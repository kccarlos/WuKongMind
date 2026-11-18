import XCTest
@testable import WukongMind

final class TranscriptFollowTests: XCTestCase {
    typealias F = TranscriptFollow
    typealias G = TranscriptFollow.Geometry

    func testTransitionTableForEveryChatThreadCallbackAndOnChange() {
        let bottom = G(nearBottom: true, contentHeight: 1_000, viewportHeight: 500, offsetTenths: 5_000)
        let nudgedUp = G(nearBottom: true, contentHeight: 1_000, viewportHeight: 500, offsetTenths: 4_940)
        let scrolledAway = G(nearBottom: false, contentHeight: 1_000, viewportHeight: 500, offsetTenths: 3_500)
        let transientLazyDrop = G(nearBottom: true, contentHeight: 600, viewportHeight: 500, offsetTenths: 650)
        let scrolledDownToBottom = G(nearBottom: true, contentHeight: 1_000, viewportHeight: 500, offsetTenths: 4_700)
        let keyboardShrank = G(nearBottom: false, contentHeight: 1_000, viewportHeight: 260, offsetTenths: 5_000)
        let streamGrewOffBottom = G(nearBottom: false, contentHeight: 1_080, viewportHeight: 500, offsetTenths: 5_000)
        let viewportExpanded = G(nearBottom: true, contentHeight: 1_000, viewportHeight: 700, offsetTenths: 3_500)
        let shortContent = G(nearBottom: true, contentHeight: 320, viewportHeight: 500, offsetTenths: 0)

        let table: [(String, F, F.Event, F.Phase, Bool, Bool, F.Effect)] = [
            // VStack.onGeometryChange (`contentGrew`)
            ("content-seed-from-zero", F(), .contentGrew(height: 600, isRunning: true), .following, false, true, .none),
            ("content-grew-following-running", F(contentHeight: 600), .contentGrew(height: 680, isRunning: true),
             .following, false, true, .scrollNow(.bottom, afterTurn: .recheckBottom(clearPinning: false))),
            ("content-grew-idle", F(contentHeight: 600), .contentGrew(height: 680, isRunning: false), .following, false, true, .none),
            ("content-shrank", F(contentHeight: 600), .contentGrew(height: 240, isRunning: true), .following, false, true, .none),
            ("content-grew-while-dragging", F(isUserScrolling: true, contentHeight: 600), .contentGrew(height: 680, isRunning: true),
             .following, true, true, .none),
            ("content-grew-while-paused-near-bottom", F(phase: .pausedNearBottom, contentHeight: 600),
             .contentGrew(height: 680, isRunning: true), .pausedNearBottom, false, true, .none),
            ("content-grew-while-scrolled-up", F(phase: .detached(scrolledUp: true), nearBottom: false, contentHeight: 600),
             .contentGrew(height: 680, isRunning: true), .detached(scrolledUp: true), false, false, .none),

            // ChatScrollTracker.onPhaseChange (`dragBegan` / `dragEnded`)
            ("drag-began-following", F(), .dragBegan, .following, true, true, .none),
            ("drag-began-cancels-settle", F(phase: .settling), .dragBegan, .following, true, true, .none),
            ("drag-began-cancels-pinning", F(phase: .pinning), .dragBegan, .following, true, true, .none),
            ("drag-decelerating-keeps-scrolling", F(phase: .detached(scrolledUp: true), isUserScrolling: true, nearBottom: false),
             .dragEnded(decelerating: true), .detached(scrolledUp: true), true, false, .none),
            ("drag-decelerating-during-settle-ignored", F(phase: .settling), .dragEnded(decelerating: true),
             .settling, false, true, .none),
            ("drag-ended-idle", F(phase: .detached(scrolledUp: true), isUserScrolling: true, nearBottom: false),
             .dragEnded(decelerating: false), .detached(scrolledUp: true), false, false, .none),

            // ChatScrollTracker.onScrollGeometryChange (`geometryChanged`)
            ("geometry-slight-upward-pauses-follow", F(), .geometryChanged(old: bottom, new: nudgedUp, isRunning: true),
             .pausedNearBottom, false, true, .none),
            ("geometry-scroll-up-past-threshold", F(isUserScrolling: true), .geometryChanged(old: bottom, new: scrolledAway, isRunning: true),
             .detached(scrolledUp: true), true, false, .none),
            ("geometry-lazy-height-drop-stays-detached",
             F(phase: .detached(scrolledUp: true), isUserScrolling: true, nearBottom: false),
             .geometryChanged(old: G(nearBottom: false, contentHeight: 1_000, viewportHeight: 500, offsetTenths: 650), new: transientLazyDrop, isRunning: false),
             .detached(scrolledUp: true), true, false, .none),
            ("geometry-scroll-down-into-bottom-resumes",
             F(phase: .detached(scrolledUp: true), isUserScrolling: true, nearBottom: false),
             .geometryChanged(old: scrolledAway, new: scrolledDownToBottom, isRunning: true),
             .following, true, true, .none),
            ("geometry-viewport-expanded-reaches-bottom",
             F(phase: .detached(scrolledUp: true), nearBottom: false),
             .geometryChanged(old: scrolledAway, new: viewportExpanded, isRunning: false),
             .following, false, true, .none),
            ("geometry-content-shrank-within-viewport",
             F(phase: .detached(scrolledUp: true), nearBottom: false),
             .geometryChanged(old: scrolledAway, new: shortContent, isRunning: false),
             .following, false, true, .none),
            ("geometry-keyboard-shrink-pins-bottom", F(), .geometryChanged(old: bottom, new: keyboardShrank, isRunning: false),
             .pinning, false, true, .scrollNow(.bottom, afterTurn: .recheckBottom(clearPinning: true))),
            ("geometry-stream-growth-pins-bottom", F(), .geometryChanged(old: bottom, new: streamGrewOffBottom, isRunning: true),
             .pinning, false, true, .scrollNow(.bottom, afterTurn: .recheckBottom(clearPinning: true))),
            ("geometry-paused-stream-growth-detaches", F(phase: .pausedNearBottom),
             .geometryChanged(
                 old: nudgedUp,
                 new: G(nearBottom: false, contentHeight: 1_080, viewportHeight: 500, offsetTenths: 4_940),
                 isRunning: true
             ),
             .detached(scrolledUp: true), false, false, .none),
            ("geometry-paused-scroll-down-resumes-pinning", F(phase: .pausedNearBottom),
             .geometryChanged(old: nudgedUp, new: streamGrewOffBottom, isRunning: true),
             .pinning, false, true, .scrollNow(.bottom, afterTurn: .recheckBottom(clearPinning: true))),
            ("geometry-idle-growth-detaches-without-pin", F(), .geometryChanged(old: bottom, new: streamGrewOffBottom, isRunning: false),
             .detached(scrolledUp: false), false, false, .none),

            // onChange(of: toolCallsCount) and onChange(of: runState) (`runStepChanged`)
            ("step-changed-following", F(), .runStepChanged, .following, false, true, .scrollNow(.bottom)),
            ("step-changed-scrolled-up", F(phase: .detached(scrolledUp: true), nearBottom: false), .runStepChanged,
             .detached(scrolledUp: true), false, false, .none),
            ("step-changed-paused-near-bottom", F(phase: .pausedNearBottom), .runStepChanged, .pausedNearBottom, false, true, .none),

            // onChange(of: runsCount) (`runAdded`)
            ("run-added-from-scrolled-up", F(phase: .detached(scrolledUp: true), nearBottom: false), .runAdded,
             .settling, false, true, .settleToBottom(interruptMomentum: false)),

            // onChange(of: voiceTurnsCount) (`voiceTurnAdded`)
            ("voice-turn-following", F(), .voiceTurnAdded, .following, false, true, .scrollNow(.bottom)),
            ("voice-turn-scrolled-up-stays-put", F(phase: .detached(scrolledUp: true), nearBottom: false), .voiceTurnAdded,
             .detached(scrolledUp: true), false, false, .none),
            ("voice-turn-after-topic-reset-scrolls", F(phase: .detached(scrolledUp: false), nearBottom: false), .voiceTurnAdded,
             .detached(scrolledUp: false), false, false, .scrollNow(.bottom)),

            // chatScrollToBottom (`jumpTapped`)
            ("jump-tapped-during-momentum", F(phase: .detached(scrolledUp: true), isUserScrolling: true, nearBottom: false),
             .jumpTapped, .settling, false, true, .settleToBottom(interruptMomentum: true)),

            // onChange(of: topicKey) (`topicChanged`)
            ("topic-changed-no-runs", F(phase: .settling, isUserScrolling: true, contentHeight: 900),
             .topicChanged(hasRuns: false), .detached(scrolledUp: false), false, false,
             .scrollNow(.top, afterTurn: .syncTopicTop)),
            ("topic-changed-with-runs-keeps-scroll", F(phase: .detached(scrolledUp: true), nearBottom: false, contentHeight: 900),
             .topicChanged(hasRuns: true), .detached(scrolledUp: true), false, false, .none),

            // Follow-ups, settle completion, iOS 17 anchor fallback, disappear
            ("pin-followup-clears-pinning", F(phase: .pinning), .followUp(.recheckBottom(clearPinning: true)),
             .following, false, true, .scrollNow(.bottom)),
            ("topic-sync-tall-summary", F(phase: .detached(scrolledUp: false), nearBottom: false), .followUp(.syncTopicTop),
             .detached(scrolledUp: false), false, false, .none),
            ("topic-sync-short-summary", F(phase: .detached(scrolledUp: false), nearBottom: true), .followUp(.syncTopicTop),
             .following, false, true, .none),
            ("settle-finished-at-bottom", F(phase: .settling, nearBottom: true), .settleFinished, .following, false, true, .none),
            ("settle-finished-short-of-bottom", F(phase: .settling, nearBottom: false), .settleFinished,
             .detached(scrolledUp: false), false, false, .none),
            ("anchor-disappeared-fallback", F(), .bottomAnchorChanged(isVisible: false),
             .detached(scrolledUp: false), false, false, .none),
            ("disappeared-cancels-settle", F(phase: .settling), .disappeared, .following, false, true, .none)
        ]

        for (label, initial, event, wantPhase, wantUserScrolling, wantAtBottom, wantEffect) in table {
            let (next, effect) = initial.transition(event)
            XCTAssertEqual(next.phase, wantPhase, label)
            XCTAssertEqual(next.isUserScrolling, wantUserScrolling, label)
            XCTAssertEqual(next.isAtBottom, wantAtBottom, label)
            XCTAssertEqual(effect, wantEffect, label)
        }
    }

