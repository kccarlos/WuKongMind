# App Store review readiness

A guideline-by-guideline review of what stands between WukongMind and App Store approval. This is an assessment only: no app code changed (WUKO-148).

**Updated 2026-11-19 (WUKO-168):** the owner decided on one build with no store flag, and on the general-browser case for 1.2 (recorded in [requirements.md](requirements.md), section 12). The summary, the checklist rows and the tasks below were changed to match, and the code was audited for non-public API and hidden behaviour: [app-store-code-audit.md](app-store-code-audit.md), summarized in section 6.

**Updated 2026-11-19 (WUKO-169):** the owner decided that WukongMind goes to the App Store, alongside Forumind, as an AI-assisted browser (requirements.md, section 12). Task 0 is closed. How the two apps are kept apart, the name, and both apps' state in App Store Connect are in [store-positioning.md](store-positioning.md); risk 4, the 4.3(a), 2.3.7 and 5.2.1 rows, section 3, the category and tasks 8 and 10 to 13 below were changed to match.

- **Guidelines used:** [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), fetched 2026-11-18, "Last Updated: October 16, 2026". Quotes below are from that text.
- **Code state:** `main` at `c6974c2` (version 1.5.0). Every `file:line` was checked against that commit; the lines added or changed on 2026-11-19 (tasks 0, 1, 4, 5 and section 6) refer to `6c4f66c` (version 1.5.4).
- **Forumind history:** from the Forumind Claude Code transcripts (through 2026-11-11) and from Forumind's own `docs/APP_STORE.md`, which is still in this repo's history (`git show e046b43:docs/APP_STORE.md`).
- **Risk levels:** **blocker** (will be rejected, or cannot be reviewed at all), **likely** (a reviewer who looks will reject), **question** (expect a question or a request for an explanation; a good note should settle it), **fine**.

## 1. Summary

**Verdict: WukongMind would not pass as it is today.** Until 2026-11-19 that was by design: [requirements.md](requirements.md) said "No App Store compliance, and no limits on any capability for its sake", and the cleanup in `d915ea0` and `83b4e45` deleted the consent, terms, moderation and listing work Forumind had built for review. The owner reversed that decision on 2026-11-19 (requirements.md, section 12): the app goes to the store, so the items below are now work to do.

Nothing found is impossible to fix. The engine (WebKit only), the lack of accounts, payments, analytics and servers, and the bundled filter lists are all in good shape. The work is in three places: things the cleanup deleted, the Agent's freedom to act and save code without the user seeing it, and everything App Store Connect needs.

### Top risks, in order

| # | Risk | Guideline | Level | Why |
|---|---|---|---|---|
| 1 | Reviewers cannot use the app's main feature | 2.1 | blocker | The Agent needs a tool-calling model, and Apple Intelligence is excluded (`WukongMind/ProviderModels.swift:91`). Without a key a reviewer gets the browser and, only on a device with Apple Intelligence turned on, thread summaries (the Summaries role accepts it, `WukongMind/AppModel+Models.swift:62`). The Agent, saved scripts, Learn on ask, podcasts' Google voices and live voice all need a key. The sample content is DEBUG only (`WukongMind/AppModel+Browse.swift:195`). |
| 2 | No permission before page content goes to a third-party AI, and no privacy policy in the app | 5.1.2(i), 5.1.1(i) | blocker | 5.1.2(i) now names "third-party AI" and requires "explicit permission". The per-provider consent page was deleted in `d915ea0`; a search of the app for "consent", "privacy policy" or a privacy URL finds nothing. `PRIVACY.md` says the app is "not distributed on the App Store". |
| 3 | Public materials contradict a submission | 5.6, 2.3.1, 2.5.19 | blocker | `README.md:16` says "not distributed on the App Store … with App Store capability restrictions removed" and `README.md:31` says "no confirmation prompts and no risk tiers". Forumind's last rejection was 5.6 ("features that appear to have been intentionally hidden") and the most likely trigger was public pages that did not match the build. |
| 4 | Two apps from one codebase on one account | 4.3(a) | likely | "Don't create multiple Bundle IDs of the same app." WukongMind is a fork of Forumind, and it still contains Forumind's forum summaries, digest, podcasts and voice. Decided 2026-11-19: both apps go up. Neither is live yet (Forumind 1.0.0 is developer-rejected). The plan to keep them apart is [store-positioning.md](store-positioning.md); tasks 10 to 13. |
| 5 | The Agent writes, saves and auto-runs code the user never saw; no confirmations by default | 2.5.2, 4.7.2, 4.7.3, 1.6 | likely | `script_save` stores the script enabled (`WukongMind/ToolRegistry.swift:1742`) with no approval step; "Confirm before writes" is off by default (`WukongMind/Models.swift:118`); `cookies_get` can hand HttpOnly cookie values to the model (`WukongMind/ToolRegistry+Network.swift:184`). User scripts as such have precedent on the store; unreviewed, self-saving ones are the weak point. |
| 6 | No user-generated-content precautions | 1.2, 2.3.6 | likely | Forumind was rejected under 1.2 for exactly this (a browser where users read and post to forums), and had to add Terms of Use, report, block and a word filter. All four were deleted in `d915ea0`. A general browser has a better argument than a forum app, but the forum features are still here. |
| 7 | No store listing at all | 2.1, 2.3, 1.5 | blocker (process) | `appstore/` and the website were deleted in `83b4e45`: no description, screenshots, privacy URL, support page or age rating answers exist. |
| 8 | Privacy manifest misses one API | 5.1.1, upload check | question | `ProcessInfo.systemUptime` is used at `WukongMind/BrowserTabsOverview.swift:1322`, but `WukongMind/PrivacyInfo.xcprivacy` declares only UserDefaults and file timestamps. System boot time is a required-reason API. |

### What must change before submitting

1. Decided 2026-11-19: WukongMind goes to the store, alongside Forumind. Make the difference between the two plain in the app, the listings and the note (risk 4; [store-positioning.md](store-positioning.md); tasks 10 to 13).
2. Give reviewers a working model (section 4.1): a spend-capped key in the review notes, plus a screen recording.
3. Bring back AI data consent and an in-app privacy policy link; rewrite `PRIVACY.md` and `README.md` for a store app.
4. Make Agent-saved scripts wait for the user's approval, turn "Confirm before writes" on by default, and stop giving cookie values to the model by default. Each is a visible Settings switch with the safe side as the default.
5. Argue the general web browser and AI agent case for 1.2 (decided 2026-11-19), with a lightweight Terms acceptance and "Report this answer" on AI output; accept that a rejection round is possible.
6. Rebuild the listing, privacy site and App Store Connect answers.
7. Fix the privacy manifest.

Section 5 turns these into tasks. **There is one build and no store flag** (decided 2026-11-19; an earlier version of this page planned a `DC_APP_STORE` compile flag). What the store needs becomes a visible Settings switch with the safe side as the default, and the user may turn it the other way. The TestFlight build is the store build, so a reviewer, a tester and a user all run the same code with the same defaults. That is the honest answer to 2.5.19 and 5.6: nothing depends on the build, the install source or who is looking.

## 2. Checklist

Guidelines that cannot apply are grouped in one row per section. "Note" means text for App Review Information (drafted in section 4.2).

### Introduction and "Before you submit"

| Item | Applies? | Evidence | Risk | Fix / note |
|---|---|---|---|---|
| "If you build an app that you just want to show to family and friends, the App Store isn't the best way" | Yes | `README.md:14` calls it a "self-use browser" | blocker until task 3 | Decided 2026-11-19: it goes to the store (requirements.md, section 12). The README must stop saying self-use only (task 3). |
| "Provide App Review with full access to your app … demo account or fully-featured demo mode, plus any other hardware or resources" | Yes | No key, no Agent (`ProviderModels.swift:91`); onboarding step 1 asks for an Agent provider (`WukongMind/OnboardingSteps.swift:112-119`) | blocker | Section 4.1. |
| "Include detailed explanations of non-obvious features" | Yes | Agent tools, user scripts, Learn on ask, developer mode | likely | Notes in section 4.2 name each one. |
| "Ensure that all app information and metadata is complete and accurate" | Yes | `appstore/` deleted in `83b4e45` | blocker (process) | Task 8. |
| "Test your app for crashes and bugs" | Yes | Camera, microphone and photo strings are present (`WukongMind/Info.plist`), which was Forumind's crash | fine | Test on iPad too: Forumind's reviews ran on iPad Air and iPhone 17 Pro Max. |

