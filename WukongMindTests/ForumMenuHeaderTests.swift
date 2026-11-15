import XCTest
@testable import WukongMind

/// The browser menu's site row: a forum only while the page is that forum.
final class ForumMenuHeaderTests: XCTestCase {
    private let forum = Forum(siteURL: "https://www.uscardforum.com", kind: .discourse, name: "美卡论坛", iconURL: nil)

    func testForumPageShowsTheForum() {
        XCTAssertEqual(ForumMenuHeader.forum(barForum: forum, pageIsForum: true, showsHome: false)?.siteURL, forum.siteURL)
    }

    func testOrdinaryPageAfterAForumDoesNotShowTheLastForum() {
        // barForum falls back to the last forum; the page (bbc.com) is not a forum.
        XCTAssertNil(ForumMenuHeader.forum(barForum: forum, pageIsForum: false, showsHome: false))
        XCTAssertEqual(ForumMenuHeader.plainHost(URL(string: "https://www.bbc.com/news")), "bbc.com")
    }

    func testHomeShowsNoForumAndNoHost() {
        XCTAssertNil(ForumMenuHeader.forum(barForum: forum, pageIsForum: true, showsHome: true))
        XCTAssertNil(ForumMenuHeader.plainHost(nil))
    }
}
