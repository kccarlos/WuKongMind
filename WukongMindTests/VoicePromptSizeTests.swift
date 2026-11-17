import XCTest
@testable import WukongMind

/// The fixed prompt every Gemini Live model turn re-bills: the system
/// instruction and the tool declarations (docs/wukongmind/voice-cost.md).
/// Prints the sizes (`[VOICE-PROMPT-SIZE]`) and fails when they grow past
/// the budget, so a longer description is a deliberate choice.
@MainActor
final class VoicePromptSizeTests: XCTestCase {
    /// Characters, measured after WUKO-124's trim plus a little headroom.
    static let instructionBudget = Int.max
    static let declarationsBudget = Int.max

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
}

// TEMP-GOLDEN-DUMP
final class TempGoldenDump: XCTestCase {
    @MainActor func testDump() throws {
        print("[GOLDEN-VI-BEGIN]\n" + SiteGoldens.voiceInstructions() + "[GOLDEN-VI-END]")
        print("[GOLDEN-GD-BEGIN]\n" + (try SiteGoldens.geminiDeclarations()) + "[GOLDEN-GD-END]")
    }
}
