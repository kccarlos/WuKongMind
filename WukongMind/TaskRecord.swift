import CryptoKit
import Foundation
import WebKit

// MARK: - Events

/// One line of `Application Support/WukongMind/Tasks/<task-id>.jsonl`.
/// Types: `task`, `host`, `history`, `system`, `tools`, `request`, `raw_request`, `raw_response`, `response`,
/// `tool_result`, `end`.
struct TaskRecordEvent: Codable, Equatable, Sendable {
    var type: String
    var time: Date
    var fields: [String: JSONValue]

    init(type: String, time: Date, fields: [String: JSONValue] = [:]) {
        self.type = type
        self.time = time
        self.fields = fields
    }

    /// The history the task started from, including its own new user turn when it has one.
    static func history(_ turns: [AgentModelTurn], time: Date) -> TaskRecordEvent {
        TaskRecordEvent(type: "history", time: time, fields: ["turns": JSONValue.encoding(turns) ?? .array([])])
    }

    static func request(
        turn: Int, historyCount: Int, systemHash: String, toolsHash: String, pageURL: String? = nil, time: Date
    ) -> TaskRecordEvent {
        var fields: [String: JSONValue] = [
            "turn": .int(Int64(turn)), "historyCount": .int(Int64(historyCount)),
            "systemHash": .string(systemHash), "toolsHash": .string(toolsHash)
        ]
        if let pageURL { fields["pageURL"] = .string(pageURL) }
        return TaskRecordEvent(type: "request", time: time, fields: fields)
    }

    /// Opens the record: what an export needs to know about the run (design-m3.md "Task export").
    static func task(
        prompt: String, provider: String, model: String, stepLimit: Int, truncationLimit: Int,
        pageURL: String, time: Date
    ) -> TaskRecordEvent {
        TaskRecordEvent(type: "task", time: time, fields: [
            "prompt": .string(String(prompt.prefix(500))), "provider": .string(provider), "model": .string(model),
            "stepLimit": .int(Int64(stepLimit)), "truncationLimit": .int(Int64(truncationLimit)),
            "pageURL": .string(pageURL)
        ])
    }

    /// `raw_request` and `raw_response` for one turn, from the captured HTTP exchange.
    static func raw(_ exchange: AgentWireExchange, turn: Int, time: Date) -> [TaskRecordEvent] {
        var response: [String: JSONValue] = ["turn": .int(Int64(turn)), "body": .string(exchange.responseBody)]
        if let status = exchange.status { response["status"] = .int(Int64(status)) }
        return [
            TaskRecordEvent(type: "raw_request", time: time, fields: [
                "turn": .int(Int64(turn)), "url": .string(exchange.url),
                "method": .string(exchange.method), "body": .string(exchange.requestBody)
            ]),
            TaskRecordEvent(type: "raw_response", time: time, fields: response)
        ]
    }

    static func response(
        _ response: AgentModelTurnResponse, model: String?, provider: String?, time: Date
    ) -> TaskRecordEvent {
        var fields: [String: JSONValue] = ["response": JSONValue.encoding(response) ?? .null]
        if let model { fields["model"] = .string(model) }
        if let provider { fields["provider"] = .string(provider) }
        return TaskRecordEvent(type: "response", time: time, fields: fields)
    }

    static func toolResult(
        call: AgentModelToolCall, output: String, isError: Bool, duration: TimeInterval?,
        wasTruncated: Bool, totalCharacterCount: Int, savedPath: String?, resultSummary: String,
        images: [AgentImage] = [], time: Date
    ) -> TaskRecordEvent {
        var fields: [String: JSONValue] = [
            "callID": .string(call.id),
            "name": .string(call.name),
            "arguments": .object(call.arguments),
            "isError": .bool(isError),
            "output": .string(output),
            "wasTruncated": .bool(wasTruncated),
            "totalCharacterCount": .int(Int64(totalCharacterCount)),
            "resultSummary": .string(resultSummary),
            "images": JSONValue.encoding(images) ?? .array([])
        ]
        if let raw = call.rawArgumentsJSON { fields["rawArgumentsJSON"] = .string(raw) }
        if let duration { fields["durationMs"] = .int(Int64(duration * 1000)) }
        if let savedPath { fields["savedPath"] = .string(savedPath) }
        return TaskRecordEvent(type: "tool_result", time: time, fields: fields)
    }
}

