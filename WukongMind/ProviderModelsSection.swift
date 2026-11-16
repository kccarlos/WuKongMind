import SwiftUI
import UIKit

/// The `Models` section on `ProviderSettingsPage` (`design-browser-bar-tabs-models.md` §3, rows P1 & P2):
/// fetches or displays the provider's models in provider order, pins added-by-name
/// and unlisted active-role models at the top marked `added by name`, shows the five
/// states (Loading, No key yet, Fetch failed, Nothing listed, Loaded), lets the user
/// star favorites in place or add an unlisted model inline by name, shows active role
/// seals (`Agent`, `Summaries`, `Scripts`), and offers the native `⋯` Menu.
struct ProviderModelsSection: View {
    static let initialVisibleCount = 6
    static let searchThreshold = 20
    static let stateRowScrollID = "providerModelsStateRow"
    static let searchRowScrollID = "providerModelsSearchRow"

    @MainActor
    static func scrollTargetID(for provider: AIProvider, in app: AppModel) -> String {
        if provider.isAppleIntelligence {
            return "modelRow-appleIntelligence"
        }
        let isFixed = provider == .vertexAI
        let trimmedKey = app.settings.configuration(for: provider).apiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let needsKey = provider.requiresAPIKey && !isFixed && trimmedKey.isEmpty
        let resolved: [DiscoveredModel] = if isFixed {
            AIProvider.vertexAIModels.map { DiscoveredModel(id: $0) }
        } else {
            app.discoveredModels[provider] ?? []
        }
        let hasCached = isFixed || app.discoveredModels[provider] != nil
        let pinned = app.pinnedAddedModelIDs(
            for: provider,
            fetchedIDs: hasCached ? Set(resolved.map(\.id)) : nil
        )
        if needsKey || !hasCached {
            return pinned.first.map { "modelRow-\($0)" } ?? stateRowScrollID
        }
        let pinnedSet = Set(pinned)
        let allIDs = pinned + resolved.map(\.id).filter { !pinnedSet.contains($0) }
        if allIDs.isEmpty {
            return stateRowScrollID
        }
        if allIDs.count > searchThreshold {
            return searchRowScrollID
        }
        return "modelRow-\(allIDs[0])"
    }

    @ObservedObject var app: AppModel
    let provider: AIProvider

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showAll = false
    @State private var searchQuery = ""
    @State private var isAddingModel = false
    @State private var newModelName = ""
    @FocusState private var isAddFieldFocused: Bool
    @State private var loadTask: Task<Void, Never>?
    @State private var loadID = UUID()
    @State private var accessibilityActionItem: ListedProviderModel?

    fileprivate struct ListedProviderModel: Identifiable, Equatable {
        let provider: AIProvider
        let model: DiscoveredModel
        let isAddedByName: Bool

        var id: String {
            "modelRow-\(provider.isAppleIntelligence ? "appleIntelligence" : model.id)"
        }
    }

    private var configuration: ProviderConfiguration {
        app.settings.configuration(for: provider)
    }

