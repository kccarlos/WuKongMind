# M3 acceptance (1.2.0)

Run for WUKO-41 against [design-m3.md "Acceptance checks"](design-m3.md#acceptance-checks) and the acceptance list of [page-feedback.md](page-feedback.md). Run on 2026-11-13 on the iPhone 18 Pro simulator, with recorded model responses (no network, no API key).

## Result

Live runs used **claude-haiku-5-5 only** (`-dc-browser-agent-live-model claude-haiku-5-5`). `m3-acceptance/model-evidence.txt` counts the `"model"` values in the nine newest task records of the session: all `claude-haiku-5-5`, nothing else. Evidence files are in [`m3-acceptance/`](m3-acceptance/) (names below are relative to it; no key or cookie in any of them). Simulator: iPhone 18 Pro, the fixture forum served on loopback. Device: `scripts/device-check.sh` on the owner's iPhone 13.

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Thread crawl | **Pass.** Live (Haiku): 8 steps, 25 page files plus `thread.md` and `notes.md`, summary covers every page. Local: `CrawlAcceptanceTests`; `AgentBridgeTests.testCrawlOf25FixturePagesThroughWukongFetchAndFilesInRealWebKit` (real WebKit, `wukong.fetch`, `wukong.files`) | `check1-crawl.json`, `check1-workspace-listing.txt` (27 files) |
| 2 | Files survive a kill | **Pass.** App killed (`simctl terminate`) mid-crawl at 4 page files; all 4 whole after relaunch; the task is in the audit log (5 `m3-kill` lines) | `check2-listing-at-kill.txt`, `check2-listing-after-relaunch.txt`, `check2-killed-at.txt` |
| 3 | Export replays | **Pass.** `crawl-25-pages.json` replays through `RecordedModelClient`; no key or cookie | `CrawlAcceptanceTests`, `TaskExportTests` |
| 4 | Saved reader | **Pass, across a relaunch.** Launch 1 (Haiku): `script_save`. The app is terminated; the scripts folder still holds the script. Launch 2 (a new process, same scripts folder, the next thread): `script_list`, `script_read`, `run_js` with its logic, marker returned | `check4-launch1-save.json`, `check4-listing-before-relaunch.txt`, `check4-launch2-reuse.json`, `check4-listing-after-relaunch.txt`, `saved-reader-scripts/` |
| 5 | Each new tool | `screenshot`: live (Haiku) described the page correctly. `network_log`: live, on `net.html` (a page doing `fetch` and XHR), it returned 2 requests. `cookies_get` card, then **Don't allow**, then the Agent explains: live UI test `M3LiveAcceptanceUITests.testLiveDontAllowThenTheAgentExplains` passes (reply: "the request was declined … the confirmation was refused"). `navigate` refusing `javascript:` and `file:`, `http_request` cards with the switch on and off, text-only model hides `screenshot`: unit tests (`BrowserToolsTests`, `AgentNetworkToolsTests`, `AgentPageCaptureTests`) | `check5-screenshot-network-log.json`, `dont-allow-card-question.txt`, `dont-allow-reply.txt` |
| 6 | Page feedback | Unit and replay tests (`PageFeedbackTests`, `ScriptStoreCoreTests`, `ScriptStoreWebTests`) cover every bullet and Undo. "This page looks broken" on a page with an active script: live UI test `M3LiveAcceptanceUITests.testLiveThisPageLooksBrokenRow` shows the row, taps it, and the Agent finishes (Haiku) | `looks-broken-row.txt`, `looks-broken-reply.txt` |
| 7 | No regressions | **Pass.** Full unit run: see the count in the final proof; with Confirm before writes on, every `http_request` asks | `-only-testing:WukongMindTests` |

Note on check 5: `http_request` asks only with Confirm before writes on (the default is off), so the live card test uses `cookies_get`, which always asks. A first attempt with a POST ran without a card for that reason.

**On the owner's iPhone** (`scripts/device-check.sh`, 3 tests, 0 failures; output in `device-check-output.txt`): `testAssistantPageStatesOffline`, `testManageRowsUseMailStyleSwipeActions`, `ScreenshotThumbnailUITests.testScreenshotThumbnailOpensSheet`. These are offline UI tests. No live-model run was made on the phone: the fixture forum is served from the Mac, which the phone can't reach, so the live checks ran on the simulator.

**Gaps:** none of the seven checks has an open gap except the live model on the phone itself, which the owner may accept on the `v1.2.0` approval card.

## Fixtures added

- `WukongMindTests/Fixtures/CrawlForum/page-01.html` to `page-25.html`: the 25-page forum, one `CRAWL-MARKER-NN` line each. `FixtureSpaForumServer` serves them at `/crawl/page-NN.html` for UI tests.
- `WukongMindTests/Fixtures/TaskExports/crawl-25-pages.json`: the crawl task as exported by `TaskExport`. It holds no key and no cookie value (checked by the test). Rebuild it with `TEST_RUNNER_TASK_EXPORT_FIXTURE_OUT=<path>` on `testExportedCrawlHasNoSecretsAndReplays`.

## Scope notes

- The `CrawlAcceptanceTests` page driver stands in for WebKit; the WebKit test next to it covers the real `wukong.fetch` and `wukong.files` path.
- `M3LiveAcceptanceUITests` skip without `TEST_RUNNER_ANTHROPIC_API_KEY` and need the fixture forum on `127.0.0.1:8765`.
- `net.html` in the fixture forum is the fetch and XHR page for `network_log`.
