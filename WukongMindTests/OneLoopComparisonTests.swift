import Foundation
import XCTest
@testable import WukongMind

/// The One loop comparison (design-one-loop.md "Comparison test").
/// - Record (`ONE_LOOP_RECORD=1`, task 8, real quota): for each confirmed question, old Research
///   runs once live (its result goes only into the report), then the new Agent runs on the same
///   text and page. Forum traffic goes through `ForumSnapshot` in record mode; the new side's runs
///   are saved under `Fixtures/Comparison/runs/`; the report goes to `docs/wukongmind/one-loop-comparison.md`.
/// - Replay (no flag, CI): each saved new-side run replays with the real registry over the snapshot.
@MainActor
final class OneLoopComparisonTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("one-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Dry run, writer and replay (no network, no quota)

    static let dryQuestion = ComparisonQuestion(
        id: "DRY1", kind: "discourse", siteURL: "https://discourse.fixture.test",
        startURL: "https://discourse.fixture.test/t/42",
        prompt: #"In the thread "Rebuild fails" (https://discourse.fixture.test/t/42), which fix worked?"#
    )
    static let dryAnswer = "Pinning oj 3.13.20 without SSE4.2 fixed the rebuild "
        + "([Rebuild fails](https://discourse.fixture.test/t/42/2))."

    func testDryRecordWritesARunTheReportAndReplays() async throws {
        let folder = try temporaryFolder()
        let question = Self.dryQuestion
        let snapshot = try ForumSnapshot(kind: question.siteKind, mode: .replay)
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(
                text: "", toolCalls: [AgentModelToolCall(id: "c1", name: "read_topic", arguments: ["topic_id": .string("42")])],
                stopReason: "tool_use", usage: AgentTokenUsage(inputTokens: 1_200, outputTokens: 40)
            )),
            .success(AgentModelTurnResponse(text: Self.dryAnswer, usage: AgentTokenUsage(inputTokens: 2_000, outputTokens: 60)))
        ])
        let recorded = try await NewSideRun.run(
            question, snapshot: snapshot, ai: ComparisonAIService(), modelClient: client,
            models: .offline, folder: folder.appendingPathComponent("record", isDirectory: true)
        )
        XCTAssertEqual(snapshot.unmatchedURLs, [])
        XCTAssertEqual(recorded.side.calls.map(\.tool), ["read_topic"])
        XCTAssertEqual(recorded.side.answer, Self.dryAnswer)
        XCTAssertEqual(recorded.side.loopTokens, AgentTokenUsage(inputTokens: 3_200, outputTokens: 100))
        XCTAssertEqual(recorded.side.summaryTokens, .zero)
        XCTAssertEqual(recorded.side.topicsRead, 1)

        // The run is written like task 8's, and loads back.
        let runs = folder.appendingPathComponent("runs", isDirectory: true)
        try recorded.write(to: runs, id: question.id)
        let saved = try RecordedNewSide.load(from: runs, id: question.id)
        XCTAssertEqual(saved.document.turns.flatMap(\.toolResults).map(\.name), ["read_topic"])
        XCTAssertEqual(saved.document.turns.last?.response?.text, Self.dryAnswer)

        // The writer, given the run and a canned old side, writes the specified format.
        let old = ComparisonSide(
            calls: [
                ComparisonCall(tool: "search_forum", arguments: "query=rebuild oj", result: "3 threads", isError: false),
                ComparisonCall(tool: "read_topic", arguments: "topic_id=42", result: "2 posts", isError: false)
            ],
            answer: "Pin oj to 3.13.20 ([Rebuild fails](https://discourse.fixture.test/t/rebuild-fails/42)) "
                + "and see [elsewhere](https://example.org/x).",
            loopTokens: AgentTokenUsage(inputTokens: 4_000, outputTokens: 300), summaryTokens: nil, topicsRead: 1, seconds: 12
        )
        let report = OneLoopReport.markdown(
            header: ComparisonHeader(
                date: "2026-11-14", agentModel: "Anthropic claude-haiku-5-5", summaryModel: "Anthropic claude-haiku-5-5",
                appCommit: "abc1234", forums: ["discourse: https://discourse.fixture.test"],
                textToolCount: 21, toolDefinitionTokens: 3_456
            ),
            rows: [ComparisonRow(question: question, old: old, new: recorded.side, misses: [])],
            isSnapshotThread: { ComparisonCitations.isThread($1, question: $0, snapshot: snapshot) }
        )
        for part in [
            "# One loop comparison", "| Agent model (both loops) | Anthropic claude-haiku-5-5 |", "| App commit | abc1234 |",
            "| Snapshot misses | DRY1: 0 |", "| Text Agent's tools on forum pages | 21 tools, 3456 tokens of definitions |",
            "## Totals", "| discourse | Old Research | 4000 | 300 | n/a | n/a | 2 | 1 | 12.0 s |",
            "| discourse | New Agent | 3200 | 100 | 0 | 0 | 1 | 1 |", "| All | New Agent | 3200 | 100 |",
            "### DRY1", "**Question:** " + question.prompt, "**Starting page:** https://discourse.fixture.test/t/42",
            "1. `search_forum` query=rebuild oj → 3 threads", "1. `read_topic` topic_id=42 →",
            "**Answer:**\n\n" + Self.dryAnswer,
            "**Citations:** 2, 1 a thread in the snapshot", "- https://example.org/x: not in the snapshot",
            "- https://discourse.fixture.test/t/42/2: thread in the snapshot",
            "**Tokens:** loop 4000 in / 300 out · summary n/a", "**Tokens:** loop 3200 in / 100 out · summary 0 in / 0 out",
            "| Owner verdict | |", "## Approval", "Approved by the owner on YYYY-MM-DD: yes / no"
        ] {
            XCTAssertTrue(report.contains(part), "report lacks: \(part)\n\(report)")
        }

        // Threads cited from a list body count, slug permalinks (no ID) by their URL in a body.
        let listFolder = folder.appendingPathComponent("wp-list", isDirectory: true)
        try FileManager.default.createDirectory(at: listFolder, withIntermediateDirectories: true)
        try Data(#"{"url":"https://blog.test/wp-json/wp/v2/posts","status":200,"headers":{},"body":[{"id":184521,"link":"https://blog.test/chase-offer/"}]}"#.utf8)
            .write(to: listFolder.appendingPathComponent("wordpress-posts.json"))
        let list = try ForumSnapshot(kind: .wordpress, mode: .replay, directory: listFolder)
        let blog = ComparisonQuestion(id: "W", kind: "wordpress", siteURL: "https://blog.test", startURL: "https://blog.test/", prompt: "")
        XCTAssertTrue(ComparisonCitations.isThread(URL(string: "https://blog.test/chase-offer")!, question: blog, snapshot: list))
        XCTAssertTrue(ComparisonCitations.isThread(URL(string: "https://blog.test/?p=184521")!, question: blog, snapshot: list))
        XCTAssertFalse(ComparisonCitations.isThread(URL(string: "https://blog.test/other-post/")!, question: blog, snapshot: list))
        XCTAssertFalse(ComparisonCitations.isThread(URL(string: "https://blog.test/?p=1845")!, question: blog, snapshot: list))

        if let out = ProcessInfo.processInfo.environment["ONE_LOOP_DRY_REPORT_OUT"] { try Data(report.utf8).write(to: URL(fileURLWithPath: out)) }

        // Replay: the real tools over the snapshot, the recorded model turns.
        try await Self.assertReplays(saved, question: question, folder: folder.appendingPathComponent("replay", isDirectory: true))
    }

    /// The saved new-side runs replay with the real registry: same calls, same errors, same final text.
    /// Every recording set replays: task 8's, and each later re-record (`gate2`, WUKO-63) over its own snapshot.
    func testRecordedNewSideRunsReplay() async throws {
        let questions = try ComparisonQuestion.confirmed()
        XCTAssertEqual(Dictionary(grouping: questions, by: \.kind).mapValues(\.count), ["discourse": 5, "hackernews": 5, "wordpress": 5])
        var replayed = 0
        for set in ComparisonSet.all() {
            for question in questions where FileManager.default.fileExists(atPath: set.runFile(question.id).path) {
                let saved = try RecordedNewSide.load(from: set, id: question.id)
                try await Self.assertReplays(saved, question: question, set: set, folder: try temporaryFolder())
                if set.name == "gate2" { Self.assertGateTwo(saved, id: question.id) }
                replayed += 1
            }
        }
        guard replayed > 0 else { throw XCTSkip("No recorded new-side runs yet (task 8 records them).") }
    }

    /// Gate 2's conditions on the re-recorded runs: W2 cites a Markdown link, H3 searches beyond
    /// the named thread, H4 reads at least one thread.
    static func assertGateTwo(_ saved: RecordedNewSide, id: String) {
        let tools = saved.document.turns.flatMap(\.toolResults).filter { !$0.isError }.map(\.name)
        let answer = saved.document.turns.last?.response?.text ?? ""
        switch id {
        case "W2": XCTAssertFalse(ComparisonCitations.links(in: answer).isEmpty, "W2: no Markdown-link source")
        case "H3": XCTAssertTrue(tools.contains { ["search_forum", "search_comments"].contains($0) }, "H3: no search beyond the thread: \(tools)")
        case "H4": XCTAssertTrue(tools.contains { ["read_topic", "summarize_topic"].contains($0) }, "H4: no thread read: \(tools)")
        default: break
        }
    }

    static func assertReplays(_ saved: RecordedNewSide, question: ComparisonQuestion, set: ComparisonSet = .main, folder: URL) async throws {
        let recordedResults = saved.document.turns.flatMap(\.toolResults)
        let snapshot = try set.snapshot(question.siteKind, mode: .replay)
        let client = RecordedModelClient(export: saved.document)
        let responseCount = saved.document.turns.compactMap(\.response).count
        let replayed = try await NewSideRun.run(
            question, snapshot: snapshot, ai: ComparisonAIService(replaySummaries: saved.summaries), modelClient: client,
            models: .offline, folder: folder, recordedTaskID: saved.taskID
        )
        XCTAssertEqual(snapshot.unmatchedURLs, [], "\(question.id): replay asked for a URL the snapshot lacks")
        XCTAssertEqual(client.recordedRequests.count, responseCount, "\(question.id): the model was asked more often than recorded")
        XCTAssertEqual(replayed.side.calls.map(\.tool), recordedResults.map(\.name), "\(question.id): tool sequence")
        XCTAssertEqual(replayed.calls.map(\.arguments), recordedResults.map(\.arguments), "\(question.id): tool arguments")
        XCTAssertEqual(replayed.side.calls.map(\.isError), recordedResults.map(\.isError), "\(question.id): tool errors")
        XCTAssertEqual(replayed.side.answer, saved.document.turns.last?.response?.text, "\(question.id): final text")
    }

    // MARK: Gate 2 fixes (WUKO-63), over the recorded snapshot

    /// Runs one recorded tool call through the real registry on a question's snapshot and returns
    /// what the model was sent back, plus the run folder (for a result saved to the workspace).
    private func toolResult(
        _ id: String, tool: String, arguments: [String: JSONValue]
    ) async throws -> (result: AgentModelToolResult, system: String, folder: URL) {
        let question = try XCTUnwrap(ComparisonQuestion.confirmed().first { $0.id == id })
        let folder = try temporaryFolder()
        let snapshot = try ForumSnapshot(kind: question.siteKind, mode: .replay)
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "c1", name: tool, arguments: arguments)], stopReason: "tool_use")),
            .success(AgentModelTurnResponse(text: "Done."))
        ])
        _ = try await NewSideRun.run(question, snapshot: snapshot, ai: ComparisonAIService(), modelClient: client, models: .offline, folder: folder)
        XCTAssertEqual(snapshot.unmatchedURLs, [])
        let request = try XCTUnwrap(client.recordedRequests.last)
        let results = request.messages.compactMap { turn -> AgentModelToolResult? in
            if case .toolResults(let list) = turn { return list.first }
            return nil
        }
        return (try XCTUnwrap(results.first), request.system, folder)
    }

    /// W2: the recorded query ("multiple purchases one transaction cart total") matches 70 of the
    /// thread's 317 comments on common words. In thread order the July 2026 terms (#261, "single
    /// transaction") sat past the 12,000 characters the Agent read; best matches first, they lead.
    func testThreadQueryPutsTheSingleTransactionTermsInTheFirstRead() async throws {
        let read = try await toolResult("W2", tool: "read_topic", arguments: [
            "topic_id": .string("229112"), "query": .string("multiple purchases one transaction cart total")
        ])
        let files = FileManager.default.enumerator(at: read.folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        let saved = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix("read_topic.txt") }, "the long result is saved to the workspace")
        let text = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertTrue(text.contains("best matches first"))
        let terms = try XCTUnwrap(text.range(of: "| #261\n"), "comment #261 matches")
        XCTAssertTrue(text[terms.upperBound...].hasPrefix("This offer is back."))
        XCTAssertLessThan(text.distance(from: text.startIndex, to: terms.lowerBound), 12_000, "#261 inside the first file_read window")
        XCTAssertTrue(read.result.content.contains(ForumToolHint.queryInTopic(topic: "post")), "the hint survives the saved-file preview")
    }

    /// H3: a query inside the named thread tells the model it covers that thread only, and the
    /// prompt's rule asks for a forum search beyond it.
    func testInThreadQueryPointsToAForumSearch() async throws {
        let read = try await toolResult("H3", tool: "read_topic", arguments: ["topic_id": .string("44809166"), "query": .string("funnel")])
        XCTAssertTrue(read.result.content.contains(ForumToolHint.queryInTopic(topic: "story")), read.result.content.prefix(400).description)
        XCTAssertTrue(read.system.contains("search the site for it (`search_forum`) beyond that story before answering"))
    }

    /// H4: the latest list says it is titles only and asks for a read before recommending.
    func testLatestListAsksForAReadBeforeRecommending() async throws {
        let list = try await toolResult("H4", tool: "list_latest", arguments: [:])
        XCTAssertTrue(list.result.content.contains(ForumToolHint.latest(topic: "story")))
        XCTAssertTrue(list.system.contains("never recommend from titles alone"))
    }

    // MARK: Record (task 8)

    func testRecordComparison() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ONE_LOOP_RECORD"] == "1" else { throw XCTSkip("Record mode only: ONE_LOOP_RECORD=1 (TEST_RUNNER_ONE_LOOP_RECORD).") }
        let models = try ComparisonModels.fromEnvironment(env)
        // `ONE_LOOP_SET=<name>` records into Fixtures/Comparison/<name>/ (a fresh snapshot, runs and
        // audit log) and writes the report to `ONE_LOOP_REPORT_OUT`, leaving task 8's files alone.
        let set = env["ONE_LOOP_SET"].map(ComparisonSet.named) ?? .main
        let reportURL = env["ONE_LOOP_REPORT_OUT"].map { URL(fileURLWithPath: $0) } ?? OneLoopReport.defaultURL
        if set.name != "main" {
            XCTAssertNotEqual(reportURL, OneLoopReport.defaultURL, "a re-record set needs ONE_LOOP_REPORT_OUT")
            guard reportURL != OneLoopReport.defaultURL else { return }
        }
        let only = env["ONE_LOOP_ONLY"].map { $0.split(separator: ",").map(String.init) }
        let questions = try ComparisonQuestion.confirmed().filter { question in only?.contains(question.id) ?? true }
        // Each finished question is saved at once (`ONE_LOOP_ROWS_DIR`, outside the repo: the old side
        // lives only in the report), so a crashed test host loses at most the question it was on.
        let rowsDirectory = URL(fileURLWithPath: env["ONE_LOOP_ROWS_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("one-loop-rows", isDirectory: true)
        try FileManager.default.createDirectory(at: rowsDirectory, withIntermediateDirectories: true)
        var snapshots: [String: ForumSnapshot] = [:]
        var toolCost = (try? JSONDecoder().decode(SavedToolCost.self, from: Data(contentsOf: rowsDirectory.appendingPathComponent("tools.json")))) ?? SavedToolCost(count: 0, tokens: nil)
        func snapshot(for question: ComparisonQuestion) throws -> ForumSnapshot {
            let value = try snapshots[question.kind] ?? set.snapshot(question.siteKind, mode: .record)
            snapshots[question.kind] = value
            return value
        }
        for question in questions {
            let file = rowsDirectory.appendingPathComponent("row-\(question.id).json")
            if FileManager.default.fileExists(atPath: file.path) { continue }
            let snapshot = try snapshot(for: question)
            ModelAudit.shared.reset()
            let old = try await OldSideRun.run(question, snapshot: snapshot, models: models, folder: try temporaryFolder())
            snapshot.resetMisses()
            let new = try await NewSideRun.run(
                question, snapshot: snapshot, ai: ComparisonAIService(session: ModelAudit.session()), modelClient: nil, models: models, folder: try temporaryFolder()
            )
            try new.write(to: set, id: question.id)
            if toolCost.tokens == nil, let tools = new.document.toolSets.values.first {
                toolCost = SavedToolCost(count: tools.count, tokens: try? await ToolDefinitionCost.anthropicTokens(tools: tools, models: models))
                try JSONEncoder().encode(toolCost).write(to: rowsDirectory.appendingPathComponent("tools.json"))
            }
            try JSONEncoder().encode(SavedRow(id: question.id, old: old, new: new.side, misses: snapshot.misses.map(\.absoluteString), audit: ModelAudit.shared.recorded))
                .write(to: file, options: .atomic)
        }
        var rows: [ComparisonRow] = []
        var audit: [ModelAudit.Entry] = []
        for question in try ComparisonQuestion.confirmed() {
            guard let saved = try? JSONDecoder().decode(SavedRow.self, from: Data(contentsOf: rowsDirectory.appendingPathComponent("row-\(question.id).json"))) else { continue }
            rows.append(ComparisonRow(question: question, old: saved.old, new: saved.new, misses: saved.misses))
            audit += saved.audit
        }
        let reportQuestions = rows.map(\.question)
        let report = OneLoopReport.markdown(
            header: ComparisonHeader(
                date: ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate]),
                agentModel: models.agent.label, summaryModel: models.summary.label, appCommit: env["ONE_LOOP_COMMIT"] ?? "unknown",
                forums: Dictionary(grouping: reportQuestions, by: \.kind).keys.sorted().compactMap { kind in
                    reportQuestions.first { $0.kind == kind }.map { "\(kind): \($0.siteURL)" }
                },
                textToolCount: toolCost.count, toolDefinitionTokens: toolCost.tokens
            ),
            rows: rows,
            isSnapshotThread: { question, url in
                ComparisonCitations.isThread(url, question: question, snapshot: try? snapshot(for: question))
            }
        )
        XCTAssertFalse(audit.isEmpty)
        XCTAssertTrue(audit.allSatisfy { $0.model == ModelAudit.allowedModel }, "a call used a model other than \(ModelAudit.allowedModel)")
        try ModelAudit.writeLog(audit, to: set.auditLog)
        let models_ = Dictionary(grouping: audit, by: \.model).mapValues(\.count).sorted { $0.key < $1.key }
            .map { "\($0.value) × `\($0.key)`" }.joined(separator: ", ")
        let auditSection = "\n## Model audit\n\nEvery model request of this record run (old loop, new loop, summaries and the tool-definition count) "
            + "passed through `ModelAudit`, which reads the request body's `model` and refuses anything but `\(ModelAudit.allowedModel)`. "
            + "\(audit.count) calls: \(models_). The log (host, path, model, status; no keys) is `WukongMindTests/Fixtures/Comparison/model-audit.jsonl`; "
            + "the recorded new-side runs under `Fixtures/Comparison/runs/` name the model per turn as well.\n"
        try Data(report.replacingOccurrences(of: "\n## Approval", with: auditSection + "\n## Approval").utf8).write(to: reportURL, options: .atomic)
    }
}

