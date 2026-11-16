import Foundation

/// What the app saw when it asked the site for one page itself, with the person's session.
struct SiteProbeResult: Equatable, Sendable {
    /// `nil`: the request failed (offline, timed out).
    var status: Int?
    var finalURL: URL?
    var html: String = ""
}

/// The three kinds of failure of a learned reader (`design-learn-on-ask.md` "Invalidation and repair").
enum SiteFailureKind: Equatable, Sendable {
    /// The reader stopped working: the slot is rolled back.
    case tool
    /// The site's trouble (offline, signed out, busy): never the reader's fault.
    case service
    /// This one URL isn't a thread, while the reader still works on others.
    case page
}

/// Decides, after a call failed the light check, whose fault it was. App code only: the script's
/// own error can't decide, because a reader that meets a sign-in page usually just throws.
///
/// The settled rule (also written in the design page):
/// 1. A reader that throws `code: "service"` is taken at its word.
/// 2. The app fetches the page itself, once, with the session. A failed request, 401, 403, 429, 5xx,
///    or an answer from another host is `service`.
/// 3. A password field or a sign-in address proves nothing alone. It points at a sign-in page only
///    when the content is gone too: a list page with fewer than 5 links matching `thread_match`; a
///    saved test thread that no longer shows the post starts recorded for it.
/// 4. A thread failure then runs the reader on a saved test URL: it reads, so this URL is a `page`
///    failure; it fails too, so `tool`. A list has no second input, so anything left is `tool`.
struct SiteFailureClassifier: Sendable {
    static let minThreadLinks = 5

    var host: String
    var threadMatch: [MatchPattern]
    var fetch: @Sendable (URL) async -> SiteProbeResult
    /// Runs the reader on a saved test URL: did it return posts?
    var readerReads: @Sendable (URL) async -> Bool

    func classify(
        slot: SiteToolSlot, state: SiteSlotState, requested: URL?, readerSaidService: Bool = false
    ) async -> SiteFailureKind {
        if readerSaidService { return .service }
        let saved = state.testURLs.compactMap { SiteToolState.sameSiteURL($0, host: host) }
        guard let first = saved.first else {
            if let requested, Self.isSiteTrouble(await fetch(requested), host: host) { return .service }
            return .tool
        }
        if slot != .readTopic {
            let page = await fetch(first)
            if Self.isSiteTrouble(page, host: host) { return .service }
            return Self.showsSignIn(page) && threadLinkCount(in: page) < Self.minThreadLinks ? .service : .tool
        }
        if let requested, Self.isSiteTrouble(await fetch(requested), host: host) { return .service }
        let page = await fetch(first)
        if Self.isSiteTrouble(page, host: host) { return .service }
        if Self.showsSignIn(page), !Self.showsAnyPostStart(page, state: state, url: first) { return .service }
        if let requested, SiteToolState.canonicalThreadKey(for: requested) != SiteToolState.canonicalThreadKey(for: first) {
            return await readerReads(first) ? .page : .tool
        }
        return .tool
    }

    static func isSiteTrouble(_ page: SiteProbeResult, host: String) -> Bool {
        guard let status = page.status else { return true }
        if [401, 403, 429].contains(status) || status >= 500 { return true }
        guard let final = page.finalURL else { return false }
        return SiteToolState.normalizedHost(from: final) != SiteToolState.normalizedHost(host)
    }

    private static let passwordField = try! NSRegularExpression(pattern: #"(?i)<input\b[^>]*\btype\s*=\s*["']?password"#)
    private static let signInPath = try! NSRegularExpression(pattern: #"(?i)/(log-?in|sign-?in|log-?on|sso|auth)(/|\.|$)"#)

    static func showsSignIn(_ page: SiteProbeResult) -> Bool {
        let range = NSRange(page.html.startIndex..., in: page.html)
        if passwordField.firstMatch(in: page.html, range: range) != nil { return true }
        guard let path = page.finalURL?.path else { return false }
        return signInPath.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    static func showsAnyPostStart(_ page: SiteProbeResult, state: SiteSlotState, url: URL) -> Bool {
        let starts = state.postStarts[url.absoluteString] ?? state.postStarts.values.flatMap { $0 }
        guard !starts.isEmpty else { return true }
        let text = FetchedPageText.visible(page.html)
        return starts.contains { !$0.isEmpty && text.contains($0) }
    }

    private static let hrefPattern = try! NSRegularExpression(pattern: #"(?i)<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')"#)

    func threadLinkCount(in page: SiteProbeResult) -> Int {
        guard let base = page.finalURL else { return 0 }
        let html = page.html
        var keys: Set<String> = []
        for match in Self.hrefPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let group = match.range(at: 1).location != NSNotFound ? 1 : 2
            guard let r = Range(match.range(at: group), in: html),
                  let url = URL(string: FetchedPageText.decode(String(html[r])), relativeTo: base)?.absoluteURL,
                  SiteToolState.normalizedHost(from: url) == SiteToolState.normalizedHost(host),
                  threadMatch.isEmpty ? url.path != base.path : threadMatch.contains(where: { $0.matches(url: url) }) else { continue }
            keys.insert(SiteToolState.canonicalThreadKey(for: url))
        }
        return keys.count
    }
}

/// Plain text out of fetched markup, to compare with what a reader returned.
enum FetchedPageText {
    private static let dropped = try! NSRegularExpression(pattern: #"(?is)<(script|style)\b.*?</\1\s*>|<!--.*?-->"#)
    private static let blockTag = try! NSRegularExpression(pattern: #"(?i)</?(p|div|br|li|tr|td|th|h[1-6]|blockquote|article|section|pre)\b[^>]*>"#)
    private static let anyTag = try! NSRegularExpression(pattern: #"<[^>]*>"#)
    private static let entity = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#)
    private static let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'"]

    static func visible(_ html: String) -> String {
        func sub(_ re: NSRegularExpression, _ text: String, _ with: String) -> String {
            re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: with)
        }
        return SiteToolVerifier.foldWhitespace(decode(sub(anyTag, sub(blockTag, sub(dropped, html, " "), " "), "")))
    }

    static func decode(_ text: String) -> String {
        var result = "", last = text.startIndex
        for match in entity.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let body = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[body])
            let value: String? = if name.hasPrefix("#x") { UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) } }
                else if name.hasPrefix("#") { UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) } }
                else { named[name] }
            guard let value else { continue }
            result += text[last..<whole.lowerBound] + value
            last = whole.upperBound
        }
        return result + text[last...]
    }
}
