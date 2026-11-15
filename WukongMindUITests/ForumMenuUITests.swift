import XCTest

/// The browser menu on an ordinary page (a loopback fixture page) after
/// a forum was the current one (`-dc-seed-forums`): Share is one row with no
/// Copy Link, and the site row is the page's host, not the last forum.
final class ForumMenuUITests: DCUITestCase {
    func testShareIsOneRowAndSiteRowShowsTheHostOnAnOrdinaryPage() throws {
        let server = FixtureSpaForumServer()
        try server.start()
        defer { server.stop() }
        let app = launch(["-dc-seed-forums", "-dc-no-forum-icons", "-dc-open", server.plainURL])
        openForumMenu(in: app)

        let share = app.buttons["forumMenuShare"]
        XCTAssertTrue(share.waitForExistence(timeout: 15), "The menu has no Share row.")
        XCTAssertFalse(app.buttons["Copy Link"].exists, "Copy Link must be gone.")

        let host = URL(string: server.plainURL)?.host() ?? ""
        let site = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", host)).firstMatch
        let menu = app.collectionViews.firstMatch.debugDescription
        XCTAssertTrue(site.waitForExistence(timeout: 5), "No site row for \(host). Menu: \(menu.suffix(3000))")
        XCTAssertFalse(site.label.contains("Not signed in"), "Row: \(site.debugDescription) Menu: \(menu.suffix(2500))")
        XCTAssertFalse(app.buttons["forumMenuAccount"].exists, "A forum row appeared on an ordinary page.")
    }
}
