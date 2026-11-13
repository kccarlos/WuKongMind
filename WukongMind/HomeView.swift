import SwiftUI

// MARK: - Home, the start page (design-unified.md §3)
//
// Fixed order: the address field, the Today module (TodayModuleState,
// HomeState.swift), Sites (pinned first, then most visited; forums are just
// sites, with the grey badge only here), Recent (the newest History items),
// Continue reading and Following. With no sites yet: the address field and a
// card of three suggested sites. Shown over the web view (BrowserContent),
// which stays loaded under it. Pages pushed over Home (`HomeRoute`) live in
// `AppModel.homePath`: on iPhone in the bar's NavigationStack
// (PhoneBrowserBar.swift), on iPad in a stack of Home's own.

struct HomeView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var podcast: PodcastController
    let actions: BrowserActions

    init(app: AppModel, actions: BrowserActions) {
        self.app = app
        browser = app.browser
        podcast = app.podcast
        self.actions = actions
    }

    var body: some View {
        // The pages pushed over Home go on the bar's stack (PhoneBrowser).
        HomeList(app: app, browser: browser, podcast: podcast, siteVisits: app.siteVisits, actions: actions)
    }
}

/// The pages pushed over Home. On the view at the root of the stack that
/// holds `app.homePath`, mounted whether Home shows or not.
struct HomeDestinations: ViewModifier {
    @ObservedObject var app: AppModel
    let onOpenDigestLink: (URL, DigestCard) -> Void

    func body(content: Content) -> some View {
        content.navigationDestination(for: HomeRoute.self) { route in
            Group {
                switch route {
                case .today:
                    TodayPage(app: app, onOpen: onOpenDigestLink)
                case .digest(let id):
                    if let digest = app.digests.first(where: { $0.id == id }) {
                        DigestHistoryPage(app: app, digest: digest, onOpen: onOpenDigestLink)
                            .toolbar(.visible, for: .navigationBar)
                    }
                case .digestSettings:
                    SettingsDigestPage(app: app)
                        .navigationTitle(SettingsPage.digest.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(.visible, for: .navigationBar)
                }
            }
            .modifier(HomeRouteDockModifier(app: app, route: route))
        }
    }
}

private struct HomeList: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var podcast: PodcastController
    @ObservedObject var siteVisits: SiteVisitStore
    let actions: BrowserActions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var forumToRemove: Forum?
    @State private var addressText = ""
    @FocusState private var addressFocused: Bool

    private var tiles: [HomeSite] { HomeSites.tiles(forums: app.forums, visits: siteVisits.visits) }

