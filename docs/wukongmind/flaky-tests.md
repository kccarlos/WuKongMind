# CI-Quarantined Flaky Tests

These inherited Forumind UI, navigation, and streaming-summary tests are skipped on GitHub Actions CI only (`XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, ...)`, fed by `TEST_RUNNER_CI: ${{ env.CI }}` in `.github/workflows/ci.yml`). They still run locally (`xcodebuild test` without `TEST_RUNNER_CI`).

In addition, `.github/workflows/ci.yml` runs `xcodebuild test` with `-retry-tests-on-failure -test-iterations 3`. This reruns only failed test methods up to 3 times so transient timing spikes on shared 3-vCPU runners (such as `ModerationTests.testBlockedFirstNewPostAndBlockedUserAcceptedPostExcludedFromDigestAndPodcast` in run [`43222503681`](https://github.com/kccarlos/WuKongMind/actions/runs/43222503681), where 1005 of 1006 tests passed) do not fail the run while deterministic regressions still fail all 3 iterations.

## Root Causes Observed on 3-vCPU GitHub Actions Runners

1. **iOS 26.2 Simulator `ScreenTimeCore` cooperative-pool starvation** (mitigated in `ForumBrowserModel.disableWebKitScreenTimeForTesting`):
   - Spindump from CI run `43211047906` showed `Workqueue exceeded cooperative thread limit for 230 samples (more swift tasks runnable than allowed to run concurrently)`.
   - Whenever a `WKWebView` enters a `UIWindow` on iOS 26.2 Simulator, `-[WKWebView _installScreenTimeWebpageControllerIfNeeded]` starts `WKScreenTimeConfigurationObserver` → `STScreenTimeWebBrowserSettingsObserver` (`ScreenTimeCore`), which spawns a Swift Concurrency cooperative-pool task that blocks synchronously in `xpc_connection_send_message_with_reply_sync` waiting on `ScreenTimeSettingsAgent` → `dasd` (`-[BGSystemTaskScheduler submitTaskRequest:error:]`).
   - On a 3-vCPU runner, Swift's cooperative pool has 3 threads; after 3 windowed `WKWebView`s, all 3 cooperative threads block indefinitely and starve `Task.sleep` and actor hops (`WorkConcurrencyLimiter`, `ForumRequestPacer`).
2. **Fixed wall-clock `RunLoop.current.run(until:)` windows in hosted `UIWindow` scroll/layout tests**:
   - Several `LazyMarkdownTests` drive `RunLoop.current.run(until:)` for fixed 10–800 ms windows and assert exact `UIScrollView.contentOffset` or `MarkdownLayoutProbe` counts, which can miss a frame under CI CPU contention.

## Quarantined Tests (`XCTSkipIf` on `CI`)

| Test | Location | CI Run | Failure Mode |
| --- | --- | --- | --- |
| `AIContextValidityTests.testSyncedBlockExcludesPreviousChatAnswerFromNextRequest` | `ForumindTests/StateTransitionTests.swift` | [`43201820224`](https://github.com/kccarlos/WuKongMind/actions/runs/43201820224) | `waitUntil` timed out (`CancellationError`) waiting for second chat turn + sync block under cooperative-pool contention. |
| `HomeTests.testFailedNavigationFromHomePreservesHomeAndPresentsError` | `ForumindTests/HomeTests.swift` | [`43201820224`](https://github.com/kccarlos/WuKongMind/actions/runs/43201820224) | Timed out polling `Task.sleep` after `loadHTMLString` + unreachable `http://127.0.0.1:1/latest` navigation callback on CI simulator. |
| `CommentBridgeReviewTests.testBlockThemeBlockingParentKeepsUnrelatedReply` | `ForumindTests/ModerationTests.swift` | [`43211047906`](https://github.com/kccarlos/WuKongMind/actions/runs/43211047906) | Timed out at 300 s in `load()` `Task.sleep` after the third windowed `WKWebView` saturated the 3-thread cooperative pool. |
| `LazyMarkdownTests.testSendChatOverUniformLazySummaryReachesChatBottom` | `ForumindTests/CoreTests.swift` | [`43201092937`](https://github.com/kccarlos/WuKongMind/actions/runs/43201092937), [`43211047906`](https://github.com/kccarlos/WuKongMind/actions/runs/43211047906) | Fixed `RunLoop.current.run(until: +0.8)` window checked `.running` chat status and `scrollView.contentOffset` before async work / smooth scroll completed on CI. |
| `LazyMarkdownTests.testSummaryRetryOverSavedSummaryDoesNotFlashOldSummaryDuringStream` | `ForumindTests/CoreTests.swift` | [`43201092937`](https://github.com/kccarlos/WuKongMind/actions/runs/43201092937) | Fixed `RunLoop` polling window missed `StreamStore` throttle flush and `MarkdownLayoutProbe` counts under CI load. |
| `LazyMarkdownTests.testStreamingSummaryDragInvalidatesOnlyChangedRowAndLaysOutLazily` | `ForumindTests/CoreTests.swift` | [`43201092937`](https://github.com/kccarlos/WuKongMind/actions/runs/43201092937), [`43220385406`](https://github.com/kccarlos/WuKongMind/actions/runs/43220385406) | Fixed 150 ms `RunLoop` ticks during simulated sheet drag had different `MarkdownLayoutProbe.blockBodies` invalidation counts under CI load. |

## Transient CI Flakes Covered by `-retry-tests-on-failure -test-iterations 3`

| Test | Location | CI Run | Notes |
| --- | --- | --- | --- |
| `ModerationTests.testBlockedFirstNewPostAndBlockedUserAcceptedPostExcludedFromDigestAndPodcast` | `ForumindTests/ModerationTests.swift` | [`43222503681`](https://github.com/kccarlos/WuKongMind/actions/runs/43222503681) | Timed out once (1 of 1006 tests) waiting on digest/podcast pipeline under runner load. |
| `AIContextValidityTests.testBlockWhileSummaryInFlightDoesNotCertifyBlockedOutput` | `ForumindTests/StateTransitionTests.swift` | [`43230702074`](https://github.com/kccarlos/WuKongMind/actions/runs/43230702074) | Failed on attempt 1 (`Timed out waiting for work` / `CancellationError`) and passed on attempt 2. |
| `LazyMarkdownTests.testDiscourseAgentReadTopicSupportsPageAndQueryWithoutRefetching` | `ForumindTests/CoreTests.swift` | [`43230702074`](https://github.com/kccarlos/WuKongMind/actions/runs/43230702074) | Timed out on attempt 1 and previously crashed the test host with `Fatal error: Index out of range` on `planner.transcripts[1]` before `xcodebuild` could retry; guarded `planner.transcripts.count` and stubbed `makeTwoTopicApp`'s default `ForumService`. |
