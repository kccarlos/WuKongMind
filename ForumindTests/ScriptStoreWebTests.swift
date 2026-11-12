import Foundation
import Network
import os
import UIKit
import WebKit
import XCTest
@testable import Forumind

/// Real `WKWebView` integration tests for `ScriptStore`, `ScriptWebController`,
/// and the M2 script tools using local HTML fixtures served over `127.0.0.1`
/// (with real `Content-Security-Policy` response headers where needed).
@MainActor
final class ScriptStoreWebTests: XCTestCase {
    // MARK: - Navigation Waiter & Loopback Fixture Server

    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var timeoutTask: Task<Void, Never>?

        func waitForLoad(timeoutSeconds: Double = 30, _ start: () -> Void) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                self.timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.finish(
                        with: NSError(
                            domain: "ScriptStoreWebTests",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Navigation timed out after \(timeoutSeconds)s"]
                        )
                    )
                }
                start()
            }
        }

        private func finish(with error: Error? = nil) {
            timeoutTask?.cancel()
            timeoutTask = nil
            guard let cont = continuation else { return }
            continuation = nil
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume()
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(with: error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            finish(with: error)
        }
    }

    private final class LoopbackFixtureServer: @unchecked Sendable {
        struct Route {
            var status: Int = 200
            var contentType: String = "text/html; charset=utf-8"
            var headers: [String: String] = [:]
            var body: Data
        }

        private let listener: NWListener
        private let queue = DispatchQueue(label: "wukong.scriptstore.fixture-server")
        private let routeResolver: @Sendable (String) -> Route?
        private let activeConnections = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: NWConnection]())
        private(set) var port: UInt16 = 0

        init(routeResolver: @escaping @Sendable (String) -> Route?) throws {
            self.routeResolver = routeResolver
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            params.allowLocalEndpointReuse = true
            self.listener = try NWListener(using: params)
        }

        convenience init(routes: [String: Route]) throws {
            try self.init { path in routes[path] }
        }

        func start() async throws -> URL {
            let readyPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let resumeOnce: @Sendable (Result<UInt16, Error>) -> Void = { result in
                    let shouldResume = resumed.withLock { already -> Bool in
                        guard !already else { return false }
                        already = true
                        return true
                    }
                    guard shouldResume else { return }
                    continuation.resume(with: result)
                }

                let connections = self.activeConnections
                listener.newConnectionHandler = { [routeResolver, queue] connection in
                    let key = ObjectIdentifier(connection)
                    connections.withLock { $0[key] = connection }
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .cancelled, .failed:
                            _ = connections.withLock { $0.removeValue(forKey: key) }
                        default:
                            break
                        }
                    }
                    Self.serve(connection: connection, routeResolver: routeResolver, queue: queue)
                }
                listener.stateUpdateHandler = { [weak listener] state in
                    switch state {
                    case .ready:
                        if let port = listener?.port?.rawValue, port > 0 {
                            resumeOnce(.success(port))
                        }
                    case .failed(let error):
                        resumeOnce(.failure(error))
                    case .cancelled:
                        resumeOnce(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 5) { [weak listener] in
                    let currentState = String(describing: listener?.state)
                    resumeOnce(
                        .failure(
                            NSError(
                                domain: "LoopbackFixtureServer",
                                code: 1,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "Loopback listener did not become ready within 5s (state=\(currentState))"
                                ]
                            )
                        )
                    )
                }
            }
            self.port = readyPort
            return URL(string: "http://127.0.0.1:\(readyPort)")!
        }

        func stop() {
            listener.cancel()
            let remaining = activeConnections.withLock { map -> [NWConnection] in
                let list = Array(map.values)
                map.removeAll()
                return list
            }
            for connection in remaining {
                connection.cancel()
            }
        }

        private static func serve(
            connection: NWConnection,
            routeResolver: @escaping @Sendable (String) -> Route?,
            queue: DispatchQueue
        ) {
            connection.start(queue: queue)
            receive(on: connection, buffer: Data(), routeResolver: routeResolver, queue: queue)
        }

        private static func receive(
            on connection: NWConnection,
            buffer: Data,
            routeResolver: @escaping @Sendable (String) -> Route?,
            queue: DispatchQueue
        ) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                var buffer = buffer
                if let data {
                    buffer.append(data)
                }
                if let rawRequest = String(data: buffer, encoding: .utf8),
                   rawRequest.contains("\r\n\r\n") {
                    respond(to: rawRequest, on: connection, routeResolver: routeResolver)
                } else if !isComplete, error == nil {
                    receive(on: connection, buffer: buffer, routeResolver: routeResolver, queue: queue)
                } else {
                    connection.cancel()
                }
            }
        }

        private static func respond(
            to rawRequest: String,
            on connection: NWConnection,
            routeResolver: @escaping @Sendable (String) -> Route?
        ) {
            let firstLine = rawRequest.split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = firstLine.split(separator: " ")
            let rawPath = parts.count >= 2 ? String(parts[1]) : "/"
            let cleanPath = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

            let route = routeResolver(cleanPath) ?? Route(
                status: 404,
                contentType: "text/plain; charset=utf-8",
                headers: [:],
                body: Data("Not Found".utf8)
            )

            var headerLines = [
                "HTTP/1.1 \(route.status) \(route.status == 200 ? "OK" : "Not Found")",
                "Content-Type: \(route.contentType)",
                "Content-Length: \(route.body.count)",
                "Cache-Control: no-store",
                "Connection: close"
            ]
            for (key, value) in route.headers.sorted(by: { $0.key < $1.key }) {
                headerLines.append("\(key): \(value)")
            }
            var payload = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            payload.append(route.body)

            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private struct WebHarness {
        let webView: WKWebView
        let bridge: AgentBridge
        let controller: ScriptWebController
        let waiter: NavigationWaiter
    }

    private final class OfflineForumURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
        override func stopLoading() {}
    }

    private struct NoOpBackgroundGrace: BackgroundGracing {
        func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier { .invalid }
        func end(_ id: UIBackgroundTaskIdentifier) {}
    }

    /// Share one ephemeral `WKWebsiteDataStore`, one primary `WKWebView`, and one
    /// loopback fixture server across the suite so WebKit does not churn `WebContent`
    /// and `Networking` extension processes on Swift's 3-thread cooperative pool on CI.
    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private static var sharedServer: LoopbackFixtureServer?
    private static var sharedBaseURL: URL?
    private static var sharedWebView: WKWebView?
    private static var sharedBridge: AgentBridge?
    private static var sharedWaiter: NavigationWaiter?

    private var tempDirectory: URL!
    private var dedicatedWebViews: [WKWebView] = []
    private var activeControllers: [ScriptWebController] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptStoreWebTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        for controller in activeControllers {
            controller.detach()
        }
        activeControllers.removeAll()

        if let sharedWebView = Self.sharedWebView {
            sharedWebView.stopLoading()
            sharedWebView.configuration.userContentController.removeAllUserScripts()
        }

        for webView in dedicatedWebViews {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.removeFromSuperview()
        }
        dedicatedWebViews.removeAll()

        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    nonisolated override class func tearDown() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if let webView = sharedWebView {
                    webView.stopLoading()
                    webView.navigationDelegate = nil
                    webView.configuration.userContentController.removeAllUserScripts()
                    webView.configuration.userContentController.removeAllScriptMessageHandlers()
                    webView.removeFromSuperview()
                }
                sharedWebView = nil
                sharedBridge = nil
                sharedWaiter = nil
                sharedServer?.stop()
                sharedServer = nil
                sharedBaseURL = nil
            }
        }
        super.tearDown()
    }

    private func sharedFixtureBaseURL() async throws -> URL {
        if let existing = Self.sharedBaseURL {
            return existing
        }
        let spaData = Data(try loadFixtureHTML("ScriptStore/spa-thread.html").utf8)
        let strictData = Data(try loadFixtureHTML("AgentBridge/strict-csp.html").utf8)
        let strictCSP = "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'"
        let server = try LoopbackFixtureServer { path in
            if path.hasPrefix("/t/") || path == "/about" {
                return .init(body: spaData)
            }
            if path == "/strict" {
                return .init(
                    headers: ["Content-Security-Policy": strictCSP],
                    body: strictData
                )
            }
            return nil
        }
        let url = try await server.start()
        Self.sharedServer = server
        Self.sharedBaseURL = url
        return url
    }

    private func loadFixtureHTML(_ relativeSubpath: String) throws -> String {
        let fileName = (relativeSubpath as NSString).lastPathComponent
        let baseName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        if let bundled = Bundle(for: Self.self).url(forResource: baseName, withExtension: ext) {
            return try String(contentsOf: bundled, encoding: .utf8)
        }
        let fixturesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        let fileURL = fixturesDir.appendingPathComponent(relativeSubpath)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try String(contentsOf: fileURL, encoding: .utf8)
        }
        throw NSError(
            domain: "ScriptStoreWebTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing HTML fixture at \(fileURL.path)"]
        )
    }

    private func makeHarness(
        store: ScriptStore,
        preinstalledScriptSource: String? = nil,
        freshWebView: Bool = false
    ) -> WebHarness {
        if freshWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = Self.sharedDataStore
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            ForumBrowserModel.disableWebKitScreenTimeForTesting(in: config)

            if let preinstalledScriptSource {
                config.userContentController.addUserScript(
                    WKUserScript(
                        source: preinstalledScriptSource,
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: true
                    )
                )
            }

            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            let bridge = AgentBridge(webView: webView)
            let controller = ScriptWebController(webView: webView, store: store, agentBridge: bridge)
            let waiter = NavigationWaiter()
            webView.navigationDelegate = waiter

            dedicatedWebViews.append(webView)
            activeControllers.append(controller)
            return WebHarness(webView: webView, bridge: bridge, controller: controller, waiter: waiter)
        }

        for existing in activeControllers {
            existing.detach()
        }
        activeControllers.removeAll()

        let webView: WKWebView
        let bridge: AgentBridge
        let waiter: NavigationWaiter
        if let existingWebView = Self.sharedWebView,
           let existingBridge = Self.sharedBridge,
           let existingWaiter = Self.sharedWaiter {
            webView = existingWebView
            bridge = existingBridge
            waiter = existingWaiter
            webView.stopLoading()
            webView.configuration.userContentController.removeAllUserScripts()
        } else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = Self.sharedDataStore
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            ForumBrowserModel.disableWebKitScreenTimeForTesting(in: config)
            let createdWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            let createdBridge = AgentBridge(webView: createdWebView)
            let createdWaiter = NavigationWaiter()
            createdWebView.navigationDelegate = createdWaiter
            Self.sharedWebView = createdWebView
            Self.sharedBridge = createdBridge
            Self.sharedWaiter = createdWaiter
            webView = createdWebView
            bridge = createdBridge
            waiter = createdWaiter
        }

        if let preinstalledScriptSource {
            webView.configuration.userContentController.addUserScript(
                WKUserScript(
                    source: preinstalledScriptSource,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        let controller = ScriptWebController(webView: webView, store: store, agentBridge: bridge)
        activeControllers.append(controller)
        return WebHarness(webView: webView, bridge: bridge, controller: controller, waiter: waiter)
    }

    private func waitUntil(
        timeoutSeconds: Double = 3.0,
        condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutSeconds * 1_000))
        while ContinuousClock.now < deadline {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let finalCheck = try await condition()
        XCTAssertTrue(finalCheck, "Condition was not met within \(timeoutSeconds)s")
    }

    // MARK: - 1. Load, Reload, App Restart & Preserving Built-in WKUserScripts

    func testSavedScriptsApplyOnLoadAfterReloadAndAcrossFreshStoreAndWebView() async throws {
        let baseURL = try await sharedFixtureBaseURL()

        let store = ScriptStore(directoryURL: tempDirectory)

        // Document-start script sets marker before <head> inline script executes
        _ = try store.create(
            id: "doc-start-flag",
            name: "Doc Start Marker",
            matchRules: ["*://127.0.0.1/t/*"],
            js: "document.documentElement.dataset.docStartMarker = 'ready-at-start';",
            injectionTime: .documentStart,
            environment: .page
        )

        // Document-end script hides replies via CSS and tags OP post via JS
        _ = try store.create(
            id: "op-only",
            name: "OP Only & Dark",
            matchRules: ["*://127.0.0.1/t/*"],
            js: """
            const count = Number(document.body.dataset.opRunCount || '0') + 1;
            document.body.dataset.opRunCount = String(count);
            """,
            css: """
            body { background-color: rgb(18, 20, 24) !important; }
            article.reply { display: none !important; }
            #shadow-pill { color: rgb(0, 200, 120) !important; }
            """,
            injectionTime: .documentEnd,
            environment: .isolated
        )

        let harness = makeHarness(
            store: store,
            preinstalledScriptSource: "window.__builtInObserverSurvived = true;"
        )

        let threadURL = baseURL.appendingPathComponent("t/1")
        try await harness.waiter.waitForLoad {
            _ = harness.webView.load(URLRequest(url: threadURL))
        }

        let initialCheck = try await harness.bridge.runJS(
            code: """
            const shadowHost = document.getElementById('shadow-host');
            const shadowPill = shadowHost.shadowRoot.getElementById('shadow-pill');
            return {
              bg: getComputedStyle(document.body).backgroundColor,
              replyDisplay: getComputedStyle(document.querySelector('article.reply')).display,
              shadowColor: getComputedStyle(shadowPill).color,
              opRunCount: document.body.dataset.opRunCount
            };
            """,
            environment: .isolated
        )
        let initialJSON = try JSONValue.parseObjectJSON(try XCTUnwrap(initialCheck.valueJSON))
        XCTAssertEqual(initialJSON["bg"], .string("rgb(18, 20, 24)"))
        XCTAssertEqual(initialJSON["replyDisplay"], .string("none"))
        XCTAssertEqual(initialJSON["shadowColor"], .string("rgb(0, 200, 120)"))
        XCTAssertEqual(initialJSON["opRunCount"], .string("1"))

        // Verify document-start timing AND preservation of built-in non-ScriptStore WKUserScripts
        let pageCheck = try await harness.bridge.runJS(
            code: """
            return {
              headMarker: window.__observedAtHeadParse,
              builtInSurvived: Boolean(window.__builtInObserverSurvived)
            };
            """,
            environment: .page
        )
        let pageJSON = try JSONValue.parseObjectJSON(try XCTUnwrap(pageCheck.valueJSON))
        XCTAssertEqual(pageJSON["headMarker"], .string("ready-at-start"))
        XCTAssertEqual(pageJSON["builtInSurvived"], .bool(true))

        // Reload the page and confirm scripts apply again cleanly
        try await harness.waiter.waitForLoad {
            _ = harness.webView.reload()
        }
        let reloadCheck = try await harness.bridge.runJS(
            code: """
            return {
              bg: getComputedStyle(document.body).backgroundColor,
              replyDisplay: getComputedStyle(document.querySelector('article.reply')).display,
              opRunCount: document.body.dataset.opRunCount
            };
            """,
            environment: .isolated
        )
        let reloadJSON = try JSONValue.parseObjectJSON(try XCTUnwrap(reloadCheck.valueJSON))
        XCTAssertEqual(reloadJSON["bg"], .string("rgb(18, 20, 24)"))
        XCTAssertEqual(reloadJSON["replyDisplay"], .string("none"))
        XCTAssertEqual(reloadJSON["opRunCount"], .string("1"))

        // Simulate killing and reopening the app: new ScriptStore + new WKWebView reading from disk
        let restartedStore = ScriptStore(directoryURL: tempDirectory)
        XCTAssertEqual(restartedStore.scripts.count, 2)
        let restartedHarness = makeHarness(store: restartedStore, freshWebView: true)
        try await restartedHarness.waiter.waitForLoad {
            _ = restartedHarness.webView.load(URLRequest(url: threadURL))
        }
        let restartCheck = try await restartedHarness.bridge.runJS(
            code: "return getComputedStyle(document.querySelector('article.reply')).display;",
            environment: .isolated
        )
        XCTAssertEqual(restartCheck.valueJSON, "\"none\"")
    }

    // MARK: - 2. SPA Route Changes (pushState / replaceState / popstate)

    func testSavedScriptReRunsOnPushStateReplaceStateAndPopstateRouteChanges() async throws {
        let baseURL = try await sharedFixtureBaseURL()

        let store = ScriptStore(directoryURL: tempDirectory)
        _ = try store.create(
            id: "spa-op-marker",
            name: "SPA OP Marker",
            matchRules: ["*://127.0.0.1/t/*"],
            js: """
            window.__scriptObservedPaths = window.__scriptObservedPaths || [];
            window.__scriptObservedPaths.push(window.location.pathname);
            const op = document.querySelector('article.op');
            if (op) {
              op.setAttribute('data-script-stamped', window.location.pathname);
            }
            """,
            css: "article.reply { display: none !important; }",
            injectionTime: .documentEnd,
            environment: .isolated
        )

        let harness = makeHarness(store: store)
        try await harness.waiter.waitForLoad {
            _ = harness.webView.load(URLRequest(url: baseURL.appendingPathComponent("t/1")))
        }

        // Initial load stamped /t/1 once
        let firstStamp = try await harness.bridge.runJS(
            code: "return document.querySelector('article.op')?.getAttribute('data-script-stamped');",
            environment: .isolated
        )
        XCTAssertEqual(firstStamp.valueJSON, "\"/t/1\"")

        // 1. pushState to /t/2 (re-renders feed DOM, then SPA hook re-runs userscript)
        _ = try await harness.bridge.runJS(code: "window.spaPush('/t/2');", environment: .page)
        try await waitUntil {
            let res = try await harness.bridge.runJS(
                code: "return document.querySelector('article.op')?.getAttribute('data-script-stamped');",
                environment: .isolated
            )
            return res.valueJSON == "\"/t/2\""
        }

        // 2. replaceState to /t/3
        _ = try await harness.bridge.runJS(code: "window.spaReplace('/t/3');", environment: .page)
        try await waitUntil {
            let res = try await harness.bridge.runJS(
                code: "return document.querySelector('article.op')?.getAttribute('data-script-stamped');",
                environment: .isolated
            )
            return res.valueJSON == "\"/t/3\""
        }

        // 3. pushState to non-matching '/about' does NOT run the script and removes its CSS
        _ = try await harness.bridge.runJS(code: "window.spaPush('/about');", environment: .page)
        try await waitUntil {
            let res = try await harness.bridge.runJS(
                code: "return document.adoptedStyleSheets.length;",
                environment: .isolated
            )
            return res.valueJSON == "0"
        }

        // 4. popstate (history.back()) back to '/t/3' re-applies CSS and re-runs JS
        _ = try await harness.bridge.runJS(code: "history.back();", environment: .page)
        try await waitUntil {
            let res = try await harness.bridge.runJS(
                code: """
                return {
                  stamped: document.querySelector('article.op')?.getAttribute('data-script-stamped'),
                  replyDisplay: getComputedStyle(document.querySelector('article.reply')).display,
                  runs: window.__scriptObservedPaths
                };
                """,
                environment: .isolated
            )
            guard let json = res.valueJSON, let obj = try? JSONValue.parseObjectJSON(json) else { return false }
            return obj["stamped"] == .string("/t/3") && obj["replyDisplay"] == .string("none")
        }

        let runsCheck = try await harness.bridge.runJS(
            code: "return window.__scriptObservedPaths;",
            environment: .isolated
        )
        XCTAssertEqual(runsCheck.valueJSON, #"["/t/1","/t/2","/t/3","/t/3"]"#)
    }

    // MARK: - 3. Disabled Script & Global Kill Switch

    func testDisabledScriptAndGlobalSwitchPreventInjectionAndRemoveInjectedCSS() async throws {
        let baseURL = try await sharedFixtureBaseURL()

        let store = ScriptStore(directoryURL: tempDirectory)
        let activeScript = try store.create(
            id: "active-dark",
            name: "Active Dark",
            matchRules: ["*://127.0.0.1/t/*"],
            js: "document.body.dataset.activeRan = 'yes';",
            css: "body { background-color: rgb(10, 20, 30) !important; }"
        )
        let disabledScript = try store.create(
            id: "disabled-banner",
            name: "Disabled Script",
            matchRules: ["*://127.0.0.1/t/*"],
            js: "document.body.dataset.disabledRan = 'yes';",
            css: "#route-title { display: none !important; }",
            isEnabled: false
        )

        let harness = makeHarness(store: store)
        let pageURL = baseURL.appendingPathComponent("t/1")
        try await harness.waiter.waitForLoad {
            _ = harness.webView.load(URLRequest(url: pageURL))
        }

        // Enabled script applied; disabled script did NOT apply
        let check1 = try await harness.bridge.runJS(
            code: """
            return {
              bg: getComputedStyle(document.body).backgroundColor,
              titleDisplay: getComputedStyle(document.getElementById('route-title')).display,
              activeRan: document.body.dataset.activeRan || 'no',
              disabledRan: document.body.dataset.disabledRan || 'no'
            };
            """,
            environment: .isolated
        )
        let json1 = try JSONValue.parseObjectJSON(try XCTUnwrap(check1.valueJSON))
        XCTAssertEqual(json1["bg"], .string("rgb(10, 20, 30)"))
        XCTAssertNotEqual(json1["titleDisplay"], .string("none"))
        XCTAssertEqual(json1["activeRan"], .string("yes"))
        XCTAssertEqual(json1["disabledRan"], .string("no"))
        _ = disabledScript

        // Turning off the global switch immediately strips injected CSS from the current page
        // AND prevents any script from running on reload!
        store.isGlobalEnabled = false
        try await waitUntil {
            let bgRes = try await harness.bridge.runJS(
                code: "return getComputedStyle(document.body).backgroundColor;",
                environment: .isolated
            )
            return bgRes.valueJSON == "\"rgb(255, 255, 255)\""
        }

        try await harness.waiter.waitForLoad {
            _ = harness.webView.reload()
        }
        let afterGlobalOffReload = try await harness.bridge.runJS(
            code: """
            return {
              bg: getComputedStyle(document.body).backgroundColor,
              activeRan: document.body.dataset.activeRan || 'no'
            };
            """,
            environment: .isolated
        )
        let offJSON = try JSONValue.parseObjectJSON(try XCTUnwrap(afterGlobalOffReload.valueJSON))
        XCTAssertEqual(offJSON["bg"], .string("rgb(255, 255, 255)"))
        XCTAssertEqual(offJSON["activeRan"], .string("no"))

        // Re-enabling global switch, then disabling the individual script and reloading leaves page untouched
        store.isGlobalEnabled = true
        _ = try store.setEnabled(id: activeScript.id, isEnabled: false)
        try await harness.waiter.waitForLoad {
            _ = harness.webView.reload()
        }
        let afterPerScriptOff = try await harness.bridge.runJS(
            code: """
            return {
              bg: getComputedStyle(document.body).backgroundColor,
              activeRan: document.body.dataset.activeRan || 'no'
            };
            """,
            environment: .isolated
        )
        let perScriptOffJSON = try JSONValue.parseObjectJSON(try XCTUnwrap(afterPerScriptOff.valueJSON))
        XCTAssertEqual(perScriptOffJSON["bg"], .string("rgb(255, 255, 255)"))
        XCTAssertEqual(perScriptOffJSON["activeRan"], .string("no"))
    }

    // MARK: - 4. Strict Content Security Policy Fixture

    func testSavedScriptCSSAndJSApplyUnderStrictCSPHeader() async throws {
        let baseURL = try await sharedFixtureBaseURL()

        let store = ScriptStore(directoryURL: tempDirectory)
        _ = try store.create(
            id: "strict-csp-isolated",
            name: "Strict CSP Dark",
            matchRules: ["*://127.0.0.1/strict*"],
            js: """
            const computedViaEval = eval('20 + 22');
            document.getElementById('csp-target').setAttribute('data-isolated-eval', String(computedViaEval));
            """,
            css: """
            body { background-color: rgb(12, 16, 22) !important; }
            #csp-heading { color: rgb(80, 200, 120) !important; }
            """,
            injectionTime: .documentEnd,
            environment: .isolated
        )
        _ = try store.create(
            id: "strict-csp-page",
            name: "Strict CSP Page Stamp",
            matchRules: ["*://127.0.0.1/strict*"],
            js: "document.getElementById('csp-target').setAttribute('data-page-world', 'ok');",
            injectionTime: .documentEnd,
            environment: .page
        )

        let harness = makeHarness(store: store)
        try await harness.waiter.waitForLoad {
            _ = harness.webView.load(URLRequest(url: baseURL.appendingPathComponent("strict")))
        }

        // Control check: an ordinary <style> element IS blocked by strict style-src 'self',
        // proving the CSP header is genuinely enforced while adoptedStyleSheets + WKUserScript succeed!
        let verify = try await harness.bridge.runJS(
            code: """
            const inlineStyle = document.createElement('style');
            inlineStyle.textContent = '#csp-target { color: rgb(255, 0, 0) !important; }';
            document.head.appendChild(inlineStyle);
            const target = document.getElementById('csp-target');
            return {
              bodyBg: getComputedStyle(document.body).backgroundColor,
              headingColor: getComputedStyle(document.getElementById('csp-heading')).color,
              inlineBlockedTargetColor: getComputedStyle(target).color,
              isolatedEval: target.getAttribute('data-isolated-eval'),
              pageStamp: target.getAttribute('data-page-world')
            };
            """,
            environment: .isolated
        )
        let json = try JSONValue.parseObjectJSON(try XCTUnwrap(verify.valueJSON))
        XCTAssertEqual(json["bodyBg"], .string("rgb(12, 16, 22)"))
        XCTAssertEqual(json["headingColor"], .string("rgb(80, 200, 120)"))
        XCTAssertNotEqual(json["inlineBlockedTargetColor"], .string("rgb(255, 0, 0)"))
        XCTAssertEqual(json["isolatedEval"], .string("42"))
        XCTAssertEqual(json["pageStamp"], .string("ok"))
        XCTAssertTrue(store.scriptErrors.isEmpty)
    }

    // MARK: - 5. Error Capture Across Both Content Worlds & Live script_save Application

    func testScriptErrorsInBothWorldsReportViaIsolatedHandlerAndLiveScriptSaveAppliesImmediately() async throws {
        let baseURL = try await sharedFixtureBaseURL()

        let store = ScriptStore(directoryURL: tempDirectory)
        let brokenIsolated = try store.create(
            id: "broken-isolated",
            name: "Broken Isolated Script",
            matchRules: ["*://127.0.0.1/t/*"],
            js: "throw new Error('Isolated selector exploded');",
            environment: .isolated
        )
        let brokenPage = try store.create(
            id: "broken-page",
            name: "Broken Page Script",
            matchRules: ["*://127.0.0.1/t/*"],
            js: "await Promise.resolve(); throw new Error('Page async failure');",
            environment: .page
        )

        let harness = makeHarness(store: store)
        try await harness.waiter.waitForLoad {
            _ = harness.webView.load(URLRequest(url: baseURL.appendingPathComponent("t/1")))
        }

        try await waitUntil {
            store.error(for: brokenIsolated.id) != nil && store.error(for: brokenPage.id) != nil
        }

        XCTAssertTrue(store.error(for: brokenIsolated.id)?.message.contains("Isolated selector exploded") == true)
        XCTAssertTrue(store.error(for: brokenPage.id)?.message.contains("Page async failure") == true)

        // Bridge isolation invariant: wukongAgent handler is still undefined in .page world!
        let handlerCheck = try await harness.bridge.runJS(
            code: "return typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wukongAgent);",
            environment: .page
        )
        XCTAssertEqual(handlerCheck.valueJSON, "\"undefined\"")

        // Clear broken scripts and verify `script_save` on an already-open page applies right away
        // AND installs SPA route hooks even without reloading!
        let cleanStore = ScriptStore(directoryURL: tempDirectory.appendingPathComponent("live-save", isDirectory: true))
        let cleanHarness = makeHarness(store: cleanStore)
        try await cleanHarness.waiter.waitForLoad {
            _ = cleanHarness.webView.load(URLRequest(url: baseURL.appendingPathComponent("t/10")))
        }

        let registry = ToolRegistry.m2(
            bridge: cleanHarness.bridge,
            scriptStore: cleanStore,
            liveApplier: cleanHarness.controller,
            currentUserPrompt: { "Always hide replies here" }
        )

        let saveDispatch = try await registry.dispatch(
            toolName: "script_save",
            arguments: [
                "name": .string("Live Hide Replies"),
                "match_rules": .array([.string("*://127.0.0.1/t/*")]),
                "css": .string("article.reply { display: none !important; }"),
                "js": .string("document.querySelector('article.op')?.setAttribute('data-live-saved', window.location.pathname);")
            ]
        )
        XCTAssertFalse(saveDispatch.isError, saveDispatch.output)
        let savedJSON = try JSONValue.parseObjectJSON(saveDispatch.output)
        let savedID = try XCTUnwrap(savedJSON["script_id"]?.stringValue)
        XCTAssertEqual(savedJSON["applied_to_current_page"], .bool(true))

        // Immediately active on /t/10 without reload!
        let liveCheck = try await cleanHarness.bridge.runJS(
            code: """
            return {
              replyDisplay: getComputedStyle(document.querySelector('article.reply')).display,
              opAttr: document.querySelector('article.op')?.getAttribute('data-live-saved')
            };
            """,
            environment: .isolated
        )
        let liveObj = try JSONValue.parseObjectJSON(try XCTUnwrap(liveCheck.valueJSON))
        XCTAssertEqual(liveObj["replyDisplay"], .string("none"))
        XCTAssertEqual(liveObj["opAttr"], .string("/t/10"))

        // Immediate SPA pushState to /t/11 BEFORE any full reload also triggers the newly saved script!
        _ = try await cleanHarness.bridge.runJS(code: "window.spaPush('/t/11');", environment: .page)
        try await waitUntil {
            let res = try await cleanHarness.bridge.runJS(
                code: "return document.querySelector('article.op')?.getAttribute('data-live-saved');",
                environment: .isolated
            )
            return res.valueJSON == "\"/t/11\""
        }

        // Deleting via script_delete immediately removes the live CSS from the open page
        let delDispatch = try await registry.dispatch(
            toolName: "script_delete",
            arguments: ["script_id": .string(savedID)]
        )
        XCTAssertFalse(delDispatch.isError)
        let afterDelete = try await cleanHarness.bridge.runJS(
            code: "return getComputedStyle(document.querySelector('article.reply')).display;",
            environment: .isolated
        )
        XCTAssertNotEqual(afterDelete.valueJSON, "\"none\"")
    }

    private actor RecordedAppModelScriptClient: AgentModelClient {
        private var turn = 0
        private(set) var recordedSystemPrompts: [String] = []
        private(set) var recordedToolNames: [String] = []

        func completeToolTurn(
            system: String,
            messages: [AgentModelTurn],
            tools: [AgentToolDefinition],
            configuration: ProviderConfiguration,
            provider: AIProvider,
            maxTokens: Int
        ) async throws -> AgentModelTurnResponse {
            turn += 1
            recordedSystemPrompts.append(system)
            recordedToolNames = tools.map(\.name)

            if turn == 1 {
                return AgentModelTurnResponse(
                    text: "",
                    toolCalls: [
                        AgentModelToolCall(
                            id: "call_save_op_only",
                            name: "script_save",
                            arguments: [
                                "name": .string("OP Only & Dark Mode"),
                                "match_rules": .array([.string("*://127.0.0.1/t/*")]),
                                "css": .string("body { background-color: rgb(15, 23, 42) !important; } article.reply { display: none !important; }"),
                                "js": .string("document.body.dataset.appSavedScript = 'active';")
                            ]
                        )
                    ],
                    stopReason: "tool_use",
                    usage: AgentTokenUsage(inputTokens: 320, outputTokens: 85)
                )
            }
            return AgentModelTurnResponse(
                text: "Saved OP Only & Dark Mode for threads on this site.",
                toolCalls: [],
                stopReason: "end_turn",
                usage: AgentTokenUsage(inputTokens: 410, outputTokens: 28)
            )
        }
    }

    func testAppModelWiresScriptStoreGlobalSwitchAndBrowserAgentM2Tools() async throws {
        let baseURL = try await sharedFixtureBaseURL()

        let stateURL = tempDirectory
            .appendingPathComponent("app-state", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let keys = InMemoryProviderKeyStore()
        let forumConfig = URLSessionConfiguration.ephemeral
        forumConfig.protocolClasses = [OfflineForumURLProtocol.self]
        let stubForumService = ForumService(
            session: URLSession(configuration: forumConfig),
            pacer: ForumRequestPacer(clock: InstantPacingClock())
        )
        let podcastDirectory = tempDirectory.appendingPathComponent("Podcasts", isDirectory: true)
        let sharedBrowser = ForumBrowserModel(
            contentRules: ContentRuleLibrary(store: nil, directory: nil),
            websiteDataStore: Self.sharedDataStore
        )
        sharedBrowser.webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer {
            sharedBrowser.stopLoading()
            sharedBrowser.onPageContextChanged = nil
            sharedBrowser.webView.navigationDelegate = nil
            sharedBrowser.webView.uiDelegate = nil
            sharedBrowser.webView.configuration.userContentController.removeAllUserScripts()
            sharedBrowser.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        }

        var activeApp: AppModel?
        defer {
            if let instance = activeApp {
                instance.browser.stopLoading()
                instance.pauseDigest()
                instance.podcast.pauseGeneration()
                instance.scriptWebController.detach()
            }
            activeApp = nil
        }

        let makeIsolatedApp: () -> AppModel = {
            if let previous = activeApp {
                previous.browser.stopLoading()
                previous.pauseDigest()
                previous.podcast.pauseGeneration()
                previous.scriptWebController.detach()
                activeApp = nil
            }
            let instance = AppModel(
                store: PersistentStore(fileURL: stateURL, keys: keys),
                forumService: stubForumService,
                browser: sharedBrowser,
                cloudSync: CloudSyncController(
                    transport: nil,
                    files: nil,
                    defaults: nil,
                    schedulesAutomatically: false
                ),
                podcastDirectory: podcastDirectory,
                spotlightIndex: FakeSpotlightIndex(),
                topicActivityDonor: FakeTopicActivityDonor(),
                backgroundGrace: NoOpBackgroundGrace()
            )
            instance.usesDirectForumRequests = true
            instance.browser.stopLoading()
            instance.browser.onPageContextChanged = nil
            activeApp = instance
            return instance
        }

        weak var trackedApp: AppModel?
        weak var trackedStore: ScriptStore?
        weak var trackedController: ScriptWebController?

        let threadURL = baseURL.appendingPathComponent("t/99")
        let userPrompt = "Always show only the OP post and switch to dark mode"

        do {
            let app = makeIsolatedApp()
            trackedApp = app
            trackedStore = app.scriptStore
            trackedController = app.scriptWebController

            var anthropicConfig = app.settings.configuration(for: .anthropic)
            anthropicConfig.apiKey = "fake-recorded-key"
            anthropicConfig.model = "claude-haiku-5-5"
            app.settings.setConfiguration(anthropicConfig, for: .anthropic)
            app.settings.setModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .browserAgent)
            app.settings.aiConsent[AIProvider.anthropic.rawValue] = .allowed(Date())

            let fakeClient = RecordedAppModelScriptClient()
            app.browserAgent.configureDebugModelClient(fakeClient)

            app.browser.ignoresNavigationFailures = true
            app.browser.load(threadURL)
            await app.browser.waitUntilSettled(timeout: .seconds(30))
            try await waitUntil(timeoutSeconds: 15.0) {
                let ready = try? await app.browser.agentBridge.runJS(
                    code: "return window.location.pathname === '/t/99' && document.querySelector('article.reply') !== null;",
                    environment: .isolated
                )
                return ready?.valueJSON == "true"
            }

            await app.browserAgent.sendAndWait(userPrompt)

            let exposedTools = await fakeClient.recordedToolNames
            XCTAssertTrue(exposedTools.contains("script_save"))
            XCTAssertTrue(exposedTools.contains("script_list"))
            XCTAssertTrue(exposedTools.contains("script_read"))
            XCTAssertTrue(exposedTools.contains("script_update"))
            XCTAssertTrue(exposedTools.contains("script_delete"))

            XCTAssertEqual(app.scriptStore.scripts.count, 1)
            let saved = try XCTUnwrap(app.scriptStore.scripts.first)
            XCTAssertEqual(saved.source, .agent(userPrompt: userPrompt))
            XCTAssertTrue(FileManager.default.fileExists(atPath: app.scriptStore.scriptFileURL(for: saved.id).path))

            // Immediately active on the open page
            let liveCheck = try await app.browser.agentBridge.runJS(
                code: """
                return {
                  bg: getComputedStyle(document.body).backgroundColor,
                  replyDisplay: getComputedStyle(document.querySelector('article.reply')).display,
                  marker: document.body.dataset.appSavedScript
                };
                """,
                environment: .isolated
            )
            let liveObj = try JSONValue.parseObjectJSON(try XCTUnwrap(liveCheck.valueJSON))
            XCTAssertEqual(liveObj["bg"], .string("rgb(15, 23, 42)"))
            XCTAssertEqual(liveObj["replyDisplay"], .string("none"))
            XCTAssertEqual(liveObj["marker"], .string("active"))

            // Toggling scriptStore.isGlobalEnabled updates AppSettings and persists across AppModel restart
            app.scriptStore.isGlobalEnabled = false
            XCTAssertFalse(app.settings.browserScriptsEnabled)
            app.flushPendingSaves()
        }

        let relaunchedDisabled = makeIsolatedApp()
        XCTAssertFalse(relaunchedDisabled.scriptStore.isGlobalEnabled)
        XCTAssertEqual(relaunchedDisabled.scriptStore.scripts.count, 1)

        // Re-enabling via settings syncs back to scriptStore and auto-injects after reload in a fresh AppModel
        relaunchedDisabled.settings.browserScriptsEnabled = true
        XCTAssertTrue(relaunchedDisabled.scriptStore.isGlobalEnabled)
        relaunchedDisabled.flushPendingSaves()

        let relaunchedEnabled = makeIsolatedApp()
        XCTAssertTrue(relaunchedEnabled.scriptStore.isGlobalEnabled)
        let restartedURL = baseURL.appendingPathComponent("t/100")
        relaunchedEnabled.browser.ignoresNavigationFailures = true
        relaunchedEnabled.browser.load(restartedURL)
        await relaunchedEnabled.browser.waitUntilSettled(timeout: .seconds(30))
        try await waitUntil(timeoutSeconds: 15.0) {
            let ready = try? await relaunchedEnabled.browser.agentBridge.runJS(
                code: "return window.location.pathname === '/t/100' && document.querySelector('article.reply') !== null;",
                environment: .isolated
            )
            return ready?.valueJSON == "true"
        }

        let restartedCheck = try await relaunchedEnabled.browser.agentBridge.runJS(
            code: """
            return {
              bg: getComputedStyle(document.body).backgroundColor,
              replyDisplay: getComputedStyle(document.querySelector('article.reply')).display,
              marker: document.body.dataset.appSavedScript
            };
            """,
            environment: .isolated
        )
        let restartedObj = try JSONValue.parseObjectJSON(try XCTUnwrap(restartedCheck.valueJSON))
        XCTAssertEqual(restartedObj["bg"], .string("rgb(15, 23, 42)"))
        XCTAssertEqual(restartedObj["replyDisplay"], .string("none"))
        XCTAssertEqual(restartedObj["marker"], .string("active"))

        // Verify previous AppModel + ScriptStore + ScriptWebController deallocated cleanly (no retain cycles)
        try await waitUntil(timeoutSeconds: 10.0) {
            trackedApp == nil && trackedStore == nil && trackedController == nil
        }
    }
}
