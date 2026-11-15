import Darwin
import Foundation

// The Agent's network access outside the page: the HTTP client behind
// `http_request`, `wukong.fetch` and `GM_xmlhttpRequest`, the cookie header
// rules, per-forum pacing, `@connect` host fencing and the "site" rule.

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
        let host = ConnectHostPolicy.normalizeHost(host)
        guard !host.isEmpty else { return nil }
        if let ipv4 = ConnectHostPolicy.parseIPv4(host) {
            return String(format: "%d.%d.%d.%d", (ipv4 >> 24) & 0xFF, (ipv4 >> 16) & 0xFF, (ipv4 >> 8) & 0xFF, ipv4 & 0xFF)
        }
        if let ipv6 = ConnectHostPolicy.parseIPv6(host) {
            return ipv6.bytes.map { String(format: "%02x", $0) }.joined() + (ipv6.zone.map { "%\($0)" } ?? "")
        }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let last = labels[labels.count - 1]
        let secondLast = labels[labels.count - 2]
        let take = (last.count == 2 && secondLevelLabels.contains(secondLast)) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    static func site(of url: URL?) -> String? {
        ConnectHostPolicy.extractHost(from: url).flatMap(registrableDomain(of:))
    }

    /// True only when both URLs have a host and share a registrable domain.
    static func sameSite(_ a: URL?, _ b: URL?) -> Bool {
        guard let first = site(of: a), let second = site(of: b) else { return false }
        return first == second
    }
}

// MARK: - @connect host policy & script limits

