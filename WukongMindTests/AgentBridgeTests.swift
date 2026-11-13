import Foundation
import Network
import os
import UIKit
import WebKit
import XCTest
@testable import WukongMind

/// Real `WKWebView` tests on local HTML fixture pages in the repository (plus a
/// loopback `127.0.0.1` HTTP server for real `Content-Security-Policy` headers).
/// Never touches external live websites.
@MainActor
final class AgentBridgeTests: XCTestCase {
    // MARK: - Fixture Loader & Loopback HTTP Server

    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var timeoutTask: Task<Void, Never>?

        func waitForLoad(timeoutSeconds: Double = 45, retries: Int = 1, _ start: () -> Void) async throws {
            var lastError: Error?
            for attempt in 0...retries {
                do {
                    try await waitForSingleLoad(timeoutSeconds: timeoutSeconds, start)
                    return
                } catch {
                    lastError = error
                    if attempt < retries {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            throw lastError!
        }

        private func waitForSingleLoad(timeoutSeconds: Double, _ start: () -> Void) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                self.timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.finish(
                        with: NSError(
                            domain: "AgentBridgeTests",
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

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(
                with: NSError(
                    domain: "AgentBridgeTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "WebContent process terminated during navigation"]
                )
            )
        }
    }

    /// Minimal loopback HTTP server bound strictly to `127.0.0.1` (matching
    /// `ContentBlockerTests.LocalHTTPServer`) so `Content-Security-Policy`
    /// response headers are enforced identically to a real origin on CI and locally.
    private final class LoopbackFixtureServer: @unchecked Sendable {
        struct Route {
            var status: Int = 200
            var contentType: String = "text/html; charset=utf-8"
            var headers: [String: String] = [:]
            var body: Data
        }

        private let listener: NWListener
        private let queue = DispatchQueue(label: "wukong.agentbridge.fixture-server")
        private let routes: [String: Route]
        private(set) var port: UInt16 = 0

        init(routes: [String: Route]) throws {
            self.routes = routes
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            self.listener = try NWListener(using: params)
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

                listener.newConnectionHandler = { [routes, queue] connection in
                    Self.serve(connection: connection, routes: routes, queue: queue)
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
            let baseURL = URL(string: "http://127.0.0.1:\(readyPort)")!
            let probeSession = URLSession(configuration: .ephemeral)
            defer { probeSession.invalidateAndCancel() }
            _ = try await probeSession.data(from: baseURL.appendingPathComponent("__ready"))
            return baseURL
        }

        func stop() {
            listener.cancel()
        }

        private static func serve(
            connection: NWConnection,
            routes: [String: Route],
            queue: DispatchQueue
        ) {
            connection.start(queue: queue)
            receive(on: connection, buffer: Data(), routes: routes, queue: queue)
        }

        private static func receive(
            on connection: NWConnection,
            buffer: Data,
            routes: [String: Route],
            queue: DispatchQueue
        ) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                var buffer = buffer
                if let data {
                    buffer.append(data)
                }
                if let rawRequest = String(data: buffer, encoding: .utf8),
                   rawRequest.contains("\r\n\r\n") {
                    respond(to: rawRequest, on: connection, routes: routes, queue: queue)
                } else if !isComplete, error == nil {
                    receive(on: connection, buffer: buffer, routes: routes, queue: queue)
                } else {
                    connection.cancel()
                }
            }
        }

        private static func respond(
            to rawRequest: String,
            on connection: NWConnection,
            routes: [String: Route],
            queue: DispatchQueue
        ) {
            let firstLine = rawRequest.split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = firstLine.split(separator: " ")
            let rawPath = parts.count >= 2 ? String(parts[1]) : "/"
            let cleanPath = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

            let route = routes[cleanPath] ?? Route(
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

            connection.send(
                content: payload,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in
                    queue.asyncAfter(deadline: .now() + 2) {
                        connection.cancel()
                    }
                }
            )
        }
    }

    private var activeWebViews: [WKWebView] = []
    private var activeWindows: [UIWindow] = []

    override func tearDown() {
        for webView in activeWebViews {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.removeFromSuperview()
        }
        activeWebViews.removeAll()
        for window in activeWindows {
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
        }
        activeWindows.removeAll()
        super.tearDown()
    }

    private func loadFixtureHTML(_ filename: String) throws -> String {
        let baseName = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        if let bundled = Bundle(for: Self.self).url(forResource: baseName, withExtension: ext) {
            return try String(contentsOf: bundled, encoding: .utf8)
        }
        let fixturesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AgentBridge", isDirectory: true)
        let fileURL = fixturesDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try String(contentsOf: fileURL, encoding: .utf8)
        }
        throw NSError(
            domain: "AgentBridgeTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing HTML fixture at \(fileURL.path)"]
        )
    }

