import Combine
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

@MainActor
final class PageScriptMatchesCache {
    struct Summary: Equatable {
        var allCount = 0; var activeCount = 0; var errorCount = 0; var isGlobalEnabled = true
    }
    private var hasURL = false, lastURL: URL?, lastScripts: [UserScript]?
    private var matched: [UserScript] = [], enabled: [UserScript] = []
    private var lastGlobal: Bool?, lastErrors: [String: ScriptRuntimeError]?, cached = Summary()

    private func refresh(url: URL?, scripts: [UserScript], store: ScriptStore) -> Bool {
        guard !hasURL || url != lastURL || scripts != lastScripts else { return false }
        hasURL = true; lastURL = url; lastScripts = scripts
        matched = url.map { u in PerfProbe.time("AssistantPanel.matchingPageScripts") { store.sortedMatchingScripts(for: u, includeDisabled: true) } } ?? []
        enabled = matched.filter(\.isEnabled)
        return true
    }

    func summary(for url: URL?, in store: ScriptStore) -> Summary {
        let scripts = store.scripts, isGlobal = store.isGlobalEnabled, errors = store.scriptErrors
        let changed = refresh(url: url, scripts: scripts, store: store)
        if changed || isGlobal != lastGlobal || errors != lastErrors {
            lastGlobal = isGlobal; lastErrors = errors
            let errs = isGlobal ? enabled.filter { errors[$0.id] != nil }.count : 0
            cached = Summary(allCount: matched.count, activeCount: enabled.count, errorCount: errs, isGlobalEnabled: isGlobal)
        }
        return cached
    }

    func enabledScripts(for url: URL?, in store: ScriptStore) -> [UserScript] {
        _ = refresh(url: url, scripts: store.scripts, store: store)
        return store.isGlobalEnabled ? enabled : []
    }
}

@MainActor
private enum DrawerInputs {
    static let unusedAI = AppleIntelligenceStatus.unavailable(.deviceNotEligible)

    static func browserAgentReadiness(_ app: AppModel) -> ModelReadiness {
        app.settings.readiness(for: .browserAgent, appleIntelligence: unusedAI)
    }

    static func toolCallingFavoriteDetail(_ fav: FavoriteModel, app: AppModel) -> String {
        let state = app.settings.readiness(of: fav.selection, appleIntelligence: unusedAI).title
        return fav.model.isEmpty ? state : "\(fav.model) · \(state)"
    }

    static func scriptPageURL(facts: DrawerPageFacts, app: AppModel) -> URL? {
        if let url = facts.url, !facts.showsHome { return url }
        if let url = app.pageContext.url, !facts.showsHome { return url }
        return nil
    }

    static func activeRecords(in app: AppModel) -> (summary: WorkRecord?, pull: WorkRecord?, summaryRun: SummaryRunState) {
        guard let topicKey = app.currentTopic?.topicKey else { return (nil, nil, .idle) }
        var summary: WorkRecord?, pull: WorkRecord?
        for r in app.activities where r.topicKey == topicKey && !r.status.isTerminal {
            if summary == nil, r.type == .summary { summary = r }
            if pull == nil, r.type == .pull { pull = r }
        }
        return (summary, pull, SummaryRunState.resolve(app.activities, topicKey: topicKey))
    }

    static func providerSetupRole(app: AppModel, requested: Bool) -> ModelRole? {
        guard browserAgentReadiness(app) != .ready else { return nil }
        if requested { return .browserAgent }
        let assistantModel = app.settings.effectiveModel(for: .assistant)
        let aiStatus = assistantModel.provider.isAppleIntelligence ? app.appleIntelligenceStatus : unusedAI
        return app.settings.readiness(of: assistantModel, appleIntelligence: aiStatus) != .ready ? .browserAgent : nil
    }

    static func exportSlug(for app: AppModel) -> String {
        guard let topic = app.currentTopic else { return "topic" }
        let host = ForumSite.host(of: topic.siteURL).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return "\(host)-\(topic.topicID)"
    }
}

@MainActor
final class SliceBox<Value: Equatable>: ObservableObject {
    private(set) var value: Value
    init(_ value: Value) { self.value = value }
    func seed(_ next: Value) { value = next }
    func update(_ next: Value) {
        guard next != value else { return }
        objectWillChange.send()
        value = next
    }
}

private struct PanelCommandsSlice: Equatable {
    var topicKey: String?; var askFocusRequest = 0
}

private struct PanelRouteSlice: Equatable {
    var route: PanelRoute = .topic; var currentTabID = ""
}

private struct HeaderAppSlice: Equatable {
    var pageURL: URL?; var host = ""; var topicKey = ""; var pageState: PageContext.State = .loading
    var hasCurrentTopic = false; var hasSummaryOnSession = false
    var activeSummary: WorkRecord?; var activePull: WorkRecord?; var summaryRun: SummaryRunState = .idle
    var hasStreamText = false; var hiddenByReset = false
    var currentSelection = ModelSelection(provider: .anthropic, model: ""); var modelSubtitle = ""
    var favorites: [DrawerHeader.FavoriteItem] = []
    var developerMode = false; var auditLogRequest: AuditLogRequest?
}

private struct TranscriptAppSlice: Equatable {
    var topicKey = ""; var hasSummaryOnSession = false; var pageState: PageContext.State = .loading
    var activePull: WorkRecord?; var summaryRun: SummaryRunState = .idle
    var hasStreamText = false; var hiddenByReset = false
    var hasDefaultSetup = false; var hasRequestedSetup = false
    var runsContext = AgentRunsContext(); var activeCitation: Int?
}

private struct SummaryAppSlice: Equatable {
    var topicKey: String?; var hasCurrentTopic = false; var pageState: PageContext.State = .loading
    var activePull: WorkRecord?; var activeSummary: WorkRecord?; var summaryRun: SummaryRunState = .idle
    var streamedSummary: String?; var savedSummary = ""
    var totalPosts: Int?; var meta: SummaryMetaModel?; var hasSummaryOnSession = false
    var hiddenByReset = false; var defaultSetup: ProviderSetupModel?; var requestedSetup: ProviderSetupModel?
    var layout: DrawerSummarySections.LayoutMode = .singleColumn; var readingLanguage = "en"
    var summaryBatchLimit = SummaryBatchLimit.default; var exportOptions = ExportOptions()
    var exportParts = ExportContentFlags(session: nil, topic: nil)
}

private struct FooterAppSlice: Equatable {
    var isFirstRunPrompts = false; var pageURL: URL?; var pageContextURL: URL?
    var looksLikeThread = false; var pageState: PageContext.State = .loading; var hasCurrentTopic = false
    var agentPageToolsEnabled = true; var siteState: SiteToolState?
    var isFollowing = false; var isSummarizing = false; var canTalk = false; var developerMode = false
}

/// Evaluates `AppModel` and active-tab `DrawerPageFacts` into Equatable per-section
/// `SliceBox` stores so an unrelated publish fires zero `ObservableObject` updates
/// inside the drawer's `UIHostingController`.
@MainActor
private final class DrawerAppRelay {
    let statusRow = SliceBox(DrawerStatusRowBody.Model())
    let feedbackToast = SliceBox<FeedbackToastState?>(nil)
    let commands = SliceBox(PanelCommandsSlice())
    let route = SliceBox(PanelRouteSlice())
    let header = SliceBox(HeaderAppSlice())
    let transcript = SliceBox(TranscriptAppSlice())
    let summary = SliceBox(SummaryAppSlice())
    let footer = SliceBox(FooterAppSlice())

    private struct SettingsDerived {
        let sel: ModelSelection
        let isBrowserAgentReady: Bool
        let modelSubtitle: String
        let favorites: [DrawerHeader.FavoriteItem]
        let defaultSetupRole: ModelRole?
        let requestedSetupRole: ModelRole?
        let defaultSetup: ProviderSetupModel?
        let requestedSetup: ProviderSetupModel?
        let readingLanguage: String
        let canTalk: Bool
    }

    private weak var boundApp: AppModel?
    private weak var boundFacts: DrawerPageFactsStore?
    private var cancellables = Set<AnyCancellable>()
    private var factsCancellable: AnyCancellable?
    private var lastSettings: AppSettings?
    private var lastAppleIntelligenceStatus: AppleIntelligenceStatus?
    private var cachedSettingsDerived: SettingsDerived?
    private var hasCachedSiteState = false
    private var lastSiteStateHost: String?
    private var lastSiteStateRevision = -1
    private var cachedSiteState: SiteToolState?
    private var dirty = false

    private func settingsDerived(for app: AppModel) -> SettingsDerived {
        let aiStatus = app.appleIntelligenceStatus
        if let cached = cachedSettingsDerived, lastSettings == app.settings, lastAppleIntelligenceStatus == aiStatus { return cached }
        let settings = app.settings
        lastSettings = settings
        lastAppleIntelligenceStatus = aiStatus
        let sel = app.selection(for: .browserAgent)
        let ready = DrawerInputs.browserAgentReadiness(app)
        let assistantModel = settings.effectiveModel(for: .assistant)
        let defaultRole: ModelRole? = if ready == .ready {
            nil
        } else {
            settings.readiness(of: assistantModel, appleIntelligence: aiStatus) != .ready ? .browserAgent : nil
        }
        let requestedRole: ModelRole? = ready == .ready ? nil : .browserAgent
        let requestedSetup = requestedRole.map { ProviderSetupModel(app: app, role: $0, appleIntelligence: aiStatus) }
        let defaultSetup = defaultRole != nil ? requestedSetup : nil
        let derived = SettingsDerived(
            sel: sel,
            isBrowserAgentReady: ready == .ready,
            modelSubtitle: ready == .ready ? ModelPill.label(for: sel) : ready.title,
            favorites: settings.favoriteModels.filter { $0.selection.supportsToolCalling }
                .map { DrawerHeader.FavoriteItem(favorite: $0, detail: DrawerInputs.toolCallingFavoriteDetail($0, app: app)) },
            defaultSetupRole: defaultRole,
            requestedSetupRole: requestedRole,
            defaultSetup: defaultSetup,
            requestedSetup: requestedSetup,
            readingLanguage: ReadingLanguage.resolved(settings.readingLanguage),
            canTalk: app.voiceProvider != nil
        )
        cachedSettingsDerived = derived
        return derived
    }

    fileprivate func siteState(for url: URL?, enabled: Bool, app: AppModel) -> SiteToolState? {
        guard enabled, let url, let host = SiteToolState.normalizedHost(from: url) else {
            return nil
        }
        let rev = app.siteToolStateStore.currentRevision
        if hasCachedSiteState, lastSiteStateHost == host, lastSiteStateRevision == rev { return cachedSiteState }
        hasCachedSiteState = true
        lastSiteStateHost = host
        lastSiteStateRevision = rev
        cachedSiteState = app.siteToolStateStore.state(forHost: host)
        return cachedSiteState
    }

