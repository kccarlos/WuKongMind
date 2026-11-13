import Foundation

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Apple Foundation Models: Private Cloud Compute when available, else
    /// on-device. Listed first so pickers show it first. No key, no base URL.
    case appleIntelligence = "appleintelligence"
    case openRouter = "openrouter"
    case openAI = "openai"
    case anthropic
    case groq
    case gemini
    /// Gemini on Google Cloud Vertex AI with an API key (express mode, or a
    /// project and location in the base URL). Same wire format as `gemini`.
    case vertexAI = "vertexai"
    case ollama
    case xAI = "xai"
    case deepSeek = "deepseek"
    case lmStudio = "lmstudio"
    case nvidia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        // Apple's own name per language ("Apple 智能" in Simplified Chinese).
        case .appleIntelligence: String(localized: "Apple Intelligence", comment: "AI provider name. Use Apple's official name for Apple Intelligence in this language.")
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .groq: "Groq"
        case .gemini: "Google Gemini"
        case .vertexAI: "Google Vertex AI"
        case .ollama: String(localized: "Ollama (Local)", comment: "AI provider name: Ollama running on the user's own computer. Keep \"Ollama\".")
        case .xAI: "xAI Grok"
        case .deepSeek: "DeepSeek"
        case .lmStudio: String(localized: "LM Studio (Local)", comment: "AI provider name: LM Studio running on the user's own computer. Keep \"LM Studio\".")
        case .nvidia: "NVIDIA NIM"
        }
    }

    var defaultModel: String {
        switch self {
        // The backend is chosen at run time; records store "On-device" or
        // "Private Cloud Compute" (`RunSettings.resolvingAppleIntelligence`).
        case .appleIntelligence: "Automatic"
        case .openRouter: "moonshotai/kimi-k2"
        case .openAI: "gpt-4o-mini"
        case .anthropic: "claude-3-haiku-20240307"
        case .groq: "llama-3.1-8b-instant"
        case .gemini: "gemini-1.5-flash"
        case .vertexAI: "gemini-2.5-flash"
        case .ollama: "llama3.2"
        case .xAI: "grok-3"
        case .deepSeek: "deepseek-chat"
        case .lmStudio: "local-model"
        case .nvidia: "deepseek-ai/deepseek-v4-flash-0731"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .appleIntelligence: ""
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        // Express mode's global host. A project key can use
        // https://aiplatform.googleapis.com/v1/projects/<id>/locations/global.
        case .vertexAI: "https://aiplatform.googleapis.com/v1"
        case .ollama: "http://localhost:11434"
        case .xAI: "https://api.x.ai/v1"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .lmStudio: "http://localhost:1234/v1"
        // OpenAI-compatible: /models, /chat/completions, SSE streaming.
        case .nvidia: "https://integrate.api.nvidia.com/v1"
        }
    }

    var requiresAPIKey: Bool {
        self != .ollama && self != .lmStudio && self != .appleIntelligence
    }

    /// Built into the OS (no key, no server address, no model list).
    var isAppleIntelligence: Bool { self == .appleIntelligence }

    /// A model server on the user's own computer (needs a server address).
    var isLocalServer: Bool { self == .ollama || self == .lmStudio }

    /// Native tool calling in `AIService.completeToolTurn` (browser agent).
    var supportsToolCalling: Bool { !isAppleIntelligence }

    /// Multimodal image input capability for future screenshot/vision tools.
    var supportsImageInput: Bool {
        switch self {
        case .anthropic, .openAI, .openRouter, .gemini, .vertexAI, .xAI, .ollama, .lmStudio:
            true
        case .appleIntelligence, .groq, .deepSeek, .nvidia:
            false
        }
    }

    /// Vertex AI has no model list an API key can read, so the picker offers
    /// these Gemini models; any other model ID can still be typed.
    static let vertexAIModels = [
        "gemini-3.8-flash",
        "gemini-3.7-flash",
        "gemini-3.5-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.1-pro-preview",
        "gemini-3.1-flash-lite",
        "gemini-3-flash-preview",
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite"
    ]
}

/// A provider's connection (address and key). `model` is not stored: each
/// role's `ModelSelection` is the only model setting, and
/// `AppSettings.configuration(for: ModelRole)` fills it in for a request;
/// a provider's own configuration carries its default model.
struct ProviderConfiguration: Codable, Equatable, Sendable {
    var model: String
    var baseURL: String
    var apiKey: String

    private enum CodingKeys: String, CodingKey { case baseURL, apiKey }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = ""
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    init(model: String, baseURL: String, apiKey: String) {
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    init(provider: AIProvider) {
        model = provider.defaultModel
        baseURL = provider.defaultBaseURL
        apiKey = ""
    }
}

/// Which job a model is chosen for. Summaries, chat and watched-topic
/// refreshes use the assistant model; Ask the forum uses the agent model;
/// the page browser agent uses `browserAgent` (with no preset model).
/// See `AppModel+Models.swift`.
enum ModelRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case assistant
    case agent
    case browserAgent

    /// The two forum roles (onboarding and shared-role toggles).
    static let forumRoles: [ModelRole] = [.assistant, .agent]

    var id: String { rawValue }
}

/// A provider and one of its models: what a role runs with.
struct ModelSelection: Codable, Hashable, Sendable {
    var provider: AIProvider
    var model: String

    var supportsToolCalling: Bool {
        provider.supportsToolCalling
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var supportsImageInput: Bool {
        provider.supportsImageInput
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct FavoriteModel: Codable, Hashable, Identifiable, Sendable {
    var provider: AIProvider
    var model: String

    var id: String { "\(provider.rawValue):\(model)" }
}

/// Budget and output truncation defaults for the page browser agent (`WukongMind` M1).
enum BrowserAgentLimits {
    static let defaultMaxSteps = 30
    static let stepRange = 1...200
    static let defaultTruncationLimit = 20_000
    static let truncationRange = 500...500_000

    static func clampSteps(_ value: Int) -> Int {
        min(stepRange.upperBound, max(stepRange.lowerBound, value))
    }

    static func clampTruncationLimit(_ value: Int) -> Int {
        min(truncationRange.upperBound, max(truncationRange.lowerBound, value))
    }
}
