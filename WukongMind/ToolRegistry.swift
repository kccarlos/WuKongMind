import CoreFoundation
import Foundation

// MARK: - JSONValue Helpers for Tool Schemas & Validation

extension JSONValue {
    /// Converts a Foundation JSON object (`JSONSerialization`) into `JSONValue`
    /// while preserving `CFBoolean` vs numeric `NSNumber`.
    static func fromFoundation(_ any: Any) throws -> JSONValue {
        if any is NSNull {
            return .null
        }
        if let string = any as? String {
            return .string(string)
        }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let doubleVal = number.doubleValue
            if doubleVal.isFinite,
               doubleVal.rounded(.towardZero) == doubleVal,
               doubleVal >= Double(Int64.min),
               doubleVal <= Double(Int64.max) {
                return .int(number.int64Value)
            }
            return .double(doubleVal)
        }
        if let array = any as? [Any] {
            return .array(try array.map { try fromFoundation($0) })
        }
        if let dict = any as? [String: Any] {
            var mapped: [String: JSONValue] = [:]
            mapped.reserveCapacity(dict.count)
            for (key, val) in dict {
                mapped[key] = try fromFoundation(val)
            }
            return .object(mapped)
        }
        throw ToolValidationError("Unsupported JSON value of type \(type(of: any)).")
    }

    func toFoundation() -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return NSNumber(value: value)
        case .double(let value):
            return NSNumber(value: value)
        case .string(let value):
            return value
        case .array(let items):
            return items.map { $0.toFoundation() }
        case .object(let dict):
            return dict.mapValues { $0.toFoundation() }
        }
    }

    static func encodeCompactJSON(_ dict: [String: JSONValue]) -> String {
        let obj = JSONValue.object(dict).toFoundation()
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func parseObjectJSON(_ jsonString: String) throws -> [String: JSONValue] {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [:]
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw ToolValidationError("Arguments are not valid UTF-8 JSON.")
        }
        let decoded: JSONValue
        do {
            decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ToolValidationError("Malformed JSON arguments: \(error.localizedDescription)")
        }
        guard case .object(let dict) = decoded else {
            throw ToolValidationError("Tool arguments must be a JSON object.")
        }
        return dict
    }

    var strictBoolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var strictArrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// Strict integer extraction (does not coerce `"37"` strings or booleans).
    var strictIntValue: Int? {
        switch self {
        case .int(let value):
            return Int(exactly: value)
        case .double(let value) where value.isFinite && value.rounded(.towardZero) == value
            && value >= Double(Int.min) && value <= Double(Int.max):
            return Int(value)
        default:
            return nil
        }
    }

    /// Strict numeric extraction (does not coerce `"3.5"` strings or booleans).
    var strictDoubleValue: Double? {
        switch self {
        case .int(let value):
            return Double(value)
        case .double(let value):
            return value
        default:
            return nil
        }
    }

    var typeDescription: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

// MARK: - Tool Schema & Definitions

enum ToolParameterType: String, Equatable, Sendable {
    case string
    case integer
    case number
    case boolean
    case array
    case object
}

struct ToolParameterSchema: Equatable, Sendable {
    var name: String
    var type: ToolParameterType
    var description: String
    var enumValues: [String]?
    var itemsType: ToolParameterType?
    var minLength: Int?
    var minimum: Double?
    var maximum: Double?

    init(
        name: String,
        type: ToolParameterType,
        description: String,
        enumValues: [String]? = nil,
        itemsType: ToolParameterType? = nil,
        minLength: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.itemsType = itemsType
        self.minLength = minLength
        self.minimum = minimum
        self.maximum = maximum
    }

    func toJSONSchemaObject() -> [String: JSONValue] {
        var obj: [String: JSONValue] = [
            "type": .string(type.rawValue),
            "description": .string(description)
        ]
        if let enumValues {
            obj["enum"] = .array(enumValues.map(JSONValue.string))
        }
        if let itemsType {
            obj["items"] = .object(["type": .string(itemsType.rawValue)])
        }
        if let minLength {
            obj["minLength"] = .int(Int64(minLength))
        }
        if let minimum {
            if minimum.rounded(.towardZero) == minimum {
                obj["minimum"] = .int(Int64(minimum))
            } else {
                obj["minimum"] = .double(minimum)
            }
        }
        if let maximum {
            if maximum.rounded(.towardZero) == maximum {
                obj["maximum"] = .int(Int64(maximum))
            } else {
                obj["maximum"] = .double(maximum)
            }
        }
        return obj
    }
}

struct AgentToolDefinition: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var parameters: [ToolParameterSchema]
    var required: [String]
    var additionalProperties: Bool

    init(
        name: String,
        description: String,
        parameters: [ToolParameterSchema],
        required: [String] = [],
        additionalProperties: Bool = false
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.required = required
        self.additionalProperties = additionalProperties
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }

    /// Encodes as name, description and `inputSchema`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let description = try container.decode(String.self, forKey: .description)
        let schema = try container.decode([String: JSONValue].self, forKey: .inputSchema)
        var parameters: [ToolParameterSchema] = []
        if case .object(let properties)? = schema["properties"] {
            for key in properties.keys.sorted() {
                guard case .object(let spec) = properties[key] else { continue }
                var typeName = "string"
                if case .string(let text)? = spec["type"] { typeName = text }
                var detail = ""
                if case .string(let text)? = spec["description"] { detail = text }
                var enumValues: [String]?
                if case .array(let items)? = spec["enum"] {
                    enumValues = items.compactMap { if case .string(let text) = $0 { text } else { nil } }
                }
                var itemsType: ToolParameterType?
                if case .object(let items)? = spec["items"], case .string(let text)? = items["type"] {
                    itemsType = ToolParameterType(rawValue: text)
                }
                func number(_ value: JSONValue?) -> Double? {
                    switch value {
                    case .int(let number)?: Double(number)
                    case .double(let number)?: number
                    default: nil
                    }
                }
                parameters.append(ToolParameterSchema(
                    name: key,
                    type: ToolParameterType(rawValue: typeName) ?? .string,
                    description: detail,
                    enumValues: enumValues,
                    itemsType: itemsType,
                    minLength: number(spec["minLength"]).map { Int($0) },
                    minimum: number(spec["minimum"]),
                    maximum: number(spec["maximum"])
                ))
            }
        }
        var required: [String] = []
        if case .array(let items)? = schema["required"] {
            required = items.compactMap { if case .string(let text) = $0 { text } else { nil } }
        }
        var extra = false
        if case .bool(let flag)? = schema["additionalProperties"] { extra = flag }
        self.init(name: name, description: description, parameters: parameters, required: required, additionalProperties: extra)
    }

    /// Standard JSON Schema object (`type: "object"`, `properties`, `required`,
    /// `additionalProperties`) accepted by Anthropic, OpenAI, and Ollama.
    var inputSchema: [String: JSONValue] {
        var properties: [String: JSONValue] = [:]
        for parameter in parameters {
            properties[parameter.name] = .object(parameter.toJSONSchemaObject())
        }
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(additionalProperties)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(JSONValue.string))
        }
        return schema
    }
}

struct ToolValidationError: LocalizedError, Equatable, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

// MARK: - Untrusted Content Delimiters & Secret Scrubbing

enum UntrustedWebContent {
    static let openingTagPrefix = "<untrusted_web_content"
    static let closingTag = "</untrusted_web_content>"