    func bind(app: AppModel) {
        guard boundApp !== app else { return }
        boundApp = app
        cancellables.removeAll()
        apply(from: app, initial: true)
        bindFacts(app.browser.drawerFacts)
        app.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        app.tabs.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        app.streams.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        app.router.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        app.podcast.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        app.voice.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &cancellables)
        app.siteToolStateStore.changes.receive(on: DispatchQueue.main).sink { [weak self] in self?.scheduleRefresh() }.store(in: &cancellables)
    }

    private func bindFacts(_ store: DrawerPageFactsStore) {
        guard boundFacts !== store else { return }
        boundFacts = store
        factsCancellable = store.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
    }

    private func scheduleRefresh() {
        guard !dirty else { return }
        dirty = true
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.flush()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func flush() {
        dirty = false
        guard let app = boundApp else { return }
        bindFacts(app.browser.drawerFacts)
        apply(from: app, initial: false)
    }

    private func apply(from app: AppModel, initial: Bool) {
        func put<V: Equatable>(_ box: SliceBox<V>, _ v: V) { initial ? box.seed(v) : box.update(v) }
        let facts = app.browser.drawerPageFacts
        let pageURL = DrawerInputs.scriptPageURL(facts: facts, app: app)
        let host = pageURL?.host.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(localized: "No page open", comment: "Browser agent context bar when no web page is loaded")
        let topic = app.currentTopic
        let topicKey = topic?.topicKey ?? ""
        let topicSession = app.currentSession
        let active = DrawerInputs.activeRecords(in: app)
        let streamed = active.summary.flatMap { app.streams.texts[$0.id] }.flatMap { $0.isEmpty ? nil : $0 }
        let hasStreamText = !(streamed ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hidden = app.drawerSummaryHiddenTopicKeys.contains(topicKey)
        let pageState: PageContext.State = topic != nil ? .topic : (app.assistantPageState == .topic ? .forumHome : app.assistantPageState)
        let sd = settingsDerived(for: app)

        put(statusRow, DrawerStatusRowBody.Model(app: app, podcast: app.podcast, voice: app.voice, voiceOnly: nil))
        put(feedbackToast, app.feedbackToast)
        put(commands, PanelCommandsSlice(topicKey: topic?.topicKey, askFocusRequest: app.askFocusRequest))
        put(route, PanelRouteSlice(route: app.panelRoute, currentTabID: app.tabs.currentTabID))
        put(header, HeaderAppSlice(
            pageURL: pageURL, host: host, topicKey: topicKey, pageState: pageState,
            hasCurrentTopic: topic != nil, hasSummaryOnSession: topicSession?.hasSummary == true,
            activeSummary: active.summary, activePull: active.pull, summaryRun: active.summaryRun,
            hasStreamText: hasStreamText, hiddenByReset: hidden, currentSelection: sd.sel,
            modelSubtitle: sd.modelSubtitle,
            favorites: sd.favorites,
            developerMode: app.settings.agentDeveloperMode, auditLogRequest: app.auditLogRequest
        ))
        put(transcript, TranscriptAppSlice(
            topicKey: topicKey, hasSummaryOnSession: topicSession?.hasSummary == true, pageState: pageState,
            activePull: active.pull, summaryRun: active.summaryRun,
            hasStreamText: hasStreamText, hiddenByReset: hidden,
            hasDefaultSetup: sd.defaultSetupRole != nil, hasRequestedSetup: sd.requestedSetupRole != nil,
            runsContext: AgentRunsContext(app: app, tabs: app.tabs), activeCitation: app.citationJump?.number
        ))
        put(summary, SummaryAppSlice(
            topicKey: topic?.topicKey, hasCurrentTopic: topic != nil, pageState: pageState,
            activePull: active.pull, activeSummary: active.summary, summaryRun: active.summaryRun,
            streamedSummary: streamed,
            savedSummary: topicSession?.summary ?? "", totalPosts: topicSession?.totalPosts,
            meta: topicSession.map(SummaryMetaModel.init), hasSummaryOnSession: topicSession?.hasSummary == true,
            hiddenByReset: hidden, defaultSetup: sd.defaultSetup, requestedSetup: sd.requestedSetup,
            layout: app.router.usesWideDrawerSummary && app.router.drawerDetent == .medium ? .twoColumns : .singleColumn,
            readingLanguage: sd.readingLanguage,
            summaryBatchLimit: app.settings.summaryBatchLimit, exportOptions: app.exportOptions,
            exportParts: ExportContentFlags(session: topicSession, topic: topic)
        ))
        let page = app.pageContext
        put(footer, FooterAppSlice(
            isFirstRunPrompts: app.firstRun == .prompts, pageURL: pageURL, pageContextURL: page.url,
            looksLikeThread: page.looksLikeThread, pageState: pageState, hasCurrentTopic: topic != nil,
            agentPageToolsEnabled: app.settings.agentPageToolsEnabled,
            siteState: siteState(for: page.url, enabled: app.settings.agentPageToolsEnabled, app: app),
            isFollowing: topic.map { app.isWatched(topicKey: $0.topicKey) } ?? false,
            isSummarizing: active.summary != nil || active.pull != nil,
            canTalk: sd.canTalk, developerMode: app.settings.agentDeveloperMode
        ))
    }
}

/// Isolated keyboard visibility and composer-focus state for the AI drawer.
///
/// Observed only by `HeaderSectionObserver` and `FooterSectionObserver`, never by
/// `AssistantPanel` or the transcript. While the drawer's composer owns first responder,
/// transient `keyboardWillHide` → `keyboardWillShow` churn (such as hardware-keyboard mode
/// toggles) is coalesced with a bounded timeout so neither the drawer nor `ForumBrowserModel`
/// re-renders mid-keystroke, while a genuine hide while focused (e.g. hardware keyboard
/// attached or iPad shortcut bar) still settles to hidden.
@MainActor
final class DrawerKeyboardState: ObservableObject {
    @Published private(set) var isKeyboardVisible = false
    @Published private(set) var isComposerFocused = false

    private let hideCoalesceDuration: Duration
    private var pendingHideTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private weak var focusedBrowser: ForumBrowserModel?

    init(
        notificationCenter: NotificationCenter = .default,
        hideCoalesceDuration: Duration = .seconds(2)
    ) {
        self.hideCoalesceDuration = hideCoalesceDuration
        notificationCenter.publisher(for: UIResponder.keyboardWillShowNotification)
            .sink { [weak self] note in
                guard (note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) != false else { return }
                self?.handleKeyboardShow()
            }
            .store(in: &cancellables)
        notificationCenter.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] note in
                guard (note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) != false else { return }
                self?.handleKeyboardHide()
            }
            .store(in: &cancellables)
    }

    func setComposerFocused(_ focused: Bool, browser: ForumBrowserModel? = nil) {
        if let previous = focusedBrowser, previous !== browser || !focused {
            previous.setDrawerComposerFocused(false)
            focusedBrowser = nil
        }
        if focused, let browser {
            focusedBrowser = browser
            browser.setDrawerComposerFocused(true)
        }
        if isComposerFocused != focused {
            isComposerFocused = focused
        }
        if !focused, let pending = pendingHideTask {
            pending.cancel()
            pendingHideTask = nil
            if isKeyboardVisible {
                isKeyboardVisible = false
            }
        }
    }

    func handleKeyboardShow() {
        pendingHideTask?.cancel()
        pendingHideTask = nil
        if !isKeyboardVisible {
            isKeyboardVisible = true
        }
    }

    func handleKeyboardHide() {
        guard isKeyboardVisible else {
            pendingHideTask?.cancel()
            pendingHideTask = nil
            return
        }
        if isComposerFocused, hideCoalesceDuration > .zero {
            let duration = hideCoalesceDuration
            pendingHideTask?.cancel()
            pendingHideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: duration)
                guard let self, !Task.isCancelled else { return }
                self.pendingHideTask = nil
                if self.isKeyboardVisible {
                    self.isKeyboardVisible = false
                }
            }
        } else {
            pendingHideTask?.cancel()
            pendingHideTask = nil
            isKeyboardVisible = false
        }
    }
}

/// The unified Agent panel (`design-unified.md` §1): one conversation view
/// shared by the iPhone drawer (`AIDrawer`) and iPad split sidebar (`SplitWorkspace`),
/// with the `"Agent"` + This page header, unified transcript, transient status line,
/// suggestion slot (2b), and `AssistantComposer`.
struct AssistantPanel: View {
    let app: AppModel
    /// Post & responses as a sheet.
    let onExpand: (ExpandedPanelRoute) -> Void
    /// Opens a forum URL in the Browse workspace (the agent's step log uses it).
    let onOpenURL: ((URL) -> Void)?
    @State private var relay = DrawerAppRelay()
    @State private var keyboardState = DrawerKeyboardState()
    @State private var exporting = false
    /// Built when Export .txt is tapped (under the file limit), dropped when the exporter closes.
    @State private var exportDocument: PlainTextDocument?
    @State private var exportSlug = "topic"
    @State private var movingExport = false
    /// Temporary `.txt` file for large Export .txt; removed when `fileMover` closes.
    @State private var exportFileURL: URL?
    @State private var exportShareAnchor = ExportShareAnchor()
    /// The summary without citations (Translate, Read aloud), kept per summary text.
    @State private var strippedSummaryCache = StrippedSummaryCache()
    @State private var scriptMatchesCache = PageScriptMatchesCache()
    /// "Tap a post number to jump to it", shown with the first summary.
    @State private var showsCitationTip = false
    @State private var expandedToolRowIDs: Set<UUID> = []
    @State private var requestedProviderSetup = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        app: AppModel,
        onExpand: @escaping (ExpandedPanelRoute) -> Void,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.app = app
        self.onExpand = onExpand
        self.onOpenURL = onOpenURL
    }

    var payload: TopicExportPayload {
        app.currentExportPayload
    }

    var body: some View {
        let _ = PerfProbe.hit("AssistantPanel.body")
        let _ = relay.bind(app: app)
        VStack(spacing: 0) {
            DrawerStatusRow(app: app, podcast: app.podcast, router: app.router, voice: app.voice, slice: relay.statusRow)
            PanelRouteObserver(
                slice: relay.route, relay: relay, app: app,
                scriptMatchesCache: scriptMatchesCache, strippedSummaryCache: strippedSummaryCache,
                exportShareAnchor: exportShareAnchor, keyboardState: keyboardState,
                showsCitationTip: $showsCitationTip,
                expandedToolRowIDs: $expandedToolRowIDs, requestedProviderSetup: $requestedProviderSetup,
                onExport: presentExport,
                onExpand: onExpand, onOpenURL: openInBrowser
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { FeedbackToastObserver(slice: relay.feedbackToast, app: app) }
        .background { PanelCommandsObserver(slice: relay.commands, app: app) }
        .background(Color.clear)
        .environment(\.citationHover, CitationHoverAction { number in
            Task { await app.browser.highlight([], flash: PostFlash(number: number)) }
        })
        .environment(\.openURL, OpenURLAction { url in
            if let number = PostCitations.postNumber(from: url) {
                app.jumpToCitation(number)
                return .handled
            }
            guard ForumBrowserModel.isBrowsableURL(url) else { return .systemAction }
            openInBrowser(url)
            return .handled
        })
        .onChange(of: exporting) { _, shown in
            if !shown { exportDocument = nil }
        }
        .onChange(of: movingExport) { _, shown in
            if !shown { clearExportFile() }
        }
        .onDisappear {
            keyboardState.setComposerFocused(false)
            if !movingExport { clearExportFile() }
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: TopicExportFile.filename(slug: exportSlug)
        ) { result in
            if case .failure(let error) = result {
                app.presentError(error.localizedDescription)
            }
        }
        .fileMover(isPresented: $movingExport, file: exportFileURL) { result in
            clearExportFile()
            if case .failure(let error) = result {
                app.presentError(error.localizedDescription)
            }
        } onCancellation: {
            clearExportFile()
        }
    }

    private func presentExport(_ delivery: ExportDelivery) {
        switch delivery {
        case .text(let text, let slug):
            exportSlug = slug
            exportDocument = PlainTextDocument(text: text)
            exporting = true
        case .file(let url):
            clearExportFile()
            exportFileURL = url
            movingExport = true
        }
    }

    private func clearExportFile() {
        guard let url = exportFileURL else { return }
        exportFileURL = nil
        TopicExportFile.removeTemporaryFile(at: url)
    }

    private func openInBrowser(_ url: URL) {
        if app.router.drawerPhase == .shown, app.router.drawerDetent == .large {
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) { app.router.drawerDetent = .medium }
        }
        app.openLink(url)
        onOpenURL?(url)
    }
}

