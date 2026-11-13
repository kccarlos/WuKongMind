import SwiftUI

// MARK: - Unified Ask box (§5)
//
// One field at the bottom of the AI drawer. The scope button on its left
// picks *This topic* (the topic's chat: assistant model, forum context
// limit) or *Whole forum* (Ask the forum: an agent run on the forum picked
// in the same menu). The scope is `assistantMode` (`.agent` is Whole forum),
// so the model pill, the shared links and the App Intents that set the mode
// keep working. The box edits one of the three existing drafts and carries
// the typed text along when the scope (or the run it follows up) changes.

enum AskScope: String {
    case topic, forum
}

/// The draft the Ask box edits.
enum AskDraftTarget {
    /// This topic: `ComposerDrafts.chat`.
    case chat
    /// Whole forum, a new run: `ComposerDrafts.goal`.
    case goal
    /// Whole forum, a follow-up to the selected finished run: `ComposerDrafts.followUp`.
    case followUp
}

/// Example questions for Ask the forum; sent to the model as the user's
/// question, so they are in the app's language (the answer follows the
/// question's language).
enum AgentExamples {
    static var questions: [String] {
        [
            String(localized: "What are people discussing this week?", comment: "Example question for the forum research agent"),
            String(localized: "Most helpful answers about getting started", comment: "Example question for the forum research agent"),
            String(localized: "Common problems people report lately", comment: "Example question for the forum research agent")
        ]
    }
}

extension AppModel {
    var askScope: AskScope { assistantMode == .agent ? .forum : .topic }

    /// The finished run the box follows up, unless a new question is being
    /// written.
    var askFollowUpRun: AgentRun? {
        guard askScope == .forum, !agentComposesNewQuestion,
              let run = selectedAgentRun, run.isFinished else { return nil }
        return run
    }

    /// The selected run is still working: the box waits for it (as the old
    /// goal box did), or a new question can be started instead.
    var askWaitsForRun: Bool {
        guard askScope == .forum, !agentComposesNewQuestion, let run = selectedAgentRun else { return false }
        return !run.isFinished
    }

    /// Whole forum shows its empty state: examples and recent runs.
    var asksNewForumQuestion: Bool {
        agentComposesNewQuestion || agentRuns.isEmpty
    }

    /// The draft the box shows. Typed text stays in front: a run finishing
    /// or another run being selected never swaps it for the other, empty
    /// Whole forum draft (the scope and question buttons move it along,
    /// `carryingAskText`).
    var askDraftTarget: AskDraftTarget {
        let wanted = askWantedDraftTarget
        guard askScope == .forum, !asksNewForumQuestion else { return wanted }
        switch (drafts.goal.isEmpty, drafts.followUp.isEmpty) {
        case (false, true): return .goal
        case (true, false): return .followUp
        default: return wanted
        }
    }

    /// The draft the state asks for: the chat, a new question, or a
    /// follow-up to the selected finished run.
    private var askWantedDraftTarget: AskDraftTarget {
        switch askScope {
        case .topic: .chat
        case .forum: askFollowUpRun == nil ? .goal : .followUp
        }
    }

    var askDraft: String {
        get { drafts[keyPath: Self.draftKeyPath(askDraftTarget)] }
        set { drafts[keyPath: Self.draftKeyPath(askDraftTarget)] = newValue }
    }

    private static func draftKeyPath(_ target: AskDraftTarget) -> ReferenceWritableKeyPath<ComposerDrafts, String> {
        switch target {
        case .chat: \.chat
        case .goal: \.goal
        case .followUp: \.followUp
        }
    }

    /// This topic or Whole forum (on the forum chosen last).
    func setAskScope(_ scope: AskScope) {
        guard scope != askScope else { return }
        if scope == .forum || !agentComposesNewQuestion {
            router.answersSeenAt = Date()
        }
        carryingAskText {
            assistantMode = scope == .forum ? .agent : .chat
        }
    }

    /// Whole forum on `siteURL` (nil: the page's forum). A selected run on
    /// another forum gives way to a new question.
    func chooseAskForum(siteURL: String?) {
        carryingAskText {
            agentSiteURL = siteURL
            assistantMode = .agent
            if let run = selectedAgentRun, run.siteURL != agentForum?.siteURL {
                agentComposesNewQuestion = true
            }
        }
    }

    /// Whole forum: write a new question instead of a follow-up.
    func startNewAgentQuestion() {
        carryingAskText { agentComposesNewQuestion = true }
    }

