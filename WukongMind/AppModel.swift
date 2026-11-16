import BackgroundTasks
import Combine
import Foundation
import SwiftUI
import UIKit
import UserNotifications
import WebKit

// MARK: - AppModel API for the UI (multi-forum)
//
// Forums (see ForumDirectory.swift for `Forum` / `SuggestedForum`):
// - `forums`                        every added/visited forum (published)
// - `pinnedForums`                  pinned, in the user's order
// - `recentForums`                  unpinned, most recently visited first
// - `AppModel.suggestedForums`      well-known forums offered before adding
// - `currentForum`                  forum of the current page, else the last one shown (computed from `currentSiteURL`)
// - `forum(for:)`                   directory entry for a site URL
// - `addForum(fromAddress:pin:)`    validates a URL/host via basic-info.json, adds it
// - `pin(_:)` / `unpin(_:)` / `togglePin(_:)` / `movePinned(fromOffsets:toOffset:)`
// - `removeForum(_:deleteData:)`    optionally deletes its summaries/chats/runs/watches
// - `openForum(_:)`                 loads its /latest in the browser
// - `recordVisit(siteURL:kind:name:iconURL:)` called automatically for detected forum pages
//
// Page and assistant:
// - `pageContext`                   browser page state (.loading/.notForum/.maybe/.forumHome/.topic)
// - `currentTopic`, `currentSession` topic of the page and its saved session
// - `isProviderReady(for:)`         a role's model can run (key present when required);
//                                   roles and model selection: AppModel+Models.swift
// - `agentRuns`                     saved answers (old Research runs and Agent answers),
//                                   read-only in History's `SavedAnswerView`
// - `sessions` is keyed by topic key (`host[/basePath]/t/{id}`); per-topic calls take
//   `topicKey:` (`setKept`, `deleteSession`, `setInstructions`, `isWatched`, `unwatch`,
//   `markWatchedSeen`)
//
// Onboarding / hand-off:
// - `settings.hasCompletedOnboarding`, `completeOnboarding()`
// - `handle(_ request: IncomingLinkRequest)` share-extension / deep-link hand-off (deduped by id)
// - `drainSharedInbox()`            deliver the App Group inbox (also runs on scene .active)
// - `openShared(url:action:)`       open a shared link; "summary" | "chat" | "agent" | "open"
// - `requestAssistant()`            a hand-off wants the Assistant pane (`assistantRequest`)
// - `needsProviderSetup`            the role a hand-off needs a provider for (UI resets it)
// - `handleDeepLink(_:)`            wukongmind://open?url=…&action=…
//
// Ad and tracker blocking: see AppModel+ContentBlocking.swift.
//
// Post-level browsing (AppModel+Navigation.swift): `openTopic(_:at:)`,
// `focus(_:)`, `find(_:scope:)`, `next()` / `previous()`, `read(post:)`,
// `openLink(_:)`; the current list is
// `browseCursor`, page changes for the voice layer arrive on `pageChanges`.

/// What the AI view shows: the topic, or (split layout) History in place.
/// Settings is always a sheet: inside the split panel its navigation stack
/// would be nested in the page's and lose its bar.
enum PanelRoute: String, CaseIterable {
    case topic = "Topic"
    case history = "History"
}

/// A request to open the audit log, optionally at one step of one task.
struct AuditLogRequest: Identifiable, Equatable {
    var taskID: String?
    var step: Int?
    var id: String { "\(taskID ?? "all")-\(step ?? 0)" }
}

enum AssistantMode: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case browserAgent = "BrowserAgent"

    var id: String { rawValue }
}

enum AgentError: LocalizedError {
    case missingArgument(String)
    /// The argument's name and why it is wrong (model-visible, recoverable).
    case invalidArgument(String, reason: String)
    /// The site has closed its comment search; the run goes on without it.
    case commentsUnavailable
    case topicBudgetExhausted(Int)
    /// The tool asked for and the names this run offers.
    case unknownTool(String, available: [String])
    case runNotFound
    case queueFull

    /// Shown in the step list (localized).
    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            String(localized: "Missing argument \"\(name)\".", comment: "Ask the forum step error; the placeholder is a technical argument name such as query or topic_id")
        case .invalidArgument(let name, let reason):
            String(localized: "Invalid argument \"\(name)\": \(reason)", comment: "Ask the forum step error; the first placeholder is a technical argument name, the second the reason (English)")
        case .commentsUnavailable:
            String(localized: "This site does not allow searching comments. Use search_forum and read_topic instead.", comment: "Ask the forum step error: the WordPress site closed its comment search")
        case .topicBudgetExhausted(let limit):
            String(localized: "The topic-read budget (\(limit)) is used up; answer with what you have.", comment: "Ask the forum step error; the number is the maximum topic reads per run")
        case .unknownTool(let name, let available):
            String(localized: "Unknown tool \"\(name)\". Available: \(available.joined(separator: ", "))", comment: "Ask the forum step error; placeholders are technical tool names")
        case .runNotFound:
            String(localized: "The agent run no longer exists.")
        case .queueFull:
            String(localized: "The task queue is full. Cancel or wait for an existing task.")
        }
    }

    /// Handed back to the model as the tool's observation: always English,
    /// like the rest of the prompt.
    var modelDescription: String {
        switch self {
        case .missingArgument(let name): "Missing argument \"\(name)\"."
        case .invalidArgument(let name, let reason): "Invalid argument \"\(name)\": \(reason)"
        case .commentsUnavailable:
            "COMMENTS_UNAVAILABLE: This site does not allow searching comments. Use search_forum and read_topic instead."
        case .topicBudgetExhausted(let limit):
            "The topic-read budget (\(limit)) is used up; answer with what you have."
        case .unknownTool(let name, let available):
            "Unknown tool \"\(name)\". Available: \(available.joined(separator: ", "))"
        case .runNotFound: "The agent run no longer exists."
        case .queueFull: "The task queue is full."
        }
    }
}

/// Outcome of a provider test or model load.
enum ProviderCheckResult: Equatable {
    case success
    case failure(String)
    /// The provider settings changed (or a newer check started) before it
    /// finished; the result was dropped.
    case stale
}

enum WatchCheckReason {
    case foreground
    case manual
    case background
}

@MainActor
final class AppModel: ObservableObject {
    /// Edits apply at once: work that has not started yet uses them, work
    /// already running keeps the values it started with (`RunSettings`). Every
    /// change is persisted, coalesced (see `saveSettings()`).
    @Published var settings: AppSettings {
        didSet {
            settingsDidChange(from: oldValue)
        }
    }
    @Published private(set) var sessions: [String: TopicSession] {
        didSet { spotlightDataDidChange() }
    }
    @Published private(set) var activities: [WorkRecord]
    @Published private(set) var currentTopic: ForumTopic?
    @Published var panelRoute: PanelRoute = .topic
    /// Shared between the inline panel and its full-screen copy so opening the
    /// assistant full screen keeps the same mode.
    @Published var assistantMode: AssistantMode = .summary
    /// Streaming summary and chat text; observed by the views that show it
    /// only, not by this model (`StreamStore`).
    let streams = StreamStore()
    /// Live 0…1 progress of running work; observed only by the views that
    /// draw a progress bar, ring or percentage (`ProgressStore`).
    let progress = ProgressStore()
    /// Unsent composer text. Not published here: it changes on every
    /// keystroke, so only the Ask box and the composers observe it.
    let drafts = ComposerDrafts()
    /// Errors waiting for the root alert, oldest first: one shows at a time
    /// and a newer one never replaces it (`presentError`).
    @Published private(set) var errorQueue: [PresentedError] = []
    @Published var settingsStatus = ""
    /// Models each provider offers, from the last successful load.
    @Published var discoveredModels: [AIProvider: [DiscoveredModel]] = [:]
    /// The saved Agent answer History shows (`SavedAnswerView`); nil shows the list.
    @Published var savedAnswerRunID: UUID?
    @Published private(set) var agentRuns: [AgentRun]
    @Published private(set) var watchedTopics: [WatchedTopic]
    /// Bumped to focus the Ask box (⌘2, ⌘3).
    @Published var askFocusRequest = 0
    @Published private(set) var notificationsAuthorized = false
    /// The user's forums (pinned and recent); see the API list above.
    @Published private(set) var forums: [Forum] {
        didSet {
            spotlightDataDidChange()
            if forums.map(\.siteURL) != oldValue.map(\.siteURL) || forums.map(\.name) != oldValue.map(\.name) {
                forumsDidChangeForShortcuts()
            }
        }
    }
    /// The forum of the current page, or the last forum shown.
    @Published private(set) var currentSiteURL: String?
    /// Where Add forum is: detecting the platform of an address, then the
    /// outcome. One detection per address at a time.
    @Published private(set) var addForumPhase = AddForumPhase.idle
    private var addForumTask: (key: AddForumRequest, task: Task<Forum, Error>)?
    /// Bumped when a hand-off (shared link, Siri, Spotlight) wants the
    /// Assistant shown (`requestAssistant()`); the root view shows it once
    /// per new value.
    @Published private(set) var assistantRequest = 0
    /// A hand-off needed this role's model, which is not ready yet.
    @Published var needsProviderSetup: ModelRole?
    /// Recent daily digests, newest first (AppModel+Digest.swift; device-local).
    @Published var digests: [DailyDigest] = []
    /// What making today's digest is doing (preparing, a card, an error).
    @Published var digestActivity: DigestActivity = .idle
    /// Pages pushed over Home (the Today page, an earlier digest, digest
    /// settings); emptied when Home hides (AppModel+Browse.swift).
    @Published var homePath: [HomeRoute] = []
    /// Where this launch is in the launch rule (HomeState.swift); not
    /// published, nothing draws it.
    var launchPhase: LaunchPhase = .waiting
    /// The current list (search hits, research sources, focused posts) and
    /// the result cards' state (AppModel+Navigation.swift).
    @Published var browseCursor = BrowseCursor()
    /// The last post citation (or solved hint) jumped to: drives the
    /// selection haptic and the filled chip (AppModel+Navigation.swift).
    @Published var citationJump: CitationJump?
    /// A Settings page an outside request wants shown (Start a Voice Chat
    /// without voice set up); RootView presents it and resets it.
    @Published var requestedSettingsPage: SettingsPage?
    /// Script ID to open immediately in `ScriptManagerView` when pushed from
    /// `PageScriptsPopover`; cleared once `ScriptManagerView` consumes it.
    @Published var requestedScriptID: String?
    /// Export toggles shared between AssistantPanel and RouterHost's ExportOptionsSheet.
    @Published var exportOptions = ExportOptions()

    var currentExportPayload: TopicExportPayload {
        let session = currentSession
        return TopicExportPayload(
            summary: session?.summary ?? "",
            source: session?.source ?? "",
            title: session?.title ?? currentTopic?.title ?? "",
            url: session?.url ?? currentTopic?.url,
            history: session?.history ?? [],
            summaryUpdatedAt: session?.summaryUpdatedAt,
            summaryPostCount: session?.summaryPostCount,
            totalPosts: session?.totalPosts
        )
    }

    static var loadsOnlySamplePage: Bool {
        #if DEBUG
        return loadsOnlySamplePage(arguments: ProcessInfo.processInfo.arguments)
        #else
        return false
        #endif
    }

    #if DEBUG
    var suppressesPersistence = AppModel.loadsOnlySamplePage

    static func loadsOnlySamplePage(arguments: [String]) -> Bool {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        return arguments.contains("-dc-sample")
            || value("-dc-browser-agent-demo") != nil
            || value("-dc-browser-agent-live-prompt") != nil
            || arguments.contains("-dc-browser-agent-live-key")
            || arguments.contains("-dc-browser-agent-fixture-page")
            || value("-dc-browser-agent-scripts-box") != nil
            || value("-dc-scripts-sample") != nil
            || arguments.contains("-dc-scripts-sample")
            || value("-dc-m4-import-preview") != nil
            || value("-dc-bar-morph-fixture") != nil
            || value("-dc-fixture-model") != nil
            || arguments.contains("-dc-no-provider")
    }
    #endif

    nonisolated static var suggestedForums: [SuggestedForum] {
        return SiteRegistry.standard.adapters.flatMap(\.suggestedForums.general)
    }

    /// Open browser tabs (`BrowserTabs.swift`); `browser`, `browserAgent`,
    /// `scriptWebController`, `agentConfirmations`, and `agentHTTPClient` reflect
    /// the currently active tab while background tabs keep their own instances.
    let tabs: BrowserTabs
    var browser: ForumBrowserModel { tabs.currentTab.browser }
    private let appBox = WeakBox<AppModel>()
    /// Root sheets, covers and alerts, and the iPhone AI drawer
    /// (PresentationRouter.swift).
    let router = PresentationRouter()
    /// The sites visited, for Home's Sites grid (HomeSites.swift); local to the device.
    let siteVisits = SiteVisitStore()
    /// First-run step 3 over the browser (OnboardingTry.swift); nil when it is not running.
    @Published var firstRun: FirstRunStage?
    /// iCloud (CloudKit) sync (see CloudSyncController.swift).
    let cloudSync: CloudSyncController

    private let store: PersistentStore
    // Also used by the feature slices in other files (AppModel+Digest.swift).
    let forumService: ForumService
    /// Every platform this build reads; tests inject their own.
    let sites: SiteRegistry
    let aiService: AIService
    let notifier: WatchNotifier
    /// The daily digest's files and background task (AppModel+Digest.swift).
    let digestStore: DigestStore
    let backgroundScheduler: BackgroundTaskScheduling
    var digestPrefetch: DigestPrefetch?
    var digestNotifiedDay: String?
    var digestTask: Task<Void, Never>?
    /// The run `digestTask` belongs to; a paused (cancelled) run that is
    /// still unwinding never writes over a newer one.
    var digestRunID: UUID?
    private var openTodayObserver: NSObjectProtocol?
    private let limiter = TaskLimiter(limit: 2)
    /// The task of each job launched (waiting for a worker or running). The
    /// token tells a job that was paused and launched again from the old
    /// task still unwinding.
    private var runningTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var recordWaiters: [UUID: [UUID: CheckedContinuation<WorkRecord?, Never>]] = [:]
    private var summaryFeeds: [UUID: SummaryProgressFeed] = [:]
    /// Extra time to finish work after the app leaves the foreground.
    private let backgroundGrace: BackgroundGracing
    /// The grace period, while the app is in the background with work
    /// running; at its end the work pauses (`pauseActiveWork`).
    private var backgroundWork: UIBackgroundTaskIdentifier?
    private var didRestoreTasks = false
    private var lastWatchCheck: Date?
    private var watchTimer: Task<Void, Never>?
    private var openURLObserver: NSObjectProtocol?
    private var pendingShare: PendingShare?
    private var handledShareIDs: Set<UUID> = []
    private let keyStore: ProviderKeyStore
    /// API keys as last written to the key store; only changed ones are rewritten.
    private var persistedAPIKeys: [AIProvider: String] = [:]
    /// Trailing save for rapid settings edits (slider drags, typing).
    private var settingsSaveTask: Task<Void, Never>?
    /// Per provider: bumped when its key or address changes, or a newer
    /// test or model load starts, so an older result is dropped.
    private var connectionTestGeneration: [AIProvider: Int] = [:]
    private var activeConnectionTestGeneration: [AIProvider: Int] = [:]
    private var activeRoleConnectionTests: [ModelRole: (provider: AIProvider, generation: Int, selection: ModelSelection)] = [:]
    private var modelDiscoveryGeneration: [AIProvider: Int] = [:]
    @Published private(set) var isCheckingWatches = false
    /// A forum the user removed while its page is still open: the page must
    /// not add it straight back as a recent forum.
    private var suppressedAutoAddSiteURL: String?
    /// Delay before coalesced settings edits are written.
    var settingsSaveDelay: Duration = .milliseconds(400)
    private static let watchInterval: TimeInterval = 30 * 60
    static let agentTopicPrefix = "agent:"
    /// Runs started from code that wait for their outcome (in memory only).
    /// When true, agent tools and watch checks call the forum through
    /// ForumService's URLSession instead of the embedded web view (tests).
    var usesDirectForumRequests = false
    /// Topic overviews (title, slug, facts) by topic key, fetched once per
    /// topic for navigation (AppModel+Navigation.swift).
    var topicOverviews: [String: ForumTopicOverview] = [:]
    /// Voice's hand-off to the Agent (`hand_off_to_agent`), targeting the active tab's session.
    private(set) lazy var agentHandOff = AgentHandOff(sessionProvider: { [unowned self] in self.browserAgent })
    /// Feeds the voice session's silent context (AppModel+Voice.swift).
    var voicePageSubscription: AnyCancellable?
    /// Starts voice sessions for the UI (Voice/VoiceController.swift).
    private(set) lazy var voice = VoiceController(app: self)
    /// The podcast: episodes, the player, read-aloud (Podcast/PodcastController.swift).
    private(set) lazy var podcast: PodcastController = {
        let controller = PodcastController(app: self, store: PodcastStore(directory: podcastDirectory))
        controller.voice = voice
        return controller
    }()
    /// Whether Space plays or pauses the podcast (WorkspaceLayout.swift).
    private(set) lazy var playPauseShortcut = PlayPauseShortcut(podcast: podcast)
    /// Per-site userscript store and automatic WKWebView injector (`ScriptStore.swift`).
    let scriptStore: ScriptStore
    /// Userscript importer and daily foreground update checker (`ScriptImport.swift`).
    let scriptImporter: ScriptImporter
    private var scriptImporterCancellable: AnyCancellable?
    /// Per-host learned reading tool state (`SiteToolState.swift`).
    let siteToolStateStore: SiteToolStateStore
    /// The agent's on-disk audit log and task records (`AuditLog.swift`, `TaskRecord.swift`).
    let auditLog: AuditLog
    let taskRecordStore: TaskRecordStore
    /// Per-tab conversation and page-thumbnail sidecar store (`TabConversations/`, `TabSnapshots/`).
    let tabStateStore: TabStateStore
    private var lastPersistedTabsState: SavedBrowserTabsState?
    /// Set to open the audit log (optionally at one task and step) from the panel.
    @Published var auditLogRequest: AuditLogRequest?

    /// WebMCP page-tool bridge (`PageToolBridge.swift`) for the active tab.
    var pageToolBridge: PageToolBridge { tabs.currentTab.pageToolBridge }
    /// Live userscript applier for the active tab.
    var scriptWebController: ScriptWebController { tabs.currentTab.scriptWebController }
    /// Where the active tab's Agent confirmation cards wait for Allow or Don't allow.
    var agentConfirmations: AgentConfirmationGate { tabs.currentTab.confirmations }
    /// The HTTP client behind `http_request` and `wukong.fetch` for the active tab.
    var agentHTTPClient: AgentHTTPClient { tabs.currentTab.httpClient }
    /// Observable browser agent session (`BrowserAgent.swift`) for the active tab.
    var browserAgent: BrowserAgentSession { tabs.currentTab.agentSession }