// MARK: - Inputs

struct SavedToolCost: Codable { var count: Int; var tokens: Int? }
struct SavedRow: Codable { var id: String; var old: ComparisonSide; var new: ComparisonSide; var misses: [String]; var audit: [ModelAudit.Entry] }

struct ComparisonQuestion: Equatable, Sendable {
    var id: String
    var kind: String
    var siteURL: String
    var startURL: String
    var prompt: String

    var siteKind: SiteKind { SiteKind(kind) }
    var startsOnHome: Bool { URL(string: startURL).map { $0.query == nil && $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty } ?? true }

    static let questionsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/wukongmind/one-loop-questions.md")

    static func confirmed() throws -> [ComparisonQuestion] {
        parse(markdown: try String(contentsOf: questionsURL, encoding: .utf8))
    }

    /// Reads `one-loop-questions.md`: `## <Forum> (`<site>`)` sections, `- **D1 · …**` items with
    /// `**Starting page:**` and `**Prompt:**` lines in backticks.
    static func parse(markdown: String) -> [ComparisonQuestion] {
        var result: [ComparisonQuestion] = []
        var siteURL = ""
        var kind = ""
        var current: ComparisonQuestion?
        func ticked(_ line: Substring) -> String? {
            guard let first = line.firstIndex(of: "`"), let last = line.lastIndex(of: "`"), first < last else { return nil }
            return String(line[line.index(after: first)..<last])
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)[...]
            if line.hasPrefix("## ") {
                siteURL = ticked(line) ?? ""
                kind = line.contains("Discourse") ? "discourse" : line.contains("Hacker News") ? "hackernews" : line.contains("WordPress") ? "wordpress" : ""
            } else if line.hasPrefix("- **Starting page:**") {
                current?.startURL = ticked(line) ?? ""
            } else if line.hasPrefix("- **Prompt:**") {
                if var question = current {
                    question.prompt = ticked(line) ?? ""
                    if !question.kind.isEmpty, !question.startURL.isEmpty, !question.prompt.isEmpty { result.append(question) }
                }
                current = nil
            } else if line.hasPrefix("- **"), let dot = line.range(of: " · ") {
                current = ComparisonQuestion(id: String(line[line.index(line.startIndex, offsetBy: 4)..<dot.lowerBound]),
                                             kind: kind, siteURL: siteURL, startURL: "", prompt: "")
            }
        }
        return result
    }
}

