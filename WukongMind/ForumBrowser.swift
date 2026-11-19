import Combine
import OSLog
import SwiftUI
import WebKit

/// The embedded browser. Any http(s) page can be opened (so shared links
/// always open); after each navigation an in-page probe collects the page's
/// facts, the registry's recognizers decide whether the page is a forum of a
/// supported platform, and the browser publishes `pageContext`.
///
/// API used by the UI:
/// - `pageContext` — current page (url, site, siteURL, forumName,
///   iconURL, topic?, state: loading/notForum/maybe/forumHome/topic).
/// - `homeSiteURL` — the current forum (last forum shown).
/// - `load(_:)`, `open(address:)`, `loadHome(adapter:)` (false with no forum),
///   `loadLogin()`, back/forward/reload/stop.
/// - `contentBlocker` — built-in ad/tracker blocking (ContentBlocker.swift);
///   its lists follow each main-frame navigation.
/// - The browser bridge (BrowseBridge.swift): `scrollToPost`, `highlight`,
///   `clearHighlight`, `postsOnScreen`, `postText`; the posts on screen
///   arrive in `pageContext` (`visiblePosts`, `highlightedPosts`).
/// The browser facts the AI drawer reads (design-performance-and-state.md, task 3).
struct DrawerPageFacts: Equatable, Sendable {
    var url: URL?
    var host: String?
    var showsHome = true
    var isLoading = false
    var pageState: PageContext.State = .loading
    var pageSiteURL: String?
    var looksLikeThread = false
}

/// Publishes `DrawerPageFacts` only when it changes so progress, scroll, focus
/// and back/forward updates on `ForumBrowserModel` never invalidate the drawer.
@MainActor
final class DrawerPageFactsStore: ObservableObject {
    @Published private(set) var facts = DrawerPageFacts()

    fileprivate func update(_ next: DrawerPageFacts) {
        guard next != facts else { return }
        PerfProbe.hit("publish.DrawerPageFacts")
        facts = next
    }
}

@MainActor
final class ForumBrowserModel: NSObject, ObservableObject {
    private static let routeMessageName = "dcRouteChanged"
    /// The route observer, with the registry's probe inside it. It posts the
    /// document's facts once (after the head is parsed), and again only when a
    /// `<head>` `<link>`/`<meta>` element or an `html`/`body` class changes;
    /// every other message carries just the route, and Swift keeps the facts.
    nonisolated static func routeObserverScript(probeExpression: String) -> String {
        """
        (() => {
          if (window.__dcRouteObserverInstalled) return;
          window.__dcRouteObserverInstalled = true;

          const probe = \(probeExpression);
          let notificationTimer;
          let factsPosted = false;
          let lastUrl;
          let lastTitle;
          const publishRoute = () => {
            // The head is not parsed yet while loading; probing then would
            // report every page as "not a forum".
            const sendFacts = document.readyState !== "loading" && !factsPosted;
            const url = window.location.href;
            const title = document.title || "";
            if (!sendFacts && url === lastUrl && title === lastTitle) return;
            if (sendFacts) factsPosted = true;
            lastUrl = url;
            lastTitle = title;
            window.webkit?.messageHandlers?.dcRouteChanged?.postMessage({
              url,
              title,
              probe: sendFacts ? probe() : null
            });
          };
          const scheduleRoutePublish = () => {
            window.clearTimeout(notificationTimer);
            notificationTimer = window.setTimeout(publishRoute, 0);
          };

          for (const methodName of ["pushState", "replaceState"]) {
            const original = window.history[methodName];
            window.history[methodName] = function(...argumentsList) {
              const result = original.apply(this, argumentsList);
              scheduleRoutePublish();
              return result;
            };
          }

          window.addEventListener("popstate", scheduleRoutePublish);
          window.addEventListener("hashchange", scheduleRoutePublish);
          // A page restored from the back-forward cache keeps this script but
          // the app dropped its facts when the navigation committed.
          window.addEventListener("pageshow", event => {
            if (event.persisted) factsPosted = false;
            scheduleRoutePublish();
          });

          const touchesFacts = node =>
            node?.nodeType === 1 &&
            (node.nodeName === "LINK" ||
              node.nodeName === "META" ||
              Boolean(node.querySelector?.("link, meta")));
          const observeHead = () => {
            if (!document.head) return;
            new MutationObserver(mutations => {
              for (const mutation of mutations) {
                if (mutation.type === "attributes") {
                  if (touchesFacts(mutation.target)) factsPosted = false;
                } else if (mutation.type === "childList") {
                  for (const node of mutation.addedNodes) {
                    if (touchesFacts(node)) factsPosted = false;
                  }
                  for (const node of mutation.removedNodes) {
                    if (touchesFacts(node)) factsPosted = false;
                  }
                }
              }
              scheduleRoutePublish();
            }).observe(document.head, {
              childList: true,
              subtree: true,
              characterData: true,
              attributes: true,
              attributeFilter: ["href", "content", "rel", "name", "property"]
            });
          };
          const observeAuthentication = () => {
            const targets = [document.documentElement, document.body]
              .filter(Boolean);
            const observer = new MutationObserver(() => {
              factsPosted = false;
              scheduleRoutePublish();
            });
            for (const target of targets) {
              observer.observe(target, {
                attributes: true,
                attributeFilter: ["class"]
              });
            }
          };
          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", () => {
              observeHead();
              observeAuthentication();
              scheduleRoutePublish();
            }, { once: true });
          } else {
            observeHead();
            observeAuthentication();
          }
          scheduleRoutePublish();
        })();
        """
    }

    static let defaultPageTitle = "WukongMind"

    /// Isolated-world focus observer (`BrowseScript.world`) that reports whether an editable
    /// web-page form control (`<input>`, `<textarea>`, `<select>`, or `contenteditable`) is focused.
    nonisolated static let formFocusObserverScript = """
    (() => {
      if (window.__dcFormFocusInstalled) return;
      window.__dcFormFocusInstalled = true;
      const nonTextTypes = new Set([
        "button", "checkbox", "color", "file", "hidden", "image", "radio", "range", "reset", "submit"
      ]);
      const isEditableControl = el => {
        if (!el || el === document.body || el === document.documentElement) return false;
        if (el.isContentEditable) return true;
        const tag = (el.tagName || "").toUpperCase();
        if (tag === "TEXTAREA" || tag === "SELECT") return true;
        if (tag === "INPUT") {
          const type = (el.type || "text").toLowerCase();
          return !nonTextTypes.has(type) && !el.readOnly && !el.disabled;
        }
        return false;
      };
      let lastEditing = false;
      const post = editing => {
        if (editing !== lastEditing) {
          lastEditing = editing;
          window.webkit?.messageHandlers?.wukongmindBrowse?.postMessage({ formEditing: editing });
        }
      };
      const reportActive = () => {
        post(isEditableControl(document.activeElement));
      };
      const onFocusIn = event => {
        if (isEditableControl(event.target)) {
          post(true);
        }
        window.setTimeout(reportActive, 0);
      };
      const onFocusOut = () => {
        window.setTimeout(reportActive, 0);
      };
      document.addEventListener("focusin", onFocusIn, true);
      document.addEventListener("focus", reportActive, true);
      document.addEventListener("focusout", onFocusOut, true);
      document.addEventListener("blur", onFocusOut, true);
      window.addEventListener("focusin", onFocusIn, true);
      window.addEventListener("focusout", onFocusOut, true);
      window.addEventListener("pagehide", () => { post(false); });
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", reportActive, { once: true });
      } else {
        reportActive();
      }
    })();
    """

