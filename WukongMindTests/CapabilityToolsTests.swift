import SwiftUI
import UIKit
import UserNotifications
import Vision
import XCTest
@testable import WukongMind

@MainActor
final class CapabilityToolsTests: XCTestCase {
    private let site = "https://forum.example.com"

    override func setUp() async throws { CapabilityForumStub.reset() }
    override func tearDown() async throws { CapabilityForumStub.reset() }

    func testSummarizeTopicReusesCachedSummaryAndFetchesOnlyNewRepliesOnGrownThread() async throws {
        CapabilityForumStub.postCounts["1"] = 102
        let h = makeHarness(gatedAI: false)
        selectTopic(h.app, id: "1")
        let registry = makeRegistry(h.app)

        let first = try await registry.dispatch(toolName: "summarize_topic", arguments: ["topic_id": .string("1")])
        XCTAssertFalse(first.isError, first.output)
        XCTAssertEqual(first.resultSummary, "Topic 1")
        XCTAssertTrue(first.output.hasPrefix("Summary of Topic 1 (https://forum.example.com/t/topic-1/1), 102 posts:\n\n"))
        XCTAssertTrue(first.output.contains("#1"), "Summary must preserve #N citations")
        XCTAssertEqual(first.shape, .thread(ThreadShape(id: "1", title: "Topic 1", url: "https://forum.example.com/t/topic-1/1", posts: [], totalPosts: 102)))
        XCTAssertEqual(h.ai.calls.count, 1)
        let page1Before = CapabilityForumStub.queryCount("/raw/1?page=1"), page2Before = CapabilityForumStub.queryCount("/raw/1?page=2")
        XCTAssertEqual(page1Before, 1); XCTAssertEqual(page2Before, 1)

        let cached = try await registry.dispatch(toolName: "summarize_topic", arguments: ["topic_id": .string("1")])
        XCTAssertFalse(cached.isError)
        XCTAssertEqual(h.ai.calls.count, 1)
        XCTAssertEqual(CapabilityForumStub.queryCount("/raw/1?page=1"), page1Before)
        XCTAssertEqual(CapabilityForumStub.queryCount("/raw/1?page=2"), page2Before)
        XCTAssertEqual(cached.output, first.output)

        CapabilityForumStub.postCounts["1"] = 104
        let grown = try await registry.dispatch(toolName: "summarize_topic", arguments: ["topic_id": .string("1")])
        XCTAssertFalse(grown.isError, grown.output)
        XCTAssertEqual(h.ai.calls.count, 2)
        XCTAssertEqual(CapabilityForumStub.queryCount("/raw/1?page=1"), page1Before, "Cached full page 1 must not be re-downloaded")
        XCTAssertEqual(CapabilityForumStub.queryCount("/raw/1?page=2"), page2Before + 1, "Only grown page 2 should be fetched")
        XCTAssertTrue(grown.output.hasPrefix("Summary of Topic 1 (https://forum.example.com/t/topic-1/1), 104 posts:\n\n"))
        XCTAssertEqual(h.app.sessions["forum.example.com/t/1"]?.summaryPostCount, 104)
    }

