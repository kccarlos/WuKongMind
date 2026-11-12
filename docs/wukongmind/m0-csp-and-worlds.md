# M0: CSP and the two execution worlds

This page answers the "to verify" items in [requirements](requirements.md) section 3 ("Key technical points") and checks the bridge isolation in section 8. Every answer below comes from real WKWebView runs, not from documentation. The harness is in [`m0-spike/`](m0-spike/), the raw generated results are in [`m0-spike/results/results.md`](m0-spike/results/results.md) (with `results.json`), and the full outcome table is reproduced in the appendix.

## Environment and how to rerun

- Xcode 27.2 (27B52) on macOS 27.2.1.
- iOS Simulator runtime iOS 27.2 (24B8117). Main run on **iPhone 18 Pro**; a second run on **iPad Air 11-inch (M4)** gave the same outcome in every cell (only the whole-run `report-uri` count differed, 393 vs 394, from timing).
- **Physical device: not run (WAIVED_BY_USER style).** Nothing here was verified on the iPhone 13; see "Simulator and device".
- Rerun with one command from the repo root (needs Xcode and `xcodegen`; takes about 5 minutes):

  ```sh
  docs/wukongmind/m0-spike/run.sh
  # another simulator / output folder:
  SIM="iPad Air 11-inch (M4)" OUT=/tmp/m0-ipad docs/wukongmind/m0-spike/run.sh
  ```

  It generates a throwaway Xcode project (a tiny host app and one hosted XCTest), runs it on the simulator and rewrites `results/results.{md,json}`. Nothing in the app targets, the app's project or its tests is touched.

## How the harness works

- An in-test HTTP server (Network.framework, `127.0.0.1`) serves a fixture page, so CSP **headers are real**. A second server on another port is the "other origin".
- Seven page variants: no CSP, and three policies, each delivered once as an HTTP header and once as a `<meta>` tag:
  - **self:** `default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'`
  - **nonce:** the same, but `script-src 'nonce-…'`
  - **strict-dynamic:** the same, but `script-src 'nonce-…' 'strict-dynamic'`

  None of them allows `'unsafe-eval'`, and none has `'unsafe-inline'` in `style-src`. The header form adds `report-uri /report`, which the spec ignores in `<meta>`.
- **Controls prove the policy is enforced.** The page's own plain inline script, its `eval` and its inline `<style>` are asserted to run under no CSP and to be blocked under every policy. The page's nonced external script and its same-origin stylesheet are asserted to run everywhere. The test fails if a control is wrong.
- Each probe gets a fresh web view, attached to a window, with a non-persistent data store. The probe runs in the page world (`.page`) or an isolated world (`WKContentWorld.world(name: "wukong-iso")`).
  - The probe itself is the injected code: `callAsyncJavaScript`, or `evaluateJavaScript` for that row.
  - Each probe has a 3-second JavaScript timeout race and returns a JSON string.
  - "Works" or "blocked" is judged by an effect: a DOM marker, `getComputedStyle`, or whether the server received the request. It is never judged by whether the call threw.
- **CSP violations** are collected by a `securitypolicyviolation` listener running in a third world, plus the header variants' `report-uri` POSTs to the local server.
- A dynamically created script records which world's global it set. That shows which world it ran in, whatever world created the tag.

## Short answers

| Question | Answer (iOS 27.2 simulator) |
|---|---|
| Does `WKUserScript` run under CSP? | **Yes**, at document start and end, in both worlds, under every policy (header and meta). |
| `evaluateJavaScript` / `callAsyncJavaScript` under CSP? | **Yes**, in both worlds, under every policy. `await` works. An object return arrives in Swift as `[String: Any]`, and a `JSON.stringify` string arrives as `String`. |
| `eval` / `new Function` inside injected code? | **Page world: blocked** by any policy without `'unsafe-eval'`. The error is `EvalError: Refused to evaluate a string as JavaScript because 'unsafe-eval' … is not an allowed source of script …`, and a violation fires. **Isolated world: always works**, with no violation. One exception: a page-world document-start script under a `<meta>` CSP runs before the meta tag is parsed, so `eval` still works there. |
| CSS via `<style>`? | **Blocked in both worlds** when `style-src` has no `'unsafe-inline'` (`style-src-elem` violation). A `style` attribute set with `setAttribute` is blocked too (`style-src-attr`). |
| CSS via `adoptedStyleSheets`? | **Works in both worlds** under every policy, as does `element.style.x = …` (CSSOM). |
| Injected code creating `<script>` tags? | The tag is inserted, and the script **always runs in the page world**, even when the isolated world created it. The page's `script-src` decides, exactly as for the page's own scripts, whichever world made the tag. See the dynamic-script table below. |
| `fetch` / XHR to another origin? | **Page world: blocked by `connect-src`.** The request never reaches the server, the call fails with `TypeError: Load failed`, and a violation fires. **Isolated world: `connect-src` is not applied.** The request reaches the server and succeeds when the response has CORS headers. **CORS still applies in both worlds**: without `Access-Control-Allow-Origin` the request is sent but the response cannot be read. |
| Violations visible? | Yes. Every block above fires `securitypolicyviolation` on the document (observable from any world) and, for header policies, a `report-uri` POST. Isolated-world `eval` and fetch fire nothing, because they are not checked. |

