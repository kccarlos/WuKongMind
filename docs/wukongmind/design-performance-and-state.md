# Design: drawer performance on long threads, and the app's state machines (WUKO-139)

Status: **proposed**. This page holds the measurements, the causes, the decisions and the follow-up tasks. The only code that came with it is the measuring harness; the product behaves as before.

The owner's report (TestFlight 1.5.0, iPhone): on very long threads the drawer is slow and typing in the chat box lags. The case they reproduced it on is Summarize on `doctorofcredit.com/citi-300-checking-bonus/` (6,185 comments).

## The short version

- **One cause explains the report.** Every time the drawer's panel re-renders, it rebuilds the thread's full export text (title, summary and every post) five times, for a Share button and three menu items nobody has opened. On the real thread that is 1.8 million characters, five times per render.
- **Typing triggers a render per keystroke, and the page triggers more.** The draft text lives in the panel, so each character re-renders all of it. On the real page the browser model also published 11 times per keystroke, so the panel rendered 5.7 times per character.
- **Measured on the owner's iPhone 13:** about **2.0 s of main-thread work per keystroke** on the real thread, against 0.32 s on a 20-comment thread under the same test, and 7 ms for the composer by itself. A 61 s Instruments trace of that typing has 82 hangs (18 of them 572 to 637 ms), with 76 % of main-thread time inside `TopicExportPayload.text(options:)`.
- **Three more causes are real but smaller:** every `AppModel` or browser publish re-renders every run in the conversation; the transcript is not lazy (a 60-run conversation takes 0.66 s to open); and, likely but not isolated, cited summary paragraphs lay out one view per word, which makes scrolling a long summary heavy.
- **State machines:** the app already has good explicit ones (drawer phase, dictation, summary run, add forum). Five implicit ones are worth making explicit; two of them (where the summary shows, and whether the transcript follows the bottom) sit in the same file as the performance work and go first.

## 1. Measurements

### How it was measured

| Tool | What it gives | Where |
|---|---|---|
| `DrawerPerformanceTests` | The real `AssistantPanel` hosted in a window with a generated thread. Main-thread milliseconds for one action (open, keystroke, unrelated publish, 300 pt scroll step, one more run), and body-evaluation counts. Inputs vary one at a time. | `WukongMindTests/DrawerPerformanceTests.swift` |
| `LongThreadDrawerPerfUITests` | The whole app: summarize a thread through the fixture model, then type 30 characters, swipe, close and reopen. The app's own probe reports main-thread time, passes over 33/100/250/500/1000 ms, publishes and hot-function time. `testRealLongThread` reads a real page. | `WukongMindUITests/LongThreadDrawerPerfUITests.swift` |
| `PerfProbe` | DEBUG-only counters, timers and signposts in the hot views; a no-op in Release. | `WukongMind/PerfProbe.swift` |
| `scripts/device-check.sh --xctrace` | An Instruments trace (Time Profiler and Hangs) of the phone during the test. | `scripts/device-check.sh` |

