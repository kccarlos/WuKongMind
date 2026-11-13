import SwiftUI

// MARK: - First-run step 3: try the Agent once (design-unified.md §5)
//
// Runs in the real browser after steps 1 and 2 closed: the chosen page, the
// progress dots on top, and a panel from the bottom with two suggestions and
// the input box. After a run (or Skip) the panel shows the "You're set" card
// with the cheer mascot. Without a model (step 1 said Later) it shows the
// no-model card instead of the suggestions. The panel is drawn here, from the
// design system, so the first run doesn't depend on the conversation panel's
// states; a suggestion sends its text to the same Agent a typed question does.

/// Shows step 3 over the browser while `AppModel.firstRun` is set.
struct FirstRunHost: ViewModifier {
    @ObservedObject var app: AppModel

    func body(content: Content) -> some View {
        content.overlay {
            if app.firstRun != nil {
                ZStack(alignment: .bottom) {
                    OnboardingProgressDots(current: .tryAgent)
                        .padding(.top, DCTheme.spacingXS)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                    OnboardingTryPanel(app: app)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboardingTry")
            }
        }
        // The first run owns the bottom of the screen: no drawer under it.
        .onChange(of: app.firstRun, initial: true) {
            if app.firstRun != nil { app.router.closeDrawer() }
        }
    }
}

extension View {
    /// Step 3 of the first run, over the browser.
    func firstRunHost(app: AppModel) -> some View {
        modifier(FirstRunHost(app: app))
    }
}

struct OnboardingTryPanel: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var browser: ForumBrowserModel
    @ObservedObject private var sync: CloudSyncController
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(app: AppModel) {
        self.app = app
        _browser = ObservedObject(wrappedValue: app.browser)
        _sync = ObservedObject(wrappedValue: app.cloudSync)
    }