### Dynamic `<script>` tags (same in both worlds; ✓ ran, ✗ blocked with a violation)

| Created tag | no CSP | self | nonce | strict-dynamic |
|---|---|---|---|---|
| inline, no nonce | ✓ | ✗ | ✗ | ✓ |
| inline, nonce copied from the page (`el.nonce = pageScript.nonce`) | ✓ | ✗ (policy has no nonce) | ✓ | ✓ |
| `src` same origin, no nonce | ✓ | ✓ | ✗ | ✓ |
| `src` same origin, nonce copied | ✓ | ✓ | ✓ | ✓ |
| `src` other origin, no nonce | ✓ | ✗ | ✗ | ✓ |
| `src` other origin, nonce copied | ✓ | ✗ | ✓ | ✓ |

Header and meta delivery gave the same results.

- Notes:
  - The page's nonce is readable through the `.nonce` property from both worlds. (`getAttribute('nonce')` was not tested.)
  - Under `'strict-dynamic'`, WebKit runs every script element that was not inserted by the parser, inline ones included and without a nonce, wherever the code that made them came from. That is WebKit's current behaviour on iOS 27.2. Don't build on it: a page can switch to a plain nonce policy at any time.
- A blocked `src` tag fires `error`, and the server never sees the request.

## Execution worlds

| Check | Result |
|---|---|
| Isolated world reads and writes the DOM | **Yes.** A `data-` attribute written from the isolated world is read from the page world, and the other way round. |
| Isolated world sees page JS globals | **No.** `typeof window.pageGlobal` is `undefined` there. Assigning `window.pageGlobal = 99` in the isolated world leaves the page's value at `42`. |
| Page world sees page JS globals | **Yes** (`number`, and it can change them). |
| Page world sees a `WKScriptMessageHandlerWithReply` registered only in the isolated world | **No.** In the page world `window.webkit.messageHandlers` is an object but `.agent` is `undefined`, under every variant. A control handler registered in `.page` (`pageCtl`) is visible there and replies. It is not visible from the isolated world, so handlers are per world in both directions. |
| Reply handler returns values to the isolated world | **Yes.** `await window.webkit.messageHandlers.agent.postMessage({…})` resolved to `{echo: {…}, world: "wukong-iso"}`. |
| Page-world `fetch`/XHR wrap at document start sees the page's own requests | **Yes, under every policy, header and meta.** It saw a `fetch` and an XHR made while the page's own nonced external script was parsing, and a `fetch` made on `load`, all with status 200. |
| The same wrap in the isolated world | **Sees none of them.** Each world has its own `fetch` and `XMLHttpRequest`. |
| Agent's own requests and the page-world wrap | Requests from page-world injected code are captured. Requests from isolated-world code are **not**, because they go through the isolated world's own `fetch`. |

## Consequences for the design

- **AgentBridge `run_js`: default to the isolated world.** It works under every CSP tested.
  - `eval`, `new Function` and cross-origin `fetch` all work there; `fetch` still needs CORS.
  - It has full DOM access, it is invisible to page scripts, and it is the only world that can reach the `agent` reply handler.
  - Offer `world: "page"` for reading or changing page JS state, such as framework stores or page functions.
    - Under CSP, the page world still runs the body passed to `callAsyncJavaScript`. Only `eval`/`new Function`, `<style>`/`style` attributes and `connect-src`-blocked requests inside it fail.
    - Return the `EvalError` or `TypeError: Load failed` text to the model as is, with a hint to retry in the isolated world.
- **`inject_css`: use `adoptedStyleSheets`.** Keep one `CSSStyleSheet` per script or tool call, and update it with `replaceSync`. It works in both worlds under every policy. Never use `<style>` elements or `style` attributes: any `style-src` without `'unsafe-inline'` blocks them, even from the isolated world. Per-element tweaks can use CSSOM (`el.style.prop = …`).
  - Not tested here: pages that reassign `document.adoptedStyleSheets` themselves, or content inside shadow roots, which have their own `adoptedStyleSheets`. The implementation should re-append its sheet and cover open shadow roots.