    private func makeHostedWebView() -> (WKWebView, AgentBridge, NavigationWaiter) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        ForumBrowserModel.disableWebKitScreenTimeForTesting(in: config)

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        let bridge = AgentBridge(webView: webView)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = UIViewController()
        controller.view.frame = window.bounds
        controller.view.addSubview(webView)
        webView.frame = controller.view.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        activeWindows.append(window)
        activeWebViews.append(webView)

        return (webView, bridge, waiter)
    }

    // MARK: - run_js in Both Worlds & Isolated Reply Handler

    func testRunJSInPageAndIsolatedWorldsAndIsolatedOnlyReplyHandler() async throws {
        let html = try loadFixtureHTML("article.html")
        let (webView, bridge, waiter) = makeHostedWebView()
        try await waiter.waitForLoad {
            webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.local/article"))
        }

        // 1. Isolated world: async/await + JSON return + console capture; cannot see page JS globals.
        let isoResult = try await bridge.runJS(
            code: """
            console.log("hello from isolated", 7);
            console.warn("watch out");
            const delayed = await new Promise((r) => setTimeout(() => r({ sum: 20 + 22 }), 20));
            return {
              pageCounterType: typeof window.pageCounter,
              delayedSum: delayed.sum,
              heading: document.querySelector("h1")?.textContent?.trim()
            };
            """,
            environment: .isolated
        )
        XCTAssertNil(isoResult.error)
        XCTAssertEqual(isoResult.consoleOutput, ["hello from isolated 7", "[warn] watch out"])
        let isoJSON = try XCTUnwrap(isoResult.valueJSON?.data(using: .utf8))
        let isoDict = try XCTUnwrap(JSONSerialization.jsonObject(with: isoJSON) as? [String: Any])
        XCTAssertEqual(isoDict["pageCounterType"] as? String, "undefined")
        XCTAssertEqual(isoDict["delayedSum"] as? Int, 42)
        XCTAssertEqual(isoDict["heading"] as? String, "Understanding Content Worlds")

        // Setting a global in isolated world must not leak into page world.
        _ = try await bridge.runJS(code: "window.isolatedSecret = 'only-iso';", environment: .isolated)

        // 2. Page world: sees and calls page-defined globals, does NOT see isolated globals.
        let pageResult = try await bridge.runJS(
            code: """
            const bumped = window.bumpPageCounter(8);
            return {
              bumped,
              isolatedSecretType: typeof window.isolatedSecret
            };
            """,
            environment: .page
        )
        XCTAssertNil(pageResult.error)
        let pageJSON = try XCTUnwrap(pageResult.valueJSON?.data(using: .utf8))
        let pageDict = try XCTUnwrap(JSONSerialization.jsonObject(with: pageJSON) as? [String: Any])
        XCTAssertEqual(pageDict["bumped"] as? Int, 50)
        XCTAssertEqual(pageDict["isolatedSecretType"] as? String, "undefined")

        // 3. WKScriptMessageHandlerWithReply (`wukongAgent`): invisible in `.page`, replies in `.isolated`!
        let pageHandlerCheck = try await bridge.runJS(
            code: "return typeof window.webkit?.messageHandlers?.wukongAgent;",
            environment: .page
        )
        XCTAssertEqual(pageHandlerCheck.valueJSON, "\"undefined\"")

        let isoReplyCheck = try await bridge.runJS(
            code: """
            const reply = await window.webkit.messageHandlers.wukongAgent.postMessage({
              action: "ping",
              echo: "m1-verified"
            });
            return reply;
            """,
            environment: .isolated
        )
        XCTAssertNil(isoReplyCheck.error)
        let replyData = try XCTUnwrap(isoReplyCheck.valueJSON?.data(using: .utf8))
        let replyObj = try XCTUnwrap(JSONSerialization.jsonObject(with: replyData) as? [String: Any])
        XCTAssertEqual(replyObj["ok"] as? Bool, true)
        XCTAssertEqual(replyObj["world"] as? String, "WukongAgent")
        XCTAssertEqual(replyObj["echo"] as? String, "m1-verified")

        // 4. Runtime & syntax errors return structured error without crashing.
        let runtimeErr = try await bridge.runJS(
            code: "console.log('step before throw'); throw new Error('deliberate boom');",
            environment: .isolated
        )
        XCTAssertEqual(runtimeErr.consoleOutput, ["step before throw"])
        XCTAssertTrue(runtimeErr.error?.contains("deliberate boom") == true)
    }

    // MARK: - wukong.files: isolated run_js only

    func testWukongFilesWritesFromIsolatedRunJSButNotFromUserscriptsOrThePageWorld() async throws {
        let html = try loadFixtureHTML("article.html")
        let (webView, bridge, waiter) = makeHostedWebView()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridgeFiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        bridge.workspace = AgentWorkspace(root: root)
        try await waiter.waitForLoad {
            webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.local/article"))
        }

        // 1. Isolated run_js: write, then append, and hand back its own token.
        let agent = try await bridge.runJS(
            code: """
            const heading = document.querySelector("h1").textContent.trim();
            const first = await wukong.files.write("crawls/fixture/page-001.txt", heading + "\\n");
            const second = await wukong.files.append("crawls/fixture/page-001.txt", "second line\\n");
            return { first, second, token: __wukongCallToken };
            """,
            environment: .isolated
        )
        XCTAssertNil(agent.error)
        let saved = try String(contentsOf: root.appendingPathComponent("crawls/fixture/page-001.txt"), encoding: .utf8)
        XCTAssertEqual(saved, "Understanding Content Worlds\nsecond line\n")
        let agentJSON = try XCTUnwrap(agent.valueJSON?.data(using: .utf8))
        let agentDict = try XCTUnwrap(JSONSerialization.jsonObject(with: agentJSON) as? [String: Any])
        let first = try XCTUnwrap(agentDict["first"] as? [String: Any])
        XCTAssertEqual(first["path"] as? String, "crawls/fixture/page-001.txt")
        let staleToken = try XCTUnwrap(agentDict["token"] as? String)

        // 2. A saved userscript runs in the same isolated world, outside run_js: no helpers,
        //    and the handler refuses it with no token, a made-up one, or the finished call's.
        let userscript = try await webView.callAsyncJavaScript(
            """
            const handler = window.webkit.messageHandlers.wukongAgent;
            const attempt = async (token) => {
              try {
                await handler.postMessage({ action: "files", op: "write", path: "evil.txt", text: "x", token });
                return "wrote";
              } catch (error) {
                return String(error.message || error);
              }
            };
            return JSON.stringify({
              helpers: typeof wukong,
              none: await attempt(undefined),
              madeUp: await attempt("00000000-0000-0000-0000-000000000000"),
              stale: await attempt(staleToken)
            });
            """,
            arguments: ["staleToken": staleToken],
            in: nil,
            contentWorld: AgentBridge.isolatedWorld
        )
        let userscriptData = try XCTUnwrap((userscript as? String)?.data(using: .utf8))
        let outcome = try XCTUnwrap(JSONSerialization.jsonObject(with: userscriptData) as? [String: String])
        XCTAssertEqual(outcome["helpers"], "undefined")
        for key in ["none", "madeUp", "stale"] {
            XCTAssertEqual(outcome[key], "wukong.files is only available inside the Agent's run_js.", key)
        }

        // 3. The page world has neither the helpers nor the handler.
        let page = try await bridge.runJS(
            code: "return [typeof wukong, typeof window.webkit?.messageHandlers?.wukongAgent];",
            environment: .page
        )
        XCTAssertEqual(page.valueJSON, #"["undefined","undefined"]"#)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("evil.txt").path))

        // 4. The workspace rules still apply inside run_js.
        let escape = try await bridge.runJS(code: "await wukong.files.write('../escape.txt', 'x');", environment: .isolated)
        XCTAssertTrue(escape.error?.contains("'..'") == true, escape.error ?? "nil")
    }

    // MARK: - Strict CSP Header: eval & adoptedStyleSheets CSS Injection

    func testStrictCSPHeaderBlocksPageEvalButAllowsIsolatedEvalAndAdoptedStyleSheets() async throws {
        let strictHTML = try loadFixtureHTML("strict-csp.html")
        let csp = "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'"
        let server = try LoopbackFixtureServer(
            routes: [
                "/strict": .init(
                    headers: ["Content-Security-Policy": csp],
                    body: Data(strictHTML.utf8)
                )
            ]
        )
        let baseURL = try await server.start()
        defer { server.stop() }

        let (webView, bridge, waiter) = makeHostedWebView()
        try await waiter.waitForLoad {
            webView.load(URLRequest(url: baseURL.appendingPathComponent("strict")))
        }

        // Control: inline <style> is blocked by strict `style-src 'self'`.
        let inlineStyleBlocked = try await bridge.runJS(
            code: """
            const style = document.createElement("style");
            style.textContent = "#csp-target { color: rgb(200, 10, 20); }";
            document.head.appendChild(style);
            return window.getComputedStyle(document.getElementById("csp-target")).color;
            """,
            environment: .isolated
        )
        XCTAssertNotEqual(inlineStyleBlocked.valueJSON, "\"rgb(200, 10, 20)\"")

        // Page-world `eval` is blocked by CSP and includes the isolated-world hint.
        let pageEval = try await bridge.runJS(
            code: "return eval('21 * 2');",
            environment: .page
        )
        XCTAssertNotNil(pageEval.error)
        XCTAssertTrue(pageEval.error?.contains("isolated") == true)

        // Isolated-world `eval` succeeds under the exact same strict CSP!
        let isoEval = try await bridge.runJS(
            code: "return eval('21 * 2');",
            environment: .isolated
        )
        XCTAssertNil(isoEval.error)
        XCTAssertEqual(isoEval.valueJSON, "42")

        // `injectCSS` via `adoptedStyleSheets` works under strict `style-src 'self'`.
        let injected = try await bridge.injectCSS(
            css: "#csp-target { color: rgb(12, 160, 80) !important; }",
            id: "theme-override"
        )
        XCTAssertEqual(injected.sheetID, "theme-override")

        let computedAfterInject = try await bridge.runJS(
            code: "return window.getComputedStyle(document.getElementById('csp-target')).color;",
            environment: .isolated
        )
        XCTAssertEqual(computedAfterInject.valueJSON, "\"rgb(12, 160, 80)\"")

        // Updating the same `id` replaces rules in place, even after page clears `adoptedStyleSheets`.
        _ = try await bridge.runJS(code: "document.adoptedStyleSheets = [];", environment: .page)
        _ = try await bridge.injectCSS(
            css: "#csp-target { color: rgb(30, 90, 220) !important; }",
            id: "theme-override"
        )
        let computedAfterUpdate = try await bridge.runJS(
            code: "return window.getComputedStyle(document.getElementById('csp-target')).color;",
            environment: .isolated
        )
        XCTAssertEqual(computedAfterUpdate.valueJSON, "\"rgb(30, 90, 220)\"")
    }

    func testInjectCSSAlsoAppliesToOpenShadowRoots() async throws {
        let html = try loadFixtureHTML("article.html")
        let (webView, bridge, waiter) = makeHostedWebView()
        try await waiter.waitForLoad {
            webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.local/article"))
        }

        let res = try await bridge.injectCSS(
            css: "#shadow-badge { color: rgb(220, 40, 90) !important; }",
            id: "shadow-theme"
        )
        XCTAssertGreaterThanOrEqual(res.appliedRootCount, 2, "Should apply to document + open shadowRoot")

        let shadowColor = try await bridge.runJS(
            code: """
            const badge = document.getElementById("widget-host").shadowRoot.getElementById("shadow-badge");
            return window.getComputedStyle(badge).color;
            """,
            environment: .isolated
        )
        XCTAssertEqual(shadowColor.valueJSON, "\"rgb(220, 40, 90)\"")
    }

    // MARK: - read_page (structure, text, html, selector, maxLength, password masking)

    func testReadPageModesVisibilitySelectorsAndPasswordMasking() async throws {
        let html = try loadFixtureHTML("article.html")
        let (webView, bridge, waiter) = makeHostedWebView()
        try await waiter.waitForLoad {
            webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.local/article"))
        }

        // 1. Structure summary: visible elements, links, controls, stable selectors, masked password.
        let structure = try await bridge.readPage(mode: .structure, selector: nil, maxLength: nil)
        XCTAssertTrue(structure.contains("Page: Wukong Fixture Article"))
        XCTAssertTrue(structure.contains("Understanding Content Worlds"))
        XCTAssertTrue(structure.contains("Documentation"))
        XCTAssertTrue(structure.contains("#accept-cookies"))
        XCTAssertTrue(structure.contains(#"a[data-testid="pricing-link"]"#))
        XCTAssertTrue(structure.contains(#"select[data-testid="plan-picker"]"#))
        XCTAssertFalse(structure.contains("css-9f8a7b12"), "Noisy hash classes should be omitted from selectors")
        XCTAssertFalse(structure.contains("Hidden display none text"))
        XCTAssertFalse(structure.contains("Hidden visibility text"))
        XCTAssertFalse(structure.contains("Zero opacity text"))
        XCTAssertFalse(structure.contains("HTML hidden attribute text"))
        XCTAssertFalse(structure.contains("s3cr3t-pass-do-not-leak"), "Password value must never appear in read_page")
        XCTAssertTrue(structure.contains("[masked]"))

        // 2. Plain text mode scoped to `#main-article`.
        let text = try await bridge.readPage(mode: .text, selector: "#main-article", maxLength: nil)
        XCTAssertTrue(text.contains("Understanding Content Worlds"))
        XCTAssertTrue(text.contains("Isolated worlds access the DOM"))
        XCTAssertFalse(text.contains("Accept cookies"), "Outside #main-article scope")

        // 3. HTML mode scoped to `#cookie-banner` + maxLength limit.
        let bannerHTML = try await bridge.readPage(mode: .html, selector: "#cookie-banner", maxLength: nil)
        XCTAssertTrue(bannerHTML.contains("id=\"cookie-banner\""))
        XCTAssertTrue(bannerHTML.contains("Accept cookies"))

        let clipped = try await bridge.readPage(mode: .text, selector: nil, maxLength: 40)
        XCTAssertTrue(clipped.contains("max_length=40"))

        // 4. Unmatched & invalid selectors throw clear errors.
        do {
            _ = try await bridge.readPage(mode: .text, selector: "#does-not-exist", maxLength: nil)
            XCTFail("Expected selectorNotFound")
        } catch let error as AgentBridgeError {
            XCTAssertEqual(error, .selectorNotFound("#does-not-exist"))
        }

        do {
            _ = try await bridge.readPage(mode: .text, selector: "div[[[invalid", maxLength: nil)
            XCTFail("Expected invalidSelector")
        } catch let error as AgentBridgeError {
            XCTAssertEqual(error, .invalidSelector("div[[[invalid"))
        }
    }

    // MARK: - wait_for (immediate selector, delayed mutation, timeout, fixed ms)

    func testWaitForSelectorArrivalTimeoutAndDelay() async throws {
        let html = try loadFixtureHTML("article.html")
        let (webView, bridge, waiter) = makeHostedWebView()
        try await waiter.waitForLoad {
            webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.local/article"))
        }

        // 1. Immediate match
        let immediate = try await bridge.waitFor(selector: "#main-article", milliseconds: 1_000)
        XCTAssertEqual(immediate.mode, .selector)
        XCTAssertTrue(immediate.matched)

        // 2. Delayed DOM insertion via setTimeout
        _ = try await bridge.runJS(
            code: """
            setTimeout(() => {
              const el = document.createElement("div");
              el.id = "async-toast";
              el.textContent = "Saved!";
              document.body.appendChild(el);
            }, 250);
            """,
            environment: .page
        )
        let delayed = try await bridge.waitFor(selector: "#async-toast", milliseconds: 5_000)
        XCTAssertTrue(delayed.matched)
        XCTAssertGreaterThanOrEqual(delayed.elapsedMs, 80)

        // 3. Selector timeout
        let timedOut = try await bridge.waitFor(selector: "#never-inserted", milliseconds: 180)
        XCTAssertEqual(timedOut.mode, .selector)
        XCTAssertFalse(timedOut.matched)

        // 4. Fixed millisecond delay
        let paused = try await bridge.waitFor(selector: nil, milliseconds: 90)
        XCTAssertEqual(paused.mode, .delay)
        XCTAssertTrue(paused.matched)
        XCTAssertGreaterThanOrEqual(paused.elapsedMs, 85)
    }

    // MARK: - Optional Real-Model E2E Run (Gated; claude-haiku-5-5 ONLY)

    #if DEBUG
    func testRealHaikuEndToEndToolLoopOnLocalFixturePage() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["WUKONG_E2E_ANTHROPIC"] == "1",
            "Skipped in unit tests; set WUKONG_E2E_ANTHROPIC=1 via op run for live Haiku E2E verification."
        )
        let apiKey = (env["ANTHROPIC_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(apiKey.isEmpty, "ANTHROPIC_API_KEY must be injected via op run")

        let html = try loadFixtureHTML("article.html")
        let (webView, bridge, waiter) = makeHostedWebView()
        try await waiter.waitForLoad {
            webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.local/article"))
        }

        let aiService = AIService()
        let modelID = "claude-haiku-5-5"
        let session = BrowserAgentSession(
            pageDriver: bridge,
            modelClient: aiService,
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .anthropic, model: modelID),
                    configuration: ProviderConfiguration(
                        model: modelID,
                        baseURL: AIProvider.anthropic.defaultBaseURL,
                        apiKey: apiKey
                    ),
                    maxSteps: 8,
                    truncationLimit: 20_000,
                    customInstructions: "",
                    redactedSecrets: [apiKey]
                )
            }
        )

        await session.sendAndWait(
            "Inspect this page, hide #cookie-banner using inject_css, and confirm the page's h1 text."
        )

        guard case .completed(let steps, _) = session.runState else {
            return XCTFail("Expected live E2E session to complete, got \(session.runState)")
        }
        XCTAssertGreaterThanOrEqual(steps, 2)
        XCTAssertGreaterThan(session.tokenUsage.totalTokens, 0)
        XCTAssertTrue(session.toolCalls.contains { $0.toolName == "inject_css" })
        XCTAssertTrue(
            session.messages.last?.text.localizedCaseInsensitiveContains("Understanding Content Worlds") == true,
            "Expected final answer to report h1 text, got: \(session.messages.last?.text ?? "")"
        )

        // Verify `#cookie-banner` is genuinely hidden in the live WKWebView DOM:
        let displayCheck = try await bridge.runJS(
            code: "return window.getComputedStyle(document.getElementById('cookie-banner')).display;",
            environment: .isolated
        )
        XCTAssertEqual(displayCheck.valueJSON, "\"none\"")

        // Verify the API key never entered the page or any tool output:
        for row in session.toolCalls {
            XCTAssertFalse(row.resultText.contains(apiKey))
            XCTAssertFalse(row.argumentsJSON.contains(apiKey))
        }
    }
    #endif
}
