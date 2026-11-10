import XCTest
@testable import Forumind

/// AI data consent (App Review 5.1.2(i)): nothing reaches a third-party
/// provider before Allow, Don't Allow and Withdraw block with the right
/// state, Apple Intelligence and local servers never ask, and work the app
/// starts by itself never shows the page. Also the AI output report.
@MainActor
final class AIDataConsentTests: XCTestCase {
    private let site = "https://forum.example.com"

    override func setUp() async throws {
        StateForumStub.reset()
        ConsentAIRequestStub.reset()
    }

    // MARK: The backstop

    /// Every AIService path that sends forum content to a third party
    /// (summaries, chat, the agent planner, the digest and podcast through
    /// `complete`) stops before the network until the provider is allowed.
    func testTheBackstopBlocksEveryRequestPathUntilAllow() async throws {
        let app = makeApp(aiService: AIService(session: ConsentAIRequestStub.session()))
        select(app, .openAI, model: "gpt-test", key: "key")
        let configuration = app.settings.configuration(for: .openAI)
        let service = app.aiService

        let paths: [(String, () async throws -> String)] = [
            ("summary", { try await service.generateSummary(content: "Post", configuration: configuration, provider: .openAI, customPrompt: "", discussion: DiscourseAdapter().discussion, onDelta: { _ in }) }),
            ("chat", { try await service.answer(source: "Post", summary: "", history: [ChatMessage(role: .user, content: "Q")], contextLimit: 1_000, customPrompt: "", discussion: DiscourseAdapter().discussion, configuration: configuration, provider: .openAI, onDelta: { _ in }) }),
            ("complete", { try await service.complete(system: "S", messages: [ChatMessage(role: .user, content: "Q")], configuration: configuration, provider: .openAI) }),
            ("planner", {
                let action = try await PromptAgentPlanner(aiService: service).nextAction(
                    system: "S", transcript: [ChatMessage(role: .user, content: "GOAL: q")], configuration: configuration, provider: .openAI
                )
                return action.tool
            })
        ]
        for (name, path) in paths {
            do {
                _ = try await path()
                XCTFail("\(name) went out without consent")
            } catch AssistantError.aiConsentRequired(.openAI) {
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
        XCTAssertEqual(ConsentAIRequestStub.count, 0, "nothing reached the provider")

        app.settings.aiConsent[AIProvider.openAI.rawValue] = .declined(Date())
        do {
            _ = try await service.complete(system: "S", messages: [], configuration: configuration, provider: .openAI)
            XCTFail("declined went out")
        } catch AssistantError.aiConsentDeclined(.openAI) {}
        XCTAssertEqual(ConsentAIRequestStub.count, 0)

        app.settings.aiConsent[AIProvider.openAI.rawValue] = .allowed(Date())
        let text = try await service.complete(system: "S", messages: [ChatMessage(role: .user, content: "Q")], configuration: configuration, provider: .openAI)
        XCTAssertEqual(text, "OK")
        XCTAssertEqual(ConsentAIRequestStub.count, 1)
    }

    /// An AIService nobody configured sends nothing to a third party.
    func testAnUnconfiguredServiceBlocksByDefault() async throws {
        let service = AIService(session: ConsentAIRequestStub.session())
        let configuration = ProviderConfiguration(model: "m", baseURL: "https://api.example.com/v1", apiKey: "k")
        do {
            _ = try await service.complete(system: "S", messages: [], configuration: configuration, provider: .anthropic)
            XCTFail("went out")
        } catch AssistantError.aiConsentRequired(.anthropic) {}
        XCTAssertEqual(ConsentAIRequestStub.count, 0)
    }

    // MARK: The page

    /// A summary on an undecided provider shows the page and waits; Allow
    /// records the date and the summary runs. Two requests share one page.
    func testTheFirstSummaryWaitsForThePageThenRunsOnAllow() async throws {
        let (app, ai) = makeHarness()
        select(app, .openAI, model: "gpt-test", key: "key")

        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { app.aiConsent.asking == .openAI }
        XCTAssertEqual(app.aiConsent.queue, [.openAI], "one page for both")
        XCTAssertEqual(app.rootPresentation, .aiConsent(.openAI))
        XCTAssertTrue(ai.calls.isEmpty)
        XCTAssertTrue(app.activities.first?.statusText.contains("OpenAI") ?? false)

        app.answerAIConsent(.openAI, allow: true)
        app.answerAIConsent(.openAI, allow: true)
        guard case .allowed = app.aiConsentState(for: .openAI) else { return XCTFail("not allowed") }
        XCTAssertNil(app.aiConsent.asking)
        XCTAssertNotEqual(app.rootPresentation, .aiConsent(.openAI))
        try await waitUntil { ai.calls.count == 2 }
        ai.gated = false
        ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy { $0.status == .completed } }
    }

    /// Don't Allow: the waiting summary fails with the blocked state (no
    /// alert), the provider stays configured but reads "Not allowed", and
    /// the next request fails at once without the page. Allow… brings the
    /// page back.
    func testDontAllowBlocksWithTheBlockedState() async throws {
        let (app, ai) = makeHarness()
        select(app, .openAI, model: "gpt-test", key: "key")

        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { app.aiConsent.asking == .openAI }
        app.answerAIConsent(.openAI, allow: false)
        try await waitUntil { app.activities.first?.status == .failed }
        XCTAssertEqual(app.activities.first?.error, AssistantError.aiConsentDeclined(.openAI).localizedDescription)
        XCTAssertNil(app.presentedError)
        XCTAssertEqual(app.readiness(of: app.selection(for: .assistant)), .aiConsentDeclined)
        XCTAssertEqual(ModelSetupAction(.aiConsentDeclined, provider: .openAI), .allow(.openAI))
        XCTAssertEqual(app.settings.configuration(for: .openAI).apiKey, "key", "still configured")

        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { app.activities.filter { $0.status == .failed }.count == 2 }
        XCTAssertNil(app.aiConsent.asking)
        XCTAssertTrue(ai.calls.isEmpty)

        app.aiConsent.ask(.openAI)
        XCTAssertEqual(app.rootPresentation, .aiConsent(.openAI))
        app.answerAIConsent(.openAI, allow: true)
        XCTAssertEqual(app.readiness(of: app.selection(for: .assistant)), .ready)
    }

    /// A shared link or Siri on a declined provider shows the consent page
    /// again, not the key form.
    func testADeclinedProviderAsksAgainInsteadOfTheKeyForm() {
        let (app, _) = makeHarness()
        select(app, .openAI, model: "gpt-test", key: "key")
        app.settings.aiConsent[AIProvider.openAI.rawValue] = .declined(Date())
        app.needsProviderSetup = .assistant
        app.presentProviderSetupIfNeeded()
        XCTAssertNil(app.needsProviderSetup)
        XCTAssertNil(app.router.item)
        XCTAssertEqual(app.rootPresentation, .aiConsent(.openAI))
    }

    func testAppleIntelligenceAndLocalServersNeverAsk() async throws {
        for provider in [AIProvider.appleIntelligence, .ollama, .lmStudio] {
            XCTAssertFalse(provider.requiresDataConsent)
            XCTAssertEqual(AppSettings().aiConsentState(for: provider), .notNeeded)
            XCTAssertNil(AIProviderPolicy.policy(for: provider))
        }
        for provider in AIProvider.allCases where provider.requiresDataConsent {
            XCTAssertNotNil(AIProviderPolicy.policy(for: provider), provider.rawValue)
        }
        let (app, ai) = makeHarness()
        select(app, .ollama, model: "llama")
        ai.gated = false
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { app.activities.first?.status == .completed }
        XCTAssertNil(app.aiConsent.asking)
        XCTAssertEqual(ai.calls.count, 1)
    }

    func testRemoteAndLANOllamaOrLMStudioRequireConsentWhileLocalAddressesStayExempt() async throws {
        // 1. Local addresses stay exempt.
        for localURL in ["", "http://localhost:11434", "http://127.0.0.1:1234/v1", "http://[::1]:11434", "http://[0:0:0:0:0:0:0:1]:11434", "localhost:11434"] {
            XCTAssertTrue(AIProvider.isLocalBaseURL(localURL), "Expected \(localURL) to be treated as local")
            XCTAssertFalse(AIProvider.ollama.requiresDataConsent(baseURL: localURL))
            XCTAssertFalse(AIProvider.lmStudio.requiresDataConsent(baseURL: localURL))
        }

        // 2. Private LAN addresses, .local mDNS hosts, and remote hosts require consent.
        for remoteURL in [
            "http://192.168.1.50:11434",
            "http://10.0.0.8:1234/v1",
            "http://172.16.0.5:11434",
            "http://mac-studio.local:11434",
            "https://ollama.example.com",
            "192.168.1.50:11434"
        ] {
            XCTAssertFalse(AIProvider.isLocalBaseURL(remoteURL), "Expected \(remoteURL) to be treated as remote")
            XCTAssertTrue(AIProvider.ollama.requiresDataConsent(baseURL: remoteURL))
            XCTAssertTrue(AIProvider.lmStudio.requiresDataConsent(baseURL: remoteURL))
        }

        // 3. AIService backstop blocks remote Ollama/LM Studio until allowed, while allowing localhost.
        let app = makeApp(aiService: AIService(session: ConsentAIRequestStub.session()))
        var ollamaConfig = app.settings.configuration(for: .ollama)
        ollamaConfig.model = "llama"
        ollamaConfig.baseURL = "http://192.168.1.50:11434"
        app.setConfiguration(ollamaConfig, for: .ollama)
        app.selectModel(ModelSelection(provider: .ollama, model: "llama"), for: .both)

        XCTAssertTrue(app.settings.requiresAIConsent(for: .ollama))
        XCTAssertEqual(app.aiConsentState(for: .ollama), .undecided)
        XCTAssertTrue(AIDataFlowSection(app: app).providers.contains(.ollama))

        do {
            _ = try await app.aiService.complete(system: "S", messages: [ChatMessage(role: .user, content: "Q")], configuration: ollamaConfig, provider: .ollama)
            XCTFail("Remote Ollama went out without consent")
        } catch AssistantError.aiConsentRequired(.ollama) {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(ConsentAIRequestStub.count, 0)

        // 4. Granting and withdrawing consent works for remote Ollama/LM Studio.
        app.answerAIConsent(.ollama, allow: true)
        guard case .allowed = app.aiConsentState(for: .ollama) else { return XCTFail("Expected .allowed for remote Ollama") }
        let ok = try await app.aiService.complete(system: "S", messages: [ChatMessage(role: .user, content: "Q")], configuration: ollamaConfig, provider: .ollama)
        XCTAssertEqual(ok, "OK")
        XCTAssertEqual(ConsentAIRequestStub.count, 1)

        app.withdrawAIConsent(.ollama)
        guard case .declined = app.aiConsentState(for: .ollama) else { return XCTFail("Expected .declined after withdrawal") }

        // Switching back to localhost makes consent .notNeeded again.
        ollamaConfig.baseURL = "http://127.0.0.1:11434"
        app.setConfiguration(ollamaConfig, for: .ollama)
        XCTAssertEqual(app.aiConsentState(for: .ollama), .notNeeded)
    }

    func testRemoteOllamaConsentChecksOutgoingBaseURLAndSnapshottedRun() async throws {
        let app = makeApp(aiService: AIService(session: ConsentAIRequestStub.session()))
        let remoteConfig = ProviderConfiguration(model: "llama3", baseURL: "https://remote-ollama.example.com", apiKey: "")
        var bypassedDirect = false
        do {
            _ = try await app.aiService.complete(
                system: "System",
                messages: [ChatMessage(role: .user, content: "Private forum post")],
                configuration: remoteConfig,
                provider: .ollama
            )
            bypassedDirect = true
        } catch AssistantError.aiConsentRequired(.ollama) {
            bypassedDirect = false
        }

        ConsentAIRequestStub.reset()
        app.setConfiguration(remoteConfig, for: .ollama)
        app.selectModel(ModelSelection(provider: .ollama, model: "llama3"), for: .both)
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { app.aiConsent.asking == .ollama }
        XCTAssertEqual(ConsentAIRequestStub.count, 0)

        let localConfig = ProviderConfiguration(model: "llama3", baseURL: "http://localhost:11434", apiKey: "")
        app.setConfiguration(localConfig, for: .ollama)
        app.aiConsent.resolve(.ollama)
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }

        XCTAssertFalse(bypassedDirect)
        XCTAssertEqual(ConsentAIRequestStub.count, 0)
        XCTAssertEqual(app.activities.first?.status, .failed)
    }

    /// Withdraw: running work on that provider is cancelled and new work is
    /// blocked again.
    func testWithdrawCancelsRunningWorkAndBlocksAgain() async throws {
        let (app, ai) = makeHarness()
        select(app, .openAI, model: "gpt-test", key: "key")
        app.settings.aiConsent[AIProvider.openAI.rawValue] = .allowed(Date())

        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { ai.waiting == 1 }
        app.withdrawAIConsent(.openAI)
        XCTAssertEqual(app.activities.first?.status, .cancelled)
        guard case .declined = app.aiConsentState(for: .openAI) else { return XCTFail("not declined") }

        ai.releaseAll()
        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { app.activities.first { $0.topicID == "2" }?.status == .failed }
        XCTAssertEqual(ai.calls.count, 1)
        XCTAssertNil(app.aiConsent.asking)
    }

    func testWithdrawAIConsentStopsCrossRoleAgentSummarizerPodcastAndSwitchedDigest() async throws {
        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "Summarize topic 1", tool: "summarize_topic", arguments: ["topic_id": "1"]),
            AgentAction(thought: "Done", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done"])
        ])
        let watched = WatchedTopic(siteURL: site, topicID: "2", url: topic("2").url, title: "Topic 2", knownPostCount: 1)
        let (app, ai) = makeHarness(snapshot: AppSnapshot(watchedTopics: [watched]), planner: planner)

