import SwiftUI

// This page › Developer › Site inspector and its tool trial run (design-learn-on-ask.md "Developer mode,
// part 2"; artboards LearnInspector*). Developer mode only: the entry is a row in `DevPageLogRows`.
// Tool names, reasons and returned text come from pages and models: always `verbatim`.

private enum SiteInspectorText {
    static func slot(_ slot: SiteToolSlot) -> String {
        switch slot {
        case .readTopic: String(localized: "Read a thread", comment: "Site inspector: the thread-reading slot")
        case .listLatest: String(localized: "Latest list", comment: "Site inspector: the latest-list slot")
        case .searchForum: String(localized: "Search", comment: "Site inspector: the search slot")
        }
    }

    static func step(_ number: Int) -> String {
        switch number {
        case 1: String(localized: "Registered", comment: "Verification step 1")
        case 2: String(localized: "Real arguments", comment: "Verification step 2")
        case 3: String(localized: "Strict shape", comment: "Verification step 3")
        case 4: String(localized: "Thread sanity", comment: "Verification step 4")
        case 5: String(localized: "List sanity", comment: "Verification step 5")
        case 6: String(localized: "Not constant", comment: "Verification step 6")
        case 7: String(localized: "Faithful", comment: "Verification step 7")
        case 8: String(localized: "Bounded", comment: "Verification step 8")
        default: String(localized: "Stays home", comment: "Verification step 9")
        }
    }

    static func logTitle(_ entry: SiteLogEntry) -> String {
        let name = entry.slot.map(slot) ?? ""
        let title: String
        switch entry.kind {
        case .learned: title = String(localized: "Learned", comment: "Learning log event")
        case .failed: title = String(localized: "Failed", comment: "Learning log event")
        case .broken: title = String(localized: "Broken", comment: "Learning log event")
        case .repaired: title = String(localized: "Repaired", comment: "Learning log event")
        case .turnedOff: title = String(localized: "Turned off by you", comment: "Learning log event")
        case .forgotten: title = String(localized: "Forgotten", comment: "Learning log event")
        }
        return name.isEmpty ? title : "\(title) · \(name)"
    }

    static func logSymbol(_ kind: SiteLogEventKind) -> (name: String, color: Color) {
        switch kind {
        case .learned, .repaired: ("checkmark", DCTheme.success)
        case .failed: ("xmark", DCTheme.danger)
        case .broken: ("exclamationmark.triangle", DCTheme.warning)
        case .turnedOff, .forgotten: ("minus", DCTheme.inkMuted)
        }
    }
}

/// A line of text in a small colored seal-like label: used for source and trust.
private struct InspectorTrustLine: View {
    let tool: SiteInspectorTool

    var body: some View {
        switch tool.kind {
        case .learned(_, _, let status):
            if status == .learned {
                label(String(localized: "Verified, reads only", comment: "Site inspector: a learned reader the app checked"), "checkmark", DCTheme.success)
            } else {
                label(String(localized: "Broken", comment: "Site inspector: a learned reader that failed"), "exclamationmark.triangle", DCTheme.warning)
            }
        case .site:
            label(tool.tool.annotations.readOnlyHint
                ? String(localized: "Untrusted · always asks · claims read-only", comment: "Site inspector: a site's own tool that says it only reads")
                : String(localized: "Untrusted · always asks", comment: "Site inspector: a site's own tool"),
                "shield", DCTheme.warning)
        case .script:
            label(tool.tool.annotations.readOnlyHint
                ? String(localized: "Marked read-only", comment: "Site inspector: a script's tool marked as only reading")
                : String(localized: "Follows Confirm before writes", comment: "Site inspector: a script's tool asks as the setting says"),
                "curlybraces", DCTheme.inkMuted)
        }
    }

    private func label(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label { Text(verbatim: text) } icon: { Image(systemName: symbol) }
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }
}

private struct InspectorSourceLabel: View {
    let kind: SiteInspectorTool.Kind

    var body: some View {
        let text: String = switch kind {
        case .site: String(localized: "This site", comment: "Site inspector: a tool the website registered itself")
        case .script(let name): String(localized: "Script · \(name)", comment: "Site inspector: a tool from a saved script")
        case .learned(_, let name, _): String(localized: "Learned · \(name)", comment: "Site inspector: a learned reader's script")
        }
        Text(verbatim: text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(DCTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous))
            .foregroundStyle(DCTheme.ink)
    }
}

