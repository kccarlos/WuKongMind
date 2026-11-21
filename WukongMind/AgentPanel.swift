import SwiftUI
import UIKit

// MARK: - Unified Agent Runs & Status Line

enum BrowserAgentPanelView {
    static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.1f s", max(0.1, duration))
        }
        return String(format: "%.0f s", duration.rounded())
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    static func mascotPose(
        runState: BrowserAgentRunState,
        toolCalls: [BrowserAgentToolCallRow],
        reduceMotion: Bool
    ) -> DCMascotPose? {
        switch runState {
        case .running(let step, _):
            if reduceMotion {
                return .think
            }
            if let runningRow = toolCalls.last(where: \.isRunning) {
                if runningRow.toolName == "read_page" {
                    return .search
                }
                if runningRow.toolName == "tabs",
                   (try? JSONValue.parseObjectJSON(runningRow.argumentsJSON))?["action"]?.stringValue == "read" {
                    return .search
                }
                return .run
            }
            return step > 0 ? .run : .think
        case .completed:
            return .cheer
        case .idle, .stopped, .stepLimitReached, .failed:
            return nil
        }
    }

    static func statusText(
        runState: BrowserAgentRunState,
        developerMode: Bool,
        totalTokens: Int
    ) -> String? {
        let base: String
        switch runState {
        case .running(let step, _):
            if step <= 0 {
                base = String(localized: "Thinking…", comment: "Agent status line while waiting on the first model step")
            } else {
                base = String(localized: "Working · step \(step)", comment: "Agent status line while executing a step")
            }
            if developerMode && totalTokens > 0 {
                let tokensPart = String(localized: "\(formatTokens(totalTokens)) tokens", comment: "Browser agent footer token counter")
                return "\(base) · \(tokensPart)"
            }
            return base
        case .completed(let steps, let duration):
            base = String(localized: "Done · \(steps) steps · \(formatDuration(duration))", comment: "Browser agent footer status when a run finishes")
            if developerMode {
                let tokensPart = String(localized: "\(formatTokens(totalTokens)) tokens", comment: "Browser agent footer token counter")
                return "\(base) · \(tokensPart)"
            }
            return base
        case .idle, .stopped, .stepLimitReached, .failed:
            return nil
        }
    }
}

struct AgentStatusLine: View {
    let session: BrowserAgentSession
    let developerMode: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = session.runState
        if let pose = BrowserAgentPanelView.mascotPose(
            runState: state,
            toolCalls: session.runs.last?.toolCalls ?? [],
            reduceMotion: reduceMotion
        ),
           let text = BrowserAgentPanelView.statusText(
            runState: state,
            developerMode: developerMode,
            totalTokens: session.tokenUsage.totalTokens
        ) {
            let singleLineLimit: Int? = dynamicTypeSize.isAccessibilitySize ? nil : 1
            let isCompleted: Bool = {
                if case .completed = state { return true }
                return false
            }()
            HStack(spacing: 8) {
                DCMascotView(pose: pose, size: 40)
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(DCTheme.success)
                        .accessibilityHidden(true)
                }
                Text(verbatim: text)
                    .font(.caption.weight(isCompleted ? .medium : .semibold))
                    .foregroundStyle(isCompleted ? DCTheme.inkMuted : DCTheme.goldInk)
                    .monospacedDigit()
                    .lineLimit(singleLineLimit)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 40)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("agentStatusLine")
        }
    }
}

/// One row of the Agent conversation: a run (by index and id), or a voice turn.
enum ConversationItem: Identifiable, Equatable {
    case run(index: Int, id: UUID, startedAt: Date)
    case voice(BrowserAgentMessage)

    var id: UUID {
        switch self {
        case .run(_, let id, _): id
        case .voice(let message): message.id
        }
    }

    var date: Date {
        switch self {
        case .run(_, _, let startedAt): startedAt
        case .voice(let message): message.createdAt
        }
    }
}

@MainActor
private final class TimelineCache {
    struct Stamp: Equatable { let id: UUID; let startedAt: Date }
    struct Split {
        let lazyItems: [ConversationItem]
        let eagerItems: [ConversationItem]
        let lazyRuns: [BrowserAgentRun]
    }
    private var stamps: [Stamp]?
    private var voices: [BrowserAgentMessage]?
    private var lastSplitEager: Bool?
    private var items: [ConversationItem] = []
    private var lazyItems: [ConversationItem] = []
    private var eagerItems: [ConversationItem] = []
    private var lazyRuns: [BrowserAgentRun] = []

    func split(runs: [BrowserAgentRun], messages: [BrowserAgentMessage], isRunning: Bool) -> Split {
        let nextStamps = runs.map { Stamp(id: $0.id, startedAt: $0.startedAt) }
        let nextVoices = messages.filter(\.role.isVoice)
        if nextStamps != stamps || nextVoices != voices {
            stamps = nextStamps
            voices = nextVoices
            lastSplitEager = nil
            items = PerfProbe.time("BrowserAgentRunsView.timeline") {
                let raw = nextStamps.enumerated().map { ConversationItem.run(index: $0.offset, id: $0.element.id, startedAt: $0.element.startedAt) }
                    + nextVoices.map(ConversationItem.voice)
                return raw.enumerated().sorted { lhs, rhs in
                    lhs.element.date == rhs.element.date ? lhs.offset < rhs.offset : lhs.element.date < rhs.element.date
                }.map(\.element)
            }
        }
        let splitEager = isRunning && runs.last?.state.isRunning == true
        if splitEager != lastSplitEager {
            lastSplitEager = splitEager
            if splitEager, let latestID = runs.last?.id, let pivot = items.lastIndex(where: { $0.id == latestID }) {
                lazyItems = Array(items[..<pivot])
                eagerItems = Array(items[pivot...])
            } else {
                lazyItems = items
                eagerItems = []
            }
        }
        let lazyRunCount = splitEager ? max(0, runs.count - 1) : runs.count
        if lazyRuns.count != lazyRunCount {
            lazyRuns = Array(runs.prefix(lazyRunCount))
        } else if splitEager, lazyRunCount > 0 {
            if lazyRuns[lazyRunCount - 1].id != runs[lazyRunCount - 1].id
                || lazyRuns[lazyRunCount - 1].state != runs[lazyRunCount - 1].state {
                lazyRuns = Array(runs.prefix(lazyRunCount))
            }
        } else if lazyRunCount > 0, runs.prefix(lazyRunCount) != lazyRuns[...] {
            lazyRuns = Array(runs.prefix(lazyRunCount))
        }
        return Split(lazyItems: lazyItems, eagerItems: eagerItems, lazyRuns: lazyRuns)
    }
}

