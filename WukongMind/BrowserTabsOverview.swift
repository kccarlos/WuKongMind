import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - State & Pure Metrics

struct TabClosedToastState: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let hadConversation: Bool
}

enum TabOverviewTransitionMetrics {
    static let standardDuration: Double = 0.25
    static let reduceMotionDuration: Double = 0.2

    static func duration(reduceMotion: Bool) -> Double {
        reduceMotion ? reduceMotionDuration : standardDuration
    }

    static func animation(reduceMotion: Bool) -> Animation {
        .easeInOut(duration: duration(reduceMotion: reduceMotion))
    }

    static func usesZoom(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func columnCount(isPadOverview: Bool, isAccessibilitySize: Bool) -> Int {
        if isPadOverview {
            return isAccessibilitySize ? 2 : 4
        }
        return isAccessibilitySize ? 1 : 2
    }

    /// Approximate unit-point anchor of card `index` in the overview grid so opening zooms
    /// the active page down toward its card and choosing a card zooms up from that card.
    static func cardZoomAnchor(
        index: Int,
        columnCount: Int,
        isPadOverview: Bool
    ) -> UnitPoint {
        let cols = max(1, columnCount)
        let safeIndex = max(0, index)
        let col = safeIndex % cols
        let row = min(2, safeIndex / cols)

        let x: CGFloat
        if cols == 1 {
            x = 0.5
        } else {
            let margin: CGFloat = isPadOverview ? 0.14 : 0.26
            let span = 1 - 2 * margin
            x = margin + span * (CGFloat(col) / CGFloat(cols - 1))
        }

        let topBase: CGFloat = isPadOverview ? 0.28 : 0.24
        let rowStep: CGFloat = isPadOverview ? 0.30 : 0.28
        let y = min(0.84, topBase + CGFloat(row) * rowStep)
        return UnitPoint(x: x, y: y)
    }

    static func cardAccessibilityLabel(
        title: String,
        host: String?,
        isHome: Bool,
        isCurrent: Bool,
        isAgentWorking: Bool
    ) -> String {
        var parts: [String] = [title]
        if !isHome,
           let host,
           !host.isEmpty,
           host.caseInsensitiveCompare(title) != .orderedSame {
            parts.append(host)
        }
        if isCurrent {
            parts.append(
                String(
                    localized: "current tab",
                    comment: "VoiceOver segment on the active tab card in the tab overview"
                )
            )
        }
        if isAgentWorking {
            parts.append(
                String(
                    localized: "Agent working",
                    comment: "VoiceOver segment and badge on a tab card while its Agent is working"
                )
            )
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Browser Bar Tabs Button & Native Long-Press Menu

/// The two-overlapping-squares button in the iPhone and iPad browser bars (`design-browser-bar-tabs-models.md` §2):
/// tap opens the tab overview; long press opens a native `UIMenu` with New Tab, Close This Tab, and open tabs.
/// Uses a single `UIControl` like `PhoneBackButton` so `performAccessibilityAudit` sees one labeled 44 pt button
/// with Large Content Viewer and circular context-menu highlight preview.
struct BrowserTabsButton: UIViewRepresentable {
    @ObservedObject var app: AppModel
    @ObservedObject private var tabs: BrowserTabs
    var isEnabled: Bool = true
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(app: AppModel, isEnabled: Bool = true, isActive: Bool = true) {
        self.app = app
        self.tabs = app.tabs
        self.isEnabled = isEnabled
        self.isActive = isActive
    }

    func makeUIView(context: Context) -> ControlView {
        let view = ControlView()
        configure(view)
        return view
    }

    func updateUIView(_ uiView: ControlView, context: Context) {
        configure(uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ControlView, context: Context) -> CGSize {
        CGSize(
            width: max(0, proposal.width ?? DCTheme.controlHeight),
            height: max(0, proposal.height ?? DCTheme.controlHeight)
        )
    }

    private func configure(_ view: ControlView) {
        let reduceMotion = reduceMotion
        let enabled = isEnabled && isActive
        view.app = app
        view.canActivate = enabled
        view.onTap = { [weak app] in
            guard let app else { return }
            DCHaptics.tap()
            app.presentTabOverview(reduceMotion: reduceMotion)
        }
        view.isHidden = !isActive
        view.isUserInteractionEnabled = isActive
        view.isAccessibilityElement = isActive
        view.accessibilityElementsHidden = !isActive
        view.iconView.tintColor = UIColor(isEnabled ? DCTheme.ink : DCTheme.inkFaint)
        let title = String(localized: "Tabs", comment: "Browser bar button opening the tab overview")
        view.accessibilityLabel = title
        view.largeContentTitle = title
        view.accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
    }

    final class ControlView: UIControl, UIGestureRecognizerDelegate, UILargeContentViewerInteractionDelegate {
        let iconView = UIImageView()
        weak var app: AppModel?
        var canActivate = true
        var onTap: (() -> Void)?
        private var isTapCandidate = false
        private var didTriggerForActiveTouch = false
        private var isShowingLargeContent = false
        private var storedAccessibilityIdentifier: String? = "browserTabsButton"

        override var accessibilityIdentifier: String? {
            get { storedAccessibilityIdentifier ?? "browserTabsButton" }
            set {
                if let newValue, !newValue.isEmpty {
                    storedAccessibilityIdentifier = newValue
                }
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = true
            isAccessibilityElement = true
            accessibilityIdentifier = "browserTabsButton"

            showsLargeContentViewer = true
            scalesLargeContentImage = true
            largeContentImage = UIImage(systemName: "square.on.square")
            let lcvInteraction = UILargeContentViewerInteraction(delegate: self)
            addInteraction(lcvInteraction)
            lcvInteraction.gestureRecognizerForExclusionRelationship.addTarget(
                self,
                action: #selector(handleLargeContentGesture(_:))
            )

            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            iconView.image = UIImage(systemName: "square.on.square", withConfiguration: symbolConfig)
            iconView.contentMode = .center
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.isUserInteractionEnabled = false
            iconView.isAccessibilityElement = false
            addSubview(iconView)

            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tapRecognizer.cancelsTouchesInView = false
            tapRecognizer.delaysTouchesBegan = false
            tapRecognizer.delaysTouchesEnded = false
            tapRecognizer.delegate = self
            tapRecognizer.require(toFail: lcvInteraction.gestureRecognizerForExclusionRelationship)
            addGestureRecognizer(tapRecognizer)

            let menuInteraction = UIContextMenuInteraction(delegate: self)
            addInteraction(menuInteraction)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func handleLargeContentGesture(_ recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                isShowingLargeContent = true
                isTapCandidate = false
                didTriggerForActiveTouch = true
            case .ended, .cancelled, .failed:
                isShowingLargeContent = false
            default:
                break
            }
        }

        func largeContentViewerInteraction(
            _ interaction: UILargeContentViewerInteraction,
            didEndOn item: (any UILargeContentViewerItem)?,
            at point: CGPoint
        ) {
            isShowingLargeContent = false
            if item as AnyObject === self, bounds.contains(point), canActivate {
                onTap?()
            }
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !didTriggerForActiveTouch, !isShowingLargeContent else { return }
            didTriggerForActiveTouch = true
            isTapCandidate = false
            if canActivate { onTap?() }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            isTapCandidate = touches.count == 1
            didTriggerForActiveTouch = false
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            guard isTapCandidate, let touch = touches.first else { return }
            if !bounds.insetBy(dx: -16, dy: -16).contains(touch.location(in: self)) {
                isTapCandidate = false
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            isTapCandidate = false
            super.touchesCancelled(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            let shouldTrigger = !didTriggerForActiveTouch
                && isTapCandidate
                && canActivate
                && (touches.first.map { bounds.insetBy(dx: -16, dy: -16).contains($0.location(in: self)) } ?? false)
            isTapCandidate = false
            super.touchesEnded(touches, with: event)
            if shouldTrigger {
                didTriggerForActiveTouch = true
                onTap?()
            }
        }

        override func accessibilityActivate() -> Bool {
            guard canActivate else { return false }
            onTap?()
            return true
        }

        override func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard !UILargeContentViewerInteraction.isEnabled else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let app = self?.app else { return UIMenu(children: []) }
                return UIMenu(children: BrowserTabsButton.buildMenuElements(for: app))
            }
        }

        override func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configuration: UIContextMenuConfiguration,
            highlightPreviewForItemWithIdentifier identifier: any NSCopying
        ) -> UITargetedPreview? {
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return nil }
            let params = UIPreviewParameters()
            params.backgroundColor = .clear
            params.visiblePath = UIBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
            return UITargetedPreview(view: self, parameters: params)
        }

        override func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willDisplayMenuFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            isTapCandidate = false
            didTriggerForActiveTouch = true
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        }
    }

    static func menuSubtitle(for tab: BrowserTab, isWorking: Bool) -> String? {
        let host = tab.showsHome ? "" : BrowserAddress.host(tab.url)
        var subtitleParts: [String] = []
        if !host.isEmpty, host.caseInsensitiveCompare(tab.title) != .orderedSame {
            subtitleParts.append(host)
        }
        if isWorking {
            subtitleParts.append(
                String(
                    localized: "Agent working",
                    comment: "VoiceOver segment and badge on a tab card while its Agent is working"
                )
            )
        }
        return subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · ")
    }

    @MainActor
    static func buildMenuElements(for app: AppModel) -> [UIMenuElement] {
        let tabs = app.tabs
        let canOpen = tabs.canOpenTab

        let newTabAction = UIAction(
            title: String(localized: "New Tab", comment: "Tabs button long-press menu action to open a new tab"),
            subtitle: canOpen ? nil : BrowserTabs.personTabLimitMessage,
            image: UIImage(systemName: "plus"),
            attributes: canOpen ? [] : [.disabled]
        ) { [weak app] _ in
            guard let app else { return }
            DCHaptics.tap()
            _ = app.openNewTabFromUI()
        }

        let closeTabAction = UIAction(
            title: String(localized: "Close This Tab", comment: "Tabs button long-press menu action to close the current tab"),
            image: UIImage(systemName: "xmark"),
            attributes: .destructive
        ) { [weak app] _ in
            guard let app else { return }
            DCHaptics.tap()
            _ = app.closeTabWithUndo(id: app.tabs.currentTabID)
        }

        let topSection = UIMenu(title: "", options: .displayInline, children: [newTabAction, closeTabAction])

        let tabItems: [UIMenuElement] = tabs.tabs.map { tab in
            let subtitle = menuSubtitle(for: tab, isWorking: tabs.runningTabIDs.contains(tab.id))
            return UIAction(
                title: tab.title,
                subtitle: subtitle,
                image: UIImage(systemName: tab.showsHome ? "square.grid.2x2" : "globe"),
                state: tabs.isCurrent(tab) ? .on : .off
            ) { [weak app, tabID = tab.id] _ in
                guard let app else { return }
                DCHaptics.selection()
                app.switchToTabFromUI(id: tabID)
            }
        }
        let openTabsSection = UIMenu(title: "", options: .displayInline, children: tabItems)
        return [topSection, openTabsSection]
    }
}

// MARK: - Tab Overview Screen (iPhone & iPad)

struct TabOverviewView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var tabs: BrowserTabs
    let containerWidth: CGFloat
    let safeAreaBottom: CGFloat

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var draggingTabID: String?
    @State private var lastDropTargetID: String?

    private var isPadOverview: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && containerWidth >= 680
    }

    private var isLandscapePhone: Bool {
        !isPadOverview && verticalSizeClass == .compact
    }

    private var columnCount: Int {
        TabOverviewTransitionMetrics.columnCount(
            isPadOverview: isPadOverview,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    private var gridColumns: [GridItem] {
        let spacing: CGFloat = isPadOverview ? (containerWidth < 900 ? 16 : 24) : 14
        return Array(
            repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: spacing, alignment: .top),
            count: columnCount
        )
    }

    private var horizontalGridPadding: CGFloat {
        if isPadOverview {
            return containerWidth < 900 ? 24 : 40
        }
        return 16
    }

    private var gridRowSpacing: CGFloat {
        isPadOverview ? 24 : 14
    }

    private var cardPreviewHeight: CGFloat {
        isPadOverview ? 220 : 214
    }

    var body: some View {
        ZStack {
            DCTheme.pageBackground
                .ignoresSafeArea()

            if isPadOverview {
                padBody
            } else {
                phoneBody
            }

            #if DEBUG
            if AssistantDebug.has("-dc-tab-ax-debug") {
                TabAccessibilityDebugOverlay(tabs: tabs)
                    .zIndex(10)
            }
            #endif
        }
    }

    private var padBody: some View {
        VStack(spacing: 0) {
            overviewBar(height: 52)
                .padding(.horizontal, 12)
                .padding(.top, 4)

            if !tabs.canOpenTab {
                limitBanner
                    .padding(.top, 10)
                    .padding(.horizontal, 24)
            }

            cardsScrollView(topPadding: 24, bottomPadding: 40)
        }
        .overlay(alignment: .bottom) {
            if let toast = app.tabClosedToast {
                TabClosedUndoToast(
                    message: toast.message,
                    onUndo: {
                        DCHaptics.tap()
                        _ = app.undoCloseTab()
                    }
                )
                .frame(maxWidth: 460)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .transition(DCMotion.slide(.bottom, reduceMotion: reduceMotion))
            }
        }
        .animation(DCMotion.respecting(reduceMotion, DCMotion.spring), value: app.tabClosedToast?.id)
    }

    private var phoneBody: some View {
        let bottomClearance = max(8, safeAreaBottom - 4)
        let barHeight: CGFloat = isLandscapePhone ? 48 : 56
        return cardsScrollView(
            topPadding: 12,
            bottomPadding: barHeight + bottomClearance + (app.tabClosedToast != nil || !tabs.canOpenTab ? 84 : 24)
        )
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if let toast = app.tabClosedToast {
                    TabClosedUndoToast(
                        message: toast.message,
                        onUndo: {
                            DCHaptics.tap()
                            _ = app.undoCloseTab()
                        }
                    )
                    .padding(.horizontal, 16)
                    .transition(DCMotion.slide(.bottom, reduceMotion: reduceMotion))
                } else if !tabs.canOpenTab {
                    limitBanner
                        .padding(.horizontal, 16)
                }

                overviewBar(height: barHeight)
                    .frame(maxWidth: isLandscapePhone ? 520 : .infinity)
                    .padding(.horizontal, 16)
            }
            .padding(.bottom, bottomClearance)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .animation(DCMotion.respecting(reduceMotion, DCMotion.spring), value: app.tabClosedToast?.id)
    }

    private func cardsScrollView(topPadding: CGFloat, bottomPadding: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gridRowSpacing) {
                    ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabOverviewCard(
                            app: app,
                            tab: tab,
                            browser: tab.browser,
                            isCurrent: tabs.isCurrent(tab),
                            isAgentWorking: tabs.runningTabIDs.contains(tab.id),
                            index: index,
                            totalCount: tabs.tabs.count,
                            previewHeight: cardPreviewHeight,
                            reduceTransparency: reduceTransparency,
                            increasedContrast: colorSchemeContrast == .increased,
                            draggingTabID: $draggingTabID,
                            lastDropTargetID: $lastDropTargetID,
                            onSelect: {
                                DCHaptics.tap()
                                app.selectTabFromOverview(id: tab.id, reduceMotion: reduceMotion)
                            },
                            onClose: {
                                DCHaptics.tap()
                                withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) {
                                    _ = app.closeTabWithUndo(id: tab.id)
                                }
                            },
                            onMoveEarlier: {
                                DCHaptics.selection()
                                withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) {
                                    _ = tabs.moveTabEarlier(id: tab.id)
                                }
                            },
                            onMoveLater: {
                                DCHaptics.selection()
                                withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) {
                                    _ = tabs.moveTabLater(id: tab.id)
                                }
                            },
                            onDropReorder: { sourceID in
                                guard sourceID != tab.id,
                                      lastDropTargetID != tab.id,
                                      let targetIndex = tabs.index(of: tab.id) else { return }
                                lastDropTargetID = tab.id
                                DCHaptics.selection()
                                withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) {
                                    _ = tabs.moveTab(id: sourceID, to: targetIndex)
                                }
                            }
                        )
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, horizontalGridPadding)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
            }
            .accessibilityIdentifier("tabOverview")
            .onAppear {
                let activeID = tabs.currentTabID
                DispatchQueue.main.async {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }
        }
    }

    private func overviewBar(height: CGFloat) -> some View {
        let count = tabs.tabs.count
        return HStack(spacing: 8) {
            Button {
                DCHaptics.tap()
                _ = app.openNewTabFromUI(reduceMotion: reduceMotion)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tabs.canOpenTab ? DCTheme.ink : DCTheme.inkFaint)
                    .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!tabs.canOpenTab)
            .accessibilityLabel(Text("New tab", comment: "Tab overview bar button that opens a new tab on Home"))
            .accessibilityShowsLargeContentViewer {
                Label {
                    Text("New tab", comment: "Tab overview bar button that opens a new tab on Home")
                } icon: {
                    Image(systemName: "plus")
                }
            }
            .accessibilityIdentifier("tabOverviewNewTab")

            Spacer(minLength: 4)

            Text("\(count) tabs", comment: "Tab overview bar count of open tabs")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(DCTheme.ink)
                .lineLimit(1)
                .accessibilityShowsLargeContentViewer()
                .accessibilityIdentifier("tabOverviewCount")

            Spacer(minLength: 4)

            Button {
                DCHaptics.tap()
                app.dismissTabOverview(reduceMotion: reduceMotion)
            } label: {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DCTheme.goldInk)
                    .padding(.horizontal, 14)
                    .frame(minHeight: DCTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityShowsLargeContentViewer()
            .accessibilityIdentifier("tabOverviewDone")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 6)
        .frame(height: height)
        .modifier(
            TabGlassCapsuleSurface(
                reduceTransparency: reduceTransparency,
                increasedContrast: colorSchemeContrast == .increased
            )
        )
        .accessibilityElement(children: .contain)
    }

    private var limitBanner: some View {
        Text(BrowserTabs.personTabLimitMessage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(DCTheme.inkMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                DCTheme.surfaceRaised,
                in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
                    .strokeBorder(DCTheme.hairline, lineWidth: DCTheme.hairlineWidth)
            }
            .accessibilityIdentifier("tabOverviewLimitNotice")
    }
}

