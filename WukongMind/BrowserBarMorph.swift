import Combine
import SwiftUI
import UIKit

// MARK: - Geometry & Motion Metrics

/// Pure layout and interpolation math for the morphing browser bar (design-browser-bar-tabs-models.md §1).
enum BrowserBarMorphMetrics {
    static let collapseTravel: CGFloat = 64
    static let flickVelocityThreshold: CGFloat = 300
    static let minimizeUpperThreshold: CGFloat = 0.6
    static let minimizeLowerThreshold: CGFloat = 0.4
    static let settleMidpoint: CGFloat = 0.5
    static let pageEndTolerance: CGFloat = 1.0

    static let springResponse: Double = 0.24
    static let springDamping: Double = 1.0
    static let springSettleDurationMs: Int = 250
    static let reduceMotionCrossFadeDuration: Double = 0.2
    static let reduceMotionDurationMs: Int = 200

    static let maxBarWidth: CGFloat = 520
    static let horizontalMargin: CGFloat = 12
    static let minCollapsedWidth: CGFloat = 120
    static let maxCollapsedWidth: CGFloat = 240
    static let splitCollapsedWidth: CGFloat = 200
    static let portraitExpandedHeight: CGFloat = 56
    static let landscapeExpandedHeight: CGFloat = 48
    static let splitExpandedHeight: CGFloat = 52
    static let splitExpandedTopOffset: CGFloat = 6
    static let splitCollapsedTopOffset: CGFloat = 2
    static let baseCollapsedHeight: CGFloat = 34
    static let minimumBottomClearance: CGFloat = 8
    static let minHitTargetHeight: CGFloat = 44

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, t))
        return a + (b - a) * clamped
    }

    static func expandedHeight(isSplit: Bool = false, isLandscape: Bool) -> CGFloat {
        if isSplit { return splitExpandedHeight }
        return isLandscape ? landscapeExpandedHeight : portraitExpandedHeight
    }

    /// Collapsed pill height: 34 pt at default Dynamic Type, growing with `.footnote` up to XXXL.
    static func collapsedHeight(collapsedFontSize: CGFloat = 13) -> CGFloat {
        baseCollapsedHeight + max(0, collapsedFontSize - 13) * 1.4
    }

    static func expandedWidth(containerWidth: CGFloat, isSplit: Bool = false) -> CGFloat {
        if isSplit {
            guard containerWidth > 0 else { return 1170 }
            return max(splitCollapsedWidth, containerWidth - 2 * horizontalMargin)
        }
        guard containerWidth > 0 else { return 366 }
        return min(maxBarWidth, max(minCollapsedWidth, containerWidth - 2 * horizontalMargin))
    }

    /// Fits the leading lock/ring, domain text, and optional trailing scripts seal inside 120...240 pt on iPhone,
    /// or 200 pt on the iPad split page column (`design-browser-bar-tabs-models.md` §1).
    static func collapsedWidth(
        domainWidth: CGFloat,
        isAgentWorking: Bool,
        scriptCount: Int,
        isSplit: Bool = false
    ) -> CGFloat {
        if isSplit {
            return splitCollapsedWidth
        }
        let leadingWidth: CGFloat = isAgentWorking ? 16 : 13
        let leadingGap: CGFloat = 6
        let sealWidth: CGFloat
        if isAgentWorking, scriptCount > 0 {
            let digits = CGFloat(String(scriptCount).count)
            sealWidth = 6 + max(18, 10 + digits * 7)
        } else {
            sealWidth = 0
        }
        // Outer capsule padding (3 + 3) + inner address padding (12 + 12) + comfortable breathing room.
        let chromePadding: CGFloat = 44
        let raw = ceil(leadingWidth + leadingGap + domainWidth + sealWidth + chromePadding)
        return min(maxCollapsedWidth, max(minCollapsedWidth, raw))
    }

    /// Distance from the bottom screen edge to the bar's bottom edge (`safeArea - 4` -> `safeArea - 14`, min 8 pt).
    static func bottomEdgeFromScreen(safeAreaBottom: CGFloat, progress: CGFloat) -> CGFloat {
        let expanded = max(minimumBottomClearance, safeAreaBottom - 4)
        let collapsed = max(minimumBottomClearance, safeAreaBottom - 14)
        return lerp(expanded, collapsed, progress)
    }

    /// Expanded web-view bottom inset (`56 + 30 = 86 pt` on a 34 pt portrait bottom safe area).
    static func expandedWebViewBottomInset(safeAreaBottom: CGFloat, isLandscape: Bool) -> CGFloat {
        let height = expandedHeight(isLandscape: isLandscape)
        let bottomEdge = max(minimumBottomClearance, safeAreaBottom - 4)
        return height + bottomEdge
    }

    /// Top bar distance below the top safe area (`+4` -> `+0` on iPhone, `+6` -> `+2` on iPad split).
    static func topEdgeFromSafeArea(progress: CGFloat, isSplit: Bool = false) -> CGFloat {
        isSplit
            ? lerp(splitExpandedTopOffset, splitCollapsedTopOffset, progress)
            : lerp(4, 0, progress)
    }

    static func expandedWebViewTopInset(isSplit: Bool = false, isLandscape: Bool = false) -> CGFloat {
        if isSplit {
            return splitExpandedHeight + splitExpandedTopOffset
        }
        return expandedHeight(isLandscape: isLandscape) + 4
    }

    /// Side buttons fade over the first half of the gesture (`max(0, 1 - 2p)`).
    static func sideButtonOpacity(progress: CGFloat) -> CGFloat {
        max(0, 1 - 2 * min(1, max(0, progress)))
    }

    /// Side buttons scale from `1.0` (`p = 0`) to `0.7` (`p = 0.5`).
    static func sideButtonScale(progress: CGFloat) -> CGFloat {
        let halfProgress = min(0.5, max(0, progress))
        return 1 - 0.6 * halfProgress
    }

    /// Side button layout slot narrows from `44 pt` (`p = 0`) to `0 pt` (`p = 0.5`) so removing at `0.5` never snaps.
    static func sideButtonSlotWidth(progress: CGFloat) -> CGFloat {
        DCTheme.controlHeight * sideButtonOpacity(progress: progress)
    }

    /// Inner address field fill fades out to `0` by `p = 0.5`.
    static func addressFieldFillOpacity(progress: CGFloat, isDark: Bool) -> CGFloat {
        let base: CGFloat = isDark ? 0.08 : 0.06
        return base * sideButtonOpacity(progress: progress)
    }

    /// Closed-form critically damped spring position (`response = 0.24`, `dampingFraction = 1.0`).
    static func criticallyDampedSpringValue(
        from start: CGFloat,
        to target: CGFloat,
        elapsed: TimeInterval,
        response: Double = springResponse
    ) -> CGFloat {
        guard elapsed > 0, response > 0 else { return start }
        if elapsed >= response * 1.5 { return target }
        let omega = (2 * Double.pi) / response
        let decay = (1 + omega * elapsed) * exp(-omega * elapsed)
        return target + (start - target) * CGFloat(decay)
    }
}

