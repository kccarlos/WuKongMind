import SwiftUI

/// Grouped Settings root, iOS Settings style. Registers the sub-page
/// destinations, so it must sit inside a NavigationStack.
struct SettingsRootView: View {
    @ObservedObject var app: AppModel
    @State private var pushed: SettingsPage?

    init(app: AppModel, initialPage: SettingsPage? = nil) {
        self.app = app
        _pushed = State(initialValue: initialPage)
    }

    var body: some View {
        Form {
            Section {
                summaryRow(.assistant)
                summaryRow(.agent)
                NavigationLink(value: SettingsPage.voice) {
                    Label(SettingsRootSummary.voiceToday(
                        seconds: VoiceUsageStore().seconds(on: Date()),
                        dailyLimitMinutes: app.settings.voice.dailyLimitMinutes
                    ), systemImage: "waveform")
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settingsSummary-voice")
            }

            Section("AI") {
                NavigationLink(value: SettingsPage.provider) {
                    providerRow
                }
                .accessibilityIdentifier("settingsRow-provider")
                row(.voice, value: app.settings.voiceEnabled ? String(localized: "On") : String(localized: "Off"))
            }

            Section("Reading") {
                row(.summaries)
                row(.agent)
                row(
                    .scripts,
                    value: app.settings.browserScriptsEnabled
                        ? "\(app.scriptStore.scripts.count)"
                        : String(localized: "Off")
                )
                ReadingLanguagePicker(app: app)
                row(.browser, value: String(localized: "Bar: \(app.settings.browserBarPosition.displayName)", comment: "Settings root, Browser row: the address bar position, e.g. Automatic"))
            }

            Section("Today & following") {
                row(.digest, value: app.settings.dailyDigestEnabled ? String(localized: "On") : String(localized: "Off"))
                row(.watched, value: app.watchedTopics.isEmpty ? nil : "\(app.watchedTopics.count)")
            }

            Section("Forums, sync & privacy") {
                row(.forums, value: forumsValue)
                SettingsSyncRow(app: app)
                row(.data)
            }

            Section {
                NavigationLink(value: SettingsPage.sharing) {
                    SettingsRowLabel(page: .sharing, title: String(localized: "Open pages from Safari or Chrome"))
                }
                .accessibilityIdentifier("settingsRow-sharing")
                row(.help)
                languageRow
            } header: {
                Text("Help")
            } footer: {
                Text("iOS manages the app language. Change it in Settings › WukongMind › Language.")
            }
        }
        .formStyle(.grouped)
        .tint(DCTheme.brandBlue)
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsPage.self) { page in
            SettingsDestination(app: app, page: page)
        }
        .navigationDestination(item: $pushed) { page in
            SettingsDestination(app: app, page: page)
        }
        .accessibilityIdentifier("settingsRoot")
    }

    /// A header line: the role's name and its current model.
    private func summaryRow(_ role: ModelRole) -> some View {
        let model = app.modelLabel(for: role)
        return NavigationLink(value: SettingsPage.provider) {
            LabeledContent {
                Text(model.isEmpty ? app.selection(for: role).provider.displayName : model)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } label: {
                Text(role == .assistant ? "Summaries & chat model" : "Ask the forum model")
            }
        }
        .accessibilityIdentifier("settingsSummary-\(role.rawValue)")
    }

    private var forumsValue: String? {
        let pinned = app.pinnedForums.count
        if pinned > 0 { return String(localized: "\(pinned) pinned", comment: "Settings root, Forums row: number of pinned forums") }
        return app.forums.isEmpty ? nil : "\(app.forums.count)"
    }

