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

    func testOnboardingSuggestionsAreOrdinaryWebPagesWithChineseWikipediaFirst() {
        let chinese = AppModel.onboardingSuggestions(chineseFirst: true).map(\.siteURL)
        XCTAssertEqual(chinese.first, "https://zh.wikipedia.org")
        XCTAssertEqual(chinese.count, AppModel.suggestedSites.count)
        let english = AppModel.onboardingSuggestions(chineseFirst: false)
        XCTAssertEqual(english, AppModel.suggestedSites)
        XCTAssertTrue(english.allSatisfy { ForumSite.normalizeSiteURL($0.siteURL) == $0.siteURL })
        XCTAssertTrue(english.allSatisfy { !$0.host.contains("discourse") && !$0.host.contains("ycombinator") })
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

    func testProviderGuideHasNoBannedPricingOrPurchaseWords() {
        let bannedWords = ["buy", "credit", "credits", "price", "prices", "pricing", "purchase", "low-cost", "subscription", "free", "bill", "billed", "$"]
        for provider in AIProvider.allCases {
            let guide = ProviderGuide.guide(for: provider)
            let texts = [guide.blurb, guide.linkTitle, guide.note].compactMap { $0 }
            for text in texts {
                let lowered = text.lowercased()
                for banned in bannedWords {
                    if banned == "$" {
                        XCTAssertFalse(lowered.contains("$"), "\(provider) contains banned symbol '$' in: \(text)")
                    } else {
                        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: banned) + #"\b"#
                        XCTAssertNil(
                            lowered.range(of: pattern, options: .regularExpression),
                            "\(provider) contains banned word '\(banned)' in: \(text)"
                        )
                    }
                }
            }
            if provider.requiresAPIKey {
                XCTAssertTrue(guide.linkTitle.hasPrefix("Get a key"), "\(provider) linkTitle must start with 'Get a key', got: \(guide.linkTitle)")
            }
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
        XCTAssertTrue(stock.agentConfirmBeforeWrites)
        XCTAssertFalse(stock.agentShareCookieValues)
        XCTAssertFalse(stock.agentSaveScriptsWithoutAsking)
        XCTAssertFalse(stock.agentDeveloperMode)
        XCTAssertTrue(SyncSettings.deviceLocalKeys.contains("agentDeveloperMode"))
        XCTAssertTrue(SyncSettings.deviceLocalKeys.contains("didMigrateAgentConfirmBeforeWritesDefault"))
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("searchEngine"))
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("agentConfirmBeforeWrites"))
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("agentShareCookieValues"))
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("agentSaveScriptsWithoutAsking"))

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

        // Existing saved JSON without the new keys decodes cleanly with stock defaults.
        let bare = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(bare, stock)

        var edited = AppSettings()
        edited.searchEngine = .duckDuckGo
        edited.agentConfirmBeforeWrites = false
        edited.agentShareCookieValues = true
        edited.agentSaveScriptsWithoutAsking = true
        edited.agentDeveloperMode = true
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(roundTrip.searchEngine, .duckDuckGo)
        XCTAssertFalse(roundTrip.agentConfirmBeforeWrites)
        XCTAssertTrue(roundTrip.agentShareCookieValues)
        XCTAssertTrue(roundTrip.agentSaveScriptsWithoutAsking)
        XCTAssertTrue(roundTrip.agentDeveloperMode)
    }

    func testConfirmBeforeWritesUpgradeMigrationTurnsOnOnceAndPreservesLaterOffChoice() throws {
        // Pre-upgrade saved settings stored `agentConfirmBeforeWrites: false` without the migration flag.
        let legacyJSON = #"{"agentConfirmBeforeWrites":false}"#
        var upgraded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(upgraded.agentConfirmBeforeWrites, "Upgrade turns Confirm before writes on once")
        XCTAssertTrue(upgraded.didMigrateAgentConfirmBeforeWritesDefault)
        XCTAssertFalse(upgraded.agentShareCookieValues)
        XCTAssertFalse(upgraded.agentSaveScriptsWithoutAsking)

        // Once the user turns it off again and saves, subsequent loads keep it off.
        upgraded.agentConfirmBeforeWrites = false
        let encoded = try JSONEncoder().encode(upgraded)
        let afterUserTurnedOff = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertFalse(afterUserTurnedOff.agentConfirmBeforeWrites)
        XCTAssertTrue(afterUserTurnedOff.didMigrateAgentConfirmBeforeWritesDefault)

        // Syncing a remote `agentConfirmBeforeWrites: false` into an upgraded device keeps it off.
        let merged = try SyncSchema.applying(
            settingsUnits: ["agentConfirmBeforeWrites": .bool(false)],
            to: AppSettings()
        )
        XCTAssertFalse(merged.agentConfirmBeforeWrites)
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
        app.settings.acceptedTermsVersion = TermsOfUse.currentVersion
        return app
    }

    func testOpenProviderGuideLinkOpensTabAndDismissesModals() throws {
        let app = try model()
        app.settings.hasCompletedOnboarding = false
        app.router.onboardingReplay = .showing
        app.requestedSettingsPage = .provider
        app.needsProviderSetup = .browserAgent

        let url = ProviderGuide.guide(for: .openRouter).link
        let initialCount = app.tabs.tabs.count
        app.openProviderGuideLink(url)

        XCTAssertTrue(app.settings.hasCompletedOnboarding)
        XCTAssertEqual(app.router.onboardingReplay, .none)
        XCTAssertNil(app.requestedSettingsPage)
        XCTAssertNil(app.needsProviderSetup)
        XCTAssertEqual(app.tabs.tabs.count, initialCount + 1)
        XCTAssertEqual(app.browser.currentURL, url)
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
        XCTAssertEqual(app.rootPresentation, .termsGate, "a fresh install starts with Terms of Use")
        app.acceptTerms()
        XCTAssertEqual(app.rootPresentation, .onboarding, "onboarding follows Terms acceptance")
        app.completeOnboarding()
        app.firstRun = .prompts
        XCTAssertNil(app.rootPresentation, "the cover is gone; step 3 is not a presentation")
        XCTAssertEqual(app.firstRun, .prompts)
    }

    func testRootPresentationOrderingTable() throws {
        struct Case {
            let name: String
            let acceptedTermsVersion: Int
            let hasCompletedOnboarding: Bool
            let replay: OnboardingReplay
            let pendingAIConsent: AIProvider?
            let expected: RootPresentation?
        }

        let cases: [Case] = [
            Case(
                name: "fresh install shows Terms first",
                acceptedTermsVersion: 0,
                hasCompletedOnboarding: false,
                replay: .none,
                pendingAIConsent: nil,
                expected: .termsGate
            ),
            Case(
                name: "fresh install with pending AI consent still shows Terms first",
                acceptedTermsVersion: 0,
                hasCompletedOnboarding: false,
                replay: .none,
                pendingAIConsent: .anthropic,
                expected: .termsGate
            ),
            Case(
                name: "terms accepted + onboarding incomplete shows onboarding",
                acceptedTermsVersion: TermsOfUse.currentVersion,
                hasCompletedOnboarding: false,
                replay: .none,
                pendingAIConsent: nil,
                expected: .onboarding
            ),
            Case(
                name: "old terms version + onboarding done shows Terms gate",
                acceptedTermsVersion: 0,
                hasCompletedOnboarding: true,
                replay: .none,
                pendingAIConsent: nil,
                expected: .termsGate
            ),
            Case(
                name: "replay shows onboarding only and never Terms gate",
                acceptedTermsVersion: TermsOfUse.currentVersion,
                hasCompletedOnboarding: true,
                replay: .showing,
                pendingAIConsent: nil,
                expected: .onboarding
            ),
            Case(
                name: "completed user with current terms has no root presentation",
                acceptedTermsVersion: TermsOfUse.currentVersion,
                hasCompletedOnboarding: true,
                replay: .none,
                pendingAIConsent: nil,
                expected: nil
            )
        ]

        for testCase in cases {
            let app = try model()
            app.settings.acceptedTermsVersion = testCase.acceptedTermsVersion
            app.settings.hasCompletedOnboarding = testCase.hasCompletedOnboarding
            app.router.onboardingReplay = testCase.replay
            if let provider = testCase.pendingAIConsent {
                app.aiConsent.ask(provider)
            }
            XCTAssertEqual(app.rootPresentation, testCase.expected, testCase.name)
        }

        // Accepting Terms on an existing user with onboarding already done clears the gate without re-running onboarding.
        let existing = try model()
        existing.settings.hasCompletedOnboarding = true
        existing.settings.acceptedTermsVersion = 0
        XCTAssertEqual(existing.rootPresentation, .termsGate)
        existing.acceptTerms()
        XCTAssertNil(existing.rootPresentation)
    }

    func testOpenInAppWebPageActionFiltersHTTPAndHTTPSOnly() {
        var opened: [URL] = []
        let action = OpenInAppWebPageAction { opened.append($0) }
        let httpsURL = URL(string: "https://console.anthropic.com/settings/keys")!
        let httpURL = URL(string: "http://example.com")!
        let settingsURL = URL(string: UIApplication.openSettingsURLString)!
        let mailtoURL = URL(string: "mailto:support@example.com")!

        XCTAssertTrue(action(httpsURL))
        XCTAssertTrue(action(httpURL))
        XCTAssertFalse(action(settingsURL))
        XCTAssertFalse(action(mailtoURL))
        XCTAssertEqual(opened, [httpsURL, httpURL])

        let unset = OpenInAppWebPageAction()
        XCTAssertFalse(unset(httpsURL))
    }

    func testOnboardingIsACoverOnPhoneAndAFormSheetOnPad() {
        XCTAssertEqual(RootPresentation.onboarding.isFullScreen, UIDevice.current.userInterfaceIdiom == .phone)
    }
}
