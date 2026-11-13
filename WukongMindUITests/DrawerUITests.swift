import UIKit
import XCTest

/// The iPhone AI drawer on sample data (`-dc-sample`, a topic page): every
/// kind of root presentation shows over it and the drawer comes back at the
/// same height; the swipe rules (down from medium closes it; from large a
/// slow drag stops at medium, a flick closes it); the hint row over the bar.
/// The height comes from the DEBUG `drawerState` element; `-dc-test-present`
/// triggers the presentation.
final class DrawerUITests: DCUITestCase {
    private let sample = ["-dc-sample", "-dc-page-state", "topic"]

    private func captureAuditScreen(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFirstRunHintHasAnOpaqueReadingSurface() throws {
        try skipUnlessPhone("Drawer hint surface")
        let server = FixtureWordPressServer()
        server.pageStyle = "background: #00ff00; min-height: 5000px"
        try server.start()
        defer { server.stop() }
        let app = launch(["-dc-sample", "-dc-open", server.postURL, "-dc-drawer-first-run",
                          "-dc-no-summary", "-AppleInterfaceStyle", "Light"])
        XCTAssertTrue(app.webViews.staticTexts["Sample Cards"].waitForExistence(timeout: 20))
        let hint = any(app, "dockHintRow")
        XCTAssertTrue(hint.waitForExistence(timeout: 10))
        let screenshot = app.screenshot()
        captureAuditScreen("base-hint-over-colored-page", in: app)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
        let frame = hint.frame
        let strip = CGRect(x: frame.minX + frame.width * 0.25, y: frame.minY + 5,
                           width: frame.width * 0.5, height: 3)
        let crop = try XCTUnwrap(image.cropping(to: CGRect(
            x: strip.minX * scale, y: strip.minY * scale,
            width: strip.width * scale, height: strip.height * scale).integral))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        let greenLeak = (0..<(crop.width * crop.height)).map {
            max(0, Int(pixels[$0 * 4 + 1]) - Int(pixels[$0 * 4]))
        }.reduce(0, +)
        XCTAssertLessThan(Double(greenLeak) / Double(crop.width * crop.height), 5,
                          "Page colors and text must not bleed into the first-run hint")
    }

    func testFirstRunHintLayout() throws {
        let app = launch(sample + ["-dc-drawer-first-run", "-dc-no-summary"])
        XCTAssertTrue(app.buttons["dockHintText"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.staticTexts.matching(label(contains: "forum_team")).firstMatch.waitForExistence(timeout: 30))
        captureAuditScreen("base-drawer-nosummary-hint", in: app)
    }

    func testSummaryCitationLayout() throws {
        try skipUnlessPhone("Summary citation layout")
        let app = launch(sample + ["-dc-drawer-detent", "large", "-AppleInterfaceStyle", "Light"])
        XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["citation-1"].firstMatch.waitForExistence(timeout: 10))
        captureAuditScreen("base-drawer-summary-large", in: app)
        try assertCitationChips(["citation-1", "citation-7", "citation-9", "citation-12"], in: app)
        // The takeaways cite #1 again; at this size that chip wraps to the start of its line.
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -260)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        try assertCitationChips(["citation-1", "citation-14"], in: app)
    }