    private var trimmedAPIKey: String {
        configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNewModelName: String {
        newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private var showsAddByNameRow: Bool {
        !provider.isAppleIntelligence
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

    private var pinnedRows: [ListedProviderModel] {
        let fetchedIDs: Set<String>? = hasCachedResult ? Set(resolvedModels.map(\.id)) : nil
        return app.pinnedAddedModelIDs(for: provider, fetchedIDs: fetchedIDs).map {
            ListedProviderModel(provider: provider, model: DiscoveredModel(id: $0), isAddedByName: true)
        }
    }

    private func combinedRows(with fetched: [DiscoveredModel]) -> [ListedProviderModel] {
        let pinned = pinnedRows
        let pinnedModelIDs = Set(pinned.map(\.model.id))
        let remaining = fetched
            .filter { !pinnedModelIDs.contains($0.id) }
            .map { ListedProviderModel(provider: provider, model: $0, isAddedByName: false) }
        return pinned + remaining
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
            sectionRows
        } header: {
            header
        } footer: {
            sectionFooter
        }
        .onAppear {
            if !isFixedList && !needsKeyBeforeFetch && app.discoveredModels[provider] == nil {
                triggerLoad(debounced: false)
            }
        }
        .onChange(of: configuration.apiKey) {
            handleConfigurationChange()
        }
        .onChange(of: configuration.baseURL) {
            handleConfigurationChange()
        }
        .onChange(of: hasCachedResult) { _, hasCached in
            if hasCached {
                errorMessage = nil
                if loadTask == nil {
                    isLoading = false
                }
            } else if !isFixedList && !needsKeyBeforeFetch && loadTask == nil {
                triggerLoad(debounced: false)
            }
        }
        .onChange(of: isAddFieldFocused) { _, focused in
            if !focused && trimmedNewModelName.isEmpty {
                isAddingModel = false
            }
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            loadID = UUID()
            isLoading = false
            if trimmedNewModelName.isEmpty {
                isAddingModel = false
            }
        }
        .confirmationDialog(
            Text(verbatim: dialogTitle(for: accessibilityActionItem?.model)),
            isPresented: Binding(
                get: { accessibilityActionItem != nil },
                set: { if !$0 { accessibilityActionItem = nil } }
            ),
            presenting: accessibilityActionItem,
            actions: { item in
                accessibilityDialogItems(for: item)
            }
        )
    }

    @ViewBuilder
    private var sectionRows: some View {
        let pinned = pinnedRows
        switch state {
        case .loading:
            if !pinned.isEmpty {
                pinnedModelRows(pinned)
            }
            loadingRow
                .id(Self.stateRowScrollID)
            if showsAddByNameRow && isAddingModel {
                addModelRow
            }
        case .noKey:
            if !pinned.isEmpty {
                pinnedModelRows(pinned)
            }
            noKeyRow
                .id(Self.stateRowScrollID)
            if showsAddByNameRow {
                addModelRow
            }
        case .failed(let message):
            if !pinned.isEmpty {
                pinnedModelRows(pinned)
            }
            failedRow(message: message)
                .id(Self.stateRowScrollID)
            if showsAddByNameRow {
                addModelRow
            }
        case .empty:
            if pinned.isEmpty {
                emptyRow
                    .id(Self.stateRowScrollID)
            } else {
                loadedRows(allRows: pinned)
            }
            if showsAddByNameRow {
                addModelRow
            }
        case .loaded(let models):
            loadedRows(allRows: combinedRows(with: models))
            if showsAddByNameRow {
                addModelRow
            }
        }
    }

    @ViewBuilder
    private func pinnedModelRows(_ items: [ListedProviderModel]) -> some View {
        ForEach(items) { item in
            ProviderModelRow(
                app: app,
                provider: provider,
                model: item.model,
                isAddedByName: item.isAddedByName,
                onShowAccessibilityActions: { accessibilityActionItem = item }
            )
        }
    }

    private func dialogTitle(for model: DiscoveredModel?) -> String {
        guard let model else { return "" }
        if provider.isAppleIntelligence {
            return String(
                localized: "Foundation Model",
                comment: "Settings › Models › Apple Intelligence: the single built-in model row title"
            )
        }
        return model.id
    }

    @ViewBuilder
    private func accessibilityDialogItems(for item: ListedProviderModel) -> some View {
        let model = item.model
        let selection = ModelSelection(provider: provider, model: model.id)
        let isStarred = app.isFavorite(selection)
        let canToggleFavorite = app.isProviderSelectable(provider) || isStarred
        let activeRoles = app.activeRoles(using: selection)
        let copyableName = provider.isAppleIntelligence ? dialogTitle(for: model) : model.id

        let agentTitle = String(localized: "Use for Agent", comment: "Provider model menu: sets this model as the Agent model")
        if selection.supportsToolCalling {
            Button {
                DCHaptics.tap()
                app.selectModel(selection, for: .role(.browserAgent))
            } label: {
                if activeRoles.contains(.browserAgent) {
                    Label(agentTitle, systemImage: "checkmark")
                } else {
                    Text(verbatim: agentTitle)
                }
            }
            .disabled(!app.isProviderSelectable(provider))
        } else {
            let reason = String(localized: "Needs a tool-calling model", comment: "Provider model menu: subtitle explaining why Use for Agent is disabled")
            Button {} label: {
                Text(verbatim: "\(agentTitle) — \(reason)")
            }
            .disabled(true)
        }

        let summariesTitle = String(localized: "Use for Summaries", comment: "Provider model menu: sets this model as the Summaries model")
        Button {
            DCHaptics.tap()
            app.selectModel(selection, for: .role(.assistant))
        } label: {
            if activeRoles.contains(.assistant) {
                Label(summariesTitle, systemImage: "checkmark")
            } else {
                Text(verbatim: summariesTitle)
            }
        }
        .disabled(!app.isProviderSelectable(provider))

        let scriptsTitle = String(localized: "Use for Scripts", comment: "Provider model menu: sets this model as the Scripts model")
        Button {
            DCHaptics.tap()
            app.selectModel(selection, for: .role(.scripts))
        } label: {
            if activeRoles.contains(.scripts) {
                Label(scriptsTitle, systemImage: "checkmark")
            } else {
                Text(verbatim: scriptsTitle)
            }
        }
        .disabled(!app.isProviderSelectable(provider))

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
            UIPasteboard.general.string = copyableName
        } label: {
            Label(
                String(localized: "Copy model name", comment: "Provider model menu: copies the model identifier to the clipboard"),
                systemImage: "doc.on.doc"
            )
        }

        if item.isAddedByName {
            let removeTitle = String(localized: "Remove")
            if activeRoles.isEmpty {
                Button(role: .destructive) {
                    DCHaptics.tap()
                    app.removeCustomModel(model.id, for: provider)
                } label: {
                    Label(removeTitle, systemImage: "trash")
                }
            } else {
                let roleList = activeRoles.map(\.title).joined(separator: ", ")
                let usedReason = String(
                    localized: "Used for \(roleList)",
                    comment: "Provider settings: the model roles that use this provider, e.g. Summaries & chat, Ask the forum"
                )
                Button(role: .destructive) {} label: {
                    Text(verbatim: "\(removeTitle) — \(usedReason)")
                }
                .disabled(true)
            }
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
    private var sectionFooter: some View {
        if isAddingModel {
            Text(
                "Type the exact model ID your provider uses.",
                comment: "Provider settings › Models: footer shown while typing an unlisted model ID by name"
            )
        } else if case .loaded = state {
            footer
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
    private func loadedRows(allRows: [ListedProviderModel]) -> some View {
        let showsSearch = allRows.count > Self.searchThreshold
        if showsSearch {
            searchRow
                .id(Self.searchRowScrollID)
        }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = filteredRows(from: allRows, query: trimmedQuery)

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

            ForEach(visible) { item in
                ProviderModelRow(
                    app: app,
                    provider: provider,
                    model: item.model,
                    isAddedByName: item.isAddedByName,
                    onShowAccessibilityActions: { accessibilityActionItem = item }
                )
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

    @ViewBuilder
    private var addModelRow: some View {
        if isAddingModel {
            HStack(spacing: DCTheme.space2) {
                TextField(
                    String(localized: "Model ID", comment: "Provider settings › Models: placeholder in the inline add-model-by-name text field"),
                    text: $newModelName
                )
                .font(DCType.subheadline.monospaced())
                .foregroundStyle(DCTheme.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .focused($isAddFieldFocused)
                .onSubmit {
                    submitAddedModel()
                }
                .frame(minHeight: DCTheme.controlHeight)
                .accessibilityIdentifier("addModelByNameField")

                Button {
                    submitAddedModel()
                } label: {
                    Text("Add")
                        .font(DCType.subheadline.weight(.semibold))
                        .foregroundStyle(trimmedNewModelName.isEmpty ? DCTheme.inkFaint : DCTheme.goldInk)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(
                            DCTheme.goldWash.opacity(trimmedNewModelName.isEmpty ? 0.5 : 1),
                            in: RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous)
                        )
                        .frame(minHeight: DCTheme.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(trimmedNewModelName.isEmpty)
                .accessibilityIdentifier("confirmAddModelByName")
            }
            .frame(minHeight: DCTheme.controlHeight)
            .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 8))
            .listRowBackground(DCTheme.surface)
        } else {
            Button {
                DCHaptics.tap()
                isAddingModel = true
                isAddFieldFocused = true
            } label: {
                HStack(spacing: DCTheme.space1) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(DCTheme.goldInk)
                        .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                        .accessibilityHidden(true)
                    Text(
                        "Add a model by name…",
                        comment: "Provider settings › Models: row button that turns into an inline text field to add a model ID"
                    )
                    .font(DCType.body)
                    .foregroundStyle(DCTheme.goldInk)
                    .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 14))
            .listRowBackground(DCTheme.surface)
            .accessibilityIdentifier("addModelByNameButton")
        }
    }

    private func submitAddedModel() {
        let trimmed = trimmedNewModelName
        guard !trimmed.isEmpty else {
            isAddingModel = false
            isAddFieldFocused = false
            return
        }
        DCHaptics.tap()
        app.addCustomModel(trimmed, for: provider)
        newModelName = ""
        searchQuery = ""
        isAddingModel = false
        isAddFieldFocused = false
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

    private func filteredRows(from items: [ListedProviderModel], query: String) -> [ListedProviderModel] {
        guard !query.isEmpty else { return items }
        return items.filter { item in
            item.model.id.localizedCaseInsensitiveContains(query)
                || (item.model.displayName?.localizedCaseInsensitiveContains(query) ?? false)
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
            loadID = UUID()
            isLoading = false
            return
        }
        triggerLoad(debounced: true)
    }

    private func triggerLoad(debounced: Bool) {
        loadTask?.cancel()
        let currentID = UUID()
        loadID = currentID
        isLoading = true
        errorMessage = nil
        loadTask = Task { @MainActor in
            if debounced {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, loadID == currentID else { return }
            }
            let outcome = await app.discoverModels(provider: provider)
            guard !Task.isCancelled, loadID == currentID else { return }
            loadTask = nil
            switch outcome {
            case .success:
                errorMessage = nil
                isLoading = false
            case .failure(let message):
                errorMessage = message
                isLoading = false
            case .stale:
                if !needsKeyBeforeFetch && app.discoveredModels[provider] == nil {
                    triggerLoad(debounced: true)
                } else {
                    isLoading = false
                }
            }
        }
    }
}

/// One row in `ProviderModelsSection`: leading favorite star, display name +
/// mono model ID (or `added by name`), active role seals, and trailing `⋯` Menu.
struct ProviderModelRow: View {
    @ObservedObject var app: AppModel
    let provider: AIProvider
    let model: DiscoveredModel
    var isAddedByName = false
    let onShowAccessibilityActions: () -> Void

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
        app.activeRoles(using: selection)
    }

    private var primaryTitle: String {
        if provider.isAppleIntelligence {
            return String(
                localized: "Foundation Model",
                comment: "Settings › Models › Apple Intelligence: the single built-in model row title"
            )
        }
        if isAddedByName {
            return model.id
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
        if isAddedByName {
            return String(
                localized: "added by name",
                comment: "Provider settings › Models: subtitle under a model pinned because it was added by name"
            )
        }
        return model.distinctDisplayName != nil ? model.id : nil
    }

    private var copyableModelName: String {
        provider.isAppleIntelligence ? primaryTitle : model.id
    }

    private var usedByRolesReason: String? {
        guard !activeRoles.isEmpty else { return nil }
        let roleList = activeRoles.map(\.title).joined(separator: ", ")
        return String(
            localized: "Used for \(roleList)",
            comment: "Provider settings: the model roles that use this provider, e.g. Summaries & chat, Ask the forum"
        )
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(voiceOverLabel))
        .accessibilityAction(
            named: Text("Toggle favorite", comment: "VoiceOver custom action on a provider model row to star or unstar the model")
        ) {
            guard canToggleFavorite else { return }
            DCHaptics.tap()
            app.toggleFavorite(selection)
        }
        .accessibilityAction(
            named: Text("Actions", comment: "VoiceOver action name for a model row's more menu")
        ) {
            DCHaptics.tap()
            onShowAccessibilityActions()
        }
        .accessibilityIdentifier("modelRow-\(rowKey)")
    }

    private var starButton: some View {
        Image(systemName: isStarred ? "star.fill" : "star")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(isStarred ? DCTheme.gold : DCTheme.inkFaint)
            .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canToggleFavorite else { return }
                DCHaptics.tap()
                app.toggleFavorite(selection)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mainContent: some View {
        if dynamicTypeSize.isAccessibilitySize || activeRoles.count > 1 {
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
        .fixedSize(horizontal: true, vertical: false)
    }

    private var moreMenu: some View {
        ProviderModelMoreMenuButton(
            headerTitle: provider.isAppleIntelligence ? "" : model.id,
            supportsToolCalling: selection.supportsToolCalling,
            isProviderSelectable: app.isProviderSelectable(provider),
            isUsedForAgent: activeRoles.contains(.browserAgent),
            isUsedForSummaries: activeRoles.contains(.assistant),
            isUsedForScripts: activeRoles.contains(.scripts),
            isStarred: isStarred,
            canToggleFavorite: canToggleFavorite,
            isAddedByName: isAddedByName,
            usedByRolesReason: usedByRolesReason,
            onSelectRole: { role in
                app.selectModel(selection, for: .role(role))
            },
            onToggleFavorite: {
                app.toggleFavorite(selection)
            },
            onCopyModelName: {
                UIPasteboard.general.string = copyableModelName
            },
            onRemove: {
                app.removeCustomModel(model.id, for: provider)
            }
        )
        .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
        .accessibilityHidden(true)
    }
}

/// Native `UIMenu` button hidden from VoiceOver (`accessibilityElementsHidden = true`)
/// so `ProviderModelRow` stays a single VoiceOver focus stop (whose `Actions`
/// custom action opens the same items) without SwiftUI `Form` splitting the row.
private struct ProviderModelMoreMenuButton: UIViewRepresentable {
    let headerTitle: String
    let supportsToolCalling: Bool
    let isProviderSelectable: Bool
    let isUsedForAgent: Bool
    let isUsedForSummaries: Bool
    let isUsedForScripts: Bool
    let isStarred: Bool
    let canToggleFavorite: Bool
    let isAddedByName: Bool
    let usedByRolesReason: String?
    let onSelectRole: @MainActor (ModelRole) -> Void
    let onToggleFavorite: @MainActor () -> Void
    let onCopyModelName: @MainActor () -> Void
    let onRemove: @MainActor () -> Void

    func makeUIView(context: Context) -> AccessibilityHiddenMenuContainer {
        AccessibilityHiddenMenuContainer()
    }

    func updateUIView(_ uiView: AccessibilityHiddenMenuContainer, context: Context) {
        uiView.button.tintColor = UIColor(DCTheme.goldInk)
        uiView.button.menu = makeMenu()
    }

    private func makeMenu() -> UIMenu {
        let selectRole = onSelectRole
        let toggleFavorite = onToggleFavorite
        let copyModelName = onCopyModelName
        let removeModel = onRemove

        let agentTitle = String(localized: "Use for Agent", comment: "Provider model menu: sets this model as the Agent model")
        let agentAction: UIAction
        if supportsToolCalling {
            agentAction = UIAction(
                title: agentTitle,
                attributes: isProviderSelectable ? [] : .disabled,
                state: isUsedForAgent ? .on : .off
            ) { _ in
                Task { @MainActor in
                    DCHaptics.tap()
                    selectRole(.browserAgent)
                }
            }
        } else {
            let reason = String(
                localized: "Needs a tool-calling model",
                comment: "Provider model menu: subtitle explaining why Use for Agent is disabled"
            )
            let disabled = UIAction(title: agentTitle, attributes: .disabled) { _ in }
            disabled.subtitle = reason
            agentAction = disabled
        }

        let summariesTitle = String(localized: "Use for Summaries", comment: "Provider model menu: sets this model as the Summaries model")
        let summariesAction = UIAction(
            title: summariesTitle,
            attributes: isProviderSelectable ? [] : .disabled,
            state: isUsedForSummaries ? .on : .off
        ) { _ in
            Task { @MainActor in
                DCHaptics.tap()
                selectRole(.assistant)
            }
        }

        let scriptsTitle = String(localized: "Use for Scripts", comment: "Provider model menu: sets this model as the Scripts model")
        let scriptsAction = UIAction(
            title: scriptsTitle,
            attributes: isProviderSelectable ? [] : .disabled,
            state: isUsedForScripts ? .on : .off
        ) { _ in
            Task { @MainActor in
                DCHaptics.tap()
                selectRole(.scripts)
            }
        }

        let favoriteAction = UIAction(
            title: isStarred
                ? String(localized: "Remove from favorites")
                : String(localized: "Add to favorites"),
            image: UIImage(systemName: isStarred ? "star.slash" : "star"),
            attributes: canToggleFavorite ? [] : .disabled
        ) { _ in
            Task { @MainActor in
                DCHaptics.tap()
                toggleFavorite()
            }
        }

        let copyAction = UIAction(
            title: String(localized: "Copy model name", comment: "Provider model menu: copies the model identifier to the clipboard"),
            image: UIImage(systemName: "doc.on.doc")
        ) { _ in
            Task { @MainActor in
                DCHaptics.tap()
                copyModelName()
            }
        }

        let roleSection = UIMenu(title: "", options: .displayInline, children: [agentAction, summariesAction, scriptsAction])
        let utilitySection = UIMenu(title: "", options: .displayInline, children: [favoriteAction, copyAction])
        var sections = [roleSection, utilitySection]

        if isAddedByName {
            let removeTitle = String(localized: "Remove")
            let removeAction: UIAction
            if let usedByRolesReason {
                let disabled = UIAction(
                    title: removeTitle,
                    image: UIImage(systemName: "trash"),
                    attributes: [.destructive, .disabled]
                ) { _ in }
                disabled.subtitle = usedByRolesReason
                removeAction = disabled
            } else {
                removeAction = UIAction(
                    title: removeTitle,
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in
                    Task { @MainActor in
                        DCHaptics.tap()
                        removeModel()
                    }
                }
            }
            sections.append(UIMenu(title: "", options: .displayInline, children: [removeAction]))
        }

        return UIMenu(title: headerTitle, children: sections)
    }
}

private final class NonAccessibleMenuButton: UIButton {
    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }
}

private final class AccessibilityHiddenMenuContainer: UIView {
    let button = NonAccessibleMenuButton(type: .system)

    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityElementsHidden = true
        button.accessibilityElementsHidden = true
        button.showsMenuAsPrimaryAction = true
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        button.setImage(UIImage(systemName: "ellipsis.circle", withConfiguration: symbolConfig), for: .normal)
        button.imageView?.isAccessibilityElement = false
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
