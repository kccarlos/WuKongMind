import UIKit
import XCTest

final class BrowserBarMorphUITests: DCUITestCase {
    private struct BarDebugSnapshot {
        var progress: Double
        var displayProgress: Double
        var isMinimized: Bool
        var isAtRest: Bool
        var insetBottom: Int
        var adjustedBottom: Int
        var offsetY: Int
        var maxOffsetY: Int
        var minimizeCount: Int
        var expandCount: Int

        static func parse(_ raw: String) -> BarDebugSnapshot? {
            var values: [String: String] = [:]
            for token in raw.split(separator: " ") {
                let parts = token.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                values[String(parts[0])] = String(parts[1])
            }
            guard let p = values["p"].flatMap(Double.init),
                  let displayP = values["displayP"].flatMap(Double.init),
                  let minimized = values["minimized"].flatMap(Int.init),
                  let atRest = values["atRest"].flatMap(Int.init),
                  let insetBottom = values["insetBottom"].flatMap(Int.init),
                  let adjustedBottom = values["adjustedBottom"].flatMap(Int.init),
                  let offsetY = values["offsetY"].flatMap(Int.init),
                  let maxOffsetY = values["maxOffsetY"].flatMap(Int.init),
                  let minCount = values["minCount"].flatMap(Int.init),
                  let expCount = values["expCount"].flatMap(Int.init)
            else {
                return nil
            }
            return BarDebugSnapshot(
                progress: p,
                displayProgress: displayP,
                isMinimized: minimized == 1,
                isAtRest: atRest == 1,
                insetBottom: insetBottom,
                adjustedBottom: adjustedBottom,
                offsetY: offsetY,
                maxOffsetY: maxOffsetY,
                minimizeCount: minCount,
                expandCount: expCount
            )
        }
    }

    private func debugSnapshot(in app: XCUIApplication) -> BarDebugSnapshot? {
        let element = any(app, "browserBarDebugState")
        guard element.exists else { return nil }
        return BarDebugSnapshot.parse(element.label)
    }

    private func waitForDebug(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        where predicate: (BarDebugSnapshot) -> Bool
    ) -> BarDebugSnapshot? {
        var latest: BarDebugSnapshot?
        let matched = wait(timeout: timeout) {
            guard let snap = debugSnapshot(in: app) else { return false }
            latest = snap
            return predicate(snap)
        }
        return matched ? latest : nil
    }

    /// Performs a controlled vertical drag on the web view and holds at the end so `willDecelerate` is `false`.
    private func controlledDrag(
        on webView: XCUIElement,
        fromNormalizedY startY: CGFloat,
        toNormalizedY endY: CGFloat,
        holdDuration: TimeInterval = 0.35
    ) {
        let start = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        start.press(
            forDuration: 0.06,
            thenDragTo: end,
            withVelocity: .default,
            thenHoldForDuration: holdDuration
        )
    }

