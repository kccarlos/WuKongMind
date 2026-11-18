import CoreGraphics
import Foundation

/// Explicit state machine deciding whether the drawer transcript follows the bottom
/// (`design-performance-and-state.md` §2.2, §4.5).
struct TranscriptFollow: Equatable, Sendable {
    static let nearBottomThreshold: CGFloat = 48

    struct Geometry: Equatable, Sendable {
        var nearBottom: Bool
        var contentHeight: Int
        var viewportHeight: Int
        var offsetTenths: Int

        init(nearBottom: Bool, contentHeight: Int, viewportHeight: Int, offsetTenths: Int) {
            self.nearBottom = nearBottom
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
            self.offsetTenths = offsetTenths
        }

        init(contentHeight: CGFloat, viewportHeight: CGFloat, visibleMaxY: CGFloat, offsetY: CGFloat) {
            self.nearBottom = contentHeight - visibleMaxY < TranscriptFollow.nearBottomThreshold
            self.contentHeight = Int(contentHeight.rounded())
            self.viewportHeight = Int(viewportHeight.rounded())
            self.offsetTenths = Int((offsetY * 10).rounded())
        }
    }

    enum Phase: Equatable, Sendable {
        /// At the bottom and following incoming run output.
        case following
        /// Pinning the bottom across the next layout turn after viewport shrink or stream growth.
        case pinning(scrolledUp: Bool = false)
        /// Animated and catch-up settle to `"chatBottom"` in progress.
        case settling(atBottom: Bool = true)
        /// Within 48 pt of the bottom, with streaming follow paused after an upward scroll.
        case pausedNearBottom
        /// Away from the bottom (`chatScrollToBottom` shows when the conversation is non-empty).
        case detached(scrolledUp: Bool)

        var isAtBottom: Bool {
            switch self {
            case .following, .pinning, .settling(true), .pausedNearBottom: true
            case .settling(false), .detached: false
            }
        }

        var isPinning: Bool {
            if case .pinning = self { return true }
            return false
        }

        var isSettling: Bool {
            if case .settling = self { return true }
            return false
        }

        var isScrolledUp: Bool {
            switch self {
            case .pinning(true), .pausedNearBottom, .detached(true): true
            case .following, .pinning(false), .settling, .detached(false): false
            }
        }
    }

    enum Anchor: Equatable, Sendable {
        case top
        case bottom

        var scrollID: String {
            switch self {
            case .top: "chatTop"
            case .bottom: "chatBottom"
            }
        }
    }

    enum FollowUp: Equatable, Sendable {
        case recheckBottom(clearPinning: Bool)
        case syncTopicTop
    }

    enum Event: Equatable, Sendable {
        case dragBegan
        case dragEnded(decelerating: Bool = false)
        case geometryChanged(old: Geometry, new: Geometry, isRunning: Bool)
        case contentGrew(height: Int, isRunning: Bool)
        case runStepChanged
        case runAdded
        case voiceTurnAdded
        case jumpTapped
        case topicChanged(hasRuns: Bool)
        case followUp(FollowUp)
        case settleFinished
        case bottomAnchorChanged(isVisible: Bool)
        case disappeared
    }

    enum Effect: Equatable, Sendable {
        case none
        case scrollNow(Anchor = .bottom, afterTurn: FollowUp? = nil)
        case settleToBottom(interruptMomentum: Bool = false)
    }

    var phase: Phase = .following
    var isUserScrolling = false
    var nearBottom = true
    var contentHeight = 0

    var isAtBottom: Bool { phase.isAtBottom }
    var isSettling: Bool { phase.isSettling }
    var isFollowingBottom: Bool { phase.isAtBottom && !isUserScrolling && !phase.isScrolledUp }

    func transition(_ event: Event) -> (state: TranscriptFollow, effect: Effect) {
        var next = self
        let effect = next.step(event)
        return (next, effect)
    }