private struct FeedbackToastObserver: View {
    @ObservedObject var slice: SliceBox<FeedbackToastState?>
    let app: AppModel
    var body: some View {
        FeedbackToastBody(toast: slice.value, app: app).equatable()
    }
}

private struct FeedbackToastBody: View, Equatable {
    let toast: FeedbackToastState?
    let app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.toast == rhs.toast && ObjectIdentifier(lhs.app) == ObjectIdentifier(rhs.app)
    }
    var body: some View {
        Group {
            if let toast {
                FeedbackSavedToast(message: toast.message)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(DCMotion.slide(.bottom, reduceMotion: reduceMotion))
                    .onTapGesture { app.feedbackToast = nil }
            }
        }
        .animation(DCMotion.respecting(reduceMotion, DCMotion.spring), value: toast?.id)
    }
}

private struct PanelCommandsObserver: View {
    @ObservedObject var slice: SliceBox<PanelCommandsSlice>
    let app: AppModel
    var body: some View {
        PanelCommandsBody(topicKey: slice.value.topicKey, askFocusRequest: slice.value.askFocusRequest, app: app).equatable()
    }
}

private struct PanelCommandsBody: View, Equatable {
    let topicKey: String?
    let askFocusRequest: Int
    let app: AppModel
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.topicKey == rhs.topicKey && lhs.askFocusRequest == rhs.askFocusRequest && ObjectIdentifier(lhs.app) == ObjectIdentifier(rhs.app)
    }
    var body: some View {
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            .onChange(of: topicKey) { app.exportOptions = ExportOptions() }
            .onChange(of: askFocusRequest) { app.drafts.perform(.focus) }
    }
}

// MARK: Header

private struct HeaderSectionObserver: View {
    @ObservedObject var slice: SliceBox<HeaderAppSlice>
    @ObservedObject var keyboardState: DrawerKeyboardState
    let app: AppModel
    let scriptMatchesCache: PageScriptMatchesCache
    let onNewConversation: () -> Void
    let onFixScript: (UserScript) -> Void

    var body: some View {
        let s = slice.value
        let session = app.browserAgent
        let scriptMatches = scriptMatchesCache.summary(for: s.pageURL, in: app.scriptStore)
        let foldedStep: Int? = if keyboardState.isKeyboardVisible && keyboardState.isComposerFocused, case .running(let step, _) = session.runState { max(1, step) } else { nil }
        let hasConv = !session.runs.isEmpty || !session.messages.isEmpty || session.isRunning
        let presentation = SummaryPresentation.resolve(
            jobState: s.summaryRun, hasStreamText: s.hasStreamText, hasSavedSummary: s.hasSummaryOnSession,
            isHiddenByNewConversation: s.hiddenByReset, isPulling: s.activePull != nil,
            pageState: s.pageState, hasConversation: hasConv,
            runs: session.runs, topicKey: s.topicKey, app: app
        )
        let finished = session.runs.last.flatMap { $0.state.isRunning ? nil : $0.id.uuidString }
        DrawerHeader(
            model: .init(
                sessionID: ObjectIdentifier(session), pageURL: s.pageURL, host: s.host, foldedStep: foldedStep,
                scriptMatches: scriptMatches, canStartNewConversation: presentation.canStartNewConversation,
                modelSubtitle: s.modelSubtitle,
                currentSelection: s.currentSelection, favorites: s.favorites, hasCurrentTopic: s.hasCurrentTopic,
                showsPullPost: s.hasCurrentTopic && !s.hasSummaryOnSession,
                pullPostDisabled: s.activeSummary != nil || s.activePull != nil,
                developerMode: s.developerMode, finishedTaskID: finished,
                auditLogRequest: s.auditLogRequest
            ),
            app: app, onNewConversation: onNewConversation, onFixScript: onFixScript
        )
        .equatable()
    }
}

struct DrawerHeader: View, Equatable {
    struct FavoriteItem: Identifiable, Equatable {
        let favorite: FavoriteModel; let detail: String
        var id: String { favorite.id }
    }
    struct Model: Equatable {
        let sessionID: ObjectIdentifier; let pageURL: URL?; let host: String; let foldedStep: Int?
        let scriptMatches: PageScriptMatchesCache.Summary; let canStartNewConversation: Bool
        let modelSubtitle: String; let currentSelection: ModelSelection; let favorites: [FavoriteItem]
        let hasCurrentTopic: Bool; let showsPullPost: Bool; let pullPostDisabled: Bool
        let developerMode: Bool; let finishedTaskID: String?; let auditLogRequest: AuditLogRequest?
    }

