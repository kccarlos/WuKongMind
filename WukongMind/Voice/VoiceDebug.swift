import AVFoundation
import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

/// Developer switches for voice.
enum VoiceDebug {
    /// "Type instead of speak" in the voice bar: typed turns go to the
    /// model as `realtimeInput.text`, so tool routing can be checked without
    /// talking. Debug builds only.
    static var showsTextInput: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// `-dc-voice-fake`: a scripted session with no network, microphone or
    /// key (UI tests and screenshots).
    static var isFake: Bool {
        #if DEBUG
        AssistantDebug.has("-dc-voice-fake")
        #else
        false
        #endif
    }

    /// `-dc-voice-speak-typed`: submitting `voiceTextField` synthesizes speech
    /// via `AVSpeechSynthesizer` and streams 16 kHz PCM16 frames through
    /// `CaptureGate` into `VoiceSession` instead of `realtimeInput.text`.
    static var speaksTypedInput: Bool {
        #if DEBUG
        AssistantDebug.has("-dc-voice-speak-typed")
        #else
        false
        #endif
    }
}

#if DEBUG
/// A Gemini Live server in a box: answers the setup, greets, and echoes
/// typed text back as a model transcript. Nothing leaves the device.
@MainActor
final class ScriptedLiveTransport: LiveTransport {
    let frames: AsyncStream<Data>
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var closeReason: LiveClose?

