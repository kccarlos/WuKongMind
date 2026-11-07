import SwiftUI
import UIKit
import XCTest
@testable import Forumind

/// iPad workspace rules: split threshold with hysteresis, panel width
/// clamping, and web content crash recovery.
@MainActor
final class IPadLayoutTests: XCTestCase {
    /// Window widths from iPad multitasking: Slide Over / 1/3 (320), 1/2 on
    /// 11" (507), 1/2 on 13" (678), mini portrait (744), Air 11 portrait
    /// (820), Pro 11 portrait (834), 13" portrait (1032), 13" landscape (1366).
    func testFreshWindowsUseTheLayoutTheirWidthImplies() {
        for width: CGFloat in [320, 507, 678, 744, 820, 834] {
            XCTAssertFalse(WorkspaceMetrics.nextIsSplit(current: nil, width: width, idiom: .pad), "\(width)")
        }
        for width: CGFloat in [850, 981, 1_032, 1_180, 1_366] {
            XCTAssertTrue(WorkspaceMetrics.nextIsSplit(current: nil, width: width, idiom: .pad), "\(width)")
        }
        XCTAssertFalse(WorkspaceMetrics.nextIsSplit(current: nil, width: 1_366, idiom: .phone))
    }

    func testResizingNearTheThresholdDoesNotFlap() {
        // Split stays split down to the exit width…
        XCTAssertTrue(WorkspaceMetrics.nextIsSplit(current: true, width: 845, idiom: .pad))
        XCTAssertTrue(WorkspaceMetrics.nextIsSplit(current: true, width: 830, idiom: .pad))
        XCTAssertFalse(WorkspaceMetrics.nextIsSplit(current: true, width: 829, idiom: .pad))
        // …and single pane needs the full threshold to split again.
        XCTAssertFalse(WorkspaceMetrics.nextIsSplit(current: false, width: 845, idiom: .pad))
        XCTAssertTrue(WorkspaceMetrics.nextIsSplit(current: false, width: 850, idiom: .pad))
        // Rotating an Air 11 (1180 ↔ 820) always switches.
        XCTAssertFalse(WorkspaceMetrics.nextIsSplit(current: true, width: 820, idiom: .pad))
        XCTAssertTrue(WorkspaceMetrics.nextIsSplit(current: false, width: 1_180, idiom: .pad))
        // The band holds no real iPad window width (Pro 11 portrait is 834).
        XCTAssertGreaterThan(834, WorkspaceMetrics.splitExitWidth)
    }

