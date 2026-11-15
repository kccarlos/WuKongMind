import SwiftUI
import UIKit

struct ScriptImportSheet: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var importer: ScriptImporter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(app: AppModel) {
        self.app = app
        self.importer = app.scriptImporter
    }

    private var isRegularLayout: Bool {
        (horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad) && !dynamicTypeSize.isAccessibilitySize
    }

    private var isFailedPhase: Bool {
        if case .failed = importer.phase { true } else { false }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch importer.phase {
                case .loading(let linkURL): loadingBody(linkURL: linkURL)
                case .failed(let failure): failedBody(failure: failure)
                case .ready(let review): readyBody(review: review)
                case nil: Color.clear
                }
            }
            .background(DCTheme.ground.ignoresSafeArea())
            .navigationTitle(Text("Add script", comment: "Navigation title of the userscript import review sheet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        DCHaptics.tap()
                        importer.dismissImport()
                    } label: {
                        if isFailedPhase {
                            Text("Close", comment: "Closes the failed script import sheet")
                        } else {
                            Text("Cancel", comment: "Cancels importing a userscript")
                        }
                    }
                    .accessibilityIdentifier("scriptImportDismiss")
                }
            }
            .safeAreaInset(edge: .bottom) { footerBar }
        }
        .presentationDragIndicator(.visible)
        .frame(idealWidth: 620, idealHeight: 760)
        .accessibilityIdentifier("scriptImportSheet")
    }

    private func loadingBody(linkURL: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.regular)
            Text("Fetching script…", comment: "Loading status while downloading a .user.js file to review")
                .font(.subheadline.weight(.medium)).foregroundStyle(DCTheme.ink)
            Text(verbatim: linkURL)
                .font(.caption.monospaced()).foregroundStyle(DCTheme.inkMuted)
                .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scriptImportLoading")
    }

    private func failedBody(failure: ScriptImportFailure) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DCTheme.cinnabarWash).frame(width: 48, height: 48)
                        .overlay { Image(systemName: "exclamationmark.triangle").font(.title3.weight(.semibold)).foregroundStyle(DCTheme.danger) }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Can’t add this script", comment: "Header title when fetching or validating an imported userscript fails")
                            .font(.title3.weight(.bold)).foregroundStyle(DCTheme.ink)
                        Text("Nothing was installed.", comment: "Subtitle reassuring the user that a failed userscript import changed nothing")
                            .font(.footnote).foregroundStyle(DCTheme.inkMuted)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                bannerView(symbol: "exclamationmark.triangle", symbolColor: DCTheme.danger, text: failure.reason)
                    .accessibilityIdentifier("scriptImportErrorReason")

                if !failure.linkURL.isEmpty {
                    sectionBlock(title: String(localized: "The link", comment: "Section header above the URL that failed to import")) {
                        sectionRow(symbol: "globe", symbolColor: DCTheme.ink) {
                            Text(verbatim: failure.linkURL)
                                .font(.footnote.monospaced()).foregroundStyle(DCTheme.ink)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, isRegularLayout ? 24 : 16).padding(.top, 8).padding(.bottom, 20)
        }
        .accessibilityIdentifier("scriptImportFailed")
    }

    private func readyBody(review: ScriptImportReview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                reviewHeader(review)
                if let duplicateHost = review.duplicateNameHost {
                    bannerView(
                        symbol: "info.circle",
                        symbolColor: DCTheme.inkMuted,
                        text: String(localized: "You already have a script with this name from \(duplicateHost). This one is added separately.", comment: "Import review notice when another script already shares the same name")
                    )
                    .accessibilityIdentifier("scriptImportDuplicateBanner")
                }
                runsOnSection(rules: review.candidate.matchRules)
                let caps = ScriptImporter.capabilitySummaries(
                    for: review.candidate,
                    scriptsModelName: app.scriptsModelDisplayName,
                    forImportSheet: true
                )
                if !caps.isEmpty { canUseSection(capabilities: caps) }
                if !review.unsupportedItems.isEmpty { unsupportedSection(items: review.unsupportedItems) }
                if !review.libraries.isEmpty { librariesSection(libraries: review.libraries) }
                codeSection(source: review.rawSource, lineCount: review.lineCount)
                if !isRegularLayout { askAgentButton(for: review) }
            }
            .padding(.horizontal, isRegularLayout ? 24 : 16).padding(.top, 8).padding(.bottom, 20)
        }
        .accessibilityIdentifier("scriptImportReady")
    }

    private func reviewHeader(_ review: ScriptImportReview) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DCTheme.ink).frame(width: 48, height: 48)
                .overlay { Image(systemName: "curlybraces").font(.title3.weight(.semibold)).foregroundStyle(DCTheme.ground) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(review.candidate.name)
                    .font(.title3.weight(.bold)).foregroundStyle(DCTheme.ink).fixedSize(horizontal: false, vertical: true)
                if let subtitle = versionAuthorSubtitle(for: review) {
                    Text(verbatim: subtitle)
                        .font(.footnote).foregroundStyle(DCTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                }
                DCSeal(text: review.finalHost, variant: .outline)
                    .accessibilityLabel(Text("From \(review.finalHost)", comment: "Accessibility label for the source host badge on the import review sheet"))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scriptImportHeader")
    }

    private func versionAuthorSubtitle(for review: ScriptImportReview) -> String? {
        var parts: [String] = []
        if let v = review.candidate.metadata.authorVersion, !v.isEmpty { parts.append(v) }
        if let author = review.author, !author.isEmpty {
            parts.append(String(localized: "by \(author)", comment: "Script author attribution in the import review header"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func runsOnSection(rules: [String]) -> some View {
        sectionBlock(title: String(localized: "Runs on", comment: "Section header in Script detail for @match URL patterns")) {
            ForEach(Array(rules.enumerated()), id: \.offset) { idx, rule in
                let isBroad = ScriptImporter.isBroadEverySiteRule(rule)
                if idx > 0 { rowDivider }
                sectionRow(symbol: "globe", symbolColor: isBroad ? DCTheme.danger : DCTheme.ink) {
                    VStack(alignment: .leading, spacing: 2) {
                        if isBroad {
                            Text("Every site", comment: "Danger label in import review when a script matches all websites (*://*/*)")
                                .font(.subheadline.weight(.bold)).foregroundStyle(DCTheme.danger)
                            Text(verbatim: rule).font(.footnote.monospaced()).foregroundStyle(DCTheme.inkMuted)
                        } else {
                            Text(verbatim: rule).font(.subheadline.monospaced()).foregroundStyle(DCTheme.ink)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func canUseSection(capabilities: [ScriptCapabilitySummary]) -> some View {
        sectionBlock(title: String(localized: "Can use", comment: "Section header listing capabilities and GM_* grants a userscript can use")) {
            ForEach(Array(capabilities.enumerated()), id: \.element.id) { idx, item in
                if idx > 0 { rowDivider }
                sectionRow(symbol: item.icon.rawValue, symbolColor: item.isDanger ? DCTheme.danger : DCTheme.ink) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(item.isDanger ? .subheadline.weight(.bold) : .subheadline)
                            .foregroundStyle(item.isDanger ? DCTheme.danger : DCTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let sub = item.subtitle { Text(sub).font(.footnote).foregroundStyle(DCTheme.inkMuted) }
                    }
                }
            }
        }
    }

    private func unsupportedSection(items: [ScriptUnsupportedItem]) -> some View {
        sectionBlock(title: String(localized: "Not supported here", comment: "Section header listing unsupported Tampermonkey directives or grants")) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                if idx > 0 { rowDivider }
                sectionRow(symbol: item.style == .blocked ? "nosign" : "info.circle", symbolColor: DCTheme.ink) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.title)
                            .font(item.isMonospaced ? .subheadline.monospaced() : .subheadline)
                            .foregroundStyle(DCTheme.ink).fixedSize(horizontal: false, vertical: true)
                        Text(item.detail).font(.footnote).foregroundStyle(DCTheme.inkMuted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func librariesSection(libraries: [ScriptLoadedLibrary]) -> some View {
        sectionBlock(title: String(localized: "Libraries", comment: "Section header listing @require external JavaScript libraries")) {
            ForEach(Array(libraries.enumerated()), id: \.offset) { idx, lib in
                if idx > 0 { rowDivider }
                sectionRow(symbol: "book.closed", symbolColor: DCTheme.ink) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: Self.compactLibraryDisplay(lib.meta.url))
                            .font(.footnote.monospaced()).foregroundStyle(DCTheme.ink).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text(verbatim: Self.formattedBytes(lib.meta.sizeBytes))
                            .font(.subheadline).foregroundStyle(DCTheme.inkMuted).monospacedDigit()
                    }
                }
            }
        }
    }

    private func codeSection(source: String, lineCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Code", comment: "Section header in Script detail for JavaScript and CSS editors")
                    .font(.footnote.weight(.medium)).textCase(.uppercase).foregroundStyle(DCTheme.inkMuted)
                Spacer()
                Text("\(lineCount) lines", comment: "Code row trailing label showing line count")
                    .font(.footnote).foregroundStyle(DCTheme.inkMuted).monospacedDigit()
            }
            .padding(.horizontal, 16).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(Self.attributedCode(source: source))
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous))
            .accessibilityLabel(Text("Script code, read-only", comment: "Accessibility label for the read-only source preview in the import review sheet"))
            .accessibilityIdentifier("scriptImportCode")
        }
    }

    private func askAgentButton(for review: ScriptImportReview) -> some View {
        let shape = RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
        return Button {
            DCHaptics.tap()
            app.askAgentToReviewImportedScript(review)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.subheadline.weight(.semibold)).accessibilityHidden(true)
                Text("Ask the Agent to review it", comment: "Button in the script import sheet that opens the Agent to review the untrusted script code")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(isRegularLayout ? 1 : nil)
            }
            .foregroundStyle(DCTheme.ink).padding(.horizontal, 14).frame(minHeight: DCTheme.controlHeight)
            .background(Color.clear, in: shape)
            .overlay { shape.strokeBorder(DCTheme.gold, lineWidth: DCTheme.ringWidth) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: isRegularLayout, vertical: false)
        .accessibilityIdentifier("scriptImportAskAgent")
    }

    @ViewBuilder
    private var footerBar: some View {
        switch importer.phase {
        case .ready(let review):
            let sessionID = importer.activeSessionID
            footerContainer {
                if isRegularLayout {
                    HStack(spacing: 8) {
                        askAgentButton(for: review)
                        Spacer(minLength: 8)
                        addKeepOffButton(for: review, sessionID: sessionID, fullWidth: false).fixedSize(horizontal: true, vertical: false)
                        addTurnOnButton(for: review, sessionID: sessionID, fullWidth: false).fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    VStack(spacing: 8) {
                        addTurnOnButton(for: review, sessionID: sessionID, fullWidth: true)
                        addKeepOffButton(for: review, sessionID: sessionID, fullWidth: true)
                    }
                }
            }
        case .failed:
            footerContainer {
                let btn = Button {
                    DCHaptics.tap(); importer.retryCurrentImport()
                } label: {
                    Text("Try again", comment: "Button on failed script import sheet to retry downloading the .user.js link")
                }.accessibilityIdentifier("scriptImportTryAgain")
                if isRegularLayout {
                    HStack { Spacer(); btn.buttonStyle(DCButtonStyle(role: .secondary)) }
                } else {
                    btn.buttonStyle(DCButtonStyle(role: .secondary, fullWidth: true))
                }
            }
        case .loading, nil:
            EmptyView()
        }
    }

    private func addTurnOnButton(for review: ScriptImportReview, sessionID: UUID?, fullWidth: Bool) -> some View {
        Button { confirmImport(review: review, sessionID: sessionID, turnOn: true) } label: {
            Text("Add and turn on", comment: "Primary import button that saves and enables the script")
        }
        .buttonStyle(DCButtonStyle(role: .primary, fullWidth: fullWidth))
        .accessibilityIdentifier("scriptImportAddTurnOn")
    }

    private func addKeepOffButton(for review: ScriptImportReview, sessionID: UUID?, fullWidth: Bool) -> some View {
        Button { confirmImport(review: review, sessionID: sessionID, turnOn: false) } label: {
            Text("Add, keep off", comment: "Secondary import button that saves the script disabled")
        }
        .buttonStyle(DCButtonStyle(role: .secondary, fullWidth: fullWidth))
        .accessibilityIdentifier("scriptImportAddKeepOff")
    }

    private func footerContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, isRegularLayout ? 20 : 16).padding(.vertical, 12)
            .background {
                DCTheme.surface
                    .overlay(alignment: .top) { Rectangle().fill(DCTheme.hairline).frame(height: DCTheme.hairlineWidth) }
                    .ignoresSafeArea()
            }
    }

    private func confirmImport(review: ScriptImportReview, sessionID: UUID?, turnOn: Bool) {
        DCHaptics.success()
        do { _ = try importer.confirmImport(turnOn: turnOn, expectedSessionID: sessionID, expectedReview: review) }
        catch { app.presentError(error.localizedDescription) }
    }

    private func bannerView(symbol: String, symbolColor: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(symbolColor).padding(.top, 1).accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(DCTheme.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func sectionBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.medium)).textCase(.uppercase).foregroundStyle(DCTheme.inkMuted)
                .padding(.horizontal, 16).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content() }
                .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous))
        }
    }

    private func sectionRow<Content: View>(symbol: String, symbolColor: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.subheadline.weight(.medium)).foregroundStyle(symbolColor)
                .frame(width: 20, alignment: .center).padding(.top, 1).accessibilityHidden(true)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 11).accessibilityElement(children: .combine)
    }

    private var rowDivider: some View {
        Rectangle().fill(DCTheme.hairline).frame(height: DCTheme.hairlineWidth).padding(.leading, 46)
    }

    private static func compactLibraryDisplay(_ rawURL: String) -> String {
        guard let url = URL(string: rawURL), let host = url.host else { return rawURL }
        return (url.path.isEmpty || url.path == "/") ? host : "\(host)\(url.path)"
    }

    private static func formattedBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(max(1, bytes)) B" }
        let kb = Int((Double(bytes) / 1024.0).rounded())
        return kb < 1024 ? "\(max(1, kb)) KB" : String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }

    private static func attributedCode(source: String) -> AttributedString {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let maxDigits = max(2, String(lines.count).count)
        var output = AttributedString()
        for (idx, line) in lines.enumerated() {
            let num = String(idx + 1)
            var numAttr = AttributedString(String(repeating: " ", count: max(0, maxDigits - num.count)) + num + " ")
            numAttr.foregroundColor = DCTheme.inkFaint
            output.append(numAttr)
            var codeAttr = AttributedString(line + (idx < lines.count - 1 ? "\n" : ""))
            codeAttr.foregroundColor = DCTheme.ink
            output.append(codeAttr)
        }
        return output
    }
}
