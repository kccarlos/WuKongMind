import Foundation
import XCTest
#if canImport(WukongMind)
@testable import WukongMind
#endif

/// Task export (design-m3.md "Task export"): no keys, no cookies, refusals, and replay.
@MainActor
final class TaskExportTests: XCTestCase {
    nonisolated static let anthropicKey = "sk-ant-api03-TESTKEY-0123456789"
    nonisolated static let geminiKey = "AIzaSyTESTKEY0123456789abcdef"
    nonisolated static let sessionCookie = "s3cr3t-session-value-42"
    nonisolated static let cookies = [KnownCookie(name: "sid", value: sessionCookie), KnownCookie(name: "lang", value: "en")]
    nonisolated static let pageText = "Page: Example Story\n[h1] Breaking News\nsid=\(sessionCookie); lang=en"

    // MARK: Raw capture

    func testGeminiKeyNeverReachesTheRecorder() async throws {
        StubHTTP.reset([#"{"candidates":[{"content":{"parts":[{"text":"Echo \#(Self.geminiKey)"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":2}}"#])
        let collector = WireCollector()
        let response = try await StubHTTP.service.completeToolTurn(
            system: "sys", messages: [.user("hi")], tools: [],
            configuration: ProviderConfiguration(model: "gemini-2.5-flash", baseURL: AIProvider.gemini.defaultBaseURL, apiKey: Self.geminiKey),
            provider: .gemini, maxTokens: 64, recorder: collector
        )
        XCTAssertTrue(response.text.hasPrefix("Echo"))
        XCTAssertTrue(StubHTTP.seen.first?.url?.query?.contains("key=") == true, "the real request carries the key")
        let exchange = try XCTUnwrap(collector.exchanges.first)
        XCTAssertFalse(exchange.url.contains(Self.geminiKey))
        XCTAssertFalse(exchange.url.contains("key="))
        XCTAssertFalse(exchange.requestBody.contains(Self.geminiKey))
        XCTAssertFalse(exchange.responseBody.contains(Self.geminiKey))
        XCTAssertEqual(exchange.method, "POST")
        XCTAssertEqual(exchange.status, 200)
    }

    // MARK: Export of a real session

    func testRecordedSessionExportsWithoutKeysOrCookiesAndReplays() async throws {
        let (store, data, url) = try await exportRecordedSession()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("wukong-task-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-read-the-page-and-tell-me.json"))
        XCTAssertFalse(text.contains(Self.anthropicKey), "no API key")
        XCTAssertFalse(text.contains(Self.sessionCookie), "no seeded long cookie value")
        XCTAssertFalse(text.contains("lang=en"), "no short cookie pair")
        XCTAssertTrue(text.contains("sid=[cookie]"))

        let document = try TaskExport.load(data)
        XCTAssertEqual(document.provider, "Anthropic")
        XCTAssertEqual(document.stepLimit, 5)
        XCTAssertEqual(document.startPageURL, "https://news.example.org/story")
        XCTAssertEqual(document.turns.count, 3)
        XCTAssertEqual(document.turns.map(\.turn), [1, 2, 3])
        XCTAssertTrue(document.turns.allSatisfy { $0.rawRequest != nil && $0.rawResponse?.status == 200 })
        for turn in document.turns {
            let body = Data((turn.rawRequest?.body ?? "").utf8)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: body), "turn \(turn.turn) raw request stays valid JSON")
        }
        XCTAssertEqual(document.systems.count, 1)
        XCTAssertEqual(document.toolSets.count, 1)
        XCTAssertEqual(document.turns[1].pageURL, "https://news.example.org/story")

        try await assertReplays(document, tools: ["read_page", "run_js"])