enum ConnectHostPolicy {
    static func extractHost(from url: URL?) -> String? {
        guard let raw = url?.host(percentEncoded: false) ?? url?.host else { return nil }
        let normalized = normalizeHost(raw)
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizeHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 {
            host.removeFirst(); host.removeLast()
        }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func isNumericOrHexIPv4Candidate(_ host: String) -> Bool {
        guard !host.isEmpty, !host.contains(":") else { return false }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.count <= 4 && parts.allSatisfy { part in
            guard !part.isEmpty else { return false }
            return part.hasPrefix("0x")
                ? (part.count > 2 && part.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit })
                : part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    static func parseIPv4(_ host: String) -> UInt32? {
        guard isNumericOrHexIPv4Candidate(host) else { return nil }
        var addr = in_addr()
        if host.withCString({ inet_aton($0, &addr) }) == 1 { return UInt32(bigEndian: addr.s_addr) }
        if host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 { return UInt32(bigEndian: addr.s_addr) }
        return nil
    }

    static func parseIPv6(_ host: String) -> (bytes: [UInt8], zone: String?)? {
        guard host.contains(":") else { return nil }
        let parts = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let zone = parts.count > 1 ? String(parts[1]) : nil
        if let zone, zone.isEmpty { return nil }
        var addr = in6_addr()
        guard String(parts[0]).withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return (withUnsafeBytes(of: addr) { Array($0) }, zone)
    }

    static func isPrivateIPv4(_ u32: UInt32) -> Bool {
        (u32 & 0xFF00_0000) == 0x0000_0000 || (u32 & 0xFF00_0000) == 0x0A00_0000
            || (u32 & 0xFFC0_0000) == 0x6440_0000 || (u32 & 0xFF00_0000) == 0x7F00_0000
            || (u32 & 0xFFFF_0000) == 0xA9FE_0000 || (u32 & 0xFFF0_0000) == 0xAC10_0000
            || (u32 & 0xFFFF_0000) == 0xC0A8_0000 || u32 == 0xFFFF_FFFF
    }

    static func isPrivateIPv6(_ bytes: [UInt8], zone: String?) -> Bool {
        if zone != nil || bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
        if (bytes[0] & 0xFE) == 0xFC { return true }
        if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 || (bytes[1] & 0xC0) == 0xC0 { return true }
        let v4 = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF { return isPrivateIPv4(v4) }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return isPrivateIPv4(v4) }
        if bytes[0..<8].allSatisfy({ $0 == 0 }), bytes[8] == 0xFF, bytes[9] == 0xFF, bytes[10] == 0, bytes[11] == 0 { return isPrivateIPv4(v4) }
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xFF, bytes[3] == 0x9B, bytes[4..<12].allSatisfy({ $0 == 0 }) { return isPrivateIPv4(v4) }
        return false
    }

    static func isLocalOrPrivateHost(_ rawHost: String) -> Bool {
        let host = normalizeHost(rawHost)
        guard !host.isEmpty else { return true }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if isNumericOrHexIPv4Candidate(host) {
            var a1 = in_addr(), a2 = in_addr()
            let ok1 = host.withCString { inet_aton($0, &a1) } == 1
            let ok2 = host.withCString { inet_pton(AF_INET, $0, &a2) } == 1
            if !ok1 { return true }
            let v1 = UInt32(bigEndian: a1.s_addr)
            if ok2, UInt32(bigEndian: a2.s_addr) != v1 { return true }
            return isPrivateIPv4(v1)
        }
        if host.contains(":") {
            guard let ipv6 = parseIPv6(host) else { return true }
            return isPrivateIPv6(ipv6.bytes, zone: ipv6.zone)
        }
        return false
    }

    static func allows(url: URL, pageURL: URL?, connect: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let targetHost = extractHost(from: url) else { return false }
        let targetIPv4 = parseIPv4(targetHost), targetIPv6 = parseIPv6(targetHost)
        let targetIsIP = targetIPv4 != nil || targetIPv6 != nil || isNumericOrHexIPv4Candidate(targetHost)
        for rawRule in (connect.isEmpty ? ["self"] : connect) {
            let rule = normalizeHost(rawRule)
            guard !rule.isEmpty else { continue }
            if rule == "self" { if AgentSite.sameSite(url, pageURL) { return true }; continue }
            if rule == "*" { if !isLocalOrPrivateHost(targetHost) { return true }; continue }
            if let ruleV4 = parseIPv4(rule) { if targetIPv4 == ruleV4 { return true }; continue }
            if let ruleV6 = parseIPv6(rule) {
                if let targetIPv6, targetIPv6.bytes == ruleV6.bytes, (ruleV6.zone == nil || targetIPv6.zone == ruleV6.zone) { return true }
                continue
            }
            if !targetIsIP, targetHost == rule || targetHost.hasSuffix("." + rule) { return true }
        }
        return false
    }
}

final class ScriptRequestLimiter: @unchecked Sendable {
    static let maxConcurrentPerScript = 4
    static let maxPerMinutePerScript = 60
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var inFlightByScript: [String: Int] = [:]
    private var startsByScript: [String: [Date]] = [:]

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func acquire(scriptID: String) throws {
        lock.lock(); defer { lock.unlock() }
        let inFlight = inFlightByScript[scriptID, default: 0]
        if inFlight >= Self.maxConcurrentPerScript {
            throw ScriptHTTPError(kind: .limit, message: "GM_xmlhttpRequest limit reached: at most \(Self.maxConcurrentPerScript) requests at once per script.")
        }
        let ts = now(), cutoff = ts.addingTimeInterval(-60)
        var recent = (startsByScript[scriptID] ?? []).filter { $0 > cutoff }
        if recent.count >= Self.maxPerMinutePerScript {
            startsByScript[scriptID] = recent
            throw ScriptHTTPError(kind: .limit, message: "GM_xmlhttpRequest limit reached: at most \(Self.maxPerMinutePerScript) requests per minute per script.")
        }
        recent.append(ts)
        startsByScript[scriptID] = recent
        inFlightByScript[scriptID] = inFlight + 1
    }

