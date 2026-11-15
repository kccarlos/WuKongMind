import UIKit
import XCTest

/// Voice anywhere live acceptance (WUKO-84, `docs/wukongmind/voice-review.md` §5 "### 6.").
///
/// Runs all seven Done-when checks in one uninterrupted `VoiceSession` using real
/// synthesized 16 kHz PCM16 speech frames (`-dc-voice-speak-typed`) through `CaptureGate`
/// (`textFramesSent == 0`), trying `VERTEX_API_KEY` first and falling back to
/// `GEMINI_LIVE_KEY` if Vertex refuses or lacks a project. Uses `claude-haiku-5-5`
/// for summaries and Agent hand-offs. Never writes to saved app state or Keychain.
/// On the shared phone, run only through `scripts/device-check.sh`.
final class VoiceAnywhereLiveAcceptanceUITests: DCUITestCase {
    private static let anthropicModel = "claude-haiku-5-5"

    private struct Telemetry: Decodable {
        struct ToolEvent: Decodable {
            var name: String
            var status: String
            var shown: String
        }

        var sessionCount: Int
        var connectionSerial: Int
        var endpoint: String
        var geminiModel: String
        var agentModel: String
        var summaryModel: String
        var audioBackend: String
        var state: String
        var failure: String
        var isInjectingSpeech: Bool
        var utterancesInjected: Int
        var micFramesSent: Int
        var audioFramesSent: Int
        var textFramesSent: Int
        var audioBytesPlayed: Int
        var turnCompleteCount: Int
        var lastUserText: String
        var lastModelText: String
        var userTurns: [String]
        var modelTurns: [String]
        var toolEvents: [ToolEvent]
        var briefingKinds: [String]
        var isHandingOff: Bool
        var agentIsRunning: Bool
        var agentRunCount: Int
        var lastAgentRunState: String
        var podcastPlaying: Bool
        var podcastState: String
        var podcastTime: Double
        var pageURL: String
        var pageHost: String
        var pageTitle: String
        var isForum: Bool
        var cardsCount: Int
        var cardsVisible: Bool
        var probeRevision: Int
        var visibleLinkCount: Int
        var thirdLinkText: String
        var thirdLinkURL: String
        var headlinePhrase: String
        var headlineText: String
        var headlineURL: String
        var pageLuminance: Double
        var pageBg: String
    }