extension JSONValue {
    /// Round-trips any Codable value through JSON.
    static func encoding<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    func decoded<T: Decodable>(as type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Cookie source and scrub

struct KnownCookie: Hashable, Sendable {
    var name: String
    var value: String
}

/// Reads the cookies for the hosts a task touched. `nil` means the store couldn't be read.
protocol TaskCookieSource: Sendable {
    func cookies(forHosts hosts: Set<String>) async -> [KnownCookie]?
}

struct WebKitTaskCookieSource: TaskCookieSource {
    func cookies(forHosts hosts: Set<String>) async -> [KnownCookie]? {
        let all: [HTTPCookie] = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
            }
        }
        return all.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return hosts.contains { $0 == domain || $0.hasSuffix("." + domain) }
        }.map { KnownCookie(name: $0.name, value: $0.value) }
    }
}

/// Removes cookie values from a record line. Structured places are cleared whatever the value's
/// length; values of 8 or more characters are replaced anywhere; shorter ones only in structured places.
struct CookieScrubber: Sendable {
    static let marker = "[cookie]"
    static let longValueLength = 8

    var cookies: Set<KnownCookie>

    private var names: Set<String> { Set(cookies.map(\.name)) }
    private var longValues: [String] {
        cookies.map(\.value).filter { $0.count >= Self.longValueLength }.sorted { $0.count > $1.count }
    }

    func scrub(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text):
            return .string(scrubString(text))
        case .array(let items):
            return .array(items.map(scrub))
        case .object(let object):
            var result: [String: JSONValue] = [:]
            let isCookieRecord: Bool = {
                if case .string(let name)? = object["name"], names.contains(name) { return true }
                return false
            }()
            for (key, item) in object {
                let lowered = key.lowercased()
                if lowered == "cookie" || lowered == "set-cookie" { continue }
                if isCookieRecord, key == "value" {
                    result[key] = .string(Self.marker)
                } else {
                    result[key] = scrub(item)
                }
            }
            return .object(result)
        default:
            return value
        }
    }

    func scrubString(_ text: String) -> String {
        var current = text
        // A string that is itself JSON (a `cookies_get` result) is scrubbed as a tree.
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
            let scrubbed = scrub(parsed)
            if let out = try? JSONEncoder().encode(scrubbed), let string = String(data: out, encoding: .utf8) {
                current = string
            }
        }
        current = Self.replace(#"(?im)^(\s*)(set-cookie|cookie)\s*:.*$"#, in: current, with: "$1$2: \(Self.marker)")
        for name in names where !name.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            current = Self.replace(
                #"(?<![\w-])"# + escaped + #"=[^;&\s"'<>,\\]+"#, in: current,
                with: NSRegularExpression.escapedTemplate(for: name) + "=" + Self.marker
            )
        }
        for value in longValues {
            current = current.replacingOccurrences(of: value, with: Self.marker)
        }
        return current
    }

    /// Replaces long values in the serialized line, in their JSON-escaped form too (raw bodies).
    func scrubSerialized(_ line: String) -> String {
        var current = line
        for value in longValues {
            if let escaped = Self.jsonEscaped(value), escaped != value {
                current = current.replacingOccurrences(of: escaped, with: Self.marker)
            }
            current = current.replacingOccurrences(of: value, with: Self.marker)
        }
        return current
    }

    private static func jsonEscaped(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return nil }
        return String(text.dropFirst().dropLast())
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
    }
}

// MARK: - Store