// MARK: - Deterministic Morph State Machine

/// Scroll snapshot fed into `BrowserBarMorphState` on each scroll/gesture event.
struct BrowserScrollSample: Equatable {
    /// Content offset normalized so `0` is the top of the document (`contentOffset.y + adjustedContentInset.top`).
    var offsetY: CGFloat
    var contentHeight: CGFloat
    /// Visible height below the top inset (`bounds.height - adjustedContentInset.top`).
    var viewportHeight: CGFloat
    var bottomInset: CGFloat
    var boundsHeight: CGFloat? = nil
    var isTracking: Bool = false
    var isDecelerating: Bool = false
    var isZooming: Bool = false
    var zoomScale: CGFloat = 1.0

    var isShortPage: Bool {
        // WKWebView floors `contentSize.height` at `bounds.height` even on 1-line documents
        // (including when `adjustedContentInset.top > 0` reduces `viewportHeight` below `bounds.height`);
        // 1 pt tolerance absorbs fractional Retina pixel rounding (`812.33` vs `812.0`).
        let effectiveFloor = max(viewportHeight, boundsHeight ?? viewportHeight)
        return viewportHeight <= 0 || contentHeight <= effectiveFloor + 1
    }

    var maxOffsetY: CGFloat {
        guard !isShortPage else { return 0 }
        return max(0, contentHeight - viewportHeight + bottomInset)
    }

