import XCTest
@testable import WukongMind

/// `http_request`, `cookies_get`, `wukong.fetch` and confirmations (design-m3.md, task 5).
/// A `URLProtocol` stub stands in for the network and a fake clock for pacing time.
@MainActor
final class AgentNetworkToolsTests: XCTestCase {
    // MARK: Stub

    private struct Stubbed {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var hangs = false
    }

    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Stubbed)?
        nonisolated(unsafe) static var requests: [URLRequest] = []
        private static let lock = NSLock()

        static func reset(_ handler: @escaping @Sendable (URLRequest) -> Stubbed) {
            lock.withLock { requests = []; self.handler = handler }
        }
        static var seen: [URLRequest] { lock.withLock { requests } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var captured = request
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                stream.close()
                captured.httpBody = data
            }
            Self.lock.withLock { Self.requests.append(captured) }
            guard let stub = Self.handler?(captured), !stub.hangs else { return }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return config
    }

    private func cookie(_ name: String, _ value: String, domain: String, httpOnly: Bool = false, secure: Bool = false) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: "/"
        ]
        if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if secure { props[.secure] = "TRUE" }
        return HTTPCookie(properties: props)!
    }

    private func makeClient(
        cookies: [HTTPCookie] = [],
        page: String? = nil,
        confirm: Bool = false,
        pacing: Bool = true,
        forumHosts: Set<String> = [],
        clock: ForumPacingClock = InstantPacingClock(),
        fetched: FetchLog = FetchLog()
    ) -> AgentHTTPClient {
        AgentHTTPClient(
            configuration: configuration(),
            pacer: ForumRequestPacer(clock: clock),
            environment: AgentNetworkEnvironment(
                cookies: { cookies },
                currentPageURL: { page.flatMap(URL.init(string:)) },
                confirmBeforeWrites: { confirm },
                pacing: { (pacing, .gentle) },
                isForumHost: { forumHosts.contains($0.host ?? "") },
                onFetch: { url, _ in fetched.add(url) }
            )
        )
    }

    private final class FetchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        func add(_ url: String) { lock.withLock { urls.append(url) } }
        var all: [String] { lock.withLock { urls } }
    }

    private struct NoPageDriver: AgentPageDriving {
        func currentPageMetadata() async -> AgentPageMetadata { .empty }
        func readPage(mode: PageReadMode, selector: String?, maxLength: Int?) async throws -> String { "" }
        func runJS(code: String, environment: AgentExecutionEnvironment, timeout: TimeInterval) async throws -> JSExecutionResult {
            JSExecutionResult(valueJSON: nil, consoleOutput: [], error: nil)
        }
        func injectCSS(css: String, id: String?) async throws -> CSSInjectionResult {
            CSSInjectionResult(sheetID: id ?? "s", appliedRootCount: 1)
        }
        func waitFor(selector: String?, milliseconds: Int?) async throws -> WaitForResult {
            WaitForResult(mode: .delay, matched: true, elapsedMs: 0, selector: nil)
        }
    }

    private func makeRegistry(
        client: AgentHTTPClient,
        gate: AgentConfirmationGate,
        workspace: AgentWorkspace? = nil
    ) -> ToolRegistry {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("NetTools-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        return ToolRegistry.m3(context: AgentToolContext(
            bridge: NoPageDriver(),
            workspace: workspace,
            scriptStore: ScriptStore(directoryURL: sandbox.appendingPathComponent("Scripts", isDirectory: true)),
            network: client,
            confirmations: gate
        ))
    }

    /// Runs `body` while answering the first confirmation with `allow`; returns the question asked (nil if none).
    private func dispatch(
        _ registry: ToolRegistry, gate: AgentConfirmationGate, tool: String, args: String, answer allow: Bool = true
    ) async throws -> (result: ToolDispatchResult, asked: AgentConfirmation?) {
        let baseline = StubProtocol.seen.count
        let task = Task { try await registry.dispatch(toolName: tool, rawArgumentsJSON: args) }
        var asked: AgentConfirmation?
        for _ in 0..<200 {
            if let first = gate.pending.first {
                asked = first
                gate.resolve(first.id, allow: allow)
                break
            }
            try await Task.sleep(for: .milliseconds(10))
            if StubProtocol.seen.count > baseline { break }
        }
        return (try await task.value, asked)
    }

    private func json(_ text: String) throws -> [String: Any] {
        let start = try XCTUnwrap(text.firstIndex(of: "{"))
        let data = Data(text[start...].utf8)
        var depth = 0
        var end = text.endIndex
        for index in text[start...].indices {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" { depth -= 1; if depth == 0 { end = text.index(after: index); break } }
        }
        _ = data
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text[start..<end].utf8)) as? [String: Any])
    }

    // MARK: Site rule

    func testSiteRule() {
        XCTAssertEqual(AgentSite.registrableDomain(of: "a.example.org"), "example.org")
        XCTAssertTrue(AgentSite.sameSite(URL(string: "https://a.example.org/x"), URL(string: "https://b.example.org/")))
        XCTAssertEqual(AgentSite.registrableDomain(of: "www.example.co.uk"), "example.co.uk")
        XCTAssertFalse(AgentSite.sameSite(URL(string: "https://example.co.uk/"), URL(string: "https://other.co.uk/")))
        XCTAssertFalse(AgentSite.sameSite(URL(string: "https://example.org/"), nil))
    }

    // MARK: http_request basics

    func testMethodHeadersBodyAndSetCookieDropped() async throws {
        StubProtocol.reset { _ in
            Stubbed(status: 201, headers: ["Content-Type": "application/json", "Set-Cookie": "a=b", "X-Test": "1"], body: Data("{\"ok\":true}".utf8))
        }
        let client = makeClient()
        var request = AgentHTTPRequest(url: URL(string: "https://api.example.org/v1/items")!)
        request.method = "POST"
        request.headers = ["X-Custom": "yes", "Content-Type": "text/plain"]
        request.body = "hello"
        let response = try await client.send(request)
        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(response.text, "{\"ok\":true}")
        XCTAssertNil(response.headers.keys.first { $0.lowercased() == "set-cookie" })
        XCTAssertEqual(response.headers["X-Test"], "1")
        let sent = try XCTUnwrap(StubProtocol.seen.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Custom"), "yes")
        XCTAssertEqual(sent.httpBody.flatMap { String(data: $0, encoding: .utf8) }, "hello")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Cookie"))
    }

    func testRedirectsAreFollowedAndCapped() async throws {
        StubProtocol.reset { request in
            let n = Int(request.url!.lastPathComponent) ?? 0
            if n < 3 { return Stubbed(status: 302, headers: ["Location": "/\(n + 1)"]) }
            return Stubbed(body: Data("done".utf8))
        }
        let client = makeClient()
        let response = try await client.send(AgentHTTPRequest(url: URL(string: "https://example.org/0")!))
        XCTAssertEqual(response.text, "done")
        XCTAssertEqual(response.finalURL.path, "/3")

        StubProtocol.reset { _ in Stubbed(status: 302, headers: ["Location": "/again"]) }
        do {
            _ = try await client.send(AgentHTTPRequest(url: URL(string: "https://example.org/0")!))
            XCTFail("expected too many redirects")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Too many redirects"))
        }
        XCTAssertEqual(StubProtocol.seen.count, 11)
    }

    func testBodyStopsAtTwentyMegabytesAndBinaryIsDescribed() async throws {
        StubProtocol.reset { _ in Stubbed(body: Data(repeating: 0x61, count: 21 * 1024 * 1024)) }
        let client = makeClient()
        let big = try await client.send(AgentHTTPRequest(url: URL(string: "https://example.org/big")!))
        XCTAssertTrue(big.truncated)
        XCTAssertEqual(big.data.count, AgentHTTPClient.maxBodyBytes)

        StubProtocol.reset { _ in Stubbed(headers: ["Content-Type": "image/png"], body: Data([0x89, 0x50, 0x00, 0xFF])) }
        let gate = AgentConfirmationGate()
        let registry = makeRegistry(client: client, gate: gate)
        let (result, _) = try await dispatch(registry, gate: gate, tool: "http_request", args: #"{"url":"https://example.org/i.png"}"#)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("binary, 4 bytes, image/png"))
    }

    func testTimeoutReturnsAnError() async throws {
        StubProtocol.reset { _ in Stubbed(hangs: true) }
        let client = makeClient()
        var request = AgentHTTPRequest(url: URL(string: "https://example.org/slow")!)
        request.timeout = 1
        do {
            _ = try await client.send(request)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
    }

    func testSaveToWritesTheBodyToTheWorkspace() async throws {
        StubProtocol.reset { _ in Stubbed(body: Data(String(repeating: "x", count: 3_000).utf8)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NetWS-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = AgentWorkspace(root: root)
        let gate = AgentConfirmationGate()
        let registry = makeRegistry(client: makeClient(), gate: gate, workspace: workspace)
        let (result, _) = try await dispatch(
            registry, gate: gate, tool: "http_request", args: #"{"url":"https://example.org/a","save_to":"pages/a.txt"}"#
        )
        XCTAssertEqual(result.savedPath, "pages/a.txt")
        XCTAssertFalse(result.output.contains(String(repeating: "x", count: 1_000)))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("pages/a.txt"), encoding: .utf8).count, 3_000)
    }

    // MARK: Cookies

    func testSendCookiesUsesTheTargetSiteNotTheCurrentPageHttpOnlyIncluded() async throws {
        StubProtocol.reset { _ in Stubbed(headers: ["Set-Cookie": "new=1"]) }
        let cookies = [
            cookie("sid", "target-secret", domain: ".other-site.net", httpOnly: true),
            cookie("page", "page-secret", domain: "example.org")
        ]
        let client = makeClient(cookies: cookies, page: "https://example.org/")
        var request = AgentHTTPRequest(url: URL(string: "https://www.other-site.net/api")!)
        request.sendCookies = true
        let response = try await client.send(request)
        let sent = try XCTUnwrap(StubProtocol.seen.first?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(sent, "sid=target-secret")
        XCTAssertNil(response.headers.keys.first { $0.lowercased() == "set-cookie" })
    }

    func testRedirectOffTheSiteDropsTheCookieHeader() async throws {
        StubProtocol.reset { request in
            if request.url?.host == "example.org" {
                return Stubbed(status: 302, headers: ["Location": "https://elsewhere.net/landing"])
            }
            return Stubbed(body: Data("ok".utf8))
        }
        let client = makeClient(cookies: [cookie("sid", "v", domain: "example.org")])
        var request = AgentHTTPRequest(url: URL(string: "https://example.org/go")!)
        request.sendCookies = true
        _ = try await client.send(request)
        XCTAssertEqual(StubProtocol.seen.count, 2)
        XCTAssertEqual(StubProtocol.seen[0].value(forHTTPHeaderField: "Cookie"), "sid=v")
        XCTAssertNil(StubProtocol.seen[1].value(forHTTPHeaderField: "Cookie"))
    }

    func testCookiesGetMatchesParentDomainsAndAlwaysAsks() async throws {
        StubProtocol.reset { _ in Stubbed() }
        let cookies = [
            cookie("a", "1", domain: ".example.org"),
            cookie("b", "2", domain: "forum.example.org", httpOnly: true),
            cookie("c", "3", domain: "other.org")
        ]
        let client = makeClient(cookies: cookies, confirm: false)
        let gate = AgentConfirmationGate()
        let registry = makeRegistry(client: client, gate: gate)
        let (result, asked) = try await dispatch(registry, gate: gate, tool: "cookies_get", args: #"{"domain":"forum.example.org"}"#)
        XCTAssertEqual(asked?.question, "Read 2 cookies for forum.example.org?")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("\"name\":\"a\""))
        XCTAssertTrue(result.output.contains("\"name\":\"b\""))
        XCTAssertTrue(result.output.contains("\"http_only\":true"))
        XCTAssertFalse(result.output.contains("\"name\":\"c\""))

        let (declined, _) = try await dispatch(registry, gate: gate, tool: "cookies_get", args: #"{"domain":"example.org"}"#, answer: false)
        XCTAssertTrue(declined.isError)
        XCTAssertTrue(declined.output.contains("The user declined this action."))
    }

    // MARK: Confirmations

    func testConfirmationMatrixWithTheSwitchOff() async throws {
        StubProtocol.reset { _ in Stubbed(body: Data("ok".utf8)) }
        let client = makeClient(cookies: [cookie("sid", "v", domain: "other-site.net")], page: "https://example.org/", confirm: false)
        let gate = AgentConfirmationGate()
        let registry = makeRegistry(client: client, gate: gate)

        // Other requests run without asking.
        let (plain, plainAsk) = try await dispatch(registry, gate: gate, tool: "http_request", args: #"{"url":"https://other-site.net/x"}"#)
        XCTAssertNil(plainAsk)
        XCTAssertFalse(plain.isError)

        // Cross-site send_cookies asks, in the owner's words.
        let (_, crossAsk) = try await dispatch(
            registry, gate: gate, tool: "http_request", args: #"{"url":"https://other-site.net/x","send_cookies":true}"#
        )
        XCTAssertEqual(crossAsk?.question, "Send a request to other-site.net using your login there?")
        XCTAssertEqual(crossAsk?.detail, "https://other-site.net/x")

        // A Cookie header the model writes itself counts as send_cookies.
        let (_, headerAsk) = try await dispatch(
            registry, gate: gate, tool: "http_request",
            args: #"{"url":"https://other-site.net/x","headers":{"cookie":"a=b"}}"#
        )
        XCTAssertNotNil(headerAsk)

        // The current page's own site does not ask.
        let (_, sameAsk) = try await dispatch(
            registry, gate: gate, tool: "http_request", args: #"{"url":"https://api.example.org/x","send_cookies":true}"#
        )
        XCTAssertNil(sameAsk)

        // Don't allow returns the declined error and sends nothing.
        StubProtocol.reset { _ in Stubbed() }
        let (declined, _) = try await dispatch(
            registry, gate: gate, tool: "http_request",
            args: #"{"url":"https://other-site.net/x","send_cookies":true}"#, answer: false
        )
        XCTAssertTrue(declined.isError)
        XCTAssertTrue(declined.output.contains("The user declined this action."))
        XCTAssertTrue(StubProtocol.seen.isEmpty)
    }

    func testConfirmationWithTheSwitchOnAsksForEveryRequest() async throws {
        StubProtocol.reset { _ in Stubbed(body: Data("ok".utf8)) }
        let client = makeClient(page: "https://example.org/", confirm: true)
        let gate = AgentConfirmationGate()
        let registry = makeRegistry(client: client, gate: gate)
        let (_, asked) = try await dispatch(
            registry, gate: gate, tool: "http_request",
            args: #"{"url":"https://api.example.org/v1/items?x=1","method":"POST"}"#
        )
        XCTAssertEqual(asked?.question, "Send a POST request to api.example.org/v1/items?")
        XCTAssertEqual(asked?.detail, "https://api.example.org/v1/items?x=1")
    }

    func testStopCancelsTheCard() async throws {
        let gate = AgentConfirmationGate()
        let task = Task { try await gate.ask(tool: "cookies_get", question: "Read?") }
        while gate.pending.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(gate.pending.isEmpty)
    }

    // MARK: wukong.fetch

    func testScriptFetchWaitsForThePaceOnForumHostsAndSkipsItWhenOff() async throws {
        StubProtocol.reset { _ in Stubbed(body: Data("page".utf8)) }
        let clock = FakePacingClock()
        let paced = makeClient(page: "https://forum.example.org/t/1", forumHosts: ["forum.example.org"], clock: clock)
        _ = try await paced.scriptFetch("https://forum.example.org/t/1?page=1")
        _ = try await paced.scriptFetch("https://forum.example.org/t/1?page=2")
        XCTAssertEqual(clock.sleeps, [1])

        let freeClock = FakePacingClock()
        let unpaced = makeClient(page: "https://forum.example.org/t/1", pacing: false, forumHosts: ["forum.example.org"], clock: freeClock)
        _ = try await unpaced.scriptFetch("https://forum.example.org/t/1?page=1")
        _ = try await unpaced.scriptFetch("https://forum.example.org/t/1?page=2")
        XCTAssertTrue(freeClock.sleeps.isEmpty)
    }

    func testScriptFetchSendsCookiesOnlyOnTheCurrentSite() async throws {
        StubProtocol.reset { _ in Stubbed(body: Data("ok".utf8)) }
        let fetched = FetchLog()
        let cookies = [cookie("sid", "mine", domain: "example.org"), cookie("sid", "theirs", domain: "other-site.net")]
        let client = makeClient(cookies: cookies, page: "https://example.org/t", fetched: fetched)
        _ = try await client.scriptFetch("https://forum.example.org/t/1")
        _ = try await client.scriptFetch("https://other-site.net/t/1")
        XCTAssertEqual(StubProtocol.seen[0].value(forHTTPHeaderField: "Cookie"), "sid=mine")
        XCTAssertNil(StubProtocol.seen[1].value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(fetched.all.count, 2)
    }

    func testScriptFetchWithConfirmOnRunsSameSiteAndRefusesAnotherSite() async throws {
        StubProtocol.reset { _ in Stubbed(body: Data("ok".utf8)) }
        let client = makeClient(page: "https://example.org/t", confirm: true)
        let text = try await client.scriptFetch("https://forum.example.org/t/1")
        XCTAssertEqual(text, "ok")
        do {
            _ = try await client.scriptFetch("https://other-site.net/")
            XCTFail("expected an error pointing to http_request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("http_request"))
        }
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }
}
