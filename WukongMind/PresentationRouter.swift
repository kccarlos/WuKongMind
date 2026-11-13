import SwiftUI
import UIKit

// MARK: - Presentation router
//
// Every sheet, full-screen cover and alert that used to hang off the root
// (WukongMindApp, ContentView) goes through one host, `RouterHost`. SwiftUI
// presents one sheet per view level, so while the iPhone AI drawer (itself a
// sheet) is up the host sits inside the drawer's content; otherwise it sits on
// the root. Presenters nested inside the panel or a routed sheet stay local.
//
// - `RootPresentation`   what the host shows; derived from the app's own
//                        triggers (`requestedSettingsPage`, …) plus
//                        `PresentationRouter.item`
// - `RootAlert`          the root alert (an error; DEBUG: the keychain probe)
// - `PresentationRouter` explicit routes, the walkthrough replay and the
//                        drawer's state (open, detent, host location)

/// Optional follow-up action offered by the root error alert.
enum ErrorAction: Equatable {
    /// Opens Settings › AI models so the user can add or update an API key.
    case openAIModels
}

/// An error waiting for the root alert (`AppModel.errorQueue`); its own id,
/// so the same message coming back later shows again.
struct PresentedError: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var action: ErrorAction? = nil
}

/// A sheet or full-screen cover presented from the root.
enum RootPresentation: Identifiable, Equatable {
    case onboarding
    case providerSetup(ModelRole)
    case settings(SettingsPage)
    case expanded(ExpandedPanelRoute)
    case loginInfo
    case translatePosts
    case translateText(title: String, text: String, target: String)
    case pinnedForums
    case instructions
    case exportOptions
    case addForum
    /// "Share from Safari or Chrome" (Home card).
    case shareHowTo
    /// The Today podcast's player (NowPlaying.swift).
    case nowPlaying
    #if DEBUG
    /// `-dc-show-settings <page>`: Settings as a cover (screenshots).
    case debugSettings(SettingsPage?)
    #endif

    var id: String {
        switch self {
        case .onboarding: "onboarding"
        case .providerSetup(let role): "providerSetup-\(role.rawValue)"
        case .settings(let page): "settings-\(page.rawValue)"
        case .expanded(let route): "expanded-\(route.rawValue)"
        case .loginInfo: "loginInfo"
        case .translatePosts: "translatePosts"
        case .translateText(let title, let text, let target): "translateText-\(target)-\(title.hashValue)-\(text.hashValue)"
        case .pinnedForums: "pinnedForums"
        case .instructions: "instructions"
        case .exportOptions: "exportOptions"
        case .addForum: "addForum"
        case .shareHowTo: "shareHowTo"
        case .nowPlaying: "nowPlaying"
        #if DEBUG
        case .debugSettings(let page): "debugSettings-\(page?.rawValue ?? "root")"
        #endif
        }
    }

    /// Covers the whole screen instead of a sheet.
    var isFullScreen: Bool {
        switch self {
        case .onboarding: true
        #if DEBUG
        case .debugSettings: true
        #endif
        default: false
        }
    }
}

/// The root alert.
enum RootAlert: Identifiable, Equatable {
    case error(PresentedError)
    #if DEBUG
    case keychainProbe(String)
    #endif

    var id: String {
        switch self {
        case .error(let error): "error-\(error.id)"
        #if DEBUG
        case .keychainProbe: "keychainProbe"
        #endif
        }
    }
}

/// Where the iPhone drawer's sheet is. Moves on from the sheet's own
/// callbacks (its content appearing, its dismissal); UIKit can drop a
/// presentation (another one still animating), so a phase that does not move
/// on in time falls back to `.closed` (`PresentationRouter.watchdogDelay`).
enum DrawerPhase: Equatable {
    /// No sheet: the root hosts the root presentations.
    case closed
    /// Asked for; waiting for its content to appear.
    case presenting
    /// Up: the drawer hosts the root presentations.
    case shown
    /// Asked to close; waiting for the sheet's dismissal.
    case dismissing
    /// A presentation never appeared: closed for a moment (a sheet still on
    /// screen goes first), then tried again.
    case recovering

