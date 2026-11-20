import Foundation

// MARK: - Terms of Use and AI output reporting (App Review 1.2, 4.7.1)
//
// - `TermsOfUse`: versioned Terms of Use acceptance shown once on first run
//   (right after onboarding/consent) and whenever `currentVersion` bumps.
// - `AIOutputReport`: prefilled email draft (or copy/share fallback) for
//   reporting objectionable or inaccurate AI summaries and answers.

enum TermsOfUse {
    /// Bump when the terms change materially; everyone accepts again.
    static let currentVersion = 1
    private static let reportEmailInfoKey = "DCReportEmail"

    /// Receives AI output reports when `DCReportEmail` is configured in `Info.plist`.
    static var reportEmail: String? { reportEmail() }

    static func reportEmail(info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        guard let raw = info?[reportEmailInfoKey] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("_TBD") else { return nil }
        return trimmed
    }
}

/// An AI-generated summary or answer that the user chooses to report.
struct AIOutputReportTarget: Identifiable, Equatable {
    enum Feature: String, Equatable {
        case summary
        case agentAnswer = "agent answer"
    }

    var feature: Feature
    var siteURL: String
    var pageTitle: String
    var pageURL: URL?
    /// "Provider · model", as shown in the UI.
    var model: String
    var question: String?
    var text: String

    /// Maximum number of AI output characters included in the report draft.
    static let reportTextLimit = 4_000

    var id: String {
        "\(feature.rawValue)|\(pageURL?.absoluteString ?? siteURL)|\(text.hashValue)"
    }
}

enum AIOutputReportReason: String, CaseIterable, Identifiable {
    case inaccurate
    case harassment
    case hate
    case sexual
    case violence
    case illegal
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inaccurate: String(localized: "Inaccurate or misleading", comment: "AI output report reason")
        case .harassment: String(localized: "Harassment or bullying", comment: "AI output report reason")
        case .hate: String(localized: "Hate speech", comment: "AI output report reason")
        case .sexual: String(localized: "Sexual content", comment: "AI output report reason")
        case .violence: String(localized: "Violence or threats", comment: "AI output report reason")
        case .illegal: String(localized: "Illegal content", comment: "AI output report reason")
        case .other: String(localized: "Something else", comment: "AI output report reason")
        }
    }
}

struct MailDraft: Equatable {
    var subject: String
    var body: String
}

/// Builds the email draft and `mailto:` fallback for an AI output report.
enum AIOutputReport {
    static func subject(for target: AIOutputReportTarget) -> String {
        let host = target.pageURL?.host(percentEncoded: false)
            ?? (target.siteURL.isEmpty ? "" : ForumSite.host(of: target.siteURL))
        if host.isEmpty {
            return "WukongMind report: AI \(target.feature.rawValue)"
        }
        return "WukongMind report: AI \(target.feature.rawValue) on \(host)"
    }

    static func body(
        for target: AIOutputReportTarget,
        reason: AIOutputReportReason,
        note: String,
        appVersion: String = AppVersion.text()
    ) -> String {
        var lines: [String] = [
            "I'm reporting this AI output in WukongMind.",
            ""
        ]
        if !target.pageTitle.isEmpty { lines.append("Page: \(target.pageTitle)") }
        if let url = target.pageURL {
            lines.append("URL: \(url.absoluteString)")
        } else if !target.siteURL.isEmpty {
            lines.append("Site: \(target.siteURL)")
        }
        lines.append("Feature: \(target.feature.rawValue)")
        if !target.model.isEmpty { lines.append("Model: \(target.model)") }
        lines.append("Reason: \(reason.title)")

        let trimmedQuestion = target.question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedQuestion.isEmpty {
            lines.append("")
            lines.append("Prompt:")
            lines.append(String(trimmedQuestion.prefix(500)))
        }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            lines.append("")
            lines.append("Details:")
            lines.append(trimmedNote)
        }

        let trimmedText = target.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            lines.append("")
            lines.append("AI output:")
            lines.append(String(trimmedText.prefix(AIOutputReportTarget.reportTextLimit)))
        }

        lines.append("")
        lines.append("App version: \(appVersion)")
        return lines.joined(separator: "\n")
    }

    static func draft(
        for target: AIOutputReportTarget,
        reason: AIOutputReportReason,
        note: String,
        appVersion: String = AppVersion.text()
    ) -> MailDraft {
        MailDraft(
            subject: subject(for: target),
            body: body(for: target, reason: reason, note: note, appVersion: appVersion)
        )
    }

    static func mailtoURL(to recipient: String?, subject: String, body: String) -> URL? {
        guard let recipient = recipient?.trimmingCharacters(in: .whitespacesAndNewlines), !recipient.isEmpty else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }

    static func clipboardText(recipient: String?, draft: MailDraft) -> String {
        if let recipient = recipient?.trimmingCharacters(in: .whitespacesAndNewlines), !recipient.isEmpty {
            return "To: \(recipient)\nSubject: \(draft.subject)\n\n\(draft.body)"
        }
        return "Subject: \(draft.subject)\n\n\(draft.body)"
    }
}

extension AppModel {
    var needsTermsAcceptance: Bool {
        settings.acceptedTermsVersion < TermsOfUse.currentVersion
    }

    func acceptTerms() {
        guard settings.acceptedTermsVersion < TermsOfUse.currentVersion else { return }
        settings.acceptedTermsVersion = TermsOfUse.currentVersion
        save()
    }

    func reportAIOutput(_ target: AIOutputReportTarget) {
        router.item = .reportAIOutput(target)
    }

    func aiSummaryReportTarget() -> AIOutputReportTarget? {
        guard let session = currentSession else { return nil }
        let text = session.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let selection = selection(for: .assistant)
        let modelName = session.model.isEmpty
            ? (selection.model.isEmpty ? selection.provider.displayName : "\(selection.provider.displayName) · \(selection.model)")
            : session.model
        return AIOutputReportTarget(
            feature: .summary,
            siteURL: session.siteURL,
            pageTitle: session.title,
            pageURL: session.url,
            model: modelName,
            question: nil,
            text: text
        )
    }

    func agentAnswerReportTarget(for run: BrowserAgentRun, reply: String) -> AIOutputReportTarget? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let selection = selection(for: .browserAgent)
        let modelName = selection.model.isEmpty
            ? selection.provider.displayName
            : "\(selection.provider.displayName) · \(selection.model)"
        let pageURL = pageContext.url ?? tabs.currentTab.url
        let siteURL = pageContext.siteURL ?? pageURL.map { ForumSite.normalizeSiteURL($0.absoluteString) ?? $0.absoluteString } ?? ""
        return AIOutputReportTarget(
            feature: .agentAnswer,
            siteURL: siteURL,
            pageTitle: tabs.currentTab.title,
            pageURL: pageURL,
            model: modelName,
            question: run.prompt,
            text: trimmed
        )
    }
}