    var clampedOffsetY: CGFloat {
        min(max(0, offsetY), maxOffsetY)
    }

    var isAtPageEnd: Bool {
        !isShortPage && maxOffsetY > 0 && offsetY >= maxOffsetY - BrowserBarMorphMetrics.pageEndTolerance
    }
}

/// How `progress` transitioned on an event, so the coordinator can pick no-animation vs spring vs cross-fade.
enum BrowserBarTransitionKind: Equatable {
    case immediate
    case spring(target: CGFloat)
}

/// Dedicated small `ObservableObject` holding live scroll-morph progress (`0`…`1`) so
/// `PhoneMorphingBarHost` updates per frame without invalidating `ForumBrowserModel`'s
/// wider view tree (`ContentView`, `NavigationStack`, `BrowserContent`, `DockLayer`).
@MainActor
final class BrowserBarProgressModel: ObservableObject {
    @Published var progress: CGFloat = 0
}

/// Pure, unit-testable state machine for `p`, settle/flick/page-end rules, hysteresis, freeze guards, and rest inset.
struct BrowserBarMorphState: Equatable {
    private(set) var progress: CGFloat = 0
    private(set) var isChromeMinimized = false
    /// Same 0.6 / 0.4 hysteresis as `isChromeMinimized`; drives the 0.2 s end-state cross-fade under Reduce Motion.
    private(set) var reduceMotionCollapsed = false

    private(set) var isTracking = false
    private(set) var isDecelerating = false
    private(set) var isZooming = false
    var isLoading = false
    private(set) var isKeyboardFrozen = false
    private(set) var isLockedExpanded = false
    var isApplyingInset = false

    /// Whether a settle or discrete-trigger spring is currently in flight.
    private(set) var isSpringAnimating = false
    private(set) var springStartProgress: CGFloat = 0
    private(set) var springTargetProgress: CGFloat = 0

    /// Sampled once at finger-up (`willEndDragging`), in points/second (`> 0` scrolling down, `< 0` scrolling up).
    private(set) var sampledFlickVelocity: CGFloat = 0
    /// Queued when Agent finishes or asks a confirmation (or discrete trigger fires) while a finger is on the page.
    private(set) var pendingExpandWhenFingerUp = false
    /// Prevents leftover coasting/rubber-band frames from fighting a page-end or finger-up expand spring.
    private(set) var suppressCoastingUntilNextDrag = false

    private var hasScrollBaseline = false
    private var lastClampedOffsetY: CGFloat = 0
    private var lastZoomScale: CGFloat = 1.0

    var expandedBottomInset: CGFloat = 86 {
        didSet {
            guard expandedBottomInset != oldValue else { return }
            updateRestInsetIfNeeded()
        }
    }

    /// Web-view `contentInset.bottom` applied ONLY when the bar comes to rest at `p == 0` (`86`) or `p == 1` (`0`).
    private(set) var appliedBottomInset: CGFloat = 86
    /// Monotonic counts of hysteresis state transitions (`false -> true` and `true -> false`) for flap detection.
    private(set) var minimizeCount = 0
    private(set) var expandCount = 0

    var isAtRest: Bool {
        !isTracking && !isDecelerating && !isSpringAnimating && (progress == 0 || progress == 1)
    }

    /// Visual progress to display: under Reduce Motion there is no intermediate morph (`0` or `1` only).
    func displayProgress(reduceMotion: Bool) -> CGFloat {
        reduceMotion ? (reduceMotionCollapsed ? 1 : 0) : progress
    }

