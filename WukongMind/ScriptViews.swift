import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Toolbar Script Count Badge (M1 §3 + M2)

struct ToolbarScriptBadgeSummary: Equatable {
    var count: Int
    var errorCount: Int
    var isGlobalEnabled: Bool

    var isVisible: Bool { count > 0 }
}

extension AppModel {
    var currentBrowserScriptURL: URL? {
        guard !browser.showsForumsHome else { return nil }
        return browser.currentURL ?? pageContext.url
    }

    var toolbarScriptBadgeSummary: ToolbarScriptBadgeSummary {
        guard let url = currentBrowserScriptURL else {
            return ToolbarScriptBadgeSummary(count: 0, errorCount: 0, isGlobalEnabled: scriptStore.isGlobalEnabled)
        }
        let enabledMatching = scriptStore.scripts(matching: url, includeDisabled: false)
        let isGlobal = scriptStore.isGlobalEnabled
        let errors = isGlobal
            ? enabledMatching.filter { scriptStore.error(for: $0.id) != nil }.count
            : 0
        return ToolbarScriptBadgeSummary(
            count: enabledMatching.count,
            errorCount: errors,
            isGlobalEnabled: isGlobal
        )
    }

    var toolbarScriptAccessibilityDescription: String? {
        let summary = toolbarScriptBadgeSummary
        guard summary.isVisible else { return nil }
        if !summary.isGlobalEnabled {
            return String(localized: "Scripts off", comment: "Accessibility value of the browser toolbar Agent button when the global script switch is off")
        }
        if summary.errorCount > 0 {
            if summary.errorCount == 1 {
                return String(localized: "1 script has an error", comment: "Accessibility value of the browser toolbar Agent button when one script on this page failed")
            }
            return String(localized: "\(summary.errorCount) scripts have errors", comment: "Accessibility value of the browser toolbar Agent button when multiple scripts on this page failed")
        }
        return String(localized: "\(summary.count) scripts on this page", comment: "Browser agent context bar: number of saved scripts matching this page")
    }
}

/// Capsule count badge at the top-trailing corner of `PhoneAIButton` and
/// `SplitPanelToggle` (`design-m1.md` §3).
struct ScriptCountBadge: View {
    let summary: ToolbarScriptBadgeSummary
    @Environment(\.colorScheme) private var colorScheme

    private var fillColor: Color {
        if !summary.isGlobalEnabled {
            return Color(light: 0x6B7280, dark: 0xA1A8B3)
        }
        if summary.errorCount > 0 {
            return DCTheme.danger
        }
        return DCTheme.agentTint
    }

