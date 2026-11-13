import Foundation

// MARK: - Audit line

/// One JSON line of the on-disk audit log (`Application Support/WukongMind/AuditLog/<yyyy-mm-dd>.jsonl`).
/// A task opens with a `.task` line, each tool call writes one `.step` line, and a `.end` line closes it.
/// Full tool results are not here; they live in the task record (`TaskRecord.swift`).
struct AuditLine: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case task, step, fetch, confirm, end
    }

    static let maxArgumentCharacters = 4_000
    static let maxSummaryCharacters = 500
    static let maxPromptCharacters = 500

    var kind: Kind
    var time: Date
    var taskID: String
    var step: Int?
    var tool: String?
    var durationMs: Int?
    var arguments: String?
    var resultSummary: String?
    var isError: Bool?
    var truncated: Bool?
    var savedPath: String?
    var warning: String?
    var pageURL: String?
    /// Full target URL of `http_request` and `wukong.fetch`, never shortened.
    var url: String?
    var method: String?
    var question: String?
    var answer: String?
    var prompt: String?
    var model: String?
    var provider: String?
    var outcome: String?
    var steps: Int?
    var tokens: Int?

    var id: String { "\(kind.rawValue)-\(taskID)-\(step ?? -1)-\(time.timeIntervalSince1970)-\(tool ?? "")" }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }

    static func taskStart(
        taskID: String, time: Date, prompt: String, model: String?, provider: String?, pageURL: String?
    ) -> AuditLine {
        AuditLine(
            kind: .task, time: time, taskID: taskID, pageURL: pageURL,
            prompt: clip(prompt, maxPromptCharacters), model: model, provider: provider
        )
    }

    static func taskEnd(
        taskID: String, time: Date, outcome: String, steps: Int, tokens: Int, duration: TimeInterval
    ) -> AuditLine {
        AuditLine(
            kind: .end, time: time, taskID: taskID, durationMs: Int(duration * 1000),
            outcome: outcome, steps: steps, tokens: tokens
        )
    }

    /// Builds the step line for a finished tool call. Arguments and summary are redacted, then clipped.
    static func step(
        row: BrowserAgentToolCallRow, taskID: String, time: Date, pageURL: String?,
        warning: String? = nil, savedPath: String? = nil, secrets: [String] = []
    ) -> AuditLine {
        let args = UntrustedWebContent.redactSecrets(in: row.argumentsJSON, secrets: secrets)
        let summary = UntrustedWebContent.redactSecrets(in: row.resultSummary, secrets: secrets)
        var line = AuditLine(
            kind: .step, time: time, taskID: taskID, step: row.stepNumber, tool: row.toolName,
            durationMs: row.duration.map { Int($0 * 1000) },
            arguments: clip(args, maxArgumentCharacters),
            resultSummary: clip(summary, maxSummaryCharacters),
            isError: row.isError, truncated: row.wasTruncated || savedPath != nil,
            savedPath: savedPath, warning: warning, pageURL: pageURL
        )
        if row.toolName == "http_request",
           let data = row.argumentsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            line.url = object["url"] as? String
            line.method = ((object["method"] as? String) ?? "GET").uppercased()
        }
        return line
    }

    static func fetch(taskID: String, time: Date, url: String, pageURL: String?) -> AuditLine {
        AuditLine(kind: .fetch, time: time, taskID: taskID, tool: "wukong.fetch", pageURL: pageURL, url: url, method: "GET")
    }

    static func confirmation(taskID: String, time: Date, tool: String, question: String, answer: String) -> AuditLine {
        AuditLine(
            kind: .confirm, time: time, taskID: taskID, tool: tool,
            question: clip(question, maxSummaryCharacters), answer: answer
        )
    }
}

/// A task as the audit page shows it.
struct AuditTask: Identifiable, Hashable, Sendable {
    var id: String
    var start: Date
    var prompt: String
    var model: String?
    var provider: String?
    var pageURL: String?
    var outcome: String?
    var lines: [AuditLine]

    var steps: [AuditLine] { lines.filter { $0.kind == .step } }
    var hasError: Bool { steps.contains { $0.isError == true } }
    var host: String? { pageURL.flatMap { URL(string: $0)?.host } }
}

