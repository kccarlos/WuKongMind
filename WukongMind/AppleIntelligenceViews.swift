import SwiftUI
import UIKit

/// Availability of the Apple Intelligence provider, with the
/// "No API key needed · Private" note (provider setup and Settings).
/// Reads the cached status on `AppModel` in `body` and refreshes off the render
/// path on appearance (and on app activation / settings changes).
struct AppleIntelligenceStatusView: View {
    @ObservedObject var app: AppModel
    /// Card chrome for onboarding; plain for a Form row.
    var carded = false

    var body: some View {
        let status = app.appleIntelligenceStatus
        VStack(alignment: .leading, spacing: DCTheme.spacingS) {
            HStack(alignment: .firstTextBaseline, spacing: DCTheme.spacingS) {
                Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(status.isAvailable ? DCTheme.success : DCTheme.warning)
                Text(status.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("appleIntelligenceStatus")
            }
            Text(status.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("No API key needed · Private", systemImage: "lock.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DCTheme.success)
            if status.reason == .appleIntelligenceNotEnabled,
               let url = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: url) {
                    Label("Open the Settings app", systemImage: "gear")
                        .font(.footnote.weight(.semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(OptionalCard(enabled: carded))
        .accessibilityElement(children: .combine)
        .onAppear { app.refreshAppleIntelligenceStatus() }
    }
}

private struct OptionalCard: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.dcCard() } else { content }
    }
}
