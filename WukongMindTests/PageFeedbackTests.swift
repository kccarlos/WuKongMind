import Foundation
import Network
import UIKit
import WebKit
import XCTest
@testable import WukongMind

/// Page feedback (docs/wukongmind/page-feedback.md "How" 1 to 3): the rules
/// on their own, then real `WKWebView` snapshots on local fixture HTML
/// through the `run_js` and `inject_css` tools.
@MainActor
final class PageFeedbackTests: XCTestCase {
    // MARK: - Rules (no web view)

    private func snapshot(
        url: String = "https://fixture.local/page",
        text: Int = 5_000,
        height: Int = 4_000,
        scrollable: Bool = true,
        links: Int = 20,
        controls: Int = 6,
        images: Int = 3,
        errors: Int = 0
    ) -> PageStateSnapshot {
        PageStateSnapshot(
            url: url,
            textLength: text,
            documentHeight: height,
            isScrollable: scrollable,
            linkCount: links,
            formControlCount: controls,
            visibleImageCount: images,
            pageErrorCount: errors
        )
    }

    func testEachRuleMatchesOnItsOwn() {
        let before = snapshot()
        XCTAssertEqual(
            PageFeedbackRules.reasons(before: before, after: snapshot(text: 2_400)),
            ["visible text dropped from 5,000 to 2,400 characters"]
        )
        XCTAssertEqual(
            PageFeedbackRules.reasons(before: before, after: snapshot(height: 1_999)),
            ["page height dropped from 4,000 to 1,999"]
        )
        XCTAssertEqual(
            PageFeedbackRules.reasons(before: before, after: snapshot(scrollable: false)),
            ["the page can no longer scroll"]
        )
        XCTAssertEqual(
            PageFeedbackRules.reasons(before: before, after: snapshot(links: 9)),
            ["links dropped from 20 to 9"]
        )
        XCTAssertEqual(
            PageFeedbackRules.reasons(before: before, after: snapshot(controls: 2)),
            ["form controls dropped from 6 to 2"]
        )
        XCTAssertEqual(
            PageFeedbackRules.reasons(before: before, after: snapshot(errors: 1)),
            ["a new page error appeared"]
        )
        XCTAssertEqual(
            PageFeedbackRules.reasons(before: before, after: snapshot(errors: 3)),
            ["3 new page errors appeared"]
        )
    }

    func testExactlyHalfAndSmallPagesDoNotWarn() {
        let before = snapshot()
        XCTAssertEqual(
            PageFeedbackRules.reasons(
                before: before,
                after: snapshot(text: 2_500, height: 2_000, links: 10, controls: 3)
            ),
            []
        )
        // One link removed from a page with one link: below the minimum.
        XCTAssertEqual(
            PageFeedbackRules.reasons(before: snapshot(text: 20, links: 1), after: snapshot(text: 0, links: 0)),
            []
        )
        // More text, a taller page, an image less: no warning.
        XCTAssertEqual(
            PageFeedbackRules.reasons(before: before, after: snapshot(text: 9_000, height: 9_000, images: 0)),
            []
        )
    }

    func testChangesLineListsOnlyChangedValuesWithGrouping() {
        let report = PageFeedbackRules.compare(
            before: snapshot(text: 12_400, height: 8_200),
            after: snapshot(text: 310, height: 900, scrollable: false)
        )
        XCTAssertEqual(
            report.changesLine,
            "Page changes: text 12,400 → 310; height 8,200 → 900; scrollable yes → no"
        )
        XCTAssertEqual(
            report.warningLine,
            "The page may be broken: visible text dropped from 12,400 to 310 characters; "
                + "page height dropped from 8,200 to 900; the page can no longer scroll."
        )
        XCTAssertEqual(PageFeedbackRules.format(1_234_567), "1,234,567")
        XCTAssertEqual(PageFeedbackRules.format(999), "999")
    }

