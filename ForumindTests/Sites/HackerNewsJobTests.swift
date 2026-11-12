import JavaScriptCore
import XCTest
@testable import Forumind

@MainActor
final class HackerNewsJobTests: XCTestCase {
    private let site = HackerNewsFixture.site
    private var topic: ForumTopic { .init(siteURL: site, topicID: "1", url: URL(string: site + "/item?id=1")!, title: "Y Combinator") }
    private func harness(actions: [AgentAction] = [], blocked: Bool = false, watched: Bool = false,
                         aiService: AIService? = nil) throws -> (AppModel, StateAIStub, ScriptedAgentPlanner, HackerNewsFixture) {
        // Fails before implementation without changing any existing site's baseline.
        _ = try XCTUnwrap(SiteRegistry.standard.adapter(for: SiteKind("hackernews")))
        let fixture = HackerNewsFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var snapshot = AppSnapshot(forums: [Forum(siteURL: site, kind: SiteKind("hackernews"), name: "Hacker News")])
        if watched { snapshot.watchedTopics = [.init(siteURL: site, topicID: "1", url: topic.url, title: topic.title, knownPostCount: 1)] }
        // A pre-existing block, before this run. Persisted timestamps have
        // whole-second precision; a block from this second conservatively
        // invalidates observations until that second ends.
        if blocked { snapshot.settings.blockedUsers = [BlockedUser(siteURL: site, username: "sama", blockedAt: Date(timeIntervalSince1970: 1))] }
        try store.save(snapshot)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let ai = StateAIStub(); ai.gated = false
        let planner = ScriptedAgentPlanner(actions: actions)
        let app = AppModel(store: store, forumService: fixture.network().service, sites: .standard,
                           aiService: aiService ?? ai, planner: planner,
                           podcastDirectory: directory.appendingPathComponent("Podcasts"))
        app.usesDirectForumRequests = true
        app.allowAllAIProviders()
        app.selectModel(.init(provider: .ollama, model: "model-a"), for: .both)
        app.browser.onPageContextChanged = nil
        app.settings.forumRequestPace = .fast
        addTeardownBlock { @MainActor in
            for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
            app.pauseDigest()
            app.podcast.pauseGeneration()
            app.podcast.player.unload()
        }
        return (app, ai, planner, fixture)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate() {
            guard Date() < deadline else { XCTFail("Timed out"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func testSummaryChatAndVoiceReadUseModeratedNestedText() async throws {
        let (app, ai, _, _) = try harness(blocked: true)
        app.select(topic: topic)
        XCTAssertTrue(app.enqueueSummary(for: topic))
        try await wait { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed, app.activities.first?.error ?? "")
        let summary = try XCTUnwrap(ai.calls.first)
        XCTAssertFalse(summary.content.contains("sama |"))
        XCTAssertTrue(summary.content.contains("[Reply to #2; item 15]"))
        app.drafts.chat = "Explain the nested replies"
        app.sendChat()
        try await wait { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(ai.calls.last?.kind, "chat")
        XCTAssertFalse(ai.calls.last?.content.contains("sama |") ?? true)
        app.browser.setPageContext(.init(url: topic.url, site: SiteKind("hackernews"), siteURL: site, forumName: "Hacker News", topic: topic, state: .topic))
        let facts = TopicFacts(postsCount: 4, highestPostNumber: 4)
        let hidden = await app.postText(2, in: .init(siteURL: site, topicID: "1"), facts: facts)
        if case .shown = hidden { XCTFail("voice must not read a blocked user") }
        let visible = await app.postText(3, in: .init(siteURL: site, topicID: "1"), facts: facts)
        if case .shown(let text) = visible { XCTAssertTrue(text.text.contains("[Reply to #2; item 15]")) }
        else { XCTFail("nested comment should be readable by voice") }
    }
    func testAgentSearchLatestReadPageAndQueryThenCite() async throws {
        func action(_ tool: String, _ args: [String: String] = [:]) -> AgentAction { .init(thought: "", tool: tool, arguments: args) }
        let (app, _, planner, _) = try harness(actions: [
            action("search_forum", ["query": "sqlite"]), action("list_latest"),
            action("read_topic", ["topic_id": "1", "page": "1", "query": "Sandhill"]),
            action("read_topic", ["topic_id": "1", "page": "2"]),
            action("final_answer", ["answer": "See [the story](https://news.ycombinator.com/item?id=1)."])
        ], blocked: true)
        app.startAgentRun(goal: "Find and read", siteURL: site)
        try await wait { app.agentRuns.first?.isFinished ?? false }
        let run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(run.result, .completed, run.error)
        XCTAssertTrue(planner.system.contains("nested"))
        let read = planner.transcripts.flatMap { $0 }.map(\.content).joined(separator: "\n")
        XCTAssertTrue(read.contains("Sandhill"), read)
        XCTAssertTrue(read.contains("[Reply to #2; item 15]"), read)
        XCTAssertFalse(read.contains("sama |"))
        XCTAssertTrue(run.knownLinks.values.contains("1"))
        XCTAssertTrue(run.steps.contains { $0.arguments["page"] == "2" && $0.isError }, "Story 1 has only one logical page")
    }
    func testAddingByAddressAndShareContextUsesURLStoryID() async throws {
        let (app, _, _, _) = try harness()
        let forum = try await app.addForum(fromAddress: site + "/item?id=1")
        XCTAssertEqual(forum.kind, SiteKind("hackernews"))
        let url = topic.url
        let context = PageContext.make(url: url, title: "Y Combinator", facts: PageFacts(url: url, elements: ["hnmain": [:]], matches: ["tr.athing.submission"]), knownForum: nil, registry: .standard)
        XCTAssertEqual(context.state, .topic)
        XCTAssertEqual(context.topic?.topicID, "1")
        let shared = SharedPage(url: url, title: "Y Combinator", detection: .unknown)
        XCTAssertNotNil(shared)
    }

    func testAgentReadsSecondLogicalPageOfARealLargeTree() async throws {
        let (app, _, planner, fixture) = try harness(actions: [
            .init(thought: "", tool: "read_topic", arguments: ["topic_id": "27016630", "page": "2"]),
            .init(thought: "", tool: "final_answer", arguments: ["answer": "Read page two."])
        ])
        fixture.item = HackerNewsFixture.data("hn-large", ext: "json")
        app.startAgentRun(goal: "Read page two", siteURL: site)
        try await wait { app.agentRuns.first?.isFinished == true }
        let read = planner.transcripts.last?.map(\.content).joined(separator: "\n") ?? ""
        XCTAssertTrue(read.contains("| #101"), read)
        XCTAssertTrue(read.contains("[Reply to #"), read)
        XCTAssertFalse(app.agentRuns.first?.steps.first?.isError ?? true)
    }

    func testDigestAndPodcastModelInputsKeepParentsAndExcludeBlockedText() async throws {
        let ai = HNPipelineAI()
        let (app, _, _, _) = try harness(blocked: true, watched: true, aiService: ai)
        app.settings.hasCompletedOnboarding = true
        app.settings.dailyDigestIncludesTrending = false
        app.makeTodaysDigest()
        try await wait { app.todaysDigest?.isComplete == true && app.digestActivity == .idle }
        XCTAssertEqual(app.todaysDigest?.cards.count, 1)
        XCTAssertTrue(ai.summaries.joined().contains("[Reply to #2; item 15]"))
        XCTAssertFalse(ai.summaries.joined().contains("rising star"))
        app.settings.podcast.engine = .onDevice
        app.podcast.makeEngine = { _, _, _ in FakeSpeechEngine() }
        app.podcast.make(play: false)
        try await wait { app.podcast.episode?.isComplete == true && !app.podcast.activity.isRunning }
        XCTAssertFalse(ai.prompts.isEmpty)
        XCTAssertTrue(ai.prompts.joined().contains("[Reply to #2; item 15]"))
        XCTAssertFalse(ai.prompts.joined().contains("rising star"))
        app.podcast.player.unload()
    }

    func testJobAndPollSubmissionsCanBeRead() async throws {
        let a = try XCTUnwrap(SiteRegistry.standard.adapter(for: SiteKind("hackernews")))
        let fixture = HackerNewsFixture()

        // Live YC self-hosted job item 49524704 ("type": "job") and live HN poll 49986710 ("type": "poll")
        let jobURL = URL(string: "https://news.ycombinator.com/item?id=49524704")!
        let pollURL = URL(string: "https://news.ycombinator.com/item?id=49986710")!
        XCTAssertEqual(PageContext.make(url: jobURL, title: "Quill (YC W20)", facts: PageFacts(url: jobURL, elements: ["hnmain": [:]], matches: ["tr.athing.submission"]), knownForum: nil, registry: .standard).state, .topic)
        XCTAssertEqual(PageContext.make(url: pollURL, title: "Poll HN", facts: PageFacts(url: pollURL, elements: ["hnmain": [:]], matches: ["tr.athing.submission"]), knownForum: nil, registry: .standard).state, .topic)

        fixture.item = Data(#"""
        {"author":"rachel_quill","children":[],"created_at_i":1788000000,"id":49524704,"points":null,
         "text":"<p>Quill (YC W20) is hiring a Fullstack SWE.</p>","title":"Quill (YC W20) Is Hiring a Fullstack SWE","type":"job","url":""}
        """#.utf8)
        let jobRead = try? await a.readTopic(
            .init(topic: .init(siteURL: site, topicID: "49524704"), cachedPages: [], knownTotalPosts: nil),
            net: fixture.network(), progress: { _ in }, onPage: nil
        )

        fixture.item = Data(#"""
        {"author":"jv22222","created_at_i":1791336057,"id":49986710,"options":[49986711,49986712],"points":6,"text":null,
         "title":"Poll HN: Is there a skill to coding with AI?","type":"poll","url":null,
         "children":[{"author":"springtimesun","children":[],"created_at_i":1791340000,"id":49988308,"points":null,"text":"Definitely a skill.","type":"comment"}]}
        """#.utf8)
        let pollRead = try? await a.readTopic(
            .init(topic: .init(siteURL: site, topicID: "49986710"), cachedPages: [], knownTotalPosts: nil),
            net: fixture.network(), progress: { _ in }, onPage: nil
        )

        XCTAssertEqual(try XCTUnwrap(jobRead).totalPosts, 1)
        XCTAssertFalse(try XCTUnwrap(jobRead).content.contains("Link: "))
        XCTAssertEqual(try XCTUnwrap(pollRead).totalPosts, 2)
        XCTAssertTrue(try XCTUnwrap(pollRead).content.contains("Definitely a skill."))
        let overview = try await a.overview(.init(siteURL: site, topicID: "49986710"), net: fixture.network())
        XCTAssertEqual(overview.facts?.posts.map(\.username), ["jv22222", "springtimesun"])
    }

    func testAppAndShareProbeRequireSubmissionMarkup() throws {
        let shareDir: URL
        if let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("ForumindShare.appex"),
           FileManager.default.fileExists(atPath: appex.path) {
            shareDir = appex
        } else {
            shareDir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ForumindShare", isDirectory: true)
        }
        let script = try String(contentsOf: shareDir.appendingPathComponent("PageFactsProbe.js"), encoding: .utf8)

        func runShareProbe(url: String, title: String, hasHNMain: Bool, hasSubmission: Bool) throws -> [String: Any] {
            let js = try XCTUnwrap(JSContext())
            js.evaluateScript("""
            var window = { location: { href: \(String(decoding: try JSONEncoder().encode(url), as: UTF8.self)) } };
            var document = {
              title: \(String(decoding: try JSONEncoder().encode(title), as: UTF8.self)),
              documentElement: { className: "" },
              body: { className: "" },
              getElementById: function (id) { return (id === "hnmain" && \(hasHNMain)) ? { dataset: {} } : null; },
              querySelector: function (sel) {
                if (sel === "tr.athing.submission") return \(hasSubmission) ? {} : null;
                return null;
              }
            };
            var out = null;
            """)
            js.evaluateScript(script)
            js.evaluateScript("ExtensionPreprocessingJS.run({ completionFunction: function (r) { out = r; } });")
            return try XCTUnwrap(js.objectForKeyedSubscript("out")?.toDictionary() as? [String: Any])
        }

        for (id, main, submission) in [("1", true, true), ("49524704", true, true),
                                        ("49986710", true, true), ("15", true, false),
                                        ("49986711", true, false), ("999999999999", false, false)] {
            let url = URL(string: site + "/item?id=" + id)!
            let probe = try runShareProbe(url: url.absoluteString, title: "Hacker News", hasHNMain: main, hasSubmission: submission)
            let shared = try XCTUnwrap(SharedPageLoader.page(fromProbeResults: probe))
            if main {
                guard case .site(let match) = shared.detection else { return XCTFail("HN markup must identify the site") }
                XCTAssertEqual(match.topicID, submission ? id : nil)
            } else {
                XCTAssertEqual(shared.detection, .notDetected)
            }
            for known in [nil, KnownForumSite(siteURL: site, name: "Hacker News", iconURL: nil, kind: .hackerNews)] {
                let context = PageContext.make(url: url, title: "Hacker News", facts: PageFacts(probe: probe, fallbackURL: url), knownForum: known, registry: .standard)
                XCTAssertEqual(context.state == .topic, submission, id)
                XCTAssertEqual(context.topic?.topicID, submission ? id : nil)
            }
        }
    }

    func testTrendingDigestAndPodcastExcludeBlockedOpeningAuthor() async throws {
        let ai = HNPipelineAI()
        let (app, _, _, fixture) = try harness(aiService: ai)
        // Keep a visible control so the entire digest and podcast pipeline runs.
        fixture.search = Data(#"{"hits":[{"objectID":"27016630","author":"phiresky","title":"Hosting SQLite databases on GitHub Pages","num_comments":0},{"objectID":"1","author":"pg","title":"Y Combinator","num_comments":3}]}"#.utf8)
        app.pin(Forum(siteURL: site, kind: .hackerNews, name: "Hacker News"))
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.settings.dailyDigestIncludesWatched = false
        app.settings.dailyDigestIncludesTrending = true
        app.settings.dailyDigestMaxCards = 3
        // Pre-existing block on "phiresky" (author of 27016630)
        app.settings.blockedUsers = [BlockedUser(siteURL: site, username: "phiresky", blockedAt: Date(timeIntervalSince1970: 1))]
        app.applyModerationRules()

        app.makeTodaysDigest()
        try await wait { app.todaysDigest?.isComplete == true && app.digestActivity == .idle }

        app.settings.podcast.engine = .onDevice
        app.podcast.makeEngine = { _, _, _ in FakeSpeechEngine() }
        app.podcast.make(play: false)
        try await wait { app.podcast.episode?.isComplete == true && !app.podcast.activity.isRunning }
        let introText = app.podcast.episode?.entries.first?.chapter.spokenText ?? ""
        let podcastPrompts = ai.prompts.joined(separator: "\n")
        app.podcast.player.unload()

        XCTAssertEqual(app.todaysDigest?.cards.map(\.topicID), ["1"])
        XCTAssertFalse(ai.prompts.isEmpty)
        XCTAssertFalse(fixture.requests.contains { $0.url?.path == "/api/v1/items/27016630" })
        XCTAssertFalse(app.todaysDigest?.cards.map(\.topicID).contains("27016630") == true,
                       "Blocked author phiresky's story 27016630 became a Trending Digest card")
        XCTAssertFalse(podcastPrompts.contains("Hosting SQLite databases on GitHub Pages"),
                       "Blocked author phiresky's story title was sent to Podcast LLM")
        XCTAssertFalse(introText.contains("Hosting SQLite databases on GitHub Pages"),
                       "Blocked author phiresky's story title was spoken in Podcast intro")
    }

    func testVoiceBriefAndAgentReadExcludeHiddenTitles() async throws {
        for rule in ["word", "author", "post"] {
            let (app, _, planner, _) = try harness(actions: [
                .init(thought: "", tool: "read_topic", arguments: ["topic_id": "1"]),
                .init(thought: "", tool: "summarize_topic", arguments: ["topic_id": "1"]),
                .init(thought: "", tool: "saved_summaries", arguments: [:]),
                .init(thought: "", tool: "final_answer", arguments: ["answer": "Done."])
            ])
            switch rule {
            case "word": _ = app.addFilteredWord("Combinator")
            case "author": app.block("pg", on: site)
            default: app.blockPost(1, topicID: "1", on: site)
            }
            app.browser.setPageContext(.init(url: topic.url, site: .hackerNews, siteURL: site, forumName: "Hacker News", topic: topic, state: .topic))
            let result = await app.voiceTopicBrief()
            let brief = try XCTUnwrap(result)
            var voiceContext = VoiceContext()
            let note = voiceContext.topicBriefNote(brief) ?? ""
            XCTAssertFalse(note.contains("Combinator"), rule + ": " + note)
            app.startAgentRun(goal: "Check story 1", siteURL: site)
            try await wait { app.agentRuns.first?.isFinished == true }
            let observation = planner.transcripts.flatMap { $0 }.map(\.content).joined(separator: "\n")
            XCTAssertTrue(observation.contains("dmon |"), "The read must retain visible replies")
            XCTAssertFalse(observation.contains("Combinator"), rule + ": " + observation)
        }
    }

    func testOverviewBlocksCommentNavigationBeforeSessionExists() async throws {
        let (app, _, _, _) = try harness(blocked: true)
        app.browser.setPageContext(.init(url: topic.url, site: .hackerNews, siteURL: site, forumName: "Hacker News", topic: topic, state: .topic))
        // PhoneBrowser sets barShowsTopicFacts = true, which prefetches topicOverview
        _ = await app.topicOverview(siteURL: site, topicID: "1")
        XCTAssertNil(app.currentSession)
        // Post #2 on story 1 is authored by blocked user "sama"
        let result = await app.openTopic(.topic("1"), at: .post(2), includeContent: false)
        XCTAssertEqual(result.status, .hidden)
        app.select(topic: topic)
        XCTAssertEqual(app.currentSession?.source, "")
        XCTAssertTrue(app.currentHiddenPosts.contains(2))
    }

    func testDigestRejectsHiddenTrendingOpeningAndEmptyWatchedContent() async throws {
        for trending in [false, true] {
            let (app, ai, _, fixture) = try harness()
            if trending {
                // No overview was prefetched. Visible replies must not resurrect a blocked author's trending story.
                app.block("pg", on: site)
            } else {
                fixture.item = Data(#"{"id":1,"type":"story","author":"alice","title":"Hidden story","children":[]}"#.utf8)
                app.blockPost(1, topicID: "1", on: site)
            }
            let card = DigestCard(siteURL: site, topicID: "1", title: "Hidden story",
                                  reason: trending ? .trending : .newReplies(1), postCount: 1)
            do {
                _ = try await app.summarizeDigestCard(card, digestID: UUID(), context: app.runSettings(role: .assistant, topicKey: card.topicKey))
                XCTFail("A hidden trending opening or empty moderated topic cannot become a completed card")
            } catch AssistantError.emptyResponse {
                // Expected: no model request, even when prefetch metadata was absent.
            }
            XCTAssertTrue(ai.calls.isEmpty)
        }
    }

    func testHTTPSharedStoryStartsSummaryAfterHTTPSRedirect() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PersistentStore(fileURL: dir.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var snap = AppSnapshot(forums: [
            Forum(siteURL: site, kind: .hackerNews, name: "Hacker News"),
            Forum(siteURL: "https://forum.example.com", kind: .discourse, name: "Example")
        ])
        snap.settings.hasCompletedOnboarding = true
        snap.settings.acceptedTermsVersion = ModerationTerms.currentVersion
        try store.save(snap)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let fixture = HackerNewsFixture()
        let ai = StateAIStub(); ai.gated = false
        let liveApp = AppModel(store: store, forumService: fixture.network().service, sites: .standard, aiService: ai)
        liveApp.usesDirectForumRequests = true
        liveApp.allowAllAIProviders()
        liveApp.selectModel(.init(provider: .ollama, model: "model-a"), for: .both)
        let onPage = liveApp.browser.onPageContextChanged
        liveApp.browser.onPageContextChanged = nil
        addTeardownBlock { @MainActor in
            for r in liveApp.activities where !r.status.isTerminal { liveApp.cancel(record: r) }
        }

        // Control: Discourse http:// -> https:// 301 redirect starts Summarize
        liveApp.openShared(url: URL(string: "http://forum.example.com/t/a-topic/1")!, action: "summary", autoRun: true)
        let discourseRedirected = PageContext(
            url: URL(string: "https://forum.example.com/t/a-topic/1")!, site: .discourse,
            siteURL: "https://forum.example.com", forumName: "Example",
            topic: ForumTopic(siteURL: "https://forum.example.com", topicID: "1", url: URL(string: "https://forum.example.com/t/a-topic/1")!, title: "Topic 1"),
            state: .topic
        )
        liveApp.browser.setPageContext(discourseRedirected)
        onPage?(discourseRedirected)
        XCTAssertEqual(liveApp.activities.count, 1, "Control: Discourse http->https redirect starts Summarize")
        for r in liveApp.activities where !r.status.isTerminal { liveApp.cancel(record: r) }

        // Hacker News: http://news.ycombinator.com/item?id=1 301-redirects to https://news.ycombinator.com/item?id=1
        liveApp.openShared(url: URL(string: "http://news.ycombinator.com/item?id=1")!, action: "summary", autoRun: true)
        let hnRedirected = PageContext(url: topic.url, site: .hackerNews, siteURL: site, forumName: "Hacker News", topic: topic, state: .topic)
        liveApp.browser.setPageContext(hnRedirected)
        onPage?(hnRedirected)

        XCTAssertEqual(liveApp.activities.count, 2, "Shared http://news.ycombinator.com/item?id=1 silently dropped Summarize after 301 redirect to https://")
    }
}

private final class HNPipelineAI: AIService {
    @MainActor var summaries: [String] = []
    @MainActor var prompts: [String] = []
    override func generateSummary(content: String, configuration: ProviderConfiguration, provider: AIProvider,
                                  customPrompt: String, discussion: DiscussionProfile, batchLimit: Int = SummaryBatchLimit.default,
                                  onDelta: @escaping @MainActor (String) -> Void,
                                  onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }) async throws -> String {
        await MainActor.run { summaries.append(content) }
        return content
    }
    override func complete(system: String, messages: [ChatMessage], configuration: ProviderConfiguration,
                           provider: AIProvider, maxTokens: Int = 4_096) async throws -> String {
        await MainActor.run { prompts.append(messages.map(\.content).joined(separator: "\n")) }
        return #"{"turns":[{"speaker":"A","text":"Readers discuss the story."},{"speaker":"B","text":"The replies add context."}]}"#
    }
}
