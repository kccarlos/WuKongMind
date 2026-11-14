import Foundation
import XCTest
#if canImport(WukongMind)
@testable import WukongMind
#endif

/// M3 acceptance checks 1 to 3 (design-m3.md "Acceptance checks") against the 25-page fixture
/// forum in `Fixtures/CrawlForum`: the crawl lands every page in the workspace and the summary
/// covers every page; the files and the task record survive a relaunch; the exported task holds no
/// key or cookie and replays through `RecordedModelClient` (`Fixtures/TaskExports/crawl-25-pages.json`).
/// WebKit's `wukong.fetch` and `wukong.files` bridge is covered by `AgentBridgeTests` and
/// `AgentNetworkToolsTests`; here the page driver stands in for it and writes through `AgentWorkspace`.
@MainActor
final class CrawlAcceptanceTests: XCTestCase {
    nonisolated static let anthropicKey = "sk-ant-api03-CRAWLKEY-0123456789"
    nonisolated static let sessionCookie = "crawl-session-value-77"
    nonisolated static let cookies = [KnownCookie(name: "sid", value: sessionCookie)]
    nonisolated static let threadDir = "crawls/indieboard.example/thread-1"
    nonisolated static let topics = [
        "mechanical keyboards", "offline maps", "tea brewing", "bike commuting", "home networks",
        "sourdough starters", "film cameras", "e-ink readers", "houseplants", "chess openings",
        "vinyl records", "3D printing", "trail running", "password managers", "podcast gear",
        "coffee grinders", "retro consoles", "solar chargers", "note-taking apps", "board games",
        "fountain pens", "weather stations", "open-source licences", "sleep routines", "soldering irons"
    ]

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrawlAcceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: Checks 1 and 2

    func testCrawlSavesEveryPageSummaryCoversThemAndFilesSurviveARelaunch() async throws {
        let run = try await runCrawl()
        let (workspaceRoot, recordsDirectory) = (run.workspaceRoot, run.recordsDirectory)

        // Check 1: every page file exists, whole, and the Agent used well under 30 steps.
        let workspace = AgentWorkspace(root: workspaceRoot)
        for page in 1...25 {
            let name = String(format: "page-%02d", page)
            let read = try await workspace.read(path: "\(Self.threadDir)/\(name).txt", length: 100_000)
            XCTAssertTrue(read.text.contains("CRAWL-MARKER-\(String(format: "%02d", page))"), "\(name) is whole")
            XCTAssertEqual(read.text, try Self.pageText(page))
        }
        guard case .completed(let steps, _) = run.session.runState else {
            return XCTFail("run did not complete: \(run.session.runState)")
        }
        XCTAssertEqual(run.session.toolCalls.map(\.toolName), ["read_page", "run_js", "run_js", "file_read", "file_read"])
        XCTAssertLessThan(steps, 30)
        let summary = try XCTUnwrap(run.session.messages.last { $0.role == .assistant }).text
        for (index, topic) in Self.topics.enumerated() {
            XCTAssertTrue(summary.contains(topic), "the summary cites page \(index + 1): \(topic)")
        }

        // Check 2: a relaunch (new workspace and record store over the same folders) finds the files
        // whole and the task in the record.
        let relaunched = AgentWorkspace(root: workspaceRoot)
        let listing = try await relaunched.list(path: Self.threadDir)
        XCTAssertEqual(listing.entries.filter { $0.path.hasSuffix(".txt") && $0.path.contains("page-") }.count, 25)
        let reopened = TaskRecordStore(directory: recordsDirectory, cookieSource: FixedCookies(Self.cookies))
        let taskIDs = await reopened.taskIDs()
        XCTAssertEqual(taskIDs, [try XCTUnwrap(run.session.currentTaskID)])
        let events = await reopened.events(taskID: try XCTUnwrap(taskIDs.first))
        XCTAssertFalse(events.isEmpty)
    }

    // MARK: Check 3

