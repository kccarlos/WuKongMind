# M3 acceptance (1.2.0)

Run for WUKO-41 against [design-m3.md "Acceptance checks"](design-m3.md#acceptance-checks) and the acceptance list of [page-feedback.md](page-feedback.md). Run on 2026-11-13 on the iPhone 18 Pro simulator, with recorded model responses (no network, no API key).

## Result

| # | Check | Result | Where it runs |
|---|---|---|---|
| 1 | Thread crawl (25-page fixture forum) | Passes locally. Live forum on the device: **not run** | `CrawlAcceptanceTests.testCrawlSavesEveryPageSummaryCoversThemAndFilesSurviveARelaunch` |
| 2 | Files survive a kill | Passes locally as a relaunch of the workspace and record store. A real app kill mid-crawl: **not run** | same test |
| 3 | Export replays | Passes | `CrawlAcceptanceTests.testExportedCrawlHasNoSecretsAndReplays`, `testCheckedInCrawlFixtureReplaysThroughRecordedModelClient`, `TaskExportTests` |
| 4 | Saved reader reused on the next thread | **Not proven.** Only a live model can show it chooses to save and reuse the logic; the pieces (`script_save`, saved scripts applying on load) have unit tests (`ScriptStoreWebTests`, `PageFeedbackTests`) | live |
| 5 | Each new tool | `screenshot` hidden for text-only models and `network_log` (`AgentPageCaptureTests`); `navigate` refuses other schemes (`BrowserToolsTests.testNavigateRefusesOtherSchemes`); `http_request` and `cookies_get` confirmations, including `cookies_get` and cross-site `send_cookies` with the switch off (`AgentNetworkToolsTests.testConfirmationMatrixWithTheSwitchOff`, `testCookiesGetMatchesParentDomainsAndAlwaysAsks`). "The Agent describes the test page from a screenshot" and "explains after Don't allow" need a live model: **not run** | unit tests |
| 6 | Page feedback | Empty body warns, a throwing script is refused, 3 error loads auto-disable, a big asked-for change saves with `confirm_change`, replay of the warning and refused-save paths, a no-op adds one line, Undo on the saved card (`PageFeedbackTests`, `ScriptStoreCoreTests`, `ScriptStoreWebTests`). "This page looks broken" row: **not run** here | unit tests |
| 7 | No regressions | Full unit run after the last change: 1,093 tests, 9 skipped, 0 failures; with Confirm before writes on, every `http_request` asks (`testConfirmationWithTheSwitchOnAsksForEveryRequest`) | `-only-testing:WukongMindTests` |

## Fixtures added

- `WukongMindTests/Fixtures/CrawlForum/page-01.html` to `page-25.html`: the 25-page forum, one `CRAWL-MARKER-NN` line each. `FixtureSpaForumServer` serves them at `/crawl/page-NN.html` for UI tests.
- `WukongMindTests/Fixtures/TaskExports/crawl-25-pages.json`: the crawl task as exported by `TaskExport`. It holds no key and no cookie value (checked by the test). Rebuild it with `TEST_RUNNER_TASK_EXPORT_FIXTURE_OUT=<path>` on `testExportedCrawlHasNoSecretsAndReplays`.

## Scope notes

- The crawl test's page driver stands in for WebKit and writes the fixture pages through `AgentWorkspace`; the `wukong.fetch` and `wukong.files` bridge itself is covered by `AgentBridgeTests` and `AgentNetworkToolsTests`.
- The live checks need a real model key and the owner's iPhone (`scripts/device-check.sh`), and are left to the owner's trial.
