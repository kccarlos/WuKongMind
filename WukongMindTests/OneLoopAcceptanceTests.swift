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
}
