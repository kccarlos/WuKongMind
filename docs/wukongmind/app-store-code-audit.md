# App Store code compliance audit (WUKO-168)

A sweep of the whole app, the share extension, the scripts and the build settings for anything that bypasses Apple's rules, uses non-public API, or behaves differently for App Review than for users (guidelines 2.5.1, 2.5.2, 2.5.4, 2.5.19, 2.3.1, 4.7, 5.6). No app code changed; one check script was added (`scripts/audit-release-binary.sh`). The guideline-by-guideline review is [app-store-review.md](app-store-review.md); this page is its code audit.

- **Code state:** `main` at `6c4f66c` (version 1.5.4), 216 Swift files, 101,479 lines in `WukongMind/` and `WukongMindShare/`. Every `file:line` below was checked against that commit.
- **Method:** every pattern in section 4 was searched over all tracked sources, not sampled. Each hit was classified by the `#if` blocks around it with a small parser, then the Release build was checked for what must not be in it (section 5).
- **Levels:** **blocker** (will be rejected), **likely** (a reviewer who looks will reject), **question** (expect a question; a note or a small change settles it), **fine**.
- **Frame:** the owner's decisions of 2026-11-19 ([requirements.md](requirements.md), section 12): one build, no store flag; what the store needs becomes a visible Settings switch with the safe side as the default.

## 1. Summary

**No blocker. The Release binary uses no non-public API, and nothing in the app opens it from the share extension, loads remote configuration, hides a feature behind a gesture, or reads a launch argument.** Forumind's share-extension trick is gone: the extension only writes a request into the App Group and the app picks it up when it is next opened.

What is left is of two kinds:

- **Four "likely" findings.** Three are the Agent acting without the user seeing it (saving code, changing saved code, reading cookie values); the owner's decisions already cover them and tasks 1 and 4 of the review carry them. The fourth is new: one default that depends on where the app was installed from (finding 4), which the one-build decision rules out.
- **Nine "question" findings**: things to change in a small way or to say plainly in the review notes.

The only private API in the repository is a DEBUG-only test helper (finding 14). The Release build was checked and does not contain it.

## 2. Findings

"In Release?" says whether the code is in the Release binary; "DEBUG only" was verified by the binary check in section 5, not only by reading the `#if`.

