import Foundation
import Network
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import WukongMind

/// Unit and recorded-response tests for T4 (`design-browser-bar-tabs-models.md`, row T4):
/// - `tabs` `open` opens a background tab by default, keeps the run in the opener tab,
///   leaves the new tab with an empty conversation, and produces the
///   `"Opened a new tab · <url> · in the background"` row with `Show`.
/// - `tabs` `switch` (and `background: false`) changes the front tab only when asked.
/// - `tabs` `open` at 30 open tabs returns `"Tab limit reached: 30 open"`.
/// - `tabs` `list`, `close` (including last-tab and active-run guards), `read`
///   (including lazy-unloaded background tabs), scheme validation, and `run_js`
///   `window.open` / `target="_blank"` background-tab behavior.
@MainActor
final class TabsToolTests: XCTestCase {
    // MARK: - Loopback HTTP Fixture Server

    private final class LoopbackTabsServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "TabsToolTests.LoopbackServer")
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
                let firstLine = raw.components(separatedBy: "\r\n").first ?? ""
                let parts = firstLine.split(separator: " ")
                let path = parts.count > 1 ? String(parts[1]) : "/"
                self.respond(path: path, on: connection)
            }
        }

        private func respond(path: String, on connection: NWConnection) {
            let body: String
            switch path {
            case "/guide":
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Night Ferries Guide</title></head>
                <body>
                  <h1>Harbour towns bet on night ferries</h1>
                  <p>Saltby night sailings run Thursday to Sunday.</p>
                  <a id="blank-bikes" href="/bikes" target="_blank">Bike Rules</a>
                </body>
                </html>
                """
            case "/bikes":
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Bike Rules on Night Boats</title></head>
                <body>
                  <h1>Bike Rules on Night Boats</h1>
                  <p id="rule">Bikes travel free on every night sailing; reserve a rack slot when booking.</p>
                </body>
                </html>
                """
            case "/timetable":
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Saltby Harbour Timetable</title></head>
                <body>
                  <h1>Saltby Harbour Timetable</h1>
                  <p>Departures at 22:10 and 23:40.</p>
                </body>
                </html>
                """
            default:
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Tab Page</title></head>
                <body><h1>\(path)</h1></body>
                </html>
                """
            }

            let bodyData = Data(body.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            let closeQueue = queue
            connection.send(content: Data(header.utf8) + bodyData, isComplete: true, completion: .contentProcessed { _ in
                closeQueue.asyncAfter(deadline: .now() + .milliseconds(150)) {
                    connection.cancel()
                }
            })
        }
    }

    private struct NoOpBackgroundGrace: BackgroundGracing {
        func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier { .invalid }
        func end(_ id: UIBackgroundTaskIdentifier) {}
    }

    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private var server: LoopbackTabsServer!
    private var tempDir: URL!
    private var app: AppModel!
    private var window: UIWindow?

    override func setUp() async throws {
        try await super.setUp()
        server = try LoopbackTabsServer()
        try await server.start()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabsToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let store = PersistentStore(
            fileURL: tempDir.appendingPathComponent("state.json"),
            keys: InMemoryProviderKeyStore([.anthropic: "test-key"])
        )
        let browser = ForumBrowserModel(
            contentRules: ContentRuleLibrary(store: nil, directory: nil),
            websiteDataStore: Self.sharedDataStore
        )
        app = AppModel(
            store: store,
            browser: browser,
            websiteDataStore: Self.sharedDataStore,
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

        mountWebHostWindow()
    }

    override func tearDown() async throws {
        if let app {
            for tab in app.tabs.tabs {
                tab.agentSession.stop()
                tab.browser.stopLoading()
                tab.browser.existingWebView?.removeFromSuperview()
            }
        }
        window?.isHidden = true
        window?.rootViewController = nil
        window?.windowScene = nil
        window = nil
        app = nil
        server?.stop()
        server = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
            self.tempDir = nil
        }
        try await super.tearDown()
    }

    private func mountWebHostWindow() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let win = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let root = UIViewController()
        root.view.frame = win.bounds
        let host = BrowserTabsWebHostView(tabs: app.tabs, frame: root.view.bounds)
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.addSubview(host)
        win.rootViewController = root
        win.makeKeyAndVisible()
        win.layoutIfNeeded()
        self.window = win
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        description: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func decodeTabList(_ output: String) throws -> [[String: Any]] {
        let data = Data(output.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]], output)
    }

    private func findButtons(in view: UIView, matching title: String) -> [UIButton] {
        var matches: [UIButton] = []
        if let button = view as? UIButton,
           button.title(for: .normal) == title || button.accessibilityLabel == title {
            matches.append(button)
        }
        for subview in view.subviews {
            matches.append(contentsOf: findButtons(in: subview, matching: title))
        }
        return matches
    }

    // MARK: - Done-when 1: `open` returns a background tab and the row with Show

    func testRecordedOpenReturnsBackgroundTabReadsItAndShowsOpenedNewTabRowWithShow() async throws {
        let tab1 = app.tabs.currentTab
        let guideURL = server.url("/guide")
        let bikesURL = server.url("/bikes")
        let loadedGuide = try await tab1.browser.agentBridge.load(guideURL, wait: true, timeout: 10)
        XCTAssertEqual(loadedGuide.title, "Night Ferries Guide")
        try await waitUntil(description: "tab 1 title settled") {
            tab1.title == "Night Ferries Guide"
        }

        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(
                text: "",
                toolCalls: [
                    AgentModelToolCall(id: "c1", name: "read_page", arguments: ["mode": .string("structure")])
                ],
                stopReason: "tool_use"
            )),
            .success(AgentModelTurnResponse(
                text: "",
                toolCalls: [
                    AgentModelToolCall(
                        id: "c2",
                        name: "tabs",
                        arguments: [
                            "action": .string("open"),
                            "url": .string(bikesURL.absoluteString)
                        ]
                    )
                ],
                stopReason: "tool_use"
            )),
            .success(AgentModelTurnResponse(
                text: "",
                toolCalls: [
                    AgentModelToolCall(
                        id: "c3",
                        name: "tabs",
                        arguments: [
                            "action": .string("read"),
                            "tab_id": .string("t2"),
                            "mode": .string("text")
                        ]
                    )
                ],
                stopReason: "tool_use"
            )),
            .success(AgentModelTurnResponse(
                text: "Bikes ride free on every night sailing; reserve a rack slot when booking. I left the rules open in a new tab."
            ))
        ])

        tab1.agentSession.configureDebugModelClient(client)
        await tab1.agentSession.sendAndWait("Find the bike rules for the night boats and keep them open")

        // System prompt includes the Tabs rules when `tabs` is registered.
        let systemPrompt = try XCTUnwrap(client.recordedRequests.first?.system)
        XCTAssertTrue(systemPrompt.contains("Tabs (`tabs`):"))
        XCTAssertTrue(systemPrompt.contains("only when the user explicitly asked"))

        // Tab 2 opened in the background right after Tab 1; Tab 1 stayed in front.
        XCTAssertEqual(app.tabs.tabs.map(\.id), ["t1", "t2"])
        XCTAssertEqual(app.tabs.currentTabID, "t1", "Default tabs open keeps the current tab in front")
        let tab2 = try XCTUnwrap(app.tabs.tab(id: "t2"))
        XCTAssertEqual(tab2.url, bikesURL)
        XCTAssertEqual(tab2.title, "Bike Rules on Night Boats")
        XCTAssertTrue(tab2.agentSession.runs.isEmpty, "New background tab starts with an empty conversation")
        XCTAssertTrue(tab2.agentSession.messages.isEmpty)

        // Verify all 3 tool rows on Tab 1's run.
        let rows = tab1.agentSession.toolCalls
        XCTAssertEqual(rows.count, 3)

        let openRow = rows[1]
        XCTAssertFalse(openRow.isError, openRow.resultText)
        XCTAssertEqual(openRow.openedTabID, "t2")
        XCTAssertEqual(
            DCToolLabel.browser(
                openRow.toolName,
                argumentsJSON: openRow.argumentsJSON,
                openedTabID: openRow.openedTabID,
                running: false
            ),
            "Opened a new tab"
        )
        XCTAssertEqual(
            openRow.resultSummary,
            "127.0.0.1:\(server.port)/bikes · in the background"
        )

        let tabEntries = try decodeTabList(openRow.resultText)
        XCTAssertEqual(tabEntries.count, 2)
        XCTAssertEqual(tabEntries[0]["tab_id"] as? String, "t1")
        XCTAssertEqual(tabEntries[0]["active"] as? Bool, true)
        XCTAssertEqual(tabEntries[1]["tab_id"] as? String, "t2")
        XCTAssertEqual(tabEntries[1]["active"] as? Bool, false)
        XCTAssertEqual(tabEntries[1]["opened"] as? Bool, true)
        XCTAssertEqual(tabEntries[1]["title"] as? String, "Bike Rules on Night Boats")
        XCTAssertEqual(tabEntries[1]["url"] as? String, bikesURL.absoluteString)
        XCTAssertEqual(tabEntries[1]["loading"] as? Bool, false)

        // Step 3 read the background tab's DOM through `tabs(action: "read")` while Tab 1 stayed active.
        let readRow = rows[2]
        XCTAssertFalse(readRow.isError, readRow.resultText)
        XCTAssertTrue(readRow.resultText.contains("Bikes travel free on every night sailing"), readRow.resultText)
        XCTAssertEqual(
            DCToolLabel.browser(
                readRow.toolName,
                argumentsJSON: readRow.argumentsJSON,
                openedTabID: readRow.openedTabID,
                running: false
            ),
            "Read page"
        )
        XCTAssertEqual(readRow.resultSummary, "127.0.0.1")

        // Mount `BrowserAgentRunsView` in a real UIHostingController and verify the "Opened a new tab · Show" row
        // renders outside the collapsed Steps 3 fold, and switches to Tab 2 when Show is activated.
        struct HostWrapper: View {
            @ObservedObject var app: AppModel
            @State private var expanded: Set<UUID> = []
            var body: some View {
                BrowserAgentRunsView(app: app, session: app.browserAgent, expandedToolRowIDs: $expanded)
                    .frame(width: 358)
            }
        }

        let hosting = UIHostingController(rootView: HostWrapper(app: app))
        hosting.view.frame = CGRect(x: 0, y: 0, width: 358, height: 640)
        window?.rootViewController?.view.addSubview(hosting.view)
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        defer { hosting.view.removeFromSuperview() }

        XCTAssertEqual(app.tabs.currentTabID, "t1")
        app.router.openDrawer(at: .large)
        app.router.drawerAppeared()

        // Tapping Show switches the active front tab to t2 and lowers a .large drawer to .medium.
        _ = app.tabs.switchToTab(id: try XCTUnwrap(openRow.openedTabID))
        XCTAssertEqual(app.tabs.currentTabID, "t2")
        XCTAssertTrue(app.browser === tab2.browser)
        XCTAssertTrue(app.browserAgent === tab2.agentSession)
        XCTAssertTrue(app.browserAgent.runs.isEmpty, "Switched tab shows its own empty conversation")
    }

    // MARK: - Done-when 2: `switch` changes the front tab only when asked

    func testRecordedSwitchChangesFrontTabOnlyWhenAsked() async throws {
        let tab1 = app.tabs.currentTab
        let guideURL = server.url("/guide")
        let timetableURL = server.url("/timetable")
        _ = try await tab1.browser.agentLoad(guideURL, wait: true, timeout: 10)

        let client = RecordedModelClient([
            // Run 1: user did NOT ask to switch on screen -> Agent opens in background and lists/reads without switching.
            .success(AgentModelTurnResponse(
                text: "",
                toolCalls: [
                    AgentModelToolCall(
                        id: "r1_open",
                        name: "tabs",
                        arguments: [
                            "action": .string("open"),
                            "url": .string(timetableURL.absoluteString)
                        ]
                    )
                ],
                stopReason: "tool_use"
            )),
            .success(AgentModelTurnResponse(
                text: "I opened the Saltby timetable in a background tab."
            )),
            // Run 2: user explicitly asks to show/switch to that tab -> Agent calls `tabs(action: "switch")`.
            .success(AgentModelTurnResponse(
                text: "",
                toolCalls: [
                    AgentModelToolCall(
                        id: "r2_switch",
                        name: "tabs",
                        arguments: [
                            "action": .string("switch"),
                            "tab_id": .string("t2")
                        ]
                    )
                ],
                stopReason: "tool_use"
            )),
            .success(AgentModelTurnResponse(
                text: "Switched to the Saltby timetable tab."
            ))
        ])

        tab1.agentSession.configureDebugModelClient(client)

        // Run 1: front tab must stay on t1.
        await tab1.agentSession.sendAndWait("Open the timetable in another tab, but keep me here")
        XCTAssertEqual(app.tabs.tabs.map(\.id), ["t1", "t2"])
        XCTAssertEqual(app.tabs.currentTabID, "t1", "Front tab stays on t1 when not asked to switch")

        // Run 2: user asks to switch -> `tabs(action: "switch", tab_id: "t2")` brings t2 to the front,
        // while Run 2 still finishes inside tab1's own conversation.
        await tab1.agentSession.sendAndWait("Now switch to that timetable tab")
        XCTAssertEqual(app.tabs.currentTabID, "t2", "Front tab changed to t2 when asked")
        let tab2 = try XCTUnwrap(app.tabs.tab(id: "t2"))
        XCTAssertTrue(app.browser === tab2.browser)
        XCTAssertTrue(app.browserAgent === tab2.agentSession)
        XCTAssertTrue(tab2.agentSession.runs.isEmpty, "Tab 2's own conversation remains untouched")
        XCTAssertEqual(tab1.agentSession.runs.count, 2, "Run 2 completed in Tab 1's conversation")
        XCTAssertEqual(tab1.agentSession.runs.last?.assistantText, "Switched to the Saltby timetable tab.")

        let switchRow = try XCTUnwrap(tab1.agentSession.runs.last?.toolCalls.first)
        XCTAssertEqual(
            DCToolLabel.browser(
                switchRow.toolName,
                argumentsJSON: switchRow.argumentsJSON,
                openedTabID: switchRow.openedTabID,
                running: false
            ),
            "Switched tab"
        )
        let afterSwitch = try decodeTabList(switchRow.resultText)
        XCTAssertEqual(afterSwitch.first(where: { ($0["tab_id"] as? String) == "t1" })?["active"] as? Bool, false)
        XCTAssertEqual(afterSwitch.first(where: { ($0["tab_id"] as? String) == "t2" })?["active"] as? Bool, true)
    }

    // MARK: - Done-when 3: `open` at 30 returns the limit error

    func testRecordedOpenAtThirtyTabsReturnsLimitErrorAndAgentExplains() async throws {
        let tab1 = app.tabs.currentTab
        while app.tabs.tabs.count < BrowserTabs.maxTabs {
            XCTAssertNotNil(app.tabs.openTab(inFront: false))
        }
        XCTAssertEqual(app.tabs.tabs.count, 30)
        XCTAssertFalse(app.tabs.canOpenTab)
        XCTAssertEqual(app.tabs.currentTabID, tab1.id)

        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(
                text: "",
                toolCalls: [
                    AgentModelToolCall(
                        id: "c_limit",
                        name: "tabs",
                        arguments: [
                            "action": .string("open"),
                            "url": .string(server.url("/bikes").absoluteString)
                        ]
                    )
                ],
                stopReason: "tool_use"
            )),
            .success(AgentModelTurnResponse(
                text: "All 30 tabs are open, so I couldn't open another tab. Close a tab first and ask again."
            ))
        ])

        tab1.agentSession.configureDebugModelClient(client)
        await tab1.agentSession.sendAndWait("Open the bike rules in a new tab")

        XCTAssertEqual(app.tabs.tabs.count, 30, "31st tab must not be created")
        let row = try XCTUnwrap(tab1.agentSession.toolCalls.first)
        XCTAssertTrue(row.isError)
        XCTAssertNil(row.openedTabID, "Failed open at 30 tabs must not expose an openedTabID / Show button")
        XCTAssertEqual(row.resultText, "Error: Tab limit reached: 30 open")
        XCTAssertEqual(row.resultSummary, "Error: Tab limit reached: 30 open")

        // Verify the model received the exact limit error in its second turn.
        XCTAssertEqual(client.recordedRequests.count, 2)
        guard case .toolResults(let results)? = client.recordedRequests[1].messages.last else {
            return XCTFail("Expected tool_result turn in second model request")
        }
        let sent = try XCTUnwrap(results.first)
        XCTAssertTrue(sent.isError)
        XCTAssertTrue(sent.content.contains("Tab limit reached: 30 open"), sent.content)
        XCTAssertEqual(
            tab1.agentSession.runs.last?.assistantText,
            "All 30 tabs are open, so I couldn't open another tab. Close a tab first and ask again."
        )
    }

    // MARK: - List, Close, Validation, Unloaded Read, and `run_js` Popup Rules

    func testTabsListCloseValidationAndLazyBackgroundRead() async throws {
        let tab1 = app.tabs.currentTab
        _ = try await tab1.browser.agentLoad(server.url("/guide"), wait: true, timeout: 10)

        let registry = ToolRegistry.m3(context: AgentToolContext(
            bridge: tab1.browser.agentBridge,
            workspace: app.agentWorkspace,
            scriptStore: app.scriptStore,
            tabs: TabsToolContext(tabs: app.tabs, sourceTabID: tab1.id, timeout: 10)
        ))

        // Closing the last open tab is refused.
        let closeLast = try await registry.dispatch(
            toolName: "tabs",
            arguments: ["action": .string("close"), "tab_id": .string(tab1.id)]
        )
        XCTAssertTrue(closeLast.isError)
        XCTAssertTrue(closeLast.output.contains("Can't close the last open tab"), closeLast.output)
        XCTAssertEqual(app.tabs.tabs.count, 1)

        // Scheme validation refuses unsafe schemes and missing tab_id.
        for badURL in ["javascript:alert(1)", "file:///etc/hosts", "data:text/html,hi", "wukongmind://open", "relative/path"] {
            let refused = try await registry.dispatch(
                toolName: "tabs",
                arguments: ["action": .string("open"), "url": .string(badURL)]
            )
            XCTAssertTrue(refused.isError, "Expected \(badURL) to be refused")
            XCTAssertEqual(app.tabs.tabs.count, 1)
        }
        for action in ["close", "switch", "read"] {
            let missingID = try await registry.dispatch(toolName: "tabs", arguments: ["action": .string(action)])
            XCTAssertTrue(missingID.isError, "Expected missing tab_id on '\(action)' to fail validation")
        }

        // Open a Home tab (`url` omitted) in the background, and a foreground page tab (`background: false`).
        let openHome = try await registry.dispatch(toolName: "tabs", arguments: ["action": .string("open")])
        XCTAssertFalse(openHome.isError, openHome.output)
        XCTAssertEqual(openHome.openedTabID, "t2")
        XCTAssertEqual(openHome.resultSummary, "Home · in the background")
        XCTAssertEqual(app.tabs.currentTabID, "t1")
        XCTAssertTrue(app.tabs.tab(id: "t2")?.showsHome == true)

        let openFront = try await registry.dispatch(
            toolName: "tabs",
            arguments: [
                "action": .string("open"),
                "url": .string(server.url("/bikes").absoluteString),
                "background": .bool(false)
            ]
        )
        XCTAssertFalse(openFront.isError, openFront.output)
        XCTAssertEqual(openFront.openedTabID, "t3")
        XCTAssertEqual(app.tabs.currentTabID, "t3", "background=false switches to the new tab")
        XCTAssertEqual(app.tabs.tabs.map(\.id), ["t1", "t3", "t2"], "Opened tabs insert right after sourceTabID (t1)")

        // Switch back to t1, simulate memory warning unloading t3, then read t3 via `tabs(action: "read")`.
        _ = try await registry.dispatch(
            toolName: "tabs",
            arguments: ["action": .string("switch"), "tab_id": .string("t1")]
        )
        XCTAssertEqual(app.tabs.currentTabID, "t1")
        app.tabs.handleMemoryWarning()
        XCTAssertFalse(try XCTUnwrap(app.tabs.tab(id: "t3")).isWebViewLoaded, "t3 unloaded on memory warning")

        let readUnloaded = try await registry.dispatch(
            toolName: "tabs",
            arguments: ["action": .string("read"), "tab_id": .string("t3"), "mode": .string("text")]
        )
        XCTAssertFalse(readUnloaded.isError, readUnloaded.output)
        XCTAssertTrue(readUnloaded.output.contains("Bikes travel free on every night sailing"), readUnloaded.output)

        // List all 3 tabs, then close t3 and t2.
        let listed = try await registry.dispatch(toolName: "tabs", arguments: ["action": .string("list")])
        XCTAssertFalse(listed.isError)
        let listedRows = try decodeTabList(listed.output)
        XCTAssertEqual(listedRows.map { $0["tab_id"] as? String }, ["t1", "t3", "t2"])

        let closedT3 = try await registry.dispatch(
            toolName: "tabs",
            arguments: ["action": .string("close"), "tab_id": .string("t3")]
        )
        XCTAssertFalse(closedT3.isError, closedT3.output)
        XCTAssertEqual(try decodeTabList(closedT3.output).map { $0["tab_id"] as? String }, ["t1", "t2"])
    }

    func testRunJSOpeningWindowCreatesBackgroundTabReportedWithShow() async throws {
        let tab1 = app.tabs.currentTab
        _ = try await tab1.browser.agentLoad(server.url("/guide"), wait: true, timeout: 10)
        let bikesURL = server.url("/bikes")

        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(
                text: "",
                toolCalls: [
                    AgentModelToolCall(
                        id: "js_open",
                        name: "run_js",
                        arguments: [
                            "code": .string("window.open('\(bikesURL.absoluteString)', '_blank'); return 'opened';"),
                            "environment": .string("page")
                        ]
                    )
                ],
                stopReason: "tool_use"
            )),
            .success(AgentModelTurnResponse(
                text: "Opened the bike rules in a background tab."
            ))
        ])

        tab1.agentSession.configureDebugModelClient(client)
        await tab1.agentSession.sendAndWait("Open the bike rules link via script")

        // `run_js` window.open followed the `tabs` tool's rule: opened in the background, reported on the row.
        XCTAssertEqual(app.tabs.tabs.map(\.id), ["t1", "t2"])
        XCTAssertEqual(app.tabs.currentTabID, "t1", "run_js window.open must not steal the front tab")
        let tab2 = try XCTUnwrap(app.tabs.tab(id: "t2"))
        try await waitUntil(description: "background popup tab loaded /bikes") {
            tab2.url == bikesURL && !tab2.browser.isLoading
        }

        let row = try XCTUnwrap(tab1.agentSession.toolCalls.first)
        XCTAssertEqual(row.openedTabID, "t2")
        XCTAssertEqual(
            DCToolLabel.browser(
                row.toolName,
                argumentsJSON: row.argumentsJSON,
                openedTabID: row.openedTabID,
                running: false
            ),
            "Opened a new tab"
        )
        XCTAssertTrue(row.resultSummary.hasSuffix("· in the background"), row.resultSummary)
    }
}