// MARK: - Single Tab Card

private struct TabOverviewCard: View {
    let app: AppModel
    @ObservedObject var tab: BrowserTab
    @ObservedObject var browser: ForumBrowserModel
    let isCurrent: Bool
    let isAgentWorking: Bool
    let index: Int
    let totalCount: Int
    let previewHeight: CGFloat
    let reduceTransparency: Bool
    let increasedContrast: Bool
    @Binding var draggingTabID: String?
    @Binding var lastDropTargetID: String?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void
    let onDropReorder: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swipeOffsetX: CGFloat = 0

    private static let webPreviewPaper = Color(light: 0xFBFAF7, dark: 0x121212)

    private var titleText: String {
        tab.title
    }

    private var hostText: String? {
        guard !tab.showsHome else { return nil }
        let host = BrowserAddress.host(tab.url)
        return host.isEmpty ? nil : host
    }

    private var voiceOverLabel: String {
        TabOverviewTransitionMetrics.cardAccessibilityLabel(
            title: titleText,
            host: hostText,
            isHome: tab.showsHome,
            isCurrent: isCurrent,
            isAgentWorking: isAgentWorking
        )
    }

    private var swipeOpacity: Double {
        let travel = Double(abs(swipeOffsetX))
        return max(0.25, 1.0 - travel / 220.0)
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous)

        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if tab.showsHome {
                        TabMiniHomePreview()
                    } else if let snapshot = tab.snapshot {
                        GeometryReader { proxy in
                            Image(uiImage: snapshot)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                                .clipped()
                        }
                    } else {
                        TabMiniWebPlaceholder(title: titleText)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: previewHeight)
                .background(tab.showsHome ? DCTheme.pageBackground : Self.webPreviewPaper)
                .clipShape(cardShape)

