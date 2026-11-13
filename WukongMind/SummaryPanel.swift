import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The assistant's screens shown as a sheet (Post & responses; History and
/// Settings over Home and in the drawer layout).
enum ExpandedPanelRoute: String, Identifiable {
    case post
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .post: String(localized: "Post & responses")
        case .history: String(localized: "History", comment: "Screen title: saved summaries, chats, Ask the forum runs and watched topics")
        case .settings: String(localized: "Settings")
        }
    }
}

/// The unified Agent panel (`design-unified.md` §1): one conversation view
/// shared by the iPhone drawer (`AIDrawer`) and iPad split sidebar (`SplitWorkspace`),
/// with the `"Agent"` + This page header, unified transcript, transient status line,
/// suggestion slot (2b), and `AssistantComposer`.
struct AssistantPanel: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var streams: StreamStore
    @ObservedObject private var browser: ForumBrowserModel
    private var browserAgent: BrowserAgentSession { app.browserAgent }
    private var scriptStore: ScriptStore { app.scriptStore }
    /// Post & responses as a sheet.
    let onExpand: (ExpandedPanelRoute) -> Void
    /// Opens a forum URL in the Browse workspace (the agent's step log uses it).
    let onOpenURL: ((URL) -> Void)?
    @State private var exporting = false
    /// "Tap a post number to jump to it", shown with the first summary.
    @State private var showsCitationTip = false
    @State private var renderedSummary: ThrottledParse<DrawerSummarySections.Input, (sections: Int, hasCitations: Bool, rows: [MarkdownRow])>?
    @State private var agentDraft = ""
    @FocusState private var composerFocused: Bool
    @State private var isKeyboardVisible = false
    @State private var showsPageCapabilitiesPopover = false
    @State private var showsCompletedStatus = false
    @State private var completedStatusTask: Task<Void, Never>?
    @State private var expandedToolRowIDs: Set<UUID> = []
    @State private var requestedProviderSetup = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.composerBottomInset) private var bottomInset

    init(
        app: AppModel,
        onExpand: @escaping (ExpandedPanelRoute) -> Void,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.app = app
        _streams = ObservedObject(wrappedValue: app.streams)
        _browser = ObservedObject(wrappedValue: app.browser)
        self.onExpand = onExpand
        self.onOpenURL = onOpenURL
    }

    private var activeRecords: [WorkRecord] {
        guard let topicKey = app.currentTopic?.topicKey else { return [] }
        return app.activities.filter { $0.topicKey == topicKey && !$0.status.isTerminal }
    }

    private var activeSummary: WorkRecord? { activeRecords.first { $0.type == .summary } }
    private var summaryRun: SummaryRunState {
        guard let topicKey = app.currentTopic?.topicKey else { return .idle }
        return SummaryRunState.resolve(app.activities, topicKey: topicKey)
    }
    private var isSummaryFailed: Bool {
        if case .failed = summaryRun { return true }
        return false
    }
    private var activePull: WorkRecord? { activeRecords.first { $0.type == .pull } }
    private var activeChat: WorkRecord? { activeRecords.first { $0.type == .chat } }

    var payload: TopicExportPayload {
        app.currentExportPayload
    }

    private var exportText: String {
        payload.text(options: app.exportOptions)
    }

    private var exportDisabled: Bool {
        activePull != nil || !payload.hasContent(options: app.exportOptions)
    }

    private var providerSetupRole: ModelRole? {
        if app.assistantMode == .agent, !app.isProviderReady(for: .agent) {
            return .agent
        }
        if !app.isProviderReady(for: .browserAgent),
           requestedProviderSetup || !app.isProviderReady(for: .assistant) {
            return .browserAgent
        }
        return nil
    }

    private var isBrowserAgentCompleted: Bool {
        if case .completed = browserAgent.runState { return true }
        return false
    }

    private var runningStepNumber: Int? {
        if case .running(let step, _) = browserAgent.runState {
            return max(1, step)
        }
        return nil
    }

    private var foldsStatusIntoHeader: Bool {
        isKeyboardVisible && composerFocused && runningStepNumber != nil
    }

    private var showsFooterStatusLine: Bool {
        (browserAgent.isRunning && !(isKeyboardVisible && composerFocused))
            || (showsCompletedStatus && isBrowserAgentCompleted)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Over History and Settings too: voice can always be muted or
            // ended (the rest of the row is about the topic).
            DrawerStatusRow(
                app: app, podcast: app.podcast, router: app.router, voice: app.voice,
                voiceOnly: app.panelRoute != .topic
            )
            if app.panelRoute == .topic {
                VStack(spacing: 0) {
                    drawerHeader
                    Divider()
                    drawerThread
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    assistantFooter
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agentPanel")
            } else {
                routeContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // In the drawer the system sheet's glass shows through at medium
        // (opaque at large by itself).
        .background(Color.clear)
        .dcKeyboardVisible($isKeyboardVisible)
        .environment(\.activeCitation, app.citationJump?.number)
        // A pointer over a citation pre-highlights the post on the page.
        .environment(\.citationHover, CitationHoverAction { number in
            Task { await app.browser.highlight([], flash: PostFlash(number: number)) }
        })
        .environment(\.openURL, OpenURLAction { url in
            // `#37` in a summary: scroll the page to the post (§4.5).
            if let number = PostCitations.postNumber(from: url) {
                app.jumpToCitation(number)
                return .handled
            }
            guard ForumBrowserModel.isBrowsableURL(url) else { return .systemAction }
            openInBrowser(url)
            return .handled
        })
        .onChange(of: app.currentTopic?.topicKey) {
            app.exportOptions = ExportOptions()
            renderedSummary = nil
        }
        .onChange(of: app.askFocusRequest) {
            composerFocused = true
        }
        .onChange(of: browserAgent.runState) { _, newState in
            updateCompletedStatusVisibility(for: newState, isInitialAppear: false)
        }
        .onAppear {
            updateCompletedStatusVisibility(for: browserAgent.runState, isInitialAppear: true)
            #if DEBUG
            if AssistantDebug.has("-dc-scripts-open-popover") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    showsPageCapabilitiesPopover = true
                }
            }
            #endif
        }
        .onDisappear {
            completedStatusTask?.cancel()
            completedStatusTask = nil
        }
        .fileExporter(
            isPresented: $exporting,
            document: PlainTextDocument(text: exportText),
            contentType: .plainText,
            defaultFilename: "wukongmind-\(exportSlug).txt"
        ) { result in
            if case .failure(let error) = result {
                app.presentError(error.localizedDescription)
            }
        }
    }

    private static var completedStatusHoldDuration: Double {
        #if DEBUG
        if AssistantDebug.has("-dc-browser-agent-live-prompt")
            || AssistantDebug.value("-dc-browser-agent-live-prompt") != nil
            || AssistantDebug.has("-dc-browser-agent-live-key")
            || AssistantDebug.value("-dc-browser-agent-live-key") != nil
            || AssistantDebug.has("-dc-browser-agent-demo")
            || AssistantDebug.value("-dc-browser-agent-demo") != nil {
            return 8.0
        }
        #endif
        return 3.5
    }

    private func updateCompletedStatusVisibility(for state: BrowserAgentRunState, isInitialAppear: Bool) {
        completedStatusTask?.cancel()
        completedStatusTask = nil
        guard case .completed = state else {
            showsCompletedStatus = false
            return
        }
        let holdDuration = Self.completedStatusHoldDuration
        if isInitialAppear {
            var remaining = holdDuration
            var shouldShow = false
            #if DEBUG
            if AssistantDebug.has("-dc-browser-agent-demo") || AssistantDebug.value("-dc-browser-agent-demo") != nil {
                shouldShow = true
            }
            #endif
            if !shouldShow, let lastRun = browserAgent.runs.last {
                let endedAt = lastRun.startedAt.addingTimeInterval(lastRun.duration ?? 0)
                let elapsed = Date().timeIntervalSince(endedAt)
                if elapsed >= 0, elapsed < holdDuration {
                    shouldShow = true
                    remaining = max(0.5, holdDuration - elapsed)
                }
            }
            guard shouldShow else {
                showsCompletedStatus = false
                return
            }
            showsCompletedStatus = true
            scheduleCompletedStatusDismiss(after: remaining)
        } else {
            showsCompletedStatus = true
            scheduleCompletedStatusDismiss(after: holdDuration)
        }
    }

    private func scheduleCompletedStatusDismiss(after seconds: Double) {
        completedStatusTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.quick)) {
                showsCompletedStatus = false
            }
        }
    }

    @ViewBuilder
    private var routeContent: some View {
        VStack(spacing: 0) {
            switch app.panelRoute {
            case .topic:
                EmptyView()
            case .history:
                subHeader("History")
                Divider()
                HistoryView(app: app)
            }
        }
    }

    private var exportSlug: String {
        guard let topic = app.currentTopic else { return "topic" }
        let host = ForumSite.host(of: topic.siteURL)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return "\(host)-\(topic.topicID)"
    }

    /// A post link opens the topic at that post and highlights it. From
    /// the drawer at its large height, like a citation (§4.5), the drawer
    /// steps down to medium so the post shows.
    private func openInBrowser(_ url: URL) {
        if app.router.drawerPhase == .shown, app.router.drawerDetent == .large {
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) { app.router.drawerDetent = .medium }
        }
        app.openLink(url)
        onOpenURL?(url)
    }

    // MARK: Header

    private var currentScriptPageURL: URL? {
        if let url = browser.currentURL, !browser.showsForumsHome {
            return url
        }
        if let url = app.pageContext.url, !browser.showsForumsHome {
            return url
        }
        return nil
    }

    private var currentHost: String {
        if let url = currentScriptPageURL,
           let host = url.host,
           !host.isEmpty {
            return host
        }
        return String(localized: "No page open", comment: "Browser agent context bar when no web page is loaded")
    }

    private var matchingPageScripts: [UserScript] {
        guard let url = currentScriptPageURL else { return [] }
        return scriptStore.sortedMatchingScripts(for: url, includeDisabled: true)
    }

    private var enabledMatchingPageScripts: [UserScript] {
        matchingPageScripts.filter(\.isEnabled)
    }

    private var matchingPageScriptErrorCount: Int {
        guard scriptStore.isGlobalEnabled else { return 0 }
        return enabledMatchingPageScripts.filter { scriptStore.error(for: $0.id) != nil }.count
    }

    /// Unified Agent header: `"Agent"`, the This page seal (or folded `"Step N"`
    /// while the keyboard is up during a run), and the `⋯` menu.
    private var drawerHeader: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            HStack(spacing: 8) {
                Text(AssistantMode.browserAgent.title)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("drawerTitle")
                if !dynamicTypeSize.isAccessibilitySize {
                    headerStatusOrPageSeal
                }
                Spacer(minLength: 0)
                drawerMoreMenu
            }
            if dynamicTypeSize.isAccessibilitySize {
                headerStatusOrPageSeal
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(minHeight: DCTheme.controlHeight + 10)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawerHeader")
    }

    @ViewBuilder
    private var headerStatusOrPageSeal: some View {
        if foldsStatusIntoHeader, let step = runningStepNumber {
            HStack(spacing: 6) {
                DCAgentRing(size: 14, lineWidth: 2, isTurning: !reduceMotion)
                Text("Step \(step)", comment: "Folded header status during an Agent run while the keyboard is up; placeholder is step number")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DCTheme.goldInk)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(minHeight: DCTheme.controlHeight)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("agentFoldedStatus")
        } else {
            thisPageSealButton
        }
    }

    private var thisPageSealButton: some View {
        let allCount = matchingPageScripts.count
        let activeCount = enabledMatchingPageScripts.count
        let errorCount = matchingPageScriptErrorCount
        let isGlobalEnabled = scriptStore.isGlobalEnabled
        let host = currentHost

        let sealInfo: (text: String, accessibility: String, isDanger: Bool, variant: DCSealVariant, symbol: String?) = {
            if !isGlobalEnabled, allCount > 0 {
                let offPart = String(
                    localized: "Scripts off · \(allCount) here",
                    comment: "Browser agent context chip when global scripts switch is off; placeholder is number of scripts matching this page"
                )
                return (
                    "\(host) · \(offPart)",
                    String(localized: "This page, \(host), \(offPart)", comment: "Accessibility label of the This page seal when scripts are turned off"),
                    false,
                    .outline,
                    "nosign"
                )
            }
            if errorCount > 0 {
                let scriptsPart = String(localized: "\(activeCount) scripts", comment: "Count of scripts in context chip error state")
                let errorsPart = errorCount == 1
                    ? String(localized: "1 error", comment: "Singular error count in context chip")
                    : String(localized: "\(errorCount) errors", comment: "Plural error count in context chip")
                return (
                    "\(host) · \(scriptsPart) · \(errorsPart)",
                    String(localized: "This page, \(host), \(scriptsPart), \(errorsPart)", comment: "Accessibility label of the This page seal when scripts have errors"),
                    true,
                    .outline,
                    "exclamationmark.triangle.fill"
                )
            }
            if activeCount > 0 {
                let scriptsPart = String(localized: "\(activeCount) scripts", comment: "Count of scripts in context chip error state")
                return (
                    "\(host) · \(scriptsPart)",
                    String(localized: "This page, \(host), \(scriptsPart)", comment: "Accessibility label of the This page seal when scripts are active"),
                    false,
                    .ink,
                    nil
                )
            }
            return (
                host,
                String(localized: "This page, \(host)", comment: "Accessibility label of the This page seal when no scripts match; placeholder is the host"),
                false,
                .ink,
                nil
            )
        }()

        return Group {
            if sealInfo.isDanger {
                Button {
                    DCHaptics.tap()
                    showsPageCapabilitiesPopover = true
                } label: {
                    HStack(spacing: DCTheme.space1) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(verbatim: sealInfo.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .accessibilityHidden(true)
                    }
                    .font(DCType.caption)
                    .foregroundStyle(DCTheme.danger)
                    .padding(.horizontal, DCTheme.space2)
                    .padding(.vertical, DCTheme.space1)
                    .frame(minHeight: 24)
                    .background(
                        DCTheme.danger.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous)
                    )
                    .frame(minHeight: DCTheme.controlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                DCSealButton(
                    text: sealInfo.text,
                    variant: sealInfo.variant,
                    systemImage: sealInfo.symbol
                ) {
                    showsPageCapabilitiesPopover = true
                }
                .truncationMode(.middle)
            }
        }
        .accessibilityLabel(Text(verbatim: sealInfo.accessibility))
        .accessibilityIdentifier("pageCapabilitiesSeal")
        .popover(isPresented: $showsPageCapabilitiesPopover, arrowEdge: .top) {
            PageCapabilitiesView(
                app: app,
                pageURL: currentScriptPageURL,
                isPresented: $showsPageCapabilitiesPopover
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: Header ··· menu

    private var currentAgentModelSubtitle: String {
        let selection = app.selection(for: .browserAgent)
        let readiness = app.readiness(for: .browserAgent)
        if readiness == .ready {
            return ModelPill.label(for: selection)
        }
        return readiness.title
    }

    private var drawerMoreMenu: some View {
        Menu {
            Section {
                Menu {
                    agentModelMenuItems
                } label: {
                    Label {
                        Text("Model", comment: "Assistant more menu submenu for choosing the Agent model")
                        Text(verbatim: currentAgentModelSubtitle)
                    } icon: {
                        Image(systemName: "cpu")
                    }
                }
                .accessibilityIdentifier("agentModelMenu")

                Button {
                    app.router.item = .instructions
                } label: {
                    Label("Instructions & Context", systemImage: "text.quote")
                }
                .accessibilityIdentifier("menuInstructions")
                .disabled(app.currentTopic == nil)

                Button {
                    DCHaptics.tap()
                    browserAgent.resetConversation()
                    if app.assistantMode == .agent {
                        app.assistantMode = .summary
                    }
                } label: {
                    Label(
                        String(localized: "New conversation", comment: "Browser agent menu action: clear the conversation and start fresh"),
                        systemImage: "plus.bubble"
                    )
                }
                .accessibilityIdentifier("agentNewConversation")
                .disabled(browserAgent.runs.isEmpty && browserAgent.messages.isEmpty && !browserAgent.isRunning && app.assistantMode != .agent)
            }

            Section {
                Button {
                    withAnimation(DCMotion.respecting(reduceMotion)) { app.panelRoute = .history }
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("openHistoryMenu")

                Button {
                    app.openPanelRoute(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("openSettingsMenu")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 24, weight: .medium) : .body.weight(.medium))
        }
        .buttonStyle(DCIconButtonStyle())
        .accessibilityLabel("More assistant actions")
        .accessibilityIdentifier("assistantMoreMenu")
    }

    @ViewBuilder
    private var agentModelMenuItems: some View {
        let current = app.selection(for: .browserAgent)
        let favorites = app.visibleFavorites.filter { $0.selection.supportsToolCalling }
        Section {
            if !current.model.isEmpty, !favorites.contains(where: { $0.matches(current) }) {
                Toggle(isOn: .constant(true)) {
                    Text(current.provider.displayName)
                    Text(verbatim: ModelPill.label(for: current))
                }
            }
            ForEach(favorites) { favorite in
                Toggle(isOn: Binding(
                    get: { favorite.matches(current) },
                    set: { _ in app.activateFavorite(favorite, for: .browserAgent) }
                )) {
                    Text(favorite.provider.displayName)
                    Text(app.favoriteDetail(favorite))
                }
            }
        }
        Button {
            app.requestedSettingsPage = .provider
        } label: {
            Label("AI models…", systemImage: "gearshape")
        }
        .accessibilityIdentifier("modelMenuSettings")
    }

    private func subHeader(_ title: LocalizedStringKey) -> some View {
        HStack {
            Button {
                withAnimation(DCMotion.respecting(reduceMotion)) {
                    app.panelRoute = .topic
                }
            } label: {
                Label("Agent", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.body.weight(.medium))
            }
            .accessibilityLabel("Back to assistant")
            .accessibilityIdentifier("backToTopic")
            // Esc closes History in the panel.
            .dcCancelShortcut()
            Spacer()
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            // Balance the back button so the title stays centered.
            Label("Agent", systemImage: "chevron.left")
                .font(.body.weight(.medium))
                .hidden()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: DCTheme.controlHeight + 8)
        .background(DCTheme.toolbar)
    }

    // MARK: Sticky Footer (StatusLine + 2b Suggestion Slot + Composer)

    private var assistantFooter: some View {
        VStack(alignment: .leading, spacing: DCTheme.space2) {
            if showsFooterStatusLine {
                AgentStatusLine(
                    session: browserAgent,
                    developerMode: app.settings.developerMode
                )
                .transition(.opacity)
            }

            // Reserved slot for SuggestionRow (One panel 2b).

            AssistantComposer(
                draft: $agentDraft,
                focused: $composerFocused,
                isRunning: browserAgent.isRunning,
                onSend: sendAgentPrompt,
                onStop: { browserAgent.stop() }
            )
        }
        // A question kept for later (Shortcuts, examples) lands in the composer.
        .onChange(of: app.drafts.goal, initial: true) { _, goal in
            guard !goal.isEmpty else { return }
            agentDraft = goal
            app.drafts.goal = ""
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10 + (isKeyboardVisible ? 0 : bottomInset))
        .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: showsFooterStatusLine)
        .dcStickyFooter()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("askBox")
    }

    private func sendAgentPrompt() {
        let prompt = agentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !browserAgent.isRunning else { return }
        guard app.isProviderReady(for: .browserAgent) else {
            requestedProviderSetup = true
            composerFocused = false
            return
        }
        requestedProviderSetup = false
        DCHaptics.tap()
        agentDraft = ""
        composerFocused = false
        if app.router.drawerPhase == .shown,
           app.router.drawerDetent == .large,
           !dynamicTypeSize.isAccessibilitySize {
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) {
                app.router.drawerDetent = .medium
            }
        }
        browserAgent.send(prompt)
    }

    // MARK: Summary & Unified Transcript

    private var streamedSummary: String? {
        guard let activeSummary,
              let streamed = streams.texts[activeSummary.id],
              !streamed.isEmpty else { return nil }
        return streamed
    }

    private var visibleSummary: String {
        activeSummary != nil ? (streamedSummary ?? "") : (app.currentSession?.summary ?? "")
    }

    private var drawerThread: some View {
        let streamInput = streamedSummary.map {
            DrawerSummarySections.Input(text: $0, maximumPost: app.currentSession?.totalPosts)
        }
        let parsed: (sections: Int, hasCitations: Bool, rows: [MarkdownRow]) = if streamInput != nil,
            let renderedSummary,
            !renderedSummary.output.rows.isEmpty {
            renderedSummary.output
        } else if visibleSummary.isEmpty {
            (0, false, [])
        } else {
            DrawerSummarySections.parsed(
                for: .init(text: visibleSummary, maximumPost: app.currentSession?.totalPosts)
            )
        }
        let hasSummarySection = !parsed.rows.isEmpty || activeSummary != nil || activePull != nil || isSummaryFailed
        let hasLeadingContent = providerSetupRole != nil
            || hasSummarySection
            || app.currentTopic != nil
            || (app.assistantPageState == .loading && browserAgent.runs.isEmpty && (app.currentSession?.history.isEmpty ?? true))
        let isLazy = parsed.hasCitations
            || parsed.rows.count >= MarkdownView.lazyRowThreshold
        return ChatThread(
            app: app,
            topicKey: app.currentTopic?.topicKey ?? "",
            activeChat: activeChat,
            isLazy: isLazy,
            hasLeadingContent: hasLeadingContent,
            expandedToolRowIDs: $expandedToolRowIDs,
            onOpenURL: openInBrowser
        ) {
            drawerSummary(rows: parsed.rows, hasSummarySection: hasSummarySection)
        }
        .animation(DCMotion.respecting(reduceMotion), value: activeSummary?.id)
        .animation(DCMotion.respecting(reduceMotion), value: activePull?.id)
        .animation(DCMotion.respecting(reduceMotion), value: summaryRun)
        .animation(.easeOut(duration: 0.25), value: parsed.sections)
        .task(id: streamInput) {
            guard let streamInput else {
                renderedSummary = nil
                return
            }
            if let updated = await ThrottledParse.refreshed(
                from: renderedSummary,
                to: streamInput,
                parse: DrawerSummarySections.parsed
            ) {
                renderedSummary = updated
            }
        }
        .onChange(of: app.currentSession?.hasSummary == true, initial: true) {
            // Once, with the first summary that has post numbers.
            let key = PresentationRouter.citationTipKey
            guard app.currentSession?.hasSummary == true, !UserDefaults.standard.bool(forKey: key),
                  !PostCitations.numbers(in: app.currentSession?.summary ?? "").isEmpty else { return }
            UserDefaults.standard.set(true, forKey: key)
            showsCitationTip = true
        }
    }

    @ViewBuilder
    private func drawerSummary(rows: [MarkdownRow], hasSummarySection: Bool) -> some View {
        if let setupRole = providerSetupRole, app.assistantPageState != .loading {
            ProviderSetupCard(app: app, role: setupRole)
                .padding(.top, 4)
        }
        if app.assistantPageState == .loading, !hasSummarySection, browserAgent.runs.isEmpty {
            AssistantLoadingState()
                .padding(.top, 4)
        }
        if let record = activePull {
            WorkProgressCard(record: record, progress: app.progress) { app.cancel(record: record) }
                .padding(.top, 4)
                .transition(.opacity)
        }
        if let record = activeSummary {
            WorkProgressCard(record: record, progress: app.progress) { app.cancel(record: record) }
                .padding(.top, 4)
                .transition(.opacity)
        }
        if case .failed(let message) = summaryRun {
            SummaryFailedCard(message: message, canRetry: activePull == nil) {
                app.startSummary(regenerate: true)
            }
            .padding(.top, 4)
            .transition(.opacity)
        }
        if rows.isEmpty {
            if activeSummary != nil {
                SummaryPlaceholder()
                    .padding(.top, 4)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            } else if activePull == nil, !isSummaryFailed, app.assistantPageState != .loading, app.currentTopic != nil {
                // Until the suggestion row (task 2b) lands, the empty forum panel keeps its way to a summary.
                VStack(spacing: 0) {
                    DCMascotView(pose: .wave, size: 128)
                        .padding(.vertical, 32)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Agent ready", comment: "Empty Agent panel accessibility label"))
                        .accessibilityIdentifier("agentEmptyState")
                    summarizeControl(prominent: true)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            if activeSummary == nil, let session = app.currentSession {
                drawerSummaryMeta(session)
                    .padding(.top, 4)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
                if session.hasStaleSummary {
                    DrawerStaleBanner(session: session) { app.startSummary() }
                        .disabled(activeSummary != nil || activePull != nil)
                        .padding(.top, 4)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
            DCResultCard(label: String(localized: "Summary", comment: "Summary result card header"), systemImage: "doc.text") {
                EmptyView()
            } content: {
                DrawerSummarySections(
                    rows: rows,
                    layout: app.router.usesWideDrawerSummary && app.router.drawerDetent == .medium
                        ? .twoColumns
                        : .singleColumn
                )
                .accessibilityIdentifier("summaryContent")
            }
            .transition(.identity)
            if activeSummary == nil {
                if showsCitationTip {
                    citationTip
                        .padding(.top, 4)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
                summarizeControl(prominent: false)
                    .padding(.top, 4)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
    }

    /// Meta chips: model, post count, age, Kept.
    @ViewBuilder
    private func summaryMeta(_ session: TopicSession) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                if !session.model.isEmpty {
                    Text(verbatim: AppleIntelligenceBackend.displayModel(session.model))
                }
                let count = session.summaryPostCount ?? session.totalPosts
                let details = [
                    count.flatMap { $0 > 0 ? String(localized: "\($0) posts") : nil },
                    session.summaryUpdatedAt.map { $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) },
                    session.kept ? String(localized: "Kept") : nil
                ].compactMap { $0 }
                Text(verbatim: details.joined(separator: " · "))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            summaryMetaRow(session)
                .minimumScaleFactor(0.85)
                .accessibilityElement(children: .combine)
        }
    }

    private func summaryMetaRow(_ session: TopicSession) -> some View {
        HStack(spacing: 5) {
            if !session.model.isEmpty {
                DCPill(text: AppleIntelligenceBackend.displayModel(session.model), systemImage: "cpu", tint: .secondary)
                    .truncationMode(.middle)
            }
            if let count = session.summaryPostCount ?? session.totalPosts, count > 0 {
                DCPill(text: String(localized: "\(count) posts"), systemImage: "text.bubble", tint: DCTheme.summaryTint)
                    .layoutPriority(1)
            }
            if let date = session.summaryUpdatedAt {
                DCPill(
                    // Abbreviated ("6 min. ago") so the row fits a phone card.
                    text: date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)),
                    systemImage: "clock",
                    tint: .secondary
                )
                .layoutPriority(1)
            }
            if session.kept {
                DCPill(
                    text: String(localized: "Kept", comment: "Badge: the user chose to keep this summary (not cleared automatically)"),
                    systemImage: "pin.fill",
                    tint: DCTheme.warning
                )
                .layoutPriority(1)
            }
        }
    }

    /// Model, post count, age, Kept; then the AI label, Translate, Read aloud, Retry, and summary `⋯`.
    private func drawerSummaryMeta(_ session: TopicSession) -> some View {
        let strippedText = PostCitations.stripped(session.summary)
        return VStack(alignment: .leading, spacing: 6) {
            if !dynamicTypeSize.isAccessibilitySize { summaryMeta(session) }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: 6))
            layout {
                if dynamicTypeSize.isAccessibilitySize {
                    DisclosureGroup {
                        summaryMeta(session)
                    } label: {
                        summaryNotice
                    }
                    .accessibilityIdentifier("summaryDetails")
                } else {
                    summaryNotice
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                HStack(spacing: 2) {
                    if session.hasSummary {
                        TranslateButton(app: app, title: session.title, text: strippedText, compact: true)
                            .buttonStyle(DCIconButtonStyle())
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        ReadAloudButton(podcast: app.podcast, id: "summary-\(session.topicKey)", title: session.title, text: strippedText, compact: true)
                            .buttonStyle(DCIconButtonStyle())
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    Button {
                        DCHaptics.tap()
                        app.startSummary(regenerate: true)
                    } label: {
                        Text("Retry", comment: "Button: writes the AI summary again")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 4)
                            .frame(minHeight: DCTheme.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(activeSummary != nil || activePull != nil)
                    .accessibilityHint(Text("Writes the summary again", comment: "Accessibility hint of the summary's Retry button"))
                    .accessibilityIdentifier("retrySummary")

                    summaryMoreMenu
                }
            }
        }
    }

    /// Summary-specific actions moved out of the panel header (`design-unified.md` §1).
    private var summaryMoreMenu: some View {
        Menu {
            Section {
                Button {
                    UIPasteboard.general.string = exportText
                    DCHaptics.success()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("copyExport")
                .disabled(exportDisabled)

                ShareLink(item: exportText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("shareExport")
                .disabled(exportDisabled)

                Button {
                    exporting = true
                } label: {
                    Label("Export .txt", systemImage: "arrow.down.doc")
                }
                .accessibilityIdentifier("exportExport")
                .disabled(exportDisabled)

                Button {
                    app.router.item = .exportOptions
                } label: {
                    Label("Export Options…", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("exportOptions")
            }

            Section {
                Button {
                    onExpand(.post)
                } label: {
                    Label("Post & Responses", systemImage: "text.bubble")
                }
                .accessibilityIdentifier("viewPost")
                .disabled((app.currentSession?.source ?? "").isEmpty)

                Button {
                    app.pullTopic()
                } label: {
                    Label("Pull Post + Replies Only", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("pullPost")
                .disabled(app.currentTopic == nil || activeSummary != nil || activePull != nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, minHeight: DCTheme.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Summary actions", comment: "Accessibility label of the summary card's more menu"))
        .accessibilityIdentifier("summaryMoreMenu")
    }

    private var summaryNotice: some View {
        Label {
            Text("AI-generated, may be wrong", comment: "Label under an AI summary in the AI drawer")
        } icon: {
            Image(systemName: "sparkles")
        }
        .font(.caption)
        .foregroundStyle(Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("aiGeneratedLabel")
    }

    private var citationTip: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(DCTheme.warning)
                .accessibilityHidden(true)
            Text("Tap a post number to jump to it", comment: "First-run tip under the first AI summary with post citations")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(DCMotion.respecting(reduceMotion)) { showsCitationTip = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .background(DCTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("citationTip")
    }

    /// Tap summarizes with the default batch size; hold to pick a batch size for
    /// this run or to pull the post without summarizing.
    @ViewBuilder
    private func summarizeControl(prominent: Bool) -> some View {
        let menu = Menu {
            Section("Context per batch") {
                ForEach(SummaryBatchLimit.presets, id: \.self) { limit in
                    Button {
                        app.startSummary(batchLimit: limit, regenerate: app.currentSession?.hasSummary == true)
                    } label: {
                        if limit == app.settings.summaryBatchLimit {
                            Label(SummaryBatchLimit.label(limit), systemImage: "checkmark")
                        } else {
                            Text(SummaryBatchLimit.label(limit))
                        }
                    }
                }
            }
            Button {
                app.pullTopic()
            } label: {
                Label("Pull post + replies only", systemImage: "arrow.down.circle")
            }
        } label: {
            Label(
                app.currentSession?.hasSummary == true ? "Check for new replies" : "Create summary",
                systemImage: app.currentSession?.hasSummary == true ? "arrow.triangle.2.circlepath" : "sparkles"
            )
            .frame(maxWidth: .infinity)
        } primaryAction: {
            DCHaptics.tap()
            app.startSummary()
        }
        .accessibilityIdentifier("createSummary")
        .disabled(app.currentTopic == nil || activeSummary != nil || activePull != nil)

        if prominent {
            menu.buttonStyle(DCPrimaryButtonStyle())
        } else {
            menu.buttonStyle(DCActionButtonStyle(prominent: false))
        }
    }
}

// MARK: - Unified Conversation ScrollView

/// Unified scrollable transcript hosting summary results, saved legacy messages,
/// embedded forum research runs, and `BrowserAgentSession` turns.
private struct ChatThread<Leading: View>: View {
    private struct HistoryCountKey: Equatable {
        let topicKey: String
        let count: Int
        let lastID: UUID?
    }

    @ObservedObject var app: AppModel
    @ObservedObject private var streams: StreamStore
    private var browserAgent: BrowserAgentSession { app.browserAgent }
    let topicKey: String
    let activeChat: WorkRecord?
    let isLazy: Bool
    let hasLeadingContent: Bool
    @Binding var expandedToolRowIDs: Set<UUID>
    let onOpenURL: (URL) -> Void
    /// The summary above the conversation, scrolled from the top.
    let leading: Leading
    @State private var atBottom = true
    @State private var userScrolling = false
    @State private var scrollTask: Task<Void, Never>?
    @State private var metricsBox = ScrollMetricsBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        app: AppModel,
        topicKey: String,
        activeChat: WorkRecord?,
        isLazy: Bool,
        hasLeadingContent: Bool,
        expandedToolRowIDs: Binding<Set<UUID>>,
        onOpenURL: @escaping (URL) -> Void,
        @ViewBuilder leading: () -> Leading
    ) {
        self.app = app
        _streams = ObservedObject(wrappedValue: app.streams)
        self.topicKey = topicKey
        self.activeChat = activeChat
        self.isLazy = isLazy
        self.hasLeadingContent = hasLeadingContent
        _expandedToolRowIDs = expandedToolRowIDs
        self.onOpenURL = onOpenURL
        self.leading = leading()
    }

    private var stream: String {
        guard let activeChat else { return "" }
        return streams.text(for: activeChat.id) ?? ""
    }

    private var history: [ChatMessage] {
        app.currentSession?.history ?? []
    }

    private var showsEmbeddedForumRun: Bool {
        app.assistantMode == .agent && app.selectedAgentRun != nil
    }

    private var hasConversationEntries: Bool {
        !history.isEmpty || activeChat != nil || !browserAgent.runs.isEmpty
    }

    private var isCompletelyEmpty: Bool {
        !hasLeadingContent && !hasConversationEntries && !showsEmbeddedForumRun
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id("chatTop")

                        VStack(alignment: .leading, spacing: 12) {
                            if hasLeadingContent {
                                if isLazy {
                                    LazyVStack(alignment: .leading, spacing: 8) {
                                        leading
                                    }
                                    .transition(.identity)
                                } else {
                                    VStack(alignment: .leading, spacing: 8) {
                                        leading
                                    }
                                    .transition(.identity)
                                }
                            }

                            if !history.isEmpty || activeChat != nil {
                                VStack(alignment: .leading, spacing: 8) {
                                    conversationRows
                                }
                                .transition(.identity)
                            }

                            if showsEmbeddedForumRun {
                                AgentView(
                                    app: app,
                                    showsProviderCard: false,
                                    embeddedInTranscript: true,
                                    onOpenTopic: onOpenURL
                                )
                                .transition(.identity)
                            }

                            if !browserAgent.runs.isEmpty {
                                BrowserAgentRunsView(
                                    app: app,
                                    session: browserAgent,
                                    expandedToolRowIDs: $expandedToolRowIDs
                                )
                                .transition(.identity)
                            }

                            if isCompletelyEmpty {
                                VStack(spacing: 0) {
                                    DCMascotView(pose: .wave, size: 128)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text("Agent ready", comment: "Empty Agent panel accessibility label"))
                                .accessibilityIdentifier("agentEmptyState")
                            }
                        }
                        .padding(.top, 10)
                        .padding(.horizontal, 14)

                        Color.clear
                            .frame(height: 1)
                            .padding(.top, 12)
                            .padding(.bottom, 14)
                            .id("chatBottom")
                            .onAppear { if #unavailable(iOS 18.0) { atBottom = true } }
                            .onDisappear { if #unavailable(iOS 18.0) { atBottom = false } }
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: Int.self) { Int($0.size.height.rounded()) } action: { newHeight in
                        let grew = metricsBox.contentHeight > 0 && newHeight > metricsBox.contentHeight
                        metricsBox.contentHeight = newHeight
                        if grew, atBottom, !userScrolling, !metricsBox.scrolledUp, (activeChat != nil || browserAgent.isRunning) {
                            scrollUnanimated(proxy: proxy)
                            DispatchQueue.main.async {
                                if atBottom, !userScrolling, !metricsBox.scrolledUp { scrollUnanimated(proxy: proxy) }
                            }
                        }
                    }
                    .animation(DCMotion.respecting(reduceMotion), value: history.count)
                    .animation(DCMotion.respecting(reduceMotion), value: activeChat?.id)
                    .animation(DCMotion.respecting(reduceMotion), value: browserAgent.runs.count)
                }
                .defaultScrollAnchor(.top)
                .modifier(ChatScrollTracker(onPhaseChange: { scrolling in
                    userScrolling = scrolling
                    if scrolling {
                        metricsBox.pinningBottom = false
                        scrollTask?.cancel()
                        scrollTask = nil
                    }
                }, onStateChange: { old, new in
                    let movedUp = scrollTask == nil
                        && old.contentHeight > 0
                        && new.viewportHeight == old.viewportHeight
                        && new.contentHeight >= old.contentHeight
                        && new.offsetTenths < old.offsetTenths - 3
                    if movedUp {
                        metricsBox.scrolledUp = true
                    } else if new.offsetTenths > old.offsetTenths + 3 && !metricsBox.pinningBottom {
                        metricsBox.scrolledUp = false
                    }
                    metricsBox.nearBottom = new.nearBottom
                    if new.nearBottom {
                        metricsBox.pinningBottom = false
                        if !atBottom,
                           scrollTask != nil
                            || new.offsetTenths > old.offsetTenths + 3
                            || new.viewportHeight > old.viewportHeight
                            || new.contentHeight <= new.viewportHeight
                        {
                            atBottom = true
                            metricsBox.scrolledUp = false
                        }
                    } else if atBottom, scrollTask == nil {
                        let viewportShrank = !userScrolling
                            && old.viewportHeight > 0
                            && new.viewportHeight < old.viewportHeight
                            && new.offsetTenths >= old.offsetTenths - 3
                        let streamGrew = !userScrolling
                            && !metricsBox.scrolledUp
                            && old.contentHeight > 0
                            && (activeChat != nil || browserAgent.isRunning)
                            && new.contentHeight > old.contentHeight
                            && new.offsetTenths >= old.offsetTenths - 3
                        if viewportShrank || streamGrew {
                            metricsBox.pinningBottom = true
                            metricsBox.scrolledUp = false
                            scrollUnanimated(proxy: proxy)
                            DispatchQueue.main.async {
                                metricsBox.pinningBottom = false
                                if atBottom, !userScrolling, !metricsBox.scrolledUp { scrollUnanimated(proxy: proxy) }
                            }
                        } else if !metricsBox.pinningBottom {
                            atBottom = false
                        }
                    }
                }))
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("agentScroll")
                .onAppear {
                    #if DEBUG
                    if AssistantDebug.has("-dc-browser-agent-expand-first-tool"),
                       expandedToolRowIDs.isEmpty,
                       let first = browserAgent.toolCalls.first {
                        expandedToolRowIDs.insert(first.id)
                    }
                    #endif
                }
                .onChange(of: topicKey) {
                    guard browserAgent.runs.isEmpty else { return }
                    scrollTask?.cancel()
                    scrollTask = nil
                    userScrolling = false
                    metricsBox.contentHeight = 0
                    metricsBox.scrolledUp = false
                    atBottom = false
                    scrollUnanimated("chatTop", anchor: .top, proxy: proxy)
                    Task { @MainActor in
                        if atBottom != metricsBox.nearBottom { atBottom = metricsBox.nearBottom }
                    }
                }
                .onChange(of: HistoryCountKey(topicKey: topicKey, count: history.count, lastID: history.last?.id)) { old, new in
                    guard old.topicKey == new.topicKey else { return }
                    if new.lastID != old.lastID, history.last?.role == .user {
                        jumpToBottom(proxy: proxy)
                    } else if new.count > old.count, atBottom, !userScrolling {
                        metricsBox.scrolledUp = false
                        scrollUnanimated(proxy: proxy)
                    }
                }
                .onChange(of: stream) {
                    // Follow the answer only while the reader is at the bottom.
                    if atBottom, !userScrolling {
                        metricsBox.scrolledUp = false
                        scrollUnanimated(proxy: proxy)
                    }
                }
                .onChange(of: browserAgent.runs.count) { oldCount, newCount in
                    if newCount > oldCount {
                        jumpToBottom(proxy: proxy)
                    }
                }
                .onChange(of: browserAgent.toolCalls.count) { _, _ in
                    #if DEBUG
                    if AssistantDebug.has("-dc-browser-agent-expand-first-tool"),
                       expandedToolRowIDs.isEmpty,
                       let first = browserAgent.toolCalls.first {
                        expandedToolRowIDs.insert(first.id)
                    }
                    #endif
                    if atBottom, !userScrolling { scrollUnanimated(proxy: proxy) }
                }
                .onChange(of: browserAgent.runState) { _, newState in
                    if atBottom, !userScrolling { scrollUnanimated(proxy: proxy) }
                    announceAgentStateIfNeeded(newState)
                }
                .onDisappear {
                    scrollTask?.cancel()
                    scrollTask = nil
                }
                if !atBottom, hasConversationEntries {
                    Button {
                        jumpToBottom(proxy: proxy)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(DCTheme.goldInk)
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                            .overlay { Circle().stroke(DCTheme.border) }
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                    .accessibilityLabel("Scroll to latest message")
                    .accessibilityIdentifier("chatScrollToBottom")
                }
            }
            .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: !atBottom && hasConversationEntries)
        }
    }

    private func announceAgentStateIfNeeded(_ state: BrowserAgentRunState) {
        switch state {
        case .failed(let message):
            UIAccessibility.post(notification: .announcement, argument: message)
        case .stepLimitReached(let limit):
            UIAccessibility.post(
                notification: .announcement,
                argument: String(
                    localized: "Stopped after \(limit) steps",
                    comment: "Browser agent step limit card title; placeholder is the step limit integer"
                )
            )
        default:
            break
        }
    }

    private func scrollUnanimated(_ id: String = "chatBottom", anchor: UnitPoint = .bottom, proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(id, anchor: anchor) }
    }

    private func jumpToBottom(proxy: ScrollViewProxy) {
        scrollTask?.cancel()
        metricsBox.scrolledUp = false
        atBottom = true
        scrollTask = Task { @MainActor in
            await settleScroll(reduceMotion: reduceMotion, shouldStop: { userScrolling }) {
                proxy.scrollTo("chatBottom", anchor: .bottom)
            }
            for _ in 0..<24 where !metricsBox.nearBottom && !userScrolling && !Task.isCancelled {
                scrollUnanimated(proxy: proxy)
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }
            scrollTask = nil
            if atBottom != metricsBox.nearBottom { atBottom = metricsBox.nearBottom }
        }
    }

    @ViewBuilder
    private var conversationRows: some View {
        if !history.isEmpty || activeChat != nil {
            conversationHeader
        }

        ForEach(history) { message in
            ChatBubble(message: message, maximumPost: app.currentSession?.totalPosts, onEdit: nil)
                .padding(.top, 4)
                .transition(.asymmetric(
                    insertion: reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity
                ))
        }

        if !stream.isEmpty {
            ChatBubble(
                message: ChatMessage(role: .assistant, content: stream),
                maximumPost: app.currentSession?.totalPosts,
                onEdit: nil,
                isStreaming: true
            )
            .padding(.top, 4)
            .id("chatStream")
        } else if activeChat != nil {
            typingBubble
                .padding(.top, 4)
        }

        if let activeChat {
            chatStatus(activeChat)
                .padding(.top, 4)
        }
    }

    /// "Conversation" between the drawer's summary and saved legacy messages.
    private var conversationHeader: some View {
        HStack {
            Text("Conversation", comment: "AI drawer: heading above the chat messages about the topic")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.top, 12)
    }

    private var typingBubble: some View {
        HStack {
            TypingIndicator(tint: DCTheme.chatTint)
                .padding(.vertical, 8)
            Spacer(minLength: 34)
        }
        .transition(.opacity)
    }

    private func chatStatus(_ record: WorkRecord) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(record.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Stop", role: .destructive) {
                app.cancel(record: record)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            .accessibilityIdentifier("cancelChat")
        }
        .padding(.horizontal, 4)
    }
}

/// Per-topic instructions plus the chat context budget.
struct InstructionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var app: AppModel
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 140)
                        .accessibilityIdentifier("topicInstructions")
                } header: {
                    Text("Instructions for this topic")
                } footer: {
                    Text(
                        app.settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Used for this topic's summary and chat. Leave blank to use the built-in structured summary prompt (in the discussion's language)."
                            : "Used for this topic's summary and chat. Leave blank to use the custom instructions from Settings."
                    )
                }

                Section {
                    ContextLimitControl(app: app)
                } header: {
                    Text("Chat context")
                } footer: {
                    Text("How much of the pulled discussion each chat answer can read.")
                }
            }
            .navigationTitle("Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let topicKey = app.currentTopic?.topicKey {
                            app.setInstructions(draft, topicKey: topicKey)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                draft = app.currentSession?.instructions ?? ""
            }
        }
        .presentationDetents([.medium, .large])
        .dcFormSheet()
    }
}

private struct ContextLimitControl: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Forum context", systemImage: "text.append")
                Spacer()
                Text(formattedLimit)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            Slider(
                value: Binding(
                    get: { Double(app.settings.forumContextLimit) },
                    set: { app.settings.forumContextLimit = Int($0) }
                ),
                in: 5_000...1_000_000,
                step: 5_000
            )
            .onChange(of: app.settings.forumContextLimit) {
                app.saveSettings()
            }
            .accessibilityLabel("Forum context size")
            .accessibilityValue(formattedLimit)
        }
    }

    private var formattedLimit: String {
        app.settings.forumContextLimit >= 1_000_000
            ? String(localized: "1M characters", comment: "Chat context size: one million characters")
            : String(localized: "\(app.settings.forumContextLimit / 1_000)k characters", comment: "Chat context size in thousands of characters, e.g. 60k characters")
    }
}

// MARK: - Export

struct ExportOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let payload: TopicExportPayload
    @Binding var options: ExportOptions

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Exclude Title and URL", isOn: $options.excludeTitleAndURL)
                        .disabled(!payload.hasTitleAndURL)
                        .accessibilityIdentifier("excludeTitleURL")
                    Toggle("Exclude Summary", isOn: $options.excludeSummary)
                        .disabled(!payload.hasSummary)
                        .accessibilityIdentifier("excludeSummary")
                    Toggle("Exclude Post & responses", isOn: $options.excludePostAndResponses)
                        .disabled(!payload.hasSource)
                        .accessibilityIdentifier("excludePostResponses")
                    Toggle("Exclude Chat history", isOn: $options.excludeChatHistory)
                        .disabled(!payload.hasChatHistory)
                        .accessibilityIdentifier("excludeChatHistory")
                } footer: {
                    Text("Copy, Share, and Export use the complete post and responses.")
                }
            }
            .navigationTitle("Export options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .presentationDetents([.medium])
        .dcFormSheet()
    }
}

