import Foundation

// MARK: - navigate and reload_page (design-m3.md "navigate and reload_page")

extension ToolRegistry {
    /// Both tools give up waiting after this long and return what loaded.
    static let navigationTimeout: TimeInterval = 30

    /// `navigate` and `reload_page` on the browser's one page.
    /// `savedScriptCount` gives the number of saved scripts that run on a
    /// URL (for `reload_page`'s note).
    static func navigationTools(
        bridge: AgentPageDriving,
        savedScriptCount: @escaping @MainActor @Sendable (String) -> Int = { _ in 0 },
        timeout: TimeInterval = ToolRegistry.navigationTimeout
    ) -> [AgentTool] {
        [
            makeNavigateTool(bridge: bridge, timeout: timeout),
            makeReloadPageTool(bridge: bridge, savedScriptCount: savedScriptCount, timeout: timeout)
        ]
    }

    /// `reload_page`'s count: the enabled saved scripts whose match rules
    /// cover a URL.
    static func savedScriptCounter(_ store: ScriptStore) -> @MainActor @Sendable (String) -> Int {
        { url in
            guard store.isGlobalEnabled else { return 0 }
            return store.scripts.filter { $0.isEnabled && $0.matches(urlString: url) }.count
        }
    }

    /// The address `navigate` may open, or a refusal.
    static func navigableURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "about:blank" {
            return URL(string: "about:blank")!
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw ToolValidationError(
                "Invalid arguments for 'navigate': '\(trimmed)' is not a full address; include http:// or https://."
            )
        }
        guard scheme == "http" || scheme == "https" else {
            throw ToolValidationError(
                "Refused: navigate opens only http, https and about:blank addresses, not '\(scheme):'."
            )
        }
        guard let host = url.host, !host.isEmpty else {
            throw ToolValidationError("Invalid arguments for 'navigate': '\(trimmed)' has no host.")
        }
        return url
    }

    private static func makeNavigateTool(bridge: AgentPageDriving, timeout: TimeInterval) -> AgentTool {
        let definition = AgentToolDefinition(
            name: "navigate",
            description: """
            Open a URL in the browser's page (replacing the current page). Only http, https \
            and about:blank are allowed. Waits for the page to load (up to 30 s) and returns \
            its final URL, title, HTTP status and load time; wait='none' returns as soon as \
            the load starts. Unsaved changes to the current page are lost; saved scripts run \
            on the new page as usual.
            """,
            parameters: [
                ToolParameterSchema(
                    name: "url",
                    type: .string,
                    description: "The address to open: an http(s) URL or about:blank.",
                    minLength: 1
                ),
                ToolParameterSchema(
                    name: "wait",
                    type: .string,
                    description: "'load' (default): wait until the page finishes loading. 'none': return at once.",
                    enumValues: ["load", "none"]
                )
            ],
            required: ["url"]
        )

        return AgentTool(
            definition: definition,
            customValidate: { args in
                _ = try navigableURL(args["url"]?.stringValue ?? "")
            },
            summarizeArguments: { args in
                condenseNavigationInline(args["url"]?.stringValue ?? "", maxChars: 64)
            },
            execute: { args in
                let url = try navigableURL(args["url"]?.stringValue ?? "")
                let wait = (args["wait"]?.stringValue ?? "load") != "none"
                let outcome = try await bridge.load(url, wait: wait, timeout: timeout)
                return navigationOutput(outcome, verb: "Opened", note: nil)
            }
        )
    }

    private static func makeReloadPageTool(
        bridge: AgentPageDriving,
        savedScriptCount: @escaping @MainActor @Sendable (String) -> Int,
        timeout: TimeInterval
    ) -> AgentTool {
        let definition = AgentToolDefinition(
            name: "reload_page",
            description: """
            Reload the current page. This undoes every unsaved change from this conversation \
            (run_js edits, inject_css styles); saved scripts are injected again. Use it to undo \
            a change that broke the page. Returns the URL, title, HTTP status and load time.
            """,
            parameters: [],
            required: []
        )

        return AgentTool(
            definition: definition,
            summarizeArguments: { _ in "" },
            execute: { _ in
                let outcome = try await bridge.reload(timeout: timeout)
                var note: String?
                if outcome.failure == nil {
                    let count = await savedScriptCount(outcome.url)
                    let scripts = count == 1 ? "1 saved script was" : "\(count) saved scripts were"
                    note = "Unsaved changes from this conversation were dropped; \(scripts) injected again."
                }
                return navigationOutput(outcome, verb: "Reloaded", note: note)
            }
        )
    }

    private static func navigationOutput(
        _ outcome: AgentNavigationOutcome,
        verb: String,
        note: String?
    ) -> ToolExecutionOutput {
        var fields: [String: JSONValue] = [
            "url": .string(outcome.url),
            "title": .string(outcome.title),
            "status": outcome.status.map { .int(Int64($0)) } ?? .null,
            "load_ms": .int(Int64(outcome.loadMs))
        ]
        if outcome.timedOut { fields["timed_out"] = .bool(true) }
        let json = JSONValue.encodeCompactJSON(fields)

        if let failure = outcome.failure {
            return ToolExecutionOutput(
                content: "Error: The page didn't load: \(failure)\n\n\(json)",
                summary: "Error: \(condenseNavigationInline(failure, maxChars: 72))",
                isError: true
            )
        }

        let host = URL(string: outcome.url)?.host ?? outcome.url
        var details: [String] = []
        if let status = outcome.status { details.append(String(status)) }
        details.append("\(outcome.loadMs) ms")
        if outcome.timedOut { details.append("timed out") }
        let summary = "\(verb) \(condenseNavigationInline(host, maxChars: 48)) (\(details.joined(separator: ", ")))"
        let content = [json, note].compactMap { $0 }.joined(separator: "\n\n")
        return ToolExecutionOutput(content: content, summary: summary, isError: false)
    }

    private static func condenseNavigationInline(_ text: String, maxChars: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.isEmpty { return "(empty)" }
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.prefix(maxChars)) + "…"
    }
}