    /// Back to the selected run from a new question.
    func showSelectedAgentRun() {
        carryingAskText {
            assistantMode = .agent
            agentComposesNewQuestion = false
        }
    }

    func applyChatSuggestion(_ question: String) {
        if activeChatEdit != nil {
            cancelEditChat()
        }
        drafts.chat = question
    }

    /// Runs `change`; when it moves the box to another draft, the typed text
    /// moves along (unless the other draft already has text of its own).
    private func carryingAskText(_ change: () -> Void) {
        let from = askDraftTarget
        change()
        let to = askWantedDraftTarget
        guard from != to else { return }
        let source = Self.draftKeyPath(from)
        let destination = Self.draftKeyPath(to)
        guard !drafts[keyPath: source].isEmpty, drafts[keyPath: destination].isEmpty else {
            if from == .chat, to != .chat {
                cancelEditChat()
            }
            return
        }
        if from == .chat, to != .chat {
            abandonEditChatWithoutRestoringDraft()
        }
        drafts[keyPath: destination] = drafts[keyPath: source]
        drafts[keyPath: source] = ""
    }

    var canSendAsk: Bool {
        let text = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        switch askDraftTarget {
        case .chat:
            guard let topicKey = currentTopic?.topicKey else { return false }
            return activeChatEdit != nil || !hasActiveWork(topicKey: topicKey, type: .chat)
        case .goal:
            return !askWaitsForRun && agentForum != nil
        case .followUp:
            // Kept while the selected run is still working; sent once it ends.
            return askFollowUpRun != nil
        }
    }

    /// Sends the box: a chat question, a new agent run on the chosen forum,
    /// or a follow-up to the selected run.
    func sendAsk() {
        guard canSendAsk else { return }
        switch askDraftTarget {
        case .chat:
            sendChat()
        case .goal:
            startAgentRun(goal: drafts.goal, siteURL: agentForum?.siteURL)
        case .followUp:
            if let run = askFollowUpRun { continueAgentRun(id: run.id, question: drafts.followUp) }
        }
    }
}

extension EnvironmentValues {
    @Entry var composerBottomInset: CGFloat = 0
}

enum AskBox {
    /// Kept for legacy `AppModel.applyChatSuggestion` engine tests until One loop.
    static var suggestions: [(String, String)] {
        [
            (
                String(localized: "Key takeaways", comment: "Chat suggestion chip"),
                String(localized: "What are the key takeaways?", comment: "Chat question filled in by the Key takeaways chip")
            ),
            (
                String(localized: "Warnings", comment: "Chat suggestion chip"),
                String(localized: "Are there any warnings or important caveats?", comment: "Chat question filled in by the Warnings chip")
            ),
            (
                String(localized: "Latest replies", comment: "Chat suggestion chip"),
                String(localized: "What do the latest replies add?", comment: "Chat question filled in by the Latest replies chip")
            ),
            (
                String(localized: "Disagreements", comment: "Chat suggestion chip"),
                String(localized: "Where do people disagree, and why?", comment: "Chat question filled in by the Disagreements chip")
            )
        ]
    }
}

