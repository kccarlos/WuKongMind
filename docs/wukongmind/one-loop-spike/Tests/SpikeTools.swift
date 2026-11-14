import Foundation

// The app's VoiceSite pulls in SiteRegistry; the spike needs only these two values.
struct VoiceSiteProfile: Sendable, Equatable {
    var persona: String
    var findHint: String
    var languageHint: String
    static let discourse = VoiceSiteProfile(
        persona: "a reading companion for Discourse forums",
        findHint: "Search matches words, so search a forum in its own language even when the user speaks another language.",
        languageHint: "Search matches words, so a question in another language is searched with words in the forum's language."
    )
}

struct VoiceSite: Sendable, Equatable {
    var profile: VoiceSiteProfile
    var focusModes = ["user", "op", "top", "posts", "clear"]
    var offersAuthorFocus: Bool { focusModes.contains("user") }
}

enum VoiceAnswerLength { case short, normal, detailed }

/// Draft One loop tool definitions in exactly the JSON Schema shape `AgentToolDefinition.inputSchema`
/// emits (lower-case types, `additionalProperties: false`, `minLength`, `minimum`/`maximum`).
/// Tasks 2, 4 and 10 haven't merged, so the forum, capability and browse texts are drafted here.
enum SpikeTools {
    static let site = VoiceSite(profile: .discourse)

    typealias P = (name: String, type: String, description: String, extra: [String: JSONValue])

    static func p(_ name: String, _ type: String, _ description: String, _ extra: [String: JSONValue] = [:]) -> P {
        (name, type, description, extra)
    }

