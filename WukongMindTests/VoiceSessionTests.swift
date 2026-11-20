import UIKit
import WebKit
import XCTest
@testable import WukongMind

/// The voice session with a fake transport, fake audio and a manual clock:
/// the tool-response hold, scheduling, briefings, silent notes, grounding,
/// resumption and refresh, stalls, idle, mute and comfort noise,
/// typed input and the cost guard.
@MainActor
final class VoiceSessionTests: XCTestCase {
    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private var transports: [FakeLiveTransport] = []
    private var audio = FakeVoiceAudio()
    private var clock = ManualVoiceClock()
    private var navigator = FakeVoiceNavigator()

    override func setUp() async throws {
        transports = []
        audio = FakeVoiceAudio()
        clock = ManualVoiceClock()
        navigator = FakeVoiceNavigator()
    }

    // MARK: Start

    func testStartIsBlockedWithoutKey() async {
        let keyless = makeSession(key: "")
        await keyless.start()
        XCTAssertEqual(keyless.state, .failed(.noKey))
        XCTAssertTrue(transports.isEmpty)
    }

    func testStartSendsTheSetupAndSeedsTheContext() async throws {
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 3, visible: [3, 4])
        navigator.brief = brief()
        navigator.visible = [VisiblePost(number: 3, username: "bob", excerpt: "Try the quiet profile. It helps.")]
        let session = try await started()
        XCTAssertEqual(transports.count, 1)
        XCTAssertEqual(transports[0].requests.first?.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertEqual(transports[0].messages.first, .setup(model: "models/gemini-3.8-live", handle: nil))
        XCTAssertEqual(session.state, .listening)
        await settle()
        let notes = transports[0].messages.compactMap(\.noteText).joined(separator: "\n")
        XCTAssertTrue(notes.hasPrefix("[Screen: the user opened the topic “Fan noise after the update” on Example."), notes)
        XCTAssertTrue(notes.contains("Accepted answer: post 3 by bob."), notes)
        XCTAssertTrue(notes.contains("At Post 3 of 9 by bob."), notes)
        XCTAssertFalse(transports[0].messages.contains { $0.turnText != nil }, "Notes never ask for a reply")
    }

    // MARK: Tool responses

