import Foundation
import XCTest
#if canImport(Forumind)
@testable import Forumind
#endif

/// Simulator-free unit tests for `MatchPattern`, `.user.js` serialization,
/// `ScriptStore` CRUD / versioning / rollback, and the five M2 script tools
/// in `ToolRegistry`. Runs in both `ForumindAgentCoreTests` (macOS) and
/// `ForumindTests` (iOS).
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

        // 6. script_update with no mutable fields rejected
        let emptyUpdate = try await registry.dispatch(
            toolName: "script_update",
            arguments: ["script_id": .string("some-id")]
        )
        XCTAssertTrue(emptyUpdate.isError)
        XCTAssertTrue(emptyUpdate.output.contains("at least one field to update"))
    }

    @MainActor
    func testScriptToolsFullLifecycleLiveApplicationAndTruncation() async throws {
        let driver = StubDriver()
        let store = ScriptStore(directoryURL: tempDirectory)
        let registry = ToolRegistry.m2(
            bridge: driver,
            scriptStore: store,
            currentUserPrompt: { "Always hide replies on example.com" },
            truncationLimit: 600
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
                    redactedSecrets: secrets
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
}
