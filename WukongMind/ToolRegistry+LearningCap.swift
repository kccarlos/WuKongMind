import Foundation

// The 4-call exploration cap before a learned reader is saved (`design-learn-on-ask.md`
// "The steps" 3, spike question 9: `gemini-3.8-flash` ignored the prompt-only cap on 6 of 6
// runs). The app counts only what it can see for certain: a call to `network_log` or
// `http_request`, or a `run_js` call whose code fetches or parses markup, on a site with no
// learned reader, before the run's first `script_save` or `script_update` with `provides`.
// Other `run_js` work on an ordinary page is never counted.

extension ToolRegistry {
    static let maxPreSaveProbes = 4

    private static let probeMarkers = ["fetch(", "DOMParser", "outerHTML"]
    private static let probeToolNames: Set<String> = ["network_log", "http_request"]

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

        @Sendable func hasLearnedReader() -> Bool {
            guard let current = stateStore?.state(forHost: host) else { return false }
            return SiteToolSlot.allCases.contains { [.learned, .broken].contains(current.slot($0).status) }
        }
        @Sendable func gate(_ name: String, _ args: [String: JSONValue]) -> ToolExecutionOutput? {
            if (name == "script_save" || name == "script_update"), case .array(let slots)? = args["provides"], !slots.isEmpty {
                state.closeProbing()
                return nil
            }
            guard isDataSourceProbe(toolName: name, arguments: args), !hasLearnedReader(),
                  let count = state.noteProbe(), count > maxPreSaveProbes else { return nil }
            return ToolExecutionOutput(
                content: "Error: Exploration stopped after \(maxPreSaveProbes) calls. Call `script_save` with `provides` now, "
                    + "or call `site_learning_report` and answer from `read_page`.",
                summary: "Exploration limit", isError: true
            )
        }

        return tools.map { tool in
            let name = tool.definition.name
            guard ["run_js", "network_log", "http_request", "script_save", "script_update"].contains(name) else { return tool }
            var wrapped = tool
            wrapped.execute = { args in
                if let refusal = gate(name, args) { return refusal }
                return try await tool.execute(args)
            }
            if let inner = tool.executeWithContext {
                wrapped.executeWithContext = { args, call in
                    if let refusal = gate(name, args) { return refusal }
                    return try await inner(args, call)
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
