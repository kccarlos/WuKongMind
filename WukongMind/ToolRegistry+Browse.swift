import Foundation

// The voice-only browse tools (`design-one-loop.md` "Voice"): they move the
// reader's page through the navigation layer (`VoiceNavigator`), so only the
// voice session declares them. The text Agent moves through pages with its
// own page tools. Each result is today's voice function response
// (`VoiceToolBridge.response`), carried as JSON in the tool output.

enum BrowseToolName {
    static let open = "browse_open"
    static let move = "browse_move"
    static let focus = "browse_focus"
    static let readPost = "read_post"
}

/// What the browse tools act on: the session's navigator, the site its
/// words came from, and whether the user can look at the screen (set by the
/// bridge before each call).
@MainActor
final class BrowseToolContext {
    weak var navigator: VoiceNavigator?
    nonisolated let site: VoiceSite
    /// The page is a recognized forum home or topic: the forum and browse tools apply.
    nonisolated let isOnForum: Bool
    var eyesFree = false

    init(navigator: VoiceNavigator?, site: VoiceSite, isOnForum: Bool? = nil) {
        self.navigator = navigator
        self.site = site
        self.isOnForum = isOnForum ?? (navigator?.pageContext.isForum ?? false)
    }

    func run(_ body: (VoiceNavigator) async -> BrowseResult) async -> String {
        guard let navigator else {
            return Self.encode(BrowseResult(status: .unavailable, shown: "The browser isn't available."), eyesFree: eyesFree)
        }
        return Self.encode(await body(navigator), eyesFree: eyesFree)
    }

    static func encode(_ result: BrowseResult, eyesFree: Bool) -> String {
        JSONValue.encodeCompactJSON(VoiceToolBridge.response(result, eyesFree: eyesFree))
    }

    // MARK: Navigation

    func open(_ args: [String: JSONValue], navigator: VoiceNavigator) async -> BrowseResult {
        let landing: BrowseLanding? = switch args["at"]?.stringValue {
        case "post": args["post"]?.intValue.map(BrowseLanding.post)
        case "solution": .solution
        case "last": .last
        case "top": .top
        case "unread": .firstNew
        default: args["post"]?.intValue.map(BrowseLanding.post)
        }
        if let card = args["card"]?.intValue {
            guard landing == nil || landing == .firstNew else {
                // A card opened somewhere else than its own post.
                let items = navigator.browseCursor.items
                guard items.indices.contains(card - 1) else {
                    return BrowseResult(status: .notFound, shown: "There is no card \(card).")
                }
                return await navigator.openTopic(.item(items[card - 1]), at: landing ?? .firstNew, includeContent: true)
            }
            return await navigator.openCard(card - 1, includeContent: true)
        }
        if let topic = args["topic_id"]?.textValue, !topic.filter(\.isNumber).isEmpty {
            return await navigator.openTopic(.topic(topic), at: landing ?? .firstNew, includeContent: true)
        }
        guard let ref = navigator.pageContext.topic else {
            return BrowseResult(status: .unavailable, shown: "No topic is open; search or pick a card first.")
        }
        return await navigator.openTopic(.topic(ref.topicID), at: landing ?? .firstNew, includeContent: true)
    }

    func move(action: String, post: Int?, navigator: VoiceNavigator) async -> BrowseResult {
        switch action {
        case "next": return await navigator.next()
        case "previous": return await navigator.previous()
        case "back": return navigator.back()
        case "forward": return navigator.forward()
        case "post":
            guard let post else { return BrowseResult(status: .notFound, shown: "No post number was given.") }
            return await navigator.goToPost(post)
        case "top": return await navigator.goToPost(1)
        case "bottom":
            guard let topic = navigator.pageContext.topic else {
                return BrowseResult(status: .unavailable, shown: "No topic is open.")
            }
            return await navigator.openTopic(.topic(topic.topicID), at: .last, includeContent: true)
        default:
            return BrowseResult(status: .unavailable, shown: "Unknown move \"\(action)\".")
        }
    }

    func focus(_ args: [String: JSONValue], navigator: VoiceNavigator) async -> BrowseResult {
        switch args["mode"]?.stringValue {
        case "user":
            let name = (args["user"]?.textValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            guard !name.isEmpty else { return BrowseResult(status: .notFound, shown: "No username was given.") }
            return await navigator.focus(.user(name))
        case "op": return await navigator.focus(.op)
        case "top": return await navigator.focus(.top)
        case "posts":
            let numbers = (args["posts"]?.arrayValue ?? []).compactMap(\.intValue)
            return await navigator.focus(.posts(numbers))
        case "clear": return await navigator.focus(.clear)
        default: return BrowseResult(status: .unavailable, shown: "Unknown focus mode.")
        }
    }
}

extension ToolRegistry {
    /// The voice session's own tools: `read_page` in structure mode, plus, on
    /// a forum page, `search_forum` with results as cards and the four browse
    /// tools. All `[.voice]`.
    static func browseTools(context: AgentToolContext) -> [AgentTool] {
        guard let browse = context.browse else { return [] }
        return [voiceReadPageTool(bridge: context.bridge)] + browseTools(browse: browse)
    }

