import Foundation

/// Stable names for the four adapter-backed forum tools (`design-one-loop.md` "Decisions").
enum ForumToolName {
    static let searchForum = "search_forum"
    static let searchComments = "search_comments"
    static let listLatest = "list_latest"
    static let readTopic = "read_topic"
}

/// One-line nudges at the top of a forum result, where a small model reads them (gate 2:
/// H4 recommended from titles only, H3 answered "others say" from the named thread only).
enum ForumToolHint {
    static func latest(topic: String) -> String {
        "Note: these are titles and excerpts only. Before recommending any, read or summarize at least one "
            + "promising \(topic) (`read_topic`), and say which ones you only saw listed."
    }

    static func queryInTopic(topic: String) -> String {
        "Note: these are matches inside this \(topic) only. To find what others say about it in other "
            + "\(topic)s, search the forum (`search_forum`) too."
    }
}

extension ToolRegistry {
    /// Forum search, comment search, latest listing, and thread reading tools for
    /// the current run's recognized forum (`design-one-loop.md` "Decisions").
    static func forumTools(context: AgentToolContext) -> [AgentTool] {
        guard let forum = context.forum else { return [] }
        let profile = forum.scope.adapter.agent
        var tools = profile.siteTools.compactMap { makeSiteQueryTool(spec: $0, forum: forum) }
        tools.append(makeReadTopicTool(forum: forum, profile: profile))
        return tools
    }

    private static func makeSiteQueryTool(spec: AgentToolSpec, forum: ForumToolContext) -> AgentTool? {
        guard [ForumToolName.searchForum, ForumToolName.searchComments, ForumToolName.listLatest].contains(spec.name) else {
            return nil
        }
        let parameters = spec.parameters.map { parameter in
            ToolParameterSchema(
                name: parameter.name,
                type: parameter.name == "page" ? .integer : .string,
                description: parameter.description
            )
        }
        return AgentTool(
            definition: AgentToolDefinition(
                name: spec.name,
                description: spec.description,
                parameters: parameters,
                required: spec.parameters.filter(\.required).map(\.name)
            ),
            summarizeArguments: { summarizeQueryArguments($0) },
            execute: { args in
                try await runForumCall {
                    let stringArgs = stringArguments(from: args)
                    switch spec.name {
                    case ForumToolName.searchForum:
                        let result = try await forum.service.search(arguments: stringArgs, scope: forum.scope)
                        return ToolExecutionOutput(
                            content: result.content,
                            summary: countLabel(result.topics.count, singular: "thread", plural: "threads"),
                            shape: .list(result.shape)
                        )
                    case ForumToolName.searchComments:
                        let result = try await forum.service.searchComments(arguments: stringArgs, scope: forum.scope)
                        return ToolExecutionOutput(
                            content: result.content,
                            summary: countLabel(result.hits.count, singular: "comment", plural: "comments"),
                            shape: .list(result.shape)
                        )
                    case ForumToolName.listLatest:
                        let result = try await forum.service.listLatest(arguments: stringArgs, scope: forum.scope)
                        let topic = forum.scope.adapter.agent.topicNoun
                        return ToolExecutionOutput(
                            content: result.topics.isEmpty ? result.content : ForumToolHint.latest(topic: topic) + "\n\n" + result.content,
                            summary: countLabel(result.topics.count, singular: "thread", plural: "threads"),
                            shape: .list(result.shape)
                        )
                    default:
                        throw SiteQueryError.unsupported
                    }
                }
            }
        )
    }

    private static func makeReadTopicTool(forum: ForumToolContext, profile: AgentSiteProfile) -> AgentTool {
        let topic = profile.topicNoun
        let siteURL = forum.scope.siteURL
        let definition = AgentToolDefinition(
            name: ForumToolName.readTopic,
            description: "Pull a \(topic)'s posts and return them (long \(topic)s are saved to the workspace "
                + "and trimmed inline to the beginning and the newest replies). Counts toward the "
                + "\(topic)-read budget the first time a \(topic) is read.",
            parameters: [
                ToolParameterSchema(name: "topic_id", type: .string, description: "Numeric \(topic) id (provide topic_id or url)."),
                ToolParameterSchema(name: "url", type: .string, description: "Thread URL on \(siteURL) (alternative to topic_id)."),
                ToolParameterSchema(name: "page", type: .integer, description: "Optional part of a long \(topic), in pages of \(RawForumPage.size) posts."),
                ToolParameterSchema(name: "query", type: .string, description: "Optional keywords to filter matching posts within this \(topic).")
            ]
        )
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
            }
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
                        content: "\(header)\n\(notice)\n\n\(bounded)\n\nRead any part with file_read(path, offset).",
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
        let content = hasQuery && !hasPage ? ForumToolHint.queryInTopic(topic: profile.topicNoun) + "\n" + result.content : result.content
        return ToolExecutionOutput(content: content, summary: defaultSummary, shape: .thread(result.shape))
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

    private static func summarizeQueryArguments(_ args: [String: JSONValue]) -> String {
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
