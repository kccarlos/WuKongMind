import XCTest
@testable import WukongMind

/// Gemini Live sessions replayed from fixtures (`Fixtures/LiveReplay`)
/// through the real `VoiceSession`, voice registry and tool bridge, with no
/// network: the voice-anywhere routing cases of the One loop spike, and the
/// live test budget. Replays prove the app's side of each recorded call
/// (declared, dispatched, answered, reply committed), not the model's routing.
@MainActor
final class LiveReplayTests: XCTestCase {
    private var clock = ManualVoiceClock()

    // MARK: Spike routing cases

    func testAnywhereUtterancesReplay() async throws {
        try await replayAll("anywhere-utterances", expected: 17)
    }

    func testAnywhereLinksReplay() async throws {
        try await replayAll("anywhere-links", expected: 4)
    }

    func testAnywhereForumQ3Replay() async throws {
        try await replayAll("anywhere-forum-q3", expected: 12)
    }

    /// The one real capture (VoiceLiveCostTests, Vertex, 2026-11-15): summary,
    /// a link and goodbye, with the wire's own call ids and frame boundaries.
    func testRecordedVertexSessionReplay() async throws {
        let recording = try XCTUnwrap(try Self.load("recorded-vertex-session").first)
        XCTAssertFalse(recording.reconstructed)
        XCTAssertEqual(recording.calls, ["summarize_topic", "open_link", "end"])
        // The numbers in docs/wukongmind/voice-cost.md.
        let usage = recording.steps.flatMap(\.frames).compactMap { GeminiLive.decode(Data($0.utf8))?.usage }
        XCTAssertEqual(usage.map(\.promptTokens), [3_589, 3_653, 3_881, 3_943, 4_039])
        XCTAssertEqual(usage.reduce(0) { $0 + $1.responseTokens }, 396, "Vertex's candidatesTokenCount")
        XCTAssertEqual(recording.audioSeconds ?? 0, 12.24, accuracy: 0.01)
        try await replay(recording)
    }

    // MARK: Replay transport

