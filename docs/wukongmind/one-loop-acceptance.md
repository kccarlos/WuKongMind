# One loop acceptance (1.3.0)

Run for WUKO-70 against [design-one-loop.md "Acceptance checks"](design-one-loop.md#acceptance-checks) on 2026-11-14. Two places:

- **Simulator:** the fixed iPhone 18 Pro simulator.
- **Phone:** the owner's iPhone 13, only through `scripts/device-check.sh`.

Every live run used **claude-haiku-5-5 only** (`-dc-browser-agent-live-model claude-haiku-5-5`, key by name from `herdr-secret`). Each evidence file starts with `model: claude-haiku-5-5`. The recording's audit log ([`model-audit.jsonl`](../../WukongMindTests/Fixtures/OneLoopAcceptance/model-audit.jsonl)) has 6 calls, all `claude-haiku-5-5`.

Evidence is text in [`one-loop-acceptance/`](one-loop-acceptance/); names below are relative to it. Screenshots are in the WUKO-70 proof artifact. No file holds a key.

Live debug launches never write the app's saved state (`AppModel.save` returns early for them), so nothing on the phone was changed. The same rule means a relaunch can't be shown live (check 8).

## Result

| # | Check | Result | Where | Evidence |
|---|---|---|---|---|
| 1 | Multi-step Discourse request | **Pass, typed.**<br>**Simulator** (meta.appinn.net, D3's thread): `summarize_topic`, `search_forum` ×2, `summarize_topic` on a found thread, `read_aloud`, then an answer with numbered chips. Tapping chip S2 opened thread 66683 in the browser; the screenshot shows its post.<br>**Phone** (meta.discourse.org/t/410209): `summarize_topic`, `search_forum` ×5, `summarize_topic`, then `read_aloud`. Tapping chip S4 opened thread 412350, whose title shows in the browser bar.<br>**Replay fixture:** `OneLoopAcceptanceTests.testMultiStepDiscourseRequestReplays` passes (summarize, 3 searches, `read_aloud`, then a cited answer).<br>**Said, by voice: not run** (see Not proven). | Simulator, phone, unit test | `check1-simulator.txt`, `check1-phone.txt`, [`acceptance-run-A1.json`](../../WukongMindTests/Fixtures/OneLoopAcceptance/runs/acceptance-run-A1.json) |
| 2 | Suggestion and typed parity | **Recorded part passes:** `SuggestionRoutingTests.testTappedAndTypedSuggestionsMakeTheSameAgentRequest` and `testSearchThisForumSendsTheCompletedTextAsTyped`.<br>**The owner's side-by-side comparison on the phone is the owner's to make** (Not proven). | Unit tests | full unit run |
| 3 | One loop for text, shared with voice | **Grep passes:** `AgentEngine.swift` is gone; `AgentPlanner`, `AgentPrompt`, `AgentToolName`, `startAgentRun` and `sendChat` occur 0 times as whole words in app and test code.<br>**Voice declarations come from the registry:** `VoiceToolTests.testVoiceDeclarationsAreTheRegistrysVoiceToolsAndTheTextAgentHasNoBrowseTools` passes.<br>**Saying "Switch to dark mode": not run** (voice). Typed "Make it dark" on an ordinary page took effect on both the simulator and the phone (check 8's first turn). | Simulator, phone, unit tests | `check3-grep.txt`, `check8-*.txt` |
| 4 | Background features unaffected | **Tests pass:** `DailyDigestTests`, plus the follow and notification tests in `CoreTests`, `StateTransitionTests` and `CapabilityToolsTests`, are all in the full run.<br>**A new reply notifying for a followed thread is manual:** not run (Not proven). | Unit tests | full unit run |
| 5 | The comparison came first | **Partly fails.**<br>`one-loop-comparison.md` carries the approval line (WUKO-63, merged 2026-11-14 18:15 UTC). All five deletion PRs merged after it: #66 at 18:57, #67 at 19:19, #69 at 19:59, #70 at 21:34, #71 at 22:07.<br>**Only #70 and #71 link the comparison in their description; #66, #67 and #69 don't.** Merged PRs were not edited (follow-up). | GitHub | `check5-prs.txt` |
| 6 | Long threads | **Unit test passes:** `ForumToolsTests.testLongThreadSavesToWorkspaceAndFallsBackWithoutWorkspace`.<br>**"Visible in Files": not shown** (Not proven). The comparison's recorded runs also save long threads under `results/<task-id>/` (for example W5 in `one-loop-comparison.md`). | Unit test | full unit run |
| 7 | Two model roles | **Pass.** Settings › Models shows Agent and Summaries, with no Ask the forum row: `SettingsNavigationUITests.testAIModelsPageShowsBothRolesAndOpensARolesPicker` passes on the simulator. On the phone its two role rows also pass and the screenshot is in the proof, but the later picker step failed because the test could not scroll back up on the smaller screen. A saved `agent` selection decodes and is dropped: `ModelSwitchingTests.testSettingsWithAnOldAgentRoleDecodeAndDropIt`.<br>**Apple Intelligence summaries:** only the recorded `AppleIntelligenceTests` pass. The live tests skip, since neither the simulator nor an iPhone 13 has Apple Intelligence (Not proven).<br>**Fixed:** `-dc-agent-model` had stopped reaching the Agent row when One loop 14 removed the old role. | Simulator, phone, unit tests | full unit run |
| 8 | Agent answers in History | **Pass for what can run live, on the simulator and the phone.**<br>The cited forum answer from check 1 is in History and opens read-only in `SavedAnswerView`, with question, answer and sources and no composer.<br>The long ordinary-page answer is saved under "Other sites" and opens.<br>**"Make it dark" follows the save rule but is often saved:** Haiku's confirmations ran from 174 to 444 characters across six runs. Only the 174-character one stayed under 200 and was not saved, so the "a short page-change turn adds nothing" case held only once (follow-up). The test checks the rule: the turn is saved exactly when its reply is 200 characters or more.<br>**After relaunch: unit tests only.** `AgentAnswerHistoryTests` covers storing, decoding, the save condition and sync encoding; live debug launches never save, so a relaunch can't be shown. | Simulator, phone, unit tests | `check8-simulator.txt`, `check8-phone.txt` |
| 9 | No regressions | **Pass on the simulator:** 1,102 unit tests, 10 skipped (live-only), 0 failures. This includes `OneLoopComparisonTests.testRecordedNewSideRunsReplay` (all 18 recorded new-side runs) and the new fixture's replay. CI runs the same on the pull request. | Simulator, CI | full unit run |

## Fixed in this task

- **The answer must come last (prompt rule 7).** On the first recording of check 1, Haiku wrote the cited answer beside the `read_aloud` call, then a short closing note. The app shows and saves only the final message, so the cited answer disappeared from the conversation and History. Rule 7 says the whole answer goes in the final message, after any `read_aloud` call. The fixture was then recorded again (attempt 2), and its answer comes last with its citations.
- **`-dc-agent-model`** sets the Agent's model again, so the Settings › Models UI test passes.
- **Live acceptance UI tests** (`OneLoopLiveAcceptanceUITests`, new). Check 1 waits for the thread suggestions and then types the request, as a person would. A chip tap passes only when the browser's title bar shows the cited thread.

## Not proven

- **Check 1 said by voice, and check 3's spoken "Switch to dark mode".** Both need Gemini Live, and the owner's rule allows only `claude-haiku-5-5` for live runs. The hand-off path is covered by the voice unit tests.
- **Check 2's on-device comparison** of the tapped and typed answers: this is the owner's call.
- **Check 4's manual notification** for a new reply in a followed thread.
- **Check 6's "visible in Files"** for a long thread's saved file.
- **Check 7's Apple Intelligence summaries, live:** neither device here has Apple Intelligence.
- **Check 8 after a relaunch, live:** unit tests only, as above.

## Follow-ups (not small)

1. **meta.appinn.net isn't recognized as a forum on the phone.** The simulator recognizes the same thread. On the iPhone 13, the page loads (its title shows), but the app treats it as an ordinary page ("Summarize this page", "Make it dark"), and `read_page` returns 0 characters. So check 1 runs there without forum tools. Four attempts failed. In three, the request was sent on launch: the Agent crawled with `run_js` and never searched the forum. In the fourth, the thread suggestions didn't appear within 90 s. meta.discourse.org is recognized on the same phone, so the cause is device-, site- or probe-specific.
2. **Short page-change turns are saved when the reply runs long.** Haiku's "Make it dark" replies are usually over 200 characters, so the owner's 200-character rule saves them. The options are a page-change exception to the rule, or a prompt that keeps those replies short. A brevity sentence was tried in this task and did not hold (321 characters), so it was removed.
3. **PRs #66, #67 and #69 don't link the comparison** (check 5). Their descriptions could be edited, with the owner's go-ahead.

## Fixture added

- `WukongMindTests/Fixtures/OneLoopAcceptance/` contains `discourse/` (the forum snapshot), `runs/acceptance-run-A1.json` (the task export) with its summaries, and `model-audit.jsonl`.
  - The run is check 1's request on D3's thread (`https://meta.appinn.net/t/18527`).
  - It is kept outside `Fixtures/Comparison/`, so the comparison's own set list is unchanged.
  - Record it again with `TEST_RUNNER_ONE_LOOP_ACCEPT_RECORD=1` and `TEST_RUNNER_ANTHROPIC_API_KEY` on `OneLoopAcceptanceTests/testRecordMultiStepRun`.

## Running the live checks

- **Simulator:** `TEST_RUNNER_ANTHROPIC_API_KEY=… xcodebuild test-without-building … -only-testing:WukongMindUITests/OneLoopLiveAcceptanceUITests`. Optionally add `TEST_RUNNER_ONE_LOOP_EVIDENCE_DIR=<dir>` to write the evidence files.
- **Phone:** `TEST_RUNNER_ANTHROPIC_API_KEY=… TEST_RUNNER_ONE_LOOP_THREAD=https://meta.discourse.org/t/410209 scripts/device-check.sh test -only-testing:WukongMindUITests/OneLoopLiveAcceptanceUITests`. The evidence is in the `.xcresult` attachments.