    func testSummarizeTopicWaitsForSummaryAlreadyRunning() async throws {
        let h = makeHarness(gatedAI: true)
        let topic = ForumTopic(siteURL: site, topicID: "1", url: URL(string: "\(site)/t/topic-1/1")!, title: "Topic 1")
        h.app.select(topic: topic)
        let registry = makeRegistry(h.app)
        XCTAssertTrue(h.app.enqueueSummary(for: topic))
        try await waitUntil { h.ai.waiting == 1 }

        let joined = Task { try await registry.dispatch(toolName: "summarize_topic", arguments: ["topic_id": .string("1")]) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(h.app.activities.filter { $0.type == .summary }.count, 1, "Must join running summary instead of starting a second one")
        XCTAssertEqual(h.ai.calls.count, 1)
        h.ai.gated = false; h.ai.releaseAll()
        let result = try await joined.value
        XCTAssertFalse(result.isError)
        XCTAssertEqual(h.ai.calls.count, 1)
        XCTAssertTrue(result.output.contains("Summary by ollama/summary-model"))
    }

    func testStopCancelsWaitWhileSummaryFinishesAndStaysCached() async throws {
        let h = makeHarness(gatedAI: true)
        selectTopic(h.app, id: "1")
        let registry = makeRegistry(h.app)
        let toolTask = Task { try await registry.dispatch(toolName: "summarize_topic", arguments: ["topic_id": .string("1")]) }
        try await waitUntil { h.ai.waiting == 1 }
        XCTAssertEqual(h.app.activities.first?.status, .running)

        toolTask.cancel()
        do { _ = try await toolTask.value; XCTFail("Cancelled tool call must throw CancellationError") } catch is CancellationError {}
        XCTAssertEqual(h.app.activities.first?.status, .running)
        h.ai.gated = false; h.ai.releaseAll()
        try await waitUntil { h.app.activities.first?.status == .completed }
        XCTAssertEqual(h.app.sessions["forum.example.com/t/1"]?.hasSummary, true)
    }

    func testSummarizeTopicTextAndPathInputsUseGenericProfileWithoutCaching() async throws {
        let h = makeHarness(gatedAI: false)
        _ = try await h.app.agentWorkspace.write(path: "notes/article.md", content: "First line title\nDetailed body about Swift concurrency.")
        let registry = makeRegistry(h.app)

        let fromText = try await registry.dispatch(toolName: "summarize_topic", arguments: ["text": .string(" Web Article\nBody paragraphs here.")])
        XCTAssertFalse(fromText.isError, fromText.output)
        XCTAssertEqual(fromText.resultSummary, "Web Article")
        XCTAssertNil(fromText.shape)
        XCTAssertEqual(h.ai.lastDiscussion, .genericText)

        let fromPath = try await registry.dispatch(toolName: "summarize_topic", arguments: ["path": .string("notes/article.md")])
        XCTAssertFalse(fromPath.isError, fromPath.output)
        XCTAssertEqual(fromPath.resultSummary, "article.md")
        XCTAssertNil(fromPath.shape)
        XCTAssertTrue(h.app.sessions.isEmpty, "Text and path summaries are not cached as forum sessions")
    }

    func testReadAloudStartsPlayerAndReturnsAtOnce() async throws {
        let h = makeHarness(gatedAI: false)
        selectTopic(h.app, id: "1")
        let speech = RecordingGatedSpeech()
        h.app.podcast.makeEngine = { _, _, _ in speech }
        h.app.settings.podcast.engine = .onDevice
        _ = try await h.app.agentWorkspace.write(path: "clip.txt", content: "Short note for spoken playback.")
        let registry = makeRegistry(h.app)

        let threadResult = try await registry.dispatch(toolName: "read_aloud", arguments: ["topic_id": .string("1")])
        XCTAssertFalse(threadResult.isError, threadResult.output)
        XCTAssertEqual(threadResult.resultSummary, "Topic 1")
        XCTAssertTrue(threadResult.output.hasPrefix("Reading aloud: Topic 1, about 1 minute"))
        XCTAssertTrue(h.app.podcast.isReadingAloud("forum.example.com/t/1"))
        try await waitUntil { speech.waiting }
        XCTAssertFalse(speech.lastText.contains("#1"), "Citations must be stripped before speaking")
        speech.gated = false; speech.release()

        let pathResult = try await registry.dispatch(toolName: "read_aloud", arguments: ["path": .string("clip.txt")])
        XCTAssertFalse(pathResult.isError, pathResult.output)
        XCTAssertEqual(pathResult.resultSummary, "clip.txt")
        XCTAssertTrue(h.app.podcast.isReadingAloud(CapabilityReadAloud.pathID("clip.txt")))
    }

    func testWatchTopicFollowsNeverUnfollowsAndValidatesForumArgs() async throws {
        let h = makeHarness(gatedAI: false)
        let registry = makeRegistry(h.app)

        let noForum = try await registry.dispatch(toolName: "watch_topic", arguments: ["topic_id": .string("1")])
        XCTAssertTrue(noForum.isError)
        XCTAssertTrue(noForum.output.contains("No forum is open"))

        selectTopic(h.app, id: "1")
        let first = try await registry.dispatch(toolName: "watch_topic", arguments: ["topic_id": .string("1")])
        XCTAssertFalse(first.isError, first.output)
        XCTAssertEqual(first.resultSummary, "Topic 1")
        XCTAssertTrue(h.app.isWatched(topicKey: "forum.example.com/t/1"))

        let second = try await registry.dispatch(toolName: "watch_topic", arguments: ["topic_id": .string("1")])
        XCTAssertFalse(second.isError)
        XCTAssertTrue(h.app.isWatched(topicKey: "forum.example.com/t/1"))

        let foreign = try await registry.dispatch(toolName: "watch_topic", arguments: ["url": .string("https://other.example.org/t/foreign-topic/77")])
        XCTAssertFalse(foreign.isError, foreign.output)
        XCTAssertTrue(h.app.isWatched(topicKey: "other.example.org/t/77"))
    }

    func testNotifyRequestsPermissionAndReturnsErrorWhenDenied() async throws {
        let box = NotificationProbe()
        let h = makeHarness(gatedAI: false, notifier: WatchNotifier(backend: box.backend))
        let registry = makeRegistry(h.app)

        box.status = .notDetermined; box.grantResult = true
        let ok = try await registry.dispatch(toolName: "notify", arguments: ["title": .string("Done"), "body": .string("Crawl finished.")])
        XCTAssertFalse(ok.isError, ok.output)
        XCTAssertEqual(ok.resultSummary, "Done")
        XCTAssertEqual(box.promptCount, 1); XCTAssertEqual(box.requests.count, 1)
        XCTAssertEqual(box.requests.first?.content.title, "Done"); XCTAssertEqual(box.requests.first?.content.body, "Crawl finished.")

        box.status = .denied
        let denied = try await registry.dispatch(toolName: "notify", arguments: ["title": .string("Done"), "body": .string("Again")])
        XCTAssertTrue(denied.isError)
        XCTAssertEqual(box.promptCount, 1); XCTAssertEqual(box.requests.count, 1)

        box.status = .notDetermined; box.grantResult = false
        let declined = try await registry.dispatch(toolName: "notify", arguments: ["title": .string("Done"), "body": .string("Declined")])
        XCTAssertTrue(declined.isError)
        XCTAssertEqual(box.promptCount, 2)
    }

    func testCapabilityLabelsAndCardsRenderUnderToolRow() async throws {
        XCTAssertEqual(DCToolLabel.browser("summarize_topic", running: true), "Summarizing thread")
        XCTAssertEqual(DCToolLabel.browser("summarize_topic", running: false), "Summarized thread")
        XCTAssertEqual(DCToolLabel.browser("read_aloud", running: true), "Starting reading aloud")
        XCTAssertEqual(DCToolLabel.browser("read_aloud", running: false), "Reading aloud")
        XCTAssertEqual(DCToolLabel.browser("watch_topic", running: true), "Following thread")
        XCTAssertEqual(DCToolLabel.browser("watch_topic", running: false), "Following thread")
        XCTAssertEqual(DCToolLabel.browser("notify", running: true), "Sending notification")
        XCTAssertEqual(DCToolLabel.browser("notify", running: false), "Sent notification")

        let notifyBox = NotificationProbe()
        let h = makeHarness(gatedAI: false, notifier: WatchNotifier(backend: notifyBox.backend))
        selectTopic(h.app, id: "1")
        let speech = RecordingGatedSpeech(); speech.gated = false
        h.app.podcast.makeEngine = { _, _, _ in speech }
        h.app.settings.podcast.engine = .onDevice

        let client = RecordedModelClient([
            .success(AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "c1", name: "summarize_topic", arguments: ["topic_id": .string("1")])])),
            .success(AgentModelTurnResponse(text: "Summarized the thread.")),
            .success(AgentModelTurnResponse(text: "", toolCalls: [
                AgentModelToolCall(id: "c2", name: "summarize_topic", arguments: ["text": .string("Note title\nPlain text note content.")]),
                AgentModelToolCall(id: "c3", name: "read_aloud", arguments: ["topic_id": .string("1")])
            ])),
            .success(AgentModelTurnResponse(text: "Playing the summary aloud.")),
            .success(AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "c4", name: "watch_topic", arguments: ["topic_id": .string("1")])])),
            .success(AgentModelTurnResponse(text: "Following for new replies.")),
            .success(AgentModelTurnResponse(text: "", toolCalls: [AgentModelToolCall(id: "c5", name: "notify", arguments: ["title": .string("Crawl complete"), "body": .string("Summary is ready.")])])),
            .success(AgentModelTurnResponse(text: "Sent you a notification."))
        ])
        let agentSession = BrowserAgentSession(
            pageDriver: FixturePageDriver(page: .init(url: site, title: "Stub")), modelClient: client,
            configProvider: {
                var cfg = ProviderConfiguration(provider: .ollama); cfg.model = "agent-model"
                return BrowserAgentRuntimeConfig(selection: ModelSelection(provider: .ollama, model: "agent-model"), configuration: cfg, maxSteps: 6, truncationLimit: 20_000, customInstructions: "", redactedSecrets: [])
            },
            registryBuilder: { _, _, _ in self.makeRegistry(h.app) }
        )

        for prompt in ["Summarize this thread", "Summarize note and read aloud", "Follow this thread", "Tell me when done"] {
            agentSession.send(prompt)
            let target = agentSession.runs.count
            try await waitUntil { !agentSession.isRunning && agentSession.runs.count == target }
        }
        XCTAssertEqual(BrowserAgentRunsView.capabilityEntries(in: agentSession.runs[0].toolCalls).count, 1)
        XCTAssertEqual(BrowserAgentRunsView.capabilityEntries(in: agentSession.runs[1].toolCalls).count, 2)

        let lightImage = await renderRunsView(app: h.app, session: agentSession, scheme: .light)
        let darkImage = await renderRunsView(app: h.app, session: agentSession, scheme: .dark)
        for (name, img) in [("capability-cards-light", lightImage), ("capability-cards-dark", darkImage)] {
            let attachment = XCTAttachment(image: img); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }

        let recognized = try recognizeLines(in: try XCTUnwrap(lightImage.cgImage))
        let allText = recognized.map(\.text).joined(separator: "\n")
        let rowY = try XCTUnwrap(recognized.first { $0.text.contains("Summarized thread") }?.topDownY, "ToolRow missing in:\n\(allText)")
        let threadCardY = try XCTUnwrap(recognized.first { $0.text.contains("ollama/summary-model") }?.topDownY, "Thread summary card missing in:\n\(allText)")
        XCTAssertGreaterThan(threadCardY, rowY, "Thread summary card must render under the ToolRow")

        let stepsY = try XCTUnwrap(recognized.first { $0.text.contains("Steps 2") }?.topDownY, "Folded Steps row missing in:\n\(allText)")
        let noteCardY = try XCTUnwrap(recognized.first { $0.text.contains("Note title") }?.topDownY, "Generic text ResultCard missing in:\n\(allText)")
        let listenRowY = try XCTUnwrap(recognized.first { $0.text.contains("0:12") || $0.text.contains("About 1 minute") }?.topDownY, "ListenRow missing in:\n\(allText)")
        let watchRowY = try XCTUnwrap(recognized.first { $0.text.contains("Following thread") }?.topDownY, "watch_topic row missing in:\n\(allText)")
        let notifyRowY = try XCTUnwrap(recognized.first { $0.text.contains("Sent notification") }?.topDownY, "notify row missing in:\n\(allText)")
        XCTAssertGreaterThan(noteCardY, stepsY, "Generic text ResultCard must render under Steps row")
        XCTAssertGreaterThan(listenRowY, noteCardY, "ListenRow must render under the preceding card")
        XCTAssertGreaterThan(watchRowY, listenRowY)
        XCTAssertGreaterThan(notifyRowY, watchRowY)
    }

    // MARK: - Helpers

    private struct Harness { let app: AppModel; let ai: CapabilityAIStub }

    private func makeHarness(gatedAI: Bool, notifier: WatchNotifier = WatchNotifier()) -> Harness {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = PersistentStore(fileURL: folder.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var seeded = AppSnapshot(); seeded.ensureForum(site); try? store.save(seeded)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CapabilityForumStub.self]
        let session = URLSession(configuration: config)
        let ai = CapabilityAIStub(); ai.gated = gatedAI
        let app = AppModel(
            store: store, forumService: ForumService(session: session, pacer: ForumRequestPacer(clock: InstantPacingClock())),
            aiService: ai, notifier: notifier,
            podcastDirectory: folder.appendingPathComponent("podcast", isDirectory: true),
            workspaceDirectory: folder.appendingPathComponent("workspace", isDirectory: true)
        )
        app.usesDirectForumRequests = true; app.browser.stopLoading(); app.browser.onPageContextChanged = nil
        app.settings.assistantModel = ModelSelection(provider: .ollama, model: "summary-model")
        var ollama = app.settings.configuration(for: .ollama); ollama.model = "summary-model"
        app.setConfiguration(ollama, for: .ollama)
        addTeardownBlock { @MainActor in
            for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
            app.podcast.cancelReadAloud(); ai.gated = false; ai.releaseAll(); session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: folder)
        }
        return Harness(app: app, ai: ai)
    }

    private func makeRegistry(_ app: AppModel) -> ToolRegistry {
        ToolRegistry.m3(context: AgentToolContext(bridge: FixturePageDriver(page: .init(url: site, title: "Stub")), workspace: app.agentWorkspace, scriptStore: app.scriptStore, capabilities: app.capabilityToolContext))
    }

    private func selectTopic(_ app: AppModel, id: String) {
        app.select(topic: ForumTopic(siteURL: site, topicID: id, url: URL(string: "\(site)/t/topic-\(id)/\(id)")!, title: "Topic \(id)"))
    }

    private func waitUntil(timeout: TimeInterval = 30, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for condition"); return }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private func renderRunsView(app: AppModel, session: BrowserAgentSession, scheme: SwiftUI.ColorScheme) async -> UIImage {
        let width: CGFloat = 390, style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        let rootView = BrowserAgentRunsView(app: app, session: session, expandedToolRowIDs: .constant([]))
            .padding(16).frame(width: width, alignment: .leading).background(DCTheme.ground)
            .environment(\.colorScheme, scheme).transaction { $0.disablesAnimations = true }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1_400))
        let host = UIHostingController(rootView: rootView)
        host.overrideUserInterfaceStyle = style; window.overrideUserInterfaceStyle = style
        window.rootViewController = host; window.frame = CGRect(x: 0, y: 0, width: width, height: 1_400)
        window.makeKeyAndVisible()
        host.beginAppearanceTransition(true, animated: false); host.endAppearanceTransition()
        defer {
            host.beginAppearanceTransition(false, animated: false); host.endAppearanceTransition()
            window.isHidden = true; window.rootViewController = nil; window.windowScene = nil
        }
        host.view.frame = window.bounds; window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        let height = max(400, ceil(host.sizeThatFits(in: CGSize(width: width, height: 4_000)).height) + 32)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height); host.view.frame = window.bounds; window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        return UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { ctx in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) { host.view.layer.render(in: ctx.cgContext) }
        }
    }

    private func recognizeLines(in image: CGImage) throws -> [(text: String, topDownY: CGFloat)] {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { obs in obs.topCandidates(1).first.map { ($0.string, 1.0 - obs.boundingBox.midY) } }
    }
}