// MARK: - Post preview

/// Full-screen view of the pulled post and responses (first and last 50 lines).
struct PostPreviewView: View {
    @ObservedObject var app: AppModel
    @State private var isExpanded = false

    var source: String {
        app.currentSession?.source ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if source.isEmpty {
                    ContentUnavailableView(
                        "Post not pulled",
                        systemImage: "text.bubble",
                        description: Text("Pull the post and responses to view a compact preview.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Label(
                            isExpanded ? "Hide preview" : "Show first and last 50 lines",
                            systemImage: isExpanded ? "chevron.down" : "chevron.right"
                        )
                        .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("postResponsesDisclosure")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                    if isExpanded {
                        Text(ForumPreview.compact(source))
                            .font(.body)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("pulledPostContent")
                    }

                    Text("Copy, Share, and Export use the complete post and responses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DCTheme.pageBackground)
    }
}

// MARK: - Full screen

struct ExpandedPanel: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var app: AppModel
    let route: ExpandedPanelRoute

    /// DEBUG: `-dc-panel-settings <page>` opens Settings on that sub-page.
    private static var debugInitialPage: SettingsPage? {
        #if DEBUG
        OnboardingDebug.value(after: "-dc-panel-settings").flatMap(SettingsPage.parse)
        #else
        nil
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                switch route {
                case .post:
                    PostPreviewView(app: app)
                case .history:
                    HistoryView(app: app)
                case .settings:
                    SettingsRootView(app: app, initialPage: Self.debugInitialPage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(route.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

private struct PlainTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// A failed summary run: what went wrong, and Retry (the same path as the
/// summary's own Retry). The card goes away as soon as a new run is queued,
/// so a second tap has nothing to land on.
private struct SummaryFailedCard: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("The summary didn’t finish", comment: "Drawer: a summary run failed; the reason follows")
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DCTheme.warning)
            }
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("summaryFailureMessage")
            }
            Button {
                DCHaptics.tap()
                retry()
            } label: {
                Text("Retry", comment: "Button: writes the AI summary again")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: DCTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!canRetry)
            .accessibilityHint(Text("Writes the summary again", comment: "Accessibility hint of the summary's Retry button"))
            .accessibilityIdentifier("retryFailedSummary")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dcCard(tint: DCTheme.warning)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summaryFailedCard")
    }
}

struct WorkProgressCard: View {
    let record: WorkRecord
    @ObservedObject var progress: ProgressStore
    let cancel: () -> Void

    private var tint: Color {
        switch record.type {
        case .summary, .pull: DCTheme.summaryTint
        case .chat: DCTheme.chatTint
        case .agent: DCTheme.agentTint
        }
    }

    var body: some View {
        let fraction = progress.value(for: record.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(taskTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(record.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                        .animation(DCMotion.quick, value: record.statusText)
                }
                Spacer(minLength: 4)
                if showsPercent {
                    // The slot keeps its width while the value is unknown
                    // (queued), so the header never reflows.
                    ZStack(alignment: .trailing) {
                        Text(verbatim: "100%").hidden()
                        if let fraction {
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(tint)
                                .contentTransition(.numericText(countsDown: false))
                                .animation(DCMotion.quick, value: fraction)
                        }
                    }
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                Button("Cancel", role: .destructive, action: cancel)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
            }
            AssistantProgressBar(value: fraction, tint: tint)
        }
        .dcCard(tint: tint)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workProgressCard")
    }

    /// Chat's answer phase is indeterminate, so it shows no percentage.
    private var showsPercent: Bool { record.type != .chat }

    private var taskTitle: String {
        switch record.type {
        case .summary: String(localized: "Creating summary")
        case .pull: String(localized: "Pulling post + replies")
        case .chat: String(localized: "Answering")
        case .agent: String(localized: "Asking the forum")
        }
    }
}

/// A chat bubble with a tail-side corner.
struct ChatBubble: View {
    let message: ChatMessage
    var maximumPost: Int? = nil
    var onEdit: (() -> Void)? = nil
    var isStreaming = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom) {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if isUser {
                    Text(message.content)
                        .font(.body)
                        .foregroundStyle(DCTheme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let linked = DrawerSummarySections.link(message.content, maximum: maximumPost)
                    MarkdownView(linked, citations: linked.contains("](\(PostCitations.scheme):"))
                        .textSelection(.enabled)
                }
                if isUser, let onEdit {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                            .font(DCType.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous))
                            .foregroundStyle(DCTheme.goldInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit")
                }
                if isStreaming {
                    TypingIndicator(tint: DCTheme.chatTint)
                        .scaleEffect(0.8, anchor: .leading)
                }
            }
            .padding(.horizontal, isUser ? 14 : 0)
            .padding(.vertical, isUser ? 11 : 2)
            .background {
                if isUser { DCUserBubbleShape().fill(DCTheme.surfaceRaised) }
            }
            if !isUser { Spacer(minLength: 24) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isUser ? "You" : "Assistant")
        .accessibilityIdentifier("chatMessage-\(message.role.rawValue)")
    }
}

private final class ScrollMetricsBox {
    var nearBottom = true
    var contentHeight = 0
    var pinningBottom = false
    var scrolledUp = false
}

private struct ScrollState: Equatable {
    var nearBottom: Bool
    var contentHeight: Int
    var viewportHeight: Int
    var offsetTenths: Int
}

/// Tracks scroll phase and whether the bottom of `ChatThread` is in view
/// (iOS 18+; older systems use the bottom anchor's appear/disappear instead).
private struct ChatScrollTracker: ViewModifier {
    let onPhaseChange: (Bool) -> Void
    let onStateChange: (ScrollState, ScrollState) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    onPhaseChange(phase == .interacting || phase == .decelerating)
                }
                .onScrollGeometryChange(for: ScrollState.self) { geometry in
                    ScrollState(
                        nearBottom: geometry.contentSize.height - geometry.visibleRect.maxY < 48,
                        contentHeight: Int(geometry.contentSize.height.rounded()),
                        viewportHeight: Int(geometry.visibleRect.height.rounded()),
                        offsetTenths: Int((geometry.contentOffset.y * 10).rounded())
                    )
                } action: { old, new in
                    onStateChange(old, new)
                }
        } else {
            content
        }
    }
}

