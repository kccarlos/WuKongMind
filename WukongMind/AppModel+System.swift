import AppIntents
import Foundation

// MARK: - System entry points (System/)
//
// - `perform(_:)`                 an App Intent's action (SystemEntry.swift)
// - `openTopic(topicKey:)`        Spotlight results, Siri suggestions, Open Topic
// - `requestedSettingsPage`       a Settings page RootView presents (AppModel.swift)
// - Spotlight: `spotlightDataDidChange()` after any session or forum change;
//   `spotlightEntries` is what should be indexed (nil while the switch is off)
// - Siri suggestions: `topicActivityDidChange(_:)` donates the open topic

extension AppModel: SystemEntryRouting {
    /// An outside request may start AI work only once the walkthrough is done;
    /// before that it only opens the app.
    var acceptsSystemWork: Bool {
        settings.hasCompletedOnboarding
    }

    func perform(_ action: SystemEntryAction) {
        noteExternalEntry()
        switch action {
        case .summarize(let url):
            // The share extension's path: open the topic, then summarize
            // it once the page is detected (or ask for a provider).
            handle(IncomingLinkRequest(url: url, action: .summary), autoRun: acceptsSystemWork)
        case .ask(let siteURL, let question):
            ask(question, siteURL: siteURL)
        case .openToday:
            showsTodayPage = true
        case .playToday:
            podcast.refresh()
            if podcast.episode?.entries.contains(where: \.isReady) == true {
                podcast.playEpisode()
            } else {
                showsTodayPage = true
            }
        case .startVoice:
            startVoiceFromSystem()
        case .openTopic(let topicKey):
            openTopic(topicKey: topicKey)
        }
    }

    /// Ask a Forum: the forum opens and the question goes to the Agent once
    /// the forum's page is up, so the run has that forum's tools. Not ready
    /// (no model, walkthrough not done, a run going): the question waits in
    /// the composer.
    private func ask(_ question: String, siteURL: String) {
        if let forum = forum(for: siteURL), pageContext.siteURL != forum.siteURL || browser.showsForumsHome {
            openForum(forum)
        }
        assistantMode = .browserAgent
        panelRoute = .topic
        requestAssistant()
        guard acceptsSystemWork, isProviderReady(for: .browserAgent), !browserAgent.isRunning else {
            drafts.goal = question
            if !isProviderReady(for: .browserAgent) { needsProviderSetup = .browserAgent }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.waitForForumPage(siteURL: siteURL), !self.browserAgent.isRunning {
                self.browserAgent.send(question, origin: .shortcut)
            } else {
                self.drafts.goal = question
            }
        }
    }

    /// Waits (up to `timeout`) until the browser shows a page of `siteURL`'s
    /// forum that the Agent's forum tools recognize.
    func waitForForumPage(siteURL: String, timeout: Duration = .seconds(15)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if pageContext.isForum, pageContext.siteURL == siteURL, !browser.isLoading { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// Starts voice; without a Gemini or Vertex key, Settings › Voice.
    private func startVoiceFromSystem() {
        guard voiceProvider != nil else {
            requestedSettingsPage = .voice
            return
        }
        voice.start()
        switch voice.startFailure {
        case .noKey, .noVertexProject:
            voice.dismiss()
            requestedSettingsPage = .voice
        default:
            break
        }
    }

    /// Opens a saved topic at the page it was last read at (its URL keeps
    /// the post number Discourse showed then).
    func openTopic(topicKey: String) {
        guard let session = sessions[topicKey] else { return }
        open(session: session)
    }

    var topicEntities: [TopicEntity] {
        (spotlightEntriesIgnoringSwitch ?? []).map(TopicEntity.init(entry:))
    }

    // MARK: Spotlight

    static func makeSpotlightIndexer(index: SpotlightIndexing?, store: PersistentStore) -> SpotlightIndexer {
        if let index {
            return SpotlightIndexer(index: index, baseline: InMemorySpotlightBaseline())
        }
        // Only the app's own store feeds the real index: never tests,
        // previews or the screenshot samples.
        guard store.usesDefaultLocation, !isRunningTests, !isSampleRun else {
            return SpotlightIndexer(index: DisabledSpotlightIndex(), baseline: InMemorySpotlightBaseline())
        }
        return SpotlightIndexer(index: SystemSpotlightIndex(), baseline: UserDefaultsSpotlightBaseline())
    }

    static func makeTopicActivityDonor(store: PersistentStore) -> TopicActivityDonating {
        guard store.usesDefaultLocation, !isRunningTests, !isSampleRun else {
            return DisabledTopicActivityDonor()
        }
        return SystemTopicActivityDonor()
    }

    /// A DEBUG sample or screenshot launch (never in Release builds).
    private static var isSampleRun: Bool {
        #if DEBUG
        AssistantDebug.isActive
        #else
        false
        #endif
    }

    /// The unit-test host: XCTest is loaded, or about to be (the test
    /// runner sets the configuration path before launch). Tests run Debug
    /// builds; a Release build never checks its environment.
    nonisolated static var isRunningTests: Bool {
        #if DEBUG
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }

    /// What Spotlight should hold now; nil while the switch is off.
    var spotlightEntries: [SpotlightEntry]? {
        settings.spotlightEnabled ? spotlightEntriesIgnoringSwitch : nil
    }

    private var spotlightEntriesIgnoringSwitch: [SpotlightEntry]? {
        SpotlightCatalog.entries(sessions: Array(sessions.values), forums: forums)
    }

    /// Sessions or forums changed (any path: deletes, clear all, removing a
    /// forum, iCloud sync): reconcile once things settle.
    func spotlightDataDidChange() {
        spotlight.schedule { [weak self] in self?.spotlightEntries }
    }

    /// Reset settings: drop the index and build it again.
    func resetSpotlightIndex() {
        spotlight.deleteAll()
        spotlightDataDidChange()
    }

    // MARK: Settings

    func systemSettingsDidChange(from old: AppSettings) {
        if old.spotlightEnabled != settings.spotlightEnabled {
            if settings.spotlightEnabled {
                spotlightDataDidChange()
            } else {
                // Off: the app's whole index goes.
                spotlight.deleteAll()
            }
        }
        if old.donatesTopicActivity != settings.donatesTopicActivity {
            if settings.donatesTopicActivity {
                donatedTopicKey = nil
                topicActivityDidChange(currentTopic)
            } else {
                donatedTopicKey = nil
                topicActivityDonor.deleteAll()
            }
        }
    }

    // MARK: Siri suggestions

    /// The open topic changed: offer it to Siri suggestions (once per
    /// visit), or step down when no topic is open.
    func topicActivityDidChange(_ topic: ForumTopic?) {
        guard settings.donatesTopicActivity else { return }
        guard let topic else {
            if donatedTopicKey != nil {
                donatedTopicKey = nil
                topicActivityDonor.resign()
            }
            return
        }
        guard donatedTopicKey != topic.topicKey else { return }
        donatedTopicKey = topic.topicKey
        let forumName = forum(for: topic.siteURL)?.displayName ?? pageContext.forumName
        topicActivityDonor.donate(topicKey: topic.topicKey, title: topic.title, forumName: forumName, url: topic.url)
    }

    // MARK: Shortcuts

    /// New or renamed forums: Siri learns the names for "Ask … in WukongMind".
    func forumsDidChangeForShortcuts() {
        guard !Self.isRunningTests else { return }
        WukongMindShortcuts.updateAppShortcutParameters()
    }
}
