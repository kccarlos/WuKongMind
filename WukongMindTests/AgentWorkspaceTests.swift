import Foundation
import XCTest
#if canImport(WukongMind)
@testable import WukongMind
#endif

/// `AgentWorkspace`'s path rules, caps and atomic writes, and the history
/// trimming of old `file_read` results (design-m3.md, "Workspace").
@MainActor
final class AgentWorkspaceTests: XCTestCase {
    private var sandbox: URL!
    private var root: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        root = sandbox.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func assertRefused(
        _ body: () async throws -> some Any,
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected a refusal containing '\(fragment)'", file: file, line: line)
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(fragment),
                "'\(error.localizedDescription)' lacks '\(fragment)'",
                file: file,
                line: line
            )
        }
    }

    func testWriteAppendReadRangesAndList() async throws {
        let workspace = AgentWorkspace(root: root)
        let first = try await workspace.write(path: "crawls/example.org/t/page-001.txt", content: "Hello, 世界")
        XCTAssertEqual(first.path, "crawls/example.org/t/page-001.txt")
        XCTAssertEqual(first.bytesWritten, Data("Hello, 世界".utf8).count)
        let appended = try await workspace.write(path: "./crawls/example.org/t/page-001.txt", content: "!!", append: true)
        XCTAssertEqual(appended.size, Int64(Data("Hello, 世界!!".utf8).count))

        let whole = try await workspace.read(path: "crawls/example.org/t/page-001.txt", length: 100)
        XCTAssertEqual(whole.text, "Hello, 世界!!")
        XCTAssertEqual(whole.totalCharacters, 11)
        let range = try await workspace.read(path: "crawls/example.org/t/page-001.txt", offset: 7, length: 2)
        XCTAssertEqual(range.text, "世界")
        XCTAssertEqual([range.start, range.end], [7, 9])
        let past = try await workspace.read(path: "crawls/example.org/t/page-001.txt", offset: 99, length: 5)
        XCTAssertEqual(past.text, "")

        try await workspace.write(path: "notes.md", content: "n")
        let top = try await workspace.list()
        XCTAssertEqual(top.entries.map(\.path), ["crawls", "notes.md"])
        XCTAssertEqual(top.entries.map(\.isDirectory), [true, false])
        let all = try await workspace.list(recursive: true)
        XCTAssertEqual(all.entries.map(\.path), [
            "crawls", "crawls/example.org", "crawls/example.org/t",
            "crawls/example.org/t/page-001.txt", "notes.md"
        ])

        let capped = AgentWorkspace(root: root, limits: .init(maxListEntries: 2))
        let cut = try await capped.list(recursive: true)
        XCTAssertEqual(cut.entries.count, 2)
        XCTAssertEqual(cut.remaining, 3)

        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: root.appendingPathComponent("blob.png"))
        let binary = try await workspace.read(path: "blob.png", length: 10)
        XCTAssertEqual(binary.binaryDescription, "binary file, 4 bytes, image/png")
    }

    func testDotDotAbsolutePathsAndSymlinkEscapesAreRefused() async throws {
        let workspace = AgentWorkspace(root: root)
        let outside = sandbox.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

        await assertRefused({ try await workspace.write(path: "../outside/x.txt", content: "x") }, containing: "'..'")
        await assertRefused({ try await workspace.read(path: "a/../../outside/secret.txt", length: 10) }, containing: "'..'")
        await assertRefused({ try await workspace.write(path: outside.appendingPathComponent("x.txt").path, content: "x") }, containing: "absolute")
        await assertRefused({ try await workspace.read(path: "~/secret.txt", length: 10) }, containing: "absolute")
        await assertRefused({ try await workspace.write(path: String(repeating: "a", count: 256), content: "x") }, containing: "255")

        // A folder link, a file link and a dangling link all lead outside.
        let fm = FileManager.default
        try fm.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("linkfile.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("dangling.txt"), withDestinationURL: outside.appendingPathComponent("new.txt"))
        await assertRefused({ try await workspace.read(path: "linkdir/secret.txt", length: 10) }, containing: "outside the workspace")
        await assertRefused({ try await workspace.write(path: "linkdir/new/x.txt", content: "x") }, containing: "outside the workspace")
        await assertRefused({ try await workspace.read(path: "linkfile.txt", length: 10) }, containing: "outside the workspace")
        await assertRefused({ try await workspace.write(path: "linkfile.txt", content: "overwritten") }, containing: "outside the workspace")
        await assertRefused({ try await workspace.write(path: "dangling.txt", content: "x") }, containing: "outside the workspace")
        await assertRefused({ try await workspace.list(path: "linkdir") }, containing: "outside the workspace")

        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("secret.txt"), encoding: .utf8), "secret")
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("new").path))

        // A link that stays inside the root is fine.
        try fm.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("real"))
        let written = try await workspace.write(path: "alias/inside.txt", content: "ok")
        XCTAssertEqual(written.path, "real/inside.txt")
    }

    func testFileAndWorkspaceCapsNameTheCap() async throws {
        let workspace = AgentWorkspace(root: root, limits: .init(maxFileBytes: 10, maxTotalBytes: 20))
        try await workspace.write(path: "a.txt", content: "12345")
        await assertRefused({ try await workspace.write(path: "a.txt", content: "123456", append: true) }, containing: "cap for one file is 10 bytes")
        try await workspace.write(path: "b.txt", content: "1234567890")
        await assertRefused({ try await workspace.write(path: "c.txt", content: "1234567890") }, containing: "its cap is 20 bytes")
        // Overwriting counts the file's new size, not old plus new.
        try await workspace.write(path: "b.txt", content: "0987654321")
        let text = try await workspace.read(path: "a.txt", length: 10).text
        XCTAssertEqual(text, "12345")
    }

    func testAppendInterruptedBeforeItsAtomicReplaceLeavesTheOldFileWhole() async throws {
        struct Killed: Error {}
        let workspace = AgentWorkspace(root: root)
        try await workspace.write(path: "crawl/thread.md", content: "post 1\npost 2\n")
        let sawTemporary = expectation(description: "temporary file written in full")
        await workspace.setBeforeAtomicReplaceHook { temporary in
            let staged = try String(contentsOf: temporary, encoding: .utf8)
            XCTAssertEqual(staged, "post 1\npost 2\npost 3\n")
            sawTemporary.fulfill()
            throw Killed()
        }
        do {
            try await workspace.write(path: "crawl/thread.md", content: "post 3\n", append: true)
            XCTFail("The interrupted append should fail")
        } catch {}
        await fulfillment(of: [sawTemporary], timeout: 1)

        let onDisk = try String(contentsOf: root.appendingPathComponent("crawl/thread.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, "post 1\npost 2\n")
        let leftovers = try await workspace.list(recursive: true).entries.map(\.path)
        XCTAssertEqual(leftovers, ["crawl", "crawl/thread.md"])

        await workspace.setBeforeAtomicReplaceHook(nil)
        try await workspace.write(path: "crawl/thread.md", content: "post 3\n", append: true)
        let after = try String(contentsOf: root.appendingPathComponent("crawl/thread.md"), encoding: .utf8)
        XCTAssertEqual(after, "post 1\npost 2\npost 3\n")
    }

    // MARK: - History trimming

    private final class RecordingClient: AgentModelClient, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [AgentModelTurnResponse]
        private(set) var requests: [[AgentModelTurn]] = []

        init(_ responses: [AgentModelTurnResponse]) { self.responses = responses }

        func completeToolTurn(
            system: String,
            messages: [AgentModelTurn],
            tools: [AgentToolDefinition],
            configuration: ProviderConfiguration,
            provider: AIProvider,
            maxTokens: Int
        ) async throws -> AgentModelTurnResponse {
            lock.withLock {
                requests.append(messages)
                return responses.isEmpty ? AgentModelTurnResponse(text: "Done.") : responses.removeFirst()
            }
        }
    }

    private static func fileReadContents(_ turns: [AgentModelTurn]) -> [String] {
        turns.flatMap { turn -> [String] in
            guard case .toolResults(let results) = turn else { return [] }
            return results.filter { $0.toolName == "file_read" }.map(\.content)
        }
    }

    func testRequestsCarryOnlyTheNewestThreeFileReadsWhileHistoryKeepsAll() async throws {
        let workspace = AgentWorkspace(root: root)
        try await workspace.write(path: "crawls/f/t/thread.md", content: String(repeating: "abcdefghij", count: 10))
        let scripts = ScriptStore(directoryURL: sandbox.appendingPathComponent("Scripts", isDirectory: true))
        let context = AgentToolContext(
            bridge: NoPageDriver(),
            workspace: workspace,
            scriptStore: scripts,
            settings: AgentToolSettings(truncationLimit: 20)
        )
        let offsets = [0, 20, 40, 60, 80]
        let reads = offsets.enumerated().map { index, offset in
            AgentModelTurnResponse(text: "Notes on part \(index + 1).", toolCalls: [
                AgentModelToolCall(id: "read-\(index)", name: "file_read", arguments: [
                    "path": .string("crawls/f/t/thread.md"), "offset": .int(Int64(offset))
                ])
            ])
        }
        let client = RecordingClient(reads + [AgentModelTurnResponse(text: "Summary.")])
        let loop = AgentLoop(modelClient: client, registry: ToolRegistry.m3(context: context), maxSteps: 30)
        let result = try await loop.run(
            systemPrompt: "sys",
            initialHistory: [.user("Summarize the thread")],
            configuration: ProviderConfiguration(model: "test", baseURL: AIProvider.anthropic.defaultBaseURL, apiKey: "fake"),
            provider: .anthropic
        )

        let stored = Self.fileReadContents(result.history)
        XCTAssertEqual(stored.count, 5)
        for (content, offset) in zip(stored, offsets) {
            XCTAssertTrue(content.contains("characters \(offset)–\(offset + 20) of 100"), content)
        }

        let lastRequest = try XCTUnwrap(client.requests.last)
        let sent = Self.fileReadContents(lastRequest)
        XCTAssertEqual(sent.count, 5)
        XCTAssertEqual(sent[0], "[file_read omitted, re-read by path and offset: crawls/f/t/thread.md, offset 0]")
        XCTAssertEqual(sent[1], "[file_read omitted, re-read by path and offset: crawls/f/t/thread.md, offset 20]")
        XCTAssertEqual(Array(sent[2...]), Array(stored[2...]))
        // The reply text written alongside each read stays.
        XCTAssertTrue(lastRequest.contains(.assistant(text: "Notes on part 1.", toolCalls: [
            AgentModelToolCall(id: "read-0", name: "file_read", arguments: [
                "path": .string("crawls/f/t/thread.md"), "offset": .int(0)
            ])
        ])))
        // Pruning is deterministic and leaves short histories alone.
        XCTAssertEqual(Array(AgentHistoryPruner.prune(result.history).prefix(lastRequest.count)), lastRequest)
        XCTAssertEqual(AgentHistoryPruner.prune(Array(result.history.prefix(4))), Array(result.history.prefix(4)))
    }

    private struct NoPageDriver: AgentPageDriving {
        func currentPageMetadata() async -> AgentPageMetadata { .empty }
        func readPage(mode: PageReadMode, selector: String?, maxLength: Int?) async throws -> String { "" }
        func runJS(code: String, environment: AgentExecutionEnvironment, timeout: TimeInterval) async throws -> JSExecutionResult {
            JSExecutionResult(valueJSON: nil, consoleOutput: [], error: nil)
        }
        func injectCSS(css: String, id: String?) async throws -> CSSInjectionResult {
            CSSInjectionResult(sheetID: id ?? "s", appliedRootCount: 1)
        }
        func waitFor(selector: String?, milliseconds: Int?) async throws -> WaitForResult {
            WaitForResult(mode: .delay, matched: true, elapsedMs: 0, selector: nil)
        }
    }
}
