import SwiftUI
import UIKit

// MARK: - Address editing state & local suggestions (design-motion.md §3, task 5)

/// Isolated observable state for the active address bar draft so typing does
/// not republish `ForumBrowserModel` and re-evaluate unrelated browser chrome.
@MainActor
final class AddressEditState: ObservableObject {
    @Published var draft: String = ""
    /// The page URL string when editing began (empty on an empty tab).
    /// Suggestions show only once `draft` is non-empty and differs from this.
    var initialText: String = ""

    var showsSuggestions: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && draft != initialText
    }

    func begin(initialText: String) {
        self.initialText = initialText
        if draft != initialText {
            draft = initialText
        }
    }

    func end() {
        initialText = ""
        if !draft.isEmpty {
            draft = ""
        }
    }
}

/// One row in the local address suggestion list. Row 1 is always what Return runs.
enum AddressSuggestionRow: Identifiable, Equatable {
    case action(AddressInput.Action)
    case site(HomeSite)

    var id: String {
        switch self {
        case .action(.open(let url)): "action-open-\(url.absoluteString)"
        case .action(.askAgent(let prompt)): "action-ask-\(prompt)"
        case .action(.forumSearch(let url)): "action-forum-\(url.absoluteString)"
        case .action(.webSearch(let url)): "action-web-\(url.absoluteString)"
        case .site(let site): "site-\(site.id)"
        }
    }
}

enum AddressSuggestionsBuilder {
    static let limit = 6

    /// Builds at most `limit` local suggestion rows: classified actions first,
    /// followed by matching sites from `HomeSites.matches`. Never hits the network.
    static func rows(
        for rawText: String,
        context: AddressInput.Context,
        tiles: [HomeSite],
        limit: Int = limit
    ) -> [AddressSuggestionRow] {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, limit > 0 else { return [] }

        let actions = AddressInput.actions(for: text, context: context)
        var result: [AddressSuggestionRow] = actions.prefix(limit).map { .action($0) }
        let remaining = limit - result.count
        guard remaining > 0 else { return result }

        let matches = PerfProbe.time("HomeSites.matches") {
            HomeSites.matches(tiles, for: text, limit: remaining)
        }
        result.append(contentsOf: matches.map { .site($0) })
        return result
    }
}

enum AddressSuggestionAnnouncement {
    /// Returns a short VoiceOver announcement when the kind of row 1 changes,
    /// or `nil` when unchanged (so VoiceOver never speaks on every keystroke).
    static func message(
        from previous: AddressInput.ActionKind?,
        to current: AddressInput.ActionKind?
    ) -> String? {
        guard let current, current != previous else { return nil }
        switch current {
        case .askAgent:
            return String(localized: "Return asks the Agent", comment: "VoiceOver announcement when Return in the address bar will ask the Agent")
        case .open:
            return String(localized: "Return opens address", comment: "VoiceOver announcement when Return in the address bar will open a web address")
        case .forumSearch:
            return String(localized: "Return searches this site", comment: "VoiceOver announcement when Return in the address bar will search the current site")
        case .webSearch:
            return String(localized: "Return searches the web", comment: "VoiceOver announcement when Return in the address bar will search the web")
        }
    }
}

struct AddressSuggestionsList: View {
    let app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var editState: AddressEditState
    @ObservedObject var siteVisits: SiteVisitStore
    let actions: BrowserActions

    @State private var lastDefaultKind: AddressInput.ActionKind?

    private var trimmedDraft: String {
        editState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rows: [AddressSuggestionRow] {
        let tiles = HomeSites.tiles(forums: app.forums, visits: siteVisits.shownVisits)
        return AddressSuggestionsBuilder.rows(
            for: editState.draft,
            context: app.addressInputContext(for: browser),
            tiles: tiles
        )
    }

    private var defaultKind: AddressInput.ActionKind? {
        if case .action(let action) = rows.first {
            return action.kind
        }
        return nil
    }

    var body: some View {
        let _ = PerfProbe.hit("AddressSuggestionsList.body")
        let currentRows = rows
        let query = trimmedDraft
        let forumName = app.currentForumDisplayName(for: browser)
        let engineName = app.settings.searchEngine.displayName

        ScrollView {
            if !currentRows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(currentRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 48)
                        }
                        rowButton(
                            row,
                            isDefault: index == 0,
                            query: query,
                            forumName: forumName,
                            engineName: engineName
                        )
                        .padding(.horizontal, DCTheme.spacingM)
                        .padding(.vertical, 10)
                    }
                }
                .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
                .padding(.horizontal, DCTheme.spacingM)
                .padding(.top, DCTheme.spacingS)
                .padding(.bottom, DCTheme.spacingM)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .modifier(HomeScrollKeyboardDismiss(isEditingAddress: browser.isEditingAddress))
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(DCTheme.pageBackground)
        .accessibilityIdentifier("addressSuggestions")
        .onChange(of: defaultKind, initial: true) { _, next in
            if let message = AddressSuggestionAnnouncement.message(from: lastDefaultKind, to: next) {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
            lastDefaultKind = next
        }
    }

