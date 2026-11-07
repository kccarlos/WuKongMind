import XCTest

/// The iPhone AI drawer on sample data (`-dc-sample`, a topic page): every
/// kind of root presentation shows over it and the drawer comes back at the
/// same height; the swipe rules (down from medium closes it; from large a
/// slow drag stops at medium, a flick closes it); the hint row over the bar.
/// The height comes from the DEBUG `drawerState` element; `-dc-test-present`
/// triggers the presentation.
final class DrawerUITests: DCUITestCase {
    private let sample = ["-dc-sample", "-dc-page-state", "topic"]

    /// A Settings page request (Start a Voice Chat without voice set up).
    func testSettingsRequestShowsOverTheDrawer() throws {
        let app = try launchWithDrawer(presenting: "settings", at: "large")
        let page = app.navigationBars["Voice"]
        XCTAssertTrue(waitOrDump(page, timeout: 20, in: app), "Settings › Voice did not show over the drawer.")
        tapNavigationBack(in: app)
        let done = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        assertDrawer(at: "large", in: app, after: page)
    }

    /// A full-screen cover (the DEBUG Settings cover stands in for the
    /// walkthrough and the Terms of Use).
    func testFullScreenCoverShowsOverTheDrawer() throws {
        let app = try launchWithDrawer(presenting: "cover", at: "medium")
        let done = app.buttons["debugSettingsDone"]
        XCTAssertTrue(waitOrDump(done, timeout: 20, in: app), "The cover did not show over the drawer.")
        done.tap()
        assertDrawer(at: "medium", in: app, after: done)
    }

    /// `presentedError`: the root alert.
    func testErrorAlertShowsOverTheDrawer() throws {
        let app = try launchWithDrawer(presenting: "error", at: "medium")
        let alert = app.alerts["Forumind"]
        XCTAssertTrue(waitOrDump(alert, timeout: 20, in: app), "The error alert did not show over the drawer.")
        XCTAssertTrue(alert.staticTexts["Test error"].exists)
        alert.buttons["OK"].tap()
        assertDrawer(at: "medium", in: app, after: alert)
    }

