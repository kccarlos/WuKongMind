import Foundation

/// What the voice layer needs from the app: the navigation layer
/// (AppModel+Navigation.swift), the hand-off to the Agent, and a few reads
/// for the silent context. AppModel conforms (AppModel+Voice.swift); tests
/// use a fake.
@MainActor
protocol VoiceNavigator: AnyObject {
    var pageContext: PageContext { get }
    var pageTitle: String? { get }
    var browseCursor: BrowseCursor { get }
    /// The words and tool options of the site the current page is on.
    var voiceSite: VoiceSite { get }

    func find(_ query: String, scope: BrowseSearchScope) async -> BrowseResult
    func openPage(_ target: String) async -> VoiceOpenResult
    func pageLinks() async -> [PageLink]
    func followLink(_ link: PageLink) async -> VoiceOpenResult
    var linkPageIdentity: String { get }
    func openTopic(_ target: BrowseTarget, at landing: BrowseLanding, includeContent: Bool) async -> BrowseResult
    func openCard(_ index: Int, includeContent: Bool) async -> BrowseResult
    func goToPost(_ number: Int) async -> BrowseResult
    func next() async -> BrowseResult
    func previous() async -> BrowseResult
    func back() -> BrowseResult
    func forward() -> BrowseResult
    func scrollPage(_ direction: VoicePageScroll) async -> BrowseResult
    func focus(_ focus: BrowseFocus) async -> BrowseResult
    func read(post: Int?) async -> BrowseResult
    /// The text of every post on screen.
    func readVisible() async -> BrowseResult

    /// A hand-off run is going.
    var isHandingOff: Bool { get }
    /// Sends `request` to the Agent as a voice run (`hand_off_to_agent`); nil
    /// once a run has started, else why none did.
    func startHandOff(_ request: String) -> String?
    /// Waits for the hand-off run to end.
    func handOffOutcome() async -> VoiceHandOffOutcome
    /// Stops the hand-off run ("never mind"); false when none runs.
    func cancelHandOff() -> Bool
    /// The hand-off run's latest step, in English ("Step 2, read_topic 42");
    /// nil when none runs.
    var handOffProgress: String? { get }

    /// The open topic's facts for the topic brief; nil off topics.
    func voiceTopicBrief() async -> VoiceTopicBrief?
    /// Posts in the viewport with their first lines.
    func postsOnScreen() async -> [VisiblePost]
    /// A quick summary of the open topic from the summary pipeline, when it
    /// has no saved one; nil when it can't be made.
    func quickSummary(topicKey: String) async -> String?
}

extension VoiceNavigator {
    var pageTitle: String? {
        guard let title = pageContext.topic?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        return title
    }

    var linkPageIdentity: String {
        VoiceLinkState.pageKey(url: nil, page: pageContext)
    }
}

/// Where `browse_move` scrolls on an ordinary page (or a forum page without an open topic).
enum VoicePageScroll: String, Equatable { case top, bottom, down, up }

/// What `open_page` or `open_link` did, turned into a spoken function response.
enum VoiceOpenResult: Equatable {
    enum Kind: String, Equatable { case address, site, search, link }
    struct Candidate: Equatable { var name: String; var host: String }

    case opened(kind: Kind, title: String?, host: String, siteName: String? = nil, query: String? = nil, previousHost: String? = nil, loading: Bool = false)
    case choices(target: String, candidates: [Candidate])
    case linkChoices(words: String, candidates: [Candidate])
    case linkNotFound(String)
    case refused(String)
    case failed(String)
}

/// How a hand-off run ended.
enum VoiceHandOffOutcome: Equatable {
    case answered(String)
    case cancelled
    case failed(String)
}

/// Sends spoken requests to the Agent like typed ones (origin voice), one
/// at a time: a newer hand-off replaces the running one, and a run the user
/// typed is never stopped for one.
@MainActor
final class AgentHandOff {
    let agent: BrowserAgentSession
    private(set) var runID: UUID?

    init(agent: BrowserAgentSession) {
        self.agent = agent
    }

    private var run: BrowserAgentRun? {
        runID.flatMap { id in agent.runs.first { $0.id == id } }
    }

    var isRunning: Bool { run?.state.isRunning == true }

