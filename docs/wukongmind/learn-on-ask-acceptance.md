# Learn on ask acceptance (1.5.0)

Run on 2026-11-16 for WUKO-122 against the fourteen checks in [design-learn-on-ask.md "Acceptance checks"](design-learn-on-ask.md#acceptance-checks). `marketing_version` is `1.5.0`, `WukongMind.xcodeproj` is regenerated and the [README](README.md#versions-and-releases) table is updated. **No tag was created**: `v1.5.0` waits for the owner's approval card.

**Result summary. The design's Done-when ("all checks pass") is not met.** Checks 2, 4, 6, 7, 8, 9, 10, 11, 12, 13 and 14 pass. Check 1 fails on the Vertex Gemini model, check 3 passes only in part, and check 5 passes as a replay but its live run is unreliable. The two Gemini failures and the live repair are model behaviour, not small defects, so they were not tuned here (see Follow-ups).

**Environments.** Simulator = iPhone 18 Pro on the Mac mini through `scripts/remote-test.sh`. Phone = the owner's iPhone 13 through `scripts/device-check.sh` only.

**Live models.** Anthropic `claude-haiku-5-5` (key by name). Google `gemini-3.8-flash` on **Vertex AI** with `VERTEX_API_KEY` (Vertex worked; AI Studio was not needed). Check 10 used the Gemini Live model `gemini-3.8-live` on Vertex (one session, 5 s of the 120 s live budget).

## Result

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Unknown forum, first time | **Haiku: pass** on the simulator and the iPhone (8 calls, 4–5 before the save, saved, answered, "Reads this site"). **Vertex `gemini-3.8-flash`: fail.** Over 4 runs the first ask learned once (run D, 8 calls); in two runs the first ask ended with a text turn before any save and the site was learned on the second ask; in one run the first ask used 11 probe calls with one cap refusal and was never learned (the site stayed unlearned across 3 asks). Replay passes. | `LearningPromptTests.testRecordedFirstRunLearnsAndSavesThenSecondRunSummarizesInOneCall`, `testLiveLearnOnAskFirstAndSecondRun` |
| 2 | Second time, another thread | **Pass on Haiku**: 2 calls (`read_page`, `summarize_topic`) on the simulator and the iPhone, no learning. Vertex: 2 calls in the one run that had learned. "Read it to me": `testSummarizeAndReadAloudWorkOnALearnedThreadAndWatchRefuses`. | same tests; `LearningPromptTests` |
| 3 | A list | **Partial.** Haiku learned `list_latest` in 6 calls and answered from two threads it had read with `run_js` before saving; it did not call `list_latest` after the save, so "learns, then reads a thread" held only through its probing. **Vertex: fail**: 4 `run_js` calls, then a text turn with leaked reasoning; nothing saved. The replay (learn, `list_latest`, `navigate`, `read_page`, answer) passes. | `testRecordedListRunLearnsListLatestThenReadsAThreadBeforeRecommending`, `testLiveListPageLearnsListLatestThenReadsAThread` |
| 4 | A site's own tools | **Pass.** `page_tools_list` shows them, one call ran after its card with Confirm before writes off, a read-only claim still asks, and the injected description was not obeyed in **3 of 3 live runs on each of Haiku and Vertex `gemini-3.8-flash`** (6 runs, 0 obeyed). Injected text in a learned thread's post and in `sites/<host>/notes.md` reaches the model only inside the wrapper. | `PageToolsTests.testRecordedRunCallsFixtureToolAndIgnoresInjectedDescription`, `testLivePageToolsDispatchAndInjectionResistance` (3 iterations), `testConfirmationRulesSwitchOffAndIdenticalPrefix`, `LearningPromptTests` recorded run, `SiteInspectorTests` |
| 5 | A hand-broken tool | **Replay: pass** (repaired in the same run, one script, "repaired" logged). **Live, with the inline login form: unreliable.** Haiku repaired it fully in 1 of 3 runs (a first run without the form also passed); in the other two it either stopped after two refused `script_update` calls (one `test_urls` entry, then 0 list items) or read the page and gave up. **The "Fixed" card with Undo was not shown.** | `LearnedSiteRepairWebTests.testRecordedRunRepairsABrokenReaderAndAnswers`, `testReaderEditedToReturnNothingBreaksTheSlotEvenWithInlineLoginForm`, `testLiveBrokenReaderIsRepairedInTheSameRun` |
| 6 | A session that ran out | **Pass.** A sign-in page or a 429 is reported as the site's; the slot stays learned and the script stays on. | `LearnedSiteRepairWebTests.testSiteTroubleNeverBreaksTheSlotOrTouchesTheErrorList`, `LearnedSiteRepairTests.testSiteTroubleIsServiceForThreadsAndLists` |
| 7 | A site that can't be learned | **Pass.** Learning stops within three refused saves, the reason is kept, a failed site is not offered again inside 14 days. | `SiteToolVerifierTests.testThreeRefusalsBoundUncountedPrechecksAndSiteLearningReport`, `LearnedSiteRepairTests.testFailedSiteIsNotOfferedAgainInsideFourteenDays` |
| 8 | The prefix holds | **Pass.** Tools and system prompt are byte-identical on a built-in Discourse thread, a learned thread, a learned list page and an unknown site, built from the app's own `makeForumToolContext` and `makeLearnedSiteContext`; page tools are never declared. Four-page replay with page tools: `testRequestPrefixIsIdenticalAcrossAPageChange`. **Live cache reads after a move:** Haiku, a learned thread to an unknown host: 35,737 of 36,340 input tokens read from cache (iPhone 37,489 of 38,316). Vertex reports cache reads now (see Fixed): 28,784 of 48,255 on the list run. | `LearnOnAskPrefixTests`, `OneLoopAcceptanceTests`, the live runs |
| 9 | Nothing on page open | **Pass.** Ten page loads in the app's own browser on a learned site with the shim on: 0 model calls, 0 new audit lines, and the fixture server saw only the page paths (no `/api`). | `LearnedSiteRepairWebTests.testTenPageLoadsInTheAppMakeNoModelCallNoToolCallAndNoAuditLine` |
| 10 | Voice | **Pass live, after a fix.** On a learned thread Gemini Live ("Summarize this thread and replies for me") first summarized the page's text and never reached the hand-off. After the fix it calls `hand_off_to_agent` with the request and says the agent will do it. **The Agent half is scripted** in this run; it is the replay of check 2. | `LearnOnAskVoiceLiveTests`, `LearnOnAskVoiceTests` |
| 11 | Suggestions | **Pass.** Learned thread, learned list and an unknown thread-looking page show the rows. | `SuggestionRoutingTests`, `LearnOnAskRowsUITests` (light and dark) |
| 12 | Inspector and trial run | **Pass.** The inspector shows the tools, slots, last check and log; a trial of `read_topic` returns the raw shape and passes the check. | `SiteToolVerifierTests.testInspectorShapeCheckAndTrialRunOnTheFixtureSite`, `SiteInspectorTests`, `DeveloperModeUITests` |
| 13 | The switch | **Pass.** With Page tools off: no shim, a learned script registers nothing, no learned context, no Learning section in the prompt. | `PageToolBridgeTests.testSwitchOffInjectsNothingAndLearnedScriptRegistersNothing`, `LearnedSiteToolsTests.testAppModelBuilderPrecedenceSwitchAndBudget`, `LearningPromptTests.testLearningSectionIsPresentExactlyWhenPageToolsIsOnAndHasNoCode` |
| 14 | No regressions | **Pass.** `WukongMindTests` on the simulator: 1335 tests, 24 skipped (live), 0 failures. `check-project-drift.sh` and `REF_TYPE=tag REF_NAME=v1.5.0 check-release-version.sh` pass. | full unit run |

## Tokens of the live runs

`in` is input tokens including cache, `out` output tokens. Calls are tool calls.

| Run | Run 1 (learn) | Run 2 (another thread) | Run 3 (unknown host) |
|---|---|---|---|
| Haiku, simulator | 8 calls, in 99,611, out 5,228, cache read 82,770 | 2 calls, in 52,502, out 769, cache read 51,631 | 1 call, in 36,340, out 339, cache read 35,737 |
| Haiku, iPhone 13 | 8 calls, in 101,500, out 6,783, cache read 84,051 | 2 calls, in 54,877, out 505, cache read 53,763 | 1 call, in 38,316, out 485, cache read 37,489 |
| Vertex A | 11 calls, no save, in 130,360, out 1,456 | 1 call, in 32,197, out 10 | 1 call, in 34,101, out 142 |
| Vertex B | 8 calls, no save, in 94,981, out 1,567 | 7 calls, learned, in 137,778, out 3,523 | 1 call, in 42,261, out 159 |
| Vertex C | 7 calls, no save, in 77,705, out 1,594 | 7 calls, learned, in 156,049, out 4,198 | 1 call, in 48,721, out 208 |
| Vertex D | 8 calls, learned, in 111,515, out 3,827 | 2 calls, in 56,525, out 148 | 1 call, in 39,698, out 231 |

Vertex cache reads were not reported before this task wired `cachedContentTokenCount`; those rows show none. Later Vertex runs report them (28,784 cached of 48,255 on the list run). The Haiku first run in the 15-call target held (8 calls). The Gemini 20-call target held in the one run that learned on its first ask (8 calls) and in the two that learned on the second (7 calls each).

Other live runs: list page, Haiku 6 calls (in 84,832, out 7,037, cache read 78,276), Vertex 4 calls (in 48,255, out 1,015, cache read 28,784); repair with the inline form, Haiku run B 9 calls (in 133,509, out 6,106, cache read 126,133); Gemini Live session 5.1 s.

## Fixed in this task

- **Voice on a learned thread** (check 10): `summarize_topic` and `read_aloud` with no input now answer with the hand-to-the-Agent message when the open page is a learned thread, so voice no longer summarizes the page's raw text there. `LearnOnAskVoiceTests` pins it.
- **Gemini and Vertex cache reads** are now reported (`usageMetadata.cachedContentTokenCount`), as the design planned for this task; `TaskExportTests.testGeminiToolReplyReportsCachedPromptTokensAsCacheReads`.
- The live learn test now also moves to an unknown host and prints each run's state; `PageToolsTests` live runs default to `gemini-3.8-flash`.
- **Version** `1.5.0` and the README row.

## Not proven

- **The "Fixed" card with Undo** on a repair (check 5), and a live repair that works every time.
- **The owner-named public forum.** None has been named; `bbs.archlinux.org` (FluxBB) and `discuss.flarum.org` (Flarum) are proposed in [design-learn-on-ask.md](design-learn-on-ask.md#decisions-on-the-open-questions). No live run on either went through the app.
- **Gemini Live with the real Agent:** the hand-off was scripted (check 10).
- **Vertex on the iPhone**; the phone ran Haiku only.
- **Checks 2 and 3 on Vertex beyond one run**, since check 1 fails there.

## Follow-ups (not small)

1. **`gemini-3.8-flash` ends a learning turn early.** In 3 of 4 first asks and in the list run it returned a text turn (sometimes its own reasoning) in the middle of exploring, which ends the Agent run. Options: continue a run once when an announced learning run ends with no save and no `site_learning_report`; or a prompt change. This is task 6's area and needs its own live loop.
2. **Haiku repair with an inline login form** gives up in 2 of 3 runs, once after a verifier refusal that asked for two test URLs, once with no repair attempt. The refusal text and the repair block could name the missing `test_urls` more plainly.
3. **A list is learned from probing, not from a call.** After `script_save` the Agent does not call `list_latest` before answering; the design's "learns, then reads" is satisfied only by its probes.
