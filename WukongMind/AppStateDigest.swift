import Combine
import Foundation
import SwiftUI

/// Five one-word state slices (`drawer`, `summary`, `run`, `page`, `voice`) built
/// from the app's explicit state machines (`design-performance-and-state.md` §3).
struct AppStateDigest: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    var drawer: String
    var summary: String
    var run: String
    var page: String
    var voice: String

    var description: String {
        "drawer=\(drawer) summary=\(summary) run=\(run) page=\(page) voice=\(voice)"
    }

    static func drawerWord(usesDrawer: Bool, phase: DrawerPhase, showsSplitPanel: Bool) -> String {
        guard usesDrawer else { return showsSplitPanel ? "split" : "closed" }
        return switch phase {
        case .closed: "closed"
        case .presenting: "presenting"
        case .shown: "shown"
        case .dismissing: "dismissing"
        case .recovering: "recovering"
        }
    }

    static func voiceWord(sessionState: VoiceSession.State?, startFailure: VoiceSession.Failure?) -> String {
        guard let sessionState else { return startFailure != nil ? "failed" : "idle" }
        return switch sessionState {
        case .idle: "idle"
        case .connecting: "connecting"
        case .listening: "listening"
        case .thinking: "thinking"
        case .speaking: "speaking"
        case .reconnecting: "reconnecting"
        case .ended: "ended"
        case .failed: "failed"
        }
    }
}

@MainActor
extension AppModel {
    var stateDigest: AppStateDigest { stateDigest(for: tabs.currentTab) }

    func stateDigest(for tab: BrowserTab) -> AppStateDigest {
        AppStateDigest(
            drawer: AppStateDigest.drawerWord(
                usesDrawer: router.usesDrawer, phase: router.drawerPhase, showsSplitPanel: showsSplitPanel()
            ),
            summary: summaryDigestWord(for: tab),
            run: tab.agentSession.runState.digestWord,
            page: pageDigestWord(for: tab),
            voice: AppStateDigest.voiceWord(sessionState: voice.session?.state, startFailure: voice.startFailure)
        )
    }

    /// Reads the summary word outside `SummaryPanel.swift`; design task 4 (`SummaryPresentation`) replaces it.
    func summaryDigestWord(for tab: BrowserTab) -> String {
        let topicKey = (tab === tabs.currentTab ? currentTopic : tab.browser.pageContext.topic)?.topicKey ?? ""
        let runs = tab.agentSession.runs
        if runs.contains(where: { $0.toolCalls.contains { $0.toolName == "summarize_topic" && $0.isRunning } }) {
            return "running"
        }
        if topicKey.isEmpty {
            let hasCard = runs.contains { $0.toolCalls.contains { $0.toolName == "summarize_topic" && !$0.isRunning && !$0.isError } }
            return hasCard ? "card" : "none"
        }
        let pulling = activities.contains { $0.type == .pull && $0.topicKey == topicKey && !$0.status.isTerminal }
        let jobState = SummaryRunState.resolve(activities, topicKey: topicKey)
        if pulling || jobState == .running { return "running" }
        let hasThreadCard = runs.contains { run in
            run.toolCalls.contains { row in
                guard row.toolName == "summarize_topic", !row.isRunning, !row.isError,
                      case .thread(let thread) = row.shape else { return false }
                return session(forThreadShape: thread)?.topicKey == topicKey
            }
        }
        if hasThreadCard { return "card" }
        if drawerSummaryHiddenTopicKeys.contains(topicKey) { return "hidden" }
        if case .failed = jobState { return "failed" }
        if let session = sessions[topicKey], session.hasSummary {
            return session.hasStaleSummary ? "stale" : "saved"
        }
        return "none"
    }

    func pageDigestWord(for tab: BrowserTab) -> String {
        let target = tab.browser
        #if DEBUG
        if tab === tabs.currentTab, let seededPageContext, !target.isForumsHomeRequested {
            if target.showsCrashNotice { return "crashed" }
            if !target.isWebViewLoaded { return "unloaded" }
            return (currentTopic != nil ? .topic : seededPageContext.state).rawValue
        }
        #endif
        if target.showsForumsHome { return "home" }
        if target.showsCrashNotice { return "crashed" }
        if !target.isWebViewLoaded { return "unloaded" }
        if target.isLoading { return "loading" }
        let state = tab === tabs.currentTab ? assistantPageState : (target.pageContext.topic != nil ? .topic : target.pageContext.state)
        return state.rawValue
    }
}

