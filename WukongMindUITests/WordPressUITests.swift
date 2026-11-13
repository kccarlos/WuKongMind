import XCTest

/// P1 W12: a local WordPress site (`FixtureWordPressServer`, loopback, never
/// the network) opened in the in-app browser. The page is recognized, a
/// summary reads the article and every comment and runs against a fixture
/// Ollama endpoint on the same server (`-dc-fixture-model`), and a follow-up
/// chat answers. The comments the summary reads come through the page's own
/// `fetch()` (the in-page loader) with `X-WP-Total` readable, so no extra
/// page is probed.
final class WordPressUITests: DCUITestCase {
    private var server: FixtureWordPressServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = FixtureWordPressServer()
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        super.tearDown()
    }

    private func launchOnPost() -> XCUIApplication {
        launch(["-dc-open", server.postURL, "-dc-fixture-model", server.baseURL])
    }

    func testCitationTapTargets() throws {
        let app = try citationSummary()
        for offset in [CGFloat(0), -20, 20] {
            assertCitationTaps(in: app, scenario: "vertical offset \(offset)", offset: offset)
        }
    }

    func testCitationTapsWhileStreaming() throws {
        let app = try citationSummary(streaming: true)
        // Hold across multiple 0.12 s parse ticks, including touch-up.
        assertCitationTaps(in: app, scenario: "streaming", duration: 0.25)
    }

    func testCitationTapsFromLargeDetent() throws {
        let app = try citationSummary()
        assertCitationTaps(in: app, scenario: "large") {
            self.dragDrawer(in: app, to: 0.08)
            XCTAssertTrue(self.wait(timeout: 5) { self.drawerState(in: app).label == "detent=large" })
        }
    }

    func testCitationTapsWithKeyboardFocused() throws {
        let app = try citationSummary()
        assertCitationTaps(in: app, scenario: "keyboard") {
            app.textFields["agentPromptInput"].tap()
        }
    }

    func testCitationTapsAfterScrolling() throws {
        let app = try citationSummary(long: true)
        assertCitationTaps(in: app, scenario: "after scroll") {
            self.dragDrawer(in: app, to: 0.08)
            let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4))
            let end = start.withOffset(CGVector(dx: 0, dy: -100))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            end.press(forDuration: 0.01, thenDragTo: start, withVelocity: .fast, thenHoldForDuration: 0)
        }
    }

    private func citationSummary(streaming: Bool = false, long: Bool = false) throws -> XCUIApplication {
        try skipUnlessPhone("Citation touch targets")
        continueAfterFailure = true
        server.pageComments = """
        <div style="height:2400px"></div>
        <article class="comment" id="comment-5001"><b class="comment-author"><span class="fn">user1</span></b>
        <p class="comment-content">CITATION TARGET 5001</p></article>
        <div style="height:2400px"></div>
        """
        let text = "Readers cite #1 and #2. More words follow on the next line for comparison."
        server.streamedSummary = streaming
            ? ([text] + Array(repeating: " more", count: 3000), 0.12)
            : ([text + (long ? String(repeating: "\n\nReaders compare their experiences and discuss the options.", count: 40) : "")], 0.01)
        let app = launchOnPost()
        let summarize = app.buttons["dockHintAction"].firstMatch
        XCTAssertTrue(waitOrDump(summarize, timeout: 30, in: app))
        summarize.tap()
        XCTAssertTrue(app.buttons["citation-1"].firstMatch.waitForExistence(timeout: 60))
        return app
    }

    /// Reset to the opposite distant post before every probe, so a missed
    /// tap cannot inherit an earlier result. Never retry the measured tap.
    private func assertCitationTaps(
        in app: XCUIApplication, scenario: String, offset: CGFloat = 0,
        duration: TimeInterval = 0, beforeTap: () -> Void = {}
    ) {
        func landed(_ number: Int) -> Bool {
            let target = app.webViews.staticTexts[number == 2 ? "CITATION TARGET 5001" : "Sample Cards"].firstMatch
            return target.exists && target.frame.minY > 0 && target.frame.minY < app.frame.height / 2
        }
        func visibleCitation(_ number: Int) -> XCUIElement {
            let chip = app.buttons["citation-\(number)"].firstMatch
            for _ in 0..<6 {
                let top = any(app, "drawerHeader").frame.maxY
                let bottom = any(app, "askBox").frame.minY
                if chip.frame.minY >= top && chip.frame.maxY <= bottom { break }
                let start = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: app.frame.width * 0.75, dy: (top + bottom) / 2))
                let distance = min(160, (bottom - top) / 3)
                start.press(forDuration: 0.01, thenDragTo: start.withOffset(
                    CGVector(dx: 0, dy: chip.frame.minY < top ? distance : -distance)),
                    withVelocity: .slow, thenHoldForDuration: 0)
            }
            XCTAssertGreaterThanOrEqual(chip.frame.minY, any(app, "drawerHeader").frame.maxY, "\(scenario): citation-\(number) is above the drawer content")
            XCTAssertLessThanOrEqual(chip.frame.maxY, any(app, "askBox").frame.minY, "\(scenario): citation-\(number) is below the drawer content")
            return chip
        }
        let pageLoads = server.requests.filter { $0.path == "/hello-world/" || $0.path == "/" }.count
        var successes = 0
        for index in 0..<20 {
            let number = index.isMultiple(of: 2) ? 2 : 1
            visibleCitation(number == 1 ? 2 : 1).tap()
            XCTAssertTrue(wait(timeout: 3) { landed(number == 1 ? 2 : 1) })
            beforeTap()
            let chip = visibleCitation(number)
            let frame = chip.frame
            XCTAssertGreaterThanOrEqual(frame.width, 44)
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            let point = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY + offset))
            if duration > 0 { point.press(forDuration: duration) } else { point.tap() }
            let jumped = wait(timeout: 2) { landed(number) }
            if jumped { successes += 1 }
            XCTAssertTrue(jumped, "\(scenario), tap=\(index + 1), post=\(number), chip=\(frame)")
        }
        XCTAssertEqual(server.requests.filter { $0.path == "/hello-world/" || $0.path == "/" }.count, pageLoads,
                       "Article and comment citations must scroll without reloading")
        attachText("\(successes)/20", named: "Citation \(scenario)")
        print("CITATION RATE \(scenario): \(successes)/20")
        capture("citation-" + scenario)
    }

    func testGroupedCitationScrollsToItsNativeCommentWithoutReloading() throws {
        server.pageComments = """
        <div style="height:2400px"></div>
        <article class="comment" id="comment-5001"><b class="comment-author"><span class="fn">user1</span></b>
        <p class="comment-content">CITATION TARGET 5001</p></article>
        <div style="height:2400px"></div>
        """
        server.streamedSummary = (["Readers agree [#2 #3]."], 0.01)
        let app = launchOnPost()
        let summarize = app.buttons["dockHintAction"].firstMatch
        XCTAssertTrue(waitOrDump(summarize, timeout: 30, in: app))
        summarize.tap()
        let first = app.buttons["citation-2"].firstMatch
        let last = app.buttons["citation-3"].firstMatch
        XCTAssertTrue(waitOrDump(first, timeout: 60, in: app))
        XCTAssertTrue(last.exists, "Both bracketed citations must render as chips")
        let before = server.requests.filter { $0.path == "/hello-world/" }.count
        capture("grouped-citations-before-jump")
        first.tap()
        let target = app.webViews.staticTexts["CITATION TARGET 5001"].firstMatch
        XCTAssertTrue(wait(timeout: 10) { target.exists && target.isHittable && target.frame.minY > 0 && target.frame.minY < app.frame.height / 2 })
        XCTAssertEqual(server.requests.filter { $0.path == "/hello-world/" }.count, before,
                       "An on-page comment must scroll without reloading")
        attachText("Target frame: \(target.frame); page loads: \(before)", named: "native citation landing")
        capture("native-comment-after-jump")
    }

    func testAWordPressPostIsRecognizedAndSummarizedThroughTheInPageLoader() throws {
        let app = launchOnPost()

        // Recognized: the post is a topic, so the Dock hint offers Summarize.
        let summarize = app.buttons["dockHintAction"].firstMatch
        XCTAssertTrue(waitOrDump(summarize, timeout: 30, in: app), "A WordPress post offers no summary.")
        XCTAssertTrue(waitForHittable(summarize))
        summarize.tap()

        let summary = any(app, "summaryContent")
        XCTAssertTrue(waitOrDump(summary, timeout: 60, in: app), "The summary did not appear.")
        XCTAssertTrue(
            wait(timeout: 30) { self.server.modelRequests.contains { $0.contains("Comment number 250") } },
            "The model was not handed the last comment; requests: \(server.modelRequests.map(\.count))"
        )
        let handed = try XCTUnwrap(server.modelRequests.first { $0.contains("Comment number 250") })
        XCTAssertTrue(handed.contains("The opening article of the fixture blog"), "The article is missing from the model input.")
        XCTAssertTrue(handed.contains("Comment number 1 "), "The first comment is missing from the model input.")
        XCTAssertTrue(
            wait(timeout: 20) { app.staticTexts.containing(self.label(contains: FixtureWordPressServer.summaryMarker)).firstMatch.exists },
            "The model's summary is not shown."
        )

        // In-page loader: the comments were read in three pages by the shown
        // page itself (a Referer), and no fourth page was probed because
        // X-WP-Total reached the app.
        let comments = server.commentRequests.filter { $0.query["post"] == "\(FixtureWordPressServer.postID)" && $0.query["per_page"] == "100" }
        attachText(comments.map { "\($0.line) referer=\($0.headers["referer"] ?? "-")" }.joined(separator: "\n"), named: "comment requests")
        XCTAssertEqual(comments.compactMap { $0.query["page"] }.sorted(), ["1", "2", "3"], "Exactly three comment pages: the total came from X-WP-Total.")
        XCTAssertTrue(comments.allSatisfy { $0.headers["referer"]?.hasPrefix(server.baseURL) == true },
                      "Comments were not read by the page's own fetch (the in-page loader).")

        // Unified Agent composer is pinned below the summary.
        XCTAssertTrue(app.textFields["agentPromptInput"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["composerMic"].exists)
    }
}
