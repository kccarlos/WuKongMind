import XCTest
@testable import WukongMind

/// The fixed prompt every Gemini Live model turn re-bills: the system
/// instruction and the tool declarations (docs/wukongmind/voice-cost.md).
/// Prints the sizes (`[VOICE-PROMPT-SIZE]`) and fails when they grow past
/// the budget, so a longer description is a deliberate choice.
@MainActor
final class VoicePromptSizeTests: XCTestCase {
    /// Characters: WUKO-124 measured 4,288 and 12,734 before its trim and
    /// 4,294 and 9,375 after; these leave a little headroom.
    static let instructionBudget = 4_500
    static let declarationsBudget = 9_800

    func testFixedPromptStaysWithinBudget() throws {
        let app = LiveReplaySupport.makeApp(self)
        let navigator = LiveReplaySupport.fakePage("ordinary", app: app)
        let session = VoiceSession(
            configuration: .init(endpoint: .aiStudio, apiKey: "test"),
            transport: { FakeLiveTransport() },
            audio: FakeVoiceAudio(), navigator: navigator, usage: nil, runsLoop: false
        )
        session.tools.registryBuilder = { app.voiceToolRegistry(browse: $0) }
        let setup = session.setup(handle: nil)
        let instruction = VoiceInstructions.system(answerLength: VoiceSettings().answerLength, eyesFree: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let declarations = session.tools.declarations
        var total = 0
        for declaration in declarations {
            let size = try encoder.encode(declaration).count
            total += size
            print("[VOICE-PROMPT-SIZE] tool \(declaration.name) chars=\(size)")
        }
        let setupSize = try encoder.encode(setup).count
        print("[VOICE-PROMPT-SIZE] instruction chars=\(instruction.count) tools=\(declarations.count) declarations chars=\(total) setup chars=\(setupSize)")
        XCTAssertLessThanOrEqual(instruction.count, Self.instructionBudget)
        XCTAssertLessThanOrEqual(total, Self.declarationsBudget)
    }

    /// Microphone audio billed for two spoken requests with pauses between
    /// them (pink room noise 20 dB below the voice): an ungated stream sends
    /// every second; the capture gate sends speech plus pre-roll and
    /// hangover, and each close adds the comfort noise before
    /// `audioStreamEnd` (voice-cost.md).
    func testMicrophoneSecondsSentForTwoRequests() throws {
        typealias Audio = VADTestAudio
        var clean = [Double](repeating: 0, count: 2 * Audio.rate)
        for voice in ["a", "b"] {
            let speech = try Audio.speech(voice).map(Double.init)
            clean += Audio.scaled(speech, toDBFS: Audio.speechLevelDBFS + (Audio.rmsDB(speech) - Audio.activeLevelDB(speech)))
            clean += [Double](repeating: 0, count: 6 * Audio.rate)
        }
        let noise = Audio.scaled(try Audio.noise(.pink, samples: clean.count), toDBFS: Audio.speechLevelDBFS - 20)
        var vad = VoiceActivityDetector()
        let trace = Audio.run(Audio.pcm(zip(clean, noise).map { $0 + $1 }), vad: &vad)
        let frame = Double(Audio.frameMs) / 1000
        let total = Double(trace.sent.count) * frame
        let speech = Double(Audio.activeFrames(clean).filter { $0 }.count) * frame
        let gated = Double(trace.sent.filter { $0 }.count) * frame
        let comfort = Double(trace.closes.count) * ComfortNoise.duration
        print(String(format: "[VOICE-MIC-SECONDS] stream=%.1f speech=%.1f gated=%.1f closes=%d comfort=%.1f sent=%.1f",
                     total, speech, gated, trace.closes.count, comfort, gated + comfort))
        XCTAssertEqual(trace.opens.count, 2, "One open per request")
        XCTAssertLessThan(gated + comfort, total * 0.5, "The gate sends well under half of an open stream")
    }
}
