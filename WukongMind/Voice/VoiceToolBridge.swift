import Foundation

/// What the voice layer needs from the app: the navigation layer
/// (AppModel+Navigation.swift), the hand-off to the Agent, and a few reads
/// for the silent context. AppModel conforms (AppModel+Voice.swift); tests
/// use a fake.
@MainActor
protocol VoiceNavigator: AnyObject {
    var pageContext: PageContext { get }
    var browseCursor: BrowseCursor { get }
    /// The words and tool options of the site a session starting now is on.
    var voiceSite: VoiceSite { get }

    func find(_ query: String, scope: BrowseSearchScope) async -> BrowseResult
    func openTopic(_ target: BrowseTarget, at landing: BrowseLanding, includeContent: Bool) async -> BrowseResult
    func openCard(_ index: Int, includeContent: Bool) async -> BrowseResult
    func goToPost(_ number: Int) async -> BrowseResult
    func next() async -> BrowseResult
    func previous() async -> BrowseResult
    func back() -> BrowseResult
    func forward() -> BrowseResult
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
    weak var navigator: VoiceNavigator?
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
    private var site: VoiceSite?
    private var handOffTask: Task<Void, Never>?
    private var handOffSequence = 0

    init(navigator: VoiceNavigator?) {
        self.navigator = navigator
    }

    /// Fixes the session's tools for `site` (a fresh connection) and returns
    /// their declarations.
    func declare(for site: VoiceSite) -> [GeminiLive.FunctionDeclaration] {
        self.site = site
        declarations = VoiceDeclarations.all(registry: registry(eyesFree: false))
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

    // MARK: Registry

    private func registry(eyesFree: Bool) -> ToolRegistry {
        let browse = BrowseToolContext(navigator: navigator, site: site ?? navigator?.voiceSite ?? SiteRegistry.standard.voiceFallback)
        browse.eyesFree = eyesFree
        return registryBuilder?(browse) ?? ToolRegistry(tools: ToolRegistry.browseTools(browse: browse))
    }

    /// One registry tool, on the page as it is now.
    private func dispatch(_ name: String, args: [String: JSONValue], eyesFree: Bool) async -> VoiceToolOutcome {
        let registry = registry(eyesFree: eyesFree)
        guard let tool = registry.tool(named: name) else {
            return refusal("\(name) isn't available on this page.")
        }
        guard let result = try? await registry.dispatch(toolName: name, arguments: Self.lenient(args, for: tool.definition)) else {
            return refusal("The tool was stopped.")
        }
        return VoiceToolOutcome(response: registry.spokenResult(result, eyesFree: eyesFree), scheduling: tool.voiceScheduling)
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
        if let routed = VoiceRouting.browserAction(for: request) {
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
