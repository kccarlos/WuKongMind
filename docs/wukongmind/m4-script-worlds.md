# M4: script worlds spike

This page answers the seven questions of [design-m4.md](design-m4.md) "The spike comes first". Every answer comes from real `WKWebView` runs on the iOS 27.2 simulators (iPhone 18 Pro and iPad Air 11-inch (M4)), in the [M0 pattern](m0-csp-and-worlds.md). The harness is in [`m4-spike/`](m4-spike/); the raw results are checked in as [`m4-spike/results/results.md`](m4-spike/results/results.md) (iPhone) and [`m4-spike/results/ipad/results.md`](m4-spike/results/ipad/results.md), with `results.json` beside each. No app code was touched.

Rerun (about 2 minutes each, needs Xcode and `xcodegen`):

```sh
docs/wukongmind/m4-spike/run.sh                                  # iPhone 18 Pro
SIM=ipad OUT=$PWD/docs/wukongmind/m4-spike/results/ipad docs/wukongmind/m4-spike/run.sh
```

## Method

- An in-test HTTP server on `127.0.0.1` serves the fixture page with real CSP headers. The seven variants are the M0 matrix: no CSP, and `self`, `nonce`, `strict-dynamic`, each as a header and as a `<meta>` tag.
- Worlds are named as the design names them: `WukongAgent`, `WukongScript.a`, `WukongScript.b` (and `WukongScript.0` … `.29` for the cost run). Each script world has its own `WKScriptMessageHandlerWithReply`, named `gm`, that knows which script it belongs to and checks `message.world` against the world it was registered in.
- Each row in the raw results is one check on one variant. Both simulators gave the same `yes`/`no` in every row.
- **Not done:** the physical iPhone (the brief names simulators), and a run under real third-party scripts. Memory and timing numbers are from the simulator, where the web content process runs on the Mac, so treat them as relative, not absolute.

## Answers

| # | Question | Answer |
|---|---|---|
| 1 | Identity | **Yes, on every variant.** A handler registered in one world is visible only there. From the page world `window.webkit` doesn't even exist; from `WukongAgent` and the other script world `messageHandlers.gm` is `undefined`. A script that claims another script's ID in the message body gets the reply for its own ID, and `message.world` is the registered world every time. |
| 2 | Cost | **The time is fine, the memory is not.** See the table. 30 small worlds cost about 3 ms but 34 to 44 MB (about 1.1 to 1.5 MB per world), over the 20 MB line. **The fallback is adopted.** |
| 3 | CSS | **Yes, on every variant.** Sheets made in world A and world B at document start both apply. Each world sees both sheets in `document.adoptedStyleSheets` (length 2), and a sheet the page adds afterwards leaves both alone. A removes only its own (filter by its own reference) and B's and the page's stay; B removes its own and only the page's is left. |
| 4 | Errors | **No as worded, yes with a different capture.** A plain `error`/`unhandledrejection` listener in a script world is not isolated and not useful: see below. Wrapping in the world works exactly. |
| 5 | Document start | **Yes, on every variant**, for a small value and for 256 KB. A value set through the handler on load 1 is read synchronously on load 2, with `readyState` `loading`, before any page script ran (the page's first inline script had not set its marker). |
| 6 | Live apply | **Yes, on every variant.** `callAsyncJavaScript` in `WKContentWorld.world(name:)` of the script runs the candidate in the same world as the script's `WKUserScript` (it sees the script's `window.__state`); a style it adds applies; a second call in the same world undoes it; a synchronous throw comes back to Swift as an error; a late throw (timer) reaches the world's error listener; world B does not see A's state. |
| 7 | Today's shared world | **Yes, it can be caught: the Agent's scripts move to their own worlds.** A script in `WukongAgent` at document start caught the `run_js` call token with each of four attacks (wrap the instance's `postMessage`, wrap the prototype's, replace `messageHandlers.wukongAgent`, keep `window.webkit` and wrap later), on every variant tried (no CSP, `self` header, `nonce` header). |

### Q2 numbers

Median of 7 loads of the fixture page after a warm-up, against 0 scripts. "Heavy" is every script carrying 256 KB of stored values and a 2 MB `@require` body. Memory is the physical footprint of the web content process after the loads.