struct ComparisonModels {
    struct Model { var selection: ModelSelection; var apiKey: String; var label: String { "\(selection.provider.displayName) \(selection.model)" } }
    var agent: Model
    var summary: Model

    /// Replay and dry runs: no provider is reached (the model client and summaries are recorded).
    static let offline = ComparisonModels(
        agent: Model(selection: ModelSelection(provider: .anthropic, model: "recorded"), apiKey: "replay-key"),
        summary: Model(selection: ModelSelection(provider: .anthropic, model: "recorded"), apiKey: "replay-key")
    )

    /// `ONE_LOOP_AGENT_MODEL` (the owner's Agent model, on both loops), `ONE_LOOP_SUMMARY_PROVIDER` /
    /// `ONE_LOOP_SUMMARY_MODEL` (the Summaries model), keys from `ANTHROPIC_API_KEY` or `<PROVIDER>_API_KEY`.
    static func fromEnvironment(_ env: [String: String]) throws -> ComparisonModels {
        func key(_ provider: AIProvider) throws -> String {
            let name = provider == .anthropic ? "ANTHROPIC_API_KEY" : "\(provider.rawValue.uppercased())_API_KEY"
            guard let value = env[name], !value.isEmpty else { throw XCTSkip("Record mode needs \(name).") }
            return value
        }
        let agentModel = env["ONE_LOOP_AGENT_MODEL"] ?? "claude-haiku-5-5"
        let summaryProvider = env["ONE_LOOP_SUMMARY_PROVIDER"].flatMap(AIProvider.init(rawValue:)) ?? .anthropic
        let summaryModel = env["ONE_LOOP_SUMMARY_MODEL"] ?? agentModel
        return ComparisonModels(
            agent: Model(selection: ModelSelection(provider: TokenUsageSink.coveredFamily, model: agentModel), apiKey: try key(TokenUsageSink.coveredFamily)),
            summary: Model(selection: ModelSelection(provider: summaryProvider, model: summaryModel), apiKey: try key(summaryProvider))
        )
    }
}