    func release(scriptID: String) {
        lock.lock(); defer { lock.unlock() }
        let next = (inFlightByScript[scriptID] ?? 1) - 1
        if next <= 0 { inFlightByScript.removeValue(forKey: scriptID) } else { inFlightByScript[scriptID] = next }
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
    var httpsOnly = false
    var maxBytes: Int = AgentHTTPClient.maxBodyBytes
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

enum ScriptHTTPErrorKind: String, Sendable, Equatable {
    case blocked
    case limit
    case timeout
    case tooLarge
    case network
}

struct ScriptHTTPError: LocalizedError, Equatable, Sendable {
    var kind: ScriptHTTPErrorKind
    var message: String
    var errorDescription: String? { message }
}

struct ScriptHTTPRequest: Sendable {
    var scriptID: String
    var url: URL
    var method: String = "GET"
    var headers: [String: String] = [:]
    var body: String?
    var timeout: TimeInterval = AgentHTTPClient.defaultScriptTimeout
    var anonymous: Bool = false
    var connect: [String] = []
    var pageURL: URL?
    var useEnvironmentPageURL: Bool = true
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
    static let maxScriptBodyBytes = 5 * 1024 * 1024
    static let defaultScriptTimeout: TimeInterval = 30
    static let maxScriptTimeout: TimeInterval = 120
    static let maxRedirects = 10

    private let configuration: URLSessionConfiguration
    let pacer: ForumRequestPacer
    let scriptLimiter: ScriptRequestLimiter
    let environment: AgentNetworkEnvironment

    /// `configuration` is copied; tests add a `URLProtocol` stub through it.
    init(
        configuration: URLSessionConfiguration? = nil,
        pacer: ForumRequestPacer = ForumRequestPacer(),
        scriptLimiter: ScriptRequestLimiter = ScriptRequestLimiter(),
        environment: AgentNetworkEnvironment = AgentNetworkEnvironment()
    ) {
        let config = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        self.configuration = config
        self.pacer = pacer
        self.scriptLimiter = scriptLimiter
        self.environment = environment
    }

    func send(_ request: AgentHTTPRequest) async throws -> AgentHTTPResponse {
        if request.httpsOnly, request.url.scheme?.lowercased() != "https" {
            throw AgentHTTPError(message: "Only HTTPS links are allowed.")
        }
        let cap = max(1, min(request.maxBytes, Self.maxBodyBytes))
        let hopCheck: ((URL, String) throws -> Void)? = request.httpsOnly ? { hopURL, _ in
            if hopURL.scheme?.lowercased() != "https" { throw AgentHTTPError(message: "Redirected to a non-HTTPS address.") }
        } : nil
        return try await withTimeout(request.timeout, timeoutError: AgentHTTPError(message: "The request timed out after \(Int(request.timeout)) seconds.")) { [self] in
            try await perform(request, maxBodyBytes: cap, scriptHopCheck: hopCheck)
        }
    }

    /// Sends a `GM_xmlhttpRequest` with `@connect` fencing on every hop,
    /// `Confirm before writes`, same-site-only cookies, 5 MB cap, and per-script limits.
    func sendScriptRequest(_ request: ScriptHTTPRequest) async throws -> AgentHTTPResponse {
        try scriptLimiter.acquire(scriptID: request.scriptID)
        defer { scriptLimiter.release(scriptID: request.scriptID) }
        try Task.checkCancellation()
        let clampedTimeout = request.timeout > 0 ? min(request.timeout, Self.maxScriptTimeout) : Self.defaultScriptTimeout
        if let body = request.body, body.utf8.count > Self.maxScriptBodyBytes {
            throw ScriptHTTPError(kind: .tooLarge, message: "Request body exceeds the 5 MB script limit.")
        }
        let resolvedPageURL: URL? = if let explicit = request.pageURL { explicit }
            else if request.useEnvironmentPageURL { await environment.currentPageURL() }
            else { nil }
        let confirmWrites = await environment.confirmBeforeWrites()
        let trimmedMethod = request.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedMethod = trimmedMethod.isEmpty ? "GET" : trimmedMethod
        try validateScriptHop(url: request.url, method: normalizedMethod, pageURL: resolvedPageURL, connect: request.connect, confirmBeforeWrites: confirmWrites)

        do {
            return try await withTimeout(clampedTimeout, timeoutError: ScriptHTTPError(kind: .timeout, message: "The request timed out.")) { [self] in
                let strippedHeaders = request.headers.filter {
                    $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "cookie"
                }
                let attachCookies = !request.anonymous && AgentSite.sameSite(request.url, resolvedPageURL)
                return try await perform(
                    AgentHTTPRequest(url: request.url, method: normalizedMethod, headers: strippedHeaders, body: request.body, sendCookies: attachCookies, timeout: clampedTimeout),
                    maxBodyBytes: Self.maxScriptBodyBytes,
                    failOnOverflow: true,
                    scriptHopCheck: { hopURL, hopMethod in
                        try self.validateScriptHop(url: hopURL, method: hopMethod, pageURL: resolvedPageURL, connect: request.connect, confirmBeforeWrites: confirmWrites)
                    }
                )
            }
        } catch let error as ScriptHTTPError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw CancellationError() }
            if urlError.code == .timedOut { throw ScriptHTTPError(kind: .timeout, message: "The request timed out.") }
            throw ScriptHTTPError(kind: .network, message: urlError.localizedDescription)
        } catch {
            throw ScriptHTTPError(kind: .network, message: error.localizedDescription)
        }
    }

