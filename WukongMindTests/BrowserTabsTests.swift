import Combine
import Foundation
import Network
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import WukongMind

/// Unit tests for T1 (`design-browser-bar-tabs-models.md`, row T1):
/// - Opening, switching, and closing tabs, each with its own `BrowserAgentSession`
///   and `ForumBrowserModel`, while `AppModel.browser` and its observers re-subscribe.
/// - Logins / cookies carry over across tabs via the shared `WKWebsiteDataStore`.
/// - An Agent run started in tab A keeps driving tab A (its `AgentBridge`, page tools,
///   and navigation) after switching the active tab to tab B.
/// - Tapping a `target="_blank"` link opens a new front tab right after the current
///   tab, while non-gesture `window.open` stays blocked.
@MainActor
final class BrowserTabsTests: XCTestCase {
    // MARK: - Loopback HTTP Server

    private final class LoopbackTabsServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "BrowserTabsTests.LoopbackServer")
        private let logLock = NSLock()
        private var loggedPaths: [String] = []
        private(set) var port: UInt16 = 0

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

        var requestedPaths: [String] {
            logLock.withLock { loggedPaths }
        }

        func resetRequestLog() {
            logLock.withLock { loggedPaths.removeAll() }
        }

        func url(_ path: String) -> URL {
            URL(string: path, relativeTo: baseURL)!.absoluteURL
        }

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
        }

        private func handle(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
                guard let self, let data, let raw = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                let lines = raw.components(separatedBy: "\r\n")
                let requestLine = lines.first ?? ""
                let parts = requestLine.split(separator: " ")
                let path = parts.count > 1 ? String(parts[1]) : "/"
                let cookieHeader = lines
                    .first { $0.lowercased().hasPrefix("cookie:") }
                    .map { String($0.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces) }
                    ?? ""
                if path != "/favicon.ico" {
                    self.logLock.withLock { self.loggedPaths.append(path) }
                }
                self.respond(path: path, cookieHeader: cookieHeader, on: connection)
            }
        }

        private func respond(path: String, cookieHeader: String, on connection: NWConnection) {
            var status = "200 OK"
            var extraHeaders = ""
            let body: String

            switch path {
            case "/t/alpha-topic/101":
                body = """
                <!doctype html>
                <html>
                <head>
                  <meta charset="utf-8">
                  <meta name="generator" content="Discourse 3.3.0">
                  <title>Alpha Forum Topic</title>
                </head>
                <body>
                  <h1>Alpha Forum Topic</h1>
                  <article data-post-id="1" id="post_1"><p>First post on Alpha.</p></article>
                </body>
                </html>
                """
            case "/tab-a":
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Alpha Page</title></head>
                <body>
                  <h1>Alpha Page</h1>
                  <div id="target">before</div>
                </body>
                </html>
                """
            case "/tab-a-step2":
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Alpha Step Two</title></head>
                <body>
                  <h1>Alpha Step Two</h1>
                  <div id="step2">arrived</div>
                </body>
                </html>
                """
            case "/tab-b":
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Beta Page</title></head>
                <body>
                  <h1>Beta Page</h1>
                  <div id="target">untouched</div>
                </body>
                </html>
                """
            case "/login":
                extraHeaders = "Set-Cookie: forum_session=signed-in-token-42; Path=/; HttpOnly\r\n"
                    + "Set-Cookie: reader_theme=sepia; Path=/\r\n"
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Signed In</title></head>
                <body><p id="status">ok</p></body>
                </html>
                """
            case "/whoami":
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Who Am I</title></head>
                <body><p id="cookies">\(cookieHeader)</p></body>
                </html>
                """
            case "/opener":
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Opener Page</title></head>
                <body>
                  <h1>Opener Page</h1>
                  <a id="blank-link" href="/opened-blank" target="_blank" style="display:block;padding:24px;font-size:24px;">Open in New Tab</a>
                  <button id="popup-btn" onclick="window.lastPopup = window.open('/opened-popup');" style="display:block;padding:24px;font-size:24px;">Open Popup</button>
                  <script>
                    window.autoPopupResult = window.open('/auto-popup');
                  </script>
                </body>
                </html>
                """
            case "/opened-blank":
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Opened Blank Tab</title></head>
                <body><h1 id="heading">Opened Blank Tab</h1></body>
                </html>
                """
            case "/opened-popup":
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Opened Popup Tab</title></head>
                <body><h1 id="heading">Opened Popup Tab</h1></body>
                </html>
                """
            case "/auto-popup":
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Auto Popup</title></head>
                <body><h1>Should Be Blocked</h1></body>
                </html>
                """
            case "/timers":
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Timer Page</title></head>
                <body>
                  <h1>Timer Page</h1>
                  <div id="ticks">0</div>
                  <script>
                    window.__intervalTicks = 0;
                    window.__timeoutTicks = 0;
                    setInterval(() => {
                      window.__intervalTicks += 1;
                      document.getElementById('ticks').textContent = String(window.__intervalTicks);
                    }, 40);
                    function scheduleNext() {
                      setTimeout(() => {
                        window.__timeoutTicks += 1;
                        scheduleNext();
                      }, 40);
                    }
                    scheduleNext();
                  </script>
                </body>
                </html>
                """
            case let p where p.hasPrefix("/tall/"):
                let suffix = String(p.dropFirst("/tall/".count))
                body = """
                <!doctype html>
                <html>
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1">
                  <title>Tall Tab \(suffix)</title>
                </head>
                <body style="margin:0;">
                  <div style="height:3600px;background:linear-gradient(#e2e8f0,#94a3b8);padding:24px;">
                    <h1 id="heading">Tall Tab \(suffix)</h1>
                    <div id="target">content-\(suffix)</div>
                  </div>
                </body>
                </html>
                """
            default:
                status = "404 Not Found"
                body = "<!doctype html><html><head><title>404</title></head><body>Not found</body></html>"
            }

            let bodyData = Data(body.utf8)
            let header = "HTTP/1.1 \(status)\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(bodyData.count)\r\n"
                + extraHeaders
                + "Cache-Control: no-store\r\n"
                + "Connection: close\r\n\r\n"
            var payload = Data(header.utf8)
            payload.append(bodyData)
            let closeQueue = queue
            connection.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                closeQueue.asyncAfter(deadline: .now() + .milliseconds(200)) {
                    connection.cancel()
                }
            })
        }
    }

    // MARK: - Gated Model Client for Cross-Tab Concurrency

    private actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }
    }

    private final class TabBoundAgentClient: AgentModelClient, @unchecked Sendable {
        let step1Started = AsyncGate()
        let allowStep2 = AsyncGate()
        private let step2DestinationURL: String
        private var turn = 0

        init(step2DestinationURL: String) {
            self.step2DestinationURL = step2DestinationURL
        }

        func completeToolTurn(
            system: String,
            messages: [AgentModelTurn],
            tools: [AgentToolDefinition],
            configuration: ProviderConfiguration,
            provider: AIProvider,
            maxTokens: Int
        ) async throws -> AgentModelTurnResponse {
            turn += 1
            switch turn {
            case 1:
                await step1Started.open()
                return AgentModelTurnResponse(
                    text: "",
                    toolCalls: [
                        AgentModelToolCall(id: "c1", name: "read_page", arguments: [:])
                    ],
                    stopReason: "tool_use"
                )
            case 2:
                await allowStep2.wait()
                try Task.checkCancellation()
                return AgentModelTurnResponse(
                    text: "",
                    toolCalls: [
                        AgentModelToolCall(
                            id: "c2",
                            name: "run_js",
                            arguments: [
                                "code": .string("document.getElementById('target').textContent = 'mutated-in-tab-a'; return document.title;")
                            ]
                        )
                    ],
                    stopReason: "tool_use"
                )
            case 3:
                return AgentModelTurnResponse(
                    text: "",
                    toolCalls: [
                        AgentModelToolCall(
                            id: "c3",
                            name: "navigate",
                            arguments: ["url": .string(step2DestinationURL)]
                        )
                    ],
                    stopReason: "tool_use"
                )
            default:
                return AgentModelTurnResponse(text: "Completed work on Tab A.")
            }
        }
    }

    // MARK: - Fixture Setup

    private struct NoOpBackgroundGrace: BackgroundGracing {
        func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier { .invalid }
        func end(_ id: UIBackgroundTaskIdentifier) {}
    }

    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private var server: LoopbackTabsServer!
    private var tempDir: URL!
    private var hostWindow: UIWindow!
    private var webHostView: BrowserTabsWebHostView!
    private var app: AppModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        cancellables.removeAll()
        let existingCookies = await Self.sharedDataStore.httpCookieStore.allCookies()
        for cookie in existingCookies {
            await Self.sharedDataStore.httpCookieStore.deleteCookie(cookie)
        }

        server = try LoopbackTabsServer()
        try await server.start()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserTabsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dataStore = Self.sharedDataStore
        let contentRules = ContentRuleLibrary(store: nil, directory: nil)
        let initialBrowser = ForumBrowserModel(contentRules: contentRules, websiteDataStore: dataStore)

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let rootVC = UIViewController()
        rootVC.view.frame = window.bounds
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        self.hostWindow = window

        let store = PersistentStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            keys: InMemoryProviderKeyStore()
        )
        app = AppModel(
            store: store,
            browser: initialBrowser,
            websiteDataStore: dataStore,
            cloudSync: CloudSyncController(transport: nil, files: nil, defaults: nil, schedulesAutomatically: false),
            podcastDirectory: tempDir.appendingPathComponent("Podcasts", isDirectory: true),
            workspaceDirectory: tempDir.appendingPathComponent("Workspace", isDirectory: true),
            spotlightIndex: FakeSpotlightIndex(),
            topicActivityDonor: FakeTopicActivityDonor(),
            backgroundGrace: NoOpBackgroundGrace()
        )
        app.usesDirectForumRequests = true

        var anthropic = app.settings.configuration(for: .anthropic)
        anthropic.apiKey = "test-key"
        anthropic.model = "claude-haiku-5-5"
        app.settings.setConfiguration(anthropic, for: .anthropic)
        app.settings.setModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .browserAgent)

        mountTabsWebHost(for: app)
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        if let app {
            tearDownApp(app)
        }
        app = nil
        webHostView?.removeFromSuperview()
        webHostView = nil
        if let hostWindow {
            hostWindow.isHidden = true
            hostWindow.rootViewController = nil
            hostWindow.windowScene = nil
        }
        hostWindow = nil
        server?.stop()
        server = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    private func tearDownApp(_ targetApp: AppModel) {
        for tab in targetApp.tabs.tabs {
            tab.agentSession.stop()
            tab.browser.stopLoading()
            tab.browser.detachCallbacks()
            tab.scriptWebController.detach()
            tab.browser.existingWebView?.removeFromSuperview()
        }
        targetApp.pauseDigest()
        targetApp.podcast.pauseGeneration()
    }

    private func mountTabsWebHost(for targetApp: AppModel) {
        guard let rootView = hostWindow?.rootViewController?.view else { return }
        rootView.subviews.forEach { $0.removeFromSuperview() }
        let host = BrowserTabsWebHostView(tabs: targetApp.tabs, frame: rootView.bounds)
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        rootView.addSubview(host)
        rootView.layoutIfNeeded()
        webHostView = host
    }

    private func waitUntil(
        timeout: TimeInterval = 15,
        description: String = "condition",
        condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    // MARK: - Tests

    func testOpenSwitchAndCloseTabsWithIndependentSessionsAndReSubscribedObservers() async throws {
        XCTAssertEqual(app.tabs.tabs.map(\.id), ["t1"])
        let tab1 = app.tabs.currentTab
        XCTAssertTrue(app.browser === tab1.browser)
        XCTAssertTrue(app.browserAgent === tab1.agentSession)

        var observedPageURLs: [URL?] = []
        app.pageUpdates
            .sink { context in observedPageURLs.append(context.url) }
            .store(in: &cancellables)

        // Load a recognized Discourse topic in t1 and run a turn in t1's session.
        let alphaTopicURL = server.url("/t/alpha-topic/101")
        app.browser.load(alphaTopicURL)
        try await waitUntil(description: "t1 forum topic detected") {
            self.app.currentTopic?.topicID == "101" && !self.app.browser.isLoading
        }

        tab1.agentSession.configureDebugModelClient(
            RecordedModelClient([.success(AgentModelTurnResponse(text: "Tab 1 answer."))])
        )
        await app.browserAgent.sendAndWait("Hello from tab 1")
        XCTAssertEqual(tab1.agentSession.runs.count, 1)
        XCTAssertEqual(app.browserAgent.runs.first?.assistantText, "Tab 1 answer.")

        // Open t2 in front on a plain web page: AppModel.browser, AppModel.browserAgent,
        // currentTopic, and pageUpdates all switch to t2 while t1 keeps its state.
        let betaURL = server.url("/tab-b")
        let tab2 = try XCTUnwrap(app.tabs.openTab(url: betaURL))
        XCTAssertEqual(app.tabs.tabs.map(\.id), ["t1", "t2"])
        XCTAssertEqual(app.tabs.currentTabID, "t2")
        XCTAssertTrue(app.browser === tab2.browser)
        XCTAssertTrue(app.browserAgent === tab2.agentSession)
        XCTAssertFalse(app.browserAgent === tab1.agentSession)
        XCTAssertTrue(app.browserAgent.runs.isEmpty, "New tab starts with an empty BrowserAgentSession")

        try await waitUntil(description: "t2 loaded /tab-b") {
            tab2.browser.pageTitle == "Beta Page" && !tab2.browser.isLoading
        }
        XCTAssertNil(app.currentTopic, "Plain page in t2 clears active currentTopic")
        XCTAssertEqual(observedPageURLs.last ?? nil, betaURL)

        // Switch back to t1: active browser, session, currentTopic, and pageUpdates restore t1.
        XCTAssertTrue(app.tabs.switchToTab(id: "t1"))
        XCTAssertTrue(app.browser === tab1.browser)
        XCTAssertTrue(app.browserAgent === tab1.agentSession)
        XCTAssertEqual(app.browserAgent.runs.count, 1)
        XCTAssertEqual(app.currentTopic?.topicID, "101")
        XCTAssertEqual(observedPageURLs.last ?? nil, alphaTopicURL)

        // Close active tab t1: t2 becomes active.
        XCTAssertTrue(app.tabs.closeTab(id: "t1"))
        XCTAssertEqual(app.tabs.tabs.map(\.id), ["t2"])
        XCTAssertEqual(app.tabs.currentTabID, "t2")
        XCTAssertTrue(app.browser === tab2.browser)
        XCTAssertNil(app.currentTopic)

        // Close the last remaining tab t2: a fresh Home tab t3 replaces it so currentTab stays valid.
        XCTAssertTrue(app.tabs.closeTab(id: "t2"))
        XCTAssertEqual(app.tabs.tabs.map(\.id), ["t3"])
        XCTAssertTrue(app.browser.showsForumsHome)
        XCTAssertNil(app.browser.currentURL)
        XCTAssertTrue(app.browserAgent.runs.isEmpty)
    }

    func testLoginsAndCookiesCarryOverAcrossTabs() async throws {
        // Sign in on tab 1 (/login sets both an HttpOnly session cookie and a JS cookie).
        app.browser.load(server.url("/login"))
        try await waitUntil(description: "t1 /login finished") {
            self.app.browser.pageTitle == "Signed In" && !self.app.browser.isLoading
        }

        // Open tab 2 to /whoami: both HttpOnly request cookies and document.cookie carry over.
        let tab2 = try XCTUnwrap(app.tabs.openTab(url: server.url("/whoami")))
        try await waitUntil(description: "t2 /whoami finished") {
            tab2.browser.pageTitle == "Who Am I" && !tab2.browser.isLoading
        }

        let echoedCookies = try await tab2.browser.agentBridge.runJS(
            code: "return { serverCookies: document.getElementById('cookies').textContent, jsCookies: document.cookie };",
            environment: .isolated
        )
        let parsed = try JSONValue.parseObjectJSON(try XCTUnwrap(echoedCookies.valueJSON))
        let serverCookies = parsed["serverCookies"]?.stringValue ?? ""
        let jsCookies = parsed["jsCookies"]?.stringValue ?? ""
        XCTAssertTrue(serverCookies.contains("forum_session=signed-in-token-42"), "Server received session cookie in tab 2: \(serverCookies)")
        XCTAssertTrue(serverCookies.contains("reader_theme=sepia"), "Server received theme cookie in tab 2: \(serverCookies)")
        XCTAssertTrue(jsCookies.contains("reader_theme=sepia"), "JS cookie carried over to tab 2: \(jsCookies)")
    }

    func testRunStartedInTabAKeepsDrivingTabAAfterSwitchingToTabB() async throws {
        let tabA = app.tabs.currentTab
        tabA.browser.load(server.url("/tab-a"))
        try await waitUntil(description: "tab A loaded") {
            tabA.browser.pageTitle == "Alpha Page" && !tabA.browser.isLoading
        }

        let tabB = try XCTUnwrap(app.tabs.openTab(url: server.url("/tab-b"), inFront: false))
        try await waitUntil(description: "tab B loaded in background") {
            tabB.browser.pageTitle == "Beta Page" && !tabB.browser.isLoading
        }
        XCTAssertEqual(app.tabs.currentTabID, tabA.id)

        let step2URL = server.url("/tab-a-step2")
        let client = TabBoundAgentClient(step2DestinationURL: step2URL.absoluteString)
        tabA.agentSession.configureDebugModelClient(client)

        // Start the Agent run in tab A, wait until turn 1 begins, then switch active tab to tab B.
        tabA.agentSession.send("Update Alpha and navigate to step 2")
        await client.step1Started.wait()

        XCTAssertTrue(app.tabs.switchToTab(id: tabB.id))
        XCTAssertEqual(app.tabs.currentTabID, tabB.id)
        XCTAssertTrue(app.browser === tabB.browser)
        XCTAssertTrue(app.browserAgent === tabB.agentSession)
        XCTAssertFalse(app.browserAgent.isRunning, "Tab B's own session is idle while Tab A runs")

        // Let Tab A's run continue (run_js DOM mutation + navigate) while Tab B stays active in front.
        await client.allowStep2.open()
        await tabA.agentSession.waitForActiveRun()

        // Tab A's run completed against Tab A's page and navigated Tab A to /tab-a-step2.
        XCTAssertEqual(tabA.agentSession.runs.last?.assistantText, "Completed work on Tab A.")
        let toolResults = tabA.agentSession.toolCalls
        XCTAssertEqual(toolResults.map(\.toolName), ["read_page", "run_js", "navigate"])
        XCTAssertTrue(toolResults[0].resultText.contains("Alpha Page"), "read_page read Tab A: \(toolResults[0].resultText)")
        XCTAssertTrue(toolResults[1].resultText.contains("Alpha Page"), "run_js ran in Tab A: \(toolResults[1].resultText)")
        XCTAssertEqual(tabA.browser.currentURL, step2URL)
        XCTAssertEqual(tabA.browser.pageTitle, "Alpha Step Two")

        // Meanwhile Tab B (still active) was never touched by Tab A's tools or background navigation.
        XCTAssertEqual(app.tabs.currentTabID, tabB.id)
        XCTAssertEqual(app.browser.currentURL, server.url("/tab-b"))
        let tabBTarget = try await tabB.browser.agentBridge.runJS(
            code: "return document.getElementById('target').textContent;",
            environment: .isolated
        )
        XCTAssertEqual(tabBTarget.valueJSON, #""untouched""#)
    }

    func testClosingTabWithRunningAgentStopsItsRun() async throws {
        let tab1 = app.tabs.currentTab
        tab1.browser.load(server.url("/tab-a"))
        try await waitUntil(description: "tab 1 loaded") {
            tab1.browser.pageTitle == "Alpha Page" && !tab1.browser.isLoading
        }

        let client = TabBoundAgentClient(step2DestinationURL: server.url("/tab-a-step2").absoluteString)
        tab1.agentSession.configureDebugModelClient(client)
        tab1.agentSession.send("Long running task")
        await client.step1Started.wait()
        XCTAssertTrue(tab1.agentSession.isRunning)

        XCTAssertTrue(app.tabs.closeTab(id: tab1.id))
        XCTAssertFalse(tab1.agentSession.isRunning, "Closing a tab stops its in-flight Agent run")
    }

    func testTargetBlankOpensNewFrontTabAfterCurrentTabAndBlocksAutoWindowOpen() async throws {
        let tab1 = app.tabs.currentTab
        let trailingTab = try XCTUnwrap(app.tabs.openTab(url: server.url("/tab-b"), inFront: false))
        XCTAssertEqual(app.tabs.tabs.map(\.id), [tab1.id, trailingTab.id])
        XCTAssertEqual(app.tabs.currentTabID, tab1.id)

        // /opener runs an automatic window.open('/auto-popup') on load (no user gesture).
        tab1.browser.load(server.url("/opener"))
        try await waitUntil(description: "opener page loaded") {
            tab1.browser.pageTitle == "Opener Page" && !tab1.browser.isLoading
        }

        // Non-gesture window.open must be blocked by WKWebView and open no tab.
        let autoPopupCheck = try await tab1.browser.agentBridge.runJS(
            code: "return window.autoPopupResult === null;",
            environment: .page
        )
        XCTAssertEqual(autoPopupCheck.valueJSON, "true")
        XCTAssertEqual(app.tabs.tabs.map(\.id), [tab1.id, trailingTab.id])

        // Clicking <a target="_blank"> opens a new front tab right after tab1 (before trailingTab).
        _ = try await tab1.browser.webView.evaluateJavaScript("document.getElementById('blank-link').click();")

        try await waitUntil(description: "target=_blank opened new front tab") {
            self.app.tabs.tabs.count == 3
                && self.app.tabs.currentTabID != tab1.id
                && self.app.browser.pageTitle == "Opened Blank Tab"
                && !self.app.browser.isLoading
        }

        let blankTab = app.tabs.currentTab
        XCTAssertEqual(
            app.tabs.tabs.map(\.id),
            [tab1.id, blankTab.id, trailingTab.id],
            "New tab from target=_blank opens immediately after the source tab, in front"
        )
        XCTAssertEqual(blankTab.browser.currentURL, server.url("/opened-blank"))
        XCTAssertEqual(tab1.browser.currentURL, server.url("/opener"), "Opener tab stayed on /opener")
    }

    func testVoiceHandOffTargetsActiveTabAndTracksInFlightSessionAcrossTabSwitch() async throws {
        let tab1 = app.tabs.currentTab
        tab1.browser.load(server.url("/tab-a"))
        try await waitUntil(description: "tab 1 loaded") {
            tab1.browser.pageTitle == "Alpha Page" && !tab1.browser.isLoading
        }

        let tab2 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tab-b")))
        try await waitUntil(description: "tab 2 loaded") {
            tab2.browser.pageTitle == "Beta Page" && !tab2.browser.isLoading
        }
        XCTAssertEqual(app.tabs.currentTabID, tab2.id)

        let client = TabBoundAgentClient(step2DestinationURL: server.url("/tab-a-step2").absoluteString)
        tab2.agentSession.configureDebugModelClient(client)

        // Start a voice hand-off while tab 2 is active, then switch to tab 1 mid-run.
        XCTAssertNil(app.startHandOff("Inspect Beta from voice"))
        await client.step1Started.wait()
        XCTAssertTrue(app.isHandingOff)
        XCTAssertTrue(tab2.agentSession.isRunning)
        XCTAssertFalse(tab1.agentSession.isRunning)

        XCTAssertTrue(app.tabs.switchToTab(id: tab1.id))
        XCTAssertTrue(app.isHandingOff, "In-flight voice hand-off tracks the tab session it started in")

        await client.allowStep2.open()
        let outcome = await app.handOffOutcome()
        if case .answered(let answer) = outcome {
            XCTAssertEqual(answer, "Completed work on Tab A.")
        } else {
            XCTFail("Expected .answered outcome, got \(outcome)")
        }
        XCTAssertFalse(app.isHandingOff)
        XCTAssertEqual(tab2.agentSession.runs.count, 1)
        XCTAssertTrue(tab1.agentSession.runs.isEmpty)
    }

    // MARK: - T2: Saved Tabs, Limits, Memory Unload, and Window Host

    private func makeSolidImage(color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 64))
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 64))
        }
    }

    private func makeRestorableApp(store: PersistentStore) -> AppModel {
        let created = AppModel(
            store: store,
            browser: nil,
            websiteDataStore: Self.sharedDataStore,
            cloudSync: CloudSyncController(transport: nil, files: nil, defaults: nil, schedulesAutomatically: false),
            podcastDirectory: tempDir.appendingPathComponent("Podcasts", isDirectory: true),
            workspaceDirectory: tempDir.appendingPathComponent("Workspace", isDirectory: true),
            spotlightIndex: FakeSpotlightIndex(),
            topicActivityDonor: FakeTopicActivityDonor(),
            backgroundGrace: NoOpBackgroundGrace()
        )
        created.usesDirectForumRequests = true
        var anthropic = created.settings.configuration(for: .anthropic)
        anthropic.apiKey = "test-key"
        anthropic.model = "claude-haiku-5-5"
        created.settings.setConfiguration(anthropic, for: .anthropic)
        created.settings.setModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .browserAgent)
        return created
    }

    func testSavedSetOfFiveTabsRestoresOrderCurrentTabAndLoadsOnlyCurrentTabLazily() async throws {
        let persistenceDir = tempDir.appendingPathComponent("RestoreSuite", isDirectory: true)
        try FileManager.default.createDirectory(at: persistenceDir, withIntermediateDirectories: true)
        let sharedStore = PersistentStore(
            fileURL: persistenceDir.appendingPathComponent("state.json"),
            keys: InMemoryProviderKeyStore()
        )

        var app1: AppModel? = makeRestorableApp(store: sharedStore)
        let first = try XCTUnwrap(app1)
        mountTabsWebHost(for: first)

        // Tab 1: tall page 1, scrolled to y=320, snapshot + finished conversation.
        let t1 = first.tabs.currentTab
        t1.browser.load(server.url("/tall/1"))
        try await waitUntil(description: "t1 loaded /tall/1") {
            t1.browser.pageTitle == "Tall Tab 1" && !t1.browser.isLoading
        }
        _ = try await t1.browser.webView.evaluateJavaScript("window.scrollTo(0, 320);")
        t1.browser.setSavedScrollPosition(CGPoint(x: 0, y: 320))
        t1.snapshot = makeSolidImage(color: .systemBlue)
        t1.agentSession.configureDebugModelClient(
            RecordedModelClient([.success(AgentModelTurnResponse(text: "Reply on Tab 1."))])
        )
        await t1.agentSession.sendAndWait("Question on Tab 1")

        // Tab 2: Home tab (nil URL), voice turn in conversation.
        let t2 = try XCTUnwrap(first.tabs.openTab(url: nil, inFront: true))
        XCTAssertTrue(t2.showsHome)
        t2.agentSession.appendVoiceTurn(.voiceUser, text: "Hello from Home tab")

        // Tab 3: tall page 3, scrolled to y=460, active run in flight when the app quits.
        let t3 = try XCTUnwrap(first.tabs.openTab(url: server.url("/tall/3"), inFront: true))
        try await waitUntil(description: "t3 loaded /tall/3") {
            t3.browser.pageTitle == "Tall Tab 3" && !t3.browser.isLoading
        }
        _ = try await t3.browser.webView.evaluateJavaScript("window.scrollTo(0, 460);")
        t3.browser.setSavedScrollPosition(CGPoint(x: 0, y: 460))
        t3.snapshot = makeSolidImage(color: .systemGreen)

        // Tab 4: tall page 4, scrolled to y=610, snapshot + finished conversation.
        let t4 = try XCTUnwrap(first.tabs.openTab(url: server.url("/tall/4"), inFront: true))
        try await waitUntil(description: "t4 loaded /tall/4") {
            t4.browser.pageTitle == "Tall Tab 4" && !t4.browser.isLoading
        }
        _ = try await t4.browser.webView.evaluateJavaScript("window.scrollTo(0, 610);")
        t4.browser.setSavedScrollPosition(CGPoint(x: 0, y: 610))
        t4.snapshot = makeSolidImage(color: .systemOrange)
        t4.agentSession.configureDebugModelClient(
            RecordedModelClient([.success(AgentModelTurnResponse(text: "Reply on Tab 4."))])
        )
        await t4.agentSession.sendAndWait("Question on Tab 4")

        // Tab 5: tall page 5, snapshot + finished conversation.
        let t5 = try XCTUnwrap(first.tabs.openTab(url: server.url("/tall/5"), inFront: true))
        try await waitUntil(description: "t5 loaded /tall/5") {
            t5.browser.pageTitle == "Tall Tab 5" && !t5.browser.isLoading
        }
        t5.snapshot = makeSolidImage(color: .systemPurple)
        t5.agentSession.configureDebugModelClient(
            RecordedModelClient([.success(AgentModelTurnResponse(text: "Reply on Tab 5."))])
        )
        await t5.agentSession.sendAndWait("Question on Tab 5")

        // Switch back to Tab 3 so Tab 3 is the current tab, and start a run that stays running at quit.
        XCTAssertTrue(first.tabs.switchToTab(id: t3.id))
        t3.browser.setSavedScrollPosition(CGPoint(x: 0, y: 460))
        let inFlightClient = TabBoundAgentClient(step2DestinationURL: server.url("/tab-a-step2").absoluteString)
        t3.agentSession.configureDebugModelClient(inFlightClient)
        t3.agentSession.send("Keep running across quit")
        await inFlightClient.step1Started.wait()
        try await waitUntil(description: "t3 step 1 tool row recorded") {
            !t3.agentSession.toolCalls.isEmpty && t3.agentSession.isRunning
        }

        let expectedIDs = [t1.id, t2.id, t3.id, t4.id, t5.id]
        let expectedConversationIDs = first.tabs.tabs.map(\.conversationID)
        first.flushPendingSaves()

        // Simulate app termination without calling user stop() before saving: tear down old instance
        // after detaching persistence so the on-disk state keeps the in-flight `.running` state!
        first.suppressesPersistence = true
        tearDownApp(first)
        app1 = nil
        server.resetRequestLog()

        // Relaunch from the same store.
        let app2 = makeRestorableApp(store: sharedStore)
        addTeardownBlock { @MainActor [weak self] in
            self?.tearDownApp(app2)
        }
        mountTabsWebHost(for: app2)

        XCTAssertEqual(app2.tabs.tabs.map(\.id), expectedIDs, "All 5 tabs restore in exact saved order")
        XCTAssertEqual(app2.tabs.currentTabID, "t3", "Saved front tab restores as currentTab")
        XCTAssertEqual(app2.tabs.tabs.map(\.conversationID), expectedConversationIDs, "Conversation IDs restore 1:1")

        let r1 = try XCTUnwrap(app2.tabs.tab(id: "t1"))
        let r2 = try XCTUnwrap(app2.tabs.tab(id: "t2"))
        let r3 = try XCTUnwrap(app2.tabs.tab(id: "t3"))
        let r4 = try XCTUnwrap(app2.tabs.tab(id: "t4"))
        let r5 = try XCTUnwrap(app2.tabs.tab(id: "t5"))

        // Only the current tab (r3) allocated a WKWebView and loaded over the network.
        XCTAssertTrue(r3.isWebViewLoaded)
        XCTAssertFalse(r1.isWebViewLoaded)
        XCTAssertNil(r1.browser.existingWebView)
        XCTAssertFalse(r2.isWebViewLoaded)
        XCTAssertNil(r2.browser.existingWebView)
        XCTAssertFalse(r4.isWebViewLoaded)
        XCTAssertNil(r4.browser.existingWebView)
        XCTAssertFalse(r5.isWebViewLoaded)
        XCTAssertNil(r5.browser.existingWebView)

        try await waitUntil(description: "restored current tab r3 finished loading /tall/3") {
            r3.browser.pageTitle == "Tall Tab 3" && !r3.browser.isLoading
        }
        try await waitUntil(description: "restored current tab r3 restored scroll y=460") {
            let y = (try? await r3.browser.webView.evaluateJavaScript("window.scrollY")) as? Double ?? 0
            return abs(y - 460) < 5
        }
        XCTAssertEqual(
            Set(server.requestedPaths),
            ["/tall/3"],
            "Only the restored current tab loaded over HTTP; background tabs made zero requests"
        )

        // Unloaded background tabs still expose their saved URL, title, snapshot, scroll, and conversation.
        XCTAssertEqual(r1.url, server.url("/tall/1"))
        XCTAssertEqual(r1.title, "Tall Tab 1")
        XCTAssertEqual(r1.scrollPosition.y, 320, accuracy: 1)
        XCTAssertNotNil(r1.snapshot)
        XCTAssertEqual(r1.agentSession.runs.first?.assistantText, "Reply on Tab 1.")

        XCTAssertNil(r2.url)
        XCTAssertTrue(r2.showsHome)
        XCTAssertEqual(r2.agentSession.voiceTurns.first?.text, "Hello from Home tab")

        XCTAssertEqual(r4.url, server.url("/tall/4"))
        XCTAssertEqual(r4.title, "Tall Tab 4")
        XCTAssertEqual(r4.scrollPosition.y, 610, accuracy: 1)
        XCTAssertNotNil(r4.snapshot)
        XCTAssertEqual(r4.agentSession.runs.first?.assistantText, "Reply on Tab 4.")

        XCTAssertEqual(r5.url, server.url("/tall/5"))
        XCTAssertEqual(r5.title, "Tall Tab 5")
        XCTAssertNotNil(r5.snapshot)
        XCTAssertEqual(r5.agentSession.runs.first?.assistantText, "Reply on Tab 5.")

        // The run that was going in r3 when the app quit came back stopped.
        XCTAssertFalse(r3.agentSession.isRunning)
        if case .stopped = r3.agentSession.runState {
            // expected
        } else {
            XCTFail("Expected in-flight run to restore as .stopped, got \(r3.agentSession.runState)")
        }
        if case .stopped = r3.agentSession.runs.last?.state {
            // expected
        } else {
            XCTFail("Expected last run record to restore as .stopped, got \(String(describing: r3.agentSession.runs.last?.state))")
        }
        XCTAssertTrue(r3.agentSession.toolCalls.allSatisfy { !$0.isRunning })

        // Switching to unloaded r4 loads its page lazily and restores its saved scroll position.
        XCTAssertTrue(app2.tabs.switchToTab(id: "t4"))
        XCTAssertTrue(r4.isWebViewLoaded)
        XCTAssertFalse(r1.isWebViewLoaded, "Other background tabs stay unloaded")
        XCTAssertFalse(r5.isWebViewLoaded, "Other background tabs stay unloaded")
        try await waitUntil(description: "r4 lazily loaded /tall/4 and restored scroll y=610") {
            guard r4.browser.pageTitle == "Tall Tab 4", !r4.browser.isLoading else { return false }
            let y = (try? await r4.browser.webView.evaluateJavaScript("window.scrollY")) as? Double ?? 0
            return abs(y - 610) < 5
        }

        // Starting a "New conversation" in r4 rotates its conversationID and clears saved turns.
        let oldConvID = r4.conversationID
        r4.agentSession.resetConversation()
        XCTAssertNotEqual(r4.conversationID, oldConvID)
        app2.flushPendingSaves()
        XCTAssertNil(app2.tabStateStore.loadConversation(id: oldConvID))
    }

    func testThirtyFirstOpenIsRefusedForBothPersonAndTool() async throws {
        XCTAssertEqual(app.tabs.tabs.count, 1)
        let openerTab = app.tabs.currentTab
        openerTab.browser.load(server.url("/opener"))
        try await waitUntil(description: "opener loaded") {
            openerTab.browser.pageTitle == "Opener Page" && !openerTab.browser.isLoading
        }

        for _ in 2...BrowserTabs.maxTabs {
            XCTAssertNotNil(app.tabs.openTab(inFront: false))
        }
        XCTAssertEqual(app.tabs.tabs.count, 30)
        XCTAssertFalse(app.tabs.canOpenTab)
        XCTAssertEqual(BrowserTabs.personTabLimitMessage, "30 tabs open. Close one to open another")

        server.resetRequestLog()

        // 1. Person open via New Tab (`openTab`): refused at 30 tabs.
        XCTAssertNil(app.tabs.openTab(url: server.url("/tab-b"), inFront: true))
        XCTAssertEqual(app.tabs.tabs.count, 30)
        XCTAssertTrue(server.requestedPaths.isEmpty)

        // 2. Person open via `<a target="_blank">` in the active opener tab: refused at 30 tabs.
        XCTAssertEqual(app.tabs.currentTabID, openerTab.id)
        _ = try await openerTab.browser.webView.evaluateJavaScript("document.getElementById('blank-link').click();")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(app.tabs.tabs.count, 30, "target=_blank opens nothing at 30 tabs")
        XCTAssertFalse(server.requestedPaths.contains("/opened-blank"))

        // 3. Tool open (`openTabForTool`): fails with exact error "Tab limit reached: 30 open".
        let toolAttempt = app.tabs.openTabForTool(url: server.url("/tab-b"))
        switch toolAttempt {
        case .success(let unexpected):
            XCTFail("Expected 31st tool open to fail, got tab \(unexpected.id)")
        case .failure(let error):
            XCTAssertEqual(error.localizedDescription, "Tab limit reached: 30 open")
        }
        XCTAssertEqual(app.tabs.tabs.count, 30)
        XCTAssertTrue(server.requestedPaths.isEmpty)

        // Closing one tab frees a slot so the tool can open a 30th tab in the background.
        let closedID = app.tabs.tabs.last!.id
        XCTAssertTrue(app.tabs.closeTab(id: closedID))
        XCTAssertEqual(app.tabs.tabs.count, 29)
        XCTAssertTrue(app.tabs.canOpenTab)

        let reopened = try app.tabs.openTabForTool(url: server.url("/tab-b")).get()
        XCTAssertEqual(app.tabs.tabs.count, 30)
        XCTAssertEqual(app.tabs.currentTabID, openerTab.id, "Tool-opened tab opens in background by default")
        try await waitUntil(description: "tool-opened 30th tab loaded /tab-b") {
            reopened.browser.pageTitle == "Beta Page" && !reopened.browser.isLoading
        }
    }

    func testSimulatedMemoryWarningUnloadsIdleBackgroundTabsButNotRunningAgentTab() async throws {
        // Tab 1: idle background tab with scroll position, snapshot, and conversation.
        let tab1 = app.tabs.currentTab
        tab1.browser.load(server.url("/tall/1"))
        try await waitUntil(description: "tab 1 loaded") {
            tab1.browser.pageTitle == "Tall Tab 1" && !tab1.browser.isLoading
        }
        _ = try await tab1.browser.webView.evaluateJavaScript("window.scrollTo(0, 380);")
        tab1.browser.setSavedScrollPosition(CGPoint(x: 0, y: 380))
        tab1.snapshot = makeSolidImage(color: .systemTeal)
        tab1.agentSession.configureDebugModelClient(
            RecordedModelClient([.success(AgentModelTurnResponse(text: "Tab 1 memory reply."))])
        )
        await tab1.agentSession.sendAndWait("Remember Tab 1")

        // Tab 2: background tab with an active Agent run.
        let tab2 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tab-a"), inFront: true))
        try await waitUntil(description: "tab 2 loaded") {
            tab2.browser.pageTitle == "Alpha Page" && !tab2.browser.isLoading
        }

        // Tab 3: another idle background tab.
        let tab3 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tall/3"), inFront: true))
        try await waitUntil(description: "tab 3 loaded") {
            tab3.browser.pageTitle == "Tall Tab 3" && !tab3.browser.isLoading
        }

        // Tab 4: current front tab.
        let tab4 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tab-b"), inFront: true))
        try await waitUntil(description: "tab 4 loaded") {
            tab4.browser.pageTitle == "Beta Page" && !tab4.browser.isLoading
        }
        XCTAssertEqual(app.tabs.currentTabID, tab4.id)

        // Start an Agent run in background Tab 2.
        let runningClient = TabBoundAgentClient(step2DestinationURL: server.url("/tab-a-step2").absoluteString)
        tab2.agentSession.configureDebugModelClient(runningClient)
        tab2.agentSession.send("Modify Alpha while in background")
        await runningClient.step1Started.wait()
        XCTAssertTrue(tab2.agentSession.isRunning)

        // Post UIKit's real memory warning notification.
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: UIApplication.shared
        )

        // Idle background tabs (tab1, tab3) dropped their WKWebView while keeping metadata & conversation.
        XCTAssertFalse(tab1.isWebViewLoaded)
        XCTAssertNil(tab1.browser.existingWebView)
        XCTAssertEqual(tab1.url, server.url("/tall/1"))
        XCTAssertEqual(tab1.title, "Tall Tab 1")
        XCTAssertEqual(tab1.scrollPosition.y, 380, accuracy: 1)
        XCTAssertNotNil(tab1.snapshot)
        XCTAssertEqual(tab1.agentSession.runs.first?.assistantText, "Tab 1 memory reply.")

        XCTAssertFalse(tab3.isWebViewLoaded)
        XCTAssertNil(tab3.browser.existingWebView)
        XCTAssertEqual(tab3.url, server.url("/tall/3"))
        XCTAssertEqual(tab3.title, "Tall Tab 3")

        // Running background tab (tab2) and current tab (tab4) were NOT unloaded!
        XCTAssertTrue(tab2.isWebViewLoaded, "Running background tab must never unload under memory pressure")
        XCTAssertNotNil(tab2.browser.existingWebView)
        XCTAssertTrue(tab2.agentSession.isRunning)
        XCTAssertTrue(tab4.isWebViewLoaded, "Current front tab must not unload")

        // Let tab2 finish its background Agent run and verify its DOM/navigation succeeded.
        await runningClient.allowStep2.open()
        await tab2.agentSession.waitForActiveRun()
        XCTAssertEqual(tab2.agentSession.runs.last?.assistantText, "Completed work on Tab A.")
        XCTAssertEqual(tab2.browser.currentURL, server.url("/tab-a-step2"))

        // Switching back to unloaded tab1 reloads its page, restores scroll, and reattaches AgentBridge.
        XCTAssertTrue(app.tabs.switchToTab(id: tab1.id))
        XCTAssertTrue(tab1.isWebViewLoaded)
        try await waitUntil(description: "tab1 reloaded /tall/1 and restored scroll y=380") {
            guard tab1.browser.pageTitle == "Tall Tab 1", !tab1.browser.isLoading else { return false }
            let y = (try? await tab1.browser.webView.evaluateJavaScript("window.scrollY")) as? Double ?? 0
            return abs(y - 380) < 5
        }
        let bridgeCheck = try await tab1.browser.agentBridge.runJS(
            code: "return document.getElementById('target').textContent;",
            environment: .isolated
        )
        XCTAssertEqual(bridgeCheck.valueJSON, #""content-1""#)
    }

    func testFourthConcurrentRunIsRefusedUntilARunningTabStopsOrCompletes() async throws {
        let tab1 = app.tabs.currentTab
        let tab2 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tab-a"), inFront: false))
        let tab3 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tab-b"), inFront: false))
        let tab4 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tall/4"), inFront: true))

        tab1.browser.load(server.url("/tall/1"))
        try await waitUntil(description: "all 4 tabs settled") {
            !tab1.browser.isLoading && !tab2.browser.isLoading && !tab3.browser.isLoading && !tab4.browser.isLoading
        }

        let client1 = TabBoundAgentClient(step2DestinationURL: server.url("/tab-a-step2").absoluteString)
        let client2 = TabBoundAgentClient(step2DestinationURL: server.url("/tab-a-step2").absoluteString)
        let client3 = TabBoundAgentClient(step2DestinationURL: server.url("/tab-a-step2").absoluteString)
        tab1.agentSession.configureDebugModelClient(client1)
        tab2.agentSession.configureDebugModelClient(client2)
        tab3.agentSession.configureDebugModelClient(client3)
        tab4.agentSession.configureDebugModelClient(
            RecordedModelClient([.success(AgentModelTurnResponse(text: "Tab 4 ran once a slot freed."))])
        )

        tab1.agentSession.send("Run 1")
        tab2.agentSession.send("Run 2")
        tab3.agentSession.send("Run 3")
        await client1.step1Started.wait()
        await client2.step1Started.wait()
        await client3.step1Started.wait()

        XCTAssertEqual(app.tabs.runningTabCount, 3)
        XCTAssertFalse(app.tabs.canStartRun(forTabID: tab4.id))

        // Attempt a 4th run in tab4 (both typed send and voice hand-off): refused!
        tab4.agentSession.send("Run 4 should be refused")
        XCTAssertFalse(tab4.agentSession.isRunning)
        XCTAssertTrue(tab4.agentSession.runs.isEmpty)
        XCTAssertTrue(tab4.agentSession.messages.isEmpty)
        XCTAssertEqual(tab4.agentSession.runLimitNotice, "3 runs are going. Wait for one or stop it")

        let voiceRefusal = app.startHandOff("Voice run 4")
        XCTAssertEqual(voiceRefusal, "3 runs are going. Wait for one or stop it")
        XCTAssertFalse(tab4.agentSession.isRunning)

        // Stop tab1's run: runningTabCount drops to 2, tab4's notice clears, and tab4 can now run.
        tab1.agentSession.stop()
        XCTAssertEqual(app.tabs.runningTabCount, 2)
        XCTAssertNil(tab4.agentSession.runLimitNotice)

        await tab4.agentSession.sendAndWait("Run 4 after slot opened")
        XCTAssertEqual(tab4.agentSession.runs.first?.assistantText, "Tab 4 ran once a slot freed.")

        tab2.agentSession.stop()
        tab3.agentSession.stop()
    }

    func testAlphaZeroBackgroundRunningTabKeepsTimersAndJSRunningInWindow() async throws {
        let tab1 = app.tabs.currentTab
        tab1.browser.load(server.url("/timers"))
        try await waitUntil(description: "timer page loaded in tab 1") {
            tab1.browser.pageTitle == "Timer Page" && !tab1.browser.isLoading
        }

        let tab2 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tab-b"), inFront: false))
        try await waitUntil(description: "tab 2 loaded") {
            tab2.browser.pageTitle == "Beta Page" && !tab2.browser.isLoading
        }

        // Start a run in tab1 so BrowserTabsWebHostView keeps tab1's WKWebView in the UIWindow
        // with alpha = 0, isHidden = false, isUserInteractionEnabled = false when tab2 is in front.
        let client1 = TabBoundAgentClient(step2DestinationURL: server.url("/tab-a-step2").absoluteString)
        tab1.agentSession.configureDebugModelClient(client1)
        tab1.agentSession.send("Keep tab 1 running while tab 2 is in front")
        await client1.step1Started.wait()

        XCTAssertTrue(app.tabs.switchToTab(id: tab2.id))
        XCTAssertEqual(app.tabs.currentTabID, tab2.id)

        // Verify window attachment & styling of both web views.
        let bgWebView = try XCTUnwrap(tab1.browser.existingWebView)
        let frontWebView = try XCTUnwrap(tab2.browser.existingWebView)
        XCTAssertNotNil(bgWebView.window, "Running background tab's WKWebView must remain attached to UIWindow")
        XCTAssertFalse(bgWebView.isHidden, "Running background tab's WKWebView must keep isHidden = false")
        XCTAssertEqual(bgWebView.alpha, 0, accuracy: 0.001, "Running background tab's WKWebView must have alpha = 0")
        XCTAssertFalse(bgWebView.isUserInteractionEnabled, "Running background tab's WKWebView must disable user interaction")
        XCTAssertNotNil(frontWebView.window)
        XCTAssertEqual(frontWebView.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(webHostView.subviews.last, frontWebView, "Current tab's WKWebView stays in front")

        let baselineRaw = try await bgWebView.evaluateJavaScript("({ i: window.__intervalTicks, t: window.__timeoutTicks })") as? [String: Int]
        let startInterval = try XCTUnwrap(baselineRaw?["i"])
        let startTimeout = try XCTUnwrap(baselineRaw?["t"])

        // Keep tab2 in front for 1.5s and verify setInterval, setTimeout, and async JS keep running unthrottled in tab1.
        try await Task.sleep(for: .milliseconds(1500))

        let afterRaw = try await bgWebView.evaluateJavaScript("({ i: window.__intervalTicks, t: window.__timeoutTicks })") as? [String: Int]
        let endInterval = try XCTUnwrap(afterRaw?["i"])
        let endTimeout = try XCTUnwrap(afterRaw?["t"])
        XCTAssertGreaterThanOrEqual(
            endInterval - startInterval,
            12,
            "alpha=0 windowed background tab kept setInterval ticking (\(startInterval) -> \(endInterval))"
        )
        XCTAssertGreaterThanOrEqual(
            endTimeout - startTimeout,
            12,
            "alpha=0 windowed background tab kept setTimeout ticking (\(startTimeout) -> \(endTimeout))"
        )

        let jsTimerProbe = try await tab1.browser.agentBridge.runJS(
            code: "await new Promise(r => setTimeout(r, 80)); return window.__intervalTicks;",
            environment: .page
        )
        XCTAssertNotNil(jsTimerProbe.valueJSON)

        // Once tab1's run ends, BrowserTabsWebHostView detaches tab1's WKWebView from the window.
        tab1.agentSession.stop()
        XCTAssertNil(bgWebView.window, "Once the background run stops, its WKWebView is removed from the window")
    }

    func testScrollingUpdatesScrollPositionWithoutRepublishingBrowserModelEveryTick() async throws {
        let tab1 = app.tabs.currentTab
        tab1.browser.load(server.url("/tall/1"))
        try await waitUntil(description: "tall page loaded and probed") {
            tab1.browser.pageTitle == "Tall Tab 1"
                && !tab1.browser.isLoading
                && tab1.browser.pageContext.url == self.server.url("/tall/1")
        }
        let webView = try XCTUnwrap(tab1.browser.existingWebView)
        try? await Task.sleep(for: .milliseconds(100))

        var publishCount = 0
        let sub = tab1.browser.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { sub.cancel() }

        // Scroll through several sub-threshold offsets (< chromeToggleTravel = 36):
        // scrollPosition updates continuously, while objectWillChange stays silent.
        for y in [4, 8, 12, 16, 20] {
            _ = try await webView.evaluateJavaScript("window.scrollTo(0, \(y));")
            try await Task.sleep(for: .milliseconds(20))
        }
        try await waitUntil(description: "scrollPosition updated to 20") {
            abs(tab1.browser.scrollPosition.y - 20) <= 2
        }
        XCTAssertEqual(
            publishCount,
            0,
            "Sub-threshold scroll ticks must not fire ForumBrowserModel.objectWillChange"
        )
    }

    func testRestoredTabsStillHonorAutomaticLaunchRuleAndPruneOrphanSidecars() async throws {
        let defaults = UserDefaults.standard
        let previousDayValue = defaults.object(forKey: LaunchRule.lastHomeAutoShownDayKey)
        defer {
            if let previousDayValue {
                defaults.set(previousDayValue, forKey: LaunchRule.lastHomeAutoShownDayKey)
            } else {
                defaults.removeObject(forKey: LaunchRule.lastHomeAutoShownDayKey)
            }
        }

        let tab1 = app.tabs.currentTab
        tab1.browser.load(server.url("/tall/1"))
        try await waitUntil(description: "tab 1 loaded") {
            tab1.browser.pageTitle == "Tall Tab 1" && !tab1.browser.isLoading
        }
        let tab2 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tall/2"), inFront: true))
        try await waitUntil(description: "tab 2 loaded") {
            tab2.browser.pageTitle == "Tall Tab 2" && !tab2.browser.isLoading
        }

        var doneCard = DigestCard(
            siteURL: "https://forum.example.com",
            topicID: "42",
            title: "Morning briefing",
            slug: nil,
            reason: .trending,
            postCount: 8
        )
        doneCard.state = .done
        doneCard.summary = "Ready summary."
        app.digests = [DailyDigest(day: app.todayKey, cards: [doneCard])]
        app.saveDigests()
        app.settings.hasCompletedOnboarding = true
        app.settings.launchDestination = .automatic

        // Seed orphan sidecar files alongside the live tabs before relaunch.
        let orphanConvID = UUID()
        var orphanConv = tab1.agentSession.exportConversation()
        orphanConv.messages = [BrowserAgentMessage(role: .user, text: "Orphan message")]
        app.tabStateStore.saveConversation(orphanConv, id: orphanConvID)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let orphanImage = renderer.image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        app.tabStateStore.saveSnapshot(orphanImage, tabID: "t99")

        await app.flushPendingSaves()
        XCTAssertNotNil(app.tabStateStore.loadConversation(id: orphanConvID))
        XCTAssertNotNil(app.tabStateStore.loadSnapshot(tabID: "t99"))

        tearDownApp(app)
        app = nil

        defaults.set("2020-01-01", forKey: LaunchRule.lastHomeAutoShownDayKey)

        let relaunchStore = PersistentStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            keys: InMemoryProviderKeyStore([.anthropic: "test-key"])
        )
        let relaunched = AppModel(
            store: relaunchStore,
            websiteDataStore: Self.sharedDataStore,
            cloudSync: CloudSyncController(transport: nil, files: nil, defaults: nil, schedulesAutomatically: false),
            podcastDirectory: tempDir.appendingPathComponent("Podcasts", isDirectory: true),
            workspaceDirectory: tempDir.appendingPathComponent("Workspace", isDirectory: true),
            spotlightIndex: FakeSpotlightIndex(),
            topicActivityDonor: FakeTopicActivityDonor(),
            backgroundGrace: NoOpBackgroundGrace()
        )
        relaunched.usesDirectForumRequests = true
        self.app = relaunched
        mountTabsWebHost(for: relaunched)

        // Orphan sidecar files were pruned on launch restore.
        XCTAssertNil(relaunched.tabStateStore.loadConversation(id: orphanConvID))
        XCTAssertNil(relaunched.tabStateStore.loadSnapshot(tabID: "t99"))

        // Automatic launch rule still shows Home on the day's first launch over the restored current tab.
        XCTAssertEqual(relaunched.tabs.tabs.map(\.id), ["t1", "t2"])
        XCTAssertEqual(relaunched.tabs.currentTabID, "t2")
        relaunched.applyLaunchRuleIfNeeded(now: Date())
        XCTAssertTrue(
            relaunched.browser.showsForumsHome,
            "Automatic launch rule must still present Home on the day's first launch when tabs were restored"
        )

        // Saving while the launch Home overlay is up preserves t2's underlying page URL.
        let exportedT2 = try XCTUnwrap(relaunched.tabs.exportState().tabs.first(where: { $0.id == "t2" }))
        XCTAssertEqual(exportedT2.url, server.url("/tall/2"))
    }

    // MARK: - T3: Reorder, Shortcuts, Long-Press Menu, Close-to-History + Undo, VoiceOver

    func testReorderMoveEarlierMoveLaterAndCtrlTabCycle() throws {
        let t1 = app.tabs.currentTab
        let t2 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tall/2"), inFront: false))
        let t3 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tall/3"), inFront: false))
        let t4 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tall/4"), inFront: false))
        XCTAssertEqual(app.tabs.tabs.map(\.id), [t1.id, t2.id, t3.id, t4.id])

        // Boundary no-ops.
        XCTAssertFalse(app.tabs.moveTabEarlier(id: t1.id))
        XCTAssertFalse(app.tabs.moveTabLater(id: t4.id))

        // Move later and move earlier.
        XCTAssertTrue(app.tabs.moveTabLater(id: t1.id))
        XCTAssertEqual(app.tabs.tabs.map(\.id), [t2.id, t1.id, t3.id, t4.id])
        XCTAssertTrue(app.tabs.moveTabEarlier(id: t4.id))
        XCTAssertEqual(app.tabs.tabs.map(\.id), [t2.id, t1.id, t4.id, t3.id])

        // Arbitrary drag reorder (`moveTab(id:to:)`).
        XCTAssertTrue(app.tabs.moveTab(id: t3.id, to: 0))
        XCTAssertEqual(app.tabs.tabs.map(\.id), [t3.id, t2.id, t1.id, t4.id])
        XCTAssertEqual(app.tabs.exportState().tabs.map(\.id), [t3.id, t2.id, t1.id, t4.id])

        // ⌃Tab (`switchToNextTab`) and ⌃⇧Tab (`switchToPreviousTab`) wrap around.
        XCTAssertEqual(app.tabs.currentTabID, t1.id)
        XCTAssertTrue(app.switchNextTab())
        XCTAssertEqual(app.tabs.currentTabID, t4.id)
        XCTAssertTrue(app.switchNextTab())
        XCTAssertEqual(app.tabs.currentTabID, t3.id)
        XCTAssertTrue(app.switchPreviousTab())
        XCTAssertEqual(app.tabs.currentTabID, t4.id)
    }

    func testCloseTabSavesConversationToHistoryShowsToastAndUndoRestoresStoppedRunWithoutResuming() async throws {
        var anthropicConfig = app.settings.configuration(for: .anthropic)
        anthropicConfig.apiKey = "test-key"
        anthropicConfig.model = "claude-haiku-5-5"
        app.settings.setConfiguration(anthropicConfig, for: .anthropic)
        app.settings.setModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .browserAgent)

        // 1. Tab 1 has a finished short conversation (< 200 chars); closing saves it to History and Undo restores it.
        let tab1 = app.tabs.currentTab
        tab1.browser.load(server.url("/tall/1"))
        try await waitUntil(description: "tab 1 loaded") {
            tab1.browser.pageTitle == "Tall Tab 1" && !tab1.browser.isLoading
        }
        let shortReplyClient = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "Short summary of Tall Tab 1."))
        ])
        tab1.agentSession.configureDebugModelClient(shortReplyClient)
        await tab1.agentSession.sendAndWait("Summarize Tall Tab 1")
        XCTAssertEqual(tab1.agentSession.runs.count, 1)
        XCTAssertTrue(app.agentRuns.isEmpty, "Short <200-char reply is not in History until New conversation or tab close.")

        let tab2 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tall/2"), inFront: true))
        try await waitUntil(description: "tab 2 loaded") {
            tab2.browser.pageTitle == "Tall Tab 2" && !tab2.browser.isLoading
        }

        XCTAssertTrue(app.closeTabWithUndo(id: tab1.id, toastDuration: .seconds(5)))
        XCTAssertEqual(app.tabs.tabs.map(\.id), [tab2.id])
        XCTAssertEqual(app.tabClosedToast?.message, "Tab closed. Its conversation is in History.")
        XCTAssertEqual(app.agentRuns.count, 1, "Closing a tab with a conversation saves it to History.")
        XCTAssertEqual(app.agentRuns.first?.goal, "Summarize Tall Tab 1")
        XCTAssertEqual(app.agentRuns.first?.answer, "Short summary of Tall Tab 1.")

        let restoredTab1 = try XCTUnwrap(app.undoCloseTab())
        XCTAssertNil(app.tabClosedToast)
        XCTAssertEqual(app.tabs.tabs.map(\.id), [tab1.id, tab2.id], "Undo restores tab 1 at its original index.")
        XCTAssertEqual(restoredTab1.url, server.url("/tall/1"))
        XCTAssertEqual(restoredTab1.agentSession.runs.first?.assistantText, "Short summary of Tall Tab 1.")
        XCTAssertTrue(app.agentRuns.isEmpty, "Undoing the close removes the close-archived duplicate from History.")

        // 2. Tab 2 has an actively running Agent; closing stops it first, saves to History, and Undo keeps it stopped.
        let stalledClient = TabBoundAgentClient(step2DestinationURL: server.url("/tab-a-step2").absoluteString)
        tab2.agentSession.configureDebugModelClient(stalledClient)
        tab2.agentSession.send("Inspect Tall Tab 2 while open")
        await stalledClient.step1Started.wait()
        XCTAssertTrue(tab2.agentSession.isRunning)
        XCTAssertTrue(app.tabs.runningTabIDs.contains(tab2.id))

        XCTAssertTrue(app.closeTabWithUndo(id: tab2.id, toastDuration: .seconds(5)))
        XCTAssertFalse(app.tabs.runningTabIDs.contains(tab2.id))
        XCTAssertEqual(app.tabClosedToast?.message, "Tab closed. Its conversation is in History.")
        XCTAssertEqual(app.agentRuns.first?.goal, "Inspect Tall Tab 2 while open")
        XCTAssertEqual(app.agentRuns.first?.result, .cancelled)
        XCTAssertEqual(app.agentRuns.first?.error, "Stopped")

        let restoredTab2 = try XCTUnwrap(app.undoCloseTab())
        XCTAssertEqual(app.tabs.currentTabID, restoredTab2.id)
        XCTAssertFalse(restoredTab2.agentSession.isRunning, "Undo must NOT resume a run that closing stopped.")
        if case .stopped = restoredTab2.agentSession.runState {
            // expected
        } else {
            XCTFail("Expected restored runState to be .stopped, got \(restoredTab2.agentSession.runState)")
        }
        if case .stopped = restoredTab2.agentSession.runs.last?.state {
            // expected
        } else {
            XCTFail("Expected last turn state to be .stopped, got \(String(describing: restoredTab2.agentSession.runs.last?.state))")
        }

        // 3. Closing an empty tab shows "Tab closed." and auto-expires after toastDuration.
        let emptyTab = try XCTUnwrap(app.tabs.openTab(inFront: false))
        XCTAssertTrue(app.closeTabWithUndo(id: emptyTab.id, toastDuration: .milliseconds(120)))
        XCTAssertEqual(app.tabClosedToast?.message, "Tab closed.")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(app.tabClosedToast)
    }

    func testTabsButtonLongPressMenuActionsAndThirtyTabLimit() throws {
        let t1 = app.tabs.currentTab
        let t2 = try XCTUnwrap(app.tabs.openTab(url: server.url("/tall/2"), inFront: true))

        let menuSections = BrowserTabsButton.buildMenuElements(for: app).compactMap { $0 as? UIMenu }
        XCTAssertEqual(menuSections.count, 2)
        let commandActions = menuSections[0].children.compactMap { $0 as? UIAction }
        XCTAssertEqual(commandActions.map(\.title), ["New Tab", "Close This Tab"])
        XCTAssertFalse(commandActions[0].attributes.contains(.disabled))
        XCTAssertTrue(commandActions[1].attributes.contains(.destructive))

        let openTabActions = menuSections[1].children.compactMap { $0 as? UIAction }
        XCTAssertEqual(openTabActions.count, 2)
        XCTAssertEqual(openTabActions[0].state, .off)
        XCTAssertEqual(openTabActions[1].state, .on)
        XCTAssertEqual(t1.id, "t1")
        XCTAssertEqual(t2.id, "t2")

        // Fill up to 30 tabs: New Tab disables and shows the 30-tab limit subtitle.
        while app.tabs.canOpenTab {
            XCTAssertNotNil(app.tabs.openTab(inFront: false))
        }
        XCTAssertEqual(app.tabs.tabs.count, 30)
        XCTAssertNil(app.openNewTabFromUI())

        let fullSections = BrowserTabsButton.buildMenuElements(for: app).compactMap { $0 as? UIMenu }
        let fullNewTab = try XCTUnwrap(fullSections.first?.children.first as? UIAction)
        XCTAssertTrue(fullNewTab.attributes.contains(.disabled))
        XCTAssertEqual(fullNewTab.subtitle, "30 tabs open. Close one to open another")
    }

    func testOverviewTransitionMetricsAndHostedVoiceOverCardCustomActions() throws {
        // Transition & grid column rules.
        XCTAssertEqual(TabOverviewTransitionMetrics.duration(reduceMotion: false), 0.25, accuracy: 0.001)
        XCTAssertEqual(TabOverviewTransitionMetrics.duration(reduceMotion: true), 0.20, accuracy: 0.001)
        XCTAssertTrue(TabOverviewTransitionMetrics.usesZoom(reduceMotion: false))
        XCTAssertFalse(TabOverviewTransitionMetrics.usesZoom(reduceMotion: true))
        XCTAssertEqual(TabOverviewTransitionMetrics.columnCount(isPadOverview: false, isAccessibilitySize: false), 2)
        XCTAssertEqual(TabOverviewTransitionMetrics.columnCount(isPadOverview: false, isAccessibilitySize: true), 1)
        XCTAssertEqual(TabOverviewTransitionMetrics.columnCount(isPadOverview: true, isAccessibilitySize: false), 4)
        XCTAssertEqual(TabOverviewTransitionMetrics.columnCount(isPadOverview: true, isAccessibilitySize: true), 2)

        // Exact VoiceOver label format from spec §2 ("Accessibility (tabs)").
        let label = TabOverviewTransitionMetrics.cardAccessibilityLabel(
            title: "Night ferries ease the summer rush",
            host: "news.example.com",
            isHome: false,
            isCurrent: true,
            isAgentWorking: true
        )
        XCTAssertEqual(label, "Night ferries ease the summer rush, news.example.com, current tab, Agent working")

        // Mount TabOverviewView in a UIWindow and invoke real UIAccessibilityCustomActions.
        let t1 = app.tabs.currentTab
        let t2 = try XCTUnwrap(app.tabs.openTab(inFront: false))
        let t3 = try XCTUnwrap(app.tabs.openTab(inFront: false))

        let hostController = UIHostingController(
            rootView: TabOverviewView(
                app: app,
                tabs: app.tabs,
                containerWidth: 390,
                safeAreaBottom: 34
            )
        )
        let activeScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let overviewWindow: UIWindow
        if let activeScene {
            overviewWindow = UIWindow(windowScene: activeScene)
        } else {
            overviewWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        overviewWindow.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        overviewWindow.rootViewController = hostController
        overviewWindow.makeKeyAndVisible()
        defer {
            overviewWindow.isHidden = true
            overviewWindow.rootViewController = nil
        }
        hostController.view.frame = overviewWindow.bounds
        hostController.view.layoutIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hostController.view.layoutIfNeeded()
        CATransaction.flush()

        let hostedRoot: UIView = hostController.view!
        XCTAssertFalse(app.router.isTabOverviewPresented)
        app.presentTabOverview(reduceMotion: true)
        XCTAssertTrue(app.router.isTabOverviewPresented)
        XCTAssertEqual(
            TabCardAccessibilityInspector.customActionNames(forCardID: t1.id, in: hostedRoot),
            ["Close", "Move later"]
        )
        XCTAssertEqual(
            TabCardAccessibilityInspector.customActionNames(forCardID: t2.id, in: hostedRoot),
            ["Close", "Move earlier", "Move later"]
        )
        XCTAssertEqual(
            TabCardAccessibilityInspector.customActionNames(forCardID: t3.id, in: hostedRoot),
            ["Close", "Move earlier"]
        )

        XCTAssertTrue(
            TabCardAccessibilityInspector.invokeCustomAction(named: "Move later", forCardID: t1.id, in: hostedRoot)
        )
        XCTAssertEqual(app.tabs.tabs.map(\.id), [t2.id, t1.id, t3.id])

        hostController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(
            TabCardAccessibilityInspector.invokeCustomAction(named: "Move earlier", forCardID: t1.id, in: hostedRoot)
        )
        XCTAssertEqual(app.tabs.tabs.map(\.id), [t1.id, t2.id, t3.id])

        hostController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(
            TabCardAccessibilityInspector.invokeCustomAction(named: "Close", forCardID: t2.id, in: hostedRoot)
        )
        XCTAssertEqual(app.tabs.tabs.map(\.id), [t1.id, t3.id])
    }
}
