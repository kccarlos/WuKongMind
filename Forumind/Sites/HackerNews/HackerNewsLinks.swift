import Foundation

struct HackerNewsLinks: SiteLinks {
    func homeURL(siteURL: String) -> URL? { URL(string: HackerNewsRecognizer.siteURL) }
    func topicURL(siteURL: String, topicID: String, slug: String?) -> URL? {
        guard let id = HackerNewsRecognizer.validID(topicID) else { return nil }
        return URL(string: HackerNewsRecognizer.siteURL + "/item?id=" + id)
    }
    func postURL(topicURL: URL, number: Int, anchor: String?) -> URL {
        let page = topicPageURL(topicURL)
        guard let anchor = HackerNewsRecognizer.validID(anchor),
              var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return page }
        parts.fragment = anchor
        return parts.url ?? page
    }
    func topicPageURL(_ url: URL) -> URL {
        guard let id = HackerNewsRecognizer().looseTopicID(in: url) else { return url }
        return topicURL(siteURL: HackerNewsRecognizer.siteURL, topicID: id, slug: nil) ?? url
    }
    func canonicalPageURL(_ url: URL) -> URL { topicPageURL(url) }
    func parse(_ url: URL, basePath: String) -> SiteLink? {
        HackerNewsRecognizer().looseTopicID(in: url).map { SiteLink(topicID: $0, slug: nil, postNumber: nil) }
    }
    func lastPostURL(topicURL: URL) -> URL? { nil }
}
