import Foundation
import XCTest
@testable import WukongMind

@MainActor
final class ForumToolsTests: XCTestCase {
    private let pageDriver = FixturePageDriver(
        page: .init(url: "https://meta.discourse.org", title: "Meta", structure: "main", text: "Meta")
    )

    private func makeTempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wukong-forum-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeRegistry(
        forum: ForumToolContext?, workspace: AgentWorkspace? = nil, taskID: String? = nil,
        truncationLimit: Int = ToolRegistry.defaultTruncationLimit, secrets: [String] = []
    ) throws -> ToolRegistry {
        let dir = try makeTempFolder()
        let scriptStore = ScriptStore(directoryURL: dir.appendingPathComponent("scripts", isDirectory: true))
        var registry = ToolRegistry.m3(context: AgentToolContext(
            bridge: pageDriver, workspace: workspace, scriptStore: scriptStore,
            settings: AgentToolSettings(truncationLimit: truncationLimit, redactedSecrets: secrets), forum: forum
        ))
        registry.taskID = taskID
        return registry
    }

    // MARK: - Presence & Mid-Run Stability

    func testPresenceGatingByPageStateAndPlatformAndMidRunNavigation() async throws {
        let dir = try makeTempFolder()
        let store = PersistentStore(fileURL: dir.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let wp = WordPressFixtureSite(commentCount: 2)
        let app = AppModel(
            store: store, forumService: wp.service(), sites: SiteRegistry.standard,
            aiService: StateAIStub(), workspaceDirectory: dir.appendingPathComponent("ws", isDirectory: true)
        )
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil

        let forumNames: Set<String> = [
            ForumToolName.searchForum, ForumToolName.searchComments, ForumToolName.listLatest, ForumToolName.readTopic
        ]
        func activeForumTools() throws -> [String] {
            try makeRegistry(forum: app.makeForumToolContext()).definitions.map(\.name).filter { forumNames.contains($0) }
        }

        for ctx in [
            PageContext(url: nil, state: .loading),
            PageContext(url: URL(string: "https://example.org"), state: .notForum),
            PageContext(url: URL(string: "https://meta.discourse.org/t/slug/42"), siteURL: "https://meta.discourse.org", state: .maybe)
        ] {
            app.browser.setPageContext(ctx)
            XCTAssertEqual(try activeForumTools(), [])
        }

        for state in [PageContext.State.forumHome, .topic] {
            app.browser.setPageContext(PageContext(
                url: URL(string: "https://meta.discourse.org"), site: .discourse,
                siteURL: "https://meta.discourse.org", forumName: "Meta", state: state
            ))
            XCTAssertEqual(try activeForumTools(), ["search_forum", "list_latest", "read_topic"])
        }

        for (kind, siteURL) in [(SiteKind("hackernews"), "https://news.ycombinator.com"), (.wordpress, WordPressFixtureSite.siteURL)] {
            for state in [PageContext.State.forumHome, .topic] {
                app.browser.setPageContext(PageContext(url: URL(string: siteURL), site: kind, siteURL: siteURL, state: state))
                XCTAssertEqual(try activeForumTools(), ["search_forum", "search_comments", "list_latest", "read_topic"])
            }
        }

        // A BrowserAgentSession run keeps its starting forum across mid-run page changes, then re-evaluates next run.
        app.browser.setPageContext(PageContext(
            url: URL(string: WordPressFixtureSite.siteURL), site: .wordpress,
            siteURL: WordPressFixtureSite.siteURL, forumName: "Example Blog", state: .forumHome
        ))
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(
                text: "", toolCalls: [AgentModelToolCall(id: "c1", name: "list_latest", arguments: [:])], stopReason: "tool_use"
            )),
            .success(AgentModelTurnResponse(text: "Listed latest threads."))
        ])
        client.onRequest = { [weak app] turn in
            if turn == 1 {
                await MainActor.run {
                    app?.browser.setPageContext(PageContext(url: URL(string: "https://example.org"), state: .notForum))
                }
            }
        }
        let session = BrowserAgentSession(
            pageDriver: pageDriver, modelClient: client,
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .ollama, model: "m"),
                    configuration: ProviderConfiguration(model: "m", baseURL: "http://127.0.0.1:11434", apiKey: ""),
                    maxSteps: 5, truncationLimit: 20_000, customInstructions: "", redactedSecrets: []
                )
            },
            registryBuilder: { [unowned app] bridge, limit, secrets in
                ToolRegistry.m3(context: AgentToolContext(
                    bridge: bridge, workspace: app.agentWorkspace, scriptStore: app.scriptStore,
                    settings: AgentToolSettings(truncationLimit: limit, redactedSecrets: secrets),
                    forum: app.makeForumToolContext()
                ))
            }
        )
        session.send("What is new?")
        let deadline = Date().addingTimeInterval(5)
        while session.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(client.recordedRequests.count, 2)
        XCTAssertTrue(client.recordedRequests[0].tools.contains { $0.name == "list_latest" })
        XCTAssertTrue(client.recordedRequests[1].tools.contains { $0.name == "list_latest" })
        XCTAssertEqual(session.messages.last?.text, "Listed latest threads.")

        client.append(.success(AgentModelTurnResponse(text: "Plain page.")))
        session.send("Check again")
        while session.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let nextRunTools = try XCTUnwrap(client.recordedRequests.last?.tools).map(\.name)
        XCTAssertTrue(forumNames.isDisjoint(with: nextRunTools))
    }

    // MARK: - Schemas (SiteGoldenTests port) & ToolRow Labels

    func testSchemasFromAdapterProfilesAndToolRowLabels() async throws {
        var sessions: [String: TopicSession] = [:]
        let wp = WordPressFixtureSite(commentCount: 1)
        let service = ForumToolService(
            sessionLookup: { sessions[$0] }, sessionWrite: { sessions[$0] = $1 }, makeNetwork: { _, _, _ in wp.network() }
        )

        let discourseReg = try makeRegistry(forum: ForumToolContext(
            service: service, scope: ForumRunScope(adapter: DiscourseAdapter(), siteURL: "https://example.com/forum"),
            forumName: "Example Forum"
        ))
        let dSearch = try XCTUnwrap(discourseReg.tool(named: "search_forum")?.definition)
        XCTAssertEqual(dSearch.parameters.map(\.name), ["query"])
        XCTAssertEqual(dSearch.parameters.map(\.type), [.string])
        XCTAssertEqual(dSearch.required, ["query"])
        XCTAssertFalse(dSearch.additionalProperties)
        XCTAssertNil(discourseReg.tool(named: "search_comments"))
        let unknownComments = try await discourseReg.dispatch(toolName: "search_comments", arguments: ["query": .string("x")])
        XCTAssertTrue(unknownComments.isError && unknownComments.output.contains("Unknown tool 'search_comments'"))

        let hnAdapter = try XCTUnwrap(SiteRegistry.standard.adapter(for: SiteKind("hackernews")))
        let hnReg = try makeRegistry(forum: ForumToolContext(
            service: service, scope: ForumRunScope(adapter: hnAdapter, siteURL: HackerNewsFixture.site), forumName: "Hacker News"
        ))
        for name in ["search_forum", "search_comments"] {
            let def = try XCTUnwrap(hnReg.tool(named: name)?.definition)
            XCTAssertEqual(def.parameters.map(\.name), ["query", "page"])
            XCTAssertEqual(def.parameters.map(\.type), [.string, .integer])
            XCTAssertEqual(def.required, ["query"])
        }

        let wpReg = try makeRegistry(forum: ForumToolContext(
            service: service, scope: ForumRunScope(adapter: WordPressAdapter(), siteURL: WordPressFixtureSite.siteURL),
            forumName: "Example Blog"
        ))
        let wpSearch = try XCTUnwrap(wpReg.tool(named: "search_forum")?.definition)
        XCTAssertEqual(wpSearch.parameters.map(\.name), ["query", "category", "after", "before", "page"])
        XCTAssertEqual(wpSearch.parameters.map(\.type), [.string, .string, .string, .string, .integer])
        XCTAssertEqual(wpSearch.required, ["query"])

        let readDef = try XCTUnwrap(wpReg.tool(named: "read_topic")?.definition)
        XCTAssertEqual(readDef.parameters.map(\.name), ["topic_id", "url", "page", "query"])
        XCTAssertEqual(readDef.parameters.map(\.type), [.string, .string, .integer, .string])
        XCTAssertEqual(readDef.required, [])

        let badPageType = try await wpReg.dispatch(
            toolName: "search_forum", arguments: ["query": .string("cards"), "page": .string("2")]
        )
        XCTAssertTrue(badPageType.isError && badPageType.output.contains("parameter 'page' must be an integer"))

        for (tool, runningLabel, doneLabel) in [
            ("search_forum", String(localized: "Searching forum"), String(localized: "Searched forum")),
            ("search_comments", String(localized: "Searching comments"), String(localized: "Searched comments")),
            ("list_latest", String(localized: "Listing latest"), String(localized: "Listed latest")),
            ("read_topic", String(localized: "Reading thread"), String(localized: "Read thread"))
        ] {
            XCTAssertEqual(DCToolLabel.browser(tool, running: true), runningLabel)
            XCTAssertEqual(DCToolLabel.browser(tool, running: false), doneLabel)
        }
    }

    // MARK: - Discourse Sequence & Post-Level Coverage (SiteRequestSequenceTests + PostLevelTests port)

    func testDiscourseRequestSequencePostHitsAndInTopicQueryLookup() async throws {
        let siteURL = "https://forum.example/forum"
        let recorder = DiscourseRecorder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscourseRecorderProtocol.self]
        DiscourseRecorderProtocol.recorder = recorder
        addTeardownBlock { DiscourseRecorderProtocol.recorder = nil }

        let forumService = ForumService(
            session: URLSession(configuration: config), pacer: ForumRequestPacer(clock: InstantPacingClock())
        )
        var sessions: [String: TopicSession] = [:]
        let service = ForumToolService(
            sessionLookup: { sessions[$0] }, sessionWrite: { sessions[$0] = $1 },
            makeNetwork: { url, pace, _ in forumService.net(url, pace: pace) }
        )
        let scope = ForumRunScope(adapter: DiscourseAdapter(), siteURL: siteURL, maxTopicReads: 3)
        let registry = try makeRegistry(forum: ForumToolContext(service: service, scope: scope, forumName: "Sequence Forum"))

        let searchResult = try await registry.dispatch(
            toolName: "search_forum", arguments: ["query": .string("badges topic:240488")]
        )
        XCTAssertFalse(searchResult.isError)
        XCTAssertEqual(recorder.requests, ["forum.example/forum/search.json?q=badges%20topic:240488"])
        XCTAssertEqual(searchResult.resultSummary, "2 threads")
        for line in [
            "- id 240488: How can I hide the Badges link in the sidebar? — 11 posts",
            "  #1 @alice: I imagine", "  #5 @bob: Hello, You can hide it", "  #10 @bob: ",
            "- id 415035: ", "  #13 @carol: "
        ] {
            XCTAssertTrue(searchResult.output.contains(line), "Missing: \(line)")
        }
        XCTAssertTrue(searchResult.modelContent.hasPrefix("<untrusted_web_content tool=\"search_forum\">"))
        if case .list(let list)? = searchResult.shape {
            XCTAssertEqual(list.items.map(\.id), ["240488", "415035"])
            XCTAssertEqual(list.items[0].hits?.map(\.number), [1, 5, 10])
        } else {
            XCTFail("Expected .list shape")
        }

        recorder.clear()
        let readResult = try await registry.dispatch(toolName: "read_topic", arguments: ["topic_id": .string("123")])
        XCTAssertFalse(readResult.isError, readResult.output)
        XCTAssertEqual(recorder.requests, [
            "forum.example/forum/t/123.json", "forum.example/forum/t/123.json",
            "forum.example/forum/raw/123?page=1", "forum.example/forum/raw/123?page=2", "forum.example/forum/raw/123?page=3"
        ])
        XCTAssertEqual(readResult.resultSummary, "250 posts")
        if case .thread(let thread)? = readResult.shape {
            XCTAssertEqual(thread.id, "123")
            XCTAssertEqual(thread.totalPosts, 250)
        } else {
            XCTFail("Expected .thread shape")
        }

        recorder.clear()
        let byURL = try await registry.dispatch(
            toolName: "read_topic", arguments: ["url": .string("https://forum.example/forum/t/topic-123/123/5")]
        )
        XCTAssertFalse(byURL.isError, byURL.output)
        XCTAssertEqual(recorder.requests, [])
        XCTAssertEqual(scope.topicIDs, ["123"])

        let foreignURL = try await registry.dispatch(
            toolName: "read_topic", arguments: ["url": .string("https://other.example/forum/t/topic-123/123")]
        )
        XCTAssertTrue(foreignURL.isError && foreignURL.output.contains("must be a thread URL on \(siteURL)."))

        recorder.clear()
        _ = try await registry.dispatch(toolName: "read_topic", arguments: ["topic_id": .string("240488")])
        recorder.clear()
        let postLookupRead = try await registry.dispatch(
            toolName: "read_topic", arguments: ["topic_id": .string("240488"), "query": .string("sidebar-section-link-badges")]
        )
        XCTAssertFalse(postLookupRead.isError, postLookupRead.output)
        XCTAssertTrue(postLookupRead.output.contains("bob | #5") && postLookupRead.output.contains(".sidebar-section-link-badges"))
        XCTAssertTrue(recorder.requests.contains { $0.contains("/t/240488/posts.json?") })
    }

    // MARK: - Hacker News Tools & Shapes

    func testHackerNewsToolsShapesAndUntrustedWrapping() async throws {
        let fixture = HackerNewsFixture()
        let adapter = try XCTUnwrap(SiteRegistry.standard.adapter(for: SiteKind("hackernews")))
        var sessions: [String: TopicSession] = [:]
        let service = ForumToolService(
            sessionLookup: { sessions[$0] }, sessionWrite: { sessions[$0] = $1 }, makeNetwork: { _, _, _ in fixture.network() }
        )
        let scope = ForumRunScope(adapter: adapter, siteURL: HackerNewsFixture.site)
        let registry = try makeRegistry(forum: ForumToolContext(service: service, scope: scope, forumName: "Hacker News"))

        let stories = try await registry.dispatch(
            toolName: "search_forum", arguments: ["query": .string("sqlite"), "page": .int(1)]
        )
        XCTAssertFalse(stories.isError)
        XCTAssertTrue(stories.modelContent.hasPrefix("<untrusted_web_content tool=\"search_forum\">"))
        if case .list(let list)? = stories.shape { XCTAssertFalse(list.items.isEmpty) } else { XCTFail("Expected .list") }

        let comments = try await registry.dispatch(toolName: "search_comments", arguments: ["query": .string("wal")])
        XCTAssertFalse(comments.isError)
        XCTAssertFalse(comments.output.contains(ForumRendering.unnumberedHitsNote), "the note is a trusted tool note now")
        XCTAssertEqual(comments.notes, [.unnumberedHits])
        XCTAssertTrue(comments.modelContent.hasPrefix("\(ToolNote.label) \(ForumRendering.unnumberedHitsNote)\n<untrusted_web_content"))
        XCTAssertTrue(comments.resultSummary.contains("comment"))

        let latest = try await registry.dispatch(toolName: "list_latest", arguments: [:])
        XCTAssertFalse(latest.isError)
        if case .list(let list)? = latest.shape { XCTAssertFalse(list.items.isEmpty) } else { XCTFail("Expected .list") }

        let story = try await registry.dispatch(
            toolName: "read_topic", arguments: ["url": .string("https://news.ycombinator.com/item?id=1")]
        )
        XCTAssertFalse(story.isError, story.output)
        if case .thread(let thread)? = story.shape {
            XCTAssertEqual(thread.id, "1")
            XCTAssertEqual(thread.posts.count, thread.totalPosts)
        } else {
            XCTFail("Expected .thread")
        }
    }

    // MARK: - WordPress Port (WordPressAgentRunTests) & Topic Budget

    func testWordPressToolsErrorsPagingAndBudget() async throws {
        let wp = WordPressFixtureSite(comments: [
            ["id": 6001, "post": 1002, "parent": 0, "author_name": "carol", "date_gmt": "2026-06-02T10:00:00",
             "content": ["rendered": "<p>Booked it with points</p>"]]
        ] + (1...250).map { WordPressFixtureSite.comment($0) })
        var sessions: [String: TopicSession] = [:]
        let service = ForumToolService(
            sessionLookup: { sessions[$0] }, sessionWrite: { sessions[$0] = $1 }, makeNetwork: { _, _, _ in wp.network() }
        )
        var maxReads = 1
        let scope = ForumRunScope(
            adapter: WordPressAdapter(), siteURL: WordPressFixtureSite.siteURL, readBudget: { maxReads }, readLimit: 10_000
        )
        let registry = try makeRegistry(
            forum: ForumToolContext(service: service, scope: scope, forumName: "Example Blog"), truncationLimit: 100_000
        )

        let comments = try await registry.dispatch(toolName: "search_comments", arguments: ["query": .string("points")])
        XCTAssertFalse(comments.isError, comments.output)
        XCTAssertTrue(comments.output.contains("- id 1002: Hotel Points Guide"))
        XCTAssertTrue(comments.output.contains("@carol (2026-06-02): Booked it with points"))
        XCTAssertTrue(scope.visitedTopics.contains { $0.topicID == "1002" })

        let latest = try await registry.dispatch(toolName: "list_latest", arguments: [:])
        XCTAssertEqual(latest.resultSummary, "3 threads")
        XCTAssertTrue(scope.visitedTopics.contains { $0.topicID == "1003" })

        wp.respond { req in
            req.path.hasSuffix("/comments") && req.query["search"] != nil
                ? WordPressFixtureSite.Reply(status: 403, body: Data("{}".utf8))
                : nil
        }
        let closed = try await registry.dispatch(toolName: "search_comments", arguments: ["query": .string("approved")])
        XCTAssertTrue(closed.isError && closed.output.contains(
            "COMMENTS_UNAVAILABLE: This site does not allow searching comments. Use search_forum and read_topic instead."
        ))
        wp.respond { _ in nil }

        let recovered = try await registry.dispatch(toolName: "search_forum", arguments: ["query": .string("cards")])
        XCTAssertTrue(!recovered.isError && recovered.output.hasPrefix("- id 1001:"))

        let badDate = try await registry.dispatch(
            toolName: "search_forum", arguments: ["query": .string("x"), "after": .string("last year")]
        )
        XCTAssertTrue(badDate.isError && badDate.output.contains("Invalid argument \"after\": use the form YYYY-MM-DD."))

        let badCategory = try await registry.dispatch(
            toolName: "search_forum", arguments: ["query": .string("x"), "category": .string("nothing")]
        )
        XCTAssertTrue(badCategory.isError && badCategory.output.contains("no category matches \"nothing\""))

        let missingArg = try await registry.dispatch(toolName: "read_topic", arguments: [:])
        XCTAssertTrue(missingArg.isError && missingArg.output.contains("Missing argument \"topic_id\"."))

        let missingPost = try await registry.dispatch(toolName: "read_topic", arguments: ["topic_id": .string("999")])
        XCTAssertTrue(missingPost.isError)

        let initialRead = try await registry.dispatch(toolName: "read_topic", arguments: ["topic_id": .string("1001")])
        XCTAssertFalse(initialRead.isError, initialRead.output)
        XCTAssertTrue(initialRead.output.contains("Article: (Update) Sample Cards & Notes – Part 1"))
        XCTAssertTrue(initialRead.output.contains("#251\nComment number 250 "))
        XCTAssertTrue(initialRead.output.contains("pass page=2 to 3 or query=\"<keywords>\" to read other parts."))
        XCTAssertEqual(scope.topicIDs, ["1001"])

        let countBeforePaging = wp.requests.count
        let page2 = try await registry.dispatch(
            toolName: "read_topic", arguments: ["topic_id": .string("1001"), "page": .int(2)]
        )
        XCTAssertTrue(page2.output.contains("Showing: page 2 of 3") && page2.output.contains("#150\nComment number 149 "))
        XCTAssertFalse(page2.output.contains("#251\nComment number 250 "))
        XCTAssertEqual(wp.requests.count, countBeforePaging)

        let queried = try await registry.dispatch(
            toolName: "read_topic", arguments: ["topic_id": .string("1001"), "query": .string("user145")]
        )
        XCTAssertTrue(queried.output.contains("Showing: 1 matching post for \"user145\" (of 251 posts)"))
        XCTAssertTrue(queried.output.contains("Article: (Update) Sample Cards & Notes – Part 1"))
        XCTAssertTrue(queried.output.contains("#146\nComment number 145 "))

        let invalidPage = try await registry.dispatch(
            toolName: "read_topic", arguments: ["topic_id": .string("1001"), "page": .int(5)]
        )
        XCTAssertTrue(invalidPage.isError && invalidPage.output.contains("Invalid argument \"page\": use a number from 1 to 3."))

        let exhausted = try await registry.dispatch(toolName: "read_topic", arguments: ["topic_id": .string("2002")])
        XCTAssertTrue(exhausted.isError)
        XCTAssertEqual(exhausted.output, "Error: \(AgentError.topicBudgetExhausted(1).modelDescription)")

        maxReads = 2
        let allowed = try await registry.dispatch(toolName: "read_topic", arguments: ["topic_id": .string("2002")])
        XCTAssertFalse(allowed.isError, allowed.output)
        XCTAssertEqual(scope.topicIDs, ["1001", "2002"])
    }

    // MARK: - Long Threads in Workspace & Fallback

    func testLongThreadSavesToWorkspaceAndFallsBackWithoutWorkspace() async throws {
        let secret = "sk-live-secret-999"
        let wp = WordPressFixtureSite(comments: (1...30).map { index -> [String: Any] in
            let html = index == 15
                ? "<p>Middle diagnostic note \(String(repeating: "x", count: 80)) key=\(secret)</p>"
                : "<p>Reply body \(index) \(String(repeating: "y", count: 80))</p>"
            return [
                "id": 5000 + index, "post": 1001, "parent": 0, "author_name": "user\(index)",
                "date_gmt": String(format: "2026-05-14T10:%02d:05", index),
                "content": ["rendered": html]
            ]
        })
        var sessions: [String: TopicSession] = [:]
        let service = ForumToolService(
            sessionLookup: { sessions[$0] }, sessionWrite: { sessions[$0] = $1 }, makeNetwork: { _, _, _ in wp.network() }
        )
        let scope = ForumRunScope(adapter: WordPressAdapter(), siteURL: WordPressFixtureSite.siteURL, maxTopicReads: 5)
        let forum = ForumToolContext(service: service, scope: scope, forumName: "Example Blog")

        let wsDir = try makeTempFolder()
        let workspace = AgentWorkspace(root: wsDir)
        let registryWithWS = try makeRegistry(
            forum: forum, workspace: workspace, taskID: "task-42", truncationLimit: 1_400, secrets: [secret]
        )

        let savedRead = try await registryWithWS.dispatch(
            toolName: "read_topic", arguments: ["topic_id": .string("1001")], step: 7
        )
        XCTAssertFalse(savedRead.isError, savedRead.output)
        XCTAssertFalse(savedRead.wasTruncated)
        XCTAssertEqual(savedRead.savedPath, "results/task-42/07-read_topic.txt")
        XCTAssertEqual(savedRead.resultSummary, "saved to results/task-42/07-read_topic.txt")
        XCTAssertTrue(savedRead.output.hasPrefix("Topic: (Update) Sample Cards & Notes – Part 1\nURL: "))
        XCTAssertTrue(savedRead.output.contains("Full thread: 31 posts, "))
        XCTAssertTrue(savedRead.output.contains("characters, saved to results/task-42/07-read_topic.txt"))
        XCTAssertTrue(savedRead.output.contains("Article: (Update) Sample Cards & Notes – Part 1"))
        XCTAssertTrue(savedRead.output.contains("[Older middle replies omitted"))
        XCTAssertTrue(savedRead.output.contains("#31\nReply body 30"))
        XCTAssertTrue(savedRead.output.hasSuffix("Read any part with file_read(path, offset)."))
        XCTAssertFalse(savedRead.output.contains(secret))
        if case .thread(let thread)? = savedRead.shape { XCTAssertEqual(thread.posts.count, 31) } else { XCTFail("Expected .thread") }

        let diskText = try String(contentsOf: wsDir.appendingPathComponent("results/task-42/07-read_topic.txt"), encoding: .utf8)
        XCTAssertEqual(RawTopicFormat.postBlocks(diskText).count, 31)
        XCTAssertTrue(diskText.contains("[REDACTED_API_KEY]") && !diskText.contains(secret))

        let slice = try await registryWithWS.dispatch(
            toolName: "file_read",
            arguments: ["path": .string("results/task-42/07-read_topic.txt"), "offset": .int(1_400), "length": .int(1_200)]
        )
        XCTAssertTrue(!slice.isError && slice.output.contains("Middle diagnostic note"))

        let registryNoWS = try makeRegistry(forum: forum, workspace: nil, taskID: nil, truncationLimit: 1_400, secrets: [secret])
        let fallbackRead = try await registryNoWS.dispatch(
            toolName: "read_topic", arguments: ["topic_id": .string("1001")], step: 8
        )
        XCTAssertNil(fallbackRead.savedPath)
        XCTAssertFalse(fallbackRead.wasTruncated)
        XCTAssertEqual(fallbackRead.resultSummary, "31 posts")
        XCTAssertFalse(fallbackRead.output.contains("saved to results/"))
        XCTAssertFalse(fallbackRead.output.contains("Read any part with file_read"))
        XCTAssertTrue(fallbackRead.output.contains("Article: (Update) Sample Cards & Notes – Part 1"))
        XCTAssertTrue(fallbackRead.output.contains("[Older middle replies omitted"))
        XCTAssertTrue(fallbackRead.output.contains("#31\nReply body 30"))

        let shortRead = try await registryWithWS.dispatch(
            toolName: "read_topic", arguments: ["topic_id": .string("2002")], step: 9
        )
        XCTAssertNil(shortRead.savedPath)
        XCTAssertEqual(shortRead.resultSummary, "1 post")
        XCTAssertFalse(shortRead.output.contains("Full thread:"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wsDir.appendingPathComponent("results/task-42/09-read_topic.txt").path))
    }
}

