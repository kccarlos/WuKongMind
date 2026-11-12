import XCTest

final class ScriptManagerUITests: DCUITestCase {
    func testSavedScriptCardViewCodeToggleAndDeleteUndo() throws {
        let app = launch(["-dc-browser-agent-demo", "saved-script", "-dc-drawer-detent", "large"])

        let card = any(app, "agentScriptCard")
        XCTAssertTrue(waitOrDump(card, timeout: 15, in: app), "Script card did not appear after script_save.")

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

        let chip = app.buttons["agentScriptsCount"].firstMatch
        XCTAssertTrue(waitOrDump(chip, timeout: 15, in: app), "Scripts on this page chip did not appear.")
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
                capture("iphone-detail-error-light")
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
                    capture("iphone-badge-active-light")
                }

                let errorBar = launch(styleArgs + ["-dc-browser-agent-fixture-page", "-dc-scripts-sample", "page-error"])
                XCTAssertTrue(waitForBarItem(errorBar.buttons["aiButton"], timeout: 15))
                closeDrawer(in: errorBar)
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                capture("iphone-badge-error-\(suffix)")

                // 2. Saved script card in Agent conversation
                let cardApp = launch(styleArgs + ["-dc-browser-agent-demo", "saved-script", "-dc-drawer-detent", "large"])
                XCTAssertTrue(waitOrDump(any(cardApp, "agentScriptCard"), timeout: 15, in: cardApp))
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                capture("iphone-card-\(suffix)")

                // 3. Scripts on this page popover (with active + error + CSS-only rows)
                let popApp = launch(styleArgs + [
                    "-dc-browser-agent-demo", "empty",
                    "-dc-scripts-sample", "page-error",
                    "-dc-drawer-detent", "large",
                    "-dc-scripts-open-popover"
                ])
                XCTAssertTrue(waitOrDump(any(popApp, "pageScriptsPopover"), timeout: 15, in: popApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                capture("iphone-popover-\(suffix)")

                // 4. Settings › Scripts manager
                let mgrApp = launch(styleArgs + ["-dc-sample", "-dc-show-settings", "scripts", "-dc-scripts-sample", "manager"])
                XCTAssertTrue(waitOrDump(any(mgrApp, "scriptManager"), timeout: 15, in: mgrApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                capture("iphone-manager-\(suffix)")

                // 5. Script detail (with runtime error card)
                let detailApp = launch(styleArgs + ["-dc-sample", "-dc-show-settings", "scripts", "-dc-scripts-sample", "detail-error"])
                XCTAssertTrue(waitOrDump(any(detailApp, "scriptErrorCard"), timeout: 15, in: detailApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                capture("iphone-detail-error-\(suffix)")

                // 6. Version history
                let histApp = launch(styleArgs + [
                    "-dc-sample",
                    "-dc-show-settings", "scripts",
                    "-dc-scripts-sample", "detail",
                    "-dc-scripts-detail-subpage", "history"
                ])
                XCTAssertTrue(waitOrDump(any(histApp, "scriptVersionRow-1"), timeout: 15, in: histApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                capture("iphone-history-\(suffix)")

                if suffix == "dark" {
                    let editorApp = launch(styleArgs + [
                        "-dc-sample",
                        "-dc-show-settings", "scripts",
                        "-dc-scripts-sample", "detail",
                        "-dc-scripts-detail-subpage", "js"
                    ])
                    XCTAssertTrue(waitOrDump(any(editorApp, "scriptCodeEditor"), timeout: 15, in: editorApp))
                    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                    capture("iphone-editor-dark")
                }
            }
        } else {
            for (suffix, style) in styles {
                let styleArgs = base + ["-AppleInterfaceStyle", style]

                // 1. iPad split workspace: top bar badge + side panel with Script card
                let splitCard = launch(styleArgs + ["-dc-browser-agent-demo", "saved-script"], orientation: .landscapeLeft)
                XCTAssertTrue(waitOrDump(any(splitCard, "agentScriptCard"), timeout: 15, in: splitCard))
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                capture("ipad-split-card-\(suffix)")

                // 2. iPad split workspace: global-off grey badge + PageScriptsPopover
                let popOff = launch(styleArgs + [
                    "-dc-browser-agent-demo", "empty",
                    "-dc-scripts-sample", "global-off",
                    "-dc-scripts-open-popover"
                ], orientation: .landscapeLeft)
                XCTAssertTrue(waitOrDump(any(popOff, "pageScriptsPopover"), timeout: 15, in: popOff))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                capture("ipad-popover-off-\(suffix)")

                // 3. iPad Settings › Scripts sheet over dimmed browser
                let sheetMgr = launch(styleArgs + [
                    "-dc-browser-agent-demo", "empty",
                    "-dc-scripts-sample", "manager",
                    "-dc-scripts-sheet"
                ], orientation: .landscapeLeft)
                XCTAssertTrue(waitOrDump(any(sheetMgr, "scriptManager"), timeout: 15, in: sheetMgr))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                capture("ipad-manager-sheet-\(suffix)")
            }
        }
    }
}
