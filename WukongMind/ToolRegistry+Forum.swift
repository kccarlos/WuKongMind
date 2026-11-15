import Foundation

/// Stable names for the four adapter-backed forum tools (`design-one-loop.md` "Decisions").
enum ForumToolName {
    static let searchForum = "search_forum"
    static let searchComments = "search_comments"
    static let listLatest = "list_latest"
    static let readTopic = "read_topic"
}

extension ToolRegistry {
    /// Forum search, comment search, latest listing, and thread reading tools
    /// (`design-one-loop.md` "Decisions"). The text Agent declares the same four
    /// on every page, with wording that names no site, so the tool list stays
    /// byte-identical across page changes and the prompt cache holds (WUKO-73);
    /// off a supported site, or for a tool the site lacks, they refuse. The
    /// site's own words go in the page context instead. Voice keeps the
    /// site's `read_topic` only while on a forum.
    static func forumTools(context: AgentToolContext, surface: ToolSurface = .text) -> [AgentTool] {
        guard surface == .text else {
            guard let forum = context.forum else { return [] }
            return [makeReadTopicTool(forum: forum, definition: readTopicDefinition(
                topic: forum.scope.adapter.agent.topicNoun, urlHint: "Thread URL on \(forum.scope.siteURL)"
            ))]
        }
        let forum = context.forum
        let specs = forum?.scope.adapter.agent.siteTools ?? []
        var tools = stableQueryDefinitions.map { definition in
            makeSiteQueryTool(definition: definition, spec: specs.first { $0.name == definition.name }, forum: forum)
        }
        let readTopic = readTopicDefinition(topic: "thread", urlHint: "Thread or post URL on the current site")
        if let forum {
            tools.append(makeReadTopicTool(forum: forum, definition: readTopic))
        } else {
            tools.append(refusingTool(definition: readTopic, forum: nil))
        }
        return tools
    }

    /// The text Agent's site query tools, the same on every page: every
    /// adapter's parameters, in one schema (WUKO-73).
    static let stableQueryDefinitions: [AgentToolDefinition] = {
        let page = ToolParameterSchema(name: "page", type: .integer, description: "Optional result page, 1 to 3 (Hacker News and WordPress).")
        let after = ToolParameterSchema(name: "after", type: .string, description: "Optional: only items after this date, YYYY-MM-DD (WordPress).")
        let before = ToolParameterSchema(name: "before", type: .string, description: "Optional: only items before this date, YYYY-MM-DD (WordPress).")
        return [
            AgentToolDefinition(
                name: ForumToolName.searchForum,
                description: "Search the current site's threads or posts when the page context says you are on a supported "
                    + "site (Discourse forum, Hacker News or WordPress); the page context says what its search supports. "
                    + "Returns up to about 20 threads with id, title and matches.",
                parameters: [
                    ToolParameterSchema(name: "query", type: .string, description: "Search text"),
                    ToolParameterSchema(name: "category", type: .string, description: "Optional category name or slug (WordPress)."),
                    after, before, page
                ],
                required: ["query"]
            ),
            AgentToolDefinition(
                name: ForumToolName.searchComments,
                description: "Search comments across the current site's threads (Hacker News and WordPress only), returning "
                    + "about 10 authored excerpts with their thread ids; read the thread for context and a citable source.",
                parameters: [
                    ToolParameterSchema(name: "query", type: .string, description: "Search text"),
                    ToolParameterSchema(name: "category", type: .string, description: "Optional category name or slug."),
                    after, before, page
                ],
                required: ["query"]
            ),
            AgentToolDefinition(
                name: ForumToolName.listLatest,
                description: "List the current site's most recently active threads or newest posts (about 30), when the page "
                    + "context says you are on a supported site.",
                parameters: []
            )
        ]
    }()

    static func readTopicDefinition(topic: String, urlHint: String) -> AgentToolDefinition {
        AgentToolDefinition(
            name: ForumToolName.readTopic,
            description: "Pull a \(topic)'s posts and return them (long \(topic)s are saved to the workspace "
                + "and trimmed inline to the beginning and the newest replies). Counts toward the "
                + "\(topic)-read budget the first time a \(topic) is read.",
            parameters: [
                ToolParameterSchema(name: "topic_id", type: .string, description: "Numeric \(topic) id (provide topic_id or url)."),
                ToolParameterSchema(name: "url", type: .string, description: "\(urlHint) (alternative to topic_id)."),
                ToolParameterSchema(name: "page", type: .integer, description: "Optional part of a long \(topic), in pages of \(RawForumPage.size) posts."),
                ToolParameterSchema(name: "query", type: .string, description: "Optional keywords to filter matching posts within this \(topic).")
            ]
        )
    }