    let model: Model
    let app: AppModel
    let onNewConversation: () -> Void
    let onFixScript: (UserScript) -> Void
    @State private var showsPageCapabilitiesPopover = false
    @State private var exportTaskID: String?
    @State private var reportTaskID: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && ObjectIdentifier(lhs.app) == ObjectIdentifier(rhs.app)
    }

    var body: some View {
        let _ = PerfProbe.hit("DrawerHeader.body")
        PerfProbe.time("AssistantPanel.buildHeader") { drawerHeader }
            .onChange(of: model.sessionID) { showsPageCapabilitiesPopover = false }
            .onAppear {
                #if DEBUG
                if AssistantDebug.has("-dc-scripts-open-popover") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        showsPageCapabilitiesPopover = true
                    }
                }
                #endif
            }
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
                newConversationButton
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
        if let step = model.foldedStep {
            HStack(spacing: 6) {
                DCAgentRing(state: .working, size: 14, lineWidth: 2)
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
        let allCount = model.scriptMatches.allCount
        let activeCount = model.scriptMatches.activeCount
        let errorCount = model.scriptMatches.errorCount
        let isGlobalEnabled = model.scriptMatches.isGlobalEnabled
        let host = model.host

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
                pageURL: model.pageURL,
                isPresented: $showsPageCapabilitiesPopover,
                onFixScript: onFixScript
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: Header ··· menu

    private var newConversationButton: some View {
        Button {
            DCHaptics.tap()
            onNewConversation()
        } label: {
            Image(systemName: "plus.bubble")
        }
        .buttonStyle(DCIconButtonStyle())
        .accessibilityLabel(String(localized: "New conversation", comment: "Browser agent menu action: clear the conversation and start fresh"))
        .accessibilityIdentifier("agentNewConversationHeader")
        .disabled(!model.canStartNewConversation)
    }

    private var drawerMoreMenu: some View {
        Menu {
            Section {
                Menu {
                    agentModelMenuItems
                } label: {
                    Label {
                        Text("Model", comment: "Assistant more menu submenu for choosing the Agent model")
                        Text(verbatim: model.modelSubtitle)
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
                .disabled(!model.hasCurrentTopic)

                // Before a summary exists (after, it is in the summary's ⋯).
                if model.showsPullPost {
                    Button {
                        app.pullTopic()
                    } label: {
                        Label("Pull Post + Replies Only", systemImage: "arrow.down.circle")
                    }
                    .accessibilityIdentifier("menuPullPost")
                    .disabled(model.pullPostDisabled)
                }

                Button {
                    DCHaptics.tap()
                    onNewConversation()
                } label: {
                    Label(
                        String(localized: "New conversation", comment: "Browser agent menu action: clear the conversation and start fresh"),
                        systemImage: "plus.bubble"
                    )
                }
                .accessibilityIdentifier("agentNewConversation")
                .disabled(!model.canStartNewConversation)
            }

            Section {
                let finished = model.finishedTaskID
                if model.developerMode {
                    Button {
                        exportTaskID = finished
                    } label: {
                        Label(
                            String(localized: "Export task", comment: "Assistant more menu: export the last task as a file (developer mode)"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .disabled(finished == nil)
                    .accessibilityIdentifier("exportTaskMenuItem")
                }

                Button {
                    reportTaskID = finished
                } label: {
                    Label(
                        String(localized: "Report a problem", comment: "Assistant more menu: save the last task for TestFlight feedback"),
                        systemImage: "exclamationmark.bubble"
                    )
                }
                .disabled(finished == nil)
                .accessibilityIdentifier("reportProblemMenuItem")

                Button {
                    app.auditLogRequest = AuditLogRequest()
                } label: {
                    Label(
                        String(localized: "Audit log", comment: "Assistant more menu: open the Agent's audit log"),
                        systemImage: "list.bullet.clipboard"
                    )
                }
                .accessibilityIdentifier("auditLogMenuItem")

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
        .taskExportPrompt(app: app, taskID: $exportTaskID)
        .taskReportPrompt(app: app, taskID: $reportTaskID)
        .sheet(item: Binding(get: { model.auditLogRequest }, set: { app.auditLogRequest = $0 })) { request in
            NavigationStack {
                SettingsAuditLogPage(app: app, focus: request)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done", comment: "Closes the audit log sheet")) {
                                app.auditLogRequest = nil
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var agentModelMenuItems: some View {
        let current = model.currentSelection
        Section {
            if !current.model.isEmpty, !model.favorites.contains(where: { $0.favorite.matches(current) }) {
                Toggle(isOn: .constant(true)) {
                    Text(current.provider.displayName)
                    Text(verbatim: ModelPill.label(for: current))
                }
            }
            ForEach(model.favorites) { item in
                Toggle(isOn: Binding(
                    get: { item.favorite.matches(current) },
                    set: { _ in app.activateFavorite(item.favorite, for: .browserAgent) }
                )) {
                    Text(item.favorite.provider.displayName)
                    Text(item.detail)
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
}

private struct PanelRouteObserver: View {
    @ObservedObject var slice: SliceBox<PanelRouteSlice>
    let relay: DrawerAppRelay
    let app: AppModel
    let scriptMatchesCache: PageScriptMatchesCache
    let strippedSummaryCache: StrippedSummaryCache
    let exportShareAnchor: ExportShareAnchor
    let keyboardState: DrawerKeyboardState
    @Binding var showsCitationTip: Bool
    @Binding var expandedToolRowIDs: Set<UUID>
    @Binding var requestedProviderSetup: Bool
    let onExport: (ExportDelivery) -> Void
    let onExpand: (ExpandedPanelRoute) -> Void
    let onOpenURL: (URL) -> Void

    var body: some View {
        let s = slice.value
        TopicPanelBody(
            route: s.route, relay: relay, app: app, currentTabID: s.currentTabID, scriptMatchesCache: scriptMatchesCache,
            strippedSummaryCache: strippedSummaryCache,
            exportShareAnchor: exportShareAnchor, keyboardState: keyboardState,
            showsCitationTip: $showsCitationTip,
            expandedToolRowIDs: $expandedToolRowIDs, requestedProviderSetup: $requestedProviderSetup,
            onExport: onExport, onExpand: onExpand, onOpenURL: onOpenURL
        )
        .equatable()
    }
}

private struct TopicPanelBody: View, Equatable {
    let route: PanelRoute
    let relay: DrawerAppRelay
    let app: AppModel
    let currentTabID: String
    let scriptMatchesCache: PageScriptMatchesCache
    let strippedSummaryCache: StrippedSummaryCache
    let exportShareAnchor: ExportShareAnchor
    let keyboardState: DrawerKeyboardState
    @Binding var showsCitationTip: Bool
    @Binding var expandedToolRowIDs: Set<UUID>
    @Binding var requestedProviderSetup: Bool
    let onExport: (ExportDelivery) -> Void
    let onExpand: (ExpandedPanelRoute) -> Void
    let onOpenURL: (URL) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var browserAgent: BrowserAgentSession { app.browserAgent }
    private var scriptStore: ScriptStore { app.scriptStore }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.route == rhs.route && ObjectIdentifier(lhs.app) == ObjectIdentifier(rhs.app) && lhs.currentTabID == rhs.currentTabID
            && ObjectIdentifier(lhs.keyboardState) == ObjectIdentifier(rhs.keyboardState)
            && lhs.showsCitationTip == rhs.showsCitationTip && lhs.expandedToolRowIDs == rhs.expandedToolRowIDs
            && lhs.requestedProviderSetup == rhs.requestedProviderSetup
    }

    var body: some View {
        if route == .topic {
            topicContent
        } else {
            VStack(spacing: 0) {
                subHeader("History")
                Divider()
                HistoryView(app: app)
            }
        }
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

    private var topicContent: some View {
        VStack(spacing: 0) {
            HeaderSectionObserver(
                slice: relay.header, keyboardState: keyboardState, app: app, scriptMatchesCache: scriptMatchesCache,
                onNewConversation: { app.hideDrawerSummaryForNewConversation(); browserAgent.resetConversation() },
                onFixScript: sendFixScriptRequest
            )
            Divider()
            TranscriptSectionObserver(
                slice: relay.transcript, summarySlice: relay.summary, app: app, strippedSummaryCache: strippedSummaryCache,
                exportShareAnchor: exportShareAnchor, showsCitationTip: $showsCitationTip,
                expandedToolRowIDs: $expandedToolRowIDs, requestedProviderSetup: $requestedProviderSetup,
                onExport: onExport, onExpand: onExpand, onOpenURL: onOpenURL
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            FooterSectionObserver(
                slice: relay.footer, keyboardState: keyboardState, relay: relay, app: app, scriptMatchesCache: scriptMatchesCache,
                onFocusChange: { keyboardState.setComposerFocused($0, browser: app.browser) },
                onSuggestion: runSuggestion, onSend: submitPrompt
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentPanel")
    }

    private func runSuggestion(_ suggestion: PageSuggestion) {
        switch PageSuggestions.route(for: suggestion) {
        case .fill:
            app.drafts.perform(.fill(suggestion.composerText))
        case .agent where app.firstRun != nil:
            // Step 3 sends once the page has loaded.
            Task { @MainActor in
                var waited = 0
                while app.browser.drawerPageFacts.isLoading, waited < 50 {
                    try? await Task.sleep(for: .milliseconds(200))
                    waited += 1
                }
                app.drafts.perform(.send(suggestion.text, attachedBlock: nil))
            }
        case .agent where suggestion == .pageBroken:
            Task { @MainActor in
                let snapshot = await app.browser.agentBridge.pageSnapshot()
                let url = DrawerInputs.scriptPageURL(facts: app.browser.drawerPageFacts, app: app)
                let active = scriptMatchesCache.enabledScripts(for: url, in: scriptStore)
                let block = PageFeedbackContext.brokenPageBlock(
                    snapshot: snapshot,
                    activeScripts: active,
                    errorsByScriptID: scriptStore.scriptErrors
                )
                app.drafts.perform(.send(suggestion.text, attachedBlock: block))
            }
        case .agent:
            app.drafts.perform(.send(suggestion.text, attachedBlock: nil))
        }
    }

    private func announceRunLimitNoticeIfPresent() {
        guard let notice = browserAgent.runLimitNotice else { return }
        UIAccessibility.post(notification: .announcement, argument: notice)
    }

    private func sendFixScriptRequest(for script: UserScript) {
        guard !browserAgent.isRunning else { return }
        app.drafts.perform(.stopDictation)
        guard app.isProviderReady(for: .browserAgent) else {
            requestedProviderSetup = true
            app.drafts.perform(.blur)
            return
        }
        requestedProviderSetup = false
        guard browserAgent.checkRunStartGate() else {
            announceRunLimitNoticeIfPresent()
            return
        }
        DCHaptics.tap()
        app.drafts.perform(.clearAndBlur)
        app.startScriptRepair(script)
    }

    /// The footer's send, after it has closed the microphone: provider and run-limit
    /// checks, then the run. The footer empties the box when this says `.sent`.
    private func submitPrompt(_ prompt: String, attachedBlock: String?) -> ComposerSendOutcome {
        guard app.isProviderReady(for: .browserAgent) else {
            requestedProviderSetup = true
            return .needsProvider
        }
        requestedProviderSetup = false
        guard browserAgent.checkRunStartGate() else {
            announceRunLimitNoticeIfPresent()
            return .blocked
        }
        DCHaptics.tap()
        if app.router.drawerPhase == .shown,
           app.router.drawerDetent == .large,
           !dynamicTypeSize.isAccessibilitySize {
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) {
                app.router.drawerDetent = .medium
            }
        }
        browserAgent.send(prompt, context: nil, attachedBlock: attachedBlock)
        return .sent
    }
}

private struct FooterSectionObserver: View {
    @ObservedObject var slice: SliceBox<FooterAppSlice>
    @ObservedObject var keyboardState: DrawerKeyboardState
    let relay: DrawerAppRelay
    let app: AppModel
    let scriptMatchesCache: PageScriptMatchesCache
    let onFocusChange: (Bool) -> Void
    let onSuggestion: (PageSuggestion) -> Void
    let onSend: (String, String?) -> ComposerSendOutcome

    var body: some View {
        let s = slice.value
        let scripts = app.scriptStore.scripts
        let suggestions: [PageSuggestion] = {
            if s.isFirstRunPrompts { return [.tryReadable, .tryHideClutter] }
            let learned = s.agentPageToolsEnabled
                ? s.pageContextURL.flatMap { SiteToolState.learnedSuggestionKind(state: relay.siteState(for: $0, enabled: true, app: app), url: $0, scripts: scripts) }
                : nil
            let kind = PageSuggestions.pageKind(state: s.pageState, hasPage: s.pageURL != nil || s.hasCurrentTopic, learned: learned, looksLikeThread: s.looksLikeThread)
            let m = scriptMatchesCache.summary(for: s.pageURL, in: app.scriptStore)
            return PageSuggestions.suggestions(for: kind, isFollowing: s.isFollowing, isSummarizing: s.isSummarizing, hasActiveScripts: m.isGlobalEnabled && m.activeCount > 0, hasScriptErrors: m.errorCount > 0)
        }()
        EquatableFooter(
            app: app, sessionID: ObjectIdentifier(app.browserAgent), suggestions: suggestions,
            isKeyboardVisible: keyboardState.isKeyboardVisible, canTalk: s.canTalk,
            developerMode: s.developerMode,
            onFocusChange: onFocusChange, onSuggestion: onSuggestion, onSend: onSend
        )
        .equatable()
    }
}

private struct EquatableFooter: View, Equatable {
    let app: AppModel; let sessionID: ObjectIdentifier; let suggestions: [PageSuggestion]
    let isKeyboardVisible: Bool; let canTalk: Bool; let developerMode: Bool
    let onFocusChange: (Bool) -> Void; let onSuggestion: (PageSuggestion) -> Void
    let onSend: (String, String?) -> ComposerSendOutcome

    static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(lhs.app) == ObjectIdentifier(rhs.app) && lhs.sessionID == rhs.sessionID
            && lhs.suggestions == rhs.suggestions && lhs.isKeyboardVisible == rhs.isKeyboardVisible
            && lhs.canTalk == rhs.canTalk && lhs.developerMode == rhs.developerMode
    }

    var body: some View {
        PerfProbe.time("AssistantPanel.buildFooter") {
            AssistantFooter(
                app: app, drafts: app.drafts, voice: app.voice, suggestions: suggestions,
                isKeyboardVisible: isKeyboardVisible, onFocusChange: onFocusChange,
                onSuggestion: onSuggestion, onSend: onSend
            )
        }
    }
}

// MARK: Summary & Unified Transcript

struct SummaryMetaModel: Equatable {
    let topicKey: String; let title: String; let summary: String; let hasSummary: Bool
    let model: String; let totalPosts: Int?; let summaryPostCount: Int?
    let summaryUpdatedAt: Date?; let kept: Bool; let hasStaleSummary: Bool; let hasSource: Bool

    init(_ s: TopicSession) {
        topicKey = s.topicKey; title = s.title; summary = s.summary; hasSummary = s.hasSummary
        model = s.model; totalPosts = s.totalPosts; summaryPostCount = s.summaryPostCount
        summaryUpdatedAt = s.summaryUpdatedAt; kept = s.kept; hasStaleSummary = s.hasStaleSummary
        hasSource = !s.source.isEmpty
    }
}

struct ExportContentFlags: Equatable {
    let hasTitleAndURL: Bool; let hasSummary: Bool; let hasSource: Bool; let hasChatHistory: Bool
    init(session s: TopicSession?, topic: ForumTopic?) {
        let title = s?.title ?? topic?.title ?? ""
        let url = s?.url ?? topic?.url
        hasTitleAndURL = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(url?.absoluteString.isEmpty ?? true)
        hasSummary = s?.hasSummary == true
        hasSource = !(s?.source.isEmpty ?? true)
        hasChatHistory = !(s?.history.isEmpty ?? true)
    }
}

private struct TranscriptSectionObserver: View {
    @ObservedObject var slice: SliceBox<TranscriptAppSlice>
    let summarySlice: SliceBox<SummaryAppSlice>
    let app: AppModel
    let strippedSummaryCache: StrippedSummaryCache
    let exportShareAnchor: ExportShareAnchor
    @Binding var showsCitationTip: Bool
    @Binding var expandedToolRowIDs: Set<UUID>
    @Binding var requestedProviderSetup: Bool
    let onExport: (ExportDelivery) -> Void
    let onExpand: (ExpandedPanelRoute) -> Void
    let onOpenURL: (URL) -> Void

    var body: some View {
        let s = slice.value
        let session = app.browserAgent
        let runs = session.runs
        let hasConv = !runs.isEmpty || session.messages.contains(where: \.role.isVoice)
        let presentation = SummaryPresentation.resolve(
            jobState: s.summaryRun, hasStreamText: s.hasStreamText, hasSavedSummary: s.hasSummaryOnSession,
            isHiddenByNewConversation: s.hiddenByReset, isPulling: s.activePull != nil,
            pageState: s.pageState, hasConversation: hasConv,
            runs: runs, topicKey: s.topicKey, app: app
        )
        let hasSetup = s.pageState != .loading && (requestedProviderSetup ? s.hasRequestedSetup : s.hasDefaultSetup)
        let hasLeading = hasSetup || presentation.hasTopContent
        let cardRowID = presentation.card.rowID
        let model = PerfProbe.time("AssistantPanel.buildThread") {
            var runsContext = s.runsContext
            runsContext.cardRowID = cardRowID
            return ChatThread.Model(
                topicKey: s.topicKey, hasSummaryOnSession: s.hasSummaryOnSession, hasLeadingContent: hasLeading,
                hasConversation: hasConv, runsContext: runsContext,
                cardRowID: cardRowID, activeCitation: s.activeCitation,
                showsCitationTip: showsCitationTip, requestedProviderSetup: requestedProviderSetup,
                expandedToolRowIDs: expandedToolRowIDs
            )
        }
        ChatThread(
            model: model, summarySlice: summarySlice,
            app: app, session: session, strippedSummaryCache: strippedSummaryCache,
            exportShareAnchor: exportShareAnchor, showsCitationTip: $showsCitationTip,
            expandedToolRowIDs: $expandedToolRowIDs, requestedProviderSetup: $requestedProviderSetup,
            onExport: onExport, onExpand: onExpand, onOpenURL: onOpenURL
        )
        .equatable()
    }
}

private struct SummarySectionObserver: View {
    @ObservedObject var slice: SliceBox<SummaryAppSlice>
    let app: AppModel
    let session: BrowserAgentSession
    let isCardFooter: Bool
    let strippedSummaryCache: StrippedSummaryCache
    let exportShareAnchor: ExportShareAnchor
    @Binding var showsCitationTip: Bool
    @Binding var requestedProviderSetup: Bool
    let onExport: (ExportDelivery) -> Void
    let onExpand: (ExpandedPanelRoute) -> Void
    @State private var renderedSummary: ThrottledParse<DrawerSummarySections.Input, (sections: Int, hasCitations: Bool, rows: [MarkdownRow])>?
    @State private var parsedCache = ParsedSummaryCache()

    var body: some View {
        let s = slice.value
        let model: DrawerSummary.Model = if isCardFooter {
            makeCardModel(s)
        } else {
            makeTopModel(s)
        }
        DrawerSummary(
            model: model, app: app, strippedSummaryCache: strippedSummaryCache, exportShareAnchor: exportShareAnchor,
            renderedSummary: $renderedSummary, showsCitationTip: $showsCitationTip,
            onDismissCitationTip: { showsCitationTip = false }, onExport: onExport, onExpand: onExpand
        )
        .equatable()
    }

    private func resolve(_ s: SummaryAppSlice, hasStreamText: Bool) -> SummaryPresentation {
        SummaryPresentation.resolve(
            jobState: s.summaryRun, hasStreamText: hasStreamText, hasSavedSummary: s.hasSummaryOnSession,
            isHiddenByNewConversation: s.hiddenByReset, isPulling: s.activePull != nil,
            pageState: s.pageState, hasConversation: session.hasConversation,
            runs: session.runs, topicKey: s.topicKey ?? "", app: app
        )
    }

    private func makeCardModel(_ s: SummaryAppSlice) -> DrawerSummary.Model {
        let presentation = resolve(s, hasStreamText: false)
        let showsSavedChrome: Bool = switch presentation.card {
        case .saved, .failed: true
        case .none, .running: false
        }
        return .init(
            mode: .card(presentation.card), isLazy: false, setup: nil,
            activePull: s.activePull, activeSummary: s.activeSummary, summaryRun: s.summaryRun,
            parsed: .empty, streamInput: nil, topicKey: s.topicKey, layout: .singleColumn,
            meta: showsSavedChrome ? s.meta : nil,
            showsCitationTip: showsSavedChrome && showsCitationTip,
            hasCurrentTopic: s.hasCurrentTopic, hasSummaryOnSession: s.hasSummaryOnSession,
            readingLanguage: s.readingLanguage, summaryBatchLimit: s.summaryBatchLimit,
            exportOptions: s.exportOptions, exportParts: s.exportParts
        )
    }

    private func makeTopModel(_ s: SummaryAppSlice) -> DrawerSummary.Model {
        let initial = resolve(s, hasStreamText: !(s.streamedSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let streamInput: DrawerSummarySections.Input? = if case .running = initial.top {
            s.streamedSummary.map { DrawerSummarySections.Input(text: $0, maximumPost: s.totalPosts) }
        } else {
            nil
        }
        let parsed: ParsedSummary = switch initial.top {
        case .running:
            if streamInput != nil, let renderedSummary, !renderedSummary.output.rows.isEmpty {
                ParsedSummary(input: renderedSummary.input, sections: renderedSummary.output.sections, hasCitations: renderedSummary.output.hasCitations, rows: renderedSummary.output.rows)
            } else if let streamInput, !streamInput.text.isEmpty {
                parsedCache.parsed(for: streamInput)
            } else {
                .empty
            }
        case .saved, .failed(_, true):
            s.savedSummary.isEmpty ? .empty : parsedCache.parsed(for: .init(text: s.savedSummary, maximumPost: s.totalPosts))
        case .none, .loading, .emptyTopic, .failed(_, false):
            .empty
        }
        let top: SummaryPresentation.Top = if case .running(true) = initial.top, parsed.rows.isEmpty {
            .running(streaming: false)
        } else {
            initial.top
        }
        let showsSavedChrome: Bool = switch top {
        case .saved, .failed(_, true): true
        case .none, .loading, .emptyTopic, .running, .failed(_, false): false
        }
        let setup = s.pageState != .loading ? (requestedProviderSetup ? s.requestedSetup : s.defaultSetup) : nil
        return .init(
            mode: .top(top, showsPullProgress: initial.showsPullProgress),
            isLazy: parsed.hasCitations || parsed.rows.count >= MarkdownView.lazyRowThreshold,
            setup: setup, activePull: s.activePull, activeSummary: s.activeSummary, summaryRun: s.summaryRun,
            parsed: parsed, streamInput: streamInput, topicKey: s.topicKey, layout: s.layout,
            meta: showsSavedChrome ? s.meta : nil,
            showsCitationTip: showsSavedChrome && showsCitationTip,
            hasCurrentTopic: s.hasCurrentTopic, hasSummaryOnSession: s.hasSummaryOnSession,
            readingLanguage: s.readingLanguage, summaryBatchLimit: s.summaryBatchLimit,
            exportOptions: s.exportOptions, exportParts: s.exportParts
        )
    }
}

struct DrawerSummary: View, Equatable {
    enum Mode: Equatable {
        case top(SummaryPresentation.Top, showsPullProgress: Bool)
        case card(SummaryPresentation.Card)
    }

    struct Model: Equatable {
        let mode: Mode; let isLazy: Bool; let setup: ProviderSetupModel?
        let activePull: WorkRecord?; let activeSummary: WorkRecord?; let summaryRun: SummaryRunState
        let parsed: ParsedSummary; let streamInput: DrawerSummarySections.Input?; let topicKey: String?
        let layout: DrawerSummarySections.LayoutMode
        let meta: SummaryMetaModel?; let showsCitationTip: Bool
        let hasCurrentTopic: Bool; let hasSummaryOnSession: Bool; let readingLanguage: String; let summaryBatchLimit: Int
        let exportOptions: ExportOptions; let exportParts: ExportContentFlags
    }

    let model: Model
    let app: AppModel
    let strippedSummaryCache: StrippedSummaryCache
    let exportShareAnchor: ExportShareAnchor
    @Binding var renderedSummary: ThrottledParse<DrawerSummarySections.Input, (sections: Int, hasCitations: Bool, rows: [MarkdownRow])>?
    @Binding var showsCitationTip: Bool
    let onDismissCitationTip: () -> Void
    let onExport: (ExportDelivery) -> Void
    let onExpand: (ExpandedPanelRoute) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && ObjectIdentifier(lhs.app) == ObjectIdentifier(rhs.app)
    }

    private var exportDisabled: Bool {
        PerfProbe.time("AssistantPanel.exportDisabled") {
            model.activePull != nil || !app.currentExportPayload.hasContent(options: model.exportOptions)
        }
    }

    var body: some View {
        let _ = PerfProbe.hit("DrawerSummary.body")
        switch model.mode {
        case .card(let card):
            summaryCardFooterBody(card)
        case .top(let top, let showsPullProgress):
            if model.setup != nil || showsPullProgress || top != .none || model.streamInput != nil {
                Group {
                    if model.isLazy {
                        LazyVStack(alignment: .leading, spacing: 8) { topBody(top, showsPullProgress: showsPullProgress) }.transition(.identity)
                    } else {
                        VStack(alignment: .leading, spacing: 8) { topBody(top, showsPullProgress: showsPullProgress) }.transition(.identity)
                    }
                }
                .animation(DCMotion.respecting(reduceMotion), value: model.activeSummary?.id)
                .animation(DCMotion.respecting(reduceMotion), value: model.activePull?.id)
                .animation(DCMotion.respecting(reduceMotion), value: model.summaryRun)
                .animation(.easeOut(duration: 0.25), value: model.parsed.sections)
                .task(id: model.streamInput) {
                    guard let streamInput = model.streamInput else { renderedSummary = nil; return }
                    if let updated = await ThrottledParse.refreshed(from: renderedSummary, to: streamInput, parse: DrawerSummarySections.parsed) {
                        renderedSummary = updated
                    }
                }
                .onChange(of: model.topicKey) { renderedSummary = nil }
                .onDisappear { if renderedSummary != nil { renderedSummary = nil } }
            }
        }
    }

    @ViewBuilder
    private func topBody(_ top: SummaryPresentation.Top, showsPullProgress: Bool) -> some View {
        if let setup = model.setup {
            ProviderSetupCardBody(model: setup, app: app)
                .equatable()
                .padding(.top, 4)
        }
        if case .loading = top {
            AssistantLoadingState()
                .padding(.top, 4)
        }
        if showsPullProgress, let record = model.activePull {
            WorkProgressCard(record: record, progress: app.progress) { app.cancel(record: record) }
                .padding(.top, 4)
                .transition(.opacity)
        }
        switch top {
        case .none, .loading:
            EmptyView()
        case .emptyTopic:
            DCMascotView(pose: .wave, size: 128)
                .padding(.vertical, 32)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Agent ready", comment: "Empty Agent panel accessibility label"))
                .accessibilityIdentifier("agentEmptyState")
                .frame(maxWidth: .infinity)
        case .running(let streaming):
            summaryProgressCard
            if streaming {
                summarySectionsBlock
            } else {
                SummaryPlaceholder()
                    .padding(.top, 4)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        case .saved:
            topSavedSummary
        case .failed(let message, let showsSaved):
            failedSummaryCard(message)
            if showsSaved { topSavedSummary }
        }
    }

    @ViewBuilder
    private var summarySectionsBlock: some View {
        // The summary's rows stay direct children of the lazy transcript (a long
        // summary lays out only what is on screen), so only the jade header is a card piece.
        DCResultHeader(label: String(localized: "Summary", comment: "Summary result card header"), systemImage: "doc.text")
            .padding(.top, 4)
        DrawerSummarySections(rows: model.parsed.rows, layout: model.layout)
            .accessibilityIdentifier("summaryContent")
            .transition(.identity)
    }

    @ViewBuilder
    private var topSavedSummary: some View {
        if let meta = model.meta {
            drawerSummaryMeta(meta)
                .padding(.top, 4)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            if meta.hasStaleSummary {
                DrawerStaleBanner(totalPosts: meta.totalPosts, summaryPostCount: meta.summaryPostCount) { app.startSummary() }
                    .disabled(model.activeSummary != nil || model.activePull != nil)
                    .padding(.top, 4)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        summarySectionsBlock
        if model.showsCitationTip {
            citationTip
                .padding(.top, 4)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
        }
        summarizeControl(prominent: false)
            .padding(.top, 4)
            .transition(.asymmetric(insertion: .opacity, removal: .identity))
    }

    @ViewBuilder
    private var summaryProgressCard: some View {
        if let record = model.activeSummary {
            WorkProgressCard(record: record, progress: app.progress) { app.cancel(record: record) }
                .padding(.top, 4)
                .transition(.opacity)
        }
    }

    private func failedSummaryCard(_ message: String) -> some View {
        SummaryFailedCard(message: message, canRetry: model.activePull == nil) {
            app.startSummary(regenerate: true)
        }
        .padding(.top, 4)
        .transition(.opacity)
    }

    /// Under the conversation's summary card for the open thread: what the top
    /// section had around its summary (WUKO-134), so there is one summary on screen.
    @ViewBuilder
    private func summaryCardFooterBody(_ card: SummaryPresentation.Card) -> some View {
        switch card {
        case .none:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: 8) { summaryProgressCard }
                .transition(.opacity)
        case .saved:
            VStack(alignment: .leading, spacing: 8) { cardSavedSummaryChrome }
                .transition(.opacity)
        case .failed(_, let message):
            VStack(alignment: .leading, spacing: 8) {
                failedSummaryCard(message)
                cardSavedSummaryChrome
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var cardSavedSummaryChrome: some View {
        if let meta = model.meta {
            drawerSummaryMeta(meta)
            if meta.hasStaleSummary {
                DrawerStaleBanner(totalPosts: meta.totalPosts, summaryPostCount: meta.summaryPostCount) { app.startSummary() }
                    .disabled(model.activePull != nil)
            }
            if model.showsCitationTip { citationTip }
            summarizeControl(prominent: false)
        }
    }

    /// Meta chips: model, post count, age, Kept.
    @ViewBuilder
    private func summaryMeta(_ session: SummaryMetaModel) -> some View {
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

    private func summaryMetaRow(_ session: SummaryMetaModel) -> some View {
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
    private func drawerSummaryMeta(_ session: SummaryMetaModel) -> some View {
        let strippedText = PerfProbe.time("AssistantPanel.strippedSummary") { strippedSummaryCache.stripped(session.summary) }
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
                        DirectTranslateButton(app: app, readingLanguage: model.readingLanguage, title: session.title, text: strippedText, compact: true)
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
                    .disabled(model.activeSummary != nil || model.activePull != nil)
                    .accessibilityHint(Text("Writes the summary again", comment: "Accessibility hint of the summary's Retry button"))
                    .accessibilityIdentifier("retrySummary")

                    summaryMoreMenu(session)
                }
            }
        }
    }

    /// Summary-specific actions moved out of the panel header (`design-unified.md` §1).
    private func summaryMoreMenu(_ meta: SummaryMetaModel) -> some View {
        SummaryMoreMenu(
            app: app,
            exportShareAnchor: exportShareAnchor,
            exportDisabled: exportDisabled,
            hasSource: meta.hasSource,
            pullDisabled: !model.hasCurrentTopic || model.activeSummary != nil || model.activePull != nil,
            onExport: onExport,
            onExpand: onExpand
        )
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
                withAnimation(DCMotion.respecting(reduceMotion)) { onDismissCitationTip() }
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
                        app.startSummary(batchLimit: limit, regenerate: model.hasSummaryOnSession)
                    } label: {
                        if limit == model.summaryBatchLimit {
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
                model.hasSummaryOnSession ? "Check for new replies" : "Create summary",
                systemImage: model.hasSummaryOnSession ? "arrow.triangle.2.circlepath" : "sparkles"
            )
            .frame(maxWidth: .infinity)
        } primaryAction: {
            DCHaptics.tap()
            app.startSummary()
        }
        .accessibilityIdentifier("createSummary")
        .disabled(!model.hasCurrentTopic || model.activeSummary != nil || model.activePull != nil)

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
private struct ChatThread: View, Equatable {
    struct Model: Equatable {
        let topicKey: String; let hasSummaryOnSession: Bool; let hasLeadingContent: Bool; let hasConversation: Bool
        let runsContext: AgentRunsContext
        let cardRowID: UUID?; let activeCitation: Int?; let showsCitationTip: Bool
        let requestedProviderSetup: Bool; let expandedToolRowIDs: Set<UUID>
    }

    let model: Model
    let summarySlice: SliceBox<SummaryAppSlice>
    let app: AppModel
    let session: BrowserAgentSession
    let strippedSummaryCache: StrippedSummaryCache
    let exportShareAnchor: ExportShareAnchor
    @Binding var showsCitationTip: Bool
    @Binding var expandedToolRowIDs: Set<UUID>
    @Binding var requestedProviderSetup: Bool
    let onExport: (ExportDelivery) -> Void
    let onExpand: (ExpandedPanelRoute) -> Void
    let onOpenURL: (URL) -> Void
    @State private var atBottom = true
    @State private var follow = TranscriptFollowPlumbing()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && ObjectIdentifier(lhs.app) == ObjectIdentifier(rhs.app) && ObjectIdentifier(lhs.session) == ObjectIdentifier(rhs.session)
    }

    private var hasConversationEntries: Bool { model.hasConversation }

    private var isCompletelyEmpty: Bool {
        !model.hasLeadingContent && !hasConversationEntries
    }

    private func summaryObserver(isCardFooter: Bool) -> SummarySectionObserver {
        SummarySectionObserver(
            slice: summarySlice, app: app, session: session, isCardFooter: isCardFooter,
            strippedSummaryCache: strippedSummaryCache, exportShareAnchor: exportShareAnchor,
            showsCitationTip: $showsCitationTip, requestedProviderSetup: $requestedProviderSetup,
            onExport: onExport, onExpand: onExpand
        )
    }

    var body: some View {
        let _ = PerfProbe.hit("ChatThread.body")
        ScrollViewReader { proxy in
            // A ZStack, not a VStack: the jump button floats over the text with no row of its own.
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id("chatTop")

                        VStack(alignment: .leading, spacing: 12) {
                            if model.hasLeadingContent {
                                summaryObserver(isCardFooter: false)
                                    .accessibilityElement(children: .contain)
                                    .accessibilitySortPriority(2)
                            }

                            if model.hasConversation {
                                BrowserAgentRunsView(
                                    app: app,
                                    session: session,
                                    context: model.runsContext,
                                    expandedToolRowIDs: $expandedToolRowIDs,
                                    onOpenURL: onOpenURL
                                )
                                .accessibilitySortPriority(1)
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
                            .onAppear { if #unavailable(iOS 18.0) { apply(.bottomAnchorChanged(isVisible: true), proxy: proxy) } }
                            .onDisappear { if #unavailable(iOS 18.0) { apply(.bottomAnchorChanged(isVisible: false), proxy: proxy) } }
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: Int.self) { Int($0.size.height.rounded()) } action: { newHeight in
                        apply(.contentGrew(height: newHeight, isRunning: session.isRunning || follow.finishingLayoutTurn), proxy: proxy)
                    }
                }
                .defaultScrollAnchor(.top)
                .modifier(ChatScrollTracker(
                    onEvent: { apply($0, proxy: proxy) },
                    isRunning: { session.isRunning || follow.finishingLayoutTurn }
                ))
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("agentScroll")
                .background {
                    TranscriptSessionEvents(
                        session: session,
                        follow: follow,
                        expandedToolRowIDs: $expandedToolRowIDs,
                        onEvent: { apply($0, proxy: proxy) },
                        onAnnounce: announceAgentStateIfNeeded
                    )
                }
                .onAppear {
                    #if DEBUG
                    if AssistantDebug.has("-dc-browser-agent-expand-first-tool"),
                       expandedToolRowIDs.isEmpty,
                       let first = session.runs.first?.toolCalls.first {
                        expandedToolRowIDs.insert(first.id)
                    }
                    #endif
                }
                .onChange(of: model.hasSummaryOnSession, initial: true) {
                    // Once, with the first summary that has post numbers (top section or conversation card).
                    let key = PresentationRouter.citationTipKey
                    guard app.currentSession?.hasSummary == true, !UserDefaults.standard.bool(forKey: key),
                          !PostCitations.numbers(in: app.currentSession?.summary ?? "").isEmpty else { return }
                    UserDefaults.standard.set(true, forKey: key)
                    showsCitationTip = true
                }
                .onChange(of: model.topicKey) {
                    apply(.topicChanged(hasRuns: !session.runs.isEmpty), proxy: proxy)
                }
                .onDisappear {
                    apply(.disappeared, proxy: proxy)
                }
                if !atBottom, hasConversationEntries {
                    Button {
                        apply(.jumpTapped, proxy: proxy)
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
                    .padding(.vertical, 8)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                    .accessibilityLabel("Scroll to latest message")
                    .accessibilityIdentifier("chatScrollToBottom")
                }
            }
            .animation(DCMotion.respecting(reduceMotion, DCMotion.quick), value: !atBottom && hasConversationEntries)
        }
        .environment(\.activeCitation, model.activeCitation)
        .environment(\.threadSummaryCardFooter, model.cardRowID.map {
            ThreadSummaryCardFooter(rowID: $0, content: AnyView(summaryObserver(isCardFooter: true)))
        })
        .id(ObjectIdentifier(session))
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

    private func apply(_ event: TranscriptFollow.Event, proxy: ScrollViewProxy) {
        let (next, effect) = follow.state.transition(event)
        follow.state = next
        if !next.isSettling, follow.scrollTask != nil {
            follow.cancelSettle()
        }
        if atBottom != next.isAtBottom {
            atBottom = next.isAtBottom
        }
        switch effect {
        case .none:
            break
        case .scrollNow(let anchor, let afterTurn):
            if anchor == .top {
                follow.cancelBottomScroll()
                scrollUnanimated(anchor.scrollID, anchor: .top, proxy: proxy)
            } else if !follow.state.isSettling {
                follow.scheduleBottomScroll(proxy: proxy, session: session)
            }
            switch afterTurn {
            case nil:
                break
            case .recheckBottom(let clearPinning)?:
                DispatchQueue.main.async {
                    apply(.followUp(.recheckBottom(clearPinning: clearPinning)), proxy: proxy)
                }
            case .syncTopicTop?:
                Task { @MainActor in
                    apply(.followUp(.syncTopicTop), proxy: proxy)
                }
            }
        case .settleToBottom(let interruptMomentum):
            let targetID = follow.currentSettleTargetID(session: session)
            follow.cancelSettle()
            if interruptMomentum {
                // An immediate scroll interrupts any momentum before the settling animation.
                scrollUnanimated(targetID, proxy: proxy)
            }
            let token = UUID()
            follow.settleID = token
            #if DEBUG
            ChatScrollProbe.begin(token)
            #endif
            follow.scrollTask = Task { @MainActor in
                #if DEBUG
                defer { ChatScrollProbe.end(token) }
                #endif
                if UIView.areAnimationsEnabled {
                    withAnimation(.easeOut(duration: reduceMotion ? 0.04 : 0.16)) {
                        proxy.scrollTo(targetID, anchor: .bottom)
                    }
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 180))
                } else {
                    scrollUnanimated(targetID, proxy: proxy)
                    try? await Task.sleep(for: .milliseconds(16))
                }
                let bottomID = TranscriptFollow.Anchor.bottom.scrollID
                var snappedBottomInset = targetID == bottomID
                var settledPasses = 0
                var previousHeight = follow.state.contentHeight
                let requiredSettledPasses = interruptMomentum ? 8 : 1
                for _ in 0..<24 {
                    if Task.isCancelled || follow.state.isUserScrolling { break }
                    let currentHeight = follow.state.contentHeight
                    if !follow.state.nearBottom || currentHeight != previousHeight {
                        settledPasses = 0
                        snappedBottomInset = targetID == bottomID
                        scrollUnanimated(targetID, proxy: proxy)
                    } else if !snappedBottomInset {
                        snappedBottomInset = true
                        scrollUnanimated(bottomID, proxy: proxy)
                    } else {
                        settledPasses += 1
                        if settledPasses >= requiredSettledPasses { break }
                    }
                    previousHeight = currentHeight
                    try? await Task.sleep(for: .milliseconds(16))
                }
                guard !Task.isCancelled, follow.settleID == token else { return }
                follow.scrollTask = nil
                apply(.settleFinished, proxy: proxy)
            }
        }
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

private struct SummaryMoreMenu: View {
    let app: AppModel
    let exportShareAnchor: ExportShareAnchor
    let exportDisabled: Bool
    let hasSource: Bool
    let pullDisabled: Bool
    let onExport: (ExportDelivery) -> Void
    let onExpand: (ExpandedPanelRoute) -> Void
    @State private var isPreparingExport = false

    var body: some View {
        Menu {
            Section {
                Button(action: copyExport) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("copyExport")
                .disabled(exportDisabled || isPreparingExport)

                Button(action: shareExport) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("shareExport")
                .disabled(exportDisabled || isPreparingExport)

                Button(action: exportFile) {
                    Label("Export .txt", systemImage: "arrow.down.doc")
                }
                .accessibilityIdentifier("exportExport")
                .disabled(exportDisabled || isPreparingExport)

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
                .disabled(!hasSource)

                Button {
                    app.pullTopic()
                } label: {
                    Label("Pull Post + Replies Only", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("pullPost")
                .disabled(pullDisabled)
            }

            Section {
                Button {
                    if let target = app.aiSummaryReportTarget() {
                        app.reportAIOutput(target)
                    }
                } label: {
                    Label("Report this summary", systemImage: "flag")
                }
                .accessibilityIdentifier("reportSummary")
                .disabled(exportDisabled)
            }
        } label: {
            Group {
                if isPreparingExport {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 32, minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPreparingExport)
        .background(exportShareAnchor)
        .accessibilityLabel(Text("Summary actions", comment: "Accessibility label of the summary card's more menu"))
        .accessibilityIdentifier("summaryMoreMenu")
    }

    private func copyExport() {
        guard !isPreparingExport else { return }
        let payload = app.currentExportPayload
        let options = app.exportOptions
        isPreparingExport = true
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                PerfProbe.time("AssistantPanel.exportText") {
                    payload.text(options: options)
                }
            }.value
            UIPasteboard.general.string = text
            DCHaptics.success()
            isPreparingExport = false
        }
    }

    private func shareExport() {
        prepareDelivery { exportShareAnchor.present($0) }
    }

    private func exportFile() {
        prepareDelivery { onExport($0) }
    }

    private func prepareDelivery(_ deliver: @escaping (ExportDelivery) -> Void) {
        guard !isPreparingExport else { return }
        let payload = app.currentExportPayload
        let options = app.exportOptions
        let slug = DrawerInputs.exportSlug(for: app)
        isPreparingExport = true
        Task {
            do {
                let delivery = try await Task.detached(priority: .userInitiated) {
                    try TopicExportFile.prepare(payload: payload, options: options, slug: slug)
                }.value
                deliver(delivery)
            } catch {
                app.presentError(error.localizedDescription)
            }
            isPreparingExport = false
        }
    }
}

/// How an export leaves the app: inline text under the limit, a temporary `.txt` file over it.
enum ExportDelivery: Equatable, Sendable {
    case text(String, slug: String)
    case file(URL)
}

/// Builds export text off the main thread and writes long exports to a temporary `.txt` file
/// (`docs/wukongmind/design-performance-2.md`, decision 1).
enum TopicExportFile {
    /// Text above this character count is handed over as `wukongmind-<slug>.txt` instead of an
    /// inline string. Probed on iPhone 13 (iOS 27.2.1): Messages opens 7k chars immediately,
    /// stalls >3 s and overflows its compose sheet at 50k chars, stalls >6 s at 100k, and stays
    /// blank >10 s at 200k+. 20,000 keeps short threads and summary-only exports inline.
    static let inlineCharacterLimit = 20_000
    private static let tempFolderPrefix = "wukongmind-export-"

    static func filename(slug: String) -> String {
        let safe = slug
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "wukongmind-\(safe).txt"
    }

    static func prepare(
        payload: TopicExportPayload,
        options: ExportOptions,
        slug: String,
        limit: Int = inlineCharacterLimit,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> ExportDelivery {
        let text = PerfProbe.time("AssistantPanel.exportText") {
            payload.text(options: options)
        }
        guard text.count > limit else {
            return .text(text, slug: slug)
        }
        let folder = temporaryDirectory
            .appendingPathComponent("\(tempFolderPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(filename(slug: slug))
        try Data(text.utf8).write(to: url, options: .atomic)
        return .file(url)
    }

    /// Removes the temporary folder created by `prepare`. Safe even after `fileMover` moves the file out.
    static func removeTemporaryFile(at url: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix(tempFolderPrefix) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Anchors the system share popover to the summary's More button on iPad.
struct ExportShareAnchor: UIViewRepresentable {
    @MainActor
    private final class Storage {
        lazy var view = UIView()
    }

    private let storage = Storage()

    func makeUIView(context: Context) -> UIView {
        let view = storage.view
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func present(_ delivery: ExportDelivery) {
        let anchor = storage.view
        let item: ExportActivityItem
        let tempFileURL: URL?
        switch delivery {
        case .text(let text, _):
            item = ExportActivityItem(text: text)
            tempFileURL = nil
        case .file(let url):
            item = ExportActivityItem(fileURL: url)
            tempFileURL = url
        }
        // Let SwiftUI finish the menu action before presenting UIKit's sheet.
        DispatchQueue.main.async {
            guard anchor.window != nil else {
                if let tempFileURL { TopicExportFile.removeTemporaryFile(at: tempFileURL) }
                return
            }
            var responder: UIResponder? = anchor
            while let current = responder, !(current is UIViewController) {
                responder = current.next
            }
            guard let presenter = responder as? UIViewController, presenter.presentedViewController == nil else {
                if let tempFileURL { TopicExportFile.removeTemporaryFile(at: tempFileURL) }
                return
            }
            let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
            if let tempFileURL {
                controller.completionWithItemsHandler = { _, _, _, _ in
                    TopicExportFile.removeTemporaryFile(at: tempFileURL)
                }
            }
            controller.popoverPresentationController?.sourceView = anchor
            controller.popoverPresentationController?.sourceRect = anchor.bounds
            presenter.present(controller, animated: true)
        }
    }
}

/// Shares either an inline string (short exports) or a temporary `.txt` file URL (long exports).
final class ExportActivityItem: NSObject, UIActivityItemSource {
    enum Content: Equatable {
        case text(String)
        case file(URL)
    }

    let content: Content

    init(text: String) { self.content = .text(text) }
    init(fileURL: URL) { self.content = .file(fileURL) }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        switch content {
        case .text(let text): return text
        case .file(let url): return url
        }
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        switch content {
        case .text(let text): return text
        case .file(let url): return url
        }
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        switch content {
        case .text: return ""
        case .file(let url): return url.lastPathComponent
        }
    }
}

/// The citation-free summary, recomputed only when the summary text changes.
/// A reference so `body` can fill it without writing view state.
final class StrippedSummaryCache {
    private var source: String?
    private var value = ""

    func stripped(_ summary: String) -> String {
        if summary != source {
            source = summary
            value = PostCitations.stripped(summary)
        }
        return value
    }
}

struct PlainTextDocument: FileDocument {
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

#if DEBUG
/// `-dc-perf-probe`: the probe's cumulative numbers as an accessibility element
/// (`perfProbeState`) for the long-thread UI test, refreshed twice a second.
struct PerfProbeState: View {
    let app: AppModel
    @ObservedObject private var tabs: BrowserTabs
    @State private var state = ""
    private let ticks = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(app: AppModel) {
        self.app = app
        self.tabs = app.tabs
    }

    private func currentState() -> String {
        let main = PerfProbe.mainThreadReport
        let probe = PerfProbe.snapshot
        let session = app.currentSession
        var fields = [
            "passes=\(main.passes)", "busy_ms=\(Int(main.busySeconds * 1_000))"
        ]
        for (index, threshold) in PerfProbe.MainThreadReport.thresholds.enumerated() {
            fields.append("over\(Int(threshold * 1_000))=\(main.over[index])")
        }
        for name in ["AssistantPanel.body", "DrawerHeader.body", "DrawerSummary.body", "DrawerSummarySections.body",
                     "ChatThread.body", "BrowserAgentRunsView.runSection", "MarkdownBlockView.body",
                     "publish.AppModel", "publish.ForumBrowserModel", "publish.DrawerPageFacts",
                     "publish.StreamStore", "publish.VoiceController", "publish.PresentationRouter"] {
            fields.append("n:\(name)=\(probe.counts[name] ?? 0)")
        }
        for name in ["AssistantPanel.exportText", "AssistantPanel.exportDisabled", "TopicExportPayload.text", "DrawerSummarySections.parsed", "AssistantPanel.strippedSummary",
                     "AssistantPanel.summaryPlacement", "AssistantPanel.matchingPageScripts",
                     "BrowserAgentRunsView.timeline", "BrowserAgentRunsView.forumSources",
                     "AssistantPanel.buildHeader", "AssistantPanel.buildThread", "AssistantPanel.buildFooter"] {
            fields.append("n:\(name)=\(probe.counts[name] ?? 0)")
            fields.append("us:\(name)=\(Int((probe.seconds[name] ?? 0) * 1_000_000))")
        }
        fields.append("source_chars=\(session?.source.count ?? 0)")
        fields.append("summary_chars=\(session?.summary.count ?? 0)")
        fields.append("posts=\(session?.totalPosts ?? 0)")
        fields.append("runs=\(app.browserAgent.runs.count)")
        return fields.joined(separator: " ")
    }

    var body: some View {
        Text(verbatim: state)
            .font(.system(size: 2))
            .frame(width: 4, height: 4)
            .opacity(0.02)
            .allowsHitTesting(false)
            .accessibilityLabel(Text(verbatim: state))
            .accessibilityIdentifier("perfProbeState")
            .onAppear {
                PerfProbe.startMainThreadMonitor()
                state = currentState()
            }
            .onReceive(ticks) { _ in state = currentState() }
            // Who publishes: every one of these re-evaluates each view that observes the object.
            .onReceive(app.objectWillChange) { _ in PerfProbe.hit("publish.AppModel") }
            .onReceive(tabs.currentTab.browser.objectWillChange) { _ in PerfProbe.hit("publish.ForumBrowserModel") }
            .onReceive(app.streams.objectWillChange) { _ in PerfProbe.hit("publish.StreamStore") }
            .onReceive(app.voice.objectWillChange) { _ in PerfProbe.hit("publish.VoiceController") }
            .onReceive(app.router.objectWillChange) { _ in PerfProbe.hit("publish.PresentationRouter") }
    }
}

@MainActor
enum ChatScrollProbe {
    private static var activeToken: UUID?

    static var isSettling: Bool { activeToken != nil }

    static func begin(_ token: UUID) {
        activeToken = token
    }

    static func end(_ token: UUID) {
        if activeToken == token {
            activeToken = nil
        }
    }

    static func reset() {
        activeToken = nil
    }
}
#endif

@MainActor
private final class TranscriptFollowPlumbing {
    var state = TranscriptFollow()
    var scrollTask: Task<Void, Never>?
    var settleID = UUID()
    var finishingLayoutTurn = false
    private var pendingBottomScroll = false
    private var bottomBlockScheduled = false

    func currentSettleTargetID(session: BrowserAgentSession) -> String {
        let latestVoice = session.messages.last(where: \.role.isVoice)
        if let latestRun = session.runs.last, latestVoice.map({ $0.createdAt <= latestRun.startedAt }) ?? true {
            return BrowserAgentRunsView.scrollID(for: latestRun.id)
        }
        return TranscriptFollow.Anchor.bottom.scrollID
    }

    func cancelBottomScroll() {
        pendingBottomScroll = false
    }

    func scheduleBottomScroll(proxy: ScrollViewProxy, session: BrowserAgentSession) {
        pendingBottomScroll = true
        guard !bottomBlockScheduled else { return }
        bottomBlockScheduled = true
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bottomBlockScheduled = false
                guard self.pendingBottomScroll else { return }
                self.pendingBottomScroll = false
                guard !self.state.isSettling, !self.state.isUserScrolling, !self.state.phase.isScrolledUp else { return }
                let target = self.state.nearBottom
                    ? TranscriptFollow.Anchor.bottom.scrollID
                    : self.currentSettleTargetID(session: session)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(target, anchor: .bottom) }
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func cancelSettle() {
        pendingBottomScroll = false
        scrollTask?.cancel()
        scrollTask = nil
        #if DEBUG
        ChatScrollProbe.reset()
        #endif
    }
}

private struct TranscriptSessionEvents: View {
    struct StepStamp: Equatable {
        let toolCalls: Int
        let state: BrowserAgentRunState
    }
    let session: BrowserAgentSession
    let follow: TranscriptFollowPlumbing
    @Binding var expandedToolRowIDs: Set<UUID>
    let onEvent: (TranscriptFollow.Event) -> Void
    let onAnnounce: (BrowserAgentRunState) -> Void

    var body: some View {
        let runs = session.runs
        let runsCount = runs.count
        let voiceCount = session.messages.contains(where: \.role.isVoice)
            ? session.messages.reduce(0) { $0 + ($1.role.isVoice ? 1 : 0) }
            : 0
        let step = StepStamp(toolCalls: runs.last?.toolCalls.count ?? 0, state: session.runState)
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            .onChange(of: runsCount) { oldCount, newCount in
                if newCount > oldCount { onEvent(.runAdded) }
            }
            .onChange(of: voiceCount) { oldCount, newCount in
                if newCount > oldCount { onEvent(.voiceTurnAdded) }
            }
            .onChange(of: step) { oldStep, newStep in
                #if DEBUG
                if newStep.toolCalls != oldStep.toolCalls,
                   AssistantDebug.has("-dc-browser-agent-expand-first-tool"),
                   expandedToolRowIDs.isEmpty,
                   let first = session.runs.first?.toolCalls.first {
                    expandedToolRowIDs.insert(first.id)
                }
                #endif
                if oldStep.state.isRunning, !newStep.state.isRunning {
                    follow.finishingLayoutTurn = true
                    DispatchQueue.main.async { follow.finishingLayoutTurn = false }
                }
                onEvent(.runStepChanged)
                if newStep.state != oldStep.state {
                    onAnnounce(newStep.state)
                }
            }
    }
}

/// Forwards scroll phase and geometry events from `ChatThread` into `TranscriptFollow`
/// (iOS 18+; older systems use the bottom anchor's appear/disappear instead).
private struct ChatScrollTracker: ViewModifier {
    let onEvent: (TranscriptFollow.Event) -> Void
    let isRunning: () -> Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    onEvent(phase == .interacting ? .dragBegan : .dragEnded(decelerating: phase == .decelerating))
                }
                .onScrollGeometryChange(for: TranscriptFollow.Geometry.self) { geometry in
                    TranscriptFollow.Geometry(
                        contentHeight: geometry.contentSize.height,
                        viewportHeight: geometry.visibleRect.height,
                        visibleMaxY: geometry.visibleRect.maxY,
                        offsetY: geometry.contentOffset.y
                    )
                } action: { old, new in
                    onEvent(.geometryChanged(old: old, new: new, isRunning: isRunning()))
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
    let app: AppModel
    let podcast: PodcastController
    let router: PresentationRouter
    let voice: VoiceController
    fileprivate var slice: SliceBox<DrawerStatusRowBody.Model>? = nil
    /// Over History or Settings: only voice.
    var voiceOnly: Bool? = nil

    init(app: AppModel, podcast: PodcastController, router: PresentationRouter, voice: VoiceController, voiceOnly: Bool? = nil) {
        self.app = app; self.podcast = podcast; self.router = router; self.voice = voice; self.voiceOnly = voiceOnly
    }

    fileprivate init(app: AppModel, podcast: PodcastController, router: PresentationRouter, voice: VoiceController, slice: SliceBox<DrawerStatusRowBody.Model>) {
        self.app = app; self.podcast = podcast; self.router = router; self.voice = voice; self.slice = slice
    }

    var voiceStatusText: String? {
        if let session = voice.session, voice.isActive {
            return "\(VoiceSessionBar.stateText(session)) · \(DockText.clock(session.connectedSeconds))"
        }
        return voice.inactiveBarMessage
    }

    var body: some View {
        if let slice {
            StatusRowSliceObserver(slice: slice, app: app, podcast: podcast, router: router, voice: voice)
        } else {
            StandaloneStatusRowObserver(app: app, podcast: podcast, router: router, voice: voice, voiceOnly: voiceOnly)
        }
    }
}

private struct StatusRowSliceObserver: View {
    @ObservedObject var slice: SliceBox<DrawerStatusRowBody.Model>
    let app: AppModel
    let podcast: PodcastController
    let router: PresentationRouter
    let voice: VoiceController

    var body: some View {
        DrawerStatusRowBody(
            model: slice.value, app: app, podcast: podcast, router: router, voice: voice,
            activeSession: voice.isActive ? voice.session : nil
        )
        .equatable()
    }
}

private struct StandaloneStatusRowObserver: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    @ObservedObject var router: PresentationRouter
    @ObservedObject var voice: VoiceController
    let voiceOnly: Bool?

    var body: some View {
        DrawerStatusRowBody(
            model: .init(app: app, podcast: podcast, voice: voice, voiceOnly: voiceOnly),
            app: app, podcast: podcast, router: router, voice: voice,
            activeSession: voice.isActive ? voice.session : nil
        )
        .equatable()
    }
}

private struct DrawerStatusRowBody: View, Equatable {
    struct Model: Equatable {
        var voiceSessionID: ObjectIdentifier?
        var inactiveMessage: String?
        var inactiveIsWarning = false
        var isVoiceOnly = false
        var research: WorkRecord?
        var readyAnswer: WorkRecord?
        var cardsCursor: BrowseCursor?

        init() {}

        @MainActor
        init(app: AppModel, podcast: PodcastController, voice: VoiceController, voiceOnly: Bool?) {
            let vo = voiceOnly ?? (app.panelRoute != .topic)
            let activeSession = voice.isActive ? voice.session : nil
            let showsChip = !vo && app.isAIViewShown && app.browseCursor.showsInDrawer && app.browseCursor.matches(app.pageContext)
            voiceSessionID = activeSession.map(ObjectIdentifier.init)
            inactiveMessage = activeSession == nil ? voice.inactiveBarMessage : nil
            inactiveIsWarning = voice.inactiveBarIsWarning
            isVoiceOnly = vo
            research = vo ? nil : app.activeResearch
            readyAnswer = vo ? nil : app.readyAnswer
            cardsCursor = showsChip ? app.browseCursor : nil
        }
    }

    let model: Model
    let app: AppModel
    let podcast: PodcastController
    let router: PresentationRouter
    let voice: VoiceController
    let activeSession: VoiceSession?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && ObjectIdentifier(lhs.app) == ObjectIdentifier(rhs.app)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session = activeSession {
                DrawerVoiceStatus(session: session) {
                    voice.end()
                    voice.dismiss()
                }
            } else if let message = model.inactiveMessage {
                DrawerVoiceInactiveStatus(
                    message: message,
                    isWarning: model.inactiveIsWarning,
                    dismiss: voice.dismiss
                )
            } else if model.isVoiceOnly {
                EmptyView()
            } else if let research = model.research {
                DrawerResearchStatus(record: research, progress: app.progress) {
                    showAnswer(for: research)
                }
            } else if let readyAnswer = model.readyAnswer {
                row(
                    systemImage: "checkmark.circle.fill",
                    text: String(localized: "Answer ready", comment: "AI drawer status row: an Ask the forum answer finished")
                ) {
                    showAnswer(for: readyAnswer)
                }
            }
            // The strip over the page is hidden while the AI view is up.
            if let cursor = model.cardsCursor {
                DrawerCardsChip(cursor: cursor, app: app, router: router)
            }
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
    let cursor: BrowseCursor
    let app: AppModel
    @ObservedObject var router: PresentationRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

/// While the summary is written and no text has come yet: three still lines.
private struct SummaryPlaceholder: View {
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
        .accessibilityElement()
        .accessibilityLabel(Text("Writing summary…"))
        .accessibilityIdentifier("summaryPlaceholder")
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
        PerfProbe.time("DrawerSummarySections.parsed") { parsedUntimed(for: input) }
    }

    private static func parsedUntimed(for input: Input) -> (sections: Int, hasCitations: Bool, rows: [MarkdownRow]) {
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
        let _ = PerfProbe.hit("DrawerSummarySections.body")
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
    let totalPosts: Int?
    let summaryPostCount: Int?
    let onCheck: () -> Void

    private var newReplies: Int? {
        guard let total = totalPosts, let summarized = summaryPostCount, total > summarized else { return nil }
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