    func testNoChangeAddsOneLineAndURLChangeSkipsTheComparison() {
        let unchanged = PageFeedbackRules.compare(before: snapshot(), after: snapshot())
        XCTAssertNil(unchanged.warningLine)
        XCTAssertEqual(unchanged.decorate("true"), "true", "the lines are tool notes now")
        XCTAssertEqual(ToolNote.pageFeedback(unchanged).map(\.text), ["Page changes: none"])

        let moved = PageFeedbackRules.compare(
            before: snapshot(),
            after: snapshot(url: "https://fixture.local/other", text: 0, links: 0)
        )
        XCTAssertTrue(moved.urlChanged)
        XCTAssertTrue(moved.reasons.isEmpty)
        XCTAssertEqual(
            moved.changesLine,
            "Page changes: not compared, the page address changed to https://fixture.local/other."
        )
        // The trusted note only names the change; the page-controlled URL stays in the wrapped output.
        XCTAssertFalse(ToolNote.pageFeedback(moved).map(\.text).joined().contains("fixture.local"))
        XCTAssertEqual(moved.decorate("true"), "true\n\nNew page address: https://fixture.local/other")

        let unreadable = PageFeedbackRules.compare(before: snapshot(), after: nil)
        XCTAssertTrue(unreadable.reasons.isEmpty)
        XCTAssertTrue(unreadable.changesLine.contains("couldn't be read"))
    }

    func testFeedbackLinesAreAddedAfterTruncation() async throws {
        let feedback = PageFeedbackRules.compare(before: snapshot(), after: snapshot(text: 10))
        let tool = AgentTool(
            definition: AgentToolDefinition(name: "big_change", description: "test", parameters: [], required: []),
            summarizeArguments: { _ in "" },
            execute: { _ in
                ToolExecutionOutput(content: String(repeating: "x", count: 500), summary: "done", pageFeedback: feedback)
            }
        )
        let registry = ToolRegistry(tools: [tool], truncationLimit: 100)
        let result = try await registry.dispatch(toolName: "big_change", arguments: [:])
        XCTAssertTrue(result.wasTruncated)
        XCTAssertTrue(result.notes.first?.text.hasPrefix("The page may be broken: visible text dropped") == true)
        XCTAssertEqual(result.notes.last?.text, "Page changes: text 5,000 → 10")
        XCTAssertTrue(result.output.contains("[truncated, 500 characters in total]"))
        XCTAssertTrue(result.modelContent.hasPrefix("\(ToolNote.label) The page may be broken"))
        XCTAssertTrue(result.resultSummary.hasPrefix("Page may be broken"))
        XCTAssertFalse(result.isError, "A warning is not an error")
        XCTAssertEqual(result.pageFeedback, feedback)
    }

    // MARK: - Real pages

    private var activeWindows: [UIWindow] = []
    private var activeBrowsers: [ForumBrowserModel] = []
    private var activeControllers: [ScriptWebController] = []
    private var activeServers: [ArticleFixtureServer] = []
    private var tempDirectories: [URL] = []

    override func tearDown() async throws {
        for controller in activeControllers {
            controller.detach()
        }
        activeControllers.removeAll()
        for browser in activeBrowsers {
            browser.stopLoading()
        }
        activeBrowsers.removeAll()
        for window in activeWindows {
            window.isHidden = true
            window.rootViewController = nil
        }
        activeWindows.removeAll()
        for server in activeServers {
            server.stop()
        }
        activeServers.removeAll()
        for dir in tempDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirectories.removeAll()
        try await super.tearDown()
    }

    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Never>?

