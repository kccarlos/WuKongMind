import Foundation

/// Where the open page's thread summary, progress and error show in the drawer
/// (`design-performance-and-state.md` §2.1, WUKO-134).
struct SummaryPresentation: Equatable {
    /// How the conversation's `summarize_topic` tool rows stand for the open thread.
    enum CardRow: Equatable {
        case none
        /// A `summarize_topic` call is running and no card for this thread has finished yet.
        case pending
        /// The newest finished `summarize_topic` card for the open thread (`rowID`).
        case card(UUID)
    }

    struct Inputs: Equatable {
        var jobState: SummaryRunState = .idle
        var hasStreamText = false
        var hasSavedSummary = false
        var cardRow: CardRow = .none
        var isHiddenByNewConversation = false
        var isPulling = false
        var pageState: PageContext.State = .topic
        var hasConversation = false
    }

    /// What the drawer's top summary section renders below any provider-setup or pull card.
    enum Top: Equatable {
        case none
        case loading
        case emptyTopic
        case running(streaming: Bool)
        case saved
        case failed(message: String, showsSaved: Bool)

        var showsSummary: Bool {
            switch self {
            case .running(true), .saved, .failed(_, true): true
            case .none, .loading, .emptyTopic, .running(false), .failed(_, false): false
            }
        }

        var showsStatus: Bool {
            switch self {
            case .running, .failed: true
            case .none, .loading, .emptyTopic, .saved: false
            }
        }

        var isClearableByNewConversation: Bool { showsSummary || showsStatus }
    }

    /// What the conversation's newest `summarize_topic` card for the open thread owns.
    enum Card: Equatable {
        case none
        case running(rowID: UUID)
        case saved(rowID: UUID)
        case failed(rowID: UUID, message: String)

        var rowID: UUID? {
            switch self {
            case .none: nil
            case .running(let id), .saved(let id), .failed(let id, _): id
            }
        }

        var showsStatus: Bool {
            switch self {
            case .running, .failed: true
            case .none, .saved: false
            }
        }
    }

    let showsPullProgress: Bool
    let top: Top
    let card: Card
    let canStartNewConversation: Bool
    let isHiddenSummary: Bool

    var hasTopContent: Bool { showsPullProgress || top != .none }

    static func resolve(_ inputs: Inputs) -> SummaryPresentation {
        guard inputs.pageState == .topic else {
            let top: Top = inputs.pageState == .loading && !inputs.hasConversation ? .loading : .none
            return SummaryPresentation(
                showsPullProgress: false, top: top, card: .none,
                canStartNewConversation: inputs.hasConversation, isHiddenSummary: false
            )
        }

        if case .card(let rowID) = inputs.cardRow {
            let card: Card = switch inputs.jobState {
            case .running: .running(rowID: rowID)
            case .idle: .saved(rowID: rowID)
            case .failed(let message): .failed(rowID: rowID, message: message)
            }
            return SummaryPresentation(
                showsPullProgress: inputs.isPulling, top: .none, card: card,
                canStartNewConversation: true, isHiddenSummary: false
            )
        }

        let emptyOrNone: Top = !inputs.isPulling && !inputs.hasConversation ? .emptyTopic : .none
        if inputs.isHiddenByNewConversation, inputs.cardRow == .none {
            return SummaryPresentation(
                showsPullProgress: inputs.isPulling, top: emptyOrNone, card: .none,
                canStartNewConversation: inputs.hasConversation,
                isHiddenSummary: inputs.hasSavedSummary || inputs.jobState != .idle
            )
        }

        let isPendingCard = inputs.cardRow == .pending
        let top: Top = switch inputs.jobState {
        case .running:
            .running(streaming: inputs.hasStreamText)
        case .failed(let message):
            .failed(message: message, showsSaved: inputs.hasSavedSummary && !isPendingCard)
        case .idle:
            inputs.hasSavedSummary && !isPendingCard ? .saved : emptyOrNone
        }
        return SummaryPresentation(
            showsPullProgress: inputs.isPulling, top: top, card: .none,
            canStartNewConversation: inputs.hasConversation || top.isClearableByNewConversation,
            isHiddenSummary: false
        )
    }

    func digestWord(cardRow: CardRow, isStale: Bool = false, hasTextSummaryCard: Bool = false) -> String {
        if cardRow == .pending || showsPullProgress { return "running" }
        switch (top, card) {
        case (.running, _), (_, .running): return "running"
        case (_, .saved), (_, .failed): return "card"
        case (.failed, .none): return "failed"
        case (.saved, .none): return isStale ? "stale" : "saved"
        case (.none, .none), (.loading, .none), (.emptyTopic, .none):
            if isHiddenSummary { return "hidden" }
            return hasTextSummaryCard ? "card" : "none"
        }
    }

    @MainActor
    static func cardRow(in runs: [BrowserAgentRun], topicKey: String, app: AppModel) -> CardRow {
        if let id = BrowserAgentRunsView.latestThreadSummaryRowID(in: runs, topicKey: topicKey, app: app) {
            return .card(id)
        }
        return BrowserAgentRunsView.hasRunningThreadSummary(in: runs) ? .pending : .none
    }

    @MainActor
    static func resolve(
        jobState: SummaryRunState,
        hasStreamText: Bool,
        hasSavedSummary: Bool,
        isHiddenByNewConversation: Bool,
        isPulling: Bool,
        pageState: PageContext.State,
        hasConversation: Bool,
        runs: [BrowserAgentRun],
        topicKey: String,
        app: AppModel
    ) -> SummaryPresentation {
        PerfProbe.time("AssistantPanel.summaryPlacement") {
            resolve(Inputs(
                jobState: jobState, hasStreamText: hasStreamText, hasSavedSummary: hasSavedSummary,
                cardRow: cardRow(in: runs, topicKey: topicKey, app: app),
                isHiddenByNewConversation: isHiddenByNewConversation, isPulling: isPulling,
                pageState: pageState, hasConversation: hasConversation
            ))
        }
    }
}