    private static func makeBrowserTab(
        id: String,
        conversationID: UUID,
        snapshot: UIImage?,
        tabBrowser: ForumBrowserModel,
        appBox: WeakBox<AppModel>,
        agentWorkspace: AgentWorkspace,
        scriptStore: ScriptStore,
        initialPageToolsEnabled: Bool,
        forumService: ForumService,
        aiService: AIService,
        auditLog: AuditLog,
        taskRecordStore: TaskRecordStore
    ) -> BrowserTab {
        tabBrowser.agentBridge.workspace = agentWorkspace
        let pageToolBridge = PageToolBridge(
            webView: tabBrowser.existingWebView,
            isEnabled: appBox.value?.settings.agentPageToolsEnabled ?? initialPageToolsEnabled
        )
        let scriptWebController = ScriptWebController(
            webView: tabBrowser.existingWebView,
            store: scriptStore,
            agentBridge: tabBrowser.agentBridge,
            pageToolBridge: pageToolBridge
        )
        tabBrowser.onWebViewAttached = { [weak scriptWebController] attachedWebView in
            scriptWebController?.attach(to: attachedWebView)
        }
        tabBrowser.onWebViewDetached = { [weak scriptWebController] in
            scriptWebController?.detachWebView()
        }
        let sessionBox = WeakBox<BrowserAgentSession>()
        let confirmations = AgentConfirmationGate()
        confirmations.onAsk = { [weak appBox, weak tabBrowser] _ in
            guard let app = appBox?.value, let tabBrowser, app.browser === tabBrowser, !app.isAIViewShown else { return }
            tabBrowser.expandChrome(deferIfTracking: true)
        }
        confirmations.onAnswer = { [weak sessionBox] tool, question, answer in
            sessionBox?.value?.recordConfirmation(tool: tool, question: question, answer: answer)
        }
        let httpClient = AgentHTTPClient(
            pacer: forumService.pacer,
            scriptLimiter: scriptStore.valuesStore.requestLimiter,
            environment: AgentNetworkEnvironment(
                cookies: { [weak tabBrowser] in
                    guard let tabBrowser else { return [] }
                    return await tabBrowser.configuredWebsiteDataStore.httpCookieStore.allCookies()
                },
                currentPageURL: { [weak tabBrowser] in
                    guard let tabBrowser else { return nil }
                    if let webViewURL = await tabBrowser.existingWebView?.url {
                        return webViewURL
                    }
                    return await tabBrowser.currentURL
                },
                confirmBeforeWrites: { [weak appBox] in
                    await appBox?.value?.settings.agentConfirmBeforeWrites ?? false
                },
                pacing: { [weak appBox] in
                    guard let app = await appBox?.value else { return (true, .gentle) }
                    return await (app.settings.forumRateLimitingEnabled, app.settings.forumRequestPace)
                },
                isForumHost: { [weak appBox] url in
                    await appBox?.value?.directory.forum(containing: url) != nil
                },
                onFetch: { [weak sessionBox] url, pageURL in
                    await sessionBox?.value?.recordFetch(url: url, pageURL: pageURL)
                }
            )
        )
        tabBrowser.agentBridge.fetchHandler = { [weak httpClient] url in
            guard let httpClient else { throw CancellationError() }
            return try await httpClient.scriptFetch(url)
        }
        scriptWebController.gmBridge.httpClient = httpClient
        scriptWebController.gmBridge.auditLog = auditLog
        scriptWebController.gmBridge.aiService = GMAiService(
            cache: scriptStore.aiCache, limiter: scriptStore.aiLimiter, aiService: aiService, auditLog: auditLog,
            runtimeProvider: { [weak appBox, weak scriptStore] in
                appBox?.value?.gmAiRuntimeSnapshot() ?? .unavailable(isGlobalScriptsEnabled: scriptStore?.isGlobalEnabled ?? false)
            }
        )

        let agentSession = BrowserAgentSession(
            pageDriver: tabBrowser.agentBridge,
            modelClient: aiService,
            configProvider: { [weak appBox] in
                guard let app = appBox?.value else {
                    return BrowserAgentRuntimeConfig(
                        selection: nil,
                        configuration: nil,
                        maxSteps: BrowserAgentLimits.defaultMaxSteps,
                        truncationLimit: BrowserAgentLimits.defaultTruncationLimit,
                        customInstructions: "",
                        redactedSecrets: []
                    )
                }
                return app.browserAgentRuntimeConfig
            },
            registryBuilder: { [weak appBox, weak tabBrowser, weak pageToolBridge, weak scriptWebController, weak confirmations, weak httpClient, weak sessionBox] bridge, limit, secrets in
                guard let app = appBox?.value else {
                    return ToolRegistry.m1(bridge: bridge, truncationLimit: limit, redactedSecrets: secrets)
                }
                let forum = tabBrowser.flatMap { app.makeForumToolContext(for: $0) }
                return ToolRegistry.m3(context: AgentToolContext(
                    bridge: bridge,
                    workspace: app.agentWorkspace,
                    scriptStore: app.scriptStore,
                    liveApplier: scriptWebController,
                    currentUserPrompt: { [weak sessionBox] in
                        sessionBox?.value?.lastUserPrompt
                    },
                    pageBaseline: { [weak sessionBox] in
                        sessionBox?.value?.pageBaseline
                    },
                    pageBaselineImage: { [weak sessionBox] in
                        sessionBox?.value?.pageBaselineImage
                    },
                    settings: AgentToolSettings(
                        truncationLimit: limit,
                        redactedSecrets: secrets,
                        supportsImageInput: app.settings.browserAgentModel?.supportsImageInput ?? false,
                        confirmBeforeWrites: app.settings.agentConfirmBeforeWrites
                    ),
                    network: httpClient,
                    confirmations: confirmations,
                    forum: forum,
                    learnedSite: forum == nil ? app.makeLearnedSiteContext(for: tabBrowser, pageToolBridge: pageToolBridge) : nil,
                    capabilities: tabBrowser.map { app.capabilityToolContext(for: $0) },
                    pageTools: app.settings.agentPageToolsEnabled ? pageToolBridge.map {
                        PageToolContext(
                            bridge: $0,
                            scriptStore: app.scriptStore,
                            confirmBeforeWrites: { [weak appBox] in
                                await appBox?.value?.settings.agentConfirmBeforeWrites ?? false
                            }
                        )
                    } : nil
                ))
            },
            auditLog: auditLog,
            taskRecords: taskRecordStore
        )
        sessionBox.value = agentSession
        agentSession.onAnswer = { [weak appBox] answer in
            _ = appBox?.value?.saveAgentAnswer(answer)
        }
        agentSession.onRunFinished = { [weak appBox, weak tabBrowser] in
            guard let app = appBox?.value, let tabBrowser, app.browser === tabBrowser, !app.isAIViewShown else { return }
            tabBrowser.expandChrome(deferIfTracking: true)
        }

        tabBrowser.knownForumLookup = { [weak appBox] url in
            guard let forum = appBox?.value?.directory.forum(containing: url) else { return nil }
            return KnownForumSite(siteURL: forum.siteURL, name: forum.name, iconURL: forum.iconURL, kind: forum.kind)
        }
        tabBrowser.onPageContextChanged = { [weak appBox, weak tabBrowser] context in
            guard let app = appBox?.value, let tabBrowser else { return }
            app.handlePageContext(context, from: tabBrowser)
        }
        tabBrowser.onNavigationFailed = { [weak appBox, weak tabBrowser] error in
            guard let app = appBox?.value, let tabBrowser, tabBrowser.onPageContextChanged != nil else { return }
            app.handleNavigationFailed(error, from: tabBrowser)
        }
        tabBrowser.onPagePositionChanged = { [weak appBox, weak tabBrowser] context in
            guard let app = appBox?.value, let tabBrowser else { return }
            app.handlePagePosition(context, from: tabBrowser)
        }
        tabBrowser.topicFactsLookup = { [weak appBox] topic in
            appBox?.value?.topicOverviews[topic.topicKey]?.facts
        }
        tabBrowser.onUserScriptNavigation = { [weak appBox] url in
            appBox?.value?.openScriptImportFromBrowser(url)
        }
        if let app = appBox.value {
            tabBrowser.homeSiteURL = app.currentSiteURL
            tabBrowser.applyContentBlocking(app.effectiveContentBlockingPolicy)
            tabBrowser.linkSettings = app.linkSettings
        }

        let tab = BrowserTab(
            id: id,
            conversationID: conversationID,
            snapshot: snapshot,
            browser: tabBrowser,
            pageToolBridge: pageToolBridge,
            scriptWebController: scriptWebController,
            confirmations: confirmations,
            httpClient: httpClient,
            agentSession: agentSession,
            sessionBox: sessionBox
        )
        agentSession.onConversationChanged = { [weak appBox, weak tab] in
            guard let app = appBox?.value, let tab else { return }
            app.persistTabConversation(tab)
        }
        agentSession.onConversationReset = { [weak appBox, weak tab] in
            guard let app = appBox?.value, let tab else { return }
            app.handleTabConversationReset(tab)
        }
        return tab
    }
    /// Where podcast audio is cached (`Caches/Podcasts`; tests pass their own).
    let podcastDirectory: URL
    /// The browser Agent's files: `Documents/`, shown in the Files app (tests pass their own).
    let agentWorkspace: AgentWorkspace
    /// Read topics and summaries in Spotlight (AppModel+System.swift).
    let spotlight: SpotlightIndexer
    /// Siri suggestions for the topics the user reads.
    let topicActivityDonor: TopicActivityDonating
    /// The topic last offered to Siri suggestions (one donation per visit).
    var donatedTopicKey: String?
    /// Every page context change (both kinds); `pageChanges` debounces it.
    let pageUpdates = PassthroughSubject<PageContext, Never>()
    /// How long the page must settle before `pageChanges` reports it.
    var pageChangeDelay: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(400)
    /// Fetch every opened topic's facts (post count, accepted answer) into
    /// the page context. Off by default (one more request per topic); the
    /// voice layer turns it on. Navigation actions fetch them either way.
    var prefetchesTopicFacts = false
    /// The iPhone bar shows "Solved · answer at #N" from the facts, so the
    /// browser UI fetches them for every opened topic (unit tests don't).
    var barShowsTopicFacts = false

