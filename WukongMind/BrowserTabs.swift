import Combine
import Foundation
import UIKit
import WebKit

/// Small weak reference holder so closures created while wiring a tab or model
/// never form strong reference cycles.
final class WeakBox<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value? = nil) {
        self.value = value
    }
}

/// Errors returned when the `tabs` tool tries to open a tab past the limit.
enum BrowserTabOpenError: LocalizedError, Equatable, Sendable {
    case limitReached(maxTabs: Int)

    var errorDescription: String? {
        switch self {
        case .limitReached(let maxTabs):
            return "Tab limit reached: \(maxTabs) open"
        }
    }
}

/// One open browser tab (`design-browser-bar-tabs-models.md` §2, T1/T2): its own
/// `ForumBrowserModel` (lazy/unloadable `WKWebView` + `AgentBridge`),
/// `BrowserAgentSession`, live userscript controller, HTTP client, confirmation
/// queue, thumbnail snapshot, and persistent conversation ID.
@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    /// Short stable identifier (`"t1"`, `"t2"`, …).
    let id: String
    /// Stable UUID linking this tab to its on-disk Agent conversation file.
    private(set) var conversationID: UUID
    /// Last captured thumbnail of the page (kept across lazy restore and memory unload).
    @Published var snapshot: UIImage? {
        didSet {
            if snapshot !== oldValue {
                onSnapshotChanged?()
            }
        }
    }
    var onSnapshotChanged: (() -> Void)?

    let browser: ForumBrowserModel
    let pageToolBridge: PageToolBridge
    let scriptWebController: ScriptWebController
    let confirmations: AgentConfirmationGate
    let httpClient: AgentHTTPClient
    let agentSession: BrowserAgentSession
    /// Keeps weak closures inside `agentSession` and `httpClient` connected for
    /// the lifetime of this tab without retaining `agentSession` in cycles.
    let sessionBox: WeakBox<BrowserAgentSession>

    init(
        id: String,
        conversationID: UUID = UUID(),
        snapshot: UIImage? = nil,
        browser: ForumBrowserModel,
        pageToolBridge: PageToolBridge,
        scriptWebController: ScriptWebController,
        confirmations: AgentConfirmationGate,
        httpClient: AgentHTTPClient,
        agentSession: BrowserAgentSession,
        sessionBox: WeakBox<BrowserAgentSession>
    ) {
        self.id = id
        self.conversationID = conversationID
        self.snapshot = snapshot
        self.browser = browser
        self.pageToolBridge = pageToolBridge
        self.scriptWebController = scriptWebController
        self.confirmations = confirmations
        self.httpClient = httpClient
        self.agentSession = agentSession
        self.sessionBox = sessionBox
    }

    var isWebViewLoaded: Bool {
        browser.isWebViewLoaded
    }

    var showsHome: Bool {
        browser.showsForumsHome
    }

    var url: URL? {
        showsHome ? nil : browser.currentURL
    }

    var scrollPosition: CGPoint {
        browser.scrollPosition
    }

    var title: String {
        if showsHome {
            return String(localized: "Home", comment: "Title of a tab showing the Home start page")
        }
        let trimmed = browser.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != ForumBrowserModel.defaultPageTitle {
            return trimmed
        }
        if let host = browser.currentURL?.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return browser.currentURL?.absoluteString ?? ForumBrowserModel.defaultPageTitle
    }

    /// Assigns a fresh `conversationID` when starting a new conversation and returns
    /// the previous ID so its saved file can be removed.
    @discardableResult
    func assignNewConversationID() -> UUID {
        let previous = conversationID
        conversationID = UUID()
        return previous
    }

    func loadIfNeeded() {
        browser.loadIfNeeded()
    }

    func unloadWebView() {
        browser.unloadWebView()
    }

    @discardableResult
    func captureSnapshotIfAvailable() async -> UIImage? {
        if showsHome {
            snapshot = nil
            return nil
        }
        guard let captured = await browser.captureTabSnapshot() else {
            return snapshot
        }
        snapshot = captured
        return captured
    }

    func exportSavedTab() -> SavedBrowserTab {
        browser.refreshScrollPositionFromWebView()
        let isSavedHome = showsHome && !(browser.isLaunchHomeOverlay && browser.currentURL != nil)
        let savedURL = isSavedHome ? nil : browser.currentURL
        let rawTitle = isSavedHome ? "" : browser.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedTitle = rawTitle == ForumBrowserModel.defaultPageTitle ? "" : rawTitle
        return SavedBrowserTab(
            id: id,
            url: savedURL,
            title: savedTitle,
            scrollPosition: browser.scrollPosition,
            conversationID: conversationID
        )
    }
}