    mutating func resetBaseline(to sample: BrowserScrollSample? = nil) {
        if let sample {
            hasScrollBaseline = true
            lastClampedOffsetY = sample.clampedOffsetY
            lastZoomScale = sample.zoomScale
        } else {
            hasScrollBaseline = false
        }
    }

    // MARK: Scroll & Gesture Events

    mutating func willBeginDragging(currentSampledProgress: CGFloat? = nil, sample: BrowserScrollSample? = nil) {
        if isSpringAnimating, let interrupted = currentSampledProgress {
            isSpringAnimating = false
            applyProgress(min(1, max(0, interrupted)))
        } else {
            isSpringAnimating = false
        }
        isTracking = true
        suppressCoastingUntilNextDrag = false
        sampledFlickVelocity = 0
        if let sample {
            hasScrollBaseline = true
            lastClampedOffsetY = sample.clampedOffsetY
            lastZoomScale = sample.zoomScale
        }
    }

    @discardableResult
    mutating func didScroll(_ sample: BrowserScrollSample) -> BrowserBarTransitionKind? {
        isTracking = sample.isTracking
        isDecelerating = sample.isDecelerating
        if sample.isZooming { isZooming = true }

        let clamped = sample.clampedOffsetY
        let zoomChanged = abs(sample.zoomScale - lastZoomScale) > 0.0001
        lastZoomScale = sample.zoomScale

        if !hasScrollBaseline {
            hasScrollBaseline = true
            lastClampedOffsetY = clamped
            if sample.isShortPage, progress > 0, !sample.isTracking {
                return startSpring(to: 0)
            }
            return nil
        }

        let deltaY = clamped - lastClampedOffsetY
        lastClampedOffsetY = clamped

        // Ignore inset-switch adjustments, zoom changes, locked states, loading, and keyboard freeze.
        if isApplyingInset || zoomChanged || isZooming || sample.isZooming {
            return nil
        }
        if isLockedExpanded {
            return progress > 0 ? setImmediate(0) : nil
        }
        if sample.isShortPage {
            if progress > 0, !sample.isTracking {
                return startSpring(to: 0)
            }
            return progress > 0 ? setImmediate(0) : nil
        }
        if isLoading || isKeyboardFrozen {
            return nil
        }

        // Only the person's own scrolling (`isTracking` or `isDecelerating`) drives `p`.
        guard sample.isTracking || sample.isDecelerating else {
            return nil
        }
        guard !suppressCoastingUntilNextDrag else {
            return nil
        }

        // Coasting reaching the page end replaces settle and springs straight to `p = 0`.
        if !sample.isTracking, sample.isDecelerating, sample.isAtPageEnd {
            suppressCoastingUntilNextDrag = true
            sampledFlickVelocity = 0
            if progress > 0 {
                return startSpring(to: 0)
            }
            updateRestInsetIfNeeded()
            return nil
        }

        guard deltaY != 0 else { return nil }
        let next = min(1, max(0, progress + deltaY / BrowserBarMorphMetrics.collapseTravel))
        guard next != progress else { return nil }
        isSpringAnimating = false
        applyProgress(next)
        return .immediate
    }

    /// Samples flick velocity once at finger-up, in points/second (`> 0` scrolling down, `< 0` scrolling up).
    mutating func willEndDragging(velocityPtPerSec: CGFloat) {
        if isZooming || isLoading || isKeyboardFrozen || isLockedExpanded {
            sampledFlickVelocity = 0
        } else {
            sampledFlickVelocity = velocityPtPerSec
        }
    }