    /// Redacts any configured non-empty API keys from tool output so secrets
    /// never leak into tool results or UI logs.
    static func redactSecrets(in text: String, secrets: [String]) -> String {
        guard !text.isEmpty, !secrets.isEmpty else { return text }
        var scrubbed = text
        for rawSecret in secrets {
            let trimmed = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if scrubbed.contains(trimmed) {
                scrubbed = scrubbed.replacingOccurrences(of: trimmed, with: "[REDACTED_API_KEY]")
            }
        }
        return scrubbed
    }

    /// Escapes any literal `<untrusted_web_content` or `</untrusted_web_content>`
    /// tokens inside page text before wrapping so page content cannot break out
    /// of the untrusted delimiter block.
    static func wrap(_ text: String, toolName: String, secrets: [String] = []) -> String {
        let scrubbed = redactSecrets(in: text, secrets: secrets)
        let escaped = scrubbed
            .replacingOccurrences(
                of: "</untrusted_web_content>",
                with: "<\\/untrusted_web_content>",
                options: [.caseInsensitive]
            )
            .replacingOccurrences(
                of: "<untrusted_web_content",
                with: "<\\untrusted_web_content",
                options: [.caseInsensitive]
            )
        return """
        <untrusted_web_content tool="\(toolName)">
        \(escaped)
        </untrusted_web_content>
        """
    }
}

// MARK: - Tool Execution & Dispatch

struct ToolExecutionOutput: Equatable, Sendable {
    var content: String
    var summary: String
    var isError: Bool
    /// The workspace file the tool saved its full output to (`save_to`).
    var savedPath: String?
    /// The tool already cut its output to a range (`file_read`), so the
    /// registry neither saves nor truncates it.
    var isRanged: Bool

    init(
        content: String,
        summary: String? = nil,
        isError: Bool = false,
        savedPath: String? = nil,
        isRanged: Bool = false
    ) {
        self.content = content
        self.summary = summary ?? Self.defaultSummary(for: content)
        self.isError = isError
        self.savedPath = savedPath
        self.isRanged = isRanged
    }

    static func defaultSummary(for text: String, maxChars: Int = 96) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if firstLine.isEmpty { return "(empty)" }
        if firstLine.count <= maxChars { return firstLine }
        return String(firstLine.prefix(maxChars)) + "…"
    }
}

struct AgentTool: Sendable {
    var definition: AgentToolDefinition
    var customValidate: (@Sendable ([String: JSONValue]) throws -> Void)?
    var summarizeArguments: @Sendable ([String: JSONValue]) -> String
    var execute: @Sendable ([String: JSONValue]) async throws -> ToolExecutionOutput
}

struct ToolDispatchResult: Equatable, Sendable {
    var toolName: String
    var argumentSummary: String
    var argumentsJSON: String
    /// Secret-redacted and length-truncated tool output (for UI inspection & assertions).
    var output: String
    /// Compact one-line summary for the collapsed tool-call row.
    var resultSummary: String
    /// `output` wrapped in `<untrusted_web_content>` delimiters for the model.
    var modelContent: String
    var isError: Bool
    var wasTruncated: Bool
    var totalCharacterCount: Int
    var duration: TimeInterval
    /// Where the full output went when it was saved to the workspace (over the
    /// limit, or `save_to`); `output` then holds the notice and preview.
    var savedPath: String? = nil
}

/// Validates tool arguments against JSON Schema, dispatches tool calls, converts
/// non-cancellation failures into error tool results, redacts any configured API
/// keys, and truncates outputs over `truncationLimit`.
struct ToolRegistry: Sendable {
    static let defaultTruncationLimit = 20_000

    private var toolsByName: [String: AgentTool] = [:]
    private var orderedNames: [String] = []
    var truncationLimit: Int
    var redactedSecrets: [String]
    /// Where output over the limit is saved (`results/<task-id>/`). Without a
    /// workspace or a task ID, output is truncated and marked instead.
    var workspace: AgentWorkspace?
    var taskID: String?

    init(
        tools: [AgentTool] = [],
        truncationLimit: Int = ToolRegistry.defaultTruncationLimit,
        redactedSecrets: [String] = [],
        workspace: AgentWorkspace? = nil
    ) {
        self.truncationLimit = max(1, truncationLimit)
        self.redactedSecrets = redactedSecrets
        self.workspace = workspace
        for tool in tools {
            register(tool)
        }
    }

    mutating func register(_ tool: AgentTool) {
        let name = tool.definition.name
        if toolsByName[name] == nil {
            orderedNames.append(name)
        }
        toolsByName[name] = tool
    }

    var definitions: [AgentToolDefinition] {
        orderedNames.compactMap { toolsByName[$0]?.definition }
    }

    func tool(named name: String) -> AgentTool? {
        toolsByName[name]
    }

    /// Validates `arguments` against `tool`'s JSON schema and custom rules.
    func validateArguments(_ arguments: [String: JSONValue], for toolName: String) throws {
        guard let tool = toolsByName[toolName] else {
            throw ToolValidationError("Unknown tool '\(toolName)'.")
        }
        let def = tool.definition

        for requiredKey in def.required {
            guard let val = arguments[requiredKey], val != .null else {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': missing required parameter '\(requiredKey)'."
                )
            }
        }

        let parametersByName = Dictionary(
            uniqueKeysWithValues: def.parameters.map { ($0.name, $0) }
        )

