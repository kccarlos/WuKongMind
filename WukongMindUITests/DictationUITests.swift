import XCTest

/// The composer's microphone on the unified panel, with the scripted
/// dictation backend (`-dc-dictation-script`): the simulator cannot speak on
/// its own. Real speech is checked by hand (simulator with the Mac's
/// microphone, iPhone 13) and recorded in the task's proof.
final class DictationUITests: DCUITestCase {
    private let panel = [
        "-dc-browser-agent-fixture-page", "-dc-browser-agent-demo", "empty",
        "-dc-drawer-detent", "medium", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
    ]

    private func openPanel(_ extra: [String]) -> XCUIApplication {
        let app = launch(panel + extra)
        showAssistant(in: app)
        XCTAssertTrue(any(app, "agentEmptyState").waitForExistence(timeout: 20))
        return app
    }

    func testMicrophoneListensFillsTheBoxAndStops() {
        let app = openPanel(["-dc-dictation-script", "make this page dark"])
        let mic = app.buttons["composerMic"].firstMatch
        XCTAssertTrue(waitForHittable(mic, timeout: 15))
        mic.tap()

        // Listening: the ring becomes the cinnabar stop button.
        let stop = app.buttons["composerMicStop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        let input = app.textFields["agentPromptInput"].firstMatch
        XCTAssertTrue(wait(timeout: 10) { (input.value as? String)?.contains("make this page dark") == true },
                      "The transcript never reached the input box: \(String(describing: input.value))")
        capture("dictation-listening")

        // Stop: the text stays, the ring turns into Send.
        stop.tap()
        XCTAssertTrue(app.buttons["agentSendButton"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["composerMicStop"].exists)
        XCTAssertEqual(input.value as? String, "make this page dark")
        capture("dictation-stopped-send")
    }

    func testDeniedMicrophoneIsSaidWithASettingsLink() {
        let app = openPanel(["-dc-dictation-deny", "microphone"])
        let mic = app.buttons["composerMic"].firstMatch
        XCTAssertTrue(waitForHittable(mic, timeout: 15))
        mic.tap()

        let notice = any(app, "dictationNoticeText")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("microphone"), notice.label)
        XCTAssertTrue(app.buttons["dictationOpenSettings"].firstMatch.exists)
        // The mic stays a mic: nothing is disabled.
        XCTAssertTrue(app.buttons["composerMic"].firstMatch.isHittable)
        capture("dictation-denied")

        app.buttons["dictationNoticeDismiss"].firstMatch.tap()
        XCTAssertTrue(waitForGone(notice, timeout: 5))
    }
}