    /// Nil once a run has started, else why none did.
    func start(_ request: String) -> String? {
        if agent.isRunning {
            guard isRunning else { return "The Agent is busy with another request. Try again when it's done." }
            agent.stop()
        }
        let before = agent.runs.last?.id
        agent.send(request, origin: .voice)
        guard agent.isRunning, let run = agent.runs.last, run.id != before else {
            if case .failed(let message) = agent.runState { return message }
            return "The Agent couldn't start."
        }
        runID = run.id
        return nil
    }

    /// Waits for the hand-off run to end and says how.
    func outcome() async -> VoiceHandOffOutcome {
        guard let id = runID else { return .failed("No hand-off is running.") }
        await agent.waitForActiveRun()
        guard let run = agent.runs.first(where: { $0.id == id }) else { return .cancelled }
        if runID == id, !run.state.isRunning { runID = nil }
        switch run.state {
        case .completed:
            let text = run.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .failed("The Agent finished without an answer.") : .answered(text)
        case .stopped, .idle, .running:
            return .cancelled
        case .stepLimitReached(let limit):
            return .failed("The Agent stopped after \(limit) steps without finishing. Continue is in the panel.")
        case .failed(let message):
            return .failed(message)
        }
    }

    /// "Never mind": Stop. False when no hand-off runs.
    func cancel() -> Bool {
        guard isRunning else { return false }
        agent.stop()
        runID = nil
        return true
    }

    /// The run's latest step ("Step 2, read_topic topic 42").
    var progress: String? {
        guard let run, run.state.isRunning, let step = run.toolCalls.last else { return nil }
        let detail = step.argumentSummary.isEmpty ? "" : " \(step.argumentSummary)"
        return BrowseText.oneLine("Step \(run.toolCalls.count), \(step.toolName)\(detail)", limit: 200)
    }
}

/// What a tool call produced.
struct VoiceToolOutcome: Equatable {
    enum Effect: Equatable {
        case none
        /// A hand-off started: the session watches for an acknowledgement.
        case handOffStarted
        /// End the session after the goodbye.
        case end
    }

    var response: [String: JSONValue]
    var scheduling: GeminiLive.Scheduling
    var effect: Effect = .none
}

/// A message for the model that answers no call of its own: a function
/// response under a made-up id and the name `briefing`, so every
/// scheduling mode works for it (a user-role turn would read as the user
/// speaking).
struct VoiceBriefing: Equatable {
    static let name = "briefing"

    enum Kind: String {
        case handOffProgress = "agent progress"
        case handOffAnswer = "agent answer"
        case handOffEnded = "agent ended"
        case context
    }

    var kind: Kind
    var facts: [String: JSONValue]
    var scheduling: GeminiLive.Scheduling
    /// Text to re-send as a turn if the model doesn't voice it in time.
    var spokenText: String?
}

/// Runs the voice session's tools through the registry (`.voice` tools),
/// plus `end` and `hand_off_to_agent`, and turns each result into a
/// function response: `status`, `shown`, `content`, `hits`, and a `message`
/// telling the model what to say next, capped at 8,000 characters.
@MainActor
final class VoiceToolBridge {
    /// Shown when a forum-only tool is called on an ordinary page or Home.
    nonisolated static let notForumMessage = "This page isn't a forum. Use read_page for what is on it, or hand the request off."
    /// Shown when `open_page` or `open_link` is called while a voice hand-off is running on the page.
    nonisolated static let handOffBusyMessage = "The Agent is still working on this page. Say never mind to stop it."
    /// Shown when `open_link` is given a number from a candidate list of a previous page.
    nonisolated static let staleLinkListMessage = "That link list was from the previous page. Name the link you want on this page."
    static let forumOnlyTools: Set<String> = [
        ForumToolName.searchForum, BrowseToolName.open, BrowseToolName.focus,
        BrowseToolName.readPost, ForumToolName.readTopic, "watch_topic"
    ]

    weak var navigator: VoiceNavigator?
    let linkState = VoiceLinkState()
    /// Where hand-off briefings go (the session).
    var onBriefing: ((VoiceBriefing) -> Void)?
    /// How often a running hand-off is checked for progress.
    var progressInterval: Duration = .seconds(2)
    /// The voice registry for the page as it is now (AppModel); without
    /// one, the browse tools alone.
    var registryBuilder: ((BrowseToolContext) -> ToolRegistry)?
    /// The names the session declared when it connected; a call outside them
    /// is refused, even after a resume (spike Q2). Nil until declared.
    private(set) var declaredNames: Set<String>?
    private(set) var declarations: [GeminiLive.FunctionDeclaration] = []
    private var handOffTask: Task<Void, Never>?
    private var handOffSequence = 0