/// A navigation title with a monospaced second line: the host, or the tool's full name (middle-truncated).
private struct InspectorTitle: View {
    let title: Text
    let subtitle: String

    var body: some View {
        VStack(spacing: 0) {
            title.font(.headline)
            Text(verbatim: subtitle).font(DCType.caption.monospaced()).foregroundStyle(DCTheme.inkMuted)
                .lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Site inspector

struct SiteInspectorView: View {
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var pageURL = ""
    @State private var state: SiteToolState?
    @State private var tools: [SiteInspectorTool] = []
    @State private var auditTasks: [String: AuditTask] = [:]
    @State private var selectedSlot: SiteToolSlot = .readTopic
    @State private var openTask: AuditTask?
    @State private var forgetting = false
    @State private var showingNotesPicker = false

    private var notesURL: URL { app.agentWorkspace.root.appendingPathComponent("sites/\(host)/notes.md") }

    var body: some View {
        NavigationStack {
            List {
                toolsSection
                readingSection
                lastCheckSection
                logSection
                notesSection
                forgetSection
            }
            .listStyle(.insetGrouped)
            .dcGroupedBackground()
            .tint(DCTheme.goldInk)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { InspectorTitle(title: Text("Site inspector", comment: "Developer mode sheet title"), subtitle: host) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(item: $openTask) { AuditTaskPage(app: app, task: $0, focusStep: nil) }
            .navigationDestination(for: SiteInspectorTool.ID.self) { id in
                if let tool = tools.first(where: { $0.id == id }) {
                    ToolTrialView(app: app, tool: tool, state: state, host: host, pageURL: pageURL)
                }
            }
        }
        .accessibilityIdentifier("siteInspector")
        .task { await load() }
        .confirmationDialog(
            String(localized: "Forget this site?", comment: "Site inspector: confirmation title"),
            isPresented: $forgetting, titleVisibility: .visible
        ) {
            Button(String(localized: "Forget this site", comment: "Site inspector: confirm"), role: .destructive) {
                SiteInspectorState.forget(host: host, store: app.siteToolStateStore)
                state = app.siteToolStateStore.state(forHost: host)
            }
        }
    }

    private func load() async {
        let url = app.pageContext.url ?? app.browser.webView.url
        host = url.flatMap { SiteToolState.normalizedHost(from: $0) } ?? ""
        pageURL = url?.absoluteString ?? ""
        state = app.siteToolStateStore.state(forHost: host)
        var snapshot = await app.pageToolBridge.collectTools()
        #if DEBUG
        if AssistantDebug.has("-dc-site-inspector-seed") { snapshot = .inspectorSeed }
        #endif
        tools = SiteInspectorTool.rows(snapshot: snapshot, state: state, scripts: app.scriptStore.scripts)
        let log = app.auditLog
        let ids = Set((state?.log ?? []).compactMap(\.taskID))
        auditTasks = await Task.detached { Dictionary(uniqueKeysWithValues: log.days().flatMap(\.tasks).filter { ids.contains($0.id) }.map { ($0.id, $0) }) }.value
    }

    // MARK: Sections

    private var toolsSection: some View {
        Section {
            if tools.isEmpty {
                Text("No tools on this page.", comment: "Site inspector: nothing registered").foregroundStyle(.secondary)
            }
            ForEach(tools) { tool in
                NavigationLink(value: tool.id) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: tool.tool.prefixedName).font(DCType.code.weight(.semibold))
                        InspectorSourceLabel(kind: tool.kind)
                        InspectorTrustLine(tool: tool)
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("siteInspectorTool-\(tool.id)")
            }
        } header: {
            HStack {
                Text("Tools on this page", comment: "Site inspector section title")
                Spacer()
                Text(verbatim: "\(tools.count)")
            }
        }
    }

    private var readingSection: some View {
        Section {
            ForEach(SiteToolSlot.allCases, id: \.self) { slot in
                slotRow(slot, state?.slot(slot) ?? SiteSlotState())
            }
        } header: {
            Text("Reading", comment: "Site inspector section title")
        }
    }

    private func slotRow(_ slot: SiteToolSlot, _ slotState: SiteSlotState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: SiteInspectorText.slot(slot)).font(.body.weight(.semibold))
            switch slotState.status {
            case .learned:
                Label(String(localized: "Learned", comment: "Site inspector slot status"), systemImage: "checkmark").foregroundStyle(DCTheme.success)
            case .broken:
                Label { Text(verbatim: String(localized: "Broken: \(slotState.failure?.sentence ?? "") · waits for repair", comment: "Site inspector slot status; the reason follows")) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(DCTheme.warning)
            case .failed:
                Label { Text(verbatim: String(localized: "Failed: \(slotState.failure?.sentence ?? "")", comment: "Site inspector slot status; the reason follows")) } icon: { Image(systemName: "xmark") }
                    .foregroundStyle(DCTheme.danger)
            case .untried:
                Text("Not tried", comment: "Site inspector slot status").foregroundStyle(.secondary)
            case .notApplicable:
                Text("Not applicable", comment: "Site inspector slot status").foregroundStyle(.secondary)
            }
            if let scriptID = slotState.scriptID, let script = app.scriptStore.script(id: scriptID) {
                Text(verbatim: script.name + (slotState.verifiedAt.map { " · " + String(localized: "verified \($0.formatted(date: .abbreviated, time: .shortened))", comment: "Site inspector: when the slot was last verified") } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if slotState.status == .broken {
                Text("Repair failed \(slotState.repairFailures) of 3 times.", comment: "Site inspector: repairs tried on a broken reader")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let reason = slotState.failure?.agentReason, !reason.isEmpty {
                Text(verbatim: String(localized: "Agent: \"\(reason)\"", comment: "Site inspector: the Agent's own words about a failure"))
                    .font(.caption.italic()).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var lastCheckSection: some View {
        let check = state?.slot(selectedSlot).lastCheck
        return Section {
            Picker(selection: $selectedSlot) {
                ForEach(SiteToolSlot.allCases, id: \.self) { Text(verbatim: SiteInspectorText.slot($0)).tag($0) }
            } label: { Text("Slot", comment: "Site inspector: picks which slot's last check to show") }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("siteInspectorSlotPicker")
            if let check {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: check.url).font(DCType.code).textSelection(.enabled)
                    Text(verbatim: check.result).font(.subheadline).foregroundStyle(DCTheme.success)
                }
                ForEach(check.steps ?? [], id: \.step) { stepRow($0) }
            } else {
                Text("No check yet.", comment: "Site inspector: the slot was never verified").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Last check", comment: "Site inspector section title")
                Spacer()
                if let check {
                    Text(verbatim: check.date.formatted(date: .abbreviated, time: .shortened)
                        + (check.durationMs.map { String(format: " · %.1f s", $0 / 1_000) } ?? ""))
                }
            }
        }
    }

    private func stepRow(_ result: SiteVerificationStepResult) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(result.step)").foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
            Text(verbatim: SiteInspectorText.step(result.step))
            if let detail = result.detail {
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: result.status == .passed ? "checkmark" : (result.status == .failed ? "xmark" : "minus"))
                .foregroundStyle(result.status == .passed ? DCTheme.success : (result.status == .failed ? DCTheme.danger : DCTheme.inkMuted))
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private var logSection: some View {
        Section {
            if (state?.log ?? []).isEmpty {
                Text("Nothing learned here yet.", comment: "Site inspector: empty learning log").foregroundStyle(.secondary)
            }
            ForEach(Array((state?.log ?? []).enumerated()), id: \.offset) { _, entry in
                let task = entry.taskID.flatMap { auditTasks[$0] }
                Button { openTask = task } label: {
                    HStack {
                        Image(systemName: SiteInspectorText.logSymbol(entry.kind).name)
                            .foregroundStyle(SiteInspectorText.logSymbol(entry.kind).color).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: SiteInspectorText.logTitle(entry)).font(.subheadline.weight(.medium))
                            Text(verbatim: entry.date.formatted(date: .abbreviated, time: .shortened)
                                + (task == nil ? "" : " · " + String(localized: "task record", comment: "Site inspector: the log row opens its task record")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if task != nil { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                    }
                }
                .foregroundStyle(DCTheme.ink)
                .disabled(task == nil)
            }
        } header: {
            HStack {
                Text("Learning log", comment: "Site inspector section title")
                Spacer()
                Text("newest \(SiteToolState.maxLogEntries)", comment: "Site inspector: the log keeps this many events")
            }
        }
    }

    private var notesSection: some View {
        Section {
            let modified = (try? FileManager.default.attributesOfItem(atPath: notesURL.path)[.modificationDate]) as? Date
            Button {
                showingNotesPicker = true
            } label: {
                HStack {
                    Image(systemName: "doc")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "sites/\(host)/notes.md").font(DCType.code)
                        Text(modified.map { String(localized: "Updated \($0.formatted(date: .abbreviated, time: .omitted)) · opens in Files", comment: "Site inspector: the notes file") }
                            ?? String(localized: "No notes yet", comment: "Site inspector: the Agent has not written notes for this site"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .foregroundStyle(DCTheme.ink)
            .disabled(modified == nil)
            .accessibilityIdentifier("siteInspectorNotes")
            .sheet(isPresented: $showingNotesPicker) {
                WorkspaceFilesPicker(directoryURL: notesURL.deletingLastPathComponent()) {
                    showingNotesPicker = false
                }
            }
        } header: {
            Text("Site notes", comment: "Site inspector section title")
        }
    }

    private var forgetSection: some View {
        Section {
            Button(role: .destructive) { forgetting = true } label: {
                Text("Forget this site", comment: "Site inspector button").frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("siteInspectorForget")
        } footer: {
            Text("Clears what it learned to read here, its checks and the wait before it tries again. Saved scripts stay; delete them in Scripts.",
                 comment: "Site inspector: what Forget this site does")
        }
    }
}

// MARK: - Tool trial run

struct ToolTrialView: View {
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismissSheet
    let tool: SiteInspectorTool
    let state: SiteToolState?
    let host: String
    let pageURL: String
    @State private var argumentsText = ""
    @State private var argumentsInvalid = false
    @State private var warning = false
    @State private var running = false
    @State private var outcome: ToolTrialOutcome?
    @State private var report: SiteToolVerificationReport?
    @State private var showSteps = false
    @State private var fullText: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    InspectorSourceLabel(kind: tool.kind)
                    InspectorTrustLine(tool: tool)
                }
            }
            Section {
                TextEditor(text: $argumentsText)
                    .font(DCType.code)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 96)
                    .accessibilityLabel(Text("Arguments, JSON", comment: "Trial run: the arguments editor"))
                    .accessibilityIdentifier("toolTrialArguments")
                if argumentsInvalid {
                    Text("The arguments are not a JSON object.", comment: "Trial run: the arguments did not parse").foregroundStyle(DCTheme.danger).font(.caption)
                }
            } header: { Text("Arguments · JSON", comment: "Trial run section title") }
            Section {
                HStack(spacing: 12) {
                    Button { start() } label: { Label { Text("Run", comment: "Trial run button") } icon: { Image(systemName: "play") }.frame(maxWidth: .infinity) }
                        .buttonStyle(DCActionButtonStyle(prominent: true))
                        .accessibilityIdentifier("toolTrialRun")
                    if tool.learnedSlot != nil {
                        Button { Task { await check() } } label: { Text("Check against the shape", comment: "Trial run button").frame(maxWidth: .infinity) }
                            .buttonStyle(DCActionButtonStyle())
                            .accessibilityIdentifier("toolTrialCheck")
                    }
                }
                .disabled(running)
                .listRowBackground(Color.clear)
            }
            if let outcome { returnedSection(outcome) }
            if let report { checkSection(report) }
        }
        .listStyle(.insetGrouped)
        .dcGroupedBackground()
        .tint(DCTheme.goldInk)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { InspectorTitle(title: Text("Try tool", comment: "Trial run title"), subtitle: tool.tool.prefixedName) }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismissSheet() } }
        }
        .onAppear { if argumentsText.isEmpty { argumentsText = ToolTrialArguments.skeleton(schema: tool.tool.inputSchema) } }
        .alert(
            String(localized: "Run this site's own tool?", comment: "Trial run warning title"), isPresented: $warning
        ) {
            Button(String(localized: "Cancel", comment: "Trial run warning cancel"), role: .cancel) {}
            Button(String(localized: "Run", comment: "Trial run warning confirm")) { Task { await run() } }
                .accessibilityIdentifier("toolTrialWarningRun")
        } message: {
            Text(verbatim: (tool.tool.annotations.readOnlyHint
                ? String(localized: "Nobody checked this code. It runs on \(host) with your login there. The page says it only reads; that is its own claim.", comment: "Trial run warning message")
                : String(localized: "Nobody checked this code. It runs on \(host) with your login there.", comment: "Trial run warning message, tool makes no read-only claim"))
                + "\n\n\(tool.tool.prefixedName)(\(argumentsText.replacingOccurrences(of: "\n", with: " ")))")
        }
        .sheet(item: Binding(get: { fullText.map(TrialText.init) }, set: { fullText = $0?.text })) { TrialBodySheet(text: $0.text) }
    }

    private func start() {
        guard ToolTrialArguments.parse(argumentsText) != nil else { argumentsInvalid = true; return }
        argumentsInvalid = false
        if tool.warnsBeforeTrial { warning = true } else { Task { await run() } }
    }

    private func run() async {
        guard let arguments = ToolTrialArguments.parse(argumentsText) else { return }
        running = true
        outcome = await ToolTrialRunner.run(
            tool, arguments: arguments, host: host, pageURL: pageURL, bridge: app.pageToolBridge,
            auditLog: app.auditLog, secrets: app.browserAgentRuntimeConfig.redactedSecrets
        )
        running = false
    }

    private func check() async {
        guard let slot = tool.learnedSlot, let state, let scriptID = state.slot(slot).scriptID,
              let script = app.scriptStore.script(id: scriptID) else { return }
        running = true
        report = await SiteShapeCheck.run(
            slot: slot, script: script, state: state, openPageURL: pageURL, bridge: app.browser.agentBridge,
            pageToolBridge: app.pageToolBridge, scriptStore: app.scriptStore
        )
        if let report {
            app.auditLog.append(.toolTrial(
                host: host, tool: tool.tool.prefixedName, argumentsJSON: "{}", time: Date(), pageURL: pageURL,
                durationMs: Int(report.slots[slot]?.durationMs ?? 0), resultBytes: nil,
                errorMessage: report.passed ? nil : report.reason, summary: "shape check · \(report.passed ? "passed" : "failed")"
            ))
        }
        running = false
    }

    private func returnedSection(_ outcome: ToolTrialOutcome) -> some View {
        Section {
            Button { fullText = outcome.text } label: {
                Text(verbatim: String(outcome.text.prefix(1_200)))
                    .font(DCType.code)
                    .foregroundStyle(outcome.isError ? DCTheme.danger : DCTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("toolTrialReturned")
        } header: {
            HStack {
                Text("Returned", comment: "Trial run section title")
                Spacer()
                Text(verbatim: String(format: "%.1f s · ", outcome.durationMs / 1_000) + ByteCountFormatter.string(fromByteCount: Int64(outcome.byteCount), countStyle: .file))
            }
        }
    }

    private func checkSection(_ report: SiteToolVerificationReport) -> some View {
        let passed = report.steps.filter { $0.status == .passed }.count, skipped = report.steps.filter { $0.status == .skipped }.count
        return Section {
            Button { showSteps.toggle() } label: {
                HStack {
                    Image(systemName: report.passed ? "checkmark" : "xmark").foregroundStyle(report.passed ? DCTheme.success : DCTheme.danger)
                    Text(verbatim: report.passed
                        ? String(localized: "Passed \(passed) · \(skipped) skipped", comment: "Trial run: the shape check passed, with counts")
                        : String(localized: "Failed at step \(report.failedStep ?? 0)", comment: "Trial run: the shape check failed at a step"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("Steps", comment: "Trial run: shows the check's steps").foregroundStyle(DCTheme.goldInk)
                }
            }
            .foregroundStyle(DCTheme.ink)
            .accessibilityIdentifier("toolTrialCheckResult")
            if let reason = report.reason { Text(verbatim: reason).font(.caption).foregroundStyle(DCTheme.danger) }
            if showSteps {
                ForEach(report.steps, id: \.step) { step in
                    HStack(spacing: 8) {
                        Text(verbatim: "\(step.step)").foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
                        Text(verbatim: SiteInspectorText.step(step.step))
                        if let detail = step.detail { Text(verbatim: detail).font(.caption).foregroundStyle(.secondary) }
                        Spacer(minLength: 4)
                        Image(systemName: step.status == .passed ? "checkmark" : (step.status == .failed ? "xmark" : "minus"))
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: { Text("Check against the shape", comment: "Trial run section title") }
    }
}

private struct TrialText: Identifiable { let text: String; var id: String { text } }

/// The raw return in the `DevBodySheet` style: selectable monospaced text, Copy and Share.
private struct TrialBodySheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: text).font(DCType.code).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .navigationTitle(Text("Returned", comment: "Trial run sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { UIPasteboard.general.string = text; DCHaptics.success() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    ShareLink(item: text)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
