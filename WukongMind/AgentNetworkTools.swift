import Foundation

// The Agent's network access outside the page: the HTTP client behind
// `http_request` and `wukong.fetch`, the cookie header rules, per-forum pacing
// and the "site" rule (design-m3.md, `http_request`, Confirmations).

// MARK: - Site rule

/// "Site" means the registrable domain, found with a small built-in rule: the
/// last two labels of the host, or the last three when the second-to-last label
/// is a common second-level label under a country code (`co.uk`, `com.au`, ...).
/// An unknown case counts as a different site, so it asks.
enum AgentSite {
    private static let secondLevelLabels: Set<String> = [
        "co", "com", "org", "net", "gov", "edu", "ac", "or", "ne", "go", "gob", "nom", "mil"
    ]

    /// The registrable domain of `host`, or nil for an empty host.
    static func registrableDomain(of host: String) -> String? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return nil }
        // IP addresses and bare names are their own site.
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let last = labels[labels.count - 1]
        let secondLast = labels[labels.count - 2]
        let take = (last.count == 2 && secondLevelLabels.contains(secondLast)) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    static func site(of url: URL?) -> String? {
        url?.host.flatMap(registrableDomain(of:))
    }

    /// True only when both URLs have a host and share a registrable domain.
    static func sameSite(_ a: URL?, _ b: URL?) -> Bool {
        guard let first = site(of: a), let second = site(of: b) else { return false }
        return first == second
    }
}

// MARK: - Cookies

enum AgentCookies {
    /// Whether `cookie` may be sent to `url`: domain, path, `secure` and expiry.
    static func applies(_ cookie: HTTPCookie, to url: URL, now: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let expires = cookie.expiresDate, expires < now { return false }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        guard domainMatches(cookieDomain: cookie.domain, host: host) else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        if cookiePath == "/" { return true }
        return path == cookiePath || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
    }

    /// `cookieDomain` is the host itself or a parent of it.
    static func domainMatches(cookieDomain: String, host: String) -> Bool {
        let domain = cookieDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = host.lowercased()
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    /// The `Cookie` header of the target site's cookies (httpOnly included), or nil.
    static func header(for url: URL, from cookies: [HTTPCookie]) -> String? {
        let matching = cookies.filter { applies($0, to: url) }
        guard !matching.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }
}

// MARK: - HTTP client

struct AgentHTTPRequest: Sendable {
    var url: URL
    var method: String = "GET"
    var headers: [String: String] = [:]
    var body: String?
    /// Attach the target site's cookies from the browser's store.
    var sendCookies = false
    var timeout: TimeInterval = 30
}

struct AgentHTTPResponse: Sendable {
    var status: Int
    var finalURL: URL
    /// Response headers without `Set-Cookie`.
    var headers: [String: String]
    var data: Data
    var contentType: String?
    /// The download stopped at the size cap.
    var truncated: Bool