    func testScrolledUpWhileRunStreamsStaysPutAndNewRunJumpsToBottom() {
        var state = F()
        // Seed initial height, then stream first delta while following.
        var step = state.transition(.contentGrew(height: 600, isRunning: true))
        state = step.state
        XCTAssertEqual(step.effect, .none)

        step = state.transition(.contentGrew(height: 700, isRunning: true))
        state = step.state
        XCTAssertEqual(step.effect, .scrollNow(.bottom, afterTurn: .recheckBottom(clearPinning: false)))

        // User drags up while the run is streaming: first a 4 pt nudge within 48 pt, then past 48 pt.
        let g0 = G(nearBottom: true, contentHeight: 700, viewportHeight: 500, offsetTenths: 2_000)
        let g1 = G(nearBottom: true, contentHeight: 700, viewportHeight: 500, offsetTenths: 1_960)
        let g2 = G(nearBottom: false, contentHeight: 700, viewportHeight: 500, offsetTenths: 800)

        state = state.transition(.dragBegan).state
        state = state.transition(.geometryChanged(old: g0, new: g1, isRunning: true)).state
        XCTAssertEqual(state.phase, .pausedNearBottom)
        state = state.transition(.geometryChanged(old: g1, new: g2, isRunning: true)).state
        state = state.transition(.dragEnded(decelerating: false)).state
        XCTAssertEqual(state.phase, .detached(scrolledUp: true))
        XCTAssertFalse(state.isAtBottom)

        // Run continues streaming (height growth, scroll geometry growth, tool calls, run state): stays put.
        let g3 = G(nearBottom: false, contentHeight: 920, viewportHeight: 500, offsetTenths: 800)
        for event: F.Event in [
            .contentGrew(height: 820, isRunning: true),
            .geometryChanged(old: g2, new: g3, isRunning: true),
            .runStepChanged,
            .contentGrew(height: 920, isRunning: true),
            .voiceTurnAdded
        ] {
            let out = state.transition(event)
            state = out.state
            XCTAssertEqual(out.effect, .none, "Streaming while scrolled up must stay put on \(event)")
            XCTAssertFalse(state.isAtBottom)
        }

        // Sending a new run jumps to the bottom and resumes following once settled.
        let added = state.transition(.runAdded)
        state = added.state
        XCTAssertEqual(added.effect, .settleToBottom(interruptMomentum: false))
        XCTAssertTrue(state.isAtBottom)
        XCTAssertTrue(state.isSettling)

        let gBottom = G(nearBottom: true, contentHeight: 1_100, viewportHeight: 500, offsetTenths: 6_000)
        state = state.transition(.geometryChanged(old: g3, new: gBottom, isRunning: true)).state
        state = state.transition(.settleFinished).state
        XCTAssertEqual(state.phase, .following)
        XCTAssertEqual(
            state.transition(.contentGrew(height: 1_180, isRunning: true)).effect,
            .scrollNow(.bottom, afterTurn: .recheckBottom(clearPinning: false))
        )
    }

