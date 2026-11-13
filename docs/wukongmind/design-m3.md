# M3 design: full abilities (1.2.0)

M3 gives the Agent abilities beyond reading and changing the current page. It can take screenshots, read network traffic, open and reload pages, make HTTP requests, read cookies and use a workspace of files. It also notices when it has broken a page ([page feedback](page-feedback.md)), and it gets an audit log saved on disk and part 1 of developer mode. This page is the design and the task split. Implementation tasks start once the owner accepts One panel.

Sources, in order of precedence: the owner's review of this design (2026-11-13), then [next-phase.md](next-phase.md) (§7 "M3 full abilities", §8 "Developer mode"), then [page-feedback.md](page-feedback.md) (roadmap §12, folded into M3 by the owner), then [requirements.md](requirements.md) (§3, §4, §6, §8, §9), then [design-unified.md](design-unified.md) for the UI touch points. The format follows [design-m2.md](design-m2.md). Where these sources disagree, the conflict is named in [Conflicts](#conflicts-called-out) rather than settled silently.

Line numbers in code references are as of `dbdef90` (main when this was revised).

**There is no new visual design.** Every UI piece reuses a component in [design/design-system/components](design/design-system/components) (ToolRow, ListRow, Message, Button, Seal, Switch, ResultCard) or an existing SwiftUI pattern. Two pieces have no drawn pattern, and the owner accepted these defaults:
- the **confirmation card** reuses the ScriptCard's card shell (`surface`, `hairline` edge, `radius-lg`) with plain text and two Buttons;
- the **screenshot thumbnail** is the image at `radius-md` with a `hairline` edge.

## Decisions

- **Where the tools live.** M3 tools extend the sole Agent loop:
  - `ToolRegistry` (`WukongMind/ToolRegistry.swift`, the `m1`/`m2` factories);
  - `AgentLoop` and `BrowserAgentSession` (`WukongMind/BrowserAgent.swift`);
  - `AgentBridge` (`WukongMind/AgentBridge.swift`).

  **They do not go into `AgentToolName` or `executeAgentTool`.** Those two (`Sites/SiteAdapter.swift:176`, `AppModel.swift:3287`) belong to the old Research loop, which roadmap §6 deletes in One loop.
- **One seam first.** Task 1 adds `ToolRegistry.m3(...)`, a factory that wraps `m2` and takes an `AgentToolContext` (new): the bridge, the workspace, the cookie store, the confirmation gate and the settings.
  - Each tool family gets its own new file: `ToolRegistry+Workspace.swift`, `ToolRegistry+Capture.swift` (`screenshot`, `network_log`), `ToolRegistry+Navigation.swift` (`navigate`, `reload_page`) and `ToolRegistry+Network.swift`.
  - Task 1 creates all four, leaving the three it doesn't fill with empty tool lists. The factory calls all four, so later tasks edit only their own file.
  - `AppModel.browserAgent`'s `registryBuilder` switches from `.m2` to `.m3` once, in task 1.
