import Foundation
import Observation
import SwiftUI

// Confirmations (design-m3.md, "Confirmations"): the run pauses on a card under
// the pending ToolRow until the person taps Allow or Don't allow. Stop cancels
// the card.

/// One question waiting for an answer.
struct AgentConfirmation: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The tool asking, for the audit log.
    var tool: String
    /// Plain text, for example "Read 14 cookies for example.org?".
    var question: String
    /// The full URL, shown in `code` style under the question.
    var detail: String?
}

/// An `@Observable` queue of pending confirmations. The tool awaits `ask`; the
/// transcript renders `pending`.
@MainActor
@Observable
final class AgentConfirmationGate {
    private(set) var pending: [AgentConfirmation] = []
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<Bool, Error>] = [:]
    /// Called with the question and the answer ("allowed", "declined" or "stopped").
    @ObservationIgnored var onAnswer: ((_ tool: String, _ question: String, _ answer: String) -> Void)?

    /// Waits for the person. Returns true for Allow, false for Don't allow, and
    /// throws `CancellationError` when the run is stopped first.
    func ask(tool: String, question: String, detail: String? = nil) async throws -> Bool {
        try Task.checkCancellation()
        let item = AgentConfirmation(id: UUID(), tool: tool, question: question, detail: detail)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending.append(item)
                continuations[item.id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.finish(item.id, result: .failure(CancellationError())) }
        }
    }

    func resolve(_ id: UUID, allow: Bool) {
        finish(id, result: .success(allow))
    }

    private func finish(_ id: UUID, result: Result<Bool, Error>) {
        guard let continuation = continuations.removeValue(forKey: id),
              let index = pending.firstIndex(where: { $0.id == id })
        else { return }
        let item = pending.remove(at: index)
        switch result {
        case .success(let allow):
            onAnswer?(item.tool, item.question, allow ? "allowed" : "declined")
        case .failure:
            onAnswer?(item.tool, item.question, "stopped")
        }
        continuation.resume(with: result)
    }
}

/// The confirmation card: the ScriptCard's shell with plain text and two Buttons.
struct AgentConfirmationCard: View {
    let confirmation: AgentConfirmation
    let gate: AgentConfirmationGate

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingM) {
            Text(confirmation.question)
                .font(.headline)
                .foregroundStyle(DCTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agentConfirmationQuestion")
            if let detail = confirmation.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(DCTheme.inkMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DCTheme.spacingS) {
                Button {
                    gate.resolve(confirmation.id, allow: true)
                } label: {
                    Text("Allow", comment: "Confirmation card button that lets the Agent go ahead")
                }
                .buttonStyle(DCButtonStyle(role: .primary))
                .accessibilityIdentifier("agentConfirmAllow")
                Button {
                    gate.resolve(confirmation.id, allow: false)
                } label: {
                    Text("Don't allow", comment: "Confirmation card button that stops the Agent from going ahead")
                }
                .buttonStyle(DCButtonStyle(role: .secondary))
                .accessibilityIdentifier("agentConfirmDeny")
            }
        }
        .padding(DCTheme.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous)
                .strokeBorder(DCTheme.hairline, lineWidth: DCTheme.hairlineWidth)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentConfirmCard")
        .onAppear {
            // The run is paused: tell VoiceOver users why.
            AccessibilityNotification.Announcement(confirmation.question).post()
        }
    }
}