    /// The navigator-backed tools alone (also the bridge's registry when the
    /// app gives it no builder).
    static func browseTools(browse: BrowseToolContext) -> [AgentTool] {
        guard browse.isOnForum else { return [] }
        return [
            searchCardsTool(browse: browse),
            browseTool(BrowseToolName.open, browse: browse) { args, navigator in await browse.open(args, navigator: navigator) },
            browseTool(BrowseToolName.move, browse: browse) { args, navigator in
                await browse.move(action: args["action"]?.stringValue ?? "", post: args["post"]?.intValue, navigator: navigator)
            },
            browseTool(BrowseToolName.focus, browse: browse) { args, navigator in await browse.focus(args, navigator: navigator) },
            browseTool(BrowseToolName.readPost, browse: browse) { args, navigator in
                args["scope"]?.stringValue == "visible" ? await navigator.readVisible() : await navigator.read(post: args["post"]?.intValue)
            }
        ]
    }

    /// A browse result's facts: the response the tool encoded.
    @Sendable static func browseSpokenResult(_ result: ToolDispatchResult, eyesFree: Bool) -> [String: JSONValue] {
        if !result.isError, let facts = try? JSONValue.parseObjectJSON(result.output) { return facts }
        return defaultSpokenResult(result)
    }

    private static func searchCardsTool(browse: BrowseToolContext) -> AgentTool {
        let site = browse.site
        return AgentTool(
            definition: AgentToolDefinition(
                name: ForumToolName.searchForum,
                description: """
                Search the forum the user is on, or only the open topic, and show the hits on screen as numbered cards, best first. \
                Call it when the user asks to find, look for or search something, or asks whether anyone wrote about something. It \
                only shows cards: questions about what people think or recommend go to hand_off_to_agent. \
                Pass a few distinctive words in the forum's language (the topic brief says which): \(site.profile.findHint) \
                Scope "topic" searches inside the open topic \
                ("where did someone mention the firmware version"). The result lists the hits by number with title, author and a line. \
                If one hit clearly fits, call browse_open with its card number right away, without asking. If several could fit, say \
                the titles of the top two or three and let the user pick; they are on the cards. If nothing matched, say so and offer \
                other words. Never read out ids, post numbers in bulk or URLs.
                """,
                parameters: [
                    ToolParameterSchema(name: "query", type: .string, description: "A few distinctive search words, in the forum's language.", minLength: 1),
                    ToolParameterSchema(name: "scope", type: .string, description: "\"forum\" (default) or \"topic\" for the open topic only.", enumValues: ["forum", "topic"])
                ],
                required: ["query"]
            ),
            summarizeArguments: { $0["query"]?.stringValue ?? "" },
            execute: { args in
                let content = await browse.run { navigator in
                    await navigator.find(args["query"]?.textValue ?? "", scope: args["scope"]?.stringValue == "topic" ? .topic : .forum)
                }
                return ToolExecutionOutput(content: content)
            },
            surfaces: [.voice],
            spokenResult: browseSpokenResult
        )
    }

    private static func browseTool(
        _ name: String,
        browse: BrowseToolContext,
        body: @escaping @MainActor ([String: JSONValue], VoiceNavigator) async -> BrowseResult
    ) -> AgentTool {
        AgentTool(
            definition: browseDefinition(name, site: browse.site),
            summarizeArguments: { JSONValue.encodeCompactJSON($0) },
            execute: { args in
                ToolExecutionOutput(content: await browse.run { navigator in await body(args, navigator) })
            },
            surfaces: [.voice],
            spokenResult: browseSpokenResult
        )
    }

    /// `read_page` for voice: the structure only (`design-one-loop.md` "Voice").
    private static func voiceReadPageTool(bridge: AgentPageDriving) -> AgentTool {
        AgentTool(
            definition: AgentToolDefinition(
                name: "read_page",
                description: """
                Read the page on screen as a short structure list: headings, text, links and controls. Call it when the user asks \
                about a page that isn't a forum topic, or what is on screen. Answer only from what it returns.
                """,
                parameters: [
                    ToolParameterSchema(name: "selector", type: .string, description: "Optional CSS selector to read only part of the page.", minLength: 1)
                ]
            ),
            summarizeArguments: { $0["selector"]?.stringValue ?? "structure" },
            execute: { args in
                let content = try await bridge.readPage(mode: .structure, selector: args["selector"]?.stringValue, maxLength: spokenResultLimit)
                return ToolExecutionOutput(content: content, summary: "\(content.count) chars (structure)")
            },
            surfaces: [.voice]
        )
    }