// MARK: - Results

struct ComparisonCall: Codable, Equatable {
    var tool: String
    var arguments: String
    var result: String
    var isError: Bool
}

struct ComparisonSide: Codable, Equatable {
    var calls: [ComparisonCall]
    var answer: String
    /// nil: the loop's family doesn't report usage ("n/a").
    var loopTokens: AgentTokenUsage?
    var summaryTokens: AgentTokenUsage?
    var topicsRead: Int
    var seconds: Double
}

struct ComparisonRow {
    var question: ComparisonQuestion
    var old: ComparisonSide
    var new: ComparisonSide
    /// URLs the new side fetched live because the old side hadn't.
    var misses: [String]
}

struct ComparisonHeader {
    var date: String
    var agentModel: String
    var summaryModel: String
    var appCommit: String
    var forums: [String]
    var textToolCount: Int
    var toolDefinitionTokens: Int?
}

/// Counts `generateSummary` into the Summary sink and the old planner's `complete` into the loop sink;
/// in replay, answers summaries from the run's saved list, in order.
final class ComparisonAIService: AIService, @unchecked Sendable {
    let loopUsage = TokenUsageSink()
    let summaryUsage = TokenUsageSink()
    private let lock = NSLock()
    private var replaySummaries: [String]?
    private(set) var recordedSummaries: [String] = []

