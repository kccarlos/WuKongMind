import SwiftUI
import XCTest
@testable import Forumind

/// Settings and data that change while work is running: provider switches,
/// key edits, limits, forum removal, clearing data, resets, onboarding
/// replays, watched-topic checks, and shared links.
@MainActor
final class StateTransitionTests: XCTestCase {
    private let site = "https://forum.example.com"
    private let other = "https://other.example.org"

    override func setUp() async throws {
        StateForumStub.reset()
    }

    override func tearDown() async throws {
        StateForumStub.reset()
    }

    // MARK: 1. Provider / model switches

    /// Two summaries run while the user switches to a favorite model: the
    /// running ones keep their provider and stream, the queued one starts
    /// with the new selection, and each records what it ran with.
    func testRunningWorkKeepsItsProviderAndQueuedWorkUsesTheNewOne() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")

        for id in ["1", "2", "3"] { XCTAssertTrue(app.enqueueSummary(for: topic(id))) }
        try await waitUntil { harness.ai.waiting == 2 }
        let running = app.activities.filter { $0.status == .running }
        XCTAssertEqual(running.count, 2)

        app.activateFavorite(FavoriteModel(provider: .lmStudio, model: "model-b"), for: .assistant)
        // The header reads the selection: it changes at once.
        XCTAssertEqual(app.settings.assistantModel.provider, .lmStudio)
        XCTAssertEqual(app.selectedConfiguration.model, "model-b")
        // Running streams are untouched and not mixed.
        for record in running {
            XCTAssertEqual(app.streams.text(for: record.id), "[ollama/model-a]")
            XCTAssertEqual(record.provider, .ollama)
        }

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }

        let calls = harness.ai.calls.filter { $0.kind == "summary" }
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.prefix(2).map(\.label), ["ollama/model-a", "ollama/model-a"])
        XCTAssertEqual(calls.last?.label, "lmstudio/model-b")
        XCTAssertEqual(app.activities.first { $0.topicID == "3" }?.provider, .lmStudio)
        XCTAssertEqual(app.activities.first { $0.topicID == "3" }?.model, "model-b")
        XCTAssertEqual(app.sessions[topic("1").topicKey]?.model, "model-a")
        XCTAssertEqual(app.sessions[topic("3").topicKey]?.provider, .lmStudio)
        XCTAssertTrue(app.streams.isEmpty)
        XCTAssertTrue(app.activities.allSatisfy { $0.status == .completed })
    }

    // MARK: 2. Key and base URL edits

    func testKeyEditsMidRunKeepTheStartingKeyAndLaterWorkFailsClearly() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .openAI, model: "gpt-test", key: "key-1")
        XCTAssertTrue(app.isProviderReady)

        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { harness.ai.waiting == 1 }
        setKey(app, "key-2")
        var configuration = app.selectedConfiguration
        configuration.baseURL = "https://proxy.example.com/v1"
        app.setConfiguration(configuration, for: .openAI)
        setKey(app, "")
        XCTAssertFalse(app.isProviderReady)

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(harness.ai.calls.first?.configuration.apiKey, "key-1")
        XCTAssertEqual(harness.ai.calls.first?.configuration.baseURL, AIProvider.openAI.defaultBaseURL)
        XCTAssertEqual(app.activities.first?.status, .completed)

        // Work started after the key was deleted fails with a clear message.
        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let failed = try XCTUnwrap(app.activities.first { $0.topicID == "2" })
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.error.contains("isn’t connected"), failed.error)
        XCTAssertEqual(harness.ai.calls.count, 1)

        setKey(app, "key-3")
        XCTAssertTrue(app.isProviderReady)
    }

    /// Typing a key writes nothing per keystroke; the last value is written
    /// once edits pause or when the app leaves the foreground.
    func testKeyTypingIsCoalescedAndTheLastValueIsFlushedOnBackground() async throws {
        let harness = makeHarness()
        let app = harness.app
        app.settingsSaveDelay = .seconds(60)
        app.settings.assistantModel = ModelSelection(provider: .openAI, model: (.openAI as AIProvider).defaultModel)
        let savesBefore = harness.store.saveCount
        let writesBefore = harness.keys.writeCount

        var typed = ""
        for character in "sk-live-12345" {
            typed.append(character)
            setKey(app, typed)
            app.saveSettings()
        }
        XCTAssertEqual(harness.keys.writeCount, writesBefore)
        XCTAssertEqual(harness.store.saveCount, savesBefore)

        app.handleScenePhase(.background)
        XCTAssertEqual(harness.keys.writeCount, writesBefore + 1)
        XCTAssertEqual(harness.keys.value(for: .openAI), "sk-live-12345")
        XCTAssertEqual(harness.store.saveCount, savesBefore + 1)
        XCTAssertEqual(harness.store.load().settings.assistantModel.provider, .openAI)
        XCTAssertEqual(harness.store.load().settings.configuration(for: .openAI).apiKey, "", "keys never go in the snapshot")

        // Nothing pending: a second background does not write again.
        app.handleScenePhase(.background)
        XCTAssertEqual(harness.store.saveCount, savesBefore + 1)

        // The trailing save also fires on its own.
        app.settingsSaveDelay = .milliseconds(30)
        setKey(app, "sk-live-67890")
        try await waitUntil { harness.keys.value(for: .openAI) == "sk-live-67890" }

        let reloaded = AppModel(store: harness.store)
        XCTAssertEqual(reloaded.settings.configuration(for: .openAI).apiKey, "sk-live-67890")
    }

    func testSliderDragWritesTheSnapshotOnce() async throws {
        let harness = makeHarness()
        let app = harness.app
        app.settingsSaveDelay = .milliseconds(50)
        let savesBefore = harness.store.saveCount
        for value in stride(from: 20_000, through: 200_000, by: 5_000) {
            app.settings.summaryBatchLimit = value
            app.saveSettings()
        }
        XCTAssertEqual(harness.store.saveCount, savesBefore)
        try await waitUntil { harness.store.saveCount > savesBefore }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(harness.store.saveCount, savesBefore + 1)
        XCTAssertEqual(harness.store.load().settings.summaryBatchLimit, 200_000)
    }

    /// A connection test for the old configuration finishing after the user
    /// changed provider or key must not report on the new one.
    func testStaleConnectionTestResultIsDropped() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .openAI, model: "gpt-test", key: "key-1")

        async let stale = app.testConnection()
        try await waitUntil { harness.ai.waiting == 1 }
        setKey(app, "key-2")
        harness.ai.releaseAll()
        let staleResult = await stale
        XCTAssertEqual(staleResult, .stale)
        XCTAssertNotEqual(app.settingsStatus, "Connection successful")
        XCTAssertNil(app.presentedError)

        // A newer test supersedes an older one for the same configuration.
        async let first = app.testConnection()
        try await waitUntil { harness.ai.waiting == 1 }
        async let second = app.testConnection()
        try await waitUntil { harness.ai.waiting == 2 }
        harness.ai.releaseAll()
        let firstResult = await first
        let secondResult = await second
        XCTAssertEqual(firstResult, .stale)
        XCTAssertEqual(secondResult, .success)
        XCTAssertEqual(app.settingsStatus, "Connection successful")

        // Test & save: a stale result is neither success nor failure.
        harness.ai.failConnection = true
        let task = Task { await app.testAndSaveProvider() }
        try await waitUntil { harness.ai.waiting == 1 }
        app.settings.assistantModel = ModelSelection(provider: .anthropic, model: (.anthropic as AIProvider).defaultModel)
        harness.ai.releaseAll()
        let state = await task.value
        XCTAssertEqual(state, .idle)
    }

    // MARK: 3. Model discovery

    func testModelsDiscoveredForAnOldProviderAreIgnored() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .openAI, model: "gpt-test", key: "key-1")
        app.discoveredModels = [.openAI: ["kept-until-its-address-changes"], .groq: ["groq-old"]]

        // Lists are per provider: switching a role's provider keeps them.
        app.settings.assistantModel = ModelSelection(provider: .groq, model: (.groq as AIProvider).defaultModel)
        XCTAssertEqual(app.discoveredModels[.openAI], ["kept-until-its-address-changes"])

        async let result = app.discoverModels(provider: .openAI)
        try await waitUntil { harness.ai.waiting == 1 }
        var configuration = app.settings.configuration(for: .openAI)
        configuration.baseURL = "https://proxy.example.com/v1"
        app.setConfiguration(configuration, for: .openAI)
        XCTAssertNil(app.discoveredModels[.openAI], "an address change clears that provider's list")
        XCTAssertEqual(app.discoveredModels[.groq], ["groq-old"], "other providers keep theirs")
        harness.ai.releaseAll()
        let outcome = await result
        XCTAssertEqual(outcome, .stale)
        XCTAssertNil(app.discoveredModels[.openAI])

        harness.ai.gated = false
        let fresh = await app.discoverModels(provider: .groq)
        XCTAssertEqual(fresh, .success)
        XCTAssertEqual(app.discoveredModels[.groq], ["groq-model"])
    }

    // MARK: 4. Limits and instructions

    func testLimitsAndInstructionsAreTakenWhenWorkStarts() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.settings.summaryBatchLimit = 30_000
        app.settings.forumContextLimit = 40_000
        app.settings.systemPrompt = "Global A"
        harness.ai.gated = false
        // The fetch of topic 1 waits, so the edits land after the job started.
        StateForumStub.gate(path: "/raw/1")

        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { StateForumStub.isWaiting }
        XCTAssertEqual(app.activities.first?.status, .running)
        app.settings.summaryBatchLimit = 100_000
        app.settings.forumContextLimit = 90_000
        app.settings.systemPrompt = "Global B"
        StateForumStub.release()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }

        XCTAssertEqual(harness.ai.calls.last?.batchLimit, 30_000)
        XCTAssertEqual(harness.ai.calls.last?.customPrompt, "Global A")

        // The next job uses the new values; per-topic instructions win.
        app.select(topic: topic("2"))
        app.setInstructions("Topic two only", topicKey: topic("2").topicKey)
        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(harness.ai.calls.last?.batchLimit, 100_000)
        XCTAssertEqual(harness.ai.calls.last?.customPrompt, "Topic two only")

        // Chat: the context size is also taken at start.
        StateForumStub.gate(path: "/t/2.json")
        app.drafts.chat = "What changed?"
        app.sendChat()
        try await waitUntil { StateForumStub.isWaiting }
        app.settings.forumContextLimit = 10_000
        app.setInstructions("Edited while answering", topicKey: topic("2").topicKey)
        StateForumStub.release()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let chat = try XCTUnwrap(harness.ai.calls.last)
        XCTAssertEqual(chat.kind, "chat")
        XCTAssertEqual(chat.contextLimit, 90_000)
        XCTAssertEqual(chat.customPrompt, "Topic two only")
        XCTAssertEqual(app.sessions[topic("2").topicKey]?.history.last?.content, "Answer by ollama/model-a")
    }

    /// Lowering the step budget below the steps already used ends the run at
    /// its next step with an answer, not a failure.
    func testLoweringTheAgentStepBudgetMidRunEndsItGracefully() async throws {
        let planner = SteppingPlanner()
        let harness = makeHarness(planner: planner)
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.settings.agentMaxSteps = 10

        app.startAgentRun(goal: "Keep looking", siteURL: site)
        for step in 1...3 {
            try await waitUntil { planner.calls == step && planner.isWaiting }
            planner.release()
        }
        try await waitUntil { planner.calls == 4 && planner.isWaiting }
        app.settings.agentMaxSteps = AgentLimits.stepRange.lowerBound
        planner.release()
        try await waitUntil { planner.calls == 5 && planner.isWaiting }
        XCTAssertTrue(planner.lastTranscript.last?.content.contains("budget") ?? false)
        planner.release()

        try await waitUntil { app.agentRuns.first?.isFinished == true }
        let run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(run.result, .completed)
        XCTAssertEqual(run.steps.count, 5)
        XCTAssertEqual(run.steps.last?.outcome, "Stopped at the step budget")
        XCTAssertEqual(run.provider, .ollama)
    }

    // MARK: 5. Forums

    func testRemovingTheOpenForumWithItsDataMidRun() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.recordVisit(siteURL: other, kind: .discourse, name: "Other", iconURL: nil)
        app.recordVisit(siteURL: site, kind: .discourse, name: "Example", iconURL: nil)
        app.pin(try XCTUnwrap(app.forum(for: site)))
        harness.deliver(topicPage(topic("1")))
        app.agentSiteURL = site
        XCTAssertEqual(app.currentForum?.siteURL, site)

        for id in ["1", "2", "3"] { XCTAssertTrue(app.enqueueSummary(for: topic(id))) }
        try await waitUntil { harness.ai.waiting == 2 }

        app.removeForum(try XCTUnwrap(app.forum(for: site)), deleteData: true)
        XCTAssertNil(app.forum(for: site))
        XCTAssertTrue(app.activities.isEmpty)
        XCTAssertTrue(app.sessions.isEmpty)
        XCTAssertNil(app.agentSiteURL)
        XCTAssertEqual(app.agentForum?.siteURL, site, "the agent falls back to the page's forum")
        XCTAssertEqual(app.currentForum?.siteURL, other)
        XCTAssertTrue(app.pinnedForums.isEmpty)

        // The provider answers anyway: nothing comes back.
        harness.ai.gated = false
        harness.ai.releaseAll()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(app.sessions.filter { $0.value.siteURL == site && $0.value.hasSummary }.isEmpty)
        XCTAssertTrue(app.activities.isEmpty)
        XCTAssertTrue(app.streams.isEmpty)
        XCTAssertEqual(harness.ai.calls.count, 2, "the queued job never started")

        // Still browsing the removed forum: it is not added straight back.
        harness.deliver(topicPage(topic("4")))
        XCTAssertNil(app.forum(for: site))
        // After visiting another forum, coming back adds it as a recent forum.
        harness.deliver(topicPage(topic("9", site: other)))
        harness.deliver(topicPage(topic("5")))
        XCTAssertEqual(app.forum(for: site)?.isPinned, false)
        XCTAssertEqual(app.currentForum?.siteURL, site)
    }

    func testRemovingAForumWithoutItsDataLetsItsWorkFinish() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.recordVisit(siteURL: site, kind: .discourse, name: "Example", iconURL: nil)
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { harness.ai.waiting == 1 }

        app.removeForum(try XCTUnwrap(app.forum(for: site)), deleteData: false)
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed)
        XCTAssertTrue(app.sessions[topic("1").topicKey]?.hasSummary ?? false)
        XCTAssertNil(app.forum(for: site))
    }

    /// Owner decision 2: the forum record is gone, so work that has to read the
    /// site ends in an explicit failure (no spinner, nothing half-written).
    /// Work already past its read keeps going (see the test above).
    func testQueuedWorkOfARemovedForumFailsExplicitly() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.recordVisit(siteURL: site, kind: .discourse, name: "Example", iconURL: nil)
        for id in ["1", "2", "3"] { XCTAssertTrue(app.enqueueSummary(for: topic(id))) }
        try await waitUntil { harness.ai.waiting == 2 }
        let queued = try XCTUnwrap(app.activities.first { $0.status == .queued })

        app.removeForum(try XCTUnwrap(app.forum(for: site)), deleteData: false)
        let failed = try XCTUnwrap(app.activities.first { $0.id == queued.id })
        XCTAssertEqual(failed.status, .failed, "it never starts")
        XCTAssertEqual(failed.error, AssistantError.noForum.localizedDescription)
        XCTAssertEqual(app.presentedError, AssistantError.noForum.localizedDescription)

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.filter { $0.status == .completed }.count, 2, "the two summaries past their read finished")
        XCTAssertEqual(app.activities.first { $0.id == queued.id }?.status, .failed)
        XCTAssertEqual(harness.ai.calls.count, 2)
        XCTAssertTrue(app.streams.isEmpty)
    }

    /// The forum is removed (data kept) while a topic is being read: the job
    /// resolved its adapter when it started, so it finishes and keeps its pages
    /// (work still queued fails with noForum, see SiteJobTests).
    func testForumRemovedMidReadLetsTheRunningJobFinish() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        harness.ai.gated = false
        app.recordVisit(siteURL: site, kind: .discourse, name: "Example", iconURL: nil)
        app.select(topic: topic("1"))
        StateForumStub.gate(path: "/raw/1")
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { StateForumStub.isWaiting }
        XCTAssertEqual(app.activities.first?.status, .running)

        app.removeForum(try XCTUnwrap(app.forum(for: site)), deleteData: false)
        StateForumStub.release()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }

        let record = try XCTUnwrap(app.activities.first)
        XCTAssertEqual(record.status, .completed, record.error)
        XCTAssertFalse(app.sessions[topic("1").topicKey]?.rawPages.isEmpty ?? true, "pages already fetched stay")
        XCTAssertEqual(harness.ai.calls.map(\.kind), ["summary"])
        XCTAssertTrue(app.streams.isEmpty)
    }

    /// Tapping Add forum again for the address being detected joins that
    /// detection: one request, one forum.
    func testRapidRepeatedAddForumDetectsOnce() async throws {
        let harness = makeHarness()
        let app = harness.app
        StateForumStub.gate(path: "/site/basic-info.json")
        let first = Task { try await app.addForum(fromAddress: "forum.example.com") }
        try await waitUntil { StateForumStub.isWaiting }
        XCTAssertEqual(app.addForumPhase, .detecting(address: "forum.example.com"))
        let second = Task { try await app.addForum(fromAddress: "forum.example.com") }
        let third = Task { try await app.addForum(fromAddress: "forum.example.com") }
        try await Task.sleep(for: .milliseconds(100))
        StateForumStub.release()

        let forums = try await [first.value, second.value, third.value]
        XCTAssertEqual(Set(forums.map(\.siteURL)), [site])
        XCTAssertEqual(app.forums.count, 1)
        XCTAssertEqual(StateForumStub.count(of: "/site/basic-info.json"), 1)
        XCTAssertEqual(app.addForumPhase, .recognized(kind: .discourse, siteURL: site))
    }

    /// A site that is not a forum ends in `unsupported`; an unreachable one in
    /// `failed`, and a retry once the network is back succeeds.
    func testAddForumPhaseAfterAnUnsupportedSiteAndAnOfflineRetry() async throws {
        let harness = makeHarness(seedsForum: false)
        let app = harness.app
        StateForumStub.offline = true
        do {
            _ = try await app.addForum(fromAddress: "forum.example.com")
            XCTFail("Added while offline")
        } catch {}
        XCTAssertEqual(app.addForumPhase, .failed(.offline))
        XCTAssertTrue(app.forums.isEmpty)

        StateForumStub.offline = false
        let forum = try await app.addForum(fromAddress: "forum.example.com")
        XCTAssertEqual(forum.siteURL, site)
        XCTAssertEqual(app.addForumPhase, .recognized(kind: .discourse, siteURL: site))
    }

    func testPinStateAndOrderStayConsistent() {
        let harness = makeHarness(seedsForum: false)
        let app = harness.app
        let sites = ["https://a.example.com", "https://b.example.com", "https://c.example.com"]
        for siteURL in sites {
            app.recordVisit(siteURL: siteURL, kind: .discourse, name: nil, iconURL: nil)
            app.pin(app.forum(for: siteURL)!)
        }
        XCTAssertEqual(app.currentForum?.siteURL, sites[2])
        XCTAssertEqual(app.currentForum?.isPinned, true)

        app.removeForum(app.forum(for: sites[1])!, deleteData: false)
        XCTAssertEqual(app.pinnedForums.map(\.siteURL), [sites[0], sites[2]])
        XCTAssertEqual(app.pinnedForums.map(\.pinOrder), [0, 1])

        // `currentForum` follows pin changes (it used to keep a stale copy).
        app.unpin(app.forum(for: sites[2])!)
        XCTAssertEqual(app.currentForum?.isPinned, false)
        app.unpin(app.forum(for: sites[0])!)
        XCTAssertTrue(app.pinnedForums.isEmpty)
        XCTAssertEqual(app.recentForums.count, 2)
        app.pin(app.forum(for: sites[0])!)
        XCTAssertEqual(app.pinnedForums.map(\.pinOrder), [0])

        // A rename (the probe or basic-info reports a new name) reaches the
        // current forum too.
        app.recordVisit(siteURL: sites[2], kind: .discourse, name: "Renamed", iconURL: nil)
        XCTAssertEqual(app.currentForum?.name, "Renamed")
    }

    /// The background name/icon refresh must not re-add a forum removed
    /// meanwhile, nor re-pin one unpinned meanwhile.
    func testForumInfoRefreshDoesNotUndoRemoveOrUnpin() async throws {
        let harness = makeHarness()
        let app = harness.app
        StateForumStub.gate(path: "/site/basic-info.json")
        app.pinSuggested(SuggestedForum(kind: .discourse, name: "Example", siteURL: site, description: ""))
        try await waitUntil { StateForumStub.isWaiting }
        app.unpin(try XCTUnwrap(app.forum(for: site)))
        StateForumStub.release()
        try await waitUntil { app.forum(for: site)?.name == "Stub Forum" }
        XCTAssertEqual(app.forum(for: site)?.isPinned, false)

        StateForumStub.gate(path: "/site/basic-info.json")
        app.refreshForumInfo(siteURL: site)
        try await waitUntil { StateForumStub.isWaiting }
        app.removeForum(try XCTUnwrap(app.forum(for: site)), deleteData: false)
        StateForumStub.release()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(app.forum(for: site))
    }

    // MARK: 6. Clear data and reset

    func testClearAllWhileSummaryAndChatRunLeavesNothingBehind() async throws {
        var session = TopicSession(siteURL: site, topicID: "1", url: topic("1").url, title: "Topic 1")
        session.source = "Existing source"
        session.openedByUserAt = Date()  // pulled from its page
        session.summary = "Old summary"
        let run = finishedRun()
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [session], agentRuns: [run]))
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.select(topic: topic("1"))
        app.drafts.chat = "Is it still true?"
        app.sendChat()
        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { harness.ai.waiting == 2 }
        XCTAssertFalse(app.streams.isEmpty)
        app.drafts.chat = "An unsent draft"
        app.drafts.goal = "Unsent goal"
        app.drafts.followUp = "Unsent follow-up for the deleted run"

        app.clearAllSavedData()
        XCTAssertTrue(app.sessions.isEmpty)
        XCTAssertTrue(app.activities.isEmpty)
        XCTAssertTrue(app.agentRuns.isEmpty)
        XCTAssertNil(app.selectedAgentRunID)
        XCTAssertTrue(app.streams.isEmpty)
        XCTAssertTrue(app.streams.isEmpty)
        // Unsent text is kept on purpose, except the draft for a deleted run.
        XCTAssertEqual(app.drafts.chat, "An unsent draft")
        XCTAssertEqual(app.drafts.goal, "Unsent goal")
        XCTAssertEqual(app.drafts.followUp, "")

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(app.sessions.isEmpty, "no resurrected sessions")
        XCTAssertTrue(app.activities.isEmpty)
        XCTAssertTrue(app.streams.isEmpty)
        XCTAssertNil(app.presentedError)
        XCTAssertTrue(harness.store.load().sessions.isEmpty)
        XCTAssertNil(app.currentSession)
    }

    func testClearingOneForumKeepsTheOthersRunning() async throws {
        var snapshot = AppSnapshot()
        snapshot.ensureForum(other)
        let harness = makeHarness(snapshot: snapshot)
        let app = harness.app
        select(app, .ollama, model: "model-a")
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        XCTAssertTrue(app.enqueueSummary(for: topic("7", site: other)))
        try await waitUntil { harness.ai.waiting == 2 }

        app.clearSavedData(forSiteURL: site)
        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.map(\.siteURL), [other])
        XCTAssertEqual(app.activities.first?.status, .completed)
        XCTAssertNil(app.sessions[topic("1").topicKey])
        XCTAssertTrue(app.sessions[topic("7", site: other).topicKey]?.hasSummary ?? false)
    }

    func testResetSettingsMidRun() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .openAI, model: "gpt-test", key: "key-1")
        app.settings.hasCompletedOnboarding = true
        app.flushPendingSaves()
        XCTAssertEqual(harness.keys.value(for: .openAI), "key-1")
        for id in ["1", "2", "3"] { XCTAssertTrue(app.enqueueSummary(for: topic(id))) }
        try await waitUntil { harness.ai.waiting == 2 }
        app.discoveredModels = [.openAI: ["gpt-test"]]

        app.resetSettings()
        XCTAssertEqual(app.settings.assistantModel.provider, AppSettings().assistantModel.provider)
        XCTAssertFalse(app.isProviderReady)
        XCTAssertTrue(app.discoveredModels.isEmpty)
        XCTAssertEqual(harness.keys.value(for: .openAI), "", "reset removes keys at once")
        XCTAssertTrue(app.settings.hasCompletedOnboarding)

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let byTopic = Dictionary(uniqueKeysWithValues: app.activities.map { ($0.topicID, $0) })
        XCTAssertEqual(byTopic["1"]?.status, .completed)
        XCTAssertEqual(byTopic["2"]?.status, .completed)
        XCTAssertEqual(byTopic["3"]?.status, .failed)
        XCTAssertTrue(byTopic["3"]?.error.contains("isn’t connected") ?? false)
        XCTAssertEqual(harness.ai.calls.map(\.configuration.apiKey), ["key-1", "key-1"])
    }

    /// Clearing or editing the chat while it is answered drops the answer
    /// instead of attaching it to a conversation it no longer belongs to.
    func testClearingTheChatWhileItIsAnsweredDropsTheAnswer() async throws {
        var session = TopicSession(siteURL: site, topicID: "1", url: topic("1").url, title: "Topic 1")
        session.source = "Existing source"
        session.openedByUserAt = Date()  // pulled from its page
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [session]))
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.select(topic: topic("1"))
        app.drafts.chat = "First question"
        app.sendChat()
        try await waitUntil { harness.ai.waiting == 1 }
        app.clearChat()
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.currentSession?.history, [])
    }

    func testClearingTheChatWhileTheTopicIsReadSkipsTheProvider() async throws {
        var session = TopicSession(siteURL: site, topicID: "1", url: topic("1").url, title: "Topic 1")
        session.source = "Existing source"
        session.openedByUserAt = Date()  // pulled from its page
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [session]))
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.select(topic: topic("1"))
        StateForumStub.gate(path: "/t/1.json")
        app.drafts.chat = "First question"
        app.sendChat()
        try await waitUntil { StateForumStub.isWaiting }
        app.clearChat()
        StateForumStub.release()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertFalse(harness.ai.calls.contains { $0.kind == "chat" })
        XCTAssertEqual(app.currentSession?.history, [])
        XCTAssertNil(app.presentedError)
    }

    // MARK: 7. Onboarding replay

    func testFinishingAReplayedWalkthroughLeavesWorkAndTheAssistantAlone() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.settings.hasCompletedOnboarding = true
        harness.deliver(topicPage(topic("1")))
        app.assistantMode = .chat
        app.panelRoute = .history
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { harness.ai.waiting == 1 }

        // The provider step edits the selection, then the walkthrough ends.
        app.activateFavorite(FavoriteModel(provider: .lmStudio, model: "model-b"), for: .assistant)
        app.saveSettings()
        app.completeOnboarding()
        XCTAssertTrue(app.settings.hasCompletedOnboarding)
        XCTAssertEqual(app.assistantMode, .chat)
        XCTAssertEqual(app.panelRoute, .history)
        XCTAssertEqual(app.currentTopic?.topicKey, topic("1").topicKey)
        XCTAssertEqual(app.activities.first?.status, .running)

        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed)
        XCTAssertEqual(app.sessions[topic("1").topicKey]?.provider, .ollama)
        XCTAssertEqual(harness.store.load().settings.assistantModel.provider, .lmStudio)
    }

    func testProviderSetupRequestClearsOnceTheProviderIsReady() {
        let harness = makeHarness()
        let app = harness.app
        app.needsProviderSetup = .agent
        select(app, .ollama, model: "model-a")
        XCTAssertNil(app.needsProviderSetup)
    }

    // MARK: 8. Watched topics

    /// Unwatching a topic (and turning auto-refresh off) while a check is
    /// fetching: no crash, the right topic is updated, nothing is queued, and
    /// an overlapping check does not run twice.
    func testWatchCheckWhileTopicsAreUnwatched() async throws {
        var summarized = TopicSession(siteURL: site, topicID: "2", url: topic("2").url, title: "Topic 2")
        summarized.summary = "Summary"
        let watched = ["1", "2", "3"].map {
            WatchedTopic(siteURL: site, topicID: $0, url: topic($0).url, title: "Topic \($0)", knownPostCount: 1)
        }
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [summarized], watchedTopics: watched))
        let app = harness.app
        select(app, .ollama, model: "model-a")
        XCTAssertTrue(app.settings.watchAutoRefreshSummaries)
        StateForumStub.postCounts = ["1": 4, "2": 6, "3": 2]
        StateForumStub.gate(path: "/t/1.json")

        let check = Task { await app.checkWatchedTopics(reason: .manual) }
        try await waitUntil { StateForumStub.isWaiting }
        await app.checkWatchedTopics(reason: .foreground)  // overlapping: returns at once
        app.unwatch(topicKey: topic("1").topicKey)
        app.settings.watchAutoRefreshSummaries = false
        StateForumStub.release()
        await check.value

        XCTAssertEqual(app.watchedTopics.map(\.topicID), ["2", "3"])
        XCTAssertEqual(app.watchedTopics.map(\.newReplies), [5, 1])
        XCTAssertEqual(app.watchedTopics.map(\.knownPostCount), [6, 2])
        XCTAssertFalse(app.activities.contains { $0.type == .summary })
        XCTAssertEqual(StateForumStub.count(of: "/t/2.json"), 1)

        // Unwatching everything mid-check is fine too.
        StateForumStub.postCounts = ["2": 9, "3": 9]
        StateForumStub.gate(path: "/t/2.json")
        let second = Task { await app.checkWatchedTopics(reason: .foreground) }
        try await waitUntil { StateForumStub.isWaiting }
        app.unwatch(topicKey: topic("2").topicKey)
        app.unwatch(topicKey: topic("3").topicKey)
        StateForumStub.release()
        await second.value
        XCTAssertTrue(app.watchedTopics.isEmpty)
    }

    func testWatchRefreshDoesNotQueueSummariesWithoutAProvider() async throws {
        var summarized = TopicSession(siteURL: site, topicID: "2", url: topic("2").url, title: "Topic 2")
        summarized.summary = "Summary"
        let watched = WatchedTopic(siteURL: site, topicID: "2", url: topic("2").url, title: "Topic 2", knownPostCount: 1)
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [summarized], watchedTopics: [watched]))
        let app = harness.app
        select(app, .openAI, model: "gpt-test", key: "")
        StateForumStub.postCounts = ["2": 5]
        await app.checkWatchedTopics(reason: .manual)
        XCTAssertEqual(app.watchedTopics.first?.newReplies, 4)
        XCTAssertFalse(app.activities.contains { $0.type == .summary })
        XCTAssertNil(app.presentedError)

        select(app, .ollama, model: "model-a")
        StateForumStub.postCounts = ["2": 7]
        harness.ai.gated = false
        await app.checkWatchedTopics(reason: .manual)
        XCTAssertTrue(app.activities.contains { $0.type == .summary })
    }

    // MARK: 10. Shared links

    func testSharedLinksLatestWinsAndSettledOtherTopicsClearTheWait() async throws {
        let harness = makeHarness()
        let app = harness.app
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        select(app, .ollama, model: "model-a")
        app.panelRoute = .history

        let first = IncomingLinkRequest(url: topic("11").url, action: .summary)
        let second = IncomingLinkRequest(url: topic("12").url, action: .summary)
        app.handle(first)
        app.handle(second)
        app.handle(second)  // the same request again (URL and inbox)
        XCTAssertEqual(app.panelRoute, .topic)

        // A late report from the first shared page starts nothing and does
        // not cancel the second share (its page has not loaded yet).
        harness.deliver(topicPage(topic("11")))
        XCTAssertTrue(app.activities.isEmpty)
        harness.deliver(topicPage(topic("12")))
        XCTAssertEqual(app.activities.filter { $0.type == .summary }.map(\.topicID), ["12"])

        // Shared again while that summary runs: no duplicate, and the
        // Assistant shows it (not Manage).
        let again = IncomingLinkRequest(url: topic("12").url, action: .summary)
        app.handle(again)
        harness.deliver(topicPage(topic("12")))
        XCTAssertEqual(app.activities.filter { $0.type == .summary }.count, 1)
        XCTAssertEqual(app.panelRoute, .topic)

        // Once the shared page was reached, a settled page of another topic
        // ends the wait, so visiting it later does not start a summary.
        let third = IncomingLinkRequest(url: topic("13").url, action: .summary)
        app.handle(third)
        harness.deliver(PageContext(url: topic("13").url, state: .loading))
        harness.deliver(topicPage(topic("14")))  // the user went elsewhere
        harness.deliver(topicPage(topic("13")))
        XCTAssertFalse(app.activities.contains { $0.topicID == "13" })

        for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
    }

    // MARK: 11. Backgrounding

    func testBackgroundingMidStreamFlushesAndWorkContinues() async throws {
        let harness = makeHarness()
        let app = harness.app
        app.settingsSaveDelay = .seconds(60)
        select(app, .ollama, model: "model-a")
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { harness.ai.waiting == 1 }
        app.settings.systemPrompt = "Typed just before leaving"

        app.handleScenePhase(.inactive)
        XCTAssertEqual(harness.store.load().settings.systemPrompt, "Typed just before leaving")
        app.handleScenePhase(.background)
        XCTAssertEqual(harness.store.load().activities.first?.status, .running)

        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed)
    }

    // MARK: 12. Progress

    /// The fetch and each summary step reported by the provider move
    /// `ProgressStore` on with a status, and completion lands on 100% cleanly
    /// before clearing live progress.
    func testSummaryReportsItsStepsAsProgress() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        var published: [Double] = []
        let progressToken = app.progress.$values.sink { values in
            if let value = values.values.first { published.append(value) }
        }
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { harness.ai.waiting == 1 }
        let running = try XCTUnwrap(app.activities.first)
        XCTAssertEqual(running.status, .running)
        let current = try XCTUnwrap(app.progress.value(for: running.id))
        XCTAssertGreaterThanOrEqual(current, SummaryProgressTracker.fetchShare(pagesToFetch: 1))
        XCTAssertLessThan(current, 1)
        XCTAssertEqual(running.statusText, "Summarizing part 1 of 2…")

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed)
        XCTAssertEqual(published.last, 1, "completion reports 100% cleanly before clearing")
        XCTAssertTrue(app.progress.isEmpty)
        withExtendedLifetime(progressToken) {}
    }

    /// Pulling a topic stays below 100% while downloading pages (even on the
    /// last page before `session.apply` and `save()` finish) and reports 100%
    /// only once the session is saved.
    func testPullStaysBelow100WhileFetchingAndCompletesAt100() async throws {
        StateForumStub.postCounts["1"] = 180
        StateForumStub.gate(path: "/raw/1?page=2")
        let harness = makeHarness()
        let app = harness.app
        let target = topic("1")
        app.select(topic: target)

        var publishedWhileUnsaved: [Double] = []
        var published: [Double] = []
        let progressToken = app.progress.$values.sink { values in
            guard let value = values.values.first else { return }
            published.append(value)
            if app.sessions[target.topicKey]?.totalPosts == nil {
                publishedWhileUnsaved.append(value)
            }
        }

        app.pullTopic()
        try await waitUntil { StateForumStub.isWaiting }
        let running = try XCTUnwrap(app.activities.first)
        XCTAssertEqual(running.status, .running)
        let midPull = try XCTUnwrap(app.progress.value(for: running.id))
        XCTAssertGreaterThan(midPull, 0)
        XCTAssertLessThan(midPull, 1)

        StateForumStub.release()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed)
        XCTAssertFalse(publishedWhileUnsaved.isEmpty)
        XCTAssertTrue(publishedWhileUnsaved.allSatisfy { $0 < 1 }, "pull stays below 100% until session.apply and save finish")
        XCTAssertEqual(published.last, 1, "completion reports 100% cleanly before clearing")
        XCTAssertTrue(app.progress.isEmpty)
        withExtendedLifetime(progressToken) {}
    }

    /// A chat answer has no knowable progress: the bar is indeterminate
    /// (nil) while the model answers.
    func testChatIsIndeterminateWhileAnswering() async throws {
        var session = TopicSession(siteURL: site, topicID: "1", url: topic("1").url, title: "Topic 1")
        session.source = "Existing source"
        session.openedByUserAt = Date()  // pulled from its page
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [session]))
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.select(topic: topic("1"))
        app.drafts.chat = "A question"
        app.sendChat()
        try await waitUntil { harness.ai.waiting == 1 }
        let running = try XCTUnwrap(app.activities.first)
        XCTAssertEqual(running.statusText, "Answering follow-up question…")
        XCTAssertNil(app.progress.value(for: running.id))
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertTrue(app.progress.isEmpty)
    }

    /// The agent's bar is the steps used of its budget.
    func testAgentProgressFollowsItsSteps() async throws {
        let planner = SteppingPlanner()
        let harness = makeHarness(planner: planner)
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.settings.agentMaxSteps = 9

        app.startAgentRun(goal: "Keep looking", siteURL: site)
        var seen: [Double] = []
        for step in 1...3 {
            try await waitUntil { planner.calls == step && planner.isWaiting }
            let agentRecord = try XCTUnwrap(app.activities.first { $0.type == .agent })
            let progress = try XCTUnwrap(app.progress.value(for: agentRecord.id))
            XCTAssertEqual(progress, WorkProgress.agent(completedSteps: step - 1, maxSteps: 9), accuracy: 1e-9)
            seen.append(progress)
            planner.release()
        }
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertGreaterThan(seen.last ?? 0, 0)
        app.cancel(record: try XCTUnwrap(app.activities.first { $0.type == .agent }))
        XCTAssertTrue(app.progress.isEmpty)
        planner.release()
    }

    /// Many progress ticks and text deltas during a stream cause zero
    /// `AppModel.objectWillChange` publishes while `ProgressStore` advances
    /// monotonically and clears when the stream finishes.
    func testStreamingProgressTicksDoNotPublishAppModelAndClearAtEnd() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        _ = await app.notifier.isAuthorized()
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { harness.ai.waiting == 1 }
        // Let any initial throttle slot from the step transition settle.
        try await Task.sleep(for: .milliseconds(130))

        let running = try XCTUnwrap(app.activities.first)
        let recordID = running.id
        let updatedAtBeforeStream = running.updatedAt
        let startFraction = try XCTUnwrap(app.progress.value(for: recordID))
        XCTAssertGreaterThanOrEqual(startFraction, SummaryProgressTracker.fetchShare(pagesToFetch: 1))

        var appPublishes = 0
        let appToken = app.objectWillChange.sink { appPublishes += 1 }
        var progressPublishes = 0
        let progressToken = app.progress.objectWillChange.sink { progressPublishes += 1 }

        // Periodic wait ticks advance ProgressStore without publishing AppModel.
        try await waitUntil { (app.progress.value(for: recordID) ?? 0) > startFraction }
        let afterIdleWait = try XCTUnwrap(app.progress.value(for: recordID))
        XCTAssertGreaterThan(afterIdleWait, startFraction, "bar creeps during idle waits")
        XCTAssertEqual(appPublishes, 0, "periodic ticks must not publish AppModel")

        var observedFractions: [Double] = [startFraction, afterIdleWait]
        for wave in 0..<3 {
            let previousFraction = observedFractions.last ?? startFraction
            let previousPublishes = progressPublishes
            for tick in 1...15 {
                let chars = wave * 1_500 + tick * 100
                harness.ai.emitProgress(.streamed(characters: chars))
                harness.ai.emitDelta("chunk-\(chars) ")
            }
            try await waitUntil {
                (app.progress.value(for: recordID) ?? 0) > previousFraction
                    && progressPublishes > previousPublishes
            }
            observedFractions.append(try XCTUnwrap(app.progress.value(for: recordID)))
        }

        XCTAssertEqual(appPublishes, 0, "streaming progress ticks and deltas must not publish AppModel")
        XCTAssertEqual(app.activities.first?.updatedAt, updatedAtBeforeStream, "streaming ticks must not mutate WorkRecord.updatedAt")
        XCTAssertGreaterThanOrEqual(progressPublishes, 3, "ProgressStore publishes throttled ticks for progress views")
        XCTAssertEqual(observedFractions, observedFractions.sorted(), "progress only moves forward")
        XCTAssertGreaterThan(observedFractions.last ?? 0, startFraction)
        XCTAssertLessThan(observedFractions.last ?? 1, 1)

        // A step boundary with new statusText still updates WorkRecord once,
        // and subsequent streaming ticks within that step stay off AppModel.
        harness.ai.emitProgress(.batchFinished(level: 1, index: 0, count: 2))
        harness.ai.emitProgress(.finalStarted(combining: true))
        XCTAssertEqual(app.activities.first?.statusText, "Combining…")
        XCTAssertGreaterThan(appPublishes, 0)

        try await Task.sleep(for: .milliseconds(130))
        appPublishes = 0
        let combiningStart = try XCTUnwrap(app.progress.value(for: recordID))
        var combiningPrevious = combiningStart
        for wave in 0..<2 {
            for tick in 1...12 {
                harness.ai.emitProgress(.streamed(characters: wave * 1_200 + tick * 100))
            }
            try await waitUntil { (app.progress.value(for: recordID) ?? 0) > combiningPrevious }
            combiningPrevious = try XCTUnwrap(app.progress.value(for: recordID))
        }
        XCTAssertEqual(appPublishes, 0, "streaming ticks in the combining pass must not publish AppModel")
        XCTAssertGreaterThan(try XCTUnwrap(app.progress.value(for: recordID)), combiningStart)

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertNil(app.progress.value(for: recordID))
        XCTAssertTrue(app.progress.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(app.progress.isEmpty, "no late throttled tick resurrects progress after completion")

        withExtendedLifetime((appToken, progressToken)) {}
    }

    /// Across queued, running, finish, failure, cancel, pause, and a
    /// kill-and-restore mid-stream, `WorkRecord` and `ProgressStore` stay in
    /// sync with no stuck state.
    func testRecordAndProgressStatesAcrossFinishFailureCancelPauseAndKillRestore() async throws {
        let grace = FakeBackgroundGrace()
        let harness = makeHarness(backgroundGrace: grace)
        let app = harness.app
        app.restorePendingTasksIfNeeded()
        select(app, .ollama, model: "model-a")

        // 1. Queued vs running, then finish.
        for id in ["1", "2", "3"] { XCTAssertTrue(app.enqueueSummary(for: topic(id))) }
        try await waitUntil { harness.ai.waiting == 2 }
        let queued = try XCTUnwrap(app.activities.first { $0.topicID == "3" })
        XCTAssertEqual(queued.status, .queued)
        XCTAssertEqual(queued.statusText, WorkRecord.waitingStatusText)
        XCTAssertNil(queued.startedAt)
        XCTAssertNil(queued.completedAt)
        XCTAssertNil(app.progress.value(for: queued.id))
        for running in app.activities where running.status == .running {
            XCTAssertNotNil(app.progress.value(for: running.id))
        }

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let finished = try XCTUnwrap(app.activities.first { $0.topicID == "1" })
        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(finished.statusText, "Completed")
        XCTAssertEqual(finished.error, "")
        XCTAssertNotNil(finished.startedAt)
        XCTAssertNotNil(finished.completedAt)
        XCTAssertTrue(app.progress.isEmpty)
        XCTAssertEqual(harness.store.load().activities.first { $0.id == finished.id }?.status, .completed)

        // 2. Failure mid-stream.
        harness.ai.gated = true
        XCTAssertTrue(app.enqueueSummary(for: topic("4"), regenerate: true))
        try await waitUntil { harness.ai.waiting == 1 }
        let failingID = try XCTUnwrap(app.activities.first { $0.topicID == "4" }?.id)
        let beforeStream = try XCTUnwrap(app.progress.value(for: failingID))
        harness.ai.emitProgress(.streamed(characters: 900))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertGreaterThan(try XCTUnwrap(app.progress.value(for: failingID)), beforeStream)
        harness.ai.emitProgress(.streamed(characters: 1_200))
        harness.ai.summaryError = AssistantError.http(502, "Bad gateway")
        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let failed = try XCTUnwrap(app.activities.first { $0.id == failingID })
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.statusText, "Failed")
        XCTAssertFalse(failed.error.isEmpty)
        XCTAssertNotNil(failed.completedAt)
        XCTAssertNil(app.progress.value(for: failingID))
        XCTAssertTrue(app.progress.isEmpty)
        XCTAssertEqual(harness.store.load().activities.first { $0.id == failingID }?.status, .failed)
        harness.ai.summaryError = nil
        app.dismissPresentedError()

        // 3. Cancel mid-stream.
        harness.ai.gated = true
        XCTAssertTrue(app.enqueueSummary(for: topic("5"), regenerate: true))
        try await waitUntil { harness.ai.waiting == 1 }
        let cancelling = try XCTUnwrap(app.activities.first { $0.topicID == "5" })
        harness.ai.emitProgress(.streamed(characters: 1_200))
        XCTAssertNotNil(app.progress.value(for: cancelling.id))
        app.cancel(record: cancelling)
        let cancelled = try XCTUnwrap(app.activities.first { $0.id == cancelling.id })
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.statusText, "Cancelled")
        XCTAssertNotNil(cancelled.completedAt)
        XCTAssertNil(app.progress.value(for: cancelling.id))
        XCTAssertTrue(app.progress.isEmpty)
        XCTAssertEqual(harness.store.load().activities.first { $0.id == cancelling.id }?.status, .cancelled)
        harness.ai.gated = false
        harness.ai.releaseAll()
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(app.activities.first { $0.id == cancelling.id }?.status, .cancelled)
        XCTAssertTrue(app.progress.isEmpty)

        // 4. Kill-and-restore mid-stream, and background pause.
        harness.ai.gated = true
        XCTAssertTrue(app.enqueueSummary(for: topic("6"), regenerate: true))
        try await waitUntil { harness.ai.waiting == 1 }
        let liveID = try XCTUnwrap(app.activities.first { $0.topicID == "6" }?.id)
        harness.ai.emitProgress(.streamed(characters: 1_500))
        XCTAssertNotNil(app.progress.value(for: liveID))

        // Backgrounding saves `.running` to disk; if killed now, relaunch must
        // requeue it with clean indeterminate progress and finish cleanly.
        app.handleScenePhase(.background)
        XCTAssertEqual(harness.store.load().activities.first { $0.id == liveID }?.status, .running)

        let relaunchStore = PersistentStore(
            fileURL: harness.store.directoryURL.appendingPathComponent("state.json"),
            keys: harness.keys
        )
        let relaunchConfiguration = URLSessionConfiguration.ephemeral
        relaunchConfiguration.protocolClasses = [StateForumStub.self]
        let relaunchAI = StateAIStub()
        relaunchAI.gated = false
        let relaunched = AppModel(
            store: relaunchStore,
            forumService: ForumService(
                session: URLSession(configuration: relaunchConfiguration),
                pacer: ForumRequestPacer(clock: InstantPacingClock())
            ),
            aiService: relaunchAI
        )
        relaunched.usesDirectForumRequests = true
        relaunched.allowAllAIProviders()
        relaunched.browser.onPageContextChanged = nil

        let restoredBeforeRun = try XCTUnwrap(relaunched.activities.first { $0.id == liveID })
        XCTAssertEqual(restoredBeforeRun.status, .queued, "killed running work restores as queued, never stuck running")
        XCTAssertEqual(restoredBeforeRun.statusText, "Restoring interrupted work…")
        XCTAssertNil(restoredBeforeRun.completedAt)
        XCTAssertTrue(relaunched.progress.isEmpty, "killed work starts with no stuck progress")

        // Meanwhile on the original instance, expiring background grace pauses
        // the job and clears its live progress.
        grace.expire()
        try await waitUntil { app.activities.first { $0.id == liveID }?.status == .queued }
        XCTAssertEqual(app.activities.first { $0.id == liveID }?.statusText, "Paused until Forumind is open again")
        XCTAssertTrue(app.progress.isEmpty, "paused work clears live progress")
        harness.ai.gated = false
        harness.ai.releaseAll()

        // And the relaunched app runs the restored job to completion cleanly.
        relaunched.restorePendingTasksIfNeeded()
        try await waitUntil { relaunched.activities.allSatisfy(\.status.isTerminal) }
        let restoredAfterRun = try XCTUnwrap(relaunched.activities.first { $0.id == liveID })
        XCTAssertEqual(restoredAfterRun.status, .completed)
        XCTAssertEqual(restoredAfterRun.statusText, "Completed")
        XCTAssertNotNil(restoredAfterRun.completedAt)
        XCTAssertTrue(relaunched.progress.isEmpty)
    }

    // MARK: 12. Model roles

    /// Summaries and chat run on the assistant model; Ask the forum plans and
    /// answers on the agent model, and its `summarize_topic` tool runs on
    /// the assistant model. Each record says what it ran with.
    func testEachJobRunsOnItsRolesModel() async throws {
        let planner = RolePlanner(actions: [
            AgentAction(thought: "", tool: "summarize_topic", arguments: ["topic_id": "2"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done"])
        ])
        let harness = makeHarness(planner: planner)
        let app = harness.app
        harness.ai.gated = false
        setRoles(app, assistant: ModelSelection(provider: .ollama, model: "cheap"),
                 agent: ModelSelection(provider: .lmStudio, model: "reasoner"))

        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(harness.ai.calls.map(\.label), ["ollama/cheap"])
        XCTAssertEqual(app.activities.first?.provider, .ollama)

        app.startAgentRun(goal: "What changed?", siteURL: site)
        try await waitUntil { app.agentRuns.first?.isFinished == true }
        let run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(run.result, .completed, run.error)
        XCTAssertEqual(planner.labels, ["lmstudio/reasoner", "lmstudio/reasoner"])
        XCTAssertEqual(run.provider, .lmStudio)
        XCTAssertEqual(run.model, "reasoner")
        XCTAssertEqual(app.activities.first { $0.type == .agent }?.model, "reasoner")
        // summarize_topic: the cheap model, recorded on the saved summary.
        XCTAssertEqual(harness.ai.calls.last?.label, "ollama/cheap")
        XCTAssertEqual(app.sessions[topic("2").topicKey]?.provider, .ollama)
        XCTAssertEqual(app.sessions[topic("2").topicKey]?.model, "cheap")
    }

    /// Switching the agent model mid-run: the run keeps what it started
    /// with; the follow-up uses the new model; the assistant role is untouched.
    func testChangingTheAgentModelMidRunKeepsTheRunAndTheFollowUpUsesTheNewOne() async throws {
        let planner = RolePlanner(actions: [
            AgentAction(thought: "", tool: "saved_summaries", arguments: [:]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done"])
        ], gated: true)
        let harness = makeHarness(planner: planner)
        let app = harness.app
        setRoles(app, assistant: ModelSelection(provider: .ollama, model: "cheap"),
                 agent: ModelSelection(provider: .lmStudio, model: "reasoner"))

        app.startAgentRun(goal: "Keep looking", siteURL: site)
        try await waitUntil { planner.calls == 1 && planner.isWaiting }
        app.activateFavorite(FavoriteModel(provider: .ollama, model: "reasoner-2"), for: .agent)
        XCTAssertEqual(app.settings.assistantModel, ModelSelection(provider: .ollama, model: "cheap"))
        planner.release()
        try await waitUntil { planner.calls == 2 && planner.isWaiting }
        planner.release()
        try await waitUntil { app.agentRuns.first?.isFinished == true }
        XCTAssertEqual(planner.labels, ["lmstudio/reasoner", "lmstudio/reasoner"])

        let id = try XCTUnwrap(app.agentRuns.first?.id)
        planner.restart()
        app.continueAgentRun(id: id, question: "And then?")
        try await waitUntil { planner.calls == 1 && planner.isWaiting }
        planner.release()
        try await waitUntil { planner.calls == 2 && planner.isWaiting }
        planner.release()
        try await waitUntil { app.agentRuns.first?.isFinished == true }
        XCTAssertEqual(planner.labels, ["ollama/reasoner-2", "ollama/reasoner-2"])
        let run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(run.provider, .lmStudio, "the run keeps the model of its first answer")
        let turns = app.activities.filter { $0.type == .agent }
        XCTAssertEqual(Set(turns.map(\.model)), ["reasoner", "reasoner-2"], "each turn records its model")
        XCTAssertEqual(app.settings.assistantModel.provider, .ollama)
    }

    /// The header switcher changes the current mode's role only: Summary and
    /// Chat share the assistant model, Ask the forum has its own.
    func testHeaderSwitcherOnlyChangesTheCurrentModesRole() {
        let harness = makeHarness()
        let app = harness.app
        let cheap = ModelSelection(provider: .gemini, model: "gemini-3.1-flash-lite")
        let agentic = ModelSelection(provider: .deepSeek, model: "deepseek-v4-flash")
        setRoles(app, assistant: cheap, agent: agentic)
        let favorite = FavoriteModel(provider: .openAI, model: "gpt-5-mini")

        for mode in [AssistantMode.summary, .chat] {
            setRoles(app, assistant: cheap, agent: agentic)
            app.assistantMode = mode
            app.activateFavorite(favorite, for: app.currentRole)
            XCTAssertEqual(app.settings.assistantModel, ModelSelection(provider: .openAI, model: "gpt-5-mini"))
            XCTAssertEqual(app.settings.agentModel, agentic, "\(mode) never changes Ask the forum")
            XCTAssertEqual(app.settings.assistantModel.provider, .openAI)
            XCTAssertEqual(app.providerSummary, "OpenAI · gpt-5-mini")
        }

        setRoles(app, assistant: cheap, agent: agentic)
        app.assistantMode = .agent
        app.activateFavorite(favorite, for: app.currentRole)
        XCTAssertEqual(app.settings.agentModel, ModelSelection(provider: .openAI, model: "gpt-5-mini"))
        XCTAssertEqual(app.settings.assistantModel, cheap)
        XCTAssertEqual(app.settings.assistantModel.provider, .gemini)
        XCTAssertEqual(app.providerSummary, "OpenAI · gpt-5-mini")
    }

    /// Deleting the key of the agent's provider: Ask the forum isn't ready
    /// (and fails clearly), summaries keep working; the agent's
    /// summarize_topic fails as a step (not the run) when the assistant
    /// model isn't ready.
    func testDeletingTheKeyOfOneRolesProviderOnlyAffectsThatRole() async throws {
        let planner = RolePlanner(actions: [
            AgentAction(thought: "", tool: "summarize_topic", arguments: ["topic_id": "2"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Read it instead"])
        ])
        let harness = makeHarness(planner: planner)
        let app = harness.app
        harness.ai.gated = false
        setKey(app, "sk-openai", for: .openAI)
        setKey(app, "sk-deepseek", for: .deepSeek)
        setRoles(app, assistant: ModelSelection(provider: .openAI, model: "gpt-5-mini"),
                 agent: ModelSelection(provider: .deepSeek, model: "deepseek-v4-flash"))
        XCTAssertTrue(app.isProviderReady)

        setKey(app, "", for: .deepSeek)
        XCTAssertTrue(app.isProviderReady(for: .assistant))
        XCTAssertFalse(app.isProviderReady(for: .agent))
        XCTAssertFalse(app.isProviderReady)
        app.startAgentRun(goal: "Anything?", siteURL: site)
        try await waitUntil { app.agentRuns.first?.isFinished == true }
        XCTAssertEqual(app.agentRuns.first?.result, .failed)
        XCTAssertTrue(app.agentRuns.first?.error.contains("DeepSeek") ?? false)
        XCTAssertEqual(planner.calls, 0)
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first { $0.type == .summary }?.status, .completed)

        // Now the other way round: the assistant's key is gone.
        setKey(app, "sk-deepseek", for: .deepSeek)
        setKey(app, "", for: .openAI)
        app.dismissPresentedError()
        app.startAgentRun(goal: "Summarize it", siteURL: site)
        try await waitUntil { app.agentRuns.first?.isFinished == true }
        let run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(run.result, .completed, run.error)
        XCTAssertEqual(run.steps.first?.isError, true)
        XCTAssertTrue(run.steps.first?.outcome.contains("OpenAI") ?? false, run.steps.first?.outcome ?? "")
        XCTAssertEqual(run.answer, "Read it instead")
    }

    func testRemovingAFavoriteInUseKeepsBothRoles() {
        let harness = makeHarness()
        let app = harness.app
        let favorite = FavoriteModel(provider: .deepSeek, model: "deepseek-v4-flash")
        app.settings.favoriteModels = [favorite, FavoriteModel(provider: .gemini, model: "gemini-3.1-flash-lite")]
        app.activateFavorite(favorite, for: .agent)
        app.activateFavorite(favorite, for: .assistant)
        app.removeFavorite(favorite)
        XCTAssertEqual(app.settings.favoriteModels.map(\.model), ["gemini-3.1-flash-lite"])
        XCTAssertEqual(app.settings.agentModel, ModelSelection(provider: .deepSeek, model: "deepseek-v4-flash"))
        XCTAssertEqual(app.settings.assistantModel, ModelSelection(provider: .deepSeek, model: "deepseek-v4-flash"))
        XCTAssertFalse(app.isFavorite(app.settings.agentModel))
    }

    /// Asking the forum needs the agent model; a summary share only the
    /// assistant model.
    func testProviderSetupAsksForTheRoleTheHandOffNeeds() throws {
        let harness = makeHarness()
        let app = harness.app
        app.settings.hasCompletedOnboarding = true
        setRoles(app, assistant: ModelSelection(provider: .ollama, model: "cheap"),
                 agent: ModelSelection(provider: .deepSeek, model: "deepseek-v4-flash"))
        app.recordVisit(siteURL: site, kind: .discourse, name: "Example", iconURL: nil)
        app.askForum(try XCTUnwrap(app.forum(for: site)))
        XCTAssertEqual(app.needsProviderSetup, .agent)
        // Setting up the assistant role doesn't clear an agent request.
        app.selectModel(ModelSelection(provider: .lmStudio, model: "other"), for: .role(.assistant))
        XCTAssertEqual(app.needsProviderSetup, .agent)
        setKey(app, "sk-deepseek", for: .deepSeek)
        XCTAssertNil(app.needsProviderSetup)
    }

    /// The model roles are the only model setting: they round trip, a missing
    /// key takes the default, and a provider's stored configuration holds no
    /// model.
    func testModelRolesRoundTripAndMissingKeysTakeDefaults() throws {
        var roles = AppSettings()
        roles.setModel(ModelSelection(provider: .gemini, model: "gemini-3.1-flash-lite"), for: .assistant)
        roles.setModel(ModelSelection(provider: .deepSeek, model: "deepseek-v4-flash"), for: .agent)
        let data = try JSONEncoder().encode(roles)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["selectedProvider"])
        let configurations = try XCTUnwrap(object["configurations"] as? [String: [String: Any]])
        XCTAssertNil(configurations["gemini"]?["model"])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.assistantModel, roles.assistantModel)
        XCTAssertEqual(decoded.agentModel, roles.agentModel)

        let bare = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(bare, AppSettings())
    }


    // MARK: Streams

    /// Tokens collect and publish at a bounded rate; the final text always
    /// arrives, and a removed stream stays removed.
    @MainActor
    func testStreamStoreCoalescesAndDeliversTheFinalText() async throws {
        let store = StreamStore(interval: .milliseconds(40))
        var publishes = 0
        let token = store.objectWillChange.sink { publishes += 1 }
        let id = UUID()
        store.start(id)
        let afterStart = publishes
        for index in 0..<200 { store.append("t\(index) ", to: id) }
        let expected = (0..<200).map { "t\($0) " }.joined()
        XCTAssertEqual(store.text(for: id), expected, "the latest text is readable before it publishes")
        XCTAssertEqual(publishes, afterStart, "nothing publishes per token")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.texts[id], expected)
        XCTAssertLessThanOrEqual(publishes - afterStart, 2)

        store.append("end", to: id)
        store.flush()
        XCTAssertEqual(store.texts[id], expected + "end")

        store.append("late", to: id)
        store.remove(id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.text(for: id))
        XCTAssertTrue(store.isEmpty)
        withExtendedLifetime(token) {}
    }

    // MARK: Errors

    /// One classifier for every job: no connection, a dropped or slow one,
    /// and errors the network did not cause.
    func testNetworkFailuresAreOfflineTransientOrNotTheNetwork() {
        XCTAssertEqual(NetworkFailure.classify(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(NetworkFailure.classify(URLError(.dataNotAllowed)), .offline)
        XCTAssertEqual(NetworkFailure.classify(URLError(.networkConnectionLost)), .transient)
        XCTAssertEqual(NetworkFailure.classify(URLError(.timedOut)), .transient)
        XCTAssertEqual(NetworkFailure.classify(AssistantError.http(503, "")), .transient)
        XCTAssertNil(NetworkFailure.classify(AssistantError.http(401, "Bad key")))
        XCTAssertNil(NetworkFailure.classify(URLError(.cancelled)))
        XCTAssertNil(NetworkFailure.classify(CancellationError()))
        XCTAssertTrue(NetworkFailure.isUnreachable(URLError(.cannotFindHost)))
    }

    /// A second error waits for the first to be closed instead of replacing
    /// it; the same message is not queued twice.
    func testErrorsQueueInsteadOfOverwritingEachOther() {
        let app = makeHarness().app
        app.presentError("First")
        app.presentError("Second")
        app.presentError("First")
        XCTAssertEqual(app.presentedError, "First")
        XCTAssertEqual(app.rootAlert.map { if case .error(let error) = $0 { error.message } else { "" } }, "First")
        app.dismissRootAlert()
        XCTAssertEqual(app.presentedError, "Second")
        app.dismissRootAlert()
        XCTAssertNil(app.presentedError)
        XCTAssertNil(app.rootAlert)
    }

    /// A summary the app queued by itself (a watched topic's refresh) that
    /// fails shows in Activity without an alert; the user's own one alerts.
    func testAutomaticWorkFailsQuietlyAndUserWorkAlerts() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .openAI, model: "gpt-test", key: "")
        XCTAssertTrue(app.enqueueSummary(for: topic("1"), origin: .automatic))
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .failed)
        XCTAssertEqual(app.activities.first?.origin, .automatic)
        XCTAssertNil(app.presentedError)

        XCTAssertTrue(app.enqueueSummary(for: topic("2")))
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertTrue(app.presentedError?.contains("isn’t connected") ?? false, app.presentedError ?? "")
    }

    // MARK: Cancellation

    /// Cancelling work whose provider ignores the cancel frees its worker
    /// slot at once: queued work starts without waiting for the old calls.
    func testCancelFreesWorkerSlotsEvenWhenTheProviderIgnoresIt() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        for id in ["1", "2", "3"] { XCTAssertTrue(app.enqueueSummary(for: topic(id))) }
        try await waitUntil { harness.ai.waiting == 2 }
        let third = try XCTUnwrap(app.activities.first { $0.topicID == "3" })
        XCTAssertEqual(third.status, .queued)

        // Fast repeated taps: cancelling twice is the same as once.
        for record in app.activities where record.status == .running {
            app.cancel(record: record)
            app.cancel(record: record)
        }
        try await waitUntil { harness.ai.waiting == 3 }
        XCTAssertEqual(app.activities.first { $0.topicID == "3" }?.status, .running)
        XCTAssertEqual(app.activities.filter { $0.status == .cancelled }.count, 2)

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first { $0.topicID == "3" }?.status, .completed)
        XCTAssertEqual(app.sessions[topic("1").topicKey]?.summary ?? "", "", "a cancelled job's late answer is dropped")
    }

    // MARK: Ask box

    /// A run's live status is its work record's; only the outcome is stored.
    func testAgentRunStatusIsDerivedFromItsRecordAndStoresOnlyTheOutcome() async throws {
        let planner = SteppingPlanner()
        let harness = makeHarness(planner: planner)
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.settings.agentMaxSteps = 1
        app.startAgentRun(goal: "Derive", siteURL: site)
        try await waitUntil { planner.isWaiting }
        var run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertNil(run.result, "nothing about a live run is stored")
        XCTAssertEqual(app.status(of: run), .running)
        XCTAssertEqual(app.activeRecord(forAgentRun: run.id)?.status, .running)

        // Cancelled: the outcome is stored, the record is gone.
        app.cancelAgentRun(id: run.id)
        planner.release()
        try await waitUntil { app.agentRuns.first?.isFinished == true }
        run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(run.result, .cancelled)
        XCTAssertEqual(app.status(of: run), .cancelled)
    }

    /// When a running agent task is cancelled and unwinds with a non-`CancellationError`
    /// (such as `URLError(.cancelled)`), both the work record and the stored `AgentRun`
    /// outcome are marked `.cancelled`.
    func testAgentRunTaskCancelledWithNonCancellationErrorMarksRunCancelled() async throws {
        struct TaskCancellingPlanner: AgentPlanner {
            func nextAction(
                system: String,
                transcript: [ChatMessage],
                configuration: ProviderConfiguration,
                provider: AIProvider
            ) async throws -> AgentAction {
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.cancelled)
            }
        }
        let harness = makeHarness(planner: TaskCancellingPlanner())
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.startAgentRun(goal: "Cancel via URLSession", siteURL: site)
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }

        let record = try XCTUnwrap(app.activities.first)
        let run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(run.result, .cancelled)
        XCTAssertNotNil(run.completedAt)
        XCTAssertEqual(app.status(of: run), .cancelled)
    }

    /// App killed mid-run: the run with a record resumes as queued; one whose
    /// record is gone is closed out instead of spinning.
    func testRelaunchResumesARunWithItsRecordAndClosesOneWithout() throws {
        let resumable = AgentRun(siteURL: site, goal: "Resume me", provider: .ollama, model: "model-a")
        let orphan = AgentRun(siteURL: site, goal: "Orphan", provider: .ollama, model: "model-a")
        var record = WorkRecord(
            type: .agent, siteURL: site, topicID: AppModel.agentTopicPrefix + resumable.id.uuidString,
            title: "Resume me", url: URL(string: site)!, provider: .ollama, model: "model-a"
        )
        record.status = .running
        let harness = makeHarness(snapshot: AppSnapshot(activities: [record], agentRuns: [resumable, orphan]))
        let app = harness.app
        let resumed = try XCTUnwrap(app.agentRuns.first { $0.id == resumable.id })
        XCTAssertNil(resumed.result)
        XCTAssertEqual(app.status(of: resumed), .queued, "the interrupted record is requeued")
        let closed = try XCTUnwrap(app.agentRuns.first { $0.id == orphan.id })
        XCTAssertEqual(closed.result, .cancelled)
        XCTAssertEqual(app.status(of: closed), .cancelled)
        XCTAssertFalse(closed.error.isEmpty)
    }

    /// Text typed in the Ask box stays in front when the run it waits for
    /// finishes, or another run is selected: the box never swaps it for the
    /// other, empty draft.
    func testTypedAskTextSurvivesTheRunFinishingAndAnotherRunBeingSelected() async throws {
        let planner = SteppingPlanner()
        let harness = makeHarness(planner: planner)
        let app = harness.app
        select(app, .ollama, model: "model-a")
        app.settings.agentMaxSteps = 1
        app.chooseAskForum(siteURL: site)
        app.startAgentRun(goal: "First", siteURL: site)
        try await waitUntil { planner.isWaiting }
        XCTAssertTrue(app.askWaitsForRun)
        app.askDraft = "Typed while it runs"
        XCTAssertFalse(app.canSendAsk, "waits for the run")

        planner.release()
        try await waitUntil { planner.calls == 2 && planner.isWaiting }
        planner.release()
        try await waitUntil { app.agentRuns.first?.isFinished == true }
        XCTAssertEqual(app.askDraft, "Typed while it runs")
        XCTAssertEqual(app.askDraftTarget, .goal)
        XCTAssertTrue(app.canSendAsk)

        // A follow-up typed for the finished run stays when a running one
        // is selected, and waits for it.
        app.askDraft = ""
        XCTAssertEqual(app.askDraftTarget, .followUp)
        app.askDraft = "A follow-up"
        let second = try app.startAgentRun(goal: "Second", siteURL: site) { _ in }
        app.selectedAgentRunID = second
        XCTAssertEqual(app.askDraft, "A follow-up")
        XCTAssertEqual(app.askDraftTarget, .followUp)
        XCTAssertFalse(app.canSendAsk)
        // Fast repeated taps on Send do nothing while it can't send.
        app.sendAsk()
        app.sendAsk()
        XCTAssertEqual(app.askDraft, "A follow-up")
        XCTAssertEqual(app.agentRuns.count, 2)
    }

    // MARK: Background

    /// Leaving the foreground mid-read: the job goes on in the grace period;
    /// when it ends the job pauses (pages read so far kept, nothing failed,
    /// no alert), survives a kill as queued work, and starts again in the
    /// foreground without reading those pages again.
    func testWorkPausesWhenTheGracePeriodEndsAndResumesInTheForeground() async throws {
        let grace = FakeBackgroundGrace()
        let harness = makeHarness(backgroundGrace: grace)
        let app = harness.app
        app.restorePendingTasksIfNeeded()
        select(app, .ollama, model: "model-a")
        StateForumStub.postCounts["1"] = 250
        StateForumStub.gate(path: "/raw/1?page=2")
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { StateForumStub.isWaiting }

        app.handleScenePhase(.background)
        XCTAssertEqual(grace.begun, 1)
        XCTAssertEqual(app.activities.first?.status, .running, "it goes on for now")
        grace.expire()
        try await waitUntil { app.activities.first?.status == .queued }
        XCTAssertEqual(app.activities.first?.statusText, "Paused until Forumind is open again")
        XCTAssertEqual(app.sessions[topic("1").topicKey]?.rawPages.map(\.page), [1])
        XCTAssertEqual(app.sessions[topic("1").topicKey]?.rawPages.first?.blocks.map(\.number), [1, 2], "blocks come with the page")
        XCTAssertNil(app.presentedError)
        XCTAssertEqual(grace.ended, 1)

        // Killed now: the next launch finds it queued, to restore.
        let relaunched = AppModel(store: PersistentStore(fileURL: harness.store.directoryURL.appendingPathComponent("state.json"), keys: harness.keys))
        relaunched.browser.onPageContextChanged = nil
        XCTAssertEqual(relaunched.activities.first?.status, .queued)
        XCTAssertEqual(relaunched.sessions[topic("1").topicKey]?.rawPages.map(\.page), [1])
        XCTAssertEqual(relaunched.sessions[topic("1").topicKey]?.rawPages.first?.blocks.map(\.author), ["alice", "bob"], "blocks survive a kill")

        StateForumStub.release()
        app.handleScenePhase(.active)
        try await waitUntil { harness.ai.waiting == 1 }
        XCTAssertEqual(StateForumStub.requestsWithQuery.filter { $0 == "/raw/1?page=1" }.count, 1, "page 1 was kept")
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed)
    }

    /// Paused while its provider call ignores the cancel, then resumed: the
    /// old call finishing late must not cancel (or write over) the resumed
    /// job.
    func testAPausedJobsLateOldCallDoesNotCancelTheResumedOne() async throws {
        let grace = FakeBackgroundGrace()
        let harness = makeHarness(backgroundGrace: grace)
        let app = harness.app
        app.restorePendingTasksIfNeeded()
        select(app, .ollama, model: "model-a")
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { harness.ai.waiting == 1 }

        app.handleScenePhase(.background)
        grace.expire()
        try await waitUntil { app.activities.first?.status == .queued }
        app.handleScenePhase(.active)
        try await waitUntil { harness.ai.waiting == 2 }
        XCTAssertEqual(app.activities.first?.status, .running)

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed)
        XCTAssertEqual(app.sessions[topic("1").topicKey]?.summary, "Summary by ollama/model-a")
    }

    /// A request that fails because the app is in the background (the
    /// connection was cut) pauses the job instead of failing it.
    func testANetworkFailureInTheBackgroundPausesInsteadOfFailing() async throws {
        let grace = FakeBackgroundGrace()
        let harness = makeHarness(backgroundGrace: grace)
        let app = harness.app
        select(app, .ollama, model: "model-a")
        StateForumStub.postCounts["1"] = 250
        StateForumStub.gate(path: "/raw/1?page=2")
        XCTAssertTrue(app.enqueueSummary(for: topic("1")))
        try await waitUntil { StateForumStub.isWaiting }
        app.handleScenePhase(.background)
        StateForumStub.offline = true
        StateForumStub.release()
        try await waitUntil { app.activities.first?.status == .queued }
        XCTAssertNil(app.presentedError)
        XCTAssertEqual(app.sessions[topic("1").topicKey]?.rawPages.map(\.page), [1, 2])
        XCTAssertEqual(grace.ended, 1, "nothing left to run")
    }

    // MARK: Helpers

    private struct Harness {
        let app: AppModel
        let store: PersistentStore
        let keys: InMemoryProviderKeyStore
        let ai: StateAIStub
        /// Hands a page context to the model as the browser would. The real
        /// web view's own reports are disconnected so they cannot interfere.
        let deliver: (PageContext) -> Void
    }

    private func makeHarness(
        snapshot: AppSnapshot? = nil,
        planner: AgentPlanner? = nil,
        backgroundGrace: BackgroundGracing? = nil,
        seedsForum: Bool = true
    ) -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let keys = InMemoryProviderKeyStore()
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: keys)
        var seeded = snapshot ?? AppSnapshot()
        if seedsForum { seeded.ensureForum(site) }
        try? store.save(seeded)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StateForumStub.self]
        let session = URLSession(configuration: configuration)
        let ai = StateAIStub()
        let app = AppModel(
            store: store,
            forumService: ForumService(session: session, pacer: ForumRequestPacer(clock: InstantPacingClock())),
            aiService: ai,
            planner: planner,
            backgroundGrace: backgroundGrace
        )
        app.usesDirectForumRequests = true
        app.browser.stopLoading()
        // Consent has its own tests (AIDataConsentTests).
        app.allowAllAIProviders()
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil
        addTeardownBlock { @MainActor in
            for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
            app.browser.stopLoading()
            app.pauseDigest()
            app.podcast.pauseGeneration()
            ai.gated = false
            ai.releaseAll()
            session.invalidateAndCancel()
            StateForumStub.release()
            StateForumStub.reset()
        }
        return Harness(app: app, store: store, keys: keys, ai: ai, deliver: { app.browser.setPageContext($0); handler?($0) })
    }

    /// Both roles on `provider` · `model`, with `key`.
    private func select(_ app: AppModel, _ provider: AIProvider, model: String, key: String = "") {
        var configuration = app.settings.configuration(for: provider)
        configuration.apiKey = key
        app.setConfiguration(configuration, for: provider)
        app.selectModel(ModelSelection(provider: provider, model: model), for: .both)
    }

    private func setRoles(_ app: AppModel, assistant: ModelSelection, agent: ModelSelection) {
        app.selectModel(assistant, for: .role(.assistant))
        app.selectModel(agent, for: .role(.agent))
    }

    private func setKey(_ app: AppModel, _ key: String, for provider: AIProvider) {
        var configuration = app.settings.configuration(for: provider)
        configuration.apiKey = key
        app.setConfiguration(configuration, for: provider)
    }

    private func setKey(_ app: AppModel, _ key: String) {
        var configuration = app.selectedConfiguration
        configuration.apiKey = key
        app.setConfiguration(configuration, for: app.settings.assistantModel.provider)
    }

    private func topic(_ id: String, site: String? = nil) -> ForumTopic {
        let siteURL = site ?? self.site
        return ForumTopic(
            siteURL: siteURL,
            topicID: id,
            url: URL(string: "\(siteURL)/t/topic-\(id)/\(id)")!,
            title: "Topic \(id)"
        )
    }

    private func topicPage(_ topic: ForumTopic) -> PageContext {
        PageContext(
            url: topic.url,
            site: .discourse,
            siteURL: topic.siteURL,
            forumName: ForumSite.host(of: topic.siteURL),
            topic: topic,
            state: .topic
        )
    }

    private func finishedRun() -> AgentRun {
        var run = AgentRun(siteURL: site, goal: "Old question", provider: .ollama, model: "model-a")
        run.result = .completed
        run.answer = "Old answer"
        return run
    }

    private func waitUntil(
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Flow Fixes

    func testAskBoxSendsOnUnpulledTopicAndChatDeepLinkByFetchingPagesOnDemand() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        harness.ai.gated = false

        // 1. Opening a topic without summarizing or pulling first still lets AskBox send,
        // fetching the topic's pages on demand.
        harness.deliver(topicPage(topic("42")))
        XCTAssertEqual(app.currentTopic?.topicID, "42")
        XCTAssertEqual(app.currentSession?.source, "")
        XCTAssertEqual(app.askScope, .topic)

        app.drafts.chat = AskBox.suggestions[0].1
        XCTAssertTrue(app.canSendAsk)
        app.sendAsk()
        try await waitUntil { !app.activities.isEmpty && app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed)
        XCTAssertFalse(app.currentSession?.source.isEmpty ?? true)
        XCTAssertEqual(app.currentSession?.history.map(\.role), [.user, .assistant])

        // 2. Deep link `wukongmind://open?url=...&action=chat` opens in .chat mode with empty
        // source and also allows sending immediately.
        let deepLink = URL(string: "wukongmind://open?url=https%3A%2F%2Fforum.example.com%2Ft%2Ftopic-99%2F99&action=chat")!
        app.handleDeepLink(deepLink)
        harness.deliver(topicPage(topic("99")))
        XCTAssertEqual(app.assistantMode, .chat)
        XCTAssertEqual(app.currentSession?.source, "")
        app.drafts.chat = "What is the consensus?"
        XCTAssertTrue(app.canSendAsk)
        app.sendAsk()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.currentSession?.history.map(\.role), [.user, .assistant])
    }

    func testHistoryOpenDismissesModalExitsHomeResetsModeAndSyncsForumScope() async throws {
        var runA = AgentRun(siteURL: site, goal: "Question on Forum A", provider: .ollama, model: "model-a")
        runA.result = .completed
        runA.answer = "Answer on Forum A"
        let watched = WatchedTopic(
            siteURL: site,
            topicID: "11",
            url: topic("11").url,
            title: "Topic 11",
            knownPostCount: 2
        )
        var seeded = AppSnapshot()
        seeded.ensureForum(other)
        seeded.agentRuns = [runA]
        seeded.watchedTopics = [watched]
        let harness = makeHarness(snapshot: seeded)
        let app = harness.app
        select(app, .ollama, model: "model-a")
        harness.ai.gated = false

        harness.deliver(topicPage(topic("11")))
        app.startSummary()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let savedSession = try XCTUnwrap(app.sessions[topic("11").topicKey])
        let savedRecord = try XCTUnwrap(app.activities.first)

        // 1. From Forums Home, modal History sheet (.expanded(.history)) dismisses on Open,
        // exits Forums Home, and opens the AI view on Ask runs.
        app.showForumsHome()
        XCTAssertTrue(app.browser.showsForumsHome)
        app.openPanelRoute(.history)
        XCTAssertEqual(app.router.item, .expanded(.history))

        app.openAgentRun(id: runA.id)
        XCTAssertNil(app.router.item)
        XCTAssertFalse(app.browser.showsForumsHome)
        XCTAssertTrue(app.router.wantsDrawer)
        XCTAssertEqual(app.assistantMode, .agent)

        // Modal History sheet also dismisses on Open for saved sessions, records, and watched topics.
        app.openPanelRoute(.history)
        XCTAssertEqual(app.router.item, .expanded(.history))
        app.open(session: savedSession)
        XCTAssertNil(app.router.item)

        app.openPanelRoute(.history)
        XCTAssertEqual(app.router.item, .expanded(.history))
        app.open(record: savedRecord)
        XCTAssertNil(app.router.item)

        app.openPanelRoute(.history)
        XCTAssertEqual(app.router.item, .expanded(.history))
        app.openWatched(watched)
        XCTAssertNil(app.router.item)

        // 2. Opening a saved Summary/Chat from in-panel/in-drawer History while in .agent mode
        // resets assistantMode to .summary and steps a .large drawer down to .medium.
        app.router.presentDrawer()
        app.router.drawerAppeared()
        app.router.drawerDetent = .large
        app.assistantMode = .agent
        app.panelRoute = .history
        app.open(session: savedSession)
        XCTAssertEqual(app.panelRoute, .topic)
        XCTAssertEqual(app.assistantMode, .summary)
        XCTAssertEqual(app.router.drawerDetent, .medium)

        // 3. While browsing Forum B (`other`), opening `runA` from Forum A synchronizes `agentForum`
        // with `selectedAgentRun` and `askFollowUpRun`.
        harness.deliver(topicPage(topic("22", site: other)))
        app.agentSiteURL = nil
        app.openAgentRun(id: runA.id)
        XCTAssertEqual(app.selectedAgentRun?.siteURL, site)
        XCTAssertEqual(app.agentForum?.siteURL, site)
        XCTAssertEqual(app.askFollowUpRun?.siteURL, site)
    }

    func testEditAndClearChatCancelActiveStreamFocusComposerAndAllowResend() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")

        harness.deliver(topicPage(topic("30")))
        harness.ai.gated = false
        app.pullTopic()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }

        // 1. Editing a chat question while the assistant is streaming does NOT delete
        // history or kill the stream yet; cancelling restores the composer and lets the
        // running answer finish cleanly.
        harness.ai.gated = true
        app.drafts.chat = "First draft question"
        let focusBefore = app.askFocusRequest
        app.sendAsk()
        try await waitUntil { harness.ai.waiting == 1 }

        let activeRecord = try XCTUnwrap(app.activities.first { $0.type == .chat && !$0.status.isTerminal })
        let firstMsg = try XCTUnwrap(app.currentSession?.history.first { $0.role == .user })
        XCTAssertFalse((app.streams.text(for: activeRecord.id) ?? "").isEmpty)

        app.drafts.chat = "Unsent follow-up note"
        app.editChat(messageID: firstMsg.id)

        XCTAssertEqual(app.currentSession?.history.map(\.content), ["First draft question"])
        XCTAssertEqual(app.drafts.chat, "First draft question")
        XCTAssertEqual(app.activeChatEdit?.messageID, firstMsg.id)
        XCTAssertEqual(app.askFocusRequest, focusBefore + 1)
        XCTAssertTrue(app.hasActiveWork(topicKey: topic("30").topicKey, type: .chat))
        XCTAssertFalse((app.streams.text(for: activeRecord.id) ?? "").isEmpty)

        // Cancel restores the previous composer draft without deleting history or stopping the answer.
        app.cancelEditChat()
        XCTAssertNil(app.activeChatEdit)
        XCTAssertEqual(app.drafts.chat, "Unsent follow-up note")
        XCTAssertEqual(app.currentSession?.history.map(\.content), ["First draft question"])
        XCTAssertTrue(app.hasActiveWork(topicKey: topic("30").topicKey, type: .chat))

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.currentSession?.history.count, 2, "The first answer finished after cancelling edit.")

        // Ask a second question so history is [Q1, A1, Q2] with Q2 actively streaming.
        harness.ai.gated = true
        app.drafts.chat = "Second question"
        app.sendAsk()
        try await waitUntil { harness.ai.waiting == 1 }
        let streamingSecond = try XCTUnwrap(app.activities.first { $0.type == .chat && !$0.status.isTerminal })
        XCTAssertEqual(app.currentSession?.history.count, 3)

        // 2. Edit Q1 while Q2's answer is running: history stays [Q1, A1, Q2] until submit;
        // submitting removes Q1 and everything that followed it, cancels Q2's stream safely,
        // and starts the edited question.
        app.editChat(messageID: firstMsg.id)
        XCTAssertEqual(app.currentSession?.history.count, 3, "Edit must not remove turns before submit.")
        app.drafts.chat = "Edited first question"
        XCTAssertTrue(app.canSendAsk, "Submitting an edit is allowed even while an answer is running.")

        app.sendAsk()
        XCTAssertNil(app.activeChatEdit)
        XCTAssertEqual(app.currentSession?.history.map(\.content), ["Edited first question"])
        XCTAssertNil(app.streams.text(for: streamingSecond.id))
        XCTAssertEqual(app.activities.first(where: { $0.id == streamingSecond.id })?.status, .cancelled)

        // Releasing the cancelled stream must not append a stale answer; the new chat job runs.
        try await waitUntil { harness.ai.calls.count == 3 }
        harness.ai.releaseFirst()
        try await waitUntil { harness.ai.waiting == 1 }
        try await Task.sleep(for: .milliseconds(30))
        let replacementRecord = try XCTUnwrap(app.activities.first { $0.type == .chat && !$0.status.isTerminal })
        XCTAssertNotEqual(replacementRecord.id, streamingSecond.id)
        XCTAssertEqual(app.currentSession?.history.map(\.content), ["Edited first question"])

        // 3. clearChat() cancels both any pending edit and active chat stream.
        let editedMsg = try XCTUnwrap(app.currentSession?.history.first)
        app.editChat(messageID: editedMsg.id)
        XCTAssertNotNil(app.activeChatEdit)
        app.clearChat()
        XCTAssertNil(app.activeChatEdit)
        XCTAssertTrue(app.currentSession?.history.isEmpty == true)
        XCTAssertFalse(app.hasActiveWork(topicKey: topic("30").topicKey, type: .chat))
        XCTAssertNil(app.streams.text(for: replacementRecord.id))

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
    }

    func testForumHomeRecentRunResetsAcrossForumHomesAndAllowsOverviewReturn() async throws {
        let run = finishedRun()
        var seeded = AppSnapshot()
        seeded.agentRuns = [run]
        let harness = makeHarness(snapshot: seeded)
        let app = harness.app
        select(app, .ollama, model: "model-a")

        let home1 = PageContext(
            url: URL(string: site)!,
            site: .discourse,
            siteURL: site,
            forumName: "Stub Forum",
            topic: nil,
            state: .forumHome
        )
        harness.deliver(home1)
        XCTAssertEqual(app.assistantPageState, .forumHome)
        XCTAssertEqual(app.assistantMode, .summary)
        XCTAssertNil(app.currentTopic)

        // User taps a recent run in ForumHomeState, then can return directly to Forum overview.
        app.openAgentRun(id: run.id)
        XCTAssertEqual(app.assistantMode, .agent)
        XCTAssertNil(app.currentTopic)
        app.showForumOverview()
        XCTAssertEqual(app.assistantMode, .summary)
        XCTAssertNil(app.agentSiteURL)

        // Re-opening the recent run and navigating to another forum's home page also resets out of .agent.
        app.openAgentRun(id: run.id)
        XCTAssertEqual(app.assistantMode, .agent)

        // Navigating to another forum's home page resets out of .agent so Forum B's ForumHomeState shows.
        let home2 = PageContext(
            url: URL(string: other)!,
            site: .discourse,
            siteURL: other,
            forumName: "Other Forum",
            topic: nil,
            state: .forumHome
        )
        harness.deliver(home2)
        XCTAssertEqual(app.assistantPageState, .forumHome)
        XCTAssertEqual(app.assistantMode, .summary)
        XCTAssertNil(app.agentSiteURL)
    }

    func testBatchLimitPresetRegeneratesSummaryAndRapidStartSummaryIsIdempotent() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        harness.ai.gated = false

        // 1. Summarize topic 12, then run with an explicit per-run batchLimit on the already-summarized topic.
        harness.deliver(topicPage(topic("12")))
        app.startSummary()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(harness.ai.calls.filter { $0.kind == "summary" }.count, 1)

        app.startSummary(batchLimit: SummaryBatchLimit.presets[0])
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let summaryCalls = harness.ai.calls.filter { $0.kind == "summary" }
        XCTAssertEqual(summaryCalls.count, 2)
        XCTAssertEqual(summaryCalls.last?.batchLimit, SummaryBatchLimit.presets[0])

        // 2. Rapid repeated startSummary calls are idempotent and keep panelRoute on .topic.
        harness.ai.gated = true
        XCTAssertEqual(app.panelRoute, .topic)
        app.startSummary(regenerate: true)
        app.startSummary(regenerate: true)
        XCTAssertEqual(app.panelRoute, .topic)
        XCTAssertEqual(app.activities.filter { !$0.status.isTerminal }.count, 1)

        harness.ai.gated = false
        harness.ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
    }

    func testAnswerReadyDoesNotFireForAlreadyViewedAgentRun() async throws {
        let planner = RolePlanner(actions: [
            AgentAction(thought: "Done 1", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Read while open"]),
            AgentAction(thought: "Done 2", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Read before closing"])
        ])
        let harness = makeHarness(planner: planner)
        let app = harness.app
        select(app, .ollama, model: "model-a")
        harness.deliver(topicPage(topic("18")))
        app.router.presentDrawer()
        app.router.drawerAppeared()
        XCTAssertTrue(app.isAIViewShown)

        // 1. User switches to Whole forum, watches the run finish in AgentPanel, then switches back to This topic.
        app.setAskScope(.forum)
        try await Task.sleep(for: .milliseconds(20))
        app.startAgentRun(goal: "What is new?", siteURL: site)
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.assistantMode, .agent)
        XCTAssertNil(app.readyAnswer)

        app.setAskScope(.topic)
        XCTAssertNil(app.readyAnswer)

        // 2. User starts another Whole forum run, watches it finish while drawer is open, then closes the drawer.
        app.setAskScope(.forum)
        try await Task.sleep(for: .milliseconds(20))
        app.startAgentRun(goal: "Second question", siteURL: site)
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        app.router.closeDrawer()
        app.router.drawerDismissed()
        app.aiViewVisibilityChanged()
        XCTAssertNil(app.readyAnswer)
    }

    func testSavedDataCountsOnlySavedItemsExcludesEmptyForumsAndEnablesClearAllWithDigests() async throws {
        let harness = makeHarness()
        let app = harness.app
        select(app, .ollama, model: "model-a")
        harness.ai.gated = false

        // 1. Merely opening a topic in the browser must not count as a saved item or saved-data forum.
        harness.deliver(topicPage(topic("50")))
        XCTAssertEqual(app.savedItemCount(forSiteURL: site), 0)
        XCTAssertFalse(app.siteURLsWithSavedData.contains(site))

        // 2. Summarizing makes it 1 saved item; deleting the session in History removes the forum from saved-data rows
        // even though terminal WorkRecords remain in `activities` (no "0 saved items" row).
        app.startSummary()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.savedItemCount(forSiteURL: site), 1)
        XCTAssertEqual(app.siteURLsWithSavedData, [site])

        app.deleteSession(topicKey: topic("50").topicKey)
        XCTAssertEqual(app.savedItemCount(forSiteURL: site), 0)
        XCTAssertFalse(app.siteURLsWithSavedData.contains(site))

        // 3. Having a Daily Digest keeps saved data clearable via Clear All Saved Data even when no per-forum rows remain.
        app.clearAllSavedData()
        XCTAssertFalse(app.hasAnySavedData)
        var card = DigestCard(
            siteURL: site,
            topicID: "77",
            title: "Trending 77",
            slug: "trending-77",
            reason: .trending,
            postCount: 10
        )
        card.summary = "Digest summary"
        card.state = .done
        var digest = DailyDigest(day: DailyDigest.dayKey(for: Date()), cards: [card])
        digest.completedAt = Date()
        app.digests = [digest]
        XCTAssertTrue(app.siteURLsWithSavedData.isEmpty)
        XCTAssertTrue(app.hasAnySavedData)

        app.clearAllSavedData()
        XCTAssertNil(app.todaysDigest)
        XCTAssertFalse(app.hasAnySavedData)
    }

    func testProviderConnectionValidatesRoleModelAndPreservesActiveTestingStateOnRace() async throws {
        let harness = makeHarness()
        let app = harness.app

        // 1. Role-scoped Test & save must test the role's chosen model (e.g., Vertex AI custom model), not defaultModel.
        harness.ai.gated = false
        var vertexConfig = app.settings.configuration(for: .vertexAI)
        vertexConfig.apiKey = "vertex-key-1"
        app.setConfiguration(vertexConfig, for: .vertexAI)
        app.settings.assistantModel = ModelSelection(provider: .vertexAI, model: "gemini-2.5-pro")
        let vertexState = await app.testAndSaveProvider(scope: .role(.assistant))
        XCTAssertEqual(vertexState, .success)
        XCTAssertEqual(harness.ai.calls.last?.configuration.model, "gemini-2.5-pro")

        // 2. AIService.testConnection rejects an unavailable model ID when /models succeeds, while provider-only checks pass.
        let protocolConfig = URLSessionConfiguration.ephemeral
        protocolConfig.protocolClasses = [ProviderModelsStubProtocol.self]
        let service = AIService(session: URLSession(configuration: protocolConfig))
        var roleConfig = ProviderConfiguration(model: "nonexistent-model-xyz", baseURL: "https://api.openai.com/v1", apiKey: "sk-test")
        do {
            try await service.testConnection(configuration: roleConfig, provider: .openAI)
            XCTFail("Testing connection with an unavailable model ID must fail")
        } catch AssistantError.missingConfiguration(let message) {
            XCTAssertTrue(message.contains("nonexistent-model-xyz"))
        }
        roleConfig.model = ""
        try await service.testConnection(configuration: roleConfig, provider: .openAI)

        // 3. When a stale Test & save finishes after a newer Test & save has already started, it keeps `.testing` instead of clearing to `.idle`.
        harness.ai.gated = true
        select(app, .openAI, model: "gpt-4o-mini", key: "key-old")
        let firstTask = Task { await app.testAndSaveProvider(scope: .role(.assistant)) }
        try await waitUntil { harness.ai.waiting == 1 }

        var updatedOpenAI = app.settings.configuration(for: .openAI)
        updatedOpenAI.apiKey = "key-new"
        app.setConfiguration(updatedOpenAI, for: .openAI)

        let secondTask = Task { await app.testAndSaveProvider(scope: .role(.assistant)) }
        try await waitUntil { harness.ai.waiting == 2 }

        harness.ai.releaseFirst()
        let firstState = await firstTask.value
        XCTAssertEqual(firstState, .testing, "Superseded test finishing while a newer test is active must keep .testing")

        harness.ai.releaseAll()
        let secondState = await secondTask.value
        XCTAssertEqual(secondState, .success)

        // 4. Changing the role's model ID mid-test makes the in-flight role connection check stale.
        let modelEditTask = Task { await app.testConnection(for: .assistant) }
        try await waitUntil { harness.ai.waiting == 1 }
        app.settings.assistantModel = ModelSelection(provider: .openAI, model: "gpt-4.1")
        harness.ai.releaseAll()
        let modelEditResult = await modelEditTask.value
        XCTAssertEqual(modelEditResult, .stale)
    }

    func testSplitResizeWithModalOpenDefersSplitPanelAndSyncsDrawerOnModalDismiss() {
        let harness = makeHarness()
        let app = harness.app
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.browser.load(URL(string: "about:blank")!)
        harness.deliver(topicPage(topic("70")))

        // Compact window has the AI drawer open, then opens Settings over it:
        app.router.splitLayout = false
        app.router.openDrawer(at: .medium)
        app.router.presentDrawer()
        app.router.drawerAppeared()
        app.router.item = .expanded(.settings)
        XCTAssertNotNil(app.rootPresentation)
        XCTAssertEqual(app.router.drawerPhase, .shown)

        // Window widens into Split View while Settings is still presented (`ContentView.updateLayout`):
        app.router.splitLayout = true
        app.router.splitPanelMode = app.router.wantsDrawer ? .shown : .auto
        app.router.closeDrawer()
        app.syncDrawer()
        XCTAssertEqual(app.router.drawerPhase, .shown, "Live modal hosted inside the drawer is kept until dismissed")
        XCTAssertFalse(app.showsSplitPanel(forWidth: 1_032))

        // Render WorkspaceView at Split View width: AssistantPanel must NOT mount beside WKWebView while the compact drawer is .shown.
        let actions = BrowserActions(
            showLoginInfo: {}, addForum: {}, report: { _ in }, translatePosts: {},
            openAssistant: {}, openPanel: { _ in }, openForum: { _ in }, showForumsHome: {},
            openDigestLink: { _, _ in }, openHistory: {}, openSettings: {}, showShareHowTo: {}
        )
        let host = UIHostingController(
            rootView: WorkspaceView(
                app: app,
                browser: app.browser,
                router: app.router,
                width: 1_032,
                actions: actions,
                addressFocusRequest: 0,
                onOpenURL: { _ in }
            )
        )
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 1_032, height: 768))
        window.frame = CGRect(x: 0, y: 0, width: 1_032, height: 768)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            app.browser.webView.stopLoading()
        }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.view.layoutIfNeeded()

        XCTAssertGreaterThan(
            app.browser.webView.bounds.width,
            1_000,
            "SplitWorkspace must keep full-width web view and not mount AssistantPanel while the compact AI drawer is still .shown"
        )

        // Dismissing Settings immediately starts dismissing the drawer, and once dismissed (.closed), SplitWorkspace mounts AssistantPanel.
        app.dismissRootPresentation(.expanded(.settings))
        XCTAssertEqual(app.router.drawerPhase, .dismissing)
        XCTAssertFalse(app.isAIViewShown, "Neither drawer nor split panel is shown while drawer is still dismissing")

        app.router.drawerDismissed()
        XCTAssertEqual(app.router.drawerPhase, .closed)
        XCTAssertTrue(app.isAIViewShown)
        XCTAssertTrue(app.showsSplitPanel(forWidth: 1_032))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.view.layoutIfNeeded()
        XCTAssertLessThan(
            app.browser.webView.bounds.width,
            700,
            "SplitWorkspace mounts AssistantPanel beside WKWebView once the compact drawer reaches .closed"
        )
    }

    func testSettingsWatchedOpenDismissesSettingsAndDailyPodcastRequiresDailyDigest() async throws {
        var watched = WatchedTopic(siteURL: site, topicID: "88", url: topic("88").url, title: "Watched 88", knownPostCount: 2)
        watched.newReplies = 3
        let harness = makeHarness(snapshot: AppSnapshot(watchedTopics: [watched]))
        let app = harness.app
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()

        // 1. Manual watch check publishes `isCheckingWatches` while in flight, and opening a watched topic dismisses Settings.
        StateForumStub.postCounts = ["88": 5]
        StateForumStub.gate(path: "/t/88.json")
        let check = Task { await app.checkWatchedTopics(reason: .manual) }
        try await waitUntil { StateForumStub.isWaiting }
        XCTAssertTrue(app.isCheckingWatches)
        StateForumStub.release()
        await check.value
        XCTAssertFalse(app.isCheckingWatches)

        app.router.item = .expanded(.settings)
        app.openWatched(watched)
        XCTAssertNil(app.router.item, "Opening a watched topic from Settings › Watched topics must dismiss Settings")
        XCTAssertEqual(app.watchedTopics.first?.newReplies, 0)
        defer { app.browser.webView.stopLoading() }

        // 2. When Make a digest every day is OFF, Make the podcast every day is disabled and off in UI.
        app.settings.dailyDigestEnabled = false
        app.settings.podcastDailyEnabled = true
        let host = UIHostingController(rootView: Form { SettingsPodcastSections(app: app, podcast: app.podcast) })
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 600))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.view.layoutIfNeeded()

        let toggle = findSwitch(in: host.view)
        XCTAssertNotNil(toggle)
        XCTAssertEqual(toggle?.isEnabled, false, "Make the podcast every day must be disabled when Make a digest every day is off")
        XCTAssertEqual(toggle?.isOn, false, "Make the podcast every day must appear off when Make a digest every day is off")
    }

    func testResumedAgentRunPreservesStepsUsedAndSkipsOrphanedVoiceRuns() async throws {
        let planner = RolePlanner(actions: [
            AgentAction(thought: "Step 1", tool: "saved_summaries", arguments: [:]),
            AgentAction(thought: "Step 2", tool: "saved_summaries", arguments: [:]),
            AgentAction(thought: "Fallback answer", tool: "saved_summaries", arguments: [:])
        ])
        var settings = AppSettings()
        settings.assistantModel = ModelSelection(provider: .ollama, model: "m")
        settings.agentModel = ModelSelection(provider: .ollama, model: "m")
        settings.agentMaxSteps = 3

        let typedID = UUID()
        var typedRun = AgentRun(id: typedID, siteURL: site, goal: "Typed", provider: .ollama, model: "m", origin: .typed)
        typedRun.steps = [
            AgentStep(tool: "saved_summaries", outcome: "1"),
            AgentStep(tool: "saved_summaries", outcome: "2")
        ]
        typedRun.transcript = [
            AgentPrompt.goalMessage("Typed"),
            ChatMessage(role: .assistant, content: #"{"tool":"saved_summaries"}"#),
            AgentPrompt.observation(tool: "saved_summaries", result: "none", isError: false)
        ]

        let voiceID = UUID()
        let voiceRun = AgentRun(id: voiceID, siteURL: site, goal: "Voice", provider: .ollama, model: "m", origin: .voice)

        let followUpID = UUID()
        var followUpRun = AgentRun(id: followUpID, siteURL: site, goal: "Completed first", provider: .ollama, model: "m", origin: .typed)
        followUpRun.initialAnswer = "Initial answer"
        followUpRun.answer = "Initial answer"
        followUpRun.followUps = [ChatMessage(role: .user, content: "Follow-up")]
        followUpRun.result = nil

        var typedRecord = WorkRecord(
            type: .agent, siteURL: site,
            topicID: "agent:\(typedID.uuidString)", title: "Typed",
            url: URL(string: site)!, provider: .ollama, model: "m"
        )
        typedRecord.status = .running
        var voiceRecord = WorkRecord(
            type: .agent, siteURL: site,
            topicID: "agent:\(voiceID.uuidString)", title: "Voice",
            url: URL(string: site)!, provider: .ollama, model: "m"
        )
        voiceRecord.status = .running

        let harness = makeHarness(
            snapshot: AppSnapshot(
                settings: settings,
                activities: [typedRecord, voiceRecord],
                agentRuns: [typedRun, voiceRun, followUpRun]
            ),
            planner: planner
        )
        let app = harness.app

        // Voice run and its work record are cancelled on relaunch, not re-queued.
        XCTAssertEqual(app.activities.first(where: { $0.id == voiceRecord.id })?.status, .cancelled)
        XCTAssertEqual(app.agentRuns.first(where: { $0.id == voiceID })?.result, .cancelled)

        // Completed run with an un-restorable follow-up keeps its completed result.
        let reconciledFollowUp = try XCTUnwrap(app.agentRuns.first(where: { $0.id == followUpID }))
        XCTAssertEqual(reconciledFollowUp.result, .completed)
        XCTAssertEqual(reconciledFollowUp.error, "")

        // Resuming the typed run with 2 completed steps and maxSteps = 3 allows only 1 more tool step before stopping at the budget.
        app.restorePendingTasksIfNeeded()
        try await waitUntil { app.agentRuns.first(where: { $0.id == typedID })?.isFinished == true }
        let finishedTyped = try XCTUnwrap(app.agentRuns.first(where: { $0.id == typedID }))
        XCTAssertEqual(finishedTyped.steps.count, 4, "Resumed run must count already-completed steps against agentMaxSteps")
        XCTAssertEqual(finishedTyped.steps.last?.outcome, "Stopped at the step budget")
        XCTAssertEqual(planner.calls, 2)
    }

    func testFailedChatCoalescesConsecutiveUserRolesInAnthropicPayload() async throws {
        ChatPayloadInspectorStub.reset()
        let anthropicSessionConfig = URLSessionConfiguration.ephemeral
        anthropicSessionConfig.protocolClasses = [ChatPayloadInspectorStub.self]
        let forumSessionConfig = URLSessionConfiguration.ephemeral
        forumSessionConfig.protocolClasses = [StateForumStub.self]
        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir2) }
        let store2 = PersistentStore(fileURL: dir2.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var snap2 = AppSnapshot()
        snap2.ensureForum(site)
        try? store2.save(snap2)
        let app2 = AppModel(
            store: store2,
            forumService: ForumService(session: URLSession(configuration: forumSessionConfig), pacer: ForumRequestPacer(clock: InstantPacingClock())),
            aiService: AIService(session: URLSession(configuration: anthropicSessionConfig))
        )
        app2.usesDirectForumRequests = true
        let handler2 = app2.browser.onPageContextChanged
        app2.browser.onPageContextChanged = nil
        app2.settings.hasCompletedOnboarding = true
        app2.acceptTerms()
        app2.allowAllAIProviders()
        let anthropicConfig = ProviderConfiguration(model: "claude-sonnet-4-6", baseURL: "https://api.example.com/v1", apiKey: "sk-ant")
        app2.setConfiguration(anthropicConfig, for: .anthropic)
        app2.selectModel(ModelSelection(provider: .anthropic, model: "claude-sonnet-4-6"), for: .both)

        let t1 = ForumTopic(siteURL: site, topicID: "1", url: URL(string: "\(site)/t/topic-1/1")!, title: "Topic 1")
        let ctx = PageContext(url: t1.url, site: .discourse, siteURL: site, forumName: "Stub", topic: t1, state: .topic)
        app2.browser.setPageContext(ctx)
        handler2?(ctx)

        ChatPayloadInspectorStub.failNext = true
        app2.drafts.chat = "First question (fails)"
        app2.sendChat()
        try await waitUntil { app2.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app2.activities.first?.status, .failed)

        ChatPayloadInspectorStub.failNext = false
        app2.drafts.chat = "Second question (after reconnect)"
        app2.sendChat()
        try await waitUntil { app2.activities.allSatisfy(\.status.isTerminal) }

        let roles = ChatPayloadInspectorStub.lastRecordedRoles
        XCTAssertFalse(roles.isEmpty)
        XCTAssertNotEqual(
            roles,
            ["user", "user"],
            "Failed chat left orphan .user turn in session.history, sending consecutive user messages \(roles) to Anthropic /v1/messages"
        )
    }

    func testChatEditInteractionsWithOpenAgentRunScopeSwitchSuggestionChipAndReports() async throws {
        let planner = RolePlanner(actions: [
            AgentAction(thought: "Answer", tool: "final_answer", arguments: ["answer": "Agent reply"])
        ])
        let h = makeHarness(planner: planner)
        let app = h.app
        h.ai.gated = false
        var ollamaConfig = app.settings.configuration(for: .ollama)
        ollamaConfig.model = "model-a"
        app.setConfiguration(ollamaConfig, for: .ollama)
        var lmConfig = app.settings.configuration(for: .lmStudio)
        lmConfig.model = "model-b"
        app.setConfiguration(lmConfig, for: .lmStudio)
        app.selectModel(ModelSelection(provider: .ollama, model: "model-a"), for: .both)

        let t1 = ForumTopic(siteURL: site, topicID: "1", url: URL(string: "\(site)/t/topic-1/1")!, title: "Topic 1")
        h.deliver(PageContext(url: t1.url, site: .discourse, siteURL: site, forumName: "Stub", topic: t1, state: .topic))

        // Build 2 chat turns: Turn 1 on ollama/model-a, Turn 2 on lmStudio/model-b.
        app.drafts.chat = "Q1"
        app.sendChat()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }

        app.selectModel(ModelSelection(provider: .lmStudio, model: "model-b"), for: .role(.assistant))
        app.drafts.chat = "Q2"
        app.sendChat()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.sessions[t1.topicKey]?.history.count, 4)

        // Subcase A (Finding 11): Edit Q2 -> Q2', gate AI, cancel Q2', then report the latest chat answer (which is now A1 by model-a).
        let q2ID = try XCTUnwrap(app.sessions[t1.topicKey]?.history[2].id)
        app.editChat(messageID: q2ID)
        h.ai.gated = true
        app.drafts.chat = "Q2 edited"
        app.sendChat()
        try await waitUntil { h.ai.waiting == 1 }
        if let active = app.activities.first(where: { !$0.status.isTerminal }) {
            app.cancel(record: active)
        }
        h.ai.gated = false
        h.ai.releaseAll()

        let chatReport = try XCTUnwrap(app.currentAIOutputReport(feature: .chatAnswer))
        var reportedChatModel = ""
        if case .aiOutput(let output) = chatReport.kind {
            reportedChatModel = output.model
        }

        // Rebuild Turn 2 so history has [Q1, A1, Q2, A2] again:
        app.drafts.chat = "Q2"
        app.sendChat()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }

        // Subcase B (Finding 11): Run initial Agent on ollama/model-a, then switch Agent role to lmStudio/model-b for follow-up, and inspect report!
        app.selectModel(ModelSelection(provider: .ollama, model: "model-a"), for: .role(.agent))
        _ = try await app.performAgentRun(goal: "Initial forum goal", siteURL: site)
        let runID = try XCTUnwrap(app.agentRuns.first?.id)
        planner.restart()
        app.selectModel(ModelSelection(provider: .lmStudio, model: "model-b"), for: .role(.agent))
        app.continueAgentRun(id: runID, question: "Follow-up forum question?")
        try await waitUntil { app.agentRuns.first(where: { $0.id == runID })?.isFinished == true }
        let updatedRun = try XCTUnwrap(app.agentRuns.first(where: { $0.id == runID }))
        let agentFollowUpReport = app.aiOutputReport(for: updatedRun, answer: "Agent reply")
        var reportedAgentQuestion = ""
        var reportedAgentModel = ""
        if case .aiOutput(let output) = agentFollowUpReport.kind {
            reportedAgentQuestion = output.question ?? ""
            reportedAgentModel = output.model
        }

        // Subcase C (Finding 9): Carrying ask text when destination draft is non-empty restores previousDraft!
        let q1ID = try XCTUnwrap(app.sessions[t1.topicKey]?.history.first?.id)
        app.assistantMode = .chat
        app.drafts.chat = "Unsent topic thought"
        app.drafts.followUp = "Unsent forum follow-up"
        app.editChat(messageID: q1ID)
        XCTAssertEqual(app.drafts.chat, "Q1")
        app.setAskScope(.forum)
        app.setAskScope(.topic)
        let editStateAfterBlockedCarry = app.chatEdit
        let draftAfterBlockedCarry = app.drafts.chat

        // Subcase D (Finding 9): openAgentRun clears chatEdit when moving out of .chat!
        app.drafts.followUp = ""
        app.drafts.chat = ""
        app.editChat(messageID: q1ID)
        app.drafts.chat = ""
        app.openAgentRun(id: runID)
        let chatEditStillArmedInAgent = app.chatEdit
        app.drafts.followUp = "Question typed in Whole forum"
        app.setAskScope(.topic)
        app.sendChat()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let historyAfterOpenAgentRun = app.sessions[t1.topicKey]?.history.map(\.content) ?? []

        // Subcase E (Finding 9): applyChatSuggestion while editing Q1 cancels edit and appends Turn 4 instead of truncating!
        let countBeforeChip = app.sessions[t1.topicKey]?.history.count ?? 0
        app.editChat(messageID: q1ID)
        app.applyChatSuggestion(AskBox.suggestions[0].1)
        XCTAssertEqual(app.chatEdit, .none)
        app.sendChat()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let countAfterChip = app.sessions[t1.topicKey]?.history.count ?? 0

        XCTAssertTrue(
            reportedChatModel.contains("model-a"),
            "After editing & cancelling Turn 2, reporting A1 attributed it to '\(reportedChatModel)' instead of Turn 1's 'Ollama · model-a'"
        )
        XCTAssertEqual(
            reportedAgentQuestion,
            "Follow-up forum question?",
            "Reporting an Agent follow-up answer recorded run.goal ('\(reportedAgentQuestion)') instead of the follow-up question"
        )
        XCTAssertTrue(
            reportedAgentModel.contains("model-b"),
            "Reporting an Agent follow-up answer recorded initial model '\(reportedAgentModel)' instead of follow-up model 'LM Studio · model-b'"
        )
        XCTAssertEqual(editStateAfterBlockedCarry, .none)
        XCTAssertEqual(
            draftAfterBlockedCarry,
            "Unsent topic thought",
            "Scope round-trip with non-empty forum draft must restore previousDraft ('Unsent topic thought')"
        )
        XCTAssertEqual(
            chatEditStillArmedInAgent,
            .none,
            "openAgentRun left chatEdit armed in Agent mode (history=\(historyAfterOpenAgentRun))"
        )
        XCTAssertEqual(countAfterChip, countBeforeChip + 2, "Suggestion chip must append a turn rather than truncating history")
    }

    func testAnswerAIConsentDismissesModalWhenRequirementTurnsFalse() async throws {
        let app = makeHarness().app
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.settings.aiConsent = [:]
        let remoteConfig = ProviderConfiguration(model: "llama3", baseURL: "https://remote-ollama.example.com", apiKey: "")
        app.setConfiguration(remoteConfig, for: .ollama)
        app.selectModel(ModelSelection(provider: .ollama, model: "llama3"), for: .both)

        app.aiConsent.ask(.ollama)
        XCTAssertEqual(app.rootPresentation, .aiConsent(.ollama))

        let localConfig = ProviderConfiguration(model: "llama3", baseURL: "http://localhost:11434", apiKey: "")
        app.setConfiguration(localConfig, for: .ollama)

        app.answerAIConsent(.ollama, allow: false)
        app.answerAIConsent(.ollama, allow: true)

        XCTAssertNil(
            app.aiConsent.asking,
            "answerAIConsent must resolve aiConsent even if requiresAIConsent became false while presented"
        )
    }

    func testOnboardingDeclinedConsentAllowsRetestAndResetsToUndecided() async throws {
        let h1 = makeHarness()
        let app1 = h1.app
        h1.ai.gated = false
        app1.settings.hasCompletedOnboarding = false
        app1.settings.aiConsent = [:]
        var geminiConfig = app1.settings.configuration(for: .gemini)
        geminiConfig.apiKey = "gemini-key"
        app1.setConfiguration(geminiConfig, for: .gemini)
        app1.selectModel(ModelSelection(provider: .gemini, model: "gemini-2.5-flash"), for: .both)

        app1.aiConsent.ask(.gemini)
        app1.answerAIConsent(.gemini, allow: false)
        XCTAssertFalse(app1.isProviderReady)
        let checkResultDuringOnboarding = await app1.testAndSaveProvider(scope: .both)
        var hintDuringOnboarding = ""
        if case .failure(let message) = checkResultDuringOnboarding {
            hintDuringOnboarding = message
        }

        XCTAssertFalse(
            !app1.settings.hasCompletedOnboarding && hintDuringOnboarding.contains("Settings"),
            "Declining consent during onboarding locks out Test & Continue with '\(hintDuringOnboarding)' while Settings is unreachable"
        )
        XCTAssertEqual(app1.aiConsentState(for: .gemini), .undecided)
    }

    func testAgentFollowUpKillPreservesStepsUsedAgainstBudget() async throws {
        let planner = RolePlanner(actions: [
            AgentAction(thought: "Step", tool: "saved_summaries", arguments: [:])
        ])
        var settings = AppSettings()
        settings.hasCompletedOnboarding = true
        settings.acceptedTermsVersion = ModerationTerms.currentVersion
        settings.assistantModel = ModelSelection(provider: .ollama, model: "m")
        settings.agentModel = ModelSelection(provider: .ollama, model: "m")
        settings.agentMaxSteps = 3

        let runID = UUID()
        var followUpRun = AgentRun(id: runID, siteURL: site, goal: "Initial goal", provider: .ollama, model: "m", origin: .typed)
        followUpRun.initialAnswer = "Initial answer"
        followUpRun.answer = "Initial answer"
        followUpRun.steps = [
            AgentStep(tool: "saved_summaries", outcome: "init-1"),
            AgentStep(tool: "saved_summaries", outcome: "followup-1"),
            AgentStep(tool: "saved_summaries", outcome: "followup-2")
        ]
        followUpRun.followUps = [ChatMessage(role: .user, content: "Follow-up question")]
        followUpRun.transcript = [
            AgentPrompt.goalMessage("Initial goal"),
            ChatMessage(role: .assistant, content: #"{"tool":"final_answer","arguments":{"answer":"Initial answer"}}"#),
            AgentPrompt.followUpMessage("Follow-up question"),
            ChatMessage(role: .assistant, content: #"{"tool":"saved_summaries"}"#),
            AgentPrompt.observation(tool: "saved_summaries", result: "1", isError: false),
            ChatMessage(role: .assistant, content: #"{"tool":"saved_summaries"}"#),
            AgentPrompt.observation(tool: "saved_summaries", result: "2", isError: false)
        ]
        followUpRun.result = nil

        var record = WorkRecord(
            type: .agent, siteURL: site,
            topicID: "agent:\(runID.uuidString)", title: "Follow-up question",
            url: URL(string: site)!, provider: .ollama, model: "m"
        )
        record.status = .running

        let h = makeHarness(
            snapshot: AppSnapshot(settings: settings, activities: [record], agentRuns: [followUpRun]),
            planner: planner
        )
        h.app.restorePendingTasksIfNeeded()
        try await waitUntil { h.app.agentRuns.first(where: { $0.id == runID })?.isFinished == true }
        let resumed = try XCTUnwrap(h.app.agentRuns.first(where: { $0.id == runID }))

        XCTAssertLessThanOrEqual(
            resumed.steps.count,
            5,
            "Kill & relaunch mid-Agent follow-up reset stepsUsed to 0, running \(planner.calls) additional planner calls instead of 2 (steps.count=\(resumed.steps.count))"
        )
    }

    func testNowPlayingSheetPresentsMissingGoogleKeyAlertAndPodcastConsent() async throws {
        let h = makeHarness()
        let app = h.app
        h.ai.gated = false
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama-local"), for: .both)
        let gatedSpeech = GatedSpeechEngine()
        app.podcast.makeEngine = { _, _, _ in gatedSpeech }

        var card1 = DigestCard(siteURL: site, topicID: "1", title: "Topic 1", reason: .trending, postCount: 4)
        card1.state = .done
        card1.summary = "Topic 1 has 4 posts."
        app.digests = [DailyDigest(day: DailyDigest.dayKey(for: Date()), completedAt: Date(), cards: [card1])]

        app.settings.podcast.engine = .onDevice
        app.podcast.make(play: false)
        try await waitUntil { gatedSpeech.attempts == 1 && gatedSpeech.waiting }
        app.podcast.pauseGeneration()
        gatedSpeech.gated = false
        gatedSpeech.release()
        XCTAssertEqual(app.podcast.episode?.isComplete, false)

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let rootHost = UIHostingController(rootView: Color.clear.modifier(RouterHost(app: app, active: true)))
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = rootHost
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        rootHost.view.layoutIfNeeded()
        app.router.item = .nowPlaying
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(30))
            rootHost.view.layoutIfNeeded()
        }
        let nowPlayingSheetVC = try XCTUnwrap(rootHost.presentedViewController, "NowPlaying sheet is presented")

        app.settings.podcast.engine = .google
        app.podcast.make(play: false)
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(30))
            rootHost.view.layoutIfNeeded()
            nowPlayingSheetVC.view.layoutIfNeeded()
        }
        let alertVisibleOverSheet = (nowPlayingSheetVC is UIAlertController) || (nowPlayingSheetVC.presentedViewController is UIAlertController)
        app.dismissRootAlert()
        for _ in 0..<30 where nowPlayingSheetVC.presentedViewController != nil {
            try await Task.sleep(for: .milliseconds(30))
            rootHost.view.layoutIfNeeded()
        }
        app.router.item = nil
        for _ in 0..<30 where rootHost.presentedViewController != nil {
            try await Task.sleep(for: .milliseconds(30))
            rootHost.view.layoutIfNeeded()
        }
        window.isHidden = true
        window.rootViewController = nil

        app.router.item = .nowPlaying
        var geminiConfig = app.settings.configuration(for: .gemini)
        geminiConfig.apiKey = "gemini-key"
        app.setConfiguration(geminiConfig, for: .gemini)
        app.settings.podcastConsent = [:]
        app.podcast.make(play: false)
        let activePresentationWhileNowPlayingOpen = app.rootPresentation

        XCTAssertTrue(
            alertVisibleOverSheet,
            "Missing Google API key alert attached to RouterHost behind presented NowPlayingView sheet was dropped by UIKit"
        )
        XCTAssertEqual(
            activePresentationWhileNowPlayingOpen,
            .podcastConsent(.aiStudio),
            "Tapping Make Podcast inside NowPlayingView must present .podcastConsent(.aiStudio) over .nowPlaying"
        )
    }

    func testTodayPageAutoPodcastAndChatThreadScrollStability() async throws {
        // Part A (Finding 12): TodayPage scroll is not hijacked when unattended daily podcast auto-starts (`digestCompleted`)
        let h = makeHarness()
        let app = h.app
        h.ai.gated = false
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama-local"), for: .both)
        app.settings.dailyDigestEnabled = true
        app.settings.podcastDailyEnabled = true
        let fakeSpeech = FakeSpeechEngine()
        app.podcast.makeEngine = { _, _, _ in fakeSpeech }
        app.settings.podcast.engine = .onDevice

        let cards: [DigestCard] = (1...12).map { idx in
            var c = DigestCard(siteURL: site, topicID: "\(idx)", title: "Digest Topic \(idx) With Long Title", reason: .trending, postCount: 10)
            c.state = .done
            c.summary = String(repeating: "Detailed digest summary text for card \(idx). ", count: 8)
            return c
        }
        let today = DailyDigest(day: DailyDigest.dayKey(for: Date()), completedAt: Date(), cards: cards)
        app.digests = [today]

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let todayHost = UIHostingController(rootView: NavigationStack { TodayPage(app: app, onOpen: { _, _ in }) })
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = todayHost
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        todayHost.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        let todayScroll = try XCTUnwrap(findScrollView(in: todayHost.view, minContentHeight: 1_200))
        todayScroll.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        todayHost.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let offsetBeforeAutoPodcast = todayScroll.contentOffset.y
        XCTAssertGreaterThan(offsetBeforeAutoPodcast, 700)

        app.podcast.digestCompleted(today.id)
        try await waitUntil { app.podcast.episode?.isComplete == true && !app.podcast.activity.isRunning }
        for _ in 0..<15 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            todayHost.view.layoutIfNeeded()
        }
        let offsetWhileReadingBeforeUnrelatedAppChange = todayScroll.contentOffset.y
        XCTAssertGreaterThan(offsetWhileReadingBeforeUnrelatedAppChange, 700)
        app.settings.dailyDigestEnabled.toggle()
        for _ in 0..<30 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            todayHost.view.layoutIfNeeded()
        }
        let offsetAfterDelayedHijack = todayScroll.contentOffset.y
        app.podcast.pauseGeneration()

        // Part B (Finding 15): ChatThread (< 16 messages) when keyboard rises (`viewportHeight` shrinks while `activeChat == nil`)
        let t1 = ForumTopic(siteURL: site, topicID: "1", url: URL(string: "\(site)/t/topic-1/1")!, title: "Topic 1")
        var session = TopicSession(siteURL: site, topicID: "1", url: t1.url, title: "Topic 1")
        session.totalPosts = 20
        session.history = (1...5).flatMap { turn in
            [
                ChatMessage(role: .user, content: "User question number \(turn) about the topic details?"),
                ChatMessage(role: .assistant, content: String(repeating: "Assistant detailed answer paragraph for turn \(turn). ", count: 6))
            ]
        }
        let hChat = makeHarness(snapshot: AppSnapshot(sessions: [session]))
        let chatApp = hChat.app
        chatApp.settings.hasCompletedOnboarding = true
        chatApp.acceptTerms()
        chatApp.allowAllAIProviders()
        chatApp.selectModel(ModelSelection(provider: .ollama, model: "llama-local"), for: .both)
        hChat.deliver(PageContext(url: t1.url, site: .discourse, siteURL: site, forumName: "Stub", topic: t1, state: .topic))
        chatApp.assistantMode = .chat

        let chatHost = UIHostingController(rootView: AssistantPanel(app: chatApp, onExpand: { _ in }))
        window.rootViewController = chatHost
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        chatHost.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        let chatScroll = try XCTUnwrap(findScrollView(in: chatHost.view, minContentHeight: 700))
        let bottomOffsetBeforeKeyboard = max(0, chatScroll.contentSize.height - chatScroll.bounds.height)
        chatScroll.setContentOffset(CGPoint(x: 0, y: bottomOffsetBeforeKeyboard), animated: false)
        chatHost.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let distanceFromBottomBeforeKeyboard = chatScroll.contentSize.height - (chatScroll.contentOffset.y + chatScroll.bounds.height)
        XCTAssertLessThan(distanceFromBottomBeforeKeyboard, 20, "Reader starts at bottom")

        window.frame = CGRect(x: 0, y: 0, width: 393, height: 532)
        chatHost.view.layoutIfNeeded()
        for _ in 0..<15 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            chatHost.view.layoutIfNeeded()
        }
        let distanceFromBottomAfterKeyboard = chatScroll.contentSize.height - (chatScroll.contentOffset.y + chatScroll.bounds.height)

        XCTAssertGreaterThan(
            offsetAfterDelayedHijack,
            600,
            "TodayPage must not yank scroll back to top after unattended podcast finishes"
        )
        XCTAssertLessThan(
            distanceFromBottomAfterKeyboard,
            48,
            "When viewport shrank by keyboard height with activeChat == nil in 10-message VStack, ChatThread must keep latest reply pinned to bottom"
        )
    }

    func testChatThread15To16TransitionWhileScrolledUpPreservesOffset() async throws {
        let t1 = ForumTopic(siteURL: site, topicID: "1", url: URL(string: "\(site)/t/topic-1/1")!, title: "Topic 1")
        var session = TopicSession(siteURL: site, topicID: "1", url: t1.url, title: "Topic 1")
        session.totalPosts = 20
        session.history = (1...7).flatMap { turn in
            [
                ChatMessage(role: .user, content: "User question number \(turn) about the topic details?"),
                ChatMessage(role: .assistant, content: String(repeating: "Assistant detailed answer paragraph for turn \(turn). ", count: 8))
            ]
        }
        let h = makeHarness(snapshot: AppSnapshot(sessions: [session]))
        let app = h.app
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama-local"), for: .both)
        h.deliver(PageContext(url: t1.url, site: .discourse, siteURL: site, forumName: "Stub", topic: t1, state: .topic))
        app.assistantMode = .chat

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let host = UIHostingController(rootView: AssistantPanel(app: app, onExpand: { _ in }))
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        app.drafts.chat = "Eighth question crossing 15 to 16?"
        app.sendChat()
        try await waitUntil { h.ai.waiting == 1 }
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(30))
            host.view.layoutIfNeeded()
        }

        let scroll = try XCTUnwrap(findScrollView(in: host.view, minContentHeight: 900))
        scroll.setContentOffset(CGPoint(x: 0, y: 350), animated: false)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(30))
            host.view.layoutIfNeeded()
        }
        let offsetBefore16 = scroll.contentOffset.y
        XCTAssertEqual(offsetBefore16, 350, accuracy: 5)

        h.ai.gated = false
        h.ai.releaseAll()
        try await waitUntil { app.sessions["forum.example.com/t/1"]?.history.count == 16 }
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(30))
            host.view.layoutIfNeeded()
        }
        let offsetAfter16 = scroll.contentOffset.y
        XCTAssertEqual(
            offsetAfter16,
            offsetBefore16,
            accuracy: 40,
            "Crossing 15 -> 16 messages in ChatThread shifted reader's scroll offset from y=\(Int(offsetBefore16)) to y=\(Int(offsetAfter16))"
        )
    }

    private func findScrollView(in view: UIView, minContentHeight: CGFloat) -> UIScrollView? {
        var candidates: [UIScrollView] = []
        func walk(_ v: UIView) {
            if let sv = v as? UIScrollView, sv.bounds.height > 150, sv.contentSize.height >= minContentHeight {
                candidates.append(sv)
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return candidates.max(by: { $0.contentSize.height < $1.contentSize.height })
    }

    private func findSwitch(in view: UIView) -> UISwitch? {
        if let control = view as? UISwitch { return control }
        for subview in view.subviews {
            if let found = findSwitch(in: subview) { return found }
        }
        return nil
    }
}

private final class ProviderModelsStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"data":[{"id":"gpt-4o-mini"},{"id":"gpt-4.1"}]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - Stubs

/// Stands in for the AI provider: records what each call ran with, streams
/// one delta, then (while `gated`) waits until the test releases it —
/// ignoring task cancellation, like a provider that answers anyway. Also
/// used by DailyDigestTests.
final class StateAIStub: AIService {
    struct Call {
        var kind: String
        var provider: AIProvider
        var configuration: ProviderConfiguration
        var batchLimit: Int?
        var contextLimit: Int?
        var customPrompt = ""
        var content = ""
        var summary = ""

        var label: String { "\(provider.rawValue)/\(configuration.model)" }
    }

    @MainActor var calls: [Call] = []
    @MainActor var gated = true
    @MainActor var failConnection = false
    @MainActor var echoContentInSummary = false
    @MainActor var summaryError: Error?
    @MainActor private var waiters: [CheckedContinuation<Void, Never>] = []
    @MainActor private var activeSummaryProgress: (@MainActor (SummaryProgressEvent) -> Void)?
    @MainActor private var activeSummaryDelta: (@MainActor (String) -> Void)?
    @MainActor var waiting: Int { waiters.count }

    init() {
        super.init(session: .shared)
    }

    @MainActor func emitProgress(_ event: SummaryProgressEvent) {
        activeSummaryProgress?(event)
    }

    @MainActor func emitDelta(_ delta: String) {
        activeSummaryDelta?(delta)
    }

    @MainActor func releaseFirst() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    @MainActor func releaseAll() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    @MainActor private func arrive(_ call: Call, delta: String? = nil, onDelta: (@MainActor (String) -> Void)? = nil) async {
        calls.append(call)
        if let delta { onDelta?(delta) }
        guard gated else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    override func generateSummary(
        content: String,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        customPrompt: String,
        discussion: DiscussionProfile,
        batchLimit: Int = SummaryBatchLimit.default,
        onDelta: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }
    ) async throws -> String {
        await MainActor.run {
            activeSummaryProgress = onProgress
            activeSummaryDelta = onDelta
        }
        await onProgress(.batchStarted(level: 1, index: 0, count: 2))
        let call = Call(kind: "summary", provider: provider, configuration: configuration,
                        batchLimit: batchLimit, customPrompt: customPrompt, content: content)
        await arrive(call, delta: "[\(call.label)]", onDelta: onDelta)
        if let error = await summaryError { throw error }
        if await echoContentInSummary { return "Summary by \(call.label): \(content)" }
        return "Summary by \(call.label)"
    }

    override func answer(
        source: String,
        summary: String,
        history: [ChatMessage],
        contextLimit: Int,
        customPrompt: String,
        discussion: DiscussionProfile,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        onDelta: @escaping @MainActor (String) -> Void,
        summaryIsStale: Bool = false
    ) async throws -> String {
        let call = Call(kind: "chat", provider: provider, configuration: configuration,
                        contextLimit: contextLimit, customPrompt: customPrompt, content: source, summary: summary)
        await arrive(call, delta: "[\(call.label)]", onDelta: onDelta)
        return "Answer by \(call.label)"
    }

    override func testConnection(configuration: ProviderConfiguration, provider: AIProvider) async throws {
        await arrive(Call(kind: "test", provider: provider, configuration: configuration))
        if await failConnection { throw AssistantError.http(401, "Bad key") }
    }

    override func discoverModels(configuration: ProviderConfiguration, provider: AIProvider) async throws -> [String] {
        await arrive(Call(kind: "models", provider: provider, configuration: configuration))
        return ["\(provider.rawValue)-model"]
    }

    override func complete(
        system: String,
        messages: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider,
        maxTokens: Int = 512
    ) async throws -> String {
        let call = Call(kind: "complete", provider: provider, configuration: configuration)
        await arrive(call)
        return "Completed by \(call.label)"
    }
}

/// Answers each step with `saved_summaries` (no network), waiting for the
/// test to release it.
private final class SteppingPlanner: AgentPlanner, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var callCount = 0
    private var transcript: [ChatMessage] = []

    var calls: Int { lock.withLock { callCount } }
    var isWaiting: Bool { lock.withLock { continuation != nil } }
    var lastTranscript: [ChatMessage] { lock.withLock { transcript } }

    func release() {
        lock.withLock {
            continuation?.resume()
            continuation = nil
        }
    }

    func nextAction(
        system: String,
        transcript: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) async throws -> AgentAction {
        await withCheckedContinuation { continuation in
            lock.withLock {
                callCount += 1
                self.transcript = transcript
                self.continuation = continuation
            }
        }
        return AgentAction(thought: "", tool: "saved_summaries", arguments: [:])
    }
}

