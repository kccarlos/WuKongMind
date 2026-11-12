import SwiftUI
import UIKit

/// "Ask the forum": the selected run's live step timeline and sourced answer
/// (the Ask box, AskBox.swift, asks and follows up), or examples and recent
/// runs when there is none.
struct AgentView: View {
    @ObservedObject var app: AppModel
    var showsProviderCard = false
    /// Opens a topic the agent read in the browser.
    let onOpenTopic: (URL) -> Void
    /// nil follows the run: open while it works, closed once it has an answer.
    @State private var stepsExpanded: Bool?
    @State private var bottomScrollTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(app: AppModel, showsProviderCard: Bool = false, onOpenTopic: @escaping (URL) -> Void) {
        self.app = app
        self.showsProviderCard = showsProviderCard
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if showsProviderCard {
                            ProviderSetupCard(app: app, role: .agent)
                        }

                        askBoxHeader

                        if let run {
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
                ProgressView().controlSize(.small).tint(DCTheme.agentTint)
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
        let expanded = isStepsExpanded(run)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DCMotion.respecting(reduceMotion)) {
                    stepsExpanded = !expanded
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Steps")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(run.steps.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                    if !expanded {
                        toolStrip(run)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("agentStepsToggle")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(run.steps.enumerated()), id: \.element.id) { index, step in
                        stepRow(
                            step,
                            isLast: index == run.steps.count - 1,
                            isActive: !run.isFinished && index == run.steps.count - 1
                        )
                    }
                }
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
        .dcCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentStepLog")
    }

    /// Collapsed timeline: one tinted icon per step.
    private func toolStrip(_ run: AgentRun) -> some View {
        HStack(spacing: -4) {
            ForEach(run.steps.suffix(7)) { step in
                Image(systemName: toolIcon(step.tool))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(step.isError ? DCTheme.danger : toolTint(step.tool), in: Circle())
                    .overlay { Circle().stroke(DCTheme.surface, lineWidth: 1.5) }
            }
        }
        .accessibilityHidden(true)
    }

    private func stepRow(_ step: AgentStep, isLast: Bool, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill((step.isError ? DCTheme.danger : toolTint(step.tool)).opacity(0.15))
                    if isActive {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: toolIcon(step.tool))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(step.isError ? DCTheme.danger : toolTint(step.tool))
                    }
                }
                .frame(width: 28, height: 28)
                if !isLast {
                    Rectangle()
                        .fill(DCTheme.border)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(toolTitle(step))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !step.thought.isEmpty {
                    Text(step.thought)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !step.outcome.isEmpty {
                    Text(step.outcome)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(step.isError ? DCTheme.danger : toolTint(step.tool))
                        .lineLimit(3)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, isLast ? 0 : 14)
            Spacer(minLength: 0)
            if let topicKey = step.topicKey, let session = app.sessions[topicKey] {
                Button {
                    onOpenTopic(session.url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(DCTheme.brandBlue)
                }
                .buttonStyle(DCIconButtonStyle())
                .accessibilityLabel("Open \(session.title) in Browse")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agentStep")
    }

    // MARK: Answer

    private func answerSection(_ run: AgentRun) -> some View {
        let answer = run.initialAnswer.isEmpty ? run.answer : run.initialAnswer
        let sources = AgentSources.extract(from: answer, run: run, sessions: app.sessions, parse: app.linkParser(for: run))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble.fill")
                    .font(.subheadline)
                    .foregroundStyle(DCTheme.agentTint)
                    .frame(width: 32, height: 32)
                    .background(DCTheme.agentTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Answer")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 6) {
                        AssistantForumPill(forum: app.forumInfo(siteURL: run.siteURL))
                        if !sources.isEmpty {
                            Text("\(sources.count) sources")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
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
                    Button {
                        app.report(app.aiOutputReport(for: run, answer: answer, isInitial: true))
                    } label: {
                        Label(String(localized: "Report This Answer…", comment: "Assistant menu: report the AI's latest chat answer"), systemImage: "flag")
                    }
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("reportAgentAnswer")
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
            }

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
        .dcCard()
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
                        Text(source.label)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(DCTheme.agentTint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(DCTheme.agentTint.opacity(0.14), in: Capsule())
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
                            .foregroundStyle(DCTheme.brandBlue)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                        .foregroundStyle(DCTheme.brandBlue)
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
                            Button {
                                app.report(app.aiOutputReport(for: run, answer: message.content))
                            } label: {
                                Label(String(localized: "Report This Answer…", comment: "Assistant menu: report the AI's latest chat answer"), systemImage: "flag")
                            }
                            .disabled(message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private func toolIcon(_ tool: String) -> String {
        AgentToolName(rawValue: tool)?.symbol ?? "questionmark"
    }

    private func toolTint(_ tool: String) -> Color {
        switch AgentToolName(rawValue: tool)?.tint {
        case .search?: DCTheme.brandBlue
        case .read?: DCTheme.chatTint
        case .summarize?: DCTheme.agentTint
        case .watch?: DCTheme.warning
        case .answer?: DCTheme.success
        case nil: .secondary
        }
    }

    private func toolTitle(_ step: AgentStep) -> String {
        guard let tool = AgentToolName(rawValue: step.tool) else { return step.tool }
        return tool.title(query: step.arguments["query"] ?? "") {
            if let topicKey = step.topicKey, let title = app.sessions[topicKey]?.title { return title }
            let id = step.arguments["topic_id"] ?? ""
            return String(localized: "topic \(id)", comment: "A topic without a known title; the placeholder is its number")
        }
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

// MARK: - Browser Agent Chat Panel (M1)

struct BrowserAgentPanelView: View {
    @ObservedObject var app: AppModel
    @State private var draft = ""
    @State private var expandedToolRowIDs: Set<UUID> = []
    @State private var collapsedRunIDs: Set<UUID> = []
    @State private var manuallyExpandedRunIDs: Set<UUID> = []
    @State private var bottomScrollTrigger = 0
    @FocusState private var promptFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var session: BrowserAgentSession { app.browserAgent }
    private var isProviderReady: Bool { app.isProviderReady(for: .browserAgent) }

    private var currentHost: String {
        let host = BrowserAddress.host(app.browser.currentURL ?? app.pageContext.url)
        return host.isEmpty ? String(localized: "Current page", comment: "Browser agent context pill fallback when no host is available") : host
    }

    private var canSend: Bool {
        isProviderReady
            && !session.isRunning
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            contextRow
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !isProviderReady {
                            ProviderSetupCard(app: app, role: .browserAgent)
                        }

                        if session.runs.isEmpty {
                            emptyStateCard
                        } else {
                            ForEach(Array(session.runs.enumerated()), id: \.element.id) { index, run in
                                runSection(run, isLatest: index == session.runs.count - 1)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("browserAgentBottom")
                    }
                    .padding(14)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollToBottomEdge(trigger: bottomScrollTrigger, reduceMotion: reduceMotion)
                .accessibilityIdentifier("agentScroll")
                .onChange(of: session.runs.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: session.toolCalls.count) { _, _ in
                    #if DEBUG
                    if AssistantDebug.has("-dc-browser-agent-expand-first-tool"),
                       expandedToolRowIDs.isEmpty,
                       let first = session.toolCalls.first {
                        expandedToolRowIDs.insert(first.id)
                    }
                    #endif
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: session.runState) { _, newState in
                    scrollToBottom(proxy: proxy)
                    announceStateIfNeeded(newState)
                }
            }
            footerBar
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentPanel")
        .onChange(of: promptFocused) { _, focused in
            if focused, app.router.usesDrawer, app.router.drawerDetent == .medium {
                withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) {
                    app.router.drawerDetent = .large
                }
            }
        }
    }

    // MARK: Context row

    private var contextRow: some View {
        HStack(spacing: 8) {
            DCPill(text: currentHost, systemImage: "globe", tint: .secondary)
                .accessibilityIdentifier("agentHostPill")
            Text("\(0) scripts on this page", comment: "Browser agent context bar: number of saved scripts matching this page")
                .font(.caption.weight(.medium))
                .foregroundStyle(DCTheme.agentTint)
                .lineLimit(1)
                .accessibilityIdentifier("agentScriptsCount")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentContextRow")
    }

    // MARK: Empty state

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change this page by asking", comment: "Browser agent empty state card title")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 10) {
                howItWorksRow(
                    symbol: "doc.text",
                    tint: DCTheme.brandBlue,
                    text: String(localized: "Reads the page’s structure and text", comment: "Browser agent empty state: first how-it-works bullet")
                )
                howItWorksRow(
                    symbol: "curlybraces",
                    tint: DCTheme.agentTint,
                    text: String(localized: "Runs JavaScript and injects CSS live", comment: "Browser agent empty state: second how-it-works bullet")
                )
                howItWorksRow(
                    symbol: "hand.raised",
                    tint: DCTheme.chatTint,
                    text: String(localized: "Stops whenever you tap Stop", comment: "Browser agent empty state: third how-it-works bullet")
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.examples, id: \.self) { example in
                    Button {
                        DCHaptics.tap()
                        draft = example
                        if isProviderReady {
                            promptFocused = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DCTheme.agentTint)
                                .accessibilityHidden(true)
                            Text(example)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: DCTheme.controlHeight)
                        .background(
                            DCTheme.raisedSurface,
                            in: RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
                                .stroke(DCTheme.border)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("agentExample")
                }
            }

            Button {
                DCHaptics.tap()
                app.requestedSettingsPage = .agent
            } label: {
                Text("Up to \(app.settings.browserAgentMaxSteps) steps. Change it in Settings.", comment: "Browser agent empty state footer showing the configured step limit and linking to Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .underline()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agentStepLimitLink")
        }
        .dcCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentEmptyState")
    }

    private func howItWorksRow(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint.opacity(0.14))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static var examples: [String] {
        [
            String(localized: "Make this page dark and hide the sidebar", comment: "Browser agent example prompt 1"),
            String(localized: "Summarize the main points on this page", comment: "Browser agent example prompt 2"),
            String(localized: "Increase the font size and widen the article", comment: "Browser agent example prompt 3")
        ]
    }

    // MARK: Conversation runs

    @ViewBuilder
    private func runSection(_ run: BrowserAgentRun, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            userBubble(run.prompt)

            if !run.toolCalls.isEmpty {
                toolCallsSection(for: run, isLatest: isLatest)
            }

            let reply = run.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty {
                MarkdownView(reply)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("agentAssistantReply")
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

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 44)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    DCTheme.brandBlue.opacity(colorScheme == .dark ? 0.22 : 0.12),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .accessibilityIdentifier("agentUserMessage")
        }
    }

    private func isRunStepsExpanded(_ run: BrowserAgentRun, isLatest: Bool) -> Bool {
        if case .running = run.state { return true }
        if collapsedRunIDs.contains(run.id) { return false }
        if manuallyExpandedRunIDs.contains(run.id) { return true }
        return isLatest
    }

    private func toggleRunSteps(_ run: BrowserAgentRun, isLatest: Bool) {
        let currentlyExpanded = isRunStepsExpanded(run, isLatest: isLatest)
        withAnimation(DCMotion.respecting(reduceMotion, DCMotion.quick)) {
            if currentlyExpanded {
                collapsedRunIDs.insert(run.id)
                manuallyExpandedRunIDs.remove(run.id)
            } else {
                collapsedRunIDs.remove(run.id)
                manuallyExpandedRunIDs.insert(run.id)
            }
        }
    }

    @ViewBuilder
    private func toolCallsSection(for run: BrowserAgentRun, isLatest: Bool) -> some View {
        let isRunning: Bool = {
            if case .running = run.state { return true }
            return false
        }()
        let expanded = isRunStepsExpanded(run, isLatest: isLatest)

        if isRunning {
            if app.router.usesDrawer {
                VStack(alignment: .leading, spacing: 0) {
                    toolRowList(run.toolCalls)
                }
            } else {
                toolGroupContainer {
                    toolRowList(run.toolCalls)
                }
            }
        } else {
            toolGroupContainer {
                Button {
                    DCHaptics.tap()
                    toggleRunSteps(run, isLatest: isLatest)
                } label: {
                    HStack(spacing: 8) {
                        Text("Steps \(run.toolCalls.count)", comment: "Folded browser agent steps header showing the number of tool calls")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        toolIconStrip(run.toolCalls)
                        if run.errorCount > 0 {
                            Text("\(run.errorCount) errors", comment: "Browser agent steps header: tool error count")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DCTheme.danger)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: DCTheme.controlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agentStepsSummary")

                if expanded {
                    Divider()
                    toolRowList(run.toolCalls)
                }
            }
        }
    }

    private func toolGroupContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(
            DCTheme.surface,
            in: RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(DCTheme.border, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func toolRowList(_ rows: [BrowserAgentToolCallRow]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 {
                Divider()
            }
            BrowserAgentToolRowView(
                row: row,
                isExpanded: expandedToolRowIDs.contains(row.id),
                onToggle: {
                    DCHaptics.tap()
                    withAnimation(DCMotion.respecting(reduceMotion, DCMotion.quick)) {
                        if expandedToolRowIDs.contains(row.id) {
                            expandedToolRowIDs.remove(row.id)
                        } else {
                            expandedToolRowIDs.insert(row.id)
                        }
                    }
                }
            )
        }
    }

    private func toolIconStrip(_ rows: [BrowserAgentToolCallRow]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(rows.prefix(6))) { row in
                let style = BrowserAgentToolStyle.resolve(toolName: row.toolName, isError: row.isError)
                Image(systemName: style.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(style.tint)
                    .frame(width: 20, height: 20)
                    .background(style.tint.opacity(0.14), in: Circle())
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Step limit & error cards

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
        .dcCard(tint: DCTheme.danger)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentErrorCard")
    }

    // MARK: Sticky footer

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.runState != .idle || session.tokenUsage.totalTokens > 0 {
                statusLine
            }
            composerRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .dcStickyFooter()
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            switch session.runState {
            case .idle:
                EmptyView()
            case .running(let step, let maxSteps):
                Circle()
                    .fill(DCTheme.agentTint)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("Working · step \(max(1, step)) of \(maxSteps)", comment: "Browser agent footer status while a run is working")
                    .lineLimit(1)
            case .completed(let steps, let duration):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DCTheme.success)
                    .accessibilityHidden(true)
                Text("Done · \(steps) steps · \(Self.formatDuration(duration))", comment: "Browser agent footer status when a run finishes")
                    .lineLimit(1)
            case .stopped(let step):
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Stopped by you · step \(step)", comment: "Browser agent footer status when stopped by the user")
                    .lineLimit(1)
            case .stepLimitReached(let limit):
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(DCTheme.warning)
                    .accessibilityHidden(true)
                Text("Stopped at the step limit (\(limit))", comment: "Browser agent warning card title when the step limit is reached")
                    .lineLimit(1)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(DCTheme.danger)
                    .accessibilityHidden(true)
                Text("Turn failed", comment: "Browser agent footer status when a turn fails")
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("\(Self.formatTokens(session.tokenUsage.totalTokens)) tokens", comment: "Browser agent footer token counter")
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agentStatusLine")
    }

    private var composerPlaceholder: String {
        if !isProviderReady {
            return String(localized: "Choose a model first", comment: "Browser agent composer placeholder when no model is configured")
        }
        if session.isRunning {
            return String(localized: "Write your next message…", comment: "Browser agent composer placeholder while a run is in progress")
        }
        return String(localized: "Ask the agent to change this page…", comment: "Browser agent composer placeholder when ready")
    }

    private var composerRow: some View {
        HStack(spacing: 8) {
            TextField(composerPlaceholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused($promptFocused)
                .disabled(!isProviderReady)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(
                    Color(uiColor: .tertiarySystemFill),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(promptFocused ? DCTheme.agentTint.opacity(0.6) : DCTheme.border, lineWidth: 1)
                }
                .accessibilityIdentifier("agentPromptInput")

            if session.isRunning {
                Button {
                    DCHaptics.tap()
                    session.stop()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.caption.weight(.bold))
                        Text("Stop", comment: "Browser agent stop button title")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(DCTheme.danger, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .accessibilityLabel(Text("Stop", comment: "Browser agent stop button title"))
                .accessibilityIdentifier("agentStopButton")
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            canSend
                                ? AnyShapeStyle(DCTheme.brandGradient)
                                : AnyShapeStyle(Color.secondary.opacity(0.25)),
                            in: Circle()
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(Text("Send", comment: "Browser agent send button accessibility label"))
                .accessibilityIdentifier("agentSendButton")
            }
        }
    }

    private func sendDraft() {
        guard canSend else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        DCHaptics.tap()
        draft = ""
        session.send(prompt)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if #available(iOS 18.0, *) {
            bottomScrollTrigger &+= 1
        } else {
            withAnimation(DCMotion.respecting(reduceMotion, DCMotion.quick)) {
                proxy.scrollTo("browserAgentBottom", anchor: .bottom)
            }
        }
    }

    private func announceStateIfNeeded(_ state: BrowserAgentRunState) {
        switch state {
        case .stepLimitReached(let limit):
            AccessibilityNotification.Announcement(
                String(localized: "Stopped at the step limit (\(limit))", comment: "Browser agent warning card title when the step limit is reached")
            ).post()
        case .failed(let message):
            AccessibilityNotification.Announcement(message).post()
        default:
            break
        }
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 10 {
            return String(format: "%.1fs", max(0.1, duration))
        }
        return String(format: "%.0fs", duration)
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }
}

enum BrowserAgentToolStyle {
    struct Style {
        let symbol: String
        let tint: Color
    }

    static func resolve(toolName: String, isError: Bool) -> Style {
        if isError {
            return Style(symbol: "exclamationmark.triangle.fill", tint: DCTheme.danger)
        }
        switch toolName {
        case "read_page":
            return Style(symbol: "doc.text", tint: DCTheme.brandBlue)
        case "run_js":
            return Style(symbol: "curlybraces", tint: DCTheme.agentTint)
        case "inject_css":
            return Style(symbol: "drop", tint: DCTheme.chatTint)
        case "wait_for":
            return Style(symbol: "clock", tint: .secondary)
        case "script_save":
            return Style(symbol: "square.and.arrow.down", tint: DCTheme.agentTint)
        default:
            return Style(symbol: "wrench.and.screwdriver", tint: DCTheme.agentTint)
        }
    }
}

private struct BrowserAgentToolRowView: View {
    let row: BrowserAgentToolCallRow
    let isExpanded: Bool
    let onToggle: () -> Void

    private var style: BrowserAgentToolStyle.Style {
        BrowserAgentToolStyle.resolve(toolName: row.toolName, isError: row.isError)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: 10) {
                    Circle()
                        .fill(style.tint.opacity(0.14))
                        .frame(width: 28, height: 28)
                        .overlay {
                            if row.isRunning {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(style.tint)
                            } else {
                                Image(systemName: style.symbol)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(style.tint)
                            }
                        }
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: row.toolName)
                                .font(.subheadline.weight(.semibold).monospaced())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !row.argumentSummary.isEmpty {
                                Text(verbatim: row.argumentSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        Text(
                            row.isRunning
                                ? String(localized: "Running…", comment: "Browser agent tool row status while running")
                                : row.resultSummary
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(row.isError ? DCTheme.danger : style.tint)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 4)

                    if let duration = row.duration {
                        Text(verbatim: BrowserAgentPanelView.formatDuration(duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: DCTheme.controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agentToolRow")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ARGUMENTS", comment: "Expanded browser agent tool call section header for tool arguments JSON")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(verbatim: row.argumentsJSON)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                DCTheme.raisedSurface,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .accessibilityIdentifier("agentToolArguments")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("RESULT", comment: "Expanded browser agent tool call section header for tool result output")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            if !row.resultText.isEmpty {
                                Button {
                                    UIPasteboard.general.string = row.resultText
                                    DCHaptics.success()
                                } label: {
                                    Label(
                                        String(localized: "Copy", comment: "Button to copy tool call result text"),
                                        systemImage: "doc.on.doc"
                                    )
                                    .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(DCTheme.brandBlue)
                                .accessibilityIdentifier("agentToolCopyResult")
                            }
                        }
                        Text(verbatim: row.resultText.isEmpty ? row.resultSummary : row.resultText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                DCTheme.raisedSurface,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .accessibilityIdentifier("agentToolResult")

                        if row.wasTruncated {
                            Text("Truncated · \(row.totalCharacterCount) characters in total", comment: "Footer under a truncated browser agent tool output showing the original character count")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("agentToolTruncatedNote")
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }
}
