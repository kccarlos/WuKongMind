import Foundation
import Network
import UIKit
import XCTest

/// Simulator UI tests for T1 (`design-browser-bar-tabs-models.md`, row T1):
/// - Real touch on a `<a target="_blank">` link and a user-gesture `window.open`
///   button opens a new front tab while automatic `window.open` on load stays blocked.
/// - Each tab owns its own `BrowserAgentSession`: Tab 1's conversation stays in Tab 1
///   while the newly opened front tab starts with a fresh empty conversation.
final class BrowserTabsUITests: DCUITestCase {
    private var apiKey: String {
        (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testTargetBlankAndWindowOpenOpenNewFrontTabsWithIsolatedSessions() throws {
        let server = LocalTabsUIFixture()
        try server.start()
        defer { server.stop() }

        let orientation: UIDeviceOrientation = isPhone ? .portrait : .landscapeLeft
        let app = launch(
            [
                "-dc-open", server.guideURL,
                "-dc-browser-agent-demo", "recorded",
                "-dc-drawer-detent", "medium",
                "-AppleInterfaceStyle", "Light"
            ],
            orientation: orientation
        )

        // Wait for Tab 1's recorded Agent turn to finish in Tab 1's session.
        showAssistant(in: app)
        let reply = any(app, "agentAssistantReply")
        XCTAssertTrue(waitOrDump(reply, timeout: 30, in: app), "Tab 1 Agent reply did not appear.")
        capture("t1-recorded-tab1-panel")

        if usesDrawerLayout(app) {
            closeDrawer(in: app)
        }

        // Non-gesture window.open on load must have been blocked (still on /guide).
        let guideHeading = app.webViews.staticTexts["Harbor Ferry Field Guide"].firstMatch
        XCTAssertTrue(waitOrDump(guideHeading, timeout: 15, in: app), "Tab 1 guide page is not visible.")
        XCTAssertFalse(
            app.webViews.staticTexts["Auto Blocked Window"].exists,
            "Non-gesture window.open should be blocked by WKWebView."
        )
        capture("t1-recorded-tab1-page")

        // Tap <a target="_blank">: opens Tab 2 in front with a fresh empty Agent session.
        let blankLink = app.webViews.links["Open Companion Schedule in New Tab"].firstMatch
        XCTAssertTrue(waitForHittable(blankLink, timeout: 10), "target=_blank link is not hittable.")
        blankLink.tap()

        let companionHeading = app.webViews.staticTexts["Companion Ferry Schedule"].firstMatch
        XCTAssertTrue(
            waitOrDump(companionHeading, timeout: 15, in: app),
            "Tapping target=_blank did not bring the new tab to the front."
        )

        showAssistant(in: app)
        XCTAssertFalse(
            any(app, "agentAssistantReply").exists,
            "New tab opened from target=_blank must have its own empty BrowserAgentSession."
        )
        capture("t1-recorded-tab2-blank-fresh-session")

        if usesDrawerLayout(app) {
            closeDrawer(in: app)
        }

        // Real user tap on a button calling window.open('/popup-tariff') opens Tab 3 in front.
        let popupButton = app.webViews
            .descendants(matching: .any)
            .matching(label(contains: "Open Tariff Reference Window"))
            .firstMatch
        XCTAssertTrue(waitOrDump(popupButton, timeout: 10, in: app), "window.open button did not appear.")
        popupButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let popupHeading = app.webViews.staticTexts["Summer Tariff Reference"].firstMatch
        XCTAssertTrue(
            waitOrDump(popupHeading, timeout: 15, in: app),
            "User-gesture window.open did not open a new front tab."
        )
        capture("t1-recorded-tab3-window-open")
    }

    func testLiveTargetBlankOpensFrontTabWithFreshSession() throws {
        try runLiveTargetBlankCheck(style: "Light")
    }

    func testLiveTargetBlankOpensFrontTabWithFreshSessionDark() throws {
        try runLiveTargetBlankCheck(style: "Dark")
    }

    private func runLiveTargetBlankCheck(style: String) throws {
        guard !apiKey.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_ANTHROPIC_API_KEY to run the live claude-haiku-5-5 check.")
        }

        let server = LocalTabsUIFixture()
        try server.start()
        defer { server.stop() }

        let tag = "\(isPhone ? "iphone" : "ipad")-\(style.lowercased())"
        let orientation: UIDeviceOrientation = isPhone ? .portrait : .landscapeLeft

        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchEnvironment["ANTHROPIC_API_KEY"] = apiKey
        app.launchArguments = [
            "-dc-skip-onboarding",
            "-dc-open", server.guideURL,
            "-dc-browser-agent-live-model", "claude-haiku-5-5",
            "-dc-browser-agent-live-prompt",
            "Use read_page to inspect this page, then reply in one short sentence naming the main heading and route code.",
            "-dc-drawer-detent", "medium",
            "-AppleInterfaceStyle", style
        ]
        app.launch()

        let status = any(app, "agentStatusLine")
        XCTAssertTrue(
            wait(timeout: 90) {
                status.exists && (status.label.contains("Done") || status.label.contains("Turn failed"))
            },
            "Live claude-haiku-5-5 run did not finish on Tab 1."
        )
        let reply = any(app, "agentAssistantReply")
        XCTAssertTrue(waitOrDump(reply, timeout: 10, in: app), "Live assistant reply missing on Tab 1.")
        attachText("Tab 1 reply (\(tag)): \(reply.label)", named: "live-reply-\(tag)")
        capture("t1-live-\(tag)-1-tab1-agent")

        if usesDrawerLayout(app) {
            closeDrawer(in: app)
            let guideHeading = app.webViews.staticTexts["Harbor Ferry Field Guide"].firstMatch
            XCTAssertTrue(waitOrDump(guideHeading, timeout: 10, in: app))
            capture("t1-live-\(tag)-2-tab1-page")
        }

        let blankLink = app.webViews.links["Open Companion Schedule in New Tab"].firstMatch
        XCTAssertTrue(waitForHittable(blankLink, timeout: 15), "target=_blank link not hittable on Tab 1.")
        blankLink.tap()

        let companionHeading = app.webViews.staticTexts["Companion Ferry Schedule"].firstMatch
        XCTAssertTrue(
            waitOrDump(companionHeading, timeout: 15, in: app),
            "Tapping target=_blank did not open Companion Ferry Schedule in a new front tab."
        )
        if usesDrawerLayout(app) {
            capture("t1-live-\(tag)-3-tab2-page")
            showAssistant(in: app)
        }

        XCTAssertFalse(
            any(app, "agentAssistantReply").exists,
            "Tab 2 must start with a fresh empty BrowserAgentSession."
        )
        capture("t1-live-\(tag)-4-tab2-fresh-session")
    }

    func testFourthConcurrentRunShowsNoticeUnderComposerLightAndDark() throws {
        let orientation: UIDeviceOrientation = isPhone ? .portrait : .landscapeLeft
        for style in ["Light", "Dark"] {
            let app = launch(
                [
                    "-dc-browser-agent-demo", "run-limit",
                    "-dc-drawer-detent", "medium",
                    "-AppleInterfaceStyle", style
                ],
                orientation: orientation
            )
            showAssistant(in: app)

            let textField = app.textFields["agentPromptInput"].firstMatch
            let input = textField.waitForExistence(timeout: 15)
                ? textField
                : app.textViews["agentPromptInput"].firstMatch
            XCTAssertTrue(waitOrDump(input, timeout: 5, in: app), "Agent composer input missing (\(style)).")
            input.tap()
            input.typeText("Summarize the main points")

            let sendButton = app.buttons["agentSendButton"].firstMatch
            XCTAssertTrue(waitForHittable(sendButton, timeout: 10), "Send button not hittable (\(style)).")
            sendButton.tap()

            let notice = any(app, "agentRunLimitNotice")
            XCTAssertTrue(
                waitOrDump(notice, timeout: 10, in: app),
                "4th-run refusal notice did not appear under the composer (\(style))."
            )
            XCTAssertEqual(notice.label, "3 runs are going. Wait for one or stop it")
            XCTAssertGreaterThanOrEqual(
                notice.frame.minY,
                input.frame.maxY - 6,
                "Refusal notice must sit below the composer input box (\(style))."
            )
            let draftValue = (input.value as? String) ?? ""
            XCTAssertTrue(
                draftValue.contains("Summarize the main points"),
                "Refusing a 4th run must keep the user's draft in the composer (\(style)): \(draftValue)"
            )
            XCTAssertFalse(
                app.buttons["agentStopButton"].exists,
                "4th run must not have started (\(style))."
            )

            let tag = "\(isPhone ? "iphone" : "ipad")-\(style.lowercased())"
            capture("t2-run-limit-\(tag)")
            app.terminate()
        }
    }

    // MARK: - T4: `tabs` Agent tool & "Opened a new tab · Show" row

    func testTabsToolOpenShowsRowAndShowButtonSwitchesToFreshTabLightAndDark() throws {
        let server = LocalTabsUIFixture()
        try server.start()
        defer { server.stop() }

        let orientation: UIDeviceOrientation = isPhone ? .portrait : .landscapeLeft
        for style in ["Light", "Dark"] {
            let tag = "\(isPhone ? "iphone" : "ipad")-\(style.lowercased())"
            let app = launch(
                [
                    "-dc-open", server.guideURL,
                    "-dc-browser-agent-demo", "tabs-open",
                    "-dc-drawer-detent", "large",
                    "-AppleInterfaceStyle", style
                ],
                orientation: orientation
            )

            showAssistant(in: app)
            let reply = any(app, "agentAssistantReply")
            XCTAssertTrue(waitOrDump(reply, timeout: 30, in: app), "T4 recorded reply did not appear (\(tag)).")
            XCTAssertTrue(reply.label.contains("06:10"), "Expected companion schedule details in reply (\(tag)): \(reply.label)")

            // Outside the collapsed `Steps 3` fold, the "Opened a new tab · <url> · in the background" row and Show button show.
            let showButton = app.buttons["agentToolShowTab"].firstMatch
            XCTAssertTrue(waitOrDump(showButton, timeout: 10, in: app), "Show button did not appear on opened-tab row (\(tag)).")
            XCTAssertEqual(showButton.label, "Show")
            XCTAssertGreaterThanOrEqual(showButton.frame.width, 43.5, "Show button hit target width < 44pt (\(tag))")
            XCTAssertGreaterThanOrEqual(showButton.frame.height, 43.5, "Show button hit target height < 44pt (\(tag))")

            let openedRow = app.descendants(matching: .any)
                .matching(identifier: "agentToolRow")
                .matching(label(contains: "Opened a new tab"))
                .firstMatch
            XCTAssertTrue(openedRow.exists, "Opened a new tab row missing (\(tag)).")
            XCTAssertTrue(
                openedRow.label.contains("in the background"),
                "Opened tab row VoiceOver label should include 'in the background' (\(tag)): \(openedRow.label)"
            )
            capture("t4-recorded-\(tag)-1-folded-show")

            // Expand `Steps 3` to match the `PhoneTabs` artboard (`Read page`, `Opened a new tab · Show`, `Read page`).
            let stepsFold = app.buttons["agentStepsSummary"].firstMatch
            if stepsFold.exists {
                stepsFold.tap()
                XCTAssertTrue(
                    wait(timeout: 5) { app.buttons.matching(identifier: "agentToolShowTab").count == 1 },
                    "Expected exactly one Show button when Steps 3 is expanded (\(tag))."
                )
                capture("t4-recorded-\(tag)-2-expanded-steps")
            }

            // Tab 1 is still on /guide before tapping Show.
            if !usesDrawerLayout(app) {
                XCTAssertTrue(app.webViews.staticTexts["Harbor Ferry Field Guide"].firstMatch.exists)
            }

            // Tap Show: switches front tab to Tab 2 (/companion), lowers drawer from .large to .medium on iPhone,
            // and presents Tab 2's fresh empty Agent conversation.
            showButton.tap()

            let companionHeading = app.webViews.staticTexts["Companion Ferry Schedule"].firstMatch
            XCTAssertTrue(
                waitOrDump(companionHeading, timeout: 15, in: app),
                "Tapping Show did not switch the front tab to Companion Ferry Schedule (\(tag))."
            )
            XCTAssertFalse(
                any(app, "agentAssistantReply").exists,
                "Switched background tab must start with an empty conversation (\(tag))."
            )
            capture("t4-recorded-\(tag)-3-after-show-tab2")
            app.terminate()
        }
    }

    func testTabsToolOpenedNewTabRowAccessibilityXXXL() throws {
        let server = LocalTabsUIFixture()
        try server.start()
        defer { server.stop() }

        let orientation: UIDeviceOrientation = isPhone ? .portrait : .landscapeLeft
        let tag = isPhone ? "iphone" : "ipad"
        let app = launch(
            [
                "-dc-open", server.guideURL,
                "-dc-browser-agent-demo", "tabs-open",
                "-dc-drawer-detent", "large",
                "-AppleInterfaceStyle", "Light",
                "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
            ],
            orientation: orientation
        )

        showAssistant(in: app)
        let showButton = app.buttons["agentToolShowTab"].firstMatch
        XCTAssertTrue(waitOrDump(showButton, timeout: 30, in: app), "Show button missing at XXXL Dynamic Type (\(tag)).")
        XCTAssertGreaterThanOrEqual(showButton.frame.width, 43.5)
        XCTAssertGreaterThanOrEqual(showButton.frame.height, 43.5)
        capture("t4-recorded-\(tag)-xxxl")
        app.terminate()
    }

    func testLiveTabsToolOpensBackgroundTabWithShowButton() throws {
        guard !apiKey.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_ANTHROPIC_API_KEY to run the live claude-haiku-5-5 tabs check.")
        }

        let server = LocalTabsUIFixture()
        try server.start()
        defer { server.stop() }

        let tag = isPhone ? "iphone" : "ipad"
        let orientation: UIDeviceOrientation = isPhone ? .portrait : .landscapeLeft
        let companionURL = "\(server.baseURL)/companion"

        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchEnvironment["ANTHROPIC_API_KEY"] = apiKey
        app.launchArguments = [
            "-dc-skip-onboarding",
            "-dc-developer-mode",
            "-dc-open", server.guideURL,
            "-dc-browser-agent-live-model", "claude-haiku-5-5",
            "-dc-browser-agent-live-prompt",
            "Open \(companionURL) in a new background tab with the tabs tool (do not switch the front tab), read that new tab with the tabs tool to get the first and last boat times, and answer in one short sentence.",
            "-dc-drawer-detent", "large",
            "-AppleInterfaceStyle", "Light"
        ]
        app.launch()

        let status = any(app, "agentStatusLine")
        XCTAssertTrue(
            wait(timeout: 90) {
                status.exists && (status.label.contains("Done") || status.label.contains("Turn failed"))
            },
            "Live claude-haiku-5-5 tabs run did not finish (\(tag))."
        )
        let reply = any(app, "agentAssistantReply")
        XCTAssertTrue(waitOrDump(reply, timeout: 10, in: app), "Live claude-haiku-5-5 reply missing (\(tag)).")
        attachText("Live claude-haiku-5-5 reply (\(tag)): \(reply.label)", named: "t4-live-reply-\(tag)")

        let showButton = app.buttons["agentToolShowTab"].firstMatch
        XCTAssertTrue(waitOrDump(showButton, timeout: 10, in: app), "Live claude-haiku-5-5 run did not show the Show button (\(tag)).")
        capture("t4-live-\(tag)-1-before-show")

        // Expand steps (if folded) and tap a tool row in developer mode so `claude-haiku-5-5` is visible in the proof!
        let stepsFold = app.buttons["agentStepsSummary"].firstMatch
        if stepsFold.exists {
            stepsFold.tap()
        }
        let firstRow = app.descendants(matching: .any).matching(identifier: "agentToolRow").firstMatch
        if firstRow.waitForExistence(timeout: 5) {
            firstRow.tap()
            _ = any(app, "agentDevTurnLine").waitForExistence(timeout: 5)
        }
        capture("t4-live-\(tag)-2-model-id")

        // Tap Show to verify switching to the newly opened background tab.
        let activeShow = app.buttons["agentToolShowTab"].firstMatch
        XCTAssertTrue(waitOrDump(activeShow, timeout: 5, in: app))
        activeShow.tap()

        let companionHeading = app.webViews.staticTexts["Companion Ferry Schedule"].firstMatch
        XCTAssertTrue(
            waitOrDump(companionHeading, timeout: 15, in: app),
            "Tapping Show after live claude-haiku-5-5 tabs open did not switch to Companion Ferry Schedule (\(tag))."
        )
        capture("t4-live-\(tag)-3-after-show")
    }
}

