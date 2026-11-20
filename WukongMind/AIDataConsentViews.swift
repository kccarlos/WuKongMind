import SwiftUI

// The AI data consent page, live voice consent page, and Settings › Data &
// privacy › Where your data goes. See AIDataConsent.swift.

// MARK: - AI data consent page

/// "Send web page content to <provider>?": what goes, the provider's own note
/// and policies, WukongMind's privacy policy, Allow / Don't Allow. Full screen
/// (`RootPresentation.isFullScreen`); only an answer closes it.
struct AIDataConsentPage: View {
    let provider: AIProvider
    let onAllow: () -> Void
    let onDecline: () -> Void
    var onCancel: (() -> Void)? = nil

    private var policy: AIProviderPolicy? { AIProviderPolicy.policy(for: provider) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                    HStack(spacing: DCTheme.spacingM) {
                        ProviderBadge(provider: provider, size: 44)
                        Image(systemName: "arrow.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Straight from this device. No WukongMind server.", comment: "AI data consent: requests go directly to the provider")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Send web page content to \(provider.displayName)?", comment: "AI data consent title; the placeholder is an AI provider's name")
                        .font(.title2.weight(.heavy))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("aiConsentTitle")

                    VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                        Text("What WukongMind sends", comment: "AI data consent: heading above the list of what is sent")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ConsentBullet(Text("Web pages and text you summarize or ask about, including pages you see while signed in", comment: "AI data consent: what is sent"))
                        ConsentBullet(Text("Your questions, instructions, and chat messages", comment: "AI data consent: what is sent"))
                        ConsentBullet(Text("Your API key, only to \(provider.displayName)", comment: "AI data consent: what is sent; the placeholder is an AI provider's name"))
                    }

                    if let note = policy?.note {
                        ConsentNoteBox(text: note, id: "aiConsentNote")
                    }

                    VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                        if let policy {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: DCTheme.spacingL) { providerLinks(policy) }
                                VStack(alignment: .leading, spacing: DCTheme.spacingS) { providerLinks(policy) }
                            }
                        }
                        Link(destination: AppVersion.privacyPolicyURL) {
                            Text("WukongMind’s privacy policy", comment: "AI data consent: link to the app's privacy policy")
                        }
                        .accessibilityIdentifier("aiConsentAppPrivacy")
                    }
                    .font(.subheadline)

                    Text("Change this any time in Settings › Data & privacy. Live voice asks separately.", comment: "AI data consent footer; Settings › Data & privacy names the app's own Settings page")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DCTheme.spacingXL)
                .frame(maxWidth: DCTheme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                ConsentFooterButtons(
                    allowID: "aiConsentAllow",
                    declineID: "aiConsentDecline",
                    onAllow: onAllow,
                    onDecline: onDecline
                )
            }
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                            .accessibilityIdentifier("aiConsentCancel")
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("aiConsentPage")
    }

    @ViewBuilder
    private func providerLinks(_ policy: AIProviderPolicy) -> some View {
        Link(destination: policy.termsURL) {
            Text("\(provider.displayName)’s terms", comment: "AI data consent: link to the provider's terms; the placeholder is an AI provider's name")
        }
        .accessibilityIdentifier("aiConsentTerms")
        Link(destination: policy.privacyURL) {
            Text("\(provider.displayName)’s privacy policy", comment: "AI data consent: link to the provider's privacy policy; the placeholder is an AI provider's name")
        }
        .accessibilityIdentifier("aiConsentPrivacy")
    }
}

// MARK: - Live voice consent page

/// "Send microphone audio to <Google AI Studio / Vertex AI>?": separate
/// full-screen consent before the first live voice session.
struct VoiceConsentPage: View {
    let provider: VoiceProvider
    let onAllow: () -> Void
    let onDecline: () -> Void

