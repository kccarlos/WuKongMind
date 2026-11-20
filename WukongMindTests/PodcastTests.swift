import AVFoundation
import XCTest
@testable import WukongMind

/// Read-aloud speech, Gemini TTS, on-device voices, settings, player and cache.
/// No network or audio hardware is used: TTS goes through `TTSStub`, the
/// player runs against fakes, and read-aloud uses `FakeSpeechEngine`.
@MainActor
final class PodcastTests: XCTestCase {
    private let site = "https://forum.example.com"

    override func setUp() {
        super.setUp()
        TTSStub.reset()
    }

    // MARK: Speakable text and chunking

    func testReadAloudTextAndChunkingHaveNothingUnspeakable() {
        let raw = "Fixed by [this post](https://forum.example.com/t/x/5/3).\n```yaml\nkey: value\n```\n**Done**."
        let spoken = PodcastSpeechCheck.speakable(raw)
        XCTAssertFalse(spoken.contains("http"))
        XCTAssertFalse(spoken.contains("key: value"))
        XCTAssertTrue(spoken.contains("this post"))
        XCTAssertTrue(spoken.contains("Done"))

        let chunks = PodcastController.readAloudChunks(String(repeating: "A sentence here. ", count: 200), limit: 300)
        XCTAssertGreaterThan(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 300 })
    }

    // MARK: Gemini TTS

    func testTheTTSRequestUsesHeaderKeyOnBothEndpointsAndSingleVoiceForReadAloud() throws {
        let turns = [PodcastTurn(speaker: .a, text: "Hello."), PodcastTurn(speaker: .b, text: "Hi there.")]
        let voices = PodcastVoices(a: "Kore", b: "Puck")
        let studio = try GeminiTTS.request(
            turns: turns, voices: voices,
            endpoint: .init(provider: .aiStudio, baseURL: "https://generativelanguage.googleapis.com/v1beta/", apiKey: "secret-key")
        )
        XCTAssertEqual(studio.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash-tts:generateContent")
        XCTAssertEqual(studio.httpMethod, "POST")
        XCTAssertEqual(studio.value(forHTTPHeaderField: "x-goog-api-key"), "secret-key")
        XCTAssertFalse(studio.url?.absoluteString.contains("secret-key") ?? true, "the key never goes in the URL")

        let vertex = try GeminiTTS.request(
            turns: turns, voices: voices,
            endpoint: .init(provider: .vertex, baseURL: "https://aiplatform.googleapis.com/v1", apiKey: "vertex-key")
        )
        XCTAssertEqual(vertex.url?.absoluteString, "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-3.8-flash-tts:generateContent")
        XCTAssertEqual(vertex.value(forHTTPHeaderField: "x-goog-api-key"), "vertex-key")

        // One host (read aloud): a single voice, no speaker labels.
        let single = GeminiTTS.body(turns: [PodcastTurn(speaker: .a, text: "Only me.")], voices: voices)
        let speech = try XCTUnwrap((single["generationConfig"] as? [String: Any])?["speechConfig"] as? [String: Any])
        XCTAssertEqual((speech["voiceConfig"] as? [String: Any])?["voice"] as? String, "Kore")
        XCTAssertNil(speech["multiSpeakerVoiceConfig"])
        let singlePart = (((single["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])?.first
        XCTAssertNil((singlePart?["speech_metadata"] as? [String: Any])?["speaker"])
    }

    func testTheResponseAudioIsDecodedFromWAVOrL16() throws {
        let pcm = Data((0..<4_800).flatMap { _ in [UInt8(0x10), UInt8(0x00)] })
        let wav = WAVFile.data(PCMAudio(samples: pcm, sampleRate: 24_000))
        let audio = try GeminiTTS.decode(Self.response(parts: [("audio/wav", wav)]))
        XCTAssertEqual(audio.sampleRate, 24_000)
        XCTAssertEqual(audio.channels, 1)
        XCTAssertEqual(audio.samples, pcm)
        XCTAssertEqual(audio.duration, 0.2, accuracy: 0.0001)

        let l16 = try GeminiTTS.decode(Self.response(parts: [("audio/L16;codec=pcm;rate=16000", pcm), ("audio/L16;codec=pcm;rate=16000", pcm)]))
        XCTAssertEqual(l16.sampleRate, 16_000)
        XCTAssertEqual(l16.samples.count, pcm.count * 2)
        XCTAssertEqual(WAVFile.parse(WAVFile.data(l16)), l16, "what is written reads back the same")

        let blocked = Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8)
        XCTAssertThrowsError(try GeminiTTS.decode(blocked)) { XCTAssertEqual($0 as? PodcastSpeechError, .noAudio("SAFETY")) }
        let empty = Data(#"{"candidates":[{"content":{"parts":[]},"finishReason":"OTHER"}]}"#.utf8)
        XCTAssertThrowsError(try GeminiTTS.decode(empty)) { XCTAssertEqual($0 as? PodcastSpeechError, .noAudio("OTHER")) }
        XCTAssertThrowsError(try PCMAudio.decode(pcm, mimeType: "audio/mpeg"))
    }

    func testRateLimitsAreRetriedWithTheServersDelayAndOtherErrorsAreNot() async throws {
        let pcm = Data(count: 4_800)
        TTSStub.responses = [
            (429, Data(#"{"error":{"code":429,"message":"Quota","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"7s"}]}}"#.utf8)),
            (503, Data(#"{"error":{"message":"Overloaded"}}"#.utf8)),
            (200, Self.response(parts: [("audio/wav", WAVFile.data(PCMAudio(samples: pcm, sampleRate: 24_000)))]))
        ]
        var waits: [TimeInterval] = []
        let engine = GeminiSpeechEngine(
            endpoint: .init(provider: .aiStudio, baseURL: "https://generativelanguage.googleapis.com/v1beta", apiKey: "k"),
            voices: PodcastVoices(a: "Kore", b: "Puck"),
            session: TTSStub.session,
            sleep: { waits.append($0) }
        )
        let url = temporaryFolder().appendingPathComponent("chapter.wav")
        let duration = try await engine.synthesize([PodcastTurn(speaker: .a, text: "Hi.")], to: url)
        XCTAssertEqual(duration, 0.1, accuracy: 0.0001)
        XCTAssertEqual(TTSStub.requests.count, 3)
        XCTAssertEqual(waits.first, 7, "RetryInfo's delay is honored")
        XCTAssertEqual(waits.count, 2)
        XCTAssertGreaterThanOrEqual(waits[1], 4, "then exponential backoff")
        XCTAssertEqual(WAVFile.parse(try Data(contentsOf: url))?.sampleRate, 24_000)

        TTSStub.reset()
        TTSStub.responses = [(400, Data(#"{"error":{"message":"API key not valid."}}"#.utf8))]
        waits = []
        do {
            _ = try await engine.synthesize([PodcastTurn(speaker: .a, text: "Hi.")], to: url)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PodcastSpeechError, .http(400, "API key not valid."))
        }
        XCTAssertEqual(TTSStub.requests.count, 1)
        XCTAssertTrue(waits.isEmpty)
    }

    // MARK: Engine selection

    func testEngineKindLabels() {
        XCTAssertEqual(PodcastEngineKind.aiStudio.label, PodcastEngineChoice.google.label)
        XCTAssertEqual(PodcastEngineKind.vertex.label, PodcastEngineChoice.google.label)
        XCTAssertEqual(PodcastEngineKind.onDevice.label, PodcastEngineChoice.onDevice.label)
        XCTAssertNotEqual(PodcastEngineKind.vertex.label, PodcastEngineKind.onDevice.label)
    }

    func testGoogleVoicesNeedAKeyOtherwiseTheDeviceSpeaks() {
        XCTAssertEqual(PodcastEngineSelector.select(choice: .automatic, providers: []), .engine(.onDevice))
        XCTAssertEqual(PodcastEngineSelector.select(choice: .google, providers: []), .needsKey)
        XCTAssertEqual(PodcastEngineSelector.select(choice: .automatic, providers: [.aiStudio]), .engine(.aiStudio))
        XCTAssertEqual(PodcastEngineSelector.select(choice: .google, providers: [.aiStudio]), .engine(.aiStudio))
        XCTAssertEqual(PodcastEngineSelector.select(choice: .automatic, providers: [.vertex, .aiStudio]), .engine(.vertex))
        XCTAssertEqual(PodcastEngineSelector.select(choice: .google, providers: [.vertex, .aiStudio]), .engine(.vertex))
        XCTAssertEqual(PodcastEngineSelector.select(choice: .onDevice, providers: [.vertex]), .engine(.onDevice))
    }

    func testGoogleVoicesWithoutAKeyTellTheUserAndOpenSetupInsteadOfDeviceFallback() async throws {
        let harness = makeHarness()
        let app = harness.app
        connect(app)
        var chosenKinds: [PodcastEngineKind] = []
        app.podcast.makeEngine = { kind, _, _ in
            chosenKinds.append(kind)
            return FakeSpeechEngine()
        }

        app.settings.podcast.engine = .google
        app.podcast.readAloud(id: "summary-google", title: "Topic", text: "A short summary to speak.")
        XCTAssertNil(app.podcast.readAloudID)
        XCTAssertNil(app.podcast.player.playlist)
        XCTAssertTrue(chosenKinds.isEmpty)
        XCTAssertEqual(app.presentedError, PodcastController.missingGoogleKeyMessage)
        XCTAssertEqual(app.presentedErrorAction, .openAIModels)

        let action = try XCTUnwrap(app.presentedErrorAction)
        app.performErrorAction(action, after: .zero)
        try await waitUntil { app.requestedSettingsPage == .provider }
        XCTAssertNil(app.presentedError)
    }

    func testTwoDistinctSystemVoicesAreChosenForTheAppLanguage() {
        let voices = [
            SystemVoiceCandidate(identifier: "en.novelty", language: "en-US", quality: 3, isNovelty: true),
            SystemVoiceCandidate(identifier: "en.samantha", language: "en-US", quality: 1, gender: .female),
            SystemVoiceCandidate(identifier: "en.ava.premium", language: "en-US", quality: 3, gender: .female),
            SystemVoiceCandidate(identifier: "en.zoe.premium", language: "en-US", quality: 3, gender: .female),
            SystemVoiceCandidate(identifier: "en.evan.premium", language: "en-US", quality: 3, gender: .male),
            SystemVoiceCandidate(identifier: "en.daniel", language: "en-GB", quality: 2, gender: .male),
            SystemVoiceCandidate(identifier: "zh.tingting", language: "zh-CN", quality: 2, gender: .female),
            SystemVoiceCandidate(identifier: "zh.meijia", language: "zh-TW", quality: 1, gender: .female)
        ]
        XCTAssertEqual(PodcastSystemVoices.pick(appLanguage: "en", from: voices, region: "US"), .init(a: "en.ava.premium", b: "en.evan.premium"))
        XCTAssertEqual(PodcastSystemVoices.pick(appLanguage: "zh-Hans", from: voices, region: "CN"), .init(a: "zh.tingting", b: "zh.meijia"))
        let onlyOne = [SystemVoiceCandidate(identifier: "zh.meijia", language: "zh-TW", quality: 1)]
        let pick = PodcastSystemVoices.pick(appLanguage: "zh-Hant", from: onlyOne, region: "TW")
        XCTAssertEqual(pick?.a, "zh.meijia")
        XCTAssertTrue(pick?.sameVoice ?? false)
        XCTAssertNil(PodcastSystemVoices.pick(appLanguage: "en", from: [voices[6]], region: "US"))
    }

    // MARK: Settings & legacy compatibility

    func testPodcastSettingsDefaultsAndLegacyDigestKeysDecodeCleanly() throws {
        let settings = AppSettings()
        XCTAssertEqual(settings.podcast.engine, .automatic)
        XCTAssertEqual(settings.podcast.voiceA, "Kore")

        // Legacy snapshots containing removed daily digest & two-host podcast keys decode cleanly.
        let legacyJSON = #"""
        {
            "dailyDigestEnabled": true,
            "dailyDigestNotifies": true,
            "dailyDigestIncludesWatched": false,
            "dailyDigestIncludesTrending": false,
            "dailyDigestMaxCards": 12,
            "podcastDailyEnabled": true,
            "podcast": {
                "hostA": "Mei",
                "hostB": "Leo",
                "voiceA": "Nobody",
                "voiceB": "Puck",
                "minutesPerChapter": 40,
                "engine": "future"
            }
        }
        """#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.podcast.voiceA, "Kore")
        XCTAssertEqual(decoded.podcast.engine, .automatic)
    }

    // MARK: Player

    func testTheTimelineSkipsAcrossChaptersAndNeverIntoOneNotMadeYet() {
        let timeline = PodcastTimeline(durations: [10, 30, 20, nil])
        typealias P = PodcastTimeline.Position
        XCTAssertEqual(timeline.total, 60)
        XCTAssertEqual(timeline.skip(15, from: P(chapter: 0, time: 2)), P(chapter: 1, time: 7))
        XCTAssertEqual(timeline.skip(-15, from: P(chapter: 1, time: 7)), P(chapter: 0, time: 2))
        XCTAssertEqual(timeline.skip(-15, from: P(chapter: 0, time: 5)), P(chapter: 0, time: 0))
        XCTAssertEqual(timeline.skip(15, from: P(chapter: 2, time: 10)), P(chapter: 2, time: 19.5))
        XCTAssertEqual(timeline.previousChapter(from: P(chapter: 2, time: 8)), P(chapter: 2, time: 0))
        XCTAssertEqual(timeline.previousChapter(from: P(chapter: 2, time: 1)), P(chapter: 1, time: 0))
        XCTAssertEqual(timeline.nextChapter(from: P(chapter: 2, time: 1)), P(chapter: 3, time: 0))
        XCTAssertNil(timeline.nextChapter(from: P(chapter: 3, time: 0)))
        XCTAssertEqual(timeline.position(atElapsed: 45), P(chapter: 2, time: 5))
        XCTAssertEqual(timeline.elapsed(P(chapter: 2, time: 5)), 45)
    }

    func testThePlayerMovesThroughChaptersWaitsForNewOnesAndRemembersWhereItWas() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "podcast-tests-\(UUID().uuidString)"))
        let audio = FakePodcastAudio()
        let session = FakePodcastSession()
        let player = PodcastPlayer(audio: audio, session: session, positions: PodcastPositionStore(defaults: defaults))
        var playlist = Self.playlist(durations: [10, 30, nil])
        playlist.isGrowing = true

        player.load(playlist, autoplay: true)
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(session.activations, 1)
        XCTAssertEqual(audio.loaded.last?.lastPathComponent, "0.wav")

        audio.currentTime = 4
        player.skip(by: 15)
        XCTAssertEqual(player.position, .init(chapter: 1, time: 9))
        XCTAssertEqual(audio.loaded.last?.lastPathComponent, "1.wav")
        XCTAssertEqual(audio.currentTime, 9)

        player.previousChapter()
        XCTAssertEqual(player.chapterIndex, 1)
        player.previousChapter()
        XCTAssertEqual(player.chapterIndex, 0)
        player.nextChapter()
        XCTAssertEqual(player.chapterIndex, 1)

        audio.finish()
        XCTAssertEqual(player.state, .waiting)
        XCTAssertEqual(player.chapterIndex, 2)
        playlist.items[2].url = URL(fileURLWithPath: "/tmp/2.wav")
        playlist.items[2].duration = 20
        playlist.isGrowing = false
        player.update(playlist)
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(audio.loaded.last?.lastPathComponent, "2.wav")

        audio.currentTime = 12
        player.pause()
        XCTAssertEqual(player.state, .paused)
        let relaunched = PodcastPlayer(audio: FakePodcastAudio(), session: FakePodcastSession(), positions: PodcastPositionStore(defaults: defaults))
        relaunched.load(playlist)
        XCTAssertEqual(relaunched.position, .init(chapter: 2, time: 12))
        XCTAssertEqual(relaunched.state, .paused)

        player.play()
        audio.finish()
        XCTAssertEqual(player.state, .paused)
        player.play()
        XCTAssertEqual(player.chapterIndex, 0)
        XCTAssertEqual(player.state, .playing)
    }

    func testCallsPauseAndResumeAndUnpluggedHeadphonesPause() {
        let audio = FakePodcastAudio()
        let player = PodcastPlayer(audio: audio, session: FakePodcastSession(), positions: PodcastPositionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        player.load(Self.playlist(durations: [10, 10]), autoplay: true)

        player.interruptionBegan()
        XCTAssertEqual(player.state, .paused)
        XCTAssertFalse(audio.isPlaying)
        player.interruptionEnded(shouldResume: true)
        XCTAssertEqual(player.state, .playing)

        player.interruptionBegan()
        player.interruptionEnded(shouldResume: false)
        XCTAssertEqual(player.state, .paused)

        player.play()
        player.outputDeviceLost()
        XCTAssertEqual(player.state, .paused)
    }

    // MARK: Read aloud

    func testAFailedReadAloudLeavesNothingLoadedSoTheNextTapTriesAgain() async throws {
        let harness = makeHarness()
        let app = harness.app
        let engine = FailingSpeechEngine()
        app.podcast.makeEngine = { _, _, _ in engine }
        app.settings.podcast.engine = .onDevice

        app.podcast.readAloud(id: "summary-1", title: "Topic", text: "A short summary. It has two sentences.")
        XCTAssertEqual(app.podcast.readAloudID, "summary-1")
        try await waitUntil { app.podcast.player.playlist == nil }
        XCTAssertNil(app.podcast.readAloudID)
        XCTAssertNotNil(app.podcast.lastError)
        app.podcast.readAloud(id: "summary-1", title: "Topic", text: "A short summary. It has two sentences.")
        try await waitUntil { engine.attempts == 2 }
    }

    func testReadAloudUsesReadingLanguageAndDetectedTextLanguage() {
        let harness = makeHarness()
        let app = harness.app
        app.settings.podcast.engine = .onDevice
        var capturedLanguages: [String] = []
        app.podcast.makeEngine = { _, _, language in
            capturedLanguages.append(language)
            return FakeSpeechEngine()
        }

        app.settings.readingLanguage = "zh-Hans"
        app.podcast.readAloud(id: "zh-setting", title: "测试标题", text: "这是一个关于论坛帖子的中文总结。")
        app.podcast.cancelReadAloud()
        app.podcast.player.unload(forgettingPosition: true)

        app.settings.readingLanguage = "pt-BR"
        app.podcast.readAloud(id: "pt-setting", title: "Resumo", text: "Este é um resumo completo sobre o tópico do fórum.")
        app.podcast.cancelReadAloud()
        app.podcast.player.unload(forgettingPosition: true)

        app.settings.readingLanguage = ""
        app.podcast.readAloud(id: "zh-detected", title: "中文总结", text: "这是一个关于论坛帖子的中文总结，详细说明了固件升级后的解决方法。")
        app.podcast.cancelReadAloud()
        app.podcast.player.unload(forgettingPosition: true)

        XCTAssertEqual(capturedLanguages, ["zh-Hans", "pt-BR", "zh-Hans"])
    }

    func testFailedReadAloudPresentsRootErrorAlert() async throws {
        let harness = makeHarness()
        let app = harness.app
        let engine = FailingSpeechEngine()
        app.podcast.makeEngine = { _, _, _ in engine }
        app.settings.podcast.engine = .onDevice

        app.podcast.readAloud(id: "summary-err", title: "Topic", text: "A short summary to speak aloud.")
        try await waitUntil { app.podcast.player.playlist == nil }
        XCTAssertNotNil(app.presentedError, "Failed Read aloud must present an error alert instead of failing silently")
    }

    func testReconcilePrunesLegacyEpisodeFoldersAndKeepsFreshReadAloudAudio() throws {
        let folder = temporaryFolder()
        let store = PodcastStore(directory: folder)
        let legacyDir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: legacyDir.appendingPathComponent("episode.json"))
        try FileManager.default.createDirectory(at: store.readAloudDirectory, withIntermediateDirectories: true)
        let freshFile = store.readAloudDirectory.appendingPathComponent("fresh.wav")
        try Data("audio".utf8).write(to: freshFile)

        store.reconcile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshFile.path))
    }

    func testSystemPodcastAudioSessionRestoresPlaybackAfterVoiceEnds() throws {
        let shared = AVAudioSession.sharedInstance()
        let lease = VoiceAudioEngine.SessionLease()
        addTeardownBlock {
            lease.release()
            try? shared.setActive(false, options: .notifyOthersOnDeactivation)
        }
        let podcastSession = SystemPodcastAudioSession()

        try shared.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        lease.acquire()
        XCTAssertTrue(VoiceAudioEngine.hasActiveSession)
        try podcastSession.activateForPlayback()
        XCTAssertEqual(shared.category, .playAndRecord)
        XCTAssertEqual(shared.mode, .voiceChat)
        podcastSession.deactivate()
        XCTAssertEqual(shared.category, .playAndRecord)

        lease.release()
        XCTAssertFalse(VoiceAudioEngine.hasActiveSession)
        try? shared.setActive(false, options: .notifyOthersOnDeactivation)

        try podcastSession.activateForPlayback()
        XCTAssertEqual(shared.category, .playback, "Once voice has stopped, activateForPlayback() must switch leftover .playAndRecord back to .playback")
        XCTAssertEqual(shared.mode, .spokenAudio, "Once voice has stopped, activateForPlayback() must switch leftover .voiceChat back to .spokenAudio")
        podcastSession.deactivate()
    }

    // MARK: Helpers

    private static func playlist(durations: [TimeInterval?]) -> PodcastPlaylist {
        PodcastPlaylist(id: "read-aloud:test", title: "Summary", items: durations.enumerated().map { index, duration in
            PodcastPlaylist.Item(id: "\(index)", title: "Chunk \(index)", url: duration.map { _ in URL(fileURLWithPath: "/tmp/\(index).wav") }, duration: duration)
        })
    }

    private static func response(parts: [(String, Data)]) -> Data {
        let encoded = parts.map { #"{"inlineData":{"mimeType":"\#($0.0)","data":"\#($0.1.base64EncodedString())"}}"# }
        return Data(#"{"candidates":[{"content":{"role":"model","parts":[\#(encoded.joined(separator: ","))]},"finishReason":"STOP"}]}"#.utf8)
    }

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private struct Harness {
        let app: AppModel
        let ai: PodcastAIStub
    }

    private func makeHarness() -> Harness {
        let folder = temporaryFolder()
        let store = PersistentStore(fileURL: folder.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let ai = PodcastAIStub()
        var seeded = AppSnapshot()
        seeded.ensureForum(site)
        try? store.save(seeded)
        let app = AppModel(
            store: store,
            aiService: ai,
            podcastDirectory: folder.appendingPathComponent("Podcasts", isDirectory: true)
        )
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        addTeardownBlock { @MainActor in
            app.podcast.cancelReadAloud()
            app.podcast.player.unload()
        }
        return Harness(app: app, ai: ai)
    }

    private func connect(_ app: AppModel) {
        app.allowAllAIProviders()
        var configuration = app.settings.configuration(for: .openAI)
        configuration.apiKey = "key"
        app.setConfiguration(configuration, for: .openAI)
        app.selectModel(ModelSelection(provider: .openAI, model: "gpt-test"), for: .role(.assistant))
        app.settings.hasCompletedOnboarding = true
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

// MARK: - Fakes

final class PodcastAIStub: AIService, @unchecked Sendable {
    struct Call {
        var system: String
        var messages: [ChatMessage]
    }

    @MainActor var answers: [String] = []
    @MainActor var calls: [Call] = []

    init() {
        super.init(session: .shared)
    }

    override func complete(system: String, messages: [ChatMessage], configuration: ProviderConfiguration, provider: AIProvider, maxTokens: Int = 4_096) async throws -> String {
        await MainActor.run {
            calls.append(Call(system: system, messages: messages))
            let index = min(calls.count - 1, answers.count - 1)
            return index >= 0 ? answers[index] : ""
        }
    }

    override func streamText(system: String, messages: [ChatMessage], configuration: ProviderConfiguration, provider: AIProvider, maxTokens: Int = 16_384, onDelta: @escaping @MainActor (String) -> Void) async throws -> String {
        XCTFail("no streamed request in podcast tests")
        throw AssistantError.emptyResponse
    }
}

@MainActor
final class FakeSpeechEngine: PodcastSpeechEngine {
    private(set) var spoken: [[PodcastTurn]] = []
    var fileExtension: String { "wav" }

    func synthesize(_ turns: [PodcastTurn], to url: URL) async throws -> TimeInterval {
        spoken.append(turns)
        try WAVFile.data(PCMAudio(samples: Data(count: 1_600), sampleRate: 8_000)).write(to: url)
        return 0.1
    }
}

@MainActor
final class GatedSpeechEngine: PodcastSpeechEngine {
    private(set) var attempts = 0
    var gated = true
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    var fileExtension: String { "wav" }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func synthesize(_ turns: [PodcastTurn], to url: URL) async throws -> TimeInterval {
        attempts += 1
        if gated { await withCheckedContinuation { continuation = $0 } }
        try Task.checkCancellation()
        try WAVFile.data(PCMAudio(samples: Data(count: 1_600), sampleRate: 8_000)).write(to: url)
        return 0.1
    }
}

@MainActor
final class FailingSpeechEngine: PodcastSpeechEngine {
    private(set) var attempts = 0
    var fileExtension: String { "wav" }

    func synthesize(_ turns: [PodcastTurn], to url: URL) async throws -> TimeInterval {
        attempts += 1
        throw PodcastSpeechError.http(400, "Invalid voice")
    }
}

@MainActor
final class FakePodcastAudio: PodcastAudioPlayback {
    private(set) var loaded: [URL] = []
    private(set) var isPlaying = false
    var currentTime: TimeInterval = 0
    var onFinish: (() -> Void)?

    func load(_ url: URL) throws -> TimeInterval {
        loaded.append(url)
        currentTime = 0
        return 10
    }

    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }

    func finish() {
        isPlaying = false
        onFinish?()
    }
}

@MainActor
final class FakePodcastSession: PodcastAudioSessioning {
    private(set) var activations = 0
    var handsFree = false

    func activateForPlayback() throws { activations += 1 }
    func deactivate() {}
    var routeIsHandsFree: Bool { handsFree }
}

final class TTSStub: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        responses = []
        requests = []
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TTSStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.responses.isEmpty ? (500, Data()) : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
