import XCTest

/// WUKO-85 acceptance of 1.3.1 C (live bbc.com menu after a forum) and D (x.com in the app,
/// Google result tap, app-scheme banner, and Open links in apps + per-site override UI).
final class XComLiveUITests: DCUITestCase {
    private func launchBrowser(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-dc-skip-onboarding", "-AppleInterfaceStyle", "Light"] + extra
        app.launch()
        showBrowser(in: app)
        return app
    }

    private func type(_ address: String, in app: XCUIApplication) {
        let title = app.buttons["browserTitle"].firstMatch
        XCTAssertTrue(waitOrDump(title, timeout: 20, in: app), "No browser title.")
        title.tap()
        let field = app.textFields["addressField"]
        XCTAssertTrue(waitOrDump(field, timeout: 10, in: app), "No address field.")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        field.typeText(address + "\n")
    }

    func testTypedXComAndSiteOverrideAndSettings() throws {
        try requireNetwork()
        let app = launchBrowser()
        type("x.com", in: app)
        let title = app.buttons["browserTitle"].firstMatch
        _ = wait(timeout: 25) { title.exists && (title.label.lowercased().contains("x.com") || title.label.contains("X")) }
        sleep(8)
        capture("checkD-xcom-typed")
        XCTAssertEqual(app.state, .runningForeground, "The app was left (the X app took over).")
        XCTAssertTrue(app.webViews.firstMatch.exists, "No web view after typing x.com.")
        attachText("title: \(title.label)", named: "xcom-typed-title")

        // Per-site override from the address-bar menu on x.com, then verify in Settings › Sites.
        openForumMenu(in: app)
        let siteRow = app.buttons.matching(NSPredicate(format: "identifier == 'forumMenuSite' OR label CONTAINS[c] 'x.com'")).firstMatch
        XCTAssertTrue(waitOrDump(siteRow, timeout: 10, in: app), "No x.com site row in browser menu.")
        siteRow.tap()
        let siteToggle = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'menuToggleAppLinksOnSite' OR label CONTAINS 'Open links in apps on this site'")
        ).firstMatch
        XCTAssertTrue(waitOrDump(siteToggle, timeout: 10, in: app), "No per-site app-links switch.")
        siteToggle.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        if siteToggle.exists { dismissMenu(in: app); RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }

        openSettings(in: app)
        let sitesRow = app.buttons["settingsRow-sites"]
        XCTAssertTrue(reveal(sitesRow, in: app, swipes: 3))
        sitesRow.tap()
        let globalToggle = app.switches["openLinksInAppsToggle"]
        XCTAssertTrue(reveal(globalToggle, in: app, swipes: 6), "No Open links in apps switch in Settings › Sites.")
        XCTAssertEqual(globalToggle.value as? String, "0", "Open links in apps defaults to off.")
        let overrideRow = any(app, "appLinkSite-x.com")
        XCTAssertTrue(reveal(overrideRow, in: app, swipes: 4), "Per-site override for x.com missing in Settings › Sites.")
        capture("checkD-link-settings")
    }

    func testAppSchemeLinkAsksFirst() throws {
        let server = FixtureSpaForumServer()
        try server.start()
        defer { server.stop() }
        let app = launchBrowser(["-dc-open", server.plainURL])
        let link = app.webViews.links["Open Twitter app"].firstMatch
        XCTAssertTrue(waitOrDump(link, timeout: 15, in: app), "Fixture app-scheme link did not load.")
        link.tap()
        let banner = any(app, "appOpenBanner")
        XCTAssertTrue(waitOrDump(banner, timeout: 10, in: app), "App-scheme link did not show the prompt banner.")
        XCTAssertTrue(app.buttons["appOpenBannerOpen"].exists, "Prompt banner has no Open button.")
        XCTAssertEqual(app.state, .runningForeground, "App-scheme link opened externally without asking.")
        capture("checkD-app-scheme-banner")
    }

    func testTappedXComLinkOnGoogleResultsStaysInTheApp() throws {
        try requireNetwork()
        let app = launchBrowser()
        type("https://www.google.com/search?q=site%3Ax.com+nasa&hl=en", in: app)
        let link = app.webViews.links.matching(
            NSPredicate(format: "label CONTAINS[c] 'x.com' OR label CONTAINS[c] 'on X' OR label CONTAINS[c] 'NASA (@NASA)'")
        ).firstMatch
        guard link.waitForExistence(timeout: 35) else {
            capture("checkD-google-no-result")
            throw XCTSkip("Google showed no x.com result (consent or bot page).")
        }
        capture("checkD-google-results")
        link.tap()
        let title = app.buttons["browserTitle"].firstMatch
        _ = wait(timeout: 20) { title.exists && !title.label.lowercased().contains("google") }
        sleep(8)
        capture("checkD-xcom-tapped")
        XCTAssertEqual(app.state, .runningForeground, "The tap left the app (the X app took over).")
        XCTAssertTrue(app.webViews.firstMatch.exists)
        attachText("title after tap: \(title.label)", named: "xcom-tapped-title")
    }

    func testBBCMenuAfterForumShowsOneShareRowAndHostWithoutSignIn() throws {
        try requireNetwork()
        let app = launchBrowser(["-dc-seed-forums", "-dc-no-forum-icons", "-dc-open", "https://meta.discourse.org"])
        let title = app.buttons["browserTitle"].firstMatch
        _ = wait(timeout: 35) { title.exists && title.label.lowercased().contains("discourse") }
        type("https://www.bbc.com", in: app)
        XCTAssertTrue(wait(timeout: 45) { title.exists && title.label.lowercased().contains("bbc") }, "bbc.com did not load.")
        sleep(2)
        openForumMenu(in: app)
        let share = app.buttons.matching(NSPredicate(format: "identifier == 'forumMenuShare' OR label == 'Share'")).firstMatch
        XCTAssertTrue(waitOrDump(share, timeout: 10, in: app), "Menu on bbc.com has no Share row.")
        XCTAssertFalse(app.buttons["Copy Link"].exists, "Copy Link must be gone.")
        let site = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'bbc.com'")).firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 5), "Menu on bbc.com has no bbc.com site row.")
        XCTAssertFalse(site.label.localizedCaseInsensitiveContains("signed in"), "bbc.com row showed sign-in state: \(site.label)")
        XCTAssertFalse(app.buttons["forumMenuAccount"].exists, "Forum account row appeared on bbc.com.")
        capture("checkC-bbc-menu")
    }
}
