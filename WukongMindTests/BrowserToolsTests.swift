import Foundation
import Network
import UIKit
import WebKit
import XCTest
@testable import WukongMind

/// `navigate` and `reload_page` on a real `ForumBrowserModel` (loopback HTTP
/// fixtures only), and a recorded-model replay of the page-feedback warning.
@MainActor
final class BrowserToolsTests: XCTestCase {
    // MARK: - Loopback server

    /// `/t/page` and `/t/other` (200), `/missing` (404), `/redirect` (302 to
    /// `/t/page`) and `/slow` (never answers).
    private final class FixtureServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "BrowserToolsTests.FixtureServer")
        private var held: [NWConnection] = []
        private(set) var port: UInt16 = 0

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

        func start() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                nonisolated(unsafe) var resumed = false
                listener.stateUpdateHandler = { [weak self] state in
                    guard !resumed, let self else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        self.port = self.listener.port?.rawValue ?? 0
                        continuation.resume()
                    case .failed(let error):
                        resumed = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
            queue.sync {
                held.forEach { $0.cancel() }
                held.removeAll()
            }
        }

        private func handle(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                let parts = (request.split(separator: "\r\n").first ?? "").split(separator: " ")
                let path = parts.count > 1 ? String(parts[1]) : "/"
                self.respond(to: path, on: connection)
            }
        }

        private func respond(to path: String, on connection: NWConnection) {
            let status: String
            var extraHeaders = ""
            var body = ""
            switch path {
            case "/t/page":
                status = "200 OK"
                body = Self.page(title: "Fixture page")
            case "/t/other":
                status = "200 OK"
                body = Self.page(title: "Other page")
            case "/missing":
                status = "404 Not Found"
                body = Self.page(title: "Not found")
            case "/redirect":
                status = "302 Found"
                extraHeaders = "Location: /t/page\r\n"
            case "/slow":
                held.append(connection)
                return
            default:
                status = "404 Not Found"
            }
            let bodyData = Data(body.utf8)
            let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(bodyData.count)\r\n\(extraHeaders)Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8)
            response.append(bodyData)
            connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }

        private static func page(title: String) -> String {
            """
            <!doctype html><html><head><meta name="viewport" content="width=device-width">
            <title>\(title)</title></head>
            <body><h1>\(title)</h1><p>Some text for the page.</p><a href="/t/other">Other</a></body></html>
            """
        }
    }

    private var server: FixtureServer!
    private var browser: ForumBrowserModel!
    private var window: UIWindow?
    private var scriptDirectory: URL?
    private var controller: ScriptWebController?

    override func setUp() async throws {
        try await super.setUp()
        server = try FixtureServer()
        try await server.start()
        browser = ForumBrowserModel(
            contentRules: ContentRuleLibrary(store: nil, directory: nil),
            websiteDataStore: .nonPersistent()
        )
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let root = UIViewController()
        root.view.addSubview(browser.webView)
        browser.webView.frame = root.view.bounds
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
    }

    override func tearDown() async throws {
        controller?.detach()
        controller = nil
        browser?.stopLoading()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        browser = nil
        server?.stop()
        server = nil
        if let scriptDirectory {
            try? FileManager.default.removeItem(at: scriptDirectory)
        }
        try await super.tearDown()
    }

    private func registry(timeout: TimeInterval = ToolRegistry.navigationTimeout, store: ScriptStore? = nil) -> ToolRegistry {
        let bridge = browser.agentBridge
        var tools = ToolRegistry.m1(bridge: bridge)
        let navigation = ToolRegistry.navigationTools(
            bridge: bridge,
            savedScriptCount: store.map(ToolRegistry.savedScriptCounter) ?? { _ in 0 },
            timeout: timeout
        )
        navigation.forEach { tools.register($0) }
        return tools
    }

    private func object(_ output: String) throws -> [String: Any] {
        let json = output.components(separatedBy: "\n\n").first { $0.hasPrefix("{") } ?? ""
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], output)
    }

    // MARK: - navigate

    func testNavigateReturnsFinalURLTitleAndStatus() async throws {
        let tools = registry()
        let result = try await tools.dispatch(
            toolName: "navigate",
            arguments: ["url": .string(server.baseURL.appendingPathComponent("redirect").absoluteString)]
        )
        XCTAssertFalse(result.isError, result.output)
        let fields = try object(result.output)
        XCTAssertEqual(fields["url"] as? String, server.baseURL.appendingPathComponent("t/page").absoluteString)
        XCTAssertEqual(fields["title"] as? String, "Fixture page")
        XCTAssertEqual(fields["status"] as? Int, 200)
        XCTAssertNotNil(fields["load_ms"] as? Int)
        XCTAssertNil(fields["timed_out"])
        XCTAssertTrue(result.resultSummary.hasPrefix("Opened 127.0.0.1 (200, "), result.resultSummary)

        let missing = try await tools.dispatch(
            toolName: "navigate",
            arguments: ["url": .string(server.baseURL.appendingPathComponent("missing").absoluteString)]
        )
        XCTAssertFalse(missing.isError, "A 404 page still loaded")
        XCTAssertEqual(try object(missing.output)["status"] as? Int, 404)
        XCTAssertEqual(try object(missing.output)["title"] as? String, "Not found")
    }

    func testNavigateRefusesOtherSchemes() async throws {
        let tools = registry()
        for address in ["javascript:alert(1)", "file:///etc/hosts", "wukongmind://open", "data:text/html,hi"] {
            let result = try await tools.dispatch(toolName: "navigate", arguments: ["url": .string(address)])
            XCTAssertTrue(result.isError, address)
            XCTAssertTrue(result.output.contains("Refused"), result.output)
        }
        let relative = try await tools.dispatch(toolName: "navigate", arguments: ["url": .string("example.com")])
        XCTAssertTrue(relative.isError)
        XCTAssertNil(browser.webView.url, "Nothing was loaded")
    }

    func testNavigateOpensAboutBlank() async throws {
        let result = try await registry().dispatch(toolName: "navigate", arguments: ["url": .string("about:blank")])
        XCTAssertFalse(result.isError, result.output)
        XCTAssertEqual(try object(result.output)["url"] as? String, "about:blank")
    }

    func testNavigateTimesOutCleanly() async throws {
        let tools = registry(timeout: 1)
        let started = ContinuousClock.now
        let result = try await tools.dispatch(
            toolName: "navigate",
            arguments: ["url": .string(server.baseURL.appendingPathComponent("slow").absoluteString)]
        )
        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
        XCTAssertFalse(result.isError, result.output)
        let fields = try object(result.output)
        XCTAssertEqual(fields["timed_out"] as? Bool, true)
        XCTAssertTrue(result.resultSummary.contains("timed out"))

        // The browser is still usable afterwards.
        let next = try await tools.dispatch(
            toolName: "navigate",
            arguments: ["url": .string(server.baseURL.appendingPathComponent("t/other").absoluteString)]
        )
        XCTAssertEqual(try object(next.output)["title"] as? String, "Other page", next.output)
    }

    func testNavigateWithWaitNoneReturnsAtOnce() async throws {
        let result = try await registry().dispatch(
            toolName: "navigate",
            arguments: [
                "url": .string(server.baseURL.appendingPathComponent("slow").absoluteString),
                "wait": .string("none")
            ]
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(try object(result.output)["load_ms"] as? Int, 0)
    }

    // MARK: - reload_page

    func testReloadDropsUnsavedCSSAndInjectsSavedScriptsAgain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserToolsTests-\(UUID().uuidString)", isDirectory: true)
        scriptDirectory = directory
        let store = ScriptStore(directoryURL: directory)
        _ = try store.create(
            id: "saved-marker",
            name: "Saved marker",
            matchRules: ["*://127.0.0.1/t/*"],
            js: "document.documentElement.dataset.savedRuns = String(Number(sessionStorage.getItem('runs') || '0') + 1); sessionStorage.setItem('runs', document.documentElement.dataset.savedRuns);",
            injectionTime: .documentEnd,
            environment: .page
        )
        controller = ScriptWebController(webView: browser.webView, store: store, agentBridge: browser.agentBridge)
        let tools = registry(store: store)

        let opened = try await tools.dispatch(
            toolName: "navigate",
            arguments: ["url": .string(server.baseURL.appendingPathComponent("t/page").absoluteString)]
        )
        XCTAssertFalse(opened.isError, opened.output)
        let firstRuns = try await browser.webView.evaluateJavaScript("document.documentElement.dataset.savedRuns") as? String
        XCTAssertEqual(firstRuns, "1")

        let css = try await tools.dispatch(
            toolName: "inject_css",
            arguments: ["css": .string("body { background-color: rgb(1, 2, 3) !important; }")]
        )
        XCTAssertFalse(css.isError, css.output)
        let styled = try await browser.webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
        XCTAssertEqual(styled, "rgb(1, 2, 3)")

        let reloaded = try await tools.dispatch(toolName: "reload_page", arguments: [:])
        XCTAssertFalse(reloaded.isError, reloaded.output)
        XCTAssertTrue(
            reloaded.output.hasSuffix("Unsaved changes from this conversation were dropped; 1 saved script was injected again."),
            reloaded.output
        )
        XCTAssertEqual(try object(reloaded.output)["status"] as? Int, 200)
        XCTAssertNil(reloaded.pageFeedback, "reload_page skips the comparison")

        let unstyled = try await browser.webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
        XCTAssertNotEqual(unstyled, "rgb(1, 2, 3)", "The unsaved stylesheet is gone")
        let secondRuns = try await browser.webView.evaluateJavaScript("document.documentElement.dataset.savedRuns") as? String
        XCTAssertEqual(secondRuns, "2", "The saved script ran again")
    }

    func testReloadWithNoPageFails() async throws {
        let result = try await registry(timeout: 2).dispatch(toolName: "reload_page", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("There is no page to reload."), result.output)
    }

    func testDriverWithoutNavigationReportsAnError() async throws {
        let tools = ToolRegistry(tools: ToolRegistry.navigationTools(bridge: SnapshotDriver(snapshots: [])))
        let result = try await tools.dispatch(toolName: "reload_page", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("can't open or reload pages"), result.output)
    }

    // MARK: - Recorded replay: a warning leads to read_page, not "done"

    private final class SnapshotDriver: AgentPageDriving, @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [PageStateSnapshot]
        private(set) var readCount = 0

        init(snapshots: [PageStateSnapshot]) { self.snapshots = snapshots }

        func currentPageMetadata() async -> AgentPageMetadata {
            AgentPageMetadata(url: "https://news.example.org/story", title: "Story")
        }

        func readPage(mode: PageReadMode, selector: String?, maxLength: Int?) async throws -> String {
            lock.withLock { readCount += 1 }
            return "Page: Story\n(empty body)"
        }

        func runJS(code: String, environment: AgentExecutionEnvironment, timeout: TimeInterval) async throws -> JSExecutionResult {
            JSExecutionResult(valueJSON: "true", consoleOutput: [], error: nil)
        }

        func injectCSS(css: String, id: String?) async throws -> CSSInjectionResult {
            CSSInjectionResult(sheetID: id ?? "s1", appliedRootCount: 1)
        }

        func waitFor(selector: String?, milliseconds: Int?) async throws -> WaitForResult {
            WaitForResult(mode: .delay, matched: true, elapsedMs: 1, selector: nil)
        }

        func pageSnapshot() async -> PageStateSnapshot? {
            lock.withLock { snapshots.isEmpty ? nil : snapshots.removeFirst() }
        }
    }

    private final class RecordedModelClient: AgentModelClient, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [AgentModelTurnResponse]
        private(set) var requests: [(system: String, messages: [AgentModelTurn])] = []

        init(_ responses: [AgentModelTurnResponse]) { self.responses = responses }

        func completeToolTurn(
            system: String,
            messages: [AgentModelTurn],
            tools: [AgentToolDefinition],
            configuration: ProviderConfiguration,
            provider: AIProvider,
            maxTokens: Int
        ) async throws -> AgentModelTurnResponse {
            lock.withLock {
                requests.append((system, messages))
                return responses.isEmpty ? AgentModelTurnResponse(text: "Done.") : responses.removeFirst()
            }
        }
    }

    func testWarningLeadsTheAgentToReadThePageInsteadOfAnsweringDone() async throws {
        let before = PageStateSnapshot(
            url: "https://news.example.org/story", textLength: 8_000, documentHeight: 6_000,
            isScrollable: true, linkCount: 40, formControlCount: 2, visibleImageCount: 4, pageErrorCount: 0
        )
        var after = before
        after.textLength = 0
        after.documentHeight = 844
        after.isScrollable = false
        after.linkCount = 0
        after.visibleImageCount = 0
        let driver = SnapshotDriver(snapshots: [before, after])

        // Recorded turns: the model empties the body, sees the warning, checks
        // with read_page, and only then answers (not "done").
        let client = RecordedModelClient([
            AgentModelTurnResponse(
                text: "",
                toolCalls: [AgentModelToolCall(id: "t1", name: "run_js", arguments: ["code": .string("document.body.innerHTML = ''")])],
                stopReason: "tool_use"
            ),
            AgentModelTurnResponse(
                text: "",
                toolCalls: [AgentModelToolCall(id: "t2", name: "read_page", arguments: ["mode": .string("text")])],
                stopReason: "tool_use"
            ),
            AgentModelTurnResponse(text: "That emptied the page, so I'll undo it and try a narrower change.")
        ])

        let session = BrowserAgentSession(
            pageDriver: driver,
            modelClient: client,
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
                    configuration: ProviderConfiguration(
                        model: "claude-haiku-5-5",
                        baseURL: AIProvider.anthropic.defaultBaseURL,
                        apiKey: "fake-key"
                    ),
                    maxSteps: 30,
                    truncationLimit: 20_000,
                    customInstructions: "",
                    redactedSecrets: []
                )
            }
        )
        await session.sendAndWait("Hide the comments")

        XCTAssertTrue(client.requests.first?.system.contains("The page may be broken") == true, "The prompt carries rule 6")
        XCTAssertTrue(client.requests.first?.system.contains("never report done straight away") == true)

        // The second request carries the warning as the run_js result's first line.
        guard case .toolResults(let results)? = client.requests[1].messages.last else {
            return XCTFail("Expected tool results in the second request")
        }
        let content = try XCTUnwrap(results.first?.content)
        let inner = content.components(separatedBy: "\n").dropFirst().first ?? ""
        XCTAssertTrue(inner.hasPrefix("The page may be broken: visible text dropped from 8,000 to 0 characters"), content)
        XCTAssertTrue(content.contains("Page changes: text 8,000 → 0"))

        XCTAssertEqual(session.toolCalls.map(\.toolName), ["run_js", "read_page"])
        XCTAssertEqual(driver.readCount, 1)
        XCTAssertEqual(session.pageBaseline, before, "The run's baseline is the page before its first change")
        XCTAssertTrue(session.toolCalls.first?.resultSummary.hasPrefix("Page may be broken") == true)
    }
}