    func testPanelWidthIsClampedToTheWindowAndRange() {
        // Default: 40% of the window within 360…560.
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: nil, containerWidth: 1_032), 412.8, accuracy: 0.1)
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: nil, containerWidth: 1_366), 546.4, accuracy: 0.1)
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: nil, containerWidth: 850), DCTheme.panelMinimumWidth)
        // A chosen width is kept, but the page keeps its minimum room…
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: 540, containerWidth: 1_366), 540)
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: 540, containerWidth: 900), 439)
        // …and the range holds at both ends.
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: 900, containerWidth: 1_366), DCTheme.panelMaximumWidth)
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: 100, containerWidth: 1_366), DCTheme.panelMinimumWidth)
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: 540, containerWidth: 700), DCTheme.panelMinimumWidth)
    }

    /// Space is a key command only while an episode is loaded and no text
    /// is being edited; otherwise it types or scrolls (audit A5).
    func testSpacePlaysOrPausesOnlyWithAnEpisodeAndNoTextBeingEdited() {
        XCTAssertTrue(PlayPauseShortcut.isEnabled(episodeLoaded: true, editingText: false))
        XCTAssertFalse(PlayPauseShortcut.isEnabled(episodeLoaded: true, editingText: true))
        XCTAssertFalse(PlayPauseShortcut.isEnabled(episodeLoaded: false, editingText: false))
        XCTAssertFalse(PlayPauseShortcut.isEnabled(episodeLoaded: false, editingText: true))
        // No episode at launch: not registered.
        XCTAssertFalse(AppModel().playPauseShortcut.isEnabled)
    }

    func testSplitPanelIsCollapsedOnHomeAndShownOnPagesUntilToggled() {
        XCTAssertFalse(SplitPanelMode.auto.isVisible(onHome: true))
        XCTAssertTrue(SplitPanelMode.auto.isVisible(onHome: false))
        // The toggle flips what shows, whichever page it is on.
        XCTAssertEqual(SplitPanelMode.auto.toggled(onHome: false), .hidden)
        XCTAssertEqual(SplitPanelMode.auto.toggled(onHome: true), .shown)
        XCTAssertTrue(SplitPanelMode.shown.isVisible(onHome: true))
        XCTAssertFalse(SplitPanelMode.hidden.isVisible(onHome: false))
        XCTAssertEqual(SplitPanelMode.shown.toggled(onHome: false), .hidden)
        XCTAssertEqual(SplitPanelMode.hidden.toggled(onHome: false), .shown)
    }

    func testBackLeavesTheFormsHomeBeforeThePageHistory() {
        let browser = ForumBrowserModel()
        XCTAssertFalse(browser.canNavigateBack)
    }

    func testWebContentCrashReloadsOnceThenShowsTheBanner() {
        let browser = ForumBrowserModel()
        let start = Date()
        browser.handleWebContentTermination(now: start)
        XCTAssertFalse(browser.showsCrashNotice, "No page loaded: nothing to reload or report.")

        browser.load(URL(string: "https://meta.discourse.org/latest")!)
        let later = start.addingTimeInterval(ForumBrowserModel.crashReloadWindow + 1)
        browser.handleWebContentTermination(now: later)
        XCTAssertFalse(browser.showsCrashNotice, "The first crash reloads quietly.")

        browser.handleWebContentTermination(now: later.addingTimeInterval(5))
        XCTAssertTrue(browser.showsCrashNotice, "A second crash soon after shows the banner instead of looping.")
        XCTAssertFalse(browser.isLoading, "The bar must not keep a spinning Stop button.")

        browser.retryAfterCrash()
        XCTAssertFalse(browser.showsCrashNotice)
        browser.webView.stopLoading()
    }

    func testVoiceOverAdjustsPanelWidthInExpectedDirectionAndNarrowIPadUsesTwoColumnSummary() {
        // 1. VoiceOver adjustable action widens on `.increment` (+40) and shrinks on `.decrement` (-40).
        let containerWidth: CGFloat = 1_032
        let initial = WorkspaceMetrics.panelWidth(preferred: nil, containerWidth: containerWidth)
        let incremented = WorkspaceMetrics.adjustedPanelWidth(
            current: initial,
            delta: WorkspaceMetrics.panelWidthStep,
            containerWidth: containerWidth
        )
        let decremented = WorkspaceMetrics.adjustedPanelWidth(
            current: initial,
            delta: -WorkspaceMetrics.panelWidthStep,
            containerWidth: containerWidth
        )
        XCTAssertEqual(incremented, initial + WorkspaceMetrics.panelWidthStep, accuracy: 0.1)
        XCTAssertEqual(decremented, initial - WorkspaceMetrics.panelWidthStep, accuracy: 0.1)
        XCTAssertTrue(WorkspaceMetrics.usesTwoColumnSummary(windowWidth: 834, isSplit: false))
        XCTAssertTrue(WorkspaceMetrics.usesTwoColumnSummary(windowWidth: 820, isSplit: false))
        XCTAssertFalse(WorkspaceMetrics.usesTwoColumnSummary(windowWidth: 507, isSplit: false))
        XCTAssertFalse(WorkspaceMetrics.usesTwoColumnSummary(windowWidth: 1_032, isSplit: true))

        // 2. Narrow iPad portrait (`834pt`, Spec §10 & Decision #5) lays out summary sections in two columns at medium height,
        // while narrow phone width (`393pt`) keeps a single vertical column.
        let oneParsed = DrawerSummarySections.parsed(
            for: .init(text: "## Original post\nFirst section body text.", maximumPost: 20)
        )
        let twoParsed = DrawerSummarySections.parsed(
            for: .init(text: "## Original post\nFirst section body text.\n\n## What people are saying\nSecond section body text.", maximumPost: 20)
        )
        let oneWide = UIHostingController(rootView: VStack(alignment: .leading, spacing: 0) { DrawerSummarySections(rows: oneParsed.rows) })
        let twoWide = UIHostingController(rootView: VStack(alignment: .leading, spacing: 0) { DrawerSummarySections(rows: twoParsed.rows) })
        let oneWideSize = oneWide.sizeThatFits(in: CGSize(width: 834, height: UIView.layoutFittingCompressedSize.height))
        let twoWideSize = twoWide.sizeThatFits(in: CGSize(width: 834, height: UIView.layoutFittingCompressedSize.height))
        XCTAssertLessThan(twoWideSize.height, oneWideSize.height * 1.4,
                          "At 834pt narrow iPad width, two equal summary sections should sit side-by-side (\(twoWideSize.height)pt vs \(oneWideSize.height)pt)")

        let onePhone = UIHostingController(rootView: VStack(alignment: .leading, spacing: 0) { DrawerSummarySections(rows: oneParsed.rows) })
        let twoPhone = UIHostingController(rootView: VStack(alignment: .leading, spacing: 0) { DrawerSummarySections(rows: twoParsed.rows) })
        let onePhoneSize = onePhone.sizeThatFits(in: CGSize(width: 393, height: UIView.layoutFittingCompressedSize.height))
        let twoPhoneSize = twoPhone.sizeThatFits(in: CGSize(width: 393, height: UIView.layoutFittingCompressedSize.height))
        XCTAssertGreaterThan(twoPhoneSize.height, onePhoneSize.height * 1.7,
                             "At 393pt iPhone width, two summary sections stay stacked in 1 column (\(twoPhoneSize.height)pt vs \(onePhoneSize.height)pt)")
    }
}
