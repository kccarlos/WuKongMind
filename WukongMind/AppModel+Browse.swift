import Foundation
import SwiftUI

// MARK: - Browsing and Home (UI engineer A)
//
// - `goHome()`                     current forum's /latest, else Home
// - `showForumsHome()`             Home over the current page (HomeView.swift)
// - `showsTodayPage`               the Today page pushed over Home
// - `todayModuleState`             the Today module's state (HomeState.swift)
// - `applyLaunchRuleIfNeeded()`    the first activation: Home or the last forum
// - `askForum(_:)`                 opens the forum and the Agent, "Search this forum…" in the box
// - `isCurrent(_:)`                forum of the current page (or the current forum)

extension AppModel {
    /// Home button: the current forum's /latest; with no forum, the Forums home.
    func goHome() {
        if !loadHome() {
            browser.showForumsHome()
        }
    }

    /// Loads the current forum's home through its adapter; false with none.
    @discardableResult
    func loadHome(silentOnFailure: Bool = false) -> Bool {
        browser.loadHome(
            adapter: browser.homeSiteURL.flatMap { adapter(for: $0) },
            silentOnFailure: silentOnFailure
        )
    }

    /// The current forum's sign-in page; nil with no forum or a site that has none.
    var loginURL: URL? {
        guard let siteURL = browser.homeSiteURL else { return nil }
        return adapter(for: siteURL)?.capabilities.loginURL?(siteURL)
    }

    /// Loads the current forum's sign-in page; false when there is none.
    @discardableResult
    func loadLogin() -> Bool {
        guard let url = loginURL else { return false }
        browser.load(url)
        return true
    }

    /// The signed-in user's account page on the current forum; nil with no forum or a site that has none.
    var accountURL: URL? {
        guard let siteURL = browser.homeSiteURL else { return nil }
        return adapter(for: siteURL)?.capabilities.accountURL?(siteURL, browser.signedInUsername)
    }

    /// Loads the signed-in user's account page on the current forum; false when there is none.
    @discardableResult
    func loadAccount() -> Bool {
        guard let url = accountURL else { return false }
        browser.load(url)
        return true
    }

    /// The current forum's own search page for typed words; nil with no forum or
    /// a site without one.
    func searchPageURL(query: String) -> URL? {
        guard let siteURL = browser.homeSiteURL else { return nil }
        return adapter(for: siteURL)?.capabilities.searchPageURL?(siteURL, query)
    }

    /// Web search URL using the search engine configured in Settings › Browser.
    func webSearchURL(query: String) -> URL? {
        settings.searchEngine.searchURL(for: query)
    }

    func showForumsHome() {
        browser.showForumsHome()
    }

    // MARK: Launch rule (§7.2)

    /// A link, notification, Siri, Spotlight or the share extension opened
    /// something: before the rule has run, the page is left to it.
    func noteExternalEntry() {
        if launchPhase == .waiting { launchPhase = .openedExternally }
    }

    /// Once, on the first activation (after the share inbox has started):
    /// Home or the last forum, which the browser has been loading since
    /// launch. A request from outside always wins.
    func applyLaunchRuleIfNeeded(now: Date = Date()) {
        guard launchPhase != .settled, settings.hasCompletedOnboarding else { return }
        let openedExternally = launchPhase == .openedExternally
        launchPhase = .settled
        #if DEBUG
        // UI tests and samples land where their arguments say, unless they
        // ask for the rule (`-dc-launch automatic|home|lastForum`).
        let arguments = ProcessInfo.processInfo.arguments
        let override = AssistantDebug.value("-dc-launch").flatMap(LaunchDestination.init(rawValue:))
        if override == nil, arguments.contains(where: { $0.hasPrefix("-dc-") || $0.hasPrefix("-ui-test-") }) { return }
        let setting = override ?? settings.launchDestination
        #else
        let setting = settings.launchDestination
        #endif
        let defaults = UserDefaults.standard
        let decision = LaunchRule.decide(
            setting: setting,
            openedExternally: openedExternally,
            lastHomeAutoShownDay: defaults.string(forKey: LaunchRule.lastHomeAutoShownDayKey),
            now: now
        )
        switch decision {
        case .external, .lastForum:
            break
        case .home(let marksDay):
            if marksDay { defaults.set(LaunchRule.dayKey(for: now), forKey: LaunchRule.lastHomeAutoShownDayKey) }
            // Over the restored forum's first load, which would otherwise
            // dismiss it as it starts.
            browser.showForumsHome(overPendingLoad: true)
        }
    }

    /// "Ask the forum": opens the forum and the Agent, with "Search this
    /// forum…" started in the composer; Send goes to the Agent.
    func askForum(_ forum: Forum) {
        if !isCurrent(forum) || browser.showsForumsHome {
            openForum(forum)
        }
        assistantMode = .browserAgent
        panelRoute = .topic
        drafts.goal = PageSuggestion.searchForum.composerText
        requestAssistant()
        if !isProviderReady(for: .browserAgent) { needsProviderSetup = .browserAgent }
    }

    /// The forum of the current page (or, off-forum, the current forum).
    func isCurrent(_ forum: Forum) -> Bool {
        (pageContext.siteURL ?? currentForum?.siteURL) == forum.siteURL
    }

    /// The forum the browser bar shows: the page's forum, else the current one.
    var barForum: Forum? {
        if let siteURL = pageContext.siteURL, let forum = forum(for: siteURL) {
            return forum
        }
        if pageContext.isForum, let siteURL = pageContext.siteURL, let kind = pageContext.site {
            return Forum(siteURL: siteURL, kind: kind, name: pageContext.forumName, iconURL: pageContext.iconURL)
        }
        return currentForum
    }
}

