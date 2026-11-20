import Foundation

// MARK: - AI data consent (see AIDataConsent.swift)

extension AppModel {
    func aiConsentState(for provider: AIProvider) -> AIConsentState {
        settings.aiConsentState(for: provider)
    }

    /// The role's model can run without anyone answering a consent page:
    /// what unattended work (the digest, watched-topic refreshes) needs.
    /// Undecided consent waits until the user starts work or allows it in Settings.
    func canRunUnattended(_ role: ModelRole) -> Bool {
        isProviderReady(for: role) && aiConsentState(for: selection(for: role).provider).permitsRequests
    }

    /// Before work sends web page content to `provider`. Allowed (or not
    /// needed) goes on; declined throws. Undecided shows the consent page
    /// when `mayAsk` (work the user started) and waits for the answer,
    /// calling `whileAsking` first; otherwise it throws, and the page never
    /// shows for unattended work.
    func authorizeSending(
        to provider: AIProvider,
        baseURL: String? = nil,
        mayAsk: Bool,
        whileAsking: () -> Void = {}
    ) async throws {
        let effectiveBaseURL = baseURL ?? settings.configuration(for: provider).baseURL
        if settings.aiConsentState(for: provider, baseURL: effectiveBaseURL) == .undecided, mayAsk {
            whileAsking()
            await aiConsent.wait(for: provider)
            try Task.checkCancellation()
        }
        try settings.requireAIConsent(for: provider, baseURL: effectiveBaseURL)
    }

    /// Allow or Don't Allow on the consent page. Requests waiting on it go
    /// on (or fail with the blocked state); a second tap changes nothing.
    func answerAIConsent(_ provider: AIProvider, allow: Bool) {
        guard settings.requiresAIConsent(for: provider) else {
            aiConsent.resolve(provider)
            return
        }
        switch (allow, aiConsentState(for: provider)) {
        case (true, .allowed), (false, .declined):
            break
        case (true, _):
            settings.aiConsent[provider.rawValue] = .allowed(Date())
        case (false, _):
            settings.aiConsent[provider.rawValue] = .declined(Date())
        }
        aiConsent.resolve(provider)
        save()
    }

    /// Settings › Data & privacy › Withdraw. Future requests are blocked
    /// (the provider stays configured as "Not allowed"); work running on it
    /// now is cancelled rather than left to finish, so nothing more is sent
    /// after the person says stop.
    func withdrawAIConsent(_ provider: AIProvider) {
        guard settings.requiresAIConsent(for: provider) || settings.aiConsent[provider.rawValue] != nil else { return }
        settings.aiConsent[provider.rawValue] = .declined(Date())
        for record in activities where !record.status.isTerminal && record.provider == provider {
            cancel(record: record)
        }
        if selection(for: .browserAgent).provider == provider {
            for tab in tabs.tabs where tab.agentSession.isRunning {
                tab.agentSession.stop()
            }
        }
        pauseDigest()
        podcast.pauseGeneration()
        save()
    }

    // MARK: - Live voice consent

    func grantVoiceConsent(_ provider: VoiceProvider) {
        settings.voiceConsent[provider.rawValue] = Date()
        save()
    }

    func revokeVoiceConsent(_ provider: VoiceProvider) {
        guard settings.voiceConsent.removeValue(forKey: provider.rawValue) != nil else { return }
        if voiceProvider == provider || voice.isActive {
            voice.end()
        }
        save()
    }
}

extension Error {
    /// Waiting for or blocked by AI data consent: handled in place rather than
    /// as a generic error alert.
    var isAIConsentError: Bool {
        switch self as? AssistantError {
        case .aiConsentRequired, .aiConsentDeclined: true
        default: false
        }
    }
}