        func load(_ html: String, in webView: WKWebView) async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.local/page"))
            }
        }

        private func finish() {
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) { finish() }
    }

    /// A hosted 390×844 web view (layout needs a window) showing `html`.
    private func makePage(_ html: String) async -> (AgentBridge, ToolRegistry, LoadWaiter) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        ForumBrowserModel.disableWebKitScreenTimeForTesting(in: config)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        let bridge = AgentBridge(webView: webView)
        let waiter = LoadWaiter()
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
        activeWindows.append(window)

        await waiter.load(html, in: webView)
        return (bridge, ToolRegistry.m1(bridge: bridge), waiter)
    }

    private static let paragraph = String(
        repeating: "Fixture paragraph text that the reader came to see on this page. ",
        count: 20
    )

    /// A tall article: plenty of text, ten links, four form controls, and a
    /// page-world button whose click handler throws.
    private static let articleHTML = """
    <!doctype html>
    <html><head><meta name="viewport" content="width=device-width"><title>Fixture</title></head>
    <body>
      <main id="article">
        <h1>Fixture article</h1>
        <p id="text">\(paragraph)</p>
        <nav id="links">
          \((1...10).map { "<a href=\"/p/\($0)\">L\($0)</a>" }.joined(separator: " "))
        </nav>
        <form><input name="q"><input name="r"><select><option>a</option></select><textarea></textarea></form>
        <button id="boom" type="button">Boom</button>
        <div id="spacer" style="height: 4000px"></div>
      </main>
      <script>
        document.getElementById('boom').addEventListener('click', () => {
          throw new Error('fixture page error');
        });
      </script>
    </body></html>
    """

    private func runJS(_ code: String, on registry: ToolRegistry) async throws -> ToolDispatchResult {
        try await registry.dispatch(toolName: "run_js", arguments: ["code": .string(code)])
    }

    func testSnapshotReadsTheSevenNumbers() async throws {
        let (bridge, _, _) = await makePage(Self.articleHTML)
        let taken = await bridge.pageSnapshot()
        let snapshot = try XCTUnwrap(taken)
        XCTAssertEqual(snapshot.url, "https://fixture.local/page")
        XCTAssertGreaterThan(snapshot.textLength, 1_000)
        XCTAssertGreaterThan(snapshot.documentHeight, 4_000)
        XCTAssertTrue(snapshot.isScrollable)
        XCTAssertEqual(snapshot.linkCount, 10)
        XCTAssertEqual(snapshot.formControlCount, 5)
        XCTAssertEqual(snapshot.visibleImageCount, 0)
        XCTAssertEqual(snapshot.pageErrorCount, 0)
    }

    func testEmptyingTheBodyWarns() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let result = try await runJS("document.body.innerHTML = ''; return 'emptied';", on: registry)
        let warning = result.notes.first?.text ?? ""
        XCTAssertTrue(warning.hasPrefix("The page may be broken: "), warning)
        XCTAssertTrue(warning.contains("visible text dropped"), warning)
        XCTAssertTrue(warning.contains("links dropped from 10 to 0"), warning)
        XCTAssertEqual(result.output, "\"emptied\"")
        XCTAssertEqual(result.notes.last?.text, result.pageFeedback?.changesLine)
        XCTAssertTrue(result.modelContent.hasPrefix("\(ToolNote.label) The page may be broken"))
    }

    func testHalvingTheHeightWarns() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let result = try await runJS("document.getElementById('spacer').style.height = '200px';", on: registry)
        XCTAssertEqual(result.pageFeedback?.reasons.count, 1, result.output)
        XCTAssertTrue(result.notes.first?.text.hasPrefix("The page may be broken: page height dropped from ") == true, result.output)
    }

    func testMakingThePageUnscrollableWarns() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let result = try await registry.dispatch(
            toolName: "inject_css",
            arguments: ["css": .string("html, body { overflow: hidden !important; }")]
        )
        XCTAssertEqual(result.pageFeedback?.reasons, ["the page can no longer scroll"], result.output)
        XCTAssertEqual(result.notes.first?.text, "The page may be broken: the page can no longer scroll.")
        // The body becomes its own formatting context, so the height can move a few points.
        XCTAssertTrue(result.notes.last?.text.contains("scrollable yes → no") == true, result.output)
    }

    func testRemovingTheLinksWarns() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let result = try await runJS(
            """
            for (const a of Array.from(document.querySelectorAll('a'))) {
              const span = document.createElement('span');
              span.textContent = a.textContent;
              a.replaceWith(span);
            }
            """,
            on: registry
        )
        XCTAssertEqual(result.pageFeedback?.reasons, ["links dropped from 10 to 0"], result.output)
        XCTAssertEqual(result.notes.first?.text, "The page may be broken: links dropped from 10 to 0.")
    }

    func testAPageErrorWarns() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let result = try await runJS("document.getElementById('boom').click(); return 'clicked';", on: registry)
        XCTAssertEqual(result.pageFeedback?.reasons, ["a new page error appeared"], result.output)
        XCTAssertEqual(result.notes.last?.text, "Page changes: page errors 0 → 1", result.output)
    }

    func testAChangeThatAltersNothingAddsOneLine() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let read = try await runJS("return document.title;", on: registry)
        XCTAssertEqual(read.output, "\"Fixture\"")
        XCTAssertEqual(read.notes.map(\.text), ["Page changes: none"])

        let css = try await registry.dispatch(
            toolName: "inject_css",
            arguments: ["css": .string("h1 { color: rgb(200, 0, 0); }")]
        )
        XCTAssertEqual(css.output.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 1, css.output)
        XCTAssertEqual(css.notes.map(\.text), ["Page changes: none"])
    }

    func testAScriptErrorStillReportsWhatChanged() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let result = try await runJS("document.body.innerHTML = ''; throw new Error('half done');", on: registry)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.notes.first?.text.hasPrefix("The page may be broken: ") == true, result.output)
        XCTAssertTrue(result.output.contains("half done"))
    }

    func testReadOnlyToolsTakeNoSnapshot() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let result = try await registry.dispatch(toolName: "read_page", arguments: ["mode": .string("text")])
        XCTAssertNil(result.pageFeedback)
        XCTAssertFalse(result.output.contains("Page changes"))
        XCTAssertEqual(result.notes, [])
    }

    // MARK: - Verify before saving & recorded replay (M3 Task 4)

    private final class ArticleFixtureServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "PageFeedbackTests.ArticleFixtureServer")
        private let htmlData: Data
        private(set) var port: UInt16 = 0

        init(html: String) throws {
            self.htmlData = Data(html.utf8)
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            self.listener = try NWListener(using: params)
        }

        var articleURL: URL { URL(string: "http://127.0.0.1:\(port)/article")! }

        func start() async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                nonisolated(unsafe) var resumed = false
                listener.stateUpdateHandler = { [weak self] state in
                    guard !resumed, let self else { return }
                    if case .ready = state {
                        resumed = true; self.port = self.listener.port?.rawValue ?? 0; cont.resume()
                    } else if case .failed(let err) = state {
                        resumed = true; cont.resume(throwing: err)
                    }
                }
                listener.newConnectionHandler = { [htmlData, queue] conn in
                    conn.start(queue: queue)
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(htmlData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                        conn.send(content: Data(head.utf8) + htmlData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() { listener.cancel() }
    }

    private func makeVerifiedBrowserHarness(
        baseline: (@MainActor @Sendable () -> PageStateSnapshot?)? = nil,
        baselineImage: (@MainActor @Sendable () -> AgentImage?)? = nil,
        supportsImageInput: Bool = false
    ) async throws -> (ForumBrowserModel, ScriptStore, ScriptWebController, ToolRegistry, URL) {
        let server = try ArticleFixtureServer(html: Self.articleHTML)
        try await server.start()
        activeServers.append(server)

        let browser = ForumBrowserModel(contentRules: ContentRuleLibrary(store: nil, directory: nil), websiteDataStore: .nonPersistent())
        activeBrowsers.append(browser)

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let vc = UIViewController()
        vc.view.frame = window.bounds
        vc.view.addSubview(browser.webView)
        browser.webView.frame = vc.view.bounds
        window.rootViewController = vc
        window.makeKeyAndVisible()
        activeWindows.append(window)

        let scriptsDir = FileManager.default.temporaryDirectory.appendingPathComponent("PageFeedbackTests-\(UUID().uuidString)", isDirectory: true)
        tempDirectories.append(scriptsDir)
        let store = ScriptStore(directoryURL: scriptsDir)
        let controller = ScriptWebController(webView: browser.webView, store: store, agentBridge: browser.agentBridge)
        activeControllers.append(controller)

        let registry = ToolRegistry.m3(context: AgentToolContext(
            bridge: browser.agentBridge, workspace: nil, scriptStore: store,
            liveApplier: controller, currentUserPrompt: { "Test prompt" },
            pageBaseline: baseline, pageBaselineImage: baselineImage,
            settings: AgentToolSettings(supportsImageInput: supportsImageInput)
        ))
        let openResult = try await registry.dispatch(toolName: "navigate", arguments: ["url": .string(server.articleURL.absoluteString)])
        XCTAssertFalse(openResult.isError, openResult.output)
        return (browser, store, controller, registry, server.articleURL)
    }

    func testFailedVerifyCarriesBothImagesForImageModelAndNoneForTextModel() async throws {
        let (_, _, _, visionRegistry, _) = try await makeVerifiedBrowserHarness(supportsImageInput: true)
        let refusedWarning = try await visionRegistry.dispatch(toolName: "script_save", arguments: [
            "name": .string("Empty Vision"),
            "match_rules": .array([.string("*://127.0.0.1/*")]),
            "css": .string("main { display: none !important; }")
        ])
        XCTAssertTrue(refusedWarning.isError, refusedWarning.output)
        XCTAssertEqual(refusedWarning.images.count, 2, "Failed verify on an image model carries before and after screenshots")
        XCTAssertTrue(refusedWarning.images.allSatisfy { $0.mediaType == "image/jpeg" && !$0.data.isEmpty })

        let refusedThrow = try await visionRegistry.dispatch(toolName: "script_save", arguments: [
            "name": .string("Throw Vision"),
            "match_rules": .array([.string("*://127.0.0.1/*")]),
            "js": .string("throw new Error('vision runtime crash');")
        ])
        XCTAssertTrue(refusedThrow.isError, refusedThrow.output)
        XCTAssertEqual(refusedThrow.images.count, 2, "Runtime-error verify refusal on an image model also carries both screenshots")

        let (_, _, _, textRegistry, _) = try await makeVerifiedBrowserHarness(supportsImageInput: false)
        let refusedTextOnly = try await textRegistry.dispatch(toolName: "script_save", arguments: [
            "name": .string("Empty Text Only"),
            "match_rules": .array([.string("*://127.0.0.1/*")]),
            "css": .string("main { display: none !important; }")
        ])
        XCTAssertTrue(refusedTextOnly.isError, refusedTextOnly.output)
        XCTAssertTrue(refusedTextOnly.images.isEmpty, "Text-only models receive no screenshots on failed verify")
    }

    func testSavingAScriptThatThrowsIsRefusedEvenWithConfirmChange() async throws {
        let (_, store, _, registry, _) = try await makeVerifiedBrowserHarness()

        let syncThrow = try await registry.dispatch(toolName: "script_save", arguments: [
            "name": .string("Sync Crash"),
            "match_rules": .array([.string("*://127.0.0.1/*")]),
            "js": .string("throw new Error('selector blew up');")
        ])
        XCTAssertTrue(syncThrow.isError, syncThrow.output)
        XCTAssertTrue(syncThrow.output.hasPrefix("Error: Not saved: runtime error:"), syncThrow.output)
        XCTAssertTrue(syncThrow.output.contains("selector blew up"), syncThrow.output)
        XCTAssertFalse(syncThrow.output.contains("confirm_change: true"))
        XCTAssertTrue(store.scripts.isEmpty)
        XCTAssertTrue(store.scriptErrors.isEmpty)

        let confirmedAsyncThrow = try await registry.dispatch(toolName: "script_save", arguments: [
            "name": .string("Async Crash"),
            "match_rules": .array([.string("*://127.0.0.1/*")]),
            "js": .string("await Promise.resolve(); throw new Error('async explosion');"),
            "environment": .string("page"),
            "confirm_change": .bool(true)
        ])
        XCTAssertTrue(confirmedAsyncThrow.isError, confirmedAsyncThrow.output)
        XCTAssertTrue(confirmedAsyncThrow.output.contains("async explosion"), confirmedAsyncThrow.output)
        XCTAssertTrue(store.scripts.isEmpty)
    }

    func testScriptThatEmptiesPageIsRefusedThenSavedWithConfirmChangeAndUnmatchedSavesUnverified() async throws {
        let (_, store, _, registry, _) = try await makeVerifiedBrowserHarness()

        let refused = try await registry.dispatch(toolName: "script_save", arguments: [
            "name": .string("Empty Everything"),
            "match_rules": .array([.string("*://127.0.0.1/*")]),
            "css": .string("main { display: none !important; }")
        ])
        XCTAssertTrue(refused.isError, refused.output)
        XCTAssertTrue(refused.output.hasPrefix("Error: Not saved: "), refused.output)
        XCTAssertTrue(refused.output.contains("visible text dropped"), refused.output)
        XCTAssertTrue(refused.output.hasSuffix("If this change is what the user asked for, call again with confirm_change: true."), refused.output)
        XCTAssertTrue(store.scripts.isEmpty)

        let confirmed = try await registry.dispatch(toolName: "script_save", arguments: [
            "name": .string("Empty Everything"),
            "match_rules": .array([.string("*://127.0.0.1/*")]),
            "css": .string("main { display: none !important; }"),
            "confirm_change": .bool(true)
        ])
        XCTAssertFalse(confirmed.isError, confirmed.output)
        let savedJSON = try JSONValue.parseObjectJSON(confirmed.output)
        let scriptID = try XCTUnwrap(savedJSON["script_id"]?.stringValue)
        XCTAssertEqual(savedJSON["verified"], .bool(true))
        XCTAssertEqual(store.scripts.count, 1)

        let safeUpdate = try await registry.dispatch(toolName: "script_update", arguments: [
            "script_id": .string(scriptID), "css": .string("h1 { color: rgb(20, 40, 80); }")
        ])
        XCTAssertFalse(safeUpdate.isError, safeUpdate.output)
        _ = try await registry.dispatch(toolName: "reload_page", arguments: [:])

        let refusedUpdate = try await registry.dispatch(toolName: "script_update", arguments: [
            "script_id": .string(scriptID), "js": .string("document.body.innerHTML = '';")
        ])
        XCTAssertTrue(refusedUpdate.isError, refusedUpdate.output)
        XCTAssertEqual(store.script(id: scriptID)?.version, 2)

        let confirmedUpdate = try await registry.dispatch(toolName: "script_update", arguments: [
            "script_id": .string(scriptID), "js": .string("document.body.innerHTML = '';"), "confirm_change": .bool(true)
        ])
        XCTAssertFalse(confirmedUpdate.isError, confirmedUpdate.output)
        XCTAssertEqual(store.script(id: scriptID)?.version, 3)

        let unverified = try await registry.dispatch(toolName: "script_save", arguments: [
            "name": .string("Other Domain Reader"),
            "match_rules": .array([.string("https://other.example.org/*")]),
            "css": .string("aside { display: none; }")
        ])
        XCTAssertFalse(unverified.isError, unverified.output)
        let unverifiedJSON = try JSONValue.parseObjectJSON(unverified.output)
        XCTAssertEqual(unverifiedJSON["verified"], .bool(false))
        XCTAssertEqual(unverifiedJSON["applied_to_current_page"], .bool(false))
        XCTAssertTrue(unverifiedJSON["verification_note"]?.stringValue?.contains("do not cover the current page") == true)
    }

    func testRefusedSaveRestoresPageAndRefusesRepeatedUnconfirmedRetry() async throws {
        let (browser, store, _, registry, _) = try await makeVerifiedBrowserHarness()

        let firstRefused = try await registry.dispatch(toolName: "script_save", arguments: [
            "name": .string("Empty Retry Check"),
            "match_rules": .array([.string("*://127.0.0.1/*")]),
            "css": .string("main { display: none !important; }")
        ])
        XCTAssertTrue(firstRefused.isError, firstRefused.output)
        XCTAssertTrue(firstRefused.output.contains("visible text dropped"), firstRefused.output)
        XCTAssertTrue(store.scripts.isEmpty)

        let rawFirst = await browser.agentBridge.pageSnapshot()
        let afterFirstRefusal = try XCTUnwrap(rawFirst)
        XCTAssertGreaterThan(
            afterFirstRefusal.textLength,
            200,
            "Refused script_save must reload the page without the candidate so the refused state does not stay on screen."
        )

        let secondRefused = try await registry.dispatch(toolName: "script_save", arguments: [
            "name": .string("Empty Retry Check"),
            "match_rules": .array([.string("*://127.0.0.1/*")]),
            "css": .string("main { display: none !important; }")
        ])
        XCTAssertTrue(secondRefused.isError, secondRefused.output)
        XCTAssertTrue(secondRefused.output.contains("visible text dropped"), secondRefused.output)
        XCTAssertTrue(store.scripts.isEmpty)

        let savedClean = try await registry.dispatch(toolName: "script_save", arguments: [
            "name": .string("Hide Boom Cleanly"),
            "match_rules": .array([.string("*://127.0.0.1/*")]),
            "css": .string("#boom { display: none !important; }")
        ])
        XCTAssertFalse(savedClean.isError, savedClean.output)
        let savedID = try XCTUnwrap(JSONValue.parseObjectJSON(savedClean.output)["script_id"]?.stringValue)

        let refusedUpdate = try await registry.dispatch(toolName: "script_update", arguments: [
            "script_id": .string(savedID),
            "js": .string("document.body.innerHTML = '';")
        ])
        XCTAssertTrue(refusedUpdate.isError, refusedUpdate.output)

        let rawUpdate = await browser.agentBridge.pageSnapshot()
        let afterUpdateRefusal = try XCTUnwrap(rawUpdate)
        XCTAssertGreaterThan(afterUpdateRefusal.textLength, 200)
        let boomDisplay = try await browser.agentBridge.runJS(
            code: "return getComputedStyle(document.getElementById('boom')).display;",
            environment: .isolated,
            timeout: 2
        ).valueJSON
        XCTAssertEqual(boomDisplay, "\"none\"", "Refused script_update must restore the previously saved script's effect.")
    }

    private final class RecordedRefusedSaveClient: AgentModelClient, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [AgentModelTurnResponse]
        private(set) var requests: [[AgentModelTurn]] = []
        init(_ responses: [AgentModelTurnResponse]) { self.responses = responses }
        func completeToolTurn(
            system: String, messages: [AgentModelTurn], tools: [AgentToolDefinition],
            configuration: ProviderConfiguration, provider: AIProvider, maxTokens: Int
        ) async throws -> AgentModelTurnResponse {
            lock.withLock {
                requests.append(messages)
                return responses.isEmpty ? AgentModelTurnResponse(text: "Done.") : responses.removeFirst()
            }
        }
    }

    func testRecordedReplayRefusedSaveComparesAgainstRunBaselineAndSavesNarrowerFix() async throws {
        var sessionRef: BrowserAgentSession?
        let (browser, store, controller, _, _) = try await makeVerifiedBrowserHarness(baseline: { sessionRef?.pageBaseline })

        let client = RecordedRefusedSaveClient([
            AgentModelTurnResponse(text: "", toolCalls: [
                AgentModelToolCall(id: "t1", name: "run_js", arguments: ["code": .string("document.getElementById('article').remove();")])
            ], stopReason: "tool_use"),
            AgentModelTurnResponse(text: "", toolCalls: [
                AgentModelToolCall(id: "t2", name: "script_save", arguments: [
                    "name": .string("Hide Boom Button"),
                    "match_rules": .array([.string("*://127.0.0.1/*")]),
                    "css": .string("#article { display: none !important; }")
                ])
            ], stopReason: "tool_use"),
            AgentModelTurnResponse(text: "", toolCalls: [
                AgentModelToolCall(id: "t3", name: "script_save", arguments: [
                    "name": .string("Hide Boom Button"),
                    "match_rules": .array([.string("*://127.0.0.1/*")]),
                    "css": .string("#boom { display: none !important; }")
                ])
            ], stopReason: "tool_use"),
            AgentModelTurnResponse(text: "Saved a narrower rule that hides only the Boom button.")
        ])

        let session = BrowserAgentSession(
            pageDriver: browser.agentBridge,
            modelClient: client,
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
                    configuration: ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake-key"),
                    maxSteps: 10, truncationLimit: 20_000, customInstructions: "", redactedSecrets: []
                )
            },
            registryBuilder: { bridge, limit, secrets in
                ToolRegistry.m3(context: AgentToolContext(
                    bridge: bridge, workspace: nil, scriptStore: store, liveApplier: controller,
                    currentUserPrompt: { sessionRef?.lastUserPrompt },
                    pageBaseline: { sessionRef?.pageBaseline },
                    pageBaselineImage: { sessionRef?.pageBaselineImage },
                    settings: AgentToolSettings(
                        truncationLimit: limit,
                        redactedSecrets: secrets,
                        supportsImageInput: true
                    )
                ))
            }
        )
        sessionRef = session
        await session.sendAndWait("Always hide the Boom button on this site")

        XCTAssertEqual(session.toolCalls.map(\.toolName), ["run_js", "script_save", "script_save"])
        XCTAssertTrue(session.toolCalls[1].isError)
        XCTAssertFalse(session.toolCalls[2].isError, session.toolCalls[2].resultText)

        guard case .toolResults(let refusedResults)? = client.requests[2].last else {
            return XCTFail("Expected refused script_save tool result on turn 3")
        }
        let refusalText = refusedResults.first?.content ?? ""
        XCTAssertTrue(refusalText.contains("Error: Not saved:"), refusalText)
        XCTAssertTrue(refusalText.contains("confirm_change: true"), refusalText)
        XCTAssertEqual(refusedResults.first?.images.count, 2)
        XCTAssertNotNil(session.pageBaselineImage)
        XCTAssertEqual(store.scripts.count, 1)
        XCTAssertEqual(store.scripts.first?.css, "#boom { display: none !important; }")
    }
}
