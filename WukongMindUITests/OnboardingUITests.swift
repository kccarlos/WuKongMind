import XCTest

/// The first-run flow (design-unified.md §5): pick a model, open a site, try
/// the Agent once (`-dc-reset` shows it again; nothing is deleted).
final class OnboardingUITests: DCUITestCase {
    /// The progress dots read "Step N of 3: <title>".
    private func assertStep(
        _ number: Int,
        _ progress: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let prefix = "Step \(number) of 3"
        XCTAssertTrue(
            wait(timeout: 10) { progress.exists && progress.label.hasPrefix(prefix) },
            "Expected \(prefix)…, got “\(progress.label)”.",
            file: file,
            line: line
        )
    }

    private func suggestionButtons(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier IN %@", ["suggestion-tryReadable", "suggestion-tryHideClutter"]))
    }

    /// Terms → model → site → the Agent's first run over the browser.
    func testThreeStepsThroughToTheFirstRun() throws {
        let server = FixtureWordPressServer()
        try server.start()
        defer { server.stop() }
        let app = launch(["-dc-reset"])

        let termsGate = any(app, "termsGate")
        XCTAssertTrue(waitOrDump(termsGate, timeout: 20, in: app), "Terms of Use gate did not appear first on fresh launch.")
        let agree = app.switches["termsAgree"].firstMatch
        XCTAssertTrue(waitForHittable(agree))
        agree.tap()
        app.buttons["termsContinue"].tap()
        XCTAssertTrue(waitForGone(termsGate, timeout: 10), "Terms gate did not dismiss.")

        XCTAssertTrue(any(app, "onboarding").waitForExistence(timeout: 20), "The walkthrough did not appear.")
        let progress = any(app, "onboardingProgress")
        assertStep(1, progress)

        // 1 Pick a model: the Logo, the three providers and Other; Later goes on.
        XCTAssertTrue(any(app, "onboardingProvider-anthropic").waitForExistence(timeout: 5), "Anthropic is not offered first.")
        XCTAssertTrue(reveal(any(app, "onboardingProvider-other"), in: app), "Other provider is not offered.")
        XCTAssertTrue(reveal(any(app, "onboardingProvider-openrouter"), in: app), "OpenRouter is not offered.")
        XCTAssertTrue(reveal(any(app, "onboardingProvider-openai"), in: app), "OpenAI is not offered.")
        XCTAssertTrue(reveal(any(app, "onboardingAgentNotice"), in: app), "First-run notice about Agent acting on signed-in pages is missing.")
        capture("onboarding-step1-agent-notice")
        XCTAssertTrue(waitForHittable(app.buttons["onboardingContinue"]))
        let later = app.buttons["onboardingSkipStep"]
        XCTAssertTrue(waitForHittable(later))
        later.tap()

        // 2 Open a site: the address field and suggested sites; Back returns.
        assertStep(2, progress)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'onboardingSite-'"))
                .firstMatch.waitForExistence(timeout: 5),
            "No suggested sites."
        )
        let step2Shot = XCTAttachment(screenshot: app.screenshot())
        step2Shot.name = "onboarding-step2-starter-sites"
        step2Shot.lifetime = .keepAlways
        self.add(step2Shot)
        let back = app.buttons["onboardingBack"]
        XCTAssertTrue(waitForHittable(back))
        back.tap()
        assertStep(1, progress)
        later.tap()
        assertStep(2, progress)

        let field = app.textFields["onboardingSiteAddress"]
        XCTAssertTrue(waitForHittable(field))
        field.tap()
        // The bar tucks away while typing, so Go opens the address.
        field.typeText(server.baseURL + "\n")

