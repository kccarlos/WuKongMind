import Network
import UIKit
import XCTest

/// Post-level browsing on a live topic: opening a topic at a post lands
/// there and highlights it, then a search shows numbered result cards and
/// Next opens the first hit. The page position comes from the DEBUG
/// `browseDebugState` element (`-dc-browse-debug`), which shows the posts
/// the bridge reports highlighted on the page itself.
final class BrowseUITests: DCUITestCase {
    func testOpeningAtAPostHighlightsItAndTheCardsMoveAlongTheHits() throws {
        let topic = try liveTopic(minimumPosts: 5)
        // A post that exists: deleted posts leave gaps in the numbers.
        let numbers = try livePostNumbers(topicID: topic.id)
        guard numbers.count >= 3 else { throw XCTSkip("The live topic has too few regular posts.") }
        let post = numbers[2]
        let app = try launchOnForum(
            topic.url.absoluteString,
            extra: ["-dc-browse-post", String(post), "-dc-browse-find", "plugin", "-dc-browse-debug"]
        )
        showBrowser(in: app)

        let state = any(app, "browseDebugState")
        XCTAssertTrue(waitOrDump(state, timeout: 30, in: app), "The browse state hook is missing.")
        let landed = wait(timeout: 90) {
            state.label.contains("post=\(post) ") && state.label.contains("highlighted=\(post) ")
        }
        attachText(state.label, named: "state after landing")
        XCTAssertTrue(landed, "The page didn't land on post \(post) with it highlighted: \(state.label)")

        let cards = any(app, "resultCards")
        let chip = app.buttons["resultCardsChip"]
        // Split layout with the panel up: the cards are the panel's chip, not
        // also a strip over the page (audit A9); hiding the panel brings the strip.
        let panel = any(app, "aiPanel")
        if !usesDrawerLayout(app), panel.exists {
            XCTAssertTrue(waitOrDump(any(app, "drawerCardsChip"), timeout: 60, in: app), "No cards chip in the panel.")
            XCTAssertFalse(cards.exists || chip.exists, "Strip and chip at once.")
            app.buttons["aiPanelToggle"].tap()
            XCTAssertTrue(waitForGone(panel, timeout: 5))
        }
        // Scrolling minimizes the bar, which shrinks the cards to a chip.
        let shown = wait(timeout: 60) { cards.exists || chip.exists }
        if !shown { attachTree(app) }
        XCTAssertTrue(shown, "No result cards after the search.")
        if !cards.exists { chip.tap() }
        XCTAssertTrue(waitOrDump(any(app, "resultCard-1"), timeout: 10, in: app))
        attachScreenshot(named: "result-cards")

        let next = app.buttons["resultCardsNext"]
        XCTAssertTrue(waitForHittable(next), "Next is missing on the cards.")
        next.tap()
        // The first hit opens (another topic, or this one) and is marked.
        let moved = wait(timeout: 90) {
            state.label.contains("current=1") && state.label.range(of: #"highlighted=\d"#, options: .regularExpression) != nil
        }
        attachText(state.label, named: "state after next")
        attachScreenshot(named: "after-next")
        XCTAssertTrue(moved, "Next didn't open the first hit highlighted: \(state.label)")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testResultCardsStackVerticallyAtAccessibilitySizeAndIncludeExcerptInVoiceOver() throws {
        let server = LocalDiscourseSearchFixture()
        try server.start()
        defer { server.stop() }

        let app = launch(
            [
                "-UIPreferredContentSizeCategoryName",
                UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
                "-dc-open", server.topicURL,
                "-dc-browse-find", "firmware",
                "-dc-force-width", "375"
            ],
            orientation: .portrait
        )

        let card1 = any(app, "resultCard-1")
        let card2 = any(app, "resultCard-2")
        XCTAssertTrue(card1.waitForExistence(timeout: 20), "Result card 1 did not appear.")
        XCTAssertTrue(card2.waitForExistence(timeout: 5), "Result card 2 did not appear.")
        XCTAssertFalse(
            app.buttons["resultCardsCollapse"].exists,
            "Expected accessibility Dynamic Type (AX5) to be active."
        )

        XCTAssertGreaterThanOrEqual(
            card2.frame.minY,
            card1.frame.maxY - 4,
            "At accessibility Dynamic Type, result cards stayed side-by-side (\(card1.frame) vs \(card2.frame)) instead of stacking vertically."
        )

        let combinedVO = "\(card1.label) | \((card1.value as? String) ?? "")"
        XCTAssertTrue(
            combinedVO.localizedCaseInsensitiveContains("belt tension"),
            "ResultCard VoiceOver (\(combinedVO)) omits the visible card excerpt."
        )
    }
}

private final class LocalDiscourseSearchFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "browse-discourse-fixture")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    var baseURL: String { "http://127.0.0.1:\(port)" }
    var topicURL: String { "\(baseURL)/t/welcome-topic/42" }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        self.listener = listener
        self.port = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            guard let data, let req = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let firstLine = req.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let target = parts.count >= 2 ? String(parts[1]) : "/"
            let pathOnly = target.components(separatedBy: "?").first ?? "/"

            let (contentType, body): (String, String)
            if pathOnly == "/site/basic-info.json" {
                contentType = "application/json"
                body = #"{"title":"Local Discourse","description":"Fixture forum"}"#
            } else if pathOnly == "/search.json" {
                contentType = "application/json"
                body = """
                {
                  "posts": [
                    {"id": 101, "post_number": 1, "username": "alice", "blurb": "Check the belt tension and stepper current first.", "topic_id": 42},
                    {"id": 102, "post_number": 12, "username": "bob", "blurb": "Downgrading firmware 2.3 fixed the layer shift completely.", "topic_id": 43}
                  ],
                  "topics": [
                    {"id": 42, "title": "Layer shifts after firmware update", "slug": "welcome-topic", "posts_count": 15},
                    {"id": 43, "title": "Stepper current guide for 2.4", "slug": "stepper-guide", "posts_count": 8}
                  ]
                }
                """
            } else {
                contentType = "text/html; charset=utf-8"
                body = """
                <!doctype html><html><head><meta charset="utf-8"><title>Welcome Topic - Local Discourse</title>
                <meta name="generator" content="Discourse 3.3.0">
                <meta property="og:site_name" content="Local Discourse">
                </head><body>
                <article data-post-number="1" id="post_1"><p>Post 1 content.</p></article>
                <article data-post-number="12" id="post_12"><p>Post 12 content.</p></article>
                </body></html>
                """
            }

            let bytes = Data(body.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(header.utf8) + bytes, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
