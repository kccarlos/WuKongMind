import Foundation

extension SiteKind {
    static let hackerNews = SiteKind("hackernews")
}

/// This service occupies one HTTPS host. Story identity is always the URL's id,
/// including when a page is shared without Safari's preprocessing facts.
struct HackerNewsRecognizer: SiteRecognizer {
    static let siteURL = "https://news.ycombinator.com"
    var kind: SiteKind { .hackerNews }
    var platformName: String { "Hacker News" }
    var factKeys: PageFactKeys {
        PageFactKeys(elements: ["hnmain": []], selectors: ["tr.athing.submission"])
    }

    static func accepts(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "news.ycombinator.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }
    static func validID(_ value: String?) -> String? {
        guard let value, value.count <= 12, value.first != "0",
              value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return ForumSite.positiveTopicID(value)
    }
    func recognize(facts: PageFacts, url: URL) -> SitePageMatch? {
        guard Self.accepts(url), facts.elements["hnmain"] != nil else { return nil }
        return SitePageMatch(siteURL: Self.siteURL, basePath: "", forumName: platformName,
                             kind: kind, platformName: platformName,
                             topicID: facts.matches.contains("tr.athing.submission") ? looseTopicID(in: url) : nil)
    }
    func topicID(fromURL url: URL, basePath: String) -> String? { nil }
    func looseTopicID(in url: URL) -> String? {
        let scheme = url.scheme?.lowercased()
        let portOK = (scheme == "https" && (url.port == nil || url.port == 443))
            || (scheme == "http" && (url.port == nil || url.port == 80))
        guard portOK, url.host?.lowercased() == "news.ycombinator.com",
              url.user == nil, url.password == nil, url.path == "/item" else { return nil }
        return Self.validID(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value)
    }
    /// Fragments hold item ids, never sequential post numbers.
    func postNumber(in url: URL) -> Int? { nil }
    func claimedSiteURL(forHost host: String) -> String? {
        host.lowercased() == "news.ycombinator.com" ? Self.siteURL : nil
    }
}
