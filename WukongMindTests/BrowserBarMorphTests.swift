import SwiftUI
import UIKit
import XCTest
@testable import WukongMind

private final class StubAgentAIService: AIService, @unchecked Sendable {
    override func completeToolTurn(
        system: String,
        messages: [AgentModelTurn],
        tools: [AgentToolDefinition],
        configuration: ProviderConfiguration,
        provider: AIProvider,
        maxTokens: Int,
        recorder: AgentWireRecorder?
    ) async throws -> AgentModelTurnResponse {
        AgentModelTurnResponse(text: "Summary finished.")
    }
}

private final class MockTrackingScrollView: UIScrollView {
    var mockIsTracking = false
    var mockIsDecelerating = false

    override var isTracking: Bool { mockIsTracking }
    override var isDecelerating: Bool { mockIsDecelerating }
}

@MainActor
final class BrowserBarMorphTests: XCTestCase {
    private func sample(
        offsetY: CGFloat,
        contentHeight: CGFloat = 2400,
        viewportHeight: CGFloat = 785,
        bottomInset: CGFloat = 86,
        isTracking: Bool = false,
        isDecelerating: Bool = false,
        isZooming: Bool = false,
        zoomScale: CGFloat = 1.0
    ) -> BrowserScrollSample {
        BrowserScrollSample(
            offsetY: offsetY,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            bottomInset: bottomInset,
            isTracking: isTracking,
            isDecelerating: isDecelerating,
            isZooming: isZooming,
            zoomScale: zoomScale
        )
    }

    func testProgressIntegrationIsSignedClampedPerStepWithNoBuildUp() {
        var state = BrowserBarMorphState()
        state.willBeginDragging(sample: sample(offsetY: 0, isTracking: true))

        // +16 pt -> 0.25; +32 pt -> 0.75.
        _ = state.didScroll(sample(offsetY: 16, isTracking: true))
        XCTAssertEqual(state.progress, 0.25, accuracy: 1e-6)
        _ = state.didScroll(sample(offsetY: 48, isTracking: true))
        XCTAssertEqual(state.progress, 0.75, accuracy: 1e-6)

        // Past-end drag (+400 pt) clamps at 1.0 with zero build-up: reversing 10 pt moves straight away.
        _ = state.didScroll(sample(offsetY: 448, isTracking: true))
        XCTAssertEqual(state.progress, 1.0, accuracy: 1e-6)
        _ = state.didScroll(sample(offsetY: 438, isTracking: true))
        XCTAssertEqual(state.progress, 1.0 - 10.0 / 64.0, accuracy: 1e-6)

        // Past-start drag (-600 pt -> clamped at 0) has zero build-up: reversing +8 pt moves straight away.
        _ = state.didScroll(sample(offsetY: 100, isTracking: true))
        XCTAssertEqual(state.progress, 0.0, accuracy: 1e-6)
        _ = state.didScroll(sample(offsetY: 108, isTracking: true))
        XCTAssertEqual(state.progress, 8.0 / 64.0, accuracy: 1e-6)

        // Rubber-band overscroll (< 0 at top) does not move p.
        _ = state.didScroll(sample(offsetY: 0, isTracking: true))
        XCTAssertEqual(state.progress, 0.0, accuracy: 1e-6)
        _ = state.didScroll(sample(offsetY: -45, isTracking: true))
        XCTAssertEqual(state.progress, 0.0, accuracy: 1e-6)
        _ = state.didScroll(sample(offsetY: 0, isTracking: true))
        XCTAssertEqual(state.progress, 0.0, accuracy: 1e-6, "Bouncing back from top overscroll must not collapse the bar.")
    }