/// The unified WukongMind composer (`design-system/components/Composer`):
/// one rounded-rectangle field (`DCTheme.surface`, `radiusMd`, `borderStrong`)
/// and one 44 pt round button (open gold ring + `mic.fill` to dictate when
/// empty, filled gold + `arrow.up` to send, filled cinnabar + `stop.fill` to stop).
struct AssistantComposer: View {
    @Binding var draft: String
    @FocusState.Binding var focused: Bool
    let isRunning: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    /// Dictation is listening: the ring is cinnabar with a stop square, and
    /// the field says so.
    var isListening = false
    var onDictate: () -> Void = {}
    var onStopDictation: () -> Void = {}
    @Environment(\.composerFocusChanged) private var composerFocusChanged
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var listeningPulse = false

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var placeholder: String {
        if isListening {
            return String(localized: "Listening…", comment: "Composer placeholder while the microphone is dictating")
        }
        if isRunning {
            return String(localized: "Write your next message…", comment: "Browser agent composer placeholder while a run is in progress")
        }
        return String(localized: "Ask the Agent…", comment: "Unified Agent panel composer placeholder")
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: DCTheme.space2) {
            inputField
            trailingRingButton
        }
    }

    private var inputField: some View {
        TextField(text: $draft, prompt: Text(verbatim: ""), axis: .vertical) {
            Text(verbatim: placeholder)
        }
        .font(.subheadline)
        .foregroundStyle(DCTheme.ink)
        .lineLimit(1...5)
        .padding(.horizontal, DCTheme.space3)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight, alignment: .leading)
        .background(alignment: .topLeading) {
            if draft.isEmpty {
                Text(verbatim: placeholder)
                    .font(.subheadline)
                    .foregroundStyle(DCTheme.inkFaint)
                    .lineLimit(1)
                    .padding(.horizontal, DCTheme.space3)
                    .padding(.vertical, 11)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(
            DCTheme.surface,
            in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
                .strokeBorder(isListening ? DCTheme.cinnabar : DCTheme.borderStrong, lineWidth: isListening ? DCTheme.ringWidth : 1)
        }
        .dcFocusRing(focused, cornerRadius: DCTheme.radiusMd)
        .focused($focused)
        .submitLabel(.send)
        .onChange(of: focused) {
            composerFocusChanged(focused)
        }
        .onChange(of: draft) { oldValue, newValue in
            guard focused,
                  !isRunning,
                  newValue.count == oldValue.count + 1,
                  newValue.filter({ $0 == "\n" }).count == oldValue.filter({ $0 == "\n" }).count + 1
            else { return }
            draft = oldValue
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onSend()
            }
        }
        .onSubmit {
            if !isRunning, !trimmedDraft.isEmpty {
                onSend()
            }
        }
        .background {
            if focused {
                Button { focused = false } label: { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        #if DEBUG
        .task {
            if AssistantDebug.has("-dc-focus-chat") {
                try? await Task.sleep(for: .milliseconds(900))
                focused = true
            }
        }
        #endif
        .accessibilityIdentifier("agentPromptInput")
    }

    @ViewBuilder
    private var trailingRingButton: some View {
        if isRunning {
            Button {
                DCHaptics.tap()
                onStop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DCTheme.onCinnabar)
                    .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                    .background(DCTheme.cinnabar, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityLabel(Text("Stop", comment: "Browser agent stop button title"))
            .accessibilityIdentifier("agentStopButton")
        } else if isListening {
            Button {
                DCHaptics.tap()
                onStopDictation()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DCTheme.onCinnabar)
                    .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                    .background(DCTheme.cinnabar, in: Circle())
                    .overlay {
                        // A breathing halo says the microphone is open.
                        Circle()
                            .strokeBorder(DCTheme.cinnabar.opacity(listeningPulse ? 0 : 0.5), lineWidth: DCTheme.ringWidth)
                            .scaleEffect(listeningPulse ? 1.35 : 1)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(Text("Stop dictating", comment: "Composer button label while the microphone is dictating"))
            .accessibilityIdentifier("composerMicStop")
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    listeningPulse = true
                }
            }
            .onDisappear { listeningPulse = false }
        } else if !trimmedDraft.isEmpty {
            Button {
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(DCTheme.onGold)
                    .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                    .background(DCTheme.gold, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .dcSendShortcut()
            .accessibilityLabel(Text("Send", comment: "Browser agent send button accessibility label"))
            .accessibilityIdentifier("agentSendButton")
        } else {
            Button {
                DCHaptics.tap()
                onDictate()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DCTheme.goldInk)
                    .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                    .background(Color.clear, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(DCTheme.gold, lineWidth: DCTheme.ringWidth)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(Text("Dictate", comment: "Composer microphone button accessibility label in One panel"))
            .accessibilityIdentifier("composerMic")
        }
    }
}

/// Says why dictation did not work, in one short sentence above the
/// composer; a permission problem gets a link to Settings.
struct DictationNotice: View {
    let failure: DictationFailure
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DCTheme.space2) {
            Image(systemName: "mic.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DCTheme.cinnabar)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DCTheme.space1) {
                Text(verbatim: failure.message)
                    .font(.footnote)
                    .foregroundStyle(DCTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dictationNoticeText")
                if failure.offersSettings {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Text("Open Settings", comment: "Link in the dictation notice that opens the iOS Settings app")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DCTheme.goldInk)
                    }
                    .accessibilityIdentifier("dictationOpenSettings")
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DCTheme.inkFaint)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Dismiss", comment: "Dictation notice close button"))
            .accessibilityIdentifier("dictationNoticeDismiss")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictationNotice")
    }
}
