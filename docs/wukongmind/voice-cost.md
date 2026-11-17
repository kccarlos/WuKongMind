# Voice (Gemini Live) cost

WUKO-123. The owner said on 2026-11-15 that Gemini Live use is too high. This page measures one typical session, says where the cost goes, and lists what to change. Testing rules are in [DEVELOPMENT.md "Live Gemini Live budget"](../DEVELOPMENT.md#live-gemini-live-budget).

## How it is billed

`gemini-3.8-live` answers only in audio (`Voice/LiveProtocol.swift`). Each model turn bills:

- the **whole context as prompt tokens**: system instruction, tool declarations, notes and earlier turns, including earlier model audio, which comes back as prompt `AUDIO` tokens;
- the reply as **response tokens**: audio at about 25 tokens a second, plus the transcript text;
- thinking tokens.

Microphone audio is billed as prompt audio once it is in the context.

## Before: one scripted session (measured)

`WukongMindTests/VoiceLiveCostTests` ran on 2026-11-15 on Vertex (`VERTEX_API_KEY`, us-central1, express) with model `gemini-3.8-live`, through the live test budget. It used 1 session of 17.0 s (cap 3 sessions / 120 s).

The test used the unchanged app session, voice registry and tool bridge, on a fake news page. Turns were typed (`realtimeInput.text`), so no microphone audio was sent. The script:

1. "What's this page about?" → `summarize_topic`
2. "Open the third link." → `open_link`
3. "Thanks, that's all." → `end`

| Measure | Value |
|---|---|
| Connected | 16.4 s |
| Model audio received | 12.2 s |
| Model turns | 5 (each tool call costs 2: the call turn and the reply turn) |
| Prompt tokens per turn | 3,589 · 3,653 · 3,881 · 3,943 · 4,039 |
| Prompt tokens, total | 19,105 (of which earlier model audio: 193 + 193 + 270) |
| Response tokens, total | 396 (audio 323, text 73) |
| Thinking tokens | 251 |
| Microphone audio | 0 s (typed turns) |

The session is replayed offline from `WukongMindTests/Fixtures/LiveReplay/recorded-vertex-session.json` (`LiveReplayTests/testRecordedVertexSessionReplay`). The first reply says the summary model isn't connected. That is expected: the test app has no summary model, and it doesn't change the token counts that matter here.

The spike's token runs (`one-loop-spike/results/anywhere-tokens.json`, AI Studio) agree: the fixed 14-tool set with today's instruction costs 4,316 to 4,547 prompt tokens on the first turn.

## Where the cost went (before WUKO-124)

1. **The fixed prompt is about 90 % of the tokens** (5 × ~3,600 of 19,752). About 3,600 tokens of instruction and tool declarations are re-billed on every model turn. A tool call doubles the turns: 3 short requests cost 5 turns, about 19k prompt tokens. Trimming tool descriptions and the instruction is the biggest token lever.
2. **Model speech is re-billed.** Each reply's audio (12 s for three short answers here) is billed once as output and then again as prompt audio on every later turn. Shorter answers save twice.
3. **Compression does not help short sessions.** It started at 16k tokens (10k since WUKO-124) (`Setup.triggerTokens`) and slides back to 4k. A typical session never reaches 16k, so a lower trigger matters only for long sessions.
4. **The microphone is already gated.** On-device VAD (`CaptureGate`) sends only speech plus 100 ms pre-roll and 400 ms hangover. When the gate closes, about 1 s of comfort noise follows, then `audioStreamEnd`. That is roughly 1.5 s of billed non-speech per utterance. Not measured live here.
5. **Idle sessions already close.** The idle timeout was 60 s by default (20 s since WUKO-124), and the socket closes on `.idle`. An open session with the microphone gated sends no audio. The cost of a long idle timeout is noise that opens the gate and the context it adds.
6. **Barge-in already flushes playback** on `interrupted`, and the server stops generating.

## After (WUKO-124, measured)

The same script and test (`VoiceLiveCostTests/testLiveScriptedSessionRecordsAndMeasures`) ran again on 2026-11-16 on Vertex (`VERTEX_API_KEY`, us-central1, express), model `gemini-3.8-live`, through the live test budget: 1 session of 17.2 s.

| Measure | Before (WUKO-123) | After (WUKO-124) | Change |
|---|---|---|---|
| Connected | 16.4 s | 16.8 s | same |
| Model audio received | 12.2 s | 12.6 s | same |
| Model turns | 5 | 5 | same |
| Prompt tokens per turn | 3,589 · 3,653 · 3,881 · 3,943 · 4,039 | 2,877 · 2,941 · 3,174 · 3,236 · 3,364 | about −710 a turn |
| Prompt tokens, total | 19,105 | 15,592 | **−18 %** |
| Response tokens, total | 396 (audio 323, text 73) | 399 (audio 331, text 68) | same |
| Thinking tokens | 251 | 258 | same |
| Microphone audio | 0 s (typed turns) | 0 s (typed turns) | not measured live |

Where the saving comes from: the fixed prompt (setup) went from 17,737 to 14,384 characters. The tool declarations went from 12,734 to 9,375 characters and the instruction stayed at about 4,300 (`VoicePromptSizeTests` prints both and fails if they grow past 4,500 and 9,800). The setup declares 14 tools (12 from the registry plus `end` and `hand_off_to_agent`), not 13.

Answers were already short in this script, so the answer-length change doesn't show here.

### What changed in the app

- **Tool descriptions (item 5).** Text that the system instruction or the screen note already says was cut from the tools, along with the parameter descriptions:
  - "Only works when the screen note says the user is on a forum" on six tools;
  - hand_off_to_agent's list of the other tools;
  - "navigation can be undone, don't ask";
  - the text Agent's workspace and read-budget wording on `read_topic`.

  The spike Q3 rule (`opinionRule`) and the instruction are unchanged. Voice now has its own short descriptions for `summarize_topic`, `read_aloud` and `read_topic`, so the text Agent's prompt is unchanged.
- **Spoken answers (item 6).** The `normal` length asks for "usually two to four sentences" (was "a few"). Barge-in was already handled: `interrupted` flushes playback (`testModelAudioPlaysAndInterruptionFlushes`), and the server stops generating.
- **Idle (item 4).** "Close when quiet" counts from when the session goes quiet: a reply still playing or a hand-off still running does not count. It defaults to 20 s (was 60 s; 20 s is now also offered in Settings). A saved 60 from before is moved to 20 once (`idleTimeoutRevision`).
  - When a session closes for quiet, it leaves its resumption handle. The next tap within 5 minutes resumes that conversation instead of the session staying open (`VoiceSession.Resumption`, kept by `VoiceController`).
  - The two traps from Part A are handled. On Vertex, only a fresh connection leaves a handle, so a resumed session leaves none. The resumed session sends the current page note itself (the carried `freshAt` makes `setupCompleted` treat it as the first connection).
  - A dead handle falls back to a fresh session. A user's own stop, a handle older than 5 minutes, or another key or endpoint also starts fresh.
- **Context (item 5).** Compression now starts at 10k tokens instead of 16k and slides back to 4k, so a long session re-bills at most about 10k a turn. A forum position note lists at most 4 visible posts instead of 6. Notes were already deltas and are sent only when a page settles.
- **Microphone (item 3).** The gate was already in place (WUKO-123). Offline, through the real `VoiceActivityDetector`, two spoken requests with pauses in pink room noise 20 dB below the voice (`VoicePromptSizeTests/testMicrophoneSecondsSentForTwoRequests`) came out as:
  - an open stream would send **18.6 s**;
  - the gate sends **5.4 s** for 4.1 s of speech, plus 2 × 1 s comfort noise, **7.4 s in all (−60 %)**.

  The comfort noise is left at 1 s. Shortening it needs a live check with real microphone audio that `audioStreamEnd` still ends turns, and typed live turns can't show that.

### Routing and resume checked live (2 more sessions)

`VoiceLiveCostTests/testLiveRoutingAfterTrimAndResumeAfterIdle` ran with the trimmed declarations, Vertex, `gemini-3.8-live`. It used 2 connections of 20.3 s and 4.5 s.

- On the forum page, "What do people here think of the N100 for a home server?" called `hand_off_to_agent`; spike Q3 still holds.
- "Search for firmware rollback." called `search_forum`.
- The session then closed as idle, and a new session resumed with the handle (connection generation 1).
- To "What did I ask you to search for a moment ago?" it answered "You asked me to search for firmware rollback."
- **The resume trade-off is measured.** The resumed connection's first turn billed 3,684 prompt tokens. A fresh session's first turn bills about 2,870, so resuming costs about 800 more tokens there. That is the earlier conversation, and the reason the handle expires after 5 minutes. Holding the session open instead would bill the same context on every later turn as well. The open time would also count against the voice-minutes limit in Settings.

Live sessions used in this task: 3 of 3 (17.2 s, 20.3 s and 4.5 s; `[LIVE-BUDGET]` lines in the test logs).

### Not changed or not proven

- The comfort-noise length (see above). Microphone seconds are measured offline, not live.
- The compression trigger in a really long session; no session here reached 10k tokens.
- Whether shorter `normal` answers shorten real answers; this script's answers were already one sentence.
- Routing of every spike case after the trim. Two at-risk cases were checked live. `LiveReplayTests` still replays every recorded call against the trimmed declarations, but it can't show what the model would pick.

## Notes from Part A (for reference)

- **Measure after with the same script.** Run `VoiceLiveCostTests` again (1 Vertex session, through the budget). It prints `[LIVE-COST]` and the recording, so the "after" row compares like with like. Typed turns don't measure microphone cost. For that, count gated frames offline through `CaptureGate` (the `VoiceActivityDetectorTests` speech and noise mixes) before and after the comfort-noise change.
- **Check routing after trimming descriptions.** `LiveReplayTests` fails if a recorded call's tool is no longer declared or no longer answers. It can't tell whether the model would still pick that tool, so spend one live session on the spike Q3 cases that are at risk.
- **Vertex usage fields.** Reply tokens are `candidatesTokenCount` (handled now). Prompt and reply are split by modality in `promptTokensDetails` and `candidatesTokensDetails`, and `thoughtsTokenCount` is separate. Earlier model speech comes back as prompt `AUDIO` tokens.
- **Resume on tap has two traps in the code.** On Vertex, a handle from a resumed connection is dropped (`resumptionUpdated`), so only a generation-0 handle can carry over. `setupCompleted` sends the first page note only for a fresh session (`freshAt` is nil when resumed), so a resumed session must send the current page note itself. A dead handle already falls back to a fresh session (`connectionEnded`).
- **Comfort noise** (about 1 s at real-time pace, then `audioStreamEnd`) is a field lesson from earlier apps. Shorten it only after a live check that turns still end.