// MARK: - AI drawer parts

/// The drawer's optional 44 pt row under the grabber, only while something
/// runs: voice, research progress, "Answer ready", or the Today podcast; and
/// the result cards as a chip (the strip would be under the drawer).
struct DrawerStatusRow: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    @ObservedObject var router: PresentationRouter
    @ObservedObject var voice: VoiceController
    /// Over History or Settings: only voice.
    var voiceOnly = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var voiceStatusText: String? {
        if let session = voice.session, voice.isActive {
            return "\(VoiceSessionBar.stateText(session)) · \(DockText.clock(session.connectedSeconds))"
        }
        return voice.inactiveBarMessage
    }

    private var inAgentMode: Bool { app.assistantMode == .agent }

    private var research: WorkRecord? { app.activeResearch }
    private var readyAnswer: WorkRecord? { app.readyAnswer }

    var body: some View {
        VStack(spacing: 0) {
            if let session = voice.session, voice.isActive {
                DrawerVoiceStatus(session: session) {
                    voice.end()
                    voice.dismiss()
                }
            } else if let message = voice.inactiveBarMessage {
                DrawerVoiceInactiveStatus(
                    message: message,
                    isWarning: voice.inactiveBarIsWarning,
                    dismiss: voice.dismiss
                )
            } else if voiceOnly {
                EmptyView()
            } else if !inAgentMode, let research {
                DrawerResearchStatus(record: research, progress: app.progress) {
                    showAnswer(for: research)
                }
            } else if !inAgentMode, let readyAnswer {
                row(
                    systemImage: "checkmark.circle.fill",
                    text: String(localized: "Answer ready", comment: "AI drawer status row: an Ask the forum answer finished")
                ) {
                    showAnswer(for: readyAnswer)
                }
            } else if podcast.isPlayingEpisode, let episode = podcast.episode {
                DrawerPodcastStatus(player: podcast.player, episode: episode) {
                    app.router.item = .nowPlaying
                }
            }
            // The strip over the page is hidden while the AI view is up.
            if !voiceOnly, app.isAIViewShown, app.browseCursor.showsInDrawer {
                DrawerCardsChip(app: app, router: router)
            }
        }
        .onAppear {
            if inAgentMode, !voiceOnly { router.answersSeenAt = Date() }
        }
        .onChange(of: app.assistantMode) {
            if inAgentMode { router.answersSeenAt = Date() }
        }
    }

    private func showAnswer(for record: WorkRecord) {
        withAnimation(DCMotion.respecting(reduceMotion)) { app.showAnswer(for: record) }
    }

    private func row(systemImage: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DrawerStatusLabel(systemImage: systemImage, text: text, progress: nil)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drawerStatusRow")
    }
}

