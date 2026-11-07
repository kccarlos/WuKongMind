import XCTest

/// Settings is a grouped root list; every row pushes its own page.
final class SettingsNavigationUITests: DCUITestCase {
    /// Root row identifier suffix → the pushed page's navigation title.
    private let pages: [(row: String, title: String)] = [
        ("provider", "AI models"),
        ("voice", "Voice"),
        ("summaries", "Summaries & chat"),
        ("agent", "Ask the forum"),
        ("browser", "Browser"),
        ("digest", "Daily digest & podcast"),
        ("watched", "Watched topics"),
        ("forums", "Forums"),
        ("sync", "iCloud Sync"),
        ("data", "Data & privacy"),
        ("help", "Help & about")
    ]

    func testEachRootRowOpensItsPageAndBackReturns() throws {
        // `-dc-panel-settings` opens Settings (a sheet in every layout) once
        // the page is up.
        let app = launch(["-dc-sample", "-dc-panel-settings"])

        let root = any(app, "settingsRoot")
        XCTAssertTrue(root.waitForExistence(timeout: 20), "Settings did not open.")
        XCTAssertTrue(waitOrDump(app.navigationBars["Settings"], timeout: 5, in: app))

        for page in pages {
            let row = app.buttons["settingsRow-\(page.row)"]
            XCTAssertTrue(revealRow(row, in: app), "Root row \(page.row) is missing.")
            row.tap()
            XCTAssertTrue(
                app.navigationBars[page.title].waitForExistence(timeout: 10),
                "Row \(page.row) did not open “\(page.title)”."
            )
            assertPageContent(page.row, in: app)
            // A back tap during the push animation can be dropped; retry.
            for _ in 0..<3 where app.navigationBars[page.title].exists {
                tapNavigationBack(in: app)
                _ = waitForGone(app.navigationBars[page.title], timeout: 3)
            }
            XCTAssertTrue(
                app.navigationBars["Settings"].waitForExistence(timeout: 10),
                "Back from “\(page.title)” did not return to the Settings root."
            )
            XCTAssertTrue(waitForGone(app.navigationBars[page.title], timeout: 5))
        }

        // The Help section's share guide pushes and pops too.
        let sharing = app.buttons["settingsRow-sharing"]
        XCTAssertTrue(reveal(sharing, in: app))
        sharing.tap()
        XCTAssertTrue(app.navigationBars["Share from Safari or Chrome"].waitForExistence(timeout: 10))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        // Done: back to the page and the AI view.
        closeSettings(in: app)
        XCTAssertTrue(waitForGone(root, timeout: 10))
        // iPhone: the drawer's Ask box; iPad: the panel's.
        XCTAssertTrue(
            any(app, "askScopeButton")
                .waitForExistence(timeout: 10),
            "Closing Settings did not return to the assistant."
        )
    }

    func testStandaloneSettingsOpensEveryPage() throws {
        // `-dc-show-settings root` presents Settings full screen (no assistant).
        let app = launch(["-dc-sample", "-dc-show-settings", "root"])

        XCTAssertTrue(any(app, "settingsRoot").waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["backToTopic"].exists)
        for page in pages {
            let row = app.buttons["settingsRow-\(page.row)"]
            XCTAssertTrue(revealRow(row, in: app), "Root row \(page.row) is missing.")
            row.tap()
            XCTAssertTrue(app.navigationBars[page.title].waitForExistence(timeout: 10))
            tapNavigationBack(in: app)
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        }
    }

