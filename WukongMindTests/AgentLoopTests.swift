import Foundation
import XCTest
#if canImport(WukongMind)
@testable import WukongMind
#endif

/// Simulator-free unit tests for `AgentLoop`, `BrowserAgentSession`, recorded
/// `AIService.completeToolTurn` wire formats, and browser-agent settings/modes.
final class AgentLoopTests: XCTestCase {
    // MARK: - Recorded Fake Model Client & Stub Driver

    private final class RecordedModelClient: AgentModelClient, @unchecked Sendable {
        private let lock = NSLock()
        private var scriptedResponses: [Result<AgentModelTurnResponse, Error>]
        private(set) var recordedRequests: [(system: String, messages: [AgentModelTurn], tools: [AgentToolDefinition])] = []
        var onRequest: (@Sendable (Int) async throws -> Void)?

        init(_ responses: [Result<AgentModelTurnResponse, Error>]) {
            self.scriptedResponses = responses
        }

        func append(_ response: Result<AgentModelTurnResponse, Error>) {
            lock.lock()
            scriptedResponses.append(response)
            lock.unlock()
        }

        func completeToolTurn(
            system: String,
            messages: [AgentModelTurn],
            tools: [AgentToolDefinition],
            configuration: ProviderConfiguration,
            provider: AIProvider,
            maxTokens: Int
        ) async throws -> AgentModelTurnResponse {
            let (callNumber, next): (Int, Result<AgentModelTurnResponse, Error>) = lock.withLock {
                recordedRequests.append((system: system, messages: messages, tools: tools))
                let count = recordedRequests.count
                let item: Result<AgentModelTurnResponse, Error>
                if scriptedResponses.isEmpty {
                    item = .success(AgentModelTurnResponse(text: "Default fallback reply."))
                } else {
                    item = scriptedResponses.removeFirst()
                }
                return (count, item)
            }

            if let onRequest {
                try await onRequest(callNumber)
            }
            return try next.get()
        }
    }

    private final class StubDriver: AgentPageDriving, @unchecked Sendable {
        var metadata = AgentPageMetadata(url: "https://news.example.org/story", title: "Example Story")
        var onReadPage: (@Sendable (PageReadMode, String?, Int?) async throws -> String)?
        var onRunJS: (@Sendable (String, AgentExecutionEnvironment, TimeInterval) async throws -> JSExecutionResult)?
        var onInjectCSS: (@Sendable (String, String?) async throws -> CSSInjectionResult)?
        var onWaitFor: (@Sendable (String?, Int?) async throws -> WaitForResult)?

        func currentPageMetadata() async -> AgentPageMetadata { metadata }

        func readPage(mode: PageReadMode, selector: String?, maxLength: Int?) async throws -> String {
            if let onReadPage { return try await onReadPage(mode, selector, maxLength) }
            return "Page: \(metadata.title)\n[h1 #headline] Breaking News"
        }

        func runJS(
            code: String,
            environment: AgentExecutionEnvironment,
            timeout: TimeInterval
        ) async throws -> JSExecutionResult {
            if let onRunJS { return try await onRunJS(code, environment, timeout) }
            return JSExecutionResult(valueJSON: "true", consoleOutput: [], error: nil)
        }

        func injectCSS(css: String, id: String?) async throws -> CSSInjectionResult {
            if let onInjectCSS { return try await onInjectCSS(css, id) }
            return CSSInjectionResult(sheetID: id ?? "wukong-style-1", appliedRootCount: 1)
        }

        func waitFor(selector: String?, milliseconds: Int?) async throws -> WaitForResult {
            if let onWaitFor { return try await onWaitFor(selector, milliseconds) }
            return WaitForResult(mode: .delay, matched: true, elapsedMs: milliseconds ?? 50, selector: selector)
        }
    }

    // MARK: - System Prompt

    func testSystemPromptIncludesFiveOperatingRulesAndPageMetadata() {
        let prompt = BrowserAgentPrompt.system(
            page: AgentPageMetadata(url: "https://docs.example.com/guide", title: "Developer Guide"),
            customInstructions: "Prefer dark backgrounds."
        )
        XCTAssertTrue(prompt.contains("read_page"))
        XCTAssertTrue(prompt.contains("Verify after changing"))
        XCTAssertTrue(prompt.contains("Prefer stable selectors"))
        XCTAssertTrue(prompt.contains("script_save"))
        XCTAssertTrue(prompt.contains("<untrusted_web_content>"))
        XCTAssertTrue(prompt.contains("https://docs.example.com/guide"))
        XCTAssertTrue(prompt.contains("Developer Guide"))
        XCTAssertTrue(prompt.contains("Prefer dark backgrounds."))
    }

