import SwiftUI
import XCTest
@testable import WukongMind

/// Measures the drawer on long threads (docs/wukongmind/design-performance-and-state.md).
///
/// It records, it does not assert on time: every number is printed as a
/// `PERF<tab>case<tab>metric<tab>value` line and attached as `drawer-perf.tsv`.
/// CI skips this suite (scripts/ci/run-tests.sh); run it on the Mac mini with
/// `scripts/remote-test.sh -only-testing:WukongMindTests/DrawerPerformanceTests`.
/// No network, no model: the thread, the summary and the conversation are generated here.
@MainActor
final class DrawerPerformanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PerfProbe.isEnabled = true
    }

    override func tearDown() {
        PerfProbe.isEnabled = false
        PerfProbe.reset()
        super.tearDown()
    }

    // MARK: Fixture

    struct Fixture {
        var name: String
        /// Posts in the pulled text (`TopicSession.source`); 0 leaves it empty.
        var sourcePosts = 0
        /// `##` sections in the saved summary (each has a paragraph and four cited bullets).
        var summarySections = 6
        /// Use a Chinese summary with `#N` citations (measures CJK cited-text layout and scrolling).
        var summaryChinese = false
        /// Finished Agent runs in the conversation (each: three tool rows and a Markdown reply).
        var runs = 0
        /// Posts in the thread shape the first tool row of every run carries; 0 for none.
        var shapePosts = 0
        /// Active run in progress with a running ToolRow (turning ring) and folded header while typing.
        var hasRunningRun = false
    }

    static let siteURL = "https://meta.discourse.org"
    static let topicID = "139139"

    static func post(_ number: Int) -> String {
        "Post #\(number) by user\(number % 97) (2026-11-\(String(format: "%02d", number % 28 + 1))):\n"
            // Real comments are not plain ASCII (curly quotes, dashes, the odd emoji): that is slower to copy and trim.
            + "I tried the workaround from the earlier reply on build \(number) and it doesn’t behave the same — "
            + "when the sidebar is collapsed. The header jumps by a few points, the avatar row wraps and the "
            + "composer loses focus after the first keystroke. Steps: open the topic, scroll to the middle, "
            + "rotate the phone, type one character. Expected: “nothing moves”. Actual: the list scrolls to the "
            + "top and the draft is cleared 😕. Logs are attached; the relevant line is `layout pass \(number * 7)`."
    }

    static func source(posts: Int) -> String {
        (1...max(posts, 1)).map(post).joined(separator: "\n\n")
    }

    static func summary(sections: Int, posts: Int) -> String {
        (1...max(sections, 1)).map { section -> String in
            let base = max(1, (section * max(posts, 40)) / (sections + 1))
            return """
            ## Theme \(section): layout jumps after rotation

            Several people report the same jump after rotating with the sidebar collapsed [#\(base)](wukongmind-post:\(base)), \
            and the first fix only helped on the newest build [#\(base + 1)](wukongmind-post:\(base + 1)).

            - The header moves by a few points when the avatar row wraps [#\(base + 2)](wukongmind-post:\(base + 2)).
            - The composer loses focus after the first keystroke, **only** on phones [#\(base + 3)](wukongmind-post:\(base + 3)).
            - A workaround is to pin the sidebar before rotating; it costs one tap [#\(base + 4)](wukongmind-post:\(base + 4)).
            - The maintainers asked for logs with `layout pass` lines [#\(base + 5)](wukongmind-post:\(base + 5)).
            """
        }.joined(separator: "\n\n")
    }

    static func chineseSummary(sections: Int, posts: Int) -> String {
        (1...max(sections, 1)).map { section -> String in
            let base = max(1, (section * max(posts, 40)) / (sections + 1))
            return """
            ## 主题 \(section)：旋转后界面跳动

            多位读者反馈在侧边栏收起时旋转屏幕会出现同样的跳动 [#\(base)](wukongmind-post:\(base))，\
            第一次修复只对最新版本有效 [#\(base + 1)](wukongmind-post:\(base + 1))。银行代表说条款在春季改过，但活动页面仍显示旧条款。

            - 头像行换行时，顶部标题会偏移几个点 [#\(base + 2)](wukongmind-post:\(base + 2))。
            - 输入框在敲下第一个字后会失去焦点，**仅限**手机端 [#\(base + 3)](wukongmind-post:\(base + 3))。
            - 临时办法是在旋转前固定侧边栏，只需多点一下 [#\(base + 4)](wukongmind-post:\(base + 4))。
            - 维护者希望能提供包含 `layout pass` 记录的日志 [#\(base + 5)](wukongmind-post:\(base + 5))。
            """
        }.joined(separator: "\n\n")
    }

    static func reply(_ index: Int) -> String {
        """
        Here is what the thread says about question \(index):

        1. The jump happens after rotation with the sidebar collapsed.
        2. Pinning the sidebar first avoids it, at the cost of one tap.
        3. The fix in the newest build covers phones but **not** tablets.

        The maintainers want logs with the `layout pass` lines before they look further. \
        If you only need the short version: pin the sidebar, then rotate.
        """
    }

    static func threadShape(posts: Int) -> ForumShape {
        .thread(ThreadShape(
            id: topicID,
            title: "Layout jumps after rotation",
            url: "\(siteURL)/t/layout-jumps-after-rotation/\(topicID)",
            posts: (1...posts).map { ThreadShape.Post(number: $0, author: "user\($0 % 97)", body: post($0)) },
            totalPosts: posts
        ))
    }

    /// The same ids every time, so a conversation that grows by one run keeps the earlier runs' identity.
    static func stableID(_ run: Int, _ part: Int) -> UUID {
        UUID(uuidString: String(format: "00000139-0000-4000-8000-%08d%04d", run, part))!
    }

    static let conversationStart = Date(timeIntervalSince1970: 1_795_000_000)

    static func conversation(runs count: Int, shapePosts: Int) -> SavedAgentConversation {
        let start = conversationStart
        var runs: [BrowserAgentRun] = []
        var messages: [BrowserAgentMessage] = []
        for index in 0..<count {
            let runID = stableID(index, 0)
            var rows = (1...3).map { step in
                BrowserAgentToolCallRow(
                    id: stableID(index, step), callID: "call_\(index)_\(step)", runID: runID, stepNumber: step,
                    toolName: step == 1 ? "read_topic" : "run_js",
                    argumentSummary: "page \(step)", argumentsJSON: "{\"page\":\(step)}",
                    resultSummary: "\(step * 20) posts",
                    resultText: (1...20).map { post($0 + step * 20) }.joined(separator: "\n\n"),
                    duration: 0.8, isRunning: false, isError: false, wasTruncated: false, totalCharacterCount: 12_000
                )
            }
            if shapePosts > 0 { rows[0].shape = threadShape(posts: shapePosts) }
            let startedAt = start.addingTimeInterval(Double(index) * 30)
            runs.append(BrowserAgentRun(
                id: runID, prompt: "What does the thread say about question \(index)?", toolCalls: rows,
                assistantText: reply(index), state: .completed(steps: 3, duration: 4.2),
                tokenUsage: AgentTokenUsage(inputTokens: 9_000, outputTokens: 300),
                startedAt: startedAt, duration: 4.2
            ))
            messages.append(BrowserAgentMessage(id: stableID(index, 8), role: .user, text: runs[index].prompt, runID: runID, createdAt: startedAt))
            messages.append(BrowserAgentMessage(id: stableID(index, 9), role: .assistant, text: reply(index), runID: runID, createdAt: startedAt.addingTimeInterval(4)))
        }
        return SavedAgentConversation(
            messages: messages, runs: runs, toolCalls: runs.flatMap(\.toolCalls),
            runState: count == 0 ? .idle : .completed(steps: 3, duration: 4.2),
            tokenUsage: AgentTokenUsage(inputTokens: 9_000 * count, outputTokens: 300 * count), history: []
        )
    }

    /// Also used by `DrawerRenderCountTests` (always on in CI).
    static func makeApp(_ fixture: Fixture) -> AppModel {
        let store = PersistentStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("state.json")
        )
        let app = AppModel(store: store)
        // The view cost only: saving is timed by itself in `testHotFunctionsScaleWithThreadLength`.
        app.suppressesPersistence = true
        let forum = Forum(siteURL: Self.siteURL, kind: .discourse, name: "Discourse Meta", isPinned: true, pinOrder: 0)
        let topic = ForumTopic(
            siteURL: Self.siteURL, topicID: Self.topicID,
            url: URL(string: "\(Self.siteURL)/t/layout-jumps-after-rotation/\(Self.topicID)")!,
            title: "Layout jumps after rotation"
        )
        var session = TopicSession(siteURL: topic.siteURL, topicID: topic.topicID, url: topic.url, title: topic.title)
        if fixture.sourcePosts > 0 { session.seedSource(Self.source(posts: fixture.sourcePosts)) }
        session.summary = fixture.summaryChinese
            ? Self.chineseSummary(sections: fixture.summarySections, posts: fixture.sourcePosts)
            : Self.summary(sections: fixture.summarySections, posts: fixture.sourcePosts)
        session.totalPosts = max(fixture.sourcePosts, 40)
        session.summaryPostCount = session.totalPosts
        session.model = "claude-haiku-5-5"
        session.summaryUpdatedAt = Date().addingTimeInterval(-600)
        app.applyDebugSeed(AssistantDebugSeed(
            forums: [forum], sessions: [session], activities: [], agentRuns: [], watchedTopics: [],
            currentTopic: topic, currentForum: forum,
            pageContext: PageContext(
                url: topic.url, site: .discourse, siteURL: forum.siteURL, forumName: forum.name, topic: topic, state: .topic
            )
        ))
        if fixture.runs > 0 {
            app.browserAgent.restoreConversation(Self.conversation(runs: fixture.runs, shapePosts: fixture.shapePosts))
        }
        if fixture.hasRunningRun {
            app.selectModel(ModelSelection(provider: .ollama, model: "llama3.1"), for: .role(.browserAgent))
            let client = RecordedModelClient([
                .success(AgentModelTurnResponse(
                    text: "",
                    toolCalls: [AgentModelToolCall(id: "running_1", name: "wait_for", arguments: ["ms": .int(60_000)])],
                    usage: AgentTokenUsage(inputTokens: 1_000, outputTokens: 40)
                )),
                .success(AgentModelTurnResponse(text: "Done.", usage: AgentTokenUsage(inputTokens: 1_000, outputTokens: 20)))
            ])
            app.browserAgent.configureDebugModelClient(client)
            app.browserAgent.send("Check this thread")
            let deadline = Date().addingTimeInterval(3)
            while !(app.browserAgent.isRunning && app.browserAgent.toolCalls.contains(where: \.isRunning)), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        return app
    }

    // MARK: Meter

    /// Main-thread time spent working (not waiting) while the run loop spins.
    private final class BusyMeter {
        private(set) var busy: Double = 0
        private var startedAt: UInt64?
        private var observers: [CFRunLoopObserver] = []

        init() {
            // Waking is seen first and going to sleep last, so the work other observers do
            // before the loop sleeps (Core Animation's commit, where SwiftUI updates and lays
            // out) is counted.
            let wake: CFRunLoopActivity = [.entry, .afterWaiting]
            let sleep: CFRunLoopActivity = [.beforeWaiting, .exit]
            observers = [
                CFRunLoopObserverCreateWithHandler(nil, wake.rawValue, true, CFIndex.min) { [weak self] _, _ in
                    guard let self, self.startedAt == nil else { return }
                    self.startedAt = DispatchTime.now().uptimeNanoseconds
                },
                CFRunLoopObserverCreateWithHandler(nil, sleep.rawValue, true, CFIndex.max) { [weak self] _, _ in
                    guard let self, let start = self.startedAt else { return }
                    self.busy += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                    self.startedAt = nil
                }
            ].compactMap { $0 }
            observers.forEach { CFRunLoopAddObserver(CFRunLoopGetMain(), $0, .commonModes) }
        }

        deinit {
            observers.forEach { CFRunLoopRemoveObserver(CFRunLoopGetMain(), $0, .commonModes) }
        }
    }

    /// Runs `action`, then lets the run loop settle; returns the main-thread milliseconds both took.
    private func mainThreadMilliseconds(settle: TimeInterval = 0.12, _ action: () -> Void) -> Double {
        let meter = BusyMeter()
        let start = DispatchTime.now().uptimeNanoseconds
        action()
        CATransaction.flush()
        let sync = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        return (sync + meter.busy) * 1_000
    }

    private var lines: [String] = []

    private func record(_ fixture: String, _ metric: String, _ value: Double) {
        let line = "PERF\t\(fixture)\t\(metric)\t\(String(format: "%.3f", value))"
        lines.append(line)
        print(line)
    }

    private func recordSamples(_ fixture: String, _ metric: String, _ samples: [Double]) {
        guard !samples.isEmpty else { return }
        record(fixture, "\(metric)_min_ms", samples.min() ?? 0)
        record(fixture, "\(metric)_median_ms", median(samples))
        record(fixture, "\(metric)_max_ms", samples.max() ?? 0)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private func attachLines(named name: String) {
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    static func descendants<T: UIView>(of view: UIView, as type: T.Type) -> [T] {
        var found: [T] = []
        func walk(_ view: UIView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    // MARK: The drawer, hosted

    private func measureDrawer(_ fixture: Fixture) {
        let app = Self.makeApp(fixture)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer {
            if fixture.hasRunningRun {
                app.browserAgent.stop()
                NotificationCenter.default.post(
                    name: UIResponder.keyboardWillHideNotification,
                    object: nil,
                    userInfo: [UIResponder.keyboardIsLocalUserInfoKey: true]
                )
            }
            window.isHidden = true
            window.rootViewController = nil
        }

        // Open: mount the panel as the drawer does and lay out its first frame.
        PerfProbe.reset()
        var host: UIHostingController<AnyView>!
        let open = mainThreadMilliseconds(settle: 0.6) {
            host = UIHostingController(rootView: AnyView(
                AssistantPanel(app: app, onExpand: { _ in }).environment(\.colorScheme, .light)
            ))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
        }
        record(fixture.name, "open_ms", open)
        let openProbe = PerfProbe.snapshot
        record(fixture.name, "open_block_bodies", Double(openProbe.counts["MarkdownBlockView.body"] ?? 0))
        record(fixture.name, "open_run_sections", Double(openProbe.counts["BrowserAgentRunsView.runSection"] ?? 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        // What the meter reads when nothing is asked of the drawer (timers, the caret).
        recordSamples(fixture.name, "idle", (0..<6).map { _ in mainThreadMilliseconds {} })

        // Typing: one character at a time into the composer's own text view.
        let editor = Self.descendants(of: host.view, as: UITextView.self).first
        let field = Self.descendants(of: host.view, as: UITextField.self).first
        XCTAssertTrue(editor != nil || field != nil, "The composer's text input was not found")
        if fixture.hasRunningRun {
            XCTAssertTrue(app.browserAgent.isRunning, "Running fixture did not start a run")
            XCTAssertTrue(app.browserAgent.toolCalls.contains(where: \.isRunning), "Running fixture has no running tool row")
            _ = editor?.becomeFirstResponder() ?? field?.becomeFirstResponder()
            NotificationCenter.default.post(
                name: UIResponder.keyboardWillShowNotification,
                object: nil,
                userInfo: [UIResponder.keyboardIsLocalUserInfoKey: true]
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        var keystrokes: [Double] = []
        PerfProbe.reset()
        let typed = 12
        for index in 0..<typed {
            let character = String(UnicodeScalar(UInt8(97 + index % 26)))
            keystrokes.append(mainThreadMilliseconds {
                if let editor { editor.insertText(character) } else { field?.insertText(character) }
            })
        }
        let typing = PerfProbe.snapshot
        XCTAssertGreaterThan(typing.counts["AssistantComposer.body"] ?? 0, 0, "Typing did not reach the composer")
        // The first keystroke also hides the suggestion row; the rest are the steady state.
        record(fixture.name, "key_first_ms", keystrokes[0])
        recordSamples(fixture.name, "key", Array(keystrokes.dropFirst()))
        for name in [
            "AssistantPanel.body", "ChatThread.body", "BrowserAgentRunsView.body", "BrowserAgentRunsView.runSection",
            "DrawerSummarySections.body", "MarkdownView.body", "MarkdownBlockView.body", "AssistantComposer.body"
        ] {
            record(fixture.name, "per_key_count:\(name)", Double(typing.counts[name] ?? 0) / Double(typed))
        }
        for name in [
            "AssistantPanel.buildHeader", "AssistantPanel.buildThread", "AssistantPanel.buildFooter",
            "AssistantPanel.exportText", "AssistantPanel.exportDisabled", "TopicExportPayload.text", "DrawerSummarySections.parsed", "AssistantPanel.summaryPlacement",
            "AssistantPanel.strippedSummary", "BrowserAgentRunsView.timeline", "BrowserAgentRunsView.forumSources"
        ] {
            record(fixture.name, "per_key_ms:\(name)", (typing.seconds[name] ?? 0) * 1_000 / Double(typed))
            record(fixture.name, "per_key_calls:\(name)", Double(typing.counts[name] ?? 0) / Double(typed))
        }

        // An AppModel publish that has nothing to do with the drawer (any @Published does this).
        PerfProbe.reset()
        var publishes: [Double] = []
        for index in 0..<6 {
            publishes.append(mainThreadMilliseconds { app.discoveredModels = [.openAI: [DiscoveredModel(id: "tick \(index)")]] })
        }
        let publishing = PerfProbe.snapshot
        recordSamples(fixture.name, "unrelated_publish", publishes)
        record(fixture.name, "per_publish_count:AssistantPanel.body", Double(publishing.counts["AssistantPanel.body"] ?? 0) / 6)
        record(fixture.name, "per_publish_count:BrowserAgentRunsView.runSection", Double(publishing.counts["BrowserAgentRunsView.runSection"] ?? 0) / 6)

        // Scrolling: 300 pt steps down the transcript.
        let scrollViews = Self.descendants(of: host.view, as: UIScrollView.self).filter { !($0 is UITextView) }
        let mainScroll = scrollViews.max(by: { $0.contentSize.height < $1.contentSize.height })
        var lastScrollOffset: CGFloat = 0
        if let scroll = mainScroll {
            record(fixture.name, "content_height_pt", Double(scroll.contentSize.height))
            var steps: [Double] = []
            let limit = max(0, scroll.contentSize.height - scroll.bounds.height)
            var offset: CGFloat = 0
            while offset < limit, steps.count < 40 {
                offset = min(limit, offset + 300)
                steps.append(mainThreadMilliseconds(settle: 0.03) {
                    scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    scroll.layoutIfNeeded()
                })
            }
            lastScrollOffset = offset
            if !steps.isEmpty {
                recordSamples(fixture.name, "scroll_step", steps)
                record(fixture.name, "scroll_steps_over_16ms", Double(steps.filter { $0 > 16.7 }.count))
                record(fixture.name, "scroll_steps", Double(steps.count))
            }
        }

        // One more finished run arrives in the conversation (stand-in: restoreConversation).
        if fixture.runs > 0 {
            let grown = Self.conversation(runs: fixture.runs + 1, shapePosts: fixture.shapePosts)
            record(fixture.name, "new_run_ms", mainThreadMilliseconds(settle: 0.3) {
                app.browserAgent.restoreConversation(grown)
            })

            // Real path: one more run appended by `send` through a recorded model client.
            let cleanupDeadline = Date().addingTimeInterval(2)
            while ChatScrollProbe.isSettling, Date() < cleanupDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            app.selectModel(ModelSelection(provider: .ollama, model: "llama3.1"), for: .role(.browserAgent))
            app.browserAgent.restoreConversation(Self.conversation(runs: fixture.runs, shapePosts: fixture.shapePosts))
            host.view.layoutIfNeeded()
            if let scroll = mainScroll {
                let clamp = max(0, min(lastScrollOffset, scroll.contentSize.height - scroll.bounds.height))
                scroll.setContentOffset(CGPoint(x: 0, y: clamp), animated: false)
                scroll.layoutIfNeeded()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))

            let nextIndex = fixture.runs
            let toolTurns = (1...3).map { step -> Result<AgentModelTurnResponse, Error> in
                .success(AgentModelTurnResponse(
                    text: "", toolCalls: [AgentModelToolCall(id: "send_\(nextIndex)_\(step)", name: "wait_for", arguments: ["ms": .int(1)])],
                    usage: AgentTokenUsage(inputTokens: 9_000, outputTokens: 80)
                ))
            }
            let client = RecordedModelClient(toolTurns + [
                .success(AgentModelTurnResponse(text: Self.reply(nextIndex), usage: AgentTokenUsage(inputTokens: 9_000, outputTokens: 300)))
            ])
            app.browserAgent.configureDebugModelClient(client)

            PerfProbe.reset()
            let sendMs = sendRunMilliseconds(app: app, prompt: "What does the thread say about question \(nextIndex)?")
            let sendProbe = PerfProbe.snapshot
            XCTAssertEqual(app.browserAgent.runs.count, fixture.runs + 1, "Recorded send did not append a run")
            XCTAssertFalse(app.browserAgent.isRunning, "Recorded send did not finish")
            record(fixture.name, "send_run_ms", sendMs)
            record(fixture.name, "send_run_sections", Double(sendProbe.counts["BrowserAgentRunsView.runSection"] ?? 0))
            record(fixture.name, "send_block_bodies", Double(sendProbe.counts["MarkdownBlockView.body"] ?? 0))
        }
    }

    /// Runs a prompt through `browserAgent.send` and spins the main run loop until both the turn
    /// and the transcript's settle-to-bottom task finish; returns main-thread busy milliseconds.
    private func sendRunMilliseconds(app: AppModel, prompt: String) -> Double {
        let meter = BusyMeter()
        let start = DispatchTime.now().uptimeNanoseconds
        app.browserAgent.send(prompt)
        CATransaction.flush()
        let sync = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let deadline = Date().addingTimeInterval(5.0)
        while (app.browserAgent.isRunning || ChatScrollProbe.isSettling), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return (sync + meter.busy) * 1_000
    }

    /// The composer by itself, its draft in a small view of its own: what a keystroke costs
    /// when nothing else is invalidated (the target for the isolated input).
    private struct ComposerOnly: View {
        @State private var draft = ""
        @FocusState private var focused: Bool

        var body: some View {
            VStack {
                Spacer()
                AssistantComposer(draft: $draft, focused: $focused, isRunning: false, onSend: {}, onStop: {})
                    .padding(14)
            }
        }
    }

    private func measureComposerOnly() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let host = UIHostingController(rootView: ComposerOnly())
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let editor = Self.descendants(of: host.view, as: UITextView.self).first
        let field = Self.descendants(of: host.view, as: UITextField.self).first
        XCTAssertTrue(editor != nil || field != nil, "The composer's text input was not found")
        PerfProbe.reset()
        var keystrokes: [Double] = []
        for index in 0..<12 {
            let character = String(UnicodeScalar(UInt8(97 + index % 26)))
            keystrokes.append(mainThreadMilliseconds {
                if let editor { editor.insertText(character) } else { field?.insertText(character) }
            })
        }
        XCTAssertGreaterThan(PerfProbe.snapshot.counts["AssistantComposer.body"] ?? 0, 0, "Typing did not reach the composer")
        record("composer-only", "key_first_ms", keystrokes[0])
        recordSamples("composer-only", "key", Array(keystrokes.dropFirst()))
    }

    func testDrawerOnLongThreads() {
        let fixtures = [
            Fixture(name: "baseline"),
            Fixture(name: "running", hasRunningRun: true),
            Fixture(name: "source-100", sourcePosts: 100),
            Fixture(name: "source-500", sourcePosts: 500),
            Fixture(name: "source-2000", sourcePosts: 2_000),
            // The owner's real case has 6,184 comments (doctorofcredit.com/citi-300-checking-bonus).
            Fixture(name: "source-6000", sourcePosts: 6_000),
            Fixture(name: "summary-15", summarySections: 15),
            Fixture(name: "summary-30", summarySections: 30),
            Fixture(name: "summary-30-zh", summarySections: 30, summaryChinese: true),
            Fixture(name: "summary-60", summarySections: 60),
            Fixture(name: "runs-5", runs: 5),
            Fixture(name: "runs-20", runs: 20),
            Fixture(name: "runs-60", runs: 60),
            Fixture(name: "runs-5-shape-500", runs: 5, shapePosts: 500),
            Fixture(name: "runs-5-shape-2000", runs: 5, shapePosts: 2_000),
            Fixture(name: "all-2000", sourcePosts: 2_000, summarySections: 30, runs: 20, shapePosts: 2_000),
            Fixture(name: "all-6000", sourcePosts: 6_000, summarySections: 30, runs: 20, shapePosts: 2_000)
        ]
        // Warm up SwiftUI, fonts and the Markdown caches so the first fixture is not charged for them.
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        measureDrawer(Fixture(name: "warmup", runs: 1))
        lines.removeAll()
        measureComposerOnly()
        for fixture in fixtures {
            measureDrawer(fixture)
        }
        attachLines(named: "drawer-perf.tsv")
    }

    // MARK: Hot functions by themselves

    private func milliseconds(repeating count: Int = 5, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<count {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return median(samples)
    }

    func testHotFunctionsScaleWithThreadLength() throws {
        for posts in [100, 500, 2_000, 6_000] {
            let name = "posts-\(posts)"
            let source = Self.source(posts: posts)
            let summary = Self.summary(sections: 30, posts: posts)
            record(name, "source_characters", Double(source.count))
            let payload = TopicExportPayload(
                summary: summary, source: source, title: "Layout jumps after rotation",
                url: URL(string: Self.siteURL), history: []
            )
            var sink = 0
            record(name, "export_text_ms", milliseconds { sink &+= payload.text(options: ExportOptions()).utf8.count })

            let conversation = Self.conversation(runs: 5, shapePosts: posts)
            let other = Self.conversation(runs: 5, shapePosts: posts)
            record(name, "runs_equal_ms", milliseconds { sink &+= conversation.runs == conversation.runs ? 1 : 0 })
            record(name, "runs_differ_ms", milliseconds { sink &+= conversation.runs == other.runs ? 1 : 0 })
            let encoder = JSONEncoder()
            var bytes = 0
            record(name, "conversation_encode_ms", milliseconds(repeating: 3) {
                bytes = (try? encoder.encode(conversation))?.count ?? 0
            })
            record(name, "conversation_bytes", Double(bytes))

            var session = TopicSession(
                siteURL: Self.siteURL, topicID: Self.topicID,
                url: URL(string: "\(Self.siteURL)/t/x/\(Self.topicID)")!, title: "Layout jumps after rotation"
            )
            session.seedSource(source)
            session.summary = summary
            var snapshot = AppSnapshot()
            snapshot.sessions = [session]
            record(name, "snapshot_encode_ms", milliseconds(repeating: 3) {
                bytes = (try? encoder.encode(snapshot))?.count ?? 0
            })
            record(name, "snapshot_bytes", Double(bytes))
            XCTAssertGreaterThan(sink, 0)
        }
        for sections in [6, 15, 30, 60] {
            let name = "summary-\(sections)"
            let summary = Self.summary(sections: sections, posts: 2_000)
            record(name, "summary_characters", Double(summary.count))
            // Every pass is a new string, as a body pass sees after the caches turn over.
            var pass = 0
            record(name, "summary_parse_cold_ms", milliseconds(repeating: 3) {
                pass += 1
                _ = DrawerSummarySections.parsed(for: .init(text: summary + "\n\nPass \(pass).", maximumPost: 2_000))
            })
            _ = DrawerSummarySections.parsed(for: .init(text: summary, maximumPost: 2_000))
            record(name, "summary_parse_warm_ms", milliseconds {
                _ = DrawerSummarySections.parsed(for: .init(text: summary, maximumPost: 2_000))
            })
            record(name, "summary_strip_ms", milliseconds { _ = PostCitations.stripped(summary) })
        }
        attachLines(named: "hot-functions.tsv")
    }

    /// Cold start (docs/wukongmind/design-performance-2.md): `AppModel.init` calls `PersistentStore.load()` on
    /// the main thread and restores every tab's conversation. What that costs as saved threads grow,
    /// on generated state in a temporary folder (never the app's own).
    func testStateLoadScalesWithSavedThreads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (threads, posts) in [(1, 100), (40, 100), (1, 6_000), (5, 6_000), (20, 6_000)] {
            let name = "state-\(threads)x\(posts)"
            let source = Self.source(posts: posts)
            let summary = Self.summary(sections: 8, posts: posts)
            var snapshot = AppSnapshot()
            snapshot.sessions = (0..<threads).map { index in
                var session = TopicSession(
                    siteURL: Self.siteURL, topicID: "\(index)",
                    url: URL(string: "\(Self.siteURL)/t/x/\(index)")!, title: "Thread \(index)"
                )
                session.seedSource(source)
                session.summary = summary
                return session
            }
            let fileURL = directory.appendingPathComponent("\(name).json")
            let store = PersistentStore(fileURL: fileURL)
            record(name, "save_ms", milliseconds(repeating: 1) { try? store.save(snapshot) })
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber
            record(name, "state_bytes", size?.doubleValue ?? 0)
            var loaded = 0
            record(name, "load_ms", milliseconds(repeating: 3) {
                loaded = PersistentStore(fileURL: fileURL).load().sessions.count
            })
            XCTAssertEqual(loaded, threads)
            try? FileManager.default.removeItem(at: fileURL)
        }
        for posts in [500, 6_000] {
            let name = "conversation-5x\(posts)"
            let data = try JSONEncoder().encode(Self.conversation(runs: 5, shapePosts: posts))
            record(name, "conversation_bytes", Double(data.count))
            var runs = 0
            record(name, "conversation_decode_ms", milliseconds(repeating: 3) {
                runs = (try? JSONDecoder().decode(SavedAgentConversation.self, from: data))?.runs.count ?? 0
            })
            XCTAssertEqual(runs, 5)
        }
        attachLines(named: "state-load.tsv")
    }

    /// Captures PNG snapshots of a cited paragraph and cited bullets in English and Chinese
    /// for before/after visual verification (docs/wukongmind/design-performance-2.md task 4).
    func testCaptureCitedParagraphSnapshots() {
        let samples: [(name: String, markdown: String)] = [
            ("cited-paragraph-en", Self.summary(sections: 1, posts: 40)),
            ("cited-paragraph-zh", Self.chineseSummary(sections: 1, posts: 40))
        ]
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let width: CGFloat = 390
        for sample in samples {
            let rows = DrawerSummarySections.parsed(for: .init(text: sample.markdown, maximumPost: 40)).rows
            let content = VStack(alignment: .leading, spacing: 8) {
                DrawerSummarySections(rows: rows, layout: .singleColumn)
            }
            .padding(16)
            .frame(width: width, alignment: .leading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)

            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 600))
            let host = UIHostingController(rootView: content)
            window.rootViewController = host
            window.frame = CGRect(x: 0, y: 0, width: width, height: 600)
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            let fitted = host.sizeThatFits(in: CGSize(width: width, height: 2_000))
            let height = max(120, ceil(fitted.height))
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()

            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { ctx in
                host.view.layer.render(in: ctx.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = sample.name
            attachment.lifetime = .keepAlways
            add(attachment)

            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// Measures HomeView's hosted first-frame time (empty and populated) for before/after
    /// comparison when Home changes (docs/wukongmind/app-store-review.md tasks 11 and 12).
    func testHomeFirstFramePerformance() {
        let actions = BrowserActions(
            showLoginInfo: {},
            addForum: {},
            openForum: { _ in },
            showForumsHome: {}
        )
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        func measureHome(name: String, configure: (AppModel) -> Void) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("home-perf-\(name)-\(UUID().uuidString)", isDirectory: true)
            let store = PersistentStore(
                fileURL: directory.appendingPathComponent("state.json"),
                keys: InMemoryProviderKeyStore()
            )
            let app = AppModel(
                store: store,
                cloudSync: CloudSyncController(transport: nil, files: nil, defaults: nil, schedulesAutomatically: false),
                podcastDirectory: directory.appendingPathComponent("Podcasts", isDirectory: true),
                workspaceDirectory: directory.appendingPathComponent("Workspace", isDirectory: true),
                spotlightIndex: FakeSpotlightIndex(),
                topicActivityDonor: FakeTopicActivityDonor()
            )
            app.siteVisits.hidesVisits = true
            configure(app)
            defer { try? FileManager.default.removeItem(at: directory) }

            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }

            // Warm-up pass (not recorded) to eliminate one-time SwiftUI/UIKit lazy initialization.
            do {
                let warm = UIHostingController(rootView: AnyView(
                    NavigationStack { HomeView(app: app, isEditingAddress: false, currentURL: nil, actions: actions) }.environment(\.colorScheme, .light)
                ))
                window.rootViewController = warm
                window.makeKeyAndVisible()
                warm.view.layoutIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                window.rootViewController = nil
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }

            var samples: [Double] = []
            for _ in 0..<6 {
                var host: UIHostingController<AnyView>!
                let elapsed = mainThreadMilliseconds(settle: 0.25) {
                    host = UIHostingController(rootView: AnyView(
                        NavigationStack { HomeView(app: app, isEditingAddress: false, currentURL: nil, actions: actions) }.environment(\.colorScheme, .light)
                    ))
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    host.view.layoutIfNeeded()
                }
                samples.append(elapsed)
                window.rootViewController = nil
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            recordSamples(name, "first_frame", samples)
        }

        measureHome(name: "home-empty") { _ in }
        measureHome(name: "home-populated") { app in
            for i in 1...6 {
                app.pin(Forum(siteURL: "https://site\(i).example.org", kind: .discourse, name: "Site \(i)"))
            }
        }
        attachLines(named: "home-perf.tsv")
    }
}
