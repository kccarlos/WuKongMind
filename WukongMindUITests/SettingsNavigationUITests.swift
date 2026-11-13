import XCTest

/// Settings is grouped by object; every root row pushes its own page, and each
/// setting appears in one place.
final class SettingsNavigationUITests: DCUITestCase {
    /// Root row identifier suffix → the pushed page's navigation title.
    private let pages: [(row: String, title: String)] = [
        ("provider", "Models"),
        ("agent", "Agent"),
        ("scripts", "Scripts & tools"),
        ("sites", "Sites"),
        ("browser", "Browser"),
        ("voice", "Voice"),
        ("digest", "Daily digest & podcast"),
        ("sync", "iCloud Sync"),
        ("data", "Data & privacy"),
        ("help", "Help & about")
    ]

    private func tapSwitch(_ toggle: XCUIElement) {
        let inner = toggle.switches.firstMatch
        if inner.exists && inner.frame.width > 0 {
            inner.tap()
        } else {
            toggle.tap()
        }
    }

    func testEachRootRowOpensItsPageAndBackReturns() throws {
        // `-dc-panel-settings` opens Settings (a sheet in every layout) once
        // the page is up.
        let app = launch(["-dc-sample", "-dc-panel-settings"])

        let root = any(app, "settingsRoot")
        XCTAssertTrue(root.waitForExistence(timeout: 20), "Settings did not open.")
        XCTAssertTrue(waitOrDump(app.navigationBars["Settings"], timeout: 5, in: app))

        // Removed root duplicates and legacy Summaries & chat page must not exist.
        XCTAssertFalse(app.buttons["settingsRow-summaries"].exists)
        XCTAssertFalse(app.buttons["settingsSummary-voice"].exists)
        XCTAssertFalse(app.buttons["settingsRow-forums"].exists)
        XCTAssertFalse(app.buttons["settingsRow-watched"].exists)
        XCTAssertFalse(app.buttons["settingsRow-sharing"].exists)

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

        // Sites sub-pages: Forums and Following push and pop cleanly.
        let sitesRow = app.buttons["settingsRow-sites"]
        XCTAssertTrue(revealRow(sitesRow, in: app))
        sitesRow.tap()
        XCTAssertTrue(app.navigationBars["Sites"].waitForExistence(timeout: 10))
        let forumsRow = app.buttons["settingsRow-forums"]
        XCTAssertTrue(reveal(forumsRow, in: app))
        forumsRow.tap()
        XCTAssertTrue(app.navigationBars["Forums"].waitForExistence(timeout: 10))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Sites"].waitForExistence(timeout: 10))
        let watchedRow = app.buttons["settingsRow-watched"]
        XCTAssertTrue(reveal(watchedRow, in: app))
        watchedRow.tap()
        XCTAssertTrue(app.navigationBars["Following"].waitForExistence(timeout: 10))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Sites"].waitForExistence(timeout: 10))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        // Help & about sub-page: Share from Safari or Chrome and Language live here.
        let helpRow = app.buttons["settingsRow-help"]
        XCTAssertTrue(revealRow(helpRow, in: app))
        helpRow.tap()
        XCTAssertTrue(app.navigationBars["Help & about"].waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(any(app, "settingsRow-language"), in: app))
        let sharing = app.buttons["settingsRow-sharing"]
        XCTAssertTrue(reveal(sharing, in: app))
        sharing.tap()
        XCTAssertTrue(app.navigationBars["Share from Safari or Chrome"].waitForExistence(timeout: 10))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Help & about"].waitForExistence(timeout: 10))
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

    func testSyncPageShowsAccountFix() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "sync", "-dc-sync-status", "noAccount"])

        XCTAssertTrue(app.navigationBars["iCloud Sync"].waitForExistence(timeout: 20))
        let status = any(app, "syncStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Sign in to iCloud"), "Got “\(status.label)”.")
        XCTAssertFalse(app.buttons["syncStatusAction"].exists, "Nothing to retry without an account.")
    }

    /// Settings › Models lists Agent, Summaries, and the M4 Scripts placeholder,
    /// plus summary batching, custom instructions, and answer language.
    func testAIModelsPageShowsBothRolesAndOpensARolesPicker() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "provider", "-dc-agent-model", "deepseek:deepseek-v4-flash"])

        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 20))
        let agent = any(app, "modelRole-browserAgent")
        let assistant = any(app, "modelRole-assistant")
        let scriptsPlaceholder = any(app, "modelRole-scriptsPlaceholder")
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        XCTAssertTrue(assistant.exists)
        XCTAssertTrue(scriptsPlaceholder.exists, "M4 Scripts placeholder row should appear under Default models.")
        XCTAssertFalse(any(app, "modelRole-agent").exists, "Legacy Ask the forum role row must not appear.")
        XCTAssertTrue(agent.label.contains("deepseek-v4-flash"), "Got “\(agent.label)”.")
        XCTAssertTrue(assistant.label.contains("claude-sonnet-4-5"), "Got “\(assistant.label)”.")
        XCTAssertTrue(any(app, "useSameModel-browserAgent").exists, "Different models offer “Use deepseek-v4-flash for both”.")
        XCTAssertTrue(any(app, "useSameModel-assistant").exists)

        // Summaries batching, custom instructions, and answer language live here.
        XCTAssertTrue(reveal(any(app, "summaryBatchLimit"), in: app))
        let instructionsRow = app.buttons["settingsRow-summaryInstructions"]
        XCTAssertTrue(reveal(instructionsRow, in: app))
        instructionsRow.tap()
        XCTAssertTrue(app.navigationBars["Instructions"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "customInstructions").waitForExistence(timeout: 5))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(any(app, "settingsRow-readingLanguage"), in: app))

        // Favorites with their state; both roles' models are starred.
        XCTAssertTrue(reveal(any(app, "favoriteModel-anthropic:claude-sonnet-4-5"), in: app))
        XCTAssertFalse(any(app, "starCurrentModel-assistant").exists, "The current model is starred already.")

        capture("ai-models")

        XCTAssertTrue(reveal(agent, in: app, swipes: 5))
        agent.tap()
        XCTAssertTrue(app.navigationBars["Agent"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "providerPicker").waitForExistence(timeout: 5))
        capture("ai-models-agent-picker")
        XCTAssertTrue(reveal(app.buttons["testAndSaveProvider"], in: app, swipes: 4))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 10))
    }

    func testAgentPageShowsDefaultsSwitchesAndAuditLog() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "agent"])
        XCTAssertTrue(app.navigationBars["Agent"].waitForExistence(timeout: 20))
        XCTAssertTrue(any(app, "browserAgentModelRow").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "browserAgentMaxSteps").exists)
        XCTAssertTrue(reveal(any(app, "browserAgentTruncationLimit"), in: app))

        let confirmSwitch = app.switches["agentConfirmBeforeWrites"]
        XCTAssertTrue(reveal(confirmSwitch, in: app))
        XCTAssertEqual(confirmSwitch.value as? String, "0", "Confirm before writes defaults to off.")

        let devSwitch = app.switches["agentDeveloperMode"]
        XCTAssertTrue(reveal(devSwitch, in: app))
        XCTAssertEqual(devSwitch.value as? String, "0", "Developer mode defaults to off.")

        let auditLog = app.buttons["settingsRow-auditLog"]
        XCTAssertTrue(reveal(auditLog, in: app))
        auditLog.tap()
        XCTAssertTrue(app.navigationBars["Audit log"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "auditLogEmptyState").waitForExistence(timeout: 5))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Agent"].waitForExistence(timeout: 10))
    }

    func testAIModelsRowsStayReadableAtAccessibilitySize() throws {
        let ax5 = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
        let app = launch(["-UIPreferredContentSizeCategoryName", ax5, "-dc-sample", "-dc-forums-home", "-dc-show-settings", "provider"])
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 20))
        let agent = any(app, "modelRole-browserAgent")
        let assistant = any(app, "modelRole-assistant")
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        XCTAssertTrue(assistant.waitForExistence(timeout: 5))
        capture("ax5_phone_settings-provider")
        XCTAssertLessThan(assistant.frame.height, 340, "Summaries row collapsed into a narrow multi-screen column at AX5.")
        XCTAssertLessThanOrEqual(assistant.frame.maxY, app.windows.firstMatch.frame.maxY, "Both model role rows should fit on screen at AX5.")
    }

    func testProviderSettingsTestAndSaveButtonKeepsFullRowHeight() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-show-settings", "provider"])
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 20))

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

    /// A saved key is replaced by tapping its field and typing.
    func testSavedAPIKeyFieldTakesFocusToReplaceTheKey() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-show-settings", "root"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        let providerRow = app.buttons["settingsRow-provider"]
        XCTAssertTrue(reveal(providerRow, in: app, swipes: 3))
        providerRow.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 10))
        let anthropic = app.buttons["providerRow-anthropic"]
        XCTAssertTrue(reveal(anthropic, in: app))
        anthropic.tap()
        let field = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "apiKeyMaskedBullets").exists)
        field.tap()
        XCTAssertTrue(wait(timeout: 5) { field.value(forKey: "hasKeyboardFocus") as? Bool == true }, "Tapping a saved key's field should focus it.")
        field.typeText("NEWKEY")
        XCTAssertEqual(field.value as? String, "••••••", "Typing into a saved key's field should replace the key.")
    }

    func testSettingsReadingLanguageSyncErrorAndSavedAPIKeyLayout() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-show-settings", "root"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        capture("base_phone_settings-root")

        let providerRow = app.buttons["settingsRow-provider"]
        XCTAssertTrue(reveal(providerRow, in: app, swipes: 3))
        providerRow.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 10))
        let readingLanguage = any(app, "settingsRow-readingLanguage")
        XCTAssertTrue(reveal(readingLanguage, in: app))
        XCTAssertLessThanOrEqual(readingLanguage.frame.height, 56, "Answer language row wrapped onto a second indented line at standard Dynamic Type.")

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

        let zhApp = launch(["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_Hans", "-dc-sample", "-dc-forums-home", "-dc-show-settings", "provider"])
        XCTAssertTrue(any(zhApp, "settingsRow-readingLanguage").waitForExistence(timeout: 20) || reveal(any(zhApp, "settingsRow-readingLanguage"), in: zhApp))
        capture("zh_phone_settings-provider")

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
    /// (and Summary) switch the Summaries model, Ask the forum its own.
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
            let title = mode == "agent" ? "ASK THE FORUM" : "SUMMARIES"
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
        // AI models… opens Settings › Models over the drawer (router).
        app.buttons["modelMenuSettings"].tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 10), "AI models… did not open Settings › Models.")
    }

    func testFavoriteActionsPresentAsSheet() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "provider",
                          "-dc-agent-model", "deepseek:deepseek-v4-flash"])
        let favorite = any(app, "favoriteModel-anthropic:claude-sonnet-4-5")
        XCTAssertTrue(reveal(favorite, in: app))
        favorite.tap()
        let sheet = any(app, "favoriteModelActionsSheet")
        XCTAssertTrue(waitOrDump(sheet, timeout: 5, in: app), "Favorite actions must use a sheet")
        XCTAssertTrue(app.buttons["Use for Agent"].exists)
        XCTAssertTrue(app.buttons["Use for Summaries"].exists)
        XCTAssertFalse(app.buttons["Use for Ask the forum"].exists)
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

    func testForumRequestRateLimitToggleShowsAndHidesPaceOptions() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "sites"])
        XCTAssertTrue(app.navigationBars["Sites"].waitForExistence(timeout: 20))
        let toggle = app.switches["forumRateLimitingEnabled"]
        XCTAssertTrue(reveal(toggle, in: app, swipes: 4))
        XCTAssertEqual(toggle.value as? String, "1", "Per-forum rate limiting is on by default.")
        let gentle = any(app, "forumRequestPace-gentle")
        XCTAssertTrue(reveal(gentle, in: app, swipes: 2))
        capture("settings-rate-limit-on")

        tapSwitch(toggle)
        XCTAssertTrue(wait(timeout: 5) { (toggle.value as? String) == "0" })
        XCTAssertTrue(waitForGone(gentle, timeout: 5))
        capture("settings-rate-limit-off")

        // Restore on so persisted simulator state stays at default.
        tapSwitch(toggle)
        XCTAssertTrue(wait(timeout: 5) { (toggle.value as? String) == "1" })
        XCTAssertTrue(gentle.waitForExistence(timeout: 5))
    }

    /// Settings › Models favorites: tap = pick the role, hold = use for both,
    /// swipe = remove.
    func testFavoritesTapHoldAndSwipe() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "provider", "-dc-agent-model", "deepseek:deepseek-v4-flash"])
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 20))
        let agent = any(app, "modelRole-browserAgent")
        let assistant = any(app, "modelRole-assistant")
        XCTAssertTrue(agent.waitForExistence(timeout: 5))

        // Tap: the role choice; Agent takes claude-sonnet-4-5.
        let claude = any(app, "favoriteModel-anthropic:claude-sonnet-4-5")
        XCTAssertTrue(reveal(claude, in: app))
        claude.tap()
        let useForAgent = app.buttons["Use for Agent"]
        XCTAssertTrue(waitOrDump(useForAgent, timeout: 5, in: app), "Tapping a favorite offers its roles.")
        useForAgent.tap()
        XCTAssertTrue(reveal(agent, in: app, swipes: 5))
        XCTAssertTrue(wait(timeout: 5) { agent.label.contains("claude-sonnet-4-5") }, "Got “\(agent.label)”.")

        // Hold: both roles take deepseek-v4-flash.
        let deepseek = any(app, "favoriteModel-deepseek:deepseek-v4-flash")
        XCTAssertTrue(reveal(deepseek, in: app))
        deepseek.press(forDuration: 1.2)
        XCTAssertTrue(reveal(agent, in: app, swipes: 5))
        XCTAssertTrue(wait(timeout: 5) {
            agent.label.contains("deepseek-v4-flash") && assistant.label.contains("deepseek-v4-flash")
        }, "Holding a favorite uses it for both; got “\(assistant.label)” and “\(agent.label)”.")
        XCTAssertFalse(app.buttons["Use for Agent"].exists, "Holding doesn't open the role choice.")

        // Swipe left: remove. The roles keep their model, so it can be starred again.
        XCTAssertTrue(reveal(deepseek, in: app))
        deepseek.swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(waitForGone(deepseek, timeout: 5))
        XCTAssertTrue(any(app, "starCurrentModel-browserAgent").waitForExistence(timeout: 5), "Star deepseek-v4-flash is offered.")
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
    /// "Later" and Settings › Forums' Pin.
    func testSmallControlsAreAtLeast44PointsToTap() throws {
        var app = launch(["-dc-onboarding-step", "model"])
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

    func testWatchedRowOpensTopicAndPodcastRequiresDigest() throws {
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
            tapSwitch(podcastSwitch)
        }
        if (digestSwitch.value as? String) == "1" {
            tapSwitch(digestSwitch)
        }
        XCTAssertFalse(podcastSwitch.isEnabled, "Make the podcast every day must be disabled when Make a digest every day is off")
        XCTAssertEqual(podcastSwitch.value as? String, "0")
        tapNavigationBack(in: app)

        // 2. Sites › Following: tapping a watched topic row dismisses Settings to open the topic.
        let sitesRow = app.buttons["settingsRow-sites"]
        XCTAssertTrue(revealRow(sitesRow, in: app))
        sitesRow.tap()
        XCTAssertTrue(app.navigationBars["Sites"].waitForExistence(timeout: 10))
        let watchedRow = app.buttons["settingsRow-watched"]
        XCTAssertTrue(reveal(watchedRow, in: app))
        watchedRow.tap()
        let firstWatched = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settingsWatchedRow-'")).firstMatch
        XCTAssertTrue(reveal(firstWatched, in: app, swipes: 4))
        firstWatched.tap()
        XCTAssertTrue(waitForGone(any(app, "settingsRoot"), timeout: 8), "Tapping a watched topic row must dismiss Settings.")
    }

    func testUnsupportedAppleIntelligenceMenuAndGoogleVoicesMissingKeySetup() throws {
        // 1. Unsupported device: provider menu shows Apple Intelligence as "Not supported on this device" and disabled.
        var app = launch(["-dc-sample", "-dc-show-settings", "provider", "-dc-apple-intelligence", "unsupported"])
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 20))
        let assistantRow = any(app, "modelRole-assistant")
        XCTAssertTrue(assistantRow.waitForExistence(timeout: 5))
        assistantRow.tap()
        XCTAssertTrue(app.navigationBars["Summaries"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 10))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Daily digest & podcast"].waitForExistence(timeout: 10))

        // Restore Automatic so persisted state stays clean for other UI tests.
        XCTAssertTrue(reveal(voicesPicker, in: app, swipes: 4))
        (voicesMenuButton.exists ? voicesMenuButton : voicesPicker).tap()
        let automatic = app.buttons["Automatic"].firstMatch
        if automatic.waitForExistence(timeout: 5) { automatic.tap() }
    }

    func testCaptureWuko24ProofScreenshots() throws {
        guard ProcessInfo.processInfo.environment["DC_SCREENSHOT_DIR"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_DC_SCREENSHOT_DIR to capture WUKO-24 proof screenshots.")
        }
        let suffix = ProcessInfo.processInfo.environment["DC_SCREENSHOT_STYLE"] ?? "light"
        let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-dc-sample"]
        let prefix = isPhone ? "iphone" : "ipad"

        let rootArgs = isPhone
            ? base + ["-dc-forums-home", "-dc-show-settings", "root"]
            : base + ["-dc-panel-settings"]
        let rootApp = launch(rootArgs, orientation: isPhone ? .portrait : .landscapeLeft)
        XCTAssertTrue(rootApp.navigationBars["Settings"].waitForExistence(timeout: 20))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        capture("\(prefix)-settings-root-\(suffix)")

        if isPhone && suffix == "light" {
            for (page, title, slug) in [
                ("provider", "Models", "models"),
                ("agent", "Agent", "agent"),
                ("sites", "Sites", "sites"),
                ("browser", "Browser", "browser"),
                ("help", "Help & about", "help")
            ] {
                let subApp = launch(base + ["-dc-forums-home", "-dc-show-settings", page])
                XCTAssertTrue(subApp.navigationBars[title].waitForExistence(timeout: 15))
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                capture("\(prefix)-settings-\(slug)-\(suffix)")
                if page == "agent" {
                    _ = reveal(any(subApp, "agentReadLimit"), in: subApp, swipes: 3)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                    capture("\(prefix)-settings-agent-bottom-\(suffix)")
                }
            }
        }
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
        case "provider": expected = any(app, "modelRole-browserAgent")
        case "sync": expected = any(app, "syncAPIKeys")
        case "sites": expected = any(app, "forumRateLimitingEnabled")
        case "agent": expected = any(app, "browserAgentMaxSteps")
        case "scripts": expected = any(app, "scriptsGlobalToggle")
        case "browser": expected = any(app, "searchEnginePicker")
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