    // MARK: - Stop Conditions

    func testPlainTextReplyEndsLoopImmediatelyWithoutToolSteps() async throws {
        let client = RecordedModelClient([
            .success(
                AgentModelTurnResponse(
                    text: "This page is an article about Example Story.",
                    toolCalls: [],
                    stopReason: "end_turn",
                    usage: AgentTokenUsage(inputTokens: 120, outputTokens: 25)
                )
            )
        ])
        let driver = StubDriver()
        let loop = AgentLoop(
            modelClient: client,
            registry: ToolRegistry.m1(bridge: driver),
            maxSteps: 30
        )

        let result = try await loop.run(
            systemPrompt: "sys",
            initialHistory: [.user("What is this page?")],
            configuration: ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake"),
            provider: .anthropic
        )

        guard case .completed(let text, let steps, _) = result.outcome else {
            return XCTFail("Expected completed outcome, got \(result.outcome)")
        }
        XCTAssertEqual(text, "This page is an article about Example Story.")
        XCTAssertEqual(steps, 0)
        XCTAssertTrue(result.toolRows.isEmpty)
        XCTAssertEqual(result.tokenUsage, AgentTokenUsage(inputTokens: 120, outputTokens: 25))
        XCTAssertEqual(result.tokenUsage.totalTokens, 145)
        XCTAssertEqual(client.recordedRequests.count, 1)
    }