private struct DrawerResearchStatus: View {
    let record: WorkRecord
    @ObservedObject var progress: ProgressStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DrawerStatusLabel(
                systemImage: "magnifyingglass",
                text: record.statusText,
                progress: progress.value(for: record.id)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drawerStatusRow")
    }
}

/// The result cards while the drawer is up: "4 sources · 2/4" with ‹ ›,
/// the same jumps as the strip, which comes back when the drawer closes.
private struct DrawerCardsChip: View {
    @ObservedObject var app: AppModel
    @ObservedObject var router: PresentationRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var cursor: BrowseCursor { app.browseCursor }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(cursor.tint)
                .accessibilityHidden(true)
            Text(verbatim: cursor.chipLabel)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(cursor.tint)
                .lineLimit(1)
                .accessibilityIdentifier("drawerCardsLabel")
            Spacer(minLength: 0)
            Button {
                move { await app.previous() }
            } label: {
                Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(DCIconButtonStyle())
            .disabled(!cursor.hasPrevious)
            .accessibilityLabel(Text("Previous result", comment: "Result cards over the page: open the previous card"))
            .accessibilityIdentifier("drawerCardsPrevious")
            Button {
                move { await app.next() }
            } label: {
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(DCIconButtonStyle())
            .disabled(!cursor.hasNext)
            .accessibilityLabel(Text("Next result", comment: "Result cards over the page: open the next card"))
            .accessibilityIdentifier("drawerCardsNext")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 44)
        .padding(.top, 10)
        .sensoryFeedback(.selection, trigger: cursor.index)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawerCardsChip")
    }

