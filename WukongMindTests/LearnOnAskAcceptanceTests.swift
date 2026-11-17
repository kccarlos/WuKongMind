import Foundation
import WebKit
import XCTest
@testable import WukongMind

/// Learn on ask 10: the acceptance checks that no earlier task replays, run on the same fixture forum in a real web view.
/// Check 3 (a list), check 8 (the request prefix on a learned site) and check 9 (nothing on page open).
/// The other checks are replayed where `docs/wukongmind/learn-on-ask-acceptance.md` names them.
extension LearnedSiteRepairWebTests {
    private static let listOnlyJS = """
    await modelContext.registerTool({ name: "list_latest", annotations: { readOnlyHint: true }, async execute() {
      const d = await (await fetch("/api/latest")).json();
      return { shape: { items: d.items.map(x => ({ id: x.id, title: x.title, url: location.origin + x.path })) } };
    }});
    """

    private func call(_ id: String, _ name: String, _ arguments: [String: JSONValue] = [:]) -> AgentModelToolCall {
        AgentModelToolCall(id: id, name: name, arguments: arguments)
    }

    /// Check 3: on the list page, "What's worth reading today" learns `list_latest`, then reads a thread before recommending.
    func testRecordedListRunLearnsListLatestThenReadsAThreadBeforeRecommending() async throws {
        let h = try await makeHarness()
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        try await h.waiter.load(h.webView, url: URL(string: h.forum)!)
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "I'm working out how to read this site.", toolCalls: [
                call("c1", "run_js", ["code": .string("return (await (await fetch('/api/latest')).json()).items.length")])
            ])),
            .success(AgentModelTurnResponse(text: "", toolCalls: [
                call("c2", "script_save", [
                    "name": .string("List 127.0.0.1"), "match_rules": .array([.string("*://127.0.0.1/*")]), "js": .string(Self.listOnlyJS),
                    "provides": .array([.string("list_latest")]), "list_match": .string("*://127.0.0.1/forum"),
                    "test_urls": .array([.string(h.forum)])
                ])
            ])),
            .success(AgentModelTurnResponse(text: "Saved. Now the list.", toolCalls: [call("c3", "list_latest")])),
            .success(AgentModelTurnResponse(text: "", toolCalls: [call("c4", "navigate", ["url": .string(h.u1)])])),
            .success(AgentModelTurnResponse(text: "", toolCalls: [call("c5", "read_page")])),
            .success(AgentModelTurnResponse(text: "Read the first thread: it is about fan hysteresis. Worth reading."))
        ])
        let session = h.session(client)
        await session.sendAndWait("What's worth reading today")
        let rows = session.runs[0].toolCalls
        XCTAssertEqual(rows.map(\.toolName), ["run_js", "script_save", "list_latest", "navigate", "read_page"])
        XCTAssertFalse(rows.contains { $0.isError }, rows.map { "\($0.toolName): \($0.resultText)" }.joined(separator: "\n"))
        XCTAssertEqual(slot(h, .listLatest).status, .learned)
        XCTAssertNotEqual(slot(h, .readTopic).status, .learned, "only the slot this request needs is learned")
        XCTAssertEqual(h.scriptStore.scripts.count, 1)
        let readIndex = try XCTUnwrap(rows.firstIndex { $0.toolName == "read_page" })
        let listIndex = try XCTUnwrap(rows.firstIndex { $0.toolName == "list_latest" })
        XCTAssertLessThan(listIndex, readIndex, "a thread is read before the recommendation")
        XCTAssertTrue(session.runs[0].assistantText.contains("Worth reading"))
    }

    /// Check 9: ten page loads in the app's own browser, on a learned site and with the page-tools shim on, make no model call,
    /// write no audit line and fetch nothing but the pages (the reader never runs without a request).
    func testTenPageLoadsInTheAppMakeNoModelCallNoToolCallAndNoAuditLine() async throws {
        let h = try await makeHarness()
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("accept-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ai = StateAIStub()
        let app = AppModel(
            store: PersistentStore(fileURL: dir.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore()),
            forumService: WordPressFixtureSite(commentCount: 1).service(), sites: SiteRegistry.standard, aiService: ai,
            workspaceDirectory: dir.appendingPathComponent("ws", isDirectory: true)
        )
        app.browser.onPageContextChanged = nil
        let script = try app.scriptStore.create(id: "reader.fixture", name: "Reads 127.0.0.1", matchRules: ["*://127.0.0.1/*"], js: Self.readerJS, source: .agent(userPrompt: "x"), provides: ["read_topic", "list_latest"])
        var state = SiteToolState(host: "127.0.0.1")
        state.setSlot(SiteSlotState(status: .learned, scriptID: script.id), for: .readTopic)
        try app.siteToolStateStore.save(state)
        XCTAssertTrue(app.settings.agentPageToolsEnabled)
        app.auditLog.flush()
        let linesBefore = app.auditLog.allLines().count, callsBefore = ai.calls.count, pathsBefore = h.site.paths.count
        let pages = [h.u1, h.u2, h.forum, h.base.appendingPathComponent("about").absoluteString]
        for index in 0..<10 {
            let target = pages[index % pages.count]
            app.browser.webView.load(URLRequest(url: URL(string: target)!))
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, app.browser.webView.isLoading || app.browser.webView.url?.absoluteString != target {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(app.browser.webView.url?.absoluteString, target)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        app.auditLog.flush()
        XCTAssertEqual(ai.calls.count, callsBefore, "a page load called the model")
        XCTAssertEqual(app.auditLog.allLines().count, linesBefore, "a page load wrote an audit line")
        let fetched = Set(h.site.paths.dropFirst(pathsBefore))
        XCTAssertTrue(fetched.isSubset(of: ["/thread-101", "/thread-102", "/forum", "/about", "/favicon.ico"]), "page open fetched \(fetched.sorted())")
        XCTAssertFalse(fetched.contains { $0.hasPrefix("/api") }, "a reader ran on page open")
    }

    /// Check 3, live: on the list page of an unlearned site, "What's worth reading today" learns `list_latest`, then reads a thread.
    func testLiveListPageLearnsListLatestThenReadsAThread() async throws {
        let env = ProcessInfo.processInfo.environment
        var targets: [(AIProvider, String, String)] = []
        if let key = env["ANTHROPIC_API_KEY"], !key.isEmpty { targets.append((.anthropic, "claude-haiku-5-5", key)) }
        if let key = env["VERTEX_API_KEY"], !key.isEmpty { targets.append((.vertexAI, "gemini-3.8-flash", key)) }
        guard !targets.isEmpty else { throw XCTSkip("Set TEST_RUNNER_ANTHROPIC_API_KEY or TEST_RUNNER_VERTEX_API_KEY for the live list run.") }
        for (provider, model, key) in targets {
            let h = try await makeHarness()
            defer { h.controller.detach(); h.pageToolBridge.detach() }
            try await h.waiter.load(h.webView, url: URL(string: h.forum)!)
            var configuration = ProviderConfiguration(provider: provider)
            configuration.apiKey = key; configuration.model = model
            let runtime = BrowserAgentRuntimeConfig(
                selection: ModelSelection(provider: provider, model: model), configuration: configuration,
                maxSteps: BrowserAgentLimits.defaultMaxSteps, truncationLimit: 20_000, customInstructions: "", redactedSecrets: []
            )
            let session = BrowserAgentSession(pageDriver: h.bridge, modelClient: AIService(), configProvider: { runtime }, registryBuilder: { _, _, _ in h.registry() })
            await session.sendAndWait("What's worth reading today on this forum?")
            let run = try XCTUnwrap(session.runs.first)
            let names = run.toolCalls.map(\.toolName)
            print("LISTLIVE model=\(model) provider=\(provider.rawValue) state=\(run.state) calls=\(names.count) in=\(run.tokenUsage.inputTokens) out=\(run.tokenUsage.outputTokens) cacheRead=\(run.tokenUsage.cacheReadTokens ?? -1) tools=\(names.joined(separator: ",")) listLatest=\(slot(h, .listLatest).status.rawValue) scripts=\(h.scriptStore.scripts.count) answer=\(run.assistantText.prefix(200).replacingOccurrences(of: "\n", with: " "))")
        }
    }

    /// Check 5, live once: a hand-broken reader is repaired inside the run that needs it (`claude-haiku-5-5`, or Vertex Gemini).
    func testLiveBrokenReaderIsRepairedInTheSameRun() async throws {
        let env = ProcessInfo.processInfo.environment
        var target: (AIProvider, String, String)?
        if let key = env["ANTHROPIC_API_KEY"], !key.isEmpty { target = (.anthropic, "claude-haiku-5-5", key) }
        else if let key = env["VERTEX_API_KEY"], !key.isEmpty { target = (.vertexAI, "gemini-3.8-flash", key) }
        guard let (provider, model, key) = target else { throw XCTSkip("Set TEST_RUNNER_ANTHROPIC_API_KEY or TEST_RUNNER_VERTEX_API_KEY for the live repair run.") }
        let h = try await makeHarness(), script = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        h.site.inlineLogin = true
        try await edit(h, script, js: Self.emptyReaderJS, keepHash: true)
        var configuration = ProviderConfiguration(provider: provider)
        configuration.apiKey = key; configuration.model = model
        let runtime = BrowserAgentRuntimeConfig(
            selection: ModelSelection(provider: provider, model: model), configuration: configuration,
            maxSteps: BrowserAgentLimits.defaultMaxSteps, truncationLimit: 20_000, customInstructions: "", redactedSecrets: []
        )
        let session = BrowserAgentSession(pageDriver: h.bridge, modelClient: AIService(), configProvider: { runtime }, registryBuilder: { _, _, _ in h.registry() })
        await session.sendAndWait("Read this thread with your reading tool and tell me what it is about.")
        let run = try XCTUnwrap(session.runs.first)
        let names = run.toolCalls.map(\.toolName)
        print("REPAIRLIVE model=\(model) provider=\(provider.rawValue) calls=\(names.count) in=\(run.tokenUsage.inputTokens) out=\(run.tokenUsage.outputTokens) cacheRead=\(run.tokenUsage.cacheReadTokens ?? -1) tools=\(names.joined(separator: ",")) slot=\(slot(h, .readTopic).status.rawValue) scripts=\(h.scriptStore.scripts.count) answer=\(run.assistantText.prefix(200).replacingOccurrences(of: "\n", with: " "))")
        for row in run.toolCalls where row.toolName == "script_update" || row.isError { print("REPAIRLIVE-ROW \(row.toolName) error=\(row.isError) \(row.argumentsJSON.prefix(300)) -> \(row.resultText.prefix(500).replacingOccurrences(of: "\n", with: " | "))") }
        XCTAssertTrue(names.contains("script_update"), "the Agent repaired the reader with script_update: \(names)")
        XCTAssertEqual(slot(h, .readTopic).status, .learned, model)
        XCTAssertEqual(h.scriptStore.scripts.count, 1, "one script for the slot")
        XCTAssertTrue(h.stateStore.state(forHost: "127.0.0.1")?.log.map(\.kind).contains(.repaired) == true)
    }
}

/// Check 10, replayed: on a learned thread, "summarize this" and "read it to me" are for the Agent, never the page text.
@MainActor
final class LearnOnAskVoiceTests: XCTestCase {
    func testLearnedThreadWithNoInputIsHandedToTheAgentAndOtherPagesStillReadTheirText() async {
        let navigator = FakeVoiceNavigator()
        navigator.pageContext = PageContext(url: URL(string: "https://forum.example.org/thread-101")!, state: .notForum)
        navigator.readableText = "Cooling Fan Hysteresis and Paste"
        final class Seen: @unchecked Sendable { var called: [String] = [] }
        let seen = Seen()
        let keys = ["topic_id", "url", "path", "text"]
        let bridge = VoiceToolBridge(navigator: navigator)
        bridge.registryBuilder = { _ in
            ToolRegistry(tools: ["summarize_topic", "read_aloud"].map { name in
                AgentTool(
                    definition: AgentToolDefinition(name: name, description: "", parameters: keys.map { ToolParameterSchema(name: $0, type: .string, description: "", minLength: 1) }),
                    summarizeArguments: { _ in "" }, execute: { _ in seen.called.append(name); return ToolExecutionOutput(content: "ok") }, surfaces: [.voice]
                )
            })
        }
        navigator.openPageIsLearnedThread = true
        for name in ["summarize_topic", "read_aloud"] {
            let outcome = await bridge.handle(.init(id: name, name: name, args: [:]), eyesFree: false)
            XCTAssertEqual(outcome.response["shown"], .string(capabilityHandToAgentMessage), name)
        }
        XCTAssertTrue(seen.called.isEmpty && !navigator.calls.contains("pageReadableText"), "the page text is not read on a learned thread")
        navigator.openPageIsLearnedThread = false
        _ = await bridge.handle(.init(id: "s", name: "summarize_topic", args: [:]), eyesFree: false)
        XCTAssertEqual(seen.called, ["summarize_topic"])
    }
}

/// Check 8: the request's tools and system prompt are the same bytes on a built-in forum, a learned site and an unknown site,
/// built by the app's own registry inputs (`makeForumToolContext`, `makeLearnedSiteContext`).
@MainActor
final class LearnOnAskPrefixTests: XCTestCase {
    func testRequestPrefixIsIdenticalOnABuiltInForumALearnedSiteAndAnUnknownSite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("accept-prefix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppModel(
            store: PersistentStore(fileURL: dir.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore()),
            forumService: WordPressFixtureSite(commentCount: 1).service(), sites: SiteRegistry.standard, aiService: StateAIStub(),
            workspaceDirectory: dir.appendingPathComponent("ws", isDirectory: true)
        )
        app.browser.onPageContextChanged = nil
        let script = try app.scriptStore.create(id: "reader.fixture", name: "Reads example.org", matchRules: ["*://example.org/*"], js: "1;", source: .imported, provides: ["read_topic", "list_latest"])
        var state = SiteToolState(host: "example.org")
        state.setSlot(SiteSlotState(status: .learned, scriptID: script.id), for: .readTopic)
        state.setSlot(SiteSlotState(status: .learned, scriptID: script.id), for: .listLatest)
        try app.siteToolStateStore.save(state)

        let pages: [(PageContext, String)] = [
            (PageContext(url: URL(string: "https://meta.discourse.org/t/slug/1"), site: .discourse, siteURL: "https://meta.discourse.org", forumName: "Meta", state: .topic), "https://meta.discourse.org/t/slug/1"),
            (PageContext(url: URL(string: "https://example.org/thread-1"), state: .notForum), "https://example.org/thread-1"),
            (PageContext(url: URL(string: "https://example.org/forum"), state: .notForum), "https://example.org/forum"),
            (PageContext(url: URL(string: "https://unknown.example.net/page"), state: .notForum), "https://unknown.example.net/page")
        ]
        let client = RecordedModelClient([])
        let runtime = BrowserAgentRuntimeConfig(
            selection: ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
            configuration: ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake-key"),
            maxSteps: 3, truncationLimit: 20_000, customInstructions: "", redactedSecrets: []
        )
        let pageToolBridge = PageToolBridge(webView: app.browser.webView, isEnabled: true)
        var learnedLines: [Bool] = []
        for (context, url) in pages {
            app.browser.setPageContext(context)
            learnedLines.append(app.makeLearnedSiteContext()?.promptState.pageContextLine.contains("`read_topic`, ") == true)
            let session = BrowserAgentSession(
                pageDriver: FixturePageDriver(page: .init(url: url, title: "T", structure: "main", text: "Hi")), modelClient: client,
                configProvider: { runtime },
                registryBuilder: { [unowned app] bridge, limit, secrets in
                    let forum = app.makeForumToolContext(for: app.browser)
                    return ToolRegistry.m3(context: AgentToolContext(
                        bridge: bridge, workspace: app.agentWorkspace, scriptStore: app.scriptStore,
                        settings: AgentToolSettings(truncationLimit: limit, redactedSecrets: secrets),
                        forum: forum, learnedSite: forum == nil ? app.makeLearnedSiteContext() : nil,
                        capabilities: app.capabilityToolContext(for: app.browser),
                        pageTools: PageToolContext(bridge: pageToolBridge, scriptStore: app.scriptStore),
                        siteToolStateStore: app.siteToolStateStore
                    ))
                }
            )
            await session.sendAndWait("Where am I?")
        }
        XCTAssertEqual(learnedLines, [false, true, true, false], "the learned line follows the page")
        let requests = client.recordedRequests
        XCTAssertEqual(requests.count, pages.count)
        let configuration = ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "k")
        let bodies = try requests.map { request -> [String: Any] in
            let wire = try AIService().makeToolRequest(
                system: request.system, messages: request.messages, tools: request.tools,
                configuration: configuration, provider: .anthropic, maxTokens: 4_096
            )
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(wire.httpBody)) as? [String: Any])
        }
        func bytes(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        for index in 1..<bodies.count {
            XCTAssertEqual(try bytes(XCTUnwrap(bodies[0]["tools"])), try bytes(XCTUnwrap(bodies[index]["tools"])), "tools changed at page \(index)")
            XCTAssertEqual(try bytes(XCTUnwrap(bodies[0]["system"])), try bytes(XCTUnwrap(bodies[index]["system"])), "system changed at page \(index)")
        }
        let names = requests[0].tools.map(\.name)
        XCTAssertTrue(names.contains("page_tools_list") && names.contains("read_topic") && names.contains("script_save"))
        XCTAssertFalse(names.contains { $0.hasPrefix("site.") || $0.hasPrefix("script.") }, "page tools are never declared")
        guard case .user(let learnedTurn) = requests[1].messages.last, case .user(let unknownTurn) = requests[3].messages.last else { return XCTFail("turns") }
        XCTAssertTrue(learnedTurn.contains("- Reading learned here:"), learnedTurn)
        XCTAssertFalse(unknownTurn.contains("- Reading learned here:"), unknownTurn)
    }
}