    private var policy: AIProviderPolicy? { AIProviderPolicy.policy(for: provider.keyProvider) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                    HStack(spacing: DCTheme.spacingM) {
                        ProviderBadge(provider: provider.keyProvider, size: 44)
                        Image(systemName: "arrow.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Straight from this device. No WukongMind server.", comment: "AI data consent: requests go directly to the provider")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Send microphone audio to \(provider.displayName)?", comment: "Live voice consent title; the placeholder is Google AI Studio or Google Vertex AI")
                        .font(.title2.weight(.heavy))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("voiceConsentTitle")

                    VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                        Text("What WukongMind sends", comment: "AI data consent: heading above the list of what is sent")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ConsentBullet(Text("Live microphone audio while a voice session is active", comment: "Live voice consent: what is sent"))
                        ConsentBullet(Text("The web page content you ask about", comment: "Live voice consent: what is sent"))
                        ConsentBullet(Text("Your API key, only to \(provider.displayName)", comment: "AI data consent: what is sent; the placeholder is an AI provider's name"))
                    }

                    if let note = policy?.note {
                        ConsentNoteBox(text: note, id: "voiceConsentNote")
                    }

                    VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                        if let policy {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: DCTheme.spacingL) { providerLinks(policy) }
                                VStack(alignment: .leading, spacing: DCTheme.spacingS) { providerLinks(policy) }
                            }
                        }
                        Link(destination: AppVersion.privacyPolicyURL) {
                            Text("WukongMind’s privacy policy", comment: "AI data consent: link to the app's privacy policy")
                        }
                        .accessibilityIdentifier("voiceConsentAppPrivacy")
                    }
                    .font(.subheadline)

                    Text("Change this any time in Settings › Data & privacy.", comment: "Live voice consent footer; Settings › Data & privacy names the app's own Settings page")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DCTheme.spacingXL)
                .frame(maxWidth: DCTheme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                ConsentFooterButtons(
                    allowID: "voiceConsentAllow",
                    declineID: "voiceConsentDecline",
                    onAllow: onAllow,
                    onDecline: onDecline
                )
            }
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("voiceConsentPage")
    }

    @ViewBuilder
    private func providerLinks(_ policy: AIProviderPolicy) -> some View {
        Link(destination: policy.termsURL) {
            Text("\(provider.displayName)’s terms", comment: "AI data consent: link to the provider's terms; the placeholder is an AI provider's name")
        }
        .accessibilityIdentifier("voiceConsentTerms")
        Link(destination: policy.privacyURL) {
            Text("\(provider.displayName)’s privacy policy", comment: "AI data consent: link to the provider's privacy policy; the placeholder is an AI provider's name")
        }
        .accessibilityIdentifier("voiceConsentPrivacy")
    }
}

private struct ConsentBullet: View {
    let text: Text
    init(_ text: Text) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DCTheme.spacingS) {
            Circle()
                .fill(Color.primary)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                .accessibilityHidden(true)
            text
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ConsentNoteBox: View {
    let text: String
    let id: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .padding(DCTheme.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DCTheme.newRepliesBadgeBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
                    .stroke(DCTheme.warning.opacity(0.3))
            }
            .accessibilityIdentifier(id)
    }
}

private struct ConsentFooterButtons: View {
    let allowID: String
    let declineID: String
    let onAllow: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: DCTheme.spacingS) {
            Button(action: onAllow) {
                Text("Allow", comment: "AI data consent: agree to send content to the provider")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DCPrimaryButtonStyle())
            .accessibilityIdentifier(allowID)
            Button(action: onDecline) {
                Text("Don’t Allow", comment: "AI data consent: refuse to send content to the provider")
                    .frame(maxWidth: .infinity, minHeight: DCTheme.controlHeight)
            }
            .accessibilityIdentifier(declineID)
        }
        .padding(.horizontal, DCTheme.spacingXL)
        .padding(.vertical, DCTheme.spacingM)
        .frame(maxWidth: DCTheme.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .dcStickyFooter()
    }
}

// MARK: - Settings › Data & privacy