    /// The page jumps to the card: a large drawer steps down so it shows.
    private func move(_ jump: @escaping @MainActor () async -> Void) {
        if router.drawerDetent == .large {
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) { router.drawerDetent = .medium }
        }
        Task { await jump() }
    }
}

private struct DrawerPodcastStatus: View {
    @ObservedObject var player: PodcastPlayer
    let episode: PodcastEpisode
    let action: () -> Void

    var body: some View {
        if player.isActive {
            let timeline = PodcastTimeline(durations: episode.entries.map { $0.isReady ? $0.duration : nil })
            Button(action: action) {
                DCListenRow(
                    title: episode.title,
                    detail: DockText.podcastLine(player: player, episode: episode),
                    progress: timeline.total > 0 ? timeline.elapsed(player.position) / timeline.total : 0,
                    isPlaying: true
                )
            }
            .buttonStyle(.plain)
            .nowPlayingZoomSource()
            .accessibilityIdentifier("drawerStatusRow")
        }
    }
}

/// Voice while the drawer is up (the Dock is under it): state, time, Mute,
/// End.
private struct DrawerVoiceStatus: View {
    @ObservedObject var session: VoiceSession
    let end: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            DrawerStatusLabel(
                systemImage: "waveform",
                text: "\(VoiceSessionBar.stateText(session)) · \(DockText.clock(session.connectedSeconds))",
                progress: nil,
                showsChevron: false
            )
            Button {
                DCHaptics.tap()
                session.setMuted(!session.isMuted)
            } label: {
                Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(session.isMuted ? DCTheme.danger : .primary)
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel(session.isMuted ? Text("Unmute") : Text("Mute"))
            .accessibilityIdentifier("drawerVoiceMute")
            .padding(.top, 10)
            Button(action: end) {
                Image(systemName: "phone.down.fill")
                    .foregroundStyle(DCTheme.onCinnabar)
                    .frame(width: 34, height: 34)
                    .background(DCTheme.cinnabar, in: Circle())
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel(Text("End voice"))
            .accessibilityIdentifier("drawerVoiceEnd")
            .padding(.trailing, 12)
            .padding(.top, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawerStatusRow")
    }
}

/// Voice failure or ended status while the drawer or split panel is up.
private struct DrawerVoiceInactiveStatus: View {
    let message: String
    let isWarning: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DCTheme.spacingS) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "waveform")
                .foregroundStyle(isWarning ? DCTheme.warning : .secondary)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("voiceBarState")
            Spacer(minLength: 0)
            VoiceBarCloseButton(action: dismiss)
        }
        .padding(.leading, 16)
        .padding(.vertical, 6)
        .padding(.top, 6)
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawerStatusRow")
    }
}

