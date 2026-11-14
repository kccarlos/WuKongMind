import CryptoKit
import Foundation

struct CapabilityResolvedThread: Sendable, Equatable {
    var topic: ForumTopic
    var knownPostCount: Int
}

struct CapabilityToolError: LocalizedError, Equatable, Sendable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Shared IDs and duration estimates for `read_aloud` and its `DCListenRow`.
enum CapabilityReadAloud {
    static func pathID(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "path:\(trimmed)"
    }

    static func textID(_ text: String) -> String {
        let hex = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "text:\(hex)"
    }

    static func textTitle(_ text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? text
        let cleaned = ToolExecutionOutput.defaultSummary(for: firstLine, maxChars: 48)
        return cleaned.isEmpty ? "Selection" : cleaned
    }

    static func estimatedMinutes(for text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 1 }
        let words = trimmed.split { $0.isWhitespace || $0.isNewline }.count
        return max(1, Int(max(Double(words) / 150.0, Double(trimmed.count) / 900.0).rounded(.up)))
    }
}

/// App callbacks behind `summarize_topic`, `read_aloud`, `watch_topic`, and `notify`.
struct CapabilityToolContext: Sendable {
    var resolveTopicID: @Sendable (String) async throws -> CapabilityResolvedThread
    var resolveTopicURL: @Sendable (String) async throws -> CapabilityResolvedThread
    var summarizeThread: @Sendable (ForumTopic) async throws -> TopicSession
    var summarizeText: @Sendable (String) async throws -> String
    var existingThreadSummary: @MainActor @Sendable (String) -> TopicSession?
    var readAloud: @MainActor @Sendable (_ id: String, _ title: String, _ text: String) throws -> Int
    var followThread: @Sendable (CapabilityResolvedThread) async -> Void
    var notify: @Sendable (_ title: String, _ body: String) async throws -> Void
}

extension ToolRegistry {
    static func capabilityTools(context: AgentToolContext) -> [AgentTool] {
        guard let capabilities = context.capabilities else { return [] }
        return [
            makeSummarizeTopicTool(capabilities: capabilities, workspace: context.workspace),
            makeReadAloudTool(capabilities: capabilities, workspace: context.workspace),
            makeWatchTopicTool(capabilities: capabilities),
            makeNotifyTool(capabilities: capabilities)
        ]
    }

    private static let capabilityContentParameters: [ToolParameterSchema] = [
        ToolParameterSchema(name: "topic_id", type: .string, description: "Numeric thread ID on the currently open forum.", minLength: 1),
        ToolParameterSchema(name: "url", type: .string, description: "Full URL of a forum thread (Discourse, Hacker News, or WordPress).", minLength: 1),
        ToolParameterSchema(name: "path", type: .string, description: "Workspace-relative path of a UTF-8 text file.", minLength: 1),
        ToolParameterSchema(name: "text", type: .string, description: "Plain text to process directly.", minLength: 1)
    ]

    private static func parseSingleInput(_ args: [String: JSONValue], keys: [String], toolName: String) throws -> (key: String, value: String) {
        var provided: [(String, String)] = []
        for key in keys {
            guard let raw = args[key], raw != .null else { continue }
            let trimmed = (raw.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { throw ToolValidationError("Invalid arguments for '\(toolName)': '\(key)' must not be empty.") }
            provided.append((key, trimmed))
        }
        guard provided.count == 1, let only = provided.first else {
            let list = keys.map { "'\($0)'" }.joined(separator: ", ")
            throw ToolValidationError("Invalid arguments for '\(toolName)': provide exactly one of \(list).")
        }
        return only
    }

    private static func summarizeContentArgs(_ args: [String: JSONValue]) -> String {
        if let id = args["topic_id"]?.stringValue, !id.isEmpty { return "topic \(id)" }
        if let url = args["url"]?.stringValue, !url.isEmpty { return ToolExecutionOutput.defaultSummary(for: url, maxChars: 56) }
        if let path = args["path"]?.stringValue, !path.isEmpty { return path }
        if let text = args["text"]?.stringValue, !text.isEmpty { return ToolExecutionOutput.defaultSummary(for: text, maxChars: 48) }
        return ""
    }

    private static func resolveThread(key: String, value: String, capabilities: CapabilityToolContext) async throws -> CapabilityResolvedThread {
        key == "topic_id" ? try await capabilities.resolveTopicID(value) : try await capabilities.resolveTopicURL(value)
    }

    private static func readWorkspaceFile(path: String, workspace: AgentWorkspace?) async throws -> (relativePath: String, title: String, content: String) {
        guard let workspace else { throw CapabilityToolError("Workspace is unavailable.") }
        let read = try await workspace.read(path: path, offset: 0, length: Int.max)
        if read.binaryDescription != nil { throw CapabilityToolError("'\(read.path)' is a binary file and cannot be read as text.") }
        if read.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw CapabilityToolError("'\(read.path)' is empty.") }
        let name = URL(fileURLWithPath: read.path).lastPathComponent
        return (read.path, name.isEmpty ? read.path : name, read.text)
    }