/// Plays `actions` in order (the last one repeats), recording the model
/// each step ran with. `gated`: each step waits for `release()`.
private final class RolePlanner: AgentPlanner, @unchecked Sendable {
    private let lock = NSLock()
    private let actions: [AgentAction]
    private let gated: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var recorded: [String] = []

    init(actions: [AgentAction], gated: Bool = false) {
        self.actions = actions
        self.gated = gated
    }

    var calls: Int { lock.withLock { recorded.count } }
    var labels: [String] { lock.withLock { recorded } }
    var isWaiting: Bool { lock.withLock { continuation != nil } }

    func release() {
        lock.withLock {
            continuation?.resume()
            continuation = nil
        }
    }

    /// Starts the script over (for a follow-up).
    func restart() {
        lock.withLock { recorded = [] }
    }

    func nextAction(
        system: String,
        transcript: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) async throws -> AgentAction {
        let index: Int = lock.withLock {
            recorded.append("\(provider.rawValue)/\(configuration.model)")
            return recorded.count - 1
        }
        if gated {
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        }
        return actions[min(index, actions.count - 1)]
    }
}

/// Forum endpoints for any `/t/{id}.json`, `/raw/{id}`, and
/// `/site/basic-info.json`, plus topic lists set per host (`lists`). One
/// path at a time can be held until released; `offline` fails every request
/// like a device without a connection. Also used by DailyDigestTests.
final class StateForumStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gatedPath: String?
    nonisolated(unsafe) private static var held: (() -> Void)?
    nonisolated(unsafe) private static var seen: [String] = []
    nonisolated(unsafe) private static var seenWithQuery: [String] = []
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var listBodies: [String: String] = [:]
    nonisolated(unsafe) private static var isOffline = false

    /// Topic list bodies by "host/path", e.g. "forum.example.com/top.json".
    static var lists: [String: String] {
        get { lock.withLock { listBodies } }
        set { lock.withLock { listBodies = newValue } }
    }

    static var offline: Bool {
        get { lock.withLock { isOffline } }
        set { lock.withLock { isOffline = newValue } }
    }

    /// Every request so far, as its path.
    static var requests: [String] { lock.withLock { seen } }
    /// Every request so far, as path?query.
    static var requestsWithQuery: [String] { lock.withLock { seenWithQuery } }

    static var postCounts: [String: Int] {
        get { lock.withLock { counts } }
        set { lock.withLock { counts = newValue } }
    }

    static var isWaiting: Bool { lock.withLock { held != nil } }

    static func reset() {
        lock.withLock {
            gatedPath = nil
            held = nil
            seen = []
            seenWithQuery = []
            counts = [:]
            listBodies = [:]
            isOffline = false
        }
    }

    static func gate(path: String) {
        lock.withLock { gatedPath = path }
    }

    static func release() {
        let respond: (() -> Void)? = lock.withLock {
            let value = held
            held = nil
            gatedPath = nil
            return value
        }
        respond?()
    }

    static func count(of path: String) -> Int {
        lock.withLock { seen.filter { $0 == path }.count }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if Self.offline {
            Self.lock.withLock { Self.seen.append(path) }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let listKey = "\(request.url?.host ?? "")\(path)"
        let pathAndQuery = request.url?.query.map { "\(path)?\($0)" } ?? path
        let respond = { [self] in
            let (status, body) = Self.lists[listKey].map { (200, $0) } ?? Self.body(for: path)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        let hold: Bool = Self.lock.withLock {
            Self.seen.append(path)
            Self.seenWithQuery.append(pathAndQuery)
            // A gate is a path, or a path?query for one page.
            guard Self.gatedPath == path || Self.gatedPath == pathAndQuery, Self.held == nil else { return false }
            Self.held = respond
            return true
        }
        if !hold { respond() }
    }

    override func stopLoading() {}

    private static func body(for path: String) -> (Int, String) {
        let parts = path.split(separator: "/").map(String.init)
        if path == "/site/basic-info.json" {
            return (200, #"{"title":"Stub Forum"}"#)
        }
        if parts.count == 2, parts[0] == "t", parts[1].hasSuffix(".json") {
            let id = String(parts[1].dropLast(5))
            let posts = postCounts[id] ?? 2
            return (200, #"{"title":"Topic \#(id)","slug":"topic-\#(id)","posts_count":\#(posts)}"#)
        }
        if parts.count == 2, parts[0] == "raw" {
            return (200, "alice | 2026-10-20 12:00:00 UTC | #1\nPost 1 of topic \(parts[1])\n\n\nbob | 2026-10-20 12:05:00 UTC | #2\nPost 2\n")
        }
        return (404, "missing")
    }
}

/// The background grace period on demand.
@MainActor
final class FakeBackgroundGrace: BackgroundGracing {
    private(set) var begun = 0
    private(set) var ended = 0
    private var expiration: (() -> Void)?

    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        begun += 1
        self.expiration = expiration
        return UIBackgroundTaskIdentifier(rawValue: begun)
    }

    func end(_ id: UIBackgroundTaskIdentifier) {
        ended += 1
        expiration = nil
    }

    /// The system's time is up.
    func expire() {
        expiration?()
    }
}

private final class ChatPayloadInspectorStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var failNext = false
    nonisolated(unsafe) static var lastRecordedRoles: [String] = []

    static func reset() {
        lock.withLock {
            failNext = false
            lastRecordedRoles = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("/messages") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read > 0 { data.append(buffer, count: read) } else { break }
            }
            stream.close()
            bodyData = data
        }
        if let bodyData,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let messages = json["messages"] as? [[String: Any]] {
            let roles = messages.compactMap { $0["role"] as? String }
            Self.lock.withLock { Self.lastRecordedRoles = roles }
        }

        let shouldFail = Self.lock.withLock { Self.failNext }
        if shouldFail {
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"Server overload"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let sse = "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Recovered answer\"}}\n\ndata: [DONE]\n\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(sse.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}


// Requests must respect consent and moderation even when saved or in flight.
@MainActor
final class AIContextValidityTests: XCTestCase {
    let siteURL = "https://forum.example.com"
    var deliverPage: ((PageContext) -> Void)?

    func makeApp(ai: AIService, snapshot: AppSnapshot? = nil, service: ForumService? = nil, planner: AgentPlanner? = nil) throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var seeded = snapshot ?? AppSnapshot()
        if snapshot == nil { seeded.ensureForum(siteURL) }
        try store.save(seeded)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StateForumStub.self]
        let app = AppModel(
            store: store,
            forumService: service ?? ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock())),
            aiService: ai,
            planner: planner,
            podcastDirectory: directory.appendingPathComponent("Podcasts", isDirectory: true),
            spotlightIndex: FakeSpotlightIndex(),
            topicActivityDonor: FakeTopicActivityDonor()
        )
        app.usesDirectForumRequests = true
        app.browser.stopLoading()
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "test-model"), for: .both)
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil
        deliverPage = { app.browser.setPageContext($0); handler?($0) }
        addTeardownBlock { @MainActor in
            for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
            app.browser.stopLoading()
            app.pauseDigest()
            app.podcast.pauseGeneration()
            if let ai = ai as? StateAIStub { ai.gated = false; ai.releaseAll() }
            StateForumStub.release()
        }
        return app
    }

    /// Polls until `condition` holds. The bound only catches a hang: public
    /// CI ran this suite 30 times slower than a Mac (one test took 24 s), so
    /// it sits far above any healthy run. A timeout names the waiting line.
    func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for work", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testBlockWhileSummaryInFlightDoesNotCertifyBlockedOutput() async throws {
        StateForumStub.reset()
        let ai = StateAIStub()
        ai.echoContentInSummary = true
        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "saved_summaries", arguments: ["query": "Topic"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done"])
        ])
        let topic = ForumTopic(siteURL: siteURL, topicID: "1", url: URL(string: siteURL + "/t/topic-1/1")!, title: "Topic 1")
        var earlier = TopicSession(siteURL: siteURL, topicID: topic.topicID, url: topic.url, title: topic.title)
        earlier.summary = "Earlier saved summary"
        let app = try makeApp(ai: ai, snapshot: AppSnapshot(sessions: [earlier], forums: [Forum(siteURL: siteURL, kind: .discourse, name: "Forum")]), planner: planner)
        XCTAssertTrue(app.enqueueSummary(for: topic, regenerate: true))
        try await waitUntil { ai.waiting == 1 }
        XCTAssertTrue(ai.calls[0].content.contains("Post 2"))
        app.blockPost(2, topicID: "1", on: siteURL)
        ai.gated = false
        ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let saved = try XCTUnwrap(app.sessions[topic.topicKey])
        XCTAssertEqual(saved.summary, earlier.summary, "An obsolete response must not replace saved reader text")
        XCTAssertFalse(app.canUseSummaryAsContext(saved))
        _ = try await app.performAgentRun(goal: "Read saved summaries", siteURL: siteURL)
        let observation = planner.transcripts.flatMap { $0 }.map(\.content).joined(separator: "\n")
        XCTAssertFalse(observation.contains("Post 2"), "Post blocked during summary generation reached the planner via saved_summaries; canUse=\(app.canUseSummaryAsContext(saved))")
    }

    func testAgentSummaryCompletedAfterBlockIsDiscarded() async throws {
        StateForumStub.reset()
        let ai = StateAIStub()
        ai.echoContentInSummary = true
        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "summarize_topic", arguments: ["topic_id": "1"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done"])
        ])
        let app = try makeApp(ai: ai, planner: planner)
        app.startAgentRun(goal: "Summarize topic one", siteURL: siteURL)
        try await waitUntil { ai.waiting == 1 }
        XCTAssertTrue(ai.calls[0].content.contains("Post 2"))
        app.blockPost(2, topicID: "1", on: siteURL)
        ai.gated = false
        ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .cancelled)
        XCTAssertFalse(app.sessions[TopicIdentity.key(siteURL: siteURL, topicID: "1")]?.hasSummary == true)
        XCTAssertFalse(planner.transcripts.flatMap { $0 }.map(\.content).joined().contains("Post 2"))
    }

    func testBlockedSavedSummaryInPriorAgentTranscriptDoesNotReachFollowUpPlanner() async throws {
        StateForumStub.reset()
        let ai = StateAIStub()
        ai.gated = false
        ai.echoContentInSummary = true
        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "saved_summaries", arguments: ["query": "Topic"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Initial answer"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Follow-up answer"])
        ])
        let app = try makeApp(ai: ai, planner: planner)
        let topic = ForumTopic(siteURL: siteURL, topicID: "1", url: URL(string: siteURL + "/t/topic-1/1")!, title: "Topic 1")
        XCTAssertTrue(app.enqueueSummary(for: topic))
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        let initial = try await app.performAgentRun(goal: "Read saved Topic summaries", siteURL: siteURL)
        let runID = initial.runID
        XCTAssertTrue(planner.transcripts.last?.map(\.content).joined().contains("Post 2") == true)
        app.blockPost(2, topicID: "1", on: siteURL)
        XCTAssertFalse(app.canUseSummaryAsContext(try XCTUnwrap(app.sessions[topic.topicKey])))
        app.continueAgentRun(id: runID, question: "Anything else?")
        try await waitUntil { app.agentRuns.first(where: { $0.id == runID })?.isFinished == true }
        let replayed = planner.transcripts.last?.map(\.content).joined(separator: "\n") ?? ""
        XCTAssertTrue(app.agentRuns.first(where: { $0.id == runID })?.transcript.map(\.content).joined().contains("Post 2") == true, "The saved transcript stays visible")
        XCTAssertFalse(replayed.contains("Post 2"), "Agent follow-up replayed the pre-block saved_summaries observation despite rejecting the saved summary itself")
    }

    func testPodcastDoesNotSendPreBlockDigestSummary() async throws {
        StateForumStub.reset()
        let ai = CapturingPodcastPromptAI()
        let app = try makeApp(ai: ai)
        var card = DigestCard(siteURL: siteURL, topicID: "1", title: "Topic 1", reason: .trending, postCount: 2)
        card.state = .done
        card.summary = "BLOCKED_POST_TWO_SECRET from post two."
        app.digests = [DailyDigest(day: DailyDigest.dayKey(for: Date()), completedAt: Date(), cards: [card])]
        app.blockPost(2, topicID: "1", on: siteURL)
        app.settings.podcast.engine = .onDevice
        app.podcast.makeEngine = { _, _, _ in SilentSpeechEngine() }
        app.podcast.make(play: false)
        try await waitUntil { !ai.prompts.isEmpty && !app.podcast.activity.isRunning }
        XCTAssertFalse(app.podcast.episode?.entries.map { $0.chapter.spokenText }.joined().contains("BLOCKED_POST_TWO_SECRET") == true, "Fallback speech also uses the regenerated card")
        XCTAssertEqual(app.todaysDigest?.cards.first?.summary, card.summary, "Saved text remains visible")
        XCTAssertFalse(ai.prompts.joined().contains("BLOCKED_POST_TWO_SECRET"), "Podcast complete() sent pre-block digest summary to script model")
    }

    func testResumedPodcastRegeneratesPreBlockScriptBeforeSpeech() async throws {
        StateForumStub.reset()
        let ai = CapturingPodcastPromptAI()
        let app = try makeApp(ai: ai)
        var card = DigestCard(siteURL: siteURL, topicID: "1", title: "Topic 1", reason: .trending, postCount: 2)
        card.state = .done
        card.summary = "BLOCKED_POST_TWO_SECRET"
        let digest = DailyDigest(day: DailyDigest.dayKey(for: Date()), completedAt: Date(), cards: [card])
        app.digests = [digest]
        var chapter = PodcastChapter(card: card)
        chapter.turns = PodcastScript.fallbackTurns(for: card)
        app.podcast.store.save(PodcastEpisode(
            digestID: digest.id, day: digest.day, title: "Podcast", language: "en", hosts: app.settings.podcast.hosts,
            engine: .onDevice, minutesPerChapter: 1, entries: [PodcastEpisode.Entry(chapter: chapter)]
        ))
        app.blockPost(2, topicID: "1", on: siteURL)
        app.settings.podcast.engine = .onDevice
        app.podcast.makeEngine = { _, _, _ in SilentSpeechEngine() }
        app.podcast.make(play: false)
        try await waitUntil { !ai.prompts.isEmpty && !app.podcast.activity.isRunning }
        XCTAssertFalse(ai.prompts.joined().contains("BLOCKED_POST_TWO_SECRET"))
        XCTAssertFalse(app.podcast.episode?.entries.map { $0.chapter.spokenText }.joined().contains("BLOCKED_POST_TWO_SECRET") == true)
    }

    func testWithdrawCancelsCrossRoleSummaryAfterAssistantSwitch() async throws {
        StateForumStub.reset()
        let ai = CancellableSummaryAI()
        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "summarize_topic", arguments: ["topic_id": "1"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done"])
        ])
        let app = try makeApp(ai: ai, planner: planner)
        var configuration = app.settings.configuration(for: .openAI)
        configuration.apiKey = "test-key"
        app.setConfiguration(configuration, for: .openAI)
        app.selectModel(ModelSelection(provider: .openAI, model: "test-model"), for: .role(.assistant))
        app.startAgentRun(goal: "Summarize topic one", siteURL: siteURL)
        try await waitUntil { ai.waiting == 1 }
        XCTAssertEqual(ai.provider, .openAI)
        app.selectModel(ModelSelection(provider: .lmStudio, model: "local-model"), for: .role(.assistant))
        app.withdrawAIConsent(.openAI)
        XCTAssertEqual(app.activities.first?.status, .cancelled, "Cross-role OpenAI summary still running after withdrawal because live assistant role has switched")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(ai.cancelled, "In-flight summarizer task received no cancellation after consent withdrawal")
        ai.release()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
    }

    func testBlockedContentInPreviousChatAnswerDoesNotReachNextChat() async throws {
        try await assertPriorChatAnswerIsExcluded(synced: false)
    }

    func testSyncedBlockExcludesPreviousChatAnswerFromNextRequest() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "Timing-sensitive multi-turn chat and sync block race on 3-vCPU CI simulator (see docs/wukongmind/flaky-tests.md)")
        try await assertPriorChatAnswerIsExcluded(synced: true)
    }

    private func assertPriorChatAnswerIsExcluded(synced: Bool) async throws {
        StateForumStub.reset()
        let ai = EchoingChatContextAI()
        let app = try makeApp(ai: ai)
        let topic = ForumTopic(siteURL: siteURL, topicID: "1", url: URL(string: siteURL + "/t/topic-1/1")!, title: "Topic 1")
        deliverPage?(PageContext(url: topic.url, site: .discourse, siteURL: siteURL, forumName: "Forum", topic: topic, state: .topic))
        app.drafts.chat = "Quote the replies"
        app.sendChat()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertTrue(app.sessions[topic.topicKey]?.history.last?.content.contains("Post 2") == true)
        if synced {
            var remote = app.settings
            // Another device blocked it in the answer's second; sync drops fractions.
            let blockedAt = SyncCoding.stamp(try XCTUnwrap(app.sessions[topic.topicKey]?.history.last).createdAt)
            remote.blockedPosts.append(BlockedPost(siteURL: siteURL, topicID: "1", postNumber: 2, blockedAt: blockedAt))
            let skipped = app.applyRemote(SyncChanges(settings: SyncSettingsChange(expected: app.settings.persistable, units: try SyncSchema.settingsUnits(remote))))
            XCTAssertTrue(skipped.isEmpty)
        } else {
            app.blockPost(2, topicID: "1", on: siteURL)
        }
        app.drafts.chat = "What else?"
        app.sendChat()
        try await waitUntil { ai.histories.count == 2 && app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertFalse(ai.sources.last?.contains("Post 2") == true, "Raw source is correctly moderated")
        XCTAssertFalse(ai.histories.last?.contains("Post 2") == true, "Previous AI answer quoting blocked post two was sent back in next chat history")
        XCTAssertTrue(app.sessions[topic.topicKey]?.history.first(where: { $0.role == .assistant })?.content.contains("Post 2") == true, "Saved answers stay visible")
    }

    /// The developer's list refreshes while a chat is answered: the chat is
    /// asked again under the new list instead of ending as "Cancelled".
    func testRemoteListArrivingMidChatAnswersUnderTheNewList() async throws {
        StateForumStub.reset()
        let ai = StateAIStub()
        let app = try makeApp(ai: ai)
        let topic = ForumTopic(siteURL: siteURL, topicID: "1", url: URL(string: siteURL + "/t/topic-1/1")!, title: "Topic 1")
        deliverPage?(PageContext(url: topic.url, site: .discourse, siteURL: siteURL, forumName: "Forum", topic: topic, state: .topic))
        app.drafts.chat = "Quote the replies"
        app.sendChat()
        try await waitUntil { ai.waiting == 1 }
        XCTAssertTrue(ai.calls.last?.content.contains("Post 2") == true)
        app.remoteModeration = RemoteModerationList(posts: [.init(site: siteURL, topic: 1, post: 2)])
        ai.gated = false
        ai.releaseAll()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first { $0.type == .chat }?.status, .completed, "A list refresh must not cancel the user's chat")
        XCTAssertEqual(app.sessions[topic.topicKey]?.history.last?.role, .assistant)
        XCTAssertFalse(ai.calls.last?.content.contains("Post 2") == true, "The answer kept was asked under the new list")
    }

    /// The developer's list refreshes while Ask the forum runs: the run starts
    /// again from scratch under the new list (a resume would replay what it
    /// read before) and answers, instead of ending as "Cancelled".
    func testRemoteListArrivingMidAgentRunRestartsItFromScratch() async throws {
        StateForumStub.reset()
        let ai = StateAIStub()
        ai.echoContentInSummary = true
        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "1"]),
            AgentAction(thought: "", tool: "summarize_topic", arguments: ["topic_id": "1"]),
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "1"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done"])
        ])
        let app = try makeApp(ai: ai, planner: planner)
        var outcomes: [AgentRunOutcome] = []
        let goal = "Read topic one"
        let runID = try app.startAgentRun(goal: goal, siteURL: siteURL) { outcomes.append($0) }
        try await waitUntil { ai.waiting == 1 }
        XCTAssertTrue(planner.transcripts[1].map(\.content).joined().contains("Post 2"), "The first run read post two")
        let restartIndex = planner.transcripts.count
        app.remoteModeration = RemoteModerationList(posts: [.init(site: siteURL, topic: 1, post: 2)])
        ai.gated = false
        ai.releaseAll()
        try await waitUntil { !outcomes.isEmpty && app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(outcomes.map(\.status), [.completed], "A list refresh must not cancel the run")
        XCTAssertEqual(outcomes.first?.answer, "Done")
        let run = try XCTUnwrap(app.agentRuns.first { $0.id == runID })
        XCTAssertEqual(run.steps.map(\.tool), ["read_topic", AgentPrompt.finalAnswerTool], "Only the restarted run's steps are kept")
        let restarted = Array(planner.transcripts[restartIndex...])
        XCTAssertEqual(restarted.first?.map(\.content), [AgentPrompt.goalMessage(goal).content], "The restarted run begins at step 0 with only the goal")
        XCTAssertFalse(restarted.flatMap { $0 }.map(\.content).joined(separator: "\n").contains("Post 2"), "The restarted run's planner saw a post the new list hides")
    }

    /// A follow-up the list interrupts restarts as that follow-up: the
    /// earlier answer stays, the planner gets only the questions.
    func testRemoteListArrivingMidFollowUpRestartsThatFollowUp() async throws {
        StateForumStub.reset()
        let ai = StateAIStub()
        ai.echoContentInSummary = true
        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "1"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Initial"]),
            AgentAction(thought: "", tool: "summarize_topic", arguments: ["topic_id": "1"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Follow-up answer"])
        ])
        let app = try makeApp(ai: ai, planner: planner)
        let goal = "Read topic one"
        let runID = try await app.performAgentRun(goal: goal, siteURL: siteURL).runID
        app.continueAgentRun(id: runID, question: "Anything else?")
        try await waitUntil { ai.waiting == 1 }
        let restartIndex = planner.transcripts.count
        app.remoteModeration = RemoteModerationList(posts: [.init(site: siteURL, topic: 1, post: 2)])
        ai.gated = false
        ai.releaseAll()
        try await waitUntil { app.agentRuns.first { $0.id == runID }?.isFinished == true && app.activities.allSatisfy(\.status.isTerminal) }
        let run = try XCTUnwrap(app.agentRuns.first { $0.id == runID })
        XCTAssertEqual(run.result, .completed)
        XCTAssertEqual(run.initialAnswer, "Initial")
        XCTAssertEqual(run.followUps.map(\.content), ["Anything else?", "Follow-up answer"])
        XCTAssertEqual(run.steps.map(\.tool), ["read_topic", AgentPrompt.finalAnswerTool, AgentPrompt.finalAnswerTool], "The first turn's steps stay; the interrupted turn's are dropped")
        let restarted = Array(planner.transcripts[restartIndex...])
        XCTAssertEqual(restarted.first?.map(\.content), [AgentPrompt.goalMessage(goal).content, AgentPrompt.followUpMessage("Anything else?").content])
        XCTAssertFalse(restarted.flatMap { $0 }.map(\.content).joined(separator: "\n").contains("Post 2"))
    }

    func testSyncedConsentWithdrawalDoesNotLeaveDigestCardWorkingForever() async throws {
        StateForumStub.reset()
        let ai = StateAIStub()
        let topicURL = URL(string: siteURL + "/t/topic-1/1")!
        let watched = WatchedTopic(siteURL: siteURL, topicID: "1", url: topicURL, title: "Topic 1", knownPostCount: 1)
        let app = try makeApp(ai: ai, snapshot: AppSnapshot(watchedTopics: [watched], forums: [Forum(siteURL: siteURL, kind: .discourse, name: "Forum")]))
        var configuration = app.settings.configuration(for: .openAI)
        configuration.apiKey = "test-key"
        app.setConfiguration(configuration, for: .openAI)
        app.selectModel(ModelSelection(provider: .openAI, model: "test-model"), for: .role(.assistant))
        app.makeTodaysDigest()
        try await waitUntil { ai.waiting == 1 }
        // Exercise the actual remote-settings apply path, as another device's withdrawal would.
        var remote = app.settings
        remote.aiConsent[AIProvider.openAI.rawValue] = .declined(Date())
        let skipped = app.applyRemote(SyncChanges(settings: SyncSettingsChange(expected: app.settings.persistable, units: try SyncSchema.settingsUnits(remote))))
        XCTAssertTrue(skipped.isEmpty)
        guard case .declined = app.aiConsentState(for: .openAI) else { return XCTFail("Remote withdrawal did not apply") }
        ai.gated = false
        ai.releaseAll()
        try await waitUntil { !app.digestActivity.isRunning }
        let afterWithdrawal = app.todaysDigest?.cards.first?.state
        app.settings.aiConsent[AIProvider.openAI.rawValue] = .allowed(Date())
        app.makeTodaysDigest()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(afterWithdrawal, .failed, "The failed card offers retry after consent withdrawal")
        XCTAssertNotEqual(app.todaysDigest?.cards.first?.state, .working, "Re-allow and resume still leave the card working, with no digest task")
        app.retryDigestCard(try XCTUnwrap(app.todaysDigest?.cards.first))
        try await waitUntil { app.todaysDigest?.cards.first?.state == .done && !app.digestActivity.isRunning }
    }

    func testWordPressBlockedAuthorWithoutCachedArticleDoesNotReachPlanner() async throws {
        let wp = WordPressFixtureSite(commentCount: 0)
        var posts = wp.posts
        posts[0]["_embedded"] = ["author": [["name": "alice"]]]
        posts[0]["author"] = 1
        wp.posts = posts
        let site = WordPressFixtureSite.siteURL
        let ai = StateAIStub()
        ai.gated = false
        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "search_forum", arguments: ["query": "Opening post"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done"])
        ])
        let app = try makeApp(ai: ai, snapshot: AppSnapshot(forums: [Forum(siteURL: site, kind: .wordpress, name: "Blog")]), service: wp.service(), planner: planner)
        // The listing and article identify the same author, without a cached read.
        let article = try XCTUnwrap(WordPressParsing.parseArticle(WordPressFixtureSite.fixtureObject("article-1001")))
        XCTAssertEqual(article.author, "alice")
        app.block("alice", on: site)
        _ = try await app.performAgentRun(goal: "Find the opening post", siteURL: site)
        let observation = planner.transcripts.flatMap { $0 }.map(\.content).joined(separator: "\n")
        XCTAssertFalse(observation.contains("Opening post: the card is offering"), "Blocked author alice's article excerpt reached planner without cached author metadata")
    }
}

