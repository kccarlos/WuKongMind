# App Store Listing & Review Materials

Source-of-truth App Store metadata and review answers for **WukongMind Browser** (`io.github.kccarlos.wukongmind`, Apple ID `6833832262`, target release `1.6.0`).

The Assistant syncs these files to App Store Connect with the `asc` CLI and reads every saved value back before submission.

## Layout

- `metadata/` — App Store Connect localized listing fields (`en-US`, `zh-Hans`, `zh-Hant`) plus top-level `copyright.txt`, `primary_category.txt` (`UTILITIES`), and `secondary_category.txt` (`PRODUCTIVITY`).
  - Store name: `WukongMind Browser` / `WukongMind 浏览器` / `WukongMind 瀏覽器` (home-screen `CFBundleDisplayName` stays `WukongMind`).
  - Support, privacy, and marketing URLs point to the live GitHub Pages site (`https://kccarlos.github.io/WuKongMind/`).
  - Support / review contact email is canonical in `site/config.json` (`support_email`) and `WukongMind/Info.plist` (`DCReportEmail`); contact name and phone number are entered directly in App Store Connect and kept out of git.
- `review/` — App Store Connect review answers:
  - `notes.txt` — App Review Information › Notes (plain text, <= 4,000 characters).
  - `reviewer_key.md` — Documented key path and placeholders (`REVIEWER_KEY_TBD`) filled in at submission time.
  - `privacy_label.md` — App Privacy answers (`Data Not Collected`).
  - `age_rating.md` — Age Rating answers (`16+`, Unrestricted Web Access = Yes, User-Generated Content = Yes).
  - `content_rights.md` — Content rights, categories, pricing, and territory availability (exclude China mainland).
  - `export_compliance.md` — Export compliance (`ITSAppUsesNonExemptEncryption = false`).

## Validation

Run the metadata check script locally (also wired into the `lint` job in `.github/workflows/ci.yml`):

```sh
scripts/ci/check-appstore-metadata.sh
```

It validates required files, all three locales (`en-US`, `zh-Hans`, `zh-Hant`), App Store Connect character limits (including `review/notes.txt`), keyword formatting, banned words from `docs/wukongmind/store-positioning.md`, HTTPS URLs, and screenshot dimensions/opacity once screenshots are added.

## Screenshots

Per `docs/wukongmind/store-positioning.md` section 3, WukongMind's screenshots are captured directly from the shipping UI in light mode using offline `#if DEBUG` fixtures (`WukongMind/StoreScreenshotContent.swift` — invented non-forum articles and pages only, no network, no API keys, no real people or brands, no forum threads, no daily digest):

1. `01-change-page.png` — **Change any page:** News-style article with the ask box ("Make it dark and hide the sidebar") and the changed dark page.
2. `02-agent-steps.png` — **Agent steps:** The Agent's expanded tool steps in the conversation while modifying the page.
3. `03-script-approval.png` — **Script approval:** The shared script approval sheet when saving a reusable page change.
4. `04-tabs-navigation.png` — **Browser navigation:** The tab overview with four invented non-forum web pages.
5. `05-summarize-read-aloud.png` — **Summarize & read aloud:** "Summarize this page" with Read aloud on an ordinary article.
6. `06-ipad-split.png` *(iPad only)* — **iPad split workspace:** A web page and the Agent panel side by side.

Final opaque RGB PNGs live under `appstore/screenshots/<locale>/<device>/NN-name.png` (`en-US`, `zh-Hans`, `zh-Hant`; `iphone` at `1320×2868` for 6.9" iPhone, `ipad` at `2752×2064` landscape for 13" iPad).

### Regenerating screenshots

Run `WukongMindUITests/AppStoreScreenshotTests` on the Mac mini's native 6.9" iPhone and 13" iPad simulators with a clean status bar, extract the XCTAttachments into `appstore/screenshots/`, and validate:

```sh
scripts/remote-test.sh --sim iphone-69 --clean-status-bar \
  --out /Volumes/Ext/dev/build/wukongmind-dd/store-shots-iphone \
  -only-testing:WukongMindUITests/AppStoreScreenshotTests

scripts/remote-test.sh --sim ipad-13 --clean-status-bar \
  --out /Volumes/Ext/dev/build/wukongmind-dd/store-shots-ipad \
  -only-testing:WukongMindUITests/AppStoreScreenshotTests

scripts/extract-appstore-screenshots.py \
  /Volumes/Ext/dev/build/wukongmind-dd/store-shots-iphone/test.xcresult \
  /Volumes/Ext/dev/build/wukongmind-dd/store-shots-ipad/test.xcresult

scripts/ci/check-appstore-metadata.sh
```