                if isAgentWorking {
                    agentWorkingChip
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(8)
                        .allowsHitTesting(false)
                }

                closeDiscVisual
                    .allowsHitTesting(false)
            }
            .frame(height: previewHeight)
            .overlay {
                cardShape.strokeBorder(
                    isCurrent ? DCTheme.ink : DCTheme.hairline,
                    lineWidth: isCurrent ? 3 : DCTheme.hairlineWidth
                )
                .allowsHitTesting(false)
            }
            .accessibilityHidden(true)

            HStack(alignment: .center, spacing: 6) {
                TabCardSiteBadge(app: app, tab: tab)
                Text(titleText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DCTheme.ink)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 2)
        }
        .accessibilityHidden(true)
        .overlay {
            TabCardTouchLayer(
                tabID: tab.id,
                voiceOverLabel: voiceOverLabel,
                index: index,
                totalCount: totalCount,
                closeHitSize: CGSize(width: DCTheme.controlHeight, height: DCTheme.controlHeight),
                reduceMotion: reduceMotion,
                draggingTabID: $draggingTabID,
                lastDropTargetID: $lastDropTargetID,
                onTapCard: onSelect,
                onTapClose: onClose,
                onMoveEarlier: onMoveEarlier,
                onMoveLater: onMoveLater,
                onSwipeOffsetChanged: { dx in
                    swipeOffsetX = dx
                },
                onSwipeCommitClose: { directionSign in
                    if reduceMotion {
                        swipeOffsetX = 0
                        onClose()
                    } else {
                        withAnimation(.easeOut(duration: 0.16)) {
                            swipeOffsetX = directionSign * 260
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                            swipeOffsetX = 0
                            onClose()
                        }
                    }
                },
                onSwipeCancel: {
                    withAnimation(DCMotion.respecting(reduceMotion, DCMotion.smooth)) {
                        swipeOffsetX = 0
                    }
                },
                onDropReorder: onDropReorder
            )
        }
        .offset(x: swipeOffsetX)
        .opacity(draggingTabID == tab.id ? 0.55 : swipeOpacity)
    }

    private var closeDiscVisual: some View {
        let discFill: Color = if reduceTransparency || increasedContrast {
            DCTheme.ink
        } else if colorScheme == .dark {
            Color(hex: 0xF4EEE2, opacity: 0.30)
        } else {
            Color(hex: 0x14110E, opacity: 0.55)
        }
        let glyphColor: Color = (reduceTransparency || increasedContrast) ? DCTheme.ground : .white

        return ZStack {
            Circle()
                .fill(discFill)
                .frame(width: 24, height: 24)
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(glyphColor)
        }
        .frame(width: DCTheme.controlHeight, height: DCTheme.controlHeight)
        .accessibilityHidden(true)
    }

    private var agentWorkingChip: some View {
        let chipShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(spacing: 6) {
            DCAgentRing(size: 16, lineWidth: 2.5, isTurning: true, isEnabled: true)
            Text("Agent working", comment: "VoiceOver segment and badge on a tab card while its Agent is working")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DCTheme.goldInk)
                .lineLimit(1)
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background {
            if reduceTransparency || increasedContrast {
                chipShape.fill(DCTheme.surface)
            } else {
                chipShape.fill(.ultraThinMaterial)
            }
        }
        .overlay {
            chipShape.strokeBorder(
                (reduceTransparency || increasedContrast) ? DCTheme.borderStrong : DCTheme.hairline,
                lineWidth: DCTheme.hairlineWidth
            )
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Unified Card Touch Layer (Tap, Close Tap, Horizontal Swipe, Long-Press Drag Reorder)

private struct TabCardTouchLayer: UIViewRepresentable {
    let tabID: String
    let voiceOverLabel: String
    let index: Int
    let totalCount: Int
    let closeHitSize: CGSize
    let reduceMotion: Bool
    @Binding var draggingTabID: String?
    @Binding var lastDropTargetID: String?
    let onTapCard: () -> Void
    let onTapClose: () -> Void
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void
    let onSwipeOffsetChanged: (CGFloat) -> Void
    let onSwipeCommitClose: (CGFloat) -> Void
    let onSwipeCancel: () -> Void
    let onDropReorder: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        let dragInteraction = UIDragInteraction(delegate: context.coordinator)
        dragInteraction.isEnabled = true
        view.addInteraction(dragInteraction)

        let dropInteraction = UIDropInteraction(delegate: context.coordinator)
        view.addInteraction(dropInteraction)

        configureAccessibility(on: view)
        return view
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        context.coordinator.parent = self
        configureAccessibility(on: uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TouchView, context: Context) -> CGSize {
        CGSize(width: max(0, proposal.width ?? 0), height: max(0, proposal.height ?? 0))
    }

    private func configureAccessibility(on view: TouchView) {
        view.cardTabID = tabID
        view.accessibilityIdentifier = "tabOverviewCard-\(tabID)"
        view.accessibilityLabel = voiceOverLabel
        view.onActivate = onTapCard

        let closeAction = UIAccessibilityCustomAction(
            name: String(localized: "Close", comment: "VoiceOver custom action on a tab card to close the tab")
        ) { [onTapClose] _ in
            onTapClose()
            return true
        }
        var customActions: [UIAccessibilityCustomAction] = [closeAction]
        if index > 0 {
            customActions.append(
                UIAccessibilityCustomAction(
                    name: String(localized: "Move earlier", comment: "VoiceOver custom action on a tab card to move it one position earlier")
                ) { [onMoveEarlier] _ in
                    onMoveEarlier()
                    return true
                }
            )
        }
        if index < totalCount - 1 {
            customActions.append(
                UIAccessibilityCustomAction(
                    name: String(localized: "Move later", comment: "VoiceOver custom action on a tab card to move it one position later")
                ) { [onMoveLater] _ in
                    onMoveLater()
                    return true
                }
            )
        }
        view.accessibilityCustomActions = customActions
    }

    final class TouchView: UIView {
        var cardTabID: String = ""
        private var storedAccessibilityIdentifier: String?
        var onActivate: (() -> Void)?

        override var isAccessibilityElement: Bool {
            get { true }
            set {}
        }

        override var accessibilityIdentifier: String? {
            get { storedAccessibilityIdentifier ?? (cardTabID.isEmpty ? nil : "tabOverviewCard-\(cardTabID)") }
            set {
                if let newValue, !newValue.isEmpty {
                    storedAccessibilityIdentifier = newValue
                }
            }
        }

        override func accessibilityActivate() -> Bool {
            onActivate?()
            return true
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIDragInteractionDelegate, UIDropInteractionDelegate {
        var parent: TabCardTouchLayer

        init(_ parent: TabCardTouchLayer) {
            self.parent = parent
        }

        private func closeRect(in view: UIView) -> CGRect {
            let isRTL = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let x = isRTL ? 0 : max(0, view.bounds.width - parent.closeHitSize.width)
            return CGRect(x: x, y: 0, width: parent.closeHitSize.width, height: parent.closeHitSize.height)
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            if closeRect(in: view).contains(point) {
                parent.onTapClose()
            } else {
                parent.onTapCard()
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else {
                return true
            }
            if parent.draggingTabID != nil {
                return false
            }
            let velocity = pan.velocity(in: view)
            return abs(velocity.x) > abs(velocity.y) * 1.15
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let dx = recognizer.translation(in: view).x
            let vx = recognizer.velocity(in: view).x
            switch recognizer.state {
            case .began, .changed:
                parent.onSwipeOffsetChanged(dx)
            case .ended:
                let threshold = max(68, view.bounds.width * 0.30)
                if abs(dx) >= threshold || abs(vx) >= 450 {
                    let sign: CGFloat = (abs(dx) >= 8 ? dx : vx) >= 0 ? 1 : -1
                    parent.onSwipeCommitClose(sign)
                } else {
                    parent.onSwipeCancel()
                }
            case .cancelled, .failed:
                parent.onSwipeCancel()
            default:
                break
            }
        }

        // MARK: UIDragInteractionDelegate

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
            let id = parent.tabID
            parent.draggingTabID = id
            parent.lastDropTargetID = nil
            let provider = NSItemProvider(object: id as NSString)
            let item = UIDragItem(itemProvider: provider)
            item.localObject = id
            return [item]
        }

        func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession) -> UITargetedDragPreview? {
            guard let sourceView = interaction.view?.superview ?? interaction.view else { return nil }
            let params = UIDragPreviewParameters()
            params.visiblePath = UIBezierPath(roundedRect: sourceView.bounds, cornerRadius: DCTheme.radiusLg)
            params.backgroundColor = .clear
            return UITargetedDragPreview(view: sourceView, parameters: params)
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
            DCHaptics.selection()
            parent.draggingTabID = parent.tabID
        }

        func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
            if parent.draggingTabID == parent.tabID {
                parent.draggingTabID = nil
                parent.lastDropTargetID = nil
            }
        }

        // MARK: UIDropInteractionDelegate

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
            session.localDragSession != nil || session.canLoadObjects(ofClass: NSString.self)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) {
            guard let sourceID = session.localDragSession?.items.first?.localObject as? String else { return }
            if sourceID == parent.tabID {
                parent.lastDropTargetID = nil
            } else {
                parent.onDropReorder(sourceID)
            }
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
            if let sourceID = session.localDragSession?.items.first?.localObject as? String {
                if sourceID == parent.tabID {
                    parent.lastDropTargetID = nil
                } else {
                    parent.onDropReorder(sourceID)
                }
            }
            return UIDropProposal(operation: .move)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
            if let sourceID = session.localDragSession?.items.first?.localObject as? String,
               sourceID != parent.tabID {
                parent.onDropReorder(sourceID)
            }
            parent.draggingTabID = nil
            parent.lastDropTargetID = nil
        }
    }
}

// MARK: - Card Site Icon & Mini Previews

private struct TabCardSiteBadge: View {
    let app: AppModel
    let tab: BrowserTab

    var body: some View {
        if tab.showsHome {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(DCTheme.inkMuted)
                Text(verbatim: "H")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
        } else if let siteURL = tab.browser.pageContext.siteURL,
                  let forum = app.forum(for: siteURL) {
            ForumIcon(forum: forum, size: 16)
        } else {
            let host = BrowserAddress.host(tab.url)
            let origin = tab.url.flatMap { AppModel.origin(ofPage: $0.absoluteString) } ?? host
            let displayName = host.isEmpty ? tab.title : host
            ForumIcon(siteURL: origin.isEmpty ? tab.id : origin, name: displayName, iconURL: nil, size: 16)
        }
    }
}

private struct TabMiniHomePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Home")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(DCTheme.ink)
                .padding(.trailing, 30)

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(DCTheme.surface)
                .frame(height: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(DCTheme.hairline, lineWidth: DCTheme.hairlineWidth)
                }

            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DCTheme.surface)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(DCTheme.hairline, lineWidth: DCTheme.hairlineWidth)
                        }
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

