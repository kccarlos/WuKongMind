import XCTest
@testable import WukongMind

final class SummaryPresentationTests: XCTestCase {
    private let rowID = UUID(uuidString: "00000149-0000-4000-8000-000000000001")!

    func testNamedTransitionsAndWUKO134Cases() {
        typealias I = SummaryPresentation.Inputs
        let table: [(String, I, Bool, SummaryPresentation.Top, SummaryPresentation.Card, Bool, String)] = [
            // Page states off a topic
            ("loading-empty", I(pageState: .loading), false, .loading, .none, false, "none"),
            ("loading-conv", I(pageState: .loading, hasConversation: true), false, .none, .none, true, "none"),
            ("notForum-empty", I(pageState: .notForum), false, .none, .none, false, "none"),
            ("forumHome-conv", I(pageState: .forumHome, hasConversation: true), false, .none, .none, true, "none"),
            // Topic: top ownership
            ("topic-empty", I(), false, .emptyTopic, .none, false, "none"),
            ("topic-pulling", I(isPulling: true), true, .none, .none, false, "running"),
            ("top-placeholder", I(jobState: .running), false, .running(streaming: false), .none, true, "running"),
            ("top-streaming", I(jobState: .running, hasStreamText: true, hasSavedSummary: true), false, .running(streaming: true), .none, true, "running"),
            ("top-saved", I(hasSavedSummary: true), false, .saved, .none, true, "saved"),
            ("top-failed-fresh", I(jobState: .failed(message: "Offline")), false, .failed(message: "Offline", showsSaved: false), .none, true, "failed"),
            ("top-failed-refresh", I(jobState: .failed(message: "Offline"), hasSavedSummary: true), false, .failed(message: "Offline", showsSaved: true), .none, true, "failed"),
            // WUKO-134 (1): summarize_topic hides cached top summary while pending, streams fresh run at top until card lands, then card owns summary + status
            ("wuko134-pending-cached", I(hasSavedSummary: true, cardRow: .pending, hasConversation: true), false, .none, .none, true, "running"),
            ("wuko134-pending-streaming", I(jobState: .running, hasStreamText: true, hasSavedSummary: true, cardRow: .pending, hasConversation: true), false, .running(streaming: true), .none, true, "running"),
            ("wuko134-card-landed", I(hasSavedSummary: true, cardRow: .card(rowID), hasConversation: true), false, .none, .saved(rowID: rowID), true, "card"),
            ("wuko134-card-retry-running", I(jobState: .running, hasStreamText: true, hasSavedSummary: true, cardRow: .card(rowID), hasConversation: true), false, .none, .running(rowID: rowID), true, "running"),
            ("wuko134-card-retry-failed", I(jobState: .failed(message: "Timeout"), hasSavedSummary: true, cardRow: .card(rowID), hasConversation: true), false, .none, .failed(rowID: rowID, message: "Timeout"), true, "card"),
            ("wuko134-card-with-pull", I(hasSavedSummary: true, cardRow: .card(rowID), isPulling: true, hasConversation: true), true, .none, .saved(rowID: rowID), true, "running"),
            // WUKO-134 (2): New conversation clears top summary/progress/error and keeps saved summary hidden across Read it / follow-ups
            ("wuko134-reset-hides-saved", I(hasSavedSummary: true, isHiddenByNewConversation: true), false, .emptyTopic, .none, false, "hidden"),
            ("wuko134-reset-then-read-aloud", I(hasSavedSummary: true, isHiddenByNewConversation: true, hasConversation: true), false, .none, .none, true, "hidden"),
            ("wuko134-reset-clears-failed", I(jobState: .failed(message: "Offline"), isHiddenByNewConversation: true), false, .emptyTopic, .none, false, "hidden"),
            ("wuko134-reset-clears-running", I(jobState: .running, isHiddenByNewConversation: true), false, .emptyTopic, .none, false, "hidden"),
            ("wuko134-reset-keeps-pull", I(hasSavedSummary: true, isHiddenByNewConversation: true, isPulling: true), true, .none, .none, false, "running")
        ]

        for (label, input, pull, top, card, canReset, word) in table {
            let out = SummaryPresentation.resolve(input)
            XCTAssertEqual(out.showsPullProgress, pull, label)
            XCTAssertEqual(out.top, top, label)
            XCTAssertEqual(out.card, card, label)
            XCTAssertEqual(out.canStartNewConversation, canReset, label)
            XCTAssertEqual(out.digestWord(cardRow: input.cardRow), word, label)
        }
        let stale = SummaryPresentation.resolve(I(hasSavedSummary: true))
        XCTAssertEqual(stale.digestWord(cardRow: .none, isStale: true), "stale")
    }

