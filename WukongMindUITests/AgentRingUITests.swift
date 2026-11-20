import XCTest

/// Verifies `PhoneAIButton`'s `AgentRingState` accessibility values through real
/// recorded browser-agent runs (never `-dc-answer-ready` DEBUG-only records):
/// - Working → Answer ready while the panel is closed, cleared after opening
/// - Needs your answer when a confirmation pauses the run
/// (`docs/wukongmind/design-motion.md` §4, task 2).
final class AgentRingUITests: DCUITestCase {
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

    private func openAssistantAndSend(_ prompt: String, in app: XCUIApplication) {
        let input = app.textFields["agentPromptInput"]
        for _ in 0..<4 where !input.exists {
            showAssistant(in: app)
            _ = input.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(waitOrDump(input, timeout: 10, in: app), "Composer input did not appear")
        input.tap()
        input.typeText(prompt)
        let send = app.buttons["agentSendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send button did not appear")
        send.tap()
    }

    private func dismissDrawer(in app: XCUIApplication) {
        let header = any(app, "drawerHeader")
        guard header.waitForExistence(timeout: 5) else { return }
        let start = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        if !waitForGone(header, timeout: 4) {
            // Dismiss software keyboard if still up, then drag again.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            if header.exists {
                let retryStart = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                retryStart.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            }
        }
        XCTAssertTrue(waitForGone(header, timeout: 5), "Drawer did not close")
    }

    func testAIButtonTransitionsWorkingToAnswerReadyAndClearsOnOpen() throws {
        try skipUnlessPhone("Tests iPhone aiButton ring state with drawer closed")
        server.toolChatHandler = { messages in
            let toolResults = messages.filter { ($0["role"] as? String) == "tool" }.count
            if toolResults == 0 {
                let call: [String: Any] = [
                    "id": "call_wait_1",
                    "function": ["name": "wait_for", "arguments": ["ms": 4_000]]
                ]
                return ["message": ["role": "assistant", "content": "", "tool_calls": [call]], "done": true, "done_reason": "stop"]
            }
            return ["message": ["role": "assistant", "content": "Finished checking the page."], "done": true, "done_reason": "stop"]
        }

        let app = launch(["-dc-open", server.postURL, "-dc-fixture-model", server.baseURL])
        let aiButton = app.buttons["aiButton"]
        XCTAssertTrue(waitOrDump(aiButton, timeout: 20, in: app), "aiButton did not appear")

        openAssistantAndSend("Wait and report back", in: app)
        dismissDrawer(in: app)

        // While wait_for is running with the drawer closed, aiButton reads "Working".
        XCTAssertTrue(
            wait(timeout: 5) { (aiButton.value as? String)?.contains("Working") == true },
            "Expected aiButton value 'Working' while running, got: \(aiButton.value ?? "")"
        )

        // Once the run completes with the drawer closed, aiButton reads "Answer ready".
        XCTAssertTrue(
            wait(timeout: 15) { (aiButton.value as? String)?.contains("Answer ready") == true },
            "Expected aiButton value 'Answer ready' after completion, got: \(aiButton.value ?? "")"
        )

        // Opening the drawer marks the run seen; closing it again leaves aiButton idle.
        aiButton.tap()
        XCTAssertTrue(waitOrDump(any(app, "drawerHeader"), timeout: 10, in: app), "Drawer did not open")
        dismissDrawer(in: app)
        XCTAssertTrue(
            wait(timeout: 5) {
                let value = aiButton.value as? String ?? ""
                return !value.contains("Answer ready") && !value.contains("Working")
            },
            "Expected aiButton value to clear after opening the drawer, got: \(aiButton.value ?? "")"
        )
    }

    func testAIButtonReadsNeedsYourAnswerOnConfirmation() throws {
        try skipUnlessPhone("Tests iPhone aiButton needsYou ring state with drawer closed")
        let targetURL = server.baseURL + "/wp-json/"
        server.toolChatHandler = { messages in
            let toolResults = messages.filter { ($0["role"] as? String) == "tool" }.count
            if toolResults == 0 {
                let call: [String: Any] = [
                    "id": "call_wait_confirm",
                    "function": ["name": "wait_for", "arguments": ["ms": 2_500]]
                ]
                return ["message": ["role": "assistant", "content": "", "tool_calls": [call]], "done": true, "done_reason": "stop"]
            }
            if toolResults == 1 {
                let call: [String: Any] = [
                    "id": "call_post_confirm",
                    "function": ["name": "http_request", "arguments": ["method": "POST", "url": targetURL]]
                ]
                return ["message": ["role": "assistant", "content": "", "tool_calls": [call]], "done": true, "done_reason": "stop"]
            }
            return ["message": ["role": "assistant", "content": "Confirmation handled."], "done": true, "done_reason": "stop"]
        }

        let app = launch(["-dc-open", server.postURL, "-dc-fixture-model", server.baseURL])
        let aiButton = app.buttons["aiButton"]
        XCTAssertTrue(waitOrDump(aiButton, timeout: 20, in: app), "aiButton did not appear")

        openAssistantAndSend("Post a request", in: app)
        dismissDrawer(in: app)

        // When the POST request pauses for confirmation, aiButton reads "Needs your answer".
        XCTAssertTrue(
            wait(timeout: 15) { (aiButton.value as? String)?.contains("Needs your answer") == true },
            "Expected aiButton value 'Needs your answer' on pending confirmation, got: \(aiButton.value ?? "")"
        )

        // Opening the drawer shows the confirmation card; declining lets the run finish cleanly.
        aiButton.tap()
        let deny = app.buttons["agentConfirmDeny"]
        XCTAssertTrue(waitOrDump(deny, timeout: 10, in: app), "Confirmation card did not appear")
        deny.tap()
        XCTAssertTrue(waitForGone(deny, timeout: 10), "Confirmation card did not dismiss")
    }
}