        if !def.additionalProperties {
            for key in arguments.keys.sorted() where parametersByName[key] == nil {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': unknown parameter '\(key)'."
                )
            }
        }

        for parameter in def.parameters {
            guard let rawValue = arguments[parameter.name], rawValue != .null else {
                continue
            }
            try Self.validateValue(rawValue, against: parameter, toolName: toolName)
        }

        if let customValidate = tool.customValidate {
            try customValidate(arguments)
        }
    }

    private static func validateValue(
        _ value: JSONValue,
        against schema: ToolParameterSchema,
        toolName: String
    ) throws {
        switch schema.type {
        case .string:
            guard case .string(let str) = value else {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': parameter '\(schema.name)' must be a string, got \(value.typeDescription)."
                )
            }
            if let minLength = schema.minLength, str.count < minLength {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': parameter '\(schema.name)' must be at least \(minLength) character(s)."
                )
            }
            if let enumValues = schema.enumValues, !enumValues.contains(str) {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': parameter '\(schema.name)' must be one of [\(enumValues.joined(separator: ", "))], got '\(str)'."
                )
            }

        case .integer:
            guard let intVal = value.strictIntValue else {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': parameter '\(schema.name)' must be an integer, got \(value.typeDescription)."
                )
            }
            try validateNumericBounds(Double(intVal), schema: schema, toolName: toolName)

        case .number:
            guard let numVal = value.strictDoubleValue, numVal.isFinite else {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': parameter '\(schema.name)' must be a number, got \(value.typeDescription)."
                )
            }
            try validateNumericBounds(numVal, schema: schema, toolName: toolName)

        case .boolean:
            guard case .bool = value else {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': parameter '\(schema.name)' must be a boolean, got \(value.typeDescription)."
                )
            }

        case .array:
            guard case .array(let elements) = value else {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': parameter '\(schema.name)' must be an array, got \(value.typeDescription)."
                )
            }
            if let itemsType = schema.itemsType {
                let elementSchema = ToolParameterSchema(
                    name: "\(schema.name)[]",
                    type: itemsType,
                    description: "element of \(schema.name)"
                )
                for element in elements {
                    try validateValue(element, against: elementSchema, toolName: toolName)
                }
            }

        case .object:
            guard case .object = value else {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': parameter '\(schema.name)' must be an object, got \(value.typeDescription)."
                )
            }
        }
    }

    private static func validateNumericBounds(
        _ number: Double,
        schema: ToolParameterSchema,
        toolName: String
    ) throws {
        if let minimum = schema.minimum, number < minimum {
            throw ToolValidationError(
                "Invalid arguments for '\(toolName)': parameter '\(schema.name)' must be >= \(formatBound(minimum)), got \(formatBound(number))."
            )
        }
        if let maximum = schema.maximum, number > maximum {
            throw ToolValidationError(
                "Invalid arguments for '\(toolName)': parameter '\(schema.name)' must be <= \(formatBound(maximum)), got \(formatBound(number))."
            )
        }
    }

    private static func formatBound(_ value: Double) -> String {
        if value.rounded(.towardZero) == value,
           value >= Double(Int.min),
           value <= Double(Int.max) {
            return String(Int(value))
        }
        return String(value)
    }

    /// Truncates `text` when it exceeds `limit`, marking `"truncated, N characters in total"`.
    static func truncate(_ text: String, limit: Int) -> (text: String, wasTruncated: Bool, totalCount: Int) {
        let effectiveLimit = max(1, limit)
        let total = text.count
        guard total > effectiveLimit else {
            return (text, false, total)
        }
        let prefix = String(text.prefix(effectiveLimit))
        let truncated = "\(prefix)\n...[truncated, \(total) characters in total]"
        return (truncated, true, total)
    }

    /// Summarizes arguments for a UI row even before execution finishes.
    func argumentSummary(for toolName: String, arguments: [String: JSONValue]) -> String {
        guard let tool = toolsByName[toolName] else {
            return JSONValue.encodeCompactJSON(arguments)
        }
        return tool.summarizeArguments(arguments)
    }

    /// Dispatches a tool call using raw JSON string arguments, catching JSON
    /// parse errors as error results rather than throwing.
    func dispatch(toolName: String, rawArgumentsJSON: String, step: Int? = nil) async throws -> ToolDispatchResult {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let parsed: [String: JSONValue]
        do {
            parsed = try JSONValue.parseObjectJSON(rawArgumentsJSON)
        } catch {
            let duration = Self.secondsElapsed(since: started)
            return await makeResult(
                toolName: toolName,
                argumentSummary: ToolExecutionOutput.defaultSummary(for: rawArgumentsJSON, maxChars: 64),
                argumentsJSON: rawArgumentsJSON,
                rawOutput: error.localizedDescription,
                summary: error.localizedDescription,
                isError: true,
                duration: duration
            )
        }
        return try await dispatch(toolName: toolName, arguments: parsed, step: step)
    }

    /// Validates and executes `toolName`. Validation failures and tool runtime
    /// errors return `ToolDispatchResult(..., isError: true)` without throwing;
    /// `CancellationError` rethrows immediately so `stop()` halts the loop at once.
    /// `step` names the file an over-limit result is saved to.
    func dispatch(toolName: String, arguments: [String: JSONValue], step: Int? = nil) async throws -> ToolDispatchResult {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let argsJSON = JSONValue.encodeCompactJSON(arguments)

        guard let tool = toolsByName[toolName] else {
            let message = "Unknown tool '\(toolName)'. Available tools: \(orderedNames.joined(separator: ", "))."
            return await makeResult(
                toolName: toolName,
                argumentSummary: argsJSON,
                argumentsJSON: argsJSON,
                rawOutput: message,
                summary: message,
                isError: true,
                duration: Self.secondsElapsed(since: started)
            )
        }

        let argSummary = tool.summarizeArguments(arguments)

        do {
            try validateArguments(arguments, for: toolName)
            let execution = try await tool.execute(arguments)
            try Task.checkCancellation()
            return await makeResult(
                toolName: toolName,
                argumentSummary: argSummary,
                argumentsJSON: argsJSON,
                rawOutput: execution.content,
                summary: execution.summary,
                isError: execution.isError,
                duration: Self.secondsElapsed(since: started),
                savedPath: execution.savedPath,
                isRanged: execution.isRanged,
                step: step
            )
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            let message = error.localizedDescription
            return await makeResult(
                toolName: toolName,
                argumentSummary: argSummary,
                argumentsJSON: argsJSON,
                rawOutput: "Error: \(message)",
                summary: "Error: \(ToolExecutionOutput.defaultSummary(for: message, maxChars: 80))",
                isError: true,
                duration: Self.secondsElapsed(since: started)
            )
        }
    }

    private func makeResult(
        toolName: String,
        argumentSummary: String,
        argumentsJSON: String,
        rawOutput: String,
        summary: String,
        isError: Bool,
        duration: TimeInterval,
        savedPath: String? = nil,
        isRanged: Bool = false,
        step: Int? = nil
    ) async -> ToolDispatchResult {
        let scrubbedOutput = UntrustedWebContent.redactSecrets(in: rawOutput, secrets: redactedSecrets)
        let scrubbedSummary = UntrustedWebContent.redactSecrets(in: summary, secrets: redactedSecrets)
        var finalOutput = scrubbedOutput
        var wasTruncated = false
        var totalCount = scrubbedOutput.count
        var finalSummary = scrubbedSummary
        var finalSavedPath = savedPath
        if !isRanged, totalCount > truncationLimit {
            if let workspace, let taskID,
               let saved = try? await Self.saveOutput(
                   scrubbedOutput,
                   to: Self.resultPath(taskID: taskID, step: step, toolName: toolName),
                   workspace: workspace,
                   previewLength: Self.savedResultPreviewLength
               ) {
                finalOutput = saved.notice
                finalSavedPath = saved.path
                finalSummary = "\(scrubbedSummary) (saved to \(saved.path))"
            } else {
                (finalOutput, wasTruncated, totalCount) = Self.truncate(scrubbedOutput, limit: truncationLimit)
                finalSummary = "\(scrubbedSummary) (truncated, \(totalCount) chars total)"
            }
        }
        let wrapped = UntrustedWebContent.wrap(
            finalOutput,
            toolName: toolName,
            secrets: redactedSecrets
        )
        return ToolDispatchResult(
            toolName: toolName,
            argumentSummary: argumentSummary,
            argumentsJSON: argumentsJSON,
            output: finalOutput,
            resultSummary: finalSummary,
            modelContent: wrapped,
            isError: isError,
            wasTruncated: wasTruncated,
            totalCharacterCount: totalCount,
            duration: duration,
            savedPath: finalSavedPath
        )
    }

    private static func secondsElapsed(since start: ContinuousClock.Instant) -> TimeInterval {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000.0
    }
}

// MARK: - M1 Page Tools Factory

extension ToolRegistry {
    /// Builds a `ToolRegistry` preloaded with the four M1 browser tools:
    /// `read_page`, `run_js`, `inject_css`, and `wait_for`.
    static func m1(
        bridge: AgentPageDriving,
        truncationLimit: Int = ToolRegistry.defaultTruncationLimit,
        redactedSecrets: [String] = []
    ) -> ToolRegistry {
        ToolRegistry(
            tools: [
                makeReadPageTool(bridge: bridge),
                makeRunJSTool(bridge: bridge),
                makeInjectCSSTool(bridge: bridge),
                makeWaitForTool(bridge: bridge)
            ],
            truncationLimit: truncationLimit,
            redactedSecrets: redactedSecrets
        )
    }