/// Owns the open browser tabs (`BrowserTab`), all sharing one `WKWebsiteDataStore`
/// so forum and website sign-ins carry over across tabs. Always keeps at least
/// one tab open so `currentTab` is non-optional.
@MainActor
final class BrowserTabs: ObservableObject {
    static let maxTabs = 30
    static let maxConcurrentRuns = 3

    static var personTabLimitMessage: String {
        String(
            localized: "30 tabs open. Close one to open another",
            comment: "Shown when 30 tabs are open and the user tries to open another tab"
        )
    }

    static var runLimitMessage: String {
        String(
            localized: "3 runs are going. Wait for one or stop it",
            comment: "Shown under the Agent input box when 3 concurrent runs are already going across tabs"
        )
    }

    @Published private(set) var tabs: [BrowserTab]
    @Published private(set) var currentTabID: String
    /// IDs of tabs whose `agentSession.isRunning` is currently `true`.
    @Published private(set) var runningTabIDs: Set<String> = []

    /// Shared website data store (cookies, storage, sessions) across all tabs.
    let websiteDataStore: WKWebsiteDataStore

    /// Notifies `AppModel` after the active tab changes `(newTab, oldTab)`.
    var onActiveTabChanged: ((BrowserTab, BrowserTab?) -> Void)?
    /// Notifies `AppModel` whenever tab order, selection, or open tabs change.
    var onTabsMutated: (() -> Void)?
    /// Notifies `AppModel` when a tab is closed so its snapshot/conversation files are cleaned up.
    var onTabClosed: ((BrowserTab) -> Void)?
    /// Notifies `AppModel` when a tab's page snapshot changes.
    var onTabSnapshotUpdated: ((BrowserTab) -> Void)?

    var canOpenTab: Bool {
        tabs.count < Self.maxTabs
    }

    var runningTabCount: Int {
        runningTabIDs.count
    }

    func canStartRun(forTabID tabID: String) -> Bool {
        runningTabIDs.contains(tabID) || runningTabIDs.count < Self.maxConcurrentRuns
    }

    private var nextTabNumber: Int
    private let makeBrowser: (WKWebViewConfiguration?, Bool, URL?, String, CGPoint) -> ForumBrowserModel
    private let makeTab: (String, UUID, UIImage?, ForumBrowserModel) -> BrowserTab
    nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?