    func testExactHalfTieExpandsAndAboveHalfCollapses() {
        // Tie from expanded: 0 -> +32 pt -> p == 0.5 -> settles to 0 (expands).
        var fromExpanded = BrowserBarMorphState()
        fromExpanded.willBeginDragging(sample: sample(offsetY: 100, isTracking: true))
        _ = fromExpanded.didScroll(sample(offsetY: 132, isTracking: true))
        XCTAssertEqual(fromExpanded.progress, 0.5, accuracy: 1e-6)
        fromExpanded.willEndDragging(velocityPtPerSec: 0)
        let tieTransition = fromExpanded.didEndDragging(willDecelerate: false, sample: sample(offsetY: 132))
        XCTAssertEqual(tieTransition, .spring(target: 0))
        XCTAssertEqual(fromExpanded.progress, 0)

        // Tie from collapsed: 1.0 -> -32 pt -> p == 0.5 -> settles to 0 (expands).
        var fromCollapsed = BrowserBarMorphState()
        fromCollapsed.willBeginDragging(sample: sample(offsetY: 100, isTracking: true))
        _ = fromCollapsed.didScroll(sample(offsetY: 200, isTracking: true))
        fromCollapsed.willEndDragging(velocityPtPerSec: 0)
        _ = fromCollapsed.didEndDragging(willDecelerate: false, sample: sample(offsetY: 200))
        XCTAssertEqual(fromCollapsed.progress, 1.0)

        fromCollapsed.willBeginDragging(sample: sample(offsetY: 200, isTracking: true))
        _ = fromCollapsed.didScroll(sample(offsetY: 168, isTracking: true))
        XCTAssertEqual(fromCollapsed.progress, 0.5, accuracy: 1e-6)
        fromCollapsed.willEndDragging(velocityPtPerSec: 0)
        let tieUp = fromCollapsed.didEndDragging(willDecelerate: false, sample: sample(offsetY: 168))
        XCTAssertEqual(tieUp, .spring(target: 0))

        // Above 0.5 (e.g. +33 pt -> 33/64) collapses to 1.
        var aboveHalf = BrowserBarMorphState()
        aboveHalf.willBeginDragging(sample: sample(offsetY: 100, isTracking: true))
        _ = aboveHalf.didScroll(sample(offsetY: 133, isTracking: true))
        aboveHalf.willEndDragging(velocityPtPerSec: 0)
        let collapse = aboveHalf.didEndDragging(willDecelerate: false, sample: sample(offsetY: 133))
        XCTAssertEqual(collapse, .spring(target: 1))
    }

    func testFlickVelocitySampledOnceAtFingerUpDrivesSettleAfterCoasting() {
        // Downward flick (> 300 pt/s): finger lifts at p = 0.125, coasts slightly to p = 0.25 (< 0.5),
        // then settles in the flick's direction (1.0) when coasting ends.
        var downFlick = BrowserBarMorphState()
        downFlick.willBeginDragging(sample: sample(offsetY: 100, isTracking: true))
        _ = downFlick.didScroll(sample(offsetY: 108, isTracking: true))
        XCTAssertEqual(downFlick.progress, 0.125, accuracy: 1e-6)
        downFlick.willEndDragging(velocityPtPerSec: 420)
        let fingerUp = downFlick.didEndDragging(willDecelerate: true, sample: sample(offsetY: 108, isDecelerating: true))
        XCTAssertNil(fingerUp, "Coasting continues frame by frame before settling.")

        _ = downFlick.didScroll(sample(offsetY: 116, isDecelerating: true))
        XCTAssertEqual(downFlick.progress, 0.25, accuracy: 1e-6)

        let coastEnd = downFlick.didEndDecelerating(sample: sample(offsetY: 116))
        XCTAssertEqual(coastEnd, .spring(target: 1), "Flick > 300 pt/s settles down despite p = 0.25 < 0.5.")

        // Upward flick (< -300 pt/s) from collapsed: coasts only to p = 0.80 (> 0.5), settles to 0.
        downFlick.completeSpringAnimation()
        downFlick.willBeginDragging(sample: sample(offsetY: 400, isTracking: true))
        _ = downFlick.didScroll(sample(offsetY: 394, isTracking: true))
        downFlick.willEndDragging(velocityPtPerSec: -380)
        _ = downFlick.didEndDragging(willDecelerate: true, sample: sample(offsetY: 394, isDecelerating: true))
        _ = downFlick.didScroll(sample(offsetY: 387.2, isDecelerating: true))
        XCTAssertGreaterThan(downFlick.progress, 0.5)
        let upCoastEnd = downFlick.didEndDecelerating(sample: sample(offsetY: 387.2))
        XCTAssertEqual(upCoastEnd, .spring(target: 0), "Upward flick > 300 pt/s expands despite p > 0.5.")

        // Exactly 300 pt/s is not strictly above 300 pt/s: falls back to nearer-end settle.
        var exactBoundary = BrowserBarMorphState()
        exactBoundary.willBeginDragging(sample: sample(offsetY: 100, isTracking: true))
        _ = exactBoundary.didScroll(sample(offsetY: 116, isTracking: true))
        exactBoundary.willEndDragging(velocityPtPerSec: 300)
        let boundaryEnd = exactBoundary.didEndDragging(willDecelerate: false, sample: sample(offsetY: 116))
        XCTAssertEqual(boundaryEnd, .spring(target: 0))
    }

