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
            Section("Assistant") {
                row(.provider, value: modelsSummary)
                row(
                    .agent,
                    value: String(
                        localized: "\(app.settings.browserAgentMaxSteps) steps",
                        comment: "Settings root, Agent row: configured step limit, e.g. 30 steps"
                    )
                )
                row(
                    .scripts,
                    value: app.settings.browserScriptsEnabled
                        ? "\(app.scriptStore.scripts.count)"
                        : String(localized: "Off")
                )
            }

            Section("Sites & browsing") {
                row(
                    .sites,
                    value: String(
                        localized: "\(app.forums.count) forums",
                        comment: "Settings root, Sites row: number of saved forums"
                    )
                )
                row(.browser, value: app.settings.searchEngine.displayName)
            }

            Section("Voice & digest") {
                row(.voice, value: app.settings.voiceEnabled ? String(localized: "On") : String(localized: "Off"))
                row(
                    .digest,
                    value: (app.settings.dailyDigestEnabled || app.settings.podcastDailyEnabled)
                        ? String(localized: "On")
                        : String(localized: "Off")
                )
            }

            Section("Your data") {
                SettingsSyncRow(app: app)
                row(.data)
            }

            Section {
                row(.help)
            }
        }
        .formStyle(.grouped)
        .dcGroupedBackground()
        .tint(DCTheme.goldInk)
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsPage.self) { page in
            SettingsDestination(app: app, page: page)
        }
        .navigationDestination(item: $pushed) { page in
            SettingsDestination(app: app, page: page)
        }
        .accessibilityIdentifier("settingsRoot")
    }

    private var modelsSummary: String {
        app.hasConfiguredModel(for: .browserAgent)
            ? String(localized: "2 roles", comment: "Settings root, Models row: both Agent and Summaries models are configured")
            : String(localized: "Agent: none", comment: "Settings root, Models row: no Agent model chosen yet")
    }

    private func row(_ page: SettingsPage, value: String? = nil) -> some View {
        NavigationLink(value: page) {
            SettingsRowLabel(page: page, value: value)
        }
        .accessibilityIdentifier("settingsRow-\(page.rawValue)")
    }
}

/// Opens WukongMind's page in the Settings app, where iOS shows the
/// per-app Language picker (the bundle has more than one localization).
struct SettingsLanguageRow: View {
    var body: some View {
        Button {
            DCHaptics.tap()
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            SettingsIconRow {
                SettingsIcon(symbol: "character.bubble", tint: DCTheme.ink)
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
}

/// Settings › Models › Answer language: the app's language, or one of
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
            SettingsIcon(symbol: "translate", tint: DCTheme.ink)
        } title: {
            Text("Read answers in", comment: "Settings › Models › Answer language: picker label for summary and answer language")
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
                Picker("Read answers in", selection: $app.settings.readingLanguage) {
                    Text("App language (\(AppLanguage.displayName))", comment: "Reading language option; the placeholder is the app's language name").tag("")
                    ForEach(ReadingLanguage.choices, id: \.self) { code in
                        Text(verbatim: ReadingLanguage.displayName(code)).tag(code)
                    }
                }
            } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Read answers in"))
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
        destinationContent
            .dcGroupedBackground()
            .tint(DCTheme.goldInk)
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch page {
        case .scripts:
            ScriptManagerView(app: app)
        case .provider:
            SettingsProviderPage(app: app).toggleStyle(DCSwitchStyle())
        case .sites:
            SettingsSitesPage(app: app).toggleStyle(DCSwitchStyle())
        case .sync:
            SettingsSyncPage(app: app).toggleStyle(DCSwitchStyle())
        case .forums:
            SettingsForumsPage(app: app).toggleStyle(DCSwitchStyle())
        case .agent:
            SettingsAgentPage(app: app).toggleStyle(DCSwitchStyle())
        case .watched:
            SettingsWatchedPage(app: app).toggleStyle(DCSwitchStyle())
        case .digest:
            SettingsDigestPage(app: app).toggleStyle(DCSwitchStyle())
        case .voice:
            SettingsVoicePage(app: app, voice: app.voice).toggleStyle(DCSwitchStyle())
        case .browser:
            SettingsBrowserPage(app: app).toggleStyle(DCSwitchStyle())
        case .data:
            SettingsDataPage(app: app).toggleStyle(DCSwitchStyle())
        case .help:
            SettingsHelpPage(app: app).toggleStyle(DCSwitchStyle())
        case .sharing:
            SettingsSharingPage().toggleStyle(DCSwitchStyle())
        case .acknowledgements:
            SettingsAcknowledgementsPage(app: app).toggleStyle(DCSwitchStyle())
        }
    }
}

/// 29pt `radiusSm` icon tile: `ink` with a `ground` glyph by default, or `gold`
/// with the `onGold` ring for the Agent row (`ListRow/README.md`).
struct SettingsIcon: View {
    let symbol: String
    let isAgent: Bool

    init(page: SettingsPage) {
        symbol = page.systemImage
        isAgent = (page == .agent)
    }

    init(symbol: String, tint: Color, isAgent: Bool = false) {
        self.symbol = symbol
        self.isAgent = isAgent
    }

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 29

    var body: some View {
        DCListIconTile(
            kind: isAgent ? .agent : .ink(symbol: symbol),
            size: min(size, 34)
        )
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
        DCSeal(
            text: ready ? String(localized: "Ready", comment: "AI provider status pill") : String(localized: "Set up", comment: "AI provider status pill: needs setup"),
            variant: .state(ready ? .ready : .attention)
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
