import WebKit
import XCTest

// M4 spike: the seven questions of design-m4.md "The spike comes first". Every answer comes from a real
// WKWebView load of a fixture page served by SpikeServer (so CSP headers are real). Rows go to results.{md,json}.

private func s(_ a: Any?) -> String { a.map { "\($0)" } ?? "nil" }

@MainActor
final class ScriptWorldsTests: SpikeCase {
    // MARK: Q1 identity

    func testQ1Identity() async throws {
        let q = "Q1 Identity"
        for v in Variant.all {
            let hA = ScriptHandler(id: "A", expectedWorld: Self.worldA), hB = ScriptHandler(id: "B", expectedWorld: Self.worldB)
            let hAgent = ScriptHandler(id: "agent", expectedWorld: Self.agentWorld)
            let wv = try await makeView { u in
                u.addScriptMessageHandler(hA, contentWorld: Self.worldA, name: "gm")
                u.addScriptMessageHandler(hB, contentWorld: Self.worldB, name: "gm")
                u.addScriptMessageHandler(hAgent, contentWorld: Self.agentWorld, name: "wukongAgent")
            }
            try await navigate(wv, v)
            let probe = """
            const mh = window.webkit && window.webkit.messageHandlers;
            const out = {gm: mh ? typeof mh.gm : 'n/a', wukongAgent: mh ? typeof mh.wukongAgent : 'n/a'};
            for (const n of ['gm', 'wukongAgent']) if (mh && mh[n]) {
              try { out['reply_' + n] = await mh[n].postMessage({claimId: 'B', from: w}); } catch (e) { out['reply_' + n] = 'threw ' + e.message; }
            }
            return JSON.stringify(out);
            """
            let worlds: [(String, WKContentWorld)] = [("page", .page), ("WukongAgent", Self.agentWorld), ("script A", Self.worldA), ("script B", Self.worldB)]
            for (name, world) in worlds {
                let r = await call(wv, probe, in: world, args: ["w": name])
                let gm = r["reply_gm"] as? [String: Any], ag = r["reply_wukongAgent"] as? [String: Any]
                let seen = "gm=\(s(r["gm"])) wukongAgent=\(s(r["wukongAgent"]))"
                let replies = "reply gm=\(gm.map { "\($0["id"] ?? "?")/world \($0["world"] ?? "?")/native world ok \($0["worldMatches"] ?? "?")" } ?? "none") wukongAgent=\(ag.map { "\($0["id"] ?? "?")/\($0["world"] ?? "?")" } ?? "none")"
                let expectGM: String?, expectAgent: String?
                switch name {
                case "script A": (expectGM, expectAgent) = ("A", nil)
                case "script B": (expectGM, expectAgent) = ("B", nil)
                case "WukongAgent": (expectGM, expectAgent) = (nil, "agent")
                default: (expectGM, expectAgent) = (nil, nil)
                }
                let ok = (gm?["id"] as? String) == expectGM && (ag?["id"] as? String) == expectAgent
                    && (gm == nil || (gm?["worldMatches"] as? Bool) == true)
                record(q, v.label, "handler visible only in its own world, from \(name); a claimed id 'B' in the body is ignored", yn(ok), "\(seen); \(replies)")
            }
            teardown(wv)
        }
    }

    // MARK: Q2 cost

    static let smallWrapper = "(function () { window.__wrapper = 1; var gm = { log: function (m) { return window.webkit.messageHandlers.gm.postMessage({ op: 'log', m: String(m) }); } }; window.GM = gm; })();"

    /// 256 KB of stored values as a JSON literal, and a 2 MB `@require` body of many small functions.
    static let values256K: String = {
        let chunk = String(repeating: "v", count: 1023)
        let obj = (0 ..< 256).reduce(into: [String: String]()) { $0["key\($1)"] = chunk }
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }()
    static let require2M: String = {
        let fns = (0 ..< 35000).map { "function r\($0)(a, b) { return a * \($0) + b; }" }.joined(separator: "\n")
        return "(function () {\n\(fns)\nwindow.__req = r1(2, 3);\n})();"
    }()

