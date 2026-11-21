import XCTest
@testable import WukongMind

/// AI data consent (App Review 5.1.2(i) & 5.1.1(i)): nothing reaches a
/// third-party AI provider before Allow (including Browser Agent tool turns,
/// `GM_ai`, and live voice), Don't Allow and Withdraw block requests, Apple
/// Intelligence and loopback local servers never ask, and unattended work
/// never shows the consent page.
@MainActor
final class AIDataConsentTests: XCTestCase {
    override func setUp() async throws {
        ConsentAIRequestStub.reset()
    }

    private func makeApp(aiService: AIService = AIService()) -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wukong-consent-\(UUID().uuidString)", isDirectory: true)
        return AppModel(
            store: PersistentStore(
                fileURL: dir.appendingPathComponent("state.json"),
                keys: InMemoryProviderKeyStore()
            ),
            aiService: aiService
        )
    }

    private func select(_ app: AppModel, _ provider: AIProvider, model: String, key: String) {
        var config = app.settings.configuration(for: provider)
        config.apiKey = key
        app.settings.setConfiguration(config, for: provider)
        let selection = ModelSelection(provider: provider, model: model)
        app.settings.setModel(selection, for: .assistant)
        if provider.supportsToolCalling {
            app.settings.setModel(selection, for: .browserAgent)
        }
    }

    // MARK: - Request-layer backstop

    /// Every AIService content-sending path (summaries, answer, complete, and
    /// Browser Agent `completeToolTurn`) stops before the network until the
    /// provider is allowed.
    func testTheBackstopBlocksEveryRequestPathUntilAllow() async throws {
        let app = makeApp(aiService: AIService(session: ConsentAIRequestStub.session()))
        select(app, .openAI, model: "gpt-test", key: "key")
        let configuration = app.settings.configuration(for: .assistant)
        let service = app.aiService

        let paths: [(String, () async throws -> String)] = [
            ("summary", {
                try await service.generateSummary(
                    content: "Page content",
                    configuration: configuration,
                    provider: .openAI,
                    customPrompt: "",
                    discussion: DiscourseAdapter().discussion,
                    onDelta: { _ in }
                )
            }),
            ("answer", {
                try await service.answer(
                    source: "Page content",
                    summary: "",
                    history: [ChatMessage(role: .user, content: "Q")],
                    contextLimit: 1_000,
                    customPrompt: "",
                    discussion: DiscourseAdapter().discussion,
                    configuration: configuration,
                    provider: .openAI,
                    onDelta: { _ in }
                )
            }),
            ("complete", {
                try await service.complete(
                    system: "S",
                    messages: [ChatMessage(role: .user, content: "Q")],
                    configuration: configuration,
                    provider: .openAI
                )
            }),
            ("completeToolTurn", {
                let turn = try await service.completeToolTurn(
                    system: "S",
                    messages: [.user("Inspect this page")],
                    tools: [],
                    configuration: configuration,
                    provider: .openAI
                )
                return turn.text
            })
        ]

        for (name, path) in paths {
            do {
                _ = try await path()
                XCTFail("\(name) went out without consent")
            } catch AssistantError.aiConsentRequired(.openAI) {
            } catch {
                XCTFail("\(name) threw unexpected error: \(error)")
            }
        }
        XCTAssertEqual(ConsentAIRequestStub.count, 0, "no HTTP request may leave without consent")

        app.settings.aiConsent[AIProvider.openAI.rawValue] = .declined(Date())
        do {
            _ = try await service.complete(system: "S", messages: [], configuration: configuration, provider: .openAI)
            XCTFail("declined request went out")
        } catch AssistantError.aiConsentDeclined(.openAI) {}
        do {
            _ = try await service.completeToolTurn(system: "S", messages: [.user("Hi")], tools: [], configuration: configuration, provider: .openAI)
            XCTFail("declined tool turn went out")
        } catch AssistantError.aiConsentDeclined(.openAI) {}
        XCTAssertEqual(ConsentAIRequestStub.count, 0)

        app.settings.aiConsent[AIProvider.openAI.rawValue] = .allowed(Date())
        let text = try await service.complete(system: "S", messages: [ChatMessage(role: .user, content: "Q")], configuration: configuration, provider: .openAI)
        XCTAssertEqual(text, "OK")
        XCTAssertEqual(ConsentAIRequestStub.count, 1)

        ConsentAIRequestStub.mode = .toolTurn
        let turn = try await service.completeToolTurn(system: "S", messages: [.user("Hi")], tools: [], configuration: configuration, provider: .openAI)
        XCTAssertEqual(turn.text, "OK")
        XCTAssertEqual(ConsentAIRequestStub.count, 2)
    }

    /// An AIService nobody configured refuses third-party requests by default.
    func testAnUnconfiguredServiceBlocksByDefault() async throws {
        let service = AIService(session: ConsentAIRequestStub.session())
        let configuration = ProviderConfiguration(model: "m", baseURL: "https://api.example.com/v1", apiKey: "k")
        do {
            _ = try await service.complete(system: "S", messages: [], configuration: configuration, provider: .anthropic)
            XCTFail("complete went out")
        } catch AssistantError.aiConsentRequired(.anthropic) {}
        do {
            _ = try await service.completeToolTurn(system: "S", messages: [.user("Hi")], tools: [], configuration: configuration, provider: .anthropic)
            XCTFail("completeToolTurn went out")
        } catch AssistantError.aiConsentRequired(.anthropic) {}
        XCTAssertEqual(ConsentAIRequestStub.count, 0)
    }

    // MARK: - GM_ai

    /// `GM_ai` calls go through `AIService.complete` and cannot leave the device
    /// without consent for the Scripts provider; once allowed, they succeed.
    func testGMAiBlocksWithoutConsentAndSucceedsAfterAllow() async throws {
        let app = makeApp(aiService: AIService(session: ConsentAIRequestStub.session()))
        select(app, .openAI, model: "gpt-test", key: "key")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wukong-gmai-consent-\(UUID().uuidString)", isDirectory: true)
        let gmai = GMAiService(
            cache: ScriptAICache(directoryURL: dir),
            limiter: GMAiLimiter(),
            aiService: app.aiService,
            runtimeProvider: { app.gmAiRuntimeSnapshot() }
        )
        let script = UserScript(
            id: "consent-test-script",
            name: "Consent Script",
            matchRules: ["https://example.com/*"],
            js: "1"
        )

        do {
            _ = try await gmai.call(
                script: script,
                pageKey: "https://example.com/",
                pageURL: "https://example.com/",
                prompt: "Summarize this headline",
                format: .text
            )
            XCTFail("GM_ai call went out without consent")
        } catch let error as GMAiError {
            XCTAssertEqual(error.code, .provider)
        }
        XCTAssertEqual(ConsentAIRequestStub.count, 0, "GM_ai must not touch the network without consent")

        app.answerAIConsent(.openAI, allow: true)
        let result = try await gmai.call(
            script: script,
            pageKey: "https://example.com/",
            pageURL: "https://example.com/",
            prompt: "Summarize this headline",
            format: .text
        )
        XCTAssertEqual(result, JSONValue.string("OK"))
        XCTAssertEqual(ConsentAIRequestStub.count, 1)
    }

    // MARK: - Live voice

    /// Live voice requires separate microphone consent: `VoiceController.start()`
    /// asks first, `voiceConfiguration()` / `makeVoiceSession` refuse without it,
    /// and revoking blocks again.
    func testVoiceConsentGateAndBackstopBlockUntilAllow() {
        let app = makeApp()
        app.settings.hasCompletedOnboarding = true
        select(app, .gemini, model: "gemini-test", key: "voice-key")
        app.settings.voiceEnabled = true

        // Backstop refuses direct session creation without voice consent.
        if case .failure(let failure) = app.voiceConfiguration() {
            XCTAssertEqual(failure, .consentRequired)
        } else {
            XCTFail("voiceConfiguration succeeded without voice consent")
        }

        // Interactive start shows the voice consent page instead of starting.
        app.voice.useScriptedSession = true
        app.voice.start()
        XCTAssertEqual(app.voice.consentProvider, .aiStudio)
        XCTAssertEqual(app.rootPresentation, .voiceConsent(.aiStudio))
        XCTAssertNil(app.voice.session)

        // Declining keeps consent unset and clears the presentation.
        app.voice.declineConsent()
        XCTAssertNil(app.voice.consentProvider)
        XCTAssertFalse(VoiceConsent.isGranted(.aiStudio, in: app.settings))
        if case .failure(let failure) = app.voiceConfiguration() {
            XCTAssertEqual(failure, .consentRequired)
        } else {
            XCTFail("voiceConfiguration succeeded after decline")
        }

        // Granting consent allows voiceConfiguration; revoking blocks again.
        app.grantVoiceConsent(.aiStudio)
        XCTAssertTrue(VoiceConsent.isGranted(.aiStudio, in: app.settings))
        if case .failure(let failure) = app.voiceConfiguration() {
            XCTFail("voiceConfiguration failed after grant: \(failure)")
        }

        app.revokeVoiceConsent(.aiStudio)
        XCTAssertFalse(VoiceConsent.isGranted(.aiStudio, in: app.settings))
        if case .failure(let failure) = app.voiceConfiguration() {
            XCTAssertEqual(failure, .consentRequired)
        } else {
            XCTFail("voiceConfiguration succeeded after revoke")
        }
    }

    /// Read aloud falls back to `.onDevice` when consent is undecided or
    /// declined, and `GeminiSpeechEngine` refuses requests without consent.
    func testPodcastTTSFallsBackToOnDeviceAndBlocksGoogleWithoutConsent() async throws {
        let app = makeApp()
        select(app, .gemini, model: "gemini-test", key: "tts-key")

        // Undecided: falls back to on-device.
        XCTAssertEqual(app.podcast.engineSelection(), .engine(.onDevice))

        // Declined: falls back to on-device and GeminiSpeechEngine refuses network call.
        app.answerAIConsent(.gemini, allow: false)
        XCTAssertEqual(app.podcast.engineSelection(), .engine(.onDevice))

        let tts = GeminiSpeechEngine(
            endpoint: GeminiTTS.Endpoint(provider: .aiStudio, baseURL: AIProvider.gemini.defaultBaseURL, apiKey: "tts-key"),
            voices: PodcastVoices(a: app.settings.podcast.voiceA, b: app.settings.podcast.voiceA),
            session: ConsentAIRequestStub.session(),
            consentCheck: { try app.settings.requireAIConsent(for: .gemini) }
        )
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tts-\(UUID().uuidString).wav")
        do {
            _ = try await tts.synthesize([PodcastTurn(speaker: .a, text: "Hello")], to: out)
            XCTFail("GeminiSpeechEngine sent a request after consent was declined")
        } catch AssistantError.aiConsentDeclined(.gemini) {}
        XCTAssertEqual(ConsentAIRequestStub.count, 0, "no TTS HTTP request may leave without consent")

        // Allowed: selects the Google engine.
        app.answerAIConsent(.gemini, allow: true)
        XCTAssertEqual(app.podcast.engineSelection(), .engine(.aiStudio))
    }

    // MARK: - Local servers and Apple Intelligence

    func testAppleIntelligenceAndLoopbackLocalServersNeedNoConsent() async throws {
        let settings = AppSettings()
        XCTAssertEqual(settings.aiConsentState(for: .appleIntelligence), .notNeeded)
        XCTAssertEqual(settings.aiConsentState(for: .ollama), .notNeeded)
        XCTAssertEqual(settings.aiConsentState(for: .lmStudio), .notNeeded)

        // LAN / remote Ollama requires consent.
        XCTAssertEqual(settings.aiConsentState(for: .ollama, baseURL: "http://192.168.1.20:11434"), .undecided)
        XCTAssertEqual(settings.aiConsentState(for: .ollama, baseURL: "https://ollama.example.com"), .undecided)
        XCTAssertEqual(settings.aiConsentState(for: .ollama, baseURL: "http://127.0.0.1:11434"), .notNeeded)
        XCTAssertEqual(settings.aiConsentState(for: .ollama, baseURL: "http://[::1]:11434"), .notNeeded)

        let service = AIService(session: ConsentAIRequestStub.session())
        let remoteConfig = ProviderConfiguration(model: "llama3", baseURL: "http://192.168.1.20:11434", apiKey: "")
        do {
            _ = try await service.complete(system: "S", messages: [], configuration: remoteConfig, provider: .ollama)
            XCTFail("remote Ollama went out without consent")
        } catch AssistantError.aiConsentRequired(.ollama) {}
        XCTAssertEqual(ConsentAIRequestStub.count, 0)
    }

    // MARK: - Interactive flow, withdraw, unattended, sync & reset

    func testAuthorizeWaitsForAnswerWithdrawBlocksAndUnattendedNeverAsks() async throws {
        let app = makeApp()
        app.settings.hasCompletedOnboarding = true
        select(app, .openAI, model: "gpt-test", key: "key")

        // Unattended work never shows the consent page.
        XCTAssertFalse(app.canRunUnattended(.assistant))
        do {
            try await app.authorizeSending(to: .openAI, mayAsk: false)
            XCTFail("unattended succeeded without consent")
        } catch AssistantError.aiConsentRequired(.openAI) {}
        XCTAssertNil(app.aiConsent.asking)

        // User-initiated work queues the page and waits until Allow.
        let task = Task {
            try await app.authorizeSending(to: .openAI, mayAsk: true)
        }
        for _ in 0..<40 where app.aiConsent.asking != .openAI {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(app.aiConsent.asking, .openAI)
        XCTAssertEqual(app.rootPresentation, .aiConsent(.openAI))

        app.answerAIConsent(.openAI, allow: true)
        try await task.value
        XCTAssertNil(app.aiConsent.asking)
        XCTAssertTrue(app.canRunUnattended(.assistant))

        // Withdraw sets .declined and blocks subsequent requests.
        app.withdrawAIConsent(.openAI)
        guard case .declined = app.aiConsentState(for: .openAI) else {
            return XCTFail("Expected .declined after withdraw")
        }
        XCTAssertFalse(app.canRunUnattended(.assistant))
        do {
            try await app.authorizeSending(to: .openAI, mayAsk: true)
            XCTFail("authorize succeeded after withdraw")
        } catch AssistantError.aiConsentDeclined(.openAI) {}
    }

    func testSyncSplitsAIConsentPerProviderAndKeepsVoiceConsentDeviceLocal() throws {
        var settings = AppSettings()
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)
        settings.aiConsent = [
            AIProvider.gemini.rawValue: .allowed(t1),
            AIProvider.openAI.rawValue: .declined(t2)
        ]
        settings.voiceConsent = [VoiceProvider.aiStudio.rawValue: t1]

        let units = try SyncSchema.settingsUnits(settings)
        XCTAssertNil(units["aiConsent"])
        XCTAssertNil(units["voiceConsent"])
        XCTAssertNotNil(units["aiConsent.gemini"])
        XCTAssertNotNil(units["aiConsent.openai"])

        var local = AppSettings()
        local.aiConsent = [AIProvider.anthropic.rawValue: .allowed(Date(timeIntervalSince1970: 50))]
        let applied = try SyncSchema.applying(settingsUnits: ["aiConsent.openai": units["aiConsent.openai"]!], to: local)
        XCTAssertEqual(applied.aiConsent[AIProvider.openAI.rawValue], .declined(t2))
        XCTAssertEqual(applied.aiConsent[AIProvider.anthropic.rawValue], .allowed(Date(timeIntervalSince1970: 50)))
    }

    func testResetSettingsPreservesConsentDecisions() {
        let app = makeApp()
        let date = Date(timeIntervalSince1970: 500)
        app.settings.aiConsent[AIProvider.openAI.rawValue] = .allowed(date)
        app.settings.voiceConsent[VoiceProvider.aiStudio.rawValue] = date

        app.resetSettings()

        XCTAssertEqual(app.settings.aiConsent[AIProvider.openAI.rawValue], .allowed(date))
        XCTAssertEqual(app.settings.voiceConsent[VoiceProvider.aiStudio.rawValue], date)
    }

    func testPrivacyPolicyAndProviderPoliciesArePresent() {
        XCTAssertEqual(AppVersion.privacyPolicyURL.scheme, "https")
        for provider in AIProvider.allCases {
            if provider.requiresDataConsent {
                XCTAssertNotNil(AIProviderPolicy.policy(for: provider), "\(provider) missing policy")
            } else {
                XCTAssertNil(AIProviderPolicy.policy(for: provider), "\(provider) should not have a policy")
            }
        }
    }

    // MARK: - Multi-provider tool consent (WUKO-205)

    private func configureSplitProviders(_ app: AppModel, agent: AIProvider, summaries: AIProvider) {
        app.settings.hasCompletedOnboarding = true
        app.settings.acceptedTermsVersion = TermsOfUse.currentVersion
        var agentConfig = app.settings.configuration(for: agent)
        agentConfig.apiKey = "agent-key"
        app.settings.setConfiguration(agentConfig, for: agent)
        app.settings.setModel(ModelSelection(provider: agent, model: "agent-model"), for: .browserAgent)

        var summariesConfig = app.settings.configuration(for: summaries)
        summariesConfig.apiKey = "summaries-key"
        app.settings.setConfiguration(summariesConfig, for: summaries)
        app.settings.setModel(ModelSelection(provider: summaries, model: "summaries-model"), for: .assistant)

        // Agent provider is already allowed; Summaries provider stays undecided.
        app.settings.aiConsent[agent.rawValue] = .allowed(Date())
        app.settings.aiConsent.removeValue(forKey: summaries.rawValue)
    }

    private func waitUntil(timeoutSeconds: Double = 5, _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(15))
        }
        return condition()
    }

    /// Agent on Anthropic (allowed) calls `summarize_topic` backed by Vertex AI (undecided):
    /// the Vertex AI consent page appears, the Agent ring enters `.needsYou`, the step shows
    /// "Waiting for permission to use Google Vertex AI…", and Allow completes the same call
    /// with exactly one request to Vertex AI.
    func testAgentToolOnUndecidedProviderAsksShowsNeedsYouAndAllowSendsOnce() async throws {
        let app = makeApp(aiService: AIService(session: ConsentAIRequestStub.session()))
        configureSplitProviders(app, agent: .anthropic, summaries: .vertexAI)
        app.browserAgent.configureDebugModelClient(RecordedSummarizeAgentClient())

        app.browserAgent.send("Summarize this page")

        let asked = try await waitUntil { app.aiConsent.asking == .vertexAI }
        XCTAssertTrue(asked, "Consent page for Google Vertex AI did not appear during summarize_topic")
        XCTAssertEqual(app.rootPresentation, .aiConsent(.vertexAI))
        XCTAssertEqual(app.agentRingState(isAvailable: true), .needsYou)
        let runningRow = app.browserAgent.runs.last?.toolCalls.last(where: \.isRunning)
        XCTAssertEqual(runningRow?.toolName, "summarize_topic")
        XCTAssertEqual(runningRow?.statusText, AIConsentAuthorization.waitingStatusText(for: .vertexAI))
        XCTAssertEqual(ConsentAIRequestStub.count, 0, "Nothing may be sent to Vertex AI before Allow")

        app.answerAIConsent(.vertexAI, allow: true)

        let finished = try await waitUntil { !app.browserAgent.isRunning }
        XCTAssertTrue(finished, "Agent run did not finish after Allow")
        XCTAssertNil(app.browserAgent.awaitingConsentProvider)
        XCTAssertEqual(ConsentAIRequestStub.count, 1, "Allow must continue the same tool call with exactly one request")
        let completedRow = app.browserAgent.runs.last?.toolCalls.first(where: { $0.toolName == "summarize_topic" })
        XCTAssertEqual(completedRow?.isError, false)
        XCTAssertEqual(completedRow?.resultText, "OK")
        XCTAssertNil(completedRow?.statusText)
        XCTAssertTrue(app.browserAgent.runs.last?.assistantText.contains("OK") == true)
    }

    /// Don't Allow on the tool's provider fails that tool call with the declined text,
    /// sends nothing to Vertex AI, and lets the Agent report it plainly.
    func testAgentToolOnUndecidedProviderDeclineFailsToolWithoutSending() async throws {
        let app = makeApp(aiService: AIService(session: ConsentAIRequestStub.session()))
        configureSplitProviders(app, agent: .anthropic, summaries: .vertexAI)
        app.browserAgent.configureDebugModelClient(RecordedSummarizeAgentClient())

        app.browserAgent.send("Summarize this page")

        let asked = try await waitUntil { app.aiConsent.asking == .vertexAI }
        XCTAssertTrue(asked, "Consent page for Google Vertex AI did not appear")
        XCTAssertEqual(app.agentRingState(isAvailable: true), .needsYou)

        app.answerAIConsent(.vertexAI, allow: false)

        let finished = try await waitUntil { !app.browserAgent.isRunning }
        XCTAssertTrue(finished, "Agent run did not finish after Don't Allow")
        XCTAssertNil(app.browserAgent.awaitingConsentProvider)
        XCTAssertEqual(ConsentAIRequestStub.count, 0, "Nothing may be sent to Vertex AI after Don't Allow")
        let failedRow = app.browserAgent.runs.last?.toolCalls.first(where: { $0.toolName == "summarize_topic" })
        XCTAssertEqual(failedRow?.isError, true)
        let declinedText = AssistantError.aiConsentDeclined(.vertexAI).localizedDescription
        XCTAssertTrue(failedRow?.resultText.contains(declinedText) == true, "Expected declined message, got: \(failedRow?.resultText ?? "nil")")
        XCTAssertTrue(app.browserAgent.runs.last?.assistantText.contains(declinedText) == true)
    }

    /// Unattended summary refreshes (`origin: .automatic`) with an undecided provider
    /// never open the consent page and fail quietly.
    func testUnattendedSummaryRefreshNeverAsksAndFailsQuietly() async throws {
        let app = makeApp(aiService: AIService(session: ConsentAIRequestStub.session()))
        configureSplitProviders(app, agent: .anthropic, summaries: .vertexAI)
        let topic = ForumTopic(
            siteURL: "https://meta.discourse.org",
            topicID: "99",
            url: URL(string: "https://meta.discourse.org/t/test/99")!,
            title: "Test topic"
        )
        XCTAssertTrue(app.enqueueSummary(for: topic, origin: .automatic))
        let recordID = try XCTUnwrap(app.activities.first?.id)

        let terminal = try await waitUntil {
            app.activities.first(where: { $0.id == recordID })?.status.isTerminal == true
        }
        XCTAssertTrue(terminal, "Unattended summary job did not finish")
        XCTAssertNil(app.aiConsent.asking, "Unattended refresh must never show the consent page")
        XCTAssertEqual(app.activities.first(where: { $0.id == recordID })?.status, .failed)
        XCTAssertEqual(ConsentAIRequestStub.count, 0)
    }

    /// Summary card Retry (`startSummary(regenerate: true)`) asks for consent when
    /// the Summaries provider is undecided.
    func testSummaryCardRetryAsksForUndecidedProvider() async throws {
        let app = makeApp(aiService: AIService(session: ConsentAIRequestStub.session()))
        configureSplitProviders(app, agent: .anthropic, summaries: .vertexAI)
        let topic = ForumTopic(
            siteURL: "https://meta.discourse.org",
            topicID: "42",
            url: URL(string: "https://meta.discourse.org/t/retry-test/42")!,
            title: "Retry test"
        )
        let context = PageContext(url: topic.url, siteURL: topic.siteURL, topic: topic, state: .topic)
        app.browser.setPageContext(context)
        app.browser.onPageContextChanged?(context)

        app.startSummary(regenerate: true)

        let asked = try await waitUntil { app.aiConsent.asking == .vertexAI }
        XCTAssertTrue(asked, "Summary Retry did not show the consent page for Google Vertex AI")
        XCTAssertEqual(app.rootPresentation, .aiConsent(.vertexAI))
        XCTAssertEqual(ConsentAIRequestStub.count, 0)

        app.answerAIConsent(.vertexAI, allow: true)
        let resolved = try await waitUntil { app.aiConsent.asking == nil }
        XCTAssertTrue(resolved)
        if case .allowed = app.aiConsentState(for: .vertexAI) {
        } else {
            XCTFail("Expected Vertex AI to be allowed after answering Retry's consent page")
        }
    }
}