        // 3 Try the Agent once: over the real browser, two suggestions; Skip
        // ends in the "You're set" card and Done closes it.
        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10), "The walkthrough did not close.")
        let panel = any(app, "onboardingTryPanel")
        XCTAssertTrue(waitOrDump(panel, timeout: 20, in: app), "Step 3 did not show.")
        assertStep(3, any(app, "onboardingProgress"))
        let skip = app.buttons["onboardingTrySkip"]
        XCTAssertTrue(waitForHittable(skip))
        skip.tap()
        let done = app.buttons["onboardingTryDone"]
        XCTAssertTrue(waitForHittable(done), "Skip did not show the You’re set card.")
        done.tap()
        XCTAssertTrue(waitForGone(panel, timeout: 5), "Done did not close the first run.")
    }

    /// Step 3 offers the two suggestions with a model, and the no-model card
    /// without one.
    func testStepThreeOffersSuggestionsOrAModelChoice() throws {
        let app = launch(["-dc-sample", "-dc-onboarding-step", "3"])
        let panel = any(app, "onboardingTryPanel")
        XCTAssertTrue(waitOrDump(panel, timeout: 20, in: app), "Step 3 did not show.")
        assertStep(3, any(app, "onboardingProgress"))
        XCTAssertTrue(app.buttons["onboardingTrySkip"].waitForExistence(timeout: 5))
        let suggestions = suggestionButtons(app)
        let setup = any(app, "providerSetupCard")
        XCTAssertTrue(
            wait(timeout: 5) { suggestions.count == 2 || setup.exists },
            "Neither the suggestions nor the model setup card showed."
        )
        if suggestions.count == 2 {
            XCTAssertTrue(any(app, "agentPromptInput").exists, "The shared Agent input box is missing.")
        }
        // Leave the first run closed for the other tests.
        app.buttons["onboardingTrySkip"].tap()
        XCTAssertTrue(waitOrDump(app.buttons["onboardingTryDone"], timeout: 10, in: app), "Skip did not show the You’re set card.")
        app.buttons["onboardingTryDone"].tap()
        XCTAssertTrue(waitForGone(panel, timeout: 5))
    }

    func testBackReturnsToTheModelStep() throws {
        let app = launch(["-dc-onboarding-step", "site"])
        let progress = any(app, "onboardingProgress")
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        assertStep(2, progress)
        let back = app.buttons["onboardingBack"]
        XCTAssertTrue(waitForHittable(back))
        back.tap()
        assertStep(1, progress)
        XCTAssertFalse(app.buttons["onboardingBack"].exists, "Step 1 has nothing to go back to.")
        // Leave the walkthrough completed for the other tests.
        let later = app.buttons["onboardingSkipStep"]
        XCTAssertTrue(waitForHittable(later))
        later.tap()
        let open = app.buttons["onboardingOpen"]
        XCTAssertTrue(waitForHittable(open))
    }

    /// The walkthrough has three steps, and the deleted ones are gone.
    func testOnlyThreeStepsExist() throws {
        let app = launch(["-dc-onboarding-step", "model"])
        let progress = any(app, "onboardingProgress")
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        XCTAssertTrue(progress.label.hasPrefix("Step 1 of 3"), "Got “\(progress.label)”.")
        XCTAssertFalse(any(app, "onboardingDigest").exists, "the daily digest step is gone")
        XCTAssertFalse(app.switches["onboardingSyncToggle"].exists, "the privacy and sync step is gone")
        XCTAssertFalse(any(app, "onboardingSkipAll").exists, "there is no Skip all")
    }

    func testOnboardingFooterStaysCompact() throws {
        try skipUnlessPhone("Checks iPhone onboarding footer proportions.")

        // Step 1 at AX5.
        let ax5 = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
        var app = launch(["-UIPreferredContentSizeCategoryName", ax5, "-dc-sample", "-dc-onboarding-step", "model"], orientation: .portrait)
        let axContinue = app.buttons["onboardingContinue"]
        XCTAssertTrue(axContinue.waitForExistence(timeout: 10))
        capture("ax5_phone_onb1")
        let axContinueMinY = axContinue.frame.minY
        let portraitHeight = app.windows.firstMatch.frame.height
        app.terminate()

        // Step 2 in landscape.
        app = launch(["-dc-sample", "-dc-onboarding-step", "site"], orientation: .landscapeLeft)
        let landOpen = app.buttons["onboardingOpen"]
        XCTAssertTrue(landOpen.waitForExistence(timeout: 10))
        capture("land_phone_onb2")
        let landOpenMinY = landOpen.frame.minY
        let landHeight = app.windows.firstMatch.frame.height

        XCTAssertGreaterThan(axContinueMinY, portraitHeight * 0.80, "Onboarding AX5 footer covered too much of the screen (minY \(axContinueMinY) of \(portraitHeight)).")
        XCTAssertGreaterThan(landOpenMinY, landHeight * 0.75, "Onboarding landscape footer covered too much of the screen (minY \(landOpenMinY) of \(landHeight)).")
    }

    func testProviderKeyLinkOpensInAppBrowserTab() throws {
        let app = launch(["-dc-sample", "-dc-onboarding-step", "model"])
        let onboarding = any(app, "onboarding")
        XCTAssertTrue(onboarding.waitForExistence(timeout: 20), "Onboarding did not appear.")

        let keyLink = app.buttons["getAPIKeyLink"]
        XCTAssertTrue(reveal(keyLink, in: app), "Get a key button is missing.")
        XCTAssertEqual(keyLink.label, "Get a key")
        capture("onboarding-get-a-key-button")
        keyLink.tap()

        let safariBar = app.otherElements["TopBrowserBar"]
        XCTAssertTrue(waitOrDump(safariBar, timeout: 15, in: app), "In-app Safari sheet did not appear after tapping Get a key.")
        XCTAssertEqual(app.state, .runningForeground, "Tapping Get a key left the app instead of opening an in-app web sheet.")
        capture("provider-key-in-app-sheet")

        let close = safariBar.buttons["Close"].firstMatch
        let dismissButton = close.exists ? close : app.buttons.matching(NSPredicate(format: "identifier IN %@", ["Done", "Close"])).firstMatch
        XCTAssertTrue(waitForHittable(dismissButton), "In-app Safari dismiss button is missing.")
        dismissButton.tap()
        XCTAssertTrue(waitForGone(safariBar, timeout: 10), "In-app Safari sheet did not dismiss.")
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10), "Onboarding did not remain visible with state intact.")
        assertStep(1, any(app, "onboardingProgress"))
    }

    func testFailedOnboardingKeyTestShowsFailureAndNoDoneRow() throws {
        let app = launch(["-dc-onboarding-step", "model", "-dc-no-provider"])
        let continueButton = app.buttons["onboardingContinue"]
        XCTAssertTrue(waitOrDump(continueButton, timeout: 20, in: app), "Onboarding Continue button did not appear.")
        continueButton.tap()

        let failure = any(app, "providerTestFailure")
        XCTAssertTrue(reveal(failure, in: app, swipes: 2), "Failed key test did not show cinnabar failure status.")
        XCTAssertFalse(any(app, "providerTestSuccess").exists, "Failed key test must not show the saved ring.")
        capture("onboarding-key-test-failed")
    }

    /// Clean launch with no key: accept Terms first, skip model selection, open a page,
    /// reach the setup card saying the Agent needs a key, open Settings › Models,
    /// and still browse normally after skipping step 3.
    func testNoKeyFirstRunReachesPageAndSetupCard() throws {
        let server = FixtureWordPressServer()
        try server.start()
        defer { server.stop() }
        let app = launch(["-dc-reset", "-dc-no-provider", "-dc-apple-intelligence", "on-device"])

        let termsGate = any(app, "termsGate")
        XCTAssertTrue(waitOrDump(termsGate, timeout: 20, in: app), "Terms of Use gate did not appear first.")
        let agree = app.switches["termsAgree"].firstMatch
        XCTAssertTrue(waitForHittable(agree))
        agree.tap()
        app.buttons["termsContinue"].tap()
        XCTAssertTrue(waitForGone(termsGate, timeout: 10))

        XCTAssertTrue(any(app, "onboarding").waitForExistence(timeout: 20), "The walkthrough did not appear.")
        let later = app.buttons["onboardingSkipStep"]
        XCTAssertTrue(waitForHittable(later))
        later.tap()

        let field = app.textFields["onboardingSiteAddress"]
        XCTAssertTrue(waitForHittable(field))
        field.tap()
        field.typeText(server.baseURL + "\n")

        XCTAssertTrue(waitForGone(any(app, "onboarding"), timeout: 10))
        let panel = any(app, "onboardingTryPanel")
        XCTAssertTrue(waitOrDump(panel, timeout: 20, in: app), "Step 3 did not show.")

        let setupCard = any(app, "providerSetupCard")
        if !setupCard.waitForExistence(timeout: 5) {
            let suggestion = app.buttons["suggestion-tryReadable"]
            XCTAssertTrue(waitForHittable(suggestion, timeout: 5))
            suggestion.tap()
        }
        XCTAssertTrue(waitOrDump(setupCard, timeout: 10, in: app), "Provider setup card did not appear without a key.")
        XCTAssertTrue(
            setupCard.staticTexts.matching(NSPredicate(format: "label CONTAINS 'API key'")).firstMatch.exists,
            "Setup card should state plainly that the Agent needs an API key."
        )
        XCTAssertTrue(
            setupCard.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Apple Intelligence only runs Summaries'")).firstMatch.exists,
            "Setup card should explain that Apple Intelligence only runs Summaries."
        )
        capture("no-key-setup-card")

        let settingsButton = app.buttons["providerSetupSettings"]
        XCTAssertTrue(waitForHittable(settingsButton))
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 10), "Tapping Models… did not open Settings › Models.")
        capture("no-key-settings-models")

        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Back from Models did not return to Settings.")
        closeSettings(in: app)
        XCTAssertTrue(waitOrDump(panel, timeout: 10, in: app))

        let skip = app.buttons["onboardingTrySkip"]
        XCTAssertTrue(waitForHittable(skip))
        skip.tap()
        let done = app.buttons["onboardingTryDone"]
        XCTAssertTrue(waitForHittable(done))
        done.tap()
        XCTAssertTrue(waitForGone(panel, timeout: 5))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "Browser web view should remain usable with no key.")
    }
}
