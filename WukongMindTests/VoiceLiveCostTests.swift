import XCTest
@testable import WukongMind

/// One scripted live Gemini Live session (Vertex first), recorded as a replay
/// fixture and measured for docs/wukongmind/voice-cost.md: seconds connected,
/// model audio seconds, prompt and response tokens per turn. Opt-in: needs
/// TEST_RUNNER_VERTEX_API_KEY (or TEST_RUNNER_GEMINI_LIVE_KEY) and goes
/// through the live test budget like every Live connection.
@MainActor
final class VoiceLiveCostTests: XCTestCase {
    /// A typical short session on a news page: summary, a link, goodbye.
    static let script = ["What's this page about?", "Open the third link.", "Thanks, that's all."]

    func testLiveScriptedSessionRecordsAndMeasures() async throws {
        let env = ProcessInfo.processInfo.environment
        let vertexKey = (env["VERTEX_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let studioKey = (env["GEMINI_LIVE_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vertexKey.isEmpty || !studioKey.isEmpty else {
            throw XCTSkip("Neither VERTEX_API_KEY nor GEMINI_LIVE_KEY is set for the test runner.")
        }
        let endpoint: GeminiLive.Endpoint
        let key: String
        if !vertexKey.isEmpty {
            let project = GeminiLive.Endpoint.vertexProject(fromBaseURL: env["VERTEX_BASE_URL"] ?? "")
                ?? (env["VERTEX_PROJECT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            endpoint = .vertex(project: project, location: GeminiLive.Endpoint.vertexLocation)
            key = vertexKey
        } else {
            endpoint = .aiStudio
            key = studioKey
        }
        print("[LIVE-COST] model=\(GeminiLive.model) endpoint=\(endpoint.isVertex ? "vertex" : "aiStudio (GEMINI_LIVE_KEY)")")

        let app = LiveReplaySupport.makeApp(self)
        let navigator = LiveReplaySupport.fakePage("ordinary", app: app)
        var settings = VoiceSettings()
        settings.sessionLimitMinutes = 0
        settings.dailyLimitMinutes = 0
        var recorder: RecordingLiveTransport?
        let session = VoiceSession(
            configuration: .init(endpoint: endpoint, apiKey: key, settings: settings),
            transport: {
                let transport = RecordingLiveTransport(WebSocketLiveTransport())
                recorder = transport
                return transport
            },
            audio: FakeVoiceAudio(), navigator: navigator, usage: nil, runsLoop: false
        )
        session.tools.registryBuilder = { app.voiceToolRegistry(browse: $0) }
        var replies: [String] = []
        session.onTranscript = { role, text, _ in if role == .voiceReply { replies.append(text) } }
        let started = Date()
        await session.start()
        try await waitUntil(session, timeout: 15) { session.state == .listening }
        try await Task.sleep(for: .milliseconds(300))

        for (index, utterance) in Self.script.enumerated() {
            let before = replies.count
            session.sendText(utterance)
            try await waitUntil(session, timeout: 25) {
                session.state.isOver || (replies.count > before && session.state == .listening)
            }
            print("[LIVE-COST] turn \(index + 1) \"\(utterance)\" -> \(replies.last ?? "")")
            if session.state.isOver { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        try await waitUntil(session, timeout: 10) { session.state.isOver }
        session.stop()
        let wall = Date().timeIntervalSince(started)

        let transport = try XCTUnwrap(recorder)
        let recording = transport.recording(
            name: "ordinary: " + Self.script.joined(separator: " / "),
            source: "recorded live \(ISO8601DateFormatter().string(from: Date()).prefix(10)), "
                + (endpoint.isVertex ? "Vertex" : "AI Studio") + ", VoiceLiveCostTests",
            model: GeminiLive.model, page: "ordinary"
        )
        let usage = recording.steps.flatMap(\.frames).compactMap { GeminiLive.decode(Data($0.utf8))?.usage }
        let prompt = usage.reduce(0) { $0 + $1.promptTokens }
        let response = usage.reduce(0) { $0 + $1.responseTokens }
        print("[LIVE-COST] connected_s=\(String(format: "%.1f", session.connectedSeconds)) wall_s=\(String(format: "%.1f", wall)) "
            + "model_audio_s=\(recording.audioSeconds ?? 0) mic_audio_s=0 turns=\(usage.count) "
            + "prompt_tokens=\(prompt) response_tokens=\(response) per_turn_prompt=\(usage.map(\.promptTokens)) calls=\(recording.calls)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(["recordings": [recording]])
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "recorded-live-session.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[LIVE-RECORDING-BEGIN]\n\(String(decoding: json, as: UTF8.self))\n[LIVE-RECORDING-END]")

        XCTAssertEqual(session.state, .ended(.model), "The goodbye ends the session")
        XCTAssertTrue(recording.calls.contains(VoiceTool.end.rawValue), "\(recording.calls)")
        XCTAssertEqual(replies.count, Self.script.count, "\(replies)")
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