    /// A root sheet closed while the drawer waits to come back (asked for
    /// under the sheet): the drawer comes back, and a root alert still shows
    /// (the drawer never ends up half presented with neither host active).
    func testClosingARootSheetWhileTheDrawerIsPendingBringsItBack() throws {
        let app = try launchWithDrawer(presenting: "pending-drawer", at: "medium")
        let page = app.navigationBars["Voice"]
        XCTAssertTrue(waitOrDump(page, timeout: 20, in: app), "Settings › Voice did not show.")
        tapNavigationBack(in: app)
        let done = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 15, in: app), "The pending drawer did not come back.")
        let alert = app.alerts["Forumind"]
        XCTAssertTrue(waitOrDump(alert, timeout: 20, in: app), "The root alert did not show after the drawer came back.")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitForGone(alert, timeout: 10))
    }

    /// A drawer presentation that never reports its content (as when UIKit
    /// drops it) falls back after the watchdog: the root alert still shows
    /// and the drawer comes up.
    func testADroppedDrawerPresentationDoesNotBlockAlerts() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + ["-dc-drawer-drop-first", "-dc-test-present", "error", "-dc-test-present-after", "8"])
        let alert = app.alerts["Forumind"]
        XCTAssertTrue(waitOrDump(alert, timeout: 30, in: app), "The root alert was blocked by a dropped drawer.")
        XCTAssertTrue(alert.staticTexts["Test error"].exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 10), "The drawer did not come up.")
    }

    /// Report or block (a routed sheet).
    func testReportSheetShowsOverTheDrawer() throws {
        let app = try launchWithDrawer(presenting: "report", at: "large")
        let sheet = app.navigationBars["Report or block"]
        XCTAssertTrue(waitOrDump(sheet, timeout: 20, in: app), "The report sheet did not show over the drawer.")
        sheet.buttons["Done"].tap()
        assertDrawer(at: "large", in: app, after: sheet)
    }

    /// Two heights, no peek: the AI button opens the drawer at medium and a
    /// swipe down from medium closes it; from large a slow drag stops at
    /// medium and a flick closes it.
    func testSwipingDownClosesTheDrawer() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample)
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "Got \(state.label).")

        dragDrawer(in: app, to: 0.99)
        XCTAssertTrue(waitForGone(state, timeout: 5), "A swipe down from medium must close the drawer.")

        let button = app.buttons["aiButton"]
        XCTAssertTrue(waitForBarItem(button, timeout: 10), "The bar's AI button is missing.")
        tapBarItem(button)
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "The AI button opens the drawer at medium.")

        dragDrawer(in: app, to: 0.08)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" }, "Got \(state.label), wanted large.")
        dragDrawer(in: app, to: 0.55)
        XCTAssertTrue(wait(timeout: 5) { state.exists && state.label == "detent=medium" },
                      "A slow drag down from large must stop at medium; got \(state.label).")

        dragDrawer(in: app, to: 0.08)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" }, "Got \(state.label), wanted large.")
        flickDrawer(in: app)
        XCTAssertTrue(waitForGone(state, timeout: 5), "A flick down from large must close the drawer.")
        XCTAssertTrue(waitForBarItem(button, timeout: 10), "The bar did not come back.")
    }

    /// The first topic opened: the drawer stays closed and the hint row
    /// over the bar has the "Summarize this topic" tip. Its text opens the
    /// drawer at medium (and the tip has done its job); its button opens it
    /// and starts the summary (the DEBUG fake summary).
    func testTheHintRowOpensTheDrawerAndItsButtonSummarizes() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        try requireNetwork()
        let args = sample + ["-dc-drawer-first-run", "-dc-no-summary", "-dc-fake-summary"]
        var app = launch(args)
        var state = drawerState(in: app)
        let text = app.buttons["dockHintText"]
        XCTAssertTrue(waitOrDump(text, timeout: 20, in: app), "The first topic shows no hint row.")
        XCTAssertFalse(state.exists, "The first topic must not open the drawer.")
        XCTAssertEqual(text.label, "Summarize this topic")
        XCTAssertTrue(waitForHittable(text))
        text.tap()
        XCTAssertTrue(state.waitForExistence(timeout: 10), "The hint row's text did not open the drawer.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "Got \(state.label).")
        closeDrawer(in: app)
        XCTAssertTrue(waitForBarItem(app.buttons["aiButton"], timeout: 10))
        XCTAssertFalse(text.exists, "The tip shows once: gone after the drawer opened.")
        app.terminate()

        app = launch(args)
        state = drawerState(in: app)
        let button = app.buttons["dockHintAction"]
        XCTAssertTrue(waitOrDump(button, timeout: 20, in: app), "The hint row has no button.")
        XCTAssertEqual(button.label, "Summarize this topic")
        XCTAssertTrue(waitForHittable(button))
        button.tap()
        XCTAssertTrue(state.waitForExistence(timeout: 10), "The hint row's button did not open the drawer.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "Got \(state.label).")
        XCTAssertTrue(waitOrDump(app.buttons["citation-12"].firstMatch, timeout: 30, in: app),
                      "The summary did not start.")
    }

    /// §4.6: a topic with the drawer at medium → summarize (the DEBUG fake
    /// summary) → at large, tap `#12` → the page scrolls to post 12 and
    /// marks it, and the drawer steps down to medium. The sample page is the
    /// live meta topic 404728 (its posts 1–13 exist).
    func testCitationJumpScrollsThePageAndLowersTheDrawer() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        try requireNetwork()
        let app = launch(sample + ["-dc-no-summary", "-dc-fake-summary", "-dc-browse-debug"])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        XCTAssertTrue(wait(timeout: 8) { state.label == "detent=medium" }, "Got \(state.label).")
        let summarize = app.buttons["createSummary"].firstMatch
        XCTAssertTrue(waitForHittable(summarize), "Create summary is missing.")
        summarize.tap()

        let citation = app.buttons["citation-12"].firstMatch
        XCTAssertTrue(waitOrDump(citation, timeout: 30, in: app), "The summary has no #12 citation.")
        XCTAssertTrue(wait(timeout: 10) { app.buttons["retrySummary"].exists },
                      "The summary did not finish.")

        dragDrawer(in: app, to: 0.08)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" }, "Got \(state.label), wanted large.")
        if !citation.isHittable { app.swipeUp() }
        XCTAssertTrue(waitForHittable(citation))
        citation.tap()

        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" },
                      "A citation tap at large must lower the drawer to medium; got \(state.label).")
        let browse = any(app, "browseDebugState")
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "The browse state hook is missing.")
        let landed = wait(timeout: 40) {
            // Post 12 at the top (post 11's last pixels may still show under the header).
            (browse.label.hasSuffix("top=12") || browse.label.hasSuffix("top=11"))
                && browse.label.contains("highlighted=12 ")
        }
        attachText(browse.label, named: "browse state")
        XCTAssertTrue(landed, "The page did not scroll to post 12 and mark it: \(browse.label)")
    }

    /// A summary run that fails shows the error in the drawer with Retry;
    /// Retry writes the summary (`-dc-fake-summary-fails` fails until then).
    func testAFailedSummaryShowsItsErrorAndRetryWritesIt() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        try requireNetwork()
        let app = launch(sample + ["-dc-no-summary", "-dc-fake-summary", "-dc-fake-summary-fails", "-dc-browse-debug"])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        let summarize = app.buttons["createSummary"].firstMatch
        XCTAssertTrue(waitForHittable(summarize), "Create summary is missing.")
        summarize.tap()

        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 10) { alert.buttons["OK"].tap() }
        let retry = app.buttons["retryFailedSummary"].firstMatch
        XCTAssertTrue(waitOrDump(retry, timeout: 15, in: app), "A failed summary shows no Retry.")
        XCTAssertTrue(any(app, "summaryFailureMessage").exists, "The failure does not say what went wrong.")
        retry.tap()
        XCTAssertTrue(wait(timeout: 30) { app.buttons["retrySummary"].exists },
                      "Retry did not write the summary.")
        XCTAssertFalse(retry.exists, "The failure stays after a successful run.")
    }

    /// §5 and the citation chips (no network: `-dc-no-provider` fails a run
    /// at once). Text typed under This topic moves along to Whole forum and
    /// to a new question; the run it starts shows in History. The sample
    /// summary's `#3 #7` chips are 44 pt wide and at least 4 pt apart.
    func testAskBoxScopeKeepsTheTextAndAWholeForumRunShowsInHistory() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + ["-dc-no-provider"])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "Got \(state.label).")

        let first = app.buttons["citation-3"].firstMatch
        let second = app.buttons["citation-7"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "The sample summary has no #3 citation.")
        XCTAssertGreaterThanOrEqual(first.frame.width, 44, "A citation chip must be 44 pt wide to tap.")
        if second.exists, abs(second.frame.midY - first.frame.midY) < 4 {
            XCTAssertGreaterThanOrEqual(second.frame.minX - first.frame.maxX, 4, "Citation chips need 4 pt between them.")
        }

        let question = "Retention offers this year"
        let chat = app.textFields["chatInput"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "The Ask box has no field.")
        chat.tap()
        chat.typeText(question)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" }, "Focusing the field must raise the drawer.")

        let scope = any(app, "askScopeButton")
        XCTAssertTrue(waitForHittable(scope), "The Ask box has no scope button.")
        scope.tap()
        let wholeForum = app.buttons["Whole forum"].firstMatch
        XCTAssertTrue(wholeForum.waitForExistence(timeout: 5), "The scope menu has no Whole forum.")
        wholeForum.tap()

        // The sample's run on this forum is finished: the box follows it up.
        let followUp = app.textFields["agentFollowUpInput"]
        XCTAssertTrue(followUp.waitForExistence(timeout: 10), "Whole forum did not follow up the selected run.")
        XCTAssertEqual(followUp.value as? String, question, "Switching the scope lost the typed text.")
        XCTAssertFalse(app.textFields["chatInput"].exists)

        let newQuestion = app.buttons["agentNewQuestion"]
        if !newQuestion.isHittable { app.swipeDown() }
        XCTAssertTrue(waitForHittable(newQuestion), "New question is missing.")
        newQuestion.tap()
        let goal = app.textFields["agentGoalInput"]
        XCTAssertTrue(goal.waitForExistence(timeout: 10))
        XCTAssertEqual(goal.value as? String, question, "New question lost the typed text.")
        XCTAssertTrue(any(app, "agentExample").exists, "A new question shows the example questions.")

        let run = app.buttons["runAgent"]
        XCTAssertTrue(run.isEnabled)
        run.tap()
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) { alert.buttons["OK"].tap() }
        let runGoal = app.staticTexts["agentRunGoal"]
        XCTAssertTrue(runGoal.waitForExistence(timeout: 10), "The run did not show.")
        XCTAssertEqual(runGoal.label, question)

        // History lists the run under Asks.
        let more = app.buttons["assistantMoreMenu"]
        XCTAssertTrue(waitForHittable(more))
        more.tap()
        // Not Ask the forum's own History menu (agentHistoryMenu).
        let history = app.buttons
            .matching(NSPredicate(format: "label == 'History' AND identifier != 'agentHistoryMenu'"))
            .firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        let asks = app.buttons["historySegment-asks"]
        XCTAssertTrue(asks.waitForExistence(timeout: 10), "History did not open.")
        asks.tap()
        // Running it shows in progress, finished under Asks; either way the goal is listed.
        XCTAssertTrue(reveal(app.staticTexts[question], in: app), "The new run is not listed under Asks.")
    }

    /// "Answer ready" over the bar (iPhone: drawer closed; iPad split: panel
    /// hidden) brings the AI view forward on the run that finished, not the
    /// selected one, and the row goes (audit A1, A2).
    func testAnswerReadyShowsTheFinishedRunInTheAIView() throws {
        let app = launch(sample + ["-dc-answer-ready"], orientation: isPhone ? .portrait : .landscapeLeft)
        let split = !usesDrawerLayout(app)
        let panel = any(app, "aiPanel")
        if split {
            XCTAssertTrue(waitOrDump(panel, timeout: 20, in: app), "The sample did not show the panel.")
            // After the sample's second "show the assistant" (1.2 s in).
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            app.buttons["aiPanelToggle"].tap()
            XCTAssertTrue(waitForGone(panel, timeout: 5), "The panel did not hide.")
        } else {
            XCTAssertTrue(waitOrDump(drawerState(in: app), timeout: 20, in: app), "The sample did not open the drawer.")
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            closeDrawer(in: app)
        }
        let row = app.buttons["dockAnswerReady"]
        XCTAssertTrue(waitOrDump(row, timeout: 10, in: app), "No Answer ready row.")
        row.tap()
        if split {
            XCTAssertTrue(panel.waitForExistence(timeout: 5), "Answer ready did not show the panel.")
        } else {
            XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 10), "Answer ready did not open the drawer.")
        }
        let goal = app.staticTexts["agentRunGoal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 10), "Ask the forum did not show a run.")
        if Locale.preferredLanguages.first?.hasPrefix("en") ?? true {
            XCTAssertTrue(goal.label.contains("layer shifts"), "Not the finished run: \(goal.label)")
        }
        XCTAssertTrue(waitForGone(row, timeout: 5), "Answer ready stayed after it was shown.")
    }

    /// Pressing the software keyboard's Send key in the forum home Ask field
    /// submits Ask the forum instead of inserting a newline.
    func testForumHomeSendKeySubmitsAskTheForum() throws {
        let app = launch(["-dc-sample", "-dc-page-state", "forumHome", "-dc-no-provider"])
        showAssistant(in: app)
        let goalField = any(app, "forumHomeGoalInput")
        XCTAssertTrue(waitOrDump(goalField, timeout: 15, in: app))
        goalField.tap()
        let question = "best backup plugin"
        goalField.typeText(question)
        goalField.typeText("\n")

        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) { alert.buttons["OK"].tap() }
        XCTAssertTrue(waitForGone(any(app, "forumHomeState"), timeout: 5),
                      "Pressing Send on ForumHomeState goal field inserted a newline instead of starting Ask the forum.")
        let runGoal = app.staticTexts["agentRunGoal"]
        XCTAssertTrue(runGoal.waitForExistence(timeout: 10), "The Ask the forum run did not appear.")
        XCTAssertEqual(runGoal.label, question)
    }

    // MARK: Helpers

    private func launchWithDrawer(presenting kind: String, at detent: String) throws -> XCUIApplication {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + [
            "-dc-drawer-detent", detent,
            "-dc-test-present", kind, "-dc-test-present-after", "8"
        ])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        XCTAssertTrue(wait(timeout: 8) { state.label == "detent=\(detent)" }, "Got \(state.label), wanted \(detent).")
        return app
    }

    private func assertDrawer(at detent: String, in app: XCUIApplication, after presented: XCUIElement) {
        XCTAssertTrue(waitForGone(presented, timeout: 10), "The presentation did not close.")
        let state = drawerState(in: app)
        XCTAssertTrue(state.waitForExistence(timeout: 10), "The drawer did not come back.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=\(detent)" },
                      "The drawer came back at \(state.label), not \(detent).")
        // Still the drawer's content, not a copy at the root.
        XCTAssertTrue(any(app, "drawerHeader").exists)
    }

    func testPostsTranslationEmptyStateHasDoneButtonAndWordPressGating() throws {
        try skipUnlessPhone("iPhone forum menu translation check.")

        // 1. Empty-state PostsTranslationSheet shows Done and dismisses cleanly.
        var app = launch(sample + ["-dc-test-present", "translate-posts", "-dc-test-present-after", "1"])
        let navBar = app.navigationBars["Translate posts"]
        XCTAssertTrue(waitOrDump(navBar, timeout: 15, in: app))
        let done = app.buttons["translationDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(waitForGone(navBar, timeout: 5))
        app.terminate()

        // 2. WordPress post (pageBridge == nil) omits Translate from the forum menu.
        let server = FixtureWordPressServer()
        try server.start()
        defer { server.stop() }

        app = launch(["-dc-open", server.postURL, "-dc-fixture-model", server.baseURL])
        showAssistant(in: app)
        XCTAssertTrue(waitOrDump(app.buttons["createSummary"].firstMatch, timeout: 25, in: app))
        closeDrawer(in: app)
        openForumMenu(in: app)
        XCTAssertTrue(app.buttons["Watch this topic"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["menuTranslatePosts"].exists)
    }

    func testEditingChatQuestionKeepsHistoryUntilSubmittedAndSupportsCancel() throws {
        try skipUnlessPhone("iPhone drawer chat edit check.")
        let app = launch(sample + ["-dc-assistant-mode", "chat", "-dc-no-provider"])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        dragDrawer(in: app, to: 0.08)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" }, "Got \(state.label), wanted large.")

        let editButton = app.buttons["Edit"].firstMatch
        let chatScroll = app.scrollViews["chatScroll"].firstMatch
        for _ in 0..<8 where !(editButton.exists && editButton.isHittable) {
            if chatScroll.exists { chatScroll.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(waitForHittable(editButton, timeout: 5), "No Edit button on the sample user question.")

        let originalQuestion = "Can I roll it out to staff first?"
        editButton.tap()

        // Tapping Edit populates the composer, shows the Cancel banner, and keeps both chat turns intact.
        let banner = any(app, "chatEditBanner")
        let cancel = app.buttons["cancelChatEdit"]
        let chatField = app.textFields["chatInput"]
        XCTAssertTrue(waitOrDump(banner, timeout: 5, in: app), "Editing banner did not appear.")
        XCTAssertTrue(cancel.exists)
        XCTAssertGreaterThanOrEqual(cancel.frame.width, 44)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
        XCTAssertEqual(chatField.value as? String, originalQuestion)
        XCTAssertEqual(app.otherElements.matching(identifier: "chatMessage-user").count, 1)
        XCTAssertEqual(app.otherElements.matching(identifier: "chatMessage-assistant").count, 1)

        // Cancel leaves history untouched and clears the composer back to its prior draft.
        cancel.tap()
        XCTAssertTrue(waitForGone(banner, timeout: 5))
        XCTAssertEqual(app.otherElements.matching(identifier: "chatMessage-user").count, 1)
        XCTAssertEqual(app.otherElements.matching(identifier: "chatMessage-assistant").count, 1)

        // Edit again and submit: the old question and assistant reply are replaced by the edited turn.
        for _ in 0..<4 where !(editButton.exists && editButton.isHittable) {
            if chatScroll.exists { chatScroll.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(waitForHittable(editButton, timeout: 5))
        editButton.tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        chatField.tap()
        chatField.typeText(" Or moderators?")
        let send = app.buttons["Send question"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 4) { alert.buttons.firstMatch.tap() }

        XCTAssertTrue(waitForGone(banner, timeout: 5))
        XCTAssertEqual(app.otherElements.matching(identifier: "chatMessage-assistant").count, 0, "Old assistant reply must be removed when edited question is submitted.")
        XCTAssertTrue(app.staticTexts["Can I roll it out to staff first? Or moderators?"].waitForExistence(timeout: 5))
    }

    func testRealKeyboardKeepsChatVStackPinnedAtBottom() throws {
        try skipUnlessPhone("Tests iPhone drawer + software keyboard")
        let app = launch(
            ["-dc-sample", "-dc-page-state", "topic", "-dc-assistant-mode", "chat"],
            orientation: .portrait
        )
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app))
        dragDrawer(in: app, to: 0.08)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" })

        let jumpBtn = app.buttons["chatScrollToBottom"]
        if jumpBtn.waitForExistence(timeout: 1.5) && jumpBtn.isHittable {
            jumpBtn.tap()
        } else {
            let chatScroll = any(app, "chatScroll")
            if chatScroll.exists { chatScroll.swipeUp() }
        }
        XCTAssertTrue(waitForGone(jumpBtn, timeout: 5), "Reader starts at bottom with no scroll-to-bottom button")

        let input = any(app, "chatInput")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        if app.keyboards.keys.count == 0 {
            app.typeKey("k", modifierFlags: .command)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        XCTAssertFalse(
            jumpBtn.exists,
            "Raising software keyboard while pinned at bottom in ChatThread must keep latest reply pinned without showing chatScrollToBottom"
        )
    }
}
