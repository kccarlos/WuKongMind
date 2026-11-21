import XCTest
@testable import WukongMind

final class AddressInputTests: XCTestCase {
    private let forumSite = "https://meta.discourse.org"

    private func makeContext(
        currentSiteURL: String? = nil,
        canAskAgent: Bool = false,
        supportsForumSearch: Bool = false,
        engine: SearchEngine = .duckDuckGo
    ) -> AddressInput.Context {
        AddressInput.Context(
            currentSiteURL: currentSiteURL,
            canAskAgent: canAskAgent,
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
            case askAgent(String)
            case forumSearch(String)
            case webSearch(String)
        }

        func kinds(of actions: [AddressInput.Action]) -> [ExpectedKind] {
            actions.map { action in
                switch action {
                case .open(let url): return .open(url.absoluteString)
                case .askAgent(let prompt): return .askAgent(prompt)
                case .forumSearch(let url): return .forumSearch(url.absoluteString)
                case .webSearch(let url): return .webSearch(url.absoluteString)
                }
            }
        }

        let cases: [(
            name: String,
            input: String,
            site: String?,
            canAskAgent: Bool,
            forumSearch: Bool,
            expected: [ExpectedKind]
        )] = [
            (
                "empty string",
                "",
                forumSite,
                true,
                true,
                []
            ),
            (
                "whitespace only",
                "   \n\t ",
                forumSite,
                true,
                true,
                []
            ),
            (
                "full https URL with query on page stays address",
                "https://example.com/path?q=1",
                nil,
                true,
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
                true,
                false,
                [
                    .open("https://meta.discourse.org"),
                    .webSearch("https://duckduckgo.com/?q=meta.discourse.org"),
                ]
            ),
            (
                "near miss what.cd stays address",
                "what.cd",
                nil,
                true,
                false,
                [
                    .open("https://what.cd"),
                    .webSearch("https://duckduckgo.com/?q=what.cd"),
                ]
            ),
            (
                "host with port",
                "localhost:3000/posts",
                nil,
                true,
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
                true,
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
                true,
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
                true,
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
                false,
                [
                    .webSearch("https://duckduckgo.com/?q=swift%20concurrency"),
                ]
            ),
            (
                "disallowed scheme falls back to search",
                "javascript:alert(1)",
                nil,
                true,
                false,
                [
                    .webSearch("https://duckduckgo.com/?q=javascript:alert(1)"),
                ]
            ),
            (
                "English question on page asks Agent first then web search",
                "which fanless box is quietest?",
                nil,
                true,
                false,
                [
                    .askAgent("which fanless box is quietest?"),
                    .webSearch("https://duckduckgo.com/?q=which%20fanless%20box%20is%20quietest?"),
                ]
            ),
            (
                "English question on empty tab stays web search",
                "which fanless box is quietest?",
                nil,
                false,
                false,
                [
                    .webSearch("https://duckduckgo.com/?q=which%20fanless%20box%20is%20quietest?"),
                ]
            ),
            (
                "near miss how to geek stays search even on page",
                "how to geek",
                nil,
                true,
                false,
                [
                    .webSearch("https://duckduckgo.com/?q=how%20to%20geek"),
                ]
            ),
            (
                "Chinese question on page asks Agent first",
                "这篇文章讲了什么",
                nil,
                true,
                false,
                [
                    .askAgent("这篇文章讲了什么"),
                    .webSearch("https://duckduckgo.com/?q=%E8%BF%99%E7%AF%87%E6%96%87%E7%AB%A0%E8%AE%B2%E4%BA%86%E4%BB%80%E4%B9%88"),
                ]
            ),
        ]

        for testCase in cases {
            let context = makeContext(
                currentSiteURL: testCase.site,
                canAskAgent: testCase.canAskAgent,
                supportsForumSearch: testCase.forumSearch
            )
            let actual = kinds(of: AddressInput.actions(for: testCase.input, context: context))
            XCTAssertEqual(actual, testCase.expected, "Case failed: \(testCase.name)")
        }
    }

    func testQuestionClassifierTable() {
        let cases: [(input: String, expected: Bool)] = [
            // English questions & instructions
            ("what is this page about?", true),
            ("what is the main takeaway", true),
            ("why did the build fail", true),
            ("how does this work", true),
            ("how many replies are here", true),
            ("how to fix this?", true),
            ("which model is faster", true),
            ("who wrote this post", true),
            ("is there a dark mode", true),
            ("can you hide the sidebar", true),
            ("does it support iPad", true),
            ("summarize this thread", true),
            ("explain the benchmark", true),
            ("translate to Chinese", true),
            ("make the text larger", true),
            ("hide the comments", true),
            ("find the download link", true),
            ("anything with a question mark?", true),

            // Simplified & Traditional Chinese questions & instructions
            ("什么意思", true),
            ("怎麼導出", true),
            ("为什么这么慢", true),
            ("如何设置", true),
            ("是否支持同步", true),
            ("帮我总结一下", true),
            ("幫我隱藏側邊欄", true),
            ("请翻译成英文", true),
            ("总结这页", true),
            ("翻译成中文", true),
            ("这个好用吗", true),
            ("還有別的嗎", true),
            ("这个呢", true),
            ("这篇文章讲了什么", true),
            ("这是什么？", true),

            // Mixed English & Chinese
            ("summarize 这篇文章", true),
            ("explain 这段 Swift 代码", true),
            ("帮我 hide the sidebar", true),
            ("总结 this page", true),
            ("翻译成 English", true),
            ("Swift concurrency 怎么用？", true),

            // Near misses that MUST stay searches or addresses
            ("what.cd", false),
            ("how to geek", false),
            ("how to tie a tie", false),
            ("will smith", false),
            ("list price", false),
            ("show hn", false),
            ("can opener", false),
            ("change management", false),
            ("什么值得买", false),
            ("翻译", false),
            ("总结", false),
            ("翻译软件", false),
            ("https://example.com/search?q=what", false),
            ("http://localhost:3000/?foo=bar", false),
            ("swift concurrency", false),
            ("discourse meta", false),
            ("make", false),
            ("find", false),
            ("who", false),
            ("what", false),
            ("how", false),
            ("?", false),
            ("？", false),
            ("吗", false),
            ("苹果官网", false),
            ("哪吒电影", false),
            ("北京天气", false),
        ]

        for testCase in cases {
            XCTAssertEqual(
                AddressInput.looksLikeQuestion(testCase.input),
                testCase.expected,
                "looksLikeQuestion(\(testCase.input.debugDescription)) expected \(testCase.expected)"
            )
        }
    }