struct AuditDay: Identifiable, Equatable, Sendable {
    var id: String
    var tasks: [AuditTask]
}

// MARK: - Store

/// Appends audit lines through a serial queue and prunes by age and total size.
final class AuditLog: @unchecked Sendable {
    static let retentionDays = 30
    static let retentionBytes = 20 * 1024 * 1024

    let directory: URL
    private let now: @Sendable () -> Date
    private let maxDays: Int
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "wukongmind.auditlog")
    private let fileManager = FileManager.default

    init(
        directory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        maxDays: Int = AuditLog.retentionDays,
        maxBytes: Int = AuditLog.retentionBytes
    ) {
        self.directory = directory
        self.now = now
        self.maxDays = maxDays
        self.maxBytes = maxBytes
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WukongMind/AuditLog", isDirectory: true)
    }

    // MARK: Writing

    /// Appends one line to the file for the line's day. Blocks until it is on disk, so it is
    /// finished before the tool returns to the loop.
    func append(_ line: AuditLine) {
        queue.sync {
            guard let data = try? Self.encoder.encode(line) else { return }
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = fileURL(for: Self.dayKey(line.time))
            var payload = data
            payload.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: payload)
            } else {
                try? payload.write(to: url, options: .atomic)
            }
        }
    }

    /// Deletes day files older than the age limit, then the oldest days until the total fits.
    func prune() {
        queue.sync {
            var files = dayFiles()
            let cutoff = Self.dayKey(now().addingTimeInterval(-Double(maxDays) * 86_400))
            for file in files where file.key < cutoff {
                try? fileManager.removeItem(at: file.url)
            }
            files = dayFiles()
            var total = files.reduce(0) { $0 + $1.size }
            for file in files where total > maxBytes {
                try? fileManager.removeItem(at: file.url)
                total -= file.size
            }
        }
    }

    func clear() {
        queue.sync {
            for file in dayFiles() { try? fileManager.removeItem(at: file.url) }
        }
    }

    // MARK: Reading

    /// Every line, oldest first.
    func allLines() -> [AuditLine] {
        queue.sync {
            var result: [AuditLine] = []
            for file in dayFiles().sorted(by: { $0.key < $1.key }) {
                guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
                for raw in text.split(separator: "\n") {
                    if let line = try? Self.decoder.decode(AuditLine.self, from: Data(raw.utf8)) {
                        result.append(line)
                    }
                }
            }
            return result
        }
    }

    var stepCount: Int { allLines().filter { $0.kind == .step }.count }

    /// Days newest first; inside a day, tasks newest first. A task sits on the day it started.
    func days() -> [AuditDay] {
        Self.group(allLines())
    }

    static func group(_ lines: [AuditLine]) -> [AuditDay] {
        var order: [String] = []
        var byTask: [String: [AuditLine]] = [:]
        for line in lines {
            if byTask[line.taskID] == nil { order.append(line.taskID) }
            byTask[line.taskID, default: []].append(line)
        }
        var tasks: [AuditTask] = []
        for id in order {
            let taskLines = byTask[id] ?? []
            let head = taskLines.first { $0.kind == .task }
            let end = taskLines.last { $0.kind == .end }
            tasks.append(AuditTask(
                id: id,
                start: head?.time ?? taskLines[0].time,
                prompt: head?.prompt ?? "",
                model: head?.model,
                provider: head?.provider,
                pageURL: head?.pageURL ?? taskLines.compactMap(\.pageURL).first,
                outcome: end?.outcome,
                lines: taskLines
            ))
        }
        var days: [String: [AuditTask]] = [:]
        for task in tasks { days[dayKey(task.start), default: []].append(task) }
        return days.keys.sorted(by: >).map { key in
            AuditDay(id: key, tasks: (days[key] ?? []).sorted { $0.start > $1.start })
        }
    }

    // MARK: Files

    private struct DayFile { var key: String; var url: URL; var size: Int }

    private func dayFiles() -> [DayFile] {
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "jsonl" else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return DayFile(key: url.deletingPathExtension().lastPathComponent, url: url, size: size)
        }
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).jsonl")
    }

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
