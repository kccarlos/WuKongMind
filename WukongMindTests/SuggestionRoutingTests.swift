import Foundation
import XCTest
#if canImport(WukongMind)
@testable import WukongMind
#endif

/// Which suggestions a page shows, and that each one sends its text to the
/// Agent (One loop 9).
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

    func testOnlySearchFillsTheBoxAndEveryOtherSuggestionSends() {
        for suggestion in PageSuggestion.allCases {
            XCTAssertEqual(
                PageSuggestions.route(for: suggestion),
                suggestion == .searchForum ? .fill : .agent,
                "\(suggestion)"
            )
        }
    }

    // MARK: Tapped and typed parity (acceptance 2)

    /// Tapping a suggestion sends its text; the Agent's request is the same as
    /// typing that text, with no hand-off context.
    func testTappedAndTypedSuggestionsMakeTheSameAgentRequest() async throws {
        let sent = PageSuggestion.allCases.filter { PageSuggestions.route(for: $0) == .agent && $0 != .pageBroken }
        XCTAssertTrue(sent.contains(.summarizeThread) && sent.contains(.readAloud) && sent.contains(.followReplies))
        for suggestion in sent {
            let tapped = try await firstRequest(sending: suggestion.text)
            let typed = try await firstRequest(sending: "  \(suggestion.text)\n")
            XCTAssertEqual(tapped, typed, "\(suggestion)")
            XCTAssertEqual(tapped.messages.last, .user(suggestion.text), "\(suggestion)")
        }
    }

    func testSearchThisForumSendsTheCompletedTextAsTyped() async throws {
        XCTAssertEqual(PageSuggestions.route(for: .searchForum), .fill)
        let completed = PageSuggestion.searchForum.composerText + "dark mode bugs"
        let request = try await firstRequest(sending: completed)
        XCTAssertEqual(request.messages.last, .user("Search this forum dark mode bugs"))
    }

    /// What the model is sent for one turn: the system prompt, the tools, the messages.
    private struct AgentRequest: Equatable {
        let system: String
        let toolNames: [String]
        let messages: [AgentModelTurn]
    }

    private final class StubDriver: AgentPageDriving, @unchecked Sendable {
        func currentPageMetadata() async -> AgentPageMetadata {
            AgentPageMetadata(url: "https://forum.example.org/t/dark/7", title: "Dark mode")
        }
        func readPage(mode: PageReadMode, selector: String?, maxLength: Int?) async throws -> String { "" }
        func runJS(code: String, environment: AgentExecutionEnvironment, timeout: TimeInterval) async throws -> JSExecutionResult {
            JSExecutionResult(valueJSON: "true", consoleOutput: [], error: nil)
        }
        func injectCSS(css: String, id: String?) async throws -> CSSInjectionResult {
            CSSInjectionResult(sheetID: id ?? "s", appliedRootCount: 1)
        }
        func waitFor(selector: String?, milliseconds: Int?) async throws -> WaitForResult {
            WaitForResult(mode: .delay, matched: true, elapsedMs: 0, selector: selector)
        }
    }

    private func firstRequest(sending text: String) async throws -> AgentRequest {
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "ok", toolCalls: [], usage: AgentTokenUsage(inputTokens: 1, outputTokens: 1)))
        ])
        let session = BrowserAgentSession(
            pageDriver: StubDriver(),
            modelClient: client,
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
                    configuration: ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake-key"),
                    maxSteps: 3,
                    truncationLimit: 20_000,
                    customInstructions: "",
                    redactedSecrets: []
                )
            }
        )
        await session.sendAndWait(text)
        let request = try XCTUnwrap(client.recordedRequests.first)
        return AgentRequest(system: request.system, toolNames: request.tools.map(\.name), messages: request.messages)
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
        XCTAssertEqual(PageSuggestions.route(for: .pageBroken), .agent)

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
