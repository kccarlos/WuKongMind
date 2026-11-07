import XCTest

/// The App Store and README captures, on the DEBUG sample (SampleContent.swift):
/// `scripts/brand/capture_store_screenshots.sh` runs it on the 6.9" iPhone and 13" iPad
/// simulators for each store language and copies the results into
/// `appstore/screenshots-raw/<locale>/`. Skipped unless
/// `TEST_RUNNER_DC_SCREENSHOT_DIR` is set; `TEST_RUNNER_DC_SHOT_LANGUAGE` is
/// `en` (default), `zh-Hans` or `zh-Hant`.
final class StoreScreenshotTests: DCUITestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private var language: [String] {
        switch environment["DC_SHOT_LANGUAGE"] ?? "en" {
        case "zh-Hans": ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        case "zh-Hant": ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        default: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        }
    }

    private let sample = ["-dc-sample", "-dc-apple-intelligence", "on-device", "-AppleInterfaceStyle", "Light"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard environment["DC_SCREENSHOT_DIR"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_DC_SCREENSHOT_DIR to take the store captures.")
        }
    }

    /// Launches, waits for `ready`, lets the drawer and page settle, captures.
    private func shoot(
        _ name: String, _ arguments: [String], scrollToChat: Bool = false,
        ready: (XCUIApplication) -> XCUIElement
    ) {
        let app = launch(language + arguments)
        XCTAssertTrue(waitOrDump(ready(app), timeout: 30, in: app), "\(name): the screen did not come up.")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        if scrollToChat {
            // The conversation sits under the summary.
            let scroll = app.scrollViews["chatScroll"].firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 5), "\(name): no chat scroll view.")
            for _ in 0..<2 where scroll.exists { scroll.swipeUp() }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        XCTAssertTrue(waitForStillScreen(), "\(name): the screen never stopped changing.")
        capture(name)
        app.terminate()
    }

    /// Waits until two screenshots a second apart are identical: drawer
    /// moves, fades and streamed text have finished (the status bar is fixed).
    private func waitForStillScreen(timeout: TimeInterval = 30) -> Bool {
        var previous = XCUIScreen.main.screenshot().pngRepresentation
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let current = XCUIScreen.main.screenshot().pngRepresentation
            if current == previous { return true }
            previous = current
        }
        return false
    }

    func testPhoneCaptures() throws {
        try skipUnlessPhone("iPhone captures")
        let drawer = { (app: XCUIApplication) in self.drawerState(in: app) }
        shoot("iphone-69-1-home", sample + ["-dc-forums-home", "-dc-digest-sample", "done"]) { $0.descendants(matching: .any)["home"].firstMatch }
        shoot("iphone-69-2-summary", sample + ["-dc-assistant-mode", "summary"], ready: drawer)
        shoot("iphone-69-3-chat", sample + ["-dc-assistant-mode", "chat", "-dc-drawer-detent", "large"], scrollToChat: true, ready: drawer)
        shoot("iphone-69-4-agent", sample + ["-dc-assistant-mode", "agent", "-dc-drawer-detent", "large"], ready: drawer)
        shoot("iphone-69-5-privacy", ["-dc-sample", "-dc-onboarding-step", "privacy"]) { $0.buttons.firstMatch }
        // README: the page with the bar and its ✦ button, before the drawer opens.
        shoot("iphone-page", sample + ["-dc-drawer-first-run", "-dc-no-summary"]) { $0.buttons["dockHintText"] }
    }

    func testPadCaptures() throws {
        try skipUnlessPad("iPad captures")
        let panel = { (app: XCUIApplication) in self.any(app, "aiPanel") }
        shoot("ipad-13-1-home-summary", sample + ["-dc-assistant-mode", "summary"], ready: panel)
        shoot("ipad-13-2-chat", sample + ["-dc-assistant-mode", "chat"], scrollToChat: true, ready: panel)
        shoot("ipad-13-3-agent", sample + ["-dc-assistant-mode", "agent"], ready: panel)
        shoot("ipad-13-4-manage", sample + ["-dc-open-history"], ready: panel)
        shoot("ipad-13-5-sync", sample + ["-dc-panel-settings", "sync", "-dc-sync-status", "upToDate"]) {
            $0.descendants(matching: .any)["syncEnabled"].firstMatch
        }
    }
}
