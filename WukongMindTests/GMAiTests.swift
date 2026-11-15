import WebKit
import XCTest
@testable import WukongMind

@MainActor
final class GMAiTests: XCTestCase {
    private final class NavWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        func wait(_ trigger: () -> Void) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                trigger()
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume(); continuation = nil
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error); continuation = nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error); continuation = nil
        }
    }

    private struct WebHarness {
        let store: ScriptStore
        let window: UIWindow
        let webView: WKWebView
        let bridge: AgentBridge
        let controller: ScriptWebController
        let waiter: NavWaiter
        let auditDir: URL
        let auditLog: AuditLog
        let aiService: GMAiService
    }

    private static let sharedDataStore = WKWebsiteDataStore.nonPersistent()
    private var tempDir: URL!
    private var activeHarnesses: [WebHarness] = []

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GMAiTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for h in activeHarnesses {
            h.controller.detach()
            h.webView.stopLoading()
            h.webView.navigationDelegate = nil
            h.webView.configuration.userContentController.removeAllUserScripts()
            h.webView.configuration.userContentController.removeAllScriptMessageHandlers()
            h.webView.removeFromSuperview()
            h.window.isHidden = true
            h.window.rootViewController = nil
            h.window.windowScene = nil
        }
        activeHarnesses.removeAll()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func readySnapshot(
        provider: AIProvider = .anthropic,
        model: String = "claude-haiku-5-5",
        globalOn: Bool = true,
        aiOn: Bool = true,
        readiness: ModelReadiness = .ready,
        appleBackend: AppleIntelligenceBackend? = nil
    ) -> GMAiRuntimeSnapshot {
        let cfg = ProviderConfiguration(model: model, baseURL: provider.defaultBaseURL, apiKey: "test-key")
        return GMAiRuntimeSnapshot(
            isGlobalScriptsEnabled: globalOn,
            isScriptsAIEnabled: aiOn,
            selection: ModelSelection(provider: provider, model: model),
            configuration: cfg,
            readiness: readiness,
            appleIntelligenceBackend: appleBackend
        )
    }

    private func makeWebHarness(
        runtime: @escaping () -> GMAiRuntimeSnapshot,
        liveAIService: AIService = AIService()
    ) -> WebHarness {
        let base = tempDir.appendingPathComponent("Env-\(UUID().uuidString)", isDirectory: true)
        let store = ScriptStore(directoryURL: base.appendingPathComponent("Scripts", isDirectory: true))
        let auditDir = base.appendingPathComponent("Audit", isDirectory: true)
        let audit = AuditLog(directory: auditDir)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.sharedDataStore
        ForumBrowserModel.disableWebKitScreenTimeForTesting(in: config)
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: frame)
        window.frame = frame
        let vc = UIViewController()
        vc.view.frame = window.bounds
        let webView = WKWebView(frame: vc.view.bounds, configuration: config)
        vc.view.addSubview(webView)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let bridge = AgentBridge(webView: webView)
        let waiter = NavWaiter()
        webView.navigationDelegate = waiter
        let controller = ScriptWebController(webView: webView, store: store, agentBridge: bridge)
        let gmAi = GMAiService(cache: store.aiCache, limiter: store.aiLimiter, aiService: liveAIService, auditLog: audit, runtimeProvider: runtime)
        controller.gmBridge.aiService = gmAi
        controller.gmBridge.auditLog = audit
        let h = WebHarness(store: store, window: window, webView: webView, bridge: bridge, controller: controller, waiter: waiter, auditDir: auditDir, auditLog: audit, aiService: gmAi)
        activeHarnesses.append(h)
        return h
    }

    private func loadPage(_ h: WebHarness, url: String = "https://talk.example.org/t/topic/42", html: String = "<html><body><article data-post-id='1'>Hello</article></body></html>") async throws {
        try await h.waiter.wait {
            h.webView.loadHTMLString(html, baseURL: URL(string: url)!)
        }
    }

    // MARK: - 1. Three API Forms, Retry & All Error Codes over WKWebView

    func testThreeAPIFormsCodeFenceStrippingAndSingleRetryOverWKWebView() async throws {
        var snap = readySnapshot()
        let h = makeWebHarness(runtime: { snap })
        var seenCalls: [(system: String, messages: [ChatMessage], maxTokens: Int)] = []
        var scriptedReplies: [String] = [
            "Summary line for the post.",
            "not json at all",
            "```json\n{\"onTopic\": true, \"tags\": [\"swift\"]}\n```",
            "```json\n{\"p1\": true, \"p2\": false}\n```"
        ]
        h.aiService.completionRunner = { system, messages, _, _, maxTokens in
            seenCalls.append((system, messages, maxTokens))
            let reply = scriptedReplies.removeFirst()
            return GMAiCompletionResult(text: reply, usage: AgentTokenUsage(inputTokens: 120, outputTokens: 30))
        }

        let script = try h.store.create(
            id: "ai-forms",
            name: "Forum Judge",
            matchRules: ["https://talk.example.org/*"],
            js: "window.__wkReady = true;",
            grants: ["GM_ai"]
        )
        try await loadPage(h)
        let world = GMBridge.world(for: script.id)

        let textOut = try await h.webView.callAsyncJavaScript(
            "return await GM_ai('Summarize in one line: hello');",
            contentWorld: world
        ) as? String
        XCTAssertEqual(textOut, "Summary line for the post.")
        XCTAssertEqual(seenCalls.first?.maxTokens, 1_024)
        XCTAssertEqual(seenCalls.first?.system, GMAiService.baseSystemPrompt)

        // Form 2: JSON Schema with 1st-attempt mismatch -> automatic retry with error -> fenced JSON accepted.
        let objOut = try await h.webView.callAsyncJavaScript(
            """
            return await GM_ai(
              'Check topic',
              {
                type: 'object',
                properties: {
                  onTopic: { type: 'boolean' },
                  tags: { type: 'array', items: { type: 'string' } }
                },
                required: ['onTopic']
              }
            );
            """,
            contentWorld: world
        ) as? [String: Any]
        XCTAssertEqual(objOut?["onTopic"] as? Bool, true)
        XCTAssertEqual(objOut?["tags"] as? [String], ["swift"])
        XCTAssertEqual(seenCalls.count, 3, "Mismatch on first attempt must retry once with validation error")
        XCTAssertEqual(seenCalls[2].messages.count, 3)
        XCTAssertTrue(seenCalls[2].messages[2].content.contains("Invalid JSON"))

        // Form 3: GM_ai.map with {id, text} items; p3 omitted by model stays absent from result.
        let mapOut = try await h.webView.callAsyncJavaScript(
            """
            return await GM_ai.map(
              [
                { id: 'p1', text: 'Detailed benchmark comparing WebKit content worlds.' },
                { id: 'p2', text: '+1 thanks!' },
                { id: 'p3', text: 'Unclear fragment' }
              ],
              'Does this post add substance?',
              { type: 'boolean' }
            );
            """,
            contentWorld: world
        ) as? [String: Any]
        XCTAssertEqual(mapOut?["p1"] as? Bool, true)
        XCTAssertEqual(mapOut?["p2"] as? Bool, false)
        XCTAssertNil(mapOut?["p3"], "Items omitted by the model must be absent from the map result")
        XCTAssertEqual(seenCalls.last?.maxTokens, 4_096)
        XCTAssertNil(h.store.error(for: script.id))
    }

    func testAllSevenErrorCodesRejectWithGMAiErrorAndNeverDisableScript() async throws {
        var snap = readySnapshot()
        let h = makeWebHarness(runtime: { snap })
        h.aiService.limiter.limits.timeout = .milliseconds(80)

        let script = try h.store.create(
            id: "ai-errors",
            name: "Error Probe",
            matchRules: ["https://talk.example.org/*"],
            js: "window.__probe = true;",
            grants: ["GM_ai"]
        )
        try await loadPage(h)
        let world = GMBridge.world(for: script.id)

        func captureError(_ jsExpr: String) async throws -> [String: String] {
            let res = try await h.webView.callAsyncJavaScript(
                """
                try {
                  await (\(jsExpr));
                  return { ok: 'unexpected' };
                } catch (e) {
                  return { name: String(e.name), code: String(e.code), message: String(e.message) };
                }
                """,
                contentWorld: world
            ) as? [String: String]
            return try XCTUnwrap(res)
        }

        // 1. off (AI in scripts switch off, and global switch off)
        snap.isScriptsAIEnabled = false
        let offAI = try await captureError("GM_ai('hello')")
        XCTAssertEqual(offAI["name"], "GMAiError")
        XCTAssertEqual(offAI["code"], "off")

        snap.isScriptsAIEnabled = true
        snap.isGlobalScriptsEnabled = false
        let offGlobal = try await captureError("GM_ai('hello')")
        XCTAssertEqual(offGlobal["code"], "off")
        snap.isGlobalScriptsEnabled = true

        // 2. no_model
        snap.readiness = .needsKey
        let noModel = try await captureError("GM_ai('hello')")
        XCTAssertEqual(noModel["name"], "GMAiError")
        XCTAssertEqual(noModel["code"], "no_model")
        snap.readiness = .ready

        // 3. too_long (> 24,000 chars)
        let tooLong = try await captureError("GM_ai('x'.repeat(24001))")
        XCTAssertEqual(tooLong["code"], "too_long")

        // 4. invalid_output (both attempts fail schema)
        h.aiService.completionRunner = { _, _, _, _, _ in
            GMAiCompletionResult(text: "{\"count\": \"wrong\"}", usage: nil)
        }
        let invalid = try await captureError("GM_ai('count?', { type: 'object', properties: { count: { type: 'integer' } }, required: ['count'] })")
        XCTAssertEqual(invalid["code"], "invalid_output")

        // 5. timeout
        h.aiService.completionRunner = { _, _, _, _, _ in
            try await Task.sleep(for: .milliseconds(400))
            return GMAiCompletionResult(text: "late", usage: nil)
        }
        let timedOut = try await captureError("GM_ai('slow question')")
        XCTAssertEqual(timedOut["code"], "timeout")

        // 6. provider
        struct DummyProviderFailure: LocalizedError { var errorDescription: String? { "HTTP 503 upstream overloaded" } }
        h.aiService.completionRunner = { _, _, _, _, _ in throw DummyProviderFailure() }
        let providerErr = try await captureError("GM_ai('provider fail')")
        XCTAssertEqual(providerErr["code"], "provider")
        XCTAssertTrue(providerErr["message"]?.contains("503") == true)

        // 7. limit (invalid_output counted initial + retry = 2 calls, plus timeout + provider = 4 calls)
        XCTAssertEqual(h.store.aiCache.usageToday(for: script.id).calls, 4)
        h.aiService.limiter.limits.callsPerScriptPerMinute = 4
        let limitErr = try await captureError("GM_ai('over limit')")
        XCTAssertEqual(limitErr["code"], "limit")

        // Service errors must never count against script health or auto-disable the script.
        XCTAssertNil(h.store.error(for: script.id))
        XCTAssertEqual(h.store.consecutiveErrorLoads[script.id, default: 0], 0)
        XCTAssertEqual(h.store.script(id: script.id)?.isEnabled, true)
    }

    func testUngrantedGMAiThrowsInIsolatedAndPageWorlds() async throws {
        let h = makeWebHarness(runtime: { self.readySnapshot() })
        let noGrantIsolated = try h.store.create(
            id: "no-grant-iso",
            name: "No Grant Isolated",
            matchRules: ["https://talk.example.org/*"],
            js: "window.__isomarker = 1;",
            grants: ["GM_getValue"]
        )
        let pageScript = try h.store.create(
            id: "page-world",
            name: "Page World",
            matchRules: ["https://talk.example.org/*"],
            js: """
            try { GM_ai('hi'); } catch (e) { document.body.dataset.gmAiErr = e.message; }
            try { GM_ai.map([], 'hi'); } catch (e) { document.body.dataset.gmAiMapErr = e.message; }
            """,
            environment: .page
        )
        _ = pageScript
        try await loadPage(h)

        let isoErr = try await h.webView.callAsyncJavaScript(
            "try { await GM_ai('hi'); return 'ok'; } catch (e) { return e.message; }",
            contentWorld: GMBridge.world(for: noGrantIsolated.id)
        ) as? String
        XCTAssertEqual(isoErr, "`GM_ai` needs `@grant GM_ai`")

        let pageDataset = try await h.webView.callAsyncJavaScript(
            "return [document.body.dataset.gmAiErr, document.body.dataset.gmAiMapErr];",
            contentWorld: .page
        ) as? [String]
        XCTAssertEqual(pageDataset, ["`GM_ai` needs `@grant GM_ai`", "`GM_ai` needs `@grant GM_ai`"])
    }

    func testFourLevelJSONSchemaValidationAndIgnoredKeywords() {
        // Depth 0 (object) -> Depth 1 (level2) -> Depth 2 (level3/deepBox) -> Depth 3 (level4 enum/level4Box) -> Depth 4 (level5Ignored)
        let schemaJSON = """
        {
          "type": "object",
          "required": ["level2"],
          "additionalProperties": false,
          "properties": {
            "level2": {
              "type": "object",
              "required": ["level3"],
              "properties": {
                "level3": {
                  "type": "array",
                  "items": {
                    "type": "string",
                    "enum": ["keep", "fold"],
                    "minLength": 99
                  }
                },
                "deepBox": {
                  "type": "object",
                  "properties": {
                    "level4Box": {
                      "type": "object",
                      "properties": {
                        "level5Ignored": { "type": "number" }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """
        let schema = try! JSONDecoder().decode(JSONValue.self, from: Data(schemaJSON.utf8))
        let validVal = try! JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"level2":{"level3":["fold"],"deepBox":{"level4Box":{"level5Ignored":"notANumberAtDepth4"}}},"extra":1}"#.utf8)
        )
        XCTAssertNil(GMAiSchema.validate(validVal, against: schema), "Unknown keywords and depth >= 4 must be ignored")

        let invalidLevel4 = try! JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"level2":{"level3":["other"]}}"#.utf8)
        )
        XCTAssertNotNil(GMAiSchema.validate(invalidLevel4, against: schema), "4th level enum must be enforced")
    }

    // MARK: - 2. Per-Item Caching, Repair Survival & Disk Privacy

    func testPerItemCacheMakesZeroCallsOnRepeatAndOneCallForChangedItemWithNoTextOnDisk() async throws {
        var now = Date(timeIntervalSince1970: 1_763_200_000)
        let h = makeWebHarness(runtime: { self.readySnapshot() })
        h.aiService.clock = { now }
        var seenPrompts: [String] = []
        h.aiService.completionRunner = { _, messages, _, _, _ in
            let prompt = messages.last?.content ?? ""
            seenPrompts.append(prompt)
            if seenPrompts.count == 1 {
                return GMAiCompletionResult(text: #"{"101": true, "102": false}"#, usage: AgentTokenUsage(inputTokens: 80, outputTokens: 20))
            }
            return GMAiCompletionResult(text: #"{"102": true}"#, usage: AgentTokenUsage(inputTokens: 40, outputTokens: 10))
        }

        let secretPostA = "SECRET_POST_ALPHA_UNIQUE_TEXT"
        let secretPostB = "SECRET_POST_BETA_UNIQUE_TEXT"
        let secretInstruction = "SECRET_INSTRUCTION_MARKER"
        var script = try h.store.create(
            id: "discourse-fold",
            name: "Fold Empty Posts",
            matchRules: ["https://talk.example.org/*"],
            js: "// v1",
            grants: ["GM_ai"]
        )

        // 1st call: 2 items -> 1 model call
        let first = try await h.aiService.map(
            script: script,
            pageKey: "p1",
            pageURL: "https://talk.example.org/t/1",
            items: [GMAiMapItem(id: "101", text: secretPostA), GMAiMapItem(id: "102", text: secretPostB)],
            instruction: secretInstruction,
            format: .schema(.object(["type": .string("boolean")]))
        )
        XCTAssertEqual(first, ["101": .bool(true), "102": .bool(false)])
        XCTAssertEqual(seenPrompts.count, 1)

        // Simulate a repair updating script revision -> cache must survive revision bump.
        script = try h.store.update(id: script.id, patch: ScriptUpdatePatch(js: "// v2 repaired"), origin: .changedByAgent(userPrompt: "fix"))
        XCTAssertEqual(script.version, 2)

        // 2nd call with identical items -> 0 model calls!
        let second = try await h.aiService.map(
            script: script,
            pageKey: "p1",
            pageURL: "https://talk.example.org/t/1",
            items: [GMAiMapItem(id: "101", text: secretPostA), GMAiMapItem(id: "102", text: secretPostB)],
            instruction: secretInstruction,
            format: .schema(.object(["type": .string("boolean")]))
        )
        XCTAssertEqual(second, first)
        XCTAssertEqual(seenPrompts.count, 1, "Second call with same items must make zero model calls")

        // 3rd call with 101 unchanged and 102 edited -> 1 model call containing ONLY 102!
        let editedPostB = secretPostB + " (edited with benchmarks)"
        let third = try await h.aiService.map(
            script: script,
            pageKey: "p1",
            pageURL: "https://talk.example.org/t/1",
            items: [GMAiMapItem(id: "101", text: secretPostA), GMAiMapItem(id: "102", text: editedPostB)],
            instruction: secretInstruction,
            format: .schema(.object(["type": .string("boolean")]))
        )
        XCTAssertEqual(seenPrompts.count, 2, "One changed item must make exactly one model call")
        XCTAssertFalse(seenPrompts[1].contains(secretPostA), "Cached item must be omitted from the batch")
        XCTAssertTrue(seenPrompts[1].contains(editedPostB))
        XCTAssertEqual(third, ["101": .bool(true), "102": .bool(true)])

        let usage = h.store.aiCache.usageToday(for: script.id, now: now)
        XCTAssertEqual(usage, ScriptAICache.UsageToday(calls: 2, cacheHits: 3))

        // Disk privacy check: neither cache file nor audit file holds prompt, instruction or post text.
        let diskCacheText = try String(contentsOf: h.store.aiCache.fileURL(for: script.id), encoding: .utf8)
        XCTAssertFalse(diskCacheText.contains(secretPostA))
        XCTAssertFalse(diskCacheText.contains(secretPostB))
        XCTAssertFalse(diskCacheText.contains(secretInstruction))

        h.auditLog.flush()
        let auditFiles = (try? FileManager.default.contentsOfDirectory(at: h.auditDir, includingPropertiesForKeys: nil)) ?? []
        let auditText = auditFiles.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        XCTAssertFalse(auditText.isEmpty)
        XCTAssertFalse(auditText.contains(secretPostA))
        XCTAssertFalse(auditText.contains(secretInstruction))
        let aiAuditLines = h.auditLog.allLines().filter { $0.kind == .scriptAI }
        XCTAssertEqual(aiAuditLines.count, 3)
        XCTAssertEqual(aiAuditLines[1].itemsAsked, 2)
        XCTAssertEqual(aiAuditLines[1].itemsFromCache, 2)
        XCTAssertNil(aiAuditLines[1].tokensIn)
        XCTAssertEqual(aiAuditLines[2].tokensIn, 40)
        XCTAssertEqual(aiAuditLines[2].tokensOut, 10)

        // Delete + Undo restores cache; Clear AI cache deletes it; TTL expires after 30 days.
        let removed = try h.store.delete(id: script.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.store.aiCache.fileURL(for: script.id).path))
        try h.store.restore(removed)
        XCTAssertEqual(h.store.aiCache.cachedEntryCount(for: script.id, now: now), 3)

        now = now.addingTimeInterval(31 * 24 * 60 * 60)
        XCTAssertEqual(h.store.aiCache.cachedEntryCount(for: script.id, now: now), 0, "Entries older than 30 days must expire")
    }

    func testCacheCapsAtFiveThousandNewestEntries() {
        let cache = ScriptAICache(directoryURL: tempDir.appendingPathComponent("CapCache", isDirectory: true))
        let baseTime = Date(timeIntervalSince1970: 1_763_200_000)
        let firstBatch = (0..<3_000).map { ("k-\($0)", JSONValue.int($0)) }
        let secondBatch = (3_000..<5_200).map { ("k-\($0)", JSONValue.int($0)) }
        cache.store(entries: firstBatch, scriptID: "cap-script", now: baseTime)
        cache.store(entries: secondBatch, scriptID: "cap-script", now: baseTime.addingTimeInterval(10))

        XCTAssertEqual(cache.cachedEntryCount(for: "cap-script", now: baseTime.addingTimeInterval(20)), 5_000)
        XCTAssertNotNil(cache.lookup(scriptID: "cap-script", keyHash: "k-5199", now: baseTime.addingTimeInterval(20)))
    }

    // MARK: - 3. Batching (40 Items, 12,000 Chars, 2,000-Char Item Cut, Apple Intelligence Context)

    func testBatchingRespectsItemCharacterTruncationAndAppleIntelligenceContextBudgets() async throws {
        var snap = readySnapshot()
        let h = makeWebHarness(runtime: { snap })
        let script = try h.store.create(id: "batcher", name: "Batcher", matchRules: ["https://talk.example.org/*"], js: "//", grants: ["GM_ai"])

        var batchSizes: [Int] = []
        var seenUserPrompts: [String] = []
        h.aiService.completionRunner = { _, messages, _, _, _ in
            let prompt = messages.last?.content ?? ""
            seenUserPrompts.append(prompt)
            let markerCount = prompt.components(separatedBy: "\"id\":").count - 1
            batchSizes.append(markerCount)
            return GMAiCompletionResult(text: "{}", usage: nil)
        }

        // 85 short items -> 40 + 40 + 5
        let eightyFive = (0..<85).map { GMAiMapItem(id: "i\($0)", text: "short \($0)") }
        _ = try await h.aiService.map(script: script, pageKey: "p", pageURL: nil, items: eightyFive, instruction: "Judge", format: .schema(.object(["type": .string("boolean")])))
        XCTAssertEqual(batchSizes, [40, 40, 5])

        // 10 items of 1,500 chars each (15,000 chars total) -> 8 items (12,000 chars) + 2 items (3,000 chars)
        batchSizes.removeAll()
        let mediumItems = (0..<10).map { idx in
            GMAiMapItem(id: "m\(idx)", text: String(repeating: Character(UnicodeScalar(65 + idx)!), count: 1_500))
        }
        _ = try await h.aiService.map(script: script, pageKey: "p", pageURL: nil, items: mediumItems, instruction: "Judge", format: .schema(.object(["type": .string("boolean")])))
        XCTAssertEqual(batchSizes, [8, 2])

        // Single 2,600-char item -> truncated to 2,000 chars in prompt, but full text used in cache key
        seenUserPrompts.removeAll()
        let prefix2000 = String(repeating: "P", count: 2_000)
        let tailA = prefix2000 + "_TAIL_ONE"
        let tailB = prefix2000 + "_TAIL_TWO"
        h.aiService.completionRunner = { _, messages, _, _, _ in
            seenUserPrompts.append(messages.last?.content ?? "")
            return GMAiCompletionResult(text: #"{"long": true}"#, usage: nil)
        }
        _ = try await h.aiService.map(script: script, pageKey: "p", pageURL: nil, items: [GMAiMapItem(id: "long", text: tailA)], instruction: "Cut?", format: .schema(.object(["type": .string("boolean")])))
        XCTAssertFalse(seenUserPrompts[0].contains("_TAIL_ONE"), "Item text beyond 2,000 characters must be cut in prompt")
        _ = try await h.aiService.map(script: script, pageKey: "p", pageURL: nil, items: [GMAiMapItem(id: "long", text: tailB)], instruction: "Cut?", format: .schema(.object(["type": .string("boolean")])))
        XCTAssertEqual(seenUserPrompts.count, 2, "Cache key must hash full un-truncated item text")

        // Apple Intelligence budget follows context window size (4,096 tokens vs 32,768 tokens)
        snap = readySnapshot(provider: .appleIntelligence, model: "Automatic", appleBackend: .onDevice)
        h.aiService.appleContextTokensProvider = { _ in 4_096 }
        let smallContextBudget = await h.aiService.effectiveBatchCharacterBudget(
            runtime: snap,
            systemPrompt: GMAiService.baseSystemPrompt,
            instruction: "Does this post add substance?",
            sampleTexts: ["Sample English forum post discussing layout performance."]
        )
        h.aiService.appleContextTokensProvider = { _ in 32_768 }
        let largeContextBudget = await h.aiService.effectiveBatchCharacterBudget(
            runtime: snap,
            systemPrompt: GMAiService.baseSystemPrompt,
            instruction: "Does this post add substance?",
            sampleTexts: ["Sample English forum post discussing layout performance."]
        )
        XCTAssertLessThan(smallContextBudget, 6_000, "4,096-token Apple Intelligence context must shrink batch budget (~6-10 posts)")
        XCTAssertGreaterThan(smallContextBudget, 1_500)
        XCTAssertEqual(largeContextBudget, 12_000)
    }

    // MARK: - 4. Rate, Daily, Token & Per-Page Concurrency Limits (Cached Answers Free)

    func testAllLimitsEnforcedCachedAnswersCostNothingAndPerPageConcurrencyQueuesAtTwo() async throws {
        var now = Date(timeIntervalSince1970: 1_763_210_000)
        let h = makeWebHarness(runtime: { self.readySnapshot() })
        h.aiService.clock = { now }
        let s1 = try h.store.create(id: "s1", name: "S1", matchRules: ["https://talk.example.org/*"], js: "//", grants: ["GM_ai"])
        let s2 = try h.store.create(id: "s2", name: "S2", matchRules: ["https://talk.example.org/*"], js: "//", grants: ["GM_ai"])

        var reportedUsage: AgentTokenUsage? = AgentTokenUsage(inputTokens: 100, outputTokens: 50)
        h.aiService.completionRunner = { _, messages, _, _, _ in
            GMAiCompletionResult(text: "ok:\(messages.last?.content ?? "")", usage: reportedUsage)
        }

        // 10/min per script
        for i in 0..<10 {
            _ = try await h.aiService.call(script: s1, pageKey: "pageA", pageURL: nil, prompt: "q\(i)", format: .text)
        }
        await XCTAssertThrowsGMAiCode(.limit) {
            _ = try await h.aiService.call(script: s1, pageKey: "pageA", pageURL: nil, prompt: "q10", format: .text)
        }
        // Cached answer still succeeds at zero cost even while s1 is rate-limited!
        let cachedWhileLimited = try await h.aiService.call(script: s1, pageKey: "pageA", pageURL: nil, prompt: "q0", format: .text)
        XCTAssertEqual(cachedWhileLimited, .string("ok:q0"))
        // Other script has its own per-minute bucket
        _ = try await h.aiService.call(script: s2, pageKey: "pageA", pageURL: nil, prompt: "other0", format: .text)

        // Advance 61s -> minute window clears; test 500/day/script
        now = now.addingTimeInterval(61)
        h.aiService.limiter.limits.callsPerScriptPerDay = 11
        _ = try await h.aiService.call(script: s1, pageKey: "pageA", pageURL: nil, prompt: "q10", format: .text)
        await XCTAssertThrowsGMAiCode(.limit) {
            _ = try await h.aiService.call(script: s1, pageKey: "pageA", pageURL: nil, prompt: "q11", format: .text)
        }

        // All-scripts daily call limit (2,000 default; lowered to 13 here: 11 from s1 + 1 from s2 = 12 so far)
        h.aiService.limiter.limits.callsAllScriptsPerDay = 13
        _ = try await h.aiService.call(script: s2, pageKey: "pageA", pageURL: nil, prompt: "other1", format: .text)
        await XCTAssertThrowsGMAiCode(.limit) {
            _ = try await h.aiService.call(script: s2, pageKey: "pageA", pageURL: nil, prompt: "other2", format: .text)
        }

        // Next day resets daily counters; test token limit with fallback 1-token-per-4-chars estimation
        now = now.addingTimeInterval(25 * 60 * 60)
        h.aiService.limiter.limits = GMAiLimits(tokensAllScriptsPerDay: 500)
        reportedUsage = nil // provider reports no usage -> fallback char/4 estimate applies
        _ = try await h.aiService.call(script: s1, pageKey: "pageA", pageURL: nil, prompt: String(repeating: "a", count: 2_000), format: .text)
        await XCTAssertThrowsGMAiCode(.limit) {
            _ = try await h.aiService.call(script: s1, pageKey: "pageA", pageURL: nil, prompt: "next-after-tokens", format: .text)
        }
        // Cached answer still succeeds when token budget is exhausted!
        _ = try await h.aiService.call(script: s1, pageKey: "pageA", pageURL: nil, prompt: String(repeating: "a", count: 2_000), format: .text)

        // Tight refusal loop must cap audit lines so earlier days are not flooded.
        let beforeAudit = h.auditLog.allLines().filter { $0.kind == .scriptAI }.count
        for i in 0..<50 {
            _ = try? await h.aiService.call(script: s1, pageKey: "pageA", pageURL: nil, prompt: "flood-\(i)", format: .text)
        }
        let afterAudit = h.auditLog.allLines().filter { $0.kind == .scriptAI }.count
        XCTAssertLessThanOrEqual(afterAudit - beforeAudit, 5, "Refusal flood must cap audit lines per minute")

        // 2 concurrent calls per page: 5 simultaneous calls must all succeed with peakConcurrency == 2.
        now = now.addingTimeInterval(25 * 60 * 60)
        h.aiService.limiter.limits = GMAiLimits()
        h.aiService.completionRunner = { _, messages, _, _, _ in
            try await Task.sleep(for: .milliseconds(50))
            return GMAiCompletionResult(text: "done:\(messages.last?.content ?? "")", usage: nil)
        }
        let results = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            for idx in 0..<5 {
                group.addTask { @MainActor in
                    try await h.aiService.call(script: s1, pageKey: "concurrent-page", pageURL: nil, prompt: "p\(idx)", format: .text)
                }
            }
            var out: [JSONValue] = []
            for try await val in group { out.append(val) }
            return out
        }
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(h.aiService.pageGate.peakConcurrencyByPage["concurrent-page"], 2)
    }

    func testMapPartialBatchCacheFailureAccountingRetryCountingAndDailyPersistenceAcrossRelaunch() async throws {
        var now = Date(timeIntervalSince1970: 1_763_220_000)
        let scriptsDir = tempDir.appendingPathComponent("PersistScripts-\(UUID().uuidString)", isDirectory: true)
        let auditDir = tempDir.appendingPathComponent("PersistAudit-\(UUID().uuidString)", isDirectory: true)
        let auditLog = AuditLog(directory: auditDir)
        let store1 = ScriptStore(directoryURL: scriptsDir)
        let ai1 = GMAiService(
            cache: store1.aiCache,
            limiter: store1.aiLimiter,
            auditLog: auditLog,
            runtimeProvider: { self.readySnapshot() }
        )
        ai1.clock = { now }
        let script = try store1.create(
            id: "partial-persist",
            name: "Partial & Persist",
            matchRules: ["https://talk.example.org/*"],
            js: "//",
            grants: ["GM_ai"]
        )

        // 1. Multi-batch GM_ai.map: batch 1 validates and caches immediately; batch 2 hits 1/min limit.
        ai1.limiter.limits = GMAiLimits(callsPerScriptPerMinute: 1, maxBatchItems: 2)
        var runnerCalls = 0
        ai1.completionRunner = { _, messages, _, _, _ in
            runnerCalls += 1
            let prompt = messages.last?.content ?? ""
            if prompt.contains("\"i1\"") {
                return GMAiCompletionResult(text: #"{"i1": true, "i2": false}"#, usage: AgentTokenUsage(inputTokens: 90, outputTokens: 15))
            }
            return GMAiCompletionResult(text: #"{"i3": true, "i4": true}"#, usage: AgentTokenUsage(inputTokens: 80, outputTokens: 12))
        }
        let secretItems = [
            GMAiMapItem(id: "i1", text: "SECRET_ITEM_ONE_BODY"),
            GMAiMapItem(id: "i2", text: "SECRET_ITEM_TWO_BODY"),
            GMAiMapItem(id: "i3", text: "SECRET_ITEM_THREE_BODY"),
            GMAiMapItem(id: "i4", text: "SECRET_ITEM_FOUR_BODY"),
        ]
        let boolFormat = GMAiFormat.schema(.object(["type": .string("boolean")]))
        await XCTAssertThrowsGMAiCode(.limit) {
            _ = try await ai1.map(script: script, pageKey: "p", pageURL: "https://talk.example.org/t/9", items: secretItems, instruction: "SECRET_MAP_INSTR", format: boolFormat)
        }
        XCTAssertEqual(runnerCalls, 1)
        XCTAssertEqual(store1.aiCache.cachedEntryCount(for: script.id, now: now), 2, "Batch 1 answers must be cached before batch 2 throws")
        XCTAssertEqual(store1.aiCache.usageToday(for: script.id, now: now), ScriptAICache.UsageToday(calls: 1, cacheHits: 0))
        let failedAudit = try XCTUnwrap(auditLog.allLines().last(where: { $0.kind == .scriptAI }))
        XCTAssertEqual(failedAudit.outcome, "limit")
        XCTAssertEqual(failedAudit.tokensIn, 90)
        XCTAssertEqual(failedAudit.tokensOut, 15)

        // Retry after minute window clears: batch 1 comes from cache, only batch 2 calls the model!
        now = now.addingTimeInterval(61)
        let fullAnswers = try await ai1.map(script: script, pageKey: "p", pageURL: "https://talk.example.org/t/9", items: secretItems, instruction: "SECRET_MAP_INSTR", format: boolFormat)
        XCTAssertEqual(runnerCalls, 2, "Retrying after batch-2 limit must make only 1 call for the remaining batch")
        XCTAssertEqual(fullAnswers, ["i1": .bool(true), "i2": .bool(false), "i3": .bool(true), "i4": .bool(true)])
        XCTAssertEqual(store1.aiCache.usageToday(for: script.id, now: now), ScriptAICache.UsageToday(calls: 2, cacheHits: 2))

        // 2. Format-mismatch retry acquires a model call and counts toward rate limits & usageToday.
        now = now.addingTimeInterval(61)
        var retryAttempts = 0
        ai1.completionRunner = { _, _, _, _, _ in
            retryAttempts += 1
            return GMAiCompletionResult(text: retryAttempts == 1 ? "not-json" : #"{"ok": true}"#, usage: AgentTokenUsage(inputTokens: 20, outputTokens: 5))
        }
        // With callsPerScriptPerMinute == 1, the retry itself hits .limit without running a 2nd completion!
        await XCTAssertThrowsGMAiCode(.limit) {
            _ = try await ai1.call(script: script, pageKey: "p", pageURL: nil, prompt: "retry-blocked", format: .json)
        }
        XCTAssertEqual(retryAttempts, 1)
        XCTAssertEqual(store1.aiCache.usageToday(for: script.id, now: now).calls, 3)

        // With callsPerScriptPerMinute == 2, attempt 1 + retry attempt 2 both count (= 2 calls).
        now = now.addingTimeInterval(61)
        retryAttempts = 0
        ai1.limiter.limits = GMAiLimits(callsPerScriptPerMinute: 2, callsPerScriptPerDay: 5, callsAllScriptsPerDay: 6, tokensAllScriptsPerDay: 500)
        let retried = try await ai1.call(script: script, pageKey: "p", pageURL: nil, prompt: "retry-succeeds", format: .json)
        XCTAssertEqual(retried, .object(["ok": .bool(true)]))
        XCTAssertEqual(retryAttempts, 2)
        XCTAssertEqual(store1.aiCache.usageToday(for: script.id, now: now), ScriptAICache.UsageToday(calls: 5, cacheHits: 2))

        // 3. Relaunch persistence: fresh ScriptStore on same directory keeps daily usage & daily limiter caps.
        let store2 = ScriptStore(directoryURL: scriptsDir)
        store2.aiLimiter.limits = ai1.limiter.limits
        XCTAssertEqual(store2.aiCache.usageToday(for: script.id, now: now), ScriptAICache.UsageToday(calls: 5, cacheHits: 2))
        // Script already used 5/5 daily calls -> relaunched limiter immediately rejects!
        await XCTAssertThrowsGMAiCode(.limit) {
            try store2.aiLimiter.acquireModelCall(scriptID: script.id, now: now)
        }
        // Another script uses call #6 -> hits callsAllScriptsPerDay (6) across relaunch!
        let other = try store2.create(id: "other-script", name: "Other", matchRules: ["https://talk.example.org/*"], js: "//", grants: ["GM_ai"])
        try store2.aiLimiter.acquireModelCall(scriptID: other.id, now: now)
        let store3 = ScriptStore(directoryURL: scriptsDir)
        store3.aiLimiter.limits = ai1.limiter.limits
        await XCTAssertThrowsGMAiCode(.limit) {
            try store3.aiLimiter.acquireModelCall(scriptID: other.id, now: now)
        }
        // Token daily cap also persists across relaunch (242 tokens used so far; cap lowered to 240).
        store3.aiLimiter.limits.callsAllScriptsPerDay = 100
        store3.aiLimiter.limits.tokensAllScriptsPerDay = 240
        await XCTAssertThrowsGMAiCode(.limit) {
            try store3.aiLimiter.acquireModelCall(scriptID: other.id, now: now)
        }

        // Delete + Undo right after relaunch preserves & restores usageToday, and state files hold zero page/prompt text.
        let store4 = ScriptStore(directoryURL: scriptsDir)
        let deleted = try store4.delete(id: script.id)
        XCTAssertEqual(store4.aiCache.usageToday(for: script.id, now: now), ScriptAICache.UsageToday())
        try store4.restore(deleted)
        XCTAssertEqual(store4.aiCache.usageToday(for: script.id, now: now), ScriptAICache.UsageToday(calls: 5, cacheHits: 2))

        let cacheFiles = try FileManager.default.contentsOfDirectory(at: store4.aiCacheDirectoryURL, includingPropertiesForKeys: nil)
        let allStateText = cacheFiles.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        XCTAssertFalse(allStateText.contains("SECRET_ITEM_ONE_BODY"))
        XCTAssertFalse(allStateText.contains("SECRET_MAP_INSTR"))

        // Next day (+25h) resets both usageToday and daily limiter counters cleanly.
        let tomorrow = now.addingTimeInterval(25 * 60 * 60)
        store4.aiLimiter.limits = GMAiLimits(callsPerScriptPerDay: 5, callsAllScriptsPerDay: 6, tokensAllScriptsPerDay: 500)
        XCTAssertEqual(store4.aiCache.usageToday(for: script.id, now: tomorrow), ScriptAICache.UsageToday())
        XCTAssertNoThrow(try store4.aiLimiter.acquireModelCall(scriptID: script.id, now: tomorrow))
    }

    // MARK: - 5. Scripts Model Role & Legacy AppSettings Decoding

    func testUnsetScriptsModelFollowsSummariesAndLegacySettingsDecode() throws {
        let legacyJSON = """
        {
          "assistantModel": { "provider": "anthropic", "model": "claude-haiku-5-5" },
          "browserAgentModel": { "provider": "anthropic", "model": "claude-sonnet-4-6" },
          "browserScriptsEnabled": true
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.scriptsModel)
        XCTAssertTrue(decoded.browserScriptsAIEnabled)
        XCTAssertEqual(decoded.effectiveModel(for: .scripts), ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"))

        let app = AppModel(
            store: PersistentStore(
                fileURL: tempDir.appendingPathComponent("state-\(UUID().uuidString).json"),
                keys: InMemoryProviderKeyStore()
            )
        )
        var anthropicCfg = app.settings.configuration(for: .anthropic)
        anthropicCfg.apiKey = "sk-ant-test"
        app.settings.setConfiguration(anthropicCfg, for: .anthropic)
        var vertexCfg = app.settings.configuration(for: .vertexAI)
        vertexCfg.apiKey = "vertex-test"
        app.settings.setConfiguration(vertexCfg, for: .vertexAI)

        app.selectModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .role(.assistant))
        XCTAssertFalse(app.hasConfiguredModel(for: .scripts))
        XCTAssertEqual(app.selection(for: .scripts), ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"))

        // Changing Summaries updates unset Scripts automatically.
        app.selectModel(ModelSelection(provider: .vertexAI, model: "gemini-3.5-flash-lite"), for: .role(.assistant))
        XCTAssertEqual(app.selection(for: .scripts), ModelSelection(provider: .vertexAI, model: "gemini-3.5-flash-lite"))

        // Setting an explicit Scripts model decouples it until cleared.
        app.selectModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .role(.scripts))
        XCTAssertTrue(app.hasConfiguredModel(for: .scripts))
        XCTAssertEqual(app.selection(for: .scripts), ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"))

        app.clearScriptsModel()
        XCTAssertFalse(app.hasConfiguredModel(for: .scripts))
        XCTAssertEqual(app.selection(for: .scripts), ModelSelection(provider: .vertexAI, model: "gemini-3.5-flash-lite"))
    }

    // MARK: - 6. Live Provider Checks (Gated by Environment Keys)

    func testLiveAnthropicHaikuGMAiAndCache() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = (env["TEST_RUNNER_ANTHROPIC_API_KEY"] ?? env["ANTHROPIC_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(!key.isEmpty, "Set TEST_RUNNER_ANTHROPIC_API_KEY to run live Anthropic claude-haiku-5-5 GM_ai check.")

        let modelID = "claude-haiku-5-5"
        let cfg = ProviderConfiguration(model: modelID, baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: key)
        let snap = GMAiRuntimeSnapshot(
            isGlobalScriptsEnabled: true, isScriptsAIEnabled: true,
            selection: ModelSelection(provider: .anthropic, model: modelID),
            configuration: cfg, readiness: .ready, appleIntelligenceBackend: nil
        )
        let h = makeWebHarness(runtime: { snap })
        let script = try h.store.create(
            id: "live-haiku-fold",
            name: "Live Haiku Fold",
            matchRules: ["https://talk.example.org/*"],
            js: "window.__liveHaiku = true;",
            grants: ["GM_ai"]
        )
        try await loadPage(h)
        let world = GMBridge.world(for: script.id)

        let verdicts = try await h.webView.callAsyncJavaScript(
            """
            const q = 'Does this forum post add information, an argument, an experience, a question or a correction? Thanks, +1 and bare agreement do not.';
            const first = await GM_ai.map(
              [
                { id: 'p1', text: 'Measuring 30 WKContentWorlds on iPhone showed 38 MB of extra WebContent memory, so host-filtered injection cut idle overhead by 85%.' },
                { id: 'p2', text: '+1 thanks for sharing!' }
              ],
              q,
              { type: 'boolean' }
            );
            const second = await GM_ai.map(
              [
                { id: 'p1', text: 'Measuring 30 WKContentWorlds on iPhone showed 38 MB of extra WebContent memory, so host-filtered injection cut idle overhead by 85%.' },
                { id: 'p2', text: '+1 thanks for sharing!' }
              ],
              q,
              { type: 'boolean' }
            );
            return { first, second };
            """,
            contentWorld: world
        ) as? [String: Any]

        let first = try XCTUnwrap(verdicts?["first"] as? [String: Bool])
        let second = try XCTUnwrap(verdicts?["second"] as? [String: Bool])
        XCTAssertEqual(first["p1"], true)
        XCTAssertEqual(first["p2"], false)
        XCTAssertEqual(second, first)

        let usage = h.store.aiCache.usageToday(for: script.id)
        XCTAssertEqual(usage.calls, 1, "Live claude-haiku-5-5: first map makes 1 call, second hits cache")
        XCTAssertEqual(usage.cacheHits, 2)
        let lines = h.auditLog.allLines().filter { $0.kind == .scriptAI }
        XCTAssertEqual(lines.first?.model, modelID)
        XCTAssertGreaterThan(lines.first?.tokensIn ?? 0, 0, "Anthropic TokenUsageSink must report real input tokens")
        XCTAssertGreaterThan(lines.first?.tokensOut ?? 0, 0, "Anthropic TokenUsageSink must report real output tokens")
        print("LIVE_GMAI_ANTHROPIC model=\(modelID) first=\(first) tokensIn=\(lines.first?.tokensIn ?? -1) tokensOut=\(lines.first?.tokensOut ?? -1) calls=\(usage.calls) cacheHits=\(usage.cacheHits)")
    }

    func testLiveVertexGeminiGMAiAndCache() async throws {
        let env = ProcessInfo.processInfo.environment
        let vertexKey = (env["TEST_RUNNER_VERTEX_API_KEY"] ?? env["VERTEX_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let studioKey = (env["TEST_RUNNER_GEMINI_LIVE_KEY"] ?? env["GEMINI_LIVE_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(!vertexKey.isEmpty || !studioKey.isEmpty, "Set TEST_RUNNER_VERTEX_API_KEY (or TEST_RUNNER_GEMINI_LIVE_KEY) to run live Gemini GM_ai check.")

        let useVertex = !vertexKey.isEmpty
        let provider: AIProvider = useVertex ? .vertexAI : .gemini
        let modelID = useVertex ? "gemini-3.5-flash-lite" : "gemini-2.5-flash"
        let cfg = ProviderConfiguration(model: modelID, baseURL: provider.defaultBaseURL, apiKey: useVertex ? vertexKey : studioKey)
        let snap = GMAiRuntimeSnapshot(
            isGlobalScriptsEnabled: true, isScriptsAIEnabled: true,
            selection: ModelSelection(provider: provider, model: modelID),
            configuration: cfg, readiness: .ready, appleIntelligenceBackend: nil
        )
        let h = makeWebHarness(runtime: { snap })
        let script = try h.store.create(
            id: "live-gemini-fold",
            name: "Live Gemini Fold",
            matchRules: ["https://talk.example.org/*"],
            js: "window.__liveGemini = true;",
            grants: ["GM_ai"]
        )
        try await loadPage(h)
        let world = GMBridge.world(for: script.id)

        let out = try await h.webView.callAsyncJavaScript(
            """
            const q = 'Does this forum post add information, an argument, an experience, a question or a correction? Thanks, +1 and bare agreement do not.';
            const first = await GM_ai.map(
              [
                { id: 'p1', text: 'Reproducing the crash on iOS 26.2 showed the observer fired before document.body existed at document-start.' },
                { id: 'p2', text: 'Agreed, +1!' }
              ],
              q,
              { type: 'boolean' }
            );
            const second = await GM_ai.map(
              [
                { id: 'p1', text: 'Reproducing the crash on iOS 26.2 showed the observer fired before document.body existed at document-start.' },
                { id: 'p2', text: 'Agreed, +1!' }
              ],
              q,
              { type: 'boolean' }
            );
            const single = await GM_ai(
              'Classify whether this post reports a bug: "App crashes when tapping Save on empty rules."',
              { type: 'object', properties: { isBugReport: { type: 'boolean' } }, required: ['isBugReport'] }
            );
            return { first, second, single };
            """,
            contentWorld: world
        ) as? [String: Any]

        let first = try XCTUnwrap(out?["first"] as? [String: Bool])
        let second = try XCTUnwrap(out?["second"] as? [String: Bool])
        let single = try XCTUnwrap(out?["single"] as? [String: Bool])
        XCTAssertEqual(first["p1"], true)
        XCTAssertEqual(first["p2"], false)
        XCTAssertEqual(second, first)
        XCTAssertEqual(single["isBugReport"], true)

        let usage = h.store.aiCache.usageToday(for: script.id)
        XCTAssertEqual(usage.calls, 2, "1 call for first map + 0 for cached repeat + 1 for single GM_ai")
        XCTAssertEqual(usage.cacheHits, 2)
        print("LIVE_GMAI_GEMINI provider=\(provider.rawValue) model=\(modelID) first=\(first) single=\(single) calls=\(usage.calls) cacheHits=\(usage.cacheHits)")
    }

    private func XCTAssertThrowsGMAiCode(
        _ expected: GMAiError.Code,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: () async throws -> Void
    ) async {
        do {
            try await block()
            XCTFail("Expected GMAiError(\(expected.rawValue))", file: file, line: line)
        } catch let err as GMAiError {
            XCTAssertEqual(err.code, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