        // Past the size limit the middle turns' raw requests go; the responses stay.
        let taskIDs = await store.taskIDs()
        let events = await store.events(taskID: try XCTUnwrap(taskIDs.first))
        let small = try TaskExport.build(
            events: events, secrets: [Self.anthropicKey], cookies: Self.cookies,
            app: .init(version: "1", build: "1"), now: Date(), maxBytes: 1
        )
        let trimmed = try TaskExport.load(small.data)
        XCTAssertEqual(trimmed.omittedRawRequests, [2])
        XCTAssertNotNil(trimmed.turns[0].rawRequest)
        XCTAssertNil(trimmed.turns[1].rawRequest)
        XCTAssertNotNil(trimmed.turns[2].rawRequest)
        XCTAssertTrue(trimmed.turns.allSatisfy { $0.rawResponse != nil })
    }

    func testFixtureReplaysThroughRecordedModelClient() async throws {
        let data = try fixture("read-headline")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(Self.anthropicKey))
        XCTAssertFalse(text.contains(Self.sessionCookie))
        let document = try TaskExport.load(data)
        try await assertReplays(document, tools: ["read_page", "run_js"])
    }

    // MARK: Refusals

    func testRecordWithAnUnscrubbedLineIsRefused() {
        let events = [
            TaskRecordEvent(type: "history", time: Date(), fields: ["turns": .array([])]),
            TaskRecordEvent(type: "response", time: Date(), fields: ["cookies_scrubbed": .bool(false)])
        ]
        XCTAssertThrowsError(try TaskExport.build(
            events: events, secrets: [], cookies: [], app: .init(version: "1", build: "1"), now: Date()
        )) { XCTAssertEqual($0 as? TaskExportError, .cookiesRemain) }
    }

    func testSurvivingCookieValuesAreFound() {
        XCTAssertTrue(TaskExport.containsCookie("x \(Self.sessionCookie) y", cookies: Self.cookies))
        XCTAssertTrue(TaskExport.containsCookie("a=1; lang=en; b=2", cookies: Self.cookies))
        XCTAssertTrue(TaskExport.containsCookie(#"{"text":"lang=en\n"}"#, cookies: Self.cookies), "before a JSON escape")
        XCTAssertFalse(TaskExport.containsCookie("language=english, lang=[cookie]", cookies: Self.cookies))
    }

    func testUnreadableCookieStoreRefusesTheExport() async throws {
        let directory = try temporaryDirectory()
        let store = TaskRecordStore(directory: directory)
        await store.touch(taskID: "T", url: "https://news.example.org/")
        await store.append(taskID: "T", .history([.user("hi")], time: Date()))
        do {
            _ = try await TaskExport.export(taskID: "T", store: store, cookieSource: FixedCookies(nil), secrets: [])
            XCTFail("export must be refused")
        } catch {
            XCTAssertEqual(error as? TaskExportError, .cookiesRemain)
        }
    }

    // MARK: The one switch

    func testOldDeveloperModeKeyTurnsOnTheSwitchAndIsDropped() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"developerMode":true}"#.utf8))
        XCTAssertTrue(decoded.agentDeveloperMode)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(encoded.contains("\"developerMode\""))
        XCTAssertTrue(encoded.contains("\"agentDeveloperMode\":true"))
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).agentDeveloperMode)
    }

    // MARK: Helpers

    private func assertReplays(_ document: TaskExportDocument, tools: [String]) async throws {
        let dispatcher = ReplayToolDispatcher(document)
        let loop = AgentLoop(
            modelClient: RecordedModelClient(export: document), registry: dispatcher,
            maxSteps: document.stepLimit ?? BrowserAgentLimits.defaultMaxSteps
        )
        let first = try XCTUnwrap(document.turns.first)
        let result = try await loop.run(
            systemPrompt: document.systems[first.systemHash] ?? "", initialHistory: document.startHistory,
            configuration: ProviderConfiguration(model: document.model ?? "", baseURL: "", apiKey: ""),
            provider: .anthropic
        )
        XCTAssertEqual(dispatcher.mismatches, [])
        XCTAssertEqual(result.history.count, document.history.count)
        for (index, (built, recorded)) in zip(result.history, document.history).enumerated() {
            XCTAssertEqual(built, recorded, "history turn \(index)")
        }
        XCTAssertEqual(result.toolRows.map(\.toolName), tools)
        XCTAssertEqual(document.turns.flatMap(\.toolResults).map(\.name), tools)
        guard case .completed(let text, let steps, _) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(text, document.turns.last?.response?.text)
        XCTAssertEqual(steps, tools.count)
    }

    /// Runs a real session (AIService over stubbed HTTP, a recording store with seeded cookies)
    /// and exports it. With `TEST_RUNNER_TASK_EXPORT_FIXTURE_OUT` set, the file is also written there
    /// (how `Fixtures/TaskExports/read-headline.json` was made).
    private func exportRecordedSession() async throws -> (TaskRecordStore, Data, URL) {
        StubHTTP.reset([
            #"{"content":[{"type":"text","text":"Reading the page."},{"type":"tool_use","id":"toolu_1","name":"read_page","input":{"mode":"text"}}],"stop_reason":"tool_use","usage":{"input_tokens":812,"output_tokens":41}}"#,
            #"{"content":[{"type":"tool_use","id":"toolu_2","name":"run_js","input":{"code":"document.cookie"}}],"stop_reason":"tool_use","usage":{"input_tokens":1204,"output_tokens":86}}"#,
            #"{"content":[{"type":"text","text":"The headline is \"Breaking News\". Your session id is \#(Self.sessionCookie)."}],"stop_reason":"end_turn","usage":{"input_tokens":1390,"output_tokens":30}}"#
        ])
        let store = TaskRecordStore(directory: try temporaryDirectory(), cookieSource: FixedCookies(Self.cookies))
        let session = BrowserAgentSession(
            pageDriver: PageStub(),
            modelClient: StubHTTP.service,
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .anthropic, model: "claude-sonnet-5-5"),
                    configuration: ProviderConfiguration(
                        model: "claude-sonnet-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: Self.anthropicKey
                    ),
                    maxSteps: 5, truncationLimit: 20_000, customInstructions: "", redactedSecrets: [Self.anthropicKey]
                )
            },
            taskRecords: store
        )
        await session.sendAndWait("Read the page and tell me the headline")
        guard case .completed = session.runState else {
            XCTFail("run did not complete: \(session.runState)")
            throw CancellationError()
        }
        XCTAssertEqual(session.wireSizes.count, 3, "sizes for each turn's Request and Response rows")
        XCTAssertEqual(session.toolCalls.first?.modelTurn, AgentTurnInfo(
            turn: 1, model: "claude-sonnet-5-5", usage: AgentTokenUsage(inputTokens: 812, outputTokens: 41)
        ))
        XCTAssertEqual(session.runs.last?.finalTurn?.turn, 3)

        let taskID = try XCTUnwrap(session.currentTaskID)
        let url = try await TaskExport.export(
            taskID: taskID, store: store, cookieSource: FixedCookies(Self.cookies), secrets: [Self.anthropicKey]
        )
        let data = try Data(contentsOf: url)
        if let out = ProcessInfo.processInfo.environment["TASK_EXPORT_FIXTURE_OUT"] {
            try data.write(to: URL(fileURLWithPath: out))
        }
        return (store, data, url)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("task-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(_ name: String) throws -> Data {
        if let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        return try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TaskExports/\(name).json"))
    }
}

