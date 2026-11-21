import SwiftUI

// MARK: - iPad split layout (spec §10, design-browser-bar-tabs-models.md §1)
//
// Windows 850 pt and wider: the page column on the left with its floating
// morphing top bar (`PhoneBrowser` + `SplitBarContext`), and the AI panel on
// the right (360–560 pt, draggable). Scrolling collapses the top bar to a
// 200 × 34 pill centred over the page column while the AI panel stays in place.

/// The split top bar's extras.
struct SplitBarContext {
    let panelShown: Bool
    let pageColumnWidth: CGFloat
    let togglePanel: () -> Void
}

/// Hide or show the AI panel (⌥⌘0), with the AI button's research ring and
/// new-replies dot (the split layout has no hint row).
struct SplitPanelToggle: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var browser: ForumBrowserModel
    let isShown: Bool
    let action: () -> Void

    init(app: AppModel, isShown: Bool, action: @escaping () -> Void) {
        self.app = app
        _browser = ObservedObject(wrappedValue: app.browser)
        self.isShown = isShown
        self.action = action
    }

    private var browserAgent: BrowserAgentSession { app.browserAgent }
    private var isAvailable: Bool { app.isSplitPanelAvailable }
    private var showsNewRepliesDot: Bool { app.showsNewRepliesDot }
    private var ringState: AgentRingState { app.agentRingState(isAvailable: isAvailable) }

    /// "Hidden, New replies, Ask this site is searching": what the ring and
    /// the dot show.
    private var accessibilityValue: String {
        var parts = [isShown ? String(localized: "Shown") : String(localized: "Hidden")]
        if showsNewRepliesDot {
            parts.append(String(localized: "New replies", comment: "Accessibility value of the iPhone AI button while its dot says the topic has new replies"))
        }
        if ringState == .working, !browserAgent.isRunning, app.activeResearch != nil {
            parts.append(String(localized: "Ask this site is searching", comment: "Accessibility value of the AI panel toggle while its ring shows an Ask this site search running"))
        } else if let stateWord = ringState.accessibilityValue {
            parts.append(stateWord)
        }
        if let scriptDesc = app.toolbarScriptAccessibilityDescription {
            parts.append(scriptDesc)
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Button {
            DCHaptics.tap()
            action()
        } label: {
            DCAgentRing(
                state: ringState,
                size: PhoneAIButton.ringSize,
                lineWidth: DCTheme.ringWidth,
                panelVisible: isShown
            )
            .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
            .background {
                if isShown {
                    Circle()
                        .fill(DCTheme.goldWash)
                        .padding(2)
                }
            }
        }
        .buttonStyle(DCIconButtonStyle())
        .disabled(!isAvailable)
        .overlay(alignment: .topTrailing) {
            let badge = app.toolbarScriptBadgeSummary
            if badge.isVisible {
                ScriptCountBadge(summary: badge)
            } else if showsNewRepliesDot {
                NewRepliesDot()
            }
        }
        .accessibilityLabel(isShown ? Text("Hide AI panel") : Text("Show AI panel"))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityActions {
            if browserAgent.isRunning {
                Button("Stop agent") { browserAgent.stop() }
            }
        }
        .accessibilityIdentifier("aiPanelToggle")
    }
}

/// The window's content: the page under the bar, with the AI panel beside
/// it in the split layout. One view for both layouts, so the web view keeps
/// its place when the width crosses the threshold.
struct WorkspaceView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var router: PresentationRouter
    let width: CGFloat
    let actions: BrowserActions
    var addressFocusRequest = 0
    let onOpenURL: (URL) -> Void

    private var liveWidth: CGFloat {
        router.windowWidth > 0 ? router.windowWidth : width
    }

    private var isSplit: Bool {
        router.splitLayout ?? ContentView.usesSplitLayout(width: liveWidth)
    }

    var body: some View {
        let currentWidth = liveWidth
        let split = isSplit
        let showsPanel = app.showsSplitPanel(forWidth: currentWidth)
        let resolvedPosition = split ? BrowserBarPosition.top : app.settings.browserBarPosition.resolved(isSplit: false)
        PhoneBrowser(
            app: app,
            browser: browser,
            voice: app.voice,
            position: resolvedPosition,
            actions: actions,
            addressFocusRequest: addressFocusRequest,
            width: currentWidth,
            split: split
                ? SplitBarContext(
                    panelShown: showsPanel,
                    pageColumnWidth: currentWidth,
                    togglePanel: app.toggleAIView
                )
                : nil
        ) { dockClearance in
            WorkspaceSplitRow(
                app: app,
                browser: browser,
                router: router,
                width: currentWidth,
                fallbackDockClearance: dockClearance,
                actions: actions,
                onOpenURL: onOpenURL
            )
        }
    }
}

