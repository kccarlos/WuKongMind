import XCTest

/// The share extension hands pages to the app as
/// `wukongmind://open?url=…&action=open|summary|chat|agent`
/// (IncomingLink.swift). These tests open that link in the running app.
final class ShareHandoffUITests: DCUITestCase {
    func testSummaryLinkOpensTopicAndAsksForAProvider() throws {
        let topic = try liveTopic()
        let app = launchForHandoff()

        app.open(deepLink(topic.url, action: "summary"))

        // Once the shared topic is detected the Assistant asks for a
        // provider instead of starting a summary.
        let setupSheet = app.navigationBars["Connect an AI provider"]
        guard setupSheet.waitForExistence(timeout: 45) else {
            attachTree(app)
            XCTFail("The provider setup prompt did not appear for a shared summary.")
            return
        }
        XCTAssertTrue(setupSheet.buttons["Later"].exists)
        XCTAssertFalse(setupSheet.buttons["Done"].isEnabled, "Done needs a configured provider.")
        setupSheet.buttons["Later"].tap()
        XCTAssertTrue(waitForGone(setupSheet, timeout: 10))

        // The AI view (the drawer, or the panel in the split layout) shows.
        XCTAssertTrue(
            any(app, usesDrawerLayout(app) ? "drawerHeader" : "aiPanel").waitForExistence(timeout: 10),
            "The Assistant did not appear."
        )
        XCTAssertTrue(any(app, "providerSetupCard").waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "pageCapabilitiesSeal").waitForExistence(timeout: 10), "This page seal is missing.")
        XCTAssertFalse(any(app, "summaryContent").exists, "No summary may start without a provider.")

        // The browser shows the shared topic.
        showBrowser(in: app)
        XCTAssertTrue(
            waitOrDump(address(containing: "/\(topic.id)", in: app), timeout: 10, in: app),
            "The browser did not open the shared topic \(topic.url)."
        )
    }

    func testChatLinkOpensTheChatMode() throws {
        let topic = try liveTopic()
        let app = launchForHandoff()

        app.open(deepLink(topic.url, action: "chat"))

        let setupSheet = app.navigationBars["Connect an AI provider"]
        guard setupSheet.waitForExistence(timeout: 60) else {
            attachTree(app)
            XCTFail("The provider setup prompt did not appear for a shared chat.")
            return
        }
        setupSheet.buttons["Later"].tap()
        // The unified panel pins the Agent composer at the bottom.
        XCTAssertTrue(any(app, "agentPromptInput").waitForExistence(timeout: 10), "The AI view has no Agent composer.")
    }

    func testOpenLinkOnlyLoadsThePage() throws {
        try requireNetwork()
        let app = launchForHandoff()

        guard let url = URL(string: "https://\(Self.forumHost)/top") else { return }
        app.open(deepLink(url, action: "open"))

        XCTAssertTrue(
            waitOrDump(address(containing: "\(Self.forumHost)/top", in: app), timeout: 30, in: app),
            "The shared page did not load."
        )
        XCTAssertFalse(any(app, "home").exists)
        // "open" never switches to the Assistant or asks for a provider.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app.navigationBars["Connect an AI provider"].exists)
        if usesDrawerLayout(app) {
            XCTAssertFalse(drawerState(in: app).exists, "An open link must not open the AI drawer.")
        }
    }

    // MARK: Helpers

    /// `XCUIApplication.open(_:)` may relaunch the app with the same launch
    /// arguments, so these tests pass none that load a page (`-dc-open`) or
    /// show the Forums home later (`-dc-forums-home`): either would replace
    /// the shared page.
    private func launchForHandoff() -> XCUIApplication {
        let app = launch(["-dc-no-provider"])
        XCTAssertTrue(app.buttons["forumSwitcher"].waitForExistence(timeout: 20))
        return app
    }

    private func deepLink(_ page: URL, action: String) -> URL {
        var components = URLComponents()
        components.scheme = "wukongmind"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "url", value: page.absoluteString),
            URLQueryItem(name: "action", value: action)
        ]
        return components.url!
    }
}