    @Published private(set) var currentURL: URL? {
        didSet {
            PerfProbe.hit("publish.browser.currentURL")
            syncDrawerFacts()
        }
    }
    @Published private(set) var pageTitle = ForumBrowserModel.defaultPageTitle { didSet { PerfProbe.hit("publish.browser.pageTitle") } }
    @Published private(set) var isLoading = false {
        didSet {
            PerfProbe.hit("publish.browser.isLoading")
            syncDrawerFacts()
        }
    }
    @Published private(set) var canGoBack = false { didSet { PerfProbe.hit("publish.browser.canGoBack") } }
    @Published private(set) var canGoForward = false { didSet { PerfProbe.hit("publish.browser.canGoForward") } }
    @Published private(set) var isAuthenticated = false { didSet { PerfProbe.hit("publish.browser.isAuthenticated") } }
    /// The signed-in user's name when the forum's page reports it (memory
    /// only; never saved or synced).
    @Published private(set) var signedInUsername: String? { didSet { PerfProbe.hit("publish.browser.signedInUsername") } }
    /// Safari-style chrome: derived from `barProgress` with 0.6 / 0.4 hysteresis.
    @Published private(set) var isChromeMinimized = false { didSet { PerfProbe.hit("publish.browser.isChromeMinimized") } }
    /// Whether the browser address field is currently being edited.
    @Published private(set) var isEditingAddress = false { didSet { PerfProbe.hit("publish.browser.isEditingAddress") } }
    /// Whether an editable form control inside the web page currently owns focus.
    @Published private(set) var isPageFormInputFocused = false { didSet { PerfProbe.hit("publish.browser.isPageFormInputFocused") } }
    /// Whether UIKit's software keyboard or input-assistant bar currently overlaps the screen.
    @Published private(set) var isSystemKeyboardVisible = false { didSet { PerfProbe.hit("publish.browser.isSystemKeyboardVisible") } }
    /// True while the AI drawer's composer owns first responder; transient keyboard hide→show
    /// churn is gated until the composer resigns first responder so `ForumBrowserModel` does
    /// not publish mid-keystroke.
    private(set) var isDrawerComposerFocused = false
    private var hasPendingSystemKeyboardHide = false
    /// Additional page-keyboard freeze signal reported by the UIKit/SwiftUI keyboard observers.
    private var isExternalKeyboardFrozen = false
    /// Dedicated publisher of the small slice of page facts the AI drawer reads.
    let drawerFacts = DrawerPageFactsStore()
    var drawerPageFacts: DrawerPageFacts { drawerFacts.facts }
    /// Dedicated live progress publisher (`0` expanded … `1` collapsed) observed only by the morphing bar.
    let barProgressModel = BrowserBarProgressModel()
    var barProgress: CGFloat { barProgressModel.progress }
    var barMorphState: BrowserBarMorphState { barMorph.state }
    #if DEBUG
    /// Incremented under `-dc-browse-debug` so `BrowserBarDebugState` tracks scroll offset even while `p` is clamped.
    @Published private(set) var barDebugTick = 0
    #endif
    /// Scroll-driven morph state and `WKWebView.scrollView` delegate coordinator.
    let barMorph = BrowserBarScrollCoordinator()
    /// What the assistant knows about the current page.
    @Published private(set) var pageContext = PageContext.empty {
        didSet {
            PerfProbe.hit("publish.browser.pageContext")
            syncDrawerFacts()
        }
    }
    /// The current forum: the last Discourse forum shown (or opened by the app).
    /// Home and relative addresses resolve against it.
    @Published var homeSiteURL: String? { didSet { PerfProbe.hit("publish.browser.homeSiteURL") } }
    /// Page load progress (0…1) from WKWebView, for the bar's progress line.
    @Published private(set) var estimatedProgress: Double = 0 { didSet { PerfProbe.hit("publish.browser.estimatedProgress") } }
    /// Home is requested over the current page (the forum menu's Home, the
    /// launch rule). Any navigation clears it.
    @Published private(set) var isForumsHomeRequested = false {
        didSet {
            PerfProbe.hit("publish.browser.isForumsHomeRequested")
            syncDrawerFacts()
        }
    }
    /// Home was shown over a load already under way (the restored forum at
    /// launch): that load's start doesn't dismiss it. Ends when the load
    /// finishes or fails, or with the next explicit load.
    private var holdsHomeOverLoad = false
    /// Whether the active provisional navigation started from the Forums home;
    /// restored if provisional navigation fails so a failed tap from Home never
    /// dumps the reader onto an unrelated earlier page.
    private var loadStartedFromForumsHome = false
    /// Suppresses the error alert for the automatic background restore at launch.
    private var suppressLoadError = false
    #if DEBUG
    /// Sample launches seed fake domains whose loads are not meant to alert.
    var ignoresNavigationFailures = false
    var visiblePostsOverride: [VisiblePost]?
    private var activeSamplePage: (html: String, url: URL)?
    #endif
    /// The page's web content process quit repeatedly; auto-reload paused
    /// and the page shows a small Reload banner.
    @Published private(set) var showsCrashNotice = false { didSet { PerfProbe.hit("publish.browser.showsCrashNotice") } }
    /// "This page wants to open <app>": a small banner, never a modal.
    @Published private(set) var appOpenPrompt: AppOpenPrompt? { didSet { PerfProbe.hit("publish.browser.appOpenPrompt") } }
    /// Set by AppModel from Settings.
    var linkSettings = LinkSettings()
    /// When the web content process last quit (auto-reload once per window).
    private var contentTerminations: [Date] = []
    /// One automatic reload per this many seconds; a second crash inside it
    /// shows the banner instead (no reload loop).
    nonisolated static let crashReloadWindow: TimeInterval = 30
    private static let log = Logger(subsystem: AppIdentity.identifierPrefix, category: "browser")

    /// True while Home is shown by the launch rule over a restored tab's page,
    /// so saving tabs while viewing Today's launch screen keeps the tab's URL.
    private(set) var isLaunchHomeOverlay = false

    /// The Forums home is shown instead of the web view: requested, or no
    /// page has been loaded yet.
    var showsForumsHome: Bool { isForumsHomeRequested || currentURL == nil }

    private func syncDrawerFacts() {
        let home = showsForumsHome
        let url = home ? nil : (currentURL ?? pageContext.url)
        let host = url?.host.flatMap { $0.isEmpty ? nil : $0 }
        drawerFacts.update(DrawerPageFacts(
            url: url,
            host: host,
            showsHome: home,
            isLoading: isLoading,
            pageState: pageContext.state,
            pageSiteURL: pageContext.siteURL,
            looksLikeThread: pageContext.looksLikeThread
        ))
    }

    /// `overPendingLoad`: keep Home up while a load issued earlier (the
    /// restored forum) starts.
    func showForumsHome(overPendingLoad: Bool = false) {
        isLaunchHomeOverlay = overPendingLoad
        if overPendingLoad,
           deferredLoad != nil || allocatedWebView?.isLoading == true || (currentURL != nil && allocatedWebView?.url == nil) {
            holdsHomeOverLoad = true
        }
        if !isForumsHomeRequested { isForumsHomeRequested = true }
        if isEditingAddress { isEditingAddress = false }
        if isPageFormInputFocused { isPageFormInputFocused = false }
        syncPageKeyboardFreeze()
    }

    /// Incremented by `focusAddressBar()` (⌘L) so `AddressEditBar` focuses its
    /// field directly even inside a `NavigationStack` overlay.
    @Published private(set) var addressFocusRequest = 0 { didSet { PerfProbe.hit("publish.browser.addressFocusRequest") } }