    func testProgrammaticScrollLoadingInsetSwitchAndZoomAreIgnored() {
        var state = BrowserBarMorphState()
        _ = state.didScroll(sample(offsetY: 0))

        // Programmatic scroll (`run_js` / `scrollTo` / `#fragment`: neither tracking nor decelerating).
        let scriptScroll = state.didScroll(sample(offsetY: 600, isTracking: false, isDecelerating: false))
        XCTAssertNil(scriptScroll)
        XCTAssertEqual(state.progress, 0)

        // Next user drag starts cleanly from 600 with no accumulated delta from 0 -> 600.
        state.willBeginDragging(sample: sample(offsetY: 600, isTracking: true))
        _ = state.didScroll(sample(offsetY: 616, isTracking: true))
        XCTAssertEqual(state.progress, 0.25, accuracy: 1e-6)

        // Pinch-zoom and zoomScale changes do not move p.
        state.willBeginZooming()
        _ = state.didScroll(sample(offsetY: 700, isTracking: true, isZooming: true, zoomScale: 1.4))
        XCTAssertEqual(state.progress, 0.25, accuracy: 1e-6)
        state.didEndZooming(scale: 1.4, sample: sample(offsetY: 700, zoomScale: 1.4))
        _ = state.didScroll(sample(offsetY: 750, isTracking: true, zoomScale: 1.5))
        XCTAssertEqual(state.progress, 0.25, accuracy: 1e-6)

        // Page loading ignores offset changes.
        state.isLoading = true
        _ = state.didScroll(sample(offsetY: 900, isTracking: true, zoomScale: 1.5))
        XCTAssertEqual(state.progress, 0.25, accuracy: 1e-6)
        state.isLoading = false

        // Synchronous contentOffset clamp during an inset switch is ignored.
        state.isApplyingInset = true
        _ = state.didScroll(sample(offsetY: 850, isTracking: true, zoomScale: 1.5))
        XCTAssertEqual(state.progress, 0.25, accuracy: 1e-6)
        state.isApplyingInset = false
    }

