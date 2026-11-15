import SwiftUI

extension EnvironmentValues {
    @Entry var composerBottomInset: CGFloat = 0
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
    /// A Gemini or Vertex key is set: tapping the mic opens the voice
    /// session, long-press still dictates (design-one-loop.md "Voice").
    var canTalk = false
    /// A voice session is on: the button ends it.
    var isTalking = false
    var onTalk: () -> Void = {}
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
            // Footer transitions (suggestions/status appearing when a run ends)
            // animate the parent VStack; switch the placeholder without cross-fading
            // the running prompt over the idle one.
            Group {
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
            .transaction { $0.animation = nil }
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
        } else if isTalking {
            Button {
                DCHaptics.tap()
                onTalk()
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(DCTheme.onGold)
                    .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                    .background(DCTheme.gold, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(Text("End voice", comment: "Composer button label while a voice session is on; tapping ends it"))
            .accessibilityIdentifier("composerVoiceEnd")
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
            // Tap talks (with a voice key) or dictates; long-press always dictates.
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
                .hoverEffect(.highlight)
                .onTapGesture {
                    DCHaptics.tap()
                    if canTalk { onTalk() } else { onDictate() }
                }
                .onLongPressGesture(minimumDuration: 0.45) {
                    DCHaptics.tap()
                    onDictate()
                }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(canTalk
                    ? Text("Talk", comment: "Composer microphone button accessibility label when tapping opens a voice conversation")
                    : Text("Dictate", comment: "Composer microphone button accessibility label in One panel"))
                .accessibilityHint(canTalk ? Text("Touch and hold to dictate instead", comment: "Accessibility hint of the composer microphone when voice is set up") : Text(verbatim: ""))
                .accessibilityAction { if canTalk { onTalk() } else { onDictate() } }
                .accessibilityActions {
                    if canTalk {
                        Button(String(localized: "Dictate", comment: "Composer microphone button accessibility label in One panel")) { onDictate() }
                    }
                }
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
