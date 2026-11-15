import SwiftUI
import UIKit
import Vision
import XCTest
@testable import WukongMind

/// The composer's dictation: the state machine as a pure value, the
/// controller against a scripted backend, and how the transcript joins the
/// text already in the box.
final class DictationTests: XCTestCase {
    // MARK: State machine

    private func machine(after events: [DictationMachine.Event]) -> DictationMachine {
        var machine = DictationMachine()
        for event in events { _ = machine.send(event) }
        return machine
    }

    func testTapAsksForPermissionThenListens() {
        var machine = DictationMachine()
        XCTAssertEqual(machine.send(.tap(voiceBusy: false)), [.requestPermission])
        XCTAssertEqual(machine.phase, .requesting)
        XCTAssertTrue(machine.isBusy)
        XCTAssertEqual(machine.send(.permission(.granted)), [.startRecognition])
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertTrue(machine.isListening)
    }

    func testUpdatesReplaceTheTranscript() {
        let machine = machine(after: [.tap(voiceBusy: false), .permission(.granted), .update("hello"), .update("hello world")])
        XCTAssertEqual(machine.transcript, "hello world")
    }

    func testStopFinishesAndKeepsTheLastWords() {
        var machine = machine(after: [.tap(voiceBusy: false), .permission(.granted), .update("summarize")])
        XCTAssertEqual(machine.send(.tap(voiceBusy: false)), [.finishRecognition])
        XCTAssertEqual(machine.phase, .finishing)
        XCTAssertFalse(machine.isBusy)
        _ = machine.send(.update("summarize this thread"))
        _ = machine.send(.ended(nil))
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.transcript, "summarize this thread")
        XCTAssertNil(machine.failure)
    }

    func testStoppingWithoutSpeechIsNotAFailure() {
        let machine = machine(after: [.tap(voiceBusy: false), .permission(.granted), .tap(voiceBusy: false), .ended(.noSpeech)])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.failure)
    }

    func testSilenceEndingByItselfSaysSo() {
        let machine = machine(after: [.tap(voiceBusy: false), .permission(.granted), .ended(nil)])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.failure, .noSpeech)
    }

    func testAnErrorAfterWordsKeepsTheWords() {
        let machine = machine(after: [.tap(voiceBusy: false), .permission(.granted), .update("open the thread"), .ended(.audio)])
        XCTAssertEqual(machine.transcript, "open the thread")
        XCTAssertNil(machine.failure)
    }

    func testAnErrorWithoutWordsIsSaid() {
        let machine = machine(after: [.tap(voiceBusy: false), .permission(.granted), .ended(.audio)])
        XCTAssertEqual(machine.failure, .audio)
    }

    func testBrokenMicrophoneWhileFinishingIsStillSaid() {
        let machine = machine(after: [.tap(voiceBusy: false), .permission(.granted), .tap(voiceBusy: false), .ended(.audio)])
        XCTAssertEqual(machine.failure, .audio)
    }

    func testDeniedPermissionsAreSaidWithSettings() {
        for (permission, failure) in [
            (DictationPermission.microphoneDenied, DictationFailure.microphoneDenied),
            (.speechDenied, .speechDenied),
            (.unavailable, .unavailable)
        ] {
            var machine = DictationMachine()
            _ = machine.send(.tap(voiceBusy: false))
            XCTAssertEqual(machine.send(.permission(permission)), [])
            XCTAssertEqual(machine.phase, .idle)
            XCTAssertEqual(machine.failure, failure)
        }
        XCTAssertTrue(DictationFailure.microphoneDenied.offersSettings)
        XCTAssertTrue(DictationFailure.speechDenied.offersSettings)
        XCTAssertFalse(DictationFailure.noSpeech.offersSettings)
        XCTAssertFalse(DictationFailure.unavailable.offersSettings)
    }

    func testEveryFailureHasOneShortSentence() {
        for failure in [DictationFailure.microphoneDenied, .speechDenied, .unavailable, .voiceBusy, .noSpeech, .audio] {
            XCTAssertFalse(failure.message.isEmpty)
            XCTAssertLessThan(failure.message.count, 90, "\(failure)")
        }
    }

    func testVoiceSessionBlocksDictation() {
        var machine = DictationMachine()
        XCTAssertEqual(machine.send(.tap(voiceBusy: true)), [])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.failure, .voiceBusy)
    }

    func testTappingAgainClearsTheLastFailure() {
        var machine = machine(after: [.tap(voiceBusy: false), .permission(.microphoneDenied)])
        XCTAssertNotNil(machine.failure)
        _ = machine.send(.tap(voiceBusy: false))
        XCTAssertNil(machine.failure)
        XCTAssertEqual(machine.transcript, "")
    }

    func testDismissClearsTheFailure() {
        var machine = machine(after: [.tap(voiceBusy: false), .permission(.speechDenied)])
        _ = machine.send(.dismissFailure)
        XCTAssertNil(machine.failure)
    }

    func testCancelStopsListeningAtOnce() {
        var machine = machine(after: [.tap(voiceBusy: false), .permission(.granted), .update("hi")])
        XCTAssertEqual(machine.send(.cancel), [.cancelRecognition])
        XCTAssertEqual(machine.phase, .idle)
        // Late callbacks do nothing.
        XCTAssertEqual(machine.send(.update("hi there")), [])
        XCTAssertEqual(machine.send(.ended(nil)), [])
        XCTAssertEqual(machine.transcript, "hi")
        XCTAssertNil(machine.failure)
    }

    func testTapWhileRequestingGivesUpAndLatePermissionIsIgnored() {
        var machine = machine(after: [.tap(voiceBusy: false), .tap(voiceBusy: false)])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.send(.permission(.granted)), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testTapWhileFinishingDoesNothing() {
        var machine = machine(after: [.tap(voiceBusy: false), .permission(.granted), .tap(voiceBusy: false)])
        XCTAssertEqual(machine.send(.tap(voiceBusy: false)), [])
        XCTAssertEqual(machine.phase, .finishing)
    }

    // MARK: Joining text

    func testTranscriptJoinsTheTypedText() {
        XCTAssertEqual(DictationText.joined(base: "", transcript: "hello"), "hello")
        XCTAssertEqual(DictationText.joined(base: "Please", transcript: "summarize"), "Please summarize")
        XCTAssertEqual(DictationText.joined(base: "Please ", transcript: "summarize"), "Please summarize")
        XCTAssertEqual(DictationText.joined(base: "Please", transcript: ""), "Please")
    }

    // MARK: Recognizer language

    func testRecognizerFollowsTheInterfaceLanguage() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(SystemDictationBackend.recognizerLocale(appLanguage: "zh-Hans", current: us).identifier, "zh-CN")
        XCTAssertEqual(SystemDictationBackend.recognizerLocale(appLanguage: "zh-Hant", current: us).identifier, "zh-TW")
        XCTAssertEqual(SystemDictationBackend.recognizerLocale(appLanguage: "zh-Hant", current: Locale(identifier: "zh_HK")).identifier, "zh-HK")
        XCTAssertEqual(SystemDictationBackend.recognizerLocale(appLanguage: "en", current: Locale(identifier: "en_GB")).identifier, "en_GB")
        XCTAssertEqual(SystemDictationBackend.recognizerLocale(appLanguage: "en", current: Locale(identifier: "fr_FR")).identifier, "en-US")
    }

    // MARK: Controller

    @MainActor
    private func makeController(
        words: [String] = ["summarize", "this", "thread"],
        permission: DictationPermission = .granted
    ) -> (DictationController, ScriptedDictationBackend) {
        let backend = ScriptedDictationBackend(words: words, permission: permission, interval: .zero)
        return (DictationController(backend: backend), backend)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition not reached", file: file, line: line)
    }

    @MainActor
    func testControllerListensAndDeliversTheTranscript() async {
        let (controller, backend) = makeController()
        controller.toggle(voiceBusy: false)
        XCTAssertEqual(controller.phase, .requesting)
        await waitUntil { controller.isListening }
        XCTAssertEqual(backend.startCount, 1)
        backend.step()
        backend.step()
        XCTAssertEqual(controller.transcript, "summarize this")
        controller.toggle(voiceBusy: false)
        XCTAssertEqual(backend.finishCount, 1)
        // The scripted backend ends right after `finish`.
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.transcript, "summarize this")
        XCTAssertNil(controller.failure)
    }

    @MainActor
    func testControllerSaysADeniedMicrophoneAndNeverStarts() async {
        let (controller, backend) = makeController(permission: .microphoneDenied)
        controller.toggle(voiceBusy: false)
        await waitUntil { controller.failure != nil }
        XCTAssertEqual(controller.failure, .microphoneDenied)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(backend.startCount, 0)
        controller.dismissFailure()
        XCTAssertNil(controller.failure)
    }

    @MainActor
    func testControllerCancelStopsTheBackendAndIgnoresLaterWords() async {
        let (controller, backend) = makeController()
        controller.toggle(voiceBusy: false)
        await waitUntil { controller.isListening }
        backend.step()
        controller.cancel()
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(controller.phase, .idle)
        backend.step()
        XCTAssertEqual(controller.transcript, "summarize")
    }

    @MainActor
    func testControllerGivesUpWhenTheLastWordsNeverCome() async {
        let backend = HangingFinishBackend()
        let controller = DictationController(backend: backend)
        controller.finishTimeout = .milliseconds(30)
        controller.toggle(voiceBusy: false)
        await waitUntil { controller.isListening }
        backend.onUpdate?("almost")
        controller.toggle(voiceBusy: false)
        XCTAssertEqual(controller.phase, .finishing)
        await waitUntil { controller.phase == .idle }
        XCTAssertEqual(controller.transcript, "almost")
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertNil(controller.failure)
    }

    @MainActor
    func testControllerRefusesWhileAVoiceSessionRuns() {
        let (controller, backend) = makeController()
        controller.toggle(voiceBusy: true)
        XCTAssertEqual(controller.failure, .voiceBusy)
        XCTAssertEqual(backend.startCount, 0)
    }

    @MainActor
    func testControllerStartsAgainAfterAFinishedRun() async {
        let (controller, backend) = makeController()
        for _ in 0..<2 {
            controller.toggle(voiceBusy: false)
            await waitUntil { controller.isListening }
            backend.step()
            controller.toggle(voiceBusy: false)
            XCTAssertEqual(controller.phase, .idle)
        }
        XCTAssertEqual(backend.startCount, 2)
    }

    @MainActor
    func testComposerPlaceholderDoesNotOverlapAfterRunFinishes() async throws {
        let model = ComposerHarnessModel()
        let rect = CGRect(x: 0, y: 0, width: 390, height: 180)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: rect)
        let host = UIHostingController(rootView: ComposerHarnessView(model: model).environment(\.colorScheme, .light))
        host.overrideUserInterfaceStyle = .light
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.frame = rect
        window.makeKeyAndVisible()
        host.beginAppearanceTransition(true, animated: false)
        host.endAppearanceTransition()
        defer {
            host.beginAppearanceTransition(false, animated: false)
            host.endAppearanceTransition()
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
        }

        func snapshot(_ name: String) -> [String] {
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { ctx in
                if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                    host.view.layer.render(in: ctx.cgContext)
                }
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            guard let cg = image.cgImage else { return [] }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }

        try await Task.sleep(for: .milliseconds(250))
        _ = snapshot("composer-0-idle")

        model.isRunning = true
        try await Task.sleep(for: .milliseconds(300))
        let runningOCR = snapshot("composer-1-running")
        XCTAssertEqual(runningOCR.filter { $0.contains("Write your next message") }.count, 1, "\(runningOCR)")

        model.isRunning = false
        try await Task.sleep(for: .milliseconds(40))
        let midOCR = snapshot("composer-2-just-finished-40ms")
        XCTAssertEqual(midOCR.filter { $0.contains("Ask the Agent") }.count, 1, "Placeholder overlapped right after run finished: \(midOCR)")
        XCTAssertFalse(midOCR.joined(separator: " ").localizedCaseInsensitiveContains("message"), "Running placeholder overlapped idle placeholder: \(midOCR)")

        try await Task.sleep(for: .milliseconds(350))
        let afterOCR = snapshot("composer-3-settled")
        XCTAssertEqual(afterOCR.filter { $0.contains("Ask the Agent") }.count, 1, "\(afterOCR)")
    }
}

@MainActor
private final class ComposerHarnessModel: ObservableObject {
    @Published var draft = ""
    @Published var isRunning = false
}

private struct ComposerHarnessView: View {
    @ObservedObject var model: ComposerHarnessModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.space2) {
            if model.isRunning {
                Text(verbatim: "Step 1").transition(.opacity)
            } else {
                Text(verbatim: "Summarize this page").transition(.opacity)
            }
            AssistantComposer(draft: $model.draft, focused: $focused, isRunning: model.isRunning, onSend: {}, onStop: {})
        }
        .padding(14)
        .frame(width: 390)
        .background(DCTheme.ground)
        .animation(DCMotion.quick, value: model.isRunning)
    }
}

/// A backend whose `finish` never delivers an end.
@MainActor
private final class HangingFinishBackend: DictationBackend {
    var onUpdate: (@MainActor (String) -> Void)?
    private(set) var cancelCount = 0

    func requestPermission() async -> DictationPermission { .granted }
    func start(onUpdate: @escaping @MainActor (String) -> Void, onEnd: @escaping @MainActor (DictationFailure?) -> Void) {
        self.onUpdate = onUpdate
    }
    func finish() {}
    func cancel() { cancelCount += 1 }
}