    func testHysteresisAndReduceMotionCrossFadeSharePointSixAndPointFourThresholds() {
        var state = BrowserBarMorphState()
        state.willBeginDragging(sample: sample(offsetY: 0, isTracking: true))

        // Rising to 0.60 (`38.4 pt`) keeps both `isChromeMinimized` and Reduce Motion false.
        _ = state.didScroll(sample(offsetY: 38.4, isTracking: true))
        XCTAssertEqual(state.progress, 0.6, accuracy: 1e-6)
        XCTAssertFalse(state.isChromeMinimized)
        XCTAssertEqual(state.displayProgress(reduceMotion: true), 0)

        // Crossing 0.60 (`39.04 pt` -> 0.61) flips both to collapsed; Reduce Motion jumps to end state 1 (no morph).
        _ = state.didScroll(sample(offsetY: 39.04, isTracking: true))
        XCTAssertTrue(state.isChromeMinimized)
        XCTAssertEqual(state.displayProgress(reduceMotion: true), 1)
        XCTAssertEqual(state.displayProgress(reduceMotion: false), 0.61, accuracy: 1e-6)

        // Falling to 0.40 (`25.6 pt`) keeps both true.
        _ = state.didScroll(sample(offsetY: 25.6, isTracking: true))
        XCTAssertEqual(state.progress, 0.4, accuracy: 1e-6)
        XCTAssertTrue(state.isChromeMinimized)
        XCTAssertEqual(state.displayProgress(reduceMotion: true), 1)

        // Falling below 0.40 (`24.96 pt` -> 0.39) flips both back to expanded.
        _ = state.didScroll(sample(offsetY: 24.96, isTracking: true))
        XCTAssertFalse(state.isChromeMinimized)
        XCTAssertEqual(state.displayProgress(reduceMotion: true), 0)
    }

    func testKeyboardFreezePreservesProgressDuringPageFormEditing() {
        var state = BrowserBarMorphState()
        state.willBeginDragging(sample: sample(offsetY: 100, isTracking: true))
        _ = state.didScroll(sample(offsetY: 148, isTracking: true))
        XCTAssertEqual(state.progress, 0.75, accuracy: 1e-6)
        XCTAssertTrue(state.isChromeMinimized)

        // Keyboard rises for an in-page form field: p freezes even if WebKit or the user scrolls.
        state.setKeyboardFrozen(true, currentSample: sample(offsetY: 148))
        _ = state.didScroll(sample(offsetY: 420, isTracking: true))
        _ = state.didScroll(sample(offsetY: 40, isDecelerating: true))
        state.willEndDragging(velocityPtPerSec: -500)
        _ = state.didEndDragging(willDecelerate: false, sample: sample(offsetY: 40))
        XCTAssertEqual(state.progress, 0.75, accuracy: 1e-6)
        XCTAssertTrue(state.isChromeMinimized)

        // Keyboard dismisses: bar returns in the exact same state, re-baselined at 40.
        state.setKeyboardFrozen(false, currentSample: sample(offsetY: 40))
        XCTAssertEqual(state.progress, 0.75, accuracy: 1e-6)
        state.willBeginDragging(sample: sample(offsetY: 40, isTracking: true))
        _ = state.didScroll(sample(offsetY: 56, isTracking: true))
        XCTAssertEqual(state.progress, 1.0, accuracy: 1e-6)
    }