/// Writes the task records and prunes them (newest 50 tasks or 200 MB). A pruned record takes its
/// `results/<task-id>/` folder in the workspace with it. Cookies are scrubbed as each line is written.
actor TaskRecordStore {
    static let retentionTasks = 50
    static let retentionBytes = 200 * 1024 * 1024

    nonisolated let directory: URL
    private let resultsRoot: URL?
    private let cookieSource: TaskCookieSource?
    private let now: @Sendable () -> Date
    private let maxTasks: Int
    private let maxBytes: Int
    private var hosts: [String: Set<String>] = [:]
    private var seen: [String: Set<KnownCookie>] = [:]
    private var writtenHashes: [String: Set<String>] = [:]

    init(
        directory: URL,
        resultsRoot: URL? = nil,
        cookieSource: TaskCookieSource? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        maxTasks: Int = TaskRecordStore.retentionTasks,
        maxBytes: Int = TaskRecordStore.retentionBytes
    ) {
        self.directory = directory
        self.resultsRoot = resultsRoot
        self.cookieSource = cookieSource
        self.now = now
        self.maxTasks = maxTasks
        self.maxBytes = maxBytes
    }

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WukongMind/Tasks", isDirectory: true)
    }

    nonisolated static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: Hosts

    /// Records that the task touched this URL's host (page loads, navigate, http_request,
    /// wukong.fetch, cookies_get), so its cookies get scrubbed.
    func touch(taskID: String, url: String?) {
        guard let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }), !host.isEmpty else { return }
        // Each new host is written too, so an export after a relaunch can check that host's cookies.
        if hosts[taskID, default: []].insert(host).inserted,
           let data = try? AuditLog.encoder.encode(TaskRecordEvent(type: "host", time: now(), fields: ["host": .string(host)])) {
            write(line: String(decoding: data, as: UTF8.self), taskID: taskID)
        }
    }

    // MARK: Writing

    /// Writes the event as one line. The system prompt and tool list are written once per hash.
    func append(taskID: String, _ event: TaskRecordEvent) async {
        var event = event
        var scrubbed = true
        if let cookieSource, let touched = hosts[taskID], !touched.isEmpty {
            if let fresh = await cookieSource.cookies(forHosts: touched) {
                seen[taskID, default: []].formUnion(fresh)
            } else {
                scrubbed = false
            }
        }
        let scrubber = CookieScrubber(cookies: seen[taskID] ?? [])
        event.fields = event.fields.mapValues(scrubber.scrub)
        var fields = event.fields
        if !scrubbed { fields["cookies_scrubbed"] = .bool(false) }
        event.fields = fields
        guard let data = try? AuditLog.encoder.encode(event), var line = String(data: data, encoding: .utf8) else { return }
        line = scrubber.scrubSerialized(line)
        write(line: line, taskID: taskID)
    }

    /// Writes the `system` and `tools` lines when their hash is new for this task and returns the hashes.
    func appendRequest(
        taskID: String, turn: Int, historyCount: Int, system: String, tools: [AgentToolDefinition],
        pageURL: String? = nil
    ) async {
        let systemHash = Self.hash(system)
        let sorted = JSONEncoder()
        sorted.outputFormatting = [.sortedKeys]
        let toolsText = (JSONValue.encoding(tools)).flatMap { try? sorted.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let toolsHash = Self.hash(toolsText)
        if writtenHashes[taskID, default: []].insert(systemHash).inserted {
            await append(taskID: taskID, TaskRecordEvent(
                type: "system", time: now(), fields: ["hash": .string(systemHash), "text": .string(system)]
            ))
        }
        if writtenHashes[taskID, default: []].insert(toolsHash).inserted {
            await append(taskID: taskID, TaskRecordEvent(
                type: "tools", time: now(),
                fields: ["hash": .string(toolsHash), "tools": JSONValue.encoding(tools) ?? .null]
            ))
        }
        await append(taskID: taskID, .request(
            turn: turn, historyCount: historyCount, systemHash: systemHash, toolsHash: toolsHash,
            pageURL: pageURL, time: now()
        ))
    }

    func finish(taskID: String) {
        hosts[taskID] = nil
        seen[taskID] = nil
        writtenHashes[taskID] = nil
    }

    private func write(line: String, taskID: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(taskID).jsonl")
        let payload = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }

    // MARK: Reading

    func events(taskID: String) -> [TaskRecordEvent] {
        let url = directory.appendingPathComponent("\(taskID).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? AuditLog.decoder.decode(TaskRecordEvent.self, from: Data($0.utf8))
        }
    }

    /// Rebuilds the task's turns from its record: the history it started from, each model response and the tool
    /// results that followed it. A result's content is its output wrapped again.
    func turns(taskID: String) -> [AgentModelTurn] {
        var turns: [AgentModelTurn] = []
        var pending: [AgentModelToolResult] = []
        func flush() {
            if !pending.isEmpty { turns.append(.toolResults(pending)); pending = [] }
        }
        for event in events(taskID: taskID) {
            switch event.type {
            case "tool_result":
                guard case .string(let id)? = event.fields["callID"],
                      case .string(let name)? = event.fields["name"],
                      case .string(let output)? = event.fields["output"] else { continue }
                var isError = false
                if case .bool(let flag)? = event.fields["isError"] { isError = flag }
                let images = event.fields["images"]?.decoded(as: [AgentImage].self) ?? []
                pending.append(AgentModelToolResult(
                    toolCallID: id, toolName: name,
                    content: UntrustedWebContent.wrap(output, toolName: name), isError: isError,
                    images: images
                ))
            case "history":
                flush()
                if let start = event.fields["turns"]?.decoded(as: [AgentModelTurn].self) { turns = start }
            case "response":
                flush()
                guard let response = event.fields["response"]?.decoded(as: AgentModelTurnResponse.self) else { continue }
                turns.append(.assistant(text: response.text, toolCalls: response.toolCalls))
            default:
                continue
            }
        }
        flush()
        return turns
    }

    func taskIDs() -> [String] {
        recordFiles().map(\.id)
    }

    // MARK: Retention

    /// Keeps the newest tasks that fit both limits and deletes the rest with their `results/` folders.
    func prune() {
        let files = recordFiles().sorted { $0.modified > $1.modified }
        var kept = 0
        var total = 0
        for file in files {
            if kept < maxTasks, total + file.size <= maxBytes {
                kept += 1
                total += file.size
            } else {
                delete(file)
            }
        }
    }

    private func delete(_ file: RecordFile) {
        let fm = FileManager.default
        try? fm.removeItem(at: file.url)
        if let resultsRoot {
            try? fm.removeItem(at: resultsRoot.appendingPathComponent(file.id, isDirectory: true))
        }
    }

    private struct RecordFile { var id: String; var url: URL; var size: Int; var modified: Date }

    private func recordFiles() -> [RecordFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "jsonl" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return RecordFile(
                id: url.deletingPathExtension().lastPathComponent, url: url,
                size: values?.fileSize ?? 0, modified: values?.contentModificationDate ?? .distantPast
            )
        }
    }
}