    private static func makeReadPageTool(
        bridge: AgentPageDriving,
        workspace: AgentWorkspace? = nil,
        secrets: [String] = []
    ) -> AgentTool {
        var definition = AgentToolDefinition(
            name: "read_page",
            description: """
            Read the current web page as a condensed structure summary ('structure'), \
            visible plain text ('text'), or raw HTML ('html'). Prefer 'structure' first \
            to inspect visible headings, text, links, interactive controls, and stable CSS \
            selectors before acting.
            """,
            parameters: [
                ToolParameterSchema(
                    name: "mode",
                    type: .string,
                    description: "Output format: 'structure' (default), 'text', or 'html'.",
                    enumValues: PageReadMode.allCases.map(\.rawValue)
                ),
                ToolParameterSchema(
                    name: "selector",
                    type: .string,
                    description: "Optional CSS selector to scope reading to a matching subtree.",
                    minLength: 1
                ),
                ToolParameterSchema(
                    name: "max_length",
                    type: .integer,
                    description: "Optional maximum character count to return before truncation.",
                    minimum: 1,
                    maximum: 500_000
                )
            ],
            required: []
        )
        if workspace != nil {
            definition.parameters.append(saveToParameter)
        }

        return AgentTool(
            definition: definition,
            summarizeArguments: { args in
                let mode = args["mode"]?.stringValue ?? PageReadMode.structure.rawValue
                var parts = [mode]
                if let selector = args["selector"]?.stringValue, !selector.isEmpty {
                    parts.append( condenseInline(selector, maxChars: 42) )
                }
                if let maxLen = args["max_length"]?.strictIntValue {
                    parts.append("max \(maxLen)")
                }
                return parts.joined(separator: " · ")
            },
            execute: { args in
                let modeRaw = args["mode"]?.stringValue ?? PageReadMode.structure.rawValue
                let mode = PageReadMode(rawValue: modeRaw) ?? .structure
                let selector = args["selector"]?.stringValue
                let maxLength = args["max_length"]?.strictIntValue
                let content = try await bridge.readPage(
                    mode: mode,
                    selector: selector,
                    maxLength: maxLength
                )
                let summary = "\(content.count) chars (\(mode.rawValue))"
                if let workspace, let target = args["save_to"]?.stringValue {
                    let saved = try await saveOutput(content, to: target, workspace: workspace, secrets: secrets)
                    return ToolExecutionOutput(content: saved.notice, summary: "\(summary) · \(saved.path)", savedPath: saved.path)
                }
                return ToolExecutionOutput(content: content, summary: summary, isError: false)
            }
        )
    }

