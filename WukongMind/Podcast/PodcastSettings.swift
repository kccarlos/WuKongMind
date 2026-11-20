import Foundation

// MARK: - Read-aloud speech settings

/// Speaker slot for TTS synthesis.
enum PodcastSpeaker: String, Codable, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"

    var id: String { rawValue }

    /// The delivery style sent with each turn (`speech_metadata.style`).
    var speechStyle: String {
        switch self {
        case .a: "warm, clear and unhurried, like a morning radio host"
        case .b: "curious and relaxed, conversational"
        }
    }
}

/// Which speech engine reads text aloud.
enum PodcastEngineChoice: String, Codable, CaseIterable, Identifiable {
    /// Google's voices when a Gemini or Vertex key is there, otherwise the device's.
    case automatic
    /// Gemini TTS.
    case google
    /// `AVSpeechSynthesizer`: free and offline.
    case onDevice = "ondevice"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .google: String(localized: "Google voices", comment: "Speech engine setting: Gemini text-to-speech")
        case .onDevice: String(localized: "On-device voices", comment: "Speech engine setting: the iPhone's built-in voices")
        }
    }
}

struct PodcastSettings: Codable, Equatable {
    /// Gemini prebuilt voice (`VoiceCatalog`) used for read aloud.
    var voiceA = PodcastSettings.defaultVoiceA
    var engine: PodcastEngineChoice = .automatic

    static let defaultVoiceA = "Kore"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case voiceA, engine
    }

    // Each field falls back on its own, like `VoiceSettings`; legacy keys
    // (`hostA`, `hostB`, `voiceB`, `minutesPerChapter`) are ignored on decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        let known = Set(VoiceCatalog.voices.map(\.name))
        let a = value(.voiceA, Self.defaultVoiceA)
        voiceA = known.contains(a) ? a : Self.defaultVoiceA
        engine = value(.engine, .automatic)
    }
}

/// The Gemini voice of each speaker.
struct PodcastVoices: Codable, Equatable {
    var a: String
    var b: String

    func voice(_ speaker: PodcastSpeaker) -> String {
        speaker == .a ? a : b
    }
}

// MARK: - Engine selection

/// The engine a read-aloud uses.
enum PodcastEngineKind: String, Codable, Equatable {
    /// Gemini TTS through Google AI Studio (the Gemini key).
    case aiStudio
    /// Gemini TTS through Vertex AI (the Vertex key).
    case vertex
    case onDevice = "ondevice"
    /// The UI tests' engine (`-dc-podcast-fake`): silent audio, no network.
    case fake

    var provider: VoiceProvider? {
        switch self {
        case .aiStudio: .aiStudio
        case .vertex: .vertex
        case .onDevice, .fake: nil
        }
    }

    init(_ provider: VoiceProvider) {
        self = provider == .vertex ? .vertex : .aiStudio
    }

    var label: String {
        switch self {
        case .aiStudio, .vertex: PodcastEngineChoice.google.label
        case .onDevice, .fake: PodcastEngineChoice.onDevice.label
        }
    }
}

enum PodcastEngineSelection: Equatable {
    case engine(PodcastEngineKind)
    /// Google voices were asked for, and neither Google key is saved.
    case needsKey
}

enum PodcastEngineSelector {
    /// - `providers`: the Google providers with a key, preferred first.
    static func select(
        choice: PodcastEngineChoice,
        providers: [VoiceProvider]
    ) -> PodcastEngineSelection {
        if choice == .onDevice { return .engine(.onDevice) }
        guard let provider = providers.first else {
            return choice == .google ? .needsKey : .engine(.onDevice)
        }
        return .engine(PodcastEngineKind(provider))
    }
}