    init(
        initialBrowser: ForumBrowserModel? = nil,
        restoredState: SavedBrowserTabsState? = nil,
        loadRestoredConversation: ((UUID) -> SavedAgentConversation?)? = nil,
        loadRestoredSnapshot: ((String) -> UIImage?)? = nil,
        sites: SiteRegistry = .standard,
        contentRules: ContentRuleLibrary? = nil,
        websiteDataStore: WKWebsiteDataStore? = nil,
        makeTab: @escaping (String, UUID, UIImage?, ForumBrowserModel) -> BrowserTab
    ) {
        let resolvedDataStore = initialBrowser?.configuredWebsiteDataStore
            ?? websiteDataStore
            ?? .default()
        let resolvedRules = initialBrowser?.contentRules ?? contentRules
        self.websiteDataStore = resolvedDataStore
        let browserFactory: (WKWebViewConfiguration?, Bool, URL?, String, CGPoint) -> ForumBrowserModel = {
            popupConfiguration, startsUnloaded, restoredURL, restoredTitle, restoredScroll in
            ForumBrowserModel(
                contentRules: resolvedRules,
                sites: sites,
                websiteDataStore: resolvedDataStore,
                popupConfiguration: popupConfiguration,
                startsUnloaded: startsUnloaded,
                restoredURL: restoredURL,
                restoredTitle: restoredTitle,
                restoredScrollPosition: restoredScroll
            )
        }
        self.makeBrowser = browserFactory
        self.makeTab = makeTab

        if initialBrowser == nil,
           let restoredState,
           !restoredState.tabs.isEmpty {
            let cappedSavedTabs = Array(restoredState.tabs.prefix(Self.maxTabs))
            let resolvedCurrentID = cappedSavedTabs.contains(where: { $0.id == restoredState.currentTabID })
                ? restoredState.currentTabID
                : cappedSavedTabs[0].id
            var restoredTabs: [BrowserTab] = []
            restoredTabs.reserveCapacity(cappedSavedTabs.count)
            for saved in cappedSavedTabs {
                let isFront = saved.id == resolvedCurrentID
                let browser = browserFactory(
                    nil,
                    !isFront,
                    saved.url,
                    saved.title,
                    saved.scrollPosition
                )
                let snapshot = loadRestoredSnapshot?(saved.id)
                let tab = makeTab(saved.id, saved.conversationID, snapshot, browser)
                if let savedConversation = loadRestoredConversation?(saved.conversationID) {
                    tab.agentSession.restoreConversation(savedConversation)
                }
                restoredTabs.append(tab)
            }
            let maxNumericID = cappedSavedTabs.compactMap { Self.numericSuffix(of: $0.id) }.max() ?? 1
            self.tabs = restoredTabs
            self.currentTabID = resolvedCurrentID
            self.nextTabNumber = max(restoredState.nextTabNumber, maxNumericID + 1)
            for tab in restoredTabs {
                installTabHandlers(on: tab)
            }
            // Only the current tab loads its page on launch; background tabs stay unloaded.
            if let activeSaved = cappedSavedTabs.first(where: { $0.id == resolvedCurrentID }),
               let activeURL = activeSaved.url,
               ForumBrowserModel.isBrowsableURL(activeURL),
               let activeTab = restoredTabs.first(where: { $0.id == resolvedCurrentID }) {
                activeTab.browser.load(
                    activeURL,
                    silentOnFailure: true,
                    restoringScroll: activeSaved.scrollPosition
                )
            }
        } else {
            let firstBrowser = initialBrowser ?? browserFactory(nil, false, nil, "", .zero)
            let firstID = "t1"
            let firstTab = makeTab(firstID, UUID(), nil, firstBrowser)
            self.tabs = [firstTab]
            self.currentTabID = firstID
            self.nextTabNumber = 2
            installTabHandlers(on: firstTab)
        }

        self.memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMemoryWarning()
            }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// The currently active tab.
    var currentTab: BrowserTab {
        tabs.first(where: { $0.id == currentTabID }) ?? tabs[0]
    }

    func tab(id: String) -> BrowserTab? {
        tabs.first(where: { $0.id == id })
    }

    func index(of id: String) -> Int? {
        tabs.firstIndex(where: { $0.id == id })
    }

    func isCurrent(_ tab: BrowserTab) -> Bool {
        tab.id == currentTabID
    }

    func isCurrent(_ browser: ForumBrowserModel) -> Bool {
        currentTab.browser === browser
    }

    /// Opens a new tab for the user. Returns `nil` and opens nothing when 30 tabs are already open.
    @discardableResult
    func openTab(
        url: URL? = nil,
        after anchorTabID: String? = nil,
        inFront: Bool = true
    ) -> BrowserTab? {
        guard canOpenTab else { return nil }
        let browser = makeBrowser(nil, false, nil, "", .zero)
        let tab = appendOrInsertTab(browser: browser, after: anchorTabID)
        if inFront {
            switchToTab(id: tab.id, notifyMutated: false)
        }
        if let url, ForumBrowserModel.isBrowsableURL(url) {
            browser.load(url)
        }
        onTabsMutated?()
        return tab
    }