    init() {
        var continuation: AsyncStream<Data>.Continuation?
        frames = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect(_ request: URLRequest) async throws {}

    func send(_ text: String) {
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        if object["setup"] != nil {
            deliver(#"{"setupComplete":{}}"#, after: .milliseconds(300))
            reply("Hi. I'm listening.", after: .milliseconds(700))
        } else if let typed = (object["realtimeInput"] as? [String: Any])?["text"] as? String {
            reply("You typed: \(typed)", after: .milliseconds(300))
        }
    }

    func close() {
        guard closeReason == nil else { return }
        closeReason = LiveClose(code: LiveClose.normalClosure, reason: "closed")
        continuation?.finish()
        continuation = nil
    }

    private func reply(_ text: String, after delay: Duration) {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        deliver(#"{"serverContent":{"outputTranscription":{"text":"\#(escaped)"}}}"#, after: delay)
        deliver(#"{"serverContent":{"turnComplete":true}}"#, after: delay + .milliseconds(200))
    }

    private func deliver(_ json: String, after delay: Duration) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.continuation?.yield(Data(json.utf8))
        }
    }
}

/// Audio that captures nothing and plays nothing.
@MainActor
final class SilentVoiceAudio: VoiceAudioIO {
    var isPlaying: Bool { false }
    var headphonesConnected: Bool { false }
    func start(frame: @escaping @MainActor (Data) -> Void, gate: @escaping @MainActor (Bool) -> Void) async throws {}
    func stop() {}
    func play(_ pcm: Data) {}
    func flushPlayback() {}
}

// MARK: - Spoken-audio acceptance harness (`-dc-voice-speak-typed`)

/// Fallback `VoiceAudioIO` when a headless simulator has no input channels:
/// runs the real `FrameChunker` + `CaptureGate` and paces 24 kHz playback.
@MainActor
final class SyntheticCaptureVoiceAudio: VoiceAudioIO {
    private var chunker = FrameChunker()
    private var gate = CaptureGate()
    private var onFrame: (@MainActor (Data) -> Void)?
    private var onGate: (@MainActor (Bool) -> Void)?
    private var reportedGateOpen = false
    private var isRunning = false
    private var isMuted = false
    private var playingUntil: TimeInterval = 0
    private(set) var debugBytesPlayed = 0

    var isPlaying: Bool { CFAbsoluteTimeGetCurrent() < playingUntil }
    var headphonesConnected: Bool { false }

    func start(frame: @escaping @MainActor (Data) -> Void, gate: @escaping @MainActor (Bool) -> Void) async throws {
        onFrame = frame
        onGate = gate
        chunker.reset()
        self.gate.reset()
        reportedGateOpen = false
        isRunning = true
    }

    func stop() {
        isRunning = false
        playingUntil = 0
        chunker.reset()
        gate.reset()
        reportGate(open: false)
        onFrame = nil
        onGate = nil
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        chunker.reset()
        gate.reset()
        reportGate(open: false)
    }

    func play(_ pcm: Data) {
        let sampleCount = pcm.count / 2
        guard sampleCount > 0 else { return }
        debugBytesPlayed += pcm.count
        let now = CFAbsoluteTimeGetCurrent()
        playingUntil = max(now, playingUntil) + Double(sampleCount) / VoiceAudioFormat.playbackRate
    }

    func flushPlayback() {
        playingUntil = 0
    }

    func injectCapturedSamples(_ samples: [Int16]) {
        guard isRunning, !isMuted, !samples.isEmpty else { return }
        for frame in chunker.push(samples) {
            let out = gate.push(frame)
            if let transition = out.transition { reportGate(open: transition == .opened) }
            for send in out.send { onFrame?(send.pcm16LEData) }
        }
    }

    private func reportGate(open: Bool) {
        guard open != reportedGateOpen else { return }
        reportedGateOpen = open
        onGate?(open)
    }
}

/// Uses the real `VoiceAudioEngine` on device and falls back to
/// `SyntheticCaptureVoiceAudio` only when a headless simulator reports no
/// microphone input channels.
@MainActor
final class DebugInjectableVoiceAudio: VoiceAudioIO {
    let hardware = VoiceAudioEngine()
    private let synthetic = SyntheticCaptureVoiceAudio()
    private(set) var usesHardware = false

    var hardwareEngine: VoiceAudioEngine? { usesHardware ? hardware : nil }
    var backendName: String { usesHardware ? "VoiceAudioEngine" : "SyntheticCaptureVoiceAudio" }
    var debugBytesPlayed: Int { usesHardware ? hardware.debugBytesPlayed : synthetic.debugBytesPlayed }
    var isPlaying: Bool { usesHardware ? hardware.isPlaying : synthetic.isPlaying }
    var headphonesConnected: Bool { usesHardware ? hardware.headphonesConnected : synthetic.headphonesConnected }

    func start(frame: @escaping @MainActor (Data) -> Void, gate: @escaping @MainActor (Bool) -> Void) async throws {
        #if targetEnvironment(simulator)
        usesHardware = false
        try await synthetic.start(frame: frame, gate: gate)
        #else
        do {
            try await hardware.start(frame: frame, gate: gate)
            usesHardware = true
        } catch VoiceAudioEngine.Failure.noMicrophone {
            usesHardware = false
            try await synthetic.start(frame: frame, gate: gate)
        }
        #endif
        let quiet = [Int16](repeating: 0, count: VoiceAudioFormat.frameSamples)
        for _ in 0..<100 {
            injectSamples(quiet)
        }
    }

    func stop() {
        if usesHardware { hardware.stop() } else { synthetic.stop() }
    }

    func setMuted(_ muted: Bool) {
        if usesHardware { hardware.setMuted(muted) } else { synthetic.setMuted(muted) }
    }

    func play(_ pcm: Data) {
        if usesHardware { hardware.play(pcm) } else { synthetic.play(pcm) }
    }

    func flushPlayback() {
        if usesHardware { hardware.flushPlayback() } else { synthetic.flushPlayback() }
    }

    func injectSamples(_ samples: [Int16]) {
        if usesHardware {
            hardware.injectCapturedSamples(samples)
        } else {
            synthetic.injectCapturedSamples(samples)
        }
    }
}

/// Synthesizes English utterances via `AVSpeechSynthesizer.write` into 16 kHz
/// mono PCM16 frames and streams them at real-time 40 ms pace.
@MainActor
final class SpeechFrameInjector: ObservableObject {
    @Published private(set) var isInjecting = false
    @Published private(set) var utterancesInjected = 0

    // Defer AVSpeechSynthesizer and speechVoices() XPC lookup until speak(_:sink:) is called
    // so creating SpeechFrameInjector never stalls the main thread at launch.
    private lazy var synthesizer = AVSpeechSynthesizer()
    private lazy var voice: AVSpeechSynthesisVoice? = Self.pickPreferredVoice()
    private var streamTask: Task<Void, Never>?

    init() {}

    private static func pickPreferredVoice() -> AVSpeechSynthesisVoice? {
        let preferred = AVSpeechSynthesisVoice.speechVoices()
            .filter {
                $0.language == "en-US"
                    && !$0.voiceTraits.contains(.isNoveltyVoice)
                    && !$0.identifier.contains(".eloquence.")
                    && !$0.identifier.contains(".speech.synthesis.voice.")
            }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        return preferred ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func speak(_ text: String, sink: @escaping @MainActor ([Int16]) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        streamTask?.cancel()
        isInjecting = true
        let voice = self.voice
        let synth = synthesizer
        streamTask = Task { @MainActor [weak self] in
            defer {
                if let self, !Task.isCancelled {
                    self.isInjecting = false
                    self.utterancesInjected += 1
                }
            }
            guard let samples = try? await Self.synthesize(trimmed, voice: voice, synthesizer: synth),
                  !samples.isEmpty, !Task.isCancelled else { return }
            let silenceFrame = [Int16](repeating: 0, count: VoiceAudioFormat.frameSamples)
            // Refill the 4-second (100-frame) VAD room-floor window while gated so
            // the 15th-percentile floor stays at -72 dBFS across the full utterance.
            for _ in 0..<100 {
                sink(silenceFrame)
            }
            for _ in 0..<4 {
                if Task.isCancelled { return }
                sink(silenceFrame)
                try? await Task.sleep(for: .milliseconds(VoiceAudioFormat.frameMilliseconds))
            }
            var offset = 0
            let clock = ContinuousClock()
            var nextTick = clock.now
            while offset < samples.count {
                if Task.isCancelled { return }
                let end = min(samples.count, offset + VoiceAudioFormat.frameSamples)
                var frame = Array(samples[offset..<end])
                if frame.count < VoiceAudioFormat.frameSamples {
                    frame.append(contentsOf: repeatElement(0, count: VoiceAudioFormat.frameSamples - frame.count))
                }
                sink(frame)
                offset = end
                nextTick += .milliseconds(VoiceAudioFormat.frameMilliseconds)
                let now = clock.now
                if nextTick > now {
                    try? await Task.sleep(for: nextTick - now)
                }
            }
            for _ in 0..<15 {
                if Task.isCancelled { return }
                sink(silenceFrame)
                try? await Task.sleep(for: .milliseconds(VoiceAudioFormat.frameMilliseconds))
            }
            for _ in 0..<100 {
                sink(silenceFrame)
            }
        }
    }

    private static func synthesize(
        _ text: String,
        voice: AVSpeechSynthesisVoice?,
        synthesizer: AVSpeechSynthesizer
    ) async throws -> [Int16] {
        let format = PCMConverter.captureFormat()
        let collector = SpeechSampleCollector(format: format)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.prefersAssistiveTechnologySettings = false
        let raw: [Int16] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.continuation = continuation
                synthesizer.write(utterance) { buffer in
                    collector.receive(buffer)
                }
                Task { @MainActor [weak collector] in
                    try? await Task.sleep(for: .seconds(20))
                    collector?.fail(CancellationError())
                }
            }
        } onCancel: {
            Task { @MainActor in synthesizer.stopSpeaking(at: .immediate) }
            collector.fail(CancellationError())
        }
        let maxPeak = PCMLevel.peak(of: raw)
        guard maxPeak > 0 else { return raw }
        let gain = min(8.0, 18_000.0 / Double(maxPeak))
        return raw.map { sample in
            let scaled = (Double(sample) * gain).rounded()
            return Int16(max(-30_000, min(30_000, Int(scaled))))
        }
    }
}

private final class SpeechSampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let format: AVAudioFormat
    private var samples: [Int16] = []
    private var converter: AVAudioConverter?
    var continuation: CheckedContinuation<[Int16], Error>?

