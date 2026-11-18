import SwiftUI

/// The Agent panel's sticky footer: the status line, the suggestion row, the dictation
/// notice, the composer and the run-limit notice. It owns the draft, the focus, dictation
/// and the "Done" hold, so a keystroke re-renders this view and nothing around it
/// (design-performance-and-state.md, cause 2). The panel reaches the box through
/// `ComposerDrafts.perform`.
struct AssistantFooter: View {
    let app: AppModel
    @ObservedObject var drafts: ComposerDrafts
    @ObservedObject var voice: VoiceController
    private var session: BrowserAgentSession { app.browserAgent }
    let suggestions: [PageSuggestion]
    let isKeyboardVisible: Bool
    /// The panel's header folds the status line away while the box is focused.
    let onFocusChange: (Bool) -> Void
    let onSuggestion: (PageSuggestion) -> Void
    /// Provider and run-limit checks, then the send.
    let onSend: (_ prompt: String, _ attachedBlock: String?) -> ComposerSendOutcome

    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    /// The composer's microphone: speech to text in `draft`, nothing else.
    @State private var dictation = DictationController(backend: DictationBackends.make())
    /// What was typed when dictation began; the transcript is added after it.
    /// Nil when no dictation owns the draft.
    @State private var dictationBase: String?
    /// Dictation paused the podcast and owes it a resume.
    @State private var dictationSuspendedPodcast = false
    /// The draft as dictation last wrote it; typing makes it differ.
    @State private var dictatedDraft = ""
    @State private var showsCompletedStatus = false
    @State private var completedStatusTask: Task<Void, Never>?
    @State private var observedAgentID: ObjectIdentifier?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.composerBottomInset) private var bottomInset

    private var isBrowserAgentCompleted: Bool {
        if case .completed = session.runState { return true }
        return false
    }

    private var showsFooterStatusLine: Bool {
        (session.isRunning && !(isKeyboardVisible && composerFocused))
            || (showsCompletedStatus && isBrowserAgentCompleted)
    }

    /// While the box is empty and the Agent is idle; it hides once you type.
    private var showsSuggestionRow: Bool {
        draft.isEmpty && !session.isRunning && !suggestions.isEmpty
    }

    var body: some View {
        let _ = PerfProbe.hit("AssistantFooter.body")
        VStack(alignment: .leading, spacing: DCTheme.space2) {
            if showsFooterStatusLine {
                AgentStatusLine(
                    session: session,
                    developerMode: app.settings.agentDeveloperMode
                )
                .transition(.opacity)
            }

            if showsSuggestionRow {
                SuggestionRowView(suggestions: suggestions, onTap: onSuggestion)
                    .transition(.opacity)
            }

            if let failure = dictation.failure {
                DictationNotice(failure: failure) { dictation.dismissFailure() }
                    .transition(.opacity)
            }

            AssistantComposer(
                draft: $draft,
                focused: $composerFocused,
                isRunning: session.isRunning,
                onSend: { send(draft) },
                onStop: { session.stop() },
                isListening: dictation.isBusy,
                onDictate: startDictation,
                onStopDictation: { dictation.toggle(voiceBusy: false) },
                canTalk: app.voiceProvider != nil,
                isTalking: voice.isActive,
                onTalk: { voice.toggle() }
            )

            if let runLimitNotice = session.runLimitNotice {
                Text(runLimitNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
                    .accessibilityIdentifier("agentRunLimitNotice")
            }
        }
        .onChange(of: dictation.transcript) { applyDictation() }
        .onChange(of: dictation.phase) { _, phase in
            if phase == .idle {
                // Last words, then the draft is the user's again.
                applyDictation()
                dictationBase = nil
                resumePodcastAfterDictation()
            }
        }
        // A voice session takes the microphone: dictation steps aside.
        .onChange(of: voice.isActive) { _, active in
            if active { stopDictation(keepingText: false) }
        }
        .onChange(of: draft) { _, draft in
            // Typing while listening: the typed text wins, listening ends.
            if dictation.isListening, draft != dictatedDraft {
                dictationBase = nil
                dictation.toggle(voiceBusy: false)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopDictation(keepingText: true) }
        }
        .onChange(of: composerFocused) { _, focused in onFocusChange(focused) }
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: dictation.failure)
        // A question kept for later (Shortcuts, examples) lands in the composer.
        .onChange(of: drafts.goal, initial: true) { _, goal in
            guard !goal.isEmpty else { return }
            draft = goal
            drafts.goal = ""
        }
        .onChange(of: ObjectIdentifier(session)) { _, newID in
            observedAgentID = newID
            updateCompletedStatusVisibility(for: session.runState, isInitialAppear: true)
        }
        .onChange(of: session.runState) { _, newState in
            let currentID = ObjectIdentifier(session)
            let sameSession = observedAgentID == currentID
            observedAgentID = currentID
            updateCompletedStatusVisibility(for: newState, isInitialAppear: !sameSession)
        }
        .onAppear {
            draft = drafts.parked
            drafts.parked = ""
            drafts.handler = { perform($0) }
            observedAgentID = ObjectIdentifier(session)
            updateCompletedStatusVisibility(for: session.runState, isInitialAppear: true)
        }
        .onDisappear {
            completedStatusTask?.cancel()
            completedStatusTask = nil
            stopDictation(keepingText: true)
            // The microphone does not outlive the box.
            if dictation.isBusy || dictation.phase == .finishing { dictation.cancel() }
            dictationBase = nil
            resumePodcastAfterDictation()
            drafts.parked = draft
            drafts.handler = nil
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10 + (isKeyboardVisible ? 0 : bottomInset))
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: showsFooterStatusLine)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: showsSuggestionRow)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: session.runLimitNotice)
        .dcStickyFooter()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("askBox")
    }

    // MARK: Commands from the panel

    private func perform(_ command: ComposerCommand) {
        switch command {
        case .fill(let text):
            draft = text
            composerFocused = true
        case .focus:
            composerFocused = true
        case .blur:
            composerFocused = false
        case .clearAndBlur:
            draft = ""
            composerFocused = false
        case .stopDictation:
            stopDictation(keepingText: false)
        case .send(let text, let block):
            send(text, attachedBlock: block)
        }
    }

    /// Sends to the Agent: typed, suggested and completed "Search this forum…"
    /// all take this one path, with no hand-off context.
    private func send(_ text: String, attachedBlock: String? = nil) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !session.isRunning else { return }
        // Sending takes what is in the box; the microphone closes.
        stopDictation(keepingText: false)
        switch onSend(prompt, attachedBlock) {
        case .sent:
            draft = ""
            composerFocused = false
        case .needsProvider:
            composerFocused = false
        case .blocked:
            break
        }
    }

    // MARK: Dictation

    private func startDictation() {
        guard !dictation.isBusy else { return }
        composerFocused = false
        dictationBase = draft
        dictatedDraft = draft
        // Dictation takes the shared audio session: an episode pauses, like
        // for a voice session, and goes on afterwards.
        let podcast = app.podcast.player
        if !voice.isActive, !podcast.isSuspendedForVoice {
            podcast.suspendForVoice()
            dictationSuspendedPodcast = true
        }
        dictation.toggle(voiceBusy: voice.isActive)
        // Nothing started (voice busy): no draft to own.
        if dictation.phase == .idle {
            dictationBase = nil
            resumePodcastAfterDictation()
        }
    }

    private func resumePodcastAfterDictation() {
        guard dictationSuspendedPodcast else { return }
        dictationSuspendedPodcast = false
        let player = app.podcast.player
        Task { await player.resumeAfterVoice() }
    }

    private func applyDictation() {
        guard let base = dictationBase, !dictation.transcript.isEmpty else { return }
        let text = DictationText.joined(base: base, transcript: dictation.transcript)
        dictatedDraft = text
        draft = text
    }

    /// Ends dictation. Words already heard stay in the box when asked to.
    private func stopDictation(keepingText: Bool) {
        guard dictation.isBusy || dictation.phase == .finishing else { return }
        if keepingText {
            if dictation.isListening {
                dictation.toggle(voiceBusy: false)
            } else {
                dictation.cancel()
                dictationBase = nil
            }
        } else {
            dictationBase = nil
            dictation.cancel()
        }
    }

    // MARK: The "Done" hold

    private static var completedStatusHoldDuration: Double {
        #if DEBUG
        if AssistantDebug.has("-dc-browser-agent-live-prompt")
            || AssistantDebug.value("-dc-browser-agent-live-prompt") != nil
            || AssistantDebug.has("-dc-browser-agent-live-key")
            || AssistantDebug.value("-dc-browser-agent-live-key") != nil
            || AssistantDebug.has("-dc-browser-agent-demo")
            || AssistantDebug.value("-dc-browser-agent-demo") != nil {
            return 8.0
        }
        #endif
        return 3.5
    }

    private func updateCompletedStatusVisibility(for state: BrowserAgentRunState, isInitialAppear: Bool) {
        completedStatusTask?.cancel()
        completedStatusTask = nil
        guard case .completed = state else {
            showsCompletedStatus = false
            return
        }
        let holdDuration = Self.completedStatusHoldDuration
        if isInitialAppear {
            var remaining = holdDuration
            var shouldShow = false
            #if DEBUG
            if AssistantDebug.has("-dc-browser-agent-demo") || AssistantDebug.value("-dc-browser-agent-demo") != nil {
                shouldShow = true
            }
            #endif
            if !shouldShow, let lastRun = session.runs.last {
                let endedAt = lastRun.startedAt.addingTimeInterval(lastRun.duration ?? 0)
                let elapsed = Date().timeIntervalSince(endedAt)
                if elapsed >= 0, elapsed < holdDuration {
                    shouldShow = true
                    remaining = max(0.5, holdDuration - elapsed)
                }
            }
            guard shouldShow else {
                showsCompletedStatus = false
                return
            }
            showsCompletedStatus = true
            scheduleCompletedStatusDismiss(after: remaining)
        } else {
            showsCompletedStatus = true
            scheduleCompletedStatusDismiss(after: holdDuration)
        }
    }

    private func scheduleCompletedStatusDismiss(after seconds: Double) {
        completedStatusTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.quick)) {
                showsCompletedStatus = false
            }
        }
    }
}
