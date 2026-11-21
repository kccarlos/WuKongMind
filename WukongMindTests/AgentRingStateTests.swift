import SwiftUI
import UIKit
import XCTest
@testable import WukongMind

/// Unit tests for `AgentRingState` mapping, Reduce Motion / panel visibility motion rules,
/// `BrowserAgentSession.seenRunID` lifecycle, and light/dark visual snapshots of all six states
/// (`docs/wukongmind/design-motion.md` §2, task 2).
@MainActor
final class AgentRingStateTests: XCTestCase {
    // MARK: - Mapping table

    func testStateMappingTable() {
        let runA = UUID()
        let runB = UUID()

        struct Case {
            let name: String
            let isAvailable: Bool
            let pendingConfirmation: Bool
            let runState: BrowserAgentRunState
            let lastRunID: UUID?
            let seenRunID: UUID?
            let activeResearch: Bool
            let readyAnswer: Bool
            let expected: AgentRingState
        }

        let cases: [Case] = [
            // Unavailable always wins when there is no page to work on
            Case(
                name: "unavailable overrides idle",
                isAvailable: false, pendingConfirmation: false,
                runState: .idle, lastRunID: nil, seenRunID: nil,
                activeResearch: false, readyAnswer: false,
                expected: .unavailable
            ),
            Case(
                name: "unavailable overrides running and pending confirmation",
                isAvailable: false, pendingConfirmation: true,
                runState: .running(step: 1, maxSteps: 10), lastRunID: runA, seenRunID: nil,
                activeResearch: true, readyAnswer: true,
                expected: .unavailable
            ),
            // Idle
            Case(
                name: "idle with no runs",
                isAvailable: true, pendingConfirmation: false,
                runState: .idle, lastRunID: nil, seenRunID: nil,
                activeResearch: false, readyAnswer: false,
                expected: .idle
            ),
            // Stopped by user returns to idle (never failed/cinnabar)
            Case(
                name: "stopped unseen returns to idle",
                isAvailable: true, pendingConfirmation: false,
                runState: .stopped(step: 2), lastRunID: runA, seenRunID: nil,
                activeResearch: false, readyAnswer: false,
                expected: .idle
            ),
            Case(
                name: "stopped seen returns to idle",
                isAvailable: true, pendingConfirmation: false,
                runState: .stopped(step: 2), lastRunID: runA, seenRunID: runA,
                activeResearch: false, readyAnswer: false,
                expected: .idle
            ),
            // Working
            Case(
                name: "running run maps to working",
                isAvailable: true, pendingConfirmation: false,
                runState: .running(step: 1, maxSteps: 12), lastRunID: runA, seenRunID: nil,
                activeResearch: false, readyAnswer: false,
                expected: .working
            ),
            Case(
                name: "active research maps to working",
                isAvailable: true, pendingConfirmation: false,
                runState: .idle, lastRunID: nil, seenRunID: nil,
                activeResearch: true, readyAnswer: false,
                expected: .working
            ),
            // Needs you overrides working (confirmations pause an active run)
            Case(
                name: "pending confirmation during running maps to needsYou",
                isAvailable: true, pendingConfirmation: true,
                runState: .running(step: 2, maxSteps: 12), lastRunID: runA, seenRunID: nil,
                activeResearch: false, readyAnswer: false,
                expected: .needsYou
            ),
            // Completed: unseen -> done, seen -> idle
            Case(
                name: "completed unseen maps to done",
                isAvailable: true, pendingConfirmation: false,
                runState: .completed(steps: 3, duration: 4.1), lastRunID: runA, seenRunID: nil,
                activeResearch: false, readyAnswer: false,
                expected: .done
            ),
            Case(
                name: "completed with older seenRunID maps to done",
                isAvailable: true, pendingConfirmation: false,
                runState: .completed(steps: 3, duration: 4.1), lastRunID: runB, seenRunID: runA,
                activeResearch: false, readyAnswer: false,
                expected: .done
            ),
            Case(
                name: "completed seen maps to idle",
                isAvailable: true, pendingConfirmation: false,
                runState: .completed(steps: 3, duration: 4.1), lastRunID: runA, seenRunID: runA,
                activeResearch: false, readyAnswer: false,
                expected: .idle
            ),
            // Failed: unseen -> failed, seen -> idle
            Case(
                name: "failed unseen maps to failed",
                isAvailable: true, pendingConfirmation: false,
                runState: .failed(message: "Timeout"), lastRunID: runA, seenRunID: nil,
                activeResearch: false, readyAnswer: false,
                expected: .failed
            ),
            Case(
                name: "failed seen maps to idle",
                isAvailable: true, pendingConfirmation: false,
                runState: .failed(message: "Timeout"), lastRunID: runA, seenRunID: runA,
                activeResearch: false, readyAnswer: false,
                expected: .idle
            ),
            // Step limit reached: unseen -> failed, seen -> idle
            Case(
                name: "stepLimitReached unseen maps to failed",
                isAvailable: true, pendingConfirmation: false,
                runState: .stepLimitReached(limit: 12), lastRunID: runA, seenRunID: nil,
                activeResearch: false, readyAnswer: false,
                expected: .failed
            ),
            Case(
                name: "stepLimitReached seen maps to idle",
                isAvailable: true, pendingConfirmation: false,
                runState: .stepLimitReached(limit: 12), lastRunID: runA, seenRunID: runA,
                activeResearch: false, readyAnswer: false,
                expected: .idle
            ),
            // Legacy DEBUG readyAnswer record maps to done
            Case(
                name: "readyAnswer maps to done",
                isAvailable: true, pendingConfirmation: false,
                runState: .idle, lastRunID: nil, seenRunID: nil,
                activeResearch: false, readyAnswer: true,
                expected: .done
            )
        ]

        for row in cases {
            let actual = AgentRingState.resolve(
                isAvailable: row.isAvailable,
                hasPendingConfirmation: row.pendingConfirmation,
                runState: row.runState,
                lastRunID: row.lastRunID,
                seenRunID: row.seenRunID,
                hasActiveResearch: row.activeResearch,
                hasReadyAnswer: row.readyAnswer
            )
            XCTAssertEqual(actual, row.expected, row.name)
        }
    }