    init(session: URLSession = .shared, replaySummaries: [String]? = nil) {
        self.replaySummaries = replaySummaries
        super.init(session: session)
    }

    override func complete(
        system: String, messages: [ChatMessage], configuration: ProviderConfiguration, provider: AIProvider, maxTokens: Int = 4_096
    ) async throws -> String {
        try await TokenUsageSink.$current.withValue(loopUsage) {
            try await super.complete(system: system, messages: messages, configuration: configuration, provider: provider, maxTokens: maxTokens)
        }
    }

    override func generateSummary(
        content: String, configuration: ProviderConfiguration, provider: AIProvider, customPrompt: String,
        discussion: DiscussionProfile, batchLimit: Int = SummaryBatchLimit.default,
        onDelta: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }
    ) async throws -> String {
        if let replayed = try lock.withLock({ () throws -> String? in
            guard replaySummaries != nil else { return nil }
            guard let next = replaySummaries?.first else { throw AssistantError.emptyResponse }
            replaySummaries?.removeFirst()
            return next
        }) {
            return replayed
        }
        let text = try await TokenUsageSink.$current.withValue(summaryUsage) {
            try await super.generateSummary(
                content: content, configuration: configuration, provider: provider, customPrompt: customPrompt,
                discussion: discussion, batchLimit: batchLimit, onDelta: onDelta, onProgress: onProgress
            )
        }
        lock.withLock { recordedSummaries.append(text) }
        return text
    }
}

/// A fresh app per side and question: empty sessions, its own workspace, the snapshot's forum.
@MainActor
enum ComparisonApp {
    static func make(_ question: ComparisonQuestion, snapshot: ForumSnapshot, ai: AIService, models: ComparisonModels, folder: URL) throws -> AppModel {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = AppModel(
            store: PersistentStore(fileURL: folder.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore()),
            forumService: snapshot.makeForumService(pacer: snapshot.mode == .replay ? ForumRequestPacer(clock: InstantPacingClock()) : ForumRequestPacer()),
            aiService: ai, workspaceDirectory: folder.appendingPathComponent("Documents", isDirectory: true)
        )
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        var settings = app.settings
        for model in [models.agent, models.summary] {
            var configuration = settings.configuration(for: model.selection.provider)
            configuration.apiKey = model.apiKey
            settings.setConfiguration(configuration, for: model.selection.provider)
        }
        app.settings = settings
        // The Agent model on both loops (the Research role too), the Summaries model for summaries.
        app.selectModel(models.agent.selection, for: .role(.browserAgent))
        app.selectModel(models.agent.selection, for: .role(.agent))
        app.selectModel(models.summary.selection, for: .role(.assistant))
        app.recordVisit(siteURL: question.siteURL, kind: question.siteKind, name: nil, iconURL: nil)
        return app
    }
}

// MARK: - Old side (record mode only: one live pass, written into the report)