    private var textColor: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        if summary.isVisible {
            Text(verbatim: "\(summary.count)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(textColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .frame(minWidth: 16)
                .background(fillColor, in: Capsule())
                .background(
                    Capsule()
                        .fill(Color(uiColor: .systemBackground))
                        .padding(-2)
                )
                .padding(.top, 3)
                .padding(.trailing, 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Shared Formatting & Export Helpers

enum ScriptUIFormatting {
    static func injectionTimeLabel(_ time: ScriptInjectionTime) -> String {
        switch time {
        case .documentStart:
            String(localized: "Document start", comment: "Userscript injection timing: before the page finishes loading")
        case .documentEnd:
            String(localized: "Document end", comment: "Userscript injection timing: after the DOM has loaded")
        }
    }

    static func environmentPickerLabel(_ env: AgentExecutionEnvironment) -> String {
        switch env {
        case .isolated:
            String(localized: "Isolated", comment: "Userscript execution world option: isolated content world")
        case .page:
            String(localized: "Page", comment: "Userscript execution world option: page main world")
        }
    }

    static func environmentCardLabel(_ env: AgentExecutionEnvironment) -> String {
        switch env {
        case .isolated:
            String(localized: "isolated", comment: "Short lowercase label for the isolated script execution world in subtitles")
        case .page:
            String(localized: "page world", comment: "Short lowercase label for the page main world in script card subtitles")
        }
    }

    static func codeKindBadge(hasJS: Bool, hasCSS: Bool) -> String {
        switch (hasJS, hasCSS) {
        case (true, true):
            String(localized: "JS + CSS", comment: "Script card badge when a script contains both JavaScript and CSS")
        case (true, false):
            String(localized: "JS", comment: "Script card badge when a script contains JavaScript")
        case (false, true):
            String(localized: "CSS", comment: "Script card badge when a script contains CSS")
        case (false, false):
            String(localized: "Empty", comment: "Code row status when a script has zero lines of code in that language")
        }
    }

    static func cardMetadataLine(for script: UserScript) -> String {
        "\(injectionTimeLabel(script.injectionTime)) · \(environmentCardLabel(script.environment)) · \(codeKindBadge(hasJS: script.hasJS, hasCSS: script.hasCSS))"
    }

    static func lineCount(of code: String) -> Int {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        var lines = code.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return max(1, lines.count)
    }

    static func codePreview(of code: String) -> String? {
        let nonEmpty = code
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        return nonEmpty.prefix(2).joined(separator: "\n")
    }

    static func errorInlineSummary(_ error: ScriptRuntimeError) -> String {
        if let line = error.line, line > 0 {
            return String(localized: "Line \(line): \(error.message)", comment: "Userscript runtime error with a line number; first placeholder is line number, second is error message")
        }
        return error.message
    }

    static func relativeDate(_ date: Date, relativeTo now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(date)
        if abs(delta) < 5 {
            return String(localized: "just now", comment: "Relative timestamp when an action happened less than five seconds ago")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func validationMessage(for error: MatchPatternError) -> String {
        switch error {
        case .emptyPattern:
            String(localized: "Enter a @match rule, like https://*.example.org/*", comment: "Validation error when a @match rule text field is empty")
        case .missingSchemeSeparator:
            String(localized: "Add a scheme, like https:// or *://", comment: "Validation error when a @match rule is missing ://")
        case .invalidScheme:
            String(localized: "Use https://, http://, *://, file://, ws:// or wss://", comment: "Validation error when a @match rule uses an unsupported URL scheme")
        case .missingPathSlash, .invalidPath:
            String(localized: "Add a path starting with /, like /*", comment: "Validation error when a @match rule has no path starting with /")
        case .emptyHost, .invalidHost:
            String(localized: "Enter a valid host, like example.org or *.example.org", comment: "Validation error when a @match rule host is invalid")
        case .invalidPort:
            String(localized: "Use a port from 1 to 65535, or *", comment: "Validation error when a @match rule port is invalid")
        }
    }

    static func changedFieldsDescription(_ fields: [ScriptVersionChangedField]) -> String {
        guard !fields.isEmpty else {
            return String(localized: "No code changes", comment: "Version history subtitle when a version has identical fields to the prior snapshot")
        }
        let labels = fields.map { field in
            switch field {
            case .js:
                String(localized: "JavaScript", comment: "Code language label for JavaScript")
            case .css:
                String(localized: "CSS", comment: "Code language label for CSS")
            case .matchRules:
                String(localized: "Match rules", comment: "Version history changed field name: @match rules")
            case .name:
                String(localized: "Name", comment: "Version history changed field name: script name")
            case .settings:
                String(localized: "Run settings", comment: "Version history changed field name: injection time or execution world")
            }
        }
        return ListFormatter.localizedString(byJoining: labels)
    }

    static func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

/// Exports a `UserScript` as a temporary `<sanitized-name>.user.js` file with
/// `UTType.javaScript` so `ShareLink` works with Save to Files, AirDrop, etc.
struct UserScriptExportFile: Transferable {
    let filename: String
    let content: String

    init(script: UserScript) {
        self.filename = UserScript.sanitizedExportFilename(from: script.name)
        self.content = script.toUserScriptFileContent()
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .javaScript) { item in
            let exportDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("wukong-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            let fileURL = exportDir.appendingPathComponent(item.filename, isDirectory: false)
            try Data(item.content.utf8).write(to: fileURL, options: .atomic)
            return SentTransferredFile(fileURL)
        }
    }
}

// MARK: - Userscript Code Sheet ("View code" in M1 Script Card & M2 History)

struct ScriptCodeSheetView: View {
    let title: String
    let subtitle: String?
    let fileContent: String
    var onRestore: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    private var styledUserscript: AttributedString {
        var result = AttributedString(fileContent)
        if let endRange = fileContent.range(of: "// ==/UserScript==") {
            let headerPrefix = String(fileContent[..<endRange.upperBound])
            if let attrRange = result.range(of: headerPrefix) {
                result[attrRange].foregroundColor = .secondary
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(styledUserscript)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        DCTheme.raisedSurface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(DCTheme.border)
                    }
                    .padding(DCTheme.spacingL)
                    .accessibilityLabel(Text("Userscript code", comment: "Accessibility label for the full .user.js code block in View code"))
                    .accessibilityIdentifier("scriptViewCodeText")
            }
            .safeAreaInset(edge: .bottom) {
                if let onRestore {
                    VStack(spacing: 0) {
                        Button {
                            DCHaptics.tap()
                            onRestore()
                            dismiss()
                        } label: {
                            Label(
                                String(localized: "Restore this version", comment: "Version code sheet button to copy this historical version as the newest version"),
                                systemImage: "arrow.uturn.backward"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(DCPrimaryButtonStyle())
                        .accessibilityIdentifier("scriptSheetRestoreVersion")
                        .padding(.horizontal, DCTheme.spacingL)
                        .padding(.vertical, DCTheme.spacingM)
                    }
                    .dcStickyFooter()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Close", comment: "Closes the View code sheet")
                    }
                    .accessibilityIdentifier("scriptViewCodeClose")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        UIPasteboard.general.string = fileContent
                        DCHaptics.tap()
                        didCopy = true
                    } label: {
                        Label(
                            didCopy
                                ? String(localized: "Copied", comment: "Feedback label after copying code to clipboard")
                                : String(localized: "Copy", comment: "Button to copy code to clipboard"),
                            systemImage: didCopy ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .accessibilityIdentifier("scriptViewCodeCopy")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - M1 §2 Script Card (in BrowserAgentPanelView after `script_save`)

struct SavedScriptCardEntry: Identifiable, Equatable {
    var scriptID: String
    var fallbackName: String
    var fallbackFirstRule: String

    var id: String { scriptID }
}

struct AgentScriptCardView: View {
    @ObservedObject var app: AppModel
    let entry: SavedScriptCardEntry
    @State private var showingCodeSheet = false
    @State private var deletedSnapshot: UserScript?

    private var liveScript: UserScript? {
        app.scriptStore.script(id: entry.scriptID)
    }

    private var runtimeError: ScriptRuntimeError? {
        guard let liveScript, liveScript.isEnabled, app.scriptStore.isGlobalEnabled else {
            return nil
        }
        return app.scriptStore.error(for: liveScript.id)
    }

    var body: some View {
        Group {
            if let script = liveScript {
                activeCard(for: script)
            } else {
                deletedRow
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentScriptCard")
        .sheet(isPresented: $showingCodeSheet) {
            if let script = liveScript {
                ScriptCodeSheetView(
                    title: script.name,
                    subtitle: nil,
                    fileContent: script.toUserScriptFileContent()
                )
            }
        }
    }

    @ViewBuilder
    private func activeCard(for script: UserScript) -> some View {
        let error = runtimeError
        let isEffectivelyOn = script.isEnabled && app.scriptStore.isGlobalEnabled
        let cardTint: Color = {
            if error != nil { return DCTheme.danger }
            if !isEffectivelyOn { return .clear }
            return DCTheme.agentTint
        }()
        let iconTint: Color = {
            if error != nil { return DCTheme.danger }
            if !isEffectivelyOn { return .secondary }
            return DCTheme.agentTint
        }()

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconTint.opacity(0.14))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "curlybraces")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(iconTint)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(script.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2.weight(.semibold))
                                .accessibilityHidden(true)
                            Text(ScriptUIFormatting.errorInlineSummary(error))
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(DCTheme.danger)
                    } else if let firstRule = script.matchRules.first {
                        Text(verbatim: ruleSummary(for: script, firstRule: firstRule))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(ScriptUIFormatting.cardMetadataLine(for: script))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                statePill(isEffectivelyOn: isEffectivelyOn, hasError: error != nil)
            }

            HStack(spacing: 8) {
                Button {
                    DCHaptics.tap()
                    showingCodeSheet = true
                } label: {
                    Text("View code", comment: "Script card button that opens the saved .user.js source sheet")
                }
                .buttonStyle(DCActionButtonStyle(prominent: false))
                .accessibilityIdentifier("agentScriptViewCode")

                Button {
                    DCHaptics.tap()
                    let targetEnabled = !script.isEnabled
                    _ = try? app.scriptStore.setEnabled(
                        id: script.id,
                        isEnabled: targetEnabled,
                        runLiveJS: targetEnabled
                    )
                } label: {
                    if script.isEnabled {
                        Text("Disable", comment: "Script card button to turn off this saved userscript")
                    } else {
                        Text("Enable", comment: "Script card button to turn on this saved userscript")
                    }
                }
                .buttonStyle(DCActionButtonStyle(prominent: false))
                .accessibilityIdentifier("agentScriptToggleButton")

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    DCHaptics.tap()
                    deletedSnapshot = script
                    _ = app.scriptStore.deleteIfPresent(id: script.id)
                    ScriptUIFormatting.announce(
                        String(localized: "‘\(script.name)’ deleted", comment: "Toast and accessibility announcement when a userscript is deleted")
                    )
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DCTheme.danger)
                        .frame(minWidth: DCTheme.controlHeight, minHeight: DCTheme.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Delete script", comment: "Accessibility label for the trash button on a script card, or the destructive button in script detail"))
                .accessibilityIdentifier("agentScriptDeleteButton")
            }
        }
        .dcCard(tint: cardTint)
    }

    private var deletedRow: some View {
        let displayName = deletedSnapshot?.name ?? entry.fallbackName
        return HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("‘\(displayName)’ deleted", comment: "Toast and accessibility announcement when a userscript is deleted")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let snapshot = deletedSnapshot {
                Button {
                    DCHaptics.tap()
                    try? app.scriptStore.restore(snapshot)
                    deletedSnapshot = nil
                    ScriptUIFormatting.announce(
                        String(localized: "Restored ‘\(snapshot.name)’", comment: "Accessibility announcement after undoing script deletion")
                    )
                } label: {
                    Text("Undo", comment: "Undo button after deleting or restoring a userscript")
                }
                .buttonStyle(DCActionButtonStyle(prominent: false))
                .accessibilityIdentifier("agentScriptUndoDelete")
            }
        }
        .padding(.horizontal, DCTheme.spacingM)
        .padding(.vertical, DCTheme.spacingS)
        .frame(minHeight: DCTheme.controlHeight)
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(DCTheme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }

    private func ruleSummary(for script: UserScript, firstRule: String) -> String {
        let extra = script.matchRules.count - 1
        guard extra > 0 else { return firstRule }
        return "\(firstRule) · +\(extra) more"
    }

    @ViewBuilder
    private func statePill(isEffectivelyOn: Bool, hasError: Bool) -> some View {
        if hasError {
            DCPill(
                text: String(localized: "Error", comment: "State pill on a script card or detail view when the script threw an error"),
                systemImage: "exclamationmark.triangle.fill",
                tint: DCTheme.danger
            )
        } else if isEffectivelyOn {
            DCPill(
                text: String(localized: "On", comment: "State pill when a feature or script is enabled"),
                tint: DCTheme.success
            )
        } else {
            DCPill(
                text: String(localized: "Off", comment: "State pill when a feature or script is disabled"),
                tint: .secondary
            )
        }
    }
}

// MARK: - M2 §3 "Scripts on this page" Popover (`PageScriptsPopover`)

struct PageScriptsPopover: View {
    @ObservedObject var app: AppModel
    let pageURL: URL?
    @Binding var isPresented: Bool
    @State private var hasSwitchChanges = false
    @State private var turnedOffJSIDs: Set<String> = []

    private var matchingScripts: [UserScript] {
        guard let pageURL else { return [] }
        return app.scriptStore.sortedMatchingScripts(for: pageURL, includeDisabled: true)
    }

    private var isGlobalOn: Bool {
        app.scriptStore.isGlobalEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Scripts on this page", comment: "Popover header listing userscripts matching the current page")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                if let urlString = pageURL?.absoluteString, !urlString.isEmpty {
                    Text(verbatim: urlString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(Text(verbatim: urlString))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if !isGlobalOn {
                HStack(spacing: 10) {
                    Image(systemName: "nosign")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("All scripts are off. Nothing below runs.", comment: "Banner in Scripts on this page popover while the global script switch is off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        DCHaptics.tap()
                        app.settings.browserScriptsEnabled = true
                    } label: {
                        Text("Turn on", comment: "Button in Scripts on this page popover to turn the global script switch back on")
                    }
                    .buttonStyle(DCActionButtonStyle(prominent: true))
                    .accessibilityIdentifier("pageScriptsTurnOn")
                }
                .padding(10)
                .background(
                    DCTheme.raisedSurface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DCTheme.border)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matchingScripts.enumerated()), id: \.element.id) { index, script in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 14)
                        }
                        popoverScriptRow(script)
                    }
                }
            }
            .frame(maxHeight: 300)

            if hasSwitchChanges {
                Divider()
                Button {
                    DCHaptics.tap()
                    hasSwitchChanges = false
                    turnedOffJSIDs.removeAll()
                    app.browser.reload()
                    isPresented = false
                } label: {
                    Label(
                        String(localized: "Reload page", comment: "Button in Scripts on this page popover after flipping a script switch"),
                        systemImage: "arrow.clockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(DCActionButtonStyle(prominent: true))
                .accessibilityIdentifier("pageScriptsReload")
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            Divider()

            Button {
                DCHaptics.tap()
                openSettingsScripts(targetScriptID: nil)
            } label: {
                HStack {
                    Text("Manage scripts", comment: "Footer button in Scripts on this page popover opening Settings › Scripts")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(DCTheme.brandBlue)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pageScriptsManage")
        }
        .frame(width: 332)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pageScriptsPopover")
    }

    private func popoverScriptRow(_ script: UserScript) -> some View {
        let error = (script.isEnabled && isGlobalOn) ? app.scriptStore.error(for: script.id) : nil

        return HStack(spacing: 10) {
            Button {
                DCHaptics.tap()
                openSettingsScripts(targetScriptID: script.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(script.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    popoverSubtitleView(for: script, error: error)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(script.name))
            .accessibilityValue(Text(rowAccessibilityValue(for: script, error: error)))
            .accessibilityIdentifier("pageScriptRow-\(script.id)")

            Toggle(
                script.name,
                isOn: Binding(
                    get: { script.isEnabled },
                    set: { newValue in
                        DCHaptics.tap()
                        hasSwitchChanges = true
                        if !newValue && script.hasJS {
                            turnedOffJSIDs.insert(script.id)
                        } else if newValue {
                            turnedOffJSIDs.remove(script.id)
                        }
                        _ = try? app.scriptStore.setEnabled(
                            id: script.id,
                            isEnabled: newValue,
                            runLiveJS: newValue
                        )
                    }
                )
            )
            .labelsHidden()
            .tint(DCTheme.brandBlue)
            .disabled(!isGlobalOn)
            .frame(minWidth: 51, minHeight: 44)
            .accessibilityIdentifier("pageScriptToggle-\(script.id)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        .opacity(isGlobalOn ? 1 : 0.45)
    }

    @ViewBuilder
    private func popoverSubtitleView(for script: UserScript, error: ScriptRuntimeError?) -> some View {
        if let error {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Text("Error · \(ScriptUIFormatting.errorInlineSummary(error))", comment: "Error subtitle on a script row; placeholder is the formatted error message and optional line")
                    .font(.caption)
                    .lineLimit(2)
            }
            .foregroundStyle(DCTheme.danger)
        } else if !script.isEnabled && turnedOffJSIDs.contains(script.id) {
            Text("Turned off · reload to remove it fully", comment: "Subtitle in Scripts on this page popover after disabling a script whose JavaScript already ran on the page")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !script.isEnabled {
            Text("Off", comment: "State pill when a feature or script is disabled")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if script.isAllSitesRule && !script.hasJS && script.hasCSS {
            Text("All sites · CSS only", comment: "Popover subtitle for an all-sites stylesheet script")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let ranAt = app.scriptStore.lastExecutedAt[script.id] {
            Text("Ran \(ScriptUIFormatting.relativeDate(ranAt)) · \(ScriptUIFormatting.environmentCardLabel(script.environment))", comment: "Popover subtitle showing when the script last ran and in which execution world")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("\(ScriptUIFormatting.injectionTimeLabel(script.injectionTime)) · \(ScriptUIFormatting.environmentCardLabel(script.environment))", comment: "Popover subtitle showing injection timing and execution world")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rowAccessibilityValue(for script: UserScript, error: ScriptRuntimeError?) -> String {
        if let error {
            return String(localized: "Error: \(error.message)", comment: "Accessibility value on a script row when the script has a runtime error")
        }
        return script.isEnabled
            ? String(localized: "On", comment: "State pill when a feature or script is enabled")
            : String(localized: "Off", comment: "State pill when a feature or script is disabled")
    }

    private func openSettingsScripts(targetScriptID: String?) {
        isPresented = false
        Task { @MainActor in
            // Dismiss the popover before presenting the Settings sheet so UIKit
            // does not drop the sheet over an open popover (`design-m2.md`).
            try? await Task.sleep(for: .milliseconds(350))
            app.requestedScriptID = targetScriptID
            app.requestedSettingsPage = .scripts
        }
    }
}

// MARK: - M2 §1 Script Manager (`ScriptManagerView`, Settings › Scripts)

struct ScriptManagerView: View {
    @ObservedObject var app: AppModel
    @State private var pushedScriptID: String?
    @State private var deletedToastScript: UserScript?
    @State private var toastDismissTask: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var store: ScriptStore { app.scriptStore }
    private var isGlobalOn: Bool { app.settings.browserScriptsEnabled }
    private var groups: [ScriptStore.ManagerScriptGroup] { store.managerGroups }
    private var totalCount: Int { store.scripts.count }
    private var enabledCount: Int { store.scripts.filter(\.isEnabled).count }

    var body: some View {
        Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { app.settings.browserScriptsEnabled },
                        set: { newValue in
                            app.settings.browserScriptsEnabled = newValue
                            if newValue {
                                ScriptUIFormatting.announce(
                                    String(localized: "Scripts on", comment: "VoiceOver announcement when the global Run scripts switch is turned on")
                                )
                            } else {
                                ScriptUIFormatting.announce(
                                    String(localized: "Scripts are off. No script runs on any page until you turn this back on.", comment: "VoiceOver announcement when the global Run scripts switch is turned off")
                                )
                            }
                        }
                    )
                ) {
                    HStack(spacing: DCTheme.spacingM) {
                        SettingsIcon(
                            symbol: "curlybraces",
                            tint: isGlobalOn ? DCTheme.agentTint : Color(light: 0x6B7280, dark: 0x8E96A3)
                        )
                        Text("Run scripts", comment: "Settings › Scripts: master switch that enables or pauses all userscripts")
                    }
                }
                .accessibilityIdentifier("scriptsGlobalToggle")
            } footer: {
                if isGlobalOn {
                    Text("Turns every script off at once. \(totalCount) scripts, \(enabledCount) on.", comment: "Settings › Scripts global switch footer when enabled; first number is total scripts, second is enabled scripts")
                } else {
                    Label {
                        Text("Scripts are off. No script runs on any page until you turn this back on. Each script keeps its own switch.", comment: "Settings › Scripts footer status when the global switch is off")
                    } icon: {
                        Image(systemName: "nosign")
                    }
                }
            }

            if groups.isEmpty {
                Section {
                    emptyStateCard
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    Section {
                        ForEach(group.scripts) { script in
                            managerRow(for: script)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteScriptWithUndo(script)
                                    } label: {
                                        Label(
                                            String(localized: "Delete", comment: "Swipe and context menu action to delete a userscript"),
                                            systemImage: "trash"
                                        )
                                    }
                                }
                                .contextMenu {
                                    ShareLink(
                                        item: UserScriptExportFile(script: script),
                                        preview: SharePreview(UserScript.sanitizedExportFilename(from: script.name))
                                    ) {
                                        Label(
                                            String(localized: "Export", comment: "Context menu action to export a .user.js file"),
                                            systemImage: "square.and.arrow.up"
                                        )
                                    }
                                    Button(role: .destructive) {
                                        deleteScriptWithUndo(script)
                                    } label: {
                                        Label(
                                            String(localized: "Delete", comment: "Swipe and context menu action to delete a userscript"),
                                            systemImage: "trash"
                                        )
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            if let host = group.host {
                                Text(verbatim: host)
                            } else {
                                Text("All sites", comment: "Script manager group header for scripts that run on all sites")
                            }
                            Spacer()
                            Text(verbatim: "\(group.scripts.count)")
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("scriptGroup-\(group.identifierHost)")
                    } footer: {
                        if index == groups.count - 1 {
                            Text("Tap a script to edit it, see its versions or export it. Swipe left to delete.", comment: "Footer below the last script group in Settings › Scripts")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("scriptManager")
        .navigationDestination(item: $pushedScriptID) { scriptID in
            ScriptDetailView(
                app: app,
                scriptID: scriptID,
                onDeleted: { deleted in
                    presentUndoToast(for: deleted)
                }
            )
        }
        .overlay(alignment: .bottom) {
            if let deleted = deletedToastScript {
                ScriptToastBanner(
                    symbol: "trash",
                    message: String(localized: "‘\(deleted.name)’ deleted", comment: "Toast and accessibility announcement when a userscript is deleted"),
                    undoAction: {
                        undoDelete(deleted)
                    },
                    dismissAction: {
                        dismissUndoToast()
                    }
                )
                .accessibilityIdentifier("scriptUndoToast")
                .padding(.horizontal, DCTheme.spacingL)
                .padding(.bottom, DCTheme.spacingM)
                .transition(reduceMotion ? .opacity : DCMotion.slide(.bottom, reduceMotion: false))
            }
        }
        .animation(DCMotion.respecting(reduceMotion, DCMotion.spring), value: deletedToastScript?.id)
        .onAppear {
            consumeRequestedScriptIDIfNeeded()
        }
        .onChange(of: app.requestedScriptID) { _, _ in
            consumeRequestedScriptIDIfNeeded()
        }
    }

    private func consumeRequestedScriptIDIfNeeded() {
        guard let targetID = app.requestedScriptID else { return }
        app.requestedScriptID = nil
        if store.script(id: targetID) != nil {
            pushedScriptID = targetID
        }
    }

    @ViewBuilder
    private func managerRow(for script: UserScript) -> some View {
        let error = store.error(for: script.id)
        let openDetail = {
            DCHaptics.tap()
            pushedScriptID = script.id
        }
        let toggleView = Toggle(
            script.name,
            isOn: Binding(
                get: { script.isEnabled },
                set: { newValue in
                    DCHaptics.tap()
                    _ = try? store.setEnabled(id: script.id, isEnabled: newValue, runLiveJS: newValue)
                }
            )
        )
        .labelsHidden()
        .tint(DCTheme.brandBlue)
        .disabled(!isGlobalOn)
        .opacity(isGlobalOn ? 1 : 0.45)
        .accessibilityIdentifier("scriptToggle-\(script.id)")

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DCTheme.spacingXS) {
                Button(action: openDetail) {
                    managerRowTextStack(for: script, error: error)
                        .opacity(isGlobalOn ? 1 : 0.45)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(script.name))
                .accessibilityValue(Text(managerRowAccessibilityValue(for: script, error: error)))
                .accessibilityIdentifier("scriptRow-\(script.id)")

                HStack {
                    toggleView
                    Spacer()
                }
            }
        } else {
            HStack(spacing: 10) {
                Button(action: openDetail) {
                    managerRowTextStack(for: script, error: error)
                        .opacity(isGlobalOn ? 1 : 0.45)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(script.name))
                .accessibilityValue(Text(managerRowAccessibilityValue(for: script, error: error)))
                .accessibilityIdentifier("scriptRow-\(script.id)")

                toggleView

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func managerRowTextStack(for script: UserScript, error: ScriptRuntimeError?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(script.name)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                    Text("Error · \(ScriptUIFormatting.errorInlineSummary(error))", comment: "Error subtitle on a script row; placeholder is the formatted error message and optional line")
                        .font(.caption)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
                .foregroundStyle(DCTheme.danger)
            } else if let firstRule = script.matchRules.first {
                let extra = script.matchRules.count - 1
                let subtitle = extra > 0
                    ? String(localized: "\(firstRule) · +\(extra) more", comment: "Script row subtitle showing the first @match rule and how many additional rules exist")
                    : firstRule
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func managerRowAccessibilityValue(for script: UserScript, error: ScriptRuntimeError?) -> String {
        if let error {
            return String(localized: "Error: \(error.message)", comment: "Accessibility value on a script row when the script has a runtime error")
        }
        return script.isEnabled
            ? String(localized: "On", comment: "State pill when a feature or script is enabled")
            : String(localized: "Off", comment: "State pill when a feature or script is disabled")
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DCTheme.agentTint.opacity(0.14))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "curlybraces")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(DCTheme.agentTint)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("No scripts yet", comment: "Empty state title in Settings › Scripts when zero scripts are saved")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Text("Scripts are small page changes the agent saves so they run automatically whenever you visit a site.", comment: "Empty state explanation in Settings › Scripts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                numberedStepRow(
                    number: 1,
                    text: String(localized: "Open any page and tap the Agent button in the toolbar.", comment: "Settings › Scripts empty state step 1")
                )
                numberedStepRow(
                    number: 2,
                    text: String(localized: "Ask for a change and say “always” or “from now on”.", comment: "Settings › Scripts empty state step 2")
                )
                numberedStepRow(
                    number: 3,
                    text: String(localized: "Edit rules, inspect versions or export .user.js files here.", comment: "Settings › Scripts empty state step 3")
                )
            }
        }
        .dcCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scriptsEmptyState")
    }

    private func numberedStepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(DCTheme.agentTint.opacity(0.14))
                .frame(width: 24, height: 24)
                .overlay {
                    Text(verbatim: "\(number)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(DCTheme.agentTint)
                }
                .accessibilityHidden(true)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deleteScriptWithUndo(_ script: UserScript) {
        DCHaptics.tap()
        guard let removed = store.deleteIfPresent(id: script.id) else { return }
        presentUndoToast(for: removed)
    }

    private func presentUndoToast(for deleted: UserScript) {
        toastDismissTask?.cancel()
        deletedToastScript = deleted
        ScriptUIFormatting.announce(
            String(localized: "‘\(deleted.name)’ deleted", comment: "Toast and accessibility announcement when a userscript is deleted")
        )
        guard !UIAccessibility.isVoiceOverRunning else { return }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if deletedToastScript?.id == deleted.id {
                deletedToastScript = nil
            }
        }
    }

    private func undoDelete(_ script: UserScript) {
        DCHaptics.tap()
        toastDismissTask?.cancel()
        try? store.restore(script)
        deletedToastScript = nil
        ScriptUIFormatting.announce(
            String(localized: "Restored ‘\(script.name)’", comment: "Accessibility announcement after undoing script deletion")
        )
    }

    private func dismissUndoToast() {
        toastDismissTask?.cancel()
        deletedToastScript = nil
    }
}

// MARK: - Shared Undo Toast Banner

struct ScriptToastBanner: View {
    let symbol: String
    let message: String
    let undoAction: () -> Void
    let dismissAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button {
                undoAction()
            } label: {
                Text("Undo", comment: "Undo button after deleting or restoring a userscript")
            }
            .buttonStyle(DCActionButtonStyle(prominent: true))
            .accessibilityIdentifier("scriptToastUndoButton")

            if UIAccessibility.isVoiceOverRunning {
                Button {
                    dismissAction()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss", comment: "Dismisses a status banner or toast"))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(minHeight: 52)
        .frame(maxWidth: 520)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DCTheme.border)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - M2 §2 Script Detail (`ScriptDetailView`)

struct EditableMatchRule: Identifiable, Equatable {
    var id = UUID()
    var pattern: String
}

struct ScriptDetailDraft: Equatable {
    var baselineVersion: Int
    var name: String
    var ruleItems: [EditableMatchRule]
    var injectionTime: ScriptInjectionTime
    var environment: AgentExecutionEnvironment
    var js: String
    var css: String

    init(script: UserScript) {
        self.baselineVersion = script.version
        self.name = script.name
        self.ruleItems = script.matchRules.map { EditableMatchRule(pattern: $0) }
        self.injectionTime = script.injectionTime
        self.environment = script.environment
        self.js = script.js
        self.css = script.css
    }

    func isDirty(comparedTo script: UserScript) -> Bool {
        name != script.name
            || ruleItems.map(\.pattern) != script.matchRules
            || injectionTime != script.injectionTime
            || environment != script.environment
            || js != script.js
            || css != script.css
    }

    var nameValidationError: String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "Add a name", comment: "Inline validation error when the script name field is empty")
            : nil
    }

    var emptyRulesValidationError: String? {
        ruleItems.isEmpty
            ? String(localized: "Add at least one rule", comment: "Inline validation error when all @match rules have been removed")
            : nil
    }

    func ruleValidationError(at index: Int) -> String? {
        guard ruleItems.indices.contains(index),
              let err = MatchPattern.validationError(ruleItems[index].pattern) else {
            return nil
        }
        return ScriptUIFormatting.validationMessage(for: err)
    }

    var emptyBodyValidationError: String? {
        let jsEmpty = js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let cssEmpty = css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (jsEmpty && cssEmpty)
            ? String(localized: "Add JavaScript or CSS", comment: "Inline validation error when both JavaScript and CSS editors are empty")
            : nil
    }

    var isValid: Bool {
        guard nameValidationError == nil,
              emptyRulesValidationError == nil,
              emptyBodyValidationError == nil else {
            return false
        }
        for idx in ruleItems.indices where ruleValidationError(at: idx) != nil {
            return false
        }
        return true
    }

    func makePatch() -> ScriptUpdatePatch {
        ScriptUpdatePatch(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            matchRules: ruleItems.map { $0.pattern.trimmingCharacters(in: .whitespacesAndNewlines) },
            js: js,
            css: css,
            injectionTime: injectionTime,
            environment: environment
        )
    }
}

struct ScriptDetailView: View {
    @ObservedObject var app: AppModel
    let scriptID: String
    var onDeleted: (UserScript) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScriptDetailDraft?
    @State private var showsDiscardConfirmation = false
    @State private var didCopyError = false
    @State private var announcedErrorSignature: String?
    #if DEBUG
    @State private var debugSubpage: String?
    #endif

    private var store: ScriptStore { app.scriptStore }
    private var script: UserScript? { store.script(id: scriptID) }

    var body: some View {
        Group {
            if let script {
                detailForm(for: script)
            } else {
                ContentUnavailableView(
                    String(localized: "Script not found", comment: "Fallback view when a script was deleted while viewing its detail"),
                    systemImage: "curlybraces"
                )
            }
        }
        .navigationTitle(Text("Script", comment: "Navigation bar title of the single userscript detail screen"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if draft == nil, let script {
                draft = ScriptDetailDraft(script: script)
            }
            #if DEBUG
            if debugSubpage == nil, let requested = AssistantDebug.value("-dc-scripts-detail-subpage"), let script {
                if requested == "dirty" {
                    var dirtyDraft = ScriptDetailDraft(script: script)
                    dirtyDraft.name = script.name + " (edited)"
                    draft = dirtyDraft
                } else {
                    debugSubpage = requested
                }
            }
            #endif
        }
        #if DEBUG
        .navigationDestination(item: $debugSubpage) { subpage in
            if let script {
                if subpage == "js" {
                    ScriptCodeEditor(
                        kind: .javascript,
                        code: draftBinding(for: script, \.js),
                        savedCode: script.js
                    )
                } else if subpage == "css" {
                    ScriptCodeEditor(
                        kind: .css,
                        code: draftBinding(for: script, \.css),
                        savedCode: script.css
                    )
                } else if subpage == "history" {
                    ScriptHistoryView(app: app, scriptID: script.id)
                }
            }
        }
        #endif
        .onChange(of: script?.version) { _, newVersion in
            guard let script, let newVersion, let currentDraft = draft else { return }
            // Keep draft aligned when Version history restores a snapshot.
            if newVersion != currentDraft.baselineVersion {
                draft = ScriptDetailDraft(script: script)
            }
        }
    }

    @ViewBuilder
    private func detailForm(for script: UserScript) -> some View {
        let activeDraft = draft ?? ScriptDetailDraft(script: script)
        let dirty = activeDraft.isDirty(comparedTo: script)
        let canSave = dirty && activeDraft.isValid
        let runtimeError = store.error(for: script.id)
        let isEffectivelyOn = script.isEnabled && store.isGlobalEnabled

        Form {
            // 1. Plain header
            Section {
                headerView(
                    script: script,
                    draft: activeDraft,
                    dirty: dirty,
                    isEffectivelyOn: isEffectivelyOn,
                    hasError: runtimeError != nil
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
                .listRowBackground(Color.clear)
            }

            // 2. Error card (when lastError exists)
            if let runtimeError {
                Section {
                    errorCard(for: runtimeError)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }

            // 3. Name
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(
                        String(localized: "Script name", comment: "Placeholder in Script detail name field"),
                        text: draftBinding(for: script, \.name)
                    )
                    .accessibilityIdentifier("scriptNameField")
                    .accessibilityValue(
                        activeDraft.nameValidationError != nil
                            ? Text("Invalid", comment: "Accessibility value on an invalid form field")
                            : Text(verbatim: "")
                    )
                    .accessibilityHint(Text(activeDraft.nameValidationError ?? ""))

                    if let nameErr = activeDraft.nameValidationError {
                        inlineValidationLabel(nameErr)
                    }
                }
            } header: {
                Text("Name", comment: "Section header for the script's name field")
            }

            // 4. Runs on (@match rules)
            Section {
                ForEach(Array(activeDraft.ruleItems.enumerated()), id: \.element.id) { index, item in
                    let ruleErr = activeDraft.ruleValidationError(at: index)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(
                            "https://*.example.org/*",
                            text: Binding(
                                get: {
                                    let current = draft ?? ScriptDetailDraft(script: script)
                                    guard current.ruleItems.indices.contains(index) else { return item.pattern }
                                    return current.ruleItems[index].pattern
                                },
                                set: { newValue in
                                    var updated = draft ?? ScriptDetailDraft(script: script)
                                    if updated.ruleItems.indices.contains(index) {
                                        updated.ruleItems[index].pattern = newValue
                                        draft = updated
                                    }
                                }
                            )
                        )
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("scriptMatchRule-\(index)")
                        .accessibilityValue(
                            ruleErr != nil
                                ? Text("Invalid", comment: "Accessibility value on an invalid form field")
                                : Text(verbatim: "")
                        )
                        .accessibilityHint(Text(ruleErr ?? ""))

                        if let ruleErr {
                            inlineValidationLabel(ruleErr)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            var updated = draft ?? ScriptDetailDraft(script: script)
                            if updated.ruleItems.indices.contains(index) {
                                updated.ruleItems.remove(at: index)
                                draft = updated
                            }
                        } label: {
                            Label(
                                String(localized: "Delete", comment: "Swipe and context menu action to delete a userscript"),
                                systemImage: "trash"
                            )
                        }
                    }
                }

                if let emptyRulesErr = activeDraft.emptyRulesValidationError {
                    inlineValidationLabel(emptyRulesErr)
                }

                Button {
                    DCHaptics.tap()
                    var updated = draft ?? ScriptDetailDraft(script: script)
                    updated.ruleItems.append(EditableMatchRule(pattern: "https://"))
                    draft = updated
                } label: {
                    Label(
                        String(localized: "Add rule", comment: "Button in Script detail Runs on section to add another @match rule"),
                        systemImage: "plus"
                    )
                }
                .accessibilityIdentifier("scriptAddRule")
            } header: {
                HStack {
                    Text("Runs on", comment: "Section header in Script detail for @match URL patterns")
                    Spacer()
                    Text("\(activeDraft.ruleItems.count) rules", comment: "Trailing count in the Runs on section header of Script detail")
                        .monospacedDigit()
                }
            } footer: {
                Text(
                    verbatim: String(
                        localized: "Tampermonkey @match rules, like https://*.example.org/*.",
                        comment: "Footer explaining @match URL rule syntax in Script detail"
                    )
                )
            }

            // 5. How it runs
            Section {
                Toggle(
                    String(localized: "Enabled", comment: "Per-script enabled toggle in Script detail"),
                    isOn: Binding(
                        get: { script.isEnabled },
                        set: { newValue in
                            DCHaptics.tap()
                            _ = try? store.setEnabled(
                                id: script.id,
                                isEnabled: newValue,
                                runLiveJS: newValue
                            )
                        }
                    )
                )
                .accessibilityIdentifier("scriptEnabledToggle")

                Picker(
                    String(localized: "Runs at", comment: "Picker label in Script detail choosing when the script injects"),
                    selection: draftBinding(for: script, \.injectionTime)
                ) {
                    ForEach(ScriptInjectionTime.allCases, id: \.self) { timing in
                        Text(ScriptUIFormatting.injectionTimeLabel(timing)).tag(timing)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("scriptInjectionTime")

                Picker(
                    String(localized: "Environment", comment: "Picker label in Script detail choosing Isolated or Page execution world"),
                    selection: draftBinding(for: script, \.environment)
                ) {
                    Text(ScriptUIFormatting.environmentPickerLabel(.isolated))
                        .tag(AgentExecutionEnvironment.isolated)
                    Text(ScriptUIFormatting.environmentPickerLabel(.page))
                        .tag(AgentExecutionEnvironment.page)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("scriptEnvironment")
            } header: {
                Text("How it runs", comment: "Section header in Script detail for enabled state, timing and world")
            } footer: {
                Text("Isolated works on every site and is hidden from the page, but can’t see the page’s own JavaScript. Page can, but strict sites may block eval and requests to other sites.", comment: "Footer in Script detail explaining Isolated vs Page execution worlds")
            }

            // 6. Code
            Section {
                NavigationLink {
                    ScriptCodeEditor(
                        kind: .javascript,
                        code: draftBinding(for: script, \.js),
                        savedCode: script.js
                    )
                } label: {
                    codeSummaryRow(
                        title: String(localized: "JavaScript", comment: "Code language label for JavaScript"),
                        code: activeDraft.js,
                        isEdited: activeDraft.js != script.js
                    )
                }
                .accessibilityIdentifier("scriptJSRow")

                NavigationLink {
                    ScriptCodeEditor(
                        kind: .css,
                        code: draftBinding(for: script, \.css),
                        savedCode: script.css
                    )
                } label: {
                    codeSummaryRow(
                        title: String(localized: "CSS", comment: "Code language label for CSS"),
                        code: activeDraft.css,
                        isEdited: activeDraft.css != script.css
                    )
                }
                .accessibilityIdentifier("scriptCSSRow")

                if let bodyErr = activeDraft.emptyBodyValidationError {
                    inlineValidationLabel(bodyErr)
                }
            } header: {
                Text("Code", comment: "Section header in Script detail for JavaScript and CSS editors")
            }

            // 7. Source
            Section {
                sourceRow(for: script)
            } header: {
                Text("Source", comment: "Section header in Script detail showing how the script was created")
            }

            // 8. History & Export
            Section {
                NavigationLink {
                    ScriptHistoryView(app: app, scriptID: script.id)
                } label: {
                    let totalVersions = script.versions.count + 1
                    LabeledContent {
                        Text("\(totalVersions) versions", comment: "Trailing count on the Version history row in Script detail")
                            .monospacedDigit()
                    } label: {
                        Text("Version history", comment: "Row and screen title for a script's version history")
                    }
                }
                .accessibilityIdentifier("scriptHistoryRow")

                ShareLink(
                    item: UserScriptExportFile(script: script),
                    preview: SharePreview(UserScript.sanitizedExportFilename(from: script.name))
                ) {
                    Label(
                        String(localized: "Export .user.js file", comment: "Button in Script detail to share or save the script as a .user.js file"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .accessibilityIdentifier("scriptExport")
            }

            // 9. Delete
            Section {
                Button(role: .destructive) {
                    DCHaptics.tap()
                    if let removed = store.deleteIfPresent(id: script.id) {
                        onDeleted(removed)
                    }
                    dismiss()
                } label: {
                    Text("Delete script", comment: "Accessibility label for the trash button on a script card, or the destructive button in script detail")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .accessibilityIdentifier("scriptDelete")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("scriptDetail")
        .navigationBarBackButtonHidden(dirty)
        .toolbar {
            if dirty {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showsDiscardConfirmation = true
                    } label: {
                        Text("Cancel", comment: "Cancel button when editing a script draft")
                    }
                    .accessibilityIdentifier("scriptCancelButton")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saveChanges(for: script)
                } label: {
                    Text("Save", comment: "Save button in Script detail toolbar")
                }
                .disabled(!canSave)
                .accessibilityIdentifier("scriptSaveButton")
            }
        }
        .confirmationDialog(
            String(localized: "Discard changes?", comment: "Confirmation dialog title when cancelling unsaved edits in Script detail"),
            isPresented: $showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                draft = ScriptDetailDraft(script: script)
                dismiss()
            } label: {
                Text("Discard changes", comment: "Destructive confirmation action to discard unsaved script edits")
            }
            Button(role: .cancel) {} label: {
                Text("Keep editing", comment: "Cancel action in Discard changes dialog")
            }
        }
        .onAppear {
            if let runtimeError {
                announceErrorIfNeeded(runtimeError)
            }
        }
        .onChange(of: runtimeError) { _, newErr in
            if let newErr {
                announceErrorIfNeeded(newErr)
            }
        }
    }

    private func draftBinding<Value>(
        for script: UserScript,
        _ keyPath: WritableKeyPath<ScriptDetailDraft, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                (draft ?? ScriptDetailDraft(script: script))[keyPath: keyPath]
            },
            set: { newValue in
                var updated = draft ?? ScriptDetailDraft(script: script)
                updated[keyPath: keyPath] = newValue
                draft = updated
            }
        )
    }

    private func saveChanges(for script: UserScript) {
        guard let currentDraft = draft, currentDraft.isValid else { return }
        DCHaptics.tap()
        let patch = currentDraft.makePatch()
        let shouldRunJS = (currentDraft.js != script.js)
            || (currentDraft.environment != script.environment)
            || (currentDraft.ruleItems.map(\.pattern) != script.matchRules)
        if let updated = try? store.update(
            id: script.id,
            patch: patch,
            origin: .editedByUser
        ) {
            draft = ScriptDetailDraft(script: updated)
            Task { @MainActor in
                if updated.isEnabled {
                    _ = await app.scriptWebController.applyLiveScript(
                        updated,
                        runJS: updated.hasJS && shouldRunJS
                    )
                } else {
                    await app.scriptWebController.removeLiveScript(id: updated.id)
                }
            }
        }
    }

    private func announceErrorIfNeeded(_ error: ScriptRuntimeError) {
        let sig = "\(error.scriptID)-\(error.count)-\(error.message)"
        guard announcedErrorSignature != sig else { return }
        announcedErrorSignature = sig
        ScriptUIFormatting.announce(
            String(localized: "Script error: \(error.message)", comment: "VoiceOver announcement when opening Script detail with a runtime error")
        )
    }

    private func headerView(
        script: UserScript,
        draft: ScriptDetailDraft,
        dirty: Bool,
        isEffectivelyOn: Bool,
        hasError: Bool
    ) -> some View {
        let displayName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? script.name
            : draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let iconTint: Color = {
            if hasError { return DCTheme.danger }
            if !isEffectivelyOn { return .secondary }
            return DCTheme.agentTint
        }()
        let stateLabel: String = {
            if hasError {
                return String(localized: "error", comment: "Lowercase state word in Script detail combined header accessibility label")
            }
            return isEffectivelyOn
                ? String(localized: "on", comment: "Lowercase state word in Script detail combined header accessibility label")
                : String(localized: "off", comment: "Lowercase state word in Script detail combined header accessibility label")
        }()

        return HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(iconTint.opacity(0.14))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "curlybraces")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(iconTint)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if dirty {
                    Text("Version \(script.version) · unsaved changes", comment: "Script detail header subtitle while draft has unsaved changes")
                        .font(.caption)
                        .foregroundStyle(DCTheme.warning)
                } else {
                    Text("Version \(script.version) · edited \(ScriptUIFormatting.relativeDate(script.updatedAt))", comment: "Script detail header subtitle showing current version number and relative edit time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if hasError {
                DCPill(
                    text: String(localized: "Error", comment: "State pill on a script card or detail view when the script threw an error"),
                    systemImage: "exclamationmark.triangle.fill",
                    tint: DCTheme.danger
                )
            } else if isEffectivelyOn {
                DCPill(
                    text: String(localized: "On", comment: "State pill when a feature or script is enabled"),
                    tint: DCTheme.success
                )
            } else {
                DCPill(
                    text: String(localized: "Off", comment: "State pill when a feature or script is disabled"),
                    tint: .secondary
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("\(displayName), \(stateLabel), version \(script.version)", comment: "Combined accessibility label for the Script detail header: script name, state (on/off/error), and version")
        )
        .accessibilityAddTraits(.isHeader)
    }

    private func errorCard(for error: ScriptRuntimeError) -> some View {
        let formattedCode = ScriptUIFormatting.errorInlineSummary(error)
        let metadataParts: [String] = {
            var parts: [String] = []
            if let url = error.url, !url.isEmpty {
                parts.append(BrowserAddress.display(URL(string: url)))
            }
            parts.append(ScriptUIFormatting.relativeDate(error.occurredAt))
            parts.append(
                String(localized: "\(error.count) times", comment: "Number of times a userscript runtime error occurred")
            )
            return parts
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DCTheme.danger)
                    .accessibilityHidden(true)
                Text("It failed on the last page it ran on", comment: "Title of the runtime error card in Script detail")
                    .font(.subheadline.weight(.semibold))
            }

            Text(verbatim: formattedCode)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    DCTheme.raisedSurface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DCTheme.border)
                }

            Text(verbatim: metadataParts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    var copyLines = [formattedCode]
                    if let url = error.url, !url.isEmpty {
                        copyLines.append(url)
                    }
                    UIPasteboard.general.string = copyLines.joined(separator: "\n")
                    DCHaptics.tap()
                    didCopyError = true
                } label: {
                    Label(
                        didCopyError
                            ? String(localized: "Copied", comment: "Feedback label after copying code to clipboard")
                            : String(localized: "Copy error", comment: "Button in Script detail error card to copy the runtime error message"),
                        systemImage: didCopyError ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(DCActionButtonStyle(prominent: false))
                .accessibilityIdentifier("scriptCopyError")

                Button {} label: {
                    Label(
                        String(localized: "Let the agent fix", comment: "Disabled M2 button in Script detail error card for future agent auto-fix"),
                        systemImage: "sparkles"
                    )
                }
                .buttonStyle(DCActionButtonStyle(prominent: false))
                .disabled(true)
                .opacity(0.45)
                .accessibilityHint(Text("Coming in a later update", comment: "Accessibility hint on the disabled Let the agent fix button"))
                .accessibilityIdentifier("scriptFixWithAgent")
            }

            Text("The agent fix comes in a later update", comment: "Note beneath the disabled Let the agent fix button in Script detail")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .dcCard(tint: DCTheme.danger)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scriptErrorCard")
    }

    private func codeSummaryRow(title: String, code: String, isEdited: Bool) -> some View {
        let lines = ScriptUIFormatting.lineCount(of: code)
        let trailingValue: String = {
            if lines == 0 {
                return isEdited
                    ? String(localized: "Empty · edited", comment: "Code row trailing label when cleared in the draft")
                    : String(localized: "Empty", comment: "Code row status when a script has zero lines of code in that language")
            }
            if isEdited {
                return String(localized: "\(lines) lines · edited", comment: "Code row trailing label showing line count and unsaved edits")
            }
            return String(localized: "\(lines) lines", comment: "Code row trailing label showing line count")
        }()

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(trailingValue)
                    .font(.subheadline)
                    .foregroundStyle(isEdited ? DCTheme.warning : .secondary)
                    .monospacedDigit()
            }
            if let preview = ScriptUIFormatting.codePreview(of: code) {
                Text(verbatim: preview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func sourceRow(for script: UserScript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch script.source {
            case .agent(let userPrompt):
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DCTheme.agentTint)
                        .accessibilityHidden(true)
                    Text("Made by the agent · \(ScriptUIFormatting.shortDate(script.createdAt))", comment: "Source row in Script detail when created by the browser agent; placeholder is creation date")
                        .font(.subheadline)
                }
                let trimmedPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPrompt.isEmpty {
                    Text("“\(trimmedPrompt)”", comment: "Quoted user prompt that produced the script in Script detail and Version history")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .imported:
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DCTheme.agentTint)
                        .accessibilityHidden(true)
                    Text("Imported · \(ScriptUIFormatting.shortDate(script.createdAt))", comment: "Source row in Script detail when imported from a .user.js file")
                        .font(.subheadline)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scriptSource")
    }

    private func inlineValidationLabel(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DCTheme.danger)
    }
}

// MARK: - M2 §2 Code Editor (`ScriptCodeEditor`, pushed from ScriptDetailView)

struct ScriptCodeEditor: View {
    enum Kind {
        case javascript
        case css

        var title: String {
            switch self {
            case .javascript:
                String(localized: "JavaScript", comment: "Code language label for JavaScript")
            case .css:
                String(localized: "CSS", comment: "Code language label for CSS")
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .javascript:
                String(localized: "JavaScript code", comment: "Accessibility label for the JavaScript code editor field")
            case .css:
                String(localized: "CSS code", comment: "Accessibility label for the CSS code editor field")
            }
        }
    }

    let kind: Kind
    @Binding var code: String
    let savedCode: String
    @State private var didCopy = false

    private var isEdited: Bool { code != savedCode }

    var body: some View {
        VStack(spacing: 0) {
            if isEdited {
                HStack(spacing: 6) {
                    Circle()
                        .fill(DCTheme.warning)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text("Edited · not saved yet. Go back and tap Save.", comment: "Status banner at the top of the JavaScript/CSS code editor when edits are unsaved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(DCTheme.raisedSurface)
                Divider()
            }

            PlainCodeTextView(
                text: $code,
                accessibilityLabel: kind.accessibilityLabel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    UIPasteboard.general.string = code
                    DCHaptics.tap()
                    didCopy = true
                } label: {
                    Label(
                        didCopy
                            ? String(localized: "Copied", comment: "Feedback label after copying code to clipboard")
                            : String(localized: "Copy", comment: "Button to copy code to clipboard"),
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .accessibilityIdentifier("scriptEditorCopyButton")
            }
        }
    }
}

/// `UITextView` wrapper disabling smart quotes, smart dashes, smart insert/delete,
/// autocorrection and autocapitalization (`design-m2.md` §2), with a code snippet
/// keyboard accessory bar.
private struct PlainCodeTextView: UIViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .systemBackground
        textView.textColor = .label
        textView.font = Self.monospacedCalloutFont()
        textView.adjustsFontForContentSizeCategory = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 24, right: 10)
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityIdentifier = "scriptCodeEditor"
        textView.text = text
        textView.inputAccessoryView = context.coordinator.makeAccessoryToolbar(for: textView)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.text = $text
        uiView.accessibilityLabel = accessibilityLabel
        if uiView.text != text {
            uiView.text = text
        }
    }

    private static func monospacedCalloutFont() -> UIFont {
        let baseSize = UIFont.preferredFont(forTextStyle: .callout).pointSize
        let mono = UIFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
        return UIFontMetrics(forTextStyle: .callout).scaledFont(for: mono)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        private weak var textView: UITextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            if text.wrappedValue != textView.text {
                text.wrappedValue = textView.text
            }
        }

        @MainActor
        func makeAccessoryToolbar(for textView: UITextView) -> UIToolbar {
            self.textView = textView
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            bar.items = [
                snippetItem(title: "Tab", insert: "  ", cursorBack: 0),
                snippetItem(title: "{ }", insert: "{}", cursorBack: 1),
                snippetItem(title: "( )", insert: "()", cursorBack: 1),
                snippetItem(title: "' '", insert: "''", cursorBack: 1),
                snippetItem(title: ";", insert: ";", cursorBack: 0),
                snippetItem(title: "=>", insert: " => ", cursorBack: 0),
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                UIBarButtonItem(
                    title: String(localized: "Done", comment: "Keyboard toolbar button to dismiss the code keyboard"),
                    primaryAction: UIAction { [weak textView] _ in
                        textView?.resignFirstResponder()
                    }
                )
            ]
            bar.sizeToFit()
            return bar
        }

        @MainActor
        private func snippetItem(title: String, insert: String, cursorBack: Int) -> UIBarButtonItem {
            UIBarButtonItem(
                title: title,
                primaryAction: UIAction { [weak self] _ in
                    guard let self, let tv = self.textView else { return }
                    tv.insertText(insert)
                    if cursorBack > 0, let selected = tv.selectedTextRange,
                       let moved = tv.position(from: selected.start, offset: -cursorBack) {
                        tv.selectedTextRange = tv.textRange(from: moved, to: moved)
                    }
                    if self.text.wrappedValue != tv.text {
                        self.text.wrappedValue = tv.text
                    }
                }
            )
        }
    }
}

// MARK: - M2 §2 Version History (`ScriptHistoryView`)

private struct ScriptHistoryEntry: Identifiable {
    var version: Int
    var isCurrent: Bool
    var savedAt: Date
    var title: String
    var changeSummary: String
    var agentPrompt: String?
    var fileContent: String

    var id: Int { version }
}

struct ScriptHistoryView: View {
    @ObservedObject var app: AppModel
    let scriptID: String

    @State private var inspectedEntry: ScriptHistoryEntry?
    @State private var restoreToastState: (message: String, undoSnapshot: UserScript)?
    @State private var toastTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var store: ScriptStore { app.scriptStore }
    private var script: UserScript? { store.script(id: scriptID) }

    var body: some View {
        Group {
            if let script {
                let entries = buildEntries(for: script)
                List {
                    Section {
                        ForEach(entries) { entry in
                            historyRow(entry, parent: script)
                        }
                    } footer: {
                        Text("Restoring copies it as a new version, so nothing is lost.", comment: "Footer in Version history explaining non-destructive version restore")
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ContentUnavailableView(
                    String(localized: "Script not found", comment: "Fallback view when a script was deleted while viewing its detail"),
                    systemImage: "clock.arrow.circlepath"
                )
            }
        }
        .navigationTitle(Text("Version history", comment: "Row and screen title for a script's version history"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $inspectedEntry) { entry in
            ScriptCodeSheetView(
                title: String(localized: "Version \(entry.version)", comment: "Title of the View code sheet when inspecting a version from history"),
                subtitle: entry.title,
                fileContent: entry.fileContent,
                onRestore: entry.isCurrent ? nil : {
                    if let script {
                        restoreVersion(entry.version, of: script)
                    }
                }
            )
        }
        .overlay(alignment: .bottom) {
            if let toast = restoreToastState {
                ScriptToastBanner(
                    symbol: "arrow.uturn.backward",
                    message: toast.message,
                    undoAction: {
                        undoRestore(toast.undoSnapshot)
                    },
                    dismissAction: {
                        toastTask?.cancel()
                        restoreToastState = nil
                    }
                )
                .accessibilityIdentifier("scriptUndoToast")
                .padding(.horizontal, DCTheme.spacingL)
                .padding(.bottom, DCTheme.spacingM)
                .transition(reduceMotion ? .opacity : DCMotion.slide(.bottom, reduceMotion: false))
            }
        }
        .animation(DCMotion.respecting(reduceMotion, DCMotion.spring), value: restoreToastState?.message)
    }

    private func historyRow(_ entry: ScriptHistoryEntry, parent: UserScript) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                DCHaptics.tap()
                inspectedEntry = entry
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(entry.isCurrent ? DCTheme.agentTint : DCTheme.agentTint.opacity(0.12))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Text(verbatim: "\(entry.version)")
                                .font(.footnote.weight(.bold).monospacedDigit())
                                .foregroundStyle(
                                    entry.isCurrent
                                        ? (colorScheme == .dark ? Color.black : Color.white)
                                        : DCTheme.agentTint
                                )
                        }
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                            .font(.body.weight(entry.isCurrent ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("\(ScriptUIFormatting.relativeDate(entry.savedAt)) · \(entry.changeSummary)", comment: "Version history row subtitle: relative date followed by what changed")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let prompt = entry.agentPrompt {
                            Text("“\(prompt)”", comment: "Quoted user prompt that produced the script in Script detail and Version history")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scriptVersionRow-\(entry.version)")

            if entry.isCurrent {
                DCPill(
                    text: String(localized: "Current", comment: "Pill on the active version row in Version history"),
                    tint: DCTheme.success
                )
            } else {
                Button {
                    restoreVersion(entry.version, of: parent)
                } label: {
                    Text("Restore", comment: "Button on an older version row in Version history to copy it as the newest version")
                }
                .buttonStyle(DCActionButtonStyle(prominent: false))
                .accessibilityIdentifier("scriptRestoreVersion-\(entry.version)")
            }
        }
        .padding(.vertical, 2)
    }

    private func restoreVersion(_ targetVersion: Int, of currentScript: UserScript) {
        DCHaptics.tap()
        let beforeRestore = currentScript
        guard let restored = try? store.rollback(id: currentScript.id, toVersion: targetVersion) else {
            return
        }
        let msg = String(
            localized: "Version \(targetVersion) restored as version \(restored.version)",
            comment: "Toast and VoiceOver announcement when restoring an older script version; first number is restored version, second is newly created version"
        )
        toastTask?.cancel()
        restoreToastState = (message: msg, undoSnapshot: beforeRestore)
        ScriptUIFormatting.announce(msg)

        guard !UIAccessibility.isVoiceOverRunning else { return }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            restoreToastState = nil
        }
    }

    private func undoRestore(_ snapshot: UserScript) {
        DCHaptics.tap()
        toastTask?.cancel()
        try? store.restore(snapshot)
        restoreToastState = nil
        ScriptUIFormatting.announce(
            String(localized: "Undid restore", comment: "VoiceOver announcement after undoing a version restore")
        )
    }

    private func buildEntries(for script: UserScript) -> [ScriptHistoryEntry] {
        struct RawItem {
            var version: Int
            var isCurrent: Bool
            var name: String
            var matchRules: [String]
            var js: String
            var css: String
            var injectionTime: ScriptInjectionTime
            var environment: AgentExecutionEnvironment
            var savedAt: Date
            var origin: ScriptVersionOrigin?
            var fileContent: String
        }

        var ascending: [RawItem] = script.versions
            .sorted { $0.version < $1.version }
            .map { archived in
                RawItem(
                    version: archived.version,
                    isCurrent: false,
                    name: archived.name,
                    matchRules: archived.matchRules,
                    js: archived.js,
                    css: archived.css,
                    injectionTime: archived.injectionTime,
                    environment: archived.environment,
                    savedAt: archived.savedAt,
                    origin: archived.origin,
                    fileContent: archived.toUserScript(from: script).toUserScriptFileContent()
                )
            }

        ascending.append(
            RawItem(
                version: script.version,
                isCurrent: true,
                name: script.name,
                matchRules: script.matchRules,
                js: script.js,
                css: script.css,
                injectionTime: script.injectionTime,
                environment: script.environment,
                savedAt: script.updatedAt,
                origin: script.versionOrigin,
                fileContent: script.toUserScriptFileContent()
            )
        )
        ascending.sort { $0.version < $1.version }

        var built: [ScriptHistoryEntry] = []
        for (idx, item) in ascending.enumerated() {
            let (title, prompt) = resolveTitleAndPrompt(
                version: item.version,
                isEarliest: idx == 0,
                origin: item.origin,
                scriptSource: script.source
            )
            let changeSummary: String
            if idx == 0 {
                changeSummary = String(localized: "Initial version", comment: "Version history subtitle for version 1")
            } else {
                let prev = ascending[idx - 1]
                let changed = UserScript.changedFields(
                    from: (
                        name: prev.name,
                        matchRules: prev.matchRules,
                        js: prev.js,
                        css: prev.css,
                        injectionTime: prev.injectionTime,
                        environment: prev.environment
                    ),
                    to: (
                        name: item.name,
                        matchRules: item.matchRules,
                        js: item.js,
                        css: item.css,
                        injectionTime: item.injectionTime,
                        environment: item.environment
                    )
                )
                changeSummary = ScriptUIFormatting.changedFieldsDescription(changed)
            }

            built.append(
                ScriptHistoryEntry(
                    version: item.version,
                    isCurrent: item.isCurrent,
                    savedAt: item.savedAt,
                    title: title,
                    changeSummary: changeSummary,
                    agentPrompt: prompt,
                    fileContent: item.fileContent
                )
            )
        }

        return built.reversed()
    }

    private func resolveTitleAndPrompt(
        version: Int,
        isEarliest: Bool,
        origin: ScriptVersionOrigin?,
        scriptSource: ScriptSource
    ) -> (title: String, prompt: String?) {
        if let origin {
            switch origin {
            case .savedByAgent(let prompt):
                return (
                    String(localized: "Saved by the agent", comment: "Version history row title when initially saved by the browser agent"),
                    prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
                )
            case .changedByAgent(let prompt):
                return (
                    String(localized: "Changed by the agent", comment: "Version history row title when updated by the browser agent"),
                    prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
                )
            case .editedByUser:
                return (
                    String(localized: "Edited by you", comment: "Version history row title when edited in Script detail"),
                    nil
                )
            case .restored(let fromVersion):
                return (
                    String(localized: "Restored version \(fromVersion)", comment: "Version history row title when created by restoring an earlier version"),
                    nil
                )
            case .imported:
                return (
                    String(localized: "Imported", comment: "Version history row title for an imported userscript"),
                    nil
                )
            }
        }

        if isEarliest || version == 1 {
            switch scriptSource {
            case .agent(let prompt):
                let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    String(localized: "Saved by the agent", comment: "Version history row title when initially saved by the browser agent"),
                    trimmed.isEmpty ? nil : trimmed
                )
            case .imported:
                return (
                    String(localized: "Imported", comment: "Version history row title for an imported userscript"),
                    nil
                )
            }
        }

        return (
            String(localized: "Edited by you", comment: "Version history row title when edited in Script detail"),
            nil
        )
    }
}
