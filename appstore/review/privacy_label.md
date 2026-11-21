# App Privacy (Privacy Label) Answers

App Store Connect › App Privacy.

- **Do you or your third-party partners collect data from this app?** `No` (**Data Not Collected**)
- **Privacy Policy URLs:**
  - `en-US`: `https://kccarlos.github.io/WuKongMind/privacy/`
  - `zh-Hans`: `https://kccarlos.github.io/WuKongMind/zh-Hans/privacy/`
  - `zh-Hant`: `https://kccarlos.github.io/WuKongMind/zh-Hant/privacy/`
- **Matches privacy manifest:** `WukongMind/PrivacyInfo.xcprivacy` (`NSPrivacyTracking = false`, `NSPrivacyCollectedDataTypes = []`).

## Justification per data flow

| Flow | Recipient | Collected by developer? |
|---|---|---|
| Web pages | The website the user opens in `WKWebView` | No (general web browser) |
| Page text, questions, live voice audio | The AI service configured by the user with their own API key or LAN server | No (user's own account with that third party, not a partner of the developer) |
| Optional iCloud sync | The user's private CloudKit database | No (developer cannot access or read it) |
| Diagnostic / problem exports | Saved to the user's device or personal iCloud Drive | No (never transmitted unless the user sends it themselves) |
| "Report this answer" / "Report this summary" | User's own Mail composer (or `mailto:` / Copy / Share fallback) addressed to `DCReportEmail` | No (the app does not transmit over the network; voluntary user-initiated email only) |
| API keys | iOS Keychain (and optional iCloud Keychain) | No |

## Fallback if App Review asks about user-initiated report emails

If App Review treats voluntary user-initiated report emails as collected data, update the label to add:
- **Contact Info › Email Address** — App Functionality, not linked to the user's identity, not used for tracking.
- **User Content › Other User Content** — App Functionality, not linked to the user's identity, not used for tracking.
