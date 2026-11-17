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

    /// WUKO-124: after the description trim, the spike's at-risk forum routes
    /// still hold (Q3: an opinion question hands off, "search for" searches),
    /// then the session closes for quiet and the next tap resumes it with the
    /// earlier turns. Two live connections, through the budget.
    func testLiveRoutingAfterTrimAndResumeAfterIdle() async throws {
        let (endpoint, key) = try Self.liveEndpoint()
        print("[LIVE-ROUTING] model=\(GeminiLive.model) endpoint=\(endpoint.isVertex ? "vertex" : "aiStudio (GEMINI_LIVE_KEY)")")
        let app = LiveReplaySupport.makeApp(self)
        let navigator = LiveReplaySupport.fakePage("forum", app: app)
        var settings = VoiceSettings()
        settings.sessionLimitMinutes = 0
        settings.dailyLimitMinutes = 0
        let clock = OffsetVoiceClock()
        var recorders: [RecordingLiveTransport] = []
        var replies: [String] = []
        func makeSession() -> VoiceSession {
            let session = VoiceSession(
                configuration: .init(endpoint: endpoint, apiKey: key, settings: settings),
                transport: {
                    let transport = RecordingLiveTransport(WebSocketLiveTransport())
                    recorders.append(transport)
                    return transport
                },
                audio: FakeVoiceAudio(), navigator: navigator, clock: clock, usage: nil, runsLoop: false
            )
            session.tools.registryBuilder = { app.voiceToolRegistry(browse: $0) }
            session.onTranscript = { role, text, _ in if role == .voiceReply { replies.append(text) } }
            return session
        }
        func say(_ utterance: String, on session: VoiceSession, replies wanted: Int = 1) async throws {
            let before = replies.count
            session.sendText(utterance)
            try await waitUntil(session, timeout: 25) {
                session.state.isOver || (replies.count >= before + wanted && session.state == .listening)
            }
            print("[LIVE-ROUTING] \"\(utterance)\" -> \(replies.suffix(replies.count - before))")
            try await Task.sleep(for: .milliseconds(500))
        }

        let first = makeSession()
        await first.start()
        try await waitUntil(first, timeout: 15) { first.state == .listening }
        try await Task.sleep(for: .milliseconds(300))
        // The hand-off answers "started", then its briefing is spoken: two replies.
        try await say("What do people here think of the N100 for a home server?", on: first, replies: 2)
        try await say("Search for firmware rollback.", on: first)
        let calls = recorders.flatMap { $0.recording(name: "", source: "", model: "", page: "forum").calls }
        print("[LIVE-ROUTING] calls=\(calls)")
        XCTAssertEqual(calls.first, VoiceTool.handOffToAgent.rawValue, "Q3: an opinion question hands off")
        XCTAssertTrue(calls.contains("search_forum"), "\(calls)")
        try await waitUntil(first, timeout: 10) { first.resumptionHandle != nil }

        // Quiet past the idle timeout: the socket closes and leaves the handle.
        clock.offset += settings.idleTimeout + 1
        first.tick()
        XCTAssertEqual(first.state, .ended(.idle))
        let resumption = try XCTUnwrap(first.resumption, "An idle close leaves a handle")

        let second = makeSession()
        await second.start(resuming: resumption)
        try await waitUntil(second, timeout: 15) { second.state == .listening }
        XCTAssertEqual(second.connectionGeneration, 1, "Resumed, not fresh")
        try await Task.sleep(for: .milliseconds(300))
        try await say("What did I ask you to search for a moment ago?", on: second)
        second.stop()
        let answer = replies.last ?? ""
        XCTAssertTrue(answer.localizedCaseInsensitiveContains("firmware"), "The resumed session remembers: \(answer)")
        for (index, recorder) in recorders.enumerated() {
            let usage = recorder.recording(name: "", source: "", model: "", page: "forum").steps.flatMap(\.frames)
                .compactMap { GeminiLive.decode(Data($0.utf8))?.usage }
            print("[LIVE-ROUTING] connection \(index + 1) turns=\(usage.count) per_turn_prompt=\(usage.map(\.promptTokens)) "
                + "response_tokens=\(usage.reduce(0) { $0 + $1.responseTokens })")
        }
    }

    /// Vertex first (`VERTEX_API_KEY`), AI Studio (`GEMINI_LIVE_KEY`) only without it.
    static func liveEndpoint() throws -> (GeminiLive.Endpoint, String) {
        let env = ProcessInfo.processInfo.environment
        let vertexKey = (env["VERTEX_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let studioKey = (env["GEMINI_LIVE_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vertexKey.isEmpty || !studioKey.isEmpty else {
            throw XCTSkip("Neither VERTEX_API_KEY nor GEMINI_LIVE_KEY is set for the test runner.")
        }
        guard !vertexKey.isEmpty else { return (.aiStudio, studioKey) }
        let project = GeminiLive.Endpoint.vertexProject(fromBaseURL: env["VERTEX_BASE_URL"] ?? "")
            ?? (env["VERTEX_PROJECT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (.vertex(project: project, location: GeminiLive.Endpoint.vertexLocation), vertexKey)
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

/// Real time plus an offset, so a live test can skip the idle timeout.
final class OffsetVoiceClock: VoiceClock {
    var offset: TimeInterval = 0
    var now: Date { Date().addingTimeInterval(offset) }
}