@MainActor
final class ForumSourcesCache {
    struct Key: Equatable { let reply: String; let shapeRowIDs: [UUID]; let siteURL: String }
    struct Value: Equatable { let annotatedReply: String; let sources: [AgentSources.Source]; let siteURL: String }
    private var entries: [UUID: (key: Key, value: Value?)] = [:]

    func resolve(for run: BrowserAgentRun, reply: String, siteURL: String, app: AppModel) -> Value? {
        let shapeRows = run.toolCalls.filter { $0.shape != nil && !$0.isRunning }
        guard !shapeRows.isEmpty else { entries.removeValue(forKey: run.id); return nil }
        let key = Key(reply: reply, shapeRowIDs: shapeRows.map(\.id), siteURL: siteURL)
        if let cached = entries[run.id], cached.key == key { return cached.value }
        let value: Value? = PerfProbe.time("BrowserAgentRunsView.forumSources") {
            let shapes = shapeRows.compactMap(\.shape)
            let parse = app.linkParser(siteURL: siteURL, shapes: shapes)
            let sources = AgentSources.extract(from: reply, visits: AgentSources.visits(of: shapes), parse: parse)
            return Value(annotatedReply: AgentSources.annotate(reply, sources: sources, parse: parse), sources: sources, siteURL: siteURL)
        }
        entries[run.id] = (key, value)
        return value
    }
}

struct ParsedSummary: Equatable {
    var input: DrawerSummarySections.Input?
    var sections = 0
    var hasCitations = false
    var rows: [MarkdownRow] = []
    static let empty = ParsedSummary()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.input == rhs.input && lhs.sections == rhs.sections && lhs.hasCitations == rhs.hasCitations
    }
}

@MainActor
final class ParsedSummaryCache {
    private var lastInput: DrawerSummarySections.Input?
    private var lastOutput = ParsedSummary.empty

    func parsed(for input: DrawerSummarySections.Input) -> ParsedSummary {
        if input != lastInput {
            lastInput = input
            let res = DrawerSummarySections.parsed(for: input)
            lastOutput = ParsedSummary(input: input, sections: res.sections, hasCitations: res.hasCitations, rows: res.rows)
        }
        return lastOutput
    }
}

struct TopicSummarySnapshot: Equatable {
    let topicKey: String; let summary: String; let hasSummary: Bool
    let totalPosts: Int?; let summaryPostCount: Int?; let url: URL?
}

struct AgentRunsContext: Equatable {
    var developerMode = false
    var isBrowserAgentReady = false
    var openTabIDs: Set<String> = []
    var currentTabID = ""
    var pageSiteURL: String?
    var forumsCount = 0
    var activeCitation: Int?
    var cardRowID: UUID?
    var currentTopicSummary: TopicSummarySnapshot?
    var scriptsModelDisplayName = ""

    init() {}

    @MainActor
    init(app: AppModel, tabs: BrowserTabs) {
        developerMode = app.settings.agentDeveloperMode
        isBrowserAgentReady = app.settings.readiness(for: .browserAgent, appleIntelligence: .unavailable(.deviceNotEligible)) == .ready
        openTabIDs = Set(tabs.tabs.lazy.map(\.id))
        currentTabID = tabs.currentTabID
        pageSiteURL = app.pageContext.siteURL
        forumsCount = app.forums.count
        activeCitation = app.citationJump?.number
        scriptsModelDisplayName = app.scriptsModelDisplayName
        if let topicKey = app.currentTopic?.topicKey {
            let s = app.currentSession
            currentTopicSummary = TopicSummarySnapshot(
                topicKey: topicKey, summary: s?.summary ?? "", hasSummary: s?.hasSummary == true,
                totalPosts: s?.totalPosts, summaryPostCount: s?.summaryPostCount, url: s?.url ?? app.currentTopic?.url
            )
        }
    }
}

