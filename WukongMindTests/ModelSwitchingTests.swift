import XCTest
@testable import WukongMind

/// §6 model switching: the drawer pill's role, favorites (Apple Intelligence
/// is an ordinary provider), the not-ready card and the "applies to your
/// next question" footer. Keys are fakes.
final class ModelSwitchingTests: XCTestCase {
    private let available = AppleIntelligenceStatus.available(.onDevice)
    private let apple = FavoriteModel(provider: .appleIntelligence, model: "Automatic")
    private let claude = FavoriteModel(provider: .anthropic, model: "claude-sonnet")
    private let gemini = FavoriteModel(provider: .gemini, model: "gemini-flash")
    private let llama = FavoriteModel(provider: .ollama, model: "llama3.1")

    private func settings(
        assistant: ModelSelection,
        agent: ModelSelection,
        favorites: [FavoriteModel],
        keys: [AIProvider] = []
    ) -> AppSettings {
        var settings = AppSettings()
        settings.favoriteModels = favorites
        for provider in keys {
            var configuration = settings.configuration(for: provider)
            configuration.apiKey = "fake-key"
            settings.setConfiguration(configuration, for: provider)
        }
        settings.setModel(assistant, for: .assistant)
        settings.setModel(agent, for: .browserAgent)
        return settings
    }

    // MARK: Pill

    func testPillFollowsTheScopesRole() {
        XCTAssertEqual(ModelPill.role(for: .summary), .assistant)
        XCTAssertEqual(ModelPill.role(for: .browserAgent), .browserAgent)
    }

    func testPillLabelShowsTheModelOrTheProviderForAppleIntelligence() {
        XCTAssertEqual(ModelPill.label(for: claude.selection), "claude-sonnet")
        // The stored "Automatic" placeholder never shows.
        XCTAssertEqual(ModelPill.label(for: apple.selection), AIProvider.appleIntelligence.displayName)
        XCTAssertEqual(ModelPill.label(for: ModelSelection(provider: .openAI, model: " ")), AIProvider.openAI.displayName)
    }

    // MARK: Favorites

    func testFavoritesKeepTheUsersOrderWithAppleIntelligenceLikeAnyOther() {
        let favorites = [claude, apple, llama]
        XCTAssertEqual(ModelFavorites.visible(favorites, appleIntelligence: available), favorites, "not pinned to the top")
        // Not starred: not listed, even when a role uses it.
        XCTAssertEqual(ModelFavorites.visible([claude, llama], appleIntelligence: available), [claude, llama])
        // Fixable reasons keep it (shown as not ready); a device that can
        // never run it hides it.
        XCTAssertEqual(ModelFavorites.visible(favorites, appleIntelligence: .unavailable(.appleIntelligenceNotEnabled)), favorites)
        XCTAssertEqual(ModelFavorites.visible(favorites, appleIntelligence: .unavailable(.deviceNotEligible)), [claude, llama])
        XCTAssertEqual(ModelFavorites.visible(favorites, appleIntelligence: .unavailable(.requiresNewerOS)), [claude, llama])
    }

    @MainActor
    func testAppleIntelligenceCanBeStarredAndIsAppendedLikeAnyFavorite() {
        let app = makeApp()
        app.settings.favoriteModels = [claude]
        app.selectModel(apple.selection, for: .role(.assistant))
        XCTAssertFalse(app.isFavorite(app.selection(for: .assistant)))
        app.addCurrentFavorite(for: .assistant)
        XCTAssertEqual(app.settings.favoriteModels, [claude, apple])
        // Any Apple Intelligence selection is the one entry.
        XCTAssertTrue(app.isFavorite(ModelSelection(provider: .appleIntelligence, model: "On-device")))
        app.removeFavorite(matching: app.selection(for: .assistant))
        XCTAssertEqual(app.settings.favoriteModels, [claude])
    }

    func testAddingAFavoriteRespectsTheLimitAndDuplicates() {
        XCTAssertNil(ModelFavorites.adding(claude, to: [claude]))
        let full = (0..<ModelFavorites.limit).map { FavoriteModel(provider: .openAI, model: "m\($0)") }
        XCTAssertNil(ModelFavorites.adding(claude, to: full))
        XCTAssertEqual(ModelFavorites.adding(gemini, to: [claude]), [claude, gemini])
    }

    // MARK: Not ready

    func testReadinessSaysWhatIsMissing() {
        let settings = settings(assistant: gemini.selection, agent: claude.selection, favorites: [], keys: [.anthropic])
        XCTAssertEqual(settings.readiness(of: gemini.selection, appleIntelligence: available), .needsKey)
        XCTAssertEqual(settings.readiness(of: claude.selection, appleIntelligence: available), .ready)
        XCTAssertEqual(settings.readiness(of: ModelSelection(provider: .anthropic, model: ""), appleIntelligence: available), .needsModel)
        XCTAssertEqual(settings.readiness(of: llama.selection, appleIntelligence: available), .ready, "no key needed")
        XCTAssertEqual(
            settings.readiness(of: apple.selection, appleIntelligence: .unavailable(.modelNotReady)),
            .appleIntelligence(.modelNotReady)
        )
    }

