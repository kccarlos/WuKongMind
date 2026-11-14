import Foundation

// The voice session's tools come from the registry (`ToolRegistry.m3` with
// `surface: .voice`): its `.voice` tools, converted to Gemini Live function
// declarations, plus the two tools only voice has, `end` and
// `hand_off_to_agent`. The descriptions are prompt engineering: each says
// when to call the tool, what the result means and what to say next. They
// are written for the model, so they are English and not localized.
//
// Every tool is NON_BLOCKING: a BLOCKING call pauses the whole server
// stream (the user's transcript and the model's "let me check" stall until
// it is answered). Results come back with each tool's scheduling.

/// A parameter schema, in the subset Gemini Live accepts (spike Q1: no
/// `additionalProperties`; `minLength`, bounds, enums, integer arrays and
/// nested objects pass).
indirect enum VoiceSchema: Equatable {
    case string(description: String, options: [String]? = nil, minLength: Int? = nil)
    case integer(description: String, minimum: Double? = nil, maximum: Double? = nil)
    case number(description: String, minimum: Double? = nil, maximum: Double? = nil)
    case boolean(description: String)
    case array(of: VoiceSchema, description: String)
    case object(properties: [(name: String, schema: VoiceSchema)], required: [String])

    static func == (lhs: VoiceSchema, rhs: VoiceSchema) -> Bool {
        lhs.gemini == rhs.gemini
    }

    /// One registry parameter.
    init(_ parameter: ToolParameterSchema) {
        let description = parameter.description
        switch parameter.type {
        case .string: self = .string(description: description, options: parameter.enumValues, minLength: parameter.minLength)
        case .integer: self = .integer(description: description, minimum: parameter.minimum, maximum: parameter.maximum)
        case .number: self = .number(description: description, minimum: parameter.minimum, maximum: parameter.maximum)
        case .boolean: self = .boolean(description: description)
        case .object: self = .object(properties: [], required: [])
        case .array:
            let item: VoiceSchema = switch parameter.itemsType {
            case .integer: .integer(description: "An item.")
            case .number: .number(description: "An item.")
            case .boolean: .boolean(description: "An item.")
            default: .string(description: "An item.")
            }
            self = .array(of: item, description: description)
        }
    }

    /// A registry tool's parameters; nil for a tool without any, which then
    /// omits `parameters`.
    init?(_ definition: AgentToolDefinition) {
        guard !definition.parameters.isEmpty else { return nil }
        self = .object(properties: definition.parameters.map { ($0.name, VoiceSchema($0)) }, required: definition.required)
    }

    /// Gemini's OpenAPI subset (upper-case type names).
    var gemini: JSONValue {
        switch self {
        case .string(let description, let options, let minLength):
            var object: [String: JSONValue] = ["type": "STRING", "description": .string(description)]
            if let options { object["enum"] = .array(options.map(JSONValue.string)) }
            if let minLength { object["minLength"] = .int(Int64(minLength)) }
            return .object(object)
        case .integer(let description, let minimum, let maximum):
            return Self.bounded(["type": "INTEGER", "description": .string(description)], minimum, maximum)
        case .number(let description, let minimum, let maximum):
            return Self.bounded(["type": "NUMBER", "description": .string(description)], minimum, maximum)
        case .boolean(let description):
            return ["type": "BOOLEAN", "description": .string(description)]
        case .array(let item, let description):
            return ["type": "ARRAY", "items": item.gemini, "description": .string(description)]
        case .object(let properties, let required):
            var object: [String: JSONValue] = [
                "type": "OBJECT",
                "properties": .object(Dictionary(properties.map { ($0.name, $0.schema.gemini) }, uniquingKeysWith: { a, _ in a }))
            ]
            if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
            return .object(object)
        }
    }

    private static func bounded(_ object: [String: JSONValue], _ minimum: Double?, _ maximum: Double?) -> JSONValue {
        var object = object
        func number(_ value: Double) -> JSONValue { value.rounded() == value ? .int(Int64(value)) : .double(value) }
        if let minimum { object["minimum"] = number(minimum) }
        if let maximum { object["maximum"] = number(maximum) }
        return .object(object)
    }
}

/// The tools only voice has; everything else comes from the registry.
enum VoiceTool: String, CaseIterable {
    case end
    case handOffToAgent = "hand_off_to_agent"

    /// Both answer silently: `hand_off_to_agent` says `started`, and its answer
    /// comes later as a WHEN_IDLE briefing (VoiceToolBridge).
    var scheduling: GeminiLive.Scheduling { .silent }

    /// The prompt text of the tool.
    var description: String {
        switch self {
        case .handOffToAgent:
            return """
            Hand a request to WukongMind's Agent, which reads across several threads or a long thread and answers with sources, \
            and which can change the page (dark mode, hiding parts of it). Use it for questions about what people think or \
            recommend, for anything that needs several threads, and for every change to the page; never for something \
            search_forum, browse_open, browse_move, browse_focus or read_post can do. Before calling it, say one short \
            acknowledgement in your own words, once. It answers "started" at once and runs in the background; one hand-off runs \
            at a time, and a new request replaces the running one. The answer arrives later as a briefing: open with the answer. \
            action "cancel" stops it when the user says never mind.
            """
        case .end:
            return """
            End the voice conversation, when the user says goodbye, that's all, or asks you to stop listening. Say a short \
            goodbye first, then call it.
            """
        }
    }

    var parameters: VoiceSchema? {
        switch self {
        case .handOffToAgent:
            return .object(properties: [
                ("request", .string(description: "The user's request, complete, in their words.")),
                ("action", .string(description: "\"start\" (default) or \"cancel\".", options: ["start", "cancel"]))
            ], required: [])
        case .end:
            return nil
        }
    }

    var declaration: GeminiLive.FunctionDeclaration {
        GeminiLive.FunctionDeclaration(name: rawValue, description: description, parameters: parameters?.gemini, behavior: .nonBlocking)
    }
}

/// The converter from the registry to Gemini Live (`design-one-loop.md`
/// "Voice"): upper-case types, no `additionalProperties`.
enum VoiceDeclarations {
    static func declaration(_ definition: AgentToolDefinition) -> GeminiLive.FunctionDeclaration {
        GeminiLive.FunctionDeclaration(
            name: definition.name,
            description: definition.description,
            parameters: VoiceSchema(definition)?.gemini,
            behavior: .nonBlocking
        )
    }

    /// What a session declares: the voice registry's tools, then `end` and `hand_off_to_agent`.
    static func all(registry: ToolRegistry) -> [GeminiLive.FunctionDeclaration] {
        registry.definitions.map(declaration) + VoiceTool.allCases.map(\.declaration)
    }
}
