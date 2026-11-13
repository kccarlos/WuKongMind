import Foundation

// The workspace tools (`file_read`, `file_write`, `file_list`) and the one
// helper that saves a tool's full output to a workspace file: `save_to` on
// `read_page`, `run_js` and (task 5) `http_request`, and results over the limit
// (design-m3.md, "Workspace").

extension ToolRegistry {
    /// Characters of preview after a `save_to` save.
    static let saveToPreviewLength = 500
    /// Characters of preview after a result over the limit is saved.
    static let savedResultPreviewLength = 2_000

    static let saveToParameter = ToolParameterSchema(
        name: "save_to",
        type: .string,
        description: "Optional workspace path. Saves the full result to that file and returns only the path, the size and a short preview.",
        minLength: 1
    )

    /// Saves `text` to `path` in the workspace (replacing the file) and returns
    /// the notice the model gets instead: the path, the size and a preview.
    static func saveOutput(
        _ text: String,
        to path: String,
        workspace: AgentWorkspace,
        secrets: [String] = [],
        previewLength: Int = saveToPreviewLength
    ) async throws -> (path: String, notice: String) {
        let text = UntrustedWebContent.redactSecrets(in: text, secrets: secrets)
        let written = try await workspace.write(path: path, content: text)
        let preview = String(text.prefix(previewLength))
        var lines = ["Saved to \(written.path) (\(grouped(text.count)) characters)."]
        if !preview.isEmpty {
            lines.append("Preview (first \(grouped(preview.count)) characters):\n\(preview)")
        }
        lines.append("Read more with file_read(path, offset).")
        return (written.path, lines.joined(separator: "\n"))
    }

    /// `results/<task-id>/<step>-<tool>.txt`, where an over-limit result goes.
    static func resultPath(taskID: String, step: Int?, toolName: String) -> String {
        let safe: (String) -> String = { raw in
            String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        }
        let stepPart = step.map { String(format: "%02d", $0) } ?? String(UUID().uuidString.prefix(8))
        return "\(AgentWorkspace.resultsFolder)/\(safe(taskID))/\(stepPart)-\(safe(toolName)).txt"
    }

