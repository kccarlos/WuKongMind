import Foundation
import XCTest
#if canImport(WukongMind)
@testable import WukongMind
#endif

/// Simulator-free unit tests for `MatchPattern`, `.user.js` serialization,
/// `ScriptStore` CRUD / versioning / rollback, and the five M2 script tools
/// in `ToolRegistry`. Runs in both `WukongMindAgentCoreTests` (macOS) and
/// `WukongMindTests` (iOS).
final class ScriptStoreCoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptStoreCoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - @match Parsing & Matching

    func testAllURLsPatternMatchesSupportedSchemesAndRejectsUnsafeSchemes() throws {
        let all = try MatchPattern.parse("<all_urls>")
        XCTAssertTrue(all.isAllURLs)
        XCTAssertTrue(all.matches(urlString: "http://example.com"))
        XCTAssertTrue(all.matches(urlString: "https://sub.example.com/a/b?x=1#frag"))
        XCTAssertTrue(all.matches(urlString: "file:///Users/kc/page.html"))
        XCTAssertTrue(all.matches(urlString: "ws://127.0.0.1:8080/socket"))
        XCTAssertTrue(all.matches(urlString: "wss://chat.example.org/live"))

        XCTAssertFalse(all.matches(urlString: "about:blank"))
        XCTAssertFalse(all.matches(urlString: "javascript:alert(1)"))
        XCTAssertFalse(all.matches(urlString: "data:text/html,<h1>hi</h1>"))
        XCTAssertFalse(all.matches(urlString: "mailto:test@example.com"))
    }

    func testSchemeHostWildcardPortAndPathGlobSemantics() throws {
        // 1. Scheme wildcards (* and http*) match http + https only
        let starScheme = try MatchPattern.parse("*://example.com/*")
        XCTAssertTrue(starScheme.matches(urlString: "http://example.com/"))
        XCTAssertTrue(starScheme.matches(urlString: "https://example.com/index.html"))
        XCTAssertFalse(starScheme.matches(urlString: "ws://example.com/index.html"))
        XCTAssertFalse(starScheme.matches(urlString: "file:///example.com/index.html"))

        let httpStar = try MatchPattern.parse("http*://example.com/*")
        XCTAssertTrue(httpStar.matches(urlString: "http://example.com"))
        XCTAssertTrue(httpStar.matches(urlString: "https://example.com/deep/path"))

        let httpsOnly = try MatchPattern.parse("https://example.com/*")
        XCTAssertFalse(httpsOnly.matches(urlString: "http://example.com/"))
        XCTAssertTrue(httpsOnly.matches(urlString: "https://EXAMPLE.COM/"))

        // 2. '*.example.com' matches both root domain and arbitrary subdomains,
        //    while rejecting lookalike suffixes such as 'badexample.com'.
        let wildcardSubdomain = try MatchPattern.parse("*://*.example.com/*")
        XCTAssertTrue(wildcardSubdomain.matches(urlString: "https://example.com"))
        XCTAssertTrue(wildcardSubdomain.matches(urlString: "https://www.example.com/"))
        XCTAssertTrue(wildcardSubdomain.matches(urlString: "http://a.b.c.example.com/thread/42"))
        XCTAssertFalse(wildcardSubdomain.matches(urlString: "https://badexample.com/"))
        XCTAssertFalse(wildcardSubdomain.matches(urlString: "https://example.com.evil.org/"))

        // 3. Exact host does not match subdomains; '*' host matches any host
        let exactHost = try MatchPattern.parse("https://news.example.com/*")
        XCTAssertTrue(exactHost.matches(urlString: "https://news.example.com/top"))
        XCTAssertFalse(exactHost.matches(urlString: "https://example.com/top"))
        XCTAssertFalse(exactHost.matches(urlString: "https://sub.news.example.com/top"))

        let anyHost = try MatchPattern.parse("*://*/*")
        XCTAssertTrue(anyHost.matches(urlString: "http://127.0.0.1:54321/fixture"))
        XCTAssertTrue(anyHost.matches(urlString: "https://forums.swift.org/t/hello/123"))

        // 4. Ports: omitted port matches any port; explicit port matches exact port; ':*' matches any port
        let noPort = try MatchPattern.parse("http://127.0.0.1/*")
        XCTAssertTrue(noPort.matches(urlString: "http://127.0.0.1:51234/test"))
        XCTAssertTrue(noPort.matches(urlString: "http://127.0.0.1/test"))

        let exactPort = try MatchPattern.parse("http://localhost:3000/*")
        XCTAssertTrue(exactPort.matches(urlString: "http://localhost:3000/app"))
        XCTAssertFalse(exactPort.matches(urlString: "http://localhost:4000/app"))
        XCTAssertFalse(exactPort.matches(urlString: "http://localhost/app"))

        let defaultHTTPSPort = try MatchPattern.parse("https://example.com:443/*")
        XCTAssertTrue(defaultHTTPSPort.matches(urlString: "https://example.com/home"))

        let starPort = try MatchPattern.parse("http://127.0.0.1:*/*")
        XCTAssertTrue(starPort.matches(urlString: "http://127.0.0.1:9090/ok"))
        XCTAssertTrue(starPort.matches(urlString: "http://127.0.0.1/ok"))

        // 5. Path globs, trailing slashes, literal '?' query matching, and ignored '#fragment'
        let subPath = try MatchPattern.parse("https://example.com/blog/*")
        XCTAssertTrue(subPath.matches(url: URL(string: "https://example.com/blog/")!))
        XCTAssertTrue(subPath.matches(url: URL(string: "https://example.com/blog/2026/post")!))
        XCTAssertFalse(subPath.matches(url: URL(string: "https://example.com/blog")!))
        XCTAssertFalse(subPath.matches(url: URL(string: "https://example.com/blogger")!))

        let queryPattern = try MatchPattern.parse("https://example.com/search?q=*&lang=en")
        XCTAssertTrue(queryPattern.matches(urlString: "https://example.com/search?q=swift+concurrency&lang=en#results"))
        XCTAssertFalse(queryPattern.matches(urlString: "https://example.com/searchXq=swift&lang=en"))
        XCTAssertFalse(queryPattern.matches(urlString: "https://example.com/search?q=swift&lang=fr"))

        let filePattern = try MatchPattern.parse("file:///Users/*/Documents/*.html")
        XCTAssertTrue(filePattern.matches(urlString: "file:///Users/alice/Documents/notes.html"))
        XCTAssertFalse(filePattern.matches(urlString: "file:///Users/alice/Documents/notes.txt"))
    }

    func testInvalidMatchPatternsAreRejected() {
        let invalidPatterns = [
            "",
            "   ",
            "*",
            "example.com/*",
            "https://example.com",
            "javascript://example.com/*",
            "data://example.com/*",
            "mailto:*",
            "https:///*",
            "https://*example.com/*",
            "https://sub.*.example.com/*",
            "https://example.*/*",
            "https://exa*mple.com/*",
            "http://localhost:0/*",
            "http://localhost:70000/*",
            "http://localhost:abc/*",
            "https://user:pass@example.com/*"
        ]

        for pattern in invalidPatterns {
            XCTAssertFalse(
                MatchPattern.isValid(pattern),
                "Expected invalid @match pattern to be rejected: \(pattern)"
            )
            XCTAssertThrowsError(try MatchPattern.parse(pattern))
        }
    }

    // MARK: - Userscript (.user.js) Header & Body Round-Trip

    func testUserScriptHeaderAndCSSJSBodyRoundTripLosslessly() throws {
        let created = Date(timeIntervalSince1970: 1_762_966_800.125)
        let updated = Date(timeIntervalSince1970: 1_762_967_400.875)

        let original = UserScript(
            id: "op-only-a1b2c3",
            name: "  Original Poster Only \\ Dark\tMode  ",
            matchRules: [
                "*://*.example.com/t/*",
                "https://forums.swift.org/t/*"
            ],
            js: """
            const op = document.querySelector('[data-op="true"]');
            if (op) {
              document.body.dataset.opAuthor = op.textContent.trim();
            }

            """,
            css: """
            body { background: #101216 !important; color: #f5f7fa !important; }
            /* Ensure closing tags </style> and ==/WukongCSS== inside strings stay intact */
            .reply::after { content: "</style> // ==/WukongCSS=="; }
            """,
            injectionTime: .documentStart,
            environment: .page,
            isEnabled: false,
            source: .agent(userPrompt: "  From now on,\nalways show only OP posts \\ dark mode  "),
            version: 4,
            createdAt: created,
            updatedAt: updated
        )

        let serialized = original.toUserScriptFileContent()
        XCTAssertTrue(serialized.hasPrefix("// ==UserScript==\n"))
        XCTAssertTrue(serialized.contains("// @match *://*.example.com/t/*"))
        XCTAssertTrue(serialized.contains("// @match https://forums.swift.org/t/*"))
        XCTAssertTrue(serialized.contains("// @run-at document-start"))
        XCTAssertTrue(serialized.contains("// @version 4"))
        XCTAssertTrue(serialized.contains("// @wukong-environment page"))
        XCTAssertTrue(serialized.contains("// @wukong-enabled false"))
        XCTAssertTrue(serialized.contains("// @wukong-source agent"))

        let reparsed = try UserScript.parseUserScriptFile(serialized)
        XCTAssertEqual(reparsed, original)

        // CSS-only and JS-only round-trips
        let cssOnly = UserScript(
            id: "css-only-1",
            name: "Hide Sidebar",
            matchRules: ["*://example.com/*"],
            js: "",
            css: "aside { display: none !important; }",
            createdAt: created,
            updatedAt: created
        )
        XCTAssertEqual(try UserScript.parseUserScriptFile(cssOnly.toUserScriptFileContent()), cssOnly)

        let jsOnly = UserScript(
            id: "js-only-1",
            name: "Expand Details",
            matchRules: ["*://example.com/*"],
            js: "document.querySelectorAll('details').forEach(d => d.open = true);",
            css: "",
            createdAt: created,
            updatedAt: created
        )
        XCTAssertEqual(try UserScript.parseUserScriptFile(jsOnly.toUserScriptFileContent()), jsOnly)
    }

    @MainActor
    func testImportingExternalTampermonkeyUserScriptUsesSensibleDefaults() throws {
        let store = ScriptStore(directoryURL: tempDirectory)
        let externalTampermonkey = """
        // ==UserScript==
        // @name         Greasy Fork Reader Width
        // @namespace    https://greasyfork.org/
        // @version      2.3.1
        // @description  Widens article column
        // @match        *://*.wikipedia.org/wiki/*
        // @run-at       document-idle
        // ==/UserScript==

        (function() {
            'use strict';
            document.documentElement.classList.add('wide-reader');
        })();
        """

        let imported = try store.importUserScript(externalTampermonkey)
        XCTAssertEqual(imported.name, "Greasy Fork Reader Width")
        XCTAssertEqual(imported.matchRules, ["*://*.wikipedia.org/wiki/*"])
        XCTAssertEqual(imported.injectionTime, .documentEnd)
        XCTAssertEqual(imported.environment, .isolated)
        XCTAssertTrue(imported.isEnabled)
        XCTAssertEqual(imported.source, .imported)
        XCTAssertEqual(imported.version, 2)
        XCTAssertTrue(imported.js.contains("wide-reader"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.scriptFileURL(for: imported.id).path))
    }

    // MARK: - ScriptStore Versioning, Rollback & Disk Reload

    @MainActor
    func testScriptStoreVersioningRollbackPersistenceAndRestore() throws {
        let store = ScriptStore(directoryURL: tempDirectory)

        let v1 = try store.create(
            id: "dark-reader",
            name: "Dark Reader",
            matchRules: ["*://*.example.com/*"],
            js: "document.body.dataset.ver = '1';",
            css: "body { background: #111; }",
            injectionTime: .documentEnd,
            environment: .isolated,
            source: .agent(userPrompt: "Always make example.com dark")
        )
        XCTAssertEqual(v1.version, 1)
        XCTAssertTrue(store.versions(for: v1.id).isEmpty)

        // Update to v2
        let v2 = try store.update(
            id: v1.id,
            patch: ScriptUpdatePatch(
                js: "document.body.dataset.ver = '2';",
                css: "body { background: #000; }",
                injectionTime: .documentStart
            )
        )
        XCTAssertEqual(v2.version, 2)
        XCTAssertEqual(store.versions(for: v1.id).map(\.version), [1])

        // Update to v3
        let v3 = try store.update(
            id: v1.id,
            patch: ScriptUpdatePatch(
                name: "Dark Reader Pro",
                matchRules: ["*://*.example.com/*", "https://news.example.org/*"],
                js: "document.body.dataset.ver = '3';"
            )
        )
        XCTAssertEqual(v3.version, 3)
        XCTAssertEqual(store.versions(for: v1.id).map(\.version), [1, 2])

        // Toggling enabled state updates disk without adding version clutter, and clears errors
        store.recordError(scriptID: v1.id, message: "ReferenceError: foo is not defined", line: 3)
        XCTAssertNotNil(store.error(for: v1.id))
        _ = try store.setEnabled(id: v1.id, isEnabled: false)
        XCTAssertNil(store.error(for: v1.id))
        XCTAssertEqual(store.versions(for: v1.id).map(\.version), [1, 2])

        // Reload in a brand-new ScriptStore instance (simulates app restart)
        let reloadedStore = ScriptStore(directoryURL: tempDirectory)
        let loaded = try XCTUnwrap(reloadedStore.script(id: "dark-reader"))
        XCTAssertEqual(loaded.version, 3)
        XCTAssertEqual(loaded.name, "Dark Reader Pro")
        XCTAssertFalse(loaded.isEnabled)
        XCTAssertEqual(loaded.source, .agent(userPrompt: "Always make example.com dark"))
        XCTAssertEqual(reloadedStore.versions(for: "dark-reader").map(\.version), [1, 2])

        // Rollback explicitly to v1 keeps v3 in history and restores v1's content
        let rolledToV1 = try reloadedStore.rollback(id: "dark-reader", toVersion: 1)
        XCTAssertEqual(rolledToV1.version, 4)
        XCTAssertEqual(rolledToV1.name, "Dark Reader")
        XCTAssertEqual(rolledToV1.matchRules, ["*://*.example.com/*"])
        XCTAssertEqual(rolledToV1.js, "document.body.dataset.ver = '1';")
        XCTAssertEqual(rolledToV1.css, "body { background: #111; }")
        XCTAssertEqual(rolledToV1.injectionTime, .documentEnd)
        XCTAssertEqual(reloadedStore.versions(for: "dark-reader").map(\.version), [1, 2, 3])

        // Default rollback (nil targetVersion) rolls back to most recent archived version (v3)
        let rolledBackToV3 = try reloadedStore.rollback(id: "dark-reader")
        XCTAssertEqual(rolledBackToV3.version, 5)
        XCTAssertEqual(rolledBackToV3.name, "Dark Reader Pro")
        XCTAssertEqual(rolledBackToV3.js, "document.body.dataset.ver = '3';")

        // Delete removes files on disk; restore puts both active file and history back
        let deletedSnapshot = try reloadedStore.delete(id: "dark-reader")
        XCTAssertNil(reloadedStore.script(id: "dark-reader"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloadedStore.scriptFileURL(for: "dark-reader").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloadedStore.versionsDirectoryURL(for: "dark-reader").path))

        try reloadedStore.restore(deletedSnapshot)
        let thirdStore = ScriptStore(directoryURL: tempDirectory)
        XCTAssertEqual(thirdStore.script(id: "dark-reader")?.version, 5)
        XCTAssertEqual(thirdStore.versions(for: "dark-reader").map(\.version), [1, 2, 3, 4])

        // Reject path-traversal IDs
        XCTAssertThrowsError(
            try thirdStore.create(
                id: "../escape",
                name: "Bad ID",
                matchRules: ["*://example.com/*"],
                css: "body {}"
            )
        )
    }

    // MARK: - M2 Script Tools Schema, Validation, Truncation & AgentLoop Turn

    private final class StubDriver: AgentPageDriving, @unchecked Sendable {
        var metadata = AgentPageMetadata(url: "https://sub.example.com/t/welcome/1", title: "Welcome Thread")
        var injectedCSSCalls: [(css: String, id: String?)] = []
        var ranJSCalls: [(code: String, environment: AgentExecutionEnvironment)] = []
        var nextJSError: String?

        func currentPageMetadata() async -> AgentPageMetadata { metadata }

        func readPage(mode: PageReadMode, selector: String?, maxLength: Int?) async throws -> String {
            "[article #post-1 data-op='true'] Original poster\n[article .reply] Commenter"
        }

        func runJS(
            code: String,
            environment: AgentExecutionEnvironment,
            timeout: TimeInterval
        ) async throws -> JSExecutionResult {
            ranJSCalls.append((code, environment))
            if let err = nextJSError {
                return JSExecutionResult(valueJSON: nil, consoleOutput: [], error: err)
            }
            return JSExecutionResult(valueJSON: "true", consoleOutput: [], error: nil)
        }

        func injectCSS(css: String, id: String?) async throws -> CSSInjectionResult {
            injectedCSSCalls.append((css, id))
            return CSSInjectionResult(sheetID: id ?? "sheet-1", appliedRootCount: 1)
        }

        func waitFor(selector: String?, milliseconds: Int?) async throws -> WaitForResult {
            WaitForResult(mode: .delay, matched: true, elapsedMs: milliseconds ?? 10, selector: selector)
        }
    }

    @MainActor
    func testM2ToolSchemasAndValidationRejectInvalidScriptToolArguments() async throws {
        let driver = StubDriver()
        let store = ScriptStore(directoryURL: tempDirectory)
        let registry = ToolRegistry.m2(bridge: driver, scriptStore: store)

        XCTAssertEqual(
            registry.definitions.map(\.name),
            [
                "read_page", "run_js", "inject_css", "wait_for",
                "script_save", "script_list", "script_read", "script_update", "script_delete"
            ]
        )

        // Verify array schema emits `"items": {"type": "string"}` for Anthropic/OpenAI/Gemini
        let saveDef = try XCTUnwrap(registry.definitions.first { $0.name == "script_save" })
        let props = try XCTUnwrap(saveDef.inputSchema["properties"]?.objectValue)
        let matchRulesSchema = try XCTUnwrap(props["match_rules"]?.objectValue)
        XCTAssertEqual(matchRulesSchema["type"], .string("array"))
        XCTAssertEqual(matchRulesSchema["items"], .object(["type": .string("string")]))

        // 1. Missing required 'match_rules'
        let missingRules = try await registry.dispatch(
            toolName: "script_save",
            arguments: ["name": .string("Dark"), "css": .string("body {}")]
        )
        XCTAssertTrue(missingRules.isError)
        XCTAssertTrue(missingRules.output.contains("match_rules"))

        // 2. Non-string inside 'match_rules'
        let nonStringRule = try await registry.dispatch(
            toolName: "script_save",
            arguments: [
                "name": .string("Dark"),
                "match_rules": .array([.int(42)]),
                "css": .string("body {}")
            ]
        )
        XCTAssertTrue(nonStringRule.isError)
        XCTAssertTrue(nonStringRule.output.contains("must be a string"))

        // 3. Invalid @match pattern rejected during validation
        let invalidMatch = try await registry.dispatch(
            toolName: "script_save",
            arguments: [
                "name": .string("Dark"),
                "match_rules": .array([.string("example.com/*")]),
                "css": .string("body {}")
            ]
        )
        XCTAssertTrue(invalidMatch.isError)
        XCTAssertTrue(invalidMatch.output.contains("invalid @match pattern"))

        // 4. Both js and css empty rejected
        let emptyBodies = try await registry.dispatch(
            toolName: "script_save",
            arguments: [
                "name": .string("Empty"),
                "match_rules": .array([.string("*://example.com/*")]),
                "js": .string("   "),
                "css": .string("")
            ]
        )
        XCTAssertTrue(emptyBodies.isError)
        XCTAssertTrue(emptyBodies.output.contains("non-empty 'js', 'css', or both"))

        // 5. Invalid injection_time enum
        let badInjectionTime = try await registry.dispatch(
            toolName: "script_save",
            arguments: [
                "name": .string("Dark"),
                "match_rules": .array([.string("*://example.com/*")]),
                "css": .string("body {}"),
                "injection_time": .string("onload")
            ]
        )
        XCTAssertTrue(badInjectionTime.isError)
        XCTAssertTrue(badInjectionTime.output.contains("document-start, document-end"))

        // 6. script_update with no mutable fields rejected (even with confirm_change: true)
        let emptyUpdate = try await registry.dispatch(
            toolName: "script_update",
            arguments: ["script_id": .string("some-id"), "confirm_change": .bool(true)]
        )
        XCTAssertTrue(emptyUpdate.isError)
        XCTAssertTrue(emptyUpdate.output.contains("at least one field to update"))

        // 7. confirm_change schema exposed on both script_save and script_update
        XCTAssertEqual(props["confirm_change"]?.objectValue?["type"], .string("boolean"))
        let updateDef = try XCTUnwrap(registry.definitions.first { $0.name == "script_update" })
        let updateProps = try XCTUnwrap(updateDef.inputSchema["properties"]?.objectValue)
        XCTAssertEqual(updateProps["confirm_change"]?.objectValue?["type"], .string("boolean"))
    }

    @MainActor
    func testScriptToolsFullLifecycleLiveApplicationAndTruncation() async throws {
        let driver = StubDriver()
        let store = ScriptStore(directoryURL: tempDirectory)
        let registry = ToolRegistry.m2(
            bridge: driver,
            scriptStore: store,
            currentUserPrompt: { "Always hide replies on example.com" },
            truncationLimit: 600,
            saveScriptsWithoutAsking: true
        )

        // 1. script_save saves to disk, records user prompt, and applies immediately to matching page
        let saveRes = try await registry.dispatch(
            toolName: "script_save",
            arguments: [
                "name": .string("OP Only"),
                "match_rules": .array([.string("*://*.example.com/*")]),
                "css": .string(".reply { display: none !important; }"),
                "js": .string("document.body.dataset.opFiltered = '1';"),
                "injection_time": .string("document-end"),
                "environment": .string("isolated")
            ]
        )
        XCTAssertFalse(saveRes.isError, saveRes.output)
        let savedObj = try JSONValue.parseObjectJSON(saveRes.output)
        let scriptID = try XCTUnwrap(savedObj["script_id"]?.stringValue)
        XCTAssertEqual(savedObj["version"], .int(1))
        XCTAssertEqual(savedObj["applied_to_current_page"], .bool(true))
        XCTAssertEqual(driver.injectedCSSCalls.count, 1)
        XCTAssertEqual(driver.ranJSCalls.count, 1)
        XCTAssertEqual(
            store.script(id: scriptID)?.source,
            .agent(userPrompt: "Always hide replies on example.com")
        )

        // Saving a script for a non-matching domain does NOT apply to current page
        let otherRes = try await registry.dispatch(
            toolName: "script_save",
            arguments: [
                "name": .string("Other Site"),
                "match_rules": .array([.string("https://other.org/*")]),
                "css": .string("header { display: none; }")
            ]
        )
        XCTAssertFalse(otherRes.isError)
        let otherObj = try JSONValue.parseObjectJSON(otherRes.output)
        XCTAssertEqual(otherObj["applied_to_current_page"], .bool(false))
        XCTAssertEqual(driver.injectedCSSCalls.count, 1)

        // 2. script_list (all vs domain filter)
        let listAll = try await registry.dispatch(toolName: "script_list", arguments: [:])
        XCTAssertFalse(listAll.isError)
        let listAllObj = try JSONValue.parseObjectJSON(listAll.output)
        XCTAssertEqual(listAllObj["count"], .int(2))

        let listDomain = try await registry.dispatch(
            toolName: "script_list",
            arguments: ["domain": .string("sub.example.com")]
        )
        let listDomainObj = try JSONValue.parseObjectJSON(listDomain.output)
        XCTAssertEqual(listDomainObj["count"], .int(1))

        // 3. script_update increments version and archives v1
        let largeComment = "// " + String(repeating: "x", count: 900)
        let updateRes = try await registry.dispatch(
            toolName: "script_update",
            arguments: [
                "script_id": .string(scriptID),
                "js": .string("document.body.dataset.opFiltered = '2';\n\(largeComment)")
            ]
        )
        XCTAssertFalse(updateRes.isError, updateRes.output)
        let updateObj = try JSONValue.parseObjectJSON(updateRes.output)
        XCTAssertEqual(updateObj["version"], .int(2))
        XCTAssertEqual(store.versions(for: scriptID).map(\.version), [1])

        // 4. script_read returns content and enforces ToolRegistry truncation marker when > limit
        let readRes = try await registry.dispatch(
            toolName: "script_read",
            arguments: ["script_id": .string(scriptID)]
        )
        XCTAssertFalse(readRes.isError)
        XCTAssertTrue(readRes.wasTruncated)
        XCTAssertTrue(readRes.output.contains("truncated, \(readRes.totalCharacterCount) characters in total"))

        // 5. script_delete removes script; second delete returns non-fatal error observation
        let delRes = try await registry.dispatch(
            toolName: "script_delete",
            arguments: ["script_id": .string(scriptID)]
        )
        XCTAssertFalse(delRes.isError)
        let delObj = try JSONValue.parseObjectJSON(delRes.output)
        XCTAssertEqual(delObj["deleted"], .bool(true))
        XCTAssertNil(store.script(id: scriptID))

        let delMissing = try await registry.dispatch(
            toolName: "script_delete",
            arguments: ["script_id": .string(scriptID)]
        )
        XCTAssertTrue(delMissing.isError)
        XCTAssertTrue(delMissing.output.contains("\"deleted\":false"))
    }

    // MARK: - Recorded Fake Model End-to-End Agent Session Test

    private final class ScriptedModelClient: AgentModelClient, @unchecked Sendable {
        var responses: [AgentModelTurnResponse]
        private(set) var capturedSystems: [String] = []

        init(_ responses: [AgentModelTurnResponse]) {
            self.responses = responses
        }

        func completeToolTurn(
            system: String,
            messages: [AgentModelTurn],
            tools: [AgentToolDefinition],
            configuration: ProviderConfiguration,
            provider: AIProvider,
            maxTokens: Int
        ) async throws -> AgentModelTurnResponse {
            capturedSystems.append(system)
            return responses.isEmpty ? AgentModelTurnResponse(text: "Done.") : responses.removeFirst()
        }
    }

    @MainActor
    func testRecordedAgentTurnReadsPageAndSavesPersistentUserscript() async throws {
        let driver = StubDriver()
        let store = ScriptStore(directoryURL: tempDirectory)

        let fakeClient = ScriptedModelClient([
            AgentModelTurnResponse(
                text: "Inspecting the thread structure first.",
                toolCalls: [
                    AgentModelToolCall(id: "call_1", name: "read_page", arguments: ["mode": .string("structure")])
                ],
                stopReason: "tool_use",
                usage: AgentTokenUsage(inputTokens: 180, outputTokens: 30)
            ),
            AgentModelTurnResponse(
                text: "",
                toolCalls: [
                    AgentModelToolCall(
                        id: "call_2",
                        name: "script_save",
                        arguments: [
                            "name": .string("Original poster only"),
                            "match_rules": .array([.string("*://*.example.com/t/*")]),
                            "css": .string("article.reply { display: none !important; }")
                        ]
                    )
                ],
                stopReason: "tool_use",
                usage: AgentTokenUsage(inputTokens: 260, outputTokens: 45)
            ),
            AgentModelTurnResponse(
                text: "Hidden non-OP replies and saved the script for example.com.",
                toolCalls: [],
                stopReason: "end_turn",
                usage: AgentTokenUsage(inputTokens: 320, outputTokens: 22)
            )
        ])

        var sessionRef: BrowserAgentSession?
        let session = BrowserAgentSession(
            pageDriver: driver,
            modelClient: fakeClient,
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
                    configuration: ProviderConfiguration(
                        model: "claude-haiku-5-5",
                        baseURL: AIProvider.anthropic.defaultBaseURL,
                        apiKey: "fake-recorded-key"
                    ),
                    maxSteps: 10,
                    truncationLimit: 20_000,
                    customInstructions: "",
                    redactedSecrets: [],
                    allScripts: store.scripts
                )
            },
            registryBuilder: { bridge, limit, secrets in
                ToolRegistry.m2(
                    bridge: bridge,
                    scriptStore: store,
                    currentUserPrompt: { sessionRef?.lastUserPrompt },
                    truncationLimit: limit,
                    redactedSecrets: secrets,
                    saveScriptsWithoutAsking: true
                )
            }
        )
        sessionRef = session

        await session.sendAndWait("From now on, show only the original poster on this site")

        XCTAssertEqual(session.toolCalls.map(\.toolName), ["read_page", "script_save"])
        XCTAssertTrue(session.toolCalls.allSatisfy { !$0.isError })
        XCTAssertEqual(store.scripts.count, 1)
        let saved = try XCTUnwrap(store.scripts.first)
        XCTAssertEqual(saved.name, "Original poster only")
        XCTAssertEqual(
            saved.source,
            .agent(userPrompt: "From now on, show only the original poster on this site")
        )
        XCTAssertEqual(driver.injectedCSSCalls.count, 1)
        XCTAssertTrue(fakeClient.capturedSystems.first?.contains("always do this") == true)
    }

    // MARK: - M2 UI Store Helpers

    @MainActor
    func testManagerGroupsSortByHostPreservingWildcardsAndAllSitesLast() throws {
        let store = ScriptStore(directoryURL: tempDirectory)

        try store.create(
            id: "all-sites-css",
            name: "Readable spacing",
            matchRules: ["*://*/*"],
            css: "body { line-height: 1.6; }"
        )
        try store.create(
            id: "talk-b",
            name: "Zebra quotes",
            matchRules: ["https://talk.example.org/*"],
            css: "blockquote { opacity: 0.9; }"
        )
        try store.create(
            id: "talk-a",
            name: "Alpha quotes",
            matchRules: ["https://talk.example.org/t/*"],
            css: "blockquote { border-left: 2px solid; }"
        )
        try store.create(
            id: "wildcard-org",
            name: "Subdomain helper",
            matchRules: ["*://*.example.org/*"],
            js: "void 0;"
        )

        let groups = store.managerGroups
        XCTAssertEqual(groups.map(\.host), ["*.example.org", "talk.example.org", nil])
        XCTAssertEqual(groups[0].scripts.map(\.id), ["wildcard-org"])
        XCTAssertEqual(groups[1].scripts.map(\.id), ["talk-a", "talk-b"])
        XCTAssertEqual(groups[2].scripts.map(\.id), ["all-sites-css"])
        XCTAssertEqual(groups[2].identifierHost, "all")
    }

    func testValidationErrorAndSanitizedExportFilename() {
        XCTAssertNil(MatchPattern.validationError("*://*.example.org/*"))
        XCTAssertNil(MatchPattern.validationError("<all_urls>"))
        XCTAssertEqual(MatchPattern.validationError("example.org/*"), .missingSchemeSeparator)
        XCTAssertEqual(MatchPattern.validationError("ftp://example.org/*"), .invalidScheme("ftp"))
        XCTAssertEqual(MatchPattern.validationError("https://example.org"), .missingPathSlash)

        XCTAssertEqual(
            UserScript.sanitizedExportFilename(from: "Original poster: v2/3"),
            "Original poster- v2-3.user.js"
        )
        XCTAssertEqual(
            UserScript.sanitizedExportFilename(from: "   ???   "),
            "script.user.js"
        )
    }

    @MainActor
    func testRuntimeErrorCountIncrementsAndClearsOnDisableOrUpdate() throws {
        let store = ScriptStore(directoryURL: tempDirectory)
        try store.create(
            id: "broken-js",
            name: "Broken JS",
            matchRules: ["*://example.com/*"],
            js: "null.foo();"
        )

        store.recordError(scriptID: "broken-js", message: "TypeError: null", line: 1, url: "https://example.com/")
        XCTAssertEqual(store.error(for: "broken-js")?.count, 1)

        store.recordError(scriptID: "broken-js", message: "TypeError: null", line: 1, url: "https://example.com/2")
        XCTAssertEqual(store.error(for: "broken-js")?.count, 2)

        try store.setEnabled(id: "broken-js", isEnabled: false)
        XCTAssertNil(store.error(for: "broken-js"))

        try store.setEnabled(id: "broken-js", isEnabled: true)
        store.recordError(scriptID: "broken-js", message: "ReferenceError: x", line: 3)
        XCTAssertEqual(store.error(for: "broken-js")?.count, 1)

        try store.update(id: "broken-js", patch: ScriptUpdatePatch(js: "console.log('fixed');"), origin: .editedByUser)
        XCTAssertNil(store.error(for: "broken-js"))
    }

    @MainActor
    func testVersionOriginPersistenceAndRestoreCleansNewerVersionFiles() throws {
        let store = ScriptStore(directoryURL: tempDirectory)
        let created = try store.create(
            id: "origin-test",
            name: "Origin test",
            matchRules: ["*://example.com/*"],
            css: "body { color: black; }",
            source: .agent(userPrompt: "Make text black")
        )
        let v1Snapshot = try XCTUnwrap(store.script(id: created.id))

        _ = try store.update(
            id: "origin-test",
            patch: ScriptUpdatePatch(css: "body { color: navy; }"),
            origin: .changedByAgent(userPrompt: "Switch text to navy")
        )
        _ = try store.update(
            id: "origin-test",
            patch: ScriptUpdatePatch(css: "body { color: #111; }"),
            origin: .editedByUser
        )
        let rolledBack = try store.rollback(id: "origin-test", toVersion: 1)
        XCTAssertEqual(rolledBack.version, 4)
        XCTAssertEqual(rolledBack.versionOrigin, .restored(fromVersion: 1))

        let reloaded = ScriptStore(directoryURL: tempDirectory)
        let loaded = try XCTUnwrap(reloaded.script(id: "origin-test"))
        XCTAssertEqual(loaded.version, 4)
        XCTAssertEqual(loaded.versionOrigin, .restored(fromVersion: 1))
        XCTAssertEqual(
            loaded.versions.map(\.origin),
            [
                nil,
                .changedByAgent(userPrompt: "Switch text to navy"),
                .editedByUser
            ]
        )

        // Restoring an earlier pre-update snapshot cleans up newer archived versions on disk.
        try reloaded.restore(v1Snapshot)
        let reloadedAgain = ScriptStore(directoryURL: tempDirectory)
        let restored = try XCTUnwrap(reloadedAgain.script(id: "origin-test"))
        XCTAssertEqual(restored.version, 1)
        XCTAssertTrue(restored.versions.isEmpty)
    }

    @MainActor
    func testThreeConsecutiveErrorLoadsAutoDisableAndCleanLoadResetsCount() throws {
        let store = ScriptStore(directoryURL: tempDirectory)
        try store.create(
            id: "flaky-script",
            name: "Flaky Script",
            matchRules: ["*://example.com/*"],
            js: "null.boom();"
        )

        // Load 1: even if two errors fire on the same loadID, consecutiveErrorLoads bumps once.
        store.recordPageLoadError(scriptID: "flaky-script", message: "TypeError: first", line: 2, loadID: "load-1")
        store.recordPageLoadError(scriptID: "flaky-script", message: "TypeError: duplicate on load-1", line: 2, loadID: "load-1")
        XCTAssertEqual(store.consecutiveErrorLoads["flaky-script"], 1)
        XCTAssertEqual(store.script(id: "flaky-script")?.isEnabled, true)

        // Load 2: second erroring load in a row.
        store.recordPageLoadError(scriptID: "flaky-script", message: "TypeError: second", line: 2, loadID: "load-2")
        XCTAssertEqual(store.consecutiveErrorLoads["flaky-script"], 2)
        XCTAssertEqual(store.script(id: "flaky-script")?.isEnabled, true)

        // Load 3: clean run resets the consecutive error-load count!
        store.recordPageLoadClean(scriptID: "flaky-script", loadID: "load-3")
        XCTAssertEqual(store.consecutiveErrorLoads["flaky-script"], 0)
        XCTAssertNil(store.error(for: "flaky-script"))

        // Loads 4 & 5: two errors after a clean load do NOT auto-disable yet.
        store.recordPageLoadError(scriptID: "flaky-script", message: "ReferenceError: missingNode", line: 7, loadID: "load-4")
        store.recordPageLoadError(scriptID: "flaky-script", message: "ReferenceError: missingNode", line: 7, loadID: "load-5")
        XCTAssertEqual(store.script(id: "flaky-script")?.isEnabled, true)
        XCTAssertNil(store.script(id: "flaky-script")?.disabledReason)

        // Load 6: third consecutive erroring load disables the script and persists disabledReason.
        store.recordPageLoadError(scriptID: "flaky-script", message: "ReferenceError: missingNode", line: 7, loadID: "load-6")
        let autoDisabled = try XCTUnwrap(store.script(id: "flaky-script"))
        XCTAssertFalse(autoDisabled.isEnabled)
        XCTAssertEqual(
            autoDisabled.disabledReason,
            "Turned off after errors on 3 page loads in a row: ReferenceError: missingNode"
        )
        // Latest error remains accessible for "Let the Agent fix it".
        XCTAssertEqual(store.error(for: "flaky-script")?.message, "ReferenceError: missingNode")

        // Persisted across ScriptStore reload from .user.js on disk.
        let reloaded = ScriptStore(directoryURL: tempDirectory)
        let persisted = try XCTUnwrap(reloaded.script(id: "flaky-script"))
        XCTAssertFalse(persisted.isEnabled)
        XCTAssertEqual(
            persisted.disabledReason,
            "Turned off after errors on 3 page loads in a row: ReferenceError: missingNode"
        )

        // Turning the script back on clears disabledReason.
        try reloaded.setEnabled(id: "flaky-script", isEnabled: true)
        XCTAssertNil(reloaded.script(id: "flaky-script")?.disabledReason)
        let reloadedAfterReenable = ScriptStore(directoryURL: tempDirectory)
        XCTAssertNil(reloadedAfterReenable.script(id: "flaky-script")?.disabledReason)
    }

    @MainActor
    func testAgentScriptCardUndoDisablesWithoutDeleting() throws {
        let storeURL = tempDirectory.appendingPathComponent("app-state/state.json")
        let store = ScriptStore(directoryURL: tempDirectory.appendingPathComponent("scripts", isDirectory: true))
        let created = try store.create(
            id: "undo-me",
            name: "Undo Me",
            matchRules: ["*://example.com/*"],
            css: "body { filter: invert(1); }"
        )
        let app = AppModel(
            store: PersistentStore(fileURL: storeURL),
            scriptStore: store
        )
        XCTAssertEqual(app.scriptStore.script(id: created.id)?.isEnabled, true)

        AgentScriptCardView.undoSavedScript(id: created.id, in: app)

        let afterUndo = try XCTUnwrap(app.scriptStore.script(id: created.id), "Undo disables the script rather than deleting it")
        XCTAssertFalse(afterUndo.isEnabled)
        XCTAssertNil(afterUndo.disabledReason)
    }
}

