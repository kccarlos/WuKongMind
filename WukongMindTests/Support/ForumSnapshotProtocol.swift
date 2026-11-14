import CryptoKit
import Foundation
@testable import WukongMind

enum ForumSnapshotError: LocalizedError, CustomNSError, Equatable, Sendable {
    case missingURL(URL, kind: SiteKind)
    case sizeLimitExceeded(kind: SiteKind, bytes: Int, limit: Int)
    case invalidUpstreamResponse(URL)
    case unconfiguredSession(URL)

    static var errorDomain: String { "ForumSnapshotError" }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
    var errorDescription: String? {
        switch self {
        case .missingURL(let url, let kind): "No recorded \(kind.id) snapshot entry for \(url.absoluteString)."
        case .sizeLimitExceeded(let kind, let bytes, let limit): "Snapshot for \(kind.id) would reach \(bytes) bytes, exceeding the \(limit)-byte cap."
        case .invalidUpstreamResponse(let url): "Upstream response for \(url.absoluteString) was not HTTP."
        case .unconfiguredSession(let url): "No ForumSnapshot registered for request \(url.absoluteString)."
        }
    }
}

/// Per-kind HTTP snapshot store backing `ForumSnapshotProtocol` (`Fixtures/Comparison/<kind>/`, <= 5 MB).
final class ForumSnapshot: @unchecked Sendable {
    enum Mode: Sendable, Equatable { case record, replay }

    struct Entry: Codable, Equatable, Sendable {
        var url: String
        var status: Int
        var headers: [String: String]
        var body: JSONValue?
        var textBody: String?
    }

    static let defaultMaxBytesPerKind = 5 * 1024 * 1024
    private static let keptHeaders: Set<String> = ["content-type", "x-wp-total", "x-wp-totalpages"]

    let id = UUID().uuidString
    let kind: SiteKind
    let mode: Mode
    let directory: URL
    let maxBytes: Int
    private let upstreamSession: URLSession
    private let lock = NSLock()
    private var entriesByURL: [String: (entry: Entry, fileName: String, byteCount: Int)] = [:]
    private var recordedMisses: [URL] = []
    private var recordedUnmatched: [URL] = []

    static func defaultDirectory(for kind: SiteKind, filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Comparison/\(kind.id)", isDirectory: true)
    }

    init(
        kind: SiteKind, mode: Mode, directory: URL? = nil,
        maxBytes: Int = ForumSnapshot.defaultMaxBytesPerKind, upstreamSession: URLSession? = nil
    ) throws {
        self.kind = kind
        self.mode = mode
        self.directory = directory ?? Self.defaultDirectory(for: kind)
        self.maxBytes = maxBytes
        if let upstreamSession {
            self.upstreamSession = upstreamSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            self.upstreamSession = URLSession(configuration: config, delegate: ForumRedirectGuard.shared, delegateQueue: nil)
        }
        try loadExistingEntries()
        ForumSnapshotProtocol.register(self)
    }

    deinit { ForumSnapshotProtocol.unregister(id: id) }

