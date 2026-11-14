import XCTest
@testable import WukongMind

/// Jobs read through the site adapter (S4): a summary runs end to end on a
/// made-up platform, and a site with no adapter fails foreground work with
/// `noForum` and is skipped by the watch check.
@MainActor
final class SiteJobTests: XCTestCase {
    private let fakeSite = "https://fake.example.com"
    private let ghostSite = "https://ghost.example.com"

    private struct Harness {
        let app: AppModel
        let ai: StateAIStub
    }

    private func makeHarness(
        forums: [Forum],
        watched: [WatchedTopic] = [],
        fake: FakeSiteAdapter = FakeSiteAdapter()
    ) -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var snapshot = AppSnapshot(watchedTopics: watched, forums: forums)
        snapshot.settings.watchAutoRefreshSummaries = false
        try? store.save(snapshot)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(
            store: store,
            forumService: ForumService(),
            sites: SiteRegistry(adapters: [DiscourseAdapter(), fake]),
            aiService: ai
        )
        app.usesDirectForumRequests = true
        var provider = app.settings.configuration(for: .ollama)
        provider.apiKey = ""
        app.setConfiguration(provider, for: .ollama)
        app.selectModel(ModelSelection(provider: .ollama, model: "model-a"), for: .role(.assistant))
        app.browser.onPageContextChanged = nil
        addTeardownBlock { @MainActor in
            for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
        }
        return Harness(app: app, ai: ai)
    }

    private func topic(_ site: String, id: String = "42") -> ForumTopic {
        ForumTopic(siteURL: site, topicID: id, url: URL(string: "\(site)/topic/\(id)")!, title: "Topic \(id)")
    }

    func testFakeAdapterReadDrivesASummaryEndToEnd() async throws {
        let harness = makeHarness(forums: [Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake")])
        XCTAssertTrue(harness.app.enqueueSummary(for: topic(fakeSite)))
        try await waitUntil { harness.app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(harness.app.activities.first?.status, .completed)
        XCTAssertEqual(harness.ai.calls.map(\.kind), ["summary"])
        XCTAssertTrue(harness.ai.calls[0].content.contains("Opening post of the fake topic."))
        let session = try XCTUnwrap(harness.app.sessions.values.first)
        XCTAssertEqual(session.rawPages.map(\.content), [FakeSiteAdapter.pageContent])
        XCTAssertEqual(session.totalPosts, 2)
    }

    func testRemovingTheForumMidReadLetsTheJobFinishAndFailsQueuedWork() async throws {
        let gate = ReadGate()
        var fake = FakeSiteAdapter()
        fake.readGate = gate
        let harness = makeHarness(forums: [Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake")], fake: fake)
        XCTAssertTrue(harness.app.enqueueSummary(for: topic(fakeSite, id: "42")))
        try await waitUntil { gate.hasWaiter }
        XCTAssertTrue(harness.app.enqueueSummary(for: topic(fakeSite, id: "43")))
        XCTAssertEqual(harness.app.activities.first { $0.topicID == "43" }?.status, .queued)

        harness.app.removeForum(try XCTUnwrap(harness.app.forum(for: fakeSite)), deleteData: false)
        gate.release()
        try await waitUntil { harness.app.activities.allSatisfy(\.status.isTerminal) }

        // The running job kept its adapter and finished; the queued one never started.
        let running = try XCTUnwrap(harness.app.activities.first { $0.topicID == "42" })
        XCTAssertEqual(running.status, .completed, running.error)
        XCTAssertEqual(harness.app.sessions.values.first { $0.topicID == "42" }?.totalPosts, 2)
        let queued = try XCTUnwrap(harness.app.activities.first { $0.topicID == "43" })
        XCTAssertEqual(queued.status, .failed)
        XCTAssertEqual(queued.error, AssistantError.noForum.localizedDescription)
    }

    func testAPlaceholderForumIsNeverStoredPinnedOrOpened() throws {
        let harness = makeHarness(forums: [Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake")])
        let app = harness.app
        app.openForum(try XCTUnwrap(app.forum(for: fakeSite)))
        let placeholder = app.forumInfo(siteURL: ghostSite)
        XCTAssertEqual(placeholder.kind, .unknown)

        app.pin(placeholder)
        app.openForum(placeholder)
        XCTAssertNil(app.forum(for: ghostSite))
        XCTAssertEqual(app.currentSiteURL, fakeSite)
        XCTAssertEqual(app.browser.homeSiteURL, fakeSite)

        // The directory refuses it, and repairs a stored one when the real kind arrives.
        var directory = ForumDirectory()
        XCTAssertNil(directory.upsert(siteURL: ghostSite, kind: .unknown, name: "Ghost", iconURL: nil))
        XCTAssertTrue(directory.forums.isEmpty)
        directory.forums = [Forum(siteURL: ghostSite, kind: .unknown, name: "Ghost")]
        let repaired = directory.upsert(siteURL: ghostSite, kind: .discourse, name: nil, iconURL: nil)
        XCTAssertEqual(repaired?.kind, .discourse)
        directory.upsert(siteURL: ghostSite, kind: .unknown, name: nil, iconURL: nil)
        XCTAssertEqual(directory.forum(siteURL: ghostSite)?.kind, .discourse)
    }

    func testSummaryOnASiteWithoutAnAdapterFailsWithNoForum() async throws {
        let harness = makeHarness(forums: [Forum(siteURL: ghostSite, kind: SiteKind("ghost"), name: "Ghost")])
        XCTAssertTrue(harness.app.enqueueSummary(for: topic(ghostSite)))
        try await waitUntil { harness.app.activities.allSatisfy(\.status.isTerminal) }
        let record = try XCTUnwrap(harness.app.activities.first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.error, AssistantError.noForum.localizedDescription)
        XCTAssertTrue(harness.ai.calls.isEmpty)
    }

    func testWatchCheckReadsThroughTheAdapterAndSkipsASiteWithoutOne() async throws {
        func watched(_ site: String) -> WatchedTopic {
            WatchedTopic(siteURL: site, topicID: "42", url: URL(string: "\(site)/topic/42")!, title: "Topic 42", knownPostCount: 1)
        }
        let harness = makeHarness(
            forums: [
                Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake"),
                Forum(siteURL: ghostSite, kind: SiteKind("ghost"), name: "Ghost")
            ],
            watched: [watched(fakeSite), watched(ghostSite)]
        )
        await harness.app.checkWatchedTopics(reason: .manual)
        let fake = try XCTUnwrap(harness.app.watchedTopics.first { $0.siteURL == fakeSite })
        XCTAssertEqual(fake.newReplies, 1, "the fake adapter's overview says 2 posts")
        XCTAssertNotNil(fake.lastCheckedAt)
        let ghost = try XCTUnwrap(harness.app.watchedTopics.first { $0.siteURL == ghostSite })
        XCTAssertEqual(ghost.newReplies, 0)
        XCTAssertNil(ghost.lastCheckedAt, "skipped quietly, not marked as a failed check")
    }

    // MARK: Agent (S10)

    /// The Agent's forum tools for the fake site (One loop 13 ported these
    /// tests from the old Research loop to the tool level).
    private func toolRegistry(_ fake: FakeSiteAdapter) -> ToolRegistry {
        var sessions: [String: TopicSession] = [:]
        let service = ForumToolService(
            sessionLookup: { sessions[$0] }, sessionWrite: { sessions[$0] = $1 },
            makeNetwork: { siteURL, _, _ in ForumService().net(siteURL, pace: .fast) }
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ToolRegistry.m3(context: AgentToolContext(
            bridge: FixturePageDriver(page: .init(url: fakeSite, title: "Fake")),
            workspace: nil,
            scriptStore: ScriptStore(directoryURL: directory),
            settings: AgentToolSettings(truncationLimit: ToolRegistry.defaultTruncationLimit, redactedSecrets: []),
            forum: ForumToolContext(service: service, scope: ForumRunScope(adapter: fake, siteURL: fakeSite), forumName: "Fake")
        ))
    }

    func testTheForumToolsOnAnotherToolsetOfferAndRunThatToolset() async throws {
        var fake = FakeSiteAdapter()
        fake.queryResult = SiteQueryResult(topics: [
            ForumTopicListing(
                siteURL: fakeSite, id: 42, title: "Topic 42", slug: "42",
                url: URL(string: "\(fakeSite)/topic/42")!, postsCount: 2
            )
        ])
        let registry = toolRegistry(fake)
        let names = registry.definitions.map(\.name)
        XCTAssertTrue(names.contains("search_comments") && names.contains("read_topic"), "\(names)")
        XCTAssertFalse(names.contains("list_latest") || names.contains("search_forum"), "not this site's tools: \(names)")

        let refused = try await registry.dispatch(toolName: "list_latest", arguments: [:])
        XCTAssertTrue(refused.isError, refused.output)
        // The site tool runs through the fake's query and result, the read through its pages.
        let search = try await registry.dispatch(toolName: "search_comments", arguments: ["query": .string("fees")])
        XCTAssertTrue(search.output.contains("- id 42: Topic 42"), search.output)
        let read = try await registry.dispatch(toolName: "read_topic", arguments: ["topic_id": .string("42")])
        XCTAssertFalse(read.isError, read.output)
        XCTAssertTrue(read.output.contains("Opening post of the fake topic."), read.output)

        // An answer's links parse through the fake's `links`: the post and the topic fold.
        let app = makeHarness(forums: [Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake")], fake: fake).app
        let parse = app.linkParser(siteURL: fakeSite)
        let answer = "See [Topic 42](\(fakeSite)/topic/42#p2) and [again](\(fakeSite)/topic/42)."
        let sources = AgentSources.extract(from: answer, visits: [], parse: parse)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.postNumber, 2)
        XCTAssertEqual(parse(try XCTUnwrap(sources.first?.url))?.topicID, "42")
    }

    /// The widened shapes through the forum tools: options reach the adapter,
    /// an invalid argument is a recoverable error, and numberless hits and
    /// listings print their numberless forms.
    func testWidenedQueriesAndResultsRunThroughTheForumTools() async throws {
        var fake = FakeSiteAdapter()
        let listing = ForumTopicListing(
            siteURL: fakeSite, id: 42, title: "Topic 42", slug: "42",
            url: URL(string: "\(fakeSite)/topic/42")!, postsCount: nil, lastPostedAt: "2026-10-21T08:00:00Z"
        )
        fake.queryResult = SiteQueryResult(
            topics: [listing],
            hits: [ForumSearchHit(
                topic: listing, postNumber: nil, username: "bob", blurb: "Fees went up.", postedAt: "2026-10-21T08:00:00Z",
                url: URL(string: "\(fakeSite)/topic/42#comment-9")!
            )]
        )
        let registry = toolRegistry(fake)
        let badDate = try await registry.dispatch(
            toolName: "search_comments", arguments: ["query": .string("fees"), "after": .string("yesterday")]
        )
        XCTAssertTrue(badDate.isError && badDate.output.contains("Invalid argument \"after\": use the form YYYY-MM-DD."), badDate.output)
        let badPage = try await registry.dispatch(toolName: "search_comments", arguments: ["query": .string("fees"), "page": .int(9)])
        XCTAssertTrue(badPage.isError && badPage.output.contains("Invalid argument \"page\": use a number from 1 to 3."), badPage.output)
        let found = try await registry.dispatch(toolName: "search_comments", arguments: [
            "query": .string("fees"), "category": .string("News"), "after": .string("2026-10-01"),
            "before": .string("2026-10-31"), "page": .int(2)
        ])
        XCTAssertFalse(found.isError, found.output)
        XCTAssertTrue(found.output.contains("- id 42: Topic 42 — last activity 2026-10-21 — \(fakeSite)/topic/42"), found.output)
        XCTAssertTrue(found.output.contains("@bob (2026-10-21): Fees went up."), found.output)
        XCTAssertEqual(found.notes, [.unnumberedHits])

        // Only the valid call reached the adapter, with its options.
        let queries = fake.queryLog.all
        XCTAssertEqual(queries.count, 1)
        guard case .search(let text, let scope, let options) = try XCTUnwrap(queries.first) else { return XCTFail() }
        XCTAssertEqual(text, "fees")
        XCTAssertEqual(scope, .comments)
        XCTAssertEqual(options.category, "News")
        XCTAssertEqual(options.page, 2)
        XCTAssertEqual(options.after, ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        XCTAssertEqual(options.before, ISO8601DateFormatter().date(from: "2026-10-31T00:00:00Z"))
    }

    /// Items, digest cards and podcast chapters of another platform build that
    /// platform's URLs (a post is `#pN`, a topic has no slug).
    func testLinksOfAnItemACardAndAChapterComeFromTheirSitesAdapter() {
        let app = makeHarness(forums: [Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake")]).app
        let item = BrowseItem(kind: .post, siteURL: fakeSite, topicID: "42", slug: "ignored", postNumber: 2, title: "T")
        XCTAssertEqual(app.url(for: item)?.absoluteString, "\(fakeSite)/topic/42#p2")
        var topicItem = item
        topicItem.postNumber = nil
        XCTAssertEqual(app.url(for: topicItem)?.absoluteString, "\(fakeSite)/topic/42")

        let card = DigestCard(siteURL: fakeSite, topicID: "42", title: "T", reason: .trending, postCount: 99)
        XCTAssertEqual(app.url(for: card).absoluteString, "\(fakeSite)/topic/42")
        XCTAssertEqual(app.url(for: card, atPost: 3).absoluteString, "\(fakeSite)/topic/42#p3")
        XCTAssertNil(app.topPostsURL(for: card), "The fake has no filtered views")

        var chapter = PodcastChapter(card: card)
        chapter.postNumber = 4
        XCTAssertEqual(app.url(for: chapter)?.absoluteString, "\(fakeSite)/topic/42#p4")

        // No adapter: no link, and a card falls back to the forum's address.
        let ghost = makeHarness(forums: [Forum(siteURL: ghostSite, kind: SiteKind("ghost"), name: "Ghost")]).app
        XCTAssertNil(ghost.url(for: BrowseItem(kind: .post, siteURL: ghostSite, topicID: "1", postNumber: 1, title: "")))
        XCTAssertEqual(ghost.url(for: DigestCard(siteURL: ghostSite, topicID: "1", title: "", reason: .trending, postCount: 1)).absoluteString, ghostSite)
    }

    func testAgentSourcesParseThroughTheGivenAdapter() {
        let post = URL(string: "\(fakeSite)/topic/42#p3")!
        let parse = AgentSources.Parse { FakeLinks().parse($0, basePath: "") }
        let answer = "[a](\(post.absoluteString)) [b](\(fakeSite)/topic/42) [c](\(fakeSite)/topic/7)"
        let sources = AgentSources.extract(from: answer, run: nil, sessions: [:], parse: parse)
        XCTAssertEqual(sources.map(\.postNumber), [3, nil])
        XCTAssertEqual(sources.map(\.title), ["a", "c"])
        // Discourse's parser knows nothing of this site's URLs: every link is its own source.
        let discourse = AgentSources.Parse { DiscourseLinks().parse($0, basePath: "") }
        XCTAssertEqual(AgentSources.extract(from: answer, run: nil, sessions: [:], parse: discourse).count, 3)
    }

    private func waitUntil(
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
