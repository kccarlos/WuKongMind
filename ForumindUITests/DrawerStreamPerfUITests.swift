import XCTest

/// Measures the drawer's drag while an answer streams, against the same drag
/// with nothing streaming. Not a pass/fail test: `dev/scripts/perf/drawer-stream.sh`
/// records Animation Hitches and Time Profiler between the printed PERF-START
/// and PERF-END lines. Run on a device, optimized.
final class DrawerStreamPerfUITests: DCUITestCase {
    private var server: FixtureWordPressServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = FixtureWordPressServer()
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        super.tearDown()
    }

    /// A long summary shaped like a real one: headings, bullets, `#N` citations.
    private static var longAnswer: [String] {
        var chunks = ["## Original post\n"]
        for section in 1...40 {
            chunks.append("\n## Section \(section)\n")
            for point in 1...6 {
                for word in "- Readers report that the card works well and pays out quickly after a short wait".split(separator: " ") {
                    chunks.append(word + " ")
                }
                chunks.append("#\(section * point) #\(section + point + 40)\n")
            }
        }
        return chunks
    }

    private func dragDrawer(in app: XCUIApplication, seconds: TimeInterval) {
        let window = app.windows.firstMatch
        let medium = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53))
        let large = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09))
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            medium.press(forDuration: 0.05, thenDragTo: large, withVelocity: .slow, thenHoldForDuration: 0.2)
            large.press(forDuration: 0.05, thenDragTo: medium, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
    }

    private func openSummary(streaming: Bool) -> XCUIApplication {
        server.streamedSummary = streaming ? (Self.longAnswer, 0.04) : nil
        // Clears the summary an earlier run saved.
        let app = launch(["-dc-open", server.postURL, "-dc-fixture-model", server.baseURL, "-dc-script", "clear-all-after:1"])
        showAssistant(in: app)
        let summarize = app.buttons["createSummary"].firstMatch
        XCTAssertTrue(waitOrDump(summarize, timeout: 40, in: app), "No summary offered.")
        XCTAssertTrue(waitForHittable(summarize))
        summarize.tap()
        XCTAssertTrue(waitOrDump(any(app, "summaryContent"), timeout: 60, in: app), "The summary did not appear.")
        return app
    }

    func testDragWhileStreaming() {
        let app = openSummary(streaming: true)
        print("PERF-START")
        sleep(6) // xctrace attaches
        dragDrawer(in: app, seconds: 30)
        print("PERF-END")
    }

    /// The same long text, finished: separates the cost of laying out long text
    /// from the cost of updating it.
    func testDragLongTextIdle() {
        server.streamedSummary = (Self.longAnswer, 0.002)
        let app = launch(["-dc-open", server.postURL, "-dc-fixture-model", server.baseURL, "-dc-script", "clear-all-after:1"])
        showAssistant(in: app)
        let summarize = app.buttons["createSummary"].firstMatch
        XCTAssertTrue(waitOrDump(summarize, timeout: 40, in: app), "No summary offered.")
        XCTAssertTrue(waitForHittable(summarize))
        summarize.tap()
        XCTAssertTrue(waitOrDump(any(app, "summaryContent"), timeout: 60, in: app), "The summary did not appear.")
        sleep(12) // the whole answer arrives and the run ends
        print("PERF-START")
        sleep(6)
        dragDrawer(in: app, seconds: 30)
        print("PERF-END")
    }

    func testDragIdle() {
        let app = openSummary(streaming: false)
        sleep(3) // the short answer finishes
        print("PERF-START")
        sleep(6)
        dragDrawer(in: app, seconds: 30)
        print("PERF-END")
    }
}