- The timer wraps the run loop pass that renders the action (it wakes first and sleeps last, so Core Animation's commit is inside). Idle reads 0.1 ms.
- No model is called anywhere. On the real page the comments come from the site and the summary text from the fixture model. Nothing is saved (`-dc-fixture-model` launches never write).
- **All phone numbers are a Debug build** on the owner's iPhone 13. TestFlight is optimized and will be faster in absolute terms; the ratios and the counts are what carry over. Simulator numbers (Mac mini) are noisier and several times faster, so targets below are set on the phone.
### After task 2 (WUKO-142, 2026-11-17)

The composer owns its draft: `AssistantFooter` holds the draft, focus, dictation and the "Done" hold; the panel reaches the box through `ComposerDrafts.perform`. iPhone 13, Debug, hosted harness (`DrawerPerformanceTests`), keystroke median:

| Fixture | Before (task 1) | After |
|---|---|---|
| `baseline` | 37 ms | 13.6 ms |
| `source-6000` | 37 ms | 14.6 ms |
| `all-6000` | 59 ms | 23.2 ms |
| `runs-20` / `runs-60` | not recorded | 21.1 / 27.9 ms |
| composer alone | 7 ms | 5 to 8 ms |

- `AssistantPanel`, `ChatThread` and run-section bodies: 0 evaluations per keystroke on every fixture (`DrawerRenderCountTests` asserts it).
- **Target missed:** at most 12 ms on every fixture. `baseline` is 13.6 ms and the run fixtures grow with the number of runs (21 to 28 ms) although no body runs: it is UIKit layout and accessibility work over the eager transcript, which task 6 (lazy transcript) addresses. The real-thread test was not re-run here.
- Leaving the Agent route (History) now closes the microphone and parks the draft; it comes back on return.

### After task 3 (WUKO-143, 2026-11-18)

The panel stops observing `ForumBrowserModel` and whole `AppModel` publishes directly: `ForumBrowserModel` publishes an `Equatable` `DrawerPageFacts` value only when drawer-relevant page facts change, `DrawerAppRelay` feeds per-section `SliceBox` stores so an unchanged slice fires no `ObservableObject` update on the hosting view, `DrawerHeader`, `DrawerSummary`, `ChatThread` and `AgentRunSectionView` become `.equatable()` views over value models, and `matchingPageScripts`, `timeline`, `forumSources` and parsed summary sections are cached per input. The covered `WKWebView` is also hidden from accessibility while the compact drawer is at `.large` with the software keyboard up, so full-height sheet typing does not snapshot 6,185 web comments behind the sheet.

**What published 12 times per keystroke on the real page** (`360` `ForumBrowserModel` publishes across 30 keystrokes on `doctorofcredit.com/citi-300-checking-bonus/`):
1. **10.0 per keystroke (300 publishes):** `routeObserverScript` observed `document.head` with `MutationObserver`; third-party ad/analytics scripts mutated `<head>` 60 times (`2.0/key`) and posted route-only messages with identical URL and title. Each `handleRouteMessage` called `updateNavigationState()`, which unconditionally assigned five `@Published` properties (`canGoBack`, `canGoForward`, `isLoading`, `currentURL`, `pageTitle` — `60 × 5 = 300`) even when none changed. Both the JS observer and `updateNavigationState` now deduplicate unchanged values.
2. **2.0 per keystroke (60 publishes):** because `AIDrawer` allows background interaction up through `.medium`, UIKit kept `accessibilityViewIsModal = false` even at `.large`, so XCUITest's accessibility snapshots walked the covered `WKWebView`'s 6,185-comment DOM and caused `WKContentView` to emit 30 `keyboardWillHide` + 30 `keyboardWillShow` notifications (`isSystemKeyboardVisible = 60`), while also adding ~140 ms per keystroke of main-thread accessibility snapshot work.

**iPhone 13, Debug, hosted harness (`DrawerPerformanceTests`), unrelated `AppModel` publish median:**

| Fixture | Original | Before (post-task 2) | After |
|---|---|---|---|
| `baseline` | 47 ms | 41.7 ms | **1.18 ms** |
| `source-100` / `500` / `2000` / `6000` | 56 / 62 / 149 / 387 ms | 39.9 / 42.9 / 40.0 / 39.7 ms | **1.18 / 1.15 / 1.15 / 1.14 ms** |
| `summary-15` / `30` / `60` | 55 / 61 / 60 ms | 42.5 / 39.6 / 46.2 ms | **1.14 / 1.21 / 1.13 ms** |
| `runs-5` / `20` / `60` | 51 / 59 / 59 ms | 46.4 / 57.8 / 66.0 ms | **1.10 / 1.23 / 1.16 ms** |
| `runs-5-shape-500` / `2000` | not recorded | 49.1 / 50.2 ms | **1.05 / 1.19 ms** |
| `all-2000` / `all-6000` | not recorded / 413 ms | 60.9 / 59.0 ms | **1.15 / 1.09 ms** |

- Every fixture is **1.05 to 1.23 ms** (target: at most 5 ms), with `0` `AssistantPanel.body` and `0` `BrowserAgentRunsView.runSection` evaluations per publish (`DrawerRenderCountTests` asserts zero run-section and summary-row evaluations for both unrelated `AppModel` and non-fact `ForumBrowserModel` publishes).

**iPhone 13, Debug, whole-app typing (`LongThreadDrawerPerfUITests`, 30 characters):**

| Metric (per keystroke unless noted) | `fixture-20` before → after | `fixture-6000` before → after | `real-page` (6,185) before → after |
|---|---|---|---|
| Main-thread time per keystroke | 296.7 → **291.6 ms** | 309.9 → **306.4 ms** | 494.5 → **234.2 ms** (1,985 ms original) |
| Typing wall time (30 chars) | 23.3 → 23.1 s | 23.4 → 23.2 s | 43.1 → **22.0 s** |
| `AssistantPanel.body` / `ChatThread.body` | 0.10 / 0.10 → 0.07 / **0.00** | 0.10 / 0.10 → 0.07 / **0.00** | 5.00 / 5.03 → 0.07 / **0.00** |
| `BrowserAgentRunsView.runSection` | 0.10 → **0.00** | 0.10 → **0.00** | 5.00 → **0.00** |
| `ForumBrowserModel` / `DrawerPageFacts` publishes | 0.07 / — → 0.07 / **0.00** | 0.07 / — → 0.07 / **0.00** | 12.00 / — → **0.07 / 0.00** |
| Run loop passes > 100 ms / > 250 ms (total) | 64 / 0 → 63 / 0 | 63 / 0 → 64 / 0 | 78 / 0 → **30 / 0** |
| Close and reopen drawer, main-thread | 3.93 → 4.03 s | 4.32 → 4.26 s | 3.25 → **2.87 s** |

- **Gates re-checked on the iPhone 13:**
  - **Task 6 (lazy transcript):** `AgentRunSectionView.equatable()` already cuts "one more run" on `runs-60` from **2,144 ms to 177 ms** (and `all-6000` open from **666 ms to 298 ms**, new run from **589 ms to 156 ms**), but opening `runs-60` still costs **626 ms** (target: ≤ 300 ms). Task 6's gate holds for opening long multi-run conversations.
  - **Task 7 (cheaper cited text):** `summary-30` scroll step median is **58.4 ms** with **40 of 40** steps over 16.7 ms (from 57 ms, 40 of 40). Task 7's gate holds unchanged.

- How to run each: [DEVELOPMENT.md, "Performance measurements"](../DEVELOPMENT.md#performance-measurements).

### The real thread, on the iPhone 13

Thread as the app held it: 6,185 posts, `TopicSession.source` 1,828,529 characters, summary 2,753 characters, one Agent run. Two fixture threads ran through the same test as controls. The test drives the app through XCUITest, whose own accessibility snapshots cost about 0.3 s of app main-thread time per typed character: the 20-comment row is that floor.

| Typing 30 characters | 20 comments (fixture) | 6,000 comments (fixture) | Real thread, 6,185 |
|---|---|---|---|
| Main-thread time per keystroke | 320 ms | 570 ms | **1,985 ms** |
| of which building export text | 2 ms | 299 ms | **1,527 ms** |
| Panel renders per keystroke | 1.1 | 1.1 | **5.7** |
| Export text builds per keystroke | 5.5 | 5.5 | **28.3** |
| Browser model publishes per keystroke | 0.07 | 0.07 | **11.2** |
| Run loop passes over 250 ms | 0 | 31 | **97** |
| Run loop passes over 1 s | 0 | 0 | **18** |

| Other actions | 20 comments | 6,000 comments | Real thread |
|---|---|---|---|
| Close and reopen the drawer, main-thread time | 3.9 s | 6.7 s | 5.7 s |
| of which building export text | 0.02 s | 2.4 s | 2.4 s |
| One swipe of the transcript | 600 ms | 664 ms | 491 ms |
| Idle for 5 s | 372 ms | 522 ms | 477 ms |

- Scrolling the transcript does not re-render the panel (0 renders in 8 swipes), so it does not depend on thread length. What the owner felt as "the drawer is slow" is the renders: typing, opening, and anything that publishes while the drawer is up.
- Two more runs of the real thread gave 1,873 and 1,978 ms per keystroke: the result repeats.

**The trace** (Time Profiler and Hangs, 61 s while typing on the real thread):

| | |
|---|---|
| Hangs reported | 82: 18 "Hang" (572 to 637 ms) and 64 "Microhang" (251 to 361 ms), main thread at 91 % CPU (busy, not blocked) |
| Main-thread CPU in the window | 34.5 s |
| in `AssistantPanel.body` | 26.8 s (78 %) |
| in `TopicExportPayload.text(options:)` | 26.2 s (76 %) |
| reached through `exportDisabled` → `hasContent(options:)` | 15.8 s |
| reached through `exportText` (Share, file exporter) | 10.5 s |

Heaviest stack of the longest hang: `AssistantPanel.body` → `drawerThread` → `drawerSummary` → `drawerSummaryMeta` → `summaryMoreMenu` → `exportDisabled` → `TopicExportPayload.hasContent(options:)` → `text(options:)`.

### The fixture, input by input (iPhone 13, hosted panel)

One keystroke renders the panel once here (no browser publishes), so these are per-render costs.

| Fixture | Open | Keystroke (median) | Unrelated publish | Scroll step (median) | Steps over 16.7 ms | One more run |
|---|---|---|---|---|---|---|
| Composer by itself | | **6.9 ms** | | | | |
| Baseline (short summary, no posts, no runs) | 93 ms | 42 ms | 47 ms | 32 ms | 7 of 10 | |
| Posts: 100 | 93 ms | 55 ms | 56 ms | 33 ms | 8 of 10 | |
| Posts: 500 | 116 ms | 60 ms | 62 ms | 34 ms | 8 of 10 | |
| Posts: 2,000 | 208 ms | 148 ms | 149 ms | 34 ms | 8 of 10 | |
| Posts: 6,000 | 448 ms | **383 ms** | 387 ms | 38 ms | 8 of 10 | |
| Summary: 15 sections | 95 ms | 51 ms | 55 ms | 44 ms | 21 of 26 | |
| Summary: 30 sections | 119 ms | 59 ms | 61 ms | 57 ms | **40 of 40** | |
| Summary: 60 sections | 125 ms | 60 ms | 60 ms | 60 ms | 40 of 40 | |
| Conversation: 5 runs | 141 ms | 49 ms | 51 ms | 17 ms | 9 of 17 | 134 ms |
| Conversation: 20 runs | 305 ms | 59 ms | 59 ms | 15 ms | 18 of 39 | 687 ms |
| Conversation: 60 runs | **658 ms** | 60 ms | 59 ms | 16 ms | 14 of 40 | **2,144 ms** |
| Everything: 6,000 posts, 30 sections, 20 runs | 666 ms | 412 ms | 413 ms | 81 ms | 40 of 40 | 589 ms |

Deterministic counts per keystroke, the same on every run and on the simulator:

| Per keystroke | Count |
|---|---|
| `AssistantPanel.body`, `ChatThread.body`, `BrowserAgentRunsView.body` | 1 each |
| Run sections re-evaluated | every run (5, 20, 60) |
| `forumSources` (re-derives each answer's sources) | every run |
| Export text builds | 2 as text, 3 more inside `exportDisabled` |
| `summaryPlacement` | 1 to 3 |
| `PostCitations.stripped(summary)` | 1 (6 ms for a normal summary, 24 ms at 30 sections) |

The harness needed non-ASCII text in its posts (curly quotes, a dash, an emoji) to match the real thread: with plain ASCII the same 6,000 posts cost 60 ms per keystroke, not 383 ms. Real comments are not ASCII.

### After task 1 (WUKO-141, 2026-11-17)

Re-measured on the iPhone 13, Debug build, both suites, before and after the change, in one session (the "before" run repeats the tables above). The export text is now built only when Copy, Share or Export is used; `hasContent` answers from the parts.

| iPhone 13 | Before | After |
|---|---|---|
| Hosted, `source-6000` keystroke median | 384 ms | **37 ms** |
| Hosted, `baseline` keystroke median | 44 ms | 37 ms |
| Hosted, `all-6000` keystroke median | 411 ms | 59 ms |
| Hosted, `source-6000` open | 446 ms | 88 ms |
| Hosted, export text builds per keystroke (any fixture) | 5 (2 as text, 3 in `exportDisabled`) | **0** |
| Hosted, stripped summary per keystroke (`summary-30`) | 24 ms | 0.004 ms (cached) |
| Real thread, main-thread time per keystroke | 1,860 ms | **607 ms** |
| Real thread, of which building export text | 1,420 ms | **0** |
| Real thread, run loop passes over 250 ms / over 1 s (30 characters) | 94 / 17 | **0 / 0** |
| Real thread, panel renders / browser publishes per keystroke | 5.5 / 10.8 | 6.0 / 12.0 |
| 6,000-comment fixture, per keystroke | 600 ms | 328 ms |
| 20-comment control, per keystroke | 313 ms | 310 ms |
| Real thread, close and reopen the drawer | 5.6 s | 3.4 s |

- The hosted keystroke no longer grows with the thread: 36 to 38 ms from no posts to 6,000.
- The real thread is still about 2 times the control (607 against 310 ms), not the 460 ms the earlier numbers suggested. What is left is the renders: 6 per character, driven by 12 browser publishes per character (causes 2 and 3, tasks 2 and 3). The gate holds: tasks 2 and 3 go ahead as briefed.

### Causes, ranked

1. **The export text is built in the render path.** `AssistantPanel.exportText` (`SummaryPanel.swift:100`) feeds `.fileExporter(document:)` (`:220`) and `ShareLink(item:)` (`:1324`); `exportDisabled` (`:104`) calls `TopicExportPayload.hasContent` (`Models.swift:648`), which builds the whole text and trims it, for three menu items. Five builds per render, linear in thread size: 75 ms each at 6,000 posts on the phone. This alone is 76 % of main-thread time in the trace.
2. **The draft is panel state.** `@State private var agentDraft` (`SummaryPanel.swift:44`) sits in the 1,400-line `AssistantPanel`, so each character re-renders the header, the summary, the transcript and the footer. Baseline 42 ms per keystroke against 6.9 ms for the composer alone.
3. **The panel observes whole models.** `AssistantPanel` holds `@ObservedObject` for `AppModel`, `StreamStore`, `ForumBrowserModel` and `VoiceController` (`SummaryPanel.swift:28`); `ChatThread` (`:1460`) and `BrowserAgentRunsView` (`AgentPanel.swift:146`) observe `AppModel` too. Any publish costs a full render: 47 to 413 ms on the phone, the same as a keystroke. On the real page the browser model published 11 times per keystroke.
4. **The transcript is eager.** `ChatThread` puts everything in a `VStack` and `BrowserAgentRunsView` in another (`AgentPanel.swift:173`), so every run and every Markdown block exists at once: 658 ms to open 60 runs. One more run arriving cost 2.1 s in the harness, which replaces the conversation with one that has one more run (`restoreConversation`), a stand-in for a run appended by `send`; the likely cost is the scroll-to-bottom settle loop laying the whole stack out repeatedly, which was not profiled.
5. **Cited text is one view per word.** `CitedText` (`MarkdownView.swift:718`) tokenizes its paragraph on every body pass and lays out a `Text` per word in a custom layout. Scroll steps over the cited summary cost 44 to 60 ms against 15 to 17 ms over a conversation, and grow with the summary. This one is **likely, not isolated**: every fixture's summary has citations, so there is no citation-free control, a 300 pt jump is more than one frame of a real scroll, and the Animation Hitches instrument was not recorded. In the whole-app run a swipe cost the same on a short and a long thread.
6. **Small repeats in the render path.** `PostCitations.stripped` compiles a regular expression per segment on every pass (`DrawerHint.swift:164`); `matchingPageScripts` and `summaryPlacement` are computed several times per pass; `timeline` sorts and `forumSources` re-derives sources for every run on every pass.

Checked and **not** a cause:

- **Saving.** The snapshot and the tab conversation are encoded and written off the main thread (`PersistentStore.scheduleSave`, `saveConversation`). Worth knowing all the same: a conversation whose tool rows carry thread shapes is stored twice (`toolCalls` and `runs[].toolCalls`), 33 MB of JSON for five runs over a 6,000-post shape, 195 ms to encode on the phone, in the background.
- **Markdown parsing.** Cached; 0.5 ms per render for a normal summary.
- **JavaScript page reads.** Nothing from the bridge shows on the main thread in the trace.
- **Summary streaming.** Throttled already (`StreamStore`, `ThrottledParse`); not measured further here.

## 2. Implicit state machines

"Implicit" here means: several flags, optionals or stores that together encode one state, with the rules spread over the code that reads them. The house pattern for an explicit one already exists and is the one to copy: a value type with an event enum and one transition function, tested as a table (`DictationMachine`, `Dictation.swift:70`; `SummaryRunState.resolve`, `WorkProgress.swift:171`; `DrawerPhase` with `DrawerPhaseTests`).

**Method and its limits.** The sweep covered every enum named State, Phase, Status, Mode, Activity, Outcome or Readiness (57), every `ObservableObject` and `@Observable` class (28) with its published flags, the views on the drawer path line by line, and the git history for state fixes. Not read line by line: the script manager views, the site adapters, the share extension and the sync engine (off in this build). Small view-local toggles (a sheet shown, a row expanded) are not listed. Agent confirmations (`AgentConfirmationGate`) and script repair inside a run are small queues and are folded into machine 3.

### Already explicit (leave alone)

| Machine | Where | Notes |
|---|---|---|
| Drawer sheet | `DrawerPhase`, `PresentationRouter.swift:113` | closed, presenting, shown, dismissing, recovering, with a watchdog for dropped presentations; `DrawerPhaseTests` |
| Dictation | `DictationMachine`, `Dictation.swift:70` | events and one transition function |
| Summary job | `SummaryRunState.resolve`, `WorkProgress.swift:171`; `WorkStatus`, `Models.swift:1062` | derived from the newest job |
| Add forum | `AddForumPhase`, `ForumDirectory.swift:96` | one detection per address |
| Launch | `LaunchPhase`, `HomeState.swift:152` | runs once |
| Voice session | `VoiceSession.State`, `Voice/VoiceSession.swift:41` | idle, connecting, listening, thinking, speaking, reconnecting, ended, failed |
| Sync | `CloudSyncController.Status`, `CloudSyncController.swift:57` | off by default in this build |
| Content blocking | `ContentRuleLibrary.Phase`, `ContentBlocker.swift:328`; `ContentBlockingStatus`, `:293` | compile phase and per-page status |
| Learn on ask slots | `SiteSlotStatus`, `SiteToolState.swift:8` | untried, learned, broken, failed, notApplicable |
| Onboarding, digest, podcast, translation | `FirstRunStage`, `OnboardingReplay`, `DigestActivity`, `PodcastActivity`, `TranslationPhase` | small, local |

### Implicit, ranked by value over risk

| # | Machine | Where | States it really has | What it allows today | Bugs | Make explicit? |
|---|---|---|---|---|---|---|
| 1 | **Where the summary shows** | `SummaryPanel.swift:1016` (`summaryPlacement`), `:1032` to `:1167` (the conditions), `AppModel.swift:155` (`drawerSummaryHiddenTopicKeys`), `AgentPanel.swift:626` | none; streaming at the top; saved at the top; in the conversation's card; hidden by New conversation; failed; stale | Seven inputs (job state, stream text, saved summary, card row, hidden set, pull job, page state) combined in view code; line `:1120` alone has six conditions. Top and card can both be true, or neither. | WUKO-134 (summary shown twice; New conversation left the top summary) | **Yes, first.** One pure `SummaryPresentation.resolve(inputs)` returning an enum; the view switches on it. High value, low risk: the inputs do not change. |
| 2 | **Transcript follows the bottom** | `ChatThread`, `SummaryPanel.swift:1469` (`atBottom`, `userScrolling`, `scrollTask`) and `ScrollMetricsBox` `:2211` (`nearBottom`, `contentHeight`, `pinningBottom`, `scrolledUp`) | following; user scrolling; scrolled up; jumping; pinning after growth | Seven flags changed from six callbacks; `atBottom == true` with `scrolledUp == true` is reachable; the rules cannot be tested without a scroll view. | 1.3.1 B (New conversation and scroll-to-bottom) | **Yes, second.** `TranscriptFollow` with events (drag began, geometry changed, content grew, run added, jump tapped). It is the precondition for a lazy transcript. Medium risk: behaviour must stay identical, so the table test comes first. |
| 3 | **Agent run** | `BrowserAgentSession`, `BrowserAgent.swift:1220`: `runState` `:1223`, each `runs[i].state`, each row's `isRunning`, `activeTask` and `activeGeneration` `:1262`, `runLimitNotice` `:1246`; rows stored in both `toolCalls` `:1222` and `runs[].toolCalls` | idle; running(step); completed; stopped; step limit; failed | The session's state and the last run's state are written in pairs at about a dozen places (`:1584` to `:1986`); a row can be running in a finished run (`restoreConversation` repairs it after the fact); two copies of every row can differ. | Rows left "running" after a quit (the repair in `restoreConversation`, `:1456`) | **Yes, third.** One `finish(run:with:)` transition; `runState` derived from the last run; one copy of the rows. Medium risk: the saved conversation format has both arrays, so decoding must accept the old file. |
| 4 | **Provider check and model choice** | `ProviderTestState` kept three times as view state (`SettingsProviderForm.swift:654`, `SettingsProviderPage.swift:436`, `:740`), `AppModel.settingsStatus` (a display string, `AppModel.swift:172`), `ModelSelection.model == ""` meaning "none" (`ProviderModels.swift:168`), `ModelReadiness` (`AppModel+Models.swift:484`) | no model; needs key; untested; testing; ok; failed; stale result | A provider with an empty model string is a valid value everywhere; a test result outlives the key it tested; status is text. | WUKO-138 (the model row shows the provider's name; Add to favorites with nothing chosen) | **Yes, after WUKO-138 lands.** A `ModelChoice` that cannot hold an empty model, and one `ProviderCheck` per provider in the model layer. Medium value, low risk. |
| 5 | **Page and browser** | `ForumBrowserModel`, 21 published values (`ForumBrowser.swift:186` to `:347`): `isLoading`, `estimatedProgress`, `isWebViewLoaded`, `isForumsHomeRequested`, `showsCrashNotice`, `pageContext.state`; plus `AppModel.seededPageContext` (`AppModel.swift:1239`) | home; loading; loaded (not forum, maybe, forum home, topic); crashed; unloaded tab | `isLoading` with `showsCrashNotice`; `pageContext.state == .topic` on Home; every value publishes the whole object. | WUKO-126 (late page callbacks rebuilt unloaded web views), WUKO-75 (stale site row) | **Partly.** Do not rewrite the browser. Group what the drawer reads into one small `Equatable` value published only when it changes (task 3 below); leave the rest. High risk if done whole. |
| 6 | Voice, podcast and dictation sharing the microphone | `VoiceController.session` and `startFailure` (`Voice/VoiceController.swift:11`), `PodcastPlayer.isSuspendedForVoice` (`Podcast/PodcastPlayer.swift:195`), `dictationSuspendedPodcast` in the panel (`SummaryPanel.swift:51`) | free; dictating; voice session; podcast playing; podcast suspended | Who owns the audio session is inferred by each party; the "owes a resume" flag lives in a view. | none traced to it | **Later.** An `AudioOwner` value would help, but voice is being changed for cost (voice-cost.md). Revisit after that work. |
| 7 | "Done" status hold in the footer | `SummaryPanel.swift:58` (`showsCompletedStatus`, `completedStatusTask`, `observedAgentID`) | hidden; holding(until) | A timer in view state, restarted from three callbacks | none known | **No.** Small and local; it moves with the footer in task 2. |
| 8 | Script on, off, and turned off automatically | `UserScript.isEnabled` and `disabledReason: String?` (`ScriptStore.swift:1024`, `:1031`), `scriptErrors` (`:1872`), the global switch; `SiteFailureCode.fromDisabledReason` (`SiteToolState.swift:16`) reads the reason back out of its text | on; off by the person; off automatically (load errors, repairs failed); erroring | Why a script is off is a display string that other code parses (`hasPrefix("Turned off after errors on ")`); a reworded string changes behaviour. | none known | **Yes, small, after the trial.** A coded reason next to the text, decoded from old files by the same prefix rule. Not briefed below: low traffic, and it touches saved and synced scripts. |
| 9 | One-shot requests on `AppModel` | `askFocusRequest`, `assistantRequest`, `requestedSettingsPage`, `requestedScriptID`, `savedAnswerRunID`, `needsProviderSetup`, `auditLogRequest` (`AppModel.swift:176` to `:387`), `panelRoute` and `assistantMode` (`:156`, `:159`), `wantsDrawer` beside `drawerPhase` (`PresentationRouter.swift:217`, `:224`) | not a machine: counters and optionals that mean "do this once" | Each is a publish of the whole `AppModel` (cause 3). `assistantMode` still has 34 references after One panel removed the modes. | none known | **No machine.** Task 3 stops them re-rendering the drawer. Checking whether `assistantMode` is dead is a cleanup, not part of this split. |
| 10 | Work jobs | `activities`, `progress`, `streams`, `runningTasks` (`AppModel.swift:315`) | queued; running; completed; failed; cancelled | Status, progress and stream text live in three stores keyed by id | "Fix frozen progress bars" | **No.** `WorkStatus` is explicit and the split stores exist to limit re-renders. |

## 3. Decisions

### Performance strategy

1. **Nothing proportional to the thread runs in a render.** Export text is built when the person taps Copy, Share or Export; menu items are enabled from cheap facts (is there a summary, is there a source, is there a chat). This is the rule the rest follows: a body may read a count or a flag about the thread, never walk its text.
2. **The input owns its state.** The footer (status line, suggestions, composer, dictation, run-limit notice) becomes its own view; the draft lives there (`ComposerDrafts` already exists for exactly this reason). Typing never invalidates the transcript.
3. **Views observe what they draw.** The header, the summary and the transcript become separate views that take values, not the whole `AppModel`. The browser facts the drawer needs (URL, host, is Home, is loading) arrive as one small `Equatable` value. Run sections are `Equatable` views, so a publish that changes nothing re-renders nothing.
4. **Progressive disclosure for long content.** The transcript becomes lazy (runs appear as they scroll in) once following the bottom is an explicit machine; long summaries already use `LazyVStack`. Cited paragraphs keep their chips and 44 pt targets but stop being one view per word outside the lines that hold chips.
5. **Work off the main thread stays off.** Saving already is. Stored tool rows keep one copy.
6. **Not chosen:** paginating posts in the drawer (the drawer never shows posts, only the summary and the conversation); moving `AppModel` to `@Observable` wholesale (large, risky, and the three steps above remove the cost without it); debouncing keystrokes (hides the cost instead of removing it).

### State strategy

- An explicit machine is a value type with an event enum and one transition (or one `resolve`) function, plus a table test, as `DictationMachine` does. No framework, no base class.
- Make explicit only where it pays: numbers 1 to 4 above. Number 5 is narrowed, not rewritten. 6 and 8 wait. 7, 9 and 10 stay.
- A machine is introduced with behaviour unchanged: the table test is written against today's behaviour first, then the view is switched to it.

### How each change is proven

| Proof | Used for |
|---|---|
| The harness numbers before and after, on the iPhone 13 (same Debug build type), with the targets in each brief | every performance task |
| Deterministic counts (`per_key_count`, `per_publish_count`), asserted in a small always-on unit test once a task reaches zero | tasks 1 to 3: a regression fails CI without any timing |
| Table tests on the transition function | tasks 4, 5, 8, 9 |
| The existing suites unchanged: `StateTransitionTests`, `DrawerHintTests`, `DictationTests`, `TabsToolTests`, `IPadLayoutTests`, and the UI smoke set (`SuggestionRowUITests`, `ScriptManagerUITests`), plus `DrawerUITests` and `WordPressUITests` on the Mac mini for the drawer tasks | every task |
| Screenshots of the drawer before and after (same sample launch) for tasks that move views | tasks 2, 3, 6 |

Targets are for the owner's iPhone 13, Debug build, hosted harness, unless a brief says otherwise. The frame budget (16.7 ms) is the goal for a keystroke; the composer by itself is 6.9 ms, so it is reachable.

### Agent experience (AX)

- **Coding agents** get a harness that answers "did I make it slower?" in one command on the Mac mini and one on the phone, counts that are the same on every machine, and signposts named after the views. The state machines become functions they can read and test without launching the app. `SummaryPanel.swift` (2,700 lines, six machines) is split by the tasks below, so a change touches one file with one concern.
- **The in-app Agent** today learns the app's state only from the page context lines. Task 8 adds one `AppStateDigest` (drawer, summary, run, page, voice: one word each) built from the explicit machines. It goes into the audit log and the task export at each transition, and into developer mode. It is **not** added to the model's context by default: prompt caching (1.3.1 A) needs a stable prefix, and a line that changes on every transition would cost it. A read-only `app_state` tool can come later if the trial shows the Agent asking for it.
- **Tests** get `perfProbeState` (this task) and, from task 8, `appStateDigest` as accessibility elements, so a UI test waits on a state instead of on text or a sleep. That replaces fixed sleeps and text matching, the usual source of the flaky UI tests fixed one at a time so far.

## 4. Follow-up tasks

Nine tasks and one acceptance task. Sizes count changed lines, tests included.

**Rules for every task**
- Adding or removing a file means regenerating `WukongMind.xcodeproj` with `ruby scripts/generate_project.rb`; never hand-merge `project.pbxproj`.
- No visible change unless the brief says so: same layout, same strings, same accessibility identifiers.
- Simulator builds and tests with `scripts/remote-test.sh`; the phone only through `scripts/device-check.sh`.
- Each performance task puts its before and after numbers (the two commands in DEVELOPMENT.md "Performance measurements") in its proof, from the iPhone 13.
- **Gates.** One cause is three quarters of the time. Re-measure on the phone after task 1 and again after task 3, and put the numbers on this page. Tasks 6 and 7 go ahead only if their "from" numbers still hold and the owner still feels them; otherwise they are closed unbuilt.
- **Order.** Tasks 1 to 6 all edit `SummaryPanel.swift` and run strictly one after another. Task 7 (`MarkdownView.swift`), task 8 (`BrowserAgent.swift`) and task 9 (settings) touch other files and can run beside them, one at a time each.

### 1. Performance 1: no export text while rendering
- **Status:** done in WUKO-141; numbers in "After task 1". The always-on guard is `DrawerRenderCountTests` (zero `AssistantPanel.exportText` and `TopicExportPayload.text` builds while the drawer opens and while typing; `exportDisabled` still runs per render but no longer builds text, so the test asserts it does run, which proves the menu was rendered).
- **Why:** 76 % of main-thread time while typing on the owner's thread (cause 1).
- **Read:** this page, "Causes" 1 and 6.
- **Scope:**
  - `Models.swift`: `TopicExportPayload.hasContent(options:)` answers from `hasTitleAndURL`, `hasSummary`, `hasSource`, `hasChatHistory` and the options, without building text.
  - `SummaryPanel.swift`: Share, Copy and Export build the text when tapped. Share presents the system share sheet with a plain-text activity item, which keeps the sheet's Copy action and text preview. The iPad popover is anchored to the summary's More button. `.fileExporter` gets its document when `exporting` turns true.
  - `DrawerHint.swift`: `PostCitations.stripped` compiles its expressions once (static), and the panel caches the stripped summary by summary text.
  - Tests: `hasContent` equals the old answer for every combination of options and empty parts; a unit test asserts zero `AssistantPanel.exportText` and `exportDisabled` builds per keystroke with `PerfProbe`.
- **Size:** about 200. **Depends on:** nothing.
- **Done when:** on the iPhone 13, `source-6000` keystroke median is at most 55 ms (from 383 ms) and within 10 ms of `baseline`; in `testRealLongThread` no time is spent building export text while typing (from 1,527 ms per keystroke), which by today's numbers leaves about 460 ms per keystroke against the 320 ms control (the rest is the 5.7 renders per character, task 3); Copy, Share and Export produce byte-identical text to before (test).

### 2. Performance 2: the composer owns its draft
- **Why:** each character re-renders the whole panel (cause 2); 42 ms against 6.9 ms.
- **Read:** "Causes" 2; `ComposerDrafts.swift`; `DictationTests`.
- **Scope:**
  - `AssistantFooter.swift` (new): the status line, suggestion row, dictation notice, composer and run-limit notice, with the draft, the focus, the dictation ownership (`dictationBase`, `dictatedDraft`, `dictationSuspendedPodcast`) and the "Done" hold moved out of `AssistantPanel`.
  - `SummaryPanel.swift`: the panel passes actions and no longer reads the draft; filling the box from a suggestion or a kept question goes through `ComposerDrafts`.
  - Tests: `DictationTests` and `SuggestionRowUITests` unchanged; a unit test asserts zero `AssistantPanel.body`, `ChatThread.body` and run-section evaluations per keystroke.
- **Size:** about 450 (mostly moved). **Depends on:** 1.
- **Done when:** keystroke median is at most 12 ms on every fixture on the iPhone 13 (from 42 to 412 ms); the folded "Step N" header while typing during a run, the suggestion row hiding on the first character, sending, dictation and voice behave as before (existing tests, plus before and after screenshots).

### 3. Performance 3: the drawer observes what it draws
- **Status:** done in WUKO-143; numbers and gate re-check in "After task 3". `DrawerRenderCountTests` asserts zero run-section, summary-row and cache evaluations on unrelated `AppModel` publishes and on non-fact `ForumBrowserModel` publishes.
- **Why:** any publish costs a full render, and a real page publishes constantly (cause 3).
- **Read:** "Causes" 3; state machine 5.
- **Scope:**
  - `ForumBrowser.swift`: a `DrawerPageFacts` value (URL, host, shows Home, is loading) published only when it changes; the panel stops observing `ForumBrowserModel`.
  - `SummaryPanel.swift`, `AgentPanel.swift`: `DrawerHeader`, `DrawerSummary` and the transcript become views that take values and closures. Run sections become an `Equatable` view keyed by the run and the few settings it reads, used with `.equatable()`. `forumSources`, `timeline` and the script matches are computed once per change, not per pass.
  - The probe finds what the real page publishes 11 times per keystroke; say what it was in the proof.
  - `AppModel` stays an `ObservableObject`, so a view that holds it as `@ObservedObject` still re-evaluates on every publish. The mechanism is: the panel's root and the new child views hold `AppModel` as a plain `let` (for actions) and take what they draw as values from a thin observing wrapper per section; that wrapper's body only builds the `Equatable` child, so its own re-evaluation is cheap and the child's is skipped when nothing it draws changed.
  - Tests: a unit test asserts zero run-section evaluations and zero summary-row evaluations for an unrelated `AppModel` publish and for a browser publish that changes no drawer fact.
- **Size:** about 600. If it runs over, split the header and summary views from the run sections and tell the Assistant. **Depends on:** 2.
- **Done when:** on the iPhone 13 an unrelated publish costs at most 5 ms on every fixture (from 47 to 413 ms); in `testRealLongThread` typing costs within 20 % of `testShortFixtureThread` (from 6 times) and no run section is re-evaluated while typing; the drawer looks the same in light and dark at both heights (screenshots).

### 4. State 1: where the summary shows
- **Why:** state machine 1; WUKO-134's class of bug.
- **Read:** "Implicit state machines" 1; the WUKO-134 pull request (#137).
- **Scope:** `SummaryPresentation.swift` (new): inputs (job state, has stream text, has saved summary, card row, hidden by New conversation, pull job, page state, has conversation) and `resolve` returning what the top section and the card show. `SummaryPanel.swift` switches on it; the boolean conditions at `:1032` to `:1167` and `canStartNewConversation` go. Tests: a table of every input combination that can occur, including both WUKO-134 cases.
- **Size:** about 350. **Depends on:** 3.
- **Done when:** the table test passes; no input combination shows the summary twice or loses its progress or error; `StateTransitionTests` and the WUKO-134 tests pass unchanged.
- **Result (WUKO-149):** `SummaryPresentation.resolve` maps the eight inputs to `Top`, `Card`, `showsPullProgress` and `canStartNewConversation` (`SummaryPresentation.swift`); `SummaryPanel.swift` (`HeaderSectionObserver`, `TranscriptSectionObserver`, `SummarySectionObserver`, `DrawerSummary`) switches on it with `SummaryPlacement`, `canStartNewConversation` and the view-level boolean conditions removed, and `AppStateDigest.summaryDigestWord` reads `SummaryPresentation` directly. `SummaryPresentationTests` covers both WUKO-134 cases and all 140 reachable input combinations (plus 1,440 Cartesian combinations for the double-render invariants). No performance numbers: state task with behaviour unchanged.

### 5. State 2: following the bottom of the transcript
- **Why:** state machine 2; the precondition for task 6.
- **Scope:** `TranscriptFollow.swift` (new): the state and the events (drag began or ended, geometry changed, content grew, run added, voice turn added, jump tapped, topic changed) with one transition function returning the next state and an effect (none, scroll now, settle to bottom). `ChatThread` keeps only the scroll view plumbing. Tests: a table written from today's behaviour first (each `onChange` and callback in `ChatThread`), including "scrolled up while a run streams stays put" and "a new run jumps to the bottom".
- **Size:** about 400. **Depends on:** 4.
- **Done when:** the table test passes; `DrawerUITests` and the scroll tests of 1.3.1 B pass unchanged on the Mac mini.

### 6. Performance 4: a lazy transcript
- **Why:** cause 4: 658 ms to open 60 runs, 2.1 s for one more run (a stand-in measurement). Gated: see "Gates".
- **Scope:** first measure a run appended by `send` (a recorded model client) so the 2.1 s is confirmed on the real path. Then `AgentPanel.swift`, `SummaryPanel.swift`: runs in a `LazyVStack` with stable ids; the settle loop scrolls to the last run's id instead of re-laying out the stack; the newest run stays eager so its height is exact while it streams.
- **Size:** about 300. **Depends on:** 5.
- **Done when:** on the iPhone 13, `runs-60` opens in at most 300 ms (from 658) and takes one more run in at most 150 ms (from 2,144); `all-6000` opens in at most 300 ms (from 666); scroll-to-bottom, the jump button and VoiceOver order behave as before (task 5's table and `DrawerUITests`).

### 7. Performance 5: cheaper cited text
- **Why:** cause 5 (likely, not isolated). Gated: see "Gates".
- **Scope:** first add a citation-free summary fixture to `DrawerPerformanceTests` and record Animation Hitches on the phone while scrolling a cited summary; stop here if citations are not the cost. Then `MarkdownView.swift`: `CitedText` caches its tokens per source; runs of words between chips become one `Text` each (a line that holds a chip keeps the flow layout, so chips keep their size, spacing and 44 pt targets). Tests: `WordPressUITests` citation taps and `IPadLayoutTests` unchanged; a snapshot comparison of a cited paragraph before and after.
- **Size:** about 300. **Depends on:** nothing (other file); not at the same time as another `MarkdownView.swift` change.
- **Done when:** on the iPhone 13, `summary-30` scroll step median is at most 20 ms (from 57) and at most 10 of 40 steps are over 16.7 ms (from 40); citation taps land as before.

### 8. State 3 and AX: one Agent run state, and the state digest
- **Why:** state machine 3; the AX section.
- **Scope:**
  - `BrowserAgent.swift`: one `finish(run:as:)` and one `advance(run:step:)` transition replace the paired writes; `runState` is derived from the last run; `toolCalls` is derived from `runs` (the saved file still decodes with both arrays, and writes one).
  - `AppStateDigest.swift` (new): drawer, summary, run, page and voice as one word each, from the explicit machines; written to the audit log and the task export on change; shown in developer mode; exposed as the `appStateDigest` accessibility element under a DEBUG flag.
  - Tests: transitions as a table (every end state from running; stop during a tool call; restore of a file saved mid-run); an old saved conversation decodes; the digest for five known states.
- **Size:** about 550. **Depends on:** nothing in tasks 1 to 7 (other files), but after task 4 for the summary word.
- **Done when:** no place outside the two transitions assigns a run's state (grep in the proof); a saved conversation with thread shapes is half the bytes (the hot-functions test prints it); `AgentLoopTests`, `TabsToolTests` and `OneLoopAcceptanceTests` pass unchanged.
- **Result (WUKO-146):** `BrowserAgentRun.state` is `private(set)` and mutates only in `advance(step:maxSteps:appending:)` and `finish(as:duration:)`; `BrowserAgentSession.runState` (`runs.last?.state ?? .idle`) and `toolCalls` (`runs.flatMap(\.toolCalls)`) are derived, and `SavedAgentConversation` decodes legacy files carrying both `runs` and `toolCalls` while writing only `runs`. In `DrawerPerformanceTests.testHotFunctionsScaleWithThreadLength`, saved conversation bytes drop by half across every thread size (`posts-100`: 880,387 → 443,791 B; `posts-500`: 3,103,047 → 1,555,121 B; `posts-2000`: 11,475,807 → 5,741,501 B; `posts-6000`: 33,867,607 → 16,937,401 B, encode 84.2 → 40.2 ms on the Mac mini). `AppStateDigest` (`drawer`, `summary`, `run`, `page`, `voice` as one word each; the summary word reads existing `AppModel` state until task 4's `SummaryPresentation` replaces it) is recorded to `AuditLog` (`.state`) and `TaskRecordStore` / `TaskExportDocument.states` on change during Agent tasks, shown in Developer mode (`This page › Developer`, `Settings › Agent › Developer`, and `Audit log › task`), and exposed as the `appStateDigest` accessibility element under `-dc-state-debug`.

### 9. State 4: model choice and provider check
- **Why:** state machine 4; WUKO-138's class of bug.
- **Scope:** after WUKO-138 is merged. `ProviderModels.swift`, `AppModel+Models.swift`: a `ModelChoice` (none, or provider with a non-empty model) behind `ModelSelection`'s storage, so "provider without a model" is a case and not an empty string. One `ProviderCheck` per provider in `AppModel` (untested, testing, ok, failed, with the key and model it tested) replaces the three view copies and `settingsStatus`. Tests: transitions as a table; a result is dropped when its key or model changes.
- **Size:** about 400. **Depends on:** WUKO-138.
- **Done when:** the three settings views read one state; `ModelSwitchingTests`, `StateTransitionTests` and `SettingsNavigationUITests` pass unchanged; saved settings from 1.5.0 load unchanged (test with a recorded file).
- **Result (WUKO-144):** `ModelChoice` (`.none`, or `.model(provider, non-blank model)`) is the typed view of `ModelSelection`; the saved form stays `{provider, model}`, so 1.5.0 settings load and save unchanged (`testSettingsRecordedByVersion150LoadUnchanged`). `AppModel.providerChecks` keeps one `ProviderCheck` (untested, testing, ok, failed, plus the key, address and model it tested) per provider; `providerTestState(for:model:)` reads it and drops a result whose key, address or model no longer matches. The model role page, the provider page, the setup form (sheet and first run) and Onboarding read that one state; their `@State`/`@Binding` copies and `settingsStatus` (never shown) are gone. No performance numbers: this change is not on the drawer's path.
- Provider-wide checks have no model target. A role without a model can show its own validation message and still waits for a model in first-run setup. A check can update or clear its result only while it owns that provider's pending status.

### 10. Acceptance
- **Scope:** run both measurement suites and one Instruments trace on the iPhone 13 on the owner's thread; update the tables on this page with before and after; list any target missed and why.
- **Done when:** on the real thread, typing costs within 20 % of the 20-comment control, no run loop pass is over 250 ms while typing, and the trace reports no hang.

## 5. Not proven here

- **Release numbers.** Everything on the phone is a Debug build. The TestFlight build is faster in absolute terms; the causes and the ratios are the same code.
- **A real model summary.** The real page's summary text came from the fixture model (a realistic shape, 2,753 characters). No model was called.
- **Why the real page publishes 11 times per keystroke.** Explained and fixed in task 3 (WUKO-143): 10.0 publishes/key came from `<head>` `MutationObserver` firing on ad/analytics mutations and `updateNavigationState()` assigning 5 unchanged `@Published` properties per message (`60 × 5 = 300`), and 2.0 publishes/key (`isSystemKeyboardVisible = 60`) came from XCUITest snapshotting the non-modal covered `WKWebView` while the drawer was at `.large`.
- **The SwiftUI instrument.** The trace is Time Profiler and Hangs; body counts come from `PerfProbe` instead.
- **"One more run".** Measured by replacing the conversation with one that has one more run, not by a run the Agent appends; task 6 measures the real path first.
- **Cited text as the scroll cost.** No citation-free control, and Animation Hitches was not recorded; task 7 starts with both.
- **iPad.** All numbers are the phone drawer; the split panel uses the same `AssistantPanel`.
- **Streaming while typing.** Not measured separately; it publishes through `StreamStore`, which the panel observes, so cause 3 covers it.
