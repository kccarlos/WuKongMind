# Reviewer Test Key Path

App Store Connect › App Review Information › Notes (text only; never commit a real key to this repository).

- **Path in app:** `Settings > Models > Providers & keys > [PROVIDER_TBD] > API key: REVIEWER_KEY_TBD`
- **Verified by UI test:** `WukongMindUITests/SettingsNavigationUITests/testDocumentedReviewKeyPathSavesAPIKey`
- **Placeholder values to fill at submission time (owner decision):**
  - `[PROVIDER_TBD]` — chosen provider for the spend-capped review key (e.g. Google Gemini so live voice also works, or another tool-calling provider).
  - `[MODEL_TBD]` — recommended tool-calling model for that provider.
  - `REVIEWER_KEY_TBD` — fresh spend-capped API key created solely for App Review and revoked immediately after approval. Never reuse a personal key.
- **Attachments:** Real-device screen recording from launch showing Terms acceptance, pasting the key, summarizing a page, Agent page edit + script approval sheet, and "Report this answer".
- **Contact email:** Use `support_email` from `site/config.json` (also `DCReportEmail` in `WukongMind/Info.plist`); keep contact name and phone number in App Store Connect only (not in git).