// MARK: - Discourse Fixture Recorder

private final class DiscourseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var requests: [String] { lock.withLock { recorded } }
    func clear() { lock.withLock { recorded.removeAll() } }

    func respond(_ url: URL) -> (Int, String) {
        lock.withLock {
            let raw = url.absoluteString
            recorded.append(raw.hasPrefix("https://") ? String(raw.dropFirst("https://".count)) : raw)
        }
        guard url.path.hasPrefix("/forum") else { return (404, "") }
        let parts = String(url.path.dropFirst("/forum".count)).split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if parts == ["search.json"] { return (200, DiscourseFixtures.search) }
        if parts == ["t", "123.json"] {
            return (200, """
            {"id":123,"title":"Topic 123","slug":"topic-123","posts_count":250,"highest_post_number":250,
             "details":{"created_by":{"username":"alice"}},
             "post_stream":{"stream":[1001,1002],"posts":[{"id":1001,"post_number":1,"username":"alice","like_count":2}]}}
            """)
        }
        if parts == ["t", "240488.json"] {
            return (200, """
            {"id":240488,"title":"How can I hide the Badges link in the sidebar?","slug":"how-can-i-hide-the-badges-link-in-the-sidebar",
             "posts_count":205,"highest_post_number":205,"details":{"created_by":{"username":"alice"}},
             "post_stream":{"stream":[1172719,1172723,1198342],"posts":[
               {"id":1172719,"post_number":1,"username":"alice","like_count":2},
               {"id":1172723,"post_number":5,"username":"bob","like_count":6},
               {"id":1198342,"post_number":10,"username":"bob","like_count":1}]}}
            """)
        }
        if parts.count == 3, parts[0] == "t", parts[2] == "posts.json" { return (200, DiscourseFixtures.posts) }
        if parts.count == 2, parts[0] == "raw" {
            let page = query.first { $0.name == "page" }?.value ?? "1"
            return (200, "alice | 2026-10-20 10:00:00 UTC | #\(page)\n\nPage \(page) of topic \(parts[1])")
        }
        return (404, "")
    }
}

private final class DiscourseRecorderProtocol: URLProtocol {
    nonisolated(unsafe) static var recorder: DiscourseRecorder?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let recorder = Self.recorder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let (status, body) = recorder.respond(url)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
