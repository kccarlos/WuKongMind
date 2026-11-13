import SwiftUI

/// Replays the walkthrough (Settings › Help). Set by `WukongMindApp`.
struct ReplayOnboardingAction {
    var action: () -> Void = {}
    func callAsFunction() { action() }
}

private struct ReplayOnboardingKey: EnvironmentKey {
    static let defaultValue = ReplayOnboardingAction()
}

extension EnvironmentValues {
    var replayOnboarding: ReplayOnboardingAction {
        get { self[ReplayOnboardingKey.self] }
        set { self[ReplayOnboardingKey.self] = newValue }
    }
}

/// First-run steps 1 and 2 (design-unified.md §5): pick a model, open a site.
/// A full-screen cover on iPhone and a form sheet on iPad. Opening a site ends
/// it; step 3 then runs in the real browser (`OnboardingTryPanel`).
struct OnboardingFlow: View {
    @ObservedObject var app: AppModel
    /// Called after `completeOnboarding()`; the host dismisses the cover.
    var onFinish: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var step: OnboardingStep
    @State private var providerState: ProviderTestState = .idle
    @State private var address = ""
    @State private var selectedSiteURL: String? = OnboardingSitePage.suggestions.first?.siteURL
    @State private var keyboardVisible = false

    init(app: AppModel, initialStep: OnboardingStep = .model, onFinish: @escaping () -> Void = {}) {
        self.app = app
        self.onFinish = onFinish
        // Step 3 is not a page.
        _step = State(initialValue: initialStep.isPage ? initialStep : .site)
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding")
    }

    private var content: some View {
        VStack(spacing: 0) {
            OnboardingProgressDots(current: step)
                .padding(.top, usesCompactChrome ? DCTheme.spacingS : DCTheme.spacingL)
            page(for: step)
                .id(step)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The bar tucks away while typing so it never rides the keyboard
            // and covers the field being edited.
            if !keyboardVisible {
                bottomBar
            }
        }
        .dcKeyboardVisible($keyboardVisible)
    }

    // MARK: Chrome

    private var usesCompactChrome: Bool {
        verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
    }

    private var bottomBar: some View {
        Group {
            switch step {
            case .model:
                actions(
                    primary: primaryButton(
                        title: String(localized: "Continue"),
                        isBusy: providerState == .testing,
                        id: "onboardingContinue",
                        action: continueFromModel
                    ),
                    quiet: quietButton(title: String(localized: "Later", comment: "First-run step 1: go on without a model"), id: "onboardingSkipStep") {
                        go(to: .site)
                    }
                )
            case .site:
                actions(
                    primary: primaryButton(
                        title: String(localized: "Open", comment: "First-run step 2: open the chosen site"),
                        isBusy: false,
                        id: "onboardingOpen",
                        action: openSite
                    ),
                    quiet: quietButton(title: String(localized: "Back"), id: "onboardingBack") {
                        go(to: .model)
                    }
                )
            case .tryAgent:
                EmptyView()
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, DCTheme.spacingL)
        .padding(.top, usesCompactChrome ? DCTheme.spacingXS : DCTheme.spacingM)
        .padding(.bottom, usesCompactChrome ? DCTheme.spacingXS : DCTheme.spacingS)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .dcStickyFooter()
    }

    /// The primary button over the quiet one; side by side where height is short.
    @ViewBuilder
    private func actions(primary: some View, quiet: some View) -> some View {
        if usesCompactChrome {
            HStack(spacing: DCTheme.spacingM) {
                quiet
                primary
            }
        } else {
            VStack(spacing: DCTheme.spacingXS) {
                primary
                quiet
            }
        }
    }

    private func primaryButton(title: String, isBusy: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DCTheme.spacingS) {
                if isBusy { ProgressView().tint(DCTheme.onGold) }
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(DCButtonStyle(role: .primary, fullWidth: true))
        .disabled(isBusy)
        .accessibilityIdentifier(id)
    }

    private func quietButton(title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title) {
            DCHaptics.tap()
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            action()
        }
        .buttonStyle(DCButtonStyle(role: .quiet))
        .accessibilityIdentifier(id)
    }

    // MARK: Pages

    @ViewBuilder
    private func page(for step: OnboardingStep) -> some View {
        switch step {
        case .model:
            OnboardingModelPage(app: app, state: $providerState)
        case .site:
            OnboardingSitePage(address: $address, selectedSiteURL: $selectedSiteURL, onSubmit: openSite)
        case .tryAgent:
            EmptyView()
        }
    }

    // MARK: Navigation

    /// Continue: tests the model and moves on; with a model that already
    /// works (a replay), it just moves on.
    private func continueFromModel() {
        DCHaptics.tap()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if providerState == .success || (providerState == .idle && app.isBrowserAgentReady) {
            finishModel()
            return
        }
        guard providerState != .testing else { return }
        providerState = .testing
        Task {
            let result = await app.testAndSaveProvider(scope: .role(.browserAgent))
            providerState = result
            if result == .success { finishModel() }
        }
    }

    /// The Agent's model also runs summaries and forum search until Settings
    /// gives them their own.
    private func finishModel() {
        let selection = app.selection(for: .browserAgent)
        app.applyModelToBothUIRoles(selection)
        if !app.isFavorite(selection) { app.addCurrentFavorite(for: .browserAgent) }
        go(to: .site)
    }

    private func go(to target: OnboardingStep?) {
        guard let target, target != step else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        step = target
        UIAccessibility.post(notification: .screenChanged, argument: target.accessibilityLabel)
    }

    /// Open: the typed address (or a search), else the chosen suggestion. The
    /// cover closes, the site loads, and step 3 starts over it.
    private func openSite() {
        DCHaptics.success()
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggested = OnboardingSitePage.suggestions.first { $0.siteURL == selectedSiteURL }
            ?? OnboardingSitePage.suggestions.first
        finish {
            if !text.isEmpty {
                if !app.browser.open(address: text), let url = app.webSearchURL(query: text) {
                    app.browser.load(url)
                }
            } else if let suggested {
                app.openForum(suggested)
            }
        }
    }

    private func finish(then action: @escaping () -> Void) {
        app.saveSettings()
        app.completeOnboarding()
        app.settingsStatus = ""
        app.firstRun = .prompts
        onFinish()
        action()
    }
}

/// Warm paper (`ground`) / lacquer black page background (no gradient blobs).
struct OnboardingBackdrop: View {
    var body: some View {
        DCTheme.ground
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// The three steps as dots: the current one is a wider gold bar. Changes in
/// place, without animation.
struct OnboardingProgressDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: DCTheme.spacingS) {
            ForEach(OnboardingStep.allCases) { step in
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(step == current ? DCTheme.gold : DCTheme.inkFaint.opacity(0.45))
                    .frame(width: step == current ? 22 : 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(current.accessibilityLabel)
        .accessibilityIdentifier("onboardingProgress")
    }
}
