import SwiftUI
import UIKit

/// The `Models` section on `ProviderSettingsPage` (`design-browser-bar-tabs-models.md` §3, row P1):
/// fetches or displays the provider's models in provider order, shows the five
/// states (Loading, No key yet, Fetch failed, Nothing listed, Loaded), lets the
/// user star favorites in place, shows active `Agent` / `Summaries` role seals,
/// and offers the native `⋯` role/favorite/copy Menu.
struct ProviderModelsSection: View {
    static let initialVisibleCount = 6
    static let searchThreshold = 20

    @ObservedObject var app: AppModel
    let provider: AIProvider

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showAll = false
    @State private var searchQuery = ""
    @State private var loadTask: Task<Void, Never>?

    private var configuration: ProviderConfiguration {
        app.settings.configuration(for: provider)
    }

    private var trimmedAPIKey: String {
        configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBaseURL: String {
        configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFixedList: Bool {
        provider.isAppleIntelligence || provider == .vertexAI
    }

    private var needsKeyBeforeFetch: Bool {
        provider.requiresAPIKey && provider != .vertexAI && trimmedAPIKey.isEmpty
    }

    private var showsRefreshButton: Bool {
        !isFixedList && !needsKeyBeforeFetch
    }

    private var resolvedModels: [DiscoveredModel] {
        if provider.isAppleIntelligence {
            return [DiscoveredModel(id: AIProvider.appleIntelligence.defaultModel)]
        }
        if provider == .vertexAI {
            return AIProvider.vertexAIModels.map { DiscoveredModel(id: $0) }
        }
        return app.discoveredModels[provider] ?? []
    }

    private var hasCachedResult: Bool {
        isFixedList || app.discoveredModels[provider] != nil
    }

    private enum SectionState {
        case loading
        case noKey
        case failed(String)
        case empty
        case loaded([DiscoveredModel])
    }

    private var state: SectionState {
        if isFixedList {
            return .loaded(resolvedModels)
        }
        if needsKeyBeforeFetch {
            return .noKey
        }
        if isLoading {
            return .loading
        }
        if let errorMessage {
            return .failed(errorMessage)
        }
        if !hasCachedResult {
            return .loading
        }
        if resolvedModels.isEmpty {
            return .empty
        }
        return .loaded(resolvedModels)
    }

    var body: some View {
        Section {
            switch state {
            case .loading:
                loadingRow
            case .noKey:
                noKeyRow
            case .failed(let message):
                failedRow(message: message)
            case .empty:
                emptyRow
            case .loaded(let models):
                loadedContent(models: models)
            }
        } header: {
            header
        } footer: {
            if case .loaded = state {
                footer
            }
        }
        .onAppear {
            if !isFixedList && !needsKeyBeforeFetch && app.discoveredModels[provider] == nil {
                triggerLoad(debounced: false)
            }
        }
        .onChange(of: trimmedAPIKey) {
            handleConfigurationChange()
        }
        .onChange(of: trimmedBaseURL) {
            handleConfigurationChange()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
        }
    }

    private var header: some View {
        HStack(spacing: DCTheme.space2) {
            Text("Models")
            Spacer(minLength: DCTheme.space2)
            if showsRefreshButton {
                Button {
                    DCHaptics.tap()
                    triggerLoad(debounced: false)
                } label: {
                    HStack(spacing: DCTheme.space1) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Refresh", comment: "Provider settings › Models section header button to reload the model list")
                            .font(DCType.footnote.weight(.medium))
                    }
                    .foregroundStyle(isLoading ? DCTheme.inkFaint : DCTheme.goldInk)
                    .frame(minHeight: DCTheme.controlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .textCase(nil)
                .disabled(isLoading)
                .padding(.vertical, -10)
                .accessibilityIdentifier("refreshModels")
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if provider.isAppleIntelligence {
            Text(
                "Apple Intelligence has one model and no tool calling, so it can't run the Agent. There is nothing to fetch or add.",
                comment: "Provider settings › Apple Intelligence › Models footer"
            )
        } else if provider == .vertexAI {
            Text(
                "Built-in list. Add others by name.",
                comment: "Provider settings › Vertex AI › Models footer"
            )
        } else if provider.isLocalServer {
            Text(
                "Read from your server just now. Star a model to keep it in the Agent's model menu.",
                comment: "Provider settings › Local server › Models footer"
            )
        } else {
            Text(
                "Fetched with your key just now. Star a model to keep it in the Agent's model menu.",
                comment: "Provider settings › Hosted provider › Models footer"
            )
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(DCTheme.inkFaint)
            Text("Loading models…")
                .font(DCType.body)
                .foregroundStyle(DCTheme.inkMuted)
        }
        .frame(minHeight: DCTheme.controlHeight)
        .listRowBackground(DCTheme.surface)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("modelsState-loading")
    }

    private var noKeyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "key")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DCTheme.inkMuted)
                .accessibilityHidden(true)
            Text(
                "Add your API key above to see this provider's models.",
                comment: "Provider settings › Models: shown before an API key is entered"
            )
            .font(DCType.subheadline)
            .foregroundStyle(DCTheme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DCTheme.space1)
        .frame(minHeight: DCTheme.controlHeight)
        .listRowBackground(DCTheme.surface)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("modelsState-noKey")
    }

    private func failedRow(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DCTheme.warning)
                .padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t load models")
                    .font(DCType.body)
                    .foregroundStyle(DCTheme.ink)
                Text(message)
                    .font(DCType.footnote)
                    .foregroundStyle(DCTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button {
                DCHaptics.tap()
                triggerLoad(debounced: false)
            } label: {
                Text("Try again")
                    .font(DCType.subheadline.weight(.semibold))
                    .foregroundStyle(DCTheme.goldInk)
                    .frame(minHeight: DCTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("retryLoadModels")
        }
        .padding(.vertical, DCTheme.space1)
        .frame(minHeight: DCTheme.controlHeight)
        .listRowBackground(DCTheme.surface)
        .accessibilityIdentifier("modelsState-error")
    }

    private var emptyRow: some View {
        Text(
            "This server doesn't list its models. Add one by name.",
            comment: "Provider settings › Models: neutral empty state when the server returns no models or 404"
        )
        .font(DCType.subheadline)
        .foregroundStyle(DCTheme.inkMuted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, DCTheme.space1)
        .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight, alignment: .leading)
        .listRowBackground(DCTheme.surface)
        .accessibilityIdentifier("modelsState-empty")
    }

    @ViewBuilder
    private func loadedContent(models: [DiscoveredModel]) -> some View {
        if models.count > Self.searchThreshold {
            searchRow
        }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = filteredModels(from: models, query: trimmedQuery)

        if !trimmedQuery.isEmpty && filtered.isEmpty {
            Text("No models match “\(trimmedQuery)”.")
                .font(DCType.subheadline)
                .foregroundStyle(DCTheme.inkMuted)
                .frame(minHeight: DCTheme.controlHeight)
                .listRowBackground(DCTheme.surface)
                .accessibilityIdentifier("modelsState-noSearchResults")
        } else {
            let shouldCollapse = trimmedQuery.isEmpty && !showAll && filtered.count > Self.initialVisibleCount
            let visible = shouldCollapse ? Array(filtered.prefix(Self.initialVisibleCount)) : filtered

            ForEach(visible) { model in
                ProviderModelRow(app: app, provider: provider, model: model)
            }

            if shouldCollapse {
                Button {
                    DCHaptics.tap()
                    withAnimation(DCMotion.respecting(reduceMotion)) {
                        showAll = true
                    }
                } label: {
                    Text(
                        "Show all \(filtered.count)",
                        comment: "Provider settings › Models: expands the truncated model list; placeholder is the total model count"
                    )
                    .font(DCType.body)
                    .foregroundStyle(DCTheme.goldInk)
                    .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight, alignment: .leading)
                    .padding(.leading, 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                .listRowBackground(DCTheme.surface)
                .accessibilityIdentifier("showAllModels")
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: DCTheme.space2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DCTheme.inkFaint)
                .accessibilityHidden(true)
            TextField("Search models", text: $searchQuery)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .accessibilityIdentifier("searchProviderModels")
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DCTheme.inkFaint)
                        .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search", comment: "Clears the model search field"))
            }
        }
        .frame(minHeight: DCTheme.controlHeight)
        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 6))
        .listRowBackground(DCTheme.surface)
    }

    private func filteredModels(from models: [DiscoveredModel], query: String) -> [DiscoveredModel] {
        guard !query.isEmpty else { return models }
        return models.filter { model in
            model.id.localizedCaseInsensitiveContains(query)
                || (model.displayName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func handleConfigurationChange() {
        errorMessage = nil
        showAll = false
        searchQuery = ""
        guard !isFixedList else { return }
        if needsKeyBeforeFetch {
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
            return
        }
        triggerLoad(debounced: true)
    }

    private func triggerLoad(debounced: Bool) {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { @MainActor in
            if debounced {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            let outcome = await app.discoverModels(provider: provider)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success:
                errorMessage = nil
                isLoading = false
            case .failure(let message):
                errorMessage = message
                isLoading = false
            case .stale:
                break
            }
        }
    }
}

/// One row in `ProviderModelsSection`: leading favorite star, display name +
/// mono model ID, active role seals (`Agent`, `Summaries`), and trailing `⋯` Menu.
struct ProviderModelRow: View {
    @ObservedObject var app: AppModel
    let provider: AIProvider
    let model: DiscoveredModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var selection: ModelSelection {
        ModelSelection(provider: provider, model: model.id)
    }

    private var rowKey: String {
        provider.isAppleIntelligence ? "appleIntelligence" : model.id
    }

    private var isStarred: Bool {
        app.isFavorite(selection)
    }

    private var canToggleFavorite: Bool {
        app.isProviderSelectable(provider) || isStarred
    }

    private var activeRoles: [ModelRole] {
        ModelRole.uiRoles.filter { role in
            guard app.hasConfiguredModel(for: role) else { return false }
            let roleSelection = app.selection(for: role)
            if provider.isAppleIntelligence {
                return roleSelection.provider.isAppleIntelligence
            }
            return roleSelection == selection
        }
    }

    private var primaryTitle: String {
        if provider.isAppleIntelligence {
            return String(
                localized: "Foundation Model",
                comment: "Settings › Models › Apple Intelligence: the single built-in model row title"
            )
        }
        return model.title
    }

    private var secondarySubtitle: String? {
        if provider.isAppleIntelligence {
            return String(
                localized: "Private Cloud Compute when available",
                comment: "Settings › Models › Apple Intelligence: subtitle under Foundation Model"
            )
        }
        return model.distinctDisplayName != nil ? model.id : nil
    }

    private var copyableModelName: String {
        provider.isAppleIntelligence ? primaryTitle : model.id
    }

    private var voiceOverLabel: String {
        var parts = [primaryTitle]
        if let secondarySubtitle {
            parts.append(secondarySubtitle)
        }
        if !activeRoles.isEmpty {
            let roleList = activeRoles.map(\.title).joined(separator: ", ")
            parts.append(
                String(
                    localized: "used for \(roleList)",
                    comment: "VoiceOver segment on a provider model row naming the roles using this model, e.g. used for Agent"
                )
            )
        }
        if isStarred {
            parts.append(
                String(
                    localized: "favorite",
                    comment: "VoiceOver segment on a provider model row when the model is starred"
                )
            )
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: DCTheme.space1) {
            starButton
            mainContent
            moreMenu
        }
        .frame(minHeight: DCTheme.controlHeight)
        .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 4))
        .listRowBackground(DCTheme.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(voiceOverLabel))
        .accessibilityAction(
            named: Text("Toggle favorite", comment: "VoiceOver custom action on a provider model row to star or unstar the model")
        ) {
            guard canToggleFavorite else { return }
            DCHaptics.tap()
            app.toggleFavorite(selection)
        }
        .accessibilityIdentifier("modelRow-\(rowKey)")
    }

    private var starButton: some View {
        Button {
            DCHaptics.tap()
            app.toggleFavorite(selection)
        } label: {
            Image(systemName: isStarred ? "star.fill" : "star")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(isStarred ? DCTheme.gold : DCTheme.inkFaint)
                .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canToggleFavorite)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mainContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DCTheme.space1) {
                titleStack
                if !activeRoles.isEmpty {
                    sealsRow
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
        } else {
            HStack(spacing: DCTheme.space2) {
                titleStack
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !activeRoles.isEmpty {
                    sealsRow
                }
            }
            .padding(.vertical, 6)
            .accessibilityHidden(true)
        }
    }

    private var titleStack: some View {
        let wraps = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: primaryTitle)
                .font(DCType.body)
                .foregroundStyle(DCTheme.ink)
                .lineLimit(wraps ? nil : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: wraps)
            if let secondarySubtitle {
                Text(verbatim: secondarySubtitle)
                    .font(provider.isAppleIntelligence ? DCType.footnote : DCType.code)
                    .foregroundStyle(DCTheme.inkMuted)
                    .lineLimit(wraps ? nil : 1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: wraps)
            }
        }
    }

    private var sealsRow: some View {
        HStack(spacing: DCTheme.space1) {
            ForEach(activeRoles) { role in
                DCSeal(
                    text: role.title,
                    variant: role == .browserAgent ? .gold : .outline
                )
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Section {
                useForAgentItem
                useForSummariesItem
            } header: {
                if !provider.isAppleIntelligence {
                    Text(verbatim: model.id)
                }
            }

            Section {
                Button {
                    DCHaptics.tap()
                    app.toggleFavorite(selection)
                } label: {
                    Label(
                        isStarred ? String(localized: "Remove from favorites") : String(localized: "Add to favorites"),
                        systemImage: isStarred ? "star.slash" : "star"
                    )
                }
                .disabled(!canToggleFavorite)

                Button {
                    DCHaptics.tap()
                    UIPasteboard.general.string = copyableModelName
                } label: {
                    Label(
                        String(localized: "Copy model name", comment: "Provider model menu: copies the model identifier to the clipboard"),
                        systemImage: "doc.on.doc"
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(DCTheme.goldInk)
                .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Actions", comment: "VoiceOver action name for a model row's more menu"))
        .accessibilityIdentifier("modelMore-\(rowKey)")
    }

    @ViewBuilder
    private var useForAgentItem: some View {
        let isUsedForAgent = activeRoles.contains(.browserAgent)
        if selection.supportsToolCalling {
            Button {
                DCHaptics.tap()
                app.selectModel(selection, for: .role(.browserAgent))
            } label: {
                if isUsedForAgent {
                    Label(
                        String(localized: "Use for Agent", comment: "Provider model menu: sets this model as the Agent model"),
                        systemImage: "checkmark"
                    )
                } else {
                    Text("Use for Agent", comment: "Provider model menu: sets this model as the Agent model")
                }
            }
        } else {
            Button {} label: {
                Text("Use for Agent", comment: "Provider model menu: sets this model as the Agent model")
                Text(
                    "Needs a tool-calling model",
                    comment: "Provider model menu: subtitle explaining why Use for Agent is disabled"
                )
            }
            .disabled(true)
        }
    }

    @ViewBuilder
    private var useForSummariesItem: some View {
        let isUsedForSummaries = activeRoles.contains(.assistant)
        Button {
            DCHaptics.tap()
            app.selectModel(selection, for: .role(.assistant))
        } label: {
            if isUsedForSummaries {
                Label(
                    String(localized: "Use for Summaries", comment: "Provider model menu: sets this model as the Summaries model"),
                    systemImage: "checkmark"
                )
            } else {
                Text("Use for Summaries", comment: "Provider model menu: sets this model as the Summaries model")
            }
        }
        .disabled(!app.isProviderSelectable(provider))
    }
}