private final class RecordedSummarizeAgentClient: AgentModelClient, @unchecked Sendable {
    func completeToolTurn(
        system: String,
        messages: [AgentModelTurn],
        tools: [AgentToolDefinition],
        configuration: ProviderConfiguration,
        provider: AIProvider,
        maxTokens: Int
    ) async throws -> AgentModelTurnResponse {
        if case .toolResults(let results) = messages.last, let first = results.first {
            let reply = first.isError ? "Could not summarize: \(first.content)" : "Summary ready: \(first.content)"
            return AgentModelTurnResponse(text: reply, stopReason: "end_turn")
        }
        return AgentModelTurnResponse(
            text: "",
            toolCalls: [
                AgentModelToolCall(
                    id: "call_sum_1",
                    name: "summarize_topic",
                    arguments: ["text": .string("Ferries run every 30 minutes across the bay.")]
                )
            ],
            stopReason: "tool_use"
        )
    }
}

// MARK: - Network stub

private final class ConsentAIRequestStub: URLProtocol {
    enum Mode { case sse, toolTurn }

    private static let lock = NSLock()
    private static var _count = 0
    private static var _mode: Mode = .sse

    static var count: Int { lock.withLock { _count } }
    static var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    static func reset() {
        lock.withLock {
            _count = 0
            _mode = .sse
        }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConsentAIRequestStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let currentMode = Self.lock.withLock { () -> Mode in
            Self._count += 1
            return Self._mode
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": currentMode == .sse ? "text/event-stream" : "application/json"]
        )!
        let body: String
        switch currentMode {
        case .sse:
            if request.url?.absoluteString.contains("GenerateContent") == true {
                body = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"OK\"}]}}]}\n\n"
            } else {
                body = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\ndata: [DONE]\n\n"
            }
        case .toolTurn:
            body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"OK\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}"
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helpers for tests about other features

extension AIService {
    /// A service whose consent backstop lets everything through (tests of
    /// wire formats or other features, not of consent).
    static func allowingAll(session: URLSession = .shared) -> AIService {
        let service = AIService(session: session)
        service.consentCheck = { _, _ in }
        return service
    }
}

extension AppModel {
    /// Every third-party provider and live voice endpoint allowed (tests of other features).
    func allowAllAIProviders() {
        let now = Date()
        for provider in AIProvider.allCases where provider.requiresDataConsent {
            settings.aiConsent[provider.rawValue] = .allowed(now)
        }
        for provider in VoiceProvider.allCases {
            settings.voiceConsent[provider.rawValue] = now
        }
    }
}