/// Watches the state machines only while a tab has a running Agent task, recording changes.
@MainActor
final class AppStateDigestMonitor {
    private weak var app: AppModel?
    private var runningCancellable: AnyCancellable?
    private var sliceCancellables: Set<AnyCancellable> = []
    private var voiceSessionCancellable: AnyCancellable?
    private var scheduled = false

    init(app: AppModel) {
        self.app = app
        runningCancellable = app.tabs.$runningTabIDs.removeDuplicates().sink { [weak self] ids in
            Task { @MainActor [weak self] in self?.rewire(runningIDs: ids) }
        }
    }

    private func rewire(runningIDs: Set<String>) {
        sliceCancellables.removeAll()
        voiceSessionCancellable = nil
        guard !runningIDs.isEmpty, let app else { return }
        let sources: [AnyPublisher<Void, Never>] = [
            app.objectWillChange.eraseToAnyPublisher(),
            app.router.objectWillChange.eraseToAnyPublisher(),
            app.tabs.objectWillChange.eraseToAnyPublisher(),
            app.voice.objectWillChange.eraseToAnyPublisher()
        ] + runningIDs.compactMap(app.tabs.tab(id:)).map { $0.browser.objectWillChange.eraseToAnyPublisher() }
        Publishers.MergeMany(sources).sink { [weak self] in self?.scheduleCheck() }.store(in: &sliceCancellables)
        app.voice.$session.sink { [weak self] next in
            self?.scheduleCheck()
            Task { @MainActor [weak self] in
                let active = self?.app?.voice.session ?? next
                self?.voiceSessionCancellable = active?.$state.sink { [weak self] _ in self?.scheduleCheck() }
            }
        }.store(in: &sliceCancellables)
        scheduleCheck()
    }

    private func scheduleCheck() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard let app = self.app else { return }
            for id in app.tabs.runningTabIDs {
                if let tab = app.tabs.tab(id: id) { tab.agentSession.recordStateIfChanged(app.stateDigest(for: tab)) }
            }
        }
    }
}

/// Live monospaced digest shown in Developer mode (`This page › Developer`, `Settings › Agent`).
struct AppStateDigestView: View {
    @ObservedObject var app: AppModel
    var isDebugProbe = false

    var body: some View {
        let tab = app.tabs.currentTab
        ObservedDigest(
            app: app, router: app.router, tabs: app.tabs, tab: tab,
            browser: tab.browser, voice: app.voice, agent: tab.agentSession, isDebugProbe: isDebugProbe
        )
    }

    private struct ObservedDigest: View {
        @ObservedObject var app: AppModel
        @ObservedObject var router: PresentationRouter
        @ObservedObject var tabs: BrowserTabs
        let tab: BrowserTab
        @ObservedObject var browser: ForumBrowserModel
        @ObservedObject var voice: VoiceController
        let agent: BrowserAgentSession
        let isDebugProbe: Bool
        @State private var tick = 0

        var body: some View {
            let _ = (agent.runState, tick)
            let text = app.stateDigest(for: tab).description
            Group {
                if isDebugProbe {
                    Text(verbatim: text)
                        .font(.system(size: 2))
                        .frame(width: 4, height: 4)
                        .opacity(0.02)
                        .allowsHitTesting(false)
                        .accessibilityLabel(Text(verbatim: text))
                        .accessibilityIdentifier("appStateDigest")
                } else {
                    Text(verbatim: text)
                        .font(DCType.code)
                        .foregroundStyle(DCTheme.ink)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("devAppStateDigest")
                }
            }
            .onReceive(voice.session.map { $0.$state.map { _ in () }.eraseToAnyPublisher() } ?? Empty().eraseToAnyPublisher()) {
                tick &+= 1
            }
        }
    }
}

#if DEBUG
struct AppStateDigestDebugView: View {
    @ObservedObject var app: AppModel
    var body: some View { AppStateDigestView(app: app, isDebugProbe: true) }
}
#endif
