<div align="center">
  <img src="docs/brand/wukongmind-icon-1024.png" width="120" height="120" alt="WukongMind 應用程式圖示">
  <h1>WukongMind 瀏覽器</h1>
  <p><strong>網頁用不順手？說一句就改。</strong></p>
  <p>太亂、看得吃力、太長？用一句話說出你想要的。代理當著你的面把網頁改好；要不要留下這個修改，由你決定。</p>

  <p>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="授權條款：Apache-2.0"></a>
    <img src="https://img.shields.io/badge/iOS_%7C_iPadOS-17%2B-000000?logo=apple&logoColor=white" alt="iOS 與 iPadOS 17 或以上版本">
    <img src="https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white" alt="Swift">
    <img src="https://img.shields.io/badge/Made_with-SwiftUI-2396F3?logo=swift&logoColor=white" alt="以 SwiftUI 打造">
  </p>

  <p>
    <a href="README.md">English</a> · <a href="README.zh-Hans.md">简体中文</a> · <b>繁體中文</b>
  </p>
</div>

<div align="center">

[![加入 TestFlight 測試](https://img.shields.io/badge/TestFlight_測試-e0b040?style=for-the-badge&logo=apple&logoColor=1a1612)][testflight]
[![官方網站](https://img.shields.io/badge/官方網站-1a1612?style=for-the-badge)](https://kccarlos.github.io/WuKongMind/zh-Hant/)
[![開發者文件](https://img.shields.io/badge/開發者文件-5f574c?style=for-the-badge)](docs/DEVELOPER.md)

</div>

---

## App 裡的樣子

<table>
  <tr>
    <td align="center" width="33%">
      <img src="appstore/screenshots/zh-Hant/iphone/01-change-page.png" width="260" alt="向代理說「改成深色並隱藏側邊欄」之後，文章變成深色"><br>
      <sub>說一句，頁面當場改好</sub>
    </td>
    <td align="center" width="33%">
      <img src="appstore/screenshots/zh-Hant/iphone/02-agent-steps.png" width="260" alt="對話中即時列出代理的每一個步驟"><br>
      <sub>每一步都看得見</sub>
    </td>
    <td align="center" width="33%">
      <img src="appstore/screenshots/zh-Hant/iphone/03-script-approval.png" width="260" alt="「加入指令碼」頁面顯示適用網站與完整程式碼，經你核准才會儲存"><br>
      <sub>儲存腳本前先由你核准</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="33%">
      <img src="appstore/screenshots/zh-Hant/iphone/04-tabs-navigation.png" width="260" alt="多分頁概覽畫面"><br>
      <sub>分頁與概覽</sub>
    </td>
    <td align="center" width="33%">
      <img src="appstore/screenshots/zh-Hant/iphone/05-summarize-read-aloud.png" width="260" alt="頁面摘要與朗讀播放器"><br>
      <sub>摘要與朗讀</sub>
    </td>
    <td align="center" width="33%">
      <img src="appstore/screenshots/zh-Hant/iphone/06-browser-bar.png" width="260" alt="瀏覽器列中的金色代理圓環"><br>
      <sub>瀏覽器列裡的金色圓環</sub>
    </td>
  </tr>
</table>

<p align="center">
  <img src="appstore/screenshots/zh-Hant/ipad/06-ipad-split.png" width="780" alt="iPad 分割畫面，網頁與代理面板並排顯示"><br>
  <sub>在 iPad 上，網頁和代理並排顯示</sub>
</p>

---

## 你能用它做什麼

- **整理雜亂頁面** — 一句話收起橫幅、側邊欄與彈出視窗，或把刺眼的網站改成深色、放大字體，只留下內文。
- **好用就留下來** — 把修改存成依網站自動套用的小腳本，下次造訪直接生效；儲存之前先由你看過程式碼並核准。
- **摘要並念給你聽** — 快速掌握長文章與討論串重點、接著追問，或開啟朗讀與即時語音對話。
- **全程透明，隨時可停** — 代理的每一步都會即時列出，「停止」按鈕始終停留在螢幕上。
- **完整的日常瀏覽器** — 分頁、釘選網站、瀏覽記錄、裝置端翻譯（iOS 18+）、選用廣告與追蹤器封鎖，以及 iPad 並排檢視。

---

## 用心打磨的設計

WukongMind 捨棄漸層與繁雜裝飾，以四種水墨色彩傳達四種語意：**墨**落在宣紙與漆黑底色上，**金**代表代理與圓環，**青**標示來自網頁的內容，**朱**只用於停止與錯誤。字體僅使用系統字型（**SF Pro**、**蘋方**與程式碼用的 **SF Mono**），配合 iOS 動態字體，並以細緻分隔線取代厚重陰影。

<p align="center">
  <img src="docs/brand/readme/palette-light.svg" width="840" alt="WukongMind 淺色配色與代理圓環狀態">
</p>
<p align="center">
  <img src="docs/brand/readme/palette-dark.svg" width="840" alt="WukongMind 深色配色與代理圓環狀態">
</p>

<p align="center">
  <img src="docs/wukongmind/design/design-system/assets/Mascot/wave.svg" width="64" alt="WukongMind 吉祥物揮手"><br>
  <sub>完整的色彩標記、圓環狀態與元件規範見<a href="docs/wukongmind/design/design-system/README.md">設計系統文件（英文）</a>。</sub>
</p>

---

## 隱私優先 · 自備金鑰（BYOK）

沒有 WukongMind 帳號、後端伺服器、分析或追蹤。API 金鑰保存在 iOS 鑰匙圈中（可選用 iCloud 鑰匙圈同步），請求直接從你的裝置送往所選 AI 供應商，或送往區域網路上的本機模型。

- **雲端供應商（需 API 金鑰）：** OpenRouter、OpenAI、Anthropic、Google Gemini、Google Vertex AI、Groq、xAI (Grok)、DeepSeek、NVIDIA NIM。
- **區域網路本機伺服器（不需金鑰）：** Ollama、LM Studio。
- **裝置端（僅用於摘要）：** Apple Intelligence。

---

## 安全提醒

> [!WARNING]
> **網頁內容可能會引導或操控代理（提示詞注入），且代理可以使用你在本 App 中登入的所有工作階段。請勿在 WukongMind 中登入銀行、付款或主要電子郵件等高風險帳號。**

- **每一步都看得到，隨時能停** — 對頁面的所有操作都會即時列出，「停止」按鈕全程停留在螢幕上。
- **敏感操作前先徵詢確認** — 預設情況下，傳送網路要求、發送通知、讀取 Cookie 或將登入狀態送往其他網站前，都會停下來問你。
- **腳本必須經你核准才會儲存** — 儲存或更新前，你會看到它適用的網站、可用權限與完整程式碼。

橋接隔離、金鑰隔離、不受信任內容標記與完整威脅模型詳見 [docs/DEVELOPER.md](docs/DEVELOPER.md#risk-statement)（英文）與 [SECURITY.md](SECURITY.md)。

---

## 專案現況

- **TestFlight 版本 1.6.2** — 單一程式碼庫，App Store、TestFlight 與原始碼自建版本擁有完全相同的行為與預設安全設定。
- **三種語言** — English、简体中文（`zh-Hans`）與繁體中文（`zh-Hant`）。
- **iPhone 與 iPad** — 原生 SwiftUI 應用程式（iOS / iPadOS 17+），無任何第三方相依套件。
- **開放原始碼** — 採用 [Apache License 2.0](LICENSE) 授權，每次變更皆經過自動化 CI 檢查。

---

## 開發者與授權條款

- **開發者入口：** 從原始碼建置、執行測試、里程碑進度、工具原理與完整文件索引請參閱 **[docs/DEVELOPER.md](docs/DEVELOPER.md)**（英文）。
- **政策與社群：** [LICENSE](LICENSE) · [PRIVACY.md](PRIVACY.md) · [SECURITY.md](SECURITY.md) · [CONTRIBUTING.md](CONTRIBUTING.md) · [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) · [NOTICE](NOTICE)。
- WukongMind 衍生自 **[Forumind](https://github.com/kccarlos/forumind)**（`Copyright 2026 kccarlos and Forumind contributors`），採用 **[Apache License 2.0](LICENSE)** 開放原始碼授權。選用的廣告與追蹤器阻擋規則源自 [EasyList 和 EasyPrivacy](https://easylist.to/)（CC BY-SA 3.0，詳見 [NOTICE](NOTICE)）。
- 本專案為獨立開放原始碼專案，與 Civilized Discourse Construction Kit, Inc.（"Discourse"）、WordPress、Hacker News 及 Tampermonkey 皆無關聯。

<!-- Coordinator: replace the URL below with the public TestFlight link once it is live. -->
[testflight]: https://kccarlos.github.io/WuKongMind/
