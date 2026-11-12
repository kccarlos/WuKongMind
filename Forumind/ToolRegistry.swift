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
    var minLength: Int?
    var minimum: Double?
    var maximum: Double?

    init(
        name: String,
        type: ToolParameterType,
        description: String,
        enumValues: [String]? = nil,
        minLength: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.enumValues = enumValues
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

struct AgentToolDefinition: Equatable, Sendable {
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

    init(content: String, summary: String? = nil, isError: Bool = false) {
        self.content = content
        self.summary = summary ?? Self.defaultSummary(for: content)
        self.isError = isError
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

    init(
        tools: [AgentTool] = [],
        truncationLimit: Int = ToolRegistry.defaultTruncationLimit,
        redactedSecrets: [String] = []
    ) {
        self.truncationLimit = max(1, truncationLimit)
        self.redactedSecrets = redactedSecrets
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
            guard case .array = value else {
                throw ToolValidationError(
                    "Invalid arguments for '\(toolName)': parameter '\(schema.name)' must be an array, got \(value.typeDescription)."
                )
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
    func dispatch(toolName: String, rawArgumentsJSON: String) async throws -> ToolDispatchResult {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let parsed: [String: JSONValue]
        do {
            parsed = try JSONValue.parseObjectJSON(rawArgumentsJSON)
        } catch {
            let duration = Self.secondsElapsed(since: started)
            return makeResult(
                toolName: toolName,
                argumentSummary: ToolExecutionOutput.defaultSummary(for: rawArgumentsJSON, maxChars: 64),
                argumentsJSON: rawArgumentsJSON,
                rawOutput: error.localizedDescription,
                summary: error.localizedDescription,
                isError: true,
                duration: duration
            )
        }
        return try await dispatch(toolName: toolName, arguments: parsed)
    }

    /// Validates and executes `toolName`. Validation failures and tool runtime
    /// errors return `ToolDispatchResult(..., isError: true)` without throwing;
    /// `CancellationError` rethrows immediately so `stop()` halts the loop at once.
    func dispatch(toolName: String, arguments: [String: JSONValue]) async throws -> ToolDispatchResult {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let argsJSON = JSONValue.encodeCompactJSON(arguments)

        guard let tool = toolsByName[toolName] else {
            let message = "Unknown tool '\(toolName)'. Available tools: \(orderedNames.joined(separator: ", "))."
            return makeResult(
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
            return makeResult(
                toolName: toolName,
                argumentSummary: argSummary,
                argumentsJSON: argsJSON,
                rawOutput: execution.content,
                summary: execution.summary,
                isError: execution.isError,
                duration: Self.secondsElapsed(since: started)
            )
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            let message = error.localizedDescription
            return makeResult(
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
        duration: TimeInterval
    ) -> ToolDispatchResult {
        let scrubbedOutput = UntrustedWebContent.redactSecrets(in: rawOutput, secrets: redactedSecrets)
        let scrubbedSummary = UntrustedWebContent.redactSecrets(in: summary, secrets: redactedSecrets)
        let (finalOutput, wasTruncated, totalCount) = Self.truncate(scrubbedOutput, limit: truncationLimit)
        let finalSummary: String
        if wasTruncated {
            finalSummary = "\(scrubbedSummary) (truncated, \(totalCount) chars total)"
        } else {
            finalSummary = scrubbedSummary
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
            duration: duration
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

    private static func makeReadPageTool(bridge: AgentPageDriving) -> AgentTool {
        let definition = AgentToolDefinition(
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
                return ToolExecutionOutput(content: content, summary: summary, isError: false)
            }
        )
    }

    private static func makeRunJSTool(bridge: AgentPageDriving) -> AgentTool {
        let definition = AgentToolDefinition(
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

                let result = try await bridge.runJS(code: code, environment: env, timeout: timeout)
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

    private static func condenseInline(_ text: String, maxChars: Int) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        if collapsed.isEmpty { return "(empty)" }
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.prefix(maxChars)) + "…"
    }
}