    init(format: AVAudioFormat) {
        self.format = format
    }

    func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        lock.lock()
        defer { lock.unlock() }
        guard continuation != nil else { return }
        if pcm.frameLength == 0 {
            continuation?.resume(returning: samples)
            continuation = nil
            return
        }
        if let converted = convert(pcm) {
            samples.append(contentsOf: PCMConverter.samples(of: converted))
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

/// On-demand DOM & link snapshot for `VoiceAnywhereLiveAcceptanceUITests`.
@MainActor
final class VoiceAcceptanceProbe: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var visibleLinkCount = 0
    @Published private(set) var thirdLinkText = ""
    @Published private(set) var thirdLinkURL = ""
    @Published private(set) var headlinePhrase = ""
    @Published private(set) var headlineText = ""
    @Published private(set) var headlineURL = ""
    @Published private(set) var pageLuminance = 1.0
    @Published private(set) var pageBg = ""

    private static let excludedHeadlineWords: Set<String> = [
        "the", "and", "for", "with", "from", "about", "that", "this", "into", "over", "after", "under",
        "have", "will", "what", "when", "where", "your", "their", "more", "read", "watch", "live", "video",
        "audio", "link", "story", "article", "page", "open", "home", "menu", "skip", "content", "bbc", "news"
    ]

    func refresh(app: AppModel) async {
        let currentURL = (app.browser.webView.url ?? app.browser.currentURL)?.absoluteString ?? ""
        let links = await app.pageLinks()
        visibleLinkCount = links.count
        if links.count >= 3 {
            thirdLinkText = links[2].text
            thirdLinkURL = links[2].url.absoluteString
        } else {
            thirdLinkText = ""
            thirdLinkURL = ""
        }

        let orderedIndices = links.indices.sorted { lhs, rhs in
            if links[lhs].inViewport != links[rhs].inViewport { return links[lhs].inViewport }
            return lhs < rhs
        }
        var chosenPhrase = ""
        var chosenText = ""
        var chosenURL = ""
        for idx in orderedIndices where idx != 2 {
            let link = links[idx]
            guard link.url.absoluteString != currentURL else { continue }
            if let phrase = Self.distinctivePhrase(for: link, in: links) {
                chosenPhrase = phrase
                chosenText = link.text
                chosenURL = link.url.absoluteString
                break
            }
        }
        headlinePhrase = chosenPhrase
        headlineText = chosenText
        headlineURL = chosenURL

        if let metrics = (try? await app.browser.webView.callAsyncJavaScript(
            Self.luminanceScript,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )) as? [String: Any] {
            pageLuminance = (metrics["lum"] as? Double) ?? 1.0
            let bg = (metrics["bg"] as? String) ?? ""
            let filter = (metrics["filter"] as? String) ?? ""
            pageBg = filter.isEmpty ? bg : "\(bg) filter:\(filter)"
        }
        revision += 1
    }

    private static func distinctivePhrase(for link: PageLink, in links: [PageLink]) -> String? {
        guard let rx = try? NSRegularExpression(pattern: "[A-Za-z]{4,}") else { return nil }
        let words = rx.matches(in: link.text, range: NSRange(link.text.startIndex..<link.text.endIndex, in: link.text))
            .compactMap { Range($0.range, in: link.text).map { String(link.text[$0]) } }
            .filter { !excludedHeadlineWords.contains($0.lowercased()) }
        guard words.count >= 2 else { return nil }
        for length in [4, 3, 2] where words.count >= length {
            for start in 0...(words.count - length) {
                let candidate = words[start..<(start + length)].joined(separator: " ")
                if case .one(let matched) = VoiceLinkMatcher.match(candidate, in: links),
                   matched.url == link.url {
                    return candidate
                }
            }
        }
        return nil
    }

    private static let luminanceScript = """
    const parseRGB = (s) => {
      const m = s && s.match(/rgba?\\(\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)(?:\\s*,\\s*([0-9.]+))?/i);
      if (!m) return null;
      const a = m[4] !== undefined ? parseFloat(m[4]) : 1;
      if (a < 0.05) return null;
      return [parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10)];
    };
    const nodes = [document.body, document.documentElement, document.querySelector('main'), document.querySelector('article')].filter(Boolean);
    let rgb = null;
    let filterStr = '';
    for (const el of nodes) {
      const cs = getComputedStyle(el);
      if (cs.filter && cs.filter !== 'none') filterStr += ' ' + cs.filter;
      if (!rgb) rgb = parseRGB(cs.backgroundColor);
    }
    if (!rgb) rgb = [255, 255, 255];
    let lum = (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255.0;
    if (/invert\\(\\s*(1|0\\.[789]\\d*|100%|9\\d%|8\\d%)/i.test(filterStr)) {
      lum = 1.0 - lum;
    }
    return { lum: Math.round(lum * 1000) / 1000, bg: `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`, filter: filterStr.trim() };
    """
}

struct VoiceAcceptanceSnapshot: Codable {
    var sessionCount: Int
    var connectionSerial: Int
    var endpoint: String
    var geminiModel: String
    var agentModel: String
    var summaryModel: String
    var audioBackend: String
    var state: String
    var failure: String
    var isInjectingSpeech: Bool
    var utterancesInjected: Int
    var micFramesSent: Int
    var audioFramesSent: Int
    var textFramesSent: Int
    var audioBytesPlayed: Int
    var turnCompleteCount: Int
    var lastUserText: String
    var lastModelText: String
    var userTurns: [String]
    var modelTurns: [String]
    var toolEvents: [VoiceSession.DebugToolEvent]
    var briefingKinds: [String]
    var isHandingOff: Bool
    var agentIsRunning: Bool
    var agentRunCount: Int
    var lastAgentRunState: String
    var podcastPlaying: Bool
    var podcastState: String
    var podcastTime: Double
    var pageURL: String
    var pageHost: String
    var pageTitle: String
    var isForum: Bool
    var cardsCount: Int
    var cardsVisible: Bool
    var probeRevision: Int
    var visibleLinkCount: Int
    var thirdLinkText: String
    var thirdLinkURL: String
    var headlinePhrase: String
    var headlineText: String
    var headlineURL: String
    var pageLuminance: Double
    var pageBg: String
}

/// Zero-chrome accessibility readout (`voiceAcceptanceState`) active only when
/// `-dc-voice-speak-typed` is set. Contains zero secrets.
struct VoiceAcceptanceDebugState: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var podcast: PodcastController
    @ObservedObject var player: PodcastPlayer
    @ObservedObject var injector: SpeechFrameInjector
    @ObservedObject var probe: VoiceAcceptanceProbe
    @State private var tick = 0

