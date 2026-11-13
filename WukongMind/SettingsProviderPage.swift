import SwiftUI

/// Settings › Models: the model for each role (Agent and Summaries, plus a
/// placeholder for M4's Scripts model), summary batching & instructions,
/// answer language, favorite models, and each provider's key and address.
struct SettingsProviderPage: View {
    @ObservedObject var app: AppModel
    @State private var choosing: FavoriteModel?

    /// UI roles whose selection can be applied to both Agent and Summaries.
    private var shareableRoles: [ModelRole] {
        guard !app.uiRolesShareModel else { return [] }
        return ModelRole.uiRoles.filter { role in
            guard app.hasConfiguredModel(for: role) else { return false }
            let selection = app.selection(for: role)
            return app.isProviderSelectable(selection.provider)
                && selection.provider.supportsToolCalling
                && !selection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var hasCustomInstructions: Bool {
        !app.settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                ForEach(ModelRole.uiRoles) { role in
                    NavigationLink {
                        ModelRolePage(app: app, role: role)
                    } label: {
                        ModelRoleRow(app: app, role: role)
                    }
                    .accessibilityIdentifier("modelRole-\(role.rawValue)")
                }
                ScriptsModelPlaceholderRow()
                ForEach(shareableRoles) { role in
                    Button {
                        DCHaptics.tap()
                        app.applyModelToBothUIRoles(app.selection(for: role))
                    } label: {
                        Label(
                            String(
                                localized: "Use \(app.providerSummary(for: role)) for both",
                                comment: "Settings › Models: gives both Agent and Summaries this model. The placeholder is a provider and model, e.g. OpenRouter · kimi-k2."
                            ),
                            systemImage: "arrow.left.arrow.right"
                        )
                    }
                    .accessibilityIdentifier("useSameModel-\(role.rawValue)")
                }
            } header: {
                Text("Default models", comment: "Settings › Models section header for the Agent, Summaries and Scripts roles")
            } footer: {
                Text("Agent requires a tool-calling model. Summaries can use Apple Intelligence or any fast, low-cost model.")
            }

            Section {
                VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                    HStack {
                        Text("Context per batch")
                        Spacer()
                        Text(SummaryBatchLimit.label(app.settings.summaryBatchLimit))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text("How much of a long topic is summarized at once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Slider(
                        value: Binding(
                            get: { Double(app.settings.summaryBatchLimit) },
                            set: { app.settings.summaryBatchLimit = SummaryBatchLimit.normalized(Int($0)) }
                        ),
                        in: Double(SummaryBatchLimit.minimum)...Double(SummaryBatchLimit.maximum),
                        step: Double(SummaryBatchLimit.step)
                    )
                    .accessibilityLabel("Context per summary batch")
                    .tint(DCTheme.goldInk)
                    .accessibilityValue(SummaryBatchLimit.label(app.settings.summaryBatchLimit))
                    .accessibilityIdentifier("summaryBatchLimit")
                }
                if app.settings.summaryBatchLimit != SummaryBatchLimit.default {
                    Button("Use default (\(SummaryBatchLimit.label(SummaryBatchLimit.default)))") {
                        app.settings.summaryBatchLimit = SummaryBatchLimit.default
                    }
                }
                NavigationLink {
                    SummaryInstructionsPage(app: app)
                } label: {
                    SettingsIconRow {
                        SettingsIcon(symbol: "text.quote", tint: DCTheme.ink)
                    } title: {
                        Text("Instructions", comment: "Settings › Models › Summaries: row opening custom summary instructions")
                    } trailing: {
                        Text(
                            hasCustomInstructions
                                ? String(localized: "Custom", comment: "Settings › Models › Summaries: custom instructions are set")
                                : String(localized: "Built-in", comment: "Settings › Models › Summaries: built-in instructions are active")
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settingsRow-summaryInstructions")
            } header: {
                Text("Summaries")
            } footer: {
                Text("Longer discussions are split into batches of this size. Hold Create summary to pick a size for one run.")
            }

            Section {
                ReadingLanguagePicker(app: app)
            } header: {
                Text("Answer language", comment: "Settings › Models section header for the reading/answer language picker")
            } footer: {
                Text("Summaries, digests and answers are written in this language.")
            }

            FavoriteModelsSection(app: app, choosing: $choosing)

            Section {
                ForEach(providers) { provider in
                    NavigationLink {
                        ProviderSettingsPage(app: app, provider: provider)
                    } label: {
                        ProviderRow(app: app, provider: provider)
                    }
                    .accessibilityIdentifier("providerRow-\(provider.rawValue)")
                }
            } header: {
                Text("Providers & keys", comment: "Settings › Models section header for AI providers and their API keys")
            } footer: {
                Text("Keys and server addresses belong to a provider; both models use them.")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("aiModelsPage")
        .onChange(of: app.settings.summaryBatchLimit) { app.saveSettings() }
        .onChange(of: app.settings.readingLanguage) { app.saveSettings() }
        .onDisappear {
            app.saveSettings()
        }
        // Settings is already a routed presentation; its nested presenters
        // stay local (PresentationRouter), so the Settings stack stays mounted.
        .sheet(item: $choosing) { favorite in
            NavigationStack {
                Form {
                    Section {
                        ForEach(ModelRole.uiRoles.filter { $0 != .browserAgent || favorite.provider.supportsToolCalling }) { role in
                            Button(String(localized: "Use for \(role.title)", comment: "Favorite model menu: use it for a role. The placeholder is Agent or Summaries.")) {
                                DCHaptics.tap()
                                app.activateUIRoleFavorite(favorite, for: role)
                                choosing = nil
                            }
                        }
                        if favorite.provider.supportsToolCalling {
                            Button("Use for both") {
                                DCHaptics.tap()
                                app.applyModelToBothUIRoles(favorite.selection)
                                choosing = nil
                            }
                        }
                        Button("Remove from favorites", role: .destructive) {
                            app.removeFavorite(favorite)
                            choosing = nil
                        }
                    } header: {
                        Text(favorite.title)
                            .textCase(nil)
                    }
                }
                .navigationTitle("Favorite models")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { choosing = nil }
                            .accessibilityIdentifier("favoriteModelActionsDone")
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .dcFormSheet()
            .accessibilityIdentifier("favoriteModelActionsSheet")
        }
    }

    /// Providers a role uses first, then the rest in the usual order.
    private var providers: [AIProvider] {
        let used = AIProvider.allCases.filter { !app.settings.roles(using: $0).isEmpty }
        return used + AIProvider.allCases.filter { !used.contains($0) }
    }
}

/// M4 placeholder row in Settings › Models › Default models (`PhoneModels.dc.html`).
private struct ScriptsModelPlaceholderRow: View {
    var body: some View {
        SettingsIconRow {
            SettingsIcon(symbol: "curlybraces", tint: DCTheme.ink)
        } title: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scripts", comment: "Settings › Models: placeholder row for M4's optional script generation model")
                Text("Same as Summaries", comment: "Settings › Models: subtitle for the M4 Scripts model placeholder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } trailing: {
            DCSeal(text: "M4", variant: .outline)
        }
        .opacity(0.55)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("modelRole-scriptsPlaceholder")
    }
}

/// Sub-page for editing `AppSettings.systemPrompt` (`Settings › Models › Instructions`).
struct SummaryInstructionsPage: View {
    @ObservedObject var app: AppModel
    @FocusState private var editingInstructions: Bool

    var body: some View {
        Form {
            Section {
                TextEditor(text: $app.settings.systemPrompt)
                    .focused($editingInstructions)
                    .frame(minHeight: 160)
                    .overlay(alignment: .topLeading) {
                        if app.settings.systemPrompt.isEmpty {
                            Text("For example: Answer in English. Keep summaries under 200 words.",
                                 comment: "Placeholder for custom AI instructions. Translations may name their own language instead of English.")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Custom instructions")
                    .accessibilityIdentifier("customInstructions")
                if !app.settings.systemPrompt.isEmpty {
                    Button("Use the built-in prompt", role: .destructive) {
                        app.settings.systemPrompt = ""
                        app.saveSettings()
                    }
                }
            } header: {
                Text("Custom instructions")
            } footer: {
                Text("Leave blank to use the built-in structured summary prompt. A topic’s own instructions (in the assistant’s ⋯ menu) take priority.")
            }
        }
        .formStyle(.grouped)
        .dcGroupedBackground()
        .tint(DCTheme.goldInk)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(Text("Instructions", comment: "Navigation bar title for custom summary instructions"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editingInstructions {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        editingInstructions = false
                        app.saveSettings()
                    }
                }
            }
        }
        .onDisappear { app.saveSettings() }
    }
}

/// A role's row: its name, provider · model, and whether it can run.
struct ModelRoleRow: View {
    @ObservedObject var app: AppModel
    let role: ModelRole

    var body: some View {
        SettingsIconRow {
            SettingsIcon(symbol: role.systemImage, tint: DCTheme.ink, isAgent: role == .browserAgent)
        } title: {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.title)
                Text(app.providerSummary(for: role))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } trailing: {
            SettingsStatusPill(ready: app.isProviderReady(for: role))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A provider's row: which roles use it, and its state (Built in, Key
/// added, No key, On your computer).
private struct ProviderRow: View {
    @ObservedObject var app: AppModel
    let provider: AIProvider

    var body: some View {
        SettingsIconRow {
            ProviderBadge(provider: provider, size: 29)
        } title: {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                let roles = app.settings.roles(using: provider)
                if !roles.isEmpty {
                    Text(roles.map(\.title).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } trailing: {
            DCSeal(text: state.text, variant: state.variant)
        }
        .accessibilityElement(children: .combine)
    }

    private var state: (text: String, variant: DCSealVariant) {
        if provider.isAppleIntelligence {
            if let reason = app.appleIntelligenceStatus.reason {
                let variant: DCSealVariant = ModelFavorites.hidesAppleIntelligence(app.appleIntelligenceStatus)
                    ? .outline
                    : .state(.attention)
                return (reason.title, variant)
            }
            return (String(localized: "Built in", comment: "Settings › AI models, provider row: Apple Intelligence is part of the system"), .outline)
        }
        if provider.requiresAPIKey {
            return app.settings.configuration(for: provider).apiKey.isEmpty
                ? (String(localized: "No key", comment: "Settings › AI models, provider row: no key saved for this provider"), .state(.attention))
                : (String(localized: "Ready", comment: "AI provider status pill"), .state(.ready))
        }
        return (String(localized: "Local", comment: "Settings › Models, provider row: a model server on the user's own computer"), .outline)
    }
}

/// Favorites are provider + model pairs, shared by both roles, in the
/// user's order (Apple Intelligence like any other). Tap one to pick the
/// role to use it for, hold to use it for both, swipe to remove; removing
/// one leaves the roles as they are.
private struct FavoriteModelsSection: View {
    @ObservedObject var app: AppModel
    @Binding var choosing: FavoriteModel?

    /// Roles whose model isn't starred yet, one button per distinct model.
    private var unstarred: [ModelRole] {
        var seen: [ModelSelection] = []
        return ModelRole.uiRoles.filter { role in
            guard app.hasConfiguredModel(for: role) else { return false }
            let selection = app.selection(for: role)
            guard app.isProviderSelectable(selection.provider),
                  FavoriteModel(selection: selection) != nil, !app.isFavorite(selection),
                  !seen.contains(selection) else { return false }
            seen.append(selection)
            return true
        }
    }

    var body: some View {
        Section {
            if app.settings.favoriteModels.isEmpty {
                Text("Star a model to switch to it quickly here and in the assistant.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(app.settings.favoriteModels) { favorite in
                row(favorite)
            }
            ForEach(unstarred) { role in
                Button {
                    DCHaptics.tap()
                    app.addCurrentFavorite(for: role)
                } label: {
                    Label(
                        String(
                            localized: "Star \(ModelPill.label(for: app.selection(for: role)))",
                            comment: "Settings › AI models: adds a role's current model to the favorites. The placeholder is a model name."
                        ),
                        systemImage: "star"
                    )
                }
                .accessibilityIdentifier("starCurrentModel-\(role.rawValue)")
            }
        } header: {
            Text("Favorite models")
        } footer: {
            if !app.settings.favoriteModels.isEmpty {
                Text("Tap to use for one model, or hold to use for both. Swipe left to remove.")
            }
        }
    }

    @ViewBuilder
    private func row(_ favorite: FavoriteModel) -> some View {
        let hidden = favorite.provider.isAppleIntelligence && ModelFavorites.hidesAppleIntelligence(app.appleIntelligenceStatus)
        FavoriteModelRow(app: app, favorite: favorite, hidden: hidden)
            .contentShape(Rectangle())
            .onTapGesture { if !hidden { choosing = favorite } }
            .onLongPressGesture { if !hidden { useForBoth(favorite) } }
            .accessibilityAddTraits(hidden ? [] : .isButton)
            .accessibilityAction { if !hidden { choosing = favorite } }
            .accessibilityAction(named: Text("Use for both")) { if !hidden { useForBoth(favorite) } }
            .swipeActions {
                Button("Remove", role: .destructive) { app.removeFavorite(favorite) }
            }
            .accessibilityIdentifier("favoriteModel-\(favorite.id)")
    }

    private func useForBoth(_ favorite: FavoriteModel) {
        DCHaptics.tap()
        if favorite.provider.supportsToolCalling {
            app.applyModelToBothUIRoles(favorite.selection)
        } else {
            app.activateFavorite(favorite, for: .assistant)
        }
    }
}

private struct FavoriteModelRow: View {
    @ObservedObject var app: AppModel
    let favorite: FavoriteModel
    /// Apple Intelligence on a device that can't run it: kept (favorites
    /// sync) but greyed out with the reason.
    var hidden = false

    private var roles: [ModelRole] {
        ModelRole.uiRoles.filter { app.hasConfiguredModel(for: $0) && favorite.matches(app.selection(for: $0)) }
    }

    private var readiness: ModelReadiness { app.readiness(of: favorite.selection) }

    var body: some View {
        SettingsIconRow {
            Image(systemName: "star.fill")
                .foregroundStyle(DCTheme.goldInk)
                .imageScale(.small)
                .accessibilityHidden(true)
        } title: {
            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.title)
                    .foregroundStyle(hidden ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if hidden, let reason = app.appleIntelligenceStatus.reason {
                    Text(String(localized: "Hidden on this device: \(reason.title)", comment: "Settings › AI models: the Apple Intelligence favorite isn't offered on this device. The placeholder is the reason, e.g. Device not supported."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !roles.isEmpty {
                    Text(roles.map(\.title).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } trailing: {
            if !hidden {
                DCSeal(
                    text: readiness.title,
                    variant: .state(readiness == .ready ? .ready : .attention)
                )
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One role

/// Picks one role's provider and model: provider, key when missing, the
/// model (typed, from the provider's list, or a favorite), and a test.
struct ModelRolePage: View {
    @ObservedObject var app: AppModel
    let role: ModelRole
    @State private var testState: ProviderTestState = .idle

    private var scope: ModelScope { app.uiScope(for: role) }
    private var selection: ModelSelection { app.selection(for: role) }
    private var provider: AIProvider { selection.provider }
    private var guide: ProviderGuide { ProviderGuide.guide(for: provider) }

    var body: some View {
        Form {
            Section {
                header
            } footer: {
                Text(role.hint)
            }

            Section {
                ProviderMenu(app: app, scope: scope, identifier: "providerPicker") {
                    HStack {
                        Text("Provider")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(provider.displayName)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                NavigationLink {
                    ProviderSettingsPage(app: app, provider: provider)
                } label: {
                    Label(
                        String(localized: "\(provider.displayName) settings", comment: "Link to a provider's key and address. The placeholder is the provider's name."),
                        systemImage: provider.isAppleIntelligence ? "info.circle" : "key.horizontal"
                    )
                }
                .accessibilityIdentifier("providerSettingsLink")
            } header: {
                Text("Provider")
            } footer: {
                Text(guide.blurb)
            }

            if provider.requiresAPIKey, app.settings.configuration(for: provider).apiKey.isEmpty {
                Section {
                    APIKeyField(app: app, provider: provider)
                } header: {
                    Text("API key")
                } footer: {
                    Text("Sent only to \(provider.displayName). Both models use this key.")
                }
            }

            Section {
                if provider.isAppleIntelligence {
                    AppleIntelligenceStatusView(app: app)
                } else {
                    ModelField(app: app, scope: scope)
                }
                // Apple Intelligence is starred like any other provider when supported.
                if app.isProviderSelectable(provider) || app.isFavorite(selection) {
                    Button {
                        DCHaptics.tap()
                        if app.isFavorite(selection) {
                            app.removeFavorite(matching: selection)
                        } else {
                            app.addCurrentFavorite(for: role)
                        }
                    } label: {
                        Label(app.isFavorite(selection) ? "Remove from favorites" : "Add to favorites", systemImage: app.isFavorite(selection) ? "star.fill" : "star")
                    }
                    .disabled(FavoriteModel(selection: selection) == nil)
                    .accessibilityIdentifier("toggleFavoriteModel")
                }
            } header: {
                Text("Model")
            } footer: {
                if provider.isAppleIntelligence {
                    Text("Uses Private Cloud Compute when this build and device support it, otherwise the on-device model. \(guide.note ?? "")")
                } else {
                    Text("Default: \(provider.defaultModel). Tap the list button to load every model \(provider.displayName) offers.")
                }
            }

            if !app.visibleFavorites.isEmpty {
                let roleFavorites = app.visibleFavorites.filter { role != .browserAgent || $0.selection.supportsToolCalling }
                if !roleFavorites.isEmpty {
                    Section {
                        ForEach(roleFavorites) { favorite in
                            Button {
                                DCHaptics.tap()
                                app.activateUIRoleFavorite(favorite, for: role)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ModelPill.label(for: favorite.selection))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(favorite.provider.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if favorite.matches(selection) {
                                        Image(systemName: "checkmark").foregroundStyle(DCTheme.goldInk)
                                    }
                                }
                            }
                            .accessibilityHint("Switches to this model")
                        }
                    } header: {
                        Text("Favorite models")
                    }
                }
            }

            Section {
                Button {
                    Task {
                        testState = .testing
                        testState = await app.testAndSaveProvider(scope: scope)
                    }
                } label: {
                    HStack {
                        Label("Test & save", systemImage: "bolt.horizontal.circle")
                        Spacer()
                        if testState == .testing { ProgressView() }
                    }
                }
                .disabled(testState == .testing)
                .accessibilityIdentifier("testAndSaveProvider")
                if testState != .idle && testState != .testing {
                    ProviderTestStatusView(state: testState)
                }
            }

            if role == .browserAgent, app.hasConfiguredModel(for: .browserAgent) {
                Section {
                    Button(role: .destructive) {
                        DCHaptics.tap()
                        app.clearBrowserAgentModel()
                    } label: {
                        Text("Clear Agent model", comment: "Settings › Models › Agent: clears the selected Agent model")
                    }
                    .accessibilityIdentifier("clearBrowserAgentModel")
                }
            }
        }
        .formStyle(.grouped)
        .dcGroupedBackground()
        .tint(DCTheme.goldInk)
        .animation(DCMotion.quick, value: testState)
        .navigationTitle(role.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection) { testState = .idle }
        .onDisappear { app.saveSettings() }
    }

    private var header: some View {
        SettingsIconRow {
            ProviderBadge(provider: provider, size: 48)
        } title: {
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName).font(.headline)
                Text(modelSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } trailing: {
            SettingsStatusPill(ready: app.isProviderReady(for: role))
        }
        .padding(.vertical, DCTheme.spacingXS)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("modelRoleHeader-\(role.rawValue)")
    }

    private var modelSummary: String {
        if provider.isAppleIntelligence {
            return app.appleIntelligenceStatus.backend?.displayName
                ?? String(localized: "Not available", comment: "Settings › AI models header: Apple Intelligence can’t be used on this device")
        }
        return selection.model.isEmpty ? String(localized: "No model chosen") : selection.model
    }
}

// MARK: - One provider

/// A provider's key, server address, and connection test. Both roles use
/// these.
struct ProviderSettingsPage: View {
    @ObservedObject var app: AppModel
    let provider: AIProvider
    @State private var testState: ProviderTestState = .idle

    private var bindings: ProviderBindings { ProviderBindings(app: app, provider: provider) }
    private var guide: ProviderGuide { ProviderGuide.guide(for: provider) }
    private var usage: String {
        let roles = app.settings.roles(using: provider)
        guard !roles.isEmpty else {
            return String(localized: "Not used by either model", comment: "Provider settings: neither the Summaries & chat nor the Ask the forum model uses this provider")
        }
        return String(localized: "Used for \(roles.map(\.title).joined(separator: ", "))", comment: "Provider settings: the model roles that use this provider, e.g. Summaries & chat, Ask the forum")
    }

    /// "Get a key in …", the download page, or Apple's page.
    private var guideLink: some View {
        Link(destination: guide.link) {
            Label(guide.linkTitle, systemImage: provider.isAppleIntelligence ? "info.circle" : guide.isLocal ? "arrow.down.circle" : "key.horizontal")
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: DCTheme.spacingM) {
                    ProviderBadge(provider: provider, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.displayName).font(.headline)
                        Text(usage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, DCTheme.spacingXS)
                .accessibilityElement(children: .combine)
                // Providers with a key link to it under the key field.
                if !provider.requiresAPIKey {
                    guideLink
                }
            } footer: {
                Text(guide.blurb)
            }

            if provider.isAppleIntelligence {
                Section {
                    AppleIntelligenceStatusView(app: app)
                }
            }

            if provider.requiresAPIKey {
                Section {
                    APIKeyField(app: app, provider: provider)
                    guideLink
                } header: {
                    Text("API key")
                } footer: {
                    Text(app.settings.syncAPIKeys
                        ? "Sent only to \(provider.displayName). Stored in iCloud Keychain, so your other devices have it too; deleting it here deletes it there as well."
                        : "Sent only to \(provider.displayName). Stored in the Keychain on this device.")
                }
            }

            if !provider.isAppleIntelligence {
                Section {
                    TextField(provider.defaultBaseURL, text: bindings.binding(\.baseURL))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("baseURLField")
                    if bindings.configuration.baseURL != provider.defaultBaseURL {
                        Button("Use default address") {
                            bindings.binding(\.baseURL).wrappedValue = provider.defaultBaseURL
                        }
                    }
                } header: {
                    Text(provider.requiresAPIKey ? "Advanced" : "Server address")
                } footer: {
                    Text(guide.note ?? String(localized: "Leave this as is unless you use a proxy or a compatible gateway."))
                }

                Section {
                    Button {
                        Task {
                            testState = .testing
                            testState = await app.testAndSaveProvider(provider)
                        }
                    } label: {
                        HStack(spacing: DCTheme.spacingS) {
                            if testState == .testing { ProgressView().tint(DCTheme.onGold) }
                            Text("Test & Save")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DCTheme.onGold)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(testState == .testing)
                    .accessibilityIdentifier("testProvider")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(DCTheme.gold.opacity(testState == .testing ? 0.7 : 1))
                } footer: {
                    if testState != .idle && testState != .testing {
                        ProviderTestStatusView(state: testState)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DCTheme.spacingXS)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .dcGroupedBackground()
        .tint(DCTheme.goldInk)
        .animation(DCMotion.quick, value: testState)
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: bindings.configuration) { testState = .idle }
        .onDisappear { app.saveSettings() }
    }
}
