import Foundation
import XCTest
#if canImport(WukongMind)
@testable import WukongMind
#endif

/// One panel 2b: which suggestions a page shows, where each one runs, and the
/// old-engine results handed to the Agent's next message.
@MainActor
final class SuggestionRoutingTests: XCTestCase {
    private let site = "https://forum.example.org"

    // MARK: Selection

    func testPageKindFollowsThePageState() {
        XCTAssertEqual(PageSuggestions.pageKind(state: .topic, hasPage: true), .forumThread)
        XCTAssertEqual(PageSuggestions.pageKind(state: .forumHome, hasPage: true), .forumList)
        // Unrecognised sites are ordinary pages.
        XCTAssertEqual(PageSuggestions.pageKind(state: .notForum, hasPage: true), .ordinaryPage)
        XCTAssertEqual(PageSuggestions.pageKind(state: .maybe, hasPage: true), .ordinaryPage)
        // A loading page's kind isn't known yet: no row (no flash of page suggestions).
        XCTAssertNil(PageSuggestions.pageKind(state: .loading, hasPage: true))
        // No page open: no row.
        XCTAssertNil(PageSuggestions.pageKind(state: .notForum, hasPage: false))
        XCTAssertNil(PageSuggestions.pageKind(state: .loading, hasPage: false))
    }

    func testSuggestionsPerPageKind() {
        XCTAssertEqual(PageSuggestions.suggestions(for: .forumThread), [.summarizeThread, .readAloud, .searchForum, .followReplies])
        XCTAssertEqual(PageSuggestions.suggestions(for: .forumList), [.worthReadingToday, .searchForum])
        XCTAssertEqual(PageSuggestions.suggestions(for: .ordinaryPage), [.summarizePage, .makeDark, .removeDistractions])
        XCTAssertEqual(PageSuggestions.suggestions(for: nil), [])
    }

    func testAFollowedThreadDropsNotifyMe() {
        XCTAssertEqual(PageSuggestions.suggestions(for: .forumThread, isFollowing: true), [.summarizeThread, .readAloud, .searchForum])
    }

    func testARunningSummaryDropsSummarize() {
        XCTAssertEqual(PageSuggestions.suggestions(for: .forumThread, isSummarizing: true), [.readAloud, .searchForum, .followReplies])
    }

    func testAtMostFourVisibleAndOnlySearchFillsTheBox() {
        for kind in [SuggestionPageKind.forumThread, .forumList, .ordinaryPage] {
            XCTAssertLessThanOrEqual(PageSuggestions.suggestions(for: kind).count, 4)
        }
        XCTAssertEqual(PageSuggestion.allCases.filter(\.fillsComposer), [.searchForum])
        XCTAssertEqual(PageSuggestion.searchForum.composerText, "Search this forum ")
        XCTAssertEqual(PageSuggestion.summarizeThread.text, "Summarize this thread and replies")
    }

    // MARK: Routing

    func testThreadSuggestionsRunTheExistingEngines() {
        XCTAssertEqual(PageSuggestions.route(for: .summarizeThread, on: .forumThread), .summary)
        XCTAssertEqual(PageSuggestions.route(for: .readAloud, on: .forumThread), .podcast)
        XCTAssertEqual(PageSuggestions.route(for: .followReplies, on: .forumThread), .follow)
        XCTAssertEqual(PageSuggestions.route(for: .searchForum, on: .forumThread), .fillForResearch)
        XCTAssertEqual(PageSuggestions.route(for: .searchForum, on: .forumList), .fillForResearch)
    }

    func testEverythingElseGoesToTheAgent() {
        XCTAssertEqual(PageSuggestions.route(for: .worthReadingToday, on: .forumList), .agent)
        for suggestion in [PageSuggestion.summarizePage, .makeDark, .removeDistractions] {
            XCTAssertEqual(PageSuggestions.route(for: suggestion, on: .ordinaryPage), .agent)
        }
        // Off a built-in forum the old engines never run.
        XCTAssertEqual(PageSuggestions.route(for: .summarizeThread, on: .ordinaryPage), .agent)
        XCTAssertEqual(PageSuggestions.route(for: .searchForum, on: .ordinaryPage), .agent)
    }

