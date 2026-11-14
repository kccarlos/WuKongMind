import XCTest
@testable import WukongMind

/// The voice tools on the navigation layer: arguments mapped to the
/// navigator, results turned into function responses with a `message`,
/// routing in code, the silent context's notes, the instructions and the
/// settings.
@MainActor
final class VoiceToolTests: XCTestCase {
    // MARK: Mapping

    func testToolCallsMapToTheNavigationLayer() async {
        let navigator = FakeVoiceNavigator()
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 3)
        navigator.browseCursor.replace(with: [
            BrowseItem(kind: .searchHit, siteURL: "https://forum.example", topicID: "7", postNumber: 2, title: "A"),
            BrowseItem(kind: .searchHit, siteURL: "https://forum.example", topicID: "8", postNumber: 5, title: "B")
        ], origin: .search("fan"))
        let bridge = VoiceToolBridge(navigator: navigator)
        let cases: [(String, [String: JSONValue], String)] = [
            ("search_forum", ["query": "fan noise"], "find fan noise forum"),
            ("search_forum", ["query": "firmware", "scope": "topic"], "find firmware topic"),
            ("browse_open", ["card": 2], "card 1"),
            ("browse_open", ["card": "2", "at": "solution"], "open item 8/5 at solution"),
            ("browse_open", ["topic_id": "123", "at": "post", "post": 37], "open topic 123 at post(37)"),
            ("browse_open", ["at": "solution"], "open topic 42 at solution"),
            ("browse_open", ["at": "last"], "open topic 42 at last"),
            ("browse_open", ["at": "unread"], "open topic 42 at firstNew"),
            ("browse_move", ["action": "next"], "next"),
            ("browse_move", ["action": "previous"], "previous"),
            ("browse_move", ["action": "back"], "back"),
            ("browse_move", ["action": "forward"], "forward"),
            ("browse_move", ["action": "post", "post": "37"], "post 37"),
            ("browse_move", ["action": "top"], "post 1"),
            ("browse_move", ["action": "bottom"], "open topic 42 at last"),
            ("browse_focus", ["mode": "user", "user": "@alice"], "focus user(\"alice\")"),
            ("browse_focus", ["mode": "op"], "focus op"),
            ("browse_focus", ["mode": "top"], "focus top"),
            ("browse_focus", ["mode": "posts", "posts": [3, 7]], "focus posts([3, 7])"),
            ("browse_focus", ["mode": "clear"], "focus clear"),
            ("read_post", [:], "read current"),
            ("read_post", ["post": 9], "read 9"),
            ("read_post", ["scope": "visible"], "visible")
        ]
        for (name, args, expected) in cases {
            _ = await bridge.handle(.init(id: "c", name: name, args: args), eyesFree: false)
            XCTAssertEqual(navigator.calls.last, expected, "\(name) \(args)")
        }
        let end = await bridge.handle(.init(id: "e", name: "end", args: [:]), eyesFree: false)
        XCTAssertEqual(end.effect, .end)
        XCTAssertEqual(end.scheduling, .silent)
        let unknown = await bridge.handle(.init(id: "u", name: "reply", args: [:]), eyesFree: false)
        XCTAssertEqual(unknown.response["status"], "unavailable")
        // An ordinary page has no browse tools.
        navigator.pageContext = .empty
        let offForum = await bridge.handle(.init(id: "m", name: "browse_move", args: ["action": "next"]), eyesFree: false)
        XCTAssertEqual(offForum.response["shown"], "browse_move isn't available on this page.")
    }

    func testResultsBecomeFunctionResponsesThatSayWhatToSay() {
        let opened = BrowseResult(status: .opened, shown: "Post 37 of 120 by alice (accepted answer)", content: "alice, post 37:\nUse the quiet profile.")
        let response = VoiceToolBridge.response(opened, eyesFree: false)
        XCTAssertEqual(response["status"], "opened")
        XCTAssertEqual(response["shown"], "Post 37 of 120 by alice (accepted answer)")
        XCTAssertEqual(response["content"], "alice, post 37:\nUse the quiet profile.")
        XCTAssertTrue(response["message"]?.stringValue?.contains("don't read it out") ?? false)
        // Eyes-free: reading is allowed.
        let eyesFree = VoiceToolBridge.response(opened, eyesFree: true)
        XCTAssertTrue(eyesFree["message"]?.stringValue?.contains("read or paraphrase") ?? false)

        let found = BrowseResult(status: .found, shown: "2 results", hits: [
            .init(number: 1, title: "Fan noise", topicID: "42", postNumber: 3, username: "bob", excerpt: "Try it")
        ])
        let hits = VoiceToolBridge.response(found, eyesFree: false)
        XCTAssertEqual(hits["hits"], [["card": 1, "title": "Fan noise", "excerpt": "Try it", "post": 3, "author": "bob", "topic_id": "42"]])
        XCTAssertTrue(hits["message"]?.stringValue?.contains("call browse_open with its card number now") ?? false)
        XCTAssertNil(hits["content"])

        for status: BrowseResult.Status in [.notFound, .unavailable, .failed, .emptyList] {
            let message = VoiceToolBridge.message(for: BrowseResult(status: status, shown: "x"), eyesFree: false)
            XCTAssertTrue(message.contains("Tell the user that instead") && message.contains("don't retry"), "\(status)")
        }
        XCTAssertTrue(VoiceToolBridge.message(for: .init(status: .noSolution, shown: ""), eyesFree: false).contains("no accepted answer"))
    }

    // MARK: Routing in code

    func testRoutingCatchesBrowserActionsSentToTheHandOff() async {
        XCTAssertEqual(VoiceRouting.browserAction(for: "Next"), .move("next"))
        XCTAssertEqual(VoiceRouting.browserAction(for: "go back."), .move("back"))
        XCTAssertEqual(VoiceRouting.browserAction(for: "post 37"), .post(37))
        XCTAssertEqual(VoiceRouting.browserAction(for: "#12"), .post(12))
        XCTAssertEqual(VoiceRouting.browserAction(for: "第37楼"), .post(37))
        XCTAssertEqual(VoiceRouting.browserAction(for: "下一个"), .move("next"))
        XCTAssertEqual(VoiceRouting.browserAction(for: "take me to the accepted answer"), .solution)
        XCTAssertNil(VoiceRouting.browserAction(for: "what did people say about post 37 and the firmware"))
        XCTAssertNil(VoiceRouting.browserAction(for: "what are the main objections"))

        let navigator = FakeVoiceNavigator()
        navigator.pageContext = FakeVoiceNavigator.topicPage(post: 3)
        let bridge = VoiceToolBridge(navigator: navigator)
        let outcome = await bridge.handle(.init(id: "r", name: "hand_off_to_agent", args: ["request": "post 37"]), eyesFree: false)
        XCTAssertEqual(navigator.calls, ["post 37"], "Done directly; no hand-off started")
        XCTAssertEqual(outcome.scheduling, .whenIdle)
        XCTAssertEqual(outcome.effect, .none)
        XCTAssertNotNil(outcome.response["routed"])
        XCTAssertEqual(outcome.response["status"], "opened")
    }

    // MARK: Context notes

    func testTopicBriefAndPositionDeltas() throws {
        var context = VoiceContext()
        let brief = VoiceTopicBrief(
            topicKey: "forum.example/42",
            title: "Lüfter zu laut nach dem Update",
            forumName: "Prusa Forum",
            opening: "Seit dem letzten Update ist der Lüfter meines Druckers sehr laut geworden. Hat jemand eine Lösung dafür gefunden?",
            openingPoster: "alice",
            postCount: 120,
            solution: nil,
            topPosts: [.init(number: 8, username: "bob", likes: 14)]
        )
        let note = try XCTUnwrap(context.topicBriefNote(brief))
        XCTAssertTrue(note.contains("The forum writes in German; search it in German."), note)
        XCTAssertTrue(note.contains("It has 120 posts."), note)
        XCTAssertTrue(note.contains("The opening post by alice asks: Seit dem"), note)
        XCTAssertTrue(note.contains("No accepted answer."), note)
        XCTAssertTrue(note.contains("Most liked: post 8 by bob (14 likes)."), note)
        XCTAssertNil(context.topicBriefNote(brief), "Sent once per topic")
        XCTAssertNotNil(context.summaryNote("Short summary.", topicKey: "forum.example/42", title: brief.title))
        XCTAssertNil(context.summaryNote("Again.", topicKey: "forum.example/42", title: brief.title))

        var page = FakeVoiceNavigator.topicPage(post: 3, visible: [3, 4])
        page.acceptedAnswerPost = 4
        let visible = [
            VisiblePost(number: 3, username: "bob", excerpt: "Try the quiet profile in the settings menu. It halves the noise for me."),
            VisiblePost(number: 4, username: "carol", excerpt: "Same here.")
        ]
        var cursor = BrowseCursor()
        let first = try XCTUnwrap(context.positionNote(page: page, visible: visible, cursor: cursor))
        XCTAssertTrue(first.hasPrefix("[Screen: At Post 3 of 9 by bob."), first)
        XCTAssertTrue(first.contains("#3 bob: Try the quiet profile in the settings menu."), first)
        XCTAssertFalse(first.contains("It halves"), "One sentence per post")
        XCTAssertNil(context.positionNote(page: page, visible: visible, cursor: cursor), "Nothing changed")

        cursor.replace(with: [BrowseItem(kind: .searchHit, siteURL: "s", topicID: "1", postNumber: 1, title: "t")], origin: .search("fan"))
        _ = cursor.next()
        let list = try XCTUnwrap(context.positionNote(page: page, visible: visible, cursor: cursor))
        XCTAssertEqual(list, "[Screen: Current list: 1 search results for “fan”, at 1 of 1.]", "Only the change")

        // After a reconnect: the whole context again.
        let full = context.fullContextNotes()
        XCTAssertEqual(full.count, 3)
        XCTAssertTrue(full[0].contains("opened the topic"))
        XCTAssertTrue(full[1].hasPrefix("[WukongMind: AI summary"))
        XCTAssertTrue(full[2].contains("At Post 3 of 9 by bob.") && full[2].contains("Current list"), full[2])
    }

    func testFocusedPostIsCappedAtAbout800Tokens() throws {
        var context = VoiceContext()
        let long = String(repeating: "The fan curve matters a lot here. ", count: 300)
        let result = BrowseResult(status: .read, shown: "Post 5 of 9 by bob", content: long)
        let note = try XCTUnwrap(context.fullTextNote(result, topicKey: "k", number: 5))
        XCTAssertLessThan(note.count, BrowseText.contentLimit + 200)
        XCTAssertTrue(context.hasFullText(topicKey: "k", number: 5))
        XCTAssertNil(context.fullTextNote(BrowseResult(status: .notFound, shown: "x"), topicKey: "k", number: 6))
    }

    // MARK: Instructions

    func testInstructionsHaveEveryPartAndTheAnswerLength() {
        let site = DiscourseAdapter().voice
        let text = VoiceInstructions.system(answerLength: .short, eyesFree: false, forumName: "Prusa Forum", site: site)
        for part in [
            VoiceInstructions.persona(site), VoiceInstructions.speech, VoiceInstructions.screen, VoiceInstructions.precedence,
            VoiceInstructions.opinionRule, VoiceInstructions.handOff, VoiceInstructions.grounding, VoiceInstructions.notes, VoiceInstructions.language(site),
            VoiceInstructions.eyesFreeOff
        ] {
            XCTAssertTrue(text.contains(part))
        }
        XCTAssertFalse(text.contains(VoiceInstructions.eyesFreeOn))
        XCTAssertTrue(text.hasSuffix("The user is on the forum Prusa Forum."))
        XCTAssertTrue(VoiceInstructions.system(answerLength: .normal, eyesFree: true, forumName: nil, site: site).contains(VoiceInstructions.eyesFreeOn))
        // Short still asks for a real answer, not one line.
        XCTAssertTrue(VoiceInstructions.answerLength(.short).contains("still an answer, not a teaser"))
        XCTAssertNotEqual(VoiceInstructions.answerLength(.normal), VoiceInstructions.answerLength(.detailed))
        XCTAssertFalse(text.contains("**"), "No Markdown in the instructions")
        // The spike's routing sentence (Q3), word for word.
        XCTAssertTrue(text.contains("Questions about what people think or recommend, or anything that needs reading several threads, go to hand_off_to_agent even when they name a topic: search_forum only shows cards and can't answer them. Use search_forum when the user asks to find, search or look for something."))
        XCTAssertFalse(text.contains("research"), "the hand-off replaced research")
    }

    // MARK: Site profile (S14)

    /// A site that cannot narrow to an author: the declarations drop `user`
    /// and `op` (and the `user` argument and the sentences naming them).
    func testASiteWithoutTopicFiltersDropsTheAuthorModes() throws {
        func focus(_ site: VoiceSite) throws -> AgentToolDefinition {
            let registry = ToolRegistry(tools: ToolRegistry.browseTools(browse: BrowseToolContext(navigator: nil, site: site, isOnForum: true)))
            return try XCTUnwrap(registry.tool(named: "browse_focus")?.definition)
        }
        let discourse = try focus(VoiceSite(adapter: DiscourseAdapter()))
        let fakeSite = VoiceSite(adapter: FakeSiteAdapter())
        let fake = try focus(fakeSite)
        XCTAssertEqual(discourse.parameters.first?.enumValues, ["user", "op", "top", "posts", "clear"])
        XCTAssertEqual(fake.parameters.first?.enumValues, ["top", "posts", "clear"])
        XCTAssertEqual(fake.parameters.map(\.name), ["mode", "posts"])
        XCTAssertFalse(fake.description.contains("\"user\""))
        XCTAssertFalse(fake.description.contains("\"op\""))
        XCTAssertTrue(fake.description.contains("\"top\" the most liked posts"))
        XCTAssertFalse(fake.description.contains("\n"))

        // The declarations and the instructions carry the site's own words.
        let declared = VoiceDeclarations.all(registry: ToolRegistry(tools: ToolRegistry.browseTools(
            browse: BrowseToolContext(navigator: nil, site: fakeSite, isOnForum: true)
        )))
        XCTAssertTrue(declared.first { $0.name == "search_forum" }?.description.contains("Fake search matches whole sentences.") == true)
        let text = VoiceInstructions.system(answerLength: .normal, eyesFree: false, forumName: nil, site: fakeSite.profile)
        XCTAssertTrue(text.contains("a reading companion for fake sites"))
        XCTAssertFalse(text.contains("Discourse"))
    }

    /// The registry resolves the page's site, else the fallback: a session can start from Home.
    func testTheSessionStartsOnTheSiteOfItsPageOrTheFallback() {
        let registry = SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter()])
        XCTAssertEqual(registry.voiceSite(for: FakeSiteAdapter.kind).profile, FakeSiteAdapter().voice)
        XCTAssertEqual(registry.voiceSite(for: .discourse).profile, DiscourseAdapter().voice)
        XCTAssertEqual(registry.voiceSite(for: nil), registry.voiceFallback)
        XCTAssertEqual(registry.voiceSite(for: SiteKind("ghost")), registry.voiceFallback)
        // The fallback's options are the union of all adapters'.
        XCTAssertTrue(registry.voiceFallback.offersAuthorFocus)
        XCTAssertFalse(SiteRegistry(adapters: [FakeSiteAdapter()]).voiceFallback.offersAuthorFocus)
    }

    /// A topic whose facts name no accepted answer opens at the top and says so.
    func testATopicWithoutAnAcceptedAnswerAnswersNoSolution() async throws {
        let site = "https://fake.example.com"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        try store.save(AppSnapshot(forums: [Forum(siteURL: site, kind: FakeSiteAdapter.kind, name: "Fake")]))
        let app = AppModel(store: store, forumService: ForumService(), sites: SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter()]))
        app.browser.onPageContextChanged = nil
        let topic = ForumTopic(siteURL: site, topicID: "42", url: URL(string: "\(site)/topic/42")!, title: "Topic 42")
        app.browser.setPageContext(PageContext(
            url: topic.url, site: FakeSiteAdapter.kind, siteURL: site, forumName: "Fake", topic: topic, state: .topic
        ))
        let outcome = await VoiceToolBridge(navigator: app).handle(.init(id: "o", name: "browse_open", args: ["at": "solution"]), eyesFree: false)
        XCTAssertEqual(outcome.response["status"], "noSolution")
        XCTAssertEqual(app.voiceSite.profile, FakeSiteAdapter().voice, "the page's site decides the session's words")
    }

    /// A session that starts where no site is known speaks as the neutral
    /// persona, whatever adapters are registered; the options are the union.
    func testTheFallbackIsNeutralWhateverAdaptersAreRegistered() {
        let twoAdapters = SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter()])
        XCTAssertEqual(twoAdapters.voiceFallback.profile, .neutral)
        XCTAssertTrue(twoAdapters.voiceFallback.offersAuthorFocus, "Discourse supports topic filters")
        XCTAssertEqual(twoAdapters.voiceSite(for: nil).profile, .neutral)
        XCTAssertEqual(twoAdapters.voiceSite(for: .discourse).profile, DiscourseAdapter().voice, "a known site keeps its own words")
        XCTAssertEqual(SiteRegistry(adapters: [DiscourseAdapter()]).voiceFallback.profile, .neutral)
        XCTAssertEqual(SiteRegistry(adapters: [FakeSiteAdapter()]).voiceFallback.profile, .neutral)
        let text = VoiceInstructions.system(answerLength: .normal, eyesFree: false, forumName: nil, site: twoAdapters.voiceFallback.profile)
        XCTAssertFalse(text.contains("Discourse"))
        XCTAssertTrue(text.contains(VoiceSiteProfile.neutral.persona))
    }

    /// The shipped registry never falls back to one platform's persona.
    func testTheStandardRegistryFallbackIsNeutral() {
        XCTAssertEqual(SiteRegistry.standard.voiceFallback.profile, .neutral)
    }

    // MARK: Settings and provider availability

    func testVoiceSettingsDecodeEachFieldOnItsOwnAndStayOnTheDevice() throws {
        let decoded = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"answerLength":"loud","idleTimeout":5,"voiceName":"Puck"}"#.utf8))
        XCTAssertEqual(decoded.answerLength, .normal, "An unknown value falls back")
        XCTAssertEqual(decoded.idleTimeout, 15, "Clamped")
        XCTAssertEqual(decoded.voiceName, "Puck")
        XCTAssertTrue(decoded.groundsOnScreenReference)
        XCTAssertEqual(decoded.provider, .aiStudio)

        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(old.voiceEnabled)
        XCTAssertEqual(old.voice, VoiceSettings())
        XCTAssertTrue(SyncSettings.deviceLocalKeys.contains("voiceEnabled"))
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("voice"), "Preferences sync")
        XCTAssertTrue(VoiceEyesFree.auto.isActive(headphones: true))
        XCTAssertFalse(VoiceEyesFree.auto.isActive(headphones: false))
        XCTAssertFalse(VoiceEyesFree.off.isActive(headphones: true))
    }

    func testProviderAvailabilityAndEndpointResolution() throws {
        let app = makeApp()
        XCTAssertEqual(app.voiceConfiguration().failureValue, .disabled)
        app.settings.voiceEnabled = true
        XCTAssertEqual(app.voiceConfiguration().failureValue, .noKey)
        var gemini = app.settings.configuration(for: .gemini)
        gemini.apiKey = "test-key"
        app.settings.setConfiguration(gemini, for: .gemini)
        XCTAssertEqual(app.availableVoiceProviders, [.aiStudio])
        let configuration = try app.voiceConfiguration().get()
        XCTAssertEqual(configuration.endpoint, .aiStudio)
        // Vertex is chosen but has no key: AI Studio is used.
        app.settings.voice.provider = .vertex
        XCTAssertEqual(try app.voiceConfiguration().get().endpoint, .aiStudio)

        var vertex = app.settings.configuration(for: .vertexAI)
        vertex.apiKey = "vertex-key"
        app.settings.setConfiguration(vertex, for: .vertexAI)
        XCTAssertEqual(app.voiceConfiguration().failureValue, .noVertexProject, "Express mode has no project")
        app.settings.voice.vertexProject = "my-project"
        XCTAssertEqual(try app.voiceConfiguration().get().endpoint, .vertex(project: "my-project", location: "us-central1"))
        vertex.baseURL = "https://aiplatform.googleapis.com/v1/projects/from-url/locations/global"
        app.settings.setConfiguration(vertex, for: .vertexAI)
        XCTAssertEqual(try app.voiceConfiguration().get().endpoint, .vertex(project: "from-url", location: "us-central1"))
    }

    // MARK: Through AppModel

    /// The real navigation layer under the bridge (find on a stubbed forum).
    func testFindThroughAppModel() async throws {
        PostLevelURLStub.handler = { request in
            PostLevelURLStub.requests.append(request.url!)
            return (200, DiscourseFixtures.search)
        }
        let app = makeApp()
        app.recordVisit(siteURL: "https://forum.example", kind: .discourse, name: "Example", iconURL: nil)
        Self.openForumHome(app)
        let bridge = VoiceToolBridge(navigator: app)
        bridge.registryBuilder = app.voiceToolRegistry
        let outcome = await bridge.handle(.init(id: "f", name: "search_forum", args: ["query": "badges"]), eyesFree: false)
        XCTAssertEqual(outcome.response["status"], "found")
        XCTAssertEqual(outcome.response["hits"]?.arrayValue?.count, 4)
        XCTAssertEqual(outcome.scheduling, .whenIdle)
        XCTAssertEqual(app.browseCursor.items.count, 4, "voice search fills the cards")

        let empty = await bridge.handle(.init(id: "n", name: "browse_move", args: ["action": "previous"]), eyesFree: false)
        XCTAssertEqual(empty.response["status"], "endOfList")
    }

    // MARK: One registry (design-one-loop.md "Voice")

    /// What a voice session on a forum page declares is exactly the
    /// registry's `.voice` tools plus `end` and `hand_off_to_agent`; the text
    /// Agent on the same page gets none of the browse tools.
    func testVoiceDeclarationsAreTheRegistrysVoiceToolsAndTheTextAgentHasNoBrowseTools() throws {
        let app = makeApp()
        app.recordVisit(siteURL: "https://forum.example", kind: .discourse, name: "Example", iconURL: nil)
        Self.openForumHome(app)
        let bridge = VoiceToolBridge(navigator: app)
        bridge.registryBuilder = app.voiceToolRegistry
        let declared = bridge.declare(for: app.voiceSite).map(\.name)
        let voice = app.voiceToolRegistry(browse: BrowseToolContext(navigator: app, site: app.voiceSite))
        XCTAssertEqual(declared, voice.definitions.map(\.name) + ["end", "hand_off_to_agent"])
        XCTAssertEqual(Set(voice.definitions.map(\.name)), [
            "read_page", "search_forum", "read_topic", "summarize_topic", "read_aloud", "watch_topic",
            "browse_open", "browse_move", "browse_focus", "read_post"
        ], "12 with end and the hand-off; heavy tools, notify and inject_css stay text-only")
        XCTAssertNil(voice.tool(named: "read_page")?.definition.parameters.first { $0.name == "mode" }, "structure only")

        let context = AgentToolContext(
            bridge: app.browser.agentBridge, workspace: app.agentWorkspace, scriptStore: app.scriptStore,
            forum: app.makeForumToolContext(), capabilities: app.capabilityToolContext,
            browse: BrowseToolContext(navigator: app, site: app.voiceSite, isOnForum: true)
        )
        let text = Set(ToolRegistry.m3(context: context).definitions.map(\.name))
        XCTAssertTrue(text.isDisjoint(with: ["browse_open", "browse_move", "browse_focus", "read_post"]), "\(text)")
        XCTAssertTrue(text.isSuperset(of: ["search_forum", "read_topic", "read_page", "inject_css", "notify"]))
        XCTAssertNotNil(ToolRegistry.m3(context: context).tool(named: "read_page")?.definition.parameters.first { $0.name == "mode" })

        // An ordinary page: no forum or browse tools for voice.
        app.browser.setPageContext(PageContext(url: URL(string: "https://news.example.org/story")!, state: .notForum))
        let ordinary = Set(app.voiceToolRegistry(browse: BrowseToolContext(navigator: app, site: app.voiceSite)).definitions.map(\.name))
        XCTAssertEqual(ordinary, ["read_page", "summarize_topic", "read_aloud", "watch_topic"])
    }

    /// Every voice result is capped at 8,000 characters (spike Q6).
    func testSpokenResultsAreCappedAndNumbersAsTextAreTaken() {
        let long = ToolDispatchResult(
            toolName: "read_topic", argumentSummary: "", argumentsJSON: "{}", output: String(repeating: "word ", count: 6_000),
            resultSummary: "", modelContent: "", isError: false, wasTruncated: false, totalCharacterCount: 30_000, duration: 0
        )
        let facts = ToolRegistry().spokenResult(long, eyesFree: false)
        XCTAssertLessThanOrEqual(JSONValue.encodeCompactJSON(facts).count, ToolRegistry.spokenResultLimit)
        XCTAssertEqual(facts["status"], "done")
        XCTAssertTrue(facts["result"]?.stringValue?.hasSuffix("…[cut]") ?? false)
        XCTAssertNotNil(facts["message"])

        let definition = AgentToolDefinition(name: "t", description: "", parameters: [
            ToolParameterSchema(name: "card", type: .integer, description: ""),
            ToolParameterSchema(name: "posts", type: .array, description: "", itemsType: .integer)
        ])
        XCTAssertEqual(VoiceToolBridge.lenient(["card": "2", "posts": ["3", 7]], for: definition), ["card": 2, "posts": [3, 7]])
    }

    func testTheHandOffAnswerIsSpeakable() {
        XCTAssertEqual(
            VoiceText.spokenAnswer("## Short answer\n- **Most** regret it [#3](post:3) [Soldered eMMC](https://forum.example/t/9) https://x.example/a"),
            "Short answer\nMost regret it Soldered eMMC"
        )
    }

    private static func openForumHome(_ app: AppModel) {
        app.browser.onPageContextChanged = nil
        app.browser.setPageContext(PageContext(
            url: URL(string: "https://forum.example/")!, site: .discourse, siteURL: "https://forum.example",
            forumName: "Example", state: .forumHome
        ))
    }

    // MARK: Helpers

    private func makeApp() -> AppModel {
        PostLevelURLStub.requests = []
        PostLevelURLStub.cookies = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PostLevelURLStub.self]
        let session = URLSession(configuration: configuration)
        let app = AppModel(
            store: PersistentStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent("state.json")
            ),
            forumService: ForumService(session: session, pacer: ForumRequestPacer(clock: InstantPacingClock())),
            aiService: AIService(session: session)
        )
        app.usesDirectForumRequests = true
        return app
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
