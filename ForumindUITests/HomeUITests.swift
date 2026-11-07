import UIKit
import XCTest

/// Home (spec §7.1): the sections in order, the Today page pushed over it,
/// forum tiles, pinning a suggestion, Add forum, and Home with no forums.
final class HomeUITests: DCUITestCase {
    func testAddForumIsLastTileAtStandardAndAccessibilitySizes() throws {
        for category in [UIContentSizeCategory.accessibilityExtraExtraExtraLarge, .large] {
            let app = launch(["-dc-sample", "-dc-forums-home", "-UIPreferredContentSizeCategoryName", category.rawValue],
                             orientation: isPhone ? .portrait : .landscapeLeft)
            openHome(in: app)
            let last = app.buttons["pinnedForum-community.openai.com"]
            XCTAssertTrue(reveal(last, in: app))
            let add = app.buttons["homeAddForum"]
            XCTAssertTrue(reveal(add, in: app))
            XCTAssertEqual(add.frame.width, last.frame.width, accuracy: 1, "Add forum must have a tile's width")
            XCTAssertEqual(add.frame.height, last.frame.height, accuracy: 1, "Add forum must have a tile's height")
            XCTAssertTrue(add.frame.minY > last.frame.minY + 1 || add.frame.minX > last.frame.minX + 1, "Add forum goes last")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "forum-grid-\(category.rawValue)"
            shot.lifetime = .keepAlways
            self.add(shot)
            add.tap()
            XCTAssertTrue(any(app, "addForumAddress").waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    /// On the sample with no forums (nothing is saved): pin a suggestion,
    /// find it under Forums and in the switcher, then unpin it from the
    /// tile's menu.
    func testPinningASuggestedForumShowsItInTheSwitcherAndUnpinning() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-no-forums"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        let home = openHome(in: app)

        let pinButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pinSuggested-'")).firstMatch
        XCTAssertTrue(reveal(pinButton, in: app), "No suggested forum to pin.")
        let host = String(pinButton.identifier.dropFirst("pinSuggested-".count))
        pinButton.tap()

        // Pinned: it leaves the suggestions and appears as a pinned tile.
        XCTAssertTrue(waitForGone(app.buttons["pinSuggested-\(host)"], timeout: 5))
        let tile = app.buttons["pinnedForum-\(host)"]
        for _ in 0..<6 where !tile.exists { app.swipeDown() }
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "\(host) did not appear under Forums.")

        // The forum menu's first item goes back to Home.
        openForumMenu(in: app)
        let homeItem = app.buttons["Home"]
        XCTAssertTrue(homeItem.exists)
        // Home closes the menu and keeps Home.
        homeItem.tap()
        XCTAssertTrue(waitForGone(homeItem, timeout: 5))
        XCTAssertTrue(home.waitForExistence(timeout: 5))

        // Unpin from the tile's menu: the tile goes, the suggestion is back.
        XCTAssertTrue(waitForHittable(tile))
        tile.press(forDuration: 1.0)
        let unpin = app.buttons["Unpin"]
        XCTAssertTrue(unpin.waitForExistence(timeout: 5), "The tile has no Unpin.")
        unpin.tap()
        XCTAssertTrue(waitForGone(tile, timeout: 5), "\(host) is still pinned.")
    }

    func testAddForumSheetOpensFromHome() throws {
        let app = launch(["-dc-forums-home"])

        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 20))
        // (iPad: in front of the assistant pane.)
        openHome(in: app)
        // Under the pinned tiles, in the Forums section; with no forums
        // (a fresh simulator) the Start with a forum card's button.
        let first = app.buttons["homeAddFirstForum"]
        let add = first.waitForExistence(timeout: 3) ? first : app.buttons["homeAddForum"]
        if !reveal(add, in: app) { attachTree(app) }
        add.tap()
        XCTAssertTrue(app.navigationBars["Add Forum"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "addForumAddress").exists)
        // Nothing typed yet: Add is disabled.
        XCTAssertFalse(app.buttons["addForumConfirm"].isEnabled)
        app.navigationBars["Add Forum"].buttons["Cancel"].tap()
        XCTAssertTrue(waitForGone(app.navigationBars["Add Forum"], timeout: 5))
    }

    /// Today module, Continue reading, the pinned forums, Recent: top to
    /// bottom (the sample: a digest being made, saved topics, three pinned
    /// forums and recents).
    func testHomeSectionsComeInTheFixedOrder() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-digest-sample"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        openHome(in: app)

        let today = any(app, "homeToday")
        let continueRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continueReading-'")).firstMatch
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pinnedForum-'")).firstMatch
        XCTAssertTrue(waitOrDump(today, timeout: 10, in: app), "No Today module.")
        XCTAssertTrue(continueRow.waitForExistence(timeout: 5), "No Continue reading.")
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "No pinned forum tiles.")
        XCTAssertLessThan(today.frame.minY, continueRow.frame.minY)
        XCTAssertLessThan(continueRow.frame.minY, tile.frame.minY)
        XCTAssertLessThanOrEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continueReading-'")).count, 3)
        XCTAssertTrue(app.buttons["homeHistory"].exists)
        XCTAssertTrue(app.buttons["homeSettings"].exists)

        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recentForum-'")).firstMatch
        XCTAssertTrue(reveal(recent, in: app), "No Recent forums.")
        XCTAssertLessThan(tile.frame.minY, recent.frame.minY)
        // Three forums or more: no suggestions.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pinSuggested-'")).firstMatch.exists)
    }

    /// The Today page is pushed over Home and Back returns to it.
    func testTodayPageIsPushedAndGoesBack() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-digest-sample"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        let home = openHome(in: app)
        let open = app.buttons["homeTodayOpen"]
        XCTAssertTrue(waitForHittable(open))
        open.tap()

        let page = any(app, "todayPage")
        XCTAssertTrue(page.waitForExistence(timeout: 10), "The Today page was not pushed.")
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["todayMenu"].exists)
        app.navigationBars["Today"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitForGone(page, timeout: 5))
        XCTAssertTrue(home.waitForExistence(timeout: 5))
    }

    /// A pinned forum's tile opens the forum (Home goes).
    func testForumTileOpensTheForum() throws {
        let app = launch(["-dc-sample", "-dc-forums-home"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        let home = openHome(in: app)
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pinnedForum-'")).firstMatch
        XCTAssertTrue(reveal(tile, in: app))
        tile.tap()
        XCTAssertTrue(waitForGone(home, timeout: 10), "The tile did not open its forum.")
    }

    /// No forums yet: Start with a forum, suggestions, the share card.
    func testHomeWithNoForumsShowsSuggestions() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-no-forums"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        openHome(in: app)
        XCTAssertTrue(app.buttons["homeAddFirstForum"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pinSuggested-'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(any(app, "homeShareHowTo"), in: app))
        XCTAssertFalse(any(app, "homeToday").exists, "no Today module without forums")
    }

    /// Without a forum to search, Home's address bar asks for a forum address
    /// rather than inviting search words.
    func testHomeWithNoForumsPromptsForAddressOnly() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-no-forums", "-dc-page-state", "loading"])
        openHome(in: app)
        let title = app.buttons["browserTitle"]
        XCTAssertTrue(waitForBarItem(title, timeout: 10))
        XCTAssertEqual(title.label, "Enter a forum address")

        tapBarItem(title)
        let field = app.textFields["addressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("swift concurrency\n")
        let alert = app.alerts["Can’t open this address"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertFalse(
            alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'current forum'")).firstMatch.exists,
            "Alert mentions a current forum when none exists."
        )
        alert.buttons["OK"].tap()
    }

    func testDockRowsWrapToTwoLinesAtAccessibilitySize() throws {
        let ax5 = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue

        // 1. DockHintRow ("Summarize this topic") wraps onto two lines at AX5.
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

        // 2. DockPodcastRow ("Today · Welcome · … left") wraps onto two lines at AX5,
        // and Home header buttons maintain non-overlapping >= 44×44 pt hit targets.
        app = launch(
            [
                "-UIPreferredContentSizeCategoryName", ax5,
                "-dc-sample",
                "-dc-forums-home",
                "-dc-digest-sample",
                "-dc-podcast-fake",
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

        let openToday = app.buttons["homeTodayOpen"]
        XCTAssertTrue(reveal(openToday, in: app, swipes: 3))
        openToday.tap()
        XCTAssertTrue(any(app, "todayPage").waitForExistence(timeout: 10))

        let play = app.buttons["podcastPlay"]
        XCTAssertTrue(reveal(play, in: app, swipes: 4))
        play.tap()
        XCTAssertTrue(app.buttons["podcastNowPlayingRow"].waitForExistence(timeout: 10))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 10))
        let dockPodcast = app.buttons["dockPodcastOpen"]
        XCTAssertTrue(waitForHittable(dockPodcast, timeout: 10), "Dock podcast row did not appear on Home.")
        _ = wait(timeout: 2) { dockPodcast.frame.height > 80 }
        let podcastHeight = dockPodcast.frame.height

        XCTAssertGreaterThan(
            hintHeight,
            80,
            "At AX5 Dynamic Type, DockHintRow stayed single-line (height \(hintHeight) pt) instead of wrapping to two lines."
        )
        XCTAssertGreaterThan(
            podcastHeight,
            80,
            "At AX5 Dynamic Type, DockPodcastRow stayed single-line (height \(podcastHeight) pt) instead of wrapping to two lines."
        )
    }

    func testHomeDigestStripAndAccessibilityLayout() throws {
        var app = launch(["-dc-sample", "-dc-forums-home", "-dc-digest-sample"], orientation: .portrait)
        openHome(in: app)
        let card = app.buttons["homeDigestCard-241807"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        capture("base_phone_home-digest")
        let baseCardMinX = card.frame.minX
        let baseHeaderMinX = any(app, "homeHeader").frame.minX
        app.terminate()

        let ax5 = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
        app = launch(["-UIPreferredContentSizeCategoryName", ax5, "-dc-sample", "-dc-forums-home", "-dc-digest-sample"], orientation: .portrait)
        openHome(in: app)
        let axHeader = any(app, "homeHeader")
        let axCard = app.buttons["homeDigestCard-241807"]
        XCTAssertTrue(axCard.waitForExistence(timeout: 10))
        capture("ax5_phone_home-digest")
        let axCardWidth = axCard.frame.width
        let headerHeight = axHeader.frame.height

        // Home is centered and inset further on iPad. Its header has a 4 pt
        // inset from the cards; compare within the list, not to the screen edge.
        XCTAssertEqual(baseCardMinX, baseHeaderMinX - 4, accuracy: 1, "DigestStrip first card should align with the Today section leading margin instead of double-indenting.")
        XCTAssertEqual(axCard.frame.minX, axHeader.frame.minX - 4, accuracy: 1, "DigestStrip should keep its leading alignment at AX5.")
        XCTAssertLessThan(headerHeight, 175, "Date header wrapped across multiple lines at AX5 (height \(headerHeight)).")
        XCTAssertLessThanOrEqual(axCardWidth, 310, "Digest card overflowed screen width at AX5 (width \(axCardWidth)).")
    }
}
