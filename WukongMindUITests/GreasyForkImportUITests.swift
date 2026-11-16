import XCTest

/// Check 6: install two real Greasy Fork scripts through the app's own browser and the import review sheet.
final class GreasyForkImportUITests: DCUITestCase {
    private static let listURL = "https://greasyfork.org/en/scripts?sort=total_installs"
    private static let matchingPage = "https://example.com"

    /// Deletes every saved script through the Scripts manager, so each run starts and ends clean.
    private func removeAllScripts() {
        for _ in 0..<6 {
            let app = launch(["-dc-show-settings", "scripts"])
            guard any(app, "scriptManager").waitForExistence(timeout: 15) else { return }
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'scriptRow-'")).firstMatch
            guard row.waitForExistence(timeout: 5) else { app.terminate(); return }
            row.tap()
            let delete = app.buttons["scriptDelete"].firstMatch
            for _ in 0..<6 where !delete.exists || !delete.isHittable { app.swipeUp() }
            if delete.waitForExistence(timeout: 5) { delete.tap() }
            let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete' OR label == 'Delete script'")).firstMatch
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            app.terminate()
        }
    }

    func testInstallTwoGreasyForkScriptsInApp() throws {
        try requireNetwork()
        removeAllScripts()
        defer { removeAllScripts() }
        let scripts: [(label: String, slug: String, page: String)] = [
            ("Dark Mode", "dark", Self.matchingPage),
            ("Github Enhancement - High Speed Download", "github", "https://github.com/XIU2/UserScript")
        ]
        for (index, script) in scripts.enumerated() {
            let before = launch(["-dc-open", script.page])
            RunLoop.current.run(until: Date().addingTimeInterval(8))
            capture("gf\(index + 1)-\(script.slug)-before")
            before.terminate()

            let app = launch(["-dc-open", Self.listURL])
            let link = app.links[script.label].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 30), "no link \(script.label)")
            link.tap()
            let install = app.links["Install this script"].firstMatch
            XCTAssertTrue(install.waitForExistence(timeout: 30), "no install link")
            capture("gf\(index + 1)-\(script.slug)-page")
            install.tap()
            if !any(app, "scriptImportSheet").waitForExistence(timeout: 20) {
                let haveManager = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "already have a user script manager")).firstMatch
                if haveManager.waitForExistence(timeout: 10) { haveManager.tap() }
            }
            XCTAssertTrue(waitOrDump(any(app, "scriptImportSheet"), timeout: 30, in: app))
            XCTAssertTrue(waitOrDump(any(app, "scriptImportReady"), timeout: 30, in: app))
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            capture("gf\(index + 1)-\(script.slug)-review")
            let turnOn = app.buttons["scriptImportAddTurnOn"].firstMatch
            XCTAssertTrue(waitOrDump(turnOn, timeout: 10, in: app))
            turnOn.tap()
            XCTAssertTrue(waitForGone(any(app, "scriptImportSheet"), timeout: 15))
            app.terminate()

            let after = launch(["-dc-open", script.page])
            RunLoop.current.run(until: Date().addingTimeInterval(10))
            capture("gf\(index + 1)-\(script.slug)-after")
            if script.slug == "github" {
                // The script adds fast download links to the "Code" menu of a repository page.
                let codeButtons = after.buttons.matching(NSPredicate(format: "label == 'Code'"))
                _ = codeButtons.firstMatch.waitForExistence(timeout: 10)
                if let code = codeButtons.allElementsBoundByIndex.last {
                    code.tap()
                    RunLoop.current.run(until: Date().addingTimeInterval(4))
                    capture("gf\(index + 1)-\(script.slug)-after-code-menu")
                }
            }
            after.terminate()
        }
    }
}