    func testJumpTappedDuringMomentumInterruptsDecelerationAndTouchWithoutUpwardScrollKeepsFollowing() {
        // 1. Touch and release at bottom without upward motion stays following.
        var touch = F(contentHeight: 700)
        touch = touch.transition(.dragBegan).state
        touch = touch.transition(.dragEnded(decelerating: false)).state
        XCTAssertEqual(touch.phase, .following)
        XCTAssertEqual(
            touch.transition(.contentGrew(height: 760, isRunning: true)).effect,
            .scrollNow(.bottom, afterTurn: .recheckBottom(clearPinning: false))
        )

        // 2. 1.3.1 B: flick upward -> decelerating -> tap Jump -> decelerating callback does not stop settle.
        var momentum = F(phase: .detached(scrolledUp: true), isUserScrolling: true, nearBottom: false, contentHeight: 1_400)
        momentum = momentum.transition(.dragEnded(decelerating: true)).state
        XCTAssertTrue(momentum.isUserScrolling)

        let tapped = momentum.transition(.jumpTapped)
        momentum = tapped.state
        XCTAssertEqual(tapped.effect, .settleToBottom(interruptMomentum: true))
        XCTAssertFalse(momentum.isUserScrolling)
        XCTAssertTrue(momentum.isSettling)

        momentum = momentum.transition(.dragEnded(decelerating: true)).state
        XCTAssertFalse(momentum.isUserScrolling, "Trailing deceleration phase callback must not re-set isUserScrolling during settle")

        // 3. Geometry threshold: < 48 pt from bottom is nearBottom; >= 48 pt is not.
        let justInside = G(contentHeight: 1_000, viewportHeight: 500, visibleMaxY: 952.1, offsetY: 452.1)
        let atBoundary = G(contentHeight: 1_000, viewportHeight: 500, visibleMaxY: 952.0, offsetY: 452.0)
        XCTAssertTrue(justInside.nearBottom)
        XCTAssertEqual(justInside.offsetTenths, 4_521)
        XCTAssertFalse(atBoundary.nearBottom)
    }
}
