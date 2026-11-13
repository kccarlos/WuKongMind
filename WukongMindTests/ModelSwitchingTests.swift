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
        settings.setModel(agent, for: .agent)
        return settings
    }

    // MARK: Pill

    func testPillFollowsTheScopesRole() {
        XCTAssertEqual(ModelPill.role(for: .summary), .assistant)
        XCTAssertEqual(ModelPill.role(for: .chat), .assistant, "This topic")
        XCTAssertEqual(ModelPill.role(for: .agent), .agent, "Whole forum")
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

    // MARK: Next question

    func testAChangeAppliesToTheNextQuestionWhileASearchRuns() {
        let running = [ModelSelection(provider: .anthropic, model: "claude-opus")]
        XCTAssertEqual(ModelPill.runningSearchModel(role: .agent, running: running), "claude-opus")
        XCTAssertNil(ModelPill.runningSearchModel(role: .agent, running: []), "no search running")
        XCTAssertNil(ModelPill.runningSearchModel(role: .assistant, running: running), "summaries & chat aren't affected")
        // An Apple Intelligence run records its backend; it shows the provider.
        XCTAssertEqual(
            ModelPill.runningSearchModel(role: .agent, running: [ModelSelection(provider: .appleIntelligence, model: "On-device")]),
            AIProvider.appleIntelligence.displayName
        )
    }

    @MainActor
    func testUIRolesShowAgentAndSummariesWhileForumSearchFollowsAgentThenSummaries() {
        XCTAssertEqual(ModelRole.uiRoles, [.browserAgent, .assistant])
        XCTAssertEqual(ModelRole.browserAgent.title, "Agent")
        XCTAssertEqual(ModelRole.assistant.title, "Summaries")

        let app = makeApp()
        // With no Agent model set, selecting Summaries in Settings › Models also updates transitional forum search (.agent).
        app.selectModel(gemini.selection, for: app.uiScope(for: .assistant))
        XCTAssertNil(app.settings.browserAgentModel)
        XCTAssertEqual(app.selection(for: .assistant), gemini.selection)
        XCTAssertEqual(app.selection(for: .agent), gemini.selection)

        // Setting the Agent model (.browserAgent) makes transitional forum search (.agent) follow it.
        app.selectModel(claude.selection, for: .role(.browserAgent))
        XCTAssertEqual(app.settings.browserAgentModel, claude.selection)
        XCTAssertEqual(app.selection(for: .browserAgent), claude.selection)
        XCTAssertEqual(app.selection(for: .agent), claude.selection)
        XCTAssertEqual(app.selection(for: .assistant), gemini.selection)
        XCTAssertFalse(app.uiRolesShareModel)

        // Clearing the Agent model falls transitional forum search back to Summaries.
        app.clearBrowserAgentModel()
        XCTAssertNil(app.settings.browserAgentModel)
        XCTAssertEqual(app.selection(for: .agent), gemini.selection)

        // Applying a tool-calling model to both UI roles updates Agent, Summaries, and transitional forum search.
        app.applyModelToBothUIRoles(llama.selection)
        XCTAssertTrue(app.uiRolesShareModel)
        XCTAssertEqual(app.selection(for: .browserAgent), llama.selection)
        XCTAssertEqual(app.selection(for: .assistant), llama.selection)
        XCTAssertEqual(app.selection(for: .agent), llama.selection)
    }

    @MainActor
    private func makeApp() -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return AppModel(store: PersistentStore(fileURL: directory.appendingPathComponent("state.json")))
    }
}
