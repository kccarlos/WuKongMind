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

    // MARK: - T3: Tab Overview, Close (Button & Swipe), Reorder, Undo Stopped Run, VoiceOver, Shortcuts

    private func tapTabsButton(in app: XCUIApplication) {
        let button = app.buttons["browserTabsButton"].firstMatch
        XCTAssertTrue(waitOrDump(button, timeout: 10, in: app), "Tabs button missing in browser bar.")
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func longPressTabsButton(in app: XCUIApplication) {
        let button = app.buttons["browserTabsButton"].firstMatch
        XCTAssertTrue(waitOrDump(button, timeout: 10, in: app), "Tabs button missing in browser bar.")
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
    }

    /// Waits past `-dc-browser-agent-demo`'s two-step `500ms + 1200ms` drawer reveal on iPhone
    /// and closes the drawer so web-page links and the bottom browser bar are uncovered.
    private func dismissDemoDrawerIfNeeded(in app: XCUIApplication) {
        guard usesDrawerLayout(app) else { return }
        _ = any(app, "drawerState").waitForExistence(timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        closeDrawer(in: app)
    }

    private func tapCardClose(on card: XCUIElement) {
        card.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
            .withOffset(CGVector(dx: -22, dy: 22))
            .tap()
    }

    func testTabOverviewOpenAddCloseByButtonAndSwipeAndDragReorder() throws {
        let server = LocalTabsUIFixture()
        try server.start()
        defer { server.stop() }
        XCUIDevice.shared.appearance = .light
        defer { XCUIDevice.shared.appearance = .light }

        let orientation: UIDeviceOrientation = isPhone ? .portrait : .landscapeLeft
        let app = launch(
            [
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                "-dc-open", server.guideURL,
                "-dc-browser-agent-demo", "empty"
            ],
            orientation: orientation
        )

        let guideHeading = app.webViews.staticTexts["Harbor Ferry Field Guide"].firstMatch
        XCTAssertTrue(waitOrDump(guideHeading, timeout: 15, in: app), "Initial guide page did not load.")
        dismissDemoDrawerIfNeeded(in: app)

        // Tap <a target="_blank"> on Tab 1 -> opens Tab 2 (/companion), then window.open -> opens Tab 3 (/popup-tariff).
        let blankLink = app.webViews.links["Open Companion Schedule in New Tab"].firstMatch
        XCTAssertTrue(waitForHittable(blankLink, timeout: 10))
        blankLink.tap()
        let companionHeading = app.webViews.staticTexts["Companion Ferry Schedule"].firstMatch
        XCTAssertTrue(waitOrDump(companionHeading, timeout: 15, in: app))

        let popupButton = app.webViews
            .descendants(matching: .any)
            .matching(label(contains: "Open Tariff Reference Window"))
            .firstMatch
        XCTAssertTrue(waitOrDump(popupButton, timeout: 10, in: app))
        popupButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let popupHeading = app.webViews.staticTexts["Summer Tariff Reference"].firstMatch
        XCTAssertTrue(waitOrDump(popupHeading, timeout: 15, in: app))

        if usesDrawerLayout(app) {
            closeDrawer(in: app)
        } else {
            // On iPad split layout, verify the Agent panel is visible before opening the overview.
            XCTAssertTrue(any(app, "aiPanel").exists, "iPad split layout should show Agent panel on a web page.")
        }

        // Open the tab overview from the bar's Tabs button.
        tapTabsButton(in: app)
        let overview = any(app, "tabOverview")
        XCTAssertTrue(waitOrDump(overview, timeout: 10, in: app), "Tab overview did not open.")

        if !usesDrawerLayout(app) {
            XCTAssertFalse(any(app, "aiPanel").exists, "iPad Agent panel must hide while the tab overview shows.")
        }

        let countLabel = any(app, "tabOverviewCount")
        XCTAssertTrue(waitOrDump(countLabel, timeout: 5, in: app))
        XCTAssertEqual(countLabel.label, "3 tabs")

        // Tap `+` (New tab): opens Tab 4 on Home and closes the overview.
        let newTabButton = app.buttons["tabOverviewNewTab"].firstMatch
        XCTAssertTrue(waitOrDump(newTabButton, timeout: 5, in: app))
        newTabButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitForGone(overview, timeout: 5), "Opening a new tab should zoom into Home.")

        // Reopen the overview: 4 tabs are open (Guide, Companion, Tariff, Home).
        tapTabsButton(in: app)
        XCTAssertTrue(waitOrDump(overview, timeout: 10, in: app))
        XCTAssertTrue(wait(timeout: 5) { countLabel.label == "4 tabs" }, "Got \(countLabel.label)")

        let card1 = any(app, "tabOverviewCard-t1")
        let card2 = any(app, "tabOverviewCard-t2")
        let card3 = any(app, "tabOverviewCard-t3")
        let card4 = any(app, "tabOverviewCard-t4")
        XCTAssertTrue(card1.exists && card2.exists && card3.exists && card4.exists)
        XCTAssertTrue(card1.label.contains("Harbor Ferry Field Guide"), "Got \(card1.label)")
        XCTAssertTrue(card4.label.contains("Home") && card4.label.contains("current tab"), "Got \(card4.label)")

        if isPhone {
            // 2-column grid on iPhone: card1 and card2 sit on row 1, card3 and card4 on row 2.
            XCTAssertLessThan(card1.frame.minX, card2.frame.minX)
            XCTAssertEqual(card1.frame.minY, card2.frame.minY, accuracy: 8)
            XCTAssertGreaterThan(card3.frame.minY, card1.frame.maxY - 8)
        } else {
            // 4-column grid on iPad: all 4 cards sit side by side on row 1.
            XCTAssertLessThan(card1.frame.minX, card2.frame.minX)
            XCTAssertLessThan(card2.frame.minX, card3.frame.minX)
            XCTAssertLessThan(card3.frame.minX, card4.frame.minX)
            XCTAssertEqual(card1.frame.minY, card4.frame.minY, accuracy: 8)
        }

        let deviceTag = isPhone ? "iphone" : "ipad"
        capture("t3-\(deviceTag)-overview-light")

        XCUIDevice.shared.appearance = .dark
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        capture("t3-\(deviceTag)-overview-dark")
        XCUIDevice.shared.appearance = .light
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        // Long-press and drag card1 onto card2 to reorder (`t2` moves before `t1`).
        let startDrag = card1.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endDrag = card2.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        startDrag.press(forDuration: 0.85, thenDragTo: endDrag)
        XCTAssertTrue(
            wait(timeout: 5) { card2.frame.minX < card1.frame.minX },
            "Long-press drag should reorder card2 before card1 (card1=\(card1.frame), card2=\(card2.frame))."
        )
        capture("t3-\(deviceTag)-overview-reordered")

        // Close card3 via the top-trailing × button.
        tapCardClose(on: card3)
        XCTAssertTrue(waitForGone(card3, timeout: 5), "Closing card3 with × button should remove it.")
        XCTAssertTrue(wait(timeout: 5) { countLabel.label == "3 tabs" })
        XCTAssertTrue(any(app, "tabClosedToast").waitForExistence(timeout: 5))

        // Close card4 (Home) by swiping sideways.
        card4.swipeLeft()
        XCTAssertTrue(waitForGone(card4, timeout: 5), "Swiping card4 sideways should close it.")
        XCTAssertTrue(wait(timeout: 5) { countLabel.label == "2 tabs" })

        // Tap card2 (Companion Ferry Schedule) to zoom into it; on iPad the Agent panel returns.
        card2.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitForGone(overview, timeout: 5))
        XCTAssertTrue(waitOrDump(companionHeading, timeout: 10, in: app))
        if !usesDrawerLayout(app) {
            XCTAssertTrue(waitOrDump(any(app, "aiPanel"), timeout: 5, in: app), "iPad Agent panel must return on the chosen tab.")
        }
    }

    func testCloseRunningTabSavesToHistoryAndUndoRestoresTabAndStoppedConversation() throws {
        let server = LocalTabsUIFixture()
        try server.start()
        defer { server.stop() }

        let orientation: UIDeviceOrientation = isPhone ? .portrait : .landscapeLeft
        // `run-limit` opens 4 tabs with running Agent sessions in t1, t2, t3 and recorded session in t4.
        let app = launch(
            [
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                "-dc-open", server.guideURL,
                "-dc-browser-agent-demo", "run-limit",
                "-dc-drawer-detent", "medium",
                "-AppleInterfaceStyle", "Light"
            ],
            orientation: orientation
        )

        dismissDemoDrawerIfNeeded(in: app)

        tapTabsButton(in: app)
        let overview = any(app, "tabOverview")
        XCTAssertTrue(waitOrDump(overview, timeout: 10, in: app))

        let runningCard = any(app, "tabOverviewCard-t1")
        XCTAssertTrue(waitOrDump(runningCard, timeout: 5, in: app))
        XCTAssertTrue(
            runningCard.label.contains("Agent working"),
            "Running tab card must announce 'Agent working'; got “\(runningCard.label)”."
        )
        let deviceTag = isPhone ? "iphone" : "ipad"
        capture("t3-\(deviceTag)-agent-working-card")

        // Close running Tab 1: run stops, conversation saves to History, and 5s Undo toast appears.
        tapCardClose(on: runningCard)
        XCTAssertTrue(waitForGone(runningCard, timeout: 5))

        let toast = any(app, "tabClosedToast")
        let undoButton = app.buttons["tabClosedUndoButton"].firstMatch
        XCTAssertTrue(waitOrDump(toast, timeout: 5, in: app), "Closing a tab must show the Undo toast.")
        XCTAssertTrue(
            app.staticTexts["Tab closed. Its conversation is in History."].exists
                || toast.label.contains("Tab closed. Its conversation is in History."),
            "Toast must read 'Tab closed. Its conversation is in History.'"
        )
        capture("t3-\(deviceTag)-tab-closed-toast")

        // Tap Undo: Tab 1 returns with its conversation, and the run stays stopped ("Stopped").
        XCTAssertTrue(undoButton.exists)
        undoButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitOrDump(runningCard, timeout: 5, in: app), "Undo must restore Tab 1.")
        XCTAssertFalse(
            runningCard.label.contains("Agent working"),
            "Undo must NOT resume the stopped run; got “\(runningCard.label)”."
        )

        // Open restored Tab 1 and inspect its conversation in the Agent panel.
        runningCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitForGone(overview, timeout: 5))
        showAssistant(in: app)

        let userPrompt = any(app, "agentUserMessage")
        let stoppedNotice = any(app, "agentRunStoppedNotice")
        XCTAssertTrue(waitOrDump(userPrompt, timeout: 10, in: app), "Undo must restore Tab 1's conversation prompt.")
        XCTAssertTrue(waitOrDump(stoppedNotice, timeout: 5, in: app), "Last turn of a run stopped by closing must read 'Stopped'.")
        XCTAssertEqual(stoppedNotice.label, "Stopped")
        XCTAssertFalse(app.buttons["agentStopButton"].exists, "Stopped run must remain stopped after Undo.")
        capture("t3-\(deviceTag)-undo-restored-stopped-turn")

        // Close Tab 2 without Undo and verify its conversation appears in History.
        if usesDrawerLayout(app) {
            closeDrawer(in: app)
        }
        tapTabsButton(in: app)
        XCTAssertTrue(waitOrDump(overview, timeout: 10, in: app))
        let card2 = any(app, "tabOverviewCard-t2")
        XCTAssertTrue(waitOrDump(card2, timeout: 5, in: app))
        tapCardClose(on: card2)
        XCTAssertTrue(waitForGone(card2, timeout: 5))

        let doneButton = app.buttons["tabOverviewDone"].firstMatch
        doneButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitForGone(overview, timeout: 5))

        showAssistant(in: app)
        let moreMenu = app.buttons["assistantMoreMenu"].firstMatch
        if moreMenu.waitForExistence(timeout: 5) {
            moreMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let historyItem = app.buttons["History"].firstMatch
            if historyItem.waitForExistence(timeout: 5) {
                historyItem.tap()
                XCTAssertTrue(
                    wait(timeout: 10) {
                        self.any(app, "agentRunRow").exists || app.staticTexts["Inspect tab 2"].exists
                    },
                    "Closed tab's conversation must appear in History."
                )
            }
        }
    }

    func testVoiceOverActionsLongPressMenuThirtyTabLimitAndKeyboardShortcuts() throws {
        let server = LocalTabsUIFixture()
        try server.start()
        defer { server.stop() }

        let orientation: UIDeviceOrientation = isPhone ? .portrait : .landscapeLeft
        let app = launch(
            [
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                "-dc-tab-ax-debug",
                "-dc-open", server.guideURL,
                "-dc-browser-agent-demo", "empty",
                "-AppleInterfaceStyle", "Light"
            ],
            orientation: orientation
        )

        let guideHeading = app.webViews.staticTexts["Harbor Ferry Field Guide"].firstMatch
        XCTAssertTrue(waitOrDump(guideHeading, timeout: 15, in: app))
        dismissDemoDrawerIfNeeded(in: app)

        // Open Tab 2 (/companion) and Tab 3 (/popup-tariff).
        let blankLink = app.webViews.links["Open Companion Schedule in New Tab"].firstMatch
        XCTAssertTrue(waitForHittable(blankLink, timeout: 10))
        blankLink.tap()
        let companionHeading = app.webViews.staticTexts["Companion Ferry Schedule"].firstMatch
        XCTAssertTrue(waitOrDump(companionHeading, timeout: 15, in: app))

        let popupButton = app.webViews
            .descendants(matching: .any)
            .matching(label(contains: "Open Tariff Reference Window"))
            .firstMatch
        XCTAssertTrue(waitOrDump(popupButton, timeout: 10, in: app))
        popupButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitOrDump(app.webViews.staticTexts["Summer Tariff Reference"].firstMatch, timeout: 15, in: app))

        if usesDrawerLayout(app) {
            closeDrawer(in: app)
        }

        // 1. VoiceOver custom actions: Move later, Move earlier, and Close on the live UIAccessibility elements.
        tapTabsButton(in: app)
        let overview = any(app, "tabOverview")
        XCTAssertTrue(waitOrDump(overview, timeout: 10, in: app))

        let card1 = any(app, "tabOverviewCard-t1")
        let card2 = any(app, "tabOverviewCard-t2")
        let card3 = any(app, "tabOverviewCard-t3")
        XCTAssertTrue(card1.exists && card2.exists && card3.exists)
        XCTAssertLessThan(card1.frame.minX, card2.frame.minX)

        any(app, "tabAXInvoke-t1-later").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(wait(timeout: 5) { card2.frame.minX < card1.frame.minX }, "VoiceOver Move later must move t1 after t2.")

        any(app, "tabAXInvoke-t1-earlier").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(wait(timeout: 5) { card1.frame.minX < card2.frame.minX }, "VoiceOver Move earlier must move t1 back before t2.")

        any(app, "tabAXInvoke-t3-close").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitForGone(card3, timeout: 5), "VoiceOver Close action must close t3.")

        app.buttons["tabOverviewDone"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitForGone(overview, timeout: 5))

        // 2. Long-press native Menu on the bar's Tabs button: New Tab, Close This Tab, and open tab list.
        longPressTabsButton(in: app)
        XCTAssertTrue(app.buttons["New Tab"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Close This Tab"].exists)
        let guideMenuAction = app.buttons.matching(label(contains: "Harbor Ferry Field Guide")).firstMatch
        XCTAssertTrue(waitOrDump(guideMenuAction, timeout: 5, in: app))
        let deviceTag = isPhone ? "iphone" : "ipad"
        capture("t3-\(deviceTag)-tabs-long-press-menu")
        guideMenuAction.tap()
        XCTAssertTrue(waitOrDump(guideHeading, timeout: 10, in: app), "Choosing a tab from the long-press menu must switch to it.")

        // 3. On iPad, test ⌘T, ⌃Tab, ⌃⇧Tab, and ⌘W.
        if !isPhone {
            _ = waitForGone(app.buttons["New Tab"].firstMatch, timeout: 5)
            app.typeKey(.tab, modifierFlags: .control)
            if !companionHeading.waitForExistence(timeout: 3) {
                app.typeKey(.tab, modifierFlags: .control)
            }
            XCTAssertTrue(waitOrDump(companionHeading, timeout: 10, in: app), "⌃Tab must switch to the next tab.")

            app.typeKey(.tab, modifierFlags: [.control, .shift])
            if !guideHeading.waitForExistence(timeout: 3) {
                app.typeKey(.tab, modifierFlags: [.control, .shift])
            }
            XCTAssertTrue(waitOrDump(guideHeading, timeout: 10, in: app), "⌃⇧Tab must switch to the previous tab.")

            app.typeKey("t", modifierFlags: .command)
            XCTAssertTrue(
                wait(timeout: 5) { !guideHeading.exists },
                "⌘T must open a new Home tab in front."
            )

            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(
                waitOrDump(any(app, "tabClosedToast"), timeout: 5, in: app),
                "⌘W must close the current tab with Undo."
            )
        }
        app.terminate()

        // 4. 30-tab limit + Accessibility Dynamic Type grid (1 column on iPhone, 2 columns on iPad).
        let ax3 = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
        let limitApp = launch(
            [
                "-UIPreferredContentSizeCategoryName", ax3,
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                "-dc-seed-open-tabs", "30",
                "-AppleInterfaceStyle", "Light"
            ],
            orientation: orientation
        )
        tapTabsButton(in: limitApp)
        let limitOverview = any(limitApp, "tabOverview")
        XCTAssertTrue(waitOrDump(limitOverview, timeout: 10, in: limitApp))
        XCTAssertFalse(limitApp.buttons["tabOverviewNewTab"].firstMatch.isEnabled, "New tab must be disabled at 30 tabs.")
        let limitNotice = any(limitApp, "tabOverviewLimitNotice")
        XCTAssertTrue(waitOrDump(limitNotice, timeout: 5, in: limitApp))
        XCTAssertEqual(limitNotice.label, "30 tabs open. Close one to open another")

        let axCard1 = any(limitApp, "tabOverviewCard-t1")
        let axCard2 = any(limitApp, "tabOverviewCard-t2")
        if axCard1.exists && axCard2.exists {
            if isPhone {
                // 1 column at accessibility Dynamic Type on iPhone: card2 sits below card1, not beside it.
                XCTAssertEqual(axCard1.frame.minX, axCard2.frame.minX, accuracy: 8)
                XCTAssertGreaterThan(axCard2.frame.minY, axCard1.frame.maxY - 8)
            } else {
                // 2 columns at accessibility Dynamic Type on iPad.
                let axCard3 = any(limitApp, "tabOverviewCard-t3")
                XCTAssertLessThan(axCard1.frame.minX, axCard2.frame.minX)
                if axCard3.exists {
                    XCTAssertEqual(axCard1.frame.minX, axCard3.frame.minX, accuracy: 8)
                }
            }
        }
        capture("t3-\(deviceTag)-30-limit-ax-grid")
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
