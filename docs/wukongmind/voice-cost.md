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

## Where the cost goes

1. **The fixed prompt is about 90 % of the tokens** (5 × ~3,600 of 19,752). About 3,600 tokens of instruction and tool declarations are re-billed on every model turn. A tool call doubles the turns: 3 short requests cost 5 turns, about 19k prompt tokens. Trimming tool descriptions and the instruction is the biggest token lever.
2. **Model speech is re-billed.** Each reply's audio (12 s for three short answers here) is billed once as output and then again as prompt audio on every later turn. Shorter answers save twice.
3. **Compression does not help short sessions.** It starts at 16k tokens (`Setup.triggerTokens`) and slides back to 4k. A typical session never reaches 16k, so a lower trigger matters only for long sessions.
4. **The microphone is already gated.** On-device VAD (`CaptureGate`) sends only speech plus 100 ms pre-roll and 400 ms hangover. When the gate closes, about 1 s of comfort noise follows, then `audioStreamEnd`. That is roughly 1.5 s of billed non-speech per utterance. Not measured live here.
5. **Idle sessions already close.** The idle timeout is 60 s by default, and the socket closes on `.idle`. An open session with the microphone gated sends no audio. The cost of a long idle timeout is noise that opens the gate and the context it adds.
6. **Barge-in already flushes playback** on `interrupted`, and the server stops generating.

## After

Part B (the app changes) is proposed as its own task. It will add the "after" row here from the same script, so before and after are compared on the same session. In order of expected saving:

- trim tool descriptions and the instruction, keeping spike Q3 routing; check with the replay fixtures and a live routing spot-check;
- shorter spoken answers by instruction;
- comfort noise of 1 s → shorter, after checking live that `audioStreamEnd` still ends turns;
- idle timeout 60 s → shorter, with resumption on the next tap;
- a lower compression trigger for long sessions.

## Notes for Part B

- **Measure after with the same script.** Run `VoiceLiveCostTests` again (1 Vertex session, through the budget). It prints `[LIVE-COST]` and the recording, so the "after" row compares like with like. Typed turns don't measure microphone cost. For that, count gated frames offline through `CaptureGate` (the `VoiceActivityDetectorTests` speech and noise mixes) before and after the comfort-noise change.
- **Check routing after trimming descriptions.** `LiveReplayTests` fails if a recorded call's tool is no longer declared or no longer answers. It can't tell whether the model would still pick that tool, so spend one live session on the spike Q3 cases that are at risk.
- **Vertex usage fields.** Reply tokens are `candidatesTokenCount` (handled now). Prompt and reply are split by modality in `promptTokensDetails` and `candidatesTokensDetails`, and `thoughtsTokenCount` is separate. Earlier model speech comes back as prompt `AUDIO` tokens.
- **Resume on tap has two traps in the code.** On Vertex, a handle from a resumed connection is dropped (`resumptionUpdated`), so only a generation-0 handle can carry over. `setupCompleted` sends the first page note only for a fresh session (`freshAt` is nil when resumed), so a resumed session must send the current page note itself. A dead handle already falls back to a fresh session (`connectionEnded`).
- **Comfort noise** (about 1 s at real-time pace, then `audioStreamEnd`) is a field lesson from earlier apps. Shorten it only after a live check that turns still end.
