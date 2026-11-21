import SwiftUI
import WebKit

// MARK: - Browser bar (shared morphing glass capsule on iPhone & iPad split)
//
// The page sits in a NavigationStack (no navigation bar) with one floating glass
// capsule driven continuously by scroll progress `p ∈ [0, 1]` (`BrowserBarMorph.swift`):
// - Expanded (`p = 0`):
//   - iPhone / narrow iPad (`split == nil`): Back (tap goes back, long press opens
//     history with Forward), address field (Page menu at leading edge, middle-truncated
//     domain or "Search or enter address" on Home, Reload at trailing edge on pages),
//     Tabs, and the Agent ring. On Home, the bar stays expanded (`p = 0`).
//   - iPad split (`split != nil`): `pageColumnWidth - 24 × 52 pt` across the top
//     of the page column (`top safe area + 6 pt`), holding Back, Forward, centred
//     address field (Page menu, domain, Reload, max 520 pt), Tabs, Mic (when available),
//     and `SplitPanelToggle`.
// - Collapsed (`p = 1`): centred pill (`120…240 × 34 pt` on iPhone, `200 × 34 pt`
//   centred over the page column at `top safe area + 2 pt` on iPad split, `44 pt`
//   hit target) with lock (or 16 pt turning Agent ring + scripts seal while Agent
//   works) and domain; tapping springs back to `p = 0`.
// - While editing the address, `AddressEditBar` replaces the bar. While a page
//   form field raises the keyboard, `p` freezes and the bottom bar hides under
//   the keyboard (top bar stays in place, frozen).

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
    /// iPad split layout: the page column width and AI panel toggle; nil on iPhone / narrow iPad.
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

    private var isSplit: Bool {
        let liveWidth = router.windowWidth > 0 ? router.windowWidth : width
        return router.splitLayout ?? (liveWidth > 0 ? ContentView.usesSplitLayout(width: liveWidth) : split != nil)
    }

    private var isLandscape: Bool {
        verticalSizeClass == .compact
    }

    /// Hardware/container bottom safe area excluding software keyboards so focusing a page
    /// form field or address bar never inflates `expandedBottomInset`.
    private var resolvedSafeAreaBottom: CGFloat {
        BrowserBarFontMetrics.normalSceneSafeAreaBottom()
    }

    private var resolvedContainerWidth: CGFloat {
        if router.windowWidth > 0 { return router.windowWidth }
        if width > 0 { return width }
        return BrowserBarFontMetrics.normalSceneWindow()?.bounds.width ?? 390
    }

    var body: some View {
        let safeAreaBottom = resolvedSafeAreaBottom
        let containerWidth = resolvedContainerWidth
        let resolvedPosition = isSplit ? BrowserBarPosition.top : app.settings.browserBarPosition.resolved(isSplit: false)
        let dockClearance = BrowserBarFontMetrics.bottomDockClearance(
            app: app,
            browser: browser,
            voice: voice,
            isSplit: isSplit,
            position: resolvedPosition,
            safeAreaBottom: safeAreaBottom,
            isLandscape: isLandscape,
            dynamicTypeSize: dynamicTypeSize
        )

        page(dockClearance)
        .background {
            PhoneBarObserverHost(
                app: app,
                browser: browser,
                voice: voice,
                router: router,
                fallbackWidth: containerWidth,
                fallbackSplit: split,
                addressFocusRequest: addressFocusRequest,
                safeAreaBottom: safeAreaBottom,
                isLandscape: isLandscape,
                reduceMotion: reduceMotion
            )
        }
        .overlay {
            if UIDevice.current.userInterfaceIdiom == .phone {
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
            } else {
                PhoneMorphingBarHost(
                    app: app,
                    browser: browser,
                    progressModel: browser.barProgressModel,
                    router: router,
                    browserAgent: app.browserAgent,
                    scriptStore: app.scriptStore,
                    voice: voice,
                    actions: actions,
                    fallbackSplit: split,
                    addressFocusRequest: addressFocusRequest,
                    fallbackWidth: containerWidth,
                    safeAreaBottom: safeAreaBottom,
                    isLandscape: isLandscape,
                    reduceMotion: reduceMotion,
                    reduceTransparency: reduceTransparency,
                    increasedContrast: colorSchemeContrast == .increased
                )
            }
        }
        .onAppear {
            app.barShowsTopicFacts = true
        }
    }
}