struct BrowserAgentRunsView: View {
    let app: AppModel
    let session: BrowserAgentSession
    var context: AgentRunsContext?
    @Binding var expandedToolRowIDs: Set<UUID>
    /// Opens a source of an answer in the browser.
    var onOpenURL: ((URL) -> Void)?
    @State private var manuallyExpandedRunIDs: Set<UUID> = []
    @State private var screenshotSheet: ScreenshotSheetItem?
    @State private var timelineCache = TimelineCache()
    @State private var sourcesCache = ForumSourcesCache()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        app: AppModel,
        session: BrowserAgentSession,
        context: AgentRunsContext? = nil,
        expandedToolRowIDs: Binding<Set<UUID>>,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.app = app
        self.session = session
        self.context = context
        _expandedToolRowIDs = expandedToolRowIDs
        self.onOpenURL = onOpenURL
    }

    var body: some View {
        let _ = PerfProbe.hit("BrowserAgentRunsView.body")
        if let context {
            runsBody(context: context)
        } else {
            StandaloneRunsObserver(app: app, tabs: app.tabs) { runsBody(context: $0) }
        }
    }

    static func scrollID(for id: UUID) -> String { "agentItem-\(id.uuidString)" }

    private func runsBody(context: AgentRunsContext) -> some View {
        let runs = session.runs
        let latestRunID = runs.last?.id
        let split = timelineCache.split(runs: runs, messages: session.messages, isRunning: session.isRunning)
        let hasEager = !split.eagerItems.isEmpty
        let latestToolRowIDs: Set<UUID> = (!hasEager || expandedToolRowIDs.isEmpty) ? [] : Set((runs.last?.toolCalls ?? []).map(\.id))
        let earlierModel = EarlierConversationItemsView.Model(
            items: split.lazyItems, runs: split.lazyRuns,
            latestRunID: hasEager ? nil : latestRunID,
            context: context,
            manuallyExpandedRunIDs: (!hasEager || manuallyExpandedRunIDs.isEmpty) ? manuallyExpandedRunIDs : manuallyExpandedRunIDs.subtracting(latestRunID.map { [$0] } ?? []),
            expandedToolRowIDs: (!hasEager || expandedToolRowIDs.isEmpty) ? expandedToolRowIDs : expandedToolRowIDs.subtracting(latestToolRowIDs)
        )
        return VStack(alignment: .leading, spacing: 12) {
            if !split.lazyItems.isEmpty {
                EarlierConversationItemsView(
                    model: earlierModel, app: app, session: session, sourcesCache: sourcesCache,
                    onToggleSteps: { toggleSet(&manuallyExpandedRunIDs, id: $0) },
                    onToggleToolRow: { toggleSet(&expandedToolRowIDs, id: $0) },
                    onShowScreenshot: { screenshotSheet = $0 }, onOpenURL: onOpenURL
                )
                .equatable()
                .accessibilityElement(children: .contain)
                .accessibilitySortPriority(2)
                .transition(.identity)
            }
            if !split.eagerItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(split.eagerItems.enumerated()), id: \.element.id) { offset, item in
                        Self.itemView(
                            item: item, runs: runs, latestRunID: latestRunID, context: context,
                            manuallyExpandedRunIDs: manuallyExpandedRunIDs, expandedToolRowIDs: expandedToolRowIDs,
                            app: app, session: session, sourcesCache: sourcesCache,
                            onToggleSteps: { toggleSet(&manuallyExpandedRunIDs, id: $0) },
                            onToggleToolRow: { toggleSet(&expandedToolRowIDs, id: $0) },
                            onShowScreenshot: { screenshotSheet = $0 }, onOpenURL: onOpenURL
                        )
                        .id(Self.scrollID(for: item.id))
                        .accessibilitySortPriority(Double(1_000 - offset))
                        .transition(.identity)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilitySortPriority(1)
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(item: $screenshotSheet) { item in
            DCScreenshotSheet(item: item)
        }
    }

    @MainActor
    @ViewBuilder
    fileprivate static func itemView(
        item: ConversationItem, runs: [BrowserAgentRun], latestRunID: UUID?, context: AgentRunsContext,
        manuallyExpandedRunIDs: Set<UUID>, expandedToolRowIDs: Set<UUID>,
        app: AppModel, session: BrowserAgentSession, sourcesCache: ForumSourcesCache,
        onToggleSteps: @escaping (UUID) -> Void, onToggleToolRow: @escaping (UUID) -> Void,
        onShowScreenshot: @escaping (ScreenshotSheetItem) -> Void, onOpenURL: ((URL) -> Void)?
    ) -> some View {
        switch item {
        case .run(let index, let runID, _):
            if index < runs.count, runs[index].id == runID {
                let run = runs[index]
                let showableTabs = Set(run.toolCalls.lazy.compactMap { row -> String? in
                    guard !row.isRunning, !row.isError, let id = row.openedTabID,
                          context.openTabIDs.contains(id), context.currentTabID != id else { return nil }
                    return id
                })
                let showsFailure: Bool = if case .failed = run.state { context.isBrowserAgentReady } else { false }
                let siteURL: String = {
                    guard !run.assistantText.isEmpty else { return "" }
                    let sample = run.toolCalls.lazy.compactMap { row -> URL? in
                        guard !row.isRunning, let shape = row.shape else { return nil }
                        switch shape {
                        case .thread(let t): return URL(string: t.url)
                        case .list(let l): return l.items.first.flatMap { URL(string: $0.url) }
                        }
                    }.first
                    return sample.flatMap { app.siteURL(containing: $0) } ?? ""
                }()
                let hasSummaryCard = run.toolCalls.contains { $0.toolName == "summarize_topic" && !$0.isRunning && !$0.isError }
                let ownsSummaryCard = hasSummaryCard && context.currentTopicSummary.map { snap in
                    run.toolCalls.contains { row in
                        guard row.toolName == "summarize_topic", !row.isRunning, !row.isError, case .thread(let t) = row.shape else { return false }
                        return app.session(forThreadShape: t)?.topicKey == snap.topicKey
                    }
                } == true
                let hasScriptCards = !BrowserAgentRunsView.savedScriptEntries(in: run).isEmpty
                AgentRunSectionView(
                    model: .init(
                        run: run, isLatest: run.id == latestRunID, developerMode: context.developerMode,
                        showsFailureCard: showsFailure, stepsExpanded: manuallyExpandedRunIDs.contains(run.id),
                        expandedRowIDs: expandedToolRowIDs.isEmpty ? [] : Set(run.toolCalls.lazy.map(\.id).filter { expandedToolRowIDs.contains($0) }),
                        showableTabIDs: showableTabs, forumSiteURL: siteURL,
                        activeCitation: hasSummaryCard ? context.activeCitation : nil,
                        cardRowID: ownsSummaryCard ? context.cardRowID : nil,
                        currentTopicSummary: hasSummaryCard ? context.currentTopicSummary : nil,
                        scriptsModelDisplayName: hasScriptCards ? context.scriptsModelDisplayName : ""
                    ),
                    app: app, session: session, sourcesCache: sourcesCache,
                    onToggleSteps: { onToggleSteps(run.id) },
                    onToggleToolRow: onToggleToolRow,
                    onShowScreenshot: onShowScreenshot,
                    onOpenURL: onOpenURL
                )
                .equatable()
            }
        case .voice(let message):
            DCVoiceBubble(text: message.text, isUser: message.role == .voiceUser)
        }
    }

    private func toggleSet(_ set: inout Set<UUID>, id: UUID) {
        withAnimation(DCMotion.respecting(reduceMotion, DCMotion.quick)) {
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
        }
    }
}

