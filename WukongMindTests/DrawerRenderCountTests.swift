import Combine
import SwiftUI
import UIKit
import XCTest
@testable import WukongMind

/// Always-on guards for the drawer's render path (design-performance-and-state.md,
/// task 1): counts, not times, so they hold on every machine and run in CI.
/// The timings live in `DrawerPerformanceTests`, which CI skips.
@MainActor
final class DrawerRenderCountTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PerfProbe.isEnabled = true
        PerfProbe.reset()
    }

    override func tearDown() {
        PerfProbe.isEnabled = false
        PerfProbe.reset()
        super.tearDown()
    }

    // MARK: No export text while rendering

    func testTypingInTheDrawerBuildsNoExportText() {
        let app = DrawerPerformanceTests.makeApp(.init(name: "render-count", sourcePosts: 200, runs: 1))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let host = UIHostingController(rootView: AnyView(
            AssistantPanel(app: app, onExpand: { _ in }).environment(\.colorScheme, .light)
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let opened = PerfProbe.snapshot
        XCTAssertGreaterThan(opened.counts["AssistantPanel.body"] ?? 0, 0, "The panel did not render")
        // The summary's menu was built (its items read exportDisabled), and no text with it.
        XCTAssertGreaterThan(opened.counts["AssistantPanel.exportDisabled"] ?? 0, 0, "The summary menu did not render")
        XCTAssertEqual(opened.counts["AssistantPanel.exportText"] ?? 0, 0, "Opening the drawer built the export text")
        XCTAssertEqual(opened.counts["TopicExportPayload.text"] ?? 0, 0, "Opening the drawer built the export text")

        let editor = DrawerPerformanceTests.descendants(of: host.view, as: UITextView.self).first
        let field = DrawerPerformanceTests.descendants(of: host.view, as: UITextField.self).first
        XCTAssertTrue(editor != nil || field != nil, "The composer's text input was not found")
        PerfProbe.reset()
        for character in ["a", "b", "c", "d", "e"] {
            if let editor { editor.insertText(character) } else { field?.insertText(character) }
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let typing = PerfProbe.snapshot
        XCTAssertGreaterThan(typing.counts["AssistantComposer.body"] ?? 0, 0, "Typing did not reach the composer")
        // The composer owns its draft (task 2): a keystroke renders the footer and nothing around it.
        XCTAssertGreaterThan(typing.counts["AssistantFooter.body"] ?? 0, 0, "Typing did not reach the footer")
        for name in ["AssistantPanel.body", "ChatThread.body", "BrowserAgentRunsView.body", "BrowserAgentRunsView.runSection", "AssistantPanel.exportDisabled"] {
            XCTAssertEqual(typing.counts[name] ?? 0, 0, "\(name) was evaluated while typing")
        }
        XCTAssertEqual(typing.counts["AssistantPanel.exportText"] ?? 0, 0, "A keystroke built the export text")
        XCTAssertEqual(typing.counts["TopicExportPayload.text"] ?? 0, 0, "A keystroke built the export text")
    }

    // MARK: hasContent without the text

    /// The answer `hasContent` gave before it stopped building the text.
    private func oldHasContent(_ payload: TopicExportPayload, _ options: ExportOptions) -> Bool {
        !payload.text(options: options).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func testHasContentMatchesTheBuiltTextForEveryCombination() {
        let titles = ["", "  \n", "Citi “300” bonus — thread"]
        let urls: [URL?] = [nil, URL(string: "https://www.doctorofcredit.com/citi-300-checking-bonus/")]
        let summaries = ["", " \n\t", "## Theme\n\nIt works [#3](wukongmind-post:3)."]
        let sources = ["", " ", "\n\n", "Post #1 by user1:\nIt doesn’t post 😕"]
        let histories: [[ChatMessage]] = [
            [],
            [ChatMessage(role: .user, content: "  ")],
            [ChatMessage(role: .user, content: "Does it?"), ChatMessage(role: .assistant, content: "Yes.")]
        ]
        var checked = 0
        for title in titles {
            for url in urls {
                for summary in summaries {
                    for source in sources {
                        for history in histories {
                            let payload = TopicExportPayload(
                                summary: summary, source: source, title: title, url: url, history: history,
                                summaryUpdatedAt: Date(timeIntervalSince1970: 1_795_000_000), summaryPostCount: 10, totalPosts: 12
                            )
                            for mask in 0..<16 {
                                let options = ExportOptions(
                                    excludeTitleAndURL: mask & 1 != 0,
                                    excludeSummary: mask & 2 != 0,
                                    excludePostAndResponses: mask & 4 != 0,
                                    excludeChatHistory: mask & 8 != 0
                                )
                                XCTAssertEqual(
                                    payload.hasContent(options: options), oldHasContent(payload, options),
                                    "title \(title.debugDescription), url \(String(describing: url)), summary \(summary.debugDescription), source \(source.debugDescription), history \(history.count), options \(options)"
                                )
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 3 * 2 * 3 * 4 * 3 * 16)
    }

    func testHasContentBuildsNoText() {
        let payload = TopicExportPayload(
            summary: "A summary", source: DrawerPerformanceTests.source(posts: 50), title: "T", url: nil, history: []
        )
        PerfProbe.reset()
        for mask in 0..<16 {
            _ = payload.hasContent(options: ExportOptions(
                excludeTitleAndURL: mask & 1 != 0, excludeSummary: mask & 2 != 0,
                excludePostAndResponses: mask & 4 != 0, excludeChatHistory: mask & 8 != 0
            ))
        }
        XCTAssertEqual(PerfProbe.snapshot.counts["TopicExportPayload.text"] ?? 0, 0)
    }

    // MARK: Copy, Share and Export hand out the same text as before

    private var payload: TopicExportPayload {
        TopicExportPayload(
            summary: "## Theme\n\nIt posts in 3 days [#3](wukongmind-post:3) — “usually”.",
            source: "Post #1 by user1 (2026-11-01):\nIt doesn’t post 😕\n\nPost #2 by user2:\nDP’d in 2 days.",
            title: "Citi $300 checking bonus",
            url: URL(string: "https://www.doctorofcredit.com/citi-300-checking-bonus/"),
            history: [ChatMessage(role: .user, content: "Does it post?"), ChatMessage(role: .assistant, content: "Yes, in 2–3 days.")],
            summaryUpdatedAt: Date(timeIntervalSince1970: 1_795_000_000), summaryPostCount: 2, totalPosts: 2
        )
    }

    func testCopyShareAndExportUseTheExportTextUnchanged() {
        let options = [
            ExportOptions(),
            ExportOptions(excludeTitleAndURL: true),
            ExportOptions(excludeSummary: true, excludeChatHistory: true),
            ExportOptions(excludePostAndResponses: true)
        ]
        for option in options {
            // Copy uses this string directly. Share and Export .txt wrap it.
            let text = payload.text(options: option)
            let expected = Data(text.utf8)
            let item = ExportActivityItem(text: text)
            let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
            let shared = item.activityViewController(controller, itemForActivityType: .copyToPasteboard) as? String
            XCTAssertEqual(shared.map { Data($0.utf8) }, expected, "Share handed out different bytes")
            let document = PlainTextDocument(text: text)
            XCTAssertEqual(Data(document.text.utf8), expected)
        }
        // The text itself is unchanged: one fixed case, written out in full.
        XCTAssertEqual(payload.text(options: ExportOptions(excludeChatHistory: true)), """
        Citi $300 checking bonus

        Post URL: https://www.doctorofcredit.com/citi-300-checking-bonus/

        Summary:
        Summarized 2026-11-18 · 2 of 2 posts
        ## Theme

        It posts in 3 days [#3](wukongmind-post:3) — “usually”.

        Full post:
        Post #1 by user1 (2026-11-01):
        It doesn’t post 😕

        Post #2 by user2:
        DP’d in 2 days.
        """)
    }

    func testExportPreparationMatchesTextBytesForEveryOptionCombination() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wukongmind-test-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let slug = "www-doctorofcredit-com-123"
        for mask in 0..<16 {
            let options = ExportOptions(
                excludeTitleAndURL: mask & 1 != 0,
                excludeSummary: mask & 2 != 0,
                excludePostAndResponses: mask & 4 != 0,
                excludeChatHistory: mask & 8 != 0
            )
            let expectedText = payload.text(options: options)
            let expectedBytes = Data(expectedText.utf8)

            // Under the limit: plain text.
            let inline = try TopicExportFile.prepare(
                payload: payload, options: options, slug: slug, limit: Int.max, temporaryDirectory: tempRoot
            )
            XCTAssertEqual(inline, .text(expectedText, slug: slug), "mask \(mask)")
            if case .text(let text, _) = inline {
                let item = ExportActivityItem(text: text)
                let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
                let shared = item.activityViewController(controller, itemForActivityType: .message) as? String
                XCTAssertEqual(shared.map { Data($0.utf8) }, expectedBytes, "mask \(mask)")
            }

            // Over the limit (when non-empty): temporary .txt file with identical UTF-8 bytes.
            guard !expectedText.isEmpty else { continue }
            let over = try TopicExportFile.prepare(
                payload: payload, options: options, slug: slug, limit: 0, temporaryDirectory: tempRoot
            )
            guard case .file(let url) = over else {
                XCTFail("Expected .file for mask \(mask)")
                continue
            }
            defer { TopicExportFile.removeTemporaryFile(at: url) }
            XCTAssertEqual(url.lastPathComponent, "wukongmind-\(slug).txt")
            XCTAssertEqual(try Data(contentsOf: url), expectedBytes, "File bytes differ for mask \(mask)")

            let fileItem = ExportActivityItem(fileURL: url)
            let controller = UIActivityViewController(activityItems: [fileItem], applicationActivities: nil)
            XCTAssertEqual(fileItem.activityViewControllerPlaceholderItem(controller) as? URL, url)
            XCTAssertEqual(fileItem.activityViewController(controller, itemForActivityType: .message) as? URL, url)
            XCTAssertEqual(fileItem.activityViewController(controller, subjectForActivityType: .mail), "wukongmind-\(slug).txt")

            let folder = url.deletingLastPathComponent()
            TopicExportFile.removeTemporaryFile(at: url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Temp file not removed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Temp folder not removed")
        }
    }

    func testExportPreparationLimitBoundaryAndCleanupAfterMove() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wukongmind-test-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let options = ExportOptions()
        let text = payload.text(options: options)
        let exactLength = text.count
        XCTAssertGreaterThan(exactLength, 10)

        // At the limit: stays inline text.
        let atLimit = try TopicExportFile.prepare(
            payload: payload, options: options, slug: "topic-1", limit: exactLength, temporaryDirectory: tempRoot
        )
        XCTAssertEqual(atLimit, .text(text, slug: "topic-1"))

        // One character over the limit: writes a file.
        let overLimit = try TopicExportFile.prepare(
            payload: payload, options: options, slug: "topic-1", limit: exactLength - 1, temporaryDirectory: tempRoot
        )
        guard case .file(let url) = overLimit else {
            return XCTFail("Expected .file when one character over the limit")
        }
        XCTAssertEqual(url.lastPathComponent, "wukongmind-topic-1.txt")
        XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8))

        XCTAssertEqual(TopicExportFile.filename(slug: "127-0-0-1:54317-1001"), "wukongmind-127-0-0-1-54317-1001.txt")
        XCTAssertEqual(TopicExportFile.filename(slug: "a/b"), "wukongmind-a-b.txt")

        // Simulate `fileMover` having moved the file out of the temp folder: cleanup still removes the folder.
        let movedTo = tempRoot.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: url, to: movedTo)
        let folder = url.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        TopicExportFile.removeTemporaryFile(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Stripped summary

    /// `PostCitations.stripped` as it was before its expressions became static.
    private func oldStripped(_ markdown: String) -> String {
        guard let pattern = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_&/#])#(\d{1,5})(?!\d)(?![^\[\]\n]*\]\()"#
        ) else { return markdown }
        return MarkdownCodeSpans.transform(markdown) { segment in
            let group = #"(?:\[[\s,、，;；#0-9]+\]|\([\s,、，;；#0-9]+\)|（[\s,、，;；#0-9]+）|【[\s,、，;；#0-9]+】)"#
            let groups = try? NSRegularExpression(pattern: "([*_]{1,3})" + group + #"\1|"# + group)
            let nsText = segment as NSString
            let citations = pattern.matches(in: segment, range: NSRange(location: 0, length: nsText.length))
            var text = segment
            for match in (groups?.matches(in: segment, range: NSRange(location: 0, length: nsText.length)) ?? []).reversed() {
                let candidate = nsText.substring(with: match.range)
                let remaining = pattern.stringByReplacingMatches(in: candidate,
                    range: NSRange(location: 0, length: (candidate as NSString).length), withTemplate: "")
                guard remaining != candidate,
                      remaining.allSatisfy({ "[]()（）【】*_,、，;；".contains($0) || $0.isWhitespace }),
                      citations.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
                text = (text as NSString).replacingCharacters(in: match.range, with: "")
            }
            let removed = pattern.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: ""
            )
            return removed
                .replacingOccurrences(of: #"[ \t]+([.,;:!?。，；：！？])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        }
    }

    func testStrippedIsUnchangedWithStaticExpressions() {
        let samples = [
            "",
            "fixes it #37 ; three",
            "Several people report it (#12, #13) and **[#14]** too.",
            "确认#37 是的 【#2、#3】，然后（#4；#5）。",
            "Code `#12` stays, and ```\n#13\n``` too; #14  and   #15 !",
            "A [link #3](https://example.com) and _(#9)_ and [#7](wukongmind-post:7).",
            DrawerPerformanceTests.summary(sections: 6, posts: 500)
        ]
        for sample in samples {
            XCTAssertEqual(PostCitations.stripped(sample), oldStripped(sample), sample)
        }
    }

    func testStrippedSummaryCacheFollowsTheText() {
        let cache = StrippedSummaryCache()
        XCTAssertEqual(cache.stripped("one #3 two"), PostCitations.stripped("one #3 two"))
        XCTAssertEqual(cache.stripped("one #3 two"), PostCitations.stripped("one #3 two"))
        XCTAssertEqual(cache.stripped("three (#4)."), PostCitations.stripped("three (#4)."))
        XCTAssertEqual(cache.stripped(""), "")
    }

    // MARK: The drawer observes what it draws (task 3)

    func testUnrelatedAppAndBrowserPublishesEvaluateNoRunSectionsOrSummaryRows() throws {
        let app = DrawerPerformanceTests.makeApp(
            .init(name: "observe-slice", sourcePosts: 200, summarySections: 10, runs: 5, shapePosts: 100)
        )
        let topicURL = try XCTUnwrap(app.currentTopic?.url)
        _ = try app.scriptStore.importUserScript(
            """
            // ==UserScript==
            // @name         Meta Reader
            // @match        https://meta.discourse.org/*
            // ==/UserScript==
            void 0;
            """
        )
        app.browser.simulatePageUpdateForTesting(url: topicURL, title: "Layout jumps after rotation")

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        PerfProbe.reset()
        let host = UIHostingController(rootView: AnyView(
            AssistantPanel(app: app, onExpand: { _ in }).environment(\.colorScheme, .light)
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let opened = PerfProbe.snapshot
        XCTAssertGreaterThan(opened.counts["DrawerHeader.body"] ?? 0, 0)
        XCTAssertGreaterThan(opened.counts["DrawerSummary.body"] ?? 0, 0)
        XCTAssertGreaterThan(opened.counts["DrawerSummarySections.body"] ?? 0, 0)
        XCTAssertGreaterThan(opened.counts["MarkdownBlockView.body"] ?? 0, 0)
        // Only the initial LazyVStack window + eager newest run evaluate on open, not all 5 runs.
        XCTAssertLessThanOrEqual(opened.counts["BrowserAgentRunsView.runSection"] ?? 0, 3)
        XCTAssertGreaterThanOrEqual(opened.counts["BrowserAgentRunsView.runSection"] ?? 0, 1)
        XCTAssertEqual(opened.counts["BrowserAgentRunsView.timeline"] ?? 0, 1)
        XCTAssertLessThanOrEqual(opened.counts["BrowserAgentRunsView.forumSources"] ?? 0, 3)
        XCTAssertEqual(opened.counts["AssistantPanel.matchingPageScripts"] ?? 0, 1)

        var browserPublishes = 0
        let cancellable = app.browser.objectWillChange.sink { browserPublishes += 1 }
        defer { _ = cancellable }

        // 1. Unrelated AppModel publishes skip run sections, summary rows, header and caches.
        PerfProbe.reset()
        for index in 0..<5 {
            app.discoveredModels = [.openAI: [DiscoveredModel(id: "tick-\(index)")]]
            app.savedAnswerRunID = UUID()
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let appPublish = PerfProbe.snapshot
        for name in [
            "BrowserAgentRunsView.runSection", "DrawerSummarySections.body", "MarkdownBlockView.body",
            "DrawerSummary.body", "DrawerHeader.body", "ChatThread.body", "BrowserAgentRunsView.body",
            "DrawerSummarySections.parsed", "AssistantPanel.strippedSummary", "AssistantPanel.exportDisabled",
            "BrowserAgentRunsView.timeline", "BrowserAgentRunsView.forumSources", "AssistantPanel.matchingPageScripts"
        ] {
            XCTAssertEqual(appPublish.counts[name] ?? 0, 0, "\(name) ran on an unrelated AppModel publish")
        }

        // 2. Browser publishes that change no DrawerPageFacts publish zero facts and evaluate nothing in the drawer.
        browserPublishes = 0
        PerfProbe.reset()
        app.browser.simulatePageUpdateForTesting(url: topicURL, title: "Layout jumps after rotation")
        app.browser.setSystemKeyboardVisible(true)
        app.browser.setSystemKeyboardVisible(false)
        app.browser.setEditingAddress(true)
        app.browser.setEditingAddress(false)
        app.browser.homeSiteURL = "https://example.com"
        app.browser.homeSiteURL = DrawerPerformanceTests.siteURL
        app.browser.dismissCrashNotice()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let browserPublish = PerfProbe.snapshot
        XCTAssertGreaterThanOrEqual(browserPublishes, 6, "Expected ForumBrowserModel to publish")
        XCTAssertEqual(browserPublish.counts["publish.DrawerPageFacts"] ?? 0, 0, "DrawerPageFacts republished without changing")
        for name in [
            "AssistantPanel.body", "BrowserAgentRunsView.runSection", "DrawerSummarySections.body",
            "MarkdownBlockView.body", "DrawerSummary.body", "DrawerHeader.body", "ChatThread.body",
            "BrowserAgentRunsView.timeline", "BrowserAgentRunsView.forumSources", "AssistantPanel.matchingPageScripts"
        ] {
            XCTAssertEqual(browserPublish.counts[name] ?? 0, 0, "\(name) ran on a browser publish that changed no drawer fact")
        }

        // 3. Changing URL updates DrawerPageFacts once and recomputes script matches once, while run sections and summary stay untouched.
        let otherURL = try XCTUnwrap(URL(string: "https://meta.discourse.org/t/another-topic/999"))
        PerfProbe.reset()
        app.browser.simulatePageUpdateForTesting(url: otherURL, title: "Another topic")
        app.browser.simulatePageUpdateForTesting(url: otherURL, title: "Another topic retitled")
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let urlChange = PerfProbe.snapshot
        XCTAssertEqual(urlChange.counts["publish.DrawerPageFacts"] ?? 0, 1)
        XCTAssertEqual(urlChange.counts["AssistantPanel.matchingPageScripts"] ?? 0, 1)
        XCTAssertEqual(urlChange.counts["BrowserAgentRunsView.runSection"] ?? 0, 0)
        XCTAssertEqual(urlChange.counts["MarkdownBlockView.body"] ?? 0, 0)
    }

    func testConversationSummaryCardSkipsRowsAndRunSectionsOnUnrelatedPublishes() throws {
        let app = DrawerPerformanceTests.makeApp(
            .init(name: "card-summary", sourcePosts: 100, summarySections: 8, runs: 2, shapePosts: 50)
        )
        let topicURL = try XCTUnwrap(app.currentTopic?.url)
        app.browser.simulatePageUpdateForTesting(url: topicURL, title: "Layout jumps after rotation")
        var saved = SavedAgentConversation(
            messages: app.browserAgent.messages, runs: app.browserAgent.runs,
            toolCalls: app.browserAgent.toolCalls, runState: app.browserAgent.runState,
            tokenUsage: app.browserAgent.tokenUsage, history: []
        )
        saved.runs[saved.runs.count - 1].toolCalls[0].toolName = "summarize_topic"
        saved.runs[saved.runs.count - 1].toolCalls[0].resultText = app.currentSession?.summary ?? ""
        app.browserAgent.restoreConversation(saved)

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let host = UIHostingController(rootView: AnyView(
            AssistantPanel(app: app, onExpand: { _ in }).environment(\.colorScheme, .light)
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertGreaterThan(PerfProbe.snapshot.counts["MarkdownBlockView.body"] ?? 0, 0)
        XCTAssertEqual(PerfProbe.snapshot.counts["BrowserAgentRunsView.runSection"] ?? 0, 2)

        PerfProbe.reset()
        app.discoveredModels = [.anthropic: [DiscoveredModel(id: "claude-tick")]]
        app.browser.simulatePageUpdateForTesting(url: topicURL, title: "Layout jumps after rotation")
        app.browser.setSystemKeyboardVisible(true)
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let after = PerfProbe.snapshot
        for name in ["BrowserAgentRunsView.runSection", "DrawerSummarySections.body", "MarkdownBlockView.body", "DrawerSummary.body"] {
            XCTAssertEqual(after.counts[name] ?? 0, 0, "\(name) ran on an unrelated publish with a conversation summary card")
        }
    }

    func testCoveredWebViewAccessibilityTracksKeyboardTransitionsAtLargeDetent() throws {
        let app = DrawerPerformanceTests.makeApp(.init(name: "webhost-a11y", sourcePosts: 10, runs: 0))
        let topicURL = try XCTUnwrap(app.currentTopic?.url)
        app.browser.simulatePageUpdateForTesting(url: topicURL, title: "Thread")
        app.router.splitLayout = false
        app.router.openDrawer(at: .large)
        app.router.presentDrawer()
        app.router.drawerAppeared()
        XCTAssertEqual(app.router.drawerPhase, .shown)
        XCTAssertEqual(app.router.drawerDetent, .large)

        let hostView = BrowserTabsWebHostView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        hostView.bind(tabs: app.tabs, router: app.router)
        let webView = try XCTUnwrap(app.browser.existingWebView)
        XCTAssertFalse(webView.accessibilityElementsHidden)

        app.browser.setSystemKeyboardVisible(true)
        XCTAssertTrue(webView.accessibilityElementsHidden, "Keyboard appearing at .large must hide covered webView accessibility without waiting on another router publish")

        app.browser.setSystemKeyboardVisible(false)
        XCTAssertFalse(webView.accessibilityElementsHidden, "Keyboard dismissing at .large must restore webView accessibility immediately")
    }

    func testConversationSummaryCardMarksCitationTipAndSiteToolStateUpdatesSuggestionSlice() throws {
        let tipKey = PresentationRouter.citationTipKey
        let previousTip = UserDefaults.standard.object(forKey: tipKey)
        UserDefaults.standard.removeObject(forKey: tipKey)
        defer {
            if let previousTip {
                UserDefaults.standard.set(previousTip, forKey: tipKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tipKey)
            }
        }

        let app = DrawerPerformanceTests.makeApp(
            .init(name: "card-citation-tip", sourcePosts: 50, summarySections: 4, runs: 1, shapePosts: 20)
        )
        let topic = try XCTUnwrap(app.currentTopic)
        let forum = try XCTUnwrap(app.currentForum)
        let topicURL = try XCTUnwrap(topic.url)
        var session = try XCTUnwrap(app.currentSession)
        session.summary = "## Summary\n\nReaders confirm it works (#2, #3)."
        app.applyDebugSeed(AssistantDebugSeed(
            forums: [forum], sessions: [session], activities: [], agentRuns: [], watchedTopics: [],
            currentTopic: topic, currentForum: forum, pageContext: app.pageContext
        ))
        app.browser.simulatePageUpdateForTesting(url: topicURL, title: "Thread")
        var saved = SavedAgentConversation(
            messages: app.browserAgent.messages, runs: app.browserAgent.runs,
            toolCalls: app.browserAgent.toolCalls, runState: app.browserAgent.runState,
            tokenUsage: app.browserAgent.tokenUsage, history: []
        )
        saved.runs[0].toolCalls[0].toolName = "summarize_topic"
        saved.runs[0].toolCalls[0].resultText = session.summary
        app.browserAgent.restoreConversation(saved)

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let host = UIHostingController(rootView: AnyView(
            AssistantPanel(app: app, onExpand: { _ in }).environment(\.colorScheme, .light)
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(UserDefaults.standard.bool(forKey: tipKey), "Conversation summary card must record citationTipKey on first cited summary")

        // Mutating and forgetting SiteToolState on the same URL advances revision and invalidates cached state.
        let rev0 = app.siteToolStateStore.currentRevision
        var state = SiteToolState(host: "meta.discourse.org")
        state.setSlot(SiteSlotState(status: .failed, failure: SiteSlotFailure(code: .noPosts)), for: .readTopic)
        try app.siteToolStateStore.save(state)
        XCTAssertGreaterThan(app.siteToolStateStore.currentRevision, rev0)
        let rev1 = app.siteToolStateStore.currentRevision
        app.siteToolStateStore.forget(host: "meta.discourse.org")
        XCTAssertGreaterThan(app.siteToolStateStore.currentRevision, rev1)
        XCTAssertNil(app.siteToolStateStore.state(forURL: topicURL))
    }

    // MARK: Lazy transcript (task 6)

    func testLazyTranscriptOpensWithoutOffscreenRunsAndSettlesToBottom() throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }

        let app = DrawerPerformanceTests.makeApp(.init(name: "lazy-60", runs: 60))
        app.selectModel(ModelSelection(provider: .ollama, model: "llama3.1"), for: .role(.browserAgent))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        PerfProbe.reset()
        let host = UIHostingController(rootView: AnyView(
            AssistantPanel(app: app, onExpand: { _ in }).environment(\.colorScheme, .light)
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        // O(1) run sections evaluate on open (eager newest run + initial LazyVStack window), never all 60.
        let openSections = PerfProbe.snapshot.counts["BrowserAgentRunsView.runSection"] ?? 0
        XCTAssertGreaterThanOrEqual(openSections, 1)
        XCTAssertLessThanOrEqual(openSections, 4)

        let scroll = try XCTUnwrap(
            DrawerPerformanceTests.descendants(of: host.view, as: UIScrollView.self)
                .filter { !($0 is UITextView) }
                .max(by: { $0.contentSize.height < $1.contentSize.height })
        )
        // Sheet detent settlement shrinks the viewport right after open; an idle drawer opened at the top stays at the top.
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 760)
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertLessThanOrEqual(scroll.contentOffset.y, 1, "Opening an idle drawer must stay at the top across sheet settlement")

        // Append run 60 via `send` and settle to the bottom.
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "c1", name: "wait_for", arguments: ["ms": .int(1)])])),
            .success(AgentModelTurnResponse(text: DrawerPerformanceTests.reply(60)))
        ])
        app.browserAgent.configureDebugModelClient(client)
        PerfProbe.reset()
        app.browserAgent.send("What does the thread say about question 60?")
        let deadline = Date().addingTimeInterval(4)
        while (app.browserAgent.isRunning || ChatScrollProbe.isSettling), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        host.view.layoutIfNeeded()

        let afterSend = PerfProbe.snapshot
        XCTAssertEqual(app.browserAgent.runs.count, 61)
        XCTAssertLessThanOrEqual(afterSend.counts["ChatThread.body"] ?? 0, 4)
        XCTAssertLessThan(afterSend.counts["BrowserAgentRunsView.runSection"] ?? 0, 15)

        let distance = scroll.contentSize.height - (scroll.contentOffset.y + scroll.bounds.height)
        XCTAssertLessThan(distance, TranscriptFollow.nearBottomThreshold, "Settle loop must land at the bottom")
    }

    func testFinishedSummaryCardOpensLazilyAndStreamingRunStaysEager() throws {
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }

        let app = DrawerPerformanceTests.makeApp(
            .init(name: "lazy-summary-card", sourcePosts: 100, summarySections: 8, runs: 1, shapePosts: 20)
        )
        let topicURL = try XCTUnwrap(app.currentTopic?.url)
        app.browser.simulatePageUpdateForTesting(url: topicURL, title: "Layout jumps after rotation")
        let summaryText = try XCTUnwrap(app.currentSession?.summary)
        let totalBlocks = DrawerSummarySections.parsed(for: .init(text: summaryText, maximumPost: 100)).rows.count
        XCTAssertGreaterThanOrEqual(totalBlocks, 40)

        var saved = SavedAgentConversation(
            messages: app.browserAgent.messages, runs: app.browserAgent.runs,
            toolCalls: app.browserAgent.toolCalls, runState: app.browserAgent.runState,
            tokenUsage: app.browserAgent.tokenUsage, history: []
        )
        saved.runs[0].toolCalls[0].toolName = "summarize_topic"
        saved.runs[0].toolCalls[0].resultText = summaryText
        app.browserAgent.restoreConversation(saved)

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // 1. Finished run holding a 48-block summary card: only the visible blocks evaluate on open.
        PerfProbe.reset()
        let host = UIHostingController(rootView: AnyView(
            AssistantPanel(app: app, onExpand: { _ in }).environment(\.colorScheme, .light)
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let finishedOpen = PerfProbe.snapshot
        let finishedBlocks = finishedOpen.counts["MarkdownBlockView.body"] ?? 0
        XCTAssertGreaterThan(finishedBlocks, 0)
        XCTAssertLessThan(finishedBlocks, totalBlocks / 2, "Finished summary card built \(finishedBlocks) of \(totalBlocks) blocks on open")
        XCTAssertEqual(finishedOpen.counts["BrowserAgentRunsView.runSection"] ?? 0, 1)

        // 2. While streaming (`isLazy: false`), `DCResultCard` stays eager so streaming height is exact.
        let parsedRows = DrawerSummarySections.parsed(for: .init(text: summaryText, maximumPost: 100)).rows
        PerfProbe.reset()
        let eagerHost = UIHostingController(rootView: AnyView(
            ScrollView {
                DCResultCard(label: "Summary", isLazy: false) {
                    DrawerSummarySections(rows: parsedRows, layout: .singleColumn)
                }
                .padding(14)
            }
            .environment(\.colorScheme, .light)
        ))
        window.rootViewController = eagerHost
        window.makeKeyAndVisible()
        eagerHost.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let eagerBlocks = PerfProbe.snapshot.counts["MarkdownBlockView.body"] ?? 0
        XCTAssertGreaterThanOrEqual(eagerBlocks, totalBlocks, "Eager DCResultCard must build all blocks while streaming")
    }

    // MARK: Keyboard churn isolation (WUKO-166)

    func testKeyboardChurnDoesNotReevaluateAssistantPanelOrPublishBrowser() async {
        let app = DrawerPerformanceTests.makeApp(.init(name: "keyboard-churn", sourcePosts: 50, runs: 1))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let host = UIHostingController(rootView: AnyView(
            AssistantPanel(app: app, onExpand: { _ in }).environment(\.colorScheme, .light)
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        // 1. Real keyboard show/hide notifications never re-evaluate AssistantPanel.body or transcript views.
        PerfProbe.reset()
        for _ in 0..<5 {
            NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let afterNotifs = PerfProbe.snapshot
        XCTAssertEqual(afterNotifs.counts["AssistantPanel.body"] ?? 0, 0, "Keyboard notifications must not re-evaluate AssistantPanel.body")
        XCTAssertEqual(afterNotifs.counts["ChatThread.body"] ?? 0, 0, "Keyboard notifications must not re-evaluate ChatThread.body")
        XCTAssertEqual(afterNotifs.counts["BrowserAgentRunsView.runSection"] ?? 0, 0)

        // 2. While the drawer composer owns first responder, transient hide->show churn is gated.
        let browser = app.browser
        let center = NotificationCenter()
        let keyboardState = DrawerKeyboardState(notificationCenter: center)
        keyboardState.setComposerFocused(true, browser: browser)
        keyboardState.handleKeyboardShow()
        browser.setSystemKeyboardVisible(true)
        XCTAssertTrue(keyboardState.isKeyboardVisible)
        XCTAssertTrue(browser.isSystemKeyboardVisible)

        var statePublishes = 0
        let stateCancellable = keyboardState.objectWillChange.sink { statePublishes += 1 }
        defer { stateCancellable.cancel() }
        PerfProbe.reset()
        for _ in 0..<10 {
            center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            browser.setSystemKeyboardVisible(false)
            center.post(name: UIResponder.keyboardWillShowNotification, object: nil)
            browser.setSystemKeyboardVisible(true)
        }
        XCTAssertEqual(statePublishes, 0, "Gated keyboard churn must not publish DrawerKeyboardState")
        XCTAssertEqual(PerfProbe.snapshot.counts["publish.browser.isSystemKeyboardVisible"] ?? 0, 0,
                       "Gated keyboard churn must not publish ForumBrowserModel.isSystemKeyboardVisible")
        XCTAssertTrue(keyboardState.isKeyboardVisible)
        XCTAssertTrue(browser.isSystemKeyboardVisible)

        // 3. Blurring the composer flushes a pending hide immediately.
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        browser.setSystemKeyboardVisible(false)
        XCTAssertTrue(keyboardState.isKeyboardVisible)
        XCTAssertTrue(browser.isSystemKeyboardVisible)
        keyboardState.setComposerFocused(false, browser: browser)
        XCTAssertFalse(keyboardState.isKeyboardVisible)
        XCTAssertFalse(browser.isSystemKeyboardVisible)

        // 4. When composer is not focused, hide applies immediately.
        keyboardState.handleKeyboardShow()
        browser.setSystemKeyboardVisible(true)
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        browser.setSystemKeyboardVisible(false)
        XCTAssertFalse(keyboardState.isKeyboardVisible)
        XCTAssertFalse(browser.isSystemKeyboardVisible)
    }

    // MARK: Apple Intelligence status caching (WUKO-166)

    func testOpeningDrawerAndEvaluatingHintInputDoesNotProbeAppleIntelligence() {
        let client = AppleIntelligenceClient()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"))
        let app = AppModel(store: store, aiService: AIService(appleIntelligence: client))

        PerfProbe.reset()
        for _ in 0..<5 {
            _ = app.appleIntelligenceStatus
            _ = app.drawerHintInput
            _ = app.bottomLayer
            _ = app.readiness(for: .assistant)
            _ = app.readiness(for: .scripts)
        }
        XCTAssertEqual(
            PerfProbe.snapshot.counts["AppleIntelligenceClient.probe"] ?? 0,
            0,
            "Reading appleIntelligenceStatus or drawerHintInput must not probe FoundationModels"
        )

        _ = client.refreshStatus()
        XCTAssertEqual(
            PerfProbe.snapshot.counts["AppleIntelligenceClient.probe"] ?? 0,
            1,
            "Explicit refreshStatus() must re-probe FoundationModels"
        )
    }
}
