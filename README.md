# WukongMind (悟空)

<p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="License: Apache-2.0"></a>
  <img src="https://img.shields.io/badge/iOS_%7C_iPadOS-17%2B-000000?logo=apple&logoColor=white" alt="iOS and iPadOS 17 or later">
  <img src="https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/Made_with-SwiftUI-2396F3?logo=swift&logoColor=white" alt="Made with SwiftUI">
</p>

<p>
  <b>English</b> · <a href="README.zh-Hans.md">简体中文</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

**WukongMind** (悟空) is an open-source, self-use browser for iPhone and iPad whose AI agent reads and changes any web page by running JavaScript and injecting CSS, and saves its changes as per-site userscripts (like Tampermonkey).

- **Self-use, not on the App Store.** WukongMind is forked from [Forumind](https://github.com/kccarlos/forumind), which keeps its AI read-only and scoped to supported forum platforms to pass App Store review. WukongMind is not distributed on the App Store or public TestFlight: you build and sign it from source with your own Apple developer account, with App Store capability restrictions removed.
- **Code-driven page agent.** The AI never touches the page directly. It writes code; the app runs that code inside `WKWebView` and returns the result in a tool-calling loop until the task is done.
- **Bring your own key (BYOK).** There is no WukongMind backend, account, analytics, or proxy. API keys live in the iOS Keychain, and requests go straight from your device to the model provider (or a local server on your LAN).
- **Current status:** `M1` is shipped (agent chat panel and in-page tools on any site); `M2` (saving and auto-injecting per-site userscripts) is in progress. See [Status](#status).

---

## Risk Statement

> [!WARNING]
> **Web content can steer the agent, and the agent can use every login in the app. Do not log in to banking, payment, or main email accounts in WukongMind.**

Understand the security model before signing in to websites or running the agent:

- **Prompt injection and active sessions:** Untrusted text on a web page can steer the model into unintended actions, and the agent operates inside the same `WKWebView` cookie and session store as your browsing. Any site you are signed in to inside WukongMind is reachable by the agent. Avoid logging in to banking, payment, primary email, or other high-value accounts.
- **Full power in the page (`run_js`):** By default there are **no confirmation prompts and no risk tiers** — the agent calls tools directly, and `run_js` has unrestricted JavaScript execution power inside the current page (DOM reads and writes, page globals in the `page` world, forms, and same-origin requests).
- **Optional write confirmation (planned):** An optional **"Confirm before writes"** switch in Settings (off by default; prompts before `http_request`, `cookies_get`, and actions that submit forms) is planned for a later milestone (`M3`) and is **not yet implemented**.
- **Built-in safety baselines:**
  - **Bridge isolation:** The app–page message channel (`WKScriptMessageHandlerWithReply`) is registered only in an isolated `WKContentWorld`, invisible to page scripts so pages cannot call native tools or forge tool results.
  - **Key isolation:** Provider API keys stay in the iOS Keychain, never enter the page context or conversation history, and are redacted if they ever appear in tool output.
  - **Untrusted content delimiters:** Web page output returned to the model is wrapped in `<untrusted_web_content>` delimiters, and the system prompt instructs the model never to follow instructions found inside page content.
  - **Stop any time:** A **Stop** button stays visible for the entire run and cancels the loop immediately; runs also stop at a configurable step limit (`30` steps by default). A global userscript switch (`M2`) and on-disk tool audit log (`M3`) are on the roadmap below.

---

## Status

WukongMind is built in sequential milestones ([docs/wukongmind/requirements.md](docs/wukongmind/requirements.md)):

| Milestone | Status | Scope |
| :--- | :--- | :--- |
| **M0 — Survey** | **Shipped** | Forumind module map ([m0-module-map.md](docs/wukongmind/m0-module-map.md)) and `WKWebView` CSP / execution-world verification ([m0-csp-and-worlds.md](docs/wukongmind/m0-csp-and-worlds.md)). |
| **M1 — Core loop** | **Shipped** | General address bar on any site, **Agent** chat panel (bottom drawer on iPhone, resizable split panel on iPad) and toolbar button, `AgentLoop` with native tool calling, Stop button, token count, and in-page tools (`read_page`, `run_js`, `inject_css`, `wait_for`). |
| **M2 — Persistence** | **In progress** | Per-site userscripts (`ScriptStore`, `.user.js` files with `// ==UserScript==` headers and `@match` rules), script tools (`script_save`, `script_list`, `script_read`, `script_update`, `script_delete`), automatic injection on load and SPA route changes, script manager UI, toolbar badge, and global script switch. |
| **M3 — Full abilities** | Planned | `screenshot` (vision), `network_log`, `navigate`, multi-tab `tabs`, cross-origin `http_request`, `cookies_get` (including `httpOnly`), workspace `file_read` / `file_write`, on-disk `AuditLog` UI, and optional "Confirm before writes" mode. |
| **M4 — Self-extension & Tampermonkey** | Planned | `GM_addStyle`, `GM_getValue`, `GM_setValue`, `GM_xmlhttpRequest`, userscript import from URL, one-tap "let the agent fix" on script errors, `notify`, and iCloud sync for scripts. |

---

## How It Works

### Browser agent (`M1`)

1. Open any web page and tap the **✦** button in the browser bar (or use the side-by-side panel on iPad) to open **Agent** mode.
2. Describe what you want to read or change (for example, *"make this page dark and hide the sidebar"*).
3. The app sends your prompt, the system prompt, tool schemas, and the page's URL and title to your selected model. The model proposes tool calls, the app runs them in `WKWebView` via `callAsyncJavaScript`, and each tool call appears as an expandable row with arguments, duration, and result summary.
4. Tools run in an **isolated `WKContentWorld`** by default (full DOM access, unaffected by page `eval` / `connect-src` CSP, invisible to page JS) or in the **`page` world** when inspecting or mutating page JS state. Stylesheets are applied through `adoptedStyleSheets` so strict `style-src` policies do not block them.

| In-page tool (`M1`) | Purpose |
| :--- | :--- |
| `read_page` | Condensed DOM structure summary, plain text, or HTML (optional CSS selector and length limit). |
| `run_js` | Async JavaScript execution (`await` supported, 10 s default timeout) in `isolated` or `page` world; returns JSON value, console output, and errors. |
| `inject_css` | Injects CSS via `adoptedStyleSheets` across the document and open shadow roots. |
| `wait_for` | Waits for a CSS selector to appear or for a delay in milliseconds. |

### Inherited from Forumind

WukongMind keeps Forumind's existing forum features working beside the new **Agent** mode:

- **Discourse, WordPress, and Hacker News support:** Long-thread hierarchical **Summaries**, topic **Chat**, site-wide **Ask the forum** with numbered citations, watched-topic notifications, daily digest, two-host podcast, and Gemini Live voice mode.
- **Ad and tracker blocking:** Optional `WKContentRuleList` blocker built from EasyList and EasyPrivacy (off by default; toggle in **Settings › Browser**).
- **Localization:** English, Simplified Chinese (`zh-Hans`), and Traditional Chinese (`zh-Hant`).

---

## Bring Your Own Key (BYOK)

WukongMind talks directly from your device to the AI provider you configure — there are no WukongMind servers or accounts.

- **Keychain storage:** API keys are saved in the iOS Keychain (and optionally synced across your own devices via iCloud Keychain). Keys are stripped from on-disk app state and never exposed to web pages or agent tools.
- **Dedicated Browser Agent model:** No model is preset for the **Browser agent** (`Settings › AI models › Browser agent`). On first use, pick any model from a provider that supports native tool calling, independent of the models chosen for **Summaries & chat** and **Ask the forum**.

| Provider | Credentials | Notes |
| :--- | :--- | :--- |
| **OpenRouter** | API key | Single key across many tool-calling models |
| **OpenAI** | API key | GPT models |
| **Anthropic** | API key | Claude models |
| **Google Gemini** | API key | Gemini models (AI Studio) |
| **Google Vertex AI** | Vertex AI API key | Gemini models billed to your Google Cloud project |
| **Groq** | API key | Fast open-weight models |
| **xAI** | API key | Grok models |
| **DeepSeek** | API key | DeepSeek models |
| **NVIDIA NIM** | API key | OpenAI-compatible hosted models |
| **Ollama** | None (LAN URL, e.g. `http://192.168.1.20:11434`) | Local models on your own computer |
| **LM Studio** | None (LAN URL, e.g. `http://192.168.1.20:1234/v1`) | Local models on your own computer |
| **Apple Intelligence** | None (on-device / Private Cloud Compute) | Available for inherited forum **Summaries & chat** and **Ask the forum** only (not general browser-agent tool calling) |

---

## Build and Install from Source

### Requirements

- A Mac running **Xcode 27** (`Xcode 27.2` in CI; iOS / iPadOS **17.0+** deployment target).
- **Ruby** with the **`xcodeproj`** gem (`gem install --user-install xcodeproj` with macOS system Ruby, or `gem install xcodeproj` with your Ruby manager).
- An Apple account (a free Apple ID personal team or a paid Apple Developer Program team) to sign and install on a physical iPhone or iPad. Simulator builds need no signing account.
- No Swift packages, CocoaPods, or Carthage dependencies.

> **Generated Xcode project:** `WukongMind.xcodeproj` (scheme **`WukongMind`**) is generated by `scripts/generate_project.rb` (`CFBundleDisplayName = WukongMind`, URL scheme `wukongmind://`). Always change build settings in `scripts/generate_project.rb`, not in Xcode's UI — regenerating overwrites manual `.xcodeproj` edits.

### 1. Run in the iOS Simulator

```sh
git clone https://github.com/kccarlos/WuKongMind.git
cd WuKongMind
gem install --user-install xcodeproj
ruby scripts/generate_project.rb
open WukongMind.xcodeproj
```

In Xcode, select the **WukongMind** scheme and any iPhone or iPad Simulator, then press **Run** (`⌘R`). (If Xcode warns about the default signing team before you have added an account, generate with `DEVELOPMENT_TEAM="" ruby scripts/generate_project.rb`.)

To build unsigned from the command line:

```sh
destination="$(scripts/ci/pick-simulator.sh)"
xcodebuild build \
  -project WukongMind.xcodeproj \
  -scheme WukongMind \
  -destination "$destination" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

### 2. Build and install on your iPhone or iPad

Apple bundle identifiers are globally unique across all developer accounts. Because `scripts/generate_project.rb` defaults to `io.github.kccarlos.wukongmind`, **installing on a physical device with your own Apple team requires setting both your Team ID and your own reverse-DNS `BUNDLE_ID_PREFIX`**.

1. Find your 10-character **Team ID** in **Xcode › Settings › Accounts** or at [developer.apple.com/account](https://developer.apple.com/account) under Membership details (or sign in with a free Apple ID in **Xcode › Settings › Accounts**).
2. Configure your Team ID and regenerate `WukongMind.xcodeproj` with your own `BUNDLE_ID_PREFIX`:

   ```sh
   # Option A: keep your Team ID in Config/DevelopmentTeam.txt (git-ignored)
   cp Config/DevelopmentTeam.example.txt Config/DevelopmentTeam.txt
   # Edit Config/DevelopmentTeam.txt and replace ABCDE12345 with your 10-character Team ID
   BUNDLE_ID_PREFIX=com.example.wukongmind ruby scripts/generate_project.rb

   # Option B: pass both as environment variables (DEVELOPMENT_TEAM overrides the file)
   DEVELOPMENT_TEAM=ABCDE12345 BUNDLE_ID_PREFIX=com.example.wukongmind \
     ruby scripts/generate_project.rb
   ```

   `BUNDLE_ID_PREFIX` updates every target and identifier together (`<prefix>` for the app, `<prefix>.share` for the share extension, `group.<prefix>`, `iCloud.<prefix>`, Keychain service names, background task IDs, and test bundles).

3. Open `WukongMind.xcodeproj`, connect your iPhone or iPad, pick the **WukongMind** scheme and your device, and press **Run** (`⌘R`).
4. On first install on iOS/iPadOS, turn on **Developer Mode** if prompted (**Settings › Privacy & Security › Developer Mode**) and trust your developer certificate under **Settings › General › VPN & Device Management**.

#### Capabilities and free vs. paid Apple teams

- **Works out of the box on free personal teams:** In `scripts/generate_project.rb`, `DC_ENABLE_SHARE_EXTENSION`, `DC_ENABLE_APP_GROUP`, `DC_ENABLE_CLOUDKIT`, and `DC_ENABLE_PCC` all default to `NO` (see [docs/wukongmind/README.md](docs/wukongmind/README.md)). Signed device builds use empty base entitlements, so both free Apple ID personal teams (7-day app expiry; reinstall from Xcode) and paid teams build and install without portal setup.
- **Optional Share Extension and iCloud Sync (paid team required):** After registering `group.<prefix>` and `iCloud.<prefix>` on the Apple Developer portal, enable them with:

  ```sh
  DEVELOPMENT_TEAM=ABCDE12345 \
  BUNDLE_ID_PREFIX=com.example.wukongmind \
  DC_ENABLE_SHARE_EXTENSION=YES \
  DC_ENABLE_CLOUDKIT=YES \
    ruby scripts/generate_project.rb
  ```

- **Contributing back:** Never commit `WukongMind.xcodeproj` generated with your own `DEVELOPMENT_TEAM`, `BUNDLE_ID_PREFIX`, or `DC_ENABLE_*` flags. Move `Config/DevelopmentTeam.txt` aside and run `env -u DEVELOPMENT_TEAM -u BUNDLE_ID_PREFIX ruby scripts/generate_project.rb` before committing project changes so CI's `scripts/ci/check-project-drift.sh` passes.

---

## Tests and Checks

Run the simulator-free macOS core unit tests (`AgentLoop` and `ToolRegistry`):

```sh
xcodebuild test \
  -project WukongMind.xcodeproj \
  -scheme WukongMindAgentCoreTests \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

Run the full iOS Simulator unit test suite (matching `.github/workflows/ci.yml`):

```sh
destination="$(scripts/ci/pick-simulator.sh)"
xcodebuild test \
  -project WukongMind.xcodeproj \
  -scheme WukongMind \
  -destination "$destination" \
  -only-testing:WukongMindTests \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

Run the repository lint and project-drift checks:

```sh
scripts/ci/lint-plists.sh
scripts/ci/check-project-drift.sh
scripts/ci/check-site-layering.sh
scripts/i18n/check-catalogs.py
scripts/adblock/run_tests.sh
```

---

## Documentation

### WukongMind

- [docs/wukongmind/README.md](docs/wukongmind/README.md) — fork overview and build capability defaults
- [docs/wukongmind/requirements.md](docs/wukongmind/requirements.md) — product requirements, tool specs, script system, safety boundaries, and milestones (`M0`–`M4`)
- [docs/wukongmind/m0-module-map.md](docs/wukongmind/m0-module-map.md) — Forumind module map and file-level milestone change list
- [docs/wukongmind/m0-csp-and-worlds.md](docs/wukongmind/m0-csp-and-worlds.md) — `WKWebView` Content Security Policy and `WKContentWorld` verification
- [docs/wukongmind/design-m1.md](docs/wukongmind/design-m1.md) — `M1` agent chat panel and browser toolbar design

### Inherited Forumind docs

The architectural and development guides below are inherited from Forumind and still apply to shared subsystems (note that WukongMind's default bundle prefix and `DC_ENABLE_*` defaults follow `scripts/generate_project.rb` as documented above):

- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — signing details, UI tests, String Catalog localization, DEBUG launch arguments
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — app state, browser shell, site adapters, voice, and podcast architecture
- [docs/ADDING_A_SITE.md](docs/ADDING_A_SITE.md) — adding a forum/site adapter
- [docs/AD_BLOCKING.md](docs/AD_BLOCKING.md) — EasyList / EasyPrivacy content-blocking pipeline
- [docs/SYNC.md](docs/SYNC.md) — CloudKit sync engine and encryption
- [docs/APPLE_INTELLIGENCE.md](docs/APPLE_INTELLIGENCE.md) — on-device and Private Cloud Compute integration
- [docs/CI.md](docs/CI.md) — GitHub Actions workflows

---

## Credits and License

WukongMind is forked from **[Forumind](https://github.com/kccarlos/forumind)** (`Copyright 2026 kccarlos and Forumind contributors`) and is licensed under the **[Apache License 2.0](LICENSE)**.

- Optional ad and tracker blocking uses rules derived from [EasyList and EasyPrivacy](https://easylist.to/), licensed under CC BY-SA 3.0; see [NOTICE](NOTICE).
- See [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) (open issues and pull requests in [kccarlos/WuKongMind](https://github.com/kccarlos/WuKongMind)).
- WukongMind is an independent open-source project and is not affiliated with or endorsed by Civilized Discourse Construction Kit, Inc. ("Discourse"), WordPress, Hacker News, or Tampermonkey.