### 1. Safety

| No. | Title | Applies? | Evidence | Risk | Fix / note |
|---|---|---|---|---|---|
| 1.1 | Objectionable content | Partly | The app ships no content; it shows the web and AI output. Apple Intelligence uses `.permissiveContentTransformations` guardrails (docs/APPLE_INTELLIGENCE.md:45) | question | Note: content comes from sites the user opens; AI output comes from the user's own provider. Age rating covers the open web. |
| 1.2 | User-generated content | Yes | Users can sign in to and post on forums in the web view; forum adapters, summaries and digests remain. Terms, report, block and filter were deleted in `d915ea0` (`Moderation.swift`, `ModerationViews.swift`, `AppModel+Moderation.swift`, `TERMS.md`). 1.2 now also lists "AI content creation apps" | likely | Decided 2026-11-19: argue "general web browser with an AI agent, hosts nothing", with a lightweight Terms acceptance and "Report this answer" on AI output (task 5). Forumind lost the browser argument as a forum app, so a rejection round is possible; report, block and filter are then the fallback. |
| 1.2.1 | Creator content | No | No creator platform | fine | |
| 1.5 | Developer information | Yes | Settings › About has Support and source links (`WukongMind/SettingsDataHelpPages.swift:250-254`), both to GitHub | question | Task 8: a support page with a contact address; GitHub issues alone is thin. |
| 1.6 | Data security | Yes | Keys in the Keychain (`WukongMind/Persistence.swift:236-247`); password fields masked in page reads (`WukongMind/AgentBridge.swift:1518-1520`); but `cookies_get` returns HttpOnly values to the model after one confirmation (`ToolRegistry+Network.swift:184`, `:212`), and `http_request` can send them to any host (`:58-63`, `:78`) | likely | Tasks 1 and 4: cookie values are not given to the model unless the user turns on a setting; confirmations are on by default. |
| 1.3, 1.4, 1.7 | Kids, physical harm, crime reporting | No | Not a kids, health or reporting app | fine | Never select the Kids category. |

### 2. Performance

| No. | Title | Applies? | Evidence | Risk | Fix / note |
|---|---|---|---|---|---|
| 2.1(a) | App completeness | Yes | See risk 1. No in-app purchases, so 2.1(b) does not apply | blocker | Section 4.1; attach a screen recording from a real device (Apple asked Forumind for one as a new account). |
| 2.2 | Beta testing | Yes | TestFlight goes to the internal group only (`fastlane/Fastfile:86`). 2.2: a TestFlight build "should be intended for public distribution and should comply with the App Review Guidelines" | fine once task 1 ships | Decided 2026-11-19: one build. The TestFlight build is the store build, so the mismatch behind Forumind's 5.6 (an unrestricted TestFlight build next to a restricted store build) cannot happen. Until task 1 changes the defaults, TestFlight builds still have the unrestricted ones. |
| 2.3 / 2.3.1 | Accurate metadata, describe features | Yes | No listing exists; README and PRIVACY.md describe a non-store app | blocker | Tasks 3 and 8. Every claim in the listing must be true of the submitted build. |
| 2.3.3, 2.3.9 | Screenshots | Yes | None exist | blocker (process) | Task 8: the app in use, invented data only, no real people's posts. |
| 2.3.6 | Age rating | Yes | Any website can be opened; forums are user-generated content | likely if answered wrong | Unrestricted Web Access: Yes (gives 16+); User-Generated Content: Yes. Forumind was rejected twice over the second answer (once because the setting silently reverted). Section 4.4. |
| 2.3.7 | Name and keywords | Yes | Name "WukongMind" (the app record exists under it); provider names are trademarks | question | No provider, platform or other app names in name, subtitle or keywords; no "forum" in the keywords. Name candidates and the recommended name and subtitle: [store-positioning.md](store-positioning.md), section 4. |
| 2.3.10 | Other platforms | Partly | "Tampermonkey-compatible" is a third-party product name, not a mobile platform | fine | Keep it out of the name and subtitle; fine in the description. |
| 2.3.12 | What's New | Yes | Release notes come from the tag (`.github/workflows/release.yml:322`) | fine | Write real notes for store versions. |
| 2.4.1 | iPad | Yes | `TARGETED_DEVICE_FAMILY` "1,2" (`scripts/generate_project.rb:239`) | fine | |
| 2.4.2 | Power | Yes | Background tasks are bounded: watch refresh every 30 min at most, digest on power only (`WukongMind/WatchSupport.swift:148-165`, `WukongMind/DailyDigest.swift:415-437`) | fine | |
| 2.5.1 | Public APIs | Yes | Forumind's selector trick in the share extension is gone (`WukongMindShare/ShareViewController.swift:40`); the only `dlopen` and the only private selectors are a DEBUG test helper (`WukongMind/ForumBrowser.swift:1826-1878`), and a Release build was checked not to contain them | fine | Full sweep: [app-store-code-audit.md](app-store-code-audit.md). The `shareddocuments://` links were replaced with `UIDocumentPickerViewController` in audit task D. |
| 2.5.2 | Self-contained; no downloaded code that changes features | **Yes** | (a) `.user.js` links are fetched and installed (`WukongMind/ScriptImport.swift:141-145`, `:298`), with a review sheet, off and isolated by default (`:425`, `:428`). (b) The Agent runs model-written JavaScript in the page (`ToolRegistry.swift:1206`). (c) The Agent saves scripts that run on later visits, enabled at once (`ToolRegistry.swift:1624`, `:1742`). (d) `@require` libraries are downloaded. Everything runs in WebKit's JavaScript; no native code, no other interpreter, no remote config. Filter lists are bundled (`WukongMind/ContentBlocker.swift:340-341`) | likely for (c), question for (a), (b), (d) | The defensible reading: scripts act on web pages inside WebKit and do not change the app's own features, and 4.7 allows JavaScript plug-ins. (Userscript managers are, to my knowledge, on the store already; not checked for this review.) Make (c) match (a): the user sees the code and approves it (task 4). Explain all four in the note. |
| 2.5.3 | Harmful code | Yes | A user script can do anything a page can | question | Same mitigations as 2.5.2. |
| 2.5.4 | Background modes | Yes | `audio`, `fetch`, `processing`, `remote-notification` (`Info.plist`, UIBackgroundModes). Audio: podcast and read aloud play in the background (`WukongMind/Podcast/PodcastPlayer.swift:594-598`); voice uses play-and-record (`WukongMind/Voice/VoiceAudioEngine.swift:256`). No silent-audio keep-alive was found. `remote-notification` is for CloudKit's silent pushes (`WukongMind/WukongMindApp.swift:46`) and is declared even when CloudKit is off | question | Task 7: drop `remote-notification` when CloudKit is off; say in the note what each mode is for. |
| 2.5.5 | IPv6 | Yes | URLSession and WebKit only | fine | |
| 2.5.6 | WebKit for browsing | Yes | One `WKWebView` (`ForumBrowser.swift:532`); no JavaScriptCore or other engine | fine | Say so in the note. |
| 2.5.9 | Standard behaviours | Partly | Custom Safari user agent (`ForumBrowser.swift:533`, `WukongMind/LinkPolicy.swift:115-126`) | fine | Common in browsers; no need to raise it. |
| 2.5.11 | Shortcuts | Yes | Three intents, all the app's own actions (`WukongMind/System/AppIntents.swift:13`, `:42`, `:76`) | fine | |
| 2.5.14 | Recording indication | Yes | Voice and dictation ask for the microphone and show a live state (`WukongMind/VoiceViews.swift:310-329`); task records and the audit log stay on the device | fine | Live voice audio goes to Google: covered by consent (task 2). |
| 2.5.15, 2.5.16 | Files, extensions related to the app | Yes | Workspace is visible in Files (`Info.plist` UIFileSharingEnabled); the share extension is off by default (`generate_project.rb:156`) | fine | |
| 2.5.19 | No hidden or undocumented features | **Yes** | Developer mode is a visible switch, default off (`WukongMind/SettingsAssistantPages.swift:276`, `Models.swift:123`). `-dc-*` launch arguments are DEBUG only (`AppModel+Browse.swift:195-211`). No remote config or feature flags | question | Forumind's 5.6 lesson. Name developer mode in the note. One build: no store flag, and nothing may depend on the build or the install source. The one such default (`BuildChannel.isTestFlight`) was removed in audit task B (WUKO-173). |
| 2.3.2, 2.3.4, 2.3.5, 2.3.8, 2.3.11, 2.3.13, 2.3.14, 2.4.3-2.4.5, 2.5.8, 2.5.12, 2.5.13, 2.5.17, 2.5.18 | In-app purchases, previews, tvOS, Mac, CallKit, Face ID, Matter, ads | No | None of these features exist | fine | Category: Productivity or Utilities. |

