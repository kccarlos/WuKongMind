import XCTest

/// Generates App Store screenshots for WukongMind Browser (6.9" iPhone portrait,
/// 13" iPad landscape) in light mode across `en-US`, `zh-Hans`, and `zh-Hant`.
///
/// Follows the screenshot plan in `appstore/README.md` and
/// `docs/wukongmind/store-positioning.md` section 3:
/// 1. `01-change-page` — News-style article with the ask box ("Make it dark") and the changed page.
/// 2. `02-agent-steps` — The Agent's tool steps in the conversation while modifying a page.
/// 3. `03-script-approval` — The script approval sheet when saving a reusable page change.
/// 4. `04-tabs-navigation` — The tab overview with four invented non-forum tabs.
/// 5. `05-summarize-read-aloud` — "Summarize this page" with Read aloud on an ordinary article.
/// 6. `06-browser-bar` (iPhone) / `06-ipad-split` (iPad) — Address bar on iPhone; page and Agent side by side on iPad.
///
/// All pages, prompts, and responses are invented offline `#if DEBUG` fixtures
/// (`StoreScreenshotContent`); no network, API keys, real people, or forum content.
///
/// Run via `scripts/remote-test.sh --sim iphone-69 --clean-status-bar -only-testing:WukongMindUITests/AppStoreScreenshotTests`
/// and `--sim ipad-13 --clean-status-bar`, then extract with `scripts/extract-appstore-screenshots.py`.
final class AppStoreScreenshotTests: DCUITestCase {
    private struct LocaleConfig {
        let code: String
        let appleLanguages: String
        let appleLocale: String

        var launchArguments: [String] {
            [
                "-AppleLanguages", appleLanguages,
                "-AppleLocale", appleLocale,
                "-AppleInterfaceStyle", "Light"
            ]
        }
    }

    private var deviceTag: String { isPhone ? "iphone" : "ipad" }
    private var shotOrientation: UIDeviceOrientation { isPhone ? .portrait : .landscapeLeft }

    func testScreenshotsEnUS() throws {
        try captureSet(for: LocaleConfig(code: "en-US", appleLanguages: "(en)", appleLocale: "en_US"))
    }

    func testScreenshotsZhHans() throws {
        try captureSet(for: LocaleConfig(code: "zh-Hans", appleLanguages: "(zh-Hans)", appleLocale: "zh_CN"))
    }

    func testScreenshotsZhHant() throws {
        try captureSet(for: LocaleConfig(code: "zh-Hant", appleLanguages: "(zh-Hant)", appleLocale: "zh_TW"))
    }

    // MARK: - Capture Flow