    func testEveryReachableInputCombinationAndInvariants() {
        let jobs: [(SummaryRunState, Bool)] = [
            (.idle, false), (.running, false), (.running, true), (.failed(message: "Err"), false)
        ]
        let cardAndConv: [(SummaryPresentation.CardRow, Bool)] = [
            (.none, false), (.none, true), (.pending, true), (.card(rowID), true)
        ]

        var reachableCount = 0
        // 1. Off-topic combinations (12)
        for pageState in [PageContext.State.loading, .notForum, .maybe, .forumHome] {
            for (cardRow, hasConv) in [(.none, false), (.none, true), (SummaryPresentation.CardRow.pending, true)] {
                let input = SummaryPresentation.Inputs(cardRow: cardRow, pageState: pageState, hasConversation: hasConv)
                let out = SummaryPresentation.resolve(input)
                XCTAssertFalse(out.showsPullProgress)
                XCTAssertEqual(out.card, .none)
                XCTAssertEqual(out.top, pageState == .loading && !hasConv ? .loading : .none)
                XCTAssertEqual(out.canStartNewConversation, hasConv)
                assertInvariants(input: input, out: out)
                reachableCount += 1
            }
        }

        // 2. Topic combinations (128)
        for (jobState, hasStream) in jobs {
            for hasSaved in [false, true] {
                for (cardRow, hasConv) in cardAndConv {
                    for hidden in [false, true] {
                        for pulling in [false, true] {
                            let input = SummaryPresentation.Inputs(
                                jobState: jobState, hasStreamText: hasStream, hasSavedSummary: hasSaved,
                                cardRow: cardRow, isHiddenByNewConversation: hidden,
                                isPulling: pulling, pageState: .topic, hasConversation: hasConv
                            )
                            let out = SummaryPresentation.resolve(input)
                            assertInvariants(input: input, out: out)
                            reachableCount += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(reachableCount, 140)

        // 3. Unrestricted Cartesian domain (1,440): never shows summary or status twice.
        var total = 0
        for page in [PageContext.State.loading, .notForum, .maybe, .forumHome, .topic] {
            for job in [SummaryRunState.idle, .running, .failed(message: "Err")] {
                for stream in [false, true] {
                    for saved in [false, true] {
                        for card in [SummaryPresentation.CardRow.none, .pending, .card(rowID)] {
                            for hidden in [false, true] {
                                for pull in [false, true] {
                                    for conv in [false, true] {
                                        let out = SummaryPresentation.resolve(.init(
                                            jobState: job, hasStreamText: stream, hasSavedSummary: saved,
                                            cardRow: card, isHiddenByNewConversation: hidden,
                                            isPulling: pull, pageState: page, hasConversation: conv
                                        ))
                                        let topPlaceholder = out.top == .running(streaming: false)
                                        XCTAssertFalse((out.top.showsSummary || topPlaceholder) && out.card != .none)
                                        XCTAssertFalse(out.top.showsStatus && out.card.showsStatus)
                                        total += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(total, 1_440)
    }

    private func assertInvariants(input: SummaryPresentation.Inputs, out: SummaryPresentation) {
        let context = "\(input) -> \(out)"
        let topPlaceholder = out.top == .running(streaming: false)
        // Never shows the summary (or its placeholder) twice.
        XCTAssertFalse((out.top.showsSummary || topPlaceholder) && out.card != .none, context)
        // Never shows summary progress or error in both places.
        XCTAssertFalse(out.top.showsStatus && out.card.showsStatus, context)
        guard input.pageState == .topic else { return }
        // Pull progress is never lost.
        XCTAssertEqual(out.showsPullProgress, input.isPulling, context)
        // Summary progress and error are never lost unless New conversation cleared the top section with no card/pending summary.
        guard !(input.isHiddenByNewConversation && input.cardRow == .none) else { return }
        switch input.jobState {
        case .running:
            let hasProgress = out.top == .running(streaming: input.hasStreamText) || out.card == .running(rowID: rowID)
            XCTAssertTrue(hasProgress, context)
        case .failed(let message):
            let topHasError: Bool = if case .failed(let m, _) = out.top { m == message } else { false }
            let cardHasError = out.card == .failed(rowID: rowID, message: message)
            XCTAssertTrue(topHasError || cardHasError, context)
        case .idle:
            break
        }
    }
}