// MARK: - M4 Script Metadata & The File Format

@MainActor
extension ScriptStoreCoreTests {
    /// The `// @key value` lines between the markers, whitespace normalized.
    private func headerLines(of fileContent: String) -> [String] {
        var lines: [String] = []
        var inside = false
        for raw in fileContent.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "// ==UserScript==" { inside = true; continue }
            if line == "// ==/UserScript==" { break }
            guard inside, line.hasPrefix("//") else { continue }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@") else { continue }
            let parts = body.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            lines.append(parts.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
        }
        return lines
    }

    /// A header with every key in design-m4's Metadata table, as a published script writes it.
    private var publishedHeader: String {
        """
        // ==UserScript==
        // @name         Reader Width
        // @name:de      Leserbreite
        // @namespace    https://greasyfork.org/users/1234
        // @version      2.4.1
        // @description  Widens the article column
        // @author       Some Author
        // @homepage     https://example.org/reader-width
        // @match        *://*.example.org/wiki/*
        // @match        https://news.example.net/*
        // @include      /^https:\\/\\/old\\.example\\.org\\/.*$/
        // @exclude      *://*.example.org/wiki/Special:*
        // @exclude-match https://news.example.net/live/*
        // @run-at       document-idle
        // @grant        GM_getValue
        // @grant        GM_setValue
        // @grant        GM_xmlhttpRequest
        // @grant        GM_notification
        // @connect      api.example.org
        // @connect      cdn.example.net
        // @require      https://cdn.example.net/lib.js#sha256=abc
        // @inject-into  content
        // @noframes
        // @resource     logo https://example.org/logo.png
        // @antifeature  ads
        // @downloadURL  https://example.org/reader-width.user.js
        // @updateURL    https://example.org/reader-width.meta.js
        // @supportURL   https://example.org/support
        // @icon         https://example.org/icon.png
        // @x-vendor-key some value
        // @wukong-install-url https://example.org/reader-width.user.js
        // @wukong-upstream-hash 0123abcd
        // @wukong-locally-changed true
        // ==/UserScript==

        (function () { 'use strict'; document.title += '!'; })();
        """
    }

