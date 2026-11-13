# M3 design: full abilities (1.2.0)

M3 gives the Agent its abilities outside the current page: it can take screenshots, read network traffic, move between pages and tabs, make HTTP requests, read cookies and use a workspace of files. It also gets an audit log saved on disk and part 1 of developer mode. This page is the design and the task split. Implementation tasks start once the owner accepts One panel.

Sources, in order of precedence: [next-phase.md](next-phase.md) (§7 "M3 full abilities", §8 "Developer mode"), then [requirements.md](requirements.md) (§3, §4, §6, §8, §9), then [design-unified.md](design-unified.md) for the UI touch points. The format follows [design-m2.md](design-m2.md). Where these sources disagree, the conflict is named in [Conflicts](#conflicts-called-out) rather than settled silently.

**There is no new visual design.** Every UI piece reuses a component in [design/design-system/components](design/design-system/components) (ToolRow, ListRow, Message, Button, Seal, Switch, ResultCard) or an existing SwiftUI pattern. The one exception, the tab overview, is listed as an open question.

## Decisions

- **Where the tools live.** M3 tools extend the sole Agent loop: `ToolRegistry` (`WukongMind/ToolRegistry.swift`, the `m1`/`m2` factories), `AgentLoop` and `BrowserAgentSession` (`WukongMind/BrowserAgent.swift`), and `AgentBridge` (`WukongMind/AgentBridge.swift`). **They do not go into `AgentToolName` or `executeAgentTool`.** Those two (`Sites/SiteAdapter.swift:176`, `AppModel.swift:3276`) belong to the old Research loop, which roadmap §6 deletes in One loop, where its tool names come back as adapter tools. The brief listed them as code M3 builds on. That is a correction, not a conflict in the roadmap.
- **One seam first.** Task 1 adds `ToolRegistry.m3(...)`, a factory that wraps `m2` and takes an `AgentToolContext` (new): the bridge, the workspace, the cookie store, the confirmation gate and the settings. Each tool family lives in its own new file (`ToolRegistry+Workspace.swift`, `ToolRegistry+Page.swift`, `ToolRegistry+Browser.swift`, `ToolRegistry+Network.swift`). Later tasks add one line to the factory and leave the rest of `ToolRegistry.swift` alone. `AppModel.browserAgent`'s `registryBuilder` switches from `.m2` to `.m3` once, in task 1.
- **Tool names stay as requirements §4 lists them**, plus `file_list`, which the roadmap adds. Each tool gets a plain label for its ToolRow ("Took screenshot", "Read network log", "Opened page", "Switched tab", "Sent request", "Read cookies", "Read file", "Wrote file", "Listed files"), set in `BrowserAgentToolStyle` beside an SF Symbol.
- **Untrusted output.** Every M3 tool result passes through the existing `ToolRegistry.makeResult` path, so it gets the API-key redaction and the `<untrusted_web_content>` wrapping (`UntrustedWebContent.wrap`). That includes file contents: a saved page is still page text.
- **Errors are results.** As in M1, a failing tool returns `Error: …` as its result and the loop carries on (requirements §4 "Common rules").
- **Step budget.** A step is one tool call, and the limit stays at 30 by default. The crawl acceptance check has to fit inside it, which is why `save_to` and the isolated-world file helper exist (see [Workspace](#workspace)).

## Tools

The limits below are the defaults. "Limit" means the truncation limit, `settings.browserAgentTruncationLimit`, which defaults to 20,000 characters.

### `screenshot` (in the page)

| | |
|---|---|
| Arguments | `area`: `visible` (default) or `full_page` |
| Returns | One image for the model, plus a text line: "Screenshot of <url>, <w>×<h> pt, <visible\|full page>" |
| Limits | Uses `WKWebView.takeSnapshot`. The image is JPEG at quality 0.6, scaled to at most 1,280 px wide. `full_page` is capped at 8 screen heights; anything longer is cut, and the text line says so. Timeout 10 s |
| Security | Shown only when `ModelSelection.supportsImageInput` is true. Otherwise `m3` leaves the tool out of the list (requirements §6). That flag is per provider today, so a text-only model on a vision provider gets a provider error back as the tool result, and the Agent explains it. The image is page content |
| Code | `AgentBridge.screenshot(area:)` (new) and `ToolRegistry+Page.swift` |

**How images travel.** `AgentModelToolResult` gets `images: [AgentImage]` (new, Codable: `mediaType`, base64 `data`; the field defaults to empty, so older history still decodes). `AIService.makeToolRequest` then encodes images per provider family, following the table in [m0-module-map.md](m0-module-map.md) under "ModelProviders":
- Anthropic: an `image` block inside the `tool_result` content.
- Gemini and Vertex: an `inlineData` part beside the `functionResponse`.
- OpenAI-compatible and Ollama: tool messages can't carry images in Chat Completions, so a `user` message with the image (`image_url` with a data URL, or Ollama's `images`) follows the tool messages.

**History.** Only the 2 newest screenshots stay as images in the history sent to the model. Older ones become the text "[screenshot omitted, taken at step N]", which keeps token use flat. The task record keeps every image (see [Task export](#task-export)).

### `network_log` (in the page)

| | |
|---|---|
| Arguments | `url_filter` (optional substring, case-insensitive), `limit` (1 to 200, default 50), `include_bodies` (default false) |
| Returns | The newest entries first, as JSON lines: `time`, `kind` (`fetch`/`xhr`), `method`, `url`, `status`, `duration_ms`, `content_type`, `response_bytes`, and with `include_bodies`, `response_preview` (text and JSON only, the first 2,000 characters) |
| Limits | A ring buffer of 200 entries per page load, kept in the page. It covers only `fetch` and XHR, not workers, beacons, `<img>`/`<form>` loads or WebSockets ([m0-csp-and-worlds.md](m0-csp-and-worlds.md)) |
| Security | The hook lives in the page world, so the page can see it and forge entries: the result is untrusted. The hook never records `Cookie`, `Set-Cookie` or `Authorization` headers; it records no request headers at all |
| Code | A document-start `WKUserScript` in `.page` (`AgentPageCapture.swift`, new) that wraps `fetch` and `XMLHttpRequest`. The app pulls the buffer with `evaluateJavaScript(…, in: nil, contentWorld: .page)`, as M0 found it must. `AgentBridge.networkLog(...)` (new) |

The same script also keeps a **console buffer** (the newest 200 `console.*` lines from the page world, each cut to 500 characters) for developer mode. It is not a tool: `run_js` already returns the console output of its own code.

### `navigate` (outside the page)

| | |
|---|---|
| Arguments | `url` (required; `http`, `https` or `about:blank`), `wait` (`load` (default) or `none`) |
| Returns | `{url, title, status, load_ms}` once the active tab finishes loading (or at once with `wait: none`). `status` is the main document's HTTP status when WebKit reports it |
| Limits | Timeout 30 s. A timeout returns what loaded so far, marked `"timed_out": true` |
| Security | Other schemes (`javascript:`, `file:`, app URL schemes) are refused. Scripts and the network hook are injected as on any load |
| Code | `ForumBrowserModel.load(_:)` on the active tab, awaited through a navigation continuation (new). `ToolRegistry+Browser.swift` |

### `tabs` (outside the page)

| | |
|---|---|
| Arguments | `action` (required): `list`, `open`, `close` or `switch`. Then `url` (for `open`), `tab_id` (for `close` and `switch`) and `background` (for `open`, default false) |
| Returns | The tab list after the action: `[{tab_id, title, url, active, loading}]` |
| Limits | At most 8 tabs. The last tab can't be closed. Tab IDs are short and stable for the tab's life (`t1`, `t2`, …) |
| Security | None beyond `navigate`'s scheme rule. Every tab shares `WKWebsiteDataStore.default()`, so logins carry over |
| Code | `BrowserTabs` (new, `BrowserTabs.swift`) owns one `ForumBrowserModel` per tab. `ToolRegistry+Browser.swift` |

**Page tools follow the active tab.** `BrowserAgentSession` keeps one `AgentPageDriving`, now `ActiveTabPageDriver` (new). It forwards every call to the bridge of whichever tab is active, so `read_page`, `run_js` and the other page tools need no `tab_id`. `tabs open` without `background` and `tabs switch` change the active tab, and the user sees the switch. Background tabs stay loaded until iOS reclaims them. A reclaimed tab reloads when it becomes active again, reusing `handleWebContentTermination` (the risk m0-module-map lists under "Multiple Tabs").

### `http_request` (outside the page)

| | |
|---|---|
| Arguments | `url` (required, `http`/`https`), `method` (`GET` (default), `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`), `headers` (object of strings), `body` (string), `send_cookies` (default false), `timeout` (1 to 120 s, default 30), `save_to` (an optional workspace path) |
| Returns | `{status, url (after redirects), headers, body}` as text. With `save_to`, the body goes to that file, and the result holds the path, the size and a 500-character preview instead of `body`. A binary body without `save_to` returns `"binary, N bytes, <content-type>"` |
| Limits | Downloads stop at 20 MB. A body over the limit is saved to `results/` automatically (see [Workspace](#workspace)). Redirects are followed, up to 10 |
| Security | Runs on its own ephemeral `URLSession` with `httpShouldHandleCookies = false`, so browser cross-origin rules don't apply (requirements §4). With `send_cookies`, the app builds a `Cookie` header from `WKHTTPCookieStore` for the URL, httpOnly cookies included. A `Set-Cookie` in the response is **not** written back to the browser, and it is dropped from the returned headers. The model may set any header itself, `Cookie` included. On forum hosts the existing request pacing applies (`ForumRequestPacing.swift`) unless the Settings switch turns it off (requirements §2). The audit log records the full URL (requirements §8). Confirmation follows [Confirm before writes](#confirm-before-writes) |
| Code | `AgentHTTPClient` (new, `AgentNetworkTools.swift`) and `ToolRegistry+Network.swift` |

### `cookies_get` (outside the page)

| | |
|---|---|
| Arguments | `domain` (required, for example `example.org`), `name` (optional) |
| Returns | `[{name, value, domain, path, expires, http_only, secure, same_site}]` for every cookie whose domain is `domain` or a parent of it |
| Limits | At most 200 cookies |
| Security | Reads `WKWebsiteDataStore.default().httpCookieStore.allCookies()`, httpOnly included, as requirements §4 asks. The values go to the model, and the export removes them (see [Task export](#task-export)). Confirmation follows [Confirm before writes](#confirm-before-writes) |
| Code | `ToolRegistry+Network.swift` |

### `file_read`, `file_write`, `file_list` (workspace)

| Tool | Arguments | Returns |
|---|---|---|
| `file_read` | `path` (required), `offset` (characters, default 0), `length` (default and maximum: the limit) | A header line, "path · characters a–b of N", then the text. When more remains, it ends with "more: call again with offset b" |
| `file_write` | `path` (required), `content` (required), `mode`: `overwrite` (default) or `append` | `{path, bytes_written, size}` |
| `file_list` | `path` (default the root), `recursive` (default false) | `[{path, type, size, modified}]`, at most 500 entries, then "N more" |

- **Paths** are relative to the workspace root, at most 255 characters, with no absolute paths and no `..`. A path is resolved and standardised, and refused unless it is still inside the root (which stops symlink escapes).
- **Text only.** `file_read` decodes UTF-8. A binary file returns "binary file, N bytes, <type>".
- **Size caps.** One file is at most 50 MB and the whole workspace at most 1 GB. Going over returns an error that names the cap.
- **Writes are atomic** (`Data.write(options: .atomic)`; `append` uses a `FileHandle` and then `synchronize()`), so a kill mid-task never leaves a half-written file.
- **No delete tool.** The user deletes files in the Files app. Requirements and the roadmap list none.
- **Code:** `AgentWorkspace` (new, `AgentWorkspace.swift`) holds every rule above; `ToolRegistry+Workspace.swift` holds the tools.

## Workspace

- **Where.** The app's `Documents/` folder is the workspace root. `Info.plist` gets `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` set to true (through `scripts/generate_project.rb` if it writes those keys, otherwise in `WukongMind/Info.plist`). The Files app then shows it as **On My iPhone › WukongMind**. Scripts, state and records stay in Application Support, where they are today, out of the user's sight.
- **Saving big results** (roadmap §7). In `ToolRegistry.makeResult`, any output over the limit is written whole to `results/<task-id>/<step>-<tool>.txt`. The model then gets, inside the usual untrusted wrapper:
  - "Saved to results/…/07-http_request.txt (184,220 characters).";
  - a preview of the first 2,000 characters;
  - "Read more with file_read(path, offset)."

  `ToolDispatchResult` keeps `wasTruncated`/`totalCharacterCount` and gains `savedPath`. If the workspace is unavailable (full, or the write fails), it falls back to today's truncation marker.
- **`save_to`.** `read_page`, `run_js` and `http_request` take an optional `save_to`, which writes the full result straight to a workspace file and returns only the path, the size and the preview. That is the direct way from tool to file. It costs the model no output tokens, so it doesn't need `file_write`.
- **Isolated-world file helper.** The isolated world `run_js` runs in gets `wukong.files.write(path, text)` and `wukong.files.append(path, text)`. They go through the existing `wukongAgent` reply handler (`AgentBridge.replyRouter`) to `AgentWorkspace`, with the same rules and caps. They aren't in the page world, so a page can't write files. One `run_js` can then fetch pages 1 to 25 of a thread (same-origin `fetch` with the page's cookies) and save each one, all in one step.
- **The layout is agreed in the prompt only** (roadmap §7). `BrowserAgentPrompt.system` gains a short "Workspace" section:
  - put a crawl's raw pages in `crawls/<host>/<slug>/page-001.txt`, and so on;
  - keep a running `notes.md` beside them;
  - per-site notes go in `sites/<host>/notes.md`;
  - read big files back with `file_read` ranges, then write the summary.

  The code knows only `results/`. Everything else is a convention the model follows.
- **Kill mid-task.** Every file write is atomic and done before the tool returns, so whatever was written stays. The conversation itself stays in memory, as today. After a relaunch the task is in the audit log and can be exported from there (see [Audit log](#audit-log)).

## Confirm before writes

`settings.agentConfirmBeforeWrites` already exists and is saved (`Models.swift:112`). It defaults to off. M3 makes it work, and removes the "M3" seal and the "starts working with the M3 safety update" footer from Settings › Agent.

- **What asks.** Requirements §8 names `http_request` (every method), `cookies_get`, and form submits by the Agent. The form-submit case is a main-frame navigation with `navigationType == .formSubmitted` or `.formResubmitted` while an Agent run is going. The navigation delegate holds it in `decidePolicyFor` until the user answers. Submits through `fetch` don't count: they are `run_js` calls, and the roadmap doesn't count them.
- **How it asks.** The run pauses, and an inline card appears in the conversation under the pending ToolRow:
  - the card uses the Message pattern's plain Agent text on `surface`: "Send a POST request to api.example.org/v1/items?", "Read 14 cookies for example.org?" or "Submit the form on example.org/login?";
  - beneath the text, the full URL in `code` style;
  - two Buttons: **Allow** (primary) and **Don't allow** (secondary).

  Stop also cancels it. A refusal returns "The user declined this action." as the tool's error result, and the Agent explains in the conversation (rule 5 of the six product rules).
- **Code.** `AgentConfirmationGate` (new), an `@Observable` queue of pending confirmations. The tool awaits it, and the transcript renders it.

## Audit log

Today's `SettingsAuditLogPage` (`SettingsAssistantPages.swift:358`) lists `browserAgent.runs` from memory. M3 saves it to disk.

- **What is recorded:** one JSON line per tool call, with:
  - time, task ID, step number, tool name and duration;
  - the arguments (the JSON, cut to 4,000 characters, with secrets redacted);
  - the result summary (500 characters at most), the error flag, and whether the result was truncated or saved (with its path);
  - the page URL;
  - for `http_request`, the full target URL and the method, always (requirements §8).

  A task line opens each task: the prompt (first 500 characters), model, provider and start time. A closing line ends it: the outcome, steps, tokens and duration. Full results are not in the audit log; they are in the task record.
- **Where:** `Application Support/WukongMind/AuditLog/<yyyy-mm-dd>.jsonl`, appended through a serial queue.
- **Retention:** 30 days or 20 MB in total, whichever is smaller. The oldest days are deleted at launch.
- **Where it shows** (design-unified "Phases" table and Settings › Agent):
  - Settings › Agent › Records › **Audit log** (a ListRow showing the step count).
  - The panel's ⋯ menu › **Audit log**.
  - An expanded ToolRow's quiet Button, **View in audit log**, which opens that task at that step.
- **The page:** a grouped `Form` with one section per day. Each task is a ListRow (the prompt's first line, then "host · N steps · time", and an error Seal when a step failed) that pushes the task's steps. A step row shows the plain label, then the argument summary and result summary in `caption` style, then the time and duration. In developer mode it also shows the code name and the arguments JSON (today's behaviour). At the bottom, **Clear audit log** is a destructive Button with one confirmation, because it can't be undone.
- **Workspace row:** Settings › Agent › Records › **Workspace** shows the folder's size and opens the Files app at it (`shareddocuments://` plus the folder path). If that URL can't open, the footer reads "In the Files app: On My iPhone › WukongMind".
- **Code:** `AuditLog` (new, `AuditLog.swift`). `BrowserAgentSession` feeds it from `AgentLoopEvents.onStepFinished` and the run's start and end.

## Task records

Task export needs more than the audit log has: every model request and response and every full tool result. So each run also writes a **task record**.

- **Where:** `Application Support/WukongMind/Tasks/<task-id>.jsonl`, one line per event, appended as it happens. That makes it safe across a kill, and it grows linearly with the steps.
  - `request`: turn number, the history length at that turn (the full request is `system` + `tools` + the first N history turns), and a hash of the system prompt and tool list. Each new system prompt or tool list is written once.
  - `raw_request` and `raw_response`: the provider's HTTP bodies, verbatim (see [Developer mode](#developer-mode-part-1)).
  - `response`: the parsed `AgentModelTurnResponse` (text, tool calls, stop reason, tokens), with the model and provider.
  - `tool_result`: the call ID, name, arguments, the content the model got (`modelContent`), images, error flag, saved path and duration.
- **Retention:** the newest 50 tasks or 200 MB. Older records are deleted at launch. The audit log outlives them, so an old step keeps its summary and loses only its export.
- **Codable gaps:** `AgentModelTurnResponse` and `AgentToolDefinition` are not Codable today, while `AgentModelTurn`, `AgentModelToolCall` and `AgentModelToolResult` are. Task 6 makes both Codable. `AgentToolDefinition` encodes as name, description and `inputSchema`.
- **Code:** `TaskRecordStore` (new, `TaskRecord.swift`).

## Developer mode, part 1

**The one switch** is `settings.agentDeveloperMode`, in Settings › Agent › Developer. It defaults to off, and while it is off no developer entry shows (roadmap §8). `AppSettings` also has an older `developerMode` (`Models.swift:165`). It feeds `AgentStatusLine` today and is set by DEBUG launch arguments (`AppModel+Browse.swift:316`). Task 7 folds it into `agentDeveloperMode`: the launch arguments set the new flag, and the old key is decoded once and then dropped. The switch loses its "M3" seal, and its subtitle becomes "Show raw requests, tokens per step and task export".

**What it shows**

| Roadmap §8 item | Where | How (existing patterns only) |
|---|---|---|
| Full request and raw response, with the system prompt and tool definitions | An expanded ToolRow, section "Model step" | Two rows, **Request** and **Response**, each showing its size. Each opens the M2 "View code" sheet pattern (`.sheet`, `[.medium, .large]`, selectable monospaced text, Copy and Share). The request is shown pretty-printed, with the API key removed |
| Per-step tokens and model | The same section | "Turn 3 · claude-sonnet-5-5 · 1,204 in · 86 out". The rows of one model turn share the line, and the first of them shows it |
| The final reply's turn (no tool call) | Under the Agent's last message | A quiet Button, **Details**, opening the same sheet |
| Token total | Status line | Already built: "Done · 3 steps · 9 s · 6.4k tokens" |
| Tool code name and duration | The collapsed ToolRow | The code name in `code` style and the duration at the trailing edge (the design system's ToolRow README) |
| Page console and network requests | This page popover › **Developer** group | Two ListRows, **Console** (N lines) and **Network** (N requests). They push monospaced lists from the console buffer and the `network_log` ring buffer of the active tab, newest first, each with Copy. design-unified puts only the Learn-on-ask site inspector in this group; M3 adds these two rows to it first |
| Task export | ⋯ menu › **Export task**; Audit log › a task › **Export** | See below |

**Raw capture.** `AIService.completeToolTurn` gains an optional `AgentWireRecorder` (new protocol). Called with the `URLRequest` and the response `Data`, it stores:
- the URL with the `key` query item removed (Gemini puts the key there; see `makeToolRequest`);
- the method;
- the body;
- the response status and body.

It never stores request headers, so `x-api-key`, `x-goog-api-key` and `Authorization` never reach it. The existing `redactSecrets` then runs over both bodies. Capture always runs while a task record is written, whether or not developer mode is on, so a task done with the switch off can still be exported later. Developer mode only decides what is shown.

## Task export

- **The file:** one JSON document, `wukong-task-<yyyy-mm-dd>-<slug>.json`, shared through the system share sheet (`ShareLink` of a temporary file, as script export does in design-m2). It holds:
  - `format`: "wukongmind-task", `version`: 1;
  - the app's version and build, and the export time;
  - provider and model, and the step limit and truncation limit;
  - the page URL at the start and at each request;
  - `systems` and `tool_sets`, each stored once and referred to by hash;
  - `history` (the full `[AgentModelTurn]` transcript);
  - `turns[]`: each turn's request reference (system hash, tool set hash, history length), `raw_request`, `raw_response`, the parsed `response`, and that turn's `tool_results` (with images as base64 JPEG).
- **"Every turn's full request"** (roadmap §8) is kept by reference: system + tools + the first N turns of `history` rebuild the exact request, and `makeToolRequest` turns that back into the provider body. The raw bodies are kept as well while the file stays under 25 MB. Past that, the raw request bodies of the middle turns are dropped (first and last kept) and listed in `omitted_raw_requests`; the responses are always kept. Repeating every full body would grow with the square of the steps.
- **Prompt before export** (roadmap §8): an alert. Title "Export this task?". Message: "The file includes the pages and results the Agent read. API keys and cookies are removed." Buttons: **Export** and **Cancel**.
- **No API keys:**
  - keys are never captured (see the raw capture above);
  - the exporter also runs `redactSecrets` over the whole file with every configured key;
  - a unit test checks that no key string survives.
- **No cookies.** Cookies can enter through `cookies_get`, through `Cookie` headers the model wrote in `http_request`, and through `document.cookie` read by `run_js`, and then they repeat in every later request. So the exporter:
  1. replaces each `value` in `cookies_get` results with `"[cookie]"`;
  2. drops `Cookie` and `Set-Cookie` headers wherever they appear;
  3. reads every cookie value for the hosts the task touched from `WKHTTPCookieStore` at export time, and replaces every occurrence of a value 8 characters or longer, anywhere in the file, with `[cookie]`.
- **Replay.** `RecordedModelClient` is a private class inside `AgentLoopTests` today. Task 7 moves it to `WukongMindTests/Support/RecordedModelClient.swift` (new). It also adds:
  - `TaskExport.load(_:) -> (responses: [AgentModelTurnResponse], toolResults: [String: AgentModelToolResult], …)` in the app target (`TaskExport.swift`), so the app and the tests decode with the same code;
  - `ReplayToolRegistry` (test support), which registers every tool named in the file and returns the recorded result for each call ID.

  Tool results replay from the record and don't run live, because the page isn't there. Redacted placeholders don't matter, because the model's replies are recorded too. A replay test feeds the file to `AgentLoop` and asserts:
  - the tool-call sequence (names and arguments) matches the record;
  - the final text and step count match;
  - the file holds no configured key and no `[cookie]`-replaced value.

  Fixtures go in `WukongMindTests/Fixtures/TaskExports/`. Turning a failed task into a regression test is then: drop the file there, then add a test that loads it and asserts the tool sequence you expected instead.

## UI touch points (One panel style)

Everything below sits in the One panel conversation view (`AssistantPanel`, `SummaryPanel.swift:27`; tool rows in `AgentPanel.swift`, `BrowserAgentToolRowView`). It is described in words with existing components.

- **ToolRow for the new tools.** The same row with a plain label and a result summary: "Took screenshot · full page", "Read network log · 38 requests", "Opened page · example.org/t/123", "Switched tab · 3 tabs", "Sent request · 200 · 48 KB", "Read cookies · 14", "Read file · 20,000 of 184,220", "Wrote file · crawls/…/page-007.txt", "Listed files · 26". A result saved to the workspace adds a quiet **Open in Files** Button to the expanded row, under the result. A screenshot's expanded row shows the image as a thumbnail (`radius-md`, `hairline` edge), which opens full size in a sheet.
- **Developer mode in the expanded row:** see the table above. The collapsed row adds the code name and duration only in developer mode.
- **Confirmation card:** see [Confirm before writes](#confirm-before-writes).
- **⋯ menu:** **Audit log** (always) and **Export task** (developer mode only, enabled once the conversation has a finished task), as design-unified draws it.
- **Settings › Agent:** the Safety, Records and Developer sections already exist. M3 adds the Workspace row, makes the Audit log row open the on-disk log, and removes the "M3" seals and placeholder footers.
- **This page › Developer:** the Console and Network rows, in developer mode only.
- **Browser bar:** a tab button with the tab count, beside Home, as design-unified's "Phases" table says ("A tab button in the browser bar, beside Home, opening a tab overview"). No board draws the overview: see [Open questions](#open-questions).
- **Accessibility:** new rows follow the ToolRow labels ("Sent request, 200, collapsed"). The confirmation card is announced when it appears (`AccessibilityNotification.Announcement`), and its buttons are at least 44 pt. **New identifiers:**
  - `agentConfirmCard`, `agentConfirmAllow`, `agentConfirmDeny`;
  - `agentToolOpenInFiles`, `agentToolScreenshot`;
  - `agentDevRequest`, `agentDevResponse`, `agentDevTurnLine`, `agentDevDetails`;
  - `exportTaskMenuItem`;
  - `auditTaskRow-<id>`, `auditStepRow-<n>`, `auditClear`, `settingsRow-workspace`;
  - `thisPageConsole`, `thisPageNetwork`;
  - `browserTabsButton`, `tabRow-<id>`.

## Acceptance checks

From next-phase §7 (marked "added") and requirements §9 M3, which still holds:

1. **Thread crawl.** On a non-Discourse forum thread of 20 or more pages, say "read the whole thread and summarize it". The raw pages land in the workspace (visible in Files), and the summary covers every page.
   - Check: every page file exists, and the summary cites something from each page range.
   - Expected path: `read_page`, then one or two `run_js` calls that fetch and save pages with `wukong.files`, then `file_read` ranges and the summary. That stays well under 30 steps.
   - The local check uses a fixture forum with 25 pages served by the existing UI-test fixture server (`WukongMindUITests/FixtureSpaForumServer.swift`). The live check uses a real forum on the device.
2. **Files survive a kill.** Kill the app mid-crawl and reopen it: the files written before the kill are there and whole, and the task shows in the audit log.
3. **Export replays.** Export that task (or a shorter recorded one) and add it as a fixture: a unit test replays it through `RecordedModelClient` and passes. The file holds no API key or cookie value.
4. **Saved reader** (requirements §9 M3): the Agent saves the thread-reading logic as a script for that site and reuses it on the next thread.
5. **No regressions:** all unit tests pass; `screenshot` is hidden for a model without image input; with Confirm before writes on, `http_request` asks before it runs.

## Task split

Seven implementation tasks and one acceptance task. Sizes count changed lines, tests included.

**Rules for every task:**
- Adding a file means regenerating `WukongMind.xcodeproj` with `ruby scripts/generate_project.rb` (CI's drift check). On a rebase, regenerate it; never hand-merge `project.pbxproj`.
- New strings go into `Localizable.xcstrings`. On a conflict, take main's file and re-add your keys.
- Each tool family has its own new file. Shared files take only small edits in named places: `ToolRegistry.swift` (the `m3` factory list), `BrowserAgent.swift`, `AppModel.swift` (`browserAgent`).
- Done means the unit tests pass: `xcodebuild test … -only-testing:WukongMindTests`, as in [docs/DEVELOPMENT.md](../DEVELOPMENT.md). Each task adds unit tests that need no simulator where it can, with WebKit tests on local fixture HTML only, and model calls recorded (requirements §9).

**Waves** (tasks in a wave can run at the same time):
- Wave A: tasks 1, 3 and 6.
- Wave B: tasks 2, 4 and 5.
- Wave C: task 7.
- Then task 8.

The shared files inside a wave are edited in separate places:
- In wave A, task 1 edits the prompt and the factory, task 6 edits the session events, and task 3 edits browser ownership in `AppModel`.
- In wave B, tasks 2, 4 and 5 each add one factory line plus their own new files. Task 2 also edits `AgentBridge.swift` and `AIService.swift`, task 4 the browser files, and task 5 `SummaryPanel.swift` (the card).

### 1. M3 1: Workspace, file tools and saving big results
- **Scope:** `AgentWorkspace.swift` (new), `ToolRegistry+Workspace.swift` (new), `ToolRegistry.swift` (`AgentToolContext` and the `m3` factory, saving in `makeResult`, `savedPath`), `BrowserAgent.swift` (the prompt's Workspace section), `AgentBridge.swift` (only the `wukong.files` reply route), `AppModel.swift` (`registryBuilder` to `.m3`), `Info.plist` / `scripts/generate_project.rb` (Files keys), and the tests `AgentWorkspaceTests.swift` (new) and `ToolRegistryTests.swift`.
- **Size:** about 550. **Depends on:** nothing.
- **Done when:**
  - `file_read` (ranges), `file_write` (overwrite and append) and `file_list` work under the path rules and caps;
  - `..`, absolute paths and symlink escapes are refused (tests);
  - an over-limit result is saved under `results/` and the model gets the path, a preview and the size (test);
  - `save_to` works on `read_page` and `run_js` (task 5 adds it to `http_request` through the same helper);
  - `wukong.files.write` from isolated-world `run_js` writes a file, and the page world can't reach it (an `AgentBridgeTests` fixture);
  - the workspace shows in the Files app on the simulator (screenshot).

### 2. M3 2: Screenshot, network log and page console
- **Scope:** `AgentPageCapture.swift` (new, the page-world hook script and its buffers), `AgentBridge.swift` (`screenshot`, `networkLog`, `consoleLog`, installing the hook on each web view), `ToolRegistry+Page.swift` (new), `BrowserAgent.swift` (`AgentImage`, `AgentModelToolResult.images`, pruning screenshots in history), `AIService.swift` (images per provider family), and the tests `AgentPageCaptureTests.swift` (new) and `AgentLoopTests.swift` (wire format per family, through `RecordedToolURLProtocol`).
- **Size:** about 600. **Depends on:** 1 (the factory) and 3 (the hook goes into the per-tab web view setup).
- **Done when:**
  - on a fixture page that calls `fetch` and XHR, `network_log` returns both requests, with filtering and the limit working, and no cookie or auth headers;
  - `screenshot` returns a JPEG of at most 1,280 px, and `full_page` caps at 8 screens;
  - the wire-format tests show the image block for Anthropic, Gemini, OpenAI-compatible and Ollama;
  - the tool is hidden when `supportsImageInput` is false;
  - only 2 images stay in history.

### 3. M3 3: Browser tabs
- **Scope:** `BrowserTabs.swift` (new: the tab list, the active tab, creating each `ForumBrowserModel` with the shared data store, reloading a reclaimed tab), `ActiveTabPageDriver` (new, same file), `ForumBrowser.swift` (only what lets it be one of many), `AppModel.swift` (`browser` reads the active tab), `PhoneBrowserBar.swift` and `SplitWorkspace.swift` (the tab button), `TabOverview.swift` (new; a plain list by default, see the open questions), and the tests `BrowserTabsTests.swift` (new).
- **Size:** about 600. If it grows past that, move `TabOverview.swift` into a follow-up task. **Depends on:** nothing.
- **Done when:**
  - the user can open, switch and close tabs (at most 8), and logins carry over;
  - the Agent's page tools act on the active tab (a test with two fake drivers);
  - existing browser, script and suggestion tests still pass;
  - there are UI tests for open, switch and close.

### 4. M3 4: `navigate` and `tabs` tools
- **Scope:** `ToolRegistry+Browser.swift` (new), `BrowserTabs.swift` (an awaitable load with a timeout), one factory line, labels in `BrowserAgentToolStyle`, and the tests `BrowserToolsTests.swift` (new).
- **Size:** about 300. **Depends on:** 1 and 3.
- **Done when:**
  - `navigate` returns the final URL, title and status on fixture pages, refuses `javascript:` and `file:`, and times out cleanly;
  - `tabs` list, open (in front and in the background), switch and close behave as specified, including the 8-tab cap and the last-tab rule;
  - a recorded-model test opens a second tab and reads it.

### 5. M3 5: `http_request`, `cookies_get` and confirm before writes
- **Scope:** `AgentNetworkTools.swift` (new: `AgentHTTPClient`, building cookie headers, pacing), `ToolRegistry+Network.swift` (new), `AgentConfirmationGate.swift` (new), `ForumBrowser.swift` (only the form-submit hold in `decidePolicyFor`), `SummaryPanel.swift` (rendering the confirmation card), `SettingsAssistantPages.swift` (removing the Safety seal and footer), and the tests `AgentNetworkToolsTests.swift` (new, a `URLProtocol` stub).
- **Size:** about 550. **Depends on:** 1 (`save_to` and saving). It runs beside 4: its `ForumBrowser.swift` edit is one delegate method.
- **Done when:**
  - methods, headers, body, timeout, redirects, the 20 MB cap and binary bodies work;
  - `send_cookies` attaches httpOnly cookies, and `Set-Cookie` is neither returned nor stored;
  - `cookies_get` matches parent domains;
  - with the switch on, both tools and a fixture form submit wait for Allow, and Don't allow returns the declined error (tests);
  - the audit log line holds the full URL (once 6 lands; otherwise checked in 7).

### 6. M3 6: Audit log on disk and task records
- **Scope:** `AuditLog.swift` (new), `TaskRecord.swift` (new), `BrowserAgent.swift` (Codable for `AgentModelTurnResponse` and `AgentToolDefinition`, a task ID per run, feeding both stores from the session), `SettingsAssistantPages.swift` (the audit log page on disk, its task and step pages, Clear, the Workspace row), `SummaryPanel.swift` (⋯ › Audit log, and View in audit log), and the tests `AuditLogTests.swift` (new).
- **Size:** about 550. **Depends on:** nothing. The `savedPath` field comes from 1; until then, record it when present.
- **Done when:**
  - every tool call writes one line with the fields above, and `http_request` lines hold the full URL;
  - the retention rules hold (a test with a fake clock);
  - the log and task records survive relaunching the app (a test reopens the store);
  - the page groups by day and then by task;
  - a record file reads back into the same turns.

### 7. M3 7: Developer mode part 1 and task export
- **Scope:** `AIService.swift` (`AgentWireRecorder`), `TaskExport.swift` (new: build, redact, load), `BrowserAgent.swift` (per-turn model and tokens on the rows), `AgentPanel.swift` (the ToolRow's developer mode: code name, duration, the Model step section, Details), `SummaryPanel.swift` (⋯ › Export task and the alert), `ScriptViews.swift` (`PageCapabilitiesView`, the This page popover: the Console and Network rows), `Models.swift` (folding `developerMode` in), `SettingsAssistantPages.swift` (the switch's text), and the tests `WukongMindTests/Support/RecordedModelClient.swift` (moved), `TaskExportTests.swift` (new) and `Fixtures/TaskExports/` (one recorded task).
- **Size:** about 600. **Depends on:** 6 (records) and 2 (the console and network buffers).
- **Done when:**
  - with the switch off, no developer entry shows (a UI test);
  - with it on, the raw request and response, and the turn's model and tokens, show for a step;
  - the export alert appears, and the share sheet gets one JSON file;
  - the file holds no API key, including Gemini's URL key (test), and no cookie value (a test with seeded cookies);
  - the fixture replays through `RecordedModelClient` with the same tool sequence and final text.

### 8. M3 acceptance and 1.2.0
- **Scope:** run the [acceptance checks](#acceptance-checks) on a simulator and on the owner's iPhone, with a proof artifact. Write `docs/wukongmind/m3-acceptance.md`, check in the fixture forum, and add the exported crawl task as a replay fixture. Bump `marketing_version` to `1.2.0` in `scripts/generate_project.rb`, regenerate the project, and update the README version table. Fix only small defects; anything bigger goes back to the owner.
- **Size:** about 300, mostly fixtures and docs. **Depends on:** 1 to 7.
- **Done when:** all five checks pass with proof, the unit tests are green, and the owner has been asked on an approval card before `v1.2.0` is tagged ([README](README.md) "Release steps per milestone").

## Conflicts called out

- **Truncation versus saving to a file.** Requirements §4 says output over the limit "is truncated and marked". The roadmap (§7, which wins) saves it to a file and gives the path, a preview and the size. This design follows the roadmap and keeps the old marker only as a fallback.
- **`file_list` and range reads** are in the roadmap, not in requirements §4. Added, since the roadmap wins.
- **"Layout in the prompt only" against paths the code must choose.** Automatic saving needs a folder the code picks, `results/`. design-unified (History, "Conversations") also says conversations join History "with M3's workspace (`tasks/`)". This design keeps `results/` as the only folder the code knows, and keeps task records in Application Support, not the workspace. Adding conversations to History is an open question.
- **One conversation per tab.** design-unified says the conversation belongs to the browser, "one now, one per tab from M3". A `tabs` tool that switches tabs mid-run fits better with one conversation for the browser that follows the active tab. This design keeps one conversation in M3. Open question.
- **Duration and code name.** Roadmap §8 says each tool call's arguments, result and duration need no developer mode. The design system's ToolRow shows the duration and code name only in developer mode. This design does both: the collapsed row hides them, and the expanded row always shows arguments, result and duration.
- **Requirements' M3 acceptance** (save the thread reader as a script and reuse it) isn't in the brief's list. The roadmap only adds checks, so it stays as check 4.
- **Confirm before writes and `file_write`.** Requirements §8 doesn't list file writes. They aren't confirmed here; see the open questions.
- **The brief's code pointers** (`AgentToolName`, `executeAgentTool`) are the old Research loop. M3 builds on `ToolRegistry`, as stated in [Decisions](#decisions).

## Open questions

Until the owner answers, tasks use the default in parentheses.

1. **Tab overview look.** No board draws it; only the bar's slot exists. (Default: a plain sheet holding a grouped list of ListRows, with the title and host, a check for the active tab, swipe to close and a **New tab** row. No thumbnail grid.)
2. **One conversation per tab or per browser.** (Default: one for the browser in M3. It follows the active tab and remembers across tabs.)
3. **Agent conversations in History,** which design-unified ties to M3. (Default: not in M3. Task records make export and the audit log work. History waits for One loop, which redoes the transcript anyway.)
4. **Should `file_write` ask when Confirm before writes is on?** (Default: no; it writes only inside the app's own folder.)
5. **Should `Set-Cookie` from `http_request` be stored in the browser?** (Default: no, to keep the browser's logins unchanged by the Agent.)
6. **Step limit for long crawls.** (Default: keep 30; the crawl fits through `save_to` and `wukong.files`. If acceptance shows otherwise, raise it to 50.)
7. **Are the retention numbers right?** (Default: audit log 30 days or 20 MB; task records 50 tasks or 200 MB; workspace cap 1 GB.)
