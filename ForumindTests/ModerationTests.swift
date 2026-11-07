import XCTest
@testable import Forumind

/// Guideline 1.2 moderation: blocking, word filters, the developer's list,
/// reports, and the Terms of Use setting.
@MainActor
final class ModerationTests: XCTestCase {
    private let site = "https://forum.example.com"
    private let other = "https://other.example.org"

    private let raw = """
    alice | 2026-01-01 10:00:00 UTC | #1

    Welcome to the topic.

    -------------------------

    Bob | 2026-01-01 11:00:00 UTC | #2

    This is spam, buy now.

    -------------------------

    carol | 2026-01-01 12:00:00 UTC | #3

    A helpful reply.

    -------------------------
    """

    // MARK: Filter

    func testNoRulesLeavesTheTextAlone() {
        XCTAssertEqual(ModerationFilter.filter(raw, siteURL: site, topicID: "1", rules: .none), raw)
    }

    func testBlockedUsersPostsAreRemovedOnTheirForumOnly() {
        let rules = ModerationRules(blockedUsers: [site: ["bob"]])
        let filtered = ModerationFilter.filter(raw, siteURL: site, topicID: "1", rules: rules)
        XCTAssertFalse(filtered.contains("buy now"))
        XCTAssertFalse(filtered.contains("Bob |"))
        XCTAssertTrue(filtered.contains("Welcome to the topic."))
        XCTAssertTrue(filtered.contains("A helpful reply."))
        // Another forum's Bob is someone else.
        XCTAssertEqual(ModerationFilter.filter(raw, siteURL: other, topicID: "1", rules: rules), raw)
    }

    func testFilteredWordsRemoveMatchingPostsCaseInsensitively() {
        let rules = ModerationRules(filteredWords: ModerationRules.normalizedWords(["  SPAM ", "spam", ""]))
        XCTAssertEqual(rules.filteredWords, ["spam"])
        let filtered = ModerationFilter.filter(raw, siteURL: site, topicID: "1", rules: rules)
        XCTAssertFalse(filtered.contains("buy now"))
        XCTAssertTrue(filtered.contains("A helpful reply."))
    }

    func testDevelopersListHidesPostsAndUsersEverywhere() {
        let list = RemoteModerationList(
            users: [RemoteModerationList.User(site: nil, username: "Carol")],
            posts: [RemoteModerationList.Post(site: site + "/", topic: 7, post: 1)]
        )
        let rules = ModerationRules(settings: AppSettings(), remote: list)
        let filtered = ModerationFilter.filter(raw, siteURL: site, topicID: "7", rules: rules)
        XCTAssertFalse(filtered.contains("Welcome to the topic."), "Post #1 of topic 7 is on the list.")
        XCTAssertFalse(filtered.contains("A helpful reply."), "Carol is hidden on every forum.")
        XCTAssertTrue(filtered.contains("buy now"))
        // Post #1 of another topic stays.
        XCTAssertTrue(ModerationFilter.filter(raw, siteURL: site, topicID: "8", rules: rules).contains("Welcome"))
    }

    func testTextThatIsNotRawIsHiddenOnlyForAFilteredWord() {
        let rules = ModerationRules(filteredWords: ["spam"])
        XCTAssertEqual(ModerationFilter.filter("just text", siteURL: site, topicID: "1", rules: rules), "just text")
        XCTAssertEqual(ModerationFilter.filter("some spam here", siteURL: site, topicID: "1", rules: rules), "")
    }