    func testPublishedHeaderExportsWithEveryHeaderLine() throws {
        let fixedTime = Date(timeIntervalSince1970: 1_700_000_000)
        let parsed = try UserScript.parseUserScriptFile(publishedHeader, defaultTimestamp: fixedTime)
        let exported = parsed.toUserScriptFileContent()

        let original = headerLines(of: publishedHeader)
        let written = headerLines(of: exported)
        for line in original {
            XCTAssertTrue(written.contains(line), "Missing from export: \(line)")
        }
        // Everything else in the export is the app's own bookkeeping.
        let extra = written.filter { !original.contains($0) }
        XCTAssertTrue(extra.allSatisfy { $0.hasPrefix("@wukong-") }, "\(extra)")
        XCTAssertTrue(extra.contains("@wukong-revision 2"))

        // The typed views read the same lines.
        XCTAssertEqual(parsed.metadata.grants, ["GM_getValue", "GM_setValue", "GM_xmlhttpRequest", "GM_notification"])
        XCTAssertEqual(parsed.metadata.connectHosts, ["api.example.org", "cdn.example.net"])
        XCTAssertEqual(parsed.metadata.requireURLs, ["https://cdn.example.net/lib.js#sha256=abc"])
        XCTAssertEqual(parsed.metadata.injectInto, "content")
        XCTAssertEqual(parsed.metadata.authorVersion, "2.4.1")
        XCTAssertEqual(parsed.metadata.installURL, "https://example.org/reader-width.user.js")
        XCTAssertEqual(parsed.metadata.upstreamHash, "0123abcd")
        XCTAssertTrue(parsed.metadata.locallyChanged)
        XCTAssertEqual(parsed.injectionTime, .documentEnd)

        // A second round trip changes nothing.
        let again = try UserScript.parseUserScriptFile(exported, defaultTimestamp: fixedTime)
        XCTAssertEqual(again, parsed)
        XCTAssertEqual(again.toUserScriptFileContent(), exported)
    }

