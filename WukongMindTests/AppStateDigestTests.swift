import SwiftUI
import XCTest
@testable import WukongMind

@MainActor
final class AppStateDigestTests: XCTestCase {
    private final class StubDriver: AgentPageDriving, @unchecked Sendable {
        var onRunJS: (@Sendable () async throws -> JSExecutionResult)?
        func currentPageMetadata() async -> AgentPageMetadata { .init(url: "https://news.example.org/story", title: "Story") }
        func readPage(mode: PageReadMode, selector: String?, maxLength: Int?) async throws -> String { "text" }
        func runJS(code: String, environment: AgentExecutionEnvironment, timeout: TimeInterval) async throws -> JSExecutionResult {
            try await onRunJS?() ?? JSExecutionResult(valueJSON: "true", consoleOutput: [], error: nil)
        }
        func injectCSS(css: String, id: String?) async throws -> CSSInjectionResult { .init(sheetID: id ?? "s", appliedRootCount: 1) }
        func waitFor(selector: String?, milliseconds: Int?) async throws -> WaitForResult { .init(mode: .delay, matched: true, elapsedMs: 1, selector: selector) }
    }

    private struct EmptyCookies: TaskCookieSource {
        func cookies(forHosts hosts: Set<String>) async -> [KnownCookie]? { [] }
    }

    // MARK: - 1. Agent run transition table, stop mid-tool, and mid-run restore

