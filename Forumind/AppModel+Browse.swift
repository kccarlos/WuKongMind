import Foundation
import SwiftUI

// MARK: - Browsing and Home (UI engineer A)
//
// - `goHome()`                     current forum's /latest, else Home
// - `showForumsHome()`             Home over the current page (HomeView.swift)
// - `showsTodayPage`               the Today page pushed over Home
// - `todayModuleState`             the Today module's state (HomeState.swift)
// - `applyLaunchRuleIfNeeded()`    the first activation: Home or the last forum
// - `suggestedForumsToOffer`       suggested forums not added yet
// - `pinSuggested(_:)`             pins a suggested forum at once, then fetches its name/icon
// - `askForum(_:)`                 opens the forum and the Agent ("Ask the forum") for it
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

    func showForumsHome() {
        browser.showForumsHome()
    }

    /// The Today page, pushed over Home (Home's Today module, a digest
    /// notification, the Open Today and Play Today intents). Setting it
    /// false goes back to Home.
    var showsTodayPage: Bool {
        get { browser.showsForumsHome && homePath.first == .today }
        set {
            if newValue {
                browser.showForumsHome()
                if homePath != [.today] { homePath = [.today] }
            } else if !homePath.isEmpty {
                homePath = []
            }
        }
    }

    /// Home hid (a page loaded, Back): the pages pushed over it go too.
    func homeVisibilityChanged() {
        if !browser.showsForumsHome, !homePath.isEmpty { homePath = [] }
    }

    var todayModuleState: TodayModuleState {
        let digest = todaysDigest
        return TodayModuleState.resolve(
            digest: digest,
            digestActivity: digestActivity,
            providerReady: isProviderReady(for: .assistant),
            episode: podcast.episode?.digestID == digest?.id ? podcast.episode : nil,
            podcastActivity: podcast.activity
        )
    }

    // MARK: Launch rule (§7.2)

    /// A link, notification, Siri, Spotlight or the share extension opened
    /// something: before the rule has run, the page is left to it.
    func noteExternalEntry() {
        if launchPhase == .waiting { launchPhase = .openedExternally }
    }

    /// Once, on the first activation (after the share inbox and today's
    /// digest have started): Home or the last forum, which the browser has
    /// been loading since launch. A request from outside always wins.
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
        podcast.refresh()
        let defaults = UserDefaults.standard
        let decision = LaunchRule.decide(
            setting: setting,
            openedExternally: openedExternally,
            todayHasSomething: todayModuleState.hasSomething,
            lastHomeAutoShownDay: defaults.string(forKey: LaunchRule.lastHomeAutoShownDayKey),
            now: now
        )
        switch decision {
        case .external, .lastForum:
            break
        case .home(let marksDay):
            if marksDay { defaults.set(DailyDigest.dayKey(for: now), forKey: LaunchRule.lastHomeAutoShownDayKey) }
            // Over the restored forum's first load, which would otherwise
            // dismiss it as it starts.
            browser.showForumsHome(overPendingLoad: true)
        }
    }

    /// Suggested forums the user has not added yet.
    var suggestedForumsToOffer: [SuggestedForum] {
        Self.suggestedForums.filter { forum(for: $0.siteURL) == nil }
    }

    /// Pins a suggested forum immediately (no network), then refreshes its name
    /// and icon from `basic-info.json` in the background.
    func pinSuggested(_ suggested: SuggestedForum) {
        pin(Forum(siteURL: suggested.siteURL, kind: suggested.kind, name: suggested.name))
        refreshForumInfo(siteURL: suggested.siteURL)
    }

    /// "Ask the forum": opens the forum and prepares the Agent for it.
    func askForum(_ forum: Forum) {
        if !isCurrent(forum) || browser.showsForumsHome {
            openForum(forum)
        }
        agentSiteURL = forum.siteURL
        assistantMode = .agent
        panelRoute = .topic
        requestAssistant()
        if !isProviderReady(for: .agent) { needsProviderSetup = .agent }
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
    func applyDebugLaunchArguments() {
        applyBrowseDebugArguments()
        let arguments = ProcessInfo.processInfo.arguments
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
        }
        if let index = arguments.firstIndex(of: "-dc-fixture-model"), index + 1 < arguments.count {
            var configuration = settings.configuration(for: .ollama)
            configuration.baseURL = arguments[index + 1]
            configuration.model = "fixture-model"
            configuration.apiKey = ""
            settings.setConfiguration(configuration, for: .ollama)
            selectModel(ModelSelection(provider: .ollama, model: configuration.model), for: .both)
        }
        if let index = arguments.firstIndex(of: "-dc-open"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            browser.load(url)
        } else if arguments.contains("-dc-forums-home") {
            // Kept over the restored forum's first load.
            browser.showForumsHome(overPendingLoad: true)
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
            && (livePrompt != nil || hasLiveKey || demoMode == "spa-op-only")
        if usesCustomOpenPage {
            browser.ignoresNavigationFailures = true
            browser.hideForumsHome()
        } else {
            loadBrowserAgentFixturePage()
        }
        assistantMode = .browserAgent
        panelRoute = .topic

        if let demoMode {
            var config = settings.configuration(for: .anthropic)
            config.apiKey = "demo-key"
            config.model = "claude-haiku-5-5"
            settings.setConfiguration(config, for: .anthropic)
            settings.setModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .assistant)
            settings.setModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .agent)
            if demoMode == "no-model" {
                settings.setModel(ModelSelection(provider: .anthropic, model: ""), for: .browserAgent)
            } else {
                settings.setModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .browserAgent)
                if demoMode == "step-limit" {
                    settings.browserAgentMaxSteps = 2
                }
                if let parsed = BrowserAgentDemoClient.Mode(rawValue: demoMode) {
                    browserAgent.configureDebugModelClient(BrowserAgentDemoClient(mode: parsed))
                }
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
                guard let self, demoMode != "no-model", demoMode != "empty" else { return }
                let demoPrompt = demoMode == "saved-script"
                    ? "Keep only the original poster's posts and hide the sidebar on every visit"
                    : "Make this page dark and hide the sidebar"
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
            settings.setModel(ModelSelection(provider: .anthropic, model: modelID), for: .agent)
            settings.setModel(ModelSelection(provider: .anthropic, model: modelID), for: .browserAgent)
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
            js: """
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

        if variant == "page-error" {
            scriptStore.recordError(
                scriptID: "dark-thread",
                message: "TypeError: Cannot read properties of null (reading 'classList')",
                line: 2,
                url: Self.browserAgentFixtureURL.absoluteString,
                occurredAt: now.addingTimeInterval(-40)
            )
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
        }

        if AssistantDebug.has("-dc-scripts-sheet") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                self?.requestedSettingsPage = .scripts
            }
        }
    }
}
#endif
