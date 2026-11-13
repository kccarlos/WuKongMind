import XCTest

/// One panel 2b: the suggestion row per page kind and the thread
/// suggestions that run the existing engines (DEBUG sample, no network AI).
final class SuggestionRowUITests: DCUITestCase {
    private let thread = ["-dc-sample", "-dc-page-state", "topic", "-dc-not-following"]

    private func chip(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons["suggestion-\(id)"].firstMatch
    }

    /// The row scrolls sideways: swipe until the chip can be tapped.
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
        capture("suggestions-forum-thread")
    }

    func testForumListShowsListSuggestions() {
        let app = launch(["-dc-sample", "-dc-page-state", "forumHome"])
        showAssistant(in: app)
        expectChips(["worthReadingToday", "searchForum"], absent: ["summarizeThread", "followReplies"], in: app)
        capture("suggestions-forum-list")
    }

    func testOrdinaryPageShowsPageSuggestions() {
        let app = launch(["-dc-sample", "-dc-page-state", "notForum"])
        showAssistant(in: app)
        expectChips(["summarizePage", "makeDark", "removeDistractions"], absent: ["summarizeThread", "searchForum"], in: app)
        capture("suggestions-ordinary-page")
    }

    /// Summarize runs the summary engine; Read it to me then reads it aloud.
    func testSummarizeThenReadAloudUseTheExistingEngines() {
        let app = launch(thread + ["-dc-no-summary", "-dc-fake-summary"])
        showAssistant(in: app)
        let summarize = scrollToChip(app, "summarizeThread")
        summarize.tap()
        XCTAssertTrue(wait(timeout: 30) { app.buttons["retrySummary"].exists }, "The summary did not finish.")
        capture("suggestion-summary-done")

        let read = scrollToChip(app, "readAloud")
        read.tap()
        XCTAssertTrue(
            wait(timeout: 15) { app.buttons.matching(label(contains: "Pause")).firstMatch.exists },
            "Read it to me did not start reading the summary aloud."
        )
        capture("suggestion-read-aloud")
    }

    /// Notify me follows the thread: the Agent says "Following", the switch
    /// in This page is on, and the suggestion is gone.
    func testNotifyMeFollowsTheThread() {
        let app = launch(thread)
        showAssistant(in: app)
        let follow = scrollToChip(app, "followReplies")
        follow.tap()
        let reply = app.staticTexts.matching(label(contains: "Following.")).firstMatch
        XCTAssertTrue(waitOrDump(reply, timeout: 10, in: app), "No Following confirmation.")
        XCTAssertTrue(waitForGone(follow, timeout: 5), "Notify me stays after following.")
        // The existing follow asks for notification permission.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        capture("suggestion-following")

        app.buttons["pageCapabilitiesSeal"].firstMatch.tap()
        let toggle = app.switches["pageTopicFollowing"].firstMatch
        XCTAssertTrue(waitOrDump(toggle, timeout: 10, in: app), "This page has no Following switch.")
        XCTAssertEqual(toggle.value as? String, "1", "The Following switch is off after Notify me.")
    }

    /// Search this forum… fills the box; the completed search starts the
    /// old Research loop (its run shows in the conversation).
    func testSearchThisForumFillsTheBoxThenRunsResearch() {
        let app = launch(thread)
        showAssistant(in: app)
        let search = scrollToChip(app, "searchForum")
        search.tap()
        let input = app.textViews["agentPromptInput"].exists ? app.textViews["agentPromptInput"] : app.textFields["agentPromptInput"]
        XCTAssertTrue(wait(timeout: 5) { (input.value as? String) == "Search this forum " }, "Got \(String(describing: input.value)).")
        XCTAssertFalse(chip(app, "summarizeThread").exists, "The row hides once the box has text.")
        input.typeText("for streaming bugs")
        app.buttons["agentSendButton"].tap()
        let run = app.staticTexts.matching(label(contains: "Search this forum for streaming bugs")).firstMatch
        XCTAssertTrue(waitOrDump(run, timeout: 15, in: app), "The search did not start a Research run.")
        XCTAssertFalse(app.descendants(matching: .any)["agentUserMessage"].exists, "The search went to the Agent instead.")
        // The sample's placeholder key makes the real Research call fail.
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 10) { alert.buttons.firstMatch.tap() }
        if !run.isHittable { app.swipeUp() }
        capture("suggestion-research")
    }
}