- **Tool names stay as requirements §4 lists them**, plus `file_list` (roadmap §7) and `reload_page` (page feedback). `tabs` is not in M3 (see [Not in M3](#not-in-m3)).
- **ToolRow labels have two tenses**: one while running, one when done. `DCToolLabel.browser(_:running:)` (`ConversationViews.swift:33`) already does this for the M1 and M2 tools. Task 1 adds every new tool:

  | Tool | Running | Done |
  |---|---|---|
  | `screenshot` | Taking screenshot | Took screenshot |
  | `network_log` | Reading network log | Read network log |
  | `navigate` | Opening page | Opened page |
  | `reload_page` | Reloading page | Reloaded page |
  | `http_request` | Sending request | Sent request |
  | `cookies_get` | Reading cookies | Read cookies |
  | `file_read` | Reading file | Read file |
  | `file_write` | Writing file | Wrote file |
  | `file_list` | Listing files | Listed files |

  The owner's example is "Reading file…". The trailing ellipsis follows whatever `DCToolLabel` does for the existing tools.
- **Untrusted output.** Every M3 tool result passes through the existing `ToolRegistry.makeResult` path, so it gets the API-key redaction and the `<untrusted_web_content>` wrapping (`UntrustedWebContent.wrap`). That includes file contents: a saved page is still page text.
- **Errors are results.** As in M1, a failing tool returns `Error: …` as its result and the loop carries on (requirements §4 "Common rules").
- **Step budget.** A step is one tool call, and the limit stays at 30 by default. If acceptance shows the crawl doesn't fit, raise it to 50. The crawl acceptance check has to fit inside the limit, which is why `save_to`, the isolated-world file helper and history trimming exist; the arithmetic is in [Workspace](#workspace).
- **Owner decisions (2026-11-13), formerly open questions:**
  - one conversation for the browser;
  - Agent conversations don't join History in M3;
  - `file_write` never asks;
  - `Set-Cookie` from `http_request` is never stored in the browser;
  - the retention numbers below are accepted.

## Tools

The limits below are the defaults. "Limit" means the truncation limit, `settings.browserAgentTruncationLimit`, which defaults to 20,000 characters.

### `screenshot` (in the page)

| | |
|---|---|
| Arguments | `area`: `visible` (default) or `full_page` |
| Returns | One image for the model, plus a text line: "Screenshot of <url>, <w>×<h> pt, <visible\|full page>" |
| Limits | Uses `WKWebView.takeSnapshot`. The image is JPEG at quality 0.6, scaled to at most 1,280 px wide. `full_page` is capped at 8 screen heights; anything longer is cut, and the text line says so. Timeout 10 s |
| Security | Shown only when `ModelSelection.supportsImageInput` is true. Otherwise `m3` leaves the tool out of the list (requirements §6). That flag is per provider today, so a text-only model on a vision provider gets a provider error back as the tool result, and the Agent explains it. The image is page content |
| Code | `AgentBridge.screenshot(area:)` (new) and `ToolRegistry+Capture.swift` |

**How images travel.** `AgentModelToolResult` gets `images: [AgentImage]` (new, Codable: `mediaType`, base64 `data`). The field defaults to empty, so older history still decodes. `AIService.makeToolRequest` then encodes images per provider family, following the table in [m0-module-map.md](m0-module-map.md) under "ModelProviders":
- Anthropic: an `image` block inside the `tool_result` content.
- Gemini and Vertex: an `inlineData` part beside the `functionResponse`.
- OpenAI-compatible and Ollama: tool messages can't carry images in Chat Completions. So a `user` message with the image follows the tool messages (`image_url` with a data URL, or Ollama's `images`).

**History trimming** (`AgentHistoryPruner`, new, in `BrowserAgent.swift`) runs each time a request is built:
- Only the images of the 2 newest image-bearing results stay. Each older image becomes "[screenshot omitted, taken at step N]".
- Only the 3 newest `file_read` results stay whole (see [Workspace](#workspace)).
- The session's history and the task record keep everything; only the request is trimmed. Replay applies the same pruner, which is deterministic.

### `network_log` (in the page)

| | |
|---|---|
| Arguments | `url_filter` (optional substring, case-insensitive), `limit` (1 to 200, default 50), `include_bodies` (default false) |
| Returns | The newest entries first, as JSON lines: `time`, `kind` (`fetch`/`xhr`), `method`, `url`, `status`, `duration_ms`, `content_type`, `response_bytes`, and with `include_bodies`, `response_preview` (text and JSON only, the first 2,000 characters) |
| Limits | A ring buffer of 200 entries per page load, kept in the page. It covers only `fetch` and XHR, not workers, beacons, `<img>`/`<form>` loads or WebSockets ([m0-csp-and-worlds.md](m0-csp-and-worlds.md)) |
| Security | The hook lives in the page world, so the page can see it and forge entries: the result is untrusted. The hook records no request headers at all, so `Cookie` and `Authorization` never reach it, and it drops `Set-Cookie` |
| Code | A document-start `WKUserScript` in `.page` (`AgentPageCapture.swift`, new) that wraps `fetch` and `XMLHttpRequest`. The app pulls the buffer with `evaluateJavaScript(…, in: nil, contentWorld: .page)`, as M0 found it must. `AgentBridge.networkLog(...)` (new) |

The same script also keeps a **console buffer** for developer mode: the newest 200 `console.*` lines from the page world, each cut to 500 characters. It is not a tool, because `run_js` already returns the console output of its own code.

### `navigate` and `reload_page` (the one page)

| | `navigate` | `reload_page` |
|---|---|---|
| Arguments | `url` (required; `http`, `https` or `about:blank`), `wait` (`load` (default) or `none`) | none |
| Returns | `{url, title, status, load_ms}` once the page finishes loading, or at once with `wait: none`. `status` is the main document's HTTP status when WebKit reports it | The same, plus "Unsaved changes from this conversation were dropped; N saved scripts were injected again." |
| Limits | Timeout 30 s. A timeout returns what loaded so far, marked `"timed_out": true` | The same |
| Security | Other schemes (`javascript:`, `file:`, app URL schemes) are refused. Scripts and the hooks are injected as on any load | None new |

Both act on the browser's single page (`ForumBrowserModel`). `ForumBrowserModel` gains an awaitable load and reload: a navigation continuation (new) that its navigation delegate resumes. `AgentPageDriving` gets `load(_:timeout:)` and `reload(timeout:)`, and the tools live in `ToolRegistry+Navigation.swift`. A URL change during either tool skips the page-change comparison (see [Page feedback](#page-feedback)).

### `http_request` (outside the page)

| | |
|---|---|
| Arguments | `url` (required, `http`/`https`), `method` (`GET` (default), `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`), `headers` (object of strings), `body` (string), `send_cookies` (default false), `timeout` (1 to 120 s, default 30), `save_to` (an optional workspace path) |
| Returns | `{status, url (after redirects), headers, body}` as text. With `save_to`, the body goes to that file, and the result holds the path, the size and a 500-character preview instead of `body`. A binary body without `save_to` returns `"binary, N bytes, <content-type>"` |
| Limits | Downloads stop at 20 MB. A body over the limit is saved to `results/` automatically (see [Workspace](#workspace)). Redirects are followed, up to 10 |
| Security | Runs on its own ephemeral `URLSession` with `httpShouldHandleCookies = false`, so browser cross-origin rules don't apply (requirements §4). With `send_cookies`, the app builds a `Cookie` header from `WKHTTPCookieStore` with the **target site's** cookies (the site the request goes to, never the current page's), httpOnly cookies included. So a cross-site request uses the person's login at the target site. A `Set-Cookie` in the response is not written back to the browser, and it is dropped from the returned headers. The model may set any header itself, `Cookie` included. On forum hosts the existing request pacing applies (`ForumRequestPacing.swift`) unless the Settings switch turns it off (requirements §2). The audit log records the full URL (requirements §8). When it asks first: see [Confirmations](#confirmations) |
| Code | `AgentHTTPClient` (new, `AgentNetworkTools.swift`) and `ToolRegistry+Network.swift` |

### `cookies_get` (outside the page)

| | |
|---|---|
| Arguments | `domain` (required, for example `example.org`), `name` (optional) |
| Returns | `[{name, value, domain, path, expires, http_only, secure, same_site}]` for every cookie whose domain is `domain` or a parent of it |
| Limits | At most 200 cookies |
| Security | Reads `WKWebsiteDataStore.default().httpCookieStore.allCookies()`, httpOnly included, as requirements §4 asks. **Always asks first**, whatever the switch says (see [Confirmations](#confirmations)). The values go to the model, and the export removes them (see [Task export](#task-export)) |
| Code | `ToolRegistry+Network.swift` |

### `file_read`, `file_write`, `file_list` (workspace)

| Tool | Arguments | Returns |
|---|---|---|
| `file_read` | `path` (required), `offset` (characters, default 0), `length` (default and maximum: the limit) | A header line, "path · characters a–b of N", then the text. When more remains, it ends with "more: call again with offset b" |
| `file_write` | `path` (required), `content` (required), `mode`: `overwrite` (default) or `append` | `{path, bytes_written, size}` |
| `file_list` | `path` (default the root), `recursive` (default false) | `[{path, type, size, modified}]`, at most 500 entries, then "N more" |

- **Paths** are relative to the workspace root, at most 255 characters, with no absolute paths and no `..`. Each path is resolved and standardised, and refused unless it is still inside the root. That stops symlink escapes.
- **Text only.** `file_read` decodes UTF-8. A binary file returns "binary file, N bytes, <type>".
- **Size caps.** One file is at most 50 MB and the whole workspace at most 1 GB. Going over returns an error that names the cap.
- **Writes are atomic.**
  - `overwrite` uses `Data.write(options: .atomic)`.
  - `append` reads the current file, adds the new text, writes the whole result to a temporary file, and atomically replaces the old file with it.
  - One serial queue per workspace orders writes.

  A kill mid-task leaves each file either as it was or with the write complete, never half-written. An append costs a copy of the file, which the 50 MB cap keeps bounded.
- **Old reads leave history.** Only the 3 newest `file_read` results are sent in full. Each older one becomes one line: "[file_read omitted, re-read by path and offset: crawls/…/thread.md, offset 40000]". This is done by `AgentHistoryPruner`, the same way as screenshots.
- **No delete tool.** The user deletes files in the Files app. Neither the requirements nor the roadmap list one.
- **Code:** `AgentWorkspace` (new, `AgentWorkspace.swift`) holds every rule above, and `ToolRegistry+Workspace.swift` holds the tools.

## Workspace

- **Where.** The app's `Documents/` folder is the workspace root.
  - `Info.plist` gets `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` set to true. That goes through `scripts/generate_project.rb` if it writes those keys, otherwise into `WukongMind/Info.plist`.
  - The Files app then shows the folder as **On My iPhone › WukongMind**.
  - Scripts, state and records stay in Application Support, as they are today, out of the user's sight.
- **Saving big results** (roadmap §7). In `ToolRegistry.makeResult`, any output over the limit is written whole to `results/<task-id>/<step>-<tool>.txt`. The model then gets, inside the usual untrusted wrapper:
  - "Saved to results/…/07-http_request.txt (184,220 characters).";
  - a preview of the first 2,000 characters;
  - "Read more with file_read(path, offset)."

  `ToolDispatchResult` keeps `wasTruncated` and `totalCharacterCount`, and gains `savedPath`. If the workspace is unavailable (full, or the write fails), it falls back to today's truncation marker. `results/` is pruned together with the task records: a task's folder is deleted with its record, so only the newest 50 tasks keep theirs (see [Task records](#task-records)).
- **`save_to`.** `read_page`, `run_js` and `http_request` take an optional `save_to`. It writes the full result straight to a workspace file and returns only the path, the size and the preview. This direct route from tool to file costs the model no output tokens, so it doesn't need `file_write`.
- **Isolated-world helpers.** Code run by `run_js` in the isolated world (its default) gets three helpers:
  - `wukong.files.write(path, text)` and `wukong.files.append(path, text)`. They go through the existing `wukongAgent` reply handler (`AgentBridge.replyRouter`) to `AgentWorkspace`, with the same rules and caps.
  - `wukong.fetch(url)`, a GET that returns the body text through the native `AgentHTTPClient`. It sends cookies only when the URL is on the current page's site. It keeps the per-forum request pacing (`ForumRequestPacing.swift`; requirements §2) unless the Settings switch turns pacing off. While Confirm before writes is on, it stays available for the current page's own site, since a same-site GET is a read. A cross-site call then returns an error that points to `http_request`, because a script can't pause for a confirmation card.

  All three are defined inside each `run_js` call's wrapper and send a per-call token that the router checks. So saved userscripts (which share the isolated world) and the page world can't use them.

  One `run_js` with `timeout: 120` (its maximum; the default is 10 s) can fetch pages 1 to 25 of a thread and save each one, all in one step. At the default "gentle" pace of one request a second per host, 25 pages take about 25 s plus load time. The prompt tells the model to crawl with `wukong.fetch`, not the page's own `fetch`. `run_js` keeps full power, so a raw `fetch` can't be blocked. The prompt rule and the audit log (which records `wukong.fetch` URLs as it does `http_request`) are what keep crawls paced.
- **The layout is agreed in the prompt only** (roadmap §7). `BrowserAgentPrompt.system` gains a short "Workspace" section:
  - put a crawl's raw pages in `crawls/<host>/<slug>/page-001.txt`, and so on;
  - in the same script, also write the extracted posts compactly (number, author, plain body) to `thread.md` beside them, and summarise from that file, not the raw pages;
  - keep a running `notes.md` beside them;
  - per-site notes go in `sites/<host>/notes.md`;
  - read big files back with `file_read` ranges, writing a few lines of notes in the reply text alongside each read (older reads leave the history, but that text stays), then write the summary.

  The code knows only `results/`. Everything else is a convention the model follows.
- **Crawl arithmetic** (default limits).
  - Opening steps, about 4: `read_page` (1), one or two `run_js` crawls that fetch with `wukong.fetch` and save the raw pages and `thread.md` (2), then `script_save` for the reader (1).
  - Reading back, about 10: 25 pages × about 20 posts × about 400 characters is about 200,000 characters of `thread.md`, so 10 `file_read` calls of 20,000 characters each.
  - That is about 14 steps, well under 30.
  - Trimming keeps at most 3 reads (about 60,000 characters, or 15,000 tokens) in each request, instead of resending all 200,000.
- **Kill mid-task.** Every file write is atomic and finished before the tool returns, so whatever was written stays. The conversation itself stays in memory, as today. After a relaunch, the task is in the audit log and can be exported from there (see [Audit log](#audit-log)).

## Page feedback

Everything in [page-feedback.md](page-feedback.md) is in M3, including its "other milestones" table, since One panel has shipped. This section records only the design choices the spec leaves open.

- **Snapshot.** `PageStateSnapshot` (new, Codable) holds the spec's seven numbers.
  - `AgentBridge.pageSnapshot()` runs one fixed function in the isolated world.
  - The page-error counter is a small document-start script in the page world, which is where page errors and unhandled rejections fire. One extra page-world `evaluateJavaScript` reads it.
  - The code lives in `PageFeedback.swift` (new), together with `PageFeedbackRules`: the thresholds, as one set of constants, and the comparison.
- **Page-changing tools** are `run_js` and `inject_css`. Each takes a snapshot before and after running and appends "Page changes: text 12,400 → 310; height 8,200 → 900", or "Page changes: none". On a warning, the result's first line is "The page may be broken: <reasons>". `navigate` and `reload_page` change the URL or reset the page, so they skip the comparison. The warning and "Page changes" lines are added after saving or truncation, so the model always sees them and a saved file stays raw.
- **Baseline.** The session stores the snapshot taken before the run's first page change. Verify before saving compares against it. If nothing changed the page this run, verify takes a snapshot of the current page first.
- **Prompt.** `BrowserAgentPrompt.system` gains the spec's rule 4: on a warning, check with `read_page`, then fix or undo, and never report done straight away.
- **Verify before saving** (`script_save`, `script_update`).
  - The app reloads the page with the candidate script added as a temporary `WKUserScript`, for that one load only, then takes a snapshot.
  - The script is refused if any warning rule matches, or if the candidate reported a runtime error through the existing userscript error route. The refusal comes back as `Error: Not saved: <reasons>. If this change is what the user asked for, call again with confirm_change: true.`
  - `confirm_change: true` skips the snapshot rules only. **A script that throws is still refused.**
  - A script whose match rules don't cover the current page is saved unverified, and the result says so.
- **Auto-disable.** `ScriptStore.recordError` counts errors, not page loads. So `ScriptStore` gains a per-script count of consecutive loads with errors, fed once per page load from the userscript runner: an error on that load bumps it, and a clean run resets it.
  - At 3, the script is disabled and gets a saved `disabledReason`: "Turned off after errors on 3 page loads in a row: <message>".
  - This page shows the reason under the script row, in `caption` style, with a quiet Button, **Let the Agent fix it**. The button sends "Fix the script <name>" to the panel, with the script's ID and latest error attached.
- **Undo on the saved-script card.** `AgentScriptCardView` (`ScriptViews.swift:353`) gains a quiet **Undo** Button. It disables the script (it doesn't delete it) and reloads the page.
- **"This page looks broken" suggestion.** When the current page has active scripts, `PageSuggestions` (`SuggestionRow.swift:81`) adds it last in the row, and puts it first only when the current page's scripts have recorded errors. Tapping it sends that sentence, and the app attaches the current snapshot, the active scripts (names and IDs) and their latest errors as a short block in the user turn.
- **Screenshots on a warning** (task 2, once `screenshot` exists). When the model supports images, page-changing tools also keep a visible-area screenshot from before they ran. It stays in memory and is dropped unless needed. On a warning, or a failed verify, the result carries the before and after screenshots as images. History trimming treats them like any other images.
- **Developer mode:** the expanded ToolRow shows both snapshots' raw values and the rules that matched (task 7).

## Confirmations

`settings.agentConfirmBeforeWrites` already exists and is saved (`Models.swift:112`). It defaults to off. M3 makes it work, and removes the "M3" seal and the "starts working with the M3 safety update" footer from Settings › Agent.

| Case | Switch off | Switch on |
|---|---|---|
| `cookies_get` | **Always asks** | Asks |
| `http_request` with `send_cookies` to a site other than the current page's | **Always asks** | Asks |
| Any other `http_request` | Runs | Asks |
| `wukong.fetch` | Runs (cookies on the current page's site only) | Same site: runs. Cross-site: error pointing to `http_request` |
| `file_write`, form submits, everything else | Runs | Runs |

- **Cookies to another site.** `send_cookies` always sends the target site's cookies, so this case uses the person's login at the target site. A `Cookie` header the model writes itself counts as `send_cookies`. A redirect that leaves the starting site drops the `Cookie` header, for `http_request` and `wukong.fetch` alike.
- **"Site"** means the registrable domain, found with a small built-in rule: the last two labels of the host, or the last three when the second-to-last label is a common second-level label under a country code (`co.uk`, `com.au`, …). An unknown case counts as a different site, so it asks.
- **No form-submit confirmation.** The owner removed it, so `ForumBrowser.swift`'s `decidePolicyFor` is untouched.
- **How it asks.** The run pauses, and an inline card appears in the conversation under the pending ToolRow:
  - the card shell holds the question in plain `ink` text, for example "Send a POST request to api.example.org/v1/items?", "Read 14 cookies for example.org?" or "Send a request to other-site.net using your login there?";
  - beneath the text, the full URL in `code` style;
  - two Buttons: **Allow** (primary) and **Don't allow** (secondary).

  Stop also cancels the card. A refusal returns "The user declined this action." as the tool's error result, and the Agent explains in the conversation (rule 5 of the six product rules).
- **Code.** `AgentConfirmationGate` (new) is an `@Observable` queue of pending confirmations. The tool awaits it, and the transcript renders it.

## Audit log

Today's `SettingsAuditLogPage` (`SettingsAssistantPages.swift:358`) lists `browserAgent.runs` from memory. M3 saves it to disk.

- **What is recorded:** one JSON line per tool call, with:
  - time, task ID, step number, tool name and duration;
  - the arguments (the JSON, cut to 4,000 characters, with secrets redacted);
  - the result summary (500 characters at most), the error flag, whether the result was truncated or saved (with its path), and any page-feedback warning;
  - the page URL;
  - for `http_request` and `wukong.fetch`, the full target URL and the method, always (requirements §8);
  - for confirmations, the question and the answer.

  A task line opens each task: the prompt (first 500 characters), model, provider and start time. A closing line ends it: the outcome, steps, tokens and duration. Full results aren't in the audit log; they are in the task record.
- **Where:** `Application Support/WukongMind/AuditLog/<yyyy-mm-dd>.jsonl`, appended through a serial queue.
- **Retention:** 30 days or 20 MB in total, whichever is smaller. The oldest days are deleted at launch.
- **Where it shows** (design-unified "Phases" table and Settings › Agent):
  - Settings › Agent › Records › **Audit log** (a ListRow showing the step count);
  - the panel's ⋯ menu › **Audit log**;
  - an expanded ToolRow's quiet Button, **View in audit log**, which opens that task at that step.
- **The page:** a grouped `Form` with one section per day.
  - Each task is a ListRow that pushes the task's steps. It shows the prompt's first line, then "host · N steps · time", and an error Seal when a step failed.
  - A step row shows the done label, then the argument summary and result summary in `caption` style, then the time and duration. In developer mode it also shows the code name and the arguments JSON (today's behaviour).
  - At the bottom, **Clear audit log** is a destructive Button with one confirmation, because it can't be undone.
- **Workspace row:** Settings › Agent › Records › **Workspace** shows the folder's size and opens the Files app at it (`shareddocuments://` plus the folder path). If that URL can't open, the footer reads "In the Files app: On My iPhone › WukongMind".
- **Code:** `AuditLog` (new, `AuditLog.swift`). `BrowserAgentSession` feeds it from `AgentLoopEvents.onStepFinished` and the run's start and end.

## Task records

Task export needs more than the audit log has: every model request and response, and every full tool result. So each run also writes a **task record**.

- **Where:** `Application Support/WukongMind/Tasks/<task-id>.jsonl`, one line per event, appended as it happens. That makes it safe across a kill, and it grows linearly with the steps. The line types are:
  - `request`: the turn number, the history length at that turn, and a hash of the system prompt and the tool list. The full request is the system prompt, the tools and the first N history turns, run through `AgentHistoryPruner`. Each new system prompt or tool list is written once.
  - `raw_request` and `raw_response`: the provider's HTTP bodies, verbatim (see [Developer mode](#developer-mode-part-1)).
  - `response`: the parsed `AgentModelTurnResponse` (text, tool calls, stop reason, tokens), with the model and provider.
  - `tool_result`: the call ID, name, arguments, images, error flag and duration, plus the output before wrapping and the dispatch metadata.
    - The output is `ToolDispatchResult.output`: redacted, and already truncated or replaced by the saved-file notice and preview. Page changes and warnings are part of it.
    - The metadata is `wasTruncated`, `totalCharacterCount`, `savedPath` and `resultSummary`.
    - The wrapped `modelContent` isn't stored, since `UntrustedWebContent.wrap` rebuilds it exactly.
- **Cookies are scrubbed as each line is written**, not at export.
  - The store keeps the set of hosts the task touched: page loads, `navigate`, `http_request`, `wukong.fetch` and `cookies_get`.
  - It also keeps an in-memory set of every cookie (name and value) seen for those hosts. It reads `WKHTTPCookieStore` when a host is first touched and again before each line is written. It never forgets a value, so a cookie that rotates mid-task is scrubbed in both its old and new form.

  Before a line is written:
  - **Structured places are cleared, whatever the value's length.** `cookies_get` values become `"[cookie]"`. `Cookie` and `Set-Cookie` headers are dropped. Every `name=value` pair whose name is a known cookie name becomes `name=[cookie]`.
  - **Long values are replaced anywhere.** Every known value of 8 or more characters is replaced in the line's decoded strings, and in raw bodies in both its plain and JSON-escaped forms.
  - **Short values are replaced only in those structured places.** A bare string of 1 to 7 characters elsewhere ("1", "en", "dark") can't be told apart from ordinary text.

  If the cookie store can't be read when a line is written, the line is marked `"cookies_scrubbed": false`. Only the record is changed, never the live conversation.
- **Retention:** the newest 50 tasks or 200 MB. Older records are deleted at launch, and **each deleted record takes its `results/<task-id>/` folder in the workspace with it**. The audit log outlives both, so an old step keeps its summary and loses only its export.
- **Codable gaps:** `AgentModelTurnResponse` and `AgentToolDefinition` are not Codable today, while `AgentModelTurn`, `AgentModelToolCall` and `AgentModelToolResult` are. Task 6 makes both Codable. `AgentToolDefinition` encodes as name, description and `inputSchema`.
- **Code:** `TaskRecordStore` (new, `TaskRecord.swift`).

## Developer mode, part 1

**The one switch** is `settings.agentDeveloperMode`, in Settings › Agent › Developer. It defaults to off, and while it is off no developer entry shows (roadmap §8).
- `AppSettings` also has an older `developerMode` (`Models.swift:165`). It feeds `AgentStatusLine` today and is set by DEBUG launch arguments (`AppModel+Browse.swift:316`).
- Task 7 folds it into `agentDeveloperMode`: the launch arguments set the new flag, and the old key is decoded once and then dropped.
- The switch loses its "M3" seal, and its subtitle becomes "Show raw requests, tokens per step and task export".

**What it shows**

| Roadmap §8 item | Where | How (existing patterns only) |
|---|---|---|
| Full request and raw response, with the system prompt and tool definitions | An expanded ToolRow, section "Model step" | Two rows, **Request** and **Response**, each showing its size. Each opens the M2 "View code" sheet pattern (`.sheet`, `[.medium, .large]`, selectable monospaced text, Copy and Share). The request is shown pretty-printed, with the API key removed |
| Per-step tokens and model | The same section | "Turn 3 · claude-sonnet-5-5 · 1,204 in · 86 out". The rows of one model turn share the line, and the first of them shows it |
| Page-feedback snapshots | The same expanded row, for page-changing tools | Both snapshots' raw values and the rules that matched, in `code` style |
| The final reply's turn (no tool call) | Under the Agent's last message | A quiet Button, **Details**, opening the same sheet |
| Token total | Status line | Already built: "Done · 3 steps · 9 s · 6.4k tokens" |
| Tool code name and duration | The collapsed ToolRow | The code name in `code` style and the duration at the trailing edge (the design system's ToolRow README) |
| Page console and network requests | This page popover › **Developer** group | Two ListRows, **Console** (N lines) and **Network** (N requests). They push monospaced lists from the console buffer and the `network_log` ring buffer, newest first, each with Copy |
| Task export | ⋯ menu › **Export task**; Audit log › a task › **Export** | See below |

**Raw capture.** `AIService.completeToolTurn` gains an optional `AgentWireRecorder` (new protocol). It is called with the `URLRequest` and the response `Data`, and it stores:
- the URL, with the `key` query item removed (Gemini puts the key there; see `makeToolRequest`);
- the method;
- the body;
- the response status and body.

It never stores request headers, so `x-api-key`, `x-goog-api-key` and `Authorization` never reach it. The existing `redactSecrets` then runs over both bodies. Capture always runs while a task record is written, whether or not developer mode is on, so a task done with the switch off can still be exported later. Developer mode only decides what is shown.

## Task export

- **The file:** one JSON document, `wukong-task-<yyyy-mm-dd>-<slug>.json`, shared through the system share sheet (a `ShareLink` of a temporary file, as script export does in design-m2). It holds:
  - `format`: "wukongmind-task", `version`: 1;
  - the app's version and build, and the export time;
  - provider and model, and the step limit and truncation limit;
  - the page URL at the start and at each request;
  - `systems` and `tool_sets`, each stored once and referred to by hash;
  - `history` (the full `[AgentModelTurn]` transcript);
  - `turns[]`: each turn's request reference (system hash, tool set hash, history length), `raw_request`, `raw_response`, the parsed `response`, and that turn's `tool_results` (with images as base64 JPEG).
- **"Every turn's full request"** (roadmap §8) is kept by reference. The system prompt, the tools and the first N turns of `history`, run through the pruner, rebuild the exact request, and `makeToolRequest` turns that back into the provider body.
  - The raw bodies are kept as well while the file stays under 25 MB.
  - Past that, the raw request bodies of the middle turns are dropped (the first and last are kept) and listed in `omitted_raw_requests`. The responses are always kept.
  - Repeating every full body would grow with the square of the steps.
- **Prompt before export** (roadmap §8): an alert. Title "Export this task?". Message: "The file includes the pages and results the Agent read. API keys and cookies are removed." Buttons: **Export** and **Cancel**.
- **No API keys:**
  - keys are never captured (see the raw capture above);
  - the exporter also runs `redactSecrets` over the whole file with every configured key;
  - a unit test checks that no key string survives.
- **No cookies.** The task record is already scrubbed as each line is written. The exporter runs the same scrub once more with the cookie values current at export time, then checks the result.
  - **Export is refused** if any line is marked `"cookies_scrubbed": false`, or if the file still holds any current cookie value of 8 or more characters for the task's hosts, or any `name=value` pair of a current cookie.
  - A refused export shows "This task can't be exported without cookies in it." and writes no file.
- **Replay.** `RecordedModelClient` is a private class inside `AgentLoopTests` today. Task 7 moves it to `WukongMindTests/Support/RecordedModelClient.swift` (new). It also adds:
  - `TaskExport.load(_:)`, in the app target (`TaskExport.swift`), returning the recorded responses and tool results, so the app and the tests decode with the same code;
  - a seam: `AgentLoop` takes a `ToolDispatching` protocol (new: `definitions` and `dispatch(toolName:arguments:)`), which `ToolRegistry` adopts unchanged;
  - `ReplayToolDispatcher` (test support), which adopts it.
    - It returns the recorded definitions.
    - For each call, it returns the recorded dispatch result, in recorded order per tool, and fails if the name or arguments differ.
    - It rebuilds `modelContent` with `UntrustedWebContent.wrap` and doesn't run `makeResult`, so truncation, saved paths, sizes and previews come back exactly as recorded.

  A replay test feeds the file to `AgentLoop` and asserts three things:
  - the history the loop builds equals the recorded `history`, turn by turn;
  - the tool-call sequence, the final text and the step count match;
  - the file holds no configured key and no scrubbed cookie value.

  Fixtures go in `WukongMindTests/Fixtures/TaskExports/`. To turn a failed task into a regression test, drop its file there and add a test that asserts the tool sequence you expected instead.

## UI touch points (One panel style)

Everything below sits in the One panel conversation view: `AssistantPanel` (`SummaryPanel.swift:27`), with tool rows in `AgentPanel.swift`. It is described in words, using existing components.

- **ToolRow for the new tools.** The same row, with the label from the table in [Decisions](#decisions) and a result summary:
  - "Took screenshot · full page", "Read network log · 38 requests", "Opened page · example.org/t/123", "Reloaded page";
  - "Sent request · 200 · 48 KB", "Read cookies · 14";
  - "Read file · 20,000 of 184,220", "Wrote file · crawls/…/page-007.txt", "Listed files · 26".

  A page-feedback warning adds the error tint and "Page may be broken" to the summary. A result saved to the workspace adds a quiet **Open in Files** Button to the expanded row, under the result. A screenshot's expanded row shows the image as a thumbnail, which opens full size in a sheet.
- **Saved-script card:** the **Undo** Button (see [Page feedback](#page-feedback)).
- **Suggestion row:** "This page looks broken", when the page has active scripts.
- **This page:**
  - the reason a script was turned off, and **Let the Agent fix it**;
  - in developer mode, the Console and Network rows.
- **Confirmation card:** see [Confirmations](#confirmations).
- **⋯ menu:** **Audit log** (always) and **Export task** (developer mode only, enabled once the conversation has a finished task), as design-unified draws it.
- **Settings › Agent:** the Safety, Records and Developer sections already exist. M3 adds the Workspace row, makes the Audit log row open the on-disk log, and removes the "M3" seals and placeholder footers.
- **Accessibility:** new rows follow the ToolRow labels ("Sent request, 200, collapsed"). The confirmation card is announced when it appears (`AccessibilityNotification.Announcement`), and its buttons are at least 44 pt. **New identifiers:**
  - `agentConfirmCard`, `agentConfirmAllow`, `agentConfirmDeny`;
  - `agentToolOpenInFiles`, `agentToolScreenshot`, `agentScriptUndo`;
  - `agentDevRequest`, `agentDevResponse`, `agentDevTurnLine`, `agentDevDetails`, `agentDevSnapshots`;
  - `exportTaskMenuItem`, `suggestionPageBroken`;
  - `auditTaskRow-<id>`, `auditStepRow-<n>`, `auditClear`, `settingsRow-workspace`;
  - `thisPageConsole`, `thisPageNetwork`, `thisPageDisabledReason-<id>`, `thisPageLetAgentFix-<id>`.

## Acceptance checks

These come from next-phase §7 (marked "added"), requirements §9 M3 (which still holds), page-feedback.md and the owner's review.

1. **Thread crawl.** On a non-Discourse forum thread of 20 or more pages, say "read the whole thread and summarize it". The raw pages land in the workspace (visible in Files), and the summary covers every page.
   - Check: every page file exists, and the summary cites something from each page range.
   - Expected path: `read_page`, then one or two `run_js` calls that fetch pages with the paced `wukong.fetch` and save them with `wukong.files`, then `file_read` ranges and the summary, well under 30 steps.
   - The local check uses a 25-page fixture forum served by the existing UI-test fixture server (`WukongMindUITests/FixtureSpaForumServer.swift`). The live check uses a real forum on the device.
2. **Files survive a kill.** Kill the app mid-crawl and reopen it. The files written before the kill are there and whole, and the task shows in the audit log.
3. **Export replays.** Export that task (or a shorter recorded one) and add it as a fixture. A unit test replays it through `RecordedModelClient` and passes. The file holds no API key or cookie value.
4. **Saved reader** (requirements §9 M3): the Agent saves the thread-reading logic as a script for that site and reuses it on the next thread.
5. **Each new tool:**
   - `screenshot`: with a model that supports images, the Agent describes the test page correctly from the screenshot. With a text-only model, the tool isn't offered.
   - `network_log`: it lists the test page's `fetch` and XHR requests.
   - `navigate`: it opens a fixture page and refuses `javascript:` and `file:` URLs.
   - `http_request` and `cookies_get`: the confirmation card appears (for `cookies_get` and a cross-site `send_cookies` even with the switch off), and after **Don't allow** the Agent explains in the conversation.
6. **Page feedback** (the acceptance list in [page-feedback.md](page-feedback.md)):
   - emptying the body gives a warning, and the Agent doesn't report done;
   - saving a script that throws is refused;
   - a script broken by hand is turned off after the third load, and This page says why;
   - "keep only the article" completes and saves;
   - replay tests cover the warning path and the refused save;
   - an action that changes nothing adds at most one line.

   Also: **Undo** on a saved-script card turns the script off and reloads, and "This page looks broken" appears on a page with an active script.
7. **No regressions:** all unit tests pass. With Confirm before writes on, every `http_request` asks before it runs.

## Task split

Seven implementation tasks and one acceptance task. Sizes count changed lines, tests included. Each brief below can be pasted as is; its **Read** line names the sections of this page it implements.

**Rules for every task:**
- Adding a file means regenerating `WukongMind.xcodeproj` with `ruby scripts/generate_project.rb` (CI's drift check). On a rebase, regenerate it; never hand-merge `project.pbxproj`.
- New strings go into `Localizable.xcstrings`. On a conflict, take main's file and re-add your keys.
- Each tool family has its own file, created by task 1. Shared files take only small edits in named places.
- Done means the unit tests pass: `xcodebuild test … -only-testing:WukongMindTests`, as in [docs/DEVELOPMENT.md](../DEVELOPMENT.md).
- Each task adds unit tests that need no simulator where it can. WebKit tests use local fixture HTML only, and model calls are recorded (requirements §9).

**Waves.** Tasks in a wave can run at the same time.
- **Wave A: tasks 1, 3 and 6.**
  - Page feedback starts here with task 3. Task 4 is in wave B because it needs task 3's snapshot and reload.
  - **Task 1 merges first**; tasks 3 and 6 rebase on it before they merge.
  - Shared edits sit in separate places:
    - `ToolRegistry.swift`: task 1 changes `makeResult` and adds `save_to`; task 3 adds the snapshot wrapping in the `run_js` and `inject_css` handlers. Both touch the `run_js` handler, a rebase point.
    - `AgentBridge.swift`: task 1 adds the `wukong.files` route; task 3 adds `pageSnapshot`, `load` and `reload`. Another rebase point.
    - `BrowserAgent.swift`: task 1 adds the prompt's Workspace section and the pruner; task 3 the page-feedback prompt rule and the baseline; task 6 Codable and the session's store feeds.
    - The `browserAgent` initializer in `AppModel.swift`: task 1 changes `registryBuilder`; task 6 adds the stores.
- **Wave B: tasks 2, 4 and 5.** Task 2 fills `ToolRegistry+Capture.swift` and edits `AgentBridge.swift`, `AIService.swift` and `PageFeedback.swift` (the screenshots on a warning). Task 4 edits the script tools in `ToolRegistry.swift`, `ScriptStore.swift`, `ScriptViews.swift` and `SuggestionRow.swift`. Task 5 fills `ToolRegistry+Network.swift` and edits `SummaryPanel.swift` (the card), which task 4 also edits (sending the suggestion). The images on a failed verify are wired by whichever of tasks 2 and 4 merges second.
- **Wave C: task 7.**
- **Then task 8.**

### 1. M3 1: Workspace, file tools, saving big results and history trimming
- **Read:** design-m3.md: Decisions, `file_read`/`file_write`/`file_list`, Workspace, and "History trimming" under `screenshot`.
- **Scope:**
  - `AgentWorkspace.swift` (new).
  - `ToolRegistry+Workspace.swift` (new, filled), and `ToolRegistry+Capture.swift`, `ToolRegistry+Navigation.swift` and `ToolRegistry+Network.swift` (new, empty lists).
  - `ToolRegistry.swift`: `AgentToolContext`, the `m3` factory, saving in `makeResult`, `savedPath`, and `save_to` on `read_page` and `run_js`.
  - `BrowserAgent.swift`: the prompt's Workspace section, and `AgentHistoryPruner` with the `file_read` rule (keep the newest 3).
  - `AgentBridge.swift`: only the `wukong.files` route and the per-call token.
  - `ConversationViews.swift`: both tenses in `DCToolLabel` for every new tool.
  - `AppModel.swift`: `registryBuilder` to `.m3`.
  - The Files keys in `Info.plist` or `scripts/generate_project.rb`. No other code uses `.documentDirectory` today, so the whole folder is free.
  - Tests: `AgentWorkspaceTests.swift` (new), `ToolRegistryTests.swift`.
- **Size:** about 600. **Depends on:** nothing.
- **Done when:**
  - `file_read` (ranges), `file_write` (overwrite and append) and `file_list` work under the path rules and caps;
  - `..`, absolute paths and symlink escapes are refused (tests);
  - an `append` interrupted before its atomic replace leaves the old file whole (test);
  - an over-limit result is saved under `results/<task-id>/`, and the model gets the path, a preview and the size (test);
  - `save_to` works on `read_page` and `run_js` through one helper that task 5 reuses for `http_request`;
  - `wukong.files.write` from isolated-world `run_js` writes a file, while a userscript and the page world can't (an `AgentBridgeTests` fixture);
  - with 5 `file_read` results in history, the request carries the newest 3 whole and the 2 older as the one-line notice, while the stored history keeps all 5 (test);
  - every new tool has a running and a done label;
  - the workspace shows in the Files app on the simulator (screenshot).

### 2. M3 2: Screenshot, network log, page console and screenshots on a warning
- **Read:** design-m3.md: `screenshot`, `network_log`; Page feedback, "Screenshots on a warning".
- **Scope:**
  - `AgentPageCapture.swift` (new): the page-world hook script and its buffers.
  - `AgentBridge.swift`: `screenshot`, `networkLog` and `consoleLog`, and installing the hook in `init(webView:)`.
  - `ToolRegistry+Capture.swift`.
  - `BrowserAgent.swift`: `AgentImage`, `AgentModelToolResult.images`, and the image rule in `AgentHistoryPruner`.
  - `AIService.swift`: images per provider family.
  - `PageFeedback.swift`: the before screenshot and the images on a warning or a failed verify.
  - Tests: `AgentPageCaptureTests.swift` (new), and `AgentLoopTests.swift` for the wire format per family through `RecordedToolURLProtocol`.
- **Size:** about 600. If it runs over, split the warning screenshots into a small follow-up and tell the Assistant. **Depends on:** 1, and 3, the page-feedback task (`PageFeedback.swift`), which only the warning screenshots need. If task 4 has merged first, this task also wires the images on a failed verify.
- **Done when:**
  - on a fixture page that calls `fetch` and XHR, `network_log` returns both requests, with filtering and the limit working, and no cookie or auth headers;
  - `screenshot` returns a JPEG of at most 1,280 px, and `full_page` caps at 8 screens;
  - the wire-format tests show the image block for Anthropic, Gemini, OpenAI-compatible and Ollama;
  - the tool is hidden when `supportsImageInput` is false;
  - only the images of the 2 newest image-bearing results stay in the request;
  - a warning on a fixture page carries before and after images for an image model, and none for a text-only one (test);
  - if task 4 merged first: a failed verify carries both images too (test).

### 3. M3 3: Page feedback 1: snapshots, warnings, `reload_page` and `navigate`
- **Read:** design-m3.md: `navigate` and `reload_page`, Page feedback (Snapshot, Page-changing tools, Baseline, Prompt); [page-feedback.md](page-feedback.md) "How" 1 to 5.
- **Scope:**
  - `PageFeedback.swift` (new): `PageStateSnapshot`, the snapshot function, the page-world error counter script, `PageFeedbackRules` and the result text.
  - `AgentBridge.swift`: `pageSnapshot`, and `load` and `reload` on `AgentPageDriving`.
  - `ForumBrowser.swift`: the awaitable load and reload (a navigation continuation).
  - `ToolRegistry.swift`: snapshots around the `run_js` and `inject_css` handlers.
  - `ToolRegistry+Navigation.swift`.
  - `BrowserAgent.swift`: the prompt rule, and the run's baseline snapshot in the session.
  - Tests: `PageFeedbackTests.swift` (new, fixture HTML), `BrowserToolsTests.swift` (new).
- **Size:** about 600. If it runs over, stop and ask the Assistant before going on. **Depends on:** nothing (merges after 1).
- **Done when:**
  - on fixture pages, emptying the body, halving the height, making the page unscrollable, removing the links and throwing a page error each give the warning line, and a change that alters nothing gives one line (tests);
  - the thresholds live in one place;
  - `reload_page` drops an unsaved `inject_css` and injects saved scripts again (test);
  - `navigate` returns the final URL, title and status, refuses `javascript:` and `file:`, and times out cleanly (tests);
  - a recorded-model test shows the Agent calling `read_page` after a warning instead of answering done.

### 4. M3 4: Page feedback 2: verify before saving, auto-disable, Undo and the broken-page suggestion
- **Read:** design-m3.md: Page feedback (Verify before saving, Auto-disable, Undo, the suggestion); [page-feedback.md](page-feedback.md) "How" 6 and 7, and its "other milestones" table.
- **Scope:**
  - `ToolRegistry.swift`: verify in `script_save` and `script_update`, and `confirm_change` in their schemas.
  - `ScriptStore.swift`: the consecutive error-load count and the saved `disabledReason`, fed from the existing userscript error route.
  - `ScriptViews.swift`: **Undo** on `AgentScriptCardView`; the reason and **Let the Agent fix it** in `PageCapabilitiesView`.
  - `SuggestionRow.swift`: the "This page looks broken" entry.
  - `SummaryPanel.swift`: sending that suggestion and the fix request with their attached context.
  - Tests: `ScriptStoreTests.swift`, `PageFeedbackTests.swift`, and a recorded replay of the refused save.
- **Size:** about 550. **Depends on:** 3. If task 2 has merged first, this task also wires the before and after images on a failed verify.
- **Done when:**
  - saving a script that throws is refused with the reason, even with `confirm_change` (test);
  - a script that empties the page is refused, then saved with `confirm_change: true` (test);
  - three erroring loads in a row disable a script, a clean load resets the count, and This page shows the reason (tests);
  - **Undo** disables the just-saved script and reloads the page;
  - the suggestion shows only with an active script, sits last in the row (first only when the page's scripts have recorded errors), and attaches the snapshot, the scripts and their errors;
  - if task 2 merged first: a failed verify carries both images (test).

### 5. M3 5: `http_request`, `cookies_get` and confirmations
- **Read:** design-m3.md: `http_request`, `cookies_get`, Confirmations; Workspace, "Isolated-world helpers" (`wukong.fetch`).
- **Scope:**
  - `AgentNetworkTools.swift` (new): `AgentHTTPClient`, cookie headers, pacing and the site rule.
  - `AgentBridge.swift`: only the `wukong.fetch` route, beside task 1's `wukong.files`.
  - `ToolRegistry+Network.swift`.
  - `AgentConfirmationGate.swift` (new).
  - `SummaryPanel.swift`: rendering the confirmation card.
  - `SettingsAssistantPages.swift`: removing the Safety seal and footer.
  - Tests: `AgentNetworkToolsTests.swift` (new, with a `URLProtocol` stub).
- **Size:** about 550. **Depends on:** 1 (`save_to` and saving).
- **Done when:**
  - methods, headers, body, timeout, redirects, the 20 MB cap and binary bodies work;
  - `send_cookies` attaches the target site's cookies (httpOnly included), never the current page's, and `Set-Cookie` is neither returned nor stored;
  - `cookies_get` matches parent domains;
  - with the switch off, `cookies_get` and a cross-site `send_cookies` (or a model-written `Cookie` header) still wait for Allow, a redirect off the site drops the cookies, and other requests run; with it on, every `http_request` waits; **Don't allow** returns the declined error (tests);
  - the site rule treats `a.example.org` and `b.example.org` as one site, and `example.co.uk` and `other.co.uk` as two (tests);
  - `wukong.fetch` waits for the per-forum pace between requests to one forum host, skips it when pacing is off, sends cookies only on the current page's site, and with the switch on runs for the current page's site but returns the `http_request` error for another site (tests with a fake clock).

### 6. M3 6: Audit log on disk and task records
- **Read:** design-m3.md: Audit log, Task records.
- **Scope:**
  - `AuditLog.swift` (new).
  - `TaskRecord.swift` (new): the records, the cookie scrub, and retention, including the `results/<task-id>/` folders.
  - `BrowserAgent.swift`: Codable for `AgentModelTurnResponse` and `AgentToolDefinition`, a task ID per run, and feeding both stores from the session.
  - `SettingsAssistantPages.swift`: the audit log page on disk, its task and step pages, Clear, and the Workspace row.
  - `SummaryPanel.swift`: ⋯ › Audit log, and View in audit log.
  - Tests: `AuditLogTests.swift` (new).
- **Size:** about 570. **Depends on:** nothing (merges after 1, whose `savedPath` and `results/` it uses).
- **Done when:**
  - every tool call writes one line with the fields the Audit log section lists, and `http_request` lines hold the full URL;
  - the retention rules hold, and pruning a task record deletes its `results/` folder (tests with a fake clock);
  - the log and task records survive reopening the store (test);
  - a record line holds no seeded cookie value, including one that rotated mid-task and a short value inside `document.cookie` output (tests);
  - the page groups by day and then by task;
  - a record file reads back into the same turns.

### 7. M3 7: Developer mode part 1 and task export
- **Read:** design-m3.md: Developer mode part 1, Task export, UI touch points.
- **Scope:**
  - `AIService.swift`: `AgentWireRecorder`.
  - `TaskExport.swift` (new): build, redact, check and load.
  - `BrowserAgent.swift`: the `ToolDispatching` seam, and per-turn model and tokens on the rows.
  - `AgentPanel.swift`: the ToolRow's developer mode (code name, duration, the Model step section, snapshots, Details).
  - `SummaryPanel.swift`: ⋯ › Export task and the alert.
  - `ScriptViews.swift`: the Console and Network rows in `PageCapabilitiesView`.
  - `Models.swift`: folding `developerMode` in.
  - `SettingsAssistantPages.swift`: the switch's text.
  - Tests: `WukongMindTests/Support/RecordedModelClient.swift` (moved from `AgentLoopTests`), `ReplayToolDispatcher`, `TaskExportTests.swift` (new), and one recorded task in `Fixtures/TaskExports/`.
- **Size:** about 600. **Depends on:** 6 (records), 2 (the console and network buffers) and 3 (snapshots).
- **Done when:**
  - with the switch off, no developer entry shows (a UI test);
  - with it on, a step shows the raw request and response, the turn's model and tokens, and, for page-changing tools, the snapshots;
  - the export alert appears, and the share sheet gets one JSON file;
  - the file holds no API key, including Gemini's URL key (test), and no seeded cookie value (test);
  - a record with an unscrubbed line is refused (test);
  - the fixture replays through `RecordedModelClient`: the rebuilt history equals the recorded one, and the tool sequence and final text match.

### 8. M3 acceptance and 1.2.0
- **Read:** design-m3.md: Acceptance checks; [README](README.md) "Versions and releases".
- **Scope:**
  - Run the seven acceptance checks on a simulator and on the owner's iPhone, with a proof artifact.
  - Write `docs/wukongmind/m3-acceptance.md`, check in the 25-page fixture forum, and add the exported crawl task as a replay fixture.
  - Bump `marketing_version` to `1.2.0` in `scripts/generate_project.rb`, regenerate the project, and update the README version table.
  - Fix only small defects; anything bigger goes back to the owner.
- **Size:** about 300, mostly fixtures and docs. **Depends on:** 1 to 7.
- **Done when:** all seven checks pass with proof, the unit tests are green, and the owner has been asked on an approval card before `v1.2.0` is tagged.

## Not in M3

- **Multiple tabs** become a separate, later milestone (owner, 2026-11-13). Moved out: the tab model (`BrowserTabs`), the tab button and tab overview, the `tabs` tool, and the question of one conversation per tab. The previous version of this page (commit `a3cbd56`, "`tabs`" and tasks 3 and 4) holds that design for when the milestone is scheduled. It isn't in next-phase §7's list yet.
- **Agent conversations in History** wait for One loop, which redoes the transcript anyway.
- **Trimming other tool results.** Only `file_read` results and screenshots are trimmed in M3.
- **Storing `Set-Cookie` in the browser.** Never done, so the Agent can't change the browser's logins.

## Conflicts called out

- **Multiple tabs.** next-phase §7 and design-unified ("one per tab from M3", the tab button) put tabs in M3. The owner moved them to a later milestone; see [Not in M3](#not-in-m3).
- **Confirmations.** Requirements §8 names form submits by the Agent among the actions to confirm. The owner removed that case. The owner also added two cases that always ask, which requirements §8 doesn't have.
- **Page feedback's table** puts the saved-card Undo and "This page looks broken" in One panel. Its own note says to fold them into M3 if One panel has shipped, which it has.
- **`confirm_change`.** page-feedback.md doesn't say whether it also overrides "the script ran without errors". Here it doesn't, so a throwing script is never saved; that matches the spec's acceptance check.
- **Truncation versus saving to a file.** Requirements §4 says output over the limit "is truncated and marked". The roadmap (§7, which wins) saves it to a file and gives the path, a preview and the size. This design follows the roadmap and keeps the old marker only as a fallback.
- **`file_list` and range reads** are in the roadmap, not in requirements §4. Added, since the roadmap wins.
- **"Layout in the prompt only" against paths the code must choose.** Automatic saving needs a folder the code picks, `results/`. design-unified (History, "Conversations") also says conversations join History "with M3's workspace (`tasks/`)". This design keeps `results/` as the only folder the code knows, keeps task records in Application Support, and leaves History out of M3 (owner decision).
- **Duration and code name.** Roadmap §8 says each tool call's arguments, result and duration need no developer mode. The design system's ToolRow shows the duration and code name only in developer mode. This design does both: the collapsed row hides them, and the expanded row always shows arguments, result and duration.
- **Requirements' M3 acceptance** (save the thread reader as a script and reuse it) isn't in the brief's list. The roadmap only adds checks, so it stays as check 4.
- **"Every turn's full request"** (roadmap §8) is stored by reference: the system prompt, the tools and a history length rebuild it exactly. Raw request bodies of middle turns are dropped past 25 MB. The content is the same; the file is not literally one full body per turn.
- **The brief's code pointers** (`AgentToolName`, `executeAgentTool`) are the old Research loop. M3 builds on `ToolRegistry`, as stated in [Decisions](#decisions).

## Open questions

None. The owner answered the earlier seven on 2026-11-13, and the answers are in [Decisions](#decisions), [Not in M3](#not-in-m3) and the opening section. The page-feedback thresholds are a starting point, to be tuned after the trial.
