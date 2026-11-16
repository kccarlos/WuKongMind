import Foundation

/// How a live connection ended.
struct LiveClose: Equatable, Error {
    /// The WebSocket close code (1000 normal, 1007 invalid payload such as a
    /// refused setup, 1008 policy such as a bad key or an unknown or expired
    /// session, 1011 server error); nil when the socket failed without one.
    var code: Int?
    /// The server's reason (Google cuts it at 123 bytes).
    var reason: String

    static let normalClosure = 1000
    static let invalidPayload = 1007
    static let policyViolation = 1008
    static let internalError = 1011

    /// The key, the model or the setup was refused: retrying won't help.
    var isRefusal: Bool {
        guard code == Self.invalidPayload || code == Self.policyViolation else { return false }
        return !isSessionGone && !isAlreadyConnected
    }

    /// The session behind a resumption handle no longer exists (AI Studio
    /// ends sessions about 60 minutes after they open).
    var isSessionGone: Bool {
        let text = reason.lowercased()
        return code == Self.policyViolation
            && (text.contains("not found") || text.contains("expired"))
            && !text.contains("publisher model")
    }

    /// AI Studio allows one connection per session: a resume dialled while
    /// the old connection is open is refused.
    var isAlreadyConnected: Bool {
        code == Self.policyViolation && reason.lowercased().contains("already connected")
    }
}

/// One live connection: JSON text frames both ways. The session owns one at
/// a time; a resume or a refresh opens a new one.
@MainActor
protocol LiveTransport: AnyObject {
    /// Opens the connection.
    func connect(_ request: URLRequest) async throws
    /// Queues one frame, sent in order after every earlier one. A failed
    /// send ends the connection (`frames` finishes with the close).
    func send(_ text: String)
    /// Incoming frames, until the connection closes; the stream then ends
    /// with the close (see `closeReason`).
    var frames: AsyncStream<Data> { get }
    /// Why the connection ended, once `frames` has finished.
    var closeReason: LiveClose? { get }
    func close()
}

/// Makes a transport for each connection.
typealias LiveTransportFactory = @MainActor () -> LiveTransport

/// `LiveTransport` on `URLSessionWebSocketTask`: a serialized send queue, a
/// receive loop, a ping every 20 s, and the close code surfaced.
@MainActor
final class WebSocketLiveTransport: NSObject, LiveTransport {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<Data>.Continuation?
    let frames: AsyncStream<Data>
    private(set) var closeReason: LiveClose?
    /// Sends wait for the one before them: URLSessionWebSocketTask allows
    /// overlapping sends, but frames must not reorder.
    private var sendChain: Task<Void, Error>?
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private let delegateProxy = WebSocketDelegateProxy()
    /// The live test budget's charge for this connection (tests and spikes only).
    private var budgetLease: LiveBudget.Lease?
    private var budgetTask: Task<Void, Never>?

    static let pingInterval: Duration = .seconds(20)

    init(configuration: URLSessionConfiguration = .default) {
        var continuation: AsyncStream<Data>.Continuation?
        frames = AsyncStream { continuation = $0 }
        self.continuation = continuation
        session = URLSession(configuration: configuration, delegate: delegateProxy, delegateQueue: nil)
        super.init()
    }

    func connect(_ request: URLRequest) async throws {
        if let budget = LiveBudget.shared {
            budgetLease = try budget.begin(request.url?.host ?? "live")
            let seconds = budget.remainingSeconds()
            budgetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, self.closeReason == nil else { return }
                let reason = "\(LiveBudget.refusalPrefix): the run's seconds are used up"
                print("[LIVE-BUDGET] closing: \(reason)")
                self.task?.cancel(with: .policyViolation, reason: nil)
                self.finish(LiveClose(code: LiveClose.policyViolation, reason: reason))
            }
        }
        let task = session.webSocketTask(with: request)
        // Audio frames from the model are up to ~35 KB; allow headroom.
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegateProxy.setOpening { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
                task.resume()
            }
        } catch {
            finish(LiveClose(code: nil, reason: error.localizedDescription))
            throw error
        }
        delegateProxy.onClose = { [weak self] code, reason in
            Task { @MainActor in self?.finish(LiveClose(code: code, reason: reason)) }
        }
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard let task = self?.task else { return }
                task.sendPing { _ in }
            }
        }
    }

    func send(_ text: String) {
        let previous = sendChain
        sendChain = Task { @MainActor [weak self] in
            _ = try? await previous?.value
            guard let task = self?.task else { throw LiveClose(code: nil, reason: "Not connected") }
            do {
                try await task.send(.string(text))
            } catch {
                self?.task?.cancel(with: .abnormalClosure, reason: nil)
                throw error
            }
        }
    }

    func close() {
        guard let task else { return }
        task.cancel(with: .normalClosure, reason: nil)
        finish(LiveClose(code: LiveClose.normalClosure, reason: "Closed by the app"))
    }

    private func receiveLoop() async {
        while let task {
            do {
                switch try await task.receive() {
                case .string(let text): continuation?.yield(Data(text.utf8))
                case .data(let data): continuation?.yield(data)
                @unknown default: break
                }
            } catch {
                let code = task.closeCode == .invalid ? nil : task.closeCode.rawValue
                let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? error.localizedDescription
                finish(LiveClose(code: code, reason: reason))
                return
            }
        }
    }

    private func finish(_ close: LiveClose) {
        guard closeReason == nil else { return }
        closeReason = close
        budgetTask?.cancel()
        if let budgetLease { LiveBudget.shared?.end(budgetLease) }
        budgetLease = nil
        pingTask?.cancel()
        receiveTask?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}

/// URLSession's WebSocket callbacks (open, close, failure).
private final class WebSocketDelegateProxy: NSObject, URLSessionWebSocketDelegate {
    var onClose: ((Int?, String) -> Void)?
    private let lock = NSLock()
    /// Called once: nil when the socket opened, else the failure.
    private var opening: ((Error?) -> Void)?

    func setOpening(_ callback: @escaping (Error?) -> Void) {
        lock.lock()
        opening = callback
        lock.unlock()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        takeOpening()?(nil)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose?(closeCode.rawValue, reason.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        takeOpening()?(error)
    }

    private func takeOpening() -> ((Error?) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let callback = opening
        opening = nil
        return callback
    }
}
