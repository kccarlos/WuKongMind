import Foundation

// MARK: - The file

/// One exported task (design-m3.md "Task export"), built from its task record. The app and the
/// replay tests decode it with the same code (`TaskExport.load`).
struct TaskExportDocument: Codable, Equatable, Sendable {
    struct AppInfo: Codable, Equatable, Sendable {
        var version: String
        var build: String
    }

    struct RawRequest: Codable, Equatable, Sendable {
        var url: String
        var method: String
        var body: String
    }

    struct RawResponse: Codable, Equatable, Sendable {
        var status: Int?
        var body: String
    }

    /// A `tool_result` line of the record, with its field names. `output` is the dispatch output
    /// before wrapping; `UntrustedWebContent.wrap` rebuilds what the model saw.
    struct ToolResult: Codable, Equatable, Sendable {
        var callID: String
        var name: String
        var arguments: [String: JSONValue]
        var rawArgumentsJSON: String?
        var output: String
        var isError: Bool
        var durationMs: Int?
        var wasTruncated: Bool
        var totalCharacterCount: Int
        var savedPath: String?
        var resultSummary: String
        var images: [AgentImage]
        var shape: ForumShape?
    }

    struct Turn: Codable, Equatable, Sendable {
        var turn: Int
        var systemHash: String
        var toolsHash: String
        var historyCount: Int
        var pageURL: String?
        var rawRequest: RawRequest?
        var rawResponse: RawResponse?
        var model: String?
        var response: AgentModelTurnResponse?
        var toolResults: [ToolResult]

        enum CodingKeys: String, CodingKey {
            case turn, model, response
            case systemHash = "system_hash", toolsHash = "tool_set_hash", historyCount = "history_count"
            case pageURL = "page_url", rawRequest = "raw_request", rawResponse = "raw_response"
            case toolResults = "tool_results"
        }
    }

    var format = TaskExport.format
    var version = TaskExport.version
    var app: AppInfo
    var exportedAt: Date
    var provider: String?
    var model: String?
    var stepLimit: Int?
    var truncationLimit: Int?
    var startPageURL: String?
    var systems: [String: String] = [:]
    var toolSets: [String: [AgentToolDefinition]] = [:]
    var history: [AgentModelTurn] = []
    var turns: [Turn] = []
    var omittedRawRequests: [Int] = []

    enum CodingKeys: String, CodingKey {
        case format, version, app, provider, model, systems, history, turns
        case exportedAt = "exported_at", stepLimit = "step_limit", truncationLimit = "truncation_limit"
        case startPageURL = "start_page_url", toolSets = "tool_sets", omittedRawRequests = "omitted_raw_requests"
    }

    /// The history the task started from (the first request's history).
    var startHistory: [AgentModelTurn] {
        Array(history.prefix(turns.first?.historyCount ?? history.count))
    }
}

enum TaskExportError: Error, Equatable {
    case notFound
    case invalidFormat
    /// A record line is marked `"cookies_scrubbed": false`, the cookie store can't be read, or a
    /// current cookie value is still in the file.
    case cookiesRemain
    case keyRemains
}

// MARK: - Build, redact, check and load

enum TaskExport {
    static let format = "wukongmind-task"
    static let version = 1
    /// Past this, the raw request bodies of the middle turns are dropped.
    static let maxBytes = 25 * 1024 * 1024

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()