private struct EarlierConversationItemsView: View, Equatable {
    struct Model: Equatable {
        let items: [ConversationItem]
        let runs: [BrowserAgentRun]
        let latestRunID: UUID?
        let context: AgentRunsContext
        let manuallyExpandedRunIDs: Set<UUID>
        let expandedToolRowIDs: Set<UUID>
    }
    let model: Model
    let app: AppModel
    let session: BrowserAgentSession
    let sourcesCache: ForumSourcesCache
    let onToggleSteps: (UUID) -> Void
    let onToggleToolRow: (UUID) -> Void
    let onShowScreenshot: (ScreenshotSheetItem) -> Void
    let onOpenURL: ((URL) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && ObjectIdentifier(lhs.app) == ObjectIdentifier(rhs.app) && ObjectIdentifier(lhs.session) == ObjectIdentifier(rhs.session)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { offset, item in
                BrowserAgentRunsView.itemView(
                    item: item, runs: model.runs, latestRunID: model.latestRunID, context: model.context,
                    manuallyExpandedRunIDs: model.manuallyExpandedRunIDs, expandedToolRowIDs: model.expandedToolRowIDs,
                    app: app, session: session, sourcesCache: sourcesCache,
                    onToggleSteps: onToggleSteps, onToggleToolRow: onToggleToolRow,
                    onShowScreenshot: onShowScreenshot, onOpenURL: onOpenURL
                )
                .id(BrowserAgentRunsView.scrollID(for: item.id))
                .accessibilitySortPriority(Double(100_000 - offset))
                .transition(.identity)
            }
        }
    }
}

private struct StandaloneRunsObserver<Content: View>: View {
    @ObservedObject var app: AppModel
    @ObservedObject var tabs: BrowserTabs
    let content: (AgentRunsContext) -> Content
    var body: some View { content(AgentRunsContext(app: app, tabs: tabs)) }
}

private struct LatestRunConfirmationsView: View {
    let gate: AgentConfirmationGate
    var body: some View {
        ForEach(gate.pending) { item in
            AgentConfirmationCard(confirmation: item, gate: gate)
                .dcRiseIn()
        }
    }
}

private struct AgentRunSectionView: View, Equatable {
    struct Model: Equatable {
        let run: BrowserAgentRun
        let isLatest: Bool
        let developerMode: Bool
        let showsFailureCard: Bool
        let stepsExpanded: Bool
        let expandedRowIDs: Set<UUID>
        let showableTabIDs: Set<String>
        let forumSiteURL: String
        let activeCitation: Int?
        let cardRowID: UUID?
        let currentTopicSummary: TopicSummarySnapshot?
        let scriptsModelDisplayName: String
    }

    let model: Model
    let app: AppModel
    let session: BrowserAgentSession
    let sourcesCache: ForumSourcesCache
    let onToggleSteps: () -> Void
    let onToggleToolRow: (UUID) -> Void
    let onShowScreenshot: (ScreenshotSheetItem) -> Void
    let onOpenURL: ((URL) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && ObjectIdentifier(lhs.app) == ObjectIdentifier(rhs.app) && ObjectIdentifier(lhs.session) == ObjectIdentifier(rhs.session)
    }

    private var run: BrowserAgentRun { model.run }

