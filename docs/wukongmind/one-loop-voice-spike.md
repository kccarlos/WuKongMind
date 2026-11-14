# One loop voice spike (task 5)

This page answers the six open voice questions in [design-one-loop.md](design-one-loop.md#voice) with measurements against real Gemini Live. The harness is in [`one-loop-spike/`](one-loop-spike/), and the raw results (every session's event log, minus audio) are in [`one-loop-spike/results/`](one-loop-spike/results/). No app code changed.

- **Model and endpoint:** `gemini-3.8-live` on AI Studio (the app's `GeminiLive.model`), run on 2026-11-14 from the iPhone 18 Pro simulator (iOS 27.2).
- **Wire code:** the harness compiles the app's `LiveProtocol.swift`, `LiveTransport.swift`, `VoiceTools.swift` and `VoiceInstructions.swift` unchanged. So the setup frame, the tool responses, the briefing frame (`name: "briefing"`, WHEN_IDLE) and today's 7 declarations are exactly what the app sends.
- **Drafted tools:** tasks 2, 4 and 10 haven't merged, so the 12 voice tools of the design (and 15 with `list_latest`, `search_comments` and `inject_css`) are drafted in [`SpikeTools.swift`](one-loop-spike/Tests/SpikeTools.swift). Each is in exactly the JSON Schema shape `AgentToolDefinition.inputSchema` emits: lower-case types, `additionalProperties: false`, `minLength`, `minimum` and `maximum`. The browse tools reuse today's `VoiceTool` texts with the new names.
- **Input:** the user's turns go in as typed text (`realtimeInput.text`, the app's typed path), not audio. See [Not measured](#not-measured).
- **Rerun:**

  ```
  herdr-secret run GEMINI_LIVE_KEY -- docs/wukongmind/one-loop-spike/run.sh [testQ1Schema …]
  ```

## Answers

| # | Question | Answer | Voice section |
|---|---|---|---|
| 1 | Schema | Accepted once `additionalProperties` is dropped. No measurable cost in setup time or latency. | Converter confirmed, plus one rule |
| 2 | Fixed tools | A resume with a new setup keeps the conversation, but **silently keeps the old tool list**. | "Declare at connect, refuse later" confirmed |
| 3 | Routing | 30 of 36 right on the first pass. All 6 misses trace to "what do people here think of X" going to search (3), which left the "never mind" after it nothing to cancel (3). One prompt sentence fixed both (6 of 6). | Hand-off confirmed, plus a prompt rule |
| 4 | Hand-off | It works. Briefings at 31 to 90 s were spoken within 0.9 s while the user kept talking, a briefing during a reply waited its turn, and cancel worked 5 of 5. | Contract confirmed |
| 5 | Direct page changes | Unreliable: 0 of 9 passed (6 wrong stylesheets, 3 hand-offs). | Hand-off only confirmed. No direct `inject_css`. |
| 6 | Result size | Latency doesn't degrade up to 64k characters, but **at 80k or more the server closes the session** (1007). | `spokenResult` cap: 8,000 characters |

## 1. Schema

**Probes** ([`q1-schema.json`](one-loop-spike/results/q1-schema.json)): each one opened a session with one `probe` tool and asked the model to call it.

| Probe | Setup | Called |
|---|---|---|
| lower-case types (`object`, `string`) | accepted | yes |
| `additionalProperties: false` | **closed 1007** "Unknown name additionalProperties at setup.tools[0].function_declarations[0].parameters" | no |
| `minLength`, `minimum`/`maximum`, `enum` | accepted | yes |
| `ARRAY` of `INTEGER`, a nested `OBJECT` with `properties` and `required` | accepted | yes |
| an `OBJECT` property with no `properties`; `parameters: {type: OBJECT, properties: {}}`; no `parameters` | accepted | yes |
| the raw `read_page` inputSchema as `parameters` | closed 1007 (`additionalProperties`) | no |
| the raw `read_page` inputSchema as `parametersJsonSchema` | accepted | yes |

**Whole sets:**

| Set | Result |
|---|---|
| today's 7 tools | accepted |
| the 12 voice tools, converted (types upper-cased, `additionalProperties` dropped) | accepted |
| all 15 tools, converted | accepted, and "search this forum for firmware rollback" called `search_forum {"query":"firmware rollback"}` |
| all 15 tools, raw | closed 1007 |

**Timing:** today's 7 tools against the 15 converted tools, interleaved, 5 runs each, measured from "Say hello in one short sentence".

| | Setup to `setupComplete` (median, range) | First audio (median, range) | First turn's prompt tokens |
|---|---|---|---|
| today's 7 | 0.31 s (0.29–0.40) | 0.75 s (0.62–1.28) | 2,782 |
| 15 converted | 0.33 s (0.29–0.33) | 0.72 s (0.61–0.81) | 3,960 |

The 15 tools cost about 1,180 more prompt tokens per turn (the instructions are included in both counts). Since every turn re-bills the context, that is the real cost, not latency.

**For task 10:**
- The converter upper-cases types and drops `additionalProperties`. Everything else `ToolParameterSchema` emits passes through.
- A tool with no parameters may omit `parameters`.
- `parametersJsonSchema` also works, and would make the converter a pass-through. The design's `VoiceSchema` route is kept, because it is what the app's tests already cover. Both are measured to work.

## 2. Changing declarations mid-session

Each session told the model a codeword, waited for a resumable handle, closed, and resumed with the handle and a second setup ([`q2-resume.json`](one-loop-spike/results/q2-resume.json), [`q2-control.json`](one-loop-spike/results/q2-control.json)).

| Resume with | Setup | Codeword kept | New tool `mark_checkpoint` called on "Checkpoint." | Removed tool `browse_focus` called anyway |
|---|---|---|---|---|
| the same tools | accepted | yes | – | yes (as expected) |
| changed tools (run 1) | accepted | yes | **no** ("I'm ready. What's next?") | **yes** |
| changed tools (run 2) | accepted | yes | **no** | **yes** |
| control: the changed tools in a fresh session | accepted | – | yes, 2 of 2 | – |

So the server accepts the new setup, keeps the conversation and **ignores the new declarations**. The model can still call a tool the new setup removed. Resumption can't change tools, and the failure is silent.

The design's default stands: declare at connect, and a tool whose page condition no longer holds answers "not available on this page". Two consequences for the app:
- A dispatcher must refuse names the current setup doesn't hold, even after a resume.
- Changing tools needs a new session (no handle), which loses the conversation. That isn't worth it for a page change.

## 3. Routing

There were 12 utterances, each in a fresh session on a Discourse thread (screen note as `VoiceContext` sends it), run 3 times. The expected first tool was written down before running ([`q3-routing.json`](one-loop-spike/results/q3-routing.json)).

| Utterance | Expected | First pass (no opinion rule) |
|---|---|---|
| Switch to dark mode. | `hand_off_to_agent` | 3/3 |
| Summarize this, then read it to me. | `summarize_topic` or `read_aloud` | 3/3 (`summarize_topic` → `read_aloud` twice, `read_aloud` alone once) |
| Next post. | `browse_move` | 3/3 |
| What do people here think of the N100 for a home server? | `hand_off_to_agent` | **0/3** (`search_forum` each time) |
| Never mind. (after that request) | `hand_off_to_agent` `action: cancel` | 0/3 (no hand-off was running: `end` twice, nothing once) |
| Take me to the solution. | `browse_open` | 3/3 |
| Search for firmware rollback. | `search_forum` | 3/3 |
| Only show what the original poster said. | `browse_focus` | 3/3 |
| What does post 20 say? | `read_post` | 3/3 |
| Notify me of new replies to this thread. | `watch_topic` | 3/3 |
| Go back. | `browse_move` | 3/3 |
| Thanks, that's all. | `end` | 3/3 |

**Prompt fix** ([`q3-routing-opinion-rule.json`](one-loop-spike/results/q3-routing-opinion-rule.json)). The "never mind" misses only followed from the opinion miss. With `search_forum` now a voice tool, the model searched instead of handing off. Adding one sentence to the precedence part of the instruction (`SpikeTools.opinionRule`) fixed it:

> Questions about what people think or recommend, or anything that needs reading several threads, go to hand_off_to_agent even when they name a topic: search_forum only shows cards and can't answer them. Use search_forum when the user asks to find, search or look for something.

- Opinion question: 3/3 handed off (twice directly, once after a `search_forum`).
- "Never mind": 3/3 cancelled.
- Q4 ran with the rule too, and its 7 sessions all handed off (2 after a search).

**For task 10:** add the sentence to `VoiceInstructions`. A search before the hand-off is acceptable, because the cards stay on screen.

## 4. Hand-off and the briefing

Each session asked the opinion question, answered the hand-off `started` with SILENT (today's research reply, renamed), then the user kept talking:
- "Next post" (`browse_move`);
- "What does post 20 say?" (`read_post`);
- then the briefing in today's frame.

Results are in [`q4-handoff.json`](one-loop-spike/results/q4-handoff.json) and [`q4-mid-reply.json`](one-loop-spike/results/q4-mid-reply.json).

| Variant | Briefing sent after | First audio after it | Spoken |
|---|---|---|---|
| idle, ~30 s (run 1) | 43.6 s | 0.88 s | "by the way, the community generally recommends the N100 … limited SATA ports" |
| idle, 90 s | 90.0 s | 0.71 s | the same, correct |
| during a reply (rerun, 2 runs) | 31.0 s, 31.3 s, while the model was answering "tell me more about what carol said" | – | the reply finished, then the briefing in the same breath: "… quiet for the past week. By the way, the community generally recommends the N100 … six watts … sixteen gigabytes of RAM and Proxmox …" (2/2) |
| cancel ("Never mind, stop that." 5 s after) | – | – | `hand_off_to_agent {"action":"cancel"}`, 2/2 (plus 3/3 in Q3's rerun) |

- The 30 s variant waited for the two in-between turns, so it was sent at 43.6 s. The first mid-reply run measured the wrong window and is superseded by the rerun (the raw file keeps it).
- WHEN_IDLE never cut the model off, and no briefing was dropped.
- The non-blocking contract works unchanged with the new tool names.

## 5. Direct dark mode from voice

The voice set gained `inject_css` (the app's definition) and an instruction allowing it. The model was told "Switch to dark mode." on 3 light fixture pages, 3 runs each ([`q5-darkmode.json`](one-loop-spike/results/q5-darkmode.json)). `read_page` answered with a structure list of the fixture. The CSS the model wrote was applied the way `inject_css` does it (a constructed sheet in `adoptedStyleSheets`) in a WKWebView and measured.

The pass rule was fixed before running:
- the page background's luminance is at most 0.1;
- at least 95 % of visible text elements reach 4.5:1 against their effective background;
- no block of 20,000 px² or more keeps a background lighter than luminance 0.4.

| Page | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| Plain article (a `<style>` sheet) | handed off | fail: links on `#0645ad` stay dark blue on `#121212` (1.95:1), blockquote, aside | fail: the same (text 58 %) |
| Inline styles shop | fail: `div { background: #121212 !important; color: #e0e0e0 !important }` leaves inline `h2`/`p` colours at 1.01:1 | fail: the cards, grid and table stay white | handed off |
| Variables and `!important` | fail: `#app { … }` loses to `html body { background: var(--bg) !important }` and `div#app.main`; page still white | fail: the same | handed off |

- 0 of 6 stylesheets passed. Each was 59 to 251 characters, written in one shot from a structure list: no look at the result, no second try.
- The text Agent's page feedback and look-before-acting rules are exactly what this lacks.
- So the owner's default stands: page changes go through `hand_off_to_agent`, and voice gets no `inject_css`. The 3 runs that handed off on their own agree.

## 6. Result size

Each session asked "Read post 20 for me and tell me what its very last sentence says". The model's call was answered with a `read_post` result of N characters, with the fact ("profile number 47") at the very end ([`q6-result-size.json`](one-loop-spike/results/q6-result-size.json), [`q6-bracket.json`](one-loop-spike/results/q6-bracket.json)). There were 2 runs per size.

| Result characters | First audio after the result | Found the fact | First turn's prompt tokens |
|---|---|---|---|
| 1,000 | 0.83, 0.70 s | 2/2 | 4,024 |
| 4,000 | 0.80, 0.74 s | 2/2 | 4,668 |
| 16,000 | 0.62, 0.86 s | 2/2 | 7,244 |
| 32,000 | 0.78, 0.72 s | 2/2 | 10,688 |
| 48,000 | 0.98, 0.69 s | 2/2 | 14,132 |
| 64,000 | 0.78, 0.88 s | 1/2 (run 2 got it as a `browse_move` result and answered from the screen) | 17,546, **past the 16,000-token compression trigger** |
| 80,000, 90,000, 100,000 | – | 0/6: **the server closed the session**, 1007 "Request contains an invalid argument" | – |

- Run 1 of the 32,000 row first measured the tool call's own empty turn end. The bracket rerun with a fixed wait replaces it, and the raw file keeps both.
- Latency doesn't degrade at any size the server accepts. The limits are the context and a hard cliff:
  - a 48,000-character result alone takes the context to 14,000 tokens, and `Setup` compresses at 16,000;
  - somewhere between 64,000 and 80,000 characters the whole session dies.
- **The cap on `spokenResult`: 8,000 characters** (about 2,000 tokens).
  - It stays well inside the compression budget, so a few results and the conversation fit before compression slides back to 4,000 tokens.
  - It is about 2.7 times today's per-post cap (`BrowseText.contentLimit`, 3,000), which leaves room for `read_topic` and summaries.
  - The cap must hold in code for every voice tool, because one over-size result ends the conversation.

## Not measured

- **Spoken input.** Utterances were typed text (`realtimeInput.text`), so voice activity detection, input transcription and barge-in weren't exercised. Routing from real speech may differ slightly. The device acceptance (task 15) says "Switch to dark mode" aloud.
- **Vertex AI.** Only AI Studio was measured, though the app also connects to Vertex.
- **Small samples.** Routing used 3 runs per utterance and 2 to 5 for the rest: enough to see the patterns above, not rates to two digits.
- **Drafted texts.** Tool descriptions and the instruction are drafts. Task 10's real texts should be checked against the same routing script (`testQ3Routing`).
