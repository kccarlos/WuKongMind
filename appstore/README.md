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

## Screenshot Plan (separate task — no images yet)

Per `docs/wukongmind/store-positioning.md` section 3, WukongMind's screenshots show what an AI-assisted general browser does on ordinary web pages (invented content only, no real people's posts, no forum threads, no daily digest):

1. **Change any page:** A news-style article with the ask box ("Make it dark") and the changed page.
2. **Agent steps:** The Agent's tool steps in the conversation while modifying a page.
3. **Script approval & management:** The script approval sheet, or Settings › Scripts with per-site switches.
4. **Browser navigation:** The tab overview and the address bar.
5. **Summarize & read aloud:** "Summarize this page" with Read aloud on an ordinary article.
6. **iPad split workspace:** A web page and the Agent side by side on iPad.

When the screenshot task runs, place final opaque PNG/JPEG files in `appstore/screenshots/<locale>/` (`en-US`, `zh-Hans`, `zh-Hant`) with `iphone*` (6.9"/6.7") and `ipad*` (13"/12.9") filename prefixes; `scripts/ci/check-appstore-metadata.sh` will automatically validate dimensions, alpha channel, and per-locale counts.