private struct DrawerStatusLabel: View {
    let systemImage: String
    let text: String
    let progress: Double?
    var showsChevron = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(DCTheme.goldInk)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let progress {
                ProgressView(value: progress)
                    .frame(width: 44)
                    .tint(DCTheme.goldInk)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .padding(.top, 10)
        .contentShape(Rectangle())
    }
}

/// While the summary is written and no text has come yet: three lines that
/// pulse (static with Reduce Motion).
private struct SummaryPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([1.0, 0.92, 0.6], id: \.self) { width in
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: proxy.size.width * width)
                }
                .frame(height: 12)
            }
        }
        .modifier(PulseModifier(active: !reduceMotion))
        .accessibilityElement()
        .accessibilityLabel(Text("Writing summary…"))
        .accessibilityIdentifier("summaryPlaceholder")
    }
}

private struct PulseModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([0.45, 1.0]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.6) }
        } else {
            content
        }
    }
}

/// The summary's sections (split at its `#`/`##` headings) with `#N`
/// citations as chips. While it streams, each new section fades in and
/// rises 8 pt (only fades with Reduce Motion), never per character.
struct DrawerSummarySections: View {
    enum LayoutMode: Equatable {
        case automatic
        case singleColumn
        case twoColumns
    }

    let rows: [MarkdownRow]
    var layout: LayoutMode = .automatic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    struct Input: Equatable {
        let text: String
        let maximumPost: Int?
    }

