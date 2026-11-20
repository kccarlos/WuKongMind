import XCTest
@testable import WukongMind

final class AddressInputTests: XCTestCase {
    private let forumSite = "https://meta.discourse.org"

    private func makeContext(
        currentSiteURL: String? = nil,
        supportsForumSearch: Bool = false,
        engine: SearchEngine = .duckDuckGo
    ) -> AddressInput.Context {
        AddressInput.Context(
            currentSiteURL: currentSiteURL,
            forumSearchURL: supportsForumSearch
                ? { query in
                    guard let site = currentSiteURL else { return nil }
                    return DiscourseRoutes.searchPageURL(siteURL: site, query: query)
                }
                : nil,
            webSearchURL: { query in
                engine.searchURL(for: query)
            }
        )
    }

    func testActionsTable() {
        enum ExpectedKind: Equatable {
            case open(String)
            case forumSearch(String)
            case webSearch(String)
        }

        func kinds(of actions: [AddressInput.Action]) -> [ExpectedKind] {
            actions.map { action in
                switch action {
                case .open(let url): return .open(url.absoluteString)
                case .forumSearch(let url): return .forumSearch(url.absoluteString)
                case .webSearch(let url): return .webSearch(url.absoluteString)
                }
            }
        }

        let cases: [(
            name: String,
            input: String,
            site: String?,
            forumSearch: Bool,
            expected: [ExpectedKind]
        )] = [
            (
                "empty string",
                "",
                forumSite,
                true,
                []
            ),
            (
                "whitespace only",
                "   \n\t ",
                forumSite,
                true,
                []
            ),
            (
                "full https URL on non-forum",
                "https://example.com/path?q=1",
                nil,
                false,
                [
                    .open("https://example.com/path?q=1"),
                    .webSearch("https://duckduckgo.com/?q=https://example.com/path?q%3D1"),
                ]
            ),
            (
                "bare host without scheme",
                "meta.discourse.org",
                nil,
                false,
                [
                    .open("https://meta.discourse.org"),
                    .webSearch("https://duckduckgo.com/?q=meta.discourse.org"),
                ]
            ),
            (
                "host with port",
                "localhost:3000/posts",
                nil,
                false,
                [
                    .open("http://localhost:3000/posts"),
                    .webSearch("https://duckduckgo.com/?q=localhost:3000/posts"),
                ]
            ),
            (
                "IPv4 host with port",
                "127.0.0.1:8080/x",
                nil,
                false,
                [
                    .open("http://127.0.0.1:8080/x"),
                    .webSearch("https://duckduckgo.com/?q=127.0.0.1:8080/x"),
                ]
            ),
            (
                "domain host with port",
                "example.com:8443/api",
                nil,
                false,
                [
                    .open("https://example.com:8443/api"),
                    .webSearch("https://duckduckgo.com/?q=example.com:8443/api"),
                ]
            ),
            (
                "path on forum page",
                "/top",
                forumSite,
                true,
                [
                    .open("https://meta.discourse.org/top"),
                    .forumSearch("https://meta.discourse.org/search?q=/top"),
                    .webSearch("https://duckduckgo.com/?q=/top"),
                ]
            ),
            (
                "path without forum page",
                "/top",
                nil,
                false,
                [
                    .webSearch("https://duckduckgo.com/?q=/top"),
                ]
            ),
            (
                "plain search on forum page",
                "swift concurrency",
                forumSite,
                true,
                [
                    .forumSearch("https://meta.discourse.org/search?q=swift%20concurrency"),
                    .webSearch("https://duckduckgo.com/?q=swift%20concurrency"),
                ]
            ),
            (
                "plain search on non-forum page",
                "swift concurrency",
                nil,
                false,
                [
                    .webSearch("https://duckduckgo.com/?q=swift%20concurrency"),
                ]
            ),
            (
                "plain search on Home with underlying forum (forumSearch nil)",
                "swift concurrency",
                forumSite,
                false,
                [
                    .webSearch("https://duckduckgo.com/?q=swift%20concurrency"),
                ]
            ),
            (
                "disallowed scheme falls back to search",
                "javascript:alert(1)",
                nil,
                false,
                [
                    .webSearch("https://duckduckgo.com/?q=javascript:alert(1)"),
                ]
            ),
        ]

        for testCase in cases {
            let context = makeContext(
                currentSiteURL: testCase.site,
                supportsForumSearch: testCase.forumSearch
            )
            let actual = kinds(of: AddressInput.actions(for: testCase.input, context: context))
            XCTAssertEqual(actual, testCase.expected, "Case failed: \(testCase.name)")
        }
    }

    func testUnformableSearchReturnsEmpty() {
        let context = AddressInput.Context(
            currentSiteURL: nil,
            forumSearchURL: nil,
            webSearchURL: { _ in nil }
        )
        XCTAssertEqual(AddressInput.actions(for: "plain words", context: context), [])
    }
}
