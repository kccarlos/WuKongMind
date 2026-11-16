import Foundation

// WebMCP page-tool dispatchers (`design-learn-on-ask.md` "Names, limits and trust",
// "The two dispatcher tools"): `page_tools_list`, `page_tool_call` and `PageToolSchema`.

struct PageToolCounts: Equatable, Sendable {
    var site: Int
    var script: Int
    var isEmpty: Bool { site <= 0 && script <= 0 }
}

@MainActor
protocol PageToolDriving: AnyObject, Sendable {
    var isEnabled: Bool { get }
    func collectTools(pullTimeout: TimeInterval) async -> PageToolSnapshot
    func callTool(
        prefixedName: String, arguments: [String: JSONValue], timeout: TimeInterval, maxResponseBytes: Int
    ) async -> Result<PageToolCallResult, PageToolCallFailure>
}

extension PageToolBridge: PageToolDriving {}

struct PageToolContext: Sendable {
    static let learnedSlotNames: Set<String> = ["read_topic", "list_latest", "search_forum"]

    let bridge: any PageToolDriving
    let isEnabled: Bool
    let scriptStore: ScriptStore?
    let confirmBeforeWrites: (@Sendable () async -> Bool)?

    @MainActor
    init(
        bridge: any PageToolDriving,
        scriptStore: ScriptStore? = nil,
        confirmBeforeWrites: (@Sendable () async -> Bool)? = nil
    ) {
        self.bridge = bridge
        self.isEnabled = bridge.isEnabled
        self.scriptStore = scriptStore
        self.confirmBeforeWrites = confirmBeforeWrites
    }

    @MainActor
    func collectDispatcherTools(pullTimeout: TimeInterval = 2.0) async -> PageToolSnapshot {
        guard isEnabled, bridge.isEnabled else { return .empty }
        var snapshot = await bridge.collectTools(pullTimeout: pullTimeout)
        snapshot.tools.removeAll { isLearnedSlotTool($0) }
        return snapshot
    }

    @MainActor
    func counts(pullTimeout: TimeInterval = 2.0) async -> PageToolCounts {
        let snapshot = await collectDispatcherTools(pullTimeout: pullTimeout)
        return PageToolCounts(site: snapshot.siteTools.count, script: snapshot.scriptTools.count)
    }

    @MainActor
    private func isLearnedSlotTool(_ tool: PageTool) -> Bool {
        guard tool.source == .script, Self.learnedSlotNames.contains(tool.name),
              let ownerID = tool.ownerID, let script = scriptStore?.script(id: ownerID) else { return false }
        let declared = script.metadata.values(for: "@wukong-provides")
            .flatMap { $0.split { $0.isWhitespace || $0 == "," }.map(String.init) }
        return declared.contains(tool.name)
    }
}

enum PageToolSchema {
    enum Coverage: Equatable, Sendable { case noSchema, checked, checkedInPart }