    func testTheNotReadyCardOffersOneFixAndTheReadyModels() {
        XCTAssertEqual(ModelSetupAction(.needsKey, provider: .gemini), .addKey(.gemini))
        XCTAssertEqual(ModelSetupAction(.needsModel, provider: .anthropic), .chooseModel)
        XCTAssertEqual(ModelSetupAction(.appleIntelligence(.appleIntelligenceNotEnabled), provider: .appleIntelligence), .aiModels)

        let settings = settings(
            assistant: gemini.selection,
            agent: ModelSelection(provider: .anthropic, model: "claude-opus"),
            favorites: [apple, gemini, claude, FavoriteModel(provider: .openAI, model: "gpt-5")],
            keys: [.anthropic]
        )
        // Ready favorites in order (not the role's own, not the keyless
        // one), then the other role's unstarred model.
        XCTAssertEqual(
            ModelFavorites.readyAlternatives(settings: settings, role: .assistant, appleIntelligence: available),
            [apple, claude, FavoriteModel(provider: .anthropic, model: "claude-opus")]
        )
        // Without Apple Intelligence on this device it isn't offered.
        XCTAssertEqual(
            ModelFavorites.readyAlternatives(settings: settings, role: .assistant, appleIntelligence: .unavailable(.deviceNotEligible)),
            [claude, FavoriteModel(provider: .anthropic, model: "claude-opus")]
        )
    }

    @MainActor
    func testThereAreTwoModelRolesAndEachIsSetOnItsOwn() {
        XCTAssertEqual(ModelRole.allCases, [.assistant, .browserAgent, .scripts])
        XCTAssertEqual(ModelRole.uiRoles, [.browserAgent, .assistant])
        XCTAssertEqual(ModelRole.settingsRoles, [.browserAgent, .assistant, .scripts])
        XCTAssertEqual(ModelRole.assistant.other, .browserAgent)
        XCTAssertEqual(ModelRole.browserAgent.other, .assistant)
        XCTAssertEqual(ModelRole.scripts.other, .assistant)
        XCTAssertEqual(ModelRole.browserAgent.title, "Agent")
        XCTAssertEqual(ModelRole.assistant.title, "Summaries")
        XCTAssertEqual(ModelRole.scripts.title, "Scripts")

        let app = makeApp()
        // Selecting Summaries never sets the Agent model.
        app.selectModel(gemini.selection, for: app.uiScope(for: .assistant))
        XCTAssertNil(app.settings.browserAgentModel)
        XCTAssertEqual(app.selection(for: .assistant), gemini.selection)

        // The Agent model is set only by an explicit Agent choice.
        app.selectModel(claude.selection, for: .role(.browserAgent))
        XCTAssertEqual(app.settings.browserAgentModel, claude.selection)
        XCTAssertEqual(app.selection(for: .browserAgent), claude.selection)
        XCTAssertEqual(app.selection(for: .assistant), gemini.selection)
        XCTAssertFalse(app.uiRolesShareModel)

        // Clearing the Agent model leaves Summaries as it was.
        app.clearBrowserAgentModel()
        XCTAssertNil(app.settings.browserAgentModel)

        // Applying a tool-calling model to both roles updates Agent and Summaries.
        app.applyModelToBothUIRoles(llama.selection)
        XCTAssertTrue(app.uiRolesShareModel)
        XCTAssertEqual(app.selection(for: .browserAgent), llama.selection)
        XCTAssertEqual(app.selection(for: .assistant), llama.selection)
    }