    private static func browseDefinition(_ name: String, site: VoiceSite) -> AgentToolDefinition {
        switch name {
        case BrowseToolName.open:
            return AgentToolDefinition(
                name: name,
                description: """
                Open a topic and land on a post. Pass card for a card from the last search_forum or hand-off, or topic_id for a \
                topic whose id you got from a result; pass neither to stay in the open topic. at says where to land: "post" with \
                post, "solution" for the accepted answer, "last" for the newest post, "top" for the most liked posts, "unread" for \
                the first post the user hasn't seen. Call it at once when the user asks to go somewhere ("take me to the solution", \
                "open the second one", "show me the latest reply"); navigation can be undone, so don't ask first. The result says \
                what is on screen and carries the landing post's text. Tell the user in a few words where you are and give the \
                gist; the post is on screen, so don't read it out unless the result says reading is fine.
                """,
                parameters: [
                    ToolParameterSchema(name: "card", type: .integer, description: "A card number from the last search, like 2.", minimum: 1),
                    ToolParameterSchema(name: "topic_id", type: .string, description: "A topic id from a result. Leave out for the open topic."),
                    ToolParameterSchema(name: "at", type: .string, description: "Where to land.", enumValues: ["post", "solution", "last", "top", "unread"]),
                    ToolParameterSchema(name: "post", type: .integer, description: "The post number, with at \"post\".", minimum: 1)
                ]
            )
        case BrowseToolName.move:
            return AgentToolDefinition(
                name: name,
                description: """
                Move along the current list (the cards from the last search or focus) or around the open topic. action: "next" or \
                "previous" along the list, "back" or "forward" in the browser's history, "post" with post to go to post N of the \
                open topic, "top" for the first post, "bottom" for the last. Call it right away for "next", "go back", "post 37" or \
                "the first post". The result carries the post now on screen: say in a few words where you are and what it says, \
                without reading it out. At the end of the list, say so.
                """,
                parameters: [
                    ToolParameterSchema(name: "action", type: .string, description: "Where to move.", enumValues: ["next", "previous", "back", "forward", "post", "top", "bottom"]),
                    ToolParameterSchema(name: "post", type: .integer, description: "The post number, with action \"post\".", minimum: 1)
                ],
                required: ["action"]
            )
        case BrowseToolName.focus:
            // A site that cannot narrow to an author does not mention the author modes.
            let authors = site.offersAuthorFocus
                ? "\"user\" with user shows only that author's posts; \"op\" only the opening poster's; " : ""
            let examples = site.offersAuthorFocus
                ? "\"only what the original poster said\", \"just alice's posts\", \"show me the best answers\" or \"back to everything\""
                : "\"show me the best answers\" or \"back to everything\""
            var parameters = [ToolParameterSchema(name: "mode", type: .string, description: "What to show.", enumValues: site.focusModes)]
            if site.offersAuthorFocus {
                parameters.append(ToolParameterSchema(name: "user", type: .string, description: "The author's username, with mode \"user\"."))
            }
            parameters.append(ToolParameterSchema(name: "posts", type: .array, description: "Post numbers to highlight, with mode \"posts\".", itemsType: .integer))
            return AgentToolDefinition(
                name: name,
                description: """
                Narrow the open topic. mode: \(authors)\
                "top" the most liked posts; "posts" with posts highlights those posts as a tour, starting at the first; "clear" \
                shows the whole topic again. The focused posts become the current list, so "next" moves along them. Call it for \
                \(examples). \
                The result says how many posts there are and carries the first one's text: give the user the count and the gist.
                """,
                parameters: parameters,
                required: ["mode"]
            )
        default:
            return AgentToolDefinition(
                name: BrowseToolName.readPost,
                description: """
                Get the full text of a post in the open topic: post N, or the current post when post is left out; scope "visible" \
                returns every post on screen. Only call it when the user asks about a post whose text you haven't received in a \
                note or a tool result; posts you navigated to already came with their text. Answer only from what it returns, \
                never from a guess.
                """,
                parameters: [
                    ToolParameterSchema(name: "post", type: .integer, description: "The post number; leave out for the current post.", minimum: 1),
                    ToolParameterSchema(name: "scope", type: .string, description: "\"post\" (default) or \"visible\" for every post on screen.", enumValues: ["post", "visible"])
                ]
            )
        }
    }
}
