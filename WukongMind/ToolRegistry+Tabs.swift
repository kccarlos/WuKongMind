import Foundation
import WebKit

// MARK: - tabs Agent tool (design-browser-bar-tabs-models.md §2, row T4)

/// Per-tab context for the `tabs` Agent tool: the shared `BrowserTabs` store and
/// the `sourceTabID` that owns this conversation's Agent run.
struct TabsToolContext: Sendable {
    let tabs: BrowserTabs
    let sourceTabID: String
    var timeout: TimeInterval

    init(
        tabs: BrowserTabs,
        sourceTabID: String,
        timeout: TimeInterval = ToolRegistry.navigationTimeout
    ) {
        self.tabs = tabs
        self.sourceTabID = sourceTabID
        self.timeout = timeout
    }

    @MainActor
    func resolvePopupURL(tabID: String, fallback: String) -> String {
        if let tab = tabs.tab(id: tabID) {
            if let current = tab.url?.absoluteString, !current.isEmpty {
                return current
            }
            if let live = tab.browser.existingWebView?.url?.absoluteString, !live.isEmpty {
                return live
            }
        }
        return fallback
    }
}

enum TabsToolAction: String, CaseIterable, Sendable {
    case list
    case open
    case close
    case `switch`
    case read
}

extension ToolRegistry {
    static func tabTools(context: AgentToolContext) -> [AgentTool] {
        guard let tabsContext = context.tabs else { return [] }
        return [makeTabsTool(context: tabsContext)]
    }

