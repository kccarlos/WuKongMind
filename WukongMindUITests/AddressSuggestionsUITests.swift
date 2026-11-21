import XCTest

/// Motion task 5 (docs/wukongmind/design-motion.md §3 & §4):
/// - Typing replaces Home with local suggestions (no network while typing)
/// - Question + Return on a page opens the AI panel and aiButton reads "Working"
/// - Question + Return without AI consent shows the consent page first (App Store task 2)
/// - Search + Return opens the configured search engine
/// - Empty tab never shows "Ask the Agent"
/// - With no model, Question + Return opens the panel with the setup card
final class AddressSuggestionsUITests: DCUITestCase {
    private var server: FixtureWordPressServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = FixtureWordPressServer()
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        super.tearDown()
    }

    private func openAddressField(in app: XCUIApplication) -> XCUIElement {
        let title = app.buttons["browserTitle"]
        XCTAssertTrue(waitForBarItem(title, timeout: 15), "browserTitle did not appear")
        XCTAssertTrue(waitForHittable(title, timeout: 5), "browserTitle not hittable")
        tapBarItem(title)
        let field = app.textFields["addressField"]
        XCTAssertTrue(waitOrDump(field, timeout: 5, in: app), "addressField did not appear")
        return field
    }

    private func dismissDrawer(in app: XCUIApplication) {
        let header = any(app, "drawerHeader")
        guard header.waitForExistence(timeout: 5) else { return }
        let start = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        if !waitForGone(header, timeout: 4) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            if header.exists {
                let retryStart = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                retryStart.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            }
        }
        XCTAssertTrue(waitForGone(header, timeout: 5), "Drawer did not close")
    }

    /// Typing a question on a page shows "Ask the Agent" without sending any
    /// request while typing; pressing Return opens the panel and starts the run
    /// (`aiButton` reads "Working").
    func testQuestionTypingSendsNoRequestAndReturnStartsAgent() throws {
        try skipUnlessPhone("Motion task 5 iPhone address suggestions")
        var chatRequests = 0
        server.toolChatHandler = { messages in
            chatRequests += 1
            let toolResults = messages.filter { ($0["role"] as? String) == "tool" }.count
            if toolResults == 0 {
                let call: [String: Any] = [
                    "id": "call_wait_m5",
                    "function": ["name": "wait_for", "arguments": ["ms": 8_000]]
                ]
                return ["message": ["role": "assistant", "content": "", "tool_calls": [call]], "done": true, "done_reason": "stop"]
            }
            return ["message": ["role": "assistant", "content": "Done checking."], "done": true, "done_reason": "stop"]
        }

        let app = launch(["-dc-open", server.postURL, "-dc-fixture-model", server.baseURL, "-dc-seed-forums"])
        let field = openAddressField(in: app)

        // Home shows while the page URL is unchanged.
        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 5), "Home must show before typing")

        // Type a question WITHOUT pressing Return: suggestions replace Home and zero model requests fire.
        field.typeText("what is this page about?")
        let askRow = app.buttons["addressSuggestion-askAgent"]
        let webRow = app.buttons["addressSuggestion-webSearch"]
        XCTAssertTrue(waitOrDump(askRow, timeout: 5, in: app), "Ask the Agent suggestion row did not appear")
        XCTAssertTrue(webRow.exists, "Search the web row should follow Ask the Agent")
        XCTAssertFalse(any(app, "home").exists, "Suggestions must replace Home while typing")
        capture("address-suggestions-ask-agent")

        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(chatRequests, 0, "No AI request may leave the device while typing")

        // Press Return: closes overlay, opens panel, starts the run.
        field.typeText("\n")
        XCTAssertTrue(waitOrDump(any(app, "drawerHeader"), timeout: 10, in: app), "AI drawer did not open on Return")

        // Dismiss the drawer while wait_for is running: aiButton reads "Working".
        dismissDrawer(in: app)
        let aiButton = app.buttons["aiButton"]
        XCTAssertTrue(waitOrDump(aiButton, timeout: 5, in: app), "aiButton missing")
        XCTAssertTrue(
            wait(timeout: 5) { (aiButton.value as? String)?.contains("Working") == true },
            "Expected aiButton value 'Working' while running, got: \(aiButton.value ?? "")"
        )
        XCTAssertGreaterThanOrEqual(chatRequests, 1, "Model request should have started after Return")
    }

    /// With AI consent undecided (App Store task 2), asking the Agent from the
    /// address bar shows the full-screen AI consent page first before running.
    func testAskAgentFromAddressBarShowsConsentPageFirstWhenUndecided() throws {
        try skipUnlessPhone("Motion task 5 iPhone address suggestions + consent order")
        let app = launch(["-dc-sample", "-dc-page-state", "topic", "-dc-ask-ai-consent"])

        // Sample opens the drawer automatically on iPhone; dismiss it to reach the bar.
        if any(app, "drawerHeader").waitForExistence(timeout: 10) {
            dismissDrawer(in: app)
        }

        let field = openAddressField(in: app)
        field.typeText("summarize this topic\n")

        let consentPage = any(app, "aiConsentPage")
        XCTAssertTrue(waitOrDump(consentPage, timeout: 10, in: app), "AI consent page must show first when consent is undecided")
        capture("address-ask-agent-consent")

        app.buttons["aiConsentAllow"].tap()
        XCTAssertTrue(waitForGone(consentPage, timeout: 10), "Allow did not dismiss the consent page")
        XCTAssertTrue(any(app, "drawerHeader").waitForExistence(timeout: 10), "AI drawer should remain open after Allow")
    }

    /// A plain search + Return opens the configured search engine; no "Ask the
    /// Agent" row appears on an empty tab.
    func testSearchOpensEngineAndEmptyTabHidesAskAgent() throws {
        try skipUnlessPhone("Motion task 5 iPhone search and empty tab")

        // 1. Empty tab: typing a question must NOT show "Ask the Agent".
        let homeApp = launch(["-dc-forums-home", "-dc-seed-forums"])
        let homeField = openAddressField(in: homeApp)
        homeField.typeText("what is swift concurrency?")
        let homeWebRow = homeApp.buttons["addressSuggestion-webSearch"]
        XCTAssertTrue(waitOrDump(homeWebRow, timeout: 5, in: homeApp), "Web search row did not appear on empty tab")
        XCTAssertFalse(homeApp.buttons["addressSuggestion-askAgent"].exists, "Ask the Agent must not appear on an empty tab")
        capture("address-suggestions-empty-tab")

        // Press Return on a search: loads the search engine (DuckDuckGo by default).
        homeField.typeText("\n")
        XCTAssertTrue(waitForGone(any(homeApp, "addressSuggestions"), timeout: 5), "Suggestions did not close after Return")
        let barTitle = homeApp.buttons["browserTitle"]
        XCTAssertTrue(
            wait(timeout: 10) {
                barTitle.exists && (
                    barTitle.label.localizedCaseInsensitiveContains("duckduckgo")
                        || barTitle.label.localizedCaseInsensitiveContains("google")
                )
            },
            "Expected search engine to load after Return, got browserTitle: \(barTitle.label)"
        )
    }

    /// With no model configured, "Ask the Agent" + Return opens the panel and
    /// shows its provider setup card.
    func testAskAgentWithNoModelShowsProviderSetupCard() throws {
        try skipUnlessPhone("Motion task 5 iPhone no-model setup card")
        let app = launch(["-dc-open", server.postURL, "-dc-no-provider"])
        let field = openAddressField(in: app)
        field.typeText("explain this page\n")

        let setupCard = any(app, "providerSetupCard")
        XCTAssertTrue(waitOrDump(setupCard, timeout: 10, in: app), "Provider setup card did not appear when no model is configured")
        capture("address-ask-agent-no-model")
    }
}
