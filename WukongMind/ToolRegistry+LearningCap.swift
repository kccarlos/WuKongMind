import Foundation

// The 4-call exploration cap before a learned reader is saved (`design-learn-on-ask.md`
// "The steps" 3, spike question 9: `gemini-3.8-flash` ignored the prompt-only cap on 6 of 6
// runs). The app counts only what it can see for certain: a `network_log` call, or a `run_js`
// call whose code fetches or parses markup, on a site with no learned reader, before the run's
// first `script_save` or `script_update` with `provides`. Past 4 the result carries a trusted
// nudge; the call is refused once the run has shown it is learning: it said the step 1 line
// ("Working out how to read this site."), wrote a `registerTool` reader, or a forum tool was
// refused for want of a reading tool. Other work on an ordinary page is never refused.

extension ToolRegistry {
    static let maxPreSaveProbes = 4

    private static let probeMarkers = ["fetch(", "DOMParser", "outerHTML"]
    private static let probeToolNames: Set<String> = ["network_log"]

    static func isDataSourceProbe(toolName: String, arguments: [String: JSONValue]) -> Bool {
        if probeToolNames.contains(toolName) { return true }
        guard toolName == "run_js", let code = arguments["code"]?.stringValue else { return false }
        return probeMarkers.contains { code.contains($0) }
    }

    static func capPreSaveExploration(_ tools: [AgentTool], context: AgentToolContext) -> [AgentTool] {
        guard context.forum == nil, context.pageTools?.isEnabled == true, let learned = context.learnedSite else { return tools }
        let state = context.learningRunState
        let stateStore = context.siteToolStateStore ?? learned.stateStore
        let host = learned.host
        let slotNames: Set<String> = ["read_topic", "list_latest", "search_forum"]
        let watchedNames = slotNames.union(["run_js", "network_log", "script_save", "script_update"])

        @Sendable func hasLearnedReader() -> Bool {
            guard let current = stateStore?.state(forHost: host) else { return false }
            return SiteToolSlot.allCases.contains { [.learned, .broken].contains(current.slot($0).status) }
        }
        /// nil: run the tool. A refusal: return it. `nudge`: run it and add the note.
        @Sendable func gate(_ name: String, _ args: [String: JSONValue]) -> (refusal: ToolExecutionOutput?, nudge: Bool) {
            if (name == "script_save" || name == "script_update"), case .array(let slots)? = args["provides"], !slots.isEmpty {
                state.closeProbing()
                return (nil, false)
            }
            if name == "run_js", args["code"]?.stringValue?.contains("registerTool") == true { state.armLearning() }
            guard isDataSourceProbe(toolName: name, arguments: args), !hasLearnedReader(),
                  let count = state.noteProbe(), count > maxPreSaveProbes else { return (nil, false) }
            guard state.isLearningArmed else { return (nil, true) }
            return (ToolExecutionOutput(
                content: "Error: Exploration stopped after \(maxPreSaveProbes) calls. Call `script_save` with `provides` now, "
                    + "or call `site_learning_report` and answer from `read_page`.",
                summary: "Exploration limit", isError: true
            ), false)
        }
        @Sendable func finish(_ name: String, _ output: ToolExecutionOutput, nudge: Bool) -> ToolExecutionOutput {
            var output = output
            if nudge { output.notes.append(.explorationNudge) }
            if output.isError, slotNames.contains(name), output.content.contains("No reading tool for this site yet") { state.armLearning() }
            return output
        }

        return tools.map { tool in
            let name = tool.definition.name
            guard watchedNames.contains(name) else { return tool }
            var wrapped = tool
            wrapped.execute = { args in
                let verdict = gate(name, args)
                if let refusal = verdict.refusal { return refusal }
                return finish(name, try await tool.execute(args), nudge: verdict.nudge)
            }
            if let inner = tool.executeWithContext {
                wrapped.executeWithContext = { args, call in
                    let verdict = gate(name, args)
                    if let refusal = verdict.refusal { return refusal }
                    return finish(name, try await inner(args, call), nudge: verdict.nudge)
                }
            }
            return wrapped
        }
    }

    /// `sites/<host>/notes.md` when the model's notes for the open page's site exist (the page
    /// context only says so; the model reads the file itself, wrapped as data).
    func siteNotesPath(forPageURL rawURL: String) async -> String? {
        guard let workspace, let url = URL(string: rawURL), let host = SiteToolState.normalizedHost(from: url) else { return nil }
        let path = "sites/\(host)/notes.md"
        guard let read = try? await workspace.read(path: path, length: 1), read.binaryDescription == nil else { return nil }
        return path
    }
}
