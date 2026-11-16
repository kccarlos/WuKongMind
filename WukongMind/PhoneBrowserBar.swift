import SwiftUI
import WebKit

// MARK: - Browser bar (iPhone morphing glass capsule + iPad split top bar)
//
// On iPhone (`split == nil`), the page sits in a NavigationStack (no navigation
// bar) with one floating glass capsule driven continuously by scroll progress
// `p ∈ [0, 1]` (`BrowserBarMorph.swift`):
// - Expanded (`p = 0`): Back (tap goes back, long press opens history with
//   Forward), address field (page menu at leading edge, middle-truncated
//   domain, reload at trailing edge), and the Agent ring (tabs slot stays
//   empty until T3). On Home, the address field gives way to Home's own field
//   and the bar stays expanded (`p = 0`).
// - Collapsed (`p = 1`): centred pill (`120…240 × 34 pt`, `44 pt` hit target)
//   with lock (or 16 pt turning Agent ring + scripts seal while Agent works)
//   and domain; tapping springs back to `p = 0`.
// - While editing the address, `addressRow` rides on the keyboard. While a page
//   form field raises the keyboard, `p` freezes and the bottom bar hides under
//   the keyboard (top bar stays in place, frozen).
// In the iPad split layout (`split != nil`), the top bar stays above the page
// and panel until B3 adds split-bar collapse.

struct PhoneBrowser<Page: View>: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    /// The voice Dock replaces the bottom bar while a session shows.
    @ObservedObject var voice: VoiceController
    @ObservedObject private var router: PresentationRouter
    /// Resolved: `.top` or `.bottom`.
    let position: BrowserBarPosition
    let actions: BrowserActions
    /// Bumped by ⌘L to start editing the address.
    var addressFocusRequest = 0
    /// The window width.
    var width: CGFloat = 0
    /// iPad split layout: the top bar's three groups, with the AI panel's
    /// toggle. nil: the iPhone morphing bar.
    var split: SplitBarContext?
    @ViewBuilder let page: (CGFloat) -> Page

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        app: AppModel,
        browser: ForumBrowserModel,
        voice: VoiceController,
        position: BrowserBarPosition,
        actions: BrowserActions,
        addressFocusRequest: Int = 0,
        width: CGFloat = 0,
        split: SplitBarContext? = nil,
        @ViewBuilder page: @escaping (CGFloat) -> Page
    ) {
        self.app = app
        self.browser = browser
        self.voice = voice
        self.router = app.router
        self.position = position
        self.actions = actions
        self.addressFocusRequest = addressFocusRequest
        self.width = width
        self.split = split
        self.page = page
    }

    private var usesMorphingPhoneBar: Bool {
        router.splitLayout == false || split == nil
    }

    private var isLandscape: Bool {
        verticalSizeClass == .compact
    }

    /// States where the bar must stay expanded (`p = 0`).
    /// Note: iPad split (`!usesMorphingPhoneBar`) is intentionally NOT locked here so
    /// `isChromeMinimized` still shrinks `ResultCardsOverlay` to a chip on scroll while
    /// `managesWebViewInsets == false` keeps `scrollView.contentInset` at `.zero`.
    private var isBarLockedExpanded: Bool {
        browser.showsForumsHome
            || voice.showsBar
            || dynamicTypeSize.isAccessibilitySize
    }

    fileprivate static func normalSceneWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes
            .flatMap(\.windows)
            .first(where: { !$0.isHidden && $0.windowLevel == .normal }) {
            return window
        }
        return scenes.first?.windows.first(where: { $0.windowLevel == .normal })
    }

    /// Hardware/container bottom safe area excluding software keyboards so focusing a page
    /// form field or address bar never inflates `expandedBottomInset`.
    private var resolvedSafeAreaBottom: CGFloat {
        Self.normalSceneWindow()?.safeAreaInsets.bottom ?? 0
    }

    private var resolvedContainerWidth: CGFloat {
        if width > 0 { return width }
        return Self.normalSceneWindow()?.bounds.width ?? 390
    }

    /// Whether the floating morphing bar reserves clearance below `DockLayer`.
    private var showsMorphingBar: Bool {
        guard usesMorphingPhoneBar, app.homePath.isEmpty, !browser.isEditingAddress else {
            return false
        }
        if position == .bottom {
            if voice.showsBar || browser.isPageFormInputFocused {
                return false
            }
            if browser.isSystemKeyboardVisible && !app.isAIViewShown && app.rootPresentation == nil {
                return false
            }
        }
        return true
    }

    var body: some View {
        let safeAreaBottom = resolvedSafeAreaBottom
        let containerWidth = resolvedContainerWidth
        let dockClearance = bottomDockClearance(safeAreaBottom: safeAreaBottom)

        Group {
            if UIDevice.current.userInterfaceIdiom == .phone {
                let _ = router.splitPanelMode
                NavigationStack(path: $app.homePath) {
                    page(dockClearance)
                        .toolbar(.hidden, for: .navigationBar)
                        .modifier(HomeDestinations(app: app, onOpenDigestLink: actions.openDigestLink))
                }
                .background {
                    PhoneBarObserverHost(
                        app: app,
                        browser: browser,
                        voice: voice,
                        router: router,
                        hasSplitContext: false,
                        addressFocusRequest: addressFocusRequest,
                        safeAreaBottom: safeAreaBottom,
                        isLandscape: isLandscape,
                        reduceMotion: reduceMotion
                    )
                }
                .overlay {
                    PhoneOnlyMorphingBarHost(
                        app: app,
                        browser: browser,
                        progressModel: browser.barProgressModel,
                        browserAgent: app.browserAgent,
                        scriptStore: app.scriptStore,
                        voice: voice,
                        actions: actions,
                        addressFocusRequest: addressFocusRequest,
                        containerWidth: containerWidth,
                        safeAreaBottom: safeAreaBottom,
                        isLandscape: isLandscape,
                        reduceMotion: reduceMotion,
                        reduceTransparency: reduceTransparency,
                        increasedContrast: colorSchemeContrast == .increased
                    )
                }
            } else {
                let _ = router.splitLayout
                let _ = router.splitPanelMode
                ZStack {
                    VStack(spacing: 0) {
                        SplitTopBarHost(
                            app: app,
                            browser: browser,
                            router: router,
                            actions: actions,
                            split: split,
                            width: containerWidth,
                            addressFocusRequest: addressFocusRequest
                        )
                        NavigationStack(path: $app.homePath) {
                            page(dockClearance)
                                .toolbar(.hidden, for: .navigationBar)
                                .modifier(HomeDestinations(app: app, onOpenDigestLink: actions.openDigestLink))
                        }
                    }
                    PhoneBarObserverHost(
                        app: app,
                        browser: browser,
                        voice: voice,
                        router: router,
                        hasSplitContext: split != nil,
                        addressFocusRequest: addressFocusRequest,
                        safeAreaBottom: safeAreaBottom,
                        isLandscape: isLandscape,
                        reduceMotion: reduceMotion
                    )
                    PhoneMorphingBarHost(
                        app: app,
                        browser: browser,
                        progressModel: browser.barProgressModel,
                        browserAgent: app.browserAgent,
                        scriptStore: app.scriptStore,
                        voice: voice,
                        router: router,
                        hasSplitContext: split != nil,
                        actions: actions,
                        addressFocusRequest: addressFocusRequest,
                        containerWidth: containerWidth,
                        safeAreaBottom: safeAreaBottom,
                        isLandscape: isLandscape,
                        reduceMotion: reduceMotion,
                        reduceTransparency: reduceTransparency,
                        increasedContrast: colorSchemeContrast == .increased
                    )
                }
            }
        }
        .onAppear {
            app.barShowsTopicFacts = true
            if !usesMorphingPhoneBar {
                syncSplitFallbackConfiguration()
            }
        }
        .onChange(of: usesMorphingPhoneBar) { _, morphing in
            if !morphing {
                syncSplitFallbackConfiguration()
            }
        }
        .onChange(of: isBarLockedExpanded) { _, _ in
            if !usesMorphingPhoneBar {
                syncSplitFallbackConfiguration()
            }
        }
        .onChange(of: reduceMotion) { _, _ in
            if !usesMorphingPhoneBar {
                syncSplitFallbackConfiguration()
            }
        }
    }

    /// Extra bottom clearance inside safe area so `DockLayer` cards/rows sit above the floating bottom bar.
    /// Driven by `isChromeMinimized` (0.6 / 0.4 hysteresis) so `BrowserContent` does not re-layout per scroll frame.
    private func bottomDockClearance(safeAreaBottom: CGFloat) -> CGFloat {
        guard usesMorphingPhoneBar, position == .bottom, showsMorphingBar else {
            return 0
        }
        let effectiveP: CGFloat = browser.isChromeMinimized ? 1 : 0
        let collapsedFont = BrowserBarFontMetrics.collapsedFontSize(for: dynamicTypeSize)
        let barHeight = BrowserBarMorphMetrics.lerp(
            BrowserBarMorphMetrics.expandedHeight(isLandscape: isLandscape),
            BrowserBarMorphMetrics.collapsedHeight(collapsedFontSize: collapsedFont),
            effectiveP
        )
        let bottomEdge = BrowserBarMorphMetrics.bottomEdgeFromScreen(
            safeAreaBottom: safeAreaBottom,
            progress: effectiveP
        )
        return max(0, barHeight + bottomEdge - safeAreaBottom)
    }

    private func syncSplitFallbackConfiguration() {
        browser.barMorph.updateLayoutConfiguration(
            managesInsets: false,
            position: .top,
            safeAreaBottom: 0,
            isLandscape: true,
            isLockedExpanded: isBarLockedExpanded,
            reduceMotion: reduceMotion
        )
        browser.setExternalKeyboardFrozen(false)
    }
}

