# Design: motion and the address bar (WUKO-174)

Evaluation of the motion and UX proposal of 2026-11-19 (another agent's interactive page, "只有环会动"), what WukongMind adopts from it, and the tasks. Nothing here is built. Code facts were read at `6d122e1` (1.5.4).

**Decisions recorded here**

- **Owner, 2026-11-19: adopt the Safari-style address bar.** Tapping the address bar shows Home over the current page (and Home is what a new tab shows), and Home's own search field goes. Reason, in the owner's words: the home page entry is buried too deep today. Section 3 designs it; it is no longer an open question.
- **Owner principles, 2026-11-19,** applied throughout: speed first (hot paths show before and after numbers); the smallest complete change, and delete what can go; design gaps go into a design doc, never a hack; code the way Apple would agree with, nothing hidden; verification is re-run by the agent, with the raw output in the proof.
- **The proposal's "已同意" (agreed) rows are treated as proposals.** Its table marks the five ring states, the launch assembly and "tighten = learned" as agreed. No trace of that agreement is in the repo: searched `docs/wukongmind/*.md`, `design/design-system/README.md`, `feedback.md`, `requirements.md` and `git log` for the ring states, breathing, ripple, tighten, assembly and launch animation. What the repo does record is the opposite decision (2026-11-12, [design-unified.md](design-unified.md) §6): the turning ring is the only continuous animation, and the onboarding dot stretch, staggered prompts, button bounce and Home tile zoom were removed.

## 1. Verdicts

Judged on four things. **UX:** does it tell the user something they can't already see? **AX:** does it survive Reduce Motion as a still picture, and is the state also in words for VoiceOver? **DX:** one ring component, states from one tested function. **Speed:** nothing new on the drawer-open, typing, scrolling or launch paths without numbers (iPhone 13, Release).

| # | Proposal item | Verdict | Reason |
|---|---|---|---|
| 1 | Agent ring: idle, thinking (three rings breathing), reading (ripple per tool call), running (spinner), done (gap closes, squeeze, check), stopped (cinnabar) | **Adapt** | Adopt one ring with states that come from real state: idle, working, needs you, done, failed, unavailable (section 2). **Reject thinking and reading as separate animations:** `BrowserAgentRunState` has no such split; the ToolRow already names the tool in words; three concentric rings do not fit inside a 14 to 16 pt ring; and with Reduce Motion the three "busy" states are the same still picture, so the meaning would be carried by motion alone. **Reject the 0.9× squeeze:** it is a bounce. **Stopped by the user** returns to idle (the user did it; the conversation says "Stopped"); cinnabar would read as an error |
| 2 | Cold-start logo assembly that hands its outer ring to the bar's Agent ring | **Reject** | Launch is a hot path: 350 ms to 1.1 s of animation before the app is usable, on every launch or the first, is a trade of speed for decoration. After App Store task 5 the first screen is the Terms page, so the assembly would play in front of a legal text. The launch screen stays plain paper, and the still logo stays on onboarding step 1. "This ring is the Agent" is taught by step 3, where the real ring works and finishes |
| 3 | "Tighten = learned": a 2.4× ring closes on the row for Learn on ask, script save, key verified | **Adapt** | The event is real and worth marking, but a second ring animation is a second vocabulary. Reuse the ring's own **done** transition (the gap closes, then the check) on the card's ring glyph, after the save succeeded. No large collapsing ring. Words stay: "Saved. Faster next time." |
| 4 | Gold outline on page elements the Agent changed, with an "edited" stamp and undo | **Defer** | The most useful idea for the product ("what did it change?"), but it is a feature, not motion: it injects into arbitrary pages (layout, CSP, removed elements can't be outlined), needs every Agent-written script to call a new API, and its stamp duplicates the Undo that script cards already have ([design-m4.md](design-m4.md), [page-feedback.md](page-feedback.md)). It needs its own design in page-feedback.md, starting from the elements `PageFeedbackReport` already matches. Not planned here |
| 5 | Voice: three rings follow the audio level | **Reject, and delete one loop** | The voice bar already draws a meter from the real levels (`VoiceLevels`, smoothed, 30 fps, paused with Reduce Motion). Redrawing it as rings changes the look, not the information. The one loop that follows nothing is the bar mic's `.symbolEffect(.pulse)`: delete it (mic.fill in gold-ink already says "on") |
| 6 | Seam transition for theme switch and onboarding pages | **Reject** | Decorative, 320 ms (over the 250 ms rule), full-screen mask. The app has no in-app theme switch (it follows the system), and the owner already removed onboarding's decorative motion |
| 7a | iPad: the panel pushes in, the top-bar ring is gold-wash and still while the panel shows, one ring speaks at a time | **Adopt (mostly exists)** | The split panel and the gold-wash ring exist (`SplitPanelToggle`). New: while the panel is visible the bar ring does not turn, because the panel's ToolRow already does. One fewer per-frame view |
| 7b | iPad: hover or keyboard focus reveals the three rings | **Adapt** | Revealing the logo tells nothing. Give the ring the system hover highlight and focus ring that other controls have (`DCIconButtonStyle` has none today). The proposal's ⌘J is taken (Next Result); the panel already has ⌥⌘0 |
| 7c | iPad: tab cards show a status ring | **Already built** | `BrowserTabsOverview` shows "Agent working" with the turning ring |
| 7d | iPad: hovering a citation outlines the paragraph; circle with Pencil to select | **Defer** | Both depend on item 4's page API. The proposal itself files the circle under "later" |
| 8 | Onboarding woven around the logo, three concentric rings as progress | **Reject the rings, keep the dots** | Dots are read faster than "which of three nested rings is drawn", and drawing rings is the dot stretch the owner removed, in a new shape. Onboarding still gains from item 1 for free: the key row and step 3 show the same ring states as everywhere else. No ripple "reading" when a site opens: nothing is reading, and the proposal's own rule is that what did not happen is not acted out |
| 9 | Address bar shows Home; Home's search field removed; input classified as address, search or question ("Ask the Agent") | **Adopt (owner decision)** | Section 3. Adapted: an opaque Home, no page blur; no ring that dims and lights (the editing bar has no ring; the first suggestion row says what Return does); no remote suggestions |
| 10 | Live rings in Home's Recent | **Defer** | `HomeRecentItem` holds saved items only, and the tab overview already shows which tab is working. Cheap after task 1 if the owner misses it |
| 11 | Today card: the sun icon becomes a state ring | **Reject** | The ring means the Agent, and the digest is not the Agent. The card has a progress row |
| 12 | Animated mascot | **Defer** | As the proposal says: the mascot needs redrawing first |

### The motion rule becomes

> **Motion shows a live signal or a cause, never decoration.** Continuous motion is allowed only where it displays something happening now: the turning ring (the Agent is working), the voice level meter (sound in or out), the composer's recording pulse (the microphone is on), and progress (the app's progress bar and the system's own activity spinner). The ring also has one one-shot motion: its gap closes into the check when work is done or saved. The functional transitions stay as they are (a suggestion into the input box, a result rising, the browser bar morph, Home appearing over the page, system sheets): each within 250 ms, no bounce. Every state is also a still picture and a word. With Reduce Motion, transitions fade and continuous motion stands still, with one exception: a progress bar with no known value keeps a slow opacity pulse, so a long job never looks frozen.

What changes against today's rule ("the turning ring is the only continuous animation"):

- **It becomes true.** Today's code has continuous motion the rule never named. Each gets a verdict, carried out in task 1:

  | Loop in the code today | Verdict |
  |---|---|
  | Voice level meter (`Dock.swift`, from `VoiceLevels`) | Named in the rule: it draws the real level |
  | `AssistantProgressBar` sweep and sheen; with Reduce Motion its indeterminate form pulses in opacity (`AssistantStates.swift` 351 to 356) | Named: a job in progress. The Reduce Motion pulse is kept on purpose and the rule says so |
  | System `ProgressView()` spinners (29 uses) | Named: the system's own progress control, left as it is |
  | Summary placeholder's opacity pulse (`PulseModifier`, a `phaseAnimator` in `SummaryPanel.swift`) | **Delete the pulse**, keep the still placeholder and its "Writing summary…" label; the progress bar beside it is the live signal |
  | Composer's recording pulse while dictating (`AskBox.swift`) | Named: the microphone is on, which the user must be able to see |
  | Bar mic `.symbolEffect(.pulse)` (`VoiceViews.swift`) | **Delete**: follows nothing; mic.fill in gold-ink says "on" |
  | Loading skeleton's opacity pulse (`AssistantLoadingState`) | **Delete the pulse**, keep the still skeleton and its "Loading page…" line |
  | `TypingIndicator` | **Delete the type**: nothing uses it (`rg` finds only its definition) |
- **It does not grow into "only the ring moves, and it has many moves"** as the proposal suggests. One continuous ring motion and one one-shot.
- "Still removed" in design-unified §6 stays removed.

## 2. The ring: one component, states from one function

- **One enum, one mapping.** `AgentRingState`: `idle`, `working`, `needsYou`, `done`, `failed`, `unavailable`. One pure function maps what the app already knows to it, and every ring uses it.

  | State | From (today's state) | Still picture | Motion | Word (accessibility value) |
  |---|---|---|---|---|
  | idle | no run, or a run the user stopped | open gold ring | none | none |
  | working | `runState.isRunning`, `activeResearch != nil` | gold arc on a hairline track | turns, 1.1 s (today's) | "Working" |
  | needsYou | the current tab's `AgentConfirmationGate.pending` is not empty (it is `@Observable`) | gold ring with a question mark inside (not a dot: the new-replies dot is already a gold dot on this button) | none | "Needs your answer" |
  | done | the current tab's last `BrowserAgentRun` is `.completed` and not yet seen (see "Seen" below) | closed gold ring with a check | once: the gap closes in 250 ms, then the check | "Answer ready" |
  | failed | the last run is `.failed` or `.stepLimitReached` and not yet seen | ring with the warning mark, `warning` colour | none | "Stopped with a problem" |
  | unavailable | today's `isAvailable` is false (no page to work on) | `ink-faint` ring | none | none (the button loses its button trait, as today) |

- **Where it shows.** The bar ring (`PhoneAIButton`) and the iPad panel toggle show all six. The collapsed pill's 16 pt ring, the folded "Step N" header and the ToolRow disc show `working` only, as today; the ToolRow keeps its own done, warning and error discs, which describe one tool call, not the Agent.
- **Seen: one new piece of state.** Nothing in a production build tracks whether a finished Agent run was seen:
  - `readyAnswer` looks for a `WorkRecord` of type `.agent`, and those are only created by the DEBUG sample seeding (`AppModel+Assistant.swift`, inside `#if DEBUG`); `router.answersSeenAt` is only set by `showAnswer` and a debug argument. So the "answer ready" ring never shows for a real run today.
  - The only code that notices a run ending with the panel closed is `completedBrowserAgentBounce`, and nothing reads it.
  - Task 2 therefore adds one value on `BrowserAgentSession`: `seenRunID`, the id of the last run the user has seen. It is set when that tab's panel is visible as the run ends, or is opened afterwards. `done` and `failed` are "last run ended and its id is not `seenRunID`". It is kept in memory only, and `restoreConversation` (every tab at launch, and reopening a closed tab) sets it to the last restored run's id, so a restored conversation never counts as unseen and nothing is announced for it.
  - This replaces the bounce counters and `observedAgentID` (deleted in task 1). Checked in task 2: `WorkRecord` entries of type `.agent` are only created by `#if DEBUG` sample seeding (`AppModel+Assistant.swift`), so `readyAnswer`, `activeResearch` and `answersSeenAt` are unused in Release runs, but `DockTests` and `IPadLayoutUITests.testThePanelToggleShowsTheResearchRing` still exercise them; task 2 keeps them as optional inputs to `AgentRingState.resolve` and deletes `ResearchRing`.
  - If the owner would rather not add state, `done` and `failed` both fall back to words only (the conversation shows and announces the result) and the ring returns to idle.
- **One ring turns per surface.** While the panel is visible (iPad split, or the drawer open), the bar ring shows its still state and the panel's ToolRow turns.
- **What it deletes.** `ResearchRing` (its three branches become the mapping; no test uses its `researchRing` and `answerReadyRing` identifiers); the duplicated `completedBrowserAgentBounce`, `observedAgentID` and `finishedBounceValue` in `PhoneAIButton` and `SplitPanelToggle`, which no view reads any more (the bounce was removed; `MotionTests` only checks `readyAnswer`); the run-state part of the two hand-built accessibility values, which becomes the mapping's word. The other parts stay as they are: "New replies" and the scripts description on both, "Shown" or "Hidden" and "Ask the forum is searching" on the iPad toggle (`IPadLayoutUITests` asserts the last one).
- **AX.**
  - `DCAgentRing` stays hidden from accessibility; the word goes on the button that holds it, so a UI test reads the state as an accessibility value.
  - VoiceOver hears a change at three moments only: needs you (already announced by `AgentConfirmationGate`), done and failed with the panel closed. Never per tool call.
  - Reduce Motion: the arc stands still and the done picture appears without the closing gap. Every state is still told apart by shape and by word; colour is never alone (design-system rule).
- **Speed.** The turning ring is a `TimelineView(.animation)`: its body runs every frame, and rings sit on the drawer-open path (ToolRow) and the typing path (the folded header). The task does not add a per-frame view. No fixture of `DrawerPerformanceTests` draws a turning ring today (every recorded call has `isRunning: false`), so the task first adds a `running` fixture (a run in progress: one turning ToolRow and the folded header), records it on `main`, and then shows before and after (section 4, task 2). If any gets worse beyond run-to-run noise, the one-shot is cut and the still pictures stay.

## 3. The address bar shows Home (owner decision)

### Today

- **Two entries.** Home has its own field ("Search or enter address", `HomeView.addressSection`), and the bar hides its field while Home shows. On a page, tapping the bar's field swaps the bar for `AddressEditBar` (field and Cancel).
- **Home is far away.** From a page: page menu, then Home. That is the owner's complaint.
- **Three resolvers.** Home's `submitAddress` (address, else web search), the bar's `commitAddress` (address, else this forum's search, else web search) and onboarding's `openSite` (address, else web search). Voice has a fourth, stricter one.
- **The bar's field uses the URL keyboard,** which has no space bar: a search of two words or a question cannot be typed comfortably there today.

### Interaction (iPhone)

1. **Tap the address field** (or ⌘L, or the collapsed pill and then the field). The bar becomes the field and Cancel, as today, and rides above the keyboard. **Home appears over the page**, filling the space the page had (between the top safe area and the bar; with the bar at the top, or in landscape, between the bar and the keyboard or bottom edge): the same `HomeList` as today (header with History and Settings, Today, Sites, Recent, Continue reading, Following), on the opaque `ground` colour. It fades in within 200 ms; nothing slides.
2. **The page stays as it was** underneath: same scroll position, same bar state, still loading or playing. **Cancel** (the button, Esc, ⌘., the VoiceOver escape gesture) returns to it untouched.
3. **The field** holds the page's address, selected, so typing replaces it (today's behaviour). While the text is unchanged or empty, Home shows; suggestions start only once the text is not empty and differs from the page's address. Keyboard: `.webSearch` (space and period), as Home's field has today.
4. **Typing** replaces Home's sections with a suggestion list, in one step with no stagger. The first row is what Return does:

   | Input looks like | Row 1 (Return) | Next rows |
   |---|---|---|
   | an address (`bbc.com`, `https://…`, `localhost:3000`) | Open bbc.com | Search the web for it; matching sites |
   | a question or an instruction, and a page is underneath | Ask the Agent: "…" (ring glyph) | Search the web; matching sites |
   | anything else, on a forum with search | Search *forum name* for "…" (today's behaviour) | Search the web; matching sites |
   | anything else | Search *engine* for "…" (Settings › Browser › Search engine) | Matching sites |

   - At most six rows. Matching sites come from `HomeSites.matches`, as today. Everything is local: **nothing typed leaves the device before Return or a tap**, and there are no remote suggestions.
   - The Return key keeps one label ("Go"); the first row carries the meaning. A changing key label reloads the keyboard.
5. **Choosing.** Return runs row 1; a tap runs that row. A site tile, a Recent row or any other Home row opens in this tab, as on Home today. The overlay closes with the same fade.
6. **Ask the Agent** closes the overlay and sends the text through the composer's normal send path: the panel opens and the ring goes to working. Because it is the same path, the App Store rules apply with no new code: the AI consent page (task 2) appears first if consent is missing, and with no model the panel shows its "connect a model" card.
7. **Scrolling Home with the keyboard up** lowers the keyboard and keeps Home. Editing no longer ends when the field loses focus: it ends on Cancel, on a choice, or on a push (History, Settings, Today). This deletes `AddressEditBar`'s "focus lost means close" rule and its 0.6 s workaround, which existed because the page could be tapped while editing; the page is now covered.

### While the Agent works under Home

- The run goes on; Home does not pause it and it does not close Home. Typing is never interrupted.
- When it finishes, fails or asks for a confirmation, the haptic and the VoiceOver announcement happen as today. The edit bar has no ring, so the state shows on the bar's ring the moment editing ends; a confirmation simply waits, as it does today while the panel is closed.
- Choosing "Ask the Agent" while a run is in progress follows the composer's rule for a send during a run; the row adds no rule of its own.

### New tab and the empty tab

- A new tab has no page, so **Home is its content** (as today), and the bar shows its field (today it hides it). `browser.showsForumsHome` keeps its meaning, "this tab has no page", so the about forty places that read it (drawer, voice, scripts, content blocking) do not change. Home over a page does not set it.
- **No keyboard by default** on a new tab opened by touch: the sites stay visible and most new tabs are one tap on a tile. ⌘T with a hardware keyboard focuses the field.
- **Cancel on an empty tab** lowers the keyboard; Home stays, since there is nothing else to show.
- **No "Ask the Agent" row on an empty tab** in this version: the Agent works on a page, and the bar ring is unavailable there today. Asking the Agent from an empty tab (it would have to open pages by itself) is a design gap for design-unified.md, not something to patch in here.

### How input is classified

- **One pure function**, `AddressInput.actions(for:text, context)`, returns the ordered rows; the first is the default. Home's `submitAddress`, the bar's `commitAddress` and onboarding's `openSite` are deleted in its favour. Voice keeps `VoicePageNavigation`: its input comes from a model, so it refuses more (it strips queries and refuses non-web schemes); both share `ForumBrowserModel.resolveAddress`.
- **Address first:** whatever `resolveAddress` accepts today.
- **Question, conservatively:** it ends with `?` or `？`; or it starts with a question or instruction word (what, why, how, which, who, is, can, does, summarize, explain, translate, make, hide, find… and 什么, 怎么, 为什么, 如何, 是否, 帮我, 请, 总结, 翻译…); or it ends with 吗 or 呢. A rule that counts spaces would miss Chinese, so the rule is a word table, tested with English, Chinese and mixed cases.
- **The "can't open this address" alert** (`AddressError`) stays for the one case left: no row can be built at all (the search address cannot be formed).
- **Everything else is a search.** A wrong guess costs one tap, because the other row is always second; and a search never goes to a model by mistake unless it looked like a question.
- **No model call and no network per keystroke.**

### iPad

- **Regular width (split layout).** Home covers the page column only, under the top bar, with `HomeList`'s 760 pt maximum width. The Agent side panel is not covered and keeps working. Not a popover: one view in one container, on both devices.
- **Hardware keyboard.** ⌘L focuses, Esc cancels, Return runs row 1, and the up and down arrows move through the rows.
- **Compact width** (Split View, Slide Over): the iPhone behaviour.

### What moves where

| Today on Home | After |
|---|---|
| The address field and its matches (`HomeView.swift` 141 to 220) | **Removed.** The bar's field is the one entry; matches are suggestion rows |
| Header: "Home", History, Settings | Stays in Home, so both are two taps from any page |
| Today, podcast card, digest strip | Stay |
| Sites grid, Add site, pin and remove | Stay |
| Recent, Continue reading, Following | Stay |
| Pushed pages (History, Settings, Today, digest settings) | A push ends editing; going back returns to the page (or to Home on an empty tab) |
| Empty state: field plus three suggested sites | The three suggested sites; the field is the bar's |
| Page menu › Home | Kept in this plan. It is now a second way to the same place and a candidate to delete: **owner's call** (removing a control needs approval) |
| Settings › "When WukongMind opens: Home" | Unchanged: opens an empty tab |
| Onboarding step 2's own address field | Stays (the bar isn't on screen there); it uses the shared classifier |
| The bar's ring or mic while Home shows | Unchanged |

### Accessibility

- **VoiceOver.** Activating "Address field" moves focus to the field, and Home is announced as a new screen. The covered page is hidden from accessibility while Home shows (as the drawer already does with the web view). Rows are buttons whose labels are the full sentence ("Ask the Agent: which fanless box is quietest?"). When the kind of row 1 changes, one short announcement says so ("Return asks the Agent"), not on every keystroke. The escape gesture cancels.
- **Reduce Motion.** The fade stays (a fade is the Reduce Motion form); nothing else moves.
- **Dynamic Type.** Rows wrap to two lines; at accessibility sizes the list scrolls and row 1 stays first. The site grid is adaptive already.
- **Reduce Transparency.** Not affected: Home is opaque.

### Speed

- **Hot paths:** tap to Home's first frame, and each keystroke in the suggestion list.
- **No number exists today,** so the first address-bar task (task 3) adds the measurement and records today's tap-to-edit-bar and Home-field keystroke times.
- **Budgets:** first frame within 200 ms of the tap on iPhone 13 (the drawer's budget) and not slower than today's tap-to-edit-bar plus one frame; a keystroke's main-thread pass under one frame (16.7 ms) with 40 sites.
- **Why opaque, not blurred:** a live blur over a `WKWebView` is composited every frame while the page under it scrolls or plays. It adds cost and no information. Cut.
- **Home is built when first shown,** not kept mounted over the page; its list is lazy.

### Against the App Store tasks

- Terms (task 5) and AI consent (task 2) come before any of this is reachable. "Ask the Agent" adds no new way to send data: it uses the composer's send path behind the consent backstop.
- Nothing hidden: the first row always states what Return will do, the search engine setting is respected, and nothing typed leaves the device before the user acts.

## 4. Tasks

Ordered by felt value per effort. Each is one pull request with its own check. Simulator runs go through `scripts/remote-test.sh`; device numbers through `scripts/device-check.sh`. "Perf check" means the commands below, before and after, with the raw output in the proof.

- Hosted: `scripts/remote-test.sh -only-testing:WukongMindTests/DrawerPerformanceTests` (open, keystroke and scroll-step medians per fixture).
- Whole app: `scripts/remote-test.sh -only-testing:WukongMindUITests/LongThreadDrawerPerfUITests`, and on the iPhone 13 via `scripts/device-check.sh` where the task says so.
- A task fails its perf check if a median is worse than before by more than the spread of three runs.

| # | Task | Why | Scope (files) | Size | Depends on | Done when, and how it is proven |
|---|---|---|---|---|---|---|
| 1 | **The motion rule, made true.** Write the new rule into design-unified.md §6 (and the "Motion" bullet in its intro); delete the mic's `.symbolEffect(.pulse)`, the loading skeleton's pulse, the summary placeholder's pulse (`PulseModifier`) and the unused `TypingIndicator`; delete the unread bounce state in `PhoneAIButton` and `SplitPanelToggle` | The rule the next tasks are judged by; pure deletion | `design-unified.md`, `VoiceViews.swift`, `AssistantStates.swift`, `SummaryPanel.swift`, `PhoneBrowserBar.swift`, `SplitWorkspace.swift`, `MotionTests.swift` | XS (half a day) | — | `rg` finds no `symbolEffect(.pulse`, no `TypingIndicator`, no `phaseAnimator`, no `repeatForever` in `AssistantStates.swift` and no `finishedBounceValue`; the `repeatForever` and `TimelineView(.animation` hits that remain are exactly the loops the rule names (listed in the pull request); `MotionTests` and `BrowserBarMorphTests` pass; a screenshot of the bar with voice on (mic.fill, gold-ink) |
| 2 | **Ring states.** `AgentRingState`, the one mapping function, `DCAgentRing(state:)` with the still pictures and the done one-shot; the bar ring, pill ring, panel toggle, folded header and ToolRow disc use it; `ResearchRing` deleted; the word is the buttons' accessibility value; hover highlight and focus ring on the ring (iPad); the bar ring stands still while the panel is visible | The ring says what the Agent is doing and what it needs, in one place | `DesignSystem.swift`, `PhoneBrowserBar.swift`, `SplitWorkspace.swift`, `ConversationViews.swift`, `SummaryPanel.swift`, `BrowserAgent.swift` (`seenRunID`), a new `AgentRingStateTests.swift`, `IPadLayoutUITests.swift` (its toggle value still holds), `Localizable.xcstrings` | S (1 to 2 days) | 1 | Unit: a table test of the mapping (every `BrowserAgentRunState`, seen and unseen, a restored conversation whose last run ended (not unseen), confirmation waiting, no page, panel visible). UI: with a recorded browser-agent run and the panel closed (not the `-dc-answer-ready` sample, which seeds DEBUG-only records), `aiButton`'s value goes "Working" → "Answer ready", clears after the panel is opened, and reads "Needs your answer" on a confirmation. Screenshots of the six states, light and dark. Reduce Motion: a unit test of the pure function that picks the motion (`working` + Reduce Motion → still; `done` + Reduce Motion → no closing gap), since there is no launch argument for it and UI tests run with `-dc-no-animations`. Perf check, hosted (with the new `running` fixture, recorded on `main` first) and whole app |
| 3 | **Address bar: measure, and one classifier.** `PerfProbe` marks for tap-to-edit-bar and per-keystroke; a UI perf test that records today's numbers. `AddressInput.actions` (address, forum search, web search) replaces the three resolvers; behaviour unchanged | A baseline before the change; three code paths become one | `PerfProbe.swift`, a new `AddressInput.swift` and tests, `HomeView.swift`, `PhoneBrowserBar.swift`, `Onboarding.swift`, a new `AddressBarPerfUITests.swift` | S (1 day) | — | Unit: a table test (addresses, hosts with ports, searches, forum page or not; the cases of today's `HomeTests` and `BrowserBarMorphUITests` still pass). The perf test prints today's numbers, recorded in this doc |
| 4 | **Home over the page (iPhone).** Editing shows `HomeList` over the page; the empty tab shows the bar's field; Home's own field is removed; `.webSearch` keyboard; editing no longer ends on focus loss; Cancel returns to the untouched page | The owner's decision: Home is one tap from anywhere | `PhoneBrowserBar.swift`, `HomeView.swift`, `ForumBrowser.swift` (`setEditingAddress`); the UI tests that use `homeAddress` move to `addressField` (`HomeUITests` and `PhysicalDeviceSmokeTests`; the other suites already use `addressField`) | M (2 to 3 days). Stop and ask if it passes 400 changed lines | 3 | UI: tap the field on a page → `home` exists and the page's scroll offset is unchanged after Cancel; a tile opens in the same tab; new tab shows Home with `addressField` and no `homeAddress`; scrolling Home lowers the keyboard and keeps it; a push and back returns to the page. Screenshots (light, dark, XXXL). Perf: task 3's test, before and after, on the simulator and the iPhone 13; first frame within 200 ms |
| 5 | **Suggestions and "Ask the Agent" (done, WUKO-188).** The suggestion list replaces Home's sections while typing; the question rule joins the classifier; row 1 is the default; the announcement when its kind changes; `PresentationRouter.pendingProviderSetup` carries the setup-card request when asking from the address bar with no Agent model | The address bar becomes the one input: go, search or ask | `AddressInput.swift` and tests, `AddressSuggestions.swift`, `PhoneBrowserBar.swift`, `HomeView.swift`, `ForumBrowser.swift`, `PresentationRouter.swift`, `SummaryPanel.swift`, `Localizable.xcstrings`, `AddressSuggestionsUITests.swift` | S to M (2 days) | 4; App Store task 2 if it has merged (the consent page then shows first; the test covers both orders) | Unit: the classifier table with English, Chinese and mixed questions, and near misses that must stay searches ("what.cd", "how to geek", "will smith", "list price", "show hn", "can opener", "什么值得买", "翻译软件", a pasted URL with `?`). UI with recorded responses: a question + Return opens the panel and `aiButton` reads "Working"; a search opens the engine; no "Ask" row on an empty tab; with no model the panel's setup card shows. A test that no request leaves while typing. Keystroke numbers from task 3's test, before and after |
| 6 | **Home over the page (iPad).** Page-column overlay under the top bar; arrows, Return, Esc; the side panel untouched (also covers iPad's interim focus-loss state from task 4, where the top edit bar stays up until Cancel or Esc while no overlay is shown yet) | The same change on the other device | `SplitWorkspace.swift`, `PhoneBrowserBar.swift` (shared bar), `AddressSuggestions.swift` | S (1 day) | 5 | UI on the iPad simulator (`--sim ipad`): ⌘L, type, ↓, Return opens the second row; Esc returns to the page; the panel stays visible and usable. Screenshots in split and compact width |
| 7 | **"Saved" uses the ring's done (done, WUKO-196).** The saved note, the Learn on ask "Reads this site" card and onboarding's key row show the ring's done transition once, after the event really happened | One vocabulary for "it worked" | `ConversationViews.swift` (`DCSavedNote`), `ScriptViews.swift`, `SettingsProviderForm.swift` (`ProviderTestStatusView`, shared by `OnboardingSteps.swift` and Settings provider forms), `BrowserAgent.swift` (`doneShownRunIDs`), `DesignSystem.swift` | XS (half a day) | 2; App Store task 4 for scripts (done fires after the user approves the review sheet and the save succeeds, never while the sheet is up); App Store tasks 5 and 2 for the key row (Terms, then consent, then the key test; done fires on the test's success) | UI: after an approved save the note's ring has the value "Saved"; declining the sheet shows no note and no ring; a failed key test shows the cinnabar text and no ring |
| 8 | **Design files (done, WUKO-200).** Apply this page to the design-system artifact and the canvas, and re-export `docs/wukongmind/design/` with PNGs (section 5) | The exported design must match what is built | `docs/wukongmind/design/` (export only), `design-unified.md` §3, `design-browser-bar-tabs-models.md` (the Home row) | S (1 day), on Claude (visual work), like D1b | 2 and 5 merged | The export's README names the new versions; PNGs of the changed boards, light and dark |

**Order with the App Store work.** Tasks 1 to 6 do not touch onboarding's flow and can run beside App Store tasks 2, 4 and 5. Task 7 waits for them, because they decide when "saved" and "verified" really happen. If App Store task 2 or 5 is in flight, task 3 leaves `Onboarding.swift`'s `openSite` to whichever merges second (a three-line change).

**Not planned** (deferred above): the page outline and its API, live rings in Recent, the Agent from an empty tab, deleting Page menu › Home.

## 5. Design files to update

`docs/wukongmind/design/` is a read-only export; none of it is edited by hand. The written rule changes in task 1; the artifacts and the export in task 8.

| File or board | Change | Task |
|---|---|---|
| `design-unified.md` §6 and its intro bullet | The new motion rule; the ring states row; the continuous motion the rule now names | 1 |
| `design-system/README.md`, "The ring" and the Motion line under Accessibility | The six states with their still pictures and words; the new rule | 8 |
| `design-system/components/ToolRow`, `BrowserBar`, `Composer` | Ring states; the bar's edit state with Home above it; the suggestion rows | 8 |
| Canvas `Motion` | The rule, the done one-shot, Home's fade | 8 |
| Canvas `PhoneBar`, `IPadBar` (+Dark) | Ring states; the edit state over Home; suggestions | 8 |
| Canvas `PhoneHome`, `IPadHome` (+Dark) | No address field; Home over a page; the empty tab | 8 |
| Canvas `PhoneOnb1` (+Dark), `IPadOnb` | The key row's done ring (after the App Store pages are drawn) | 8 |
| `design-unified.md` §3; `design-browser-bar-tabs-models.md`, the "Home" row of the ring table | Home has no field; the bar shows its field on Home | 4 (text), 8 (boards) |

**Where task 8 put it** (canvas version 73, design-system version 15, exported 2026-11-20). The existing boards kept their sizes, so nothing on the canvas moved: `Motion`, `PhoneBar` (its Home frame), `PhoneHome`, `IPadHome`, `PhoneOnb1`, `PhoneOnb3` and `IPadOnb` (now step 1, where the key row is) were redrawn in place. The ring states, the edit state over Home and the suggestions needed more room than `PhoneBar` and `IPadBar` have, so they are new boards in a new canvas section: `MotionRing` (six states, the done one-shot, Saved), `PhoneAddress` (Home over the page, the four kinds of row 1, the empty tab), `IPadAddress` (the page-column overlay and keyboard selection, marked "per design, iPad build pending") and `PhoneTerms` (Terms of Use and AI data consent). `IPadBar` is unchanged. The removal of the daily digest and the podcast (WUKO-182) and pinned sites (WUKO-181) were applied to `PhoneHome`, `IPadHome`, `PhoneSettings`, `IPadSettings`, `PhoneSites`, `Main`, `IA`, `Glossary` and `Migration`.

## 6. Checked in this task

- Baseline of the suites the tasks build on, run on the Mac mini at `6d122e1` (iPhone 18 Pro simulator): `MotionTests`, `BrowserBarMorphTests`, `DrawerPerformanceTests`, `HomeTests`, `OnboardingTests`: 58 tests, 0 failures. Hosted drawer numbers from that run (Debug, simulator), across its 18 fixtures: open 37.1 to 75.4 ms, keystroke median 1.4 to 7.9 ms, scroll step median 8.0 to 15.1 ms. They are the simulator "before" for task 2, apart from the `running` fixture it adds.
- The iPhone 13 numbers cited (drawer open 144 to 166 ms, typing 192 ms per key) are from [design-performance-2.md](design-performance-2.md), not re-measured here.
- **Address-bar baseline (task 3, Mac mini, iPhone 18 Pro simulator, Debug, `-dc-perf-probe`, `AddressBarPerfUITests`):**
  - `tap_to_edit_bar` (`browserTitle` tap on `-dc-bar-morph-fixture short`): `m:addressEdit.tap=88` ms, `f:addressEdit.tap=89` ms, `h:AddressEditBar.body=97/394x3`, `m:addressEdit.focus=280` ms, `f:addressEdit.focus=391` ms, `busy_ms=405` ms (main-thread pass `p:87+338` ms for bar + keyboard).
  - `home_keystrokes` (20 characters typed in `homeAddress` with `-dc-forums-home -dc-seed-forums`): `busy_ms=1116` (`55.80` ms/key), `passes=427` (`21.35`/key), `over16=24` (`1.20`/key), `over33=7` (`0.35`/key), `over50=0`, `n:HomeList.body=20` (`1.00`/key), `n:HomeSites.matches=20` (`1.00`/key), `us:HomeSites.matches=712` (`35.60` µs/key).
- **Motion 5 keystroke perf (Mac mini, iPhone 18 Pro simulator, Debug, `-dc-perf-probe`, `AddressBarPerfUITests` × 3):**
  - Before (`77f0134`): `home_keystrokes` `busy_ms` = 1258, 1385, 1348 ms (median `1348` ms / `67.40` ms/key, spread `127` ms), `over33` = 16, 17, 18 (median `17`), `over50` = 2, 5, 3 (median `3`); `tap_to_edit_bar` `f:addressEdit.tap` = 91, 72, 85 ms (median `85` ms).
  - After (WUKO-188): `home_keystrokes` `busy_ms` = 670, 706, 5564 ms (median `706` ms / `35.30` ms/key; run 3 saw host contention), `over33` = 0, 1, 32 (median `1`), `over50` = 0, 0, 28 (median `0`), `n:HomeList.body=0`, `n:AddressSuggestionsList.body=20` (`1.00`/key), `n:AddressInput.actions=20` (`1.00`/key), `n:HomeSites.matches=20` (`1.00`/key); `tap_to_edit_bar` `f:addressEdit.tap` = 77, 75, 79 ms (median `77` ms).

## 7. Not proven

- **No prototype was built.** Whether the six still pictures read apart at 16 pt, and whether the done one-shot feels right at 250 ms, is settled in task 2 by its screenshots, not here.
- **Address-bar speed.** No number exists for tap-to-Home or per-keystroke suggestions; task 3 adds the measurement. The 200 ms budget is the drawer's, assumed to fit.
- **The question rule's accuracy.** The word table is a design, not a measurement; task 5's table test fixes the cases, and real misfires will only show in use.
- **The URL keyboard has no space bar:** stated from the system keyboard's known layout, not checked on a device in this task.
- **Deleting "focus lost means close"** is safe only if nothing else relied on it (hardware-keyboard shortcuts were the reason for its 0.6 s guard); task 4's UI tests on iPad decide.
- **`seenRunID` is enough** for done and failed across tabs and the iPad panel: a design, to be confirmed by task 2's tests. Whether `readyAnswer`, `activeResearch` and `answersSeenAt` are dead outside DEBUG builds was read from `rg`, not from a Release build.
- **`finishedBounceValue` is unread:** from `rg` over `WukongMind/` and `WukongMindTests/` (definitions only), not from a build with it removed.
- **Release build on the iPhone 13** for any of this: nothing here ran on a device.
- **The owner's agreement to the three "已同意" rows** was not found in the repo; if it was given elsewhere (a chat), the verdicts for items 2 and 3 are the owner's to overrule.

## 8. Board and build, checked in task 8 (WUKO-200)

Each redrawn or new board was compared with simulator screenshots of the build at `56fcff8` (Mac mini, iPhone 18 Pro and iPad Air 11-inch, light and dark, taken with a throwaway UI test that was not committed). Section 3 above was written before WUKO-182: read its lists without Today, the podcast card and the digest strip, which no longer exist.

| Screen | Difference between board and build | Outcome |
|---|---|---|
| Home on the empty tab, iPhone | The earlier board and the bar spec gave the bar a mic in place of the ring. The build shows back, the field and tabs; the mic appears only once voice is set up, and there is no ring | Board and the "Home" row of design-browser-bar-tabs-models.md fixed to the build |
| Home on the empty tab, iPad | The build keeps the ring in the bar on an empty tab (it is the panel toggle there) | Board drawn as built |
| Suggestions for an address on a site with search | Section 3's table lists "Open", then the web search. The build puts "Search *site*" between them | Board drawn as built; the extra row costs nothing and is consistent with "search this site" elsewhere |
| The keyboard's Return key | Section 3 says the key keeps one label, "Go". With the `.webSearch` keyboard the system draws its blue arrow key | Board drawn as built; the rule (one unchanging key) holds |
| The failed ring | Section 2 says "the warning mark". The build draws an exclamation mark in the `warning` colour | Board drawn as built |
| Terms of Use and AI data consent | **Design gap, not fixed here (no app code in this task).** Both pages show the system background, pure white in light and pure black in dark, where the design system says neither theme uses pure white or black for surfaces. The boards draw them on `ground` | To fix in the app: give `TermsAndReportingViews` and `AIDataConsentViews` the `ground` background |
| Settings root and Settings › Sites | **Design gap in the boards, not fixed here.** The build shows the inline title with a round Done or Back button and sentence-case section headers ("Assistant"); the Settings boards (`PhoneSettings`, `PhoneSites`, `PhoneModels`, `PhoneAgentSettings`, `IPadSettings`, `M4Settings`) still draw a large title and upper-case headers. Rows and values were brought in line (no digest row, "3 sites", Pinned sites, Limit request rate with Gentle, Standard and Fast) | A later design task should redraw the Settings chrome on all of those boards at once |
| iPad, editing the address | The build shows the edit field and Cancel over the page column and keeps the page visible; no Home overlay and no suggestions yet | Expected: Motion task 6 is in flight. `IPadAddress` is drawn from section 3 and marked "per design, iPad build pending" |

Not proven in task 8 (also in its proof): the key row's done ring ("Connected — you're ready to go.") and the failed ring were not caught in a screenshot, and are drawn from `ProviderTestStatusView` and `DCAgentRing`; the done one-shot's timing is from the code's constants, not measured; the boards are 390 × 844 and 1194 × 834 pt drawings, compared by eye with 402 × 874 and 1180 × 820 pt screenshots, not overlaid.
