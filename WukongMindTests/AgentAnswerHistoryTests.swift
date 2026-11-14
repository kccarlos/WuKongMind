import XCTest
@testable import WukongMind

/// One loop 12: the Agent's answers in History (design-one-loop.md "Agent
/// answers in History"): what is saved at the end of a turn, how the record
/// decodes, what reads it, and what ignores it.
@MainActor
final class AgentAnswerHistoryTests: XCTestCase {
    private let site = WordPressFixtureSite.siteURL
    private let article = "https://example.com/2026/05/sample-cards-and-notes/"
    private let listed = "https://example.com/2026/p1002/"
    private let ordinaryPage = "https://news.example.org/story/42"

    // MARK: Rigs

    private func makeApp() throws -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wukong-answers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = PersistentStore(fileURL: dir.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        try store.save(AppSnapshot(forums: [Forum(siteURL: site, kind: .wordpress, name: "Example Blog")]))
        return AppModel(
            store: store,
            forumService: WordPressFixtureSite(commentCount: 1).service(), sites: SiteRegistry.standard, aiService: StateAIStub(),
            workspaceDirectory: dir.appendingPathComponent("ws", isDirectory: true)
        )
    }

    private var forumShapes: [ForumShape] {
        [
            .list(ListShape(items: [.init(id: "1002", title: "Hotel Points Guide", url: listed)])),
            .thread(ThreadShape(id: "1001", title: "Sample", url: article, posts: []))
        ]
    }

    private func answer(
        _ text: String, question: String = "Which cards are worth it?", shapes: [ForumShape] = [],
        page: String? = nil, origin: AgentRunOrigin = .typed
    ) -> BrowserAgentAnswer {
        BrowserAgentAnswer(
            question: question, text: text, shapes: shapes, provider: .ollama, model: "m",
            origin: origin, pageURL: page ?? ordinaryPage, startedAt: Date()
        )
    }

    private var longText: String { String(repeating: "A long answer sentence. ", count: 10) }

    // MARK: The turn ends

