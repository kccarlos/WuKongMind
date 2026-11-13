import Foundation
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
        XCTAssertEqual(unchanged.decorate("true"), "true\n\nPage changes: none")

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
        XCTAssertTrue(result.output.hasPrefix("The page may be broken: visible text dropped"))
        XCTAssertTrue(result.output.hasSuffix("Page changes: text 5,000 → 10"))
        XCTAssertTrue(result.output.contains("[truncated, 500 characters in total]"))
        XCTAssertTrue(result.modelContent.contains("The page may be broken"))
        XCTAssertTrue(result.resultSummary.hasPrefix("Page may be broken"))
        XCTAssertFalse(result.isError, "A warning is not an error")
        XCTAssertEqual(result.pageFeedback, feedback)
    }

    // MARK: - Real pages

    private var activeWindows: [UIWindow] = []

    override func tearDown() async throws {
        for window in activeWindows {
            window.isHidden = true
            window.rootViewController = nil
        }
        activeWindows.removeAll()
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
        XCTAssertTrue(result.output.hasPrefix("The page may be broken: "), result.output)
        XCTAssertTrue(result.output.contains("visible text dropped"), result.output)
        XCTAssertTrue(result.output.contains("links dropped from 10 to 0"), result.output)
        XCTAssertTrue(result.output.contains("\"emptied\""))
        XCTAssertTrue(result.output.hasSuffix(result.pageFeedback?.changesLine ?? "missing"))
        XCTAssertTrue(result.modelContent.contains("The page may be broken"))
    }

    func testHalvingTheHeightWarns() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let result = try await runJS("document.getElementById('spacer').style.height = '200px';", on: registry)
        XCTAssertEqual(result.pageFeedback?.reasons.count, 1, result.output)
        XCTAssertTrue(result.output.hasPrefix("The page may be broken: page height dropped from "), result.output)
    }

    func testMakingThePageUnscrollableWarns() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let result = try await registry.dispatch(
            toolName: "inject_css",
            arguments: ["css": .string("html, body { overflow: hidden !important; }")]
        )
        XCTAssertEqual(result.pageFeedback?.reasons, ["the page can no longer scroll"], result.output)
        XCTAssertTrue(result.output.hasPrefix("The page may be broken: the page can no longer scroll."))
        // The body becomes its own formatting context, so the height can move a few points.
        XCTAssertTrue(result.output.contains("scrollable yes → no"), result.output)
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
        XCTAssertTrue(result.output.hasPrefix("The page may be broken: links dropped from 10 to 0."))
    }

    func testAPageErrorWarns() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let result = try await runJS("document.getElementById('boom').click(); return 'clicked';", on: registry)
        XCTAssertEqual(result.pageFeedback?.reasons, ["a new page error appeared"], result.output)
        XCTAssertTrue(result.output.hasSuffix("Page changes: page errors 0 → 1"), result.output)
    }

    func testAChangeThatAltersNothingAddsOneLine() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let read = try await runJS("return document.title;", on: registry)
        XCTAssertEqual(read.output, "\"Fixture\"\n\nPage changes: none")

        let css = try await registry.dispatch(
            toolName: "inject_css",
            arguments: ["css": .string("h1 { color: rgb(200, 0, 0); }")]
        )
        let lines = css.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2, css.output)
        XCTAssertEqual(lines.last, "Page changes: none")
    }

    func testAScriptErrorStillReportsWhatChanged() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let result = try await runJS("document.body.innerHTML = ''; throw new Error('half done');", on: registry)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.hasPrefix("The page may be broken: "), result.output)
        XCTAssertTrue(result.output.contains("half done"))
    }

    func testReadOnlyToolsTakeNoSnapshot() async throws {
        let (_, registry, _) = await makePage(Self.articleHTML)
        let result = try await registry.dispatch(toolName: "read_page", arguments: ["mode": .string("text")])
        XCTAssertNil(result.pageFeedback)
        XCTAssertFalse(result.output.contains("Page changes"))
    }
}
