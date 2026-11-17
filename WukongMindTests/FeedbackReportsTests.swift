import Foundation
import XCTest
#if canImport(WukongMind)
@testable import WukongMind
#endif

/// Feedback reports (docs/wukongmind/feedback.md): names, pruning to 50, the local fallback and the
/// "failed task saves" trigger.
@MainActor
final class FeedbackReportsTests: XCTestCase {
    /// 2025-11-17 09:30:12 UTC.
    private let date = Date(timeIntervalSince1970: 1_763_371_812)

    // MARK: Names

    func testFileNameIsUTCTimeThenHost() {
        XCTAssertEqual(
            FeedbackReportStore.filename(date: date, host: "News.Example.org"),
            "20251117T093012Z-news.example.org-task.json"
        )
        XCTAssertEqual(FeedbackReportStore.filename(date: date, host: nil), "20251117T093012Z-no-page-task.json")
        XCTAssertEqual(FeedbackReportStore.filename(date: date, host: ""), "20251117T093012Z-no-page-task.json")
        XCTAssertEqual(FeedbackReportStore.filename(date: date, host: "a/b:c d"), "20251117T093012Z-a-b-c-d-task.json")
        XCTAssertEqual(FeedbackReportStore.filename(date: date, host: "x.com", attempt: 2), "20251117T093012Z-x.com-task-2.json")
    }

    func testReportNamesIncludeICloudPlaceholdersAndNothingElse() {
        XCTAssertEqual(FeedbackReportStore.reportName("20251117T093012Z-x.com-task.json"), "20251117T093012Z-x.com-task.json")
        XCTAssertEqual(FeedbackReportStore.reportName(".20251117T093012Z-x.com-task.json.icloud"), "20251117T093012Z-x.com-task.json")
        XCTAssertEqual(FeedbackReportStore.reportName("20251117T093012Z-x.com-task-3.json"), "20251117T093012Z-x.com-task-3.json")
        XCTAssertNil(FeedbackReportStore.reportName("notes.json"))
        XCTAssertNil(FeedbackReportStore.reportName("wukong-task-2025-11-17-read.json"))
        XCTAssertNil(FeedbackReportStore.reportName(".DS_Store"))
    }

    // MARK: Pruning

    func testSavingKeepsTheNewestFiftyAndLeavesOtherFiles() throws {
        let documents = try temporaryDirectory()
        let store = FeedbackReportStore(ubiquityContainer: { nil }, localDocuments: documents)
        let folder = documents.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("notes.json"))
        for minute in 0..<55 {
            let name = FeedbackReportStore.filename(date: date.addingTimeInterval(Double(minute) * 60), host: "x.com")
            try Data("{}".utf8).write(to: folder.appendingPathComponent(name))
        }