    func testMultiStepToolExecutionWrapsUntrustedObservationsAndAccumulatesTokens() async throws {
        let client = RecordedModelClient([
            .success(
                AgentModelTurnResponse(
                    text: "Let me inspect the page first.",
                    toolCalls: [
                        AgentModelToolCall(id: "toolu_1", name: "read_page", arguments: ["mode": .string("structure")])
                    ],
                    stopReason: "tool_use",
                    usage: AgentTokenUsage(inputTokens: 200, outputTokens: 40)
                )
            ),
            .success(
                AgentModelTurnResponse(
                    text: "",
                    toolCalls: [
                        AgentModelToolCall(
                            id: "toolu_2",
                            name: "inject_css",
                            arguments: ["css": .string("#ad-banner { display: none !important; }"), "id": .string("hide-ad")]
                        )
                    ],
                    stopReason: "tool_use",
                    usage: AgentTokenUsage(inputTokens: 310, outputTokens: 35)
                )
            ),
            .success(
                AgentModelTurnResponse(
                    text: "Hid the banner cleanly.",
                    toolCalls: [],
                    stopReason: "end_turn",
                    usage: AgentTokenUsage(inputTokens: 380, outputTokens: 20)
                )
            )
        ])

        let driver = StubDriver()
        let loop = AgentLoop(
            modelClient: client,
            registry: ToolRegistry.m1(bridge: driver),
            maxSteps: 30
        )

        let result = try await loop.run(
            systemPrompt: "sys",
            initialHistory: [.user("Hide the ad banner")],
            configuration: ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake"),
            provider: .anthropic
        )

        guard case .completed(let text, let steps, _) = result.outcome else {
            return XCTFail("Expected completed outcome, got \(result.outcome)")
        }
        XCTAssertEqual(text, "Hid the banner cleanly.")
        XCTAssertEqual(steps, 2)
        XCTAssertEqual(result.toolRows.map(\.toolName), ["read_page", "inject_css"])
        XCTAssertTrue(result.toolRows.allSatisfy { !$0.isRunning && !$0.isError })
        XCTAssertEqual(result.tokenUsage, AgentTokenUsage(inputTokens: 890, outputTokens: 95))

        // Verify the second model request received `<untrusted_web_content>` delimiters.
        let secondTurnMessages = client.recordedRequests[1].messages
        guard case .toolResults(let results) = secondTurnMessages.last,
              let firstObs = results.first else {
            return XCTFail("Expected toolResults turn in second request")
        }
        XCTAssertFalse(firstObs.isError)
        XCTAssertTrue(firstObs.content.contains(#"<untrusted_web_content tool="read_page">"#))
        XCTAssertTrue(firstObs.content.contains("</untrusted_web_content>"))
    }

    func testToolErrorIsFedBackToModelSoLoopRecoversAndFinishes() async throws {
        let client = RecordedModelClient([
            .success(
                AgentModelTurnResponse(
                    text: "",
                    toolCalls: [
                        AgentModelToolCall(
                            id: "call_bad",
                            name: "read_page",
                            arguments: ["selector": .string("#wrong-id")]
                        )
                    ],
                    stopReason: "tool_use",
                    usage: AgentTokenUsage(inputTokens: 100, outputTokens: 20)
                )
            ),
            .success(
                AgentModelTurnResponse(
                    text: "",
                    toolCalls: [
                        AgentModelToolCall(
                            id: "call_good",
                            name: "read_page",
                            arguments: ["selector": .string("#headline")]
                        )
                    ],
                    stopReason: "tool_use",
                    usage: AgentTokenUsage(inputTokens: 150, outputTokens: 20)
                )
            ),
            .success(
                AgentModelTurnResponse(
                    text: "Found #headline after adjusting the selector.",
                    toolCalls: [],
                    stopReason: "end_turn",
                    usage: AgentTokenUsage(inputTokens: 190, outputTokens: 15)
                )
            )
        ])

        let driver = StubDriver()
        driver.onReadPage = { _, selector, _ in
            if selector == "#wrong-id" {
                throw AgentBridgeError.selectorNotFound("#wrong-id")
            }
            return "[h1 #headline] Recovered Headline"
        }

        let loop = AgentLoop(
            modelClient: client,
            registry: ToolRegistry.m1(bridge: driver),
            maxSteps: 30
        )

        let result = try await loop.run(
            systemPrompt: "sys",
            initialHistory: [.user("Read the headline")],
            configuration: ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake"),
            provider: .anthropic
        )

        guard case .completed(let text, let steps, _) = result.outcome else {
            return XCTFail("Expected completed outcome after tool error recovery")
        }
        XCTAssertEqual(steps, 2)
        XCTAssertEqual(text, "Found #headline after adjusting the selector.")
        XCTAssertTrue(result.toolRows[0].isError)
        XCTAssertFalse(result.toolRows[1].isError)

        // Confirm the first tool result sent to turn 2 carried `isError == true`.
        guard case .toolResults(let turn1Results) = client.recordedRequests[1].messages.last else {
            return XCTFail("Missing toolResults in turn 2")
        }
        XCTAssertEqual(turn1Results.first?.isError, true)
        XCTAssertTrue(turn1Results.first?.content.contains("#wrong-id") == true)
    }

    @MainActor
    func testStepLimitStopsLoopReportsNoticeAndAllowsContinue() async throws {
        // Default 30-step limit verification on pure loop:
        let thirtyTurnResponses: [Result<AgentModelTurnResponse, Error>] = (1...35).map { idx in
            .success(
                AgentModelTurnResponse(
                    text: "",
                    toolCalls: [
                        AgentModelToolCall(
                            id: "step_\(idx)",
                            name: "run_js",
                            arguments: ["code": .string("return \(idx);")]
                        )
                    ],
                    stopReason: "tool_use",
                    usage: AgentTokenUsage(inputTokens: 10, outputTokens: 5)
                )
            )
        }
        let defaultClient = RecordedModelClient(thirtyTurnResponses)
        let defaultLoop = AgentLoop(
            modelClient: defaultClient,
            registry: ToolRegistry.m1(bridge: StubDriver())
        )
        XCTAssertEqual(defaultLoop.maxSteps, 30)

        let defaultResult = try await defaultLoop.run(
            systemPrompt: "sys",
            initialHistory: [.user("Loop forever")],
            configuration: ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake"),
            provider: .anthropic
        )
        guard case .stepLimitReached(let limit, let notice, _) = defaultResult.outcome else {
            return XCTFail("Expected stepLimitReached(30), got \(defaultResult.outcome)")
        }
        XCTAssertEqual(limit, 30)
        XCTAssertEqual(defaultResult.toolRows.count, 30)
        XCTAssertTrue(notice.contains("30"))

        // Also verify Observable BrowserAgentSession step limit (3) + Continue flow:
        let sessionResponses: [Result<AgentModelTurnResponse, Error>] = (1...4).map { idx in
            .success(
                AgentModelTurnResponse(
                    text: "",
                    toolCalls: [
                        AgentModelToolCall(
                            id: "s_\(idx)",
                            name: "read_page",
                            arguments: ["mode": .string("text")]
                        )
                    ],
                    usage: AgentTokenUsage(inputTokens: 20, outputTokens: 10)
                )
            )
        } + [
            .success(
                AgentModelTurnResponse(
                    text: "Finished on continuation!",
                    toolCalls: [],
                    usage: AgentTokenUsage(inputTokens: 30, outputTokens: 12)
                )
            )
        ]

        let sessionClient = RecordedModelClient(sessionResponses)
        let session = BrowserAgentSession(
            pageDriver: StubDriver(),
            modelClient: sessionClient,
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
                    configuration: ProviderConfiguration(
                        model: "claude-haiku-5-5",
                        baseURL: AIProvider.anthropic.defaultBaseURL,
                        apiKey: "fake-key"
                    ),
                    maxSteps: 3,
                    truncationLimit: 20_000,
                    customInstructions: "",
                    redactedSecrets: ["fake-key"]
                )
            }
        )

        await session.sendAndWait("Inspect 3 times")
        XCTAssertEqual(session.runState, .stepLimitReached(limit: 3))
        XCTAssertEqual(session.toolCalls.count, 3)
        XCTAssertTrue(session.messages.last?.isError == true)
        XCTAssertTrue(session.messages.last?.text.contains("step limit") == true)

        // Continue with a fresh budget:
        await session.continueAfterStepLimitAndWait()
        if case .completed(let steps, _) = session.runState {
            XCTAssertEqual(steps, 0)
        } else {
            XCTFail("Expected completed state after continueAfterStepLimit, got \(session.runState)")
        }
        XCTAssertEqual(session.messages.last?.text, "Finished on continuation!")
    }

