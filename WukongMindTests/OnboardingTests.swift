import Combine
import XCTest
@testable import WukongMind

final class OnboardingTests: XCTestCase {
    func testThereAreThreeStepsInOrder() {
        XCTAssertEqual(OnboardingStep.allCases, [.model, .site, .tryAgent])
        XCTAssertEqual(OnboardingStep.first, .model)
        XCTAssertEqual(OnboardingStep.last, .tryAgent)
        XCTAssertNil(OnboardingStep.tryAgent.next)
        XCTAssertNil(OnboardingStep.model.previous)
        XCTAssertEqual(OnboardingStep.site.previous, .model)
        XCTAssertEqual(OnboardingStep.model.next, .site)
    }

    func testStepsOneAndTwoArePagesAndStepThreeRunsInTheBrowser() {
        XCTAssertEqual(OnboardingStep.allCases.filter(\.isPage), [.model, .site])
        XCTAssertEqual(OnboardingStep.allCases.filter(\.allowsSkip), [.model], "only the model can be left for later")
        XCTAssertEqual(OnboardingStep.allCases.filter(\.hasTextInput), [.model, .site])
    }

    func testLabels() {
        XCTAssertEqual(OnboardingStep.model.accessibilityLabel, "Step 1 of 3: Pick a model")
        XCTAssertEqual(OnboardingStep.site.accessibilityLabel, "Step 2 of 3: Open a site")
        XCTAssertEqual(OnboardingStep.tryAgent.accessibilityLabel, "Step 3 of 3: Try the Agent once")
    }

    func testParseStepNumbersAndNames() {
        XCTAssertEqual(OnboardingStep.parse("1"), .model)
        XCTAssertEqual(OnboardingStep.parse("2"), .site)
        XCTAssertEqual(OnboardingStep.parse("3"), .tryAgent)
        XCTAssertNil(OnboardingStep.parse("4"))
        XCTAssertNil(OnboardingStep.parse("0"))
        XCTAssertEqual(OnboardingStep.parse("site"), .site)
        XCTAssertEqual(OnboardingStep.parse("TryAgent"), .tryAgent)
        XCTAssertNil(OnboardingStep.parse("privacy"), "the deleted steps are gone")
        XCTAssertNil(OnboardingStep.parse("daily"))
    }

    func testStepThreeOffersTwoSentencesTheUserCouldHaveTyped() {
        XCTAssertEqual(AppModel.firstRunSuggestions, ["Make this page easier to read", "Hide everything but the article"])
    }

    func testChineseLanguageSuggestsTheChineseForumsFirst() {
        let chinese = AppModel.onboardingSuggestions(chineseFirst: true).map(\.siteURL)
        XCTAssertEqual(Array(chinese.prefix(2)), ["https://www.uscardforum.com", "https://linux.do"])
        XCTAssertEqual(chinese.count, AppModel.suggestedForums.count + 2)
        let english = AppModel.onboardingSuggestions(chineseFirst: false)
        XCTAssertEqual(english, AppModel.suggestedForums)
        XCTAssertTrue(SiteRegistry.standard.adapters.flatMap(\.suggestedForums.chinese).allSatisfy { ForumSite.normalizeSiteURL($0.siteURL) == $0.siteURL })
    }

    func testEveryProviderHasGuidance() {
        for provider in AIProvider.allCases {
            let guide = ProviderGuide.guide(for: provider)
            XCTAssertFalse(guide.blurb.isEmpty, "\(provider) needs a blurb")
            XCTAssertEqual(guide.link.scheme, "https", "\(provider) link must be https")
            // Local providers link to a download and explain how to reach the computer.
            XCTAssertEqual(guide.isLocal, provider.isLocalServer, "\(provider) local mismatch")
            if guide.isLocal { XCTAssertNotNil(guide.note) }
        }
    }

    func testSettingsRootVoiceTodaySummary() {
        XCTAssertEqual(SettingsRootSummary.voiceToday(seconds: 45, dailyLimitMinutes: 30), "Voice today 1 of 30 min")
        XCTAssertEqual(SettingsVoicePage.minutes(45), "1 min")
        XCTAssertEqual(SettingsRootSummary.voiceToday(seconds: 4 * 60 + 20, dailyLimitMinutes: 30), "Voice today 5 of 30 min")
        XCTAssertEqual(SettingsVoicePage.minutes(4 * 60 + 20), "5 min")
        XCTAssertEqual(SettingsRootSummary.voiceToday(seconds: 0, dailyLimitMinutes: 0), "Voice today 0 min")
    }