    @discardableResult
    mutating func didEndDragging(willDecelerate: Bool, sample: BrowserScrollSample) -> BrowserBarTransitionKind? {
        isTracking = false
        isDecelerating = willDecelerate
        hasScrollBaseline = true
        lastClampedOffsetY = sample.clampedOffsetY

        // 1. Deferred discrete trigger (e.g. Agent finished or asked while finger was down).
        if pendingExpandWhenFingerUp {
            pendingExpandWhenFingerUp = false
            suppressCoastingUntilNextDrag = willDecelerate
            sampledFlickVelocity = 0
            return expandOrRest()
        }

        // 2. Finger-up at page end replaces settle and springs to `p = 0` (unless flicking back up, which also goes to 0).
        if !isKeyboardFrozen, !isLoading, sample.isAtPageEnd {
            suppressCoastingUntilNextDrag = willDecelerate
            sampledFlickVelocity = 0
            return expandOrRest()
        }

        // 3. If coasting continues, `didScroll` drives `p` frame by frame until `didEndDecelerating` (or page end).
        guard !willDecelerate else {
            return nil
        }

        return settleAfterScrollStopped(atPageEnd: false)
    }

    @discardableResult
    mutating func didEndDecelerating(sample: BrowserScrollSample) -> BrowserBarTransitionKind? {
        isTracking = false
        isDecelerating = false
        hasScrollBaseline = true
        lastClampedOffsetY = sample.clampedOffsetY

        if suppressCoastingUntilNextDrag {
            suppressCoastingUntilNextDrag = false
            updateRestInsetIfNeeded()
            return nil
        }

        return settleAfterScrollStopped(atPageEnd: !isKeyboardFrozen && !isLoading && sample.isAtPageEnd)
    }

    mutating func willBeginZooming() {
        isZooming = true
        sampledFlickVelocity = 0
    }

    mutating func didEndZooming(scale: CGFloat, sample: BrowserScrollSample? = nil) {
        isZooming = false
        lastZoomScale = scale
        if let sample {
            hasScrollBaseline = true
            lastClampedOffsetY = sample.clampedOffsetY
        }
    }

    // MARK: Discrete Triggers & Locks

    /// Discrete expand trigger (pill tap, page load, address edit, Agent finished or confirmation asked).
    /// Springs to `p = 0` when no finger is on the page; if a finger is down and `deferIfTracking` is true,
    /// waits until finger-up.
    @discardableResult
    mutating func requestExpand(deferIfTracking: Bool = true) -> BrowserBarTransitionKind? {
        if isTracking, deferIfTracking {
            pendingExpandWhenFingerUp = true
            return nil
        }
        pendingExpandWhenFingerUp = false
        if isDecelerating {
            suppressCoastingUntilNextDrag = true
        }
        sampledFlickVelocity = 0
        return expandOrRest()
    }

    /// Freezes `p` while a page form field's keyboard is shown, restoring the exact same state when it hides.
    mutating func setKeyboardFrozen(_ frozen: Bool, currentSample: BrowserScrollSample? = nil) {
        guard isKeyboardFrozen != frozen else { return }
        isKeyboardFrozen = frozen
        sampledFlickVelocity = 0
        if let currentSample {
            hasScrollBaseline = true
            lastClampedOffsetY = currentSample.clampedOffsetY
        }
    }

    /// Locks the bar expanded (`p = 0`) on Home, during a voice session, in iPad split, or above XXXL Dynamic Type.
    @discardableResult
    mutating func setLockedExpanded(_ locked: Bool) -> BrowserBarTransitionKind? {
        guard isLockedExpanded != locked else { return nil }
        isLockedExpanded = locked
        if locked {
            pendingExpandWhenFingerUp = false
            sampledFlickVelocity = 0
            isSpringAnimating = false
            return setImmediate(0)
        }
        updateRestInsetIfNeeded()
        return nil
    }

    /// Marks the in-flight settle/trigger spring completed so the rest inset (`86` or `0`) can switch.
    mutating func completeSpringAnimation() {
        guard isSpringAnimating else {
            updateRestInsetIfNeeded()
            return
        }
        isSpringAnimating = false
        applyProgress(springTargetProgress)
        updateRestInsetIfNeeded()
    }

    // MARK: Private Helpers