    /// The body as text, or nil when it is binary.
    var text: String? {
        guard !data.isEmpty else { return "" }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

struct AgentHTTPError: LocalizedError, Equatable, Sendable {
    var message: String
    var errorDescription: String? { message }
}

/// What the client needs from the app. Closures, so settings are read at call
/// time and tests supply fakes.
struct AgentNetworkEnvironment: Sendable {
    /// Every cookie in the browser's store.
    var cookies: @Sendable () async -> [HTTPCookie] = { [] }
    /// The page the person is looking at.
    var currentPageURL: @Sendable () async -> URL? = { nil }
    var confirmBeforeWrites: @Sendable () async -> Bool = { false }
    /// Per-forum request pacing on or off, and its pace.
    var pacing: @Sendable () async -> (enabled: Bool, pace: ForumRequestPace) = { (true, .gentle) }
    /// Pacing applies on forum hosts only.
    var isForumHost: @Sendable (URL) async -> Bool = { _ in false }
    /// Logs a `wukong.fetch` URL (the audit log records it as it does `http_request`).
    var onFetch: @Sendable (_ url: String, _ pageURL: String?) async -> Void = { _, _ in }
}

final class AgentHTTPClient: @unchecked Sendable {
    static let maxBodyBytes = 20 * 1024 * 1024
    static let maxRedirects = 10

    private let configuration: URLSessionConfiguration
    let pacer: ForumRequestPacer
    let environment: AgentNetworkEnvironment

    /// `configuration` is copied; tests add a `URLProtocol` stub through it.
    init(
        configuration: URLSessionConfiguration? = nil,
        pacer: ForumRequestPacer = ForumRequestPacer(),
        environment: AgentNetworkEnvironment = AgentNetworkEnvironment()
    ) {
        let config = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        self.configuration = config
        self.pacer = pacer
        self.environment = environment
    }

    /// Sends the request, following up to 10 redirects by hand so each hop can
    /// be paced and a hop off the starting site drops the `Cookie` header.
    /// The model's headers (a `Cookie` of its own included) are sent as given;
    /// `sendCookies` adds the target site's cookies when the model wrote none.
    func send(_ request: AgentHTTPRequest) async throws -> AgentHTTPResponse {
        try await withTimeout(request.timeout) { [self] in
            try await perform(request)
        }
    }

    private func perform(_ request: AgentHTTPRequest) async throws -> AgentHTTPResponse {
        var url = request.url
        var method = request.method.uppercased()
        var body = request.body
        var headers = request.headers
        let startSite = AgentSite.site(of: request.url)
        let hasOwnCookie = headers.keys.contains { $0.lowercased() == "cookie" }
        if request.sendCookies, !hasOwnCookie,
           let header = AgentCookies.header(for: url, from: await environment.cookies()) {
            headers["Cookie"] = header
        }

        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        for hop in 0...Self.maxRedirects {
            var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
            urlRequest.httpMethod = method
            for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
            if let body, method != "GET", method != "HEAD" { urlRequest.httpBody = Data(body.utf8) }

            let response = try await fetchOnce(urlRequest, session: session)
            guard (300..<400).contains(response.status), response.status != 304,
                  let location = response.location,
                  let next = URL(string: location, relativeTo: url)?.absoluteURL,
                  ["http", "https"].contains(next.scheme?.lowercased() ?? "")
            else {
                return response.value
            }
            guard hop < Self.maxRedirects else {
                throw AgentHTTPError(message: "Too many redirects (more than \(Self.maxRedirects)).")
            }
            if AgentSite.site(of: next) != startSite {
                headers = headers.filter { $0.key.lowercased() != "cookie" }
            }
            if response.status == 303 || ((response.status == 301 || response.status == 302) && method == "POST") {
                if method != "HEAD" { method = "GET" }
                body = nil
                headers = headers.filter { !["content-type", "content-length"].contains($0.key.lowercased()) }
            }
            url = next
        }
        throw AgentHTTPError(message: "Too many redirects (more than \(Self.maxRedirects)).")
    }

    private struct Hop {
        var value: AgentHTTPResponse
        var location: String?
        var status: Int { value.status }
    }

    private func fetchOnce(_ request: URLRequest, session: URLSession) async throws -> Hop {
        let paceState = await environment.pacing()
        var slot: String?
        if paceState.enabled, let url = request.url, await environment.isForumHost(url) {
            slot = try await pacer.acquire(for: url, pace: paceState.pace)
        }
        var backOff: TimeInterval?
        defer {
            if let slot {
                let pacer = pacer
                let wait = backOff
                Task { await pacer.release(slot, backOff: wait) }
            }
        }

        let (bytes, urlResponse) = try await session.bytes(for: request, delegate: NoRedirectDelegate())
        guard let http = urlResponse as? HTTPURLResponse else {
            throw AgentHTTPError(message: "The server did not answer with HTTP.")
        }
        var data = Data()
        var truncated = false
        var buffer = [UInt8]()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if data.count >= Self.maxBodyBytes { truncated = true; break }
            }
        }
        if !truncated { data.append(contentsOf: buffer) }
        if data.count > Self.maxBodyBytes {
            data = data.prefix(Self.maxBodyBytes)
            truncated = true
        }

        if http.statusCode == 429, let retry = http.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(retry) {
            backOff = seconds
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            if name.lowercased() == "set-cookie" { continue }
            headers[name] = text
        }
        let value = AgentHTTPResponse(
            status: http.statusCode,
            finalURL: http.url ?? request.url ?? URL(string: "about:blank")!,
            headers: headers,
            data: data,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            truncated: truncated
        )
        return Hop(value: value, location: http.value(forHTTPHeaderField: "Location"))
    }

    /// `wukong.fetch(url)` from isolated `run_js`: a GET that returns the body
    /// text. It sends cookies only when `url` is on the current page's site.
    /// With Confirm before writes on, it runs for the current page's own site
    /// (a same-site GET is a read) and refuses another site, because a script
    /// can't pause for a confirmation card.
    func scriptFetch(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw AgentHTTPError(message: "wukong.fetch needs an http or https URL.")
        }
        let page = await environment.currentPageURL()
        let sameSite = AgentSite.sameSite(url, page)
        if await environment.confirmBeforeWrites(), !sameSite {
            throw AgentHTTPError(
                message: "wukong.fetch can't reach another site while Confirm before writes is on. Use http_request, which can ask first."
            )
        }
        await environment.onFetch(url.absoluteString, page?.absoluteString)
        let response = try await send(AgentHTTPRequest(url: url, sendCookies: sameSite, timeout: 60))
        guard (200..<300).contains(response.status) else {
            throw AgentHTTPError(message: "wukong.fetch: HTTP \(response.status) from \(response.finalURL.absoluteString)")
        }
        guard let text = response.text else {
            throw AgentHTTPError(message: "wukong.fetch: the response is binary (\(response.data.count) bytes).")
        }
        return text
    }
}

/// Always answers "don't follow", so the client sees the 3xx and follows by hand.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// Runs `operation`, throwing `AgentHTTPError` if it takes longer than `seconds`.
private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw AgentHTTPError(message: "The request timed out after \(Int(seconds)) seconds.")
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}