    /// Measures each visible chip with the given ID (the sample cites some posts twice):
    /// its full stop touches it, and a chip that wrapped starts at the text column.
    private func assertCitationChips(_ ids: [String], in app: XCUIApplication) throws {
        let screen = app.windows.firstMatch.frame
        // Between the drawer's header and its composer: chips scrolled under either are hidden.
        let top = any(app, "drawerHeader").frame.maxY, bottom = any(app, "askBox").frame.minY
        let chips = try ids.map { id in
            (id, try XCTUnwrap(app.buttons.matching(identifier: id).allElementsBoundByIndex.first {
                $0.frame.minY >= top && $0.frame.maxY <= bottom
            }, "\(id): expected a visible citation chip"))
        }
        let cgImage = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(cgImage.width) / screen.width
        func pixels(in frame: CGRect) throws -> (px: [UInt8], w: Int, h: Int) {
            let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                              width: frame.width * scale, height: frame.height * scale).integral
            let crop = try XCTUnwrap(cgImage.cropping(to: rect))
            let w = crop.width, h = crop.height
            var px = [UInt8](repeating: 255, count: w * h * 4)
            px.withUnsafeMutableBytes { bytes in
                CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return (px, w, h)
        }
        for (name, chip) in chips {
            let (px, w, h) = try pixels(in: CGRect(x: 10, y: chip.frame.minY, width: chip.frame.maxX + 12 - 10, height: chip.frame.height))
            func dark(_ i: Int) -> Bool { px[i] < 90 && px[i + 1] < 90 && px[i + 2] < 90 }
            var pillMinX: Int?, pillMaxX: Int?
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                    // Light-mode `DCTheme.jadeWash` (#DCEFEB = 220, 239, 235) citation seal fill.
                    if abs(r - 220) <= 14 && abs(g - 239) <= 14 && abs(b - 235) <= 14 && g - r >= 10 {
                        pillMinX = min(pillMinX ?? x, x)
                        pillMaxX = max(pillMaxX ?? x, x)
                    }
                }
            }
            let start = try XCTUnwrap(pillMinX, "\(name): expected citation pill"), edge = pillMaxX!
            // Dark body text before the pill on its line (blue list markers do not count).
            let textBefore = (h / 4..<(3 * h / 4)).contains { y in (0..<start).contains { dark((y * w + $0) * 4) } }
            if !textBefore {
                // Wrapped: bullet (34 pt) or numbered (42 pt) text column, not indented past it.
                XCTAssertLessThanOrEqual(10 + CGFloat(start) / scale, 43, "\(name): a wrapped citation chip must align with the list text column")
            }
            var dotMinX: Int?
            for y in 0..<h {
                for x in (edge + 1)..<w where dark((y * w + x) * 4) {
                    dotMinX = min(dotMinX ?? x, x)
                }
            }
            let gap = CGFloat(try XCTUnwrap(dotMinX, "\(name): expected trailing full stop on same line") - edge - 1) / scale
            XCTAssertLessThanOrEqual(gap, 2.0, "\(name): full stop must touch its chip without a space (got \(gap) pt)")
        }
    }

    func testAccessibilityDrawerKeepsTitleAndComposerReadable() throws {
        try skipUnlessPhone("Drawer accessibility layout")
        for detent in ["medium", "large"] {
            let app = launch(sample + ["-dc-drawer-detent", detent,
                "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
            XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 20))
            XCTAssertTrue(wait(timeout: 5) { drawerState(in: app).label == "detent=\(detent)" })
            let title = any(app, "drawerTitle")
            let field = app.textFields["agentPromptInput"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "ax5-drawer-summary-\(detent)"
            shot.lifetime = .keepAlways
            add(shot)
            let font = UIFont.preferredFont(forTextStyle: .headline, compatibleWith:
                UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
            let titleWidth = (title.label as NSString).size(withAttributes: [.font: font]).width
            // The system's floating medium sheet scales its content down slightly.
            let scale: CGFloat = detent == "medium" ? 0.94 : 1
            XCTAssertGreaterThanOrEqual(title.frame.width, titleWidth * scale - 2, "Header title must fit without truncation")
            XCTAssertGreaterThanOrEqual(field.frame.width, 180, "AX5 field must keep room to read and edit a question")
            XCTAssertGreaterThanOrEqual(app.buttons["composerMic"].frame.width, 44 * scale)
            if detent == "large" {
                any(app, "summaryDetails").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let metadata = app.staticTexts.matching(label(contains: "88 posts")).firstMatch
                XCTAssertTrue(metadata.waitForExistence(timeout: 5))
                XCTAssertTrue(metadata.label.contains("Kept"))
                captureAuditScreen("ax5-summary-details", in: app)
                app.buttons["assistantMoreMenu"].tap()
                let model = app.buttons.matching(label(contains: "Model")).firstMatch
                XCTAssertTrue(model.waitForExistence(timeout: 5), "Model submenu stays available in More at accessibility sizes")
                captureAuditScreen("ax5-model-overflow", in: app)
            }
        }
    }

    func testTypingFollowUpKeepsSummaryPosition() throws {
        let app = launch(sample)
        XCTAssertTrue(waitOrDump(any(app, "askBox"), timeout: 20, in: app))
        dragDrawer(in: app, to: 0.08)
        let marker = app.buttons["retrySummary"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        let field = app.textFields["agentPromptInput"]
        field.tap()
        let before = marker.frame.minY
        field.typeText("Follow-up with more details")
        XCTAssertEqual(marker.frame.minY, before, accuracy: 2, "Typing must not scroll the summary")
    }

    /// A Settings page request (Start a Voice Chat without voice set up).
    func testSettingsRequestShowsOverTheDrawer() throws {
        let app = try launchWithDrawer(presenting: "settings", at: "large")
        let page = app.navigationBars["Voice"]
        XCTAssertTrue(waitOrDump(page, timeout: 20, in: app), "Settings › Voice did not show over the drawer.")
        tapNavigationBack(in: app)
        let done = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        assertDrawer(at: "large", in: app, after: page)
    }

    /// A full-screen cover (the DEBUG Settings cover stands in for the
    /// walkthrough and the Terms of Use).
    func testFullScreenCoverShowsOverTheDrawer() throws {
        let app = try launchWithDrawer(presenting: "cover", at: "medium")
        let done = app.buttons["debugSettingsDone"]
        XCTAssertTrue(waitOrDump(done, timeout: 20, in: app), "The cover did not show over the drawer.")
        done.tap()
        assertDrawer(at: "medium", in: app, after: done)
    }

    /// `presentedError`: the root alert.
    func testErrorAlertShowsOverTheDrawer() throws {
        let app = try launchWithDrawer(presenting: "error", at: "medium")
        let alert = app.alerts["WukongMind"]
        XCTAssertTrue(waitOrDump(alert, timeout: 20, in: app), "The error alert did not show over the drawer.")
        XCTAssertTrue(alert.staticTexts["Test error"].exists)
        alert.buttons["OK"].tap()
        assertDrawer(at: "medium", in: app, after: alert)
    }

    /// A root sheet closed while the drawer waits to come back (asked for
    /// under the sheet): the drawer comes back, and a root alert still shows
    /// (the drawer never ends up half presented with neither host active).
    func testClosingARootSheetWhileTheDrawerIsPendingBringsItBack() throws {
        let app = try launchWithDrawer(presenting: "pending-drawer", at: "medium")
        let page = app.navigationBars["Voice"]
        XCTAssertTrue(waitOrDump(page, timeout: 20, in: app), "Settings › Voice did not show.")
        tapNavigationBack(in: app)
        let done = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 15, in: app), "The pending drawer did not come back.")
        let alert = app.alerts["WukongMind"]
        XCTAssertTrue(waitOrDump(alert, timeout: 20, in: app), "The root alert did not show after the drawer came back.")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitForGone(alert, timeout: 10))
    }

    /// A drawer presentation that never reports its content (as when UIKit
    /// drops it) falls back after the watchdog: the root alert still shows
    /// and the drawer comes up.
    func testADroppedDrawerPresentationDoesNotBlockAlerts() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + ["-dc-drawer-drop-first", "-dc-test-present", "error", "-dc-test-present-after", "8"])
        let alert = app.alerts["WukongMind"]
        XCTAssertTrue(waitOrDump(alert, timeout: 30, in: app), "The root alert was blocked by a dropped drawer.")
        XCTAssertTrue(alert.staticTexts["Test error"].exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 10), "The drawer did not come up.")
    }

    /// Two heights, no peek: the AI button opens the drawer at medium and a
    /// swipe down from medium closes it; from large a slow drag stops at
    /// medium and a flick closes it.
    func testSwipingDownClosesTheDrawer() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample)
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "Got \(state.label).")

        dragDrawer(in: app, to: 0.99)
        XCTAssertTrue(waitForGone(state, timeout: 5), "A swipe down from medium must close the drawer.")

        let button = app.buttons["aiButton"]
        XCTAssertTrue(waitForBarItem(button, timeout: 10), "The bar's AI button is missing.")
        tapBarItem(button)
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "The AI button opens the drawer at medium.")

        dragDrawer(in: app, to: 0.08)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" }, "Got \(state.label), wanted large.")
        dragDrawer(in: app, to: 0.55)
        XCTAssertTrue(wait(timeout: 5) { state.exists && state.label == "detent=medium" },
                      "A slow drag down from large must stop at medium; got \(state.label).")

        dragDrawer(in: app, to: 0.08)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" }, "Got \(state.label), wanted large.")
        flickDrawer(in: app)
        XCTAssertTrue(waitForGone(state, timeout: 5), "A flick down from large must close the drawer.")
        XCTAssertTrue(waitForBarItem(button, timeout: 10), "The bar did not come back.")
    }

    /// The first topic opened: the drawer stays closed and the hint row
    /// over the bar has the "Summarize this thread?" tip. Its text opens the
    /// drawer at medium (and the tip has done its job); its button opens it
    /// and starts the summary (the DEBUG fake summary).
    func testTheHintRowOpensTheDrawerAndItsButtonSummarizes() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let args = sample + ["-dc-drawer-first-run", "-dc-no-summary", "-dc-fake-summary"]
        var app = launch(args)
        var state = drawerState(in: app)
        let text = app.buttons["dockHintText"]
        XCTAssertTrue(waitOrDump(text, timeout: 20, in: app), "The first topic shows no hint row.")
        XCTAssertFalse(state.exists, "The first topic must not open the drawer.")
        XCTAssertEqual(text.label, "Summarize this thread? · Open assistant")
        XCTAssertTrue(waitForHittable(text))
        text.tap()
        XCTAssertTrue(state.waitForExistence(timeout: 10), "The hint row's text did not open the drawer.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "Got \(state.label).")
        closeDrawer(in: app)
        XCTAssertTrue(waitForBarItem(app.buttons["aiButton"], timeout: 10))
        XCTAssertFalse(text.exists, "The tip shows once: gone after the drawer opened.")
        app.terminate()

        app = launch(args)
        state = drawerState(in: app)
        let button = app.buttons["dockHintAction"]
        XCTAssertTrue(waitOrDump(button, timeout: 20, in: app), "The hint row has no button.")
        XCTAssertEqual(button.label, "Summarize this thread")
        XCTAssertTrue(waitForHittable(button))
        button.tap()
        XCTAssertTrue(state.waitForExistence(timeout: 10), "The hint row's button did not open the drawer.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "Got \(state.label).")
        XCTAssertTrue(waitOrDump(app.buttons["citation-12"].firstMatch, timeout: 30, in: app),
                      "The summary did not start.")
    }

    /// §4.6: a topic with the drawer at medium → summarize (the DEBUG fake
    /// summary) → at large, tap `#12` → the page scrolls to post 12 and
    /// marks it, and the drawer steps down to medium. The sample page has
    /// posts 1–30 (SampleContent.topicPageHTML).
    func testCitationJumpScrollsThePageAndLowersTheDrawer() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + ["-dc-no-summary", "-dc-fake-summary", "-dc-browse-debug"])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        XCTAssertTrue(wait(timeout: 8) { state.label == "detent=medium" }, "Got \(state.label).")
        let summarize = app.buttons["suggestion-summarizeThread"].firstMatch
        XCTAssertTrue(waitForHittable(summarize), "The summarize suggestion is missing.")
        summarize.tap()

        let citation = app.buttons["citation-12"].firstMatch
        XCTAssertTrue(waitOrDump(citation, timeout: 30, in: app), "The summary has no #12 citation.")
        XCTAssertTrue(wait(timeout: 10) { app.buttons["retrySummary"].exists },
                      "The summary did not finish.")

        dragDrawer(in: app, to: 0.08)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" }, "Got \(state.label), wanted large.")
        if !citation.isHittable { app.swipeUp() }
        XCTAssertTrue(waitForHittable(citation))
        citation.tap()

        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" },
                      "A citation tap at large must lower the drawer to medium; got \(state.label).")
        let browse = any(app, "browseDebugState")
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "The browse state hook is missing.")
        let landed = wait(timeout: 40) {
            // Post 12 at the top (post 11's last pixels may still show under the header).
            (browse.label.hasSuffix("top=12") || browse.label.hasSuffix("top=11"))
                && browse.label.contains("highlighted=12 ")
        }
        attachText(browse.label, named: "browse state")
        XCTAssertTrue(landed, "The page did not scroll to post 12 and mark it: \(browse.label)")
    }

    /// A summary run that fails shows the error in the drawer with Retry;
    /// Retry writes the summary (`-dc-fake-summary-fails` fails until then).
    func testAFailedSummaryShowsItsErrorAndRetryWritesIt() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + ["-dc-no-summary", "-dc-fake-summary", "-dc-fake-summary-fails", "-dc-browse-debug"])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        let summarize = app.buttons["suggestion-summarizeThread"].firstMatch
        XCTAssertTrue(waitForHittable(summarize), "The summarize suggestion is missing.")
        summarize.tap()

        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 10) { alert.buttons["OK"].tap() }
        let retry = app.buttons["retryFailedSummary"].firstMatch
        XCTAssertTrue(waitOrDump(retry, timeout: 15, in: app), "A failed summary shows no Retry.")
        XCTAssertTrue(any(app, "summaryFailureMessage").exists, "The failure does not say what went wrong.")
        retry.tap()
        XCTAssertTrue(wait(timeout: 30) { app.buttons["retrySummary"].exists },
                      "Retry did not write the summary.")
        XCTAssertFalse(retry.exists, "The failure stays after a successful run.")
    }

    /// §5 and the citation chips (no network: `-dc-no-provider` fails a run
    /// at once). Text typed under This topic moves along to Whole forum and
    /// to a new question; the run it starts shows in History. The sample
    /// summary's `#3 #7` chips are 44 pt wide and at least 4 pt apart.
    /// "Answer ready" over the bar (iPhone: drawer closed; iPad split: panel
    /// hidden) brings the AI view forward on the run that finished, not the
    /// selected one, and the row goes (audit A1, A2).
    func testAnswerReadyShowsTheFinishedRunInTheAIView() throws {
        let app = launch(sample + ["-dc-answer-ready"], orientation: isPhone ? .portrait : .landscapeLeft)
        let split = !usesDrawerLayout(app)
        let panel = any(app, "aiPanel")
        if split {
            XCTAssertTrue(waitOrDump(panel, timeout: 20, in: app), "The sample did not show the panel.")
            // After the sample's second "show the assistant" (1.2 s in).
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            app.buttons["aiPanelToggle"].tap()
            XCTAssertTrue(waitForGone(panel, timeout: 5), "The panel did not hide.")
        } else {
            XCTAssertTrue(waitOrDump(drawerState(in: app), timeout: 20, in: app), "The sample did not open the drawer.")
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            closeDrawer(in: app)
        }
        let row = app.buttons["dockAnswerReady"]
        XCTAssertTrue(waitOrDump(row, timeout: 10, in: app), "No Answer ready row.")
        row.tap()
        if split {
            XCTAssertTrue(panel.waitForExistence(timeout: 5), "Answer ready did not show the panel.")
        } else {
            XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 10), "Answer ready did not open the drawer.")
        }
        let goal = app.staticTexts["agentRunGoal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 10), "Ask the forum did not show a run.")
        if Locale.preferredLanguages.first?.hasPrefix("en") ?? true {
            XCTAssertTrue(goal.label.contains("rate limits"), "Not the finished run: \(goal.label)")
        }
        XCTAssertTrue(waitForGone(row, timeout: 5), "Answer ready stayed after it was shown.")
    }

    // MARK: Helpers

    private func launchWithDrawer(presenting kind: String, at detent: String) throws -> XCUIApplication {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + [
            "-dc-drawer-detent", detent,
            "-dc-test-present", kind, "-dc-test-present-after", "8"
        ])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        XCTAssertTrue(wait(timeout: 8) { state.label == "detent=\(detent)" }, "Got \(state.label), wanted \(detent).")
        return app
    }

    private func assertDrawer(at detent: String, in app: XCUIApplication, after presented: XCUIElement) {
        XCTAssertTrue(waitForGone(presented, timeout: 10), "The presentation did not close.")
        let state = drawerState(in: app)
        XCTAssertTrue(state.waitForExistence(timeout: 10), "The drawer did not come back.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=\(detent)" },
                      "The drawer came back at \(state.label), not \(detent).")
        // Still the drawer's content, not a copy at the root.
        XCTAssertTrue(any(app, "drawerHeader").exists)
    }

    func testPostsTranslationEmptyStateHasDoneButtonAndWordPressGating() throws {
        try skipUnlessPhone("iPhone forum menu translation check.")

        // 1. Empty-state PostsTranslationSheet shows Done and dismisses cleanly.
        var app = launch(sample + ["-dc-test-present", "translate-posts", "-dc-test-present-after", "1"])
        let navBar = app.navigationBars["Translate posts"]
        XCTAssertTrue(waitOrDump(navBar, timeout: 15, in: app))
        let done = app.buttons["translationDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(waitForGone(navBar, timeout: 5))
        app.terminate()

        // 2. WordPress post (pageBridge == nil) omits Translate from the forum menu.
        let server = FixtureWordPressServer()
        try server.start()
        defer { server.stop() }

        app = launch(["-dc-open", server.postURL, "-dc-fixture-model", server.baseURL])
        XCTAssertTrue(waitOrDump(app.buttons["forumSwitcher"].firstMatch, timeout: 25, in: app))
        openForumMenu(in: app)
        XCTAssertTrue(app.buttons["Watch this topic"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["menuTranslatePosts"].exists)
    }

    func testRealKeyboardKeepsChatVStackPinnedAtBottom() throws {
        try skipUnlessPhone("Tests iPhone drawer + software keyboard")
        let app = launch(
            ["-dc-sample", "-dc-page-state", "topic", "-dc-assistant-mode", "chat"],
            orientation: .portrait
        )
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app))
        dragDrawer(in: app, to: 0.08)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" })

        let jumpBtn = app.buttons["chatScrollToBottom"]
        if jumpBtn.waitForExistence(timeout: 1.5) && jumpBtn.isHittable {
            jumpBtn.tap()
        } else {
            let chatScroll = any(app, "agentScroll")
            if chatScroll.exists { chatScroll.swipeUp() }
        }
        XCTAssertTrue(waitForGone(jumpBtn, timeout: 5), "Reader starts at bottom with no scroll-to-bottom button")

        let input = any(app, "agentPromptInput")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        if app.keyboards.keys.count == 0 {
            app.typeKey("k", modifierFlags: .command)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        XCTAssertFalse(
            jumpBtn.exists,
            "Raising software keyboard while pinned at bottom in ChatThread must keep latest reply pinned without showing chatScrollToBottom"
        )
    }

    func testUnifiedAgentPanelMatchesAcrossForumAndOrdinaryPageAndRunsAgent() throws {
        let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

        // 1. Forum fixture (unsummarized): shows "Agent" header, This page seal, wave mascot, and composer + mic ring.
        var app = launch(base + ["-dc-sample", "-dc-no-summary", "-dc-drawer-detent", "large"], orientation: isPhone ? .portrait : .landscapeLeft)
        showAssistant(in: app)
        let forumTitle = any(app, "drawerTitle")
        XCTAssertTrue(waitOrDump(forumTitle, timeout: 15, in: app))
        XCTAssertEqual(forumTitle.label, "Agent")
        let forumSeal = app.buttons["pageCapabilitiesSeal"].firstMatch
        XCTAssertTrue(forumSeal.waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "agentEmptyState").waitForExistence(timeout: 10), "Unsummarized forum topic should show the unified wave mascot empty state.")
        XCTAssertFalse(any(app, "agentStatusLine").exists, "Status line must stay hidden while idle.")
        XCTAssertTrue(app.textFields["agentPromptInput"].exists)
        XCTAssertTrue(app.buttons["composerMic"].exists)

        // Open This page popover on a forum thread: shows This topic Following + Block ads here + Site settings.
        forumSeal.tap()
        let popover = any(app, "pageScriptsPopover")
        XCTAssertTrue(waitOrDump(popover, timeout: 8, in: app), "This page popover did not open.")
        XCTAssertTrue(app.switches["pageTopicFollowing"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["pageBlockAdsToggle"].exists)
        XCTAssertTrue(app.buttons["pageSiteSettings"].exists)
        app.terminate()

        // 2. Ordinary web page: identical "Agent" shell, then type a question and run the Agent.
        app = launch(base + ["-dc-browser-agent-fixture-page", "-dc-browser-agent-demo", "empty", "-dc-drawer-detent", "large"], orientation: isPhone ? .portrait : .landscapeLeft)
        showAssistant(in: app)
        let ordinaryTitle = any(app, "drawerTitle")
        XCTAssertTrue(waitOrDump(ordinaryTitle, timeout: 15, in: app))
        XCTAssertEqual(ordinaryTitle.label, "Agent")
        XCTAssertTrue(app.buttons["pageCapabilitiesSeal"].firstMatch.exists)
        XCTAssertTrue(any(app, "agentEmptyState").exists, "Ordinary page should show the identical wave mascot empty state.")
        XCTAssertFalse(any(app, "agentStatusLine").exists)
        XCTAssertTrue(app.buttons["composerMic"].exists)

        let promptInput = app.textFields["agentPromptInput"].firstMatch
        XCTAssertTrue(waitForHittable(promptInput, timeout: 10))
        promptInput.tap()
        promptInput.typeText("Make this page dark and hide the sidebar")

        let sendButton = app.buttons["agentSendButton"].firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "Typing in composer must switch mic ring to Send.")
        if sendButton.isHittable {
            sendButton.tap()
        } else {
            sendButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        XCTAssertTrue(any(app, "agentUserMessage").waitForExistence(timeout: 10))
        let statusLine = any(app, "agentStatusLine")
        XCTAssertTrue(wait(timeout: 20) {
            statusLine.exists && statusLine.label.contains("Done ·")
        }, "Agent status line did not show transient completion.")
        XCTAssertFalse(statusLine.label.contains("tokens"), "Token count must be hidden when developerMode is off.")
        XCTAssertTrue(any(app, "agentAssistantReply").exists)
    }

    func testCaptureWuko23ProofScreenshots() throws {
        guard ProcessInfo.processInfo.environment["DC_SCREENSHOT_DIR"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_DC_SCREENSHOT_DIR to capture WUKO-23 proof screenshots.")
        }
        let device = isPhone ? "iphone" : "ipad"
        let orient: UIDeviceOrientation = isPhone ? .portrait : .landscapeLeft
        let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

        for (suffix, style) in [("light", "Light"), ("dark", "Dark")] {
            let styleArgs = base + ["-AppleInterfaceStyle", style]

            // 1. Forum fixture showing the unified Agent panel (empty wave mascot + This page seal + composer).
            let forumApp = launch(styleArgs + ["-dc-sample", "-dc-no-summary", "-dc-drawer-detent", "medium"], orientation: orient)
            showAssistant(in: forumApp)
            XCTAssertTrue(waitOrDump(any(forumApp, "agentEmptyState"), timeout: 15, in: forumApp))
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            capture("\(device)-forum-panel-\(suffix)")

            if suffix == "light" {
                forumApp.buttons["pageCapabilitiesSeal"].firstMatch.tap()
                XCTAssertTrue(waitOrDump(any(forumApp, "pageScriptsPopover"), timeout: 8, in: forumApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                capture("\(device)-this-page-popover-light")
            }
            forumApp.terminate()

            // 2. Ordinary non-forum page showing the exact same Agent panel.
            let webApp = launch(styleArgs + ["-dc-browser-agent-fixture-page", "-dc-browser-agent-demo", "empty", "-dc-drawer-detent", "medium"], orientation: orient)
            showAssistant(in: webApp)
            XCTAssertTrue(waitOrDump(any(webApp, "agentEmptyState"), timeout: 15, in: webApp))
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            capture("\(device)-ordinary-panel-\(suffix)")

            // 3. Typed question running the Agent through AssistantComposer -> completed turn + Done status line.
            if suffix == "light" || !isPhone {
                let input = webApp.textFields["agentPromptInput"].firstMatch
                XCTAssertTrue(waitForHittable(input, timeout: 10))
                input.tap()
                input.typeText("Make this page dark and hide the sidebar")
                let send = webApp.buttons["agentSendButton"].firstMatch
                XCTAssertTrue(send.waitForExistence(timeout: 5))
                if send.isHittable {
                    send.tap()
                } else {
                    send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                let statusLine = any(webApp, "agentStatusLine")
                XCTAssertTrue(wait(timeout: 20) { statusLine.exists && statusLine.label.contains("Done ·") })
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                capture("\(device)-typed-agent-run-\(suffix)")
            }
            webApp.terminate()
        }
    }
}
