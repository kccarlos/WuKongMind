<div align="center">
  <img src="docs/brand/wukongmind-icon-1024.png" width="120" height="120" alt="WukongMind app icon">
  <h1>WukongMind Browser</h1>
  <p><strong>Make any web page work your way.</strong></p>
  <p>Too cluttered, too hard to read, too long? Say what you want in one sentence. The Agent changes the page in front of you, and keeps the change only if you approve it.</p>

  <p>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="License: Apache-2.0"></a>
    <img src="https://img.shields.io/badge/iOS_%7C_iPadOS-17%2B-000000?logo=apple&logoColor=white" alt="iOS and iPadOS 17 or later">
    <img src="https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white" alt="Swift">
    <img src="https://img.shields.io/badge/Made_with-SwiftUI-2396F3?logo=swift&logoColor=white" alt="Made with SwiftUI">
  </p>

  <p>
    <b>English</b> · <a href="README.zh-Hans.md">简体中文</a> · <a href="README.zh-Hant.md">繁體中文</a>
  </p>
</div>

<div align="center">

[![Try the beta on TestFlight](https://img.shields.io/badge/Try_the_beta_on_TestFlight-e0b040?style=for-the-badge&logo=apple&logoColor=1a1612)][testflight]
[![Website](https://img.shields.io/badge/Website-1a1612?style=for-the-badge)](https://kccarlos.github.io/WuKongMind/)
[![Developer Guide](https://img.shields.io/badge/Developer_Guide-5f574c?style=for-the-badge)](docs/DEVELOPER.md)

</div>

---

## In the app

<table>
  <tr>
    <td align="center" width="33%">
      <img src="appstore/screenshots/en-US/iphone/01-change-page.png" width="260" alt="An article turned dark after asking the Agent to make it dark and hide the sidebar"><br>
      <sub>Change a page by asking</sub>
    </td>
    <td align="center" width="33%">
      <img src="appstore/screenshots/en-US/iphone/02-agent-steps.png" width="260" alt="The Agent listing every step as it runs"><br>
      <sub>See every step</sub>
    </td>
    <td align="center" width="33%">
      <img src="appstore/screenshots/en-US/iphone/03-script-approval.png" width="260" alt="The Add script sheet showing matching sites and full code before saving"><br>
      <sub>Approve before saving a script</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="33%">
      <img src="appstore/screenshots/en-US/iphone/04-tabs-navigation.png" width="260" alt="Tab overview with open web pages"><br>
      <sub>Tabs and overview</sub>
    </td>
    <td align="center" width="33%">
      <img src="appstore/screenshots/en-US/iphone/05-summarize-read-aloud.png" width="260" alt="Page summary with the Read aloud player"><br>
      <sub>Summarize and read aloud</sub>
    </td>
    <td align="center" width="33%">
      <img src="appstore/screenshots/en-US/iphone/06-browser-bar.png" width="260" alt="Browser bar with the gold Agent ring"><br>
      <sub>One gold ring in the browser bar</sub>
    </td>
  </tr>
</table>

<p align="center">
  <img src="appstore/screenshots/en-US/ipad/06-ipad-split.png" width="780" alt="iPad split view showing a web page and the Agent panel side by side"><br>
  <sub>On iPad, the web page and the Agent sit side by side</sub>
</p>

---

## What you can do

- **Clean up any page** — hide banners, sidebars, and pop-ups, or switch a bright site to dark mode and larger text with a single sentence.
- **Keep what works for your next visit** — save a fix as a small per-site script so it runs automatically every time you open that site, only after you review and approve it.
- **Summarize and listen** — get the main points of a long article or discussion thread, ask follow-up questions, or listen with Read aloud and live voice.
- **Watch every step** — see each change as it happens, with **Stop** always on screen.
- **Use it as a full browser** — tabs, pinned sites, history, on-device translation (iOS 18+), optional ad and tracker blocking, and side-by-side browsing on iPad.

---

## Private by design · Bring your own key

There are no WukongMind accounts, servers, analytics, or tracking. Your API keys live in the iOS Keychain (with optional iCloud Keychain sync), and requests go straight from your device to the AI provider you choose — or to a local model on your own network.

- **Cloud (API key):** OpenRouter, OpenAI, Anthropic, Google Gemini, Google Vertex AI, Groq, xAI (Grok), DeepSeek, NVIDIA NIM.
- **Local network (no key):** Ollama, LM Studio.
- **On-device (Summaries only):** Apple Intelligence.

---

## Safety

> [!WARNING]
> **Web content can steer the agent, and the agent can use every login in the app. Do not log in to banking, payment, or main email accounts in WukongMind.**

- **Every step is shown and stoppable** — actions are listed as they happen, and **Stop** stays on screen for the entire run.
- **Asks before sensitive actions** — by default the Agent asks before sending network requests, posting notifications, reading cookies, or sending your login to another site.
- **Scripts are saved only with your approval** — before anything is kept, you see which sites it runs on, what it can use, and its full code.

For bridge isolation, key isolation, content delimiters, and the full threat model, see [docs/DEVELOPER.md](docs/DEVELOPER.md#risk-statement) and [SECURITY.md](SECURITY.md).

---

## Developers & License

- **Builds & releases:** Native SwiftUI app for iPhone and iPad (iOS / iPadOS 17+) with zero third-party dependencies, localized in English, Simplified Chinese (`zh-Hans`), and Traditional Chinese (`zh-Hant`). Try the beta on [TestFlight][testflight], or build from source with automated CI checks on every change.
- **Developers:** Build from source, run tests, and explore milestone status, tool internals, and architecture docs in **[docs/DEVELOPER.md](docs/DEVELOPER.md)**.
- **Policies & community:** [LICENSE](LICENSE) · [PRIVACY.md](PRIVACY.md) · [SECURITY.md](SECURITY.md) · [CONTRIBUTING.md](CONTRIBUTING.md) · [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) · [NOTICE](NOTICE).
- WukongMind is forked from **[Forumind](https://github.com/kccarlos/forumind)** (`Copyright 2026 kccarlos and Forumind contributors`) and is licensed under the **[Apache License 2.0](LICENSE)**. Optional ad and tracker blocking uses rules derived from [EasyList and EasyPrivacy](https://easylist.to/) (CC BY-SA 3.0; see [NOTICE](NOTICE)).
- WukongMind is an independent open-source project and is not affiliated with or endorsed by Civilized Discourse Construction Kit, Inc. ("Discourse"), WordPress, Hacker News, or Tampermonkey.

<p align="center">
  <img src="docs/wukongmind/design/design-system/assets/Mascot/wave.svg" width="64" alt="WukongMind mascot waving"><br>
  <sub>Make any web page work your way — see the <a href="docs/wukongmind/design/design-system/README.md">design system</a> for tokens, ring states, and component specs.</sub>
</p>

[testflight]: https://testflight.apple.com/join/t5RNVr7M
