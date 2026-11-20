import XCTest

/// App Review 1.2 & 4.7.1: Terms of Use gate right after onboarding/consent,
/// Terms link in Settings › About, and "Report this answer" / "Report this summary"
/// on AI output.
final class TermsAndReportUITests: DCUITestCase {
    /// First run presents the Terms of Use gate right after onboarding finishes,
    /// keeps Continue disabled until agreed, and proceeds to Step 3 once accepted.
    func testFirstRunWaitsForTermsAcceptance() throws {
        let server = FixtureWordPressServer()
        try server.start()
        defer { server.stop() }

        let app = launch(["-dc-reset"])
        XCTAssertTrue(any(app, "onboarding").waitForExistence(timeout: 20), "Onboarding did not appear.")

        let later = app.buttons["onboardingSkipStep"]
        XCTAssertTrue(waitForHittable(later))
        later.tap()

        let field = app.textFields["onboardingSiteAddress"]
        XCTAssertTrue(waitForHittable(field))
        field.tap()
        field.typeText(server.baseURL + "\n")

        let termsGate = any(app, "termsGate")
        XCTAssertTrue(waitOrDump(termsGate, timeout: 15, in: app), "Terms of Use gate did not appear after onboarding.")
        XCTAssertTrue(app.links["termsLink"].exists || any(app, "termsLink").exists, "Terms link is missing.")
        let continueButton = app.buttons["termsContinue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertFalse(continueButton.isEnabled, "Continue should stay disabled before agreeing.")
        capture("terms-gate")

        let agreeSwitch = app.switches["termsAgree"].firstMatch
        XCTAssertTrue(waitForHittable(agreeSwitch), "Terms agreement toggle is missing.")
        agreeSwitch.tap()
        XCTAssertTrue(wait(timeout: 5) { continueButton.isEnabled }, "Continue did not enable after agreeing.")
        continueButton.tap()

        XCTAssertTrue(waitForGone(termsGate, timeout: 10), "Terms gate did not dismiss after Continue.")
        XCTAssertTrue(waitOrDump(any(app, "onboardingTryPanel"), timeout: 15, in: app), "Step 3 did not appear after accepting Terms.")
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
    }
}
