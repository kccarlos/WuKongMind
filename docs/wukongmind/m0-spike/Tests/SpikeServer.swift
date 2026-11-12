import Foundation
import Network

/// Minimal HTTP/1.1 server on 127.0.0.1 so fixture pages get real CSP response headers.
/// One request per connection (Connection: close). Good enough for a spike, nothing more.
final class SpikeServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
    }

    struct Response {
        var status = 200
        var contentType = "text/plain; charset=utf-8"
        var headers: [String: String] = [:]
        var body = Data()

        static func text(_ s: String, type: String = "text/plain; charset=utf-8", headers: [String: String] = [:]) -> Response {
            Response(status: 200, contentType: type, headers: headers, body: Data(s.utf8))
        }
    }

    let name: String
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var requestLog: [Request] = []
    private let handler: (Request) -> Response
    private(set) var port: UInt16 = 0

    var origin: String { "http://127.0.0.1:\(port)" }

    init(name: String, handler: @escaping (Request) -> Response) throws {
        self.name = name
        self.handler = handler
        self.queue = DispatchQueue(label: "spike.server.\(name)")
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func start() async throws {
        final class Once: @unchecked Sendable { var done = false } // only touched on `queue`
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    cont.resume()
                case let .failed(error):
                    once.done = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    /// Every request this server has received, in order.
    var log: [Request] {
        lock.lock(); defer { lock.unlock() }
        return requestLog
    }

    func received(id: String) -> Bool {
        log.contains { $0.query["id"] == id }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { connection.cancel(); return }
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    self.lock.lock(); self.requestLog.append(request); self.lock.unlock()
                    self.send(self.handler(request), on: connection)
                    return
                }
                if isComplete || error != nil { connection.cancel(); return }
                readMore()
            }
        }
        readMore()
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) OK\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        for (k, v) in response.headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex ..< headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == "content-length" { contentLength = Int(kv[1]) ?? 0 }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let body = data[bodyStart ..< bodyStart + contentLength]
        let target = String(parts[1])
        let comps = URLComponents(string: "http://x\(target)")
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]), path: comps?.path ?? target, query: query, body: Data(body))
    }
}