    @discardableResult
    private mutating func settleAfterScrollStopped(atPageEnd: Bool) -> BrowserBarTransitionKind? {
        let flick = sampledFlickVelocity
        sampledFlickVelocity = 0

        if atPageEnd {
            return expandOrRest()
        }

        if isKeyboardFrozen || isLockedExpanded {
            updateRestInsetIfNeeded()
            return nil
        }

        guard progress > 0, progress < 1 else {
            updateRestInsetIfNeeded()
            return nil
        }

        let target: CGFloat
        if !isLoading, abs(flick) > BrowserBarMorphMetrics.flickVelocityThreshold {
            target = flick > 0 ? 1 : 0
        } else {
            // Tie at 0.5 expands (`progress <= 0.5` -> `0`).
            target = progress > BrowserBarMorphMetrics.settleMidpoint ? 1 : 0
        }
        return startSpring(to: target)
    }

    @discardableResult
    private mutating func expandOrRest() -> BrowserBarTransitionKind? {
        if progress > 0 {
            return startSpring(to: 0)
        }
        isSpringAnimating = false
        applyProgress(0)
        updateRestInsetIfNeeded()
        return nil
    }

    @discardableResult
    private mutating func startSpring(to target: CGFloat) -> BrowserBarTransitionKind {
        let clampedTarget = min(1, max(0, target))
        springStartProgress = progress
        springTargetProgress = clampedTarget
        isSpringAnimating = true
        applyProgress(clampedTarget)
        return .spring(target: clampedTarget)
    }

    @discardableResult
    private mutating func setImmediate(_ value: CGFloat) -> BrowserBarTransitionKind {
        isSpringAnimating = false
        applyProgress(value)
        updateRestInsetIfNeeded()
        return .immediate
    }

    private mutating func applyProgress(_ next: CGFloat) {
        let clamped = min(1, max(0, next))
        progress = clamped
        if clamped > BrowserBarMorphMetrics.minimizeUpperThreshold {
            if !isChromeMinimized {
                isChromeMinimized = true
                minimizeCount += 1
            }
            reduceMotionCollapsed = true
        } else if clamped < BrowserBarMorphMetrics.minimizeLowerThreshold {
            if isChromeMinimized {
                isChromeMinimized = false
                expandCount += 1
            }
            reduceMotionCollapsed = false
        }
    }

    private mutating func updateRestInsetIfNeeded() {
        guard !isTracking, !isDecelerating, !isSpringAnimating else { return }
        if progress <= 0.0001 {
            progress = 0
            appliedBottomInset = expandedBottomInset
        } else if progress >= 0.9999 {
            progress = 1
            appliedBottomInset = 0
        }
    }
}

// MARK: - WKWebView ScrollView Coordinator

/// Bridges `WKWebView.scrollView` delegate events to `BrowserBarMorphState`, runs the settle spring,
/// and applies `contentInset` switches strictly at rest without feeding UIKit's offset clamp back into `p`.
@MainActor
final class BrowserBarScrollCoordinator: NSObject, UIScrollViewDelegate {
    private weak var scrollView: UIScrollView?
    private(set) var state = BrowserBarMorphState()

    var onChange: ((BrowserBarMorphState, BrowserBarTransitionKind?) -> Void)?
    var onUserScrollBegan: (() -> Void)?

    /// Whether the floating morphing bar owns `scrollView.contentInset`.
    private(set) var managesWebViewInsets = false
    private(set) var isSplitLayout = false
    private(set) var barPosition: BrowserBarPosition = .bottom
    private(set) var safeAreaBottom: CGFloat = 34
    private(set) var isLandscape = false
    var reduceMotion = false

    private var springStartDate: Date?
    private var springCompletionTask: Task<Void, Never>?
    private var transitionGeneration = 0

    func attach(to scrollView: UIScrollView) {
        self.scrollView = scrollView
        scrollView.delegate = self
        if managesWebViewInsets {
            let targetBehavior: UIScrollView.ContentInsetAdjustmentBehavior = isSplitLayout ? .automatic : .never
            if scrollView.contentInsetAdjustmentBehavior != targetBehavior {
                applyScrollViewMutation {
                    scrollView.contentInsetAdjustmentBehavior = targetBehavior
                }
            }
            syncScrollViewInsets()
        }
    }

