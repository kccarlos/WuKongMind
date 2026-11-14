import SwiftUI

// Developer mode, part 1: the UI half (design-m3.md "Developer mode, part 1" and "Task export").
// Everything here shows only while `settings.agentDeveloperMode` is on.

// MARK: - Model step (raw request and response)

/// One model turn's developer section: "Turn 3 · model · 1,204 in · 86 out", then the Request and
/// Response rows, each opening the raw body in a sheet.
struct DevModelStepView: View {
    @ObservedObject var app: AppModel
    let session: BrowserAgentSession
    let taskID: String
    let info: AgentTurnInfo

    @State private var shown: DevBodySheet.Kind?

    private var sizes: (request: Int, response: Int)? {
        session.wireSizes[BrowserAgentSession.wireKey(taskID: taskID, turn: info.turn)]
    }

    static func turnLine(_ info: AgentTurnInfo) -> String {
        let input = info.usage.inputTokens.formatted()
        let output = info.usage.outputTokens.formatted()
        return String(
            localized: "Turn \(info.turn) · \(info.model) · \(input) in · \(output) out",
            comment: "Developer mode: one model turn, its model and token counts"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model step", comment: "Developer mode section title in an expanded tool row")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DCTheme.inkMuted)
                .textCase(.uppercase)
            if info.isFirstOfTurn {
                Text(verbatim: Self.turnLine(info))
                    .font(DCType.code)
                    .foregroundStyle(DCTheme.ink)
                    .accessibilityIdentifier("agentDevTurnLine")
            }
            if let sizes {
                bodyRow(String(localized: "Request", comment: "Developer mode row: the raw model request"),
                        bytes: sizes.request, kind: .request, id: "agentDevRequest")
                bodyRow(String(localized: "Response", comment: "Developer mode row: the raw model response"),
                        bytes: sizes.response, kind: .response, id: "agentDevResponse")
            }
        }
        .sheet(item: $shown) { kind in
            DevBodySheet(app: app, taskID: taskID, turn: info.turn, kind: kind)
        }
    }