/// Where your data goes: each feature with the provider it uses and the
/// consent behind it, then each third-party provider and voice endpoint with
/// its decision and Withdraw / Allow.
struct AIDataFlowSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var aiConsent: AIConsentGate
    /// Hosted on the enclosing `Form` so SwiftUI never drops the presentation from a `Section`.
    @Binding var allowing: AIProvider?

    init(app: AppModel, allowing: Binding<AIProvider?>) {
        self.app = app
        aiConsent = app.aiConsent
        _allowing = allowing
    }

    private var assistant: AIProvider { app.selection(for: .assistant).provider }
    private var agent: AIProvider? { app.settings.configuredBrowserAgentModel?.provider }
    private var scripts: AIProvider? { app.settings.scriptsModel?.provider }

    /// Third-party providers in use or with a recorded decision, in list order.
    var providers: [AIProvider] {
        AIProvider.allCases.filter {
            app.settings.requiresAIConsent(for: $0)
                && ($0 == assistant || $0 == agent || $0 == scripts || app.settings.aiConsent[$0.rawValue] != nil)
        }
    }

    private var grantedVoiceProviders: [VoiceProvider] {
        VoiceProvider.allCases.filter { VoiceConsent.isGranted($0, in: app.settings) }
    }

    var body: some View {
        Section {
            if let agent, agent != assistant {
                flowRow(
                    title: String(localized: "Agent", comment: "AI model role: the tool-calling model used by the Agent"),
                    detail: flowDetail(agent),
                    value: stateText(agent)
                )
                flowRow(
                    title: String(localized: "Summaries", comment: "AI model role: the model used for summaries, digests and reply checks"),
                    detail: flowDetail(assistant),
                    value: stateText(assistant)
                )
            } else {
                flowRow(
                    title: String(localized: "Agent & summaries", comment: "Settings › Data & privacy: the AI features using one provider"),
                    detail: flowDetail(assistant),
                    value: stateText(assistant)
                )
            }
            if let scripts, scripts != assistant, scripts != agent {
                flowRow(
                    title: String(localized: "Scripts", comment: "AI model role: the model userscripts ask via GM_ai"),
                    detail: flowDetail(scripts),
                    value: stateText(scripts)
                )
            }
            flowRow(
                title: String(localized: "Live voice", comment: "Settings › Data & privacy: live voice"),
                detail: String(localized: "Your microphone audio and the page → Google Gemini Live", comment: "Settings › Data & privacy: where live voice sends data"),
                value: agreedText(VoiceProvider.allCases.compactMap { app.settings.voiceConsent[$0.rawValue] }.max())
            )
            Link(destination: AppVersion.privacyPolicyURL) {
                Label(String(localized: "Privacy Policy", comment: "Settings › Data & privacy: link to the app's privacy policy"), systemImage: "hand.raised")
            }
            .accessibilityIdentifier("settingsDataPrivacyPolicy")
        } header: {
            Text("Where your data goes", comment: "Settings › Data & privacy section header")
        } footer: {
            Text("Nothing goes to a WukongMind server: there isn’t one.", comment: "Settings › Data & privacy footer")
        }

        if !providers.isEmpty {
            Section {
                ForEach(providers) { provider in
                    providerRow(provider)
                }
            } header: {
                Text("AI providers", comment: "Settings › Data & privacy section header: consent per AI provider")
            } footer: {
                Text("Withdrawing stops what is running on that provider and blocks new requests. It stays set up, so you can allow it again.", comment: "Settings › Data & privacy footer of the AI providers' consent")
            }
        }

        if !grantedVoiceProviders.isEmpty {
            Section {
                ForEach(grantedVoiceProviders) { provider in
                    HStack(spacing: DCTheme.spacingM) {
                        ProviderBadge(provider: provider.keyProvider, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                            Text(agreedText(app.settings.voiceConsent[provider.rawValue]))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: DCTheme.spacingS)
                        Button("Withdraw", role: .destructive) { app.revokeVoiceConsent(provider) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Withdraw live voice consent for \(provider.displayName)", comment: "Settings › Data & privacy; the placeholder is Google AI Studio or Google Vertex AI"))
                            .accessibilityIdentifier("voiceConsentWithdraw-\(provider.rawValue)")
                    }
                }
            } header: {
                Text("Live voice", comment: "Settings › Data & privacy section header: live voice consent")
            } footer: {
                Text("Withdrawing ends an active voice session and asks again before starting a new one.", comment: "Settings › Data & privacy footer of live voice consent")
            }
        }
    }

    private func flowRow(title: String, detail: String, value: String) -> some View {
        HStack(spacing: DCTheme.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DCTheme.spacingS)
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func providerRow(_ provider: AIProvider) -> some View {
        let state = app.aiConsentState(for: provider)
        return HStack(spacing: DCTheme.spacingM) {
            ProviderBadge(provider: provider, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Text(stateText(provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DCTheme.spacingS)
            switch state {
            case .allowed:
                Button("Withdraw", role: .destructive) { app.withdrawAIConsent(provider) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Withdraw consent for \(provider.displayName)", comment: "Settings › Data & privacy; the placeholder is an AI provider's name"))
                    .accessibilityIdentifier("aiConsentWithdraw-\(provider.rawValue)")
            case .declined, .undecided:
                Button(String(localized: "Allow…", comment: "Settings › Data & privacy: shows the AI data consent page")) { allowing = provider }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("aiConsentAllow-\(provider.rawValue)")
            case .notNeeded:
                EmptyView()
            }
        }
    }

    private func flowDetail(_ provider: AIProvider) -> String {
        if provider.isAppleIntelligence {
            return String(localized: "Stays with Apple Intelligence (on this device or Private Cloud Compute)", comment: "Settings › Data & privacy: Apple Intelligence keeps the data with Apple")
        }
        if provider.isLocalServer, !app.settings.requiresAIConsent(for: provider) {
            return String(localized: "Web pages you open → \(provider.displayName), on your computer", comment: "Settings › Data & privacy: a local model server; the placeholder is its name")
        }
        return String(localized: "Web pages you open → \(provider.displayName)", comment: "Settings › Data & privacy: where AI features send data; the placeholder is an AI provider's name")
    }

    private func stateText(_ provider: AIProvider) -> String {
        switch app.aiConsentState(for: provider) {
        case .notNeeded: String(localized: "No consent needed", comment: "Settings › Data & privacy: Apple Intelligence or a local server")
        case .undecided: String(localized: "Asks first", comment: "Settings › Data & privacy: the consent page shows before the first request")
        case .allowed(let date): agreedText(date)
        case .declined: String(localized: "Not allowed", comment: "AI model state: the user chose not to send web page content to this provider")
        }
    }

    private func agreedText(_ date: Date?) -> String {
        guard let date else { return String(localized: "Asks first", comment: "Settings › Data & privacy: the consent page shows before the first request") }
        return String(localized: "Agreed \(date.formatted(.dateTime.month(.abbreviated).day()))", comment: "Settings › Data & privacy: when consent was given; the placeholder is a short date")
    }
}