    func testQ2Cost() async throws {
        let q = "Q2 Cost"
        let v = Variant.all[0]
        struct Stat { var loadMs: [Double] = []; var dclMs: [Double] = []; var footprint: Int? }
        var base: Stat?
        let scenarios: [(Int, Bool)] = [(0, false), (1, false), (10, false), (30, false), (1, true), (10, true), (30, true)]
        for (n, heavy) in scenarios {
            let handlers = (0 ..< n).map { ScriptHandler(id: "s\($0)", expectedWorld: nil) }
            let wv = try await makeView { u in
                for i in 0 ..< n {
                    let w = WKContentWorld.world(name: "WukongScript.\(i)")
                    u.addScriptMessageHandler(handlers[i], contentWorld: w, name: "gm")
                    let src = heavy ? "window.__vals = \(Self.values256K);\n\(Self.require2M)\n\(Self.smallWrapper)" : Self.smallWrapper
                    u.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: w))
                }
            }
            _ = try await navigate(wv, v) // warm-up
            var st = Stat()
            for _ in 0 ..< 7 {
                st.loadMs.append(try await navigate(wv, v))
                let dcl = await call(wv, "const t = performance.getEntriesByType('navigation')[0]; return JSON.stringify({dcl: t.domContentLoadedEventEnd - t.startTime});", in: .page)
                st.dclMs.append(dcl["dcl"] as? Double ?? -1)
            }
            await pause(500)
            st.footprint = footprint(wv)
            func med(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
            let label = "\(n) worlds, \(heavy ? "heavy (256 KB values + 2 MB require each)" : "small wrapper")"
            if n == 0 { base = st }
            let dLoad = base.map { med(st.loadMs) - med($0.loadMs) }
            let dDcl = base.map { med(st.dclMs) - med($0.dclMs) }
            let dMem = (st.footprint != nil && base?.footprint != nil) ? (st.footprint! - base!.footprint!) : nil
            record(q, v.label, label,
                   "info", String(format: "median load→didFinish %.0f ms (%+.0f vs 0 worlds); median document-end (DCL) %.0f ms (%+.0f); web process footprint %@ (%@ vs 0 worlds); handlers registered %d",
                                  med(st.loadMs), dLoad ?? 0, med(st.dclMs), dDcl ?? 0,
                                  st.footprint.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "unreadable",
                                  dMem.map { String(format: "%+.1f MB", Double($0) / 1_048_576) } ?? "n/a", n))
            teardown(wv)
        }
    }

    // MARK: Q3 CSS

    func testQ3AdoptedStyleSheets() async throws {
        let q = "Q3 CSS"
        let sheetA = "const sa = new CSSStyleSheet(); sa.replaceSync('#target { background-color: rgb(1, 2, 3); }'); window.__mine = sa; document.adoptedStyleSheets = [...document.adoptedStyleSheets, sa];"
        let sheetB = "const sb = new CSSStyleSheet(); sb.replaceSync('#target { color: rgb(4, 5, 6); }'); window.__mine = sb; document.adoptedStyleSheets = [...document.adoptedStyleSheets, sb];"
        let computed = "const c = getComputedStyle(document.getElementById('target')); return JSON.stringify({bg: c.backgroundColor, color: c.color, border: c.borderTopWidth, len: document.adoptedStyleSheets.length});"
        for v in Variant.all {
            let wv = try await makeView { u in
                u.addUserScript(WKUserScript(source: "(function(){\(sheetA)})();", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.worldA))
                u.addUserScript(WKUserScript(source: "(function(){\(sheetB)})();", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.worldB))
            }
            try await navigate(wv, v)
            let both = await call(wv, computed, in: .page)
            record(q, v.label, "A's and B's sheets both apply (from document-start scripts)", yn(both["bg"] as? String == "rgb(1, 2, 3)" && both["color"] as? String == "rgb(4, 5, 6)"), "page sees \(json(both))")
            let seenA = await call(wv, "return JSON.stringify({len: document.adoptedStyleSheets.length, hasMine: document.adoptedStyleSheets.includes(window.__mine)});", in: Self.worldA)
            let seenB = await call(wv, "return JSON.stringify({len: document.adoptedStyleSheets.length, hasMine: document.adoptedStyleSheets.includes(window.__mine)});", in: Self.worldB)
            record(q, v.label, "each world's adoptedStyleSheets list (length, contains its own sheet)", "info", "A \(json(seenA)); B \(json(seenB)); page \(json(both["len"] ?? "?"))")
            // The page adds its own sheet after both, then A removes only its own and B adds a second one.
            _ = await call(wv, "const p = new CSSStyleSheet(); p.replaceSync('#target { border-top: 5px solid red; }'); document.adoptedStyleSheets = [...document.adoptedStyleSheets, p]; return '{}';", in: .page)
            let afterPage = await call(wv, computed, in: .page)
            record(q, v.label, "a sheet the page adds afterwards does not remove A's or B's", yn(afterPage["bg"] as? String == "rgb(1, 2, 3)" && afterPage["color"] as? String == "rgb(4, 5, 6)" && afterPage["border"] as? String == "5px"), json(afterPage))
            _ = await call(wv, "document.adoptedStyleSheets = document.adoptedStyleSheets.filter(function (s) { return s !== window.__mine; }); return '{}';", in: Self.worldA)
            let afterRemove = await call(wv, computed, in: .page)
            record(q, v.label, "A removes its own sheet: A's rule goes, B's and the page's stay", yn(afterRemove["bg"] as? String != "rgb(1, 2, 3)" && afterRemove["color"] as? String == "rgb(4, 5, 6)" && afterRemove["border"] as? String == "5px"), json(afterRemove))
            _ = await call(wv, "document.adoptedStyleSheets = document.adoptedStyleSheets.filter(function (s) { return s !== window.__mine; }); return '{}';", in: Self.worldB)
            let afterBoth = await call(wv, computed, in: .page)
            record(q, v.label, "B removes its own: only the page's sheet is left", yn(afterBoth["color"] as? String != "rgb(4, 5, 6)" && afterBoth["border"] as? String == "5px" && (afterBoth["len"] as? Int) == 1), json(afterBoth))
            teardown(wv)
        }
    }

    // MARK: Q4 errors

    func testQ4Errors() async throws {
        let q = "Q4 Errors"
        func listeners(_ tag: String) -> String { // tag labels the world only (a `//# sourceURL` pragma was tried and made no difference)
            """
            (function () {
              function send(k, e) {
                var err = e.error !== undefined ? e.error : e.reason;
                window.webkit.messageHandlers.gm.postMessage({ kind: k, msg: String(e.message || (err && err.message) || err),
                  stack: String((err && err.stack) || ''), filename: String(e.filename || ''),
                  inst: err instanceof Error, ownPromise: e.promise ? e.promise instanceof Promise : null, errType: typeof err });
              }
              window.addEventListener('error', function (e) { send('error', e); });
              window.addEventListener('unhandledrejection', function (e) { send('rejection', e); });
              // Attribution by wrapping, world-locally: callbacks the script registers report their own throw.
              function wrap(f) {
                if (typeof f !== 'function') return f;
                return function () { try { return f.apply(this, arguments); } catch (err) { send('wrapped', { message: err.message, error: err }); throw err; } };
              }
              ['setTimeout', 'setInterval'].forEach(function (n) { var o = window[n]; window[n] = function (f) { var a = Array.prototype.slice.call(arguments); a[0] = wrap(f); return o.apply(this, a); }; });
              var oa = EventTarget.prototype.addEventListener;
              EventTarget.prototype.addEventListener = function (t, f, o) { return oa.call(this, t, wrap(f), o); };
              window.__fire = function (t) {
                setTimeout(function () { throw new Error(t + '-timer'); }, 10);
                var el = document.getElementById('ctl'); el.addEventListener('click', function () { throw new Error(t + '-click'); }); el.click();
                Promise.reject(new Error(t + '-reject'));
              };
            })();
            """
        }
        for v in Variant.all {
            let hA = ScriptHandler(id: "A", expectedWorld: Self.worldA), hB = ScriptHandler(id: "B", expectedWorld: Self.worldB)
            let wv = try await makeView { u in
                u.addScriptMessageHandler(hA, contentWorld: Self.worldA, name: "gm")
                u.addScriptMessageHandler(hB, contentWorld: Self.worldB, name: "gm")
                u.addUserScript(WKUserScript(source: listeners("A"), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.worldA))
                u.addUserScript(WKUserScript(source: listeners("B"), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.worldB))
            }
            try await navigate(wv, v)
            _ = await call(wv, "window.__fire('A'); return '{}';", in: Self.worldA)
            _ = await call(wv, "window.__fire('B'); return '{}';", in: Self.worldB)
            _ = await call(wv, """
                setTimeout(function () { throw new Error('PAGE-timer'); }, 10);
                var el = document.getElementById('ctl'); el.addEventListener('click', function () { throw new Error('PAGE-click'); }); el.click();
                Promise.reject(new Error('PAGE-reject'));
                return '{}';
                """, in: .page)
            // A click that A's own world dispatches on an element whose handler is page code.
            _ = await call(wv, "document.getElementById('ctl2').click(); return '{}';", in: Self.worldA)
            await pause(400)
            let a = hA.received.filter { $0["kind"] as? String != "wrapped" }.map { "\($0["kind"] ?? "?"):\($0["msg"] ?? "?")" }.sorted()
            let b = hB.received.filter { $0["kind"] as? String != "wrapped" }.map { "\($0["kind"] ?? "?"):\($0["msg"] ?? "?")" }.sorted()
            func only(_ list: [String], _ tag: String) -> Bool { !list.isEmpty && list.allSatisfy { $0.contains("\(tag)-") } }
            func has(_ list: [String], _ tag: String) -> (Bool, Bool, Bool) {
                (list.contains { $0.hasSuffix("\(tag)-click") }, list.contains { $0.hasSuffix("\(tag)-timer") }, list.contains { $0.hasSuffix("\(tag)-reject") })
            }
            let ha = has(a, "A"), hb = has(b, "B")
            record(q, v.label, "plain window listener: A sees its own late errors (timer, event handler, rejection) with their messages", yn(ha.0 && ha.1 && ha.2), "A received \(a)")
            record(q, v.label, "plain window listener: B sees its own late errors (timer, event handler, rejection) with their messages", yn(hb.0 && hb.1 && hb.2), "B received \(b)")
            record(q, v.label, "plain window listener: A sees nothing from B or from the page", yn(only(a, "A")), "A received \(a)")
            record(q, v.label, "plain window listener: B sees nothing from A or from the page", yn(only(b, "B")), "B received \(b)")
            func kinds(_ h: ScriptHandler, _ kind: String, own: String, ownPromiseOnly: Bool = false) -> (own: [String], foreign: [String]) {
                let msgs = h.received.filter { $0["kind"] as? String == kind && (!ownPromiseOnly || $0["ownPromise"] as? Bool == true) }.map { $0["msg"] as? String ?? "?" }
                return (msgs.filter { $0.contains("\(own)-") }.sorted(), msgs.filter { !$0.contains("\(own)-") }.sorted())
            }
            let wA = kinds(hA, "wrapped", own: "A"), wB = kinds(hB, "wrapped", own: "B")
            let stackOK = hA.received.filter { $0["kind"] as? String == "wrapped" }.allSatisfy { !(($0["stack"] as? String) ?? "").isEmpty }
            record(q, v.label, "world-local wrappers (setTimeout, addEventListener) report exactly the world's own timer and click errors, with a stack",
                   yn(Set(wA.own).count == 2 && wA.foreign.isEmpty && Set(wB.own).count == 2 && wB.foreign.isEmpty && stackOK), "A own \(wA.own) foreign \(wA.foreign); B own \(wB.own) foreign \(wB.foreign); stacks present \(stackOK)")
            let rA = kinds(hA, "rejection", own: "A", ownPromiseOnly: true), rB = kinds(hB, "rejection", own: "B", ownPromiseOnly: true)
            record(q, v.label, "an unhandledrejection whose `promise instanceof Promise` is the world's own is exactly the world's own rejection",
                   yn(rA.own == ["A-reject"] && rA.foreign.isEmpty && rB.own == ["B-reject"] && rB.foreign.isEmpty), "A own \(rA.own) foreign \(rA.foreign); B own \(rB.own) foreign \(rB.foreign)")
            let rawA = hA.received.filter { $0["kind"] as? String == "error" }.map { $0["msg"] as? String ?? "?" }
            record(q, v.label, "the plain window `error` event, from script code in the world, names its script", yn(rawA.contains { $0.contains("A-") }), "A's raw error events: \(rawA)")
            record(q, v.label, "samples of what a listener gets (kind, errType, inst, filename, stack head)", "info",
                   json(hA.received.map { "\($0["msg"] ?? "?") \($0["kind"] ?? "?") \($0["errType"] ?? "?") inst=\($0["inst"] ?? "?") file=\($0["filename"] ?? "") stack=\(String(($0["stack"] as? String ?? "").prefix(50)))" }))
            teardown(wv)
        }
    }

    // MARK: Q5 document start

    func testQ5DocumentStartValues() async throws {
        let q = "Q5 Document start"
        for v in Variant.all {
            for big in [false, true] {
                let h = ScriptHandler(id: "A", expectedWorld: Self.worldA)
                let wv = try await makeView { u in u.addScriptMessageHandler(h, contentWorld: Self.worldA, name: "gm") }
                func source(_ vals: [String: Any]) -> String {
                    """
                    (function () {
                      var vals = \(json(vals));
                      var d = document.documentElement;
                      window.__r = { readyState: document.readyState, value: vals.k === undefined ? null : (vals.k.length > 20 ? vals.k.length : vals.k),
                                     pageScriptRanBefore: !!(d && d.dataset.ctlInlineNonce), docEl: !!d };
                      window.webkit.messageHandlers.gm.postMessage({ op: 'set', k: 'k', v: \(big ? "'x'.repeat(256 * 1024)" : "'v1'") });
                    })();
                    """
                }
                let ucc = wv.configuration.userContentController
                ucc.addUserScript(WKUserScript(source: source([:]), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.worldA))
                try await navigate(wv, v)
                await pause(150)
                let first = await call(wv, "return JSON.stringify(window.__r);", in: Self.worldA)
                let stored = h.values["k"] as? String
                ucc.removeAllUserScripts()
                ucc.addUserScript(WKUserScript(source: source(["k": stored ?? ""]), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.worldA))
                try await navigate(wv, v)
                let second = await call(wv, "return JSON.stringify(window.__r);", in: Self.worldA)
                let expect: Any = big ? 256 * 1024 : "v1"
                let ok = first["value"] is NSNull && "\(second["value"] ?? "")" == "\(expect)" && second["pageScriptRanBefore"] as? Bool == false
                record(q, v.label, "\(big ? "256 KB" : "small") value set on load 1 is read synchronously at document start on load 2, before any page script",
                       yn(ok), "load 1 read \(json(first)); load 2 read \(json(second)); stored \(stored?.count ?? -1) chars")
                teardown(wv)
            }
        }
    }

    // MARK: Q6 live apply

    func testQ6LiveApply() async throws {
        let q = "Q6 Live apply"
        let base = """
        (function () {
          window.__state = { loaded: true };
          window.addEventListener('error', function (e) { window.webkit.messageHandlers.gm.postMessage({ kind: 'error', msg: String(e.message) }); });
        })();
        """
        let good = """
        const sh = new CSSStyleSheet(); sh.replaceSync('#target { outline: 3px solid rgb(9, 9, 9); }');
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sh];
        window.__undo = function () { document.adoptedStyleSheets = document.adoptedStyleSheets.filter(function (x) { return x !== sh; }); };
        return JSON.stringify({sawBaseState: !!(window.__state && window.__state.loaded)});
        """
        let outline = "return JSON.stringify({o: getComputedStyle(document.getElementById('target')).outlineStyle});"
        for v in Variant.all {
            let h = ScriptHandler(id: "A", expectedWorld: Self.worldA)
            let wv = try await makeView { u in
                u.addScriptMessageHandler(h, contentWorld: Self.worldA, name: "gm")
                u.addUserScript(WKUserScript(source: base, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.worldA))
            }
            try await navigate(wv, v)
            let applied = await call(wv, good, in: Self.worldA)
            let on = await call(wv, outline, in: .page)
            record(q, v.label, "callAsyncJavaScript runs a candidate in script A's world on the loaded page, sees the world's state, and the style applies",
                   yn(applied["sawBaseState"] as? Bool == true && on["o"] as? String == "solid"), "candidate \(json(applied)); page outline \(json(on))")
            let undoResult = await call(wv, "window.__undo(); return '{}';", in: Self.worldA)
            let off = await call(wv, outline, in: .page)
            record(q, v.label, "Undo, a second call in the same world, removes it", yn(off["o"] as? String != "solid"), "undo call \(json(undoResult)); page outline \(json(off))")
            let bad = await call(wv, "throw new Error('candidate-sync');", in: Self.worldA)
            let badAsync = await call(wv, "throw new Error('candidate-sync-2');", in: Self.worldA)
            record(q, v.label, "a synchronous throw in a candidate comes back to Swift (verify before saving)", yn("\(bad)".contains("candidate-sync")), "\(bad); \(badAsync)")
            _ = await call(wv, "setTimeout(function () { throw new Error('candidate-late'); }, 10); return '{}';", in: Self.worldA)
            await pause(300)
            let late = h.received.map { "\($0["msg"] ?? "?")" }
            record(q, v.label, "a late throw in a candidate reaches the world's error listener", yn(late.contains { $0.contains("candidate-late") }), "handler received \(late)")
            let wrongWorld = await call(wv, "return JSON.stringify({s: typeof window.__state});", in: Self.worldB)
            record(q, v.label, "script B's world does not see A's state", yn(wrongWorld["s"] as? String == "undefined"), json(wrongWorld))
            teardown(wv)
        }
    }

    // MARK: Q7 shared world

    func testQ7SharedWorld() async throws {
        let q = "Q7 Shared world"
        // A third-party script in WukongAgent, at document start, wraps the handler the way a malicious script would.
        let attacks: [(String, String)] = [
            ("wrap the instance's postMessage", "var h = window.webkit.messageHandlers.wukongAgent; var o = h.postMessage; h.postMessage = function (m) { (window.__caught = window.__caught || []).push(m); return o.apply(this, arguments); };"),
            ("wrap the prototype's postMessage", "var h = window.webkit.messageHandlers.wukongAgent; var p = Object.getPrototypeOf(h); var o = p.postMessage; p.postMessage = function (m) { (window.__caught = window.__caught || []).push(m); return o.apply(this, arguments); };"),
            ("replace messageHandlers.wukongAgent", "var mh = window.webkit.messageHandlers; var h = mh.wukongAgent; var o = h.postMessage.bind(h); Object.defineProperty(mh, 'wukongAgent', { value: { postMessage: function (m) { (window.__caught = window.__caught || []).push(m); return o(m); } }, configurable: true });"),
            ("keep a reference to window.webkit and wrap later", "var w = window.webkit; setTimeout(function () { var h = w.messageHandlers.wukongAgent; var o = h.postMessage; h.postMessage = function (m) { (window.__caught = window.__caught || []).push(m); return o.apply(this, arguments); }; }, 0);"),
        ]
        // What the app's run_js helper does: post a call token through the handler and get a reply.
        let runJS = "var r = await window.webkit.messageHandlers.wukongAgent.postMessage({ token: 'SECRET-CALL-TOKEN', op: 'fetch' }); return JSON.stringify({reply: r});"
        for (name, attack) in attacks {
            for v in [Variant.all[0], Variant.all[1], Variant.all[3]] {
                let hAgent = ScriptHandler(id: "agent", expectedWorld: Self.agentWorld)
                let wv = try await makeView { u in
                    u.addScriptMessageHandler(hAgent, contentWorld: Self.agentWorld, name: "wukongAgent")
                    u.addUserScript(WKUserScript(source: "(function(){\(attack)})();", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.agentWorld))
                }
                try await navigate(wv, v)
                let r = await call(wv, runJS, in: Self.agentWorld)
                await pause(100)
                let caught = await call(wv, "return JSON.stringify({caught: window.__caught || []});", in: Self.agentWorld)
                let leaked = "\(caught)".contains("SECRET-CALL-TOKEN")
                record(q, v.label, "a script in WukongAgent can \(name) and catch the run_js call token", yn(leaked), "run_js reply \(json(r)); caught \(json(caught)); native handler got \(hAgent.received.count) message(s)")
                teardown(wv)
            }
        }
    }
}
