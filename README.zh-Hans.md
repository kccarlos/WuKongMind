<div align="center">
  <img src="docs/brand/wukongmind-icon-1024.png" width="120" height="120" alt="WukongMind 应用图标">
  <h1>WukongMind 浏览器</h1>
  <p><strong>网页不顺手？说一句就改。</strong></p>
  <p>太乱、看着累、太长？用一句话说出你想要的。智能体当着你的面把网页改好；要不要留下这个修改，由你决定。</p>

  <p>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="许可证：Apache-2.0"></a>
    <img src="https://img.shields.io/badge/iOS_%7C_iPadOS-17%2B-000000?logo=apple&logoColor=white" alt="iOS 与 iPadOS 17 或更高版本">
    <img src="https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white" alt="Swift">
    <img src="https://img.shields.io/badge/Made_with-SwiftUI-2396F3?logo=swift&logoColor=white" alt="使用 SwiftUI 构建">
  </p>

  <p>
    <a href="README.md">English</a> · <b>简体中文</b> · <a href="README.zh-Hant.md">繁體中文</a>
  </p>
</div>

<div align="center">

[![加入 TestFlight 测试](https://img.shields.io/badge/TestFlight_测试-e0b040?style=for-the-badge&logo=apple&logoColor=1a1612)][testflight]
[![官网](https://img.shields.io/badge/官网-1a1612?style=for-the-badge)](https://kccarlos.github.io/WuKongMind/zh-Hans/)
[![开发者文档](https://img.shields.io/badge/开发者文档-5f574c?style=for-the-badge)](docs/DEVELOPER.md)

</div>

---

## App 里的样子

<table>
  <tr>
    <td align="center" width="33%">
      <img src="appstore/screenshots/zh-Hans/iphone/01-change-page.png" width="260" alt="向智能体说“改成深色并隐藏侧边栏”之后，文章变成深色"><br>
      <sub>说一句，网页当场改好</sub>
    </td>
    <td align="center" width="33%">
      <img src="appstore/screenshots/zh-Hans/iphone/02-agent-steps.png" width="260" alt="对话中实时列出智能体的每一步操作"><br>
      <sub>每一步都看得见</sub>
    </td>
    <td align="center" width="33%">
      <img src="appstore/screenshots/zh-Hans/iphone/03-script-approval.png" width="260" alt="“添加脚本”页面展示适用网站和完整代码，经你批准后才保存"><br>
      <sub>保存脚本前先由你批准</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="33%">
      <img src="appstore/screenshots/zh-Hans/iphone/04-tabs-navigation.png" width="260" alt="多标签页概览界面"><br>
      <sub>标签页与概览</sub>
    </td>
    <td align="center" width="33%">
      <img src="appstore/screenshots/zh-Hans/iphone/05-summarize-read-aloud.png" width="260" alt="页面摘要和朗读播放器"><br>
      <sub>摘要与朗读</sub>
    </td>
    <td align="center" width="33%">
      <img src="appstore/screenshots/zh-Hans/iphone/06-browser-bar.png" width="260" alt="浏览器栏中的金色智能体圆环"><br>
      <sub>浏览器栏里的金色圆环</sub>
    </td>
  </tr>
</table>

<p align="center">
  <img src="appstore/screenshots/zh-Hans/ipad/06-ipad-split.png" width="780" alt="iPad 分屏视图，网页与智能体面板并排显示"><br>
  <sub>在 iPad 上，网页和智能体并排显示</sub>
</p>

---

## 你能用它做什么

- **清理杂乱页面** — 一句话收起横幅、侧边栏和弹窗，或把刺眼的网页改成深色、调大字号，只留正文。
- **好用就留下来** — 把修改存成按网站生效的小脚本，下次打开自动套用；保存之前先由你看过代码并批准。
- **总结并读给你听** — 快速提炼长网页和讨论串的要点、继续追问，或开启朗读与实时语音对话。
- **全程透明，随时可停** — 智能体的每一步都实时列出，“停止”按钮始终在屏幕上。
- **完整的日常浏览器** — 标签页、置顶网站、历史记录、设备端翻译（iOS 18+）、可选广告与追踪器拦截，以及 iPad 并排模式。

---

## 隐私优先 · 自带密钥（BYOK）

没有 WukongMind 账号、后端服务器、统计分析或追踪。API 密钥保存在 iOS 钥匙串中（可选通过 iCloud 钥匙串同步），请求直接从你的设备发往所选 AI 提供方，或发往你局域网里的本地模型。

- **云端提供方（需 API 密钥）：** OpenRouter、OpenAI、Anthropic、Google Gemini、Google Vertex AI、Groq、xAI (Grok)、DeepSeek、NVIDIA NIM。
- **局域网本地服务（无需密钥）：** Ollama、LM Studio。
- **设备端（仅用于摘要）：** Apple 智能。

---

## 安全提醒

> [!WARNING]
> **网页内容可能会诱导智能体（提示词注入），且智能体可以使用你在本 App 中登录的所有会话。请勿在 WukongMind 中登录银行、支付或主力邮箱等高风险账户。**

- **每一步都看得见，随时能停** — 对页面的所有操作都会实时展示，“停止”按钮全程停留在屏幕上。
- **敏感操作前先征求确认** — 默认情况下，发起网络请求、发送通知、读取 Cookie 或向其他网站发送登录态之前，都会停下来问你。
- **脚本必须经你批准才会保存** — 保存或更新前，你会看到它适用的网站、可用权限和完整代码。

桥接隔离、密钥隔离、不受信任内容标记及完整威胁模型详见 [docs/DEVELOPER.md](docs/DEVELOPER.md#risk-statement)（英文）与 [SECURITY.md](SECURITY.md)。

---

## 开发者与许可证

- **构建与发布：** 原生 SwiftUI 应用，支持 iPhone 与 iPad（iOS / iPadOS 17+），零第三方依赖，提供 English、简体中文（`zh-Hans`）与繁體中文（`zh-Hant`）三种语言。欢迎加入 [TestFlight][testflight] 测试，或从源码构建，每次改动均通过自动化 CI 检查。
- **开发者入口：** 从源码构建、运行测试、里程碑进展、工具原理与完整文档索引请参阅 **[docs/DEVELOPER.md](docs/DEVELOPER.md)**（英文）。
- **政策与社区：** [LICENSE](LICENSE) · [PRIVACY.md](PRIVACY.md) · [SECURITY.md](SECURITY.md) · [CONTRIBUTING.md](CONTRIBUTING.md) · [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) · [NOTICE](NOTICE)。
- WukongMind 派生自 **[Forumind](https://github.com/kccarlos/forumind)**（`Copyright 2026 kccarlos and Forumind contributors`），采用 **[Apache License 2.0](LICENSE)** 开源许可。可选广告与跟踪器拦截规则源自 [EasyList 和 EasyPrivacy](https://easylist.to/)（CC BY-SA 3.0，详见 [NOTICE](NOTICE)）。
- 本项目为独立开源项目，与 Civilized Discourse Construction Kit, Inc.（"Discourse"）、WordPress、Hacker News 及 Tampermonkey 均无关联。

<p align="center">
  <img src="docs/wukongmind/design/design-system/assets/Mascot/wave.svg" width="64" alt="WukongMind 吉祥物挥手"><br>
  <sub>网页顺手，逛得轻松 — 完整的颜色标记、圆环状态与组件规范见<a href="docs/wukongmind/design/design-system/README.md">设计系统文档（英文）</a>。</sub>
</p>

[testflight]: https://testflight.apple.com/join/t5RNVr7M
