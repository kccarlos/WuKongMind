import Foundation
import Network
import os
import UIKit
import WebKit
import XCTest
@testable import WukongMind

@MainActor
final class GMBridgeTests: XCTestCase {
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var timeoutTask: Task<Void, Never>?
        private var activeNavigation: WKNavigation?
        private var waitingForStart = false

        func cancelPending() { finish(with: CancellationError()) }

        func waitForLoad(timeoutSeconds: Double = 30, _ start: () -> Void) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                self.activeNavigation = nil
                self.waitingForStart = true
                self.timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    if !Task.isCancelled {
                        self?.finish(with: NSError(domain: "GMBridgeTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Navigation timed out"]))
                    }
                }
                start()
            }
        }

        private func finish(with error: Error? = nil) {
            timeoutTask?.cancel(); timeoutTask = nil; activeNavigation = nil; waitingForStart = false
            guard let cont = continuation else { return }
            continuation = nil
            if let error { cont.resume(throwing: error) } else { cont.resume() }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            if continuation != nil, waitingForStart { activeNavigation = navigation; waitingForStart = false }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !waitingForStart, continuation != nil, activeNavigation == nil || activeNavigation == navigation { finish() }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if !(waitingForStart && (error as NSError).code == NSURLErrorCancelled) { finish(with: error) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if !(waitingForStart && (error as NSError).code == NSURLErrorCancelled) { finish(with: error) }
        }
    }

    private final class LoopbackServer: @unchecked Sendable {
        struct Route {
            var contentType = "text/html; charset=utf-8"
            var headers: [String: String] = [:]
            var body: Data
        }
        private let listener: NWListener
        private let queue = DispatchQueue(label: "wukong.gmbridge.fixture")
        private let resolver: @Sendable (String) -> Route?
        private let connections = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: NWConnection]())
        private(set) var port: UInt16 = 0

        init(resolver: @escaping @Sendable (String) -> Route?) throws {
            self.resolver = resolver
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            self.listener = try NWListener(using: params)
        }

        func start() async throws {
            let resolver = self.resolver, conns = self.connections
            listener.newConnectionHandler = { conn in
                let key = ObjectIdentifier(conn)
                conns.withLock { $0[key] = conn }
                conn.stateUpdateHandler = { st in
                    if case .cancelled = st { _ = conns.withLock { $0.removeValue(forKey: key) } }
                    if case .failed = st { _ = conns.withLock { $0.removeValue(forKey: key) } }
                }
                conn.start(queue: self.queue)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                    let firstLine = (String(data: data ?? Data(), encoding: .utf8) ?? "").components(separatedBy: "\r\n").first ?? ""
                    let parts = firstLine.split(separator: " ")
                    let raw = parts.count >= 2 ? String(parts[1]) : "/"
                    let path = String(raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "/")
                    let route = resolver(path)
                    let body = route?.body ?? Data("Not Found".utf8)
                    var head = "HTTP/1.1 \(route == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(route?.contentType ?? "text/plain")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                    for (k, v) in route?.headers ?? [:] { head += "\(k): \(v)\r\n" }
                    conn.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let done = OSAllocatedUnfairLock(initialState: false)
                listener.stateUpdateHandler = { [weak self] st in
                    if case .ready = st, done.withLock({ v in defer { v = true }; return !v }) {
                        self?.port = self?.listener.port?.rawValue ?? 0; cont.resume()
                    } else if case .failed(let err) = st, done.withLock({ v in defer { v = true }; return !v }) {
                        cont.resume(throwing: err)
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
            for c in connections.withLock({ d -> [NWConnection] in defer { d.removeAll() }; return Array(d.values) }) { c.cancel() }
        }
    }

    private struct CSPVariant {
        let slug: String
        let policy: String?
        let viaMeta: Bool
        static let m0Matrix: [CSPVariant] = [
            .init(slug: "none", policy: nil, viaMeta: false),
            .init(slug: "self-header", policy: "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'", viaMeta: false),
            .init(slug: "self-meta", policy: "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'", viaMeta: true),
            .init(slug: "nonce-header", policy: "default-src 'self'; script-src 'nonce-wukong1'; style-src 'self'; connect-src 'self'", viaMeta: false),
            .init(slug: "nonce-meta", policy: "default-src 'self'; script-src 'nonce-wukong1'; style-src 'self'; connect-src 'self'", viaMeta: true),
            .init(slug: "strict-dynamic-header", policy: "default-src 'self'; script-src 'nonce-wukong1' 'strict-dynamic'; style-src 'self'; connect-src 'self'", viaMeta: false),
            .init(slug: "strict-dynamic-meta", policy: "default-src 'self'; script-src 'nonce-wukong1' 'strict-dynamic'; style-src 'self'; connect-src 'self'", viaMeta: true),
        ]
    }

    private struct Harness {
        let window: UIWindow
        let webView: WKWebView
        let bridge: AgentBridge
        let controller: ScriptWebController
        let waiter: NavigationWaiter
    }

    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private static var sharedServer: LoopbackServer?
    private var tempDir: URL!
    private var harnesses: [Harness] = []

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GMBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for h in harnesses {
            h.controller.detach()
            h.waiter.cancelPending()
            h.webView.stopLoading()
            h.webView.navigationDelegate = nil
            h.webView.configuration.userContentController.removeAllUserScripts()
            h.webView.configuration.userContentController.removeAllScriptMessageHandlers()
            h.webView.removeFromSuperview()
            h.window.isHidden = true
            h.window.rootViewController = nil
            h.window.windowScene = nil
        }
        harnesses.removeAll()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    nonisolated override class func tearDown() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { sharedServer?.stop(); sharedServer = nil }
        }
        super.tearDown()
    }

    private func fixtureServer() async throws -> LoopbackServer {
        if let existing = Self.sharedServer { return existing }
        let server = try LoopbackServer { path in
            if path == "/head-probe.js" {
                let js = "window.__headProbeDocStartAttr = document.documentElement.getAttribute('data-gm-sync'); window.__headProbeReadyState = document.readyState;"
                return .init(contentType: "application/javascript; charset=utf-8", body: Data(js.utf8))
            }
            if path.hasPrefix("/csp/") {
                let slug = String(path.dropFirst("/csp/".count))
                guard let v = CSPVariant.m0Matrix.first(where: { $0.slug == slug }) else { return nil }
                let meta = (v.viaMeta && v.policy != nil) ? "<meta http-equiv=\"Content-Security-Policy\" content=\"\(v.policy!)\">" : ""
                let headers = (!v.viaMeta && v.policy != nil) ? ["Content-Security-Policy": v.policy!] : [:]
                let html = "<!doctype html><html><head>\(meta)<script src=\"/head-probe.js\" nonce=\"wukong1\"></script><script>window.__inlineUnnoncedRan = true;</script></head><body><main>CSP \(slug)</main></body></html>"
                return .init(headers: headers, body: Data(html.utf8))
            }
            return .init(body: Data("<!doctype html><html><body><article class='post'>Hello \(path)</article></body></html>".utf8))
        }
        try await server.start()
        Self.sharedServer = server
        return server
    }

    private func makeHarness(store: ScriptStore) -> Harness {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.sharedDataStore
        ForumBrowserModel.disableWebKitScreenTimeForTesting(in: config)
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: frame)
        window.frame = frame
        let vc = UIViewController()
        vc.view.frame = window.bounds
        let webView = WKWebView(frame: vc.view.bounds, configuration: config)
        vc.view.addSubview(webView)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let bridge = AgentBridge(webView: webView)
        let controller = ScriptWebController(webView: webView, store: store, agentBridge: bridge)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        let h = Harness(window: window, webView: webView, bridge: bridge, controller: controller, waiter: waiter)
        harnesses.append(h)
        return h
    }

    private func waitUntil(
        timeoutSeconds: Double = 5.0,
        _ message: String = "Timed out waiting for condition",
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let finalMet = try await condition()
        XCTAssertTrue(finalMet, message, file: file, line: line)
    }

    func testCrossWorldIsolationPreventsHandlerValueAndErrorSpoofing() async throws {
        let server = try await fixtureServer()
        let store = ScriptStore(directoryURL: tempDir.appendingPathComponent("Scripts", isDirectory: true))
        _ = try store.create(
            id: "script-a", name: "Script A", matchRules: ["*://127.0.0.1/*"],
            js: """
            GM_setValue("secretToken", "alpha-only-secret");
            window.__scriptAInternal = "private-to-a";
            document.documentElement.setAttribute("data-a-agent", typeof (window.webkit?.messageHandlers?.wukongAgent));
            """,
            grants: ["GM_getValue", "GM_setValue", "GM_listValues"]
        )
        _ = try store.create(
            id: "script-b", name: "Script B", matchRules: ["*://127.0.0.1/*"],
            js: """
            document.documentElement.setAttribute("data-b-probe", JSON.stringify({
              leakedValue: GM_getValue("secretToken", "not-found"),
              ownKeys: GM_listValues(),
              sawAGlobal: typeof window.__scriptAInternal,
              sawAgentHandler: typeof (window.webkit?.messageHandlers?.wukongAgent)
            }));
            await window.webkit.messageHandlers.gm.postMessage({ action: "scriptError", scriptId: "script-a", message: "forged-via-b-handler" });
            const tpl = document.createElement("template");
            tpl.setAttribute("data-wukong-script-error", JSON.stringify({ token: "forged", scriptId: "script-a", message: "forged-dom" }));
            document.documentElement.appendChild(tpl);
            document.dispatchEvent(new Event("__wukong_script_error"));
            """,
            injectionTime: .documentEnd,
            grants: ["GM_getValue", "GM_setValue", "GM_listValues"]
        )
        _ = try store.create(
            id: "page-clean", name: "Page Clean", matchRules: ["*://127.0.0.1/*"],
            js: "document.documentElement.setAttribute('data-page-clean', '1');", environment: .page
        )

        let harness = makeHarness(store: store)
        try await harness.waiter.waitForLoad {
            harness.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/thread/1")!))
        }
        try await waitUntil { store.error(for: "script-b") != nil }

        XCTAssertNil(store.error(for: "script-a"))
        XCTAssertNil(store.error(for: "page-clean"))
        XCTAssertEqual(store.error(for: "script-b")?.message, "forged-via-b-handler")

        let probeRaw = try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-b-probe')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
        let probe = try JSONDecoder().decode([String: JSONValue].self, from: Data((probeRaw ?? "{}").utf8))
        XCTAssertEqual(probe["leakedValue"], .string("not-found"))
        XCTAssertEqual(probe["ownKeys"], .array([]))
        XCTAssertEqual(probe["sawAGlobal"], .string("undefined"))
        XCTAssertEqual(probe["sawAgentHandler"], .string("undefined"))
        let aAgent = try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-a-agent')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
        XCTAssertEqual(aAgent, "undefined")

        let pageCheck = try await harness.webView.evaluateJavaScript(
            """
            (() => {
              const tpl = document.createElement("template");
              tpl.setAttribute("data-wukong-script-error", JSON.stringify({ token: "guessed", scriptId: "script-a", message: "forged-page" }));
              document.documentElement.appendChild(tpl);
              document.dispatchEvent(new Event("__wukong_script_error"));
              return { gm: typeof (window.webkit?.messageHandlers?.gm), agent: typeof (window.webkit?.messageHandlers?.wukongAgent) };
            })()
            """,
            in: nil, contentWorld: .page
        ) as? [String: String]
        XCTAssertEqual(pageCheck?["gm"], "undefined")
        XCTAssertEqual(pageCheck?["agent"], "undefined")
        let agentGM = try await harness.webView.evaluateJavaScript("typeof (window.webkit?.messageHandlers?.gm)", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
        XCTAssertEqual(agentGM, "undefined")
        XCTAssertNil(store.error(for: "script-a"))
        XCTAssertEqual(store.valuesDirectoryURL.lastPathComponent, "ScriptValues")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.valuesStore.fileURL(for: "script-a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.valuesStore.fileURL(for: "script-b").path))
    }

    func testDocumentStartSyncReadAcrossAllSevenM0CSPVariantsAnd256KBCeiling() async throws {
        let server = try await fixtureServer()
        let store = ScriptStore(directoryURL: tempDir.appendingPathComponent("Scripts", isDirectory: true))
        _ = try store.create(
            id: "csp-sync-store", name: "CSP Sync Store", matchRules: ["*://127.0.0.1/*"],
            js: """
            if (window.location.pathname === "/seed") {
              const block = "z".repeat(82 * 1024);
              GM_setValue("chunk1", block); GM_setValue("chunk2", block); GM_setValue("chunk3", block);
              GM_setValue("prefs", { theme: "obsidian", count: 42 });
            } else {
              const p = GM_getValue("prefs", null);
              const len = GM_getValue("chunk1", "").length + GM_getValue("chunk2", "").length + GM_getValue("chunk3", "").length;
              document.documentElement.setAttribute("data-gm-sync", p ? (p.theme + ":" + p.count + ":" + len) : "missing");
              GM_addStyle("body { background-color: rgb(12, 34, 56) !important; }");
            }
            """,
            injectionTime: .documentStart,
            grants: ["GM_getValue", "GM_setValue", "GM_listValues"]
        )

        let harness = makeHarness(store: store)
        try await harness.waiter.waitForLoad {
            harness.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/seed")!))
        }
        XCTAssertTrue(harness.controller.isUserScriptListStale)
        XCTAssertEqual(harness.controller.userScriptRebuildCount, 1)

        let expected = "obsidian:42:\(3 * 82 * 1024)"
        for variant in CSPVariant.m0Matrix {
            try await harness.waiter.waitForLoad {
                harness.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/csp/\(variant.slug)")!))
            }
            let check = try await harness.webView.evaluateJavaScript(
                "({ saw: window.__headProbeDocStartAttr || null, state: window.__headProbeReadyState || null, inlineRan: Boolean(window.__inlineUnnoncedRan), bg: getComputedStyle(document.body).backgroundColor })",
                in: nil, contentWorld: .page
            ) as? [String: Any]
            XCTAssertEqual(check?["saw"] as? String, expected, "Failed sync read under \(variant.slug)")
            XCTAssertEqual(check?["state"] as? String, "loading")
            XCTAssertEqual(check?["inlineRan"] as? Bool, variant.policy == nil)
            XCTAssertEqual(check?["bg"] as? String, "rgb(12, 34, 56)")
        }
        XCTAssertEqual(harness.controller.userScriptRebuildCount, 2)
        XCTAssertNil(store.error(for: "csp-sync-store"))
    }

    func testValueLifecyclePromiseFormsSizeLimitsAndDeleteUndoRestore() async throws {
        let server = try await fixtureServer()
        let pageURL = URL(string: "http://127.0.0.1:\(server.port)/values")!
        let store = ScriptStore(directoryURL: tempDir.appendingPathComponent("Scripts", isDirectory: true))
        _ = try store.create(
            id: "gm-dot-values", name: "GM Dot Values", matchRules: ["*://127.0.0.1/*"],
            js: """
            const prior = await GM.getValue("persisted", null);
            if (!prior) {
              await GM.setValue("persisted", { ok: true, items: [1, "two", null] });
              await GM.setValue("ephemeral", "temp");
              await GM.deleteValue("ephemeral");
              let overSingle = false, overTotal = false;
              try { await GM.setValue("big", "x".repeat(100 * 1024 + 16)); } catch (e) { overSingle = String(e).includes("100 KB"); }
              await GM.setValue("fill1", "a".repeat(95 * 1024));
              await GM.setValue("fill2", "b".repeat(95 * 1024));
              try { await GM.setValue("fill3", "c".repeat(80 * 1024)); } catch (e) { overTotal = String(e).includes("256 KB"); }
              await GM.addStyle("body { color: rgb(9, 8, 7) !important; }");
              document.documentElement.setAttribute("data-dot-p1", JSON.stringify({
                overSingle, overTotal, keys: (await GM.listValues()).sort(), handler: GM.info.scriptHandler
              }));
            } else {
              document.documentElement.setAttribute("data-dot-p2", JSON.stringify({ prior, keys: (await GM.listValues()).sort() }));
            }
            """,
            grants: ["GM.getValue", "GM.setValue", "GM.deleteValue", "GM.listValues"]
        )

        let harness = makeHarness(store: store)
        try await harness.waiter.waitForLoad { harness.webView.load(URLRequest(url: pageURL)) }
        try await waitUntil {
            (try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-dot-p1')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String) != nil
        }
        let p1Raw = try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-dot-p1')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
        let p1 = try JSONDecoder().decode([String: JSONValue].self, from: Data((p1Raw ?? "{}").utf8))
        XCTAssertEqual(p1["overSingle"], .bool(true))
        XCTAssertEqual(p1["overTotal"], .bool(true))
        XCTAssertEqual(p1["keys"], .array([.string("fill1"), .string("fill2"), .string("persisted")]))
        XCTAssertEqual(p1["handler"], .string("WukongMind"))

        let valuesFile = store.valuesStore.fileURL(for: "gm-dot-values")
        XCTAssertTrue(FileManager.default.fileExists(atPath: valuesFile.path))
        XCTAssertFalse(try XCTUnwrap(store.script(id: "gm-dot-values")).toUserScriptFileContent().contains(String(repeating: "a", count: 1024)))

        let deleted = try store.delete(id: "gm-dot-values")
        XCTAssertFalse(FileManager.default.fileExists(atPath: valuesFile.path))
        try store.restore(deleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: valuesFile.path))

        try await harness.waiter.waitForLoad { harness.webView.reload() }
        try await waitUntil {
            (try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-dot-p2')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String) != nil
        }
        let p2Raw = try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-dot-p2')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
        let p2 = try JSONDecoder().decode([String: JSONValue].self, from: Data((p2Raw ?? "{}").utf8))
        XCTAssertEqual(p2["keys"], .array([.string("fill1"), .string("fill2"), .string("persisted")]))
        XCTAssertEqual(p2["prior"], .object(["ok": .bool(true), "items": .array([.int(1), .string("two"), .null])]))
    }

    func testUngrantedAndUnsupportedCallsThrowExactMessagesAndStylesCleanUp() async throws {
        let server = try await fixtureServer()
        let store = ScriptStore(directoryURL: tempDir.appendingPathComponent("Scripts", isDirectory: true))
        _ = try store.create(id: "ungranted-caller", name: "Ungranted", matchRules: ["*://127.0.0.1/*"], js: "GM_getValue('secret');")
        _ = try store.create(id: "unsupported-caller", name: "Unsupported", matchRules: ["*://127.0.0.1/*"], js: "GM_notification('hi');")
        _ = try store.create(
            id: "raw-bridge-bypass", name: "Bypass", matchRules: ["*://127.0.0.1/*"],
            js: "window.webkit.messageHandlers.gm.postMessage({ action: 'setValue', key: 'x', rawJSON: '\"v\"' }).catch(() => {});"
        )
        _ = try store.importUserScript(
            """
            // ==UserScript==
            // @name         Page World Stylist
            // @namespace    https://wukong.test
            // @version      2.4.1
            // @match        *://127.0.0.1/*
            // @inject-into  page
            // ==/UserScript==
            GM_log("hello from page");
            GM_addStyle("article.post { color: rgb(200, 10, 20) !important; }");
            document.documentElement.setAttribute("data-page-gminfo", JSON.stringify({
              name: GM_info.script.name, version: GM_info.script.version,
              namespace: GM_info.script.namespace, handler: GM_info.scriptHandler, leaked: typeof window.GM_info
            }));
            """,
            preferredID: "page-stylist"
        )
        _ = try store.create(
            id: "isolated-stylist", name: "Isolated Stylist", matchRules: ["*://127.0.0.1/*"],
            js: "GM_log('iso'); GM_addStyle('body { border-top: 7px solid rgb(1, 2, 3) !important; }');"
        )

        let harness = makeHarness(store: store)
        try await harness.waiter.waitForLoad {
            harness.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/grants")!))
        }
        try await waitUntil {
            store.error(for: "ungranted-caller") != nil && store.error(for: "unsupported-caller") != nil && store.error(for: "raw-bridge-bypass") != nil
        }
        XCTAssertEqual(store.error(for: "ungranted-caller")?.message, "`GM_getValue` needs `@grant GM_getValue`")
        XCTAssertEqual(store.error(for: "unsupported-caller")?.message, "`GM_notification` is not supported in WukongMind")
        XCTAssertEqual(store.error(for: "raw-bridge-bypass")?.message, "`GM_setValue` needs `@grant GM_setValue`")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.valuesStore.fileURL(for: "raw-bridge-bypass").path))

        let check = try await harness.webView.evaluateJavaScript(
            "({ info: JSON.parse(document.documentElement.getAttribute('data-page-gminfo') || '{}'), color: getComputedStyle(document.querySelector('article.post')).color, border: getComputedStyle(document.body).borderTopWidth })",
            in: nil, contentWorld: .page
        ) as? [String: Any]
        let info = check?["info"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "Page World Stylist")
        XCTAssertEqual(info?["version"] as? String, "2.4.1")
        XCTAssertEqual(info?["namespace"] as? String, "https://wukong.test")
        XCTAssertEqual(info?["handler"] as? String, "WukongMind")
        XCTAssertEqual(info?["leaked"] as? String, "undefined")
        XCTAssertEqual(check?["color"] as? String, "rgb(200, 10, 20)")
        XCTAssertEqual(check?["border"] as? String, "7px")

        _ = try store.setEnabled(id: "isolated-stylist", isEnabled: false)
        try await waitUntil("isolated-stylist GM_addStyle cleanup") {
            (try await harness.webView.evaluateJavaScript("getComputedStyle(document.body).borderTopWidth", in: nil, contentWorld: .page) as? String) == "0px"
        }
        _ = try store.setEnabled(id: "page-stylist", isEnabled: false)
        try await waitUntil("page-stylist GM_addStyle cleanup") {
            (try await harness.webView.evaluateJavaScript("getComputedStyle(document.querySelector('article.post')).color", in: nil, contentWorld: .page) as? String) != "rgb(200, 10, 20)"
        }
    }

    func testAgentScriptRunsInDedicatedWorldAndPerHostInjectionWithSPARoutes() async throws {
        let server = try await fixtureServer()
        let store = ScriptStore(directoryURL: tempDir.appendingPathComponent("Scripts", isDirectory: true))
        for idx in 0..<30 {
            _ = try store.create(id: "other-\(idx)", name: "Other \(idx)", matchRules: ["*://site-\(idx).example/*"], js: "document.body.dataset.leaked = '\(idx)';")
        }
        _ = try store.create(
            id: "agent-thread-enhancer", name: "Agent Thread Enhancer", matchRules: ["*://127.0.0.1/t/*"],
            js: """
            window.__enhancerWorldMarker = "in-own-world";
            window.__enhancerRuns = (window.__enhancerRuns || 0) + 1;
            document.documentElement.setAttribute("data-thread-path", window.location.pathname + "#" + window.__enhancerRuns);
            """,
            css: "article.post { font-weight: 700 !important; }",
            source: .agent(userPrompt: "Highlight threads")
        )
        _ = try store.create(
            id: "localhost-only", name: "Localhost Only", matchRules: ["*://localhost/*"],
            js: "document.documentElement.setAttribute('data-localhost-ran', 'yes');"
        )

        let harness = makeHarness(store: store)
        try await harness.waiter.waitForLoad {
            harness.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/categories")!))
        }
        XCTAssertEqual(harness.controller.managedUserScriptCount, 4)
        XCTAssertEqual(harness.webView.configuration.userContentController.userScripts.count, 6)
        let before = try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-thread-path')", in: nil, contentWorld: AgentBridge.isolatedWorld)
        XCTAssertTrue(before == nil || before is NSNull)

        _ = try await harness.webView.evaluateJavaScript("history.pushState({}, '', '/t/42'); true;", in: nil, contentWorld: .page)
        try await waitUntil {
            (try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-thread-path')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String) == "/t/42#1"
        }
        let ownMarker = try await harness.webView.evaluateJavaScript("window.__enhancerWorldMarker", in: nil, contentWorld: GMBridge.world(for: "agent-thread-enhancer")) as? String
        let agentMarker = try await harness.webView.evaluateJavaScript("typeof window.__enhancerWorldMarker", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
        let pageMarker = try await harness.webView.evaluateJavaScript("typeof window.__enhancerWorldMarker", in: nil, contentWorld: .page) as? String
        XCTAssertEqual(ownMarker, "in-own-world")
        XCTAssertEqual(agentMarker, "undefined")
        XCTAssertEqual(pageMarker, "undefined")

        try await harness.waiter.waitForLoad {
            harness.webView.load(URLRequest(url: URL(string: "http://localhost:\(server.port)/welcome")!))
        }
        let locRan = try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-localhost-ran')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
        XCTAssertEqual(locRan, "yes")
        XCTAssertEqual(harness.controller.managedUserScriptCount, 3)
        XCTAssertEqual(harness.webView.configuration.userContentController.userScripts.count, 5)
    }
}
