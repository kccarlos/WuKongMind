import Foundation

// MARK: - AI data consent (App Review 5.1.2(i))
//
// Before the first request that sends web page content to a third-party AI
// provider, the person agrees to it on a full-screen page, once per provider
// (`AIDataConsentPage`). Apple Intelligence (on device / Private Cloud
// Compute) and model servers on this machine (Ollama, LM Studio on loopback)
// need no consent. Live voice has its own consent page (`VoiceConsentPage`)
// because it sends microphone audio to Google.
//
// - `AppSettings.aiConsent`    decisions per provider; synced one unit per
//                              provider. Withdrawing writes `.declined`, never
//                              removes the entry, so an older `.allowed` on
//                              another device cannot win the merge.
// - `AppSettings.voiceConsent` live voice microphone consent per Google
//                              endpoint; kept on this device.
// - `AIConsentGate`            who is waiting for an answer (not saved).
// - `AppModel.authorizeSending(to:baseURL:mayAsk:whileAsking:)`
//                              interactive check at the start of user work.
// - `AIConsentAuthorization`   TaskLocal interactive hook inherited by tools
//                              and jobs started on behalf of a user action.
// - `AIService.consentCheck`   the request-layer backstop before every
//                              third-party request (streamText & tool turns),
//                              including `GM_ai`, summaries, and the Agent.

/// What the person decided for one provider.
enum AIConsentDecision: Codable, Equatable {
    case allowed(Date)
    case declined(Date)

    var date: Date {
        switch self {
        case .allowed(let date), .declined(let date): date
        }
    }
}

/// Whether web page content may go to a provider now.
enum AIConsentState: Equatable {
    /// On this device or a loopback server on this machine: nothing to agree to.
    case notNeeded
    /// Never asked: work the user starts shows the consent page first;
    /// automatic work waits.
    case undecided
    case allowed(Date)
    case declined(Date)

    /// Requests may go out.
    var permitsRequests: Bool {
        switch self {
        case .notNeeded, .allowed: true
        case .undecided, .declined: false
        }
    }
}

/// Explicit consent to send live microphone audio and page content to Google,
/// asked once per voice endpoint before its first session and kept on this device.
enum VoiceConsent {
    static func isGranted(_ provider: VoiceProvider, in settings: AppSettings) -> Bool {
        settings.voiceConsent[provider.rawValue] != nil
    }
}

extension AIProvider {
    /// Sends content to a third party (not Apple Intelligence, not a loopback
    /// server on this machine).
    var requiresDataConsent: Bool { requiresDataConsent(baseURL: defaultBaseURL) }

    /// Whether sending content to `self` at `baseURL` needs AI data consent.
    /// Local servers (`.ollama`, `.lmStudio`) are exempt only when `baseURL`
    /// points to loopback (`localhost`, `127.0.0.1`, `::1`); remote and private
    /// LAN addresses require consent like cloud providers.
    func requiresDataConsent(baseURL: String) -> Bool {
        if isAppleIntelligence { return false }
        if isLocalServer { return !Self.isLocalBaseURL(baseURL) }
        return true
    }

    /// True only when `baseURL` resolves to a loopback address on this machine
    /// (`localhost`, `127.0.0.1`, `::1`), or is empty (falling back to the
    /// local default). Private LAN addresses (`192.168.x.x`, `10.x.x.x`,
    /// `172.16.x.x`, `.local`) are treated as remote.
    static func isLocalBaseURL(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let rawHost = components.host,
              !rawHost.isEmpty
        else {
            return false
        }
        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        switch host {
        case "localhost", "127.0.0.1", "::1", "0:0:0:0:0:0:0:1":
            return true
        default:
            return false
        }
    }
}

extension AppSettings {
    func requiresAIConsent(for provider: AIProvider) -> Bool {
        provider.requiresDataConsent(baseURL: configuration(for: provider).baseURL)
    }

    func aiConsentState(for provider: AIProvider) -> AIConsentState {
        aiConsentState(for: provider, baseURL: configuration(for: provider).baseURL)
    }

    func aiConsentState(for provider: AIProvider, baseURL: String) -> AIConsentState {
        guard provider.requiresDataConsent(baseURL: baseURL) else { return .notNeeded }
        switch aiConsent[provider.rawValue] {
        case nil: return .undecided
        case .allowed(let date): return .allowed(date)
        case .declined(let date): return .declined(date)
        }
    }

    /// The backstop's check: throws unless requests to `provider` may go.
    func requireAIConsent(for provider: AIProvider, baseURL: String? = nil) throws {
        let state = baseURL.map { aiConsentState(for: provider, baseURL: $0) } ?? aiConsentState(for: provider)
        switch state {
        case .notNeeded, .allowed: return
        case .undecided: throw AssistantError.aiConsentRequired(provider)
        case .declined: throw AssistantError.aiConsentDeclined(provider)
        }
    }
}