    /// One `AgentToolDefinition` as name, description and inputSchema.
    static func tool(_ name: String, _ description: String, _ params: [P], required: [String] = []) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for param in params {
            var object: [String: JSONValue] = ["type": .string(param.type), "description": .string(param.description)]
            for (key, value) in param.extra { object[key] = value }
            properties[param.name] = .object(object)
        }
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return ["name": .string(name), "description": .string(description), "inputSchema": .object(schema)]
    }

    static func appText(_ tool: VoiceTool) -> String {
        var text = tool.description(for: site)
        for (old, new) in [
            ("call open", "call browse_open"), ("the last find or research", "the last search_forum or hand_off_to_agent"),
            ("the last find, research or focus", "the last search_forum, hand_off_to_agent or browse_focus"),
            ("find, open, move, focus or read", "the browse tools")
        ] { text = text.replacingOccurrences(of: old, with: new) }
        return text
    }

    static let topicID = p("topic_id", "string", "A thread id on this forum, from a result. Leave out for the open thread.", ["minLength": 1])
    static let url = p("url", "string", "A thread URL on a forum the app can read.", ["minLength": 1])
    static let page = p("page", "integer", "A page of the thread, from 1.", ["minimum": 1, "maximum": 1000])

    /// The twelve voice tools of the design (four browse, six shared, two voice-only).
    static let voice: [JSONValue] = [
        tool("browse_open", appText(.open), [
            p("card", "integer", "A card number from the last search_forum or hand-off, like 2.", ["minimum": 1, "maximum": 50]),
            topicID,
            p("at", "string", "Where to land.", ["enum": ["post", "solution", "last", "top", "unread"]]),
            p("post", "integer", "The post number, with at \"post\".", ["minimum": 1])
        ]),
        tool("browse_move", appText(.move), [
            p("action", "string", "Where to move.", ["enum": ["next", "previous", "back", "forward", "post", "top", "bottom"]]),
            p("post", "integer", "The post number, with action \"post\".", ["minimum": 1])
        ], required: ["action"]),
        tool("browse_focus", appText(.focus), [
            p("mode", "string", "What to show.", ["enum": ["user", "op", "top", "posts", "clear"]]),
            p("user", "string", "The author's username, with mode \"user\".", ["minLength": 1]),
            p("posts", "array", "Post numbers to highlight, with mode \"posts\".", ["items": ["type": "integer"]])
        ], required: ["mode"]),
        tool("read_post", appText(.read).replacingOccurrences(of: "Get the full text", with: "Get the full text (voice only)"), [
            p("post", "integer", "The post number; leave out for the current post.", ["minimum": 1]),
            p("scope", "string", "\"post\" (default) or \"visible\" for every post on screen.", ["enum": ["post", "visible"]])
        ]),
        tool("read_page", "Read the current web page as a condensed structure summary ('structure'), visible plain text ('text'), or raw HTML ('html'). Prefer 'structure' first.", [
            p("mode", "string", "Output format: 'structure' (default), 'text', or 'html'.", ["enum": ["structure", "text", "html"]]),
            p("selector", "string", "Optional CSS selector to scope reading to a matching subtree.", ["minLength": 1]),
            p("max_length", "integer", "Optional maximum character count to return before truncation.", ["minimum": 1, "maximum": 500_000])
        ]),
        tool("search_forum", appText(.find), [
            p("query", "string", "A few distinctive search words, in the forum's language.", ["minLength": 1]),
            p("scope", "string", "\"forum\" (default) or \"topic\" for the open thread only.", ["enum": ["forum", "topic"]]),
            page
        ], required: ["query"]),
        tool("read_topic", "Read a thread's posts as text: the beginning and the newest replies, or one page, or only posts matching query. A long thread is saved to a file.", [
            topicID, url, page, p("query", "string", "Only posts matching these words.", ["minLength": 1])
        ]),
        tool("summarize_topic", "Summarize a thread (topic_id or url, cached, only new replies are summarized), a workspace file (path) or text. Returns the summary with #N post citations; the summary card shows on screen.", [
            topicID, url, p("path", "string", "A workspace file.", ["minLength": 1]), p("text", "string", "Text to summarize.", ["minLength": 1])
        ]),
        tool("read_aloud", "Read one text aloud with the podcast player: text, a workspace file, or a thread's summary (summarizing first if there is none). Returns at once with the length.", [
            topicID, url, p("path", "string", "A workspace file.", ["minLength": 1]), p("text", "string", "The text to read.", ["minLength": 1])
        ]),
        tool("watch_topic", "Follow a thread so the user is notified of new replies. Never unfollows.", [topicID, url]),
        tool("end", appText(.end), []),
        tool("hand_off_to_agent", """
        Hand a request to WukongMind's Agent, which reads across several threads or a long thread, changes the page \
        (dark mode, hiding things, bigger text) and answers with sources in the conversation. Use it for questions that \
        need reasoning across many posts or threads and for every change to the page, never for something the browse \
        tools or search_forum can do. Before calling it, say one short acknowledgement in your own words, once. It \
        answers "started" at once and runs in the background; one hand-off runs at a time. The answer arrives later as a \
        briefing: open with the answer. action "cancel" stops it when the user says never mind.
        """, [
            p("request", "string", "The user's request, complete, in their words.", ["minLength": 1]),
            p("action", "string", "\"start\" (default) or \"cancel\".", ["enum": ["start", "cancel"]])
        ])
    ]

    static let injectCSS = tool("inject_css", "Inject or update CSS rules on the current page (and open shadow roots) via CSSStyleSheet and adoptedStyleSheets, bypassing inline style-src CSP restrictions. Pass 'id' to update an earlier stylesheet in place without duplicating rules.", [
        p("css", "string", "CSS rules to apply to the current document.", ["minLength": 1]),
        p("id", "string", "Optional stylesheet identifier for updating an injected stylesheet in place.", ["minLength": 1])
    ], required: ["css"])

    /// Fifteen: the upper bound of the design's 12 to 15.
    static let fifteen: [JSONValue] = voice + [
        tool("list_latest", "List the forum's latest threads.", [page]),
        tool("search_comments", "Search comments across the site (Hacker News, WordPress).", [
            p("query", "string", "Search words.", ["minLength": 1]), page
        ], required: ["query"]),
        injectCSS
    ]

    // MARK: Converter (the candidate for task 10)

    /// Keywords the converter drops. Q1's probes decide which Gemini Live refuses.
    static var dropped: Set<String> = ["additionalProperties"]

    /// JSON Schema (lower-case types) to Gemini's OpenAPI subset (upper-case), recursively.
    static func gemini(_ schema: JSONValue) -> JSONValue {
        guard case .object(var object) = schema else { return schema }
        for key in dropped { object[key] = nil }
        if case .string(let type)? = object["type"] { object["type"] = .string(type.uppercased()) }
        if let items = object["items"] { object["items"] = gemini(items) }
        if case .object(let properties)? = object["properties"] { object["properties"] = .object(properties.mapValues(gemini)) }
        return .object(object)
    }

    /// One Gemini Live function declaration (NON_BLOCKING like every voice tool today). A tool
    /// without parameters gets no `parameters` (an empty OBJECT is one of Q1's probes).
    static func declaration(_ tool: JSONValue, raw: Bool = false) -> JSONValue {
        guard case .object(let object) = tool, case .object(let schema)? = object["inputSchema"] else { return tool }
        var declaration: [String: JSONValue] = ["name": object["name"]!, "description": object["description"]!, "behavior": "NON_BLOCKING"]
        let empty = schema["properties"]?.objectValue?.isEmpty ?? true
        if !empty { declaration["parameters"] = raw ? .object(schema) : gemini(.object(schema)) }
        return .object(declaration)
    }

    /// Today's seven tools, exactly as the app declares them.
    static var today: [JSONValue] {
        let data = try! JSONEncoder().encode(VoiceTool.geminiDeclarations(for: site))
        return try! JSONDecoder().decode([JSONValue].self, from: data)
    }

    // MARK: Instructions

    /// Today's instruction with the research and precedence parts rewritten for the One loop names.
    static func instructions(directCSS: Bool = false) -> String {
        let profile = site.profile
        let precedence = """
        Use browse_open, browse_move, browse_focus, read_post and search_forum first; they work at once and take \
        precedence over the hand-off. "Next", "go back", "post 37", "take me to the solution", "only the original \
        poster" and "search for X" are browser actions: do them yourself. summarize_topic, read_aloud and watch_topic \
        are yours too: "summarize this", "read it to me" and "follow this thread" need no hand-off.
        """
        let handOff = directCSS
            ? "For a visual change to the page (dark mode, bigger text), call read_page if you need the structure, then inject_css yourself. Call hand_off_to_agent for questions that need several threads or reasoning across a long thread. Before you call it, say one short acknowledgement, once. The answer comes back later as a briefing; when it does, open straight with the answer."
            : "Call hand_off_to_agent for questions that need several threads or reasoning across a long thread, and for every change to the page, such as dark mode, hiding something or bigger text. Before you call it, say one short acknowledgement, in your own words and different each time, and say it only once. The answer comes back later as a briefing; when it does, open straight with the answer."
        let grounding = VoiceInstructions.grounding.replacingOccurrences(of: "call read;", with: "call read_post;")
        return [
            VoiceInstructions.persona(.init(persona: profile.persona, findHint: profile.findHint, languageHint: profile.languageHint)),
            VoiceInstructions.speech, VoiceInstructions.screen, precedence, handOff, grounding, VoiceInstructions.notes,
            VoiceInstructions.eyesFreeOff, VoiceInstructions.answerLength(.short),
            "The user is on the forum Home Lab Talk."
        ].joined(separator: "\n\n")
    }

    static var todayInstructions: String {
        VoiceInstructions.system(answerLength: .short, eyesFree: false, forumName: "Home Lab Talk", site: .discourse)
    }

    static let screenNote = """
    [Screen: the user opened the topic “Fan noise after firmware 5.2” (topic id 4821) on Home Lab Talk, 84 posts, \
    with an accepted solution at post 37. At post 12 by alice: "Same here, the fan ramps to full speed every few \
    minutes since 5.2." Cards: none.]
    """
}