        let newest = date.addingTimeInterval(3_600)
        let saved = try store.save(data: Data("{}".utf8), date: newest, host: "x.com")

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let reports = names.compactMap(FeedbackReportStore.reportName).sorted()
        XCTAssertEqual(reports.count, FeedbackReportStore.maxReports)
        XCTAssertEqual(reports.last, saved.url.lastPathComponent)
        // 56 reports, 50 kept: the six oldest (minutes 0-5) went.
        XCTAssertEqual(reports.first, FeedbackReportStore.filename(date: date.addingTimeInterval(6 * 60), host: "x.com"))
        XCTAssertTrue(names.contains("notes.json"), "files that aren't reports stay")
    }

    func testPruningByTotalSizeAlwaysKeepsTheNewest() throws {
        let folder = try temporaryDirectory()
        let store = FeedbackReportStore(ubiquityContainer: { nil }, localDocuments: folder)
        for minute in 0..<3 {
            let name = FeedbackReportStore.filename(date: date.addingTimeInterval(Double(minute) * 60), host: "x.com")
            try Data(repeating: 0x20, count: 100).write(to: folder.appendingPathComponent(name))
        }
        store.prune(folder: folder, keep: 50, maxBytes: 150)
        let reports = try FileManager.default.contentsOfDirectory(atPath: folder.path).compactMap(FeedbackReportStore.reportName)
        XCTAssertEqual(reports, [FeedbackReportStore.filename(date: date.addingTimeInterval(120), host: "x.com")])

        store.prune(folder: folder, keep: 50, maxBytes: 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1, "the newest is never pruned")
    }

    func testTwoReportsInTheSameSecondBothStay() throws {
        let store = FeedbackReportStore(ubiquityContainer: { nil }, localDocuments: try temporaryDirectory())
        let first = try store.save(data: Data("1".utf8), date: date, host: "x.com")
        let second = try store.save(data: Data("2".utf8), date: date, host: "x.com")
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(second.url.lastPathComponent, "20251117T093012Z-x.com-task-2.json")
        XCTAssertEqual(try Data(contentsOf: first.url), Data("1".utf8))
    }

    // MARK: Where reports go

    func testWithICloudReportsGoToTheContainersDocumentsReports() throws {
        let container = try temporaryDirectory()
        let store = FeedbackReportStore(ubiquityContainer: { container }, localDocuments: try temporaryDirectory())
        let saved = try store.save(data: Data("{}".utf8), date: date, host: "x.com")
        XCTAssertEqual(saved.location, .iCloud)
        XCTAssertEqual(saved.url.deletingLastPathComponent().standardizedFileURL,
                       container.appendingPathComponent("Documents/Reports").standardizedFileURL)
    }

    func testWithoutICloudReportsFallBackToLocalDocuments() throws {
        let documents = try temporaryDirectory()
        let store = FeedbackReportStore(ubiquityContainer: { nil }, localDocuments: documents)
        let saved = try store.save(data: Data("{}".utf8), date: date, host: "x.com")
        XCTAssertEqual(saved.location, .local)
        XCTAssertEqual(saved.url.deletingLastPathComponent().standardizedFileURL,
                       documents.appendingPathComponent("Reports").standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.url.path))
    }

    func testAnUnwritableContainerFallsBackToLocalDocuments() throws {
        // A file where the container's folder should be: the iCloud write fails.
        let blocker = try temporaryDirectory().appendingPathComponent("not-a-folder")
        try Data().write(to: blocker)
        let documents = try temporaryDirectory()
        let store = FeedbackReportStore(ubiquityContainer: { blocker }, localDocuments: documents)
        let saved = try store.save(data: Data("{}".utf8), date: date, host: "x.com")
        XCTAssertEqual(saved.location, .local)
        XCTAssertTrue(saved.url.path.hasPrefix(documents.appendingPathComponent("Reports").path))
    }

    func testToastSaysWhenTheReportStayedOnTheDevice() {
        XCTAssertEqual(AppModel.feedbackToastMessage(.iCloud), "Saved for feedback. Send a TestFlight screenshot if you like.")
        XCTAssertTrue(AppModel.feedbackToastMessage(.local).contains("iCloud isn't available"))
        XCTAssertTrue(AppModel.feedbackToastMessage(.local).contains("Files › WukongMind › Reports"))
    }

    // MARK: The trigger and the setting

    func testOnlyRunsThatEndInAnErrorSaveThemselves() {
        XCTAssertTrue(FeedbackReportStore.savesAutomatically(after: .failed(message: "HTTP 500"), enabled: true))
        XCTAssertTrue(FeedbackReportStore.savesAutomatically(after: .stepLimitReached(limit: 5), enabled: true))
        XCTAssertFalse(FeedbackReportStore.savesAutomatically(after: .completed(steps: 1, duration: 1), enabled: true))
        XCTAssertFalse(FeedbackReportStore.savesAutomatically(after: .stopped(step: 1), enabled: true))
        XCTAssertFalse(FeedbackReportStore.savesAutomatically(after: .idle, enabled: true))
        XCTAssertFalse(FeedbackReportStore.savesAutomatically(after: .failed(message: "x"), enabled: false))
    }

    func testTheSettingFollowsTheBuildUntilChangedAndStaysOnTheDevice() throws {
        var settings = AppSettings()
        XCTAssertTrue(settings.savesFailedTasksForFeedback(isTestFlight: true))
        XCTAssertFalse(settings.savesFailedTasksForFeedback(isTestFlight: false))
        settings.saveFailedTasksForFeedback = false
        XCTAssertFalse(settings.savesFailedTasksForFeedback(isTestFlight: true))

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.saveFailedTasksForFeedback, false)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertNil(old.saveFailedTasksForFeedback, "older settings follow the build")
        XCTAssertTrue(SyncSettings.deviceLocalKeys.contains("saveFailedTasksForFeedback"))
    }

    func testAStepLimitedRunSavesARedactedReportAndACompletedOneDoesNot() async throws {
        let records = TaskRecordStore(directory: try temporaryDirectory(), cookieSource: NoCookies())
        let client = LoopingClient()
        let session = makeSession(client: client, records: records)
        var ended: [(String, BrowserAgentRunState)] = []
        session.onRunEndedWithError = { ended.append(($0, $1)) }

        await session.sendAndWait("Keep reading the page")
        guard case .stepLimitReached = session.runState else { return XCTFail("\(session.runState)") }
        XCTAssertEqual(ended.count, 1)
        let taskID = try XCTUnwrap(ended.first?.0)
        XCTAssertEqual(taskID, session.currentTaskID)

        let file = try await TaskExport.file(taskID: taskID, store: records, cookieSource: NoCookies(), secrets: [Self.key])
        let documents = try temporaryDirectory()
        let saved = try FeedbackReportStore(ubiquityContainer: { nil }, localDocuments: documents)
            .save(data: file.data, host: file.host)
        XCTAssertTrue(saved.url.lastPathComponent.hasSuffix("-news.example.org-task.json"))
        let text = try String(contentsOf: saved.url, encoding: .utf8)
        XCTAssertFalse(text.contains(Self.key), "no API key in a report")
        XCTAssertEqual(try TaskExport.load(Data(text.utf8)).stepLimit, 1)

        await client.finishNext()
        await session.sendAndWait("Now just answer")
        guard case .completed = session.runState else { return XCTFail("\(session.runState)") }
        XCTAssertEqual(ended.count, 1, "a completed run doesn't save")
    }

    func testAFailedRunSavesItself() async throws {
        let records = TaskRecordStore(directory: try temporaryDirectory(), cookieSource: NoCookies())
        let session = makeSession(client: FailingClient(), records: records)
        var ended: [(String, BrowserAgentRunState)] = []
        session.onRunEndedWithError = { ended.append(($0, $1)) }
        await session.sendAndWait("Read the page")
        guard case .failed = session.runState else { return XCTFail("\(session.runState)") }
        XCTAssertEqual(ended.count, 1)

        // The record has a request and no response: it still exports and saves.
        let taskID = try XCTUnwrap(ended.first?.0)
        let file = try await TaskExport.file(taskID: taskID, store: records, cookieSource: NoCookies(), secrets: [Self.key])
        let saved = try FeedbackReportStore(ubiquityContainer: { nil }, localDocuments: try temporaryDirectory())
            .save(data: file.data, host: file.host)
        XCTAssertEqual(saved.location, .local)
        let document = try TaskExport.load(try Data(contentsOf: saved.url))
        XCTAssertEqual(document.turns.count, 1)
        XCTAssertNil(document.turns.first?.response)
    }

    // MARK: Helpers

    nonisolated static let key = "sk-ant-api03-FEEDBACKKEY-0123456789"

    private func makeSession(client: AgentModelClient, records: TaskRecordStore) -> BrowserAgentSession {
        BrowserAgentSession(
            pageDriver: FeedbackPageStub(),
            modelClient: client,
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .anthropic, model: "claude-sonnet-5-5"),
                    configuration: ProviderConfiguration(
                        model: "claude-sonnet-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: Self.key
                    ),
                    maxSteps: 1, truncationLimit: 20_000, customInstructions: "", redactedSecrets: [Self.key]
                )
            },
            taskRecords: records
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