@MainActor
enum OldSideRun {
    static func run(_ question: ComparisonQuestion, snapshot: ForumSnapshot, models: ComparisonModels, folder: URL) async throws -> ComparisonSide {
        let ai = ComparisonAIService(session: ModelAudit.session())
        let app = try ComparisonApp.make(question, snapshot: snapshot, ai: ai, models: models, folder: folder)
        let started = Date()
        app.startAgentRun(goal: question.prompt, siteURL: question.siteURL)
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline, !(app.agentRuns.first?.isFinished ?? false) { try await Task.sleep(for: .milliseconds(200)) }
        guard let run = app.agentRuns.first else { throw AssistantError.invalidResponse }
        let steps = run.steps.filter { $0.tool != AgentPrompt.finalAnswerTool }
        let reads: Set<String> = [AgentToolName.readTopic.rawValue, AgentToolName.summarizeTopic.rawValue]
        return ComparisonSide(
            calls: steps.map { step in
                ComparisonCall(
                    tool: step.tool, arguments: step.arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
                    result: step.outcome, isError: step.isError
                )
            },
            answer: run.answer.isEmpty ? "Error: \(run.error)" : run.answer,
            loopTokens: ai.loopUsage.usage, summaryTokens: TokenUsageSink.covers(models.summary.selection.provider) ? ai.summaryUsage.usage : nil,
            topicsRead: Set(steps.filter { reads.contains($0.tool) && !$0.isError }.compactMap { $0.topicKey ?? $0.topicID }).count,
            seconds: Date().timeIntervalSince(started)
        )
    }
}

// MARK: - New side

@MainActor
private final class SessionBox {
    weak var session: BrowserAgentSession?
}

private struct NoCookies: TaskCookieSource {
    func cookies(forHosts hosts: Set<String>) async -> [KnownCookie]? { [] }
}

/// Where one recording lives: a snapshot per forum kind, the new-side runs and the audit log.
/// `main` is task 8's (WUKO-61). A named set (`gate2`, WUKO-63's re-record after the gate 2
/// fixes) is `Fixtures/Comparison/<name>/`, its files prefixed `<name>-` so no bundle resource
/// name repeats, and starts from an empty snapshot.
struct ComparisonSet {
    var name: String
    var root: URL
    var prefix: String
    var runs: URL

    static let comparisonRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Comparison", isDirectory: true)
    static let main = ComparisonSet(name: "main", root: comparisonRoot, prefix: "", runs: comparisonRoot.appendingPathComponent("runs", isDirectory: true))

    static func named(_ name: String) -> ComparisonSet {
        guard name != "main" else { return .main }
        let root = comparisonRoot.appendingPathComponent(name, isDirectory: true)
        return ComparisonSet(name: name, root: root, prefix: "\(name)-", runs: root.appendingPathComponent("runs", isDirectory: true))
    }

    /// `main` and every named set on disk (a folder of `Fixtures/Comparison` with `runs/`).
    static func all() -> [ComparisonSet] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: comparisonRoot, includingPropertiesForKeys: nil)) ?? []
        let named = folders.map(\.lastPathComponent).sorted()
            .filter { FileManager.default.fileExists(atPath: comparisonRoot.appendingPathComponent("\($0)/runs").path) }
        return [.main] + named.map(Self.named)
    }

    func runFile(_ id: String) -> URL { runs.appendingPathComponent("\(prefix)run-\(id).json") }
    func summariesFile(_ id: String) -> URL { runs.appendingPathComponent("\(prefix)run-\(id).summaries.json") }
    var auditLog: URL { root.appendingPathComponent("model-audit.jsonl") }

    func snapshot(_ kind: SiteKind, mode: ForumSnapshot.Mode) throws -> ForumSnapshot {
        try ForumSnapshot(kind: kind, mode: mode, directory: root.appendingPathComponent(kind.id, isDirectory: true), filePrefix: prefix)
    }
}

/// One new-side run: what the report shows, its exported task record and its summaries.
struct RecordedNewSide {
    var side: ComparisonSide
    var calls: [(tool: String, arguments: [String: JSONValue])] = []
    var document: TaskExportDocument
    var summaries: [String]

    var taskID: String? {
        document.turns.flatMap(\.toolResults).compactMap(\.savedPath).first.flatMap { path in
            path.split(separator: "/").dropFirst().first.map(String.init)
        }
    }

    static var defaultDirectory: URL { ComparisonSet.main.runs }

    /// `run-<id>.json` (the task export) and `run-<id>.summaries.json`, never a snapshot kind's prefix.
    func write(to folder: URL, id: String) throws {
        try write(to: ComparisonSet(name: "", root: folder.deletingLastPathComponent(), prefix: "", runs: folder), id: id)
    }

    func write(to set: ComparisonSet, id: String) throws {
        try FileManager.default.createDirectory(at: set.runs, withIntermediateDirectories: true)
        try TaskExport.encoder.encode(document).write(to: set.runFile(id), options: .atomic)
        try TaskExport.encoder.encode(summaries).write(to: set.summariesFile(id), options: .atomic)
    }

    static func load(from folder: URL, id: String) throws -> RecordedNewSide {
        try load(from: ComparisonSet(name: "", root: folder.deletingLastPathComponent(), prefix: "", runs: folder), id: id)
    }

    static func load(from set: ComparisonSet, id: String) throws -> RecordedNewSide {
        let document = try TaskExport.load(try Data(contentsOf: set.runFile(id)))
        let summaries = (try? JSONDecoder().decode([String].self, from: try Data(contentsOf: set.summariesFile(id)))) ?? []
        return RecordedNewSide(
            side: ComparisonSide(calls: [], answer: document.turns.last?.response?.text ?? "", loopTokens: nil, summaryTokens: nil, topicsRead: 0, seconds: 0),
            document: document, summaries: summaries
        )
    }
}

