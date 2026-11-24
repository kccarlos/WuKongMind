# Privacy Policy

**WukongMind Browser** ([kccarlos/WuKongMind](https://github.com/kccarlos/WuKongMind)) is an open-source AI-assisted web browser for iPhone and iPad.

**The developer collects no data from this app.** There are no WukongMind servers, user accounts, analytics, telemetry, crash-reporting SDKs, advertising, or cross-app tracking.

## Where your data goes

- **Websites you visit:** Pages load directly in `WKWebView` from each site. Cookies, site storage, and website logins are stored locally on your device by WebKit and sent only to their own sites. Built-in site readers fetch directly from Discourse and WordPress endpoints (reusing your site session where supported) and from Algolia's public Hacker News API (`hn.algolia.com`) for Hacker News.
- **Your AI and speech providers (BYOK):** When you use the browser Agent, summaries, site search, daily digests, podcast scripts, read aloud, Gemini text-to-speech, Gemini Live voice sessions, or userscripts that call `GM_ai`, the relevant page content or questions (and live microphone audio while a voice session is active) are sent directly from your device to the provider you configured:
  - Hosted APIs (OpenRouter, OpenAI, Anthropic, Google Gemini, Google Vertex AI, Groq, xAI, DeepSeek, NVIDIA NIM) using your own API key, governed by that provider's terms and privacy policy.
  - Local network servers (Ollama or LM Studio) on your own LAN.
  - Apple Intelligence (on-device or Apple Private Cloud Compute, where available on your device; used for summaries).
- **Optional iCloud sync (CloudKit):** Disabled by default in builds without iCloud entitlements (`DC_ENABLE_CLOUDKIT=NO`). When enabled, app records sync through your own private Apple iCloud CloudKit database using encrypted fields; the developer cannot access or read them.
- **Diagnostic exports:** Any problem report or task export you generate is saved to your own device or your own iCloud Drive. Nothing is sent to the developer unless you choose to share the file yourself.
- **On-device features:** Optional ad and tracker blocking uses bundled EasyList and EasyPrivacy filter lists compiled locally in WebKit. Spotlight indexing, Siri Suggestions and Shortcuts, local notifications, and Apple on-device Translation all run locally on your device.

## Storage and retention

- **Local app data:** Conversations, summaries, per-site userscripts (`ScriptStore`), watched discussions, digests, cached podcast audio, and settings are stored locally on your device until you clear them or uninstall the app.
- **API keys:** Provider API keys live in the iOS Keychain (and optionally sync across your own devices via end-to-end encrypted iCloud Keychain), never in plaintext app state files.
- **Third-party AI providers:** Data sent to a hosted AI provider is retained and handled according to that provider's own terms and privacy policy.

## Withdrawing consent and deleting data

- **Stop using an AI provider:** Remove or replace a provider's API key at any time in **Settings › Models**, or remove all keys via **Settings › Data & privacy › Reset Settings to Defaults…**.
- **Delete saved app data:** Clear saved summaries, chats, and site data per site or all at once in **Settings › Data & privacy**. View, turn off, or delete saved userscripts in **Settings › Scripts & tools**.
- **Delete everything locally:** Uninstalling WukongMind deletes all local app data from your device.

## Security

For risks around active web logins and untrusted page content when running the Agent, see [SECURITY.md](SECURITY.md) and the [Risk Statement in docs/DEVELOPER.md](docs/DEVELOPER.md#risk-statement).

## Contact

For privacy questions or support, visit the [WukongMind Support page](https://kccarlos.github.io/WuKongMind/support/) or open an issue at <https://github.com/kccarlos/WuKongMind/issues>.
