# Design: performance 2 — slow drawer open, blank Share, long sessions (WUKO-155)

Status: **proposed**. A diagnosis and a plan. The only code that came with it measures: a per-touch timeline in `PerfProbe`, three whole-app tests and one unit test. The product behaves as before.

It builds on [design-performance-and-state.md](design-performance-and-state.md) (WUKO-139: typing on long threads, tasks 1 to 10) and does not repeat its measurements.

The owner's report (1.5.1, TestFlight, iPhone 13):

1. The 金箍 button takes 1 to 2 s before the drawer appears.
2. On a summary, Share or Export .txt opens a blank screen.
3. Long threads and long sessions still feel slower.

## The short version

- **Share: a blank screen reproduced, one step later than expected.** The app's own share sheet and the Files picker opened on every thread size. The blank screen comes when the text is handed on: Share › Messages with a 1.8 or 2.1 million character thread shows an empty sheet for at least 15 s (two runs, one on each long thread); with a 7,000 character thread the message opens with the text in it (two runs). The app hands the system one in-memory string, and the receiving app has to draw all of it. Whether this is the blank screen the owner saw is not confirmed, and **a blank screen on Export .txt was not reproduced**.
- **Drawer open: the cost is building and drawing everything in the transcript, every time.** The sheet is rebuilt on each open, and a summary card in the conversation is not lazy. From finger lift to the sheet's first frame: **141 to 151 ms** when the summary is the lazy one at the top (the owner's real thread), **365 ms** for a summary of similar length as a card (the fixture's text, not the same one), **629 ms** for a Chinese summary card half as long. Then the system's sheet animation runs, with a 100 to 200 ms stall for drawing text at its start.
- **Chinese costs more than English because cited text is one view per Chinese character** (one per word in English). Drawing text and making its layers is 48 % of the open.
- **Thread length no longer matters for opening** (20 or 6,000 comments: 365 against 378 ms). What matters is how much the conversation holds: summary blocks and runs.
- **The optimized build is not much faster than Debug** where both were measured: the hosted panel's numbers on the phone are within 0 to 25 % of the first page's latest Debug ones. The time is in SwiftUI, UIKit and CoreText, not in the app's own code (an app frame is on the stack in 9 % of the samples of an open).
- **The button gives no feedback until the finger lifts** (read in the code, not timed), so the whole press is added to what is felt.
- **Saved state grows with every long thread:** 3.1 MB of `state.json` per 6,000-comment thread, read on the main thread at launch (136 ms for 20 of them) and rewritten whole on each save.

## 1. Measurements

### How it was measured

| Tool | What it gives | Where |
|---|---|---|
| `PerfTimeline` (new) | For one touch: when the screen was touched and when the app heard, named moments (tap handler, each drawer phase), first and last evaluation of each probed view body, every main run loop pass of 8 ms or more, and the first display-link tick after each moment. Milliseconds from the touch down, read by a test as the `perfTimeline` accessibility element. | `WukongMind/PerfProbe.swift` |
| `testOpenShareExport…` (new) | The whole app with animations on: first open, summarize through the fixture model, six opens, then Share and Export .txt with screenshots at fixed times; optionally hand the text to a share target. The test taps and then asks the app nothing for 4.5 s, so no accessibility query is inside the timing. | `WukongMindUITests/LongThreadDrawerPerfUITests.swift` |
| `testStateLoadScalesWithSavedThreads` (new) | `PersistentStore` save and load, and a tab conversation decode, on generated state in a temporary folder. | `WukongMindTests/DrawerPerformanceTests.swift` |
| Time Profiler | 75 s over five opens, app frames symbolicated with `atos`, system frames from the device support symbols. | `scripts/device-check.sh --xctrace 'Time Profiler'` |

- **Device and build:** the owner's iPhone 13 (iOS 27.2.1). The build is the Debug configuration compiled with `-O` and whole-module (an `XCODE_XCCONFIG_FILE` override), so `PerfProbe` and the `-dc-` arguments exist and the code is optimized as in TestFlight. A true Release build cannot run the harness.
- **Clock:** "from lift" is from the touch-up time of the tap event. The test's tap lasts 58 ms; a person's is longer.
- **First frame** is the first display-link tick after the sheet's content appeared (`DrawerPhase.shown`): the commit that starts the sheet's animation. The animation itself is the system's (about half a second; not timed here).
- No model is called. The real thread is `doctorofcredit.com/citi-300-checking-bonus/` (6,185 posts, 1,828,529 characters); on the phone it showed the summary the owner had saved the day before. Launches with `-dc-fixture-model` never write.

### Symptom 1: tap to first drawer frame

Medians of six opens, milliseconds from finger lift (range of the first frame in brackets). **After** numbers are from the WUKO-164 acceptance run on `main` (`68d074d`, tasks 1–4 and gates merged, same iPhone 13 and optimized-Debug build).

| Case | Summary blocks built (before → after) | Tap handler (before → after) | `.presenting` (before → after) | `.shown` (before → after) | First frame (before → after) | Main thread busy, first 1.3 s (before → after) | Longest pass after the first frame (before → after) |
|---|---|---|---|---|---|---|---|
| Real thread, saved summary at the top (lazy) | 5 → **5** | 8 to 18 → **29.5** | 22 to 32 → **45.0** | 99 to 109 → **107.5** | 141 to 151 (135 to 160) → **145.5** (141 to 150) | 172 → **196.5** | 20 → **18.0** |
| 20 comments, summary card, English, 2,606 characters | 41 → **8** | 18 → **34.5** | 37 → **54.5** | 230 → **132.5** | 365 (349 to 373) → **159.5** (155 to 163) | 605 → **144.5** | 169 to 203 → **8.0** |
| 6,000 comments, the same summary card | 41 → **8** | 18 to 21 → **35.5** | 35 to 39 → **54.0** | 234 → **134.0** | 376 to 378 (364 to 393) → **166.0** (153 to 168) | 624 to 638 → **239.5** | 161 to 209 → **22.0** |
| 20 comments, summary card, Chinese, 1,310 characters | 41 → **8** | 11 → **32.5** | 33 → **51.5** | 349 → **131.5** | 629 (623 to 638) → **160.5** (154 to 165) | 890 → **149.5** | 99 → **0.0** (8.0 after 1.3 s) |
| First open after launch, nothing summarized | 0 to 4 → **0 to 4** | 10 to 22 → **21 to 44** | 28 to 39 → **32 to 93** | 113 to 215 → **133 to 262** | 141 to 275 → **165 to 304** | 131 to 285 → **174 to 350** | none → **0 to 19** |

- Three runs of the real thread (medians 141, 146 and 151 ms) and two of each fixture agree within 15 ms.
- Per open, every case: `ContentView.body` 3 times, `AssistantPanel.body` 3 times, one run section, and every summary block of the card (41) against 5 for the lazy summary.
- Instruments' Hangs track reports each of the five traced opens as a microhang of 359 to 376 ms.
- The whole open is one run loop pass from the tap to the first frame (the display link is silent for 345 to 373 ms), then a second pass of 100 to 200 ms that draws the text while the sheet is already moving.

**What runs in between** (Time Profiler, five opens of the 6,000-comment fixture, 587 ms of main thread per open):

| Per open | Time | Share |
|---|---|---|
| View bodies and graph update (AttributeGraph) | 210 ms | 36 % |
| Drawing text into display lists (`ResolvedStyledText`, TextKit, CoreText) | 155 ms | 26 % |
| UIKit views and layers for the content (`DisplayList.ViewUpdater`) | 124 ms | 21 % |
| Measuring text | 40 ms | 7 % |
| Core Animation commit | 27 ms | 5 % |
| SwiftUI layout (`sizeThatFits`, place) | 21 ms | 4 % |
| Other | 9 ms | 1 % |

Inside those (a sample counts once per line, so lines overlap):

| On the stack | Per open |
|---|---|
| `UISheetPresentationController _transitionWillBegin` (the sheet lays out its new content) | 186 ms |
| Text selection set up for each selectable text (`UITextInteractionAssistant`, context-menu interactions) | 57 ms |
| `CitationFlowLayout.makeCache` | 19 ms |
| `AppModel.drawerHintInput` (the Dock and the AI button re-evaluate at each drawer phase) | 13 ms |
| `AppleIntelligenceClient.currentStatus` (asked from that re-evaluation) | 12 ms |
| `PhoneAIButton.body` | 11 ms |
| Any frame of the app's own binary | 9 % of samples |

**Content is what scales** (hosted panel, `DrawerPerformanceTests`, same phone, optimized build; **before → after** WUKO-164 on `68d074d`, with the first page's post-task-3 Debug number in brackets where recorded):

| Fixture | Open (before → after) | Keystroke median (before → after) | Scroll step median (before → after) | One more run (before → after) |
|---|---|---|---|---|
| Baseline | 74 → **58.4 ms** | 12.7 (13.6) → **13.1 ms** | 28 → **19.1 ms** | |
| Posts: 6,000 | 76 (88) → **56.6 ms** | 14.4 (14.6) → **13.7 ms** | 34 → **19.3 ms** | |
| Summary: 30 sections (lazy, at the top) | 89 → **72.4 ms** | 15.3 → **13.8 ms** | 56 (58) → **17.7 ms** | |
| Summary: 30 sections, Chinese (added in task 4) | 127.1 → **86.0 ms** | — → **13.7 ms** | 121.9 → **18.0 ms** | |
| Conversation: 5 runs | 119 → **68.1 ms** | 17.2 → **14.0 ms** | 20 → **17.2 ms** | 122 → **52.8 ms** (`send`: 141.0) |
| Conversation: 20 runs | 247 → **61.7 ms** | 20.9 (21.1) → **13.8 ms** | 14 → **18.2 ms** | 121 → **67.8 ms** (`send`: 269.7) |
| Conversation: 60 runs | 637 (626) → **60.7 ms** | 26.2 (27.9) → **15.0 ms** | 16 → **18.6 ms** | 134 (177) → **51.1 ms** (`send`: 307.6) |
| Everything: 6,000 posts, 30 sections, 20 runs | 276 (298) → **66.6 ms** | 23.5 (23.2) → **15.1 ms** | 76 → **18.7 ms** | 146 (156) → **55.8 ms** (`send`: 127.9) |

The hosted open has no sheet and no cited summary card; in the whole app one cited card of 41 blocks costs 605 ms where five plain runs of 29 blocks cost 119 ms hosted.

### Symptom 2: Share and Export .txt

Runs on the phone: three thread sizes at the large drawer height (each twice or more) and the real thread again at the medium height. Both fixtures also ran on the simulator, where both sheets opened.

| | 20 comments (7,111 characters) | 6,000 comments (2,113,610) | Real thread (1,828,529) |
|---|---|---|---|
| Building the export text (main thread) | 1 to 2 ms → **0 ms** (`Task.detached`) | 63 to 76 ms → **0 ms** (`Task.detached`) | 71 to 79 ms → **0 ms** (`Task.detached`) |
| Share: main-thread passes after the tap | 179 to 248 ms, then 31 → **33 to 38 ms** tap, then **194 to 212 ms** UIKit sheet | 337, then 35 to 62 → **35 ms** tap, then **287 ms** UIKit sheet | 290 to 325, then 229 to 367 → **52 ms** tap, then **296 ms** UIKit sheet |
| The app's share sheet | shown → **shown** (inline text) | shown → **shown** (`wukongmind-….txt`, `Text Document · 2.2 MB`) | shown (large and medium) → **shown** (`wukongmind-www-doctorofcredit….txt`, `Text Document · 1.9 MB`) |
| **Share › Messages** | **the message opens with the text** (2 runs: English and Chinese summary; WUKO-158 confirmed unchanged) | blank sheet for 15 s → **`New Message` with `2.2 MB` `.txt` attachment within 3 s** | blank sheet for 15 s → **`New Message` with `1.9 MB` `.txt` attachment within 3 s** |
| Export .txt: main-thread passes after the tap | 59, then 72 → **30 to 32 ms** tap, max **36 to 75 ms** | 138, then 83 → **63 ms** max (WUKO-158; skipped here when `DC_PERF_SHARE_TARGET=Messages` exits after Share) | 111, then 185 → not re-run (skipped when `DC_PERF_SHARE_TARGET=Messages` exits after Share) |
| The Files picker | shown → **shown** (`Save` button visible) | shown | shown; its file list was still empty 3.9 s after the tap in one run of three |

- The share sheet's header shows the app icon and nothing else: no title, no size, no preview of what is being shared.
- **Why the screen is blank:** `ExportShareAnchor.present` (`SummaryPanel.swift:2368`) gives `UIActivityViewController` one `ExportActivityItem` that returns the whole text as a `String`, as the placeholder and as the item. The target app receives 1.8 million characters as a message body and never gets as far as drawing its screen. The app's own main thread is fine: two passes of about 0.3 s, no long hang.
- It is not the sheet height (medium and large behave the same) and not the build of the text (under 80 ms).
- Export .txt hands `fileExporter` a `PlainTextDocument` holding the same string; the picker opened every time. Saving was not pressed (it would write to the owner's Files).

### Symptom 3: long threads and long sessions

**Saved state** (iPhone 13, optimized build, generated state, pretty-printed JSON as the app writes it):

| Saved threads | `state.json` | Load (main thread, at launch) | Save (background, whole file) |
|---|---|---|---|
| 40 threads of 100 posts | 2.3 MB | 6 ms | 10 ms |
| 1 thread of 6,000 posts | 3.1 MB | 7 ms | 12 ms |
| 5 threads of 6,000 posts | 15.6 MB | 35 ms | 60 ms |
| 20 threads of 6,000 posts | 62.4 MB | **136 ms** | **269 ms** |

| Tab conversation (5 runs) | File | Decode (main thread, at launch, per restored tab) |
|---|---|---|
| Thread shapes of 500 posts | 1.6 MB | 7 ms |
| Thread shapes of 6,000 posts | 16.9 MB | 72 ms |

- Retention keeps up to 40 summarized topics and 60 visited ones, each with its full text and raw pages (`SessionRetention.swift`), all in one file and all in memory. The generated threads have no raw pages; real ones do, so real files are larger.
- What the owner's phone actually holds was not read (it is their data).
- The rest of "long sessions get slower" is the table above: opening grows with the runs in the conversation, and scrolling a cited summary is still 56 ms a step.

## 2. Causes, ranked by what the owner feels

1. **Share hands the system 1.8 million characters as one string.** Blank screen in the receiving app in both runs on the long threads (one each), and in neither run on the short one. A correctness bug more than a speed one. Only Messages was tried.
2. **The drawer builds, lays out and draws its whole transcript on every open.** `.sheet` makes `AssistantPanel` from nothing each time (`AIDrawer.swift:50`), and the summary card and the runs are in plain `VStack`s (`AgentPanel.swift`, `DCResultCard` in `ConversationViews.swift:275`), so cost follows content, not what is visible: 141 ms lazy against 365 ms as a card for summaries of similar length (different text and page, so the gap is indicative; the block counts, 5 against 41, are exact); 119 to 637 ms hosted from 5 to 60 runs.
3. **Cited text is one `Text` per word, and one per Chinese character** (`CitedText.tokens`, `MarkdownView.swift:787`: a wide character ends a token). Half the characters, 1.7 times the time: 629 ms against 365 ms. Text drawing and its layers are 48 % of an open.
4. **No feedback on touch down.** `PhoneAIButton` is a bare `onTapGesture` with `onLongPressGesture` (`PhoneBrowserBar.swift:1888`): nothing changes on screen and the haptic (`ContentView.openAssistant`) comes at lift. The handler runs 4 to 23 ms after lift, so the gesture itself adds no delay; the press does.
5. **A stall at the start of the sheet's animation.** 100 to 200 ms of text drawing in the pass right after the first frame. Same root as 2 and 3.
6. **Selectable text sets up interactions eagerly:** 57 ms per open for text nobody is selecting.
7. **Saved state holds every thread's full text** in one file read on the main thread at launch and rewritten whole. 136 ms and 62 MB at 20 long threads; unmeasured on the owner's phone.
8. **The open is a chain of root re-renders** (`wantsDrawer` › `onChange` › `.presenting` › `onAppear` › `.shown`): real (three root and three panel evaluations) and small (about 20 ms from the tap to `.presenting`, 11 to 13 ms of Dock and button work).

### The hypotheses

| Hypothesis | Verdict | Evidence |
|---|---|---|
| Opening is a multi-hop cascade of root-wide re-renders | **Confirmed, minor** | 3 `ContentView.body` and 3 `AssistantPanel.body` per open; about 20 ms tap to `.presenting`; 11 to 13 ms in the Dock and the button |
| `.sheet` rebuilds the whole panel on every open | **Confirmed, the main cost** | Every block and run section is built on each of six opens; 605 ms per open for one card |
| `ChatThread` and `BrowserAgentRunsView` are `VStack`s, so cost is O(runs) | **Confirmed** | Hosted open 119, 247, 637 ms for 5, 20, 60 runs; lazy summary 5 blocks against 41 |
| `PhoneAIButton` has no pressed state | **Confirmed by reading; its felt cost unmeasured** | No `Button`, no pressed style; handler 4 to 23 ms after lift |
| `CitedText` is one `Text` per Chinese character | **Confirmed** | `tokens` breaks after every wide character; 629 against 365 ms |
| `DCResultCard` is a plain `VStack` | **Confirmed** | `ConversationViews.swift:275`: its content is a `VStack`; all 41 blocks of the card are built on each open |
| `MarkdownInline.attributed`, `ForumSourcesCache`, `timelineCache` are recomputed on every open | **Rejected as a cost** | `matchingPageScripts`, `timeline`, `forumSources`, `parsed`, `strippedSummary` each under 1 ms per open; `MarkdownInline.attributed` 1.8 ms |
| `savedScriptEntries`' JSON is parsed again on every open | **Unmeasured** | No probe on it, and the fixtures have no saved scripts |
| Cold start reads `state.json` and every tab's conversation on the main thread | **Confirmed by reading; cost measured on generated state** | `AppModel.swift:713`, `BrowserTabs.init`; 7 ms per long thread, 72 ms per heavy conversation |
| Large text is kept in memory and in `state.json`; SQLite would help | **Confirmed in size; SQLite not needed yet** | 3.1 MB per long thread; see decision 5 |
| A very long exported text overwhelms the system | **Confirmed for the receiving app (Messages); not seen in the app's own share sheet or the Files picker; Export .txt's blank screen not reproduced** | Symptom 2 |
| TestFlight is much faster than the Debug numbers | **Rejected for the hosted panel; the whole-app open was not run unoptimized** | Hosted numbers within 0 to 25 % of Debug |

## 3. Decisions

1. **Long text leaves the app as a file.** Over a size limit (**20,000 characters**, set by probing Messages and Quick Note on iPhone 13 in task 1) Share and Export hand over `wukongmind-<slug>.txt`, written off the main thread, with its name and size in the share sheet. Under the limit Share stays plain text, so a short summary still lands as a message body. Copy keeps the pasteboard string, built off the main thread. One busy state on the menu's button while a large text is written.
2. **The button answers the finger.** A pressed look and the haptic at touch down; the long press for voice stays.
3. **Open cost follows what is visible.** The card's blocks and the runs are lazy, as the top summary already is. Measured gap: 141 against 365 ms for summaries of similar length. The target is one for every content: first frame within 200 ms of lift.
4. **A cited paragraph is a few views, not hundreds.** Runs of words between chips become one `Text`; Chinese stops being per character. Chips keep their size, spacing and 44 pt targets.
5. **A thread's text is not app state.** `source` and `rawPages` move to one file per topic, read when a summary, chat or export needs them, the way tab conversations already are (`TabStateStore`). No SQLite now: nothing queries across threads, and files are the house pattern. Gated on a readout of real sizes first.
6. **Not chosen:**
   - Keeping the panel alive between opens or warming it up: `.sheet` owns its content, so this means a UIKit-hosted sheet under `PresentationRouter`, which hosts every root presentation. Large and risky; laziness removes the cost without it.
   - A two-stage mount (shell first, content next frame): held back as a gate after decision 3, since a lazy transcript is already that.
   - Collapsing the open into one hop: about 20 ms; not worth touching the drawer's state machine.
   - Trimming the export (dropping posts by default): changes what people get.

**DX and AX.** One command gives tap-to-frame for a touch on any control (`perfTimeline`), so "did this get slower to open?" has a number on the simulator and the phone. The share path gets a test that hands the text to a real target. Each task below names the test that proves it.

## 4. Follow-up tasks

Sizes count changed lines, tests included. Phone numbers are the iPhone 13 with the optimized-Debug build of DEVELOPMENT.md, "Performance measurements". Rules as on the first page: no visible change unless the brief says so; `scripts/remote-test.sh` for simulators, `scripts/device-check.sh` for the phone.

### 1. Share and Export hand over a file
- **Why:** cause 1; the blank screen.
- **Scope:** `SummaryPanel.swift` (`ExportShareAnchor`, `ExportActivityItem`, the menu's three actions, `fileExporter`). Build the text off the main thread. Over the limit: write the file to a temporary folder, share its URL, and export with `fileMover`; under it: today's string. A busy state on the More button while writing. Remove the temporary file when the sheet closes. Tests: text and file bytes equal today's text for every option combination; the limit's two sides.
- **Size:** about 250. **Depends on:** nothing. Not at the same time as another `SummaryPanel.swift` task.
- **Done when:** on the phone, `testOpenShareExportLongThread` with `TEST_RUNNER_DC_PERF_SHARE_TARGET=Messages` shows the message with a .txt attachment within 3 s (from blank at 15 s); the short thread still opens with the text in the body; no main-thread pass over 100 ms after either tap (from 290 to 352 ms); the share sheet's header names the file.
- **Result (WUKO-158, iPhone 13, optimized Debug):**
  - **Size-limit probe (plain-text handoff before the change):**
    - ~7,100 chars (20 comments): Messages opens immediately with text in the body.
    - ~53,300 chars (145 comments): Messages is still blank at 3 s and opens by 6 s with the compose sheet overflowed; Add to New Quick Note opens by 6 s.
    - ~102,300 chars (285 comments): Messages is blank through 6 s and opens by 10 s (overflowed); Add to New Quick Note opens by 6 s.
    - ~202,000 and ~504,000 chars (570 and 1,430 comments): Messages stays blank through 10 s.
    - Set `TopicExportFile.inlineCharacterLimit = 20_000` characters so short threads and summary-only exports stay inline while long threads hand over `wukongmind-<slug>.txt`.
  - **Before vs after (`fixture-6000`, 2,113,610 chars, and `fixture-20`, 7,111 chars):**
    - Share › Messages (`fixture-6000`): blank at 15 s before → `New Message` with `wukongmind-….txt` (`Text Document · 2.2 MB`) attachment within 3 s after.
    - Share sheet header (`fixture-6000`): app icon only before → document preview, filename, and `Text Document · 2.2 MB` after.
    - Share › Messages (`fixture-20`): still opens with the plain text in the message body within 3 s.
    - Main-thread work: `TopicExportPayload.text` dropped from 63 ms on the main thread to **0 ms** (`Task.detached`). Export .txt (`fileMover`) max main-thread pass dropped from 138 ms to **63 ms** (tap pass 49 ms; Files picker opens with `Save as wukongmind-…`). Share tap pass dropped from 280 ms to **42 to 44 ms**; UIKit's own `UIActivityViewController` init/presentation pass on the main thread remains 157 ms on the short thread and 253 to 422 ms on the 2.2 MB file (cannot run off the main thread).

### 2. The AI button answers the finger
- **Why:** cause 4.
- **Scope:** `PhoneBrowserBar.swift` (`PhoneAIButton`): a `Button` with a pressed style (the ring dims and shrinks slightly) and `DCHaptics.tap()` at touch down; the 0.45 s long press for voice as a simultaneous gesture; accessibility traits, value and action unchanged. The haptic leaves `ContentView.openAssistant`.
- **Size:** about 90. **Depends on:** nothing.
- **Done when:** a UI test screenshot shows the pressed ring during a 0.3 s press; the long press still starts voice and a tap still opens (`DrawerUITests`, the voice button tests); the timeline shows the haptic before the touch-up.
- **Measured (iPhone 13, optimized Debug):** before, `m:haptic.done=327 ms` (after `m:up=300 ms`, inside `openAssistant`) with no pressed look; after, `m:down.delivered=14 ms`, `m:haptic.done=15 ms`, `f:haptic.done=29 ms` (`m:up=300 ms`, `m:tap.handler=330 ms`), and `testAIButtonPressedStateAndTimeline` + `testVoiceDockHidesBarLocksProgressExpandedAndRestoresOnClose` pass on the phone.

### 3. The transcript and the summary card are lazy (changes task 6 of the first page)
- **Status:** done in WUKO-159 (building on WUKO-152).
- **Why:** causes 2 and 5.
- **Scope:** as task 6 there (runs in a `LazyVStack`, scroll to the last run's id), with one change: the newest run stays eager **only while it streams**; once finished, its card's blocks are lazy too. Today's usual case is one finished run holding a 41-block card, which task 6 as written would leave eager.
- **Size:** about 350. **Depends on:** task 5 of the first page (WUKO-150).
- **Done when:** on the phone, the summary-card fixture's first frame is within 200 ms of lift (from 365) and its main thread busy within 300 ms (from 605); `runs-60` opens hosted in at most 300 ms (from 637); the pass after the first frame is under 50 ms (from 169 to 203); scroll-to-bottom, the jump button and VoiceOver order as before.
- **Result (WUKO-159, 2026-11-19):** `TimelineCache.split` (`AgentPanel.swift`) keeps the newest run eager only while `isRunning && runs.last?.state.isRunning == true`; once finished, all runs live in `EarlierConversationItemsView`'s `LazyVStack` (preserving `latestRunID` and expansion state). `DCResultCard` (`ConversationViews.swift`) takes `isLazy` and renders its content in a `LazyVStack` when true, passed as `!run.state.isRunning` from `AgentRunSectionView` / `CapabilityThreadSummaryCard`. On the iPhone 13 (optimized-Debug, `4f0bfa7` before vs. after):
  - `fixture-20` summary-card open (medians of 6 opens): blocks built **41 → 8**; `.shown` **230 → 128 ms**; first frame from lift **361.5 ms** (354–367; 365 original) **→ 167.0 ms** (153–175; target ≤ 200); main thread busy in first 1.3 s **612.0 ms** (605 original) **→ 159.5 ms** (target ≤ 300); longest pass after first frame **178.0 ms** (143–203; 169–203 original) **→ 4.0 ms** (0–8, none ≥ 8 ms on 3 of 6 opens; target < 50).
  - Hosted `DrawerPerformanceTests`: `runs-60` open **82.6 ms** (3 sections / 19 blocks; 637 original) **→ 78.2 ms** (2 sections / 14 blocks; target ≤ 300); `all-6000` open **101.9 ms** (276 original) **→ 85.4 ms** (2 sections / 14 blocks).
  - Guarded by `DrawerRenderCountTests.testFinishedSummaryCardOpensLazilyAndStreamingRunStaysEager`, `TranscriptFollowTests`, and `DrawerUITests` (`testJumpToBottomDuringDeceleration`, `testScrollToBottomButtonFloatsOverTheConversation`, `testSummarizeShowsOneSummaryAndNewConversationClearsIt`, `testRealKeyboardKeepsChatVStackPinnedAtBottom`).

### 4. Cheaper cited text (task 7 of the first page, gate passed)
- **Why:** cause 3. The gate that task set (is cited text the cost?) is answered here for opening: 48 % of an open is text drawing and layers, and Chinese is 1.7 times English at half the length.
- **Scope:** as task 7 there, plus: a wide character no longer ends a token by itself; a run of text between two chips is one `Text` that wraps. Add the Chinese summary to `DrawerPerformanceTests` fixtures.
- **Size:** about 300. **Depends on:** nothing; not at the same time as another `MarkdownView.swift` change.
- **Done when:** the Chinese card's first frame is within 20 % of the English card's (from 1.7 times); `summary-30` scroll step median at most 20 ms (from 56); citation taps land as before (`WordPressUITests`), with a before and after picture of a cited paragraph in both languages.
- **Result (WUKO-157, 2026-11-19):** `CitedText` (`MarkdownView.swift`) now caches tokenization and plain VoiceOver text in `CitedTextCache` (`NSCache`, 512 entries), stops splitting on wide CJK characters or whitespace so each contiguous styled run between chips is one wrapping `Text`, and caches wrapped widths plus TextKit 2 last-line widths inside `CitationFlowLayout` so following chips continue inline on the last line of wrapped runs while preserving chip size, 44 pt hit areas, punctuation gluing, and `.firstTextBaseline` alignment for list markers. Added `summary-30-zh` to `DrawerPerformanceTests`. Measured before and after on the iPhone 13 (optimized Debug):
  - Whole-app drawer open (`LongThreadDrawerPerfUITests`, 6 opens, from finger lift): English card (`fixture-20`) first frame **359.5 → 200.5 ms** (range 199–216; busy **614.5 → 219.0 ms**); Chinese card (`fixture-20-zh`) first frame **631.0 → 216.0 ms** (range 202–223; busy **888.0 → 228.5 ms**). Chinese/English ratio **1.76× → 1.08×** (within 20 %).
  - Hosted panel (`DrawerPerformanceTests`): `summary-30` scroll step median **55.9 → 17.8 ms** (steps > 16.7 ms: 40/40 → 29/40; open **91.6 → 74.4 ms**); `summary-30-zh` scroll step median **121.9 → 19.2 ms** (steps > 16.7 ms: 40/40 → 33/40; open **127.1 → 68.1 ms**); `summary-60` scroll step median **60.4 → 17.4 ms**; `all-6000` scroll step median **79.3 → 20.8 ms**.
  - Verified unchanged: `CoreTests` (including pill geometry, inline chip placement after multi-line wrapped runs, AX5 word spacing, streaming/in-place growth, and tokenization/cache tests), `DrawerRenderCountTests`, `IPadLayoutTests` (iPad simulator), and all 7 `WordPressUITests` citation-tap tests on the Mac mini.

### 5. Text selection on demand
- **Why:** cause 6. Gated: only if task 3 leaves more than 20 ms of it per open.
- **Scope:** `AgentPanel.swift` (`:444` to `:781`), `MarkdownView.swift:592`, `ConversationViews.swift:506`: `.textSelection(.enabled)` only on blocks on screen, or switched on by a long press.
- **Size:** about 80. **Depends on:** 3.
- **Done when:** no `UITextInteractionAssistant` frame in a trace of five opens; selecting and copying a paragraph works as before.
- **Gate result (WUKO-162, 2026-11-19, iPhone 13, optimized Debug):** **Not triggered (≤ 20 ms/open).** Time Profiler over 5 opens of the summary-card fixture (`testOpenShareExportShortThread`, `fixture-20`, 2,606-char summary card, lazy transcript & card): `UITextInteractionAssistant` **4.4 ms/open** (22.0 ms across 5 opens); `UIContextMenuInteraction`/`ContextMenu` **1.4 ms/open** (7.0 ms across 5 opens); all text-selection and context-menu interaction frames combined (`UITextInteractionAssistant`, `UITextSelectionDisplayInteraction`, `UIContextMenuInteraction`, SwiftUI `TextSelectionRepresentable` / `TextSelectionConfigurationForText`) **13.2 ms/open** (66.0 ms across 5 opens), down from 57 ms/open before task 3.

### 6. Thread text out of `state.json`
- **Why:** cause 7. **Gate first:** a line in developer mode with `state.json`'s size, the number of sessions with text, and the largest; the owner reads it out. Go ahead above 20 MB.
- **Scope:** `Persistence.swift`, `Models.swift`, `AppModel.swift`: `TopicSession.source` and `rawPages` in `Threads/<topic key>.json`, loaded on demand and dropped from memory when the topic is not open; `state.json` keeps counts and dates. A one-time move from the old file, which still decodes. Retention removes the files it removes today from the snapshot. Tests: old file loads and moves; export, chat and "Check for new replies" read the text back; sync payloads unchanged.
- **Size:** about 450. If it runs over, split the move from the on-demand loading. **Depends on:** nothing.
- **Done when:** `testStateLoadScalesWithSavedThreads` loads 20 long threads in under 15 ms (from 136) and saves in under 30 ms (from 269); memory after launch with 20 long threads drops by their text; every reader of `source` passes its tests unchanged.
- **Gate result (WUKO-162, 2026-11-19):** Added read-only `StateStorageStats` (`Persistence.swift`, `AppModel.measureStateStorageStats()`, `StateStorageReadoutView` in `Settings › Agent › Developer` behind `agentDeveloperMode`) showing `state.json` size on disk, count of sessions holding thread text (`source` or `rawPages`), and largest session's thread text size, computed off the main thread (`Task.detached(priority: .utility)`). Guarded by `CoreTests.testStateStorageStatsCountsSessionsWithTextAndReadsFileSize` and `SettingsNavigationUITests.testThisPageAndSettingsDeveloperShowLiveStateDigest`. Waiting on the owner's readout (> 20 MB to proceed).

### 7. Acceptance (extends task 10 of the first page)
- **Status:** done in WUKO-164 (2026-11-19, `68d074d`, iPhone 13, optimized Debug, measurement only).
- **Scope:** the three open cases, Share › Messages on the real thread (and 6,000-post fixture), and task 10's typing run, on the phone; update the tables here and on the first page.
- **Done when:** first frame within 200 ms of lift on every case; no blank screen; task 10's own targets.
- **Verdict per target:**

| Target | Before | After (`68d074d`, iPhone 13 opt-Debug) | Verdict |
|---|---|---|---|
| Drawer open: real thread, saved summary at top (≤ 200 ms) | 141 to 151 ms | **145.5 ms** (141 to 150) | **Met** (−54.5 ms) |
| Drawer open: English summary card, 20 posts (≤ 200 ms; busy ≤ 300; post-frame pass < 50) | 365 ms (busy 605; pass 169–203) | **144.0 ms** (WUKO-166, 140 to 156; WUKO-164 was 159.5, busy 144.5, pass 8.0) | **Met** (−56.0 ms) |
| Drawer open: English summary card, 6,000 posts (≤ 200 ms; busy ≤ 300; post-frame pass < 50) | 376 to 378 ms (busy 624–638; pass 161–209) | **166.0 ms** (153 to 168; busy 239.5; pass 22.0) | **Met** (−34.0 ms) |
| Drawer open: Chinese summary card, 20 posts (≤ 200 ms; within 20 % of English) | 629 ms (1.72× English) | **160.5 ms** (154 to 165; **1.01×** English) | **Met** (−39.5 ms) |
| Touch-down haptic before finger lift (`m:haptic.done < m:up`) | 327 ms (after lift) | **8 to 19 ms** (lift at 58 ms) | **Met** |
| Share › Messages: real thread, 6,185 posts (no blank screen; `.txt` attachment ≤ 3 s) | blank for 15 s | **`New Message` with `1.9 MB` `.txt` attachment within 3 s**; share sheet shows filename and size | **Met** |
| Share › Messages: 6,000-post fixture (no blank screen; `.txt` attachment ≤ 3 s) | blank for 15 s | **`New Message` with `2.2 MB` `.txt` attachment within 3 s**; share sheet shows filename and size | **Met** |
| Hosted `runs-60` open (≤ 300 ms) / `all-6000` open (≤ 300 ms) | 637 / 276 ms | **60.7 / 66.6 ms** | **Met** |
| Hosted `runs-60` one more run `new_run_ms` (≤ 150 ms) | 134 ms (2,144 Debug) | **51.1 ms** (`send_run_ms`: 307.6 ms) | **Met** |
| Hosted `summary-30` scroll step median (≤ 20 ms) / `summary-30-zh` | 56 / 121.9 ms | **17.7 / 18.0 ms** | **Met** |
| Hosted `summary-30` scroll steps > 16.7 ms (first page task 7: ≤ 10 of 40) | 40 of 40 | **26 of 40** (even `baseline` is 7 of 10 at 19.1 ms) | **Not met** (+16 steps) |
| Hosted keystroke median (first page task 2: ≤ 12 ms on every fixture) | 12.7 to 26.2 ms (42–412 original) | **13.1 to 15.1 ms** (composer-only 5.8 ms; all < 16.7 ms frame budget) | **Not met** (+1.1 to +3.1 ms) |
| Hosted unrelated `AppModel` publish (≤ 5 ms on every fixture) | 47 to 413 ms | **1.6 to 2.2 ms** | **Met** |
| Task 10: real-thread typing within 20 % of 20-comment control (`≤ 203.5 ms/key`) | 1,985 vs 320 ms (6.2×); WUKO-164 (3 runs): 312.0 vs 169.6 (1.84×) | **191.8 ms/key** vs **170.6 ms/key** (**1.12×**, +12.4 %, 1 run; `n:publish.ForumBrowserModel=14`, `n:AssistantPanel.body=0`; WUKO-166) | **Met** (−11.7 ms/key) |
| Task 10: no run loop pass > 250 ms while typing | 97 on real thread, 31 on `fixture-6000` | **0** on all three cases (all 3 real-thread runs) | **Met** |
| Task 10: Instruments trace reports no hang (> 250 ms) | 82 (18 Hangs + 64 Microhangs) | **0 hangs, 0 microhangs** (41.0 s Time Profiler trace) | **Met** |

**Order:** 1 and 2 first (the two things the owner sees on every use, both small and independent), then 3, then 4. Tasks 5 and 6 wait for their gates.

**The first page's remaining tasks:** 5 (WUKO-150) unchanged. 6 (WUKO-152): **change** as task 3 above before it starts. 7: **keep**, its gate is passed and its scope grows by the Chinese rule. 8 and 9 are done. 10: **keep**, extended by task 7 above.

## 5. Not proven here

- **The owner's 1 to 2 s, end to end.** The longest tap to first frame measured is 0.63 s, then the system's animation. Their conversation's size, their summary's language and their press are not known; a Chinese summary of normal length or a long conversation would reach it, by the scaling above.
- **A true Release build.** Optimized Debug stands in for it. The whole-app open was not also run unoptimized, so its Debug-to-optimized ratio is unknown; only the hosted panel has both.
- **The sheet animation's own length** and the pressed state's felt effect: read from the code, not timed.
- **Whether this is the owner's blank screen.** They did not say which step was blank; the reproduction is Share › Messages.
- **Whether Messages ever recovers** after 15 s, and other targets (Notes, Mail, WeChat, AirDrop): only Messages was tried.
- **Whether a blank leaves the share sheet stuck.** Twice a short-thread run that came right after a blank long-thread run showed nothing after the tap on Messages; run by itself, and before any blank, the short thread opened the message. Not pursued.
- **Export .txt's blank screen.** Not reproduced: the picker opened in every run. Save was never pressed, and the picker's slow first paint (one run of three) was not explained.
- **The owner's real `state.json`** size and launch time; memory pressure on a phone with many tabs.
- **How much of the open is the cascade.** Bounded (about 20 ms plus 11 to 13 ms) but not isolated.
- **The SwiftUI and Animation Hitches instruments:** not recorded (the SwiftUI tables come back empty with all-process recording).
- **iPad:** phone drawer only.

## 6. Proposed follow-ups (unmet targets)

Ranked by main-thread CPU in the 41.0 s Time Profiler trace of `testRealLongThread` (`6,557 ms` WukongMind main-thread CPU; `0` hangs; `com.apple.WebKit.WebContent` also used `14,120 ms` on the live `doctorofcredit.com` page behind the drawer):

1. **Eliminate per-keystroke keyboard hide/show churn and `AssistantPanel.body` re-evaluations on real pages — `2,661 ms` (40.6 % of WukongMind main-thread CPU).** — **Done in WUKO-166.**
   - *Evidence:* On `real-page` (all three WUKO-164 runs), `UIKit` toggles hardware↔software keyboard mode (`setInHardwareKeyboardMode`, `detachHardwareKeyboard`, `setKeyWindowSceneInputViews`) on every XCUITest `typeText` character, posting `keyboardWillHide` + `keyboardWillShow` twice per keystroke (`n:publish.ForumBrowserModel=60`, `n:AssistantPanel.body=60` vs. `2` on `fixture-20` and `fixture-6000`). That accounted for the entire `+142 ms/key` gap between `real-page` (`312.0 ms/key`) and `fixture-20` (`169.6 ms/key`); `ChatThread.body`, `BrowserAgentRunsView.runSection`, `DrawerPageFacts` and `TopicExportPayload.text` are all `0`.
   - *Key-tap check (WUKO-166, iPhone 13 opt-Debug, 1 run before code change):* Tapping software keyboard keys directly (`TEST_RUNNER_DC_PERF_KEY_TAPS=1`, `app.keyboards.keys[...]`) on the same real 6,185-post page produced **`n:publish.ForumBrowserModel=0`** and **`n:AssistantPanel.body=0`** (`235.7 ms/key` including per-tap keyboard AX lookups; `over100=0`, `over250=0`), confirming the per-keystroke hide/show churn is an XCUITest `typeText` hardware-keyboard-toggle artifact rather than real touch typing.
   - *Result (WUKO-166, iPhone 13 opt-Debug, 1 run):* Moved drawer keyboard/focus state into `DrawerKeyboardState` (`SummaryPanel.swift`, observed only by `HeaderSectionObserver` and `FooterSectionObserver`, never by `AssistantPanel` or the transcript) and coalesced transient keyboard-hide transitions with a bounded 2 s timeout while the drawer composer owns first responder in both `DrawerKeyboardState` and `ForumBrowserModel` (flushing immediately on blur/disappear, and still settling to hidden if the keyboard genuinely hides while focused, e.g. hardware keyboard attach or iPad shortcut bar). On `testRealLongThread` (`typeText`), `real-page` dropped from **`312.0 ms/key` → `191.8 ms/key`** against **`170.6 ms/key`** on `fixture-20` (**`1.12×`**, +12.4 %, within the `≤ 203.5 ms/key` target), with **`n:publish.ForumBrowserModel=14`** (from 60), **`n:AssistantPanel.body=0`** (from 60), and `over250=0`. Guarded by `DrawerRenderCountTests.testKeyboardChurnDoesNotReevaluateAssistantPanelOrPublishBrowser` and `DrawerUITests.testRealKeyboardKeepsChatVStackPinnedAtBottom` (passed on both Mac mini simulator and iPhone 13).
2. **Audit SwiftUI accessibility hierarchy cost under XCUITest / VoiceOver — `2,545 ms` (38.8 %; only `3 ms` in `WKWebView`).**
   - *Evidence:* Task 3's `accessibilityHidden` on the covered `WKWebView` succeeded (`WKWebView` AX walking is down to `3 ms`), leaving XCUITest's `_accessibilityUserTestingSnapshotWithOptions` walking the SwiftUI drawer itself as the second largest CPU consumer. This is mostly UI-test harness floor (`fixture-20` is `169.6 ms/key`), so it does not affect normal typing unless VoiceOver is active, but flattening redundant accessibility containers in `AssistantPanel` / `DrawerSummary` would cut both VoiceOver and UI-test snapshot time.
3. **Trim residual SwiftUI/AttributeGraph work per keystroke and per scroll step — `918 ms` (14.0 %, including `34 ms` in `DockLayer` / `AppleIntelligenceClient.currentStatus`).** — **Apple Intelligence caching done in WUKO-166** (composer/scroll layout deferred).
   - *Evidence:* Hosted keystroke median is `13.1–15.1 ms` (target ≤ 12 ms; composer-only is `5.8 ms`) and hosted `summary-30` scroll has `26/40` steps over `16.7 ms` (target ≤ 10/40; median `17.7 ms` meets ≤ 20 ms, and even `baseline` is `19.1 ms`, `7/10` over `16.7 ms` on 300 pt programmatic jumps). Both are already near or under the `16.7 ms` frame budget and flat across thread/run sizes, so this is lower priority than #1.
   - *Result (WUKO-166, iPhone 13 opt-Debug):* Cached `AppleIntelligenceClient.currentStatus()` behind an `OSAllocatedUnfairLock` in `AppleIntelligenceClient` and stored `@Published private(set) var appleIntelligenceStatus` on `AppModel`, initialized once at launch and refreshed off the render path on `handleScenePhase(.active)`, `settingsDidChange`, `NSLocale.currentLocaleDidChangeNotification`, `AppleIntelligenceStatusView.onAppear`, `selectModel` (when Apple Intelligence is chosen), `showAIView()` (when status is `.modelNotReady`), and `requireBackend()`. In a 60 s Time Profiler trace over six opens of `fixture-20` (`6,673` WukongMind samples, `6,323` main thread, symbolicated with `atos`): **`0` samples** in `AppleIntelligenceClient.currentStatus`, `FoundationModelsBridge.probe`, or `FoundationModels`/`SystemLanguageModel` (down from `12 ms/open`), `AppModel.drawerHintInput.getter` dropped from `13 ms/open` to `2` samples total (~`0.3 ms/open`), and `fixture-20` first-frame median improved from `159.5 ms` to **`144.0 ms`** (`140–156 ms`). Guarded by `DrawerRenderCountTests.testOpeningDrawerAndEvaluatingHintInputDoesNotProbeAppleIntelligence` and `AppleIntelligenceTests.testAppModelCachesAppleIntelligenceStatusAndRefreshesOnActivationAndSettingsChange`.
   - *Remaining follow-up:* Profile `AssistantComposer` + hosted `ScrollView` layout if sub-12 ms keystrokes or ≤ 10/40 300 pt scroll steps are required.
4. *(Harness-only, not a product follow-up)* **`PerfProbeState` 0.5 s polling timer — `430 ms` (6.6 %).** DEBUG-only measurement overhead; does not ship in Release.
