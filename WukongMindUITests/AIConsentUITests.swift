import XCTest

/// App Review 5.1.2(i) & 5.1.1(i): full-screen AI data consent page (Allow,
/// Don't Allow, Withdraw in Settings › Data & privacy), separate live voice
/// consent page, and Privacy Policy links.
final class AIConsentUITests: DCUITestCase {
    private let sample = ["-dc-sample", "-dc-page-state", "topic"]

    /// Before the first summary on an undecided provider: the consent page
    /// appears full screen; Allow closes it and proceeds with the summary.
    func testConsentPageShowsBeforeFirstSummaryAndAllowProceeds() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + ["-dc-no-summary", "-dc-fake-summary", "-dc-ask-ai-consent"])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")

        let summarize = app.buttons["suggestion-summarizeThread"].firstMatch
        XCTAssertTrue(waitForHittable(summarize, timeout: 15), "Summarize suggestion is missing.")
        summarize.tap()

        let page = any(app, "aiConsentPage")
        XCTAssertTrue(waitOrDump(page, timeout: 10, in: app), "The consent page did not show before the summary.")
        let title = any(app, "aiConsentTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Send web page content to Anthropic?")
        XCTAssertTrue(app.links["aiConsentTerms"].exists || any(app, "aiConsentTerms").exists, "Provider terms link is missing.")
        XCTAssertTrue(app.links["aiConsentAppPrivacy"].exists || any(app, "aiConsentAppPrivacy").exists, "App privacy policy link is missing.")
        capture("ai-consent-page")
        XCTAssertFalse(any(app, "capabilityThreadSummaryCard").exists, "Nothing may run before the answer.")

        app.buttons["aiConsentAllow"].tap()
        XCTAssertTrue(waitForGone(page, timeout: 10), "Allow did not close the page.")
        XCTAssertTrue(waitOrDump(any(app, "capabilityThreadSummaryCard"), timeout: 30, in: app), "The summary did not run after Allow.")
    }

    /// Don't Allow blocks the summary; Settings › Data & privacy allows
    /// granting and withdrawing consent, and links the Privacy Policy.
    func testConsentDeclineAndWithdrawInSettings() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + ["-dc-no-summary", "-dc-fake-summary", "-dc-ask-ai-consent"])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")

        let summarize = app.buttons["suggestion-summarizeThread"].firstMatch
        XCTAssertTrue(waitForHittable(summarize, timeout: 15), "Summarize suggestion is missing.")
        summarize.tap()

        let page = any(app, "aiConsentPage")
        XCTAssertTrue(waitOrDump(page, timeout: 10, in: app), "The consent page did not show.")
        app.buttons["aiConsentDecline"].tap()
        XCTAssertTrue(waitForGone(page, timeout: 10), "Don't Allow did not close the page.")
        XCTAssertFalse(any(app, "capabilityThreadSummaryCard").exists, "Summary must not run after Don't Allow.")

        // Open Settings › Data & privacy to allow, then withdraw.
        let app2 = launch(sample + ["-dc-show-settings", "data", "-dc-ask-ai-consent"])
        let privacyLink = any(app2, "settingsDataPrivacyPolicy")
        XCTAssertTrue(waitOrDump(privacyLink, timeout: 15, in: app2), "Privacy Policy link missing in Settings › Data & privacy.")

        let allowButton = app2.buttons["aiConsentAllow-anthropic"].firstMatch
        XCTAssertTrue(waitForHittable(allowButton, timeout: 10), "Allow… button for Anthropic is missing.")
        captureIfRequested("settings-data-before-allow")
        allowButton.tap()

        let sheetPage = any(app2, "aiConsentPage")
        XCTAssertTrue(waitOrDump(sheetPage, timeout: 10, in: app2), "Consent page did not open from Settings.")
        app2.buttons["aiConsentAllow"].tap()
        XCTAssertTrue(waitForGone(sheetPage, timeout: 10), "Allow did not close the consent page.")

        let withdrawButton = app2.buttons["aiConsentWithdraw-anthropic"].firstMatch
        XCTAssertTrue(waitForHittable(withdrawButton, timeout: 10), "Withdraw button did not appear after Allow.")
        capture("settings-data-after-allow")
        withdrawButton.tap()
        XCTAssertTrue(waitForHittable(allowButton, timeout: 10), "Allow… button did not return after Withdraw.")

        // Verify Privacy Policy link in Settings › Help / About (near the bottom of the Form).
        let app3 = launch(sample + ["-dc-show-settings", "help"])
        let aboutPrivacy = any(app3, "settingsAboutPrivacyPolicy")
        for _ in 0..<6 where !aboutPrivacy.exists {
            app3.swipeUp()
        }
        XCTAssertTrue(waitOrDump(aboutPrivacy, timeout: 10, in: app3), "Privacy Policy link missing in Settings › Help / About.")
        capture("settings-about-privacy-link")
    }

    /// Separate live voice consent page shows before starting voice.
    func testVoiceConsentPageShowsBeforeVoice() throws {
        try skipUnlessPhone("The browser bar voice button is an iPhone behavior.")
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-voice-fake", "-dc-ask-voice-consent"])
        let mic = app.buttons.matching(identifier: "voiceButton").firstMatch
        if waitForBarItem(mic, timeout: 5) {
            tapBarItem(mic)
        } else {
            let ai = app.buttons["aiButton"]
            XCTAssertTrue(waitForBarItem(ai, timeout: 10), "Neither voiceButton nor aiButton found.")
            pressBarItem(ai, duration: 1.0)
        }

        let page = any(app, "voiceConsentPage")
        XCTAssertTrue(waitOrDump(page, timeout: 10, in: app), "Live voice consent page did not appear.")
        let title = any(app, "voiceConsentTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Send microphone audio to Google AI Studio?")
        XCTAssertTrue(app.links["voiceConsentAppPrivacy"].exists || any(app, "voiceConsentAppPrivacy").exists, "App privacy policy link is missing on voice consent page.")
        capture("voice-consent-page")

        app.buttons["voiceConsentDecline"].tap()
        XCTAssertTrue(waitForGone(page, timeout: 10), "Don't Allow did not close voice consent page.")
    }

    /// WUKO-205: Agent on one provider (Google Vertex AI) and Summaries on another
    /// (Anthropic). After allowing the Agent's provider, `summarize_topic` shows the
    /// consent page for the second provider, and Allow completes the summary card.
    func testAgentToolOnSecondProviderAsksForConsentAndProceedsAfterAllow() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(
            sample + [
                "-dc-no-summary",
                "-dc-fake-summary",
                "-dc-agent-model", "vertexai:gemini-2.5-flash",
                "-dc-ask-ai-consent"
            ]
        )
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")

        let summarize = app.buttons["suggestion-summarizeThread"].firstMatch
        XCTAssertTrue(waitForHittable(summarize, timeout: 15), "Summarize suggestion is missing.")
        summarize.tap()

        // 1. Agent's provider (Google Vertex AI) asks first.
        let page = any(app, "aiConsentPage")
        XCTAssertTrue(waitOrDump(page, timeout: 10, in: app), "Consent page for the Agent's provider did not appear.")
        let title = any(app, "aiConsentTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Send web page content to Google Vertex AI?")
        app.buttons["aiConsentAllow"].tap()

        // 2. `summarize_topic` uses Summaries' provider (Anthropic), which asks next.
        let secondTitle = app.staticTexts["Send web page content to Anthropic?"].firstMatch
        XCTAssertTrue(
            waitOrDump(secondTitle, timeout: 15, in: app),
            "Consent page for the tool's second provider (Anthropic) did not appear."
        )
        capture("wuko205-second-provider-consent")
        XCTAssertFalse(any(app, "capabilityThreadSummaryCard").exists, "Summary must not run before allowing the second provider.")

        app.buttons["aiConsentAllow"].tap()
        XCTAssertTrue(waitForGone(page, timeout: 10), "Allow did not close the second consent page.")
        XCTAssertTrue(waitOrDump(any(app, "capabilityThreadSummaryCard"), timeout: 30, in: app), "Summary card did not appear after allowing the second provider.")
        capture("wuko205-after-allow-summary")
    }
}
