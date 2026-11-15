import XCTest

final class ScriptImportUITests: DCUITestCase {
    func testImportFromLinkMenuAndReviewConfirmFlows() throws {
        let mgrApp = launch(["-dc-sample", "-dc-show-settings", "scripts"])
        XCTAssertTrue(waitOrDump(any(mgrApp, "scriptManager"), timeout: 15, in: mgrApp))

        let moreButton = mgrApp.buttons["scriptsMoreMenu"].firstMatch
        XCTAssertTrue(waitOrDump(moreButton, timeout: 5, in: mgrApp))
        moreButton.tap()

        let importMenuItem = mgrApp.buttons["scriptsImportFromLinkMenuButton"].firstMatch
        XCTAssertTrue(waitOrDump(importMenuItem, timeout: 5, in: mgrApp))
        importMenuItem.tap()

        let alert = mgrApp.alerts["Import from link"].firstMatch
        XCTAssertTrue(waitOrDump(alert, timeout: 5, in: mgrApp))
        alert.buttons["Cancel"].firstMatch.tap()

        let addApp = launch(["-dc-m4-import-preview", "add"])
        XCTAssertTrue(waitOrDump(any(addApp, "scriptImportSheet"), timeout: 15, in: addApp))
        XCTAssertTrue(any(addApp, "scriptImportDuplicateBanner").exists)
        let keepOff = addApp.buttons["scriptImportAddKeepOff"].firstMatch
        XCTAssertTrue(waitOrDump(keepOff, timeout: 5, in: addApp))
        keepOff.tap()
        XCTAssertTrue(waitForGone(any(addApp, "scriptImportSheet"), timeout: 5))

        let failedApp = launch(["-dc-m4-import-preview", "failed"])
        XCTAssertTrue(waitOrDump(any(failedApp, "scriptImportFailed"), timeout: 15, in: failedApp))
        let closeButton = failedApp.buttons["scriptImportDismiss"].firstMatch
        XCTAssertTrue(waitOrDump(closeButton, timeout: 5, in: failedApp))
        closeButton.tap()
        XCTAssertTrue(waitForGone(any(failedApp, "scriptImportSheet"), timeout: 5))
    }

    func testCaptureM4ImportProofScreenshots() throws {
        let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        let styles = [("light", "Light"), ("dark", "Dark")]

        if isPhone {
            for (suffix, style) in styles {
                let styleArgs = base + ["-AppleInterfaceStyle", style]

                let addApp = launch(styleArgs + ["-dc-m4-import-preview", "add"])
                XCTAssertTrue(waitOrDump(any(addApp, "scriptImportSheet"), timeout: 15, in: addApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                capture("m4-iphone-add-\(suffix)")
                if suffix == "light" {
                    addApp.swipeUp()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                    capture("m4-iphone-add-bottom-light")
                }

                let failedApp = launch(styleArgs + ["-dc-m4-import-preview", "failed"])
                XCTAssertTrue(waitOrDump(any(failedApp, "scriptImportSheet"), timeout: 15, in: failedApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                capture("m4-iphone-failed-\(suffix)")

                let settingsApp = launch(styleArgs + ["-dc-m4-import-preview", "settings"])
                XCTAssertTrue(waitOrDump(any(settingsApp, "scriptManager"), timeout: 15, in: settingsApp))
                if suffix == "light" {
                    let more = settingsApp.buttons["scriptsMoreMenu"].firstMatch
                    if more.waitForExistence(timeout: 5) {
                        more.tap()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                        capture("m4-iphone-settings-menu-light")
                        let item = settingsApp.buttons["scriptsImportFromLinkMenuButton"].firstMatch
                        if item.waitForExistence(timeout: 5) {
                            item.tap()
                            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                            capture("m4-iphone-settings-alert-light")
                        }
                    }
                } else {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                    capture("m4-iphone-settings-dark")
                }

                let detailApp = launch(styleArgs + ["-dc-m4-import-preview", "detail"])
                XCTAssertTrue(waitOrDump(any(detailApp, "scriptDetail"), timeout: 15, in: detailApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                capture("m4-iphone-detail-\(suffix)")
                if suffix == "light" {
                    detailApp.swipeUp()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                    capture("m4-iphone-detail-source-light")
                }
            }
        } else {
            for (suffix, style) in styles {
                let styleArgs = base + ["-AppleInterfaceStyle", style]

                let addApp = launch(styleArgs + ["-dc-m4-import-preview", "add"], orientation: .landscapeLeft)
                XCTAssertTrue(waitOrDump(any(addApp, "scriptImportSheet"), timeout: 15, in: addApp))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                capture("m4-ipad-add-\(suffix)")
            }
        }
    }
}