private struct WorkspaceSplitRow: View {
    @ObservedObject var app: AppModel
    @ObservedObject var browser: ForumBrowserModel
    @ObservedObject var router: PresentationRouter
    let width: CGFloat
    let fallbackDockClearance: CGFloat
    let actions: BrowserActions
    let onOpenURL: (URL) -> Void
    /// The panel's width: what the reader chose with the handle (0 = 40% of
    /// the window).
    @AppStorage("dc.assistantPanelWidth") private var storedWidth: Double = 0
    @State private var dragStartWidth: CGFloat?
    @State private var dropTargeted = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var liveWidth: CGFloat {
        router.windowWidth > 0 ? router.windowWidth : width
    }

    private var isSplit: Bool {
        router.splitLayout ?? ContentView.usesSplitLayout(width: liveWidth)
    }

    private var panelVisible: Bool {
        app.showsSplitPanel(forWidth: liveWidth)
    }

    private var panelWidth: CGFloat {
        WorkspaceMetrics.panelWidth(
            preferred: router.splitPanelDragWidth ?? (storedWidth > 0 ? CGFloat(storedWidth) : nil),
            containerWidth: liveWidth
        )
    }

    var body: some View {
        let split = isSplit
        let showsPanel = panelVisible
        let showsHomeOverlay = browser.isEditingAddress && !browser.showsForumsHome
        let showsHome = browser.showsForumsHome || showsHomeOverlay
        let showsWebView = !browser.showsForumsHome
        let resolvedPosition = split ? BrowserBarPosition.top : app.settings.browserBarPosition.resolved(isSplit: false)
        let dockClearance = BrowserBarFontMetrics.bottomDockClearance(
            app: app,
            browser: browser,
            voice: app.voice,
            isSplit: split,
            position: resolvedPosition,
            safeAreaBottom: BrowserBarFontMetrics.normalSceneSafeAreaBottom(),
            isLandscape: verticalSizeClass == .compact,
            dynamicTypeSize: dynamicTypeSize
        )
        let homeBottomInset: CGFloat? = (!split && resolvedPosition == .bottom && browser.isEditingAddress)
            ? DCTheme.controlHeight + 12
            : nil
        HStack(spacing: 0) {
            BrowserContent(
                app: app,
                browser: browser,
                voice: app.voice,
                actions: actions,
                cardsBottomInset: dockClearance,
                homeBottomInset: homeBottomInset,
                floatingTopBarInset: resolvedPosition == .top
                    ? (split ? BrowserBarMorphMetrics.expandedWebViewTopInset(isSplit: true, isLandscape: verticalSizeClass == .compact) : 64)
                    : 0,
                webViewIgnoresBottomSafeArea: showsWebView,
                showsHomeWhileEditing: true,
                dockFloatsTrailing: split && !showsPanel
            )
            .ignoresSafeArea(.keyboard, edges: !showsHome ? .bottom : [])
            .frame(maxWidth: .infinity)
            if showsPanel { panel }
        }
    }

    @ViewBuilder
    private var panel: some View {
        let containerWidth = liveWidth
        let current = panelWidth
        PanelResizeHandle(
            panelWidth: current,
            onDrag: { translation in
                let start = dragStartWidth ?? current
                dragStartWidth = start
                // The panel is on the right: dragging left widens it.
                router.splitPanelDragWidth = WorkspaceMetrics.panelWidth(
                    preferred: start - translation,
                    containerWidth: containerWidth
                )
            },
            onDragEnded: {
                if let dragWidth = router.splitPanelDragWidth {
                    storedWidth = Double(dragWidth)
                }
                router.splitPanelDragWidth = nil
                dragStartWidth = nil
            },
            // Width changes are not animated: animating a List's width (the
            // Forums home) can loop UICollectionView self-sizing.
            onReset: { storedWidth = 0 },
            onAdjust: { delta in
                storedWidth = Double(
                    WorkspaceMetrics.adjustedPanelWidth(
                        current: current,
                        delta: delta,
                        containerWidth: containerWidth
                    )
                )
            }
        )
        AssistantPanel(
            app: app,
            // Post & responses opens as a sheet, like in the drawer.
            onExpand: { route in app.router.item = .expanded(route) },
            onOpenURL: onOpenURL
        )
        .frame(width: current)
        .background(DCTheme.surface.ignoresSafeArea())
        // A forum link dropped on the panel: summarize it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, ForumBrowserModel.isBrowsableURL(url) else { return false }
            app.openShared(url: url, action: "summary")
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                    .strokeBorder(DCTheme.gold, lineWidth: 3)
                    .background(.regularMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
                    .overlay {
                        Label("Summarize this link", systemImage: "link")
                            .font(.headline)
                            .foregroundStyle(DCTheme.goldInk)
                    }
                    .padding(DCTheme.spacingS)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aiPanel")
    }
}