    func updateLayoutConfiguration(
        managesInsets: Bool,
        isSplit: Bool = false,
        position: BrowserBarPosition,
        safeAreaBottom: CGFloat,
        isLandscape: Bool,
        isLockedExpanded: Bool,
        reduceMotion: Bool
    ) {
        let changedMode = managesWebViewInsets != managesInsets
            || isSplitLayout != isSplit
            || barPosition != position
        managesWebViewInsets = managesInsets
        isSplitLayout = isSplit
        barPosition = position
        self.safeAreaBottom = safeAreaBottom
        self.isLandscape = isLandscape
        self.reduceMotion = reduceMotion

        if let scrollView {
            // In iPad split layout the morphing bar floats at `.top` while UIKit's
            // `.automatic` safe-area adjustment handles the home indicator at `.bottom`,
            // keeping `scrollView.contentInset.bottom == 0`.
            let targetBehavior: UIScrollView.ContentInsetAdjustmentBehavior = (managesInsets && !isSplit) ? .never : .automatic
            if scrollView.contentInsetAdjustmentBehavior != targetBehavior {
                applyScrollViewMutation {
                    scrollView.contentInsetAdjustmentBehavior = targetBehavior
                }
            }
        }

        let newExpandedBottom = BrowserBarMorphMetrics.expandedWebViewBottomInset(
            safeAreaBottom: safeAreaBottom,
            isLandscape: isLandscape
        )
        let prevBottomInset = state.appliedBottomInset
        state.expandedBottomInset = newExpandedBottom

        let lockTransition = state.setLockedExpanded(isLockedExpanded)
        if let lockTransition {
            handleTransition(lockTransition)
        } else if changedMode || state.appliedBottomInset != prevBottomInset {
            syncScrollViewInsets()
            onChange?(state, nil)
        } else {
            syncScrollViewInsets()
        }
    }

    func setLoading(_ loading: Bool) {
        guard state.isLoading != loading else { return }
        state.isLoading = loading
        if !loading, let scrollView {
            state.resetBaseline(to: makeSample(from: scrollView))
        }
    }

    func setPageKeyboardFrozen(_ frozen: Bool) {
        let sample = scrollView.map(makeSample(from:))
        let wasCollapsed = state.reduceMotionCollapsed
        state.setKeyboardFrozen(frozen, currentSample: sample)
        if state.reduceMotionCollapsed != wasCollapsed {
            onChange?(state, nil)
        }
    }

    func requestExpand(deferIfTracking: Bool = true) {
        let transition = state.requestExpand(deferIfTracking: deferIfTracking)
        handleTransition(transition)
    }

    // MARK: UIScrollViewDelegate (never implement `viewForZooming(in:)` on WKWebView!)

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onUserScrollBegan?()
        let interruptedProgress: CGFloat?
        if state.isSpringAnimating, let start = springStartDate {
            let elapsed = Date().timeIntervalSince(start)
            interruptedProgress = BrowserBarMorphMetrics.criticallyDampedSpringValue(
                from: state.springStartProgress,
                to: state.springTargetProgress,
                elapsed: elapsed
            )
        } else {
            interruptedProgress = nil
        }
        cancelPendingSpringCompletion()
        state.willBeginDragging(
            currentSampledProgress: interruptedProgress,
            sample: makeSample(from: scrollView)
        )
        if interruptedProgress != nil {
            onChange?(state, .immediate)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !state.isApplyingInset else { return }
        let prevProgress = state.progress
        let prevMinimized = state.isChromeMinimized
        let prevReduced = state.reduceMotionCollapsed
        let transition = state.didScroll(makeSample(from: scrollView))
        if let transition {
            handleTransition(transition)
            return
        }
        #if DEBUG
        let publishDebug = ProcessInfo.processInfo.arguments.contains("-dc-browse-debug")
        #else
        let publishDebug = false
        #endif
        if state.progress != prevProgress
            || state.isChromeMinimized != prevMinimized
            || state.reduceMotionCollapsed != prevReduced
            || publishDebug
        {
            onChange?(state, nil)
        }
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        // UIKit reports `velocity` in points/millisecond (`1.0 == 1000 pt/s`).
        state.willEndDragging(velocityPtPerSec: velocity.y * 1000)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        let transition = state.didEndDragging(
            willDecelerate: decelerate,
            sample: makeSample(from: scrollView)
        )
        handleTransition(transition)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let transition = state.didEndDecelerating(sample: makeSample(from: scrollView))
        handleTransition(transition)
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        state.willBeginZooming()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        state.didEndZooming(scale: scale, sample: makeSample(from: scrollView))
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        requestExpand(deferIfTracking: false)
        return true
    }