    @ViewBuilder
    private func rowButton(
        _ row: AddressSuggestionRow,
        isDefault: Bool,
        query: String,
        forumName: String,
        engineName: String
    ) -> some View {
        switch row {
        case .action(let action):
            let title = actionTitle(for: action, query: query, forumName: forumName, engineName: engineName)
            Button {
                DCHaptics.tap()
                app.performAddressAction(action, in: browser)
            } label: {
                HStack(spacing: DCTheme.spacingM) {
                    actionIcon(for: action)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    Text(verbatim: title)
                        .font(isDefault ? .body.weight(.medium) : .body)
                        .foregroundStyle(DCTheme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(actionIdentifier(for: action))

        case .site(let site):
            Button {
                openSite(site)
            } label: {
                HStack(spacing: DCTheme.spacingM) {
                    ForumIcon(siteURL: site.siteURL, name: site.name, iconURL: site.iconURL, size: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: site.name)
                            .font(.body)
                            .foregroundStyle(DCTheme.ink)
                            .lineLimit(1)
                        Text(verbatim: site.host)
                            .font(.footnote)
                            .foregroundStyle(DCTheme.inkMuted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Open \(site.name)", comment: "Address bar suggestion: open a matching site"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("addressSuggestion-site-\(site.host)")
        }
    }

    @ViewBuilder
    private func actionIcon(for action: AddressInput.Action) -> some View {
        switch action {
        case .open:
            Image(systemName: "globe")
                .font(.body)
                .foregroundStyle(DCTheme.inkMuted)
        case .askAgent:
            DCAgentRing(size: 16, lineWidth: DCTheme.ringWidth)
        case .forumSearch, .webSearch:
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(DCTheme.inkMuted)
        }
    }

    private func actionTitle(
        for action: AddressInput.Action,
        query: String,
        forumName: String,
        engineName: String
    ) -> String {
        switch action {
        case .open(let url):
            let display = BrowserAddress.display(url)
            let target = display.isEmpty ? url.absoluteString : display
            return String(localized: "Open \(target)", comment: "Address bar suggestion: open a web address")
        case .askAgent(let prompt):
            return String(localized: "Ask the Agent: “\(prompt)”", comment: "Address bar suggestion: ask the Agent about the current page")
        case .forumSearch:
            return String(localized: "Search \(forumName) for “\(query)”", comment: "Address bar suggestion: search the current site")
        case .webSearch:
            return String(localized: "Search \(engineName) for “\(query)”", comment: "Address bar suggestion: search the web with the chosen search engine")
        }
    }

    private func actionIdentifier(for action: AddressInput.Action) -> String {
        switch action {
        case .open: "addressSuggestion-open"
        case .askAgent: "addressSuggestion-askAgent"
        case .forumSearch: "addressSuggestion-forumSearch"
        case .webSearch: "addressSuggestion-webSearch"
        }
    }

    private func openSite(_ site: HomeSite) {
        DCHaptics.tap()
        browser.setEditingAddress(false)
        app.router.addressEditRevision &+= 1
        if let forum = site.forum {
            actions.openForum(forum)
        } else if let url = site.url {
            siteVisits.noteVisit(siteURL: site.siteURL, name: site.name, isForum: false)
            app.browser.load(url)
        }
    }
}

extension AppModel {
    func addressInputContext(for browser: ForumBrowserModel) -> AddressInput.Context {
        AddressInput.Context(
            currentSiteURL: browser.homeSiteURL,
            canAskAgent: !browser.showsForumsHome,
            forumSearchURL: browser.showsForumsHome ? nil : { [weak self] in self?.searchPageURL(query: $0) },
            webSearchURL: { [weak self] in self?.webSearchURL(query: $0) }
        )
    }

    func currentForumDisplayName(for browser: ForumBrowserModel) -> String {
        guard let siteURL = browser.homeSiteURL else { return "" }
        if let forum = forum(for: siteURL) {
            return forum.displayName
        }
        return HomeSites.displayName(forOrigin: siteURL)
    }

    func performAddressAction(_ action: AddressInput.Action, in browser: ForumBrowserModel) {
        switch action {
        case .open(let url), .forumSearch(let url), .webSearch(let url):
            browser.load(url)
            browser.setEditingAddress(false)
            router.addressEditRevision &+= 1
        case .askAgent(let prompt):
            askAgentFromAddressBar(prompt, in: browser)
        }
    }

    /// Closes address editing, opens the AI panel, and sends `prompt` through
    /// the composer's normal send path (provider setup card when unconfigured,
    /// run-limit check, and AI data consent backstop).
    func askAgentFromAddressBar(_ prompt: String, in browser: ForumBrowserModel) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !browser.showsForumsHome else { return }
        browser.setEditingAddress(false)
        router.addressEditRevision &+= 1
        showAIView()
        guard isProviderReady(for: .browserAgent) else {
            router.pendingProviderSetup = true
            return
        }
        guard browserAgent.checkRunStartGate() else {
            if let notice = browserAgent.runLimitNotice {
                UIAccessibility.post(notification: .announcement, argument: notice)
            }
            return
        }
        browserAgent.send(trimmed)
    }
}