    private static func threadShape(for session: TopicSession, fallbackCount: Int = 0) -> ForumShape {
        let count = session.summaryPostCount ?? session.totalPosts ?? (fallbackCount > 0 ? fallbackCount : nil)
        return .thread(ThreadShape(id: session.topicID, title: session.title, url: session.url.absoluteString, posts: [], totalPosts: count))
    }

    private static func makeSummarizeTopicTool(capabilities: CapabilityToolContext, workspace: AgentWorkspace?) -> AgentTool {
        let keys = ["topic_id", "url", "path", "text"]
        return AgentTool(
            definition: AgentToolDefinition(
                name: "summarize_topic",
                description: "Summarize a forum thread ('topic_id' on the open forum or 'url' on any supported Discourse, Hacker News, or WordPress thread), a workspace file ('path'), or plain 'text'.",
                parameters: capabilityContentParameters
            ),
            customValidate: { _ = try parseSingleInput($0, keys: keys, toolName: "summarize_topic") },
            summarizeArguments: { summarizeContentArgs($0) },
            execute: { args in
                let input = try parseSingleInput(args, keys: keys, toolName: "summarize_topic")
                switch input.key {
                case "topic_id", "url":
                    let resolved = try await resolveThread(key: input.key, value: input.value, capabilities: capabilities)
                    let session = try await capabilities.summarizeThread(resolved.topic)
                    let count = session.summaryPostCount ?? session.totalPosts ?? resolved.knownPostCount
                    return ToolExecutionOutput(
                        content: "Summary of \(session.title) (\(session.url.absoluteString)), \(count) posts:\n\n\(session.summary)",
                        summary: session.title,
                        shape: threadShape(for: session, fallbackCount: resolved.knownPostCount)
                    )
                case "path":
                    let file = try await readWorkspaceFile(path: input.value, workspace: workspace)
                    return ToolExecutionOutput(content: try await capabilities.summarizeText(file.content), summary: file.title)
                default:
                    return ToolExecutionOutput(content: try await capabilities.summarizeText(input.value), summary: CapabilityReadAloud.textTitle(input.value))
                }
            },
            surfaces: [.text, .voice]
        )
    }

