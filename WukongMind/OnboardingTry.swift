import SwiftUI

// MARK: - First-run step 3: try the Agent once (design-unified.md §5)
//
// Runs in the real browser after steps 1 and 2 closed: the chosen page, the
// progress dots on top, and a panel from the bottom that is the shared Agent
// conversation (`AssistantPanel`, One panel) with the two first-run
// suggestions in its suggestion row. After a run (or Skip) the panel shows the
// "You're set" card with the cheer mascot. Without a model (step 1 said Later)
// the shared panel shows its own provider setup card.

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
        .onChange(of: app.router.wantsDrawer) {
            if app.firstRun != nil, app.router.wantsDrawer { app.router.closeDrawer() }
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
    @ObservedObject private var sync: CloudSyncController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(app: AppModel) {
        self.app = app
        _sync = ObservedObject(wrappedValue: app.cloudSync)
    }

    private var session: BrowserAgentSession { app.browserAgent }
    private var isDone: Bool { app.firstRun == .done }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            skipRow
            if isDone {
                ScrollView {
                    doneCard
                        .padding(.horizontal, DCTheme.spacingL)
                        .padding(.top, DCTheme.spacingS)
                        .padding(.bottom, DCTheme.spacingL)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                // The same conversation view as the drawer; first run swaps
                // its suggestions for the two below.
                AssistantPanel(app: app, onExpand: { _ in })
            }
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
        dynamicTypeSize.isAccessibilitySize ? 560 : (isDone ? 300 : 480)
    }

    // MARK: Chrome

    private var grabber: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(DCTheme.inkFaint.opacity(0.5))
            .frame(width: 36, height: 5)
            .padding(.top, 6)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var skipRow: some View {
        if !isDone {
            HStack {
                Spacer(minLength: 0)
                Button {
                    DCHaptics.tap()
                    app.firstRun = .done
                } label: {
                    Text("Skip", comment: "First-run step 3: skip trying the Agent")
                }
                .buttonStyle(DCButtonStyle(role: .quiet))
                .accessibilityIdentifier("onboardingTrySkip")
            }
            .padding(.trailing, DCTheme.spacingS)
        }
    }

    /// A run that completed ends the first run; any other ending is said in
    /// the conversation and leaves the suggestions to try again.
    private func finished(_ state: BrowserAgentRunState) {
        if case .completed = state, app.firstRun == .prompts {
            DCHaptics.success()
            app.firstRun = .done
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
        .accessibilityElement(children: .contain)
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