### 3. Business

| No. | Title | Applies? | Evidence | Risk | Fix / note |
|---|---|---|---|---|---|
| 3.1.1 | In-app purchase | Yes | The app is free and unlocks nothing. Users bring their own API key | question | Note: no purchase, subscription or unlock; keys are the user's own account with a third party, as in other bring-your-own-key apps. |
| 3.1.1(a) | Links to other purchase methods | Yes | Onboarding links to each provider's key page (`WukongMind/AppModel+Onboarding.swift:128-179`), where credits are also sold | question | Task 9: keep the wording to "get a key", never "buy" or prices. Outside the United States, links that lead to a purchase need care; plain text addresses are the fallback. |
| 3.1.3(f) | Free stand-alone apps | Partly | A free client for services paid for elsewhere, with no purchasing in the app | fine | Supports the note above. |
| 3.2.2(i) | Store-like interface for plug-ins | Yes | No script catalogue or store exists; scripts come only from links the user opens | fine | Don't add a catalogue without re-reading 4.7.4. |
| 3.1.2, 3.1.4, 3.1.5, 3.2.1, rest of 3.2.2 | Subscriptions, hardware, crypto, loans | No | | fine | |

### 4. Design

| No. | Title | Applies? | Evidence | Risk | Fix / note |
|---|---|---|---|---|---|
| 4.1 | Copycats | Partly | Original design; "Tampermonkey-compatible" describes compatibility only | fine | |
| 4.2 | Minimum functionality | Yes | Far more than a wrapped website | fine | Only at risk if the reviewer has no model (risk 1): then it looks like a bare browser. |
| 4.2.3 | Works on its own | Yes | No other app needed | fine | |
| 4.3(a) | Same app, several bundle IDs | **Yes** | Fork of Forumind (`docs/wukongmind/README.md:16`), with Forumind's forum features kept; about 165 interface strings still say forum, topic or thread | likely | Decided 2026-11-19: both on the store. [store-positioning.md](store-positioning.md) lists every Forumind-derived feature with keep, generalise or remove, the two listings, and the note paragraph on the relationship. Tasks 10 to 13. |
| 4.4 | Extensions | Partly | Share extension off by default | fine | If enabled, mention it in the description. |
| 4.5.4 | Push notifications | Partly | Silent CloudKit pushes only; local notifications are opt-in (`WukongMind/WatchSupport.swift:20-23`) | fine | |
| 4.7 | Mini apps, plug-ins, chatbots | **Yes** | User scripts are JavaScript plug-ins; the Agent is a chatbot | question | 4.7 makes the developer "responsible for all such software offered in your app". The app offers none itself: say so. |
| 4.7.1 | Privacy, filtering, payments for that software | Yes | Depends on tasks 2 and 5 | likely until those land | |
| 4.7.2 | "may not extend or expose native platform APIs or technologies to the software without prior permission" | **Yes** | Scripts get native requests (`GM_xmlhttpRequest`, with `@connect` enforced, `WukongMind/AgentNetworkTools.swift:393-395`), storage, and `GM_ai`, which calls the user's AI provider (`WukongMind/GMAi.swift:313-316` for its limits). Clipboard, downloads, notifications, cookies and tabs are refused (`WukongMind/GMBridge.swift:166-169`) | question | These are web-level abilities, not device APIs (no camera, location, contacts, files). Say that in the note. |
| 4.7.3 | Consent "in each instance" before sharing data with that software | Yes | Imported scripts: review sheet with capability rows, `GM_ai` and `@connect *` flagged (`ScriptImport.swift:485-517`). Agent-saved scripts: none | likely | Task 4. |
| 4.7.4, 4.7.5 | Index of software; age limits | No | No software is offered by the app | fine | |
| 4.8 | Login services | Yes | No account of its own; sites' own sign-in pages may show Google or other buttons | question | Forumind was cited for this and answered with the "client for a third-party service" exception; Apple did not raise it again. Put the answer in the note up front. |
| 4.2.1, 4.2.2, 4.2.6, 4.2.7, 4.4.1, 4.4.2, 4.5.1-4.5.3, 4.5.5, 4.5.6, 4.9, 4.10 | AR, templates, remote desktop, keyboards, Safari extensions, Apple Music, Game Center, Apple Pay | No | | fine | |

### 5. Legal

| No. | Title | Applies? | Evidence | Risk | Fix / note |
|---|---|---|---|---|---|
| 5.1.1(i) | Privacy policy, in the app and in App Store Connect | Yes | No link in the app; `PRIVACY.md` is written for a non-store app; the website was deleted in `83b4e45` | blocker | Tasks 2, 3 and 8. |
| 5.1.1(ii) | Consent and purpose strings | Yes | Strings exist but still say "forum page" (`Info.plist`, camera, microphone, photos) | question | Task 7: say "web page". |
| 5.1.1(iii), (iv) | Data minimisation, access | Yes | Photos is add-only; camera and microphone only when a page or the user asks | fine | |
| 5.1.1(v) | Accounts and deletion | No | No accounts. Sites' own logins live in WebKit | fine | Say "no account, nothing to delete" in the note. Settings › Data & privacy can clear saved site data (`WukongMind/SettingsDataHelpPages.swift:65`). |
| 5.1.1(vi) | Discovering passwords or private data | Yes | Password fields masked; cookies readable by the Agent after a confirmation | question | Task 4. |
| 5.1.2(i) | Explicit permission before sharing with third parties, "including with third-party AI" | **Yes** | Page text, forum content and voice audio go to the chosen provider (`PRIVACY.md`); no consent step. The deleted `AIDataConsent.swift` was built for this rule | blocker | Task 2. |
| 5.1.2(i), tracking | App Tracking Transparency | No | No tracking, no SDKs (`PrivacyInfo.xcprivacy`: NSPrivacyTracking false) | fine | |
| 5.1.4 | Kids | No | | fine | Rated 16+ by the web-access answer. |
| 5.2.1 | Trademarks | Yes | Checked 2026-11-19 ([store-positioning.md](store-positioning.md), section 4): USPTO has a registered WUKONG for educational software (class 9), a pending WUKONG for AI services (class 42) and BLACK MYTH WUKONG in classes 9 and 42; nothing for "wukongmind". The store has a large browser named 悟空浏览器 | question | The owner decides the name. Recommended: "WukongMind Browser"; not "Wukong Browser". Nothing in the icon or text may borrow the game's look. |
| 5.2.2 | Third-party content and terms | Yes | Reads, summarises and narrates pages; optional ad blocking, off by default (`Models.swift:132-136`); no site-specific ad skipping or paywall code | question | Note: acts like a browser for the user's own reading; ad blocking is optional and off; filter lists are credited (Settings › Acknowledgements, `NOTICE`). No listing claim of an ad-free web. |
| 5.2.3 | Saving media from third-party sources | Partly | No downloader; `GM_download` is refused; `http_request` can save any file up to 20 MB to the workspace | question | Never describe it as a downloader. If asked: a general file tool, like saving from a browser. |
| 5.2.4, 5.2.5 | Apple endorsement, look-alikes | Partly | "Safari-like address bar" is a design-doc phrase only | fine | Don't use "Safari" in the listing except to describe the share sheet. |
| 5.6 | Developer Code of Conduct | **Yes** | See risk 3 | blocker until the public pages match | Task 3. |
| Export compliance (not a guideline; asked at upload) | Yes | `ITSAppUsesNonExemptEncryption` false (`Info.plist`); only system TLS, CloudKit and CryptoKit hashing | fine | Same reasoning as Forumind's. |
| Entitlements | Yes | Base file is empty; iCloud and push are added only with `DC_ENABLE_CLOUDKIT` (`generate_project.rb:154-173`); Private Cloud Compute only with `DC_ENABLE_PCC` (`:175`) | fine | Review each enabled capability in the note. |
| 5.1.3, 5.1.5, 5.3, 5.4, 5.5 | Health, location, gambling, VPN, MDM | No | | fine | |

### Privacy manifest check