    @MainActor
    func testStopCancelsImmediatelyHealsHistoryAndPermitsNextTurn() async throws {
        let toolEntered = expectation(description: "slow tool started")
        let driver = StubDriver()
        driver.onRunJS = { _, _, _ in
            toolEntered.fulfill()
            try await Task.sleep(for: .seconds(10))
            return JSExecutionResult(valueJSON: "1", consoleOutput: [], error: nil)
        }

        let client = RecordedModelClient([
            .success(
                AgentModelTurnResponse(
                    text: "",
                    toolCalls: [
                        AgentModelToolCall(
                            id: "slow_call_1",
                            name: "run_js",
                            arguments: ["code": .string("await sleep(10000);")]
                        )
                    ],
                    usage: AgentTokenUsage(inputTokens: 50, outputTokens: 15)
                )
            ),
            .success(
                AgentModelTurnResponse(
                    text: "Follow-up after stop succeeded.",
                    toolCalls: [],
                    usage: AgentTokenUsage(inputTokens: 80, outputTokens: 18)
                )
            )
        ])

        let session = BrowserAgentSession(
            pageDriver: driver,
            modelClient: client,
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
                    configuration: ProviderConfiguration(
                        model: "claude-haiku-5-5",
                        baseURL: AIProvider.anthropic.defaultBaseURL,
                        apiKey: "fake-key"
                    ),
                    maxSteps: 30,
                    truncationLimit: 20_000,
                    customInstructions: "",
                    redactedSecrets: []
                )
            }
        )

        session.send("Start long script")
        await fulfillment(of: [toolEntered], timeout: 2.0)
        XCTAssertTrue(session.isRunning)

        let stopStart = ContinuousClock.now
        session.stop()
        let stopElapsed = stopStart.duration(to: .now)
        XCTAssertLessThan(stopElapsed, .milliseconds(250))
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.runState, .stopped(step: 1))
        XCTAssertEqual(session.toolCalls.first?.resultSummary, "Stopped")

        // Verify history has no dangling tool_use without a matching tool_result,
        // and that a follow-up user turn succeeds cleanly.
        await session.sendAndWait("Now answer quickly")
        if case .completed = session.runState {
            XCTAssertEqual(session.messages.last?.text, "Follow-up after stop succeeded.")
        } else {
            XCTFail("Expected follow-up after stop() to complete, got \(session.runState)")
        }
    }

    #if canImport(WukongMind)
    // MARK: - Recorded Wire Format Tests (Anthropic & OpenAI)

    private final class RecordedToolURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (status, data) = try handler(request)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private static func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    func testAIServiceAnthropicToolCallingWireFormatRoundTrip() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [RecordedToolURLProtocol.self]
        let service = AIService(session: URLSession(configuration: sessionConfig))

        var capturedRequest: URLRequest?
        var capturedJSON: [String: Any]?

        RecordedToolURLProtocol.handler = { request in
            capturedRequest = request
            if let bodyData = Self.requestBodyData(request) {
                capturedJSON = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
            }
            let recordedAnthropicResponse = """
            {
              "id": "msg_01Recorded",
              "type": "message",
              "role": "assistant",
              "model": "claude-haiku-5-5",
              "content": [
                { "type": "text", "text": "Checking the DOM structure." },
                {
                  "type": "tool_use",
                  "id": "toolu_01Recorded",
                  "name": "read_page",
                  "input": { "mode": "structure", "selector": "#main" }
                }
              ],
              "stop_reason": "tool_use",
              "usage": {
                "input_tokens": 312,
                "cache_read_input_tokens": 18,
                "output_tokens": 44
              }
            }
            """
            return (200, Data(recordedAnthropicResponse.utf8))
        }
        defer { RecordedToolURLProtocol.handler = nil }

        let tools = ToolRegistry.m1(bridge: StubDriver()).definitions
        let turns: [AgentModelTurn] = [
            .user("Inspect #main"),
            .assistant(
                text: "",
                toolCalls: [
                    AgentModelToolCall(id: "toolu_prev", name: "wait_for", arguments: ["ms": .int(100)])
                ]
            ),
            .toolResults([
                AgentModelToolResult(
                    toolCallID: "toolu_prev",
                    toolName: "wait_for",
                    content: "<untrusted_web_content tool=\"wait_for\">\nWaited 100 ms.\n</untrusted_web_content>",
                    isError: false
                )
            ])
        ]

        let response = try await service.completeToolTurn(
            system: "System rules",
            messages: turns,
            tools: tools,
            configuration: ProviderConfiguration(
                model: "claude-haiku-5-5",
                baseURL: "https://api.anthropic.com/v1",
                apiKey: "test-fake-anthropic-key"
            ),
            provider: .anthropic
        )

        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "x-api-key"), "test-fake-anthropic-key")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try XCTUnwrap(capturedJSON)
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(body["system"] as? String, "System rules")
        let encodedTools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(encodedTools.count, 4)
        XCTAssertNotNil(encodedTools.first?["input_schema"] as? [String: Any])

        // Ensure empty assistant text was NOT emitted as `{"type":"text","text":""}`!
        let encodedMessages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(encodedMessages.count, 3)
        let assistantContent = try XCTUnwrap(encodedMessages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantContent.count, 1)
        XCTAssertEqual(assistantContent.first?["type"] as? String, "tool_use")

        // Verify parsed response:
        XCTAssertEqual(response.text, "Checking the DOM structure.")
        XCTAssertEqual(response.stopReason, "tool_use")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.id, "toolu_01Recorded")
        XCTAssertEqual(response.toolCalls.first?.name, "read_page")
        XCTAssertEqual(response.toolCalls.first?.arguments["selector"], .string("#main"))
        XCTAssertEqual(response.usage, AgentTokenUsage(inputTokens: 330, outputTokens: 44))
    }

    func testAIServiceOpenAIToolCallingWireFormatRoundTrip() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [RecordedToolURLProtocol.self]
        let service = AIService(session: URLSession(configuration: sessionConfig))

        RecordedToolURLProtocol.handler = { _ in
            let recordedOpenAI = """
            {
              "id": "chatcmpl_recorded",
              "choices": [
                {
                  "index": 0,
                  "finish_reason": "tool_calls",
                  "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [
                      {
                        "id": "call_openai_1",
                        "type": "function",
                        "function": {
                          "name": "inject_css",
                          "arguments": "{\\"css\\":\\"body { background: #111; }\\"}"
                        }
                      }
                    ]
                  }
                }
              ],
              "usage": {
                "prompt_tokens": 210,
                "completion_tokens": 28
              }
            }
            """
            return (200, Data(recordedOpenAI.utf8))
        }
        defer { RecordedToolURLProtocol.handler = nil }

        let response = try await service.completeToolTurn(
            system: "Sys",
            messages: [.user("Dark mode")],
            tools: ToolRegistry.m1(bridge: StubDriver()).definitions,
            configuration: ProviderConfiguration(
                model: "gpt-4o-mini",
                baseURL: "https://api.openai.com/v1",
                apiKey: "sk-openai-fake"
            ),
            provider: .openAI
        )

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.name, "inject_css")
        XCTAssertEqual(response.toolCalls.first?.arguments["css"], .string("body { background: #111; }"))
        XCTAssertEqual(response.usage, AgentTokenUsage(inputTokens: 210, outputTokens: 28))
    }

    // MARK: - Settings & Non-Discourse Page Support

    @MainActor
    func testBrowserAgentHasNoPresetModelAndWorksOnNonForumPages() throws {
        let stock = AppSettings()
        XCTAssertNil(stock.browserAgentModel, "Browser agent must have no preset model")
        XCTAssertEqual(stock.browserAgentMaxSteps, 30)
        XCTAssertEqual(stock.browserAgentTruncationLimit, 20_000)

        // Empty JSON decodes to stock defaults (preserving StateTransitionTests contract).
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, stock)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = AppModel(store: PersistentStore(fileURL: directory.appendingPathComponent("state.json")))

        XCTAssertFalse(app.isProviderReady(for: .browserAgent))
        XCTAssertEqual(app.readiness(for: .browserAgent), .needsModel)

        // Apple Intelligence does not support tool calling and must not be accepted for browserAgent.
        app.selectModel(
            ModelSelection(provider: .appleIntelligence, model: "Automatic"),
            for: .role(.browserAgent)
        )
        XCTAssertNil(app.settings.browserAgentModel)

        // Choosing a tool-calling model without an API key reports .needsKey.
        app.selectModel(
            ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
            for: .role(.browserAgent)
        )
        XCTAssertEqual(app.readiness(for: .browserAgent), .needsKey)

        var anthropicConfig = app.settings.configuration(for: .anthropic)
        anthropicConfig.apiKey = "test-fake-anthropic-key"
        app.settings.setConfiguration(anthropicConfig, for: .anthropic)
        XCTAssertEqual(app.readiness(for: .browserAgent), .ready)
        XCTAssertTrue(app.isBrowserAgentReady)

        // Opening browser agent on a plain non-forum page works without blocking.
        app.openBrowserAgent()
        XCTAssertEqual(app.assistantMode, .browserAgent)
        XCTAssertEqual(app.currentRole, .browserAgent)

        // M1 UI helpers: tool labels (tense), token formatting, and duration formatting.
        XCTAssertEqual(DCToolLabel.browser("read_page", running: true), "Reading page")
        XCTAssertEqual(DCToolLabel.browser("read_page", running: false), "Read page")
        XCTAssertEqual(DCToolLabel.browser("run_js", running: true), "Running script")
        XCTAssertEqual(DCToolLabel.browser("run_js", running: false), "Ran script")
        XCTAssertEqual(DCToolLabel.browser("script_save", running: false), "Saved script")

        XCTAssertEqual(BrowserAgentPanelView.formatTokens(420), "420")
        XCTAssertEqual(BrowserAgentPanelView.formatTokens(1_420), "1.4k")
        XCTAssertEqual(BrowserAgentPanelView.formatDuration(0.34), "0.3 s")
        XCTAssertEqual(BrowserAgentPanelView.formatDuration(9.0), "9 s")
        XCTAssertEqual(BrowserAgentPanelView.formatDuration(14.2), "14 s")

        // Unified status line: token count is hidden by default and shown only in developerMode.
        XCTAssertFalse(AppSettings().developerMode)
        XCTAssertEqual(
            BrowserAgentPanelView.statusText(
                runState: .completed(steps: 3, duration: 9),
                developerMode: false,
                totalTokens: 1_420
            ),
            "Done · 3 steps · 9 s"
        )
        XCTAssertEqual(
            BrowserAgentPanelView.statusText(
                runState: .completed(steps: 3, duration: 9),
                developerMode: true,
                totalTokens: 1_420
            ),
            "Done · 3 steps · 9 s · 1.4k tokens"
        )
        XCTAssertEqual(
            BrowserAgentPanelView.statusText(
                runState: .running(step: 2, maxSteps: 10),
                developerMode: false,
                totalTokens: 900
            ),
            "Working · step 2"
        )
        XCTAssertEqual(
            BrowserAgentPanelView.statusText(
                runState: .running(step: 2, maxSteps: 10),
                developerMode: true,
                totalTokens: 900
            ),
            "Working · step 2 · 900 tokens"
        )
        XCTAssertNil(
            BrowserAgentPanelView.statusText(
                runState: .idle,
                developerMode: true,
                totalTokens: 900
            )
        )
        XCTAssertNil(
            BrowserAgentPanelView.statusText(
                runState: .failed(message: "Network error"),
                developerMode: true,
                totalTokens: 900
            )
        )

        // Mascot pose transitions: think -> search/run -> cheer; Reduce Motion stays think; errors never show mascot.
        let runID = UUID()
        let readRow = BrowserAgentToolCallRow(
            id: UUID(), callID: "c1", runID: runID, stepNumber: 1, toolName: "read_page",
            argumentSummary: "", argumentsJSON: "{}", resultSummary: "", resultText: "",
            duration: nil, isRunning: true, isError: false, wasTruncated: false, totalCharacterCount: 0
        )
        let jsRow = BrowserAgentToolCallRow(
            id: UUID(), callID: "c2", runID: runID, stepNumber: 2, toolName: "run_js",
            argumentSummary: "", argumentsJSON: "{}", resultSummary: "", resultText: "",
            duration: nil, isRunning: true, isError: false, wasTruncated: false, totalCharacterCount: 0
        )
        XCTAssertEqual(
            BrowserAgentPanelView.mascotPose(runState: .running(step: 0, maxSteps: 10), toolCalls: [], reduceMotion: false),
            .think
        )
        XCTAssertEqual(
            BrowserAgentPanelView.mascotPose(runState: .running(step: 1, maxSteps: 10), toolCalls: [readRow], reduceMotion: false),
            .search
        )
        XCTAssertEqual(
            BrowserAgentPanelView.mascotPose(runState: .running(step: 2, maxSteps: 10), toolCalls: [jsRow], reduceMotion: false),
            .run
        )
        XCTAssertEqual(
            BrowserAgentPanelView.mascotPose(runState: .running(step: 2, maxSteps: 10), toolCalls: [jsRow], reduceMotion: true),
            .think
        )
        XCTAssertEqual(
            BrowserAgentPanelView.mascotPose(runState: .completed(steps: 3, duration: 9), toolCalls: [], reduceMotion: false),
            .cheer
        )
        XCTAssertNil(
            BrowserAgentPanelView.mascotPose(runState: .failed(message: "Boom"), toolCalls: [], reduceMotion: false)
        )
        XCTAssertNil(
            BrowserAgentPanelView.mascotPose(runState: .stepLimitReached(limit: 15), toolCalls: [], reduceMotion: false)
        )
    }
    #endif
}

