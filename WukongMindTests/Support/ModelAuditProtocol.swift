import Foundation
@testable import WukongMind

/// Record-mode guard and audit log for the One loop comparison (owner's Haiku-only rule).
/// Every model request goes through a session with this protocol: the request body's `model` is
/// read before the call is forwarded, a call to any other model fails without leaving the machine,
/// and each call is logged (host, path, model, status; never a header or key).
final class ModelAudit: @unchecked Sendable {
    struct Entry: Codable, Equatable { var sequence: Int; var host: String; var path: String; var model: String; var status: Int }

    static let shared = ModelAudit()
    static let allowedModel = "claude-haiku-5-5"

    private let lock = NSLock()
    private var entries: [Entry] = []

    var recorded: [Entry] { lock.withLock { entries } }
    func reset() { lock.withLock { entries = [] } }

    @discardableResult
    func log(host: String, path: String, model: String, status: Int) -> Entry {
        lock.withLock {
            let entry = Entry(sequence: entries.count + 1, host: host, path: path, model: model, status: status)
            entries.append(entry)
            return entry
        }
    }

    /// A session whose every request is checked and logged, then forwarded to the network.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelAuditProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func model(in request: URLRequest) -> String? {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            body = data
        }
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json["model"] as? String
    }

    func writeLog(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try recorded.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }
}

struct ModelAuditError: LocalizedError {
    var model: String
    var errorDescription: String? { "Blocked a model call to \(model): only \(ModelAudit.allowedModel) is allowed." }
}

final class ModelAuditProtocol: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private var upstreamTask: URLSessionDataTask?
    private var model = "unknown"
    private var status = 0
    private var upstream: URLSession?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        model = ModelAudit.model(in: request) ?? "unknown"
        guard model == ModelAudit.allowedModel else {
            ModelAudit.shared.log(host: request.url?.host ?? "", path: request.url?.path ?? "", model: model, status: -1)
            client?.urlProtocol(self, didFailWithError: ModelAuditError(model: model))
            return
        }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        upstream = session
        let dataTask = session.dataTask(with: request)
        upstreamTask = dataTask
        dataTask.resume()
    }

    override func stopLoading() {
        upstreamTask?.cancel()
        upstream?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        ModelAudit.shared.log(host: request.url?.host ?? "", path: request.url?.path ?? "", model: model, status: status)
        if let error { client?.urlProtocol(self, didFailWithError: error) } else { client?.urlProtocolDidFinishLoading(self) }
        session.finishTasksAndInvalidate()
    }
}
