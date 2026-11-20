import AVFoundation
import Combine
import Foundation

// MARK: - Read aloud controller
//
// Owned by AppModel (`app.podcast`), like `VoiceController`.
// Reads a summary or page text aloud with one voice (Google Gemini TTS or
// on-device AVSpeechSynthesizer) through `PodcastPlayer`.

@MainActor
final class PodcastController: ObservableObject {
    /// Why the last read-aloud run stopped.
    @Published private(set) var lastError: String?
    /// The read-aloud being made or played (its id), for the buttons.
    @Published private(set) var readAloudID: String?

    let player: PodcastPlayer
    let store: PodcastStore
    /// The speech engine for a kind (tests and `-dc-podcast-fake` replace it).
    var makeEngine: ((PodcastEngineKind, PodcastVoices, String) -> PodcastSpeechEngine)?

    private weak var app: AppModel?
    private var readTask: Task<Void, Never>?
    private var playerSubscription: AnyCancellable?

    init(app: AppModel, store: PodcastStore, player: PodcastPlayer? = nil) {
        self.app = app
        self.store = store
        if let player {
            self.player = player
        } else if AppModel.isRunningTests {
            self.player = PodcastPlayer.makeForTesting()
        } else {
            let session = SystemPodcastAudioSession()
            let made = PodcastPlayer(audio: SystemPodcastAudio(), session: session, nowPlaying: SystemPodcastNowPlaying())
            session.player = made
            self.player = made
        }
        // The player's state changes redraw the views that observe this
        // controller; its time ticks (twice a second) do not.
        let player = self.player
        playerSubscription = Publishers.MergeMany(
            player.$playlist.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            player.$state.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            player.$chapterIndex.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            player.$isSuspendedForVoice.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            player.$failure.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ).sink { [weak self] in self?.objectWillChange.send() }
    }

    deinit {
        readTask?.cancel()
    }

    static var isFake: Bool {
        #if DEBUG
        AssistantDebug.isActive && AssistantDebug.has("-dc-podcast-fake")
        #else
        false
        #endif
    }

    /// Google providers with a key and AI data consent, the voice provider first.
    var googleProviders: [VoiceProvider] {
        guard let app else { return [] }
        let preferred = app.settings.voice.provider
        return VoiceProvider.allCases
            .filter {
                !app.settings.configuration(for: $0.keyProvider).apiKey.isEmpty
                    && app.aiConsentState(for: $0.keyProvider).permitsRequests
            }
            .sorted { ($0 == preferred ? 0 : 1) < ($1 == preferred ? 0 : 1) }
    }

    func engineSelection() -> PodcastEngineSelection {
        if Self.isFake { return .engine(.fake) }
        guard let app else { return .engine(.onDevice) }
        return PodcastEngineSelector.select(
            choice: app.settings.podcast.engine,
            providers: googleProviders
        )
    }

    static var missingGoogleKeyMessage: String {
        String(
            localized: "Add a Google Gemini or Vertex AI key in Settings › AI models to use Google’s voices.",
            comment: "Read aloud error: Google voices are selected, and neither a Google Gemini nor a Vertex AI key is saved. Settings › AI models names the app's own Settings pages."
        )
    }

    private func presentMissingGoogleKeyError() {
        let message = Self.missingGoogleKeyMessage
        lastError = message
        app?.presentError(message, action: .openAIModels)
    }

    private func engine(_ kind: PodcastEngineKind, voices: PodcastVoices, language: String) -> PodcastSpeechEngine {
        if let makeEngine { return makeEngine(kind, voices, language) }
        switch kind {
        case .aiStudio, .vertex:
            let provider = kind.provider ?? .aiStudio
            let configuration = app?.settings.configuration(for: provider.keyProvider) ?? ProviderConfiguration(provider: provider.keyProvider)
            return GeminiSpeechEngine(
                endpoint: GeminiTTS.Endpoint(provider: provider, baseURL: configuration.baseURL, apiKey: configuration.apiKey),
                voices: voices,
                consentCheck: { [weak app] in
                    guard let app else { throw AssistantError.aiConsentRequired(provider.keyProvider) }
                    try app.settings.requireAIConsent(for: provider.keyProvider)
                }
            )
        case .fake:
            #if DEBUG
            return SilentSpeechEngine()
            #else
            return SystemSpeechEngine(appLanguage: language)
            #endif
        case .onDevice:
            #if DEBUG
            if AppModel.isRunningTests { return SilentSpeechEngine() }
            #endif
            return SystemSpeechEngine(appLanguage: language)
        }
    }

    // MARK: Read aloud

