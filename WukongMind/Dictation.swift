import Foundation
import Observation

// MARK: - Composer dictation (One panel 5)
//
// The composer's microphone turns speech into text in the input box and
// nothing else: the user edits or sends it. Voice sessions (the browser
// bar's microphone) are a separate feature and stay untouched; dictation
// refuses to start while one is running.
//
// `DictationMachine` is the whole state machine as a pure value (tests drive
// it event by event); `DictationController` runs its effects against a
// `DictationBackend` (system speech recognition in `DictationSpeech.swift`,
// a scripted one in tests) and publishes the transcript for the composer.

/// Why dictation did not (or could not) produce text. Each one is said in a
/// single short sentence above the composer, never as a disabled button.
enum DictationFailure: Equatable {
    case microphoneDenied
    case speechDenied
    /// No recognizer for the language, or the system's one is not available.
    case unavailable
    /// A voice session holds the microphone.
    case voiceBusy
    /// Listening ended on its own without a word.
    case noSpeech
    /// The microphone or the audio session would not start.
    case audio

    var message: String {
        switch self {
        case .microphoneDenied:
            String(localized: "Turn on the microphone for WukongMind in Settings to dictate.", comment: "Dictation failure: microphone permission denied; a Settings link follows")
        case .speechDenied:
            String(localized: "Turn on speech recognition for WukongMind in Settings to dictate.", comment: "Dictation failure: speech recognition permission denied; a Settings link follows")
        case .unavailable:
            String(localized: "Dictation isn't available right now.", comment: "Dictation failure: no speech recognizer")
        case .voiceBusy:
            String(localized: "End the voice session before dictating.", comment: "Dictation failure: a voice session is using the microphone")
        case .noSpeech:
            String(localized: "I didn't hear anything. Tap the microphone to try again.", comment: "Dictation failure: nothing was said")
        case .audio:
            String(localized: "The microphone couldn't start. Check that no other app is using it.", comment: "Dictation failure: audio engine or session error")
        }
    }

    /// A permission problem only the Settings app can fix.
    var offersSettings: Bool {
        self == .microphoneDenied || self == .speechDenied
    }
}

/// The answer to "may we listen?".
enum DictationPermission: Equatable {
    case granted
    case microphoneDenied
    case speechDenied
    case unavailable
}

enum DictationPhase: Equatable {
    case idle
    /// The permission prompts (first use) are up or being checked.
    case requesting
    case listening
    /// The user ended listening; the last words are still being recognized.
    case finishing
}

struct DictationMachine: Equatable {
    enum Event: Equatable {
        /// The microphone button. `voiceBusy`: a voice session is active.
        case tap(voiceBusy: Bool)
        case permission(DictationPermission)
        /// The recognizer's best transcript so far (the whole utterance).
        case update(String)
        /// Recognition is over. A failure, when the recognizer reports one.
        case ended(DictationFailure?)
        /// The composer sent or cleared the text, or the panel went away.
        case cancel
        case dismissFailure
    }

    enum Effect: Equatable {
        case requestPermission
        case startRecognition
        /// Stop listening and let the recognizer deliver the last words.
        case finishRecognition
        case cancelRecognition
    }

    private(set) var phase: DictationPhase = .idle
    private(set) var transcript = ""
    private(set) var failure: DictationFailure?

    var isListening: Bool { phase == .listening }
    /// The microphone is (about to be) in use: the button shows Stop.
    var isBusy: Bool { phase == .requesting || phase == .listening }

    mutating func send(_ event: Event) -> [Effect] {
        switch (phase, event) {
        case (.idle, .tap(let voiceBusy)):
            if voiceBusy {
                failure = .voiceBusy
                return []
            }
            failure = nil
            transcript = ""
            phase = .requesting
            return [.requestPermission]

        case (.requesting, .tap):
            // Stop before the first prompt was answered.
            phase = .idle
            return []

        case (.listening, .tap):
            phase = .finishing
            return [.finishRecognition]

        case (.requesting, .permission(let permission)):
            switch permission {
            case .granted:
                phase = .listening
                return [.startRecognition]
            case .microphoneDenied:
                return fail(.microphoneDenied)
            case .speechDenied:
                return fail(.speechDenied)
            case .unavailable:
                return fail(.unavailable)
            }

        case (.listening, .update(let text)), (.finishing, .update(let text)):
            transcript = text
            return []

        case (.listening, .ended(let reported)):
            phase = .idle
            // Words heard win over a late error; silence is said.
            if transcript.isEmpty { failure = reported ?? .noSpeech }
            return []

        case (.finishing, .ended(let reported)):
            phase = .idle
            // The user stopped it: nothing heard is not a failure, a broken
            // microphone still is.
            if transcript.isEmpty, let reported, reported != .noSpeech { failure = reported }
            return []

        case (.requesting, .cancel):
            phase = .idle
            return []

        case (.listening, .cancel), (.finishing, .cancel):
            phase = .idle
            return [.cancelRecognition]

        case (_, .dismissFailure):
            failure = nil
            return []

        default:
            // Late callbacks after the end, a tap while finishing, …
            return []
        }
    }

    private mutating func fail(_ reason: DictationFailure) -> [Effect] {
        phase = .idle
        failure = reason
        return []
    }
}

