import XCTest
@testable import WukongMind

@MainActor
final class TermsAndReportingTests: XCTestCase {
    private func makeModel() -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        return AppModel(store: store)
    }

    func testFreshAppNeedsTermsAcceptanceAndAcceptsOnce() {
        let app = makeModel()
        XCTAssertEqual(app.settings.acceptedTermsVersion, 0)
        XCTAssertTrue(app.needsTermsAcceptance)

        app.acceptTerms()
        XCTAssertEqual(app.settings.acceptedTermsVersion, TermsOfUse.currentVersion)
        XCTAssertFalse(app.needsTermsAcceptance)
    }

    func testSettingsDecodingMissingAcceptedTermsVersionDefaultsToZero() throws {
        let json = Data(#"{"hasCompletedOnboarding":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(decoded.hasCompletedOnboarding)
        XCTAssertEqual(decoded.acceptedTermsVersion, 0)
    }

    func testResetSettingsPreservesAcceptedTermsVersion() {
        let app = makeModel()
        app.acceptTerms()
        app.settings.hasCompletedOnboarding = true
        app.resetSettings()
        XCTAssertEqual(app.settings.acceptedTermsVersion, TermsOfUse.currentVersion)
        XCTAssertFalse(app.needsTermsAcceptance)
    }

    func testAIOutputReportDraftFormatsFieldsTruncatesAndBuildsMailto() {
        let longText = String(repeating: "a", count: AIOutputReportTarget.reportTextLimit + 500)
        let target = AIOutputReportTarget(
            feature: .agentAnswer,
            siteURL: "https://example.com",
            pageTitle: "Example Page",
            pageURL: URL(string: "https://example.com/article"),
            model: "Anthropic · claude-sonnet-4-5",
            question: "Summarize this",
            text: longText
        )

        let draft = AIOutputReport.draft(
            for: target,
            reason: .harassment,
            note: "Offensive reply",
            appVersion: "1.5.4 (1)"
        )

        XCTAssertEqual(draft.subject, "WukongMind report: AI agent answer on example.com")
        XCTAssertTrue(draft.body.contains("Page: Example Page"))
        XCTAssertTrue(draft.body.contains("URL: https://example.com/article"))
        XCTAssertTrue(draft.body.contains("Feature: agent answer"))
        XCTAssertTrue(draft.body.contains("Model: Anthropic · claude-sonnet-4-5"))
        XCTAssertTrue(draft.body.contains("Reason: Harassment or bullying"))
        XCTAssertTrue(draft.body.contains("Prompt:\nSummarize this"))
        XCTAssertTrue(draft.body.contains("Details:\nOffensive reply"))
        XCTAssertTrue(draft.body.contains("App version: 1.5.4 (1)"))
        XCTAssertFalse(draft.body.contains(longText))
        XCTAssertTrue(draft.body.contains(String(repeating: "a", count: AIOutputReportTarget.reportTextLimit)))

        let mailto = AIOutputReport.mailtoURL(to: "support@example.com", subject: draft.subject, body: draft.body)
        XCTAssertEqual(mailto?.scheme, "mailto")
        XCTAssertEqual(mailto?.path, "support@example.com")
        XCTAssertEqual(
            AIOutputReport.clipboardText(recipient: "support@example.com", draft: draft),
            "To: support@example.com\nSubject: \(draft.subject)\n\n\(draft.body)"
        )
    }

    func testReportEmailReadsInfoPlistAndUnsetFallsBackToCopyShareOnly() {
        XCTAssertEqual(
            TermsOfUse.reportEmail(info: ["DCReportEmail": "  support@example.com \n"]),
            "support@example.com"
        )
        XCTAssertNil(TermsOfUse.reportEmail(info: [:]))
        XCTAssertNil(TermsOfUse.reportEmail(info: ["DCReportEmail": "   "]))
        XCTAssertNil(TermsOfUse.reportEmail(info: ["DCReportEmail": "SUPPORT_EMAIL_TBD"]))

        let draft = MailDraft(subject: "Test subject", body: "Test body")
        XCTAssertNil(AIOutputReport.mailtoURL(to: nil, subject: draft.subject, body: draft.body))
        XCTAssertNil(AIOutputReport.mailtoURL(to: "   ", subject: draft.subject, body: draft.body))
        XCTAssertEqual(
            AIOutputReport.clipboardText(recipient: nil, draft: draft),
            "Subject: Test subject\n\nTest body"
        )
    }

    func testAgentAnswerReportTargetRequiresNonEmptyReply() {
        let app = makeModel()
        let run = BrowserAgentRun(
            id: UUID(),
            prompt: "Make it dark",
            toolCalls: [],
            assistantText: "Done.",
            state: .completed(steps: 1, duration: 1),
            tokenUsage: .zero,
            startedAt: Date()
        )
        XCTAssertNil(app.agentAnswerReportTarget(for: run, reply: "   "))

        let target = app.agentAnswerReportTarget(for: run, reply: "Done.")
        XCTAssertEqual(target?.feature, .agentAnswer)
        XCTAssertEqual(target?.question, "Make it dark")
        XCTAssertEqual(target?.text, "Done.")
    }
}
