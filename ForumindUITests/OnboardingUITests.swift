import XCTest

/// The first-launch walkthrough (`-dc-reset` shows it again; nothing is deleted).
final class OnboardingUITests: DCUITestCase {
    func testWalkthroughPagesThroughToForumsHome() throws {
        let app = launch(["-dc-reset"])

        XCTAssertTrue(any(app, "onboarding").waitForExistence(timeout: 20), "The walkthrough did not appear.")
        let progress = any(app, "onboardingProgress")
        let next = app.buttons["onboardingContinue"]
        let skipStep = app.buttons["onboardingSkipStep"]

        // Welcome → Choose your AI.
        XCTAssertTrue(waitForHittable(next))
        XCTAssertFalse(skipStep.exists, "Welcome has nothing to skip.")
        next.tap()
        assertStep(2, progress)

        // Provider: Gemini is offered first; skip for now (nothing is tested).
        XCTAssertTrue(any(app, "onboardingProvider-gemini").waitForExistence(timeout: 5), "Google Gemini is not offered first.")
        XCTAssertTrue(waitForHittable(skipStep))
        skipStep.tap()
        assertStep(3, progress)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'onboardingForum-'"))
                .firstMatch.waitForExistence(timeout: 5),
            "The forums step lists no suggested forums."
        )

        // Forums: skip for now (pins nothing).
        XCTAssertTrue(waitForHittable(skipStep))
        skipStep.tap()
        assertStep(4, progress)

        // Your day: everything is off by default; skip.
        XCTAssertTrue(any(app, "onboardingDigest").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(skipStep))
        skipStep.tap()
        assertStep(5, progress)

        // Privacy needs the Terms of Use accepted; the iCloud toggle is here.
        XCTAssertTrue(app.switches["onboardingSyncToggle"].waitForExistence(timeout: 5))
        XCTAssertFalse(skipStep.exists, "Only the provider, forums and daily steps can be skipped.")
        XCTAssertFalse(next.isEnabled, "Continue works before the Terms of Use are accepted.")
        acceptTerms(app)
        XCTAssertTrue(waitForHittable(next))
        next.tap()

