import XCTest

/// One panel 2b: the suggestion row per page kind and the thread
/// suggestions that run the existing engines (DEBUG sample, no network AI).
final class SuggestionRowUITests: DCUITestCase {
    private let thread = ["-dc-sample", "-dc-page-state", "topic", "-dc-not-following"]

    private func chip(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons["suggestion-\(id)"].firstMatch
    }

    /// The row scrolls sideways: swipe until the chip can be tapped.
    @discardableResult
    private func scrollToChip(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let element = chip(app, id)
        XCTAssertTrue(waitOrDump(element, timeout: 20, in: app), "Missing suggestion \(id).")
        var swipes = 0
        while !element.isHittable, swipes < 4 {
            any(app, "suggestionRow").swipeLeft()
            swipes += 1
        }
        XCTAssertTrue(waitForHittable(element), "Suggestion \(id) cannot be tapped.")
        return element
    }

    private func expectChips(_ ids: [String], absent: [String] = [], in app: XCUIApplication) {
        for id in ids {
            XCTAssertTrue(waitOrDump(chip(app, id), timeout: 20, in: app), "Missing suggestion \(id).")
        }
        for id in absent {
            XCTAssertFalse(chip(app, id).exists, "Suggestion \(id) must not show here.")
        }
    }

    func testForumThreadShowsFourSuggestions() {
        let app = launch(thread + ["-dc-no-summary"])
        showAssistant(in: app)
        expectChips(["summarizeThread", "readAloud", "searchForum", "followReplies"], absent: ["summarizePage"], in: app)
        captureIfRequested("suggestions-forum-thread")
    }

    func testForumListShowsListSuggestions() {
        let app = launch(["-dc-sample", "-dc-page-state", "forumHome"])
        showAssistant(in: app)
        expectChips(["worthReadingToday", "searchForum"], absent: ["summarizeThread", "followReplies"], in: app)
        captureIfRequested("suggestions-forum-list")
    }

    func testOrdinaryPageShowsPageSuggestions() {
        let app = launch(["-dc-sample", "-dc-page-state", "notForum"])
        showAssistant(in: app)
        expectChips(["summarizePage", "makeDark", "removeDistractions"], absent: ["summarizeThread", "searchForum"], in: app)
        XCTAssertFalse(app.buttons["suggestionPageBroken"].exists, "suggestionPageBroken must not show without active scripts.")
        captureIfRequested("suggestions-ordinary-page")
    }

    func testPageBrokenSuggestionPromotesFirstWhenCurrentPageScriptsHaveErrors() {
        let app = launch([
            "-dc-browser-agent-demo", "empty",
            "-dc-scripts-sample", "page-error",
            "-dc-drawer-detent", "large"
        ])
        showAssistant(in: app)
        let broken = app.buttons["suggestionPageBroken"].firstMatch
        XCTAssertTrue(waitOrDump(broken, timeout: 20, in: app), "Missing suggestionPageBroken.")
        XCTAssertTrue(waitForHittable(broken), "suggestionPageBroken must sit first and hittable without scrolling when scripts have errors.")
    }

    // The two read-aloud tests use `-dc-podcast-fake` (silent audio): the real
    // AVSpeechSynthesizer starves the app's main thread on a CI runner, so UI
    // queries time out and the next launch fails (main CI 44130863162). They
    // test the flow, not the voice.

    /// Summarize runs `summarize_topic` (summary card under its row); Read it to me then runs `read_aloud`.
    func testSummarizeThenReadAloudUseTheExistingEngines() {
        let app = launch(thread + ["-dc-no-summary", "-dc-fake-summary", "-dc-podcast-fake"])
        showAssistant(in: app)
        scrollToChip(app, "summarizeThread").tap()
        XCTAssertTrue(any(app, "capabilityThreadSummaryCard").waitForExistence(timeout: 30), "Missing summary card under summarize_topic.")
        captureIfRequested("suggestion-summary-done")

        let read = scrollToChip(app, "readAloud")
        read.tap()
        let listenRow = any(app, "capabilityListenRow")
        XCTAssertTrue(listenRow.waitForExistence(timeout: 15), "Missing listen card under read_aloud.")
        XCTAssertTrue(
            wait(timeout: 15) { (listenRow.value as? String) == "Pause" },
            "Read it to me did not start reading the summary aloud."
        )
        captureIfRequested("suggestion-read-aloud")
    }

    /// Read it to me with no summary yet: it summarizes first, then reads.
    func testReadAloudWithoutASummarySummarizesFirst() {
        let app = launch(thread + ["-dc-no-summary", "-dc-fake-summary", "-dc-podcast-fake"])
        showAssistant(in: app)
        scrollToChip(app, "readAloud").tap()
        let listenRow = any(app, "capabilityListenRow")
        XCTAssertTrue(listenRow.waitForExistence(timeout: 30), "Read it to me did not summarize and start listen row.")
        XCTAssertTrue(
            wait(timeout: 15) { (listenRow.value as? String) == "Pause" },
            "The summary was not read aloud once written."
        )
        if usesDrawerLayout(app) { dragDrawer(in: app, to: 0.08) }
        any(app, "agentScroll").swipeDown()
        XCTAssertTrue(any(app, "summaryContent").waitForExistence(timeout: 5), "Read it to me did not write the summary.")
    }

    /// Notify me follows the thread: the Agent says "Following.", the switch
    /// in This page is on, and the suggestion is gone.
    func testNotifyMeFollowsTheThread() {
        let app = launch(thread)
        showAssistant(in: app)
        let follow = scrollToChip(app, "followReplies")
        follow.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        let reply = app.staticTexts.matching(label(contains: "Following.")).firstMatch
        // A fresh simulator asks for notification permission, and the agent
        // waits for the answer. The alert can come late on a slow runner, so
        // tap Allow whenever it shows up while waiting for the reply.
        let followed = wait(timeout: 60) {
            if allow.exists { allow.tap() }
            return reply.exists
        }
        if !followed { attachTree(app) }
        XCTAssertTrue(followed, "No Following confirmation.")
        XCTAssertTrue(waitForGone(follow, timeout: 5), "Notify me stays after following.")
        captureIfRequested("suggestion-following")

        app.buttons["pageCapabilitiesSeal"].firstMatch.tap()
        let toggle = app.switches["pageTopicFollowing"].firstMatch
        XCTAssertTrue(waitOrDump(toggle, timeout: 10, in: app), "This page has no Following switch.")
        XCTAssertEqual(toggle.value as? String, "1", "The Following switch is off after Notify me.")
    }

    /// Search this forum… fills the box; sending routes the completed query to the one Agent conversation.
    func testSearchThisForumFillsTheBoxThenSendsToAgent() {
        let app = launch(thread)
        showAssistant(in: app)
        scrollToChip(app, "searchForum").tap()
        let input = app.textViews["agentPromptInput"].exists ? app.textViews["agentPromptInput"] : app.textFields["agentPromptInput"]
        XCTAssertTrue(wait(timeout: 5) { (input.value as? String) == "Search this forum " }, "Got \(String(describing: input.value)).")
        XCTAssertFalse(chip(app, "summarizeThread").exists, "The row hides once the box has text.")
        input.typeText("for streaming bugs")
        app.buttons["agentSendButton"].tap()
        let userTurn = any(app, "agentUserMessage")
        XCTAssertTrue(waitOrDump(userTurn, timeout: 15, in: app), "The search did not send to the Agent.")
        XCTAssertTrue(app.staticTexts.matching(label(contains: "Search this forum for streaming bugs")).firstMatch.exists)
        captureIfRequested("suggestion-search-agent")
    }
}