    /// Formats a compact target label for an opened-tab row (`ferries.example.org/bikes` or `Home`).
    static func compactTabTargetDisplay(_ rawURL: String, maxChars: Int = 56) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "Home", comment: "Title of a tab showing the Home start page")
        }
        if trimmed.lowercased() == "about:blank" {
            return "about:blank"
        }
        var stripped = trimmed
        for prefix in ["https://", "http://"] where stripped.lowercased().hasPrefix(prefix) {
            stripped = String(stripped.dropFirst(prefix.count))
            break
        }
        if stripped.lowercased().hasPrefix("www.") {
            stripped = String(stripped.dropFirst(4))
        }
        if let url = URL(string: trimmed),
           (url.path.isEmpty || url.path == "/"),
           url.query == nil,
           url.fragment == nil,
           stripped.hasSuffix("/") {
            stripped.removeLast()
        }
        return condenseInline(stripped, maxChars: maxChars)
    }

    /// Collapsed tool-row summary for `tabs(action: "open")` and `run_js` popup opens.
    static func openedTabSummary(rawURL: String, inBackground: Bool) -> String {
        let target = compactTabTargetDisplay(rawURL)
        guard inBackground else { return target }
        return String(
            localized: "\(target) · in the background",
            comment: "Tool row summary when the Agent opened a new tab in the background; placeholder is the compact page address or Home"
        )
    }

    static func tabsCountSummary(_ count: Int) -> String {
        String(
            localized: "\(count) tabs",
            comment: "Tool row summary showing the number of open browser tabs"
        )
    }

    static func makeTabsTool(context: TabsToolContext) -> AgentTool {
        let definition = AgentToolDefinition(
            name: "tabs",
            description: "List, open, read, switch, or close browser tabs. 'open' opens a new tab in the background by default (background=true) right after this conversation's tab while keeping this run here; set background=false or use 'switch' only when the user explicitly asked to show or switch to a tab. Use 'read' with 'tab_id' to inspect another open tab's page without leaving this tab. Returns the open tab list [{tab_id, title, url, active, loading}] (or the page content for 'read'); fails at the 30-tab limit ('Tab limit reached: 30 open').",
            parameters: [
                ToolParameterSchema(
                    name: "action",
                    type: .string,
                    description: "Action to perform: 'list', 'open', 'close', 'switch', or 'read'.",
                    enumValues: TabsToolAction.allCases.map(\.rawValue)
                ),
                ToolParameterSchema(
                    name: "url",
                    type: .string,
                    description: "For 'open': an http, https, or about:blank URL to open in the new tab (omit to open Home).",
                    minLength: 1
                ),
                ToolParameterSchema(
                    name: "tab_id",
                    type: .string,
                    description: "Target tab ID (such as 't2') for 'close', 'switch', or 'read'.",
                    minLength: 1
                ),
                ToolParameterSchema(
                    name: "background",
                    type: .boolean,
                    description: "For 'open': true (default) opens the new tab in the background without changing the front tab; set false only when the user asked to show the new tab."
                ),
                ToolParameterSchema(
                    name: "wait",
                    type: .string,
                    description: "For 'open' with 'url': 'load' (default) waits up to 30 s for the page to load; 'none' returns as soon as loading starts.",
                    enumValues: ["load", "none"]
                ),
                ToolParameterSchema(
                    name: "mode",
                    type: .string,
                    description: "For 'read': output format — 'structure' (default), 'text', or 'html'.",
                    enumValues: PageReadMode.allCases.map(\.rawValue)
                ),
                ToolParameterSchema(
                    name: "selector",
                    type: .string,
                    description: "For 'read': optional CSS selector to scope reading.",
                    minLength: 1
                ),
                ToolParameterSchema(
                    name: "max_length",
                    type: .integer,
                    description: "For 'read': optional maximum character count to return.",
                    minimum: 1,
                    maximum: 500_000
                )
            ],
            required: ["action"]
        )

        return AgentTool(
            definition: definition,
            customValidate: { args in
                let actionRaw = args["action"]?.stringValue ?? ""
                guard let action = TabsToolAction(rawValue: actionRaw) else {
                    throw ToolValidationError("Invalid arguments for 'tabs': unknown action '\(actionRaw)'.")
                }
                switch action {
                case .list:
                    break
                case .open:
                    if let rawURL = args["url"]?.stringValue {
                        _ = try navigableURL(rawURL, toolName: "tabs")
                    }
                case .close, .switch, .read:
                    let id = args["tab_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if id.isEmpty {
                        throw ToolValidationError(
                            "Invalid arguments for 'tabs': action '\(action.rawValue)' requires a non-empty 'tab_id'."
                        )
                    }
                }
            },
            summarizeArguments: { args in
                let action = TabsToolAction(rawValue: args["action"]?.stringValue ?? "") ?? .list
                switch action {
                case .list:
                    return "list"
                case .open:
                    let background = args["background"]?.strictBoolValue ?? true
                    return openedTabSummary(rawURL: args["url"]?.stringValue ?? "", inBackground: background)
                case .switch:
                    return condenseInline(args["tab_id"]?.stringValue ?? "", maxChars: 24)
                case .close:
                    return condenseInline(args["tab_id"]?.stringValue ?? "", maxChars: 24)
                case .read:
                    let tabID = condenseInline(args["tab_id"]?.stringValue ?? "", maxChars: 24)
                    if let mode = args["mode"]?.stringValue, mode != PageReadMode.structure.rawValue {
                        return "\(tabID) · \(mode)"
                    }
                    return tabID
                }
            },
            execute: { args in
                let action = TabsToolAction(rawValue: args["action"]?.stringValue ?? "") ?? .list
                switch action {
                case .list:
                    return await executeTabsList(context: context)
                case .open:
                    return try await executeTabsOpen(args: args, context: context)
                case .switch:
                    let tabID = args["tab_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return await executeTabsSwitch(tabID: tabID, context: context)
                case .close:
                    let tabID = args["tab_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return await executeTabsClose(tabID: tabID, context: context)
                case .read:
                    let tabID = args["tab_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return try await executeTabsRead(tabID: tabID, args: args, context: context)
                }
            }
        )
    }

    // MARK: - Action Handlers

    @MainActor
    private static func executeTabsList(context: TabsToolContext) -> ToolExecutionOutput {
        let json = encodeTabList(tabs: context.tabs)
        let summary = tabsCountSummary(context.tabs.tabs.count)
        return ToolExecutionOutput(content: json, summary: summary, isError: false)
    }

    private static func executeTabsOpen(
        args: [String: JSONValue],
        context: TabsToolContext
    ) async throws -> ToolExecutionOutput {
        let requestedURL: URL?
        if let rawURL = args["url"]?.stringValue {
            requestedURL = try navigableURL(rawURL, toolName: "tabs")
        } else {
            requestedURL = nil
        }
        let background = args["background"]?.strictBoolValue ?? true
        let wait = (args["wait"]?.stringValue ?? "load") != "none"

        if let requestedURL, ScriptImporter.isUserScriptURL(requestedURL) {
            await MainActor.run {
                let opener = context.tabs.tab(id: context.sourceTabID) ?? context.tabs.currentTab
                opener.browser.onUserScriptNavigation?(requestedURL)
            }
            return ToolExecutionOutput(
                content: ScriptImporter.navigateInterceptMessage,
                summary: ScriptImporter.navigateInterceptMessage,
                isError: false
            )
        }

        let openOutcome: Result<BrowserTab, BrowserTabOpenError> = await MainActor.run {
            context.tabs.openTabForTool(
                url: nil,
                after: context.sourceTabID,
                inFront: !background
            )
        }

        let newTab: BrowserTab
        switch openOutcome {
        case .failure(let openError):
            let message = openError.localizedDescription
            return ToolExecutionOutput(
                content: "Error: \(message)",
                summary: "Error: \(message)",
                isError: true
            )
        case .success(let created):
            newTab = created
        }

        guard let requestedURL else {
            let json = await MainActor.run {
                encodeTabList(tabs: context.tabs, openedTabID: newTab.id)
            }
            return ToolExecutionOutput(
                content: json,
                summary: openedTabSummary(rawURL: "", inBackground: background),
                isError: false,
                openedTabID: newTab.id
            )
        }

        let (bridge, attachedTabID) = await MainActor.run { () -> (AgentBridge, String?) in
            let attachID: String? = background ? newTab.id : nil
            if let attachID {
                context.tabs.beginAgentBackgroundAttachment(tabID: attachID)
            }
            return (newTab.browser.agentBridge, attachID)
        }
        let navOutcome: AgentNavigationOutcome
        do {
            navOutcome = try await bridge.load(requestedURL, wait: wait, timeout: context.timeout)
            if let attachedTabID {
                await MainActor.run {
                    context.tabs.endAgentBackgroundAttachment(tabID: attachedTabID)
                }
            }
        } catch {
            if let attachedTabID {
                await MainActor.run {
                    context.tabs.endAgentBackgroundAttachment(tabID: attachedTabID)
                }
            }
            throw error
        }

        if let intercepted = navOutcome.interceptedMessage {
            return ToolExecutionOutput(content: intercepted, summary: intercepted, isError: false)
        }

        let (json, finalURL) = await MainActor.run {
            let resolved = navOutcome.url.isEmpty ? requestedURL.absoluteString : navOutcome.url
            let encoded = encodeTabList(
                tabs: context.tabs,
                openedTabID: newTab.id,
                openedTitleFallback: navOutcome.title
            )
            return (encoded, resolved)
        }

        if let failure = navOutcome.failure {
            return ToolExecutionOutput(
                content: "Error: Opened tab \(newTab.id), but the page didn't load: \(failure)\n\n\(json)",
                summary: "Error: \(condenseInline(failure, maxChars: 72))",
                isError: true,
                openedTabID: newTab.id,
                touchedURLs: [requestedURL.absoluteString]
            )
        }

        return ToolExecutionOutput(
            content: json,
            summary: openedTabSummary(rawURL: finalURL, inBackground: background),
            isError: false,
            openedTabID: newTab.id,
            touchedURLs: [finalURL]
        )
    }

    @MainActor
    private static func executeTabsSwitch(
        tabID: String,
        context: TabsToolContext
    ) -> ToolExecutionOutput {
        guard let target = context.tabs.tab(id: tabID) else {
            return ToolExecutionOutput(
                content: "Error: No open tab with tab_id '\(tabID)'.",
                summary: "Error: No open tab '\(tabID)'.",
                isError: true
            )
        }
        _ = context.tabs.switchToTab(id: tabID)
        let json = encodeTabList(tabs: context.tabs)
        let summary = "\(tabShortLabel(target)) · \(tabsCountSummary(context.tabs.tabs.count))"
        return ToolExecutionOutput(content: json, summary: summary, isError: false)
    }

    @MainActor
    private static func executeTabsClose(
        tabID: String,
        context: TabsToolContext
    ) -> ToolExecutionOutput {
        guard let target = context.tabs.tab(id: tabID) else {
            return ToolExecutionOutput(
                content: "Error: No open tab with tab_id '\(tabID)'.",
                summary: "Error: No open tab '\(tabID)'.",
                isError: true
            )
        }
        guard context.tabs.tabs.count > 1 else {
            return ToolExecutionOutput(
                content: "Error: Can't close the last open tab.",
                summary: "Error: Can't close the last open tab.",
                isError: true
            )
        }
        if tabID == context.sourceTabID, target.agentSession.isRunning {
            return ToolExecutionOutput(
                content: "Error: Can't close tab '\(tabID)' while this conversation's run is using it.",
                summary: "Error: Can't close active run's tab.",
                isError: true
            )
        }
        let closedLabel = tabShortLabel(target)
        _ = context.tabs.closeTab(id: tabID)
        let json = encodeTabList(tabs: context.tabs)
        let summary = "\(closedLabel) · \(tabsCountSummary(context.tabs.tabs.count))"
        return ToolExecutionOutput(content: json, summary: summary, isError: false)
    }

    private static func executeTabsRead(
        tabID: String,
        args: [String: JSONValue],
        context: TabsToolContext
    ) async throws -> ToolExecutionOutput {
        let modeRaw = args["mode"]?.stringValue ?? PageReadMode.structure.rawValue
        let mode = PageReadMode(rawValue: modeRaw) ?? .structure
        let selector = args["selector"]?.stringValue
        let maxLength = args["max_length"]?.strictIntValue

        enum TargetState {
            case missing
            case home(title: String)
            case page(bridge: AgentBridge, needsLazyLoad: URL?, currentURL: String, label: String)
        }

        let state: TargetState = await MainActor.run {
            guard let target = context.tabs.tab(id: tabID) else {
                return .missing
            }
            let webURL = target.browser.existingWebView?.url?.absoluteString ?? ""
            if target.showsHome, target.url == nil, webURL != "about:blank" {
                return .home(title: target.title)
            }
            let lazyURL: URL? = (!target.isWebViewLoaded ? target.url : nil)
            let urlString = target.url?.absoluteString ?? webURL
            return .page(
                bridge: target.browser.agentBridge,
                needsLazyLoad: lazyURL,
                currentURL: urlString,
                label: tabHostOrTitle(target)
            )
        }

        switch state {
        case .missing:
            return ToolExecutionOutput(
                content: "Error: No open tab with tab_id '\(tabID)'.",
                summary: "Error: No open tab '\(tabID)'.",
                isError: true
            )
        case .home(let title):
            return ToolExecutionOutput(
                content: "Tab \(tabID) is on Home (no web page loaded).",
                summary: title,
                isError: false
            )
        case .page(let bridge, let lazyURL, let initialURL, let fallbackLabel):
            await MainActor.run {
                context.tabs.beginAgentBackgroundAttachment(tabID: tabID)
            }
            let content: String
            do {
                if let lazyURL, ForumBrowserModel.isBrowsableURL(lazyURL) {
                    let loadOutcome = try await bridge.load(lazyURL, wait: true, timeout: context.timeout)
                    if let failure = loadOutcome.failure {
                        await MainActor.run {
                            context.tabs.endAgentBackgroundAttachment(tabID: tabID)
                        }
                        return ToolExecutionOutput(
                            content: "Error: Could not load tab '\(tabID)': \(failure)",
                            summary: "Error: \(condenseInline(failure, maxChars: 72))",
                            isError: true,
                            touchedURLs: [lazyURL.absoluteString]
                        )
                    }
                }
                content = try await bridge.readPage(mode: mode, selector: selector, maxLength: maxLength)
                await MainActor.run {
                    context.tabs.endAgentBackgroundAttachment(tabID: tabID)
                }
            } catch {
                await MainActor.run {
                    context.tabs.endAgentBackgroundAttachment(tabID: tabID)
                }
                throw error
            }
            let (label, resolvedURL) = await MainActor.run {
                guard let target = context.tabs.tab(id: tabID) else {
                    return (fallbackLabel, initialURL)
                }
                let finalURL = target.url?.absoluteString
                    ?? target.browser.existingWebView?.url?.absoluteString
                    ?? initialURL
                return (tabHostOrTitle(target), finalURL)
            }
            return ToolExecutionOutput(
                content: content,
                summary: label,
                isError: false,
                touchedURLs: resolvedURL.isEmpty ? [] : [resolvedURL]
            )
        }
    }

    // MARK: - Serialization Helpers

    @MainActor
    static func encodeTabList(
        tabs: BrowserTabs,
        openedTabID: String? = nil,
        openedTitleFallback: String? = nil
    ) -> String {
        let rows: [[String: Any]] = tabs.tabs.map { tab in
            let urlString: String
            if tab.showsHome {
                let liveURL = tab.browser.existingWebView?.url?.absoluteString ?? ""
                urlString = liveURL == "about:blank" ? "about:blank" : ""
            } else {
                urlString = tab.url?.absoluteString
                    ?? tab.browser.existingWebView?.url?.absoluteString
                    ?? ""
            }
            var resolvedTitle = tab.title
            if tab.id == openedTabID,
               let fallback = openedTitleFallback?.trimmingCharacters(in: .whitespacesAndNewlines),
               !fallback.isEmpty,
               (resolvedTitle == tab.url?.host || resolvedTitle == ForumBrowserModel.defaultPageTitle) {
                resolvedTitle = fallback
            }
            var row: [String: Any] = [
                "tab_id": tab.id,
                "title": resolvedTitle,
                "url": urlString,
                "active": tab.id == tabs.currentTabID,
                "loading": tab.browser.isLoading
            ]
            if tab.id == openedTabID {
                row["opened"] = true
            }
            return row
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: rows,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return "[]"
        }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    private static func tabHostOrTitle(_ tab: BrowserTab) -> String {
        if let host = tab.url?.host, !host.isEmpty {
            let clean = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return condenseInline(clean, maxChars: 48)
        }
        if tab.browser.existingWebView?.url?.absoluteString == "about:blank" {
            return "about:blank"
        }
        return condenseInline(tab.title, maxChars: 48)
    }

    @MainActor
    private static func tabShortLabel(_ tab: BrowserTab) -> String {
        if let url = tab.url {
            return compactTabTargetDisplay(url.absoluteString, maxChars: 40)
        }
        return condenseInline(tab.title, maxChars: 40)
    }
}