    var body: some View {
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
                if !app.forums.isEmpty { TodayModule(app: app, podcast: podcast, onOpen: actions.openDigestLink) }
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
        .task { podcast.refresh() }
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
                ForEach(HomeSites.matches(tiles, for: addressText)) { site in
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
        let text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if browser.open(address: text) {
            finishAddress()
        } else if let url = app.webSearchURL(query: text) {
            browser.load(url)
            finishAddress()
        }
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
            // A forum asks what happens to its saved data first.
            if site.isForum {
                Label("Remove…", systemImage: "trash")
            } else {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func isCurrent(_ site: HomeSite) -> Bool {
        guard browser.currentURL != nil else { return false }
        if let forum = site.forum { return app.isCurrent(forum) }
        return HomeSites.originOf(browser.currentURL) == site.siteURL
    }

    private func togglePin(_ site: HomeSite) {
        DCHaptics.tap()
        if let forum = site.forum {
            site.isPinned ? app.unpin(forum) : app.pin(forum)
        } else {
            siteVisits.setPinned(!site.isPinned, siteURL: site.siteURL)
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

    /// Three suggested sites, no badge and no explanatory text.
    @ViewBuilder
    private var suggestedCard: some View {
        let suggestions = Array(app.suggestedForumsToOffer.prefix(3))
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggested in
                    Button { app.openForum(suggested) } label: {
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

    /// The newest History items; until conversations are saved (M3's
    /// workspace) this launch's Agent conversation joins them.
    private var recentItems: [HomeRecentItem] {
        let run = app.browserAgent.runs.last
        return HomeRecent.items(
            sessions: Array(app.sessions.values),
            runs: app.agentRuns,
            conversation: run.map {
                (prompt: $0.prompt, host: BrowserAddress.host(app.browser.currentURL), date: $0.startedAt)
            }
        )
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
        case .conversation:
            if app.browser.currentURL != nil { app.browser.hideForumsHome() }
            actions.openAssistant()
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
                    .padding(-2)
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
        case .agent: String(localized: "Agent", comment: "Home Recent: an Agent conversation")
        case .ask: String(localized: "Agent", comment: "Home Recent: a forum search the Agent ran")
        case .summary: String(localized: "Summary", comment: "Home Recent: a saved summary")
        case .chat: String(localized: "Chat", comment: "Home Recent: a saved chat")
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
                    Image(systemName: item.kind == .chat ? "bubble.left" : "doc.text")
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

// MARK: - Today module

/// The Today module at the top of Home, in one of its 7 states: the big
/// podcast card, the digest strip, or one row.
private struct TodayModule: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    let onOpen: (URL, DigestCard) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private func shownCards(for state: TodayModuleState) -> [DigestCard] {
        switch state {
        case .digestReady, .digestInProgress:
            return app.todaysDigest?.cards.filter { $0.state == .done } ?? []
        default:
            return []
        }
    }

    var body: some View {
        let state = app.todayModuleState
        let shown = shownCards(for: state)
        Section {
            switch state {
            case .podcastReady, .podcastInProgress:
                if let episode = podcast.episode, let digest = app.todaysDigest {
                    PodcastHomeCard(app: app, podcast: podcast, episode: episode, digest: digest, isMaking: state == .podcastInProgress)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: DCTheme.spacingXS, leading: 0, bottom: DCTheme.spacingXS, trailing: 0))
                }
            case .digestReady, .digestInProgress:
                if let digest = app.todaysDigest {
                    digestHeader(digest, state: state)
                } else {
                    // Preparing (or offline) before there are cards.
                    progressRow(state: state, digest: nil)
                }
            case .digestOff:
                row(
                    title: Text("Today", comment: "Home Today module title"),
                    detail: Text("Make a digest of today’s topics", comment: "Forums home Today row when the daily digest is off"),
                    action: (Text("Make", comment: "Home Today module: make today's digest"), {
                        DCHaptics.tap()
                        app.makeTodaysDigest()
                    }),
                    actionID: "homeTodayMake"
                )
            case .aiNotSetUp:
                row(
                    title: Text("Today", comment: "Home Today module title"),
                    detail: Text("Set up AI to get a daily digest", comment: "Home Today module when no AI model is ready"),
                    action: (Text("Set up", comment: "Home Today module: set up an AI model"), {
                        app.needsProviderSetup = .assistant
                    }),
                    actionID: "homeTodaySetUp"
                )
            case .nothingNew:
                row(
                    title: Text("Today", comment: "Home Today module title"),
                    detail: Text("Nothing new today", comment: "Daily digest with no topics"),
                    action: nil,
                    actionID: nil
                )
            }
        } footer: {
            if !shown.isEmpty {
                DigestStrip(app: app, cards: shown, onOpen: onOpen)
                    .listRowInsets(EdgeInsets(top: DCTheme.spacingS, leading: 0, bottom: DCTheme.spacingXS, trailing: 0))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("homeToday")
    }

    private func openToday() {
        DCHaptics.tap()
        app.showsTodayPage = true
    }

    /// "Today · 6 topics · made 7:02 AM" (a tap opens the Today page) and
    /// Listen: the cards read aloud with the podcast's voices (the device's
    /// by default, free).
    private func digestHeader(_ digest: DailyDigest, state: TodayModuleState) -> some View {
        HStack(spacing: DCTheme.spacingM) {
            Button(action: openToday) {
                HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: DCTheme.spacingM) {
                    DigestIcon(size: 30)
                        .padding(.top, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Today", comment: "Home Today module title")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        statusText(state: state, digest: digest)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens today’s digest"))
            .accessibilityIdentifier("homeTodayOpen")
            if state == .digestReady {
                ReadAloudButton(podcast: podcast, id: "today-digest", title: String(localized: "Today"), text: readAloudText(digest))
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(DCButtonStyle(role: .secondary))
                    .fixedSize()
            } else if case .digestInProgress(offline: false) = state {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, DCTheme.spacingXS)
            }
        }
        .padding(.vertical, 2)
    }

    private func progressRow(state: TodayModuleState, digest: DailyDigest?) -> some View {
        Button(action: openToday) {
            HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: DCTheme.spacingM) {
                DigestIcon(size: 30)
                    .padding(.top, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today", comment: "Home Today module title")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    statusText(state: state, digest: digest)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if case .digestInProgress(offline: false) = state {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, DCTheme.spacingXS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("homeTodayOpen")
    }

    private func statusText(state: TodayModuleState, digest: DailyDigest?) -> Text {
        if case .digestInProgress(offline: true) = state {
            return Text("Can’t reach your forums. It continues when you’re back online.", comment: "Home Today module: the digest is paused while offline")
        }
        guard let digest else {
            return Text("Checking your forums…", comment: "Daily digest: reading the forums' topic lists before summarizing")
        }
        if !digest.isComplete {
            return Text("\(digest.finishedCount) of \(digest.cards.count) ready", comment: "Daily digest progress: cards summarized so far, then the number of cards")
        }
        let made = (digest.completedAt ?? digest.createdAt).formatted(date: .omitted, time: .shortened)
        return Text("\(digest.cards.count) topics · made \(made)", comment: "Home Today module: number of digest cards, then when the digest was made")
    }

    private func readAloudText(_ digest: DailyDigest) -> String {
        digest.cards
            .filter { $0.state == .done && !$0.summary.isEmpty }
            .map { "\($0.title).\n\($0.summary)" }
            .joined(separator: "\n\n")
    }

    /// One row: Digest off, AI not set up, Nothing new. The row opens the
    /// Today page (Earlier, digest settings); the button does its action.
    private func row(title: Text, detail: Text, action: (Text, () -> Void)?, actionID: String?) -> some View {
        HStack(spacing: DCTheme.spacingM) {
            Button(action: openToday) {
                HStack(spacing: DCTheme.spacingM) {
                    DigestIcon(size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        title
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        detail
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens today’s digest"))
            .accessibilityIdentifier("homeTodayOpen")
            if let action {
                Button(action: action.1) {
                    action.0
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .background(DCTheme.goldWash, in: RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous))
                        .frame(minHeight: DCTheme.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DCTheme.goldInk)
                .fixedSize()
                .accessibilityIdentifier(actionID ?? "")
            }
        }
    }
}

/// "Listen to today": the big card for a made (or growing) episode. Play
/// starts as soon as the first chapter is spoken.
private struct PodcastHomeCard: View {
    @ObservedObject var app: AppModel
    @ObservedObject var podcast: PodcastController
    let episode: PodcastEpisode
    let digest: DailyDigest
    let isMaking: Bool

    private var facts: PodcastCardFacts { PodcastCardFacts(episode: episode) }
    private var isPlaying: Bool { podcast.isPlayingEpisode && podcast.player.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            HStack(spacing: DCTheme.spacingL) {
                Button {
                    DCHaptics.tap()
                    if podcast.isPlayingEpisode { podcast.player.toggle() } else { podcast.playEpisode() }
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(HomeStyle.podcastCard)
                        .frame(width: 56, height: 56)
                        .background(.white, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!episode.hasAudio)
                .opacity(episode.hasAudio ? 1 : 0.5)
                .accessibilityLabel(isPlaying ? Text("Pause") : Text("Play today’s podcast", comment: "Home podcast card: play button"))
                .accessibilityIdentifier("homePodcastPlay")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Listen to today", comment: "Today page: the podcast section's title")
                        .font(.title3.weight(.bold))
                    subtitle
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                        .accessibilityIdentifier("homePodcastFacts")
                }
                Spacer(minLength: 0)
            }
            if isMaking {
                ProgressView(value: Double(facts.readyChapters), total: Double(max(facts.chapters, 1)))
                    .tint(.white)
                    .accessibilityLabel(Text("Making the podcast", comment: "Home podcast card: progress bar while chapters are being made"))
            }
            Divider().overlay(.white.opacity(0.15))
            HStack {
                Text(reasons)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: DCTheme.spacingS)
                Button {
                    DCHaptics.tap()
                    app.showsTodayPage = true
                } label: {
                    Text("Read \(digest.cards.count) topics", comment: "Home podcast card: opens the Today page; the placeholder is the number of topics")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous))
                        .frame(minHeight: DCTheme.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityIdentifier("homeReadTopics")
            }
        }
        .foregroundStyle(.white)
        .padding(DCTheme.spacingL)
        .background(HomeStyle.podcastCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("homePodcastCard")
    }

    /// "6 topics · about 8 min · Google voices"; while it's made, the chapters.
    private var subtitle: Text {
        if isMaking {
            return Text("\(facts.readyChapters) of \(facts.chapters) chapters ready", comment: "Home podcast card while the podcast is being made")
        }
        return Text("\(facts.topics) topics · about \(facts.minutes) min · \(episode.engine.label)", comment: "Home podcast card: number of topics, the podcast's length in minutes, then which voices read it (Google or on-device)")
    }

    private var reasons: String {
        let watched = digest.cards.filter { if case .newReplies = $0.reason { return true } else { return false } }.count
        let trending = digest.cards.count - watched
        return String(localized: "\(watched) watched · \(trending) trending", comment: "Home podcast card: digest cards from watched topics, then trending ones")
    }
}

/// Finished digest cards in a horizontal strip: forum, reason, title and a
/// two-line summary; a tap opens the topic.
private struct DigestStrip: View {
    @ObservedObject var app: AppModel
    let cards: [DigestCard]
    let onOpen: (URL, DigestCard) -> Void
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 272

    private var resolvedCardWidth: CGFloat {
        min(cardWidth, 300)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: DCTheme.spacingM) {
                ForEach(cards) { card in
                    Button { onOpen(app.url(for: card), card) } label: { cardView(card) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("homeDigestCard-\(card.topicID)")
                }
            }
            .padding(.trailing, DCTheme.spacingL)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func cardView(_ card: DigestCard) -> some View {
        let forum = app.forumInfo(siteURL: card.siteURL)
        return VStack(alignment: .leading, spacing: DCTheme.spacingS) {
            SettingsIconRow(spacing: DCTheme.spacingS) {
                ForumIcon(forum: forum, size: 22)
            } title: {
                Text(forum.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } trailing: {
                reason(card)
            }
            Text(card.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Text(card.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: resolvedCardWidth, alignment: .topLeading)
        .frame(minHeight: 150, alignment: .topLeading)
        .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(DCTheme.border)
        }
        .contentShape(RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the topic")
    }

    @ViewBuilder
    private func reason(_ card: DigestCard) -> some View {
        switch card.reason {
        case .newReplies(let count):
            NewRepliesBadge(text: String(localized: "\(count) new replies", comment: "Digest card: why a watched topic is in the digest"))
        case .trending:
            DCPill(text: String(localized: "Trending", comment: "Digest card: the topic is among today's top topics of a pinned forum"),
                   tint: DCTheme.jade)
        }
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