    private mutating func step(_ event: Event) -> Effect {
        switch event {
        case .dragBegan:
            isUserScrolling = true
            if case .pinning(let scrolledUp) = phase {
                phase = scrolledUp ? .pausedNearBottom : .following
            } else if case .settling(let atBottom) = phase {
                phase = atBottom ? .following : .detached(scrolledUp: false)
            }
            return .none

        case .dragEnded(let decelerating):
            isUserScrolling = decelerating && !phase.isSettling
            return .none

        case .geometryChanged(let old, let new, let isRunning):
            let isPinning = phase.isPinning
            let movedUp = !phase.isSettling
                && old.contentHeight > 0
                && new.viewportHeight == old.viewportHeight
                && new.contentHeight >= old.contentHeight
                && new.offsetTenths < old.offsetTenths - 3
            var scrolledUp = phase.isScrolledUp
            if movedUp {
                scrolledUp = true
            } else if new.offsetTenths > old.offsetTenths + 3, !isPinning {
                scrolledUp = false
            }
            nearBottom = new.nearBottom
            if new.nearBottom {
                if phase.isSettling {
                    phase = .settling(atBottom: true)
                    return .none
                }
                if !phase.isAtBottom {
                    if new.offsetTenths > old.offsetTenths + 3
                        || new.viewportHeight > old.viewportHeight
                        || new.contentHeight <= new.viewportHeight
                    {
                        phase = .following
                    } else {
                        phase = .detached(scrolledUp: scrolledUp)
                    }
                } else {
                    phase = scrolledUp ? .pausedNearBottom : .following
                }
                return .none
            }
            if phase.isSettling { return .none }
            if phase.isAtBottom {
                let viewportShrank = !isUserScrolling
                    && old.viewportHeight > 0
                    && new.viewportHeight < old.viewportHeight
                    && new.offsetTenths >= old.offsetTenths - 3
                let streamGrew = !isUserScrolling
                    && !scrolledUp
                    && old.contentHeight > 0
                    && isRunning
                    && new.contentHeight > old.contentHeight
                    && new.offsetTenths >= old.offsetTenths - 3
                if viewportShrank || streamGrew {
                    phase = .pinning(scrolledUp: false)
                    return .scrollNow(.bottom, afterTurn: .recheckBottom(clearPinning: true))
                }
                if isPinning {
                    phase = .pinning(scrolledUp: scrolledUp)
                } else {
                    phase = .detached(scrolledUp: scrolledUp)
                }
                return .none
            }
            phase = .detached(scrolledUp: scrolledUp)
            return .none

        case .contentGrew(let height, let isRunning):
            let grew = contentHeight > 0 && height > contentHeight
            contentHeight = height
            guard grew, isRunning, isFollowingBottom else { return .none }
            return .scrollNow(.bottom, afterTurn: .recheckBottom(clearPinning: false))

        case .runStepChanged:
            return isFollowingBottom ? .scrollNow(.bottom) : .none

        case .runAdded:
            phase = .settling()
            return .settleToBottom(interruptMomentum: false)

        case .voiceTurnAdded:
            return (!isUserScrolling && !phase.isScrolledUp) ? .scrollNow(.bottom) : .none

        case .jumpTapped:
            isUserScrolling = false
            phase = .settling()
            return .settleToBottom(interruptMomentum: true)

        case .topicChanged(let hasRuns):
            guard !hasRuns else { return .none }
            isUserScrolling = false
            contentHeight = 0
            phase = .detached(scrolledUp: false)
            return .scrollNow(.top, afterTurn: .syncTopicTop)

        case .followUp(let followUp):
            switch followUp {
            case .recheckBottom(let clearPinning):
                if clearPinning, case .pinning(let scrolledUp) = phase {
                    phase = scrolledUp ? .pausedNearBottom : .following
                }
                return isFollowingBottom ? .scrollNow(.bottom) : .none
            case .syncTopicTop:
                if phase.isSettling {
                    phase = .settling(atBottom: nearBottom)
                    return .none
                }
                guard !phase.isPinning else { return .none }
                if phase.isAtBottom != nearBottom {
                    phase = nearBottom ? (phase.isScrolledUp ? .pausedNearBottom : .following) : .detached(scrolledUp: phase.isScrolledUp)
                }
                return .none
            }

        case .settleFinished:
            guard phase.isSettling else { return .none }
            phase = nearBottom ? .following : .detached(scrolledUp: false)
            return .none

        case .bottomAnchorChanged(let isVisible):
            if phase.isSettling {
                phase = .settling(atBottom: isVisible)
            } else if phase.isPinning {
                if !isVisible {
                    phase = .detached(scrolledUp: phase.isScrolledUp)
                }
            } else {
                phase = isVisible ? (phase.isScrolledUp ? .pausedNearBottom : .following) : .detached(scrolledUp: phase.isScrolledUp)
            }
            return .none

        case .disappeared:
            if case .settling(let atBottom) = phase {
                phase = atBottom ? .following : .detached(scrolledUp: false)
            }
            return .none
        }
    }
}
