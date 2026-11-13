import SwiftUI

// Settings › Agent, Audit log, Sites, Following, and Browser.

/// "55k characters" (shared with the summary batch label, so both read and
/// translate the same way).
private func characters(_ value: Int) -> String {
    SummaryBatchLimit.label(value)
}

/// Plain-language explanation shown above a control.
private struct SettingExplanation: View {
    let title: LocalizedStringKey
    let value: String
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Sites

struct SettingsSitesPage: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Form {
            Section {
                NavigationLink(value: SettingsPage.forums) {
                    SettingsIconRow {
                        SettingsIcon(page: .forums)
                    } title: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Forums")
                            Text("Saved sites, search & pins", comment: "Settings › Sites › Forums row subtitle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } trailing: {
                        Text("\(app.forums.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityIdentifier("settingsRow-forums")

                NavigationLink(value: SettingsPage.watched) {
                    SettingsIconRow {
                        SettingsIcon(page: .watched)
                    } title: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SettingsPage.watched.title)
                            Text("Check for new replies", comment: "Settings › Sites › Following row subtitle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } trailing: {
                        if !app.watchedTopics.isEmpty {
                            Text("\(app.watchedTopics.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .accessibilityIdentifier("settingsRow-watched")
            } header: {
                Text("Forums")
            }

            ForumRequestPaceSection(app: app)

            ContentBlockingSettingsSections(app: app, rules: app.contentRules)
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("sitesSettingsPage")
    }
}

/// Settings › Sites › Reading pace: how quickly topics are read.
private struct ForumRequestPaceSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Section {
            Toggle("Limit request rate", isOn: $app.settings.forumRateLimitingEnabled)
                .tint(DCTheme.goldInk)
                .accessibilityIdentifier("forumRateLimitingEnabled")
            if app.settings.forumRateLimitingEnabled {
                Picker(selection: $app.settings.forumRequestPace) {
                    ForEach(ForumRequestPace.allCases) { pace in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pace.title)
                            Text(pace.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(pace)
                        .accessibilityIdentifier("forumRequestPace-\(pace.rawValue)")
                    }
                } label: {
                    Text("Reading pace")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("forumRequestPace")
            }
        } header: {
            Text("Reading pace")
        } footer: {
            Text(footer)
        }
        .onChange(of: app.settings.forumRateLimitingEnabled) { app.saveSettings() }
        .onChange(of: app.settings.forumRequestPace) { app.saveSettings() }
    }

    private var footer: String {
        guard app.settings.forumRateLimitingEnabled else {
            return String(localized: "Requests are sent immediately without per-forum spacing or concurrency limits. Work that’s already running keeps its pace.", comment: "Settings › Summaries & chat › Forum requests footer when rate limiting is off")
        }
        var sentences = [
            String(localized: "Forums are run by people and communities who pay for their servers. Reading a topic one page at a time keeps WukongMind a polite visitor and avoids being rate limited.", comment: "Settings › Summaries & chat › Forum requests footer")
        ]
        switch app.settings.forumRequestPace {
        case .gentle:
            sentences.append(String(localized: "Long topics take longer to read: a 2,000-post topic takes about 20 seconds.", comment: "Forum requests footer for the Gentle pace (20 pages of 100 posts at 1 per second)"))
        case .standard:
            sentences.append(String(localized: "A 2,000-post topic takes about 10 seconds.", comment: "Forum requests footer for the Standard pace"))
        case .fast:
            sentences.append(String(localized: "Fast reads long topics quickest but puts the most load on the forum. Use it on forums you run or where you know it’s welcome.", comment: "Forum requests footer for the Fast pace"))
        }
        sentences.append(String(localized: "Work that’s already running keeps its pace.", comment: "Forum requests footer"))
        return sentences.joined(separator: " ")
    }
}

// MARK: - Agent

struct SettingsAgentPage: View {
    @ObservedObject var app: AppModel

    private var auditStepCount: Int {
        app.browserAgent.runs.reduce(0) { $0 + $1.toolCalls.count }
    }

    private var headerTitle: String {
        app.hasConfiguredModel(for: .browserAgent)
            ? app.modelLabel(for: .browserAgent)
            : app.providerSummary(for: .browserAgent)
    }

    private var headerSubtitle: String {
        let roleSubtitle = String(localized: "Agent model", comment: "Settings › Agent header subtitle under the selected model name")
        guard app.hasConfiguredModel(for: .browserAgent) else { return roleSubtitle }
        return "\(app.selection(for: .browserAgent).provider.displayName) · \(roleSubtitle)"
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ModelRolePage(app: app, role: .browserAgent)
                } label: {
                    SettingsIconRow {
                        DCListIconTile(kind: .agent, size: 44)
                    } title: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(headerTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(headerSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } trailing: {
                        Text("Change", comment: "Settings › Agent header link to change the Agent model")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DCTheme.goldInk)
                    }
                    .padding(.vertical, DCTheme.spacingXS)
                }
                .accessibilityIdentifier("browserAgentModelRow")
            }

            Section {
                Stepper(
                    "Step limit: \(app.settings.browserAgentMaxSteps)",
                    value: Binding(
                        get: { app.settings.browserAgentMaxSteps },
                        set: { app.settings.browserAgentMaxSteps = BrowserAgentLimits.clampSteps($0) }
                    ),
                    in: BrowserAgentLimits.stepRange
                )
                .accessibilityIdentifier("browserAgentMaxSteps")

                VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                    SettingExplanation(
                        title: "Result size",
                        value: characters(app.settings.browserAgentTruncationLimit),
                        detail: "Maximum size of each page read or JavaScript result sent back to the model."
                    )
                    Slider(
                        value: Binding(
                            get: { Double(app.settings.browserAgentTruncationLimit) },
                            set: { app.settings.browserAgentTruncationLimit = BrowserAgentLimits.clampTruncationLimit(Int($0)) }
                        ),
                        in: Double(BrowserAgentLimits.truncationRange.lowerBound)...Double(BrowserAgentLimits.truncationRange.upperBound),
                        step: 1_000
                    )
                    .tint(DCTheme.goldInk)
                    .accessibilityLabel("Result size")
                    .accessibilityValue(characters(app.settings.browserAgentTruncationLimit))
                    .accessibilityIdentifier("browserAgentTruncationLimit")
                }
            } header: {
                Text("Runs", comment: "Settings › Agent section header for step and result limits")
            } footer: {
                Text("Defaults: \(BrowserAgentLimits.defaultMaxSteps) steps, \(characters(BrowserAgentLimits.defaultTruncationLimit)) per tool result.")
            }

            Section {
                HStack {
                    Toggle("Confirm before writes", isOn: $app.settings.agentConfirmBeforeWrites)
                        .accessibilityIdentifier("agentConfirmBeforeWrites")
                    DCSeal(text: "M3", variant: .outline)
                }
            } header: {
                Text("Safety", comment: "Settings › Agent section header for confirmation settings")
            } footer: {
                Text("Your choice is saved now. Asking before network requests, cookie reads and form submits starts working with the M3 safety update.")
            }

            Section {
                NavigationLink {
                    SettingsAuditLogPage(app: app)
                } label: {
                    SettingsIconRow {
                        SettingsIcon(symbol: "list.bullet.clipboard", tint: DCTheme.ink)
                    } title: {
                        Text("Audit log", comment: "Settings › Agent › Records row opening the tool-call audit log")
                    } trailing: {
                        Text("\(auditStepCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityIdentifier("settingsRow-auditLog")
            } header: {
                Text("Records", comment: "Settings › Agent section header for the audit log")
            }

            Section {
                Toggle(isOn: $app.settings.agentDeveloperMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DCTheme.spacingS) {
                            Text("Developer mode", comment: "Settings › Agent switch showing raw tool payloads")
                            DCSeal(text: "M3", variant: .outline)
                        }
                        Text("Show raw tool arguments & results", comment: "Settings › Agent subtitle for Developer mode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("agentDeveloperMode")
            } header: {
                Text("Developer", comment: "Settings › Agent section header for developer diagnostics")
            }

            Section {
                Stepper(
                    "Search steps: \(app.settings.agentMaxSteps)",
                    value: Binding(
                        get: { app.settings.agentMaxSteps },
                        set: { app.settings.agentMaxSteps = AgentLimits.clampSteps($0) }
                    ),
                    in: AgentLimits.stepRange
                )
                .accessibilityIdentifier("agentMaxSteps")

                Stepper(
                    "Topics to read: \(app.settings.agentMaxTopicReads)",
                    value: Binding(
                        get: { app.settings.agentMaxTopicReads },
                        set: { app.settings.agentMaxTopicReads = AgentLimits.clampTopicReads($0) }
                    ),
                    in: AgentLimits.topicReadRange
                )
                .accessibilityIdentifier("agentMaxTopicReads")

                VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                    SettingExplanation(
                        title: "Read size",
                        value: characters(app.settings.agentReadLimit),
                        detail: "How much of each topic it reads. Larger reads catch more detail in long threads."
                    )
                    Slider(
                        value: Binding(
                            get: { Double(app.settings.agentReadLimit) },
                            set: { app.settings.agentReadLimit = AgentLimits.clampReadLimit(Int($0)) }
                        ),
                        in: Double(AgentLimits.readLimitRange.lowerBound)...Double(AgentLimits.readLimitRange.upperBound),
                        step: 5_000
                    )
                    .tint(DCTheme.goldInk)
                    .accessibilityLabel("Context per topic read")
                    .accessibilityValue(characters(app.settings.agentReadLimit))
                    .accessibilityIdentifier("agentReadLimit")
                }
            } header: {
                Text("Forum search", comment: "Settings › Agent section header for forum search limits")
            } footer: {
                Text("Used when searching across a forum. Defaults: \(AgentLimits.defaultMaxSteps) steps, \(AgentLimits.defaultMaxTopicReads) topics, \(characters(AgentLimits.defaultReadLimit)) per topic.")
            }

            if app.settings.agentMaxSteps != AgentLimits.defaultMaxSteps
                || app.settings.agentMaxTopicReads != AgentLimits.defaultMaxTopicReads
                || app.settings.agentReadLimit != AgentLimits.defaultReadLimit
                || app.settings.browserAgentMaxSteps != BrowserAgentLimits.defaultMaxSteps
                || app.settings.browserAgentTruncationLimit != BrowserAgentLimits.defaultTruncationLimit {
                Section {
                    Button("Restore defaults") {
                        app.settings.agentMaxSteps = AgentLimits.defaultMaxSteps
                        app.settings.agentMaxTopicReads = AgentLimits.defaultMaxTopicReads
                        app.settings.agentReadLimit = AgentLimits.defaultReadLimit
                        app.settings.browserAgentMaxSteps = BrowserAgentLimits.defaultMaxSteps
                        app.settings.browserAgentTruncationLimit = BrowserAgentLimits.defaultTruncationLimit
                    }
                    .accessibilityIdentifier("restoreAgentDefaults")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("agentSettingsPage")
        .onChange(of: app.settings.agentConfirmBeforeWrites) { app.saveSettings() }
        .onChange(of: app.settings.agentDeveloperMode) { app.saveSettings() }
        .onChange(of: app.settings.agentMaxSteps) { app.saveSettings() }
        .onChange(of: app.settings.agentMaxTopicReads) { app.saveSettings() }
        .onChange(of: app.settings.agentReadLimit) { app.saveSettings() }
        .onChange(of: app.settings.browserAgentMaxSteps) { app.saveSettings() }
        .onChange(of: app.settings.browserAgentTruncationLimit) { app.saveSettings() }
    }
}

struct SettingsAuditLogPage: View {
    @ObservedObject var app: AppModel

    private var runsWithToolCalls: [BrowserAgentRun] {
        app.browserAgent.runs.filter { !$0.toolCalls.isEmpty }.reversed()
    }

    var body: some View {
        Form {
            if runsWithToolCalls.isEmpty {
                Section {
                    Text("No tool calls recorded in this session yet.", comment: "Settings › Agent › Audit log empty state")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("auditLogEmptyState")
                } footer: {
                    Text("Every tool call's time, arguments and result summary appear here as the Agent works.")
                }
            } else {
                ForEach(runsWithToolCalls) { run in
                    Section {
                        ForEach(run.toolCalls) { step in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(verbatim: step.toolName)
                                        .font(DCType.code)
                                    Spacer()
                                    if step.isError {
                                        DCSeal(
                                            text: String(localized: "Error", comment: "Audit log badge for a failed tool call"),
                                            variant: .state(.error)
                                        )
                                    } else {
                                        DCSeal(text: "#\(step.stepNumber)", variant: .outline)
                                    }
                                }
                                if !step.argumentSummary.isEmpty {
                                    Text(verbatim: step.argumentSummary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text(verbatim: step.resultSummary)
                                    .font(.caption)
                                    .foregroundStyle(step.isError ? DCTheme.danger : .secondary)
                                    .lineLimit(3)
                                if app.settings.agentDeveloperMode {
                                    Text(verbatim: step.argumentsJSON)
                                        .font(DCType.code)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(6)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text(verbatim: "\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(run.prompt)")
                            .lineLimit(1)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .dcGroupedBackground()
        .tint(DCTheme.goldInk)
        .navigationTitle(Text("Audit log", comment: "Navigation bar title of the Agent audit log screen"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("auditLogPage")
    }
}

// MARK: - Following

struct SettingsWatchedPage: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: DCTheme.spacingM) {
                    Text("Notifications")
                    Spacer()
                    if app.notificationsAuthorized {
                        Label("On", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(DCTheme.success)
                            .font(.subheadline.weight(.semibold))
                    } else {
                        Button("Turn on") { app.requestNotificationAuthorization() }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("enableNotifications")
                    }
                }
                Toggle(isOn: $app.settings.watchAutoRefreshSummaries) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Refresh their summaries")
                        Text("When new replies arrive, with your Summaries model", comment: "Settings › Sites › Following toggle subtitle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(DCTheme.goldInk)
                .accessibilityIdentifier("watchAutoRefresh")
            } footer: {
                Text("Checked when you open WukongMind, every 30 minutes while it’s open, and now and then in the background.")
            }

            Section {
                if app.watchedTopics.isEmpty {
                    Text("You’re not watching any topics yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.watchedTopics) { watched in
                        Button {
                            DCHaptics.tap()
                            app.openWatched(watched)
                        } label: {
                            HStack(spacing: DCTheme.spacingM) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(watched.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(app.forum(for: watched.siteURL)?.displayName ?? ForumSite.host(of: watched.siteURL))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: DCTheme.spacingS)
                                if watched.newReplies > 0 {
                                    DCSeal(
                                        text: String(localized: "\(watched.newReplies) new", comment: "Badge: number of new replies in a watched topic"),
                                        variant: .gold
                                    )
                                }
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("settingsWatchedRow-\(watched.topicID)")
                        .swipeActions {
                            Button("Unwatch", role: .destructive) {
                                withAnimation { app.unwatch(topicKey: watched.topicKey) }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Watching · \(app.watchedTopics.count)", comment: "Settings › Watched topics section header with the number of watched topics")
                    Spacer()
                    if !app.watchedTopics.isEmpty {
                        if app.isCheckingWatches {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityIdentifier("checkingWatchedTopics")
                        } else {
                            Button("Check now") {
                                DCHaptics.tap()
                                Task { await app.checkWatchedTopics(reason: .manual) }
                            }
                            .font(.footnote.weight(.semibold))
                            .textCase(nil)
                            .accessibilityIdentifier("checkWatchedTopics")
                        }
                    }
                }
            } footer: {
                Text("Swipe left to stop watching. Watch a topic from the drawer’s ⋯ menu or the forum menu.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: app.settings.watchAutoRefreshSummaries) { app.saveSettings() }
    }
}

// MARK: - Browser

struct SettingsBrowserPage: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Search engine", selection: $app.settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(verbatim: engine.displayName).tag(engine)
                    }
                }
                .accessibilityIdentifier("searchEnginePicker")
            } header: {
                Text("Search", comment: "Settings › Browser section header for the web search engine picker")
            } footer: {
                Text("Your choice is saved now. Web search from the address bar arrives with the unified address field.", comment: "Settings › Browser footer: search engine is not yet used by the address bar")
            }

            Section {
                HStack(spacing: DCTheme.spacingXL) {
                    ForEach(BrowserBarPosition.allCases) { position in
                        BrowserBarPreview(
                            position: position,
                            selected: app.settings.browserBarPosition == position
                        ) {
                            withAnimation(DCMotion.quick) { app.settings.browserBarPosition = position }
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: app.settings.browserBarPosition)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DCTheme.spacingS)
                .listRowSeparator(.hidden)

                Picker("Browser bar", selection: $app.settings.browserBarPosition) {
                    ForEach(BrowserBarPosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("browserBarPosition")
            } header: {
                Text("Browser bar")
            } footer: {
                VStack(alignment: .leading, spacing: DCTheme.spacingXS) {
                    Text("The bar shrinks while you scroll down a forum page and comes back when you scroll up or tap it. Bottom keeps it within reach of your thumb.")
                    Text("Automatic puts it at the bottom on iPhone and in narrow windows, and at the top when the assistant is beside the page.")
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        Text("With the assistant beside the page, the bar is always at the top: Top and Bottom apply to the single-column layout.", comment: "Settings › Browser footer on iPad: the bar position setting has no effect in the side-by-side layout")
                            .accessibilityIdentifier("browserBarSplitNote")
                    }
                }
            }

            Section {
                Picker("When WukongMind opens", selection: $app.settings.launchDestination) {
                    ForEach(LaunchDestination.allCases) { destination in
                        Text(destination.displayName).tag(destination)
                    }
                }
                .accessibilityIdentifier("launchDestination")
            } footer: {
                Text("Automatic opens Home the first time each day when Today has a podcast or digest, and otherwise the forum you read last. Links, notifications, Siri and shared pages always open what they point to.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: app.settings.searchEngine) { app.saveSettings() }
        .onChange(of: app.settings.browserBarPosition) { app.saveSettings() }
        .onChange(of: app.settings.launchDestination) { app.saveSettings() }
    }
}

/// Block ads / Block trackers and the sites allowed to show ads.
private struct ContentBlockingSettingsSections: View {
    @ObservedObject var app: AppModel
    @ObservedObject var rules: ContentRuleLibrary

    var body: some View {
        Section {
            Toggle(isOn: $app.settings.contentBlockingEnabled) {
                Label {
                    Text("Block ads")
                } icon: {
                    SettingsIcon(symbol: "shield.lefthalf.filled", tint: DCTheme.ink)
                }
            }
            .accessibilityIdentifier("blockAdsToggle")
            Toggle(isOn: $app.settings.blockTrackers) {
                Label {
                    Text("Block trackers")
                } icon: {
                    SettingsIcon(symbol: "eye.slash.fill", tint: DCTheme.ink)
                }
            }
            .accessibilityIdentifier("blockTrackersToggle")
        } header: {
            Text("Ads & trackers")
        } footer: {
            Text(footer)
                .accessibilityIdentifier("contentBlockingFootnote")
        }
        // The lists' date, without looking up or compiling anything.
        .onAppear { rules.loadManifestIfNeeded() }

        Section {
            if app.settings.adBlockAllowedSites.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(app.settings.adBlockAllowedSites, id: \.self) { host in
                    Label(host, systemImage: "shield.slash")
                        .accessibilityIdentifier("allowedSite-\(host)")
                }
                .onDelete { offsets in
                    withAnimation { app.removeAllowedSites(atOffsets: offsets) }
                }
            }
        } header: {
            Text("Allowed sites")
        } footer: {
            Text(
                app.settings.adBlockAllowedSites.isEmpty
                    ? "To let a site show ads, open it and tap the shield in the address bar."
                    : "Ads and trackers aren’t blocked on these sites. Swipe left to remove one."
            )
        }
    }

    /// Whole sentences, each its own localizable string, joined by spaces.
    private var footer: String {
        var sentences = [
            String(localized: "Off by default, out of respect for forum owners who rely on ads. Turn either switch on to block them in the built-in browser.", comment: "Settings › Browser: why ad and tracker blocking starts off"),
            String(localized: "Uses EasyList and EasyPrivacy filter lists.")
        ]
        if let date = rules.manifest?.generatedDate {
            let day = date.formatted(date: .abbreviated, time: .omitted)
            sentences.append(String(localized: "Lists from \(day).", comment: "Filter lists' date"))
        } else if let version = rules.manifest?.version {
            sentences.append(String(localized: "Lists version \(version)."))
        }
        if rules.phase == .compiling, app.settings.contentBlockingEnabled || app.settings.blockTrackers {
            sentences.append(String(localized: "Preparing the lists…"))
        }
        sentences.append(String(localized: "Forum sign-in pages are never blocked."))
        return sentences.joined(separator: " ")
    }
}

/// Tiny phone mock with the bar at the top or bottom (Automatic: at the
/// bottom, with the top outlined).
private struct BrowserBarPreview: View {
    let position: BrowserBarPosition
    let selected: Bool
    let action: () -> Void

    private var accessibilityLabel: Text {
        switch position {
        case .automatic: Text("Bar placed automatically", comment: "Settings › Browser: preview of the Automatic bar position")
        case .top: Text("Bar at the top")
        case .bottom: Text("Bar at the bottom")
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: DCTheme.spacingS) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DCTheme.raisedSurface)
                    .frame(width: 70, height: 120)
                    .overlay(alignment: position == .top ? .top : .bottom) {
                        Capsule()
                            .fill(selected ? DCTheme.gold : Color.secondary.opacity(0.5))
                            .frame(width: 52, height: 12)
                            .padding(8)
                    }
                    .overlay(alignment: .top) {
                        // Automatic: bottom, or top beside the assistant.
                        if position == .automatic {
                            Capsule()
                                .strokeBorder(
                                    selected ? DCTheme.gold : Color.secondary.opacity(0.5),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                                )
                                .frame(width: 52, height: 12)
                                .padding(8)
                        }
                    }
                    .overlay {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(0..<4, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.secondary.opacity(0.25))
                                    .frame(width: index.isMultiple(of: 2) ? 44 : 34, height: 5)
                            }
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selected ? DCTheme.gold : DCTheme.border, lineWidth: selected ? 2 : 1)
                    }
                Text(position.displayName)
                    .font(.footnote.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DCTheme.goldInk : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
