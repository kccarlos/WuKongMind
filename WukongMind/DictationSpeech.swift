import AVFoundation
import Foundation
import OSLog
import Speech

// MARK: - System speech recognition for dictation

/// Dictation on Apple's speech recognition: on-device where the language
/// supports it, Apple's servers otherwise (the usage description says so).
@MainActor
final class SystemDictationBackend: DictationBackend {
    /// The recognizer language for the app's interface language: the
    /// language the user reads is the one they dictate in.
    nonisolated static func recognizerLocale(appLanguage: String, current: Locale = .current) -> Locale {
        switch appLanguage {
        case "zh-Hans":
            return Locale(identifier: "zh-CN")
        case "zh-Hant":
            // Hong Kong speaks Cantonese there; everyone else gets Taiwan Mandarin.
            return Locale(identifier: current.region?.identifier == "HK" ? "zh-HK" : "zh-TW")
        default:
            if current.language.languageCode?.identifier == appLanguage { return current }
            return Locale(identifier: appLanguage == "en" ? "en-US" : appLanguage)
        }
    }

    private static let log = Logger(subsystem: "io.github.kccarlos.wukongmind", category: "Dictation")

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var runID = 0

    func requestPermission() async -> DictationPermission {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return .speechDenied }
        guard await AVAudioApplication.requestRecordPermission() else { return .microphoneDenied }
        return .granted
    }

    func start(onUpdate: @escaping @MainActor (String) -> Void, onEnd: @escaping @MainActor (DictationFailure?) -> Void) {
        begin(preferOnDevice: true, onUpdate: onUpdate, onEnd: onEnd)
    }

    /// `preferOnDevice`: audio stays on the phone where the language has an
    /// on-device model. If that recognizer fails before the first word (a
    /// missing model, the simulator), it is tried once more with Apple's
    /// servers rather than giving up.
    private func begin(
        preferOnDevice: Bool,
        onUpdate: @escaping @MainActor (String) -> Void,
        onEnd: @escaping @MainActor (DictationFailure?) -> Void
    ) {
        tearDown()
        runID += 1
        let id = runID
        let locale = Self.recognizerLocale(appLanguage: AppLanguage.current)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            onEnd(.unavailable)
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let onDevice = preferOnDevice && recognizer.supportsOnDeviceRecognition
        if onDevice { request.requiresOnDeviceRecognition = true }
        self.request = request

        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                Self.log.error("No microphone input format (sample rate \(format.sampleRate), channels \(format.channelCount))")
                tearDown()
                onEnd(.audio)
                return
            }
            Self.installTap(on: input, format: format, request: request)
            engine.prepare()
            try engine.start()
        } catch {
            Self.log.error("Audio start failed: \(error.localizedDescription, privacy: .public)")
            tearDown()
            onEnd(.audio)
            return
        }
        self.engine = engine

        var heardText = false
        task = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.resultHandler { [weak self] text, isFinal, error in
                guard let self, id == runID else { return }
                if let text, !text.isEmpty { heardText = true }
                if let text { onUpdate(text) }
                if error != nil, !heardText, !isFinal, onDevice {
                    Self.log.error("On-device recognition failed, trying the network recognizer")
                    begin(preferOnDevice: false, onUpdate: onUpdate, onEnd: onEnd)
                    return
                }
                if isFinal || error != nil {
                    tearDown()
                    onEnd(isFinal || text != nil ? nil : Self.failure(for: error))
                }
            }
        )
    }

    func finish() {
        // No more audio; the recognizer delivers its final result.
        stopEngine()
        request?.endAudio()
    }

    func cancel() {
        runID += 1
        tearDown()
    }

    // MARK: Plumbing

    private func stopEngine() {
        if let engine, engine.isRunning {
            engine.stop()
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }

    private func tearDown() {
        stopEngine()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func failure(for error: Error?) -> DictationFailure {
        guard let error else { return .noSpeech }
        let nsError = error as NSError
        log.error("Recognition failed: \(nsError.domain, privacy: .public) \(nsError.code)")
        // kAFAssistantErrorDomain 1110: no speech detected.
        if nsError.domain == "kAFAssistantErrorDomain", nsError.code == 1110 { return .noSpeech }
        // The microphone ran (the audio engine started); the recognizer did not.
        return .unavailable
    }

    /// The tap runs on the audio thread: built outside the main actor so it
    /// does not inherit its isolation.
    private nonisolated static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    /// The recognizer calls back on its own queue: hop to the main actor.
    private nonisolated static func resultHandler(
        _ deliver: @escaping @MainActor (String?, Bool, Error?) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                deliver(text, isFinal, error)
            }
        }
    }
}
