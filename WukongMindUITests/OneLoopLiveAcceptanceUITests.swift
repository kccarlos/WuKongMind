import XCTest

/// One loop acceptance, live model (WUKO-70, design-one-loop.md "Acceptance checks" 1 and 8).
/// Skips without `TEST_RUNNER_ANTHROPIC_API_KEY`; uses `claude-haiku-5-5` only. Check 1 reads the
/// public Discourse forum meta.appinn.net (D3's thread), so it needs the network; check 8 uses the
/// built-in fixture page. Live debug launches never save, so nothing here outlives the app.
/// Evidence travels as attachments in the `.xcresult` (and to `TEST_RUNNER_ONE_LOOP_EVIDENCE_DIR`
/// on a simulator). On the shared phone, run only through `scripts/device-check.sh`.
final class OneLoopLiveAcceptanceUITests: DCUITestCase {
    private static let model = "claude-haiku-5-5"
    private static let multiStep = "Summarize this thread first, then check what other people on this forum say about point 2, then read it to me"

    private var apiKey: String {
        (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func evidence(_ name: String, _ text: String) {
        attachText(text, named: name)
        guard let dir = ProcessInfo.processInfo.environment["ONE_LOOP_EVIDENCE_DIR"], !dir.isEmpty else { return }
        try? text.write(toFile: dir + "/" + name + ".txt", atomically: true, encoding: .utf8)
    }

    private func launchLive(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["ANTHROPIC_API_KEY"] = apiKey
        app.launchArguments = ["-dc-skip-onboarding", "-dc-browser-agent-live-model", Self.model,
                               "-dc-drawer-detent", "large", "-AppleInterfaceStyle", "Light"] + extra
        app.launch()
        return app
    }

    /// Waits for the turn to end and returns the status line's text.
    private func waitForTurn(_ app: XCUIApplication, timeout: TimeInterval) -> String {
        let status = any(app, "agentStatusLine")
        _ = wait(timeout: timeout) {
            status.exists && ["Done", "Turn failed", "Stopped", "step limit"].contains { status.label.contains($0) }
        }
        return status.exists ? status.label : "(no status line)"
    }

    /// The run's ToolRow labels in order: a finished run folds its steps behind "N steps", and the
    /// conversation is lazy, so it opens the fold, then scrolls down collecting rows as they appear.
    private func toolRows(_ app: XCUIApplication) -> [String] {
        let fold = any(app, "agentStepsSummary")
        // The run sits below the topic's summary: scroll down to it.
        for _ in 0..<12 where !(fold.exists && fold.isHittable) { app.swipeUp() }
        if fold.exists, fold.value as? String == "Collapsed" { fold.tap() }
        var seen: [String] = []
        for _ in 0..<16 {
            for row in app.descendants(matching: .any).matching(identifier: "agentToolRow").allElementsBoundByIndex
            where row.exists && !seen.contains(row.label) { seen.append(row.label) }
            if any(app, "agentSources").exists && any(app, "agentSources").isHittable { break }
            app.swipeUp()
        }
        return seen
    }

    private func openHistory(_ app: XCUIApplication) {
        let more = app.buttons["assistantMoreMenu"].firstMatch
        XCTAssertTrue(waitOrDump(more, timeout: 10, in: app), "No assistant menu.")
        more.tap()
        // Menu items lose their identifiers in the menu's own window.
        let item = app.buttons.matching(NSPredicate(format: "identifier == 'openHistoryMenu' OR label == 'History'")).firstMatch
        XCTAssertTrue(waitOrDump(item, timeout: 10, in: app), "No History item in the menu.")
        item.tap()
        let asks = app.buttons["historySegment-asks"]
        if asks.waitForExistence(timeout: 10) { asks.tap() }
    }

    /// Types a request into the composer and sends it.
    private func type(_ text: String, in app: XCUIApplication) {
        let input = app.descendants(matching: .any)["agentPromptInput"].firstMatch
        XCTAssertTrue(waitOrDump(input, timeout: 10, in: app), "No composer.")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "The composer did not take focus.")
        app.typeText(text)
        app.buttons["agentSendButton"].firstMatch.tap()
        let status = any(app, "agentStatusLine")
        _ = wait(timeout: 15) { !(status.exists && status.label.contains("Done")) }
    }

    /// A History row opens with its Open button.
    private func openRow(_ row: XCUIElement) {
        let open = row.buttons.matching(label(contains: "Open")).firstMatch
        if open.exists { open.tap() } else { row.tap() }
    }

    /// Check 1 (typed) and check 8 (cited answer): one run does `summarize_topic`, `search_forum`,
    /// then `read_aloud`; the answer's citation chips open the cited thread; the answer is in History
    /// and opens read-only in `SavedAnswerView`.
    func testLiveMultiStepDiscourseRequest() throws {
        guard !apiKey.isEmpty else { throw XCTSkip("Set TEST_RUNNER_ANTHROPIC_API_KEY.") }
        try requireNetwork()
        // Typed as a person would: once the thread's suggestions show, the page is recognized and the
        // run gets the forum tools.
        // `TEST_RUNNER_ONE_LOOP_THREAD` picks another Discourse thread (default: D3's).
        let thread = ProcessInfo.processInfo.environment["ONE_LOOP_THREAD"].flatMap { $0.isEmpty ? nil : $0 } ?? "https://meta.appinn.net/t/18527"
        let host = URL(string: thread)?.host ?? "meta.appinn.net"
        let app = launchLive(["-dc-open", thread, "-dc-browser-agent-live-key"])
        showAssistant(in: app)
        let summarize = app.buttons["suggestion-summarizeThread"].firstMatch
        let recognized = summarize.waitForExistence(timeout: 90)
        capture("check1-recognized-thread")
        guard recognized else {
            showBrowser(in: app)
            capture("check1-unrecognized-browser")
            attachTree(app, named: "check1-unrecognized-tree")
            XCTFail("\(thread) was not recognized as a thread (no thread suggestions).")
            return
        }
        type(Self.multiStep, in: app)
        let status = waitForTurn(app, timeout: 420)
        capture("check1-after-run")
        let rows = toolRows(app)
        let reply = any(app, "agentAssistantReply")
        evidence("check1-run", "model: \(Self.model)\nstatus: \(status)\ntools:\n" + rows.joined(separator: "\n")
                 + "\nreply: \(reply.exists ? reply.label : "(none)")")
        XCTAssertTrue(status.contains("Done"), status)
        let order = ["Summarized thread", "Searched forum", "Reading aloud"].map { name in rows.firstIndex { $0.contains(name) } }
        XCTAssertFalse(order.contains(nil), "Missing a step: \(rows)")
        XCTAssertEqual(order.compactMap { $0 }, order.compactMap { $0 }.sorted(), "Steps out of order: \(rows)")
        XCTAssertTrue(any(app, "capabilityListenRow").exists, "No podcast row for read_aloud.")

        // A citation chip opens the cited thread in the browser.
        // The answer's numbered chips are links ("S2", identifier = the cited URL). Tap one that cites
        // another thread, and the browser opens that thread.
        let chips = app.links.matching(NSPredicate(format: "label BEGINSWITH 'S' AND identifier CONTAINS %@", "\(host)/t/"))
        attachTree(app, named: "check1-answer-tree")
        let all = chips.allElementsBoundByIndex
        evidence("check1-chips", all.map { "\($0.label) → \($0.identifier)" }.joined(separator: "\n"))
        let threadID = thread.split(separator: "/").last.map(String.init) ?? ""
        let other = all.first { !$0.identifier.contains("/\(threadID)") }
        let chip = try XCTUnwrap(other ?? all.first, "No citation chip in the answer.")
        let target = chip.identifier
        let topic = target.split(separator: "/").last { Int($0) != nil && $0.count > 3 }.map(String.init) ?? host
        if !chip.isHittable { _ = reveal(chip, in: app) }
        capture("check1-citations")
        chip.tap()
        let opened = wait(timeout: 20) { self.address(containing: topic, in: app).exists }
        capture("check1-chip-opened")
        evidence("check1-chip", "tapped \(chip.label) → \(target)\nbrowser address shows \(topic): \(opened)")
        XCTAssertTrue(opened, "The citation chip did not open \(target).")

        // Check 8: the cited answer is saved and opens read-only.
        showAssistant(in: app)
        openHistory(app)
        let row = any(app, "agentRunRow")
        XCTAssertTrue(waitOrDump(row, timeout: 15, in: app), "The cited answer is not in History.")
        capture("check8-history-cited")
        openRow(row)
        XCTAssertTrue(waitOrDump(any(app, "savedAnswerView"), timeout: 10, in: app), "SavedAnswerView did not open.")
        XCTAssertTrue(any(app, "savedAnswerQuestion").exists && any(app, "savedAnswerText").exists)
        XCTAssertFalse(app.textViews["agentPromptInput"].exists || app.textFields["agentPromptInput"].exists, "A saved answer has no composer.")
        capture("check8-saved-answer-cited")
        evidence("check8-cited", "question: \(any(app, "savedAnswerQuestion").label)\nsources: \(any(app, "savedAnswerSources").exists)")
    }

    /// Check 8 on an ordinary page: a short page-change turn saves nothing, a long answer is saved
    /// under "Other sites".
    func testLiveShortPageChangeIsNotSavedAndLongAnswerIs() throws {
        guard !apiKey.isEmpty else { throw XCTSkip("Set TEST_RUNNER_ANTHROPIC_API_KEY.") }
        let app = launchLive(["-dc-browser-agent-fixture-page", "-dc-browser-agent-live-prompt", "Make it dark"])
        let first = waitForTurn(app, timeout: 240)
        capture("check8-make-it-dark")
        // A reply of several paragraphs is several elements: join them.
        let darkText = app.descendants(matching: .any).matching(identifier: "agentAssistantReply").allElementsBoundByIndex
            .map(\.label).joined(separator: "\n")
        let darkLength = darkText.count
        evidence("check8-make-it-dark", "reply (\(darkLength) characters): \(darkText)")
        XCTAssertTrue(first.contains("Done"), first)

        type("In three short paragraphs, explain what this article argues and who it is for. Do not change the page.", in: app)
        let second = waitForTurn(app, timeout: 240)
        let reply = app.descendants(matching: .any).matching(identifier: "agentAssistantReply").allElementsBoundByIndex.last
        evidence("check8-ordinary-page", "model: \(Self.model)\nfirst turn: \(first)\nsecond turn: \(second)\nlong reply characters: \(reply?.label.count ?? 0)")
        XCTAssertTrue(second.contains("Done"), second)

        openHistory(app)
        let rows = app.descendants(matching: .any).matching(identifier: "agentRunRow")
        XCTAssertTrue(waitOrDump(rows.firstMatch, timeout: 15, in: app), "The long answer is not in History.")
        XCTAssertTrue(any(app, "historyOtherSites").exists, "No Other sites group.")
        capture("check8-history-other-sites")
        let rowTexts = rows.allElementsBoundByIndex.map { $0.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " · ") }
        evidence("check8-history", "rows: \(rows.count)\n" + rowTexts.joined(separator: "\n"))
        // The save rule (owner decision): sources, or 200 characters or more. A page-change reply under
        // 200 characters saves nothing; Haiku's confirmations land on either side of that line, so this
        // checks the rule rather than the model's length.
        let darkSaved = rowTexts.contains { $0.contains("Make it dark") }
        XCTAssertEqual(darkSaved, darkLength >= 200, "\"Make it dark\" (\(darkLength) characters) saved: \(darkSaved)")
        XCTAssertTrue(rowTexts.contains { $0.contains("three short paragraphs") }, "The long answer is not saved.")
        openRow(rows.firstMatch)
        XCTAssertTrue(waitOrDump(any(app, "savedAnswerView"), timeout: 10, in: app), "SavedAnswerView did not open.")
        capture("check8-saved-answer-long")
    }
}