#if DEBUG
extension AppModel {
    /// Screenshot / QA states:
    /// - `-dc-seed-forums`   pins three forums and adds two recents (icons fetched
    ///                       live unless `-dc-no-forum-icons`)
    /// - `-dc-no-forum-icons` letter monograms instead of forum icons (ForumIconPolicy)
    /// - `-dc-forums-home`   starts on Home even when a forum was restored
    /// - `-dc-launch <destination>` applies the launch rule (automatic | home |
    ///                       lastForum) although this is a `-dc-` launch
    /// - `-dc-open <url>`    opens a page on launch
    /// - `-dc-fixture-model <url>` points the Ollama provider at a local
    ///                       fixture server (`/api/chat`) and selects it, so a UI
    ///                       test runs real jobs without a network model
    /// - `-dc-show-switcher` opens the forum switcher after launch (ContentView)
    /// - `-dc-browse-post`, `-dc-browse-find`, `-dc-browse-debug` post-level
    ///                       browsing (AppModel+Navigation.swift)
    func applyDebugLaunchArguments(arguments: [String] = ProcessInfo.processInfo.arguments) {
        if Self.loadsOnlySamplePage(arguments: arguments) {
            suppressesPersistence = true
        }
        applyBrowseDebugArguments()
        if arguments.contains("-dc-seed-forums"), forums.isEmpty {
            // The sample's real public forums (SampleContent.swift) and
            // Hacker News, which the app reads as a forum too.
            let text = SampleContent.current
            let kind = SiteKind.discourse
            let pinned = [
                Forum(siteURL: text.meta.siteURL, kind: kind, name: text.meta.name),
                Forum(siteURL: text.openAI.siteURL, kind: kind, name: text.openAI.name),
                Forum(siteURL: HackerNewsRecognizer.siteURL, kind: .hackerNews, name: "Hacker News")
            ]
            pinned.forEach(pin)
            if ForumIconPolicy.loadsRemoteIcons {
                for forum in forums { refreshForumInfo(siteURL: forum.siteURL) }
            }
        } else if arguments.contains("-dc-seed-forums"), suppressesPersistence,
                  !forums.contains(where: { $0.siteURL == HackerNewsRecognizer.siteURL }) {
            pin(Forum(siteURL: HackerNewsRecognizer.siteURL, kind: .hackerNews, name: "Hacker News"))
        }
        if let index = arguments.firstIndex(of: "-dc-fixture-model"), index + 1 < arguments.count {
            var configuration = settings.configuration(for: .ollama)
            configuration.baseURL = arguments[index + 1]
            configuration.model = "fixture-model"
            configuration.apiKey = ""
            let selection = ModelSelection(provider: .ollama, model: configuration.model)
            var inMemory = settings
            inMemory.setConfiguration(configuration, for: .ollama)
            inMemory.setModel(selection, for: .assistant)
            inMemory.setModel(selection, for: .browserAgent)
            settings = inMemory
        } else if arguments.contains("-dc-no-provider"), !arguments.contains("-dc-sample") {
            let unconfigured = ModelSelection(provider: .anthropic, model: "claude-haiku-5-5")
            var inMemory = settings
            inMemory.setModel(unconfigured, for: .assistant)
            inMemory.setModel(unconfigured, for: .browserAgent)
            for provider in AIProvider.allCases where provider.requiresAPIKey {
                var configuration = inMemory.configuration(for: provider)
                configuration.apiKey = ""
                inMemory.setConfiguration(configuration, for: provider)
            }
            settings = inMemory
        }
        if let index = arguments.firstIndex(of: "-dc-open"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            browser.load(url)
        } else if arguments.contains("-dc-forums-home") {
            // Kept over the restored forum's first load.
            browser.showForumsHome(overPendingLoad: true)
        }
        if arguments.contains("-dc-store-tabs") {
            settings.hasCompletedOnboarding = true
            let content = StoreScreenshotContent.current
            let firstTab = tabs.currentTab
            firstTab.browser.onPageContextChanged = { _ in }
            firstTab.browser.ignoresNavigationFailures = true
            firstTab.browser.hideForumsHome()
            firstTab.browser.loadSamplePage(content.articleHTML, at: content.articleURL)
            firstTab.browser.setPageContext(PageContext(url: content.articleURL, state: .notForum))
            var seededTabs: [BrowserTab] = []
            for page in content.extraTabs {
                if let tab = tabs.openTab(inFront: false) {
                    tab.browser.onPageContextChanged = { _ in }
                    tab.browser.ignoresNavigationFailures = true
                    tab.browser.hideForumsHome()
                    tab.browser.loadSamplePage(page.html, at: page.url)
                    tab.browser.setPageContext(PageContext(url: page.url, state: .notForum))
                    seededTabs.append(tab)
                }
            }
            // Cycle each extra tab briefly on screen so WKWebView paints and captures
            // a real thumbnail snapshot before the overview opens.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self else { return }
                for tab in seededTabs {
                    _ = self.tabs.switchToTab(id: tab.id)
                    try? await Task.sleep(for: .milliseconds(450))
                    _ = await tab.captureSnapshotIfAvailable()
                }
                _ = self.tabs.switchToTab(id: firstTab.id)
                try? await Task.sleep(for: .milliseconds(350))
                _ = await firstTab.captureSnapshotIfAvailable()
            }
        }
        if let index = arguments.firstIndex(of: "-dc-seed-open-tabs"),
           index + 1 < arguments.count,
           let targetCount = Int(arguments[index + 1]),
           targetCount > tabs.tabs.count {
            settings.hasCompletedOnboarding = true
            let capped = min(BrowserTabs.maxTabs, targetCount)
            while tabs.tabs.count < capped {
                if tabs.openTab(inFront: false) == nil { break }
            }
        }
    }

    private static let browserAgentFixtureURL = URL(string: "https://news.example.org/story/user-agency")!

    private static let browserAgentFixtureHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Why Web Browsers Need User Agency</title>
      <style>
        body {
          margin: 0;
          font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          background: #ffffff;
          color: #1e293b;
          line-height: 1.55;
        }
        header {
          padding: 16px 20px;
          border-bottom: 1px solid #e2e8f0;
          font-weight: 700;
          color: #0f172a;
        }
        .layout {
          display: flex;
          gap: 20px;
          padding: 20px;
          max-width: 960px;
          margin: 0 auto;
        }
        article {
          flex: 2;
        }
        aside.sidebar {
          flex: 1;
          padding: 16px;
          border-radius: 12px;
          background: #f1f5f9;
          border: 1px solid #cbd5e1;
        }
        h1 { margin-top: 0; font-size: 1.5rem; }
      </style>
    </head>
    <body>
      <header>Example Dispatch · Technology</header>
      <div class="layout">
        <article id="main-article">
          <h1>Why Web Browsers Need User Agency</h1>
          <p>Modern web pages ship megabytes of layout chrome, sticky promos, and rigid themes. A user agent should work for its reader, adapting any page on demand.</p>
          <p>With structured DOM inspection, scoped CSS injection, and isolated JavaScript execution, a browser agent can reshape a page in seconds while keeping untrusted content contained.</p>
        </article>
        <aside class="sidebar" id="newsletter-aside">
          <h3>Sponsored Sidebar</h3>
          <p>Subscribe to our daily growth popups and partner notifications.</p>
        </aside>
      </div>
    </body>
    </html>
    """

    private func loadBrowserAgentFixturePage() {
        let url = Self.browserAgentFixtureURL
        browser.onPageContextChanged = { _ in }
        browser.ignoresNavigationFailures = true
        browser.hideForumsHome()
        browser.loadSamplePage(Self.browserAgentFixtureHTML, at: url)
        browser.setPageContext(PageContext(url: url, state: .notForum))
    }

    func applyBrowserAgentDebugArguments() {
        if AssistantDebug.has("-dc-developer-mode") {
            settings.agentDeveloperMode = true
        }
        let demoMode = AssistantDebug.value("-dc-browser-agent-demo")
        let livePrompt = AssistantDebug.value("-dc-browser-agent-live-prompt")
        let hasLiveKey = AssistantDebug.has("-dc-browser-agent-live-key")
        let hasCustomOpenURL = AssistantDebug.value("-dc-open") != nil
        let wantsBrowserAgentDebug = AssistantDebug.has("-dc-browser-agent-fixture-page")
            || demoMode != nil
            || livePrompt != nil
            || hasLiveKey

        guard wantsBrowserAgentDebug else { return }

        settings.hasCompletedOnboarding = true
        needsProviderSetup = nil
        let usesCustomOpenPage = hasCustomOpenURL
            && !AssistantDebug.has("-dc-browser-agent-fixture-page")
            && (livePrompt != nil || hasLiveKey || demoMode != nil)
        let isStoreDemo = demoMode == "store-dark"
            || demoMode == "store-script"
            || demoMode == "store-summarize"
            || demoMode == "store-empty"
        if usesCustomOpenPage {
            browser.ignoresNavigationFailures = true
            browser.hideForumsHome()
        } else if isStoreDemo {
            let content = StoreScreenshotContent.current
            browser.onPageContextChanged = { _ in }
            browser.ignoresNavigationFailures = true
            browser.hideForumsHome()
            browser.loadSamplePage(content.articleHTML, at: content.articleURL)
            browser.setPageContext(PageContext(url: content.articleURL, state: .notForum))
        } else {
            loadBrowserAgentFixturePage()
        }
        assistantMode = .browserAgent
        panelRoute = .topic
        if AssistantDebug.has("-dc-site-inspector-seed"), let host = SiteToolState.normalizedHost(from: Self.browserAgentFixtureURL) {
            try? siteToolStateStore.save(.inspectorSeed(host: host))
        }

        if let demoMode {
            var config = settings.configuration(for: .anthropic)
            config.apiKey = "demo-key"
            config.model = "claude-haiku-5-5"
            settings.setConfiguration(config, for: .anthropic)
            settings.setModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .assistant)
            // Demo mode uses the local offline `BrowserAgentDemoClient` (never contacts
            // Anthropic), so pre-allow consent unless a test explicitly checks the gate.
            if !AssistantDebug.has("-dc-ask-ai-consent") {
                settings.aiConsent[AIProvider.anthropic.rawValue] = .allowed(Date())
            }
            if demoMode == "no-model" {
                settings.setModel(ModelSelection(provider: .anthropic, model: ""), for: .browserAgent)
            } else if demoMode == "run-limit" {
                settings.setModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .browserAgent)
                let customOpenURL = usesCustomOpenPage
                    ? AssistantDebug.value("-dc-open").flatMap(URL.init(string:))
                    : nil
                let tab1 = tabs.currentTab
                if let customOpenURL {
                    tab1.browser.ignoresNavigationFailures = true
                    tab1.browser.load(customOpenURL)
                } else {
                    tab1.browser.loadSamplePage(Self.browserAgentFixtureHTML, at: Self.browserAgentFixtureURL)
                }
                tab1.agentSession.configureDebugModelClient(BrowserAgentDemoClient(mode: .running))
                tab1.agentSession.send("Summarize this page")
                for index in 2...3 {
                    if let bgTab = tabs.openTab(inFront: false) {
                        if let customOpenURL {
                            bgTab.browser.ignoresNavigationFailures = true
                            bgTab.browser.load(customOpenURL)
                        } else {
                            bgTab.browser.loadSamplePage(Self.browserAgentFixtureHTML, at: Self.browserAgentFixtureURL)
                        }
                        bgTab.agentSession.configureDebugModelClient(BrowserAgentDemoClient(mode: .running))
                        bgTab.agentSession.send("Inspect tab \(index)")
                    }
                }
                if let fourthTab = tabs.openTab(inFront: true) {
                    fourthTab.agentSession.configureDebugModelClient(BrowserAgentDemoClient(mode: .recorded))
                    if let customOpenURL {
                        fourthTab.browser.ignoresNavigationFailures = true
                        fourthTab.browser.load(customOpenURL)
                    } else {
                        loadBrowserAgentFixturePage()
                    }
                }
            } else {
                settings.setModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .browserAgent)
                if demoMode == "step-limit" {
                    settings.browserAgentMaxSteps = 2
                }
                let clientMode = BrowserAgentDemoClient.Mode(rawValue: demoMode) ?? .recorded
                browserAgent.configureDebugModelClient(BrowserAgentDemoClient(mode: clientMode))
            }
            guard demoMode != "spa-op-only" else { return }
            Task { @MainActor [weak self] in
                for delay in [500, 1200] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard let self else { return }
                    self.needsProviderSetup = nil
                    self.requestAssistant()
                    self.showAIView()
                    if let value = AssistantDebug.value("-dc-drawer-detent"), let detent = DrawerDetent(rawValue: value) {
                        self.router.drawerDetent = detent
                    }
                }
                guard let self, demoMode != "no-model", demoMode != "empty", demoMode != "store-empty", demoMode != "run-limit" else { return }
                let demoPrompt: String
                if demoMode == "store-dark" {
                    demoPrompt = StoreScreenshotContent.current.darkPrompt
                } else if demoMode == "store-script" {
                    demoPrompt = StoreScreenshotContent.current.saveScriptPrompt
                } else if demoMode == "store-summarize" {
                    demoPrompt = StoreScreenshotContent.current.summarizePrompt
                } else if demoMode == "saved-script" {
                    demoPrompt = "Keep only the original poster's posts and hide the sidebar on every visit"
                } else if demoMode == "tabs-open" {
                    demoPrompt = "Find the companion schedule and keep it open in a new tab"
                } else {
                    demoPrompt = "Make this page dark and hide the sidebar"
                }
                if demoMode == "voice" {
                    // Voice turns around a hand-off run (the voice bubble's screenshots).
                    self.browserAgent.appendVoiceTurn(.voiceUser, text: demoPrompt)
                    self.browserAgent.appendVoiceTurn(.voiceReply, text: "I'll have the Agent do that.")
                    try? await Task.sleep(for: .milliseconds(50))
                    _ = self.agentHandOff.start(demoPrompt)
                    _ = await self.agentHandOff.outcome()
                    self.browserAgent.appendVoiceTurn(.voiceReply, text: "Done. The page is dark and the sidebar is gone; the details are in the panel.")
                    self.browserAgent.appendVoiceTurn(.voiceUser, text: "Read me the first heading")
                    return
                }
                self.browserAgent.send(demoPrompt)
            }
            return
        }

        if livePrompt != nil || hasLiveKey {
            let env = ProcessInfo.processInfo.environment
            let apiKey = (env["ANTHROPIC_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let modelID = AssistantDebug.value("-dc-browser-agent-live-model") ?? "claude-haiku-5-5"
            settings.browserAgentMaxSteps = min(settings.browserAgentMaxSteps, 10)
            var config = settings.configuration(for: .anthropic)
            config.apiKey = apiKey
            config.model = modelID
            settings.setConfiguration(config, for: .anthropic)
            settings.setModel(ModelSelection(provider: .anthropic, model: modelID), for: .assistant)
            settings.setModel(ModelSelection(provider: .anthropic, model: modelID), for: .browserAgent)

            let vertexKey = (env["VERTEX_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let vertexBase = (env["VERTEX_BASE_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let vertexProject = (env["VERTEX_PROJECT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let geminiKey = (env["GEMINI_LIVE_KEY"] ?? env["GEMINI_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !vertexKey.isEmpty {
                var vertexCfg = settings.configuration(for: .vertexAI)
                vertexCfg.apiKey = vertexKey
                vertexCfg.baseURL = vertexBase.isEmpty ? AIProvider.vertexAI.defaultBaseURL : vertexBase
                settings.setConfiguration(vertexCfg, for: .vertexAI)
                settings.voice.vertexProject = vertexProject
            }
            if !geminiKey.isEmpty {
                var geminiCfg = settings.configuration(for: VoiceProvider.aiStudio.keyProvider)
                geminiCfg.apiKey = geminiKey
                settings.setConfiguration(geminiCfg, for: VoiceProvider.aiStudio.keyProvider)
            }
            if !vertexKey.isEmpty || !geminiKey.isEmpty {
                settings.voiceEnabled = true
                settings.podcast.engine = .onDevice
                settings.voice.sessionLimitMinutes = 0
                settings.voice.dailyLimitMinutes = 0
                settings.voice.idleTimeout = 300
                if let explicit = AssistantDebug.value("-dc-voice-provider"),
                   let forced = VoiceProvider(rawValue: explicit.lowercased()) {
                    settings.voice.provider = forced
                } else if !vertexKey.isEmpty {
                    settings.voice.provider = .vertex
                } else if !geminiKey.isEmpty {
                    settings.voice.provider = .aiStudio
                }
            }
        }

        if let livePrompt {
            let resultFile = AssistantDebug.value("-dc-browser-agent-result-file")

            Task { @MainActor [weak self] in
                for delay in [500, 1200] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard let self else { return }
                    self.needsProviderSetup = nil
                    self.requestAssistant()
                    self.showAIView()
                    if let value = AssistantDebug.value("-dc-drawer-detent"), let detent = DrawerDetent(rawValue: value) {
                        self.router.drawerDetent = detent
                    }
                }
                guard let self else { return }
                await self.browser.waitUntilSettled(timeout: .seconds(10))
                await self.browserAgent.sendAndWait(livePrompt)
                if let resultFile {
                    await self.writeBrowserAgentLiveResult(to: resultFile)
                }
            }
        }
    }

    private func writeBrowserAgentLiveResult(to path: String) async {
        let sidebarDisplay = (try? await browser.agentBridge.runJS(
            code: "const el = document.querySelector('.sidebar'); return el ? getComputedStyle(el).display : 'removed';",
            environment: .isolated
        ).valueJSON) ?? "unknown"
        let bodyBg = (try? await browser.agentBridge.runJS(
            code: "return getComputedStyle(document.body).backgroundColor;",
            environment: .isolated
        ).valueJSON) ?? "unknown"

        var afterReloadSidebar = ""
        var afterReloadBodyBg = ""
        if AssistantDebug.has("-dc-browser-agent-live-reload") {
            loadBrowserAgentFixturePage()
            await browser.waitUntilSettled(timeout: .seconds(10))
            afterReloadSidebar = (try? await browser.agentBridge.runJS(
                code: "const el = document.querySelector('.sidebar'); return el ? getComputedStyle(el).display : 'removed';",
                environment: .isolated
            ).valueJSON) ?? "unknown"
            afterReloadBodyBg = (try? await browser.agentBridge.runJS(
                code: "return getComputedStyle(document.body).backgroundColor;",
                environment: .isolated
            ).valueJSON) ?? "unknown"
        }

        var payload: [String: Any] = [
            "state": String(describing: browserAgent.runState),
            "stepCount": browserAgent.toolCalls.count,
            "tools": browserAgent.toolCalls.map { [
                "name": $0.toolName,
                "argumentSummary": $0.argumentSummary,
                "resultSummary": $0.resultSummary,
                "isError": $0.isError
            ] },
            "assistantReply": browserAgent.runs.last?.assistantText ?? "",
            "totalTokens": browserAgent.tokenUsage.totalTokens,
            "sidebarDisplay": sidebarDisplay,
            "bodyBackground": bodyBg,
            "savedScriptCount": scriptStore.scripts.count,
            "savedScripts": scriptStore.scripts.map { [
                "id": $0.id,
                "name": $0.name,
                "matchRules": $0.matchRules,
                "version": $0.version,
                "enabled": $0.isEnabled
            ] }
        ]
        if !afterReloadSidebar.isEmpty || !afterReloadBodyBg.isEmpty {
            payload["afterReloadSidebarDisplay"] = afterReloadSidebar
            payload["afterReloadBodyBackground"] = afterReloadBodyBg
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func seedScriptsSampleIfNeeded() {
        guard AssistantDebug.has("-dc-scripts-sample") else { return }
        let variant = AssistantDebug.value("-dc-scripts-sample") ?? "manager"
        settings.hasCompletedOnboarding = true
        needsProviderSetup = nil

        if variant == "empty" {
            for existing in scriptStore.scripts {
                _ = scriptStore.deleteIfPresent(id: existing.id)
            }
            if AssistantDebug.has("-dc-scripts-sheet") {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    self?.requestedSettingsPage = .scripts
                }
            }
            return
        }

        let now = Date()
        let v1Date = now.addingTimeInterval(-3 * 86_400)
        let v2Date = now.addingTimeInterval(-3600 * 5)
        let v3Date = now.addingTimeInterval(-900)

        for existing in scriptStore.scripts {
            _ = scriptStore.deleteIfPresent(id: existing.id)
        }

        if let created = try? scriptStore.create(
            id: "op-only",
            name: "Original poster only",
            matchRules: ["*://news.example.org/*", "*://*.example.org/*"],
            js: """
            document.querySelectorAll('.reply').forEach(el => {
              el.hidden = true;
            });
            """,
            css: "",
            injectionTime: .documentEnd,
            environment: .page,
            isEnabled: true,
            source: .agent(userPrompt: "Keep only the original poster's posts on news.example.org"),
            now: v1Date
        ) {
            _ = try? scriptStore.update(
                id: created.id,
                patch: ScriptUpdatePatch(
                    js: """
                    document.querySelectorAll('.reply:not([data-op])').forEach(el => {
                      el.hidden = true;
                    });
                    """,
                    css: ".sidebar { display: none !important; }"
                ),
                origin: .changedByAgent(userPrompt: "Also hide the sidebar aside and keep [data-op] replies"),
                now: v2Date
            )
            _ = try? scriptStore.update(
                id: created.id,
                patch: ScriptUpdatePatch(
                    css: """
                    .sidebar, #newsletter-aside { display: none !important; }
                    article { max-width: 68ch; margin-inline: auto; }
                    """
                ),
                origin: .editedByUser,
                now: v3Date
            )
            scriptStore.noteExecuted(scriptID: created.id, at: now.addingTimeInterval(-120))
        }

        _ = try? scriptStore.create(
            id: "dark-thread",
            name: "Dark palette & wide thread",
            matchRules: ["*://news.example.org/*"],
            js: variant == "page-error"
                ? "document.querySelector('.missing-header').classList.add('dark');"
                : """
                const header = document.querySelector('header.site-header');
                if (header) header.dataset.theme = 'dark';
                """,
            css: """
            html, body { background: #0f172a !important; color: #e2e8f0 !important; }
            """,
            injectionTime: .documentStart,
            environment: .isolated,
            isEnabled: true,
            source: .agent(userPrompt: "Make news.example.org articles dark and readable at night"),
            now: now.addingTimeInterval(-7200)
        )
        scriptStore.noteExecuted(scriptID: "dark-thread", at: now.addingTimeInterval(-95))

        // A learned reader (Learn on ask 8): This page reads "Reads this site" under it.
        if AssistantDebug.has("-dc-reads-site") {
            _ = try? scriptStore.create(
                id: "thread-reader",
                name: "Thread reader",
                matchRules: ["*://news.example.org/*"],
                js: "1;",
                injectionTime: .documentEnd,
                environment: .isolated,
                isEnabled: true,
                source: .agent(userPrompt: "Learn how to read this forum"),
                provides: ["read_topic"],
                now: now.addingTimeInterval(-600)
            )
        }

        if variant == "page-error" {
            scriptStore.recordError(
                scriptID: "dark-thread",
                message: "TypeError: Cannot read properties of null (reading 'classList')",
                line: 2,
                url: Self.browserAgentFixtureURL.absoluteString,
                occurredAt: now.addingTimeInterval(-40)
            )
        } else if variant == "auto-disabled" {
            for load in ["load-1", "load-2", "load-3"] {
                scriptStore.recordPageLoadError(
                    scriptID: "dark-thread",
                    message: "TypeError: Cannot read properties of null (reading 'classList')",
                    line: 2,
                    url: Self.browserAgentFixtureURL.absoluteString,
                    loadID: load,
                    occurredAt: now.addingTimeInterval(-40)
                )
            }
        }

        _ = try? scriptStore.create(
            id: "collapse-solved",
            name: "Collapse solved banners",
            matchRules: ["https://*.example.org/*"],
            js: """
            document.querySelectorAll('.solved-callout').forEach(node => {
              node.setAttribute('open', 'false');
            });
            """,
            css: "",
            injectionTime: .documentEnd,
            environment: .isolated,
            isEnabled: true,
            source: .agent(userPrompt: "Collapse solved banners across example.org subdomains"),
            now: now.addingTimeInterval(-86_400)
        )
        scriptStore.noteExecuted(scriptID: "collapse-solved", at: now.addingTimeInterval(-1080))

        _ = try? scriptStore.create(
            id: "quote-fold",
            name: "Fold long nested quotes",
            matchRules: ["https://talk.example.org/*"],
            js: """
            const quotes = document.querySelector('.post-stream').querySelectorAll('blockquote blockquote');
            quotes.forEach(q => q.classList.add('folded'));
            """,
            css: "blockquote.folded { max-height: 4.5em; overflow: hidden; }",
            injectionTime: .documentEnd,
            environment: .page,
            isEnabled: true,
            source: .agent(userPrompt: "Fold nested blockquotes on talk.example.org"),
            now: now.addingTimeInterval(-43_200)
        )
        for _ in 0..<3 {
            scriptStore.recordError(
                scriptID: "quote-fold",
                message: "TypeError: Cannot read properties of null (reading 'querySelectorAll')",
                line: 1,
                url: "https://talk.example.org/posts/release-notes-420",
                occurredAt: now.addingTimeInterval(-300)
            )
        }

        _ = try? scriptStore.create(
            id: "reading-spacing",
            name: "Comfortable reading spacing",
            matchRules: ["*://*/*"],
            js: "",
            css: "article p { line-height: 1.65; }",
            injectionTime: .documentStart,
            environment: .isolated,
            isEnabled: false,
            source: .imported,
            now: now.addingTimeInterval(-172_800)
        )

        if variant == "global-off" {
            settings.browserScriptsEnabled = false
        } else {
            settings.browserScriptsEnabled = true
        }

        if variant == "detail" {
            requestedScriptID = "op-only"
        } else if variant == "detail-error" {
            requestedScriptID = "quote-fold"
        } else if variant == "m4-ai" || variant == "m4-ai-detail" {
            settings.browserScriptsAIEnabled = true
            if let aiScript = try? scriptStore.create(
                id: "fold-empty-replies",
                name: "Fold empty replies",
                matchRules: ["*://news.example.org/*", "https://talk.example.org/*"],
                js: "const verdicts = await GM_ai.map([], 'Has substance?', { type: 'boolean' });",
                css: "[data-wk-judged='false'] { max-height: 2.2em; overflow: hidden; }",
                injectionTime: .documentEnd,
                environment: .isolated,
                isEnabled: true,
                source: .agent(userPrompt: "Fold replies that don't add anything"),
                grants: ["GM_ai"],
                now: now.addingTimeInterval(-3600)
            ) {
                scriptStore.noteExecuted(scriptID: aiScript.id, at: now.addingTimeInterval(-45))
                scriptStore.aiCache.store(entries: [(ScriptAICache.hashKey(["sample"]), .bool(false))], scriptID: aiScript.id, now: now)
                scriptStore.aiCache.recordUsage(scriptID: aiScript.id, calls: 3, cacheHits: 41, now: now)
                if variant == "m4-ai-detail" {
                    requestedScriptID = aiScript.id
                }
            }
        }

        if AssistantDebug.has("-dc-scripts-sheet") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                self?.requestedSettingsPage = .scripts
            }
        }
    }

    func seedM4ImportPreviewIfNeeded() {
        guard let mode = AssistantDebug.value("-dc-m4-import-preview") else { return }
        settings.hasCompletedOnboarding = true
        settings.assistantModel = ModelSelection(provider: .anthropic, model: "Claude Haiku 5.5")
        needsProviderSetup = nil
        browser.hideForumsHome()
        _ = browser.webView.loadHTMLString(
            """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>body{font-family:-apple-system,system-ui,sans-serif;margin:24px 16px;background:#fff;color:#1e1e1e}
            @media(prefers-color-scheme:dark){body{background:#16171a;color:#e6e6e8}}
            h1{font-size:22px;line-height:1.25}</style></head>
            <body><h1>Which home server for a quiet closet? Fanless builds compared</h1></body></html>
            """,
            baseURL: URL(string: "https://talk.example.org/threads/fanless-home-server/42")
        )

        for existing in scriptStore.scripts {
            _ = scriptStore.deleteIfPresent(id: existing.id)
        }

        let rawV1 = """
        // ==UserScript==
        // @name        Tidy Threads
        // @namespace   https://greasyfork.example.org/users/mira
        // @version     2.4.1
        // @author      mira
        // @match       *://*/*
        // @match       https://talk.example.org/threads/*
        // @include     /forum/
        // @run-at      context-menu
        // @grant       GM_getValue
        // @grant       GM_setValue
        // @grant       GM_xmlhttpRequest
        // @grant       GM_ai
        // @grant       GM_notification
        // @grant       GM_openInTab
        // @connect     api.example.org
        // @connect     cdn.example.net
        // @require     https://cdn.example.net/libs/jquery-3.7.1.min.js
        // ==/UserScript==
        document.querySelectorAll('.noise').forEach(el => el.remove());
        """

        guard let parsedV1 = try? ScriptImporter.parseExternalUserScript(rawV1) else { return }
        let libMeta = ScriptLoadedLibrary(
            meta: ScriptRequiredLibrary(
                url: "https://cdn.example.net/libs/jquery-3.7.1.min.js",
                sha256: ScriptStore.sha256Hex(Data("/* jquery */".utf8)),
                sizeBytes: 89_088
            ),
            code: "/* jquery */"
        )
        let installURL = "https://greasyfork.example.org/scripts/4821/tidy-threads.user.js"

        switch mode {
        case "add":
            let review = ScriptImportReview(
                mode: .create(duplicateNameHost: "scripts.example.com"),
                candidate: parsedV1.script,
                rawSource: rawV1,
                installURL: installURL,
                finalHost: "greasyfork.example.org",
                upstreamHash: ScriptStore.sha256Hex(Data(rawV1.utf8)),
                author: parsedV1.author,
                libraries: [libMeta],
                unsupportedItems: parsedV1.unsupported
            )
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.scriptImporter.presentDebugPhase(.ready(review))
            }

        case "update":
            guard var saved = try? scriptStore.saveImportedScript(
                parsedV1.script,
                installURL: installURL,
                upstreamHash: ScriptStore.sha256Hex(Data(rawV1.utf8)),
                libraries: [libMeta],
                turnOn: true
            ) else { return }
            saved = (try? scriptStore.update(
                id: saved.id,
                patch: ScriptUpdatePatch(js: saved.js + "\nconsole.log('local');"),
                origin: .editedByUser
            )) ?? saved

            let rawV2 = """
            // ==UserScript==
            // @name        Tidy Threads
            // @version     2.5.0
            // @author      mira
            // @match       *://*/*
            // @match       https://talk.example.org/threads/*
            // @match       https://forum.example.com/*
            // @grant       GM_getValue
            // @grant       GM_setValue
            // @grant       GM_xmlhttpRequest
            // @grant       GM_ai
            // @connect     api.example.org
            // @connect     cdn.example.net
            // @connect     stats.example.io
            // ==/UserScript==
            document.querySelectorAll('.noise, .promo').forEach(el => el.remove());
            """
            guard let parsedV2 = try? ScriptImporter.parseExternalUserScript(rawV2) else { return }
            let diff = ScriptImporter.computeDiff(
                existing: saved,
                candidate: parsedV2.script,
                newRawSource: rawV2,
                changedHost: (oldHost: "greasyfork.example.org", newHost: "raw.example.net")
            )
            let review = ScriptImportReview(
                mode: .update(existing: saved, diff: diff),
                candidate: parsedV2.script,
                rawSource: rawV2,
                installURL: installURL,
                finalHost: "raw.example.net",
                upstreamHash: ScriptStore.sha256Hex(Data(rawV2.utf8)),
                author: parsedV2.author,
                libraries: [],
                unsupportedItems: parsedV2.unsupported
            )
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.scriptImporter.presentDebugPhase(.ready(review))
            }

        case "failed":
            let failure = ScriptImportFailure(
                linkURL: installURL,
                reason: "Couldn’t fetch the file: the server answered 404 Not Found."
            )
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.scriptImporter.presentDebugPhase(.failed(failure, isUpdate: false))
            }

        case "settings", "detail":
            var specificV1 = parsedV1.script
            if mode == "settings" {
                specificV1.matchRules = ["https://talk.example.org/threads/*"]
            }
            guard let saved = try? scriptStore.saveImportedScript(
                specificV1,
                installURL: installURL,
                upstreamHash: ScriptStore.sha256Hex(Data(rawV1.utf8)),
                libraries: [libMeta],
                turnOn: true
            ) else { return }
            try? scriptStore.valuesStore.setValue(rawJSON: "\"compact\"", forKey: "density", scriptID: saved.id)
            try? scriptStore.valuesStore.setValue(rawJSON: "true", forKey: "hidePromo", scriptID: saved.id)
            try? scriptStore.valuesStore.setValue(rawJSON: "2", forKey: "schema", scriptID: saved.id)
            scriptImporter.setDebugAvailableUpdate(ScriptAvailableUpdate(
                scriptID: saved.id,
                fetchURL: installURL,
                newVersion: "2.5.0",
                checkedAt: Date().addingTimeInterval(-600),
                upstreamHash: "deadbeef"
            ))
            if mode == "detail" {
                requestedScriptID = saved.id
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.requestedSettingsPage = .scripts
            }

        default:
            break
        }
    }

    /// Loads deterministic in-memory HTML fixtures (`-dc-bar-morph-fixture long|short|agent-running|result-cards`)
    /// without touching saved settings, forums, or scripts on disk.
    func applyBarMorphDebugArguments() {
        guard let mode = AssistantDebug.value("-dc-bar-morph-fixture") else { return }
        settings.hasCompletedOnboarding = true
        needsProviderSetup = nil
        if AssistantDebug.value("-dc-bar") == nil {
            settings.browserBarPosition = .automatic
        }
        browser.onPageContextChanged = { _ in }
        browser.ignoresNavigationFailures = true
        browser.hideForumsHome()

        let url: URL = switch mode {
        case "short":
            URL(string: "https://news.example.org/story/short-note")!
        case "long-domain":
            URL(string: "https://communities.reader-archive.example.org/story/browser-bar-accessibility")!
        default:
            URL(string: "https://news.example.org/story/bar-morph")!
        }
        let html = mode == "short" ? Self.barMorphShortFixtureHTML : Self.barMorphLongFixtureHTML
        let context = PageContext(
            url: url,
            siteURL: mode == "result-cards" ? "https://news.example.org" : nil,
            state: mode == "result-cards" ? .forumHome : .notForum
        )
        browser.onPageContextChanged = { [weak browser] reported in
            if mode == "result-cards", !reported.isForum {
                browser?.setPageContext(context)
            }
        }
        browser.loadSamplePage(html, at: url)
        browser.setPageContext(context)

        if mode == "result-cards" {
            browseCursor.replace(
                with: [
                    BrowseItem(
                        kind: .source,
                        siteURL: "https://news.example.org",
                        topicID: "101",
                        postNumber: 1,
                        title: "Liquid glass capsule geometry",
                        excerpt: "Continuous progress p maps user scroll deltas over 64 points."
                    ),
                    BrowseItem(
                        kind: .source,
                        siteURL: "https://news.example.org",
                        topicID: "102",
                        postNumber: 1,
                        title: "Rest-only bottom inset switching",
                        excerpt: "Web view contentInset.bottom switches between 86 and 0 strictly at rest."
                    ),
                    BrowseItem(
                        kind: .source,
                        siteURL: "https://news.example.org",
                        topicID: "103",
                        postNumber: 1,
                        title: "Split result-card chip minimize",
                        excerpt: "Scrolling with the split panel hidden shrinks result cards to a chip."
                    )
                ],
                origin: .sources,
                current: 0
            )
        }

        // Configure Ollama (no Keychain write needed on unsigned simulator builds) so the Agent ring is enabled.
        var config = settings.configuration(for: .ollama)
        config.baseURL = "http://127.0.0.1:11434"
        config.model = "fixture-model"
        config.apiKey = ""
        settings.setConfiguration(config, for: .ollama)
        settings.setModel(ModelSelection(provider: .ollama, model: "fixture-model"), for: .assistant)
        settings.setModel(ModelSelection(provider: .ollama, model: "fixture-model"), for: .browserAgent)

        if mode == "agent-running" {
            // `loadsOnlySamplePage` routes `scriptStore` to a throwaway temp directory, never user data.
            settings.browserScriptsEnabled = true
            _ = try? scriptStore.create(
                id: "reader-width",
                name: "Comfortable column width",
                matchRules: ["*://news.example.org/*"],
                js: "",
                css: ".post { max-width: 68ch; }",
                injectionTime: .documentEnd,
                environment: .isolated,
                isEnabled: true,
                source: .agent(userPrompt: "Keep post lines comfortable")
            )
            _ = try? scriptStore.create(
                id: "calm-links",
                name: "Calm link underlines",
                matchRules: ["*://news.example.org/*"],
                js: "",
                css: "a { text-underline-offset: 2px; }",
                injectionTime: .documentEnd,
                environment: .isolated,
                isEnabled: true,
                source: .agent(userPrompt: "Tidy link underlines")
            )
            browserAgent.configureDebugModelClient(BrowserAgentDemoClient(mode: .running))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                await self.browser.waitUntilSettled(timeout: .seconds(5))
                self.browserAgent.send("Clean up the layout")
            }
        }
    }

    private static let barMorphLongFixtureHTML: String = {
        let posts = (1...28).map { index in
            let extraInput = index == 4
                ? """
                  <form class="filter-bar" onsubmit="document.activeElement?.blur(); return false;">
                    <input id="mid-field" type="text" enterkeyhint="done" aria-label="Reply note" placeholder="Reply note" onkeydown="if (event.key === 'Enter') { this.blur(); event.preventDefault(); }">
                  </form>
                  """
                : ""
            return """
            <section class="post" id="post-\(index)">
              <div class="meta">Post #\(index) · Reader notes</div>
              <p>Continuous bar morphing maps finger scroll delta over 64 points while keeping web view insets stable during active touch and coasting.</p>
              \(extraInput)
            </section>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Browser Bar Motion Spec</title>
          <style>
            * { box-sizing: border-box; }
            body {
              margin: 0;
              font-family: -apple-system, BlinkMacSystemFont, sans-serif;
              background: #fafaf7;
              color: #1c1917;
              line-height: 1.5;
            }
            header {
              padding: 18px 20px;
              border-bottom: 1px solid #e7e5e4;
              font-weight: 700;
              font-size: 1.15rem;
            }
            .filter-bar {
              margin: 0;
              padding: 10px 20px;
              border-bottom: 1px solid #ece9e4;
            }
            .filter-bar input {
              width: 100%;
              font-size: 16px;
              padding: 8px 12px;
              border: 1px solid #d6d3d1;
              border-radius: 10px;
              background: #ffffff;
              color: #1c1917;
            }
            .post {
              min-height: 120px;
              padding: 16px 20px;
              border-bottom: 1px solid #ece9e4;
            }
            .meta {
              font-size: 0.82rem;
              font-weight: 600;
              color: #78716c;
              margin-bottom: 6px;
            }
            footer#page-end {
              padding: 20px;
              font-weight: 700;
              background: #f3efe8;
              color: #292524;
            }
          </style>
        </head>
        <body>
          <header>Browser Bar Motion Spec</header>
          <form class="filter-bar" onsubmit="document.activeElement?.blur(); return false;">
            <input id="page-field" type="text" enterkeyhint="done" aria-label="Filter notes" placeholder="Filter notes" onkeydown="if (event.key === 'Enter') { this.blur(); event.preventDefault(); }">
          </form>
          \(posts)
          <footer id="page-end">End of thread · Post 28</footer>
        </body>
        </html>
        """
    }()

    private static let barMorphShortFixtureHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Short Pinned Note</title>
      <style>
        body {
          margin: 0;
          padding: 24px 20px;
          font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          background: #fafaf7;
          color: #1c1917;
        }
        h1 { margin: 0 0 8px; font-size: 1.2rem; }
        p { margin: 0; color: #57534e; }
      </style>
    </head>
    <body>
      <h1>Short Pinned Note</h1>
      <p>This page fits comfortably inside one viewport height and never collapses the bar.</p>
    </body>
    </html>
    """
}
#endif