private struct TabMiniWebPlaceholder: View {
    let title: String

    private static let lineColor = Color(light: 0xDDD6CC, dark: 0x2E2B27)
    private static let blockColor = Color(light: 0xDCD3C4, dark: 0x2E2A24)
    private static let textColor = Color(light: 0x1E1E1E, dark: 0xE8E6E1)

    var body: some View {
        GeometryReader { proxy in
            let innerWidth = max(40, proxy.size.width - 20)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .serif))
                    .foregroundStyle(Self.textColor)
                    .lineLimit(2)
                    .padding(.trailing, 30)

                Capsule()
                    .fill(Self.lineColor)
                    .frame(width: innerWidth * 0.80, height: 6)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Self.blockColor)
                    .frame(height: 44)

                Capsule()
                    .fill(Self.lineColor)
                    .frame(height: 6)
                Capsule()
                    .fill(Self.lineColor)
                    .frame(width: innerWidth * 0.90, height: 6)
                Capsule()
                    .fill(Self.lineColor)
                    .frame(width: innerWidth * 0.70, height: 6)

                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Closed Tab Undo Toast (`PhoneTabs.dc.html` Frame 3)

struct TabClosedUndoToast: View {
    let message: String
    let onUndo: () -> Void

    private static let undoGold = Color(light: 0xE8BD55, dark: 0x8A6200)

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(DCTheme.ground)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("tabClosedToast")

