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

    /// Check 8: the request's tools and system prompt are the same bytes on a learned thread, a learned list page and an unknown site.
    func testRequestPrefixIsIdenticalOnALearnedSiteAndAnUnknownSite() async throws {
        let h = try await makeHarness(); _ = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        let unknown = URL(string: h.base.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"))!.appendingPathComponent("about")
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "Done on the learned thread.")),
            .success(AgentModelTurnResponse(text: "Done on the learned list.")),
            .success(AgentModelTurnResponse(text: "Done on the unknown site."))
        ])
        let session = h.session(client)
        await session.sendAndWait("Where am I?")
        try await h.waiter.load(h.webView, url: URL(string: h.forum)!)
        await session.sendAndWait("Where am I?")
        try await h.waiter.load(h.webView, url: unknown)
        await session.sendAndWait("Where am I?")
        let requests = client.recordedRequests
        XCTAssertEqual(requests.count, 3)
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
            XCTAssertEqual(try bytes(XCTUnwrap(bodies[0]["tools"])), try bytes(XCTUnwrap(bodies[index]["tools"])), "tools changed at turn \(index)")
            XCTAssertEqual(try bytes(XCTUnwrap(bodies[0]["system"])), try bytes(XCTUnwrap(bodies[index]["system"])), "system changed at turn \(index)")
        }
        let names = requests[0].tools.map(\.name)
        XCTAssertTrue(names.contains("page_tools_list") && names.contains("read_topic") && names.contains("script_save"))
        XCTAssertFalse(names.contains { $0.hasPrefix("site.") || $0.hasPrefix("script.") }, "page tools are never declared")
        // The page itself is only in the turn's page context (the unknown-site wording is pinned by OneLoopAcceptanceTests).
        guard case .user(let learnedTurn) = requests[0].messages.last, case .user(let unknownTurn) = requests[2].messages.last else { return XCTFail("turns") }
        XCTAssertTrue(learnedTurn.contains("- Reading learned here:"), learnedTurn)
        XCTAssertTrue(unknownTurn.contains("- URL: \(unknown.absoluteString)"), unknownTurn)
    }

    /// Check 9: ten page loads of a learned site with no message make no model call, no tool call and no request beyond the pages.
    func testTenPageLoadsWithNoMessageMakeNoModelCallAndNoToolCall() async throws {
        let h = try await makeHarness(); _ = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        let client = RecordedModelClient([])
        let session = h.session(client)
        let before = h.site.paths.count
        let pages = [h.u1, h.u2, h.forum, h.base.appendingPathComponent("about").absoluteString]
        for index in 0..<10 { try await h.waiter.load(h.webView, url: URL(string: pages[index % pages.count])!) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(client.recordedRequests.isEmpty, "a page load called the model")
        XCTAssertTrue(session.runs.isEmpty && session.toolCalls.isEmpty, "a page load ran a tool")
        let fetched = Set(h.site.paths.dropFirst(before))
        XCTAssertTrue(fetched.isSubset(of: ["/thread-101", "/thread-102", "/forum", "/about", "/favicon.ico"]), "page open fetched \(fetched.sorted())")
        XCTAssertFalse(fetched.contains { $0.hasPrefix("/api") }, "a reader ran on page open")
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
        XCTAssertTrue(names.contains("script_update"), "the Agent repaired the reader with script_update: \(names)")
        XCTAssertEqual(slot(h, .readTopic).status, .learned, model)
        XCTAssertEqual(h.scriptStore.scripts.count, 1, "one script for the slot")
        XCTAssertTrue(h.stateStore.state(forHost: "127.0.0.1")?.log.map(\.kind).contains(.repaired) == true)
    }
}
