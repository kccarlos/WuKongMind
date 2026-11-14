import XCTest

/// Developer mode part 1 (design-m3.md task 7): no developer entry while the switch is off; with
/// it on, a step shows its model line, raw request and response, and ⋯ › Export task shows its alert.
final class DeveloperModeUITests: DCUITestCase {
    private func launchDemo(developer: Bool) -> XCUIApplication {
        let args = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-dc-browser-agent-fixture-page",
                    "-dc-browser-agent-demo", "recorded", "-dc-drawer-detent", "large"]
        let app = launch(args + (developer ? ["-dc-developer-mode"] : []), orientation: isPhone ? .portrait : .landscapeLeft)
        showAssistant(in: app)
        let status = any(app, "agentStatusLine")
        XCTAssertTrue(wait(timeout: 40) { status.exists && status.label.contains("Done ·") }, "The demo task did not finish.")
        return app
    }

    private func dismissPopover(_ app: XCUIApplication) {
        let popover = any(app, "pageScriptsPopover")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        if !wait(timeout: 4, until: { !popover.exists }) {
            app.buttons["pageCapabilitiesSeal"].firstMatch.tap()
        }
        XCTAssertTrue(wait(timeout: 4, until: { !popover.exists }), "The This page popover did not close.")
    }

    private func openMenu(_ app: XCUIApplication) {
        let menu = app.buttons["assistantMoreMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
    }

    func testNoDeveloperEntriesWhileSwitchIsOff() throws {
        let app = launchDemo(developer: false)
        XCTAssertFalse(any(app, "agentDevDetails").exists)
        XCTAssertFalse(any(app, "agentDevTurnLine").exists)
        app.buttons["pageCapabilitiesSeal"].firstMatch.tap()
        XCTAssertTrue(any(app, "pageScriptsPopover").waitForExistence(timeout: 8))
        XCTAssertFalse(any(app, "thisPageConsole").exists)
        dismissPopover(app)
        openMenu(app)
        XCTAssertTrue(app.buttons["Audit log"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Export task"].exists, "Export task is a developer-mode entry.")
    }

    func testDeveloperModeShowsRawStepAndExportAlert() throws {
        let app = launchDemo(developer: true)

        XCTAssertTrue(any(app, "agentDevDetails").waitForExistence(timeout: 10), "The final reply needs a Details button.")
        capture("dev-mode-panel")

        // Expand a step: model line, Request and Response rows.
        let fold = any(app, "agentStepsSummary")
        if fold.exists { fold.tap() }
        let row = any(app, "agentToolRow")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let turnLine = any(app, "agentDevTurnLine")
        XCTAssertTrue(turnLine.waitForExistence(timeout: 5))
        XCTAssertTrue(turnLine.label.contains(" in · "), "Turn line was: \(turnLine.label)")
        let request = app.buttons["agentDevRequest"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        capture("dev-mode-step")
        request.tap()
        XCTAssertTrue(any(app, "agentDevBodyText").waitForExistence(timeout: 5))
        capture("dev-mode-request-sheet")
        app.buttons["Done"].firstMatch.tap()

        // This page › Developer: Console and Network.
        app.buttons["pageCapabilitiesSeal"].firstMatch.tap()
        XCTAssertTrue(any(app, "thisPageConsole").waitForExistence(timeout: 8))
        XCTAssertTrue(any(app, "thisPageNetwork").exists)
        capture("dev-mode-this-page")
        dismissPopover(app)

        // ⋯ › Export task: the alert, then the share sheet with one file.
        openMenu(app)
        let export = app.buttons["Export task"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertTrue(export.isEnabled)
        export.tap()
        let alert = app.alerts["Export this task?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        capture("dev-mode-export-alert")
        alert.buttons["Export"].tap()
        XCTAssertTrue(app.buttons["exportTaskShareLink"].firstMatch.waitForExistence(timeout: 10))
        capture("dev-mode-export-share")
    }
}