            Button(action: onUndo) {
                Text("Undo", comment: "Undo button on the toast shown after closing a browser tab")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Self.undoGold)
                    .padding(.horizontal, 12)
                    .frame(minHeight: DCTheme.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tabClosedUndoButton")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(minHeight: 52)
        .background(
            DCTheme.ink,
            in: RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous)
        )
        .dcShadowPop()
    }
}

// MARK: - Glass Capsule Surface

struct TabGlassCapsuleSurface: ViewModifier {
    let reduceTransparency: Bool
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        if reduceTransparency || increasedContrast {
            content
                .background(DCTheme.surface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(DCTheme.borderStrong, lineWidth: 1)
                }
        } else if #available(iOS 26.0, *) {
            content
                .background {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular, in: .capsule)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        } else {
            content
                .background(.bar, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: DCTheme.hairlineWidth)
                }
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        }
    }
}

// MARK: - Hardware Keyboard Shortcuts Responder (⌘T, ⌘W, ⌃Tab, ⌃⇧Tab)

enum TabCycleShortcutGate {
    @MainActor private static var lastFireAt: ContinuousClock.Instant?

    @MainActor static func postOncePerKeystroke(_ command: WorkspaceCommand) {
        let now = ContinuousClock.now
        if let lastFireAt, now - lastFireAt <= .milliseconds(40) { return }
        lastFireAt = now
        command.post()
    }
}

