import Foundation
import Network
import UIKit
import WebKit
import XCTest
@testable import WukongMind

@MainActor
final class SiteToolVerifierTests: XCTestCase {
    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private var windows: [UIWindow] = [], listeners: [NWListener] = [], tempDirs: [URL] = []

    private final class NavigationWaiter: NSObject, WKNavigationDelegate, AgentPageNavigating {
        weak var webView: WKWebView?
        private var continuation: CheckedContinuation<Void, Error>?

        // Returns on didFinish, so a long limit costs nothing when WebKit is fast; the cold
        // WebContent launch on a CI runner has taken longer than 20 s (-1001 on main).
        func load(_ wv: WKWebView, url: URL, timeout: Double = 90) async throws {
            try await navigate(wv, timeout: timeout) { wv.load(URLRequest(url: url)) }
        }
        func agentLoad(_ url: URL, wait: Bool, timeout: TimeInterval) async throws -> AgentNavigationOutcome {
            guard let wv = webView else { throw AgentBridgeError.webViewUnavailable }
            if wait { try await load(wv, url: url, timeout: timeout) } else { wv.load(URLRequest(url: url)) }
            return AgentNavigationOutcome(url: wv.url?.absoluteString ?? url.absoluteString, title: wv.title ?? "", status: 200, loadMs: 5)
        }
        func agentReload(timeout: TimeInterval) async throws -> AgentNavigationOutcome {
            guard let wv = webView else { throw AgentBridgeError.webViewUnavailable }
            try await navigate(wv, timeout: timeout) { wv.reload() }
            return AgentNavigationOutcome(url: wv.url?.absoluteString ?? "", title: wv.title ?? "", status: 200, loadMs: 5)
        }
        private func navigate(_ wv: WKWebView, timeout: Double, trigger: () -> Void) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont; trigger()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if let pending = self?.continuation { self?.continuation = nil; pending.resume(throwing: URLError(.timedOut)) }
                }
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if let c = continuation { continuation = nil; c.resume() } }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if let c = continuation { continuation = nil; c.resume(throwing: error) } }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if let c = continuation { continuation = nil; c.resume(throwing: error) } }
    }

    override func tearDown() {
        listeners.forEach { $0.cancel() }; listeners.removeAll()
        windows.forEach { $0.isHidden = true; $0.rootViewController = nil }; windows.removeAll()
        tempDirs.forEach { try? FileManager.default.removeItem(at: $0) }; tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir); return dir
    }

    private static let t101Posts: [(Int, String, String)] = [
        (1, "alice", "Thermal paste replacement dropped idle CPU temperatures by twelve degrees on the fan curve."),
        (2, "", "Deleted member confirmed the same idle fan drop after cleaning dust from the heatsink fins."),
        (3, "bob", "Check BIOS 3.05 fan hysteresis settings so the blower stays silent below fifty degrees."),
        (4, "cara", "Measured acoustic noise at twenty decibels once hysteresis changed from two to five seconds."),
        (5, "dan", "Note that stock pads on the VRM rail also benefit from one millimeter replacement pads."),
        (6, "erin", "Running stress-ng for ten minutes peaked at seventy eight degrees with zero thermal throttling."),
        (7, "frank", "Undervolting offset of minus thirty millivolts shaved another four watts under compile load."),
        (8, "grace", "Make sure ec-probe polling is disabled during sleep or s2idle residency drops noticeably."),
        (9, "hank", "Updated firmware package landed in testing repository yesterday with quieter fan table."),
        (10, "ivy", "Confirmed BIOS 3.06 plus fresh paste resolves both the fan ramp spike and dock heat.")
    ]
    private static let t102Posts: [(Int, String, String)] = [
        (1, "dana", "Does btrfs scrub IO priority class three prevent NVMe latency spikes during Rust builds?"),
        (2, "mark", "Yes, pass -c 3 to btrfs scrub start so background checksum verification yields to writes."),
        (3, "nina", "On kernel 6.14 mq-deadline honors idle ioprio hints on NVMe namespaces out of the box."),
        (4, "dana", "Build times stayed within two percent of baseline while scrubbing two terabytes, solved.")
    ]

    private func startFixtureServer() async throws -> URL {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any); params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params), queue = DispatchQueue(label: "dev.wukongmind.sitetoolverifier")
        listeners.append(listener)
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            listener.newConnectionHandler = { conn in
                conn.start(queue: queue)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? "GET / HTTP/1.1"
                    let rawTarget = req.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let comps = URLComponents(string: "http://127.0.0.1" + rawTarget)
                    let q = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                    let (ctype, body) = Self.serveFixture(path: comps?.path ?? "/", query: q)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: \(ctype)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
            listener.stateUpdateHandler = { [weak listener] st in
                guard !once.done else { return }
                if case .ready = st, let p = listener?.port?.rawValue, p > 0 { once.done = true; cont.resume(returning: p) }
                else if case .failed(let e) = st { once.done = true; cont.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    nonisolated private static func serveFixture(path: String, query: [String: String]) -> (String, Data) {
        switch path {
        case "/", "/forum":
            let rows = [(101, "Cooling Fan Hysteresis and Paste"), (102, "Btrfs Scrub Priority on NVMe"), (103, "Wayland Fractional Scaling Notes"), (104, "Zram Swap Compression Benchmarks"), (105, "Systemd Boot Time Analysis"), (106, "PipeWire Low Latency Buffer Guide")]
                .map { #"<li><a href="/thread-\#($0.0)">\#($0.1)</a></li>"# }.joined()
            return ("text/html; charset=utf-8", Data("<!doctype html><html><head><title>Hardware Forum</title></head><body><h1>Cooling Forum</h1><ul>\(rows)</ul></body></html>".utf8))
        case "/thread-101", "/thread-102":
            let is101 = path == "/thread-101", title = is101 ? "Cooling Fan Hysteresis and Paste" : "Btrfs Scrub Priority on NVMe"
            let articles = (is101 ? t101Posts : t102Posts).map { #"<article><b>\#($0.1.isEmpty ? "[deleted]" : $0.1)</b> <span>#\#($0.0)</span><p>\#($0.2)</p></article>"# }.joined()
            return ("text/html; charset=utf-8", Data("<!doctype html><html><head><title>\(title)</title></head><body><h1>\(title)</h1>\(articles)</body></html>".utf8))
        case "/api/thread-101", "/api/thread-102":
            let is101 = path.hasSuffix("101"), title = is101 ? "Cooling Fan Hysteresis and Paste" : "Btrfs Scrub Priority on NVMe"
            let posts = (is101 ? t101Posts : t102Posts).map { ["number": $0.0, "author": $0.1, "body": $0.2, "date": "2026-11-15T10:00:00Z"] as [String: Any] }
            return ("application/json", (try? JSONSerialization.data(withJSONObject: ["title": title, "posts": posts])) ?? Data("{}".utf8))
        case "/api/latest":
            let items = (101...106).map { ["id": "\($0)", "title": $0 == 101 ? "Cooling Fan Hysteresis and Paste" : "Thread \($0) Notes", "path": "/thread-\($0)"] }
            return ("application/json", (try? JSONSerialization.data(withJSONObject: ["items": items])) ?? Data("{}".utf8))
        case "/api/search":
            let term = (query["q"] ?? "").lowercased()
            let hits: [[String: Any]] = (term.contains("cooling") || term.contains("fan") || term.contains("hysteresis"))
                ? [["title": "Cooling Fan Hysteresis and Paste", "path": "/thread-101"], ["title": "Quiet Fan Curve Tips", "path": "/thread-107"]] : []
            return ("application/json", (try? JSONSerialization.data(withJSONObject: ["items": hits])) ?? Data("{}".utf8))
        default:
            return ("text/html; charset=utf-8", Data("<!doctype html><html><body>Other</body></html>".utf8))
        }
    }

    @MainActor
    private struct Harness {
        let dir: URL, webView: WKWebView, waiter: NavigationWaiter, bridge: AgentBridge
        let scriptStore: ScriptStore, pageToolBridge: PageToolBridge, controller: ScriptWebController, stateStore: SiteToolStateStore

        func makeRegistry(timeout: TimeInterval = PageToolBridge.defaultTimeout, surface: ToolSurface = .text) -> ToolRegistry {
            let host = "127.0.0.1", state = stateStore.state(forHost: host) ?? SiteToolState(host: host)
            let learned = LearnedSiteContext(host: host, state: state, pageToolBridge: pageToolBridge, scriptStore: scriptStore, stateStore: stateStore)
            let limits = SiteToolVerifier.Limits(callTimeout: timeout, maxResponseBytes: PageToolBridge.defaultMaxResponseBytes)
            let ptCtx = pageToolBridge.isEnabled ? PageToolContext(bridge: pageToolBridge, scriptStore: scriptStore) : nil
            var reg = ToolRegistry.m3(context: AgentToolContext(
                bridge: bridge, workspace: nil, scriptStore: scriptStore, liveApplier: controller,
                learnedSite: pageToolBridge.isEnabled ? learned : nil, pageTools: ptCtx,
                siteToolStateStore: stateStore, learningRunState: SiteLearningRunState(verifierLimits: limits)
            ), surface: surface)
            reg.taskID = "task-verify"; return reg
        }
    }

    private func makeHarness() throws -> Harness {
        let dir = try makeTempDir(), cfg = WKWebViewConfiguration(), frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        cfg.websiteDataStore = Self.sharedDataStore; cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        ForumBrowserModel.disableWebKitScreenTimeForTesting(in: cfg)
        let webView = WKWebView(frame: frame, configuration: cfg), waiter = NavigationWaiter()
        waiter.webView = webView; webView.navigationDelegate = waiter
        let win = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: frame)
        win.frame = frame; let vc = UIViewController(); vc.view.frame = frame; vc.view.addSubview(webView)
        win.rootViewController = vc; win.makeKeyAndVisible(); win.layoutIfNeeded(); windows.append(win)
        let scriptStore = ScriptStore(directoryURL: dir.appendingPathComponent("Scripts", isDirectory: true))
        let stateStore = SiteToolStateStore(directoryURL: dir.appendingPathComponent("SiteTools", isDirectory: true))
        let bridge = AgentBridge(webView: webView); bridge.navigator = waiter
        let pageToolBridge = PageToolBridge(webView: webView, isEnabled: true)
        let controller = ScriptWebController(webView: webView, store: scriptStore, agentBridge: bridge, pageToolBridge: pageToolBridge)
        return Harness(dir: dir, webView: webView, waiter: waiter, bridge: bridge, scriptStore: scriptStore, pageToolBridge: pageToolBridge, controller: controller, stateStore: stateStore)
    }

    private static let passingReadTopicJS = """
    await modelContext.registerTool({ name: "read_topic", annotations: { readOnlyHint: true }, async execute({ url, page = 1 }) {
      const d = await (await fetch("/api" + new URL(url).pathname)).json();
      return { shape: { title: d.title, url, total_posts: d.posts.length, posts: d.posts }, page, total_pages: 1 };
    }});
    """

    private static let passingListAndSearchJS = """
    await modelContext.registerTool({ name: "list_latest", annotations: { readOnlyHint: true }, async execute() {
      const d = await (await fetch("/api/latest")).json();
      return { shape: { items: d.items.map(x => ({ id: x.id, title: x.title, url: location.origin + x.path })) } };
    }});
    await modelContext.registerTool({ name: "search_forum", annotations: { readOnlyHint: true }, async execute({ query, page = 1 }) {
      const d = await (await fetch("/api/search?q=" + encodeURIComponent(query))).json();
      return { shape: { items: d.items.map(x => ({ title: x.title, url: location.origin + x.path })) }, page, total_pages: 1 };
    }});
    """

    func testHeaderKeysRoundTripAndLegacy13ScriptDecodesUnchanged() throws {
        XCTAssertEqual(SiteToolVerifier.Limits.default.callTimeout, 20)
        XCTAssertEqual(SiteToolVerifier.Limits.default.maxResponseBytes, 2 * 1_024 * 1_024)
        let store = ScriptStore(directoryURL: try makeTempDir())
        let created = try store.create(
            id: "reader-example", name: "Read example.org", matchRules: ["*://example.org/*"],
            js: "modelContext.registerTool({ name: 'read_topic', execute: () => ({}) });",
            source: .agent(userPrompt: "Summarize"), provides: ["read_topic", "list_latest"],
            threadMatches: ["*://example.org/thread-*"], listMatches: ["*://example.org/forum*"],
            testURLs: ["https://example.org/thread-101", "https://example.org/thread-102"]
        )
        let serialized = created.toUserScriptFileContent()
        XCTAssertTrue(serialized.contains("// @wukong-provides read_topic\n// @wukong-provides list_latest"))
        XCTAssertTrue(serialized.contains("// @wukong-thread-match *://example.org/thread-*"))
        XCTAssertTrue(serialized.contains("// @wukong-list-match *://example.org/forum*"))
        XCTAssertTrue(serialized.contains("// @wukong-test-url https://example.org/thread-101\n// @wukong-test-url https://example.org/thread-102"))
        let reparsed = try UserScript.parseUserScriptFile(serialized)
        store.reloadFromDisk()
        XCTAssertEqual(reparsed, store.script(id: "reader-example"))
        XCTAssertEqual(reparsed.metadata.provides, ["read_topic", "list_latest"])
        XCTAssertEqual(reparsed.metadata.threadMatches, ["*://example.org/thread-*"])
        XCTAssertEqual(reparsed.metadata.listMatches, ["*://example.org/forum*"])
        XCTAssertEqual(reparsed.metadata.testURLs, ["https://example.org/thread-101", "https://example.org/thread-102"])

        let legacy13 = """
        // ==UserScript==
        // @name Dark Forum
        // @match *://*.example.org/*
        // @run-at document-end
        // @version 3
        // @wukong-id dark-forum
        // @wukong-environment isolated
        // @wukong-enabled true
        // @wukong-source agent
        // @wukong-created-at 2026-10-01T10:00:00.000Z
        // @wukong-updated-at 2026-10-01T10:00:00.000Z
        // ==/UserScript==
        document.body.dataset.dark = '1';
        """
        let decoded13 = try UserScript.parseUserScriptFile(legacy13)
        XCTAssertEqual(decoded13.version, 3)
        XCTAssertEqual(decoded13.metadata, ScriptMetadata())
        XCTAssertTrue(decoded13.metadata.provides.isEmpty && decoded13.metadata.testURLs.isEmpty)
    }

    func testAllNineStepsRefuseFailingFixturesAndPassingReadersSaveStateAndHeaders() async throws {
        let base = try await startFixtureServer(), h = try makeHarness()
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        let u1 = base.appendingPathComponent("thread-101").absoluteString
        let u2 = base.appendingPathComponent("thread-102").absoluteString
        let forumURL = base.appendingPathComponent("forum").absoluteString
        try await h.waiter.load(h.webView, url: URL(string: u1)!)

        func saveReadTopic(_ js: String, testURLs: [String] = [u1, u2], timeout: TimeInterval = 20) async throws -> ToolDispatchResult {
            try await h.makeRegistry(timeout: timeout).dispatch(toolName: "script_save", arguments: [
                "name": .string("Reader"), "match_rules": .array([.string("*://127.0.0.1/*")]), "js": .string(js),
                "provides": .array([.string("read_topic")]), "thread_match": .string("*://127.0.0.1/thread-*"),
                "test_urls": .array(testURLs.map(JSONValue.string))
            ])
        }

        let s1 = try await saveReadTopic("window.__noop = 1;")
        XCTAssertTrue(s1.isError && s1.output.contains("no tool named read_topic was registered"), s1.output)

        let s2 = try await saveReadTopic("""
        await modelContext.registerTool({ name: "read_topic", async execute({ url }) {
          if (url.includes("thread-102")) throw new Error("upstream broken");
          const d = await (await fetch("/api/thread-101")).json();
          return { shape: { title: d.title, url, posts: d.posts } };
        }});
        """)
        XCTAssertTrue(s2.isError && s2.output.contains(u2), s2.output)

        let s3MissingAuthor = try await saveReadTopic("""
        await modelContext.registerTool({ name: "read_topic", execute: ({ url }) => ({ shape: { title: "T", url, posts: [{ number: 1, body: "Missing author key" }] } })});
        """)
        XCTAssertTrue(s3MissingAuthor.isError && s3MissingAuthor.output.contains("shape.posts[0].author"), s3MissingAuthor.output)

        let s3Mistyped = try await saveReadTopic("""
        await modelContext.registerTool({ name: "read_topic", execute: ({ url }) => ({ shape: { title: "T", url, posts: [{ number: "one", author: "a", body: "Bad" }] } })});
        """)
        XCTAssertTrue(s3Mistyped.isError && s3Mistyped.output.contains("shape.posts[0].number"), s3Mistyped.output)

        let s4Markup = try await saveReadTopic("""
        await modelContext.registerTool({ name: "read_topic", execute: ({ url }) => ({
          shape: { title: url, url, posts: [{ number: 1, author: "a", body: "Plain" }, { number: 2, author: "b", body: "<div class='p'><p>Markup</p></div>" }] }
        })});
        """)
        XCTAssertTrue(s4Markup.isError && s4Markup.output.contains("post #2") && s4Markup.output.contains("markup"), s4Markup.output)

        let s4TooManyEmptyAuthors = try await saveReadTopic("""
        await modelContext.registerTool({ name: "read_topic", async execute({ url }) {
          const d = await (await fetch("/api" + new URL(url).pathname)).json();
          return { shape: { title: d.title, url, posts: d.posts.map((p, i) => ({ ...p, author: (i === 1 || i === 4) ? "" : p.author })) } };
        }});
        """)
        XCTAssertTrue(s4TooManyEmptyAuthors.isError && s4TooManyEmptyAuthors.output.contains("post #5") && s4TooManyEmptyAuthors.output.contains("empty author"), s4TooManyEmptyAuthors.output)

        let s6 = try await saveReadTopic("""
        await modelContext.registerTool({ name: "read_topic", async execute({ url }) {
          const d = await (await fetch("/api/thread-101")).json();
          return { shape: { title: d.title, url, posts: d.posts } };
        }});
        """)
        XCTAssertTrue(s6.isError && s6.output.contains("both URLs returned the same thread"), s6.output)

        let s7 = try await saveReadTopic("""
        await modelContext.registerTool({ name: "read_topic", async execute({ url }) {
          if (url.includes("thread-102")) { const d2 = await (await fetch("/api/thread-102")).json(); return { shape: { title: d2.title, url, posts: d2.posts } }; }
          const d1 = await (await fetch("/api/thread-101")).json();
          return { shape: { title: d1.title, url, posts: [d1.posts[0], { number: 3, author: "ghost", body: "Invented reply text that never appeared anywhere on the open page document." }]}};
        }});
        """)
        XCTAssertTrue(s7.isError && s7.output.contains("post #3 is not on the page"), s7.output)

        let s8Timeout = try await saveReadTopic("await modelContext.registerTool({ name: 'read_topic', execute: () => new Promise(() => {}) });", timeout: 0.25)
        XCTAssertTrue(s8Timeout.isError && s8Timeout.output.contains("timed out after 0.25s"), s8Timeout.output)

        let s8Oversize = try await saveReadTopic("""
        await modelContext.registerTool({ name: "read_topic", execute: ({ url }) => ({ shape: { title: "Big", url, posts: [{ number: 1, author: "a", body: "x".repeat(2200000) }] } })});
        """)
        XCTAssertTrue(s8Oversize.isError && s8Oversize.output.contains("2 MB"), s8Oversize.output)

        let s9 = try await saveReadTopic(Self.passingReadTopicJS + "\nconst PING = 'https://telemetry.evil.example/collect';")
        XCTAssertTrue(s9.isError && s9.output.contains("telemetry.evil.example"), s9.output)

        XCTAssertTrue(h.scriptStore.scripts.isEmpty)
        XCTAssertNil(h.stateStore.state(forHost: "127.0.0.1"))

        let reg = h.makeRegistry()
        let passRead = try await reg.dispatch(toolName: "script_save", arguments: [
            "name": .string("Hardware Reader"), "match_rules": .array([.string("*://127.0.0.1/*")]),
            "js": .string(Self.passingReadTopicJS), "provides": .array([.string("read_topic")]),
            "thread_match": .string("*://127.0.0.1/thread-*"), "test_urls": .array([.string(u1), .string(u2)])
        ])
        XCTAssertTrue(!passRead.isError && passRead.output.contains("verified on 2 threads: 10 and 4 posts"), passRead.output)
        let readerID = try XCTUnwrap((try JSONValue.parseObjectJSON(passRead.output))["script_id"]?.stringValue)
        let savedScript = try XCTUnwrap(h.scriptStore.script(id: readerID))
        XCTAssertEqual(savedScript.metadata.testURLs, [u1, u2])
        XCTAssertTrue(savedScript.toUserScriptFileContent().contains("// @wukong-test-url \(u1)\n// @wukong-test-url \(u2)"))
        let stateAfterRead = try XCTUnwrap(h.stateStore.state(forHost: "127.0.0.1"))
        XCTAssertEqual(stateAfterRead.slot(.readTopic).status, .learned)
        XCTAssertEqual(stateAfterRead.slot(.readTopic).scriptID, readerID)
        XCTAssertEqual(stateAfterRead.slot(.readTopic).testURLs, [u1, u2])

        let liveRead = try await reg.dispatch(toolName: "read_topic", arguments: ["url": .string(u2)])
        XCTAssertTrue(!liveRead.isError && liveRead.output.contains("Btrfs Scrub Priority on NVMe"), liveRead.output)

        let duplicateSave = try await reg.dispatch(toolName: "script_save", arguments: [
            "name": .string("Second Reader"), "match_rules": .array([.string("*://127.0.0.1/*")]),
            "js": .string(Self.passingReadTopicJS), "provides": .array([.string("read_topic")]),
            "thread_match": .string("*://127.0.0.1/thread-*"), "test_urls": .array([.string(u1), .string(u2)])
        ])
        XCTAssertTrue(duplicateSave.isError && duplicateSave.output.contains("Hardware Reader (\(readerID)) already provides read_topic") && duplicateSave.output.contains("script_update"), duplicateSave.output)
        XCTAssertEqual(h.scriptStore.scripts.count, 1)

        try await h.waiter.load(h.webView, url: URL(string: forumURL)!)
        let s5ShortList = try await h.makeRegistry().dispatch(toolName: "script_save", arguments: [
            "name": .string("Short List"), "match_rules": .array([.string("*://127.0.0.1/*")]),
            "js": .string(#"await modelContext.registerTool({ name: "list_latest", execute: () => ({ shape: { items: [{ title: "One", url: location.origin + "/thread-101" }, { title: "", url: location.origin + "/thread-102" }] } })});"#),
            "provides": .array([.string("list_latest")]), "list_match": .string("*://127.0.0.1/forum*"), "test_urls": .array([.string(forumURL)])
        ])
        XCTAssertTrue(s5ShortList.isError && s5ShortList.output.contains("item #2 has an empty title"), s5ShortList.output)

        let s5EmptySearch = try await h.makeRegistry().dispatch(toolName: "script_save", arguments: [
            "name": .string("Empty Search"), "match_rules": .array([.string("*://127.0.0.1/*")]),
            "js": .string(#"await modelContext.registerTool({ name: "search_forum", execute: () => ({ shape: { items: [] } }) });"#),
            "provides": .array([.string("search_forum")]), "list_match": .string("*://127.0.0.1/forum*"), "test_urls": .array([.string(forumURL)])
        ])
        XCTAssertTrue(s5EmptySearch.isError && s5EmptySearch.output.contains("expected at least 1"), s5EmptySearch.output)

        let listReg = h.makeRegistry()
        let passList = try await listReg.dispatch(toolName: "script_save", arguments: [
            "name": .string("List Reader"), "match_rules": .array([.string("*://127.0.0.1/*")]),
            "js": .string(Self.passingListAndSearchJS), "provides": .array([.string("list_latest")]), "list_match": .string("*://127.0.0.1/forum*")
        ])
        XCTAssertTrue(!passList.isError && passList.output.contains("verified on the list page: 6 threads"), passList.output)
        let listID = try XCTUnwrap((try JSONValue.parseObjectJSON(passList.output))["script_id"]?.stringValue)
        XCTAssertEqual(h.scriptStore.script(id: listID)?.metadata.testURLs, [forumURL])

        let passSearch = try await listReg.dispatch(toolName: "script_update", arguments: [
            "script_id": .string(listID), "provides": .array([.string("list_latest"), .string("search_forum")]), "list_match": .string("*://127.0.0.1/forum*")
        ])
        XCTAssertTrue(!passSearch.isError && passSearch.output.contains("verified with a search for 'cooling': 2 results"), passSearch.output)
        XCTAssertEqual(h.scriptStore.script(id: listID)?.metadata.testURLs, [forumURL])

        let zeroHitSearch = try await listReg.dispatch(toolName: "search_forum", arguments: ["query": .string("zzzznomatch")])
        XCTAssertTrue(!zeroHitSearch.isError && zeroHitSearch.output == "No topics found.", zeroHitSearch.output)
    }

    /// Acceptance check 12: the inspector's shape check and a trial run on the fixture site.
    func testInspectorShapeCheckAndTrialRunOnTheFixtureSite() async throws {
        let base = try await startFixtureServer(), h = try makeHarness()
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        let u1 = base.appendingPathComponent("thread-101").absoluteString, u2 = base.appendingPathComponent("thread-102").absoluteString
        try await h.waiter.load(h.webView, url: URL(string: u1)!)
        let saved = try await h.makeRegistry().dispatch(toolName: "script_save", arguments: [
            "name": .string("Reader"), "match_rules": .array([.string("*://127.0.0.1/*")]), "js": .string(Self.passingReadTopicJS),
            "provides": .array([.string("read_topic")]), "thread_match": .string("*://127.0.0.1/thread-*"),
            "test_urls": .array([.string(u1), .string(u2)])
        ])
        XCTAssertFalse(saved.isError, saved.output)
        let state = try XCTUnwrap(h.stateStore.state(forHost: "127.0.0.1"))
        XCTAssertEqual(state.slot(.readTopic).lastCheck?.steps?.count, 9, "the learning save keeps each step for the inspector")
        let script = try XCTUnwrap(h.scriptStore.script(id: XCTUnwrap(state.slot(.readTopic).scriptID)))

        let report = await SiteShapeCheck.run(
            slot: .readTopic, script: script, state: state, openPageURL: u1, bridge: h.bridge,
            pageToolBridge: h.pageToolBridge, scriptStore: h.scriptStore
        )
        XCTAssertTrue(report.passed, report.reason ?? "")
        XCTAssertEqual(report.steps.count, 9)
        XCTAssertEqual(report.steps.first { $0.step == 5 }?.status, .skipped)
        XCTAssertEqual(h.stateStore.state(forHost: "127.0.0.1"), state, "the check changes no state, log or count")

        let rows = SiteInspectorTool.rows(snapshot: await h.pageToolBridge.collectTools(), state: state, scripts: h.scriptStore.scripts)
        let tool = try XCTUnwrap(rows.first { $0.learnedSlot == .readTopic })
        XCTAssertFalse(tool.warnsBeforeTrial)
        let audit = AuditLog(directory: try makeTempDir().appendingPathComponent("Audit"))
        let outcome = await ToolTrialRunner.run(
            tool, arguments: ["url": .string(u2)], host: "127.0.0.1", pageURL: u1,
            bridge: h.pageToolBridge, auditLog: audit, secrets: []
        )
        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertTrue(outcome.text.contains("Btrfs Scrub Priority on NVMe"))
        audit.flush()
        XCTAssertEqual(audit.allLines().filter { $0.kind == .toolTrial }.count, 1)
    }

    func testThreeRefusalsBoundUncountedPrechecksAndSiteLearningReport() async throws {
        let base = try await startFixtureServer(), h = try makeHarness()
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        let u1 = base.appendingPathComponent("thread-101").absoluteString
        let u2 = base.appendingPathComponent("thread-102").absoluteString
        try await h.waiter.load(h.webView, url: URL(string: u1)!)
        let reg = h.makeRegistry()

        for _ in 1...4 {
            let miss = try await reg.dispatch(toolName: "script_save", arguments: [
                "name": .string("Wrong Host"), "match_rules": .array([.string("*://other.example/*")]),
                "js": .string(Self.passingReadTopicJS), "provides": .array([.string("read_topic")]),
                "thread_match": .string("*://other.example/thread-*"),
                "test_urls": .array([.string("https://other.example/thread-1"), .string("https://other.example/thread-2")])
            ])
            XCTAssertTrue(miss.isError && miss.output.contains("open a thread of the site") && !miss.output.contains("Stop:"), miss.output)
        }
        h.scriptStore.isGlobalEnabled = false
        for _ in 1...4 {
            let off = try await reg.dispatch(toolName: "script_save", arguments: [
                "name": .string("Global Off"), "match_rules": .array([.string("*://127.0.0.1/*")]),
                "js": .string(Self.passingReadTopicJS), "provides": .array([.string("read_topic")]),
                "thread_match": .string("*://127.0.0.1/thread-*"), "test_urls": .array([.string(u1), .string(u2)])
            ])
            XCTAssertTrue(off.isError && off.output.contains("userscripts are turned off in Settings") && !off.output.contains("Stop:"), off.output)
        }
        h.scriptStore.isGlobalEnabled = true
        let seed = try h.scriptStore.create(id: "seed-script", name: "Seed", matchRules: ["*://127.0.0.1/*"], js: "1;", source: .agent(userPrompt: "x"))
        for _ in 1...4 {
            let dis = try await reg.dispatch(toolName: "script_update", arguments: [
                "script_id": .string(seed.id), "js": .string(Self.passingReadTopicJS), "enabled": .bool(false), "provides": .array([.string("list_latest")])
            ])
            XCTAssertTrue(dis.isError && dis.output.contains("only when it can be checked") && !dis.output.contains("Stop:"), dis.output)
        }
        _ = try h.scriptStore.delete(id: seed.id)
        XCTAssertNil(h.stateStore.state(forHost: "127.0.0.1"))

        for attempt in 1...3 {
            let res = try await reg.dispatch(toolName: "script_save", arguments: [
                "name": .string("Bad Attempt \(attempt)"), "match_rules": .array([.string("*://127.0.0.1/*")]),
                "js": .string("window.__attempt = \(attempt);"), "provides": .array([.string("read_topic")]),
                "thread_match": .string("*://127.0.0.1/thread-*"), "test_urls": .array([.string(u1), .string(u2)])
            ])
            XCTAssertTrue(res.isError)
            if attempt < 3 {
                XCTAssertFalse(res.output.contains("Stop: three attempts failed"), res.output)
                XCTAssertNil(h.stateStore.state(forHost: "127.0.0.1"))
            } else {
                XCTAssertTrue(res.output.contains("Stop: three attempts failed"), res.output)
            }
        }
        XCTAssertTrue(h.scriptStore.scripts.isEmpty)
        let failedState = try XCTUnwrap(h.stateStore.state(forHost: "127.0.0.1"))
        XCTAssertEqual(failedState.slot(.readTopic).status, .failed)
        XCTAssertEqual(failedState.slot(.readTopic).failure?.code, .refused3)
        XCTAssertNil(failedState.slot(.readTopic).scriptID)

        let gaveUp = try await reg.dispatch(toolName: "site_learning_report", arguments: [
            "slot": .string("list_latest"), "outcome": .string("gave_up"),
            "reason": .string("Thread list renders inside an encrypted WebSocket canvas.")
        ])
        let notApp = try await reg.dispatch(toolName: "site_learning_report", arguments: [
            "slot": .string("search_forum"), "outcome": .string("not_applicable"),
            "reason": .string("Site has no search endpoint or form.")
        ])
        XCTAssertTrue(!gaveUp.isError && !notApp.isError)
        let reported = try XCTUnwrap(h.stateStore.state(forHost: "127.0.0.1"))
        XCTAssertEqual(reported.slot(.listLatest).status, .failed)
        XCTAssertEqual(reported.slot(.listLatest).failure?.code, .gaveUp)
        XCTAssertEqual(reported.slot(.listLatest).failure?.agentReason, "Thread list renders inside an encrypted WebSocket canvas.")
        XCTAssertEqual(reported.slot(.searchForum).status, .notApplicable)
        XCTAssertEqual(reported.slot(.searchForum).failure?.agentReason, "Site has no search endpoint or form.")
        let promptLine = SiteToolState.readingPromptState(state: reported, scripts: []).pageContextLine
        XCTAssertFalse(promptLine.contains("WebSocket canvas") || promptLine.contains("search endpoint"))

        XCTAssertFalse(h.makeRegistry(surface: .voice).definitions.contains { $0.name == "site_learning_report" })
        h.pageToolBridge.isEnabled = false
        XCTAssertFalse(h.makeRegistry().definitions.contains { $0.name == "site_learning_report" })
    }
}