private final class CapabilityAIStub: AIService, @unchecked Sendable {
    let inner = StateAIStub()
    @MainActor var lastDiscussion: DiscussionProfile?
    @MainActor var calls: [StateAIStub.Call] { inner.calls }
    @MainActor var waiting: Int { inner.waiting }
    @MainActor var gated: Bool { get { inner.gated } set { inner.gated = newValue } }
    @MainActor func releaseAll() { inner.releaseAll() }
    init() { super.init(session: .shared) }
    override func generateSummary(
        content: String, configuration: ProviderConfiguration, provider: AIProvider,
        customPrompt: String, discussion: DiscussionProfile, batchLimit: Int = SummaryBatchLimit.default,
        onDelta: @escaping @MainActor (String) -> Void, onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }
    ) async throws -> String {
        await MainActor.run { self.lastDiscussion = discussion }
        let base = try await inner.generateSummary(content: content, configuration: configuration, provider: provider, customPrompt: customPrompt, discussion: discussion, batchLimit: batchLimit, onDelta: onDelta, onProgress: onProgress)
        return "## Overview\n- \(base) #1"
    }
}

private final class NotificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    var status: UNAuthorizationStatus = .authorized, grantResult = true
    private(set) var promptCount = 0, requests: [UNNotificationRequest] = []
    var backend: WatchNotifier.NotificationBackend {
        WatchNotifier.NotificationBackend(
            authorizationStatus: { self.lock.withLock { self.status } },
            requestAuthorization: { self.lock.withLock { self.promptCount += 1; if self.grantResult { self.status = .authorized }; return self.grantResult } },
            add: { request in self.lock.withLock { self.requests.append(request) } }
        )
    }
}