// MARK: - Fakes

private final class WireCollector: AgentWireRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentWireExchange] = []
    var exchanges: [AgentWireExchange] { lock.withLock { stored } }
    func record(_ exchange: AgentWireExchange) async { lock.withLock { stored.append(exchange) } }
}

private struct FixedCookies: TaskCookieSource {
    let cookies: [KnownCookie]?
    init(_ cookies: [KnownCookie]?) { self.cookies = cookies }
    func cookies(forHosts hosts: Set<String>) async -> [KnownCookie]? { cookies }
}

private final class PageStub: AgentPageDriving, @unchecked Sendable {
    func currentPageMetadata() async -> AgentPageMetadata {
        AgentPageMetadata(url: "https://news.example.org/story", title: "Example Story")
    }
    func readPage(mode: PageReadMode, selector: String?, maxLength: Int?) async throws -> String { TaskExportTests.pageText }
    func runJS(code: String, environment: AgentExecutionEnvironment, timeout: TimeInterval) async throws -> JSExecutionResult {
        JSExecutionResult(valueJSON: "\"sid=\(TaskExportTests.sessionCookie); lang=en\"", consoleOutput: [], error: nil)
    }
    func injectCSS(css: String, id: String?) async throws -> CSSInjectionResult {
        CSSInjectionResult(sheetID: id ?? "s", appliedRootCount: 1)
    }
    func waitFor(selector: String?, milliseconds: Int?) async throws -> WaitForResult {
        WaitForResult(mode: .delay, matched: true, elapsedMs: 1, selector: selector)
    }
}

/// Serves the queued bodies, in order, with status 200, and keeps the requests it saw.
private final class StubHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var bodies: [String] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static let service: AIService = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTP.self]
        return AIService(session: URLSession(configuration: configuration))
    }()

    static func reset(_ queued: [String]) { lock.withLock { bodies = queued; requests = [] } }
    static var seen: [URLRequest] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let body: String = Self.lock.withLock {
            Self.requests.append(request)
            return Self.bodies.isEmpty ? "{}" : Self.bodies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