    /// The sheet's `isPresented`.
    var isPresented: Bool { self == .presenting || self == .shown }
}

/// Settings › Help › Show onboarding again. A routed sheet (Settings) goes
/// first and the walkthrough's cover comes once it has gone: UIKit drops a
/// cover presented while a sheet is still leaving.
enum OnboardingReplay: Equatable {
    case none
    /// Asked for over a sheet; waiting for the sheet's dismissal.
    case waitingForSheet
    case showing
}

/// Whether the split layout's AI panel shows: collapsed on Home, shown on
/// pages, until the reader hides or shows it (back to `.auto` when Home
/// comes or goes).
enum SplitPanelMode: Equatable {
    case auto, shown, hidden

    func isVisible(onHome: Bool) -> Bool {
        switch self {
        case .auto: !onHome
        case .shown: true
        case .hidden: false
        }
    }

    /// The mode after the toggle button.
    func toggled(onHome: Bool) -> SplitPanelMode {
        isVisible(onHome: onHome) ? .hidden : .shown
    }
}

/// Heights of the AI drawer. No smaller height: closed, the hint row over
/// the bar (Dock.swift) says what it can do.
enum DrawerDetent: String, CaseIterable {
    case medium
    case large

    var presentationDetent: PresentationDetent {
        switch self {
        case .medium: .medium
        case .large: .large
        }
    }

    init(_ detent: PresentationDetent) {
        self = detent == .large ? .large : .medium
    }
}

@MainActor
final class PresentationRouter: ObservableObject {
    /// Routes the app asks for explicitly (the others follow app state).
    @Published var item: RootPresentation?
    /// Settings › Help › replay the walkthrough.
    @Published var onboardingReplay: OnboardingReplay = .none
    var replayingOnboarding: Bool { onboardingReplay != .none }
    #if DEBUG
    @Published var keychainProbeResult: String?
    #endif

    // MARK: Window layout (Phase 8)

    /// Side by side (page left, AI panel right) or the drawer layout, by
    /// window width (`WorkspaceMetrics.nextIsSplit`, with hysteresis). nil
    /// until the first size is known.
    @Published var splitLayout: Bool?
    /// Whether the split layout's AI panel shows.
    @Published var splitPanelMode: SplitPanelMode = .auto
    /// Whether a narrow-window drawer is wide enough for a two-column medium summary.
    @Published var usesWideDrawerSummary = false

    /// The bottom bar and the AI drawer: iPhone, and iPad windows narrower
    /// than the split threshold.
    var usesDrawer: Bool { splitLayout != true }

    // MARK: Drawer (iPhone and narrow windows)

    /// The user (or a hand-off) wants the AI drawer; it shows on web pages,
    /// not on the Forums home (`AppModel.syncDrawer`).
    @Published var wantsDrawer = false
    /// The drawer's height, bound to the sheet's detent selection so it comes
    /// back at the same height after every presentation.
    @Published var drawerDetentSelection: PresentationDetent = DrawerDetent.medium.presentationDetent
    /// Where the drawer's sheet is. Only moves on while nothing routed is
    /// up, so the host never moves under a live presentation; routed
    /// presentations wait while it is presenting or dismissing.
    @Published private(set) var drawerPhase: DrawerPhase = .closed
    /// Presentations in a row that never appeared; after
    /// `maximumDroppedPresentations` the request is given up.
    private var droppedPresentations = 0
    private var watchdog: Task<Void, Never>?
    /// How long presenting or dismissing may take before it is taken as
    /// dropped.
    var watchdogDelay: Duration = .seconds(2)
    /// How long `.recovering` lasts.
    var recoveryDelay: Duration = .milliseconds(600)
    static let maximumDroppedPresentations = 2
    /// How long a dismissed sheet takes to leave for good before a cover can
    /// be presented in its place.
    static var settleDelay: Duration = .milliseconds(450)
    /// How long a replay waits for the sheet's dismissal to report before
    /// showing the walkthrough anyway.
    static var dismissalFallback: Duration = .seconds(2)
    /// Ask the forum answers finished after this show "Answer ready" in the
    /// drawer's status row until the reader opens Ask the forum.
    @Published var answersSeenAt = Date()
    /// The hint row's "Summarize this topic" tip is still to come: until the
    /// drawer first opens on a topic or a summary starts. Kept in the user
    /// defaults (`summarizeTipKey`); published so the row goes at once.
    @Published private(set) var summarizeTipPending = !UserDefaults.standard.bool(forKey: summarizeTipKey)