    // MARK: Private

    private func makeSample(from scrollView: UIScrollView) -> BrowserScrollSample {
        let topInset = scrollView.adjustedContentInset.top
        return BrowserScrollSample(
            offsetY: scrollView.contentOffset.y + topInset,
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height - topInset,
            bottomInset: scrollView.adjustedContentInset.bottom,
            boundsHeight: scrollView.bounds.height,
            isTracking: scrollView.isTracking,
            isDecelerating: scrollView.isDecelerating,
            isZooming: scrollView.isZooming || scrollView.isZoomBouncing,
            zoomScale: scrollView.zoomScale
        )
    }

    private func handleTransition(_ transition: BrowserBarTransitionKind?) {
        switch transition {
        case .spring:
            transitionGeneration &+= 1
            let generation = transitionGeneration
            springStartDate = Date()
            springCompletionTask?.cancel()
            let durationMs = reduceMotion
                ? BrowserBarMorphMetrics.reduceMotionDurationMs
                : BrowserBarMorphMetrics.springSettleDurationMs
            onChange?(state, transition)
            springCompletionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(durationMs))
                guard !Task.isCancelled, let self, self.transitionGeneration == generation else { return }
                self.springStartDate = nil
                self.state.completeSpringAnimation()
                self.syncScrollViewInsets()
                self.onChange?(self.state, nil)
            }
        case .immediate:
            cancelPendingSpringCompletion()
            syncScrollViewInsets()
            onChange?(state, .immediate)
        case nil:
            syncScrollViewInsets()
            onChange?(state, nil)
        }
    }

    private func cancelPendingSpringCompletion() {
        transitionGeneration &+= 1
        springStartDate = nil
        springCompletionTask?.cancel()
        springCompletionTask = nil
    }

    private func syncScrollViewInsets() {
        guard let scrollView else { return }
        let desiredTop: CGFloat
        let desiredBottom: CGFloat
        if !managesWebViewInsets {
            desiredTop = 0
            desiredBottom = 0
        } else if isSplitLayout {
            desiredTop = BrowserBarMorphMetrics.expandedWebViewTopInset(isSplit: true, isLandscape: true)
            desiredBottom = 0
        } else if barPosition == .top {
            desiredTop = BrowserBarMorphMetrics.expandedWebViewTopInset(isLandscape: isLandscape)
            desiredBottom = max(0, safeAreaBottom)
        } else {
            desiredTop = 0
            desiredBottom = state.appliedBottomInset
        }

        let current = scrollView.contentInset
        guard abs(current.top - desiredTop) > 0.5 || abs(current.bottom - desiredBottom) > 0.5 else {
            return
        }
        applyScrollViewMutation {
            let oldTop = scrollView.contentInset.top
            let wasAtTop = !scrollView.isTracking
                && !scrollView.isDecelerating
                && scrollView.contentOffset.y <= -oldTop + 1
            let nextInsets = UIEdgeInsets(top: desiredTop, left: 0, bottom: desiredBottom, right: 0)
            scrollView.contentInset = nextInsets
            scrollView.verticalScrollIndicatorInsets = nextInsets
            if abs(oldTop - desiredTop) > 0.5, wasAtTop {
                scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: -desiredTop)
            }
        }
    }

    private func applyScrollViewMutation(_ body: () -> Void) {
        guard let scrollView else { return }
        state.isApplyingInset = true
        body()
        state.isApplyingInset = false
        state.resetBaseline(to: makeSample(from: scrollView))
    }
}
