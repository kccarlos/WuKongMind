# Voice anywhere acceptance (1.3.2)

Run on 2026-11-15 for WUKO-84 against [voice-review.md §5 "6. Voice anywhere acceptance"](voice-review.md#6-voice-anywhere-acceptance), following the owner's 2026-11-14 decisions in [voice-review.md §4](voice-review.md#4-owner-decisions-2026-11-14) (shipping before the trial as `1.3.2`, `open_link` enabled, title and host only in page notes).

Two environments:

- **Phone:** the owner's iPhone 13 (iOS 27.2.1), run exclusively through `scripts/device-check.sh`.
- **Simulator:** the fixed iPhone 18 Pro simulator, run through `scripts/remote-test.sh` on the Mac mini.

**Models and endpoints:**

- **Agent and Summaries:** `claude-haiku-5-5` only (`-dc-browser-agent-live-model claude-haiku-5-5`, key supplied by name through `herdr-secret`).
- **Voice (Gemini Live):** `gemini-3.8-live` on **Vertex AI Express** (`wss://us-central1-aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent`, model path `publishers/google/models/gemini-3.8-live`) using `VERTEX_API_KEY` first, which connected and ran directly on both the phone and the simulator. `GEMINI_LIVE_KEY` (AI Studio) was configured as the automatic fallback; earlier on 2026-11-15 the AI Studio project hit its monthly spending cap (`close 1011`), making Vertex Express the active live path.

**State isolation and evidence:** `-dc-browser-agent-live-key` sets `suppressesPersistence = true`, so `AppModel.save`, Keychain writes, and `VoiceUsageStore` writes return early without touching saved app state or keys (Agent workspace files and audit records under `Documents/` behave as noted in [one-loop-acceptance.md](one-loop-acceptance.md)). Non-secret text summaries and session telemetry are in [`voice-anywhere-acceptance/`](voice-anywhere-acceptance/). Real iPhone 13 screenshots are in the WUKO-84 proof artifact (`voice-anywhere-acceptanc-163f`). `marketing_version` is bumped to `1.3.2` in `scripts/generate_project.rb` with `WukongMind.xcodeproj` regenerated and [README.md](README.md#versions-and-releases) updated; no git tag was created.

**Result summary.** All seven Done-when checks pass in **one uninterrupted `VoiceSession`** (`sessionCount == 1`, `textFramesSent == 0`, 16 kHz PCM16 speech frames gated through `CaptureGate` via `-dc-voice-speak-typed`) on both the owner's iPhone 13 and the iPhone 18 Pro simulator.

## Result

| # | Check | Result | Where | Evidence |
|---|---|---|---|---|
| 1 | From a forum (`meta.discourse.org`), `"open bbc.com"` opens it in a few seconds, with no Agent run | **Pass.** `open_page` opened `www.bbc.com` directly (`agentRunCount == 0`), replied `"I've opened the BBC home page for you."` on the phone (14.1 s end-to-end including spoken synthesis, VAD hold, page load, and spoken confirmation). | iPhone 13, simulator | [`iphone13-summary.txt`](voice-anywhere-acceptance/iphone13-summary.txt), [`simulator-summary.txt`](voice-anywhere-acceptance/simulator-summary.txt), proof `voice-01-open-bbc.png` |
| 2 | On `bbc.com`: `"what's this page about"` and `"read it to me"` answer and play | **Pass.**<br>1. `"What's this page about?"` called `summarize_topic` with no input -> `VoiceToolBridge` defaulted to `pageReadableText()` (`claude-haiku-5-5`) and spoke a 2-sentence summary of the BBC front page (`agentRunCount == 0`).<br>2. `"Read it to me."` called `read_aloud` (`status: "started"`), spoke confirmation, and started `PodcastPlayer` playback (`podcastPlayed == true`, `peakTime == 2.92 s` on phone before test pause) while keeping the `VoiceSession` active. | iPhone 13, simulator | [`iphone13-summary.txt`](voice-anywhere-acceptance/iphone13-summary.txt), [`simulator-summary.txt`](voice-anywhere-acceptance/simulator-summary.txt), proof `voice-02b-read-it-to-me.png` |
| 3 | On `bbc.com`: `"open the third link"` and `"open the one about <a headline on screen>"` each open that link, with no Agent run and no address spoken | **Pass.**<br>1. `"Open the third link."` called `open_link` (`#3`) and opened `/news/articles/cwdr1dmn563do` (`agentRunCount == 0`, no `http://` or `https://` in user or model transcript).<br>2. After `"Go back."` (`browse_move`), `"Open the one about Zelensky urges Musk lift."` matched the visible headline `"Zelensky urges US and Musk to lift Starlink restrictions and be on 'right side of history'"` via `open_link` and opened `/news/articles/c6m25zg88k45o` (`agentRunCount == 0`, no URL spoken). | iPhone 13, simulator | [`iphone13-summary.txt`](voice-anywhere-acceptance/iphone13-summary.txt), [`simulator-summary.txt`](voice-anywhere-acceptance/simulator-summary.txt), proof `voice-03a-open-third-link.png`, `voice-03b-open-headline-link.png` |
| 4 | `"go back"` returns to the forum, and `"search for X"` shows cards | **Pass.** Two spoken `"Go back."` turns (`browse_move`) returned from the BBC article through BBC Home to `meta.discourse.org` (`isForum == true`). Speaking `"Search for plugins."` called `search_forum` (`status: "found"`) and displayed 20 numbered result cards (`cardsCount == 20`, `cardsVisible == true`, `agentRunCount == 0`). | iPhone 13, simulator | [`iphone13-summary.txt`](voice-anywhere-acceptance/iphone13-summary.txt), [`simulator-summary.txt`](voice-anywhere-acceptance/simulator-summary.txt), proof `voice-04b-search-cards.png` |
| 5 | `"open Hacker News"` opens the saved site by name | **Pass.** `"Open Hacker News."` resolved the pinned site via `open_page` to `news.ycombinator.com` (`agentRunCount == 0`), hid the Discourse result cards (`cardsVisible == false`), and confirmed aloud. | iPhone 13, simulator | [`iphone13-summary.txt`](voice-anywhere-acceptance/iphone13-summary.txt), [`simulator-summary.txt`](voice-anywhere-acceptance/simulator-summary.txt), proof `voice-05-open-hacker-news.png` |
| 6 | `"switch to dark mode"` on an ordinary page takes effect through the Agent | **Pass.** After opening `example.com` (`isForum == false`, background luminance `0.933`), `"Switch to dark mode."` called `hand_off_to_agent` (`status: "started"`), ran `BrowserAgent` on `claude-haiku-5-5` to completion, dropped page background luminance to `0.071` (`rgb(18, 18, 18)`), and delivered the `WHEN_IDLE` `"agent answer"` briefing aloud. | iPhone 13, simulator | [`iphone13-summary.txt`](voice-anywhere-acceptance/iphone13-summary.txt), [`simulator-summary.txt`](voice-anywhere-acceptance/simulator-summary.txt), proof `voice-06a-ordinary-page-light.png`, `voice-06b-ordinary-page-dark.png` |
| 7 | `"open bbc.com"` while that hand-off runs is refused in a sentence, and `"never mind"` stops the run | **Pass.**<br>1. While a multi-step Agent hand-off was running on `wikipedia.org`, `"Open bbc.com."` called `open_page`, received `status: "unavailable"` (`"The Agent is still working on this page. Say never mind to stop it."`), stayed on `wikipedia.org`, and spoke the refusal in one sentence.<br>2. Speaking `"Never mind."` called `hand_off_to_agent` with `action: "cancel"` (`status: "cancelled"`), stopped the Agent run (`lastAgentRunState == "stopped"`, `isHandingOff == false`), and confirmed aloud — all within the same `VoiceSession` (`sessionCount == 1`, `micFramesSent == 1,273` on phone, `textFramesSent == 0`). | iPhone 13, simulator | [`iphone13-summary.txt`](voice-anywhere-acceptance/iphone13-summary.txt), [`iphone13-telemetry.json`](voice-anywhere-acceptance/iphone13-telemetry.json), [`simulator-summary.txt`](voice-anywhere-acceptance/simulator-summary.txt), proof `voice-07a-handoff-busy-refused.png`, `voice-07b-never-mind-stopped.png` |
| Regressions & version | Voice/navigation unit & UI suites, project drift, layering, plists, string catalogs, and `1.3.2` release version check | **Pass.** `VoiceProtocolTests`, `VoiceSessionTests`, `VoiceToolTests`, `VoiceActivityDetectorTests`, `PodcastTests`, `BrowseNavigationTests`, `SiteGoldenTests`, and `VoiceUITests` pass via `scripts/remote-test.sh`; `check-project-drift.sh`, `check-site-layering.sh`, `lint-plists.sh`, `check-catalogs.py`, and `REF_TYPE=tag REF_NAME=v1.3.2 check-release-version.sh` all pass (`Marketing version: 1.3.2`). | Mac mini simulator, local static checks | [`regression-voice.txt`](voice-anywhere-acceptance/regression-voice.txt) |

## Fixed in this task

- **Vertex AI Express for Gemini Live (`Voice/LiveProtocol.swift`, `AppModel+Voice.swift`).** `AppModel.voiceConfiguration()` previously failed with `.noVertexProject` when `vertexProject` was empty because Express mode had only been probed against the global host (`aiplatform.googleapis.com`) or `TEXT` output (`1007`). On the regional `us-central1` WebSocket host (`wss://us-central1-aiplatform.googleapis.com/...`) with `AUDIO` output, `publishers/google/models/gemini-3.8-live` works directly with `VERTEX_API_KEY`. Project-scoped Vertex keys still use `projects/<id>/locations/us-central1/publishers/google/models/gemini-3.8-live`. Covered by `VoiceProtocolTests` and `VoiceToolTests`.
- **Read-aloud playback during an active voice session (`Podcast/PodcastPlayer.swift`).** `SystemPodcastAudioSession.activateForPlayback()` switched `AVAudioSession.sharedInstance()` to `.playback` / `.spokenAudio`, overriding `.playAndRecord` / `.voiceChat` and interrupting `VoiceAudioEngine` capture when `"read it to me"` (`read_aloud`) started; `deactivate()` also deactivated the shared session on pause/stop. Both now preserve the active `.playAndRecord` + `.voiceChat` session while voice is running.
- **Immediate speech after `go back` to a forum (`Voice/VoiceSession.swift`, `AppModel+Navigation.swift`).** `VoiceSession` waited for 1 second of post-turn quiet (`isQuiet`) before flushing queued `[Screen: …]` notes, so speaking `"Search for X"` right after `"Go back"` could open the capture gate before the settled forum note was sent, causing Gemini to route `"Search for X"` to `open_page` instead of `search_forum`. `VoiceSession.flushNotesBeforeUserTurn()` now flushes queued notes before opening the capture gate, and `AppModel.back()` / `forward()` include the destination's clean title, host, and known-forum status (never the full URL, path, query, or fragment) in the `browse_move` result. Covered by `VoiceSessionTests.testPendingPageNoteFlushesBeforeImmediateNextUserSpeech`.
- **Forum result cards hidden off-forum (`BrowseCursor.swift`, `ResultCards.swift`, `SummaryPanel.swift`).** Navigating from a forum search to another site via `open_page` left the forum's result cards floating over ordinary pages and other forums. `BrowseCursor.matches(_:)` hides the cards off the forum where they were created and shows them again when returning to that forum. Covered by `VoiceToolTests.testFindThroughAppModel`.

## Not proven

- **Human room acoustics and open-air echo cancellation:** both the iPhone 13 (`VoiceAudioEngine`) and simulator (`SyntheticCaptureVoiceAudio`) runs drove `CaptureGate` and `VoiceSession` with synthesized 16 kHz PCM16 speech frames (`AVSpeechSynthesizer`, `-dc-voice-speak-typed`, `textFramesSent == 0`). This exercises VAD, comfort noise, `audioStreamEnd`, barge-in gating, and speaker playback (`4.75 MB` PCM played on the iPhone 13), but does not measure human speech in ambient noise or physical speaker-to-microphone acoustic bleed.
- **Git tag `v1.3.2` and TestFlight archive:** `marketing_version` is bumped to `1.3.2` and verified with `REF_TYPE=tag REF_NAME=v1.3.2 scripts/ci/check-release-version.sh`, per task instructions no tag was created or pushed.

## Running the live check

- **Phone (`scripts/device-check.sh` only):**
  ```sh
  herdr-secret run ANTHROPIC_API_KEY,VERTEX_API_KEY,GEMINI_LIVE_KEY -- \
    env TEST_RUNNER_ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
        TEST_RUNNER_VERTEX_API_KEY="$VERTEX_API_KEY" \
        TEST_RUNNER_GEMINI_LIVE_KEY="$GEMINI_LIVE_KEY" \
    scripts/device-check.sh test \
      -only-testing:WukongMindUITests/VoiceAnywhereLiveAcceptanceUITests/testVoiceAnywhereOneSession
  ```
- **Simulator (`scripts/remote-test.sh`):**
  ```sh
  herdr-secret run ANTHROPIC_API_KEY,VERTEX_API_KEY,GEMINI_LIVE_KEY -- \
    scripts/remote-test.sh test --sim iphone \
      --secret ANTHROPIC_API_KEY=TEST_RUNNER_ANTHROPIC_API_KEY \
      --secret VERTEX_API_KEY=TEST_RUNNER_VERTEX_API_KEY \
      --secret GEMINI_LIVE_KEY=TEST_RUNNER_GEMINI_LIVE_KEY \
      -only-testing:WukongMindUITests/VoiceAnywhereLiveAcceptanceUITests/testVoiceAnywhereOneSession
  ```