    /// The model-facing refusal of a forum tool where it can't run (WUKO-73).
    static func forumToolRefusal(_ name: String, forum: ForumToolContext?) -> String {
        guard let forum else {
            return "This page isn't a forum or a supported site, so `\(name)` can't run here. "
                + "Use `read_page` to read the current page."
        }
        return "`\(name)` isn't available on \(forum.forumName); use `search_forum` or `read_topic` there."
    }

    private static func refusingTool(definition: AgentToolDefinition, forum: ForumToolContext?) -> AgentTool {
        AgentTool(
            definition: definition,
            summarizeArguments: { summarizeQueryArguments($0) },
            execute: { _ in
                let message = forumToolRefusal(definition.name, forum: forum)
                return ToolExecutionOutput(
                    content: message,
                    summary: forum == nil ? "Not a forum" : "Not on this site",
                    isError: true
                )
            }
        )
    }

    private static func makeSiteQueryTool(definition: AgentToolDefinition, spec: AgentToolSpec?, forum: ForumToolContext?) -> AgentTool {
        guard let forum, let spec else { return refusingTool(definition: definition, forum: forum) }
        return AgentTool(
            definition: definition,
            summarizeArguments: { summarizeQueryArguments($0) },
            execute: { args in
                try await runForumCall {
                    let stringArgs = stringArguments(from: args)
                    switch spec.name {
                    case ForumToolName.searchForum:
                        let result = try await forum.service.search(arguments: stringArgs, scope: forum.scope)
                        return ToolExecutionOutput(
                            content: result.body ?? result.content,
                            summary: countLabel(result.topics.count, singular: "thread", plural: "threads"),
                            shape: .list(result.shape),
                            notes: result.showsUnnumberedHits ? [.unnumberedHits] : []
                        )
                    case ForumToolName.searchComments:
                        let result = try await forum.service.searchComments(arguments: stringArgs, scope: forum.scope)
                        return ToolExecutionOutput(
                            content: result.body ?? result.content,
                            summary: countLabel(result.hits.count, singular: "comment", plural: "comments"),
                            shape: .list(result.shape),
                            notes: result.showsUnnumberedHits ? [.unnumberedHits] : []
                        )
                    case ForumToolName.listLatest:
                        let result = try await forum.service.listLatest(arguments: stringArgs, scope: forum.scope)
                        let topic = forum.scope.adapter.agent.topicNoun
                        return ToolExecutionOutput(
                            content: result.content,
                            summary: countLabel(result.topics.count, singular: "thread", plural: "threads"),
                            shape: .list(result.shape),
                            notes: result.topics.isEmpty ? [] : [.latestList(topic: topic)]
                        )
                    default:
                        throw SiteQueryError.unsupported
                    }
                }
            }
        )
    }

    private static func makeReadTopicTool(forum: ForumToolContext, definition: AgentToolDefinition) -> AgentTool {
        let profile = forum.scope.adapter.agent
        return AgentTool(
            definition: definition,
            summarizeArguments: { summarizeReadTopicArguments($0) },
            execute: { args in
                try await runForumCall {
                    try await executeReadTopic(
                        arguments: args, forum: forum, profile: profile,
                        callContext: ToolCallContext(
                            workspace: nil, taskID: nil, step: nil,
                            truncationLimit: ToolRegistry.defaultTruncationLimit, redactedSecrets: []
                        )
                    )
                }
            },
            executeWithContext: { args, callContext in
                try await runForumCall {
                    try await executeReadTopic(arguments: args, forum: forum, profile: profile, callContext: callContext)
                }
            },
            surfaces: [.text, .voice]
        )
    }