        var openAIConfig = app.settings.configuration(for: .openAI)
        openAIConfig.apiKey = "sk-test"
        app.setConfiguration(openAIConfig, for: .openAI)
        app.settings.aiConsent[AIProvider.openAI.rawValue] = .allowed(Date())
        app.selectModel(ModelSelection(provider: .openAI, model: "gpt-test"), for: .role(.assistant))
        app.selectModel(ModelSelection(provider: .ollama, model: "llama-local"), for: .role(.agent))

        // 1. Cross-role Agent run: planner uses local Ollama, summarize_topic uses OpenAI.
        _ = try app.startAgentRun(goal: "Summarize 1", siteURL: site) { _ in }
        try await waitUntil { ai.waiting == 1 }
        XCTAssertEqual(ai.calls.last?.provider, .openAI)

        // 2. Podcast generation running while OpenAI consent is withdrawn.
        var doneCard = DigestCard(siteURL: site, topicID: "9", title: "Topic 9", reason: .trending, postCount: 4)
        doneCard.state = .done
        doneCard.summary = "Summary of topic 9 with 4 posts."
        app.digests = [DailyDigest(day: DailyDigest.dayKey(for: Date()), completedAt: Date(), cards: [doneCard])]
        let speech = GatedConsentSpeechEngine()
        app.podcast.makeEngine = { _, _, _ in speech }
        app.settings.podcast.engine = .onDevice
        app.podcast.make(play: false)
        try await waitUntil { speech.waiting || app.podcast.activity.isRunning }
        defer {
            speech.release()
            app.podcast.pauseGeneration()
        }