    func summarizeTipSeen() {
        guard summarizeTipPending else { return }
        summarizeTipPending = false
        UserDefaults.standard.set(true, forKey: Self.summarizeTipKey)
    }

    #if DEBUG
    /// After the launch arguments reset or set the tips.
    func reloadSummarizeTip() {
        summarizeTipPending = !UserDefaults.standard.bool(forKey: Self.summarizeTipKey)
    }
    #endif

    var drawerDetent: DrawerDetent {
        get { DrawerDetent(drawerDetentSelection) }
        set { drawerDetentSelection = newValue.presentationDetent }
    }

    func openDrawer(at detent: DrawerDetent = .medium) {
        drawerDetent = detent
        droppedPresentations = 0
        wantsDrawer = true
    }

    func closeDrawer() {
        wantsDrawer = false
    }

    /// Which host presents the root sheets, covers and alerts: the root
    /// while the drawer is closed, the drawer while it is up, neither while
    /// it is on its way.
    var rootHostIsActive: Bool { drawerPhase == .closed || drawerPhase == .recovering }
    var drawerHostIsActive: Bool { drawerPhase == .shown }

    func presentDrawer() {
        guard drawerPhase == .closed else { return }
        move(to: .presenting)
    }

    func dismissDrawer() {
        guard drawerPhase.isPresented else { return }
        move(to: .dismissing)
    }

    /// The drawer's content appeared.
    func drawerAppeared() {
        guard drawerPhase == .presenting else { return }
        droppedPresentations = 0
        move(to: .shown)
    }

    /// The sheet was dismissed (by `dismissDrawer` or a swipe).
    func drawerDismissed() {
        move(to: .closed)
    }

    private func move(to phase: DrawerPhase) {
        drawerPhase = phase
        watchdog?.cancel()
        let delay: Duration
        switch phase {
        case .presenting, .dismissing: delay = watchdogDelay
        case .recovering: delay = recoveryDelay
        case .closed, .shown: return
        }
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.drawerPhase == phase else { return }
            self.timedOut(in: phase)
        }
    }

    /// The sheet never appeared (or never went): closed, so the root host is
    /// not left inactive. A drawer still wanted is tried again after
    /// `.recovering` (`AppModel.syncDrawer`), and given up after a few.
    private func timedOut(in phase: DrawerPhase) {
        switch phase {
        case .presenting:
            droppedPresentations += 1
            if droppedPresentations >= Self.maximumDroppedPresentations {
                droppedPresentations = 0
                wantsDrawer = false
                move(to: .closed)
            } else {
                move(to: .recovering)
            }
        case .dismissing, .recovering:
            move(to: .closed)
        case .closed, .shown:
            break
        }
    }

    /// First-run tips, once each (§4.5): "Summarize this topic" over the bar
    /// (the hint row) and "Tap a post number to jump to it" with the first
    /// summary.
    static let summarizeTipKey = "dc.tipSummarizeShown"
    static let citationTipKey = "dc.tipCitationShown"
    /// "This topic / Whole forum" the first time the Ask box is focused (§5).
    static let askScopeHintKey = "dc.tipAskScopeShown"
    static let tipKeys = [summarizeTipKey, citationTipKey, askScopeHintKey]
}

/// A composer (chat, Ask the forum) gained or lost focus. The iPhone drawer
/// goes to its large height so it never covers the keyboard.
struct ComposerFocusAction {
    var action: (Bool) -> Void = { _ in }
    func callAsFunction(_ focused: Bool) { action(focused) }
}