    /// Opens a new tab for the `tabs` Agent tool (defaults to background: `inFront = false`).
    /// Fails with `"Tab limit reached: 30 open"` when 30 tabs are already open.
    func openTabForTool(
        url: URL? = nil,
        after anchorTabID: String? = nil,
        inFront: Bool = false
    ) -> Result<BrowserTab, BrowserTabOpenError> {
        guard canOpenTab else {
            return .failure(.limitReached(maxTabs: Self.maxTabs))
        }
        let browser = makeBrowser(nil, false, nil, "", .zero)
        let tab = appendOrInsertTab(browser: browser, after: anchorTabID)
        if inFront {
            switchToTab(id: tab.id, notifyMutated: false)
        }
        if let url, ForumBrowserModel.isBrowsableURL(url) {
            browser.load(url)
        }
        onTabsMutated?()
        return .success(tab)
    }

    /// Makes `id` the active tab when it exists and isn't already active, loading its
    /// page lazily if it was restored unloaded or dropped under memory pressure.
    @discardableResult
    func switchToTab(id: String) -> Bool {
        switchToTab(id: id, notifyMutated: true)
    }

    @discardableResult
    private func switchToTab(id: String, notifyMutated: Bool) -> Bool {
        guard id != currentTabID, let newTab = tab(id: id) else {
            return id == currentTabID
        }
        let previousTab = currentTab
        if previousTab.isWebViewLoaded {
            previousTab.browser.refreshScrollPositionFromWebView()
            Task { @MainActor [weak previousTab] in
                _ = await previousTab?.captureSnapshotIfAvailable()
            }
        }
        newTab.loadIfNeeded()
        currentTabID = id
        onActiveTabChanged?(newTab, previousTab)
        if notifyMutated {
            onTabsMutated?()
        }
        return true
    }

    /// Closes the tab with `id`, stopping any active Agent run in it. Closing the
    /// last remaining tab replaces it with a fresh Home tab so `currentTab` stays valid.
    @discardableResult
    func closeTab(id: String) -> Bool {
        guard let closingIndex = index(of: id) else { return false }
        let closingTab = tabs[closingIndex]
        tearDown(closingTab)
        onTabClosed?(closingTab)

        if tabs.count == 1 {
            let replacement = appendOrInsertTab(browser: makeBrowser(nil, false, nil, "", .zero), after: nil)
            tabs.remove(at: closingIndex)
            currentTabID = replacement.id
            onActiveTabChanged?(replacement, closingTab)
            onTabsMutated?()
            return true
        }

        let wasCurrent = closingTab.id == currentTabID
        tabs.remove(at: closingIndex)
        if wasCurrent {
            let nextIndex = min(closingIndex, tabs.count - 1)
            let nextTab = tabs[nextIndex]
            nextTab.loadIfNeeded()
            currentTabID = nextTab.id
            onActiveTabChanged?(nextTab, closingTab)
        }
        onTabsMutated?()
        return true
    }

    /// Resets all tabs back to a single fresh `"t1"` Home tab (used by "Clear all data").
    func resetToSingleHomeTab() {
        let oldCurrent = currentTab
        let previousTabs = tabs
        for tab in previousTabs {
            tearDown(tab)
            onTabClosed?(tab)
        }
        runningTabIDs.removeAll()
        nextTabNumber = 1
        let freshID = allocateTabID()
        let freshTab = makeTab(freshID, UUID(), nil, makeBrowser(nil, false, nil, "", .zero))
        installTabHandlers(on: freshTab)
        tabs = [freshTab]
        currentTabID = freshID
        onActiveTabChanged?(freshTab, oldCurrent)
        onTabsMutated?()
    }

    /// Unloads idle background tabs when iOS reports memory pressure, keeping their
    /// URL, title, snapshot, scroll position, and conversation. Never unloads the
    /// current tab or any tab whose Agent run is active.
    func handleMemoryWarning() {
        for tab in tabs where tab.id != currentTabID && !tab.agentSession.isRunning && tab.isWebViewLoaded {
            tab.unloadWebView()
        }
    }

    func exportState() -> SavedBrowserTabsState {
        SavedBrowserTabsState(
            tabs: tabs.map { $0.exportSavedTab() },
            currentTabID: currentTabID,
            nextTabNumber: nextTabNumber
        )
    }

    // MARK: - Private

    private static func numericSuffix(of tabID: String) -> Int? {
        guard tabID.hasPrefix("t") else { return nil }
        return Int(tabID.dropFirst())
    }

