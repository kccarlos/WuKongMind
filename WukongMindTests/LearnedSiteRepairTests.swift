import Foundation
import Network
import UIKit
import WebKit
import XCTest
@testable import WukongMind

// Invalidation and repair (`design-learn-on-ask.md` "Invalidation and repair"): the settled failure
// rule on fixtures, the broken slot, the repair count, and a recorded repair run.

// MARK: - The settled rule, on fixtures (no web view)

final class SiteFailureRuleTests: XCTestCase {
    private let host = "forum.test"
    private let u1 = URL(string: "https://forum.test/thread-1")!
    private let u2 = URL(string: "https://forum.test/thread-2")!
    private let listURL = URL(string: "https://forum.test/latest")!
    private let login = #"<form action="/login"><input type="text" name="u"><input type="password" name="p"></form>"#

    private func threadHTML(inlineLogin: Bool) -> String {
        "<html><body>\(inlineLogin ? login : "")<article><b>alice</b><p><b>Thermal</b> paste &amp; fans run <i>quiet</i> now</p></article></body></html>"
    }

    private func listHTML(first: Int, count: Int, inlineLogin: Bool) -> String {
        let rows = (first..<(first + count)).map { #"<li><a href="/thread-\#($0)">Title \#($0)</a></li>"# }.joined()
        return "<html><body>\(inlineLogin ? login : "")<ul>\(rows)</ul></body></html>"
    }

    private func page(_ html: String, status: Int = 200, at url: URL? = nil) -> SiteProbeResult {
        SiteProbeResult(status: status, finalURL: url ?? u1, html: html)
    }

    private func slotState(_ slot: SiteToolSlot) -> SiteSlotState {
        slot == .readTopic
            ? SiteSlotState(status: .learned, testURLs: [u1.absoluteString, u2.absoluteString], postStarts: [u1.absoluteString: ["Thermal paste & fans run quiet now"]])
            : SiteSlotState(status: .learned, testURLs: [listURL.absoluteString])
    }

    private func classify(
        _ slot: SiteToolSlot, requested: URL? = nil, said: Bool = false,
        pages: @escaping @Sendable (URL) -> SiteProbeResult, readerReads: Bool = false
    ) async -> SiteFailureKind {
        let match = [try! MatchPattern.parse("*://forum.test/thread-*")]
        let classifier = SiteFailureClassifier(host: host, threadMatch: match, fetch: { pages($0) }, readerReads: { _ in readerReads })
        return await classifier.classify(slot: slot, state: slotState(slot), requested: requested ?? (slot == .readTopic ? u1 : nil), readerSaidService: said)
    }

    /// Requirement (b): a broken reader is found, also on a site that shows a login box on every page.
    func testBrokenReaderIsToolEvenWithInlineLoginForm() async {
        let thread = await classify(.readTopic, pages: { [self] u in page(threadHTML(inlineLogin: true), at: u) })
        XCTAssertEqual(thread, .tool)
        let latest = await classify(.listLatest, pages: { [self] u in page(listHTML(first: 201, count: 6, inlineLogin: true), at: u) })
        XCTAssertEqual(latest, .tool, "the items all changed since verification, but the page still lists threads")
        let search = await classify(.searchForum, pages: { [self] u in page(listHTML(first: 1, count: 5, inlineLogin: true), at: u) })
        XCTAssertEqual(search, .tool)
        let plain = await classify(.listLatest, pages: { [self] u in page(listHTML(first: 1, count: 6, inlineLogin: false), at: u) })
        XCTAssertEqual(plain, .tool)
        let bareThread = await classify(.readTopic, pages: { [self] u in page("<html><article><p>Thermal paste &amp; fans run quiet now</p></article>", at: u) })
        XCTAssertEqual(bareThread, .tool, "post starts are compared after tags and entities are removed")
    }

    /// Requirement (a): the site's trouble is never the reader's.
    func testSiteTroubleIsServiceForThreadsAndLists() async {
        let signIn = SiteProbeResult(status: 200, finalURL: URL(string: "https://forum.test/login")!, html: login)
        let fewLinks = listHTML(first: 1, count: 4, inlineLogin: true)
        let cases: [(String, @Sendable (URL) -> SiteProbeResult)] = [
            ("sign-in page", { _ in signIn }),
            ("sign-in at the same address", { [login] u in SiteProbeResult(status: 200, finalURL: u, html: login) }),
            ("429", { u in SiteProbeResult(status: 429, finalURL: u, html: "Slow down") }),
            ("401", { u in SiteProbeResult(status: 401, finalURL: u) }),
            ("503", { u in SiteProbeResult(status: 503, finalURL: u) }),
            ("offline", { _ in SiteProbeResult(status: nil) }),
            ("another host", { _ in SiteProbeResult(status: 200, finalURL: URL(string: "https://sso.example/auth")!, html: "<html>ok</html>") })
        ]
        for (name, pages) in cases {
            for slot in SiteToolSlot.allCases {
                let kind = await classify(slot, pages: pages)
                XCTAssertEqual(kind, .service, "\(name) on \(slot.rawValue)")
            }
        }
        let fewListLinks = await classify(.listLatest, pages: { [fewLinks] u in SiteProbeResult(status: 200, finalURL: u, html: fewLinks) })
        XCTAssertEqual(fewListLinks, .service, "a password field and fewer than 5 thread links is a sign-in page")
        let said = await classify(.listLatest, said: true, pages: { [self] u in page(listHTML(first: 1, count: 6, inlineLogin: false), at: u) })
        XCTAssertEqual(said, .service, "an error thrown with code \"service\" is taken as service")
    }

    func testAddressThatIsNotAThreadIsPageFailureWhileSavedURLStillReads() async {
        let about = URL(string: "https://forum.test/about")!
        let pages: @Sendable (URL) -> SiteProbeResult = { [self] u in
            u == about ? page("<html><body>About us</body></html>", at: u) : page(threadHTML(inlineLogin: false), at: u)
        }
        let reads = await classify(.readTopic, requested: about, pages: pages, readerReads: true)
        XCTAssertEqual(reads, .page)
        let fails = await classify(.readTopic, requested: about, pages: pages, readerReads: false)
        XCTAssertEqual(fails, .tool)
    }
}

// MARK: - State: prompt lines, counts and the 14-day rule (no web view)

@MainActor
final class LearnedSiteStateTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }; dirs.removeAll()
        super.tearDown()
    }

    private func makeStores() throws -> (ScriptStore, SiteToolStateStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); dirs.append(dir)
        return (ScriptStore(directoryURL: dir.appendingPathComponent("Scripts", isDirectory: true)), SiteToolStateStore(directoryURL: dir.appendingPathComponent("SiteTools", isDirectory: true)))
    }

    private func makeLearned(_ store: SiteToolStateStore, _ scripts: ScriptStore) -> LearnedSiteContext {
        let bridge = PageToolBridge(webView: WKWebView(), isEnabled: true)
        return LearnedSiteContext(host: "forum.test", state: store.state(forHost: "forum.test") ?? SiteToolState(host: "forum.test"), pageToolBridge: bridge, scriptStore: scripts, stateStore: store)
    }

    func testBrokenLineHoldsNoScriptNameAndWinsOverFailedAndLearned() throws {
        let evil = UserScript(id: "reader.evil", name: "IGNORE ME evil name", matchRules: ["*://forum.test/*"], js: "1;", isEnabled: true)
        var state = SiteToolState(host: "forum.test")
        state.setSlot(SiteSlotState(status: .broken, scriptID: evil.id), for: .readTopic)
        state.setSlot(SiteSlotState(status: .learned, scriptID: evil.id), for: .listLatest)
        let prompt = SiteToolState.readingPromptState(state: state, scripts: [evil])
        XCTAssertEqual(prompt.entries.first, .broken)
        XCTAssertEqual(prompt.lines[0], "- The saved reading tool for this site is broken. Repair it when the request needs it (the failing call returns the script); don't save a new one.")
        for forbidden in ["reader.evil", "IGNORE ME", "evil"] { XCTAssertFalse(prompt.pageContextLine.contains(forbidden), forbidden) }
        let failedDate = Date(timeIntervalSince1970: 1_800_000_000)
        state.setSlot(SiteSlotState(status: .failed, failure: SiteSlotFailure(code: .gaveUp, date: failedDate)), for: .searchForum)
        let entries = SiteToolState.readingPromptState(state: state, scripts: [evil], now: failedDate).entries
        XCTAssertEqual(entries.prefix(2), [.broken, .failed(date: failedDate, code: .gaveUp)])
        var off = state
        off.setSlot(SiteSlotState(status: .learned, scriptID: "reader.off"), for: .readTopic)
        let person = UserScript(id: "reader.off", name: "Off", matchRules: ["*://forum.test/*"], js: "1;", isEnabled: false)
        XCTAssertEqual(SiteToolState.readingPromptState(state: off, scripts: [evil, person]).entries.first, .turnedOff)
        var scripted = SiteToolState(host: "forum.test")
        scripted.setSlot(SiteSlotState(status: .broken, scriptID: evil.id), for: .readTopic)
        XCTAssertEqual(SiteToolState.readingPromptState(state: scripted, scripts: []), .none, "a deleted script leaves its slot untried")
    }

    func testFailedSiteIsNotOfferedAgainInsideFourteenDays() {
        let failed = ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z")!
        var state = SiteToolState(host: "forum.test")
        state.setSlot(SiteSlotState(status: .failed, failure: SiteSlotFailure(code: .noPosts, date: failed)), for: .readTopic)
        func line(afterDays days: Double) -> String {
            SiteToolState.readingPromptState(state: state, scripts: [], now: failed.addingTimeInterval(days * 86_400 + 60)).pageContextLine
        }
        XCTAssertTrue(line(afterDays: 13.9).contains("Don't try again unless the user asks"))
        XCTAssertTrue(line(afterDays: 14).contains("learn it again") && !line(afterDays: 14).contains("Don't try again"))
        let off = UserScript(id: "reader.1", name: "R", matchRules: ["*://forum.test/*"], js: "1;", isEnabled: false, disabledReason: "repair_3")
        state.setSlot(SiteSlotState(status: .failed, scriptID: off.id, failure: SiteSlotFailure(code: .repair3, date: failed)), for: .readTopic)
        let later = SiteToolState.readingPromptState(state: state, scripts: [off], now: failed.addingTimeInterval(15 * 86_400)).pageContextLine
        XCTAssertTrue(later.contains("`script_update`") && later.contains("don't save a second one") && !later.contains("reader.1"), later)
    }

    func testRepairFailuresCountRunsThatEndBrokenAndThreeTurnTheScriptOff() throws {
        let (scripts, store) = try makeStores()
        let script = try scripts.create(id: "reader.r", name: "R", matchRules: ["*://forum.test/*"], js: "1;", source: .agent(userPrompt: "x"))
        var state = SiteToolState(host: "forum.test")
        state.setSlot(SiteSlotState(status: .broken, scriptID: script.id), for: .readTopic)
        try store.save(state)
        let learned = makeLearned(store, scripts)

        for run in 1...2 {
            learned.scope.brokenSlots = [.readTopic]
            LearnedSiteRepair.finishRun(learned: learned, scriptStore: scripts, taskID: "t\(run)")
            let slot = try XCTUnwrap(store.state(forHost: "forum.test")?.slot(.readTopic))
            XCTAssertEqual(slot.repairFailures, run); XCTAssertEqual(slot.status, .broken); XCTAssertEqual(slot.scriptID, script.id)
        }
        learned.scope.brokenSlots = []
        LearnedSiteRepair.finishRun(learned: learned, scriptStore: scripts, taskID: "quiet")
        XCTAssertEqual(store.state(forHost: "forum.test")?.slot(.readTopic).repairFailures, 2, "a run that never met the broken slot counts nothing")

        let verified = SiteToolVerificationReport(passed: true)
        LearnedSiteRepair.markVerified(.readTopic, script: script, report: verified, learned: learned, taskID: "fix")
        var repaired = try XCTUnwrap(store.state(forHost: "forum.test")?.slot(.readTopic))
        XCTAssertEqual(repaired.status, .learned); XCTAssertEqual(repaired.repairFailures, 0)
        XCTAssertEqual(store.state(forHost: "forum.test")?.log.first?.kind, .repaired)

        repaired.status = .broken; repaired.repairFailures = 0
        try store.update(host: "forum.test") { $0.setSlot(repaired, for: .readTopic) }
        for run in 1...3 {
            learned.scope.brokenSlots = [.readTopic]
            LearnedSiteRepair.finishRun(learned: learned, scriptStore: scripts, taskID: "r\(run)")
        }
        let failed = try XCTUnwrap(store.state(forHost: "forum.test")?.slot(.readTopic))
        XCTAssertEqual(failed.status, .failed); XCTAssertEqual(failed.failure?.code, .repair3); XCTAssertEqual(failed.scriptID, script.id)
        let off = try XCTUnwrap(scripts.script(id: script.id))
        XCTAssertFalse(off.isEnabled); XCTAssertEqual(off.disabledReason, "repair_3")
    }

    func testThreePageLoadErrorsSetLoadErrors3AndKeepScriptID() async throws {
        let (scripts, store) = try makeStores()
        let script = try scripts.create(id: "reader.l", name: "L", matchRules: ["*://forum.test/*"], js: "1;", source: .agent(userPrompt: "x"))
        var state = SiteToolState(host: "forum.test")
        state.setSlot(SiteSlotState(status: .learned, scriptID: script.id), for: .readTopic)
        try store.save(state)
        for n in 1...3 { scripts.recordPageLoadError(scriptID: script.id, message: "boom", loadID: "load-\(n)") }
        let gate = await ToolRegistry.learnedSlotGate(slot: .readTopic, learned: makeLearned(store, scripts), scriptStore: scripts)
        XCTAssertNotNil(gate.refusal)
        let slot = try XCTUnwrap(store.state(forHost: "forum.test")?.slot(.readTopic))
        XCTAssertEqual(slot.status, .failed); XCTAssertEqual(slot.failure?.code, .loadErrors3); XCTAssertEqual(slot.scriptID, script.id)
    }

    func testAScriptThePersonTurnedOffIsNeverTurnedOnByTheAgent() async throws {
        let (scripts, store) = try makeStores()
        let script = try scripts.create(id: "reader.p", name: "P", matchRules: ["*://forum.test/*"], js: "1;", source: .agent(userPrompt: "x"), provides: ["read_topic"])
        _ = try scripts.setEnabled(id: script.id, isEnabled: false)
        let registry = ToolRegistry.m3(context: AgentToolContext(bridge: FixturePageDriver(page: .init(url: "https://forum.test/thread-1", title: "T", structure: "", text: "")), workspace: nil, scriptStore: scripts, siteToolStateStore: store))
        let result = try await registry.dispatch(toolName: "script_update", arguments: ["script_id": .string(script.id), "enabled": .bool(true)])
        XCTAssertTrue(result.isError && result.output.contains("turned off in This page"), result.output)
        XCTAssertFalse(try XCTUnwrap(scripts.script(id: script.id)).isEnabled)
    }
}