private final class CapturingPodcastPromptAI: AIService {
    override func generateSummary(content: String, configuration: ProviderConfiguration, provider: AIProvider, customPrompt: String, discussion: DiscussionProfile, batchLimit: Int = SummaryBatchLimit.default, onDelta: @escaping @MainActor (String) -> Void, onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }) async throws -> String {
        return "Fresh digest: " + content
    }
    @MainActor var prompts: [String] = []
    override func complete(system: String, messages: [ChatMessage], configuration: ProviderConfiguration, provider: AIProvider, maxTokens: Int = 512) async throws -> String {
        await MainActor.run { prompts.append(messages.map(\.content).joined(separator: "\n")) }
        throw AssistantError.http(400, "Prompt captured; no network request")
    }
}

private final class EchoingChatContextAI: AIService {
    @MainActor var histories: [String] = []
    @MainActor var sources: [String] = []
    override func answer(source: String, summary: String, history: [ChatMessage], contextLimit: Int, customPrompt: String, discussion: DiscussionProfile, configuration: ProviderConfiguration, provider: AIProvider, onDelta: @escaping @MainActor (String) -> Void, summaryIsStale: Bool = false) async throws -> String {
        await MainActor.run {
            histories.append(history.map(\.content).joined(separator: "\n"))
            sources.append(source)
        }
        return "Quoted replies: " + source
    }
}

private final class CancellableSummaryAI: AIService {
    @MainActor var provider: AIProvider?
    @MainActor var waiting = 0
    @MainActor var cancelled = false
    @MainActor private var continuation: CheckedContinuation<Void, Never>?
    @MainActor func release() { continuation?.resume(); continuation = nil }
    override func generateSummary(content: String, configuration: ProviderConfiguration, provider: AIProvider, customPrompt: String, discussion: DiscussionProfile, batchLimit: Int = SummaryBatchLimit.default, onDelta: @escaping @MainActor (String) -> Void, onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }) async throws -> String {
        await withTaskCancellationHandler {
            await MainActor.run { self.provider = provider }
            await hold()
        } onCancel: {
            Task { @MainActor in self.cancelled = true; self.release() }
        }
        try Task.checkCancellation()
        return "Summary"
    }
    @MainActor private func hold() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiting += 1
        }
    }
}
