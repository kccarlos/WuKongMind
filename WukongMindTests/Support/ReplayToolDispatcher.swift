import Foundation
#if canImport(WukongMind)
@testable import WukongMind
#endif

/// Answers tool calls from an exported task: the recorded definitions, and for each call the
/// recorded result, in recorded order per tool. A call whose name or arguments differ fails (and
/// is listed in `mismatches`). `makeResult` never runs, so truncation, saved paths, sizes and
/// previews come back exactly as recorded; `modelContent` is rebuilt with `UntrustedWebContent.wrap`.
final class ReplayToolDispatcher: ToolDispatching, @unchecked Sendable {
    struct Mismatch: Error, CustomStringConvertible {
        var description: String
    }

    let definitions: [AgentToolDefinition]
    let redactedSecrets: [String] = []
    private let lock = NSLock()
    private var queues: [String: [TaskExportDocument.ToolResult]]
    private(set) var mismatches: [String] = []

    init(_ document: TaskExportDocument) {
        definitions = document.turns.first.flatMap { document.toolSets[$0.toolsHash] } ?? []
        queues = Dictionary(grouping: document.turns.flatMap(\.toolResults), by: \.name)
    }

    func argumentSummary(for toolName: String, arguments: [String: JSONValue]) -> String { "" }

    func dispatch(toolName: String, arguments: [String: JSONValue], step: Int?) async throws -> ToolDispatchResult {
        try next(toolName, arguments: arguments, raw: nil)
    }

    func dispatch(toolName: String, rawArgumentsJSON: String, step: Int?) async throws -> ToolDispatchResult {
        try next(toolName, arguments: nil, raw: rawArgumentsJSON)
    }

    private func next(_ name: String, arguments: [String: JSONValue]?, raw: String?) throws -> ToolDispatchResult {
        try lock.withLock {
            guard var queue = queues[name], !queue.isEmpty else {
                mismatches.append("unexpected call to \(name)")
                throw Mismatch(description: "unexpected call to \(name)")
            }
            let recorded = queue.removeFirst()
            queues[name] = queue
            if let arguments, arguments != recorded.arguments {
                mismatches.append("\(name) arguments differ")
                throw Mismatch(description: "\(name) arguments differ")
            }
            if let raw, raw != recorded.rawArgumentsJSON {
                mismatches.append("\(name) raw arguments differ")
                throw Mismatch(description: "\(name) raw arguments differ")
            }
            return ToolDispatchResult(
                toolName: name, argumentSummary: "",
                argumentsJSON: raw ?? JSONValue.encodeCompactJSON(recorded.arguments),
                output: recorded.output, resultSummary: recorded.resultSummary,
                modelContent: UntrustedWebContent.wrap(recorded.output, toolName: name),
                isError: recorded.isError, wasTruncated: recorded.wasTruncated,
                totalCharacterCount: recorded.totalCharacterCount,
                duration: Double(recorded.durationMs ?? 0) / 1000,
                savedPath: recorded.savedPath, images: recorded.images
            )
        }
    }
}