    func testUnformableSearchReturnsEmpty() {
        let context = AddressInput.Context(
            currentSiteURL: nil,
            canAskAgent: false,
            forumSearchURL: nil,
            webSearchURL: { _ in nil }
        )
        XCTAssertEqual(AddressInput.actions(for: "plain words", context: context), [])
    }

    func testSuggestionsBuilderCapsAtSixRowsWithActionsFirst() {
        let tiles = (1...10).map { i in
            HomeSite(
                siteURL: "https://swift\(i).example.com",
                name: "Swift Site \(i)",
                iconURL: nil,
                forum: nil,
                isPinned: false,
                visitCount: i,
                lastVisitedAt: nil
            )
        }
        let context = makeContext(currentSiteURL: nil, canAskAgent: true, supportsForumSearch: false)
        let rows = AddressSuggestionsBuilder.rows(for: "swift", context: context, tiles: tiles)

        XCTAssertEqual(rows.count, AddressSuggestionsBuilder.limit)
        if case .action(.webSearch) = rows.first {
            // Row 1 is the default Return action.
        } else {
            XCTFail("Expected row 1 to be webSearch, got \(String(describing: rows.first))")
        }
        let siteCount = rows.dropFirst().filter {
            if case .site = $0 { return true }
            return false
        }.count
        XCTAssertEqual(siteCount, 5)
    }

    @MainActor
    func testAddressEditStateShowsSuggestionsOnlyWhenEditedAndNonEmpty() {
        let state = AddressEditState()
        state.begin(initialText: "https://example.com/post")
        XCTAssertFalse(state.showsSuggestions, "Unchanged page address keeps Home visible")

        state.draft = ""
        XCTAssertFalse(state.showsSuggestions, "Empty field keeps Home visible")

        state.draft = "   "
        XCTAssertFalse(state.showsSuggestions, "Whitespace-only field keeps Home visible")

        state.draft = "what is this?"
        XCTAssertTrue(state.showsSuggestions, "Edited non-empty text shows suggestions")

        state.end()
        XCTAssertFalse(state.showsSuggestions)
        XCTAssertEqual(state.draft, "")
    }

    func testAnnouncementOnlyFiresWhenDefaultKindChanges() {
        XCTAssertNotNil(AddressSuggestionAnnouncement.message(from: nil, to: .webSearch))
        XCTAssertNil(AddressSuggestionAnnouncement.message(from: .webSearch, to: .webSearch))
        XCTAssertNotNil(AddressSuggestionAnnouncement.message(from: .webSearch, to: .askAgent))
        XCTAssertNil(AddressSuggestionAnnouncement.message(from: .askAgent, to: .askAgent))
        XCTAssertNotNil(AddressSuggestionAnnouncement.message(from: .askAgent, to: .open))
        XCTAssertNil(AddressSuggestionAnnouncement.message(from: .open, to: nil))
    }

    @MainActor
    func testAskAgentWhileRunInProgressPreservesPromptInComposerDraft() {
        let app = AppModel()
        app.browser.load(URL(string: "https://example.com/article")!)
        var cfg = app.settings.configuration(for: .ollama)
        cfg.baseURL = "http://127.0.0.1:11434"
        cfg.model = "test-model"
        app.settings.setConfiguration(cfg, for: .ollama)
        app.settings.setModel(ModelSelection(provider: .ollama, model: "test-model"), for: .browserAgent)

        // Start a run that stays active via `BrowserAgentDemoClient(mode: .running)`.
        app.browserAgent.configureDebugModelClient(BrowserAgentDemoClient(mode: .running))
        app.browserAgent.send("first question")
        XCTAssertTrue(app.browserAgent.isRunning)

        app.browser.setEditingAddress(true)
        app.askAgentFromAddressBar("follow up question", in: app.browser)

        XCTAssertFalse(app.browser.isEditingAddress, "Address editing closes")
        XCTAssertEqual(app.drafts.goal, "follow up question", "Prompt must be preserved in composer draft while a run is active")
        app.browserAgent.stop()
    }
}