private struct ComposerFocusKey: EnvironmentKey {
    static let defaultValue = ComposerFocusAction()
}

extension EnvironmentValues {
    var composerFocusChanged: ComposerFocusAction {
        get { self[ComposerFocusKey.self] }
        set { self[ComposerFocusKey.self] = newValue }
    }
}

// MARK: - Resolving

extension AppModel {
    /// What the root host shows, highest priority first. A request that
    /// arrives while a higher one is up waits until it closes.
    var rootPresentation: RootPresentation? {
        if !settings.hasCompletedOnboarding || router.onboardingReplay == .showing { return .onboarding }
        // The sheet the replay was asked from is leaving: nothing else comes.
        if router.onboardingReplay == .waitingForSheet { return nil }
        if let item = router.item { return item }
        if let page = requestedSettingsPage { return .settings(page) }
        return nil
    }

    /// Clears the trigger behind a presentation the user closed.
    func dismissRootPresentation(_ presentation: RootPresentation) {
        switch presentation {
        case .onboarding:
            router.onboardingReplay = .none
            if !settings.hasCompletedOnboarding { completeOnboarding() }
        case .settings:
            requestedSettingsPage = nil
            requestedScriptID = nil
        case .providerSetup:
            router.item = nil
            needsProviderSetup = nil
        default:
            if router.item == presentation { router.item = nil }
        }
        syncDrawer()
    }

    /// Settings › Help › Show onboarding again. Settings (as a sheet or a
    /// Settings page request) closes for good, so it doesn't come back after
    /// the walkthrough.
    func replayOnboarding() {
        guard router.onboardingReplay == .none else { return }
        let overSheet = rootPresentation.map { !$0.isFullScreen } ?? false
        router.item = nil
        requestedSettingsPage = nil
        guard overSheet else {
            router.onboardingReplay = .showing
            return
        }
        router.onboardingReplay = .waitingForSheet
        // The sheet's dismissal moves it on; in case it never reports.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: PresentationRouter.dismissalFallback)
            guard let self, self.router.onboardingReplay == .waitingForSheet else { return }
            self.router.onboardingReplay = .showing
        }
    }

    /// A root sheet went (its `onDismiss`). UIKit still finishes the
    /// dismissal for a moment after it reports (iPad form sheets), and a
    /// cover asked for then is dropped without a word, so it waits a beat.
    func rootSheetDismissed() {
        syncDrawer()
        guard router.onboardingReplay == .waitingForSheet else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: PresentationRouter.settleDelay)
            guard let self, self.router.onboardingReplay == .waitingForSheet else { return }
            self.router.onboardingReplay = .showing
        }
    }

    var rootAlert: RootAlert? {
        #if DEBUG
        if let result = router.keychainProbeResult { return .keychainProbe(result) }
        #endif
        return errorQueue.first.map(RootAlert.error)
    }

    func dismissRootAlert() {
        #if DEBUG
        if router.keychainProbeResult != nil {
            router.keychainProbeResult = nil
            return
        }
        #endif
        dismissPresentedError()
    }

    /// A shared link needs an AI provider first; not over the walkthrough.
    func presentProviderSetupIfNeeded() {
        guard let role = needsProviderSetup, acceptsSystemWork, !router.replayingOnboarding else { return }
        if isProviderReady(for: role) {
            needsProviderSetup = nil
        } else if router.item == nil {
            router.item = .providerSetup(role)
        }
    }
}

// MARK: - Host

/// Hosts every root presentation. Attached twice (drawer content and root);
/// only the `active` one presents.
struct RouterHost: ViewModifier {
    @ObservedObject var app: AppModel
    @ObservedObject var router: PresentationRouter
    @ObservedObject var podcast: PodcastController
    let active: Bool
    /// A forum was added from the Add forum sheet.
    var onForumAdded: (Forum) -> Void = { _ in }