@MainActor
enum NewSideRun {
    /// Runs `BrowserAgentSession` from the question's start page with the app's text registry (forum,
    /// capability and workspace tools). `modelClient` nil means the live provider (record mode).
    /// `recordedTaskID` links the recorded run's `results/<task-id>/` to this run's, so a recorded
    /// `file_read` of a saved thread finds it.
    static func run(
        _ question: ComparisonQuestion, snapshot: ForumSnapshot, ai: ComparisonAIService, modelClient: AgentModelClient?,
        models: ComparisonModels, folder: URL, recordedTaskID: String? = nil
    ) async throws -> RecordedNewSide {
        let app = try ComparisonApp.make(question, snapshot: snapshot, ai: ai, models: models, folder: folder)
        let forumName = ForumSite.displayName(siteURL: question.siteURL, name: nil)
        app.browser.setPageContext(PageContext(
            url: URL(string: question.startURL), site: question.siteKind, siteURL: question.siteURL,
            forumName: forumName, state: question.startsOnHome ? .forumHome : .topic
        ))
        let page = FixturePageDriver.SavedPage(
            url: question.startURL, title: forumName,
            structure: "Page: \(forumName)\nURL: \(question.startURL)", text: "\(forumName)\n\(question.startURL)"
        )
        let resultsRoot = app.agentWorkspace.root.appendingPathComponent(AgentWorkspace.resultsFolder, isDirectory: true)
        let store = TaskRecordStore(
            directory: folder.appendingPathComponent("Tasks", isDirectory: true), resultsRoot: resultsRoot, cookieSource: NoCookies()
        )
        let box = SessionBox()
        if let recordedTaskID, let client = modelClient as? RecordedModelClient {
            client.onRequest = { _ in
                await MainActor.run {
                    guard let current = box.session?.currentTaskID, current != recordedTaskID else { return }
                    let link = resultsRoot.appendingPathComponent(recordedTaskID)
                    try? FileManager.default.createDirectory(at: resultsRoot, withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: link.path) {
                        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: resultsRoot.appendingPathComponent(current))
                    }
                }
            }
        }
        let session = BrowserAgentSession(
            pageDriver: FixturePageDriver(page: page),
            modelClient: modelClient ?? ai,
            configProvider: { [unowned app] in app.browserAgentRuntimeConfig },
            registryBuilder: { [unowned app] bridge, limit, secrets in
                ToolRegistry.m3(context: AgentToolContext(
                    bridge: bridge, workspace: app.agentWorkspace, scriptStore: app.scriptStore, liveApplier: app.scriptWebController,
                    currentUserPrompt: { box.session?.lastUserPrompt },
                    pageBaseline: { box.session?.pageBaseline },
                    pageBaselineImage: { box.session?.pageBaselineImage },
                    settings: AgentToolSettings(
                        truncationLimit: limit, redactedSecrets: secrets,
                        supportsImageInput: app.settings.browserAgentModel?.supportsImageInput ?? false,
                        confirmBeforeWrites: app.settings.agentConfirmBeforeWrites
                    ),
                    network: app.agentHTTPClient, confirmations: app.agentConfirmations,
                    forum: app.makeForumToolContext(), capabilities: app.capabilityToolContext
                ))
            },
            taskRecords: store
        )
        box.session = session
        let started = Date()
        await session.sendAndWait(question.prompt)
        let seconds = Date().timeIntervalSince(started)
        let taskID = try XCTUnwrap(session.currentTaskID)
        let secrets = [models.agent.apiKey, models.summary.apiKey]
        let file = try TaskExport.build(
            events: await store.events(taskID: taskID), secrets: secrets, cookies: [], app: TaskExport.currentApp, now: Date()
        )
        let rows = session.toolCalls
        let reads: Set<String> = ["read_topic", "summarize_topic"]
        let topics = Set(rows.filter { reads.contains($0.toolName) && !$0.isError }.compactMap { row -> String? in
            if case .thread(let thread)? = row.shape { return thread.url }
            return row.argumentsJSON
        })
        let document = try TaskExport.load(file.data)
        return RecordedNewSide(
            side: ComparisonSide(
                calls: rows.map { ComparisonCall(tool: $0.toolName, arguments: $0.argumentSummary, result: $0.resultSummary, isError: $0.isError) },
                answer: session.runs.last?.assistantText ?? "",
                loopTokens: session.tokenUsage, summaryTokens: TokenUsageSink.covers(models.summary.selection.provider) ? ai.summaryUsage.usage : nil,
                topicsRead: topics.count, seconds: seconds
            ),
            calls: document.turns.flatMap(\.toolResults).map { ($0.name, $0.arguments) },
            document: document,
            summaries: ai.recordedSummaries
        )
    }
}