    func testResearchQueryNeedsTheFilledStartAndMore() {
        XCTAssertEqual(PageSuggestions.researchQuery(from: "Search this forum for dark mode bugs"), "Search this forum for dark mode bugs")
        XCTAssertEqual(PageSuggestions.researchQuery(from: "  search this forum  rust  "), "search this forum  rust")
        XCTAssertNil(PageSuggestions.researchQuery(from: "Search this forum "))
        XCTAssertNil(PageSuggestions.researchQuery(from: "What about dark mode?"))
    }

    // MARK: Context hand-off

    func testFinishedResultsAreHandedOverOnce() throws {
        var session = TopicSession(siteURL: site, topicID: "7", url: URL(string: "\(site)/t/dark/7")!, title: "Dark mode")
        session.summary = "People want a dark theme; #3 explains the CSS."
        var run = AgentRun(siteURL: site, goal: "Search this forum for themes", provider: .openAI, model: "m")
        run.answer = "Three topics discuss themes."
        run.result = .completed
        let app = makeApp(sessions: [session], runs: [run])

        app.agentHandoffs = [
            .summary(topicKey: session.topicKey),
            .research(runID: run.id),
            .follow(title: "Dark mode", url: session.url),
            .research(runID: UUID())
        ]
        let context = try XCTUnwrap(app.takeAgentHandoffContext())
        XCTAssertTrue(context.contains("People want a dark theme"), context)
        XCTAssertTrue(context.contains("Three topics discuss themes."), context)
        XCTAssertTrue(context.contains("followed the thread \"Dark mode\""), context)
        XCTAssertTrue(app.agentHandoffs.isEmpty, "A deleted run is dropped, the rest are handed over.")
        XCTAssertNil(app.takeAgentHandoffContext(), "Each result goes along once.")

        // The same summary handed over again (e.g. a second Read it to me) is skipped.
        app.agentHandoffs = [.summary(topicKey: session.topicKey)]
        XCTAssertNil(app.takeAgentHandoffContext())
    }

    func testAMissingSummaryIsNotHandedOver() {
        let app = makeApp(sessions: [], runs: [])
        app.agentHandoffs = [.summary(topicKey: "nothing")]
        XCTAssertNil(app.takeAgentHandoffContext())
        XCTAssertTrue(app.agentHandoffs.isEmpty)
    }

    func testModelPromptPutsContextBeforeTheQuestion() {
        XCTAssertEqual(BrowserAgentSession.modelPrompt("Why?", context: nil), "Why?")
        XCTAssertEqual(BrowserAgentSession.modelPrompt("Why?", context: ""), "Why?")
        let prompt = BrowserAgentSession.modelPrompt("Why?", context: "Summary text")
        XCTAssertTrue(prompt.hasPrefix("Context from earlier"))
        XCTAssertTrue(prompt.hasSuffix("The user's message:\nWhy?"))
    }

    // MARK: - M3 Broken-page suggestion & script fix context

    func testBrokenPageSuggestionPlacementAndRouting() {
        XCTAssertEqual(PageSuggestion.pageBroken.text, "This page looks broken")
        XCTAssertEqual(PageSuggestion.pageBroken.accessibilityIdentifier, "suggestionPageBroken")
        XCTAssertFalse(PageSuggestion.pageBroken.fillsComposer)
        XCTAssertEqual(PageSuggestions.route(for: .pageBroken, on: .forumThread), .agent)
        XCTAssertEqual(PageSuggestions.route(for: .pageBroken, on: .ordinaryPage), .agent)

        // Absent when no active scripts run on the page (even if hasScriptErrors is true).
        XCTAssertFalse(
            PageSuggestions.suggestions(for: .ordinaryPage, hasActiveScripts: false, hasScriptErrors: true)
                .contains(.pageBroken)
        )
        XCTAssertEqual(
            PageSuggestions.suggestions(for: nil, hasActiveScripts: true, hasScriptErrors: true),
            []
        )

        // Last when active scripts have no recorded errors.
        XCTAssertEqual(
            PageSuggestions.suggestions(for: .ordinaryPage, hasActiveScripts: true, hasScriptErrors: false),
            [.summarizePage, .makeDark, .removeDistractions, .pageBroken]
        )
        XCTAssertEqual(
            PageSuggestions.suggestions(for: .forumThread, hasActiveScripts: true, hasScriptErrors: false).last,
            .pageBroken
        )

        // First only when the current page's scripts have recorded errors.
        XCTAssertEqual(
            PageSuggestions.suggestions(for: .ordinaryPage, hasActiveScripts: true, hasScriptErrors: true),
            [.pageBroken, .summarizePage, .makeDark, .removeDistractions]
        )
        XCTAssertEqual(
            PageSuggestions.suggestions(for: .forumThread, hasActiveScripts: true, hasScriptErrors: true).first,
            .pageBroken
        )
    }