    func testFilesWrittenBy13DecodeWithTheSameRevisionAndExportOneNewLine() throws {
        let oldFile = """
        // ==UserScript==
        // @name Hide replies
        // @match *://*.example.com/*
        // @run-at document-start
        // @version 7
        // @wukong-id hide-replies
        // @wukong-environment isolated
        // @wukong-enabled true
        // @wukong-source agent
        // @wukong-prompt Hide the replies
        // @wukong-version-origin changed-by-agent
        // @wukong-version-prompt Hide the replies
        // @wukong-created-at 2026-10-01T10:00:00.000Z
        // @wukong-updated-at 2026-10-02T11:30:00.000Z
        // ==/UserScript==
        document.body.dataset.x = '1';
        """
        let script = try UserScript.parseUserScriptFile(oldFile)
        XCTAssertEqual(script.version, 7)
        XCTAssertEqual(script.metadata, ScriptMetadata())
        XCTAssertEqual(script.injectionTime, .documentStart)

        let expected = oldFile.replacingOccurrences(
            of: "// @version 7\n",
            with: "// @version 7\n// @wukong-revision 7\n"
        )
        XCTAssertEqual(script.toUserScriptFileContent(), expected)

        // The version line keeps following the revision for a script with no version of its own.
        let store = ScriptStore(directoryURL: tempDirectory)
        let imported = try store.importUserScript(oldFile, now: Date(timeIntervalSince1970: 1_759_404_600))
        let update = try store.makeCandidateForUpdate(
            id: imported.id,
            patch: ScriptUpdatePatch(js: "document.body.dataset.x = '2';"),
            now: Date(timeIntervalSince1970: 1_760_000_000)
        )
        let committed = try store.commitUpdated(update)
        XCTAssertEqual(committed.version, 8)
        let lines = headerLines(of: committed.toUserScriptFileContent())
        XCTAssertTrue(lines.contains("@version 8"))
        XCTAssertTrue(lines.contains("@wukong-revision 8"))
        var expectedFromFile = committed
        expectedFromFile.versions = []
        XCTAssertEqual(try UserScript.parseUserScriptFile(committed.toUserScriptFileContent()), expectedFromFile)
        XCTAssertEqual(ScriptStore(directoryURL: tempDirectory).script(id: imported.id), committed)
    }