    private func captureSet(for locale: LocaleConfig) throws {
        let base = locale.launchArguments

        // 1. Change any page ("Make it dark and hide the sidebar").
        do {
            let app = launch(
                base + ["-dc-browser-agent-demo", "store-dark", "-dc-drawer-detent", "medium"],
                orientation: shotOrientation
            )
            let reply = any(app, "agentAssistantReply")
            XCTAssertTrue(
                waitOrDump(reply, timeout: 30, in: app),
                "[\(locale.code)] Agent reply did not appear for 01-change-page."
            )
            if usesDrawerLayout(app) {
                let state = drawerState(in: app)
                XCTAssertTrue(
                    wait(timeout: 10) { state.exists && state.label.contains("detent=medium") },
                    "[\(locale.code)] Drawer did not settle at medium for 01-change-page."
                )
            }
            settle(0.6)
            captureUpright("\(locale.code)__\(deviceTag)__01-change-page")
            app.terminate()
        }

        // 2. Agent tool steps in the conversation (pinned at large detent on iPhone).
        do {
            let app = launch(
                base + ["-dc-browser-agent-demo", "store-dark", "-dc-drawer-detent", "large"],
                orientation: shotOrientation
            )
            let reply = any(app, "agentAssistantReply")
            XCTAssertTrue(
                waitOrDump(reply, timeout: 30, in: app),
                "[\(locale.code)] Agent reply did not appear for 02-agent-steps."
            )
            if usesDrawerLayout(app) {
                let state = drawerState(in: app)
                XCTAssertTrue(
                    wait(timeout: 10) { state.exists && state.label.contains("detent=large") },
                    "[\(locale.code)] Drawer did not reach large detent for 02-agent-steps."
                )
            }
            let stepsButton = app.buttons["agentStepsSummary"].firstMatch
            XCTAssertTrue(
                waitOrDump(stepsButton, timeout: 10, in: app),
                "[\(locale.code)] Steps fold button missing for 02-agent-steps."
            )
            stepsButton.tap()
            settle(0.6)
            captureUpright("\(locale.code)__\(deviceTag)__02-agent-steps")
            app.terminate()
        }

        // 3. Script approval sheet (`script_save` -> shared ScriptImportSheet).
        do {
            let app = launch(
                base + ["-dc-browser-agent-demo", "store-script", "-dc-drawer-detent", "large"],
                orientation: shotOrientation
            )
            let approveButton = app.buttons["scriptImportAddTurnOn"].firstMatch
            XCTAssertTrue(
                waitOrDump(approveButton, timeout: 25, in: app),
                "[\(locale.code)] Script approval sheet did not appear for 03-script-approval."
            )
            settle(0.6)
            captureUpright("\(locale.code)__\(deviceTag)__03-script-approval")
            app.terminate()
        }

        // 4. Tab overview (and on iPhone, 06-browser-bar showing the bottom address bar).
        do {
            let app = launch(
                base + ["-dc-store-tabs"],
                orientation: shotOrientation
            )
            let tabsButton = app.buttons["browserTabsButton"].firstMatch
            XCTAssertTrue(
                waitOrDump(tabsButton, timeout: 15, in: app),
                "[\(locale.code)] Tabs button missing for 04-tabs-navigation."
            )
            // Let all four tabs finish cycling and capturing live WKWebView thumbnails.
            settle(3.0)
            if isPhone {
                captureUpright("\(locale.code)__\(deviceTag)__06-browser-bar")
            }
            tabsButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let overview = any(app, "tabOverview")
            XCTAssertTrue(
                waitOrDump(overview, timeout: 10, in: app),
                "[\(locale.code)] Tab overview did not open for 04-tabs-navigation."
            )
            XCTAssertTrue(
                any(app, "tabOverviewCard-t4").waitForExistence(timeout: 5),
                "[\(locale.code)] Expected 4 tabs in overview."
            )
            settle(0.6)
            captureUpright("\(locale.code)__\(deviceTag)__04-tabs-navigation")
            app.terminate()
        }

        // 5. "Summarize this page" with Read aloud on an ordinary article.
        do {
            let app = launch(
                base + ["-dc-browser-agent-demo", "store-summarize", "-dc-drawer-detent", "large"],
                orientation: shotOrientation
            )
            let listenRow = any(app, "capabilityListenRow")
            let reply = any(app, "agentAssistantReply")
            XCTAssertTrue(
                waitOrDump(reply, timeout: 30, in: app),
                "[\(locale.code)] Summary reply did not appear for 05-summarize-read-aloud."
            )
            XCTAssertTrue(
                waitOrDump(listenRow, timeout: 15, in: app),
                "[\(locale.code)] Read aloud listen row did not appear for 05-summarize-read-aloud."
            )
            if usesDrawerLayout(app) {
                let state = drawerState(in: app)
                XCTAssertTrue(
                    wait(timeout: 10) { state.exists && state.label.contains("detent=large") },
                    "[\(locale.code)] Drawer did not reach large detent for 05-summarize-read-aloud."
                )
            }
            // Pause silent playback so iOS clears any Dynamic Island audio pill and all
            // locales keep an identical clean 9:41 status bar while showing the Read aloud card.
            if listenRow.isHittable {
                listenRow.tap()
            } else {
                listenRow.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            }
            settle(0.8)
            captureUpright("\(locale.code)__\(deviceTag)__05-summarize-read-aloud")
            app.terminate()
        }

        // 6. iPad split workspace: light-mode article and Agent suggestions side by side.
        if !isPhone {
            let app = launch(
                base + ["-dc-browser-agent-demo", "store-empty"],
                orientation: .landscapeLeft
            )
            let panel = any(app, "aiPanel")
            XCTAssertTrue(
                waitOrDump(panel, timeout: 20, in: app),
                "[\(locale.code)] iPad split AI panel did not appear for 06-ipad-split."
            )
            XCTAssertTrue(
                app.buttons["suggestion-summarizePage"].firstMatch.waitForExistence(timeout: 15),
                "[\(locale.code)] Ordinary-page suggestions did not appear for 06-ipad-split."
            )
            settle(0.6)
            captureUpright("\(locale.code)__\(deviceTag)__06-ipad-split")
            app.terminate()
        }
    }

    /// Captures the main screen and rotates iPad `.landscapeLeft` framebuffer images
    /// (which Xcode 27 returns as 2064x2752 rotated 90° clockwise) upright to 2752x2064
    /// without resampling or resizing.
    private func captureUpright(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let image = shot.image
        if !isPhone, let cg = image.cgImage, cg.width < cg.height {
            let uprightSize = CGSize(width: cg.height, height: cg.width)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let rotated = UIImage(cgImage: cg, scale: 1, orientation: .left)
            let rendered = UIGraphicsImageRenderer(size: uprightSize, format: format).image { _ in
                rotated.draw(in: CGRect(origin: .zero, size: uprightSize))
            }
            let attachment = XCTAttachment(image: rendered)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }
        capture(name)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
