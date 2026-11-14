# M3 acceptance (1.2.0)

Run for WUKO-41 against [design-m3.md "Acceptance checks"](design-m3.md#acceptance-checks) and the acceptance list of [page-feedback.md](page-feedback.md). Run on 2026-11-13 on the iPhone 18 Pro simulator, with recorded model responses (no network, no API key).

## Result

Live runs used **claude-haiku-5-5 only** (`-dc-browser-agent-live-model claude-haiku-5-5`); every task record written holds only `"model":"claude-haiku-5-5"`. Simulator: iPhone 18 Pro, a loopback copy of the fixture forum, `-dc-browser-agent-live-prompt`. Device: `scripts/device-check.sh` on the owner's iPhone 13.

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Thread crawl | **Pass.** Live (Haiku): 5 steps, 25 of 25 page files, summary cites all 25 topics. Local: `CrawlAcceptanceTests`, and `AgentBridgeTests.testCrawlOf25FixturePagesThroughWukongFetchAndFilesInRealWebKit` (real WebKit, `wukong.fetch`, `wukong.files`) | result file, workspace listing |
| 2 | Files survive a kill | **Pass.** App killed (`simctl terminate`) mid-crawl at 4 page files; all 4 whole after relaunch; the task is in the audit log and `Tasks/` | simulator container |
| 3 | Export replays | **Pass.** `crawl-25-pages.json` replays; no key or cookie | `CrawlAcceptanceTests`, `TaskExportTests` |
| 4 | Saved reader | **Pass in one conversation.** Live (Haiku): `script_save`, `navigate` to the next thread, `script_read`, `run_js` with its logic, both markers returned. Across an app relaunch it is **not proven**: the live-prompt debug mode starts with no saved scripts, so a second launch found none | live result file |
| 5 | Each new tool | `screenshot`: live (Haiku) described the page's heading and layout correctly. `network_log` listing fetch and XHR, `navigate` refusing `javascript:` and `file:`, `http_request` and `cookies_get` cards, text-only model hides `screenshot`: unit tests (`AgentPageCaptureTests`, `BrowserToolsTests`, `AgentNetworkToolsTests`). **Not run live:** the "Don't allow, then the Agent explains" path (needs tapping the card) and `network_log` on a page that makes requests (the fixture makes none) | unit tests |
| 6 | Page feedback | Unit and replay tests (`PageFeedbackTests`, `ScriptStoreCoreTests`, `ScriptStoreWebTests`) cover every bullet and Undo. **Not run live:** the "This page looks broken" row | unit tests |
| 7 | No regressions | **Pass.** 1,094 unit tests, 9 skipped, 0 failures; with Confirm before writes on, every `http_request` asks | `-only-testing:WukongMindTests` |

**On the owner's iPhone** (`scripts/device-check.sh`, offline subset, 3 tests, 0 failures): `testAssistantPageStatesOffline`, `testManageRowsUseMailStyleSwipeActions`, `ScreenshotThumbnailUITests.testScreenshotThumbnailOpensSheet`. No live-model run was made on the phone.

## Fixtures added

- `WukongMindTests/Fixtures/CrawlForum/page-01.html` to `page-25.html`: the 25-page forum, one `CRAWL-MARKER-NN` line each. `FixtureSpaForumServer` serves them at `/crawl/page-NN.html` for UI tests.
- `WukongMindTests/Fixtures/TaskExports/crawl-25-pages.json`: the crawl task as exported by `TaskExport`. It holds no key and no cookie value (checked by the test). Rebuild it with `TEST_RUNNER_TASK_EXPORT_FIXTURE_OUT=<path>` on `testExportedCrawlHasNoSecretsAndReplays`.

## Scope notes

- The `CrawlAcceptanceTests` page driver stands in for WebKit; the WebKit test next to it covers the real `wukong.fetch` and `wukong.files` path.
- Still needing a live model or a tap: check 5's Don't-allow explanation and `network_log` on a requesting page, check 6's "looks broken" row, and check 4 across a relaunch.
