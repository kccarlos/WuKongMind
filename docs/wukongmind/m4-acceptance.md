# M4 acceptance (1.4.0)

Run on 2026-11-15 for WUKO-98 against the twelve checks in [design-m4.md "Acceptance checks"](design-m4.md#acceptance-checks). `marketing_version` is `1.4.0`, `WukongMind.xcodeproj` is regenerated and the [README](README.md#versions-and-releases) table is updated. **No tag was created**: `v1.4.0` waits for the owner's approval card.

**Two things the owner must know before tagging:**

- **Script sync ships switched off and was not tested on two devices.** It is built and unit-tested on the engine's test transport (check 10), behind the existing CloudKit flag. CloudKit stays off until the owner registers the iCloud container; the two-device check runs then ([open question 4](design-m4.md#open-questions)).
- **Check 6 was not run against two real Greasy Fork scripts.** Greasy Fork refused automated requests from this machine. Import, `@require`, review-before-run, update and export are proven on fixture scripts that use Tampermonkey headers (below).

**Environments:** simulator = iPhone 18 Pro on the Mac mini via `scripts/remote-test.sh`; phone = the owner's iPhone via `scripts/device-check.sh` only.

**Live models:** Anthropic `claude-haiku-5-5` only; Google `gemini-3.8-flash` on Vertex AI with `VERTEX_API_KEY` (Vertex worked, AI Studio was not needed).

## Result

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | `GM_ai` folds empty posts; reload uses cache only | **Pass, live on both models.** Haiku: `GMAiAgentScriptTests.testLiveHaikuGMAiScriptFolding` (simulator and iPhone). Vertex: `testLiveVertexGeminiGMAiScriptFolding` (simulator; the script is the recorded Haiku one, `GM_ai` answered live by `gemini-3.8-flash`, 1 batched call, 0 on reload). Replay: `testRecordedGMAiScriptFoldsEmptyPostsAndReloadUsesCacheOnly`. Cache and limits: `GMAiTests`. | proof artifact |
| 2 | Model down: nothing folded, script stays on | **Pass (tests).** `GMAiTests.testAllSevenErrorCodesRejectWithGMAiErrorAndNeverDisableScript`, `ScriptRepairTests.testErrorKindsStackClampingLastFiveHistoryAndServiceNeverAutoDisables`, `GMAiAgentScriptTests.testVerificationCatchesErrorsThrownAfterGMAiAnswerAndAllowsServiceFailure`. A live run met one genuine provider 503; the script logged a `service` error and stayed on. | proof artifact |
| 3 | Core four under each CSP | **Pass (tests).** `GMBridgeTests.testDocumentStartSyncReadAcrossAllSevenM0CSPVariantsAnd256KBCeiling`, `testValueLifecycleSizeLimitsAndDeleteUndoRestore`. | |
| 4 | Requests are fenced | **Pass (tests).** `GMRequestTests.testConnectFencingInitialAndRedirectHopsAndDefaultSelf`, `testWildcardConnectRefusesLocalhostAndAllPrivateAddressesOnEveryHopUnlessNamed`, `testSameSiteCookiesCrossSiteDropSetCookieStripAndConfirmBeforeWrites`, `testWKWebViewGMXmlhttpRequestCallbacksAbortUnsupportedOptionsAndAuditLog`. | |
| 5 | Powers can't be borrowed | **Pass (tests, real `WKWebView`).** `GMBridgeTests.testCrossWorldIsolationPreventsHandlerValueAndErrorSpoofing`. | |
| 6 | Import | **Partly proven.** Fixture scripts, including `@require` and `@grant GM_*` values: `ScriptImportTests.testImportWithRequireAndGMValuesNeverRunsBeforeConfirmThenRunsInOwnWorld`, `ScriptImportUITests.testImportFromLinkMenuAndReviewConfirmFlows` (pasted link and link tap, nothing runs before **Add and turn on**), `ScriptStoreCoreTests.testPublishedHeaderExportsWithEveryHeaderLine`. Real Greasy Fork scripts: **not run** (see above). | screenshots |
| 7 | Update | **Pass (tests).** `ScriptImportTests.testUpdateCheckDiffConfirmHistoryRollbackAndDuplicateNameIsolation`, `testUpdateChecksUseOnlyHTTPSUpdateLinks`; sheet screenshots in light and dark. | screenshots |
| 8 | Repair | **Pass.** Recorded: `ScriptRepairTests.testBrokenScriptAutoDisablesRepairsViaRecordedReplayUndoesAndStopsAfterThreeFailedFixes`. Live: `testLiveHaikuScriptRepair` with `claude-haiku-5-5` passed on the simulator. | |
| 9 | Late error is seen | **Pass (tests).** `ScriptRepairTests.testLateErrorsInScriptWorldCaptureHandlersTimersObserversRejectionsAndIsolatePageNoise`. | |
| 10 | Sync | **Pass on the test transport only.** `ScriptSyncTests` (eight tests). Not run on two devices. | |
| 11 | Old scripts untouched | **Pass (tests).** `ScriptStoreCoreTests.testFilesWrittenBy13DecodeWithTheSameRevisionAndExportOneNewLine`, `testNewHeaderValuesDecodeFromOlderJSON`. | |
| 12 | No regressions | **Pass.** `WukongMindTests` on the simulator: 1252 tests, 19 skipped, 0 failures. `check-project-drift.sh` and `REF_TYPE=tag REF_NAME=v1.4.0 check-release-version.sh` pass. | |

## iPhone

`scripts/device-check.sh` ran `testLiveHaikuGMAiScriptFolding` (check 1, Haiku) and `PhysicalDeviceSmokeTests.testLiveBrowserAgentDarkAndHideSidebar` on the owner's iPhone: both passed. The Vertex run and the recorded replay need the fixture file on disk, which a device build does not have, so they ran on the simulator only.

## Fixed in this task

- Added `testLiveVertexGeminiGMAiScriptFolding` so check 1 can run live on a Vertex Gemini model.
- The live Haiku test prints a `GMAI_LIVE_ERROR` line (provider, model, error; never a key) when a `GM_ai` call fails, which showed the first failure was a provider 503.

## Not proven

- Two real Greasy Fork scripts running on a real matching page (check 6).
- Script sync on two real devices (check 10); CloudKit is off.
- Vertex Gemini on the iPhone.
