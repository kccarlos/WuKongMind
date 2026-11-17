import XCTest

/// The drawer on a very long thread, in the whole app (docs/wukongmind/design-performance-and-state.md).
///
/// Not pass/fail on time: each test summarizes a thread through the fixture model, then types,
/// scrolls and reopens the drawer while the app's own probe (`-dc-perf-probe`, `perfProbeState`)
/// counts main-thread time. The numbers are attached as `long-thread-perf-<case>.txt`. CI does not
/// run this suite; run it on the Mac mini (`scripts/remote-test.sh`) or the test iPhone
/// (`scripts/device-check.sh`).
final class LongThreadDrawerPerfUITests: DCUITestCase {
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

    /// A summary shaped like a real one of a long comment thread: headings, bullets, `#N` citations.
    private static func summary(posts: Int) -> String {
        (1...8).map { section -> String in
            let base = max(1, section * posts / 9)
            return """
            ## Theme \(section): what readers report

            Most readers got the bonus within the stated time #\(base), a few needed a second deposit #\(base + 1).

            - Direct deposits from two brokerages counted #\(base + 2) #\(base + 3).
            - The fee is waived with the stated balance, **only** in the first year #\(base + 4).
            - One reader was denied after an earlier bonus within 24 months #\(base + 5).
            """
        }.joined(separator: "\n\n")
    }

    private static func comment(_ index: Int) -> String {
        "<p>Data point \(index): opened the account in branch, funded it the same week and the bonus posted "
            + "after about \(60 + index % 40) days. My direct deposit came from a brokerage transfer of "
            + "$\(500 + index % 9 * 250) and it counted. The representative said the terms changed in the spring, "
            + "but the offer page still shows the old ones.</p>"
    }

    /// The probe's numbers (cumulative since launch).
    private func probe(_ app: XCUIApplication) -> [String: Int] {
        let element = any(app, "perfProbeState")
        XCTAssertTrue(element.waitForExistence(timeout: 10), "The perf probe element is missing (-dc-perf-probe)")
        var values: [String: Int] = [:]
        for field in element.label.split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let value = Int(parts[1]) { values[String(parts[0])] = value }
        }
        return values
    }

    private func delta(_ before: [String: Int], _ after: [String: Int], per count: Int, named name: String) -> String {
        let sizes: Set<String> = ["source_chars", "summary_chars", "posts", "runs"]
        let lines = after.keys.sorted().map { key -> String in
            if sizes.contains(key) { return "\(key)=\(after[key] ?? 0)" }
            let change = (after[key] ?? 0) - (before[key] ?? 0)
            return "\(key)=\(change) (\(String(format: "%.2f", Double(change) / Double(max(count, 1)))) per action)"
        }
        return "== \(name) (\(count) actions)\n" + lines.joined(separator: "\n")
    }

    private func summarizeAndMeasure(_ name: String, open url: String, summaryTimeout: TimeInterval) {
        let app = launch(["-dc-open", url, "-dc-fixture-model", server.baseURL, "-dc-perf-probe"])
        let summarize = app.buttons["suggestion-summarizeThread"].firstMatch
        // The page may still be loading when the drawer is first asked for: ask again.
        for _ in 0..<4 where !summarize.exists {
            showAssistant(in: app)
            _ = summarize.waitForExistence(timeout: 15)
        }
        XCTAssertTrue(waitOrDump(summarize, timeout: 20, in: app), "No summary offered.")
        XCTAssertTrue(waitForHittable(summarize))
        let started = Date()
        summarize.tap()
        XCTAssertTrue(wait(timeout: summaryTimeout) {
            self.any(app, "summaryContent").exists || self.any(app, "capabilityThreadSummaryCard").exists
        }, "The summary did not appear.")
        let status = any(app, "agentStatusLine")
        _ = wait(timeout: 120) { !status.exists }
        var report = ["case=\(name)", "summarize_seconds=\(Int(Date().timeIntervalSince(started)))"]
        RunLoop.current.run(until: Date().addingTimeInterval(3))

        // Nothing asked of the app: what the meter reads by itself.
        var before = probe(app)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        var after = probe(app)
        report.append(delta(before, after, per: 1, named: "idle 5 s"))

        // Typing, one character at a time.
        let box = any(app, "askBox")
        let input = box.textViews.firstMatch.exists ? box.textViews.firstMatch : box.textFields.firstMatch
        XCTAssertTrue(waitForHittable(input), "The composer is not hittable")
        input.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // `scripts/device-check.sh --xctrace <template>` starts recording at this line.
        print("XCTRACE-START \(name)")
        if ProcessInfo.processInfo.environment["DC_PERF_TRACE"] == "1" {
            RunLoop.current.run(until: Date().addingTimeInterval(10))
        }
        let keys = 30
        before = probe(app)
        let typingStarted = Date()
        for index in 0..<keys {
            input.typeText(String(UnicodeScalar(UInt8(97 + index % 26))))
        }
        let typingSeconds = Date().timeIntervalSince(typingStarted)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        after = probe(app)
        report.append("typing_wall_seconds=\(String(format: "%.1f", typingSeconds))")
        report.append(delta(before, after, per: keys, named: "typing"))

        // Scrolling the transcript.
        let scroll = any(app, "agentScroll")
        before = probe(app)
        for _ in 0..<6 { scroll.swipeUp() }
        for _ in 0..<6 { scroll.swipeDown() }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        after = probe(app)
        report.append(delta(before, after, per: 12, named: "scrolling"))

        // Closing and opening the drawer (phones and narrow windows).
        if usesDrawerLayout(app) {
            closeDrawer(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            before = probe(app)
            let openStarted = Date()
            showAssistant(in: app)
            XCTAssertTrue(any(app, "askBox").waitForExistence(timeout: 20), "The drawer did not reopen")
            let openSeconds = Date().timeIntervalSince(openStarted)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            after = probe(app)
            report.append("reopen_wall_seconds=\(String(format: "%.2f", openSeconds))")
            report.append(delta(before, after, per: 1, named: "reopening the drawer"))
        }

        let text = report.joined(separator: "\n")
        attachText(text, named: "long-thread-perf-\(name).txt")
        print("LONG-THREAD-PERF-BEGIN\n\(text)\nLONG-THREAD-PERF-END")
    }

    /// The control: the same steps on a thread of 20 comments.
    func testShortFixtureThread() {
        server.commentCount = 20
        server.commentBody = Self.comment
        server.summaryReply = Self.summary(posts: 20)
        summarizeAndMeasure("fixture-20", open: server.postURL, summaryTimeout: 120)
    }

    /// 6,000 comments, the size of the thread the owner reported.
    func testLongFixtureThread() {
        server.commentCount = 6_000
        server.commentBody = Self.comment
        server.summaryReply = Self.summary(posts: 6_000)
        summarizeAndMeasure("fixture-6000", open: server.postURL, summaryTimeout: 900)
    }

    /// A real page (`TEST_RUNNER_DC_PERF_URL`): its comments are read from the site, the summary
    /// text comes from the fixture model, so no model is called and nothing is saved.
    func testRealLongThread() throws {
        guard let url = ProcessInfo.processInfo.environment["DC_PERF_URL"], !url.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_DC_PERF_URL to a long thread's address to measure a real page.")
        }
        server.summaryReply = Self.summary(posts: 6_000)
        summarizeAndMeasure("real-page", open: url, summaryTimeout: 1_200)
    }
}
