import XCTest

/// Baseline performance measurements for the address bar and Home's address field
/// (docs/wukongmind/design-motion.md §3 "Speed", task 3).
///
/// Not pass/fail on time: prints raw `PerfTimeline` and `perfAddressProbeState`
/// numbers for tap-to-edit-bar and Home-field keystrokes, and attaches them as
/// `address-bar-perf.txt`.
final class AddressBarPerfUITests: DCUITestCase {
    override var disablesAnimations: Bool { false }

    private func timeline(_ app: XCUIApplication) -> String {
        let element = any(app, "perfTimeline")
        return element.waitForExistence(timeout: 10) ? element.label : "missing"
    }

    private func addressProbe(_ app: XCUIApplication) -> [String: Int] {
        let element = any(app, "perfAddressProbeState")
        XCTAssertTrue(element.waitForExistence(timeout: 10), "perfAddressProbeState is missing (-dc-perf-probe)")
        var values: [String: Int] = [:]
        for field in element.label.split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let value = Int(parts[1]) {
                values[String(parts[0])] = value
            }
        }
        return values
    }

    private func point(_ frame: CGRect, in app: XCUIApplication) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
    }

    private func delta(_ before: [String: Int], _ after: [String: Int], per count: Int, named name: String) -> String {
        let lines = after.keys.sorted().map { key -> String in
            let change = (after[key] ?? 0) - (before[key] ?? 0)
            return "\(key)=\(change) (\(String(format: "%.2f", Double(change) / Double(max(count, 1)))) per action)"
        }
        return "== \(name) (\(count) actions)\n" + lines.joined(separator: "\n")
    }

    func testAddressBarTapAndHomeKeystrokeBaseline() throws {
        try skipUnlessPhone("Baseline targets iPhone tap-to-edit-bar and Home-field keystrokes.")
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            print("ADDRESS-BAR-PERF | " + line.replacingOccurrences(of: "\n", with: "\nADDRESS-BAR-PERF | "))
        }

        // 1. Tap-to-edit-bar on a loaded page.
        let pageApp = launch(["-dc-perf-probe", "-dc-bar-morph-fixture", "short"])
        let titleButton = pageApp.buttons["browserTitle"]
        XCTAssertTrue(waitForBarItem(titleButton, timeout: 15), "browserTitle did not appear")
        XCTAssertTrue(waitForHittable(titleButton, timeout: 5), "browserTitle not hittable")
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        if ProcessInfo.processInfo.environment["DC_PERF_TRACE"] == "1" {
            print("XCTRACE-START tap_to_edit_bar")
            RunLoop.current.run(until: Date().addingTimeInterval(8.0))
        }

        tapBarItem(titleButton)
        if !pageApp.textFields["addressField"].waitForExistence(timeout: 5) {
            attachTree(pageApp, named: "no-address-field")
            XCTFail("addressField did not appear (titleButton frame=\(titleButton.frame))")
        }
        XCTAssertTrue(any(pageApp, "home").waitForExistence(timeout: 5), "Home overlay did not appear")
        RunLoop.current.run(until: Date().addingTimeInterval(3.5))
        note("tap_to_edit_bar " + timeline(pageApp))

        let cancel = pageApp.buttons["addressCancel"]
        if cancel.exists { cancel.tap() }

        // 2. Per-keystroke in the bar's address field on Home.
        let homeApp = launch(["-dc-perf-probe", "-dc-forums-home", "-dc-seed-forums"])
        let homeBarTitle = homeApp.buttons["browserTitle"]
        XCTAssertTrue(waitForBarItem(homeBarTitle, timeout: 15), "browserTitle did not appear on Home")
        XCTAssertTrue(waitForHittable(homeBarTitle, timeout: 5), "browserTitle not hittable on Home")
        tapBarItem(homeBarTitle)
        let homeField = homeApp.textFields["addressField"]
        XCTAssertTrue(homeField.waitForExistence(timeout: 5), "addressField did not appear on Home")
        XCTAssertTrue(homeApp.keyboards.firstMatch.waitForExistence(timeout: 5), "Keyboard did not appear")
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let before = addressProbe(homeApp)
        let typed = "discourse meta swift"
        let typingStarted = Date()
        for ch in typed {
            homeField.typeText(String(ch))
        }
        let typingSeconds = Date().timeIntervalSince(typingStarted)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let after = addressProbe(homeApp)

        note("home_keystrokes_wall_seconds=\(String(format: "%.2f", typingSeconds))")
        note(delta(before, after, per: typed.count, named: "home_keystrokes"))
        attachText(report.joined(separator: "\n"), named: "address-bar-perf.txt")
    }
}