    func testToolResponseWaitsForTheCallsTurnComplete() async throws {
        let session = try await started()
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_1","name":"browse_move","args":{"action":"next"}}]}}"#))
        await settle()
        XCTAssertEqual(navigator.calls.last, "next")
        XCTAssertFalse(sent().contains { $0.isToolResponse }, "Held until the call's turn completes")
        XCTAssertEqual(session.state, .listening)
        session.receive(frame(#"{"serverContent":{"generationComplete":true,"turnComplete":true}}"#))
        XCTAssertEqual(sent().last, .toolResponse(id: "call_1", name: "browse_move", scheduling: "WHEN_IDLE"))
        XCTAssertEqual(session.state, .thinking, "The result's answer is owed")
    }

    func testToolResponseHoldIsCappedAtOneAndAHalfSeconds() async throws {
        let session = try await started()
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_2","name":"read_post","args":{}}]}}"#))
        await settle()
        clock.advance(1.0)
        session.tick()
        XCTAssertFalse(sent().contains { $0.isToolResponse })
        clock.advance(0.5)
        session.tick()
        XCTAssertEqual(sent().last, .toolResponse(id: "call_2", name: "read_post", scheduling: "WHEN_IDLE"))
    }

    func testCancelledCallsAreNotAnswered() async throws {
        let session = try await started()
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_3","name":"search_forum","args":{"query":"fan"}}]}}"#))
        await settle()
        session.receive(frame(#"{"toolCallCancellation":{"ids":["call_3"]}}"#))
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertFalse(sent().contains { $0.isToolResponse })
    }

    func testInterruptIsDowngradedWhileSpeakingOrPlaying() async throws {
        let session = try await started()
        XCTAssertEqual(session.downgraded(.interrupt), .interrupt)
        audio.isPlaying = true
        XCTAssertEqual(session.downgraded(.interrupt), .whenIdle, "Queued playback counts as speaking")
        XCTAssertEqual(session.downgraded(.silent), .silent)
        session.brief(VoiceBriefing(kind: .context, facts: ["facts": "x"], scheduling: .interrupt))
        XCTAssertEqual(sent().last, .toolResponse(id: "b-1", name: "briefing", scheduling: "WHEN_IDLE"))
        audio.isPlaying = false
        session.receive(audioFrame())
        XCTAssertEqual(session.downgraded(.interrupt), .whenIdle, "The model's own audio counts too")
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(session.downgraded(.interrupt), .interrupt)
    }

    func testBriefingsUseMadeUpIDsAndWaitForTheConnection() async throws {
        let session = makeSession()
        await session.start()
        session.brief(VoiceBriefing(kind: .context, facts: ["facts": "early"], scheduling: .silent))
        XCTAssertFalse(sent().contains { $0.isToolResponse }, "Queued until setup completes")
        session.receive(frame(#"{"setupComplete":{}}"#))
        session.brief(VoiceBriefing(kind: .context, facts: ["facts": "later"], scheduling: .whenIdle))
        let responses = sent().filter(\.isToolResponse)
        XCTAssertEqual(responses, [
            .toolResponse(id: "b-1", name: "briefing", scheduling: "SILENT"),
            .toolResponse(id: "b-2", name: "briefing", scheduling: "WHEN_IDLE")
        ])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(transports[0].sent.last!.utf8)) as? [String: Any])
        let response = (((object["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])?.first)?["response"] as? [String: Any]
        XCTAssertEqual(response?["facts"] as? String, "later")
        XCTAssertTrue((response?["about_this"] as? String)?.hasPrefix("Not the user speaking") ?? false)
    }

    // MARK: Hand-off

    func testHandOffStartsProgressesAndBriefsTheAnswer() async throws {
        navigator.holdsHandOff = true
        let session = try await started()
        session.tools.progressInterval = .milliseconds(10)
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_r","name":"hand_off_to_agent","args":{"request":"what are the main objections"}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(sent().last, .toolResponse(id: "call_r", name: "hand_off_to_agent", scheduling: "SILENT"), "started, at once")
        XCTAssertEqual(navigator.calls.last, "hand off what are the main objections")

        navigator.handOffProgress = "Step 2, read_topic 42"
        try await waitUntil { self.sent().contains(.toolResponse(id: "b-1", name: "briefing", scheduling: "SILENT")) }

        navigator.releaseHandOff()
        try await waitUntil { self.sent().contains(.toolResponse(id: "b-2", name: "briefing", scheduling: "WHEN_IDLE")) }
        let answer = try lastResponse()
        XCTAssertEqual(answer["kind"] as? String, "agent answer")
        XCTAssertEqual(answer["answer"] as? String, "Lower the fan curve in the quiet profile Fan noise.", "Links and marks go")
        XCTAssertTrue((answer["message"] as? String)?.contains("about two sentences") ?? false)
        XCTAssertTrue((answer["message"] as? String)?.contains("in the panel") ?? false)
    }

    func testANewHandOffReplacesTheOldAndCancelStopsIt() async throws {
        navigator.holdsHandOff = true
        let session = try await started()
        session.tools.progressInterval = .seconds(60)
        for (id, question) in [("call_a", "first question"), ("call_b", "second question")] {
            session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"\#(id)","name":"hand_off_to_agent","args":{"request":"\#(question)"}}]}}"#))
            await settle()
            session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        }
        await settle()
        XCTAssertEqual(navigator.calls.filter { $0.hasPrefix("hand off") }, ["hand off first question", "hand off second question"])
        XCTAssertFalse(sent().contains { if case .toolResponse(_, "briefing", _) = $0 { return true }; return false },
                       "The replaced hand-off briefs nothing")

        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_c","name":"hand_off_to_agent","args":{"action":"cancel"}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(navigator.calls.last, "cancel hand-off")
        XCTAssertEqual(try lastResponse()["status"] as? String, "cancelled")
        await settle()
        XCTAssertFalse(sent().contains { if case .toolResponse(_, "briefing", _) = $0 { return true }; return false })
    }

    func testAHandOffThatCannotStartIsRefusedNotStarted() async throws {
        navigator.handOffRefusal = "Choose a tool-calling model for the browser agent in Settings."
        let session = try await started()
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_r","name":"hand_off_to_agent","args":{"request":"why"}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        let response = try lastResponse()
        XCTAssertEqual(response["status"] as? String, "unavailable")
        XCTAssertEqual(response["shown"] as? String, "Choose a tool-calling model for the browser agent in Settings.")
    }

    func testUnacknowledgedHandOffGetsANudgeAndAnUnspokenAnswerIsResent() async throws {
        navigator.holdsHandOff = true
        let session = try await started()
        session.tools.progressInterval = .seconds(60)
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_r","name":"hand_off_to_agent","args":{"request":"why"}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        clock.advance(1.6)
        session.tick()
        XCTAssertEqual(sent().last?.turnText, VoiceWatchdog.acknowledgementPrompt)

        session.receive(audioFrame())
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        navigator.releaseHandOff()
        try await waitUntil { self.sent().contains(.toolResponse(id: "b-1", name: "briefing", scheduling: "WHEN_IDLE")) }
        clock.advance(5)
        session.tick()
        XCTAssertNil(sent().last?.turnText)
        clock.advance(1.1)
        session.tick()
        XCTAssertTrue(sent().last?.turnText?.contains("Lower the fan curve") ?? false, "\(String(describing: sent().last))")
    }

    /// The real hand-off: a fake-transport session sends the request to a
    /// real Agent session (recorded model), which shows the run like a typed
    /// one; its answer is briefed, and cancel stops the run.
    func testAHandOffRunsTheAgentAndBriefsItsAnswerAndCancelStopsIt() async throws {
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "c1", name: "read_page", arguments: [:])])),
            .success(AgentModelTurnResponse(text: "Most regret it: two boxes wore out [Soldered eMMC](https://forum.example/t/emmc/9)."))
        ])
        let agent = Self.agentSession(client: client)
        navigator.agentHandOff = AgentHandOff(agent: agent)
        let session = try await started()
        session.tools.progressInterval = .seconds(60)
        session.onTranscript = { role, text, date in agent.appendVoiceTurn(role, text: text, at: date) }
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"What do people think of soldered eMMC?"}}}"#))
        // The acknowledgement streams across the tool call, as it does live (spike Q4).
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"I'll have"}}}"#))
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_h","name":"hand_off_to_agent","args":{"request":"What do people here think of soldered eMMC?"}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":" the Agent look."}}}"#))
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(sent().last, .toolResponse(id: "call_h", name: "hand_off_to_agent", scheduling: "SILENT"))

        try await waitUntil(timeout: 15) { self.briefing(kinds: ["agent answer", "agent ended"]) != nil }
        let briefed = try XCTUnwrap(briefing(kinds: ["agent answer", "agent ended"]))
        XCTAssertEqual(briefed["answer"] as? String, "Most regret it: two boxes wore out Soldered eMMC.", "\(briefed) \(String(describing: agent.runs.last?.state))")
        let run = try XCTUnwrap(agent.runs.last)
        XCTAssertEqual(run.origin, .voice)
        XCTAssertEqual(run.prompt, "What do people here think of soldered eMMC?")
        XCTAssertEqual(run.toolNames, ["read_page"])
        XCTAssertEqual(agent.voiceTurns.map(\.text), ["What do people think of soldered eMMC?", "I'll have the Agent look."])
        XCTAssertLessThan(agent.voiceTurns[0].createdAt, agent.voiceTurns[1].createdAt)
        XCTAssertLessThan(agent.voiceTurns[1].createdAt, run.startedAt, "One reply, shown before the run it announced")
        guard case .user(let turn)? = client.recordedRequests.first?.messages.first else { return XCTFail("no user turn") }
        XCTAssertTrue(turn.contains("(transcribed speech):\nUser: What do people think of soldered eMMC?\n\nThe user's message:"), turn)
        XCTAssertTrue(turn.hasSuffix("The user's message:\nWhat do people here think of soldered eMMC?"), turn)

        // Cancel: Stop on a running hand-off.
        client.onRequest = { _ in try await Task.sleep(for: .seconds(30)) }
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_2","name":"hand_off_to_agent","args":{"request":"And what about SD cards?"}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        try await waitUntil { agent.isRunning }
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_c","name":"hand_off_to_agent","args":{"action":"cancel"}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(try lastResponse()["status"] as? String, "cancelled")
        XCTAssertFalse(agent.isRunning)
        if case .stopped = agent.runs.last?.state {} else { XCTFail("expected a stopped run, got \(String(describing: agent.runs.last?.state))") }
    }

    func testTheSessionDeclaresTheRegistrysVoiceToolsAndRefusesOthers() async throws {
        let session = try await started()
        let declared = transports[0].declaredNames
        let browse = BrowseToolContext(navigator: navigator, site: navigator.voiceSite, isOnForum: true)
        XCTAssertEqual(declared, FakeVoiceNavigator.forumRegistry(browse).definitions.map(\.name) + ["end", "hand_off_to_agent"])
        XCTAssertFalse(declared.contains("find"))
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_f","name":"find","args":{"query":"fan"}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(try lastResponse()["shown"] as? String, "There is no tool called find.")
        XCTAssertTrue(navigator.calls.isEmpty)
    }

    func testFinishedVoiceTurnsGoToTheConversation() async throws {
        let session = try await started()
        var turns: [String] = []
        session.onTranscript = { role, text, _ in turns.append("\(role.rawValue): \(text)") }
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"Next "}}}"#))
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"post."}}}"#))
        XCTAssertTrue(turns.isEmpty, "Not before the turn ends")
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"You're on post 4."}}}"#))
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(turns, ["voiceUser: Next post.", "voiceReply: You're on post 4."])
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(turns.count, 2, "Nothing twice")

        // An interrupted reply is finished where it was cut; the next turn's reply is whole.
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"The long story is"}}}"#))
        session.receive(frame(#"{"serverContent":{"interrupted":true}}"#))
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"Short version."}}}"#))
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(turns.suffix(2), ["voiceReply: The long story is", "voiceReply: Short version."])

        // Typed input ends the reply in progress before its own words.
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"Half a"}}}"#))
        session.sendText("Stop, go back")
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"Going back."}}}"#))
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(turns.suffix(3), ["voiceReply: Half a", "voiceUser: Stop, go back", "voiceReply: Going back."])
    }

    static func agentSession(client: RecordedModelClient) -> BrowserAgentSession {
        BrowserAgentSession(
            pageDriver: FixturePageDriver(page: .init(url: "https://forum.example/t/fan-noise/42", title: "Fan noise")),
            modelClient: client,
            configProvider: {
                var cfg = ProviderConfiguration(provider: .ollama); cfg.model = "agent-model"
                return BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .ollama, model: "agent-model"), configuration: cfg,
                    maxSteps: 6, truncationLimit: 20_000, customInstructions: "", redactedSecrets: []
                )
            }
        )
    }

    func testToolMarkupSpokenAsTextIsCutAndCorrected() async throws {
        let session = try await started()
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"Sure. <tool_call>find(query"}}}"#))
        XCTAssertEqual(audio.flushes, 1)
        XCTAssertEqual(session.lastModelText, "Sure.")
        session.receive(audioFrame())
        XCTAssertTrue(audio.played.isEmpty, "The rest of the turn is dropped")
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(sent().last?.turnText, VoiceWatchdog.markupCorrection)
    }

    // MARK: Silent notes and grounding

    func testNotesWaitForQuietAndSendOnlyTheChange() async throws {
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 3, visible: [3])
        navigator.brief = brief()
        navigator.visible = [VisiblePost(number: 3, username: "bob", excerpt: "Try the quiet profile.")]
        let session = try await started()
        await settle()
        let before = sent().compactMap(\.noteText).count

        // The model speaks: the next note waits.
        session.receive(audioFrame())
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 4, visible: [4])
        navigator.visible = [VisiblePost(number: 4, username: "carol", excerpt: "Mine is louder after the update.")]
        session.pageChanged(navigator.pageContext)
        await settle()
        XCTAssertEqual(sent().compactMap(\.noteText).count, before)
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        session.tick()
        let delta = try XCTUnwrap(sent().compactMap(\.noteText).last)
        XCTAssertTrue(delta.contains("At Post 4 of 9 by carol."), delta)
        XCTAssertFalse(delta.contains("opened the topic"), "The brief isn't sent again")

        // Nothing changed: no note.
        session.pageChanged(navigator.pageContext)
        await settle()
        session.tick()
        XCTAssertEqual(sent().compactMap(\.noteText).count, before + 1)
    }

    func testScreenReferenceSendsTheFocusedPostBeforeTheAnswer() async throws {
        for words in ["Is this post right?", "他说的对吗", "這一樓在說什麼"] {
            transports = []
            navigator = FakeVoiceNavigator()
            navigator.pageContext = FakeVoiceNavigator.topicPage(post: 5)
            let session = try await started()
            await settle()
            session.captureGate(open: true)
            session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"\#(words)"}}}"#))
            await settle()
            XCTAssertEqual(navigator.calls.filter { $0.hasPrefix("read") }, ["read 5"], words)
            let note = try XCTUnwrap(sent().compactMap(\.noteText).last, words)
            XCTAssertTrue(note.hasPrefix("[Screen: full text of Post 5"), note)
            // Once per post.
            session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":" this one"}}}"#))
            await settle()
            XCTAssertEqual(navigator.calls.filter { $0.hasPrefix("read") }.count, 1)
            session.stop()
        }
        XCTAssertFalse(VoiceContext.refersToScreen("Find posts about fan noise"))
        XCTAssertFalse(VoiceContext.refersToScreen("thispostman"), "Whole words in English")
    }

    func testGroundingSwitchesTurnItOff() async throws {
        var settings = VoiceSettings()
        settings.groundsOnScreenReference = false
        settings.groundsOnDwell = false
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 5)
        let session = try await started(settings: settings)
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"what did he say"}}}"#))
        session.pageChanged(navigator.pageContext)
        clock.advance(3)
        session.tick()
        await settle()
        XCTAssertFalse(navigator.calls.contains { $0.hasPrefix("read") })
    }

    func testDwellingOnAPostSendsItsText() async throws {
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 6)
        let session = try await started()
        session.pageChanged(navigator.pageContext)
        await settle()
        clock.advance(1)
        session.tick()
        XCTAssertFalse(navigator.calls.contains { $0.hasPrefix("read") })
        clock.advance(1.1)
        session.tick()
        await settle()
        session.tick()
        XCTAssertEqual(navigator.calls.filter { $0.hasPrefix("read") }, ["read 6"])
        XCTAssertTrue(sent().compactMap(\.noteText).last?.contains("full text of Post 6") ?? false)
    }

    // MARK: Resumption

    func testAIStudioResumesWithTheHandleAfterClosingAndResendsTheContext() async throws {
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 3)
        navigator.brief = brief()
        let session = try await started()
        await settle()
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"h-1","resumable":true}}"#))
        session.receive(frame(#"{"sessionResumptionUpdate":{"resumable":false}}"#))
        XCTAssertEqual(session.resumptionHandle, "h-1", "A non-resumable update keeps the last handle")

        session.receive(frame(#"{"goAway":{"timeLeft":"50s"}}"#))
        session.tick()
        try await waitForTransports(2)
        XCTAssertEqual(transports.count, 2)
        XCTAssertTrue(transports[0].closed, "Close before resume: AI Studio allows one connection")
        XCTAssertEqual(transports[1].messages.first, .setup(model: "models/gemini-3.8-live", handle: "h-1"))
        session.receive(frame(#"{"setupComplete":{}}"#))
        let notes = transports[1].messages.compactMap(\.noteText)
        XCTAssertTrue(notes.first?.contains("opened the topic") ?? false, "The whole context again: \(notes)")
    }

    func testAIStudioRefreshesFreshBeforeTheHourAndAfterAGoAwayPastIt() async throws {
        let session = try await started(settings: longIdle)
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"h-1","resumable":true}}"#))
        clock.advance(53 * 60)
        session.tick()
        XCTAssertEqual(transports.count, 1)
        clock.advance(60)
        session.tick()
        try await waitForTransports(2)
        XCTAssertEqual(transports.count, 2)
        XCTAssertEqual(transports[1].messages.first, .setup(model: "models/gemini-3.8-live", handle: nil), "A fresh session")
        XCTAssertTrue(transports[0].closed)
        session.receive(frame(#"{"setupComplete":{}}"#))
        XCTAssertNil(session.handleForReconnect(.goAway))

        // A GoAway past the age opens a fresh session too.
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"h-2","resumable":true}}"#))
        XCTAssertEqual(session.handleForReconnect(.goAway), "h-2")
        clock.advance(55 * 60)
        XCTAssertNil(session.handleForReconnect(.goAway))
    }

    func testVertexNeverResumesAResumedSession() async throws {
        let session = try await started(endpoint: .vertex(project: "p", location: "us-central1"), settings: longIdle)
        let model = "projects/p/locations/us-central1/publishers/google/models/gemini-3.8-live"
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"v-0","resumable":true}}"#))
        transports[0].drop()
        try await waitForTransports(2)
        XCTAssertEqual(transports[1].messages.first, .setup(model: model, handle: "v-0"))
        session.receive(frame(#"{"setupComplete":{}}"#))
        XCTAssertEqual(session.connectionGeneration, 1)
        // A handle from the resumed connection is never used, and the
        // generation-0 one no longer covers this connection's turns.
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"v-1","resumable":true}}"#))
        XCTAssertNil(session.resumptionHandle)
        transports[1].drop()
        try await waitForTransports(3)
        XCTAssertEqual(transports[2].messages.first, .setup(model: model, handle: nil), "Fresh, seeded with the context")
        // No 54-minute refresh on Vertex.
        session.receive(frame(#"{"setupComplete":{}}"#))
        clock.advance(70 * 60)
        session.receive(frame("{}"))
        session.tick()
        XCTAssertEqual(transports.count, 3)
    }

    func testAnExpiredSessionStartsFreshAndARefusalFails() async throws {
        let session = try await started()
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"h-1","resumable":true}}"#))
        transports[0].drop(LiveClose(code: 1008, reason: "Requested entity was not found."))
        try await waitForTransports(2)
        XCTAssertEqual(transports[1].messages.first, .setup(model: "models/gemini-3.8-live", handle: nil))
        session.receive(frame(#"{"setupComplete":{}}"#))

        let refused = makeSession()
        await refused.start()
        transports.last?.drop(LiveClose(code: 1008, reason: "API keys are not supported by this API."))
        try await waitUntil { refused.state == .failed(.refused("API keys are not supported by this API.")) }
        XCTAssertEqual(refused.state, .failed(.refused("API keys are not supported by this API.")))
    }

    func testStalledTurnRecyclesTheConnectionWithTheHandle() async throws {
        let session = try await started()
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"h-1","resumable":true}}"#))
        session.captureGate(open: true)
        session.microphoneFrame(Data(repeating: 1, count: 1280))
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"next one"}}}"#))
        session.captureGate(open: false)
        clock.advance(1.0)
        session.tick()
        XCTAssertEqual(sent().last, .audioStreamEnd)
        XCTAssertEqual(session.state, .thinking)
        clock.advance(9)
        session.tick()
        XCTAssertEqual(transports.count, 1)
        clock.advance(1.1)
        session.tick()
        try await waitForTransports(2)
        XCTAssertEqual(transports.count, 2)
        XCTAssertEqual(transports[1].messages.first, .setup(model: "models/gemini-3.8-live", handle: "h-1"))
    }

    func testNoiseWithoutWordsIsNoStall() async throws {
        let session = try await started()
        session.captureGate(open: true)
        session.microphoneFrame(Data(repeating: 1, count: 1280))
        session.captureGate(open: false)
        clock.advance(1.0)
        session.tick()
        XCTAssertEqual(sent().last, .audioStreamEnd)
        XCTAssertEqual(session.state, .listening, "A cough owes no reply")
        session.queueNote("[Screen: x]")
        XCTAssertEqual(sent().last?.noteText, "[Screen: x]", "Quiet again: notes flow")
        clock.advance(11)
        session.tick()
        XCTAssertEqual(transports.count, 1)

        // Words transcribed after the stream ended: now a reply is owed.
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"go back"}}}"#))
        XCTAssertEqual(session.state, .thinking)
    }

    func testAFailedGroundingReadIsRetried() async throws {
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 5)
        navigator.results["read"] = BrowseResult(status: .notFound, shown: "Post 5 couldn't be read.")
        let session = try await started()
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"is this post right"}}}"#))
        await settle()
        navigator.results["read"] = nil
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"what about this one"}}}"#))
        await settle()
        XCTAssertEqual(navigator.calls.filter { $0.hasPrefix("read") }.count, 2)
        XCTAssertTrue(sent().compactMap(\.noteText).last?.contains("full text of Post 5") ?? false)
    }

    // MARK: Idle, end, usage

    func testIdleSessionCloses() async throws {
        var settings = VoiceSettings()
        settings.idleTimeout = 60
        let session = try await started(settings: settings)
        clock.advance(59)
        session.tick()
        XCTAssertEqual(session.state, .listening)
        clock.advance(2)
        session.tick()
        XCTAssertEqual(session.state, .ended(.idle))
        XCTAssertTrue(transports[0].closed)
        XCTAssertTrue(audio.stopped)
        XCTAssertGreaterThan(session.connectedSeconds, 0)
    }

    /// WUKO-124: an idle close leaves the handle; the next tap resumes with
    /// it and sends the page note itself (the new session's context is empty).
    func testIdleCloseResumesOnTheNextTapWithThePageNote() async throws {
        navigator.pageContext = PageContext(url: URL(string: "https://news.example.org/a")!, state: .notForum)
        navigator.explicitPageTitle = "Markets"
        let first = try await started()
        first.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"h-1","resumable":true}}"#))
        clock.advance(VoiceSettings.defaultIdleTimeout + 1)
        first.tick()
        XCTAssertEqual(first.state, .ended(.idle))
        XCTAssertTrue(transports[0].closed, "The socket closes when idle")
        let resumption = try XCTUnwrap(first.resumption)
        XCTAssertEqual(resumption.handle, "h-1")

        clock.advance(60)
        let second = makeSession()
        await second.start(resuming: resumption)
        XCTAssertEqual(transports[1].messages.first, .setup(model: "models/gemini-3.8-live", handle: "h-1"))
        second.receive(frame(#"{"setupComplete":{}}"#))
        await settle()
        let notes = transports[1].messages.compactMap(\.noteText).joined(separator: "\n")
        XCTAssertTrue(notes.contains("[Screen: the user is on \"Markets\" at news.example.org"), notes)

        // A user's own stop, or a handle past the window, starts fresh.
        second.stop()
        XCTAssertNil(second.resumption)
        clock.advance(VoiceSession.Resumption.window)
        let third = makeSession()
        await third.start(resuming: resumption)
        XCTAssertEqual(transports[2].messages.first, .setup(model: "models/gemini-3.8-live", handle: nil))
        // Another key or endpoint never takes the handle either.
        XCTAssertFalse(resumption.usable(by: .init(endpoint: .aiStudio, apiKey: "other"), at: resumption.endedAt))
    }

    /// On Vertex a resumed connection's handles are dropped, so a session
    /// that itself resumed leaves nothing to resume; a dead handle starts fresh.
    func testVertexResumedSessionLeavesNoHandleAndADeadHandleStartsFresh() async throws {
        let vertex = GeminiLive.Endpoint.vertex(project: "p", location: "us-central1")
        let model = "projects/p/locations/us-central1/publishers/google/models/gemini-3.8-live"
        let first = try await started(endpoint: vertex)
        first.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"v-0","resumable":true}}"#))
        clock.advance(VoiceSettings.defaultIdleTimeout + 1)
        first.tick()
        let resumption = try XCTUnwrap(first.resumption)

        let second = makeSession(endpoint: vertex)
        await second.start(resuming: resumption)
        XCTAssertEqual(transports[1].messages.first, .setup(model: model, handle: "v-0"))
        transports[1].drop(LiveClose(code: 1008, reason: "Requested entity was not found."))
        try await waitForTransports(3)
        XCTAssertEqual(transports[2].messages.first, .setup(model: model, handle: nil), "A dead handle: fresh")
        second.receive(frame(#"{"setupComplete":{}}"#))
        XCTAssertEqual(second.state, .listening)
        second.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"v-1","resumable":true}}"#))

        let third = makeSession(endpoint: vertex)
        await third.start(resuming: resumption)
        XCTAssertEqual(transports[3].messages.first, .setup(model: model, handle: "v-0"))
        third.receive(frame(#"{"setupComplete":{}}"#))
        third.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"v-2","resumable":true}}"#))
        clock.advance(VoiceSettings.defaultIdleTimeout + 1)
        third.tick()
        XCTAssertEqual(third.state, .ended(.idle))
        XCTAssertNil(third.resumption, "A resumed Vertex connection's handle is never used")
    }

    /// The idle clock starts when the session goes quiet: a reply still
    /// playing, or a hand-off still running, never counts toward it.
    func testIdleCountsFromTheEndOfPlaybackAndOfAHandOff() async throws {
        let session = try await started()
        session.receive(audioFrame())
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        audio.isPlaying = true
        clock.advance(25)
        session.tick()
        XCTAssertEqual(session.state, .speaking)
        audio.isPlaying = false
        clock.advance(0.1)
        session.tick()
        XCTAssertEqual(session.state, .listening, "Not closed as the reply ends")
        clock.advance(VoiceSettings.defaultIdleTimeout - 1)
        session.tick()
        XCTAssertEqual(session.state, .listening)

        // A hand-off running longer than the timeout keeps it open.
        navigator.holdsHandOff = true
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_h","name":"hand_off_to_agent","args":{"request":"dark mode"}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        clock.advance(30)
        session.tick()
        XCTAssertFalse(session.state.isOver, "A hand-off still running is not idle")
        navigator.releaseHandOff()
        await settle()
        session.stop()
    }

    func testIdleDefaultIsShortAndAnOldSavedDefaultMovesToIt() throws {
        XCTAssertEqual(VoiceSettings().idleTimeout, 20)
        let old = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"idleTimeout":60}"#.utf8))
        XCTAssertEqual(old.idleTimeout, 20, "60 was the old default, saved without a revision")
        var chosen = VoiceSettings()
        chosen.idleTimeout = 60
        let saved = try JSONDecoder().decode(VoiceSettings.self, from: JSONEncoder().encode(chosen))
        XCTAssertEqual(saved.idleTimeout, 60, "A 60 picked since then stays")
        let other = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"idleTimeout":120}"#.utf8))
        XCTAssertEqual(other.idleTimeout, 120)
    }

    func testEndToolClosesAfterTheGoodbye() async throws {
        let session = try await started()
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"Bye for now."}}}"#))
        session.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"call_e","name":"end","args":{}}]}}"#))
        await settle()
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(sent().last, .toolResponse(id: "call_e", name: "end", scheduling: "SILENT"))
        audio.isPlaying = true
        clock.advance(1)
        session.tick()
        XCTAssertFalse(session.state.isOver, "The goodbye is still playing")
        audio.isPlaying = false
        session.tick()
        XCTAssertEqual(session.state, .ended(.model))
    }

    func testMinutesAreCountedPerSessionAndPerDay() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "voice-usage-\(UUID().uuidString)"))
        let store = VoiceUsageStore(defaults: defaults)
        var settings = VoiceSettings()
        settings.idleTimeout = 600
        let session = try await started(settings: settings, usage: store)
        for _ in 0..<30 {
            clock.advance(2)
            session.tick()
        }
        session.stop()
        XCTAssertEqual(session.connectedSeconds, 60, accuracy: 0.01)
        XCTAssertEqual(store.minutes(on: clock.now), 1, accuracy: 0.01)
        XCTAssertEqual(store.lastSessionSeconds, 60, accuracy: 0.01)
        store.add(seconds: 30, at: clock.now, sessionTotal: 30)
        XCTAssertEqual(store.seconds(on: clock.now), 90, accuracy: 0.01)
        XCTAssertEqual(store.seconds(on: clock.now.addingTimeInterval(-86_400 * 2)), 0)
    }

    // MARK: Cost guard

    func testTheSessionLimitEndsAfterTheCurrentAnswer() async throws {
        var settings = VoiceSettings()
        settings.idleTimeout = 100_000
        settings.sessionLimitMinutes = 5
        let session = try await started(settings: settings)
        for _ in 0..<149 {
            clock.advance(2)
            session.tick()
        }
        XCTAssertEqual(session.state, .listening, "Just under five minutes")
        session.receive(audioFrame())
        audio.isPlaying = true
        clock.advance(2)
        session.tick()
        XCTAssertEqual(session.limitReached, .sessionLimit)
        XCTAssertFalse(session.state.isOver, "The answer that is playing finishes")
        audio.isPlaying = false
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        clock.advance(1.1)
        session.tick()
        XCTAssertEqual(session.state, .ended(.sessionLimit))
        XCTAssertTrue(transports[0].closed)
    }

    func testTheDailyLimitRefusesANewSessionAndEndsARunningOne() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "voice-usage-\(UUID().uuidString)"))
        let store = VoiceUsageStore(defaults: defaults)
        var settings = VoiceSettings()
        settings.idleTimeout = 100_000
        settings.dailyLimitMinutes = 30
        settings.sessionLimitMinutes = 0
        store.add(seconds: 29 * 60, at: clock.now, sessionTotal: 0)
        let session = try await started(settings: settings, usage: store)
        for _ in 0..<35 {
            clock.advance(2)
            session.tick()
        }
        XCTAssertEqual(session.state, .ended(.dailyLimit))

        let next = makeSession(settings: settings, usage: store)
        await next.start()
        XCTAssertEqual(next.state, .ended(.dailyLimit))
        XCTAssertEqual(transports.count, 1, "Nothing connects once today's minutes are used")

        settings.dailyLimitMinutes = 0
        let unlimited = makeSession(settings: settings, usage: store)
        await unlimited.start()
        XCTAssertEqual(unlimited.state, .connecting)
    }

    func testLimitsDecodeAndZeroMeansNone() throws {
        XCTAssertEqual(VoiceSettings().sessionLimitMinutes, 15)
        XCTAssertEqual(VoiceSettings().dailyLimitMinutes, 30)
        XCTAssertEqual(VoiceSettings().voiceName, VoiceCatalog.defaultVoice)
        XCTAssertTrue(VoiceCatalog.voices.contains { $0.name == VoiceCatalog.defaultVoice })
        XCTAssertEqual(Set(VoiceCatalog.voices.map(\.name)).count, VoiceCatalog.voices.count)
        let decoded = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"sessionLimitMinutes":0,"dailyLimitMinutes":-4}"#.utf8))
        XCTAssertEqual(decoded.sessionLimitMinutes, 0)
        XCTAssertEqual(decoded.dailyLimitMinutes, 0)
        XCTAssertNil(VoiceSettings.limit(0))
        XCTAssertEqual(VoiceSettings.limit(15), 900)
    }

    // MARK: Typed input

    func testTypedTextGoesAsRealtimeTextAndAReplyIsOwed() async throws {
        let session = try await started()
        session.sendText("  take me to the solution ")
        let last = try XCTUnwrap(transports[0].sent.last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        XCTAssertEqual((object["realtimeInput"] as? [String: Any])?["text"] as? String, "take me to the solution")
        XCTAssertEqual(session.lastUserText, "take me to the solution", "No input transcription comes back for text")
        XCTAssertEqual(session.state, .thinking)
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"Opening it."}}}"#))
        XCTAssertEqual(session.lastModelText, "Opening it.")
        session.sendText("   ")
        XCTAssertEqual(transports[0].sent.last, last, "Blank text is not sent")
    }

    func testATypedScreenReferenceReadsTheFocusedPost() async throws {
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 3, visible: [3])
        let session = try await started()
        await settle()
        session.sendText("is this post right?")
        await settle()
        XCTAssertTrue(navigator.calls.contains("read 3"), "\(navigator.calls)")
    }

    // MARK: Audio

    func testMuteSendsNothing() async throws {
        let session = try await started()
        session.setMuted(true)
        session.captureGate(open: true)
        session.microphoneFrame(Data(repeating: 1, count: 1280))
        session.captureGate(open: false)
        clock.advance(2)
        session.tick()
        XCTAssertFalse(sent().contains { $0.isAudio || $0 == .audioStreamEnd })

        // Muting mid-utterance ends the turn at once, without noise.
        session.setMuted(false)
        session.captureGate(open: true)
        session.microphoneFrame(Data(repeating: 1, count: 1280))
        session.setMuted(true)
        XCTAssertEqual(sent().suffix(2), [.audio(1280), .audioStreamEnd])
    }

    func testComfortNoiseAtRealTimePaceThenStreamEnd() async throws {
        let session = try await started()
        session.captureGate(open: true)
        session.microphoneFrame(Data(repeating: 1, count: 1280))
        session.captureGate(open: false)
        clock.advance(0.5)
        session.tick()
        let halfway = sent().filter(\.isAudio).count
        XCTAssertEqual(halfway, 1 + 13, "About half a second of 40 ms frames")
        XCTAssertNotEqual(sent().last, .audioStreamEnd)
        clock.advance(0.6)
        session.tick()
        XCTAssertEqual(sent().filter(\.isAudio).count, 1 + 25)
        XCTAssertEqual(sent().last, .audioStreamEnd)
        let noise = ComfortNoise.frame(seed: &seed)
        XCTAssertEqual(noise.count, 1280)
        let samples = noise.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertTrue(samples.allSatisfy { abs($0) <= 8 })
        XCTAssertTrue(samples.contains { $0 != 0 }, "Never zeros")
    }

    func testModelAudioPlaysAndInterruptionFlushes() async throws {
        let session = try await started()
        session.receive(audioFrame())
        XCTAssertEqual(audio.played.count, 1)
        XCTAssertEqual(session.state, .speaking)
        session.receive(frame(#"{"serverContent":{"interrupted":true}}"#))
        XCTAssertEqual(audio.flushes, 1)
        session.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(session.state, .listening)
    }

    // MARK: Voice anywhere (fixed tool set and settled page notes)

    func testSettledPagesSendOneNoteWithTitleAndHostAndNeverPathOrQuery() async throws {
        // Loading and `.maybe` states send nothing before the page settles.
        navigator.pageContext = PageContext(url: URL(string: "https://news.example.org/private/99?token=s3cr3t")!, state: .loading)
        navigator.explicitPageTitle = "Quarterly Outlook at WTO"
        let session = try await started()
        await settle()
        XCTAssertTrue(sent().compactMap(\.noteText).isEmpty)

        navigator.pageContext.state = .maybe
        session.pageChanged(navigator.pageContext)
        await settle()
        XCTAssertTrue(sent().compactMap(\.noteText).isEmpty)

        // Settled ordinary page: title + host only, never scheme, path, query or fragment.
        let ordinaryURL = URL(string: "https://news.example.org/private/room/99?token=s3cr3t&session=abc#section-2")!
        navigator.pageContext = PageContext(url: ordinaryURL, state: .notForum)
        session.pageChanged(navigator.pageContext)
        await settle()
        let notes1 = sent().compactMap(\.noteText)
        XCTAssertEqual(notes1, [
            "[Screen: the user is on \"Quarterly Outlook at WTO\" at news.example.org, an ordinary web page. Forum tools don't work here.]"
        ])
        for forbidden in ["https://", "private", "room", "99", "token", "s3cr3t", "session", "section-2"] {
            XCTAssertFalse(notes1[0].contains(forbidden), "Leaked \(forbidden) in \(notes1[0])")
        }

        // Transcription vocabulary takes words from the ordinary page's title.
        let vocab = VoiceSession.vocabulary(page: navigator.pageContext, title: navigator.pageTitle)
        XCTAssertTrue(vocab.contains("Quarterly Outlook at WTO"))
        XCTAssertTrue(vocab.contains("Quarterly"))
        XCTAssertTrue(vocab.contains("Outlook"))

        // Same settled document (including a fragment jump): no duplicate note.
        navigator.pageContext.url = URL(string: "https://news.example.org/private/room/99?token=s3cr3t&session=abc#other")!
        session.pageChanged(navigator.pageContext)
        await settle()
        XCTAssertEqual(sent().compactMap(\.noteText).count, 1)

        // A reconnect on an ordinary page re-sends that settled note once.
        session.receive(frame(#"{"sessionResumptionUpdate":{"newHandle":"h-ord","resumable":true}}"#))
        session.receive(frame(#"{"goAway":{"timeLeft":"50s"}}"#))
        session.tick()
        try await waitForTransports(2)
        session.receive(frame(#"{"setupComplete":{}}"#))
        await settle()
        XCTAssertEqual(transports[1].messages.compactMap(\.noteText), notes1)

        // Settled forum page: forum name + kind, title + host, adapter hints, and no path or query.
        let forumURL = URL(string: "https://forum.example.org/u/alice/messages?api_key=topsecret#inbox")!
        navigator.voiceSite = VoiceSite(adapter: DiscourseAdapter())
        navigator.explicitPageTitle = "Latest Discussions"
        navigator.pageContext = PageContext(
            url: forumURL, site: .discourse, siteURL: "https://forum.example.org", forumName: "Example", state: .forumHome
        )
        session.pageChanged(navigator.pageContext)
        await settle()
        let forumNote = try XCTUnwrap(sent().compactMap(\.noteText).last)
        XCTAssertTrue(forumNote.hasPrefix("[Screen: the user is on the forum Example (Discourse), \"Latest Discussions\" at forum.example.org. Forum tools work here."), forumNote)
        XCTAssertTrue(forumNote.contains(DiscourseAdapter().voice.findHint), forumNote)
        XCTAssertTrue(forumNote.contains(DiscourseAdapter().voice.languageHint), forumNote)
        for forbidden in ["https://", "alice", "messages", "api_key", "topsecret", "inbox"] {
            XCTAssertFalse(forumNote.contains(forbidden), "Leaked \(forbidden) in \(forumNote)")
        }

        // Another settled ordinary page on the earlier host sends one new note.
        navigator.voiceSite = SiteRegistry.standard.voiceFallback
        navigator.explicitPageTitle = "Second Story"
        navigator.pageContext = PageContext(url: URL(string: "https://news.example.org/another/path?k=v")!, state: .notForum)
        session.pageChanged(navigator.pageContext)
        await settle()
        XCTAssertEqual(
            sent().compactMap(\.noteText).last,
            "[Screen: the user is on \"Second Story\" at news.example.org, an ordinary web page. Forum tools don't work here.]"
        )
    }

    func testSessionMovesBetweenOrdinaryPageAndForumWithoutReconnecting() async throws {
        let app = makeStubbedApp()
        app.recordVisit(siteURL: "https://forum.example", kind: .discourse, name: "Example", iconURL: nil)

        let ordinaryURL = URL(string: "https://bbc.example/news/story-1?token=priv#top")!
        app.browser.webView.loadHTMLString(
            "<html><head><title>Tariff Talks</title></head><body><h1>Tariff Talks</h1><p>Markets held steady today.</p></body></html>",
            baseURL: ordinaryURL
        )
        try await waitUntil(timeout: 20) { app.browser.webView.title == "Tariff Talks" && !app.browser.webView.isLoading }
        let ordinaryPage = PageContext(url: ordinaryURL, state: .notForum)
        let forumPage = PageContext(
            url: URL(string: "https://forum.example/latest")!, site: .discourse,
            siteURL: "https://forum.example", forumName: "Example", state: .forumHome
        )
        var appTransports: [FakeLiveTransport] = []
        func startAppSession(on page: PageContext) async throws -> VoiceSession {
            app.browser.setPageContext(page)
            appTransports = []
            let s = try app.makeVoiceSession(audio: FakeVoiceAudio(), transport: {
                let t = FakeLiveTransport(); appTransports.append(t); return t
            }).get()
            await s.start()
            s.receive(frame(#"{"setupComplete":{}}"#))
            await settle()
            return s
        }

        // 1. Start on an ordinary page, then move to a forum and search it.
        let session1 = try await startAppSession(on: ordinaryPage)
        XCTAssertEqual(appTransports[0].messages.compactMap(\.noteText), [
            "[Screen: the user is on \"Tariff Talks\" at bbc.example, an ordinary web page. Forum tools don't work here.]"
        ])
        session1.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"c1","name":"search_forum","args":{"query":"badges"}}]}}"#))
        await settle()
        session1.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(try decodeLastResponse(in: appTransports[0])["shown"] as? String, VoiceToolBridge.notForumMessage)
        session1.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))

        app.browser.setPageContext(forumPage)
        session1.pageChanged(forumPage)
        await settle()
        XCTAssertEqual(appTransports.count, 1, "No reconnect when switching page kinds")
        XCTAssertTrue(appTransports[0].messages.compactMap(\.noteText).last?.contains("Forum tools work here.") == true)

        session1.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"c2","name":"search_forum","args":{"query":"badges"}}]}}"#))
        try await waitUntil {
            session1.receive(self.frame(#"{"serverContent":{"turnComplete":true}}"#))
            return appTransports[0].sent.filter { $0.contains("toolResponse") }.count >= 2
        }
        let searchedOnForum = try decodeLastResponse(in: appTransports[0])
        XCTAssertEqual(searchedOnForum["status"] as? String, "found")
        XCTAssertEqual((searchedOnForum["hits"] as? [[String: Any]])?.count, 4)
        session1.stop()
        app.voiceSessionEnded()

        // 2. Start on a forum, then move to an ordinary page and run `read_page`.
        let session2 = try await startAppSession(on: forumPage)
        app.browser.setPageContext(ordinaryPage)
        session2.pageChanged(ordinaryPage)
        await settle()
        XCTAssertEqual(appTransports.count, 1, "No reconnect when moving from forum to ordinary page")
        XCTAssertTrue(appTransports[0].messages.compactMap(\.noteText).last?.contains("Forum tools don't work here.") == true)

        session2.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"c3","name":"read_page","args":{}}]}}"#))
        try await waitUntil(timeout: 15) {
            session2.receive(self.frame(#"{"serverContent":{"turnComplete":true}}"#))
            return !appTransports[0].sent.filter { $0.contains("toolResponse") }.isEmpty
        }
        let pageRead = try decodeLastResponse(in: appTransports[0])
        XCTAssertEqual(pageRead["status"] as? String, "done")
        let readResult = pageRead["result"] as? String ?? ""
        XCTAssertTrue(readResult.contains("Tariff Talks") && readResult.contains("Markets held steady today."), readResult)

        session2.receive(frame(#"{"toolCall":{"functionCalls":[{"id":"c4","name":"search_forum","args":{"query":"badges"}}]}}"#))
        await settle()
        session2.receive(frame(#"{"serverContent":{"turnComplete":true}}"#))
        XCTAssertEqual(try decodeLastResponse(in: appTransports[0])["shown"] as? String, VoiceToolBridge.notForumMessage)
        session2.stop()
        app.voiceSessionEnded()
    }

    /// Opt-in live Gemini Live routing check (voice-review.md §6 "For task 2"):
    /// tries VERTEX_API_KEY first when set, falls back to GEMINI_LIVE_KEY.
    func testLiveGeminiAnywhereRoutingOnForumAndOrdinaryPage() async throws {
        let env = ProcessInfo.processInfo.environment
        let vertexKey = (env["VERTEX_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let studioKey = (env["GEMINI_LIVE_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vertexKey.isEmpty || !studioKey.isEmpty else {
            throw XCTSkip("Neither VERTEX_API_KEY nor GEMINI_LIVE_KEY is set for the test runner.")
        }

        var chosenEndpoint: GeminiLive.Endpoint?
        var chosenKey = ""
        var endpointNote = ""
        if !vertexKey.isEmpty {
            let project = GeminiLive.Endpoint.vertexProject(fromBaseURL: env["VERTEX_BASE_URL"] ?? "")
                ?? (env["VERTEX_PROJECT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = GeminiLive.Endpoint.vertex(project: project, location: GeminiLive.Endpoint.vertexLocation)
            let probe = VoiceSession(configuration: .init(endpoint: candidate, apiKey: vertexKey), audio: FakeVoiceAudio(), navigator: nil, usage: nil, runsLoop: false)
            await probe.start()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, probe.state == .connecting { try await Task.sleep(for: .milliseconds(50)) }
            if probe.state == .listening {
                chosenEndpoint = candidate
                chosenKey = vertexKey
                endpointNote = project.isEmpty ? "vertex express (us-central1)" : "vertex (\(project))"
            } else {
                endpointNote = "vertex failed (\(probe.state)); "
            }
            probe.stop()
        }
        if chosenEndpoint == nil {
            guard !studioKey.isEmpty else { throw XCTSkip("Vertex Live could not connect (\(endpointNote)) and GEMINI_LIVE_KEY is not set.") }
            chosenEndpoint = .aiStudio; chosenKey = studioKey; endpointNote += "aiStudio (GEMINI_LIVE_KEY)"
        }
        let endpoint = try XCTUnwrap(chosenEndpoint)
        print("[LIVE-VOICE] model=\(GeminiLive.model) endpoint=\(endpointNote)")

        let app = makeStubbedApp()
        app.recordVisit(siteURL: "https://forum.example", kind: .discourse, name: "Home Lab Talk", iconURL: nil)
        var settings = VoiceSettings()
        settings.answerLength = .short

        func startLive(on page: PageContext, into replies: UnsafeMutablePointer<[String]>) async throws -> VoiceSession {
            app.browser.setPageContext(page)
            let s = VoiceSession(configuration: .init(endpoint: endpoint, apiKey: chosenKey, settings: settings), audio: FakeVoiceAudio(), navigator: app, usage: nil, runsLoop: false)
            s.tools.registryBuilder = app.voiceToolRegistry
            s.onTranscript = { role, text, _ in if role == .voiceReply { replies.pointee.append(text) } }
            await s.start()
            try await waitUntil(timeout: 12) { s.state == .listening }
            try await Task.sleep(for: .milliseconds(250))
            return s
        }

        // 1. Forum routing (3 runs): "Search for firmware rollback." -> search_forum, then "Open the second one." -> browse_open.
        let forumPage = PageContext(url: URL(string: "https://forum.example/latest")!, site: .discourse, siteURL: "https://forum.example", forumName: "Home Lab Talk", state: .forumHome)
        var searchHits = 0, openSecondHits = 0
        for rep in 1...3 {
            var replies: [String] = []
            let session = try await startLive(on: forumPage, into: &replies)
            session.sendText("Search for firmware rollback.")
            try await waitUntil(timeout: 20) { session.tick(); return !replies.isEmpty && session.state == .listening }
            let didSearch = app.browseCursor.items.count == 4
            if didSearch { searchHits += 1 }
            print("[LIVE-VOICE] forum rep=\(rep) search_forum=\(didSearch) reply1=\(replies.last ?? "")")
            if didSearch {
                let before = replies.count
                session.sendText("Open the second one.")
                try await waitUntil(timeout: 20) { session.tick(); return replies.count > before && session.state == .listening }
                let didOpenSecond = app.browseCursor.index == 1
                if didOpenSecond { openSecondHits += 1 }
                print("[LIVE-VOICE] forum rep=\(rep) browse_open_card2=\(didOpenSecond) reply2=\(replies.last ?? "")")
            }
            session.stop()
            app.browseCursor = BrowseCursor()
        }
        XCTAssertGreaterThanOrEqual(searchHits, 2, "search_forum routed \(searchHits)/3")
        XCTAssertGreaterThanOrEqual(openSecondHits, 2, "browse_open card 2 routed \(openSecondHits)/3")

        // 2. Ordinary page refusal: forum tool called or declined without retrying.
        let ordinaryURL = URL(string: "https://heraldexample.com/2026/11/tariffs?token=secret")!
        app.browser.webView.loadHTMLString(
            "<html><head><title>Markets steady as tariff talks resume</title></head><body><h1>Markets steady as tariff talks resume</h1><p>Talks resume Thursday.</p></body></html>",
            baseURL: ordinaryURL
        )
        try await waitUntil(timeout: 20) { app.browser.webView.title == "Markets steady as tariff talks resume" && !app.browser.webView.isLoading }
        var ordinaryReplies: [String] = []
        let ordinarySession = try await startLive(on: PageContext(url: ordinaryURL, state: .notForum), into: &ordinaryReplies)
        PostLevelURLStub.requests = []
        ordinarySession.sendText("Search the forum for firmware rollback.")
        try await waitUntil(timeout: 20) { ordinarySession.tick(); return !ordinaryReplies.isEmpty && ordinarySession.state == .listening }
        print("[LIVE-VOICE] ordinary reply=\(ordinaryReplies.last ?? "")")
        XCTAssertTrue(PostLevelURLStub.requests.isEmpty, "No forum network call ran on an ordinary page")
        XCTAssertFalse((ordinaryReplies.last ?? "").isEmpty)
        ordinarySession.stop()

        // 3. Ordinary page navigation, scroll, link following, summarize, and read_aloud (Tasks 3, 4 & 5).
        let fake = FakeVoiceNavigator()
        fake.holdsHandOff = true
        fake.pageContext = PageContext(url: ordinaryURL, state: .notForum)
        fake.explicitPageTitle = "Markets steady as tariff talks resume"
        fake.readableText = "Markets steady as tariff talks resume\n\nNegotiators met in Geneva on Thursday and agreed to pause new port levies for ninety days while technical teams review customs rules."
        fake.links = [
            PageLink(text: "Top stories", url: URL(string: "https://heraldexample.com/top")!, host: "heraldexample.com"),
            PageLink(text: "Opinion: why tariffs miss the point", url: URL(string: "https://heraldexample.com/tariffs?src=home#lead")!, host: "heraldexample.com"),
            PageLink(text: "Apple unveils new iPad lineup", url: URL(string: "https://heraldexample.com/ipad")!, host: "heraldexample.com"),
            PageLink(text: "Apple shareholders back buyback plan", url: URL(string: "https://ft-example.com/buyback")!, host: "ft-example.com")
        ]
        var navReplies: [String] = []
        let navSession = VoiceSession(
            configuration: .init(endpoint: endpoint, apiKey: chosenKey, settings: settings),
            audio: FakeVoiceAudio(), navigator: fake, usage: nil, runsLoop: false
        )
        navSession.tools.registryBuilder = { browse in app.voiceToolRegistry(browse: browse) }
        navSession.onTranscript = { role, text, _ in if role == .voiceReply { navReplies.append(text) } }
        await navSession.start()
        try await waitUntil(timeout: 12) { navSession.state == .listening }
        try await Task.sleep(for: .milliseconds(250))

        navSession.sendText("Open bbc.com.")
        try await waitUntil(timeout: 20) { navSession.tick(); return !navReplies.isEmpty && navSession.state == .listening }
        print("[LIVE-VOICE] ordinary open_page calls=\(fake.calls) reply=\(navReplies.last ?? "")")
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("openPage ") }, "Expected open_page for 'Open bbc.com.', got \(fake.calls)")

        let beforeScroll = navReplies.count
        navSession.sendText("Scroll down.")
        try await waitUntil(timeout: 20) { navSession.tick(); return navReplies.count > beforeScroll && navSession.state == .listening }
        print("[LIVE-VOICE] ordinary scroll_down calls=\(fake.calls) reply=\(navReplies.last ?? "")")
        XCTAssertTrue(fake.calls.contains("scroll down"), "Expected browse_move down for 'Scroll down.', got \(fake.calls)")

        let beforeThird = navReplies.count
        navSession.sendText("Open the third link.")
        try await waitUntil(timeout: 20) { navSession.tick(); return navReplies.count > beforeThird && navSession.state == .listening }
        print("[LIVE-VOICE] ordinary open_link_number calls=\(fake.calls) reply=\(navReplies.last ?? "")")
        XCTAssertTrue(fake.calls.contains("followLink Apple unveils new iPad lineup @ heraldexample.com"), "Expected open_link #3, got \(fake.calls)")

        let beforeWords = navReplies.count
        navSession.sendText("Open the one about tariffs.")
        try await waitUntil(timeout: 20) { navSession.tick(); return navReplies.count > beforeWords && navSession.state == .listening }
        print("[LIVE-VOICE] ordinary open_link_words calls=\(fake.calls) reply=\(navReplies.last ?? "")")
        XCTAssertTrue(fake.calls.contains("followLink Opinion: why tariffs miss the point @ heraldexample.com"), "Expected open_link tariffs, got \(fake.calls)")

        let beforeSummarize = navReplies.count
        let readsBeforeSum = fake.calls.filter { $0 == "pageReadableText" }.count
        navSession.sendText("Summarize this.")
        try await waitUntil(timeout: 20) { navSession.tick(); return navReplies.count > beforeSummarize && navSession.state == .listening }
        let readsAfterSum = fake.calls.filter { $0 == "pageReadableText" }.count
        print("[LIVE-VOICE] ordinary summarize_topic pageReadableText=\(readsAfterSum - readsBeforeSum) reply=\(navReplies.last ?? "")")
        XCTAssertGreaterThan(readsAfterSum, readsBeforeSum, "Expected summarize_topic({}) to read pageReadableText, got \(fake.calls)")

        let beforeListen = navReplies.count
        navSession.sendText("Read it to me.")
        try await waitUntil(timeout: 20) { navSession.tick(); return navReplies.count > beforeListen && navSession.state == .listening }
        let readsAfterListen = fake.calls.filter { $0 == "pageReadableText" }.count
        print("[LIVE-VOICE] ordinary read_aloud pageReadableText=\(readsAfterListen - readsAfterSum) reply=\(navReplies.last ?? "")")
        XCTAssertGreaterThan(readsAfterListen, readsAfterSum, "Expected read_aloud({}) to read pageReadableText, got \(fake.calls)")
        XCTAssertEqual(app.podcast.player.playlist?.title, "Markets steady as tariff talks resume")
        navSession.stop()
        app.podcast.cancelReadAloud()
    }

    func testPendingPageNoteFlushesBeforeImmediateNextUserSpeech() async throws {
        navigator.pageContext = PageContext(url: URL(string: "https://www.bbc.com/news")!, state: .notForum)
        navigator.explicitPageTitle = "BBC News"
        let session = try await started()
        await settle()
        XCTAssertEqual(sent().compactMap(\.noteText).count, 1)

        // User says "go back", server transcribes and finishes its turn, leaving
        // `lastUserSpeechAt` < 1s ago so `isQuiet` has not opened yet.
        session.captureGate(open: true)
        session.microphoneFrame(Data(repeating: 1, count: 1280))
        session.receive(frame(#"{"serverContent":{"inputTranscription":{"text":"go back"}}}"#))
        session.captureGate(open: false)
        clock.advance(0.45)
        session.tick()
        session.receive(frame(#"{"serverContent":{"outputTranscription":{"text":"Went back."},"turnComplete":true}}"#))
        XCTAssertEqual(session.state, .listening)

        // The browser finishes settling back onto the forum within that 1s window.
        navigator.voiceSite = VoiceSite(adapter: DiscourseAdapter())
        navigator.explicitPageTitle = "Discourse Meta"
        navigator.pageContext = PageContext(
            url: URL(string: "https://meta.discourse.org/latest")!,
            site: .discourse,
            siteURL: "https://meta.discourse.org",
            forumName: "Discourse Meta",
            state: .forumHome
        )
        session.pageChanged(navigator.pageContext)
        XCTAssertEqual(sent().compactMap(\.noteText).count, 1, "Held while within 1s of prior speech")

        // User immediately starts speaking ("Search for plugins."): the queued
        // forum `[Screen: …]` note must go out before the new audio frames.
        let countBeforeGate = sent().count
        session.captureGate(open: true)
        session.microphoneFrame(Data(repeating: 2, count: 1280))
        let tail = Array(sent().dropFirst(countBeforeGate))
        XCTAssertEqual(tail.count, 2, "Expected note then audio, got \(tail)")
        XCTAssertTrue(tail[0].noteText?.contains("Forum tools work here.") == true, "Got \(tail)")
        XCTAssertEqual(tail[1], .audio(1280))
    }

    private func makeStubbedApp() -> AppModel {
        PostLevelURLStub.requests = []
        PostLevelURLStub.cookies = []
        PostLevelURLStub.handler = { request in
            PostLevelURLStub.requests.append(request.url!)
            return (200, DiscourseFixtures.search)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PostLevelURLStub.self]
        let urlSession = URLSession(configuration: configuration)
        let ai = StateAIStub()
        ai.gated = false
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceSessionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let browser = ForumBrowserModel(
            contentRules: ContentRuleLibrary(store: nil, directory: nil),
            websiteDataStore: Self.sharedDataStore
        )
        let app = AppModel(
            store: PersistentStore(
                fileURL: tempDir.appendingPathComponent("state.json"),
                keys: InMemoryProviderKeyStore()
            ),
            forumService: ForumService(session: urlSession, pacer: ForumRequestPacer(clock: InstantPacingClock())),
            aiService: ai,
            browser: browser,
            websiteDataStore: Self.sharedDataStore,
            cloudSync: CloudSyncController(transport: nil, files: nil, defaults: nil, schedulesAutomatically: false),
            podcastDirectory: tempDir.appendingPathComponent("Podcasts", isDirectory: true),
            workspaceDirectory: tempDir.appendingPathComponent("Workspace", isDirectory: true),
            spotlightIndex: FakeSpotlightIndex(),
            topicActivityDonor: FakeTopicActivityDonor()
        )
        app.usesDirectForumRequests = true
        app.allowAllAIProviders()
        app.settings.assistantModel = ModelSelection(provider: .ollama, model: "summary-model")
        var ollama = app.settings.configuration(for: .ollama); ollama.model = "summary-model"
        app.setConfiguration(ollama, for: .ollama)
        app.settings.podcast.engine = .onDevice
        app.podcast.makeEngine = { _, _, _ in InstantSpeechStub() }
        app.settings.voiceEnabled = true
        var gemini = app.settings.configuration(for: .gemini)
        gemini.apiKey = "test-key"
        app.settings.setConfiguration(gemini, for: .gemini)
        app.browser.onPageContextChanged = nil

        // Host the WKWebView in a visible window so WebKit does not treat its
        // WebContent process as background/freezable on headless CI runners.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let hostVC = UIViewController()
        hostVC.view.frame = window.bounds
        app.browser.webView.frame = window.bounds
        hostVC.view.addSubview(app.browser.webView)
        window.rootViewController = hostVC
        window.isHidden = false
        window.layoutIfNeeded()

        addTeardownBlock { @MainActor in
            PostLevelURLStub.handler = nil
            app.browser.stopLoading()
            app.browser.detachCallbacks()
            app.browser.existingWebView?.removeFromSuperview()
            app.pauseDigest()
            app.podcast.pauseGeneration()
            app.podcast.cancelReadAloud()
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
            urlSession.invalidateAndCancel()
            try? FileManager.default.removeItem(at: tempDir)
        }
        return app
    }

    // MARK: Helpers

    private var seed: UInt64 = 42

    /// An idle timeout past the hour-long tests.
    private var longIdle: VoiceSettings {
        var settings = VoiceSettings()
        settings.idleTimeout = 100_000
        settings.sessionLimitMinutes = 0
        settings.dailyLimitMinutes = 0
        return settings
    }

    private func makeSession(
        endpoint: GeminiLive.Endpoint = .aiStudio,
        key: String = "test-key",
        settings: VoiceSettings = VoiceSettings(),
        usage: VoiceUsageStore? = nil
    ) -> VoiceSession {
        let session = VoiceSession(
            configuration: .init(endpoint: endpoint, apiKey: key, settings: settings),
            transport: { [unowned self] in
                let transport = FakeLiveTransport()
                self.transports.append(transport)
                return transport
            },
            audio: audio,
            navigator: navigator,
            clock: clock,
            usage: usage,
            runsLoop: false
        )
        session.tools.registryBuilder = FakeVoiceNavigator.forumRegistry
        return session
    }

    /// A session past `setupComplete`.
    private func started(
        endpoint: GeminiLive.Endpoint = .aiStudio,
        settings: VoiceSettings = VoiceSettings(),
        usage: VoiceUsageStore? = nil
    ) async throws -> VoiceSession {
        let session = makeSession(endpoint: endpoint, settings: settings, usage: usage)
        await session.start()
        session.receive(frame(#"{"setupComplete":{}}"#))
        XCTAssertEqual(session.state, .listening)
        return session
    }

    private func brief() -> VoiceTopicBrief {
        VoiceTopicBrief(
            topicKey: navigator.pageContext.topic?.topicKey ?? "k",
            title: "Fan noise after the update",
            forumName: "Example",
            opening: "Since the last update the fan is loud. Anyone else?",
            openingPoster: "alice",
            postCount: 9,
            solution: .init(number: 3, username: "bob")
        )
    }

    /// Everything sent on the newest connection.
    private func sent() -> [VoiceSent] {
        transports.last?.messages ?? []
    }

    /// The newest tool response's `response` object.
    private func lastResponse() throws -> [String: Any] {
        try decodeLastResponse(in: try XCTUnwrap(transports.last))
    }

    private func decodeLastResponse(in transport: FakeLiveTransport) throws -> [String: Any] {
        let text = try XCTUnwrap(transport.sent.last { $0.contains("toolResponse") })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let item = (((object["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])?.first)
        return try XCTUnwrap(item?["response"] as? [String: Any])
    }

    /// The newest briefing of one of `kinds`.
    private func briefing(kinds: Set<String>) -> [String: Any]? {
        for text in (transports.last?.sent ?? []).reversed() where text.contains("toolResponse") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let item = ((object["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])?.first,
                  let response = item["response"] as? [String: Any],
                  let kind = response["kind"] as? String, kinds.contains(kind)
            else { continue }
            return response
        }
        return nil
    }

    private func frame(_ text: String) -> Data { Data(text.utf8) }

    private func audioFrame() -> Data {
        frame(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AAEC"}}]}}}"#)
    }

    /// Lets the session's tasks run (tool handlers, context reads).
    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    /// Waits for the session to open its `count`th connection. A reconnect
    /// runs on tasks woken by the old stream ending, so how many yields it
    /// takes depends on the machine; indexing `transports` after a fixed
    /// number of yields crashed on a slow CI runner.
    private func waitForTransports(_ count: Int) async throws {
        try await waitUntil { self.transports.count >= count }
        _ = try XCTUnwrap(transports.count >= count ? true : nil, "No connection \(count)")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out")
    }
}