    func setEditingAddress(_ editing: Bool) {
        if editing {
            allocatedWebView?.endEditing(true)
            _ = allocatedWebView?.resignFirstResponder()
        } else if isEditingAddress {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
        if isEditingAddress != editing {
            isEditingAddress = editing
        }
        syncPageKeyboardFreeze()
    }

    func focusAddressBar() {
        expandChrome(deferIfTracking: false)
        setEditingAddress(true)
        addressFocusRequest &+= 1
    }

    func setPageFormInputFocused(_ focused: Bool) {
        if isPageFormInputFocused != focused {
            isPageFormInputFocused = focused
        }
        syncPageKeyboardFreeze()
    }

    func setDrawerComposerFocused(_ focused: Bool) {
        isDrawerComposerFocused = focused
        if !focused, hasPendingSystemKeyboardHide {
            hasPendingSystemKeyboardHide = false
            if isSystemKeyboardVisible {
                isSystemKeyboardVisible = false
            }
        }
    }

    func setSystemKeyboardVisible(_ visible: Bool, force: Bool = false) {
        if visible {
            hasPendingSystemKeyboardHide = false
            if !isSystemKeyboardVisible {
                isSystemKeyboardVisible = true
            }
            return
        }
        guard isSystemKeyboardVisible else {
            hasPendingSystemKeyboardHide = false
            return
        }
        if isDrawerComposerFocused, !force {
            hasPendingSystemKeyboardHide = true
        } else {
            hasPendingSystemKeyboardHide = false
            isSystemKeyboardVisible = false
        }
    }

    func setExternalKeyboardFrozen(_ frozen: Bool) {
        if isExternalKeyboardFrozen != frozen {
            isExternalKeyboardFrozen = frozen
        }
        syncPageKeyboardFreeze()
    }

    private func syncPageKeyboardFreeze() {
        let shouldFreeze = !isEditingAddress && !showsForumsHome && (isPageFormInputFocused || isExternalKeyboardFrozen)
        barMorph.setPageKeyboardFrozen(shouldFreeze)
    }

    /// Returns to the page under Home (no-op without one).
    func hideForumsHome() {
        isLaunchHomeOverlay = false
        holdsHomeOverLoad = false
        loadStartedFromForumsHome = false
        if isForumsHomeRequested { isForumsHomeRequested = false }
        syncPageKeyboardFreeze()
    }

    private let contentRulesLibrary: ContentRuleLibrary
    private let explicitWebsiteDataStore: WKWebsiteDataStore?
    private var contentBlockingPolicy = ContentBlockingPolicy()
    private var allocatedWebView: WKWebView?
    private var allocatedContentBlocker: ContentBlocker?

    /// Whether this tab currently has an allocated `WKWebView` (false for lazy-restored
    /// background tabs and idle tabs unloaded under memory pressure).
    @Published private(set) var isWebViewLoaded: Bool { didSet { PerfProbe.hit("publish.browser.isWebViewLoaded") } }
    /// Last known scroll offset of the page (preserved across lazy restore and memory-pressure unload;
    /// non-`@Published` so KVO scroll ticks do not republish `ForumBrowserModel` every frame).
    private(set) var scrollPosition: CGPoint = .zero
    private var pendingScrollRestore: CGPoint?

    /// Existing `WKWebView` without allocating one when unloaded.
    var existingWebView: WKWebView? { allocatedWebView }
    var contentRules: ContentRuleLibrary { contentRulesLibrary }
    var configuredWebsiteDataStore: WKWebsiteDataStore {
        allocatedWebView?.configuration.websiteDataStore ?? explicitWebsiteDataStore ?? .default()
    }

    var webView: WKWebView { ensureWebView() }
    /// Page-tool bridge (`read_page`, `run_js`, `inject_css`, `wait_for`) and
    /// isolated-world reply channel for the browser agent.
    let agentBridge: AgentBridge
    /// Ad and tracker blocking for this web view.
    var contentBlocker: ContentBlocker {
        _ = ensureWebView()
        return allocatedContentBlocker!
    }
    /// Called when a `WKWebView` is created after a lazy start or memory-pressure unload.
    var onWebViewAttached: ((WKWebView) -> Void)?
    /// Called right before `unloadWebView()` tears down the `WKWebView`.
    var onWebViewDetached: (() -> Void)?
    /// Called when a main-frame load finishes so tab snapshots/scroll state can refresh.
    var onDidFinishPageLoad: (() -> Void)?
    /// A load issued while the compiled rule lists are still being looked up
    /// (launch); it starts when they are attached, or after a short cap.
    private var deferredLoad: URL?
    /// Tracks the current main-frame navigation so late IPC callbacks from a
    /// superseded navigation cannot overwrite flags of a newer load.
    private var activeNavigation: WKNavigation?
    private var activeNavigationStarted = false
    /// The agent's `navigate` or `reload_page` waiting for its load to end.
    fileprivate var agentNavigationWaiter: AgentNavigationWaiter?
    /// The main document's HTTP status of the latest response.
    fileprivate var mainDocumentStatus: Int?
    /// The longest a load waits for rule-list lookups (never for compiling).
    static let ruleLookupWait: Duration = .milliseconds(300)
    /// Called whenever `pageContext` changes, apart from its position fields.
    var onPageContextChanged: ((PageContext) -> Void)?
    /// Called when a main-frame navigation fails (excluding cancellations).
    var onNavigationFailed: ((Error) -> Void)?
    /// Called when a main-frame `.user.js` navigation is stopped so the import sheet opens.
    var onUserScriptNavigation: ((URL) -> Void)?
    /// Called when a link with `target="_blank"` or user-gesture `window.open`
    /// requests a new window (`BrowserTabs` creates a front tab and returns its `WKWebView`).
    var onCreatePopupWebView: ((WKWebViewConfiguration, WKNavigationAction) -> WKWebView?)?
    /// Called when only the position fields of `pageContext` change (posts on
    /// screen, highlights, the topic's facts): cheap, and often while scrolling.
    var onPagePositionChanged: ((PageContext) -> Void)?
    /// The topic's facts when AppModel has them (post count, accepted answer).
    var topicFactsLookup: ((ForumTopic) -> TopicFacts?)?
    /// The bridge's latest scroll report (visible and highlighted posts).
    private var lastBridgeReport: BrowseBridgeReport?
    private let browseMessageHandler = BrowseMessageHandler()
    /// A highlight to re-apply once its topic is on screen (BrowseBridge.swift).
    var pendingHighlight: PendingHighlight?
    /// A citation jump on its way (smooth scroll, flash on arrival).
    var pendingJump: PostJump?
    /// The page height the app's result cards cover at the bottom.
    var coveredBottomInset: CGFloat = 0
    /// Directory lookup: pages on a known forum count as that platform before the
    /// probe reports.
    var knownForumLookup: ((URL) -> KnownForumSite?)?
    /// The platforms that recognize pages and read their signed-in state.
    let sites: SiteRegistry
    /// The probe the registry's recognizers declare (see `PageFactsProbe`).
    private let probeExpression: String
    /// The facts of the document on screen: posted once per document, kept
    /// across its routes, dropped when a navigation commits.
    private var lastFacts: PageFacts?
    private let routeMessageHandler = ForumRouteMessageHandler()
    private var scrollObservation: NSKeyValueObservation?
    private var progressObservation: NSKeyValueObservation?
    /// Fires when the user starts scrolling the page (once per drag), so the
    /// workspace knows the page is where they are working.
    let userInteraction = PassthroughSubject<Void, Never>()

    /// `contentRules` nil: the shared library (see `ContentBlocker.init`).
    init(
        contentRules: ContentRuleLibrary? = nil,
        sites: SiteRegistry = .standard,
        websiteDataStore: WKWebsiteDataStore? = nil,
        popupConfiguration: WKWebViewConfiguration? = nil,
        startsUnloaded: Bool = false,
        restoredURL: URL? = nil,
        restoredTitle: String = "",
        restoredScrollPosition: CGPoint = .zero
    ) {
        let contentRules = contentRules ?? .shared
        let probeExpression = sites.probeExpression
        self.sites = sites
        self.probeExpression = probeExpression
        self.contentRulesLibrary = contentRules
        self.explicitWebsiteDataStore = popupConfiguration?.websiteDataStore ?? websiteDataStore
        self.isWebViewLoaded = !startsUnloaded
        self.agentBridge = AgentBridge(webView: nil)
        super.init()
        agentBridge.navigator = self
        routeMessageHandler.browser = self
        browseMessageHandler.browser = self

        let trimmedRestoredTitle = restoredTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let restoredURL, Self.isBrowsableURL(restoredURL) {
            self.currentURL = restoredURL
            self.pageTitle = trimmedRestoredTitle.nonEmpty ?? Self.defaultPageTitle
            self.scrollPosition = CGPoint(x: max(0, restoredScrollPosition.x), y: max(0, restoredScrollPosition.y))
            self.isForumsHomeRequested = false
            self.pageContext = PageContext.make(
                url: restoredURL,
                title: trimmedRestoredTitle.nonEmpty,
                facts: nil,
                knownForum: nil,
                registry: sites
            )
            if let siteURL = self.pageContext.siteURL {
                self.homeSiteURL = siteURL
            }
        }

        if !startsUnloaded {
            _ = buildAndAttachWebView(popupConfiguration: popupConfiguration)
        }
        syncDrawerFacts()
    }

    @discardableResult
    private func ensureWebView() -> WKWebView {
        if let existing = allocatedWebView {
            return existing
        }
        let created = buildAndAttachWebView(popupConfiguration: nil)
        onWebViewAttached?(created)
        return created
    }

    private func buildAndAttachWebView(popupConfiguration: WKWebViewConfiguration?) -> WKWebView {
        let configuration: WKWebViewConfiguration
        if let popupConfiguration {
            // Keep WebKit's popup configuration (process pool, related web view,
            // and shared data store), with this tab's own content controller.
            popupConfiguration.userContentController = WKUserContentController()
            configuration = popupConfiguration
        } else {
            configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = explicitWebsiteDataStore ?? .default()
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = true
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            Self.disableWebKitScreenTimeForTesting(in: configuration)
        }
        #endif
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.routeObserverScript(probeExpression: probeExpression),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.formFocusObserverScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: BrowseScript.world
            )
        )
        // The in-page bridge scripts of every registered site scroll to,
        // highlight and read posts, in their own content world.
        for installer in sites.adapters.compactMap({ $0.capabilities.pageBridge?.bridgeInstaller }) {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: installer,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true,
                    in: BrowseScript.world
                )
            )
        }

        let createdWebView = WKWebView(frame: .zero, configuration: configuration)
        createdWebView.customUserAgent = LinkPolicy.userAgent(isPad: UIDevice.current.userInterfaceIdiom == .pad)
        let blocker = ContentBlocker(
            controller: configuration.userContentController,
            library: contentRulesLibrary
        )
        blocker.policy = contentBlockingPolicy
        allocatedWebView = createdWebView
        allocatedContentBlocker = blocker
        isWebViewLoaded = true
        agentBridge.attach(to: createdWebView)
        configuration.userContentController.add(
            routeMessageHandler,
            name: Self.routeMessageName
        )
        configuration.userContentController.add(
            browseMessageHandler,
            contentWorld: BrowseScript.world,
            name: BrowseScript.messageName
        )
        createdWebView.navigationDelegate = self
        createdWebView.uiDelegate = self
        createdWebView.allowsBackForwardNavigationGestures = true
        createdWebView.allowsLinkPreview = true
        createdWebView.scrollView.keyboardDismissMode = .interactive
        barMorph.onUserScrollBegan = { [weak self] in
            self?.userInteraction.send()
        }
        barMorph.onChange = { [weak self] state, transition in
            self?.applyBarMorphChange(state, transition: transition)
        }
        barMorph.attach(to: createdWebView.scrollView)
        scrollObservation = createdWebView.scrollView.observe(\.contentOffset, options: [.new]) {
            [weak self] scrollView, _ in
            Task { @MainActor [weak self] in
                self?.recordScrollPosition(from: scrollView)
            }
        }
        progressObservation = createdWebView.observe(\.estimatedProgress, options: [.new]) {
            [weak self] webView, _ in
            let progress = webView.estimatedProgress
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Coalesce tiny steps so the bar does not re-render constantly.
                if abs(progress - self.estimatedProgress) >= 0.02 || progress >= 1 || progress == 0 {
                    self.estimatedProgress = progress
                }
            }
        }
        return createdWebView
    }

    /// Allocates the `WKWebView` when this tab was lazy-restored or unloaded under
    /// memory pressure, and loads its saved page + scroll position.
    func loadIfNeeded() {
        guard !isWebViewLoaded else { return }
        _ = ensureWebView()
        if let url = currentURL, !isForumsHomeRequested, Self.isBrowsableURL(url) {
            load(url, silentOnFailure: true, restoringScroll: scrollPosition)
        }
    }

    /// Updates `scrollPosition` (for tests or before saving when scrolled via JS).
    func setSavedScrollPosition(_ position: CGPoint) {
        scrollPosition = CGPoint(x: max(0, position.x), y: max(0, position.y))
    }

    /// Reads the live scroll position from the `WKWebView` when loaded.
    func refreshScrollPositionFromWebView() {
        guard pendingScrollRestore == nil, let webView = allocatedWebView, webView.url != nil else { return }
        let inset = webView.scrollView.adjustedContentInset
        let offsetX = max(0, webView.scrollView.contentOffset.x + inset.left)
        let offsetY = max(0, webView.scrollView.contentOffset.y + inset.top)
        scrollPosition = CGPoint(x: offsetX, y: offsetY)
    }

    /// Drops the underlying `WKWebView` under memory pressure while keeping `currentURL`,
    /// `pageTitle`, `scrollPosition`, and `pageContext` so the tab reloads cleanly when shown.
    func unloadWebView() {
        guard let oldWebView = allocatedWebView else { return }
        refreshScrollPositionFromWebView()
        deferredLoad = nil
        activeNavigation = nil
        activeNavigationStarted = false
        finishAgentNavigation(.failed("Tab was unloaded."))
        scrollObservation?.invalidate()
        scrollObservation = nil
        progressObservation?.invalidate()
        progressObservation = nil
        onWebViewDetached?()
        agentBridge.detachWebView()
        oldWebView.stopLoading()
        oldWebView.scrollView.delegate = nil
        oldWebView.navigationDelegate = nil
        oldWebView.uiDelegate = nil
        let controller = oldWebView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.routeMessageName)
        controller.removeScriptMessageHandler(forName: BrowseScript.messageName, contentWorld: BrowseScript.world)
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        oldWebView.removeFromSuperview()
        allocatedContentBlocker = nil
        allocatedWebView = nil
        isWebViewLoaded = false
        isLoading = false
        barMorph.setLoading(false)
        estimatedProgress = 0
        canGoBack = false
        canGoForward = false
        showsCrashNotice = false
        appOpenPrompt = nil
    }

    /// Captures a lightweight thumbnail snapshot of the loaded page when available.
    func captureTabSnapshot(width: CGFloat = 360) async -> UIImage? {
        guard let webView = allocatedWebView,
              !showsForumsHome,
              currentURL != nil,
              webView.alpha > 0.01,
              webView.bounds.width > 1,
              webView.bounds.height > 1 else {
            return nil
        }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(width))
        return try? await webView.takeSnapshot(configuration: config)
    }

    func expandChrome(deferIfTracking: Bool = false) {
        barMorph.requestExpand(deferIfTracking: deferIfTracking)
    }

    private func recordScrollPosition(from scrollView: UIScrollView) {
        guard pendingScrollRestore == nil, !isLoading, allocatedWebView?.url != nil else { return }
        let offsetX = scrollView.contentOffset.x + scrollView.adjustedContentInset.left
        let offsetY = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        scrollPosition = CGPoint(x: max(0, offsetX), y: max(0, offsetY))
    }

    private func applyBarMorphChange(_ state: BrowserBarMorphState, transition: BrowserBarTransitionKind?) {
        #if DEBUG
        let tracksDebug = ProcessInfo.processInfo.arguments.contains("-dc-browse-debug")
        #endif
        if barMorph.reduceMotion {
            let targetProgress: CGFloat = state.reduceMotionCollapsed ? 1 : 0
            if isChromeMinimized != state.isChromeMinimized || barProgressModel.progress != targetProgress {
                withAnimation(.easeInOut(duration: BrowserBarMorphMetrics.reduceMotionCrossFadeDuration)) {
                    if isChromeMinimized != state.isChromeMinimized {
                        isChromeMinimized = state.isChromeMinimized
                    }
                    if barProgressModel.progress != targetProgress {
                        barProgressModel.progress = targetProgress
                    }
                    #if DEBUG
                    if tracksDebug { barDebugTick &+= 1 }
                    #endif
                }
            } else {
                #if DEBUG
                if tracksDebug {
                    var tx = Transaction(animation: nil)
                    tx.disablesAnimations = true
                    withTransaction(tx) { barDebugTick &+= 1 }
                }
                #endif
            }
            return
        }

        switch transition {
        case .spring(let target):
            withAnimation(
                .spring(
                    response: BrowserBarMorphMetrics.springResponse,
                    dampingFraction: BrowserBarMorphMetrics.springDamping
                )
            ) {
                barProgressModel.progress = target
                if isChromeMinimized != state.isChromeMinimized {
                    isChromeMinimized = state.isChromeMinimized
                }
                #if DEBUG
                if tracksDebug { barDebugTick &+= 1 }
                #endif
            }
        case .immediate, nil:
            var tx = Transaction(animation: nil)
            tx.disablesAnimations = true
            withTransaction(tx) {
                if barProgressModel.progress != state.progress {
                    barProgressModel.progress = state.progress
                }
                if isChromeMinimized != state.isChromeMinimized {
                    isChromeMinimized = state.isChromeMinimized
                }
                #if DEBUG
                if tracksDebug { barDebugTick &+= 1 }
                #endif
            }
        }
    }

    /// Loads the current forum's home, as `adapter` (the forum's) addresses it.
    /// Returns false (and does nothing) when there is no current forum or
    /// adapter; the UI then shows the Forums home.
    @discardableResult
    func loadHome(adapter: (any SiteAdapter)?, silentOnFailure: Bool = false) -> Bool {
        guard let homeSiteURL, let url = adapter?.links.homeURL(siteURL: homeSiteURL) else {
            return false
        }
        load(url, silentOnFailure: silentOnFailure)
        return true
    }

    func load(_ url: URL, silentOnFailure: Bool = false, restoringScroll: CGPoint? = nil) {
        guard Self.isBrowsableURL(url) else { return }
        if ScriptImporter.isUserScriptURL(url) {
            onUserScriptNavigation?(url)
            return
        }
        #if DEBUG
        activeSamplePage = nil
        #endif
        if let restoringScroll, restoringScroll.x > 0 || restoringScroll.y > 0 {
            pendingScrollRestore = CGPoint(x: max(0, restoringScroll.x), y: max(0, restoringScroll.y))
            scrollPosition = pendingScrollRestore!
        } else {
            pendingScrollRestore = nil
            scrollPosition = .zero
        }
        let startedFromHome = showsForumsHome || loadStartedFromForumsHome
        hideForumsHome()
        expandChrome(deferIfTracking: true)
        loadStartedFromForumsHome = startedFromHome
        suppressLoadError = silentOnFailure
        // The first load (the restored forum at launch) would otherwise leave
        // `currentURL` nil until WebKit reports the navigation, so the Forums
        // home flashes in and fades out on every launch. Navigation updates
        // replace this right away.
        if currentURL == nil { currentURL = url }
        if !contentBlocker.library.lookupsFinished {
            // Launch: give the already-compiled lists a moment to attach so
            // the first page is filtered too. Compiling is never waited for.
            let isWaiting = deferredLoad != nil
            deferredLoad = url
            activeNavigation = nil
            activeNavigationStarted = false
            guard !isWaiting else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.contentBlocker.library.waitForLookups(timeout: Self.ruleLookupWait)
                guard let url = self.deferredLoad else { return }
                self.deferredLoad = nil
                self.activeNavigation = self.webView.load(URLRequest(url: url))
                self.activeNavigationStarted = false
            }
            return
        }
        deferredLoad = nil
        activeNavigation = webView.load(URLRequest(url: url))
        activeNavigationStarted = false
    }

    #if DEBUG
    /// `-dc-sample`: shows the sample's own topic page at `url` (no network).
    func loadSamplePage(_ html: String, at url: URL) {
        deferredLoad = nil
        pendingScrollRestore = nil
        scrollPosition = .zero
        hideForumsHome()
        currentURL = url
        activeSamplePage = (html, url)
        activeNavigation = webView.loadHTMLString(html, baseURL: url)
        activeNavigationStarted = false
    }
    #endif

    /// Suspends while a navigation is in flight (queued, provisional or loading),
    /// at most `timeout`. A page still loading has no document to scroll yet, and
    /// a second `load` issued over it can be folded into the first one: WebKit
    /// then commits the first document under the second's address (observed on a
    /// topic opened at a post right after launch), so the page never lands.
    func waitUntilSettled(timeout: Duration = .seconds(15)) async {
        let deadline = ContinuousClock.now + timeout
        while deferredLoad != nil || allocatedWebView?.isLoading == true, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Opens an address typed into the bar. Returns false when it does not
    /// resolve to a web page.
    @discardableResult
    func open(address: String) -> Bool {
        guard let url = Self.resolveAddress(address, currentSiteURL: homeSiteURL) else {
            return false
        }
        load(url)
        return true
    }

    /// Accepts a full http(s) URL, a bare host (`meta.discourse.org/t/…`), or a
    /// path (`/t/…`, `t/…`) resolved against the current forum. Anything else
    /// (plain words, other schemes, a path with no current forum) is nil; the
    /// bar never turns text into a web search.
    nonisolated static func resolveAddress(_ address: String, currentSiteURL: String?) -> URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let lowercased = text.lowercased()
        var candidate: String
        if lowercased.range(of: "^[a-z][a-z0-9+.-]*://", options: .regularExpression) != nil {
            candidate = text
        } else if lowercased.range(of: "^[a-z][a-z0-9+.-]*:[^0-9]", options: .regularExpression) != nil
            || lowercased.range(of: "^[a-z][a-z0-9+.-]*:$", options: .regularExpression) != nil {
            // javascript:, mailto:, … (host:port is handled below).
            return nil
        } else if text.hasPrefix("//") {
            candidate = "https:" + text
        } else if text.hasPrefix("/") {
            // A path already under the base path ("/forum/t/…") is not
            // prefixed again.
            guard let site = ForumSite.parse(siteURL: currentSiteURL) else { return nil }
            let path = URLComponents(string: text)?.path ?? text
            candidate = ForumSite.hasBasePathPrefix(path, basePath: site.basePath)
                && !site.basePath.isEmpty
                ? site.origin + text
                : site.siteURL + text
        } else {
            let host = String(
                lowercased.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            )
            let hostName = host.split(separator: ":").first.map(String.init) ?? host
            if hostName.contains(".") || hostName == "localhost" {
                candidate = (hostName == "localhost" || hostName == "127.0.0.1" ? "http://" : "https://")
                    + text
            } else if text.contains("/"), let site = ForumSite.parse(siteURL: currentSiteURL) {
                candidate = site.siteURL + "/" + text
            } else {
                return nil
            }
        }
        guard let url = URL(string: candidate), isBrowsableURL(url) else { return nil }
        return url
    }

    func goBack() {
        guard let webView = allocatedWebView, webView.canGoBack else { return }
        suppressLoadError = false
        activeNavigation = webView.goBack()
        activeNavigationStarted = false
    }

    /// Back also leaves the Forums home when it covers a page.
    var canNavigateBack: Bool {
        (isForumsHomeRequested && currentURL != nil) || (canGoBack && !showsForumsHome)
    }

    func navigateBack() {
        if isForumsHomeRequested, currentURL != nil {
            hideForumsHome()
        } else {
            goBack()
        }
    }

    /// Pages behind the current one, most recent first (the title's
    /// long-press history menu).
    var backHistory: [WKBackForwardListItem] { allocatedWebView?.backForwardList.backList.reversed() ?? [] }
    var forwardHistory: [WKBackForwardListItem] { allocatedWebView?.backForwardList.forwardList ?? [] }

    func go(to item: WKBackForwardListItem) {
        let startedFromHome = showsForumsHome || loadStartedFromForumsHome
        hideForumsHome()
        expandChrome(deferIfTracking: true)
        loadStartedFromForumsHome = startedFromHome
        suppressLoadError = false
        activeNavigation = webView.go(to: item)
        activeNavigationStarted = false
    }

    func goForward() {
        guard let webView = allocatedWebView, webView.canGoForward else { return }
        suppressLoadError = false
        activeNavigation = webView.goForward()
        activeNavigationStarted = false
    }

    func reload() {
        suppressLoadError = false
        #if DEBUG
        if let sample = activeSamplePage, (allocatedWebView?.url ?? currentURL) == sample.url {
            activeNavigation = webView.loadHTMLString(sample.html, baseURL: sample.url)
            activeNavigationStarted = false
            return
        }
        #endif
        if !isWebViewLoaded {
            loadIfNeeded()
            return
        }
        activeNavigation = webView.reload()
        activeNavigationStarted = false
    }

    /// Primes a newly opened popup tab (`target="_blank"` or `window.open`) with
    /// its initial URL so it never flashes Home while WebKit starts loading.
    func prepareForPopupNavigation(to url: URL) {
        guard Self.isBrowsableURL(url) else { return }
        hideForumsHome()
        if currentURL == nil { currentURL = url }
    }

    /// Clears delegate-facing callbacks when closing a tab so late WebKit IPC
    /// from the closed web view cannot update app state.
    func detachCallbacks() {
        onPageContextChanged = nil
        onPagePositionChanged = nil
        onNavigationFailed = nil
        onUserScriptNavigation = nil
        onCreatePopupWebView = nil
        onWebViewAttached = nil
        onWebViewDetached = nil
        onDidFinishPageLoad = nil
        knownForumLookup = nil
        topicFactsLookup = nil
    }

    func stopLoading() {
        deferredLoad = nil
        activeNavigation = nil
        activeNavigationStarted = false
        allocatedWebView?.stopLoading()
        if isLoading { isLoading = false }
        barMorph.setLoading(false)
        finishAgentNavigation(.failed("Loading was stopped."))
    }

    /// Applies a new blocking policy right away. Returns true when it
    /// changes what is blocked on the page shown now (the caller reloads it).
    @discardableResult
    func applyContentBlocking(_ policy: ContentBlockingPolicy) -> Bool {
        contentBlockingPolicy = policy
        guard let blocker = allocatedContentBlocker else {
            return false
        }
        let pageURL = allocatedWebView?.url ?? currentURL
        let before = blocker.policy.activeCategories(forTopURL: pageURL)
        blocker.policy = policy
        let after = policy.activeCategories(forTopURL: pageURL)
        return before != after && pageURL.map(Self.isBrowsableURL) == true
    }

    /// Cookie header for one forum host (never another site's cookies).
    func cookieHeader(forHost host: String) async -> String? {
        let cookies = await configuredWebsiteDataStore.httpCookieStore.allCookies()
        let forumCookies = ForumSite.cookies(cookies, forHost: host)
        guard !forumCookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: forumCookies)["Cookie"]
    }

    /// Cookie header for a forum site URL.
    func cookieHeader(forSite siteURL: String) async -> String? {
        guard let host = ForumSite.parse(siteURL: siteURL)
            .flatMap({ URLComponents(string: $0.origin)?.host })
        else {
            return nil
        }
        return await cookieHeader(forHost: host)
    }

    /// Loads a forum resource. When the web view shows the same forum, fetch()
    /// runs in the page (with its Cloudflare clearance and Discourse session);
    /// otherwise the request goes out directly with that forum's cookies only.
    func fetchForumResource(_ url: URL) async throws -> ForumResourceResponse {
        guard Self.isBrowsableURL(url), let requestOrigin = ForumSite.origin(of: url) else {
            throw AssistantError.invalidResponse
        }

        // Restored tasks can resume before WKWebView finishes its first load.
        // Wait while it is still loading a page of the requested site.
        for _ in 0..<120 {
            try Task.checkCancellation()
            guard let liveWebView = allocatedWebView,
                  liveWebView.isLoading,
                  liveWebView.url.map({ ForumSite.origin(of: $0)?.origin == requestOrigin.origin }) ?? true
            else {
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        if let siteURL = pageContext.siteURL,
           let liveWebView = allocatedWebView,
           !liveWebView.isLoading,
           let current = liveWebView.url,
           ForumSite.isSameForum(url: current, siteURL: siteURL),
           ForumSite.isSameForum(url: url, siteURL: siteURL) {
            return try await fetchInPage(url)
        }
        return try await fetchDirect(url)
    }

    /// The page's own `fetch()`: given up after 60 s, or as soon as the
    /// calling task is cancelled (the script call itself ignores that).
    private func fetchInPage(_ url: URL) async throws -> ForumResourceResponse {
        let requestID = UUID().uuidString
        let page = webView
        let script = """
        const controller = new AbortController();
        const running = (window.__wukongmindFetches = window.__wukongmindFetches || {});
        running[requestID] = controller;
        const timer = setTimeout(() => controller.abort(), timeoutMilliseconds);
        try {
          const response = await fetch(resourceURL, {
            credentials: "include",
            cache: "no-store",
            headers: { "Accept": "application/json,text/plain,text/html,*/*" },
            signal: controller.signal
          });
          return {
            statusCode: response.status,
            statusText: response.statusText,
            headers: Object.fromEntries(response.headers),
            body: await response.text()
          };
        } finally {
          clearTimeout(timer);
          delete running[requestID];
        }
        """
        let value = try await withTaskCancellationHandler {
            try await page.callAsyncJavaScript(
                script,
                arguments: [
                    "resourceURL": url.absoluteString,
                    "requestID": requestID,
                    "timeoutMilliseconds": Self.inPageFetchTimeoutMilliseconds
                ],
                in: nil,
                contentWorld: .page
            )
        } onCancel: {
            Task { @MainActor in
                _ = try? await page.callAsyncJavaScript(
                    "const fetches = window.__wukongmindFetches; if (fetches && fetches[requestID]) fetches[requestID].abort();",
                    arguments: ["requestID": requestID],
                    in: nil,
                    contentWorld: .page
                )
            }
        }
        guard let result = value as? [String: Any],
              let statusCode = result["statusCode"] as? Int,
              let body = result["body"] as? String
        else {
            throw AssistantError.invalidResponse
        }
        return ForumResourceResponse(
            statusCode: statusCode,
            statusText: result["statusText"] as? String ?? "",
            headers: (result["headers"] as? [String: String]) ?? [:],
            data: Data(body.utf8)
        )
    }

    static let inPageFetchTimeoutMilliseconds = 60_000

    private func fetchDirect(_ url: URL) async throws -> ForumResourceResponse {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.httpShouldHandleCookies = false
        request.setValue("application/json,text/plain,text/html,*/*", forHTTPHeaderField: "Accept")
        if let host = url.host, let cookies = await cookieHeader(forHost: host) {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        // Redirects to another origin drop the forum's cookies.
        let (data, response) = try await URLSession.shared.data(
            for: request,
            delegate: ForumRedirectGuard.shared
        )
        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.invalidResponse
        }
        return ForumResourceResponse(
            statusCode: http.statusCode,
            statusText: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            headers: http.lowercasedHeaders,
            data: data
        )
    }

    func handleRouteMessage(
        urlString: String,
        title: String,
        probe: [String: Any]?,
        from sender: WKWebView?
    ) {
        // Only the web view this tab still shows may report. A message queued
        // before a memory-warning unload must not touch `webView`: that would
        // build a blank web view, the tab would look loaded and a lazy read
        // would skip reloading its page.
        guard let page = allocatedWebView, sender === page,
              let url = URL(string: urlString), Self.isBrowsableURL(url),
              Self.isRouteMessage(from: url, forPageAt: page.url)
        else {
            return
        }
        if let probe {
            PerfProbe.hit("publish.browser.caller.routeMessageProbe")
            // Facts a previous document posted just before it was replaced can
            // arrive while a new load is in flight or after didCommit cleared
            // them: only the shown page's own address may set them then.
            if lastFacts == nil || page.isLoading {
                guard Self.isSamePage(url, page.url, registry: sites) else { return }
            }
            lastFacts = PageFacts(probe: probe, fallbackURL: url)
        } else if lastFacts != nil {
            PerfProbe.hit("publish.browser.caller.routeMessageRouteOnly")
            // Another route of the same document: its facts still hold.
            lastFacts?.url = url
            lastFacts?.title = title
        } else {
            PerfProbe.hit("publish.browser.caller.routeMessageNoFacts")
        }
        updateNavigationState(url: url, title: title)
    }

    /// Route messages come from the page's own scripts, so any page (or an
    /// injected script on it) can post one. Only a message about the document
    /// the web view actually shows (same origin; SPA routes never change it)
    /// may update the page context; a message claiming another site is dropped.
    nonisolated static func isRouteMessage(from reportedURL: URL, forPageAt pageURL: URL?) -> Bool {
        guard let pageURL, let reported = webOrigin(of: reportedURL), let page = webOrigin(of: pageURL)
        else {
            return false
        }
        return reported == page
    }

    /// Same origin and the same page: the same loose topic ID when either URL
    /// carries one, otherwise the same path (query and fragment ignored). A
    /// forum rewrites its own address while the reader scrolls (`/t/slug/1` to
    /// `/t/slug/1/42`); the document is still the shown one.
    nonisolated static func isSamePage(_ reported: URL, _ shown: URL?, registry: SiteRegistry) -> Bool {
        guard let shown, let reportedOrigin = webOrigin(of: reported), reportedOrigin == webOrigin(of: shown) else {
            return false
        }
        let reportedTopic = registry.looseTopicID(in: reported)
        let shownTopic = registry.looseTopicID(in: shown)
        if reportedTopic != nil || shownTopic != nil {
            return reportedTopic == shownTopic
        }
        func path(_ url: URL) -> String { url.path.isEmpty ? "/" : url.path }
        return path(reported) == path(shown)
    }

    /// `scheme://host[:port]` of an http(s) URL, default port omitted.
    private nonisolated static func webOrigin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty
        else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        guard let port = url.port, port != defaultPort else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    /// Runs the probe once a load finishes, so every page settles into a
    /// state even if the route observer did not report it.
    private func probeCurrentPage() async {
        guard let webView = allocatedWebView, let url = webView.url, Self.isBrowsableURL(url) else { return }
        do {
            let value = try await webView.callAsyncJavaScript(
                "return (\(probeExpression))();",
                arguments: [:],
                in: nil,
                contentWorld: .defaultClient
            )
            // Unloaded (or replaced) while the probe ran: its answer is about a
            // page this tab no longer shows, and the state update would read a
            // new blank web view's nil address over the saved one.
            guard allocatedWebView === webView else { return }
            if let result = value as? [String: Any] {
                lastFacts = PageFacts(probe: result, fallbackURL: url)
            }
        } catch {
            guard allocatedWebView === webView else { return }
            // No document to inspect (error page, download): not a forum.
            lastFacts = PageFacts(url: url)
        }
        updateNavigationState()
    }

    /// Recomputes the page context (e.g. after the forum directory changed).
    func refreshPageContext() {
        updateNavigationState()
    }

    // MARK: Web content process crashes

    /// WebKit killed or lost the page's content process (memory pressure,
    /// a crash): the view goes blank and `isLoading` can stay true (a
    /// spinning Stop). Reload the page once; if it keeps dying within
    /// `crashReloadWindow`, stop and show the banner.
    func handleWebContentTermination(now: Date = Date()) {
        contentTerminations = contentTerminations.filter { now.timeIntervalSince($0) < Self.crashReloadWindow }
        contentTerminations.append(now)
        // The address the user saw: after an in-page (SPA) route change the dead
        // process leaves `webView.url` on the last full load.
        let url = currentURL ?? webView.url
        let reloads = contentTerminations.count == 1 && url.map(Self.isBrowsableURL) == true
        Self.log.notice(
            "Web content process ended (\(self.contentTerminations.count, privacy: .public) in \(Int(Self.crashReloadWindow), privacy: .public) s); \(reloads ? "reloading" : "showing notice", privacy: .public)"
        )
        if reloads, let url {
            // Give WebKit a moment to tear the dead process down: a load
            // issued inside this callback can fail to launch a new one and
            // report a second termination straight away.
            let generation = contentTerminations.count
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, self.contentTerminations.count == generation else { return }
                self.webView.load(URLRequest(url: url))
            }
        } else {
            webView.stopLoading()
        }
        // A dead page reports no title; keep the one the user saw.
        updateNavigationState(url: url, title: webView.title?.nonEmpty ?? pageTitle)
        // WebKit can still report the dead load; the bar shows Reload, not Stop.
        if !reloads { isLoading = false }
        estimatedProgress = 0
        showsCrashNotice = !reloads && url != nil
    }

    /// The banner's Reload: an explicit retry resets the crash window.
    func retryAfterCrash() {
        contentTerminations.removeAll()
        showsCrashNotice = false
        if let url = currentURL ?? webView.url {
            load(url)
        }
    }

    func dismissCrashNotice() {
        showsCrashNotice = false
    }

    #if DEBUG
    func simulatePageUpdateForTesting(url: URL? = nil, title: String? = nil) {
        hideForumsHome()
        updateNavigationState(url: url, title: title)
    }
    #endif

    private func updateNavigationState(
        url: URL? = nil,
        title: String? = nil
    ) {
        PerfProbe.hit("publish.browser.caller.updateNavigationState")
        let resolvedURL: URL?
        let resolvedTitle: String?
        let nextBack: Bool
        let nextForward: Bool
        let nextLoading: Bool
        if let liveWebView = allocatedWebView {
            resolvedURL = url ?? liveWebView.url
            resolvedTitle = title ?? liveWebView.title
            nextBack = liveWebView.canGoBack
            nextForward = liveWebView.canGoForward
            nextLoading = liveWebView.isLoading
        } else {
            resolvedURL = url ?? currentURL
            resolvedTitle = title ?? pageTitle.nonEmpty
            nextBack = false
            nextForward = false
            nextLoading = false
        }
        if canGoBack != nextBack { canGoBack = nextBack }
        if canGoForward != nextForward { canGoForward = nextForward }
        if isLoading != nextLoading { isLoading = nextLoading }
        if currentURL != resolvedURL { currentURL = resolvedURL }
        let nextTitle = resolvedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? Self.defaultPageTitle
        if pageTitle != nextTitle { pageTitle = nextTitle }
        barMorph.setLoading(isLoading)

        let made = PageContext.make(
            url: resolvedURL,
            title: resolvedTitle,
            facts: lastFacts,
            knownForum: resolvedURL.flatMap { knownForumLookup?($0) },
            registry: sites
        )
        let context = made.merging(
            report: lastBridgeReport, facts: made.topic.flatMap { topicFactsLookup?($0) }, registry: sites
        )
        applySession(of: made)
        if let siteURL = context.siteURL, homeSiteURL != siteURL {
            homeSiteURL = siteURL
        }
        publish(context)
    }

    /// Signed-in state and username, read from the document's facts by the
    /// page's own platform (nothing on a page that is not a forum).
    private func applySession(of context: PageContext) {
        let reader = context.site.flatMap(sites.adapter(for:))?.capabilities.session
        let session = lastFacts.flatMap { reader?.session(from: $0) }
        let authenticated = session?.authenticated ?? false
        if isAuthenticated != authenticated { isAuthenticated = authenticated }
        let name = authenticated ? session?.username.flatMap { String($0.prefix(60)).nonEmpty } : nil
        if signedInUsername != name { signedInUsername = name }
    }

    #if DEBUG
    /// Tests: sees every script about to go into the page, before the web view is asked.
    var scriptSpy: ((String) -> Void)?

    /// Tests: the page context the web view would have reported, set without
    /// the callbacks (the test then calls them as it needs).
    func setPageContext(_ context: PageContext) {
        pageContext = context
    }
    #endif

    /// Publishes a new page context: the full callback for a new page or
    /// route, the cheap one when only the position fields changed.
    private func publish(_ context: PageContext) {
        guard context != pageContext else { return }
        let topicChanged = context.topic?.topicKey != pageContext.topic?.topicKey
            || context.state != pageContext.state
        let positionOnly = context.sameDocument(as: pageContext)
        pageContext = context
        if positionOnly {
            onPagePositionChanged?(context)
        } else {
            onPageContextChanged?(context)
        }
        if topicChanged { applyPendingHighlight() }
    }

    /// The bridge reported the posts on screen (debounced in the page).
    func handleBridgeReport(_ report: BrowseBridgeReport) {
        guard let url = webView.url, Self.isRouteMessage(from: report.url, forPageAt: url) else { return }
        lastBridgeReport = report
        publish(pageContext.merging(
            report: report, facts: pageContext.topic.flatMap { topicFactsLookup?($0) }, registry: sites
        ))
    }

    /// AppModel has new facts for the page's topic.
    func refreshTopicFacts() {
        publish(pageContext.merging(
            report: lastBridgeReport, facts: pageContext.topic.flatMap { topicFactsLookup?($0) }, registry: sites
        ))
    }

    /// The page's own site's DOM scripts; nil on a page that is not a forum
    /// or whose site has none. Every script call into the page needs it.
    var pageBridge: PageBridgeProfile? {
        pageContext.site.flatMap(sites.adapter(for:))?.capabilities.pageBridge
    }

    /// Whether visible-post translation is available on the current page.
    var canTranslatePostsOnScreen: Bool {
        !isForumsHomeRequested && pageContext.topic != nil && pageBridge?.bridgeInstaller != nil && ReadingLanguage.isTranslationAvailable
    }

    /// Pages the browser may show: http and https.
    nonisolated static func isBrowsableURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty
        else {
            return false
        }
        return true
    }
}

