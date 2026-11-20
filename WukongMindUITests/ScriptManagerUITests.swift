import XCTest

final class ScriptManagerUITests: DCUITestCase {
    func testSavedScriptCardViewCodeToggleAndDeleteUndo() throws {
        let app = launch(["-dc-browser-agent-demo", "saved-script", "-dc-drawer-detent", "large"])

        // Default: Save scripts without asking is off, so script_save opens the shared review sheet.
        let approveButton = app.buttons["scriptImportAddTurnOn"].firstMatch
        XCTAssertTrue(waitOrDump(approveButton, timeout: 15, in: app), "Agent script_save did not open the shared review sheet.")
        XCTAssertFalse(app.buttons["scriptImportAskAgent"].exists, "Agent-proposed scripts must not offer 'Ask the Agent to review it'.")
        capture("agent-script-save-review-sheet")
        approveButton.tap()

        let card = any(app, "agentScriptCard")
        XCTAssertTrue(waitOrDump(card, timeout: 15, in: app), "Script card did not appear after approving script_save.")

        let viewCode = app.buttons["agentScriptViewCode"].firstMatch
        XCTAssertTrue(viewCode.waitForExistence(timeout: 5))
        viewCode.tap()

        let codeSheet = any(app, "scriptViewCodeText")
        XCTAssertTrue(waitOrDump(codeSheet, timeout: 8, in: app), "Code sheet did not present.")
        let closeButton = app.buttons["scriptViewCodeClose"].firstMatch
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        closeButton.tap()
        XCTAssertTrue(waitForGone(codeSheet, timeout: 5))

        let toggleButton = app.buttons["agentScriptToggleButton"].firstMatch
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5))

        let undoSavedButton = app.buttons["agentScriptUndo"].firstMatch
        XCTAssertTrue(undoSavedButton.waitForExistence(timeout: 5), "Saved script card Undo button did not appear.")
        undoSavedButton.tap()
        XCTAssertTrue(waitForGone(undoSavedButton, timeout: 5), "Undo did not disable the saved script.")
        XCTAssertTrue(card.exists, "Undo must disable the saved script without deleting its card.")
        toggleButton.tap()

        toggleButton.tap()
        toggleButton.tap()

        let deleteButton = app.buttons["agentScriptDeleteButton"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        let undoButton = app.buttons["agentScriptUndoDelete"].firstMatch
        XCTAssertTrue(waitOrDump(undoButton, timeout: 5, in: app), "Deleted row Undo button did not appear.")
        undoButton.tap()
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5), "Undo did not restore the script card.")
    }

    func testPageScriptsPopoverTogglesReloadAndOpensManager() throws {
        let app = launch([
            "-dc-browser-agent-demo", "empty",
            "-dc-scripts-sample", "manager",
            "-dc-drawer-detent", "large"
        ])

        let chip = app.buttons["pageCapabilitiesSeal"].firstMatch
        XCTAssertTrue(waitOrDump(chip, timeout: 15, in: app), "This page seal did not appear.")
        chip.tap()

        let popover = any(app, "pageScriptsPopover")
        XCTAssertTrue(waitOrDump(popover, timeout: 8, in: app), "Page scripts popover did not open.")
        XCTAssertTrue(any(app, "pageScriptRow-op-only").waitForExistence(timeout: 5))

        let toggle = app.switches["pageScriptToggle-op-only"].firstMatch
        if toggle.waitForExistence(timeout: 5) {
            toggle.tap()
            XCTAssertTrue(
                app.buttons["pageScriptsReload"].firstMatch.waitForExistence(timeout: 5),
                "Reload page button did not appear after toggling a page script."
            )
        }

        let manage = app.buttons["pageScriptsManage"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()

        XCTAssertTrue(
            waitOrDump(any(app, "scriptManager"), timeout: 10, in: app),
            "Manage scripts did not open Settings › Scripts."
        )
    }

    func testAutoDisabledScriptShowsReasonAndFixButtonInThisPage() throws {
        let app = launch([
            "-dc-browser-agent-demo", "empty",
            "-dc-scripts-sample", "auto-disabled",
            "-dc-drawer-detent", "large"
        ])

        if usesDrawerLayout(app) {
            let state = drawerState(in: app)
            XCTAssertTrue(
                wait(timeout: 15) { state.exists && state.label.contains("detent=large") },
                "AI drawer did not reach large detent."
            )
        }

        let chip = app.buttons["pageCapabilitiesSeal"].firstMatch
        XCTAssertTrue(waitOrDump(chip, timeout: 15, in: app), "This page seal did not appear.")
        XCTAssertTrue(waitForHittable(chip, timeout: 10), "This page seal did not become hittable.")
        chip.tap()

        let popover = any(app, "pageScriptsPopover")
        XCTAssertTrue(waitOrDump(popover, timeout: 10, in: app), "Page scripts popover did not open.")

        let reason = any(app, "thisPageDisabledReason-dark-thread")
        XCTAssertTrue(waitOrDump(reason, timeout: 8, in: app), "Auto-disabled reason text is missing in This page.")
        XCTAssertTrue(
            reason.label.contains("Turned off after errors on 3 page loads in a row: TypeError: Cannot read properties of null (reading 'classList')"),
            "Unexpected disabled reason label: \(reason.label)"
        )

        let fixButton = app.buttons["thisPageLetAgentFix-dark-thread"].firstMatch
        XCTAssertTrue(waitOrDump(fixButton, timeout: 8, in: app), "Let the Agent fix it button is missing in This page.")
        XCTAssertTrue(waitForHittable(fixButton, timeout: 8), "Let the Agent fix it button is not hittable.")
        fixButton.tap()

        XCTAssertTrue(waitForGone(popover, timeout: 10), "Tapping Let the Agent fix it did not close This page.")
        let promptMessage = app.staticTexts.matching(label(contains: "Fix the script Dark palette & wide thread")).firstMatch
        XCTAssertTrue(
            waitOrDump(promptMessage, timeout: 15, in: app),
            "Let the Agent fix it did not send the repair prompt to the Agent."
        )
    }

    func testScriptManagerGroupsDetailAndHistoryRollback() throws {
        let app = launch([
            "-dc-sample",
            "-dc-show-settings", "scripts",
            "-dc-scripts-sample", "manager"
        ])

        XCTAssertTrue(waitOrDump(any(app, "scriptManager"), timeout: 15, in: app))
        XCTAssertTrue(any(app, "scriptsGlobalToggle").waitForExistence(timeout: 5))

        let opRow = app.buttons["scriptRow-op-only"].firstMatch
        XCTAssertTrue(reveal(opRow, in: app, swipes: 4), "Original poster only row is missing.")
        opRow.tap()

        XCTAssertTrue(waitOrDump(any(app, "scriptDetail"), timeout: 8, in: app))
        XCTAssertTrue(any(app, "scriptNameField").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "scriptMatchRule-0").waitForExistence(timeout: 5))

        let historyRow = app.buttons["scriptHistoryRow"].firstMatch
        XCTAssertTrue(reveal(historyRow, in: app, swipes: 6), "Version history row is missing.")
        historyRow.tap()

        let restoreButton = app.buttons["scriptRestoreVersion-1"].firstMatch
        XCTAssertTrue(reveal(restoreButton, in: app, swipes: 4), "Version 1 Restore button is missing.")
        restoreButton.tap()

        XCTAssertTrue(
            waitOrDump(any(app, "scriptUndoToast"), timeout: 8, in: app),
            "Undo toast did not appear after restoring version 1."
        )
    }

    func testSpaForumPersistReloadReopenRouteAndManagerToggleOff() throws {
        try runM2SpaForumAcceptanceFlow(
            launchExtra: ["-dc-browser-agent-demo", "spa-op-only"]
        )
    }

    func testCaptureM2ProofScreenshots() throws {
        guard ProcessInfo.processInfo.environment["DC_SCREENSHOT_DIR"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_DC_SCREENSHOT_DIR to capture M2 proof screenshots.")
        }

        let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        let requestedStyle = ProcessInfo.processInfo.environment["DC_SHOT_STYLE"]
        let styles: [(String, String)] = {
            switch requestedStyle {
            case "light": return [("light", "Light")]
            case "dark": return [("dark", "Dark")]
            default: return [("light", "Light"), ("dark", "Dark")]
            }
        }()

        if isPhone {
            if requestedStyle == "detail-light" {
                let detailApp = launch(base + ["-dc-sample", "-dc-show-settings", "scripts", "-dc-scripts-sample", "detail-error"])
                XCTAssertTrue(waitOrDump(any(detailApp, "scriptErrorCard"), timeout: 15, in: detailApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                captureIfRequested("iphone-detail-error-light")
                return
            }

            for (suffix, style) in styles {
                let styleArgs = base + ["-AppleInterfaceStyle", style]

                // 1. Browser bar badge (active & error)
                if suffix == "light" {
                    let activeBar = launch(styleArgs + ["-dc-browser-agent-fixture-page", "-dc-scripts-sample", "manager"])
                    XCTAssertTrue(waitForBarItem(activeBar.buttons["aiButton"], timeout: 15))
                    closeDrawer(in: activeBar)
                    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                    captureIfRequested("iphone-badge-active-light")
                }

                let errorBar = launch(styleArgs + ["-dc-browser-agent-fixture-page", "-dc-scripts-sample", "page-error"])
                XCTAssertTrue(waitForBarItem(errorBar.buttons["aiButton"], timeout: 15))
                closeDrawer(in: errorBar)
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                captureIfRequested("iphone-badge-error-\(suffix)")

                // 2. Saved script card in Agent conversation
                let cardApp = launch(styleArgs + ["-dc-browser-agent-demo", "saved-script", "-dc-drawer-detent", "large"])
                let approveCard = cardApp.buttons["scriptImportAddTurnOn"].firstMatch
                if approveCard.waitForExistence(timeout: 10) { approveCard.tap() }
                XCTAssertTrue(waitOrDump(any(cardApp, "agentScriptCard"), timeout: 15, in: cardApp))
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                captureIfRequested("iphone-card-\(suffix)")

                // 3. Scripts on this page popover (with active + error + CSS-only rows)
                let popApp = launch(styleArgs + [
                    "-dc-browser-agent-demo", "empty",
                    "-dc-scripts-sample", "page-error",
                    "-dc-drawer-detent", "large",
                    "-dc-scripts-open-popover"
                ])
                XCTAssertTrue(waitOrDump(any(popApp, "pageScriptsPopover"), timeout: 15, in: popApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                captureIfRequested("iphone-popover-\(suffix)")

                // 4. Settings › Scripts manager
                let mgrApp = launch(styleArgs + ["-dc-sample", "-dc-show-settings", "scripts", "-dc-scripts-sample", "manager"])
                XCTAssertTrue(waitOrDump(any(mgrApp, "scriptManager"), timeout: 15, in: mgrApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                captureIfRequested("iphone-manager-\(suffix)")

                // 5. Script detail (with runtime error card)
                let detailApp = launch(styleArgs + ["-dc-sample", "-dc-show-settings", "scripts", "-dc-scripts-sample", "detail-error"])
                XCTAssertTrue(waitOrDump(any(detailApp, "scriptErrorCard"), timeout: 15, in: detailApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                captureIfRequested("iphone-detail-error-\(suffix)")

                // 6. Version history
                let histApp = launch(styleArgs + [
                    "-dc-sample",
                    "-dc-show-settings", "scripts",
                    "-dc-scripts-sample", "detail",
                    "-dc-scripts-detail-subpage", "history"
                ])
                XCTAssertTrue(waitOrDump(any(histApp, "scriptVersionRow-1"), timeout: 15, in: histApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                captureIfRequested("iphone-history-\(suffix)")

                if suffix == "dark" {
                    let editorApp = launch(styleArgs + [
                        "-dc-sample",
                        "-dc-show-settings", "scripts",
                        "-dc-scripts-sample", "detail",
                        "-dc-scripts-detail-subpage", "js"
                    ])
                    XCTAssertTrue(waitOrDump(any(editorApp, "scriptCodeEditor"), timeout: 15, in: editorApp))
                    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                    captureIfRequested("iphone-editor-dark")
                }
            }
        } else {
            for (suffix, style) in styles {
                let styleArgs = base + ["-AppleInterfaceStyle", style]

                // 1. iPad split workspace: top bar badge + side panel with Script card
                let splitCard = launch(styleArgs + ["-dc-browser-agent-demo", "saved-script"], orientation: .landscapeLeft)
                let approveSplit = splitCard.buttons["scriptImportAddTurnOn"].firstMatch
                if approveSplit.waitForExistence(timeout: 10) { approveSplit.tap() }
                XCTAssertTrue(waitOrDump(any(splitCard, "agentScriptCard"), timeout: 15, in: splitCard))
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                captureIfRequested("ipad-split-card-\(suffix)")

                // 2. iPad split workspace: global-off grey badge + PageScriptsPopover
                let popOff = launch(styleArgs + [
                    "-dc-browser-agent-demo", "empty",
                    "-dc-scripts-sample", "global-off",
                    "-dc-scripts-open-popover"
                ], orientation: .landscapeLeft)
                XCTAssertTrue(waitOrDump(any(popOff, "pageScriptsPopover"), timeout: 15, in: popOff))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                captureIfRequested("ipad-popover-off-\(suffix)")

                // 3. iPad Settings › Scripts sheet over dimmed browser
                let sheetMgr = launch(styleArgs + [
                    "-dc-browser-agent-demo", "empty",
                    "-dc-scripts-sample", "manager",
                    "-dc-scripts-sheet"
                ], orientation: .landscapeLeft)
                XCTAssertTrue(waitOrDump(any(sheetMgr, "scriptManager"), timeout: 15, in: sheetMgr))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                captureIfRequested("ipad-manager-sheet-\(suffix)")
            }
        }
    }

    func testM4GMAiSettingsManagerAndDetailViews() throws {
        let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // The dark pass repeats the light pass's assertions (labels and
        // presence, nothing colour-dependent) to take the dark screenshots, so
        // it only runs when a screenshot directory is asked for.
        var appearances = [("light", "Light")]
        if ProcessInfo.processInfo.environment["DC_SCREENSHOT_DIR"] != nil {
            appearances.append(("dark", "Dark"))
        }
        for (suffix, style) in appearances {
            let styleArgs = base + ["-AppleInterfaceStyle", style]

            // 1-3. Settings › Models, Settings › Models › Scripts, Settings › Scripts, and Script detail
            // in one launch per appearance to avoid 8 full app launches per test.
            let settingsApp = launch(styleArgs + ["-dc-sample", "-dc-show-settings", "root", "-dc-scripts-sample", "m4-ai"])
            XCTAssertTrue(waitOrDump(any(settingsApp, "settingsRoot"), timeout: 15, in: settingsApp), "Settings root did not appear.")

            let providerRow = settingsApp.buttons["settingsRow-provider"].firstMatch
            XCTAssertTrue(reveal(providerRow, in: settingsApp, swipes: 3), "Models settings row missing.")
            providerRow.tap()

            let scriptsRoleRow = any(settingsApp, "modelRole-scripts")
            XCTAssertTrue(waitOrDump(scriptsRoleRow, timeout: 10, in: settingsApp), "Scripts model role row missing.")
            XCTAssertTrue(scriptsRoleRow.label.contains("Same as Summaries"), "Unexpected Scripts role label: \(scriptsRoleRow.label)")
            XCTAssertTrue(waitForHittable(scriptsRoleRow, timeout: 5))
            captureIfRequested("m4-models-\(suffix)")

            scriptsRoleRow.tap()
            let sameToggle = settingsApp.switches["scriptsSameAsSummariesToggle"].firstMatch
            XCTAssertTrue(waitOrDump(sameToggle, timeout: 10, in: settingsApp), "Same as Summaries toggle missing on Scripts model page.")
            XCTAssertTrue(waitForHittable(sameToggle, timeout: 5))
            captureIfRequested("m4-models-scripts-\(suffix)")

            for _ in 0..<3 where settingsApp.navigationBars["Scripts"].exists {
                settingsApp.navigationBars.buttons.element(boundBy: 0).tap()
                _ = waitForGone(settingsApp.navigationBars["Scripts"], timeout: 3)
            }
            XCTAssertTrue(settingsApp.navigationBars["Models"].waitForExistence(timeout: 10), "Back from Scripts did not return to Models.")
            for _ in 0..<3 where settingsApp.navigationBars["Models"].exists {
                tapNavigationBack(in: settingsApp)
                _ = waitForGone(settingsApp.navigationBars["Models"], timeout: 3)
            }
            XCTAssertTrue(settingsApp.navigationBars["Settings"].waitForExistence(timeout: 10), "Back from Models did not return to Settings.")

            let scriptsRow = settingsApp.buttons["settingsRow-scripts"].firstMatch
            XCTAssertTrue(reveal(scriptsRow, in: settingsApp, swipes: 3), "Scripts settings row missing.")
            scriptsRow.tap()

            // 2. Settings › Scripts (AI in scripts switch + Uses AI subtitle)
            XCTAssertTrue(waitOrDump(any(settingsApp, "scriptManager"), timeout: 10, in: settingsApp), "Script manager did not appear.")
            let aiSwitch = settingsApp.switches["scriptsAIEnabledToggle"].firstMatch
            XCTAssertTrue(waitOrDump(aiSwitch, timeout: 8, in: settingsApp), "AI in scripts toggle missing.")
            let foldRow = settingsApp.buttons["scriptRow-fold-empty-replies"].firstMatch
            XCTAssertTrue(reveal(foldRow, in: settingsApp, swipes: 5), "Fold empty replies row missing.")
            XCTAssertTrue(foldRow.label.contains("Uses AI"), "Expected Uses AI in row label, got: \(foldRow.label)")
            captureIfRequested("m4-scripts-manager-\(suffix)")

            // 3. Script detail (Can use + AI use today + Clear AI cache)
            foldRow.tap()
            XCTAssertTrue(waitOrDump(any(settingsApp, "scriptDetail"), timeout: 10, in: settingsApp), "Script detail did not appear.")
            let canUseRow = any(settingsApp, "scriptCanUseAI")
            XCTAssertTrue(waitOrDump(canUseRow, timeout: 8, in: settingsApp), "Can use Uses AI row missing in Script detail.")
            XCTAssertTrue(canUseRow.label.contains("Uses AI: sends page text to"), "Unexpected Can use label: \(canUseRow.label)")

            let aiUseRow = any(settingsApp, "scriptAIUseTodayRow")
            XCTAssertTrue(reveal(aiUseRow, in: settingsApp, swipes: 5), "AI use today row missing in Script detail.")
            XCTAssertTrue(aiUseRow.label.contains("3 calls") && aiUseRow.label.contains("41 from cache"), "Unexpected AI use label: \(aiUseRow.label)")
            let clearBtn = settingsApp.buttons["scriptClearAICacheButton"].firstMatch
            XCTAssertTrue(reveal(clearBtn, in: settingsApp, swipes: 3), "Clear AI cache button missing in Script detail.")
            captureIfRequested("m4-script-detail-\(suffix)")

            if suffix == "light" {
                clearBtn.tap()
                XCTAssertTrue(waitForHittable(clearBtn, timeout: 5), "Clear AI cache button disappeared after tap.")
            }

            // 4. This page popover (uses AI subtitle)
            let popApp = launch(styleArgs + [
                "-dc-browser-agent-demo", "empty",
                "-dc-scripts-sample", "m4-ai",
                "-dc-drawer-detent", "large",
                "-dc-scripts-open-popover"
            ])
            if usesDrawerLayout(popApp) {
                let state = drawerState(in: popApp)
                XCTAssertTrue(
                    wait(timeout: 15) { state.exists && state.label.contains("detent=large") },
                    "AI drawer did not reach large detent."
                )
            }
            XCTAssertTrue(waitOrDump(any(popApp, "pageScriptsPopover"), timeout: 15, in: popApp), "Page scripts popover did not open.")
            let popRow = any(popApp, "pageScriptRow-fold-empty-replies")
            XCTAssertTrue(waitOrDump(popRow, timeout: 8, in: popApp), "Fold empty replies row missing in This page popover.")
            XCTAssertTrue(popRow.label.contains("Uses AI"), "Expected Uses AI in popover row label, got: \(popRow.label)")
            XCTAssertTrue(waitForHittable(popRow, timeout: 5))
            captureIfRequested("m4-this-page-\(suffix)")
        }
    }
}