    func testScrollingCollapsesToPillTapExpandsAndRestInsetsSwitch() throws {
        try skipUnlessPhone("B1 covers the iPhone morphing bar; iPad split bar collapse is B3.")

        let app = launch(["-dc-browse-debug", "-dc-bar-morph-fixture", "long", "-dc-bar", "automatic"])
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15))

        let title = app.buttons["browserTitle"]
        let pill = app.buttons["browserChromeStrip"]
        let back = app.buttons["browserBack"]
        let aiButton = app.buttons["aiButton"]

        guard let initial = waitForDebug(
            in: app,
            timeout: 15,
            where: { $0.maxOffsetY > 1500 && $0.isAtRest && $0.progress <= 0.001 }
        ) else {
            attachTree(app)
            XCTFail("Long fixture page did not settle in expanded state.")
            return
        }

        XCTAssertTrue(title.exists, "Expanded bar shows browserTitle.")
        XCTAssertFalse(pill.exists, "Expanded bar hides collapsed pill tap target.")
        XCTAssertEqual(initial.insetBottom, 86, "Web-view bottom inset is 86 at expanded rest.")
        XCTAssertEqual(initial.adjustedBottom, 86)
        capture("b1-phone-expanded")

        // 1. Drag straight to collapsed (`p = 1`) without coasting: collapses to pill and switches inset to 0 at rest.
        controlledDrag(on: webView, fromNormalizedY: 0.68, toNormalizedY: 0.28)

        guard let collapsedAfterDrag = waitForDebug(
            in: app,
            timeout: 8,
            where: { $0.isAtRest && $0.progress >= 0.999 && $0.insetBottom == 0 }
        ) else {
            attachTree(app)
            XCTFail("Dragging down did not rest collapsed with insetBottom == 0.")
            return
        }

        XCTAssertTrue(pill.waitForExistence(timeout: 3), "Collapsed pill button exists.")
        XCTAssertTrue(pill.label.contains("news.example.org"), "Collapsed pill label names the domain: \(pill.label)")
        XCTAssertFalse(back.exists, "Side buttons are removed past p >= 0.5.")
        XCTAssertFalse(aiButton.exists, "Agent button is removed past p >= 0.5.")
        XCTAssertEqual(collapsedAfterDrag.insetBottom, 0)
        XCTAssertEqual(collapsedAfterDrag.adjustedBottom, 0)
        capture("b1-phone-collapsed-pill")

        // 2. Drag straight back to expanded (`p = 0`) without coasting: switches inset back to 86 at rest.
        controlledDrag(on: webView, fromNormalizedY: 0.30, toNormalizedY: 0.70)

        guard let expandedAfterDrag = waitForDebug(
            in: app,
            timeout: 8,
            where: { $0.isAtRest && $0.progress <= 0.001 && $0.insetBottom == 86 }
        ) else {
            attachTree(app)
            XCTFail("Dragging straight back to expanded did not restore insetBottom == 86.")
            return
        }
        XCTAssertTrue(title.exists)
        XCTAssertFalse(pill.exists)
        XCTAssertEqual(expandedAfterDrag.insetBottom, 86)
        XCTAssertEqual(expandedAfterDrag.adjustedBottom, 86)

        // 3. Collapse again, then tap the pill: springs open and switches inset back to 86 at rest with no offset jump.
        controlledDrag(on: webView, fromNormalizedY: 0.68, toNormalizedY: 0.28)
        guard let collapsedBeforeTap = waitForDebug(in: app, timeout: 8, where: { $0.isAtRest && $0.progress >= 0.999 && $0.insetBottom == 0 }) else {
            attachTree(app)
            XCTFail("Second drag down did not rest collapsed.")
            return
        }
        XCTAssertTrue(pill.waitForExistence(timeout: 3))

        tapBarItem(pill)

        guard let expandedAfterTap = waitForDebug(
            in: app,
            timeout: 8,
            where: { $0.isAtRest && $0.progress <= 0.001 && $0.insetBottom == 86 }
        ) else {
            attachTree(app)
            XCTFail("Tapping the collapsed pill did not expand the bar and restore insetBottom == 86.")
            return
        }
        XCTAssertTrue(waitForBarItem(title, timeout: 5))
        XCTAssertTrue(aiButton.exists)
        XCTAssertFalse(pill.exists)
        XCTAssertEqual(expandedAfterTap.insetBottom, 86)
        XCTAssertEqual(expandedAfterTap.adjustedBottom, 86)
        XCTAssertLessThanOrEqual(
            abs(expandedAfterTap.offsetY - collapsedBeforeTap.offsetY),
            1,
            "Switching contentInset.bottom from 0 to 86 at rest must not jump the page offset."
        )

        // 4. Tapping `browserTitle` after morph cycles opens `addressField`; Cancel returns to the expanded bar.
        tapBarItem(title)
        let addressField = app.textFields["addressField"]
        let openedAddress = addressField.waitForExistence(timeout: 5)
        if !openedAddress { attachTree(app) }
        XCTAssertTrue(openedAddress, "Tapping browserTitle after morph opens addressField.")
        app.buttons["addressCancel"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }

    func testCoastingToEndExpandsAndBottomFurtherDragReExpandsWithoutFlapping() throws {
        try skipUnlessPhone("B1 covers the iPhone morphing bar; iPad split bar collapse is B3.")

        let app = launch(["-dc-browse-debug", "-dc-bar-morph-fixture", "long", "-dc-bar", "automatic"])
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15))
        let title = app.buttons["browserTitle"]

        XCTAssertNotNil(waitForDebug(in: app, timeout: 15) { $0.maxOffsetY > 1500 && $0.isAtRest && $0.insetBottom == 86 })

        // First collapse mid-page so we enter the final fast coasting swipe from `p = 1` (`insetBottom = 0`).
        controlledDrag(on: webView, fromNormalizedY: 0.68, toNormalizedY: 0.28)
        XCTAssertNotNil(waitForDebug(in: app, timeout: 8) { $0.isAtRest && $0.progress >= 0.999 && $0.insetBottom == 0 })

        // Fast swipes down so momentum coasting reaches the bottom of the page.
        for _ in 0..<8 {
            if let snap = debugSnapshot(in: app), snap.offsetY >= snap.maxOffsetY - 120, snap.progress <= 0.01, snap.insetBottom == 86 {
                break
            }
            webView.swipeUp(velocity: .fast)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }

        guard let atBottomExpanded = waitForDebug(
            in: app,
            timeout: 10,
            where: {
                $0.isAtRest
                    && $0.progress <= 0.001
                    && $0.insetBottom == 86
                    && $0.offsetY >= $0.maxOffsetY - 120
            }
        ) else {
            attachTree(app)
            XCTFail("Coasting to the end of the page did not spring the bar open with insetBottom == 86.")
            return
        }
        XCTAssertTrue(title.exists, "Coasting to page end restores expanded bar.")
        XCTAssertEqual(atBottomExpanded.insetBottom, 86)

        // At the page bottom with inset 86 (leaving ~86 pt of scrollable bottom inset room):
        // dragging down further collapses (`minimizeCount` + 1), and lifting finger at the end
        // re-expands (`expandCount` + 1) to `p = 0, insetBottom = 86` with zero flapping.
        let minBefore = atBottomExpanded.minimizeCount
        let expBefore = atBottomExpanded.expandCount

        controlledDrag(on: webView, fromNormalizedY: 0.72, toNormalizedY: 0.25, holdDuration: 0.30)

        guard let reExpanded = waitForDebug(
            in: app,
            timeout: 8,
            where: {
                $0.isAtRest
                    && $0.progress <= 0.001
                    && $0.insetBottom == 86
                    && $0.minimizeCount >= minBefore + 1
                    && $0.expandCount >= expBefore + 1
            }
        ) else {
            let finalSnap = debugSnapshot(in: app)
            attachText("Final debug snapshot: \(String(describing: finalSnap))", named: "bottom-drag-debug")
            attachTree(app)
            XCTFail("Further drag down at page bottom did not collapse during drag and re-expand at finger-up.")
            return
        }

        XCTAssertEqual(reExpanded.minimizeCount, minBefore + 1, "Collapsed exactly once during the further drag.")
        XCTAssertEqual(reExpanded.expandCount, expBefore + 1, "Re-expanded once at finger-up without flapping.")
        XCTAssertEqual(reExpanded.insetBottom, 86)
        XCTAssertTrue(title.exists)

        // Watch for 0.8s after rest to prove there is zero post-settle inset/offset flapping.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        if let stable = debugSnapshot(in: app) {
            XCTAssertTrue(stable.isAtRest)
            XCTAssertEqual(stable.progress, 0, accuracy: 0.001)
            XCTAssertEqual(stable.insetBottom, 86)
            XCTAssertEqual(stable.minimizeCount, reExpanded.minimizeCount, "No flapping after page-end settle.")
            XCTAssertEqual(stable.expandCount, reExpanded.expandCount, "No flapping after page-end settle.")
        }
    }

    func testShortPageNeverCollapsesAndAgentRunningShowsCollapsedRing() throws {
        try skipUnlessPhone("B1 covers the iPhone morphing bar.")

        // 1. Short page (`contentHeight <= viewportHeight`) never collapses.
        let shortApp = launch(["-dc-browse-debug", "-dc-bar-morph-fixture", "short", "-dc-bar", "automatic"])
        let shortWebView = shortApp.webViews.firstMatch
        XCTAssertTrue(shortWebView.waitForExistence(timeout: 15))
        XCTAssertTrue(shortWebView.staticTexts["Short Pinned Note"].waitForExistence(timeout: 10))
        XCTAssertNotNil(waitForDebug(in: shortApp, timeout: 10) { $0.isAtRest && $0.maxOffsetY == 0 })

        shortWebView.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        if let snap = debugSnapshot(in: shortApp) {
            XCTAssertEqual(snap.progress, 0, accuracy: 0.001, "Short page must never collapse.")
            XCTAssertEqual(snap.insetBottom, 86)
            XCTAssertEqual(snap.minimizeCount, 0)
        }
        XCTAssertTrue(shortApp.buttons["browserTitle"].exists)
        XCTAssertFalse(shortApp.buttons["browserChromeStrip"].exists)

        // 2. While Agent is running with panel closed, collapsed pill announces Agent working and renders turning ring.
        let agentApp = launch(["-dc-browse-debug", "-dc-bar-morph-fixture", "agent-running", "-dc-bar", "automatic"])
        let agentWebView = agentApp.webViews.firstMatch
        XCTAssertTrue(agentWebView.waitForExistence(timeout: 15))
        XCTAssertNotNil(waitForDebug(in: agentApp, timeout: 15) { $0.maxOffsetY > 1500 && $0.isAtRest })

        // Wait until the demo Agent starts running.
        let stopOrRunning = wait(timeout: 6) {
            agentApp.buttons["aiButton"].exists
        }
        XCTAssertTrue(stopOrRunning)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        controlledDrag(on: agentWebView, fromNormalizedY: 0.68, toNormalizedY: 0.28)
        let pill = agentApp.buttons["browserChromeStrip"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertTrue(pill.label.contains("Agent working"), "Collapsed pill announces Agent working: \(pill.label)")
        capture("b1-phone-collapsed-agent-working")
    }

    func testPageFormKeyboardFreezesProgressAndKeepsRestBottomInset() throws {
        try skipUnlessPhone("Covers iPhone page-form keyboard safe-area isolation and progress freeze.")

        let app = launch(["-dc-browse-debug", "-dc-bar-morph-fixture", "long", "-dc-bar", "automatic"])
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15))
        XCTAssertNotNil(waitForDebug(in: app, timeout: 15) { $0.maxOffsetY > 1500 && $0.isAtRest && $0.insetBottom == 86 })

        // 1. Focus top page form field while expanded (`p = 0`): keyboard height must NOT leak into `insetBottom` (stays 86).
        let topField = webView.textFields["Filter notes"]
        XCTAssertTrue(topField.waitForExistence(timeout: 10))
        topField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), "Focusing a page input raises the system keyboard.")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        guard let expandedKeyboardSnap = debugSnapshot(in: app) else {
            XCTFail("Missing browserBarDebugState while page form keyboard is up.")
            return
        }
        XCTAssertEqual(expandedKeyboardSnap.progress, 0, accuracy: 0.001, "Progress stays frozen at 0 while keyboard is up.")
        XCTAssertEqual(expandedKeyboardSnap.insetBottom, 86, "Keyboard height must not leak into expandedBottomInset (expected 86, got \(expandedKeyboardSnap.insetBottom)).")
        let hidBar = waitForGone(app.buttons["browserTitle"], timeout: 2)
        if !hidBar { attachTree(app) }
        XCTAssertTrue(hidBar, "Bottom bar hides under the page-form keyboard.")

        // Dragging on the visible upper half of the page while keyboard is up keeps `p` frozen at 0 and `insetBottom` at 86.
        controlledDrag(on: webView, fromNormalizedY: 0.35, toNormalizedY: 0.14)
        if let afterFrozenDrag = debugSnapshot(in: app) {
            XCTAssertEqual(afterFrozenDrag.progress, 0, accuracy: 0.001, "Scrolling while page-form keyboard is up must not advance p.")
            XCTAssertEqual(afterFrozenDrag.insetBottom, 86)
        }

        // Dismiss WebKit's input focus via the accessory Done button or Enter key; bar returns expanded (`p = 0, insetBottom = 86`).
        let dismissPageKeyboard = {
            let accessoryDone = app.toolbars.buttons["Done"].firstMatch
            if accessoryDone.exists, accessoryDone.isHittable {
                accessoryDone.tap()
            } else {
                app.typeText("\n")
            }
        }
        dismissPageKeyboard()
        let restoredTitle = app.buttons["browserTitle"]
        XCTAssertTrue(restoredTitle.waitForExistence(timeout: 5), "Expanded bottom bar reappears after dismissing the page-form keyboard.")
        XCTAssertGreaterThan(restoredTitle.frame.minY, webView.frame.midY, "Restored bar sits at the bottom.")
        XCTAssertNotNil(waitForDebug(in: app, timeout: 5) { $0.isAtRest && $0.progress <= 0.001 && $0.insetBottom == 86 })

        // 2. Scrolling after dismiss proves `p` unfroze (`p = 1, insetBottom = 0`); focus mid-page form field and dismiss again.
        controlledDrag(on: webView, fromNormalizedY: 0.68, toNormalizedY: 0.32)
        let pill = app.buttons["browserChromeStrip"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "Bar unfroze after keyboard dismiss and collapsed to pill on scroll.")
        XCTAssertNotNil(waitForDebug(in: app, timeout: 8) { $0.isAtRest && $0.progress >= 0.999 && $0.insetBottom == 0 })

        let midField = webView.textFields["Reply note"]
        XCTAssertTrue(midField.waitForExistence(timeout: 5))
        if midField.frame.minY < 60 || midField.frame.maxY > webView.frame.maxY - 120 {
            controlledDrag(on: webView, fromNormalizedY: 0.55, toNormalizedY: 0.40)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        midField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), "Focusing mid-page input raises the keyboard.")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let hidPill = waitForGone(pill, timeout: 2)
        if !hidPill { attachTree(app) }
        XCTAssertTrue(hidPill, "Collapsed bottom pill hides under the page-form keyboard.")
        if let collapsedKeyboardSnap = debugSnapshot(in: app) {
            XCTAssertEqual(collapsedKeyboardSnap.progress, 1.0, accuracy: 0.001)
            XCTAssertEqual(collapsedKeyboardSnap.insetBottom, 0, "Collapsed insetBottom stays 0 while keyboard is up.")
        }

        // Dismissing the mid-page keyboard restores the collapsed pill (`p = 1, insetBottom = 0`), and tapping it expands to `p = 0`.
        dismissPageKeyboard()
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "Collapsed bottom pill reappears after dismissing the page-form keyboard.")
        XCTAssertGreaterThan(pill.frame.minY, webView.frame.midY)
        XCTAssertNotNil(waitForDebug(in: app, timeout: 5) { $0.isAtRest && $0.progress >= 0.999 && $0.insetBottom == 0 })

        tapBarItem(pill)
        XCTAssertTrue(restoredTitle.waitForExistence(timeout: 5), "Tapping restored pill expands the bar.")
        XCTAssertNotNil(waitForDebug(in: app, timeout: 5) { $0.isAtRest && $0.progress <= 0.001 && $0.insetBottom == 86 })
    }

    func testVoiceDockHidesBarLocksProgressExpandedAndRestoresOnClose() throws {
        try skipUnlessPhone("Covers iPhone Voice-Dock bottom-bar hide, lock-expanded observer, and restore.")

        let app = launch(["-dc-browse-debug", "-dc-bar-morph-fixture", "long", "-dc-bar", "automatic", "-dc-voice-fake"])
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15))
        XCTAssertNotNil(waitForDebug(in: app, timeout: 15) { $0.maxOffsetY > 1500 && $0.isAtRest && $0.insetBottom == 86 })

        let title = app.buttons["browserTitle"]
        let pill = app.buttons["browserChromeStrip"]
        let ai = app.buttons["aiButton"]
        XCTAssertTrue(waitForBarItem(ai, timeout: 10))

        // Long-pressing the AI button starts a scripted Voice session (`voice.showsBar == true`), hiding the bottom bar.
        pressBarItem(ai, duration: 1.0)
        let voiceBar = any(app, "voiceBar")
        XCTAssertTrue(voiceBar.waitForExistence(timeout: 10), "The Voice Dock appeared.")
        XCTAssertTrue(waitForGone(title, timeout: 3), "Bottom morphing bar hides while Voice Dock is shown.")
        XCTAssertFalse(pill.exists)

        // Scrolling the page while `voiceBar` hides the bottom bar must keep `p == 0` (`isBarLockedExpanded == true`).
        let minBeforeVoiceScroll = debugSnapshot(in: app)?.minimizeCount ?? 0
        controlledDrag(on: webView, fromNormalizedY: 0.45, toNormalizedY: 0.15)
        guard let duringVoiceSnap = waitForDebug(
            in: app,
            timeout: 6,
            where: { $0.isAtRest && $0.offsetY > 60 }
        ) else {
            attachTree(app)
            XCTFail("Page did not scroll while Voice Dock was shown.")
            return
        }
        XCTAssertEqual(duringVoiceSnap.progress, 0, accuracy: 0.001, "Progress stays locked at 0 while Voice Dock is shown.")
        XCTAssertFalse(duringVoiceSnap.isMinimized)
        XCTAssertEqual(duringVoiceSnap.insetBottom, 86)
        XCTAssertEqual(duringVoiceSnap.minimizeCount, minBeforeVoiceScroll, "Scroll under Voice Dock must not minimize the bar.")
        XCTAssertFalse(title.exists)
        XCTAssertFalse(pill.exists)

        // Ending and closing Voice restores the bottom bar (`p = 0, insetBottom = 86`) and unlocks scroll morphing.
        let voiceEnd = app.buttons["voiceEnd"]
        XCTAssertTrue(waitForHittable(voiceEnd))
        voiceEnd.tap()
        let voiceClose = app.buttons["voiceBarClose"]
        XCTAssertTrue(voiceClose.waitForExistence(timeout: 5))
        voiceClose.tap()
        XCTAssertTrue(waitForGone(voiceBar, timeout: 5))

        XCTAssertTrue(title.waitForExistence(timeout: 5), "Expanded bottom bar returns when Voice Dock closes.")
        XCTAssertGreaterThan(title.frame.minY, webView.frame.midY)
        XCTAssertNotNil(waitForDebug(in: app, timeout: 5) { $0.isAtRest && $0.progress <= 0.001 && $0.insetBottom == 86 })

        controlledDrag(on: webView, fromNormalizedY: 0.68, toNormalizedY: 0.32)
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "Closing Voice Dock unlocks bar morphing on subsequent scroll.")
        XCTAssertNotNil(waitForDebug(in: app, timeout: 8) { $0.isAtRest && $0.progress >= 0.999 && $0.insetBottom == 0 })
    }

    func testIPadSplitScrollShrinksResultCardsToChipAndTapRestores() throws {
        try skipUnlessPad("Covers iPad split layout resultCardsChip scroll regression.")

        let app = launch(
            ["-dc-browse-debug", "-dc-bar-morph-fixture", "result-cards"],
            orientation: .landscapeLeft
        )
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15))

        // Confirm split layout (`aiPanelToggle` in top bar) and hide the side panel so `DockLayer` renders `ResultCardsOverlay` over the page.
        let panel = any(app, "aiPanel")
        let toggle = app.buttons["aiPanelToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "Landscape iPad uses split top bar.")
        if panel.waitForExistence(timeout: 8) {
            toggle.tap()
            XCTAssertTrue(waitForGone(panel, timeout: 5), "AI panel hides when toggled.")
        }

        let cards = any(app, "resultCards")
        let chip = app.buttons["resultCardsChip"]
        XCTAssertTrue(cards.waitForExistence(timeout: 8), "Expanded result cards appear over the split page when panel is hidden.")
        XCTAssertFalse(chip.exists)

        guard let initial = waitForDebug(in: app, timeout: 10, where: { $0.maxOffsetY > 1000 && $0.isAtRest }) else {
            attachTree(app)
            XCTFail("Split long fixture did not settle.")
            return
        }
        XCTAssertFalse(initial.isMinimized)
        XCTAssertEqual(initial.insetBottom, 0, "iPad split leaves webView contentInset.bottom at 0.")

        // Scroll down on the upper half of the page (clear of resultCards at the bottom): cards shrink to `resultCardsChip`.
        controlledDrag(on: webView, fromNormalizedY: 0.52, toNormalizedY: 0.18)

        XCTAssertTrue(chip.waitForExistence(timeout: 5), "Scrolling down in iPad split shrinks result cards to resultCardsChip.")
        XCTAssertFalse(cards.exists)
        if let minimizedSnap = debugSnapshot(in: app) {
            XCTAssertTrue(minimizedSnap.isMinimized)
            XCTAssertEqual(minimizedSnap.insetBottom, 0, "iPad split keeps contentInset.bottom at 0 when minimized.")
        }
        capture("b1-ipad-split-cards-chip")

        // Tapping `resultCardsChip` restores the full result cards strip and clears `isChromeMinimized`.
        chip.tap()
        XCTAssertTrue(cards.waitForExistence(timeout: 5), "Tapping resultCardsChip restores expanded result cards.")
        XCTAssertFalse(chip.exists)
        XCTAssertNotNil(waitForDebug(in: app, timeout: 5) { !$0.isMinimized && $0.insetBottom == 0 })
    }

    func testPageMenuInsideAddressFieldForwardInMenuAndBackLongPressAndReloadWorks() throws {
        try skipUnlessPhone("B2 covers the iPhone address field's page menu, reload, and back/forward history.")

        let server = FixtureSpaForumServer()
        try server.start()
        defer { server.stop() }

        let page1URL = "\(server.baseURL)/crawl/page-01.html"
        let app = launch(["-dc-open", page1URL, "-dc-bar", "automatic"])
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15))
        XCTAssertTrue(
            webView.staticTexts.matching(label(contains: "CRAWL-MARKER-01")).firstMatch.waitForExistence(timeout: 15),
            "Page 01 did not finish loading."
        )

        let back = app.buttons["browserBack"]
        let pageMenu = app.buttons["forumSwitcher"]
        let title = app.buttons["browserTitle"]
        let reload = app.buttons["browserReload"]
        let ai = app.buttons["aiButton"]

        XCTAssertTrue(waitForBarItem(title, timeout: 10))
        XCTAssertTrue(back.exists && pageMenu.exists && reload.exists && ai.exists)

        // Page menu and Reload sit strictly inside the address field between Back and Agent.
        XCTAssertLessThanOrEqual(back.frame.maxX, pageMenu.frame.minX + 1, "Page menu sits after Back.")
        XCTAssertLessThanOrEqual(pageMenu.frame.maxX, title.frame.minX + 1, "Page menu leads the domain inside the address field.")
        XCTAssertLessThanOrEqual(title.frame.maxX, reload.frame.minX + 1, "Reload trails the domain inside the address field.")
        XCTAssertLessThanOrEqual(reload.frame.maxX, ai.frame.minX + 1, "Reload sits inside the address field before Agent.")

        // 1. Page menu opens from inside the address field and exposes Forward (disabled before forward history).
        tapBarItem(pageMenu)
        let menuCollection = app.collectionViews.firstMatch
        XCTAssertTrue(menuCollection.waitForExistence(timeout: 5), "Tapping Page menu inside the address field did not open the menu.")
        let menuForward = menuCollection.buttons["Forward"]
        XCTAssertTrue(menuForward.waitForExistence(timeout: 5), "Forward is missing from the page menu.")
        XCTAssertFalse(menuForward.isEnabled, "Forward is disabled before going back.")
        capture("b2-page-menu-open")
        dismissMenu(in: app)
        XCTAssertTrue(waitForGone(menuCollection, timeout: 5))

        // 2. Navigate to page 02, tap Back to return to page 01, then use Forward in the Page menu.
        let nextLink = webView.links["Next page"].firstMatch
        XCTAssertTrue(nextLink.waitForExistence(timeout: 10))
        nextLink.tap()
        XCTAssertTrue(
            webView.staticTexts.matching(label(contains: "CRAWL-MARKER-02")).firstMatch.waitForExistence(timeout: 15),
            "Tapping Next page did not load page 02."
        )
        XCTAssertTrue(wait(timeout: 5) { back.isEnabled }, "Back enables after navigating to page 02.")

        tapBarItem(back)
        XCTAssertTrue(
            webView.staticTexts.matching(label(contains: "CRAWL-MARKER-01")).firstMatch.waitForExistence(timeout: 15),
            "Tapping Back did not return to page 01."
        )
        XCTAssertTrue(wait(timeout: 5) { !back.isEnabled }, "Back disables at the start of history.")

        tapBarItem(pageMenu)
        XCTAssertTrue(menuForward.waitForExistence(timeout: 5))
        XCTAssertTrue(menuForward.isEnabled, "Forward in the page menu enables when forward history exists.")
        menuForward.tap()
        XCTAssertTrue(
            webView.staticTexts.matching(label(contains: "CRAWL-MARKER-02")).firstMatch.waitForExistence(timeout: 15),
            "Tapping Forward in the page menu did not return to page 02."
        )

        // 3. Go back to page 01 again, then long-press Back (even while Back tap is disabled!) to go Forward from history.
        tapBarItem(back)
        XCTAssertTrue(
            webView.staticTexts.matching(label(contains: "CRAWL-MARKER-01")).firstMatch.waitForExistence(timeout: 15)
        )
        pressBarItem(back, duration: 1.0)
        let historyMenu = app.collectionViews.firstMatch
        XCTAssertTrue(historyMenu.waitForExistence(timeout: 5), "Long-pressing Back did not open the history menu.")
        let forwardSection = historyMenu.descendants(matching: .any)["Forward"].firstMatch
        XCTAssertTrue(forwardSection.exists, "Back's long-press history menu has no Forward section.")
        let page2HistoryItem = historyMenu.buttons.matching(label(contains: "page 02")).firstMatch
        XCTAssertTrue(page2HistoryItem.waitForExistence(timeout: 5), "Page 02 is missing from Back's long-press Forward history.")
        capture("b2-back-long-press-history")
        page2HistoryItem.tap()
        XCTAssertTrue(
            webView.staticTexts.matching(label(contains: "CRAWL-MARKER-02")).firstMatch.waitForExistence(timeout: 15),
            "Selecting Page 02 from Back's long-press Forward history did not navigate forward."
        )

        // 4. Open /threads/101 and verify the trailing Reload button inside the address field reloads the page.
        tapBarItem(title)
        let addressField = app.textFields["addressField"]
        XCTAssertTrue(addressField.waitForExistence(timeout: 5))
        addressField.typeText(server.thread101URL + "\n")
        XCTAssertTrue(webView.staticTexts["Load #1"].waitForExistence(timeout: 15), "Initial thread load did not show Load #1.")
        let countBefore = server.requestCount(forPath: "/threads/101")

        XCTAssertTrue(waitForBarItem(reload, timeout: 5))
        tapBarItem(reload)
        XCTAssertTrue(webView.staticTexts["Load #2"].waitForExistence(timeout: 15), "Tapping Reload inside the address field did not reload.")
        XCTAssertGreaterThanOrEqual(server.requestCount(forPath: "/threads/101"), countBefore + 1)
    }

    func testVoiceOverAuditFindsLabelsAndXXXLAndAX5KeepOneRowWith44PtButtons() throws {
        try skipUnlessPhone("B2 VoiceOver audit, XXXL one-row 44 pt check, and Large Content Viewer check.")

        // 1. VoiceOver labels & system Accessibility Audit (expanded + collapsed).
        let app = launch([
            "-dc-browse-debug",
            "-dc-bar-morph-fixture", "long",
            "-dc-bar", "automatic",
            "-AppleInterfaceStyle", "Light"
        ])
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15))
        XCTAssertTrue(webView.staticTexts["Browser Bar Motion Spec"].waitForExistence(timeout: 10))
        XCTAssertNotNil(waitForDebug(in: app, timeout: 15) { $0.maxOffsetY > 1500 && $0.isAtRest && $0.progress <= 0.001 })

        let bar = any(app, "browserBar")
        let back = app.buttons["browserBack"]
        let pageMenu = app.buttons["forumSwitcher"]
        let title = app.buttons["browserTitle"]
        let reload = app.buttons["browserReload"]
        let ai = app.buttons["aiButton"]

        XCTAssertTrue(bar.waitForExistence(timeout: 5), "Expanded bar exposes Browser bar container.")
        XCTAssertEqual(bar.label, "Browser bar")
        XCTAssertEqual(back.label, "Back")
        XCTAssertEqual(pageMenu.label, "Page menu")
        XCTAssertEqual(title.label, "Address field: news.example.org")
        XCTAssertEqual(reload.label, "Reload")
        XCTAssertEqual(ai.label, "Agent")
        capture("b2-phone-expanded-light")

        // Activating the address field edits and shows the full URL.
        XCTAssertTrue(waitForBarItem(title, timeout: 5))
        tapBarItem(title)
        let editField = app.textFields["addressField"]
        XCTAssertTrue(editField.waitForExistence(timeout: 5))
        XCTAssertEqual(editField.value as? String, "https://news.example.org/story/bar-morph")
        app.buttons["addressCancel"].tap()
        XCTAssertTrue(waitForBarItem(title, timeout: 5))

        // Audit every native element in the expanded bar (`performAccessibilityAudit` inspects contrast, hitRegion, traits, labels).
        let barFrame = bar.frame.insetBy(dx: -8, dy: -8)
        try app.performAccessibilityAudit(for: [.elementDetection, .hitRegion, .sufficientElementDescription, .trait, .contrast]) { issue in
            guard let element = issue.element else { return false }
            if element.frame.intersects(barFrame) {
                return false
            }
            return true
        }

        // Collapse and audit the single pill button ("Show browser bar, news.example.org").
        // Over translucent Liquid Glass, WebKit paragraph glyphs behind the pill vary by scroll offset,
        // while solid surface contrast (>= 4.5:1 under Reduce Transparency / Increase Contrast) is verified in unit tests.
        controlledDrag(on: webView, fromNormalizedY: 0.68, toNormalizedY: 0.28)
        let pill = app.buttons["browserChromeStrip"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertEqual(pill.label, "Show browser bar, news.example.org")
        XCTAssertGreaterThanOrEqual(pill.frame.height, 44 - 0.5, "Collapsed pill maintains a 44 pt hit target.")
        let pillFrame = pill.frame.insetBy(dx: -8, dy: -8)
        try app.performAccessibilityAudit(for: [.elementDetection, .hitRegion, .sufficientElementDescription, .trait]) { issue in
            guard let element = issue.element else { return false }
            return !element.frame.intersects(pillFrame)
        }
        app.terminate()

        // 2. XXXL Dynamic Type screenshot & single-row 44 pt button check (Light and Dark).
        let xxxl = UIContentSizeCategory.extraExtraExtraLarge.rawValue
        for style in ["Light", "Dark"] {
            let xxxlApp = launch([
                "-UIPreferredContentSizeCategoryName", xxxl,
                "-dc-browse-debug",
                "-dc-bar-morph-fixture", "long",
                "-dc-bar", "automatic",
                "-AppleInterfaceStyle", style
            ])
            XCTAssertTrue(xxxlApp.webViews.firstMatch.waitForExistence(timeout: 15))
            let xxxlBar = any(xxxlApp, "browserBar")
            let xxxlBack = xxxlApp.buttons["browserBack"]
            let xxxlMenu = xxxlApp.buttons["forumSwitcher"]
            let xxxlTitle = xxxlApp.buttons["browserTitle"]
            let xxxlReload = xxxlApp.buttons["browserReload"]
            let xxxlAI = xxxlApp.buttons["aiButton"]
            XCTAssertTrue(waitForBarItem(xxxlTitle, timeout: 10))

            // `browserBar` reports the content union of its single 44 pt row inside the 56 pt glass capsule.
            XCTAssertGreaterThanOrEqual(xxxlBar.frame.height, 44 - 0.5)
            XCTAssertLessThanOrEqual(xxxlBar.frame.height, 56 + 1.5, "XXXL expanded bar stays one row (\(style)).")
            for (name, button) in [("Back", xxxlBack), ("Page menu", xxxlMenu), ("Reload", xxxlReload), ("Agent", xxxlAI)] {
                XCTAssertGreaterThanOrEqual(button.frame.width, 44 - 0.5, "\(name) width < 44 pt at XXXL (\(button.frame)).")
                XCTAssertGreaterThanOrEqual(button.frame.height, 44 - 0.5, "\(name) height < 44 pt at XXXL (\(button.frame)).")
                XCTAssertLessThanOrEqual(
                    abs(button.frame.midY - xxxlBar.frame.midY),
                    1.5,
                    "\(name) wrapped out of the single bar row at XXXL (\(button.frame) vs bar \(xxxlBar.frame))."
                )
            }
            XCTAssertGreaterThanOrEqual(xxxlTitle.frame.height, 44 - 0.5)
            XCTAssertLessThanOrEqual(xxxlBack.frame.maxX, xxxlMenu.frame.minX + 0.5)
            XCTAssertLessThanOrEqual(xxxlMenu.frame.maxX, xxxlTitle.frame.minX + 0.5)
            XCTAssertLessThanOrEqual(xxxlTitle.frame.maxX, xxxlReload.frame.minX + 0.5)
            XCTAssertLessThanOrEqual(xxxlReload.frame.maxX, xxxlAI.frame.minX + 0.5)

            capture("b2-phone-xxxl-expanded-\(style.lowercased())")
            xxxlApp.terminate()
        }

        // 3. Accessibility Dynamic Type (AX5): stays expanded on one row, 44 pt buttons, middle-truncated domain, Large Content Viewer on long press.
        let ax5 = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
        let axApp = launch([
            "-UIPreferredContentSizeCategoryName", ax5,
            "-dc-browse-debug",
            "-dc-bar-morph-fixture", "long-domain",
            "-dc-bar", "automatic",
            "-dc-voice-fake",
            "-AppleInterfaceStyle", "Light"
        ])
        let axWebView = axApp.webViews.firstMatch
        XCTAssertTrue(axWebView.waitForExistence(timeout: 15))
        let axBar = any(axApp, "browserBar")
        let axBack = axApp.buttons["browserBack"]
        let axMenu = axApp.buttons["forumSwitcher"]
        let axTitle = axApp.buttons["browserTitle"]
        let axReload = axApp.buttons["browserReload"]
        let axAI = axApp.buttons["aiButton"]
        XCTAssertTrue(waitForBarItem(axTitle, timeout: 10))
        XCTAssertEqual(axTitle.label, "Address field: communities.reader-archive.example.org")
        XCTAssertGreaterThanOrEqual(axBar.frame.height, 44 - 0.5)
        XCTAssertLessThanOrEqual(axBar.frame.height, 56 + 1.5, "AX5 bar stays one row.")
        for button in [axBack, axMenu, axReload, axAI] {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44 - 0.5)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44 - 0.5)
        }
        capture("b2-phone-ax5-middle-truncation")

        // Scrolling at AX5 leaves the bar expanded (`p = 0`), because above XXXL a pill is not small.
        axWebView.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(axApp.buttons["browserChromeStrip"].exists, "Above XXXL the bar stays expanded.")

        // Long-pressing the Agent button at AX5 shows Large Content Viewer instead of starting a voice session;
        // sliding off cancels activation so the drawer stays closed too.
        axAI.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.8,
            thenDragTo: axWebView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        )
        XCTAssertFalse(any(axApp, "voiceBar").exists, "At AX5 long-pressing Agent shows Large Content Viewer rather than starting voice.")
        if drawerState(in: axApp).exists {
            closeDrawer(in: axApp)
        }

        // Editing still shows the full URL.
        tapBarItem(axTitle)
        let axField = axApp.textFields["addressField"]
        XCTAssertTrue(axField.waitForExistence(timeout: 5))
        XCTAssertEqual(
            axField.value as? String,
            "https://communities.reader-archive.example.org/story/browser-bar-accessibility"
        )
        capture("b2-phone-ax5-address-editing")
        axApp.buttons["addressCancel"].tap()
        axApp.terminate()

        // 4. Forum page shows the forum avatar inside the leading edge of the address field ("Page menu", value = forum name).
        let forumApp = launch(["-dc-sample", "-dc-page-state", "topic", "-dc-bar", "automatic", "-AppleInterfaceStyle", "Light"])
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        showBrowser(in: forumApp)
        let forumMenu = forumApp.buttons["forumSwitcher"]
        let forumTitle = forumApp.buttons["browserTitle"]
        XCTAssertTrue(waitForBarItem(forumMenu, timeout: 10))
        XCTAssertEqual(forumMenu.label, "Page menu")
        XCTAssertEqual(forumMenu.value as? String, "Discourse Meta")
        XCTAssertEqual(forumTitle.label, "Address field: meta.discourse.org")
        capture("b2-phone-forum-avatar")
    }
}