private extension UIResponder {
    @objc func dcHandleNextTabKeyCommand(_ sender: Any?) {
        MainActor.assumeIsolated {
            TabCycleShortcutGate.postOncePerKeystroke(.nextTab)
        }
    }

    @objc func dcHandlePreviousTabKeyCommand(_ sender: Any?) {
        MainActor.assumeIsolated {
            TabCycleShortcutGate.postOncePerKeystroke(.previousTab)
        }
    }
}

/// Installs priority `UIKeyCommand`s on the window's root view controller so `⌃Tab` and `⌃⇧Tab`
/// cycle tabs reliably on iPad even when `WKWebView` or UIKit focus navigation is active.
struct TabKeyCommandResponder: UIViewRepresentable {
    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        uiView.installIfNeeded()
    }

    final class AnchorView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            installIfNeeded()
        }

        func installIfNeeded() {
            guard let rootVC = window?.rootViewController else { return }
            let nextAction = #selector(UIResponder.dcHandleNextTabKeyCommand(_:))
            let alreadyInstalled = rootVC.keyCommands?.contains(where: { $0.action == nextAction }) == true
            guard !alreadyInstalled else { return }

            let nextTab = UIKeyCommand(
                input: "\t",
                modifierFlags: .control,
                action: nextAction
            )
            nextTab.discoverabilityTitle = String(localized: "Show Next Tab", comment: "Keyboard shortcut command to switch to the next open tab")
            nextTab.wantsPriorityOverSystemBehavior = true

            let prevTab = UIKeyCommand(
                input: "\t",
                modifierFlags: [.control, .shift],
                action: #selector(UIResponder.dcHandlePreviousTabKeyCommand(_:))
            )
            prevTab.discoverabilityTitle = String(localized: "Show Previous Tab", comment: "Keyboard shortcut command to switch to the previous open tab")
            prevTab.wantsPriorityOverSystemBehavior = true

            rootVC.addKeyCommand(nextTab)
            rootVC.addKeyCommand(prevTab)
        }
    }
}