    private static let linkedCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        return cache
    }()

    static func link(_ text: String, maximum: Int?) -> String {
        let key = ("\(maximum ?? -1)|" + text) as NSString
        if let cached = linkedCache.object(forKey: key) {
            return cached as String
        }
        let value = PostCitations.linked(text, maximum: maximum)
        linkedCache.setObject(value as NSString, forKey: key)
        return value
    }

    static func parsed(for input: Input) -> (sections: Int, hasCitations: Bool, rows: [MarkdownRow]) {
        let marker = "](\(PostCitations.scheme):"
        var hasCitations = false
        let linked = sections(of: input.text).map { section -> String in
            let value = link(section, maximum: input.maximumPost)
            if !hasCitations, value.contains(marker) { hasCitations = true }
            return value
        }
        return (linked.count, hasCitations, MarkdownRow.rows(fromSections: linked, initialTopSpacing: 4, stackSpacing: 8))
    }

    var body: some View {
        switch layout {
        case .singleColumn:
            rowList(rows)
        case .twoColumns, .automatic:
            let columns = Self.columnRows(from: rows)
            if let right = columns.right {
                SummaryTwoColumnLayout(
                    minimumWidth: layout == .twoColumns ? 0 : WorkspaceMetrics.twoColumnSummaryMinimumWidth
                ) {
                    VStack(alignment: .leading, spacing: 8) { rowList(columns.left) }
                    VStack(alignment: .leading, spacing: 8) { rowList(right) }
                }
                .textSelection(.enabled)
            } else {
                rowList(rows)
            }
        }
    }

    @ViewBuilder
    private func rowList(_ items: [MarkdownRow]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, row in
            MarkdownBlockView(row: row, citations: true)
                .equatable()
                .transition(.asymmetric(
                    insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)),
                    removal: .identity
                ))
        }
        .textSelection(.enabled)
    }

    private static func columnRows(from rows: [MarkdownRow]) -> (left: [MarkdownRow], right: [MarkdownRow]?) {
        var groups: [[MarkdownRow]] = []
        for row in rows {
            if case .heading(let level, _) = row.content, level <= 2, !groups.isEmpty {
                groups.append([row])
            } else if groups.isEmpty {
                groups.append([row])
            } else {
                groups[groups.count - 1].append(row)
            }
        }
        guard groups.count >= 2 else { return (rows, nil) }
        let split = (groups.count + 1) / 2
        let left = Array(groups[..<split].joined())
        var right = Array(groups[split...].joined())
        if !right.isEmpty { right[0].topSpacing = 4 }
        return (left, right)
    }

    /// Splits before each level-1/2 heading outside code fences.
    static func sections(of markdown: String) -> [String] {
        var sections: [[String]] = [[]]
        var inFence = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            let isHeading = !inFence && (trimmed.hasPrefix("# ") || trimmed.hasPrefix("## "))
            if isHeading, sections[sections.count - 1].contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                sections.append([])
            }
            sections[sections.count - 1].append(line)
        }
        return sections.map { $0.joined(separator: "\n") }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private struct SummaryTwoColumnLayout: Layout {
    let minimumWidth: CGFloat
    var horizontalSpacing: CGFloat = 20
    var verticalFallbackSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        if let width = proposal.width, width.isFinite, width >= minimumWidth {
            let colWidth = max(0, (width - horizontalSpacing) / 2)
            let left = subviews[0].sizeThatFits(.init(width: colWidth, height: proposal.height))
            let right = subviews[1].sizeThatFits(.init(width: colWidth, height: proposal.height))
            return CGSize(width: width, height: max(left.height, right.height))
        }
        let left = subviews[0].sizeThatFits(proposal)
        let right = subviews[1].sizeThatFits(proposal)
        return CGSize(width: max(left.width, right.width), height: left.height + verticalFallbackSpacing + right.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if bounds.width >= minimumWidth {
            let colWidth = max(0, (bounds.width - horizontalSpacing) / 2)
            let colProposal = ProposedViewSize(width: colWidth, height: nil)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: colProposal)
            subviews[1].place(at: CGPoint(x: bounds.minX + colWidth + horizontalSpacing, y: bounds.minY), anchor: .topLeading, proposal: colProposal)
        } else {
            let rowProposal = ProposedViewSize(width: bounds.width, height: nil)
            let left = subviews[0].sizeThatFits(rowProposal)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: rowProposal)
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + left.height + verticalFallbackSpacing), anchor: .topLeading, proposal: rowProposal)
        }
    }
}

/// "12 newer replies · Check for new replies" (totalPosts − summaryPostCount).
private struct DrawerStaleBanner: View {
    let session: TopicSession
    let onCheck: () -> Void

    private var newReplies: Int? {
        guard let total = session.totalPosts, let summarized = session.summaryPostCount, total > summarized else { return nil }
        return total - summarized
    }

    var body: some View {
        Button(action: onCheck) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .accessibilityHidden(true)
                Group {
                    if let newReplies {
                        Text("\(newReplies) newer replies · Check for new replies", comment: "AI drawer banner over a stale summary; the placeholder is the number of replies since it was written")
                    } else {
                        Text("Newer replies · Check for new replies", comment: "AI drawer banner over a stale summary when the number of new replies is unknown")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DCTheme.newRepliesBadgeText)
            .padding(.horizontal, 12)
            .frame(minHeight: DCTheme.controlHeight)
            .background(DCTheme.newRepliesBadgeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("staleSummaryNotice")
    }
}
