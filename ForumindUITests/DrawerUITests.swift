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

    func testNativeAssistantMenuKeepsReportReachable() throws {
        try skipUnlessPhone("Drawer variants")
        let app = launch(sample)
        XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 20))
        captureAuditScreen("drawer-summary-medium", in: app)
        app.buttons["assistantMoreMenu"].tap()
        let report = app.buttons["Report This Summary…"].firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        captureAuditScreen("more-menu", in: app)
        let menu = app.collectionViews.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let start = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(waitForHittable(report), "Native menus must scroll to their final actions")
        captureAuditScreen("more-menu-scrolled", in: app)
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
                    if r > 220 && g > 220 && b > 245 && b - r > 8 {
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

    func testLatestMessageControlLeavesChatActionsUncovered() throws {
        try skipUnlessPhone("Drawer chat layout")
        continueAfterFailure = true
        let app = launch(sample + ["-dc-assistant-mode", "chat", "-dc-drawer-detent", "large"])
        let jump = app.buttons["chatScrollToBottom"]
        XCTAssertTrue(jump.waitForExistence(timeout: 20))
        let scroll = any(app, "chatScroll")
        XCTAssertGreaterThanOrEqual(jump.frame.minY, scroll.frame.maxY - 1,
            "The latest-message control must reserve space outside the message viewport")
        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(reveal(edit, in: app))
        if jump.exists {
            XCTAssertFalse(jump.frame.intersects(edit.frame), "Edit must remain uncovered")
        }
        captureAuditScreen("base-chat-edit-action", in: app)
    }

    func testAccessibilityChatEditingKeepsQuestionReadable() throws {
        try skipUnlessPhone("Drawer accessibility editing")
        let app = launch(sample + ["-dc-assistant-mode", "chat", "-dc-drawer-detent", "large",
            "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
        XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 20))
        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(reveal(edit, in: app, swipes: 48))
        // reveal's swipes fling: a tap while the chat still glides misses the button.
        var last = CGRect.null
        XCTAssertTrue(wait(timeout: 5) { let frame = edit.frame; defer { last = frame }; return frame == last })
        edit.tap()
        let field = app.textFields["chatInput"]
        XCTAssertTrue(any(app, "chatEditBanner").waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(field.frame.width, 180)
        let title = app.staticTexts["Editing question"].firstMatch
        let font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith:
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        let titleWidth = (title.label as NSString).size(withAttributes: [.font: font]).width
        XCTAssertTrue(title.frame.width >= titleWidth - 2 || title.frame.height >= font.lineHeight * 2 - 2,
                      "The editing banner must show its full title")
        let wordWidth = ("question" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThanOrEqual(title.frame.width, wordWidth - 2, "Editing words must fit without hyphenation")
        XCTAssertTrue(app.buttons["cancelChatEdit"].isHittable)
        XCTAssertTrue(app.buttons["assistantMoreMenu"].isHittable)
        captureAuditScreen("ax5-chat-edit", in: app)
    }

    func testAccessibilityDrawerKeepsTitleAndComposerReadable() throws {
        try skipUnlessPhone("Drawer accessibility layout")
        for detent in ["medium", "large"] {
            let app = launch(sample + ["-dc-drawer-detent", detent,
                "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
            XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 20))
            XCTAssertTrue(wait(timeout: 5) { drawerState(in: app).label == "detent=\(detent)" })
            let title = any(app, "drawerTitle")
            let field = app.textFields["chatInput"]
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
            XCTAssertGreaterThanOrEqual(app.buttons["Send question"].frame.width, 44 * scale)
            if detent == "large" {
                any(app, "summaryDetails").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let metadata = app.staticTexts.matching(label(contains: "88 posts")).firstMatch
                XCTAssertTrue(metadata.waitForExistence(timeout: 5))
                XCTAssertTrue(metadata.label.contains("Kept"))
                captureAuditScreen("ax5-summary-details", in: app)
                app.buttons["assistantMoreMenu"].tap()
                let model = app.buttons.matching(label(contains: "claude-sonnet-4-5")).firstMatch
                XCTAssertTrue(model.waitForExistence(timeout: 5), "Model selection stays available in More at accessibility sizes")
                captureAuditScreen("ax5-model-overflow", in: app)
            }
        }
    }

    func testAskControlsStayInsideBarAcrossDetentsAndKeyboard() throws {
        try skipUnlessPhone("Drawer geometry")
        continueAfterFailure = true
        let server = FixtureWordPressServer()
        try server.start()
        defer { server.stop() }
        server.streamedSummary = (["## Summary\n" + String(repeating: "Readers compare the options and explain their experiences. #1\n\n", count: 30)], 0.001)
        let app = launch(["-dc-open", server.postURL, "-dc-fixture-model", server.baseURL,
                          "-dc-voice-fake", "-AppleInterfaceStyle", "Light",
                          "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.large.rawValue])
        showAssistant(in: app)
        let summarize = app.buttons["createSummary"].firstMatch
        XCTAssertTrue(waitOrDump(summarize, timeout: 30, in: app))
        summarize.tap()
        let retry = app.buttons["retrySummary"].firstMatch
        XCTAssertTrue(wait(timeout: 30) { retry.exists && retry.isEnabled })
        XCTAssertTrue(any(app, "askSuggestions").exists)
        let bar = any(app, "askBox")
        XCTAssertTrue(waitOrDump(bar, timeout: 20, in: app))
        var iconInk: [String: Set<Int>] = [:]
        func ink(in frame: CGRect, screenshot: XCUIScreenshot) -> Set<Int> {
            guard let image = screenshot.image.cgImage else { return [] }
            let scale = CGFloat(image.width) / app.windows.firstMatch.frame.width
            let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                              width: frame.width * scale, height: frame.height * scale).integral
            guard let crop = image.cropping(to: rect) else { return [] }
            var pixels = [UInt8](repeating: 0, count: 44 * 44 * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 44, height: 44,
                                        bitsPerComponent: 8, bytesPerRow: 44 * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(crop, in: CGRect(x: 0, y: 0, width: 44, height: 44))
            }
            return Set((0..<(44 * 44)).filter {
                pixels[$0 * 4] < 180 && pixels[$0 * 4 + 1] < 180
                    && pixels[$0 * 4 + 2] < 180 && pixels[$0 * 4 + 3] > 240
            })
        }
        func find(_ node: XCUIElementSnapshot, _ id: String, _ type: XCUIElement.ElementType) -> XCUIElementSnapshot? {
            if node.identifier == id, node.elementType == type { return node }
            return node.children.lazy.compactMap { find($0, id, type) }.first
        }
        func check(_ stage: String) {
            // One snapshot: separate frame queries during a drag observe different instants.
            guard let snapshot = try? bar.snapshot(),
                  let field = find(snapshot, "chatInput", .textField)?.frame else {
                XCTFail("\(stage): missing bar or field")
                return
            }
            let bounds = snapshot.frame
            let screenshot = app.screenshot()
            var frames = "\(stage): bar=\(bounds), field=\(field)"
            for id in ["chatInstructions", "voiceButton"] {
                guard let icon = find(snapshot, id, .button)?.frame else {
                    XCTFail("\(stage): missing \(id)")
                    continue
                }
                XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(icon), "\(stage): \(id) \(icon) outside bar \(bounds)")
                XCTAssertEqual(icon.maxY - field.maxY, 11, accuracy: 2, "\(stage): \(id) drifted from field bottom")
                // AX geometry alone cannot detect a glyph painted in the wrong layer.
                // Compare its ink inside the expected slot while the bar is visible.
                if stage != "closing" {
                    let current = ink(in: icon, screenshot: screenshot)
                    XCTAssertGreaterThan(current.count, 15, "\(stage): \(id) is not drawn in its bar slot")
                    XCTAssertLessThan(current.count, 300, "\(stage): expected an icon on the light bar background")
                    if let reference = iconInk[id] {
                        let matched = current.filter { point in
                            (-2...2).contains { dy in
                                (-2...2).contains { dx in reference.contains(point + dy * 44 + dx) }
                            }
                        }.count
                        XCTAssertGreaterThan(Double(matched) / Double(max(current.count, 1)), 0.65,
                                             "\(stage): \(id)'s rendered glyph drifted")
                    } else {
                        iconInk[id] = current
                    }
                }
                frames += ", \(id)=\(icon)"
            }
            attachText(frames, named: stage)
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = stage
            shot.lifetime = .keepAlways
            add(shot)
        }
        func sampleMotion(_ stage: String, gesture: () -> Void) {
            var sampled = false
            let timer = Timer(timeInterval: 0.9, repeats: false) { _ in
                if bar.exists {
                    check(stage)
                    sampled = true
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            gesture()
            timer.invalidate()
            XCTAssertTrue(sampled, "Read bar-relative frames during \(stage)")
        }
        check("medium")
        sampleMotion("expanding") { dragDrawer(in: app, to: 0.08) }
        check("large")
        dragDrawer(in: app, to: 0.54)
        check("medium-again")
        // Focus from medium: sheet expansion and keyboard avoidance happen together.
        app.textFields["chatInput"].tap()
        XCTAssertTrue(wait(timeout: 5) { drawerState(in: app).label == "detent=large" })
        let keyboard = app.keyboards.firstMatch
        // With Simulator's hardware keyboard connected the software keyboard sits below the
        // screen: there is nothing to avoid, so only the overlap check depends on it.
        let softwareKeyboard = wait(timeout: 5) {
            keyboard.exists && keyboard.frame.height > 150
                && keyboard.frame.minY < app.windows.firstMatch.frame.maxY - 150
        }
        if !softwareKeyboard {
            attachText("Hardware keyboard connected (keyboard \(keyboard.frame)): keyboard overlap not checked", named: "keyboard mode")
        }
        // The keyboard exposes its target before the keyboard and hint animations settle.
        var previousBarFrame = CGRect.null
        XCTAssertTrue(wait(timeout: 5) {
            let frame = bar.frame
            defer { previousBarFrame = frame }
            return frame == previousBarFrame
        }, "Keyboard and hint layout must settle")
        // Capture before typeText attaches XCUITest's hardware keyboard.
        check("keyboard")
        if softwareKeyboard {
            XCTAssertLessThanOrEqual(bar.frame.maxY, keyboard.frame.minY + 1, "Bar background must stop above keyboard")
        }
        app.textFields["chatInput"].typeText("A follow-up")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        check("large-after-keyboard")
        dragDrawer(in: app, to: 0.54)
        check("lowered")
        let header = any(app, "drawerHeader")
        let start = header.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.90))
        sampleMotion("closing") {
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 3)
        }
        XCTAssertTrue(waitForGone(bar, timeout: 5))
        XCTAssertFalse(app.buttons["chatInstructions"].exists, "Instructions must leave with the bar")
    }

    func testAskScopeLeavesRoomForQuestion() throws {
        let app = launch(sample + ["-dc-voice-fake"])
        let field = app.textFields["chatInput"]
        XCTAssertTrue(waitOrDump(field, timeout: 20, in: app))
        XCTAssertGreaterThanOrEqual(field.frame.width, 90, "The scope must leave room for a readable question")
    }

    func testTypingFollowUpKeepsSummaryPosition() throws {
        let app = launch(sample)
        XCTAssertTrue(waitOrDump(any(app, "askBox"), timeout: 20, in: app))
        dragDrawer(in: app, to: 0.08)
        let marker = app.buttons["retrySummary"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        let field = app.textFields["chatInput"]
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
        let alert = app.alerts["Forumind"]
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
        let alert = app.alerts["Forumind"]
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
        let alert = app.alerts["Forumind"]
        XCTAssertTrue(waitOrDump(alert, timeout: 30, in: app), "The root alert was blocked by a dropped drawer.")
        XCTAssertTrue(alert.staticTexts["Test error"].exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 10), "The drawer did not come up.")
    }

    /// Report or block (a routed sheet).
    func testReportSheetShowsOverTheDrawer() throws {
        let app = try launchWithDrawer(presenting: "report", at: "large")
        let sheet = app.navigationBars["Report or block"]
        XCTAssertTrue(waitOrDump(sheet, timeout: 20, in: app), "The report sheet did not show over the drawer.")
        sheet.buttons["Done"].tap()
        assertDrawer(at: "large", in: app, after: sheet)
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
    /// over the bar has the "Summarize this topic" tip. Its text opens the
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
        XCTAssertEqual(text.label, "Summarize this topic")
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
        XCTAssertEqual(button.label, "Summarize this topic")
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
        let summarize = app.buttons["createSummary"].firstMatch
        XCTAssertTrue(waitForHittable(summarize), "Create summary is missing.")
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
        let summarize = app.buttons["createSummary"].firstMatch
        XCTAssertTrue(waitForHittable(summarize), "Create summary is missing.")
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
    func testAskBoxScopeKeepsTheTextAndAWholeForumRunShowsInHistory() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + ["-dc-no-provider"])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "Got \(state.label).")

        let first = app.buttons["citation-3"].firstMatch
        let second = app.buttons["citation-7"].firstMatch
        // Lazy summary rows can be outside the medium viewport.
        XCTAssertTrue(reveal(first, in: app), "The sample summary has no #3 citation.")
        XCTAssertGreaterThanOrEqual(first.frame.width, 44, "A citation chip must be 44 pt wide to tap.")
        if second.exists, abs(second.frame.midY - first.frame.midY) < 4 {
            XCTAssertGreaterThanOrEqual(second.frame.minX - first.frame.maxX, 4, "Citation chips need 4 pt between them.")
        }

        let question = "Retention offers this year"
        let chat = app.textFields["chatInput"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "The Ask box has no field.")
        chat.tap()
        chat.typeText(question)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" }, "Focusing the field must raise the drawer.")

        let scope = any(app, "askScopeButton")
        XCTAssertTrue(waitForHittable(scope), "The Ask box has no scope button.")
        scope.tap()
        let wholeForum = app.buttons["Whole forum"].firstMatch
        XCTAssertTrue(wholeForum.waitForExistence(timeout: 5), "The scope menu has no Whole forum.")
        wholeForum.tap()

        // The sample's run on this forum is finished: the box follows it up.
        let followUp = app.textFields["agentFollowUpInput"]
        XCTAssertTrue(followUp.waitForExistence(timeout: 10), "Whole forum did not follow up the selected run.")
        XCTAssertEqual(followUp.value as? String, question, "Switching the scope lost the typed text.")
        XCTAssertFalse(app.textFields["chatInput"].exists)

        let newQuestion = app.buttons["agentNewQuestion"]
        if !newQuestion.isHittable { app.swipeDown() }
        XCTAssertTrue(waitForHittable(newQuestion), "New question is missing.")
        newQuestion.tap()
        let goal = app.textFields["agentGoalInput"]
        XCTAssertTrue(goal.waitForExistence(timeout: 10))
        XCTAssertEqual(goal.value as? String, question, "New question lost the typed text.")
        XCTAssertTrue(any(app, "agentExample").exists, "A new question shows the example questions.")

        let run = app.buttons["runAgent"]
        XCTAssertTrue(run.isEnabled)
        run.tap()
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) { alert.buttons["OK"].tap() }
        let runGoal = app.staticTexts["agentRunGoal"]
        XCTAssertTrue(runGoal.waitForExistence(timeout: 10), "The run did not show.")
        XCTAssertEqual(runGoal.label, question)

        // History lists the run under Asks.
        let more = app.buttons["assistantMoreMenu"]
        XCTAssertTrue(waitForHittable(more))
        more.tap()
        // Not Ask the forum's own History menu (agentHistoryMenu).
        let history = app.buttons
            .matching(NSPredicate(format: "label == 'History' AND identifier != 'agentHistoryMenu'"))
            .firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        let asks = app.buttons["historySegment-asks"]
        XCTAssertTrue(asks.waitForExistence(timeout: 10), "History did not open.")
        asks.tap()
        // Running it shows in progress, finished under Asks; either way the goal is listed.
        XCTAssertTrue(reveal(app.staticTexts[question], in: app), "The new run is not listed under Asks.")
    }

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

    /// Pressing the software keyboard's Send key in the forum home Ask field
    /// submits Ask the forum instead of inserting a newline.
    func testForumHomeSendKeySubmitsAskTheForum() throws {
        let app = launch(["-dc-sample", "-dc-page-state", "forumHome", "-dc-no-provider"])
        showAssistant(in: app)
        let goalField = any(app, "forumHomeGoalInput")
        XCTAssertTrue(waitOrDump(goalField, timeout: 15, in: app))
        goalField.tap()
        let question = "best backup plugin"
        goalField.typeText(question)
        goalField.typeText("\n")

        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) { alert.buttons["OK"].tap() }
        XCTAssertTrue(waitForGone(any(app, "forumHomeState"), timeout: 5),
                      "Pressing Send on ForumHomeState goal field inserted a newline instead of starting Ask the forum.")
        let runGoal = app.staticTexts["agentRunGoal"]
        XCTAssertTrue(runGoal.waitForExistence(timeout: 10), "The Ask the forum run did not appear.")
        XCTAssertEqual(runGoal.label, question)
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
        showAssistant(in: app)
        XCTAssertTrue(waitOrDump(app.buttons["createSummary"].firstMatch, timeout: 25, in: app))
        closeDrawer(in: app)
        openForumMenu(in: app)
        XCTAssertTrue(app.buttons["Watch this topic"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["menuTranslatePosts"].exists)
    }

    func testEditingChatQuestionKeepsHistoryUntilSubmittedAndSupportsCancel() throws {
        try skipUnlessPhone("iPhone drawer chat edit check.")
        let app = launch(sample + ["-dc-assistant-mode", "chat", "-dc-no-provider"])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        dragDrawer(in: app, to: 0.08)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" }, "Got \(state.label), wanted large.")

        let editButton = app.buttons["Edit"].firstMatch
        let chatScroll = app.scrollViews["chatScroll"].firstMatch
        for _ in 0..<8 where !(editButton.exists && editButton.isHittable) {
            if chatScroll.exists { chatScroll.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(waitForHittable(editButton, timeout: 5), "No Edit button on the sample user question.")

        let originalQuestion = "Why can’t I post more than two links yet?"
        // The sample chat has two turns; Edit (the first) edits the first question.
        let users = app.otherElements.matching(identifier: "chatMessage-user").count
        let replies = app.otherElements.matching(identifier: "chatMessage-assistant").count
        editButton.tap()

        // Tapping Edit populates the composer, shows the Cancel banner, and keeps both chat turns intact.
        let banner = any(app, "chatEditBanner")
        let cancel = app.buttons["cancelChatEdit"]
        let chatField = app.textFields["chatInput"]
        XCTAssertTrue(waitOrDump(banner, timeout: 5, in: app), "Editing banner did not appear.")
        XCTAssertTrue(cancel.exists)
        XCTAssertGreaterThanOrEqual(cancel.frame.width, 44)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
        XCTAssertEqual(chatField.value as? String, originalQuestion)
        XCTAssertEqual(app.otherElements.matching(identifier: "chatMessage-user").count, users)
        XCTAssertEqual(app.otherElements.matching(identifier: "chatMessage-assistant").count, replies)

        // Cancel leaves history untouched and clears the composer back to its prior draft.
        cancel.tap()
        XCTAssertTrue(waitForGone(banner, timeout: 5))
        XCTAssertEqual(app.otherElements.matching(identifier: "chatMessage-user").count, users)
        XCTAssertEqual(app.otherElements.matching(identifier: "chatMessage-assistant").count, replies)

        // Edit again and submit: the old question and assistant reply are replaced by the edited turn.
        // Cancel keeps the composer focused, so only a short strip above the keyboard shows the
        // chat and the first question can sit below or above it. Swipes fling past that strip
        // (and blind swipes down reach the top and drag the drawer closed): step toward the
        // question with short drags that stop without momentum.
        let composer = any(app, "askBox")
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<12 where !(editButton.exists && editButton.isHittable) {
            let mid = (chatScroll.frame.minY + composer.frame.minY) / 2
            let up = !editButton.exists || editButton.frame.midY > mid
            let start = origin.withOffset(CGVector(dx: chatScroll.frame.midX, dy: mid + (up ? 50 : -50)))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: up ? -100 : 100)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(waitForHittable(editButton, timeout: 5))
        editButton.tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        chatField.tap()
        chatField.typeText(" Or moderators?")
        let send = app.buttons["Send question"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 4) { alert.buttons.firstMatch.tap() }

        XCTAssertTrue(waitForGone(banner, timeout: 5))
        XCTAssertEqual(app.otherElements.matching(identifier: "chatMessage-assistant").count, 0, "Old assistant reply must be removed when edited question is submitted.")
        XCTAssertTrue(app.staticTexts["Why can’t I post more than two links yet? Or moderators?"].waitForExistence(timeout: 5))
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
            let chatScroll = any(app, "chatScroll")
            if chatScroll.exists { chatScroll.swipeUp() }
        }
        XCTAssertTrue(waitForGone(jumpBtn, timeout: 5), "Reader starts at bottom with no scroll-to-bottom button")

        let input = any(app, "chatInput")
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
}
