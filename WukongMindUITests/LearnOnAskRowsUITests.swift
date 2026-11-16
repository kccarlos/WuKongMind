import XCTest

/// Learn on ask 8: the unknown-thread suggestion row and the "Reads this site"
/// line under a learned reader in This page, in light and dark (screenshots for
/// the artboards' PNGs).
final class LearnOnAskRowsUITests: DCUITestCase {
    private let appearances = [("light", "Light"), ("dark", "Dark")]

    func testUnknownThreadRowShowsThreadSuggestions() throws {
        for (name, style) in appearances {
            let app = launch([
                "-AppleInterfaceStyle", style, "-dc-sample", "-dc-page-state", "notForum", "-dc-looks-like-thread",
                "-dc-drawer-detent", "large"
            ])
            let row = any(app, "suggestionRow")
            XCTAssertTrue(waitOrDump(row, timeout: 15, in: app), "The suggestion row did not appear.")
            XCTAssertTrue(app.buttons["suggestion-summarizeThread"].firstMatch.exists)
            XCTAssertTrue(app.buttons["suggestion-readAloud"].firstMatch.exists)
            XCTAssertTrue(app.buttons["suggestion-makeDark"].firstMatch.exists)
            capture("learn-unknown-thread-row-\(name)")
            app.terminate()
        }
    }

    func testThisPageShowsReadsThisSiteUnderALearnedReader() throws {
        for (name, style) in appearances {
            let app = launch([
                "-AppleInterfaceStyle", style, "-dc-browser-agent-demo", "empty", "-dc-scripts-sample", "manager",
                "-dc-reads-site", "-dc-drawer-detent", "large"
            ])
            let chip = app.buttons["pageCapabilitiesSeal"].firstMatch
            XCTAssertTrue(waitOrDump(chip, timeout: 15, in: app), "This page seal did not appear.")
            chip.tap()
            let row = any(app, "pageScriptRow-thread-reader")
            XCTAssertTrue(waitOrDump(row, timeout: 8, in: app), "The learned reader's row did not appear.")
            XCTAssertTrue(app.staticTexts["Reads this site"].firstMatch.exists)
            capture("learn-reads-site-row-\(name)")
            app.terminate()
        }
    }
}