    init(navigator: VoiceNavigator?) {
        self.navigator = navigator
    }

    /// Fixes the session's tools (one neutral set on every page) and returns
    /// their declarations.
    func declare(for _: VoiceSite = SiteRegistry.standard.voiceFallback) -> [GeminiLive.FunctionDeclaration] {
        let (_, registry) = makeRegistry(eyesFree: false)
        declarations = VoiceDeclarations.all(registry: registry)
        declaredNames = Set(declarations.map(\.name))
        return declarations
    }

    func handle(_ call: GeminiLive.FunctionCall, eyesFree: Bool) async -> VoiceToolOutcome {
        if let declaredNames, !declaredNames.contains(call.name) {
            return refusal("There is no tool called \(call.name).")
        }
        if let tool = VoiceTool(rawValue: call.name) {
            switch tool {
            case .end:
                return VoiceToolOutcome(
                    response: ["status": "ending", "message": "The conversation ends once your goodbye has played. Say nothing more."],
                    scheduling: tool.scheduling,
                    effect: .end
                )
            case .handOffToAgent:
                guard let navigator else { return refusal("The browser isn't available.") }
                return await handOff(call.args, navigator: navigator, eyesFree: eyesFree)
            }
        }
        guard navigator != nil else { return refusal("The browser isn't available.") }
        return await dispatch(call.name, args: call.args, eyesFree: eyesFree)
    }

    /// The session ends: stop watching the hand-off. Its run goes on and
    /// stays in the conversation.
    func stop() {
        handOffTask?.cancel()
        handOffTask = nil
    }

    /// Drops any kept `open_link` candidate list when the browser moves to another page.
    func pageChanged(_ page: PageContext) {
        linkState.pageChanged(to: VoiceLinkState.pageKey(url: nil, page: page))
    }

    // MARK: Registry

    private func makeRegistry(eyesFree: Bool) -> (BrowseToolContext, ToolRegistry) {
        let browse = BrowseToolContext(
            navigator: navigator,
            site: navigator?.voiceSite ?? SiteRegistry.standard.voiceFallback,
            linkState: linkState
        )
        browse.eyesFree = eyesFree
        let registry = registryBuilder?(browse) ?? ToolRegistry(tools: ToolRegistry.browseTools(browse: browse))
        return (browse, registry)
    }

    /// One registry tool, on the page as it is now.
    private func dispatch(_ name: String, args: [String: JSONValue], eyesFree: Bool) async -> VoiceToolOutcome {
        let (browse, registry) = makeRegistry(eyesFree: eyesFree)
        guard let tool = registry.tool(named: name) else {
            return refusal("\(name) isn't available on this page.")
        }
        if !browse.isOnForum, Self.forumOnlyTools.contains(name) {
            return refusal(Self.notForumMessage)
        }
        var args = Self.lenient(args, for: tool.definition)
        // "Summarize this", "follow this thread": voice names no thread, so the open topic it is.
        if let topicID = navigator?.pageContext.topic?.topicID {
            args = Self.defaultingToOpenTopic(args, topicID: topicID, for: tool.definition)
        }
        guard let result = try? await registry.dispatch(toolName: name, arguments: args) else {
            return refusal("The tool was stopped.")
        }
        if name == "read_page", !result.isError { linkState.clearDropped() }
        return VoiceToolOutcome(response: registry.spokenResult(result, eyesFree: eyesFree), scheduling: tool.voiceScheduling)
    }

