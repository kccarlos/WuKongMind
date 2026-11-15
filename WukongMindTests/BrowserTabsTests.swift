import Combine
import Foundation
import Network
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
        private(set) var port: UInt16 = 0

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

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

        mountActiveWebView()
        app.objectWillChange
            .sink { [weak self] in
                Task { @MainActor in self?.mountActiveWebView() }
            }
            .store(in: &cancellables)
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        if let app {
            for tab in app.tabs.tabs {
                tab.agentSession.stop()
                tab.browser.stopLoading()
                tab.browser.detachCallbacks()
                tab.scriptWebController.detach()
                tab.browser.webView.removeFromSuperview()
            }
            app.pauseDigest()
            app.podcast.pauseGeneration()
        }
        app = nil
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

    private func mountActiveWebView() {
        guard let rootView = hostWindow?.rootViewController?.view, let activeWebView = app?.browser.webView else { return }
        if activeWebView.superview !== rootView {
            rootView.subviews.forEach { $0.removeFromSuperview() }
            activeWebView.frame = rootView.bounds
            rootView.addSubview(activeWebView)
            rootView.layoutIfNeeded()
        }
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
        let tab2 = app.tabs.openTab(url: betaURL)
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
        let tab2 = app.tabs.openTab(url: server.url("/whoami"))
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

        let tabB = app.tabs.openTab(url: server.url("/tab-b"), inFront: false)
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
        let trailingTab = app.tabs.openTab(url: server.url("/tab-b"), inFront: false)
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

        let tab2 = app.tabs.openTab(url: server.url("/tab-b"))
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
}