// MARK: - Fakes

private struct NoCookies: TaskCookieSource {
    func cookies(forHosts hosts: Set<String>) async -> [KnownCookie]? { [] }
}

/// Calls `read_page` every turn (so a one-step run hits the step limit), until told to answer.
private actor LoopingClient: AgentModelClient {
    private var answersNext = false
    private var calls = 0

    func finishNext() { answersNext = true }

    func completeToolTurn(
        system: String, messages: [AgentModelTurn], tools: [AgentToolDefinition],
        configuration: ProviderConfiguration, provider: AIProvider, maxTokens: Int
    ) async throws -> AgentModelTurnResponse {
        if answersNext { return AgentModelTurnResponse(text: "Done.") }
        calls += 1
        return AgentModelTurnResponse(
            text: "", toolCalls: [AgentModelToolCall(id: "call_\(calls)", name: "read_page", arguments: ["mode": .string("text")])]
        )
    }
}

private struct FailingClient: AgentModelClient {
    struct Failure: LocalizedError { var errorDescription: String? { "HTTP 500" } }
    func completeToolTurn(
        system: String, messages: [AgentModelTurn], tools: [AgentToolDefinition],
        configuration: ProviderConfiguration, provider: AIProvider, maxTokens: Int
    ) async throws -> AgentModelTurnResponse {
        throw Failure()
    }
}

private final class FeedbackPageStub: AgentPageDriving, @unchecked Sendable {
    func currentPageMetadata() async -> AgentPageMetadata {
        AgentPageMetadata(url: "https://news.example.org/story", title: "Example Story")
    }
    func readPage(mode: PageReadMode, selector: String?, maxLength: Int?) async throws -> String { "Page: Example Story" }
    func runJS(code: String, environment: AgentExecutionEnvironment, timeout: TimeInterval) async throws -> JSExecutionResult {
        JSExecutionResult(valueJSON: "null", consoleOutput: [], error: nil)
    }
    func injectCSS(css: String, id: String?) async throws -> CSSInjectionResult {
        CSSInjectionResult(sheetID: id ?? "s", appliedRootCount: 1)
    }
    func waitFor(selector: String?, milliseconds: Int?) async throws -> WaitForResult {
        WaitForResult(mode: .delay, matched: true, elapsedMs: 1, selector: selector)
    }
}
