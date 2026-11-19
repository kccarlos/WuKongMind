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
    /// The drawer-open tests time the sheet as people see it, animations on.
    private var animated = false
    override var disablesAnimations: Bool { !animated }

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
        "<p>Data point \(index): opened the account in branch, funded it the same week — the bonus posted "
            + "after about \(60 + index % 40) days. My direct deposit came from a brokerage transfer of "
            + "$\(500 + index % 9 * 250) and it counted. The representative said the terms changed in the spring, "
            + "but the offer page still shows the “old” ones, so I’m not sure 😕.</p>"
    }

    /// The probe's numbers (cumulative since launch).
    private func probe(_ app: XCUIApplication) -> [String: Int] {
        let element = any(app, "perfProbeState")
        if !element.waitForExistence(timeout: 10) { attachTree(app, named: "No perf probe") }
        XCTAssertTrue(element.exists, "The perf probe element is missing (-dc-perf-probe)")
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
        // The card shows while the thread is still being read: wait for the saved summary.
        let saved = wait(timeout: summaryTimeout) { (self.probe(app)["summary_chars"] ?? 0) > 0 }
        let status = any(app, "agentStatusLine")
        _ = wait(timeout: 120) { !status.exists }
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            print("LONG-THREAD-PERF \(name) | " + line.replacingOccurrences(of: "\n", with: "\nLONG-THREAD-PERF \(name) | "))
        }
        note("case=\(name) summary_saved=\(saved) summarize_seconds=\(Int(Date().timeIntervalSince(started)))")
        RunLoop.current.run(until: Date().addingTimeInterval(3))

        // Nothing asked of the app: what the meter reads by itself.
        var before = probe(app)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        var after = probe(app)
        note(delta(before, after, per: 1, named: "idle 5 s"))

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
        note("typing_wall_seconds=\(String(format: "%.1f", typingSeconds))")
        note(delta(before, after, per: keys, named: "typing"))

        // Scrolling the transcript.
        let scroll = any(app, "agentScroll")
        before = probe(app)
        // Up only: a swipe down at the top would drag the drawer shut.
        for _ in 0..<8 { scroll.swipeUp() }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        after = probe(app)
        note(delta(before, after, per: 8, named: "scrolling"))

        // Closing and opening the drawer (phones and narrow windows).
        if usesDrawerLayout(app) {
            // The probe lives in the drawer: read it before closing, so this covers close and reopen.
            before = probe(app)
            closeDrawer(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let openStarted = Date()
            showAssistant(in: app)
            XCTAssertTrue(any(app, "askBox").waitForExistence(timeout: 20), "The drawer did not reopen")
            let openSeconds = Date().timeIntervalSince(openStarted)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            after = probe(app)
            note("reopen_wall_seconds=\(String(format: "%.2f", openSeconds))")
            note(delta(before, after, per: 1, named: "closing and reopening the drawer"))
        }

        attachText(report.joined(separator: "\n"), named: "long-thread-perf-\(name).txt")
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

    // MARK: Drawer open, Share and Export (docs/wukongmind/design-performance-2.md)

    /// The app's record of its last touch (`PerfTimeline`): milliseconds from the touch down.
    private func timeline(_ app: XCUIApplication) -> String {
        let element = any(app, "perfTimeline")
        return element.waitForExistence(timeout: 10) ? element.label : "missing"
    }

    private func point(_ frame: CGRect, in app: XCUIApplication) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
    }

    /// Taps, asks the app nothing while it works (an accessibility query costs main-thread time), then reads.
    private func tapAndReadTimeline(_ app: XCUIApplication, at point: XCUICoordinate, wait seconds: TimeInterval = 4.5) -> String {
        point.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        return timeline(app)
    }

    /// Tap to first drawer frame (first open on the page, then repeated opens on the summarized
    /// thread), then Share and Export .txt from the summary's menu with screenshots over 15 s.
    private func measureOpenShareExport(_ name: String, open url: String, summaryTimeout: TimeInterval, settle: TimeInterval) {
        animated = true
        let app = launch(["-dc-open", url, "-dc-fixture-model", server.baseURL, "-dc-perf-probe"])
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            print("DRAWER-OPEN-PERF \(name) | \(line)")
        }
        let button = app.buttons["aiButton"]
        XCTAssertTrue(waitForBarItem(button, timeout: 60), "No AI button.")
        // The page finishes loading and goes quiet.
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let opener = point(button.frame, in: app)

        // 1. The first open after launch.
        note("first_open " + tapAndReadTimeline(app, at: opener))

        let summarize = app.buttons["suggestion-summarizeThread"].firstMatch
        for _ in 0..<4 where !summarize.exists {
            showAssistant(in: app)
            _ = summarize.waitForExistence(timeout: 15)
        }
        XCTAssertTrue(waitOrDump(summarize, timeout: 20, in: app), "No summary offered.")
        XCTAssertTrue(waitForHittable(summarize))
        summarize.tap()
        XCTAssertTrue(wait(timeout: summaryTimeout) {
            self.any(app, "summaryContent").exists || self.any(app, "capabilityThreadSummaryCard").exists
        }, "The summary did not appear.")
        _ = wait(timeout: summaryTimeout) { (self.probe(app)["summary_chars"] ?? 0) > 0 }
        let status = any(app, "agentStatusLine")
        _ = wait(timeout: 120) { !status.exists }
        let sizes = probe(app)
        note("source_chars=\(sizes["source_chars"] ?? 0) summary_chars=\(sizes["summary_chars"] ?? 0) posts=\(sizes["posts"] ?? 0) runs=\(sizes["runs"] ?? 0)")

        // 2. Repeated opens on the summarized thread.
        closeDrawer(in: app)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        // `scripts/device-check.sh --xctrace <template>` starts recording at this line.
        print("XCTRACE-START \(name)")
        if ProcessInfo.processInfo.environment["DC_PERF_TRACE"] == "1" {
            RunLoop.current.run(until: Date().addingTimeInterval(10))
        }
        for index in 0..<6 {
            note("open_\(index) " + tapAndReadTimeline(app, at: opener))
            closeDrawer(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }

        // 3. Share and Export .txt from the summary's menu, at the large height unless
        // `TEST_RUNNER_DC_PERF_DETENT=medium` (the height the drawer opens at).
        let atMedium = ProcessInfo.processInfo.environment["DC_PERF_DETENT"] == "medium"
        showAssistant(in: app)
        if !atMedium { dragDrawer(in: app, to: 0.05) }
        note("share_export_detent=\(drawerState(in: app).label)")
        let more = app.buttons["summaryMoreMenu"].firstMatch
        if !more.waitForExistence(timeout: 10) { attachTree(app, named: "\(name)-no-summary-menu") }
        XCTAssertTrue(more.exists, "The summary's menu is missing.")
        for (action, label) in [("shareExport", "Share"), ("exportExport", "Export .txt")] {
            if !drawerState(in: app).exists {
                showAssistant(in: app)
                if !atMedium { dragDrawer(in: app, to: 0.05) }
            }
            note("\(action) detent before=\(drawerState(in: app).label)")
            // The menu sits under the summary: scroll to it.
            let scroll = any(app, "agentScroll")
            for _ in 0..<14 where !more.isHittable { scroll.swipeUp(velocity: .slow) }
            if !more.isHittable { attachTree(app, named: "\(name)-menu-not-hittable") }
            XCTAssertTrue(waitForHittable(more), "The summary's menu is not hittable before \(action).")
            more.tap()
            // Menu items answer to their titles, not their identifiers.
            let item = app.buttons[label].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), "\(action) is missing from the menu.")
            note("\(action) enabled=\(item.isEnabled)")
            let target = point(item.frame, in: app)
            let before = probe(app)
            let started = Date()
            target.tap()
            for (index, seconds) in [0.5, 1, 2, 4, 8, 15].enumerated() {
                let remaining = started.addingTimeInterval(seconds).timeIntervalSinceNow
                if remaining > 0 { RunLoop.current.run(until: Date().addingTimeInterval(remaining)) }
                capture("\(name)-\(action)-\(index)-at-\(seconds)s")
                note("\(action) screenshot \(index) asked at \(seconds)s taken at \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            }
            note("\(action) timeline " + timeline(app))
            // The drawer's probe is out of reach under a system sheet.
            let probeElement = any(app, "perfProbeState")
            if probeElement.exists { note(delta(before, probe(app), per: 1, named: "\(action), 15 s")) }
            // What the system put up.
            let wanted = ["Copy", "Close", "Save", "Move", "Cancel", "Save to Files", "Open", "Browse", "Recents", "Done"]
            note("\(action) system buttons: " + wanted.filter { app.buttons[$0].firstMatch.exists }.joined(separator: ","))
            note("\(action) ActivityListView=\(any(app, "ActivityListView").exists) navigationBars=\(app.navigationBars.allElementsBoundByIndex.map(\.identifier).joined(separator: ","))")
            capture("\(name)-\(action)-final")
            // Away again.
            var dismissed = false
            for label in ["Close", "Cancel"] where !dismissed {
                let dismiss = app.buttons[label].firstMatch
                if dismiss.exists, dismiss.isHittable { dismiss.tap(); dismissed = true }
            }
            // No button: a tap above the sheet closes it.
            if !dismissed { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(2.5))
            capture("\(name)-\(action)-after-dismiss")
        }
        attachText(report.joined(separator: "\n"), named: "drawer-open-perf-\(name).txt")
    }

    func testOpenShareExportShortThread() {
        server.commentCount = 20
        server.commentBody = Self.comment
        server.summaryReply = Self.summary(posts: 20)
        measureOpenShareExport("fixture-20", open: server.postURL, summaryTimeout: 120, settle: 6)
    }

    func testOpenShareExportLongThread() {
        server.commentCount = 6_000
        server.commentBody = Self.comment
        server.summaryReply = Self.summary(posts: 6_000)
        measureOpenShareExport("fixture-6000", open: server.postURL, summaryTimeout: 900, settle: 6)
    }

    func testOpenShareExportRealThread() throws {
        guard let url = ProcessInfo.processInfo.environment["DC_PERF_URL"], !url.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_DC_PERF_URL to a long thread's address to measure a real page.")
        }
        server.summaryReply = Self.summary(posts: 6_000)
        measureOpenShareExport("real-page", open: url, summaryTimeout: 1_200, settle: 20)
    }

    /// Screenshots of the drawer at medium and large heights in light and dark appearance.
    func testCaptureDrawerScreenshots() throws {
        guard ProcessInfo.processInfo.environment["DC_SCREENSHOT_DIR"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_DC_SCREENSHOT_DIR to capture drawer screenshots.")
        }
        try skipUnlessPhone("Drawer height screenshots require phone layout.")
        let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-dc-sample", "-dc-page-state", "topic"]
        for detent in ["medium", "large"] {
            for (suffix, style) in [("light", "Light"), ("dark", "Dark")] {
                let app = launch(base + ["-dc-drawer-detent", detent, "-AppleInterfaceStyle", style])
                XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 20))
                XCTAssertTrue(any(app, "summaryContent").waitForExistence(timeout: 15))
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                capture("drawer-\(detent)-\(suffix)")
                app.terminate()
            }
        }
    }
}
