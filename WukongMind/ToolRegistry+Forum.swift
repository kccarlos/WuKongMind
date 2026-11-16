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
    /// (`design-one-loop.md` "Decisions"). Both surfaces declare site-neutral
    /// definitions on every page; off a supported site, or for a tool the site
    /// lacks, they refuse. Voice declares only `read_topic` from this group
    /// (`search_forum` is the card tool in `ToolRegistry+Browse.swift`).
    static func forumTools(context: AgentToolContext, surface: ToolSurface = .text) -> [AgentTool] {
        guard surface == .text else {
            var voiceReadTopic = readTopicDefinition(topic: "thread", urlHint: "Thread or post URL on the current site")
            voiceReadTopic.description += " Only works when the screen note says the user is on a forum; elsewhere it refuses."
            if let forum = context.forum {
                return [makeReadTopicTool(forum: forum, definition: voiceReadTopic)]
            }
            return [AgentTool(
                definition: voiceReadTopic,
                summarizeArguments: { summarizeReadTopicArguments($0) },
                execute: { _ in
                    let content = await BrowseToolContext.encode(
                        BrowseResult(status: .unavailable, shown: VoiceToolBridge.notForumMessage),
                        eyesFree: false
                    )
                    return ToolExecutionOutput(content: content, summary: "Not a forum")
                },
                surfaces: [.voice],
                spokenResult: browseSpokenResult
            )]
        }
        let forum = context.forum
        let specs = forum?.scope.adapter.agent.siteTools ?? []
        var tools = stableQueryDefinitions.map { definition -> AgentTool in
            if forum != nil {
                return makeSiteQueryTool(definition: definition, spec: specs.first { $0.name == definition.name }, forum: forum)
            }
            if let slot = SiteToolSlot(rawValue: definition.name), let learned = context.learnedSite {
                return makeLearnedSlotTool(definition: definition, slot: slot, learned: learned, context: context)
            }
            return refusingTool(definition: definition, forum: nil)
        }
        let readTopic = readTopicDefinition(topic: "thread", urlHint: "Thread or post URL on the current site")
        if let forum {
            tools.append(makeReadTopicTool(forum: forum, definition: readTopic))
        } else if let learned = context.learnedSite {
            tools.append(makeLearnedSlotTool(definition: readTopic, slot: .readTopic, learned: learned, context: context))
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
                description: "Search the current site's threads or posts when you are on a site the page context says "
                    + "can be read; the page context says what its search supports. "
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
                description: "List the current site's most recently active threads or newest posts (about 30), when you "
                    + "are on a site the page context says can be read.",
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
            return "No reading tool for this site yet. If the request needs the whole thread or a list, "
                + "learn the site (see Learning a site); otherwise use `read_page`."
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
        let hasPage = !(stringArgs["page"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasQuery = !((stringArgs["query"] ?? stringArgs["q"])?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let totalPages = max(1, session.rawPages.isEmpty ? RawTopicFormat.pageCount(of: session.source) : session.rawPages.count)
        let readLimit = await MainActor.run { forum.scope.readLimit }
        return try await finishTopicReadOutput(
            rawSource: session.source, renderedContent: result.content,
            header: ForumRendering.topicHeader(session: session, profile: profile),
            postCount: postCount, totalPages: totalPages, readLimit: readLimit,
            hasPage: hasPage, hasQuery: hasQuery, topicNoun: profile.topicNoun,
            shape: result.shape, callContext: callContext
        )
    }

    private static func finishTopicReadOutput(
        rawSource: String, renderedContent: String, header: String,
        postCount: Int, totalPages: Int, readLimit: Int,
        hasPage: Bool, hasQuery: Bool, topicNoun: String,
        shape: ThreadShape, callContext: ToolCallContext
    ) async throws -> ToolExecutionOutput {
        let defaultSummary = countLabel(postCount, singular: "post", plural: "posts")
        if !hasPage && !hasQuery {
            let compact = RawTopicFormat.postBlocks(rawSource).joined(separator: RawTopicFormat.blockSeparator)
            let scrubbedCompact = UntrustedWebContent.redactSecrets(in: compact, secrets: callContext.redactedSecrets)
            let limit = max(1, callContext.truncationLimit)
            if scrubbedCompact.count > limit {
                let boundedLimit = max(1, min(readLimit, limit))
                let bounded = PromptBuilder.boundedForumContext(rawSource, limit: boundedLimit, minimum: min(5_000, boundedLimit), totalPages: totalPages)
                if let workspace = callContext.workspace, let taskID = callContext.taskID,
                   let saved = try? await saveOutput(
                       compact, to: resultPath(taskID: taskID, step: callContext.step, toolName: ForumToolName.readTopic),
                       workspace: workspace, secrets: callContext.redactedSecrets, previewLength: 0
                   ) {
                    try Task.checkCancellation()
                    let notice = "Full thread: \(grouped(postCount)) \(postCount == 1 ? "post" : "posts"), \(grouped(scrubbedCompact.count)) characters, saved to \(saved.path)"
                    return ToolExecutionOutput(content: "\(header)\n\(notice)\n\n\(bounded)", summary: "saved to \(saved.path)", savedPath: saved.path, isRanged: true, shape: .thread(shape))
                }
                return ToolExecutionOutput(content: "\(header)\n\n\(bounded)", summary: defaultSummary, isRanged: true, shape: .thread(shape))
            }
            return ToolExecutionOutput(content: renderedContent, summary: defaultSummary, isRanged: true, shape: .thread(shape))
        }
        return ToolExecutionOutput(content: renderedContent, summary: defaultSummary, shape: .thread(shape), notes: hasQuery && !hasPage ? [.queryInTopic(topic: topicNoun)] : [])
    }

    private static func makeLearnedSlotTool(
        definition: AgentToolDefinition, slot: SiteToolSlot, learned: LearnedSiteContext, context: AgentToolContext
    ) -> AgentTool {
        let defaultCall = ToolCallContext(workspace: nil, taskID: nil, step: nil, truncationLimit: ToolRegistry.defaultTruncationLimit, redactedSecrets: [])
        return AgentTool(
            definition: definition,
            summarizeArguments: { args in slot == .readTopic ? summarizeReadTopicArguments(args) : summarizeQueryArguments(args) },
            execute: { args in try await runForumCall { try await executeLearnedSlot(slot: slot, arguments: args, learned: learned, context: context, callContext: defaultCall) } },
            executeWithContext: { args, callContext in try await runForumCall { try await executeLearnedSlot(slot: slot, arguments: args, learned: learned, context: context, callContext: callContext) } }
        )
    }

    /// The checks every learned `read_topic`, `list_latest` or `search_forum` call passes before
    /// the script runs: the switch, the person's off switch, failed state, and userscripts.
    /// Shared by the slots and the thread capabilities.
    static func learnedSlotGate(
        slot: SiteToolSlot, learned: LearnedSiteContext, scriptStore: ScriptStore
    ) async -> (refusal: ToolExecutionOutput?, scriptID: String?) {
        await MainActor.run { () -> (refusal: ToolExecutionOutput?, scriptID: String?) in
            guard learned.pageToolBridge.isEnabled else {
                return (ToolExecutionOutput(content: forumToolRefusal(slot.rawValue, forum: nil), summary: "Not a forum", isError: true), nil)
            }
            let liveState = learned.stateStore?.state(forHost: learned.host) ?? learned.state
            let slotState = liveState.slot(slot)
            let script = slotState.scriptID.flatMap { scriptStore.script(id: $0) }
            if slotState.scriptID != nil && script == nil {
                return (ToolExecutionOutput(content: forumToolRefusal(slot.rawValue, forum: nil), summary: "Not a forum", isError: true), nil)
            }
            if let script, !script.isEnabled, (script.disabledReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (ToolExecutionOutput(
                    content: "Error: The reading tool for this site is turned off in This page; use `read_page`.",
                    summary: "Turned off in This page", isError: true
                ), nil)
            }
            if slotState.status == .failed || (script.map { !$0.isEnabled } ?? false) {
                let code = slotState.failure?.code ?? SiteFailureCode.fromDisabledReason(script?.disabledReason)
                return (ToolExecutionOutput(
                    content: "Error: Learning to read this site failed (\(code.appSentence)). Don't try again unless the user asks; use `read_page`.",
                    summary: "Reading tool failed", isError: true
                ), nil)
            }
            if slotState.status == .notApplicable {
                return (ToolExecutionOutput(content: "Error: `\(slot.rawValue)` isn't available on this site; use `read_page`.", summary: "Not available", isError: true), nil)
            }
            guard let scriptID = slotState.scriptID, script != nil, slotState.status == .learned || slotState.status == .broken else {
                return (ToolExecutionOutput(content: forumToolRefusal(slot.rawValue, forum: nil), summary: "Not a forum", isError: true), nil)
            }
            guard scriptStore.isGlobalEnabled else {
                return (ToolExecutionOutput(content: "Error: Userscripts are turned off in Settings; use `read_page`.", summary: "Userscripts off", isError: true), nil)
            }
            return (nil, scriptID)
        }
    }

    private static func executeLearnedSlot(
        slot: SiteToolSlot, arguments: [String: JSONValue],
        learned: LearnedSiteContext, context: AgentToolContext, callContext: ToolCallContext
    ) async throws -> ToolExecutionOutput {
        let gate = await learnedSlotGate(slot: slot, learned: learned, scriptStore: context.scriptStore)
        if let refusal = gate.refusal { return refusal }
        let scriptID = gate.scriptID!

        switch slot {
        case .readTopic:
            let rawTopicID = arguments["topic_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawURL = arguments["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if rawURL.isEmpty && !rawTopicID.isEmpty {
                return ToolExecutionOutput(content: "Error: this site has no thread ids; pass the thread's URL.", isError: true)
            }
            guard !rawURL.isEmpty else { throw AgentError.missingArgument("url") }
            guard let validURL = SiteToolState.sameSiteURL(rawURL, host: learned.host) else {
                return ToolExecutionOutput(content: "Error: that address is not on this site.", isError: true)
            }
            let requestedPage = try validatedPageArgument(arguments)
            let threadKey = SiteToolState.canonicalThreadKey(for: validURL)
            try await MainActor.run { try learned.scope.checkTopicBudget(for: threadKey) }

            var payload: [String: JSONValue] = ["url": .string(validURL.absoluteString)]
            if let requestedPage { payload["page"] = .int(Int64(requestedPage)) }
            let call = await callLearnedReader(slot: slot, scriptID: scriptID, payload: payload, learned: learned, shapeNoun: "thread", as: ThreadShape.self)
            if let errorOutput = call.error { return errorOutput }
            let envelope = call.envelope!
            if envelope.currentPageOnly == true {
                let openURL = await context.bridge.currentPageMetadata().url
                guard SiteToolState.isSameDocument(validURL, openURLString: openURL) else {
                    return ToolExecutionOutput(content: "Error: open that thread first.", isError: true)
                }
            }
            guard !envelope.shape.posts.isEmpty,
                  envelope.shape.posts.allSatisfy({ !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                return ToolExecutionOutput(content: "Error: The reading tool returned no posts.", isError: true)
            }
            let rawSource = ForumRendering.rawTopicText(from: envelope.shape)
            let query = (arguments["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let readLimit = await MainActor.run { learned.scope.readLimit }
            let rendered = try ForumRendering.formatLearnedTopicRead(
                envelope: envelope, rawSource: rawSource, requestedPage: requestedPage, query: query, readLimit: readLimit
            )
            await MainActor.run { learned.scope.recordTopicRead(threadKey) }
            let postCount = envelope.shape.totalPosts ?? envelope.shape.posts.count
            let totalPages = max(1, envelope.totalPages ?? RawTopicFormat.pageCount(of: rawSource))
            return try await finishTopicReadOutput(
                rawSource: rawSource, renderedContent: rendered,
                header: ForumRendering.topicHeader(thread: envelope.shape),
                postCount: postCount, totalPages: totalPages, readLimit: readLimit,
                hasPage: requestedPage != nil, hasQuery: !query.isEmpty, topicNoun: "thread",
                shape: envelope.shape, callContext: callContext
            )

        case .listLatest:
            let call = await callLearnedReader(slot: slot, scriptID: scriptID, learned: learned, shapeNoun: "list", as: ListShape.self)
            if let errorOutput = call.error { return errorOutput }
            let envelope = call.envelope!
            guard !envelope.shape.items.isEmpty else {
                return ToolExecutionOutput(content: "Error: The reading tool returned no items.", isError: true)
            }
            let parts = ForumRendering.formatParts(list: envelope.shape, limit: 30)
            return ToolExecutionOutput(
                content: parts.body,
                summary: countLabel(envelope.shape.items.count, singular: "thread", plural: "threads"),
                shape: .list(envelope.shape),
                notes: [.latestList(topic: "thread")]
            )

        case .searchForum:
            for key in ["category", "after", "before"] {
                if let val = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                    return ToolExecutionOutput(content: "Error: not supported on this site: search with the query only.", isError: true)
                }
            }
            let query = (arguments["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw AgentError.missingArgument("query") }
            let requestedPage = try validatedPageArgument(arguments)
            var payload: [String: JSONValue] = ["query": .string(query)]
            if let requestedPage { payload["page"] = .int(Int64(requestedPage)) }
            let call = await callLearnedReader(slot: slot, scriptID: scriptID, payload: payload, learned: learned, shapeNoun: "list", as: ListShape.self)
            if let errorOutput = call.error { return errorOutput }
            let envelope = call.envelope!
            if let requestedPage, let total = envelope.totalPages, total >= 1, requestedPage > total {
                throw AgentError.invalidArgument("page", reason: "no such page \(requestedPage) (use 1 to \(total)).")
            }
            let parts = ForumRendering.formatParts(list: envelope.shape, limit: 20)
            return ToolExecutionOutput(
                content: parts.body,
                summary: countLabel(envelope.shape.items.count, singular: "thread", plural: "threads"),
                shape: .list(envelope.shape),
                notes: parts.showsUnnumberedHits ? [.unnumberedHits] : []
            )
        }
    }

    private static func validatedPageArgument(_ arguments: [String: JSONValue]) throws -> Int? {
        guard let raw = arguments["page"], !raw.isNull else { return nil }
        if let text = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty { return nil }
        guard let page = raw.intValue, page >= 1 else {
            throw AgentError.invalidArgument("page", reason: "use a positive integer.")
        }
        return page
    }

    static func callLearnedReader<Shape: Codable & Equatable & Sendable>(
        slot: SiteToolSlot, scriptID: String, payload: [String: JSONValue] = [:],
        learned: LearnedSiteContext, shapeNoun: String, as _: Shape.Type
    ) async -> (envelope: LearnedToolResult<Shape>?, error: ToolExecutionOutput?) {
        let outcome = await learned.pageToolBridge.callScriptTool(
            scriptID: scriptID, name: slot.rawValue, argumentsJSON: JSONValue.encodeCompactJSON(payload)
        )
        guard case .success(let callResult) = outcome else {
            if case .failure(let failure) = outcome {
                return (nil, ToolExecutionOutput(content: "Error: \(failure.message)", isError: true))
            }
            return (nil, ToolExecutionOutput(content: "Error: Tool call failed.", isError: true))
        }
        guard let envelope = try? JSONDecoder().decode(LearnedToolResult<Shape>.self, from: Data(callResult.json.utf8)) else {
            return (nil, ToolExecutionOutput(content: "Error: The reading tool returned an invalid \(shapeNoun) shape.", isError: true))
        }
        return (envelope, nil)
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