    func testReplaySendsEachStepOnItsTriggerAndKeepsUnexpectedOnes() async throws {
        let recording = LiveRecording(
            source: "test", reconstructed: true, model: GeminiLive.model, name: "t", page: nil, notes: [],
            utterances: ["Next post."], calls: ["browse_move"],
            steps: [
                .init(on: .setup, frames: [#"{"setupComplete":{}}"#]),
                .init(on: .turn, frames: [#"{"toolCall":{"functionCalls":[{"id":"c1","name":"browse_move","args":{}}]}}"#]),
                .init(on: .toolResponse("c1"), frames: [#"{"serverContent":{"turnComplete":true}}"#])
            ]
        )
        let replay = ReplayLiveTransport(recording)
        var received: [String] = []
        let reader = Task { for await frame in replay.frames { received.append(String(decoding: frame, as: UTF8.self)) } }
        replay.send(#"{"clientContent":{"turnComplete":false,"turns":[]}}"#)
        XCTAssertEqual(replay.pending.count, 3, "A silent note triggers nothing")
        replay.send(try GeminiLive.encode(.setup(.init(endpoint: .aiStudio, voice: nil, instructions: "", functions: [], resumptionHandle: nil))))
        replay.send(try GeminiLive.encode(.toolResponse([.init(id: "c9", name: "x", response: [:])])))
        replay.send(try GeminiLive.encode(.toolResponse([.init(id: "b-1", name: VoiceBriefing.name, response: [:])])))
        replay.send(try GeminiLive.encode(.text("Next post.")))
        XCTAssertTrue(replay.isWaitingForUser == false)
        replay.send(try GeminiLive.encode(.toolResponse([.init(id: "c1", name: "browse_move", response: [:])])))
        XCTAssertTrue(replay.pending.isEmpty)
        XCTAssertEqual(replay.unexpected, [.toolResponse("c9")], "Briefings are skipped, an unknown response is kept")
        replay.close()
        await reader.value
        XCTAssertEqual(received.count, 3)
    }

    func testAudioIsStubbedAndCounted() throws {
        let pcm = Data(count: 48_000) // 1 s at 24 kHz PCM16
        let frame = #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\#(pcm.base64EncodedString())"}}]}}}"#
        let stubbed = LiveRecording.stubbingAudio(Data(frame.utf8))
        XCTAssertEqual(stubbed.audioSeconds, 1, accuracy: 0.001)
        XCTAssertTrue(stubbed.text.contains(LiveRecording.audioStub))
        XCTAssertLessThan(stubbed.text.utf8.count, 1_000)
        XCTAssertEqual(GeminiLive.decode(Data(stubbed.text.utf8))?.audio.first?.count, 480)
    }

    // MARK: Budget

    func testBudgetParsesTheEnvironmentAndDefaultsInTests() {
        XCTAssertEqual(LiveBudget.configuredCap(environment: ["GEMINI_LIVE_BUDGET": "5, 600"]), .init(sessions: 5, seconds: 600))
        XCTAssertEqual(LiveBudget.configuredCap(environment: ["GEMINI_LIVE_BUDGET": "lots"]), LiveBudget.defaultCap)
        XCTAssertEqual(LiveBudget.configuredCap(environment: ["XCTestConfigurationFilePath": "/x"]), LiveBudget.defaultCap)
        XCTAssertEqual(LiveBudget.defaultCap, .init(sessions: 3, seconds: 120))
        XCTAssertNotNil(LiveBudget.shared, "This test process is capped")
    }

    func testBudgetRefusesPastTheSessionAndSecondCaps() throws {
        var now = Date(timeIntervalSince1970: 0)
        let budget = LiveBudget(cap: .init(sessions: 2, seconds: 60), now: { now })
        let first = try budget.begin("a")
        now += 50
        XCTAssertEqual(budget.remainingSeconds(), 10, accuracy: 0.001)
        budget.end(first)
        budget.end(first)
        XCTAssertEqual(budget.secondsUsed, 50, accuracy: 0.001, "An end counts once")
        let second = try budget.begin("b")
        now += 20
        XCTAssertEqual(budget.remainingSeconds(), 0)
        budget.end(second)
        XCTAssertThrowsError(try budget.begin("c")) { error in
            let close = error as? LiveClose
            XCTAssertEqual(close?.code, LiveClose.policyViolation)
            XCTAssertTrue(close?.isRefusal == true, "A voice session fails at once instead of retrying")
            XCTAssertTrue(close?.reason.hasPrefix(LiveBudget.refusalPrefix) == true)
        }
        let seconds = LiveBudget(cap: .init(sessions: 9, seconds: 10), now: { now })
        let lease = try seconds.begin("d")
        now += 11
        seconds.end(lease)
        XCTAssertThrowsError(try seconds.begin("e"), "Seconds used up")
    }

    func testRefusedConnectionFailsTheSessionAtOnce() async throws {
        let refusing = FakeLiveTransport()
        refusing.connectError = LiveClose(code: LiveClose.policyViolation, reason: "\(LiveBudget.refusalPrefix) used up")
        let session = VoiceSession(
            configuration: .init(endpoint: .aiStudio, apiKey: "test-key"), transport: { refusing },
            audio: FakeVoiceAudio(), navigator: nil, clock: clock, usage: nil, runsLoop: false
        )
        await session.start()
        XCTAssertEqual(session.state, .failed(.refused("\(LiveBudget.refusalPrefix) used up")))
        XCTAssertEqual(refusing.requests.count, 1, "No retries past the budget")
    }

    func testNamedTimeoutFailsFastWithPhaseNameWhenOperationHangs() async {
        let started = Date()
        do {
            try await Self.withPhaseTimeout(recording: "sample", phase: "tool read_aloud", seconds: 0.08) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
            XCTFail("Expected phase timeout")
        } catch let timeout as ReplayPhaseTimeout {
            XCTAssertTrue(timeout.message.contains("sample: stuck in tool read_aloud"), timeout.message)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: Driver

    private func replayAll(_ fixture: String, expected: Int) async throws {
        let recordings = try Self.load(fixture)
        XCTAssertEqual(recordings.count, expected)
        for recording in recordings {
            try await replay(recording)
        }
    }

    static func load(_ fixture: String) throws -> [LiveRecording] {
        struct File: Decodable { var recordings: [LiveRecording] }
        let url = try XCTUnwrap(Bundle(for: LiveReplayTests.self).url(forResource: fixture, withExtension: "json"), "Missing \(fixture).json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).recordings
    }

    @MainActor
    private final class ReplayHarness {
        var app: AppModel?
        var navigator: FakeVoiceNavigator?
        var session: VoiceSession?
        let replay: ReplayLiveTransport
        var connections = 0
        var replies: [String] = []

        init(_ recording: LiveRecording) {
            replay = ReplayLiveTransport(recording)
        }
    }

    /// Runs one recording through a session on a fake page and checks the
    /// app's side of every recorded call.
    private func replay(_ recording: LiveRecording) async throws {
        let name = recording.name
        let harness = ReplayHarness(recording)
        let detail = PhaseDetailBox()

        try await runPhase(recording: name, phase: "start", detail: detail) {
            detail.set("makeApp")
            let app = LiveReplaySupport.makeApp(self)
            detail.set("fakePage")
            let navigator = LiveReplaySupport.fakePage(recording.page, app: app)
            var settings = VoiceSettings()
            settings.idleTimeout = 100_000
            settings.sessionLimitMinutes = 0
            settings.dailyLimitMinutes = 0
            let session = VoiceSession(
                configuration: .init(endpoint: .aiStudio, apiKey: "test-key", settings: settings),
                transport: { [weak harness] in
                    guard let harness else { return FakeLiveTransport() }
                    harness.connections += 1
                    return harness.connections == 1 ? harness.replay : FakeLiveTransport()
                },
                audio: FakeVoiceAudio(), navigator: navigator, clock: self.clock, usage: nil, runsLoop: false
            )
            session.tools.registryBuilder = { app.voiceToolRegistry(browse: $0) }
            session.onTranscript = { [weak harness] role, text, _ in
                if role == .voiceReply { harness?.replies.append(text) }
            }
            harness.app = app
            harness.navigator = navigator
            harness.session = session
            detail.set("session.start")
            await session.start()
            detail.set("pump(.listening)")
            try await self.pump(session, harness.replay, phase: "start") { session.state == .listening }
        }

        let session = try XCTUnwrap(harness.session, name)
        let replay = harness.replay
        let declared = try XCTUnwrap(session.tools.declaredNames, name)
        for call in recording.calls {
            XCTAssertTrue(declared.contains(call), "\(name): the app no longer declares \(call)")
        }
        for utterance in recording.utterances {
            let phase = Self.turnPhase(for: utterance, pending: replay.pending)
            try await runPhase(recording: name, phase: phase, detail: detail) {
                detail.set("sendText")
                session.sendText(utterance)
                detail.set("pump(turn)")
                try await self.pump(session, replay, phase: phase) {
                    // The recorded frames for this turn are in and handled.
                    replay.isWaitingForUser && (session.state == .listening || session.state.isOver)
                }
            }
        }

        try await runPhase(recording: name, phase: "stop", detail: detail) {
            detail.set("settle")
            await self.settle()
            XCTAssertTrue(replay.pending.isEmpty, "\(name): steps left \(replay.pending.map(\.on))")
            XCTAssertEqual(replay.unexpected, [], name)
            XCTAssertEqual(harness.connections, 1, "\(name): no reconnect")

            // Every recorded call got one answer, from its own tool.
            let responses = replay.sent.map(VoiceSent.init).filter(\.isToolResponse)
            let answered = responses.compactMap { sent -> String? in
                guard case .toolResponse(let id, let tool, _) = sent, !id.hasPrefix("b-") else { return nil }
                return tool
            }
            XCTAssertEqual(answered, recording.calls, name)
            for text in replay.sent where text.contains("toolResponse") {
                XCTAssertFalse(text.contains("There is no tool called"), "\(name): \(text.prefix(300))")
                XCTAssertFalse(text.contains("isn't available on this page"), "\(name): \(text.prefix(300))")
            }
            // The replies the model spoke reached the conversation.
            let spoken = recording.steps.flatMap(\.frames).compactMap { GeminiLive.decode(Data($0.utf8))?.outputTranscription?.text }
            if recording.calls.last == VoiceTool.end.rawValue {
                // The goodbye plays out, then the session ends on a tick.
                detail.set("pump(goodbye)")
                try await self.pump(session, replay, phase: "stop") { session.state.isOver }
                XCTAssertEqual(session.state, .ended(.model), name)
            } else {
                XCTAssertEqual(harness.replies, spoken, name)
            }
            detail.set("session.stop")
            session.stop()
            detail.set("teardown")
            harness.session = nil
            harness.navigator = nil
            harness.app = nil
        }
    }

    private static func turnPhase(for utterance: String, pending: [LiveRecording.Step]) -> String {
        guard let first = pending.first, first.on == .turn else { return "turn \(utterance)" }
        var steps = [first]
        for step in pending.dropFirst() {
            if step.on == .turn { break }
            steps.append(step)
        }
        let calls = steps.flatMap(\.frames)
            .compactMap { GeminiLive.decode(Data($0.utf8)) }
            .flatMap(\.toolCalls)
            .map(\.name)
        return calls.isEmpty ? "turn \(utterance)" : "tool \(calls.joined(separator: ", "))"
    }

    private func runPhase(
        recording: String,
        phase: String,
        detail: PhaseDetailBox,
        seconds: TimeInterval = 12,
        body: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        do {
            try await Self.withPhaseTimeout(recording: recording, phase: phase, seconds: seconds, detail: detail, body: body)
        } catch let timeout as ReplayPhaseTimeout {
            XCTFail(timeout.message)
            throw timeout
        }
    }

    private struct ReplayPhaseTimeout: LocalizedError, Equatable, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private final class PhaseDetailBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func set(_ next: String) { lock.withLock { value = next } }
        func get() -> String { lock.withLock { value } }
    }

    private final class RaceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var settled: Result<Void, Error>?
        private var continuation: CheckedContinuation<Void, Error>?

        func arm(_ next: CheckedContinuation<Void, Error>) {
            let ready = lock.withLock { () -> Result<Void, Error>? in
                if let settled { return settled }
                continuation = next
                return nil
            }
            if let ready { next.resume(with: ready) }
        }

        func finish(_ result: Result<Void, Error>) {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard settled == nil else { return nil }
                settled = result
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: result)
        }
    }

    /// Races `body` against a hard GCD deadline so an await that never resumes
    /// fails fast with `stuck in <phase>` instead of waiting for XCTest's 300 s
    /// execution-time allowance.
    nonisolated private static func withPhaseTimeout(
        recording: String,
        phase: String,
        seconds: TimeInterval = 12,
        detail: PhaseDetailBox = PhaseDetailBox(),
        body: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        let workGate = RaceGate()
        let timerGate = RaceGate()
        let work = Task { @MainActor in
            do {
                try await body()
                workGate.finish(.success(()))
            } catch {
                workGate.finish(.failure(error))
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler {
            let substep = detail.get()
            let suffix = substep.isEmpty ? "" : " (\(substep))"
            let message = "\(recording): stuck in \(phase)\(suffix)"
            fputs("[LIVE-REPLAY-TIMEOUT] \(message)\n", stderr)
            fflush(stderr)
            work.cancel()
            timerGate.finish(.failure(ReplayPhaseTimeout(message: message)))
        }
        timer.resume()
        defer {
            timer.cancel()
            work.cancel()
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { workGate.arm($0) }
                } onCancel: {
                    work.cancel()
                    workGate.finish(.failure(CancellationError()))
                }
            }
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { timerGate.arm($0) }
                } onCancel: {
                    timer.cancel()
                    timerGate.finish(.failure(CancellationError()))
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Lets the session run: its tasks, the 100 ms tick and the clock, until
    /// `done` (at most 30 s of session time).
    private func pump(
        _ session: VoiceSession,
        _ replay: ReplayLiveTransport,
        phase: String,
        until done: () -> Bool
    ) async throws {
        // Tool handlers do real async work (the URL stub, the summary), so wait
        // in real time too, not only by yields.
        let deadline = Date().addingTimeInterval(10)
        for _ in 0..<120 where Date() < deadline {
            await settle()
            if done() { return }
            try await Task.sleep(for: .milliseconds(5))
            await settle()
            if done() { return }
            clock.advance(0.25)
            session.tick()
        }
        if done() { return }
        XCTFail("\(replay.recording.name): stuck in \(phase) (state=\(session.state), steps left \(replay.pending.map(\.on)))")
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

/// The app and pages replays and the live cost test run on.
@MainActor
enum LiveReplaySupport {
    /// The fake page a recording ran on ("forum": a topic at post 12; else
    /// the spike's ordinary news page with four links).
    static func fakePage(_ page: String?, app: AppModel) -> FakeVoiceNavigator {
        let navigator = FakeVoiceNavigator()
        if page == "forum" {
            app.recordVisit(siteURL: "https://forum.example", kind: .discourse, name: "Example", iconURL: nil)
            navigator.pageContext = FakeVoiceNavigator.topicPage(post: 12, visible: [12])
            navigator.summary = "Firmware 5.2 resets the fan curve; roll back or pick the silent profile."
        } else {
            let url = URL(string: "https://heraldexample.com/2026/11/tariffs")!
            navigator.pageContext = PageContext(url: url, state: .notForum)
            navigator.explicitPageTitle = "Markets steady as tariff talks resume"
            navigator.readableText = "Markets steady as tariff talks resume\n\nNegotiators agreed to pause new port levies for ninety days."
            navigator.links = [
                PageLink(text: "Top stories", url: URL(string: "https://heraldexample.com/top")!, host: "heraldexample.com"),
                PageLink(text: "Opinion: why tariffs miss the point", url: URL(string: "https://heraldexample.com/tariffs")!, host: "heraldexample.com"),
                PageLink(text: "Apple unveils new iPad lineup", url: URL(string: "https://heraldexample.com/ipad")!, host: "heraldexample.com"),
                PageLink(text: "Apple shareholders back buyback plan", url: URL(string: "https://ft-example.com/buyback")!, host: "ft-example.com")
            ]
        }
        app.browser.setPageContext(navigator.pageContext)
        return navigator
    }

    static func makeApp(_ test: XCTestCase) -> AppModel {
        PostLevelURLStub.requests = []
        PostLevelURLStub.cookies = []
        PostLevelURLStub.handler = { request in
            PostLevelURLStub.requests.append(request.url!)
            return (200, DiscourseFixtures.search)
        }
        test.addTeardownBlock { PostLevelURLStub.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PostLevelURLStub.self]
        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(
            store: PersistentStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("state.json")),
            forumService: ForumService(session: URLSession(configuration: configuration), pacer: ForumRequestPacer(clock: InstantPacingClock())),
            aiService: ai
        )
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        return app
    }
}
