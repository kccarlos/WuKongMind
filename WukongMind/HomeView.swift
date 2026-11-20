import SwiftUI

// MARK: - Home, the start page (design-unified.md §3)
//
// Fixed order: the address field, Sites (pinned first, then most visited;
// forums are just sites, with the grey badge only here), Recent (the newest
// History items), Continue reading and Following. With no sites yet: the
// address field and a card of three suggested sites. Shown over the web view
// (BrowserContent), which stays loaded under it.

struct HomeView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    let actions: BrowserActions

    init(app: AppModel, actions: BrowserActions) {
        self.app = app
        browser = app.browser
        self.actions = actions
    }

    var body: some View {
        HomeList(app: app, browser: browser, siteVisits: app.siteVisits, actions: actions)
    }
}

private struct HomeList: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var siteVisits: SiteVisitStore
    let actions: BrowserActions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var forumToRemove: Forum?
    @State private var addressText = ""
    @FocusState private var addressFocused: Bool

    private var tiles: [HomeSite] { HomeSites.tiles(forums: app.forums, visits: siteVisits.shownVisits) }

    var body: some View {
        let _ = PerfProbe.hit("HomeList.body")
        let tiles = tiles
        List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: DCTheme.spacingS, leading: 4, bottom: 0, trailing: 4))

            addressSection(tiles: tiles)

            if tiles.isEmpty {
                suggestedCard
            } else {
                sitesSection(tiles)
            }
            recentSection
            continueReadingSection
            followingSection
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.top, DCTheme.spacingXS, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(DCTheme.pageBackground)
        .accessibilityIdentifier("home")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: DCTheme.spacingS) {
            Text("Home", comment: "Title of the Home screen")
                .font(DCType.largeTitle)
                .foregroundStyle(DCTheme.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("homeHeader")
            Spacer(minLength: 0)
            headerButton("clock.arrow.circlepath", Text("History", comment: "Home button: the history of conversations and results"), id: "homeHistory", action: actions.openHistory)
            headerButton("gearshape", Text("Settings"), id: "homeSettings", action: actions.openSettings)
        }
        .padding(.bottom, DCTheme.spacingXS)
    }

    private func headerButton(_ symbol: String, _ label: Text, id: String, action: @escaping () -> Void) -> some View {
        Button {
            DCHaptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(minWidth: DCTheme.controlHeight, minHeight: DCTheme.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .foregroundStyle(DCTheme.ink)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: Address field

    /// The only address entry on Home (the bar hides its own while Home shows).
    /// Text that is not an address searches with Settings › Browser › Search
    /// engine; while typing, the sites that match are offered.
    @ViewBuilder
    private func addressSection(tiles: [HomeSite]) -> some View {
        Section {
            HStack(spacing: DCTheme.spacingS) {
                Image(systemName: "magnifyingglass")
                    .font(.body)
                    .foregroundStyle(DCTheme.inkFaint)
                    .accessibilityHidden(true)
                TextField(text: $addressText, prompt: Text("Search or enter address", comment: "Home address field placeholder").foregroundStyle(DCTheme.inkFaint)) {
                    Text("Address", comment: "Accessibility label of Home's address field")
                }
                .textContentType(.URL)
                .keyboardType(.webSearch)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit(submitAddress)
                .onChange(of: addressText) { _, _ in
                    PerfProbe.mark("address.keystroke")
                }
                .foregroundStyle(DCTheme.ink)
                .accessibilityIdentifier("homeAddress")
                if !addressText.isEmpty {
                    Button {
                        addressText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DCTheme.inkFaint)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear address")
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: DCTheme.controlHeight)
            .background(DCTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: DCTheme.spacingXS, leading: 0, bottom: DCTheme.spacingXS, trailing: 0))

            if addressFocused {
                let matches = PerfProbe.time("HomeSites.matches") {
                    HomeSites.matches(tiles, for: addressText)
                }
                ForEach(matches) { site in
                    Button { open(site) } label: {
                        HStack(spacing: DCTheme.spacingM) {
                            ForumIcon(siteURL: site.siteURL, name: site.name, iconURL: site.iconURL, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(site.name).font(.subheadline.weight(.semibold)).foregroundStyle(DCTheme.ink).lineLimit(1)
                                Text(site.host).font(.caption).foregroundStyle(DCTheme.inkMuted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DCTheme.surface)
                    .accessibilityIdentifier("homeMatch-\(site.host)")
                }
            }
        }
    }

    private func submitAddress() {
        let context = AddressInput.Context(
            currentSiteURL: browser.homeSiteURL,
            forumSearchURL: nil,
            webSearchURL: { app.webSearchURL(query: $0) }
        )
        guard let action = AddressInput.actions(for: addressText, context: context).first else { return }
        browser.load(action.url)
        finishAddress()
    }

    private func finishAddress() {
        addressFocused = false
        addressText = ""
    }

    // MARK: Sites

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return Array(repeating: GridItem(.flexible(), spacing: DCTheme.spacingS, alignment: .top), count: 2)
        }
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 88), spacing: DCTheme.spacingS, alignment: .top)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: DCTheme.spacingS, alignment: .top), count: 4)
    }

    private func sitesSection(_ tiles: [HomeSite]) -> some View {
        Section {
            LazyVGrid(columns: columns, alignment: .center, spacing: DCTheme.spacingL) {
                ForEach(tiles) { site in
                    siteButton(site)
                }
                Button(action: actions.addForum) {
                    SiteTileLabel(title: String(localized: "Add", comment: "Home's last site tile: add a site")) { size in
                        RoundedRectangle(cornerRadius: size * DCTheme.forumIconCornerRatio, style: .continuous)
                            .fill(DCTheme.surfaceRaised)
                            .frame(width: size, height: size)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: size * 0.4, weight: .semibold))
                                    .foregroundStyle(DCTheme.goldInk)
                            }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a site")
                .accessibilityIdentifier("homeAddSite")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: DCTheme.spacingXS, leading: 0, bottom: DCTheme.spacingXS, trailing: 0))
        } header: {
            sectionTitle("Sites", comment: "Home section: pinned and most visited sites")
        }
    }

    @ViewBuilder
    private func siteButton(_ site: HomeSite) -> some View {
        let button = Button { open(site) } label: {
            SiteTile(site: site, isCurrent: isCurrent(site))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .contextMenu { siteMenu(site) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(site.name)
        .accessibilityValue(site.host)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: site.isPinned ? "Unpin" : "Pin") { togglePin(site) }
        .accessibilityAction(named: "Remove") { confirmRemoval(site) }
        .accessibilityIdentifier("siteTile-\(site.host)")
        // A new identity when the pin changes, so the menu is built afresh.
        .id("\(site.siteURL)-\(site.isPinned)")
        if let forum = site.forum {
            // The dialog is a popover on iPad; anchor it to this tile.
            button.forumRemovalDialog($forumToRemove, app: app, for: forum)
        } else {
            button
        }
    }

    /// Native menu, buttons only (design-unified.md, "Menus are native menus only").
    @ViewBuilder
    private func siteMenu(_ site: HomeSite) -> some View {
        Button { togglePin(site) } label: {
            if site.isPinned {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin", systemImage: "pin")
            }
        }
        Divider()
        Button(role: .destructive) { confirmRemoval(site) } label: {
            // A directory site asks what happens to its saved data first.
            if site.forum != nil {
                Label("Remove…", systemImage: "trash")
            } else {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func isCurrent(_ site: HomeSite) -> Bool {
        guard browser.currentURL != nil else { return false }
        if let forum = site.forum, forum.hasReader { return app.isCurrent(forum) }
        return HomeSites.originOf(browser.currentURL) == site.siteURL
    }

    private func togglePin(_ site: HomeSite) {
        DCHaptics.tap()
        if let forum = site.forum {
            site.isPinned ? app.unpin(forum) : app.pin(forum)
        } else if !site.isPinned {
            // One kind of pin: pinning a visited site adds it to the synced directory as `.web`.
            app.pin(Forum(siteURL: site.siteURL, kind: .web, name: site.name))
            siteVisits.setPinned(false, siteURL: site.siteURL)
        } else {
            siteVisits.setPinned(false, siteURL: site.siteURL)
        }
    }

    /// A forum asks what happens to its saved data; another site is just forgotten.
    /// From a context menu the dialog presents once the menu has dismissed: set
    /// during the dismissal, the dialog (a popover on iPad) is dropped and the
    /// binding resets, so "Remove Forum" never appears.
    private func confirmRemoval(_ site: HomeSite) {
        guard let forum = site.forum else {
            siteVisits.remove(siteURL: site.siteURL)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            forumToRemove = forum
        }
    }

    private func open(_ site: HomeSite) {
        DCHaptics.tap()
        addressFocused = false
        if let forum = site.forum {
            actions.openForum(forum)
        } else if let url = site.url {
            siteVisits.noteVisit(siteURL: site.siteURL, name: site.name, isForum: false)
            app.browser.load(url)
        }
    }

    // MARK: No sites yet

    /// Three suggested ordinary sites, no badge and no explanatory text.
    @ViewBuilder
    private var suggestedCard: some View {
        let suggestions = Array(AppModel.onboardingSuggestions().prefix(3))
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggested in
                    Button { app.openSuggestedSite(suggested) } label: {
                        HStack(spacing: DCTheme.spacingM) {
                            ForumIcon(suggested: suggested, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggested.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(DCTheme.ink)
                                    .lineLimit(1)
                                Text(suggested.description)
                                    .font(.footnote)
                                    .foregroundStyle(DCTheme.inkMuted)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DCTheme.surface)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens \(suggested.host)")
                    .accessibilityIdentifier("suggestedSite-\(suggested.host)")
                }
            }
        }
    }

    // MARK: Recent

    /// The newest History items: saved summaries, chats and answers.
    private var recentItems: [HomeRecentItem] {
        HomeRecent.items(sessions: Array(app.sessions.values), runs: app.agentRuns)
    }

    @ViewBuilder
    private var recentSection: some View {
        let items = recentItems
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    Button { openRecent(item) } label: {
                        RecentRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DCTheme.surface)
                    .accessibilityIdentifier("recent-\(item.id)")
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    sectionTitle("Recent", comment: "Home section: the newest conversations and results")
                    Spacer()
                    Button {
                        DCHaptics.tap()
                        actions.openHistory()
                    } label: {
                        Text("History", comment: "Home Recent: the link to all of History")
                            .font(.body)
                            .foregroundStyle(DCTheme.goldInk)
                            .textCase(nil)
                            .frame(minHeight: DCTheme.controlHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recentHistoryLink")
                }
            }
        }
    }

    private func openRecent(_ item: HomeRecentItem) {
        DCHaptics.tap()
        switch item.target {
        case .topic(let topicKey): app.openTopic(topicKey: topicKey)
        case .askRun(let id): app.openAgentRun(id: id)
        }
    }

    // MARK: Continue reading

    @ViewBuilder
    private var continueReadingSection: some View {
        let sessions = HomeSections.continueReading(Array(app.sessions.values))
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { session in
                    Button {
                        DCHaptics.tap()
                        app.openTopic(topicKey: session.topicKey)
                    } label: {
                        ContinueReadingRow(session: session, forum: app.forumInfo(siteURL: session.siteURL))
                    }
                    .tint(.primary)
                    .listRowBackground(DCTheme.surface)
                    .accessibilityIdentifier("continueReading-\(session.topicID)")
                }
            } header: {
                sectionTitle("Continue reading", comment: "Home section: the topics read last")
            }
        }
    }

    // MARK: Following

    @ViewBuilder
    private var followingSection: some View {
        let following = HomeSections.watching(app.watchedTopics)
        if !following.isEmpty {
            Section {
                ForEach(following) { watched in
                    Button {
                        DCHaptics.tap()
                        app.openWatched(watched)
                    } label: {
                        HStack(spacing: DCTheme.spacingM) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(watched.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(DCTheme.ink)
                                    .lineLimit(2)
                                Text(app.forumInfo(siteURL: watched.siteURL).displayName)
                                    .font(.caption)
                                    .foregroundStyle(DCTheme.inkMuted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: DCTheme.spacingS)
                            NewRepliesBadge(text: String(localized: "\(watched.newReplies) new", comment: "Badge: number of new replies in a followed topic"))
                        }
                        .contentShape(Rectangle())
                    }
                    .tint(.primary)
                    .listRowBackground(DCTheme.surface)
                    .accessibilityIdentifier("following-\(watched.topicID)")
                }
            } header: {
                sectionTitle("Following", comment: "Home section: followed topics with new replies")
            }
        }
    }

    private func sectionTitle(_ key: LocalizedStringKey, comment: StaticString) -> some View {
        Text(key, comment: comment)
            .font(.title3.weight(.semibold))
            .foregroundStyle(DCTheme.ink)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Site tiles

/// One site on the grid: its own colour, its name, and (forums only) the grey
/// speech-bubble badge, which shows nowhere else.
private struct SiteTile: View {
    let site: HomeSite
    var isCurrent = false

    var body: some View {
        SiteTileLabel(title: site.name, isCurrent: isCurrent) { size in
            ZStack(alignment: .bottomTrailing) {
                ForumIcon(siteURL: site.siteURL, name: site.name, iconURL: site.iconURL, size: size)
                if site.isForum {
                    ForumBadge()
                        .offset(x: 4, y: 4)
                }
            }
        }
    }
}

private struct SiteTileLabel<Icon: View>: View {
    let title: String
    var isCurrent = false
    let icon: (CGFloat) -> Icon
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = DCTheme.forumTileIcon

    var body: some View {
        VStack(spacing: 6) {
            icon(min(iconSize, 72))
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(DCTheme.ink)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, DCTheme.spacingXS)
        .frame(maxWidth: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if isCurrent {
                RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
                    .strokeBorder(DCTheme.goldInk.opacity(0.55), lineWidth: 1.5)
                    .padding(2.5)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The forum badge: a grey disc with a speech bubble.
private struct ForumBadge: View {
    var body: some View {
        Circle()
            .fill(Color(light: 0x48484A, dark: 0x48484A))
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay { Circle().strokeBorder(DCTheme.ground, lineWidth: 2).padding(-1) }
            .accessibilityHidden(true)
    }
}

/// A row of Recent: icon, the first words, then kind · host · time.
private struct RecentRow: View {
    let item: HomeRecentItem

    private var kindLabel: String {
        switch item.kind {
        case .agent: String(localized: "Agent", comment: "Home Recent: a saved Agent answer")
        case .ask: String(localized: "Agent", comment: "Home Recent: a forum search the Agent ran")
        case .summary: String(localized: "Summary", comment: "Home Recent: a saved summary")
        }
    }

    private var detail: String {
        let when = Date().timeIntervalSince(item.date) < 60
            ? String(localized: "just now", comment: "Home Recent: less than a minute ago")
            : item.date.formatted(.relative(presentation: .named, unitsStyle: .narrow))
        return [kindLabel, item.host, when].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: DCTheme.spacingM) {
            Group {
                if item.isAgent {
                    DCAgentRing(size: 20, lineWidth: DCTheme.ringWidth)
                } else {
                    Image(systemName: "doc.text")
                        .font(.body)
                        .foregroundStyle(DCTheme.ink)
                }
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .font(.subheadline)
                    .foregroundStyle(DCTheme.ink)
                    .lineLimit(1)
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(DCTheme.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows and styles

private struct ContinueReadingRow: View {
    let session: TopicSession
    let forum: Forum

    var body: some View {
        let newer = HomeSections.newerReplies(session)
        HStack(spacing: DCTheme.spacingM) {
            ForumIcon(forum: forum, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if newer > 0 {
                    Text("\(newer) newer replies", comment: "Home Continue reading: posts added since the topic was summarized")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DCTheme.newRepliesBadgeText)
                } else {
                    Text(verbatim: "\(forum.displayName) · \(session.lastSeenAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The gold "12 new" seal.
private struct NewRepliesBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DCType.caption)
            .foregroundStyle(DCTheme.newRepliesBadgeText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DCTheme.newRepliesBadgeBackground, in: RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous))
            .lineLimit(1)
            .fixedSize()
    }
}

enum HomeStyle {
    /// The podcast card: warm ink in light, raised warm surface in dark.
    static let podcastCard = Color(light: 0x1A1612, dark: 0x2A251E)
}