        // Done: "Browse (all) forums" is offered whether or not forums were pinned before.
        assertStep(6, progress)
        let browse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(browse), "The last step did not appear.")
        XCTAssertFalse(app.buttons["onboardingSkipAll"].isEnabled, "Skip is hidden on the last step.")
        browse.tap()

        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10), "The walkthrough did not close.")
        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 10), "Finishing did not land on the Forums home.")
        XCTAssertTrue(app.buttons["forumSwitcher"].exists)
    }

    func testSkipStopsAtTheTermsThenJumpsToTheLastStep() throws {
        let app = launch(["-dc-onboarding-step", "daily"])

        let skipAll = app.buttons["onboardingSkipAll"]
        XCTAssertTrue(waitForHittable(skipAll, timeout: 20), "Skip is missing on a middle step.")
        skipAll.tap()
        // The Terms of Use can't be skipped.
        assertStep(5, any(app, "onboardingProgress"))
        XCTAssertFalse(app.buttons["onboardingContinue"].isEnabled)
        skipAll.tap()
        assertStep(5, any(app, "onboardingProgress"))
        acceptTerms(app)
        skipAll.tap()
        let browse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(browse), "Skip did not jump to the last step.")

        // Back is hidden on the last step; finishing closes the walkthrough.
        XCTAssertFalse(app.buttons["onboardingBack"].isEnabled)
        browse.tap()
        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10))
        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 10))
    }

    func testBackReturnsToThePreviousStep() throws {
        let app = launch(["-dc-onboarding-step", "forums"])

        let progress = any(app, "onboardingProgress")
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        assertStep(3, progress)
        let back = app.buttons["onboardingBack"]
        XCTAssertTrue(waitForHittable(back))
        back.tap()
        assertStep(2, progress)
        // Leave the walkthrough completed for the other tests (Skip stops
        // at the Terms of Use first).
        let skipAll = app.buttons["onboardingSkipAll"]
        XCTAssertTrue(waitForHittable(skipAll))
        skipAll.tap()
        assertStep(5, progress)
        acceptTerms(app)
        XCTAssertTrue(waitForHittable(skipAll))
        skipAll.tap()
        let browse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(browse))
        browse.tap()
        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10))
    }

    func testDoneStepOpensTheShareHowToPage() throws {
        let app = launch(["-dc-onboarding-step", "done"])

        let row = app.buttons["onboardingShareHowTo"]
        let browse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(row, timeout: 20), "The Safari or Chrome row is missing.")
        // Scroll the row clear of the bottom buttons before tapping it.
        for _ in 0..<4 where row.frame.maxY > browse.frame.minY - 8 { app.swipeUp() }
        row.tap()
        let done = app.buttons["shareHowToDone"]
        for _ in 0..<4 where !(done.waitForExistence(timeout: 3) && done.isHittable) { app.swipeUp() }
        XCTAssertTrue(waitForHittable(done), "The Share how-to page did not open.")
        done.tap()
        // Leave the walkthrough completed for the other tests.
        XCTAssertTrue(waitForHittable(browse))
        browse.tap()
        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10))
    }

    func testReplayFromHomeReturnsToHomeAndBrowseAllMeetsHitTarget() throws {
        let server = FixtureWordPressServer()
        try server.start()
        defer { server.stop() }

        var app = launch(["-dc-sample", "-dc-onboarding-step", "done"])
        let browseAll = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(browseAll, timeout: 15))
        XCTAssertGreaterThanOrEqual(browseAll.frame.height, 44, "'Browse all forums' hit target must be at least 44 pt tall.")
        browseAll.tap()
        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10))
        app.terminate()

        app = launch(["-dc-sample", "-dc-open", server.postURL])
        showBrowser(in: app)
        XCTAssertTrue(waitOrDump(address(containing: "127.0.0.1", in: app), timeout: 15, in: app))
        openForumsHomeFromSwitcher(in: app)
        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 10))

        app.buttons["homeSettings"].tap()
        XCTAssertTrue(any(app, "settingsRoot").waitForExistence(timeout: 10))
        let helpRow = app.buttons.matching(label(contains: "Help")).firstMatch
        XCTAssertTrue(reveal(helpRow, in: app, swipes: 4))
        helpRow.tap()
        let replay = any(app, "replayOnboarding")
        XCTAssertTrue(reveal(replay, in: app, swipes: 4))
        let title = app.staticTexts["Help & about"].firstMatch
        for _ in 0..<3 where title.exists && replay.frame.minY < title.frame.maxY + 24 {
            let list = app.collectionViews.containing(.any, identifier: "replayOnboarding").firstMatch
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 90)))
        }
        XCTAssertTrue(waitForHittable(replay, timeout: 5))
        replay.tap()

        let continueBtn = app.buttons["onboardingContinue"]
        XCTAssertTrue(waitForHittable(continueBtn, timeout: 10))
        continueBtn.tap()
        let skipAll = app.buttons["onboardingSkipAll"]
        XCTAssertTrue(waitForHittable(skipAll, timeout: 10))
        skipAll.tap()
        XCTAssertTrue(waitForHittable(continueBtn, timeout: 10))
        continueBtn.tap()

        let returnButton = app.buttons["onboardingReturn"]
        XCTAssertTrue(waitForHittable(returnButton, timeout: 10))
        XCTAssertEqual(returnButton.label, "Back to Home")
        returnButton.tap()
        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 10))
    }

    func testUncheckingAddedForumAndSkippingLeavesItUnpinned() throws {
        let server = FixtureWordPressServer()
        try server.start()
        defer { server.stop() }

        let app = launch(["-dc-sample", "-dc-no-forums", "-dc-onboarding-step", "forums"])
        let addrField = app.textFields["onboardingForumAddress"]
        let footer = app.buttons["onboardingContinue"]
        XCTAssertTrue(footer.waitForExistence(timeout: 10))
        // isHittable passes for a field under the bottom bar: accessibility hit-testing
        // ignores the bar's background, but a tap lands on it and never focuses the field.
        for _ in 0..<4 where addrField.frame.maxY > footer.frame.minY - 8 { app.swipeUp() }
        XCTAssertTrue(waitForHittable(addrField, timeout: 10))
        addrField.tap()
        // Submit with the Go key rather than tapping Add: on iPad the keyboard
        // dismisses and re-presents while typing, shifting the card under the
        // button, so a tap can land on the pre-shift position.
        addrField.typeText(server.baseURL + "\n")

        let addedPredicate = NSPredicate(format: "identifier BEGINSWITH 'onboardingForum-127.0.0.1'")
        let addedRow = app.buttons.matching(addedPredicate).firstMatch
        for _ in 0..<4 where !addedRow.isHittable { app.swipeDown() }
        XCTAssertTrue(addedRow.waitForExistence(timeout: 10))
        XCTAssertEqual(addedRow.value as? String, "Pinned")
        addedRow.tap()
        XCTAssertTrue(wait(timeout: 3) { (addedRow.value as? String) == "Not pinned" })

        let skipStep = app.buttons["onboardingSkipStep"]
        XCTAssertTrue(waitForHittable(skipStep, timeout: 5))
        skipStep.tap()
        XCTAssertTrue(waitForHittable(skipStep, timeout: 5))
        skipStep.tap()

        acceptTerms(app)
        let continueBtn = app.buttons["onboardingContinue"]
        XCTAssertTrue(waitForHittable(continueBtn, timeout: 5))
        continueBtn.tap()

        let browse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(waitForHittable(browse, timeout: 10))
        browse.tap()
        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 10))

        let pinnedPredicate = NSPredicate(format: "identifier BEGINSWITH 'pinnedForum-127.0.0.1'")
        XCTAssertFalse(
            app.descendants(matching: .any).matching(pinnedPredicate).firstMatch.exists,
            "Unchecking an added custom forum on Step 3 and tapping 'Skip for now' still left it pinned on Home."
        )
    }

    func testOnboardingFooterStaysCompactAndDonePageHasBreathingRoom() throws {
        try skipUnlessPhone("Checks iPhone onboarding footer proportions and step 6 spacing.")

        // 1. Step 6 at base size (Finding 11): all cards stay clear of Browse forums.
        var app = launch(["-dc-sample", "-dc-no-forums", "-dc-onboarding-step", "done"], orientation: .portrait)
        let browse = app.buttons["onboardingBrowseForums"]
        let shareHowTo = app.buttons["onboardingShareHowTo"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        XCTAssertTrue(shareHowTo.waitForExistence(timeout: 5))
        capture("base_phone_onb6")
        let doneShareMaxY = shareHowTo.frame.maxY
        let doneBrowseMinY = browse.frame.minY
        app.terminate()

        // 2. Step 2 and Step 6 at AX5 (Finding 25).
        let ax5 = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
        app = launch(["-UIPreferredContentSizeCategoryName", ax5, "-dc-sample", "-dc-onboarding-step", "provider"], orientation: .portrait)
        let axContinue = app.buttons["onboardingContinue"]
        XCTAssertTrue(axContinue.waitForExistence(timeout: 10))
        capture("ax5_phone_onb2")
        let axStep2ContinueMinY = axContinue.frame.minY
        let portraitHeight = app.windows.firstMatch.frame.height
        app.terminate()

        app = launch(["-UIPreferredContentSizeCategoryName", ax5, "-dc-sample", "-dc-no-forums", "-dc-onboarding-step", "done"], orientation: .portrait)
        let axBrowse = app.buttons["onboardingBrowseForums"]
        XCTAssertTrue(axBrowse.waitForExistence(timeout: 10))
        capture("ax5_phone_onb6")
        let axDoneBrowseHeight = axBrowse.frame.height
        app.terminate()

        // 3. Step 2 in landscape (Finding 25).
        app = launch(["-dc-sample", "-dc-onboarding-step", "provider"], orientation: .landscapeLeft)
        let landContinue = app.buttons["onboardingContinue"]
        XCTAssertTrue(landContinue.waitForExistence(timeout: 10))
        capture("land_phone_onb2")
        let landContinueMinY = landContinue.frame.minY
        let landHeight = app.windows.firstMatch.frame.height

        XCTAssertLessThanOrEqual(doneShareMaxY, doneBrowseMinY - 12, "Step 6 cards collided with the Browse forums button (\(doneShareMaxY) vs \(doneBrowseMinY)).")
        XCTAssertGreaterThan(axStep2ContinueMinY, portraitHeight * 0.80, "Onboarding AX5 footer covered too much of the screen (minY \(axStep2ContinueMinY) of \(portraitHeight)).")
        XCTAssertLessThanOrEqual(axDoneBrowseHeight, 72, "Browse forums wrapped into a multi-line block at AX5 (\(axDoneBrowseHeight) pt).")
        XCTAssertGreaterThan(landContinueMinY, landHeight * 0.75, "Onboarding landscape footer covered too much of the screen (minY \(landContinueMinY) of \(landHeight)).")
    }

    /// The progress dots read "Step N of 6: <title>".
    private func assertStep(
        _ number: Int,
        _ progress: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let prefix = "Step \(number) of"
        XCTAssertTrue(
            wait(timeout: 10) { progress.exists && progress.label.hasPrefix(prefix) },
            "Expected \(prefix)…, got “\(progress.label)”.",
            file: file,
            line: line
        )
    }

    private func acceptTerms(_ app: XCUIApplication) {
        let agree = app.switches["termsAgree"]
        for _ in 0..<6 where !agree.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(agree), "The Terms of Use toggle is missing.")
        // "Hittable" under the floating Continue bar too: clear of it first.
        let bottomBar = app.buttons["onboardingContinue"]
        for _ in 0..<4 where bottomBar.exists && agree.frame.maxY > bottomBar.frame.minY - 8 {
            app.swipeUp()
        }
        // Tap the switch itself (right edge), not its label; again if missed.
        for _ in 0..<2 where (agree.value as? String) != "1" {
            agree.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            _ = wait(timeout: 2) { (agree.value as? String) == "1" }
        }
    }
}