| API | Used at | Declared? |
|---|---|---|
| UserDefaults | throughout | Yes, `CA92.1` |
| File timestamps | `WukongMind/ScriptStore.swift:3417`, `WukongMind/AgentWorkspace.swift:252`, `WukongMind/AppModel.swift:746` | Yes, `C617.1` |
| System boot time (`systemUptime`) | `WukongMind/BrowserTabsOverview.swift:1322` | **No** (reason `35F9.1`, measuring time between events in the app, should fit; see Not verified) |
| Disk space, active keyboards | not used | n/a |

The share extension's manifest declares no APIs; that matches its code (no UserDefaults use found).

## 3. Forumind's review history and what it means here

Forumind 1.0.0 was **never approved**. The transcripts end on 2026-11-10 with a submission the owner cancelled in order to resubmit a newer build; the appeal's result is not recorded. App Store Connect on 2026-11-19 (read-only API): version 1.0.0 is `DEVELOPER_REJECTED`, the one review submission on record (submitted 2026-11-09) is `COMPLETE`, and the public lookup for the app's id returns nothing, so Forumind is not on the store. Its listing as it stands is summarised in [store-positioning.md](store-positioning.md), section 1.

| Date | Build | Apple said | Cause | What fixed it | Same risk in WukongMind? |
|---|---|---|---|---|---|
| 09-28 | 1.0.0 (1-2) | 2.1 Information Needed: new developer account; asked for a device screen recording, purpose, setup steps, external services (AI named), regional differences, third-party material | New account | Reply the same day with a recording; the same text in the Notes field. No key was shared | **Yes.** Same account history. Have the recording and notes ready first (section 4.2). |
| 10-06 | 1.0.0 (2), iPad | 2.1(a): crash on "Take Photo or Video" from a forum upload field | Camera, microphone and photo usage strings missing | Added the strings | Handled: all three are in `Info.plist`. |
| 10-06 | same | 4.8: third-party login without an equivalent option | A forum's own "Continue with Google" button | Reply: no login of its own; client of a third-party service. Not raised again | Yes, as a question. Answer it in the notes up front. |
| 10-06 | same | 1.2: user-generated content without filtering, reporting, blocking, action within 24 hours, and a recording of the terms and the flows | Users read and post to forums in the app | Terms of Use acceptance, report, block, word filter, a public moderation list | **Yes, and unhandled:** all deleted in `d915ea0`. |
| 10-06, 10-16 | (2), (102) | 2.3.6: answer "Yes" to User-Generated Content | Answered No; then the Yes was lost, probably by a stale browser tab | Set to Yes and re-checked | Yes. Answer Yes, and read the saved value back before submitting. |
| about 11-09 | 1.0.0 (102), after about 24 days waiting | 5.6: "features that appear to have been intentionally hidden during the review process" (no feature named) | Not established. Candidates found: the public README, website and TestFlight advertised features the reviewed build lacked; a daily remote moderation file that looks like remote config; a seven-tap hidden Developer section; a private-selector trick in the share extension | README and website corrected; notes rewritten to say nothing is hidden; appeal filed; Apple replied only "please resubmit" | **Yes, more so.** The README says App Store restrictions were removed. Handled already: no remote file, no hidden menu (developer mode is a visible switch), no selector trick. Not handled: public pages. |

Other lessons:

- **The reviewer key.** Forumind went from "Apple Intelligence needs no key", to "contact us for a key", to a spend-capped key written into the notes. Start at the last step.
- **TestFlight** external builds passed Beta App Review without trouble; that says little about App Review.
- **A long silence is normal** for a new account (about 24 days once). Plan for it.
- **Forumind's choices that still fit:** privacy label "Data Not Collected", export compliance exempt, content rights "yes", not offered in China mainland, a non-affiliation line for named platforms.

## 4. Drafts for App Store Connect

### 4.1 How reviewers get a working model

| Option | How | For | Against |
|---|---|---|---|
| **A. A spend-capped key in the notes (recommended)** | A new key for one provider, with a small hard limit, in the Notes field with the exact path to paste it; revoked after approval | No code. Works on any review device. Shows every feature, voice included if it is a Gemini key | Anyone who sees the notes can spend up to the cap. Must be renewed for each review. Never reuse a personal key |
| B. Apple Intelligence runs the Agent too (today it serves only the Summaries role) | Add tool calling for the on-device model | No key, nothing leaves the device | New work. The on-device context is about 4,096 tokens (docs/APPLE_INTELLIGENCE.md:47), too small for page reading. Needs an eligible review device with Apple Intelligence on. Cannot be the only path |
| C. A demo mode with recorded answers | Ship the DEBUG sample in release | No key, no cost | 2.1(a) allows a demo mode only "with prior approval by Apple" and it must show "full features". A mode made for reviewers is also what 5.6 punishes. Only acceptable as a visible "try a sample" for everyone, and it still proves nothing live |
| D. A hosted free tier | The developer's own proxy | Easiest for users too | A server, cost and abuse; changes the privacy label; against the app's design |

**Recommendation:** A, plus a screen recording from a real iPhone and iPad showing the same steps, so the review does not depend on the key working that day. Decided (WUKO-169 brief, 2026-11-19): yes, a spend-capped key goes in the notes.

### 4.2 Draft notes (App Review Information › Notes)

Plain text, under 4,000 characters. The paragraph on the relationship with Forumind ("OUR OTHER APP", [store-positioning.md](store-positioning.md), section 3) goes after the opening paragraph. Text in [brackets] is filled in at submission. Statements marked (after task N) are true only once that task ships.

```
WukongMind is a web browser for iPhone and iPad with an AI assistant ("Agent") that reads the page you are on and answers questions about it. It has no account, no login of its own, no in-app purchases, no ads, no analytics and no server of ours.

TEST KEY
The Agent uses an AI service the user connects with their own key. For review, please use this temporary key (limited spend, revoked after review):
Settings > AI models > Providers > [provider] > API key: [PASTE KEY]
The attached screen recording (real iPhone, from launch) shows every step below.

HOW TO TEST
1. Launch. Accept the Terms of Use and the AI data notice (after tasks 2, 5).
2. Paste the key as above and choose [model].
3. Open any page, e.g. https://en.wikipedia.org/wiki/Apple. Open the assistant and ask "Summarize this page".
4. Ask "Make the text larger on this page". The Agent runs JavaScript in the page inside WebKit and shows what it did.
5. Ask it to keep that change. It shows the script and asks before saving (after task 4). Saved scripts are listed in Settings > Scripts, where each can be read, turned off or deleted.
6. Open meta.discourse.org, open a topic, ask for a summary; try Read aloud.
7. Report an AI answer: the menu on an answer > Report this answer (after task 5).

SCRIPTS (guidelines 2.5.2, 4.7)
All web content is rendered with WKWebView and all scripts run in WebKit's JavaScript. Scripts change web pages only; they cannot change the app's features or interface and get no device APIs (no camera, location, contacts, files, clipboard).
- The app offers no catalogue of scripts. A user can import a script from an https link; the app downloads it and any libraries it names (@require), shows the full source and what it can do, and the user turns it on.
- A script may ask for two extra abilities, both shown before it is turned on: web requests to the sites it lists (GM_xmlhttpRequest), and asking the user's AI service a question (GM_ai, rate-limited).
- Once a day the app checks whether an imported script has a newer version at its own link. It only shows "update available"; the user reviews the changes before anything is replaced. This can be turned off in Settings > Scripts.
- "Learn on ask": when asked about a site, the Agent can write a small read-only script for that site and reuse it later. The user approves it first (after task 4) and can read or delete it in Settings > Scripts.
The app downloads nothing else: no remote configuration, no feature flags. Ad and tracker blocking is optional, off by default, and uses filter lists bundled in the app.

NOTHING IS HIDDEN
There are no hidden or review-only features. "Developer mode" (Settings > Agent) is a visible switch that shows technical details of each request.

LOGIN (4.8)
The app has no login. Websites show their own sign-in pages in the browser; any "Continue with Google" button belongs to the website. Account deletion does not apply.

DATA
Page content and questions go directly from the device to the AI service the user chose, after the user agrees, per service. Voice mode sends microphone audio to Google Gemini while it is on, after a separate consent. Optional iCloud sync uses the user's private CloudKit database. We receive no data.

BACKGROUND MODES
audio: Read aloud and podcasts keep playing; voice mode. fetch/processing: refresh topics the user watches. remote-notification: silent iCloud sync pushes.

OTHER
Free. Not offered in China mainland. Not affiliated with any website or AI provider named. EasyList and EasyPrivacy are used under CC BY-SA 3.0. Source code: [repository link].
```

