# Learn on ask spike: page tools and site learning (task 1)

This page answers the nine spike questions in [design-learn-on-ask.md](design-learn-on-ask.md#the-spike-comes-first) with real `WKWebView` and live model runs. The throwaway harness is in [`learn-spike/`](learn-spike/), and the checked-in raw JSON outputs are in [`learn-spike/results/`](learn-spike/results/) (with iPad parity runs in [`learn-spike/results/ipad/`](learn-spike/results/ipad/)). No app code changed.

- **Simulators and toolchain:** Xcode 27.2 on macOS 27.2.1 (Mac mini runner via `learn-spike/run.sh`), iOS Simulator 27.2 on **iPhone 18 Pro** (all Q1–Q9) and **iPad Air 11-inch (M4)** (Q1–Q6 parity), run on 2026-11-15.
- **Models and endpoints (Q9):**
  - Anthropic: **`claude-haiku-5-5`** (`api.anthropic.com/v1/messages`, `ANTHROPIC_API_KEY`).
  - Vertex AI: **`gemini-3.8-flash`** (`aiplatform.googleapis.com/v1/publishers/google/models/gemini-3.8-flash`, `VERTEX_API_KEY` express mode; AI Studio `GEMINI_LIVE_KEY` fallback was configured for HTTP 429/5xx after 3 retries and **did not fire** — all 6 runs completed on `vertexai`).
- **App code compiled:** `SpikeHost` compiles `WukongMind/` (`AppModel`, `BrowserAgent`, `ToolRegistry`, `ScriptStore`, `ScriptWebController`, `AgentBridge`, `AIService`, `ForumShapes`) unchanged, adding only `PageToolShim`, `SpikeVerifier`, and the local `Network.framework` fixture server inside `SpikeTests`.
- **Rerun:**

  ```sh
  # Deterministic WKWebView checks (Q1–Q8, ~35 s):
  docs/wukongmind/learn-spike/run.sh testQ1_shimFirstUnderM0Matrix testQ2_pullAndCall \
    testQ3_hostilePage testQ4_attributionAndRouteChange testQ5_isolatedWorldFetch \
    testQ6_shimLoadCost testQ7_olderNameAndRealSites testQ8_publicForumReadersContract

  # iPad parity (Q1–Q6):
  SIM=ipad OUT=docs/wukongmind/learn-spike/results/ipad docs/wukongmind/learn-spike/run.sh \
    testQ1_shimFirstUnderM0Matrix testQ2_pullAndCall testQ3_hostilePage \
    testQ4_attributionAndRouteChange testQ5_isolatedWorldFetch testQ6_shimLoadCost

  # Live model learning and prefix token counts (Q9):
  herdr-secret run ANTHROPIC_API_KEY,VERTEX_API_KEY,GEMINI_LIVE_KEY -- \
    docs/wukongmind/learn-spike/run.sh testQ9_liveModelLearning
  ```

## Answers

| # | Question | Measured answer | Design impact |
|---|---|---|---|
| 1 | Shim first | `document.modelContext` (`=== navigator.modelContext`) is present before parse-time scripts under **7/7** CSP variants on iPhone and iPad; parse-time and `load` registrations are kept, `AbortSignal` removes tools, and `registerTool`/`getTools` return `Promise`s. | Confirmed; return `Promise`s per WebIDL |
| 2 | Pull and call | Sync (`1.0 ms`), async Promise (`31.4 ms`), timeout (`351.0 ms` on `350 ms` limit, firing `{ signal }` abort), and `1 MB` return (`0.9 ms`) all work; `>2 MB` (`2.2 MB`) refuses in `0.8 ms` (`response_too_large`). | Confirmed |
| 3 | Hostile page | Non-configurable `Document.prototype`/`Navigator.prototype` getters + captured intrinsics block replacement, hide `wukongAgent` and the isolated binder, reject dot/space names, cap at 30 tools (`10` dropped), cut descriptions at `500` chars and `>4,000`-char schemas to `"no schema"`, and time out cleanly even when `Promise.resolve` and `setTimeout` are poisoned. | Confirmed; lock getters + capture intrinsics |
| 4 | Attribution & SPA | Wrapper-bound `modelContext` attributes tools per script ID (`unowned` `document.modelContext` tools fail slot Step 1); across 3 SPA routes (`initial`, `pushState`, `replaceState`), re-running replaces in place (`1` tool, latest route). | Confirmed |
| 5 | Isolated `fetch` | Same-site `fetch` succeeds and carries `HttpOnly; SameSite=Lax` cookies under **7/7** CSP policies including `connect-src 'none'`. Cross-site `fetch` sends no same-site cookie and WebKit enforces CORS before exposing responses (simple requests still reach the remote server first). | Confirmed |
| 6 | Load cost | Shim sources are `4,364 B` (`.page`) and `4,488 B` (`WukongAgent`), `<1 ms` JS init, `+0.80 ms` median navigation delta on iPhone (`6.79` -> `7.59 ms`) and `-0.20 ms` on iPad (`11.71` -> `11.51 ms`, within noise). | Confirmed |
| 7 | Older name & real sites | `navigator.modelContext` works identically (`{"found":true,"code":"A9"}`); native WebKit `document.modelContext` is `false` today. 3 live early-adopter sites (`sitepassport.org`, `parity-webmcp.vercel.app`, `webmcp.com`) ship 2, 5, and 9 WebMCP tools today and registered cleanly into our shim. | Confirmed |
| 8 | Contract on 2 forums | Hand-written `read_topic` scripts for **FluxBB** (`bbs.archlinux.org`) and **Flarum** (`discuss.flarum.org`) passed the 8 `read_topic` steps (`thread_match` not checked) across 2 threads + page 2 (`206–1,157 ms`, `15–25 KB`). | Proposes FluxBB + Flarum for open question 1 |
| 9 | Live learning & prefix | Prefix delta: **`+1,265` Anthropic / `+757` Vertex tokens** (3 tools + Rule 4/5/`forumRules`/`script_save` text + `"Learning a site"`), **`+1,601` / `+877` all-in** with `provides` schemas. `claude-haiku-5-5` passed **6/6** verified runs in **`5–8` calls** (`<=15` confirmed). Vertex `gemini-3.8-flash` passed **5/6** verified runs in **`12–20` calls** (`3/3` on HTML `bbs.archlinux.org`; `#2` fixture stopped at `8` calls without saving). | Revise prefix targets (`<1,350` / `<1,700` all-in) & Gemini call target (`<=20`) |

## 1. Shim first across the CSP matrix

[`q1-shim-first.json`](learn-spike/results/q1-shim-first.json) (and [`ipad/q1-shim-first.json`](learn-spike/results/ipad/q1-shim-first.json)) served `/tools-page` from a local `Network.framework` HTTP server with real `Content-Security-Policy` headers across seven policies: `no-csp`, `self-only`, `nonce`, `hash`, `strict-dynamic`, `style-src-none` (`connect-src 'none'`), and `trusted-types` (`require-trusted-types-for 'script'`).

- Under **all 7 policies** on both simulators, `window.__pageSawShimAtParse` was `true`, `registerTool` returned a `Promise`, `transient_tool` aborted via `AbortController` was absent, and both parse-time (`echo_order`, `hang_forever`, `large_catalog`) and `window.load` (`delayed_quote`) registrations were collected.
- **For task 2:** `registerTool` and `getTools` must return `Promise`s (the 13 Nov 2026 WebIDL specifies `Promise<undefined>` / `Promise<sequence<ModelContextTool>>`, and `sitepassport.org` calls `registerTool(...).catch(...)` in production).

## 2. Pull and call

[`q2-pull-and-call.json`](learn-spike/results/q2-pull-and-call.json) pulled `.page` metadata and invoked `execute` via `callAsyncJavaScript`:

| Case | Outcome | Duration (iPhone / iPad) | Payload |
|---|---|---|---|
| Synchronous `execute` (`echo_order`) | `ok: true`, `{"total":45,"note":"rush"}` | `0.98 ms` / `1.09 ms` | `26 B` |
| Async Promise `execute` (`delayed_quote`, 30 ms timer) | `ok: true`, `{"item":"gear","price":42}` | `31.40 ms` / `31.69 ms` | `26 B` |
| Hanging Promise (`hang_forever`, `350 ms` timeout) | `ok: false`, `code: "timeout"`, `abortSignalFiredOnTimeout: true` | `350.96 ms` / `352.66 ms` | `0 B` |
| `1 MB` JSON return (`large_catalog`) | `ok: true` | `0.89 ms` / `0.66 ms` | `1,048,587 B` |
| `>2 MB` JSON return (`2.2 MB`) | `ok: false`, `code: "response_too_large"` | `0.81 ms` / `0.67 ms` | `2,200,011 B` refused in JS |

Checking UTF-8/string length inside the shim before returning avoids copying multi-megabyte strings across IPC.

## 3. Hostile page isolation

[`q3-hostile-page.json`](learn-spike/results/q3-hostile-page.json) loaded `/hostile`, where an inline script tried to overwrite and `delete` `document.modelContext`, probed `window.webkit.messageHandlers.wukongAgent` and the isolated binder, registered forged names (`read_topic`, `script.evil.tool`, `site.evil`, `bad space!`), registered a `1,200`-char description + `5,000`-char schema + `35` spam tools, and then poisoned `Promise.resolve = () => new Promise(() => {})` and `window.setTimeout = () => 0`.

- `pageReplacedDocShim: false`, `pageSawWukongHandler: false`, `pageSawIsolatedBinder: false`.
- Dot/space names were dropped; `.page`'s `read_topic` became `site.read_topic` (never filling a slot); `30` tools were kept and `10` dropped; description was cut at `500` chars and the `>4,000`-char schema became `"no schema"`.
- Even after `.page` poisoned `Promise.resolve` and `window.setTimeout`, pulling `.page` succeeded (`timedOut: false`), calling `never_answers` still timed out cleanly at `300 ms` (`hangingPageTimedOutCleanly: true`), and `WukongAgent`'s `script-good:read_topic` remained untouched (`{"clean":true}`).
- **For task 2:** define `modelContext` on `Document.prototype` and `Navigator.prototype` with `configurable: false` getters, and capture `Promise`, `setTimeout`, `clearTimeout`, `AbortController`, `JSON.stringify`, and `JSON.parse` inside the `.atDocumentStart` closure.

## 4. Attribution and SPA route changes

[`q4-attribution.json`](learn-spike/results/q4-attribution.json) ran a real `ScriptStore` + `ScriptWebController` userscript on `/thread-101`, bound `ctx` to `"spa-reader-id"`, registered an unowned tool on `document.modelContext` in `WukongAgent`, and triggered `history.pushState` (`/thread-102`) and `history.replaceState` (`/thread-101?v=2`):

- Registry owners were `["nil:unowned_tool", "other-script:helper", "spa-reader-id:read_topic"]`; the unowned tool failed `SpikeVerifier` Step 1 (`unownedCannotPassSlotCheck: true`).
- `ScriptStore`'s SPA hook ran the script `3` times and replaced `(owner, name)` in place (`toolsCountAfterThreeRoutes: 1`, returning `{"route":"/thread-101?v=2","runs":3}`).

## 5. `fetch` from the isolated world

[`q5-isolated-fetch.json`](learn-spike/results/q5-isolated-fetch.json) set `Set-Cookie: sid=session-secret-77; Path=/; HttpOnly; SameSite=Lax` on server A (`127.0.0.1`) across all **7 CSP variants** (including `connect-src 'none'`) and ran `fetch` from `AgentBridge.isolatedWorld` to server A (`/api/whoami`) and cross-site server B (`localhost:<portB>`):

- **Same-site (`7/7`):** `sameSiteOK: true`, `sameSiteCarriedCookie: true` (`sid=session-secret-77` arrived even under `connect-src 'none'`).
- **Cross-site (`7/7`):** `crossSiteNoCorsBlocked: true` without `Access-Control-Allow-Origin`, `crossSiteWithCorsOK: true` when CORS allowed it, and `crossSiteLeakedCookie: false` (`127.0.0.1`'s cookie was never sent to `localhost`). WebKit still sends a simple cross-site GET over the wire before CORS blocks reading the body, matching the design's privacy note (`design-learn-on-ask.md` "What can't be enforced").

## 6. Page-load cost

[`q6-load-cost.json`](learn-spike/results/q6-load-cost.json) and [`ipad/q6-load-cost.json`](learn-spike/results/ipad/q6-load-cost.json) interleaved 20 navigations to `/thread-101` (with inline login form and 15 posts) after 2 warmups, comparing a plain `WKWebView` against one injecting the shim in both worlds (`4,364 B` `.page` + `4,488 B` `WukongAgent`):

| Simulator | Baseline median (range) | With shim median (range) | Median delta | Self-timed JS init |
|---|---|---|---|---|
| iPhone 18 Pro | `6.79 ms` (`5.70–16.70`) | `7.59 ms` (`6.02–13.69`) | **`+0.80 ms`** | `0 µs` (`<1 ms` timer quantum) |
| iPad Air 11-inch (M4) | `11.71 ms` (`7.83–20.95`) | `11.51 ms` (`7.43–23.12`) | **`-0.20 ms`** | `0 µs` (`<1 ms` timer quantum) |

## 7. `navigator.modelContext` and public sites today

[`q7-real-sites.json`](learn-spike/results/q7-real-sites.json) verified `navigator.modelContext === document.modelContext` (`{"found":true,"code":"A9"}`), confirmed unshimmed WebKit has `typeof document.modelContext === "undefined"` (`nativeWebKitModelContext: false`), and probed 7 live HTTPS sites:

- Mainstream sites (`news.ycombinator.com`, `bbs.archlinux.org`, `discuss.flarum.org`, `webkit.org`): `0` tools today.
- **3 live early-adopter sites registered real WebMCP tools into our shim:**
  - `https://sitepassport.org/` (`2` tools): `site.scan_website_agent_readiness`, `site.list_verified_agent_ready_sites`.
  - `https://parity-webmcp.vercel.app/` (`5` tools): `site.get_booking_state`, `site.list_accommodations`, `site.find_providers`, `site.select_provider`, `site.explain_capability`.
  - `https://webmcp.com/` (`9` tools): `site.search_directory`, `site.get_site_tools`, `site.open_site_page`, etc. `webmcp.com` ships `@mcp-b/webmcp-polyfill`, which detected our document-start shim and registered into it instead of overwriting it.

## 8. Contract check and proposed public forums (open question 1)

[`q8-public-readers.json`](learn-spike/results/q8-public-readers.json) tested hand-written isolated-world `read_topic` scripts against the 8 `read_topic` steps of `SpikeVerifier` (`thread_match` not checked; Step 5 list sanity is N/A for `read_topic` — strict `LearnedToolResult` + `ThreadShape` decode, 2 threads, page 2 pagination, rising post numbers, `>=90%` authors, non-HTML bodies, distinct titles/first posts, 40-char faithfulness against visible page text, URL host scan, `<=20 s` and `<=2 MB`):

| Proposed forum | Software & data path | Threads verified (p1 / p2 / thread 2) | Call durations | Max payload | Verifier |
|---|---|---|---|---|---|
| **`https://bbs.archlinux.org`** | **FluxBB** — server-rendered HTML (`fetch` + `DOMParser`, `&p=N` paging, no anti-bot gate) | `id=95007` (`25` / `25` posts), `id=314636` (`25` posts) | `207, 208, 206 ms` | `25,099 B` | **Passed (8 `read_topic` steps, `thread_match` not checked)** |
| **`https://discuss.flarum.org`** | **Flarum** — SPA + JSON:API (`/api/discussions/<id>` + `/api/posts?filter[id]=…`, no anti-bot gate) | `d/31150` (`19` / `6` posts), `d/39415` (`19` posts) | `1,108, 1,157, 866 ms` | `15,190 B` | **Passed (8 `read_topic` steps, `thread_match` not checked)** |

Both are proposed for Decision 1 (`design-learn-on-ask.md` §"Decisions on the open questions"): **FluxBB (`bbs.archlinux.org`)** exercises multi-page DOM scraping, while **Flarum (`discuss.flarum.org`)** exercises SPA route changes + JSON:API pagination. Either works cleanly without credentials or anti-bot challenges; `bbs.archlinux.org` is fastest (`~207 ms`/page).

## 9. Prefix tokens and live model learning

**Cached-prefix token delta** ([`q9-prefix-tokens.json`](learn-spike/results/q9-prefix-tokens.json)), measured via Anthropic `/v1/messages/count_tokens` and Vertex `:countTokens` on the exact final `candSys` (Rule 4's exception, Rule 5's sentence, `forumRules` update, and `"Learning a site"` with the one-call `outerHTML` dump + 4-call exploration cap) and `candTools` (reworded `stableQueryDefinitions`, updated `script_save` description, the 3 new tools, plus the 4 `provides`/`thread_match`/`list_match`/`test_urls` schemas on `script_save` and `script_update`):

| Provider & model | Baseline (25 tools + system) | 3 new tools + prompt/description edits | All-in (+ `provides` schemas on `script_save`/`script_update`) | Settled target |
|---|---|---|---|---|
| Anthropic `claude-haiku-5-5` | `8,728` | `9,993` (**`+1,265` tokens**) | `10,329` (**`+1,601` tokens**) | **Revised** to `< 1,350` (`< 1,700` all-in) |
| Vertex AI `gemini-3.8-flash` | `3,918` | `4,675` (**`+757` tokens**) | `4,795` (**`+877` tokens**) | `< 1,350` / `< 1,700` (**confirmed**) |

*(Note: `8,728` includes `BrowserAgentPrompt.system` + a 4-token user message on top of today's `6,626`-token 25-tool list; adding the 8 `provides`/`thread_match`/`list_match`/`test_urls` schemas across `script_save` and `script_update` accounts for `+336` Anthropic / `+120` Vertex tokens. Earlier inline JS snippets added ~280 extra Anthropic tokens because code punctuation tokenizes densely — Task 6 must keep `"Learning a site"` in plain prose.)*

**Live runs** ([`q9-live-anthropic.json`](learn-spike/results/q9-live-anthropic.json), [`q9-live-gemini.json`](learn-spike/results/q9-live-gemini.json)) executed the exact final `candSys` + `script_save`/`stableQueryDefinitions` description edits and `<page_context>` line (`"- No reading tool for this site yet."`) on today's `AppModel` + `BrowserAgentSession` (`maxSteps = 30`) across the 20-post 2-page fixture forum (`127.0.0.1`, inline login form + JSON API) and `bbs.archlinux.org` (`id=95007`, 50 posts, 2 pages):

| Model (provider) | Forum | Run | Tool calls | Input / Output tokens | Cache-read tokens | `notes.md` | Post-run verifier (8 `read_topic` steps) |
|---|---|---:|---:|---:|---:|---|---|
| `claude-haiku-5-5` (`anthropic`) | `fixture` | 1 | **7** *(2nd visit: **2**)* | `80,414` / `4,433` | `63,604` *(2nd: `46,015`)* | yes | **Passed** (`15`/`5`/`4` posts) |
| `claude-haiku-5-5` (`anthropic`) | `fixture` | 2 | **8** | `109,172` / `5,498` | `102,005` | yes | **Passed** (`15`/`5`/`4` posts) |
| `claude-haiku-5-5` (`anthropic`) | `fixture` | 3 | **7** | `95,728` / `5,255` | `88,427` | yes | **Passed** (`15`/`5`/`4` posts) |
| `claude-haiku-5-5` (`anthropic`) | `bbs.archlinux.org` | 1 | **5** *(2nd visit: **5**)* | `91,097` / `6,157` | `76,604` *(2nd: `135,381`)* | yes | **Passed** (`25`/`25`/`25` posts) |
| `claude-haiku-5-5` (`anthropic`) | `bbs.archlinux.org` | 2 | **8** | `130,675` / `7,817` | `112,494` | yes | **Passed** (`25`/`25`/`25` posts) |
| `claude-haiku-5-5` (`anthropic`) | `bbs.archlinux.org` | 3 | **6** | `86,051` / `5,334` | `75,510` | yes | **Passed** (`25`/`25`/`25` posts) |
| `gemini-3.8-flash` (`vertexai`) | `fixture` | 1 | **12** *(2nd visit: **4**)* | `178,428` / `3,627` | `203,366` *(raw)* | yes | **Passed** (`15`/`5`/`4` posts) |
| `gemini-3.8-flash` (`vertexai`) | `fixture` | 2 | **8** | `85,971` / `1,710` | `53,311` *(raw)* | no | Stopped early at 8 exploration calls (`savedScriptCount: 0`) |
| `gemini-3.8-flash` (`vertexai`) | `fixture` | 3 | **15** | `211,110` / `4,445` | `150,808` *(raw)* | yes | **Passed** (`15`/`5`/`4` posts) |
| `gemini-3.8-flash` (`vertexai`) | `bbs.archlinux.org` | 1 | **16** *(2nd visit: **7**)* | `222,081` / `7,014` | `370,054` *(raw)* | yes | **Passed** (`25`/`25`/`25` posts) |
| `gemini-3.8-flash` (`vertexai`) | `bbs.archlinux.org` | 2 | **20** | `292,373` / `7,630` | `207,699` *(raw)* | yes | **Passed** (`25`/`25`/`25` posts) |
| `gemini-3.8-flash` (`vertexai`) | `bbs.archlinux.org` | 3 | **18** | `300,090` / `7,609` | `206,248` *(raw)* | yes | **Passed** (`25`/`25`/`25` posts) |

**What Q9 settled for Tasks 4, 5, 6 and 10:**
1. **Prompt and rule alignment validated on live runs:**
   - **Rule 4, `script_save`, `forumRules`, and `wukong.fetch` guard:** Amending Rule 4 (`BrowserAgent.swift:248`), `script_save` (`ToolRegistry.swift:1434`), and `forumRules` (`:306`) — and explicitly instructing the Agent not to answer thread requests from `read_page` or `workspaceSection`'s `wukong.fetch` crawl — raised `claude-haiku-5-5` to **6/6 verified runs in `5–8` calls** (an earlier phrasing without the `wukong.fetch` guard made Haiku crawl into `crawls/.../thread.md` instead of saving a reader, while unamended Rule 4 had caused a post-save `script_delete`).
   - **Single-call `outerHTML` DOM dump + 4-call exploration cap (Step 3):** Adding the one-call `outerHTML` + selector/pagination/thread-link inspection rule transformed Vertex `gemini-3.8-flash` on HTML-only `bbs.archlinux.org` from `0/3` (`30/30/30` single-selector `run_js` probes) to **3/3 verified in `16, 20, 18` calls** (`5/6` verified overall, `12–20` calls).
2. **Confirmed/revised cost targets (`design-learn-on-ask.md` line 348):**
   - First learning: **`<= 15` tool calls confirmed for `claude-haiku-5-5`** (`5–8` calls on **6/6** verified runs); **revised to `<= 20` tool calls for `gemini-3.8-flash`**, confirmed on **5/6** verified runs (`12, 15` on fixture; `16, 20, 18` on `bbs.archlinux.org`).
   - Cached-prefix addition: **revised from `< 1,200` to `< 1,350` Anthropic tokens (`+1,265` Anthropic, `+757` Vertex)** for the 3 new tools + prompt/description edits, and **`< 1,700` Anthropic tokens all-in (`+1,601` Anthropic, `+877` Vertex)** once `script_save` and `script_update` add the four `provides` parameter schemas.
   - Second visit summary: **unconfirmed in the pre-Task-4 harness** (`2–5` calls on Haiku, `4–7` on Gemini because `read_topic` / `summarize_topic` are not yet wired to learned scripts, requiring `run_js` + `file_read`); checked against the `1`-call target (`<= 2` acceptance bar) once Task 4 wires the slot.
3. **Gemini cache-read reporting (for Task 10):** `AIService.swift:1187` currently ignores `usageMetadata.cachedContentTokenCount` on `.gemini`/`.vertexAI`, leaving `AgentTokenUsage.cacheReadTokens` `nil` even though Vertex cached up to `370,054` tokens in Q9. Wire `cachedContentTokenCount` into `AgentTokenUsage` so acceptance reports cache-read tokens on both providers.

## Not measured

- **Physical iPhone:** Not run (per `m0-csp-and-worlds.md`, WKWebView content-world/CSP semantics match simulator on the same iOS version; physical device smoke stays in Task 10).
- **Subframes and Web Workers:** All shim injections used `forMainFrameOnly: true`.
- **Wired slot on second visit & in-save `SiteToolVerifier` retry loop:** Tested pre-Task-4/Task-5 (`SpikeVerifier` ran immediately post-run).
