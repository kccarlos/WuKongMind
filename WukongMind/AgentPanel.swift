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
            toolCalls: session.toolCalls,
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

/// One row of the Agent conversation: a run, or a voice turn.
enum ConversationItem: Identifiable {
    case run(BrowserAgentRun)
    case voice(BrowserAgentMessage)

    var id: UUID {
        switch self {
        case .run(let run): run.id
        case .voice(let message): message.id
        }
    }

    var date: Date {
        switch self {
        case .run(let run): run.startedAt
        case .voice(let message): message.createdAt
        }
    }
}

struct BrowserAgentRunsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var tabs: BrowserTabs
    let session: BrowserAgentSession
    @Binding var expandedToolRowIDs: Set<UUID>
    /// Opens a source of an answer in the browser.
    var onOpenURL: ((URL) -> Void)?
    @State private var manuallyExpandedRunIDs: Set<UUID> = []
    @State private var screenshotSheet: ScreenshotSheetItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        app: AppModel,
        session: BrowserAgentSession,
        expandedToolRowIDs: Binding<Set<UUID>>,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.app = app
        _tabs = ObservedObject(wrappedValue: app.tabs)
        self.session = session
        _expandedToolRowIDs = expandedToolRowIDs
        self.onOpenURL = onOpenURL
    }

    private var isProviderReady: Bool { app.isProviderReady(for: .browserAgent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(timeline) { item in
                switch item {
                case .run(let run):
                    runSection(run, isLatest: run.id == session.runs.last?.id)
                case .voice(let message):
                    DCVoiceBubble(text: message.text, isUser: message.role == .voiceUser)
                }
            }
        }
        .sheet(item: $screenshotSheet) { item in
            DCScreenshotSheet(item: item)
        }
    }

    /// Runs and voice turns in the order they happened.
    private var timeline: [ConversationItem] {
        let items = session.runs.map(ConversationItem.run) + session.voiceTurns.map(ConversationItem.voice)
        return items.enumerated().sorted { lhs, rhs in
            lhs.element.date == rhs.element.date ? lhs.offset < rhs.offset : lhs.element.date < rhs.element.date
        }.map(\.element)
    }

    @ViewBuilder
    private func runSection(_ run: BrowserAgentRun, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // A hand-off's request already shows as the voice bubble before it.
            if run.origin != .voice {
                userBubble(run.prompt)
            }

            if !run.toolCalls.isEmpty {
                toolCallsSection(for: run)
            }

            if isLatest {
                ForEach(app.agentConfirmations.pending) { item in
                    AgentConfirmationCard(confirmation: item, gate: app.agentConfirmations)
                        .dcRiseIn()
                }
            }

            let savedEntries = Self.savedScriptEntries(in: run)
            if !savedEntries.isEmpty {
                ForEach(savedEntries) { entry in
                    AgentScriptCardView(app: app, entry: entry)
                        .dcRiseIn()
                }
                DCSavedNote()
            }

            let reply = run.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty {
                let forum = forumSources(for: run, reply: reply)
                MarkdownView(forum.map { AgentSources.annotate(reply, sources: $0.sources, parse: $0.parse) } ?? reply)
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
                if app.settings.agentDeveloperMode, let info = run.finalTurn {
                    DevDetailsButton(app: app, session: session, taskID: run.id.uuidString, info: info)
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
            case .failed(let message) where isProviderReady:
                errorCard(message: message)
            default:
                EmptyView()
            }
        }
    }

    /// The numbered sources of an answer whose run used forum tools; nil for a
    /// run without them, whose answer shows as written.
    private func forumSources(
        for run: BrowserAgentRun, reply: String
    ) -> (sources: [AgentSources.Source], siteURL: String, parse: AgentSources.Parse)? {
        let shapes = run.toolCalls.compactMap(\.shape)
        guard !shapes.isEmpty else { return nil }
        let sample = shapes.lazy.compactMap { shape -> URL? in
            switch shape {
            case .thread(let thread): URL(string: thread.url)
            case .list(let list): list.items.first.flatMap { URL(string: $0.url) }
            }
        }.first
        let siteURL = sample.flatMap { app.siteURL(containing: $0) } ?? ""
        let parse = app.linkParser(siteURL: siteURL, shapes: shapes)
        let sources = AgentSources.extract(from: reply, visits: AgentSources.visits(of: shapes), parse: parse)
        return (sources, siteURL, parse)
    }

    static func savedScriptEntries(in run: BrowserAgentRun) -> [SavedScriptCardEntry] {
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
                ? (run.repairTarget?.scriptID == scriptID ? run.repairTarget : nil)
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

    private func isRunStepsExpanded(_ run: BrowserAgentRun) -> Bool {
        manuallyExpandedRunIDs.contains(run.id)
    }

    private func toggleRunSteps(_ run: BrowserAgentRun) {
        withAnimation(DCMotion.respecting(reduceMotion, DCMotion.quick)) {
            if manuallyExpandedRunIDs.contains(run.id) {
                manuallyExpandedRunIDs.remove(run.id)
            } else {
                manuallyExpandedRunIDs.insert(run.id)
            }
        }
    }

    /// While the run goes, and for a run of one step, the rows show directly.
    /// Two or more steps fold into "Steps N" once the run ends.
    @ViewBuilder
    private func toolCallsSection(for run: BrowserAgentRun) -> some View {
        let isRunning: Bool = {
            if case .running = run.state { return true }
            return false
        }()
        if isRunning || run.toolCalls.count == 1 {
            VStack(alignment: .leading, spacing: 8) {
                toolRowList(run.toolCalls, inlineCapabilityCards: true)
            }
        } else {
            let stepsExpanded = isRunStepsExpanded(run)
            VStack(alignment: .leading, spacing: 10) {
                DCStepsFold(
                    count: run.toolCalls.count,
                    errorCount: run.errorCount,
                    isExpanded: stepsExpanded,
                    onToggle: {
                        DCHaptics.tap()
                        toggleRunSteps(run)
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
                    ForEach(Self.capabilityEntries(in: run.toolCalls)) { entry in
                        capabilityCard(for: entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolRowList(_ rows: [BrowserAgentToolCallRow], inlineCapabilityCards: Bool) -> some View {
        let developerMode = app.settings.agentDeveloperMode
        ForEach(rows) { row in
            let expanded = expandedToolRowIDs.contains(row.id)
            let showableTabID: String? = {
                guard !row.isRunning,
                      !row.isError,
                      let tabID = row.openedTabID,
                      tabs.tab(id: tabID) != nil,
                      tabs.currentTabID != tabID else {
                    return nil
                }
                return tabID
            }()
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
                        withAnimation(DCMotion.respecting(reduceMotion, DCMotion.quick)) {
                            if expanded { expandedToolRowIDs.remove(row.id) } else { expandedToolRowIDs.insert(row.id) }
                        }
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
                if inlineCapabilityCards, let entry = Self.capabilityEntry(for: row) {
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
                DCScreenshotStrip(row: images) { screenshotSheet = $0 }
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

    @ViewBuilder
    private func capabilityCard(for entry: CapabilityResultEntry) -> some View {
        switch entry {
        case .threadSummary(let id, let thread, let fallbackText):
            CapabilityThreadSummaryCard(app: app, rowID: id, thread: thread, fallbackText: fallbackText)
        case .textSummary(_, let title, let markdown):
            DCResultCard(label: String(localized: "Summary", comment: "Summary result card header"), systemImage: "doc.text") {
                if !title.isEmpty { Text(verbatim: title).font(.caption).lineLimit(1) }
            } content: {
                MarkdownView(markdown).textSelection(.enabled)
            }
            .accessibilityIdentifier("capabilityTextSummaryCard")
        case .listen(_, let thread, let explicitID, let title, let fallbackDetail, let rawText, let workspacePath):
            CapabilityListenCard(app: app, podcast: app.podcast, player: app.podcast.player,
                                 thread: thread, explicitID: explicitID, title: title, fallbackDetail: fallbackDetail, rawText: rawText, workspacePath: workspacePath)
        }
    }
}

/// Actions under the open thread's newest summary card (Retry, Check for new
/// replies, progress), given by the drawer that owns them (WUKO-134).
struct ThreadSummaryCardFooter {
    let rowID: UUID
    let content: (TopicSession) -> AnyView
}

extension EnvironmentValues {
    @Entry var threadSummaryCardFooter: ThreadSummaryCardFooter?
}

private struct CapabilityThreadSummaryCard: View {
    @ObservedObject var app: AppModel
    let rowID: UUID
    let thread: ThreadShape
    let fallbackText: String
    @Environment(\.threadSummaryCardFooter) private var footer

    var body: some View {
        let session = app.session(forThreadShape: thread)
        let summaryText = (session?.hasSummary == true ? session?.summary : nil) ?? fallbackText
        let maxPost = session?.totalPosts ?? thread.totalPosts
        let count = session?.summaryPostCount ?? maxPost
        let parsed = DrawerSummarySections.parsed(for: .init(text: summaryText, maximumPost: maxPost))
        if !parsed.rows.isEmpty {
            DCResultCard(label: String(localized: "Summary", comment: "Summary result card header"), systemImage: "doc.text") {
                if let count, count > 0 { Text(String(localized: "\(count) posts")).font(.caption) }
            } content: {
                DrawerSummarySections(rows: parsed.rows, layout: .singleColumn)
            }
            .environment(\.openURL, OpenURLAction { url in
                if let number = PostCitations.postNumber(from: url) {
                    if let session, session.topicKey == app.currentTopic?.topicKey {
                        app.jumpToCitation(number)
                    } else if let target = session?.url ?? URL(string: thread.url) {
                        app.browser.load(target)
                    }
                    return .handled
                }
                guard ForumBrowserModel.isBrowsableURL(url) else { return .systemAction }
                app.browser.load(url)
                return .handled
            })
            .accessibilityIdentifier("capabilityThreadSummaryCard")
            if let footer, footer.rowID == rowID, let session, session.topicKey == app.currentTopic?.topicKey {
                footer.content(session)
            }
        }
    }
}

private struct CapabilityListenCard: View {
    @ObservedObject var app: AppModel
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
        let readID = session?.topicKey ?? explicitID ?? ""
        let matches = !readID.isEmpty && player.playlist?.id == PodcastController.readAloudPlaylistID(readID)
        let timeline = player.timeline
        let progress = matches && timeline.total > 0 ? timeline.elapsed(player.position) / timeline.total : 0
        let detail = matches && timeline.total > 0
            ? "\(DockText.clock(timeline.elapsed(player.position))) / \(DockText.clock(timeline.total))"
            : fallbackDetail
        let speakText = session.map { PostCitations.stripped($0.summary) } ?? rawText.map { PostCitations.stripped($0) }
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