// MARK: - UIKit Accessibility Tree Walker (Used by Unit Tests & Optional `-dc-tab-ax-debug` UI Test Hook)

@MainActor
enum TabCardAccessibilityInspector {
    /// Finds the live UIAccessibility element in `root` matching `identifier` by walking
    /// both `accessibilityElements` containers and `UIView` subview hierarchies.
    static func findElement(withIdentifier identifier: String, in root: Any) -> NSObject? {
        guard let object = root as? NSObject else { return nil }
        if let touchView = object as? TabCardTouchLayer.TouchView,
           "tabOverviewCard-\(touchView.cardTabID)" == identifier {
            return touchView
        }
        if let ident = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier,
           ident == identifier,
           object.isAccessibilityElement {
            return object
        }
        if let view = object as? UIView {
            for subview in view.subviews {
                if let match = findElement(withIdentifier: identifier, in: subview) {
                    return match
                }
            }
        }
        if let elements = object.accessibilityElements {
            for child in elements {
                if let match = findElement(withIdentifier: identifier, in: child) {
                    return match
                }
            }
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for idx in 0..<count {
                if let child = object.accessibilityElement(at: idx),
                   let match = findElement(withIdentifier: identifier, in: child) {
                    return match
                }
            }
        }
        return nil
    }