    var misses: [URL] { lock.withLock { recordedMisses } }
    var unmatchedURLs: [URL] { lock.withLock { recordedUnmatched } }
    var recordedURLs: [String] { lock.withLock { entriesByURL.keys.sorted() } }
    var totalBytes: Int { lock.withLock { entriesByURL.values.reduce(0) { $0 + $1.byteCount } } }
    func resetMisses() { lock.withLock { recordedMisses.removeAll() } }

    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ForumSnapshotProtocol.self]
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpAdditionalHeaders = [ForumSnapshotProtocol.snapshotHeader: id]
        return URLSession(configuration: config, delegate: SnapshotSessionDelegate(snapshot: self), delegateQueue: nil)
    }

    func makeForumService(pacer: ForumRequestPacer = ForumRequestPacer()) -> ForumService {
        ForumService(session: makeSession(), pacer: pacer)
    }

    static func canonicalURLString(for url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        parts.fragment = nil
        if let scheme = parts.scheme { parts.scheme = scheme.lowercased() }
        if let host = parts.host { parts.host = host.lowercased() }
        return parts.string ?? url.absoluteString
    }

    fileprivate func resolve(request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw ForumSnapshotError.invalidUpstreamResponse(URL(string: "about:blank")!) }
        let key = Self.canonicalURLString(for: url)
        if let hit = lock.withLock({ entriesByURL[key]?.entry }) {
            return try Self.makeHTTPResponse(for: url, entry: hit)
        }
        guard mode == .record else {
            lock.withLock { recordedUnmatched.append(url) }
            throw ForumSnapshotError.missingURL(url, kind: kind)
        }

        var liveRequest = request
        liveRequest.setValue(nil, forHTTPHeaderField: ForumSnapshotProtocol.snapshotHeader)
        let (rawData, rawResponse) = try await upstreamSession.data(for: liveRequest)
        guard let http = rawResponse as? HTTPURLResponse else { throw ForumSnapshotError.invalidUpstreamResponse(url) }
        let headers = Self.filteredHeaders(from: http)
        if http.statusCode == 429 || (500...599).contains(http.statusCode) {
            return (HTTPURLResponse(url: url, statusCode: http.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!, rawData)
        }

        let (trimmedBody, trimmedText) = Self.trimBody(rawData, url: url, headers: headers, kind: kind)
        let entry = Entry(url: key, status: http.statusCode, headers: headers, body: trimmedBody, textBody: trimmedText)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let fileData = try encoder.encode(entry)
        let fileName = Self.fileName(forKey: key, url: url, kind: kind)

        try lock.withLock {
            let existing = entriesByURL[key]?.byteCount ?? 0
            let nextTotal = entriesByURL.values.reduce(0) { $0 + $1.byteCount } - existing + fileData.count
            if nextTotal > maxBytes {
                throw ForumSnapshotError.sizeLimitExceeded(kind: kind, bytes: nextTotal, limit: maxBytes)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileData.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            entriesByURL[key] = (entry, fileName, fileData.count)
            recordedMisses.append(url)
        }
        return try Self.makeHTTPResponse(for: url, entry: entry)
    }

    private func loadExistingEntries() throws {
        var files: [URL] = []
        if let dirFiles = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            files = dirFiles.filter { $0.pathExtension == "json" }
        } else if mode == .replay, let bundled = Bundle(for: ForumSnapshotProtocol.self).urls(forResourcesWithExtension: "json", subdirectory: nil) {
            files = bundled.filter { $0.lastPathComponent.hasPrefix("\(kind.id)-") }
        }
        let decoder = JSONDecoder()
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try Data(contentsOf: file)
            let entry = try decoder.decode(Entry.self, from: data)
            entriesByURL[entry.url] = (entry, file.lastPathComponent, data.count)
        }
        let loaded = entriesByURL.values.reduce(0) { $0 + $1.byteCount }
        if loaded > maxBytes { throw ForumSnapshotError.sizeLimitExceeded(kind: kind, bytes: loaded, limit: maxBytes) }
    }

    private static func makeHTTPResponse(for url: URL, entry: Entry) throws -> (HTTPURLResponse, Data) {
        let data = if let json = entry.body {
            try JSONSerialization.data(withJSONObject: json.toFoundation(), options: [.sortedKeys])
        } else {
            Data((entry.textBody ?? "").utf8)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: entry.status, httpVersion: "HTTP/1.1", headerFields: entry.headers) else {
            throw ForumSnapshotError.invalidUpstreamResponse(url)
        }
        return (response, data)
    }

    private static func filteredHeaders(from response: HTTPURLResponse) -> [String: String] {
        var filtered: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            let key = String(describing: k).lowercased()
            if keptHeaders.contains(key) { filtered[key] = String(describing: v) }
        }
        return filtered
    }

    private static func fileName(forKey key: String, url: URL, kind: SiteKind) -> String {
        let rawSlug = ((url.host ?? "") + "-" + url.path).lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let slug = rawSlug.isEmpty ? "root" : String(rawSlug.prefix(36))
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(kind.id)-\(slug)-\(digest).json"
    }

    // MARK: - Adapter-Aware Body Trimming

    static func trimBody(_ data: Data, url: URL, headers: [String: String], kind: SiteKind) -> (JSONValue?, String?) {
        let contentType = headers["content-type"]?.lowercased() ?? ""
        if !contentType.contains("html"),
           let rawJSON = try? JSONSerialization.jsonObject(with: data),
           rawJSON is [String: Any] || rawJSON is [Any],
           let value = try? JSONValue.fromFoundation(trimJSON(rawJSON, url: url, kind: kind)) {
            return (value, nil)
        }
        let text = String(decoding: data, as: UTF8.self)
        if kind == .hackerNews, text.range(of: #"\bid=["']?hnmain\b"#, options: .regularExpression) != nil {
            return (nil, "<!doctype html><html><body><table id=\"hnmain\"></table></body></html>")
        }
        return (nil, text)
    }

    private static func trimJSON(_ any: Any, url: URL, kind: SiteKind) -> Any {
        switch kind {
        case .discourse: trimDiscourse(any, path: url.path)
        case .hackerNews: trimHackerNews(any)
        case .wordpress: trimWordPress(any, path: url.path)
        default: any
        }
    }

    private static let discourseListingKeys = [
        "id", "title", "fancy_title", "slug", "posts_count",
        "last_posted_at", "bumped_at", "excerpt", "pinned", "like_count", "has_accepted_answer"
    ]

    private static func trimDiscourse(_ any: Any, path: String) -> Any {
        guard let dict = any as? [String: Any] else { return any }
        if path.hasSuffix("/posts.json"), let stream = dict["post_stream"] as? [String: Any] {
            let posts = (stream["posts"] as? [[String: Any]] ?? []).map {
                trimDiscoursePost($0, keys: ["id", "post_number", "username", "cooked", "like_count"])
            }
            return ["post_stream": ["posts": posts]]
        }
        if let stream = dict["post_stream"] as? [String: Any] {
            var out = pick(dict, ["id", "title", "fancy_title", "slug", "posts_count", "highest_post_number", "accepted_answer", "accepted_answers"])
            if let username = ((dict["details"] as? [String: Any])?["created_by"] as? [String: Any])?["username"] {
                out["details"] = ["created_by": ["username": username]]
            }
            var trimmedStream = pick(stream, ["stream"])
            trimmedStream["posts"] = (stream["posts"] as? [[String: Any]] ?? []).map {
                trimDiscoursePost($0, keys: ["id", "post_number", "username", "like_count", "accepted_answer", "topic_accepted_answer"])
            }
            out["post_stream"] = trimmedStream
            return out
        }
        if let topicList = dict["topic_list"] as? [String: Any] {
            return ["topic_list": ["topics": (topicList["topics"] as? [[String: Any]] ?? []).map { pick($0, discourseListingKeys) }]]
        }
        if dict["posts"] != nil || dict["topics"] != nil {
            var out: [String: Any] = [:]
            if let posts = dict["posts"] as? [[String: Any]] {
                out["posts"] = posts.map { pick($0, ["id", "username", "blurb", "post_number", "topic_id"]) }
            }
            if let topics = dict["topics"] as? [[String: Any]] {
                out["topics"] = topics.map { pick($0, discourseListingKeys) }
            }
            return out
        }
        if let about = dict["about"] as? [String: Any] { return ["about": pick(about, ["title"])] }
        if path.hasSuffix("/site/basic-info.json") {
            return pick(dict, ["title", "apple_touch_icon_url", "large_icon_url", "favicon_url", "logo_small_url"])
        }
        return dict
    }

    private static func trimDiscoursePost(_ post: [String: Any], keys: [String]) -> [String: Any] {
        var out = pick(post, keys)
        if let actions = post["actions_summary"] as? [[String: Any]] {
            out["actions_summary"] = actions.map { pick($0, ["id", "count"]) }
        }
        return out
    }

    private static func trimHackerNews(_ any: Any) -> Any {
        guard let dict = any as? [String: Any] else { return any }
        if let hits = dict["hits"] as? [[String: Any]] {
            let keys = ["objectID", "story_id", "story_title", "title", "comment_text", "story_text", "num_comments", "created_at", "points", "author", "parent_id"]
            return ["hits": hits.map { pick($0, keys) }]
        }
        return (dict["id"] != nil && dict["type"] != nil) ? trimHackerNewsItem(dict) : dict
    }

    private static func trimHackerNewsItem(_ dict: [String: Any]) -> [String: Any] {
        var out = pick(dict, ["id", "type", "author", "title", "text", "url", "points", "created_at_i"])
        if let children = dict["children"] as? [[String: Any]], !children.isEmpty {
            out["children"] = children.map(trimHackerNewsItem)
        }
        return out
    }

    private static func trimWordPress(_ any: Any, path: String) -> Any {
        if let array = any as? [[String: Any]] {
            if path.contains("/comments") { return array.map(trimWordPressComment) }
            if path.contains("/categories") { return array.map { pick($0, ["id", "name", "slug"]) } }
            return array.map(trimWordPressPost)
        }
        guard let dict = any as? [String: Any] else { return any }
        if dict["namespaces"] != nil { return pick(dict, ["name", "namespaces", "home", "site_icon_url"]) }
        if dict["id"] != nil, dict["title"] != nil || dict["content"] != nil { return trimWordPressPost(dict) }
        return dict
    }

    private static func trimWordPressPost(_ dict: [String: Any]) -> [String: Any] {
        var out = pick(dict, ["id", "link", "date_gmt", "modified_gmt", "author"])
        for field in ["title", "content", "excerpt"] {
            if let rendered = (dict[field] as? [String: Any])?["rendered"] { out[field] = ["rendered": rendered] }
        }
        if let name = (((dict["_embedded"] as? [String: Any])?["author"] as? [[String: Any]])?.first)?["name"] as? String {
            out["_embedded"] = ["author": [["name": name]]]
        }
        return out
    }

    private static func trimWordPressComment(_ dict: [String: Any]) -> [String: Any] {
        var out = pick(dict, ["id", "post", "parent", "author_name", "date_gmt"])
        if let rendered = (dict["content"] as? [String: Any])?["rendered"] { out["content"] = ["rendered": rendered] }
        return out
    }

    private static func pick(_ dict: [String: Any], _ keys: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in keys { if let val = dict[key], !(val is NSNull) { out[key] = val } }
        return out
    }
}

