import Foundation
import Network
import XCTest

/// UI tests for `ProviderSettingsPage` › `Models` (`design-browser-bar-tabs-models.md` §3, row P1):
/// provider-ordered model rows with display names and mono IDs, role seals,
/// native `⋯` Menu (`Use for Agent` / `Use for Summaries` checkmarks and
/// disabled `Use for Agent` on Apple Intelligence), starring in place,
/// `Show all N`, search above 20 models, and the five section states.
final class ProviderModelsUITests: DCUITestCase {
    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    private func tapTrailingMore(on row: XCUIElement, key: String, in app: XCUIApplication) {
        let button = app.buttons["modelMore-\(key)"]
        if button.exists && button.isHittable {
            button.tap()
            return
        }
        row.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -24, dy: 0))
            .tap()
    }

    private func tapLeadingStar(on row: XCUIElement) {
        row.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 24, dy: 0))
            .tap()
    }

    private func replaceFieldText(_ field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let existing = field.value as? String, !existing.isEmpty {
            let deleteSequence = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 8)
            field.typeText(deleteSequence)
        }
        field.typeText(text + "\n")
    }

    func testAnthropicPageListsModelsMovesAgentSealAndStarsInPlace() throws {
        let app = launch([
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-dc-sample",
            "-dc-forums-home",
            "-dc-show-settings", "provider",
            "-dc-agent-model", "anthropic:claude-sonnet-5-5"
        ])

        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 20))
        let anthropicRow = app.buttons["providerRow-anthropic"]
        XCTAssertTrue(reveal(anthropicRow, in: app, swipes: 6))
        anthropicRow.tap()

        XCTAssertTrue(app.navigationBars["Anthropic"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "refreshModels").waitForExistence(timeout: 5))

        let fableRow = any(app, "modelRow-claude-fable-5-2")
        let haikuRow = any(app, "modelRow-claude-haiku-5-5")
        let sonnetRow = any(app, "modelRow-claude-sonnet-5-5")
        let sixthRow = any(app, "modelRow-claude-opus-5")
        let seventhRow = any(app, "modelRow-claude-sonnet-5")
        let showAll = any(app, "showAllModels")

        XCTAssertTrue(waitOrDump(fableRow, timeout: 5, in: app))
        XCTAssertTrue(haikuRow.exists)
        XCTAssertTrue(sonnetRow.exists)
        XCTAssertTrue(reveal(sixthRow, in: app, swipes: 3))
        XCTAssertTrue(reveal(showAll, in: app, swipes: 2))
        XCTAssertTrue(showAll.label.contains("Show all 15"), "Got “\(showAll.label)”.")
        XCTAssertFalse(seventhRow.exists, "Only the first 6 models should show before tapping Show all 15.")

        // Provider order and VoiceOver combined label check.
        XCTAssertTrue(reveal(fableRow, in: app, swipes: 3))
        XCTAssertLessThan(fableRow.frame.minY, haikuRow.frame.minY)
        XCTAssertLessThan(haikuRow.frame.minY, sonnetRow.frame.minY)
        XCTAssertTrue(sonnetRow.label.contains("Claude Sonnet 5.5"), "Got “\(sonnetRow.label)”.")
        XCTAssertTrue(sonnetRow.label.contains("claude-sonnet-5-5"), "Got “\(sonnetRow.label)”.")
        XCTAssertTrue(sonnetRow.label.contains("used for Agent"), "Got “\(sonnetRow.label)”.")
        XCTAssertTrue(sonnetRow.label.contains("favorite"), "Got “\(sonnetRow.label)”.")
        XCTAssertFalse(haikuRow.label.contains("used for Agent"), "Got “\(haikuRow.label)”.")

        capture(isPhone ? "p1-iphone-anthropic-initial-light" : "p1-ipad-anthropic-initial-light")

        // Starring in place keeps the provider's row order unchanged.
        XCTAssertFalse(fableRow.label.contains("favorite"))
        tapLeadingStar(on: fableRow)
        XCTAssertTrue(wait(timeout: 5) { fableRow.label.contains("favorite") }, "Got “\(fableRow.label)”.")
        XCTAssertLessThan(fableRow.frame.minY, haikuRow.frame.minY, "Starred models must stay in place.")

        // Open ⋯ on Claude Haiku 5.5 and move the Agent seal to it.
        tapTrailingMore(on: haikuRow, key: "claude-haiku-5-5", in: app)
        let useForAgent = app.buttons.matching(label(contains: "Use for Agent")).firstMatch
        XCTAssertTrue(waitOrDump(useForAgent, timeout: 5, in: app))
        XCTAssertTrue(useForAgent.isEnabled)
        XCTAssertTrue(app.buttons.matching(label(contains: "Use for Summaries")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(label(contains: "Copy model name")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(label(contains: "Use for Scripts")).firstMatch.exists, "Scripts must not join the menu before M4.")
        capture(isPhone ? "p1-iphone-anthropic-menu-light" : "p1-ipad-anthropic-menu-light")

        useForAgent.tap()
        XCTAssertTrue(wait(timeout: 5) {
            haikuRow.label.contains("used for Agent") && !sonnetRow.label.contains("used for Agent")
        }, "Agent seal did not move: haiku=“\(haikuRow.label)”, sonnet=“\(sonnetRow.label)”.")
        capture(isPhone ? "p1-iphone-anthropic-seal-moved-light" : "p1-ipad-anthropic-seal-moved-light")

        // Expand all 15 models.
        XCTAssertTrue(reveal(showAll, in: app, swipes: 3))
        showAll.tap()
        let fifteenthRow = any(app, "modelRow-claude-sonnet-4-5-20250929")
        XCTAssertTrue(reveal(fifteenthRow, in: app, swipes: 6))
        XCTAssertTrue(fifteenthRow.label.contains("Claude Sonnet 4.5"))
    }

    func testAppleIntelligenceShowsDisabledUseForAgentWithReason() throws {
        let app = launch([
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-dc-sample",
            "-dc-forums-home",
            "-dc-apple-intelligence", "on-device",
            "-dc-show-settings", "provider"
        ])

        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 20))
        let appleRow = app.buttons["providerRow-appleintelligence"]
        XCTAssertTrue(reveal(appleRow, in: app, swipes: 6))
        appleRow.tap()

        XCTAssertTrue(app.navigationBars["Apple Intelligence"].waitForExistence(timeout: 10))
        XCTAssertFalse(any(app, "refreshModels").exists, "Apple Intelligence has no Refresh button.")

        let foundationRow = any(app, "modelRow-appleIntelligence")
        XCTAssertTrue(reveal(foundationRow, in: app, swipes: 3))
        XCTAssertTrue(foundationRow.label.contains("Foundation Model"), "Got “\(foundationRow.label)”.")
        XCTAssertTrue(foundationRow.label.contains("Private Cloud Compute when available"), "Got “\(foundationRow.label)”.")
        XCTAssertTrue(foundationRow.label.contains("used for Summaries"), "Got “\(foundationRow.label)”.")

        tapTrailingMore(on: foundationRow, key: "appleIntelligence", in: app)

        let useForAgent = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Use for Agent'")).firstMatch
        XCTAssertTrue(waitOrDump(useForAgent, timeout: 5, in: app))
        XCTAssertFalse(useForAgent.isEnabled, "Apple Intelligence must show Use for Agent disabled.")
        XCTAssertTrue(
            useForAgent.label.contains("Needs a tool-calling model"),
            "Disabled Use for Agent item should expose its subtitle reason; got “\(useForAgent.label)”."
        )
        let useForSummaries = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Use for Summaries'")).firstMatch
        XCTAssertTrue(useForSummaries.exists)
        XCTAssertTrue(useForSummaries.isEnabled)
        capture(isPhone ? "p1-iphone-apple-intelligence-disabled-agent" : "p1-ipad-apple-intelligence-disabled-agent")

        dismissMenu(in: app)
    }

    func testProviderModelsNoKeyErrorEmptySearchAndVertexBuiltInStates() throws {
        let server = FixtureModelsHTTPServer()
        try server.start()
        defer { server.stop() }

        let app = launch([
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-dc-sample",
            "-dc-no-provider",
            "-dc-forums-home",
            "-dc-show-settings", "provider"
        ])

        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 20))
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }

        // 1. Vertex AI: built-in list without a fetch or API key, and no Refresh button.
        let vertexRow = app.buttons["providerRow-vertexai"]
        XCTAssertTrue(reveal(vertexRow, in: app, swipes: 6))
        vertexRow.tap()
        XCTAssertTrue(app.navigationBars["Google Vertex AI"].waitForExistence(timeout: 10))
        XCTAssertFalse(any(app, "refreshModels").exists)
        XCTAssertTrue(reveal(any(app, "modelRow-gemini-3.8-flash"), in: app, swipes: 3))
        let vertexShowAll = any(app, "showAllModels")
        XCTAssertTrue(reveal(vertexShowAll, in: app, swipes: 3))
        XCTAssertTrue(vertexShowAll.label.contains("Show all 10"))
        XCTAssertEqual(server.requestCount, 0)

        app.navigationBars["Google Vertex AI"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 10))

        // 2. OpenAI with no key yet -> No key state.
        let openAIRow = app.buttons["providerRow-openai"]
        XCTAssertTrue(reveal(openAIRow, in: app, swipes: 6))
        openAIRow.tap()
        XCTAssertTrue(app.navigationBars["OpenAI"].waitForExistence(timeout: 10))
        let noKeyState = any(app, "modelsState-noKey")
        XCTAssertTrue(waitOrDump(noKeyState, timeout: 5, in: app))
        XCTAssertFalse(any(app, "refreshModels").exists)
        capture("p1-state-no-key-dark")

        // 3. Point baseURL at local server returning 401 and add a test key -> Fetch failed state.
        server.setResponse(status: 401, body: #"{"error":{"message":"invalid_api_key"}}"#)
        let baseURLField = app.textFields["baseURLField"]
        XCTAssertTrue(reveal(baseURLField, in: app, swipes: 3))
        replaceFieldText(baseURLField, with: server.baseURL)

        let apiKeyField = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(reveal(apiKeyField, in: app, swipes: 3))
        apiKeyField.tap()
        apiKeyField.typeText("bad-test-key\n")

        let errorState = any(app, "modelsState-error")
        XCTAssertTrue(waitOrDump(errorState, timeout: 10, in: app))
        XCTAssertTrue(
            app.staticTexts.matching(label(contains: "The key was refused (401). Check it above.")).firstMatch.exists
        )
        capture("p1-state-error-dark")

        // 4. Switch server to 404 and tap Try again -> neutral Nothing listed state.
        server.setResponse(status: 404, body: "Not Found")
        let retry = app.buttons["Try again"]
        XCTAssertTrue(retry.exists)
        retry.tap()

        let emptyState = any(app, "modelsState-empty")
        XCTAssertTrue(waitOrDump(emptyState, timeout: 10, in: app))
        capture("p1-state-empty-dark")

        // 5. Switch server to 22 dated models and Refresh -> Search field appears above 20 models, newest first.
        let manyModelsJSON: String = {
            let items = (1...22).map { index in
                let id = String(format: "gpt-custom-%02d", index)
                let created = 1_750_000_000 + index * 1_000
                return #"{"id":"\#(id)","created":\#(created)}"#
            }.joined(separator: ",")
            return #"{"data":[\#(items)]}"#
        }()
        server.setResponse(status: 200, body: manyModelsJSON)
        let refresh = app.buttons.matching(label(contains: "Refresh")).firstMatch
        XCTAssertTrue(reveal(refresh, in: app, swipes: 3))
        refresh.tap()

        let searchField = app.textFields["searchProviderModels"]
        XCTAssertTrue(waitOrDump(searchField, timeout: 10, in: app))
        XCTAssertTrue(any(app, "modelRow-gpt-custom-22").exists, "Newest model by created timestamp should appear first.")
    }

    func testDarkAndAccessibilitySizeAnthropicRowsWrapCleanly() throws {
        try skipUnlessPhone("Accessibility Dynamic Type layout check runs on iPhone.")

        let ax5 = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
        let app = launch([
            "-UIPreferredContentSizeCategoryName", ax5,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-dc-sample",
            "-dc-forums-home",
            "-dc-show-settings", "provider",
            "-dc-agent-model", "anthropic:claude-sonnet-5-5"
        ])

        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 20))
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        let anthropicRow = app.buttons["providerRow-anthropic"]
        XCTAssertTrue(reveal(anthropicRow, in: app, swipes: 8))
        anthropicRow.tap()

        XCTAssertTrue(app.navigationBars["Anthropic"].waitForExistence(timeout: 10))
        let sonnetRow = any(app, "modelRow-claude-sonnet-5-5")
        XCTAssertTrue(reveal(sonnetRow, in: app, swipes: 4))
        XCTAssertGreaterThan(sonnetRow.frame.height, 64, "Row should expand vertically at accessibility Dynamic Type sizes.")
        capture("p1-iphone-anthropic-ax-dark")
    }

    /// Opt-in live check with `TEST_RUNNER_ANTHROPIC_API_KEY`: fetches real
    /// `GET https://api.anthropic.com/v1/models` and selects `claude-haiku-5-5`
    /// for Agent via `⋯ › Use for Agent`.
    func testLiveAnthropicModelsAndSelectHaikuForAgent() throws {
        let apiKey = (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_ANTHROPIC_API_KEY to run the live Anthropic model list check.")
        }

        XCUIDevice.shared.orientation = Self.resolved(.portrait)
        let app = XCUIApplication()
        app.launchEnvironment["ANTHROPIC_API_KEY"] = apiKey
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-dc-skip-onboarding",
            "-dc-browser-agent-live-key",
            "-dc-browser-agent-live-model", "claude-sonnet-4-5-20250929",
            "-dc-show-settings", "provider"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 20))
        let anthropicRow = app.buttons["providerRow-anthropic"]
        XCTAssertTrue(reveal(anthropicRow, in: app, swipes: 6))
        anthropicRow.tap()

        XCTAssertTrue(app.navigationBars["Anthropic"].waitForExistence(timeout: 10))
        let firstModelRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'modelRow-'"))
            .firstMatch
        XCTAssertTrue(
            waitOrDump(firstModelRow, timeout: 20, in: app),
            "Live Anthropic /v1/models should return model rows."
        )

        let haikuPredicate = NSPredicate(format: "identifier BEGINSWITH 'modelRow-claude-haiku-5-5'")
        var haikuRow = app.descendants(matching: .any).matching(haikuPredicate).firstMatch
        if !haikuRow.exists {
            let showAll = any(app, "showAllModels")
            if reveal(showAll, in: app, swipes: 3) {
                showAll.tap()
            }
            haikuRow = app.descendants(matching: .any).matching(haikuPredicate).firstMatch
        }
        XCTAssertTrue(
            reveal(haikuRow, in: app, swipes: 6),
            "Live Anthropic /v1/models should list claude-haiku-5-5."
        )
        let haikuID = String(haikuRow.identifier.dropFirst("modelRow-".count))
        capture("p1-live-anthropic-before-select")

        tapTrailingMore(on: haikuRow, key: haikuID, in: app)
        let useForAgent = app.buttons.matching(label(contains: "Use for Agent")).firstMatch
        XCTAssertTrue(waitOrDump(useForAgent, timeout: 5, in: app))
        useForAgent.tap()

        XCTAssertTrue(wait(timeout: 5) {
            haikuRow.label.contains("used for Agent")
        }, "Selecting Use for Agent on claude-haiku-5-5 should move the Agent seal; got “\(haikuRow.label)”.")
        capture("p1-live-anthropic-haiku-selected")
        app.terminate()
    }
}

private final class FixtureModelsHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fixture-models-http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var responseStatus = 200
    private var responseBody = #"{"data":[]}"#
    private var count = 0
    private(set) var port: UInt16 = 0

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }
    var requestCount: Int { lock.withLock { count } }

    func setResponse(status: Int, body: String) {
        lock.withLock {
            responseStatus = status
            responseBody = body
        }
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let boundPort = listener.port?.rawValue else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        port = boundPort
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] _, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let (status, body) = self.lock.withLock { () -> (Int, String) in
                self.count += 1
                return (self.responseStatus, self.responseBody)
            }
            let bodyData = Data(body.utf8)
            let reason = HTTPURLResponse.localizedString(forStatusCode: status)
            let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
            var payload = Data(header.utf8)
            payload.append(bodyData)
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
