import XCTest

/// App Review 1.2 & 4.7.1: Terms of Use gate before onboarding on first run,
/// in-app web sheet for first-run links, Terms link in Settings › About,
/// and "Report this answer" / "Report this summary" on AI output.
final class TermsAndReportUITests: DCUITestCase {
    private func safariDismissButton(in app: XCUIApplication) -> XCUIElement {
        let bar = app.otherElements["TopBrowserBar"]
        let close = bar.buttons["Close"].firstMatch
        if close.exists { return close }
        let done = bar.buttons["Done"].firstMatch
        if done.exists { return done }
        return app.buttons.matching(NSPredicate(format: "identifier IN %@", ["Done", "Close"])).firstMatch
    }

    private func acceptTerms(in app: XCUIApplication, captureName: String? = nil) {
        let termsGate = any(app, "termsGate")
        XCTAssertTrue(waitOrDump(termsGate, timeout: 20, in: app), "Terms of Use gate did not appear first on fresh launch.")
        XCTAssertFalse(any(app, "onboarding").exists, "Onboarding must not appear before Terms acceptance.")
        XCTAssertTrue(app.links["termsLink"].exists || any(app, "termsLink").exists, "Terms link is missing.")
        let continueButton = app.buttons["termsContinue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertFalse(continueButton.isEnabled, "Continue should stay disabled before agreeing.")
        if let captureName { capture(captureName) }

        let agreeSwitch = app.switches["termsAgree"].firstMatch
        XCTAssertTrue(waitForHittable(agreeSwitch), "Terms agreement toggle is missing.")
        agreeSwitch.tap()
        XCTAssertTrue(wait(timeout: 5) { continueButton.isEnabled }, "Continue did not enable after agreeing.")
        continueButton.tap()
        XCTAssertTrue(waitForGone(termsGate, timeout: 10), "Terms gate did not dismiss after Continue.")
    }

    /// First run presents the Terms of Use gate before onboarding, keeps Continue
    /// disabled until agreed, shows Step 1 after accepting, opens "Get a key" in an
    /// in-app SFSafariViewController sheet that returns to the same onboarding step
    /// on Done/Close, and proceeds to Step 3 without showing Terms again.
    func testFirstRunWaitsForTermsAcceptance() throws {
        let server = FixtureWordPressServer()
        try server.start()
        defer { server.stop() }

        let app = launch(["-dc-reset"])
        acceptTerms(in: app, captureName: "terms-first-light")

        let onboarding = any(app, "onboarding")
        XCTAssertTrue(waitOrDump(onboarding, timeout: 15, in: app), "Onboarding did not appear after accepting Terms.")
        let progress = any(app, "onboardingProgress")
        XCTAssertTrue(wait(timeout: 10) { progress.exists && progress.label.hasPrefix("Step 1 of 3") }, "Expected Step 1 of 3 after accepting Terms.")
        let anthropic = any(app, "onboardingProvider-anthropic")
        XCTAssertTrue(anthropic.waitForExistence(timeout: 5), "Anthropic provider row missing on Step 1.")
        if !anthropic.isSelected { anthropic.tap() }
        capture("onboarding-step1-light")

        // Tapping "Get a key" presents an in-app SFSafariViewController sheet and keeps state intact on Done/Close.
        let keyLink = app.buttons["getAPIKeyLink"]
        XCTAssertTrue(reveal(keyLink, in: app), "Get a key button is missing.")
        keyLink.tap()

        let safariBar = app.otherElements["TopBrowserBar"]
        XCTAssertTrue(waitOrDump(safariBar, timeout: 15, in: app), "In-app Safari view controller did not appear for Get a key.")
        XCTAssertEqual(app.state, .runningForeground, "Tapping Get a key left the app instead of opening an in-app web sheet.")
        capture("get-a-key-sheet-light")
        let dismissButton = safariDismissButton(in: app)
        XCTAssertTrue(waitForHittable(dismissButton), "In-app Safari dismiss button is missing.")
        dismissButton.tap()
        XCTAssertTrue(waitForGone(safariBar, timeout: 10), "In-app Safari sheet did not dismiss.")

        XCTAssertTrue(onboarding.waitForExistence(timeout: 10), "Onboarding did not remain visible after closing Get a key.")
        XCTAssertTrue(progress.label.hasPrefix("Step 1 of 3"), "Onboarding did not return to Step 1, got “\(progress.label)”.")
        XCTAssertTrue(anthropic.isSelected, "Selected provider state was lost after closing Get a key.")

        let later = app.buttons["onboardingSkipStep"]
        XCTAssertTrue(waitForHittable(later))
        later.tap()

        let field = app.textFields["onboardingSiteAddress"]
        XCTAssertTrue(waitForHittable(field))
        field.tap()
        field.typeText(server.baseURL + "\n")

        XCTAssertTrue(waitForGone(onboarding, timeout: 10), "Onboarding did not close after opening a site.")
        XCTAssertFalse(any(app, "termsGate").exists, "Terms gate must not appear a second time after onboarding.")
        XCTAssertTrue(waitOrDump(any(app, "onboardingTryPanel"), timeout: 15, in: app), "Step 3 did not appear after onboarding.")
    }

    /// Captures dark-mode first-run flow (Terms first -> Step 1 -> in-app Get a key sheet).
    func testFirstRunTermsAndGetAKeyInDarkMode() throws {
        let app = launch(["-dc-reset", "-AppleInterfaceStyle", "Dark"])
        acceptTerms(in: app, captureName: "terms-first-dark")

        let onboarding = any(app, "onboarding")
        XCTAssertTrue(waitOrDump(onboarding, timeout: 15, in: app), "Onboarding did not appear after accepting Terms in dark mode.")
        let anthropic = any(app, "onboardingProvider-anthropic")
        XCTAssertTrue(anthropic.waitForExistence(timeout: 5), "Anthropic provider row missing in dark mode.")
        if !anthropic.isSelected { anthropic.tap() }
        capture("onboarding-step1-dark")

        let keyLink = app.buttons["getAPIKeyLink"]
        XCTAssertTrue(reveal(keyLink, in: app), "Get a key button is missing.")
        keyLink.tap()

        let safariBar = app.otherElements["TopBrowserBar"]
        XCTAssertTrue(waitOrDump(safariBar, timeout: 15, in: app), "In-app Safari sheet did not appear in dark mode.")
        XCTAssertEqual(app.state, .runningForeground, "Tapping Get a key left the app in dark mode.")
        capture("get-a-key-sheet-dark")
        let dismissButton = safariDismissButton(in: app)
        XCTAssertTrue(waitForHittable(dismissButton), "In-app Safari dismiss button is missing in dark mode.")
        dismissButton.tap()
        XCTAssertTrue(waitForGone(safariBar, timeout: 10), "In-app Safari sheet did not dismiss in dark mode.")
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10), "Onboarding did not remain visible in dark mode.")
    }

    /// An Agent answer's menu has "Report this answer" and opens the report sheet,
    /// and a Summary's menu has "Report this summary".
    func testAnswerMenuHasReportThisAnswerAndSummaryHasReport() throws {
        let app = launch([
            "-dc-browser-agent-fixture-page",
            "-dc-browser-agent-demo", "recorded",
            "-dc-drawer-detent", "medium"
        ])
        if app.buttons["aiConsentAllow"].waitForExistence(timeout: 5) {
            app.buttons["aiConsentAllow"].tap()
        }
        showAssistant(in: app)

        let reply = any(app, "agentAssistantReply")
        XCTAssertTrue(waitOrDump(reply, timeout: 30, in: app), "Recorded Agent reply did not appear.")

        let answerMenu = app.buttons["agentAnswerMenu"].firstMatch
        XCTAssertTrue(reveal(answerMenu, in: app), "Agent answer menu button is missing.")
        answerMenu.tap()

        let reportAnswer = app.buttons["Report this answer"].firstMatch
        XCTAssertTrue(waitOrDump(reportAnswer, timeout: 5, in: app), "Report this answer is missing from the answer menu.")
        capture("agent-answer-menu")
        reportAnswer.tap()

        let reportForm = any(app, "aiOutputReportForm")
        XCTAssertTrue(waitOrDump(reportForm, timeout: 10, in: app), "Report form did not open from Report this answer.")
        capture("report-answer-form")
        app.buttons["reportNext"].tap()

        let fallbackDone = app.buttons["reportFallbackDone"]
        XCTAssertTrue(waitOrDump(fallbackDone, timeout: 10, in: app), "Report fallback/composer did not open.")
        capture("report-answer-draft")
        fallbackDone.tap()
        XCTAssertTrue(waitForGone(fallbackDone, timeout: 5))

        // Summary menu also offers Report this summary, and Settings › About links to Terms.
        let sampleApp = launch(["-dc-sample", "-dc-page-state", "topic"])
        if isPhone {
            XCTAssertTrue(waitOrDump(drawerState(in: sampleApp), timeout: 20, in: sampleApp), "Drawer did not open.")
        } else {
            showAssistant(in: sampleApp)
        }
        let summaryMenu = sampleApp.buttons["summaryMoreMenu"].firstMatch
        XCTAssertTrue(waitForHittable(summaryMenu, timeout: 15), "Summary more menu is missing.")
        summaryMenu.tap()
        let reportSummary = sampleApp.buttons["Report this summary"].firstMatch
        XCTAssertTrue(waitOrDump(reportSummary, timeout: 5, in: sampleApp), "Report this summary is missing from the summary menu.")
        capture("summary-report-menu")

        let settingsApp = launch(["-dc-sample", "-dc-show-settings", "help"])
        let aboutTerms = any(settingsApp, "settingsAboutTermsOfUse")
        for _ in 0..<6 where !aboutTerms.exists {
            settingsApp.swipeUp()
        }
        XCTAssertTrue(waitOrDump(aboutTerms, timeout: 10, in: settingsApp), "Terms of Use link missing in Settings › About.")
        capture("settings-about")
    }
}
