import Foundation
import UniformTypeIdentifiers

/// A failure the workspace reports to the Agent as an `Error: …` tool result.
struct AgentWorkspaceError: LocalizedError, Equatable, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// The Agent's workspace of files: the app's `Documents/` folder, which the
/// Files app shows as On My iPhone › WukongMind (design-m3.md, "Workspace").
///
/// Every rule lives here: paths stay inside the root (no absolute paths, no
/// `..`, no symlink escapes), text is UTF-8, one file is at most 50 MB and the
/// whole folder at most 1 GB, and writes are atomic. Being an actor, it is the
/// one serial queue that orders the workspace's writes.
actor AgentWorkspace {
    struct Limits: Equatable, Sendable {
        var maxPathLength = 255
        var maxFileBytes: Int64 = 50 * 1_000_000
        var maxTotalBytes: Int64 = 1_000_000_000
        var maxListEntries = 500
    }

    struct ReadResult: Equatable, Sendable {
        var path: String
        var text: String
        var start: Int
        var end: Int
        var totalCharacters: Int
        /// "binary file, N bytes, <type>" when the file isn't UTF-8 text.
        var binaryDescription: String?
    }

    struct WriteResult: Equatable, Sendable {
        var path: String
        var bytesWritten: Int
        var size: Int64
    }

    struct Entry: Equatable, Sendable {
        var path: String
        var isDirectory: Bool
        var size: Int64
        var modified: Date?
    }

    /// The folder for results saved automatically, the only path the code picks.
    static let resultsFolder = "results"

    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    nonisolated let root: URL
    nonisolated let limits: Limits
    /// Test seam: runs after an append's temporary file is written and before it
    /// atomically replaces the old file.
    private var beforeAtomicReplace: (@Sendable (URL) throws -> Void)?

    init(root: URL = AgentWorkspace.defaultRoot, limits: Limits = Limits()) {
        self.root = root
        self.limits = limits
    }

    func setBeforeAtomicReplaceHook(_ hook: (@Sendable (URL) throws -> Void)?) {
        beforeAtomicReplace = hook
    }

    // MARK: - Paths

    private var fileManager: FileManager { .default }

    private func resolvedRoot() throws -> URL {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw AgentWorkspaceError("The workspace is unavailable: \(error.localizedDescription)")
        }
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func itemExists(_ url: URL) -> Bool {
        // `attributesOfItem` doesn't follow a final symlink, so a dangling link counts as present.
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func isSymlink(_ url: URL) -> Bool {
        let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return type == .typeSymbolicLink
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        return parts.count >= rootParts.count && Array(parts.prefix(rootParts.count)) == rootParts
    }

    /// Resolves a workspace-relative `path` to a URL that is still inside the
    /// root after symlinks are followed, with its standardised relative path.
    func resolve(_ path: String, allowRoot: Bool = false) throws -> (url: URL, relative: String) {
        if path.count > limits.maxPathLength {
            throw AgentWorkspaceError("Path is longer than \(limits.maxPathLength) characters.")
        }
        if path.hasPrefix("/") || path.hasPrefix("~") {
            throw AgentWorkspaceError("Path '\(path)' is absolute; use a path relative to the workspace root.")
        }
        if path.contains("\0") || path.contains("\\") {
            throw AgentWorkspaceError("Path '\(path)' contains a character that isn't allowed.")
        }
        let parts = path.split(separator: "/").map(String.init).filter { $0 != "." }
        if parts.contains("..") {
            throw AgentWorkspaceError("Path '\(path)' contains '..'; paths must stay inside the workspace.")
        }
        let rootURL = try resolvedRoot()
        if parts.isEmpty {
            guard allowRoot else { throw AgentWorkspaceError("Path must name a file in the workspace.") }
            return (rootURL, "")
        }

        // Follow symlinks through the deepest part of the path that exists, so a
        // link anywhere along it (to a folder or a file) can't lead outside.
        var existing = rootURL
        var tail: [String] = []
        for (index, part) in parts.enumerated() {
            let next = existing.appendingPathComponent(part)
            if itemExists(next) {
                existing = next
            } else {
                tail = Array(parts[index...])
                break
            }
        }
        let resolvedExisting = existing.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isInside(resolvedExisting, root: rootURL), !isSymlink(resolvedExisting) else {
            throw AgentWorkspaceError("Path '\(path)' leads outside the workspace.")
        }
        let url = tail.reduce(resolvedExisting) { $0.appendingPathComponent($1) }
        let relative = Array(url.pathComponents.dropFirst(rootURL.pathComponents.count)).joined(separator: "/")
        return (url, relative)
    }

    // MARK: - Read

    /// Reads characters `offset ..< offset + length` of a UTF-8 text file.
    func read(path: String, offset: Int = 0, length: Int) throws -> ReadResult {
        let (url, relative) = try resolve(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AgentWorkspaceError("No file at '\(relative)'.")
        }
        guard !isDirectory.boolValue else {
            throw AgentWorkspaceError("'\(relative)' is a folder; use file_list.")
        }
        let size = fileSize(url)
        guard size <= limits.maxFileBytes else {
            throw AgentWorkspaceError("'\(relative)' is \(Self.formatBytes(size)); the cap for one file is \(Self.formatBytes(limits.maxFileBytes)).")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AgentWorkspaceError("Couldn't read '\(relative)': \(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return ReadResult(
                path: relative, text: "", start: 0, end: 0, totalCharacters: 0,
                binaryDescription: "binary file, \(data.count) bytes, \(type)"
            )
        }
        let total = text.count
        let start = min(max(0, offset), total)
        let end = min(start + max(0, length), total)
        let startIndex = text.index(text.startIndex, offsetBy: start)
        let endIndex = text.index(startIndex, offsetBy: end - start)
        return ReadResult(path: relative, text: String(text[startIndex..<endIndex]), start: start, end: end, totalCharacters: total)
    }

    // MARK: - Write

    /// Writes UTF-8 `content`, replacing the file or appending to it. Both are
    /// atomic: a kill leaves the file as it was or with the write complete.
    func write(path: String, content: String, append: Bool = false) throws -> WriteResult {
        let (url, relative) = try resolve(path)
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue {
            throw AgentWorkspaceError("'\(relative)' is a folder.")
        }
        let newBytes = Data(content.utf8)
        let oldSize = exists ? fileSize(url) : 0
        let newSize = append ? oldSize + Int64(newBytes.count) : Int64(newBytes.count)
        if newSize > limits.maxFileBytes {
            throw AgentWorkspaceError("'\(relative)' would be \(Self.formatBytes(newSize)); the cap for one file is \(Self.formatBytes(limits.maxFileBytes)).")
        }
        let total = totalSize() - oldSize + newSize
        if total > limits.maxTotalBytes {
            throw AgentWorkspaceError("The workspace would be \(Self.formatBytes(total)); its cap is \(Self.formatBytes(limits.maxTotalBytes)). Delete files in the Files app first.")
        }

        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if append, exists {
                var combined = try Data(contentsOf: url)
                combined.append(newBytes)
                try replaceAtomically(url, with: combined)
            } else {
                try newBytes.write(to: url, options: .atomic)
            }
        } catch let error as AgentWorkspaceError {
            throw error
        } catch {
            throw AgentWorkspaceError("Couldn't write '\(relative)': \(error.localizedDescription)")
        }
        return WriteResult(path: relative, bytesWritten: newBytes.count, size: newSize)
    }

    private func replaceAtomically(_ url: URL, with data: Data) throws {
        let scratch = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: url,
            create: true
        )
        defer { try? fileManager.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temporary)
        try beforeAtomicReplace?(temporary)
        _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
    }

    // MARK: - List

    /// Lists a folder (the root by default), sorted by path, at most
    /// `limits.maxListEntries` entries; `remaining` counts the rest.
    func list(path: String = "", recursive: Bool = false) throws -> (entries: [Entry], remaining: Int) {
        let (url, relative) = try resolve(path, allowRoot: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AgentWorkspaceError("No folder at '\(relative)'.")
        }
        guard isDirectory.boolValue else {
            throw AgentWorkspaceError("'\(relative)' is a file; use file_read.")
        }
        let rootURL = try resolvedRoot()
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var urls: [URL]
        if recursive {
            let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            urls = (enumerator?.allObjects as? [URL]) ?? []
        } else {
            urls = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }
        var entries: [Entry] = urls.map { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL
            let itemPath = Array(resolved.pathComponents.dropFirst(rootURL.pathComponents.count)).joined(separator: "/")
            let directory = values?.isDirectory ?? false
            return Entry(
                path: itemPath,
                isDirectory: directory,
                size: directory ? 0 : Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate
            )
        }
        entries.sort { $0.path < $1.path }
        let shown = Array(entries.prefix(limits.maxListEntries))
        return (shown, entries.count - shown.count)
    }

    // MARK: - Sizes

    func totalSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}
