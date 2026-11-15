import XCTest
@testable import WukongMind

final class LinkPolicyTests: XCTestCase {
    private func nav(
        _ url: String, main: Bool = true, tapped: Bool = true, method: String? = "GET"
    ) -> LinkPolicy.Navigation {
        .init(url: URL(string: url)!, targetIsMainFrame: main, isLinkActivated: tapped, httpMethod: method)
    }

    func testTappedHTTPSLinkLoadsInPlaceByDefault() {
        XCTAssertEqual(LinkPolicy.decide(nav("https://x.com/home"), settings: .init()), .reloadInPlace)
    }

    func testTypedOrScriptNavigationIsAllowed() {
        XCTAssertEqual(LinkPolicy.decide(nav("https://x.com", tapped: false), settings: .init()), .allow)
    }

    func testFormPostSubFrameAndNonMainFrameAreLeftAlone() {
        XCTAssertEqual(LinkPolicy.decide(nav("https://x.com", method: "POST"), settings: .init()), .allow)
        XCTAssertEqual(LinkPolicy.decide(nav("https://x.com", main: false), settings: .init()), .allow)
    }

    func testGlobalSettingAllowsAppLinks() {
        let on = LinkSettings(openInApps: true)
        XCTAssertEqual(LinkPolicy.decide(nav("https://x.com/home"), settings: on), .allow)
    }

    func testSiteOverrideBeatsGlobalAndMatchesSubdomains() {
        let off = LinkSettings(openInApps: false, siteOverrides: ["x.com": true])
        XCTAssertEqual(LinkPolicy.decide(nav("https://www.x.com/a"), settings: off), .allow)
        XCTAssertEqual(LinkPolicy.decide(nav("https://mobile.x.com/a"), settings: off), .allow)
        XCTAssertEqual(LinkPolicy.decide(nav("https://example.com/a"), settings: off), .reloadInPlace)
        let on = LinkSettings(openInApps: true, siteOverrides: ["x.com": false])
        XCTAssertEqual(LinkPolicy.decide(nav("https://x.com/a"), settings: on), .reloadInPlace)
        XCTAssertEqual(LinkPolicy.decide(nav("https://other.org/a"), settings: on), .allow)
    }

    func testAppSchemeAlwaysPromptsUnlessTappedWithSettingOn() {
        let url = URL(string: "twitter://timeline")!
        XCTAssertEqual(LinkPolicy.decide(nav("twitter://timeline", tapped: false), settings: .init()), .promptOpenApp(url))
        XCTAssertEqual(LinkPolicy.decide(nav("twitter://timeline"), settings: .init()), .promptOpenApp(url))
        XCTAssertEqual(LinkPolicy.decide(nav("twitter://timeline", tapped: false), settings: .init(openInApps: true)), .promptOpenApp(url))
        XCTAssertEqual(LinkPolicy.decide(nav("twitter://timeline"), settings: .init(openInApps: true)), .openExternally(url))
    }

    func testSystemSchemesAndInPageSchemes() {
        let mail = URL(string: "mailto:a@b.c")!
        XCTAssertEqual(LinkPolicy.decide(nav("mailto:a@b.c"), settings: .init()), .openExternally(mail))
        XCTAssertEqual(LinkPolicy.decide(nav("mailto:a@b.c", tapped: false), settings: .init()), .cancel)
        XCTAssertEqual(LinkPolicy.decide(nav("about:blank", tapped: false), settings: .init()), .allow)
        XCTAssertEqual(LinkPolicy.decide(nav("javascript:void(0)"), settings: .init()), .cancel)
    }

    func testSafariHandoffSchemeLoadsTheWebURL() {
        XCTAssertEqual(
            LinkPolicy.decide(nav("x-safari-https://x.com/a?b=1", tapped: false), settings: .init()),
            .loadWebURL(URL(string: "https://x.com/a?b=1")!)
        )
    }

    func testUserAgentLooksLikeSafari() {
        let os = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        let phone = LinkPolicy.userAgent(osVersion: os, isPad: false)
        XCTAssertTrue(phone.contains("iPhone; CPU iPhone OS 26_1"))
        XCTAssertTrue(phone.contains("Version/26.1 Mobile/15E148 Safari/"))
        let pad = LinkPolicy.userAgent(osVersion: os, isPad: true)
        XCTAssertTrue(pad.contains("Macintosh") && pad.contains("Version/26.1 Safari/"))
    }

    func testOverrideMatchingGlobalIsCleared() {
        var settings = AppSettings()
        settings.appLinkSiteOverrides["x.com"] = true
        XCTAssertEqual(settings.appLinkSiteOverrides.count, 1)
        let decoded = try? JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded?.appLinkSiteOverrides, ["x.com": true])
        XCTAssertEqual(decoded?.openLinksInApps, false)
    }
}