    static func readAloudPlaylistID(_ id: String) -> String { "read-aloud:\(id)" }

    func isReadingAloud(_ id: String) -> Bool {
        player.playlist?.id == Self.readAloudPlaylistID(id) && player.isActive
    }

    /// Reads a text with one voice (voice A). Tapping again pauses it.
    func readAloud(id: String, title: String, text: String) {
        let playlistID = Self.readAloudPlaylistID(id)
        if player.playlist?.id == playlistID {
            player.toggle()
            return
        }
        guard let app else { return }
        let kind: PodcastEngineKind
        switch engineSelection() {
        case .needsKey:
            presentMissingGoogleKeyError()
            return
        case .engine(let selected):
            kind = selected
        }
        let chunks = Self.readAloudChunks(PodcastSpeechCheck.speakable(text))
        guard !chunks.isEmpty else { return }
        cancelReadAloud()
        readAloudID = id
        var playlist = PodcastPlaylist(
            id: playlistID,
            title: title,
            items: chunks.indices.map { PodcastPlaylist.Item(id: "\($0)", title: title) },
            isGrowing: true
        )
        player.load(playlist, chapter: 0, autoplay: true)
        let voices = PodcastVoices(a: app.settings.podcast.voiceA, b: app.settings.podcast.voiceA)
        let preferredLanguage = ReadingLanguage.resolved(app.settings.readingLanguage)
        let language: String
        if let detected = ReadingLanguage.detect(chunks.joined(separator: " ")),
           !ReadingLanguage.sameLanguage(detected, preferredLanguage) {
            language = detected
        } else {
            language = preferredLanguage
        }
        let engine = engine(kind, voices: voices, language: language)
        #if DEBUG
        // The fake engine's silence outlasts any UI test: the listen row reads
        // "Pause" only while playing, and a test that polls for it on a slow
        // runner must not find the 4 s file already finished (WUKO-153).
        (engine as? SilentSpeechEngine)?.secondsPerTurn = 120
        #endif
        let folder = store.readAloudDirectory
        let key = Self.cacheKey("\(kind.rawValue)|\(voices.a)|\(language)|\(text)")
        readTask = Task { @MainActor [weak self] in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, chunk) in chunks.enumerated() {
                // Keep `self` weak across `engine.synthesize` so releasing
                // `AppModel` cancels read-aloud instead of pinning the
                // controller alive and starting audio on a dead instance.
                guard self?.app != nil, self?.readAloudID == id, !Task.isCancelled else { return }
                let url = folder.appendingPathComponent("\(key)-\(index).\(engine.fileExtension)")
                do {
                    // Read before: the file is reused (no second request).
                    var duration = Self.cachedDuration(url) ?? 0
                    if duration == 0 {
                        duration = try await engine.synthesize([PodcastTurn(speaker: .a, text: chunk)], to: url)
                    }
                    guard let self, self.app != nil, self.readAloudID == id, !Task.isCancelled else { return }
                    playlist.items[index].url = url
                    playlist.items[index].duration = duration
                    playlist.isGrowing = index < chunks.count - 1
                    self.player.update(playlist)
                } catch {
                    guard let self, self.app != nil, self.readAloudID == id, !Task.isCancelled else { return }
                    try? FileManager.default.removeItem(at: url)
                    self.lastError = error.localizedDescription
                    self.app?.presentError(error.localizedDescription)
                    // Nothing half-loaded stays: the next tap tries again.
                    self.player.unload(forgettingPosition: true)
                    self.readAloudID = nil
                    self.readTask = nil
                    return
                }
            }
            if let self, self.readAloudID == id {
                self.readTask = nil
            }
        }
    }

    func cancelReadAloud() {
        readTask?.cancel()
        readTask = nil
        readAloudID = nil
    }

    /// Pieces of about `limit` characters, cut at sentence ends, so the
    /// first can play while the rest is made.
    static func readAloudChunks(_ text: String, limit: Int = 1_200) -> [String] {
        var chunks: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
            if !current.isEmpty, current.count + sentence.count > limit {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? sentence : " " + sentence
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// The duration of a read-aloud file made earlier, if it is there.
    private static func cachedDuration(_ url: URL) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url), file.length > 0
        else {
            return nil
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func cacheKey(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: Storage

    /// Prunes read-aloud audio older than 7 days and any legacy episode folders.
    func reconcile() {
        store.reconcile()
    }

    /// Clears all cached read-aloud audio.
    func deleteAll() {
        cancelReadAloud()
        store.deleteAll()
        player.unload(forgettingPosition: true)
    }
}