    private static func makeRunJSTool(
        bridge: AgentPageDriving,
        workspace: AgentWorkspace? = nil,
        secrets: [String] = []
    ) -> AgentTool {
        var definition = AgentToolDefinition(
            name: "run_js",
            description: """
            Execute JavaScript in the current page via an async function body (top-level \
            'await' is supported; use 'return <value>' to return a JSON-serializable value). \
            Defaults to the 'isolated' content world (full DOM access, exempt from page \
            eval/connect-src CSP, invisible to page scripts). Set environment='page' only \
            when reading or calling page-defined JS globals.
            """,
            parameters: [
                ToolParameterSchema(
                    name: "code",
                    type: .string,
                    description: "JavaScript async function body. Use 'await' for promises and 'return ...' to return a value.",
                    minLength: 1
                ),
                ToolParameterSchema(
                    name: "environment",
                    type: .string,
                    description: "Execution world: 'isolated' (default) or 'page' (shares JS globals with the page).",
                    enumValues: [
                        AgentExecutionEnvironment.isolated.rawValue,
                        AgentExecutionEnvironment.page.rawValue
                    ]
                ),
                ToolParameterSchema(
                    name: "timeout",
                    type: .number,
                    description: "Execution timeout in seconds (default 10).",
                    minimum: 0.1,
                    maximum: 120
                )
            ],
            required: ["code"]
        )
        if workspace != nil {
            definition.description += " In the isolated world, `await wukong.files.write(path, text)` and "
                + "`await wukong.files.append(path, text)` save text to the workspace from the script itself."
            definition.parameters.append(saveToParameter)
        }

        return AgentTool(
            definition: definition,
            customValidate: { args in
                let code = args["code"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if code.isEmpty {
                    throw ToolValidationError("Invalid arguments for 'run_js': 'code' must not be empty.")
                }
            },
            summarizeArguments: { args in
                let snippet = condenseInline(args["code"]?.stringValue ?? "", maxChars: 56)
                let env = args["environment"]?.stringValue ?? AgentExecutionEnvironment.defaultEnvironment.rawValue
                return env == AgentExecutionEnvironment.page.rawValue ? "\(snippet) (page)" : snippet
            },
            execute: { args in
                let code = args["code"]?.stringValue ?? ""
                let envRaw = args["environment"]?.stringValue ?? AgentExecutionEnvironment.defaultEnvironment.rawValue
                let env = AgentExecutionEnvironment(rawValue: envRaw) ?? .defaultEnvironment
                let timeout = args["timeout"]?.strictDoubleValue ?? AgentBridge.defaultJSTimeout

                let result = workspace == nil
                    ? try await bridge.runJS(code: code, environment: env, timeout: timeout)
                    : try await bridge.runAgentJS(code: code, environment: env, timeout: timeout)
                if let errorMessage = result.error {
                    var sections = ["Error: \(errorMessage)"]
                    if !result.consoleOutput.isEmpty {
                        sections.append("Console:\n" + result.consoleOutput.joined(separator: "\n"))
                    }
                    return ToolExecutionOutput(
                        content: sections.joined(separator: "\n\n"),
                        summary: "Error: \(condenseInline(errorMessage, maxChars: 72))",
                        isError: true
                    )
                }

                let valueDisplay = result.valueJSON ?? "undefined"
                if let workspace, let target = args["save_to"]?.stringValue {
                    // A returned string is saved as its text, anything else as JSON.
                    let text = result.valueJSON
                        .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) as? String }
                        ?? valueDisplay
                    let saved = try await saveOutput(text, to: target, workspace: workspace, secrets: secrets)
                    var sections = [saved.notice]
                    if !result.consoleOutput.isEmpty {
                        sections.append("Console:\n" + result.consoleOutput.joined(separator: "\n"))
                    }
                    return ToolExecutionOutput(
                        content: sections.joined(separator: "\n\n"),
                        summary: "Saved \(saved.path)",
                        savedPath: saved.path
                    )
                }
                var sections = [valueDisplay]
                if !result.consoleOutput.isEmpty {
                    sections.append("Console:\n" + result.consoleOutput.joined(separator: "\n"))
                }
                let summaryValue = condenseInline(valueDisplay, maxChars: 72)
                let summary = result.consoleOutput.isEmpty
                    ? summaryValue
                    : "\(summaryValue) (\(result.consoleOutput.count) console line\(result.consoleOutput.count == 1 ? "" : "s"))"
                return ToolExecutionOutput(
                    content: sections.joined(separator: "\n\n"),
                    summary: summary,
                    isError: false
                )
            }
        )
    }

    private static func makeInjectCSSTool(bridge: AgentPageDriving) -> AgentTool {
        let definition = AgentToolDefinition(
            name: "inject_css",
            description: """
            Inject or update CSS rules on the current page (and open shadow roots) via \
            CSSStyleSheet and adoptedStyleSheets, bypassing inline style-src CSP restrictions. \
            Pass 'id' to update an earlier stylesheet in place without duplicating rules.
            """,
            parameters: [
                ToolParameterSchema(
                    name: "css",
                    type: .string,
                    description: "CSS rules to apply to the current document.",
                    minLength: 1
                ),
                ToolParameterSchema(
                    name: "id",
                    type: .string,
                    description: "Optional stylesheet identifier for updating an injected stylesheet in place.",
                    minLength: 1
                )
            ],
            required: ["css"]
        )

        return AgentTool(
            definition: definition,
            customValidate: { args in
                let css = args["css"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if css.isEmpty {
                    throw ToolValidationError("Invalid arguments for 'inject_css': 'css' must not be empty.")
                }
            },
            summarizeArguments: { args in
                let snippet = condenseInline(args["css"]?.stringValue ?? "", maxChars: 52)
                if let id = args["id"]?.stringValue, !id.isEmpty {
                    return "\(id): \(snippet)"
                }
                return snippet
            },
            execute: { args in
                let css = args["css"]?.stringValue ?? ""
                let id = args["id"]?.stringValue
                let injected = try await bridge.injectCSS(css: css, id: id)
                let content = "Applied stylesheet '\(injected.sheetID)' across \(injected.appliedRootCount) root(s) via adoptedStyleSheets."
                let summary = "Applied '\(injected.sheetID)' (\(css.count) chars)"
                return ToolExecutionOutput(content: content, summary: summary, isError: false)
            }
        )
    }

    private static func makeWaitForTool(bridge: AgentPageDriving) -> AgentTool {
        let definition = AgentToolDefinition(
            name: "wait_for",
            description: """
            Wait for a CSS selector to appear in the DOM (up to 'ms' milliseconds, default \
            5000 ms) or pause for a fixed 'ms' duration when 'selector' is omitted.
            """,
            parameters: [
                ToolParameterSchema(
                    name: "selector",
                    type: .string,
                    description: "Optional CSS selector to wait for in the document.",
                    minLength: 1
                ),
                ToolParameterSchema(
                    name: "ms",
                    type: .integer,
                    description: "Duration in milliseconds: timeout when 'selector' is set, or delay when 'selector' is omitted.",
                    minimum: 1,
                    maximum: 60_000
                )
            ],
            required: []
        )

        return AgentTool(
            definition: definition,
            customValidate: { args in
                let selector = args["selector"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let ms = args["ms"]?.strictIntValue
                if selector.isEmpty && (ms == nil || (ms ?? 0) <= 0) {
                    throw ToolValidationError(
                        "Invalid arguments for 'wait_for': provide a non-empty 'selector' or a positive 'ms' duration."
                    )
                }
            },
            summarizeArguments: { args in
                let selector = args["selector"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let ms = args["ms"]?.strictIntValue
                if !selector.isEmpty, let ms {
                    return "\(condenseInline(selector, maxChars: 42)) (≤\(ms) ms)"
                }
                if !selector.isEmpty {
                    return condenseInline(selector, maxChars: 48)
                }
                if let ms {
                    return "\(ms) ms"
                }
                return "(empty)"
            },
            execute: { args in
                let selector = args["selector"]?.stringValue
                let ms = args["ms"]?.strictIntValue
                let result = try await bridge.waitFor(selector: selector, milliseconds: ms)
                switch result.mode {
                case .selector:
                    let target = result.selector ?? (selector ?? "")
                    if result.matched {
                        let text = "Matched selector '\(target)' after \(result.elapsedMs) ms."
                        return ToolExecutionOutput(
                            content: text,
                            summary: "Matched '\(condenseInline(target, maxChars: 40))' (\(result.elapsedMs) ms)",
                            isError: false
                        )
                    } else {
                        let text = "Timed out after \(result.elapsedMs) ms waiting for selector '\(target)'."
                        return ToolExecutionOutput(
                            content: text,
                            summary: "Timed out after \(result.elapsedMs) ms",
                            isError: true
                        )
                    }
                case .delay:
                    let text = "Waited \(result.elapsedMs) ms."
                    return ToolExecutionOutput(content: text, summary: text, isError: false)
                }
            }
        )
    }

    static func condenseInline(_ text: String, maxChars: Int) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        if collapsed.isEmpty { return "(empty)" }
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.prefix(maxChars)) + "…"
    }

    // MARK: - M2 Page + Userscript Tools Factory

    /// Builds a `ToolRegistry` preloaded with the four M1 page tools plus the five
    /// M2 userscript management tools (`script_save`, `script_list`, `script_read`,
    /// `script_update`, `script_delete`).
    static func m2(
        bridge: AgentPageDriving,
        scriptStore: ScriptStore,
        liveApplier: ScriptLiveApplying? = nil,
        currentUserPrompt: (@MainActor @Sendable () -> String?)? = nil,
        truncationLimit: Int = ToolRegistry.defaultTruncationLimit,
        redactedSecrets: [String] = []
    ) -> ToolRegistry {
        var allTools = pageTools(bridge: bridge, workspace: nil)
        allTools.append(
            contentsOf: scriptTools(
                bridge: bridge,
                scriptStore: scriptStore,
                liveApplier: liveApplier,
                currentUserPrompt: currentUserPrompt
            )
        )
        return ToolRegistry(
            tools: allTools,
            truncationLimit: truncationLimit,
            redactedSecrets: redactedSecrets
        )
    }

    /// The four M1 page tools; with a workspace, `read_page` and `run_js` also
    /// take `save_to`, and `run_js` gets the `wukong.files` helpers.
    static func pageTools(
        bridge: AgentPageDriving,
        workspace: AgentWorkspace?,
        secrets: [String] = []
    ) -> [AgentTool] {
        [
            makeReadPageTool(bridge: bridge, workspace: workspace, secrets: secrets),
            makeRunJSTool(bridge: bridge, workspace: workspace, secrets: secrets),
            makeInjectCSSTool(bridge: bridge),
            makeWaitForTool(bridge: bridge)
        ]
    }

    static func scriptTools(
        bridge: AgentPageDriving,
        scriptStore: ScriptStore,
        liveApplier: ScriptLiveApplying? = nil,
        currentUserPrompt: (@MainActor @Sendable () -> String?)? = nil
    ) -> [AgentTool] {
        [
            makeScriptSaveTool(
                bridge: bridge,
                scriptStore: scriptStore,
                liveApplier: liveApplier,
                currentUserPrompt: currentUserPrompt
            ),
            makeScriptListTool(scriptStore: scriptStore),
            makeScriptReadTool(scriptStore: scriptStore),
            makeScriptUpdateTool(
                bridge: bridge,
                scriptStore: scriptStore,
                liveApplier: liveApplier,
                currentUserPrompt: currentUserPrompt
            ),
            makeScriptDeleteTool(
                scriptStore: scriptStore,
                liveApplier: liveApplier
            )
        ]
    }

    private static func makeScriptSaveTool(
        bridge: AgentPageDriving,
        scriptStore: ScriptStore,
        liveApplier: ScriptLiveApplying?,
        currentUserPrompt: (@MainActor @Sendable () -> String?)?
    ) -> AgentTool {
        let definition = AgentToolDefinition(
            name: "script_save",
            description: """
            Save a persistent per-site userscript (with JavaScript, CSS, or both) that runs \
            automatically on every matching page load and SPA route change, and apply it to \
            the current page right away if the current URL matches. Call this only when the \
            user asks to always apply a change or persist it for future visits.
            """,
            parameters: [
                ToolParameterSchema(
                    name: "name",
                    type: .string,
                    description: "Short human-readable script name, such as 'Original poster only'.",
                    minLength: 1
                ),
                ToolParameterSchema(
                    name: "match_rules",
                    type: .array,
                    description: "One or more Tampermonkey @match URL patterns, e.g. ['*://*.example.com/*'].",
                    itemsType: .string
                ),
                ToolParameterSchema(
                    name: "js",
                    type: .string,
                    description: "Optional JavaScript body to run on matching pages (either 'js' or 'css' must be non-empty)."
                ),
                ToolParameterSchema(
                    name: "css",
                    type: .string,
                    description: "Optional CSS rules to inject via adoptedStyleSheets under strict CSP (either 'js' or 'css' must be non-empty)."
                ),
                ToolParameterSchema(
                    name: "injection_time",
                    type: .string,
                    description: "When to inject on page load: 'document-end' (default) or 'document-start'.",
                    enumValues: ScriptInjectionTime.allCases.map(\.rawValue)
                ),
                ToolParameterSchema(
                    name: "environment",
                    type: .string,
                    description: "Execution world for JS: 'isolated' (default, CSP-safe) or 'page' (shares page JS globals).",
                    enumValues: [
                        AgentExecutionEnvironment.isolated.rawValue,
                        AgentExecutionEnvironment.page.rawValue
                    ]
                )
            ],
            required: ["name", "match_rules"]
        )

        return AgentTool(
            definition: definition,
            customValidate: { args in
                let name = args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if name.isEmpty {
                    throw ToolValidationError("Invalid arguments for 'script_save': 'name' must not be empty.")
                }
                let rules = try extractValidatedMatchRules(from: args["match_rules"], toolName: "script_save")
                if rules.isEmpty {
                    throw ToolValidationError("Invalid arguments for 'script_save': 'match_rules' must contain at least one @match pattern.")
                }
                let js = args["js"]?.stringValue ?? ""
                let css = args["css"]?.stringValue ?? ""
                if js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ToolValidationError("Invalid arguments for 'script_save': provide non-empty 'js', 'css', or both.")
                }
            },
            summarizeArguments: { args in
                let name = condenseInline(args["name"]?.stringValue ?? "", maxChars: 36)
                let firstRule = args["match_rules"]?.strictArrayValue?.first?.stringValue ?? ""
                if !firstRule.isEmpty {
                    return "\(name) · \(condenseInline(firstRule, maxChars: 32))"
                }
                return name
            },
            execute: { args in
                let name = args["name"]?.stringValue ?? ""
                let rules = try extractValidatedMatchRules(from: args["match_rules"], toolName: "script_save")
                let js = args["js"]?.stringValue ?? ""
                let css = args["css"]?.stringValue ?? ""
                let injectionRaw = args["injection_time"]?.stringValue ?? ScriptInjectionTime.defaultTime.rawValue
                let injectionTime = ScriptInjectionTime(rawValue: injectionRaw) ?? .defaultTime
                let envRaw = args["environment"]?.stringValue ?? AgentExecutionEnvironment.defaultEnvironment.rawValue
                let environment = AgentExecutionEnvironment(rawValue: envRaw) ?? .defaultEnvironment

                let saved: UserScript = try await MainActor.run {
                    let prompt = currentUserPrompt?() ?? ""
                    return try scriptStore.create(
                        name: name,
                        matchRules: rules,
                        js: js,
                        css: css,
                        injectionTime: injectionTime,
                        environment: environment,
                        isEnabled: true,
                        source: .agent(userPrompt: prompt)
                    )
                }

                let liveOutcome = await applyScriptToOpenPage(
                    saved,
                    runJS: saved.hasJS,
                    bridge: bridge,
                    scriptStore: scriptStore,
                    liveApplier: liveApplier
                )

                var payload: [String: JSONValue] = [
                    "script_id": .string(saved.id),
                    "name": .string(saved.name),
                    "version": .int(Int64(saved.version)),
                    "match_rules": .array(saved.matchRules.map(JSONValue.string)),
                    "injection_time": .string(saved.injectionTime.rawValue),
                    "environment": .string(saved.environment.rawValue),
                    "applied_to_current_page": .bool(liveOutcome.applied)
                ]
                if let runtimeError = liveOutcome.runtimeError {
                    payload["runtime_error"] = .string(runtimeError)
                }

                let json = JSONValue.encodeCompactJSON(payload)
                if let runtimeError = liveOutcome.runtimeError {
                    return ToolExecutionOutput(
                        content: json,
                        summary: "Saved '\(saved.name)' (\(saved.id)), runtime error: \(condenseInline(runtimeError, maxChars: 48))",
                        isError: true
                    )
                }
                return ToolExecutionOutput(
                    content: json,
                    summary: "Saved '\(saved.name)' (\(saved.id), v\(saved.version))",
                    isError: false
                )
            }
        )
    }

    private static func makeScriptListTool(scriptStore: ScriptStore) -> AgentTool {
        let definition = AgentToolDefinition(
            name: "script_list",
            description: """
            List saved userscripts, optionally filtered to scripts whose @match patterns \
            apply to a given domain.
            """,
            parameters: [
                ToolParameterSchema(
                    name: "domain",
                    type: .string,
                    description: "Optional domain (e.g. 'example.com' or 'sub.example.com') to filter matching scripts."
                )
            ],
            required: []
        )

        return AgentTool(
            definition: definition,
            summarizeArguments: { args in
                if let domain = args["domain"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !domain.isEmpty {
                    return condenseInline(domain, maxChars: 48)
                }
                return "all scripts"
            },
            execute: { args in
                let rawDomain = args["domain"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let (globalEnabled, items, count): (Bool, [JSONValue], Int) = await MainActor.run {
                    let matching = rawDomain.isEmpty
                        ? scriptStore.scripts
                        : scriptStore.scripts(matchingDomain: rawDomain)
                    let encodedItems: [JSONValue] = matching.map { script in
                        var obj: [String: JSONValue] = [
                            "script_id": .string(script.id),
                            "name": .string(script.name),
                            "match_rules": .array(script.matchRules.map(JSONValue.string)),
                            "enabled": .bool(script.isEnabled),
                            "version": .int(Int64(script.version)),
                            "injection_time": .string(script.injectionTime.rawValue),
                            "environment": .string(script.environment.rawValue),
                            "source": .string(script.source.kindIdentifier),
                            "has_js": .bool(script.hasJS),
                            "has_css": .bool(script.hasCSS)
                        ]
                        if let err = scriptStore.error(for: script.id) {
                            obj["error"] = .string(err.message)
                        }
                        return .object(obj)
                    }
                    return (scriptStore.isGlobalEnabled, encodedItems, matching.count)
                }

                var payload: [String: JSONValue] = [
                    "global_enabled": .bool(globalEnabled),
                    "count": .int(Int64(count)),
                    "scripts": .array(items)
                ]
                if !rawDomain.isEmpty {
                    payload["domain"] = .string(rawDomain)
                }
                let summary = count == 1 ? "1 script" : "\(count) scripts"
                return ToolExecutionOutput(
                    content: JSONValue.encodeCompactJSON(payload),
                    summary: summary,
                    isError: false
                )
            }
        )
    }

    private static func makeScriptReadTool(scriptStore: ScriptStore) -> AgentTool {
        let definition = AgentToolDefinition(
            name: "script_read",
            description: "Read the full metadata, JavaScript/CSS bodies, version history, and .user.js content of a saved userscript.",
            parameters: [
                ToolParameterSchema(
                    name: "script_id",
                    type: .string,
                    description: "Identifier of the script to read.",
                    minLength: 1
                )
            ],
            required: ["script_id"]
        )

        return AgentTool(
            definition: definition,
            customValidate: { args in
                let id = args["script_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if id.isEmpty {
                    throw ToolValidationError("Invalid arguments for 'script_read': 'script_id' must not be empty.")
                }
            },
            summarizeArguments: { args in
                condenseInline(args["script_id"]?.stringValue ?? "", maxChars: 48)
            },
            execute: { args in
                let id = args["script_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let (script, runtimeErr): (UserScript, ScriptRuntimeError?) = try await MainActor.run {
                    guard let found = scriptStore.script(id: id) else {
                        throw ScriptStoreError.scriptNotFound(id)
                    }
                    return (found, scriptStore.error(for: id))
                }

                var payload: [String: JSONValue] = [
                    "script_id": .string(script.id),
                    "name": .string(script.name),
                    "match_rules": .array(script.matchRules.map(JSONValue.string)),
                    "js": .string(script.js),
                    "css": .string(script.css),
                    "injection_time": .string(script.injectionTime.rawValue),
                    "environment": .string(script.environment.rawValue),
                    "enabled": .bool(script.isEnabled),
                    "version": .int(Int64(script.version)),
                    "source": .string(script.source.kindIdentifier),
                    "versions": .array(script.versions.map { .int(Int64($0.version)) }),
                    "user_script": .string(script.toUserScriptFileContent())
                ]
                if let prompt = script.source.userPrompt {
                    payload["user_prompt"] = .string(prompt)
                }
                if let runtimeErr {
                    payload["error"] = .string(runtimeErr.message)
                }

                return ToolExecutionOutput(
                    content: JSONValue.encodeCompactJSON(payload),
                    summary: "Read '\(script.name)' (v\(script.version))",
                    isError: false
                )
            }
        )
    }

    private static func makeScriptUpdateTool(
        bridge: AgentPageDriving,
        scriptStore: ScriptStore,
        liveApplier: ScriptLiveApplying?,
        currentUserPrompt: (@MainActor @Sendable () -> String?)? = nil
    ) -> AgentTool {
        let definition = AgentToolDefinition(
            name: "script_update",
            description: """
            Update one or more fields of an existing userscript, archiving the previous \
            version for rollback and returning the new version number.
            """,
            parameters: [
                ToolParameterSchema(
                    name: "script_id",
                    type: .string,
                    description: "Identifier of the script to update.",
                    minLength: 1
                ),
                ToolParameterSchema(
                    name: "name",
                    type: .string,
                    description: "Optional updated human-readable name.",
                    minLength: 1
                ),
                ToolParameterSchema(
                    name: "match_rules",
                    type: .array,
                    description: "Optional replacement list of Tampermonkey @match patterns.",
                    itemsType: .string
                ),
                ToolParameterSchema(
                    name: "js",
                    type: .string,
                    description: "Optional replacement JavaScript body (pass '' to clear JS if CSS remains non-empty)."
                ),
                ToolParameterSchema(
                    name: "css",
                    type: .string,
                    description: "Optional replacement CSS stylesheet (pass '' to clear CSS if JS remains non-empty)."
                ),
                ToolParameterSchema(
                    name: "injection_time",
                    type: .string,
                    description: "Optional updated injection time: 'document-start' or 'document-end'.",
                    enumValues: ScriptInjectionTime.allCases.map(\.rawValue)
                ),
                ToolParameterSchema(
                    name: "environment",
                    type: .string,
                    description: "Optional updated execution world: 'isolated' or 'page'.",
                    enumValues: [
                        AgentExecutionEnvironment.isolated.rawValue,
                        AgentExecutionEnvironment.page.rawValue
                    ]
                ),
                ToolParameterSchema(
                    name: "enabled",
                    type: .boolean,
                    description: "Optional enabled state for the script."
                )
            ],
            required: ["script_id"]
        )

        return AgentTool(
            definition: definition,
            customValidate: { args in
                let id = args["script_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if id.isEmpty {
                    throw ToolValidationError("Invalid arguments for 'script_update': 'script_id' must not be empty.")
                }

                let mutableKeys = ["name", "match_rules", "js", "css", "injection_time", "environment", "enabled"]
                guard mutableKeys.contains(where: { args[$0] != nil }) else {
                    throw ToolValidationError(
                        "Invalid arguments for 'script_update': provide at least one field to update (name, match_rules, js, css, injection_time, environment, or enabled)."
                    )
                }

                if let rawName = args["name"]?.stringValue,
                   rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ToolValidationError("Invalid arguments for 'script_update': 'name' must not be empty.")
                }
                if let rulesVal = args["match_rules"] {
                    _ = try extractValidatedMatchRules(from: rulesVal, toolName: "script_update")
                }
                if let js = args["js"]?.stringValue, let css = args["css"]?.stringValue {
                    if js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw ToolValidationError(
                            "Invalid arguments for 'script_update': 'js' and 'css' cannot both be empty."
                        )
                    }
                }
            },
            summarizeArguments: { args in
                let id = condenseInline(args["script_id"]?.stringValue ?? "", maxChars: 36)
                let changed = ["name", "match_rules", "js", "css", "injection_time", "environment", "enabled"]
                    .filter { args[$0] != nil }
                if changed.isEmpty { return id }
                return "\(id) (\(changed.joined(separator: ", ")))"
            },
            execute: { args in
                let id = args["script_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let matchRules: [String]?
                if let rulesVal = args["match_rules"] {
                    matchRules = try extractValidatedMatchRules(from: rulesVal, toolName: "script_update")
                } else {
                    matchRules = nil
                }

                let patch = ScriptUpdatePatch(
                    name: args["name"]?.stringValue,
                    matchRules: matchRules,
                    js: args["js"]?.stringValue,
                    css: args["css"]?.stringValue,
                    injectionTime: args["injection_time"]?.stringValue.flatMap(ScriptInjectionTime.init(rawValue:)),
                    environment: args["environment"]?.stringValue.flatMap(AgentExecutionEnvironment.init(rawValue:)),
                    isEnabled: args["enabled"]?.strictBoolValue
                )

                let (wasEnabled, updated): (Bool, UserScript) = try await MainActor.run {
                    let previouslyEnabled = scriptStore.script(id: id)?.isEnabled ?? false
                    let prompt = currentUserPrompt?() ?? ""
                    let result = try scriptStore.update(
                        id: id,
                        patch: patch,
                        origin: .changedByAgent(userPrompt: prompt)
                    )
                    return (previouslyEnabled, result)
                }

                let shouldRunJS = updated.hasJS && (
                    patch.js != nil
                    || patch.environment != nil
                    || patch.matchRules != nil
                    || (patch.isEnabled == true && !wasEnabled)
                )
                let liveOutcome = await applyScriptToOpenPage(
                    updated,
                    runJS: shouldRunJS,
                    bridge: bridge,
                    scriptStore: scriptStore,
                    liveApplier: liveApplier
                )

                var payload: [String: JSONValue] = [
                    "script_id": .string(updated.id),
                    "version": .int(Int64(updated.version)),
                    "enabled": .bool(updated.isEnabled),
                    "applied_to_current_page": .bool(liveOutcome.applied)
                ]
                if let runtimeError = liveOutcome.runtimeError {
                    payload["runtime_error"] = .string(runtimeError)
                }

                let json = JSONValue.encodeCompactJSON(payload)
                if let runtimeError = liveOutcome.runtimeError {
                    return ToolExecutionOutput(
                        content: json,
                        summary: "Updated '\(updated.name)' to v\(updated.version), runtime error: \(condenseInline(runtimeError, maxChars: 44))",
                        isError: true
                    )
                }
                return ToolExecutionOutput(
                    content: json,
                    summary: "Updated '\(updated.name)' to v\(updated.version)",
                    isError: false
                )
            }
        )
    }

    private static func makeScriptDeleteTool(
        scriptStore: ScriptStore,
        liveApplier: ScriptLiveApplying?
    ) -> AgentTool {
        let definition = AgentToolDefinition(
            name: "script_delete",
            description: "Delete a saved userscript and remove its live styles and future automatic injection.",
            parameters: [
                ToolParameterSchema(
                    name: "script_id",
                    type: .string,
                    description: "Identifier of the script to delete.",
                    minLength: 1
                )
            ],
            required: ["script_id"]
        )

        return AgentTool(
            definition: definition,
            customValidate: { args in
                let id = args["script_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if id.isEmpty {
                    throw ToolValidationError("Invalid arguments for 'script_delete': 'script_id' must not be empty.")
                }
            },
            summarizeArguments: { args in
                condenseInline(args["script_id"]?.stringValue ?? "", maxChars: 48)
            },
            execute: { args in
                let id = args["script_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let deletedScript: UserScript? = try await MainActor.run {
                    guard scriptStore.script(id: id) != nil else {
                        return nil
                    }
                    return try scriptStore.delete(id: id)
                }

                guard let deletedScript else {
                    let payload: [String: JSONValue] = [
                        "script_id": .string(id),
                        "deleted": .bool(false),
                        "error": .string("Script '\(id)' was not found.")
                    ]
                    return ToolExecutionOutput(
                        content: JSONValue.encodeCompactJSON(payload),
                        summary: "Error: Script '\(id)' was not found.",
                        isError: true
                    )
                }

                if let liveApplier {
                    await liveApplier.removeLiveScript(id: id)
                }

                let payload: [String: JSONValue] = [
                    "script_id": .string(id),
                    "deleted": .bool(true)
                ]
                return ToolExecutionOutput(
                    content: JSONValue.encodeCompactJSON(payload),
                    summary: "Deleted '\(deletedScript.name)' (\(id))",
                    isError: false
                )
            }
        )
    }

    private static func extractValidatedMatchRules(
        from rawValue: JSONValue?,
        toolName: String
    ) throws -> [String] {
        guard let elements = rawValue?.strictArrayValue, !elements.isEmpty else {
            throw ToolValidationError(
                "Invalid arguments for '\(toolName)': 'match_rules' must be a non-empty array of @match patterns."
            )
        }
        var cleaned: [String] = []
        cleaned.reserveCapacity(elements.count)
        for element in elements {
            guard let rawRule = element.stringValue else {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': every entry in 'match_rules' must be a string."
                )
            }
            let trimmed = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': 'match_rules' entries must not be empty."
                )
            }
            do {
                _ = try MatchPattern.parse(trimmed)
            } catch {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': invalid @match pattern '\(trimmed)' (\(error.localizedDescription))"
                )
            }
            cleaned.append(trimmed)
        }
        return cleaned
    }

    private static func applyScriptToOpenPage(
        _ script: UserScript,
        runJS: Bool,
        bridge: AgentPageDriving,
        scriptStore: ScriptStore,
        liveApplier: ScriptLiveApplying?
    ) async -> ScriptLiveApplicationOutcome {
        if let liveApplier {
            return await liveApplier.applyLiveScript(script, runJS: runJS)
        }

        let isGloballyAllowed = await MainActor.run {
            scriptStore.isGlobalEnabled && script.isEnabled
        }
        guard isGloballyAllowed else {
            return .notApplied
        }

        let meta = await bridge.currentPageMetadata()
        guard !meta.url.isEmpty, script.matches(urlString: meta.url) else {
            return .notApplied
        }

        if script.hasCSS {
            _ = try? await bridge.injectCSS(css: script.css, id: "userscript-\(script.id)")
        }

        var capturedError: String?
        if runJS && script.hasJS {
            if let jsResult = try? await bridge.runJS(
                code: script.js,
                environment: script.environment,
                timeout: AgentBridge.defaultJSTimeout
            ), let err = jsResult.error, !err.isEmpty {
                capturedError = err
                await MainActor.run {
                    scriptStore.recordError(scriptID: script.id, message: err, url: meta.url)
                }
            }
        }
        return ScriptLiveApplicationOutcome(applied: true, runtimeError: capturedError)
    }
}