    private var providerRow: some View {
        SettingsIconRow {
            SettingsIcon(page: .provider)
        } title: {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI models")
                Text(providerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } trailing: {
            SettingsStatusPill(ready: app.isProviderReady)
        }
    }

    /// One "provider · model" when both roles share it, else both models.
    private var providerSummary: String {
        guard !app.rolesShareModel else { return app.providerSummary(for: .assistant) }
        return ModelRole.forumRoles.map { role in
            let model = app.modelLabel(for: role)
            return model.isEmpty ? app.selection(for: role).provider.displayName : model
        }.joined(separator: " · ")
    }

    /// Opens WukongMind's page in the Settings app, where iOS shows the
    /// per-app Language picker (the bundle has more than one localization).
    private var languageRow: some View {
        Button {
            DCHaptics.tap()
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            SettingsIconRow {
                SettingsIcon(symbol: "globe", tint: Color(light: 0x1C7CD6, dark: 0x4AA3FF))
            } title: {
                // Explicit colors: a Form button would tint `.primary`.
                Text("Language")
                    .foregroundStyle(Color.primary)
            } trailing: {
                HStack(spacing: DCTheme.spacingS) {
                    Text(AppLanguage.displayName)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                    Image(systemName: "arrow.up.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityHint("Opens WukongMind in the Settings app")
        .accessibilityIdentifier("settingsRow-language")
    }

    private func row(_ page: SettingsPage, value: String? = nil) -> some View {
        NavigationLink(value: page) {
            SettingsRowLabel(page: page, value: value)
        }
        .accessibilityIdentifier("settingsRow-\(page.rawValue)")
    }
}

/// Settings › Reading language: the app's language, or one of
/// `ReadingLanguage.choices` (names from the system).
struct ReadingLanguagePicker: View {
    @ObservedObject var app: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var selectedLabel: String {
        let code = app.settings.readingLanguage
        if code.isEmpty {
            return String(localized: "App language (\(AppLanguage.displayName))", comment: "Reading language option; the placeholder is the app's language name")
        }
        return ReadingLanguage.displayName(code)
    }

    var body: some View {
        SettingsIconRow {
            SettingsIcon(symbol: "translate", tint: Color(light: 0x2F9E6B, dark: 0x4CC38A))
        } title: {
            Text("Reading language")
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        } trailing: {
            HStack(spacing: 3) {
                Text(verbatim: selectedLabel)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
        }
        .contentShape(Rectangle())
        .overlay {
            Menu {
                Picker("Reading language", selection: $app.settings.readingLanguage) {
                    Text("App language (\(AppLanguage.displayName))", comment: "Reading language option; the placeholder is the app's language name").tag("")
                    ForEach(ReadingLanguage.choices, id: \.self) { code in
                        Text(verbatim: ReadingLanguage.displayName(code)).tag(code)
                    }
                }
            } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Reading language"))
            .accessibilityValue(selectedLabel)
            .accessibilityIdentifier("settingsRow-readingLanguage")
        }
    }
}

/// Routes a page value to its view.
struct SettingsDestination: View {
    @ObservedObject var app: AppModel
    let page: SettingsPage

    var body: some View {
        Group {
            switch page {
            case .provider: SettingsProviderPage(app: app)
            case .sync: SettingsSyncPage(app: app)
            case .forums: SettingsForumsPage(app: app)
            case .summaries: SettingsSummariesPage(app: app)
            case .agent: SettingsAgentPage(app: app)
            case .scripts: ScriptManagerView(app: app)
            case .watched: SettingsWatchedPage(app: app)
            case .digest: SettingsDigestPage(app: app)
            case .voice: SettingsVoicePage(app: app, voice: app.voice)
            case .browser: SettingsBrowserPage(app: app)
            case .data: SettingsDataPage(app: app)
            case .help: SettingsHelpPage(app: app)
            case .sharing: SettingsSharingPage()
            case .acknowledgements: SettingsAcknowledgementsPage(app: app)
            }
        }
        .tint(DCTheme.brandBlue)
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

/// White glyph in a colored rounded square, like iOS Settings.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    init(page: SettingsPage) {
        symbol = page.systemImage
        tint = page.tint
    }

    init(symbol: String, tint: Color) {
        self.symbol = symbol
        self.tint = tint
    }

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 29

    var body: some View {
        let side = min(size, 34)
        RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
            .fill(tint.gradient)
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A Settings row with a leading icon, a title/subtitle stack, and a
/// trailing value or status badge. At accessibility text sizes the icon is
/// omitted and the trailing view stacks under the title so the title keeps
/// the full row width.
struct SettingsIconRow<Icon: View, Title: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var spacing: CGFloat = DCTheme.spacingM
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var title: () -> Title
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DCTheme.spacingXS) {
                title()
                trailing()
            }
        } else {
            HStack(spacing: 4) {
                HStack(spacing: spacing) {
                    icon()
                    title()
                }
                Spacer(minLength: 0)
                trailing()
            }
        }
    }
}

struct SettingsRowLabel: View {
    let page: SettingsPage
    var title: String?
    var value: String?

    var body: some View {
        SettingsIconRow {
            SettingsIcon(page: page)
        } title: {
            Text(title ?? page.title)
        } trailing: {
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct SettingsStatusPill: View {
    let ready: Bool

    var body: some View {
        DCPill(
            text: ready ? String(localized: "Ready", comment: "AI provider status pill") : String(localized: "Set up", comment: "AI provider status pill: needs setup"),
            systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            tint: ready ? DCTheme.success : DCTheme.warning
        )
        .accessibilityLabel(ready ? "Provider ready" : "Provider needs setup")
    }
}

/// Derived text for the Settings root header.
enum SettingsRootSummary {
    /// "Voice today 4 of 30 min"; without a daily limit (0) just the minutes.
    static func voiceToday(seconds: TimeInterval, dailyLimitMinutes: Int) -> String {
        let used = Int((max(0, seconds) / 60).rounded(.up))
        if dailyLimitMinutes > 0 {
            return String(localized: "Voice today \(used) of \(dailyLimitMinutes) min", comment: "Settings header: voice minutes used today of the daily limit")
        }
        return String(localized: "Voice today \(used) min", comment: "Settings header: voice minutes used today, no daily limit")
    }
}
