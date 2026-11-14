import Foundation
import XCTest
@testable import WukongMind

@MainActor
final class ForumShapesTests: XCTestCase {
    func testDiscourseListAndThreadShapesFillRequiredAndOptionalFields() async throws {
        let siteURL = "https://meta.discourse.org"
        let rawPage = """
        alice | 2022-10-04 08:15:00 UTC | #1

        How can I hide the Badges link in the sidebar?

        -------------------------

        dave | 2022-10-04 09:00:00 UTC | #2

        Have you checked Admin > Navigation?

        -------------------------

        bob | 2022-10-04 10:30:00 UTC | #5

        You can hide it with `.sidebar-section-link-badges { display: none; }`.
        """
        let net = DiscourseStubNetwork.make(
            siteURL: siteURL, searchJSON: DiscourseFixtures.search, topicJSON: DiscourseFixtures.topic, rawPage: rawPage
        )
        var sessions: [String: TopicSession] = [:]
        let service = ForumToolService(
            sessionLookup: { sessions[$0] }, sessionWrite: { sessions[$0] = $1 }, makeNetwork: { _, _, _ in net }
        )
        let scope = ForumRunScope(adapter: DiscourseAdapter(), siteURL: siteURL, maxTopicReads: 2)

        let search = try await service.search(arguments: ["query": "hide badges sidebar"], scope: scope)
        XCTAssertEqual(search.content, ForumRendering.format(listings: search.topics, hits: search.hits))
        XCTAssertEqual(search.shape.items.count, 2)
        let first = try XCTUnwrap(search.shape.items.first)
        XCTAssertEqual(first.id, "240488")
        XCTAssertEqual(first.title, "How can I hide the Badges link in the sidebar?")
        XCTAssertEqual(first.url, "https://meta.discourse.org/t/how-can-i-hide-the-badges-link-in-the-sidebar/240488")
        XCTAssertEqual(first.postsCount, 11)
        XCTAssertEqual(first.lastActivity, "2022-11-21T09:57:55.135Z")
        XCTAssertEqual(first.hits?.map(\.number), [1, 5, 10])
        XCTAssertEqual(first.hits?.map(\.author), ["alice", "bob", "bob"])
        XCTAssertTrue(first.hits?.allSatisfy { ($0.blurb ?? "").isEmpty == false } == true)

        let read = try await service.readTopic(arguments: ["topic_id": "240488"], scope: scope)
        let thread = read.shape
        XCTAssertEqual(thread.id, "240488")
        XCTAssertEqual(thread.title, "How can I hide the Badges link in the sidebar?")
        XCTAssertEqual(thread.url, "https://meta.discourse.org/t/how-can-i-hide-the-badges-link-in-the-sidebar/240488")
        XCTAssertEqual(thread.totalPosts, 14)
        XCTAssertEqual(thread.posts.map(\.number), [1, 2, 5])
        XCTAssertEqual(thread.posts.map(\.author), ["alice", "dave", "bob"])
        XCTAssertEqual(thread.posts[0].date, "2022-10-04T08:15:00Z")
        XCTAssertTrue(thread.posts[2].body.contains(".sidebar-section-link-badges"))
        XCTAssertNil(thread.posts[0].score)
        XCTAssertNil(thread.posts[0].replyTo)

        let encoded = try JSONEncoder().encode(ForumShape.thread(thread))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"total_posts\":14"))
        XCTAssertEqual(try JSONDecoder().decode(ForumShape.self, from: encoded), .thread(thread))
    }

    func testHackerNewsListCommentAndThreadShapes() async throws {
        let fixture = HackerNewsFixture()
        let adapter = try XCTUnwrap(SiteRegistry.standard.adapter(for: SiteKind("hackernews")))
        var sessions: [String: TopicSession] = [:]
        let service = ForumToolService(
            sessionLookup: { sessions[$0] }, sessionWrite: { sessions[$0] = $1 },
            makeNetwork: { _, _, _ in fixture.network() }
        )
        let scope = ForumRunScope(adapter: adapter, siteURL: HackerNewsFixture.site)

        let stories = try await service.search(arguments: ["query": "sqlite"], scope: scope)
        XCTAssertFalse(stories.shape.items.isEmpty)
        XCTAssertTrue(stories.shape.items.allSatisfy {
            !$0.title.isEmpty && $0.url.hasPrefix("https://news.ycombinator.com/item?id=") && $0.id != nil
        })

        let comments = try await service.searchComments(arguments: ["query": "wal"], scope: scope)
        let commentHits = comments.shape.items.flatMap { $0.hits ?? [] }
        XCTAssertFalse(commentHits.isEmpty)
        XCTAssertTrue(commentHits.allSatisfy { $0.number == nil && ($0.author ?? "").isEmpty == false })

        let latest = try await service.listLatest(scope: scope)
        XCTAssertFalse(latest.shape.items.isEmpty)
        XCTAssertTrue(latest.shape.items.allSatisfy { !$0.title.isEmpty && !$0.url.isEmpty })

        let thread = try await service.readTopic(arguments: ["topic_id": "1"], scope: scope).shape
        XCTAssertEqual(thread.id, "1")
        XCTAssertFalse(thread.title.isEmpty)
        XCTAssertEqual(thread.url, "https://news.ycombinator.com/item?id=1")
        XCTAssertEqual(thread.totalPosts, thread.posts.count)
        XCTAssertFalse(thread.posts.isEmpty)
        XCTAssertTrue(thread.posts.allSatisfy { $0.number >= 1 && !$0.author.isEmpty && !$0.body.isEmpty })
        XCTAssertNotNil(thread.posts.first?.score)
        XCTAssertTrue(thread.posts.contains { $0.replyTo != nil })

        let encoded = try JSONEncoder().encode(thread)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"reply_to\":"))
        XCTAssertEqual(try JSONDecoder().decode(ThreadShape.self, from: encoded), thread)
    }

    func testWordPressListCommentAndThreadShapesBudgetAndFollow() async throws {
        let site = WordPressFixtureSite(comments: [
            WordPressFixtureSite.comment(1, post: 1001, parent: 0, author: "Pat"),
            WordPressFixtureSite.comment(2, post: 1001, parent: 5001, author: "Sam")
        ])
        var sessions: [String: TopicSession] = [:]
        var watched: [String] = []
        let service = ForumToolService(
            sessionLookup: { sessions[$0] }, sessionWrite: { sessions[$0] = $1 },
            makeNetwork: { _, _, _ in site.network() },
            watchTopic: { _, topicID, _, title, _ in watched.append("\(topicID):\(title)") }
        )
        let scope = ForumRunScope(adapter: WordPressAdapter(), siteURL: WordPressFixtureSite.siteURL, maxTopicReads: 1)

        let search = try await service.search(arguments: ["query": "cards"], scope: scope)
        XCTAssertFalse(search.shape.items.isEmpty)
        XCTAssertTrue(search.shape.items.allSatisfy {
            !$0.title.isEmpty && $0.url.hasPrefix("https://example.com/") && $0.id != nil
        })

        let commentSearch = try await service.searchComments(arguments: ["query": "worth"], scope: scope)
        let hits = commentSearch.shape.items.flatMap { $0.hits ?? [] }
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.number == nil && ($0.blurb ?? "").isEmpty == false })

        let thread = try await service.readTopic(arguments: ["topic_id": WordPressFixtureSite.postID], scope: scope).shape
        XCTAssertEqual(thread.id, "1001")
        XCTAssertEqual(thread.title, "(Update) Sample Cards & Notes – Part 1")
        XCTAssertEqual(thread.url, "https://example.com/2026/05/sample-cards-and-notes/")
        XCTAssertEqual(thread.totalPosts, 3)
        XCTAssertEqual(thread.posts.map(\.number), [1, 2, 3])
        XCTAssertEqual(thread.posts.map(\.author), ["alice", "Pat", "Sam"])
        XCTAssertTrue(thread.posts[0].body.contains("Opening post: the card is offering 10x"))
        XCTAssertNil(thread.posts[1].replyTo)
        XCTAssertEqual(thread.posts[2].replyTo, 2)
        XCTAssertEqual(thread.posts[0].date, "2026-05-14T16:00:00Z")

        // Cached re-read skips the network and budget; reading a second topic hits the budget.
        let countAfterFirstRead = site.requests.count
        _ = try await service.readTopic(arguments: ["topic_id": "1001", "page": "1"], scope: scope)
        XCTAssertEqual(site.requests.count, countAfterFirstRead)
        do {
            _ = try await service.readTopic(arguments: ["topic_id": "2002"], scope: scope)
            XCTFail("Expected topicBudgetExhausted")
        } catch let error as AgentError {
            if case .topicBudgetExhausted(let limit) = error {
                XCTAssertEqual(limit, 1)
            } else {
                XCTFail("Expected topicBudgetExhausted, got \(error)")
            }
        }

        let followed = try await service.follow(arguments: ["topic_id": "1001"], scope: scope)
        XCTAssertEqual(followed.outcome, "Watching")
        XCTAssertEqual(watched, ["1001:(Update) Sample Cards & Notes – Part 1"])
    }

    func testToolRegistryCarriesShapeAndM3RecordsWithoutShapeStillDecode() async throws {
        let list = ListShape(items: [
            .init(id: "42", title: "Hello Forum", url: "https://forum.example.com/item?id=42", postsCount: 5)
        ])
        var registry = ToolRegistry()
        registry.register(AgentTool(
            definition: AgentToolDefinition(name: "search_forum", description: "Search", parameters: []),
            summarizeArguments: { _ in "" },
            execute: { _ in ToolExecutionOutput(content: "- id 42: Hello Forum", summary: "1 thread", shape: .list(list)) }
        ))
        let dispatched = try await registry.dispatch(toolName: "search_forum", arguments: [:])
        XCTAssertEqual(dispatched.shape, .list(list))

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/TaskExports/read-headline.json")
        let m3Export = try TaskExport.load(try Data(contentsOf: fixtureURL))
        let m3Results = m3Export.turns.flatMap(\.toolResults)
        XCTAssertFalse(m3Results.isEmpty)
        XCTAssertTrue(m3Results.allSatisfy { $0.shape == nil })

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wukong-m3-shape-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let taskID = "m3-compat"
        let legacyLines = [
            #"{"fields":{"model":"claude-sonnet-5-5","pageURL":"https://forum.example.com","prompt":"Check forum","provider":"Anthropic","stepLimit":5,"truncationLimit":20000},"time":"2026-11-10T01:00:00Z","type":"task"}"#,
            #"{"fields":{"turns":[{"user":{"_0":"Check forum"}}]},"time":"2026-11-10T01:00:01Z","type":"history"}"#,
            #"{"fields":{"historyCount":1,"pageURL":"https://forum.example.com","systemHash":"s1","toolsHash":"t1","turn":1},"time":"2026-11-10T01:00:02Z","type":"request"}"#,
            #"{"fields":{"model":"claude-sonnet-5-5","provider":"Anthropic","response":{"stopReason":"toolUse","text":"","toolCalls":[{"arguments":{},"id":"c1","name":"read_page"}],"usage":{"inputTokens":10,"outputTokens":5}}},"time":"2026-11-10T01:00:03Z","type":"response"}"#,
            #"{"fields":{"arguments":{},"callID":"c1","images":[],"isError":false,"name":"read_page","output":"Headline","resultSummary":"Headline","totalCharacterCount":8,"wasTruncated":false},"time":"2026-11-10T01:00:04Z","type":"tool_result"}"#
        ].joined(separator: "\n") + "\n"
        try Data(legacyLines.utf8).write(to: folder.appendingPathComponent("\(taskID).jsonl"))

        let store = TaskRecordStore(directory: folder)
        await store.append(taskID: taskID, .request(
            turn: 2, historyCount: 3, systemHash: "s1", toolsHash: "t1",
            pageURL: "https://forum.example.com", time: Date(timeIntervalSince1970: 1_794_272_410)
        ))
        let searchCall = AgentModelToolCall(id: "c2", name: "search_forum", arguments: [:])
        await store.append(taskID: taskID, .response(
            AgentModelTurnResponse(text: "", toolCalls: [searchCall], stopReason: "toolUse", usage: .zero),
            model: "claude-sonnet-5-5", provider: "Anthropic", time: Date(timeIntervalSince1970: 1_794_272_411)
        ))
        await store.append(taskID: taskID, .toolResult(
            call: searchCall, output: "- id 42: Hello Forum", isError: false, duration: 0.1,
            wasTruncated: false, totalCharacterCount: 20, savedPath: nil, resultSummary: "1 thread",
            shape: .list(list), time: Date(timeIntervalSince1970: 1_794_272_412)
        ))

        let built = try TaskExport.build(
            events: await store.events(taskID: taskID), secrets: [], cookies: [],
            app: .init(version: "1.3.0", build: "1"), now: Date(timeIntervalSince1970: 1_794_272_420)
        )
        let exported = try TaskExport.load(built.data)
        XCTAssertEqual(exported.turns.count, 2)
        XCTAssertNil(exported.turns[0].toolResults.first?.shape)
        XCTAssertEqual(exported.turns[1].toolResults.first?.shape, .list(list))

        let replay = ReplayToolDispatcher(exported)
        let replayedLegacy = try await replay.dispatch(toolName: "read_page", arguments: [:], step: 1)
        XCTAssertNil(replayedLegacy.shape)
        let replayedForum = try await replay.dispatch(toolName: "search_forum", arguments: [:], step: 2)
        XCTAssertEqual(replayedForum.shape, .list(list))
    }
}

private enum DiscourseStubNetwork {
    private final class ProtocolStub: URLProtocol {
        nonisolated(unsafe) static var handler: (@Sendable (URL) -> (Int, Data, String))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
            }
            let (status, body, type) = handler(url)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    static func make(siteURL: String, searchJSON: String, topicJSON: String, rawPage: String) -> SiteNetwork {
        ProtocolStub.handler = { url in
            if url.path.hasSuffix("/search.json") { return (200, Data(searchJSON.utf8), "application/json") }
            if url.path.contains("/raw/") { return (200, Data(rawPage.utf8), "text/plain; charset=utf-8") }
            return (200, Data(topicJSON.utf8), "application/json")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProtocolStub.self]
        return ForumService(session: URLSession(configuration: config)).net(siteURL, pace: .fast)
    }
}