/// Always-mounted zero-size observer leaf for the morphing bar.
/// Hanging `.onChange` and `UIResponder.keyboard*Notification` publishers on a dedicated
/// concrete view (never on a `Group` that can become `EmptyView` while the bar is hidden
/// under a page keyboard, Voice Dock, or pushed Settings screen) keeps keyboard-hide and
/// lock transitions live at all times without re-evaluating `PhoneBrowser` at 120 Hz.
private struct PhoneBarObserverHost: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var router: PresentationRouter
    let fallbackWidth: CGFloat
    let fallbackSplit: SplitBarContext?
    let addressFocusRequest: Int
    let safeAreaBottom: CGFloat
    let isLandscape: Bool
    let reduceMotion: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var lastReadyAnswerID: UUID?
    @State private var hasActiveKeyboardSession = false

    private var liveWidth: CGFloat {
        router.windowWidth > 0 ? router.windowWidth : fallbackWidth
    }

    private var isSplit: Bool {
        router.splitLayout ?? (liveWidth > 0 ? ContentView.usesSplitLayout(width: liveWidth) : fallbackSplit != nil)
    }

    private var resolvedPosition: BrowserBarPosition {
        isSplit ? .top : app.settings.browserBarPosition.resolved(isSplit: false)
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
                browser.setSystemKeyboardVisible(false, coalesceHideDuration: .zero)
                browser.setExternalKeyboardFrozen(false)
            }
            .onChange(of: ObjectIdentifier(browser)) { _, _ in
                syncMorphConfiguration()
            }
            .onChange(of: isSplit) { _, _ in
                hasActiveKeyboardSession = false
                browser.setSystemKeyboardVisible(false, coalesceHideDuration: .zero)
                browser.setExternalKeyboardFrozen(false)
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
                PerfProbe.mark("addressEdit.tap")
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
                hasActiveKeyboardSession = true
                updateSystemKeyboardVisibility(from: note, isHideNotification: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { note in
                hasActiveKeyboardSession = true
                updateSystemKeyboardVisibility(from: note, isHideNotification: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard hasActiveKeyboardSession else { return }
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
        let liveSafeBottom = BrowserBarFontMetrics.normalSceneSafeAreaBottom()
        browser.barMorph.updateLayoutConfiguration(
            managesInsets: true,
            isSplit: isSplit,
            position: resolvedPosition,
            safeAreaBottom: liveSafeBottom > 0 ? liveSafeBottom : safeAreaBottom,
            isLandscape: isLandscape,
            isLockedExpanded: isBarLockedExpanded,
            reduceMotion: reduceMotion
        )
        browser.setExternalKeyboardFrozen(isPageFormKeyboardActive)
    }

    private func updateSystemKeyboardVisibility(from notification: Notification, isHideNotification: Bool) {
        guard (notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) != false else { return }
        if isHideNotification {
            browser.setSystemKeyboardVisible(false)
            return
        }
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        if let window = BrowserBarFontMetrics.normalSceneWindow() {
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
    let browser: ForumBrowserModel
    @ObservedObject var editState: AddressEditState
    let actions: BrowserActions
    let addressFocusRequest: Int
    let browserAddressFocusRequest: Int

    @State private var addressError: AddressError?
    @FocusState private var addressFocused: Bool

    init(
        app: AppModel,
        browser: ForumBrowserModel,
        actions: BrowserActions,
        addressFocusRequest: Int,
        browserAddressFocusRequest: Int
    ) {
        self.app = app
        self.browser = browser
        self.editState = browser.addressEditState
        self.actions = actions
        self.addressFocusRequest = addressFocusRequest
        self.browserAddressFocusRequest = browserAddressFocusRequest
    }

    var body: some View {
        let _ = PerfProbe.hit("AddressEditBar.body")
        HStack(spacing: DCTheme.spacingS) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search or enter address", text: $editState.draft)
                    .textContentType(.URL)
                    .keyboardType(.webSearch)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(commitAddress)
                    .onKeyPress(.downArrow) {
                        let rows = currentSuggestionRows
                        guard !rows.isEmpty else { return .ignored }
                        DispatchQueue.main.async {
                            editState.moveSelection(delta: 1, rowCount: rows.count)
                        }
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        let rows = currentSuggestionRows
                        guard !rows.isEmpty else { return .ignored }
                        DispatchQueue.main.async {
                            editState.moveSelection(delta: -1, rowCount: rows.count)
                        }
                        return .handled
                    }
                    .onChange(of: editState.draft) { _, _ in
                        PerfProbe.mark("address.keystroke")
                    }
                    .accessibilityIdentifier("addressField")
                    // Select the whole address so typing replaces it, like Safari.
                    .onReceive(
                        NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)
                    ) { notification in
                        guard let textField = notification.object as? UITextField else { return }
                        PerfProbe.mark("addressEdit.focus")
                        textField.selectAll(nil)
                    }
                    .task(id: browserAddressFocusRequest) {
                        for delayMs in [0, 50, 150, 350] {
                            if delayMs > 0 {
                                try? await Task.sleep(for: .milliseconds(delayMs))
                            }
                            guard !Task.isCancelled, browser.isEditingAddress else { return }
                            if !addressFocused {
                                addressFocused = true
                            }
                        }
                    }
                if !editState.draft.isEmpty {
                    Button {
                        editState.draft = ""
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
                closeAddressBar()
            }
            .fixedSize(horizontal: true, vertical: false)
            .keyboardShortcut(.cancelAction)
            .frame(minHeight: DCTheme.controlHeight)
            .accessibilityIdentifier("addressCancel")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, DCTheme.spacingM)
        .padding(.vertical, 6)
        .accessibilityAction(.escape) { closeAddressBar() }
        .onChange(of: addressFocusRequest) {
            addressFocused = true
        }
        .onChange(of: browserAddressFocusRequest) {
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

    private var currentSuggestionRows: [AddressSuggestionRow] {
        guard editState.showsSuggestions else { return [] }
        let tiles = HomeSites.tiles(forums: app.forums, visits: app.siteVisits.shownVisits)
        return AddressSuggestionsBuilder.rows(
            for: editState.draft,
            context: app.addressInputContext(for: browser),
            tiles: tiles
        )
    }

    private func closeAddressBar() {
        addressFocused = false
        browser.setEditingAddress(false)
        app.router.addressEditRevision &+= 1
    }

    /// Runs the selected suggestion row (default row 1) or the classified action.
    private func commitAddress() {
        guard browser.isEditingAddress else { return }
        let rows = currentSuggestionRows
        if !rows.isEmpty {
            let index = min(max(0, editState.selectedSuggestionIndex ?? 0), rows.count - 1)
            addressFocused = false
            DCHaptics.tap()
            app.performSuggestionRow(rows[index], in: browser, actions: actions)
            return
        }
        let draft = editState.draft
        let context = app.addressInputContext(for: browser)
        if let action = AddressInput.actions(for: draft, context: context).first {
            addressFocused = false
            app.performAddressAction(action, in: browser)
        } else {
            addressError = AddressError(address: draft, hasForum: browser.homeSiteURL != nil)
        }
    }
}

// MARK: - Single Morphing Glass Bar (iPhone & iPad Split)

enum BrowserBarFontMetrics {
    @MainActor
    static func normalSceneWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes
            .flatMap(\.windows)
            .first(where: { !$0.isHidden && $0.windowLevel == .normal }) {
            return window
        }
        return scenes.first?.windows.first(where: { $0.windowLevel == .normal })
    }

    @MainActor
    static func normalSceneSafeAreaBottom() -> CGFloat {
        normalSceneWindow()?.safeAreaInsets.bottom ?? 0
    }

    /// Extra bottom clearance inside safe area so `DockLayer` cards/rows sit above the floating bottom bar.
    /// Driven by `isChromeMinimized` (0.6 / 0.4 hysteresis) so `BrowserContent` does not re-layout per scroll frame.
    @MainActor
    static func bottomDockClearance(
        app: AppModel,
        browser: ForumBrowserModel,
        voice: VoiceController,
        isSplit: Bool,
        position: BrowserBarPosition,
        safeAreaBottom: CGFloat,
        isLandscape: Bool,
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        guard !isSplit, position == .bottom, !browser.isEditingAddress else {
            return 0
        }
        if voice.showsBar || browser.isPageFormInputFocused {
            return 0
        }
        if browser.isSystemKeyboardVisible && !app.isAIViewShown && app.rootPresentation == nil {
            return 0
        }
        let effectiveP: CGFloat = browser.isChromeMinimized ? 1 : 0
        let collapsedFont = collapsedFontSize(for: dynamicTypeSize)
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
            if browser.isEditingAddress {
                Group {
                    if position == .top {
                        VStack(spacing: 0) {
                            AddressEditBar(
                                app: app,
                                browser: browser,
                                actions: actions,
                                addressFocusRequest: addressFocusRequest,
                                browserAddressFocusRequest: browser.addressFocusRequest
                            )
                            Divider()
                        }
                        .background(.bar)
                    } else {
                        AddressEditBar(
                            app: app,
                            browser: browser,
                            actions: actions,
                            addressFocusRequest: addressFocusRequest,
                            browserAddressFocusRequest: browser.addressFocusRequest
                        )
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
                        PerfProbe.mark("addressEdit.tap")
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

/// Isolates 120 Hz scroll-progress observation to the floating bar overlay on iPad (both split
/// `width >= 850` and narrow/portrait `width < 850`) while keeping `PhoneMorphingBar` mounted
/// across 850 pt split-layout rotations and centering the bar over the page column in split mode.
private struct PhoneMorphingBarHost: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var progressModel: BrowserBarProgressModel
    @ObservedObject var router: PresentationRouter
    var browserAgent: BrowserAgentSession
    var scriptStore: ScriptStore
    @ObservedObject var voice: VoiceController
    let actions: BrowserActions
    let fallbackSplit: SplitBarContext?
    let addressFocusRequest: Int
    let fallbackWidth: CGFloat
    let safeAreaBottom: CGFloat
    let isLandscape: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increasedContrast: Bool
    @AppStorage("dc.assistantPanelWidth") private var storedPanelWidth: Double = 0

    private var liveWidth: CGFloat {
        if router.windowWidth > 0 { return router.windowWidth }
        if let w = BrowserBarFontMetrics.normalSceneWindow()?.bounds.width, w > 0 { return w }
        return fallbackWidth
    }

    private var isSplit: Bool {
        router.splitLayout ?? (liveWidth > 0 ? ContentView.usesSplitLayout(width: liveWidth) : fallbackSplit != nil)
    }

    private var resolvedPosition: BrowserBarPosition {
        isSplit ? .top : app.settings.browserBarPosition.resolved(isSplit: false)
    }

    private var resolvedSplit: SplitBarContext? {
        guard isSplit else { return nil }
        let panelShown = app.showsSplitPanel(forWidth: liveWidth)
        let currentPanelWidth = WorkspaceMetrics.panelWidth(
            preferred: router.splitPanelDragWidth ?? (storedPanelWidth > 0 ? CGFloat(storedPanelWidth) : nil),
            containerWidth: liveWidth
        )
        let columnWidth = panelShown
            ? max(0, liveWidth - currentPanelWidth - WorkspaceMetrics.handleHitWidth)
            : liveWidth
        return SplitBarContext(
            panelShown: panelShown,
            pageColumnWidth: columnWidth,
            togglePanel: fallbackSplit?.togglePanel ?? app.toggleAIView
        )
    }

    private var isAnyKeyboardVisible: Bool {
        browser.isSystemKeyboardVisible || browser.isPageFormInputFocused
    }

    private var hidesBottomBar: Bool {
        guard resolvedPosition == .bottom, !browser.isEditingAddress else { return false }
        if voice.showsBar || browser.isPageFormInputFocused {
            return true
        }
        return isAnyKeyboardVisible && !app.isAIViewShown && app.rootPresentation == nil
    }

    @ViewBuilder
    var body: some View {
        let _ = router.splitLayout
        let _ = router.splitPanelMode
        let _ = router.addressEditRevision
        let split = resolvedSplit
        let position = resolvedPosition
        let columnWidth = split?.pageColumnWidth ?? liveWidth
        let liveSafeBottom = BrowserBarFontMetrics.normalSceneSafeAreaBottom()
        let isEditing = browser.isEditingAddress
        let hostAlignment: Alignment = split != nil
            ? .topLeading
            : (position == .top ? .top : .bottom)
        if hidesBottomBar {
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
                split: split,
                showsInlineAddressEdit: true,
                addressEditRevision: router.addressEditRevision,
                addressFocusRequest: addressFocusRequest,
                containerWidth: columnWidth,
                safeAreaBottom: liveSafeBottom > 0 ? liveSafeBottom : safeAreaBottom,
                isLandscape: isLandscape,
                progress: browser.showsForumsHome ? 0 : min(1, max(0, progressModel.progress)),
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency,
                increasedContrast: increasedContrast,
                onEdit: {
                    PerfProbe.mark("addressEdit.tap")
                    browser.expandChrome(deferIfTracking: false)
                    browser.setEditingAddress(true)
                    router.addressEditRevision &+= 1
                }
            )
            .frame(width: split != nil ? columnWidth : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hostAlignment)
            .ignoresSafeArea([.container, .keyboard], edges: (!isEditing && position == .bottom) ? .bottom : [])
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
    var split: SplitBarContext? = nil
    var showsInlineAddressEdit = false
    var addressEditRevision = 0
    var addressFocusRequest = 0
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

    private var isSplit: Bool {
        split != nil
    }

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
        let _ = addressEditRevision
        let isEditing = showsInlineAddressEdit && browser.isEditingAddress
        let effectiveP: CGFloat = if browser.showsForumsHome {
            0
        } else if reduceMotion {
            browser.isChromeMinimized ? 1 : 0
        } else {
            min(1, max(0, progress))
        }
        if isEditing {
            if position == .top {
                VStack(spacing: 0) {
                    AddressEditBar(
                        app: app,
                        browser: browser,
                        actions: actions,
                        addressFocusRequest: addressFocusRequest,
                        browserAddressFocusRequest: browser.addressFocusRequest
                    )
                    Divider()
                }
                .background(.bar)
            } else {
                AddressEditBar(
                    app: app,
                    browser: browser,
                    actions: actions,
                    addressFocusRequest: addressFocusRequest,
                    browserAddressFocusRequest: browser.addressFocusRequest
                )
                    .background(.bar)
            }
        } else {
            morphingCapsule(at: effectiveP, snapsGeometry: reduceMotion)
                .frame(maxWidth: .infinity, alignment: .center)
                .ignoresSafeArea(.container, edges: position == .bottom ? .bottom : [])
        }
    }

    @ViewBuilder
    private func morphingCapsule(at p: CGFloat, snapsGeometry: Bool = false) -> some View {
        let expandedFont = BrowserBarFontMetrics.expandedFontSize(for: dynamicTypeSize)
        let collapsedFont = BrowserBarFontMetrics.collapsedFontSize(for: dynamicTypeSize)
        let domainWidth = BrowserBarFontMetrics.measuredWidth(of: domainText, fontSize: collapsedFont)

        let expandedW = BrowserBarMorphMetrics.expandedWidth(containerWidth: containerWidth, isSplit: isSplit)
        let collapsedW = BrowserBarMorphMetrics.collapsedWidth(
            domainWidth: domainWidth,
            isAgentWorking: isAgentWorking,
            scriptCount: scriptBadge.count,
            isSplit: isSplit
        )
        let expandedH = BrowserBarMorphMetrics.expandedHeight(isSplit: isSplit, isLandscape: isLandscape)
        let collapsedH = BrowserBarMorphMetrics.collapsedHeight(collapsedFontSize: collapsedFont)

        let barWidth = BrowserBarMorphMetrics.lerp(expandedW, collapsedW, p)
        let barHeight = BrowserBarMorphMetrics.lerp(expandedH, collapsedH, p)
        let outerHPad = BrowserBarMorphMetrics.lerp(6, 3, p)
        let itemGap = BrowserBarMorphMetrics.lerp(2, 0, p)
        let fontSize = BrowserBarMorphMetrics.lerp(expandedFont, collapsedFont, p)

        let bottomOffset = BrowserBarMorphMetrics.bottomEdgeFromScreen(safeAreaBottom: safeAreaBottom, progress: p)
        let topOffset = BrowserBarMorphMetrics.topEdgeFromSafeArea(progress: p, isSplit: isSplit)
        let isCollapsedHalf = !browser.showsForumsHome && p >= 0.5
        let extraHit = isCollapsedHalf ? max(0, BrowserBarMorphMetrics.minHitTargetHeight - barHeight) : 0
        let capsuleAlignment: Alignment = position == .bottom ? .bottom : .top

        // Keep `expandedMorphItems` permanently mounted inside a single `ZStack` over one
        // continuous glass capsule so UIKit-backed controls (`Menu`, `PhoneAddressTitleButton`)
        // never tear down and recreate mid-spring across `p = 0.5`.
        ZStack(alignment: capsuleAlignment) {
            if browser.showsForumsHome {
                HStack(spacing: itemGap) {
                    homeItems(barHeight: expandedH, fontSize: expandedFont)
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
                        collapsedW: collapsedW,
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
    private func homeItems(barHeight: CGFloat, fontSize: CGFloat) -> some View {
        let fieldFill = BrowserBarMorphMetrics.addressFieldFillOpacity(
            progress: 0,
            isDark: colorScheme == .dark
        )
        let visualFieldHeight = max(30, barHeight - ((!isSplit && isLandscape) ? 12 : 14))
        let rowHeight = max(DCTheme.controlHeight, visualFieldHeight)
        let maxFieldWidth: CGFloat = isSplit ? BrowserBarMorphMetrics.maxBarWidth : .infinity

        PhoneBackButton(browser: browser, isActive: true)
            .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
        if isSplit {
            PhoneForwardButton(browser: browser)
        }
        HStack(spacing: 0) {
            ForumMenuButton(
                app: app,
                browser: browser,
                actions: actions,
                avatarSize: (!isSplit && isLandscape) ? 22 : 26
            )
            .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)

            PhoneAddressTitleButton(
                domainText: "",
                placeholder: String(localized: "Search or enter address", comment: "Home address field placeholder"),
                fullAddressDisplay: "",
                isSecurePage: false,
                fontSize: fontSize,
                minHeight: rowHeight,
                isActive: true,
                onEdit: onEdit
            )
            .frame(maxWidth: .infinity, minHeight: rowHeight)
        }
        .frame(maxWidth: maxFieldWidth, minHeight: rowHeight, maxHeight: rowHeight)
        .background {
            Capsule()
                .fill(DCTheme.ink.opacity(fieldFill))
                .frame(height: visualFieldHeight)
        }
        .contentShape(Capsule())
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)

        BrowserTabsButton(app: app)
            .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
        if let split {
            if app.showsVoiceButton {
                VoiceBarButton(voice: voice)
            }
            SplitPanelToggle(app: app, isShown: split.panelShown, action: split.togglePanel)
        } else {
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
    }

    @ViewBuilder
    private func expandedMorphItems(
        p: CGFloat,
        barHeight: CGFloat,
        collapsedW: CGFloat,
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
        let visualFieldHeight = max(30, barHeight - BrowserBarMorphMetrics.lerp((!isSplit && isLandscape) ? 12 : 14, 2, p))
        let rowHeight = isExpandedHalf ? max(DCTheme.controlHeight, visualFieldHeight) : visualFieldHeight
        let maxFieldWidth: CGFloat = isSplit
            ? BrowserBarMorphMetrics.lerp(BrowserBarMorphMetrics.maxBarWidth, collapsedW, p)
            : .infinity

        if isExpandedHalf {
            PhoneBackButton(browser: browser, isActive: isExpandedHalf)
                .scaleEffect(btnScale)
                .opacity(btnOpacity)
                .frame(width: slotWidth, height: DCTheme.controlHeight)
                .allowsHitTesting(sideButtonsHitTarget)

            if isSplit {
                PhoneForwardButton(browser: browser)
                    .scaleEffect(btnScale)
                    .opacity(btnOpacity)
                    .frame(width: slotWidth, height: DCTheme.controlHeight)
                    .allowsHitTesting(sideButtonsHitTarget)
            }
        }

        HStack(spacing: 0) {
            if isExpandedHalf {
                ForumMenuButton(
                    app: app,
                    browser: browser,
                    actions: actions,
                    avatarSize: (!isSplit && isLandscape) ? 22 : 26
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
        .frame(maxWidth: maxFieldWidth, minHeight: rowHeight, maxHeight: rowHeight)
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
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)

        if isExpandedHalf {
            BrowserTabsButton(app: app, isActive: isExpandedHalf && sideButtonsHitTarget)
                .frame(width: slotWidth, height: DCTheme.controlHeight)
                .scaleEffect(btnScale)
                .opacity(btnOpacity)
                .allowsHitTesting(sideButtonsHitTarget)

            if let split {
                if app.showsVoiceButton {
                    VoiceBarButton(voice: voice)
                        .scaleEffect(btnScale)
                        .opacity(btnOpacity)
                        .frame(width: slotWidth, height: DCTheme.controlHeight)
                        .allowsHitTesting(sideButtonsHitTarget)
                }
                SplitPanelToggle(app: app, isShown: split.panelShown, action: split.togglePanel)
                    .scaleEffect(btnScale)
                    .opacity(btnOpacity)
                    .frame(width: slotWidth, height: DCTheme.controlHeight)
                    .allowsHitTesting(sideButtonsHitTarget)
            } else {
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
    }

    @ViewBuilder
    private func collapsedPillInner(fontSize: CGFloat) -> some View {
        HStack(spacing: 6) {
            if isAgentWorking {
                DCAgentRing(state: .working, size: 16, lineWidth: 2.5)
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

private struct PhoneForwardButton: View {
    @ObservedObject var browser: ForumBrowserModel

    private var isEnabled: Bool {
        browser.canGoForward && !browser.showsForumsHome
    }

    var body: some View {
        Button {
            DCHaptics.tap()
            browser.goForward()
        } label: {
            Image(systemName: "chevron.forward")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isEnabled ? DCTheme.ink : DCTheme.inkFaint)
                .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Forward")
        .accessibilityShowsLargeContentViewer {
            Label("Forward", systemImage: "chevron.forward")
        }
        .accessibilityIdentifier("browserForward")
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
    var placeholder: String = ""
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
                if domainText.isEmpty, !placeholder.isEmpty {
                    Text(verbatim: placeholder)
                        .font(.system(size: fontSize, weight: .regular))
                        .foregroundStyle(DCTheme.inkFaint)
                        .lineLimit(1)
                } else {
                    Text(verbatim: domainText)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(DCTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var browserAgent: BrowserAgentSession { app.browserAgent }
    private var showsNewRepliesDot: Bool { app.showsNewRepliesDot }
    private var ringState: AgentRingState { app.agentRingState(isAvailable: isAvailable) }

    private var accessibilityValueText: Text {
        var parts: [String] = []
        if let stateWord = ringState.accessibilityValue {
            parts.append(stateWord)
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
                    state: ringState,
                    size: Self.ringSize,
                    lineWidth: DCTheme.ringWidth,
                    panelVisible: app.isAIViewShown
                )
            }
        }
        .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
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

    @ViewBuilder
    private var buttonControl: some View {
        Button {
            guard isAvailable else { return }
            onOpen()
        } label: {
            ringVisual
        }
        .buttonStyle(
            PhoneAIButtonStyle(
                isAvailable: isAvailable,
                allowLongPress: !dynamicTypeSize.isAccessibilitySize,
                reduceMotion: reduceMotion,
                onTouchDown: {
                    DCHaptics.tap()
                    PerfProbe.mark("haptic.done")
                },
                onLongPress: {
                    DCHaptics.tap()
                    voice.toggle()
                }
            )
        )
        .accessibilityRemoveTraits(isAvailable ? [] : .isButton)
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                buttonControl
                    .accessibilityShowsLargeContentViewer {
                        Label {
                            Text("Agent", comment: "Browser bar button that opens the Agent panel")
                        } icon: {
                            Image(systemName: voice.isActive ? "waveform" : "circle")
                        }
                    }
            } else {
                buttonControl
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

/// Dims and shrinks the AI button ring at touch-down, fires the tap haptic before
/// lift, and keeps the 0.45 s long press for voice as a simultaneous gesture.
private struct PhoneAIButtonStyle: PrimitiveButtonStyle {
    let isAvailable: Bool
    let allowLongPress: Bool
    let reduceMotion: Bool
    let onTouchDown: () -> Void
    let onLongPress: () -> Void

    @Environment(\.isFocused) private var isFocused
    @State private var isPressing = false
    @State private var didTouchDown = false
    @State private var didLongPress = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isAvailable && isPressing
        configuration.label
            .hoverEffect(.highlight)
            .dcFocusRing(isFocused, cornerRadius: DCTheme.controlHeight / 2)
            .opacity(pressed ? 0.65 : 1)
            .scaleEffect(pressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
            .overlay {
                TouchDownWatcher(
                    onTouchDown: {
                        guard isAvailable, !didTouchDown else { return }
                        didTouchDown = true
                        didLongPress = false
                        isPressing = true
                        onTouchDown()
                    },
                    onTouchUp: {
                        isPressing = false
                    }
                )
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        defer {
                            didTouchDown = false
                            isPressing = false
                        }
                        guard isAvailable else { return }
                        if didLongPress {
                            didLongPress = false
                            return
                        }
                        if abs(value.translation.width) < DCTheme.controlHeight,
                           abs(value.translation.height) < DCTheme.controlHeight {
                            configuration.trigger()
                        }
                    }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        guard isAvailable, allowLongPress else { return }
                        didLongPress = true
                        isPressing = false
                        onLongPress()
                    }
            )
    }
}

/// Fires `onTouchDown` immediately on `touchesBegan` without delaying or
/// cancelling SwiftUI's tap or long-press gestures.
private struct TouchDownWatcher: UIViewRepresentable {
    let onTouchDown: () -> Void
    let onTouchUp: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = TouchDownRecognizer()
        recognizer.onTouchDown = onTouchDown
        recognizer.onTouchUp = onTouchUp
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        for case let recognizer as TouchDownRecognizer in uiView.gestureRecognizers ?? [] {
            recognizer.onTouchDown = onTouchDown
            recognizer.onTouchUp = onTouchUp
        }
    }

    private final class TouchDownRecognizer: UIGestureRecognizer {
        var onTouchDown: () -> Void = {}
        var onTouchUp: () -> Void = {}

        override init(target: Any? = nil, action: Selector? = nil) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouchDown()
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouchUp()
            state = .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouchUp()
            state = .failed
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
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
        forum.map { String(localized: "\($0.displayName) home", comment: "Button label: the site's home page (site name)") }
            ?? String(localized: "Sites")
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
