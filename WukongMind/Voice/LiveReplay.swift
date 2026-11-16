import Foundation

#if DEBUG
// Recorded Gemini Live sessions, replayed without the network
// (docs/DEVELOPMENT.md "Live Gemini Live budget").
//
// A recording is the server's frames cut into steps, each started by what
// the client sent: the setup, a user turn (typed text or the end of the
// microphone stream), or the response to one recorded tool call. The replay
// sends a step's frames when the session sends its trigger, so it follows
// the session's own pace (the tool-response hold, briefings, watchdog
// nudges) instead of recorded timestamps. Model audio is kept only as a
// short stub per chunk; its real length is in `audioSeconds`.

/// One recorded (or reconstructed) Live session.
struct LiveRecording: Codable, Equatable {
    /// Where it came from: a live capture, or which spike result it was
    /// rebuilt from.
    var source: String
    /// True when the frames were rebuilt from a spike's event log rather
    /// than captured from the wire.
    var reconstructed: Bool
    var model: String
    var name: String
    /// "forum" or "ordinary": the page the session ran on.
    var page: String?
    /// The silent notes the client sent (the page context).
    var notes: [String]
    /// What the user said, in order (one per `turn` step).
    var utterances: [String]
    /// The calls the model made, in order (`name` only).
    var calls: [String]
    var steps: [Step]
    /// Seconds of model audio the stubs stand for (24 kHz PCM16).
    var audioSeconds: Double?

    struct Step: Codable, Equatable {
        var on: Trigger
        /// Raw server frames, as JSON text.
        var frames: [String]
    }

    enum Trigger: Codable, Equatable, Hashable {
        case setup
        /// A user turn: `realtimeInput.text` or `audioStreamEnd`.
        case turn
        /// The function response for the call with this id.
        case toolResponse(String)

        init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            switch text {
            case "setup": self = .setup
            case "turn": self = .turn
            default:
                guard text.hasPrefix("toolResponse:") else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown trigger \(text)"))
                }
                self = .toolResponse(String(text.dropFirst("toolResponse:".count)))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .setup: try container.encode("setup")
            case .turn: try container.encode("turn")
            case .toolResponse(let id): try container.encode("toolResponse:\(id)")
            }
        }

        /// The triggers in one client frame (a frame may answer several calls).
        static func of(_ clientFrame: String) -> [Trigger] {
            guard let object = try? JSONSerialization.jsonObject(with: Data(clientFrame.utf8)) as? [String: Any] else { return [] }
            if object["setup"] != nil { return [.setup] }
            if let input = object["realtimeInput"] as? [String: Any] {
                return input["text"] != nil || input["audioStreamEnd"] != nil ? [.turn] : []
            }
            let responses = (object["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]] ?? []
            return responses.compactMap { ($0["id"] as? String).map(Trigger.toolResponse) }
        }
    }

    /// A short stand-in for one chunk of model audio (10 ms of silence).
    static let audioStub = Data(count: 480).base64EncodedString()

    /// A server frame with every audio payload replaced by `audioStub`, and
    /// the seconds of audio it carried.
    static func stubbingAudio(_ frame: Data) -> (text: String, audioSeconds: Double) {
        guard var root = try? JSONDecoder().decode([String: JSONValue].self, from: frame),
              case .object(var content)? = root["serverContent"],
              case .object(var turn)? = content["modelTurn"],
              case .array(let parts)? = turn["parts"]
        else {
            return (String(decoding: frame, as: UTF8.self), 0)
        }
        var seconds = 0.0
        turn["parts"] = .array(parts.map { part in
            guard case .object(var object) = part, case .object(var inline)? = object["inlineData"],
                  let data = inline["data"]?.stringValue else { return part }
            seconds += Double(Data(base64Encoded: data)?.count ?? 0) / Double(GeminiLive.outputSampleRate * 2)
            inline["data"] = .string(audioStub)
            object["inlineData"] = .object(inline)
            return .object(object)
        })
        content["modelTurn"] = .object(turn)
        root["serverContent"] = .object(content)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(root)).map { String(decoding: $0, as: UTF8.self) } ?? String(decoding: frame, as: UTF8.self)
        return (text, seconds)
    }
}