    static let maxArgumentsBytes = 64 * 1_024
    static let maxArgumentsDepth = 8
    static let maxSchemaDepth = 4
    private static let supportedTypes: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]
    private static let checkedKeywords: Set<String> = [
        "type", "properties", "required", "additionalProperties", "items",
        "enum", "minLength", "maxLength", "minimum", "maximum", "minItems", "maxItems"
    ]
    private static let ignoredKeywords: Set<String> = ["title", "description", "default", "examples", "format"]

    static func inspect(_ schema: JSONValue?, schemaJSON: String? = nil) -> Coverage {
        guard let root = usableRoot(schema, schemaJSON: schemaJSON) else { return .noSchema }
        return hasUnsupportedPart(root, level: 1) ? .checkedInPart : .checked
    }

    static func validateAlways(_ arguments: JSONValue) -> String? {
        guard case .object(let dict) = arguments else {
            return "`arguments` must be a JSON object, got \(arguments.typeDescription)."
        }
        let encodedBytes = JSONValue.encodeCompactJSON(dict).utf8.count
        if encodedBytes > maxArgumentsBytes { return "`arguments` exceeds the 64 KB limit (\(encodedBytes) bytes)." }
        if nestingDepth(arguments) > maxArgumentsDepth { return "`arguments` exceeds the maximum nesting depth of \(maxArgumentsDepth)." }
        return nil
    }

    static func validate(arguments: JSONValue, schema: JSONValue?, schemaJSON: String? = nil) -> String? {
        if let alwaysError = validateAlways(arguments) { return alwaysError }
        guard let root = usableRoot(schema, schemaJSON: schemaJSON) else { return nil }
        return validateNode(arguments, schemaObj: root, path: "arguments", level: 1)
    }

    private static func usableRoot(_ schema: JSONValue?, schemaJSON: String?) -> [String: JSONValue]? {
        guard let schema, !schema.isNull, case .object(let root) = schema, root["type"] == .string("object") else { return nil }
        let length = schemaJSON?.count ?? JSONValue.encodeCompactJSON(root).count
        return length <= PageToolBridge.maxSchemaCharacters ? root : nil
    }

    private static func nestingDepth(_ value: JSONValue) -> Int {
        switch value {
        case .null, .bool, .int, .double, .string: 0
        case .array(let items): 1 + (items.map(nestingDepth).max() ?? 0)
        case .object(let dict): 1 + (dict.values.map(nestingDepth).max() ?? 0)
        }
    }

    private static func hasUnsupportedPart(_ schemaObj: [String: JSONValue], level: Int) -> Bool {
        if level > maxSchemaDepth { return true }
        var partial = false
        for (key, val) in schemaObj where !ignoredKeywords.contains(key) {
            guard checkedKeywords.contains(key) else { partial = true; continue }
            switch key {
            case "type": if case .string(let t) = val, supportedTypes.contains(t) {} else { partial = true }
            case "additionalProperties": if val.strictBoolValue == nil { partial = true }
            case "properties":
                guard case .object(let props) = val else { partial = true; continue }
                for (_, sub) in props {
                    guard case .object(let subObj) = sub else { partial = true; continue }
                    if level >= maxSchemaDepth || hasUnsupportedPart(subObj, level: level + 1) { partial = true }
                }
            case "items":
                guard case .object(let itemObj) = val else { partial = true; continue }
                if level >= maxSchemaDepth || hasUnsupportedPart(itemObj, level: level + 1) { partial = true }
            case "required": if case .array(let reqs) = val, reqs.allSatisfy({ $0.stringValue != nil }) {} else { partial = true }
            case "enum": if case .array(let vals) = val, !vals.isEmpty {} else { partial = true }
            case "minLength", "maxLength", "minItems", "maxItems": if let n = val.strictIntValue, n >= 0 {} else { partial = true }
            case "minimum", "maximum": if let d = val.strictDoubleValue, d.isFinite {} else { partial = true }
            default: partial = true
            }
        }
        return partial
    }

    private static func validateNode(_ value: JSONValue, schemaObj: [String: JSONValue], path: String, level: Int) -> String? {
        guard level <= maxSchemaDepth else { return nil }
        if case .string(let t)? = schemaObj["type"], supportedTypes.contains(t), !matchesType(value, expectedType: t) {
            let label = ["object", "array", "integer"].contains(t) ? "an \(t)" : (t == "null" ? "null" : "a \(t)")
            return "`\(path)` must be \(label), got \(value.typeDescription)."
        }
        if case .array(let allowed)? = schemaObj["enum"], !allowed.isEmpty, !allowed.contains(where: { jsonEqual($0, value) }) {
            return "`\(path)` must be one of [\(allowed.map(renderScalar).joined(separator: ", "))]."
        }
        switch value {
        case .string(let str):
            let count = str.unicodeScalars.count
            if let minL = schemaObj["minLength"]?.strictIntValue, minL >= 0, count < minL { return "`\(path)` must be at least \(minL) character(s)." }
            if let maxL = schemaObj["maxLength"]?.strictIntValue, maxL >= 0, count > maxL { return "`\(path)` must be at most \(maxL) character(s)." }
        case .int, .double:
            guard let num = value.strictDoubleValue, num.isFinite else { break }
            if let minV = schemaObj["minimum"]?.strictDoubleValue, minV.isFinite, num < minV { return "`\(path)` must be >= \(formatNumber(minV))." }
            if let maxV = schemaObj["maximum"]?.strictDoubleValue, maxV.isFinite, num > maxV { return "`\(path)` must be <= \(formatNumber(maxV))." }
        case .array(let elements):
            if let minI = schemaObj["minItems"]?.strictIntValue, minI >= 0, elements.count < minI { return "`\(path)` must have at least \(minI) item(s)." }
            if let maxI = schemaObj["maxItems"]?.strictIntValue, maxI >= 0, elements.count > maxI { return "`\(path)` must have at most \(maxI) item(s)." }
            if level < maxSchemaDepth, case .object(let itemSchema)? = schemaObj["items"] {
                for (i, item) in elements.enumerated() {
                    if let err = validateNode(item, schemaObj: itemSchema, path: "\(path)[\(i)]", level: level + 1) { return err }
                }
            }
        case .object(let dict):
            let childPath = { (key: String) in path == "arguments" ? key : "\(path).\(key)" }
            if case .array(let reqs)? = schemaObj["required"] {
                for reqKey in reqs.compactMap(\.stringValue) where dict[reqKey] == nil {
                    return "missing required property `\(childPath(reqKey))`."
                }
            }
            let propsObj: [String: JSONValue]? = if case .object(let p)? = schemaObj["properties"] { p } else { nil }
            if schemaObj["additionalProperties"] == .bool(false) {
                let allowed = Set(propsObj?.keys ?? [:].keys)
                if let bad = dict.keys.sorted().first(where: { !allowed.contains($0) }) {
                    return "unexpected property `\(childPath(bad))`."
                }
            }
            if level < maxSchemaDepth, let propsObj {
                for key in propsObj.keys.sorted() {
                    guard let propVal = dict[key], case .object(let propSchema) = propsObj[key] else { continue }
                    if let err = validateNode(propVal, schemaObj: propSchema, path: childPath(key), level: level + 1) { return err }
                }
            }
        case .bool, .null: break
        }
        return nil
    }

    private static func matchesType(_ value: JSONValue, expectedType: String) -> Bool {
        switch expectedType {
        case "object": value.objectValue != nil
        case "array": value.strictArrayValue != nil
        case "string": value.stringValue != nil
        case "boolean": value.strictBoolValue != nil
        case "null": value.isNull
        case "integer":
            if case .int = value { true } else if case .double(let d) = value { d.isFinite && d.rounded(.towardZero) == d } else { false }
        case "number": value.strictDoubleValue?.isFinite == true
        default: true
        }
    }

    private static func jsonEqual(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        lhs == rhs || (lhs.strictDoubleValue != nil && lhs.strictDoubleValue == rhs.strictDoubleValue)
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded(.towardZero) == value, value >= Double(Int64.min), value <= Double(Int64.max) { return String(Int64(value)) }
        return String(value)
    }

    private static func renderScalar(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): "\"\(s)\""
        case .int(let n): String(n)
        case .double(let d): formatNumber(d)
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        case .array, .object: JSONValue.encodeCompactJSON(["v": value])
        }
    }
}