    func testAuthorVersionIsKeptAsWrittenAndRevisionCountsSeparately() throws {
        let file = """
        // ==UserScript==
        // @name Versioned
        // @match https://example.org/*
        // @version 3.0.0
        // @wukong-revision 5
        // ==/UserScript==
        console.log(1);
        """
        let store = ScriptStore(directoryURL: tempDirectory)
        let imported = try store.importUserScript(file)
        XCTAssertEqual(imported.version, 5)
        XCTAssertEqual(imported.metadata.authorVersion, "3.0.0")

        let update = try store.makeCandidateForUpdate(id: imported.id, patch: ScriptUpdatePatch(js: "console.log(2);"))
        let committed = try store.commitUpdated(update)
        XCTAssertEqual(committed.version, 6)
        let lines = headerLines(of: committed.toUserScriptFileContent())
        XCTAssertTrue(lines.contains("@version 3.0.0"))
        XCTAssertTrue(lines.contains("@wukong-revision 6"))

        // A whole-number author version from an install link is not mistaken for the revision.
        let installed = try UserScript.parseUserScriptFile("""
        // ==UserScript==
        // @name Installed
        // @match https://example.org/*
        // @version 1
        // @wukong-revision 1
        // @wukong-install-url https://example.org/a.user.js
        // ==/UserScript==
        console.log(1);
        """)
        XCTAssertEqual(installed.metadata.authorVersion, "1")
        var next = installed
        next.version = 2
        XCTAssertTrue(headerLines(of: next.toUserScriptFileContent()).contains("@version 1"))
    }