| # | Where | What it does | Guideline | Level | In Release? | Fix that keeps the feature |
|---|---|---|---|---|---|---|
| 1 | `WukongMind/ToolRegistry.swift:1624`, `:1742` | `script_save`: the Agent stores JavaScript it wrote as a script that is on at once (`isEnabled: true`) and runs again on every matching page. The user sees a card afterwards, not the code beforehand. Learn on ask readers are saved the same way. | 2.5.2, 4.7 | likely | Yes | Show the import review sheet (source, where it runs, what it can do) and save only after the user agrees. A visible setting, off by default, lets the Agent save without asking. Review task 4. |
| 2 | `WukongMind/ToolRegistry.swift:1973`, `:2034`, `:2116` | `script_update` can change the code, the sites, the world (`page`), the grants and the allowed hosts of any saved script, and turn it on. Neither the tool nor the store method it calls (`WukongMind/ScriptStore.swift:2425`, which keeps `source: existing.source` at `:2494`) looks at where the script came from, so it can rewrite a script the user imported and reviewed. No approval step. | 2.5.2, 1.6 | likely | Yes | The same sheet as finding 1, as a diff, whenever an update changes code, sites, grants or hosts, or turns a script on. Add to review task 4. |
| 3 | `WukongMind/ToolRegistry+Network.swift:184`, `:212`, `:214` | `cookies_get` gives cookie values, HttpOnly included, to the model after one confirmation card. A session cookie then sits in a third party's logs. | 1.6, 5.1.1 | likely | Yes | Names and attributes only by default; a visible setting, off by default, adds the values. Review task 1. |
| 4 | `WukongMind/FeedbackReports.swift:168-175`, `WukongMind/Models.swift:126`, `:332-333` | `BuildChannel.isTestFlight` reads the receipt file name (`sandboxReceipt`) and looks for a provisioning profile. Until the user touches the switch, "Save failed tasks for feedback" is on for a TestFlight install and off for any other. The switch is visible (`WukongMind/SettingsAssistantPages.swift:290`), but its default depends on the install source. | 2.3.1, 5.6 | likely | Yes (`BuildChannel` symbols and the `appStoreReceiptURL` selector are in the binary) | One default for every install (off), keep the visible switch, delete `BuildChannel`. Audit task B. |
| 5 | `WukongMind/ToolRegistry.swift:1206`, `:1347`; `WukongMind/Models.swift:118`; `WukongMind/SettingsAssistantPages.swift:235-240`; `WukongMind/ToolRegistry+Network.swift:42` | `run_js` and `inject_css` run model-written code in the open page with no question; the user sees a tool row with the code. "Confirm before writes" is off by default. When on it asks before `http_request` (line 42), limits requests from scripts and `wukong.fetch` to same-site reads (`WukongMind/AgentNetworkTools.swift:397`, `:545`) and asks before a saved script's page tool that is not read-only (`WukongMind/ToolRegistry+PageTools.swift:269`). It does not cover `run_js` changing the page, and its footer speaks only of network requests. `http_request` to any host runs without a card while it is off. | 2.5.2, 4.7 | question | Yes | Default on (review task 1). Keep `run_js` unprompted: it is the product, it runs only in WebKit on the page the user is looking at, and the row shows the code. Rename the switch or widen it so the label matches what it asks about. |
| 6 | `WukongMind/ToolRegistry+Capabilities.swift:283`, `:300` | The Agent's `notify` tool posts a local notification with any title and text, and asks for notification permission if it was never asked. No card. A page that steers the Agent could word a notification. | 4.5.4 | question | Yes | Put `notify` under "Confirm before writes", and never let the tool raise the permission prompt on its own: the user turns notifications on in Settings. Add to review task 4. |
| 7 | `WukongMind/SettingsAssistantPages.swift:638`, `WukongMind/SiteInspectorViews.swift:341` | Opens the Files app at the app's folder with `shareddocuments://`, a URL scheme of Apple's that is not documented. It is a string, not private API, so no scan flags it, but it is an unsupported way to open another app. | 2.5.1 | question | Yes | `UIDocumentPickerViewController` (or SwiftUI `fileImporter`) opened at that folder, or a plain line "Files › On My iPhone › WukongMind". Audit task D. |
| 8 | `WukongMind/LinkPolicy.swift:118-129`, `WukongMind/ForumBrowser.swift:645` | Every web view sends Safari's exact user agent for the OS (the iPad sends the Macintosh one, as Safari does), with no app name in it. Public API (`customUserAgent`). The comment says why: sites otherwise treat the web view as an in-app browser. | 2.5.6, 2.5.9 | question | Yes | Keep. Browsers on the store do this. Say it in the review notes so it is not found as a surprise. Review task 8. |
| 9 | `WukongMind/Voice/VoiceAudioEngine.swift:256`; `WukongMind/AppModel.swift:2587-2600` | Live voice holds a play-and-record audio session, and nothing ends it when the app goes to the background (the scene-phase handler pauses the digest, podcast generation and queued work, not voice; no file in `Voice/` watches the scene phase). So the microphone and the Gemini connection stay open in the background until the idle or session limit. Real audio, not a keep-alive trick, but the user did not clearly ask for it. | 2.5.4, 2.5.14 | question | Yes | Decide: end the session when the app leaves the foreground, or keep it as a "call" with the Now Playing entry and say so in the notes. Review task 7 already asks. |
| 10 | `WukongMind/Info.plist:82`; `WukongMind/WukongMindApp.swift:46` | The `remote-notification` background mode is always declared, but the app registers for remote notifications only when built with CloudKit. The TestFlight build has CloudKit on (`.github/workflows/release.yml:47` and the repository variable), so there the mode is used. | 2.5.4 | question (fine in the shipped build) | Yes | Declare the mode only when CloudKit is on. Review task 7. |
| 11 | `WukongMind/ScriptImport.swift:144`, `:425`, `:428`, `:557`; `WukongMind/ScriptImportViews.swift:444`, `:452`; `WukongMind/ScriptStore.swift:904`; `WukongMind/GMBridge.swift:166-170` | Imported user scripts: a `.user.js` link opens a review sheet with the full source; nothing is stored until the user taps "Add and turn on" or "Add, keep off". Libraries (`@require`) are downloaded over HTTPS and their hashes pinned. The daily update check only shows "update available". Scripts can be granted web requests to listed hosts (`*` allowed, shown as "any site") and `GM_ai`. Notifications, clipboard, downloads, cookies and opening tabs are refused. | 2.5.2, 4.7 | question | Yes | Nothing to change. This is downloaded code and must be described in the notes exactly as it works (the review's draft notes do). |
| 12 | `WukongMind/Voice/LiveBudget.swift:38-44` | A test hook that is compiled into Release: the `GEMINI_LIVE_BUDGET` environment variable, or a loaded XCTest, caps live voice connections. A user cannot set an environment variable on iOS, and the hook can only lower a limit. | 2.5.19 | question (low) | Yes (`GEMINI_LIVE_BUDGET` is in the binary's strings) | Put the hook under `#if DEBUG`. Audit task E. |
| 13 | `WukongMind/IncomingLink.swift:42-44` | A comment says "the share extension both enqueues a request and opens this URL". The extension no longer opens anything, but the repository is public and the sentence describes Forumind's rejected trick as if it were still there. | 5.6 | question (low) | Comment only | Correct the comment. Audit task E. |
| 14 | `WukongMind/ForumBrowser.swift:1826-1878` (used at `:613`) | For tests: replaces WebKit's Screen Time methods by name through the Objective-C runtime (six selectors on four classes, among them `_installScreenTimeWebpageControllerIfNeeded` and the private class `STScreenTimeWebBrowserSettingsObserver`), and in the simulator loads a private framework with `dlopen`. | 2.5.1 | fine | **No: DEBUG only**, verified in the binary | Keep. Never upload a Debug build; audit task C makes CI check that. |
| 15 | `WukongMind/BrowserTabsOverview.swift:1453` | `target.perform(action.selector, with:)` on an accessibility action (a public selector), in a helper that only tests and a DEBUG overlay call. The source is not under `#if DEBUG`. | 2.5.1 | fine | No (the optimizer drops it: `performSelector` is not among the selectors the Release binary sends) | Move the helper under `#if DEBUG`. Audit task E. |

## 3. Code execution: what runs, where, and what the user sees

All of it is JavaScript in WebKit. There is no JavaScriptCore, no other interpreter, no native code loaded at run time, and nothing downloaded changes the app's own screens or features.

| Code | Written by | Runs in | The user sees | Stored |
|---|---|---|---|---|
| The app's own bridges (page probe, Agent bridge, browse bridge, page tools, feedback) | The app (string literals in the binary) | The page world or an isolated `WKContentWorld` | Nothing (part of the app) | No |
| `run_js`, `inject_css` (`WukongMind/ToolRegistry.swift:1206`, `:1347`) | The model, during a task the user started | The open page; isolated world by default, the page world on request | A tool row with the code | No |
| `wukong.fetch`, `wukong.files` inside `run_js` (`WukongMind/AgentBridge.swift:962`, `:980`) | The model | Native helpers reached from the isolated world only: the app's HTTP client, and files in the app's own Documents folder | The tool row; the files show in Files | Files only |
| Agent-saved scripts and Learn on ask readers (`script_save`, `script_update`) | The model | Every matching page load, isolated world by default | A card after saving; Settings › Scripts lists, shows, turns off and deletes each one | Yes (findings 1 and 2) |
| Imported user scripts and their `@require` libraries | Downloaded from a link the user opened | Isolated world always (`WukongMind/ScriptImport.swift:425`), off until the user chooses | The full source and what it can do, before anything is stored | Yes (finding 11) |
| Share extension probe (`WukongMindShare/PageFactsProbe.js`) | The app (generated from the recognizers by `scripts/generate-share-probe.sh`) | Safari, as the extension's JavaScript preprocessing file | Nothing | No |

Native abilities the model can reach: the web view, `http_request` (cookies to another site always ask), `cookies_get` (always asks; finding 3), files in the app's Documents folder, local notifications (finding 6). No tool reaches the Keychain, the clipboard or Settings, and no tool opens another app; a link the Agent clicks in a page goes through the same link policy as a user's tap (`WukongMind/LinkPolicy.swift:88-97`), which was not traced for Agent clicks (section 7).

## 4. Checked and found clean

Searched over `WukongMind/`, `WukongMindShare/`, `scripts/`, `fastlane/`, `.github/` and the project file. "DEBUG only" means every hit is inside `#if DEBUG`.

| What | Pattern | Result |
|---|---|---|
| Selectors built from strings | `NSSelectorFromString`, `Selector("`, `performSelector`, `.perform(` | 3 `NSSelectorFromString`, DEBUG only (finding 14); one `perform` (finding 15); the rest are the app's own Swift methods named `perform`. Every `#selector` names a public UIKit method or the app's own. |
| Key-value access to system objects | `value(forKey`, `setValue(`, `forKeyPath` | None. All `setValue` hits are HTTP header fields or the app's script storage. |
| Runtime tricks | `dlopen`, `dlsym`, `objc_`, `class_getInstanceMethod`, `method_setImplementation`, `method_exchangeImplementations`, `class_addMethod`, `imp_implementationWithBlock`, `unsafeBitCast`, `@_silgen_name`, `@_spi`, `@objc(_` | DEBUG only (finding 14). No `@_spi`, `@_silgen_name` or `unsafeBitCast` anywhere. |
| Private classes | `NSClassFromString` | Two private class names, DEBUG only (finding 14). `"XCTestCase"` at `WukongMind/Voice/LiveBudget.swift:43` in Release: a test-framework class, not a system one (finding 12). |
| Private frameworks and imports | every `import`; `otool -L` on the binary | 27 modules, all public. No private framework linked. |
| Private web view settings | `WKPreferences`, `.preferences.`, `_`-prefixed keys, `developerExtras`, file-access keys | Public properties only (`WukongMind/ForumBrowser.swift:605-610`: JavaScript on, no automatic pop-ups, element full screen). The Agent turns pop-ups on for the length of one call (`WukongMind/AgentBridge.swift:655`), a public property. |
| Private entitlements | `*.entitlements`, `scripts/generate_project.rb` | App Group, iCloud and push only. `com.apple.developer.private-cloud-compute` (`scripts/generate_project.rb:175`) is an entitlement Apple grants on request; it is off in the release variables. |
| Extension opens its app | `openURL`, `UIApplication`, `extensionContext.open`, `responder`, `NSSelectorFromString` in `WukongMindShare/` and `WukongMind/SharedPage.swift` | None. The extension enqueues the request and completes (`WukongMindShare/ShareViewController.swift:40-54`); the app reads the inbox when it becomes active. The extension target builds with `APPLICATION_EXTENSION_API_ONLY`. The share extension is off in the current TestFlight build. |
| Custom URL scheme | `wukongmind://` (`WukongMind/Info.plist:33`), `onOpenURL`, `handleDeepLink` | One command, `open`, with `action=open|summary|chat|agent`. A link from outside only opens the page and the Assistant; AI work starts only when the share extension queued the same request (`WukongMind/AppModel.swift:1086-1091`). No debug commands; a link cannot install a script or change a setting. |
| Opening other apps | `UIApplication.shared.open`, `canOpenURL`, `App-prefs:`, `prefs:`, `itms-` | Only: links the user tapped (`mailto`, `tel`, `sms`, FaceTime), an app's link after an "Open" prompt, "Open in app" with `universalLinksOnly`, the app's own Settings page (`openSettingsURLString`), and finding 7. No `canOpenURL`, no private Settings URLs. |
| Universal Links | `WukongMind/LinkPolicy.swift:80`, `WukongMind/ForumBrowser.swift:1611` | A tapped link is reloaded in the web view so the site's app does not take it, unless the visible setting "Open links in apps" is on (`WukongMind/Models.swift:141`, per-site override). Public API; what browsers do. |
| Clipboard reads | `UIPasteboard`, `PasteButton` | One read: the "Summarize link" Shortcut when it is given no link (`WukongMind/System/SystemEntry.swift:55`, `:81`); iOS shows its paste prompt. Nothing at launch. All other uses are writes from a Copy button. |
| Background modes | `UIBackgroundModes` (`WukongMind/Info.plist:77`), `AVAudioSession`, `beginBackgroundTask`, `BGTaskScheduler`, `numberOfLoops`, zero volume, `isIdleTimerDisabled`, location, VoIP, background `URLSession` | `audio`: podcast and read aloud (`WukongMind/Podcast/PodcastPlayer.swift:610`) and live voice (finding 9). `fetch`: watched topics, 30 minutes at least (`WukongMind/WatchSupport.swift:160`). `processing`: the digest, on power (`WukongMind/DailyDigest.swift:433`). `remote-notification`: finding 10. No silent audio, no looping player, no chained background tasks; the two `beginBackgroundTask` uses are single grace periods (`WukongMind/AppModel.swift:4190`, `WukongMind/CloudSyncController.swift:757`). A running Agent task has no background path of its own. |
| Notifications | `UNUserNotificationCenter` | Local only: new replies in a watched topic, digest ready, and the Agent's `notify` (finding 6). No marketing. |
| Hidden gestures | `onTapGesture(count`, `numberOfTapsRequired`, `onLongPressGesture`, `LongPressGesture`, `motionEnded` | No shake, no multi-tap unlock. One double tap, on the iPad split divider (`WukongMind/WorkspaceLayout.swift:143`). Three long presses, each a shortcut to something also reachable by a visible control: dictate instead of talk (`WukongMind/AskBox.swift:228`), start voice from the AI button (`WukongMind/PhoneBrowserBar.swift:1887`), use a favourite model for both roles (`WukongMind/SettingsProviderPage.swift:361`). |
| Hidden settings | every field of the settings struct (`WukongMind/Models.swift:86`, 45 fields) against the view files | 43 field names appear in a Settings or other view; the other two are the provider entries and added model names, edited in Settings › AI models. (A name match, not a proof of a control for each; a helper pass that read the views found none without one.) Developer mode is a visible switch (`WukongMind/SettingsAssistantPages.swift:276`, default off, `WukongMind/Models.swift:123`); it shows raw requests and counts and unlocks no feature. |
| Reviewer, region or date detection | `appStoreReceiptURL`, `sandboxReceipt`, `mobileprovision`, `TestFlight`, `Locale…region`, `storefront`, hard-coded dates and years, `jailb` | One: finding 4. The only region use picks a podcast voice. No date gates. |
| Launch arguments in Release | `"-dc-…"`, `"-ui-test-…"`, `ProcessInfo.processInfo.arguments`, `CommandLine` | 92 literals, DEBUG only. The helpers that read them (`AssistantDebug`, `OnboardingDebug`: `WukongMind/AppModel+Assistant.swift:315`, `WukongMind/AppModel+Onboarding.swift:367`) are DEBUG only. Release reads the process environment in one place (finding 12). |
| Remote configuration and remote lists | every `http(s)://` literal; `URLSession` users | No configuration, flag, prompt or list is fetched. Network calls go to: the AI provider the user set up (chat and its model list), the sites the user opens, script links the user imports, Hacker News' public search API for that site's adapter, and CloudKit. Filter lists are bundled; a weekly CI job proposes new ones as a pull request (`.github/workflows/update-filter-lists.yml:64`), so they change only with an app release. |
| Other interpreters | `JavaScriptCore`, `JSContext`, `NSExpression`, `NSPredicate(format`, `WebAssembly`, `Process(`, `Bundle(path` | None. |
| TLS | `NSAppTransportSecurity` (`WukongMind/Info.plist:53`), challenge delegates, `serverTrust` | Only `NSAllowsLocalNetworking` (for Ollama and LM Studio on the local network). No delegate accepts a bad certificate. |
| Automation hiding | `webdriver`, `navigator.` overrides, fingerprint, paywall, captcha | None beyond finding 8. Captcha hosts are only excluded from ad blocking. The app replays the web view's own cookies for the same site in its requests (`WukongMind/ForumBrowser.swift:1096`), through the public cookie store. |
| Share extension data | `WukongMindShare/PageFactsProbe.js:12` | Reads the page address, title, a few meta tags and, on Discourse, the signed-in username, to recognize the site. It goes to the extension only and is not sent anywhere. |
| Build settings | `project.pbxproj`, `scripts/generate_project.rb`, `.github/workflows/release.yml` | `DEBUG` is defined for the Debug configuration only. The release archives the Release configuration (`.github/workflows/release.yml:276`). No extra linker flags or frameworks. |
| Scripts, CI and fastlane | `scripts/`, `.github/workflows/`, `fastlane/Fastfile` | The release archives the app, exports it with Xcode (which re-signs it for distribution) and uploads it; no step of the workflow or of `scripts/ci/` edits the app or its binary. fastlane only uploads to TestFlight. |

## 5. The Release binary check

`scripts/audit-release-binary.sh <WukongMind.app> [more bundles]` reads a built app and fails if it finds what only DEBUG code may contain. Run on 2026-11-19 on Release builds of `6c4f66c` for a generic iOS device, unsigned, built on the Mac mini:

| Build | Result |
|---|---|
| Release, default flags (through `scripts/remote-test.sh build -configuration Release -destination generic/platform=iOS`) | clean |
| Release with `DC_ENABLE_CLOUDKIT=YES DC_ENABLE_SHARE_EXTENSION=YES`, app and share extension. A superset of the TestFlight build, which sets CloudKit only | clean, both binaries |
| Control: the Debug build's `WukongMind.debug.dylib` | **FAIL**, as it must: 5 private names, 4 runtime imports, `performSelector`, the `arguments` selector, 188 DEBUG-only symbols, 91 of 92 launch-argument literals |

What "clean" means, for the app binary (36 MB, 472,442 strings, 93,450 symbols, 611 Objective-C selectors sent):

- No library linked from outside `/System/Library/Frameworks` and `/usr/lib`; nothing from `PrivateFrameworks`.
- None of the private names of finding 14 in its strings.
- No import of `dlopen`, `NSSelectorFromString`, `class_getInstanceMethod`, `method_setImplementation`, `method_exchangeImplementations`, `class_addMethod`, `class_replaceMethod` or `imp_implementationWithBlock`.
- `dlsym` is imported, with ten calls, all inside `__initializeAvailabilityCheck`: the compiler's own support for `#available`, present in every app.
- No selector sent starts with an underscore; no `performSelector`, `valueForKey` or `setValue:forKey:`.
- The `arguments` selector is never sent, so the binary does not read its launch arguments at all.
- No DEBUG-only symbol (`AssistantDebug`, `OnboardingDebug`, the swizzle, `VoiceDebug`, the tab debug overlay).
- None of the 92 launch-argument literals in its strings. Swift keeps literals of 15 bytes or fewer inside the code where `strings` cannot see them, so this line proves the 62 longer ones; the 30 short ones are covered by the two lines above.

The second build could not go through `scripts/remote-test.sh`, which passes no `DC_*` flags to the project generator; it was run by hand over SSH in the same copy on the Mac mini, and its build folder was removed afterwards.

## 6. Follow-up tasks

Findings 1, 2, 3, 5 and 6 belong to tasks 1 and 4 of [app-store-review.md](app-store-review.md), and findings 8, 9 and 10 to its tasks 7 and 8; those tasks were updated for them. The tasks below are new. Sizes: XS under 50 changed lines, S under 150, M under 400.

### Audit task B: one default for every install

- **Why:** finding 4. Under the one-build decision nothing may depend on where the app was installed from, and a check of the receipt is exactly what a reviewer reads as "behaves differently in review".
- **Scope:** `saveFailedTasksForFeedback` becomes a plain `Bool`, off by default, with the same visible switch; delete `BuildChannel`; keep an existing stored choice. Update docs/wukongmind/feedback.md (testers turn the switch on once).
- **Size:** S.
- **Done when:** no `appStoreReceiptURL`, `sandboxReceipt` or `mobileprovision` in the sources; a unit test for the default and for a stored choice; the binary check lists no `BuildChannel` symbol.

### Audit task C: check the Release binary in CI

- **Why:** findings 14 and 15 are safe only while they stay out of Release. Today that rests on `#if DEBUG` being placed right every time.
- **Scope:** run `scripts/audit-release-binary.sh` on the app the `release-build` job already builds (`.github/workflows/ci.yml:213`); add the `BuildChannel` check from task B. Document it in docs/CI.md. The selector and symbol checks need the binary's local symbols, which that job's product has and an archived, stripped app does not; the script refuses a stripped binary rather than pass it.
- **Size:** S.
- **Done when:** the CI job fails on a branch that moves the swizzle out of `#if DEBUG` (shown once in the pull request), and passes on main.

### Audit task D: open the Files folder with public API

- **Why:** finding 7.
- **Scope:** replace both `shareddocuments://` links with a document picker opened at the folder, or with a line of text naming the place in Files if the picker reads poorly. No other use of the scheme.
- **Size:** S.
- **Done when:** `shareddocuments` is not in the sources or the binary's strings; a UI test opens the Workspace row and finds the picker or the text.

### Audit task E: tidy-ups

- **Why:** findings 12, 13 and 15: a test hook compiled into Release, a comment that describes the old trick, and a test helper outside `#if DEBUG`.
- **Scope:** `LiveBudget`'s environment and XCTest checks under `#if DEBUG` (tests run Debug); correct the comment at `WukongMind/IncomingLink.swift:42-44`; move `TabCardAccessibilityInspector.invokeCustomAction` under `#if DEBUG` or into the test target.
- **Size:** XS.
- **Done when:** the Release binary has no `GEMINI_LIVE_BUDGET` string and does not import `NSClassFromString`; the live-budget tests still pass.

## 7. Not proven

- **The signed, uploaded build.** The checks ran on unsigned Release builds made from the same commit and configuration, not on the archive the release workflow signs and uploads. The signed entitlements and the provisioning profile were not read.
- **How App Review's own install looks to finding 4.** Whether a reviewer's device has a `sandboxReceipt` like TestFlight was not tested; the finding stands on the code alone (a default that differs by install source).
- **Apple's static scan.** The script checks what such a scan is known to look at (linked libraries, selectors, symbol imports, strings). Apple does not publish its list.
- **Behaviour on a device.** Nothing was run. That live voice continues in the background (finding 9) is read from the code: no code ends it. That iOS shows the paste prompt for the Shortcut's clipboard read is the system's documented behaviour, not observed here.
- **Third-party claims.** That other browsers on the store send Safari's user agent and suppress Universal Links is general knowledge, not checked for this audit.
- **A link the Agent clicks.** Whether a click made by the Agent's JavaScript counts as a user's tap for `mailto:`, `tel:` and app links was not traced or run.
- **Line-level detail of two long files.** The Agent's script tools (`ToolRegistry.swift`) and the script store were read for the points cited, with two helper passes over the rest; a path that asks for approval somewhere uncited would lower findings 1 and 2, and none was found.