/// Always-mounted zero-size observer leaf for the iPhone morphing bar.
/// Hanging `.onChange` and `UIResponder.keyboard*Notification` publishers on a dedicated
/// concrete view (never on a `Group` that can become `EmptyView` while the bar is hidden
/// under a page keyboard, Voice Dock, or pushed Settings screen) keeps keyboard-hide and
/// lock transitions live at all times without re-evaluating `PhoneBrowser` at 120 Hz.
private struct PhoneBarObserverHost: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var router: PresentationRouter
    let hasSplitContext: Bool
    let addressFocusRequest: Int
    let safeAreaBottom: CGFloat
    let isLandscape: Bool
    let reduceMotion: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var lastReadyAnswerID: UUID?
    @State private var hasActiveKeyboardSession = false

    private var isActiveMorphingBar: Bool {
        if let splitLayout = router.splitLayout {
            return !splitLayout
        }
        return !hasSplitContext
    }

    private var resolvedPosition: BrowserBarPosition {
        app.settings.browserBarPosition.resolved(isSplit: false)
    }

    private var isBarLockedExpanded: Bool {
        browser.showsForumsHome
            || voice.showsBar
            || dynamicTypeSize.isAccessibilitySize
    }

    private var isAnyKeyboardVisible: Bool {
        browser.isSystemKeyboardVisible || browser.isPageFormInputFocused
    }

    /// Keyboard raised by a web-page form field (not our address bar, drawer, root sheet, Home field, or voice Dock).
    private var isPageFormKeyboardActive: Bool {
        guard !browser.isEditingAddress, !voice.showsBar, !browser.showsForumsHome else {
            return false
        }
        if browser.isPageFormInputFocused {
            return true
        }
        return isAnyKeyboardVisible && !app.isAIViewShown && app.rootPresentation == nil
    }

    var body: some View {
        let _ = router.splitLayout
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                lastReadyAnswerID = app.readyAnswer?.id
                syncMorphConfiguration()
            }
            .onDisappear {
                browser.setSystemKeyboardVisible(false)
                browser.setExternalKeyboardFrozen(false)
            }
            .onChange(of: isActiveMorphingBar) { _, active in
                if !active {
                    hasActiveKeyboardSession = false
                    browser.setSystemKeyboardVisible(false)
                    browser.setExternalKeyboardFrozen(false)
                } else {
                    syncMorphConfiguration()
                }
            }
            .onChange(of: ObjectIdentifier(browser)) { _, _ in
                syncMorphConfiguration()
            }
            .onChange(of: safeAreaBottom) { _, _ in
                syncMorphConfiguration()
            }
            .onChange(of: isLandscape) { _, _ in
                syncMorphConfiguration()
            }
            .onChange(of: resolvedPosition) { _, _ in
                syncMorphConfiguration()
            }
            .onChange(of: isBarLockedExpanded) { _, _ in
                syncMorphConfiguration()
            }
            .onChange(of: reduceMotion) { _, _ in
                syncMorphConfiguration()
            }
            .onChange(of: isPageFormKeyboardActive) { _, active in
                browser.setExternalKeyboardFrozen(active)
            }
            .onChange(of: addressFocusRequest) {
                browser.expandChrome(deferIfTracking: false)
                browser.setEditingAddress(true)
            }
            .onChange(of: app.readyAnswer?.id) { _, nextID in
                defer { lastReadyAnswerID = nextID }
                if let nextID, nextID != lastReadyAnswerID, !app.isAIViewShown {
                    browser.expandChrome(deferIfTracking: true)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                guard isActiveMorphingBar else { return }
                hasActiveKeyboardSession = true
                updateSystemKeyboardVisibility(from: note, isHideNotification: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { note in
                guard isActiveMorphingBar else { return }
                hasActiveKeyboardSession = true
                updateSystemKeyboardVisibility(from: note, isHideNotification: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard isActiveMorphingBar, hasActiveKeyboardSession else { return }
                updateSystemKeyboardVisibility(from: note, isHideNotification: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                hasActiveKeyboardSession = false
                updateSystemKeyboardVisibility(from: note, isHideNotification: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { note in
                hasActiveKeyboardSession = false
                updateSystemKeyboardVisibility(from: note, isHideNotification: true)
            }
    }

    private func syncMorphConfiguration() {
        guard isActiveMorphingBar else { return }
        let liveSafeBottom = PhoneBrowser<EmptyView>.normalSceneWindow()?.safeAreaInsets.bottom ?? safeAreaBottom
        browser.barMorph.updateLayoutConfiguration(
            managesInsets: true,
            position: resolvedPosition,
            safeAreaBottom: liveSafeBottom,
            isLandscape: isLandscape,
            isLockedExpanded: isBarLockedExpanded,
            reduceMotion: reduceMotion
        )
        browser.setExternalKeyboardFrozen(isPageFormKeyboardActive)
    }

    private func updateSystemKeyboardVisibility(from notification: Notification, isHideNotification: Bool) {
        if isHideNotification {
            browser.setSystemKeyboardVisible(false)
            return
        }
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        if let window = PhoneBrowser<EmptyView>.normalSceneWindow() {
            let localFrame = window.convert(frame, from: window.screen.coordinateSpace)
            let windowBounds = window.bounds
            let intersection = windowBounds.intersection(localFrame)
            let overlapHeight = intersection.isNull ? 0 : intersection.height
            let visible = overlapHeight >= 20 && localFrame.minY < windowBounds.maxY - 16
            browser.setSystemKeyboardVisible(visible)
            return
        }
        let screenBounds = (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds) ?? CGRect(x: 0, y: 0, width: 402, height: frame.maxY)
        let intersection = screenBounds.intersection(frame)
        let overlapHeight = intersection.isNull ? 0 : intersection.height
        // Measure direct screen intersection (do not subtract `safeAreaBottom`, which is 34 pt on
        // Face ID iPhones and would swallow WebKit's 44–54 pt compact `^ v ✓` input-assistant bar
        // when a hardware keyboard is attached). When hidden, `frame.minY >= screenBounds.maxY`.
        let visible = overlapHeight >= 20 && frame.minY < screenBounds.maxY - 16
        browser.setSystemKeyboardVisible(visible)
    }
}

// MARK: - Shared Address Editing Bar & Split Top Bar Host

private struct AddressEditBar: View {
    let app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    let addressFocusRequest: Int

    @State private var addressDraft: String
    @State private var addressError: AddressError?
    @State private var didGainFocus = false
    @FocusState private var addressFocused: Bool

    init(app: AppModel, browser: ForumBrowserModel, addressFocusRequest: Int) {
        self.app = app
        self.browser = browser
        self.addressFocusRequest = addressFocusRequest
        let initial = browser.showsForumsHome ? "" : (browser.currentURL?.absoluteString ?? "")
        _addressDraft = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: DCTheme.spacingS) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search or enter address", text: $addressDraft)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(commitAddress)
                    .accessibilityIdentifier("addressField")
                    // Select the whole address so typing replaces it, like Safari.
                    .onReceive(
                        NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)
                    ) { notification in
                        (notification.object as? UITextField)?.selectAll(nil)
                    }
                    .onAppear {
                        DispatchQueue.main.async { addressFocused = true }
                    }
                if !addressDraft.isEmpty {
                    Button {
                        addressDraft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: DCTheme.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear address")
                    .accessibilityShowsLargeContentViewer {
                        Label("Clear address", systemImage: "xmark.circle.fill")
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(minHeight: DCTheme.controlHeight)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5) }

            // Esc / ⌘. too, like Safari.
            Button("Cancel") {
                addressFocused = false
                browser.setEditingAddress(false)
            }
            .fixedSize(horizontal: true, vertical: false)
            .keyboardShortcut(.cancelAction)
            .frame(minHeight: DCTheme.controlHeight)
            .accessibilityIdentifier("addressCancel")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, DCTheme.spacingM)
        .padding(.vertical, 6)
        .onChange(of: addressFocused) { _, isFocused in
            if isFocused {
                didGainFocus = true
            } else if didGainFocus, addressError == nil {
                browser.setEditingAddress(false)
            }
        }
        .onChange(of: addressFocusRequest) {
            addressFocused = true
        }
        .alert(
            addressError?.title ?? "",
            isPresented: Binding(
                get: { addressError != nil },
                set: { if !$0 { addressError = nil } }
            ),
            presenting: addressError
        ) { _ in
            Button("OK", role: .cancel) {
                DispatchQueue.main.async { addressFocused = true }
            }
        } message: { error in
            Text(error.message)
        }
    }

    /// An address opens; other words search the current forum.
    private func commitAddress() {
        let query = addressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if browser.open(address: addressDraft) {
            addressFocused = false
            browser.setEditingAddress(false)
        } else if !query.isEmpty, let url = app.searchPageURL(query: query) ?? app.webSearchURL(query: query) {
            browser.load(url)
            addressFocused = false
            browser.setEditingAddress(false)
        } else {
            addressError = AddressError(address: addressDraft, hasForum: browser.homeSiteURL != nil)
        }
    }
}

private struct SplitTopBarHost: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var router: PresentationRouter
    let actions: BrowserActions
    let split: SplitBarContext?
    let width: CGFloat
    let addressFocusRequest: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastReadyAnswerID: UUID?

    private var isBarLockedExpanded: Bool {
        browser.showsForumsHome
            || app.voice.showsBar
            || dynamicTypeSize.isAccessibilitySize
    }

    private var isActiveSplit: Bool {
        if let splitLayout = router.splitLayout {
            return splitLayout
        }
        return split != nil
    }

    var body: some View {
        let _ = router.splitLayout
        let _ = router.splitPanelMode
        let showsSplitBar = isActiveSplit && app.homePath.isEmpty
        let activeSplit = split ?? SplitBarContext(panelShown: app.showsSplitPanel(), togglePanel: app.toggleAIView)
        VStack(spacing: 0) {
            if showsSplitBar {
                VStack(spacing: 0) {
                    if browser.isEditingAddress {
                        AddressEditBar(app: app, browser: browser, addressFocusRequest: addressFocusRequest)
                    } else {
                        HStack(spacing: DCTheme.spacingS) { splitItems(activeSplit) }
                            .padding(.horizontal, DCTheme.spacingM)
                            .padding(.vertical, 6)
                    }
                    Divider()
                }
                .background(.bar)
            }
        }
        .frame(height: showsSplitBar ? nil : 0)
        .clipped()
        .allowsHitTesting(showsSplitBar)
        .accessibilityHidden(!showsSplitBar)
        .onAppear {
            lastReadyAnswerID = app.readyAnswer?.id
            if showsSplitBar { syncSplitMorphConfiguration() }
        }
        .onChange(of: showsSplitBar) { _, active in
            if active { syncSplitMorphConfiguration() }
        }
        .onChange(of: ObjectIdentifier(browser)) { _, _ in
            if showsSplitBar { syncSplitMorphConfiguration() }
        }
        .onChange(of: isBarLockedExpanded) { _, _ in
            if showsSplitBar { syncSplitMorphConfiguration() }
        }
        .onChange(of: reduceMotion) { _, _ in
            if showsSplitBar { syncSplitMorphConfiguration() }
        }
        .onChange(of: addressFocusRequest) {
            guard showsSplitBar else { return }
            browser.expandChrome(deferIfTracking: false)
            browser.setEditingAddress(true)
        }
        .onChange(of: app.readyAnswer?.id) { _, nextID in
            defer { lastReadyAnswerID = nextID }
            if showsSplitBar, let nextID, nextID != lastReadyAnswerID, !app.isAIViewShown {
                browser.expandChrome(deferIfTracking: true)
            }
        }
    }

    private func syncSplitMorphConfiguration() {
        browser.barMorph.updateLayoutConfiguration(
            managesInsets: false,
            position: .top,
            safeAreaBottom: 0,
            isLandscape: true,
            isLockedExpanded: isBarLockedExpanded,
            reduceMotion: reduceMotion
        )
    }

    /// Forum avatar, back, forward | address capsule | mic, ···, AI panel. Home
    /// has its own address field, so the bar hides its capsule while it shows.
    @ViewBuilder
    private func splitItems(_ split: SplitBarContext) -> some View {
        ForumMenuButton(app: app, browser: browser, actions: actions)
        SplitNavigationButtons(browser: browser)
        if browser.showsForumsHome {
            Spacer(minLength: 0)
        } else {
            PhoneTitleCapsule(
                app: app,
                browser: browser,
                filled: true,
                width: 0,
                onEdit: {
                    browser.setEditingAddress(true)
                }
            )
        }
        BrowserTabsButton(app: app)
            .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
        if app.showsVoiceButton {
            VoiceBarButton(voice: app.voice)
        }
        SplitMoreMenu(app: app, browser: browser, actions: actions)
        SplitPanelToggle(app: app, isShown: app.showsSplitPanel(forWidth: width), action: split.togglePanel)
    }
}

// MARK: - Single Morphing Glass Bar (iPhone)

enum BrowserBarFontMetrics {
    private static func cappedCategory(for dynamicTypeSize: DynamicTypeSize) -> UIContentSizeCategory {
        switch dynamicTypeSize {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge, .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5:
            .extraExtraExtraLarge
        @unknown default: .large
        }
    }

    static func expandedFontSize(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: cappedCategory(for: dynamicTypeSize))
        return UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 15, compatibleWith: traits)
    }

    static func collapsedFontSize(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: cappedCategory(for: dynamicTypeSize))
        return UIFontMetrics(forTextStyle: .footnote).scaledValue(for: 13, compatibleWith: traits)
    }

    static func measuredWidth(of text: String, fontSize: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// Dedicated iPhone overlay host without split-layout `router` observation or outer `.allowsHitTesting`
/// wrappers so `NavigationStack`'s overlay passes cold-launch taps directly to SwiftUI `Button`s.
private struct PhoneOnlyMorphingBarHost: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var progressModel: BrowserBarProgressModel
    var browserAgent: BrowserAgentSession
    var scriptStore: ScriptStore
    @ObservedObject var voice: VoiceController
    let actions: BrowserActions
    let addressFocusRequest: Int
    let containerWidth: CGFloat
    let safeAreaBottom: CGFloat
    let isLandscape: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool

    private var resolvedPosition: BrowserBarPosition {
        app.settings.browserBarPosition.resolved(isSplit: false)
    }

    private var isAnyKeyboardVisible: Bool {
        browser.isSystemKeyboardVisible || browser.isPageFormInputFocused
    }

    private var hidesBottomBar: Bool {
        guard resolvedPosition == .bottom else { return false }
        if voice.showsBar || browser.isPageFormInputFocused {
            return true
        }
        return isAnyKeyboardVisible && !app.isAIViewShown && app.rootPresentation == nil
    }

    var body: some View {
        let position = resolvedPosition
        Group {
            if !app.homePath.isEmpty {
                EmptyView()
            } else if browser.isEditingAddress {
                Group {
                    if position == .top {
                        VStack(spacing: 0) {
                            AddressEditBar(app: app, browser: browser, addressFocusRequest: addressFocusRequest)
                            Divider()
                        }
                        .background(.bar)
                    } else {
                        AddressEditBar(app: app, browser: browser, addressFocusRequest: addressFocusRequest)
                            .background(.bar)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: position == .top ? .top : .bottom)
            } else if hidesBottomBar {
                EmptyView()
            } else {
                PhoneMorphingBar(
                    app: app,
                    browser: browser,
                    browserAgent: browserAgent,
                    scriptStore: scriptStore,
                    voice: voice,
                    actions: actions,
                    position: position,
                    containerWidth: containerWidth,
                    safeAreaBottom: safeAreaBottom,
                    isLandscape: isLandscape,
                    progress: browser.showsForumsHome ? 0 : min(1, max(0, progressModel.progress)),
                    reduceMotion: reduceMotion,
                    reduceTransparency: reduceTransparency,
                    increasedContrast: increasedContrast,
                    onEdit: {
                        browser.expandChrome(deferIfTracking: false)
                        browser.setEditingAddress(true)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: position == .top ? .top : .bottom)
                .ignoresSafeArea([.container, .keyboard], edges: position == .bottom ? .bottom : [])
            }
        }
    }
}

/// Isolates 120 Hz scroll-progress observation to the floating bar overlay on iPad narrow/portrait
/// windows while keeping `PhoneMorphingBar` mounted across 850 pt split-layout rotations.
private struct PhoneMorphingBarHost: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var progressModel: BrowserBarProgressModel
    var browserAgent: BrowserAgentSession
    var scriptStore: ScriptStore
    @ObservedObject var voice: VoiceController
    @ObservedObject var router: PresentationRouter
    let hasSplitContext: Bool
    let actions: BrowserActions
    let addressFocusRequest: Int
    let containerWidth: CGFloat
    let safeAreaBottom: CGFloat
    let isLandscape: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool

    private var isActiveMorphingBar: Bool {
        if let splitLayout = router.splitLayout {
            return !splitLayout
        }
        return !hasSplitContext
    }

    private var resolvedPosition: BrowserBarPosition {
        app.settings.browserBarPosition.resolved(isSplit: false)
    }

    private var isAnyKeyboardVisible: Bool {
        browser.isSystemKeyboardVisible || browser.isPageFormInputFocused
    }

    private var hidesBottomBar: Bool {
        guard resolvedPosition == .bottom else { return false }
        if voice.showsBar || browser.isPageFormInputFocused {
            return true
        }
        return isAnyKeyboardVisible && !app.isAIViewShown && app.rootPresentation == nil
    }

    var body: some View {
        let _ = router.splitLayout
        let position = resolvedPosition
        let isEligible = isActiveMorphingBar && app.homePath.isEmpty
        let showsEditBar = isEligible && browser.isEditingAddress
        let showsMorphBar = isEligible && !browser.isEditingAddress && !hidesBottomBar
        let liveWidth = PhoneBrowser<EmptyView>.normalSceneWindow()?.bounds.width ?? containerWidth
        let liveSafeBottom = PhoneBrowser<EmptyView>.normalSceneWindow()?.safeAreaInsets.bottom ?? safeAreaBottom

        Group {
            if showsEditBar {
                Group {
                    if position == .top {
                        VStack(spacing: 0) {
                            AddressEditBar(app: app, browser: browser, addressFocusRequest: addressFocusRequest)
                            Divider()
                        }
                        .background(.bar)
                    } else {
                        AddressEditBar(app: app, browser: browser, addressFocusRequest: addressFocusRequest)
                            .background(.bar)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: position == .top ? .top : .bottom)
            } else {
                PhoneMorphingBar(
                    app: app,
                    browser: browser,
                    browserAgent: browserAgent,
                    scriptStore: scriptStore,
                    voice: voice,
                    actions: actions,
                    position: position,
                    containerWidth: liveWidth,
                    safeAreaBottom: liveSafeBottom,
                    isLandscape: isLandscape,
                    progress: browser.showsForumsHome ? 0 : min(1, max(0, progressModel.progress)),
                    reduceMotion: reduceMotion,
                    reduceTransparency: reduceTransparency,
                    increasedContrast: increasedContrast,
                    onEdit: {
                        browser.expandChrome(deferIfTracking: false)
                        browser.setEditingAddress(true)
                    }
                )
                .opacity(showsMorphBar ? 1 : 0)
                .allowsHitTesting(showsMorphBar)
                .accessibilityHidden(!showsMorphBar)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: position == .top ? .top : .bottom)
                .ignoresSafeArea([.container, .keyboard], edges: position == .bottom ? .bottom : [])
            }
        }
    }
}

/// One glass capsule that morphs smoothly between expanded bar (`p = 0`) and domain pill (`p = 1`).
/// Uses SwiftUI's native animatable layout/effect modifiers (`frame`, `padding`, `opacity`, `scaleEffect`)
/// rather than composite `Animatable` conformance so UIKit-backed `Menu` buttons and accessibility
/// visibility remain live across spring transitions.
struct PhoneMorphingBar: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    var browserAgent: BrowserAgentSession
    var scriptStore: ScriptStore
    @ObservedObject var voice: VoiceController
    let actions: BrowserActions
    let position: BrowserBarPosition
    let containerWidth: CGFloat
    let safeAreaBottom: CGFloat
    let isLandscape: Bool
    var progress: CGFloat
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool
    let onEdit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isAgentWorking: Bool {
        browserAgent.isRunning || app.activeResearch != nil
    }

    private var scriptBadge: ToolbarScriptBadgeSummary {
        app.toolbarScriptBadgeSummary
    }

    private var domainText: String {
        let host = BrowserAddress.host(browser.currentURL)
        if !host.isEmpty { return host }
        let display = BrowserAddress.display(browser.currentURL)
        return display.isEmpty ? browser.pageTitle : display
    }

    private var isSecurePage: Bool {
        browser.currentURL?.scheme?.lowercased() == "https"
    }

    private var answerPost: Int? {
        guard !browser.showsForumsHome, app.pageContext.state == .topic else { return nil }
        return app.pageContext.acceptedAnswerPost
    }

    var body: some View {
        let effectiveP: CGFloat = if browser.showsForumsHome {
            0
        } else if reduceMotion {
            browser.isChromeMinimized ? 1 : 0
        } else {
            min(1, max(0, progress))
        }
        morphingCapsule(at: effectiveP, snapsGeometry: reduceMotion)
            .frame(maxWidth: .infinity, alignment: .center)
            .ignoresSafeArea(.container, edges: position == .bottom ? .bottom : [])
    }

    @ViewBuilder
    private func morphingCapsule(at p: CGFloat, snapsGeometry: Bool = false) -> some View {
        let expandedFont = BrowserBarFontMetrics.expandedFontSize(for: dynamicTypeSize)
        let collapsedFont = BrowserBarFontMetrics.collapsedFontSize(for: dynamicTypeSize)
        let domainWidth = BrowserBarFontMetrics.measuredWidth(of: domainText, fontSize: collapsedFont)

        let expandedW = BrowserBarMorphMetrics.expandedWidth(containerWidth: containerWidth)
        let collapsedW = BrowserBarMorphMetrics.collapsedWidth(
            domainWidth: domainWidth,
            isAgentWorking: isAgentWorking,
            scriptCount: scriptBadge.count
        )
        let expandedH = BrowserBarMorphMetrics.expandedHeight(isLandscape: isLandscape)
        let collapsedH = BrowserBarMorphMetrics.collapsedHeight(collapsedFontSize: collapsedFont)

        let barWidth = BrowserBarMorphMetrics.lerp(expandedW, collapsedW, p)
        let barHeight = BrowserBarMorphMetrics.lerp(expandedH, collapsedH, p)
        let outerHPad = BrowserBarMorphMetrics.lerp(6, 3, p)
        let itemGap = BrowserBarMorphMetrics.lerp(2, 0, p)
        let fontSize = BrowserBarMorphMetrics.lerp(expandedFont, collapsedFont, p)

        let bottomOffset = BrowserBarMorphMetrics.bottomEdgeFromScreen(safeAreaBottom: safeAreaBottom, progress: p)
        let topOffset = BrowserBarMorphMetrics.topEdgeFromSafeArea(progress: p)
        let isCollapsedHalf = !browser.showsForumsHome && p >= 0.5
        let extraHit = isCollapsedHalf ? max(0, BrowserBarMorphMetrics.minHitTargetHeight - barHeight) : 0
        let capsuleAlignment: Alignment = position == .bottom ? .bottom : .top

        // Keep `expandedMorphItems` permanently mounted inside a single `ZStack` over one
        // continuous glass capsule so UIKit-backed controls (`Menu`, `PhoneAddressTitleButton`)
        // never tear down and recreate mid-spring across `p = 0.5`.
        ZStack(alignment: capsuleAlignment) {
            if browser.showsForumsHome {
                HStack(spacing: itemGap) {
                    homeItems
                }
                .padding(.horizontal, outerHPad)
                .frame(width: barWidth, height: barHeight)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Browser bar", comment: "VoiceOver container label of the expanded browser bar"))
                .accessibilityIdentifier("browserBar")
            } else {
                HStack(spacing: itemGap) {
                    expandedMorphItems(
                        p: snapsGeometry ? 0 : p,
                        barHeight: barHeight,
                        fontSize: snapsGeometry ? expandedFont : fontSize,
                        isExpandedHalf: !isCollapsedHalf,
                        sideButtonsHitTarget: !isCollapsedHalf && (snapsGeometry || p < 0.35)
                    )
                }
                .padding(.horizontal, outerHPad)
                .frame(width: barWidth, height: barHeight)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Browser bar", comment: "VoiceOver container label of the expanded browser bar"))
                .accessibilityIdentifier("browserBar")
                .opacity(isCollapsedHalf ? 0 : 1)
                .allowsHitTesting(!isCollapsedHalf)
                .accessibilityHidden(isCollapsedHalf)

                if isCollapsedHalf {
                    Button {
                        DCHaptics.tap()
                        browser.expandChrome(deferIfTracking: false)
                    } label: {
                        collapsedPillInner(fontSize: snapsGeometry ? collapsedFont : fontSize)
                            .padding(.horizontal, outerHPad)
                            .frame(width: barWidth, height: barHeight)
                            .padding(position == .bottom ? .top : .bottom, extraHit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(collapsedAccessibilityLabel)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("browserChromeStrip")
                }
            }
        }
        .background(alignment: capsuleAlignment) {
            Color.clear
                .frame(width: barWidth, height: barHeight)
                .modifier(
                    PhoneBarGlassSurface(
                        reduceTransparency: reduceTransparency,
                        increasedContrast: increasedContrast
                    )
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.bottom, position == .bottom ? bottomOffset : 0)
        .padding(.top, position == .top ? topOffset : 0)
    }

    @ViewBuilder
    private var homeItems: some View {
        PhoneBackButton(browser: browser, isActive: true)
            .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
        ForumMenuButton(app: app, browser: browser, actions: actions)
            .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
        Spacer(minLength: 0)
        BrowserTabsButton(app: app)
            .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
        if app.showsVoiceButton {
            VoiceBarButton(voice: app.voice)
        }
        if browser.currentURL != nil {
            PhoneAIButton(
                app: app,
                voice: app.voice,
                router: app.router,
                podcast: app.podcast,
                isAvailable: app.isDrawerAvailable,
                onOpen: {
                    browser.hideForumsHome()
                    actions.openAssistant()
                }
            )
        }
    }

    @ViewBuilder
    private func expandedMorphItems(
        p: CGFloat,
        barHeight: CGFloat,
        fontSize: CGFloat,
        isExpandedHalf: Bool,
        sideButtonsHitTarget: Bool
    ) -> some View {
        let btnOpacity = BrowserBarMorphMetrics.sideButtonOpacity(progress: p)
        let btnScale = BrowserBarMorphMetrics.sideButtonScale(progress: p)
        let slotWidth = BrowserBarMorphMetrics.sideButtonSlotWidth(progress: p)
        let fieldFill = BrowserBarMorphMetrics.addressFieldFillOpacity(
            progress: p,
            isDark: colorScheme == .dark
        )
        let visualFieldHeight = max(30, barHeight - BrowserBarMorphMetrics.lerp(isLandscape ? 12 : 14, 2, p))
        let rowHeight = isExpandedHalf ? max(DCTheme.controlHeight, visualFieldHeight) : visualFieldHeight

        if isExpandedHalf {
            PhoneBackButton(browser: browser, isActive: isExpandedHalf)
                .scaleEffect(btnScale)
                .opacity(btnOpacity)
                .frame(width: slotWidth, height: DCTheme.controlHeight)
                .allowsHitTesting(sideButtonsHitTarget)
        }

        HStack(spacing: 0) {
            if isExpandedHalf {
                ForumMenuButton(
                    app: app,
                    browser: browser,
                    actions: actions,
                    avatarSize: isLandscape ? 22 : 26
                )
                .scaleEffect(btnScale)
                .opacity(btnOpacity)
                .frame(width: slotWidth, height: DCTheme.controlHeight)
                .allowsHitTesting(sideButtonsHitTarget)
            }

            PhoneAddressTitleButton(
                domainText: domainText,
                fullAddressDisplay: BrowserAddress.display(browser.currentURL),
                isSecurePage: isSecurePage,
                fontSize: fontSize,
                minHeight: rowHeight,
                isActive: isExpandedHalf,
                onEdit: onEdit
            )
            .frame(maxWidth: .infinity, minHeight: rowHeight)

            if isExpandedHalf, let answerPost, btnOpacity > 0.05 {
                SolvedAnswerChip(postNumber: answerPost) {
                    app.jumpToCitation(answerPost)
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .opacity(btnOpacity)
                .scaleEffect(btnScale)
            }

            if isExpandedHalf {
                PhoneReloadButton(browser: browser)
                    .scaleEffect(btnScale)
                    .opacity(btnOpacity)
                    .frame(width: slotWidth, height: DCTheme.controlHeight)
                    .allowsHitTesting(sideButtonsHitTarget)
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
        .background {
            if isExpandedHalf, fieldFill > 0.001 {
                Capsule()
                    .fill(DCTheme.ink.opacity(fieldFill))
                    .frame(height: visualFieldHeight)
            }
        }
        .overlay(alignment: .bottom) {
            if isExpandedHalf {
                LoadingLine(progress: browser.estimatedProgress, isLoading: browser.isLoading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, max(0, (rowHeight - visualFieldHeight) / 2) + 2)
            }
        }
        .contentShape(Capsule())

        if isExpandedHalf {
            BrowserTabsButton(app: app, isActive: isExpandedHalf && sideButtonsHitTarget)
                .frame(width: slotWidth, height: DCTheme.controlHeight)
                .scaleEffect(btnScale)
                .opacity(btnOpacity)
                .allowsHitTesting(sideButtonsHitTarget)

            PhoneAIButton(
                app: app,
                voice: app.voice,
                router: app.router,
                podcast: app.podcast,
                isAvailable: app.isDrawerAvailable && browser.currentURL != nil,
                onOpen: actions.openAssistant
            )
            .scaleEffect(btnScale)
            .opacity(btnOpacity)
            .frame(width: slotWidth, height: DCTheme.controlHeight)
            .allowsHitTesting(sideButtonsHitTarget)
        }
    }

    @ViewBuilder
    private func collapsedPillInner(fontSize: CGFloat) -> some View {
        HStack(spacing: 6) {
            if isAgentWorking {
                DCAgentRing(size: 16, lineWidth: 2.5, isTurning: true, isEnabled: true)
            } else {
                Image(systemName: isSecurePage ? "lock.fill" : "globe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DCTheme.inkMuted)
                    .accessibilityHidden(true)
            }
            Text(verbatim: domainText)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(DCTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityHidden(true)
            if isAgentWorking, scriptBadge.isVisible {
                CollapsedScriptsSeal(summary: scriptBadge)
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay(alignment: .bottom) {
            LoadingLine(progress: browser.estimatedProgress, isLoading: browser.isLoading)
                .padding(.horizontal, 12)
                .padding(.bottom, 1)
        }
    }

    private var collapsedAccessibilityLabel: Text {
        let host = BrowserAddress.host(browser.currentURL)
        if isAgentWorking {
            if host.isEmpty {
                return Text("Show browser bar, Agent working", comment: "Collapsed browser pill accessibility label while the Agent is working and no host is shown")
            }
            return Text("Show browser bar, \(host), Agent working", comment: "Collapsed browser pill accessibility label while the Agent is working; placeholder is the website domain")
        }
        if host.isEmpty {
            return Text("Show browser bar")
        }
        return Text("Show browser bar, \(host)", comment: "Collapsed browser pill accessibility label; placeholder is the website domain")
    }
}

/// Glass capsule material: Liquid Glass on iOS 26+, `.bar` material below, solid `surface` + `borderStrong`
/// when Reduce Transparency or Increase Contrast is enabled.
private struct PhoneBarGlassSurface: ViewModifier {
    let reduceTransparency: Bool
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        if reduceTransparency || increasedContrast {
            content
                .background(DCTheme.surface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(DCTheme.borderStrong, lineWidth: 1)
                }
        } else if #available(iOS 26.0, *) {
            content
                .background {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular, in: .capsule)
                        .allowsHitTesting(false)
                }
        } else {
            content
                .background(.bar, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: DCTheme.hairlineWidth)
                }
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        }
    }
}

/// UIKit-backed Back button: short tap navigates back immediately without menu delay,
/// long press presents the Back/Forward history menu (including Forward even when
/// `canNavigateBack` is false), and at accessibility Dynamic Type sizes long press shows
/// the system Large Content Viewer.
private struct PhoneBackButton: UIViewRepresentable {
    @ObservedObject var browser: ForumBrowserModel
    var isActive: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> ControlView {
        let view = ControlView()
        configure(view)
        return view
    }

    func updateUIView(_ uiView: ControlView, context: Context) {
        configure(uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ControlView, context: Context) -> CGSize {
        CGSize(
            width: max(0, proposal.width ?? DCTheme.controlHeight),
            height: max(0, proposal.height ?? DCTheme.controlHeight)
        )
    }

    private func configure(_ view: ControlView) {
        let canBack = browser.canNavigateBack
        let canForward = browser.canGoForward && !browser.showsForumsHome
        let reduceMotion = reduceMotion
        view.browser = browser
        view.canNavigateBack = canBack
        view.onBack = { [weak browser] in
            guard let browser, browser.canNavigateBack else { return }
            withAnimation(DCMotion.respecting(reduceMotion)) {
                browser.navigateBack()
            }
        }
        view.isHidden = !isActive
        view.isUserInteractionEnabled = isActive
        view.isAccessibilityElement = isActive
        view.accessibilityElementsHidden = !isActive
        view.iconView.tintColor = UIColor(canBack ? DCTheme.ink : DCTheme.inkFaint)
        let backLabel = String(localized: "Back")
        view.accessibilityLabel = backLabel
        view.largeContentTitle = backLabel
        view.accessibilityTraits = canBack ? .button : [.button, .notEnabled]
        view.accessibilityHint = (canBack || canForward)
            ? String(localized: "Touch and hold for history", comment: "Accessibility hint on the Back button when back or forward history is available")
            : nil
        if canForward {
            view.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "Forward")) { [weak browser] _ in
                    guard let browser, browser.canGoForward, !browser.showsForumsHome else { return false }
                    browser.goForward()
                    return true
                }
            ]
        } else {
            view.accessibilityCustomActions = nil
        }
    }

    final class ControlView: UIControl, UIGestureRecognizerDelegate, UILargeContentViewerInteractionDelegate {
        let iconView = UIImageView()
        weak var browser: ForumBrowserModel?
        var canNavigateBack = false
        var onBack: (() -> Void)?
        private var isTapCandidate = false
        private var didTriggerForActiveTouch = false
        private var isShowingLargeContent = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = true
            isAccessibilityElement = true
            accessibilityIdentifier = "browserBack"

            showsLargeContentViewer = true
            scalesLargeContentImage = true
            largeContentImage = UIImage(systemName: "chevron.backward")
            let lcvInteraction = UILargeContentViewerInteraction(delegate: self)
            addInteraction(lcvInteraction)
            lcvInteraction.gestureRecognizerForExclusionRelationship.addTarget(
                self,
                action: #selector(handleLargeContentGesture(_:))
            )

            let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            iconView.image = UIImage(systemName: "chevron.backward", withConfiguration: config)
            iconView.contentMode = .center
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.isUserInteractionEnabled = false
            iconView.isAccessibilityElement = false
            addSubview(iconView)

            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tapRecognizer.cancelsTouchesInView = false
            tapRecognizer.delaysTouchesBegan = false
            tapRecognizer.delaysTouchesEnded = false
            tapRecognizer.delegate = self
            tapRecognizer.require(toFail: lcvInteraction.gestureRecognizerForExclusionRelationship)
            addGestureRecognizer(tapRecognizer)

            let menuInteraction = UIContextMenuInteraction(delegate: self)
            addInteraction(menuInteraction)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func handleLargeContentGesture(_ recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                isShowingLargeContent = true
                isTapCandidate = false
                didTriggerForActiveTouch = true
            case .ended, .cancelled, .failed:
                isShowingLargeContent = false
            default:
                break
            }
        }

        func largeContentViewerInteraction(
            _ interaction: UILargeContentViewerInteraction,
            didEndOn item: (any UILargeContentViewerItem)?,
            at point: CGPoint
        ) {
            isShowingLargeContent = false
            if item as AnyObject === self, bounds.contains(point), canNavigateBack {
                onBack?()
            }
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !didTriggerForActiveTouch, !isShowingLargeContent else { return }
            didTriggerForActiveTouch = true
            isTapCandidate = false
            if canNavigateBack { onBack?() }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            isTapCandidate = touches.count == 1
            didTriggerForActiveTouch = false
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            guard isTapCandidate, let touch = touches.first else { return }
            if !bounds.insetBy(dx: -16, dy: -16).contains(touch.location(in: self)) {
                isTapCandidate = false
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            isTapCandidate = false
            super.touchesCancelled(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            let shouldTrigger = !didTriggerForActiveTouch
                && isTapCandidate
                && canNavigateBack
                && (touches.first.map { bounds.insetBy(dx: -16, dy: -16).contains($0.location(in: self)) } ?? false)
            isTapCandidate = false
            super.touchesEnded(touches, with: event)
            if shouldTrigger {
                didTriggerForActiveTouch = true
                onBack?()
            }
        }

        override func accessibilityActivate() -> Bool {
            guard canNavigateBack else { return false }
            onBack?()
            return true
        }

        override func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard !UILargeContentViewerInteraction.isEnabled else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.makeHistoryMenu()
            }
        }

        override func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configuration: UIContextMenuConfiguration,
            highlightPreviewForItemWithIdentifier identifier: any NSCopying
        ) -> UITargetedPreview? {
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return nil }
            let params = UIPreviewParameters()
            params.backgroundColor = .clear
            params.visiblePath = UIBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
            return UITargetedPreview(view: self, parameters: params)
        }

        override func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willDisplayMenuFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            isTapCandidate = false
            didTriggerForActiveTouch = true
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        }

        @MainActor
        private func makeHistoryMenu() -> UIMenu {
            guard let browser else {
                return UIMenu(children: [])
            }
            let back = Array(browser.backHistory.prefix(12))
            let forward = browser.showsForumsHome ? [] : Array(browser.forwardHistory.prefix(12))
            var children: [UIMenuElement] = []
            if !forward.isEmpty {
                children.append(
                    UIMenu(
                        title: String(localized: "Forward"),
                        options: .displayInline,
                        children: forward.reversed().map {
                            historyAction($0, systemImage: "chevron.forward", browser: browser)
                        }
                    )
                )
            }
            var backActions: [UIMenuElement] = []
            if browser.isForumsHomeRequested, let url = browser.currentURL {
                let title = browser.pageTitle.isEmpty ? BrowserAddress.host(url) : browser.pageTitle
                let subtitle = BrowserAddress.display(url)
                backActions.append(
                    UIAction(
                        title: title,
                        subtitle: subtitle,
                        image: UIImage(systemName: "chevron.backward")
                    ) { [weak browser] _ in
                        browser?.hideForumsHome()
                    }
                )
            }
            backActions.append(
                contentsOf: back.map {
                    historyAction($0, systemImage: "chevron.backward", browser: browser)
                }
            )
            if !backActions.isEmpty {
                children.append(
                    UIMenu(
                        title: String(localized: "Back"),
                        options: .displayInline,
                        children: backActions
                    )
                )
            }
            if children.isEmpty {
                children.append(
                    UIAction(
                        title: String(
                            localized: "No history yet",
                            comment: "Browser bar Back button history menu with no pages to go back or forward to"
                        ),
                        attributes: .disabled
                    ) { _ in }
                )
            }
            return UIMenu(children: children)
        }

        @MainActor
        private func historyAction(
            _ item: WKBackForwardListItem,
            systemImage: String,
            browser: ForumBrowserModel
        ) -> UIAction {
            let title = (item.title?.isEmpty == false) ? (item.title ?? "") : BrowserAddress.host(item.url)
            let subtitle = BrowserAddress.display(item.url)
            return UIAction(
                title: title,
                subtitle: subtitle,
                image: UIImage(systemName: systemImage)
            ) { [weak browser] _ in
                browser?.go(to: item)
            }
        }
    }
}