    private var session: BrowserAgentSession { app.browserAgent }
    private var isDone: Bool { app.firstRun == .done }
    private var hasModel: Bool { app.isBrowserAgentReady }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                    if isDone {
                        doneCard
                    } else if !hasModel {
                        noModelCard
                    } else {
                        prompts
                    }
                }
                .padding(.horizontal, DCTheme.spacingL)
                .padding(.top, DCTheme.spacingS)
                .padding(.bottom, DCTheme.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            if hasModel, !isDone { composer }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .frame(height: panelHeight)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: DCTheme.radiusSheet, topTrailingRadius: DCTheme.radiusSheet, style: .continuous)
                .fill(DCTheme.surface)
                .shadow(color: .black.opacity(0.16), radius: 30, y: -8)
                .ignoresSafeArea(edges: .bottom)
        )
        .onChange(of: session.runState) { _, state in finished(state) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboardingTryPanel")
    }

    /// About half the window, so the page above it stays in view.
    private var panelHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 560 : (isDone ? 300 : 420)
    }

    // MARK: Chrome

    private var grabber: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(DCTheme.inkFaint.opacity(0.5))
            .frame(width: 36, height: 5)
            .padding(.top, 6)
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: DCTheme.spacingS) {
            Text("Agent", comment: "Title of the Agent panel")
                .font(.headline)
                .foregroundStyle(DCTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if !isDone {
                Button {
                    DCHaptics.tap()
                    focused = false
                    app.firstRun = .done
                } label: {
                    Text("Skip", comment: "First-run step 3: skip trying the Agent")
                }
                .buttonStyle(DCButtonStyle(role: .quiet))
                .accessibilityIdentifier("onboardingTrySkip")
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, DCTheme.spacingS)
        .frame(minHeight: DCTheme.controlHeight)
    }

    // MARK: Prompts

    @ViewBuilder
    private var prompts: some View {
        Text("Try the Agent once", comment: "First-run step 3 title")
            .font(.title2.weight(.bold))
            .foregroundStyle(DCTheme.ink)
            .accessibilityAddTraits(.isHeader)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AppModel.firstRunSuggestions, id: \.self) { suggestion in
                Button {
                    DCHaptics.tap()
                    send(suggestion)
                } label: {
                    Text(suggestion)
                        .font(.body)
                        .foregroundStyle(DCTheme.ink)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, DCTheme.spacingM)
                        .frame(minHeight: DCTheme.controlHeight, alignment: .leading)
                        .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
                                .strokeBorder(DCTheme.borderStrong, lineWidth: DCTheme.hairlineWidth)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning)
                .accessibilityIdentifier("onboardingSuggestion-\(suggestion.prefix(8))")
            }
        }
        status
    }

    /// The run's progress: the turning ring while it works, and a sentence if
    /// it could not finish (failures are said, not shown).
    @ViewBuilder
    private var status: some View {
        switch session.runState {
        case .running:
            HStack(spacing: DCTheme.spacingM) {
                DCAgentRing(size: 28, lineWidth: DCTheme.ringWidth, isTurning: true)
                Text("Working on it…", comment: "First-run step 3: the Agent is working")
                    .font(.subheadline)
                    .foregroundStyle(DCTheme.inkMuted)
                Spacer(minLength: 0)
                Button {
                    DCHaptics.tap()
                    session.stop()
                } label: {
                    Text("Stop", comment: "Button: stop the Agent")
                }
                .buttonStyle(DCButtonStyle(role: .destructive))
                .accessibilityIdentifier("onboardingTryStop")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onboardingTryWorking")
        case .failed(let message):
            problem(message)
        case .stepLimitReached:
            problem(String(localized: "That took more steps than allowed. Try something smaller.", comment: "First-run step 3: the Agent hit its step limit"))
        case .stopped:
            problem(String(localized: "Stopped.", comment: "First-run step 3: the user stopped the Agent"))
        default:
            EmptyView()
        }
    }

    private func problem(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(DCTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(DCTheme.danger)
        }
        .accessibilityIdentifier("onboardingTryProblem")
    }

    // MARK: Input box

    private var composer: some View {
        HStack(spacing: DCTheme.spacingS) {
            TextField(
                "",
                text: $draft,
                prompt: Text("Ask anything about this page…", comment: "Placeholder of the Agent's input box").foregroundStyle(DCTheme.inkFaint),
                axis: .vertical
            )
            .lineLimit(1...4)
            .focused($focused)
            .submitLabel(.send)
            .onSubmit { sendDraft() }
            .foregroundStyle(DCTheme.ink)
            .padding(.horizontal, DCTheme.spacingM)
            .padding(.vertical, 10)
            .frame(minHeight: DCTheme.controlHeight)
            .background(DCTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
            .accessibilityIdentifier("onboardingTryField")
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(DCTheme.onGold)
                        .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                        .background(DCTheme.gold, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("onboardingTrySend")
            }
        }
        .padding(.horizontal, DCTheme.spacingL)
        .padding(.top, DCTheme.spacingS)
        .padding(.bottom, DCTheme.spacingS)
        .overlay(alignment: .top) { Rectangle().fill(DCTheme.hairline).frame(height: DCTheme.hairlineWidth) }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        focused = false
        send(text)
    }

    /// Sends the sentence to the Agent once the page has loaded.
    private func send(_ prompt: String) {
        guard !session.isRunning else { return }
        Task { @MainActor in
            var waited = 0
            while browser.isLoading, waited < 50 {
                try? await Task.sleep(for: .milliseconds(200))
                waited += 1
            }
            session.send(prompt)
        }
    }

    /// A run that completed ends the first run; any other ending is said in
    /// the panel and leaves the suggestions to try again.
    private func finished(_ state: BrowserAgentRunState) {
        if case .completed = state, app.firstRun == .prompts {
            DCHaptics.success()
            app.firstRun = .done
        }
    }

    // MARK: No model

    private var noModelCard: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            Text("Choose a model", comment: "First-run step 3 without a model: the title")
                .font(.title2.weight(.bold))
                .foregroundStyle(DCTheme.ink)
            Button {
                DCHaptics.tap()
                app.needsProviderSetup = .browserAgent
            } label: {
                Text("Choose a model", comment: "First-run step 3 without a model: the button")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DCButtonStyle(role: .primary, fullWidth: true))
            .accessibilityIdentifier("onboardingTryChooseModel")
        }
    }

    // MARK: You're set

    /// The cheer mascot, "You're set", what is on and where the rest lives, and Done.
    private var doneCard: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            if let answer = session.runs.last?.assistantText, !answer.isEmpty {
                Text(verbatim: answer)
                    .font(.subheadline)
                    .foregroundStyle(DCTheme.ink)
                    .lineLimit(6)
                    .accessibilityIdentifier("onboardingTryAnswer")
            }
            HStack(spacing: DCTheme.spacingM) {
                DCMascotView(pose: .cheer, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("You’re set", comment: "First-run step 3: the card after the first run")
                        .font(.headline)
                        .foregroundStyle(DCTheme.ink)
                    Text(setupSummary)
                        .font(.footnote)
                        .foregroundStyle(DCTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            Button {
                DCHaptics.success()
                app.firstRun = nil
            } label: {
                Text("Done", comment: "First-run step 3: close the first run")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DCButtonStyle(role: .primary, fullWidth: true))
            .accessibilityIdentifier("onboardingTryDone")
        }
        .padding(DCTheme.spacingM)
        .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous).strokeBorder(DCTheme.hairline)
        }
        .accessibilityIdentifier("onboardingTryDoneCard")
    }

    /// "iCloud sync: On · Daily digest: in Settings".
    private var setupSummary: String {
        let syncOn = SyncDebug.isEnabled(actual: sync.isEnabled)
        let syncText = syncOn
            ? String(localized: "iCloud sync: On", comment: "First-run \"You're set\" card: iCloud sync is on")
            : String(localized: "iCloud sync: Off", comment: "First-run \"You're set\" card: iCloud sync is off")
        let digest = String(localized: "Daily digest: in Settings", comment: "First-run \"You're set\" card: where to turn on the daily digest")
        return "\(syncText) · \(digest)"
    }
}
