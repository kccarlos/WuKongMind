import UIKit
import XCTest

/// Home, the start page (design-unified.md §3): the address field, Today,
/// Sites (pinned first, then most visited), Recent, Continue reading; the
/// Today page pushed over it; pinning from a tile's menu; Add site; and Home
/// with no sites.
final class HomeUITests: DCUITestCase {
    private func siteTiles(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'siteTile-'"))
    }

    func testAddIsLastTileAtStandardAndAccessibilitySizes() throws {
        for category in [UIContentSizeCategory.accessibilityExtraExtraExtraLarge, .large] {
            let app = launch(["-dc-sample", "-dc-forums-home", "-UIPreferredContentSizeCategoryName", category.rawValue],
                             orientation: isPhone ? .portrait : .landscapeLeft)
            openHome(in: app)
            let first = siteTiles(app).firstMatch
            XCTAssertTrue(reveal(first, in: app))
            let add = app.buttons["homeAddSite"]
            XCTAssertTrue(reveal(add, in: app))
            XCTAssertEqual(add.frame.width, first.frame.width, accuracy: 1, "Add must have a tile's width")
            XCTAssertEqual(add.frame.height, first.frame.height, accuracy: 1, "Add must have a tile's height")
            XCTAssertTrue(add.frame.minY > first.frame.minY + 1 || add.frame.minX > first.frame.minX + 1, "Add goes last")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "site-grid-\(category.rawValue)"
            shot.lifetime = .keepAlways
            self.add(shot)
            add.tap()
            XCTAssertTrue(any(app, "addForumAddress").waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    /// A tile's menu pins and unpins (buttons only), and offers Remove.
    func testPinAndUnpinFromTheTileMenu() throws {
        let app = launch(["-dc-sample", "-dc-forums-home"], orientation: isPhone ? .portrait : .landscapeLeft)
        openHome(in: app)
        let tile = siteTiles(app).firstMatch
        XCTAssertTrue(reveal(tile, in: app), "No site tile.")
        let identifier = tile.identifier

        tile.press(forDuration: 1.0)
        let pin = app.buttons["Pin"]
        let unpin = app.buttons["Unpin"]
        XCTAssertTrue(wait(timeout: 5) { pin.exists || unpin.exists }, "The tile's menu has no Pin or Unpin.")
        XCTAssertTrue(app.buttons["Remove…"].exists || app.buttons["Remove"].exists, "The tile's menu has no Remove.")
        let wasPinned = unpin.exists
        let before = tile.frame
        (wasPinned ? unpin : pin).tap()
        XCTAssertTrue(waitForGone(wasPinned ? unpin : pin, timeout: 5))

        // Pinned sites go first, the rest by visits: the tile moved (or fell
        // past the 11-tile cap when unpinned alongside accumulated visits).
        let moved = any(app, identifier)
        XCTAssertTrue(
            wait(timeout: 5) {
                if wasPinned {
                    return siteTiles(app).firstMatch.identifier != identifier
                        && (!moved.exists || moved.frame != before)
                }
                return moved.exists && moved.frame != before
            },
            "Tapping \(wasPinned ? "Unpin" : "Pin") did not move the tile."
        )
    }

    func testAddSiteSheetOpensFromHome() throws {
        let app = launch(["-dc-sample", "-dc-forums-home"])

        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 20))
        // (iPad: in front of the assistant pane.)
        openHome(in: app)
        let add = app.buttons["homeAddSite"]
        if !reveal(add, in: app) { attachTree(app) }
        add.tap()
        XCTAssertTrue(app.navigationBars["Add Site"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "addForumAddress").exists)
        // Nothing typed yet: Add is disabled.
        XCTAssertFalse(app.buttons["addForumConfirm"].isEnabled)
        app.navigationBars["Add Site"].buttons["Cancel"].tap()
        XCTAssertTrue(waitForGone(app.navigationBars["Add Site"], timeout: 5))
    }

    /// Address field, Sites, Recent, Continue reading: top to bottom (no Today module).
    func testHomeSectionsComeInTheFixedOrder() throws {
        let app = launch(["-dc-sample", "-dc-forums-home"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        openHome(in: app)

        let address = app.textFields["homeAddress"]
        let tile = siteTiles(app).firstMatch
        let continueRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continueReading-'")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10), "No address field.")
        XCTAssertFalse(any(app, "homeToday").exists, "Today module must not appear on Home.")
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "No site tiles.")
        XCTAssertLessThan(address.frame.minY, tile.frame.minY)
        XCTAssertTrue(app.buttons["homeHistory"].exists)
        XCTAssertTrue(app.buttons["homeSettings"].exists)

        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recent-'")).firstMatch
        XCTAssertTrue(reveal(recent, in: app), "No Recent items.")
        XCTAssertLessThan(tile.frame.minY, recent.frame.minY)
        XCTAssertLessThanOrEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recent-'")).count, 3)
        XCTAssertTrue(reveal(continueRow, in: app), "No Continue reading.")
        XCTAssertLessThan(recent.frame.minY, continueRow.frame.minY)
        XCTAssertLessThanOrEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continueReading-'")).count, 3)
    }

    /// A site tile opens the site (Home goes).
    func testSiteTileOpensTheSite() throws {
        let app = launch(["-dc-sample", "-dc-forums-home"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        let home = openHome(in: app)
        let tile = siteTiles(app).firstMatch
        XCTAssertTrue(reveal(tile, in: app))
        tile.tap()
        XCTAssertTrue(waitForGone(home, timeout: 10), "The tile did not open its site.")
    }

    /// No sites yet: the address field and three suggested sites; no Today,
    /// no share card, no Add tile.
    func testHomeWithNoSitesShowsTheAddressFieldAndSuggestedSites() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-no-forums"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        openHome(in: app)
        XCTAssertTrue(app.textFields["homeAddress"].waitForExistence(timeout: 10))
        let suggested = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'suggestedSite-'"))
        XCTAssertTrue(suggested.firstMatch.waitForExistence(timeout: 5), "No suggested sites.")
        XCTAssertLessThanOrEqual(suggested.count, 3)
        XCTAssertFalse(any(app, "homeShareHowTo").exists, "the share card lives in Settings › Help now")
        XCTAssertFalse(any(app, "homeToday").exists, "no Today module without forums")
        XCTAssertEqual(siteTiles(app).count, 0)
    }

    /// Home has its own address field, so the bar shows no address capsule
    /// while it shows; an address typed there opens the page and Home goes.
    func testHomeAddressFieldOpensAnAddressAndTheBarHidesItsOwn() throws {
        let server = FixtureWordPressServer()
        try server.start()
        defer { server.stop() }
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-no-forums", "-dc-page-state", "loading"])
        let home = openHome(in: app)
        XCTAssertFalse(app.buttons["browserTitle"].exists, "The bar still shows its address capsule on Home.")
        let field = app.textFields["homeAddress"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(server.baseURL + "\n")
        XCTAssertTrue(waitForGone(home, timeout: 15), "The typed address did not open.")
    }

    func testDockRowsWrapToTwoLinesAtAccessibilitySize() throws {
        let ax5 = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue

        // 1. DockHintRow ("Summarize this thread?") wraps onto two lines at AX5.
        var app = launch(
            [
                "-UIPreferredContentSizeCategoryName", ax5,
                "-dc-sample",
                "-dc-page-state", "topic",
                "-dc-drawer-first-run",
                "-dc-no-summary",
                "-dc-force-width", "375"
            ],
            orientation: .portrait
        )
        let hintText = app.buttons["dockHintText"]
        XCTAssertTrue(waitForHittable(hintText, timeout: 15), "Dock hint row did not appear.")
        _ = wait(timeout: 2) { hintText.frame.height > 80 }
        let hintHeight = hintText.frame.height
        app.terminate()

        // 2. Home header buttons maintain non-overlapping >= 44×44 pt hit targets at AX5.
        app = launch(
            [
                "-UIPreferredContentSizeCategoryName", ax5,
                "-dc-sample",
                "-dc-forums-home",
                "-dc-force-width", "375"
            ],
            orientation: .portrait
        )
        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 15))
        let historyBtn = app.buttons["homeHistory"]
        let settingsBtn = app.buttons["homeSettings"]
        XCTAssertTrue(historyBtn.waitForExistence(timeout: 5) && settingsBtn.exists)
        XCTAssertGreaterThanOrEqual(historyBtn.frame.width, 44)
        XCTAssertGreaterThanOrEqual(settingsBtn.frame.width, 44)
        XCTAssertLessThanOrEqual(historyBtn.frame.maxX, settingsBtn.frame.minX + 1)

        XCTAssertGreaterThan(
            hintHeight,
            80,
            "At AX5 Dynamic Type, DockHintRow stayed single-line (height \(hintHeight) pt) instead of wrapping to two lines."
        )
    }
}