    /// Loader that runs forum requests in the authenticated web view context.
    var webViewResourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)? {
        webViewResourceLoader(for: browser)
    }

    func webViewResourceLoader(
        for targetBrowser: ForumBrowserModel
    ) -> (@MainActor (URL) async throws -> ForumResourceResponse)? {
        guard !usesDirectForumRequests else { return nil }
        return { [targetBrowser] url in try await targetBrowser.fetchForumResource(url) }
    }

    init(
        store: PersistentStore = PersistentStore(),
        forumService: ForumService = ForumService(),
        sites: SiteRegistry = .standard,
        aiService: AIService = AIService(),
        browser: ForumBrowserModel? = nil,
        websiteDataStore: WKWebsiteDataStore? = nil,
        notifier: WatchNotifier = .shared,
        cloudSync: CloudSyncController? = nil,
        backgroundScheduler: BackgroundTaskScheduling = BGTaskScheduler.shared,
        podcastDirectory: URL? = nil,
        workspaceDirectory: URL? = nil,
        spotlightIndex: SpotlightIndexing? = nil,
        topicActivityDonor: TopicActivityDonating? = nil,
        backgroundGrace: BackgroundGracing? = nil,
        scriptStore: ScriptStore? = nil,
        siteToolStateStore: SiteToolStateStore? = nil
    ) {
        self.store = store
        let workspaceRoot = workspaceDirectory ?? AgentWorkspace.defaultRoot
        agentWorkspace = AgentWorkspace(root: workspaceRoot)
        let auditLog = AuditLog(directory: store.directoryURL.appendingPathComponent("AuditLog", isDirectory: true))
        let taskRecordStore = TaskRecordStore(
            directory: store.directoryURL.appendingPathComponent("Tasks", isDirectory: true),
            resultsRoot: workspaceRoot.appendingPathComponent(AgentWorkspace.resultsFolder, isDirectory: true),
            cookieSource: WebKitTaskCookieSource()
        )
        let tabStateStore = TabStateStore(baseDirectory: store.directoryURL)
        self.auditLog = auditLog
        self.taskRecordStore = taskRecordStore
        self.tabStateStore = tabStateStore
        // Retention runs at launch: the oldest audit days and task records go.
        DispatchQueue.global(qos: .utility).async { auditLog.prune() }
        Task.detached(priority: .utility) { await taskRecordStore.prune() }
        self.backgroundGrace = backgroundGrace ?? ApplicationBackgroundGrace()
        spotlight = Self.makeSpotlightIndexer(index: spotlightIndex, store: store)
        self.topicActivityDonor = topicActivityDonor ?? Self.makeTopicActivityDonor(store: store)
        self.podcastDirectory = podcastDirectory ?? PodcastStore.defaultDirectory
        self.backgroundScheduler = backgroundScheduler
        digestStore = DigestStore(directory: store.directoryURL)
        self.keyStore = store.keys
        self.cloudSync = cloudSync ?? CloudSyncController.makeDefault(for: store)
        self.forumService = forumService
        self.sites = sites
        self.aiService = aiService
        self.notifier = notifier

        let snapshot = store.load()
        forums = snapshot.forums
        let loadedRuns = snapshot.agentRuns.sorted { $0.createdAt > $1.createdAt }
        agentRuns = loadedRuns
        watchedTopics = snapshot.watchedTopics
        var loadedSettings = snapshot.settings
        var loadedKeys: [AIProvider: String] = [:]
        for provider in AIProvider.allCases {
            var configuration = loadedSettings.configuration(for: provider)
            configuration.apiKey = store.keys.value(for: provider)
            loadedKeys[provider] = configuration.apiKey
            loadedSettings.setConfiguration(configuration, for: provider)
        }
        #if DEBUG
        if AssistantDebug.value("-dc-browser-agent-scripts-box") != nil {
            loadedSettings.browserScriptsEnabled = true
        }
        #endif
        settings = loadedSettings
        persistedAPIKeys = loadedKeys

        let resolvedScriptStore: ScriptStore
        if let scriptStore {
            scriptStore.isGlobalEnabled = loadedSettings.browserScriptsEnabled
            resolvedScriptStore = scriptStore
        } else {
            let scriptsDirectory: URL
            #if DEBUG
            if Self.loadsOnlySamplePage && store.usesDefaultLocation {
                if let rawBox = AssistantDebug.value("-dc-browser-agent-scripts-box"), !rawBox.isEmpty {
                    let sanitizedBox = String(rawBox.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
                    let tempRoot = FileManager.default.temporaryDirectory
                    let boxDir = tempRoot.appendingPathComponent(
                        "wukong-scripts-box-\(sanitizedBox.isEmpty ? "default" : sanitizedBox)",
                        isDirectory: true
                    )
                    if AssistantDebug.has("-dc-browser-agent-reset-scripts-box") {
                        try? FileManager.default.removeItem(at: boxDir)
                        if let siblings = try? FileManager.default.contentsOfDirectory(
                            at: tempRoot,
                            includingPropertiesForKeys: [.contentModificationDateKey],
                            options: [.skipsHiddenFiles]
                        ) {
                            let cutoff = Date().addingTimeInterval(-3600)
                            for url in siblings where url.lastPathComponent.hasPrefix("wukong-scripts-box-") && url != boxDir {
                                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                                if let modified, modified < cutoff {
                                    try? FileManager.default.removeItem(at: url)
                                }
                            }
                        }
                    }
                    scriptsDirectory = boxDir
                } else if let customPath = AssistantDebug.value("-dc-browser-agent-scripts-dir"), !customPath.isEmpty {
                    scriptsDirectory = URL(fileURLWithPath: customPath, isDirectory: true)
                } else {
                    scriptsDirectory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("wukong-debug-scripts-\(UUID().uuidString)", isDirectory: true)
                }
            } else {
                scriptsDirectory = store.directoryURL.appendingPathComponent("Scripts", isDirectory: true)
            }
            #else
            scriptsDirectory = store.directoryURL.appendingPathComponent("Scripts", isDirectory: true)
            #endif
            resolvedScriptStore = ScriptStore(
                directoryURL: scriptsDirectory,
                isGlobalEnabled: loadedSettings.browserScriptsEnabled
            )
        }
        self.scriptStore = resolvedScriptStore
        if let siteToolStateStore {
            self.siteToolStateStore = siteToolStateStore
        } else {
            #if DEBUG
            let siteToolsDir = (Self.loadsOnlySamplePage && store.usesDefaultLocation)
                ? FileManager.default.temporaryDirectory.appendingPathComponent("wukong-debug-sitetools-\(UUID().uuidString)", isDirectory: true)
                : store.directoryURL.appendingPathComponent("SiteTools", isDirectory: true)
            #else
            let siteToolsDir = store.directoryURL.appendingPathComponent("SiteTools", isDirectory: true)
            #endif
            self.siteToolStateStore = SiteToolStateStore(directoryURL: siteToolsDir)
        }
        let box = self.appBox
        let resolvedImporter = ScriptImporter(
            scriptStore: resolvedScriptStore,
            httpClientProvider: {
                box.value?.agentHTTPClient ?? AgentHTTPClient()
            }
        )
        self.scriptImporter = resolvedImporter
        let workspace = self.agentWorkspace
        let initialPageToolsEnabled = loadedSettings.agentPageToolsEnabled
        let allowsTabRestore = browser == nil && !Self.loadsOnlySamplePage
        let restoredTabsState = allowsTabRestore ? snapshot.browserTabs : nil
        let restoredTabsFromSnapshot = (restoredTabsState?.tabs.isEmpty == false)
        self.tabs = BrowserTabs(
            initialBrowser: browser,
            restoredState: restoredTabsState,
            loadRestoredConversation: { conversationID in
                tabStateStore.loadConversation(id: conversationID)
            },
            loadRestoredSnapshot: { tabID in
                tabStateStore.loadSnapshot(tabID: tabID)
            },
            sites: sites,
            websiteDataStore: websiteDataStore
        ) { tabID, conversationID, tabSnapshot, tabBrowser in
            Self.makeBrowserTab(
                id: tabID,
                conversationID: conversationID,
                snapshot: tabSnapshot,
                tabBrowser: tabBrowser,
                appBox: box,
                agentWorkspace: workspace,
                scriptStore: resolvedScriptStore,
                initialPageToolsEnabled: initialPageToolsEnabled,
                forumService: forumService,
                aiService: aiService,
                auditLog: auditLog,
                taskRecordStore: taskRecordStore
            )
        }

        let now = Date()
        sessions = Dictionary(
            snapshot.sessions.map { session in
                var normalized = session
                if !session.kept,
                   let updated = session.chatUpdatedAt,
                   now.timeIntervalSince(updated) >= 24 * 60 * 60 {
                    normalized.history = []
                    normalized.chatUpdatedAt = nil
                }
                return (normalized.topicKey, normalized)
            },
            uniquingKeysWith: { first, second in first.updatedAt >= second.updatedAt ? first : second }
        )
        activities = snapshot.activities
            .filter {
                !$0.status.isTerminal
                    || now.timeIntervalSince($0.completedAt ?? $0.updatedAt) < 24 * 60 * 60
            }
            .map {
                guard !$0.status.isTerminal else { return $0 }
                var interrupted = $0
                // The old Research loop is gone: an interrupted run's record
                // never runs again.
                if interrupted.type == .agent {
                    interrupted.status = .cancelled
                    interrupted.statusText = String(localized: "Cancelled", comment: "Status of AI work the user cancelled")
                    interrupted.completedAt = now
                } else {
                    interrupted.status = .queued
                    interrupted.statusText = String(localized: "Restoring interrupted work…", comment: "Status of AI work that was interrupted when the app quit and is starting again")
                }
                return interrupted
            }
            .sorted { $0.createdAt > $1.createdAt }

        // An old Research run that never finished is closed out instead of
        // spinning: the loop that ran it is gone.
        agentRuns = agentRuns.map { run in
            guard !run.isFinished else { return run }
            var updated = run
            if !updated.initialAnswer.isEmpty {
                updated.result = .completed
                updated.completedAt = updated.completedAt ?? now
            } else {
                updated.result = .cancelled
                updated.error = String(localized: "Interrupted before the run could finish.", comment: "Ask the forum: a research run stopped when the app quit")
                updated.completedAt = now
            }
            return updated
        }

        self.appBox.value = self
        self.tabs.onActiveTabChanged = { [weak self] newTab, oldTab in
            self?.handleActiveTabChanged(to: newTab, from: oldTab)
        }
        self.tabs.onTabsMutated = { [weak self] in
            self?.saveSettings()
        }
        self.tabs.onTabClosed = { [weak self] closedTab in
            self?.handleTabClosed(closedTab)
        }
        self.tabs.onTabSnapshotUpdated = { [weak self] updatedTab in
            self?.persistTabSnapshot(updatedTab)
        }
        self.scriptStore.onGlobalEnabledChanged = { [weak self] isEnabled in
            guard let self, self.settings.browserScriptsEnabled != isEnabled else { return }
            self.settings.browserScriptsEnabled = isEnabled
        }
        self.scriptStore.onStoreChanged = { [weak self] in
            self?.objectWillChange.send()
        }
        self.scriptStore.onSyncedScriptsChanged = { [weak self] in
            guard let self else { return }
            #if DEBUG
            if self.suppressesPersistence { return }
            #endif
            self.cloudSync.localDataDidChange()
        }
        self.scriptStore.libraryHTTPClientProvider = { [weak resolvedImporter] in
            resolvedImporter?.httpClientProvider()
        }
        self.scriptImporterCancellable = resolvedImporter.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Start on the most recently visited forum (or the first pinned one);
        // with none, the browser stays empty and the UI shows the Forums home.
        currentSiteURL = Self.startForum(in: forums)?.siteURL
        // Ad/tracker blocking starts before the first page load.
        configureContentBlocking()
        for tab in self.tabs.tabs {
            tab.browser.homeSiteURL = currentSiteURL
            tab.browser.linkSettings = linkSettings
            if restoredTabsFromSnapshot {
                tab.browser.refreshPageContext()
            }
        }
        if restoredTabsFromSnapshot {
            // Persist normalized conversation states (e.g. runs stopped on quit)
            // and prune any sidecar files not referenced by the restored tabs.
            for tab in self.tabs.tabs where tab.agentSession.hasConversation {
                persistTabConversation(tab)
            }
            pruneOrphanTabState()
        }
        self.lastPersistedTabsState = self.tabs.exportState()
        // (DEBUG samples load only their own page: a restored forum's load
        // failing late would replace it with the Forums home.)
        if !restoredTabsFromSnapshot,
           self.browser.existingWebView?.url == nil,
           !Self.loadsOnlySamplePage,
           !Self.isRunningTests {
            self.loadHome(silentOnFailure: true)
        }
        openURLObserver = NotificationCenter.default.addObserver(
            forName: WatchNotifier.openURLNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            Task { @MainActor [weak self] in
                self?.noteExternalEntry()
                self?.browser.load(url)
                self?.panelRoute = .topic
            }
        }
        WatchBackgroundRefresh.perform = { [weak self] in
            await self?.checkWatchedTopics(reason: .background)
            // On disk before the system suspends the app again.
            await self?.flushPendingSaves()
        }
        loadDigests()
        // Podcast audio of deleted or week-old digests goes.
        podcast.reconcile()
        openTodayObserver = NotificationCenter.default.addObserver(
            forName: WatchNotifier.openTodayNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.openTodayFromNotification() }
        }
        DigestBackgroundPrefetch.perform = { [weak self] in
            await self?.performBackgroundDigestPrefetch()
            await self?.flushPendingSaves()
        }
        if settings.dailyDigestEnabled { scheduleDigestPrefetch() }
        Task { [weak self] in
            guard let notifier = self?.notifier else { return }
            let authorized = await notifier.isAuthorized()
            if let self, self.notificationsAuthorized != authorized {
                self.notificationsAuthorized = authorized
            }
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-ui-test-") }) {
            // UI-test seeds start past the walkthrough.
            settings.hasCompletedOnboarding = true
        }
        if AssistantDebug.isActive {
            seedAssistantSample()
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-manage-swipe") {
            seedUITestManageSession()
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-sample-session") {
            seedUITestSession()
        }
        applyBrowserAgentDebugArguments()
        applyBarMorphDebugArguments()
        seedScriptsSampleIfNeeded()
        seedM4ImportPreviewIfNeeded()
        // Sample only: never over the real digests or with a real key.
        if AssistantDebug.isActive, AssistantDebug.has("-dc-digest-sample") { seedDigestSample() }
        // `-dc-no-forums`: the sample as a new user sees Home (never saved).
        if AssistantDebug.isActive, AssistantDebug.has("-dc-no-forums") {
            directory = ForumDirectory(forums: [])
            siteVisits.hidesVisits = true
            currentSiteURL = nil
            self.browser.homeSiteURL = nil
        }
        applyStateDebugScript()
        if VoiceDebug.isFake { settings.voiceEnabled = true }
        #endif
        // Launch: what grew while the app ran last (and data from before
        // sessions were pruned at all) goes before anything reads it.
        pruneSessions()
        self.cloudSync.attach(self)
        if !Self.loadsOnlySamplePage {
            self.scriptStore.retryUnresolvedSyncedLibraries()
        }
        // Launch: bring Spotlight up to date (only the difference, or
        // everything once after a new index version).
        spotlightDataDidChange()
    }

    var currentSession: TopicSession? {
        guard let topicKey = currentTopic?.topicKey else { return nil }
        return sessions[topicKey]
    }

    /// Live availability of the Apple Intelligence provider (through
    /// `aiService`, so tests can fake it).
    var appleIntelligenceStatus: AppleIntelligenceStatus {
        aiService.appleIntelligence.currentStatus()
    }

    /// The assistant role's provider settings and model.
    var selectedConfiguration: ProviderConfiguration {
        settings.configuration(for: .assistant)
    }

    func restorePendingTasksIfNeeded() {
        guard !didRestoreTasks else { return }
        didRestoreTasks = true
        for record in activities where record.status == .queued {
            launch(recordID: record.id)
        }
    }

    /// `wukongmind://open?url=…&action=open|summary|chat|agent`.
    ///
    /// Any app or web page can open such a link, so a link only starts AI
    /// work (which spends the user's credits) when the share extension queued
    /// the same request in the App Group inbox. Otherwise it opens the page
    /// and the Assistant in the requested mode, and the user starts it.
    func handleDeepLink(_ deepLink: URL) {
        guard let request = IncomingLink.parse(deepLink) else { return }
        guard !handledShareIDs.contains(request.id) else { return }
        // The share extension also queued this request in the inbox.
        let fromShareExtension = SharedInbox.remove(id: request.id)
        handle(request, autoRun: fromShareExtension)
    }

    /// Hand-off from the share extension or a deep link. A request is handled
    /// once even when it arrives both ways (inbox and URL). `autoRun: false`
    /// opens the page and Assistant without starting a summary or pull; before
    /// onboarding is done (`acceptsSystemWork`), AI work never starts
    /// automatically either.
    func handle(_ request: IncomingLinkRequest, autoRun: Bool = true) {
        guard handledShareIDs.insert(request.id).inserted else { return }
        noteExternalEntry()
        openShared(url: request.url, action: request.action.rawValue, autoRun: autoRun && acceptsSystemWork)
    }

    /// Delivers the newest request the share extension queued in the App Group
    /// inbox (older ones are superseded) — call on launch/foreground.
    func drainSharedInbox() {
        let requests = SharedInbox.drainAll().filter { !handledShareIDs.contains($0.id) }
        if let latest = requests.last { handle(latest) }
    }

    /// The error the root alert shows.
    var presentedError: String? { errorQueue.first?.message }
    var presentedErrorAction: ErrorAction? { errorQueue.first?.action }

    /// Queues an error for the root alert; a message already waiting is not
    /// queued twice. For what the user just did: work the app started by
    /// itself reports in Activity instead.
    func presentError(_ message: String, action: ErrorAction? = nil) {
        if let index = errorQueue.firstIndex(where: { $0.message == message }) {
            if errorQueue[index].action == nil, let action {
                errorQueue[index].action = action
            }
            return
        }
        errorQueue.append(PresentedError(message: message, action: action))
    }

    /// Runs the root error alert's follow-up action after dismissing the alert.
    func performErrorAction(_ action: ErrorAction, after delay: Duration? = nil) {
        let wait = delay ?? PresentationRouter.settleDelay
        dismissPresentedError()
        if router.item != nil { router.item = nil }
        Task { @MainActor [weak self] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
            }
            guard let self else { return }
            switch action {
            case .openAIModels:
                self.requestedSettingsPage = .provider
            }
        }
    }

    /// The root alert's OK: the next error (if any) shows.
    func dismissPresentedError() {
        guard !errorQueue.isEmpty else { return }
        errorQueue.removeFirst()
    }

    /// Asks the root view to show the Assistant (once per call).
    func requestAssistant() {
        assistantRequest &+= 1
    }

    /// Opens the page browser agent on any loaded web page (whether a recognized
    /// forum or a general website).
    func openBrowserAgent() {
        browser.hideForumsHome()
        assistantMode = .browserAgent
        panelRoute = .topic
        requestAssistant()
        if !isProviderReady(for: .browserAgent) {
            needsProviderSetup = .browserAgent
        }
    }

    /// Display name of the model used for userscript capabilities (`GM_ai`).
    var scriptsModelDisplayName: String {
        roleModelDisplayName(for: .scripts)
    }

    /// Opens the userscript import review sheet when a `.user.js` navigation is intercepted.
    /// Ignores background or follow-up `.user.js` navigations while an import sheet is already active
    /// so a page behind the sheet can never swap what the person is reviewing.
    func openScriptImportFromBrowser(_ url: URL) {
        guard scriptImporter.activeSessionID == nil, scriptImporter.phase == nil else { return }
        let inSettings = (requestedSettingsPage == .scripts)
        if !inSettings {
            requestedSettingsPage = nil
            router.item = nil
        }
        scriptImporter.openImport(from: url, inSettings: inSettings)
    }

    /// Dismisses the import review sheet, opens the Browser Agent, and sends the
    /// third-party script wrapped as untrusted web content for a read-only review.
    func askAgentToReviewImportedScript(_ review: ScriptImportReview) {
        scriptImporter.dismissImport()
        requestedSettingsPage = nil
        requestedScriptID = nil
        openBrowserAgent()
        guard isProviderReady(for: .browserAgent) else { return }
        let attached = Self.makeScriptReviewAttachedBlock(
            review: review,
            redactedSecrets: browserAgentRuntimeConfig.redactedSecrets
        )
        browserAgent.send(
            String(localized: "Review this script before I turn it on", comment: "User prompt sent to the Browser Agent when tapping Ask the Agent to review it in the script import sheet"),
            context: nil,
            attachedBlock: attached
        )
    }

    static func makeScriptReviewAttachedBlock(
        review: ScriptImportReview,
        redactedSecrets: [String]
    ) -> String {
        let untrustedPayload = """
        Install URL: \(review.installURL)
        Source host: \(review.finalHost)

        \(review.rawSource)
        """
        let wrapped = UntrustedWebContent.wrap(
            untrustedPayload,
            toolName: "userscript_import_review",
            secrets: redactedSecrets
        )
        return """
        The person is reviewing a third-party userscript before deciding whether to install it.
        Do NOT call script_save, script_delete, navigate, or any page-modifying tool. Explain in plain words what the script does, which sites and hosts it reaches, and any privacy or security risks.

        \(wrapped)
        """
    }

    /// Live configuration snapshot read by `browserAgent` when starting a turn.
    var browserAgentRuntimeConfig: BrowserAgentRuntimeConfig {
        let selection = settings.browserAgentModel
        let configuration: ProviderConfiguration? = selection.map { sel in
            var config = settings.configuration(for: sel.provider)
            config.model = sel.model
            return config
        }
        let secrets = AIProvider.allCases
            .map { settings.configuration(for: $0).apiKey }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return BrowserAgentRuntimeConfig(
            selection: selection,
            configuration: configuration,
            maxSteps: settings.browserAgentMaxSteps,
            truncationLimit: settings.browserAgentTruncationLimit,
            customInstructions: settings.systemPrompt,
            redactedSecrets: secrets,
            allScripts: scriptStore.scripts
        )
    }

    /// Opens a shared link. Once the page is detected as that topic (or, for
    /// "agent", any page of a Discourse forum), switches to the Assistant and
    /// starts the summary / focuses chat / prepares the agent for that forum.
    /// Without a configured provider it sets `needsProviderSetup` instead of
    /// starting AI work.
    func openShared(url: URL, action: String, autoRun: Bool = true) {
        guard ForumBrowserModel.isBrowsableURL(url) else { return }
        let kind = PendingShare.Action(rawValue: action.lowercased()) ?? .open
        pendingShare = kind == .open
            ? nil
            : PendingShare(
                url: url,
                action: kind,
                topicID: sites.looseTopicID(in: url),
                autoRun: autoRun
            )
        panelRoute = .topic
        browser.load(url)
    }

    /// The browser's current page as the assistant sees it, with the reading
    /// position (posts on screen, highlights). The browser is the only
    /// store: scrolling republishes `ForumBrowserModel`, not this model, which
    /// announces only new pages and routes (`handlePageContext`).
    var pageContext: PageContext {
        #if DEBUG
        if let seededPageContext { return seededPageContext }
        #endif
        return browser.pageContext
    }

    #if DEBUG
    /// Screenshot and UI-test seeds: the page context they show until the
    /// browser reports a scroll position.
    private(set) var seededPageContext: PageContext?
    #endif

    private func pruneOrphanTabState() {
        #if DEBUG
        if suppressesPersistence { return }
        #endif
        tabStateStore.pruneOrphans(
            keepingTabIDs: Set(tabs.tabs.map(\.id)),
            keepingConversationIDs: Set(tabs.tabs.map(\.conversationID))
        )
    }

    private func persistTabConversation(_ tab: BrowserTab) {
        #if DEBUG
        if suppressesPersistence { return }
        #endif
        tabStateStore.saveConversation(tab.agentSession.exportConversation(), id: tab.conversationID)
    }

    private func persistTabSnapshot(_ tab: BrowserTab) {
        #if DEBUG
        if suppressesPersistence { return }
        #endif
        tabStateStore.saveSnapshot(tab.snapshot, tabID: tab.id)
    }

    private func handleTabClosed(_ tab: BrowserTab) {
        #if DEBUG
        if suppressesPersistence { return }
        #endif
        tabStateStore.removeSnapshot(tabID: tab.id)
        tabStateStore.removeConversation(id: tab.conversationID)
    }

    private func handleTabConversationReset(_ tab: BrowserTab) {
        let oldID = tab.assignNewConversationID()
        #if DEBUG
        if suppressesPersistence { return }
        #endif
        tabStateStore.removeConversation(id: oldID)
        saveSettings()
    }

    private func handleActiveTabChanged(to newTab: BrowserTab, from oldTab: BrowserTab?) {
        #if DEBUG
        seededPageContext = nil
        #endif
        oldTab?.browser.setEditingAddress(false)
        oldTab?.browser.setSystemKeyboardVisible(false)
        oldTab?.browser.setExternalKeyboardFrozen(false)
        let context = newTab.browser.pageContext
        if let siteURL = context.siteURL ?? newTab.browser.homeSiteURL {
            if currentSiteURL != siteURL { currentSiteURL = siteURL }
        } else if let currentSiteURL {
            newTab.browser.homeSiteURL = currentSiteURL
        }
        select(topic: newTab.browser.showsForumsHome ? nil : context.topic)
        pageUpdates.send(context)
        homeVisibilityChanged()
        objectWillChange.send()
        if prefetchesTopicFacts || barShowsTopicFacts, let topic = context.topic, context.state == .topic,
           topicOverviews[topic.topicKey] == nil {
            Task { [weak self] in _ = await self?.topicOverview(siteURL: topic.siteURL, topicID: topic.topicID) }
        }
    }

    private func handlePageContext(_ context: PageContext, from tabBrowser: ForumBrowserModel) {
        let isCurrent = tabs.isCurrent(tabBrowser)
        if isCurrent {
            objectWillChange.send()
            if let suppressed = suppressedAutoAddSiteURL {
                // A forum removed while its page is open stays removed until the
                // browser settles on another forum or a non-forum page.
                if let siteURL = context.siteURL, siteURL != suppressed {
                    suppressedAutoAddSiteURL = nil
                } else if context.state == .notForum {
                    suppressedAutoAddSiteURL = nil
                }
            }
        }
        if let kind = context.site, let siteURL = context.siteURL, siteURL != suppressedAutoAddSiteURL {
            recordVisit(siteURL: siteURL, kind: kind, name: context.forumName, iconURL: context.iconURL)
            siteVisits.noteVisit(siteURL: siteURL, name: context.forumName, isForum: true)
        } else if context.state == .notForum, let origin = HomeSites.originOf(context.url) {
            siteVisits.noteVisit(siteURL: origin, name: HomeSites.displayName(forOrigin: origin), isForum: false)
        }
        guard isCurrent else { return }
        select(topic: context.topic)
        completePendingShare(with: context)
        pageUpdates.send(context)
        if prefetchesTopicFacts || barShowsTopicFacts, let topic = context.topic, context.state == .topic,
           topicOverviews[topic.topicKey] == nil {
            Task { [weak self] in _ = await self?.topicOverview(siteURL: topic.siteURL, topicID: topic.topicID) }
        }
    }

    /// Only the page's position changed (posts on screen, highlights, the
    /// topic's facts): no topic selection or save.
    func handlePagePosition(_ context: PageContext, from tabBrowser: ForumBrowserModel? = nil) {
        if let tabBrowser, !tabs.isCurrent(tabBrowser) { return }
        #if DEBUG
        seededPageContext = nil
        #endif
        pageUpdates.send(context)
    }

    private func handleNavigationFailed(_ error: Error, from tabBrowser: ForumBrowserModel) {
        guard tabs.isCurrent(tabBrowser) else { return }
        presentError(error.localizedDescription)
    }

    /// How a link on `siteURL` is read: the site's adapter, with the forum's base
    /// path. Nothing parses when the site has no adapter.
    func linkParser(siteURL: String) -> AgentSources.Parse {
        linkParser(siteURL: siteURL, known: [:])
    }

    /// The parser of one run's links: the adapter's, then the permalinks the
    /// run's tools showed (`AgentRun.knownLinks`), for a platform whose links
    /// carry no topic id.
    func linkParser(for run: AgentRun) -> AgentSources.Parse {
        linkParser(siteURL: run.siteURL, known: run.knownLinks)
    }

    /// The parser of an Agent run's links: the permalinks its forum results
    /// showed (thread and list shapes) stand in for `AgentRun.knownLinks`.
    func linkParser(siteURL: String, shapes: [ForumShape]) -> AgentSources.Parse {
        guard let links = adapter(for: siteURL)?.links else { return linkParser(siteURL: siteURL) }
        var known: [String: String] = [:]
        func note(_ urlText: String, _ id: String?) {
            guard let id, !id.isEmpty, known.count < AgentRun.knownLinkLimit, let url = URL(string: urlText) else { return }
            known[AgentSources.knownKey(url, links: links)] = id
        }
        for shape in shapes {
            switch shape {
            case .thread(let thread): note(thread.url, thread.id)
            case .list(let list): list.items.forEach { note($0.url, $0.id) }
            }
        }
        return linkParser(siteURL: siteURL, known: known)
    }

    private func linkParser(siteURL: String, known: [String: String]) -> AgentSources.Parse {
        let links = adapter(for: siteURL)?.links
        let basePath = ForumSite.parse(siteURL: siteURL)?.basePath ?? ""
        return AgentSources.Parse(basePath: basePath) { url in
            guard let links else { return nil }
            if let link = links.parse(url, basePath: basePath) { return link }
            return known[AgentSources.knownKey(url, links: links)].map { SiteLink(topicID: $0, slug: nil, postNumber: nil) }
        }
    }

    /// The forum a URL is on: a directory forum, else the page's forum.
    func siteURL(containing url: URL) -> String? {
        if let forum = directory.forum(containing: url) { return forum.siteURL }
        if let siteURL = pageContext.siteURL, ForumSite.isSameForum(url: url, siteURL: siteURL) { return siteURL }
        return nil
    }

    nonisolated private static func sameSharedPage(_ lhs: URL, _ rhs: URL) -> Bool {
        if PageContext.samePage(lhs, rhs) { return true }
        func normalized(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            if let path = components?.path, path.count > 1, path.hasSuffix("/") {
                components?.path = String(path.dropLast())
            }
            return components?.string ?? url.absoluteString
        }
        return normalized(lhs) == normalized(rhs)
    }

    private func completePendingShare(with context: PageContext) {
        guard var pending = pendingShare, let url = context.url else { return }
        if !pending.sawSharedPage, Self.sameSharedPage(url, pending.url) {
            pending.sawSharedPage = true
            pendingShare = pending
        }
        switch context.state {
        case .loading, .maybe:
            return
        case .notForum:
            // Plain web pages can open directly or launch the browser agent once
            // the page settles; forum-specific summary/chat shares still stop here.
            guard !browser.isLoading else { return }
            pendingShare = nil
            if pending.action == .agent {
                assistantMode = .browserAgent
                panelRoute = .topic
                requestAssistant()
                if !isProviderReady(for: .browserAgent) { needsProviderSetup = .browserAgent }
            }
            return
        case .forumHome, .topic:
            break
        }
        let topicMatches: Bool
        if let expectedID = pending.topicID {
            topicMatches = context.topic?.topicID == expectedID
        } else {
            topicMatches = context.state == .topic
                && context.topic != nil
                && (Self.sameSharedPage(url, pending.url) || pending.sawSharedPage)
        }
        switch pending.action {
        case .open:
            pendingShare = nil
        case .agent:
            // The Agent, with this forum's tools (the old Research loop is gone).
            pendingShare = nil
            assistantMode = .browserAgent
            panelRoute = .topic
            requestAssistant()
            if !isProviderReady(for: .browserAgent) { needsProviderSetup = .browserAgent }
        case .summary, .chat:
            guard topicMatches else {
                // A Discourse page that is not the shared topic: stop waiting
                // once loading finished somewhere else. For a topic page that
                // needs the shared page to have been reached first (a late
                // report from the page before it must not cancel the share);
                // after that, the user went elsewhere, and visiting the
                // shared topic later must not start work by surprise.
                if !browser.isLoading, !Self.sameSharedPage(url, pending.url),
                   context.state == .forumHome || pending.sawSharedPage {
                    pendingShare = nil
                }
                return
            }
            pendingShare = nil
            assistantMode = .summary
            panelRoute = .topic
            requestAssistant()
            guard isProviderReady(for: .assistant) else {
                needsProviderSetup = .assistant
                return
            }
            // A deep link that did not come from the share extension — or a
            // hand-off before onboarding is done — only opens the Assistant;
            // the user starts the work.
            guard pending.autoRun, acceptsSystemWork else { return }
            if pending.action == .summary {
                // The same topic shared again while its summary runs: show it.
                if let topicKey = currentTopic?.topicKey,
                   hasActiveWork(topicKey: topicKey, type: .summary) {
                    return
                }
                startSummary()
            } else if currentSession?.source.isEmpty ?? true,
                      let topicKey = currentTopic?.topicKey,
                      !hasActiveWork(topicKey: topicKey, type: .pull) {
                pullTopic()
            }
        }
    }

    func select(topic: ForumTopic?) {
        #if DEBUG
        if topic == nil,
           ProcessInfo.processInfo.arguments.contains("-ui-test-sample-session") {
            return
        }
        #endif
        currentTopic = topic
        topicActivityDidChange(topic)
        guard let topic else { return }
        #if DEBUG
        let resetForPullUITest = ProcessInfo.processInfo.arguments.contains(
            "-ui-test-pull-mode"
        )
        #else
        let resetForPullUITest = false
        #endif
        var session = resetForPullUITest ? nil : sessions[topic.topicKey]
        if session == nil {
            session = TopicSession(siteURL: topic.siteURL, topicID: topic.topicID, url: topic.url, title: topic.title)
        }
        session?.url = topic.url
        session?.title = topic.title
        // The page is in front of the user: the one place a visit is recorded.
        session?.openedByUserAt = Date()
        sessions[topic.topicKey] = session
        save()
    }

    /// Starts a summary; `batchLimit` overrides the hierarchical-summary batch
    /// size for this run only.
    /// `regenerate`: write it again even when no reply is new (Retry).
    func startSummary(batchLimit: Int? = nil, regenerate: Bool = false) {
        guard let topic = currentTopic else {
            presentError(AssistantError.noTopic.localizedDescription)
            return
        }
        if activities.contains(where: {
            $0.topicKey == topic.topicKey && $0.type == .summary && !$0.status.isTerminal
        }) {
            return
        }
        router.summarizeTipSeen()
        let shouldRegenerate = regenerate || (batchLimit != nil && currentSession?.hasSummary == true)
        enqueueSummary(for: topic, batchLimit: batchLimit, regenerate: shouldRegenerate)
    }

    /// Queues a summary task for any topic (used by watched-topic refreshes,
    /// `origin: .automatic`).
    @discardableResult
    func enqueueSummary(
        for topic: ForumTopic,
        batchLimit: Int? = nil,
        regenerate: Bool = false,
        origin: WorkOrigin = .user
    ) -> Bool {
        guard !activities.contains(where: {
            $0.topicKey == topic.topicKey && $0.type == .summary && !$0.status.isTerminal
        }) else {
            return false
        }
        guard activeTaskCount < 50 else {
            if origin == .user {
                presentError(String(localized: "The task queue is full. Cancel or wait for an existing task."))
            }
            return false
        }

        let selection = settings.assistantModel
        var record = WorkRecord(
            type: .summary,
            siteURL: topic.siteURL,
            topicID: topic.topicID,
            title: topic.title,
            url: topic.url,
            provider: selection.provider,
            model: selection.model
        )
        record.batchLimit = batchLimit.map(SummaryBatchLimit.normalized)
        record.origin = origin
        if regenerate { record.regenerate = true }
        activities.insert(record, at: 0)
        save()
        launch(recordID: record.id)
        return true
    }

    // MARK: Forums

    private var directory: ForumDirectory {
        get { ForumDirectory(forums: forums) }
        set { forums = newValue.forums }
    }

    var pinnedForums: [Forum] { directory.pinned }
    var recentForums: [Forum] { directory.recent }

    func forum(for siteURL: String) -> Forum? {
        directory.forum(siteURL: siteURL)
    }

    /// The adapter that reads `siteURL`. Lookup order: (1) a host the registry
    /// claims (one site whatever the path); (2) the directory forum's kind;
    /// (3) the open page's detected site when its site URL matches (a forum
    /// removed while its page is still open, `suppressedAutoAddSiteURL`).
    /// Nil means unsupported, and the registry is not asked for a guess: callers
    /// fail with `AssistantError.noForum`, never crash or delete anything.
    func adapter(for siteURL: String) -> (any SiteAdapter)? {
        if let host = URL(string: siteURL)?.host, let claimed = sites.claimedSite(forHost: host) { return claimed.adapter }
        if let forum = forum(for: siteURL) { return sites.adapter(for: forum.kind) }
        let normalized = ForumSite.normalizeSiteURL(siteURL) ?? siteURL
        if pageContext.siteURL == normalized, let kind = pageContext.site { return sites.adapter(for: kind) }
        for tab in tabs.tabs where tab.browser.pageContext.siteURL == normalized {
            if let kind = tab.browser.pageContext.site { return sites.adapter(for: kind) }
        }
        return nil
    }

    /// The transport for one job on `siteURL`: the forum's cookies, the pace the
    /// job started with and (unless `inPage` is false) the in-page loader.
    func network(
        for siteURL: String,
        pace: ForumRequestPace,
        isPaced: Bool? = nil,
        inPage: Bool = true,
        browser targetBrowser: ForumBrowserModel? = nil
    ) async -> SiteNetwork {
        let resolvedBrowser = targetBrowser ?? browser
        let cookieHeader = usesDirectForumRequests ? nil : await resolvedBrowser.cookieHeader(forSite: siteURL)
        var context = SiteRequestContext(
            cookieHeader: cookieHeader,
            pace: pace,
            isPaced: isPaced ?? settings.forumRateLimitingEnabled
        )
        if inPage, let loader = webViewResourceLoader(for: resolvedBrowser) {
            context.resourceLoader = { url in try await loader(url) }
        }
        return SiteNetwork(service: forumService, siteURL: siteURL, context: context)
    }

    /// The current forum: the last Discourse forum shown (or opened by the
    /// app), resolved from `currentSiteURL` so its name, icon and pin state
    /// always come from the directory.
    var currentForum: Forum? {
        currentSiteURL.map { forumInfo(siteURL: $0) }
    }

    func hasActiveWork(topicKey: String, type: WorkType) -> Bool {
        activities.contains { $0.topicKey == topicKey && $0.type == type && !$0.status.isTerminal }
    }

    /// Most recently visited forum, else the first pinned one.
    static func startForum(in forums: [Forum]) -> Forum? {
        let directory = ForumDirectory(forums: forums)
        return forums
            .filter { $0.lastVisitedAt != nil }
            .max { ($0.lastVisitedAt ?? .distantPast) < ($1.lastVisitedAt ?? .distantPast) }
            ?? directory.pinned.first
    }

    /// Adds (or refreshes) a forum and marks it visited; called for every
    /// detected Discourse page, so visited forums show up as recent.
    func recordVisit(siteURL: String, kind: SiteKind, name: String?, iconURL: URL?) {
        var directory = self.directory
        let previous = directory.forum(siteURL: siteURL)
        let now = Date()
        // Visits within a minute on the same forum do not rewrite the snapshot.
        let isFreshVisit = previous?.lastVisitedAt.map { now.timeIntervalSince($0) > 60 } ?? true
        guard let forum = directory.upsert(
            siteURL: siteURL,
            kind: kind,
            name: name,
            iconURL: iconURL,
            visitedAt: isFreshVisit ? now : nil
        ) else {
            return
        }
        let changed = forum != previous
        if changed { self.directory = directory }
        if currentSiteURL != forum.siteURL { currentSiteURL = forum.siteURL }
        if changed { save() }
    }

    /// Validates an address (URL or host, optionally a page on the forum) by
    /// asking each registered adapter, in order, for the site's info (Discourse:
    /// `/site/basic-info.json`, fallback `/about.json`), then adds the forum with
    /// its kind, name and icon. Existing forums are refreshed. A repeated call
    /// for the address being detected joins that detection (`addForumPhase`).
    @discardableResult
    func addForum(fromAddress address: String, pin: Bool = false) async throws -> Forum {
        let key = AddForumRequest(address: address, pin: pin)
        if case .detecting = addForumPhase, let running = addForumTask, running.key == key {
            return try await running.task.value
        }
        let task = Task { [weak self] () throws -> Forum in
            guard let self else { throw CancellationError() }
            return try await self.detectForum(key)
        }
        addForumTask = (key, task)
        addForumPhase = .detecting(address: address)
        defer {
            if addForumTask?.key == key {
                addForumTask = nil
                // Cancelled before it found an answer: not detecting any more.
                if case .detecting = addForumPhase { addForumPhase = .idle }
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Ends the detection `key` started with `phase`, unless a newer one replaced it.
    private func finishAddForum(_ key: AddForumRequest, _ phase: AddForumPhase) {
        if addForumTask?.key == key { addForumPhase = phase }
    }

    private func detectForum(_ key: AddForumRequest) async throws -> Forum {
        let address = key.address
        var firstCandidate: String?
        var lastFailure: NetworkFailure?
        for adapter in sites.adapters {
            for siteURL in adapter.siteURLCandidates(fromAddress: address) {
                firstCandidate = firstCandidate ?? siteURL
                guard ForumSite.parse(siteURL: siteURL).flatMap({ URLComponents(string: $0.origin)?.host }) != nil else {
                    continue
                }
                let net = await network(for: siteURL, pace: settings.forumRequestPace, inPage: false)
                let info: ForumSiteInfo
                do {
                    info = try await adapter.siteInfo(siteURL: siteURL, net: net)
                } catch {
                    lastFailure = NetworkFailure.classify(error)
                    continue
                }
                var directory = self.directory
                guard var forum = directory.upsert(
                    siteURL: siteURL,
                    kind: adapter.kind,
                    name: info.name,
                    iconURL: info.iconURL,
                    overwritingKind: true
                ) else {
                    continue
                }
                if key.pin {
                    directory.setPinned(true, siteURL: forum.siteURL)
                    forum = directory.forum(siteURL: forum.siteURL) ?? forum
                }
                if suppressedAutoAddSiteURL == forum.siteURL { suppressedAutoAddSiteURL = nil }
                self.directory = directory
                save()
                browser.refreshPageContext()
                finishAddForum(key, .recognized(kind: adapter.kind, siteURL: forum.siteURL))
                return forum
            }
        }
        guard let firstCandidate else {
            finishAddForum(key, .idle)
            throw ForumDirectoryError.invalidAddress
        }
        finishAddForum(key, lastFailure.map { .failed($0) } ?? .unsupported)
        throw ForumDirectoryError.notSupported(ForumSite.host(of: firstCandidate))
    }

    /// Fetches a forum's name and icon in the background. Only the name and
    /// icon change: a forum removed meanwhile is not added back, and its pin
    /// state is whatever the user set while the request ran.
    func refreshForumInfo(siteURL: String) {
        guard let normalized = ForumSite.normalizeSiteURL(siteURL),
              let forum = forum(for: normalized),
              let adapter = adapter(for: normalized)
        else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let net = await self.network(for: normalized, pace: self.settings.forumRequestPace, inPage: false)
            guard let info = try? await adapter.siteInfo(siteURL: normalized, net: net),
                  self.forum(for: normalized) != nil
            else {
                return
            }
            var directory = self.directory
            directory.upsert(siteURL: normalized, kind: forum.kind, name: info.name, iconURL: info.iconURL)
            guard directory.forums != self.forums else { return }
            self.directory = directory
            self.save()
        }
    }

    func pin(_ forum: Forum) {
        // A placeholder (`forumInfo`, kind .unknown) is not a forum the app can keep.
        guard forum.kind != .unknown || directory.forum(siteURL: forum.siteURL) != nil else { return }
        if suppressedAutoAddSiteURL == forum.siteURL { suppressedAutoAddSiteURL = nil }
        var directory = self.directory
        if directory.forum(siteURL: forum.siteURL) == nil {
            directory.upsert(siteURL: forum.siteURL, kind: forum.kind, name: forum.name, iconURL: forum.iconURL)
        }
        directory.setPinned(true, siteURL: forum.siteURL)
        self.directory = directory
        save()
    }

    func unpin(_ forum: Forum) {
        var directory = self.directory
        directory.setPinned(false, siteURL: forum.siteURL)
        self.directory = directory
        save()
    }

    func togglePin(_ forum: Forum) {
        if directory.forum(siteURL: forum.siteURL)?.isPinned == true {
            unpin(forum)
        } else {
            pin(forum)
        }
    }

    /// Reorders `pinnedForums` (offsets are into `pinnedForums`).
    func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        var directory = self.directory
        directory.movePinned(fromOffsets: source, toOffset: destination)
        self.directory = directory
        save()
    }

    /// Removes a forum from the directory. With `deleteData`, also cancels its
    /// active work and deletes its saved summaries, chats, agent runs, and
    /// watched topics.
    ///
    /// Work already running for the forum keeps running unless its data is
    /// deleted: a job resolved its adapter when it started and finishes with
    /// it (its pages and results are kept). Work still queued fails with
    /// `noForum` when the data is kept. The agent's forum falls back to the page's forum, and a page
    /// of the removed forum that is still open does not add it back.
    func removeForum(_ forum: Forum, deleteData: Bool) {
        let siteURL = forum.siteURL
        if deleteData {
            for record in activities where record.siteURL == siteURL && !record.status.isTerminal {
                cancel(record: record)
            }
            sessions = sessions.filter { $0.value.siteURL != siteURL }
            activities.removeAll { $0.siteURL == siteURL }
            agentRuns.removeAll { $0.siteURL == siteURL }
            watchedTopics.removeAll { $0.siteURL == siteURL }
            removeDigestCards(siteURL: siteURL)
        }
        if pageContext.siteURL == siteURL { suppressedAutoAddSiteURL = siteURL }
        var directory = self.directory
        directory.remove(siteURL: siteURL)
        self.directory = directory
        siteVisits.remove(siteURL: siteURL)
        if !deleteData { failQueuedWork(siteURL: siteURL, error: AssistantError.noForum) }
        if currentSiteURL == siteURL {
            currentSiteURL = (pageContext.siteURL.flatMap { self.directory.forum(siteURL: $0) }
                ?? Self.startForum(in: forums))?.siteURL
        }
        if browser.homeSiteURL == siteURL, (pageContext.siteURL != siteURL || browser.showsForumsHome) {
            browser.homeSiteURL = currentSiteURL
        }
        save()
        browser.refreshPageContext()
    }

    /// Work still waiting for its turn on a forum that was just removed never
    /// starts: it ends in the explicit failed state (no spinner) and the person
    /// is asked to add the forum again.
    private func failQueuedWork(siteURL: String, error: Error) {
        for record in activities where record.siteURL == siteURL && record.status == .queued {
            progress.remove(record.id)
            mutateRecord(record.id) {
                $0.status = .failed
                $0.statusText = String(localized: "Failed", comment: "Status of AI work that failed")
                $0.error = error.localizedDescription
                $0.completedAt = Date()
            }
            if record.origin == .user { presentError(error.localizedDescription) }
        }
    }

    /// Makes the forum current and loads its /latest.
    func openForum(_ forum: Forum) {
        // No adapter (a placeholder, or a platform this build lacks): leave the state alone.
        guard let adapter = sites.adapter(for: forum.kind) else { return }
        if suppressedAutoAddSiteURL == forum.siteURL { suppressedAutoAddSiteURL = nil }
        currentSiteURL = forum.siteURL
        browser.homeSiteURL = forum.siteURL
        browser.loadHome(adapter: adapter)
        panelRoute = .topic
    }

    /// Opens a suggested forum (added to the directory as recent on arrival).
    func openForum(_ suggested: SuggestedForum) {
        openForum(Forum(siteURL: suggested.siteURL, kind: suggested.kind, name: suggested.name))
    }

    // MARK: Saved answers

    /// The newest records kept in `agentRuns`, Research and Agent together.
    static let agentRunLimit = 50

    /// Puts a new record first and applies the shared cap and its sync prune.
    private func insertAgentRun(_ run: AgentRun) {
        agentRuns.insert(run, at: 0)
        cloudSync.notePruned(kind: .run, ids: agentRuns.dropFirst(Self.agentRunLimit).map(\.id.uuidString))
        agentRuns = Array(agentRuns.prefix(Self.agentRunLimit))
    }

    /// Whether an answer needs saving: it cites a source (a Markdown link; a
    /// plain-text URL is none), or is long enough to be worth coming back to.
    /// "Done, the page is dark now" is not.
    static let savedAnswerMinimumLength = 200

    static func shouldSaveAnswer(text: String, sourceCount: Int) -> Bool {
        sourceCount > 0 || text.trimmingCharacters(in: .whitespacesAndNewlines).count >= savedAnswerMinimumLength
    }

    /// Saves one Agent turn's final answer as an `AgentRun` record (see
    /// design-one-loop "Agent answers in History"): the question, the answer
    /// and its sources, with the visited topics so retention keeps them. The
    /// tool log stays in the task record.
    @discardableResult
    func saveAgentAnswer(_ answer: BrowserAgentAnswer) -> AgentRun? {
        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Forum tools ran: the forum's site URL. Otherwise the page's origin.
        let sample = answer.shapes.lazy.compactMap { shape -> URL? in
            switch shape {
            case .thread(let thread): URL(string: thread.url)
            case .list(let list): list.items.first.flatMap { URL(string: $0.url) }
            }
        }.first
        let forumURL = sample.flatMap { siteURL(containing: $0) }
        let siteURL = forumURL ?? Self.origin(ofPage: answer.pageURL) ?? ""

        let visits = AgentSources.visits(of: answer.shapes)
        var sources: [SavedSource] = []
        if forumURL != nil || !answer.shapes.isEmpty {
            let parse = linkParser(siteURL: siteURL, shapes: answer.shapes)
            sources = AgentSources.extract(from: text, visits: visits, parse: parse)
                .prefix(SavedSource.limit).map(SavedSource.init)
        }
        // Only cited Markdown links count; topics read but not linked are listed, not "sources".
        guard Self.shouldSaveAnswer(text: text, sourceCount: sources.filter(\.cited).count) else { return nil }

        var run = AgentRun(
            siteURL: siteURL, goal: answer.question, provider: answer.provider, model: answer.model, origin: answer.origin
        )
        run.loop = .agent
        run.result = .completed
        run.answer = text
        run.initialAnswer = text
        run.sources = sources
        if forumURL != nil {
            var seen = Set<String>()
            run.topicIDs = visits.compactMap(\.topicID).filter { !$0.isEmpty && seen.insert($0).inserted }
            if let links = adapter(for: siteURL)?.links {
                var found: [(url: URL, topicID: String)] = []
                for shape in answer.shapes {
                    switch shape {
                    case .thread(let thread):
                        if let url = URL(string: thread.url), let id = thread.id, !id.isEmpty { found.append((url: url, topicID: id)) }
                    case .list(let list):
                        for item in list.items {
                            if let url = URL(string: item.url), let id = item.id, !id.isEmpty { found.append((url: url, topicID: id)) }
                        }
                    }
                }
                run.remember(found, links: links)
            }
        }
        run.createdAt = answer.startedAt
        run.completedAt = Date()
        insertAgentRun(run)
        save()
        return run
    }

    /// `scheme://host` of a page address.
    static func origin(ofPage pageURL: String) -> String? {
        guard let url = URL(string: pageURL), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        return "\(scheme)://\(host)"
    }

    /// Whether `run`'s `siteURL` is a forum (a Research run's always is). An
    /// Agent record from an ordinary page must not become a forum.
    func isForumRecord(_ run: AgentRun) -> Bool {
        run.loop == .research || forum(for: run.siteURL) != nil || adapter(for: run.siteURL) != nil
    }

    func deleteAgentRun(id: UUID) {
        guard let run = agentRuns.first(where: { $0.id == id }), run.isFinished else {
            return
        }
        agentRuns.removeAll { $0.id == id }
        save()
    }

    /// Every saved answer, an old Research run or an Agent answer, opens
    /// read-only in History (`SavedAnswerView`).
    func openAgentRun(id: UUID) {
        guard agentRuns.contains(where: { $0.id == id }) else { return }
        savedAnswerRunID = id
        openPanelRoute(.history)
    }

    /// A source tapped in `SavedAnswerView`: the sources become the current
    /// list, History closes and the browser opens the page.
    func openSavedSource(_ source: AgentSources.Source, of sources: [AgentSources.Source], siteURL: String) {
        followSources(sources, selecting: source, siteURL: siteURL)
        savedAnswerRunID = nil
        dismissHistoryIfNeeded()
        assistantMode = .summary
        openLink(source.url)
        panelRoute = .topic
        stepDownDrawerIfShown()
    }

    /// Another link in a saved answer: History closes and the browser opens it.
    func openSavedLink(_ url: URL) {
        savedAnswerRunID = nil
        dismissHistoryIfNeeded()
        assistantMode = .summary
        openLink(url)
        panelRoute = .topic
        stepDownDrawerIfShown()
    }

    func showForumOverview() {
        guard currentTopic == nil, assistantPageState == .forumHome else { return }
        assistantMode = .summary
    }

    /// A saved run's outcome. Nothing runs them any more: one with no
    /// result was closed out at launch, so this is only a fallback.
    func status(of run: AgentRun) -> WorkStatus {
        run.result?.workStatus ?? .cancelled
    }

    // MARK: Watched topics

    func isWatched(topicKey: String) -> Bool {
        watchedTopics.contains { $0.topicKey == topicKey }
    }

    /// Watches or unwatches the current topic, fetching its post count when
    /// the app has not pulled it yet.
    func toggleWatchCurrentTopic() {
        guard let topic = currentTopic else { return }
        if isWatched(topicKey: topic.topicKey) {
            unwatch(topicKey: topic.topicKey)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var count = self.sessions[topic.topicKey]?.totalPosts
            if count == nil, let adapter = self.adapter(for: topic.siteURL) {
                count = try? await adapter.overview(
                    TopicRef(siteURL: topic.siteURL, topicID: topic.topicID),
                    net: await self.network(for: topic.siteURL, pace: self.settings.forumRequestPace)
                ).postCount
            }
            await self.watch(
                siteURL: topic.siteURL,
                topicID: topic.topicID,
                url: topic.url,
                title: topic.title,
                knownPostCount: count ?? 0
            )
        }
    }

    func watch(siteURL: String, topicID: String, url: URL, title: String, knownPostCount: Int) async {
        let watched = WatchedTopic(
            siteURL: siteURL,
            topicID: topicID,
            url: url,
            title: title,
            knownPostCount: knownPostCount
        )
        guard !isWatched(topicKey: watched.topicKey) else { return }
        watchedTopics.append(watched)
        save()
        if !notificationsAuthorized {
            notificationsAuthorized = await notifier.requestAuthorization()
        }
        WatchBackgroundRefresh.schedule()
    }

    func unwatch(topicKey: String) {
        watchedTopics.removeAll { $0.topicKey == topicKey }
        save()
    }

    func markWatchedSeen(topicKey: String) {
        guard let index = watchedTopics.firstIndex(where: { $0.topicKey == topicKey }) else { return }
        watchedTopics[index].markSeen()
        save()
    }

    func openWatched(_ watched: WatchedTopic) {
        dismissHistoryIfNeeded()
        dismissSettingsIfNeeded()
        markWatchedSeen(topicKey: watched.topicKey)
        browser.load(watched.url)
        panelRoute = .topic
        stepDownDrawerIfShown()
    }

    /// Checks every watched topic (on every forum) for new replies. In the
    /// foreground new replies can queue a summary refresh; in the background
    /// they post a notification.
    ///
    /// One check runs at a time (a timer, foreground, and background refresh
    /// can overlap; the later ones return at once). Topics unwatched while the
    /// check is fetching are skipped, and the auto-refresh setting is read
    /// when the replies arrive, so toggling it mid-check takes effect.
    ///
    /// Each topic is one paced request (`settings.forumRequestPace`). Topics
    /// checked longest ago go first, and a background check stops after
    /// `backgroundWatchCheckBudget`: the rest go first next time.
    func checkWatchedTopics(reason: WatchCheckReason) async {
        guard !watchedTopics.isEmpty, !isCheckingWatches else { return }
        isCheckingWatches = true
        defer { isCheckingWatches = false }
        lastWatchCheck = Date()
        var networks: [String: SiteNetwork] = [:]
        var arrivals: [(WatchedTopic, Int)] = []
        let pace = settings.forumRequestPace
        let isPaced = settings.forumRateLimitingEnabled
        let clock = forumService.pacer.clock
        let started = clock.now()

        for watched in Self.watchCheckOrder(watchedTopics) {
            if Task.isCancelled { break }
            if reason == .background,
               clock.now() - started + (isPaced ? pace.minimumInterval : 0) > Self.backgroundWatchCheckBudget {
                break
            }
            // A site without an adapter (its forum was removed) is skipped quietly.
            guard let adapter = adapter(for: watched.siteURL) else { continue }
            // The web view cannot run scripts while the app is in the background,
            // so background checks go straight to URLSession with each forum's cookies.
            let net: SiteNetwork
            if let known = networks[watched.siteURL] {
                net = known
            } else {
                net = await network(for: watched.siteURL, pace: pace, isPaced: isPaced, inPage: reason != .background)
                networks[watched.siteURL] = net
            }
            let result: Result<ForumTopicOverview, Error>
            do {
                result = .success(try await adapter.overview(
                    TopicRef(siteURL: watched.siteURL, topicID: watched.topicID),
                    net: net
                ))
            } catch {
                // Background time ran out: this topic stays due for next time.
                // (A URLSession request cancelled with the task throws
                // `URLError(.cancelled)`, not `CancellationError`.)
                if error is CancellationError || Task.isCancelled { break }
                result = .failure(error)
            }
            // The list may have changed during the fetch: find the topic again.
            guard let index = watchedTopics.firstIndex(where: { $0.topicKey == watched.topicKey })
            else { continue }
            switch result {
            case .success(let overview):
                let delta = watchedTopics[index].record(postCount: overview.postCount)
                if !overview.title.isEmpty { watchedTopics[index].title = overview.title }
                if var session = sessions[watched.topicKey] {
                    session.totalPosts = overview.postCount
                    session.lastCheckedAt = Date()
                    sessions[watched.topicKey] = session
                }
                if delta > 0 { arrivals.append((watchedTopics[index], delta)) }
            case .failure:
                watchedTopics[index].lastCheckedAt = Date()
            }
        }
        save()

        guard !arrivals.isEmpty else { return }
        let appIsActive = UIApplication.shared.applicationState == .active
        if reason == .background || !appIsActive {
            for (watched, delta) in arrivals where isWatched(topicKey: watched.topicKey) {
                await notifier.notifyNewReplies(topic: watched, count: delta)
            }
        }
        // Without a connected provider the refresh would only fail (and alert).
        if reason != .background, settings.watchAutoRefreshSummaries, isProviderReady(for: .assistant) {
            for (watched, _) in arrivals
            where isWatched(topicKey: watched.topicKey) && sessions[watched.topicKey]?.hasSummary == true {
                enqueueSummary(
                    for: ForumTopic(
                        siteURL: watched.siteURL,
                        topicID: watched.topicID,
                        url: watched.url,
                        title: watched.title
                    ),
                    origin: .automatic
                )
            }
        }
    }

    /// Background App Refresh gives about 30 seconds; paced checks stop well
    /// before that.
    static var backgroundWatchCheckBudget: TimeInterval = 20

    /// Topics never checked first, then the ones checked longest ago, so a
    /// check cut short never starves the same topics.
    nonisolated static func watchCheckOrder(_ topics: [WatchedTopic]) -> [WatchedTopic] {
        topics.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.lastCheckedAt ?? .distantPast
                let right = rhs.element.lastCheckedAt ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            drainSharedInbox()
            startWatchTimer()
            // API keys edited on another device arrive through iCloud
            // Keychain, which has no change notification on iOS (sync passes
            // re-read them too, but iCloud sync may be off).
            reloadProviderKeysFromKeychain()
            let stale = lastWatchCheck.map {
                Date().timeIntervalSince($0) >= Self.watchInterval
            } ?? true
            if stale {
                Task { [weak self] in await self?.checkWatchedTopics(reason: .foreground) }
            }
            Task { [weak self] in await self?.refreshNotificationAuthorization() }
            openTodayFromNotification()
            resumeDigestIfNeeded()
            podcast.resumeIfNeeded()
            workEnteredForeground()
            // After the inbox and the digest have started: where the launch lands.
            applyLaunchRuleIfNeeded()
        case .inactive:
            // Coalesced edits must not be lost if the app is closed next.
            flushPendingSaves()
        case .background:
            flushPendingSaves()
            watchTimer?.cancel()
            watchTimer = nil
            if !watchedTopics.isEmpty { WatchBackgroundRefresh.schedule() }
            // Summaries are made in the foreground only; the run continues
            // from the same card next time.
            pauseDigest()
            // Likewise the podcast's chapters; playback goes on.
            podcast.pauseGeneration()
            // Summaries, chats and Ask the forum finish if they can in the
            // time the system gives, else pause until the app is back.
            workEnteredBackground()
            if settings.dailyDigestEnabled { scheduleDigestPrefetch() }
        @unknown default:
            break
        }
        cloudSync.handleScenePhase(phase)
    }

    func requestNotificationAuthorization() {
        Task { [weak self] in
            guard let self else { return }
            self.notificationsAuthorized = await self.notifier.requestAuthorization()
        }
    }

    private func refreshNotificationAuthorization() async {
        let authorized = await notifier.isAuthorized()
        if notificationsAuthorized != authorized {
            notificationsAuthorized = authorized
        }
    }

    private func startWatchTimer() {
        watchTimer?.cancel()
        watchTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchInterval))
                guard !Task.isCancelled else { return }
                await self?.checkWatchedTopics(reason: .foreground)
            }
        }
    }

    func setInstructions(_ instructions: String, topicKey: String) {
        guard var session = sessions[topicKey] else { return }
        session.instructions = instructions
        session.updatedAt = Date()
        sessions[topicKey] = session
        save()
    }

    /// Instructions for a topic: its own when set, otherwise the global ones.
    func effectiveInstructions(for topicKey: String) -> String {
        PromptBuilder.effectiveInstructions(
            topic: sessions[topicKey]?.instructions ?? "",
            global: settings.systemPrompt
        )
    }

    func pullTopic() {
        guard let topic = currentTopic else {
            presentError(AssistantError.noTopic.localizedDescription)
            return
        }
        if activities.contains(where: {
            $0.topicKey == topic.topicKey && $0.type == .pull && !$0.status.isTerminal
        }) {
            panelRoute = .history
            return
        }
        guard activeTaskCount < 50 else {
            presentError(String(localized: "The task queue is full. Cancel or wait for an existing task."))
            return
        }

        let selection = settings.assistantModel
        let record = WorkRecord(
            type: .pull,
            siteURL: topic.siteURL,
            topicID: topic.topicID,
            title: topic.title,
            url: topic.url,
            provider: selection.provider,
            model: selection.model
        )
        activities.insert(record, at: 0)
        save()
        launch(recordID: record.id)
    }

    func cancel(record: WorkRecord) {
        runningTasks[record.id]?.task.cancel()
        runningTasks.removeValue(forKey: record.id)
        summaryFeeds.removeValue(forKey: record.id)?.cancel()
        streams.remove(record.id)
        progress.remove(record.id)
        Task {
            await limiter.cancel(workID: record.id)
        }
        mutateRecord(record.id) {
            $0.status = .cancelled
            $0.statusText = String(localized: "Cancelled", comment: "Status of AI work the user cancelled")
            $0.completedAt = Date()
        }
        resumeRecordWaiters(record.id, with: activities.first { $0.id == record.id })
        save()
    }

    /// Delete from History: a record in progress is cancelled first.
    func removeActivity(id: UUID) {
        if let record = activities.first(where: { $0.id == id }), !record.status.isTerminal {
            cancel(record: record)
        }
        deleteActivity(id: id)
    }

    func deleteActivity(id: UUID) {
        guard let record = activities.first(where: { $0.id == id }),
              record.status.isTerminal
        else {
            return
        }
        activities.removeAll { $0.id == id }
        save()
    }

    func open(record: WorkRecord) {
        if record.type == .agent, let runID = agentRunID(for: record) {
            openAgentRun(id: runID)
            return
        }
        dismissHistoryIfNeeded()
        assistantMode = .summary
        browser.load(record.url)
        panelRoute = .topic
        stepDownDrawerIfShown()
    }

    func open(session: TopicSession) {
        dismissHistoryIfNeeded()
        assistantMode = .summary
        browser.load(session.url)
        panelRoute = .topic
        stepDownDrawerIfShown()
    }

    private func dismissHistoryIfNeeded() {
        if router.item == .expanded(.history) {
            router.item = nil
        }
    }

    private func dismissSettingsIfNeeded() {
        if requestedSettingsPage != nil { requestedSettingsPage = nil }
        if router.item == .expanded(.settings) { router.item = nil }
        #if DEBUG
        if case .debugSettings = router.item { router.item = nil }
        #endif
    }

    private func stepDownDrawerIfShown() {
        if router.usesDrawer, router.drawerPhase.isPresented, router.drawerDetent == .large {
            router.drawerDetent = .medium
        }
    }

    func setKept(_ kept: Bool, topicKey: String) {
        guard var session = sessions[topicKey] else { return }
        session.kept = kept
        session.updatedAt = Date()
        sessions[topicKey] = session
        save()
    }

    func deleteSession(topicKey: String) {
        guard !activities.contains(where: {
            $0.topicKey == topicKey && !$0.status.isTerminal
        }) else {
            presentError(String(localized: "Cancel this topic’s active tasks before deleting it."))
            return
        }
        sessions.removeValue(forKey: topicKey)
        save()
    }

    /// Persists settings (API keys to the key store, the rest to the
    /// snapshot). Coalesced: views call this on every slider step, and every
    /// settings change schedules it anyway, so the write happens once the
    /// edits pause (`settingsSaveDelay`), when the app leaves the foreground,
    /// or with the next data save — whichever comes first.
    func saveSettings() {
        settingsSaveTask?.cancel()
        let delay = settingsSaveDelay
        settingsSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes coalesced settings edits and waits until the snapshot is on
    /// disk (scene inactive/background, background tasks, tests).
    func flushPendingSaves() {
        let currentTabsState = tabs.exportState()
        if settingsSaveTask != nil || currentTabsState != lastPersistedTabsState {
            save()
        }
        store.flush()
        tabStateStore.flush()
    }

    /// Writes API keys that changed since the last write; returns false (and
    /// reports) when the key store refuses one.
    @discardableResult
    private func persistChangedAPIKeys() -> Bool {
        #if DEBUG
        if suppressesPersistence { return true }
        #endif
        for provider in AIProvider.allCases {
            let key = settings.configuration(for: provider).apiKey
            guard persistedAPIKeys[provider] != key else { continue }
            do {
                try keyStore.set(key, for: provider)
                persistedAPIKeys[provider] = key
            } catch {
                presentError(error.localizedDescription)
                return false
            }
        }
        return true
    }

    /// Reacts to any settings edit (Settings, favorites, onboarding, reset).
    private func settingsDidChange(from old: AppSettings) {
        guard old != settings else { return }
        for provider in AIProvider.allCases {
            let oldConfiguration = old.configuration(for: provider)
            let newConfiguration = settings.configuration(for: provider)
            let endpointChanged = oldConfiguration.baseURL != newConfiguration.baseURL
            guard endpointChanged || oldConfiguration.apiKey != newConfiguration.apiKey else { continue }
            // Results of a test or model load for the old configuration are stale.
            connectionTestGeneration[provider, default: 0] &+= 1
            modelDiscoveryGeneration[provider, default: 0] &+= 1
            settingsStatus = ""
            if discoveredModels[provider] != nil { discoveredModels[provider] = nil }
        }
        if let role = needsProviderSetup, isProviderReady(for: role) { needsProviderSetup = nil }
        contentBlockingSettingsDidChange(from: old)
        let currentLinkSettings = linkSettings
        for tab in tabs.tabs {
            tab.browser.linkSettings = currentLinkSettings
        }
        digestSettingsDidChange(from: old)
        systemSettingsDidChange(from: old)
        let hadVoiceKey = !old.configuration(for: .gemini).apiKey.isEmpty || !old.configuration(for: .vertexAI).apiKey.isEmpty
        let hasVoiceKey = !settings.configuration(for: .gemini).apiKey.isEmpty || !settings.configuration(for: .vertexAI).apiKey.isEmpty
        if !hadVoiceKey, hasVoiceKey, !settings.voiceEnabled {
            settings.voiceEnabled = true
        }
        if old.voiceEnabled, !settings.voiceEnabled {
            voice.end()
        }
        if old.browserScriptsEnabled != settings.browserScriptsEnabled,
           scriptStore.isGlobalEnabled != settings.browserScriptsEnabled {
            scriptStore.isGlobalEnabled = settings.browserScriptsEnabled
        }
        if old.agentPageToolsEnabled != settings.agentPageToolsEnabled {
            for tab in tabs.tabs where tab.pageToolBridge.isEnabled != settings.agentPageToolsEnabled {
                tab.pageToolBridge.isEnabled = settings.agentPageToolsEnabled
            }
        }
        saveSettings()
    }

    /// Resets preferences; onboarding progress is not a preference and stays.
    /// Work already running keeps the provider it started with; queued work
    /// starts with the defaults (and fails clearly without a key).
    ///
    /// "Sync API keys" stays as it is: it says where this device's keys live,
    /// and the reset deletes them there. (Switching it back on would adopt the
    /// iCloud Keychain keys again, so a reset with it off would bring keys
    /// back on the next pass or launch; switching it on first would delete
    /// the synced keys on every device.)
    func resetSettings() {
        var fresh = AppSettings()
        fresh.hasCompletedOnboarding = settings.hasCompletedOnboarding
        fresh.syncAPIKeys = settings.syncAPIKeys
        settings = fresh
        discoveredModels = [:]
        settingsStatus = ""
        save()
        // A clean start for Spotlight too: rebuilt from the saved topics.
        resetSpotlightIndex()
    }

    /// Ends the walkthrough (first run or replay). Browsing, the Assistant,
    /// and running work are left as they are.
    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        save()
    }

    /// Loads `provider`'s models into `discoveredModels[provider]`. A result
    /// that arrives after that provider's base URL or key changed (or after a
    /// newer load started) is dropped and reported as `.stale`.
    @discardableResult
    func discoverModels(provider: AIProvider) async -> ProviderCheckResult {
        modelDiscoveryGeneration[provider, default: 0] &+= 1
        let generation = modelDiscoveryGeneration[provider]
        let configuration = settings.configuration(for: provider)
        settingsStatus = String(localized: "Loading models…")
        #if DEBUG
        if AssistantDebug.isActive,
           configuration.apiKey == "sample-key",
           configuration.baseURL == provider.defaultBaseURL {
            let models = AssistantDebug.sampleModels(for: provider)
            discoveredModels[provider] = models
            settingsStatus = String(localized: "Loaded \(models.count) models", comment: "AI provider settings: number of models found")
            return .success
        }
        #endif
        do {
            let models = try await aiService.discoverModels(configuration: configuration, provider: provider)
            guard generation == modelDiscoveryGeneration[provider] else { return .stale }
            discoveredModels[provider] = models
            settingsStatus = String(localized: "Loaded \(models.count) models", comment: "AI provider settings: number of models found")
            return .success
        } catch AssistantError.http(404, _) {
            guard generation == modelDiscoveryGeneration[provider] else { return .stale }
            discoveredModels[provider] = []
            settingsStatus = String(localized: "Loaded \(0) models", comment: "AI provider settings: number of models found")
            return .success
        } catch {
            guard generation == modelDiscoveryGeneration[provider] else { return .stale }
            settingsStatus = String(localized: "Model loading failed")
            return .failure(Self.modelDiscoveryFailureMessage(for: error, provider: provider))
        }
    }

    private static func modelDiscoveryFailureMessage(for error: Error, provider: AIProvider) -> String {
        if let assistantError = error as? AssistantError,
           case .http(let status, let detail) = assistantError {
            if (status == 401 || status == 403) && provider.requiresAPIKey {
                return String(
                    localized: "The key was refused (\(status)). Check it above.",
                    comment: "Provider settings › Models: API key refused with HTTP 401 or 403; placeholder is the HTTP status code"
                )
            }
            if let extracted = extractedJSONErrorMessage(from: detail) {
                return AssistantError.http(status, extracted).localizedDescription
            }
        }
        return error.localizedDescription
    }

    private static func extractedJSONErrorMessage(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let nested = (json["error"] as? [String: Any])?["message"] as? String {
            let trimmed = nested.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let direct = json["message"] as? String {
            let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Tests `provider` with its key and address. A result for a
    /// configuration the user has since changed (or superseded by a newer
    /// test of it) is `.stale` and leaves the status alone.
    @discardableResult
    func testConnection(provider: AIProvider) async -> ProviderCheckResult {
        var configuration = settings.configuration(for: provider)
        if provider != .vertexAI { configuration.model = "" }
        return await runConnectionTest(configuration: configuration, provider: provider)
    }

    /// Tests the provider and model a role uses. Stale also when the role's
    /// selection changed meanwhile.
    @discardableResult
    func testConnection(for role: ModelRole = .assistant) async -> ProviderCheckResult {
        let selection = settings.model(for: role)
        let configuration = settings.configuration(for: role)
        return await runConnectionTest(
            configuration: configuration,
            provider: selection.provider,
            role: (role, selection),
            isStillCurrent: { settings.model(for: role) == selection }
        )
    }

    func isTestingConnection(for provider: AIProvider) -> Bool {
        guard let active = activeConnectionTestGeneration[provider] else { return false }
        return active == connectionTestGeneration[provider]
    }

    func isTestingConnection(for role: ModelRole) -> Bool {
        guard let active = activeRoleConnectionTests[role] else { return false }
        return active.selection == settings.model(for: role) && isTestingConnection(for: active.provider)
    }

    private func runConnectionTest(
        configuration: ProviderConfiguration,
        provider: AIProvider,
        role: (ModelRole, ModelSelection)? = nil,
        isStillCurrent: () -> Bool = { true }
    ) async -> ProviderCheckResult {
        connectionTestGeneration[provider, default: 0] &+= 1
        let generation = connectionTestGeneration[provider, default: 0]
        activeConnectionTestGeneration[provider] = generation
        if let (targetRole, selection) = role {
            activeRoleConnectionTests[targetRole] = (provider, generation, selection)
        }
        defer {
            if activeConnectionTestGeneration[provider] == generation {
                activeConnectionTestGeneration[provider] = nil
            }
            if let (targetRole, _) = role, activeRoleConnectionTests[targetRole]?.generation == generation {
                activeRoleConnectionTests[targetRole] = nil
            }
        }
        settingsStatus = String(localized: "Testing connection…")
        do {
            try await aiService.testConnection(configuration: configuration, provider: provider)
            guard generation == connectionTestGeneration[provider], isStillCurrent() else { return .stale }
            settingsStatus = String(localized: "Connection successful")
            return .success
        } catch {
            guard generation == connectionTestGeneration[provider], isStillCurrent() else { return .stale }
            settingsStatus = String(localized: "Connection failed")
            return .failure(error.localizedDescription)
        }
    }

    func configurationBinding(for provider: AIProvider) -> ProviderConfiguration {
        settings.configuration(for: provider)
    }

    func setConfiguration(_ configuration: ProviderConfiguration, for provider: AIProvider) {
        settings.setConfiguration(configuration, for: provider)
    }

    #if DEBUG
    /// The forum the UI-test seeds belong to.
    private static let uiTestSiteURL = "https://meta.discourse.org"
    private static let uiTestForumName = "Discourse Meta"

    private func seedUITestSession() {
        guard let url = URL(
            string: "https://meta.discourse.org/t/ui-test-topic/999999"
        ) else {
            return
        }
        let topic = ForumTopic(
            siteURL: Self.uiTestSiteURL,
            topicID: "999999",
            url: url,
            title: "Responsive UI test topic"
        )
        var session = TopicSession(
            siteURL: topic.siteURL,
            topicID: topic.topicID,
            url: topic.url,
            title: topic.title
        )
        session.seedSource("Sample forum source for UI verification.")
        session.summary = """
        # Card Strategy

        The discussion recommends **comparing annual fees** before applying.

        ## Key points

        - Review the welcome offer.
        - Confirm the spending requirement.

        > Keep screenshots of the offer terms.

        | Option | Reward |
        | --- | --- |
        | Sample card | 4x points |

        ```text
        Verify before applying
        ```
        """
        session.history = [
            ChatMessage(role: .user, content: "What is the main recommendation?"),
            ChatMessage(
                role: .assistant,
                content: "Compare the **full offer terms** before applying."
            )
        ]
        session.totalPosts = 12
        session.summaryPostCount = 12
        session.summaryUpdatedAt = Date()
        session.chatUpdatedAt = Date()
        currentTopic = topic
        seededPageContext = PageContext(
            url: topic.url,
            site: .discourse,
            siteURL: topic.siteURL,
            forumName: Self.uiTestForumName,
            topic: topic,
            state: .topic
        )
        sessions[topic.topicKey] = session
    }

    /// Replaces the in-memory data with a DEBUG seed (screenshots; see
    /// AppModel+Assistant.swift). Nothing is saved unless the user acts.
    func applyDebugSeed(_ seed: AssistantDebugSeed) {
        forums = seed.forums
        sessions = Dictionary(
            seed.sessions.map { ($0.topicKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        activities = seed.activities
        agentRuns = seed.agentRuns
        watchedTopics = seed.watchedTopics
        currentTopic = seed.currentTopic
        currentSiteURL = seed.currentForum?.siteURL
        seededPageContext = seed.pageContext
        // No automatic watch check (network, summary refresh) for the seed.
        lastWatchCheck = Date()
    }

    /// Advances a seeded running record (DEBUG sample only), the way a real
    /// job would: progress moves forward only.
    func debugAdvanceSample(recordID: UUID, progress: Double, statusText: String? = nil) {
        guard let current = activities.first(where: { $0.id == recordID }),
              current.status == .running
        else { return }
        self.progress.advance(recordID, to: progress)
        if let statusText, statusText != current.statusText {
            mutateRecord(recordID) { $0.statusText = statusText }
        }
    }

    private func seedUITestManageSession() {
        guard let deleteURL = URL(
            string: "https://meta.discourse.org/t/ui-test-delete/999997"
        ),
        let keepURL = URL(
            string: "https://meta.discourse.org/t/ui-test-keep/999998"
        ) else {
            return
        }

        let now = Date()
        var deleteSession = TopicSession(
            siteURL: Self.uiTestSiteURL,
            topicID: "999997",
            url: deleteURL,
            title: "Swipe test delete summary"
        )
        deleteSession.summary = "# Summary\n\nDelete this saved summary."
        deleteSession.totalPosts = 1
        deleteSession.summaryPostCount = 1
        deleteSession.summaryUpdatedAt = now

        var keepSession = TopicSession(
            siteURL: Self.uiTestSiteURL,
            topicID: "999998",
            url: keepURL,
            title: "Swipe test keep summary"
        )
        keepSession.summary = "# Summary\n\nKeep this saved summary."
        keepSession.totalPosts = 1
        keepSession.summaryPostCount = 1
        keepSession.summaryUpdatedAt = now

        var recent = WorkRecord(
            type: .summary,
            siteURL: Self.uiTestSiteURL,
            topicID: "999997",
            title: "Swipe test recent activity",
            url: deleteURL,
            provider: .openAI,
            model: "test-model"
        )
        recent.status = .completed
        recent.statusText = "Completed"
        recent.completedAt = now

        sessions = [
            deleteSession.topicKey: deleteSession,
            keepSession.topicKey: keepSession
        ]
        activities = [recent]
        currentTopic = nil
    }
    #endif

    private func launch(recordID: UUID) {
        guard runningTasks[recordID] == nil else { return }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.jobEnded(recordID: recordID, token: token) }
            guard let record = self.activities.first(where: { $0.id == recordID }) else {
                return
            }
            guard await self.limiter.acquire(
                topicID: record.topicKey,
                workID: record.id
            ) else {
                return
            }
            defer {
                Task { await self.limiter.release(workID: record.id) }
            }
            guard !Task.isCancelled else { return }
            await self.run(recordID: recordID, token: token)
        }
        runningTasks[recordID] = (token, task)
    }

    /// The task `token` launched is still the record's: not cancelled or
    /// paused (and maybe launched again since).
    private func isCurrentLaunch(_ recordID: UUID, token: UUID) -> Bool {
        runningTasks[recordID]?.token == token
    }

    /// A job's task is done (finished, failed, cancelled or paused).
    private func jobEnded(recordID: UUID, token: UUID) {
        // A paused job launched again has a new task: leave that one.
        if isCurrentLaunch(recordID, token: token) { runningTasks.removeValue(forKey: recordID) }
        // Nothing runs any more (finished or paused): the grace period is
        // not needed.
        if backgroundWork != nil, runningTasks.isEmpty { endBackgroundWork() }
        let current = activities.first { $0.id == recordID }
        if current == nil || current?.status.isTerminal == true {
            resumeRecordWaiters(recordID, with: current)
        }
    }

    // MARK: Background

    /// The app left the foreground: running work goes on for the grace
    /// period the system gives, then pauses (`pauseActiveWork`).
    private func workEnteredBackground() {
        guard !runningTasks.isEmpty, backgroundWork == nil else { return }
        let id = backgroundGrace.begin(name: "WukongMind work") { [weak self] in
            // On the main thread; the task must end before the handler returns.
            MainActor.assumeIsolated {
                self?.pauseActiveWork()
                self?.endBackgroundWork()
            }
        }
        if id == .invalid {
            pauseActiveWork()
        } else {
            backgroundWork = id
        }
    }

    /// Back in the foreground: paused work starts again.
    private func workEnteredForeground() {
        endBackgroundWork()
        // At launch, `restorePendingTasksIfNeeded` (once the UI is up) does it.
        guard didRestoreTasks else { return }
        for record in activities where record.status == .queued && runningTasks[record.id] == nil {
            mutateRecord(record.id) { $0.statusText = WorkRecord.waitingStatusText }
            launch(recordID: record.id)
        }
    }

    private func endBackgroundWork() {
        guard let id = backgroundWork else { return }
        backgroundWork = nil
        backgroundGrace.end(id)
    }

    /// Puts every queued or running job back in the queue, as a relaunch
    /// would (the pages it read are kept): the grace period ended, or a
    /// job's request failed because the app is in the background. On disk
    /// before the app is suspended.
    func pauseActiveWork() {
        for record in activities where !record.status.isTerminal {
            pause(recordID: record.id)
        }
        save()
        store.flush()
    }

    private func pause(recordID: UUID) {
        runningTasks[recordID]?.task.cancel()
        runningTasks.removeValue(forKey: recordID)
        summaryFeeds.removeValue(forKey: recordID)?.cancel()
        streams.remove(recordID)
        progress.remove(recordID)
        Task { await limiter.cancel(workID: recordID) }
        mutateRecord(recordID) {
            $0.status = .queued
            $0.statusText = String(localized: "Paused until WukongMind is open again", comment: "Status of AI work stopped because the app went to the background; it continues when the app is opened")
        }
    }

    /// The settings a job runs with, taken when it starts (not when it was
    /// queued): the provider, model and key selected at that moment, and the
    /// limits and instructions then. Edits made while it runs apply to the
    /// next job. Agent step and topic budgets can still be lowered mid-run.
    ///
    /// Queued work (summaries and pulls) runs with the assistant model.
    private func runSettings(for record: WorkRecord) -> RunSettings {
        runSettings(
            role: .assistant,
            topicKey: record.topicKey,
            batchLimit: record.batchLimit
        )
    }

    /// The same snapshot for work outside the queue (the daily digest).
    func runSettings(role: ModelRole, topicKey: String, batchLimit: Int? = nil) -> RunSettings {
        let resolved = { (role: ModelRole) -> RunSettings.Model in
            let provider = self.selection(for: role).provider
            return RunSettings.Model(
                provider: provider,
                configuration: RunSettings.resolvingAppleIntelligence(
                    self.settings.configuration(for: role),
                    provider: provider,
                    status: self.appleIntelligenceStatus
                )
            )
        }
        let main = resolved(role)
        return RunSettings(
            provider: main.provider,
            configuration: main.configuration,
            summarizer: role == .assistant ? main : resolved(.assistant),
            batchLimit: batchLimit ?? settings.summaryBatchLimit,
            contextLimit: settings.forumContextLimit,
            topicInstructions: effectiveInstructions(for: topicKey),
            globalInstructions: settings.systemPrompt,
            forumRequestPace: settings.forumRequestPace,
            forumRateLimitingEnabled: settings.forumRateLimitingEnabled
        )
    }

    /// The job is still wanted: not cancelled, and its record was not
    /// cancelled or deleted (cancel, clear data, remove forum) meanwhile.
    private func isLive(_ recordID: UUID) -> Bool {
        !Task.isCancelled && activities.first(where: { $0.id == recordID })?.status == .running
    }

    /// Call after every await, before writing results back.
    private func ensureLive(_ recordID: UUID) throws {
        guard isLive(recordID) else { throw CancellationError() }
    }

    /// Runs a job. `token`: its launch; a task of a paused job still
    /// unwinding must not touch the record a newer launch is running.
    private func run(recordID: UUID, token: UUID) async {
        guard var record = activities.first(where: { $0.id == recordID }),
              record.status == .queued
        else {
            return
        }
        // Topic chat and the old Research loop are gone: a chat or Research
        // record saved by an older version never runs.
        if record.type == .chat || record.type == .agent {
            mutateRecord(recordID) {
                $0.status = .cancelled
                $0.statusText = String(localized: "Cancelled", comment: "Status of AI work the user cancelled")
                $0.completedAt = Date()
            }
            save()
            return
        }
        let context = runSettings(for: record)
        // Recorded so Manage and the saved summary show what actually ran.
        record.provider = context.provider
        record.model = context.configuration.model
        // A restored record starts over; progress then only moves forward.
        progress.remove(recordID)
        mutateRecord(recordID) {
            $0.status = .running
            $0.statusText = String(localized: "Reading forum responses…", comment: "Status while downloading a topic's replies")
            $0.startedAt = Date()
            $0.provider = context.provider
            $0.model = context.configuration.model
        }
        save()

        do {
            if record.type != .pull {
                try context.requireReadyProvider()
            }
            switch record.type {
            case .summary:
                try await runSummary(recordID: recordID, record: record, context: context)
            case .pull:
                try await runPull(recordID: recordID, record: record, context: context)
            case .chat, .agent:
                break
            }
            // Finished after it was cancelled (a provider that ignores
            // cancellation): it stays cancelled.
            try ensureLive(recordID)
            mutateRecord(recordID) {
                $0.status = .completed
                $0.statusText = String(localized: "Completed", comment: "Status of finished AI work")
                $0.completedAt = Date()
            }
        } catch is CancellationError {
            // A paused job is back in the queue (or already running again):
            // it stays there. `cancel(record:)` wrote its own status.
            if isCurrentLaunch(recordID, token: token),
               activities.first(where: { $0.id == recordID })?.status == .running {
                mutateRecord(recordID) {
                    $0.status = .cancelled
                    $0.statusText = String(localized: "Cancelled", comment: "Status of AI work the user cancelled")
                    $0.completedAt = Date()
                }
            }
        } catch where backgroundWork != nil && isLive(recordID) && NetworkFailure.isUnreachable(error) {
            // The system cut the connection in the background: it waits for
            // the app to come back instead of failing.
            pause(recordID: recordID)
        } catch where !isLive(recordID) {
            // Cancelled or deleted meanwhile; its request failing is expected.
            if isCurrentLaunch(recordID, token: token),
               activities.first(where: { $0.id == recordID })?.status == .running {
                mutateRecord(recordID) {
                    $0.status = .cancelled
                    $0.statusText = String(localized: "Cancelled", comment: "Status of AI work the user cancelled")
                    $0.completedAt = Date()
                }
            }
        } catch {
            mutateRecord(recordID) {
                $0.status = .failed
                $0.statusText = String(localized: "Failed", comment: "Status of AI work that failed")
                $0.error = error.localizedDescription
                $0.completedAt = Date()
            }
            // Work the app started by itself shows its failure in Activity.
            if record.origin == .user { presentError(error.localizedDescription) }
        }
        if isCurrentLaunch(recordID, token: token) {
            streams.remove(recordID)
            progress.remove(recordID)
        }
        activities = Array(
            activities
                .filter {
                    !$0.status.isTerminal
                        || Date().timeIntervalSince($0.completedAt ?? $0.updatedAt)
                            < 24 * 60 * 60
                }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(100)
        )
        pruneSessions()
        save()
    }

    private func runPull(recordID: UUID, record: WorkRecord, context: RunSettings) async throws {
        guard let adapter = adapter(for: record.siteURL) else { throw AssistantError.noForum }
        var session = sessions[record.topicKey] ?? TopicSession(
            siteURL: record.siteURL,
            topicID: record.topicID,
            url: record.url,
            title: record.title
        )
        let fetch = try await fetchTopicPages(of: session, adapter: adapter, recordID: recordID, pace: context.forumRequestPace, isPaced: context.forumRateLimitingEnabled) { progress in
            await self.updateFetchProgress(recordID: recordID, progress: progress)
        }

        // Cancelled (or its forum's data deleted) while the page fetch was
        // finishing: do not write the session back.
        try ensureLive(recordID)
        session = sessions[record.topicKey] ?? session
        let now = Date()
        session.apply(fetch, at: now)
        session.updatedAt = now
        sessions[record.topicKey] = session
        save()
        progress.advance(recordID, to: 1)
    }

    /// Keeps a topic's freshly read pages in its existing session (the
    /// daily digest); a topic without one gets none.
    func storeFetchedPages(_ fetch: ForumFetchResult, topicKey: String) {
        guard var session = sessions[topicKey] else { return }
        session.apply(fetch, at: Date())
        sessions[topicKey] = session
        save()
    }

    private func runSummary(recordID: UUID, record: WorkRecord, context: RunSettings) async throws {
        #if DEBUG
        if AssistantDebug.has("-dc-fake-summary") {
            // `-dc-fake-summary-fails`: fails until Retry (`regenerate`).
            if AssistantDebug.has("-dc-fake-summary-fails"), record.regenerate != true {
                throw AssistantError.missingConfiguration("The sample summary failed on purpose.")
            }
            try await runFakeSummary(recordID: recordID, record: record)
            return
        }
        #endif
        guard let adapter = adapter(for: record.siteURL) else { throw AssistantError.noForum }
        var session = sessions[record.topicKey] ?? TopicSession(
            siteURL: record.siteURL,
            topicID: record.topicID,
            url: record.url,
            title: record.title
        )
        let tracker = SummaryProgressTracker(
            cachedPages: session.rawPages.count,
            inputCharacters: session.source.count,
            previousSummaryCharacters: session.hasSummary ? session.summary.count : nil
        )
        let feed = startSummaryFeed(recordID: recordID, tracker: tracker)
        defer { stopSummaryFeed(recordID, feed) }
        let fetch = try await fetchTopicPages(of: session, adapter: adapter, recordID: recordID, pace: context.forumRequestPace, isPaced: context.forumRateLimitingEnabled) { progress in
            await self.updateFetchProgress(recordID: recordID, progress: progress)
        }

        // Cancelled (or its forum's data deleted) while the page fetch was
        // finishing: do not write the session back.
        try ensureLive(recordID)
        session = sessions[record.topicKey] ?? session
        let now = Date()
        session.apply(fetch, at: now)
        session.updatedAt = now
        sessions[record.topicKey] = session
        save()

        if fetch.unchanged,
           record.regenerate != true,
           session.hasSummary,
           session.summaryPostCount == fetch.totalPosts {
            mutateRecord(recordID) {
                $0.statusText = String(localized: "Saved summary already includes every reply.")
            }
            feed.finish()
            return
        }

        mutateRecord(recordID) {
            $0.statusText = fetch.newPosts > 0 && session.hasSummary
                ? String(localized: "Updating summary with \(fetch.newPosts) new posts…", comment: "Status while a saved summary is updated with the topic's new replies")
                : String(localized: "Generating summary…")
        }
        let content = fetch.content
        feed.setInputCharacters(content.count)
        streams.start(recordID)
        let summary = try await aiService.generateSummary(
            content: content,
            configuration: context.configuration,
            provider: context.provider,
            customPrompt: context.topicInstructions,
            discussion: adapter.discussion,
            batchLimit: context.batchLimit,
            onDelta: { delta in
                // Deltas of a cancelled job must not recreate its stream.
                guard self.isLive(recordID) else { return }
                self.streams.append(delta, to: recordID)
            },
            onProgress: { feed.handle($0) }
        )

        try ensureLive(recordID)
        feed.finish()
        session = sessions[record.topicKey] ?? session
        session.summary = summary
        session.summaryPostCount = fetch.totalPosts
        session.provider = context.provider
        session.model = context.configuration.model
        let finishedAt = Date()
        session.summaryUpdatedAt = finishedAt
        session.updatedAt = finishedAt
        sessions[record.topicKey] = session
    }

    #if DEBUG
    /// `-dc-fake-summary`: a summary run that reads nothing and calls no AI.
    /// It streams the sample summary (with `#N` citations) one section at a
    /// time, then saves it as the open topic's summary.
    private func runFakeSummary(recordID: UUID, record: WorkRecord) async throws {
        let text = SampleContent.current.tipsSummary
        let sections = text.components(separatedBy: "\n\n## ")
        streams.start(recordID)
        try await Task.sleep(for: .seconds(1.2))
        for (index, section) in sections.enumerated() {
            guard activities.contains(where: { $0.id == recordID && !$0.status.isTerminal }) else { return }
            streams.append(index == 0 ? section : "\n\n## " + section, to: recordID)
            try await Task.sleep(for: .milliseconds(500))
        }
        var session = sessions[record.topicKey] ?? TopicSession(
            siteURL: record.siteURL, topicID: record.topicID, url: record.url, title: record.title
        )
        if session.source.isEmpty { session.seedSource("Sample post and replies for \(record.title).") }
        session.summary = text
        session.totalPosts = max(session.totalPosts ?? 0, 68)
        session.summaryPostCount = session.totalPosts
        session.provider = record.provider
        session.model = record.model
        session.summaryUpdatedAt = Date()
        session.updatedAt = Date()
        sessions[record.topicKey] = session
    }
    #endif

    // MARK: Forum tools

    /// The saved run an old Research work record belongs to.
    func agentRunID(for record: WorkRecord) -> UUID? {
        guard record.topicID.hasPrefix(Self.agentTopicPrefix) else { return nil }
        return UUID(uuidString: String(record.topicID.dropFirst(Self.agentTopicPrefix.count)))
    }

    var forumToolService: ForumToolService {
        forumToolService(for: nil)
    }

    func forumToolService(for targetBrowser: ForumBrowserModel?) -> ForumToolService {
        ForumToolService(
            sessionLookup: { [unowned self] key in self.sessions[key] },
            sessionWrite: { [unowned self] key, session in self.sessions[key] = session },
            persist: { [unowned self] in self.save() },
            makeNetwork: { [unowned self, weak targetBrowser] siteURL, pace, isPaced in
                await self.network(for: siteURL, pace: pace, isPaced: isPaced, browser: targetBrowser)
            },
            watchTopic: { [unowned self] siteURL, topicID, url, title, count in
                await self.watch(siteURL: siteURL, topicID: topicID, url: url, title: title, knownPostCount: count)
            }
        )
    }

    /// Builds per-run forum tool context when the browser is on a recognized
    /// forum home or topic page (`.maybe`, `.notForum`, and `.loading` do not count).
    func makeForumToolContext(for targetBrowser: ForumBrowserModel? = nil) -> ForumToolContext? {
        let page = targetBrowser?.pageContext ?? pageContext
        guard page.isForum,
              let kind = page.site,
              let siteURL = page.siteURL, !siteURL.isEmpty,
              let adapter = sites.adapter(for: kind),
              adapter.supportsAgent
        else {
            return nil
        }
        let rawName = page.forumName.isEmpty ? forum(for: siteURL)?.name : page.forumName
        let forumName = ForumSite.displayName(siteURL: siteURL, name: rawName)
        let scope = ForumRunScope(
            adapter: adapter,
            siteURL: siteURL,
            readBudget: { [weak self] in self?.settings.agentMaxTopicReads ?? AgentLimits.defaultMaxTopicReads },
            readLimit: settings.agentReadLimit,
            pace: settings.forumRequestPace,
            isPaced: settings.forumRateLimitingEnabled
        )
        let basePath = page.basePath.isEmpty ? (ForumSite.parse(siteURL: siteURL)?.basePath ?? "") : page.basePath
        let openTopicID = page.state == .topic
            ? (page.topic?.topicID ?? page.url.flatMap { adapter.recognizer.topicID(fromURL: $0, basePath: basePath) ?? adapter.recognizer.looseTopicID(in: $0) })
            : nil
        let openTopicURL = page.state == .topic ? (page.topic?.url ?? page.url)?.absoluteString : nil
        return ForumToolContext(
            service: forumToolService(for: targetBrowser),
            scope: scope,
            forumName: forumName,
            openTopicID: openTopicID,
            openTopicURL: openTopicURL
        )
    }

    /// Builds per-run learned-site context when Page tools is enabled and the open page has no built-in adapter.
    func makeLearnedSiteContext(
        for targetBrowser: ForumBrowserModel? = nil,
        pageToolBridge: PageToolBridge? = nil
    ) -> LearnedSiteContext? {
        guard settings.agentPageToolsEnabled, makeForumToolContext(for: targetBrowser) == nil else { return nil }
        let bridge = pageToolBridge
            ?? tabs.tabs.first(where: { $0.browser === targetBrowser })?.pageToolBridge
            ?? self.pageToolBridge
        guard bridge.isEnabled else { return nil }
        let page = targetBrowser?.pageContext ?? pageContext
        let candidateURL = page.url ?? targetBrowser?.webView.url ?? browser.webView.url
        guard let url = candidateURL,
              let host = SiteToolState.normalizedHost(from: url),
              let state = siteToolStateStore.state(forHost: host) else { return nil }
        let scope = LearnedRunScope(
            readBudget: { [weak self] in self?.settings.agentMaxTopicReads ?? AgentLimits.defaultMaxTopicReads },
            readLimit: settings.agentReadLimit
        )
        return LearnedSiteContext(host: host, state: state, pageToolBridge: bridge, scriptStore: scriptStore, scope: scope)
    }

    /// Reads a job's topic, cached pages reused. Every new page goes into
    /// the topic's session as it arrives, so a read that fails, is paused or
    /// is killed keeps what it fetched; a later read fetches only the rest.
    private func fetchTopicPages(
        of session: TopicSession,
        adapter siteAdapter: any SiteAdapter,
        recordID: UUID,
        pace: ForumRequestPace,
        isPaced: Bool,
        progress: @escaping @Sendable (ForumFetchProgress) async -> Void
    ) async throws -> ForumFetchResult {
        let net = await network(for: session.siteURL, pace: pace, isPaced: isPaced)
        let template = session
        let result = try await siteAdapter.readTopic(
            TopicReadRequest(
                topic: TopicRef(siteURL: session.siteURL, topicID: session.topicID),
                cachedPages: session.rawPages,
                knownTotalPosts: session.totalPosts
            ),
            net: net,
            progress: progress,
            onPage: { page in await self.keepFetchedPage(page, recordID: recordID, into: template) }
        )
        return result
    }

    /// A page a job fetched, into its topic's session (made from `template`
    /// for a topic read for the first time). Not once the job ended (a
    /// cancel) or its record is gone (its forum's data was deleted).
    private func keepFetchedPage(_ page: RawForumPage, recordID: UUID, into template: TopicSession) {
        guard activities.contains(where: { $0.id == recordID && !$0.status.isTerminal }) else { return }
        var session = sessions[template.topicKey] ?? template
        session.apply(page: page)
        sessions[template.topicKey] = session
        save()
    }

    private func updateFetchProgress(recordID: UUID, progress: ForumFetchProgress) {
        // A late page report of a cancelled job must not touch its record.
        guard isLive(recordID),
              let record = activities.first(where: { $0.id == recordID })
        else { return }
        if let feed = summaryFeeds[recordID] {
            feed.handle(.fetched(completedPages: progress.completedPages, totalPages: progress.totalPages))
        } else {
            self.progress.advance(recordID, to: WorkProgress.fetch(progress.fraction, type: record.type))
        }
        if record.statusText != progress.message {
            mutateRecord(recordID) { $0.statusText = progress.message }
        }
    }

    /// Moves a running job's determinate progress forward (never back).
    private func advanceProgress(recordID: UUID, to fraction: Double) {
        guard isLive(recordID) else { return }
        progress.advance(recordID, to: fraction)
    }

    /// Starts a clock-driven summary feed; ticks go only through `ProgressStore`.
    private func startSummaryFeed(
        recordID: UUID,
        tracker: SummaryProgressTracker,
        keepsStatusText: Bool = false,
        map: @escaping (Double) -> Double = { $0 }
    ) -> SummaryProgressFeed {
        summaryFeeds.removeValue(forKey: recordID)?.cancel()
        let token = runningTasks[recordID]?.token
        let output = ThrottledProgress { [weak self] fraction, statusText in
            guard let self, let token, self.isCurrentLaunch(recordID, token: token), self.isLive(recordID) else { return }
            self.progress.advance(recordID, to: fraction)
            if let statusText, !keepsStatusText,
               self.activities.first(where: { $0.id == recordID })?.statusText != statusText {
                self.mutateRecord(recordID) { $0.statusText = statusText }
            }
        }
        let feed = SummaryProgressFeed(tracker: tracker, output: output, map: map)
        summaryFeeds[recordID] = feed
        return feed
    }

    private func stopSummaryFeed(_ recordID: UUID, _ feed: SummaryProgressFeed) {
        feed.cancel()
        if summaryFeeds[recordID] === feed { summaryFeeds.removeValue(forKey: recordID) }
    }

    private func mutateRecord(_ id: UUID, mutation: (inout WorkRecord) -> Void) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        mutation(&activities[index])
        activities[index].updatedAt = Date()
    }

    /// Drops old sessions and agent-read pages (SessionRetention.swift).
    private func pruneSessions(now: Date = Date()) {
        var protected = Set(watchedTopics.map(\.topicKey))
        for record in activities where !record.status.isTerminal { protected.insert(record.topicKey) }
        if let topicKey = currentTopic?.topicKey { protected.insert(topicKey) }
        let plan = SessionRetention.plan(
            sessions: sessions,
            protected: protected,
            citedByRuns: SessionRetention.topicKeys(citedBy: agentRuns),
            now: now
        )
        guard !plan.isEmpty else { return }
        var kept = sessions
        for key in plan.remove { kept.removeValue(forKey: key) }
        for key in plan.dropPages {
            kept[key]?.dropFetchedText()
        }
        sessions = kept
        // Pruned, not deleted: other devices keep their copies.
        cloudSync.notePruned(kind: .session, ids: plan.remove)
    }

    /// Saves the snapshot (and any changed API keys). Data changes save at
    /// once; settings edits are coalesced through `saveSettings()`. The file
    /// is written in the background (`PersistentStore.scheduleSave`);
    /// `flushPendingSaves()` waits for it.
    func save() {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        #if DEBUG
        // Sample and fixture launches never write over the real snapshot,
        // and their placeholder or blanked keys stay in memory.
        if suppressesPersistence { return }
        #endif
        cloudSync.localDataDidChange()
        persistChangedAPIKeys()
        let tabsState = tabs.exportState()
        lastPersistedTabsState = tabsState
        let snapshot = AppSnapshot(
            settings: settings.persistable,
            sessions: Array(sessions.values),
            activities: activities,
            agentRuns: agentRuns,
            watchedTopics: watchedTopics,
            forums: forums,
            browserTabs: tabsState
        )
        // Encoded and written off the main actor; rapid saves coalesce.
        store.scheduleSave(snapshot) { [weak self] error in
            self?.presentError(String(localized: "Unable to save app data: \(error.localizedDescription)", comment: "Error; the placeholder is the system's reason"))
        }
    }

    private var activeTaskCount: Int {
        activities.lazy.filter { !$0.status.isTerminal }.count
    }

    // MARK: Sync hooks (AppModel+CloudSync.swift)

    /// Replaces the synced collections with merged ones and saves.
    func replaceSyncedData(
        sessions: [String: TopicSession],
        agentRuns: [AgentRun],
        watchedTopics: [WatchedTopic],
        forums: [Forum]
    ) {
        if self.sessions != sessions {
            self.sessions = sessions
        }
        if self.agentRuns != agentRuns {
            self.agentRuns = agentRuns
        }
        if self.watchedTopics != watchedTopics { self.watchedTopics = watchedTopics }
        if self.forums != forums {
            let removed = Set(self.forums.map(\.siteURL)).subtracting(forums.map(\.siteURL))
            self.forums = forums
            // Like `removeForum`: its open page must not add it straight back,
            // and a current forum removed elsewhere falls back.
            if let page = pageContext.siteURL, removed.contains(page) { suppressedAutoAddSiteURL = page }
            if let current = currentSiteURL, forum(for: current) == nil {
                currentSiteURL = (pageContext.siteURL.flatMap { forum(for: $0) } ?? Self.startForum(in: forums))?.siteURL
                if browser.homeSiteURL == current, (pageContext.siteURL != current || browser.showsForumsHome) {
                    browser.homeSiteURL = currentSiteURL
                }
            }
        }
        save()
    }

    /// Every synced record the app holds, as "kind/id" (to notice deletes).
    func syncRecordKeys() -> Set<String> {
        var keys = Set<String>(
            minimumCapacity: sessions.count + agentRuns.count + watchedTopics.count
                + forums.count + scriptStore.scripts.count + 1
        )
        for key in sessions.keys { keys.insert(SyncRecord.recordKey(kind: .session, id: key)) }
        for run in agentRuns { keys.insert(SyncRecord.recordKey(kind: .run, id: run.id.uuidString)) }
        for watched in watchedTopics { keys.insert(SyncRecord.recordKey(kind: .watched, id: watched.topicKey)) }
        for forum in forums { keys.insert(SyncRecord.recordKey(kind: .forum, id: forum.siteURL)) }
        for script in scriptStore.scripts { keys.insert(SyncRecord.recordKey(kind: .script, id: script.id)) }
        return keys
    }

    /// Adopts API keys that changed in the key store behind the app's back
    /// (iCloud Keychain delivered them). A key with an unsaved edit here is
    /// left alone. Called at the start of every sync pass.
    func reloadProviderKeysFromKeychain() {
        var updated = settings
        for provider in AIProvider.allCases {
            let stored = keyStore.value(for: provider)
            let persisted = persistedAPIKeys[provider] ?? ""
            guard stored != persisted, updated.configuration(for: provider).apiKey == persisted else { continue }
            var configuration = updated.configuration(for: provider)
            configuration.apiKey = stored
            updated.setConfiguration(configuration, for: provider)
            persistedAPIKeys[provider] = stored
        }
        if updated != settings { settings = updated }
    }

    // MARK: Capability Tools

    private func resumeRecordWaiters(_ recordID: UUID, with record: WorkRecord?) {
        recordWaiters.removeValue(forKey: recordID)?.values.forEach { $0.resume(returning: record) }
    }

    private func cancelRecordWaiter(recordID: UUID, waiterID: UUID) {
        guard let continuation = recordWaiters[recordID]?.removeValue(forKey: waiterID) else { return }
        if recordWaiters[recordID]?.isEmpty == true { recordWaiters.removeValue(forKey: recordID) }
        continuation.resume(returning: nil)
    }

    private func awaitRecord(id recordID: UUID) async throws -> WorkRecord {
        let waiterID = UUID()
        let finished = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WorkRecord?, Never>) in
                if Task.isCancelled { continuation.resume(returning: nil); return }
                guard let current = activities.first(where: { $0.id == recordID }), !current.status.isTerminal else {
                    continuation.resume(returning: activities.first(where: { $0.id == recordID })); return
                }
                recordWaiters[recordID, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRecordWaiter(recordID: recordID, waiterID: waiterID) }
        }
        try Task.checkCancellation()
        guard let finished else { throw CancellationError() }
        return finished
    }

    /// Runs or joins a thread summary job and awaits its completion without cancelling it on Stop.
    func summarizeForTool(_ topic: ForumTopic) async throws -> TopicSession {
        let recordID: UUID
        if let active = activities.first(where: { $0.topicKey == topic.topicKey && $0.type == .summary && !$0.status.isTerminal }) {
            recordID = active.id
        } else {
            guard enqueueSummary(for: topic, origin: .automatic),
                  let created = activities.first(where: { $0.topicKey == topic.topicKey && $0.type == .summary }) else {
                throw AssistantError.missingConfiguration(String(localized: "The task queue is full. Cancel or wait for an existing task."))
            }
            recordID = created.id
        }
        let finished = try await awaitRecord(id: recordID)
        switch finished.status {
        case .completed:
            guard let session = sessions[topic.topicKey], session.hasSummary else { throw AssistantError.emptyResponse }
            return session
        case .failed:
            throw CapabilityToolError(finished.error.isEmpty ? String(localized: "Failed") : finished.error)
        case .cancelled, .queued, .running:
            throw CancellationError()
        }
    }

    var capabilityToolContext: CapabilityToolContext {
        capabilityToolContext(for: nil)
    }

    func capabilityToolContext(for targetBrowser: ForumBrowserModel?) -> CapabilityToolContext {
        CapabilityToolContext(
            resolveTopicID: { [weak self, weak targetBrowser] id in
                guard let self else { throw CancellationError() }
                return try await self.resolveCapabilityTopic(topicID: id, for: targetBrowser)
            },
            resolveTopicURL: { [weak self, weak targetBrowser] url in
                guard let self else { throw CancellationError() }
                return try await self.resolveCapabilityTopic(urlString: url, for: targetBrowser)
            },
            summarizeThread: { [weak self] topic in guard let self else { throw CancellationError() }; return try await self.summarizeForTool(topic) },
            summarizeText: { [weak self] text in guard let self else { throw CancellationError() }; return try await self.summarizePlainText(text) },
            existingThreadSummary: { [weak self] key in
                guard let self, let s = self.sessions[key], s.hasSummary, !self.hasActiveWork(topicKey: key, type: .summary) else { return nil }
                return s
            },
            readAloud: { [weak self] id, title, text in guard let self else { throw CancellationError() }; return try self.startReadAloud(id: id, title: title, text: text) },
            followThread: { [weak self] r in await self?.watch(siteURL: r.topic.siteURL, topicID: r.topic.topicID, url: r.topic.url, title: r.topic.title, knownPostCount: r.knownPostCount) },
            notify: { [notifier] title, body in try await notifier.notify(title: title, body: body) }
        )
    }

    func session(forThreadShape thread: ThreadShape) -> TopicSession? {
        if let id = thread.id, let url = URL(string: thread.url), let siteURL = ForumSite.siteURL(fromPage: url),
           let key = ForumSite.topicKey(siteURL: siteURL, topicID: id), let exact = sessions[key] {
            return exact
        }
        return sessions.values.first { $0.url.absoluteString == thread.url && (thread.id == nil || $0.topicID == thread.id) }
    }

    private func summarizePlainText(_ text: String) async throws -> String {
        let context = runSettings(role: .assistant, topicKey: "")
        try RunSettings.requireReady(provider: context.summarizer.provider, configuration: context.summarizer.configuration)
        return try await aiService.generateSummary(
            content: text, configuration: context.summarizer.configuration, provider: context.summarizer.provider,
            customPrompt: context.globalInstructions, discussion: .genericText, batchLimit: context.batchLimit, onDelta: { _ in }
        )
    }

    private func startReadAloud(id: String, title: String, text: String) throws -> Int {
        let stripped = PostCitations.stripped(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !PodcastController.readAloudChunks(PodcastSpeechCheck.speakable(stripped)).isEmpty else {
            throw CapabilityToolError("Nothing speakable to read aloud.")
        }
        if podcast.engineSelection() == .needsKey {
            throw CapabilityToolError("Google voices need a Google Gemini or Vertex AI key in Settings.")
        }
        let playlistID = PodcastController.readAloudPlaylistID(id)
        if podcast.player.playlist?.id == playlistID {
            if !podcast.player.isActive { podcast.player.play() }
        } else {
            podcast.readAloud(id: id, title: title, text: stripped)
        }
        guard podcast.player.playlist?.id == playlistID else { throw CapabilityToolError("Could not start audio playback.") }
        return CapabilityReadAloud.estimatedMinutes(for: stripped)
    }

    private func resolveCapabilityTopic(topicID rawID: String, for targetBrowser: ForumBrowserModel? = nil) async throws -> CapabilityResolvedThread {
        let id = try ForumToolService.requiredTopicID(["topic_id": rawID])
        let page = targetBrowser?.pageContext ?? pageContext
        let fallbackTopicSite = targetBrowser == nil ? currentTopic?.siteURL : page.topic?.siteURL
        guard let siteURL = page.siteURL ?? fallbackTopicSite, let adapter = adapter(for: siteURL) else {
            throw CapabilityToolError("No forum is open right now; pass a thread 'url' instead of 'topic_id'.")
        }
        return try await buildCapabilityThread(siteURL: siteURL, topicID: id, adapter: adapter, browser: targetBrowser)
    }

    private func resolveCapabilityTopic(urlString rawURL: String, for targetBrowser: ForumBrowserModel? = nil) async throws -> CapabilityResolvedThread {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ForumSite.origin(of: url) != nil else {
            throw CapabilityToolError("Invalid or unsupported thread URL '\(trimmed)'.")
        }
        if let host = url.host, let claimed = sites.claimedSite(forHost: host) {
            guard let id = claimed.adapter.recognizer.looseTopicID(in: url) else {
                throw CapabilityToolError("'\(trimmed)' is not a thread URL on \(claimed.adapter.recognizer.platformName).")
            }
            return try await buildCapabilityThread(siteURL: claimed.siteURL, topicID: id, adapter: claimed.adapter, browser: targetBrowser)
        }
        let pageSiteURL = targetBrowser?.pageContext.siteURL ?? pageContext.siteURL
        let knownSites = Array(Set(forums.map(\.siteURL) + [pageSiteURL].compactMap { $0 })).sorted { $0.count > $1.count }
        for knownSite in knownSites {
            guard let parsed = ForumSite.parse(siteURL: knownSite),
                  ForumSite.siteURL(fromPage: url, basePath: parsed.basePath) == parsed.siteURL,
                  let matched = adapter(for: parsed.siteURL) else { continue }
            guard let id = matched.recognizer.topicID(fromURL: url, basePath: parsed.basePath) ?? matched.recognizer.looseTopicID(in: url) else {
                throw CapabilityToolError("'\(trimmed)' is not a thread URL.")
            }
            return try await buildCapabilityThread(siteURL: parsed.siteURL, topicID: id, adapter: matched, browser: targetBrowser)
        }
        for candidateAdapter in sites.adapters {
            for candidate in candidateAdapter.siteURLCandidates(fromAddress: trimmed) {
                guard let parsed = ForumSite.parse(siteURL: candidate),
                      let id = candidateAdapter.recognizer.topicID(fromURL: url, basePath: parsed.basePath) ?? candidateAdapter.recognizer.looseTopicID(in: url) else { continue }
                let net = await network(for: parsed.siteURL, pace: settings.forumRequestPace, inPage: false, browser: targetBrowser)
                guard let info = try? await candidateAdapter.siteInfo(siteURL: parsed.siteURL, net: net) else { continue }
                var dir = self.directory
                if dir.upsert(siteURL: parsed.siteURL, kind: candidateAdapter.kind, name: info.name, iconURL: info.iconURL, visitedAt: nil) != nil {
                    self.directory = dir; save()
                }
                return try await buildCapabilityThread(siteURL: parsed.siteURL, topicID: id, adapter: candidateAdapter, browser: targetBrowser)
            }
        }
        throw CapabilityToolError("Could not recognize a supported forum thread at '\(trimmed)'.")
    }

    private func buildCapabilityThread(
        siteURL: String,
        topicID: String,
        adapter: any SiteAdapter,
        browser targetBrowser: ForumBrowserModel? = nil
    ) async throws -> CapabilityResolvedThread {
        let topicKey = TopicIdentity.key(siteURL: siteURL, topicID: topicID)
        if let active = activities.first(where: { $0.topicKey == topicKey && $0.type == .summary && !$0.status.isTerminal }) {
            return CapabilityResolvedThread(topic: ForumTopic(siteURL: siteURL, topicID: topicID, url: active.url, title: active.title), knownPostCount: sessions[topicKey]?.totalPosts ?? 0)
        }
        if let cached = sessions[topicKey] {
            return CapabilityResolvedThread(topic: ForumTopic(siteURL: siteURL, topicID: topicID, url: cached.url, title: cached.title), knownPostCount: cached.totalPosts ?? 0)
        }
        let info = try await adapter.overview(
            TopicRef(siteURL: siteURL, topicID: topicID),
            net: await network(for: siteURL, pace: settings.forumRequestPace, browser: targetBrowser)
        )
        let fallbackName = ForumSite.displayName(siteURL: siteURL, name: forum(for: siteURL)?.name)
        let title = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return CapabilityResolvedThread(
            topic: ForumTopic(siteURL: siteURL, topicID: topicID, url: info.url, title: title.isEmpty ? "\(fallbackName) topic \(topicID)" : title),
            knownPostCount: info.postCount
        )
    }
}

/// What a job runs with, captured when it starts (see `AppModel.runSettings`).
/// In memory only: the key is never written into a record.
struct RunSettings {
    /// A provider and its settings with the model to run.
    struct Model {
        var provider: AIProvider
        var configuration: ProviderConfiguration
    }

    /// The job's own model: the agent model for Ask the forum, else the
    /// assistant model.
    var provider: AIProvider
    var configuration: ProviderConfiguration
    /// The assistant model, for the agent's `summarize_topic` tool.
    var summarizer: Model
    var batchLimit: Int
    var contextLimit: Int
    /// The topic's own instructions, else the global ones.
    var topicInstructions: String
    var globalInstructions: String
    /// How quickly this job's requests go to the forum (taken at the start).
    var forumRequestPace: ForumRequestPace = .default
    var forumRateLimitingEnabled = true

    /// Fails with a clear message when the provider was disconnected (key
    /// deleted, settings reset) between queueing and starting.
    func requireReadyProvider() throws {
        try Self.requireReady(provider: provider, configuration: configuration)
    }

    static func requireReady(provider: AIProvider, configuration: ProviderConfiguration) throws {
        if configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AssistantError.missingConfiguration(String(localized: "Choose a model in Settings › AI models.", comment: "Error; Settings › AI models names the app's own Settings page"))
        }
        if provider.requiresAPIKey,
           configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AssistantError.missingConfiguration(
                String(localized: "\(provider.displayName) isn’t connected. Add an API key in Settings › AI models.", comment: "Error; the placeholder is the AI provider's name. Settings › AI models names the app's own Settings page.")
            )
        }
    }
}

/// A shared link waiting for its page to be detected.
private struct PendingShare {
    enum Action: String {
        case open, summary, chat, agent
    }

    var url: URL
    var action: Action
    /// Topic id in the shared URL (base path unknown until the probe).
    var topicID: String?
    /// Start the summary / pull once the topic is detected (false for deep
    /// links that the share extension did not queue).
    var autoRun = true
    /// The browser has reported the shared page itself (loading or loaded).
    var sawSharedPage = false
}

/// Extra time to run after the app leaves the foreground
/// (`UIApplication.beginBackgroundTask`); tests fake it.
@MainActor
protocol BackgroundGracing {
    /// `.invalid` when the system gives no time.
    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ id: UIBackgroundTaskIdentifier)
}

struct ApplicationBackgroundGrace: BackgroundGracing {
    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
    }

    func end(_ id: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(id)
    }
}
