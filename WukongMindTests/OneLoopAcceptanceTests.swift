import Foundation
import XCTest
@testable import WukongMind

/// One loop acceptance check 1 (design-one-loop.md "Acceptance checks", WUKO-70): the multi-step
/// Discourse request as a recorded replay fixture. Record once with `ONE_LOOP_ACCEPT_RECORD=1`
/// (`TEST_RUNNER_ONE_LOOP_ACCEPT_RECORD`) and `TEST_RUNNER_ANTHROPIC_API_KEY` on a simulator
/// (claude-haiku-5-5 only); without the flag the run replays with the real registry over the
/// saved forum snapshot, with no network and no quota.
@MainActor
final class OneLoopAcceptanceTests: XCTestCase {
    /// The thread is D3's (one-loop-questions.md); the request is the acceptance check's own text.
    static let multiStep = ComparisonQuestion(
        id: "A1", kind: "discourse", siteURL: "https://meta.appinn.net",
        startURL: "https://meta.appinn.net/t/18527",
        prompt: "Summarize this thread first, then check what other people on this forum say about point 2, then read it to me"
    )

    /// Kept outside `Fixtures/Comparison/`, so the comparison's own set list is unchanged.
    static let set: ComparisonSet = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OneLoopAcceptance", isDirectory: true)
        return ComparisonSet(name: "acceptance", root: root, prefix: "acceptance-", runs: root.appendingPathComponent("runs", isDirectory: true))
    }()

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("one-loop-accept-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// One run: `summarize_topic`, then `search_forum` (and reads), then `read_aloud`, and an answer
    /// with Markdown-link citations. The replay matches the recording call for call.
    func testMultiStepDiscourseRequestReplays() async throws {
        let question = Self.multiStep
        guard FileManager.default.fileExists(atPath: Self.set.runFile(question.id).path) else {
            throw XCTSkip("Not recorded yet: ONE_LOOP_ACCEPT_RECORD=1.")
        }
        let saved = try RecordedNewSide.load(from: Self.set, id: question.id)
        let tools = saved.document.turns.flatMap(\.toolResults).filter { !$0.isError }.map(\.name)
        let summarize = try XCTUnwrap(tools.firstIndex(of: "summarize_topic"), "no summarize_topic: \(tools)")
        let search = try XCTUnwrap(tools.firstIndex(of: "search_forum"), "no search_forum: \(tools)")
        let readAloud = try XCTUnwrap(tools.lastIndex(of: "read_aloud"), "no read_aloud: \(tools)")
        XCTAssertTrue(summarize < search && search < readAloud, "order: \(tools)")
        let answer = saved.document.turns.last?.response?.text ?? ""
        let links = ComparisonCitations.links(in: answer)
        XCTAssertFalse(links.isEmpty, "the answer cites no thread as a Markdown link")
        XCTAssertTrue(links.allSatisfy { $0.host == "meta.appinn.net" }, "a citation leaves the forum: \(links)")
        // Recorded with operating rule 7 (WUKO-70): the whole answer comes last, after `read_aloud`.
        XCTAssertTrue(saved.document.systems.values.allSatisfy { $0.contains("after any `read_aloud` call") })
        try await OneLoopComparisonTests.assertReplays(saved, question: question, set: Self.set, folder: try temporaryFolder())
    }

    /// Operating rule 7 is in every Agent prompt: only the final message is shown and saved.
    func testThePromptPutsTheWholeAnswerInTheFinalMessage() {
        let system = BrowserAgentPrompt.system()
        XCTAssertTrue(system.contains("7. Your final message is the answer"))
        XCTAssertTrue(system.contains("after any `read_aloud` call"))
    }

    func testRecordMultiStepRun() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ONE_LOOP_ACCEPT_RECORD"] == "1" else { throw XCTSkip("Record mode only: ONE_LOOP_ACCEPT_RECORD=1.") }
        let models = try ComparisonModels.fromEnvironment(env)
        ModelAudit.shared.reset()
        let snapshot = try Self.set.snapshot(Self.multiStep.siteKind, mode: .record)
        let run = try await NewSideRun.run(
            Self.multiStep, snapshot: snapshot, ai: ComparisonAIService(session: ModelAudit.session()), modelClient: nil,
            models: models, folder: try temporaryFolder()
        )
        try run.write(to: Self.set, id: Self.multiStep.id)
        try ModelAudit.writeLog(ModelAudit.shared.recorded, to: Self.set.auditLog)
        XCTAssertFalse(ModelAudit.shared.recorded.isEmpty)
        XCTAssertTrue(ModelAudit.shared.recorded.allSatisfy { $0.model == ModelAudit.allowedModel }, "a call used a model other than \(ModelAudit.allowedModel)")
    }
    // MARK: - Page changes (WUKO-73)

    /// The owner's 1.3.0 flow: a forum thread summary, then a page change to a news page, then
    /// "Summarize this page". Recorded once with `PAGE_CHANGE_RECORD=1` (`TEST_RUNNER_PAGE_CHANGE_RECORD`)
    /// and `TEST_RUNNER_ANTHROPIC_API_KEY` (claude-haiku-5-5 only); replayed with no network.
    static let pageChangeRun = set.root.appendingPathComponent("runs/acceptance-page-change.json")
    static let forumPrompt = "Summarize this thread and replies"
    static let newsPrompt = "Summarize this page"

    func testPageChangeReadsTheNewPageAndKeepsTheSummaryShort() async throws {
        guard FileManager.default.fileExists(atPath: Self.pageChangeRun.path) else {
            throw XCTSkip("Not recorded yet: PAGE_CHANGE_RECORD=1.")
        }
        let saved = try JSONDecoder().decode(PageChangeRecording.self, from: Data(contentsOf: Self.pageChangeRun))
        XCTAssertEqual(saved.model, ModelAudit.allowedModel)
        let client = RecordedModelClient(saved.responses.map { .success($0) })
        let run = try await PageChangeRun.run(
            client: client, ai: ComparisonAIService(replaySummaries: saved.summaries), models: .offline, folder: try temporaryFolder()
        )
        XCTAssertEqual(client.recordedRequests.count, saved.responses.count, "the model was asked as often as recorded")

        // (b) A plain summary request: the card shows the summary; the reply is a line or two.
        let forumTools = run.session.runs[0].toolCalls.map(\.toolName)
        XCTAssertEqual(forumTools.filter { $0 == "summarize_topic" }.count, 1, "\(forumTools)")
        let forumAnswer = run.session.runs[0].assistantText
        XCTAssertFalse(forumAnswer.isEmpty)
        XCTAssertLessThanOrEqual(forumAnswer.count, 500, "the reply restates the summary card: \(forumAnswer)")

        // (a) After the page change, "this page" is the news page: read it, never re-summarize the thread.
        let newsRows = run.session.runs[1].toolCalls
        XCTAssertEqual(newsRows.first?.toolName, "read_page", "\(newsRows.map(\.toolName))")
        XCTAssertFalse(newsRows.contains { $0.toolName == "summarize_topic" }, "\(newsRows.map(\.toolName))")
        XCTAssertFalse(newsRows.contains { $0.argumentsJSON.contains("18527") }, "an old thread id came back")
        let newsAnswer = run.session.runs[1].assistantText.lowercased()
        XCTAssertTrue(newsAnswer.contains("coral") || newsAnswer.contains("reef"), newsAnswer)
        XCTAssertEqual(run.session.runs.count, 2)
        XCTAssertTrue(run.session.runs.allSatisfy { if case .completed = $0.state { true } else { false } })
    }

    /// (c) The cached prefix holds across a page change: the same tools and system prompt, byte for
    /// byte, and the first turn's messages a prefix of the second's, on the wire.
    func testRequestPrefixIsIdenticalAcrossAPageChange() async throws {
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "Done on the forum.")),
            .success(AgentModelTurnResponse(text: "Done on the news page."))
        ])
        _ = try await PageChangeRun.run(client: client, ai: ComparisonAIService(), models: .offline, folder: try temporaryFolder())
        XCTAssertEqual(client.recordedRequests.count, 2)
        let configuration = ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "k")
        let bodies = try client.recordedRequests.map { request -> [String: Any] in
            let wire = try AIService().makeToolRequest(
                system: request.system, messages: request.messages, tools: request.tools,
                configuration: configuration, provider: .anthropic, maxTokens: 4_096
            )
            return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(wire.httpBody)) as? [String: Any])
        }
        func bytes(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        XCTAssertEqual(try bytes(XCTUnwrap(bodies[0]["tools"])), try bytes(XCTUnwrap(bodies[1]["tools"])), "tools changed with the page")
        XCTAssertEqual(try bytes(XCTUnwrap(bodies[0]["system"])), try bytes(XCTUnwrap(bodies[1]["system"])), "system changed with the page")
        XCTAssertTrue(client.recordedRequests[0].tools.contains { $0.name == "search_forum" })

        // The breakpoint moves to the newest turn; everything before it is unchanged.
        func stripped(_ messages: Any?) throws -> [Data] {
            try XCTUnwrap(messages as? [[String: Any]]).map { message in
                var message = message
                message["content"] = (message["content"] as? [[String: Any]])?.map { $0.filter { $0.key != "cache_control" } }
                return try bytes(message)
            }
        }
        let first = try stripped(bodies[0]["messages"]), second = try stripped(bodies[1]["messages"])
        XCTAssertEqual(second.count, first.count + 2)
        XCTAssertEqual(Array(second.prefix(first.count)), first)
        let lastBlock = try XCTUnwrap((bodies[1]["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]).last
        XCTAssertNotNil(lastBlock?["cache_control"])

        // The page itself lives in each turn's page context.
        guard case .user(let forumTurn) = client.recordedRequests[1].messages[0],
              case .user(let newsTurn)? = client.recordedRequests[1].messages.last else { return XCTFail("turns") }
        XCTAssertTrue(forumTurn.contains("- URL: https://meta.appinn.net/t/18527") && forumTurn.contains("- Forum: you are on"))
        XCTAssertTrue(newsTurn.contains("- URL: \(PageChangeRun.newsPage.url)"))
        XCTAssertTrue(newsTurn.contains("The page changed since the user's previous message"))
        XCTAssertTrue(newsTurn.contains("Not a forum or a supported site"))
        XCTAssertTrue(newsTurn.hasSuffix("The user's message:\n\(Self.newsPrompt)"))
    }

    func testRecordPageChangeRun() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PAGE_CHANGE_RECORD"] == "1" else { throw XCTSkip("Record mode only: PAGE_CHANGE_RECORD=1.") }
        let models = try ComparisonModels.fromEnvironment(env)
        ModelAudit.shared.reset()
        let ai = ComparisonAIService(session: ModelAudit.session())
        let recorder = RecordingModelClient(base: ai)
        let run = try await PageChangeRun.run(client: recorder, ai: ai, models: models, folder: try temporaryFolder())
        XCTAssertTrue(ModelAudit.shared.recorded.allSatisfy { $0.model == ModelAudit.allowedModel }, "a call used a model other than \(ModelAudit.allowedModel)")
        let recording = PageChangeRecording(model: models.agent.selection.model, responses: recorder.responses, summaries: ai.recordedSummaries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(recording)
        try json.write(to: Self.pageChangeRun)
        // A remote run writes on the other Mac: the attachment carries the recording back.
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = Self.pageChangeRun.lastPathComponent
        attachment.lifetime = .keepAlways
        add(attachment)
        for (index, response) in recorder.responses.enumerated() {
            let usage = response.usage
            print("PAGE-CHANGE turn \(index + 1): \(response.toolCalls.map(\.name)) in=\(usage.inputTokens) cacheRead=\(usage.cacheReadTokens.map(String.init) ?? "n/a") out=\(usage.outputTokens)")
        }
        for (index, saved) in run.session.runs.enumerated() {
            print("PAGE-CHANGE run \(index + 1) answer (\(saved.assistantText.count) chars): \(saved.assistantText)")
        }
    }
}

/// One recorded page-change run: the Agent model's responses and the summaries, in order.
struct PageChangeRecording: Codable {
    var model: String
    var responses: [AgentModelTurnResponse]
    var summaries: [String]
}

/// Passes each turn to the live client and keeps its response (record mode).
final class RecordingModelClient: AgentModelClient, @unchecked Sendable {
    private let base: AgentModelClient
    private let lock = NSLock()
    private(set) var responses: [AgentModelTurnResponse] = []

    init(base: AgentModelClient) { self.base = base }

    func completeToolTurn(
        system: String, messages: [AgentModelTurn], tools: [AgentToolDefinition],
        configuration: ProviderConfiguration, provider: AIProvider, maxTokens: Int
    ) async throws -> AgentModelTurnResponse {
        let response = try await base.completeToolTurn(
            system: system, messages: messages, tools: tools, configuration: configuration, provider: provider, maxTokens: maxTokens
        )
        lock.withLock { responses.append(response) }
        return response
    }
}

@MainActor
enum PageChangeRun {
    static let thread = OneLoopAcceptanceTests.multiStep
    static let newsPage = FixturePageDriver.SavedPage(
        url: "https://news.example.org/science/2026/11/14/pacific-coral-reefs-recover",
        title: "Pacific coral reefs recover faster than expected, survey finds",
        structure: """
        Page: Pacific coral reefs recover faster than expected, survey finds
        URL: https://news.example.org/science/2026/11/14/pacific-coral-reefs-recover
        main > article
          h1: Pacific coral reefs recover faster than expected, survey finds
          p (byline): By the Science desk, 14 November 2026
          p: A five-year survey of 120 reefs across the western Pacific found that coral cover returned to 80% of its \
        pre-bleaching level within four years on reefs protected from fishing, twice as fast as scientists had predicted.
          p: Unprotected reefs recovered only half as much. The researchers credit grazing fish, which keep algae from \
        smothering young coral.
          p: The team warns that recovery depends on bleaching events staying at least six years apart; at the current \
        rate of ocean warming, that gap is shrinking.
          p: The authors call for wider no-fishing zones and say the findings give "real grounds for hope".
        """,
        text: """
        Pacific coral reefs recover faster than expected, survey finds
        By the Science desk, 14 November 2026
        A five-year survey of 120 reefs across the western Pacific found that coral cover returned to 80% of its \
        pre-bleaching level within four years on reefs protected from fishing, twice as fast as scientists had predicted.
        Unprotected reefs recovered only half as much. The researchers credit grazing fish, which keep algae from smothering young coral.
        The team warns that recovery depends on bleaching events staying at least six years apart; at the current rate of \
        ocean warming, that gap is shrinking.
        The authors call for wider no-fishing zones and say the findings give "real grounds for hope".
        """
    )

    struct Result {
        var session: BrowserAgentSession
    }

    /// Two turns in one conversation: the thread summary on the forum page, then "Summarize this page"
    /// after the browser moved to the news page.
    static func run(client: AgentModelClient, ai: ComparisonAIService, models: ComparisonModels, folder: URL) async throws -> Result {
        let snapshot = try OneLoopAcceptanceTests.set.snapshot(thread.siteKind, mode: .replay)
        let app = try ComparisonApp.make(thread, snapshot: snapshot, ai: ai, models: models, folder: folder)
        let forumName = ForumSite.displayName(siteURL: thread.siteURL, name: nil)
        app.browser.setPageContext(PageContext(
            url: URL(string: thread.startURL), site: thread.siteKind, siteURL: thread.siteURL, forumName: forumName, state: .topic
        ))
        let driver = FixturePageDriver(page: .init(
            url: thread.startURL, title: forumName,
            structure: "Page: \(forumName)\nURL: \(thread.startURL)", text: "\(forumName)\n\(thread.startURL)"
        ))
        weak var box: BrowserAgentSession?
        let session = BrowserAgentSession(
            pageDriver: driver,
            modelClient: client,
            configProvider: { [unowned app] in app.browserAgentRuntimeConfig },
            registryBuilder: { [unowned app] bridge, limit, secrets in
                ToolRegistry.m3(context: AgentToolContext(
                    bridge: bridge, workspace: app.agentWorkspace, scriptStore: app.scriptStore, liveApplier: app.scriptWebController,
                    currentUserPrompt: { box?.lastUserPrompt },
                    settings: AgentToolSettings(truncationLimit: limit, redactedSecrets: secrets),
                    network: app.agentHTTPClient, confirmations: app.agentConfirmations,
                    forum: app.makeForumToolContext(), capabilities: app.capabilityToolContext
                ))
            }
        )
        box = session
        await session.sendAndWait(OneLoopAcceptanceTests.forumPrompt)
        driver.show(newsPage)
        app.browser.setPageContext(PageContext(url: URL(string: newsPage.url), state: .notForum))
        await session.sendAndWait(OneLoopAcceptanceTests.newsPrompt)
        XCTAssertEqual(snapshot.unmatchedURLs, [], "the run asked for a URL the snapshot lacks")
        return Result(session: session)
    }
}