    func testRunTransitionsTableStopDuringToolAndMidRunRestore() async throws {
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let table: [(String, BrowserAgentRunState, BrowserAgentRunState, TimeInterval?)] = [
            ("completed", .completed(steps: 2, duration: 3.5), .completed(steps: 2, duration: 3.5), 3.5),
            ("stopped", .stopped(step: 2), .stopped(step: 2), nil),
            ("stepLimit", .stepLimitReached(limit: 5), .stepLimitReached(limit: 5), nil),
            ("failed", .failed(message: "boom"), .failed(message: "boom"), nil),
            ("ignoreIdle", .idle, .running(step: 2, maxSteps: 5), nil),
            ("ignoreRunning", .running(step: 4, maxSteps: 5), .running(step: 2, maxSteps: 5), nil)
        ]
        for (label, end, expected, expectedDuration) in table {
            let runID = UUID()
            var run = BrowserAgentRun(id: runID, prompt: "q", toolCalls: [], assistantText: "", state: .running(step: 0, maxSteps: 5), tokenUsage: .zero, startedAt: start)
            let call = BrowserAgentToolCallRow(callID: "c1", runID: runID, stepNumber: 1, toolName: "read_page", argumentSummary: "", argumentsJSON: "{}")
            BrowserAgentSession.advance(run: &run, step: 1, appending: call)
            BrowserAgentSession.advance(run: &run, step: 2)
            XCTAssertEqual(run.state, .running(step: 2, maxSteps: 5), label)

            BrowserAgentSession.finish(run: &run, as: end)
            XCTAssertEqual(run.state, expected, label)
            XCTAssertEqual(run.duration, expectedDuration, label)
            XCTAssertEqual(run.toolCalls.first?.isRunning, false, label)
            XCTAssertEqual(run.toolCalls.first?.resultSummary, "Stopped", label)
            if !expected.isRunning {
                BrowserAgentSession.advance(run: &run, step: 9)
                BrowserAgentSession.finish(run: &run, as: .failed(message: "late"))
                XCTAssertEqual(run.state, expected, "\(label) stays terminal")
            }
        }

        let entered = expectation(description: "tool started")
        let driver = StubDriver()
        driver.onRunJS = {
            entered.fulfill()
            try await Task.sleep(for: .seconds(20))
            return JSExecutionResult(valueJSON: "1", consoleOutput: [], error: nil)
        }
        let session = BrowserAgentSession(
            pageDriver: driver,
            modelClient: RecordedModelClient([.success(AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "js1", name: "run_js", arguments: ["code": .string("1")])]))]),
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
                    configuration: ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake"),
                    maxSteps: 5, truncationLimit: 20_000, customInstructions: "", redactedSecrets: ["fake"]
                )
            }
        )
        session.send("Run slow JS")
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertEqual(session.runState, .running(step: 1, maxSteps: 5))
        XCTAssertEqual(session.toolCalls.first?.isRunning, true)

        session.stop()
        XCTAssertEqual(session.runState, .stopped(step: 1))
        XCTAssertEqual(session.runs.last?.state, .stopped(step: 1))
        XCTAssertEqual(session.toolCalls.first?.isRunning, false)
        XCTAssertEqual(session.toolCalls.first?.isError, true)
        XCTAssertEqual(session.toolCalls.first?.resultText, "Stopped by user.")

        let midID = UUID()
        let activeRow = BrowserAgentToolCallRow(callID: "m1", runID: midID, stepNumber: 2, toolName: "read_page", argumentSummary: "", argumentsJSON: "{}")
        session.restoreConversation(SavedAgentConversation(
            messages: [BrowserAgentMessage(role: .user, text: "Mid-run")],
            runs: [BrowserAgentRun(id: midID, prompt: "Mid-run", toolCalls: [activeRow], assistantText: "", state: .running(step: 2, maxSteps: 10), tokenUsage: .zero, startedAt: start)],
            tokenUsage: .zero, history: []
        ))
        XCTAssertEqual(session.runState, .stopped(step: 2))
        XCTAssertEqual(session.runs.last?.state, .stopped(step: 2))
        XCTAssertEqual(session.toolCalls.first?.isRunning, false)
        XCTAssertEqual(session.toolCalls.first?.resultSummary, "Stopped")
    }

    // MARK: - 2. Legacy conversation decoding and single-array encoding size

    func testOldSavedConversationDecodesAndNewEncodingWritesOneCopyAtHalfSize() throws {
        let base = DrawerPerformanceTests.conversation(runs: 2, shapePosts: 200)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(base)) as? [String: Any])
        legacyObject["toolCalls"] = try JSONSerialization.jsonObject(with: encoder.encode(base.toolCalls))
        legacyObject["runState"] = try JSONSerialization.jsonObject(with: encoder.encode(base.runState))
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoded = try decoder.decode(SavedAgentConversation.self, from: legacyData)
        XCTAssertEqual(decoded.runs, base.runs)
        XCTAssertEqual(decoded.toolCalls, base.toolCalls)
        XCTAssertEqual(decoded.runState, .completed(steps: 3, duration: 4.2))

        let reencoded = try encoder.encode(decoded)
        let reencodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        XCTAssertNotNil(reencodedObject["runs"])
        XCTAssertNil(reencodedObject["toolCalls"])
        XCTAssertNil(reencodedObject["runState"])
        XCTAssertLessThan(Double(reencoded.count), Double(legacyData.count) * 0.55)
    }

    // MARK: - 3. AppStateDigest known states and audit/export recording

    func testAppStateDigestFiveKnownStatesAndTaskTransitionRecording() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("digest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppModel(
            store: PersistentStore(fileURL: dir.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore([.anthropic: "secret-key"])),
            workspaceDirectory: dir.appendingPathComponent("ws", isDirectory: true)
        )
        app.suppressesPersistence = true
        app.allowAllAIProviders()
        // No SwiftUI sheet is attached to answer `presentDrawer()` before the async agent turn finishes,
        // so keep the 2s UIKit drop-recovery watchdog from resetting `.presenting` to `.closed` under CI load.
        app.router.watchdogDelay = .seconds(60)
        let forum = Forum(siteURL: "https://meta.discourse.org", kind: .discourse, name: "Meta", isPinned: true, pinOrder: 0)
        let topicURL = URL(string: "https://meta.discourse.org/t/perf/42")!
        let topic = ForumTopic(siteURL: forum.siteURL, topicID: "42", url: topicURL, title: "Perf")
        let topicPage = PageContext(url: topicURL, site: .discourse, siteURL: forum.siteURL, forumName: forum.name, topic: topic, state: .topic)
        func seed(sessions: [TopicSession] = [], activities: [WorkRecord] = [], topic: ForumTopic? = topic, page: PageContext = topicPage) {
            app.applyDebugSeed(AssistantDebugSeed(forums: [forum], sessions: sessions, activities: activities, agentRuns: [], watchedTopics: [], currentTopic: topic, currentForum: topic == nil ? nil : forum, pageContext: page))
        }

        // State 1: fresh launch on Forums Home.
        XCTAssertEqual(app.stateDigest.description, "drawer=closed summary=none run=idle page=home voice=idle")

        // State 2: forum topic open, drawer shown, saved summary.
        var topicSession = TopicSession(siteURL: forum.siteURL, topicID: "42", url: topicURL, title: "Perf")
        topicSession.summary = "## Summary\n\nFast now."
        topicSession.totalPosts = 10
        topicSession.summaryPostCount = 10
        seed(sessions: [topicSession])
        app.router.presentDrawer(); app.router.drawerAppeared()
        XCTAssertEqual(app.stateDigest.description, "drawer=shown summary=saved run=idle page=topic voice=idle")

        // State 3: stale summary in iPad split layout, voice start failed.
        app.router.dismissDrawer(); app.router.drawerDismissed()
        app.router.splitLayout = true; app.router.splitPanelMode = .shown
        topicSession.totalPosts = 25
        seed(sessions: [topicSession])
        app.voice.start()
        XCTAssertEqual(app.stateDigest.description, "drawer=split summary=stale run=idle page=topic voice=failed")

        // State 4: summary running while drawer presenting on phone layout.
        app.voice.dismiss(); app.router.splitLayout = false; app.router.presentDrawer()
        var runningSummary = WorkRecord(type: .summary, siteURL: forum.siteURL, topicID: "42", title: "Perf", url: topicURL, provider: .anthropic, model: "claude-haiku-5-5")
        runningSummary.status = .running
        seed(sessions: [topicSession], activities: [runningSummary])
        XCTAssertEqual(app.stateDigest.description, "drawer=presenting summary=running run=idle page=topic voice=idle")

        // State 5: non-forum page with Agent run executing -> records mid-run drawer change and completion.
        app.selectModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .role(.browserAgent))
        seed(topic: nil, page: PageContext(url: URL(string: "https://example.com/article"), state: .notForum))
        let stepGate = expectation(description: "agent running")
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "c1", name: "wait_for", arguments: ["milliseconds": .int(50)])])),
            .success(AgentModelTurnResponse(text: "All set."))
        ])
        client.onRequest = { index in if index == 1 { stepGate.fulfill() } }
        app.browserAgent.configureDebugModelClient(client)
        app.browserAgent.send("Check this article")
        await fulfillment(of: [stepGate], timeout: 10)
        XCTAssertEqual(app.stateDigest.description, "drawer=presenting summary=none run=running page=notForum voice=idle")
        app.router.drawerAppeared()
        await app.browserAgent.waitForActiveRun()
        XCTAssertEqual(app.stateDigest.description, "drawer=shown summary=none run=completed page=notForum voice=idle")

        app.auditLog.flush()
        let taskID = try XCTUnwrap(app.browserAgent.currentTaskID)
        let auditStates = app.auditLog.allLines().filter { $0.taskID == taskID && $0.kind == .state }.compactMap(\.state)
        XCTAssertGreaterThanOrEqual(auditStates.count, 2)
        XCTAssertEqual(auditStates.first?.run, "running")
        XCTAssertEqual(auditStates.last, AppStateDigest(drawer: "shown", summary: "none", run: "completed", page: "notForum", voice: "idle"))

        let exported = try await TaskExport.file(taskID: taskID, store: app.taskRecordStore, cookieSource: EmptyCookies(), secrets: ["secret-key"])
        let doc = try TaskExport.load(exported.data)
        XCTAssertEqual(doc.states?.first?.state.run, "running")
        XCTAssertEqual(doc.states?.last?.state, auditStates.last)
    }
}