- **ScriptStore injection: use `WKUserScript` in the isolated world by default**, at document start or end.
  - It runs under every CSP, and `eval`/`new Function` work, which userscripts often rely on.
  - Scripts that need page globals (Tampermonkey's `unsafeWindow` case) need the page world, where `eval` is blocked under CSP.
  - For external libraries (`@require`), don't add `<script src>` tags: whether they run depends on the page's policy. Instead, prepend the library source to the `WKUserScript` source on the native side. As a runtime fallback, isolated-world code can `fetch` the text and run it with indirect `eval`; that ran in the isolated world under all seven variants (row "workaround: fetch other-origin script text + indirect eval").
  - Dynamically created `<script>` tags run in the page world under the page's CSP. Treat them only as a way to put code into the page world when the policy allows it.
- **Network-capture hook: the plan works as written.**
  - It needs a document-start `WKUserScript` in **`.page`** wrapping `fetch` and `XMLHttpRequest`. It saw the page's own requests under every policy, header and meta. The isolated world cannot do it.
  - The page can see and change the hook and the ring buffer, because both live in its world. Treat captured data as untrusted page content.
  - The page world cannot reach the `agent` handler, so the hook cannot push to it. The app should pull the ring buffer with `evaluateJavaScript(…, contentWorld: .page)`. A page-world handler would also work, but any page could then forge entries.
  - The agent's isolated-world requests are not captured. That is fine: `http_request` and the audit log record the agent's own traffic.
  - Not tested: requests from workers, `navigator.sendBeacon`, `<img>`/`<form>` loads and WebSockets. A `fetch`/XHR wrap cannot see these.
- **Bridge isolation (section 8) holds.** A reply handler registered only in the isolated world is invisible to page scripts. The page world still has `window.webkit.messageHandlers` here, because the harness registered a page-world control handler. Not tested: whether `window.webkit` exists at all in the page world when no page-world handler is registered.
- **Timing quirk:** page-world code at document start runs before a `<meta>` CSP is parsed, so it briefly escapes that policy, though not a header policy. Don't depend on it.

## Simulator and device

- Every result is from the iOS 27.2 simulator: iPhone 18 Pro, and iPad Air 11-inch (M4) (identical outcomes).
- **Device verification: not done (WAIVED_BY_USER style).** The physical iPhone 13 was not used. No result here is plausibly simulator-specific:
  - CSP enforcement, content worlds and message-handler scoping are WebKit logic that the simulator shares with the device for the same iOS version.
  - None of the probes uses a simulator-only feature. The isolated-world exemptions (`eval`, `connect-src`) come from WebKit's CSP checks, not from the host.
- What could differ on a device:
  - A different iOS version, since the WebKit version follows iOS.
  - Lockdown Mode, which changes JavaScript features.

  Rerun on the device once before M1 if either applies.

## Not verified

- Physical device (see above).
- WebKit's own Web Inspector console text for resource blocks. The harness cannot read the console in-process. It records the `EvalError` message text, `securitypolicyviolation` events and `report-uri` reports instead.
- Policies not in the matrix: hash sources, `require-trusted-types-for 'script'` / Trusted Types, `sandbox`, and `script-src-elem`/`-attr` split differently from `script-src`.
- Frames: everything here is main frame only.
- The capture-hook gaps listed above (workers, beacons, WebSockets).

## Appendix: full outcome table (generated)

From `m0-spike/results/results.md`, iPhone 18 Pro, iOS 27.2 simulator. "⚑" means at least one `securitypolicyviolation` event fired during that case. Each case waits 150 ms after load before taking its snapshot, so the page's own load-time violations are not counted against it. The raw results list each case's violations (directive, blocked URI).

| Case | World | no CSP | self (header) | self (meta) | nonce (header) | nonce (meta) | strict-dynamic (header) | strict-dynamic (meta) |
|---|---|---|---|---|---|---|---|---|
| Control: page inline <script> without nonce | - | runs | blocked | blocked | blocked | blocked | blocked | blocked |
| Control: page inline <script> with nonce | - | runs | blocked | blocked | runs | runs | runs | runs |
| Control: page same-origin <script src> with nonce | - | runs | runs | runs | runs | runs | runs | runs |
| Control: page eval | - | runs | blocked | blocked | blocked | blocked | blocked | blocked |
| Control: page inline <style> | - | applies | blocked | blocked | blocked | blocked | blocked | blocked |
| Control: page same-origin stylesheet | - | applies | applies | applies | applies | applies | applies | applies |
| WKUserScript at document start: runs | page | runs | runs | runs | runs | runs | runs | runs |
| WKUserScript at document start: eval | page | works | blocked | works | blocked | works | blocked | works |
| WKUserScript at document start: new Function | page | works | blocked | works | blocked | works | blocked | works |
| WKUserScript at document end: runs | page | runs | runs | runs | runs | runs | runs | runs |
| WKUserScript at document end: eval | page | works | blocked | blocked | blocked | blocked | blocked | blocked |
| WKUserScript at document end: new Function | page | works | blocked | blocked | blocked | blocked | blocked | blocked |
| Capture hook at start sees page's own fetch/XHR | page | sees all | sees all | sees all | sees all | sees all | sees all | sees all |
| WKUserScript at document start: runs | isolated | runs | runs | runs | runs | runs | runs | runs |
| WKUserScript at document start: eval | isolated | works | works | works | works | works | works | works |
| WKUserScript at document start: new Function | isolated | works | works | works | works | works | works | works |
| WKUserScript at document end: runs | isolated | runs | runs | runs | runs | runs | runs | runs |
| WKUserScript at document end: eval | isolated | works | works | works | works | works | works | works |
| WKUserScript at document end: new Function | isolated | works | works | works | works | works | works | works |
| Capture hook at start sees page's own fetch/XHR | isolated | sees none | sees none | sees none | sees none | sees none | sees none | sees none |
| CSP violations during page load (securitypolicyviolation) | - | 0 | 8 ⚑ | 6 ⚑ | 7 ⚑ | 5 ⚑ | 7 ⚑ | 5 ⚑ |
| evaluateJavaScript | page | works | works | works | works | works | works | works |
| evaluateJavaScript | isolated | works | works | works | works | works | works | works |
| callAsyncJavaScript await + JSON string | page | works | works | works | works | works | works | works |
| callAsyncJavaScript await + JSON string | isolated | works | works | works | works | works | works | works |
| callAsyncJavaScript await + object return | page | works | works | works | works | works | works | works |
| callAsyncJavaScript await + object return | isolated | works | works | works | works | works | works | works |
| eval in injected code | page | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ |
| eval in injected code | isolated | works | works | works | works | works | works | works |
| new Function in injected code | page | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ |
| new Function in injected code | isolated | works | works | works | works | works | works | works |
| DOM read + write | page | works | works | works | works | works | works | works |
| DOM read + write | isolated | works | works | works | works | works | works | works |
| page JS global visible | page | visible | visible | visible | visible | visible | visible | visible |
| page JS global visible | isolated | not visible | not visible | not visible | not visible | not visible | not visible | not visible |
| CSS via <style> element | page | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ |
| CSS via <style> element | isolated | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ |
| CSS via adoptedStyleSheets | page | works | works | works | works | works | works | works |
| CSS via adoptedStyleSheets | isolated | works | works | works | works | works | works | works |
| CSS via setAttribute('style') | page | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ |
| CSS via setAttribute('style') | isolated | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ |
| CSS via element.style (CSSOM) | page | works | works | works | works | works | works | works |
| CSS via element.style (CSSOM) | isolated | works | works | works | works | works | works | works |
| dynamic <script> inline | page | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | works | works |
| dynamic <script> inline | isolated | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | works | works |
| dynamic <script> inline + copied nonce | page | works | blocked ⚑ | blocked ⚑ | works | works | works | works |
| dynamic <script> inline + copied nonce | isolated | works | blocked ⚑ | blocked ⚑ | works | works | works | works |
| dynamic <script src> same origin | page | works | works | works | blocked ⚑ | blocked ⚑ | works | works |
| dynamic <script src> same origin | isolated | works | works | works | blocked ⚑ | blocked ⚑ | works | works |
| dynamic <script src> same origin + copied nonce | page | works | works | works | works | works | works | works |
| dynamic <script src> same origin + copied nonce | isolated | works | works | works | works | works | works | works |
| dynamic <script src> other origin | page | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | works | works |
| dynamic <script src> other origin | isolated | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | works | works |
| dynamic <script src> other origin + copied nonce | page | works | blocked ⚑ | blocked ⚑ | works | works | works | works |
| dynamic <script src> other origin + copied nonce | isolated | works | blocked ⚑ | blocked ⚑ | works | works | works | works |
| fetch same origin | page | works | works | works | works | works | works | works |
| fetch same origin | isolated | works | works | works | works | works | works | works |
| fetch other origin (CORS allowed) | page | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ |
| fetch other origin (CORS allowed) | isolated | works | works | works | works | works | works | works |
| fetch other origin (no CORS header) | page | blocked | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ |
| fetch other origin (no CORS header) | isolated | blocked | blocked | blocked | blocked | blocked | blocked | blocked |
| workaround: fetch other-origin script text + indirect eval | page | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ |
| workaround: fetch other-origin script text + indirect eval | isolated | works | works | works | works | works | works | works |
| XHR other origin (CORS allowed) | page | works | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ | blocked ⚑ |
| XHR other origin (CORS allowed) | isolated | works | works | works | works | works | works | works |
| message handlers seen | page | agent not visible | agent not visible | agent not visible | agent not visible | agent not visible | agent not visible | agent not visible |
| message handlers seen | isolated | agent visible | agent visible | agent visible | agent visible | agent visible | agent visible | agent visible |
| report-uri reports received (whole run) | - |  | 394 |  | 345 |  | 339 |  |

