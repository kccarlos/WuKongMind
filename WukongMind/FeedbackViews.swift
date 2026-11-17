import SwiftUI

// MARK: - Report a problem

/// ⋯ › Report a problem: the same alert and refusals as ⋯ › Export task, then the report is saved
/// to iCloud Drive (or locally) and a short toast says where. Set `taskID` to start.
struct TaskReportPrompt: ViewModifier {
    @ObservedObject var app: AppModel
    @Binding var taskID: String?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "Save this task for feedback?", comment: "Report a problem alert title"),
                isPresented: Binding(get: { taskID != nil }, set: { if !$0 { taskID = nil } })
            ) {
                Button(String(localized: "Save", comment: "Report a problem alert confirm")) {
                    guard let id = taskID else { return }
                    taskID = nil
                    Task { await run(id) }
                }
                Button(String(localized: "Cancel", comment: "Task export alert cancel"), role: .cancel) { taskID = nil }
            } message: {
                Text("The file includes the pages and results the Agent read. API keys and cookies are removed.",
                     comment: "Task export alert message")
            }
            .alert(
                String(localized: "Can't save this task", comment: "Report a problem failure title"),
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: failure ?? "")
            }
    }

    private func run(_ id: String) async {
        switch await app.saveFeedbackReport(taskID: id, announces: true) {
        case .success:
            DCHaptics.tap()
        case .failure(TaskExportError.cookiesRemain):
            failure = String(localized: "This task can't be exported without cookies in it.", comment: "Task export refused")
        case .failure(TaskExportError.notFound):
            failure = String(localized: "No record of this task was found.", comment: "Task export: record missing")
        case .failure:
            failure = String(localized: "The task file could not be built.", comment: "Task export failed")
        }
    }
}

extension View {
    func taskReportPrompt(app: AppModel, taskID: Binding<String?>) -> some View {
        modifier(TaskReportPrompt(app: app, taskID: taskID))
    }
}

// MARK: - Toast

/// The toast after a report is saved, in the style of the closed-tab toast.
struct FeedbackSavedToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DCTheme.ground)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.subheadline)
                .foregroundStyle(DCTheme.ground)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .background(DCTheme.ink, in: RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous))
        .dcShadowPop()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feedbackSavedToast")
    }
}