    private func bodyRow(_ title: String, bytes: Int, kind: DevBodySheet.Kind, id: String) -> some View {
        Button {
            DCHaptics.tap()
            shown = kind
        } label: {
            HStack {
                Text(verbatim: title).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    .font(.caption).foregroundStyle(DCTheme.inkMuted).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DCTheme.ink)
        .accessibilityLabel("\(title), \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
        .accessibilityIdentifier(id)
    }
}

/// The final reply's turn (no tool call): a quiet Details button opening the same rows in a sheet.
struct DevDetailsButton: View {
    @ObservedObject var app: AppModel
    let session: BrowserAgentSession
    let taskID: String
    let info: AgentTurnInfo
    @State private var open = false

    var body: some View {
        Button {
            DCHaptics.tap()
            open = true
        } label: {
            Text("Details", comment: "Developer mode: opens the final reply's model step")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(DCTheme.inkMuted)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityIdentifier("agentDevDetails")
        .sheet(isPresented: $open) {
            NavigationStack {
                ScrollView {
                    DevModelStepView(app: app, session: session, taskID: taskID, info: info)
                        .padding(16)
                }
                .navigationTitle(Text("Details", comment: "Developer mode sheet title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { open = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// A page-changing tool's snapshots: both raw values and the rules that matched, in `code` style.
struct DevSnapshotsView: View {
    let report: PageFeedbackReport

    static func describe(_ snapshot: PageStateSnapshot) -> String {
        "url=\(snapshot.url) text=\(snapshot.textLength) height=\(snapshot.documentHeight) "
            + "scrollable=\(snapshot.isScrollable) links=\(snapshot.linkCount) "
            + "controls=\(snapshot.formControlCount) images=\(snapshot.visibleImageCount) "
            + "errors=\(snapshot.pageErrorCount)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Page snapshots", comment: "Developer mode section title in an expanded tool row")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DCTheme.inkMuted)
                .textCase(.uppercase)
            Text(verbatim: "before  " + Self.describe(report.before))
            Text(verbatim: "after   " + (report.after.map(Self.describe) ?? "unreadable"))
            Text(verbatim: "rules   " + (report.reasons.isEmpty ? "none matched" : report.reasons.joined(separator: ", ")))
        }
        .font(DCType.code)
        .foregroundStyle(DCTheme.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agentDevSnapshots")
    }
}

/// The M2 "View code" sheet pattern: selectable monospaced text, Copy and Share.
struct DevBodySheet: View {
    enum Kind: String, Identifiable { case request, response; var id: String { rawValue } }

    @ObservedObject var app: AppModel
    let taskID: String
    let turn: Int
    let kind: Kind
    @State private var text: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: text ?? "…")
                    .font(DCType.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .accessibilityIdentifier("agentDevBodyText")
            }
            .navigationTitle(kind == .request
                ? Text("Request", comment: "Developer mode sheet title") : Text("Response", comment: "Developer mode sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if let text {
                        Button { UIPasteboard.general.string = text; DCHaptics.success() } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: text)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            let events = await app.taskRecordStore.events(taskID: taskID)
            let bodies = TaskExport.rawBodies(turn: turn, in: events)
            text = (kind == .request ? bodies.request : bodies.response)
                ?? String(localized: "Nothing was recorded for this turn.", comment: "Developer mode: no raw body in the task record")
        }
    }
}

// MARK: - Console and Network (This page › Developer)

/// Monospaced, newest-first lists from the page's capture buffers, each with Copy.
struct DevPageLogSheet: View {
    enum Kind: String, Identifiable { case console, network; var id: String { rawValue } }

    @ObservedObject var app: AppModel
    let kind: Kind
    @State private var lines: [String] = []
    @Environment(\.dismiss) private var dismiss

    static func load(_ kind: Kind, from bridge: AgentPageDriving) async -> [String] {
        switch kind {
        case .console:
            return ((try? await bridge.consoleLog()) ?? []).map { "\($0.time) [\($0.level)] \($0.text)" }
        case .network:
            return ((try? await bridge.networkLog(urlFilter: nil, limit: 200, includeBodies: false)) ?? []).map {
                "\($0.method) \($0.status) \($0.url) · \($0.durationMs) ms · \($0.responseBytes) B"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if lines.isEmpty {
                        Text("Nothing captured on this page yet.", comment: "Developer mode: empty console or network list")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).font(DCType.code).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle(kind == .console
                ? Text("Console", comment: "Developer mode sheet title") : Text("Network", comment: "Developer mode sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { UIPasteboard.general.string = lines.joined(separator: "\n"); DCHaptics.success() } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(lines.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task { lines = await Self.load(kind, from: app.browser.agentBridge) }
    }
}

/// The two rows of This page's Developer group.
struct DevPageLogRows: View {
    @ObservedObject var app: AppModel
    @State private var counts: [DevPageLogSheet.Kind: Int] = [:]
    @State private var shown: DevPageLogSheet.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Developer", comment: "This page popover group title, developer mode only")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DCTheme.inkMuted)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
            row(.console, title: String(localized: "Console", comment: "This page developer row"),
                detail: counts[.console].map { String(localized: "\($0) lines", comment: "This page › Console row: number of captured console lines") },
                id: "thisPageConsole")
            row(.network, title: String(localized: "Network", comment: "This page developer row"),
                detail: counts[.network].map { String(localized: "\($0) requests", comment: "This page › Network row: number of captured requests") },
                id: "thisPageNetwork")
        }
        .task {
            for kind in [DevPageLogSheet.Kind.console, .network] {
                counts[kind] = await DevPageLogSheet.load(kind, from: app.browser.agentBridge).count
            }
        }
        .sheet(item: $shown) { DevPageLogSheet(app: app, kind: $0) }
    }

    private func row(_ kind: DevPageLogSheet.Kind, title: String, detail: String?, id: String) -> some View {
        Button { shown = kind } label: {
            HStack {
                Text(verbatim: title).font(.subheadline.weight(.medium)).foregroundStyle(DCTheme.ink)
                Spacer(minLength: 8)
                if let detail {
                    Text(verbatim: detail).font(.caption).foregroundStyle(DCTheme.inkMuted)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Export task

/// A task file waiting in the share sheet.
struct ExportedTaskFile: Identifiable { let url: URL; var id: URL { url } }

/// ⋯ › Export task and Audit log › task › Export: the alert, the export, the refusal message and
/// the share sheet. Set `taskID` to start.
struct TaskExportPrompt: ViewModifier {
    @ObservedObject var app: AppModel
    @Binding var taskID: String?
    @State private var file: ExportedTaskFile?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "Export this task?", comment: "Task export alert title"),
                isPresented: Binding(get: { taskID != nil }, set: { if !$0 { taskID = nil } })
            ) {
                Button(String(localized: "Export", comment: "Task export alert confirm")) {
                    guard let id = taskID else { return }
                    taskID = nil
                    Task { await run(id) }
                }
                Button(String(localized: "Cancel", comment: "Task export alert cancel"), role: .cancel) { taskID = nil }
            } message: {
                Text("The file includes the pages and results the Agent read. API keys and cookies are removed.",
                     comment: "Task export alert message")
            }
            .alert(
                String(localized: "Can't export this task", comment: "Task export failure title"),
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: failure ?? "")
            }
            .sheet(item: $file) { item in
                VStack(spacing: 16) {
                    Text("Task file ready", comment: "Task export share sheet title").font(.headline)
                    ShareLink(item: item.url) {
                        Label(item.url.lastPathComponent, systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(DCActionButtonStyle(prominent: true))
                    .accessibilityIdentifier("exportTaskShareLink")
                    Button("Done") { file = nil }
                }
                .padding(24)
                .presentationDetents([.height(240)])
            }
    }

    private func run(_ id: String) async {
        do {
            let url = try await TaskExport.export(
                taskID: id, store: app.taskRecordStore, cookieSource: WebKitTaskCookieSource(),
                secrets: app.browserAgentRuntimeConfig.redactedSecrets
            )
            file = ExportedTaskFile(url: url)
        } catch TaskExportError.cookiesRemain {
            failure = String(localized: "This task can't be exported without cookies in it.", comment: "Task export refused")
        } catch TaskExportError.notFound {
            failure = String(localized: "No record of this task was found.", comment: "Task export: record missing")
        } catch {
            failure = String(localized: "The task file could not be built.", comment: "Task export failed")
        }
    }
}

extension View {
    func taskExportPrompt(app: AppModel, taskID: Binding<String?>) -> some View {
        modifier(TaskExportPrompt(app: app, taskID: taskID))
    }
}