    func testShortPageNeverCollapsesAndRestInsetSwitchesOnlyAtEnds() {
        var shortState = BrowserBarMorphState()
        shortState.willBeginDragging(sample: sample(offsetY: 0, contentHeight: 720, viewportHeight: 785, isTracking: true))
        _ = shortState.didScroll(sample(offsetY: 50, contentHeight: 720, viewportHeight: 785, isTracking: true))
        XCTAssertEqual(shortState.progress, 0, "A page shorter than the screen must never collapse.")
        XCTAssertEqual(shortState.appliedBottomInset, 86)

        // WKWebView floors contentSize.height at bounds.height even on 1-line pages (plus sub-point Retina rounding).
        shortState.willBeginDragging(sample: sample(offsetY: 0, contentHeight: 785.33, viewportHeight: 785, isTracking: true))
        _ = shortState.didScroll(sample(offsetY: 86, contentHeight: 785.33, viewportHeight: 785, isTracking: true))
        XCTAssertEqual(shortState.progress, 0, "WKWebView's floored contentSize.height == bounds.height must also stay short.")

        // Long page: inset stays 86 during drag even after p reaches 1.0, then switches to 0 at rest.
        var longState = BrowserBarMorphState()
        XCTAssertEqual(longState.appliedBottomInset, 86)
        longState.willBeginDragging(sample: sample(offsetY: 0, isTracking: true))
        _ = longState.didScroll(sample(offsetY: 80, isTracking: true))
        XCTAssertEqual(longState.progress, 1.0)
        XCTAssertEqual(longState.appliedBottomInset, 86, "Inset must not switch mid-drag.")

        // Drag straight to p == 1 with no deceleration -> immediately at rest -> inset becomes 0.
        longState.willEndDragging(velocityPtPerSec: 0)
        _ = longState.didEndDragging(willDecelerate: false, sample: sample(offsetY: 80, bottomInset: 86))
        XCTAssertTrue(longState.isAtRest)
        XCTAssertEqual(longState.appliedBottomInset, 0)

        // Pill tap starts a spring to 0: inset stays 0 while springing and becomes 86 once the spring completes.
        let pillTap = longState.requestExpand(deferIfTracking: false)
        XCTAssertEqual(pillTap, .spring(target: 0))
        XCTAssertEqual(longState.appliedBottomInset, 0, "Inset waits for the spring to finish.")
        longState.completeSpringAnimation()
        XCTAssertTrue(longState.isAtRest)
        XCTAssertEqual(longState.appliedBottomInset, 86)

        // Page-bottom sequence: after page-end expand sets inset to 86 (`maxOffset = 2400 - 785 + 86 = 1701`),
        // a further drag down from 1615 -> 1701 collapses (`p == 1`, inset still 86 while tracking),
        // and finger-up at the end (`1701`) re-expands to `0` with no flapping.
        longState.willBeginDragging(sample: sample(offsetY: 1615, bottomInset: 86, isTracking: true))
        _ = longState.didScroll(sample(offsetY: 1701, bottomInset: 86, isTracking: true))
        XCTAssertEqual(longState.progress, 1.0)
        XCTAssertEqual(longState.appliedBottomInset, 86)
        longState.willEndDragging(velocityPtPerSec: 0)
        let bottomLift = longState.didEndDragging(willDecelerate: false, sample: sample(offsetY: 1701, bottomInset: 86))
        XCTAssertEqual(bottomLift, .spring(target: 0))
        longState.completeSpringAnimation()
        XCTAssertEqual(longState.progress, 0)
        XCTAssertEqual(longState.appliedBottomInset, 86)
    }

