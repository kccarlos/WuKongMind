import UIKit
import WebKit
import XCTest
@testable import WukongMind

/// Home (spec §7.1) and the launch rule (§7.2): the pure decisions in
/// HomeState.swift and their wiring in AppModel.
@MainActor
final class HomeTests: XCTestCase {
    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private let site = "https://forum.example.org"

    // MARK: Launch rule

    /// A fixed calendar (UTC) and clock, so the day boundary is exact.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: text)!
    }

    private func decide(
        _ setting: LaunchDestination,
        external: Bool = false,
        today: Bool = true,
        lastShown: String? = nil,
        now: String = "2026-10-23T08:00:00Z"
    ) -> LaunchDecision {
        LaunchRule.decide(
            setting: setting,
            openedExternally: external,
            todayHasSomething: today,
            lastHomeAutoShownDay: lastShown,
            now: date(now),
            calendar: calendar
        )
    }

    func testAnOutsideRequestAlwaysWins() {
        for setting in LaunchDestination.allCases {
            XCTAssertEqual(decide(setting, external: true), .external, "\(setting)")
        }
    }

    func testAutomaticShowsHomeOnTheDaysFirstLaunchWhenTodayHasSomething() {
        XCTAssertEqual(decide(.automatic, today: true, lastShown: nil), .home(marksDay: true))
        XCTAssertEqual(decide(.automatic, today: true, lastShown: "2026-10-22"), .home(marksDay: true))
    }

    func testAutomaticGoesToTheLastForumOnceHomeWasShownToday() {
        XCTAssertEqual(decide(.automatic, today: true, lastShown: "2026-10-23"), .lastForum)
    }

    func testAutomaticGoesToTheLastForumWhenTodayHasNothing() {
        XCTAssertEqual(decide(.automatic, today: false, lastShown: nil), .lastForum)
        XCTAssertEqual(decide(.automatic, today: false, lastShown: "2026-10-22"), .lastForum)
    }

    func testTheCalendarDayBoundary() {
        // Shown at 23:59; one minute later is a new day.
        XCTAssertEqual(decide(.automatic, lastShown: "2026-10-22", now: "2026-10-22T23:59:00Z"), .lastForum)
        XCTAssertEqual(decide(.automatic, lastShown: "2026-10-22", now: "2026-10-23T00:01:00Z"), .home(marksDay: true))
    }

    func testHomeAndLastForumForceTheDestination() {
        XCTAssertEqual(decide(.home, today: false, lastShown: "2026-10-23"), .home(marksDay: false))
        XCTAssertEqual(decide(.lastForum, today: true, lastShown: nil), .lastForum)
    }

    func testLaunchDestinationDecodesAndSyncs() throws {
        XCTAssertEqual(AppSettings().launchDestination, .automatic)
        func decode(_ json: String) throws -> LaunchDestination {
            try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).launchDestination
        }
        XCTAssertEqual(try decode("{}"), .automatic, "a missing key")
        XCTAssertEqual(try decode(#"{"launchDestination":"home"}"#), .home)
        XCTAssertEqual(try decode(#"{"launchDestination":"lastForum"}"#), .lastForum)
        XCTAssertThrowsError(try decode(#"{"launchDestination":"somewhereNew"}"#))
        var settings = AppSettings()
        settings.launchDestination = .lastForum
        let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(round.launchDestination, .lastForum)
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("launchDestination"), "synced like the other settings")
    }

    func testAnOutsideRequestBeforeTheRuleKeepsThePage() {
        let app = makeApp()
        app.noteExternalEntry()
        XCTAssertEqual(app.launchPhase, .openedExternally)
        app.applyLaunchRuleIfNeeded()
        XCTAssertEqual(app.launchPhase, .settled)
        app.noteExternalEntry()
        XCTAssertEqual(app.launchPhase, .settled, "after the rule, requests just navigate")
    }

    // MARK: Today module

    private func card(_ id: String, _ state: DigestCard.State, reason: DigestReason = .trending) -> DigestCard {
        var card = DigestCard(siteURL: site, topicID: id, title: "Topic \(id)", slug: nil, reason: reason, postCount: 10)
        card.state = state
        if state == .done { card.summary = "Summary \(id)" }
        return card
    }

    private func digest(_ cards: [DigestCard]) -> DailyDigest {
        DailyDigest(day: DailyDigest.dayKey(for: Date()), cards: cards)
    }

    private func episode(for digest: DailyDigest, states: [PodcastEpisode.Entry.State], durations: [TimeInterval?] = []) -> PodcastEpisode {
        let kinds: [PodcastChapter.Kind] = states.indices.map { $0 == 0 ? .intro : $0 == states.count - 1 ? .outro : .topic }
        let entries = states.indices.map { index in
            PodcastEpisode.Entry(
                chapter: PodcastChapter(id: "c\(index)", kind: kinds[index], title: "C\(index)"),
                audioFile: states[index] == .ready ? "c\(index).m4a" : nil,
                duration: durations.indices.contains(index) ? durations[index] : (states[index] == .ready ? 60 : nil),
                state: states[index]
            )
        }
        return PodcastEpisode(digestID: digest.id, day: digest.day, title: "T", language: "en",
                              hosts: PodcastHosts(a: "A", b: "B"), engine: .onDevice, minutesPerChapter: 1, entries: entries)
    }

    private func state(
        _ digest: DailyDigest?,
        activity: DigestActivity = .idle,
        ready: Bool = true,
        episode: PodcastEpisode? = nil,
        podcast: PodcastActivity = .idle
    ) -> TodayModuleState {
        TodayModuleState.resolve(digest: digest, digestActivity: activity, providerReady: ready,
                                 episode: episode, podcastActivity: podcast)
    }

    func testTheSevenStates() {
        let done = digest([card("1", .done), card("2", .done)])
        XCTAssertEqual(state(done, episode: episode(for: done, states: [.ready, .ready, .ready, .ready])), .podcastReady)
        XCTAssertEqual(state(done, episode: episode(for: done, states: [.ready, .working, .pending, .pending]),
                             podcast: .speaking("c1")), .podcastInProgress)
        XCTAssertEqual(state(done), .digestReady)
        XCTAssertEqual(state(digest([card("1", .done), card("2", .working)]), activity: .summarizing("2")),
                       .digestInProgress(offline: false))
        XCTAssertEqual(state(nil, ready: true), .digestOff)
        XCTAssertEqual(state(nil, ready: false), .aiNotSetUp)
        XCTAssertEqual(state(digest([])), .nothingNew)
    }

    func testOnlyThePodcastGetsTheBigCardAndOnlyMadeOrMakingCountsForTheLaunch() {
        let all: [TodayModuleState] = [.podcastReady, .podcastInProgress, .digestReady, .digestInProgress(offline: false),
                                       .digestInProgress(offline: true), .digestOff, .aiNotSetUp, .nothingNew]
        XCTAssertEqual(all.filter(\.usesBigCard), [.podcastReady, .podcastInProgress])
        XCTAssertEqual(all.filter(\.hasSomething), [.podcastReady, .podcastInProgress, .digestReady,
                                                    .digestInProgress(offline: false), .digestInProgress(offline: true)])
    }

    func testTheEdgesBetweenStates() {
        // Preparing (no cards yet) and offline count as in progress.
        XCTAssertEqual(state(nil, activity: .preparing), .digestInProgress(offline: false))
        XCTAssertEqual(state(nil, activity: .unreachable), .digestInProgress(offline: true))
        XCTAssertEqual(state(digest([card("1", .pending)]), activity: .unreachable), .digestInProgress(offline: true))
        // Relaunched mid-digest (no run yet, cards waiting): still in progress.
        XCTAssertEqual(state(digest([card("1", .done), card("2", .pending)])), .digestInProgress(offline: false))
        // Cards waiting with no model to make them: set up.
        XCTAssertEqual(state(digest([card("1", .pending)]), ready: false), .aiNotSetUp)
        // A made digest still shows without a model.
        XCTAssertEqual(state(digest([card("1", .done)]), ready: false), .digestReady)
        // An episode of another digest (yesterday's) doesn't count.
        let today = digest([card("1", .done)])
        let other = digest([card("1", .done)])
        XCTAssertEqual(state(today, episode: episode(for: other, states: [.ready, .ready, .ready])), .digestReady)
        // A finished episode with a failed chapter is still ready.
        XCTAssertEqual(state(today, episode: episode(for: today, states: [.ready, .failed, .ready])), .podcastReady)
        // The episode wins over an incomplete digest.
        let partial = digest([card("1", .done), card("2", .pending)])
        XCTAssertEqual(state(partial, episode: episode(for: partial, states: [.ready, .pending, .pending])), .podcastInProgress)
    }

    func testThePodcastLengthIsTheRealAudioIncludingIntroAndOutro() {
        let made = digest([card("1", .done), card("2", .done)])
        let facts = PodcastCardFacts(episode: episode(for: made, states: [.ready, .ready, .ready, .ready],
                                                      durations: [20, 200, 220, 40]))
        XCTAssertEqual(facts.topics, 2)
        XCTAssertEqual(facts.seconds, 480)
        XCTAssertEqual(facts.minutes, 8)
        let growing = PodcastCardFacts(episode: episode(for: made, states: [.ready, .working, .pending, .pending]))
        XCTAssertEqual(growing.readyChapters, 1)
        XCTAssertEqual(growing.chapters, 4)
    }

    // MARK: Sections

    func testContinueReadingIsTheLastThreeTopicsWithNewerReplies() {
        let now = Date()
        let sessions: [TopicSession] = (1...5).map { index in
            var session = TopicSession(siteURL: site, topicID: "\(index)", url: URL(string: "\(site)/t/\(index)")!, title: "T\(index)")
            session.openedByUserAt = now.addingTimeInterval(TimeInterval(-index * 60))
            session.totalPosts = 20
            session.summaryPostCount = index == 1 ? 8 : 20
            return session
        }
        let shown = HomeSections.continueReading(sessions.shuffled())
        XCTAssertEqual(shown.map(\.topicID), ["1", "2", "3"])
        XCTAssertEqual(HomeSections.newerReplies(shown[0]), 12)
        XCTAssertEqual(HomeSections.newerReplies(shown[1]), 0)
        var unsummarized = sessions[0]
        unsummarized.summaryPostCount = nil
        XCTAssertEqual(HomeSections.newerReplies(unsummarized), 0)
    }

    /// Topics only the agent read (no visit) never show in Continue
    /// reading or Spotlight; a visit records them.
    func testOnlyTopicsTheUserOpenedAreContinueReadingAndSpotlightEntries() {
        let app = makeApp()
        let forum = Forum(siteURL: site, kind: .discourse, name: "Example")
        var agentRead = TopicSession(siteURL: site, topicID: "1", url: URL(string: "\(site)/t/one/1")!, title: "Agent read")
        agentRead.source = "pages"
        XCTAssertNil(agentRead.openedByUserAt)
        XCTAssertTrue(HomeSections.continueReading([agentRead]).isEmpty)
        XCTAssertTrue(SpotlightCatalog.entries(sessions: [agentRead], forums: [forum]).isEmpty)

        let visited = ForumTopic(siteURL: site, topicID: "2", url: URL(string: "\(site)/t/two/2")!, title: "Visited")
        app.select(topic: visited)
        let session = app.sessions[visited.topicKey]
        XCTAssertNotNil(session?.openedByUserAt)
        XCTAssertEqual(HomeSections.continueReading(Array(app.sessions.values)).map(\.topicID), ["2"])
        XCTAssertEqual(SpotlightCatalog.entries(sessions: [agentRead] + (session.map { [$0] } ?? []), forums: [forum]).map(\.title), ["Visited"])
    }

    func testWatchingListsOnlyTopicsWithNewReplies() {
        func watched(_ id: String, new: Int) -> WatchedTopic {
            var topic = WatchedTopic(siteURL: site, topicID: id, url: URL(string: "\(site)/t/\(id)")!, title: id, knownPostCount: 5)
            topic.newReplies = new
            return topic
        }
        XCTAssertEqual(HomeSections.watching([watched("a", new: 0), watched("b", new: 2), watched("c", new: 7)]).map(\.topicID), ["c", "b"])
    }

    // MARK: Sites grid and Recent (design-unified.md §3)

    private func forum(_ host: String, pinned: Bool = false, order: Int = 0, visited: TimeInterval? = nil) -> Forum {
        Forum(
            siteURL: "https://\(host)", kind: .discourse, name: host, isPinned: pinned, pinOrder: order,
            lastVisitedAt: visited.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func visit(_ host: String, count: Int, at time: TimeInterval, pinned: Bool = false, order: Int = 0, isForum: Bool = false) -> SiteVisit {
        SiteVisit(
            siteURL: "https://\(host)", name: host, isForum: isForum, visitCount: count,
            lastVisitedAt: Date(timeIntervalSince1970: time), isPinned: pinned, pinOrder: order
        )
    }

    func testSitesListPinnedFirstThenMostVisited() {
        let tiles = HomeSites.tiles(
            forums: [forum("a.example", visited: 50), forum("b.example", pinned: true, order: 1), forum("c.example", pinned: true, order: 0)],
            visits: [
                visit("a.example", count: 2, at: 50, isForum: true),
                visit("docs.example", count: 9, at: 10),
                visit("news.example", count: 3, at: 90),
                visit("pinned-web.example", count: 1, at: 5, pinned: true)
            ]
        )
        XCTAssertEqual(
            tiles.map(\.host),
            ["c.example", "b.example", "pinned-web.example", "docs.example", "news.example", "a.example"],
            "pinned forums in their order, pinned sites, then by visit count"
        )
        XCTAssertEqual(tiles.filter(\.isForum).map(\.host), ["c.example", "b.example", "a.example"], "only forums carry the badge")
    }

    func testSitesBreakTiesByNewestVisitAndCountAnOldForumVisitOnce() {
        let tiles = HomeSites.tiles(
            forums: [forum("old-forum.example", visited: 100)],
            visits: [visit("new.example", count: 1, at: 200), visit("older.example", count: 1, at: 50)]
        )
        XCTAssertEqual(tiles.map(\.host), ["new.example", "old-forum.example", "older.example"])
        XCTAssertEqual(tiles.first { $0.host == "old-forum.example" }?.visitCount, 1)
    }

    func testSitesAreLimitedAndAForumIsNeverListedTwice() {
        let many = (0..<20).map { visit("site\($0).example", count: $0 + 1, at: Double($0)) }
        XCTAssertEqual(HomeSites.tiles(forums: [], visits: many).count, HomeSites.limit)
        let tiles = HomeSites.tiles(forums: [forum("a.example")], visits: [visit("a.example", count: 4, at: 1, isForum: false)])
        XCTAssertEqual(tiles.map(\.host), ["a.example"])
    }

    func testOriginAndNameOfAPage() {
        XCTAssertEqual(HomeSites.originOf(URL(string: "https://WWW.Example.com/a/b?c=1")), "https://www.example.com")
        XCTAssertEqual(HomeSites.originOf(URL(string: "http://127.0.0.1:8080/x")), "http://127.0.0.1:8080")
        XCTAssertNil(HomeSites.originOf(URL(string: "about:blank")))
        XCTAssertNil(HomeSites.originOf(URL(string: "file:///tmp/a.html")))
        XCTAssertNil(HomeSites.originOf(nil))
        XCTAssertEqual(HomeSites.displayName(forOrigin: "https://www.example.com"), "example.com")
    }

    func testTheAddressFieldOffersMatchingSites() {
        let tiles = HomeSites.tiles(forums: [forum("meta.discourse.org"), forum("news.ycombinator.com")], visits: [])
        XCTAssertEqual(HomeSites.matches(tiles, for: "disc").map(\.host), ["meta.discourse.org"])
        XCTAssertEqual(HomeSites.matches(tiles, for: "  ").count, 0)
        XCTAssertEqual(HomeSites.matches(tiles, for: "zzz").count, 0)
    }

    @MainActor
    func testVisitsCountOncePerMinutePinAndPersist() throws {
        let suite = UserDefaults(suiteName: "wk.test.\(UUID().uuidString)")!
        let store = SiteVisitStore(defaults: suite, key: "visits")
        let start = Date(timeIntervalSince1970: 1_000)
        store.noteVisit(siteURL: "https://a.example", name: "a.example", isForum: false, at: start)
        store.noteVisit(siteURL: "https://a.example", name: "a.example", isForum: false, at: start.addingTimeInterval(30))
        XCTAssertEqual(store.visit(for: "https://a.example")?.visitCount, 1, "a second visit within a minute is the same visit")
        store.noteVisit(siteURL: "https://a.example", name: "a.example", isForum: false, at: start.addingTimeInterval(90))
        XCTAssertEqual(store.visit(for: "https://a.example")?.visitCount, 2)
        store.noteVisit(siteURL: "https://b.example", name: "b.example", isForum: false, at: start)
        store.setPinned(true, siteURL: "https://a.example")
        store.setPinned(true, siteURL: "https://b.example")
        XCTAssertEqual(store.visit(for: "https://b.example")?.pinOrder, 1, "a pinned site goes last")
        store.setPinned(false, siteURL: "https://a.example")
        XCTAssertEqual(SiteVisitStore(defaults: suite, key: "visits").visits, store.visits, "visits are kept on the device")
        store.remove(siteURL: "https://b.example")
        XCTAssertNil(store.visit(for: "https://b.example"))
    }

    func testRecentIsTheNewestThreeHistoryItems() {
        func session(_ id: String, at time: TimeInterval) -> TopicSession {
            var session = TopicSession(siteURL: "https://forum.example", topicID: id, url: URL(string: "https://forum.example/t/\(id)")!, title: "Topic \(id)")
            session.summary = "S"
            session.updatedAt = Date(timeIntervalSince1970: time)
            return session
        }
        var run = AgentRun(siteURL: "https://forum.example", goal: "Which boxes do people regret?\nsecond line", provider: .ollama, model: "m")
        run.createdAt = Date(timeIntervalSince1970: 5)
        var answer = AgentRun(siteURL: "https://news.example.com", goal: "Make this page dark and hide the sidebar", provider: .ollama, model: "m")
        answer.loop = .agent
        answer.createdAt = Date(timeIntervalSince1970: 30)
        let items = HomeRecent.items(
            sessions: [session("1", at: 10), session("2", at: 40), session("3", at: 20)],
            runs: [run, answer]
        )
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[1].title, "Make this page dark and hide the sidebar")
        XCTAssertTrue(items[1].isAgent)
        XCTAssertEqual(items[1].kind, .agent)
        XCTAssertEqual(items[1].target, .askRun(answer.id))
        XCTAssertEqual(items[1].host, "news.example.com")
        XCTAssertFalse(items[0].isAgent)
        XCTAssertEqual(items.map(\.id).first, "session-\(session("2", at: 40).topicKey)")
        XCTAssertEqual(HomeRecent.firstWords(String(repeating: "word ", count: 40)).count < HomeRecent.titleLength + 2, true)
        XCTAssertEqual(HomeRecent.firstWords("a\nb"), "a")
    }

    // MARK: The Today page over Home

    func testTheTodayPageIsPushedOverHomeAndLeavesWithIt() {
        let app = makeApp()
        app.showsTodayPage = true
        XCTAssertTrue(app.browser.showsForumsHome)
        XCTAssertEqual(app.homePath, [.today])
        app.showsTodayPage = true
        XCTAssertEqual(app.homePath, [.today], "a second request doesn't push twice")
        app.homePath.append(.digestSettings)
        XCTAssertTrue(app.showsTodayPage)
        app.showsTodayPage = false
        XCTAssertEqual(app.homePath, [])
        XCTAssertTrue(app.browser.showsForumsHome, "back to Home")

        // Opening a card's topic leaves Home and the pushed pages.
        app.showsTodayPage = true
        let digestCard = card("9", .done)
        app.openDigestLink(app.url(for: digestCard), card: digestCard)
        XCTAssertFalse(app.showsTodayPage)
        XCTAssertEqual(app.homePath, [])
    }

    private static func closedLoopbackURL(path: String = "/latest") throws -> URL {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        XCTAssertEqual(named, 0)
        let port = UInt16(bigEndian: assigned.sin_port)
        return try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
    }

    func testFailedNavigationFromHomePreservesHomeAndPresentsError() async throws {
        let app = makeApp()
        hostBrowser(app.browser)
        app.browser.showForumsHome()
        XCTAssertTrue(app.browser.showsForumsHome)
        XCTAssertNil(app.browser.currentURL)

        // First load from Home to an unreachable server: returns to Home and surfaces an error.
        let unreachable = try Self.closedLoopbackURL()
        app.browser.load(unreachable)

        let firstDeadline = ContinuousClock.now + .seconds(30)
        while (app.browser.isLoading || !app.browser.showsForumsHome || app.presentedError == nil),
              ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(app.browser.showsForumsHome)
        XCTAssertNil(app.browser.currentURL)
        XCTAssertNotNil(app.presentedError, "Failed first navigation from Home gave no error.")
        app.dismissPresentedError()
        XCTAssertNil(app.presentedError)

        // Subsequent load from Home when Forum A was already loaded: keeps Home up instead of
        // dumping the user onto Forum A, and surfaces an error.
        let forumA = URL(string: "http://127.0.0.1:18991/t/previous-topic/1")!
        app.browser.webView.loadHTMLString(
            "<html><head><title>Previous Forum A</title></head><body>Old page</body></html>",
            baseURL: forumA
        )
        let settleA = ContinuousClock.now + .seconds(30)
        while (app.browser.currentURL != forumA || app.browser.isLoading), ContinuousClock.now < settleA {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(app.browser.currentURL, forumA)

        app.browser.showForumsHome()
        XCTAssertTrue(app.browser.showsForumsHome)

        app.browser.load(try Self.closedLoopbackURL())
        let secondDeadline = ContinuousClock.now + .seconds(30)
        while (app.browser.isLoading || !app.browser.showsForumsHome || app.presentedError == nil),
              ContinuousClock.now < secondDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertTrue(app.browser.showsForumsHome, "Failed load from Home dumped the user onto Forum A.")
        XCTAssertNotNil(app.presentedError, "Failed subsequent navigation from Home gave no error.")
    }

    func testCitationJumpWhileOnHomeDismissesHomeAndShowsTopic() async throws {
        let app = makeApp()
        hostBrowser(app.browser)
        let site = "http://127.0.0.1:18992"
        let topicURL = URL(string: "\(site)/t/layer-shifts/42")!
        let html = """
        <html><head><meta name="generator" content="Discourse 3.3.0"><title>Layer Shifts</title></head>
        <body><article data-post-number="1" id="post_1"><p>First post</p></article>
        <article data-post-number="2" id="post_2"><p>Second post</p></article></body></html>
        """
        app.browser.webView.loadHTMLString(html, baseURL: topicURL)
        let settle = ContinuousClock.now + .seconds(30)
        while (app.pageContext.state != .topic || app.browser.isLoading), ContinuousClock.now < settle {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(app.pageContext.state, .topic)

        app.showsTodayPage = true
        XCTAssertTrue(app.browser.showsForumsHome)
        XCTAssertTrue(app.showsTodayPage)

        app.jumpToCitation(2)
        let jumpDeadline = ContinuousClock.now + .seconds(30)
        while (app.browser.pendingJump != nil || app.browser.showsForumsHome || app.showsTodayPage),
              ContinuousClock.now < jumpDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(
            app.browser.showsForumsHome,
            "Tapping a citation while Home covered an already-loaded topic scrolled the hidden webView without dismissing Home."
        )
        XCTAssertFalse(app.showsTodayPage)

        app.browser.showForumsHome()
        XCTAssertTrue(app.browser.showsForumsHome)
        app.topicOverviews[TopicIdentity.key(siteURL: site, topicID: "42")] = ForumTopicOverview(
            siteURL: site,
            topicID: "42",
            title: "Layer Shifts",
            slug: "layer-shifts",
            url: topicURL,
            postCount: 2,
            facts: nil
        )
        _ = await app.goToPost(1)
        XCTAssertFalse(
            app.browser.showsForumsHome,
            "Jumping to a post while Home covered an already-loaded topic did not dismiss Home."
        )
    }

    private func makeApp() -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeTests-\(UUID().uuidString)", isDirectory: true)
        let browser = ForumBrowserModel(
            contentRules: ContentRuleLibrary(store: nil, directory: nil),
            websiteDataStore: Self.sharedDataStore
        )
        let app = AppModel(
            store: PersistentStore(
                fileURL: directory.appendingPathComponent("state.json"),
                keys: InMemoryProviderKeyStore()
            ),
            browser: browser,
            cloudSync: CloudSyncController(
                transport: nil,
                files: nil,
                defaults: nil,
                schedulesAutomatically: false
            ),
            podcastDirectory: directory.appendingPathComponent("Podcasts", isDirectory: true),
            workspaceDirectory: directory.appendingPathComponent("Workspace", isDirectory: true),
            spotlightIndex: FakeSpotlightIndex(),
            topicActivityDonor: FakeTopicActivityDonor()
        )
        app.usesDirectForumRequests = true
        app.settings.hasCompletedOnboarding = true
        addTeardownBlock { @MainActor in
            app.browser.stopLoading()
            app.scriptWebController.detach()
            try? FileManager.default.removeItem(at: directory)
        }
        return app
    }

    private func hostBrowser(_ browser: ForumBrowserModel) {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: frame)
        window.frame = frame
        let controller = UIViewController()
        controller.view.frame = window.bounds
        browser.webView.frame = controller.view.bounds
        controller.view.addSubview(browser.webView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            browser.stopLoading()
            browser.webView.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
        }
    }
}
