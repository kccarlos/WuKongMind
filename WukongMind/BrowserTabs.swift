import Combine
import Foundation
import WebKit

/// Small weak reference holder so closures created while wiring a tab or model
/// never form strong reference cycles.
final class WeakBox<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value? = nil) {
        self.value = value
    }
}

/// One open browser tab (`design-browser-bar-tabs-models.md` §2, T1): its own
/// `ForumBrowserModel` (`WKWebView` + `AgentBridge`), `BrowserAgentSession`,
/// live userscript controller, HTTP client, and confirmation queue.
@MainActor
final class BrowserTab: Identifiable {
    /// Short stable identifier (`"t1"`, `"t2"`, …).
    let id: String
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
        browser: ForumBrowserModel,
        pageToolBridge: PageToolBridge,
        scriptWebController: ScriptWebController,
        confirmations: AgentConfirmationGate,
        httpClient: AgentHTTPClient,
        agentSession: BrowserAgentSession,
        sessionBox: WeakBox<BrowserAgentSession>
    ) {
        self.id = id
        self.browser = browser
        self.pageToolBridge = pageToolBridge
        self.scriptWebController = scriptWebController
        self.confirmations = confirmations
        self.httpClient = httpClient
        self.agentSession = agentSession
        self.sessionBox = sessionBox
    }
}

/// Owns the open browser tabs (`BrowserTab`), all sharing one `WKWebsiteDataStore`
/// so forum and website sign-ins carry over across tabs. Always keeps at least
/// one tab open so `currentTab` is non-optional.
@MainActor
final class BrowserTabs: ObservableObject {
    @Published private(set) var tabs: [BrowserTab]
    @Published private(set) var currentTabID: String

    /// Shared website data store (cookies, storage, sessions) across all tabs.
    let websiteDataStore: WKWebsiteDataStore

    /// Notifies `AppModel` after the active tab changes `(newTab, oldTab)`.
    var onActiveTabChanged: ((BrowserTab, BrowserTab?) -> Void)?

    private var nextTabNumber: Int
    private let makeBrowser: (WKWebViewConfiguration?) -> ForumBrowserModel
    private let makeTab: (String, ForumBrowserModel) -> BrowserTab

    init(
        initialBrowser: ForumBrowserModel? = nil,
        sites: SiteRegistry = .standard,
        contentRules: ContentRuleLibrary? = nil,
        websiteDataStore: WKWebsiteDataStore? = nil,
        makeTab: @escaping (String, ForumBrowserModel) -> BrowserTab
    ) {
        let resolvedDataStore = initialBrowser?.webView.configuration.websiteDataStore
            ?? websiteDataStore
            ?? .default()
        let resolvedRules = initialBrowser?.contentBlocker.library ?? contentRules
        self.websiteDataStore = resolvedDataStore
        let browserFactory: (WKWebViewConfiguration?) -> ForumBrowserModel = { popupConfiguration in
            ForumBrowserModel(
                contentRules: resolvedRules,
                sites: sites,
                websiteDataStore: resolvedDataStore,
                popupConfiguration: popupConfiguration
            )
        }
        self.makeBrowser = browserFactory
        self.makeTab = makeTab

        let firstBrowser = initialBrowser ?? browserFactory(nil)
        let firstID = "t1"
        let firstTab = makeTab(firstID, firstBrowser)
        self.tabs = [firstTab]
        self.currentTabID = firstID
        self.nextTabNumber = 2
        installPopupHandler(on: firstTab)
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

    /// Opens a new tab. When `url` is nil the tab starts on Home; when `anchorTabID`
    /// is given the new tab is placed right after that tab, otherwise at the end.
    @discardableResult
    func openTab(
        url: URL? = nil,
        after anchorTabID: String? = nil,
        inFront: Bool = true
    ) -> BrowserTab {
        let browser = makeBrowser(nil)
        let tab = appendOrInsertTab(browser: browser, after: anchorTabID)
        if inFront {
            switchToTab(id: tab.id)
        }
        if let url, ForumBrowserModel.isBrowsableURL(url) {
            browser.load(url)
        }
        return tab
    }

    /// Makes `id` the active tab when it exists and isn't already active.
    @discardableResult
    func switchToTab(id: String) -> Bool {
        guard id != currentTabID, let newTab = tab(id: id) else {
            return id == currentTabID
        }
        let previousTab = currentTab
        currentTabID = id
        onActiveTabChanged?(newTab, previousTab)
        return true
    }

    /// Closes the tab with `id`, stopping any active Agent run in it. Closing the
    /// last remaining tab replaces it with a fresh Home tab so `currentTab` stays valid.
    @discardableResult
    func closeTab(id: String) -> Bool {
        guard let closingIndex = index(of: id) else { return false }
        let closingTab = tabs[closingIndex]
        tearDown(closingTab)

        if tabs.count == 1 {
            let replacement = appendOrInsertTab(browser: makeBrowser(nil), after: nil)
            tabs.remove(at: closingIndex)
            currentTabID = replacement.id
            onActiveTabChanged?(replacement, closingTab)
            return true
        }

        let wasCurrent = closingTab.id == currentTabID
        tabs.remove(at: closingIndex)
        if wasCurrent {
            let nextIndex = min(closingIndex, tabs.count - 1)
            let nextTab = tabs[nextIndex]
            currentTabID = nextTab.id
            onActiveTabChanged?(nextTab, closingTab)
        }
        return true
    }

    // MARK: - Private

    private func allocateTabID() -> String {
        let id = "t\(nextTabNumber)"
        nextTabNumber += 1
        return id
    }

    private func appendOrInsertTab(
        browser: ForumBrowserModel,
        after anchorTabID: String?
    ) -> BrowserTab {
        let id = allocateTabID()
        let tab = makeTab(id, browser)
        installPopupHandler(on: tab)
        if let anchorTabID, let anchorIndex = index(of: anchorTabID) {
            tabs.insert(tab, at: anchorIndex + 1)
        } else {
            tabs.append(tab)
        }
        return tab
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
    private func openPopupTab(
        from sourceTabID: String,
        configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if let url = navigationAction.request.url, !url.absoluteString.isEmpty {
            let isAbout = url.scheme?.lowercased() == "about"
            guard ForumBrowserModel.isBrowsableURL(url) || isAbout else { return nil }
        }
        let popupBrowser = makeBrowser(configuration)
        if let url = navigationAction.request.url, ForumBrowserModel.isBrowsableURL(url) {
            popupBrowser.prepareForPopupNavigation(to: url)
        }
        let tab = appendOrInsertTab(browser: popupBrowser, after: sourceTabID)
        switchToTab(id: tab.id)
        return popupBrowser.webView
    }

    private func tearDown(_ tab: BrowserTab) {
        if tab.agentSession.isRunning {
            tab.agentSession.stop()
        }
        tab.confirmations.cancelAll()
        tab.browser.stopLoading()
        tab.browser.detachCallbacks()
        tab.scriptWebController.detach()
        tab.pageToolBridge.detach()
    }
}