    private func session(client: RecordedModelClient, page: String) -> BrowserAgentSession {
        BrowserAgentSession(
            pageDriver: FixturePageDriver(page: .init(url: page, title: "Page")), modelClient: client,
            configProvider: {
                var cfg = ProviderConfiguration(provider: .ollama); cfg.model = "agent-model"
                return BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .ollama, model: "agent-model"), configuration: cfg,
                    maxSteps: 6, truncationLimit: 20_000, customInstructions: "", redactedSecrets: []
                )
            }
        )
    }

    func testACompletedTurnHandsOverTheQuestionAndAnswerWithoutAToolLog() async throws {
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "c1", name: "read_page", arguments: ["mode": .string("text")])])),
            .success(AgentModelTurnResponse(text: longText))
        ])
        let agent = session(client: client, page: ordinaryPage)
        var received: [BrowserAgentAnswer] = []
        agent.onAnswer = { received.append($0) }
        await agent.sendAndWait("What is on this page?")
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].question, "What is on this page?")
        XCTAssertEqual(received[0].text, longText.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(received[0].origin, .typed)
        XCTAssertEqual(received[0].pageURL, ordinaryPage)
    }

    func testAFailedStoppedOrEmptyTurnHandsOverNothing() async throws {
        struct Boom: Error {}
        let failing = session(client: RecordedModelClient([.failure(Boom())]), page: ordinaryPage)
        var received: [BrowserAgentAnswer] = []
        failing.onAnswer = { received.append($0) }
        await failing.sendAndWait("Fails")
        if case .failed = failing.runState {} else { XCTFail("expected a failed run") }

        let empty = session(client: RecordedModelClient([.success(AgentModelTurnResponse(text: "  \n "))]), page: ordinaryPage)
        empty.onAnswer = { received.append($0) }
        await empty.sendAndWait("Empty")

        let slow = RecordedModelClient([.success(AgentModelTurnResponse(text: self.longText))])
        slow.onRequest = { _ in try await Task.sleep(for: .seconds(30)) }
        let stopped = session(client: slow, page: ordinaryPage)
        stopped.onAnswer = { received.append($0) }
        stopped.send("Stopped")
        try await Task.sleep(for: .milliseconds(100))
        stopped.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(received.isEmpty)
    }

    func testAHandOffRunKeepsItsVoiceOrigin() async throws {
        let agent = session(client: RecordedModelClient([.success(AgentModelTurnResponse(text: longText))]), page: ordinaryPage)
        var received: [BrowserAgentAnswer] = []
        agent.onAnswer = { received.append($0) }
        await agent.sendAndWait("Spoken question", origin: .voice)
        XCTAssertEqual(received.first?.origin, .voice)

        let app = try makeApp()
        let saved = try XCTUnwrap(app.saveAgentAnswer(XCTUnwrap(received.first)))
        XCTAssertEqual(saved.origin, .voice)
    }

    func testAContinueAfterTheStepLimitSavesTheOriginalQuestion() async throws {
        let calls = (1...3).map { AgentModelToolCall(id: "c\($0)", name: "read_page", arguments: ["mode": .string("text")]) }
        var responses: [Result<AgentModelTurnResponse, Error>] = calls.map { .success(AgentModelTurnResponse(text: "", toolCalls: [$0])) }
        responses.append(.success(AgentModelTurnResponse(text: longText)))
        let agent = BrowserAgentSession(
            pageDriver: FixturePageDriver(page: .init(url: ordinaryPage, title: "Page")),
            modelClient: RecordedModelClient(responses),
            configProvider: {
                var cfg = ProviderConfiguration(provider: .ollama); cfg.model = "agent-model"
                return BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .ollama, model: "agent-model"), configuration: cfg,
                    maxSteps: 1, truncationLimit: 20_000, customInstructions: "", redactedSecrets: []
                )
            }
        )
        var received: [BrowserAgentAnswer] = []
        agent.onAnswer = { received.append($0) }
        await agent.sendAndWait("The original question")
        if case .stepLimitReached = agent.runState {
            await agent.continueAfterStepLimitAndWait()
        }
        XCTAssertEqual(received.map(\.question), ["The original question"])
    }

    // MARK: The save condition

    func testTheSaveConditionIsASourceOrTwoHundredCharacters() throws {
        let app = try makeApp()
        // One source and a short text: saved.
        let cited = "Yes: [Sample](\(article))."
        XCTAssertNotNil(app.saveAgentAnswer(answer(cited, shapes: forumShapes, page: site)))
        // No sources and 200 characters or more: saved.
        XCTAssertEqual(longText.count >= 200, true)
        XCTAssertNotNil(app.saveAgentAnswer(answer(longText)))
        // A page-change turn, no sources, a short answer: nothing.
        let before = app.agentRuns.count
        XCTAssertNil(app.saveAgentAnswer(answer("Done, the page is dark now.")))
        XCTAssertNil(app.saveAgentAnswer(answer(String(repeating: "x", count: 199))))
        XCTAssertNil(app.saveAgentAnswer(answer("   ")))
        XCTAssertEqual(app.agentRuns.count, before)
        // Gate 2: a forum turn that read a thread but cites it only as a plain URL has no source.
        XCTAssertNil(app.saveAgentAnswer(answer("Yes, see \(article)", shapes: forumShapes, page: site)))
        XCTAssertEqual(app.agentRuns.count, before)
        XCTAssertFalse(AppModel.shouldSaveAnswer(text: "short", sourceCount: 0))
        XCTAssertTrue(AppModel.shouldSaveAnswer(text: "short", sourceCount: 1))
    }

    func testAForumAnswerSavesOneRecordWithItsSourcesAndVisits() throws {
        let app = try makeApp()
        let text = "See [Hotel Points Guide](\(listed)#comment-6001) and [the article](\(article.dropLast()))."
        let run = try XCTUnwrap(app.saveAgentAnswer(answer(text, shapes: forumShapes, page: article)))
        XCTAssertEqual(app.agentRuns.count, 1)
        XCTAssertEqual(run.loop, .agent)
        XCTAssertEqual(run.result, .completed)
        XCTAssertEqual(run.goal, "Which cards are worth it?")
        XCTAssertEqual(run.answer, text)
        XCTAssertEqual(run.initialAnswer, text)
        XCTAssertEqual(run.siteURL, site)
        XCTAssertEqual(run.sources.map(\.number), [1, 2])
        XCTAssertEqual(run.sources.compactMap(\.topicID), ["1002", "1001"])
        XCTAssertEqual(run.topicIDs, ["1001"], "the visits are the thread reads; a list is a search result")
        XCTAssertFalse(run.knownLinks.isEmpty, "a slug permalink finds its topic again")
        XCTAssertTrue(run.steps.isEmpty && run.transcript.isEmpty && run.followUps.isEmpty)
        XCTAssertEqual(run.provider, .ollama)
        XCTAssertEqual(run.model, "m")
    }

    func testAnOrdinaryPageAnswerUsesThePagesOriginAndAddsNoForum() throws {
        let app = try makeApp()
        let run = try XCTUnwrap(app.saveAgentAnswer(answer(longText)))
        XCTAssertEqual(run.siteURL, "https://news.example.org")
        XCTAssertTrue(run.sources.isEmpty)
        XCTAssertFalse(app.isForumRecord(run))
        XCTAssertTrue(app.manageForums.isEmpty, "a page someone asked about is not a forum")
        // A forum answer's record does count.
        let forumRun = try XCTUnwrap(app.saveAgentAnswer(answer("Yes [Sample](\(article))", shapes: forumShapes, page: site)))
        XCTAssertTrue(app.isForumRecord(forumRun))
        XCTAssertEqual(app.manageForums.map(\.siteURL), [site])
    }

    // MARK: Decoding

    func testAnOldRecordWithoutTheNewFieldsDecodesAsResearch() throws {
        var old = AgentRun(siteURL: site, goal: "Old", provider: .ollama, model: "m")
        old.answer = "A"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "loop")
        object.removeValue(forKey: "sources")
        let decoded = try JSONDecoder().decode(AgentRun.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.loop, .research)
        XCTAssertEqual(decoded.sources, [])
        XCTAssertEqual(decoded.goal, "Old")
    }

    func testAStoreWithAndWithoutAgentRecordsDecodes() throws {
        var research = AgentRun(siteURL: site, goal: "Research", provider: .ollama, model: "m")
        research.result = .completed
        var agent = AgentRun(siteURL: "https://news.example.org", goal: "Agent", provider: .ollama, model: "m", origin: .voice)
        agent.loop = .agent
        agent.sources = [SavedSource(number: 1, title: "T", url: article, topicID: "1001", postNumber: 3, cited: false)]
        let snapshot = AppSnapshot(agentRuns: [research, agent])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: data)
        XCTAssertEqual(decoded.agentRuns, [research, agent])
        XCTAssertEqual(decoded.agentRuns[1].sources.first?.source?.postNumber, 3)

        // A store from before this task: runs with no new keys, and one with no runs.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var runs = try XCTUnwrap(legacy["agentRuns"] as? [[String: Any]])
        for index in runs.indices { runs[index].removeValue(forKey: "loop"); runs[index].removeValue(forKey: "sources") }
        legacy["agentRuns"] = runs
        let old = try JSONDecoder().decode(AppSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.agentRuns.map(\.loop), [.research, .research])
        legacy.removeValue(forKey: "agentRuns")
        XCTAssertEqual(try JSONDecoder().decode(AppSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy)).agentRuns, [])
    }

    // MARK: Cap, sync and retention

    func testTheSharedCapKeepsTheNewestFifty() throws {
        let app = try makeApp()
        for index in 0..<52 {
            XCTAssertNotNil(app.saveAgentAnswer(answer(longText, question: "Question \(index)")))
        }
        XCTAssertEqual(app.agentRuns.count, AppModel.agentRunLimit)
        XCTAssertEqual(app.agentRuns.first?.goal, "Question 51")
        XCTAssertFalse(app.agentRuns.contains { $0.goal == "Question 0" || $0.goal == "Question 1" })
    }

    func testRetentionKeepsTheTopicsAnAgentRecordCites() throws {
        let app = try makeApp()
        let run = try XCTUnwrap(app.saveAgentAnswer(answer("Yes [Sample](\(article))", shapes: forumShapes, page: site)))
        XCTAssertEqual(SessionRetention.topicKeys(citedBy: [run]), [TopicIdentity.key(siteURL: site, topicID: "1001")])
    }

    func testARecordSurvivesEncodingForSync() throws {
        let app = try makeApp()
        let run = try XCTUnwrap(app.saveAgentAnswer(answer("Yes [Sample](\(article))", shapes: forumShapes, page: site)))
        let units = try XCTUnwrap(SyncSchema.runUnits(run))
        let object = SyncSchema.object(kind: .run, units: units)
        let back = try SyncCoding.decode(AgentRun.self, from: .object(object))
        // Dates keep whole seconds in a synced record; everything else is exact.
        XCTAssertEqual(back.id, run.id)
        XCTAssertEqual(back.loop, .agent)
        XCTAssertEqual(back.goal, run.goal)
        XCTAssertEqual(back.answer, run.answer)
        XCTAssertEqual(back.sources, run.sources)
        XCTAssertEqual(back.topicIDs, run.topicIDs)
        XCTAssertEqual(back.knownLinks, run.knownLinks)
        XCTAssertEqual(back.origin, run.origin)
    }

    // MARK: The Research UI ignores them

    func testTheResearchRunListsAndFollowUpsReadOnlyResearchRecords() throws {
        let app = try makeApp()
        let saved = try XCTUnwrap(app.saveAgentAnswer(answer(longText)))
        XCTAssertTrue(app.researchRuns.isEmpty)
        XCTAssertNil(app.selectedAgentRun)
        XCTAssertTrue(app.asksNewForumQuestion)
        app.continueAgentRun(id: saved.id, question: "And then?")
        XCTAssertTrue(app.agentRuns.first { $0.id == saved.id }?.followUps.isEmpty ?? false)

        app.selectModel(ModelSelection(provider: .ollama, model: "test-model"), for: .both)
        app.startAgentRun(goal: "Research question", siteURL: site)
        XCTAssertEqual(app.researchRuns.map(\.goal), ["Research question"])
        XCTAssertEqual(app.selectedAgentRun?.goal, "Research question")
        XCTAssertEqual(app.agentRuns.count, 2)
    }

    func testSelectionSkipsAgentRecordsOnReloadAndAfterDeletingResearch() throws {
        var research = AgentRun(siteURL: site, goal: "Research", provider: .ollama, model: "m")
        research.result = .completed
        research.createdAt = Date(timeIntervalSince1970: 100)
        var agent = AgentRun(siteURL: "https://news.example.org", goal: "Agent", provider: .ollama, model: "m")
        agent.loop = .agent
        agent.result = .completed
        agent.createdAt = Date(timeIntervalSince1970: 200)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wukong-sel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = PersistentStore(fileURL: dir.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        try store.save(AppSnapshot(agentRuns: [research, agent]))
        let app = AppModel(
            store: store,
            forumService: WordPressFixtureSite(commentCount: 1).service(), sites: SiteRegistry.standard, aiService: StateAIStub(),
            workspaceDirectory: dir.appendingPathComponent("ws", isDirectory: true)
        )
        XCTAssertEqual(app.selectedAgentRunID, research.id)
        app.deleteAgentRun(id: research.id)
        XCTAssertNil(app.selectedAgentRunID)
        XCTAssertNil(app.selectedAgentRun)
    }

    // MARK: History and Home

    func testAgentRecordsShowInHistoryAndHomeRecentAndOpenInTheSavedAnswer() throws {
        let app = try makeApp()
        let forum = try XCTUnwrap(app.saveAgentAnswer(answer("Yes [Sample](\(article))", shapes: forumShapes, page: site)))
        let page = try XCTUnwrap(app.saveAgentAnswer(answer(longText, question: "Summarize the story")))

        let feed = HistoryFeed(forum: nil, activities: [], sessions: [], runs: app.agentRuns, watched: [])
        XCTAssertEqual(Set(feed.asks.map(\.id)), [forum.id, page.id])
        XCTAssertEqual(feed.count(.asks), 2)
        // A forum filter hides the ordinary-page record.
        let filtered = HistoryFeed(forum: site, activities: [], sessions: [], runs: app.agentRuns, watched: [])
        XCTAssertEqual(filtered.asks.map(\.id), [forum.id])

        let recent = HomeRecent.items(sessions: [], runs: app.agentRuns)
        XCTAssertEqual(recent.count, 2)
        XCTAssertTrue(recent.contains { $0.target == .askRun(forum.id) } && recent.contains { $0.target == .askRun(page.id) })
        XCTAssertTrue(recent.allSatisfy(\.isAgent))

        XCTAssertNil(app.savedAnswerRunID)
        app.openAgentRun(id: page.id)
        XCTAssertEqual(app.savedAnswerRunID, page.id)
        XCTAssertNil(app.selectedAgentRun, "Research's selection stays out of it")
    }

    func testTheSavedAnswerSubtitleIsAnswerAndTheDateWithoutReadOnly() {
        let date = Date(timeIntervalSince1970: 1_731_369_600) // 12 Nov 2024 UTC
        let subtitle = SavedAnswerView.subtitle(for: date)
        XCTAssertTrue(subtitle.hasPrefix("Answer"), subtitle)
        XCTAssertFalse(subtitle.lowercased().contains("read-only"))
        XCTAssertFalse(subtitle.lowercased().contains("read only"))
    }
}