    // MARK: - Motion and Reduce Motion

    func testMotionSelectionRespectsReduceMotionAndPanelVisibility() {
        // Working turns only when panel is hidden and Reduce Motion is off.
        XCTAssertEqual(AgentRingState.motion(for: .working, panelVisible: false, reduceMotion: false), .turning)
        XCTAssertEqual(AgentRingState.motion(for: .working, panelVisible: true, reduceMotion: false), .still)
        XCTAssertEqual(AgentRingState.motion(for: .working, panelVisible: false, reduceMotion: true), .still)
        XCTAssertEqual(AgentRingState.motion(for: .working, panelVisible: true, reduceMotion: true), .still)

        // Done runs the one-shot gap close only when panel is hidden and Reduce Motion is off.
        XCTAssertEqual(AgentRingState.motion(for: .done, panelVisible: false, reduceMotion: false), .closeGap)
        XCTAssertEqual(AgentRingState.motion(for: .done, panelVisible: true, reduceMotion: false), .still)
        XCTAssertEqual(AgentRingState.motion(for: .done, panelVisible: false, reduceMotion: true), .still)
        XCTAssertEqual(AgentRingState.motion(for: .done, panelVisible: true, reduceMotion: true), .still)

        // Idle, needsYou, failed and unavailable are always still.
        for state in [AgentRingState.idle, .needsYou, .failed, .unavailable] {
            for panelVisible in [false, true] {
                for reduceMotion in [false, true] {
                    XCTAssertEqual(
                        AgentRingState.motion(for: state, panelVisible: panelVisible, reduceMotion: reduceMotion),
                        .still,
                        "\(state) panelVisible=\(panelVisible) reduceMotion=\(reduceMotion)"
                    )
                }
            }
        }
    }

    func testAccessibilityValuesMatchSpec() {
        XCTAssertNil(AgentRingState.idle.accessibilityValue)
        XCTAssertEqual(AgentRingState.working.accessibilityValue, "Working")
        XCTAssertEqual(AgentRingState.needsYou.accessibilityValue, "Needs your answer")
        XCTAssertEqual(AgentRingState.done.accessibilityValue, "Answer ready")
        XCTAssertEqual(AgentRingState.failed.accessibilityValue, "Stopped with a problem")
        XCTAssertNil(AgentRingState.unavailable.accessibilityValue)
    }

    // MARK: - Restored conversation and seenRunID