    func testRunAtIsLenientAndWrittenBackAsWrittenWhileItStillMeansTheSame() throws {
        func parse(_ runAt: String) throws -> UserScript {
            try UserScript.parseUserScriptFile("""
            // ==UserScript==
            // @name RunAt
            // @match https://example.org/*
            // @run-at \(runAt)
            // ==/UserScript==
            console.log(1);
            """)
        }
        let idle = try parse("document-idle")
        XCTAssertEqual(idle.injectionTime, .documentEnd)
        XCTAssertTrue(headerLines(of: idle.toUserScriptFileContent()).contains("@run-at document-idle"))

        let unknown = try parse("context-menu")
        XCTAssertEqual(unknown.injectionTime, .documentEnd)
        XCTAssertEqual(unknown.metadata.runAtText, "context-menu")
        XCTAssertTrue(headerLines(of: unknown.toUserScriptFileContent()).contains("@run-at context-menu"))

        // Once the time is changed here, the text no longer applies.
        var moved = unknown
        moved.injectionTime = .documentStart
        XCTAssertTrue(headerLines(of: moved.toUserScriptFileContent()).contains("@run-at document-start"))
        XCTAssertNil(try parse("document-start").metadata.runAtText)
    }

    func testExcludedURLsDoNotMatchAndUnusableExcludesAreReported() throws {
        let script = try UserScript.parseUserScriptFile("""
        // ==UserScript==
        // @name Excluding
        // @match *://*.example.org/*
        // @exclude *://*.example.org/admin/*
        // @exclude-match https://private.example.org/*
        // @exclude *://blocked.example.org/*
        // @exclude /regex-not-a-pattern/
        // ==/UserScript==
        console.log(1);
        """)
        XCTAssertTrue(script.matches(urlString: "https://www.example.org/wiki/A"))
        XCTAssertFalse(script.matches(urlString: "https://www.example.org/admin/users"))
        XCTAssertFalse(script.matches(url: URL(string: "https://private.example.org/x")!))
        XCTAssertTrue(script.matches(url: URL(string: "http://private.example.org/x")!))
        XCTAssertTrue(script.matchesDomain("www.example.org"))
        XCTAssertTrue(script.matchesDomain("private.example.org"))
        XCTAssertFalse(script.matchesDomain("blocked.example.org"))
        XCTAssertEqual(script.metadata.unusableExcludePatterns, ["/regex-not-a-pattern/"])
        XCTAssertTrue(headerLines(of: script.toUserScriptFileContent()).contains("@exclude /regex-not-a-pattern/"))

        // The injected matcher gets the excludes as vetoing rules.
        let descriptors = ScriptWebController.compiledRulesArray(for: script)
        XCTAssertEqual(descriptors.filter { $0["exclude"] as? Bool == true }.count, 3)
        XCTAssertEqual(descriptors.filter { $0["exclude"] == nil }.count, 1)
    }

