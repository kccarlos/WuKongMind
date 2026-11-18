import Foundation
import UIKit

/// The toast after ⋯ › Report a problem (`FeedbackSavedToast`).
struct FeedbackToastState: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var location: FeedbackReportLocation
}

extension AppModel {
    /// Builds the task's export (same redaction and refusals as ⋯ › Export task) and saves it as a
    /// feedback report (`FeedbackReportStore`). With `announces`, shows the toast. Throws the
    /// export's refusal; a task saved automatically just skips on one.
    @discardableResult
    func saveFeedbackReport(
        taskID: String, announces: Bool, store: FeedbackReportStore = .live
    ) async -> Result<FeedbackReportSaveResult, Error> {
        do {
            let file = try await TaskExport.file(
                taskID: taskID, store: taskRecordStore, cookieSource: WebKitTaskCookieSource(),
                secrets: browserAgentRuntimeConfig.redactedSecrets
            )
            let saved = try await Task.detached(priority: .utility) {
                try store.save(data: file.data, host: file.host)
            }.value
            if announces { showFeedbackToast(saved.location) }
            return .success(saved)
        } catch {
            return .failure(error)
        }
    }

    static func feedbackToastMessage(_ location: FeedbackReportLocation) -> String {
        switch location {
        case .iCloud:
            String(
                localized: "Saved for feedback. Send a TestFlight screenshot if you like.",
                comment: "Toast after Report a problem saved the task to iCloud Drive"
            )
        case .local:
            String(
                localized: "iCloud isn't available, so it's saved on this device in Files › WukongMind › Reports. Send a TestFlight screenshot if you like.",
                comment: "Toast after Report a problem saved the task locally because iCloud Drive isn't available"
            )
        }
    }

    func showFeedbackToast(_ location: FeedbackReportLocation, duration: Duration = .seconds(4)) {
        let toast = FeedbackToastState(message: Self.feedbackToastMessage(location), location: location)
        feedbackToastDismissTask?.cancel()
        feedbackToast = toast
        UIAccessibility.post(notification: .announcement, argument: toast.message)
        let effective = UIAccessibility.isVoiceOverRunning ? max(duration, .seconds(8)) : duration
        feedbackToastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: effective)
            guard !Task.isCancelled, let self, self.feedbackToast?.id == toast.id else { return }
            self.feedbackToast = nil
        }
    }
}
