import Foundation

// MARK: - Suggestion routing and context hand-off (One panel 2b)
//
// Transitional routing (next-phase §7): on built-in forums the thread
// suggestions run the existing engines (summary, podcast read-aloud, Research,
// follow). Each result is attached once, as context, to the Agent's next
// message so follow-up questions see it (`takeAgentHandoffContext`).
//
// - `suggestSummary()`              summary engine for the open thread
// - `suggestReadAloud()`            reads the summary aloud (summarizes first)
// - `completePendingReadAloud()`    reads it once the summary is written
// - `suggestFollow()`               follows the open thread (never unfollows)
// - `startSuggestedResearch(_:)`    old Research loop on the page's forum
// - `takeAgentHandoffContext()`     finished results as context, once each

/// An old-engine result the Agent's next message carries as context.
enum AgentHandoff: Equatable {
    case summary(topicKey: String)
    case research(runID: UUID)
    case follow(title: String, url: URL)
}

extension AppModel {
    /// The longest piece of one result the Agent gets.
    static let handoffCharacterLimit = 8_000

    func suggestSummary() {
        guard let topic = currentTopic else { return }
        startSummary()
        addHandoff(.summary(topicKey: topic.topicKey))
    }

    func suggestReadAloud() {
        guard let topic = currentTopic else { return }
        addHandoff(.summary(topicKey: topic.topicKey))
        if summaryIsRunning(topicKey: topic.topicKey) || currentSession?.hasSummary != true {
            pendingReadAloudTopicKey = topic.topicKey
            startSummary()
        } else {
            readSummaryAloud(topicKey: topic.topicKey)
        }
    }

    /// Called when the summary state changes: reads a summary "Read it to
    /// me" waited for, or gives up when the run ended without one.
    func completePendingReadAloud() {
        guard let key = pendingReadAloudTopicKey, !summaryIsRunning(topicKey: key) else { return }
        pendingReadAloudTopicKey = nil
        if sessions[key]?.hasSummary == true { readSummaryAloud(topicKey: key) }
    }

    /// Follows the open thread; true when it is (or already was) followed.
    @discardableResult
    func suggestFollow() -> Bool {
        guard let topic = currentTopic else { return false }
        if !isWatched(topicKey: topic.topicKey) { toggleWatchCurrentTopic() }
        addHandoff(.follow(title: topic.title, url: topic.url))
        return true
    }

    /// The completed "Search this forum …" goes to the old Research loop on
    /// the page's forum and shows in the conversation.
    func startSuggestedResearch(_ query: String) {
        researchFillPending = false
        let before = selectedAgentRunID
        assistantMode = .agent
        startAgentRun(goal: query, siteURL: assistantForum?.siteURL)
        agentComposesNewQuestion = false
        if let id = selectedAgentRunID, id != before { addHandoff(.research(runID: id)) }
    }

    /// Finished results not handed over yet, as one context block; results
    /// still running stay for a later message.
    func takeAgentHandoffContext() -> String? {
        var parts: [String] = []
        var waiting: [AgentHandoff] = []
        for handoff in agentHandoffs {
            switch handoff {
            case .summary(let key):
                if summaryIsRunning(topicKey: key) {
                    waiting.append(handoff)
                } else if let session = sessions[key], session.hasSummary {
                    parts.append("Summary of the forum thread \"\(session.title)\" (\(session.url.absoluteString)):\n\(Self.capped(session.summary))")
                }
            case .research(let id):
                guard let run = agentRuns.first(where: { $0.id == id }) else { continue }
                if !run.isFinished {
                    waiting.append(handoff)
                } else if !run.answer.isEmpty {
                    parts.append("Answer from searching the forum for \"\(run.goal)\":\n\(Self.capped(run.answer))")
                }
            case .follow(let title, let url):
                parts.append("The user followed the thread \"\(title)\" (\(url.absoluteString)) and is notified of new replies.")
            }
        }
        agentHandoffs = waiting
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func addHandoff(_ handoff: AgentHandoff) {
        if !agentHandoffs.contains(handoff) { agentHandoffs.append(handoff) }
    }

    private func summaryIsRunning(topicKey: String) -> Bool {
        activities.contains { $0.topicKey == topicKey && $0.type == .summary && !$0.status.isTerminal }
    }

    private func readSummaryAloud(topicKey: String) {
        guard let session = sessions[topicKey], session.hasSummary else { return }
        let id = "summary-\(topicKey)"
        guard !podcast.isReadingAloud(id) else { return }
        podcast.readAloud(id: id, title: session.title, text: PostCitations.stripped(session.summary))
    }

    private static func capped(_ text: String) -> String {
        text.count > handoffCharacterLimit ? String(text.prefix(handoffCharacterLimit)) + "…" : text
    }
}
