import XCTest

/// Developer mode part 1 (design-m3.md task 7): no developer entry while the switch is off; with
/// it on, a step shows its model line, raw request and response, and ⋯ › Export task shows its alert.
final class DeveloperModeUITests: DCUITestCase {
    private func launchDemo(developer: Bool, extra: [String] = []) -> XCUIApplication {
        let args = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-dc-browser-agent-fixture-page",
                    "-dc-browser-agent-demo", "recorded", "-dc-drawer-detent", "large"] + extra
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
        XCTAssertFalse(any(app, "thisPageSiteInspector").exists, "The site inspector is a developer-mode entry.")
        dismissPopover(app)
        openMenu(app)
        XCTAssertTrue(app.buttons["Audit log"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Export task"].exists, "Export task is a developer-mode entry.")
    }

    /// ⋯ › Report a problem (every build, not only developer mode): the export alert, then a toast.
    /// The simulator has no iCloud, so the report stays on the device and the toast says so.
    func testReportAProblemSavesTheTaskAndShowsAToast() throws {
        let app = launchDemo(developer: false, extra: ["-AppleInterfaceStyle", "Dark"])
        openMenu(app)
        let report = app.buttons["Report a problem"].firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        XCTAssertTrue(report.isEnabled)
        captureIfRequested("report-problem-menu-dark")
        report.tap()
        let alert = app.alerts["Save this task for feedback?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Save"].tap()
        let toast = any(app, "feedbackSavedToast")
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "No toast after Report a problem.")
        XCTAssertTrue(toast.label.contains("iCloud isn't available"), "Toast was: \(toast.label)")
        captureIfRequested("report-problem-toast-dark")
    }

    func testSiteInspectorOpensFromThisPage() throws { try openSiteInspector(dark: false) }

    func testSiteInspectorOpensInDarkMode() throws { try openSiteInspector(dark: true) }

    func testTryToolWarnsBeforeASiteToolRuns() throws { try openTryTool(dark: false) }

    func testTryToolInDarkMode() throws { try openTryTool(dark: true) }

    private func openTryTool(dark: Bool) throws {
        let suffix = dark ? "-dark" : ""
        let app = launchDemo(developer: true, extra: ["-dc-site-inspector-seed"] + (dark ? ["-AppleInterfaceStyle", "Dark"] : []))
        app.buttons["pageCapabilitiesSeal"].firstMatch.tap()
        let row = any(app, "thisPageSiteInspector")
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let trial = any(app, "siteInspectorTool-site.search_posts")
        XCTAssertTrue(trial.waitForExistence(timeout: 10), "The seeded site tool row did not show.")
        trial.tap()
        XCTAssertTrue(any(app, "toolTrialRun").waitForExistence(timeout: 5), "Try tool did not open.")
        capture("try-tool\(suffix)")
        any(app, "toolTrialRun").tap()
        let warning = app.alerts["Run this site's own tool?"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "A site's own tool must warn before a trial run, even when it claims to be read-only.")
        capture("try-tool-warning\(suffix)")
        warning.buttons["Cancel"].tap()
    }

    private func openSiteInspector(dark: Bool) throws {
        let suffix = dark ? "-dark" : ""
        let app = launchDemo(developer: true, extra: ["-dc-site-inspector-seed"] + (dark ? ["-AppleInterfaceStyle", "Dark"] : []))
        app.buttons["pageCapabilitiesSeal"].firstMatch.tap()
        let row = any(app, "thisPageSiteInspector")
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        XCTAssertTrue(any(app, "siteInspector").waitForExistence(timeout: 8), "The site inspector sheet did not open.")
        let toolRow = any(app, "siteInspectorTool-site.search_posts")
        XCTAssertTrue(toolRow.waitForExistence(timeout: 10), "The seeded tools did not show.")
        capture("site-inspector\(suffix)")
        app.swipeUp(velocity: .slow)
        capture("site-inspector-reading\(suffix)")
        let picker = any(app, "siteInspectorSlotPicker")
        for _ in 0..<5 where !picker.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(picker.isHittable, "The Last check picker never scrolled into view.")
        capture("site-inspector-scrolled\(suffix)")
        app.swipeUp(); app.swipeUp()
        capture("site-inspector-bottom\(suffix)")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(wait(timeout: 5) { !self.any(app, "siteInspector").exists })
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