/// What the controller needs from the platform. Callbacks arrive on the
/// main actor.
@MainActor
protocol DictationBackend: AnyObject {
    func requestPermission() async -> DictationPermission
    /// Starts listening. `onUpdate` delivers the whole transcript so far;
    /// `onEnd` fires once when recognition is over (nil: finished normally).
    func start(onUpdate: @escaping @MainActor (String) -> Void, onEnd: @escaping @MainActor (DictationFailure?) -> Void)
    /// Stop listening; the last words still arrive through `onUpdate`, then `onEnd`.
    func finish()
    /// Stop at once; no more callbacks matter.
    func cancel()
}

@MainActor
@Observable
final class DictationController {
    private(set) var machine = DictationMachine()
    /// How long the last words may take after the user stopped.
    var finishTimeout: Duration = .seconds(2)

    @ObservationIgnored private let backend: DictationBackend
    /// Callbacks of an older recognition run are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    init(backend: DictationBackend) {
        self.backend = backend
    }

    var phase: DictationPhase { machine.phase }
    var transcript: String { machine.transcript }
    var failure: DictationFailure? { machine.failure }
    var isListening: Bool { machine.isListening }
    var isBusy: Bool { machine.isBusy }

    /// The microphone button: start listening, or stop and keep the text.
    func toggle(voiceBusy: Bool) {
        handle(.tap(voiceBusy: voiceBusy))
    }

    /// Drop everything (text sent or panel gone).
    func cancel() {
        handle(.cancel)
    }

    func dismissFailure() {
        handle(.dismissFailure)
    }

    private func handle(_ event: DictationMachine.Event) {
        for effect in machine.send(event) {
            run(effect)
        }
        if machine.phase != .finishing {
            timeoutTask?.cancel()
            timeoutTask = nil
        }
    }

    private func run(_ effect: DictationMachine.Effect) {
        switch effect {
        case .requestPermission:
            generation += 1
            let current = generation
            Task { [weak self] in
                guard let self else { return }
                let permission = await backend.requestPermission()
                guard current == generation else { return }
                handle(.permission(permission))
            }
        case .startRecognition:
            let current = generation
            backend.start(
                onUpdate: { [weak self] text in
                    guard let self, current == generation else { return }
                    handle(.update(text))
                },
                onEnd: { [weak self] failure in
                    guard let self, current == generation else { return }
                    handle(.ended(failure))
                }
            )
        case .finishRecognition:
            backend.finish()
            let current = generation
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: finishTimeout)
                guard !Task.isCancelled, current == generation, machine.phase == .finishing else { return }
                backend.cancel()
                handle(.ended(nil))
            }
        case .cancelRecognition:
            generation += 1
            backend.cancel()
        }
    }
}

/// How the composer joins what was typed before listening with the
/// transcript.
enum DictationText {
    static func joined(base: String, transcript: String) -> String {
        guard !transcript.isEmpty else { return base }
        guard !base.isEmpty else { return transcript }
        let separator = base.last?.isWhitespace == true ? "" : " "
        return base + separator + transcript
    }
}

/// Which backend the composer uses.
enum DictationBackends {
    @MainActor static func make() -> DictationBackend {
        #if DEBUG
        // UI tests and screenshots cannot speak: `-dc-dictation-script "text"`
        // plays that text, `-dc-dictation-deny microphone|speech` answers the
        // permission with a denial.
        if AssistantDebug.has("-dc-dictation-script") || AssistantDebug.has("-dc-dictation-deny") {
            let deny: DictationPermission? = switch AssistantDebug.value("-dc-dictation-deny") {
            case "microphone": .microphoneDenied
            case "speech": .speechDenied
            default: nil
            }
            return ScriptedDictationBackend(
                words: (AssistantDebug.value("-dc-dictation-script") ?? "").split(separator: " ").map(String.init),
                permission: deny ?? .granted
            )
        }
        #endif
        return SystemDictationBackend()
    }
}

#if DEBUG
/// Plays a script word by word, as a recognizer would. Used by unit and UI
/// tests and by `-dc-dictation-script`.
@MainActor
final class ScriptedDictationBackend: DictationBackend {
    var words: [String]
    var permission: DictationPermission
    /// Pause between words; tests set it to zero and drive `step()` instead.
    var interval: Duration
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    private var onUpdate: (@MainActor (String) -> Void)?
    private var onEnd: (@MainActor (DictationFailure?) -> Void)?
    private var spoken = 0
    private var player: Task<Void, Never>?

    init(words: [String], permission: DictationPermission = .granted, interval: Duration = .milliseconds(350)) {
        self.words = words
        self.permission = permission
        self.interval = interval
    }

    func requestPermission() async -> DictationPermission { permission }

    func start(onUpdate: @escaping @MainActor (String) -> Void, onEnd: @escaping @MainActor (DictationFailure?) -> Void) {
        startCount += 1
        self.onUpdate = onUpdate
        self.onEnd = onEnd
        spoken = 0
        guard interval > .zero else { return }
        player = Task { [weak self] in
            while let self, !Task.isCancelled, spoken < words.count {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                step()
            }
        }
    }

    /// Speaks the next word.
    func step() {
        guard spoken < words.count else { return }
        spoken += 1
        onUpdate?(words.prefix(spoken).joined(separator: " "))
    }

    /// The recognizer gives up or ends by itself.
    func end(_ failure: DictationFailure?) {
        player?.cancel()
        onEnd?(failure)
    }

    func finish() {
        finishCount += 1
        player?.cancel()
        // The last words arrive, then recognition ends.
        onEnd?(nil)
    }

    func cancel() {
        cancelCount += 1
        player?.cancel()
    }
}
#endif
