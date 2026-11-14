import Foundation

/// One real Gemini Live connection through the app's `WebSocketLiveTransport` and `GeminiLive`
/// encode/decode. It records a timestamped event log (never audio bytes, never headers).
@MainActor
final class LiveClient {
    struct Event: Codable { var t: Double; var kind: String; var text: String }

    static var apiKey: String { ProcessInfo.processInfo.environment["SPIKE_GEMINI_KEY"] ?? "" }

    let transport = WebSocketLiveTransport()
    private let start = Date()
    private(set) var events: [Event] = []
    private(set) var calls: [GeminiLive.FunctionCall] = []
    private(set) var setupCompleteAt: Double?
    private(set) var audioTimes: [Double] = []
    private(set) var turnCompleteTimes: [Double] = []
    private(set) var output = ""
    private(set) var handle: String?
    private(set) var resumable = false
    private(set) var usage: GeminiLive.Usage?
    private(set) var close: LiveClose?
    private var pump: Task<Void, Never>?

    var now: Double { Date().timeIntervalSince(start) }

    func log(_ kind: String, _ text: String = "") { events.append(Event(t: (now * 1000).rounded() / 1000, kind: kind, text: text)) }

    /// The setup frame: the app's `Setup` encoding, with the declarations replaced by `declarations`.
    static func setupFrame(instructions: String, declarations: [JSONValue], handle: String? = nil) throws -> String {
        let setup = GeminiLive.Setup(endpoint: .aiStudio, voice: nil, instructions: instructions, functions: [], resumptionHandle: handle)
        let text = try GeminiLive.encode(.setup(setup))
        guard case .object(var root) = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              case .object(var body)? = root["setup"] else { return text }
        body["tools"] = [["functionDeclarations": .array(declarations)]]
        root["setup"] = .object(body)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(JSONValue.object(root)), as: UTF8.self)
    }

    /// Connects and sends the setup; true once `setupComplete` arrives, false on a close or timeout.
    func connect(setup: String, timeout: Double = 20) async -> Bool {
        do {
            try await transport.connect(GeminiLive.Endpoint.aiStudio.request(apiKey: Self.apiKey))
        } catch {
            log("connect-failed", error.localizedDescription)
            return false
        }
        log("open")
        pump = Task { [weak self] in
            guard let frames = self?.transport.frames else { return }
            for await frame in frames { self?.handle(frame) }
            guard let self else { return }
            self.close = self.transport.closeReason
            self.log("close", "\(self.close?.code.map(String.init) ?? "nil") \(self.close?.reason ?? "")")
        }
        transport.send(setup)
        log("setup-sent", "\(setup.utf8.count) bytes")
        return await wait(timeout) { self.setupCompleteAt != nil || self.close != nil } && setupCompleteAt != nil
    }

    private func handle(_ frame: Data) {
        guard let message = GeminiLive.decode(frame) else { return log("undecodable", String(decoding: frame.prefix(300), as: UTF8.self)) }
        if message.setupComplete { setupCompleteAt = now; log("setupComplete") }
        if !message.audio.isEmpty {
            if audioTimes.count <= turnCompleteTimes.count { log("audio-start") }
            audioTimes.append(now)
        }
        if let t = message.inputTranscription { log("in", t.text) }
        if let t = message.outputTranscription { output += t.text }
        if message.interrupted { log("interrupted") }
        for call in message.toolCalls {
            calls.append(call)
            let args = (try? JSONEncoder().encode(call.args)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            log("call", "\(call.name) \(args)")
        }
        if !message.cancelledCalls.isEmpty { log("cancelled", message.cancelledCalls.joined(separator: ",")) }
        if message.turnComplete {
            turnCompleteTimes.append(now)
            log("turnComplete", output)
            output = ""
        }
        if let r = message.resumption {
            if let h = r.handle { handle = h }
            resumable = r.resumable
        }
        if let u = message.usage { usage = u; log("usage", "prompt \(u.promptTokens) response \(u.responseTokens)") }
        if let g = message.goAway { log("goAway", "\(g)") }
    }

    func say(_ text: String) { log("user", text); transport.send(try! GeminiLive.encode(.text(text))) }
    func note(_ text: String) { log("note", text); transport.send(try! GeminiLive.encode(.content(text, turnComplete: false))) }

    func respond(_ call: GeminiLive.FunctionCall, _ response: [String: JSONValue], _ scheduling: GeminiLive.Scheduling) {
        respond(id: call.id, name: call.name, response, scheduling)
    }

    func respond(id: String, name: String, _ response: [String: JSONValue], _ scheduling: GeminiLive.Scheduling) {
        let frame = try! GeminiLive.encode(.toolResponse([.init(id: id, name: name, response: response, scheduling: scheduling)]))
        log("response", "\(name) \(scheduling.rawValue) \(frame.utf8.count) bytes")
        transport.send(frame)
    }

    /// All transcribed model speech so far, finished turns included.
    var spoken: String { events.filter { $0.kind == "turnComplete" }.map(\.text).joined(separator: " ") + output }

    func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = now + seconds
        while now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Waits for the next tool call after `count` calls, or a finished turn with none.
    func nextCall(after count: Int, timeout: Double = 25) async -> GeminiLive.FunctionCall? {
        let turns = turnCompleteTimes.count
        _ = await wait(timeout) { self.calls.count > count || self.turnCompleteTimes.count > turns || self.close != nil }
        // A spoken acknowledgement can finish its turn just before the call arrives.
        if calls.count <= count, close == nil { _ = await wait(3) { self.calls.count > count } }
        return calls.count > count ? calls[count] : nil
    }

    func shutdown() { transport.close(); pump?.cancel() }
}