    private var anthropicKey: String {
        (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var vertexKey: String {
        (ProcessInfo.processInfo.environment["VERTEX_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var vertexBaseURL: String {
        (ProcessInfo.processInfo.environment["VERTEX_BASE_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var vertexProject: String {
        (ProcessInfo.processInfo.environment["VERTEX_PROJECT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var geminiKey: String {
        let live = (ProcessInfo.processInfo.environment["GEMINI_LIVE_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { return live }
        return (ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testVoiceAnywhereOneSession() throws {
        guard !anthropicKey.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_ANTHROPIC_API_KEY to run the live voice acceptance check.")
        }
        guard !vertexKey.isEmpty || !geminiKey.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_VERTEX_API_KEY or TEST_RUNNER_GEMINI_LIVE_KEY to run the live voice acceptance check.")
        }
        try requireNetwork()

        var log: [String] = []
        log.append("device: \(UIDevice.current.name) (\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion))")

        var app: XCUIApplication!
        defer {
            if let app {
                let rawState = any(app, "voiceAcceptanceState").label
                if !rawState.isEmpty {
                    saveEvidenceText(rawState, named: "voice-final-telemetry.json")
                }
            }
            saveEvidenceText(log.joined(separator: "\n") + "\n", named: "voice-anywhere-summary.txt")
        }
        if !vertexKey.isEmpty {
            let probeApp = launchVoiceApp(provider: "vertex", includeVertex: true, includeGemini: false)
            try waitForInitialForum(in: probeApp)
            startVoice(in: probeApp)
            let settled = wait(timeout: 18) {
                self.allowMicrophoneIfPrompted()
                guard let snap = self.telemetry(in: probeApp) else { return false }
                return snap.state == "listening" || snap.state == "speaking" || snap.state == "failed" || !snap.failure.isEmpty
            }
            let vertexSnap = telemetry(in: probeApp)
            if settled, let vertexSnap, vertexSnap.state == "listening" || vertexSnap.state == "speaking" {
                log.append("gemini_provider_probe: VERTEX_API_KEY succeeded (endpoint=\(vertexSnap.endpoint))")
                app = probeApp
            } else {
                let reason = vertexSnap?.failure.isEmpty == false
                    ? vertexSnap!.failure
                    : "state=\(vertexSnap?.state ?? "missing")"
                log.append("gemini_provider_probe: VERTEX_API_KEY tried first -> failed (\(reason)); falling back to GEMINI_LIVE_KEY (aiStudio)")
                probeApp.terminate()
                guard !geminiKey.isEmpty else {
                    XCTFail("VERTEX_API_KEY failed (\(reason)) and GEMINI_LIVE_KEY is not set.")
                    return
                }
                app = launchVoiceApp(provider: "aistudio", includeVertex: false, includeGemini: true)
                try waitForInitialForum(in: app)
                startVoice(in: app)
            }
        } else {
            log.append("gemini_provider_probe: VERTEX_API_KEY not provided; using GEMINI_LIVE_KEY (aiStudio)")
            app = launchVoiceApp(provider: "aistudio", includeVertex: false, includeGemini: true)
            try waitForInitialForum(in: app)
            startVoice(in: app)
        }

        // Wait for the single voice session to connect and settle into Listening.
        var connected = wait(timeout: 25) {
            self.allowMicrophoneIfPrompted()
            guard let snap = self.telemetry(in: app) else { return false }
            return snap.sessionCount == 1 && (snap.state == "listening" || snap.state == "failed")
        }
        if telemetry(in: app)?.state != "listening" {
            app.terminate()
            RunLoop.current.run(until: Date().addingTimeInterval(3.0))
            let useVertex = !vertexKey.isEmpty
            app = launchVoiceApp(provider: useVertex ? "vertex" : "aistudio", includeVertex: useVertex, includeGemini: !useVertex)
            try waitForInitialForum(in: app)
            startVoice(in: app)
            connected = wait(timeout: 30) {
                self.allowMicrophoneIfPrompted()
                guard let snap = self.telemetry(in: app) else { return false }
                return snap.sessionCount == 1 && snap.state == "listening"
            }
        }
        guard connected, let startSnap = telemetry(in: app), startSnap.state == "listening" else {
            let snap = telemetry(in: app)
            saveEvidenceScreenshot(named: "voice-connect-failure")
            XCTFail("Voice session did not reach listening (state=\(snap?.state ?? "nil"), failure=\(snap?.failure ?? "nil")).")
            return
        }
        // Let any initial greeting settle if one arrives right after setupComplete.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        _ = waitForQuietListening(in: app, timeout: 15)
        saveEvidenceScreenshot(named: "voice-00-forum-listening")
        log.append("session_started: endpoint=\(startSnap.endpoint) geminiModel=\(startSnap.geminiModel) agentModel=\(startSnap.agentModel) summaryModel=\(startSnap.summaryModel) audioBackend=\(startSnap.audioBackend) page=\(startSnap.pageURL)")

        // ------------------------------------------------------------------
        // 1. From a forum: "open bbc.com" opens it in a few seconds, no Agent
        // ------------------------------------------------------------------
        let beforeOpenBBC = try requireTelemetry(in: app)
        let tOpenBBC = Date()
        speak("Open BBC dot com.", in: app, afterUtterances: beforeOpenBBC.utterancesInjected)
        let openedBBC = wait(timeout: 30) {
            guard let s = self.telemetry(in: app) else { return false }
            let hasOpen = s.toolEvents.dropFirst(beforeOpenBBC.toolEvents.count).contains {
                $0.name == "open_page" && $0.status == "opened"
            }
            return hasOpen && s.pageHost.contains("bbc.") && s.state == "listening" && !s.isInjectingSpeech
        }
        let bbcSnap = try requireTelemetry(in: app)
        let openBBCElapsed = Date().timeIntervalSince(tOpenBBC)
        saveEvidenceScreenshot(named: "voice-01-open-bbc")
        XCTAssertTrue(openedBBC, "Expected open_page -> bbc.com; host=\(bbcSnap.pageHost), user=\(bbcSnap.lastUserText), reply=\(bbcSnap.lastModelText), tools=\(bbcSnap.toolEvents.map { "\($0.name):\($0.status)" })")
        XCTAssertEqual(bbcSnap.sessionCount, 1, "Voice session restarted.")
        XCTAssertEqual(bbcSnap.textFramesSent, 0, "Must use spoken audio frames only.")
        XCTAssertGreaterThan(bbcSnap.micFramesSent, 0, "Expected spoken microphone frames.")
        XCTAssertEqual(bbcSnap.agentRunCount, 0, "open bbc.com must not start an Agent run.")
        log.append(String(format: "check_1_open_bbc: PASS (%.1fs, host=%@, user=%@, reply=%@, agentRuns=%d)",
                          openBBCElapsed, bbcSnap.pageHost, bbcSnap.lastUserText, bbcSnap.lastModelText, bbcSnap.agentRunCount))

        // Give BBC headlines a brief moment to finish DOM layout.
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        _ = waitForQuietListening(in: app, timeout: 15)

        // ------------------------------------------------------------------
        // 2a. On bbc.com: "what's this page about" answers
        // ------------------------------------------------------------------
        let beforeAbout = try requireTelemetry(in: app)
        speak("What's this page about?", in: app, afterUtterances: beforeAbout.utterancesInjected)
        let answeredAbout = wait(timeout: 55) {
            guard let s = self.telemetry(in: app) else { return false }
            let newTools = s.toolEvents.dropFirst(beforeAbout.toolEvents.count)
            let usedSummaryTool = newTools.contains { $0.name == "summarize_topic" || $0.name == "read_page" }
            let spokeAnswer = s.modelTurns.count > beforeAbout.modelTurns.count && s.audioBytesPlayed > beforeAbout.audioBytesPlayed
            return usedSummaryTool && spokeAnswer && s.state == "listening" && !s.isInjectingSpeech
        }
        let aboutSnap = try requireTelemetry(in: app)
        saveEvidenceScreenshot(named: "voice-02a-whats-this-page-about")
        XCTAssertTrue(answeredAbout, "Expected spoken page summary; tools=\(aboutSnap.toolEvents.map(\.name)), reply=\(aboutSnap.lastModelText)")
        XCTAssertEqual(aboutSnap.sessionCount, 1)
        XCTAssertEqual(aboutSnap.agentRunCount, 0, "what's this page about must not run BrowserAgent.")
        log.append("check_2a_whats_this_page_about: PASS (tools=\(aboutSnap.toolEvents.dropFirst(beforeAbout.toolEvents.count).map(\.name)), user=\(aboutSnap.lastUserText), reply=\(aboutSnap.lastModelText))")

        // ------------------------------------------------------------------
        // 2b. On bbc.com: "read it to me" answers and plays
        // ------------------------------------------------------------------
        let beforeRead = try requireTelemetry(in: app)
        speak("Read it to me.", in: app, afterUtterances: beforeRead.utterancesInjected)
        var sawPodcastPlaying = false
        var peakPodcastTime = 0.0
        let startedReadAloud = wait(timeout: 55) {
            guard let s = self.telemetry(in: app) else { return false }
            if s.podcastPlaying { sawPodcastPlaying = true }
            if s.podcastTime > peakPodcastTime { peakPodcastTime = s.podcastTime }
            let calledReadAloud = s.toolEvents.dropFirst(beforeRead.toolEvents.count).contains {
                $0.name == "read_aloud" && $0.status == "started"
            }
            let spokeConfirmation = s.audioBytesPlayed > beforeRead.audioBytesPlayed
            return calledReadAloud && sawPodcastPlaying && peakPodcastTime >= 0.15 && spokeConfirmation && s.state == "listening"
        }
        let readSnap = try requireTelemetry(in: app)
        saveEvidenceScreenshot(named: "voice-02b-read-it-to-me")
        XCTAssertTrue(startedReadAloud, "Expected read_aloud to answer and play; podcastState=\(readSnap.podcastState), time=\(peakPodcastTime), tools=\(readSnap.toolEvents.map { "\($0.name):\($0.status)" })")
        XCTAssertEqual(readSnap.sessionCount, 1)
        XCTAssertEqual(readSnap.agentRunCount, 0)
        log.append(String(format: "check_2b_read_it_to_me: PASS (podcastPlayed=%@, peakTime=%.2fs, user=%@, reply=%@)",
                          String(sawPodcastPlaying), peakPodcastTime, readSnap.lastUserText, readSnap.lastModelText))

        // Pause background article read-aloud after proving playback so its audio doesn't overlap remaining checks.
        sendDebugCommand("__pause_podcast__", in: app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        // ------------------------------------------------------------------
        // 3a. On bbc.com: "open the third link" opens it, no Agent, no URL spoken
        // ------------------------------------------------------------------
        var probeSnap = try refreshProbe(in: app)
        if probeSnap.visibleLinkCount < 3 || probeSnap.thirdLinkURL == probeSnap.pageURL || probeSnap.thirdLinkURL.contains("#") {
            app.webViews.firstMatch.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            probeSnap = try refreshProbe(in: app)
        }
        XCTAssertGreaterThanOrEqual(probeSnap.visibleLinkCount, 3, "Expected at least 3 links on BBC.")
        let bbcURLBeforeThird = probeSnap.pageURL
        let thirdText = probeSnap.thirdLinkText
        speak("Open the third link.", in: app, afterUtterances: probeSnap.utterancesInjected)
        let openedThird = wait(timeout: 35) {
            guard let s = self.telemetry(in: app) else { return false }
            let opened = s.toolEvents.dropFirst(probeSnap.toolEvents.count).contains {
                $0.name == "open_link" && $0.status == "opened"
            }
            return opened && s.pageURL != bbcURLBeforeThird && s.state == "listening" && !s.isInjectingSpeech
        }
        let thirdSnap = try requireTelemetry(in: app)
        saveEvidenceScreenshot(named: "voice-03a-open-third-link")
        XCTAssertTrue(openedThird, "Expected open_link #3 to open; url=\(thirdSnap.pageURL), tools=\(thirdSnap.toolEvents.map { "\($0.name):\($0.status)" })")
        XCTAssertEqual(thirdSnap.agentRunCount, 0, "open the third link must not start an Agent run.")
        assertNoSpokenAddress(thirdSnap.lastUserText, context: "user turn for third link")
        assertNoSpokenAddress(thirdSnap.lastModelText, context: "model reply for third link")
        log.append("check_3a_open_third_link: PASS (targetText=\(thirdText), landedURL=\(thirdSnap.pageURL), user=\(thirdSnap.lastUserText), reply=\(thirdSnap.lastModelText))")

        // Step back to bbc.com so we can also open a headline link from BBC.
        try speakGoBackOnce(in: app)

        // ------------------------------------------------------------------
        // 3b. On bbc.com: "open the one about <headline on screen>" opens it
        // ------------------------------------------------------------------
        var headlineProbe = try refreshProbe(in: app)
        if headlineProbe.headlinePhrase.isEmpty {
            app.webViews.firstMatch.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            headlineProbe = try refreshProbe(in: app)
        }
        XCTAssertFalse(headlineProbe.headlinePhrase.isEmpty, "Could not find a distinctive headline link on screen.")
        let bbcURLBeforeHeadline = headlineProbe.pageURL
        let chosenPhrase = headlineProbe.headlinePhrase
        let chosenHeadline = headlineProbe.headlineText
        speak("Open the one about \(chosenPhrase).", in: app, afterUtterances: headlineProbe.utterancesInjected)
        let headlineFirstStep = wait(timeout: 35) {
            guard let s = self.telemetry(in: app) else { return false }
            let events = s.toolEvents.dropFirst(headlineProbe.toolEvents.count)
            let handled = events.contains { $0.name == "open_link" && ($0.status == "opened" || $0.status == "choices") }
            return handled && s.state == "listening" && !s.isInjectingSpeech
        }
        var headlineSnap = try requireTelemetry(in: app)
        if headlineFirstStep,
           headlineSnap.toolEvents.dropFirst(headlineProbe.toolEvents.count).contains(where: { $0.name == "open_link" && $0.status == "choices" }),
           !headlineSnap.toolEvents.dropFirst(headlineProbe.toolEvents.count).contains(where: { $0.name == "open_link" && $0.status == "opened" }) {
            let beforePick = headlineSnap
            speak("The first one.", in: app, afterUtterances: beforePick.utterancesInjected)
            _ = wait(timeout: 30) {
                guard let s = self.telemetry(in: app) else { return false }
                let opened = s.toolEvents.dropFirst(beforePick.toolEvents.count).contains {
                    $0.name == "open_link" && $0.status == "opened"
                }
                return opened && s.pageURL != bbcURLBeforeHeadline && s.state == "listening" && !s.isInjectingSpeech
            }
            headlineSnap = try requireTelemetry(in: app)
        }
        saveEvidenceScreenshot(named: "voice-03b-open-headline-link")
        let headlineOpened = headlineSnap.toolEvents.dropFirst(headlineProbe.toolEvents.count).contains {
            $0.name == "open_link" && $0.status == "opened"
        } && headlineSnap.pageURL != bbcURLBeforeHeadline
        XCTAssertTrue(headlineOpened, "Expected headline open_link to open; phrase=\(chosenPhrase), url=\(headlineSnap.pageURL), tools=\(headlineSnap.toolEvents.map { "\($0.name):\($0.status)" })")
        XCTAssertEqual(headlineSnap.agentRunCount, 0, "open_link by headline must not start an Agent run.")
        assertNoSpokenAddress(headlineSnap.lastUserText, context: "user turn for headline link")
        assertNoSpokenAddress(headlineSnap.lastModelText, context: "model reply for headline link")
        log.append("check_3b_open_headline_link: PASS (phrase=\"\(chosenPhrase)\", headline=\"\(chosenHeadline)\", landedURL=\(headlineSnap.pageURL), user=\(headlineSnap.lastUserText), reply=\(headlineSnap.lastModelText))")

        // ------------------------------------------------------------------
        // 4. "go back" returns to the forum, and "search for X" shows cards
        // ------------------------------------------------------------------
        var backAttempts = 0
        while backAttempts < 4 {
            let current = try requireTelemetry(in: app)
            if current.isForum && current.pageHost == Self.forumHost { break }
            backAttempts += 1
            try speakGoBackOnce(in: app)
            _ = wait(timeout: 8) {
                guard let s = self.telemetry(in: app) else { return false }
                return s.isForum && s.pageHost == Self.forumHost
            }
        }
        let forumBackSnap = try requireTelemetry(in: app)
        saveEvidenceScreenshot(named: "voice-04a-back-on-forum")
        XCTAssertEqual(forumBackSnap.pageHost, Self.forumHost, "Expected go back to return to \(Self.forumHost), got \(forumBackSnap.pageHost)")
        XCTAssertTrue(forumBackSnap.isForum, "Expected recognized forum after go back.")
        XCTAssertEqual(forumBackSnap.agentRunCount, 0)
        log.append("check_4a_go_back_to_forum: PASS (steps=\(backAttempts), host=\(forumBackSnap.pageHost), isForum=\(forumBackSnap.isForum))")

        // Let the settled `[Screen: … forum …]` note flush before searching.
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        _ = waitForQuietListening(in: app, timeout: 10)

        let beforeSearch = try requireTelemetry(in: app)
        speak("Search for plugins.", in: app, afterUtterances: beforeSearch.utterancesInjected)
        let showedCards = wait(timeout: 40) {
            guard let s = self.telemetry(in: app) else { return false }
            let searched = s.toolEvents.dropFirst(beforeSearch.toolEvents.count).contains { $0.name == "search_forum" }
            return searched && s.cardsCount > 0 && s.cardsVisible && s.state == "listening" && !s.isInjectingSpeech
        }
        let searchSnap = try requireTelemetry(in: app)
        saveEvidenceScreenshot(named: "voice-04b-search-cards")
        XCTAssertTrue(showedCards, "Expected search_forum cards; cardsCount=\(searchSnap.cardsCount), visible=\(searchSnap.cardsVisible), tools=\(searchSnap.toolEvents.map(\.name))")
        XCTAssertEqual(searchSnap.agentRunCount, 0, "search_forum must not start a BrowserAgent run.")
        log.append("check_4b_search_shows_cards: PASS (query=plugins, cardsCount=\(searchSnap.cardsCount), cardsVisible=\(searchSnap.cardsVisible), reply=\(searchSnap.lastModelText))")

        // ------------------------------------------------------------------
        // 5. "open Hacker News" opens the saved site by name
        // ------------------------------------------------------------------
        let beforeHN = try requireTelemetry(in: app)
        speak("Open Hacker News.", in: app, afterUtterances: beforeHN.utterancesInjected)
        let openedHN = wait(timeout: 30) {
            guard let s = self.telemetry(in: app) else { return false }
            let opened = s.toolEvents.dropFirst(beforeHN.toolEvents.count).contains {
                $0.name == "open_page" && $0.status == "opened"
            }
            return opened && s.pageHost == "news.ycombinator.com" && s.state == "listening" && !s.isInjectingSpeech
        }
        let hnSnap = try requireTelemetry(in: app)
        saveEvidenceScreenshot(named: "voice-05-open-hacker-news")
        XCTAssertTrue(openedHN, "Expected Hacker News by saved site name; host=\(hnSnap.pageHost), tools=\(hnSnap.toolEvents.map { "\($0.name):\($0.status)" })")
        XCTAssertFalse(hnSnap.cardsVisible, "Previous forum's search cards must hide when leaving that forum.")
        XCTAssertEqual(hnSnap.agentRunCount, 0, "open Hacker News must not start an Agent run.")
        log.append("check_5_open_hacker_news: PASS (host=\(hnSnap.pageHost), cardsVisible=\(hnSnap.cardsVisible), user=\(hnSnap.lastUserText), reply=\(hnSnap.lastModelText))")

        // ------------------------------------------------------------------
        // 6. "switch to dark mode" on an ordinary page takes effect via Agent
        // ------------------------------------------------------------------
        let beforeExample = try requireTelemetry(in: app)
        speak("Open example dot com.", in: app, afterUtterances: beforeExample.utterancesInjected)
        let onExample = wait(timeout: 30) {
            guard let s = self.telemetry(in: app) else { return false }
            return s.pageHost.contains("example.com") && !s.isForum && s.state == "listening" && !s.isInjectingSpeech
        }
        XCTAssertTrue(onExample, "Could not open example.com for ordinary-page dark mode check.")
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let lightProbe = try refreshProbe(in: app)
        saveEvidenceScreenshot(named: "voice-06a-ordinary-page-light")

        speak("Switch to dark mode.", in: app, afterUtterances: lightProbe.utterancesInjected)
        let darkCompleted = wait(timeout: 95) {
            guard let s = self.telemetry(in: app) else { return false }
            let handedOff = s.toolEvents.dropFirst(lightProbe.toolEvents.count).contains {
                $0.name == "hand_off_to_agent" && $0.status == "started"
            }
            let briefed = s.briefingKinds.dropFirst(lightProbe.briefingKinds.count).contains("agent answer")
            return handedOff && s.agentRunCount > lightProbe.agentRunCount && s.lastAgentRunState == "completed"
                && briefed && s.state == "listening" && !s.isInjectingSpeech
        }
        let darkProbe = try refreshProbe(in: app)
        saveEvidenceScreenshot(named: "voice-06b-ordinary-page-dark")
        XCTAssertTrue(darkCompleted, "Expected dark mode hand-off to complete; runState=\(darkProbe.lastAgentRunState), briefings=\(darkProbe.briefingKinds), tools=\(darkProbe.toolEvents.map { "\($0.name):\($0.status)" })")
        XCTAssertLessThan(darkProbe.pageLuminance, 0.35, "Expected dark background on example.com; before=\(lightProbe.pageLuminance) (\(lightProbe.pageBg)), after=\(darkProbe.pageLuminance) (\(darkProbe.pageBg))")
        log.append(String(format: "check_6_dark_mode_via_agent: PASS (model=%@, lum %.3f -> %.3f, bg=%@, reply=%@)",
                          darkProbe.agentModel, lightProbe.pageLuminance, darkProbe.pageLuminance, darkProbe.pageBg, darkProbe.lastModelText))

        // ------------------------------------------------------------------
        // 7. "open bbc.com" while a hand-off runs is refused in a sentence,
        //    and "never mind" stops the run
        // ------------------------------------------------------------------
        let beforeWiki = try requireTelemetry(in: app)
        speak("Open wikipedia dot org.", in: app, afterUtterances: beforeWiki.utterancesInjected)
        let onWiki = wait(timeout: 30) {
            guard let s = self.telemetry(in: app) else { return false }
            return s.pageHost.contains("wikipedia.org") && !s.isForum && s.state == "listening" && !s.isInjectingSpeech
        }
        XCTAssertTrue(onWiki, "Could not open wikipedia.org for Check 7.")
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let beforeBusyHandOff = try requireTelemetry(in: app)
        let multiStepWikiTask = "Read this page, open the English Wikipedia main page, read its featured article, and switch it to dark mode."
        speak(multiStepWikiTask, in: app, afterUtterances: beforeBusyHandOff.utterancesInjected)
        let handOffRunning = wait(timeout: 30) {
            guard let s = self.telemetry(in: app) else { return false }
            return s.isHandingOff && s.turnCompleteCount > beforeBusyHandOff.turnCompleteCount
                && s.state == "listening" && !s.isInjectingSpeech
        }
        XCTAssertTrue(handOffRunning, "Expected hand-off to be actively running on wikipedia.org after acknowledgement.")

        let whileRunning = try requireTelemetry(in: app)
        speak("Open BBC dot com.", in: app, afterUtterances: whileRunning.utterancesInjected)
        let refusedOpen = wait(timeout: 25) {
            guard let s = self.telemetry(in: app) else { return false }
            let refused = s.toolEvents.dropFirst(whileRunning.toolEvents.count).contains {
                $0.name == "open_page" && $0.status == "unavailable"
            }
            let spokeRefusal = s.modelTurns.count > whileRunning.modelTurns.count
                || (!s.lastModelText.isEmpty && s.lastModelText != whileRunning.lastModelText && s.state == "listening")
            return refused && spokeRefusal && s.state == "listening" && !s.isInjectingSpeech
        }
        let refusedSnap = try requireTelemetry(in: app)
        saveEvidenceScreenshot(named: "voice-07a-handoff-busy-refused")
        XCTAssertTrue(refusedOpen, "Expected open_page refusal while hand-off runs; tools=\(refusedSnap.toolEvents.dropFirst(whileRunning.toolEvents.count).map { "\($0.name):\($0.status)" }), reply=\(refusedSnap.lastModelText)")
        XCTAssertTrue(refusedSnap.pageHost.contains("wikipedia.org"), "Browser must stay on wikipedia.org when open_page is refused, got \(refusedSnap.pageHost)")
        log.append("check_7a_open_refused_during_handoff: PASS (host=\(refusedSnap.pageHost), reply=\(refusedSnap.lastModelText))")

        // Say "Never mind." while a hand-off is actively running (and after any model acknowledgement finishes playing).
        func attemptCancelActiveHandOff() throws -> (cancelled: Bool, snap: Telemetry, baseCount: Int) {
            var base = try requireTelemetry(in: app)
            if !base.isHandingOff {
                RunLoop.current.run(until: Date().addingTimeInterval(1.5))
                _ = waitForQuietListening(in: app, timeout: 15)
                let restartBase = try requireTelemetry(in: app)
                speak(multiStepWikiTask, in: app, afterUtterances: restartBase.utterancesInjected)
                _ = wait(timeout: 30) {
                    guard let s = self.telemetry(in: app) else { return false }
                    return s.isHandingOff && s.turnCompleteCount > restartBase.turnCompleteCount
                        && s.state == "listening" && !s.isInjectingSpeech
                }
                base = try requireTelemetry(in: app)
            }
            guard base.isHandingOff else { return (false, base, base.toolEvents.count) }
            _ = waitForQuietListening(in: app, timeout: 10)
            base = try requireTelemetry(in: app)
            guard base.isHandingOff else { return (false, base, base.toolEvents.count) }
            speak("Never mind.", in: app, afterUtterances: base.utterancesInjected)
            _ = wait(timeout: 25) {
                guard let s = self.telemetry(in: app) else { return false }
                let events = s.toolEvents.dropFirst(base.toolEvents.count)
                let handled = events.contains {
                    $0.name == "hand_off_to_agent" && ($0.status == "cancelled" || $0.status == "unavailable")
                }
                return handled && !s.isHandingOff && !s.agentIsRunning && s.state == "listening" && !s.isInjectingSpeech
            }
            let snap = try requireTelemetry(in: app)
            let didCancel = snap.toolEvents.dropFirst(base.toolEvents.count).contains {
                $0.name == "hand_off_to_agent" && $0.status == "cancelled"
            } && !snap.isHandingOff && !snap.agentIsRunning && snap.lastAgentRunState == "stopped"
            return (didCancel, snap, base.toolEvents.count)
        }

        var cancelAttempt = try attemptCancelActiveHandOff()
        if !cancelAttempt.cancelled, cancelAttempt.snap.lastAgentRunState == "completed" {
            // The first hand-off completed while "Never mind." was spoken; start a fresh one and cancel immediately.
            cancelAttempt = try attemptCancelActiveHandOff()
        }
        let cancelledHandOff = cancelAttempt.cancelled
        let cancelSnap = cancelAttempt.snap
        saveEvidenceScreenshot(named: "voice-07b-never-mind-stopped")
        XCTAssertTrue(cancelledHandOff, "Expected 'never mind' to cancel the running hand-off; state=\(cancelSnap.lastAgentRunState), tools=\(cancelSnap.toolEvents.dropFirst(cancelAttempt.baseCount).map { "\($0.name):\($0.status)" })")
        log.append("check_7b_never_mind_stops_run: PASS (lastAgentRunState=\(cancelSnap.lastAgentRunState), isHandingOff=\(cancelSnap.isHandingOff), reply=\(cancelSnap.lastModelText))")

        // ------------------------------------------------------------------
        // Final single-session & protocol assertions
        // ------------------------------------------------------------------
        XCTAssertEqual(cancelSnap.sessionCount, 1, "All seven checks must complete in one uninterrupted VoiceSession.")
        XCTAssertEqual(cancelSnap.textFramesSent, 0, "Zero realtimeInput.text frames allowed.")
        XCTAssertGreaterThan(cancelSnap.micFramesSent, 100)
        XCTAssertGreaterThan(cancelSnap.audioBytesPlayed, 0)
        XCTAssertEqual(cancelSnap.agentModel, Self.anthropicModel)
        XCTAssertEqual(cancelSnap.summaryModel, Self.anthropicModel)
        log.append("final_invariants: PASS (sessionCount=\(cancelSnap.sessionCount), connections=\(cancelSnap.connectionSerial), endpoint=\(cancelSnap.endpoint), geminiModel=\(cancelSnap.geminiModel), agentModel=\(cancelSnap.agentModel), micFramesSent=\(cancelSnap.micFramesSent), textFramesSent=\(cancelSnap.textFramesSent), audioBytesPlayed=\(cancelSnap.audioBytesPlayed))")

        let endButton = app.buttons["voiceEnd"]
        if endButton.waitForExistence(timeout: 5) { endButton.tap() }
    }

    // MARK: - Helpers

    private func launchVoiceApp(provider: String, includeVertex: Bool, includeGemini: Bool) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["ANTHROPIC_API_KEY"] = anthropicKey
        if includeVertex, !vertexKey.isEmpty {
            app.launchEnvironment["VERTEX_API_KEY"] = vertexKey
            if !vertexBaseURL.isEmpty { app.launchEnvironment["VERTEX_BASE_URL"] = vertexBaseURL }
            if !vertexProject.isEmpty { app.launchEnvironment["VERTEX_PROJECT"] = vertexProject }
        }
        if includeGemini, !geminiKey.isEmpty {
            app.launchEnvironment["GEMINI_LIVE_KEY"] = geminiKey
        }
        app.launchArguments = [
            "-dc-skip-onboarding",
            "-dc-seed-forums",
            "-dc-open", Self.forumLatest,
            "-dc-browser-agent-live-key",
            "-dc-browser-agent-live-model", Self.anthropicModel,
            "-dc-voice-provider", provider,
            "-dc-voice-speak-typed",
            "-AppleInterfaceStyle", "Light"
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 25))
        return app
    }

    private func waitForInitialForum(in app: XCUIApplication) throws {
        let ready = wait(timeout: 35) {
            guard let snap = self.telemetry(in: app) else { return false }
            return snap.pageHost == Self.forumHost && snap.isForum
        }
        showBrowser(in: app)
        guard ready else {
            saveEvidenceScreenshot(named: "voice-forum-load-failure")
            XCTFail("Initial forum \(Self.forumLatest) did not settle as a recognized forum.")
            return
        }
    }

    private func startVoice(in app: XCUIApplication) {
        let mic = app.buttons.matching(identifier: "voiceButton").firstMatch
        if waitForBarItem(mic, timeout: 4) {
            tapBarItem(mic)
            allowMicrophoneIfPrompted()
            return
        }
        let ai = app.buttons["aiButton"]
        XCTAssertTrue(waitForBarItem(ai, timeout: 10), "The bar has neither a microphone nor an AI button.")
        pressBarItem(ai, duration: 1.0)
        allowMicrophoneIfPrompted()
    }

    private func allowMicrophoneIfPrompted() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let tccAllow = springboard.buttons["kTCCServiceMicrophone-allow-button"].firstMatch
        if tccAllow.exists {
            tccAllow.tap()
            return
        }
        let alert = springboard.alerts.firstMatch
        guard alert.exists else { return }
        for title in ["Allow", "OK", "允许", "好"] {
            let button = alert.buttons[title].firstMatch
            if button.exists {
                button.tap()
                return
            }
        }
    }

    private func speak(_ utterance: String, in app: XCUIApplication, afterUtterances previousCount: Int) {
        sendDebugCommand(utterance, in: app)
        _ = wait(timeout: 25) {
            guard let s = self.telemetry(in: app) else { return false }
            return s.utterancesInjected > previousCount && !s.isInjectingSpeech
        }
    }

    private func speakGoBackOnce(in app: XCUIApplication) throws {
        _ = waitForQuietListening(in: app, timeout: 15)
        let before = try requireTelemetry(in: app)
        speak("Go back.", in: app, afterUtterances: before.utterancesInjected)
        let moved = wait(timeout: 30) {
            guard let s = self.telemetry(in: app) else { return false }
            let didMove = s.toolEvents.dropFirst(before.toolEvents.count).contains {
                $0.name == "browse_move" && $0.status == "moved"
            }
            return didMove && s.state == "listening" && !s.isInjectingSpeech
        }
        XCTAssertTrue(moved, "Expected browse_move(back) to complete.")
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    }

    private func refreshProbe(in app: XCUIApplication) throws -> Telemetry {
        let before = try requireTelemetry(in: app)
        sendDebugCommand("__refresh_probe__", in: app)
        let updated = wait(timeout: 15) {
            guard let s = self.telemetry(in: app) else { return false }
            return s.probeRevision > before.probeRevision
        }
        XCTAssertTrue(updated, "DOM/link probe did not update.")
        return try requireTelemetry(in: app)
    }

    private func sendDebugCommand(_ text: String, in app: XCUIApplication) {
        let field = app.textFields["voiceTextField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "voiceTextField missing in DEBUG voice bar.")
        field.tap()
        field.typeText(text + "\n")
    }

    @discardableResult
    private func waitForQuietListening(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) {
            guard let s = self.telemetry(in: app) else { return false }
            return s.state == "listening" && !s.isInjectingSpeech
        }
    }

    private func telemetry(in app: XCUIApplication) -> Telemetry? {
        let el = any(app, "voiceAcceptanceState")
        guard el.exists else { return nil }
        let raw = el.label
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Telemetry.self, from: data)
    }

    private func requireTelemetry(in app: XCUIApplication) throws -> Telemetry {
        guard let snap = telemetry(in: app) else {
            XCTFail("Missing voiceAcceptanceState telemetry.")
            throw CancellationError()
        }
        return snap
    }

    private func assertNoSpokenAddress(_ text: String, context: String) {
        let lower = text.lowercased()
        XCTAssertFalse(lower.contains("http://") || lower.contains("https://"), "Unexpected spoken URL in \(context): \(text)")
    }

    private func saveEvidenceText(_ text: String, named name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["VOICE_ACCEPTANCE_EVIDENCE_DIR"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? text.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }

    private func saveEvidenceScreenshot(named name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["VOICE_ACCEPTANCE_EVIDENCE_DIR"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
    }
}