    func testRestoredConversationIsNeverUnseen() {
        let store = PersistentStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("state.json")
        )
        let app = AppModel(store: store)
        app.suppressesPersistence = true

        let completedID = UUID()
        let savedCompleted = SavedAgentConversation(
            messages: [BrowserAgentMessage(role: .assistant, text: "Done.", runID: completedID)],
            runs: [BrowserAgentRun(
                id: completedID,
                prompt: "Check this",
                toolCalls: [],
                assistantText: "Done.",
                state: .completed(steps: 1, duration: 1.0),
                tokenUsage: .zero,
                startedAt: Date(),
                duration: 1.0
            )],
            tokenUsage: .zero,
            history: []
        )
        app.browserAgent.restoreConversation(savedCompleted)
        XCTAssertEqual(app.browserAgent.seenRunID, completedID)
        XCTAssertTrue(app.browserAgent.doneShownRunIDs.contains(completedID), "Restored run must not replay the saved-note done one-shot")
        XCTAssertEqual(app.agentRingState(isAvailable: true), .idle, "A restored completed run must not show as unseen done")

        let liveRunID = UUID()
        XCTAssertFalse(app.browserAgent.doneShownRunIDs.contains(liveRunID))
        app.browserAgent.markSavedNoteDoneShown(for: liveRunID)
        XCTAssertTrue(app.browserAgent.doneShownRunIDs.contains(liveRunID))

        app.browserAgent.resetConversation()
        XCTAssertTrue(app.browserAgent.doneShownRunIDs.isEmpty)

        let failedID = UUID()
        let savedFailed = SavedAgentConversation(
            messages: [],
            runs: [BrowserAgentRun(
                id: failedID,
                prompt: "Check this",
                toolCalls: [],
                assistantText: "",
                state: .failed(message: "Network error"),
                tokenUsage: .zero,
                startedAt: Date(),
                duration: 1.0
            )],
            tokenUsage: .zero,
            history: []
        )
        app.browserAgent.restoreConversation(savedFailed)
        XCTAssertEqual(app.browserAgent.seenRunID, failedID)
        XCTAssertEqual(app.agentRingState(isAvailable: true), .idle, "A restored failed run must not show as unseen failed")
    }

    // MARK: - Visual snapshots (all six states, light and dark)

    func testCaptureSixStatesLightAndDarkSnapshots() {
        let labels: [(AgentRingState, String)] = [
            (.idle, "idle"),
            (.working, "working (still)"),
            (.needsYou, "needsYou"),
            (.done, "done"),
            (.failed, "failed"),
            (.unavailable, "unavailable")
        ]
        for (schemeName, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let content = VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: "AgentRingState — \(schemeName)")
                    .font(DCType.headline)
                    .foregroundStyle(DCTheme.ink)
                ForEach(labels, id: \.1) { state, title in
                    HStack(spacing: 16) {
                        DCAgentRing(state: state, size: PhoneAIButton.ringSize, lineWidth: DCTheme.ringWidth, panelVisible: true)
                            .frame(width: 44, height: 44)
                        DCAgentRing(state: state, size: 16, lineWidth: 2.5, panelVisible: true)
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: title)
                                .font(DCType.subheadline.weight(.semibold))
                                .foregroundStyle(DCTheme.ink)
                            Text(verbatim: state.accessibilityValue ?? "(none)")
                                .font(DCType.footnote)
                                .foregroundStyle(DCTheme.inkMuted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
                            .strokeBorder(DCTheme.hairline, lineWidth: DCTheme.hairlineWidth)
                    }
                }
            }
            .padding(20)
            .frame(width: 390, alignment: .leading)
            .background(DCTheme.ground)
            .environment(\.colorScheme, scheme)

            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
            let host = UIHostingController(rootView: content)
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = host
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            let fitted = host.sizeThatFits(in: CGSize(width: 390, height: 1200))
            window.frame = CGRect(x: 0, y: 0, width: 390, height: ceil(fitted.height))
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))

            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { ctx in
                host.view.layer.render(in: ctx.cgContext)
            }
            XCTAssertGreaterThan(image.size.width, 300)
            let attachment = XCTAttachment(image: image)
            attachment.name = "agent-ring-states-\(schemeName)"
            attachment.lifetime = .keepAlways
            add(attachment)

            window.isHidden = true
            window.rootViewController = nil
        }
    }
}