/// Each provider's terms and privacy policy, and what the consent page says
/// about how it may use what it receives. One table for every link.
struct AIProviderPolicy: Equatable {
    var termsURL: URL
    var privacyURL: URL
    /// Provider-specific data use, when there is something to say.
    var note: String?

    /// Nil for providers that need no consent.
    static func policy(for provider: AIProvider) -> AIProviderPolicy? {
        func make(_ terms: String, _ privacy: String, note: String? = nil) -> AIProviderPolicy {
            AIProviderPolicy(termsURL: URL(string: terms)!, privacyURL: URL(string: privacy)!, note: note)
        }
        switch provider {
        case .appleIntelligence, .ollama, .lmStudio:
            return nil
        case .openRouter:
            return make(
                "https://openrouter.ai/terms", "https://openrouter.ai/privacy",
                note: String(localized: "OpenRouter passes each request to the company that runs the model you chose, under that company’s own terms.", comment: "AI data consent: OpenRouter's data use")
            )
        case .openAI:
            return make("https://openai.com/policies/services-agreement/", "https://openai.com/policies/privacy-policy/")
        case .anthropic:
            return make("https://www.anthropic.com/legal/commercial-terms", "https://www.anthropic.com/legal/privacy")
        case .groq:
            return make("https://groq.com/terms-of-use", "https://groq.com/privacy-policy")
        case .gemini:
            return make(
                "https://ai.google.dev/gemini-api/terms", "https://policies.google.com/privacy",
                note: String(localized: "On Google AI Studio’s free tier, Google may use what you send to improve its products, and people may review it. A paid key or Vertex AI doesn’t allow this.", comment: "AI data consent: Google Gemini's free-tier data use")
            )
        case .vertexAI:
            return make(
                "https://cloud.google.com/terms", "https://cloud.google.com/terms/cloud-privacy-notice",
                note: String(localized: "On Vertex AI, your Google Cloud agreement decides how Google may use what you send.", comment: "AI data consent: data use on Vertex AI")
            )
        case .xAI:
            return make("https://x.ai/legal/terms-of-service-enterprise", "https://x.ai/legal/privacy-policy")
        case .deepSeek:
            return make(
                "https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html",
                "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html"
            )
        case .nvidia:
            return make("https://www.nvidia.com/en-us/about-nvidia/terms-of-service/", "https://www.nvidia.com/en-us/about-nvidia/privacy-policy/")
        }
    }
}

/// Interactive AI data consent hook inherited across async work started by
/// the user (such as an Agent run and every tool or summary job it invokes).
/// Unattended work (watched-topic refreshes, background tasks, autonomous page
/// scripts) leaves this nil so `AIService.consentCheck` remains a non-asking backstop.
enum AIConsentAuthorization {
    @TaskLocal static var authorize: (@MainActor @Sendable (AIProvider, String) async throws -> Void)?

    /// Shared status text shown while waiting for the person to answer the
    /// consent page for `provider`.
    static func waitingStatusText(for provider: AIProvider) -> String {
        String(
            localized: "Waiting for permission to use \(provider.displayName)…",
            comment: "Status while the AI data consent page is waiting for an answer; the placeholder is an AI provider's name"
        )
    }
}

/// Who is waiting for an answer on the consent page. The first provider in
/// `queue` has the page; several requests for the same provider share one
/// page, and a second provider is asked after the first is answered.
@MainActor
final class AIConsentGate: ObservableObject {
    /// Providers waiting for an answer, in the order they were asked.
    @Published private(set) var queue: [AIProvider] = []
    private var asked: Set<AIProvider> = []
    private var waiters: [UUID: (provider: AIProvider, continuation: CheckedContinuation<Void, Never>)] = [:]

    /// The provider whose page is up.
    var asking: AIProvider? { queue.first }

    /// Shows the page for `provider` (an "Allow…" button); asking again
    /// while it is queued does nothing.
    func ask(_ provider: AIProvider) {
        asked.insert(provider)
        enqueue(provider)
    }

    private func enqueue(_ provider: AIProvider) {
        if !queue.contains(provider) { queue.append(provider) }
    }

    /// Asks and returns once the page for `provider` is answered or closed,
    /// or the waiting task is cancelled. The caller reads the decision from
    /// the settings.
    func wait(for provider: AIProvider) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiters[id] = (provider, continuation)
                enqueue(provider)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(id) }
        }
    }

    /// The page for `provider` was answered or closed: every request
    /// waiting on it goes on. A second answer finds nothing to do.
    func resolve(_ provider: AIProvider) {
        asked.remove(provider)
        queue.removeAll { $0 == provider }
        for (id, waiter) in waiters where waiter.provider == provider {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    private func release(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume()
        let provider = waiter.provider
        if !asked.contains(provider), !waiters.values.contains(where: { $0.provider == provider }) {
            queue.removeAll { $0 == provider }
        }
    }
}