/// Keeps the owning `ForumSnapshot` alive for as long as its `URLSession` lives.
private final class SnapshotSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let snapshot: ForumSnapshot
    init(snapshot: ForumSnapshot) { self.snapshot = snapshot }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(ForumRedirectGuard.redirectRequest(request, from: task.currentRequest ?? task.originalRequest))
    }
}

/// `URLProtocol` routing `ForumService` requests through their registered `ForumSnapshot`.
final class ForumSnapshotProtocol: URLProtocol {
    typealias Mode = ForumSnapshot.Mode
    static let snapshotHeader = "X-Wukong-Snapshot-ID"
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var snapshots: [String: WeakSnapshot] = [:]
    private var loadingTask: Task<Void, Never>?

    private struct WeakSnapshot { weak var value: ForumSnapshot? }
    static func register(_ snapshot: ForumSnapshot) { registryLock.withLock { snapshots[snapshot.id] = WeakSnapshot(value: snapshot) } }
    static func unregister(id: String) { registryLock.withLock { _ = snapshots.removeValue(forKey: id) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        let client = self.client
        let snapshotID = req.value(forHTTPHeaderField: Self.snapshotHeader)
        guard let snapshot = Self.registryLock.withLock({ snapshotID.flatMap { Self.snapshots[$0]?.value } }) else {
            client?.urlProtocol(self, didFailWithError: ForumSnapshotError.unconfiguredSession(req.url ?? URL(string: "about:blank")!))
            return
        }
        loadingTask = Task {
            do {
                let (response, data) = try await snapshot.resolve(request: req)
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
        loadingTask = nil
    }
}
