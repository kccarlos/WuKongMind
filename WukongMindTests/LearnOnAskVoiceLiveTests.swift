import XCTest
@testable import WukongMind

/// Learn on ask acceptance check 10, live: on a learned site's thread, "summarize this thread" said to Gemini Live
/// (Vertex first) reaches the summary through the hand-off to the Agent. The page is a learned thread of the fixture
/// forum, learned in the app's own stores; the hand-off is scripted here because the Agent half is replayed by `LearningPromptTests` (check 2).
/// Opt-in: needs TEST_RUNNER_VERTEX_API_KEY (or TEST_RUNNER_GEMINI_LIVE_KEY); goes through the live test budget.
@MainActor
final class LearnOnAskVoiceLiveTests: XCTestCase {
    func testLiveSummarizeThisThreadOnALearnedSiteReachesTheHandOff() async throws {
        let env = ProcessInfo.processInfo.environment
        let vertexKey = (env["VERTEX_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let studioKey = (env["GEMINI_LIVE_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vertexKey.isEmpty || !studioKey.isEmpty else {
            throw XCTSkip("Neither VERTEX_API_KEY nor GEMINI_LIVE_KEY is set for the test runner.")
        }
        let endpoint: GeminiLive.Endpoint, key: String
        if !vertexKey.isEmpty {
            let project = GeminiLive.Endpoint.vertexProject(fromBaseURL: env["VERTEX_BASE_URL"] ?? "")
                ?? (env["VERTEX_PROJECT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            endpoint = .vertex(project: project, location: GeminiLive.Endpoint.vertexLocation); key = vertexKey
        } else {
            endpoint = .aiStudio; key = studioKey
        }
        print("[LEARN-VOICE] model=\(GeminiLive.model) endpoint=\(endpoint.isVertex ? "vertex" : "aiStudio (GEMINI_LIVE_KEY)")")

        let app = LiveReplaySupport.makeApp(self)
        let navigator = FakeVoiceNavigator()
        navigator.pageContext = PageContext(url: URL(string: "https://forum.example.org/thread-101")!, state: .notForum)
        navigator.explicitPageTitle = "Cooling Fan Hysteresis and Paste"
        navigator.readableText = "Cooling Fan Hysteresis and Paste\n\nalice: Thermal paste dropped idle temperatures by twelve degrees."
        // The site is learned in the app's own stores, so `summarize_topic` on this thread is the learned-thread refusal.
        let script = try app.scriptStore.create(id: "reader.fixture", name: "Reads forum.example.org", matchRules: ["*://forum.example.org/*"], js: "1;", source: .imported, provides: ["read_topic"], threadMatches: ["*://forum.example.org/thread-*"])
        var learnedState = SiteToolState(host: "forum.example.org")
        learnedState.setSlot(SiteSlotState(status: .learned, scriptID: script.id), for: .readTopic)
        try app.siteToolStateStore.save(learnedState)
        app.browser.setPageContext(navigator.pageContext)
        navigator.openPageIsLearnedThread = app.openPageIsLearnedThread
        var settings = VoiceSettings()
        settings.sessionLimitMinutes = 0; settings.dailyLimitMinutes = 0
        let session = VoiceSession(
            configuration: .init(endpoint: endpoint, apiKey: key, settings: settings),
            transport: { WebSocketLiveTransport() },
            audio: FakeVoiceAudio(), navigator: navigator, usage: nil, runsLoop: false
        )
        session.tools.registryBuilder = { app.voiceToolRegistry(browse: $0) }
        var replies: [String] = []
        session.onTranscript = { role, text, _ in if role == .voiceReply { replies.append(text) } }
        await session.start()
        try await waitUntil(session, timeout: 15) { session.state == .listening }
        try await Task.sleep(for: .milliseconds(300))
        session.sendText("Summarize this thread and replies for me.")
        try await waitUntil(session, timeout: 40) { session.state.isOver || (!replies.isEmpty && session.state == .listening) }
        print("[LEARN-VOICE] calls=\(navigator.calls) reply=\(replies.last ?? "")")
        session.stop()
        XCTAssertTrue(navigator.openPageIsLearnedThread, "the app knows the fixture page is a learned thread")
        XCTAssertTrue(navigator.calls.contains { $0.hasPrefix("hand off ") }, "the summary came through the hand-off: \(navigator.calls)")
    }

    private func waitUntil(_ session: VoiceSession, timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            session.tick()
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(condition(), "Timed out in \(session.state)")
    }
}
