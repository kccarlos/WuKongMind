import Network
import os
import WebKit
import XCTest
@testable import WukongMind

@MainActor
final class GMRequestTests: XCTestCase {
    private struct StubReply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var delayMs = 0
        var hangs = false
    }

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> StubReply)?
        nonisolated(unsafe) static var seenRequests: [URLRequest] = []
        private static let lock = NSLock()
        private var workTask: Task<Void, Never>?

        static func reset(_ handler: @escaping @Sendable (URLRequest) -> StubReply) {
            lock.withLock { seenRequests = []; self.handler = handler }
        }
        static var seen: [URLRequest] { lock.withLock { seenRequests } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var captured = request
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                stream.close()
                captured.httpBody = data
            }
            Self.lock.withLock { Self.seenRequests.append(captured) }
            guard let stub = Self.handler?(captured), !stub.hangs else { return }
            let url = request.url!
            workTask = Task { [weak self] in
                if stub.delayMs > 0 { try? await Task.sleep(for: .milliseconds(stub.delayMs)) }
                guard let self, !Task.isCancelled else { return }
                let resp = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
                self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: stub.body)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() { workTask?.cancel() }
    }

    private final class NavWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        func wait(_ trigger: () -> Void) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont; trigger()
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
    }

    private struct WebHarness {
        let store: ScriptStore
        let window: UIWindow
        let webView: WKWebView
        let bridge: AgentBridge
        let controller: ScriptWebController
        let waiter: NavWaiter
        let auditLog: AuditLog
    }

    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private var tempDir: URL!
    private var activeHarnesses: [WebHarness] = []

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GMRequestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for h in activeHarnesses {
            h.controller.detach()
            h.webView.stopLoading()
            h.webView.navigationDelegate = nil
            h.webView.configuration.userContentController.removeAllUserScripts()
            h.webView.configuration.userContentController.removeAllScriptMessageHandlers()
            h.webView.removeFromSuperview()
            h.window.isHidden = true
            h.window.rootViewController = nil
            h.window.windowScene = nil
        }
        activeHarnesses.removeAll()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func stubSessionConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }

    private func makeClient(
        cookies: [HTTPCookie] = [],
        page: String? = "https://forum.example.org/t/10",
        confirm: Bool = false,
        limiter: ScriptRequestLimiter = ScriptRequestLimiter()
    ) -> AgentHTTPClient {
        AgentHTTPClient(
            configuration: stubSessionConfig(),
            pacer: ForumRequestPacer(clock: InstantPacingClock()),
            scriptLimiter: limiter,
            environment: AgentNetworkEnvironment(
                cookies: { cookies },
                currentPageURL: { page.flatMap(URL.init(string:)) },
                confirmBeforeWrites: { confirm },
                pacing: { (false, .fast) }
            )
        )
    }

    private func makeWebHarness(cookies: [HTTPCookie] = [], confirm: Bool = false) -> WebHarness {
        let store = ScriptStore(directoryURL: tempDir.appendingPathComponent("Scripts-\(UUID().uuidString)", isDirectory: true))
        let audit = AuditLog(directory: tempDir.appendingPathComponent("Audit-\(UUID().uuidString)", isDirectory: true))
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
        let waiter = NavWaiter()
        webView.navigationDelegate = waiter
        let controller = ScriptWebController(webView: webView, store: store, agentBridge: bridge)
        controller.gmBridge.httpClient = AgentHTTPClient(
            configuration: stubSessionConfig(),
            pacer: ForumRequestPacer(clock: InstantPacingClock()),
            scriptLimiter: ScriptRequestLimiter(),
            environment: AgentNetworkEnvironment(
                cookies: { cookies },
                currentPageURL: { [weak webView] in await webView?.url },
                confirmBeforeWrites: { confirm },
                pacing: { (false, .fast) }
            )
        )
        controller.gmBridge.auditLog = audit
        let h = WebHarness(store: store, window: window, webView: webView, bridge: bridge, controller: controller, waiter: waiter, auditLog: audit)
        activeHarnesses.append(h)
        return h
    }

    private func waitUntil(timeout: TimeInterval = 5, _ check: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for condition")
    }

    private func makeCookie(_ name: String, _ value: String, domain: String, httpOnly: Bool = true) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
        if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: props)!
    }

    func testConnectFencingInitialAndRedirectHopsAndDefaultSelf() async throws {
        StubURLProtocol.reset { req in
            if req.url?.host == "api.allowed.org", req.url?.path == "/leave" {
                return StubReply(status: 302, headers: ["Location": "https://evil.org/steal"])
            }
            if req.url?.host == "api.allowed.org", req.url?.path == "/sub" {
                return StubReply(status: 302, headers: ["Location": "https://cdn.allowed.org/ok"])
            }
            return StubReply(status: 200, body: Data("ok".utf8))
        }
        let client = makeClient(page: "https://sub.forum.example.org/t/1")
        let selfRes = try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "s1", url: URL(string: "https://api.forum.example.org/posts")!, connect: []))
        XCTAssertEqual(selfRes.status, 200)
        await XCTAssertThrowsErrorAsync(try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "s1", url: URL(string: "https://api.allowed.org/ok")!, connect: [])))

        let subHop = try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "s1", url: URL(string: "https://api.allowed.org/sub")!, connect: ["allowed.org"]))
        XCTAssertEqual(subHop.finalURL.absoluteString, "https://cdn.allowed.org/ok")
        await XCTAssertThrowsErrorAsync(try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "s1", url: URL(string: "https://notallowed.org/x")!, connect: ["allowed.org"])))
        await XCTAssertThrowsErrorAsync(try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "s1", url: URL(string: "https://api.allowed.org/leave")!, connect: ["allowed.org"])))
        XCTAssertFalse(StubURLProtocol.seen.contains { $0.url?.host == "evil.org" })
    }

    func testWildcardConnectRefusesLocalhostAndAllPrivateAddressesOnEveryHopUnlessNamed() async throws {
        let forbiddenTargets = [
            "http://localhost:8080/a", "http://api.localhost/a", "http://localhost./a",
            "http://127.0.0.1/a", "http://127.255.255.1/a", "http://0177.0.0.1/a", "http://010.0.0.1/a",
            "http://0.0.0.0/a", "http://10.0.0.1/a", "http://10.255.255.254/a",
            "http://172.16.0.1/a", "http://172.31.255.254/a", "http://192.168.1.1/a",
            "http://169.254.169.254/latest/meta-data", "http://100.64.0.1/a",
            "http://[::1]/a", "http://[0:0:0:0:0:0:0:1]/a", "http://[::]/a",
            "http://[fc00::1]/a", "http://[fd12:3456:789a::1]/a", "http://[fe80::1]/a",
            "http://[::ffff:127.0.0.1]/a", "http://[::ffff:10.0.0.1]/a",
            "http://[::ffff:192.168.0.1]/a", "http://[64:ff9b::127.0.0.1]/a",
        ]
        StubURLProtocol.reset { _ in StubReply(status: 200, body: Data("ok".utf8)) }
        let client = makeClient(page: "https://public.example.com/")
        for (idx, allowed) in ["https://public.example.com/ok", "http://172.15.0.1/ok", "http://172.32.0.1/ok", "http://[2606:4700:4700::1111]/ok", "http://[::ffff:93.184.216.34]/ok"].enumerated() {
            let res = try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "allow-\(idx)", url: URL(string: allowed)!, connect: ["*"]))
            XCTAssertEqual(res.status, 200, "Expected \(allowed) to pass @connect *")
        }
        for (idx, bad) in forbiddenTargets.enumerated() {
            let redirectTarget = bad
            let badURL = try XCTUnwrap(URL(string: bad))
            StubURLProtocol.reset { req in
                req.url?.host == "public.example.com" && req.url?.path == "/bounce"
                    ? StubReply(status: 302, headers: ["Location": redirectTarget])
                    : StubReply(status: 200, body: Data("ok".utf8))
            }
            do {
                _ = try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "hop0-\(idx)", url: badURL, connect: ["*"]))
                XCTFail("Hop 0 should refuse \(bad)")
            } catch let err as ScriptHTTPError {
                XCTAssertEqual(err.kind, .blocked, "Hop 0 should block \(bad)")
            }
            do {
                _ = try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "redir-\(idx)", url: URL(string: "https://public.example.com/bounce")!, connect: ["*"]))
                XCTFail("Redirect hop should refuse \(bad)")
            } catch let err as ScriptHTTPError {
                XCTAssertEqual(err.kind, .blocked, "Redirect hop should block \(bad)")
            }
        }
        let localNamed = try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "s", url: URL(string: "http://localhost:8080/a")!, connect: ["localhost"]))
        XCTAssertEqual(localNamed.status, 200)
        await XCTAssertThrowsErrorAsync(try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "s", url: URL(string: "http://127.0.0.1/a")!, connect: ["localhost"])))
        let v6Named = try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "s", url: URL(string: "http://[0:0:0:0:0:0:0:1]/a")!, connect: ["::1"]))
        XCTAssertEqual(v6Named.status, 200)
    }

    func testSameSiteCookiesCrossSiteDropSetCookieStripAndConfirmBeforeWrites() async throws {
        StubURLProtocol.reset { req in
            req.url?.path == "/cross-hop"
                ? StubReply(status: 302, headers: ["Location": "https://other.org/land"])
                : StubReply(status: 200, headers: ["Set-Cookie": "leak=1", "X-Reply": "yes"], body: Data("done".utf8))
        }
        let cookies = [makeCookie("sid", "secret-1", domain: ".example.org"), makeCookie("other_sid", "secret-2", domain: ".other.org")]
        let client = makeClient(cookies: cookies, page: "https://forum.example.org/t/9")

        let r1 = try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "s", url: URL(string: "https://api.example.org/me")!, connect: ["example.org", "other.org"]))
        XCTAssertEqual(StubURLProtocol.seen.last?.value(forHTTPHeaderField: "Cookie"), "sid=secret-1")
        XCTAssertNil(r1.headers["Set-Cookie"])
        XCTAssertEqual(r1.headers["X-Reply"], "yes")

        _ = try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "s", url: URL(string: "https://api.example.org/me")!, headers: ["Cookie": "forged=1"], anonymous: true, connect: ["example.org"]))
        XCTAssertNil(StubURLProtocol.seen.last?.value(forHTTPHeaderField: "Cookie"))

        _ = try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "s", url: URL(string: "https://other.org/api")!, headers: ["Cookie": "forged=1"], connect: ["other.org"]))
        XCTAssertNil(StubURLProtocol.seen.last?.value(forHTTPHeaderField: "Cookie"))

        StubURLProtocol.reset { req in
            req.url?.path == "/cross-hop" ? StubReply(status: 302, headers: ["Location": "https://other.org/land"]) : StubReply(status: 200)
        }
        _ = try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "s", url: URL(string: "https://forum.example.org/cross-hop")!, connect: ["example.org", "other.org"]))
        XCTAssertEqual(StubURLProtocol.seen.count, 2)
        XCTAssertEqual(StubURLProtocol.seen[0].value(forHTTPHeaderField: "Cookie"), "sid=secret-1")
        XCTAssertNil(StubURLProtocol.seen[1].value(forHTTPHeaderField: "Cookie"))

        let strictClient = makeClient(cookies: cookies, page: "https://forum.example.org/t/9", confirm: true)
        let getOK = try await strictClient.sendScriptRequest(ScriptHTTPRequest(scriptID: "s", url: URL(string: "https://api.example.org/read")!, method: "GET", connect: ["example.org"]))
        XCTAssertEqual(getOK.status, 200)
        let headOK = try await strictClient.sendScriptRequest(ScriptHTTPRequest(scriptID: "s", url: URL(string: "https://api.example.org/read")!, method: "HEAD", connect: ["example.org"]))
        XCTAssertEqual(headOK.status, 200)
        await XCTAssertThrowsErrorAsync(try await strictClient.sendScriptRequest(ScriptHTTPRequest(scriptID: "s", url: URL(string: "https://api.example.org/write")!, method: "POST", body: "x=1", connect: ["example.org"])))
        await XCTAssertThrowsErrorAsync(try await strictClient.sendScriptRequest(ScriptHTTPRequest(scriptID: "s", url: URL(string: "https://other.org/read")!, method: "GET", connect: ["other.org"])))
        await XCTAssertThrowsErrorAsync(try await strictClient.sendScriptRequest(ScriptHTTPRequest(scriptID: "s", url: URL(string: "https://forum.example.org/cross-hop")!, method: "GET", connect: ["example.org", "other.org"])))
    }

    func testPerScriptConcurrencyRateSizeAndTimeoutCaps() async throws {
        StubURLProtocol.reset { req in req.url?.path == "/slow" ? StubReply(body: Data("ok".utf8), delayMs: 250) : StubReply(body: Data("fast".utf8)) }
        let client = makeClient()
        let slowTasks = (0..<4).map { idx in
            Task { try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "busy", url: URL(string: "https://forum.example.org/slow?\(idx)")!, connect: ["self"])) }
        }
        try await Task.sleep(for: .milliseconds(40))
        await XCTAssertThrowsErrorAsync(try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "busy", url: URL(string: "https://forum.example.org/fifth")!, connect: ["self"])))
        let otherRes = try await client.sendScriptRequest(ScriptHTTPRequest(scriptID: "other", url: URL(string: "https://forum.example.org/ok")!, connect: ["self"]))
        XCTAssertEqual(otherRes.status, 200)
        for t in slowTasks { _ = try await t.value }

        final class FakeClock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1_000_000) }
        let clock = FakeClock()
        let rateClient = makeClient(limiter: ScriptRequestLimiter(now: { clock.date }))
        StubURLProtocol.reset { _ in StubReply(status: 200) }
        for i in 0..<60 {
            _ = try await rateClient.sendScriptRequest(ScriptHTTPRequest(scriptID: "burst", url: URL(string: "https://forum.example.org/r?\(i)")!, connect: ["self"]))
        }
        await XCTAssertThrowsErrorAsync(try await rateClient.sendScriptRequest(ScriptHTTPRequest(scriptID: "burst", url: URL(string: "https://forum.example.org/r?60")!, connect: ["self"])))
        clock.date = clock.date.addingTimeInterval(61)
        let afterWindow = try await rateClient.sendScriptRequest(ScriptHTTPRequest(scriptID: "burst", url: URL(string: "https://forum.example.org/r?61")!, connect: ["self"]))
        XCTAssertEqual(afterWindow.status, 200)

        let over5MB = Data(repeating: 0x41, count: AgentHTTPClient.maxScriptBodyBytes + 1024)
        StubURLProtocol.reset { req in
            if req.url?.path == "/huge" { return StubReply(status: 200, body: over5MB) }
            if req.url?.path == "/hang" { return StubReply(hangs: true) }
            return StubReply(status: 200)
        }
        await XCTAssertThrowsErrorAsync(try await rateClient.sendScriptRequest(ScriptHTTPRequest(scriptID: "cap", url: URL(string: "https://forum.example.org/huge")!, connect: ["self"])))
        await XCTAssertThrowsErrorAsync(try await rateClient.sendScriptRequest(ScriptHTTPRequest(scriptID: "cap", url: URL(string: "https://forum.example.org/up")!, method: "POST", body: String(repeating: "x", count: AgentHTTPClient.maxScriptBodyBytes + 1), connect: ["self"])))
        do {
            _ = try await rateClient.sendScriptRequest(ScriptHTTPRequest(scriptID: "cap", url: URL(string: "https://forum.example.org/hang")!, timeout: 0.05, connect: ["self"]))
            XCTFail("Expected timeout")
        } catch let err as ScriptHTTPError {
            XCTAssertEqual(err.kind, .timeout)
        }
    }

    func testWKWebViewGMXmlhttpRequestCallbacksAbortUnsupportedOptionsAndAuditLog() async throws {
        let longQuery = String(repeating: "q", count: 600)
        StubURLProtocol.reset { req in
            switch req.url?.path {
            case "/json": return StubReply(status: 201, headers: ["Content-Type": "application/json", "Set-Cookie": "s=1", "X-Tag": "v1"], body: Data(#"{"items":[1,2]}"#.utf8))
            case "/hang": return StubReply(hangs: true)
            default: return StubReply(status: 200, body: Data("plain".utf8))
            }
        }
        let harness = makeWebHarness(cookies: [makeCookie("auth", "tok", domain: ".example.org")])
        _ = try harness.store.importUserScript(
            """
            // ==UserScript==
            // @name         Request Runner
            // @match        https://forum.example.org/*
            // @grant        GM_xmlhttpRequest
            // @connect      api.example.org
            // ==/UserScript==
            const results = {};
            await new Promise((r) => GM_xmlhttpRequest({
              method: "POST", url: "https://api.example.org/json?\(longQuery)",
              headers: { "X-From": "script" }, data: "hello", responseType: "json",
              onload(res) {
                results.loaded = { status: res.status, statusText: res.statusText, items: res.response.items, headers: res.responseHeaders, readyState: res.readyState };
                r();
              }
            }));
            await new Promise((r) => GM_xmlhttpRequest({ url: "https://unlisted.other.net/secret", onerror(e) { results.blocked = e.error; r(); } }));
            await new Promise((r) => GM_xmlhttpRequest({ url: "https://api.example.org/hang", timeout: 60, ontimeout(e) { results.timedOut = Boolean(e.error); r(); } }));
            await new Promise((r) => {
              const h = GM_xmlhttpRequest({ url: "https://api.example.org/hang", onabort() { results.aborted = true; r(); } });
              setTimeout(() => h.abort(), 15);
            });
            await new Promise((r) => GM_xmlhttpRequest({ url: "https://api.example.org/json", responseType: "blob", onerror(e) { results.unsupportedBlob = e.error; r(); } }));
            try { GM_xmlhttpRequest({ url: "https://api.example.org/json", data: new Uint8Array([1, 2]) }); results.binaryThrew = false; }
            catch (e) { results.binaryThrew = String(e.message || e).includes("binary"); }
            document.documentElement.setAttribute("data-xhr", JSON.stringify(results));
            """,
            preferredID: "req-runner"
        )

        try await harness.waiter.wait { harness.webView.loadHTMLString("<html><body>ok</body></html>", baseURL: URL(string: "https://forum.example.org/t/42")!) }
        try await waitUntil { (try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-xhr')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String) != nil }

        let raw = try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-xhr')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
        let parsed = try JSONSerialization.jsonObject(with: Data((raw ?? "{}").utf8)) as? [String: Any]
        let loaded = parsed?["loaded"] as? [String: Any]
        XCTAssertEqual(loaded?["status"] as? Int, 201)
        XCTAssertEqual(loaded?["statusText"] as? String, "Created")
        XCTAssertEqual(loaded?["items"] as? [Int], [1, 2])
        XCTAssertEqual(loaded?["readyState"] as? Int, 4)
        XCTAssertFalse(((loaded?["headers"] as? String) ?? "").lowercased().contains("set-cookie"))
        XCTAssertTrue(((loaded?["headers"] as? String) ?? "").contains("X-Tag: v1"))
        XCTAssertTrue(((parsed?["blocked"] as? String) ?? "").contains("@connect"))
        XCTAssertEqual(parsed?["timedOut"] as? Bool, true)
        XCTAssertEqual(parsed?["aborted"] as? Bool, true)
        XCTAssertTrue(((parsed?["unsupportedBlob"] as? String) ?? "").contains("blob"))
        XCTAssertEqual(parsed?["binaryThrew"] as? Bool, true)

        try await waitUntil { harness.auditLog.allLines().count >= 4 }
        let lines = harness.auditLog.allLines()
        let first = try XCTUnwrap(lines.first { $0.status == 201 })
        XCTAssertEqual(first.kind, .scriptRequest)
        XCTAssertEqual(first.scriptID, "req-runner")
        XCTAssertEqual(first.scriptName, "Request Runner")
        XCTAssertEqual(first.method, "POST")
        XCTAssertEqual(first.url, "https://api.example.org/json?\(longQuery)")
        XCTAssertEqual(first.pageURL, "https://forum.example.org/t/42")
        XCTAssertTrue(lines.contains { $0.url == "https://unlisted.other.net/secret" && $0.isError == true })
        XCTAssertEqual(harness.auditLog.days().first?.tasks.first?.prompt, "Request Runner")
    }

    func testRefusedRequestsCountAgainstPerScriptLimitAndCapAuditLinesAtSixty() async throws {
        StubURLProtocol.reset { _ in StubReply(status: 200) }
        let harness = makeWebHarness()
        _ = try harness.store.importUserScript(
            """
            // ==UserScript==
            // @name         Refused Flood
            // @match        https://forum.example.org/*
            // @grant        GM_xmlhttpRequest
            // @connect      *
            // ==/UserScript==
            let errors = 0;
            for (let i = 0; i < 200; i++) {
              const target = i % 4 === 0 ? "http://[::1" : "http://10.0.0.1/secret";
              await new Promise((r) => GM_xmlhttpRequest({ url: target, onerror() { errors += 1; r(); } }));
            }
            document.documentElement.setAttribute("data-flood", String(errors));
            """,
            preferredID: "refused-flood"
        )
        _ = try harness.store.importUserScript(
            """
            // ==UserScript==
            // @name         Parallel Flood
            // @match        https://forum.example.org/*
            // @grant        GM_xmlhttpRequest
            // @connect      *
            // ==/UserScript==
            let errors = 0;
            await Promise.all(Array.from({ length: 200 }, () => new Promise((r) => GM_xmlhttpRequest({ url: "http://10.0.0.1/", onerror() { errors += 1; r(); } }))));
            document.documentElement.setAttribute("data-burst", String(errors));
            """,
            preferredID: "parallel-flood"
        )

        try await harness.waiter.wait { harness.webView.loadHTMLString("<html><body>flood</body></html>", baseURL: URL(string: "https://forum.example.org/t/1")!) }
        try await waitUntil(timeout: 10) {
            let a = try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-flood')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
            let b = try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-burst')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
            return a == "200" && b == "200"
        }

        let seqLines = harness.auditLog.allLines().filter { $0.kind == .scriptRequest && $0.scriptID == "refused-flood" }
        let burstLines = harness.auditLog.allLines().filter { $0.kind == .scriptRequest && $0.scriptID == "parallel-flood" }
        XCTAssertEqual(seqLines.count, 60)
        XCTAssertLessThanOrEqual(burstLines.count, 60)
        XCTAssertFalse(seqLines.contains { ($0.resultSummary ?? "").contains("limit reached") })
        XCTAssertFalse(burstLines.contains { ($0.resultSummary ?? "").contains("limit reached") })
    }

    func testMenuCommandsRegisterInvokeUnregisterAndClearOnDisableOrNavigate() async throws {
        let harness = makeWebHarness()
        _ = try harness.store.importUserScript(
            """
            // ==UserScript==
            // @name         Tidy Threads
            // @match        https://forum.example.org/*
            // @grant        GM_registerMenuCommand
            // ==/UserScript==
            let count = 0;
            GM_registerMenuCommand("Tidy Threads settings…", () => { count += 1; document.body.setAttribute("data-cmd-runs", String(count)); });
            const tempId = GM_registerMenuCommand("Temporary action", () => {});
            GM_unregisterMenuCommand(tempId);
            GM_registerMenuCommand("Show folded posts", () => { document.body.setAttribute("data-unfolded", "yes"); return new Promise(() => {}); });
            """,
            preferredID: "tidy-threads"
        )
        _ = try harness.store.create(id: "ungranted-menu", name: "Ungranted Menu", matchRules: ["https://forum.example.org/*"], js: "GM_registerMenuCommand('Nope', () => {});")

        try await harness.waiter.wait { harness.webView.loadHTMLString("<html><body>thread</body></html>", baseURL: URL(string: "https://forum.example.org/t/88")!) }
        try await waitUntil { harness.controller.gmBridge.menuCommands(for: "tidy-threads").count == 2 && harness.store.error(for: "ungranted-menu") != nil }
        XCTAssertEqual(harness.store.error(for: "ungranted-menu")?.message, "`GM_registerMenuCommand` needs `@grant GM_registerMenuCommand`")
        let cmds = harness.controller.gmBridge.menuCommands(for: "tidy-threads")
        XCTAssertEqual(cmds.map(\.title), ["Tidy Threads settings…", "Show folded posts"])
        guard cmds.count == 2 else { return }

        let ranFirst = await harness.controller.gmBridge.invokeMenuCommandAsync(scriptID: "tidy-threads", commandID: cmds[0].id)
        let ranSecond = await harness.controller.gmBridge.invokeMenuCommandAsync(scriptID: "tidy-threads", commandID: cmds[1].id)
        XCTAssertTrue(ranFirst && ranSecond)
        let domState = try await harness.webView.evaluateJavaScript("[document.body.getAttribute('data-cmd-runs'), document.body.getAttribute('data-unfolded')]", in: nil, contentWorld: .page) as? [String]
        XCTAssertEqual(domState, ["1", "yes"])

        _ = try harness.store.setEnabled(id: "tidy-threads", isEnabled: false)
        XCTAssertTrue(harness.controller.gmBridge.menuCommands(for: "tidy-threads").isEmpty)
        try await Task.sleep(for: .milliseconds(40))
        _ = try harness.store.setEnabled(id: "tidy-threads", isEnabled: true, runLiveJS: true)
        try await waitUntil { harness.controller.gmBridge.menuCommands(for: "tidy-threads").count == 2 }
        XCTAssertEqual(harness.controller.gmBridge.menuCommands(for: "tidy-threads").map(\.title), ["Tidy Threads settings…", "Show folded posts"])

        _ = try await harness.webView.evaluateJavaScript("history.pushState({}, '', '/t/89'); true", in: nil, contentWorld: .page)
        try await waitUntil { harness.controller.gmBridge.menuCommands(for: "tidy-threads").count == 2 }
        XCTAssertEqual(harness.controller.gmBridge.menuCommands(for: "tidy-threads").map(\.title), ["Tidy Threads settings…", "Show folded posts"])

        try await harness.waiter.wait { harness.webView.loadHTMLString("<html><body>other</body></html>", baseURL: URL(string: "https://elsewhere.org/")!) }
        XCTAssertTrue(harness.controller.gmBridge.menuCommands(for: "tidy-threads").isEmpty)
    }

    func testGMDotPromiseFormsAndGrantSpellings() async throws {
        StubURLProtocol.reset { req in req.url?.path == "/hang" ? StubReply(hangs: true) : StubReply(status: 200, body: Data(#"{"ok":true}"#.utf8)) }
        let harness = makeWebHarness()
        _ = try harness.store.importUserScript(
            """
            // ==UserScript==
            // @name         GM Dot Suite
            // @version      3.1.0
            // @match        https://forum.example.org/*
            // @grant        GM.getValue
            // @grant        GM.setValue
            // @grant        GM.deleteValue
            // @grant        GM.listValues
            // @grant        GM.xmlHttpRequest
            // @connect      api.example.org
            // ==/UserScript==
            const seeded = await GM.getValue("persisted", "none");
            await GM.setValue("persisted", { v: 7 });
            await GM.setValue("ephemeral", 1);
            await GM.deleteValue("ephemeral");
            const keys = await GM.listValues();
            await GM.addStyle("body { margin-top: 13px !important; }");
            const xhr = await GM.xmlHttpRequest({ url: "https://api.example.org/ok", responseType: "json" });
            let blockedMsg = "";
            try { await GM.xmlHttpRequest({ url: "https://blocked.example.net/no" }); } catch (e) { blockedMsg = e.message; }
            let abortRejected = false;
            const pending = GM.xmlHttpRequest({ url: "https://api.example.org/hang" });
            setTimeout(() => pending.abort(), 15);
            try { await pending; } catch (_) { abortRejected = true; }
            document.documentElement.setAttribute("data-gmdot", JSON.stringify({ seeded, keys, version: GM.info.script.version, ok: xhr.response.ok, blocked: blockedMsg.includes("@connect"), abortRejected }));
            """,
            preferredID: "gm-dot"
        )
        _ = try harness.store.importUserScript(
            """
            // ==UserScript==
            // @name         GM Dot Ungranted
            // @match        https://forum.example.org/*
            // @grant        GM_info
            // ==/UserScript==
            const errs = [];
            try { await GM.getValue("x"); } catch (e) { errs.push(e.message); }
            try { await GM.xmlHttpRequest({ url: "https://forum.example.org/" }); } catch (e) { errs.push(e.message); }
            document.documentElement.setAttribute("data-gmdot-ungranted", JSON.stringify(errs));
            """,
            preferredID: "gm-dot-ungranted"
        )

        try await harness.waiter.wait { harness.webView.loadHTMLString("<html><body>dot</body></html>", baseURL: URL(string: "https://forum.example.org/t/1")!) }
        try await waitUntil {
            let a = try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-gmdot')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
            let b = try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-gmdot-ungranted')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
            return a != nil && b != nil
        }

        let pageGMType = try await harness.webView.evaluateJavaScript("typeof window.GM", in: nil, contentWorld: .page) as? String
        let marginTop = try await harness.webView.evaluateJavaScript("getComputedStyle(document.body).marginTop", in: nil, contentWorld: .page) as? String
        XCTAssertEqual(pageGMType, "undefined")
        XCTAssertEqual(marginTop, "13px")

        let firstRun = try JSONDecoder().decode([String: JSONValue].self, from: Data(((try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-gmdot')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String) ?? "{}").utf8))
        XCTAssertEqual(firstRun["seeded"], .string("none"))
        XCTAssertEqual(firstRun["keys"], .array([.string("persisted")]))
        XCTAssertEqual(firstRun["version"], .string("3.1.0"))
        XCTAssertEqual(firstRun["ok"], .bool(true))
        XCTAssertEqual(firstRun["blocked"], .bool(true))
        XCTAssertEqual(firstRun["abortRejected"], .bool(true))

        let ungrantedErrs = try JSONDecoder().decode([String].self, from: Data(((try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-gmdot-ungranted')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String) ?? "[]").utf8))
        XCTAssertEqual(ungrantedErrs, ["`GM.getValue` needs `@grant GM.getValue`", "`GM.xmlHttpRequest` needs `@grant GM.xmlHttpRequest`"])

        try await harness.waiter.wait { harness.webView.loadHTMLString("<html><body>dot2</body></html>", baseURL: URL(string: "https://forum.example.org/t/2")!) }
        try await waitUntil { (try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-gmdot')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String) != nil }
        let secondRun = try JSONDecoder().decode([String: JSONValue].self, from: Data(((try await harness.webView.evaluateJavaScript("document.documentElement.getAttribute('data-gmdot')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String) ?? "{}").utf8))
        XCTAssertEqual(secondRun["seeded"], .object(["v": .int(7)]))
    }

    // MARK: - 6. AppModel tab wiring (`makeBrowserTab`)

    func testAppModelWiresScriptRequestsMenuCommandsAndAuditLog() async throws {
        let server = try LoopbackMiniServer { path in
            if path == "/api/ping" {
                return (200, "application/json", Data(#"{"pong":true}"#.utf8))
            }
            return (200, "text/html; charset=utf-8", Data("<html><body><div id='out'>idle</div></body></html>".utf8))
        }
        let baseURL = try await server.start()
        defer { server.stop() }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("wukong-gm-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let stateURL = tempRoot.appendingPathComponent("state/state.json", isDirectory: false)
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let forumConfig = URLSessionConfiguration.ephemeral
        let forumSession = URLSession(configuration: forumConfig)
        let browser = ForumBrowserModel(
            contentRules: ContentRuleLibrary(store: nil, directory: nil),
            websiteDataStore: .nonPersistent()
        )
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: frame)
        window.frame = frame
        let host = UIViewController()
        host.view.frame = frame
        browser.webView.frame = frame
        host.view.addSubview(browser.webView)
        window.rootViewController = host
        window.makeKeyAndVisible()

        let app = AppModel(
            store: PersistentStore(fileURL: stateURL, keys: InMemoryProviderKeyStore()),
            forumService: ForumService(session: forumSession, pacer: ForumRequestPacer(clock: InstantPacingClock())),
            browser: browser,
            cloudSync: CloudSyncController(transport: nil, files: nil, defaults: nil, schedulesAutomatically: false),
            podcastDirectory: tempRoot.appendingPathComponent("Podcasts", isDirectory: true),
            workspaceDirectory: tempRoot.appendingPathComponent("Workspace", isDirectory: true),
            spotlightIndex: FakeSpotlightIndex(),
            topicActivityDonor: FakeTopicActivityDonor()
        )
        app.usesDirectForumRequests = true
        app.browser.ignoresNavigationFailures = true
        defer {
            forumSession.invalidateAndCancel()
            app.browser.stopLoading()
            app.podcast.cancelReadAloud()
            app.scriptWebController.detach()
            browser.webView.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
        }

        XCTAssertTrue(app.scriptWebController.gmBridge.httpClient === app.agentHTTPClient)
        XCTAssertTrue(app.scriptWebController.gmBridge.auditLog === app.auditLog)

        let script = try app.scriptStore.importUserScript(
            """
            // ==UserScript==
            // @name         App Wired Script
            // @match        http://127.0.0.1/*
            // @grant        GM.xmlHttpRequest
            // @grant        GM_registerMenuCommand
            // @connect      127.0.0.1
            // ==/UserScript==
            GM_registerMenuCommand("Ping thread", () => {
              document.getElementById("out").textContent = "menu-ran";
            });
            const res = await GM.xmlHttpRequest({ url: "\(baseURL.absoluteString)/api/ping", responseType: "json" });
            document.documentElement.setAttribute("data-pong", String(res.response.pong));
            """,
            preferredID: "app-wired"
        )

        let threadURL = baseURL.appendingPathComponent("t/10")
        app.browser.load(threadURL)
        await app.browser.waitUntilSettled(timeout: .seconds(20))
        try await waitUntil {
            let pong = try await app.browser.webView.evaluateJavaScript("document.documentElement.getAttribute('data-pong')", in: nil, contentWorld: AgentBridge.isolatedWorld) as? String
            return pong == "true" && app.scriptWebController.gmBridge.menuCommands(for: script.id).count == 1
        }

        let cmd = try XCTUnwrap(app.scriptWebController.gmBridge.menuCommands(for: script.id).first)
        XCTAssertEqual(cmd.title, "Ping thread")
        let ran = await app.scriptWebController.gmBridge.invokeMenuCommandAsync(scriptID: script.id, commandID: cmd.id)
        XCTAssertTrue(ran)
        let outText = try await app.browser.webView.evaluateJavaScript("document.getElementById('out').textContent", in: nil, contentWorld: .page) as? String
        XCTAssertEqual(outText, "menu-ran")

        try await waitUntil { app.auditLog.days().flatMap(\.tasks).contains { $0.id.hasSuffix(":\(script.id)") } }
        let auditTask = try XCTUnwrap(app.auditLog.days().flatMap(\.tasks).first { $0.id.hasSuffix(":\(script.id)") })
        XCTAssertEqual(auditTask.prompt, "App Wired Script")
        XCTAssertEqual(auditTask.steps.first?.status, 200)
        XCTAssertEqual(auditTask.steps.first?.url, "\(baseURL.absoluteString)/api/ping")
    }
}

private final class LoopbackMiniServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "wukong.gm.loopback")
    private let handler: @Sendable (String) -> (Int, String, Data)

    init(handler: @escaping @Sendable (String) -> (Int, String, Data)) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params)
    }

    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.newConnectionHandler = { [handler, queue] conn in
                conn.start(queue: queue)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                    let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let rawTarget = req.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let path = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
                    let (status, mime, body) = handler(path)
                    var resp = Data("HTTP/1.1 \(status) OK\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                    resp.append(body)
                    conn.send(content: resp, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if let p = listener?.port?.rawValue, p > 0, resumed.withLock({ let ok = !$0; $0 = true; return ok }) {
                        cont.resume(returning: p)
                    }
                case .failed(let err):
                    if resumed.withLock({ let ok = !$0; $0 = true; return ok }) { cont.resume(throwing: err) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() { listener.cancel() }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message.isEmpty ? "Expected expression to throw an error" : message, file: file, line: line)
    } catch {}
}