Also fill in the contact name, phone and email in App Store Connect (kept out of the repo), and attach the recording. For 1.2 the recording must show the Terms acceptance and "Report this answer".

### 4.3 Draft privacy label

**Answer: "No, we do not collect data from this app" (label: Data Not Collected).** Apple's test is whether the developer or its partners can access data sent off the device beyond serving the request. Here:

| Flow | Who receives it | Collected by the developer? |
|---|---|---|
| Web pages | The site the user opens | No (a browser) |
| Page text, questions, voice audio | The AI service the user configured with their own key | No: the user's own account with that service, not a partner of the developer |
| Sync | The user's private CloudKit database | No: the developer cannot read it |
| "Report a problem" exports | The user's own iCloud Drive, or the device (`WukongMind/FeedbackReports.swift:27-40`) | No, unless the user sends the file to the developer |
| API keys | Keychain | No |

This matches the manifest (`NSPrivacyCollectedDataTypes` empty). Two things would change the answer:

- **A reviewer key or hosted tier used by real users** (option D above): then Other User Content and Audio Data are collected.
- **Reports e-mailed to the developer** (task 5 uses the user's own Mail composer, with a `mailto:` / copy / share-sheet fallback when Mail is not configured): the app itself never transmits the report over the network, so "Data Not Collected" remains accurate and matches `NSPrivacyCollectedDataTypes` being empty. If App Review treats voluntary user-initiated report emails as collected, the conservative label adds Contact Info › Email Address and User Content › Other User Content, both "App Functionality", not linked, not tracking.

The privacy policy must still describe every flow above, name the AI services, and say how to withdraw consent and delete local data (5.1.1(i)).

### 4.4 Other answers

- **Age rating:** Unrestricted Web Access: Yes. User-Generated Content: Yes. Messaging and Chat: No (users don't talk to each other through the app). Everything else None or No. Apple's [age ratings page](https://developer.apple.com/help/app-store-connect/reference/age-ratings-values-and-definitions) (read 2026-11-18) lists "Unrestricted web access" under **16+** and has no question on AI assistants in the part read. Read the saved result back before submitting.
- **Category:** Utilities (primary), Productivity (secondary). Changed 2026-11-19: most browsers the store search returned, including all the large ones, are in Utilities, and Forumind is in Productivity and Reference, so the category helps tell the two apart.
- **Content rights:** contains third-party content (the filter lists), and has the rights.
- **Export compliance:** no non-exempt encryption (the plist key already answers it).
- **Availability:** as Forumind, exclude China mainland (AI services and filtering rules there).

## 5. Follow-up tasks

Each is one pull request. Order matters: 1 first; 2 to 7, 9 and 11 are independent of each other; 10 starts once the owner has answered on the digest (task 12); 12 only if the owner agrees; 8 last, after 10, 11 and 12 or its "no" branch (the listing describes the app as those tasks leave it). Task 13 is in Forumind's repository. There is one build (decided 2026-11-19): tasks 1, 2, 4 and 5 change every install, and where the owner wants the old freedom back it is a visible Settings switch, never a build flag. Task 0 is not code. The code audit adds tasks B to E ([app-store-code-audit.md](app-store-code-audit.md), section 6).

The owner's principles (2026-11-19) apply to every task: speed first (a task that touches a hot path such as launch, Home, the drawer, typing or scrolling shows before and after numbers); the smallest complete change, deleting what can be deleted; a design gap is fixed in its design document, not worked around; nothing hidden and no store rule worked around; each task re-runs the tests itself with `scripts/remote-test.sh` and keeps the command, the result and the log path in its proof.

### Task 0 (owner): decide (closed 2026-11-19)

- **Decided 2026-11-19** (recorded in requirements.md, section 12): (c) for 1.2, argue the general web browser and AI agent case, with a lightweight Terms acceptance and "Report this answer" on AI output; (e) one build only, no `DC_APP_STORE` flag: the TestFlight build is the store build, and what the store needs is a visible Settings switch with the safe side as the default.
- **Decided 2026-11-19 (WUKO-169):** (a) Yes, WukongMind goes to the App Store; the old decision is reversed. (b) Both apps go up: WukongMind as an AI-assisted browser, Forumind as forum browsing only; the plan is [store-positioning.md](store-positioning.md). (d) Yes, a spend-capped key is shared with reviewers (from the task brief). The assistant may fill in App Store Connect with the `asc` CLI.
- **Left for the owner, no longer part of this task:** the store name (store-positioning.md, section 4; decide before task 8) and removing the daily digest (task 12; decide before task 10 starts, because task 10 rewords the digest if it stays).
- **Why:** every other task depended on (a); (b) could sink the submission on its own.
- **Check:** done: the answers are in requirements.md, section 12.

### Task 1: one build, safe defaults as visible settings (done, WUKO-170)

- **Status:** Done (2026-11-19, WUKO-170).
  - **What shipped:** (a) `agentConfirmBeforeWrites` defaults to `true` in `WukongMind/Models.swift`, with a one-time per-device upgrade migration (`didMigrateAgentConfirmBeforeWritesDefault`, excluded from iCloud sync in `WukongMind/SyncRecords.swift`) that turns it on once for existing installs and preserves any later user choice to turn it off; (b) new synced Settings › Agent › Safety switch **Give cookie values to the model** (`agentShareCookieValues`, default `false`); (c) new synced Settings › Agent › Safety switch **Save scripts without asking** (`agentSaveScriptsWithoutAsking`, default `false`, ready for task 4). `docs/DEVELOPMENT.md` now records the one-build rule (no store variant; nothing may depend on build configuration beyond `#if DEBUG` test hooks, install source, date, or region), and `README.md` no longer claims "no confirmation prompts".
  - **Route chosen for `run_js` / `document.cookie`:** Took the recommended route (redact cookie values while **Give cookie values to the model** is off), using two layers so neither short cookies nor bypasses leak without corrupting normal HTML/JSON: (1) `AgentBridge.wrappedExecutionScript` wraps `document.cookie`'s getter during `runAgentJS` (on `Document.prototype` in the isolated world and on `document` in the page world, restored in `finally`, setter preserved) so `document.cookie` yields `name=[cookie]` before user JS can transform or encode it; (2) `ToolRegistry` redacts known cookie values for the current page's domain from tool outputs, summaries, page feedback, and `run_js` `save_to` files (`UntrustedWebContent.redactCookieValues`: exact `name=value` pairs for all cookies and values of 8+ chars anywhere). `cookies_get` omits the `"value"` field while off and includes it when on.
- **Why:** the owner's decision of 2026-11-19; 2.5.19, 5.6, 1.6. One build means App Review, TestFlight testers and users run the same code with the same defaults.
- **Files:** `WukongMind/Models.swift`, `WukongMind/SettingsAssistantPages.swift`, `WukongMind/AgentNetworkTools.swift`, `WukongMind/ToolRegistry+Network.swift`, `WukongMind/ToolRegistry.swift`, `WukongMind/AgentBridge.swift`, `WukongMind/AppModel.swift`, `WukongMind/SyncRecords.swift`, `WukongMind/Localizable.xcstrings`, `docs/DEVELOPMENT.md`, `README.md`.
- **Check:** unit tests for the three defaults on a new install and for the one-time switch-on at upgrade (`OnboardingTests`); recorded-response tests that `cookies_get` output has no values while the switch is off and has them when on, and that `run_js` returning `document.cookie` gives the model no cookie value while off (`AgentNetworkToolsTests`, `AgentBridgeTests`); UI test finds all three switches with their default states (`SettingsNavigationUITests`).

### Task 2: AI data consent and the privacy policy link (done, WUKO-175)

- **What:** before the first request to a third-party AI service, a full-screen page per service: what is sent, to whom, a link to the privacy policy, Allow / Don't allow; a backstop that refuses any third-party request without consent; withdraw in Settings › Data & privacy. Apple Intelligence and local servers need none. Separate consent for live voice (microphone audio to Google). Add a privacy policy link in Settings › About and on the consent page. Start from the deleted code: `git show d915ea0^:Forumind/AIDataConsent.swift`, `AIDataConsentViews.swift`, `AppModel+AIConsent.swift` and their tests.
- **Why:** 5.1.2(i) and 5.1.1(i); the two privacy blockers.
- **Files:** `WukongMind/AIDataConsent.swift`, `WukongMind/AIDataConsentViews.swift`, `WukongMind/AppModel+AIConsent.swift`, `WukongMind/AIService.swift` (backstop on both `streamText` and `completeToolTurn`), `WukongMind/BrowserAgent.swift`, `WukongMind/Models.swift`, `WukongMind/SyncRecords.swift`, `WukongMind/PresentationRouter.swift`, `WukongMind/AppModel.swift`, `WukongMind/AppModel+Voice.swift`, `WukongMind/Voice/VoiceController.swift`, `WukongMind/Voice/VoiceSession.swift`, `WukongMind/Podcast/PodcastController.swift`, `WukongMind/OnboardingSteps.swift`, `WukongMind/SettingsDataHelpPages.swift`, `WukongMindTests/AIDataConsentTests.swift`, `WukongMindUITests/AIConsentUITests.swift`.
- **Changed / not brought back:** one consent model (`aiConsent` per provider, `voiceConsent` per live-voice endpoint) and one request-layer backstop in `AIService` (`streamText` + `completeToolTurn`, covering summaries, Agent, `GM_ai`, and podcast scripts) plus the voice backstop in `voiceConfiguration()`. Did not bring back the separate `podcastConsent` sheet/dictionary (Google TTS reuses the provider's `aiConsent`), Forumind's `ModerationTerms`/report flow (Task 5), or duplicate voice withdrawal UI in `SettingsVoicePage` (all withdrawal lives in Settings › Data & privacy). Privacy policy links point to `AppVersion.privacyPolicyURL` (`PRIVACY.md` on GitHub until Task 8 sets a site URL).
- **Check:** done — `AIDataConsentTests` (10 tests: `AIService` backstop across summary/answer/complete/tool-turn, `GM_ai`, live voice gate + backstop, podcast TTS fallback + backstop, Apple Intelligence & loopback local servers vs LAN/remote, interactive wait + withdraw + unattended refusal, sync split, reset preservation) and `AIConsentUITests` (3 tests: Allow proceeds, Decline + Settings Allow/Withdraw + Privacy Policy links, separate live voice consent page). Appears for every install (one build).

### Task 3: public documents that match a store app (done, WUKO-191)

- **Done (2026-11-20, WUKO-191):**
  - Rewrote `PRIVACY.md` as a store privacy policy for **WukongMind Browser** covering all data flows from section 4.3 (web browsing, BYOK AI/speech providers, optional private CloudKit sync, local/iCloud Drive diagnostic exports, on-device filter lists/Spotlight/Siri/Translation), storage and Keychain retention, how to stop sending data to a provider or delete local data, and contact links to the Support page and GitHub Issues (compatible with `scripts/site/build.py` without `_TBD` leaks).
  - Rewrote `README.md`, `README.zh-Hans.md`, and `README.zh-Hant.md` (title `WukongMind Browser` / `WukongMind 浏览器` / `WukongMind 瀏覽器`, opening, "One build everywhere" replacing "Self-use, not on the App Store", Risk Statement with actual `Settings › Agent › Safety` defaults from task 1, updated Status table through `1.5.4`, and removed deleted topic-chat / third-role references) and updated `SECURITY.md` to match the one-build safety defaults.
  - Added App Store decision notes to `docs/wukongmind/requirements.md` and `docs/wukongmind/next-phase.md` noting that section 12 (2026-11-19) supersedes "No App Store compliance" and "no confirmation prompts by default".
- **What:** rewrite `PRIVACY.md` as a store privacy policy (data flows from section 4.3, named services, retention, how to withdraw consent and delete data, contact). Rewrite the README's opening, "Self-use, not on the App Store" bullet and Risk Statement so they describe the one build truthfully (its defaults, and the switches that loosen them). Update requirements.md and next-phase.md with a note that the store decision supersedes "No App Store compliance". Translate the README changes (`README.zh-Hans.md`, `README.zh-Hant.md`).
- **Why:** 5.6 and 2.3.1; Forumind's last rejection.
- **Files:** `PRIVACY.md`, `README*.md`, `SECURITY.md`, `docs/wukongmind/requirements.md`, `docs/wukongmind/next-phase.md`.
- **Check:** a reader comparing the README with the build finds no feature named that the build lacks, and no "restrictions removed" wording; links resolve.

### Task 4: the Agent asks before it saves code or acts for the user

- **What:** for every install, unless the user turned on "Save scripts without asking" (task 1): (a) `script_save` shows the same review sheet as an import (source, where it runs, what it can do) and saves only after the user approves; Learn on ask readers included, approved once per site. (b) `script_update` shows the sheet as a diff whenever it changes code, sites, grants or allowed hosts, or turns a script on; this includes scripts the user imported, which it can rewrite today (audit findings 1 and 2). (c) `notify` comes under "Confirm before writes" and no longer raises the notification permission prompt by itself (audit finding 6). (d) The "Confirm before writes" label and footer say what it covers (audit finding 5). (e) The first-run text explains that the Agent can act on pages the user is signed in to. The defaults themselves are task 1.
- **Why:** 2.5.2, 4.7.3, 1.6, 5.1.1(vi): the user sees and approves code before it runs again, and credentials don't leave the device.
- **Files:** `WukongMind/ToolRegistry.swift` (1624, 1742, 1973, 2034, 2116), `WukongMind/AgentConfirmationGate.swift`, `WukongMind/ScriptImportViews.swift` (reuse the sheet), `WukongMind/ToolRegistry+Capabilities.swift` (283-300), `WukongMind/SettingsAssistantPages.swift` (235-240), `docs/wukongmind/design-learn-on-ask.md` (line 97, "A learned reader never asks", now true only with the switch on).
- **Check:** recorded-response tests: a save without approval stores nothing; declining leaves no script; an update to an imported script waits for approval; with "Save scripts without asking" on, the current tests pass unchanged.

### Task 5: Terms of Use and "Report this answer" (done, WUKO-179)

- **Done (2026-11-20, WUKO-179):**
  - Added `TERMS.md` (compatible with `scripts/site/build.py`) with zero-tolerance wording for objectionable content and abusive behavior, reporting instructions, AI/script disclaimers, and contact details.
  - Added `WukongMind/TermsAndReporting.swift` and `WukongMind/TermsAndReportingViews.swift`: versioned `TermsOfUse` (`currentVersion = 1`), `AppSettings.acceptedTermsVersion` (persisted and synced; preserved across `resetSettings()`), and `TermsGateView` presented full-screen right after onboarding/consent (`RootPresentation.termsGate`) until the user toggles agreement and taps Continue.
  - Added "Report this answer" (`agentAnswerMenu` on completed Agent replies in `WukongMind/AgentPanel.swift`) and "Report this summary" (`SummaryMoreMenu` in `WukongMind/SummaryPanel.swift`), routing to `AIOutputReportSheet` (`AIOutputReportForm` -> `MFMailComposeViewController` addressed to `kccarlos.opensource@gmail.com`, with `ReportEmailFallback` offering `mailto:`, Copy, and `ShareLink` when Mail is not configured).
  - Added a "Terms of Use" link in Settings › About (`WukongMind/SettingsDataHelpPages.swift`) and `AppVersion.termsURL` (`WukongMind/AppModel+Onboarding.swift`).
- **What:** the lightweight precautions that go with the general-browser case (decided 2026-11-19): Terms of Use accepted once before first use (zero-tolerance wording for objectionable content), and "Report this answer" on AI output. For every install; no flag. How a report travels is for the task to propose (Forumind used the user's own Mail app). This page reads "lightweight" as: per-site blocked users, the word filter and the remote moderation list are **not** restored, and are the fallback if Apple rejects the browser argument; the owner did not say this in so many words. If that happens, never restore the daily remote list as it was (it looked like remote config); bundle it and update it with app releases.
- **Why:** 1.2, 4.7.1; Forumind's rejection of 10-06. A browser hosts nothing, but 1.2 now names AI content, so the AI answers get a report path.
- **Files:** `TERMS.md`, `WukongMind/TermsAndReporting.swift`, `WukongMind/TermsAndReportingViews.swift`, `WukongMind/Models.swift`, `WukongMind/AppModel.swift`, `WukongMind/AppModel+Onboarding.swift`, `WukongMind/AppModel+Assistant.swift`, `WukongMind/PresentationRouter.swift`, `WukongMind/AgentPanel.swift`, `WukongMind/SummaryPanel.swift`, `WukongMind/SettingsDataHelpPages.swift`, `WukongMindTests/TermsAndReportingTests.swift`, `WukongMindUITests/TermsAndReportUITests.swift`, `WukongMindUITests/OnboardingUITests.swift`.
- **Check:** `TermsAndReportingTests` (5 tests: terms acceptance, backward-compatible decoding, `resetSettings()` preservation, report draft formatting/truncation/`mailto:`, empty-reply guard), `TermsAndReportUITests` (2 tests: first-run Terms gate waits for agreement before Step 3; Agent answer menu has "Report this answer" and opens report form/fallback, Summary menu has "Report this summary", Settings › About has Terms link), and `OnboardingUITests` (6 tests) all pass on `scripts/remote-test.sh`.

### Task 6: reviewers and new users are never stuck without a model

- **What:** check and fix the no-key first run: onboarding can be skipped, the browser works, and the assistant shows a clear "connect a model" card with a working path to Settings. Apple Intelligence serves the Summaries role but not the Agent: check on a device that a summary really works with it and no key, and make the card say plainly that the Agent needs a key. Write the exact key path used in the review notes into a UI test so it cannot drift.
- **Why:** 2.1; a reviewer whose key fails must still see a complete, non-broken app.
- **Files:** `WukongMind/Onboarding.swift`, `WukongMind/OnboardingSteps.swift`, `WukongMind/AppModel+Models.swift` (around 276-347, 520-530), `WukongMindUITests`.
- **Check:** a UI test from a clean launch with no key reaches a page and the setup card; a second pastes a fake key along the documented path.

### Task 7: privacy manifest, purpose strings, background modes (done)

- **Done:** replaced `ProcessInfo.processInfo.systemUptime` in `WukongMind/BrowserTabsOverview.swift` (`TabCycleShortcutGate`) with `ContinuousClock.now` so `NSPrivacyAccessedAPICategorySystemBootTime` is not used or needed; changed "forum page(s)" to "web page(s)" in `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` and `NSPhotoLibraryAddUsageDescription` in `WukongMind/Info.plist` and all three languages of `WukongMind/InfoPlist.xcstrings`; moved `remote-notification` out of `WukongMind/Info.plist` and into `scripts/generate_project.rb` only when `DC_ENABLE_CLOUDKIT=YES`; ended active live voice sessions (`voice.end()`) on `.background` in `WukongMind/AppModel.swift`.
- **What:** add `NSPrivacyAccessedAPICategorySystemBootTime` with reason `35F9.1` to `WukongMind/PrivacyInfo.xcprivacy` (or replace `systemUptime` at `BrowserTabsOverview.swift:1322` with `ContinuousClock`). Change "forum page" to "web page" in the camera, microphone and photo strings, in all three languages. Declare `remote-notification` only when CloudKit is enabled. Decide what live voice does when the app goes to the background (stop, or keep and say so in the notes).
- **Why:** upload checks for required-reason APIs; 5.1.1(ii); 2.5.4.
- **Files:** `WukongMind/PrivacyInfo.xcprivacy`, `WukongMind/Info.plist`, `WukongMind/InfoPlist.xcstrings`, `scripts/generate_project.rb`, `WukongMind/Voice/VoiceAudioEngine.swift`.
- **Check:** archive and read Xcode's privacy report (Organizer › Generate Privacy Report); upload a build to TestFlight and confirm no ITMS-91053 warning e-mail.

### Task 8: listing, website and App Store Connect

- **What:** recreate `appstore/metadata/` (name, subtitle, description, keywords, URLs) in English and both Chinese scripts, with no provider or product names in name, subtitle or keywords; screenshots with invented content; a small site with the privacy policy and a support page with a contact address; the App Store Connect answers from section 4 (privacy label, age rating, content rights, review notes, recording). Add to the notes what the code audit says to state plainly: web views send Safari's user agent; tapped links stay in the browser unless "Open links in apps" is on; what live voice does in the background (after task 7). Restore what is reusable from `git show 83b4e45^:appstore/`, `mobile-site/`, `scripts/ci/check-appstore-metadata.sh` and the listing lanes in `fastlane/Fastfile`. The app record already exists (id 6833832262, name "WukongMind", version 1.0 in Prepare for Submission since 2026-11-12, en-US only, nothing else filled in): fill it with the `asc` CLI in write mode (allowed by the owner, 2026-11-19), adding the two Chinese localisations, and read every saved value back. Use the name and subtitle the owner chose from [store-positioning.md](store-positioning.md), section 4 (the name was checked there against the store and USPTO), its listing rules and screenshot list (section 3), the relationship paragraph in the notes, and category Utilities then Productivity. The bundle id does not change.
- **Why:** 2.1, 2.3, 1.5, 5.1.1(i).
- **Files:** `appstore/`, `mobile-site/` (or another host), `fastlane/Fastfile`, `.github/workflows/release.yml`, a new `docs/APP_STORE.md` based on Forumind's.
- **Website part: done (WUKO-190).** `site/` + `scripts/site/build.py` + `.github/workflows/site.yml`: home, privacy (generated from `PRIVACY.md`), support, in English, 简体中文 and 繁體中文, deployed to GitHub Pages (needs Settings › Pages › Source "GitHub Actions" once; see [DEVELOPMENT.md](../DEVELOPMENT.md#website)). **Still open for task 8:** the support email (`support_email` in `site/config.json`, `SUPPORT_EMAIL_TBD`; the support page shows GitHub only until it is set); the public TestFlight link (`testflight_url`, `TESTFLIGHT_URL_TBD`; its section is not rendered until set); a terms page appears by itself once `TERMS.md` exists (task 5); the privacy page follows `PRIVACY.md`, so task 3's rewrite lands on it automatically, and today's text still says "not distributed on the App Store"; screenshots (none on the site until real ones exist); the Chinese privacy page is the English text under a note, since there is no translated policy. Put the Pages URLs into App Store Connect (privacy, support, marketing) once the site is live.
- **Check:** the metadata limit check passes in CI; URLs load; the age rating and privacy answers are read back from App Store Connect after saving (Forumind lost one that way).

### Task 9: provider key links (done 2026-11-19)

- **What:** review the wording around the key links in onboarding and Settings: "Get a key" only, no prices, no "buy credits". Open them in the app's own browser tab or show the address as text, for every install, so no button leads straight to a purchase page.
- **Done:** removed pricing, credit, free-tier, and billing wording ("low-cost", "with free credits to start", "with a free tier", "no bill", "no usage bill", "billed to it") from `ProviderGuide` and `Localizable.xcstrings`; replaced external `Link`/`openURL` calls in `SettingsProviderForm.swift`, `SettingsProviderPage.swift`, and `SettingsDataHelpPages.swift` with `AppModel.openProviderGuideLink(_:)` so every provider link opens in a new browser tab inside the app (completing onboarding and dismissing active Settings/setup sheets so the tab is immediately visible). Added `testProviderGuideHasNoBannedPricingOrPurchaseWords`, `testOpenProviderGuideLinkOpensTabAndDismissesModals`, and `testProviderKeyLinkOpensInAppBrowserTab`.
- **Why:** 3.1.1(a) outside the United States.
- **Files:** `WukongMind/AppModel+Onboarding.swift`, `WukongMind/SettingsProviderForm.swift`, `WukongMind/SettingsProviderPage.swift`, `WukongMind/SettingsDataHelpPages.swift`, `WukongMind/Localizable.xcstrings`.
- **Check:** a test over `ProviderGuide` strings for banned words; a UI check of where the link opens.

### Task 10: one vocabulary, a browser's (words and entry points)

- **What:** WukongMind's interface stops speaking as a forum app ([store-positioning.md](store-positioning.md), section 2, rows 1 to 3, 6, 8 to 10, 13 to 15, and row 5's wording if the owner keeps the digest). Start by listing the interface strings that speak as a forum app: forum, topic, thread, post, reply, community, discussion, "worth reading", and the platform names Discourse, WordPress and Hacker News (about 165 of 1,556 by a count of the first three and the platform names; the wider list adds about 54) and mark each reword, delete (unused, or a leftover of the deleted chat and research engines) or keep (true only of a discussion page). Then: one "Summarize this page" wording; "Search this site…" for "Search this forum…"; "What's new on this site" for "What's worth reading today" on a list page; "Follow this discussion"; "Read it to me" on ordinary pages too; "Ask a Site" and "Summarize Link" taking any address in Siri; share-sheet actions reworded and the platform badge deleted; "site" for "forum" in Settings, History, Sync and the request-pace footers. If the owner keeps the digest (task 12 answered no): its strings ("Daily digest & podcast", "Today's podcast", "Make the podcast every day", the Siri actions) are reworded to pinned sites and followed pages here, and the listing names the feature. If the owner removes it, task 12 deletes those strings and this task leaves them alone. English and both Chinese scripts. No behaviour changes and no new types; internal tool and type names stay.
- **Why:** 4.3(a). Forumind's listing must not also describe WukongMind's screens. Words are most of the difference a reviewer can see, and the engines are already general.
- **Size:** M (strings in three languages, intents, the share extension, and the tests that match on these strings).
- **Starts when:** the owner has answered on the digest (task 12).
- **Files:** `WukongMind/Localizable.xcstrings`, `WukongMind/AppShortcuts.xcstrings`, `WukongMind/SuggestionRow.swift`, `WukongMind/System/AppIntents.swift`, `WukongMindShare/ShareSheetView.swift`, `WukongMind/SettingsAssistantPages.swift`, `WukongMind/SettingsSyncPage.swift`, `WukongMind/HistoryView.swift`, `WukongMind/SettingsDataHelpPages.swift`, the tests that assert these strings.
- **Done when:** a search of the string catalogues for the same pattern as above (forum, topic, thread, post, reply, community, discussion, "worth reading", Discourse, WordPress, Hacker News, and digest, podcast and Today if the digest stays) finds only strings on the task's "keep" list, each with its reason; the unit and UI tests pass on `scripts/remote-test.sh`; screenshots of Home, the suggestion row on an article and on a discussion page, Settings and the share sheet are in the proof.

### Task 11: pinned sites, not forums; no forum picker

- **What:** store-positioning.md, section 2, rows 4 and 17. Settings › Forums becomes Sites: any address can be pinned to Home; the "doesn't look like a supported site" refusal (`WukongMind/ForumDirectory.swift:85`) is deleted; the "Suggested" list of well-known forums (`WukongMind/SettingsForumsPage.swift:69`, `SiteAdapter.suggestedForums`) is deleted in Settings; first run's step 2 shows the same forums (`WukongMind/OnboardingSteps.swift:260`) and gets a short mixed list of ordinary pages or the address field alone, whichever design-unified.md settles on. The three adapters stay as readers for the sites they recognise. A pinned site with no reader is a favourite and nothing more; say so in the design document rather than adding a second kind of pin. Update [design-unified.md](design-unified.md) (start page, Settings › Sites) in the same pull request.
- **Why:** 4.3(a). A list that accepts only three forum platforms is Forumind's home screen; a list of pinned sites is a browser's favourites.
- **Size:** M. The synced `Forum` record needs a kind for "no reader" (or an optional one); check `WukongMind/SyncRecords.swift` and older builds reading it.
- **Files:** `WukongMind/ForumDirectory.swift`, `WukongMind/SettingsForumsPage.swift`, `WukongMind/HomeSites.swift`, `WukongMind/HomeView.swift`, `WukongMind/OnboardingSteps.swift`, `WukongMind/Sites/SiteAdapter.swift` and the adapters' `suggestedForums`, `WukongMind/SyncRecords.swift`, `docs/wukongmind/design-unified.md`.
- **Done when:** a unit test pins an ordinary site and a recognised one and both appear on Home; a sync round-trip test covers a pin with no reader; no "Suggested" forums list remains; Home's first-frame time before and after is in the proof and is not slower; tests pass on `scripts/remote-test.sh`.

### Task 12 (needs the owner's yes): remove the daily digest from WukongMind

- **What:** store-positioning.md, section 2, row 5. Delete the Today module and page, the digest, its two-host podcast, the background prefetch task and the "Open Today's Digest" and "Play Today's Podcast" Siri actions, with their settings, strings and tests. Read aloud and following a discussion stay. Decide in the task what happens to digests already synced (recommended: stop reading and writing the record kind; leave the stored records alone). Update [next-phase.md](next-phase.md) sections 4 and 6 and design-unified.md, which keep Today on the start page, in the same pull request.
- **Why:** 4.3(a), and the owner's "what can be deleted?". The digest is the one screen that is Forumind and nothing else, it is not useful on any web page, and generalising it is new background work. It contradicts next-phase.md, so it waits for the owner.
- **Size:** M (1,624 lines in `DailyDigest.swift`, `DigestViews.swift` and `AppModel+Digest.swift`, plus the digest parts of `Podcast/` and the tests; mostly deletion).
- **Files:** `WukongMind/DailyDigest.swift`, `WukongMind/DigestViews.swift`, `WukongMind/AppModel+Digest.swift`, `WukongMind/HomeView.swift`, `WukongMind/Podcast/`, `WukongMind/System/AppIntents.swift`, `WukongMind/Info.plist` (the background task identifier), `WukongMind/SyncRecords.swift`, the two design documents.
- **Done when:** no Today entry point remains; the `processing` background mode is dropped if nothing else uses it (then say so in task 7's notes); Home's first-frame time before and after is in the proof; tests pass on `scripts/remote-test.sh`. If the owner says no instead: the digest's words are generalised in task 10 (which waits for this answer), the listing names it, and this task is closed unused. Either way the answer comes before task 10 starts, so the build never reaches submission with the forum digest untouched.

### Task 13 (Forumind's repository): Forumind's listing leaves "browser" to WukongMind

- **What:** store-positioning.md, section 3. In Forumind's listing: open with "an AI reader for forums" rather than "a forum browser"; remove 浏览器 / 瀏覽器 from the Chinese keywords; remove `wordpress` and `hacker news` from the en-US keywords (other parties' names, 2.3.7); add the mirrored relationship paragraph to its review notes. Submit Forumind before WukongMind.
- **Why:** 4.3(a) and 2.3.7: the two listings should not compete for the same words, and each note should name the other app.
- **Size:** S (metadata only; a write through `asc` or Forumind's `appstore/metadata`, read back).
- **Done when:** the saved values are read back from App Store Connect and match.

## 6. Code compliance audit (WUKO-168)

The full audit is [app-store-code-audit.md](app-store-code-audit.md): 15 findings with `file:line`, the list of what was searched and found clean, a check of the Release binary, and tasks B to E.

- **No blocker.** The Release binary uses no non-public API (checked with `scripts/audit-release-binary.sh` on two Release builds; a Debug build fails the same check, as it should). The share extension never opens the app. There is no remote configuration, no hidden gesture or menu, no launch argument honoured in Release.
- **Likely (4):** the Agent saves a script it wrote, on at once, unseen (task 4); the Agent can rewrite and turn on any saved script, imported ones included (task 4); `cookies_get` gives cookie values to the model, and `run_js` can read `document.cookie` unasked (task 1, done in WUKO-170); one default depended on the install source, `BuildChannel.isTestFlight` (audit task B, done in WUKO-173).
- **Question (9):** `run_js` runs unprompted, and "Confirm before writes" is off by default and does not cover page changes (tasks 1 and 4); the Agent's `notify` tool (task 4); the undocumented `shareddocuments://` link (fixed in audit task D); Safari's user agent (say it in the notes, task 8); live voice keeps running in the background (task 7); `remote-notification` declared without CloudKit (task 7); imported user scripts (notes); a test hook compiled into Release and a stale comment about the old share trick (fixed in audit task E).
- **Fine, noted (2):** the DEBUG-only Screen Time test helper that uses private selectors, and a test helper moved under `#if DEBUG` (audit task C — done in WUKO-171 — keeps the first out of Release; audit task E moved the second).

## Not verified

- Forumind was never approved (confirmed in App Store Connect, 2026-11-19: 1.0.0 is developer-rejected and the app is not on the store). The result of its 5.6 appeal is still not known: the Resolution Center is not readable through the API.
- What exactly triggered Forumind's 5.6 rejection: Apple named no feature.
- The exact questions App Store Connect asks today: only visible in App Store Connect.
- That a summary really works with Apple Intelligence and no key: the Summaries role accepts it in code; not run on a device here.
- The required-reason code `35F9.1` and that `systemUptime` is on Apple's list: from memory; Apple's page did not load as text. Check when doing task 7.
- That userscript managers are on the App Store today, and how Apple treated them: not checked.
- Apple's age ratings page was read only in part (the first 100,000 characters).
- Nothing was run on a device or simulator for this review; it is a reading of code, history and Apple's text.
