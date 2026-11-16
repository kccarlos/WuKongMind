import Foundation

/// A whole thread read through a site's learned `read_topic` reader, as plain text, for the
/// capabilities (`summarize_topic`, `read_aloud`). It goes through the same gate and reader
/// call as the slot itself (`design-learn-on-ask.md` "Capabilities on a learned thread").
struct LearnedThreadText: Equatable, Sendable {
    var title: String
    var url: String
    var postCount: Int
    var text: String
    /// Same thread and size, so a kept summary still fits.
    var cacheKey: String { "\(url)#\(postCount)" }
}

enum LearnedThreadReader {
    /// A reader's pages are read at most this far for one summary.
    static let maxPages = 10

    /// True when `rawURL` is a thread URL of the site the open page is on, and that site has a
    /// learned `read_topic` reader.
    @MainActor
    static func isLearnedThread(_ rawURL: String, learned: LearnedSiteContext?, scriptStore: ScriptStore) -> Bool {
        guard let learned, learned.pageToolBridge.isEnabled, SiteToolState.sameSiteURL(rawURL, host: learned.host) != nil else { return false }
        let slotState = (learned.stateStore?.state(forHost: learned.host) ?? learned.state).slot(.readTopic)
        return slotState.scriptID.flatMap { scriptStore.script(id: $0) } != nil
            && [.learned, .broken, .failed].contains(slotState.status)
    }

    static func read(
        url rawURL: String, learned: LearnedSiteContext, scriptStore: ScriptStore, openPageURL: String
    ) async throws -> LearnedThreadText {
        let gate = await ToolRegistry.learnedSlotGate(slot: .readTopic, learned: learned, scriptStore: scriptStore)
        if let refusal = gate.refusal { throw CapabilityToolError(refusal.content) }
        guard let scriptID = gate.scriptID, let url = SiteToolState.sameSiteURL(rawURL, host: learned.host) else {
            throw CapabilityToolError("That address is not on this site.")
        }

        var posts: [ThreadShape.Post] = []
        var first: ThreadShape?
        var page = 1
        var totalPages = 1
        while page <= min(totalPages, maxPages) {
            let call = await ToolRegistry.callLearnedReader(
                slot: .readTopic, scriptID: scriptID,
                payload: ["url": .string(url.absoluteString), "page": .int(Int64(page))],
                learned: learned, shapeNoun: "thread", as: ThreadShape.self
            )
            if let error = call.error { throw CapabilityToolError(error.content) }
            guard let envelope = call.envelope else { throw CapabilityToolError("The reading tool returned no thread.") }
            if envelope.currentPageOnly == true, !SiteToolState.isSameDocument(url, openURLString: openPageURL) {
                throw CapabilityToolError("Open that thread first.")
            }
            guard !envelope.shape.posts.isEmpty else { throw CapabilityToolError("The reading tool returned no posts.") }
            first = first ?? envelope.shape
            posts += envelope.shape.posts
            totalPages = max(totalPages, envelope.totalPages ?? 1)
            if envelope.totalPages == nil, envelope.nextPage == nil { break }
            page = (envelope.nextPage.flatMap { $0 > page ? $0 : nil }) ?? page + 1
        }
        guard let head = first else { throw CapabilityToolError("The reading tool returned no thread.") }
        var thread = head
        thread.posts = posts
        let title = head.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return LearnedThreadText(
            title: title.isEmpty ? url.absoluteString : title, url: url.absoluteString,
            postCount: head.totalPosts ?? posts.count, text: ForumRendering.rawTopicText(from: thread)
        )
    }
}

/// Summaries of learned threads kept for one conversation, by thread URL and post count.
final class LearnedSummaryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [String: String] = [:]
    private var order: [String] = []
    private let limit = 20

    func summary(for key: String) -> String? { lock.withLock { summaries[key] } }

    func store(_ summary: String, for key: String) {
        lock.withLock {
            if summaries[key] == nil { order.append(key) }
            summaries[key] = summary
            while order.count > limit { summaries[order.removeFirst()] = nil }
        }
    }
}
