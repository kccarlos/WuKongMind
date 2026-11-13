import Foundation
import XCTest
#if canImport(WukongMind)
@testable import WukongMind
#endif

/// The audit log and task records on disk (M3 task 6). Fake clocks and fake cookie sources only.
final class AuditLogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    private func row(
        _ tool: String, step: Int = 1, args: String = "{}", summary: String = "ok", error: Bool = false
    ) -> BrowserAgentToolCallRow {
        BrowserAgentToolCallRow(
            callID: "c\(step)", runID: UUID(), stepNumber: step, toolName: tool,
            argumentSummary: "", argumentsJSON: args, resultSummary: summary, resultText: summary,
            duration: 0.25, isRunning: false, isError: error
        )
    }

    // MARK: - Audit lines

    func testStepLineHoldsFieldsAndFullHTTPRequestURL() {
        let log = AuditLog(directory: root.appendingPathComponent("a"))
        let longURL = "https://forum.example/t/123?" + String(repeating: "q=1&", count: 1_500)
        let args = #"{"method":"post","url":"\#(longURL)"}"#
        let line = AuditLine.step(
            row: row("http_request", step: 3, args: args, summary: String(repeating: "r", count: 900)),
            taskID: "T1", time: date("2026-11-13T10:00:00Z"), pageURL: "https://forum.example/t/1",
            warning: "Page may be broken", savedPath: "results/T1/03-http_request.txt"
        )
        log.append(line)
        let read = log.allLines()
        XCTAssertEqual(read.count, 1)
        let stored = read[0]
        XCTAssertEqual(stored.taskID, "T1")
        XCTAssertEqual(stored.step, 3)
        XCTAssertEqual(stored.tool, "http_request")
        XCTAssertEqual(stored.durationMs, 250)
        XCTAssertEqual(stored.arguments?.count, AuditLine.maxArgumentCharacters)
        XCTAssertEqual(stored.resultSummary?.count, AuditLine.maxSummaryCharacters)
        XCTAssertEqual(stored.url, longURL, "http_request lines hold the full URL")
        XCTAssertEqual(stored.method, "POST")
        XCTAssertEqual(stored.savedPath, "results/T1/03-http_request.txt")
        XCTAssertEqual(stored.warning, "Page may be broken")
        XCTAssertEqual(stored.pageURL, "https://forum.example/t/1")
        XCTAssertEqual(stored.truncated, true)
    }

    func testStepArgumentsAreRedacted() {
        let line = AuditLine.step(
            row: row("run_js", args: #"{"code":"fetch('x', {key: 'sk-secret-123456'})"}"#),
            taskID: "T", time: Date(), pageURL: nil, secrets: ["sk-secret-123456"]
        )
        XCTAssertFalse(line.arguments?.contains("sk-secret-123456") ?? true)
    }

    func testSurvivesReopeningTheStore() {
        let dir = root.appendingPathComponent("reopen")
        let first = AuditLog(directory: dir)
        first.append(.taskStart(taskID: "T", time: date("2026-11-13T09:00:00Z"), prompt: "Hello", model: "m", provider: "p", pageURL: nil))
        first.append(.step(row: row("read_page"), taskID: "T", time: date("2026-11-13T09:00:01Z"), pageURL: nil))
        let second = AuditLog(directory: dir)
        XCTAssertEqual(second.allLines().map(\.kind), [.task, .step])
        XCTAssertEqual(second.stepCount, 1)
    }

    func testPageGroupsByDayThenTask() {
        let log = AuditLog(directory: root.appendingPathComponent("group"))
        for (id, time) in [("A", "2026-11-12T08:00:00Z"), ("B", "2026-11-13T08:00:00Z"), ("C", "2026-11-13T09:00:00Z")] {
            log.append(.taskStart(taskID: id, time: date(time), prompt: "Task \(id)", model: nil, provider: nil, pageURL: "https://x.example/"))
            log.append(.step(row: row("read_page"), taskID: id, time: date(time).addingTimeInterval(5), pageURL: nil))
            log.append(.taskEnd(taskID: id, time: date(time).addingTimeInterval(9), outcome: "completed", steps: 1, tokens: 10, duration: 9))
        }
        let days = log.days()
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].tasks.map(\.id), ["C", "B"], "newest day and task first")
        XCTAssertEqual(days[1].tasks.map(\.id), ["A"])
        XCTAssertEqual(days[0].tasks[0].steps.count, 1)
        XCTAssertEqual(days[0].tasks[0].host, "x.example")
        XCTAssertEqual(days[0].tasks[0].outcome, "completed")
    }

    func testRetentionByAgeWithFakeClock() {
        let clock = Clock(date("2026-11-13T12:00:00Z"))
        let log = AuditLog(directory: root.appendingPathComponent("age"), now: { clock.now })
        for day in ["2026-09-01", "2026-10-10", "2026-10-20", "2026-11-13"] {
            log.append(.taskStart(taskID: day, time: date("\(day)T12:00:00Z"), prompt: day, model: nil, provider: nil, pageURL: nil))
        }
        log.prune()
        XCTAssertEqual(Set(log.allLines().map(\.taskID)), ["2026-10-20", "2026-11-13"], "30 days back from the fake now")
        clock.now = date("2026-12-30T12:00:00Z")
        log.prune()
        XCTAssertTrue(log.allLines().isEmpty)
    }

    func testRetentionBySize() {
        let clock = Clock(date("2026-11-13T12:00:00Z"))
        let log = AuditLog(directory: root.appendingPathComponent("size"), now: { clock.now }, maxBytes: 1_000)
        for day in ["2026-11-10", "2026-11-11", "2026-11-12"] {
            log.append(.taskStart(taskID: day, time: date("\(day)T12:00:00Z"), prompt: String(repeating: "p", count: 400), model: nil, provider: nil, pageURL: nil))
        }
        log.prune()
        XCTAssertLessThan(log.allLines().count, 3)
        XCTAssertTrue(log.allLines().contains { $0.taskID == "2026-11-12" }, "the newest day stays")
    }

    func testClearRemovesEverything() {
        let log = AuditLog(directory: root.appendingPathComponent("clear"))
        log.append(.taskStart(taskID: "T", time: Date(), prompt: "x", model: nil, provider: nil, pageURL: nil))
        log.clear()
        XCTAssertTrue(log.allLines().isEmpty)
    }

    // MARK: - Task records

    private func makeStore(
        _ name: String, cookies: [[KnownCookie]?] = [], maxTasks: Int = 50, maxBytes: Int = 200_000_000
    ) -> (TaskRecordStore, URL) {
        let results = root.appendingPathComponent("results-\(name)")
        let store = TaskRecordStore(
            directory: root.appendingPathComponent("tasks-\(name)"), resultsRoot: results,
            cookieSource: FakeCookies(cookies), maxTasks: maxTasks, maxBytes: maxBytes
        )
        return (store, results)
    }

    private func recordText(_ store: TaskRecordStore, _ id: String) -> String {
        (try? String(contentsOf: store.directory.appendingPathComponent("\(id).jsonl"), encoding: .utf8)) ?? ""
    }

    func testRecordRetentionDeletesResultsFolders() async throws {
        let (store, results) = makeStore("ret", maxTasks: 2)
        let fm = FileManager.default
        for (index, id) in ["old", "mid", "new"].enumerated() {
            await store.append(taskID: id, .user("hi", time: Date()))
            let folder = results.appendingPathComponent(id)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try "saved".write(to: folder.appendingPathComponent("01-read_page.txt"), atomically: true, encoding: .utf8)
            try fm.setAttributes(
                [.modificationDate: date("2026-11-1\(index)T00:00:00Z")],
                ofItemAtPath: store.directory.appendingPathComponent("\(id).jsonl").path
            )
        }
        await store.prune()
        let ids = await store.taskIDs()
        XCTAssertEqual(Set(ids), ["mid", "new"])
        XCTAssertFalse(fm.fileExists(atPath: results.appendingPathComponent("old").path), "pruning a record deletes its results folder")
        XCTAssertTrue(fm.fileExists(atPath: results.appendingPathComponent("new").path))
    }

    func testRecordRetentionBySize() async throws {
        let (store, results) = makeStore("bytes", maxBytes: 600)
        for (index, id) in ["a", "b", "c"].enumerated() {
            await store.append(taskID: id, .user(String(repeating: "x", count: 300), time: Date()))
            try FileManager.default.createDirectory(at: results.appendingPathComponent(id), withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.modificationDate: date("2026-11-1\(index)T00:00:00Z")],
                ofItemAtPath: store.directory.appendingPathComponent("\(id).jsonl").path
            )
        }
        await store.prune()
        let ids = await store.taskIDs()
        XCTAssertEqual(ids, ["c"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: results.appendingPathComponent("a").path))
    }

    func testRecordsSurviveReopeningTheStore() async {
        let (store, _) = makeStore("reopen")
        await store.append(taskID: "T", .user("Find posts", time: date("2026-11-13T10:00:00Z")))
        let reopened = TaskRecordStore(directory: store.directory)
        let events = await reopened.events(taskID: "T")
        XCTAssertEqual(events.map(\.type), ["user"])
        let turns = await reopened.turns(taskID: "T")
        XCTAssertEqual(turns, [.user("Find posts")])
    }

    func testCookieValuesAreScrubbedIncludingRotationAndShortValues() async {
        let seed = KnownCookie(name: "session", value: "s3cr3t-session-value")
        let rotated = KnownCookie(name: "session", value: "rotated-session-VALUE-2")
        let theme = KnownCookie(name: "theme", value: "dark")
        let (store, _) = makeStore("scrub", cookies: [[seed, theme], [rotated, theme]])
        await store.touch(taskID: "T", url: "https://forum.example/t/1")

        // First read sees the seeded value, the second the rotated one.
        await store.append(taskID: "T", TaskRecordEvent(type: "tool_result", time: Date(), fields: [
            "output": .string("document.cookie = theme=dark; session=s3cr3t-session-value; lang=en"),
            "note": .string("the page is dark and uses s3cr3t-session-value"),
            "name": .string("cookies_get")
        ]))
        await store.append(taskID: "T", TaskRecordEvent(type: "tool_result", time: Date(), fields: [
            "output": .string(#"[{"name":"session","value":"rotated-session-VALUE-2"},{"name":"theme","value":"dark"}]"#),
            "old": .string("s3cr3t-session-value"),
            "headers": .object(["Cookie": .string("theme=dark"), "Accept": .string("*/*")])
        ]))
        await store.append(taskID: "T", TaskRecordEvent(type: "raw_response", time: Date(), fields: [
            "body": .string(#"{"echo":"rotated-session-VALUE-2"}"#)
        ]))

        let text = recordText(store, "T")
        XCTAssertFalse(text.contains("s3cr3t-session-value"), "seeded long value")
        XCTAssertFalse(text.contains("rotated-session-VALUE-2"), "rotated long value")
        XCTAssertTrue(text.contains("theme=[cookie]"), "short value in document.cookie output is cleared")
        XCTAssertFalse(text.contains("theme=dark"))
        XCTAssertTrue(text.contains("the page is dark"), "a bare short value elsewhere stays")
        XCTAssertFalse(text.contains("\"Cookie\""), "Cookie headers are dropped")
        XCTAssertTrue(text.contains("Accept"))
        XCTAssertFalse(text.contains("cookies_scrubbed"))
    }

    func testUnreadableCookieStoreMarksTheLine() async {
        let (store, _) = makeStore("unreadable", cookies: [nil])
        await store.touch(taskID: "T", url: "https://forum.example/")
        await store.append(taskID: "T", .user("hi", time: Date()))
        XCTAssertTrue(recordText(store, "T").contains("\"cookies_scrubbed\":false"))
    }

    func testToolDefinitionEncodesAsNameDescriptionAndSchema() throws {
        let definition = AgentToolDefinition(
            name: "file_read", description: "Reads a file",
            parameters: [
                ToolParameterSchema(name: "path", type: .string, description: "Where", minLength: 1),
                ToolParameterSchema(name: "offset", type: .integer, description: "From", minimum: 0, maximum: 1_000)
            ],
            required: ["path"]
        )
        let data = try JSONEncoder().encode(definition)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["name", "description", "inputSchema"])
        let decoded = try JSONDecoder().decode(AgentToolDefinition.self, from: data)
        XCTAssertEqual(decoded.inputSchema, definition.inputSchema)
        XCTAssertEqual(decoded.required, ["path"])
    }

    func testRecordReadsBackIntoTheSameTurns() async throws {
        let (store, _) = makeStore("turns")
        let echo = AgentTool(
            definition: AgentToolDefinition(name: "echo", description: "Echo", parameters: [
                ToolParameterSchema(name: "text", type: .string, description: "Text")
            ], required: ["text"]),
            customValidate: nil,
            summarizeArguments: { _ in "" },
            execute: { args in ToolExecutionOutput(content: "echo: \(args["text"]?.stringValue ?? "")") }
        )
        let registry = ToolRegistry(tools: [echo])
        let client = ScriptedClient([
            AgentModelTurnResponse(text: "Checking.", toolCalls: [
                AgentModelToolCall(id: "c1", name: "echo", arguments: ["text": .string("one")]),
                AgentModelToolCall(id: "c2", name: "missing_tool", arguments: [:])
            ], usage: AgentTokenUsage(inputTokens: 5, outputTokens: 2)),
            AgentModelTurnResponse(text: "Done.")
        ])
        let loop = AgentLoop(modelClient: client, registry: registry, maxSteps: 5)
        var events = AgentLoopEvents()
        events.onModelResponse = { _, response in
            await store.append(taskID: "T", .response(response, model: "m", provider: "p", time: Date()))
        }
        events.onToolResult = { call, row, _ in
            await store.append(taskID: "T", .toolResult(
                call: call, output: row.resultText, isError: row.isError, duration: row.duration,
                wasTruncated: row.wasTruncated, totalCharacterCount: row.totalCharacterCount,
                savedPath: nil, resultSummary: row.resultSummary, time: Date()
            ))
        }
        await store.append(taskID: "T", .user("Say hi", time: Date()))
        let result = try await loop.run(
            systemPrompt: "sys", initialHistory: [.user("Say hi")],
            configuration: ProviderConfiguration(model: "m", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake"), provider: .anthropic, events: events
        )
        let rebuilt = await store.turns(taskID: "T")
        XCTAssertEqual(rebuilt, result.history)
    }
}

// MARK: - Fakes

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// Returns the next scripted list on each read; the last one repeats. `nil` entries mean unreadable.
private final class FakeCookies: TaskCookieSource, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [[KnownCookie]?]

    init(_ reads: [[KnownCookie]?]) { self.reads = reads }

    func cookies(forHosts hosts: Set<String>) async -> [KnownCookie]? {
        lock.withLock {
            if reads.isEmpty { return [] }
            return reads.count > 1 ? reads.removeFirst() : reads[0]
        }
    }
}

private final class ScriptedClient: AgentModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [AgentModelTurnResponse]

    init(_ responses: [AgentModelTurnResponse]) { self.responses = responses }

    func completeToolTurn(
        system: String, messages: [AgentModelTurn], tools: [AgentToolDefinition],
        configuration: ProviderConfiguration, provider: AIProvider, maxTokens: Int
    ) async throws -> AgentModelTurnResponse {
        lock.withLock { responses.isEmpty ? AgentModelTurnResponse(text: "") : responses.removeFirst() }
    }
}