    var body: some View {
        let _ = PerfProbe.hit("BrowserAgentRunsView.runSection")
        VStack(alignment: .leading, spacing: 10) {
            // A hand-off's request already shows as the voice bubble before it.
            if run.origin != .voice {
                userBubble(run.prompt)
            }

            if !run.toolCalls.isEmpty {
                toolCallsSection(for: run)
            }

            if model.isLatest {
                LatestRunConfirmationsView(gate: app.agentConfirmations)
            }

            let savedEntries = BrowserAgentRunsView.savedScriptEntries(in: run)
            if !savedEntries.isEmpty {
                ForEach(savedEntries) { entry in
                    AgentScriptCardView(app: app, entry: entry, scriptsModelDisplayName: model.scriptsModelDisplayName)
                        .dcRiseIn()
                }
                DCSavedNote(animateDone: model.isLatest && !session.doneShownRunIDs.contains(run.id)) {
                    session.markSavedNoteDoneShown(for: run.id)
                }
            }

            let reply = run.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty {
                let forum = sourcesCache.resolve(for: run, reply: reply, siteURL: model.forumSiteURL, app: app)
                MarkdownView(forum?.annotatedReply ?? reply)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("agentAssistantReply")
                if let forum, !forum.sources.isEmpty {
                    DCSourcesList(sources: forum.sources) { source in
                        // The sources become the current list (result cards, Next).
                        app.followSources(forum.sources, selecting: source, siteURL: forum.siteURL)
                        onOpenURL?(source.url)
                    }
                    .accessibilityIdentifier("agentSources")
                }
                if !run.state.isRunning || (model.developerMode && run.finalTurn != nil) {
                    HStack(spacing: 8) {
                        if model.developerMode, let info = run.finalTurn {
                            DevDetailsButton(app: app, session: session, taskID: run.id.uuidString, info: info)
                        }
                        Spacer(minLength: 0)
                        if !run.state.isRunning {
                            answerMenu(run: run, reply: reply)
                        }
                    }
                }
            }

            switch run.state {
            case .stopped:
                Text("Stopped", comment: "Agent turn notice when a run was stopped before finishing")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DCTheme.inkMuted)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("agentRunStoppedNotice")
            case .stepLimitReached(let limit):
                stepLimitCard(limit: limit)
            case .failed(let message) where model.showsFailureCard:
                errorCard(message: message)
            default:
                EmptyView()
            }
        }
    }

    fileprivate static func savedScriptEntries(in run: BrowserAgentRun) -> [SavedScriptCardEntry] {
        var indexByScriptID: [String: Int] = [:]
        var entries: [SavedScriptCardEntry] = []
        for row in run.toolCalls where !row.isRunning && !row.isError {
            let isSave = row.toolName == "script_save"
            let isUpdate = row.toolName == "script_update"
            guard isSave || isUpdate,
                  let obj = try? JSONValue.parseObjectJSON(row.resultText),
                  let scriptID = obj["script_id"]?.stringValue,
                  !scriptID.isEmpty else {
                continue
            }
            if isUpdate && obj["repaired"]?.strictBoolValue != true {
                continue
            }
            let argsObj = try? JSONValue.parseObjectJSON(row.argumentsJSON)
            let fallbackName = obj["name"]?.stringValue
                ?? argsObj?["name"]?.stringValue
                ?? scriptID
            let fallbackRule = obj["match_rules"]?.arrayValue?.first?.stringValue
                ?? argsObj?["match_rules"]?.arrayValue?.first?.stringValue
                ?? ""
            let repairTarget: ScriptRepairTarget? = isUpdate
                ? (run.repairTarget?.scriptID == scriptID ? run.repairTarget : ScriptRepairTarget(scriptID: scriptID, payload: obj))
                : nil
            let entry = SavedScriptCardEntry(
                scriptID: scriptID,
                fallbackName: fallbackName,
                fallbackFirstRule: fallbackRule,
                repairTarget: repairTarget
            )
            if let idx = indexByScriptID[scriptID] {
                entries[idx] = entry
            } else {
                indexByScriptID[scriptID] = entries.count
                entries.append(entry)
            }
        }
        return entries
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 44)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(DCTheme.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(DCTheme.surfaceRaised, in: DCUserBubbleShape())
                .accessibilityIdentifier("agentUserMessage")
        }
    }

    @ViewBuilder
    private func answerMenu(run: BrowserAgentRun, reply: String) -> some View {
        Menu {
            Button {
                UIPasteboard.general.string = reply
                DCHaptics.success()
            } label: {
                Label(String(localized: "Copy", comment: "Button to copy an AI answer"), systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("copyAgentAnswer")

            ShareLink(item: reply) {
                Label(String(localized: "Share", comment: "Button to share an AI answer"), systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("shareAgentAnswer")

            Divider()

            Button {
                if let target = app.agentAnswerReportTarget(for: run, reply: reply) {
                    app.reportAIOutput(target)
                }
            } label: {
                Label(String(localized: "Report this answer", comment: "Answer menu action to report objectionable or inaccurate AI output"), systemImage: "flag")
            }
            .accessibilityIdentifier("reportAgentAnswer")
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Answer actions", comment: "Accessibility label for an AI answer's menu"))
        .accessibilityIdentifier("agentAnswerMenu")
    }

    @ViewBuilder
    private func toolCallsSection(for run: BrowserAgentRun) -> some View {
        if run.state.isRunning || run.toolCalls.count == 1 {
            VStack(alignment: .leading, spacing: 8) {
                toolRowList(run.toolCalls, inlineCapabilityCards: true)
            }
        } else {
            let stepsExpanded = model.stepsExpanded
            VStack(alignment: .leading, spacing: 10) {
                DCStepsFold(
                    count: run.toolCalls.count,
                    errorCount: run.errorCount,
                    isExpanded: stepsExpanded,
                    onToggle: {
                        DCHaptics.tap()
                        onToggleSteps()
                    }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        toolRowList(run.toolCalls, inlineCapabilityCards: true)
                    }
                }
                if !stepsExpanded {
                    let openedRows = run.toolCalls.filter { !$0.isRunning && !$0.isError && $0.openedTabID != nil }
                    if !openedRows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            toolRowList(openedRows, inlineCapabilityCards: false)
                        }
                    }
                    ForEach(BrowserAgentRunsView.capabilityEntries(in: run.toolCalls)) { entry in
                        capabilityCard(for: entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolRowList(_ rows: [BrowserAgentToolCallRow], inlineCapabilityCards: Bool) -> some View {
        let developerMode = model.developerMode
        ForEach(rows) { row in
            let expanded = model.expandedRowIDs.contains(row.id)
            let showableTabID: String? = row.openedTabID.flatMap { model.showableTabIDs.contains($0) ? $0 : nil }
            VStack(alignment: .leading, spacing: inlineCapabilityCards ? 8 : 0) {
                DCToolRow(
                    label: DCToolLabel.browser(
                        row.toolName,
                        argumentsJSON: row.argumentsJSON,
                        openedTabID: row.openedTabID,
                        running: row.isRunning
                    ),
                    codeName: developerMode ? row.toolName : nil,
                    duration: developerMode ? row.duration.map(BrowserAgentPanelView.formatDuration) : nil,
                    summary: row.isRunning ? "" : row.resultSummary,
                    state: row.isRunning ? .running : (row.isError ? .error : (row.isPageWarning ? .warning : .done)),
                    doneSymbol: row.openedTabID != nil ? "square.on.square" : "checkmark",
                    isExpanded: expanded,
                    onToggle: {
                        DCHaptics.tap()
                        onToggleToolRow(row.id)
                    },
                    actionTitle: showableTabID != nil
                        ? String(localized: "Show", comment: "Button on an opened-tab tool row that switches to that tab")
                        : nil,
                    actionHint: showableTabID != nil
                        ? String(localized: "Switches to the opened tab", comment: "VoiceOver hint for the Show button on an opened-tab tool row")
                        : nil,
                    actionIdentifier: "agentToolShowTab",
                    onAction: showableTabID.map { tabID in
                        {
                            DCHaptics.tap()
                            if app.router.drawerPhase == .shown, app.router.drawerDetent == .large {
                                withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) {
                                    app.router.drawerDetent = .medium
                                }
                            }
                            _ = app.tabs.switchToTab(id: tabID)
                        }
                    }
                ) {
                    toolRowDetail(row, developerMode: developerMode)
                }
                if inlineCapabilityCards, let entry = BrowserAgentRunsView.capabilityEntry(for: row) {
                    capabilityCard(for: entry)
                }
            }
        }
    }

    private func toolRowDetail(_ row: BrowserAgentToolCallRow, developerMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if developerMode {
                codeBlock(row.argumentsJSON, id: "agentToolArguments")
                if let info = row.modelTurn {
                    DevModelStepView(app: app, session: session, taskID: row.runID.uuidString, info: info)
                }
                if let report = row.pageFeedback {
                    DevSnapshotsView(report: report)
                }
            }
            codeBlock(row.displayText.isEmpty ? row.resultSummary : row.displayText, id: "agentToolResult", warning: row.isPageWarning,
                      images: row.carriesImages ? row : nil)
            HStack {
                if row.wasTruncated {
                    Text("Truncated · \(row.totalCharacterCount) characters in total", comment: "Footer under a truncated browser agent tool output showing the original character count")
                        .font(.caption)
                        .foregroundStyle(DCTheme.inkMuted)
                        .accessibilityIdentifier("agentToolTruncatedNote")
                }
                Spacer(minLength: 0)
                if !row.isRunning {
                    Button {
                        DCHaptics.tap()
                        app.auditLogRequest = AuditLogRequest(taskID: row.runID.uuidString, step: row.stepNumber)
                    } label: {
                        Text("View in audit log", comment: "Quiet button under an expanded tool row that opens this step in the audit log")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DCTheme.inkMuted)
                    .padding(.trailing, 8)
                    .accessibilityIdentifier("agentToolViewInAuditLog")
                }
                if !row.displayText.isEmpty {
                    Button {
                        UIPasteboard.general.string = row.displayText
                        DCHaptics.success()
                    } label: {
                        Label(String(localized: "Copy", comment: "Button to copy tool call result text"), systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DCTheme.goldInk)
                    .accessibilityIdentifier("agentToolCopyResult")
                }
            }
        }
    }

    private func codeBlock(_ text: String, id: String, warning: Bool = false, images: BrowserAgentToolCallRow? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: text)
                .font(.caption.monospaced())
                .foregroundStyle(warning ? DCTheme.warning : DCTheme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(id)
            if let images {
                DCScreenshotStrip(row: images, onOpen: onShowScreenshot)
            }
        }
        .padding(10)
        .background(DCTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
    }

    private func stepLimitCard(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(DCTheme.warning)
                    .accessibilityHidden(true)
                Text("Stopped at the step limit (\(limit))", comment: "Browser agent warning card title when the step limit is reached")
                    .font(.subheadline.weight(.semibold))
            }
            Text("The page may be half changed. Continue to grant another \(limit) steps, or adjust the step limit in Settings.", comment: "Browser agent warning card body when the step limit is reached")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    DCHaptics.tap()
                    session.continueAfterStepLimit()
                } label: {
                    Text("Continue", comment: "Browser agent button: continue running after hitting the step limit")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DCActionButtonStyle(prominent: true))
                .accessibilityIdentifier("agentContinueButton")

                Button {
                    DCHaptics.tap()
                    app.requestedSettingsPage = .agent
                } label: {
                    Text("Step limit…", comment: "Browser agent button: open step limit settings")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DCActionButtonStyle(prominent: false))
                .accessibilityIdentifier("agentStepLimitSettingsButton")
            }
        }
        .dcCard(tint: DCTheme.warning)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentStepLimitCard")
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DCTheme.danger)
                    .accessibilityHidden(true)
                Text("Could not complete turn", comment: "Browser agent error card title")
                    .font(.subheadline.weight(.semibold))
            }
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agentErrorMessage")
            HStack(spacing: 10) {
                Button {
                    DCHaptics.tap()
                    session.retryLastTurn()
                } label: {
                    Text("Try again", comment: "Browser agent button: retry the failed turn")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DCActionButtonStyle(prominent: true))
                .accessibilityIdentifier("agentRetryButton")

                Button {
                    DCHaptics.tap()
                    app.requestedSettingsPage = .provider
                } label: {
                    Text("Check key", comment: "Browser agent button: open AI models settings to check the API key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DCActionButtonStyle(prominent: false))
                .accessibilityIdentifier("agentCheckKeyButton")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DCTheme.cinnabarWash, in: RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous))
        .dcRiseIn()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentErrorCard")
    }

    @ViewBuilder
    private func capabilityCard(for entry: BrowserAgentRunsView.CapabilityResultEntry) -> some View {
        let isLazy = !run.state.isRunning
        switch entry {
        case .threadSummary(let id, let thread, let fallbackText):
            CapabilityThreadSummaryCard(app: app, currentTopicSummary: model.currentTopicSummary, rowID: id, thread: thread, fallbackText: fallbackText, isLazy: isLazy)
        case .textSummary(_, let title, let markdown):
            DCResultCard(label: String(localized: "Summary", comment: "Summary result card header"), systemImage: "doc.text", isLazy: isLazy) {
                if !title.isEmpty { Text(verbatim: title).font(.caption).lineLimit(1) }
            } content: {
                MarkdownView(markdown).textSelection(.enabled)
            }
            .accessibilityIdentifier("capabilityTextSummaryCard")
        case .listen(_, let thread, let explicitID, let title, let fallbackDetail, let rawText, let workspacePath):
            CapabilityListenCard(app: app, currentTopicSummary: model.currentTopicSummary, podcast: app.podcast, player: app.podcast.player,
                                 thread: thread, explicitID: explicitID, title: title, fallbackDetail: fallbackDetail, rawText: rawText, workspacePath: workspacePath)
        }
    }
}

extension BrowserAgentRunsView {
    static func savedScriptEntries(in run: BrowserAgentRun) -> [SavedScriptCardEntry] {
        AgentRunSectionView.savedScriptEntries(in: run)
    }

    // MARK: Capability Cards

    enum CapabilityResultEntry: Identifiable, Equatable {
        case threadSummary(id: UUID, thread: ThreadShape, fallbackText: String)
        case textSummary(id: UUID, title: String, markdown: String)
        case listen(id: UUID, thread: ThreadShape?, explicitID: String?, title: String, fallbackDetail: String, rawText: String?, workspacePath: String?)

        var id: UUID {
            switch self {
            case .threadSummary(let id, _, _), .textSummary(let id, _, _), .listen(let id, _, _, _, _, _, _): id
            }
        }
    }

    /// The newest finished `summarize_topic` card for `topicKey`: the one place
    /// the drawer shows that thread's summary while the conversation has it (WUKO-134).
    static func latestThreadSummaryRowID(in runs: [BrowserAgentRun], topicKey: String, app: AppModel) -> UUID? {
        guard !topicKey.isEmpty else { return nil }
        for run in runs.reversed() {
            for row in run.toolCalls.reversed() where row.toolName == "summarize_topic" && !row.isRunning && !row.isError {
                if case .thread(let thread) = row.shape, app.session(forThreadShape: thread)?.topicKey == topicKey {
                    return row.id
                }
            }
        }
        return nil
    }

    /// A `summarize_topic` call still running: its card is on the way.
    static func hasRunningThreadSummary(in runs: [BrowserAgentRun]) -> Bool {
        runs.contains { $0.toolCalls.contains { $0.toolName == "summarize_topic" && $0.isRunning } }
    }

    static func capabilityEntries(in rows: [BrowserAgentToolCallRow]) -> [CapabilityResultEntry] {
        rows.compactMap(capabilityEntry(for:))
    }

    static func capabilityEntry(for row: BrowserAgentToolCallRow) -> CapabilityResultEntry? {
        guard !row.isRunning, !row.isError else { return nil }
        switch row.toolName {
        case "summarize_topic":
            if case .thread(let thread) = row.shape {
                return .threadSummary(id: row.id, thread: thread, fallbackText: stripThreadSummaryHeader(row.resultText))
            }
            let markdown = row.resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            return markdown.isEmpty ? nil : .textSummary(id: row.id, title: row.resultSummary, markdown: markdown)
        case "read_aloud":
            let detail = stripReadAloudPrefix(row.resultText, title: row.resultSummary)
            if case .thread(let thread) = row.shape {
                let title = row.resultSummary.isEmpty ? thread.title : row.resultSummary
                return .listen(id: row.id, thread: thread, explicitID: nil, title: title, fallbackDetail: detail, rawText: nil, workspacePath: nil)
            }
            let args = try? JSONValue.parseObjectJSON(row.argumentsJSON)
            let rawText = args?["text"]?.stringValue
            let path = args?["path"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let explicitID = if let path {
                CapabilityReadAloud.pathID(path)
            } else if let rawText {
                CapabilityReadAloud.textID(PostCitations.stripped(rawText).trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                Optional<String>.none
            }
            return .listen(id: row.id, thread: nil, explicitID: explicitID, title: row.resultSummary, fallbackDetail: detail, rawText: rawText, workspacePath: path)
        default:
            return nil
        }
    }

    private static func stripThreadSummaryHeader(_ text: String) -> String {
        guard text.hasPrefix("Summary of "), let range = text.range(of: ":\n\n") else { return text }
        return String(text[range.upperBound...])
    }

    private static func stripReadAloudPrefix(_ text: String, title: String) -> String {
        let prefix = "Reading aloud: \(title), "
        guard text.hasPrefix(prefix) else { return text }
        let suffix = String(text.dropFirst(prefix.count))
        return suffix.prefix(1).uppercased() + suffix.dropFirst()
    }

}

/// Actions under the open thread's newest summary card (Retry, Check for new
/// replies, progress), given by the drawer that owns them (WUKO-134).
struct ThreadSummaryCardFooter {
    let rowID: UUID
    let content: AnyView
}

extension EnvironmentValues {
    @Entry var threadSummaryCardFooter: ThreadSummaryCardFooter?
}

private struct CapabilityThreadSummaryCard: View {
    let app: AppModel
    let currentTopicSummary: TopicSummarySnapshot?
    let rowID: UUID
    let thread: ThreadShape
    let fallbackText: String
    let isLazy: Bool
    @State private var parsedCache = ParsedSummaryCache()
    @Environment(\.threadSummaryCardFooter) private var footer

    var body: some View {
        let session = app.session(forThreadShape: thread)
        let isCurrent = session != nil && session?.topicKey == currentTopicSummary?.topicKey
        let summaryText = (isCurrent ? (currentTopicSummary?.hasSummary == true ? currentTopicSummary?.summary : nil)
                           : (session?.hasSummary == true ? session?.summary : nil)) ?? fallbackText
        let maxPost = (isCurrent ? currentTopicSummary?.totalPosts : session?.totalPosts) ?? thread.totalPosts
        let count = (isCurrent ? currentTopicSummary?.summaryPostCount : session?.summaryPostCount) ?? maxPost
        let parsed = parsedCache.parsed(for: .init(text: summaryText, maximumPost: maxPost))
        let showsFooter = footer?.rowID == rowID && isCurrent
        CapabilityThreadSummaryCardBody(
            model: .init(parsed: parsed, count: count, isCurrentTopic: isCurrent,
                         targetURL: (isCurrent ? currentTopicSummary?.url : session?.url) ?? URL(string: thread.url),
                         footerRowID: showsFooter ? rowID : nil, isLazy: isLazy),
            app: app, footer: showsFooter ? footer?.content : nil
        )
        .equatable()
    }
}

private struct CapabilityThreadSummaryCardBody: View, Equatable {
    struct Model: Equatable {
        let parsed: ParsedSummary
        let count: Int?
        let isCurrentTopic: Bool
        let targetURL: URL?
        let footerRowID: UUID?
        let isLazy: Bool
    }

    let model: Model
    let app: AppModel
    let footer: AnyView?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && ObjectIdentifier(lhs.app) == ObjectIdentifier(rhs.app)
    }

    var body: some View {
        if !model.parsed.rows.isEmpty {
            DCResultCard(label: String(localized: "Summary", comment: "Summary result card header"), systemImage: "doc.text", isLazy: model.isLazy) {
                if let count = model.count, count > 0 { Text(String(localized: "\(count) posts")).font(.caption) }
            } content: {
                DrawerSummarySections(rows: model.parsed.rows, layout: .singleColumn)
            }
            .environment(\.openURL, OpenURLAction { url in
                if let number = PostCitations.postNumber(from: url) {
                    if model.isCurrentTopic {
                        app.jumpToCitation(number)
                    } else if let target = model.targetURL {
                        app.browser.load(target)
                    }
                    return .handled
                }
                guard ForumBrowserModel.isBrowsableURL(url) else { return .systemAction }
                app.browser.load(url)
                return .handled
            })
            .accessibilityIdentifier("capabilityThreadSummaryCard")
            if let footer {
                footer
            }
        }
    }
}

private struct CapabilityListenCard: View {
    let app: AppModel
    let currentTopicSummary: TopicSummarySnapshot?
    @ObservedObject var podcast: PodcastController
    @ObservedObject var player: PodcastPlayer
    let thread: ThreadShape?
    let explicitID: String?
    let title: String
    let fallbackDetail: String
    let rawText: String?
    let workspacePath: String?

    var body: some View {
        let session = thread.flatMap { app.session(forThreadShape: $0) }
        let isCurrent = session != nil && session?.topicKey == currentTopicSummary?.topicKey
        let readID = (isCurrent ? currentTopicSummary?.topicKey : session?.topicKey) ?? explicitID ?? ""
        let matches = !readID.isEmpty && player.playlist?.id == PodcastController.readAloudPlaylistID(readID)
        let timeline = player.timeline
        let progress = matches && timeline.total > 0 ? timeline.elapsed(player.position) / timeline.total : 0
        let detail = matches && timeline.total > 0
            ? "\(DockText.clock(timeline.elapsed(player.position))) / \(DockText.clock(timeline.total))"
            : fallbackDetail
        let summarySource = isCurrent ? currentTopicSummary?.summary : session?.summary
        let speakText = summarySource.map { PostCitations.stripped($0) } ?? rawText.map { PostCitations.stripped($0) }
        Button {
            DCHaptics.tap()
            if matches { player.toggle() }
            else if !readID.isEmpty, let speakText, !speakText.isEmpty { podcast.readAloud(id: readID, title: title, text: speakText) }
            else if !readID.isEmpty, let workspacePath {
                Task { @MainActor in
                    guard let read = try? await app.agentWorkspace.read(path: workspacePath, offset: 0, length: Int.max) else { return }
                    let cleaned = PostCitations.stripped(read.text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { podcast.readAloud(id: readID, title: title, text: cleaned) }
                }
            }
        } label: {
            DCListenRow(title: title, detail: detail, progress: progress, isPlaying: matches && player.isActive)
        }
        .buttonStyle(.plain)
        .accessibilityValue(matches && player.isActive ? Text("Pause") : Text("Listen"))
        .accessibilityIdentifier("capabilityListenRow")
    }
}
