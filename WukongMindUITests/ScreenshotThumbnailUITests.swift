import XCTest

/// WUKO-49: a screenshot row expands to a thumbnail, which opens full size in a sheet.
final class ScreenshotThumbnailUITests: DCUITestCase {
    func testScreenshotThumbnailOpensSheet() throws {
        let args = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-dc-browser-agent-fixture-page",
                    "-dc-browser-agent-demo", "screenshot", "-dc-drawer-detent", "large"]
        let app = launch(args, orientation: isPhone ? .portrait : .landscapeLeft)
        showAssistant(in: app)
        let status = any(app, "agentStatusLine")
        XCTAssertTrue(wait(timeout: 40) { status.exists && status.label.contains("Done ·") }, "The demo task did not finish.")
        let fold = any(app, "agentStepsSummary")
        if fold.exists { fold.tap() }
        let rows = app.descendants(matching: .any).matching(identifier: "agentToolRow")
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5))
        rows.element(boundBy: 1).tap()
        let thumb = app.buttons["agentToolScreenshot"].firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout: 8), "The expanded screenshot row needs a thumbnail.")
        XCTAssertEqual(thumb.label, "Screenshot, opens full size")
        capture("screenshot-thumbnail")
        thumb.tap()
        XCTAssertTrue(any(app, "agentScreenshotSheet").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "agentScreenshotImage").waitForExistence(timeout: 5))
        capture("screenshot-sheet")
        app.buttons["agentScreenshotDone"].tap()
        XCTAssertTrue(wait(timeout: 5) { !any(app, "agentScreenshotSheet").exists })
    }
}