    private func allocateTabID() -> String {
        while true {
            let candidate = "t\(nextTabNumber)"
            nextTabNumber += 1
            if !tabs.contains(where: { $0.id == candidate }) {
                return candidate
            }
        }
    }

    private func appendOrInsertTab(
        browser: ForumBrowserModel,
        after anchorTabID: String?
    ) -> BrowserTab {
        let id = allocateTabID()
        let tab = makeTab(id, UUID(), nil, browser)
        installTabHandlers(on: tab)
        if let anchorTabID, let anchorIndex = index(of: anchorTabID) {
            tabs.insert(tab, at: anchorIndex + 1)
        } else {
            tabs.append(tab)
        }
        return tab
    }

    private func installTabHandlers(on tab: BrowserTab) {
        let tabID = tab.id
        if tab.agentSession.isRunning {
            runningTabIDs.insert(tabID)
        }
        tab.agentSession.runStartGate = { [weak self] in
            guard let self else { return nil }
            return self.canStartRun(forTabID: tabID) ? nil : Self.runLimitMessage
        }
        tab.agentSession.onRunStateChanged = { [weak self] isRunning in
            self?.tabRunStateDidChange(tabID: tabID, isRunning: isRunning)
        }
        tab.onSnapshotChanged = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.onTabSnapshotUpdated?(tab)
        }
        tab.browser.onDidFinishPageLoad = { [weak self, weak tab] in
            guard let self, let tab else { return }
            Task { @MainActor [weak self, weak tab] in
                guard let self, let tab else { return }
                _ = await tab.captureSnapshotIfAvailable()
                self.onTabsMutated?()
            }
        }
        installPopupHandler(on: tab)
    }

    private func tabRunStateDidChange(tabID: String, isRunning: Bool) {
        if isRunning {
            tab(id: tabID)?.loadIfNeeded()
            runningTabIDs.insert(tabID)
        } else {
            runningTabIDs.remove(tabID)
            if runningTabIDs.count < Self.maxConcurrentRuns {
                for tab in tabs where tab.agentSession.runLimitNotice != nil {
                    tab.agentSession.clearRunLimitNotice()
                }
            }
        }
    }

    private func installPopupHandler(on tab: BrowserTab) {
        let sourceTabID = tab.id
        tab.browser.onCreatePopupWebView = { [weak self] configuration, navigationAction in
            self?.openPopupTab(
                from: sourceTabID,
                configuration: configuration,
                navigationAction: navigationAction
            )
        }
    }

    /// Handles `<a target="_blank">` and user-gesture `window.open`: opens a new
    /// front tab right after the opener tab (`design-browser-bar-tabs-models.md` §2).
    /// Returns `nil` and opens nothing when 30 tabs are already open.
    private func openPopupTab(
        from sourceTabID: String,
        configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction
    ) -> WKWebView? {
        guard canOpenTab else { return nil }
        guard navigationAction.targetFrame == nil else { return nil }
        if let url = navigationAction.request.url, !url.absoluteString.isEmpty {
            let isAbout = url.scheme?.lowercased() == "about"
            guard ForumBrowserModel.isBrowsableURL(url) || isAbout else { return nil }
        }
        let popupBrowser = makeBrowser(configuration, false, nil, "", .zero)
        if let url = navigationAction.request.url, ForumBrowserModel.isBrowsableURL(url) {
            popupBrowser.prepareForPopupNavigation(to: url)
        }
        let tab = appendOrInsertTab(browser: popupBrowser, after: sourceTabID)
        switchToTab(id: tab.id, notifyMutated: false)
        onTabsMutated?()
        return popupBrowser.webView
    }

    private func tearDown(_ tab: BrowserTab) {
        if tab.agentSession.isRunning {
            tab.agentSession.stop()
        }
        runningTabIDs.remove(tab.id)
        tab.onSnapshotChanged = nil
        tab.agentSession.runStartGate = nil
        tab.agentSession.onRunStateChanged = nil
        tab.agentSession.onRunFinished = nil
        tab.agentSession.onConversationChanged = nil
        tab.agentSession.onConversationReset = nil
        tab.confirmations.cancelAll()
        tab.browser.stopLoading()
        tab.browser.detachCallbacks()
        tab.scriptWebController.detach()
        tab.pageToolBridge.detach()
    }
}
