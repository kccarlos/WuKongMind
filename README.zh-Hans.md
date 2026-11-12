# WukongMind (悟空)

<p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="许可证：Apache-2.0"></a>
  <img src="https://img.shields.io/badge/iOS_%7C_iPadOS-17%2B-000000?logo=apple&logoColor=white" alt="iOS 与 iPadOS 17 或更高版本">
  <img src="https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/Made_with-SwiftUI-2396F3?logo=swift&logoColor=white" alt="使用 SwiftUI 构建">
</p>

<p>
  <a href="README.md">English</a> · <b>简体中文</b> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

**WukongMind**（悟空）是一款面向 iPhone 与 iPad 的开源自用浏览器：内置的 AI 智能体通过运行 JavaScript 与注入 CSS 读取和修改任意网页，并可将修改保存为按站点生效的用户脚本（类似 Tampermonkey）。

- **个人自用，不上架 App Store。** WukongMind 派生自 [Forumind](https://github.com/kccarlos/forumind)（Forumind 为通过 App Store 审核，将 AI 限制在受支持的论坛平台且保持只读）。WukongMind 不在 App Store 或公开 TestFlight 分发：由你使用自己的 Apple 开发者账号从源代码构建并签名安装，移除了面向 App Store 的能力限制。
- **通过代码驱动网页。** AI 不会直接操作页面，而是编写代码；App 在 `WKWebView` 中执行代码并将结果返回给模型，通过工具调用循环完成任务。
- **自带密钥（BYOK）。** 没有 WukongMind 后端服务器、账户、统计分析或中转代理。API 密钥保存在 iOS 钥匙串中，请求由你的设备直接发往模型提供方（或局域网内的本地模型服务）。
- **当前状态：** `M1` 已完成（支持任意网站的智能体聊天面板与页面内工具）；`M2`（按站点保存并自动注入用户脚本）进行中。详见[当前进展](#当前进展)。

---

## 风险声明

> [!WARNING]
> **网页内容可能会诱导智能体（提示词注入），且智能体可以使用你在本 App 中登录的所有会话。请勿在 WukongMind 中登录银行、支付或主力邮箱等高风险账户。**

在登录网站或运行智能体前，请充分了解其安全模型：

- **提示词注入与登录态共享：** 网页上的不受信任文本可能会误导模型执行非预期操作，而智能体与你的日常浏览共享同一个 `WKWebView` Cookie 与会话存储。你在 WukongMind 内登录的任何网站，智能体均可访问。请避免在其中登录网银、支付工具、主邮箱或其他高价值账户。
- **页面内完整执行权限（`run_js`）：** 默认**没有任何确认弹窗，也没有风险分级**——智能体会直接调用工具，`run_js` 在当前页面内拥有完整的 JavaScript 执行权限（读写 DOM、在 `page` 世界访问页面全局变量、操作表单及发起同源请求）。
- **可选的写入前确认（规划中）：** 设置中的可选开关 **“写入前确认”（Confirm before writes）**（默认关闭；开启后在调用 `http_request`、`cookies_get` 及提交表单前先询问确认）计划在后续里程碑（`M3`）中提供，**当前尚未实装**。
- **当前已内置的安全基线：**
  - **桥接隔离：** App 与页面的消息通道（`WKScriptMessageHandlerWithReply`）仅注册在隔离的 `WKContentWorld` 中，页面自身脚本不可见，因此网页无法调用原生工具或伪造工具结果。
  - **密钥隔离：** AI 提供方的 API 密钥仅保存在 iOS 钥匙串中，绝不进入页面环境或对话历史，若意外出现在工具输出中也会被脱敏。
  - **不受信任内容标记：** 工具返回的网页文本会包裹在 `<untrusted_web_content>` 分隔符中，系统提示词明确要求模型绝不服从网页内容中的指令。
  - **随时停止：** 运行期间 **停止（Stop）** 按钮全程可见，点击即刻中止循环；单次运行还受可配置的步数上限保护（默认 `30` 步）。全局脚本总开关（`M2`）和本地磁盘审计日志（`M3`）见下方路线图。

---

## 当前进展

WukongMind 按里程碑顺序推进（详见英文需求文档 [docs/wukongmind/requirements.md](docs/wukongmind/requirements.md)）：

| 里程碑 | 状态 | 内容 |
| :--- | :--- | :--- |
| **M0 — 调研** | **已完成** | Forumind 模块映射与改动清单（[m0-module-map.md](docs/wukongmind/m0-module-map.md)），以及 `WKWebView` CSP 与双执行世界实测验证（[m0-csp-and-worlds.md](docs/wukongmind/m0-csp-and-worlds.md)）。 |
| **M1 — 核心循环** | **已完成** | 支持任意网站的通用地址栏、**Agent** 聊天面板（iPhone 底部抽屉，iPad 可调宽分栏）与工具栏按钮、支持原生工具调用的 `AgentLoop`、停止按钮、Token 统计，以及页面内工具（`read_page`、`run_js`、`inject_css`、`wait_for`）。 |
| **M2 — 持久化脚本** | **进行中** | 按站点的用户脚本系统（`ScriptStore`，带 `// ==UserScript==` 头与 `@match` 规则的 `.user.js` 文件）、脚本管理工具（`script_save`、`script_list`、`script_read`、`script_update`、`script_delete`）、页面加载与 SPA 路由切换自动注入、脚本管理器界面、工具栏脚本计数徽标与全局脚本开关。 |
| **M3 — 完整能力** | 规划中 | `screenshot`（视觉截图）、`network_log`、`navigate`、多标签页 `tabs`、跨域 `http_request`、`cookies_get`（含 `httpOnly`）、工作区文件读写 `file_read` / `file_write`、磁盘审计日志界面，以及可选的“写入前确认”模式。 |
| **M4 — 自扩展与 Tampermonkey 兼容** | 规划中 | `GM_addStyle`、`GM_getValue`、`GM_setValue`、`GM_xmlhttpRequest`、从 URL 导入用户脚本、脚本报错一键“交给智能体修复”、`notify`，以及脚本 iCloud 同步。 |

---

## 工作方式

- **页面智能体（`M1`）：** 打开任意网页，点按浏览器栏中的 **✦** 按钮打开 **Agent** 面板，输入需求（例如 *“把这个页面改成深色并隐藏侧边栏”*）。工具默认在隔离的 `WKContentWorld` 中通过 `callAsyncJavaScript` 运行（也可指定 `page` 世界访问页面 JS 全局状态），CSS 通过 `adoptedStyleSheets` 注入以绕过严格的 `style-src` 限制。当前已提供 `read_page`、`run_js`、`inject_css`、`wait_for` 四个页面工具。
- **继承自 Forumind 的能力：** Discourse、WordPress 与 Hacker News 的长帖分级**摘要**、话题**聊天**、全站**问论坛**、关注话题提醒、每日摘要与双人播客、Gemini Live 实时语音，以及基于 EasyList / EasyPrivacy 的可选广告与跟踪器拦截均完整保留，与 **Agent** 模式并存。

---

## 自带密钥（BYOK）

- **直连提供方：** 所有模型请求均从你的 iPhone 或 iPad 直接发往所配置的 AI 提供方接口。
- **钥匙串存储：** API 密钥保存在 iOS 钥匙串（可选通过 iCloud 钥匙串在你的设备间同步），不会写入明文状态文件，也不会暴露给网页或工具。
- **独立的浏览器智能体模型：** **浏览器智能体**默认不预设模型（**设置 › AI 模型 › Browser agent**），首次使用时请从支持原生工具调用的提供方中选择模型：
  - **云端提供方（需 API 密钥）：** OpenRouter、OpenAI、Anthropic、Google Gemini、Google Vertex AI、Groq、xAI (Grok)、DeepSeek、NVIDIA NIM。
  - **局域网本地服务（无需密钥）：** Ollama（如 `http://192.168.1.20:11434`）、LM Studio（如 `http://192.168.1.20:1234/v1`）。
  - **Apple 智能：** 仅可用于继承自 Forumind 的论坛**摘要与聊天**及**问论坛**，不支持通用浏览器智能体工具调用。

---

## 从源代码构建与安装

### 环境要求

- 装有 **Xcode 27**（CI 使用 `Xcode 27.2`；部署目标为 iOS / iPadOS **17.0+**）的 Mac。
- **Ruby** 及 **`xcodeproj`** gem（使用系统 Ruby 可运行 `gem install --user-install xcodeproj`）。
- 若要安装到真机（iPhone / iPad），需要一个 Apple 账号（免费个人 Apple ID 团队或付费 Apple Developer Program 团队均可）；模拟器运行无需签名账号。
- 无任何第三方 Swift Package、CocoaPods 或 Carthage 依赖。

> **工程与 Scheme 名称说明：** WukongMind 沿用了 Forumind 的工程文件与目标名（`Forumind.xcodeproj` 与 **`Forumind`** Scheme），构建出的应用显示名称为 **WukongMind**（URL Scheme 为 `wukongmind://`）。请勿在 Xcode 界面中直接修改构建设置——请修改 `scripts/generate_project.rb` 后重新生成。

### 1. 在 iOS 模拟器中运行

```sh
git clone https://github.com/kccarlos/WuKongMind.git
cd WuKongMind
gem install --user-install xcodeproj
ruby scripts/generate_project.rb
open Forumind.xcodeproj
```

在 Xcode 中选择 **Forumind** Scheme 和任意模拟器，按 **Run**（`⌘R`）即可。（若尚未登录 Apple 账号时 Xcode 提示默认签名团队不可用，可执行 `DEVELOPMENT_TEAM="" ruby scripts/generate_project.rb`。）

命令行无签名构建：

```sh
destination="$(scripts/ci/pick-simulator.sh)"
xcodebuild build \
  -project Forumind.xcodeproj \
  -scheme Forumind \
  -destination "$destination" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

### 2. 使用你自己的 Apple 团队签名并安装到真机

Apple 的 Bundle ID 全局唯一。由于 `scripts/generate_project.rb` 默认使用 `io.github.kccarlos.wukongmind`，**在真机上用你自己的团队签名时，必须同时配置你的 Team ID 和自定义的反向域名 `BUNDLE_ID_PREFIX`**：

1. 在 **Xcode › Settings › Accounts** 或 [developer.apple.com/account](https://developer.apple.com/account) 查看你的 10 位 **Team ID**。
2. 配置 Team ID 并指定 `BUNDLE_ID_PREFIX` 重新生成工程：

   ```sh
   # 方式 A：将 Team ID 写入被 Git 忽略的 Config/DevelopmentTeam.txt
   cp Config/DevelopmentTeam.example.txt Config/DevelopmentTeam.txt
   # 编辑 Config/DevelopmentTeam.txt，把 ABCDE12345 替换为你的 10 位 Team ID
   BUNDLE_ID_PREFIX=com.example.wukongmind ruby scripts/generate_project.rb

   # 方式 B：直接通过环境变量传入（DEVELOPMENT_TEAM 优先级高于文件）
   DEVELOPMENT_TEAM=ABCDE12345 BUNDLE_ID_PREFIX=com.example.wukongmind \
     ruby scripts/generate_project.rb
   ```

3. 打开 `Forumind.xcodeproj`，连接 iPhone 或 iPad，选择 **Forumind** Scheme 与你的设备，点击 **Run**（`⌘R`）。首次安装需在设备上开启**开发者模式**（**设置 › 隐私与安全性 › 开发者模式**），并在**设置 › 通用 › VPN 与设备管理**中信任开发者证书。

- **免费个人团队可直接签名：** `scripts/generate_project.rb` 中 `DC_ENABLE_SHARE_EXTENSION`、`DC_ENABLE_APP_GROUP`、`DC_ENABLE_CLOUDKIT` 和 `DC_ENABLE_PCC` 默认均为 `NO`（详见 [docs/wukongmind/README.md](docs/wukongmind/README.md)），基础 entitlements 为空，因此免费个人 Apple ID 团队（签名有效期 7 天）和付费开发者团队均可直接编译安装，无需预先在开发者后台注册容器。付费团队若在后台注册了 `group.<prefix>` 与 `iCloud.<prefix>`，可通过 `DC_ENABLE_SHARE_EXTENSION=YES` 与 `DC_ENABLE_CLOUDKIT=YES` 开启分享扩展与 iCloud 同步。
- **提交代码注意：** 请勿提交带有个人 `DEVELOPMENT_TEAM`、`BUNDLE_ID_PREFIX` 或 `DC_ENABLE_*` 的 `Forumind.xcodeproj`；提交前请移开 `Config/DevelopmentTeam.txt` 并执行 `env -u DEVELOPMENT_TEAM -u BUNDLE_ID_PREFIX ruby scripts/generate_project.rb`，以通过 CI 的 `scripts/ci/check-project-drift.sh` 检查。

---

## 测试与检查

```sh
# 无需模拟器的 macOS 核心单元测试（AgentLoop 与 ToolRegistry）
xcodebuild test \
  -project Forumind.xcodeproj \
  -scheme ForumindAgentCoreTests \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

# 完整 iOS 模拟器单元测试（与 .github/workflows/ci.yml 一致）
destination="$(scripts/ci/pick-simulator.sh)"
xcodebuild test \
  -project Forumind.xcodeproj \
  -scheme Forumind \
  -destination "$destination" \
  -only-testing:ForumindTests \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

# 仓库校验脚本
scripts/ci/lint-plists.sh
scripts/ci/check-project-drift.sh
scripts/ci/check-site-layering.sh
scripts/i18n/check-catalogs.py
scripts/adblock/run_tests.sh
```

---

## 文档与许可证

详细设计、模块映射与开发文档（英文）请参阅英文主文档 [README.md](README.md#documentation)、[docs/wukongmind/requirements.md](docs/wukongmind/requirements.md) 与 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。（仓库中的 [PRIVACY.md](PRIVACY.md)、[TERMS.md](TERMS.md) 和 [docs/APP_STORE.md](docs/APP_STORE.md) 继承自 Forumind 的 App Store 版本并保留备查；WukongMind 本身不上架 App Store。）

WukongMind 派生自 **[Forumind](https://github.com/kccarlos/forumind)**（`Copyright 2026 kccarlos and Forumind contributors`），采用 **[Apache License 2.0](LICENSE)** 开源许可。可选广告与跟踪器拦截规则源自 [EasyList 和 EasyPrivacy](https://easylist.to/)（CC BY-SA 3.0，详见 [NOTICE](NOTICE)）。本项目与 Civilized Discourse Construction Kit, Inc.（"Discourse"）、WordPress、Hacker News 及 Tampermonkey 均无关联。