private struct PhoneReloadButton: View {
    @ObservedObject var browser: ForumBrowserModel

    private var isStopping: Bool {
        browser.isLoading && !browser.showsForumsHome
    }

    private var isEnabled: Bool {
        isStopping || browser.currentURL != nil
    }

    var body: some View {
        Button {
            DCHaptics.tap()
            if isStopping {
                browser.stopLoading()
            } else {
                browser.reload()
            }
        } label: {
            Image(systemName: isStopping ? "xmark" : "arrow.clockwise")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isEnabled ? DCTheme.ink : DCTheme.inkFaint)
                .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(isStopping ? Text("Stop loading") : Text("Reload"))
        .accessibilityShowsLargeContentViewer {
            Label(
                isStopping ? "Stop loading" : "Reload",
                systemImage: isStopping ? "xmark" : "arrow.clockwise"
            )
        }
        .accessibilityIdentifier("browserReload")
    }
}

private struct CollapsedScriptsSeal: View {
    let summary: ToolbarScriptBadgeSummary

    private var fill: Color {
        if !summary.isGlobalEnabled { return DCTheme.inkMuted }
        return summary.errorCount > 0 ? DCTheme.cinnabar : DCTheme.ink
    }

    private var foreground: Color {
        summary.errorCount > 0 && summary.isGlobalEnabled ? DCTheme.onCinnabar : DCTheme.ground
    }