    func testBrokenPageAndFixScriptAttachedBlocksCarrySnapshotScriptsAndErrors() {
        let snapshot = PageStateSnapshot(
            url: "https://news.example.org/story",
            textLength: 42,
            documentHeight: 844,
            isScrollable: false,
            linkCount: 1,
            formControlCount: 0,
            visibleImageCount: 0,
            pageErrorCount: 2
        )
        let cleanScript = UserScript(
            id: "reader-layout",
            name: "Reader Layout",
            matchRules: ["*://news.example.org/*"],
            css: "article { max-width: 65ch; }"
        )
        let brokenScript = UserScript(
            id: "comment-hider",
            name: "Comment Hider",
            matchRules: ["*://news.example.org/*"],
            js: "document.querySelector('.missing').remove();"
        )
        let runtimeError = ScriptRuntimeError(
            scriptID: "comment-hider",
            scriptName: "Comment Hider",
            message: "TypeError: null is not an object",
            line: 4,
            url: "https://news.example.org/story",
            occurredAt: Date(),
            count: 2
        )

        let brokenBlock = PageFeedbackContext.brokenPageBlock(
            snapshot: snapshot,
            activeScripts: [cleanScript, brokenScript],
            errorsByScriptID: ["comment-hider": runtimeError]
        )
        let brokenPrompt = BrowserAgentSession.modelPrompt(
            PageSuggestion.pageBroken.text,
            context: nil,
            attachedBlock: brokenBlock
        )
        XCTAssertTrue(brokenPrompt.contains("https://news.example.org/story"), brokenPrompt)
        XCTAssertTrue(brokenPrompt.contains("text 42 chars"), brokenPrompt)
        XCTAssertTrue(brokenPrompt.contains("Reader Layout (id: reader-layout) — latest error: none"), brokenPrompt)
        XCTAssertTrue(brokenPrompt.contains("Comment Hider (id: comment-hider) — latest error: TypeError: null is not an object (line 4)"), brokenPrompt)
        XCTAssertTrue(brokenPrompt.hasSuffix("The user's message:\nThis page looks broken"), brokenPrompt)

        var disabledScript = brokenScript
        disabledScript.isEnabled = false
        disabledScript.disabledReason = "Turned off after errors on 3 page loads in a row: TypeError: null is not an object"

        let fixBlock = PageFeedbackContext.fixScriptBlock(
            script: disabledScript,
            latestError: runtimeError
        )
        let fixPrompt = BrowserAgentSession.modelPrompt(
            "Fix the script \(disabledScript.name)",
            context: nil,
            attachedBlock: fixBlock
        )
        XCTAssertTrue(fixPrompt.contains("Comment Hider (id: comment-hider)"), fixPrompt)
        XCTAssertTrue(fixPrompt.contains("TypeError: null is not an object (line 4)"), fixPrompt)
        XCTAssertTrue(fixPrompt.contains("enabled: true"), fixPrompt)
        XCTAssertTrue(fixPrompt.hasSuffix("The user's message:\nFix the script Comment Hider"), fixPrompt)
    }

    private func makeApp(sessions: [TopicSession], runs: [AgentRun]) -> AppModel {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("state.json")
        let store = PersistentStore(fileURL: fileURL)
        try? store.save(AppSnapshot(sessions: sessions, agentRuns: runs))
        return AppModel(store: store)
    }
}