/// Plays a `LiveRecording` back: each step's frames go out when the session
/// sends that step's trigger. Triggers the recording doesn't expect next are
/// kept in `unexpected` for the test to check.
@MainActor
final class ReplayLiveTransport: LiveTransport {
    let recording: LiveRecording
    private(set) var pending: [LiveRecording.Step]
    private(set) var sent: [String] = []
    private(set) var unexpected: [LiveRecording.Trigger] = []
    private(set) var connects = 0
    let frames: AsyncStream<Data>
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var closeReason: LiveClose?

    init(_ recording: LiveRecording) {
        self.recording = recording
        pending = recording.steps
        var continuation: AsyncStream<Data>.Continuation?
        frames = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    /// The next step waits for a user turn, or nothing is left.
    var isWaitingForUser: Bool { pending.first.map { $0.on == .turn } ?? true }

    func connect(_ request: URLRequest) async throws {
        connects += 1
    }

    func send(_ text: String) {
        sent.append(text)
        for trigger in LiveRecording.Trigger.of(text) {
            guard let next = pending.first, next.on == trigger else {
                // A turn or response the recording has no step for (a briefing
                // id, a watchdog's extra turn, or a call answered twice).
                if !trigger.isBriefing { unexpected.append(trigger) }
                continue
            }
            pending.removeFirst()
            next.frames.forEach { continuation?.yield(Data($0.utf8)) }
        }
    }

    func close() {
        guard closeReason == nil else { return }
        closeReason = LiveClose(code: LiveClose.normalClosure, reason: "closed")
        continuation?.finish()
        continuation = nil
    }
}

/// Wraps a real transport and records the session as a `LiveRecording`
/// (audio stubbed), for a live test to save as a replay fixture.
@MainActor
final class RecordingLiveTransport: LiveTransport {
    private let inner: LiveTransport
    private(set) var steps: [LiveRecording.Step] = []
    private(set) var notes: [String] = []
    private(set) var utterances: [String] = []
    private(set) var calls: [String] = []
    private(set) var audioSeconds = 0.0
    let frames: AsyncStream<Data>
    private var continuation: AsyncStream<Data>.Continuation?
    private var pump: Task<Void, Never>?

    init(_ inner: LiveTransport) {
        self.inner = inner
        var continuation: AsyncStream<Data>.Continuation?
        frames = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    var closeReason: LiveClose? { inner.closeReason }

    func connect(_ request: URLRequest) async throws {
        try await inner.connect(request)
        let source = inner.frames
        pump = Task { @MainActor [weak self] in
            for await frame in source { self?.received(frame) }
            self?.continuation?.finish()
        }
    }

    func send(_ text: String) {
        for trigger in LiveRecording.Trigger.of(text) where !(trigger.isBriefing) {
            steps.append(.init(on: trigger, frames: []))
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            if let input = object["realtimeInput"] as? [String: Any], let typed = input["text"] as? String {
                utterances.append(typed)
            } else if let content = object["clientContent"] as? [String: Any], content["turnComplete"] as? Bool == false,
                      let note = ((content["turns"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String {
                notes.append(note)
            }
        }
        inner.send(text)
    }

    func close() {
        inner.close()
    }

    private func received(_ frame: Data) {
        var stubbed = LiveRecording.stubbingAudio(frame)
        // Resumption handles are live credentials for a while: never keep them.
        if stubbed.text.contains("newHandle"), var root = try? JSONDecoder().decode([String: JSONValue].self, from: Data(stubbed.text.utf8)),
           case .object(var update)? = root["sessionResumptionUpdate"] {
            update["newHandle"] = "handle-stub"
            root["sessionResumptionUpdate"] = .object(update)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(root) { stubbed.text = String(decoding: data, as: UTF8.self) }
        }
        audioSeconds += stubbed.audioSeconds
        if let message = GeminiLive.decode(frame) { calls += message.toolCalls.map(\.name) }
        if steps.isEmpty { steps.append(.init(on: .setup, frames: [])) }
        steps[steps.count - 1].frames.append(stubbed.text)
        continuation?.yield(frame)
    }

    func recording(name: String, source: String, model: String, page: String?) -> LiveRecording {
        LiveRecording(
            source: source, reconstructed: false, model: model, name: name, page: page, notes: notes,
            utterances: utterances, calls: calls, steps: steps, audioSeconds: (audioSeconds * 100).rounded() / 100
        )
    }
}

private extension LiveRecording.Trigger {
    /// Briefings are function responses under made-up `b-` ids.
    var isBriefing: Bool {
        if case .toolResponse(let id) = self { return id.hasPrefix("b-") }
        return false
    }
}
#endif
