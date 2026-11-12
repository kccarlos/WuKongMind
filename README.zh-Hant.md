# WukongMind (悟空)

<p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="授權條款：Apache-2.0"></a>
  <img src="https://img.shields.io/badge/iOS_%7C_iPadOS-17%2B-000000?logo=apple&logoColor=white" alt="iOS 與 iPadOS 17 或以上版本">
  <img src="https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/Made_with-SwiftUI-2396F3?logo=swift&logoColor=white" alt="以 SwiftUI 打造">
</p>

<p>
  <a href="README.md">English</a> · <a href="README.zh-Hans.md">简体中文</a> · <b>繁體中文</b>
</p>

**WukongMind**（悟空）是一款適用於 iPhone 與 iPad 的開放原始碼自用瀏覽器：內建的 AI 代理透過執行 JavaScript 與注入 CSS 來讀取並修改任意網頁，並能將修改儲存為依網站自動執行的使用者腳本（類似 Tampermonkey）。

- **個人自用，不在 App Store 上架。** WukongMind 衍生自 [Forumind](https://github.com/kccarlos/forumind)（Forumind 為通過 App Store 審查，將 AI 限制於受支援的論壇平台且維持唯讀）。WukongMind 不在 App Store 或公開 TestFlight 發布：由你使用自己的 Apple 開發者帳號從原始碼建置並簽署安裝，移除了針對 App Store 的能力限制。
- **以程式碼驅動網頁。** AI 不會直接觸碰頁面，而是撰寫程式碼；App 在 `WKWebView` 中執行程式碼並將結果回傳給模型，透過工具呼叫迴圈完成任務。
- **自備金鑰（BYOK）。** 沒有 WukongMind 後端伺服器、帳號、分析或中繼代理。API 金鑰保存在 iOS 鑰匙圈中，請求直接從你的裝置送往模型供應商（或區域網路內的本機模型伺服器）。
- **目前狀態：** `M1` 已完成（支援任意網站的代理聊天面板與頁面內工具）；`M2`（依網站儲存並自動注入使用者腳本）進行中。詳見[目前進度](#目前進度)。

---

## 風險聲明

> [!WARNING]
> **網頁內容可能會引導或操控代理（提示詞注入），且代理可以使用你在本 App 中登入的所有工作階段。請勿在 WukongMind 中登入銀行、付款或主要電子郵件等高風險帳號。**

在登入網站或執行代理之前，請先了解其安全模型：

- **提示詞注入與登入狀態共用：** 網頁上的不受信任文字可能誘導模型執行非預期操作，而代理與你的日常瀏覽共用同一個 `WKWebView` Cookie 與工作階段儲存空間。你在 WukongMind 內登入的任何網站，代理皆可存取。請避免在其中登入網路銀行、支付服務、主要信箱或其他高價值帳號。
- **頁面內完整執行權限（`run_js`）：** 預設**沒有任何確認提示，也沒有風險分級**——代理會直接呼叫工具，`run_js` 在目前頁面中擁有不受限制的 JavaScript 執行權限（讀寫 DOM、在 `page` 世界存取頁面全域變數、操作表單及發送同源請求）。
- **可選用的寫入前確認（規劃中）：** 設定中的可選開關 **「寫入前確認」（Confirm before writes）**（預設關閉；開啟後在呼叫 `http_request`、`cookies_get` 及送出表單前先詢問確認）規劃於後續里程碑（`M3`）提供，**目前尚未實作**。
- **目前已內建的安全基線：**
  - **橋接隔離：** App 與頁面的訊息通道（`WKScriptMessageHandlerWithReply`）僅註冊於隔離的 `WKContentWorld`，頁面自身腳本不可見，因此網頁無法呼叫原生工具或偽造工具結果。
  - **金鑰隔離：** AI 供應商的 API 金鑰僅保存在 iOS 鑰匙圈中，絕不進入頁面環境或對話紀錄，若意外出現在工具輸出中也會自動遮罩。
  - **不受信任內容標記：** 工具回傳的網頁文字會包覆在 `<untrusted_web_content>` 分隔符號中，系統提示詞明確要求模型絕不服從網頁內容中的指令。
  - **隨時停止：** 執行期間 **停止（Stop）** 按鈕全程顯示，點按即刻中止迴圈；單次執行亦受可調整的步數上限保護（預設 `30` 步）。全域腳本總開關（`M2`）與本機磁碟稽核日誌（`M3`）見下方路線圖。

---

## 目前進度

WukongMind 依里程碑順序開發（詳見英文需求文件 [docs/wukongmind/requirements.md](docs/wukongmind/requirements.md)）：

| 里程碑 | 狀態 | 內容 |
| :--- | :--- | :--- |
| **M0 — 盤點與驗證** | **已完成** | Forumind 模組對應與修改清單（[m0-module-map.md](docs/wukongmind/m0-module-map.md)），以及 `WKWebView` CSP 與雙執行世界實測驗證（[m0-csp-and-worlds.md](docs/wukongmind/m0-csp-and-worlds.md)）。 |
| **M1 — 核心迴圈** | **已完成** | 支援任意網站的一般網址列、**Agent** 聊天面板（iPhone 底部抽屜，iPad 可調寬分割面板）與工具列按鈕、支援原生工具呼叫的 `AgentLoop`、停止按鈕、Token 統計，以及頁面內工具（`read_page`、`run_js`、`inject_css`、`wait_for`）。 |
| **M2 — 持久化腳本** | **進行中** | 依網站生效的使用者腳本系統（`ScriptStore`，含 `// ==UserScript==` 標頭與 `@match` 規則的 `.user.js` 檔案）、腳本管理工具（`script_save`、`script_list`、`script_read`、`script_update`、`script_delete`）、頁面載入與 SPA 路由切換自動注入、腳本管理員介面、工具列腳本數量徽章與全域腳本開關。 |
| **M3 — 完整能力** | 規劃中 | `screenshot`（畫面截圖）、`network_log`、`navigate`、多分頁 `tabs`、跨網域 `http_request`、`cookies_get`（含 `httpOnly`）、工作區檔案讀寫 `file_read` / `file_write`、磁碟稽核日誌介面，以及可選用的「寫入前確認」模式。 |
| **M4 — 自我擴充與 Tampermonkey 相容** | 規劃中 | `GM_addStyle`、`GM_getValue`、`GM_setValue`、`GM_xmlhttpRequest`、從 URL 匯入使用者腳本、腳本錯誤一鍵「交給代理修復」、`notify`，以及腳本 iCloud 同步。 |

---

## 運作方式

- **瀏覽器代理（`M1`）：** 開啟任意網頁，點按瀏覽器列中的 **✦** 按鈕開啟 **Agent** 面板，輸入需求（例如 *「把這個頁面改成深色並隱藏側邊欄」*）。工具預設在隔離的 `WKContentWorld` 中透過 `callAsyncJavaScript` 執行（也可指定 `page` 世界存取頁面 JS 全域狀態），CSS 透過 `adoptedStyleSheets` 注入以避免受嚴格的 `style-src` 阻擋。目前已提供 `read_page`、`run_js`、`inject_css`、`wait_for` 四項頁面工具。
- **繼承自 Forumind 的功能：** Discourse、WordPress 與 Hacker News 的長篇討論分層**摘要**、話題**聊天**、全站**問論壇**、追蹤話題通知、每日摘要與雙主持人 Podcast、Gemini Live 即時語音，以及基於 EasyList / EasyPrivacy 的可選用廣告與追蹤器阻擋皆完整保留，與 **Agent** 模式並存。

---

## 自備金鑰（BYOK）

- **裝置直連供應商：** 所有模型請求皆直接從你的 iPhone 或 iPad 送往所設定的 AI 供應商端點。
- **鑰匙圈儲存：** API 金鑰儲存在 iOS 鑰匙圈（可選擇透過 iCloud 鑰匙圈在你的裝置間同步），不會寫入明文狀態檔，也不會暴露給網頁或工具。
- **獨立的瀏覽器代理模型：** **瀏覽器代理**預設不指定模型（**設定 › AI 模型 › Browser agent**），首次使用時請從支援原生工具呼叫的供應商中挑選模型：
  - **雲端供應商（需 API 金鑰）：** OpenRouter、OpenAI、Anthropic、Google Gemini、Google Vertex AI、Groq、xAI (Grok)、DeepSeek、NVIDIA NIM。
  - **區域網路本機伺服器（不需金鑰）：** Ollama（如 `http://192.168.1.20:11434`）、LM Studio（如 `http://192.168.1.20:1234/v1`）。
  - **Apple Intelligence：** 僅適用於繼承自 Forumind 的論壇**摘要與聊天**及**問論壇**，不支援一般瀏覽器代理工具呼叫。

---

## 從原始碼建置與安裝

### 系統需求

- 安裝 **Xcode 27**（CI 使用 `Xcode 27.2`；部署目標為 iOS / iPadOS **17.0+**）的 Mac。
- **Ruby** 與 **`xcodeproj`** gem（使用系統內建 Ruby 可執行 `gem install --user-install xcodeproj`）。
- 若要安裝到實體 iPhone 或 iPad，需要一個 Apple 帳號（免費個人 Apple ID 團隊或付費 Apple Developer Program 團隊皆可）；模擬器執行無需簽署帳號。
- 無任何第三方 Swift Package、CocoaPods 或 Carthage 相依套件。

> **專案與 Scheme 名稱說明：** WukongMind 沿用 Forumind 的專案檔與目標名稱（`Forumind.xcodeproj` 與 **`Forumind`** Scheme），建置出的應用程式顯示名稱為 **WukongMind**（URL Scheme 為 `wukongmind://`）。請勿直接在 Xcode 介面修改建置設定——請編輯 `scripts/generate_project.rb` 後重新產生。

### 1. 在 iOS 模擬器中執行

```sh
git clone https://github.com/kccarlos/WuKongMind.git
cd WuKongMind
gem install --user-install xcodeproj
ruby scripts/generate_project.rb
open Forumind.xcodeproj
```

在 Xcode 中選擇 **Forumind** Scheme 與任意模擬器，按 **Run**（`⌘R`）即可。（若尚未登入 Apple 帳號時 Xcode 提示預設簽署團隊不可用，可執行 `DEVELOPMENT_TEAM="" ruby scripts/generate_project.rb`。）

命令列無簽署建置：

```sh
destination="$(scripts/ci/pick-simulator.sh)"
xcodebuild build \
  -project Forumind.xcodeproj \
  -scheme Forumind \
  -destination "$destination" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

### 2. 使用你自己的 Apple 團隊簽署並安裝到實體裝置

Apple 的 Bundle ID 為全域唯一。由於 `scripts/generate_project.rb` 預設使用 `io.github.kccarlos.wukongmind`，**在實體裝置上以你自己的團隊簽署時，必須同時設定你的 Team ID 與自訂的反向網域名稱 `BUNDLE_ID_PREFIX`**：

1. 在 **Xcode › Settings › Accounts** 或 [developer.apple.com/account](https://developer.apple.com/account) 查詢你的 10 碼 **Team ID**。
2. 設定 Team ID 並指定 `BUNDLE_ID_PREFIX` 重新產生專案：

   ```sh
   # 方式 A：將 Team ID 寫入被 Git 忽略的 Config/DevelopmentTeam.txt
   cp Config/DevelopmentTeam.example.txt Config/DevelopmentTeam.txt
   # 編輯 Config/DevelopmentTeam.txt，將 ABCDE12345 替換為你的 10 碼 Team ID
   BUNDLE_ID_PREFIX=com.example.wukongmind ruby scripts/generate_project.rb

   # 方式 B：直接透過環境變數傳入（DEVELOPMENT_TEAM 優先於檔案）
   DEVELOPMENT_TEAM=ABCDE12345 BUNDLE_ID_PREFIX=com.example.wukongmind \
     ruby scripts/generate_project.rb
   ```

3. 開啟 `Forumind.xcodeproj`，連接 iPhone 或 iPad，選擇 **Forumind** Scheme 與你的裝置，點按 **Run**（`⌘R`）。首次安裝需在裝置上開啟**開發者模式**（**設定 › 隱私權與安全性 › 開發者模式**），並於**設定 › 一般 › VPN 與裝置管理**中信任開發者憑證。

- **免費個人團隊可直接簽署：** `scripts/generate_project.rb` 中 `DC_ENABLE_SHARE_EXTENSION`、`DC_ENABLE_APP_GROUP`、`DC_ENABLE_CLOUDKIT` 與 `DC_ENABLE_PCC` 預設皆為 `NO`（詳見 [docs/wukongmind/README.md](docs/wukongmind/README.md)），基礎 entitlements 為空，因此免費個人 Apple ID 團隊（簽署效期 7 天）與付費開發者團隊皆可直接建置安裝，無須事先在開發者後台註冊容器。付費團隊若已在後台註冊 `group.<prefix>` 與 `iCloud.<prefix>`，可透過 `DC_ENABLE_SHARE_EXTENSION=YES` 與 `DC_ENABLE_CLOUDKIT=YES` 啟用分享延伸功能與 iCloud 同步。
- **提交變更注意事項：** 請勿提交含有個人 `DEVELOPMENT_TEAM`、`BUNDLE_ID_PREFIX` 或 `DC_ENABLE_*` 的 `Forumind.xcodeproj`；提交前請先移開 `Config/DevelopmentTeam.txt` 並執行 `env -u DEVELOPMENT_TEAM -u BUNDLE_ID_PREFIX ruby scripts/generate_project.rb`，以通過 CI 的 `scripts/ci/check-project-drift.sh` 檢查。

---

## 測試與檢查

```sh
# 免模擬器的 macOS 核心單元測試（AgentLoop 與 ToolRegistry）
xcodebuild test \
  -project Forumind.xcodeproj \
  -scheme ForumindAgentCoreTests \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

# 完整 iOS 模擬器單元測試（與 .github/workflows/ci.yml 一致）
destination="$(scripts/ci/pick-simulator.sh)"
xcodebuild test \
  -project Forumind.xcodeproj \
  -scheme Forumind \
  -destination "$destination" \
  -only-testing:ForumindTests \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

# 儲存庫檢查腳本
scripts/ci/lint-plists.sh
scripts/ci/check-project-drift.sh
scripts/ci/check-site-layering.sh
scripts/i18n/check-catalogs.py
scripts/adblock/run_tests.sh
```

---

## 文件與授權條款

詳細設計、模組對應與開發文件（英文）請參閱英文主文件 [README.md](README.md#documentation)、[docs/wukongmind/requirements.md](docs/wukongmind/requirements.md) 與 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。（儲存庫中的 [PRIVACY.md](PRIVACY.md)、[TERMS.md](TERMS.md) 與 [docs/APP_STORE.md](docs/APP_STORE.md) 繼承自 Forumind 的 App Store 版本並保留備查；WukongMind 本身不在 App Store 上架。）

WukongMind 衍生自 **[Forumind](https://github.com/kccarlos/forumind)**（`Copyright 2026 kccarlos and Forumind contributors`），採用 **[Apache License 2.0](LICENSE)** 開放原始碼授權。可選用的廣告與追蹤器阻擋規則源自 [EasyList 和 EasyPrivacy](https://easylist.to/)（CC BY-SA 3.0，詳見 [NOTICE](NOTICE)）。本專案與 Civilized Discourse Construction Kit, Inc.（"Discourse"）、WordPress、Hacker News 及 Tampermonkey 皆無關聯。