private final class LocalTabsUIFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BrowserTabsUITests.Fixture")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    var baseURL: String { "http://127.0.0.1:\(port)" }
    var guideURL: String { "\(baseURL)/guide" }

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
            let rawPath = parts.count >= 2 ? String(parts[1]) : "/"
            let path = rawPath.components(separatedBy: "?").first ?? "/"

            let body: String
            switch path {
            case "/guide":
                body = """
                <!doctype html>
                <html>
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1">
                  <title>Harbor Ferry Field Guide</title>
                  <style>
                    :root { color-scheme: light dark; }
                    body { font-family: -apple-system, sans-serif; margin: 24px; line-height: 1.5; background: #faf8f5; color: #1c1917; }
                    .badge { display: inline-block; padding: 4px 10px; border-radius: 6px; background: #e7e5e4; font-size: 13px; font-weight: 600; }
                    .card { margin-top: 18px; padding: 18px; border-radius: 12px; background: #ffffff; border: 1px solid #d6d3d1; }
                    a.cta { display: inline-block; margin-top: 14px; padding: 12px 16px; border-radius: 10px; background: #1c1917; color: #fafaf9; text-decoration: none; font-weight: 600; }
                    .sidebar { margin-top: 18px; padding: 12px; border-radius: 8px; background: #f5f5f4; color: #57534e; font-size: 14px; }
                    @media (prefers-color-scheme: dark) {
                      body { background: #161514; color: #f5f5f4; }
                      .badge { background: #292524; color: #e7e5e4; }
                      .card { background: #211f1d; border-color: #3f3b37; }
                      a.cta { background: #f5f5f4; color: #1c1917; }
                      .sidebar { background: #24211f; color: #a8a29e; }
                    }
                  </style>
                </head>
                <body>
                  <span class="badge">Route NF-04 · Tab 1</span>
                  <h1>Harbor Ferry Field Guide</h1>
                  <p>Morning crossings depart Pier 7 every 20 minutes with priority boarding for foot passengers.</p>
                  <div class="card">
                    <strong>Connected timetable</strong>
                    <p>Open the companion schedule in a separate tab while keeping this guide and its Agent conversation open.</p>
                    <a id="companion-blank" class="cta" href="/companion" target="_blank" rel="noopener">Open Companion Schedule in New Tab</a>
                  </div>
                  <aside class="sidebar">Terminal bulletin: Bay wind 11 kt NW.</aside>
                  <script>
                    window.blockedOnLoad = window.open('/auto-blocked');
                  </script>
                </body>
                </html>
                """
            case "/companion":
                body = """
                <!doctype html>
                <html>
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1">
                  <title>Companion Ferry Schedule</title>
                  <style>
                    :root { color-scheme: light dark; }
                    body { font-family: -apple-system, sans-serif; margin: 24px; line-height: 1.5; background: #f4f7fb; color: #0f172a; }
                    .badge { display: inline-block; padding: 4px 10px; border-radius: 6px; background: #dbeafe; color: #1e3a8a; font-size: 13px; font-weight: 600; }
                    .card { margin-top: 18px; padding: 18px; border-radius: 12px; background: #ffffff; border: 1px solid #cbd5e1; }
                    button.cta { margin-top: 14px; padding: 12px 16px; border-radius: 10px; border: none; background: #1e3a8a; color: #ffffff; font-size: 16px; font-weight: 600; }
                    @media (prefers-color-scheme: dark) {
                      body { background: #131822; color: #f1f5f9; }
                      .badge { background: #1e293b; color: #93c5fd; }
                      .card { background: #1c2432; border-color: #334155; }
                      button.cta { background: #60a5fa; color: #0f172a; }
                    }
                  </style>
                </head>
                <body>
                  <span class="badge">Opened via target=_blank · Front Tab</span>
                  <h1>Companion Ferry Schedule</h1>
                  <p>First boat 06:10 · Last boat 22:50 · Peak headway 15 minutes.</p>
                  <div class="card">
                    <strong>Fare classes</strong>
                    <p>Check seasonal foot-passenger and bicycle fare rules in a reference window.</p>
                    <button id="popup-btn" type="button" aria-label="Open Tariff Reference Window" class="cta" onclick="window.open('/popup-tariff');">Open Tariff Reference Window</button>
                  </div>
                </body>
                </html>
                """
            case "/popup-tariff":
                body = """
                <!doctype html>
                <html>
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1">
                  <title>Summer Tariff Reference</title>
                  <style>
                    body { font-family: -apple-system, sans-serif; margin: 24px; line-height: 1.5; background: #f7fee7; color: #1a2e05; }
                    .badge { display: inline-block; padding: 4px 10px; border-radius: 6px; background: #d9f99d; font-size: 13px; font-weight: 600; }
                  </style>
                </head>
                <body>
                  <span class="badge">Opened via window.open · Front Tab</span>
                  <h1>Summer Tariff Reference</h1>
                  <p>Adult single crossing $6.50 · Bicycle supplement $1.00.</p>
                </body>
                </html>
                """
            default:
                body = """
                <!doctype html>
                <html>
                <head><meta charset="utf-8"><title>Auto Blocked Window</title></head>
                <body><h1>Auto Blocked Window</h1></body>
                </html>
                """
            }

            let bytes = Data(body.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            let closeQueue = self.queue
            conn.send(content: Data(header.utf8) + bytes, isComplete: true, completion: .contentProcessed { _ in
                closeQueue.asyncAfter(deadline: .now() + .milliseconds(200)) {
                    conn.cancel()
                }
            })
        }
    }
}