| Scripts, each in its own world | iPhone: load / document end / memory | iPad: load / document end / memory |
|---|---|---|
| 1, small | +4 ms / +4 ms / +2.0 MB | +6 ms / +4 ms / +1.5 MB |
| 10, small | -1 ms / +0 ms / +17.9 MB | +1 ms / +1 ms / +10.8 MB |
| **30, small** | **+3 ms / +4 ms / +44.2 MB** | **+1 ms / +0 ms / +38.9 MB** |
| 1, heavy | +1 ms / +1 ms / +38.5 MB | +7 ms / +7 ms / +46.0 MB |
| 10, heavy | +24 ms / +21 ms / +394.5 MB | +23 ms / +22 ms / +239.9 MB |
| **30, heavy** | **+59 ms / +60 ms / +432.2 MB** | **+137 ms / +79 ms / +517.9 MB** |

(The first run on the iPhone gave +34 MB and +530 MB for the two bold rows, so the memory numbers move by about 20 percent between runs.)

- Time: 30 small worlds are within noise. 30 heavy worlds pass 50 ms on both devices, and the memory is the cost of holding every script's source in every page.
- Memory: 30 small worlds pass 20 MB on both devices. **By the design's own rule the fallback applies.**

**Decision: the fallback is adopted.** The app injects a script only into pages whose host the script can match. `syncUserScripts` is rebuilt at the start of each main-frame navigation from `UserScript.matchesDomain`; a route change inside a single-page app still matches by path in JavaScript. A person's few scripts for one site then cost a handful of worlds, not thirty. A script that can match every host (`*://*/*`) still costs a world on every page, which is why the global scripts switch and the size limits stay.

### Q4 in detail

What a plain `window` listener in a script world gets (same on every variant and both devices):

- **It is not isolated.** Listener A received the page's errors (`PAGE-click`, `PAGE-timer`) with full messages, and the unhandled rejections of world B and of the page. `error` events arrive in every world's listeners.
- **Its own errors are mostly unreadable.** Errors thrown by code that came from a `WKUserScript` source (a timer, a click handler) arrive as `Script error.`, with no error object, no file, no stack. The same listener gets the page's errors in full. (Adding a `//# sourceURL` pragma makes no difference to this; it was tried, and it is not used.) Errors thrown by code run through `callAsyncJavaScript` (a candidate) arrive in full.
- **Rejections carry the promise.** `unhandledrejection` arrives with the reason in full, and `e.promise instanceof Promise` is true only for a promise made in the listener's own world. Filtering on it kept exactly the world's own rejection in both A and B.

What works, and replaces "the wrapper listens for `error` in its own world" in the design:

1. **Wrap in the world.** The script's wrapper replaces `setTimeout`, `setInterval` and `EventTarget.prototype.addEventListener` in its own world (each world has its own copy of these, so the page and other worlds are untouched) so a callback is run in a `try`/`catch` that reports the error and rethrows it. Result: A reported exactly its own timer and click errors, with a stack, and B reported exactly its own; nothing foreign, on every variant. (A listener one world added to a shared element runs the other world's click handler too, and a throw there is reported by the world that owns the listener, which is right.)
2. **Filter rejections** by `e.promise instanceof Promise`.
3. **Ignore the plain `error` event** in script worlds. At most it is a hint that something was thrown ("Script error." with no owner).

Caveat: replacing `addEventListener` breaks `removeEventListener` for functions registered after the wrap unless the wrapper keeps a map from the original to the wrapped function. Task 6 owns that detail. Observers (`MutationObserver`, `IntersectionObserver`) and `requestAnimationFrame` need the same wrap, which the spike did not measure.

The brief's rule says a failed question 4 sends the design back to the owner. It failed as worded, but the capture the design already asks for ("wraps every callback") is enough, and nothing in the design's cost or safety changes, so this page adopts it and says so here; the owner can overrule it.

## What changes in the design

Applied to [design-m4.md](design-m4.md) in this task:

- **Decisions.** The Agent's own scripts (no grants) **move to their own worlds too**; the table row "Made by the Agent, no grants → `WukongAgent`" is replaced. `WukongAgent` keeps only `run_js` and the helpers. Task 3's "unless question 7 found the shared world unsafe" clause is therefore decided: unsafe, so own world.
- **Injection** is per matching host (the fallback), not per script on every page.
- **Errors.** Capture is by wrapping callbacks in the world and filtering rejections, not by the plain `error` listener.
- **Storage.** The sync read at document start is confirmed under every CSP in the matrix, for the full 256 KB.

## Nothing here changed

The questions the spike did not ask (a real GM API, reply handler limits, behaviour on a physical device) stay with tasks 3 and 4.
