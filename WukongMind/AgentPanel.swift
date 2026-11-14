import SwiftUI
import UIKit

/// "Ask the forum": the selected run's live step timeline and sourced answer
/// (the Ask box, AskBox.swift, asks and follows up), or examples and recent
/// runs when there is none.
struct AgentView: View {
    @ObservedObject var app: AppModel
    var showsProviderCard = false
    var embeddedInTranscript = false
    /// Opens a topic the agent read in the browser.
    let onOpenTopic: (URL) -> Void
    /// nil follows the run: open while it works, closed once it has an answer.
    @State private var stepsExpanded: Bool?
    @State private var bottomScrollTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        app: AppModel,
        showsProviderCard: Bool = false,
        embeddedInTranscript: Bool = false,
        onOpenTopic: @escaping (URL) -> Void
    ) {
        self.app = app
        self.showsProviderCard = showsProviderCard
        self.embeddedInTranscript = embeddedInTranscript
        self.onOpenTopic = onOpenTopic
    }

    private var run: AgentRun? {
        app.asksNewForumQuestion ? nil : app.selectedAgentRun
    }

    private var activeRecord: WorkRecord? {
        guard let run else { return nil }
        return app.activeRecord(forAgentRun: run.id)
    }

    private var isRunning: Bool {
        guard let run else { return false }
        return !run.isFinished
    }

    private var forum: Forum? { app.agentForum }

    @ViewBuilder
    private func runBody(_ run: AgentRun) -> some View {
        runHeader(run)
        if !run.steps.isEmpty {
            stepTimeline(run)
        }
        if !run.answer.isEmpty || !run.followUps.isEmpty {
            answerSection(run)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        if !run.error.isEmpty {
            Label(run.error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(DCTheme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dcCard(tint: DCTheme.danger)
                .accessibilityIdentifier("agentRunError")
        }
    }

    var body: some View {
        if embeddedInTranscript {
            if let run {
                VStack(alignment: .leading, spacing: 14) {
                    if showsProviderCard {
                        ProviderSetupCard(app: app, role: .agent)
                    }
                    runBody(run)
                }
                .onChange(of: app.selectedAgentRunID) {
                    stepsExpanded = nil
                }
            }
        } else {
            standaloneBody
        }
    }

    private var standaloneBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if showsProviderCard {
                            ProviderSetupCard(app: app, role: .agent)
                        }

                        askBoxHeader

                        if let run {
                            runBody(run)
                        } else {
                            askBoxEmptyState
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("agentBottom")
                    }
                    .padding(14)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .animation(DCMotion.respecting(reduceMotion), value: run?.steps.count)
                    .animation(DCMotion.respecting(reduceMotion), value: run.map { app.status(of: $0) })
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollToBottomEdge(trigger: bottomScrollTrigger, reduceMotion: reduceMotion)
                .accessibilityIdentifier("agentScroll")
                .environment(\.openURL, OpenURLAction { url in
                    guard ForumBrowserModel.isBrowsableURL(url) else { return .systemAction }
                    onOpenTopic(url)
                    return .handled
                })
                #if DEBUG
                .task {
                    if AssistantDebug.has("-dc-scroll-sources") {
                        try? await Task.sleep(for: .milliseconds(600))
                        if #available(iOS 18.0, *), run?.followUps.isEmpty != false {
                            bottomScrollTrigger &+= 1
                        } else {
                            await settleScroll(animated: false) { proxy.scrollTo("agentSources", anchor: .bottom) }
                        }
                    }
                }
                #endif
                .onChange(of: run?.steps.count ?? 0) { oldCount, newCount in
                    guard isRunning, newCount > oldCount else { return }
                    if #available(iOS 18.0, *) {
                        bottomScrollTrigger &+= 1
                    } else {
                        Task {
                            await settleScroll(reduceMotion: reduceMotion) {
                                proxy.scrollTo("agentBottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .animation(DCMotion.respecting(reduceMotion), value: run?.isFinished)
        .onChange(of: app.selectedAgentRunID) {
            stepsExpanded = nil
            bottomScrollTrigger = 0
        }
    }

    // MARK: Goal

    private var budgetText: some View {
        Text(
            "Reads the forum on its own — up to \(app.settings.agentMaxSteps) steps, \(app.settings.agentMaxTopicReads) topics. It never posts.",
            comment: "Ask the forum budget: maximum tool calls (steps) and topic reads per run"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var historyMenu: some View {
        Menu {
            ForEach(app.agentRuns) { previous in
                Button {
                    withAnimation(DCMotion.respecting(reduceMotion)) {
                        app.openAgentRun(id: previous.id)
                    }
                } label: {
                    Label(
                        "\(String(previous.goal.prefix(60))) · \(app.forumInfo(siteURL: previous.siteURL).displayName)",
                        systemImage: statusIcon(app.status(of: previous))
                    )
                }
            }
        } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
                .font(.footnote.weight(.semibold))
                .frame(minHeight: DCTheme.controlHeight)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("agentHistoryMenu")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("How it works", systemImage: "sparkle.magnifyingglass")
                .font(.headline)
                .foregroundStyle(DCTheme.agentTint)
            howItWorks(
                "magnifyingglass",
                forum.map {
                    String(localized: "Searches \($0.displayName) for your question.", comment: "How Ask the forum works; the placeholder is a forum name")
                } ?? String(localized: "Searches the forum for your question.")
            )
            howItWorks("text.bubble", String(localized: "Reads or summarizes the most relevant topics."))
            howItWorks("checkmark.seal", String(localized: "Answers with numbered sources you can open."))
            Text("Summaries it creates are saved like your own. It can watch topics for new replies.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .dcCard()
    }

    private func howItWorks(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(DCTheme.agentTint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text).font(.subheadline)
        }
    }

    // MARK: With the Ask box

    /// History (until the History page, Phase 7) and New question / back
    /// to the answer.
    @ViewBuilder
    private var askBoxHeader: some View {
        let onForumHome = app.currentTopic == nil && app.assistantPageState == .forumHome
        let hasRuns = !app.agentRuns.isEmpty
        if hasRuns || onForumHome {
            HStack(spacing: 8) {
                if onForumHome {
                    Button {
                        withAnimation(DCMotion.respecting(reduceMotion)) { app.showForumOverview() }
                    } label: {
                        Label(String(localized: "Forum overview", comment: "Button: returns from Ask the forum to the forum home overview"), systemImage: "chevron.left")
                            .font(.footnote.weight(.semibold))
                            .frame(minHeight: DCTheme.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .tint(DCTheme.agentTint)
                    .accessibilityIdentifier("agentForumOverview")
                }
                if hasRuns {
                    historyMenu
                }
                Spacer(minLength: 4)
                if run != nil {
                    Button {
                        withAnimation(DCMotion.respecting(reduceMotion)) { app.startNewAgentQuestion() }
                    } label: {
                        Label("New question", systemImage: "square.and.pencil")
                            .font(.footnote.weight(.semibold))
                            .frame(minHeight: DCTheme.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .tint(DCTheme.agentTint)
                    .accessibilityIdentifier("agentNewQuestion")
                } else if app.agentComposesNewQuestion {
                    Button {
                        withAnimation(DCMotion.respecting(reduceMotion)) { app.showSelectedAgentRun() }
                    } label: {
                        Label("Last answer", systemImage: "arrow.uturn.backward")
                            .font(.footnote.weight(.semibold))
                            .frame(minHeight: DCTheme.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .tint(DCTheme.agentTint)
                    .accessibilityIdentifier("agentShowLastAnswer")
                }
            }
        }
    }

    /// Empty Whole forum: example questions, the recent runs on this forum,
    /// then how it works and its budget.
    private var askBoxEmptyState: some View {
        let runs = Array(app.agentRuns.filter { $0.siteURL == forum?.siteURL }.prefix(3))
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                DCSectionHeader(title: forum.map {
                    String(localized: "Ask \($0.displayName)", comment: "Heading above example questions for Ask the forum; the placeholder is a forum name")
                } ?? String(localized: "Ask the forum"))
                ForEach(AgentExamples.questions, id: \.self) { example in
                    Button {
                        DCHaptics.tap()
                        app.drafts.goal = example
                        app.askFocusRequest += 1
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkle")
                                .foregroundStyle(DCTheme.agentTint)
                                .accessibilityHidden(true)
                            Text(example)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: DCTheme.controlHeight)
                        .background(DCTheme.agentTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Fills the question box")
                    .accessibilityIdentifier("agentExample")
                }
            }
            if !runs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    DCSectionHeader(title: String(localized: "Recent questions", comment: "Section header: the latest Ask the forum runs on this forum"))
                    ForEach(runs) { previous in
                        Button {
                            withAnimation(DCMotion.respecting(reduceMotion)) { app.openAgentRun(id: previous.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: statusIcon(app.status(of: previous)))
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(statusColor(app.status(of: previous)))
                                    .frame(width: 28, height: 28)
                                    .background(statusColor(app.status(of: previous)).opacity(0.14), in: Circle())
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(previous.goal)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(previous.createdAt.formatted(.relative(presentation: .named)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: DCTheme.controlHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agentRecentRun")
                    }
                }
            }
            emptyState
            budgetText
        }
    }

    // MARK: Run

    private func runHeader(_ run: AgentRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                statusBadge(app.status(of: run))
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.goal)
                        .font(.headline)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("agentRunGoal")
                    Text(runStatusText(run))
                        .font(.caption)
                        .foregroundStyle(run.result == .failed ? DCTheme.danger : .secondary)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("agentRunStatus")
                }
                Spacer(minLength: 0)
                if let activeRecord {
                    Button("Stop", role: .destructive) {
                        app.cancel(record: activeRecord)
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("cancelAgentRun")
                }
            }
            if !run.isFinished {
                WorkProgressBar(recordID: activeRecord?.id, progress: app.progress, tint: DCTheme.agentTint)
            }
        }
        .dcCard(tint: run.isFinished ? .clear : DCTheme.agentTint)
    }

    private func statusBadge(_ status: WorkStatus) -> some View {
        ZStack {
            Circle().fill(statusColor(status).opacity(0.14))
            if status.isTerminal {
                Image(systemName: statusIcon(status))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(statusColor(status))
            } else {
                DCAgentRing(size: 18, lineWidth: DCTheme.ringWidth, isTurning: true)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }

    private func runStatusText(_ run: AgentRun) -> String {
        // Two keys so each count gets its own plural form.
        let steps = [
            String(localized: "\(run.steps.count) steps", comment: "Ask the forum run progress: tool calls made"),
            String(localized: "\(run.readTopicCount) topics read", comment: "Ask the forum run progress: topics read")
        ].joined(separator: " · ")
        switch app.status(of: run) {
        case .queued:
            return String(localized: "Waiting for a worker · \(steps)", comment: "Run status; the placeholder is “3 steps · 1 topics read”")
        case .running:
            let latest = activeRecord?.statusText ?? String(localized: "Working…")
            return "\(latest) · \(steps)"
        case .completed:
            let when = (run.completedAt ?? run.updatedAt).formatted(.relative(presentation: .named))
            return String(
                localized: "Done · \(steps) · \(when)",
                comment: "Run status; placeholders: “3 steps · 1 topics read” and a relative time such as “2 minutes ago”"
            )
        case .failed:
            return String(localized: "Failed · \(steps)", comment: "Run status; the placeholder is “3 steps · 1 topics read”")
        case .cancelled:
            return String(localized: "Cancelled · \(steps)", comment: "Run status; the placeholder is “3 steps · 1 topics read”")
        }
    }

    private func isStepsExpanded(_ run: AgentRun) -> Bool {
        stepsExpanded ?? (!run.isFinished || run.answer.isEmpty)
    }

    private func stepTimeline(_ run: AgentRun) -> some View {
        let developerMode = app.settings.agentDeveloperMode
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(run.steps.enumerated()), id: \.element.id) { index, step in
                stepRow(step, isActive: !run.isFinished && index == run.steps.count - 1, developerMode: developerMode)
            }
        }
        return Group {
            if !run.isFinished || run.steps.count == 1 {
                rows
            } else {
                DCStepsFold(
                    count: run.steps.count,
                    errorCount: run.steps.filter(\.isError).count,
                    isExpanded: stepsExpanded ?? false,
                    onToggle: {
                        withAnimation(DCMotion.respecting(reduceMotion)) { stepsExpanded = !(stepsExpanded ?? false) }
                    }
                ) { rows.transition(.opacity) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentStepLog")
    }

    private func stepRow(_ step: AgentStep, isActive: Bool, developerMode: Bool) -> some View {
        HStack(alignment: .center, spacing: 4) {
            DCToolRow(
                label: toolTitle(step, running: isActive),
                codeName: developerMode ? step.tool : nil,
                duration: developerMode ? step.finishedAt.map { BrowserAgentPanelView.formatDuration($0.timeIntervalSince(step.startedAt)) } : nil,
                summary: isActive ? "" : step.outcome,
                state: isActive ? .running : (step.isError ? .error : .done)
            )
            if let topicKey = step.topicKey, let session = app.sessions[topicKey] {
                Button {
                    onOpenTopic(session.url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(DCTheme.jade)
                }
                .buttonStyle(DCIconButtonStyle())
                .accessibilityLabel("Open \(session.title) in Browse")
            }
        }
        .accessibilityIdentifier("agentStep")
    }

    // MARK: Answer

    private func answerSection(_ run: AgentRun) -> some View {
        let answer = run.initialAnswer.isEmpty ? run.answer : run.initialAnswer
        let sources = AgentSources.extract(from: answer, run: run, sessions: app.sessions, parse: app.linkParser(for: run))
        let label = sources.isEmpty
            ? String(localized: "Answer")
            : String(localized: "Answer · \(sources.count) sources", comment: "Answer card header; the placeholder is the number of sources")
        return DCResultCard(label: label, systemImage: "text.bubble") {
            if run.isFinished {
                TranslateButton(app: app, title: String(localized: "Answer"), text: answer, compact: true)
                    .buttonStyle(DCIconButtonStyle())
            }
            Menu {
                Button {
                    UIPasteboard.general.string = answer
                    DCHaptics.success()
                } label: {
                    Label("Copy answer", systemImage: "doc.on.doc")
                }
                ShareLink(item: answer) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if run.isFinished {
                    Button(role: .destructive) {
                        app.deleteAgentRun(id: run.id)
                    } label: {
                        Label("Delete run", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(DCIconButtonStyle())
            .accessibilityLabel("Answer actions")
            .accessibilityIdentifier("agentAnswerMenu")
        } content: {
            MarkdownView(AgentSources.annotate(answer, sources: sources, parse: app.linkParser(for: run)))
                .textSelection(.enabled)
                .accessibilityIdentifier("agentAnswer")

            if !sources.isEmpty {
                sourcesList(sources)
                    .id("agentSources")
            }

            if !run.followUps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(run.followUps) { message in
                        followUpRow(message, run: run, sources: sources)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func sourcesList(_ sources: [AgentSources.Source]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(sources) { source in
                Button {
                    DCHaptics.tap()
                    // The sources become the current list (result cards, Next).
                    if let run { app.followSources(sources, selecting: source, siteURL: run.siteURL) }
                    onOpenTopic(source.url)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        DCCitationChip(number: source.label)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            Text(sourceDetail(source))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DCTheme.jade)
                    }
                    .padding(10)
                    .background(DCTheme.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Source \(source.number): \(source.title)")
                .accessibilityValue(source.postNumber.map { String(localized: "Post \($0)", comment: "Accessibility value of an Ask the forum source that is one post of a topic; the number is the post number") } ?? "")
                .accessibilityHint(
                    source.postNumber == nil
                        ? String(localized: "Opens the topic in the browser")
                        : String(localized: "Opens the topic at this post in the browser", comment: "Accessibility hint of an Ask the forum source that is one post of a topic")
                )
                .accessibilityIdentifier("agentSource-\(source.number)")
            }
        }
    }

    /// The forum host, with the post number for a post-level source.
    private func sourceDetail(_ source: AgentSources.Source) -> String {
        let host = source.url.host ?? ""
        if !source.cited {
            return String(localized: "Read, not cited · \(host)", comment: "Source the agent read but didn't cite; the placeholder is the forum host")
        }
        if let post = source.postNumber {
            return String(localized: "Post \(post) · \(host)", comment: "Ask the forum source that is one post of a topic; the number is the post number, the placeholder the forum host")
        }
        return host
    }

    private func followUpRow(_ message: ChatMessage, run: AgentRun, sources: [AgentSources.Source]) -> some View {
        Group {
            if message.role == .user {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(DCTheme.inkMuted)
                        .accessibilityHidden(true)
                    Text(message.content)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownView(AgentSources.annotate(message.content, sources: sources, parse: app.linkParser(for: run)))
                        .textSelection(.enabled)
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        if run.isFinished {
                            TranslateButton(app: app, title: String(localized: "Answer"), text: message.content, compact: true)
                                .buttonStyle(DCIconButtonStyle())
                        }
                        Menu {
                            Button {
                                UIPasteboard.general.string = message.content
                                DCHaptics.success()
                            } label: {
                                Label("Copy answer", systemImage: "doc.on.doc")
                            }
                            ShareLink(item: message.content) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .buttonStyle(DCIconButtonStyle())
                        .accessibilityLabel("Answer actions")
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: Presentation helpers

    private func toolTitle(_ step: AgentStep, running: Bool) -> String {
        guard let tool = AgentToolName(rawValue: step.tool) else { return step.tool }
        let topic: () -> String = {
            if let topicKey = step.topicKey, let title = app.sessions[topicKey]?.title { return title }
            let id = step.arguments["topic_id"] ?? ""
            return String(localized: "topic \(id)", comment: "A topic without a known title; the placeholder is its number")
        }
        let query = step.arguments["query"] ?? ""
        return running ? tool.runningTitle(query: query, topic: topic) : tool.title(query: query, topic: topic)
    }

    private func statusIcon(_ status: WorkStatus) -> String {
        switch status {
        case .queued, .running: "circle.dotted"
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        }
    }

    private func statusColor(_ status: WorkStatus) -> Color {
        switch status {
        case .queued, .running: DCTheme.agentTint
        case .completed: DCTheme.success
        case .failed: DCTheme.danger
        case .cancelled: .secondary
        }
    }
}

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
                return runningRow.toolName == "read_page" ? .search : .run
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

struct BrowserAgentRunsView: View {
    @ObservedObject var app: AppModel
    let session: BrowserAgentSession
    @Binding var expandedToolRowIDs: Set<UUID>
    @State private var manuallyExpandedRunIDs: Set<UUID> = []
    @State private var screenshotSheet: ScreenshotSheetItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isProviderReady: Bool { app.isProviderReady(for: .browserAgent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(session.runs.enumerated()), id: \.element.id) { index, run in
                runSection(run, isLatest: index == session.runs.count - 1)
            }
        }
        .sheet(item: $screenshotSheet) { item in
            DCScreenshotSheet(item: item)
        }
    }

    @ViewBuilder
    private func runSection(_ run: BrowserAgentRun, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            userBubble(run.prompt)

            if !run.toolCalls.isEmpty {
                toolCallsSection(for: run)
            }

            if isLatest {
                ForEach(app.agentConfirmations.pending) { item in
                    AgentConfirmationCard(confirmation: item, gate: app.agentConfirmations)
                        .dcRiseIn()
                }
            }

            let savedEntries = savedScriptEntries(in: run)
            if !savedEntries.isEmpty {
                ForEach(savedEntries) { entry in
                    AgentScriptCardView(app: app, entry: entry)
                        .dcRiseIn()
                }
                DCSavedNote()
            }

            let reply = run.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty {
                MarkdownView(reply)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("agentAssistantReply")
                if app.settings.agentDeveloperMode, let info = run.finalTurn {
                    DevDetailsButton(app: app, session: session, taskID: run.id.uuidString, info: info)
                }
            }

            switch run.state {
            case .stepLimitReached(let limit):
                stepLimitCard(limit: limit)
            case .failed(let message) where isProviderReady:
                errorCard(message: message)
            default:
                EmptyView()
            }
        }
    }

    private func savedScriptEntries(in run: BrowserAgentRun) -> [SavedScriptCardEntry] {
        var seen: Set<String> = []
        var entries: [SavedScriptCardEntry] = []
        for row in run.toolCalls where row.toolName == "script_save" && !row.isRunning {
            guard let obj = try? JSONValue.parseObjectJSON(row.resultText),
                  let scriptID = obj["script_id"]?.stringValue,
                  !scriptID.isEmpty,
                  seen.insert(scriptID).inserted else {
                continue
            }
            let argsObj = try? JSONValue.parseObjectJSON(row.argumentsJSON)
            let fallbackName = obj["name"]?.stringValue
                ?? argsObj?["name"]?.stringValue
                ?? scriptID
            let fallbackRule = obj["match_rules"]?.arrayValue?.first?.stringValue
                ?? argsObj?["match_rules"]?.arrayValue?.first?.stringValue
                ?? ""
            entries.append(
                SavedScriptCardEntry(
                    scriptID: scriptID,
                    fallbackName: fallbackName,
                    fallbackFirstRule: fallbackRule
                )
            )
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
            VStack(alignment: .leading, spacing: 0) { toolRowList(run.toolCalls) }
        } else {
            DCStepsFold(
                count: run.toolCalls.count,
                errorCount: run.errorCount,
                isExpanded: isRunStepsExpanded(run),
                onToggle: {
                    DCHaptics.tap()
                    toggleRunSteps(run)
                }
            ) {
                toolRowList(run.toolCalls)
            }
        }
    }

    @ViewBuilder
    private func toolRowList(_ rows: [BrowserAgentToolCallRow]) -> some View {
        let developerMode = app.settings.agentDeveloperMode
        ForEach(rows) { row in
            let expanded = expandedToolRowIDs.contains(row.id)
            DCToolRow(
                label: DCToolLabel.browser(row.toolName, running: row.isRunning),
                codeName: developerMode ? row.toolName : nil,
                duration: developerMode ? row.duration.map(BrowserAgentPanelView.formatDuration) : nil,
                summary: row.isRunning ? "" : row.resultSummary,
                state: row.isRunning ? .running : (row.isError ? .error : (row.isPageWarning ? .warning : .done)),
                isExpanded: expanded,
                onToggle: {
                    DCHaptics.tap()
                    withAnimation(DCMotion.respecting(reduceMotion, DCMotion.quick)) {
                        if expanded { expandedToolRowIDs.remove(row.id) } else { expandedToolRowIDs.insert(row.id) }
                    }
                }
            ) {
                toolRowDetail(row, developerMode: developerMode)
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
            codeBlock(row.resultText.isEmpty ? row.resultSummary : row.resultText, id: "agentToolResult", warning: row.isPageWarning)
            if row.carriesImages {
                DCScreenshotStrip(row: row) { screenshotSheet = $0 }
            }
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
                if !row.resultText.isEmpty {
                    Button {
                        UIPasteboard.general.string = row.resultText
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

    private func codeBlock(_ text: String, id: String, warning: Bool = false) -> some View {
        Text(verbatim: text)
            .font(.caption.monospaced())
            .foregroundStyle(warning ? DCTheme.warning : DCTheme.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(DCTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
            .accessibilityIdentifier(id)
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
}