    /// A thread tool called with no input (`{}`) gets the open topic.
    static func defaultingToOpenTopic(_ args: [String: JSONValue], topicID: String, for definition: AgentToolDefinition) -> [String: JSONValue] {
        guard definition.parameters.contains(where: { $0.name == "topic_id" }) else { return args }
        let given = ["topic_id", "url", "path", "text"].contains { key in
            !(args[key]?.textValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !given else { return args }
        var args = args
        for key in ["topic_id", "url", "path", "text"] { args[key] = nil }
        args["topic_id"] = .string(topicID)
        return args
    }

    /// Voice models send numbers as text ("2"); integer parameters take them.
    static func lenient(_ args: [String: JSONValue], for definition: AgentToolDefinition) -> [String: JSONValue] {
        var args = args
        for parameter in definition.parameters {
            guard let value = args[parameter.name] else { continue }
            switch parameter.type {
            case .integer where value.strictIntValue == nil:
                if let number = value.intValue { args[parameter.name] = .int(Int64(number)) }
            case .array where parameter.itemsType == .integer:
                if let items = value.arrayValue {
                    args[parameter.name] = .array(items.map { item in item.intValue.map { .int(Int64($0)) } ?? item })
                }
            default:
                break
            }
        }
        return args
    }

    // MARK: Hand-off

    private func handOff(_ args: [String: JSONValue], navigator: VoiceNavigator, eyesFree: Bool) async -> VoiceToolOutcome {
        if args["action"]?.stringValue == "cancel" {
            handOffTask?.cancel()
            handOffTask = nil
            let result = navigator.cancelHandOff()
                ? BrowseResult(status: .cancelled, shown: "The Agent's run was stopped.")
                : BrowseResult(status: .unavailable, shown: "No hand-off is running.")
            return VoiceToolOutcome(response: Self.response(result, eyesFree: eyesFree), scheduling: .whenIdle)
        }
        let request = (args["request"]?.textValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            return refusal("No request was given to hand off.")
        }
        // Routing in code: a browser action sent to the Agent is done here.
        if let routed = VoiceRouting.browserAction(for: request),
           routed == .move("back") || navigator.pageContext.isForum {
            let name: String
            let routedArgs: [String: JSONValue]
            switch routed {
            case .move(let action): (name, routedArgs) = (BrowseToolName.move, ["action": .string(action)])
            case .post(let number): (name, routedArgs) = (BrowseToolName.move, ["action": "post", "post": .int(Int64(number))])
            case .solution: (name, routedArgs) = (BrowseToolName.open, ["at": "solution"])
            }
            var outcome = await dispatch(name, args: routedArgs, eyesFree: eyesFree)
            outcome.response["routed"] = .string("This was a browser action, done directly with \(name); use \(name) for it next time.")
            outcome.scheduling = .whenIdle
            return outcome
        }
        if let reason = navigator.startHandOff(request) {
            return refusal(reason)
        }
        watchHandOff(request, navigator: navigator)
        return VoiceToolOutcome(
            response: [
                "status": "started",
                "shown": "The Agent is working on it in the panel.",
                "message": "You have already acknowledged it, so say nothing now. The answer arrives as a briefing; don't hand this request off again."
            ],
            scheduling: .silent,
            effect: .handOffStarted
        )
    }

    /// Watches one hand-off at a time: progress goes out silently, the end
    /// WHEN_IDLE. A newer hand-off drops the older one's briefing.
    private func watchHandOff(_ request: String, navigator: VoiceNavigator) {
        handOffTask?.cancel()
        handOffSequence += 1
        let sequence = handOffSequence
        let interval = progressInterval
        let progress = Task { @MainActor [weak self, weak navigator] in
            var last: String?
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.handOffSequence == sequence, let step = navigator?.handOffProgress, step != last else { continue }
                last = step
                self.onBriefing?(VoiceBriefing(
                    kind: .handOffProgress,
                    facts: ["request": .string(request), "step": .string(step), "message": "Progress only; say nothing unless the user asks how it's going."],
                    scheduling: .silent
                ))
            }
        }
        handOffTask = Task { @MainActor [weak self, weak navigator] in
            defer { progress.cancel() }
            guard let navigator else { return }
            let outcome = await navigator.handOffOutcome()
            guard let self, self.handOffSequence == sequence, !Task.isCancelled else { return }
            self.handOffTask = nil
            self.onBriefing?(Self.handOffBriefing(outcome, request: request))
        }
    }

    static func handOffBriefing(_ outcome: VoiceHandOffOutcome, request: String) -> VoiceBriefing {
        switch outcome {
        case .answered(let text):
            let answer = VoiceText.spokenAnswer(text)
            let facts = ToolRegistry.capSpoken([
                "status": "answered",
                "request": .string(request),
                "answer": .string(answer),
                "message": "The Agent you handed this to has answered. Open straight with the answer: restate it in about two sentences in the user's language, and say the full answer and its sources are in the panel. Don't read it out."
            ])
            return VoiceBriefing(kind: .handOffAnswer, facts: facts, scheduling: .whenIdle, spokenText: facts["answer"]?.stringValue)
        case .cancelled:
            return VoiceBriefing(
                kind: .handOffEnded,
                facts: ["status": "cancelled", "request": .string(request), "message": "The Agent's run stopped. Say nothing unless the user asks."],
                scheduling: .silent
            )
        case .failed(let reason):
            return VoiceBriefing(
                kind: .handOffEnded,
                facts: ["status": "failed", "request": .string(request), "shown": .string(reason),
                        "message": "The Agent couldn't finish. Tell the user in a few words; don't hand it off again unless they ask."],
                scheduling: .whenIdle,
                spokenText: reason
            )
        }
    }

    // MARK: Results

    /// A `BrowseResult` as the model gets it, with what to say next.
    static func response(_ result: BrowseResult, eyesFree: Bool) -> [String: JSONValue] {
        var response: [String: JSONValue] = [
            "status": .string(result.status.rawValue),
            "shown": .string(result.shown)
        ]
        if let content = result.content, !content.isEmpty { response["content"] = .string(content) }
        if let hits = result.hits, !hits.isEmpty {
            response["hits"] = .array(hits.map { hit in
                var object: [String: JSONValue] = [
                    "card": .int(Int64(hit.number)),
                    "title": .string(hit.title),
                    "excerpt": .string(hit.excerpt)
                ]
                if let post = hit.postNumber { object["post"] = .int(Int64(post)) }
                if let username = hit.username { object["author"] = .string(username) }
                object["topic_id"] = .string(hit.topicID)
                return .object(object)
            })
        }
        response["message"] = .string(message(for: result, eyesFree: eyesFree))
        return response
    }

    /// An `open_page` or `open_link` outcome as the model gets it, with host and title only (never a full URL).
    static func response(_ result: VoiceOpenResult, eyesFree: Bool) -> [String: JSONValue] {
        switch result {
        case .opened(let kind, let title, let host, let siteName, let query, let previousHost, let loading):
            let stripped = (title ?? "").replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTitle: String? = stripped.isEmpty ? nil : stripped
            let (shown, message): (String, String) = switch kind {
            case .address:
                (cleanTitle.map { "Opened “\($0)” at \(host)." } ?? (loading ? "Opening \(host)." : "Opened \(host)."),
                 "Say in a few words that you opened it, naming the title and host if shown.")
            case .site:
                (cleanTitle.map { "Opened “\($0)” at \(host)." } ?? "\(loading ? "Opening" : "Opened") \(siteName ?? host) (\(host)).",
                 "Say in a few words that you opened the site, naming the title and host.")
            case .search:
                (cleanTitle.map { "Searched the web for “\(query ?? "")” (“\($0)” at \(host))." } ?? "Searching the web for “\(query ?? "")” at \(host).",
                 "It ran a web search, not a site: tell the user so in a few words.")
            case .link:
                (cleanTitle.map { "Opened “\($0)” at \(host)." } ?? (loading ? "Opening \(host)." : "Opened \(host)."),
                 (previousHost.map { !$0.isEmpty && $0.lowercased() != host.lowercased() } ?? false)
                     ? "Say in a few words that you opened it, naming the title and the new host (\(host)), since it left \(previousHost ?? "")."
                     : "Say in a few words that you opened it, naming the title and host if shown.")
            }
            var response: [String: JSONValue] = ["status": "opened", "kind": .string(kind.rawValue), "host": .string(host), "shown": .string(shown), "message": .string(message)]
            if let cleanTitle { response["title"] = .string(cleanTitle) }
            return response
        case .choices(let target, let candidates):
            let items = candidates.map { "\($0.name) (\($0.host))" }
            return [
                "status": "choices",
                "shown": .string("Several sites match “\(target)”: \(items.joined(separator: ", "))."),
                "candidates": .array(items.map(JSONValue.string)),
                "message": "Several sites matched. Say this short list and ask the user which one to open."
            ]
        case .linkChoices(let words, let candidates):
            let cleanWords = AgentBridge.cleanLinkText(words)
            let items = candidates.prefix(5).enumerated().map { "\($0.offset + 1). \(AgentBridge.cleanLinkText($0.element.name)) (\($0.element.host))" }
            return [
                "status": "choices",
                "shown": .string("Several links match “\(cleanWords)”: \(items.joined(separator: "; "))."),
                "candidates": .array(items.map(JSONValue.string)),
                "message": "Several links matched. Say them briefly with their host and ask the user which one, then call open_link with its number."
            ]
        case .linkNotFound(let reason):
            return response(BrowseResult(status: .notFound, shown: reason), eyesFree: eyesFree)
        case .refused(let reason):
            return response(BrowseResult(status: .unavailable, shown: reason), eyesFree: eyesFree)
        case .failed(let reason):
            return response(BrowseResult(status: .failed, shown: reason), eyesFree: eyesFree)
        }
    }

    /// Plan B1 principle 5: every result says what to say next.
    static func message(for result: BrowseResult, eyesFree: Bool) -> String {
        let refusal = " Tell the user that instead, in a few words; don't retry."
        let landed = eyesFree
            ? "Tell the user in a few words where you are, then read or paraphrase the post briefly; they can't look at the screen."
            : "Say in a few words where you are and give the gist. It's on screen: don't read it out."
        switch result.status {
        case .opened, .moved:
            return result.content == nil ? "Say in a few words what is on screen now." : landed
        case .focused:
            return result.content == nil
                ? "Tell the user in a few words what the page shows now."
                : "Give the user the count and the gist of the first post. " + (eyesFree ? "You may read it briefly." : "It's on screen: don't read it out.")
        case .found:
            return "The hits are on screen as numbered cards. If one clearly fits what the user wants, call browse_open with its card number now, without asking. If several could fit, say the titles of the top two or three and let the user pick. Never read out ids or URLs."
        case .read:
            return eyesFree
                ? "Answer the user from this text only. You may read it out or paraphrase it."
                : "Answer the user from this text only. It's on screen: give the gist rather than reading it out, unless they asked you to read it."
        case .answered:
            return "Restate the answer in about two sentences and say the sources are on screen. Don't read it out."
        case .cancelled:
            return "Confirm in a few words that it stopped."
        case .noResults:
            return "Nothing matched. Say so and offer to try other words; search in the forum's language."
        case .noSolution:
            return "The topic has no accepted answer, so it opened at the top. Tell the user, and offer the most liked posts instead."
        case .endOfList:
            return "There is nothing further that way. Tell the user in a few words."
        case .emptyList:
            return "There is no list to move along yet. Tell the user and offer to search." + refusal
        case .notFound, .unavailable, .failed:
            return "It didn't work: the shown text says why." + refusal
        }
    }

    private func refusal(_ shown: String) -> VoiceToolOutcome {
        let result = BrowseResult(status: .unavailable, shown: shown)
        return VoiceToolOutcome(response: Self.response(result, eyesFree: false), scheduling: .whenIdle)
    }
}

/// The Agent's Markdown answer as speakable text: links become their titles,
/// citations and formatting marks go.
enum VoiceText {
    static func spokenAnswer(_ markdown: String) -> String {
        var text = PostCitations.stripped(markdown)
        // Post citations as links ("[#3](…)") go whole; other links keep their title.
        text = text.replacingOccurrences(of: #"\s?\[#?\d+\]\([^)\s]*\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!?\[((?:[^\[\]]|\[[^\[\]]*\])*)\]\([^)\s]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`]{1,3}"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Routing enforced in code: a `hand_off_to_agent` request that a browser tool does
/// (a bare "next", "post 37", "the solution") is done directly. Kept small
/// on purpose: only whole requests that are nothing but a browser command.
enum VoiceRouting {
    enum Action: Equatable {
        case move(String)
        case post(Int)
        case solution
    }

    static func browserAction(for request: String) -> Action? {
        let text = request.lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?;:。，！？；：")))
            .replacingOccurrences(of: #"^(please |go to |go |take me to |show me |请|去|到)"#, with: "", options: .regularExpression)
        switch text {
        case "next", "next one", "next post", "next result", "下一个", "下一楼", "下一条", "下一個", "下一條":
            return .move("next")
        case "previous", "previous one", "previous post", "back one", "上一个", "上一楼", "上一条", "上一個", "上一條":
            return .move("previous")
        case "back", "go back", "返回", "后退", "後退":
            return .move("back")
        case "top", "first post", "the first post", "第一楼", "一楼", "第一樓", "一樓":
            return .post(1)
        case "the solution", "solution", "accepted answer", "the accepted answer", "解决方案", "解決方案", "采纳的答案", "採納的答案":
            return .solution
        default:
            break
        }
        let patterns = [#"^(?:post|reply|#)\s*(\d{1,5})$"#, #"^第\s*(\d{1,5})\s*[楼樓]$"#, #"^(\d{1,5})\s*[楼樓]$"#]
        for pattern in patterns {
            if let match = text.range(of: pattern, options: .regularExpression) {
                let digits = text[match].filter(\.isNumber)
                if let number = Int(digits), number >= 1 { return .post(number) }
            }
        }
        return nil
    }
}

/// Keeps the last multi-match `open_link` candidate list for the current page,
/// and drops it when the page changes so an old number is refused.
@MainActor
final class VoiceLinkState {
    enum State: Equatable {
        case none
        case active(pageKey: String, links: [PageLink])
        case dropped(onPageKey: String)
    }

    private(set) var state: State = .none

    static func pageKey(url: URL?, page: PageContext) -> String {
        if let topicKey = page.topic?.topicKey, page.state == .topic { return "topic:\(topicKey)" }
        guard let url = url ?? page.url else { return "\(page.state.rawValue):\(page.siteURL ?? "")" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    func clearDropped() { if case .dropped = state { state = .none } }

    func pageChanged(to newPageKey: String) {
        switch state {
        case .none: break
        case .active(let pageKey, _): if pageKey != newPageKey { state = .dropped(onPageKey: newPageKey) }
        case .dropped(let onPageKey):
            if onPageKey.isEmpty { state = .dropped(onPageKey: newPageKey) }
            else if !newPageKey.isEmpty, onPageKey != newPageKey { state = .none }
        }
    }

    func noteNavigation(to newPageKey: String = "") {
        switch state {
        case .none: break
        case .active: state = .dropped(onPageKey: newPageKey)
        case .dropped: state = .none
        }
    }

    func openLink(words: String?, number: Int?, navigator: VoiceNavigator) async -> VoiceOpenResult {
        if navigator.isHandingOff { return .refused(VoiceToolBridge.handOffBusyMessage) }
        let currentKey = navigator.linkPageIdentity
        pageChanged(to: currentKey)

        if let number {
            guard (1...AgentBridge.maxPageLinks).contains(number) else {
                return .linkNotFound("Link numbers run from 1 to \(AgentBridge.maxPageLinks).")
            }
            switch state {
            case .dropped:
                return .refused(VoiceToolBridge.staleLinkListMessage)
            case .active(_, let list):
                guard list.indices.contains(number - 1) else { return .linkNotFound("That list only has \(list.count) links.") }
                state = .none
                return await navigator.followLink(list[number - 1])
            case .none:
                let links = await navigator.pageLinks()
                guard !links.isEmpty else { return .linkNotFound("There are no links on this page.") }
                guard links.indices.contains(number - 1) else { return .linkNotFound("There are only \(links.count) links on this page.") }
                return await navigator.followLink(links[number - 1])
            }
        }

        let query = (words ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .refused("Say which link to open, by its words or its number.") }
        let links = await navigator.pageLinks()
        guard !links.isEmpty else { state = .none; return .linkNotFound("There are no links on this page.") }
        switch VoiceLinkMatcher.match(query, in: links) {
        case .none:
            state = .none
            return .linkNotFound("No link on this page matches “\(AgentBridge.cleanLinkText(query))”.")
        case .one(let link):
            state = .none
            return await navigator.followLink(link)
        case .several(let choices):
            let top = Array(choices.prefix(5))
            state = .active(pageKey: currentKey, links: top)
            return .linkChoices(words: query, candidates: top.map { .init(name: $0.text, host: $0.host) })
        }
    }
}

/// Pure text matcher for `open_link` (`voice-review.md` "Following a link").
enum VoiceLinkMatcher {
    enum Match: Equatable { case none, one(PageLink), several([PageLink]) }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "at", "for", "with", "from", "by", "about", "into",
        "over", "after", "under", "that", "this", "these", "those", "it", "its", "is", "are", "was", "were", "be", "and", "or", "please"
    ]
    private static let genericWords: Set<String> = ["link", "story", "article", "page", "post", "item", "one", "open", "follow", "called", "named", "titled"]
    private static let nonPluralS: Set<String> = ["news", "ios", "macos", "tvos", "watchos", "visionos", "aws", "series", "species", "paris", "texas", "mars", "gas", "lens", "always", "does", "goes", "was", "has", "his", "its", "this"]
    private static let hostNoise: Set<String> = ["www", "com", "org", "net", "io", "co", "uk", "edu", "gov"]
    private static let cjkWrappers = ["请打开", "打开", "点开", "点击", "关于", "有关", "那个", "那篇", "那条", "这个", "这篇", "这条", "的链接", "链接", "的文章", "文章", "的新闻", "新闻", "的"]

    static func match(_ words: String, in links: [PageLink]) -> Match {
        let foldedQuery = fold(words)
        let rawLatin = matches("[a-z0-9]+", in: foldedQuery).map(stem)
        let contentLatin = rawLatin.filter { !stopWords.contains($0) }
        let effectiveContent = contentLatin.isEmpty ? rawLatin : contentLatin
        let coreLatin = effectiveContent.filter { !genericWords.contains($0) }
        let cjk = cjkUnits(in: foldedQuery)
        let primaryLatin = (!coreLatin.isEmpty || !cjk.isEmpty) ? coreLatin : effectiveContent
        guard !primaryLatin.isEmpty || !cjk.isEmpty else { return .none }
        let exactPhrase = cleanPhrase(foldedQuery)

        struct Scored { var link: PageLink; var primary: Int; var content: Int; var host: Int; var exact: Bool }
        var scored: [Scored] = []
        for link in links {
            let foldedText = fold(link.text)
            let rawTextWords = matches("[a-z0-9]+", in: foldedText)
            let textTokens = Set(rawTextWords + rawTextWords.map(stem))
            let primaryHits = primaryLatin.filter { textTokens.contains($0) }.count + cjk.filter { foldedText.contains($0) }.count
            guard primaryHits > 0 else { continue }
            let contentHits = effectiveContent.filter { textTokens.contains($0) }.count + cjk.filter { foldedText.contains($0) }.count
            let rawHost = matches("[a-z0-9]+", in: fold(link.host)).filter { !hostNoise.contains($0) }
            let hostTokens = Set(rawHost + rawHost.map(stem))
            let hostHits = primaryLatin.filter { !textTokens.contains($0) && hostTokens.contains($0) }.count
            let isExact = (primaryLatin.count + cjk.count) >= 2 && cleanPhrase(foldedText) == exactPhrase
            scored.append(Scored(link: link, primary: primaryHits, content: contentHits, host: hostHits, exact: isExact))
        }
        guard let maxPrimary = scored.map(\.primary).max() else { return .none }
        var winners = scored.filter { $0.primary == maxPrimary }
        if winners.count > 1, let maxContent = winners.map(\.content).max() { winners = winners.filter { $0.content == maxContent } }
        if winners.count > 1, let maxHost = winners.map(\.host).max(), maxHost > 0 { winners = winners.filter { $0.host == maxHost } }
        if winners.count > 1, let onlyExact = winners.filter(\.exact).onlyElement { return .one(onlyExact.link) }
        return winners.count == 1 ? .one(winners[0].link) : .several(winners.map(\.link))
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    private static func cleanPhrase(_ folded: String) -> String {
        (matches("[a-z0-9]+", in: folded) + matches("[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}]+", in: folded)).joined(separator: " ")
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        return rx.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func cjkUnits(in folded: String) -> [String] {
        var units: [String] = []
        for run in matches("[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}]+", in: folded) {
            var stripped = run
            for wrapper in cjkWrappers { stripped = stripped.replacingOccurrences(of: wrapper, with: " ") }
            let parts = stripped.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            for part in (parts.isEmpty ? [run] : parts) {
                let chars = Array(part)
                if chars.count <= 2 { units.append(part) } else { for i in 0..<(chars.count - 1) { units.append(String(chars[i...i + 1])) } }
            }
        }
        return units
    }

    private static func stem(_ word: String) -> String {
        guard !nonPluralS.contains(word) else { return word }
        if word.count >= 5, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count >= 5, ["ches", "shes", "xes", "zes", "sses"].contains(where: word.hasSuffix) { return String(word.dropLast(2)) }
        if word.count >= 4, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") { return String(word.dropLast()) }
        return word
    }
}

private extension Array {
    var onlyElement: Element? { count == 1 ? first : nil }
}