/// The header row's definition cost: the provider's count of one request with and without the tool list.
enum ToolDefinitionCost {
    static func anthropicTokens(tools: [AgentToolDefinition], models: ComparisonModels) async throws -> Int {
        func count(_ withTools: Bool) async throws -> Int {
            var body: [String: Any] = [
                "model": models.agent.selection.model, "system": "x", "messages": [["role": "user", "content": "x"]]
            ]
            if withTools {
                body["tools"] = tools.map { tool in
                    ["name": tool.name, "description": tool.description, "input_schema": JSONValue.object(tool.inputSchema).toFoundation()]
                }
            }
            var request = URLRequest(url: URL(string: "\(AIProvider.anthropic.defaultBaseURL)/messages/count_tokens")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(models.agent.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await ModelAudit.session().data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let tokens = json?["input_tokens"] as? Int else { throw AssistantError.invalidResponse }
            return tokens
        }
        return try await count(true) - count(false)
    }
}

// MARK: - Report

enum ComparisonCitations {
    /// Markdown links `[title](url)` in an answer, in order, without repeats.
    static func links(in text: String) -> [URL] {
        let pattern = try! NSRegularExpression(pattern: #"\]\((https?://[^)\s]+)\)"#)
        var seen: [URL] = []
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text), let url = URL(string: String(text[range])), !seen.contains(url) else { continue }
            seen.append(url)
        }
        return seen
    }

    /// A link-check, not a judgement: the URL is on the question's forum and names a thread the
    /// snapshot holds: its ID in a recorded URL or as an ID field of a recorded body (a list or
    /// search result), or, for a permalink with no ID (WordPress slugs), the URL in a recorded body.
    static func isThread(_ url: URL, question: ComparisonQuestion, snapshot: ForumSnapshot?) -> Bool {
        guard let snapshot, url.host?.lowercased() == URL(string: question.siteURL)?.host?.lowercased(),
              let adapter = SiteRegistry.standard.adapter(for: question.siteKind) else { return false }
        let bodies = ((try? FileManager.default.contentsOfDirectory(at: snapshot.directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        func found(_ pattern: String, in texts: [String]) -> Bool {
            let regex = try! NSRegularExpression(pattern: pattern)
            return texts.contains { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
        if let id = adapter.recognizer.topicID(fromURL: url, basePath: "") ?? adapter.recognizer.looseTopicID(in: url) {
            let escaped = NSRegularExpression.escapedPattern(for: id)
            return found("(^|[/=])\(escaped)([/.?&]|$)", in: snapshot.recordedURLs)
                || found(#""(id|topic_id|story_id|objectID|post)"\s*:\s*"?"# + escaped + #"\b"#, in: bodies)
        }
        let bare = ForumSnapshot.canonicalURLString(for: url).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return found(NSRegularExpression.escapedPattern(for: bare) + #"/?""#, in: bodies)
    }
}

enum OneLoopReport {
    static let auditLogURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Comparison/model-audit.jsonl")
    static let defaultURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/wukongmind/one-loop-comparison.md")

    static func markdown(
        header: ComparisonHeader, rows: [ComparisonRow], isSnapshotThread: (ComparisonQuestion, URL) -> Bool
    ) -> String {
        var out = ["# One loop comparison", "",
                   "Old Research and the new Agent on the confirmed question set ([one-loop-questions.md](one-loop-questions.md)), "
                   + "recorded by `OneLoopComparisonTests` ([design](design-one-loop.md#comparison-test)). "
                   + "Token counts the provider didn't report show \"n/a\".", "",
                   "| | |", "|---|---|",
                   "| Date | \(header.date) |",
                   "| Agent model (both loops) | \(header.agentModel) |",
                   "| Summary model (both sides) | \(header.summaryModel) |",
                   "| App commit | \(header.appCommit) |",
                   "| Fixture forums | \(header.forums.joined(separator: "<br>")) |",
                   "| Snapshot misses | \(rows.map { "\($0.question.id): \($0.misses.count)" }.joined(separator: ", ")) |",
                   "| Text Agent's tools on forum pages | \(header.textToolCount) tools, \(header.toolDefinitionTokens.map(String.init) ?? "n/a") tokens of definitions |",
                   "", "## Totals", "",
                   "| Kind | Side | Loop tokens in | Loop tokens out | Summary tokens in | Summary tokens out | Tool calls | Topics read | Median time |",
                   "|---|---|---|---|---|---|---|---|---|"]
        let kinds = Array(Set(rows.map(\.question.kind))).sorted()
        for (label, group) in kinds.map({ kind in (kind, rows.filter { $0.question.kind == kind }) }) + [("All", rows)] {
            for (name, sides) in [("Old Research", group.map(\.old)), ("New Agent", group.map(\.new))] {
                let loop = total(sides.map(\.loopTokens)), summary = total(sides.map(\.summaryTokens))
                out.append("| \(label) | \(name) | \(loop.in) | \(loop.out) | \(summary.in) | \(summary.out) | "
                    + "\(sides.reduce(0) { $0 + $1.calls.count }) | \(sides.reduce(0) { $0 + $1.topicsRead }) | \(median(sides.map(\.seconds))) |")
            }
        }
        out += ["", "## Questions"]
        for row in rows {
            out += ["", "### \(row.question.id)", "", "**Question:** \(row.question.prompt)", "", "**Starting page:** \(row.question.startURL)"]
            if !row.misses.isEmpty { out += ["", "**Snapshot misses:** " + row.misses.joined(separator: ", ")] }
            for (name, side) in [("Old Research", row.old), ("New Agent", row.new)] {
                out += ["", "#### \(name)", "", "**Tool calls:**", ""]
                out += side.calls.isEmpty ? ["None."] : side.calls.map {
                    "1. `\($0.tool)` \($0.arguments) → \($0.isError ? "error: " : "")\($0.result)"
                }
                out += ["", "**Answer:**", "", side.answer.isEmpty ? "(empty)" : side.answer, ""]
                let links = ComparisonCitations.links(in: side.answer)
                let checked = links.map { ($0, isSnapshotThread(row.question, $0)) }
                out.append("**Citations:** \(links.count), \(checked.filter(\.1).count) a thread in the snapshot")
                if !checked.isEmpty { out.append("") }
                out += checked.map { "- \($0.0.absoluteString): \($0.1 ? "thread in the snapshot" : "not in the snapshot")" }
                out += ["", "**Tokens:** loop \(tokens(side.loopTokens)) · summary \(tokens(side.summaryTokens))"]
            }
            out += ["", "| Owner verdict | |", "|---|---|", "| New better, same, or worse | |", "| Note | |"]
        }
        out += ["", "## Approval", "", "Approved by the owner on YYYY-MM-DD: yes / no", ""]
        return out.joined(separator: "\n")
    }

    private static func tokens(_ usage: AgentTokenUsage?) -> String {
        usage.map { "\($0.inputTokens) in / \($0.outputTokens) out" } ?? "n/a"
    }

    private static func total(_ usages: [AgentTokenUsage?]) -> (in: String, out: String) {
        guard !usages.contains(where: { $0 == nil }) else { return ("n/a", "n/a") }
        let sum = usages.compactMap { $0 }
        return (String(sum.reduce(0) { $0 + $1.inputTokens }), String(sum.reduce(0) { $0 + $1.outputTokens }))
    }

    private static func median(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n/a" }
        let sorted = values.sorted(), mid = sorted.count / 2
        let value = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return String(format: "%.1f s", value)
    }
}