    func testExportedCrawlHasNoSecretsAndReplays() async throws {
        let run = try await runCrawl()
        let url = try await TaskExport.export(
            taskID: try XCTUnwrap(run.session.currentTaskID), store: run.store,
            cookieSource: FixedCookies(Self.cookies), secrets: [Self.anthropicKey]
        )
        let data = try Data(contentsOf: url)
        // `TEST_RUNNER_TASK_EXPORT_FIXTURE_OUT=<path>` rewrites the checked-in fixture from this run.
        if let out = ProcessInfo.processInfo.environment["TASK_EXPORT_FIXTURE_OUT"] {
            try data.write(to: URL(fileURLWithPath: out))
        }
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(Self.anthropicKey))
        XCTAssertFalse(text.contains(Self.sessionCookie))
        try await assertReplays(TaskExport.load(data))
    }

    func testCheckedInCrawlFixtureReplaysThroughRecordedModelClient() async throws {
        let data = try fixture("crawl-25-pages")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(Self.anthropicKey), "no API key")
        XCTAssertFalse(text.contains(Self.sessionCookie), "no cookie value")
        XCTAssertFalse(text.contains("Set-Cookie:"), "no recorded cookie header")
        let document = try TaskExport.load(data)
        XCTAssertEqual(document.turns.flatMap(\.toolResults).count, 5)
        try await assertReplays(document)
    }

    // MARK: Helpers

    private struct CrawlRun {
        var session: BrowserAgentSession
        var store: TaskRecordStore
        var workspaceRoot: URL
        var recordsDirectory: URL
    }

    private func runCrawl() async throws -> CrawlRun {
        let workspaceRoot = sandbox.appendingPathComponent("Documents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let recordsDirectory = sandbox.appendingPathComponent("Records-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
        let workspace = AgentWorkspace(root: workspaceRoot)
        let store = TaskRecordStore(directory: recordsDirectory, cookieSource: FixedCookies(Self.cookies))

        let summary = Self.topics.enumerated().map { "Page \($0.offset + 1): \($0.element)." }.joined(separator: " ")
        StubHTTP.reset([
            Self.reply([.text("Reading the first page."), .tool("t1", "read_page", ["mode": "text"])]),
            Self.reply([.tool("t2", "run_js", ["code": "/* PAGES:1-13 */ for (let p = 1; p <= 13; p++) { await wukong.files.write(`\(Self.threadDir)/page-${String(p).padStart(2, '0')}.txt`, await wukong.fetch(`/crawl/page-${String(p).padStart(2, '0')}.html`)); }"])]),
            Self.reply([.tool("t3", "run_js", ["code": "/* PAGES:14-25 */ for (let p = 14; p <= 25; p++) { await wukong.files.write(`\(Self.threadDir)/page-${String(p).padStart(2, '0')}.txt`, await wukong.fetch(`/crawl/page-${String(p).padStart(2, '0')}.html`)); }"])]),
            Self.reply([.tool("t4", "file_read", ["path": "\(Self.threadDir)/index.txt"])]),
            Self.reply([.tool("t5", "file_read", ["path": "\(Self.threadDir)/page-25.txt", "length": 400])]),
            Self.reply([.text("The thread, page by page. \(summary)")], stop: "end_turn")
        ])
        let driver = CrawlPageDriver(workspace: workspace)
        let session = BrowserAgentSession(
            pageDriver: driver,
            modelClient: StubHTTP.service,
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .anthropic, model: "claude-sonnet-5-5"),
                    configuration: ProviderConfiguration(
                        model: "claude-sonnet-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: Self.anthropicKey
                    ),
                    maxSteps: 30, truncationLimit: 20_000, customInstructions: "", redactedSecrets: [Self.anthropicKey]
                )
            },
            registryBuilder: { bridge, limit, secrets in
                ToolRegistry.m3(context: AgentToolContext(
                    bridge: bridge, workspace: workspace,
                    scriptStore: ScriptStore(directoryURL: workspaceRoot.deletingLastPathComponent().appendingPathComponent("Scripts-\(UUID().uuidString)", isDirectory: true)),
                    settings: AgentToolSettings(truncationLimit: limit, redactedSecrets: secrets)
                ))
            },
            taskRecords: store
        )
        await session.sendAndWait("Read the whole thread and summarize it")
        return CrawlRun(session: session, store: store, workspaceRoot: workspaceRoot, recordsDirectory: recordsDirectory)
    }

    nonisolated static func pageText(_ page: Int) throws -> String {
        let name = String(format: "page-%02d.html", page)
        // On a device the files are in the test bundle; on the simulator the source folder works too.
        if let bundled = Bundle(for: CrawlAcceptanceTests.self).url(forResource: "page-\(String(format: "%02d", page))", withExtension: "html") {
            return try String(contentsOf: bundled, encoding: .utf8)
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CrawlForum/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fixture(_ name: String) throws -> Data {
        if let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        return try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TaskExports/\(name).json"))
    }

    private func assertReplays(_ document: TaskExportDocument) async throws {
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
        XCTAssertEqual(result.history, document.history)
        XCTAssertEqual(result.toolRows.map(\.toolName), ["read_page", "run_js", "run_js", "file_read", "file_read"])
        guard case .completed(let text, let steps, _) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(steps, 5)
        for topic in Self.topics { XCTAssertTrue(text.contains(topic), topic) }
    }

    private enum Block {
        case text(String)
        case tool(String, String, [String: Any])
        var json: [String: Any] {
            switch self {
            case .text(let text): return ["type": "text", "text": text]
            case .tool(let id, let name, let input): return ["type": "tool_use", "id": id, "name": name, "input": input]
            }
        }
    }

    private static func reply(_ blocks: [Block], stop: String = "tool_use") -> String {
        let object: [String: Any] = [
            "content": blocks.map(\.json), "stop_reason": stop,
            "usage": ["input_tokens": 900, "output_tokens": 60]
        ]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }
}

// MARK: - Fakes

private struct FixedCookies: TaskCookieSource {
    let cookies: [KnownCookie]?
    init(_ cookies: [KnownCookie]?) { self.cookies = cookies }
    func cookies(forHosts hosts: Set<String>) async -> [KnownCookie]? { cookies }
}

/// Stands in for WebKit: a `run_js` marked `PAGES:a-b` does what the crawl script does, copying the
/// fixture pages into the workspace (the second one also writes `index.txt`, the page markers).
private final class CrawlPageDriver: AgentPageDriving, @unchecked Sendable {
    let workspace: AgentWorkspace
    init(workspace: AgentWorkspace) { self.workspace = workspace }

    func currentPageMetadata() async -> AgentPageMetadata {
        AgentPageMetadata(url: "https://indieboard.example/threads/1", title: "Long thread · page 1 of 25")
    }
    func readPage(mode: PageReadMode, selector: String?, maxLength: Int?) async throws -> String {
        "Page: Long thread (page 1 of 25)\n[a] Next page\n\(try CrawlAcceptanceTests.pageText(1))"
    }
    func runJS(code: String, environment: AgentExecutionEnvironment, timeout: TimeInterval) async throws -> JSExecutionResult {
        guard let match = code.range(of: #"PAGES:(\d+)-(\d+)"#, options: .regularExpression) else {
            return JSExecutionResult(valueJSON: "null", consoleOutput: [], error: nil)
        }
        let bounds = code[match].dropFirst(6).split(separator: "-").compactMap { Int($0) }
        for page in bounds[0]...bounds[1] {
            try await workspace.write(
                path: String(format: "\(CrawlAcceptanceTests.threadDir)/page-%02d.txt", page),
                content: try CrawlAcceptanceTests.pageText(page)
            )
        }
        if bounds[1] == 25 {
            let index = CrawlAcceptanceTests.topics.enumerated()
                .map { String(format: "page-%02d: CRAWL-MARKER-%02d %@", $0.offset + 1, $0.offset + 1, $0.element) }
                .joined(separator: "\n")
            try await workspace.write(path: "\(CrawlAcceptanceTests.threadDir)/index.txt", content: index)
        }
        return JSExecutionResult(valueJSON: "\"saved pages \(bounds[0]) to \(bounds[1])\"", consoleOutput: [], error: nil)
    }
    func injectCSS(css: String, id: String?) async throws -> CSSInjectionResult {
        CSSInjectionResult(sheetID: id ?? "s", appliedRootCount: 1)
    }
    func waitFor(selector: String?, milliseconds: Int?) async throws -> WaitForResult {
        WaitForResult(mode: .delay, matched: true, elapsedMs: 1, selector: selector)
    }
}

private final class StubHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var bodies: [String] = []
    private static let lock = NSLock()

    static let service: AIService = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTP.self]
        return AIService(session: URLSession(configuration: configuration))
    }()

    static func reset(_ queued: [String]) { lock.withLock { bodies = queued } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let body: String = Self.lock.withLock { Self.bodies.isEmpty ? "{}" : Self.bodies.removeFirst() }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