    private static func executeReadTopic(
        arguments: [String: JSONValue], forum: ForumToolContext,
        profile: AgentSiteProfile, callContext: ToolCallContext
    ) async throws -> ToolExecutionOutput {
        let stringArgs = stringArguments(from: arguments)
        let result = try await forum.service.readTopic(arguments: stringArgs, scope: forum.scope)
        let session = result.session
        let blocks = RawTopicFormat.postBlocks(session.source)
        let postCount = session.totalPosts ?? blocks.count
        let defaultSummary = countLabel(postCount, singular: "post", plural: "posts")

        let hasPage = !(stringArgs["page"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasQuery = !((stringArgs["query"] ?? stringArgs["q"])?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if !hasPage && !hasQuery {
            let compact = blocks.joined(separator: RawTopicFormat.blockSeparator)
            let scrubbedCompact = UntrustedWebContent.redactSecrets(in: compact, secrets: callContext.redactedSecrets)
            let limit = max(1, callContext.truncationLimit)
            if scrubbedCompact.count > limit {
                let header = ForumRendering.topicHeader(session: session, profile: profile)
                let totalPages = max(
                    1, session.rawPages.isEmpty ? RawTopicFormat.pageCount(of: session.source) : session.rawPages.count
                )
                let readLimit = await MainActor.run { forum.scope.readLimit }
                let boundedLimit = max(1, min(readLimit, limit))
                let bounded = PromptBuilder.boundedForumContext(
                    session.source, limit: boundedLimit, minimum: min(5_000, boundedLimit), totalPages: totalPages
                )
                if let workspace = callContext.workspace,
                   let taskID = callContext.taskID,
                   let saved = try? await saveOutput(
                       compact,
                       to: resultPath(taskID: taskID, step: callContext.step, toolName: ForumToolName.readTopic),
                       workspace: workspace,
                       secrets: callContext.redactedSecrets,
                       previewLength: 0
                   ) {
                    try Task.checkCancellation()
                    let notice = "Full thread: \(grouped(postCount)) \(postCount == 1 ? "post" : "posts"), "
                        + "\(grouped(scrubbedCompact.count)) characters, saved to \(saved.path)"
                    return ToolExecutionOutput(
                        content: "\(header)\n\(notice)\n\n\(bounded)",
                        summary: "saved to \(saved.path)", savedPath: saved.path,
                        isRanged: true, shape: .thread(result.shape)
                    )
                }
                return ToolExecutionOutput(
                    content: "\(header)\n\n\(bounded)", summary: defaultSummary,
                    isRanged: true, shape: .thread(result.shape)
                )
            }
            return ToolExecutionOutput(
                content: result.content, summary: defaultSummary, isRanged: true, shape: .thread(result.shape)
            )
        }
        return ToolExecutionOutput(
            content: result.content, summary: defaultSummary, shape: .thread(result.shape),
            notes: hasQuery && !hasPage ? [.queryInTopic(topic: profile.topicNoun)] : []
        )
    }

    private static func stringArguments(from arguments: [String: JSONValue]) -> [String: String] {
        var converted: [String: String] = [:]
        for (key, value) in arguments {
            switch value {
            case .string(let text): converted[key] = text
            case .int(let number): converted[key] = String(number)
            case .double(let number): converted[key] = value.strictIntValue.map(String.init) ?? String(number)
            case .bool(let flag): converted[key] = String(flag)
            case .object(let obj): converted[key] = JSONValue.encodeCompactJSON(obj)
            case .array(let items):
                if let data = try? JSONEncoder().encode(items), let text = String(data: data, encoding: .utf8) {
                    converted[key] = text
                }
            case .null: break
            }
        }
        return converted
    }

    fileprivate static func summarizeQueryArguments(_ args: [String: JSONValue]) -> String {
        var parts: [String] = []
        if let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            parts.append("\"\(query)\"")
        }
        for key in ["category", "after", "before"] {
            if let value = args[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                parts.append("\(key): \(value)")
            }
        }
        if let page = args["page"]?.strictIntValue { parts.append("page \(page)") }
        return parts.joined(separator: " · ")
    }

    private static func summarizeReadTopicArguments(_ args: [String: JSONValue]) -> String {
        var parts: [String] = []
        if let id = args["topic_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            parts.append("#\(id)")
        } else if let url = args["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            parts.append(url)
        }
        if let page = args["page"]?.strictIntValue { parts.append("page \(page)") }
        if let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            parts.append("\"\(query)\"")
        }
        return parts.joined(separator: " · ")
    }

    private static func countLabel(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    private static func runForumCall(_ body: () async throws -> ToolExecutionOutput) async throws -> ToolExecutionOutput {
        do {
            return try await body()
        } catch let error as AgentError {
            let message = error.modelDescription
            return ToolExecutionOutput(
                content: "Error: \(message)",
                summary: "Error: \(ToolExecutionOutput.defaultSummary(for: message, maxChars: 80))",
                isError: true
            )
        }
    }
}