        // 3. Digest started on OpenAI, then user switches Assistant role to local Ollama while digest is in flight.
        StateForumStub.postCounts["2"] = 3
        let (appDigest, aiDigest) = makeHarness(snapshot: AppSnapshot(watchedTopics: [watched]))
        appDigest.setConfiguration(openAIConfig, for: .openAI)
        appDigest.settings.aiConsent[AIProvider.openAI.rawValue] = .allowed(Date())
        appDigest.selectModel(ModelSelection(provider: .openAI, model: "gpt-test"), for: .role(.assistant))
        appDigest.makeTodaysDigest()
        try await waitUntil { aiDigest.waiting == 1 }
        XCTAssertTrue(appDigest.digestActivity.isRunning)
        appDigest.selectModel(ModelSelection(provider: .ollama, model: "llama-local"), for: .role(.assistant))

        // Withdraw OpenAI consent:
        app.withdrawAIConsent(.openAI)
        appDigest.withdrawAIConsent(.openAI)

        let digestStillRunning = appDigest.digestActivity.isRunning
        let podcastStillRunning = app.podcast.activity.isRunning

        ai.gated = false
        ai.releaseAll()
        aiDigest.gated = false
        aiDigest.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }

        let savedProvider = app.sessions[TopicIdentity.key(siteURL: site, topicID: "1")]?.provider
        XCTAssertNotEqual(savedProvider, .openAI)
        XCTAssertFalse(digestStillRunning)
        XCTAssertFalse(podcastStillRunning)
    }

    /// Work the app starts by itself (watched-topic refreshes, the digest)
    /// never shows the page: it fails with the waiting state, and the
    /// digest doesn't start until the provider is allowed.
    func testAutomaticWorkNeverPresentsThePage() async throws {
        let (app, ai) = makeHarness()
        select(app, .openAI, model: "gpt-test", key: "key")
        XCTAssertFalse(app.canRunUnattended(.assistant))
        XCTAssertEqual(app.providerAwaitingConsent(for: .assistant), .openAI)

        XCTAssertTrue(app.enqueueSummary(for: topic("1"), origin: .automatic))
        try await waitUntil { app.activities.first?.status == .failed }
        XCTAssertNil(app.aiConsent.asking)
        XCTAssertNil(app.rootPresentation)
        XCTAssertNil(app.presentedError)
        XCTAssertEqual(app.activities.first?.error, AssistantError.aiConsentRequired(.openAI).localizedDescription)

        app.makeTodaysDigest()
        XCTAssertEqual(app.digestActivity, .idle)
        XCTAssertNil(app.aiConsent.asking)
        XCTAssertTrue(ai.calls.isEmpty)

        app.settings.aiConsent[AIProvider.openAI.rawValue] = .allowed(Date())
        XCTAssertTrue(app.canRunUnattended(.assistant))
    }

    /// A cancelled job stops waiting; the page stays as a question.
    func testCancellingAWaitingJobStopsItsWait() async throws {
        let (app, ai) = makeHarness()
        select(app, .openAI, model: "gpt-test", key: "key")
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { app.aiConsent.asking == .openAI }
        let record = try XCTUnwrap(app.activities.first)
        app.cancel(record: record)
        app.answerAIConsent(.openAI, allow: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(app.activities.first?.status, .cancelled)
        XCTAssertTrue(ai.calls.isEmpty)
    }

    func testCancelledWaiterDeclinedTestConnectionVoiceWithdrawalAndResetSettings() async throws {
        let (app, ai) = makeHarness()

        // 1. Cancelling the only waiting task removes the provider from AIConsentGate's queue.
        let gate = AIConsentGate()
        let waitTask = Task { await gate.wait(for: .openAI) }
        try await waitUntil { gate.asking == .openAI }
        waitTask.cancel()
        _ = await waitTask.value
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(gate.asking, "Cancelled waiter left provider stuck in queue.")
        XCTAssertTrue(gate.queue.isEmpty)

        // Explicit `ask(_:)` stays queued until `resolve(_:)` (Cancel/Close without recording `.declined`).
        gate.ask(.anthropic)
        XCTAssertEqual(gate.asking, .anthropic)
        gate.resolve(.anthropic)
        XCTAssertNil(gate.asking)

        // 2. Declining AI consent blocks `testAndSaveProvider` from hitting the network or reporting `.success`.
        app.settings.aiConsent[AIProvider.openAI.rawValue] = .declined(Date())
        select(app, .openAI, model: "gpt-test", key: "sk-valid")
        XCTAssertFalse(app.isProviderReady(for: .assistant))
        ai.gated = false
        let declinedTestState = await app.testAndSaveProvider(scope: .role(.assistant))
        XCTAssertEqual(declinedTestState, .failure(AssistantError.aiConsentDeclined(.openAI).localizedDescription))
        XCTAssertTrue(ai.calls.isEmpty)

        // Undecided consent still permits connection testing (e.g. during onboarding before the consent step).
        app.settings.aiConsent[AIProvider.openAI.rawValue] = nil
        let undecidedTestState = await app.testAndSaveProvider(scope: .role(.assistant))
        XCTAssertEqual(undecidedTestState, .success)

        // 3. Withdrawing Voice consent or disabling `voiceEnabled` stops an active Voice session immediately.
        var geminiConfig = app.settings.configuration(for: .gemini)
        geminiConfig.apiKey = "gemini-key"
        app.setConfiguration(geminiConfig, for: .gemini)
        app.settings.voice.provider = .aiStudio
        app.grantVoiceConsent(.aiStudio)
        app.voice.start()
        XCTAssertTrue(app.voice.isActive)
        app.revokeVoiceConsent(.aiStudio)
        XCTAssertFalse(app.voice.isActive, "Withdrawing Voice consent must stop the active microphone session.")
        app.voice.dismiss()

        app.grantVoiceConsent(.aiStudio)
        app.voice.start()
        XCTAssertTrue(app.voice.isActive)
        app.settings.voiceEnabled = false
        XCTAssertFalse(app.voice.isActive, "Turning Voice off must stop the active microphone session.")
        app.voice.dismiss()

        // 4. `resetSettings()` preserves `voiceConsent` and `podcastConsent` alongside `aiConsent`.
        app.grantVoiceConsent(.aiStudio)
        app.settings.podcastConsent[VoiceProvider.aiStudio.rawValue] = Date()
        app.settings.aiConsent[AIProvider.openAI.rawValue] = .allowed(Date())
        app.resetSettings()
        XCTAssertNotNil(app.settings.aiConsent[AIProvider.openAI.rawValue])
        XCTAssertNotNil(app.settings.voiceConsent[VoiceProvider.aiStudio.rawValue])
        XCTAssertNotNil(app.settings.podcastConsent[VoiceProvider.aiStudio.rawValue])
    }

    // MARK: Sync

    /// Each provider's decision is its own settings unit and applies back.
    func testConsentSyncsOneUnitPerProvider() throws {
        var settings = AppSettings()
        settings.aiConsent = [
            AIProvider.gemini.rawValue: .allowed(Date(timeIntervalSince1970: 100)),
            AIProvider.openAI.rawValue: .declined(Date(timeIntervalSince1970: 200))
        ]
        let units = try SyncSchema.settingsUnits(settings)
        XCTAssertNil(units["aiConsent"])
        XCTAssertNotNil(units["aiConsent.gemini"])
        XCTAssertNotNil(units["aiConsent.openai"])

        var local = AppSettings()
        local.aiConsent = [AIProvider.anthropic.rawValue: .allowed(Date(timeIntervalSince1970: 50))]
        let applied = try SyncSchema.applying(settingsUnits: ["aiConsent.openai": units["aiConsent.openai"]!], to: local)
        XCTAssertEqual(applied.aiConsent[AIProvider.openAI.rawValue], .declined(Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(applied.aiConsent[AIProvider.anthropic.rawValue], .allowed(Date(timeIntervalSince1970: 50)))
    }

    // MARK: Report AI output

    /// The report captures the topic URL, the model and the text, and is
    /// built without the network (Mail queues it; the fallback copies it).
    func testReportingASummaryCapturesTopicModelAndText() throws {
        let topic = topic("7")
        var session = TopicSession(siteURL: site, topicID: "7", url: topic.url, title: topic.title)
        session.summary = "## Summary\nThe AI wrote this."
        session.provider = .gemini
        session.model = "gemini-flash"
        let (app, _) = makeHarness(snapshot: AppSnapshot(sessions: [session]))
        app.select(topic: topic)

        let target = try XCTUnwrap(app.currentAIOutputReport(feature: .summary))
        XCTAssertNil(app.currentAIOutputReport(feature: .chatAnswer), "no chat answer yet")
        let draft = ModerationReport.draft(for: target, reason: .inaccurate, note: "Wrong", blocked: false, adapter: nil)
        XCTAssertEqual(draft.subject, "Forumind report: AI summary on forum.example.com")
        XCTAssertTrue(draft.body.contains("Topic URL: \(topic.url.absoluteString)"))
        XCTAssertTrue(draft.body.contains("Model: Google Gemini · gemini-flash"))
        XCTAssertTrue(draft.body.contains("Reason: inaccurate"))
        XCTAssertTrue(draft.body.contains("The AI wrote this."))
        XCTAssertNotNil(ModerationReport.mailtoURL(subject: draft.subject, body: draft.body))
        XCTAssertEqual(ReportReason.reasons(for: target.kind).first, .inaccurate)
        XCTAssertFalse(ReportReason.reasons(for: .topic).contains(.inaccurate))

        app.report(target)
        XCTAssertEqual(app.rootPresentation, .reportAIOutput(target))
    }

    func testReportingAnAskAnswerCapturesTheQuestionAndCapsTheText() {
        let (app, _) = makeHarness()
        let run = AgentRun(siteURL: site, goal: "Which printer?", provider: .anthropic, model: "claude-test")
        let long = String(repeating: "a", count: AIOutput.reportTextLimit + 50)
        let target = app.aiOutputReport(for: run, answer: long)
        let body = ModerationReport.body(for: target, reason: .other, note: "", blocked: false, adapter: nil)
        XCTAssertTrue(body.contains("Question: Which printer?"))
        XCTAssertTrue(body.contains("AI output: Ask the forum answer"))
        XCTAssertTrue(body.contains("Model: Anthropic · claude-test"))
        XCTAssertTrue(body.contains(String(repeating: "a", count: AIOutput.reportTextLimit) + " […]"))
        XCTAssertFalse(body.contains(long))
    }

    // MARK: Helpers

    private func makeApp(aiService: AIService, snapshot: AppSnapshot? = nil, planner: (any AgentPlanner)? = nil) -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var seeded = snapshot ?? AppSnapshot()
        seeded.ensureForum(site)
        try? store.save(seeded)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StateForumStub.self]
        let app = AppModel(
            store: store,
            forumService: ForumService(session: URLSession(configuration: configuration), pacer: ForumRequestPacer(clock: InstantPacingClock())),
            aiService: aiService,
            planner: planner
        )
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        app.settings.hasCompletedOnboarding = true
        app.settings.acceptedTermsVersion = ModerationTerms.currentVersion
        return app
    }

    private func makeHarness(snapshot: AppSnapshot? = nil, planner: (any AgentPlanner)? = nil) -> (AppModel, StateAIStub) {
        let ai = StateAIStub()
        let app = makeApp(aiService: ai, snapshot: snapshot, planner: planner)
        addTeardownBlock { @MainActor in
            for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
            ai.gated = false
            ai.releaseAll()
        }
        return (app, ai)
    }

    private func select(_ app: AppModel, _ provider: AIProvider, model: String, key: String = "") {
        var configuration = app.settings.configuration(for: provider)
        configuration.apiKey = key
        configuration.baseURL = provider.isLocalServer ? configuration.baseURL : "https://api.example.com/v1"
        app.setConfiguration(configuration, for: provider)
        app.selectModel(ModelSelection(provider: provider, model: model), for: .both)
    }

    private func topic(_ id: String) -> ForumTopic {
        ForumTopic(siteURL: site, topicID: id, url: URL(string: "\(site)/t/topic-\(id)/\(id)")!, title: "Topic \(id)")
    }

    private func waitUntil(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Counts requests to the AI provider and answers with one OpenAI-style
/// streamed "OK".
final class ConsentAIRequestStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen = 0

    static var count: Int { lock.withLock { seen } }
    static func reset() { lock.withLock { seen = 0 } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsentAIRequestStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.seen += 1 }
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}],\"message\":{\"content\":\"OK\"}}\n\ndata: [DONE]\n\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class GatedConsentSpeechEngine: PodcastSpeechEngine, @unchecked Sendable {
    let fileExtension = "wav"
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    var waiting: Bool { lock.withLock { continuation != nil } }

    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let current = continuation
            continuation = nil
            return current
        }
        pending?.resume()
    }

    func synthesize(_ turns: [PodcastTurn], to destination: URL) async throws -> TimeInterval {
        await withCheckedContinuation { cont in
            lock.withLock { continuation = cont }
        }
        try Task.checkCancellation()
        try Data("RIFF".utf8).write(to: destination)
        return 1.0
    }
}

// MARK: - Helpers for tests about other things

extension AIService {
    /// A service whose consent backstop lets everything through (tests of
    /// the wire format, not of consent).
    static func allowingAll(session: URLSession) -> AIService {
        let service = AIService(session: session)
        service.consentCheck = { _, _ in }
        return service
    }
}

extension AppModel {
    /// Every third-party provider allowed (tests of other features).
    func allowAllAIProviders() {
        for provider in AIProvider.allCases where provider.requiresDataConsent {
            settings.aiConsent[provider.rawValue] = .allowed(Date())
        }
    }
}
