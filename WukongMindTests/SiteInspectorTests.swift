import XCTest
@testable import WukongMind

/// The site inspector's logic (design-learn-on-ask.md "Developer mode, part 2"). The shape check and a
/// real trial run on the fixture site are in `SiteToolVerifierTests`, which owns the WebKit harness.
@MainActor
final class SiteInspectorTests: XCTestCase {
    private func pageTool(_ source: PageToolSource, name: String = "search_posts", owner: String? = nil,
                          readOnly: Bool = false, schema: JSONValue? = nil) -> PageTool {
        PageTool(
            source: source, ownerID: owner, name: name,
            prefixedName: source == .site ? "site.\(name)" : "script.\(owner ?? "x").\(name)",
            title: nil, description: "d", inputSchema: schema, inputSchemaJSON: nil,
            annotations: PageToolAnnotations(readOnlyHint: readOnly)
        )
    }

    func testASiteToolWarnsBeforeATrialEvenWhenItClaimsToBeReadOnly() {
        for readOnly in [false, true] {
            let row = SiteInspectorTool(tool: pageTool(.site, readOnly: readOnly), kind: .site)
            XCTAssertTrue(row.warnsBeforeTrial, "readOnlyHint \(readOnly) must never skip the warning")
        }
        XCTAssertFalse(SiteInspectorTool(tool: pageTool(.script, owner: "s1"), kind: .script(name: "S")).warnsBeforeTrial)
    }

    func testToolsAreClassifiedBySource() {
        var state = SiteToolState(host: "bbs.example.net")
        state.setSlot(SiteSlotState(status: .broken, scriptID: "learned1"), for: .listLatest)
        let snapshot = PageToolSnapshot(tools: [
            pageTool(.site), pageTool(.script, name: "list_latest", owner: "learned1"),
            pageTool(.script, name: "list_latest", owner: "other"), pageTool(.script, name: "export_md", owner: "other")
        ], droppedCount: 0, nativeModelContextDetected: false)
        let scripts = [UserScript(id: "learned1", name: "Thread reader", matchRules: ["*://bbs.example.net/*"])]
        let rows = SiteInspectorTool.rows(snapshot: snapshot, state: state, scripts: scripts)
        XCTAssertEqual(rows[0].kind, .site)
        XCTAssertEqual(rows[1].kind, .learned(slot: .listLatest, scriptName: "Thread reader", status: .broken))
        guard case .script = rows[2].kind, case .script = rows[3].kind else { return XCTFail("other scripts are plain script tools") }
    }

    func testArgumentSkeletonFollowsTheSchemaAndSurvivesJunk() throws {
        let schema = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["query": .object(["type": .string("string")]), "limit": .object(["type": .string("integer")])])
        ])
        let parsed = try XCTUnwrap(ToolTrialArguments.parse(ToolTrialArguments.skeleton(schema: schema)))
        XCTAssertEqual(parsed["query"], .string(""))
        XCTAssertEqual(parsed["limit"], .int(0))
        for junk in [nil, .string("x"), .array([]), .object(["type": .array([.string("object")])]), .object(["properties": .int(3)])] as [JSONValue?] {
            XCTAssertEqual(ToolTrialArguments.skeleton(schema: junk), "{}")
        }
        var deep = JSONValue.object(["type": .string("string")])
        for _ in 0..<12 { deep = .object(["type": .string("object"), "properties": .object(["a": deep])]) }
        XCTAssertFalse(ToolTrialArguments.skeleton(schema: deep).isEmpty)
        XCTAssertNil(ToolTrialArguments.parse("[1]"))
        XCTAssertNil(ToolTrialArguments.parse("{nope"))
    }

    func testTrialLineIsAToolCallThatKeepsNoResultAndRedactsSecrets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AuditLog(directory: dir)
        log.append(.toolTrial(host: "bbs.example.net", tool: "site.search_posts", argumentsJSON: #"{"token":"s3cret"}"#, time: Date(),
                              pageURL: "https://bbs.example.net/", durationMs: 12, resultBytes: 4_096, errorMessage: nil, secrets: ["s3cret"]))
        log.append(.toolTrial(host: "bbs.example.net", tool: "site.search_posts", argumentsJSON: "{}", time: Date(),
                              pageURL: nil, durationMs: 3, resultBytes: nil, errorMessage: "tool threw", secrets: []))
        log.flush()
        let lines = log.allLines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(log.stepCount, 2, "a trial run counts as a tool call")
        XCTAssertFalse(lines[0].arguments?.contains("s3cret") ?? true)
        XCTAssertEqual(lines[0].resultSummary, "trial run · 4096 bytes")
        XCTAssertEqual(lines[0].isError, false)
        XCTAssertEqual(lines[1].isError, true)
        XCTAssertEqual(log.days().first?.tasks.first?.steps.count, 2)
    }

    func testForgetClearsTheStateAndKeepsOneLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SiteToolStateStore(directoryURL: dir)
        var state = SiteToolState(host: "bbs.example.net")
        state.setSlot(SiteSlotState(status: .learned, scriptID: "s1"), for: .readTopic)
        state.appendLog(SiteLogEntry(kind: .learned, slot: .readTopic, date: Date(), taskID: "t1"))
        try store.save(state)
        SiteInspectorState.forget(host: "bbs.example.net", store: store)
        let after = try XCTUnwrap(store.state(forHost: "bbs.example.net"))
        XCTAssertEqual(after.slot(.readTopic).status, .untried)
        XCTAssertNil(after.slot(.readTopic).scriptID)
        XCTAssertEqual(after.log.map(\.kind), [.forgotten])
    }

    func testStateSavedBeforeTheInspectorStillDecodes() throws {
        let old = #"{"date":0,"url":"https://a.example/t-1","result":"ok","counts":[3]}"#
        let check = try JSONDecoder().decode(SiteSlotCheck.self, from: Data(old.utf8))
        XCTAssertNil(check.steps)
        var withSteps = check
        withSteps.steps = [SiteVerificationStepResult(step: 1, name: "Registered", status: .passed, detail: nil)]
        let round = try JSONDecoder().decode(SiteSlotCheck.self, from: JSONEncoder().encode(withSteps))
        XCTAssertEqual(round.steps?.count, 1)
    }
}
