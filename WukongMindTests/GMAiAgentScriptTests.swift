import UIKit
import WebKit
import XCTest
@testable import WukongMind

struct RecordedGMAiTurn: Codable, Equatable, Sendable {
    var text: String
    var usage: AgentTokenUsage?
}

struct GMAiAcceptanceRecording: Codable, Equatable, Sendable {
    var model: String
    var prompt: String
    var pageURL: String
    var agentResponses: [AgentModelTurnResponse]
    var gmAiResponses: [RecordedGMAiTurn]
}

private final class LiveGMAiAgentRecorder: AgentModelClient, @unchecked Sendable {
    private let base: AgentModelClient
    private let lock = NSLock()
    private(set) var responses: [AgentModelTurnResponse] = []
    init(base: AgentModelClient) { self.base = base }

    func completeToolTurn(
        system: String, messages: [AgentModelTurn], tools: [AgentToolDefinition],
        configuration: ProviderConfiguration, provider: AIProvider, maxTokens: Int
    ) async throws -> AgentModelTurnResponse {
        let response = try await base.completeToolTurn(
            system: system, messages: messages, tools: tools,
            configuration: configuration, provider: provider, maxTokens: maxTokens
        )
        lock.withLock { responses.append(response) }
        return response
    }
}

@MainActor
final class GMAiAgentScriptTests: XCTestCase {
    private final class OfflineForumURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
        override func stopLoading() {}
    }

    private struct NoOpBackgroundGrace: BackgroundGracing {
        func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier { .invalid }
        func end(_ id: UIBackgroundTaskIdentifier) {}
    }

    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private var tempDir: URL!

    static let acceptancePrompt = "From now on, fold the posts in threads here that have no substance."
    static let fixturePageURL = URL(string: "https://forum.example.org/t/sqlite-wal-checkpoint-latency-under-write-bursts/420")!
    static let recordingURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/GMAiAcceptance/fold-empty-posts.json")

    static let substantiveSnippets: [String: String] = [
        "101": "PRAGMA wal_autocheckpoint = 1000 stalls readers for 180 ms",
        "103": "SQLITE_CHECKPOINT_RESTART during idle gaps cut p99 to 4 ms",
        "106": "Tested SQLITE_CHECKPOINT_TRUNCATE on a 50-connection pool"
    ]

    static let emptySnippets: [String: String] = [
        "102": "Plus one, following this thread closely!",
        "104": "Thanks!! This helped our team so much",
        "105": "Totally agree with the point above!"
    ]

    private static func postHTML(_ num: Int, id: String, uid: Int, user: String, text: String) -> String {
        """
        <div class="topic-post clearfix regular" data-post-number="\(num)"><article id="post_\(num)" data-post-id="\(id)" data-user-id="\(uid)" class="boxed onscreen-post"><div class="topic-body clearfix"><div class="topic-meta-data"><div class="names"><span class="first username"><a href="/u/\(user)">\(user)</a></span></div></div><div class="regular contents"><div class="cooked"><p>\(text)</p></div></div></div></article></div>
        """
    }

    static let discourseFixtureHTML: String = {
        let posts = [
            postHTML(1, id: "101", uid: 11, user: "mira_db", text: "On our telemetry collector (250 inserts/sec on NVMe, SQLite 3.46 in WAL mode), PRAGMA wal_autocheckpoint = 1000 stalls readers for 180 ms every ~40 seconds whenever an analytical dashboard query overlaps a writer commit. Turning autocheckpoint off grows the -wal file past 2 GB within an hour."),
            postHTML(2, id: "102", uid: 22, user: "echo_user", text: "+1! Plus one, following this thread closely!"),
            postHTML(3, id: "103", uid: 33, user: "devon_k", text: "Autocheckpoint runs PASSIVE on the committing writer thread, and when long readers pin old WAL frames the WAL grows until page-cache churn spikes latency. Disable autocheckpoint (0), run a dedicated background thread calling sqlite3_wal_checkpoint_v2 with SQLITE_CHECKPOINT_RESTART during idle gaps, and set PRAGMA journal_size_limit = 67108864: in our production service SQLITE_CHECKPOINT_RESTART during idle gaps cut p99 to 4 ms."),
            postHTML(4, id: "104", uid: 44, user: "sunny99", text: "Thanks!! This helped our team so much!"),
            postHTML(5, id: "105", uid: 55, user: "alex_t", text: "Totally agree with the point above!"),
            postHTML(6, id: "106", uid: 11, user: "mira_db", text: "Tested SQLITE_CHECKPOINT_TRUNCATE on a 50-connection pool in staging: p99 reader latency dropped from 180 ms to 3.2 ms, and the WAL file resets cleanly to 0 bytes whenever readers close their statements promptly. One follow-up question: does PRAGMA busy_timeout cap how long RESTART blocks if a reader leaks an unfinished cursor?")
        ].joined(separator: "\n")
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Discourse 3.4.0"><meta property="og:site_name" content="Example Engineering Forum">
        <title>SQLite WAL checkpoint latency under write bursts - Example Engineering Forum</title>
        <style>body{font-family:-apple-system,sans-serif;margin:16px;color:#1c1c1e;background:#fff}.topic-post{border-bottom:1px solid #e5e5ea;padding:12px 0}.names{font-weight:600;font-size:14px;margin-bottom:6px}.cooked p{margin:6px 0;line-height:1.45}</style>
        </head><body><div id="main-outlet"><h1 class="fancy-title">SQLite WAL checkpoint latency under write bursts</h1><div class="post-stream">
        \(posts)
        </div></div></body></html>
        """
    }()

    override func setUp() async throws {
        try await super.setUp()
        ToolRegistry.verificationTiming = ToolRegistry.ScriptVerificationTiming()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GMAiAgentScriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ToolRegistry.verificationTiming = ToolRegistry.ScriptVerificationTiming()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func withTestApp(dirName: String, aiService: AIService = AIService(), body: @MainActor (AppModel) async throws -> Void) async throws {
        let stateURL = tempDir.appendingPathComponent("\(dirName)/state.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let forumConfig = URLSessionConfiguration.ephemeral
        forumConfig.protocolClasses = [OfflineForumURLProtocol.self]
        let forumSession = URLSession(configuration: forumConfig)
        let browser = ForumBrowserModel(contentRules: ContentRuleLibrary(store: nil, directory: nil), websiteDataStore: Self.sharedDataStore)
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let browserWindow = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: frame)
        browserWindow.frame = frame
        let vc = UIViewController()
        vc.view.frame = browserWindow.bounds
        browser.webView.frame = vc.view.bounds
        vc.view.addSubview(browser.webView)
        browserWindow.rootViewController = vc
        browserWindow.makeKeyAndVisible()
        browserWindow.layoutIfNeeded()
        let app = AppModel(
            store: PersistentStore(fileURL: stateURL, keys: InMemoryProviderKeyStore()),
            forumService: ForumService(session: forumSession, pacer: ForumRequestPacer(clock: InstantPacingClock())),
            aiService: aiService,
            browser: browser,
            cloudSync: CloudSyncController(transport: nil, files: nil, defaults: nil, schedulesAutomatically: false),
            podcastDirectory: tempDir.appendingPathComponent("\(dirName)-Podcasts", isDirectory: true),
            workspaceDirectory: tempDir.appendingPathComponent("\(dirName)-Workspace", isDirectory: true),
            spotlightIndex: FakeSpotlightIndex(),
            topicActivityDonor: FakeTopicActivityDonor(),
            backgroundGrace: NoOpBackgroundGrace()
        )
        app.usesDirectForumRequests = true
        app.allowAllAIProviders()
        app.browser.ignoresNavigationFailures = true
        defer {
            forumSession.invalidateAndCancel()
            app.browser.stopLoading()
            app.podcast.cancelReadAloud()
            app.scriptWebController.detach()
            browser.webView.navigationDelegate = nil
            browser.webView.uiDelegate = nil
            browser.webView.configuration.userContentController.removeAllUserScripts()
            browser.webView.configuration.userContentController.removeAllScriptMessageHandlers()
            browser.webView.removeFromSuperview()
            browserWindow.isHidden = true
            browserWindow.rootViewController = nil
            browserWindow.windowScene = nil
        }
        try await body(app)
    }

    private func waitUntil(timeoutSeconds: Double = 10.0, _ description: String, condition: @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        let finalCheck = try await condition()
        XCTAssertTrue(finalCheck, "Timed out waiting for \(description)")
    }

    private func configureHaikuModel(on app: AppModel, apiKey: String) {
        var anthropic = app.settings.configuration(for: .anthropic)
        anthropic.apiKey = apiKey
        anthropic.model = ModelAudit.allowedModel
        app.settings.setConfiguration(anthropic, for: .anthropic)
        for role: ModelRole in [.assistant, .browserAgent, .scripts] {
            app.settings.setModel(ModelSelection(provider: .anthropic, model: ModelAudit.allowedModel), for: role)
        }
    }

    // MARK: - 1. Prompt Section Gating

    func testScriptsAskingModelSectionIsPresentOnlyWithScriptTools() async throws {
        XCTAssertFalse(BrowserAgentPrompt.system(includesScriptTools: false).contains("Scripts that ask a model:"))
        XCTAssertFalse(BrowserAgentPrompt.system(includesScriptTools: false).contains("GM_ai.map"))
        let withScripts = BrowserAgentPrompt.system(includesScriptTools: true)
        for needle in ["Scripts that ask a model:", "grants: [\"GM_ai\"]", "GM_ai.map", "500 ms", "confirm_change: true"] {
            XCTAssertTrue(withScripts.contains(needle), "Missing '\(needle)' in scriptsAskingModelSection")
        }

        let driver = FixturePageDriver(page: .init(url: "https://example.org/article", title: "Example"))
        let runtime = BrowserAgentRuntimeConfig(
            selection: ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
            configuration: ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "test-key"),
            maxSteps: 5, truncationLimit: 20_000, customInstructions: "", redactedSecrets: []
        )

        let m1Client = RecordedModelClient([.success(AgentModelTurnResponse(text: "Done."))])
        let m1Session = BrowserAgentSession(
            pageDriver: driver, modelClient: m1Client, configProvider: { runtime },
            registryBuilder: { bridge, limit, secrets in ToolRegistry.m1(bridge: bridge, truncationLimit: limit, redactedSecrets: secrets) }
        )
        await m1Session.sendAndWait("Inspect this page")
        XCTAssertEqual(m1Client.recordedRequests.first?.tools.contains(where: { $0.name == "script_save" }), false)
        XCTAssertEqual(m1Client.recordedRequests.first?.system.contains("Scripts that ask a model:"), false)

        let store = ScriptStore(directoryURL: tempDir.appendingPathComponent("PromptGateScripts", isDirectory: true))
        let m2Client = RecordedModelClient([.success(AgentModelTurnResponse(text: "Done."))])
        let m2Session = BrowserAgentSession(
            pageDriver: driver, modelClient: m2Client, configProvider: { runtime },
            registryBuilder: { bridge, limit, secrets in ToolRegistry.m2(bridge: bridge, scriptStore: store, truncationLimit: limit, redactedSecrets: secrets) }
        )
        await m2Session.sendAndWait("Inspect this page")
        XCTAssertEqual(m2Client.recordedRequests.first?.tools.contains(where: { $0.name == "script_save" }), true)
        XCTAssertEqual(m2Client.recordedRequests.first?.system.contains("Scripts that ask a model:"), true)
    }

    // MARK: - 2. Verification Waits for GM_* Calls, Catches Post-GM_ai Errors, and Handles Service Outcome

    func testVerificationCatchesErrorsThrownAfterGMAiAnswerAndAllowsServiceFailure() async throws {
        try await withTestApp(dirName: "verify-gmai") { app in
            configureHaikuModel(on: app, apiKey: "test-key")
            app.browser.loadSamplePage(Self.discourseFixtureHTML, at: Self.fixturePageURL)
            await app.browser.waitUntilSettled(timeout: .seconds(15))

            let registry = ToolRegistry.m3(context: AgentToolContext(
                bridge: app.browser.agentBridge, workspace: app.agentWorkspace,
                scriptStore: app.scriptStore, liveApplier: app.scriptWebController
            ))
            let rules: JSONValue = .array([.string("https://forum.example.org/t/*")])
            let grants: JSONValue = .array([.string("GM_ai")])

            // 2a. Delayed fire-and-forget async judge (waits 220 ms to start, GM_ai takes 120 ms, then throws TypeError).
            app.scriptWebController.gmBridge.aiService?.completionRunner = { _, _, _, _, _ in
                try await Task.sleep(for: .milliseconds(120))
                return GMAiCompletionResult(text: "{\"101\": true, \"102\": false}", usage: AgentTokenUsage(inputTokens: 40, outputTokens: 10))
            }
            let delayedCrashJS = """
            setTimeout(async () => {
              const v = await GM_ai.map([{ id: "101", text: "ok" }, { id: "102", text: "+1" }], "Substance?", { type: "boolean" });
              if (v["102"] === false) { const missing = null; missing.classList.add("folded"); }
            }, 220);
            """
            let refusedDelayed = try await registry.dispatch(
                toolName: "script_save",
                arguments: ["name": .string("Delayed Crash"), "match_rules": rules, "js": .string(delayedCrashJS), "grants": grants]
            )
            XCTAssertTrue(refusedDelayed.isError, refusedDelayed.output)
            XCTAssertTrue(refusedDelayed.output.contains("Not saved: runtime error:"), refusedDelayed.output)
            XCTAssertTrue(app.scriptStore.scripts.isEmpty)

            // 2b. Main-body await GM_ai followed by an error.
            app.scriptWebController.gmBridge.aiService?.completionRunner = { _, _, _, _, _ in
                try await Task.sleep(for: .milliseconds(80))
                return GMAiCompletionResult(text: "substantive", usage: nil)
            }
            let refusedMain = try await registry.dispatch(
                toolName: "script_save",
                arguments: [
                    "name": .string("Main Crash"), "match_rules": rules, "grants": grants,
                    "js": .string("const v = await GM_ai('Classify'); throw new Error('boom-after-ai-' + v);")
                ]
            )
            XCTAssertTrue(refusedMain.isError, refusedMain.output)
            XCTAssertTrue(refusedMain.output.contains("boom-after-ai-substantive"), refusedMain.output)
            XCTAssertTrue(app.scriptStore.scripts.isEmpty)

            // 2c. Service failure during verification saves with "saved, but the model call couldn't be checked".
            struct OutageError: LocalizedError { var errorDescription: String? { "HTTP 503 provider unavailable" } }
            app.scriptWebController.gmBridge.aiService?.completionRunner = { _, _, _, _, _ in throw OutageError() }
            let savedDespiteOutage = try await registry.dispatch(
                toolName: "script_save",
                arguments: [
                    "name": .string("Resilient Fold"), "match_rules": rules, "grants": grants,
                    "js": .string("try { await GM_ai.map([{ id: '101', text: 'post' }], 'Substance?', { type: 'boolean' }); } catch (_) {}")
                ]
            )
            XCTAssertFalse(savedDespiteOutage.isError, savedDespiteOutage.output)
            XCTAssertTrue(savedDespiteOutage.output.contains("saved, but the model call couldn't be checked"), savedDespiteOutage.output)
            XCTAssertTrue(savedDespiteOutage.resultSummary.contains("saved, but the model call couldn't be checked"), savedDespiteOutage.resultSummary)
            let savedID = try XCTUnwrap((try JSONValue.parseObjectJSON(savedDespiteOutage.output))["script_id"]?.stringValue)
            XCTAssertNil(app.scriptStore.error(for: savedID))
            XCTAssertNil(app.scriptStore.latestServiceError(for: savedID))

            let unhandledServiceOut = try await registry.dispatch(
                toolName: "script_update",
                arguments: ["script_id": .string(savedID), "js": .string("await GM_ai('unhandled provider outage');")]
            )
            XCTAssertFalse(unhandledServiceOut.isError, unhandledServiceOut.output)
            XCTAssertTrue(unhandledServiceOut.output.contains("saved, but the model call couldn't be checked"))
            XCTAssertNil(app.scriptStore.error(for: savedID))
            XCTAssertEqual(app.scriptStore.latestServiceError(for: savedID)?.kind, .service)
            _ = try await registry.dispatch(toolName: "script_delete", arguments: ["script_id": .string(savedID)])

            // 2d. Heavy fold (>50% visible text drop) refuses first, then reuses cached GM_ai answers on confirm_change: true.
            var confirmCalls = 0
            app.scriptWebController.gmBridge.aiService?.completionRunner = { _, _, _, _, _ in
                confirmCalls += 1
                return GMAiCompletionResult(
                    text: "{\"101\": false, \"102\": true, \"103\": false, \"104\": true, \"105\": true, \"106\": false}",
                    usage: nil
                )
            }
            let heavyFoldJS = """
            const v = await GM_ai.map([...document.querySelectorAll('article[data-post-id]')].map(a => ({ id: a.dataset.postId, text: a.innerText })), 'Keep?', { type: 'boolean' });
            for (const a of document.querySelectorAll('article[data-post-id]')) { if (v[a.dataset.postId] === false) a.style.display = 'none'; }
            """
            let firstHeavy = try await registry.dispatch(
                toolName: "script_save",
                arguments: ["name": .string("Heavy Thread Fold"), "match_rules": rules, "js": .string(heavyFoldJS), "grants": grants]
            )
            XCTAssertTrue(firstHeavy.isError && firstHeavy.output.contains("confirm_change: true"), firstHeavy.output)
            XCTAssertEqual(confirmCalls, 1)

            let confirmedHeavy = try await registry.dispatch(
                toolName: "script_save",
                arguments: ["name": .string("Heavy Thread Fold"), "match_rules": rules, "js": .string(heavyFoldJS), "grants": grants, "confirm_change": .bool(true)]
            )
            XCTAssertFalse(confirmedHeavy.isError, confirmedHeavy.output)
            XCTAssertEqual(confirmCalls, 1, "Retry with confirm_change: true must reuse cached GM_ai answers")
        }
    }

    // MARK: - 3. Recorded Acceptance Check 1 Replay & Live claude-haiku-5-5 Recording

    private func assertFoldStateAndShowControl(in app: AppModel) async throws {
        try await waitUntil(timeoutSeconds: 8.0, "empty posts folded while substantive posts stay visible") {
            let res = try await app.browser.agentBridge.runJS(code: "return document.body ? document.body.innerText : '';", environment: .isolated)
            let visible = (try? JSONDecoder().decode(String.self, from: Data((res.valueJSON ?? "").utf8))) ?? ""
            return Self.substantiveSnippets.values.allSatisfy { visible.contains($0) }
                && Self.emptySnippets.values.allSatisfy { !visible.contains($0) }
        }
        let domCount = try await app.browser.agentBridge.runJS(code: "return document.querySelectorAll('article[data-post-id] .cooked').length;", environment: .isolated)
        XCTAssertEqual(domCount.valueJSON, "6")
    }

    private func assertShowControlRevealsFoldedPost(in app: AppModel, postID: String, expectedSnippet: String) async throws {
        let clicked = try await app.browser.agentBridge.runJS(
            code: """
            const article = document.querySelector('article[data-post-id="\(postID)"]');
            const container = article ? (article.closest('.topic-post') || article) : null;
            if (!container) return 'missing-container';
            const candidates = [...container.querySelectorAll('button, summary, [role="button"], a')];
            const ctrl = candidates.find(el => /show|expand|unfold|view|reveal/i.test(el.textContent || '')) || candidates[candidates.length - 1];
            if (!ctrl) return 'missing-show-control';
            ctrl.click();
            return ctrl.textContent.trim();
            """,
            environment: .page
        )
        XCTAssertFalse(["\"missing-container\"", "\"missing-show-control\""].contains(clicked.valueJSON ?? ""))
        try await waitUntil(timeoutSeconds: 4.0, "folded post \(postID) shown again") {
            let res = try await app.browser.agentBridge.runJS(code: "return document.body ? document.body.innerText : '';", environment: .isolated)
            let visible = (try? JSONDecoder().decode(String.self, from: Data((res.valueJSON ?? "").utf8))) ?? ""
            return visible.contains(expectedSnippet)
        }
    }

    func testRecordedGMAiScriptFoldsEmptyPostsAndReloadUsesCacheOnly() async throws {
        guard FileManager.default.fileExists(atPath: Self.recordingURL.path) else {
            throw XCTSkip("Fixture not recorded yet: run testLiveHaikuGMAiScriptFolding with ANTHROPIC_API_KEY.")
        }
        let saved = try JSONDecoder().decode(GMAiAcceptanceRecording.self, from: Data(contentsOf: Self.recordingURL))
        XCTAssertEqual(saved.model, ModelAudit.allowedModel)
        XCTAssertEqual(saved.prompt, Self.acceptancePrompt)

        try await withTestApp(dirName: "replay-fold") { app in
            configureHaikuModel(on: app, apiKey: "recorded-replay-key")
            let replayAgentClient = RecordedModelClient(saved.agentResponses.map { .success($0) })
            app.browserAgent.configureDebugModelClient(replayAgentClient)

            let allCalls = saved.agentResponses.flatMap(\.toolCalls)
            if let saveName = allCalls.last(where: { $0.name == "script_save" && $0.arguments["js"]?.stringValue != nil })?.arguments["name"]?.stringValue,
               let updateID = allCalls.first(where: { $0.name == "script_update" })?.arguments["script_id"]?.stringValue {
                app.scriptStore.seedPendingCandidateID(updateID, forName: saveName)
            }

            var queuedGMAi = saved.gmAiResponses
            var gmAiModelCallCount = 0
            app.scriptWebController.gmBridge.aiService?.completionRunner = { _, _, _, _, _ in
                gmAiModelCallCount += 1
                guard !queuedGMAi.isEmpty else { throw GMAiError(.provider, "Unexpected extra GM_ai model call during replay.") }
                let next = queuedGMAi.removeFirst()
                return GMAiCompletionResult(text: next.text, usage: next.usage)
            }

            app.browser.loadSamplePage(Self.discourseFixtureHTML, at: Self.fixturePageURL)
            await app.browser.waitUntilSettled(timeout: .seconds(15))
            await app.browserAgent.sendAndWait(Self.acceptancePrompt)

            XCTAssertEqual(replayAgentClient.recordedRequests.first?.system.contains("Scripts that ask a model:"), true)
            XCTAssertEqual(replayAgentClient.recordedRequests.count, saved.agentResponses.count)
            XCTAssertEqual(app.scriptStore.scripts.count, 1)
            let script = try XCTUnwrap(app.scriptStore.scripts.first)
            XCTAssertTrue(script.isEnabled && script.metadata.grants == ["GM_ai"])
            XCTAssertNil(app.scriptStore.error(for: script.id))
            XCTAssertGreaterThan(gmAiModelCallCount, 0)

            try await assertFoldStateAndShowControl(in: app)
            try await assertShowControlRevealsFoldedPost(in: app, postID: "102", expectedSnippet: Self.emptySnippets["102"]!)

            let callsBeforeReload = gmAiModelCallCount
            let auditCountBeforeReload = app.auditLog.allLines().count
            _ = try await app.browser.agentBridge.reload(timeout: 15)
            try await assertFoldStateAndShowControl(in: app)

            XCTAssertEqual(gmAiModelCallCount, callsBeforeReload, "Second load must make no model call")
            let reloadAIEntries = app.auditLog.allLines().dropFirst(auditCountBeforeReload).filter { $0.kind == .scriptAI }
            XCTAssertFalse(reloadAIEntries.isEmpty)
            XCTAssertTrue(reloadAIEntries.allSatisfy { ($0.itemsFromCache ?? 0) > 0 && $0.tokensIn == nil })
        }
    }

    func testLiveHaikuGMAiScriptFolding() async throws {
        let env = ProcessInfo.processInfo.environment
        let apiKey = (env["ANTHROPIC_API_KEY"] ?? env["TEST_RUNNER_ANTHROPIC_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw XCTSkip("Set TEST_RUNNER_ANTHROPIC_API_KEY to run the live claude-haiku-5-5 check.") }

        ModelAudit.shared.reset()
        let liveAIService = AIService(session: ModelAudit.session())
        try await withTestApp(dirName: "live-haiku-fold", aiService: liveAIService) { app in
            configureHaikuModel(on: app, apiKey: apiKey)
            let agentRecorder = LiveGMAiAgentRecorder(base: liveAIService)
            app.browserAgent.configureDebugModelClient(agentRecorder)

            var recordedGMAi: [RecordedGMAiTurn] = []
            let baseRunner = try XCTUnwrap(app.scriptWebController.gmBridge.aiService?.completionRunner)
            app.scriptWebController.gmBridge.aiService?.completionRunner = { system, messages, config, provider, maxTokens in
                do {
                    let result = try await baseRunner(system, messages, config, provider, maxTokens)
                    recordedGMAi.append(RecordedGMAiTurn(text: result.text, usage: result.usage))
                    return result
                } catch {
                    print("GMAI_LIVE_ERROR provider=\(provider.rawValue) model=\(config.model) error=\(error)")
                    throw error
                }
            }

            app.browser.loadSamplePage(Self.discourseFixtureHTML, at: Self.fixturePageURL)
            await app.browser.waitUntilSettled(timeout: .seconds(15))
            await app.browserAgent.sendAndWait(Self.acceptancePrompt)

            let script = try XCTUnwrap(app.scriptStore.scripts.first)
            XCTAssertEqual(app.scriptStore.scripts.count, 1)
            XCTAssertTrue(script.isEnabled && script.metadata.grants.contains("GM_ai"))
            try await assertFoldStateAndShowControl(in: app)
            try await assertShowControlRevealsFoldedPost(in: app, postID: "102", expectedSnippet: Self.emptySnippets["102"]!)

            let modelCallsBeforeReload = ModelAudit.shared.recorded.count
            let gmCallsBeforeReload = recordedGMAi.count
            _ = try await app.browser.agentBridge.reload(timeout: 15)
            try await assertFoldStateAndShowControl(in: app)
            XCTAssertEqual(recordedGMAi.count, gmCallsBeforeReload)
            XCTAssertEqual(ModelAudit.shared.recorded.count, modelCallsBeforeReload)
            XCTAssertTrue(ModelAudit.shared.recorded.allSatisfy { $0.model == ModelAudit.allowedModel && $0.status == 200 })

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let jsonData = try encoder.encode(GMAiAcceptanceRecording(
                model: ModelAudit.allowedModel, prompt: Self.acceptancePrompt,
                pageURL: Self.fixturePageURL.absoluteString, agentResponses: agentRecorder.responses, gmAiResponses: recordedGMAi
            ))
            let attachment = XCTAttachment(data: jsonData, uniformTypeIdentifier: "public.json")
            attachment.name = "fold-empty-posts.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Check 1, second live run: the Scripts model is a Vertex Gemini model. The saved script comes from the
    /// recorded Haiku run (the Agent is replayed), so this run proves only that `GM_ai` works on Gemini.
    func testLiveVertexGeminiGMAiScriptFolding() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = (env["VERTEX_API_KEY"] ?? env["TEST_RUNNER_VERTEX_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw XCTSkip("Set TEST_RUNNER_VERTEX_API_KEY to run the live Vertex Gemini check.") }
        guard FileManager.default.fileExists(atPath: Self.recordingURL.path) else { throw XCTSkip("Recorded fixture missing.") }
        let saved = try JSONDecoder().decode(GMAiAcceptanceRecording.self, from: Data(contentsOf: Self.recordingURL))
        let modelID = (env["TEST_RUNNER_VERTEX_MODEL"] ?? "gemini-3.8-flash")

        try await withTestApp(dirName: "live-vertex-fold") { app in
            var vertex = app.settings.configuration(for: .vertexAI)
            vertex.apiKey = key
            vertex.model = modelID
            app.settings.setConfiguration(vertex, for: .vertexAI)
            app.settings.setModel(ModelSelection(provider: .vertexAI, model: modelID), for: .scripts)
            configureHaikuModel(on: app, apiKey: "recorded-replay-key")
            app.settings.setModel(ModelSelection(provider: .vertexAI, model: modelID), for: .scripts)
            app.browserAgent.configureDebugModelClient(RecordedModelClient(saved.agentResponses.map { .success($0) }))
            let allCalls = saved.agentResponses.flatMap(\.toolCalls)
            if let saveName = allCalls.last(where: { $0.name == "script_save" && $0.arguments["js"]?.stringValue != nil })?.arguments["name"]?.stringValue,
               let updateID = allCalls.first(where: { $0.name == "script_update" })?.arguments["script_id"]?.stringValue {
                app.scriptStore.seedPendingCandidateID(updateID, forName: saveName)
            }

            var geminiCalls = 0
            let baseRunner = try XCTUnwrap(app.scriptWebController.gmBridge.aiService?.completionRunner)
            app.scriptWebController.gmBridge.aiService?.completionRunner = { system, messages, config, provider, maxTokens in
                XCTAssertEqual(provider, .vertexAI)
                geminiCalls += 1
                return try await baseRunner(system, messages, config, provider, maxTokens)
            }

            app.browser.loadSamplePage(Self.discourseFixtureHTML, at: Self.fixturePageURL)
            await app.browser.waitUntilSettled(timeout: .seconds(15))
            await app.browserAgent.sendAndWait(Self.acceptancePrompt)
            XCTAssertGreaterThan(geminiCalls, 0)
            try await assertFoldStateAndShowControl(in: app)
            try await assertShowControlRevealsFoldedPost(in: app, postID: "102", expectedSnippet: Self.emptySnippets["102"]!)

            let callsBeforeReload = geminiCalls
            _ = try await app.browser.agentBridge.reload(timeout: 15)
            try await assertFoldStateAndShowControl(in: app)
            XCTAssertEqual(geminiCalls, callsBeforeReload, "Second load must make no model call")
            print("GMAI_VERTEX_LIVE model=\(modelID) calls=\(geminiCalls)")
        }
    }
}
