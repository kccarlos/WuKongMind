import Foundation
import XCTest
@testable import WukongMind

final class ComparisonSnapshotTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComparisonSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        UpstreamStubProtocol.reset()
        try super.tearDownWithError()
    }

    func testCommittedSnapshotsReplayDiscourseHackerNewsAndWordPressAndFailOnUnknownURL() async throws {
        let discourseSnap = try ForumSnapshot(kind: .discourse, mode: .replay)
        let discourseNet = discourseSnap.makeForumService().net("https://discourse.fixture.test", isPaced: false)
        let dTopic = try await DiscourseAdapter().readTopic(
            TopicReadRequest(topic: TopicRef(siteURL: "https://discourse.fixture.test", topicID: "42"), cachedPages: [], knownTotalPosts: nil),
            net: discourseNet, progress: { _ in }, onPage: nil
        )
        XCTAssertEqual(dTopic.totalPosts, 2)
        XCTAssertEqual(dTopic.facts?.acceptedAnswer?.postNumber, 2)
        XCTAssertTrue(dTopic.content.contains("Pin oj 3.13.20 without SSE4.2."))

        let hnSnap = try ForumSnapshot(kind: .hackerNews, mode: .replay)
        let hnNet = hnSnap.makeForumService().net("https://news.ycombinator.com", isPaced: false)
        let hnTopic = try await HackerNewsAdapter().readTopic(
            TopicReadRequest(topic: TopicRef(siteURL: "https://news.ycombinator.com", topicID: "99999901"), cachedPages: [], knownTotalPosts: nil),
            net: hnNet, progress: { _ in }, onPage: nil
        )
        XCTAssertEqual(hnTopic.totalPosts, 2)
        XCTAssertTrue(hnTopic.content.contains("Litestream replicates the WAL"))

        let wpSnap = try ForumSnapshot(kind: .wordpress, mode: .replay)
        let wpNet = wpSnap.makeForumService().net("https://wordpress.fixture.test", isPaced: false)
        let wpTopic = try await WordPressAdapter().readTopic(
            TopicReadRequest(topic: TopicRef(siteURL: "https://wordpress.fixture.test", topicID: "77"), cachedPages: [], knownTotalPosts: nil),
            net: wpNet, progress: { _ in }, onPage: nil
        )
        XCTAssertEqual(wpTopic.totalPosts, 2)
        XCTAssertEqual(wpTopic.facts?.openingPoster, "Will")
        XCTAssertTrue(wpTopic.content.contains("Three hotel nights in one cart"))

        let started = ContinuousClock.now
        let unknown = URL(string: "https://discourse.fixture.test/t/999999.json")!
        do {
            _ = try await discourseNet.data(unknown)
            XCTFail("Expected replay of unknown URL to fail")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, ForumSnapshotError.errorDomain)
            XCTAssertTrue(error.localizedDescription.contains("999999.json"))
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertEqual(discourseSnap.unmatchedURLs, [unknown])
    }

    func testRecordModeTrimsAndReplaysDiscourseHackerNewsAndWordPress() async throws {
        UpstreamStubProtocol.install(routes: Self.untrimmedUpstreamRoutes())
        let upstream = UpstreamStubProtocol.makeSession()

        let dDir = tempDir.appendingPathComponent("discourse", isDirectory: true)
        let dRecord = try ForumSnapshot(kind: .discourse, mode: .record, directory: dDir, upstreamSession: upstream)
        let dNet = dRecord.makeForumService().net("https://meta.example.org", isPaced: false)
        let dSearch = try await DiscourseAdapter().run(.search(text: "sidebar", scope: .forum), net: dNet)
        XCTAssertEqual(dSearch.topics.first?.title, "Sidebar feedback")
        XCTAssertEqual(dRecord.misses.count, 1)
        dRecord.resetMisses()
        _ = try await DiscourseAdapter().run(.search(text: "sidebar", scope: .forum), net: dNet)
        XCTAssertTrue(dRecord.misses.isEmpty)
        let dSaved = try Self.concatenatedFiles(in: dDir)
        for stripped in ["__cf_bm", "grouped_search_result", "avatar_template"] { XCTAssertFalse(dSaved.contains(stripped)) }
        let dReplayed = try await DiscourseAdapter().run(
            .search(text: "sidebar", scope: .forum),
            net: try ForumSnapshot(kind: .discourse, mode: .replay, directory: dDir).makeForumService().net("https://meta.example.org", isPaced: false)
        )
        XCTAssertEqual(dReplayed.topics.map(\.id), [101])
        XCTAssertEqual(dReplayed.hits.first?.username, "sam")

        let hDir = tempDir.appendingPathComponent("hackernews", isDirectory: true)
        let hRecord = try ForumSnapshot(kind: .hackerNews, mode: .record, directory: hDir, upstreamSession: upstream)
        let hNet = hRecord.makeForumService().net("https://news.ycombinator.com", isPaced: false)
        let hInfo = try await HackerNewsAdapter().siteInfo(siteURL: "https://news.ycombinator.com", net: hNet)
        let hComments = try await HackerNewsAdapter().run(.search(text: "Litestream", scope: .comments), net: hNet)
        let hSaved = try Self.concatenatedFiles(in: hDir)
        for stripped in ["_highlightResult", "bloated-script-payload"] { XCTAssertFalse(hSaved.contains(stripped)) }
        let hReplayNet = try ForumSnapshot(kind: .hackerNews, mode: .replay, directory: hDir).makeForumService().net("https://news.ycombinator.com", isPaced: false)
        let hReplayedInfo = try await HackerNewsAdapter().siteInfo(siteURL: "https://news.ycombinator.com", net: hReplayNet)
        let hReplayedComments = try await HackerNewsAdapter().run(.search(text: "Litestream", scope: .comments), net: hReplayNet)
        XCTAssertEqual(hReplayedInfo, hInfo)
        XCTAssertEqual(hReplayedComments.hits.map(\.blurb), hComments.hits.map(\.blurb))

        let wDir = tempDir.appendingPathComponent("wordpress", isDirectory: true)
        let wRecord = try ForumSnapshot(kind: .wordpress, mode: .record, directory: wDir, upstreamSession: upstream)
        let wSearch = try await WordPressAdapter().run(
            .search(text: "Smartly", scope: .forum),
            net: wRecord.makeForumService().net("https://blog.example.com", isPaced: false)
        )
        XCTAssertEqual(wSearch.hits.first?.username, "Chuck")
        let wSaved = try Self.concatenatedFiles(in: wDir)
        XCTAssertFalse(wSaved.contains("https://api.w.org/featuredmedia"))
        XCTAssertFalse(wSaved.contains("wp_secret_cookie"))
        let wReplayed = try await WordPressAdapter().run(
            .search(text: "Smartly", scope: .forum),
            net: try ForumSnapshot(kind: .wordpress, mode: .replay, directory: wDir).makeForumService().net("https://blog.example.com", isPaced: false)
        )
        XCTAssertEqual(wReplayed.topics.map(\.title), ["US Bank Smartly Review"])
        XCTAssertEqual(wReplayed.hits.first?.username, "Chuck")
    }

    func testRecordModeEnforcesPerKindByteCap() async throws {
        UpstreamStubProtocol.install(routes: [
            "https://meta.example.org/raw/1?page=1": (200, ["Content-Type": "text/plain"], Data(String(repeating: "x", count: 1_500).utf8))
        ])
        let snap = try ForumSnapshot(
            kind: .discourse, mode: .record, directory: tempDir.appendingPathComponent("capped", isDirectory: true),
            maxBytes: 512, upstreamSession: UpstreamStubProtocol.makeSession()
        )
        do {
            _ = try await snap.makeForumService().net("https://meta.example.org", isPaced: false)
                .data(URL(string: "https://meta.example.org/raw/1?page=1")!)
            XCTFail("Expected sizeLimitExceeded")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, ForumSnapshotError.errorDomain)
            XCTAssertTrue(error.localizedDescription.contains("512-byte cap"))
        }
        XCTAssertEqual(snap.totalBytes, 0)
    }

    func testFixturePageDriverServesReadPageAndRefusesPageChanges() async throws {
        let saved = FixturePageDriver.SavedPage(
            url: "https://meta.discourse.org/t/introducing-nested-replies/402812",
            title: "Introducing nested replies - announcements - Discourse Meta",
            structure: "[main] Heading: Introducing nested replies",
            text: "Meaningful conversation happens when everyone has heard each other.",
            html: "<article><h1>Introducing nested replies</h1></article>"
        )
        let driver = FixturePageDriver(page: saved)
        let meta = await driver.currentPageMetadata()
        XCTAssertEqual(meta, AgentPageMetadata(url: saved.url, title: saved.title))

        let scriptStore = await MainActor.run {
            ScriptStore(directoryURL: tempDir.appendingPathComponent("scripts", isDirectory: true))
        }
        let registry = ToolRegistry.m3(context: AgentToolContext(bridge: driver, workspace: nil, scriptStore: scriptStore))

        let structureRead = try await registry.dispatch(toolName: "read_page", arguments: [:])
        XCTAssertFalse(structureRead.isError)
        XCTAssertTrue(structureRead.output.contains("Introducing nested replies"))

        let cappedText = try await registry.dispatch(toolName: "read_page", arguments: ["mode": .string("text"), "max_length": .int(23)])
        XCTAssertFalse(cappedText.isError)
        XCTAssertTrue(cappedText.output.contains("truncated"))

        let refused: [(String, [String: JSONValue])] = [
            ("read_page", ["selector": .string("article")]),
            ("run_js", ["code": .string("document.title")]),
            ("inject_css", ["css": .string("body { background: black; }")]),
            ("wait_for", ["ms": .int(50)]),
            ("navigate", ["url": .string("https://meta.discourse.org/latest")]),
            ("reload_page", [:]),
            ("screenshot", [:]),
            ("script_save", ["name": .string("Dark"), "match_rules": .array([.string("https://meta.discourse.org/*")]), "css": .string("body{}")])
        ]
        for (name, args) in refused {
            let res = try await registry.dispatch(toolName: name, arguments: args)
            XCTAssertTrue(res.isError, "Expected \(name) to fail on FixturePageDriver")
        }
    }

    private static func concatenatedFiles(in directory: URL) throws -> String {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    private static func untrimmedUpstreamRoutes() -> [String: (Int, [String: String], Data)] {
        let discourseSearch: [String: Any] = [
            "posts": [["id": 9001, "username": "sam", "avatar_template": "/a.png", "blurb": "Sidebar works.", "post_number": 4, "topic_id": 101]],
            "topics": [["id": 101, "title": "Sidebar feedback", "slug": "sidebar-feedback", "posts_count": 12, "posters": [["user_id": 1]]]],
            "users": [["id": 1, "username": "sam"]], "grouped_search_result": ["more_posts": true]
        ]
        let hnComments: [String: Any] = [
            "hits": [["objectID": "5002", "story_id": 5000, "story_title": "SQLite Backups", "comment_text": "Litestream streams WAL.",
                      "author": "benbjohnson", "created_at": "2026-04-02T08:00:00Z", "parent_id": 5000,
                      "_highlightResult": ["comment_text": ["value": "<em>Litestream</em>"]], "_tags": ["comment"]]]
        ]
        let wpPosts: [[String: Any]] = [[
            "id": 301, "link": "https://blog.example.com/?p=301", "date_gmt": "2026-04-03T09:00:00",
            "title": ["rendered": "US Bank Smartly Review", "raw": "unused"], "excerpt": ["rendered": "<p>Updated.</p>"],
            "_embedded": ["author": [["name": "Chuck", "description": "Bio"]]],
            "_links": ["wp:featuredmedia": [["href": "https://api.w.org/featuredmedia/1"]]]
        ]]
        return [
            "https://meta.example.org/search.json?q=sidebar": (200, ["Content-Type": "application/json", "Set-Cookie": "__cf_bm=secret"], try! JSONSerialization.data(withJSONObject: discourseSearch)),
            "https://news.ycombinator.com": (200, ["Content-Type": "text/html"], Data("<html><script>var x='bloated-script-payload';</script><table id=\"hnmain\"></table></html>".utf8)),
            "https://hn.algolia.com/api/v1/search?tags=comment&query=Litestream&page=0&hitsPerPage=10": (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: hnComments)),
            "https://blog.example.com/wp-json/wp/v2/posts?search=Smartly&per_page=20&page=1&_fields=id,title,link,date_gmt,excerpt,author,_embedded,_links&_embed=author": (200, ["Content-Type": "application/json", "Set-Cookie": "wp_secret_cookie=1"], try! JSONSerialization.data(withJSONObject: wpPosts))
        ]
    }
}

private final class UpstreamStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: (Int, [String: String], Data)] = [:]
    static func install(routes: [String: (Int, [String: String], Data)]) { lock.withLock { self.routes = routes } }
    static func reset() { lock.withLock { routes.removeAll() } }
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpstreamStubProtocol.self]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let (status, headers, data) = Self.lock.withLock({ Self.routes[ForumSnapshot.canonicalURLString(for: url)] }) else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "UpstreamStubProtocol", code: 404))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