    @MainActor
    func testMetadataSurvivesUpdateReloadHistoryAndRollback() throws {
        let store = ScriptStore(directoryURL: tempDirectory)
        let imported = try store.importUserScript(publishedHeader)
        XCTAssertEqual(imported.metadata.grants.count, 4)

        // A text-only update keeps every header line and marks the imported script as changed here.
        let first = try store.commitUpdated(
            try store.makeCandidateForUpdate(id: imported.id, patch: ScriptUpdatePatch(js: "document.title = 'x';"))
        )
        XCTAssertEqual(first.metadata.lines, imported.metadata.lines)
        XCTAssertTrue(first.metadata.locallyChanged)

        // New grants and connect hosts replace the old ones, while archived v1 keeps its own metadata.
        let second = try store.commitUpdated(
            try store.makeCandidateForUpdate(
                id: imported.id,
                patch: ScriptUpdatePatch(grants: ["GM_getValue"], connectHosts: ["api.example.org", "extra.example.org"])
            )
        )
        XCTAssertEqual(second.metadata.grants, ["GM_getValue"])
        XCTAssertEqual(second.metadata.connectHosts, ["api.example.org", "extra.example.org"])
        XCTAssertEqual(second.metadata.excludePatterns, imported.metadata.excludePatterns)

        let v1Archive = try XCTUnwrap(second.versions.first { $0.version == imported.version })
        XCTAssertEqual(v1Archive.toUserScript(from: second).metadata.connectHosts, ["api.example.org", "cdn.example.net"])

        // Rolling back to v1 restores v1's grants, connect hosts and code (dropping extra.example.org).
        let rolledBack = try store.rollback(id: imported.id, toVersion: imported.version)
        XCTAssertEqual(rolledBack.metadata.grants, imported.metadata.grants)
        XCTAssertEqual(rolledBack.metadata.connectHosts, ["api.example.org", "cdn.example.net"])
        XCTAssertEqual(rolledBack.metadata.authorVersion, "2.4.1")

        let reloaded = ScriptStore(directoryURL: tempDirectory)
        let loaded = try XCTUnwrap(reloaded.script(id: imported.id))
        XCTAssertEqual(loaded.metadata, rolledBack.metadata)
        XCTAssertEqual(loaded.version, rolledBack.version)
        let v3Archive = try XCTUnwrap(loaded.versions.first { $0.version == second.version })
        XCTAssertEqual(v3Archive.metadata.connectHosts, ["api.example.org", "extra.example.org"])
    }