// MARK: - A fixture forum in a real web view: breaking, site trouble and a recorded repair run

@MainActor
final class LearnedSiteRepairWebTests: XCTestCase {
    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private var windows: [UIWindow] = [], listeners: [NWListener] = [], tempDirs: [URL] = []

    /// What the fixture site does right now; the server reads it on every request.
    final class Site: @unchecked Sendable {
        enum Mode { case normal, signIn, tooMany }
        private let lock = NSLock()
        private var _mode = Mode.normal, _inlineLogin = false, _listFirst = 101
        private var _paths: [String] = []
        /// Every path the fixture site has been asked for, in order.
        var paths: [String] { lock.withLock { _paths } }
        func record(_ path: String) { lock.withLock { _paths.append(path) } }
        var mode: Mode { get { lock.withLock { _mode } } set { lock.withLock { _mode = newValue } } }
        var inlineLogin: Bool { get { lock.withLock { _inlineLogin } } set { lock.withLock { _inlineLogin = newValue } } }
        var listFirst: Int { get { lock.withLock { _listFirst } } set { lock.withLock { _listFirst = newValue } } }
    }

    private static let posts101 = (1...10).map { ($0, $0 == 2 ? "" : "user\($0)", "Post number \($0) about fan hysteresis and thermal paste curves on the laptop heatsink.") }
    private static let posts102 = (1...4).map { ($0, "nina\($0)", "Reply \($0) about btrfs scrub priority and NVMe latency during long Rust builds.") }
    private static let loginForm = #"<form action="/login"><input type="text" name="u"><input type="password" name="p"></form>"#