    var body: some View {
        let json = encodedSnapshot(tick: tick)
        Text(verbatim: json)
            .font(.system(size: 2))
            .frame(width: 4, height: 4)
            .opacity(0.02)
            .allowsHitTesting(false)
            .accessibilityLabel(Text(verbatim: json))
            .accessibilityIdentifier("voiceAcceptanceState")
            .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
                tick &+= 1
            }
    }

    private func encodedSnapshot(tick _: Int) -> String {
        let session = voice.session
        let endpoint: String = switch session?.configuration.endpoint {
        case .aiStudio?: "aiStudio"
        case .vertex?: "vertex"
        case nil: "none"
        }
        let stateName: String = switch session?.state {
        case .idle?, nil: "idle"
        case .connecting?: "connecting"
        case .listening?: "listening"
        case .thinking?: "thinking"
        case .speaking?: "speaking"
        case .reconnecting?: "reconnecting"
        case .ended?: "ended"
        case .failed?: "failed"
        }
        let failureMessage: String
        if let startFailure = voice.startFailure {
            failureMessage = startFailure.message
        } else if case .failed(let failure)? = session?.state {
            failureMessage = failure.message
        } else {
            failureMessage = ""
        }
        let podcastStateName: String = switch player.state {
        case .idle: "idle"
        case .playing: "playing"
        case .paused: "paused"
        case .waiting: "waiting"
        }
        let runs = app.tabs.tabs.flatMap(\.agentSession.runs)
        let lastRunState: String = switch runs.last?.state {
        case nil: "none"
        case .idle?: "idle"
        case .running?: "running"
        case .completed?: "completed"
        case .stopped?: "stopped"
        case .stepLimitReached?: "stepLimit"
        case .failed(let msg)?: "failed:\(String(msg.prefix(80)))"
        }
        let resolvedURL = browser.webView.url ?? browser.currentURL
        let snapshot = VoiceAcceptanceSnapshot(
            sessionCount: voice.debugSessionCount,
            connectionSerial: session?.debugConnections ?? 0,
            endpoint: endpoint,
            geminiModel: session?.configuration.model ?? GeminiLive.model,
            agentModel: app.selection(for: .browserAgent).model,
            summaryModel: app.selection(for: .assistant).model,
            audioBackend: voice.debugAudioBackendName,
            state: stateName,
            failure: failureMessage,
            isInjectingSpeech: injector.isInjecting,
            utterancesInjected: injector.utterancesInjected,
            micFramesSent: session?.debugMicFramesSent ?? 0,
            audioFramesSent: session?.debugAudioFramesSent ?? 0,
            textFramesSent: session?.debugTextFramesSent ?? 0,
            audioBytesPlayed: voice.debugAudioBytesPlayed,
            turnCompleteCount: session?.debugTurnCount ?? 0,
            lastUserText: String((session?.lastUserText ?? "").prefix(240)),
            lastModelText: String((session?.lastModelText ?? "").prefix(320)),
            userTurns: Array((session?.debugUserTurns ?? []).suffix(16)),
            modelTurns: Array((session?.debugModelTurns ?? []).suffix(16)).map { String($0.prefix(240)) },
            toolEvents: Array((session?.debugToolEvents ?? []).suffix(24)),
            briefingKinds: Array((session?.debugBriefingKinds ?? []).suffix(12)),
            isHandingOff: app.isHandingOff,
            agentIsRunning: app.browserAgent.isRunning,
            agentRunCount: runs.count,
            lastAgentRunState: lastRunState,
            podcastPlaying: player.state == .playing,
            podcastState: podcastStateName,
            podcastTime: (player.time * 100).rounded() / 100,
            pageURL: resolvedURL?.absoluteString ?? "",
            pageHost: resolvedURL?.host?.lowercased() ?? "",
            pageTitle: String((app.pageTitle ?? "").prefix(140)),
            isForum: app.pageContext.isForum,
            cardsCount: app.browseCursor.items.count,
            cardsVisible: app.browseCursor.cards != .hidden && app.browseCursor.matches(app.pageContext),
            probeRevision: probe.revision,
            visibleLinkCount: probe.visibleLinkCount,
            thirdLinkText: String(probe.thirdLinkText.prefix(120)),
            thirdLinkURL: probe.thirdLinkURL,
            headlinePhrase: probe.headlinePhrase,
            headlineText: String(probe.headlineText.prefix(120)),
            headlineURL: probe.headlineURL,
            pageLuminance: probe.pageLuminance,
            pageBg: probe.pageBg
        )
        guard let data = try? JSONEncoder().encode(snapshot),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
#endif
