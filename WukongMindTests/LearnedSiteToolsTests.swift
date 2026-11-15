import Foundation
import Network
import UIKit
import WebKit
import XCTest
@testable import WukongMind

@MainActor
final class LearnedSiteToolsTests: XCTestCase {
    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private var windows: [UIWindow] = []
    private var listeners: [NWListener] = []
    private var tempDirs: [URL] = []

    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        func load(_ webView: WKWebView, url: URL, timeout: Double = 30) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                webView.load(URLRequest(url: url))
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("learned-site-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func startFixtureForum() async throws -> URL {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "dev.wukongmind.learnedsitetools")
        listeners.append(listener)
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.newConnectionHandler = { conn in
                conn.start(queue: queue)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? "GET / HTTP/1.1"
                    let path = req.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let body = Data("<!doctype html><html><head><title>Fixture Forum</title></head><body><main>\(path)</main></body></html>".utf8)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
            listener.stateUpdateHandler = { [weak listener] state in
                guard !resumed else { return }
                if case .ready = state, let p = listener?.port?.rawValue, p > 0 { resumed = true; cont.resume(returning: p) }
                else if case .failed(let err) = state { resumed = true; cont.resume(throwing: err) }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    private func makeWebHarness() throws -> (URL, WKWebView, NavigationWaiter, AgentBridge, ScriptStore, PageToolBridge, ScriptWebController, SiteToolStateStore) {
        let dir = try makeTempDir()
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = Self.sharedDataStore
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        ForumBrowserModel.disableWebKitScreenTimeForTesting(in: cfg)
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let webView = WKWebView(frame: frame, configuration: cfg)
        let waiter = NavigationWaiter(); webView.navigationDelegate = waiter
        let win = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: frame)
        win.frame = frame
        let vc = UIViewController(); vc.view.frame = frame; vc.view.addSubview(webView)
        win.rootViewController = vc; win.makeKeyAndVisible(); win.layoutIfNeeded()
        windows.append(win)
        let scriptStore = ScriptStore(directoryURL: dir.appendingPathComponent("Scripts", isDirectory: true))
        let stateStore = SiteToolStateStore(directoryURL: dir.appendingPathComponent("SiteTools", isDirectory: true))
        let agentBridge = AgentBridge(webView: webView)
        let pageToolBridge = PageToolBridge(webView: webView, isEnabled: true)
        let controller = ScriptWebController(webView: webView, store: scriptStore, agentBridge: agentBridge, pageToolBridge: pageToolBridge)
        return (dir, webView, waiter, agentBridge, scriptStore, pageToolBridge, controller, stateStore)
    }

    private static let fixtureReaderJS = """
    "use strict";
    const record = (entry) => {
      const list = JSON.parse(document.documentElement.dataset.calls || "[]");
      list.push(entry);
      document.documentElement.dataset.calls = JSON.stringify(list);
    };
    await modelContext.registerTool({
      name: "read_topic", annotations: { readOnlyHint: true },
      execute: async (input) => {
        record({ tool: "read_topic", keys: Object.keys(input).sort(), input });
        const u = new URL(input.url), page = input.page ?? 1;
        if (u.pathname === "/current-only") {
          return { shape: { title: "DOM-Only Thread", url: input.url, total_posts: 1, posts: [{ number: 1, author: "cara", body: "Open document post.", date: "2026-11-15T09:00:00Z" }] }, current_page_only: true };
        }
        if (u.pathname === "/thread-long") {
          const posts = Array.from({ length: 30 }, (_, i) => ({ number: i + 1, author: "user" + (i + 1), body: "Post #" + (i + 1) + " " + "detail ".repeat(45), date: "2026-11-15T10:00:00Z" }));
          return { shape: { title: "Long Architecture Thread", url: input.url, total_posts: 30, posts } };
        }
        if (u.pathname === "/thread-paged") {
          return { shape: { title: "Paged Thread", url: input.url, total_posts: 4, posts: [{ number: (page - 1) * 2 + 1, author: "alice", body: "Page " + page + " first post", date: "2026-11-15T10:00:00Z" }, { number: (page - 1) * 2 + 2, author: "", body: "Deleted user mentions thermal paste", date: "2026-11-15T10:05:00Z" }] }, page, total_pages: 2, next_page: page < 2 ? page + 1 : null };
        }
        return { shape: { title: "Cooling Fan Noise", url: input.url, total_posts: 3, posts: [{ number: 1, author: "alice", body: "My laptop fan spins up on idle.", date: "2026-11-15T10:00:00Z" }, { number: 2, author: "", body: "Check the BIOS curve first.", date: "2026-11-15T10:05:00Z" }, { number: 3, author: "bob", body: "Replacing thermal paste dropped 12C.", date: "2026-11-15T10:10:00Z" }] } };
      }
    });
    await modelContext.registerTool({
      name: "list_latest", annotations: { readOnlyHint: true },
      execute: async (input) => {
        record({ tool: "list_latest", keys: Object.keys(input).sort() });
        return { shape: { items: [{ id: "101", title: "Cooling Fan Noise", url: location.origin + "/thread-1", posts_count: 3, last_activity: "2026-11-15", excerpt: "Fan spins up" }, { title: "Kernel 6.12 Notes", url: location.origin + "/thread-2", posts_count: 8 }] } };
      }
    });
    await modelContext.registerTool({
      name: "search_forum", annotations: { readOnlyHint: true },
      execute: async (input) => {
        record({ tool: "search_forum", keys: Object.keys(input).sort() });
        if (input.query === "nomatch") return { shape: { items: [] }, page: 1, total_pages: 1 };
        return { shape: { items: [{ title: "Cooling Fan Noise", url: location.origin + "/thread-1", hits: [{ number: 3, author: "bob", blurb: "thermal paste dropped 12C" }] }] }, page: input.page ?? 1, total_pages: 2 };
      }
    });
    """

    private func recordedCalls(in bridge: AgentBridge) async throws -> [[String: JSONValue]] {
        let res = try await bridge.runJS(code: "return JSON.parse(document.documentElement.dataset.calls || '[]');", environment: .isolated, timeout: 5)
        return (res.valueJSON?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([[String: JSONValue]].self, from: $0) } ?? []
    }

    func testEnvelopeDecodingAndSiteToolStateStorePersistence() throws {
        let minimalJSON = #"{"shape":{"title":"T","url":"https://example.org/t/1","posts":[{"number":1,"author":"","body":"Hi"}]}}"#
        let minimal = try JSONDecoder().decode(LearnedToolResult<ThreadShape>.self, from: Data(minimalJSON.utf8))
        XCTAssertEqual(minimal.shape.posts.first?.author, "")
        XCTAssertTrue(minimal.page == nil && minimal.totalPages == nil && minimal.nextPage == nil && minimal.currentPageOnly == nil)

        let pagedJSON = #"{"shape":{"items":[{"title":"A","url":"https://example.org/t/1"}]},"page":2,"total_pages":5,"next_page":3,"current_page_only":true}"#
        let paged = try JSONDecoder().decode(LearnedToolResult<ListShape>.self, from: Data(pagedJSON.utf8))
        XCTAssertTrue(paged.page == 2 && paged.totalPages == 5 && paged.nextPage == 3 && paged.currentPageOnly == true)

        let missingAuthor = #"{"shape":{"title":"T","url":"https://example.org/t/1","posts":[{"number":1,"body":"No author key"}]}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LearnedToolResult<ThreadShape>.self, from: Data(missingAuthor.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(LearnedToolResult<ThreadShape>.self, from: Data(#"{"page":1}"#.utf8)))

        let dir = try makeTempDir().appendingPathComponent("SiteTools", isDirectory: true)
        let store = SiteToolStateStore(directoryURL: dir)
        let failDate = ISO8601DateFormatter().date(from: "2026-11-20T08:00:00Z")!
        var state = SiteToolState(host: "WWW.Example.ORG", threadMatch: ["*://example.org/t/*"])
        state.setSlot(SiteSlotState(status: .failed, scriptID: "reader.1", failure: SiteSlotFailure(code: .noPosts, date: failDate, agentReason: "untrusted model note")), for: .readTopic)
        for i in 0..<25 { state.appendLog(SiteLogEntry(kind: .learned, slot: .readTopic, date: failDate.addingTimeInterval(Double(i)), taskID: "t\(i)")) }
        try store.save(state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("example.org.json").path))

        let reloaded = try XCTUnwrap(SiteToolStateStore(directoryURL: dir).state(forURL: URL(string: "https://example.org/t/9")!))
        XCTAssertEqual(reloaded.host, "example.org")
        XCTAssertEqual(reloaded.log.count, 20)
        XCTAssertEqual(reloaded.slot(.readTopic).failure?.sentence, "the tool returned no posts")
        store.forget(host: "www.example.org")
        XCTAssertNil(store.state(forHost: "example.org"))
        XCTAssertNil(SiteToolState.normalizedHost("../escape"))
    }

    func testFourPageContextLinesPrecedenceAndAppTextContainment() throws {
        let page = AgentPageMetadata(url: "https://example.org/thread/1", title: "Thread")
        let failDate = ISO8601DateFormatter().date(from: "2026-11-20T15:30:00Z")!
        let noToolCtx = BrowserAgentPrompt.pageContext(page: page, pageChanged: false, forum: nil, includesForumTools: true)
        XCTAssertTrue(noToolCtx.contains("\n- No reading tool for this site yet.\n"), noToolCtx)

        let enabledScript = UserScript(id: "reader.1", name: "IGNORE ME evil script name", matchRules: ["*://example.org/*"], js: "1;", isEnabled: true)
        let userDisabledScript = UserScript(id: "reader.off", name: "Off Reader", matchRules: ["*://example.org/*"], js: "1;", isEnabled: false, disabledReason: nil)
        let appDisabledScript = UserScript(id: "reader.appoff", name: "App Off", matchRules: ["*://example.org/*"], js: "1;", isEnabled: false, disabledReason: "repair_3")

        var learnedState = SiteToolState(host: "example.org", threadMatch: ["EVIL_MATCH"])
        learnedState.setSlot(SiteSlotState(status: .learned, scriptID: "reader.1", testURLs: ["https://example.org/SECRET_URL"], postStarts: ["u": ["SECRET_POST_START"]]), for: .readTopic)
        let learnedCtx = BrowserAgentPrompt.pageContext(
            page: page, pageChanged: false, forum: nil, includesForumTools: true,
            siteReading: SiteToolState.readingPromptState(state: learnedState, scripts: [enabledScript])
        )
        XCTAssertTrue(learnedCtx.contains("- Reading learned here: `read_topic`, `summarize_topic` and `read_aloud` take a thread URL of this site. `list_latest`: not learned yet."), learnedCtx)

        var failedState = SiteToolState(host: "example.org")
        failedState.setSlot(SiteSlotState(status: .failed, scriptID: "reader.appoff", failure: SiteSlotFailure(code: .noPosts, date: failDate, agentReason: "INJECTED_AGENT_REASON_DO_NOT_SHOW")), for: .readTopic)
        let failedCtx = BrowserAgentPrompt.pageContext(
            page: page, pageChanged: false, forum: nil, includesForumTools: true,
            siteReading: SiteToolState.readingPromptState(state: failedState, scripts: [appDisabledScript])
        )
        XCTAssertTrue(failedCtx.contains("- Learning to read this site failed on 2026-11-20 (the tool returned no posts). Don't try again unless the user asks; use `read_page`."), failedCtx)
        for forbidden in ["INJECTED_AGENT_REASON_DO_NOT_SHOW", "reader.appoff", "App Off", "EVIL_MATCH", "SECRET_URL", "SECRET_POST_START"] {
            XCTAssertFalse(learnedCtx.contains(forbidden), forbidden)
            XCTAssertFalse(failedCtx.contains(forbidden), forbidden)
        }

        var offState = SiteToolState(host: "example.org")
        offState.setSlot(SiteSlotState(status: .learned, scriptID: "reader.off"), for: .readTopic)
        let offCtx = BrowserAgentPrompt.pageContext(
            page: page, pageChanged: false, forum: nil, includesForumTools: true,
            siteReading: SiteToolState.readingPromptState(state: offState, scripts: [userDisabledScript])
        )
        XCTAssertTrue(offCtx.contains("- The reading tool for this site is turned off in This page. Don't learn it again or turn it on; use `read_page`."), offCtx)

        var failedAndLearned = learnedState
        failedAndLearned.setSlot(SiteSlotState(status: .failed, failure: SiteSlotFailure(code: .noPosts, date: failDate)), for: .listLatest)
        XCTAssertEqual(SiteToolState.readingPromptState(state: failedAndLearned, scripts: [enabledScript]), .failed(date: failDate, code: .noPosts))

        var offAndFailed = failedAndLearned
        offAndFailed.setSlot(SiteSlotState(status: .failed, scriptID: "reader.off", failure: SiteSlotFailure(code: .threw, date: failDate)), for: .searchForum)
        XCTAssertEqual(SiteToolState.readingPromptState(state: offAndFailed, scripts: [enabledScript, userDisabledScript]), .turnedOff)

        let adapter = try XCTUnwrap(SiteRegistry.standard.adapter(for: .discourse))
        let builtIn = ForumPromptContext(forumName: "Meta", siteURL: "https://meta.discourse.org", adapter: adapter, maxTopicReads: 5)
        let builtInVsOff = BrowserAgentPrompt.pageContext(page: page, pageChanged: false, forum: builtIn, includesForumTools: true, siteReading: .turnedOff)
        XCTAssertTrue(builtInVsOff.contains("- Forum: you are on Meta") && !builtInVsOff.contains("turned off in This page"))
        XCTAssertEqual(SiteToolState.readingPromptState(state: learnedState, scripts: []), .none)
        XCTAssertEqual(SiteToolState.readingPromptState(state: learnedState, scripts: [enabledScript], pageToolsEnabled: false), .none)
    }

    func testLearnedSlotsRenderingLongThreadWorkspaceSaveAndGuards() async throws {
        let base = try await startFixtureForum()
        let (dir, webView, waiter, agentBridge, scriptStore, pageToolBridge, controller, stateStore) = try makeWebHarness()
        defer { controller.detach(); pageToolBridge.detach() }

        let script = try scriptStore.create(id: "reader.fixture", name: "Fixture Reader", matchRules: ["*://127.0.0.1/*"], js: Self.fixtureReaderJS, source: .agent(userPrompt: "learn"))
        controller.syncUserScripts()
        try await waiter.load(webView, url: base.appendingPathComponent("current-only"))
        try await Task.sleep(nanoseconds: 80_000_000)

        var state = SiteToolState(host: "127.0.0.1")
        for slot in SiteToolSlot.allCases { state.setSlot(SiteSlotState(status: .learned, scriptID: script.id), for: slot) }
        try stateStore.save(state)

        let workspace = AgentWorkspace(root: dir.appendingPathComponent("Workspace", isDirectory: true))
        let scope = LearnedRunScope(maxTopicReads: 3, readLimit: 1_200)
        let learned = LearnedSiteContext(host: "127.0.0.1", state: state, pageToolBridge: pageToolBridge, scriptStore: scriptStore, scope: scope)
        var registry = ToolRegistry.m3(context: AgentToolContext(bridge: agentBridge, workspace: workspace, scriptStore: scriptStore, settings: AgentToolSettings(truncationLimit: 1_200), learnedSite: learned))
        registry.taskID = "task-42"

        let searchDef = try XCTUnwrap(registry.tool(named: "search_forum")?.definition)
        let listDef = try XCTUnwrap(registry.tool(named: "list_latest")?.definition)
        XCTAssertTrue(searchDef.description.contains("a site the page context says can be read") && !searchDef.description.contains("Discourse"))
        XCTAssertTrue(listDef.description.contains("a site the page context says can be read"))

        let threadURL = base.appendingPathComponent("thread-1").absoluteString
        let shortRead = try await registry.dispatch(toolName: "read_topic", arguments: ["url": .string(threadURL)], step: 1)
        XCTAssertFalse(shortRead.isError, shortRead.output)
        XCTAssertTrue(shortRead.output.contains("Topic: Cooling Fan Noise\nURL: \(threadURL)"))
        XCTAssertTrue(shortRead.output.contains("alice | 2026-11-15 10:00:00 UTC | #1\nMy laptop fan spins up on idle."))
        XCTAssertTrue(shortRead.output.contains("anonymous | 2026-11-15 10:05:00 UTC | #2\nCheck the BIOS curve first."))
        XCTAssertTrue(shortRead.modelContent.contains("<untrusted_web_content tool=\"read_topic\">"))
        guard case .thread(let threadShape)? = shortRead.shape else { return XCTFail("expected ThreadShape") }
        XCTAssertTrue(threadShape.posts.count == 3 && threadShape.posts[1].author.isEmpty)

        let queried = try await registry.dispatch(toolName: "read_topic", arguments: ["url": .string(threadURL), "query": .string("thermal paste"), "topic_id": .string("ignored")], step: 2)
        XCTAssertTrue(!queried.isError && queried.output.contains("Showing: 1 matching post for \"thermal paste\" (of 3 posts), best matches first"))
        XCTAssertTrue(queried.output.contains("bob | 2026-11-15 10:10:00 UTC | #3") && !queried.output.contains("Check the BIOS curve first."))
        XCTAssertEqual(queried.notes, [.queryInTopic(topic: "thread")])
        let callsAfterQuery = try await recordedCalls(in: agentBridge)
        XCTAssertEqual(callsAfterQuery.last?["keys"], .array([.string("url")]))

        let longURL = base.appendingPathComponent("thread-long").absoluteString
        let longRead = try await registry.dispatch(toolName: "read_topic", arguments: ["url": .string(longURL)], step: 3)
        let savedPath = try XCTUnwrap(longRead.savedPath)
        XCTAssertTrue(!longRead.isError && savedPath.hasPrefix("results/task-42/") && longRead.output.contains("Full thread: 30 posts") && longRead.notes.contains(.readSavedFile))
        let savedText = try await workspace.read(path: savedPath, offset: 0, length: 20_000).text
        XCTAssertTrue(savedText.contains("user30 | 2026-11-15 10:00:00 UTC | #30"))

        let currentOK = try await registry.dispatch(toolName: "read_topic", arguments: ["url": .string(base.appendingPathComponent("current-only").absoluteString + "#post-1")], step: 4)
        XCTAssertFalse(currentOK.isError, currentOK.output)

        let countBeforeBudget = try await recordedCalls(in: agentBridge).count
        let overBudget = try await registry.dispatch(toolName: "read_topic", arguments: ["url": .string(base.appendingPathComponent("thread-4").absoluteString)], step: 5)
        XCTAssertTrue(overBudget.isError && overBudget.output.contains("topic-read budget (3)"))
        let countAfterBudget = try await recordedCalls(in: agentBridge).count
        XCTAssertEqual(countAfterBudget, countBeforeBudget)

        scope.readURLs.removeAll()
        try await waiter.load(webView, url: base.appendingPathComponent("other-page"))
        try await Task.sleep(nanoseconds: 80_000_000)
        let currentRefused = try await registry.dispatch(toolName: "read_topic", arguments: ["url": .string(base.appendingPathComponent("current-only").absoluteString)])
        XCTAssertTrue(currentRefused.isError && currentRefused.output.contains("open that thread first"))

        let pagedURL = base.appendingPathComponent("thread-paged").absoluteString
        let page2 = try await registry.dispatch(toolName: "read_topic", arguments: ["url": .string(pagedURL), "page": .int(2)])
        XCTAssertTrue(!page2.isError && page2.output.contains("Showing: page 2 of 2"))
        let page3 = try await registry.dispatch(toolName: "read_topic", arguments: ["url": .string(pagedURL), "page": .int(3)])
        XCTAssertTrue(page3.isError && page3.output.lowercased().contains("no such page"))

        let callsBeforeGuards = try await recordedCalls(in: agentBridge).count
        for badURL in ["https://evil.example/thread-1", "ftp://127.0.0.1/thread-1", "javascript:alert(1)", "file:///etc/passwd", "http://user:pass@127.0.0.1/thread-1", "/thread-1"] {
            let refused = try await registry.dispatch(toolName: "read_topic", arguments: ["url": .string(badURL)])
            XCTAssertTrue(refused.isError && refused.output.contains("that address is not on this site"), badURL)
        }
        let topicIDOnly = try await registry.dispatch(toolName: "read_topic", arguments: ["topic_id": .string("42")])
        XCTAssertTrue(topicIDOnly.isError && topicIDOnly.output.contains("this site has no thread ids; pass the thread's URL"))
        for unsupported in [["query": JSONValue.string("fan"), "category": .string("hw")], ["query": .string("fan"), "after": .string("2026-01-01")], ["query": .string("fan"), "before": .string("2026-12-31")]] {
            let refused = try await registry.dispatch(toolName: "search_forum", arguments: unsupported)
            XCTAssertTrue(refused.isError && refused.output.contains("not supported on this site: search with the query only"))
        }
        let commentsRefused = try await registry.dispatch(toolName: "search_comments", arguments: ["query": .string("fan")])
        XCTAssertTrue(commentsRefused.isError && commentsRefused.output.contains("No reading tool for this site yet."))
        let callsAfterGuards = try await recordedCalls(in: agentBridge).count
        XCTAssertEqual(callsAfterGuards, callsBeforeGuards)

        let latest = try await registry.dispatch(toolName: "list_latest", arguments: [:])
        XCTAssertTrue(!latest.isError && latest.output.contains("- id 101: Cooling Fan Noise — 3 posts, last activity 2026-11-15") && latest.notes == [.latestList(topic: "thread")])

        let searched = try await registry.dispatch(toolName: "search_forum", arguments: ["query": .string("paste"), "category": .string("")])
        XCTAssertTrue(!searched.isError && searched.output.contains("#3 @bob: thermal paste dropped 12C"))
        let callsAfterSearch = try await recordedCalls(in: agentBridge)
        XCTAssertEqual(callsAfterSearch.last?["keys"], .array([.string("query")]))

        let emptySearch = try await registry.dispatch(toolName: "search_forum", arguments: ["query": .string("nomatch")])
        XCTAssertTrue(!emptySearch.isError && emptySearch.output == "No topics found.")

        let badSearchPage = try await registry.dispatch(toolName: "search_forum", arguments: ["query": .string("paste"), "page": .int(5)])
        XCTAssertTrue(badSearchPage.isError && badSearchPage.output.lowercased().contains("no such page"))

        let voiceReg = ToolRegistry.m3(context: AgentToolContext(bridge: agentBridge, workspace: workspace, scriptStore: scriptStore, learnedSite: learned), surface: .voice)
        let voiceRefused = try await voiceReg.dispatch(toolName: "read_topic", arguments: ["url": .string(threadURL)])
        XCTAssertTrue(voiceRefused.output.contains("isn't a forum"))

        _ = try scriptStore.setEnabled(id: script.id, isEnabled: false)
        let userOffRefusal = try await registry.dispatch(toolName: "read_topic", arguments: ["url": .string(threadURL)])
        XCTAssertTrue(userOffRefusal.isError && userOffRefusal.output.contains("turned off in This page"))
        _ = try scriptStore.setEnabled(id: script.id, isEnabled: true)

        pageToolBridge.isEnabled = false
        let unknownReg = ToolRegistry.m3(context: AgentToolContext(bridge: agentBridge, workspace: workspace, scriptStore: scriptStore))
        for (tool, args) in [("read_topic", ["url": JSONValue.string(threadURL)]), ("list_latest", [:]), ("search_forum", ["query": .string("x")])] {
            let switchedOff = try await registry.dispatch(toolName: tool, arguments: args)
            let unknown = try await unknownReg.dispatch(toolName: tool, arguments: args)
            XCTAssertTrue(switchedOff.isError && switchedOff.output == unknown.output)
        }
    }

    func testAppModelBuilderPrecedenceSwitchAndBudget() async throws {
        let dir = try makeTempDir()
        let store = PersistentStore(fileURL: dir.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let app = AppModel(
            store: store, forumService: WordPressFixtureSite(commentCount: 1).service(),
            sites: SiteRegistry.standard, aiService: StateAIStub(),
            workspaceDirectory: dir.appendingPathComponent("ws", isDirectory: true)
        )
        app.browser.onPageContextChanged = nil
        let script = try app.scriptStore.create(id: "reader.meta", name: "Reader", matchRules: ["*://meta.discourse.org/*", "*://example.org/*"], js: "1;", source: .imported)
        for host in ["meta.discourse.org", "www.example.org"] {
            var st = SiteToolState(host: host); st.setSlot(SiteSlotState(status: .learned, scriptID: script.id), for: .readTopic)
            try app.siteToolStateStore.save(st)
        }

        app.browser.setPageContext(PageContext(url: URL(string: "https://meta.discourse.org/t/slug/1"), site: .discourse, siteURL: "https://meta.discourse.org", forumName: "Meta", state: .topic))
        XCTAssertNotNil(app.makeForumToolContext())
        XCTAssertNil(app.makeLearnedSiteContext())

        app.settings.agentMaxTopicReads = 2
        app.browser.setPageContext(PageContext(url: URL(string: "https://www.example.org/thread/1"), state: .notForum))
        let learned = try XCTUnwrap(app.makeLearnedSiteContext())
        XCTAssertTrue(learned.host == "example.org" && learned.scope.readBudget() == 2)
        XCTAssertEqual(learned.promptState.pageContextLine, "- Reading learned here: `read_topic`, `summarize_topic` and `read_aloud` take a thread URL of this site. `list_latest`: not learned yet.")

        let client = RecordedModelClient([.success(AgentModelTurnResponse(text: "Done."))])
        let driver = FixturePageDriver(page: .init(url: "https://www.example.org/thread/1", title: "Thread 1", structure: "main", text: "Hi"))
        let runtimeCfg = BrowserAgentRuntimeConfig(
            selection: ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
            configuration: ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake-key"),
            maxSteps: 3, truncationLimit: 20_000, customInstructions: "", redactedSecrets: []
        )
        let session = BrowserAgentSession(
            pageDriver: driver, modelClient: client,
            configProvider: { runtimeCfg },
            registryBuilder: { [unowned app] bridge, limit, secrets in
                ToolRegistry.m3(context: AgentToolContext(bridge: bridge, workspace: app.agentWorkspace, scriptStore: app.scriptStore, settings: AgentToolSettings(truncationLimit: limit, redactedSecrets: secrets), learnedSite: app.makeLearnedSiteContext()))
            }
        )
        await session.sendAndWait("Summarize")
        guard case .user(let turn)? = client.recordedRequests.first?.messages.last else { return XCTFail("missing turn") }
        XCTAssertTrue(turn.contains("- Reading learned here: `read_topic`, `summarize_topic` and `read_aloud` take a thread URL of this site. `list_latest`: not learned yet."), turn)

        app.settings.agentPageToolsEnabled = false
        XCTAssertNil(app.makeLearnedSiteContext())
    }
}