private final class ForumRouteMessageHandler: NSObject, WKScriptMessageHandler {
    weak var browser: ForumBrowserModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // The observer script runs in the main frame only; iframes (ads,
        // embeds) can still reach the handler, so their messages are ignored.
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let urlString = body["url"] as? String
        else {
            return
        }
        let title = body["title"] as? String ?? ""
        let probe = body["probe"] as? [String: Any]
        nonisolated(unsafe) let sendableProbe = probe
        let sender = message.webView
        Task { @MainActor [weak browser, weak sender] in
            browser?.handleRouteMessage(
                urlString: urlString,
                title: title,
                probe: sendableProbe,
                from: sender
            )
        }
    }
}

extension ForumBrowserModel: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.finishAgentNavigation(.failed("The page's web process quit."))
            self.handleWebContentTermination()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame {
            mainDocumentStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode
        }
        // WebKit's own default: show what it can show.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true,
           (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET",
           ScriptImporter.isUserScriptURL(url) {
            finishAgentNavigation(.intercepted(ScriptImporter.navigateInterceptMessage, url.absoluteString))
            decisionHandler(.cancel)
            Task { @MainActor in self.onUserScriptNavigation?(url) }
            return
        }

        let navigation = LinkPolicy.Navigation(
            url: url,
            targetIsMainFrame: navigationAction.targetFrame?.isMainFrame == true,
            isLinkActivated: navigationAction.navigationType == .linkActivated,
            httpMethod: navigationAction.request.httpMethod,
            pageHost: webView.url?.host
        )
        switch LinkPolicy.decide(navigation, settings: linkSettings) {
        case .allow:
            // The rule lists for the new main page (an allowed site or a
            // sign-in page has none) go in before its requests start.
            let scheme = url.scheme?.lowercased()
            if navigation.targetIsMainFrame, scheme == "http" || scheme == "https" {
                contentBlocker.prepare(forTopURL: url)
            }
            decisionHandler(.allow)
        case .reloadInPlace:
            // Loading the URL ourselves never triggers a Universal Link.
            decisionHandler(.cancel)
            Task { @MainActor in self.load(url) }
        case .loadWebURL(let web):
            decisionHandler(.cancel)
            Task { @MainActor in self.load(web) }
        case .promptOpenApp(let appURL):
            decisionHandler(.cancel)
            Task { @MainActor in
                self.appOpenPrompt = AppOpenPrompt(appName: LinkPolicy.appName(forScheme: appURL.scheme), url: appURL)
            }
        case .openExternally(let external):
            decisionHandler(.cancel)
            Task { @MainActor in UIApplication.shared.open(external) }
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    /// The prompt's Open.
    func confirmAppOpen() {
        guard let url = appOpenPrompt?.url else { return }
        appOpenPrompt = nil
        UIApplication.shared.open(url)
    }

    func dismissAppOpenPrompt() { appOpenPrompt = nil }

    /// "Open in app" for the current page: only when an app claims the link.
    func openCurrentPageInApp() {
        guard let url = currentURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                self?.appOpenPrompt = AppOpenPrompt(
                    appName: "",
                    url: nil,
                    message: String(localized: "No app can open this page.", comment: "Notice after Open in app finds no app")
                )
            }
        }
    }

    private func isCurrentNavigation(_ navigation: WKNavigation?) -> Bool {
        guard deferredLoad == nil else { return false }
        return activeNavigation == nil || activeNavigation == navigation
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard deferredLoad == nil else {
            updateNavigationState()
            return
        }
        if activeNavigation == nil || activeNavigationStarted || activeNavigation == navigation {
            activeNavigation = navigation
            activeNavigationStarted = true
        } else {
            updateNavigationState()
            return
        }
        expandChrome(deferIfTracking: true)
        if !holdsHomeOverLoad {
            let startedFromHome = loadStartedFromForumsHome
            hideForumsHome()
            loadStartedFromForumsHome = startedFromHome
        }
        updateNavigationState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard isCurrentNavigation(navigation) else {
            updateNavigationState()
            return
        }
        loadStartedFromForumsHome = false
        suppressLoadError = false
        appOpenPrompt = nil
        if isPageFormInputFocused {
            isPageFormInputFocused = false
            syncPageKeyboardFreeze()
        }
        // A new document: the facts of the last one no longer apply.
        lastFacts = nil
        // The committed page (after redirects) decides the lists.
        contentBlocker.prepare(forTopURL: webView.url)
        updateNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isCurrentNavigation(navigation) else {
            updateNavigationState()
            return
        }
        activeNavigation = nil
        activeNavigationStarted = false
        holdsHomeOverLoad = false
        loadStartedFromForumsHome = false
        suppressLoadError = false
        if showsCrashNotice { showsCrashNotice = false }
        let restoreOffset = pendingScrollRestore
        updateNavigationState()
        finishAgentNavigation(.finished)
        Task { @MainActor in
            guard self.deferredLoad == nil, self.activeNavigation == nil else { return }
            if let restoreOffset {
                await self.restoreScrollPosition(restoreOffset, in: webView)
            }
            // A full load starts a fresh bridge: mark the landing post again.
            await self.probeCurrentPage()
            self.applyPendingHighlight(afterLoad: true)
            self.onDidFinishPageLoad?()
            #if DEBUG
            // `-dc-scroll-page <points>`: scrolls each loaded page (screenshots).
            if let value = OnboardingDebug.value(after: "-dc-scroll-page"), let offset = Double(value) {
                try? await Task.sleep(for: .seconds(2))
                _ = try? await webView.evaluateJavaScript("window.scrollTo(0, \(offset))")
            }
            #endif
        }
    }

    private func restoreScrollPosition(_ point: CGPoint, in webView: WKWebView) async {
        let x = Double(max(0, point.x))
        let y = Double(max(0, point.y))
        _ = try? await webView.evaluateJavaScript("window.scrollTo(\(x), \(y));")
        let inset = webView.scrollView.adjustedContentInset
        let targetX = CGFloat(x) - inset.left
        let targetY = CGFloat(y) - inset.top
        if webView.scrollView.contentSize.height > 0 {
            let maxX = max(-inset.left, webView.scrollView.contentSize.width - webView.scrollView.bounds.width + inset.right)
            let maxY = max(-inset.top, webView.scrollView.contentSize.height - webView.scrollView.bounds.height + inset.bottom)
            webView.scrollView.setContentOffset(
                CGPoint(x: min(targetX, maxX), y: min(targetY, maxY)),
                animated: false
            )
        }
        scrollPosition = CGPoint(x: max(0, point.x), y: max(0, point.y))
        pendingScrollRestore = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard isCurrentNavigation(navigation) else {
            updateNavigationState()
            return
        }
        activeNavigation = nil
        activeNavigationStarted = false
        let heldHome = holdsHomeOverLoad
        let silent = suppressLoadError
        holdsHomeOverLoad = false
        suppressLoadError = false
        updateNavigationState()
        agentNavigationDidFail(error)
        guard !Self.isIgnorableNavigationError(error) else { return }
        #if DEBUG
        if ignoresNavigationFailures { return }
        #endif
        if !silent, !heldHome {
            onNavigationFailed?(error)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard isCurrentNavigation(navigation) else {
            updateNavigationState()
            return
        }
        activeNavigation = nil
        activeNavigationStarted = false
        let heldHome = holdsHomeOverLoad
        let silent = suppressLoadError
        holdsHomeOverLoad = false
        // The page did not change: back to its lists.
        contentBlocker.prepare(forTopURL: webView.url)
        agentNavigationDidFail(error)
        let ignored = Self.isIgnorableNavigationError(error)
        if !ignored {
            suppressLoadError = false
            var ignoresFailure = false
            #if DEBUG
            ignoresFailure = ignoresNavigationFailures
            #endif
            if !ignoresFailure, loadStartedFromForumsHome {
                loadStartedFromForumsHome = false
                isForumsHomeRequested = true
            }
            updateNavigationState()
            if !ignoresFailure, !silent, !heldHome {
                onNavigationFailed?(error)
            }
        } else {
            updateNavigationState()
        }
    }

    nonisolated private static func isIgnorableNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 || nsError.code == 204 {
            return true
        }
        return false
    }

    #if DEBUG
    private static let swizzleWebKitScreenTimeOnce: Void = {
        #if targetEnvironment(simulator)
        for path in [
            "/System/Library/Frameworks/ScreenTime.framework/ScreenTime",
            "/System/Library/PrivateFrameworks/ScreenTimeCore.framework/ScreenTimeCore"
        ] {
            _ = dlopen(path, RTLD_LAZY)
        }
        #endif
        let noop: @convention(block) (AnyObject) -> Void = { _ in }
        let imp = imp_implementationWithBlock(noop)
        for selectorName in [
            "_installScreenTimeWebpageControllerIfNeeded",
            "_updateScreenTimeBasedOnWindowVisibility"
        ] {
            if let method = class_getInstanceMethod(WKWebView.self, NSSelectorFromString(selectorName)) {
                method_setImplementation(method, imp)
            }
        }
        for className in [
            "WKScreenTimeConfigurationObserver",
            "STScreenTimeWebBrowserSettingsObserver"
        ] {
            if let cls = NSClassFromString(className),
               let method = class_getInstanceMethod(cls, NSSelectorFromString("startObserving")) {
                method_setImplementation(method, imp)
            }
        }
        let returnFalse: @convention(block) (AnyObject) -> Bool = { _ in false }
        let falseImp = imp_implementationWithBlock(returnFalse)
        for selectorName in [
            "showsSystemScreenTimeBlockingView",
            "_showsSystemScreenTimeBlockingView"
        ] {
            if let method = class_getInstanceMethod(WKWebViewConfiguration.self, NSSelectorFromString(selectorName)) {
                method_setImplementation(method, falseImp)
            }
        }
    }()

    /// In iOS 26.2 Simulator, `WKWebView` installs `STScreenTimeWebBrowserSettingsObserver`
    /// whenever it enters a `UIWindow`, which spawns a Swift cooperative-pool task that blocks
    /// synchronously on XPC to `ScreenTimeSettingsAgent` / `dasd`. On a 3-vCPU CI runner,
    /// three windowed `WKWebView`s exhaust all three cooperative threads and hang `Task.sleep`
    /// and actor hops for the remainder of the test suite.
    static func disableWebKitScreenTimeForTesting(in configuration: WKWebViewConfiguration) {
        _ = swizzleWebKitScreenTimeOnce
        if #available(iOS 26.0, *) {
            configuration.showsSystemScreenTimeBlockingView = false
        }
    }
    #endif
}