    init(
        app: AppModel,
        active: Bool,
        onForumAdded: @escaping (Forum) -> Void = { _ in }
    ) {
        self.app = app
        router = app.router
        podcast = app.podcast
        self.active = active
        self.onForumAdded = onForumAdded
    }

    private func binding(fullScreen: Bool) -> Binding<RootPresentation?> {
        Binding(
            get: {
                guard active, let current = app.rootPresentation, current.isFullScreen == fullScreen else { return nil }
                return current
            },
            set: { newValue in
                guard newValue == nil, active, let current = app.rootPresentation,
                      current.isFullScreen == fullScreen else { return }
                app.dismissRootPresentation(current)
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: binding(fullScreen: false), onDismiss: { app.rootSheetDismissed() }) { presentation in
                view(for: presentation)
                    .tint(DCTheme.brandBlue)
                    .modifier(RootAlertModifier(app: app, active: active, presentation: presentation))
            }
            .fullScreenCover(item: binding(fullScreen: true)) { presentation in
                view(for: presentation)
                    .tint(DCTheme.brandBlue)
                    .modifier(RootAlertModifier(app: app, active: active, presentation: presentation))
            }
            .modifier(RootAlertModifier(app: app, active: active, presentation: nil))
    }

    // MARK: Views

    @ViewBuilder
    private func view(for presentation: RootPresentation) -> some View {
        switch presentation {
        case .onboarding:
            OnboardingFlow(app: app, initialStep: initialOnboardingStep) {
                router.onboardingReplay = .none
            }
        case .providerSetup(let role):
            ProviderSetupSheet(app: app, role: role)
        case .settings(let page):
            // Start a Voice Chat without voice set up: Settings › Voice.
            NavigationStack {
                SettingsRootView(app: app, initialPage: page)
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                app.requestedSettingsPage = nil
                                app.requestedScriptID = nil
                            }
                        }
                    }
            }
        case .expanded(let route):
            ExpandedPanel(app: app, route: route)
        case .loginInfo:
            LoginReadinessView(app: app)
        case .translatePosts:
            PostsTranslationSheet(app: app)
        case .translateText(let title, let text, let target):
            TranslationSheet(
                title: title,
                sources: [TranslationSource(id: "text", text: text)],
                target: target
            )
        case .pinnedForums:
            PinnedForumsEditor(app: app)
        case .instructions:
            InstructionsSheet(app: app)
        case .exportOptions:
            ExportOptionsSheet(payload: app.currentExportPayload, options: $app.exportOptions)
        case .shareHowTo:
            ShareHowToSheet(onDone: { router.item = nil })
        case .addForum:
            AddForumSheet(app: app, onAdded: onForumAdded)
        case .nowPlaying:
            NowPlayingView(app: app, podcast: podcast)
                .nowPlayingZoomDestination()
        #if DEBUG
        case .debugSettings(let page):
            NavigationStack {
                SettingsRootView(app: app, initialPage: page)
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // UI tests close it (screenshots keep it bare).
                        if AssistantDebug.has("-dc-test-present") {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(action: { router.item = nil }) { Text(verbatim: "Done") }
                                    .accessibilityIdentifier("debugSettingsDone")
                            }
                        }
                    }
            }
        #endif
        }
    }

    private var initialOnboardingStep: OnboardingStep {
        #if DEBUG
        if let step = OnboardingDebug.initialStep, !router.replayingOnboarding { return step }
        #endif
        return .welcome
    }
}

private struct RootAlertModifier: ViewModifier {
    @ObservedObject var app: AppModel
    let active: Bool
    let presentation: RootPresentation?