struct PageToolDispatchError: LocalizedError, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension ToolRegistry {
    struct PageToolConfirmation: Equatable, Sendable {
        var question: String
        var detail: String
    }

    private static func siteHostLabel(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else { return urlString }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    static func confirmationForPageTool(
        tool: PageTool, siteHost: String, arguments: [String: JSONValue], confirmBeforeWrites: Bool
    ) -> PageToolConfirmation? {
        let host = siteHost.isEmpty
            ? String(localized: "this page", comment: "Fallback site label on a page-tool confirmation card when the URL has no host.")
            : siteHost
        let rawArgs = JSONValue.encodeCompactJSON(arguments)
        let argsPreview = rawArgs.count > 500 ? String(rawArgs.prefix(500)) + "…" : rawArgs
        switch tool.source {
        case .site:
            let yes = String(localized: "yes", comment: "Short boolean value on a page-tool confirmation card.")
            let no = String(localized: "no", comment: "Short boolean value on a page-tool confirmation card.")
            let readOnly = tool.annotations.readOnlyHint ? yes : no
            let consequential = tool.annotations.consequentialHint ? yes : no
            let question = String(
                localized: "Allow \(host) to run its page tool “\(tool.name)”?",
                comment: "Confirmation card: the Agent wants to call an unverified WebMCP tool registered by the website. First placeholder is the site host, second is the tool name."
            )
            let claims = String(
                localized: "Page claims (unverified): readOnlyHint=\(readOnly), consequentialHint=\(consequential)",
                comment: "Confirmation card detail: shows the website's own unverified readOnlyHint and consequentialHint claims."
            )
            return PageToolConfirmation(question: question, detail: "\(tool.prefixedName)(\(argsPreview))\n\(claims)")
        case .script:
            guard confirmBeforeWrites, !tool.annotations.readOnlyHint else { return nil }
            let question = String(
                localized: "Run script tool “\(tool.name)” on \(host)?",
                comment: "Confirmation card: Confirm before writes is on and the Agent wants to call a userscript tool not marked read-only. First placeholder is the tool name, second is the site host."
            )
            return PageToolConfirmation(question: question, detail: "\(tool.prefixedName)(\(argsPreview))")
        }
    }

    static func pageDispatcherTools(context: AgentToolContext) -> [AgentTool] {
        guard let pageTools = context.pageTools, pageTools.isEnabled else { return [] }
        return [makePageToolsListTool(pageTools: pageTools), makePageToolCallTool(context: context, pageTools: pageTools)]
    }

    private static func makePageToolsListTool(pageTools: PageToolContext) -> AgentTool {
        AgentTool(
            definition: AgentToolDefinition(
                name: "page_tools_list",
                description: "List WebMCP tools registered on the current page (`site.*` from the website, `script.*` from your userscripts) with descriptions, schemas and annotations.",
                parameters: [], required: []
            ),
            summarizeArguments: { _ in "" },
            execute: { _ in
                let snapshot = await pageTools.collectDispatcherTools()
                let entries: [JSONValue] = snapshot.tools.map { tool in
                    var item: [String: JSONValue] = [
                        "name": .string(tool.prefixedName),
                        "source": .string(tool.source.rawValue),
                        "description": .string(tool.description),
                        "annotations": .object([
                            "readOnlyHint": .bool(tool.annotations.readOnlyHint),
                            "untrustedContentHint": .bool(tool.annotations.untrustedContentHint),
                            "consequentialHint": .bool(tool.annotations.consequentialHint)
                        ])
                    ]
                    if let title = tool.title { item["title"] = .string(title) }
                    switch PageToolSchema.inspect(tool.inputSchema, schemaJSON: tool.inputSchemaJSON) {
                    case .noSchema: item["input_schema"] = .string("no schema")
                    case .checked: item["input_schema"] = tool.inputSchema ?? .string("no schema")
                    case .checkedInPart:
                        item["input_schema"] = tool.inputSchema ?? .string("no schema")
                        item["schema_check"] = .string("arguments checked in part")
                    }
                    return .object(item)
                }
                var payload: [String: JSONValue] = ["count": .int(Int64(entries.count)), "tools": .array(entries)]
                if snapshot.droppedCount > 0 { payload["dropped_count"] = .int(Int64(snapshot.droppedCount)) }
                let summary = entries.count == 1 ? "1 page tool" : "\(entries.count) page tools"
                return ToolExecutionOutput(content: JSONValue.encodeCompactJSON(payload), summary: summary, isError: false)
            }
        )
    }

    private static func makePageToolCallTool(context: AgentToolContext, pageTools: PageToolContext) -> AgentTool {
        let gate = context.confirmations, pageBridge = context.bridge, defaultConfirmWrites = context.settings.confirmBeforeWrites
        return AgentTool(
            definition: AgentToolDefinition(
                name: "page_tool_call",
                description: "Call a tool from `page_tools_list` (`site.<name>` or `script.<id>.<name>`). Every `site.*` call asks the user first.",
                parameters: [
                    ToolParameterSchema(name: "name", type: .string, description: "Prefixed tool name (`site.<name>` or `script.<id>.<name>`).", minLength: 1),
                    ToolParameterSchema(name: "arguments", type: .object, description: "JSON object of arguments for the tool.")
                ],
                required: ["name"]
            ),
            summarizeArguments: { $0["name"]?.stringValue ?? JSONValue.encodeCompactJSON($0) },
            execute: { args in
                guard let prefixedName = args["name"]?.stringValue, PageToolBridge.parsePrefixedName(prefixedName) != nil else {
                    throw PageToolDispatchError("Invalid page tool name '\(args["name"]?.stringValue ?? "")'. Expected 'site.<name>' or 'script.<id>.<name>'.")
                }
                let rawArguments = args["arguments"] ?? .object([:])
                if let alwaysError = PageToolSchema.validateAlways(rawArguments) { throw PageToolDispatchError(alwaysError) }
                let initialMeta = await pageBridge.currentPageMetadata()
                guard await pageTools.bridge.isEnabled else { throw PageToolDispatchError("Page tools are turned off.") }
                let snapshot = await pageTools.collectDispatcherTools()
                guard let tool = snapshot.tools.first(where: { $0.prefixedName == prefixedName }) else {
                    throw PageToolDispatchError("No page tool named '\(prefixedName)' is registered on the current page.")
                }
                if let schemaError = PageToolSchema.validate(arguments: rawArguments, schema: tool.inputSchema, schemaJSON: tool.inputSchemaJSON) {
                    throw PageToolDispatchError(schemaError)
                }
                let argumentsObject = rawArguments.objectValue ?? [:]
                let confirmWrites = if let override = pageTools.confirmBeforeWrites { await override() } else { defaultConfirmWrites }
                let beforeAskMeta = await pageBridge.currentPageMetadata()
                guard beforeAskMeta.url == initialMeta.url else {
                    throw PageToolDispatchError("The page changed before '\(prefixedName)' could run.")
                }
                let host = siteHostLabel(for: initialMeta.url)
                if let confirmation = confirmationForPageTool(tool: tool, siteHost: host, arguments: argumentsObject, confirmBeforeWrites: confirmWrites) {
                    let allowed = try await gate?.ask(tool: "page_tool_call", question: confirmation.question, detail: confirmation.detail) ?? false
                    guard allowed else { throw PageToolDispatchError(declinedMessage) }
                    let afterAskMeta = await pageBridge.currentPageMetadata()
                    guard afterAskMeta.url == initialMeta.url, !initialMeta.url.isEmpty || afterAskMeta.title == initialMeta.title else {
                        throw PageToolDispatchError("The page changed while waiting for confirmation; did not run '\(prefixedName)'.")
                    }
                    guard await pageTools.bridge.isEnabled else { throw PageToolDispatchError("Page tools are turned off.") }
                }
                switch await pageTools.bridge.callTool(
                    prefixedName: prefixedName, arguments: argumentsObject,
                    timeout: PageToolBridge.defaultTimeout, maxResponseBytes: PageToolBridge.defaultMaxResponseBytes
                ) {
                case .success(let result):
                    return ToolExecutionOutput(content: result.json, summary: ToolExecutionOutput.defaultSummary(for: result.json, maxChars: 80), isError: false)
                case .failure(let failure):
                    throw PageToolDispatchError(failure.message)
                }
            }
        )
    }
}