    func testSettingsPagesParseAndHaveTitles() {
        XCTAssertEqual(SettingsPage.parse("forums"), .forums)
        XCTAssertEqual(SettingsPage.parse("Provider"), .provider)
        XCTAssertNil(SettingsPage.parse("root"))
        for page in SettingsPage.allCases {
            XCTAssertFalse(page.title.isEmpty)
            XCTAssertFalse(page.systemImage.isEmpty)
        }
        // UI tests look for this row label on the Settings root.
        XCTAssertEqual(SettingsPage.provider.title, "Models")
        XCTAssertEqual(SettingsPage.browser.title, "Browser")
    }

    @MainActor
    func testSyncStatusPresentation() {
        let off = SyncStatusPresentation(.off)
        XCTAssertNil(off.action)
        XCTAssertEqual(off.shortLabel, "Off")
        XCTAssertEqual(SyncStatusPresentation(.noAccount).detail, "Sign in to iCloud in the Settings app to sync across your devices.")
        XCTAssertEqual(SyncStatusPresentation(.restricted).detail, "iCloud is turned off for WukongMind in Settings › [your name] › iCloud.")
        XCTAssertEqual(SyncStatusPresentation(.unavailable("Try later")).detail, "Try later")
        XCTAssertTrue(SyncStatusPresentation(.syncing).isBusy)
        XCTAssertEqual(SyncStatusPresentation(.upToDate).shortLabel, "On")
        XCTAssertNil(SyncStatusPresentation(.upToDate).action)
        let error = SyncStatusPresentation(.error("Disk full"))
        XCTAssertEqual(error.detail, "Disk full")
        XCTAssertEqual(error.actionTitle, "Sync now")

        XCTAssertEqual(SyncDebug.parse("upToDate"), .upToDate)
        XCTAssertEqual(SyncDebug.parse("no-account"), .noAccount)
        XCTAssertEqual(SyncDebug.parse("restricted"), .restricted)
        XCTAssertNil(SyncDebug.parse("nope"))
        XCTAssertEqual(SettingsPage.parse("sync"), .sync)
        XCTAssertEqual(SettingsPage.sync.title, "iCloud Sync")
        XCTAssertEqual(SettingsPage.parse("sites"), .sites)
        XCTAssertEqual(SettingsPage.sites.title, "Sites")
        XCTAssertEqual(SettingsPage.provider.title, "Models")
        XCTAssertEqual(SettingsPage.agent.title, "Agent")
        XCTAssertEqual(SettingsPage.scripts.title, "Scripts & tools")
        XCTAssertEqual(SettingsPage.watched.title, "Following")
        XCTAssertNil(SettingsPage.parse("summaries"), "Summaries & chat is folded into Models and Sites")
        XCTAssertEqual(SettingsPage.agent.tint, DCTheme.gold)
        XCTAssertEqual(SettingsPage.provider.tint, DCTheme.ink)
    }

    func testSearchEngineAndAgentSettingsDefaultsAndPersistence() throws {
        let stock = AppSettings()
        XCTAssertEqual(stock.searchEngine, .google)
        XCTAssertFalse(stock.agentConfirmBeforeWrites)
        XCTAssertFalse(stock.agentDeveloperMode)
        XCTAssertTrue(SyncSettings.deviceLocalKeys.contains("agentDeveloperMode"))
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("searchEngine"))
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("agentConfirmBeforeWrites"))

        XCTAssertEqual(
            SearchEngine.google.searchURL(for: "swift concurrency")?.absoluteString,
            "https://www.google.com/search?q=swift%20concurrency"
        )
        XCTAssertEqual(
            SearchEngine.duckDuckGo.searchURL(for: "wukong")?.absoluteString,
            "https://duckduckgo.com/?q=wukong"
        )
        XCTAssertEqual(
            SearchEngine.bing.searchURL(for: "discourse")?.absoluteString,
            "https://www.bing.com/search?q=discourse"
        )
        XCTAssertEqual(
            SearchEngine.ecosia.searchURL(for: "trees")?.absoluteString,
            "https://www.ecosia.org/search?q=trees"
        )
        XCTAssertNil(SearchEngine.google.searchURL(for: "   "))

        // Existing saved JSON without the new keys decodes cleanly with stock defaults (no migration).
        let bare = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(bare, stock)

        var edited = AppSettings()
        edited.searchEngine = .duckDuckGo
        edited.agentConfirmBeforeWrites = true
        edited.agentDeveloperMode = true
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(roundTrip.searchEngine, .duckDuckGo)
        XCTAssertTrue(roundTrip.agentConfirmBeforeWrites)
        XCTAssertTrue(roundTrip.agentDeveloperMode)
    }

    func testVersionText() {
        XCTAssertEqual(
            AppVersion.text(info: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "34"]),
            "1.2 (34)"
        )
        XCTAssertEqual(AppVersion.text(info: nil), "— (—)")
    }
}