    var body: some View {
        Text(verbatim: "\(summary.count)")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Domain button inside the expanded address field: single-line middle-truncated domain text,
/// tap (or VoiceOver activate) to edit the full address, and Large Content Viewer at
/// accessibility Dynamic Type sizes.
private struct PhoneAddressTitleButton: View {
    let domainText: String
    let fullAddressDisplay: String
    let isSecurePage: Bool
    let fontSize: CGFloat
    let minHeight: CGFloat
    let isActive: Bool
    let onEdit: () -> Void

    private var accessibilityLabelText: Text {
        if domainText.isEmpty {
            return Text("Address field", comment: "Expanded browser bar address button when no domain is loaded")
        }
        return Text("Address field: \(domainText)", comment: "Expanded browser bar address button; placeholder is the website domain")
    }

    private var accessibilityValueString: String {
        (!fullAddressDisplay.isEmpty && fullAddressDisplay != domainText) ? fullAddressDisplay : ""
    }

    var body: some View {
        Button {
            DCHaptics.tap()
            onEdit()
        } label: {
            HStack(spacing: 0) {
                Text(verbatim: domainText)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(DCTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: minHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(Text(verbatim: accessibilityValueString))
        .accessibilityShowsLargeContentViewer {
            Label {
                if domainText.isEmpty {
                    Text("Address field", comment: "Expanded browser bar address button when no domain is loaded")
                } else {
                    Text(verbatim: domainText)
                }
            } icon: {
                Image(systemName: isSecurePage ? "lock.fill" : "globe")
            }
        }
        .accessibilityIdentifier("browserTitle")
    }
}

private struct SolvedAnswerChip: View {
    let postNumber: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                Text(verbatim: "#\(postNumber)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .fixedSize()
            .foregroundStyle(DCTheme.success)
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background(DCTheme.success.opacity(0.12), in: Capsule())
            .frame(minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Solved · answer at #\(postNumber)", comment: "iPhone bar hint: the topic has an accepted answer; the placeholder is its post number"))
        .accessibilityHint(Text("Jumps to the answer", comment: "Accessibility hint of the solved hint in the iPhone bar"))
        .accessibilityIdentifier("acceptedAnswerHint")
    }
}

// MARK: - Title capsule

/// Page title over the host; on Home "Search or enter a forum address". Tap
/// edits the address; long press lists the history. The not-a-forum icon,
/// the solved hint and the ad shield sit inside.
struct PhoneTitleCapsule: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    /// A fill of its own (top bar, and before Liquid Glass).
    var filled = true
    /// The capsule's width. A menu label in a toolbar takes its ideal width,
    /// so the title is given the room explicitly to truncate in.
    var width: CGFloat = 0
    let onEdit: () -> Void

    private var showsHome: Bool { browser.showsForumsHome }

    private var answerPost: Int? {
        guard !showsHome, app.pageContext.state == .topic else { return nil }
        return app.pageContext.acceptedAnswerPost
    }

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                historyMenu
            } label: {
                titleLabel
            } primaryAction: {
                onEdit()
            }
            .menuOrder(.fixed)
            .tint(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityHint(accessibilityHint)
            .accessibilityIdentifier("browserTitle")

            if let answerPost {
                answerChip(answerPost)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight)
        .background {
            if filled { Capsule().fill(Color(uiColor: .tertiarySystemFill)) }
        }
        .overlay(alignment: .bottom) {
            if !showsHome {
                LoadingLine(progress: browser.estimatedProgress, isLoading: browser.isLoading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 2)
            }
        }
        .contentShape(Capsule())
    }

    private var canSearch: Bool { app.searchPageURL(query: "a") != nil }

    private var homePrompt: Text {
        canSearch
            ? Text("Search or enter address", comment: "iPhone bar on Home: placeholder of the search and address field")
            : Text("Enter an address")
    }

    @ViewBuilder
    private var titleLabel: some View {
        if showsHome {
            HStack(spacing: 8) {
                Image(systemName: canSearch ? "magnifyingglass" : "globe")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                homePrompt
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(width: titleWidth, alignment: .leading)
            .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight, alignment: .leading)
            .contentShape(Rectangle())
        } else {
            pageTitleLabel
        }
    }

    private var pageTitleLabel: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(browser.pageTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: titleWidth, alignment: .leading)
        .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// What the solved-answer chip leaves of the capsule (nil: no limit).
    private var titleWidth: CGFloat? {
        guard width > 0 else { return nil }
        var reserved: CGFloat = 16
        if answerPost != nil { reserved += 64 }
        return max(60, width - reserved)
    }

    private var subtitle: String {
        BrowserAddress.host(browser.currentURL)
    }

    private var accessibilityTitle: Text {
        if showsHome { return homePrompt }
        return Text(verbatim: "\(browser.pageTitle), \(BrowserAddress.display(browser.currentURL))")
    }

    private var accessibilityHint: Text {
        Text("Tap to enter an address. Touch and hold for history.", comment: "Accessibility hint of the iPhone bar title")
    }

    @ViewBuilder
    private var historyMenu: some View {
        let back = Array(browser.backHistory.prefix(12))
        let forward = Array(browser.forwardHistory.prefix(12))
        if !forward.isEmpty {
            Section("Forward") {
                ForEach(forward.reversed(), id: \.self) { historyItem($0) }
            }
        }
        if !back.isEmpty {
            Section("Back") {
                ForEach(back, id: \.self) { historyItem($0) }
            }
        }
        if back.isEmpty, forward.isEmpty {
            Text("No history yet", comment: "iPhone bar title's history menu with no pages to go back or forward to")
        }
    }

    private func historyItem(_ item: WKBackForwardListItem) -> some View {
        Button {
            browser.go(to: item)
        } label: {
            Text(item.title?.isEmpty == false ? item.title ?? "" : BrowserAddress.host(item.url))
            Text(BrowserAddress.display(item.url))
        }
    }

    /// "Solved · answer at #N": jumps to the accepted answer.
    private func answerChip(_ number: Int) -> some View {
        Button {
            // The same jump as a citation in the drawer (§4.5).
            app.jumpToCitation(number)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                Text(verbatim: "#\(number)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .fixedSize()
            .foregroundStyle(DCTheme.success)
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background(DCTheme.success.opacity(0.12), in: Capsule())
            .frame(minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Solved · answer at #\(number)", comment: "iPhone bar hint: the topic has an accepted answer; the placeholder is its post number"))
        .accessibilityHint(Text("Jumps to the answer", comment: "Accessibility hint of the solved hint in the iPhone bar"))
        .accessibilityIdentifier("acceptedAnswerHint")
    }
}

/// Ad blocking on the current site, for This page and the forum menu.
@MainActor
struct SiteBlocking {
    let app: AppModel
    let url: URL?

    var status: ContentBlockingStatus { app.contentBlockingStatus(for: url) }

    var statusTitle: String {
        switch status {
        case .off: String(localized: "Ad blocking is off")
        case .blocking(let ads, _):
            ads ? String(localized: "Ads blocked on this site") : String(localized: "Trackers blocked on this site")
        case .allowedSite: String(localized: "Ads allowed on this site")
        case .signInPage: String(localized: "Nothing blocked on sign-in pages")
        }
    }

    var symbol: String {
        switch status {
        case .blocking: "shield.lefthalf.filled"
        case .off: "shield"
        case .allowedSite, .signInPage: "shield.slash"
        }
    }

    var tint: Color {
        if case .blocking = status { return DCTheme.success }
        return .secondary
    }

    /// Allow / block ads on the current site (nil when it doesn't apply).
    var toggle: (title: String, systemImage: String, action: () -> Void)? {
        guard let host = url?.host.flatMap(ContentBlockingRules.normalizedHost) else { return nil }
        let app = app, url = url
        switch status {
        case .blocking:
            return (String(localized: "Allow ads on \(host)", comment: "Menu item; the placeholder is a website host"), "shield.slash", {
                DCHaptics.tap()
                app.setAdsAllowed(true, on: url)
            })
        case .allowedSite:
            return (String(localized: "Block ads on \(host)", comment: "Menu item; the placeholder is a website host"), "shield.lefthalf.filled", {
                DCHaptics.tap()
                app.setAdsAllowed(false, on: url)
            })
        case .off, .signInPage:
            return nil
        }
    }

    /// The forum menu's "Block Ads on This Site" switch: on while this page
    /// is filtered. Turning it on with blocking off turns blocking on.
    var isBlockingHere: Binding<Bool>? {
        guard url?.host.flatMap(ContentBlockingRules.normalizedHost) != nil, status != .signInPage else { return nil }
        let app = app, url = url, status = status
        return Binding(
            get: { if case .blocking = status { return true } else { return false } },
            set: { blocks in
                DCHaptics.tap()
                if blocks {
                    app.setAdsAllowed(false, on: url)
                    if status == .off { app.turnOnContentBlocking() }
                } else {
                    app.setAdsAllowed(true, on: url)
                }
            }
        )
    }
}

/// The address-bar menu's app-link entries for the current site: the
/// per-site switch and "Open in app" (https pages).
struct AppLinkMenuItems: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    let url: URL?

    var body: some View {
        if let host = url?.host.flatMap(ContentBlockingRules.normalizedHost) {
            Toggle(isOn: Binding(
                get: { app.opensApps(on: url) },
                set: { DCHaptics.tap(); app.setOpensApps($0, on: url) }
            )) {
                Label("Open links in apps on this site", systemImage: "arrow.up.forward.app")
            }
            .accessibilityIdentifier("menuToggleAppLinksOnSite")
            .accessibilityHint(host)
            if url?.scheme?.lowercased() == "https" {
                Button {
                    DCHaptics.tap()
                    browser.openCurrentPageInApp()
                } label: {
                    Label("Open in app", systemImage: "arrow.up.forward.app.fill")
                }
                .accessibilityIdentifier("menuOpenInApp")
            }
        }
    }
}

// MARK: - AI button

/// Opens the drawer at medium; a long press starts voice (when set up). A
/// dot when the topic has new replies and another row holds the hint row's
/// place (`BottomLayer.showsNewRepliesDot`).
struct PhoneAIButton: View {
    /// The Agent's mark in the bar: an open gold ring of `ring-width`, no icon.
    static let ringSize: CGFloat = 40
    @ObservedObject var app: AppModel
    @ObservedObject var voice: VoiceController
    /// The layer's inputs, for the dot.
    @ObservedObject var router: PresentationRouter
    @ObservedObject var podcast: PodcastController
    let isAvailable: Bool
    let onOpen: () -> Void
    @State private var completedBrowserAgentBounce = 0
    @State private var observedAgentID: ObjectIdentifier?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var browserAgent: BrowserAgentSession { app.browserAgent }
    private var showsNewRepliesDot: Bool { app.showsNewRepliesDot }

    private var finishedBounceValue: String? {
        if reduceMotion { return nil }
        if let id = app.readyAnswer?.id { return id.uuidString }
        if completedBrowserAgentBounce > 0 { return "agent-\(completedBrowserAgentBounce)" }
        return nil
    }

    private var accessibilityValueText: Text {
        var parts: [String] = []
        if browserAgent.isRunning {
            parts.append(String(localized: "Working", comment: "Accessibility value of the AI button while the browser agent is working"))
        }
        if showsNewRepliesDot {
            parts.append(String(localized: "New replies", comment: "Accessibility value of the iPhone AI button while its dot says the topic has new replies"))
        }
        if let scriptDesc = app.toolbarScriptAccessibilityDescription {
            parts.append(scriptDesc)
        }
        return Text(verbatim: parts.joined(separator: ", "))
    }

    @ViewBuilder
    private var ringVisual: some View {
        Group {
            if voice.isActive {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isAvailable ? DCTheme.goldInk : DCTheme.inkFaint)
            } else {
                DCAgentRing(
                    size: Self.ringSize,
                    lineWidth: DCTheme.ringWidth,
                    isTurning: browserAgent.isRunning || app.activeResearch != nil,
                    isEnabled: isAvailable
                )
            }
        }
        .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
        .overlay { ResearchRing(app: app) }
        .overlay(alignment: .topTrailing) {
            let badge = app.toolbarScriptBadgeSummary
            if badge.isVisible {
                ScriptCountBadge(summary: badge)
            } else if showsNewRepliesDot {
                NewRepliesDot()
            }
        }
        .contentShape(Circle())
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Button {
                    guard isAvailable else { return }
                    onOpen()
                } label: {
                    ringVisual
                }
                .buttonStyle(.plain)
                .disabled(!isAvailable)
                .accessibilityShowsLargeContentViewer {
                    Label {
                        Text("Agent", comment: "Browser bar button that opens the Agent panel")
                    } icon: {
                        Image(systemName: voice.isActive ? "waveform" : "circle")
                    }
                }
            } else {
                ringVisual
                    .onTapGesture {
                        guard isAvailable else { return }
                        onOpen()
                    }
                    .onLongPressGesture(minimumDuration: 0.45) {
                        guard isAvailable else { return }
                        DCHaptics.tap()
                        voice.toggle()
                    }
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityRemoveTraits(isAvailable ? [] : .isButton)
                    .accessibilityAction { if isAvailable { onOpen() } }
            }
        }
        .onAppear { observedAgentID = ObjectIdentifier(browserAgent) }
        .onChange(of: ObjectIdentifier(browserAgent)) { _, newID in observedAgentID = newID }
        .onChange(of: browserAgent.isRunning) { wasRunning, isRunning in
            let currentID = ObjectIdentifier(browserAgent)
            defer { observedAgentID = currentID }
            if observedAgentID == currentID, wasRunning, !isRunning, !app.isAIViewShown, browserAgent.runs.last != nil {
                completedBrowserAgentBounce &+= 1
            }
        }
        .accessibilityLabel(Text("Agent", comment: "Browser bar button that opens the Agent panel"))
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint(
            isAvailable
                ? Text("Hold to talk", comment: "Accessibility hint of the browser bar Agent ring button")
                : Text(verbatim: "")
        )
        .accessibilityActions {
            if browserAgent.isRunning {
                Button("Stop agent") { browserAgent.stop() }
            }
            if isAvailable {
                Button(voice.isActive ? "End voice" : "Talk to WukongMind") { voice.toggle() }
            }
        }
        .accessibilityIdentifier("aiButton")
    }
}

/// Ask the forum's or browser agent's progress around the AI button (and the
/// split layout's panel toggle); a short arc while the progress is not known,
/// a full ring once the answer is ready and unseen.
struct ResearchRing: View {
    @ObservedObject var app: AppModel

    private var browserAgent: BrowserAgentSession { app.browserAgent }

    var body: some View {
        if browserAgent.isRunning {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityIdentifier("researchRing")
        } else if app.activeResearch != nil {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityIdentifier("researchRing")
        } else if app.readyAnswer != nil {
            Circle()
                .stroke(DCTheme.gold, lineWidth: DCTheme.ringWidth)
                .padding(5)
                .allowsHitTesting(false)
                .accessibilityIdentifier("answerReadyRing")
        }
    }
}

/// The AI button's (or panel toggle's) dot: the topic has new replies
/// (`AppModel.showsNewRepliesDot`). Gold per design system ("New" and "unread" are gold, never cinnabar).
struct NewRepliesDot: View {
    var body: some View {
        Circle()
            .fill(DCTheme.gold)
            .frame(width: 8, height: 8)
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Forum menu

/// The forum avatar; its menu (spec §4.3): the forum and account, page
/// navigation, page actions, ad blocking, other forums and Home.
struct ForumMenuButton: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    let actions: BrowserActions
    var avatarSize: CGFloat = 28

    private var forum: Forum? { app.barForum }
    /// The forum the menu header and leading icon show: only when the page really is that forum (`barForum` falls back to the last forum).
    private var headerForum: Forum? {
        ForumMenuHeader.forum(barForum: forum, pageIsForum: browser.pageContext.isForum, showsHome: showsHome)
    }
    private var showsHome: Bool { browser.showsForumsHome }
    private var pageURL: URL? { showsHome ? nil : browser.currentURL }
    private var topic: ForumTopic? { showsHome ? nil : browser.pageContext.topic }

    var body: some View {
        Menu {
            Section {
                Button(action: actions.showForumsHome) {
                    Label("Home", systemImage: "square.grid.2x2")
                }
                .accessibilityIdentifier("switcherAllForums")
            }
            headerSection
            ControlGroup {
                Button(action: goBack) { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!browser.canNavigateBack)
                Button(action: browser.goForward) { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!browser.canGoForward || showsHome)
                if browser.isLoading, !showsHome {
                    Button(action: browser.stopLoading) { Label("Stop loading", systemImage: "xmark") }
                } else {
                    Button(action: browser.reload) { Label("Reload", systemImage: "arrow.clockwise") }
                        .disabled(pageURL == nil)
                }
                Button(action: goHome) { Label(homeLabel, systemImage: "house") }
                    .accessibilityIdentifier("browserHome")
            }
            // Four icons in one row (the default size wraps Home to its own).
            .controlGroupStyle(.palette)
            .controlSize(.small)
            // A palette keeps the menu open after a tap (the page would
            // change behind it, e.g. Back from Home); these are commands.
            .menuActionDismissBehavior(.enabled)
            pageSection
            if let pageURL {
                ShareLink(item: pageURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("forumMenuShare")
            }
            Section {
                Button { actions.openPanel(.history) } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                Button { actions.openPanel(.settings) } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        } label: {
            avatar
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Text("Page menu", comment: "Browser bar button opening the page and site menu"))
        .accessibilityValue(headerForum.map { Text(verbatim: $0.displayName) } ?? Text(verbatim: ""))
        .accessibilityShowsLargeContentViewer {
            Label {
                Text("Page menu", comment: "Browser bar button opening the page and site menu")
            } icon: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .accessibilityIdentifier("forumSwitcher")
    }

    private var avatar: some View {
        Group {
            if let forum = headerForum {
                ForumIcon(forum: forum, size: avatarSize)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            } else {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DCTheme.ink)
                    .frame(width: avatarSize, height: avatarSize)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
        .contentShape(Rectangle())
    }

    // MARK: Sections

    @ViewBuilder
    private var headerSection: some View {
        Section {
            if headerForum == nil, let host = ForumMenuHeader.plainHost(pageURL) {
                // An ordinary page: its host, no sign-in part (design-unified is silent).
                if let blocks = SiteBlocking(app: app, url: pageURL).isBlockingHere {
                    Menu {
                        Toggle(isOn: blocks) {
                            Label("Block Ads on This Site", systemImage: "shield.lefthalf.filled")
                        }
                        .accessibilityIdentifier("menuToggleAdsOnSite")
                        AppLinkMenuItems(app: app, browser: browser, url: pageURL)
                    } label: {
                        Text(host)
                        Image(systemName: "globe")
                    }
                    .accessibilityIdentifier("forumMenuSite")
                } else {
                    Menu {
                        AppLinkMenuItems(app: app, browser: browser, url: pageURL)
                    } label: {
                        Text(host)
                        Image(systemName: "globe")
                    }
                    .accessibilityIdentifier("forumMenuSite")
                }
            }
            if let forum = headerForum {
                Menu {
                    // A site without a sign-in page offers neither the entry nor its help.
                    if browser.isAuthenticated ? app.accountURL != nil : app.loginURL != nil {
                        Button(action: openAccount) {
                            if browser.isAuthenticated {
                                Label("Open account", systemImage: "person.crop.circle")
                            } else {
                                Label("Sign in", systemImage: "person.badge.key")
                            }
                        }
                        .accessibilityIdentifier("forumMenuAccountOpen")
                    }
                    if app.loginURL != nil {
                        Button(action: actions.showLoginInfo) {
                            Label("Sign-in help", systemImage: "questionmark.circle")
                        }
                        .accessibilityIdentifier("forumMenuSignInHelp")
                    }
                    // Per-site settings live with the forum, not in the root menu.
                    if pageURL != nil, let blocks = SiteBlocking(app: app, url: pageURL).isBlockingHere {
                        Section {
                            Toggle(isOn: blocks) {
                                Label("Block Ads on This Site", systemImage: "shield.lefthalf.filled")
                            }
                            .accessibilityIdentifier("menuToggleAdsOnSite")
                        }
                    }
                } label: {
                    Text(forum.displayName)
                    Text(accountLine(for: forum))
                    Image(systemName: browser.isAuthenticated ? "person.crop.circle.fill" : "person.badge.key")
                }
                .accessibilityIdentifier("forumMenuAccount")
            }
        }
    }

    @ViewBuilder
    private var pageSection: some View {
        Section {
            if let topic = app.currentTopic, self.topic != nil {
                Button(action: app.toggleWatchCurrentTopic) {
                    if app.isWatched(topicKey: topic.topicKey) {
                        Label("Unwatch topic", systemImage: "eye.slash")
                    } else {
                        Label("Watch this topic", systemImage: "eye")
                    }
                }
            }
            if self.topic != nil, browser.canTranslatePostsOnScreen {
                Button(action: actions.translatePosts) {
                    Label("Translate", systemImage: "translate")
                }
                .accessibilityIdentifier("menuTranslatePosts")
            }
        }
    }

    // MARK: Actions

    private var homeLabel: String {
        forum.map { String(localized: "\($0.displayName) home", comment: "Button label: the forum's home page (forum name)") }
            ?? String(localized: "Forums")
    }

    private func accountLine(for forum: Forum) -> String {
        guard browser.isAuthenticated else {
            return String(localized: "\(forum.host) · Not signed in", comment: "Forum menu header; the placeholder is the forum's host")
        }
        if let name = browser.signedInUsername {
            return String(localized: "\(forum.host) · Logged in as \(name)", comment: "Forum menu header; placeholders: the forum's host, the user's forum username")
        }
        return String(localized: "\(forum.host) · Signed in", comment: "Forum menu header; the placeholder is the forum's host")
    }

    private func goBack() {
        browser.navigateBack()
    }

    private func goHome() {
        app.goHome()
    }

    /// Signed in: the user's account page; otherwise the forum's sign-in page.
    private func openAccount() {
        let opened = browser.isAuthenticated ? app.loadAccount() : app.loadLogin()
        if !opened { actions.showForumsHome() }
    }
}


/// What the browser menu's site row shows: the forum only while the page is
/// that forum, otherwise the plain host (never a stale last forum).
enum ForumMenuHeader {
    static func forum(barForum: Forum?, pageIsForum: Bool, showsHome: Bool) -> Forum? {
        pageIsForum && !showsHome ? barForum : nil
    }

    static func plainHost(_ url: URL?) -> String? {
        let host = BrowserAddress.host(url)
        return host.isEmpty ? nil : host
    }
}