// MARK: - One panel 2b: context hand-off

extension AgentLoopTests {
    /// A follow-up after a summary: the model's turn carries the summary,
    /// the user's bubble and the run show only the question.
    @MainActor
    func testFollowUpCarriesHandedOverContextOnlyToTheModel() async throws {
        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "Post 3 has the CSS.", toolCalls: [], usage: AgentTokenUsage(inputTokens: 10, outputTokens: 5)))
        ])
        let session = BrowserAgentSession(
            pageDriver: StubDriver(),
            modelClient: client,
            configProvider: {
                BrowserAgentRuntimeConfig(
                    selection: ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"),
                    configuration: ProviderConfiguration(model: "claude-haiku-5-5", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake-key"),
                    maxSteps: 3,
                    truncationLimit: 20_000,
                    customInstructions: "",
                    redactedSecrets: []
                )
            }
        )
        session.appendLocalReply(prompt: "Notify me of new replies", reply: "Following.")
        XCTAssertEqual(session.runs.last?.assistantText, "Following.")
        XCTAssertTrue(session.history.isEmpty, "A local reply never reaches the model.")

        await session.sendAndWait("Which post has the CSS?", context: "Summary of the forum thread: #3 explains the CSS.")
        let firstTurn = try XCTUnwrap(client.recordedRequests.first?.messages.first)
        guard case .user(let text) = firstTurn else { return XCTFail("Expected a user turn, got \(firstTurn)") }
        XCTAssertTrue(text.contains("#3 explains the CSS."), text)
        XCTAssertTrue(text.hasSuffix("Which post has the CSS?"), text)
        XCTAssertEqual(session.messages.first?.text, "Which post has the CSS?")
        XCTAssertEqual(session.runs.last?.prompt, "Which post has the CSS?")
    }
}