/// "Show onboarding again" from a Settings sheet: the sheet goes first,
/// then the walkthrough covers the screen; Settings doesn't come back
/// (audit A6).
@MainActor
final class OnboardingReplayTests: XCTestCase {
    private func model() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let app = AppModel(store: store)
        app.settings.hasCompletedOnboarding = true
        return app
    }

    func testFromASettingsSheetTheSheetGoesFirst() async throws {
        let app = try model()
        let delay = PresentationRouter.settleDelay
        let fallback = PresentationRouter.dismissalFallback
        PresentationRouter.settleDelay = .milliseconds(10)
        // Out of reach: only the dismissal can bring the walkthrough, however
        // long the runner takes to schedule it.
        PresentationRouter.dismissalFallback = .seconds(600)
        defer {
            PresentationRouter.settleDelay = delay
            PresentationRouter.dismissalFallback = fallback
        }
        app.router.item = .expanded(.settings)
        XCTAssertEqual(app.rootPresentation, .expanded(.settings))
        app.replayOnboarding()
        XCTAssertEqual(app.router.onboardingReplay, .waitingForSheet)
        XCTAssertNil(app.rootPresentation, "nothing while the sheet leaves")
        app.replayOnboarding()
        XCTAssertEqual(app.router.onboardingReplay, .waitingForSheet, "a second tap changes nothing")
        let shown = expectation(description: "Onboarding follows the sheet dismissal")
        let observation = app.router.$onboardingReplay
            .filter { $0 == .showing }.prefix(1)
            .sink { _ in shown.fulfill() }
        defer { observation.cancel() }
        app.rootSheetDismissed()
        XCTAssertNil(app.rootPresentation, "a beat for the sheet to leave for good")
        // A generous bound: a slow runner can stall the main thread for
        // seconds, and with the fallback out of reach a pass still proves
        // the dismissal path.
        await fulfillment(of: [shown], timeout: 60)
        XCTAssertEqual(app.rootPresentation, .onboarding)
        app.dismissRootPresentation(.onboarding)
        XCTAssertEqual(app.router.onboardingReplay, .none)
        XCTAssertNil(app.rootPresentation, "Settings does not come back")
    }

    func testWithoutASheetTheWalkthroughShowsAtOnce() throws {
        let app = try model()
        app.replayOnboarding()
        XCTAssertEqual(app.rootPresentation, .onboarding)
    }
}

/// Step 3 runs over the browser after the cover has closed (design-unified.md §5).
@MainActor
final class FirstRunTests: XCTestCase {
    private func model() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AppModel(store: PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore()))
    }

    func testTheFirstRunIsOffUntilTheWalkthroughOpensASite() throws {
        let app = try model()
        XCTAssertNil(app.firstRun)
        XCTAssertEqual(app.rootPresentation, .onboarding, "a fresh install starts with step 1")
        app.completeOnboarding()
        app.firstRun = .prompts
        XCTAssertNil(app.rootPresentation, "the cover is gone; step 3 is not a presentation")
        XCTAssertEqual(app.firstRun, .prompts)
    }

    func testOnboardingIsACoverOnPhoneAndAFormSheetOnPad() {
        XCTAssertEqual(RootPresentation.onboarding.isFullScreen, UIDevice.current.userInterfaceIdiom == .phone)
    }
}