    nonisolated private static func serve(path: String, site: Site) -> (Int, String, Data) {
        site.record(path)
        func html(_ body: String, _ status: Int = 200) -> (Int, String, Data) { (status, "text/html; charset=utf-8", Data("<!doctype html><html><body>\(body)</body></html>".utf8)) }
        switch site.mode {
        case .signIn: return html(loginForm)
        case .tooMany: return (429, "text/plain", Data("Too many requests".utf8))
        case .normal: break
        }
        func json(_ object: Any) -> (Int, String, Data) { (200, "application/json", (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)) }
        func apiPosts(_ title: String, _ posts: [(Int, String, String)]) -> (Int, String, Data) {
            json(["title": title, "posts": posts.map { ["number": $0.0, "author": $0.1, "body": $0.2, "date": "2026-11-15T10:00:00Z"] as [String: Any] }])
        }
        let form = site.inlineLogin ? loginForm : ""
        let first = site.listFirst
        switch path {
        case "/forum":
            let rows = (first..<(first + 6)).map { #"<li><a href="/thread-\#($0)">Cooling thread \#($0)</a></li>"# }.joined()
            return html("\(form)<ul>\(rows)</ul>")
        case "/thread-101", "/thread-102":
            let posts = path.hasSuffix("101") ? posts101 : posts102
            return html(form + posts.map { "<article><b>\($0.1)</b> <span>#\($0.0)</span><p>\($0.2)</p></article>" }.joined())
        case "/api/thread-101": return apiPosts("Cooling Fan Hysteresis and Paste", posts101)
        case "/api/thread-102": return apiPosts("Btrfs Scrub Priority on NVMe", posts102)
        case "/api/latest":
            return json(["items": (first..<(first + 6)).map { ["id": "\($0)", "title": "Cooling thread \($0)", "path": "/thread-\($0)"] }])
        case "/api/search":
            return json(["items": [["title": "Cooling thread \(first)", "path": "/thread-\(first)"]]])
        default: return html("About this forum")
        }
    }

    private func startServer(_ site: Site) async throws -> URL {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any); params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params), queue = DispatchQueue(label: "dev.wukongmind.learnedrepair")
        listeners.append(listener)
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            listener.newConnectionHandler = { conn in
                conn.start(queue: queue)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? "GET / HTTP/1.1"
                    let target = req.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let (status, ctype, body) = Self.serve(path: URLComponents(string: "http://x" + target)?.path ?? "/", site: site)
                    let head = "HTTP/1.1 \(status) X\r\nContent-Type: \(ctype)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
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

    final class Waiter: NSObject, WKNavigationDelegate, AgentPageNavigating {
        weak var webView: WKWebView?
        private var continuation: CheckedContinuation<Void, Error>?
        func load(_ wv: WKWebView, url: URL, timeout: Double = 20) async throws {
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

    static let readerJS = """
    await modelContext.registerTool({ name: "read_topic", annotations: { readOnlyHint: true }, async execute({ url, page = 1 }) {
      const d = await (await fetch("/api" + new URL(url).pathname)).json();
      return { shape: { title: d.title, url, total_posts: d.posts.length, posts: d.posts }, page, total_pages: 1 };
    }});
    await modelContext.registerTool({ name: "list_latest", annotations: { readOnlyHint: true }, async execute() {
      const d = await (await fetch("/api/latest")).json();
      return { shape: { items: d.items.map(x => ({ id: x.id, title: x.title, url: location.origin + x.path })) } };
    }});
    await modelContext.registerTool({ name: "search_forum", annotations: { readOnlyHint: true }, async execute({ query, page = 1 }) {
      const d = await (await fetch("/api/search?q=" + encodeURIComponent(query))).json();
      return { shape: { items: query === "nomatch" ? [] : d.items.map(x => ({ title: x.title, url: location.origin + x.path })) }, page, total_pages: 1 };
    }});
    """

    /// The same reader, edited to return nothing.
    static let emptyReaderJS = """
    await modelContext.registerTool({ name: "read_topic", async execute({ url }) { return { shape: { title: "T", url, total_posts: 0, posts: [] } }; }});
    await modelContext.registerTool({ name: "list_latest", async execute() { return { shape: { items: [] } }; }});
    await modelContext.registerTool({ name: "search_forum", async execute() { return { shape: { items: [] } }; }});
    """

    struct Harness {
        let site: Site, base: URL
        let webView: WKWebView, waiter: Waiter, bridge: AgentBridge
        let scriptStore: ScriptStore, stateStore: SiteToolStateStore, workspace: AgentWorkspace
        let pageToolBridge: PageToolBridge, controller: ScriptWebController, client: AgentHTTPClient
        var u1: String { base.appendingPathComponent("thread-101").absoluteString }
        var u2: String { base.appendingPathComponent("thread-102").absoluteString }
        var forum: String { base.appendingPathComponent("forum").absoluteString }

        @MainActor func makeLearned() -> LearnedSiteContext {
            LearnedSiteContext(
                host: "127.0.0.1", state: stateStore.state(forHost: "127.0.0.1") ?? SiteToolState(host: "127.0.0.1"),
                pageToolBridge: pageToolBridge, scriptStore: scriptStore, stateStore: stateStore
            )
        }

        @MainActor func context(_ learned: LearnedSiteContext) -> AgentToolContext {
            AgentToolContext(
                bridge: bridge, workspace: workspace, scriptStore: scriptStore, liveApplier: controller, network: client,
                learnedSite: learned, pageTools: PageToolContext(bridge: pageToolBridge, scriptStore: scriptStore), siteToolStateStore: stateStore
            )
        }

        @MainActor func registry(_ learned: LearnedSiteContext? = nil) -> ToolRegistry {
            var reg = ToolRegistry.m3(context: context(learned ?? makeLearned())); reg.taskID = "task-repair"; return reg
        }

        @MainActor func session(_ client: AgentModelClient) -> BrowserAgentSession {
            let runtime = BrowserAgentRuntimeConfig(
                selection: ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
                configuration: ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake-key"),
                maxSteps: 8, truncationLimit: 20_000, customInstructions: "", redactedSecrets: []
            )
            return BrowserAgentSession(pageDriver: bridge, modelClient: client, configProvider: { runtime }, registryBuilder: { _, _, _ in registry() })
        }
    }

    func makeHarness() async throws -> Harness {
        let site = Site(), base = try await startServer(site)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("repair-web-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); tempDirs.append(dir)
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844), cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = Self.sharedDataStore; cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        ForumBrowserModel.disableWebKitScreenTimeForTesting(in: cfg)
        let webView = WKWebView(frame: frame, configuration: cfg), waiter = Waiter()
        waiter.webView = webView; webView.navigationDelegate = waiter
        let win = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: frame)
        win.frame = frame; let vc = UIViewController(); vc.view.frame = frame; vc.view.addSubview(webView)
        win.rootViewController = vc; win.makeKeyAndVisible(); win.layoutIfNeeded(); windows.append(win)
        let scriptStore = ScriptStore(directoryURL: dir.appendingPathComponent("Scripts", isDirectory: true))
        let stateStore = SiteToolStateStore(directoryURL: dir.appendingPathComponent("SiteTools", isDirectory: true))
        let bridge = AgentBridge(webView: webView); bridge.navigator = waiter
        let pageToolBridge = PageToolBridge(webView: webView, isEnabled: true)
        let controller = ScriptWebController(webView: webView, store: scriptStore, agentBridge: bridge, pageToolBridge: pageToolBridge)
        return Harness(
            site: site, base: base, webView: webView, waiter: waiter, bridge: bridge, scriptStore: scriptStore, stateStore: stateStore,
            workspace: AgentWorkspace(root: dir.appendingPathComponent("ws", isDirectory: true)),
            pageToolBridge: pageToolBridge, controller: controller, client: AgentHTTPClient()
        )
    }

    /// Learns all three slots through the real `script_save`, so state, hash and post starts are the app's own.
    func learn(_ h: Harness) async throws -> UserScript {
        try await h.waiter.load(h.webView, url: URL(string: h.u1)!)
        let saved = try await h.registry().dispatch(toolName: "script_save", arguments: [
            "name": .string("Forum reader"), "match_rules": .array([.string("*://127.0.0.1/*")]), "js": .string(Self.readerJS),
            "provides": .array([.string("read_topic"), .string("list_latest"), .string("search_forum")]),
            "thread_match": .string("*://127.0.0.1/thread-*"), "list_match": .string("*://127.0.0.1/forum"),
            "test_urls": .array([.string(h.u1), .string(h.u2), .string(h.forum)])
        ])
        XCTAssertFalse(saved.isError, saved.output)
        let script = try XCTUnwrap(h.scriptStore.scripts.first)
        XCTAssertEqual(h.stateStore.state(forHost: "127.0.0.1")?.slot(.readTopic).status, .learned)
        return script
    }

    /// Edits the reader's text, as a person or a sync would; `keepHash` keeps the saved hash so only the light check applies.
    func edit(_ h: Harness, _ script: UserScript, js: String, keepHash: Bool = false, reload: String? = nil) async throws {
        let updated = try h.scriptStore.update(id: script.id, patch: ScriptUpdatePatch(js: js))
        if !keepHash {
            try h.stateStore.update(host: "127.0.0.1") { state in
                for slot in SiteToolSlot.allCases where state.slot(slot).scriptID == script.id {
                    var s = state.slot(slot); s.scriptHash = SiteToolVerifier.scriptTextHash(for: updated); state.setSlot(s, for: slot)
                }
            }
        }
        h.controller.syncUserScripts()
        try await h.waiter.load(h.webView, url: URL(string: reload ?? h.u1)!)
        try await Task.sleep(nanoseconds: 80_000_000)
    }

    func slot(_ h: Harness, _ slot: SiteToolSlot) -> SiteSlotState { h.stateStore.state(forHost: "127.0.0.1")?.slot(slot) ?? SiteSlotState() }

    /// Requirement (a) and the cases that must not break a slot: nothing changes, nothing is recorded.
    func testSiteTroubleNeverBreaksTheSlotOrTouchesTheErrorList() async throws {
        let h = try await makeHarness(), script = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        let reg = h.registry()

        for mode in [Site.Mode.signIn, .tooMany] {
            h.site.mode = mode
            let thread = try await reg.dispatch(toolName: "read_topic", arguments: ["url": .string(h.u1)])
            let list = try await reg.dispatch(toolName: "list_latest", arguments: [:])
            for result in [thread, list] {
                XCTAssertTrue(result.isError && result.output.contains("isn't answering the way it should"), result.output)
                XCTAssertTrue(result.notes.isEmpty)
            }
            XCTAssertEqual(slot(h, .readTopic).status, .learned); XCTAssertEqual(slot(h, .listLatest).status, .learned)
            XCTAssertTrue(h.scriptStore.errors(for: script.id).isEmpty)
            XCTAssertTrue(try XCTUnwrap(h.scriptStore.script(id: script.id)).isEnabled)
        }
        h.site.mode = .normal

        // A URL that is not a thread, while a saved test URL still reads, is a page failure.
        let about = try await reg.dispatch(toolName: "read_topic", arguments: ["url": .string(h.base.appendingPathComponent("about").absoluteString)])
        XCTAssertTrue(about.isError)
        XCTAssertEqual(slot(h, .readTopic).status, .learned, about.output)
        XCTAssertTrue(h.scriptStore.errors(for: script.id).isEmpty)

        // A search with no results is not a failure; `list_latest` on a normal page succeeds.
        let none = try await reg.dispatch(toolName: "search_forum", arguments: ["query": .string("nomatch")])
        XCTAssertFalse(none.isError, none.output)
        let latest = try await reg.dispatch(toolName: "list_latest", arguments: [:])
        XCTAssertFalse(latest.isError, latest.output)
        XCTAssertEqual(slot(h, .searchForum).status, .learned)
    }

    /// Requirement (b), and the broken slot's result: the error, the trusted note and the repair block.
    func testReaderEditedToReturnNothingBreaksTheSlotEvenWithInlineLoginForm() async throws {
        let h = try await makeHarness(), script = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        h.site.inlineLogin = true
        try await edit(h, script, js: Self.emptyReaderJS, keepHash: true)
        let learned = h.makeLearned()
        let reg = h.registry(learned)

        let thread = try await reg.dispatch(toolName: "read_topic", arguments: ["url": .string(h.u1)])
        XCTAssertTrue(thread.isError, thread.output)
        XCTAssertEqual(slot(h, .readTopic).status, .broken)
        XCTAssertEqual(slot(h, .readTopic).scriptID, script.id)
        XCTAssertEqual(thread.notes, [.slotBroken])
        XCTAssertTrue(thread.output.contains("Script repair context") && thread.output.contains(script.id))
        XCTAssertFalse(h.scriptStore.errors(for: script.id).isEmpty)
        XCTAssertEqual(learned.scope.brokenSlots, [.readTopic])
        XCTAssertEqual(learned.scope.repairState?.target.scriptID, script.id)
        let context = SiteToolState.readingPromptState(state: h.stateStore.state(forHost: "127.0.0.1"), scripts: h.scriptStore.scripts).pageContextLine
        XCTAssertTrue(context.contains("is broken") && !context.contains(script.id) && !context.contains("Forum reader"))

        // The list slot, on a list page with an inline login form whose items have all changed since verification.
        h.site.listFirst = 201
        let list = try await h.registry(learned).dispatch(toolName: "list_latest", arguments: [:])
        XCTAssertTrue(list.isError, list.output)
        XCTAssertEqual(slot(h, .listLatest).status, .broken)
    }

    /// The page can't run the reader (another page is open): neither the reader's nor the site's fault.
    func testReaderNotRunnableOnTheOpenPageLeavesTheSlotLearned() async throws {
        let h = try await makeHarness(), script = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        let learned = h.makeLearned()
        try await h.waiter.load(h.webView, url: URL(string: "data:text/html,<html><body>elsewhere</body></html>")!)
        for (tool, args) in [("read_topic", ["url": JSONValue.string(h.u1)]), ("list_latest", [:])] {
            let result = try await h.registry(learned).dispatch(toolName: tool, arguments: args)
            XCTAssertTrue(result.isError && result.notes.isEmpty, result.output)
            XCTAssertFalse(result.output.contains("Script repair context"))
        }
        XCTAssertEqual(slot(h, .readTopic).status, .learned); XCTAssertEqual(slot(h, .listLatest).status, .learned)
        XCTAssertTrue(h.scriptStore.errors(for: script.id).isEmpty)
        XCTAssertTrue(learned.scope.brokenSlots.isEmpty)
    }

    /// A reader that never resolves is the reader's own fault (`tool`); a site that times out is not.
    func testHangingReaderBreaksTheSlotButASlowSiteDoesNot() async throws {
        let h = try await makeHarness(), script = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        let hang = "await modelContext.registerTool({ name: \"read_topic\", async execute() { await new Promise(() => {}); } });"
        try await edit(h, script, js: hang)
        var learned = h.makeLearned(); learned.readerTimeout = 1
        // The site answers normally, so the hang is the reader's.
        let hung = try await h.registry(learned).dispatch(toolName: "read_topic", arguments: ["url": .string(h.u1)])
        XCTAssertTrue(hung.isError && hung.output.contains("Script repair context"), hung.output)
        XCTAssertEqual(slot(h, .readTopic).status, .broken)

        // Back to a healthy reader; now the site itself is the one that fails.
        try h.stateStore.update(host: "127.0.0.1") { state in var s = state.slot(.readTopic); s.status = .learned; s.repairFailures = 0; state.setSlot(s, for: .readTopic) }
        try await edit(h, script, js: hang)
        h.site.mode = .tooMany
        var learned2 = h.makeLearned(); learned2.readerTimeout = 1
        let slow = try await h.registry(learned2).dispatch(toolName: "read_topic", arguments: ["url": .string(h.u1)])
        XCTAssertTrue(slow.isError && slow.output.contains("isn't answering the way it should"), slow.output)
        XCTAssertEqual(slot(h, .readTopic).status, .learned)
    }

    /// A reader edited by hand fails its next call (the full check on a changed hash), once.
    func testChangedHashRunsTheFullCheckOnce() async throws {
        let h = try await makeHarness(), script = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        let before = try XCTUnwrap(slot(h, .readTopic).scriptHash)
        try await edit(h, script, js: Self.readerJS + "\n// cosmetic edit\n", keepHash: true)
        let checkedAt = slot(h, .readTopic).lastCheck?.date
        let ok = try await h.registry().dispatch(toolName: "read_topic", arguments: ["url": .string(h.u1)])
        XCTAssertFalse(ok.isError, ok.output)
        let after = try XCTUnwrap(slot(h, .readTopic).scriptHash)
        XCTAssertNotEqual(before, after)
        let ranAt = slot(h, .readTopic).lastCheck?.date
        XCTAssertNotEqual(checkedAt, ranAt, "the first call after the edit ran the full check")
        _ = try await h.registry().dispatch(toolName: "read_topic", arguments: ["url": .string(h.u1)])
        XCTAssertEqual(slot(h, .readTopic).lastCheck?.date, ranAt, "the second call did not")

        try await edit(h, script, js: Self.emptyReaderJS, keepHash: true)
        let bad = try await h.registry().dispatch(toolName: "read_topic", arguments: ["url": .string(h.u1)])
        XCTAssertTrue(bad.isError, bad.output)
        XCTAssertEqual(slot(h, .readTopic).status, .broken)
    }

    /// A script that arrives with no state (synced) runs the full check on its header's test URLs before its first answer.
    func testSyncedScriptWithNoStateGetsTheFullCheckBeforeItsFirstAnswer() async throws {
        let h = try await makeHarness(), script = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        let synced = try XCTUnwrap(h.scriptStore.script(id: script.id))
        XCTAssertEqual(synced.metadata.testURLs.count, 3)
        h.stateStore.forget(host: "127.0.0.1")
        var state = SiteToolState(host: "127.0.0.1")
        XCTAssertTrue(state.adoptSyncedReaders(from: h.scriptStore.scripts))
        XCTAssertEqual(state.slot(.listLatest).testURLs, [h.forum])
        XCTAssertEqual(state.slot(.readTopic).testURLs.count, 2)
        XCTAssertNil(state.slot(.readTopic).lastCheck)
        try h.stateStore.save(state)
        let result = try await h.registry().dispatch(toolName: "read_topic", arguments: ["url": .string(h.u2)])
        XCTAssertFalse(result.isError, result.output)
        let checked = slot(h, .readTopic)
        XCTAssertEqual(checked.scriptHash, SiteToolVerifier.scriptTextHash(for: synced))
        XCTAssertNotNil(checked.lastCheck); XCTAssertFalse(checked.postStarts.isEmpty)
        XCTAssertFalse(state.adoptSyncedReaders(from: h.scriptStore.scripts), "a slot that has a script is not adopted again")
    }

    /// Acceptance check 5 as a replay: a broken reader is repaired inside the run that needed it, with no second script.
    func testRecordedRunRepairsABrokenReaderAndAnswers() async throws {
        let h = try await makeHarness(), script = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        try await edit(h, script, js: Self.emptyReaderJS, keepHash: true)
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "c1", name: "read_topic", arguments: ["url": .string(h.u1)])])),
            .success(AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "c2", name: "script_update", arguments: [
                "script_id": .string(script.id), "js": .string(Self.readerJS), "enabled": .bool(true),
                "test_urls": .array([.string(h.u1), .string(h.u2), .string(h.forum)])
            ])])),
            .success(AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "c3", name: "read_topic", arguments: ["url": .string(h.u1)])])),
            .success(AgentModelTurnResponse(text: "The thread is about fan curves."))
        ])
        let session = h.session(client)
        await session.sendAndWait("Summarize this thread and replies")
        let rows = session.runs[0].toolCalls
        XCTAssertEqual(rows.map(\.toolName), ["read_topic", "script_update", "read_topic"])
        XCTAssertEqual(rows.map(\.isError), [true, false, false], rows.map(\.resultText).joined(separator: "\n---\n"))
        XCTAssertEqual(h.scriptStore.scripts.count, 1)
        let fixed = slot(h, .readTopic)
        XCTAssertEqual(fixed.status, .learned); XCTAssertEqual(fixed.repairFailures, 0); XCTAssertEqual(fixed.scriptID, script.id)
        XCTAssertEqual(h.stateStore.state(forHost: "127.0.0.1")?.log.map(\.kind).prefix(3).contains(.repaired), true)
        XCTAssertTrue(session.runs[0].assistantText.contains("fan curves"))
        let entry = try XCTUnwrap(BrowserAgentRunsView.savedScriptEntries(in: session.runs[0]).first)
        XCTAssertEqual(entry.repairTarget?.scriptID, script.id, "the card reads Fixed and offers Undo")
    }

    /// A repair that names only the failing URL still verifies on the saved test URLs.
    func testRepairNamingOnlyTheFailingURLUsesTheSavedTestURLs() async throws {
        let h = try await makeHarness(), script = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        try await edit(h, script, js: Self.emptyReaderJS, keepHash: true)
        _ = try await h.registry().dispatch(toolName: "read_topic", arguments: ["url": .string(h.u1)])
        let fixed = try await h.registry().dispatch(toolName: "script_update", arguments: [
            "script_id": .string(script.id), "js": .string(Self.readerJS), "enabled": .bool(true), "test_urls": .array([.string(h.u1)])
        ])
        XCTAssertFalse(fixed.isError, fixed.output)
        XCTAssertEqual(slot(h, .readTopic).status, .learned)
    }

    /// A run that ends with the slot still broken counts one failed repair; the next run repairs the same script
    /// (a second reader is refused), and three such runs turn the script off.
    func testUnfinishedRepairsCountAndThreeLeaveTheSlotFailed() async throws {
        let h = try await makeHarness(), script = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        try await edit(h, script, js: Self.emptyReaderJS, keepHash: true)
        func giveUp(_ extra: [AgentModelToolCall] = []) -> [AgentModelTurnResponse] {
            [AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "a", name: "read_topic", arguments: ["url": .string(h.u1)])] + extra),
             AgentModelTurnResponse(text: "I could not read the thread; here is what the page shows.")]
        }
        let secondReader = AgentModelToolCall(id: "b", name: "script_save", arguments: [
            "name": .string("Second reader"), "match_rules": .array([.string("*://127.0.0.1/*")]), "js": .string(Self.readerJS),
            "provides": .array([.string("read_topic")]), "thread_match": .string("*://127.0.0.1/thread-*"),
            "test_urls": .array([.string(h.u1), .string(h.u2)])
        ])
        let client = RecordedModelClient((giveUp() + giveUp([secondReader]) + giveUp()).map { .success($0) })
        let session = h.session(client)

        await session.sendAndWait("Summarize this thread")
        XCTAssertEqual(slot(h, .readTopic).repairFailures, 1); XCTAssertEqual(slot(h, .readTopic).status, .broken)
        await session.sendAndWait("Try again")
        XCTAssertEqual(slot(h, .readTopic).repairFailures, 2)
        let attempt = try XCTUnwrap(session.runs[1].toolCalls.first { $0.toolName == "script_save" })
        XCTAssertTrue(attempt.isError && attempt.resultText.contains("already provides read_topic"), attempt.resultText)
        guard case .user(let turn2)? = client.recordedRequests[2].messages.last else { return XCTFail("missing turn") }
        XCTAssertTrue(turn2.contains("is broken. Repair it when the request needs it"), turn2)
        XCTAssertEqual(h.scriptStore.scripts.count, 1)

        await session.sendAndWait("Once more")
        let failed = slot(h, .readTopic)
        XCTAssertEqual(failed.status, .failed); XCTAssertEqual(failed.failure?.code, .repair3); XCTAssertEqual(failed.scriptID, script.id)
        let off = try XCTUnwrap(h.scriptStore.script(id: script.id))
        XCTAssertFalse(off.isEnabled); XCTAssertEqual(off.disabledReason, "repair_3")
    }

    /// A script the app turned off is turned on again by a verified `script_update`.
    func testVerifiedUpdateTurnsAnAppDisabledReaderBackOn() async throws {
        let h = try await makeHarness(), script = try await learn(h)
        defer { h.controller.detach(); h.pageToolBridge.detach() }
        h.scriptStore.disableForLibraryFailure(id: script.id, reason: "repair_3")
        try h.stateStore.update(host: "127.0.0.1") { state in
            for slot in SiteToolSlot.allCases {
                var s = state.slot(slot); s.status = .failed; s.failure = SiteSlotFailure(code: .repair3); state.setSlot(s, for: slot)
            }
        }
        h.controller.syncUserScripts()
        try await h.waiter.load(h.webView, url: URL(string: h.u1)!)
        let result = try await h.registry().dispatch(toolName: "script_update", arguments: [
            "script_id": .string(script.id), "js": .string(Self.readerJS + "\n// retry\n"), "enabled": .bool(true),
            "test_urls": .array([.string(h.u1), .string(h.u2), .string(h.forum)])
        ])
        XCTAssertFalse(result.isError, result.output)
        let on = try XCTUnwrap(h.scriptStore.script(id: script.id))
        XCTAssertTrue(on.isEnabled); XCTAssertNil(on.disabledReason)
        XCTAssertEqual(slot(h, .readTopic).status, .learned); XCTAssertNil(slot(h, .readTopic).failure)
    }
}
