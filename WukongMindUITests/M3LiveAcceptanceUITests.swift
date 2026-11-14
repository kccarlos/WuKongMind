import XCTest

/// M3 acceptance, live model (WUKO-41): the two checks that need a tap. Both skip without
/// `TEST_RUNNER_ANTHROPIC_API_KEY` and use `claude-haiku-5-5` only. They need the fixture forum served on
/// `127.0.0.1:8765` (`python3 -m http.server 8765 --bind 127.0.0.1` from a folder holding
/// `crawl/` = `WukongMindTests/Fixtures/CrawlForum`). With `TEST_RUNNER_M3_EVIDENCE_DIR` set, each test
/// writes what it saw there. Never run on the shared phone outside `scripts/device-check.sh`.
final class M3LiveAcceptanceUITests: DCUITestCase {
    private var apiKey: String {
        (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func evidence(_ name: String, _ text: String) {
        attachText(text, named: name)
        guard let dir = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"], !dir.isEmpty else { return }
        try? text.write(toFile: dir + "/" + name + ".txt", atomically: true, encoding: .utf8)
    }

    private func launchLive(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["ANTHROPIC_API_KEY"] = apiKey
        app.launchArguments = ["-dc-skip-onboarding", "-dc-browser-agent-live-model", "claude-haiku-5-5",
                               "-dc-drawer-detent", "large", "-AppleInterfaceStyle", "Light"] + extra
        app.launch()
        return app
    }

    /// Check 5: `cookies_get` always asks (like `http_request` with Confirm before writes on, see AgentNetworkToolsTests); after Don't allow the Agent explains in the conversation.
    func testLiveDontAllowThenTheAgentExplains() throws {
        guard !apiKey.isEmpty else { throw XCTSkip("Set TEST_RUNNER_ANTHROPIC_API_KEY.") }
        let app = launchLive([
            "-dc-open", "http://127.0.0.1:8765/crawl/page-01.html",
            "-dc-browser-agent-live-prompt",
            "Use the cookies_get tool to list this site's cookies. If you are not allowed to, explain to me in your reply why you could not."
        ])
        let card = any(app, "agentConfirmCard")
        XCTAssertTrue(card.waitForExistence(timeout: 90), "The confirmation card did not appear.")
        capture("m3-confirm-card")
        evidence("dont-allow-card-question", any(app, "agentConfirmationQuestion").label)
        app.buttons["agentConfirmDeny"].firstMatch.tap()
        let status = any(app, "agentStatusLine")
        XCTAssertTrue(wait(timeout: 90) {
            status.exists && (status.label.contains("Done") || status.label.contains("Turn failed") || status.label.contains("Stopped"))
        }, "The run did not finish after Don't allow.")
        let reply = any(app, "agentAssistantReply")
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "The Agent must explain in the conversation after Don't allow.")
        capture("m3-after-dont-allow")
        evidence("dont-allow-reply", "status: \(status.label)\nreply: \(reply.label)")
        XCTAssertFalse(reply.label.isEmpty)
    }

    /// Check 6: "This page looks broken" on a page with an active script; tapping it sends the sentence.
    func testLiveThisPageLooksBrokenRow() throws {
        guard !apiKey.isEmpty else { throw XCTSkip("Set TEST_RUNNER_ANTHROPIC_API_KEY.") }
        let app = launchLive([
            "-dc-browser-agent-fixture-page", "-dc-browser-agent-live-key", "-dc-scripts-sample", "page-error"
        ])
        showAssistant(in: app)
        let broken = app.buttons["suggestionPageBroken"].firstMatch
        XCTAssertTrue(waitOrDump(broken, timeout: 30, in: app), "Missing suggestionPageBroken.")
        capture("m3-looks-broken-row")
        evidence("looks-broken-row", "suggestionPageBroken present; label: \(broken.label); hittable: \(broken.isHittable)")
        broken.tap()
        let status = any(app, "agentStatusLine")
        XCTAssertTrue(wait(timeout: 120) {
            status.exists && (status.label.contains("Done") || status.label.contains("Turn failed") || status.label.contains("Stopped"))
        }, "The Agent did not finish after the row was tapped.")
        capture("m3-looks-broken-after")
        let reply = any(app, "agentAssistantReply")
        evidence("looks-broken-reply", "status: \(status.label)\nreply: \(reply.exists ? reply.label : "(none)")")
        XCTAssertTrue(status.label.contains("Done"), status.label)
    }
}