    /// Settings saved before One loop carry an `agentModel` and `agentMaxSteps`:
    /// they decode, are dropped, and are not written back.
    func testSettingsWithAnOldAgentRoleDecodeAndDropIt() throws {
        let json = """
        {"assistantModel":{"provider":"groq","model":"m"},
         "agentModel":{"provider":"deepSeek","model":"deepseek-v4-flash"},
         "agentMaxSteps":40,"agentMaxTopicReads":12,"agentReadLimit":50000,
         "browserAgentModel":{"provider":"anthropic","model":"claude-haiku-5-5"}}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.assistantModel.provider, .groq)
        XCTAssertEqual(settings.browserAgentModel?.model, "claude-haiku-5-5")
        XCTAssertEqual(settings.agentMaxTopicReads, 12)
        XCTAssertEqual(settings.agentReadLimit, 50_000)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertNil(object["agentModel"])
        XCTAssertNil(object["agentMaxSteps"])
        XCTAssertNotNil(object["agentMaxTopicReads"])
        XCTAssertNotNil(ModelRole(rawValue: "browserAgent"))
        XCTAssertNil(ModelRole(rawValue: "agent"))
    }

    // MARK: Added-by-name models (P2)

    @MainActor
    func testAddAndRemoveCustomModelsGuardActiveRolesAndPinUnlistedRoleModels() throws {
        let app = makeApp()
        app.selectModel(ModelSelection(provider: .anthropic, model: "claude-haiku-5-5"), for: .role(.assistant))
        app.selectModel(ModelSelection(provider: .anthropic, model: "legacy-gateway-sonnet"), for: .role(.browserAgent))

        // Before the provider's list is fetched (fetchedIDs == nil), only explicitly added models pin.
        XCTAssertEqual(app.pinnedAddedModelIDs(for: .anthropic, fetchedIDs: nil), [])

        app.addCustomModel("  my-gateway/claude-x \n", for: .anthropic)
        app.addCustomModel("my-gateway/claude-y", for: .anthropic)
        // Re-adding an existing model moves it to the top without duplicating.
        app.addCustomModel("my-gateway/claude-x", for: .anthropic)
        XCTAssertEqual(app.addedModels(for: .anthropic), ["my-gateway/claude-x", "my-gateway/claude-y"])
        XCTAssertEqual(
            app.pinnedAddedModelIDs(for: .anthropic, fetchedIDs: nil),
            ["my-gateway/claude-x", "my-gateway/claude-y"]
        )

        // Apple Intelligence has one fixed model and ignores add-by-name.
        app.addCustomModel("custom-apple", for: .appleIntelligence)
        XCTAssertEqual(app.addedModels(for: .appleIntelligence), [])
        XCTAssertEqual(app.pinnedAddedModelIDs(for: .appleIntelligence, fetchedIDs: ["Automatic"]), [])

        // Once fetchedIDs is known, unlisted active-role models follow explicitly added models; listed ones do not.
        let fetched: Set<String> = ["claude-haiku-5-5", "claude-sonnet-5-5"]
        XCTAssertEqual(
            app.pinnedAddedModelIDs(for: .anthropic, fetchedIDs: fetched),
            ["my-gateway/claude-x", "my-gateway/claude-y", "legacy-gateway-sonnet"]
        )

        // Remove is refused while Agent, Summaries, or Scripts uses the model.
        app.selectModel(ModelSelection(provider: .anthropic, model: "my-gateway/claude-x"), for: .role(.browserAgent))
        XCTAssertEqual(
            app.activeRoles(using: ModelSelection(provider: .anthropic, model: "my-gateway/claude-x")),
            [.browserAgent]
        )
        app.removeCustomModel("my-gateway/claude-x", for: .anthropic)
        XCTAssertTrue(app.addedModels(for: .anthropic).contains("my-gateway/claude-x"))

        // Moving Agent away and configuring Scripts on it still blocks removal.
        app.selectModel(ModelSelection(provider: .anthropic, model: "claude-sonnet-5-5"), for: .role(.browserAgent))
        app.selectModel(ModelSelection(provider: .anthropic, model: "my-gateway/claude-x"), for: .role(.scripts))
        app.removeCustomModel("my-gateway/claude-x", for: .anthropic)
        XCTAssertTrue(app.addedModels(for: .anthropic).contains("my-gateway/claude-x"))

        // Clearing Scripts ("Same as Summaries") leaves no role on my-gateway/claude-x, allowing removal.
        app.clearScriptsModel()
        app.removeCustomModel("my-gateway/claude-x", for: .anthropic)
        XCTAssertEqual(app.addedModels(for: .anthropic), ["my-gateway/claude-y"])
        app.removeCustomModel("my-gateway/claude-y", for: .anthropic)
        XCTAssertEqual(app.settings.addedModels, [:])

        // Codable + SyncSchema round-trip preserves addedModels.
        app.addCustomModel("my-gateway/claude-z", for: .anthropic)
        let units = try SyncSchema.settingsUnits(app.settings)
        let merged = try SyncSchema.applying(settingsUnits: units, to: AppSettings())
        XCTAssertEqual(merged.addedModels(for: .anthropic), ["my-gateway/claude-z"])
    }

    // MARK: Model choice and provider check (State 4)

    func testModelChoiceTable() {
        let cases: [(provider: AIProvider, model: String, choice: ModelChoice)] = [
            (.anthropic, "", .none),
            (.anthropic, "   \n", .none),
            (.anthropic, "claude-haiku-5-5", .model(.anthropic, "claude-haiku-5-5")),
            (.openAI, " gpt-test ", .model(.openAI, "gpt-test")),
        ]
        for row in cases {
            let selection = ModelSelection(provider: row.provider, model: row.model)
            XCTAssertEqual(selection.choice, row.choice, "\(row.provider) '\(row.model)'")
            XCTAssertEqual(selection.hasModel, row.choice != .none)
            XCTAssertEqual(selection.supportsToolCalling, row.provider.supportsToolCalling && row.choice != .none)
        }
        XCTAssertNil(ModelChoice.none.provider)
        XCTAssertNil(ModelChoice.none.model)
        XCTAssertEqual(ModelChoice.model(.openAI, "m").provider, .openAI)
        XCTAssertEqual(ModelChoice.model(.openAI, "m").model, "m")
    }

    /// Settings as 1.5.0 saved them (an Agent with a provider and no model,
    /// a favorite, a key) load and save back unchanged.
    func testSettingsRecordedByVersion150LoadUnchanged() throws {
        let recorded = """
        {"assistantModel":{"provider":"openai","model":"gpt-test"},
         "browserAgentModel":{"provider":"anthropic","model":""},
         "scriptsModel":{"provider":"groq","model":"llama-x"},
         "favoriteModels":[{"provider":"anthropic","model":"claude-haiku-5-5"}],
         "configurations":{"openai":{"baseURL":"https://api.openai.com/v1","apiKey":"fake-key"}},
         "addedModels":{"openai":["gpt-extra"]},
         "browserAgentMaxSteps":30}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(recorded.utf8))
        XCTAssertEqual(settings.assistantModel, ModelSelection(provider: .openAI, model: "gpt-test"))
        XCTAssertEqual(settings.browserAgentModel, ModelSelection(provider: .anthropic, model: ""))
        XCTAssertEqual(settings.browserAgentModel?.choice, ModelChoice.none)
        XCTAssertEqual(settings.scriptsModel, ModelSelection(provider: .groq, model: "llama-x"))
        XCTAssertEqual(settings.favoriteModels, [FavoriteModel(provider: .anthropic, model: "claude-haiku-5-5")])
        XCTAssertEqual(settings.configuration(for: .openAI).apiKey, "fake-key")
        XCTAssertNil(settings.configuredBrowserAgentModel)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        let agent = try XCTUnwrap(object["browserAgentModel"] as? [String: String])
        XCTAssertEqual(agent, ["provider": "anthropic", "model": ""])
        let assistant = try XCTUnwrap(object["assistantModel"] as? [String: String])
        XCTAssertEqual(assistant, ["provider": "openai", "model": "gpt-test"])
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(again, settings)
    }

    /// A check's result counts only for the key, address and model it tested.
    @MainActor
    func testProviderCheckTransitionsAndDropsResultWhenInputsChange() {
        let app = makeApp()
        func configuration(key: String) -> ProviderConfiguration {
            var configuration = app.settings.configuration(for: .openAI)
            configuration.apiKey = key
            return configuration
        }
        func use(key: String) { app.setConfiguration(configuration(key: key), for: .openAI) }

        use(key: "key-1")
        XCTAssertEqual(app.providerTestState(for: .openAI, model: "m1"), .idle, "untested")

        let phases: [(ProviderCheck.Phase, ProviderTestState)] = [
            (.testing, .testing),
            (.ok, .success),
            (.failed("nope"), .failure("nope")),
            (.untested, .idle),
        ]
        for (phase, shown) in phases {
            app.recordProviderCheck(phase, provider: .openAI, configuration: configuration(key: "key-1"), model: "m1")
            XCTAssertEqual(app.providerTestState(for: .openAI, model: "m1"), shown)
        }

        // Other model: dropped. Other provider: not affected. Whitespace: same.
        app.recordProviderCheck(.ok, provider: .openAI, configuration: configuration(key: "key-1"), model: "m1")
        XCTAssertEqual(app.providerTestState(for: .openAI, model: "m2"), .idle)
        XCTAssertEqual(app.providerTestState(for: .groq, model: "m1"), .idle)
        XCTAssertEqual(app.providerTestState(for: .openAI, model: " m1 "), .success)

        // Key changed: dropped, and the record is gone.
        use(key: "key-2")
        XCTAssertEqual(app.providerTestState(for: .openAI, model: "m1"), .idle)
        XCTAssertNil(app.providerChecks[.openAI])

        // Back to the old key after a new result: only the new result counts.
        app.recordProviderCheck(.failed("x"), provider: .openAI, configuration: configuration(key: "key-2"), model: "m1")
        XCTAssertEqual(app.providerTestState(for: .openAI, model: "m1"), .failure("x"))
        app.resetSettings()
        XCTAssertTrue(app.providerChecks.isEmpty)
    }

    @MainActor
    private func makeApp() -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return AppModel(store: PersistentStore(fileURL: directory.appendingPathComponent("state.json")))
    }
}
