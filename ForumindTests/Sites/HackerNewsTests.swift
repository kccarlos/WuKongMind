import XCTest
@testable import Forumind

/// Saved public responses; no test reaches the network.
final class HackerNewsFixture: @unchecked Sendable {
    static let site = "https://news.ycombinator.com"
    private let lock = NSLock()
    private var log: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { log } }
    var item = HackerNewsFixture.data("hn-item-1", ext: "json")
    var search = HackerNewsFixture.data("hn-search", ext: "json")
    var html = HackerNewsFixture.data("hn-item", ext: "html")
    var status = 200
    func resetRequests() { lock.withLock { log = [] } }
    static func data(_ name: String, ext: String) -> Data {
        if ext == "html" {
            let json = try! JSONSerialization.jsonObject(with: data("hn-html", ext: "json")) as! [String: String]
            return Data(json["body"]!.utf8)
        }
        return try! Data(contentsOf: Bundle(for: HackerNewsFixture.self).url(forResource: name, withExtension: ext)!)
    }
    func network() -> SiteNetwork {
        HNStub.fixture = self
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HNStub.self]
        return ForumService(session: URLSession(configuration: config)).net(Self.site, pace: .fast)
    }
    func reply(_ request: URLRequest) -> (Int, Data, String) {
        lock.withLock { log.append(request) }
        let url = request.url!
        if url.host == "news.ycombinator.com" { return (status, html, "text/html") }
        if url.path.contains("/items/") { return (status, item, "application/json") }
        if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "tags", value: "comment")) == true {
            return (status, Self.data("hn-comments", ext: "json"), "application/json")
        }
        return (status, url.path.hasSuffix("search_by_date") ? Self.data("hn-latest", ext: "json") : search, "application/json")
    }
}
private final class HNStub: URLProtocol {
    nonisolated(unsafe) static var fixture: HackerNewsFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let (status, body, type) = fixture.reply(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class HackerNewsTests: XCTestCase {
    func adapter() throws -> any SiteAdapter {
        try XCTUnwrap(SiteRegistry.standard.adapter(for: SiteKind("hackernews")))
    }
    func read(_ fixture: HackerNewsFixture, cached: [RawForumPage] = []) async throws -> ForumFetchResult {
        try await adapter().readTopic(.init(topic: .init(siteURL: HackerNewsFixture.site, topicID: "1"), cachedPages: cached, knownTotalPosts: cached.isEmpty ? nil : 4), net: fixture.network(), progress: { _ in }, onPage: nil)
    }
    func testURLsRecognitionAndCapabilities() throws {
        let a = try adapter()
        let url = URL(string: "https://news.ycombinator.com/item?id=1&p=2#17")!
        XCTAssertEqual(a.recognizer.looseTopicID(in: url), "1")
        XCTAssertEqual(a.links.canonicalPageURL(url).absoluteString, "https://news.ycombinator.com/item?id=1")
        XCTAssertEqual(a.links.postURL(topicURL: url, number: 3, anchor: "17").fragment, "17")
        XCTAssertNil(a.links.lastPostURL(topicURL: url))
        for bad in ["https://example.com/item?id=1", "https://news.ycombinator.com/user?id=1", "https://news.ycombinator.com/item?id=0", "https://news.ycombinator.com/item?id=abc"] {
            XCTAssertNil(a.recognizer.looseTopicID(in: URL(string: bad)!))
        }
        XCTAssertEqual(a.recognizer.looseTopicID(in: URL(string: "http://news.ycombinator.com:80/item?id=1")!), "1")
        for bad in ["http://news.ycombinator.com:443/item?id=1", "https://news.ycombinator.com:80/item?id=1", "http://user" + "@news.ycombinator.com/item?id=1"] {
            XCTAssertNil(a.recognizer.looseTopicID(in: URL(string: bad)!))
        }
        let match = SiteRegistry.standard.recognize(facts: PageFacts(url: url, elements: ["hnmain": [:]], matches: ["tr.athing.submission"]), url: url)
        XCTAssertEqual(match?.match.topicID, "1")
        XCTAssertEqual(a.siteURLCandidates(fromAddress: "news.ycombinator.com/item?id=1"), [HackerNewsFixture.site])
        XCTAssertTrue(a.siteURLCandidates(fromAddress: "example.com").isEmpty)
        XCTAssertNotNil(a.capabilities.pageBridge)
        XCTAssertNil(a.capabilities.loginURL)
        XCTAssertNil(a.capabilities.session)
        XCTAssertNil(a.capabilities.topicFilters)
        XCTAssertNotNil(a.capabilities.postLookup)
        XCTAssertNotNil(a.capabilities.activeTopics)
        XCTAssertTrue(a.suggestedForums.general.isEmpty)
        XCTAssertTrue(a.suggestedForums.chinese.isEmpty)
    }
    func testRealTreePreservesEveryParentInModelTextAndAnchors() async throws {
        let fixture = HackerNewsFixture()
        let result = try await read(fixture)
        XCTAssertEqual(result.totalPosts, 4)
        XCTAssertEqual(result.rawPages.flatMap(\.blocks).map(\.anchor), ["1", "15", "17", "1079"])
        XCTAssertEqual(RawTopicFormat.parseHeaders(result.content).map(\.number), [1, 2, 3, 4])
        XCTAssertTrue(result.content.contains("[Reply to #2; item 15]"))
        XCTAssertTrue(result.content.contains("[Reply to #3; item 17]"))
        XCTAssertTrue(result.content.contains("http://ycombinator.com"))
        XCTAssertTrue(result.content.contains("sure"))
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.requests.first?.url?.host, "hn.algolia.com")
        XCTAssertNil(fixture.requests.first?.value(forHTTPHeaderField: "Cookie"))
        let cached = try await read(fixture, cached: result.rawPages)
        XCTAssertEqual(cached.content, result.content)
        XCTAssertTrue(cached.unchanged)
        let filtered = ModerationFilter.filter(result.content, siteURL: HackerNewsFixture.site, topicID: "1", rules: .init(blockedUsers: [HackerNewsFixture.site: ["sama"]]))
        XCTAssertFalse(filtered.contains("sama |"))
        XCTAssertTrue(filtered.contains("[Reply to #2; item 15]"))
    }
    func testSearchLatestAndDigestUseAuthoredHitsAndBudget() async throws {
        let a = try adapter()
        let fixture = HackerNewsFixture()
        var options = SearchOptions(); options.page = 2
        let search = try await a.run(.search(text: "sqlite", scope: .forum, options: options), net: fixture.network())
        XCTAssertEqual(search.topics.count, 3)
        XCTAssertEqual(search.hits.count, 3)
        XCTAssertTrue(search.hits.allSatisfy { $0.username != nil && $0.postNumber == 1 })
        XCTAssertTrue(search.topics.allSatisfy { $0.url.host == "news.ycombinator.com" })
        let query = URLComponents(url: fixture.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(query.contains(.init(name: "page", value: "1")))
        let latest = try await a.run(.latest, net: fixture.network())
        XCTAssertEqual(latest.topics.count, 3)
        let source = try XCTUnwrap(a.capabilities.activeTopics)
        let zero = await source.activeTopics(siteURL: HackerNewsFixture.site, budget: 0, net: fixture.network())
        XCTAssertEqual(zero.requests, 0)
        let active = await source.activeTopics(siteURL: HackerNewsFixture.site, budget: 1, net: fixture.network())
        XCTAssertEqual(active.requests, 1)
        XCTAssertEqual(active.failures, 0)
        XCTAssertFalse(active.topics?.isEmpty ?? true)
        XCTAssertEqual(try a.agent.query(.searchForum, ["query": "sqlite", "page": "2"]), .search(text: "sqlite", scope: .forum, options: options))
        XCTAssertThrowsError(try a.agent.query(.searchForum, ["query": " "]))
    }
    func testRealLargeTreePagesCallbacksAndParentReferencesCrossPages() async throws {
        let fixture = HackerNewsFixture()
        fixture.item = HackerNewsFixture.data("hn-large", ext: "json")
        let a = try adapter()
        let log = HNPages()
        let result = try await a.readTopic(.init(topic: .init(siteURL: HackerNewsFixture.site, topicID: "27016630"), cachedPages: [], knownTotalPosts: nil), net: fixture.network(), progress: { _ in }, onPage: { await log.add($0.page) })
        XCTAssertGreaterThan(result.totalPosts, 200)
        XCTAssertEqual(result.rawPages.count, (result.totalPosts + 99) / 100)
        XCTAssertEqual(result.rawPages.flatMap(\.blocks).map(\.number), Array(1...result.totalPosts))
        let called = await log.pages
        XCTAssertEqual(called.sorted(), result.rawPages.map(\.page))
        XCTAssertFalse(RawTopicFormat.pageText(2, pages: result.rawPages, fallbackText: "").isEmpty)
        XCTAssertEqual(fixture.requests.count, 1)
    }
    func testCommentSearchKeepsAuthorStoryIDAndCommentAnchor() async throws {
        let fixture = HackerNewsFixture()
        let result = try await adapter().run(.search(text: "sqlite", scope: .comments), net: fixture.network())
        XCTAssertEqual(result.hits.count, 3)
        XCTAssertTrue(result.hits.allSatisfy { $0.username != nil && $0.postNumber == nil && $0.url.fragment != nil })
        XCTAssertTrue(result.hits.allSatisfy { $0.url.host == "news.ycombinator.com" && $0.blurb?.isEmpty == false })
    }
    func testExpected200HTMLMentioningChallengeWordsRemainsReadable() async throws {
        let fixture = HackerNewsFixture()
        fixture.html.append(Data("<p>Cloudflare cf-chl- Just a moment checking your browser</p>".utf8))
        let info = try await adapter().siteInfo(siteURL: HackerNewsFixture.site, net: fixture.network())
        XCTAssertEqual(info.name, "Hacker News")
        // Forumind's transport has no challenge-word classification on a successful response.
        let response = try await fixture.network().data(URL(string: HackerNewsFixture.site)!, accept: "text/html")
        XCTAssertEqual(response, fixture.html)
        fixture.html = Data("<html><title>Just a moment...</title>cf-chl-</html>".utf8)
        do {
            _ = try await adapter().siteInfo(siteURL: HackerNewsFixture.site, net: fixture.network())
            XCTFail("challenge markup is not a valid site")
        } catch AssistantError.invalidResponse {}
    }
    func testInvalidMissingAndCommentItemsFailInsteadOfBecomingStories() async throws {
        let fixture = HackerNewsFixture()
        fixture.item = Data("null".utf8)
        do { _ = try await read(fixture); XCTFail("null item") } catch {}
        fixture.item = Data(#"{"id":1,"type":"comment","children":[]}"#.utf8)
        do { _ = try await read(fixture); XCTFail("comment is not a story") } catch {}
    }
}

private actor HNPages {
    var pages: [Int] = []
    func add(_ page: Int) { pages.append(page) }
}