    private static func makeReadAloudTool(capabilities: CapabilityToolContext, workspace: AgentWorkspace?) -> AgentTool {
        let keys = ["topic_id", "url", "path", "text"]
        return AgentTool(
            definition: AgentToolDefinition(
                name: "read_aloud",
                description: "Start reading a forum thread summary ('topic_id' or 'url', summarizing first if needed), a workspace file ('path'), or plain 'text' aloud in the audio player and return immediately.",
                parameters: capabilityContentParameters
            ),
            customValidate: { _ = try parseSingleInput($0, keys: keys, toolName: "read_aloud") },
            summarizeArguments: { summarizeContentArgs($0) },
            execute: { args in
                let input = try parseSingleInput(args, keys: keys, toolName: "read_aloud")
                let id: String, title: String, rawText: String, shape: ForumShape?
                switch input.key {
                case "topic_id", "url":
                    let resolved = try await resolveThread(key: input.key, value: input.value, capabilities: capabilities)
                    let cached = await capabilities.existingThreadSummary(resolved.topic.topicKey)
                    let session = if let cached { cached } else { try await capabilities.summarizeThread(resolved.topic) }
                    id = session.topicKey; title = session.title; rawText = session.summary
                    shape = threadShape(for: session, fallbackCount: resolved.knownPostCount)
                case "path":
                    let file = try await readWorkspaceFile(path: input.value, workspace: workspace)
                    id = CapabilityReadAloud.pathID(file.relativePath); title = file.title; rawText = file.content; shape = nil
                default:
                    id = CapabilityReadAloud.textID(PostCitations.stripped(input.value).trimmingCharacters(in: .whitespacesAndNewlines))
                    title = CapabilityReadAloud.textTitle(input.value); rawText = input.value; shape = nil
                }
                let minutes = try await capabilities.readAloud(id, title, rawText)
                return ToolExecutionOutput(
                    content: "Reading aloud: \(title), about \(minutes) \(minutes == 1 ? "minute" : "minutes")",
                    summary: title,
                    shape: shape
                )
            },
            surfaces: [.text, .voice],
            spokenResult: { result, _ in
                guard !result.isError else { return ToolRegistry.defaultSpokenResult(result) }
                return [
                    "status": "started",
                    "shown": .string(result.output),
                    "message": "The audio player has it (the listen row in the panel). Say in a few words that it is in the player; don't read the text yourself."
                ]
            }
        )
    }

    private static func makeWatchTopicTool(capabilities: CapabilityToolContext) -> AgentTool {
        let keys = ["topic_id", "url"]
        return AgentTool(
            definition: AgentToolDefinition(
                name: "watch_topic",
                description: "Follow a forum thread ('topic_id' on the open forum or 'url') for new-reply checks. Never unfollows.",
                parameters: Array(capabilityContentParameters.prefix(2))
            ),
            customValidate: { _ = try parseSingleInput($0, keys: keys, toolName: "watch_topic") },
            summarizeArguments: { summarizeContentArgs($0) },
            execute: { args in
                let input = try parseSingleInput(args, keys: keys, toolName: "watch_topic")
                let resolved = try await resolveThread(key: input.key, value: input.value, capabilities: capabilities)
                await capabilities.followThread(resolved)
                let count = resolved.knownPostCount > 0 ? resolved.knownPostCount : nil
                return ToolExecutionOutput(
                    content: "Following \(resolved.topic.title) (\(resolved.topic.url.absoluteString)).",
                    summary: resolved.topic.title,
                    shape: .thread(ThreadShape(id: resolved.topic.topicID, title: resolved.topic.title, url: resolved.topic.url.absoluteString, posts: [], totalPosts: count))
                )
            },
            surfaces: [.text, .voice]
        )
    }

    private static func makeNotifyTool(capabilities: CapabilityToolContext) -> AgentTool {
        AgentTool(
            definition: AgentToolDefinition(
                name: "notify",
                description: "Send an immediate local notification with 'title' and 'body'. Requests permission if not asked yet.",
                parameters: [
                    ToolParameterSchema(name: "title", type: .string, description: "Short notification title.", minLength: 1),
                    ToolParameterSchema(name: "body", type: .string, description: "Notification body message.", minLength: 1)
                ],
                required: ["title", "body"]
            ),
            customValidate: { args in
                for key in ["title", "body"] where (args[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
                    throw ToolValidationError("Invalid arguments for 'notify': '\(key)' must not be empty.")
                }
            },
            summarizeArguments: { ToolExecutionOutput.defaultSummary(for: $0["title"]?.stringValue ?? "", maxChars: 48) },
            execute: { args in
                let title = args["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let body = args["body"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try await capabilities.notify(title, body)
                return ToolExecutionOutput(content: "Sent notification: \(title)", summary: title)
            }
        )
    }
}