    func testRemoteListDecodesWithMissingKeys() throws {
        let list = try JSONDecoder().decode(RemoteModerationList.self, from: Data(#"{"users":[{"username":"x"}]}"#.utf8))
        XCTAssertEqual(list.users, [RemoteModerationList.User(site: nil, username: "x")])
        XCTAssertTrue(list.posts.isEmpty)
        XCTAssertTrue(list.words.isEmpty)
    }

    func testTopicTitlesFollowCurrentRulesAcrossAllSitesAndCachedSources() {
        for siteURL in [site, "https://wordpress.example.org", "https://news.ycombinator.com"] {
            let key = TopicIdentity.key(siteURL: siteURL, topicID: "1")
            let url = URL(string: siteURL + "/?p=1")!
            let title = "Opening title"
            var session = TopicSession(siteURL: siteURL, topicID: "1", url: url, title: title)
            session.source = "alice | 2026-01-01 10:00:00 UTC | #1\nOpening text"
            session.openedByUserAt = Date()
            let app = makeApp(sessions: [session])
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), title)
            // Some adapters supply only the post list, rather than openingPoster.
            app.topicOverviews[key] = ForumTopicOverview(
                siteURL: siteURL, topicID: "1", title: title, slug: "", url: url, postCount: 2,
                facts: TopicFacts(postsCount: 2, posts: [.init(id: 1, number: 1, username: "bob")])
            )
            app.block("bob", on: siteURL)
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), "")
            app.topicOverviews[key] = nil
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), title)
            app.block("alice", on: siteURL)
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), "")
            // A cached digest title also stays out of the podcast's intro.
            let card = DigestCard(siteURL: siteURL, topicID: "1", title: title, reason: .trending, postCount: 2)
            XCTAssertEqual(app.sanitizedDigestCard(card).title, "")
            app.settings.blockedUsers = []
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), title)
            app.blockPost(1, topicID: "1", on: siteURL)
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), "")
            app.settings.blockedPosts = []
            _ = app.addFilteredWord("opening")
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), "")
            app.settings.filteredWords = []
        }
    }

    // MARK: Browser script config

    func testScriptConfigCoversTheCurrentForumOnly() {
        let rules = ModerationRules(
            blockedUsers: [site: ["bob"], other: ["dave"]],
            filteredWords: ["spam"],
            globallyHiddenUsers: ["eve"],
            hiddenPosts: ["\(site)|7": [3, 1], "\(other)|7": [2]]
        )
        let config = ModerationScript.config(rules: rules, siteURL: site)
        XCTAssertEqual(config.users, ["bob", "eve"])
        XCTAssertEqual(config.words, ["spam"])
        XCTAssertEqual(config.posts, ["7": [1, 3]])
        XCTAssertEqual(ModerationScript.config(rules: rules, siteURL: nil).users, ["eve"])
    }

    // MARK: Reports

    func testReportEmailNamesThePostAndReason() throws {
        let target = ReportTarget(
            siteURL: site,
            forumName: "Example",
            topicTitle: "A topic",
            topicURL: URL(string: "https://forum.example.com/t/a-topic/42/9?u=me"),
            kind: .post(number: 3, username: "bob")
        )
        let subject = ModerationReport.subject(for: target, blocked: false)
        XCTAssertEqual(subject, "Forumind report: post #3 by @bob on forum.example.com")
        let body = ModerationReport.body(for: target, reason: .harassment, note: " rude ", blocked: false, links: DiscourseLinks(), appVersion: "1.0 (1)")
        XCTAssertTrue(body.contains("Post URL: https://forum.example.com/t/a-topic/42/3"))
        XCTAssertTrue(body.contains("Reason: harassment"))
        XCTAssertTrue(body.contains("Details:\nrude"))
        XCTAssertTrue(ModerationReport.subject(for: target, blocked: true).hasPrefix("Forumind block:"))

        let mailto = try XCTUnwrap(ModerationReport.mailtoURL(subject: subject, body: body))
        XCTAssertEqual(mailto.scheme, "mailto")
        XCTAssertTrue(mailto.absoluteString.hasPrefix("mailto:\(ModerationTerms.reportEmail)?subject="))
    }

    func testPostURLKeepsTheTopicPathOnly() {
        let url = { (string: String) in URL(string: string)! }
        XCTAssertEqual(
            DiscourseLinks().postURL(topicURL: url("https://f.example/t/slug/42"), number: 5, anchor: nil).absoluteString,
            "https://f.example/t/slug/42/5"
        )
        XCTAssertEqual(
            DiscourseLinks().postURL(topicURL: url("https://f.example/forum/t/slug/42/17/"), number: 5, anchor: nil).absoluteString,
            "https://f.example/forum/t/slug/42/5"
        )
    }

    // MARK: Settings and sync

    func testOlderSettingsDecodeWithNoBlocksAndNoAcceptedTerms() throws {
        let data = try JSONEncoder().encode(AppSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["blockedUsers", "filteredWords", "acceptedTermsVersion"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.blockedUsers.isEmpty)
        XCTAssertTrue(decoded.filteredWords.isEmpty)
        XCTAssertFalse(decoded.hasAcceptedCurrentTerms)
    }

    func testBlocksSyncButTermsAcceptanceStaysOnTheDevice() throws {
        var settings = AppSettings()
        settings.blockedUsers = [BlockedUser(siteURL: site, username: "bob")]
        settings.filteredWords = ["spam"]
        settings.acceptedTermsVersion = ModerationTerms.currentVersion
        let units = try SyncSchema.settingsUnits(settings)
        XCTAssertNotNil(units["blockedUsers"])
        XCTAssertNotNil(units["filteredWords"])
        XCTAssertNil(units["acceptedTermsVersion"])
        XCTAssertTrue(SyncSettings.deviceLocalKeys.contains("acceptedTermsVersion"))
    }

    func testBlockingFiltersPromptsAndSurvivesAReset() throws {
        let app = makeApp()
        app.block("@Bob ", on: site)
        app.block("bob", on: site)
        XCTAssertEqual(app.settings.blockedUsers.map(\.username), ["Bob"], "Blocking twice keeps one entry.")
        XCTAssertTrue(app.isBlocked("BOB", on: site))
        XCTAssertFalse(app.moderated(raw, siteURL: site, topicID: "1").contains("buy now"))
        XCTAssertTrue(app.browser.moderationRules.hidesUser("bob", siteURL: site), "The browser gets the new rules.")

        XCTAssertTrue(app.addFilteredWord("helpful"))
        XCTAssertFalse(app.addFilteredWord("HELPFUL"))
        XCTAssertFalse(app.moderated(raw, siteURL: site, topicID: "1").contains("A helpful reply."))

        app.acceptTerms()
        app.resetSettings()
        XCTAssertTrue(app.isBlocked("bob", on: site))
        XCTAssertEqual(app.settings.filteredWords, ["helpful"])
        XCTAssertFalse(app.needsTermsAcceptance)

        app.unblock(try XCTUnwrap(app.settings.blockedUsers.first))
        app.removeFilteredWords(atOffsets: [0])
        XCTAssertEqual(app.moderated(raw, siteURL: site, topicID: "1"), raw)
    }

    func testNewInstallsMustAcceptTheTerms() {
        let app = makeApp()
        XCTAssertTrue(app.needsTermsAcceptance)
        app.acceptTerms()
        XCTAssertFalse(app.needsTermsAcceptance)
        XCTAssertEqual(app.settings.acceptedTermsVersion, ModerationTerms.currentVersion)
    }

    func testPostPreviewAndExportFilterBlockedUsersAndWords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moderation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PersistentStore(
            fileURL: directory.appendingPathComponent("state.json"),
            keys: InMemoryProviderKeyStore()
        )
        let url = try XCTUnwrap(URL(string: "\(site)/t/a-topic/1"))
        let topic = ForumTopic(siteURL: site, topicID: "1", url: url, title: "A topic")
        var session = TopicSession(siteURL: site, topicID: "1", url: url, title: "A topic")
        session.seedSource(raw)
        session.summary = "Clean summary."
        var snapshot = AppSnapshot()
        snapshot.sessions = [session]
        try store.save(snapshot)

        let app = AppModel(store: store)
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil
        let page = PageContext(url: url, site: .discourse, siteURL: site, forumName: "Example", topic: topic, state: .topic)
        app.browser.setPageContext(page)
        handler?(page)

        app.block("bob", on: site)
        XCTAssertTrue(app.addFilteredWord("helpful"))

        let preview = PostPreviewView(app: app).source
        XCTAssertTrue(preview.contains("Welcome to the topic."))
        XCTAssertFalse(preview.contains("Bob |"), "Blocked author leaked into Post & Responses preview.")
        XCTAssertFalse(preview.contains("buy now"), "Blocked author's text leaked into Post & Responses preview.")
        XCTAssertFalse(preview.contains("A helpful reply."), "Filtered word post leaked into Post & Responses preview.")

        let exported = AssistantPanel(app: app, onExpand: { _ in }).payload.text(options: ExportOptions())
        XCTAssertTrue(exported.contains("Clean summary."))
        XCTAssertTrue(exported.contains("Welcome to the topic."))
        XCTAssertFalse(exported.contains("Bob |"), "Blocked author leaked into default Copy/Share/Export.")
        XCTAssertFalse(exported.contains("buy now"), "Blocked author's text leaked into default Copy/Share/Export.")
        XCTAssertFalse(exported.contains("A helpful reply."), "Filtered word post leaked into default Copy/Share/Export.")

        app.unblock(try XCTUnwrap(app.settings.blockedUsers.first))
        app.removeFilteredWords(atOffsets: [0])
        XCTAssertEqual(PostPreviewView(app: app).source, raw)
    }

    // MARK: Reporting AI digests, podcasts, and voice answers

    func testReportingAIDigestsPodcastsAndVoiceAnswers() throws {
        let app = makeApp()
        app.selectModel(ModelSelection(provider: .openAI, model: "gpt-test"), for: .both)

        var card = DigestCard(
            siteURL: site,
            topicID: "42",
            title: "Digest Topic",
            slug: "digest-topic",
            reason: .trending,
            postCount: 15,
            summary: "## Digest Summary\n- Point #1",
            state: .done
        )
        let digest = DailyDigest(day: "2026-11-06", cards: [card])

        let cardReport = try XCTUnwrap(app.aiOutputReport(for: card, digest: digest))
        XCTAssertEqual(cardReport.topicTitle, "Digest Topic")
        if case .aiOutput(let out) = cardReport.kind {
            XCTAssertEqual(out.feature, .digest)
            XCTAssertTrue(out.text.contains("Point #1"))
        } else {
            XCTFail("Expected .aiOutput(.digest)")
        }
        XCTAssertTrue(ModerationReport.subject(for: cardReport, blocked: false).contains("daily digest"))

        let digestReport = try XCTUnwrap(app.aiOutputReport(for: digest))
        if case .aiOutput(let out) = digestReport.kind {
            XCTAssertEqual(out.feature, .digest)
        } else {
            XCTFail("Expected .aiOutput(.digest)")
        }
        card.summary = ""
        XCTAssertNil(app.aiOutputReport(for: card, digest: digest))

        var chapter = PodcastChapter(card: digest.cards[0])
        chapter.turns = [
            PodcastTurn(speaker: .a, text: "Welcome to the chapter."),
            PodcastTurn(speaker: .b, text: "Here is what happened.")
        ]
        var entry = PodcastEpisode.Entry(chapter: chapter)
        entry.state = .ready
        let episode = PodcastEpisode(
            digestID: digest.id,
            day: digest.day,
            title: "Today's Podcast",
            language: "en",
            hosts: PodcastHosts(a: "A", b: "B"),
            engine: .onDevice,
            voices: PodcastVoices(a: "A", b: "B"),
            minutesPerChapter: 1,
            entries: [entry]
        )

        let chapterReport = try XCTUnwrap(app.aiOutputReport(for: episode, chapter: chapter))
        if case .aiOutput(let out) = chapterReport.kind {
            XCTAssertEqual(out.feature, .podcast)
            XCTAssertTrue(out.text.contains("Here is what happened."))
        } else {
            XCTFail("Expected .aiOutput(.podcast)")
        }
        XCTAssertTrue(ModerationReport.subject(for: chapterReport, blocked: false).contains("podcast"))

        let episodeReport = try XCTUnwrap(app.aiOutputReport(for: episode))
        if case .aiOutput(let out) = episodeReport.kind {
            XCTAssertEqual(out.feature, .podcast)
            XCTAssertTrue(out.text.contains("Digest Topic"))
        } else {
            XCTFail("Expected .aiOutput(.podcast)")
        }

        let voiceSession = VoiceSession(
            configuration: .init(endpoint: .aiStudio, apiKey: "k", settings: VoiceSettings(), hasConsent: true),
            transport: { FakeLiveTransport() },
            audio: FakeVoiceAudio(),
            navigator: FakeVoiceNavigator(),
            runsLoop: false
        )
        XCTAssertNil(app.aiOutputReport(for: voiceSession), "Empty voice answer is not reportable")
        voiceSession.receive(Data(#"{"serverContent":{"outputTranscription":{"text":"The accepted answer is in post #4."}}}"#.utf8))
        let voiceReport = try XCTUnwrap(app.aiOutputReport(for: voiceSession))
        if case .aiOutput(let out) = voiceReport.kind {
            XCTAssertEqual(out.feature, .voiceAnswer)
            XCTAssertEqual(out.text, "The accepted answer is in post #4.")
        } else {
            XCTFail("Expected .aiOutput(.voiceAnswer)")
        }
        XCTAssertTrue(ModerationReport.subject(for: voiceReport, blocked: false).contains("voice answer"))
    }

    // MARK: Blocked posts and accounts excluded across every AI path

    func testBlockedPostAndBlockedUserAreExcludedFromSummaryAndChat() async throws {
        final class CapturingAI: AIService, @unchecked Sendable {
            var summaryContents: [String] = []
            var chatSources: [String] = []

            override func generateSummary(
                content: String,
                configuration: ProviderConfiguration,
                provider: AIProvider,
                customPrompt: String,
                discussion: DiscussionProfile,
                batchLimit: Int = SummaryBatchLimit.default,
                onDelta: @escaping @MainActor (String) -> Void,
                onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }
            ) async throws -> String {
                summaryContents.append(content)
                return "## Summary\n- Done"
            }

            override func answer(
                source: String,
                summary: String,
                history: [ChatMessage],
                contextLimit: Int,
                customPrompt: String,
                discussion: DiscussionProfile,
                configuration: ProviderConfiguration,
                provider: AIProvider,
                onDelta: @escaping @MainActor (String) -> Void,
                summaryIsStale: Bool = false
            ) async throws -> String {
                chatSources.append(source)
                return "Chat answer."
            }
        }

        ModerationURLStub.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/t/1.json") {
                body = #"{"title":"A topic","slug":"a-topic","posts_count":3,"highest_post_number":3}"#
            } else if path.hasSuffix("/raw/1") {
                body = self.raw
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": path.hasSuffix(".json") ? "application/json" : "text/plain"]
            )!
            return (response, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ModerationURLStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let ai = CapturingAI()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moderation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let url = try XCTUnwrap(URL(string: "\(site)/t/a-topic/1"))
        let topic = ForumTopic(siteURL: site, topicID: "1", url: url, title: "A topic")
        var session = TopicSession(siteURL: site, topicID: "1", url: url, title: "A topic")
        session.seedSource(raw)
        try store.save(AppSnapshot(sessions: [session], forums: [Forum(siteURL: site, kind: .discourse, name: "Example")]))

        let app = AppModel(store: store, forumService: forumService, aiService: ai)
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama"), for: .both)
        app.select(topic: topic)

        // Block user Bob (#2) and block post #3 (carol).
        app.block("bob", on: site)
        app.blockPost(3, topicID: "1", on: site)
        XCTAssertTrue(app.isPostBlocked(3, topicID: "1", on: site))

        // 1. Summary path
        XCTAssertTrue(app.enqueueSummary(for: topic))
        let deadline = Date().addingTimeInterval(5)
        while app.activities.first?.status != .completed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let summaryInput = try XCTUnwrap(ai.summaryContents.first)
        XCTAssertTrue(summaryInput.contains("Welcome to the topic."))
        XCTAssertFalse(summaryInput.contains("buy now"), "Blocked user's post leaked to summary model")
        XCTAssertFalse(summaryInput.contains("A helpful reply."), "Blocked post #3 leaked to summary model")

        // 2. Chat path
        app.drafts.chat = "What was said?"
        app.sendChat()
        while app.activities.contains(where: { $0.type == .chat && !$0.status.isTerminal }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let chatInput = try XCTUnwrap(ai.chatSources.first)
        XCTAssertTrue(chatInput.contains("Welcome to the topic."))
        XCTAssertFalse(chatInput.contains("buy now"), "Blocked user's post leaked to chat model")
        XCTAssertFalse(chatInput.contains("A helpful reply."), "Blocked post #3 leaked to chat model")
    }

    func testBlockedPostAndBlockedUserAreExcludedFromAgentPaths() async throws {
        ModerationURLStub.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/search.json") {
                body = #"""
                {
                  "topics": [
                    {"id": 1, "title": "Topic One", "slug": "topic-one", "posts_count": 3},
                    {"id": 2, "title": "Topic Two", "slug": "topic-two", "posts_count": 2}
                  ],
                  "posts": [
                    {"id": 10, "topic_id": 1, "post_number": 2, "username": "bob", "blurb": "Bob spam blurb"},
                    {"id": 11, "topic_id": 1, "post_number": 3, "username": "carol", "blurb": "Carol blocked post blurb"},
                    {"id": 12, "topic_id": 2, "post_number": 1, "username": "alice", "blurb": "Alice clean blurb"}
                  ]
                }
                """#
            } else if path.hasSuffix("/t/1.json") {
                body = #"{"title":"Topic One","slug":"topic-one","posts_count":3,"highest_post_number":3}"#
            } else if path.hasSuffix("/raw/1") {
                body = self.raw
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": path.hasSuffix(".json") ? "application/json" : "text/plain"]
            )!
            return (response, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ModerationURLStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "search_forum", arguments: ["query": "blurb"]),
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "1"]),
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "1", "query": "helpful"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done."])
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        try store.save(AppSnapshot(forums: [Forum(siteURL: site, kind: .discourse, name: "Example")]))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(store: store, forumService: forumService, aiService: ai, planner: planner)
        app.usesDirectForumRequests = true
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama"), for: .both)
        app.browser.onPageContextChanged = nil

        app.block("bob", on: site)
        app.blockPost(3, topicID: "1", on: site)

        app.startAgentRun(goal: "Check forum", siteURL: site)
        let deadline = Date().addingTimeInterval(10)
        while !(app.agentRuns.first?.isFinished ?? false), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(run.result, .completed, run.error)

        // 1. Agent search_forum observation excludes blocked user bob and blocked post #3 (leaving only Topic Two).
        let searchObs = try XCTUnwrap(planner.transcripts[1].last?.content)
        XCTAssertFalse(searchObs.contains("Bob spam blurb"), searchObs)
        XCTAssertFalse(searchObs.contains("Carol blocked post blurb"), searchObs)
        XCTAssertFalse(searchObs.contains("Topic One"), "Topic whose only search hits were blocked must not appear in search observation")
        XCTAssertTrue(searchObs.contains("Alice clean blurb"), searchObs)

        // 2. Agent read_topic observation excludes blocked user bob and blocked post #3.
        let readObs = try XCTUnwrap(planner.transcripts[2].last?.content)
        XCTAssertTrue(readObs.contains("Welcome to the topic."))
        XCTAssertFalse(readObs.contains("buy now"))
        XCTAssertFalse(readObs.contains("A helpful reply."))

        // 3. Agent read_topic(query: "helpful") finds 0 matching posts because post #3 is blocked.
        let queryObs = try XCTUnwrap(planner.transcripts[3].last?.content)
        XCTAssertTrue(queryObs.contains("Showing: 0 matching posts for \"helpful\""), queryObs)
        XCTAssertFalse(queryObs.contains("A helpful reply."), queryObs)
    }

    func testBlockedPostAndBlockedUserAreExcludedFromDigestAndPodcast() {
        let app = makeApp()
        app.block("bob", on: site)
        app.blockPost(3, topicID: "1", on: site)
        let rules = app.browser.moderationRules

        let facts = TopicFacts(
            postsCount: 4,
            highestPostNumber: 4,
            stream: [10, 11, 12, 13],
            openingPoster: "alice",
            acceptedAnswer: TopicFacts.AcceptedAnswer(postNumber: 3, username: "carol"),
            posts: [
                TopicFacts.Post(id: 10, number: 1, username: "alice", likeCount: 1),
                TopicFacts.Post(id: 11, number: 2, username: "bob", likeCount: 50),
                TopicFacts.Post(id: 12, number: 3, username: "carol", likeCount: 30),
                TopicFacts.Post(id: 13, number: 4, username: "dave", likeCount: 5)
            ]
        )
        let overview = ForumTopicOverview(
            siteURL: site,
            topicID: "1",
            title: "Digest Topic",
            slug: "digest-topic",
            url: URL(string: "\(site)/t/digest-topic/1")!,
            postCount: 4,
            facts: facts
        )

        // DigestTopicFacts excludes blocked post #3 from acceptedAnswerPost and blocked user bob (#2) + blocked post #3 from topPost.
        let digestFacts = DigestTopicFacts(overview: overview, rules: rules)
        XCTAssertNil(digestFacts.acceptedAnswerPost, "Blocked post #3 must not be selected as acceptedAnswerPost")
        XCTAssertEqual(digestFacts.topPost, 4, "Blocked user bob (#2) and blocked post #3 must not be selected as topPost")

        // Podcast multi-page rawPages moderation when session.source is empty.
        var session = TopicSession(siteURL: site, topicID: "1", url: overview.url, title: overview.title)
        session.rawPages = [
            RawForumPage(page: 1, content: "alice | 2026-01-01 10:00:00 UTC | #1\nOpening post\n\n\nBob | 2026-01-01 11:00:00 UTC | #2\nSpam on page 1\n"),
            RawForumPage(page: 2, content: "carol | 2026-01-01 12:00:00 UTC | #3\nBlocked post on page 2\n\n\ndave | 2026-01-01 13:00:00 UTC | #4\nClean reply on page 2\n")
        ]
        session.source = ""
        let joined = RawTopicFormat.join(session.rawPages.map(\.content))
        let moderatedPodcastSource = app.moderated(joined, siteURL: site, topicID: "1")
        XCTAssertTrue(moderatedPodcastSource.contains("Opening post"))
        XCTAssertTrue(moderatedPodcastSource.contains("Clean reply on page 2"))
        XCTAssertFalse(moderatedPodcastSource.contains("Spam on page 1"), "Blocked user leaked in multi-page podcast source")
        XCTAssertFalse(moderatedPodcastSource.contains("Blocked post on page 2"), "Blocked post #3 leaked in multi-page podcast source")
    }

    func testBlockedPostAndBlockedUserAreExcludedFromVoiceAndTranslation() async throws {
        ModerationURLStub.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/t/1.json") {
                body = #"""
                {
                  "title": "Voice Topic",
                  "slug": "voice-topic",
                  "posts_count": 4,
                  "highest_post_number": 4,
                  "accepted_answer": {"post_number": 3, "username": "carol"},
                  "post_stream": {
                    "stream": [10, 11, 12, 13],
                    "posts": [
                      {"id": 10, "post_number": 1, "username": "alice", "cooked": "<p>Opening post</p>", "actions_summary": []},
                      {"id": 11, "post_number": 2, "username": "bob", "cooked": "<p>Bob post</p>", "actions_summary": [{"id": 2, "count": 20}]},
                      {"id": 12, "post_number": 3, "username": "carol", "cooked": "<p>Carol post</p>", "actions_summary": [{"id": 2, "count": 15}]},
                      {"id": 13, "post_number": 4, "username": "dave", "cooked": "<p>Dave post</p>", "actions_summary": [{"id": 2, "count": 5}]}
                    ]
                  }
                }
                """#
            } else if path.hasSuffix("/posts.json") {
                let ids = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.filter { $0.name == "post_ids[]" }.compactMap { $0.value } ?? []
                if ids == ["13"] {
                    body = #"{"post_stream":{"posts":[{"id":13,"post_number":4,"username":"dave","cooked":"<p>Dave clean reply</p>"}]}}"#
                } else {
                    body = #"{"post_stream":{"posts":[{"id":10,"post_number":1,"username":"alice","cooked":"<p>Opening post</p>"}]}}"#
                }
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ModerationURLStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        try store.save(AppSnapshot(forums: [Forum(siteURL: site, kind: .discourse, name: "Example")]))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let app = AppModel(store: store, forumService: forumService)
        app.usesDirectForumRequests = true
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil
        let url = URL(string: "\(site)/t/voice-topic/1")!
        let topic = ForumTopic(siteURL: site, topicID: "1", url: url, title: "Voice Topic")
        let page = PageContext(url: url, site: .discourse, siteURL: site, forumName: "Example", topic: topic, state: .topic)
        app.browser.setPageContext(page)
        handler?(page)

        app.block("bob", on: site)
        app.blockPost(3, topicID: "1", on: site)

        // 1. Voice brief excludes blocked user bob (#2) and blocked post #3 from solution and topPosts.
        let rawBrief = await app.voiceTopicBrief()
        let brief = try XCTUnwrap(rawBrief)
        XCTAssertNil(brief.solution, "Blocked post #3 must not appear as VoiceTopicBrief.solution")
        XCTAssertEqual(brief.topPosts.map(\.number), [4], "Blocked user bob (#2) and blocked post #3 must not appear in VoiceTopicBrief.topPosts")

        // 2. Voice postsOnScreen and Translation postsToTranslate exclude blocked user and blocked post.
        app.browser.visiblePostsOverride = [
            VisiblePost(number: 1, username: "alice", excerpt: "Opening post"),
            VisiblePost(number: 2, username: "bob", excerpt: "Bob spam"),
            VisiblePost(number: 3, username: "carol", excerpt: "Carol blocked post"),
            VisiblePost(number: 4, username: "dave", excerpt: "Dave clean reply")
        ]

        let visible = await app.postsOnScreen()
        XCTAssertEqual(visible.map(\.number), [1, 4], "postsOnScreen must exclude blocked user (#2) and blocked post (#3)")

        let toTranslate = await app.postsToTranslate()
        XCTAssertEqual(toTranslate.map(\.number), [1, 4], "postsToTranslate must exclude blocked user (#2) and blocked post (#3)")
    }

    func testWordPressBlockedCommentAndBlockedArticleExcludedFromSearchTools() async throws {
        let wpSite = "https://wp.example.com"
        ModerationURLStub.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/wp-json/wp/v2/comments") {
                body = #"[{"id":102,"post":42,"parent":0,"author_name":"bob","date_gmt":"2026-10-20T12:05:00","content":{"rendered":"<p>WP_BLOCKED_COMMENT_SECRET</p>"}}]"#
            } else if path.hasSuffix("/wp-json/wp/v2/posts") {
                body = #"[{"id":42,"title":{"rendered":"WP_BLOCKED_ARTICLE_TITLE"},"link":"https://wp.example.com/?p=42","date_gmt":"2026-10-20T12:00:00","excerpt":{"rendered":"<p>WP_BLOCKED_ARTICLE_EXCERPT</p>"}}]"#
            } else {
                body = "[]"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ModerationURLStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "search_comments", arguments: ["query": "secret"]),
            AgentAction(thought: "", tool: "search_forum", arguments: ["query": "article"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done."])
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var seeded = AppSnapshot()
        seeded.ensureForum(wpSite, kind: .wordpress)
        try store.save(seeded)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(store: store, forumService: forumService, aiService: ai, planner: planner)
        app.usesDirectForumRequests = true
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama-local"), for: .both)
        app.browser.onPageContextChanged = nil

        app.blockPost(2, topicID: "42", on: wpSite)
        app.blockPost(1, topicID: "42", on: wpSite)
        app.block("mallory", on: wpSite)

        _ = try await app.performAgentRun(goal: "Find secrets", siteURL: wpSite)
        let transcript = planner.transcripts.flatMap { $0 }.map(\.content).joined(separator: "\n")

        XCTAssertFalse(transcript.contains("WP_BLOCKED_COMMENT_SECRET"))
        XCTAssertFalse(transcript.contains("WP_BLOCKED_ARTICLE_EXCERPT"))
        XCTAssertFalse(transcript.contains("WP_BLOCKED_ARTICLE_TITLE"))
    }

    func testBlockedFirstNewPostAndBlockedUserAcceptedPostExcludedFromDigestAndPodcast() async throws {
        ModerationURLStub.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/t/50.json") {
                body = #"{"title":"Topic 50","slug":"topic-50","posts_count":3,"accepted_answer":{"post_number":3,"username":"mallory"},"post_stream":{"posts":[{"id":1,"post_number":1,"username":"alice","like_count":0},{"id":2,"post_number":2,"username":"bob","like_count":0},{"id":3,"post_number":3,"username":"mallory","like_count":25}]}}"#
            } else if path.hasSuffix("/raw/50") {
                body = "alice | 2026-10-20 12:00:00 UTC | #1\nPost 1\n\n\nbob | 2026-10-20 12:05:00 UTC | #2\nBlocked post 2\n\n\nmallory | 2026-10-20 12:10:00 UTC | #3\nBlocked user post 3\n"
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": path.hasSuffix(".json") ? "application/json" : "text/plain"]
            )!
            return (response, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ModerationURLStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let watched = WatchedTopic(siteURL: site, topicID: "50", url: URL(string: "\(site)/t/topic-50/50")!, title: "Topic 50", knownPostCount: 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var seeded = AppSnapshot(watchedTopics: [watched])
        seeded.ensureForum(site)
        try store.save(seeded)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(store: store, forumService: forumService, aiService: ai)
        app.usesDirectForumRequests = true
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama-local"), for: .both)
        app.browser.onPageContextChanged = nil

        var prefetch = DigestPrefetch(day: DailyDigest.dayKey(for: Date()))
        let refKey = TopicIdentity.key(siteURL: site, topicID: "50")
        prefetch.topics[refKey] = DigestTopicFacts(title: "Topic 50", slug: "topic-50", postCount: 3, acceptedAnswerPost: 3, topPost: 3)
        app.digestPrefetch = prefetch

        app.blockPost(2, topicID: "50", on: site)
        app.block("mallory", on: site)

        app.makeTodaysDigest()
        let deadline = Date().addingTimeInterval(5)
        while app.todaysDigest?.isComplete != true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let card = try XCTUnwrap(app.todaysDigest?.cards.first)
        let digestInstructions = try XCTUnwrap(ai.calls.last(where: { $0.kind == "summary" })?.customPrompt)
        let podcastPrompt = PodcastPrompt.content(
            for: PodcastPrompt.Chapter(card: card, forumName: "Stub", index: 1, count: 1, previousTitle: nil, topicText: "")
        )

        XCTAssertNotEqual(card.firstNewPost, 2)
        XCTAssertNil(card.acceptedAnswerPost)
        XCTAssertNil(card.topPost)
        XCTAssertFalse(digestInstructions.contains("#2"))
        XCTAssertFalse(podcastPrompt.contains("post #3") || podcastPrompt.contains("post #2"))
    }

    func testPostSummaryBlockExcludesPreBlockSummaryFromDownstreamAIContext() async throws {
        StateForumStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StateForumStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "saved_summaries", arguments: ["query": "Topic"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done."])
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var seeded = AppSnapshot()
        seeded.ensureForum(site)
        // Seeded, not `app.watch`: that asks for notification permission, and
        // on a fresh simulator nothing answers the dialog.
        seeded.watchedTopics = [WatchedTopic(
            siteURL: site,
            topicID: "1",
            url: URL(string: "\(site)/t/topic-1/1")!,
            title: "Topic 1",
            knownPostCount: 1
        )]
        try store.save(seeded)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let ai = StateAIStub()
        ai.gated = false
        ai.echoContentInSummary = true
        let app = AppModel(store: store, forumService: forumService, aiService: ai, planner: planner)
        app.usesDirectForumRequests = true
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama-local"), for: .both)
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil

        let t1 = ForumTopic(siteURL: site, topicID: "1", url: URL(string: "\(site)/t/topic-1/1")!, title: "Topic 1")
        let page = PageContext(url: t1.url, site: .discourse, siteURL: site, forumName: "Stub", topic: t1, state: .topic)
        app.browser.setPageContext(page)
        handler?(page)

        // Summarize Topic 1 before blocking Post #2 ("Post 2" by bob).
        XCTAssertTrue(app.enqueueSummary(for: t1))
        let deadline1 = Date().addingTimeInterval(5)
        while !app.activities.allSatisfy(\.status.isTerminal), Date() < deadline1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let initialSummary = try XCTUnwrap(app.sessions[t1.topicKey]?.summary)
        XCTAssertTrue(initialSummary.contains("Post 2"))

        // Block Post #2 on the topic's site:
        app.blockPost(2, topicID: "1", on: site)
        XCTAssertEqual(app.sessions[t1.topicKey]?.summary, initialSummary, "Summary is not deleted on block")

        // 1. Chat does not send the pre-block summary as context.
        app.drafts.chat = "What did people say?"
        app.sendChat()
        let deadline2 = Date().addingTimeInterval(5)
        while !app.activities.allSatisfy(\.status.isTerminal), Date() < deadline2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let chatSummarySent = try XCTUnwrap(ai.calls.last(where: { $0.kind == "chat" })?.summary)

        // 2. Voice brief does not include the pre-block summary.
        let voiceBrief = await app.voiceTopicBrief()?.summary ?? ""

        // 3. Agent saved_summaries does not send the pre-block summary to the planner.
        _ = try await app.performAgentRun(goal: "Check saved summaries", siteURL: site)
        let agentObservation = planner.transcripts.flatMap { $0 }.map(\.content).joined(separator: "\n")

        // 4. Daily Digest does not condense the pre-block summary.
        StateForumStub.postCounts["1"] = 2
        app.makeTodaysDigest()
        let deadline3 = Date().addingTimeInterval(5)
        while app.todaysDigest?.isComplete != true, Date() < deadline3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let digestSummaryInput = ai.calls.last(where: { $0.kind == "summary" })?.content ?? ""

        // 5. Re-running Summarize (without regenerate) does not short-circuit on the pre-block summary.
        let summaryCallsBefore = ai.calls.filter { $0.kind == "summary" }.count
        XCTAssertTrue(app.enqueueSummary(for: t1))
        let deadline4 = Date().addingTimeInterval(5)
        while !app.activities.allSatisfy(\.status.isTerminal), Date() < deadline4 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let summaryCallsAfter = ai.calls.filter { $0.kind == "summary" }.count

        XCTAssertFalse(chatSummarySent.contains("Post 2"))
        XCTAssertFalse(voiceBrief.contains("Post 2"))
        XCTAssertFalse(agentObservation.contains("Post 2"))
        XCTAssertFalse(digestSummaryInput.contains("Post 2"))
        XCTAssertGreaterThan(summaryCallsAfter, summaryCallsBefore)
    }

    func testBlockedCitationAndFocusBlockedUserAreIgnored() async throws {
        StateForumStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StateForumStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var seeded = AppSnapshot()
        seeded.ensureForum(site)
        try store.save(seeded)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let app = AppModel(store: store, forumService: forumService)
        app.usesDirectForumRequests = true
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil
        let t1 = ForumTopic(siteURL: site, topicID: "1", url: URL(string: "\(site)/t/topic-1/1")!, title: "Topic 1")
        let page = PageContext(url: t1.url, site: .discourse, siteURL: site, forumName: "Stub", topic: t1, state: .topic)
        app.browser.setPageContext(page)
        handler?(page)

        app.blockPost(2, topicID: "1", on: site)
        app.block("mallory", on: site)

        // 1. DrawerSummarySections does not link blocked post #2 while still linking post #1.
        let linked = DrawerSummarySections.link("See #1 and #2.", maximum: 5, hidden: app.currentHiddenPosts)
        XCTAssertTrue(linked.contains("[#1](forumind-post:1)"))
        XCTAssertFalse(linked.contains("forumind-post:2"))

        // 2. jumpToCitation(2) does not lower the drawer from .large to .medium or set citationJump.
        app.router.splitLayout = false
        app.router.openDrawer(at: .large)
        app.router.presentDrawer()
        app.router.drawerAppeared()
        XCTAssertEqual(app.router.drawerDetent, .large)
        app.jumpToCitation(2)
        XCTAssertEqual(app.router.drawerDetent, .large)
        XCTAssertNil(app.citationJump)

        // 3. focus(.user("mallory")) returns .hidden without loading ?username_filters=mallory in the browser.
        let focusResult = await app.focus(.user("mallory"))
        XCTAssertEqual(focusResult.status, .hidden)
        XCTAssertFalse(app.browser.currentURL?.absoluteString.contains("username_filters=mallory") == true)
    }

    private func makeApp(sessions: [TopicSession] = []) -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moderation-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PersistentStore(
            fileURL: directory.appendingPathComponent("state.json"),
            keys: InMemoryProviderKeyStore()
        )
        try? store.save(AppSnapshot(sessions: sessions))
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return app
    }
}

private final class ModerationURLStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