    func testNewHeaderValuesDecodeFromOlderJSON() throws {
        let decoded = try JSONDecoder().decode(ScriptMetadata.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, ScriptMetadata())
        let parsed = try UserScript.parseUserScriptFile(publishedHeader)
        let metaData = try JSONEncoder().encode(parsed.metadata)
        XCTAssertEqual(try JSONDecoder().decode(ScriptMetadata.self, from: metaData).grants.count, 4)

        // A 1.3 UserScript JSON object without a "metadata" key still decodes cleanly.
        let fullData = try JSONEncoder().encode(parsed)
        var jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: fullData) as? [String: Any])
        jsonObject.removeValue(forKey: "metadata")
        let legacyData = try JSONSerialization.data(withJSONObject: jsonObject)
        let legacyDecoded = try JSONDecoder().decode(UserScript.self, from: legacyData)
        XCTAssertEqual(legacyDecoded.id, parsed.id)
        XCTAssertEqual(legacyDecoded.metadata, ScriptMetadata())
    }

    @MainActor
    func testScriptToolsAcceptValidateAndReturnGrantsAndHosts() async throws {
        let store = ScriptStore(directoryURL: tempDirectory)
        let registry = ToolRegistry.m2(bridge: StubDriver(), scriptStore: store, saveScriptsWithoutAsking: true)

        let saved = try await registry.dispatch(
            toolName: "script_save",
            arguments: [
                "name": .string("Fetcher"),
                "match_rules": .array([.string("https://example.org/*")]),
                "js": .string("GM_getValue('a');"),
                "grants": .array([.string("GM_getValue"), .string("GM_xmlhttpRequest"), .string("GM_getValue")]),
                "connect": .array([.string("API.Example.org"), .string("self"), .string("[::1]"), .string("*")])
            ]
        )
        XCTAssertFalse(saved.isError, saved.output)
        let savedObject = try JSONValue.parseObjectJSON(saved.output)
        let id = try XCTUnwrap(savedObject["script_id"]?.stringValue)
        XCTAssertEqual(savedObject["grants"], .array([.string("GM_getValue"), .string("GM_xmlhttpRequest")]))
        XCTAssertEqual(savedObject["connect"], .array([.string("api.example.org"), .string("self"), .string("::1"), .string("*")]))
        XCTAssertEqual(store.script(id: id)?.metadata.grants, ["GM_getValue", "GM_xmlhttpRequest"])
        XCTAssertEqual(store.script(id: id)?.metadata.connectHosts, ["api.example.org", "self", "::1", "*"])

        let read = try await registry.dispatch(toolName: "script_read", arguments: ["script_id": .string(id)])
        let readObject = try JSONValue.parseObjectJSON(read.output)
        XCTAssertEqual(readObject["grants"], .array([.string("GM_getValue"), .string("GM_xmlhttpRequest")]))
        XCTAssertEqual(readObject["connect"], .array([.string("api.example.org"), .string("self"), .string("::1"), .string("*")]))
        XCTAssertEqual(readObject["version"], .int(1))

        // Update replaces; "none" or an empty list clears grants.
        let updated = try await registry.dispatch(
            toolName: "script_update",
            arguments: ["script_id": .string(id), "grants": .array([.string("none")]), "connect": .array([.string("cdn.example.net")])]
        )
        XCTAssertFalse(updated.isError, updated.output)
        let updatedObject = try JSONValue.parseObjectJSON(updated.output)
        XCTAssertEqual(updatedObject["grants"], .array([]))
        XCTAssertEqual(updatedObject["connect"], .array([.string("cdn.example.net")]))
        XCTAssertEqual(store.script(id: id)?.metadata.grants, [])
        XCTAssertEqual(store.script(id: id)?.metadata.connectHosts, ["cdn.example.net"])
        XCTAssertEqual(store.script(id: id)?.version, 2)

        // Anything the app doesn't implement or can't read is refused, and nothing is saved.
        let badArguments: [(String, [String: JSONValue])] = [
            ("grants", ["grants": .array([.string("GM_notification")])]),
            ("grants", ["grants": .array([.string("unsafeWindow")])]),
            ("grants", ["grants": .string("GM_getValue")]),
            ("connect", ["connect": .array([.string("*.example.org")])]),
            ("connect", ["connect": .array([.string("https://example.org/path")])]),
            ("connect", ["connect": .array([.string("example.org:8080")])]),
            ("connect", ["connect": .array([.string("[:::]")])]),
            ("connect", ["connect": .array([.string("exa mple.org")])])
        ]
        for (name, extra) in badArguments {
            var arguments: [String: JSONValue] = [
                "name": .string("Bad"),
                "match_rules": .array([.string("https://example.org/*")]),
                "js": .string("1;")
            ]
            arguments.merge(extra) { $1 }
            let result = try await registry.dispatch(toolName: "script_save", arguments: arguments)
            XCTAssertTrue(result.isError, "\(extra)")
            XCTAssertTrue(result.output.contains("'\(name)'"), result.output)
        }
        XCTAssertEqual(store.scripts.count, 1)
    }
}
