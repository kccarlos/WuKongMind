import MessageUI
import SwiftUI

// Views for Terms of Use acceptance and reporting AI output (see TermsAndReporting.swift).

// MARK: - Terms of Use

/// Summary of the Terms of Use and the agreement toggle.
struct TermsAgreementCard: View {
    @Binding var agreed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingL) {
            TermsPoints()
            Link(destination: AppVersion.termsURL) {
                Label(
                    String(localized: "Read the full Terms of Use", comment: "Terms gate: link to full Terms of Use"),
                    systemImage: "doc.text"
                )
                .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("termsLink")
            Toggle(isOn: $agreed) {
                Text("I agree to the Terms of Use", comment: "Toggle the user must turn on before using the app")
                    .font(.body.weight(.semibold))
            }
            .tint(DCTheme.gold)
            .accessibilityIdentifier("termsAgree")
        }
        .dcCard()
    }
}

/// Key points shown on the Terms gate before first use.
struct TermsPoints: View {
    var body: some View {
        OnboardingFeatureRow(
            symbol: "hand.raised.slash.fill",
            tint: DCTheme.warning,
            title: String(localized: "No tolerance for abuse", comment: "Terms of Use summary row title"),
            detail: String(localized: "Objectionable content and abusive behavior are not tolerated. Websites you open belong to their own owners.", comment: "Terms of Use summary row")
        )
        OnboardingFeatureRow(
            symbol: "flag.fill",
            tint: DCTheme.cinnabar,
            title: String(localized: "Report AI output", comment: "Terms of Use summary row title"),
            detail: String(localized: "On any AI summary or answer, open its menu and choose Report this answer. Reports are reviewed within 24 hours.", comment: "Terms of Use summary row")
        )
        OnboardingFeatureRow(
            symbol: "sparkles",
            tint: DCTheme.gold,
            title: String(localized: "Check AI answers", comment: "Terms of Use summary row title"),
            detail: String(localized: "Summaries and answers come from your chosen AI provider and can be wrong. Verify important details on the page.", comment: "Terms of Use summary row")
        )
    }
}

/// Shown once after onboarding/consent (or after an update that bumps `TermsOfUse.currentVersion`).
struct TermsGateView: View {
    @ObservedObject var app: AppModel
    @State private var agreed = false

    var body: some View {
        NavigationStack {
            OnboardingPage {
                OnboardingHeader(
                    eyebrow: String(localized: "Terms of Use", comment: "Terms gate eyebrow"),
                    title: String(localized: "Before you continue", comment: "Terms gate title"),
                    subtitle: String(localized: "Please read and accept the Terms of Use. They explain what isn’t allowed and how to report AI output.", comment: "Terms gate subtitle")
                )
                TermsAgreementCard(agreed: $agreed)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    DCHaptics.tap()
                    app.acceptTerms()
                } label: {
                    Text("Continue")
                }
                .buttonStyle(DCPrimaryButtonStyle())
                .disabled(!agreed)
                .padding(.horizontal, DCTheme.spacingXL)
                .padding(.vertical, DCTheme.spacingM)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .dcStickyFooter()
                .accessibilityIdentifier("termsContinue")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("termsGate")
        .interactiveDismissDisabled()
    }
}

// MARK: - Report AI output

/// Report This Summary / Report This Answer (App Review 1.2): picks a reason,
/// then opens the user's Mail composer or a copy/share fallback.
struct AIOutputReportSheet: View {
    let target: AIOutputReportTarget
    var reportEmail: String? = TermsOfUse.reportEmail
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MailDraft?

    var body: some View {
        if let draft {
            if let reportEmail, MFMailComposeViewController.canSendMail() {
                MailComposer(recipient: reportEmail, draft: draft) { dismiss() }
                    .ignoresSafeArea()
            } else {
                ReportEmailFallback(reportEmail: reportEmail, draft: draft)
            }
        } else {
            AIOutputReportForm(target: target, hasRecipient: reportEmail != nil) { reason, note in
                draft = AIOutputReport.draft(for: target, reason: reason, note: note)
            }
            .accessibilityIdentifier("aiOutputReportForm")
        }
    }
}

/// Reason picker and optional details for reporting an AI answer or summary.
struct AIOutputReportForm: View {
    let target: AIOutputReportTarget
    var hasRecipient = true
    let onSend: (AIOutputReportReason, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason: AIOutputReportReason = .inaccurate
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(AIOutputReportReason.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("What’s wrong?", comment: "Report form section header")
                }
                Section {
                    TextField(
                        String(localized: "Details (optional)", comment: "Report form optional details field"),
                        text: $note,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                } footer: {
                    Text(
                        hasRecipient
                            ? String(localized: "Next, your email app opens with the report filled in, or you can copy or share it. Reports are reviewed within 24 hours.", comment: "Report form footer")
                            : String(localized: "Next, you can copy or share the report. Reports are reviewed within 24 hours.", comment: "Report form footer when no report email is configured")
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { onSend(reason, note) }
                        .accessibilityIdentifier("reportNext")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch target.feature {
        case .summary:
            String(localized: "Report summary", comment: "Title of the form that reports an AI summary")
        case .agentAnswer:
            String(localized: "Report answer", comment: "Title of the form that reports an AI answer")
        }
    }
}

/// Shown when Mail isn't configured (or no recipient is set): open another email app, copy, or share.
struct ReportEmailFallback: View {
    let reportEmail: String?
    let draft: MailDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let reportEmail {
                        LabeledContent("To", value: reportEmail)
                    }
                    LabeledContent("Subject", value: draft.subject)
                } footer: {
                    Text(
                        reportEmail != nil
                            ? String(localized: "Mail isn’t set up on this device. Send the report from any email app, or copy or share it.", comment: "Report fallback footer")
                            : String(localized: "Copy or share the report to send it.", comment: "Report fallback footer when no report email is configured")
                    )
                }
                Section("Report") {
                    Text(draft.body)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                Section {
                    if let mailtoURL = AIOutputReport.mailtoURL(to: reportEmail, subject: draft.subject, body: draft.body) {
                        Button {
                            openURL(mailtoURL)
                        } label: {
                            Label("Open in email app", systemImage: "envelope")
                        }
                        .accessibilityIdentifier("openEmailApp")
                    }
                    Button {
                        UIPasteboard.general.string = AIOutputReport.clipboardText(recipient: reportEmail, draft: draft)
                        copied = true
                        DCHaptics.success()
                    } label: {
                        Label(
                            copied ? String(localized: "Copied") : String(localized: "Copy report"),
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .accessibilityIdentifier("copyReport")
                    ShareLink(item: draft.body, subject: Text(draft.subject)) {
                        Label("Share report", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("shareReport")
                }
            }
            .navigationTitle("Send report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("reportFallbackDone")
                }
            }
        }
    }
}

/// System mail composer addressed to the developer's report email.
struct MailComposer: UIViewControllerRepresentable {
    let recipient: String
    let draft: MailDraft
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([recipient])
        controller.setSubject(draft.subject)
        controller.setMessageBody(draft.body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinish()
        }
    }
}