extension ForumBrowserModel: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if let url = navigationAction.request.url,
           (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET",
           ScriptImporter.isUserScriptURL(url) {
            Task { @MainActor in self.onUserScriptNavigation?(url) }
            return nil
        }
        if let onCreatePopupWebView {
            return onCreatePopupWebView(configuration, navigationAction)
        }
        guard let url = navigationAction.request.url else {
            return nil
        }
        Task { @MainActor in
            if Self.isBrowsableURL(url) {
                self.load(url)
            }
        }
        return nil
    }
}

struct ForumWebView: UIViewRepresentable {
    @ObservedObject var browser: ForumBrowserModel

    func makeUIView(context: Context) -> WKWebView {
        browser.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Hosts the active tab's `WKWebView` in front while keeping any background tab
/// whose Agent run is active attached to the `UIWindow` behind it (`isHidden = false`,
/// `alpha = 0`, `isUserInteractionEnabled = false`, `accessibilityElementsHidden = true`)
/// so WebKit does not throttle its timers or JavaScript (`design-browser-bar-tabs-models.md` §2).
@MainActor
final class BrowserTabsWebHostView: UIView {
    private weak var tabs: BrowserTabs?
    private weak var router: PresentationRouter?
    private weak var observedBrowser: ForumBrowserModel?
    private var showsCurrentWebViewOverride: Bool?
    private var cancellables: Set<AnyCancellable> = []
    private var currentBrowserHomeCancellable: AnyCancellable?
    private var routerCancellable: AnyCancellable?

    private func hidesCurrentWebViewAccessibility(isKeyboardVisible: Bool? = nil) -> Bool {
        guard let router, let browser = observedBrowser else { return false }
        let keyboardVisible = isKeyboardVisible ?? browser.isSystemKeyboardVisible
        return router.usesDrawer && router.drawerPhase == .shown && router.drawerDetent == .large && keyboardVisible
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
    }

    convenience init(tabs: BrowserTabs, frame: CGRect = .zero) {
        self.init(frame: frame)
        bind(tabs: tabs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func bind(tabs: BrowserTabs, router: PresentationRouter? = nil, showsCurrentWebView: Bool? = nil) {
        let tabsChanged = self.tabs !== tabs
        let routerChanged = self.router !== router
        self.tabs = tabs
        self.router = router
        self.showsCurrentWebViewOverride = showsCurrentWebView
        if routerChanged {
            routerCancellable = router.map { r in
                r.objectWillChange.sink { [weak self] _ in
                    Task { @MainActor in self?.syncCurrentWebViewAccessibility() }
                }
            }
        }
        if tabsChanged {
            cancellables.removeAll()
            currentBrowserHomeCancellable = nil
            observedBrowser = nil
            Publishers.CombineLatest4(
                tabs.$tabs,
                tabs.$currentTabID,
                tabs.$runningTabIDs,
                tabs.$agentAttachedTabIDs
            )
                .sink { [weak self] allTabs, currentID, runningIDs, attachedIDs in
                    self?.reconcileSubviews(
                        allTabs: allTabs,
                        currentTabID: currentID,
                        runningTabIDs: runningIDs.union(attachedIDs)
                    )
                }
                .store(in: &cancellables)
        } else {
            reconcileFromCurrentState()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        for subview in subviews where subview.frame != bounds {
            subview.frame = bounds
        }
    }

    private func reconcileFromCurrentState() {
        guard let tabs else { return }
        reconcileSubviews(
            allTabs: tabs.tabs,
            currentTabID: tabs.currentTabID,
            runningTabIDs: tabs.runningTabIDs.union(tabs.agentAttachedTabIDs)
        )
    }

    private func reconcileSubviews(
        allTabs: [BrowserTab],
        currentTabID: String,
        runningTabIDs: Set<String>
    ) {
        guard let currentTab = allTabs.first(where: { $0.id == currentTabID }) ?? allTabs.first else {
            currentBrowserHomeCancellable = nil
            observedBrowser = nil
            for subview in subviews { subview.removeFromSuperview() }
            return
        }

        if observedBrowser !== currentTab.browser {
            observedBrowser = currentTab.browser
            currentBrowserHomeCancellable = Publishers.CombineLatest3(
                currentTab.browser.$isForumsHomeRequested,
                currentTab.browser.$currentURL,
                currentTab.browser.$isSystemKeyboardVisible
            )
            .dropFirst()
            .sink { [weak self, weak currentTab] isHomeRequested, currentURL, isKeyboardVisible in
                guard let self, let currentTab, self.observedBrowser === currentTab.browser else { return }
                let isHome = isHomeRequested || currentURL == nil
                let visible = self.showsCurrentWebViewOverride ?? !isHome
                if let webView = currentTab.browser.existingWebView, webView.superview === self {
                    webView.isHidden = false
                    webView.alpha = visible ? 1 : 0
                    webView.isUserInteractionEnabled = visible
                    webView.accessibilityElementsHidden = !visible || self.hidesCurrentWebViewAccessibility(isKeyboardVisible: isKeyboardVisible)
                }
            }
        }

        let isCurrentVisible = showsCurrentWebViewOverride ?? !currentTab.showsHome
        let currentWebView = currentTab.browser.webView
        var backgroundRunningWebViews: [WKWebView] = []
        for tab in allTabs where tab.id != currentTab.id && runningTabIDs.contains(tab.id) {
            backgroundRunningWebViews.append(tab.browser.webView)
        }

        let keptIDs = Set(([currentWebView] + backgroundRunningWebViews).map(ObjectIdentifier.init))
        for subview in subviews where !keptIDs.contains(ObjectIdentifier(subview)) {
            if let webView = subview as? WKWebView {
                webView.alpha = 1
                webView.isUserInteractionEnabled = true
                webView.accessibilityElementsHidden = false
            }
            subview.removeFromSuperview()
        }

        for bgWebView in backgroundRunningWebViews {
            attachIfNeeded(bgWebView)
            bgWebView.isHidden = false
            bgWebView.alpha = 0
            bgWebView.isUserInteractionEnabled = false
            bgWebView.accessibilityElementsHidden = true
            sendSubviewToBack(bgWebView)
        }

        attachIfNeeded(currentWebView)
        currentWebView.isHidden = false
        currentWebView.alpha = isCurrentVisible ? 1 : 0
        currentWebView.isUserInteractionEnabled = isCurrentVisible
        currentWebView.accessibilityElementsHidden = !isCurrentVisible || hidesCurrentWebViewAccessibility()
        bringSubviewToFront(currentWebView)
    }

    private func syncCurrentWebViewAccessibility() {
        guard let tabs,
              let currentTab = tabs.tabs.first(where: { $0.id == tabs.currentTabID }) ?? tabs.tabs.first,
              let webView = currentTab.browser.existingWebView,
              webView.superview === self else { return }
        let visible = showsCurrentWebViewOverride ?? !currentTab.showsHome
        webView.accessibilityElementsHidden = !visible || hidesCurrentWebViewAccessibility()
    }

    private func attachIfNeeded(_ webView: WKWebView) {
        if webView.superview !== self {
            webView.removeFromSuperview()
            if bounds.width > 0, bounds.height > 0 {
                webView.frame = bounds
            }
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(webView)
        } else if bounds.width > 0, bounds.height > 0, webView.frame != bounds {
            webView.frame = bounds
        }
    }
}

struct BrowserTabsWebHost: UIViewRepresentable {
    @ObservedObject var tabs: BrowserTabs
    var router: PresentationRouter? = nil
    var showsCurrentWebView: Bool? = nil

    func makeUIView(context: Context) -> BrowserTabsWebHostView {
        let view = BrowserTabsWebHostView()
        view.bind(tabs: tabs, router: router, showsCurrentWebView: showsCurrentWebView)
        return view
    }

    func updateUIView(_ uiView: BrowserTabsWebHostView, context: Context) {
        uiView.bind(tabs: tabs, router: router, showsCurrentWebView: showsCurrentWebView)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Awaitable loads for the agent (design-m3.md "navigate and reload_page")

/// How an agent-awaited load ended.
enum AgentNavigationEnding: Equatable {
    case finished
    case failed(String)
    case intercepted(String, String)
    case timedOut
    case cancelled
}

/// One awaited load: resumed exactly once, by the navigation delegate, a
/// newer agent load, the timeout or cancellation.
@MainActor
final class AgentNavigationWaiter {
    private var continuation: CheckedContinuation<AgentNavigationEnding, Never>?
    private var pending: AgentNavigationEnding?
    var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<AgentNavigationEnding, Never>) {
        if let pending {
            continuation.resume(returning: pending)
        } else {
            self.continuation = continuation
        }
    }

    func finish(_ ending: AgentNavigationEnding) {
        guard pending == nil else { return }
        pending = ending
        timeoutTask?.cancel()
        timeoutTask = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: ending)
        }
    }
}

extension ForumBrowserModel: AgentPageNavigating {
    func agentLoad(_ url: URL, wait: Bool, timeout: TimeInterval) async throws -> AgentNavigationOutcome {
        let isBlank = url.absoluteString == "about:blank"
        guard isBlank || Self.isBrowsableURL(url) else {
            return AgentNavigationOutcome(
                url: webView.url?.absoluteString ?? "",
                title: webView.title ?? "",
                status: nil,
                loadMs: 0,
                failure: "Only http, https and about:blank addresses can be opened."
            )
        }
        if ScriptImporter.isUserScriptURL(url) {
            finishAgentNavigation(.cancelled)
            onUserScriptNavigation?(url)
            return AgentNavigationOutcome(
                url: url.absoluteString,
                title: webView.title ?? "",
                status: nil,
                loadMs: 0,
                interceptedMessage: ScriptImporter.navigateInterceptMessage
            )
        }
        let start: () -> Bool = { [weak self] in
            guard let self else { return false }
            // The tool reports a failed load itself: no alert on top of it.
            if isBlank {
                self.deferredLoad = nil
                self.hideForumsHome()
                self.suppressLoadError = true
                self.activeNavigation = self.webView.load(URLRequest(url: url))
                self.activeNavigationStarted = false
            } else {
                self.load(url, silentOnFailure: true)
            }
            return true
        }
        guard wait else {
            finishAgentNavigation(.cancelled)
            mainDocumentStatus = nil
            _ = start()
            return AgentNavigationOutcome(url: url.absoluteString, title: "", status: nil, loadMs: 0)
        }
        return try await awaitAgentNavigation(timeout: timeout, start: start)
    }

    func agentReload(timeout: TimeInterval) async throws -> AgentNavigationOutcome {
        try await awaitAgentNavigation(timeout: timeout) { [weak self] in
            guard let self else { return false }
            if self.webView.url != nil {
                self.reload()
                self.suppressLoadError = true
                return true
            }
            if let url = self.currentURL, Self.isBrowsableURL(url) {
                self.load(url, silentOnFailure: true)
                return true
            }
            return false
        }
    }

    private func awaitAgentNavigation(
        timeout: TimeInterval,
        start: @escaping () -> Bool
    ) async throws -> AgentNavigationOutcome {
        try Task.checkCancellation()
        // A newer agent load supersedes an older one still waiting.
        finishAgentNavigation(.cancelled)
        let waiter = AgentNavigationWaiter()
        agentNavigationWaiter = waiter
        mainDocumentStatus = nil
        let started = ContinuousClock.now
        let effectiveTimeout = max(0.1, timeout)

        let ending = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AgentNavigationEnding, Never>) in
                waiter.install(continuation)
                waiter.timeoutTask = Task { @MainActor [weak waiter] in
                    try? await Task.sleep(for: .milliseconds(Int(effectiveTimeout * 1_000)))
                    guard !Task.isCancelled else { return }
                    waiter?.finish(.timedOut)
                }
                if !start() {
                    waiter.finish(.failed("There is no page to reload."))
                }
            }
        } onCancel: {
            Task { @MainActor in waiter.finish(.cancelled) }
        }
        if agentNavigationWaiter === waiter { agentNavigationWaiter = nil }
        if ending == .cancelled, Task.isCancelled { throw CancellationError() }

        let elapsed = started.duration(to: .now)
        let loadMs = Int(elapsed.components.seconds * 1_000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        // `allocatedWebView`: an unload ends the wait, and `webView` would
        // build a blank web view for the unloaded tab.
        var outcome = AgentNavigationOutcome(
            url: allocatedWebView?.url?.absoluteString ?? currentURL?.absoluteString ?? "",
            title: allocatedWebView?.title ?? "",
            status: mainDocumentStatus,
            loadMs: loadMs
        )
        switch ending {
        case .finished:
            break
        case .intercepted(let message, let interceptedURL):
            outcome.url = interceptedURL
            outcome.interceptedMessage = message
        case .timedOut:
            outcome.timedOut = true
        case .failed(let message):
            outcome.failure = message
        case .cancelled:
            outcome.failure = "Another page load took over."
        }
        return outcome
    }

    fileprivate func finishAgentNavigation(_ ending: AgentNavigationEnding) {
        guard let waiter = agentNavigationWaiter else { return }
        agentNavigationWaiter = nil
        waiter.finish(ending)
    }

    /// A failed load ends the agent's wait, unless it was only cancelled by a
    /// newer navigation still under way (that one's end resolves it).
    fileprivate func agentNavigationDidFail(_ error: Error) {
        guard agentNavigationWaiter != nil else { return }
        if Self.isIgnorableNavigationError(error), webView.isLoading || deferredLoad != nil {
            return
        }
        finishAgentNavigation(.failed(error.localizedDescription))
    }
}
