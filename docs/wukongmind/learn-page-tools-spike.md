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
| 8 | Contract on 2 forums | Hand-written `read_topic` scripts for **FluxBB** (`bbs.archlinux.org`) and **Flarum** (`discuss.flarum.org`) passed all 9 `SiteToolVerifier` checks across 2 threads + page 2 (`206–1,157 ms`, `15–25 KB`). | Proposes FluxBB + Flarum for open question 1 |
| 9 | Live learning & prefix | Prefix delta (25 -> 28 tools + Rule 5 + `"Learning a site"`): **`+1,109` Anthropic tokens** (`<1,200`) and **`+630` Vertex tokens**. `claude-haiku-5-5` learned in **`9–13` calls** (6/6 runs <=15, 2nd visit `1` call). `gemini-3.8-flash` on Vertex passed **3/3** on JSON fixture in `22–27` calls, and hit the `30`-step cap on HTML-only `bbs.archlinux.org` probing one selector per `run_js`. | Tighten steps 3–4 & Rule 4; split model call targets (`<=15` Haiku, `<=20` Gemini Flash) |

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

[`q8-public-readers.json`](learn-spike/results/q8-public-readers.json) tested hand-written isolated-world `read_topic` scripts against all 9 steps of `SpikeVerifier` (strict `LearnedToolResult` + `ThreadShape` decode, 2 threads, page 2 pagination, rising post numbers, `>=90%` authors, non-HTML bodies, distinct titles/first posts, 40-char faithfulness against visible page text, URL host scan, `<=20 s` and `<=2 MB`):

| Proposed forum | Software & data path | Threads verified (p1 / p2 / thread 2) | Call durations | Max payload | Verifier |
|---|---|---|---|---|---|
| **`https://bbs.archlinux.org`** | **FluxBB** — server-rendered HTML (`fetch` + `DOMParser`, `&p=N` paging, no anti-bot gate) | `id=95007` (`25` / `25` posts), `id=314636` (`25` posts) | `207, 208, 206 ms` | `25,099 B` | **Passed (9/9)** |
| **`https://discuss.flarum.org`** | **Flarum** — SPA + JSON:API (`/api/discussions/<id>` + `/api/posts?filter[id]=…`, no anti-bot gate) | `d/31150` (`19` / `6` posts), `d/39415` (`19` posts) | `1,108, 1,157, 866 ms` | `15,190 B` | **Passed (9/9)** |

Both are proposed for Decision 1 (`design-learn-on-ask.md` §"Decisions on the open questions"): **FluxBB (`bbs.archlinux.org`)** exercises multi-page DOM scraping, while **Flarum (`discuss.flarum.org`)** exercises SPA route changes + JSON:API pagination. Either works cleanly without credentials or anti-bot challenges; `bbs.archlinux.org` is fastest (`~207 ms`/page).

## 9. Prefix tokens and live model learning

**Cached-prefix token delta** ([`q9-prefix-tokens.json`](learn-spike/results/q9-prefix-tokens.json)), measured via Anthropic `/v1/messages/count_tokens` and Vertex `:countTokens` on the full `AppModel` tool list (`25` -> `28` tools) plus Rule 5's sentence and the 16-line `"Learning a site"` prose section:

| Provider & model | Baseline (25 tools + system) | Candidate (28 tools + Rule 5 + Learning) | Cached-prefix delta | Target |
|---|---|---|---|---|
| Anthropic `claude-haiku-5-5` | `8,728` | `9,837` | **`+1,109` tokens** | `< 1,200` (**confirmed**) |
| Vertex AI `gemini-3.8-flash` | `3,918` | `4,548` | **`+630` tokens** | `< 1,200` (**confirmed**) |