// MARK: - M3 Tool Context & Factory

/// The settings an M3 tool may read when the registry is built.
struct AgentToolSettings: Equatable, Sendable {
    var truncationLimit: Int = ToolRegistry.defaultTruncationLimit
    var redactedSecrets: [String] = []
    var supportsImageInput = false
    var confirmBeforeWrites = false
}

/// Everything an M3 tool family needs, handed to each `ToolRegistry+*.swift`
/// file by `ToolRegistry.m3`. Later tasks add their own fields (the cookie
/// store and the confirmation gate) with defaults, so call sites stay put.
struct AgentToolContext: Sendable {
    var bridge: AgentPageDriving
    var workspace: AgentWorkspace?
    var scriptStore: ScriptStore
    var liveApplier: ScriptLiveApplying?
    var currentUserPrompt: (@MainActor @Sendable () -> String?)?
    var settings: AgentToolSettings
    /// The HTTP client and cookie access behind `http_request` and `cookies_get`.
    var network: AgentHTTPClient?
    /// Where confirmation cards wait for an answer.
    var confirmations: AgentConfirmationGate?

    init(
        bridge: AgentPageDriving,
        workspace: AgentWorkspace?,
        scriptStore: ScriptStore,
        liveApplier: ScriptLiveApplying? = nil,
        currentUserPrompt: (@MainActor @Sendable () -> String?)? = nil,
        settings: AgentToolSettings = AgentToolSettings(),
        network: AgentHTTPClient? = nil,
        confirmations: AgentConfirmationGate? = nil
    ) {
        self.bridge = bridge
        self.workspace = workspace
        self.scriptStore = scriptStore
        self.liveApplier = liveApplier
        self.currentUserPrompt = currentUserPrompt
        self.settings = settings
        self.network = network
        self.confirmations = confirmations
    }
}

extension ToolRegistry {
    /// The M3 registry: the M2 tools, with `save_to` and saving over-limit
    /// results to the workspace, plus one list per tool family. Each family
    /// lives in its own `ToolRegistry+<Family>.swift`.
    static func m3(context: AgentToolContext) -> ToolRegistry {
        var tools = pageTools(
            bridge: context.bridge,
            workspace: context.workspace,
            secrets: context.settings.redactedSecrets
        )
        tools += scriptTools(
            bridge: context.bridge,
            scriptStore: context.scriptStore,
            liveApplier: context.liveApplier,
            currentUserPrompt: context.currentUserPrompt
        )
        tools += workspaceTools(context: context)
        tools += captureTools(context: context)
        tools += navigationTools(context: context)
        tools += networkTools(context: context)
        return ToolRegistry(
            tools: tools,
            truncationLimit: context.settings.truncationLimit,
            redactedSecrets: context.settings.redactedSecrets,
            workspace: context.workspace
        )
    }
}