    private func validateScriptHop(url: URL, method: String, pageURL: URL?, connect: [String], confirmBeforeWrites: Bool) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = ConnectHostPolicy.extractHost(from: url) else {
            throw ScriptHTTPError(kind: .blocked, message: "GM_xmlhttpRequest requires an http or https URL.")
        }
        guard ConnectHostPolicy.allows(url: url, pageURL: pageURL, connect: connect) else {
            throw ScriptHTTPError(kind: .blocked, message: "Host `\(host)` is not allowed by @connect.")
        }
        if confirmBeforeWrites, !((method == "GET" || method == "HEAD") && AgentSite.sameSite(url, pageURL)) {
            throw ScriptHTTPError(kind: .blocked, message: "Blocked while Confirm before writes is on: only same-site GET and HEAD requests may run.")
        }
    }

    private func perform(
        _ request: AgentHTTPRequest,
        maxBodyBytes: Int = AgentHTTPClient.maxBodyBytes,
        failOnOverflow: Bool = false,
        scriptHopCheck: ((URL, String) throws -> Void)? = nil
    ) async throws -> AgentHTTPResponse {
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
            if hop > 0 { try scriptHopCheck?(url, method) }
            var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
            urlRequest.httpMethod = method
            for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
            if let body, method != "GET", method != "HEAD" { urlRequest.httpBody = Data(body.utf8) }

            let response = try await fetchOnce(urlRequest, session: session, maxBodyBytes: maxBodyBytes, failOnOverflow: failOnOverflow)
            guard (300..<400).contains(response.status), response.status != 304,
                  let location = response.location else {
                return response.value
            }
            guard let next = URL(string: location, relativeTo: url)?.absoluteURL,
                  ["http", "https"].contains(next.scheme?.lowercased() ?? "") else {
                if scriptHopCheck != nil {
                    throw ScriptHTTPError(kind: .blocked, message: "Redirect target must be an http or https URL.")
                }
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

    private func fetchOnce(
        _ request: URLRequest,
        session: URLSession,
        maxBodyBytes: Int = AgentHTTPClient.maxBodyBytes,
        failOnOverflow: Bool = false
    ) async throws -> Hop {
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
        if failOnOverflow, http.expectedContentLength > Int64(maxBodyBytes) {
            throw ScriptHTTPError(kind: .tooLarge, message: "Response exceeds the 5 MB script limit.")
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
                if failOnOverflow, data.count > maxBodyBytes {
                    throw ScriptHTTPError(kind: .tooLarge, message: "Response exceeds the 5 MB script limit.")
                }
                if !failOnOverflow, data.count > maxBodyBytes { truncated = true; break }
            }
        }
        if !truncated { data.append(contentsOf: buffer) }
        if data.count > maxBodyBytes {
            if failOnOverflow {
                throw ScriptHTTPError(kind: .tooLarge, message: "Response exceeds the 5 MB script limit.")
            }
            data = data.prefix(maxBodyBytes)
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

/// Runs `operation`, throwing `timeoutError` if it takes longer than `seconds`.
private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    timeoutError: any Error & Sendable,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw timeoutError
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}
