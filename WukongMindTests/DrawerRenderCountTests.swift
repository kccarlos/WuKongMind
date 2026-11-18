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
        XCTAssertEqual(opened.counts["BrowserAgentRunsView.runSection"] ?? 0, 5)
        XCTAssertEqual(opened.counts["BrowserAgentRunsView.timeline"] ?? 0, 1)
        XCTAssertEqual(opened.counts["BrowserAgentRunsView.forumSources"] ?? 0, 5)
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
}