    func testSyncPageShowsStatusTogglesAndDelete() throws {
        // `-dc-sync-status` fakes the displayed status (screenshots/tests only).
        let app = launch(["-dc-sample", "-dc-show-settings", "sync", "-dc-sync-status", "upToDate"])

        XCTAssertTrue(app.navigationBars["iCloud Sync"].waitForExistence(timeout: 20))
        let status = any(app, "syncStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Up to date"), "Got “\(status.label)”.")
        XCTAssertEqual(app.switches["syncEnabled"].value as? String, "1", "Sync with iCloud is on.")
        XCTAssertTrue(app.buttons["syncNow"].exists)
        let toggle = app.switches["syncAPIKeys"]
        XCTAssertTrue(reveal(toggle, in: app))
        XCTAssertEqual(toggle.value as? String, "1", "Sync API keys is on by default.")
        let delete = app.buttons["syncDeleteCloudData"]
        XCTAssertTrue(reveal(delete, in: app, swipes: 4))
        delete.tap()
        // Confirmation first; cancel deletes nothing.
        XCTAssertTrue(
            app.staticTexts["Delete iCloud data?"].waitForExistence(timeout: 5),
            "Delete iCloud data asks for confirmation."
        )
        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap() } else { app.tap() }
        XCTAssertTrue(waitForGone(app.staticTexts["Delete iCloud data?"], timeout: 5))
    }

    /// Data & privacy › Safety: Blocked users and Filtered words are pages of their own.
    func testDataPageSafetyRowsOpenTheirPages() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "data"])

        XCTAssertTrue(app.navigationBars["Data & privacy"].waitForExistence(timeout: 20))
        let blocked = app.buttons["blockedUsersRow"]
        XCTAssertTrue(reveal(blocked, in: app, swipes: 6), "Safety has no Blocked users row.")
        blocked.tap()
        XCTAssertTrue(app.navigationBars["Blocked users"].waitForExistence(timeout: 10))
        tapNavigationBack(in: app)

        let words = app.buttons["filteredWordsRow"]
        XCTAssertTrue(reveal(words, in: app, swipes: 6), "Safety has no Filtered words row.")
        words.tap()
        XCTAssertTrue(app.navigationBars["Filtered words"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "filteredWordField").waitForExistence(timeout: 5))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Data & privacy"].waitForExistence(timeout: 10))
    }

    func testSyncPageShowsAccountFix() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "sync", "-dc-sync-status", "noAccount"])

        XCTAssertTrue(app.navigationBars["iCloud Sync"].waitForExistence(timeout: 20))
        let status = any(app, "syncStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Sign in to iCloud"), "Got “\(status.label)”.")
        XCTAssertFalse(app.buttons["syncStatusAction"].exists, "Nothing to retry without an account.")
    }

    /// Settings › AI models lists both roles with their own models (here set
    /// apart with `-dc-agent-model`) and opens a role's model picker.
    func testAIModelsPageShowsBothRolesAndOpensARolesPicker() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "provider", "-dc-agent-model", "deepseek:deepseek-v4-flash"])

        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 20))
        let assistant = any(app, "modelRole-assistant")
        let agent = any(app, "modelRole-agent")
        XCTAssertTrue(assistant.waitForExistence(timeout: 5))
        XCTAssertTrue(assistant.label.contains("claude-sonnet-4-5"), "Got “\(assistant.label)”.")
        XCTAssertTrue(agent.label.contains("deepseek-v4-flash"), "Got “\(agent.label)”.")
        XCTAssertTrue(any(app, "useSameModel-agent").exists, "Different models offer “Use deepseek-v4-flash for both”.")
        XCTAssertTrue(any(app, "useSameModel-assistant").exists)
        // Favorites with their state; both roles' models are starred.
        XCTAssertTrue(any(app, "favoriteModel-anthropic:claude-sonnet-4-5").exists)
        XCTAssertFalse(any(app, "starCurrentModel-assistant").exists, "The current model is starred already.")

        capture("ai-models")

        agent.tap()
        XCTAssertTrue(app.navigationBars["Ask the forum"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "providerPicker").waitForExistence(timeout: 5))
        capture("ai-models-agent-picker")
        XCTAssertTrue(reveal(app.buttons["testAndSaveProvider"], in: app, swipes: 4))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 10))
    }

    func testAIModelsRowsStayReadableAtAccessibilitySize() throws {
        let ax5 = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
        let app = launch(["-UIPreferredContentSizeCategoryName", ax5, "-dc-sample", "-dc-forums-home", "-dc-show-settings", "provider"])
        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 20))
        let assistant = any(app, "modelRole-assistant")
        let agent = any(app, "modelRole-agent")
        XCTAssertTrue(assistant.waitForExistence(timeout: 5))
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        capture("ax5_phone_settings-provider")
        XCTAssertLessThan(assistant.frame.height, 340, "Summaries & chat row collapsed into a narrow multi-screen column at AX5.")
        XCTAssertLessThanOrEqual(agent.frame.maxY, app.windows.firstMatch.frame.maxY, "Both model role rows should fit on screen at AX5.")
    }

    func testProviderSettingsTestAndSaveButtonKeepsFullRowHeight() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-show-settings", "provider"])
        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 20))

        let openRouter = app.buttons["providerRow-openrouter"]
        XCTAssertTrue(reveal(openRouter, in: app))
        openRouter.tap()
        let testButton = app.buttons["testProvider"]
        XCTAssertTrue(testButton.waitForExistence(timeout: 5))
        capture("base_phone_provider-openrouter")
        XCTAssertGreaterThanOrEqual(testButton.frame.height, 50, "Test & Save button height was clipped below standard Form row height.")
        testButton.tap()
        let failure = any(app, "providerTestFailure")
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(testButton.frame.height, 50, "Test & Save button must keep its full 52pt row height when test status is shown.")
    }

    func testSettingsReadingLanguageSyncErrorReportAndSavedAPIKeyLayout() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-show-settings", "root"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        let readingLanguage = any(app, "settingsRow-readingLanguage")
        XCTAssertTrue(reveal(readingLanguage, in: app))
        capture("base_phone_settings-root")
        XCTAssertLessThanOrEqual(readingLanguage.frame.height, 56, "Reading language row wrapped onto a second indented line at standard Dynamic Type.")

        let providerRow = app.buttons["settingsRow-provider"]
        XCTAssertTrue(reveal(providerRow, in: app, swipes: 3))
        providerRow.tap()
        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 10))
        let anthropic = app.buttons["providerRow-anthropic"]
        XCTAssertTrue(reveal(anthropic, in: app))
        anthropic.tap()
        let pasteButton = app.buttons["pasteAPIKey"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 5))
        capture("base_phone_provider-anthropic")
        let maskedBullets = any(app, "apiKeyMaskedBullets")
        XCTAssertTrue(maskedBullets.exists, "Saved API key row should show masked bullets instead of a blank space.")
        XCTAssertLessThanOrEqual(maskedBullets.frame.maxX, pasteButton.frame.minX)

        let syncApp = launch(["-dc-sample", "-dc-forums-home", "-dc-sync-status", "error", "-dc-show-settings", "sync"])
        XCTAssertTrue(syncApp.navigationBars["iCloud Sync"].waitForExistence(timeout: 20))
        capture("base_phone_sync-error")
        let syncNowButtons = syncApp.buttons.matching(NSPredicate(format: "label == 'Sync now'"))
        XCTAssertEqual(syncNowButtons.count, 1, "iCloud Sync error state should not show two duplicate Sync now buttons.")

        let reportApp = launch(["-dc-sample", "-dc-drawer-first-run"])
        let menu = reportApp.buttons["forumSwitcher"]
        XCTAssertTrue(waitForBarItem(menu, timeout: 20))
        let reportItem = reportApp.buttons["Report or block…"]
        let reportPost = reportApp.buttons["reportPost1"]
        let blockPost = reportApp.buttons["blockPost1"]
        let blockUser = reportApp.buttons["blockUser1"]
        for _ in 0..<4 where !reportPost.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            _ = wait(timeout: 15) {
                tapBarItem(menu)
                if reportItem.waitForExistence(timeout: 3) { return true }
                dismissMenu(in: reportApp)
                return false
            }
            reportItem.tap()
            if reportPost.waitForExistence(timeout: 6) { break }
            if reportApp.buttons["Done"].firstMatch.exists {
                reportApp.buttons["Done"].firstMatch.tap()
            }
        }
        XCTAssertTrue(reportPost.waitForExistence(timeout: 10))
        XCTAssertTrue(blockPost.exists)
        XCTAssertTrue(blockUser.exists)
        capture("base_phone_report-block-sheet")
        XCTAssertLessThanOrEqual(abs(blockPost.frame.height - reportPost.frame.height), 4, "Block post button wrapped to two lines while Report post stayed on one.")
        XCTAssertLessThanOrEqual(abs(blockUser.frame.height - reportPost.frame.height), 4, "Block user button wrapped to two lines while Report post stayed on one.")
        XCTAssertLessThanOrEqual(abs(blockPost.frame.minY - reportPost.frame.minY), 4, "Post action buttons should sit on one line at standard Dynamic Type.")

        let zhApp = launch(["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_Hans", "-dc-sample", "-dc-forums-home", "-dc-show-settings", "root"])
        XCTAssertTrue(any(zhApp, "settingsRow-readingLanguage").waitForExistence(timeout: 20))
        _ = reveal(any(zhApp, "settingsRow-readingLanguage"), in: zhApp)
        capture("zh_phone_settings-root")

        let addForumApp = launch(["-dc-sample", "-dc-forums-home", "-dc-add-forum"])
        XCTAssertTrue(addForumApp.textFields["addForumAddress"].waitForExistence(timeout: 20))
        capture("base_phone_addforum")

        let translateApp = launch(["-dc-sample", "-dc-test-present", "translate-posts", "-dc-test-present-after", "2"])
        XCTAssertTrue(translateApp.navigationBars["Translate posts"].waitForExistence(timeout: 20))
        capture("base_phone_present-translate-posts")

        let summaryApp = launch(["-dc-sample", "-dc-drawer-detent", "large"])
        XCTAssertTrue(any(summaryApp, "summaryContent").waitForExistence(timeout: 20))
        capture("base_phone_summary-meta-kept")

        let darkHistApp = launch(["-AppleInterfaceStyle", "Dark", "-dc-sample", "-dc-forums-home"])
        let homeHistory = darkHistApp.buttons["homeHistory"]
        XCTAssertTrue(homeHistory.waitForExistence(timeout: 20))
        homeHistory.tap()
        XCTAssertTrue(darkHistApp.navigationBars["History"].waitForExistence(timeout: 10))
        capture("dark_phone_hist-all")
    }

    /// The Assistant's model switcher names the current mode's role: Chat
    /// (and Summary) switch the summaries & chat model, Ask the forum its own.
    func testAssistantModelSwitcherFollowsTheMode() throws {
        try skipUnlessPhone("The Assistant header layout checked here is the iPhone one.")
        // The drawer's model pill shows the mode's model and lists the favorites.
        for (mode, model) in [("chat", "claude-sonnet-4-5"), ("agent", "deepseek-v4-flash")] {
            let app = launch(["-dc-sample", "-dc-topic", "openai", "-dc-assistant-mode", mode,
                              "-dc-agent-model", "deepseek:deepseek-v4-flash"])
            let pill = app.buttons["modelPill"]
            XCTAssertTrue(pill.waitForExistence(timeout: 20), "The drawer did not open in \(mode).")
            XCTAssertTrue(pill.label.contains(model), "Got “\(pill.label)” in \(mode).")
            pill.tap()
            // A favorite reads "Provider, model · Ready" (menu toggles drop
            // their identifiers).
            let current = menuOption(model, in: app)
            XCTAssertTrue(current.waitForExistence(timeout: 5), "The \(mode) switcher doesn't list \(model).")
            // The menu names its role (ModelMenu / ModelForum).
            let title = mode == "agent" ? "ASK THE FORUM" : "SUMMARIES & CHAT"
            XCTAssertTrue(app.staticTexts[title].exists, "No “\(title)” header in \(mode).")
            XCTAssertTrue(any(app, "modelUseForBoth").exists, "The roles differ: “Use X for both”.")
            capture("model-switcher-\(mode)")
            app.terminate()
        }
    }

    /// §6: picking a favorite from the drawer's pill switches the scope's
    /// model, and the pill's label follows.
    func testModelPillSwitchesTheModel() throws {
        try skipUnlessPhone("The model pill is in the iPhone drawer's header.")
        let app = launch(["-dc-sample", "-dc-topic", "openai", "-dc-assistant-mode", "chat",
                          "-dc-agent-model", "deepseek:deepseek-v4-flash"])
        let pill = app.buttons["modelPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 20), "The drawer did not open.")
        XCTAssertTrue(pill.label.contains("claude-sonnet-4-5"), "Got “\(pill.label)”.")
        pill.tap()
        let option = menuOption("deepseek-v4-flash", in: app)
        XCTAssertTrue(waitOrDump(option, timeout: 5, in: app), "The menu doesn't list the other favorite.")
        option.tap()
        let switched = NSPredicate(format: "label CONTAINS %@", "deepseek-v4-flash")
        expectation(for: switched, evaluatedWith: pill)
        waitForExpectations(timeout: 5)
        // Only This topic's model changed: the roles now share it.
        pill.tap()
        XCTAssertTrue(menuOption("claude-sonnet-4-5", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(any(app, "modelUseForBoth").exists, "Both roles use deepseek-v4-flash now.")
        // AI models… opens Settings › AI models over the drawer (router).
        app.buttons["modelMenuSettings"].tap()
        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 10), "AI models… did not open Settings › AI models.")
    }

    func testFavoriteActionsPresentAsSheet() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "provider",
                          "-dc-agent-model", "deepseek:deepseek-v4-flash"])
        let favorite = any(app, "favoriteModel-anthropic:claude-sonnet-4-5")
        XCTAssertTrue(reveal(favorite, in: app))
        favorite.tap()
        let sheet = any(app, "favoriteModelActionsSheet")
        XCTAssertTrue(waitOrDump(sheet, timeout: 5, in: app), "Favorite actions must use a sheet")
        XCTAssertTrue(app.buttons["Use for Summaries & chat"].exists)
        XCTAssertTrue(app.buttons["Use for Ask the forum"].exists)
        XCTAssertTrue(app.buttons["Use for both"].exists)
        XCTAssertTrue(app.buttons["Remove from favorites"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "favorite-model-actions-sheet"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["favoriteModelActionsDone"].tap()
        XCTAssertTrue(waitForGone(sheet, timeout: 5))
        XCTAssertTrue(favorite.exists)
    }

    /// Settings › AI models favorites (ModelSettings): tap = pick the role,
    /// hold = use for both, swipe = remove.
    func testFavoritesTapHoldAndSwipe() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "provider", "-dc-agent-model", "deepseek:deepseek-v4-flash"])
        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 20))
        let agent = any(app, "modelRole-agent")
        let assistant = any(app, "modelRole-assistant")
        XCTAssertTrue(agent.waitForExistence(timeout: 5))

        // Tap: the role choice; Ask the forum takes claude-sonnet-4-5.
        let claude = any(app, "favoriteModel-anthropic:claude-sonnet-4-5")
        XCTAssertTrue(reveal(claude, in: app))
        claude.tap()
        let useForAgent = app.buttons["Use for Ask the forum"]
        XCTAssertTrue(waitOrDump(useForAgent, timeout: 5, in: app), "Tapping a favorite offers its roles.")
        useForAgent.tap()
        XCTAssertTrue(wait(timeout: 5) { agent.label.contains("claude-sonnet-4-5") }, "Got “\(agent.label)”.")

        // Hold: both roles take deepseek-v4-flash.
        let deepseek = any(app, "favoriteModel-deepseek:deepseek-v4-flash")
        XCTAssertTrue(reveal(deepseek, in: app))
        deepseek.press(forDuration: 1.2)
        XCTAssertTrue(wait(timeout: 5) {
            agent.label.contains("deepseek-v4-flash") && assistant.label.contains("deepseek-v4-flash")
        }, "Holding a favorite uses it for both; got “\(assistant.label)” and “\(agent.label)”.")
        XCTAssertFalse(app.buttons["Use for Ask the forum"].exists, "Holding doesn't open the role choice.")

        // Swipe left: remove. The roles keep their model, so it can be starred again.
        deepseek.swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(waitForGone(deepseek, timeout: 5))
        XCTAssertTrue(any(app, "starCurrentModel-assistant").waitForExistence(timeout: 5), "Star deepseek-v4-flash is offered.")
    }

    /// A favorite in the model menu: "Provider, model · state".
    private func menuOption(_ model: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", \(model) · ")).firstMatch
    }

    /// Only the role that can't run shows the setup card: here Ask the
    /// forum's provider has no key while chat works.
    func testSetupCardShowsOnlyForTheRoleThatIsNotReady() throws {
        let args = ["-dc-sample", "-dc-topic", "openai",
                    "-dc-agent-model", "deepseek:deepseek-v4-flash", "-dc-no-agent-key"]
        var app = launch(args + ["-dc-assistant-mode", "agent"])
        let card = any(app, "providerSetupCard")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Ask the forum should ask for its model.")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "deepseek-v4-flash isn’t ready")).firstMatch.exists,
            "The card names the model that isn't ready."
        )
        XCTAssertTrue(app.buttons["providerSetupButton"].label.contains("Key"), "Got “\(app.buttons["providerSetupButton"].label)”.")
        // Never a dead end: the ready favorite is offered (ModelSetup).
        XCTAssertTrue(any(app, "readyModel-anthropic:claude-sonnet-4-5").exists)
        capture("setup-card-agent")
        app.terminate()

        app = launch(args + ["-dc-assistant-mode", "chat"])
        XCTAssertTrue(app.buttons["assistantMoreMenu"].waitForExistence(timeout: 20))
        XCTAssertFalse(any(app, "providerSetupCard").exists, "Chat's model is ready.")
    }

    /// Home › Settings (a sheet) › Help & about › Show onboarding again: the
    /// sheet goes and the walkthrough covers the screen (audit A6).
    func testShowOnboardingAgainFromTheSettingsSheet() throws {
        let app = launch(["-dc-sample", "-dc-forums-home"], orientation: isPhone ? .portrait : .landscapeLeft)
        openHome(in: app)
        let settings = app.buttons["homeSettings"]
        XCTAssertTrue(waitForHittable(settings, timeout: 10))
        settings.tap()
        XCTAssertTrue(any(app, "settingsRoot").waitForExistence(timeout: 10), "Settings did not open from Home.")
        let help = app.buttons["settingsRow-help"]
        XCTAssertTrue(reveal(help, in: app))
        help.tap()
        let replay = any(app, "replayOnboarding")
        let bar = app.navigationBars["Help & about"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        // Step toward the row with short drags that stop without momentum: a swipe flings
        // past it in the short landscape sheet, and it must end clear of the navigation bar.
        let origin = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
        for _ in 0..<10 where !(replay.exists && replay.isHittable && replay.frame.minY >= bar.frame.maxY + 24) {
            let up = !replay.exists || replay.frame.minY >= bar.frame.maxY + 24
            let start = origin.withOffset(CGVector(dx: 0, dy: up ? 300 : 120))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: up ? -160 : 90)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(waitForHittable(replay))
        replay.tap()
        XCTAssertTrue(waitOrDump(any(app, "onboarding"), timeout: 10, in: app), "The walkthrough did not show.")
        XCTAssertFalse(any(app, "replayOnboarding").isHittable, "Settings stayed over the walkthrough.")
    }

    /// §15 item 5: controls that were under 44 pt (audit): the walkthrough's
    /// "Skip for now" and Settings › Forums' Pin.
    func testSmallControlsAreAtLeast44PointsToTap() throws {
        var app = launch(["-dc-onboarding-step", "provider"])
        let skip = app.buttons["onboardingSkipStep"]
        XCTAssertTrue(skip.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(skip.frame.height, 44, "Skip for now")
        app.terminate()

        // The sample's third forum is not pinned.
        app = launch(["-dc-sample", "-dc-forums-home", "-dc-show-settings", "forums", "-dc-test-present"])
        let pin = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pin '")).firstMatch
        XCTAssertTrue(reveal(pin, in: app, swipes: 4), "No Pin button in Settings › Forums.")
        XCTAssertGreaterThanOrEqual(pin.frame.height, 44, "Pin")
        XCTAssertGreaterThanOrEqual(pin.frame.width, 44, "Pin")
    }

    func testWatchedRowOpensTopicPodcastRequiresDigestAndBlockedUsersMentionsForumMenu() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "root", "-dc-test-present"])
        XCTAssertTrue(any(app, "settingsRoot").waitForExistence(timeout: 15))

        // 1. Daily digest & podcast: turning off Make a digest every day disables Make the podcast every day.
        let digestRow = app.buttons["settingsRow-digest"]
        XCTAssertTrue(revealRow(digestRow, in: app))
        digestRow.tap()
        let digestSwitch = app.switches["digestEnabled"]
        XCTAssertTrue(digestSwitch.waitForExistence(timeout: 8))
        let podcastSwitch = app.switches["podcastDailyEnabled"]
        XCTAssertTrue(reveal(podcastSwitch, in: app, swipes: 4))
        if (podcastSwitch.value as? String) != "1" {
            podcastSwitch.switches.firstMatch.tap()
        }
        if (digestSwitch.value as? String) == "1" {
            digestSwitch.switches.firstMatch.tap()
        }
        XCTAssertFalse(podcastSwitch.isEnabled, "Make the podcast every day must be disabled when Make a digest every day is off")
        XCTAssertEqual(podcastSwitch.value as? String, "0")
        tapNavigationBack(in: app)

        // 2. Data & privacy › Blocked users mentions the forum menu as well as ⋯.
        let dataRow = app.buttons["settingsRow-data"]
        XCTAssertTrue(revealRow(dataRow, in: app))
        dataRow.tap()
        let blockedRow = app.buttons["blockedUsersRow"]
        XCTAssertTrue(reveal(blockedRow, in: app, swipes: 6))
        blockedRow.tap()
        let copy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'the forum menu or ⋯'")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        tapNavigationBack(in: app)
        tapNavigationBack(in: app)

        // 3. Watched topics: tapping a watched topic row dismisses Settings to open the topic.
        let watchedRow = app.buttons["settingsRow-watched"]
        XCTAssertTrue(revealRow(watchedRow, in: app))
        watchedRow.tap()
        let firstWatched = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settingsWatchedRow-'")).firstMatch
        XCTAssertTrue(reveal(firstWatched, in: app, swipes: 4))
        firstWatched.tap()
        XCTAssertTrue(waitForGone(any(app, "settingsRoot"), timeout: 8), "Tapping a watched topic row must dismiss Settings.")
    }

    func testUnsupportedAppleIntelligenceMenuAndGoogleVoicesMissingKeySetup() throws {
        // 1. Unsupported device: provider menu shows Apple Intelligence as "Not supported on this device" and disabled.
        var app = launch(["-dc-sample", "-dc-show-settings", "provider", "-dc-apple-intelligence", "unsupported"])
        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 20))
        let assistantRow = any(app, "modelRole-assistant")
        XCTAssertTrue(assistantRow.waitForExistence(timeout: 5))
        assistantRow.tap()
        XCTAssertTrue(app.navigationBars["Summaries & chat"].waitForExistence(timeout: 10))
        let picker = app.buttons["providerPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()

        let appleOption = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Apple Intelligence")).firstMatch
        XCTAssertTrue(waitOrDump(appleOption, timeout: 5, in: app), "Apple Intelligence should remain visible in the provider menu.")
        XCTAssertTrue(appleOption.label.contains("Not supported on this device"), "Got “\(appleOption.label)”.")
        XCTAssertFalse(appleOption.isEnabled, "Apple Intelligence must not be selectable on an unsupported device.")
        app.terminate()

        // 2. Google voices without a Google key: Settings › Daily digest & podcast offers key setup.
        app = launch(["-dc-sample", "-dc-no-provider", "-dc-show-settings", "digest", "-dc-test-present"])
        XCTAssertTrue(app.navigationBars["Daily digest & podcast"].waitForExistence(timeout: 20))
        let voicesPicker = any(app, "podcastEngine")
        XCTAssertTrue(reveal(voicesPicker, in: app, swipes: 4))
        let voicesMenuButton = voicesPicker.buttons.firstMatch
        (voicesMenuButton.exists ? voicesMenuButton : voicesPicker).tap()
        let googleVoices = app.buttons["Google voices"].firstMatch
        XCTAssertTrue(waitOrDump(googleVoices, timeout: 5, in: app))
        googleVoices.tap()

        let addKey = app.buttons["podcastAddGoogleKey"]
        XCTAssertTrue(reveal(addKey, in: app, swipes: 4), "Choosing Google voices with no key should offer key setup.")
        addKey.tap()
        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 10))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Daily digest & podcast"].waitForExistence(timeout: 10))

        // Restore Automatic so persisted state stays clean for other UI tests.
        XCTAssertTrue(reveal(voicesPicker, in: app, swipes: 4))
        (voicesMenuButton.exists ? voicesMenuButton : voicesPicker).tap()
        let automatic = app.buttons["Automatic"].firstMatch
        if automatic.waitForExistence(timeout: 5) { automatic.tap() }
    }

    /// A root row, scrolled into view by dragging the Settings list itself
    /// (on iPad the sheet is smaller than the window, so a swipe across the
    /// app can miss it or overshoot).
    private func revealRow(_ row: XCUIElement, in app: XCUIApplication) -> Bool {
        let list = any(app, "settingsRoot")
        for attempt in 0..<12 {
            // Whole, not cut by the sheet's edge or under its bar.
            if row.waitForExistence(timeout: 1), row.isHittable,
               list.frame.insetBy(dx: 0, dy: 50).contains(CGPoint(x: row.frame.midX, y: row.frame.midY)) { return true }
            guard list.exists else { break }
            let down = attempt >= 6
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.35 : 0.7))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: down ? 160 : -160)))
        }
        return reveal(row, in: app)
    }

    /// A control each page is known for (moved out of the old single form).
    private func assertPageContent(_ row: String, in app: XCUIApplication) {
        let expected: XCUIElement?
        switch row {
        case "provider": expected = any(app, "modelRole-assistant")
        case "sync": expected = any(app, "syncAPIKeys")
        case "summaries": expected = any(app, "summaryBatchLimit")
        case "agent": expected = any(app, "agentMaxSteps")
        case "watched": expected = any(app, "watchAutoRefresh")
        case "browser": expected = app.segmentedControls["browserBarPosition"]
        case "data": expected = any(app, "clearAllData")
        case "help": expected = any(app, "replayOnboarding")
        case "digest": expected = any(app, "podcastDailyEnabled")
        case "voice": expected = any(app, "voiceSessionLimit")
        default: expected = nil
        }
        guard let expected else { return }
        XCTAssertTrue(reveal(expected, in: app, swipes: 4), "The \(row) page is missing its main control.")
        // iPad: the bar position doesn't apply side by side; the footer says so.
        if row == "browser", !isPhone {
            XCTAssertTrue(reveal(any(app, "browserBarSplitNote"), in: app, swipes: 2), "No side-by-side note on iPad.")
        }
    }
}