    static var currentApp: TaskExportDocument.AppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return .init(
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? ""
        )
    }

    static func load(_ data: Data) throws -> TaskExportDocument {
        guard let document = try? AuditLog.decoder.decode(TaskExportDocument.self, from: data),
              document.format == format else { throw TaskExportError.invalidFormat }
        return document
    }

    /// The hosts the task touched, as its record lists them.
    static func hosts(in events: [TaskRecordEvent]) -> Set<String> {
        var hosts = Set<String>()
        for event in events {
            if event.type == "host", case .string(let host)? = event.fields["host"] { hosts.insert(host) }
            if event.type == "task", case .string(let url)? = event.fields["pageURL"],
               let host = URL(string: url)?.host?.lowercased() { hosts.insert(host) }
        }
        return hosts
    }

    /// Reads the task's record, the cookies current for its hosts, builds the file and writes it to
    /// a temporary folder for the share sheet.
    static func export(
        taskID: String, store: TaskRecordStore, cookieSource: TaskCookieSource, secrets: [String]
    ) async throws -> URL {
        let events = await store.events(taskID: taskID)
        guard !events.isEmpty else { throw TaskExportError.notFound }
        let hosts = hosts(in: events)
        var cookies: [KnownCookie] = []
        if !hosts.isEmpty {
            guard let current = await cookieSource.cookies(forHosts: hosts) else { throw TaskExportError.cookiesRemain }
            cookies = current
        }
        let file = try build(events: events, secrets: secrets, cookies: cookies, app: currentApp, now: Date())
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wukong-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(file.filename)
        try file.data.write(to: url, options: .atomic)
        return url
    }

    /// Builds the file from the record's lines. The lines are scrubbed again with `cookies` (the
    /// values current at export) before `history` is derived from them, so the history and the tool
    /// results stay identical. Refuses on an unscrubbed line, a surviving key or cookie value.
    static func build(
        events: [TaskRecordEvent], secrets: [String], cookies: [KnownCookie],
        app: TaskExportDocument.AppInfo, now: Date, maxBytes: Int = TaskExport.maxBytes
    ) throws -> (filename: String, data: Data) {
        if events.contains(where: { $0.fields["cookies_scrubbed"] == .bool(false) }) {
            throw TaskExportError.cookiesRemain
        }
        let scrubber = CookieScrubber(cookies: Set(cookies))
        var document = TaskExportDocument(app: app, exportedAt: now)
        var startHistory: [AgentModelTurn] = []
        var startTime = now
        var prompt = ""
        for event in events {
            let fields = event.fields.mapValues(scrubber.scrub)
            func string(_ key: String) -> String? { if case .string(let value)? = fields[key] { value } else { nil } }
            func int(_ key: String) -> Int? { if case .int(let value)? = fields[key] { Int(value) } else { nil } }
            switch event.type {
            case "task":
                startTime = event.time
                prompt = string("prompt") ?? ""
                document.provider = string("provider")
                document.model = string("model")
                document.stepLimit = int("stepLimit")
                document.truncationLimit = int("truncationLimit")
                document.startPageURL = string("pageURL")
            case "system":
                if let hash = string("hash") { document.systems[hash] = string("text") ?? "" }
            case "tools":
                if let hash = string("hash") {
                    document.toolSets[hash] = fields["tools"]?.decoded(as: [AgentToolDefinition].self) ?? []
                }
            case "history":
                startHistory = fields["turns"]?.decoded(as: [AgentModelTurn].self) ?? []
            case "request":
                document.turns.append(.init(
                    turn: int("turn") ?? document.turns.count + 1, systemHash: string("systemHash") ?? "",
                    toolsHash: string("toolsHash") ?? "", historyCount: int("historyCount") ?? 0,
                    pageURL: string("pageURL"), toolResults: []
                ))
            case "raw_request" where !document.turns.isEmpty:
                document.turns[document.turns.count - 1].rawRequest = .init(
                    url: string("url") ?? "", method: string("method") ?? "", body: string("body") ?? ""
                )
            case "raw_response" where !document.turns.isEmpty:
                document.turns[document.turns.count - 1].rawResponse = .init(status: int("status"), body: string("body") ?? "")
            case "response" where !document.turns.isEmpty:
                document.turns[document.turns.count - 1].response = fields["response"]?.decoded(as: AgentModelTurnResponse.self)
                document.turns[document.turns.count - 1].model = string("model")
            case "tool_result" where !document.turns.isEmpty:
                if let result = JSONValue.object(fields).decoded(as: TaskExportDocument.ToolResult.self) {
                    document.turns[document.turns.count - 1].toolResults.append(result)
                }
            default:
                continue
            }
        }
        document.history = history(start: startHistory, turns: document.turns)

        var data = try encoder.encode(document)
        if data.count > maxBytes, document.turns.count > 2 {
            for index in document.turns.indices.dropFirst().dropLast() where document.turns[index].rawRequest != nil {
                document.turns[index].rawRequest = nil
                document.omittedRawRequests.append(document.turns[index].turn)
            }
            data = try encoder.encode(document)
        }
        let text = UntrustedWebContent.redactSecrets(in: String(decoding: data, as: UTF8.self), secrets: secrets)
        for secret in secrets {
            let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, text.contains(key) { throw TaskExportError.keyRemains }
        }
        if containsCookie(text, cookies: cookies) { throw TaskExportError.cookiesRemain }
        return (filename(prompt: prompt, date: startTime), Data(text.utf8))
    }

    /// The transcript the loop built: the start history, then each turn's assistant message and its
    /// wrapped tool results. A final reply with no text isn't added, as in `AgentLoop`.
    static func history(start: [AgentModelTurn], turns: [TaskExportDocument.Turn]) -> [AgentModelTurn] {
        var history = start
        for turn in turns {
            guard let response = turn.response else { continue }
            if response.toolCalls.isEmpty {
                if !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    history.append(.assistant(text: response.text, toolCalls: []))
                }
                continue
            }
            history.append(.assistant(text: response.text, toolCalls: response.toolCalls))
            if !turn.toolResults.isEmpty {
                history.append(.toolResults(turn.toolResults.map {
                    AgentModelToolResult(
                        toolCallID: $0.callID, toolName: $0.name,
                        content: UntrustedWebContent.wrap($0.output, toolName: $0.name),
                        isError: $0.isError, images: $0.images
                    )
                }))
            }
        }
        return history
    }

    /// Any current cookie value of 8 or more characters (plain or JSON-escaped), or any
    /// `name=value` pair of a current cookie.
    static func containsCookie(_ text: String, cookies: [KnownCookie]) -> Bool {
        for cookie in cookies where !cookie.value.isEmpty {
            if cookie.value.count >= CookieScrubber.longValueLength {
                if text.contains(cookie.value) { return true }
                if let data = try? JSONEncoder().encode(cookie.value),
                   text.contains(String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())) { return true }
            }
            let pattern = #"(?<![\w-])"# + NSRegularExpression.escapedPattern(for: "\(cookie.name)=\(cookie.value)")
                + #"(?![^;&\s"'<>,\\])"#
            if text.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    static func filename(prompt: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let words = prompt.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.prefix(6)
        let slug = String(words.joined(separator: "-").prefix(40))
        return "wukong-task-\(formatter.string(from: date))-\(slug.isEmpty ? "task" : slug).json"
    }

    /// One turn's raw request and response from the record, pretty-printed (developer mode's sheets).
    static func rawBodies(turn: Int, in events: [TaskRecordEvent]) -> (request: String?, response: String?) {
        var request: String?
        var response: String?
        for event in events where event.fields["turn"] == .int(Int64(turn)) {
            guard case .string(let body)? = event.fields["body"] else { continue }
            if event.type == "raw_request" {
                var head = ""
                if case .string(let method)? = event.fields["method"], case .string(let url)? = event.fields["url"] {
                    head = "\(method) \(url)\n\n"
                }
                request = head + prettyJSON(body)
            } else if event.type == "raw_response" {
                response = prettyJSON(body)
            }
        }
        return (request, response)
    }

    static func prettyJSON(_ text: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return text }
        return String(decoding: data, as: UTF8.self)
    }
}