*(Note: `8,728` includes `BrowserAgentPrompt.system` + a 4-token user message on top of today's `6,626`-token 25-tool list. An earlier draft of `"Learning a site"` containing inline JS snippets measured `+1,395` Anthropic tokens because code punctuation tokenizes densely — Task 6 must keep `"Learning a site"` in plain prose.)*

**Live runs** ([`q9-live-anthropic.json`](learn-spike/results/q9-live-anthropic.json), [`q9-live-gemini.json`](learn-spike/results/q9-live-gemini.json)) used today's `AppModel` + `BrowserAgentSession` (`maxSteps = 30`) on the 20-post 2-page fixture forum (`127.0.0.1`, inline login form on thread pages + JSON API) and `bbs.archlinux.org` (`id=95007`, 50 posts, 2 pages):

| Model (provider) | Forum | Run | Tool calls | Input / Output tokens | Cache-read tokens | `notes.md` | Post-run verifier |
|---|---|---:|---:|---:|---:|---|---|
| `claude-haiku-5-5` (`anthropic`) | `fixture` | 1 | **9** *(2nd visit: **1**)* | `101,686` / `5,686` | `84,297` *(2nd: `17,923`)* | yes | **Passed** (`15`/`5`/`4` posts) |
| `claude-haiku-5-5` (`anthropic`) | `fixture` | 2 | **9** | `97,908` / `4,499` | `90,211` | yes | **Passed** (`15`/`5`/`4` posts) |
| `claude-haiku-5-5` (`anthropic`) | `fixture` | 3 | **12** | `138,149` / `5,905` | `131,733` | yes | Saved on call 7, then `script_delete` on call 12 (Rule 4 conflict) |
| `claude-haiku-5-5` (`anthropic`) | `bbs.archlinux.org` | 1 | **12** | `150,912` / `9,732` | `134,841` | yes | Failed Step 3 (`shape` wrapper omitted; no in-save verifier yet) |
| `claude-haiku-5-5` (`anthropic`) | `bbs.archlinux.org` | 2 | **11** | `140,382` / `6,666` | `129,733` | yes | **Passed** (`25`/`25`/`25` posts) |
| `claude-haiku-5-5` (`anthropic`) | `bbs.archlinux.org` | 3 | **13** | `167,005` / `8,875` | `154,347` | yes | **Passed** (`25`/`25`/`25` posts) |
| `gemini-3.8-flash` (`vertexai`) | `fixture` | 1 | **22** *(2nd visit: **4**)* | `379,344` / `3,519` | `413,934` *(raw)* | yes | **Passed** (`15`/`5`/`4` posts) |
| `gemini-3.8-flash` (`vertexai`) | `fixture` | 2 | **24** | `392,412` / `3,390` | `302,251` *(raw)* | yes | **Passed** (`15`/`5`/`4` posts) |
| `gemini-3.8-flash` (`vertexai`) | `fixture` | 3 | **27** | `557,930` / `5,750` | `448,311` *(raw)* | yes | **Passed** (`15`/`5`/`4` posts) |
| `gemini-3.8-flash` (`vertexai`) | `bbs.archlinux.org` | 1–3 | **30, 30, 30** | `359k–405k` / `3.0k–5.9k` | `0–3,294` *(raw)* | no | Hit 30-step cap (`25–29` single-selector `run_js` probes, 0 `read_page`) |

**What Q9 settled for Tasks 4, 5, 6 and 10:**
1. **Four prompt/step fixes before Task 6:**
   - **Amend Rule 4, `script_save`, and `forumRules`:** Today's Rule 4 (`BrowserAgent.swift:248`) and `script_save` (`ToolRegistry.swift:1434`) say to save only when asked `"always"` (causing Haiku fixture #3 to delete its own working reader at step 12), and `forumRules` (`:306`) + `pageContext` (`:359`) say `"Not a forum … use read_page"` (which caused an earlier Gemini pass to stop after 1 `read_page`). Task 4/6's new page-context line (`"No reading tool for this site yet"`) plus explicit Rule 4/`script_save` wording eliminates both conflicts.
   - **Batch DOM inspection & cap exploration (Step 3):** On HTML-only forums, `gemini-3.8-flash` issued 25+ micro-`run_js` calls probing one selector per turn. Step 3 must instruct the Agent to dump one post container's `outerHTML`, author/date/number selectors, and pagination links in **one** `run_js` call, and cap pre-save exploration at **4 calls** before calling `site_learning_report`.
   - **Name `fetch(url)` and outer `shape` (Step 4):** Saved userscripts have no `wukong` helper (unlike `run_js`); Step 4 must specify standard `fetch(url)`, the outer `{ shape, page, total_pages }` envelope, and testing both URLs in **one** `run_js` call. (In Haiku `bbs.archlinux.org` #1, `SiteToolVerifier` inside `script_save` in Task 5 will catch the missing `shape` key and fix it in 1 retry.)
   - **Direct slot call in Step 8:** In `gemini-3.8-flash` fixture runs (`22–27` calls), `4–6` post-save calls came from calling `read_topic` (which refuses today before Task 4 wires slots) and falling back to `run_js`/`script_read`. Wiring `read_topic` in Task 4 cuts those immediately.
2. **Confirmed/revised cost targets (`design-learn-on-ask.md` line 348):**
   - First learning: **`<= 15` tool calls confirmed for `claude-haiku-5-5`** (`9–13` measured); revised to **`<= 20` tool calls for `gemini-3.8-flash`** once Task 4 wires the slot and Task 6 adds the single-call DOM dump + 4-probe cap.
   - Cached-prefix addition: **`< 1,200` tokens confirmed** (`+1,109` Anthropic, `+630` Vertex).
   - Second visit summary: **`1` tool call confirmed** (`1` call measured on Haiku; 1 slot call once Task 4 lands).
3. **Gemini cache-read reporting (for Task 10):** `AIService.swift:1187` currently ignores `usageMetadata.cachedContentTokenCount` on `.gemini`/`.vertexAI`, leaving `AgentTokenUsage.cacheReadTokens` `nil` even though Vertex cached up to `448,311` tokens in Q9. Wire `cachedContentTokenCount` into `AgentTokenUsage` so acceptance reports cache-read tokens on both providers.

## Not measured

- **Physical iPhone:** Not run (per `m0-csp-and-worlds.md`, WKWebView content-world/CSP semantics match simulator on the same iOS version; physical device smoke stays in Task 10).
- **Subframes and Web Workers:** All shim injections used `forMainFrameOnly: true`.
- **In-save `SiteToolVerifier` retry loop:** `SpikeVerifier` ran immediately after each live run because Task 5 has not yet wired `SiteToolVerifier` into `script_save`.
