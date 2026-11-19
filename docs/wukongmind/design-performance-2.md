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

Medians of six opens, milliseconds from finger lift (range of the first frame in brackets).

| Case | Summary blocks built | Tap handler | `.presenting` | `.shown` | First frame | Main thread busy, first 1.3 s | Longest pass after the first frame |
|---|---|---|---|---|---|---|---|
| Real thread, saved summary at the top (lazy) | 5 | 8 to 18 | 22 to 32 | 99 to 109 | **141 to 151** (135 to 160) | 172 | 20 |
| 20 comments, summary card, English, 2,606 characters | 41 | 18 | 37 | 230 | **365** (349 to 373) | 605 | 169 to 203 |
| 6,000 comments, the same summary card | 41 | 18 to 21 | 35 to 39 | 234 | **376 to 378** (364 to 393) | 624 to 638 | 161 to 209 |
| 20 comments, summary card, Chinese, 1,310 characters | 41 | 11 | 33 | 349 | **629** (623 to 638) | 890 | 99 |
| First open after launch, nothing summarized | 0 to 4 | 10 to 22 | 28 to 39 | 113 to 215 | 141 to 275 | 131 to 285 | none |

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

**Content is what scales** (hosted panel, `DrawerPerformanceTests`, same phone, optimized build; in brackets the first page's Debug number for the same fixture, only where it has one from after its tasks 1 to 3):

| Fixture | Open | Keystroke median | Scroll step median | One more run |
|---|---|---|---|---|
| Baseline | 74 ms | 12.7 ms (13.6) | 28 ms | |
| Posts: 6,000 | 76 ms (88) | 14.4 ms (14.6) | 34 ms | |
| Summary: 30 sections (lazy, at the top) | 89 ms | 15.3 ms | 56 ms (58) | |
| Conversation: 5 runs | 119 ms | 17.2 ms | 20 ms | 122 ms |
| Conversation: 20 runs | 247 ms | 20.9 ms (21.1) | 14 ms | 121 ms |
| Conversation: 60 runs | **637 ms** (626) | 26.2 ms (27.9) | 16 ms | 134 ms (177) |
| Everything: 6,000 posts, 30 sections, 20 runs | 276 ms (298) | 23.5 ms (23.2) | 76 ms | 146 ms (156) |

The hosted open has no sheet and no cited summary card; in the whole app one cited card of 41 blocks costs 605 ms where five plain runs of 29 blocks cost 119 ms hosted.

### Symptom 2: Share and Export .txt

Runs on the phone: three thread sizes at the large drawer height (each twice or more) and the real thread again at the medium height. Both fixtures also ran on the simulator, where both sheets opened.

| | 20 comments (7,111 characters) | 6,000 comments (2,113,610) | Real thread (1,828,529) |
|---|---|---|---|
| Building the export text (main thread) | 1 to 2 ms | 63 to 76 ms | 71 to 79 ms |
| Share: main-thread passes after the tap | 179 to 248 ms, then 31 | 337, then 35 to 62 | 290 to 325, then 229 to 367 |
| The app's share sheet | shown | shown | shown (large and medium) |
| **Share › Messages** | **the message opens with the text** (2 runs: English and Chinese summary) | **blank sheet for the 15 s watched** (1 run) | **blank sheet for the 15 s watched** (1 run) |
| Export .txt: main-thread passes after the tap | 59, then 72 | 138, then 83 | 111, then 185 |
| The Files picker | shown | shown | shown; its file list was still empty 3.9 s after the tap in one run of three |

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

1. **Long text leaves the app as a file.** Over a size limit (100,000 characters as a starting guess; task 1 sets it by trying sizes against Messages and Notes) Share and Export hand over `wukongmind-<slug>.txt`, written off the main thread, with its name and size in the share sheet. Under the limit Share stays plain text, so a short summary still lands as a message body. Copy keeps the pasteboard string, built off the main thread. One busy state on the menu's button while a large text is written.
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

### 2. The AI button answers the finger
- **Why:** cause 4.
- **Scope:** `PhoneBrowserBar.swift` (`PhoneAIButton`): a `Button` with a pressed style (the ring dims and shrinks slightly) and `DCHaptics.tap()` at touch down; the 0.45 s long press for voice as a simultaneous gesture; accessibility traits, value and action unchanged. The haptic leaves `ContentView.openAssistant`.
- **Size:** about 90. **Depends on:** nothing.
- **Done when:** a UI test screenshot shows the pressed ring during a 0.3 s press; the long press still starts voice and a tap still opens (`DrawerUITests`, the voice button tests); the timeline shows the haptic before the touch-up.

### 3. The transcript and the summary card are lazy (changes task 6 of the first page)
- **Why:** causes 2 and 5.
- **Scope:** as task 6 there (runs in a `LazyVStack`, scroll to the last run's id), with one change: the newest run stays eager **only while it streams**; once finished, its card's blocks are lazy too. Today's usual case is one finished run holding a 41-block card, which task 6 as written would leave eager.
- **Size:** about 350. **Depends on:** task 5 of the first page (WUKO-150).
- **Done when:** on the phone, the summary-card fixture's first frame is within 200 ms of lift (from 365) and its main thread busy within 300 ms (from 605); `runs-60` opens hosted in at most 300 ms (from 637); the pass after the first frame is under 50 ms (from 169 to 203); scroll-to-bottom, the jump button and VoiceOver order as before.

### 4. Cheaper cited text (task 7 of the first page, gate passed)
- **Why:** cause 3. The gate that task set (is cited text the cost?) is answered here for opening: 48 % of an open is text drawing and layers, and Chinese is 1.7 times English at half the length.
- **Scope:** as task 7 there, plus: a wide character no longer ends a token by itself; a run of text between two chips is one `Text` that wraps. Add the Chinese summary to `DrawerPerformanceTests` fixtures.
- **Size:** about 300. **Depends on:** nothing; not at the same time as another `MarkdownView.swift` change.
- **Done when:** the Chinese card's first frame is within 20 % of the English card's (from 1.7 times); `summary-30` scroll step median at most 20 ms (from 56); citation taps land as before (`WordPressUITests`), with a before and after picture of a cited paragraph in both languages.
- **Result (WUKO-157, 2026-11-19):** `CitedText` (`MarkdownView.swift`) now caches tokenization and plain VoiceOver text in `CitedTextCache` (`NSCache`, 512 entries), stops splitting on wide CJK characters or whitespace so each contiguous styled run between chips is one wrapping `Text`, and caches wrapped widths inside `CitationFlowLayout` while preserving chip size, 44 pt hit areas, punctuation gluing, and `.firstTextBaseline` alignment for list markers. Added `summary-30-zh` to `DrawerPerformanceTests`. Measured before and after in one session on the iPhone 13 (optimized Debug):
  - Whole-app drawer open (`LongThreadDrawerPerfUITests`, 6 opens, from finger lift): English card (`fixture-20`) first frame **359.5 → 210.0 ms** (range 202–214; busy **614.5 → 220.0 ms**); Chinese card (`fixture-20-zh`) first frame **631.0 → 207.5 ms** (range 202–217; busy **888.0 → 232.5 ms**). Chinese/English ratio **1.76× → 0.99×** (within 20 %).
  - Hosted panel (`DrawerPerformanceTests`): `summary-30` scroll step median **55.9 → 17.5 ms** (steps > 16.7 ms: 40/40 → 23/40; open **91.6 → 63.5 ms**); `summary-30-zh` scroll step median **121.9 → 17.1 ms** (steps > 16.7 ms: 40/40 → 26/40; open **127.1 → 66.3 ms**); `summary-60` scroll step median **60.4 → 16.8 ms**; `all-6000` scroll step median **79.3 → 17.4 ms**.
  - Verified unchanged: `CoreTests` (including pill geometry, AX5 word spacing, streaming/in-place growth, and new tokenization/cache tests), `DrawerRenderCountTests`, `IPadLayoutTests` (iPad simulator), and all 7 `WordPressUITests` citation-tap tests on the Mac mini.

### 5. Text selection on demand
- **Why:** cause 6. Gated: only if task 3 leaves more than 20 ms of it per open.
- **Scope:** `AgentPanel.swift` (`:444` to `:781`), `MarkdownView.swift:592`, `ConversationViews.swift:506`: `.textSelection(.enabled)` only on blocks on screen, or switched on by a long press.
- **Size:** about 80. **Depends on:** 3.
- **Done when:** no `UITextInteractionAssistant` frame in a trace of five opens; selecting and copying a paragraph works as before.

### 6. Thread text out of `state.json`
- **Why:** cause 7. **Gate first:** a line in developer mode with `state.json`'s size, the number of sessions with text, and the largest; the owner reads it out. Go ahead above 20 MB.
- **Scope:** `Persistence.swift`, `Models.swift`, `AppModel.swift`: `TopicSession.source` and `rawPages` in `Threads/<topic key>.json`, loaded on demand and dropped from memory when the topic is not open; `state.json` keeps counts and dates. A one-time move from the old file, which still decodes. Retention removes the files it removes today from the snapshot. Tests: old file loads and moves; export, chat and "Check for new replies" read the text back; sync payloads unchanged.
- **Size:** about 450. If it runs over, split the move from the on-demand loading. **Depends on:** nothing.
- **Done when:** `testStateLoadScalesWithSavedThreads` loads 20 long threads in under 15 ms (from 136) and saves in under 30 ms (from 269); memory after launch with 20 long threads drops by their text; every reader of `source` passes its tests unchanged.

### 7. Acceptance (extends task 10 of the first page)
- **Scope:** the three open cases, Share › Messages on the real thread, and task 10's typing run, on the phone; update the tables here.
- **Done when:** first frame within 200 ms of lift on every case; no blank screen; task 10's own targets.

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
