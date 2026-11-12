import XCTest
@testable import Forumind

/// Home (spec §7.1) and the launch rule (§7.2): the pure decisions in
/// HomeState.swift and their wiring in AppModel.
@MainActor
final class HomeTests: XCTestCase {
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

    func testSuggestionsOnlyWhileTheUserHasFewForums() {
        XCTAssertTrue(HomeSections.showsSuggestions(forumCount: 0))
        XCTAssertTrue(HomeSections.showsSuggestions(forumCount: 2))
        XCTAssertFalse(HomeSections.showsSuggestions(forumCount: 3))
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

    func testFailedNavigationFromHomePreservesHomeAndPresentsError() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Timing-sensitive WKWebView unreachable-port navigation callback on CI simulator (see docs/wukongmind/flaky-tests.md)")
        let app = makeApp()
        app.browser.showForumsHome()
        XCTAssertTrue(app.browser.showsForumsHome)
        XCTAssertNil(app.browser.currentURL)

        // First load from Home to an unreachable server: returns to Home and surfaces an error.
        let unreachable = URL(string: "http://127.0.0.1:1/latest")!
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
        while app.browser.currentURL != forumA, ContinuousClock.now < settleA {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(app.browser.currentURL, forumA)

        app.browser.showForumsHome()
        XCTAssertTrue(app.browser.showsForumsHome)

        app.browser.load(unreachable)
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
        let site = "http://127.0.0.1:18992"
        let topicURL = URL(string: "\(site)/t/layer-shifts/42")!
        let html = """
        <html><head><meta name="generator" content="Discourse 3.3.0"><title>Layer Shifts</title></head>
        <body><article data-post-number="1" id="post_1"><p>First post</p></article>
        <article data-post-number="2" id="post_2"><p>Second post</p></article></body></html>
        """
        app.browser.webView.loadHTMLString(html, baseURL: topicURL)
        let settle = ContinuousClock.now + .seconds(5)
        while app.pageContext.state != .topic, ContinuousClock.now < settle {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(app.pageContext.state, .topic)

        app.showsTodayPage = true
        XCTAssertTrue(app.browser.showsForumsHome)
        XCTAssertTrue(app.showsTodayPage)

        app.jumpToCitation(2)
        let jumpDeadline = ContinuousClock.now + .seconds(5)
        while app.browser.pendingJump != nil, ContinuousClock.now < jumpDeadline {
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
        let app = AppModel(
            store: PersistentStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent("state.json")
            ),
            spotlightIndex: FakeSpotlightIndex(),
            topicActivityDonor: FakeTopicActivityDonor()
        )
        app.usesDirectForumRequests = true
        app.settings.hasCompletedOnboarding = true
        app.settings.acceptedTermsVersion = ModerationTerms.currentVersion
        return app
    }
}
