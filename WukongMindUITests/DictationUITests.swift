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

    /// Real speech through the system recognizer and the Mac's (simulator) or
    /// the phone's microphone. Someone has to talk while it waits:
    /// `TEST_RUNNER_DC_REAL_MIC=1`, then say a sentence.
    func testRealSpeechReachesTheInputBox() throws {
        guard ProcessInfo.processInfo.environment["DC_REAL_MIC"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_DC_REAL_MIC=1 and speak while the test waits.")
        }
        addUIInterruptionMonitor(withDescription: "Permission prompts") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label].firstMatch
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        let app = openPanel([])
        let mic = app.buttons["composerMic"].firstMatch
        XCTAssertTrue(waitForHittable(mic, timeout: 15))
        mic.tap()
        app.tap() // lets the interruption monitor answer the prompts

        let input = app.textFields["agentPromptInput"].firstMatch
        let heard = wait(timeout: 60) {
            if app.alerts.count > 0 { app.tap() }
            return !((input.value as? String) ?? "").isEmpty && (input.value as? String) != "Ask the Agent…" && (input.value as? String) != "Listening…"
        }
        capture("dictation-real-speech")
        attachText(String(describing: input.value), named: "Recognized text")
        XCTAssertTrue(heard, "Nothing was recognized: \(String(describing: input.value)) \(any(app, "dictationNoticeText").exists ? any(app, "dictationNoticeText").label : "")")
    }
}