@MainActor
private final class RecordingGatedSpeech: PodcastSpeechEngine {
    var gated = true
    var fileExtension: String { "wav" }
    private(set) var lastText = ""
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func synthesize(_ turns: [PodcastTurn], to url: URL) async throws -> TimeInterval {
        lastText = turns.map(\.text).joined(separator: " ")
        if gated { await withCheckedContinuation { continuation = $0 } }
        try Task.checkCancellation()
        try WAVFile.data(PCMAudio(samples: Data(count: 8_000 * 12 * 2), sampleRate: 8_000)).write(to: url)
        return 12.0
    }
}

private final class CapabilityForumStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var postCounts: [String: Int] = [:], queries: [String] = []
    static func reset() { lock.withLock { postCounts = [:]; queries = [] } }
    static func queryCount(_ pq: String) -> Int { lock.withLock { queries.filter { $0 == pq }.count } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url?.path ?? "", query = request.url?.query
        Self.lock.withLock { Self.queries.append(query.map { "\(path)?\($0)" } ?? path) }
        let (status, body) = Self.body(path: path, query: query)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    private static func body(path: String, query: String?) -> (Int, String) {
        if path == "/site/basic-info.json" { return (200, #"{"title":"Stub Forum"}"#) }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "t", parts[1].hasSuffix(".json") {
            let id = String(parts[1].dropLast(5)), total = lock.withLock { postCounts[id] } ?? 2
            return (200, #"{"title":"Topic \#(id)","slug":"topic-\#(id)","posts_count":\#(total)}"#)
        }
        if parts.count == 2, parts[0] == "raw" {
            let id = parts[1], total = lock.withLock { postCounts[id] } ?? 2
            let page = query?.split(separator: "=").last.flatMap { Int($0) } ?? 1
            let start = (page - 1) * 100 + 1
            guard start <= total else { return (200, "") }
            let posts = (start...min(total, page * 100)).map { "user\($0) | 2026-10-20 12:00:00 UTC | #\($0)\nBody of post \($0) in topic \(id)." }
            return (200, posts.joined(separator: "\n\n\n") + "\n")
        }
        return (404, "missing")
    }
}