// MARK: - Raw capture into the record

/// Writes each turn's raw HTTP exchange to the task record, numbering turns in call order (one HTTP
/// call per model turn), and reports the body sizes for developer mode's Request and Response rows.
actor TaskWireRecorder: AgentWireRecorder {
    private let taskID: String
    private let store: TaskRecordStore
    private let secrets: [String]
    private let onSizes: @MainActor @Sendable (_ turn: Int, _ request: Int, _ response: Int) -> Void
    private var turn = 0

    init(
        taskID: String, store: TaskRecordStore, secrets: [String],
        onSizes: @escaping @MainActor @Sendable (Int, Int, Int) -> Void = { _, _, _ in }
    ) {
        self.taskID = taskID
        self.store = store
        self.secrets = secrets
        self.onSizes = onSizes
    }

    func record(_ exchange: AgentWireExchange) async {
        turn += 1
        var redacted = exchange
        redacted.url = UntrustedWebContent.redactSecrets(in: exchange.url, secrets: secrets)
        redacted.requestBody = UntrustedWebContent.redactSecrets(in: exchange.requestBody, secrets: secrets)
        redacted.responseBody = UntrustedWebContent.redactSecrets(in: exchange.responseBody, secrets: secrets)
        for event in TaskRecordEvent.raw(redacted, turn: turn, time: Date()) {
            await store.append(taskID: taskID, event)
        }
        await onSizes(turn, redacted.requestBody.utf8.count, redacted.responseBody.utf8.count)
    }
}
