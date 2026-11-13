import Combine
import Foundation

/// Starts and ends voice sessions for the UI: the browser bar's microphone
/// and the voice bar. AppModel owns one; the session itself is in `VoiceSession`.
@MainActor
final class VoiceController: ObservableObject {
    /// The running session, or the last one while its bar still shows
    /// how it ended.
    @Published private(set) var session: VoiceSession?
    /// Why a session couldn't start (no key, voice off), shown in the bar.
    @Published private(set) var startFailure: VoiceSession.Failure?
    /// Called once a session is over or a session couldn't start (the
    /// podcast's "Ask about this" resumes then).
    var onFinished: (() -> Void)?
    #if DEBUG
    /// Unit tests: uses `SilentVoiceAudio` and `ScriptedLiveTransport`.
    var useScriptedSession = false
    #endif

    private weak var app: AppModel?
    /// The device's audio; made on the first session (it asks for the
    /// microphone then, not at launch).
    private var engine: VoiceAudioIO?
    private var stateSubscription: AnyCancellable?
    private var lastStartedAt: ContinuousClock.Instant?

    init(app: AppModel) {
        self.app = app
    }

    /// The bar is up: a session, or a failure to show.
    var showsBar: Bool { session != nil || startFailure != nil }

    var isActive: Bool { session.map { !$0.state.isOver } ?? false }

    /// Status line while a failed start or ended session stays up (`showsBar && !isActive`).
    var inactiveBarMessage: String? {
        if let failure = startFailure { return failure.message }
        guard let session, session.state.isOver else { return nil }
        return VoiceSessionBar.stateText(session)
    }

    var inactiveBarIsWarning: Bool {
        if startFailure != nil { return true }
        if case .failed? = session?.state { return true }
        return false
    }

    /// The audio engine, when it is the real one (for the Health row).
    var audioEngine: VoiceAudioEngine? { engine as? VoiceAudioEngine }

    // MARK: Actions

    /// The microphone in the browser bar: start, or end a running session.
    func toggle() {
        if let session, isActive {
            if !session.state.isActive,
               let lastStartedAt,
               ContinuousClock.now - lastStartedAt < .milliseconds(400) {
                return
            }
            session.stop()
        } else {
            start()
        }
    }

    func start() {
        guard let app, !isActive else { return }
        startFailure = nil
        guard app.voiceProvider != nil else {
            show(.noKey)
            return
        }
        // Tapping the microphone is asking for voice.
        if !app.settings.voiceEnabled { app.settings.voiceEnabled = true }
        let audio = makeAudio()
        let result: Result<VoiceSession, VoiceSession.Failure>
        #if DEBUG
        if VoiceDebug.isFake || useScriptedSession {
            result = app.makeVoiceSession(audio: audio, transport: { ScriptedLiveTransport() })
        } else {
            result = app.makeVoiceSession(audio: audio)
        }
        #else
        result = app.makeVoiceSession(audio: audio)
        #endif
        switch result {
        case .failure(let failure):
            show(failure)
        case .success(let session):
            self.session = session
            lastStartedAt = ContinuousClock.now
            stateSubscription = session.$state.sink { [weak self] state in
                if state.isOver { self?.sessionEnded() }
            }
            audioEngine?.onStopped = { [weak session] _ in session?.audioFailed() }
            Task { await session.start() }
        }
    }

    func end() {
        session?.stop()
    }

    /// Closes the bar of a session that is over.
    func dismiss() {
        guard !isActive else { return }
        session = nil
        startFailure = nil
        stateSubscription = nil
    }

    // MARK: Private

    private func makeAudio() -> VoiceAudioIO {
        if let engine { return engine }
        let audio: VoiceAudioIO
        #if DEBUG
        audio = (VoiceDebug.isFake || useScriptedSession) ? SilentVoiceAudio() : VoiceAudioEngine()
        #else
        audio = VoiceAudioEngine()
        #endif
        engine = audio
        return audio
    }

    private func show(_ failure: VoiceSession.Failure) {
        session = nil
        startFailure = failure
        finished()
    }

    private func sessionEnded() {
        // `isActive` follows the session's state, which this object doesn't
        // publish: views that only observe the controller (the drawer's
        // status row) look again.
        objectWillChange.send()
        app?.voiceSessionEnded()
        finished()
    }

    private func finished() {
        let callback = onFinished
        onFinished = nil
        callback?()
    }
}