    static func customActionNames(forCardID tabID: String, in root: Any) -> [String] {
        guard let element = findElement(withIdentifier: "tabOverviewCard-\(tabID)", in: root) else {
            return []
        }
        return (element.accessibilityCustomActions ?? []).map(\.name)
    }

    @discardableResult
    static func invokeCustomAction(named actionName: String, forCardID tabID: String, in root: Any) -> Bool {
        guard let element = findElement(withIdentifier: "tabOverviewCard-\(tabID)", in: root),
              let action = element.accessibilityCustomActions?.first(where: { $0.name == actionName }) else {
            return false
        }
        if let handler = action.actionHandler {
            return handler(action)
        }
        if let target = action.target {
            _ = target.perform(action.selector, with: action)
            return true
        }
        return false
    }
}

#if DEBUG
private struct TabAccessibilityDebugOverlay: View {
    @ObservedObject var tabs: BrowserTabs

    private static func invoke(_ actionName: String, for tabID: String) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows where !window.isHidden {
            if TabCardAccessibilityInspector.invokeCustomAction(named: actionName, forCardID: tabID, in: window) {
                return
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tabs.tabs) { tab in
                HStack(spacing: 8) {
                    Button {
                        Self.invoke(String(localized: "Close", comment: "VoiceOver custom action on a tab card to close the tab"), for: tab.id)
                    } label: {
                        Text(verbatim: "\(tab.id)-X")
                            .font(.caption2.monospaced())
                            .frame(width: 52, height: 44)
                            .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tabAXInvoke-\(tab.id)-close")

                    Button {
                        Self.invoke(String(localized: "Move earlier", comment: "VoiceOver custom action on a tab card to move it one position earlier"), for: tab.id)
                    } label: {
                        Text(verbatim: "\(tab.id)-<")
                            .font(.caption2.monospaced())
                            .frame(width: 52, height: 44)
                            .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tabAXInvoke-\(tab.id)-earlier")

                    Button {
                        Self.invoke(String(localized: "Move later", comment: "VoiceOver custom action on a tab card to move it one position later"), for: tab.id)
                    } label: {
                        Text(verbatim: "\(tab.id)->")
                            .font(.caption2.monospaced())
                            .frame(width: 52, height: 44)
                            .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tabAXInvoke-\(tab.id)-later")
                }
            }
        }
        .padding(.leading, 16)
        .padding(.top, 68)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