    private var activeAlert: RootAlert? {
        guard active, app.rootPresentation == presentation else { return nil }
        return app.rootAlert
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { if !$0, active, app.rootPresentation == presentation { app.dismissRootAlert() } }
        )
    }

    func body(content: Content) -> some View {
        let alert = activeAlert
        content.alert(
            alertTitle(alert),
            isPresented: alertBinding,
            presenting: alert
        ) { alert in
            if case .error(let error) = alert, let action = error.action {
                Button("AI models…") {
                    app.performErrorAction(action)
                }
                Button("Cancel", role: .cancel) {
                    app.dismissRootAlert()
                }
            } else {
                Button(role: .cancel) {
                    app.dismissRootAlert()
                } label: {
                    alertButton(alert)
                }
            }
        } message: { alert in
            alertMessage(alert)
        }
    }

    private func alertTitle(_ alert: RootAlert?) -> Text {
        switch alert {
        #if DEBUG
        case .keychainProbe: Text(verbatim: "Keychain sync probe")
        #endif
        default: Text("WukongMind")
        }
    }

    @ViewBuilder
    private func alertButton(_ alert: RootAlert) -> some View {
        switch alert {
        #if DEBUG
        case .keychainProbe: Text(verbatim: "OK")
        #endif
        default: Text("OK")
        }
    }

    private func alertMessage(_ alert: RootAlert) -> Text {
        switch alert {
        case .error(let error): Text(error.message)
        #if DEBUG
        case .keychainProbe(let result): Text(result)
        #endif
        }
    }
}

// MARK: - DEBUG launch arguments

#if DEBUG
/// - `-dc-drawer-first-run`        the first-run tips show again ("Summarize this
///                                 topic" over the bar; the sample leaves the drawer
///                                 closed) (other `-dc-` / `-ui-test-` launches, UI
///                                 tests among them, count as having seen them)
/// - `-dc-drawer-detent <detent>`  medium | large once the drawer is up
/// - `-dc-test-present <kind>`     after `-dc-test-present-after <s>` (default 6):
///                                 settings | cover | error | pending-drawer;
///                                 drawer-on-voice: the drawer opens once voice runs
///                                 and result cards show
/// - `-dc-drawer-drop-first`       the drawer's first presentation never reports
///                                 its content (a dropped presentation)
extension AppModel {
    func applyDrawerDebugArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        let keys = PresentationRouter.tipKeys
        if arguments.contains("-dc-drawer-first-run") {
            keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        } else if arguments.contains(where: { $0.hasPrefix("-dc-") || $0.hasPrefix("-ui-test-") }) {
            keys.forEach { UserDefaults.standard.set(true, forKey: $0) }
        }
        router.reloadSummarizeTip()
    }

    /// UI tests: a root presentation of each kind while the drawer is up.
    func runPresentationTestTrigger() async {
        if let value = AssistantDebug.value("-dc-drawer-detent"), let detent = DrawerDetent(rawValue: value) {
            for _ in 0..<60 where router.drawerPhase != .shown {
                try? await Task.sleep(for: .milliseconds(250))
            }
            // After the sample's second "show the assistant" (1.7 s in).
            try? await Task.sleep(for: .seconds(2))
            router.drawerDetent = detent
        }
        guard let kind = AssistantDebug.value("-dc-test-present") else { return }
        if kind == "drawer-on-voice" {
            for _ in 0..<480 where !(voice.isActive && !browseCursor.isEmpty) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(1))
            router.openDrawer(at: .medium)
            return
        }
        let delay = AssistantDebug.value("-dc-test-present-after").flatMap(Double.init) ?? 6
        try? await Task.sleep(for: .seconds(delay))
        switch kind {
        case "settings": requestedSettingsPage = .voice
        case "cover": router.item = .debugSettings(nil)
        case "error": presentError("Test error")
        case "translate-posts": router.item = .translatePosts
        case "pending-drawer":
            // A root sheet up while the drawer is wanted; the UI test closes
            // the sheet, the drawer comes back and an error shows over it.
            router.closeDrawer()
            for _ in 0..<40 where router.drawerPhase != .closed { try? await Task.sleep(for: .milliseconds(250)) }
            requestedSettingsPage = .voice
            try? await Task.sleep(for: .seconds(1.5))
            router.openDrawer(at: .medium)
            for _ in 0..<240 where requestedSettingsPage != nil || router.drawerPhase != .shown {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(1))
            presentError("Test error")
        default: break
        }
    }
}
#endif