    static func grouped(_ number: Int) -> String {
        number.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    static func workspaceTools(context: AgentToolContext) -> [AgentTool] {
        guard let workspace = context.workspace else { return [] }
        let limit = max(1, context.settings.truncationLimit)
        return [
            makeFileReadTool(workspace: workspace, limit: limit),
            makeFileWriteTool(workspace: workspace),
            makeFileListTool(workspace: workspace)
        ]
    }

    private static let pathParameter = ToolParameterSchema(
        name: "path",
        type: .string,
        description: "Path relative to the workspace root, for example 'crawls/example.org/thread/notes.md'.",
        minLength: 1
    )

    private static func makeFileReadTool(workspace: AgentWorkspace, limit: Int) -> AgentTool {
        AgentTool(
            definition: AgentToolDefinition(
                name: "file_read",
                description: """
                Read a UTF-8 text file from the workspace, \(grouped(limit)) characters at a time. \
                For a longer file, call again with the 'offset' the result names.
                """,
                parameters: [
                    pathParameter,
                    ToolParameterSchema(
                        name: "offset",
                        type: .integer,
                        description: "Character to start at (default 0).",
                        minimum: 0
                    ),
                    ToolParameterSchema(
                        name: "length",
                        type: .integer,
                        description: "Characters to read (default and maximum \(limit)).",
                        minimum: 1,
                        maximum: Double(limit)
                    )
                ],
                required: ["path"]
            ),
            summarizeArguments: { args in
                let path = args["path"]?.stringValue ?? ""
                let offset = args["offset"]?.strictIntValue ?? 0
                return offset > 0 ? "\(path) @ \(offset)" : path
            },
            execute: { args in
                let read = try await workspace.read(
                    path: args["path"]?.stringValue ?? "",
                    offset: args["offset"]?.strictIntValue ?? 0,
                    length: args["length"]?.strictIntValue ?? limit
                )
                if let binary = read.binaryDescription {
                    return ToolExecutionOutput(content: binary, summary: binary, isRanged: true)
                }
                var content = "\(read.path) · characters \(read.start)–\(read.end) of \(read.totalCharacters)\n\(read.text)"
                if read.end < read.totalCharacters {
                    content += "\nmore: call again with offset \(read.end)"
                }
                return ToolExecutionOutput(
                    content: content,
                    summary: "\(grouped(read.end - read.start)) of \(grouped(read.totalCharacters))",
                    isRanged: true
                )
            }
        )
    }

    private static func makeFileWriteTool(workspace: AgentWorkspace) -> AgentTool {
        AgentTool(
            definition: AgentToolDefinition(
                name: "file_write",
                description: """
                Write UTF-8 text to a workspace file, creating folders as needed. 'overwrite' \
                (default) replaces the file; 'append' adds to its end. Writes are atomic.
                """,
                parameters: [
                    pathParameter,
                    ToolParameterSchema(name: "content", type: .string, description: "The text to write."),
                    ToolParameterSchema(
                        name: "mode",
                        type: .string,
                        description: "'overwrite' (default) or 'append'.",
                        enumValues: ["overwrite", "append"]
                    )
                ],
                required: ["path", "content"]
            ),
            summarizeArguments: { args in
                let path = args["path"]?.stringValue ?? ""
                return args["mode"]?.stringValue == "append" ? "\(path) (append)" : path
            },
            execute: { args in
                let written = try await workspace.write(
                    path: args["path"]?.stringValue ?? "",
                    content: args["content"]?.stringValue ?? "",
                    append: args["mode"]?.stringValue == "append"
                )
                let json = encodeJSON(.object([
                    "path": .string(written.path),
                    "bytes_written": .int(Int64(written.bytesWritten)),
                    "size": .int(written.size)
                ]))
                return ToolExecutionOutput(content: json, summary: written.path)
            }
        )
    }

    private static func makeFileListTool(workspace: AgentWorkspace) -> AgentTool {
        AgentTool(
            definition: AgentToolDefinition(
                name: "file_list",
                description: "List files and folders in the workspace (the root by default), sorted by path.",
                parameters: [
                    ToolParameterSchema(
                        name: "path",
                        type: .string,
                        description: "Folder relative to the workspace root (default: the root)."
                    ),
                    ToolParameterSchema(
                        name: "recursive",
                        type: .boolean,
                        description: "Include everything below the folder (default false)."
                    )
                ]
            ),
            summarizeArguments: { args in
                let path = args["path"]?.stringValue ?? ""
                let shown = path.isEmpty ? "/" : path
                return args["recursive"]?.strictBoolValue == true ? "\(shown) (recursive)" : shown
            },
            execute: { args in
                let listing = try await workspace.list(
                    path: args["path"]?.stringValue ?? "",
                    recursive: args["recursive"]?.strictBoolValue ?? false
                )
                let formatter = ISO8601DateFormatter()
                let entries: [JSONValue] = listing.entries.map { entry in
                    var object: [String: JSONValue] = [
                        "path": .string(entry.path),
                        "type": .string(entry.isDirectory ? "directory" : "file"),
                        "size": .int(entry.size)
                    ]
                    if let modified = entry.modified {
                        object["modified"] = .string(formatter.string(from: modified))
                    }
                    return .object(object)
                }
                var content = encodeJSON(.array(entries))
                if listing.remaining > 0 {
                    content += "\n\(listing.remaining) more"
                }
                let count = listing.entries.count + listing.remaining
                return ToolExecutionOutput(content: content, summary: "\(count) entr\(count == 1 ? "y" : "ies")")
            }
        )
    }

    /// Compact JSON that leaves the slashes in paths alone.
    private static func encodeJSON(_ value: JSONValue) -> String {
        let object = value.toFoundation()
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}