    func testBarExpandsWhenAgentFinishesOrAsksConfirmationOnceFingerIsUp() async throws {
        // 1. State machine: while finger is down, discrete expand waits until finger-up.
        var state = BrowserBarMorphState()
        state.willBeginDragging(sample: sample(offsetY: 0, isTracking: true))
        _ = state.didScroll(sample(offsetY: 80, isTracking: true))
        XCTAssertEqual(state.progress, 1.0)

        let deferred = state.requestExpand(deferIfTracking: true)
        XCTAssertNil(deferred, "Must not spring while a finger is on the page.")
        XCTAssertTrue(state.pendingExpandWhenFingerUp)
        XCTAssertEqual(state.progress, 1.0)

        state.willEndDragging(velocityPtPerSec: 500)
        let onLift = state.didEndDragging(willDecelerate: true, sample: sample(offsetY: 80, isDecelerating: true))
        XCTAssertEqual(onLift, .spring(target: 0), "Springs open as soon as the finger lifts.")
        XCTAssertFalse(state.pendingExpandWhenFingerUp)

        // 2. AppModel integration: Agent asking a confirmation or finishing a run with panel closed expands chrome.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let app = AppModel(store: store, aiService: StubAgentAIService())
        app.browser.onPageContextChanged = nil
        app.settings.browserAgentModel = ModelSelection(provider: .ollama, model: "qwen3")
        XCTAssertFalse(app.isAIViewShown)

        let mockScroll = MockTrackingScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 785))
        mockScroll.contentSize = CGSize(width: 390, height: 2400)
        app.browser.barMorph.attach(to: mockScroll)
        app.browser.barMorph.updateLayoutConfiguration(
            managesInsets: true,
            position: .bottom,
            safeAreaBottom: 34,
            isLandscape: false,
            isLockedExpanded: false,
            reduceMotion: false
        )
        XCTAssertEqual(mockScroll.contentInset.bottom, 86, accuracy: 0.5)

        func collapseViaUserDrag() {
            mockScroll.mockIsTracking = true
            mockScroll.contentOffset = .zero
            app.browser.barMorph.scrollViewWillBeginDragging(mockScroll)
            mockScroll.contentOffset = CGPoint(x: 0, y: 90)
            app.browser.barMorph.scrollViewDidScroll(mockScroll)
            var target = CGPoint(x: 0, y: 90)
            app.browser.barMorph.scrollViewWillEndDragging(mockScroll, withVelocity: .zero, targetContentOffset: &target)
            mockScroll.mockIsTracking = false
            app.browser.barMorph.scrollViewDidEndDragging(mockScroll, willDecelerate: false)
        }

        collapseViaUserDrag()
        XCTAssertTrue(app.browser.isChromeMinimized)
        XCTAssertEqual(app.browser.barProgress, 1.0)
        XCTAssertEqual(mockScroll.contentInset.bottom, 0, accuracy: 0.5)

        // Agent asks an M3 confirmation while panel is closed -> bar springs to 0.
        let askTask = Task { @MainActor in
            try await app.agentConfirmations.ask(tool: "http_request", question: "Send POST to example.org?")
        }
        await Task.yield()
        XCTAssertEqual(app.agentConfirmations.pending.count, 1)
        XCTAssertEqual(app.browser.barProgress, 0.0, "Asking a confirmation with panel closed springs the bar open.")
        XCTAssertFalse(app.browser.isChromeMinimized)
        if let id = app.agentConfirmations.pending.first?.id {
            app.agentConfirmations.resolve(id, allow: false)
        }
        _ = try await askTask.value

        // Collapse again, then run a browserAgent turn that finishes with panel closed -> bar springs to 0.
        collapseViaUserDrag()
        XCTAssertTrue(app.browser.isChromeMinimized)
        await app.browserAgent.sendAndWait("Summarize this page")
        XCTAssertEqual(app.browser.barProgress, 0.0, "Agent finishing a run with panel closed springs the bar open.")
        XCTAssertFalse(app.browser.isChromeMinimized)
    }

    func testSafeAreaAndLandscapeGeometryMatchesDesignTable() {
        // Portrait 390 pt width, 34 pt bottom safe area.
        XCTAssertEqual(BrowserBarMorphMetrics.expandedWidth(containerWidth: 390), 366)
        XCTAssertEqual(BrowserBarMorphMetrics.expandedHeight(isLandscape: false), 56)
        XCTAssertEqual(BrowserBarMorphMetrics.bottomEdgeFromScreen(safeAreaBottom: 34, progress: 0), 30)
        XCTAssertEqual(BrowserBarMorphMetrics.bottomEdgeFromScreen(safeAreaBottom: 34, progress: 1), 20)
        XCTAssertEqual(BrowserBarMorphMetrics.expandedWebViewBottomInset(safeAreaBottom: 34, isLandscape: false), 86)

        // Zero safe-area device never drops closer than 8 pt to screen edge.
        XCTAssertEqual(BrowserBarMorphMetrics.bottomEdgeFromScreen(safeAreaBottom: 0, progress: 0), 8)
        XCTAssertEqual(BrowserBarMorphMetrics.bottomEdgeFromScreen(safeAreaBottom: 0, progress: 1), 8)

        // Landscape caps width at 520 pt and uses 48 pt expanded height.
        XCTAssertEqual(BrowserBarMorphMetrics.expandedWidth(containerWidth: 844), 520)
        XCTAssertEqual(BrowserBarMorphMetrics.expandedHeight(isLandscape: true), 48)

        // Collapsed width clamps to 120...240 pt.
        XCTAssertEqual(BrowserBarMorphMetrics.collapsedWidth(domainWidth: 20, isAgentWorking: false, scriptCount: 0), 120)
        XCTAssertEqual(BrowserBarMorphMetrics.collapsedWidth(domainWidth: 400, isAgentWorking: true, scriptCount: 12), 240)
    }

    func testCoordinatorPublishesContinuousProgressDuringDragAndSwitchesInsetAtRest() {
        let coordinator = BrowserBarScrollCoordinator()
        let scrollView = MockTrackingScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 785))
        scrollView.contentSize = CGSize(width: 390, height: 2400)
        coordinator.attach(to: scrollView)
        coordinator.updateLayoutConfiguration(
            managesInsets: true,
            position: .bottom,
            safeAreaBottom: 34,
            isLandscape: false,
            isLockedExpanded: false,
            reduceMotion: false
        )
        XCTAssertEqual(scrollView.contentInset.bottom, 86, accuracy: 0.5)

        var recordedProgress: [CGFloat] = []
        coordinator.onChange = { state, _ in
            recordedProgress.append(state.progress)
        }

        scrollView.mockIsTracking = true
        scrollView.contentOffset = .zero
        coordinator.scrollViewWillBeginDragging(scrollView)

        scrollView.contentOffset = CGPoint(x: 0, y: 16)
        coordinator.scrollViewDidScroll(scrollView)
        XCTAssertEqual(recordedProgress.last ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentInset.bottom, 86, accuracy: 0.5, "Inset must stay 86 during drag.")

        scrollView.contentOffset = CGPoint(x: 0, y: 48)
        coordinator.scrollViewDidScroll(scrollView)
        XCTAssertEqual(recordedProgress.last ?? -1, 0.75, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentInset.bottom, 86, accuracy: 0.5, "Inset must stay 86 during drag.")

        scrollView.contentOffset = CGPoint(x: 0, y: 80)
        coordinator.scrollViewDidScroll(scrollView)
        XCTAssertEqual(recordedProgress.last ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentInset.bottom, 86, accuracy: 0.5, "Inset still waits for finger-up rest.")

        var target = CGPoint(x: 0, y: 80)
        coordinator.scrollViewWillEndDragging(scrollView, withVelocity: .zero, targetContentOffset: &target)
        scrollView.mockIsTracking = false
        coordinator.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        XCTAssertEqual(scrollView.contentInset.bottom, 0, accuracy: 0.5, "Inset switches to 0 once resting at p = 1.")
    }

    func testSplitLayoutWithoutInsetManagementStillUpdatesIsChromeMinimized() {
        let coordinator = BrowserBarScrollCoordinator()
        let scrollView = MockTrackingScrollView(frame: CGRect(x: 0, y: 0, width: 1180, height: 760))
        scrollView.contentSize = CGSize(width: 1180, height: 2600)
        coordinator.attach(to: scrollView)
        coordinator.updateLayoutConfiguration(
            managesInsets: false,
            position: .top,
            safeAreaBottom: 20,
            isLandscape: true,
            isLockedExpanded: false,
            reduceMotion: false
        )

        XCTAssertEqual(scrollView.contentInset, .zero, "iPad split leaves scrollView.contentInset at zero.")
        XCTAssertEqual(scrollView.contentInsetAdjustmentBehavior, .automatic)
        XCTAssertFalse(coordinator.state.isChromeMinimized)

        scrollView.mockIsTracking = true
        scrollView.contentOffset = .zero
        coordinator.scrollViewWillBeginDragging(scrollView)

        scrollView.contentOffset = CGPoint(x: 0, y: 48)
        coordinator.scrollViewDidScroll(scrollView)
        XCTAssertTrue(coordinator.state.isChromeMinimized, "Scrolling past p > 0.6 in split still minimizes result cards.")
        XCTAssertEqual(scrollView.contentInset, .zero, "Split never writes bottom bar insets onto scrollView.")

        var target = CGPoint(x: 0, y: 48)
        coordinator.scrollViewWillEndDragging(scrollView, withVelocity: .zero, targetContentOffset: &target)
        scrollView.mockIsTracking = false
        coordinator.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        XCTAssertEqual(scrollView.contentInset, .zero)

        coordinator.requestExpand(deferIfTracking: false)
        XCTAssertFalse(coordinator.state.isChromeMinimized, "Tapping resultCardsChip expands chrome in split.")
        XCTAssertEqual(scrollView.contentInset, .zero)
    }

    func testStopLoadingClearsLoadingWithoutLatchingStaleWebViewState() async {
        let browser = ForumBrowserModel()
        // Wait for content-blocker rule lookups so `load(_:)` dispatches straight into `webView.load(_:)`.
        await browser.contentBlocker.library.waitForLookups(timeout: .seconds(5))
        browser.load(URL(string: "https://forum.example.com")!)
        browser.stopLoading()

        XCTAssertFalse(browser.isLoading, "stopLoading() must not latch webView.isLoading before WebKit IPC settles.")
        XCTAssertFalse(browser.barMorphState.isLoading, "stopLoading() must leave barMorph's loading guard cleared.")
    }

    func testExpandedBarControlsExposeVoiceOverMetadataAndLargeContentViewer() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let app = AppModel(store: store, aiService: StubAgentAIService())
        app.browser.onPageContextChanged = nil
        app.settings.browserAgentModel = ModelSelection(provider: .ollama, model: "qwen3")

        let pageURL = URL(string: "https://news.example.org/story/bar-morph")!
        app.browser.loadSamplePage("<!doctype html><html><title>Night Ferries</title><body><p>Body</p></body></html>", at: pageURL)
        app.browser.setPageContext(PageContext(url: pageURL, state: .notForum))

        let actions = BrowserActions(
            showLoginInfo: {},
            addForum: {},
            openForum: { _ in },
            showForumsHome: {}
        )
        let barView = PhoneMorphingBar(
            app: app,
            browser: app.browser,
            browserAgent: app.browserAgent,
            scriptStore: app.scriptStore,
            voice: app.voice,
            actions: actions,
            position: .bottom,
            containerWidth: 390,
            safeAreaBottom: 34,
            isLandscape: false,
            progress: 0,
            reduceMotion: false,
            reduceTransparency: false,
            increasedContrast: false,
            onEdit: {}
        )

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIHostingController(rootView: barView)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        func allSubviews(in root: UIView) -> [UIView] {
            [root] + root.subviews.flatMap(allSubviews(in:))
        }
        let views = allSubviews(in: host.view)

        let backControl = views.first { $0.accessibilityIdentifier == "browserBack" } as? UIControl
        XCTAssertNotNil(backControl, "Expected UIControl for browserBack.")
        XCTAssertEqual(backControl?.accessibilityLabel, "Back")
        XCTAssertEqual(backControl?.showsLargeContentViewer, true)
        XCTAssertEqual(backControl?.largeContentTitle, "Back")
        XCTAssertNotNil(backControl?.largeContentImage)
        XCTAssertEqual(backControl?.interactions.contains { $0 is UILargeContentViewerInteraction }, true)

        // Expanded font size caps at XXXL so accessibility sizes keep the single-row 44 pt bar geometry.
        XCTAssertEqual(
            BrowserBarFontMetrics.expandedFontSize(for: .xxxLarge),
            BrowserBarFontMetrics.expandedFontSize(for: .accessibility5),
            accuracy: 0.001
        )
    }
}
