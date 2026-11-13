# Privacy

**WukongMind** ([kccarlos/WuKongMind](https://github.com/kccarlos/WuKongMind)) is a self-use, open-source iOS and iPadOS browser with an AI agent, built from source with your own Apple developer account and not distributed on the App Store.

**The maintainer collects nothing.** There are no WukongMind servers, accounts, analytics, telemetry, crash-reporting SDKs, advertising, or tracking.

## Where data goes

- **Websites you visit:** Pages load directly in `WKWebView` from each site, with cookies and logins stored locally on your device by WebKit and sent only to their own site. Built-in forum adapters read directly from Discourse and WordPress endpoints (reusing your site session where supported) and from Algolia's public Hacker News API (`hn.algolia.com`) for Hacker News.
- **Your AI and speech providers (BYOK):** When you run the browser agent, summaries, chat, Ask the forum, daily digests, podcast scripts, Gemini text-to-speech, or Gemini Live voice sessions, the relevant page or forum content (and live microphone audio during a voice session) is sent directly from your device to the provider you configured:
  - Hosted APIs (OpenRouter, OpenAI, Anthropic, Google Gemini, Google Vertex AI, Groq, xAI, DeepSeek, NVIDIA NIM) using your own API key, governed by that provider's terms and privacy policy.
  - Local network servers (Ollama or LM Studio) on your LAN.
  - Apple Intelligence (on-device or Apple Private Cloud Compute, where available).
- **Local storage and Keychain:** Conversations, summaries, per-site userscripts (`ScriptStore`), watched topics, digests, cached podcast audio, and settings are stored locally on your device. Provider API keys live in the iOS Keychain (and optionally sync across your own devices via end-to-end encrypted iCloud Keychain), never in plaintext app state files.
- **Optional iCloud sync (CloudKit):** Disabled by default in source builds (`DC_ENABLE_CLOUDKIT=NO`). When enabled in your own signed build, app records sync through your own iCloud account's private CloudKit database using encrypted fields.
- **On-device features:** Optional ad and tracker blocking uses bundled EasyList and EasyPrivacy rules compiled locally in WebKit. Spotlight indexing, Siri suggestions and Shortcuts, local notifications, and Apple on-device Translation all run locally on your device.

For risks around active web logins and untrusted page content when running the agent, see the [Risk Statement in README.md](README.md#risk-statement).
