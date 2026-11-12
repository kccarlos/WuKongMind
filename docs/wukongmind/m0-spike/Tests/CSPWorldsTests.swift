import UIKit
import WebKit
import XCTest

// M0 spike: does a page's CSP affect what the app injects, and how do the page world and an isolated
// WKContentWorld behave? Every result comes from a real WKWebView load of a fixture page served by
// SpikeServer, so CSP headers are real. Results go to $SPIKE_OUT/results.{json,md} (run.sh sets it).

/// Reply handler used for the bridge-isolation checks. Echoes the body and the world it came from.
final class EchoHandler: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        replyHandler(["echo": message.body, "world": message.world.name ?? "page"], nil)
    }
}

final class NavigationWaiter: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    private func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}

struct Row: Codable {
    let variant: String
    let testCase: String
    let world: String
    let outcome: String
    let detail: String
    let violations: [String]
}

struct Probe {
    enum Kind { case callAsync, callAsyncObject, evaluate }
    enum ServerCheck { case mainOrigin, otherOrigin }
    let name: String
    let kind: Kind
    let body: String
    var dynCheck = false
    var server: ServerCheck?
    var domCheck = false
    var globalCheck = false
}

@MainActor
final class CSPWorldsTests: XCTestCase {
    static let iso = WKContentWorld.world(name: "wukong-iso")
    static let probeWorld = WKContentWorld.world(name: "m0-probe")
    let worlds: [(String, WKContentWorld)] = [("page", .page), ("isolated", CSPWorldsTests.iso)]

    var main: SpikeServer!
    var other: SpikeServer!
    var rows: [Row] = []
    var waiter = NavigationWaiter()
    var markerCounter = 0

    // MARK: Servers

    func startServers() async throws {
        main = try SpikeServer(name: "main") { req in
            switch req.path {
            case "/page":
                let v = Variant.all.first { $0.policy.rawValue == req.query["csp"] && $0.via == req.query["via"] } ?? Variant.all[0]
                var headers: [String: String] = [:]
                if v.via == "header", let csp = v.cspText { headers["Content-Security-Policy"] = csp + "; report-uri /report" }
                return .text(Fixtures.page(v), type: "text/html; charset=utf-8", headers: headers)
            case "/page.js": return .text(Fixtures.pageJS, type: "text/javascript")
            case "/page.css": return .text(Fixtures.pageCSS, type: "text/css")
            case "/ext.js": return .text(Fixtures.extJS(marker: req.query["m"] ?? "x"), type: "text/javascript")
            case "/api/own": return .text("{\"ok\":true}", type: "application/json")
            case "/report": return .text("")
            default: return SpikeServer.Response(status: 404)
            }
        }
        other = try SpikeServer(name: "other") { req in
            let cors = ["Access-Control-Allow-Origin": "*"]
            switch req.path {
            case "/ext.js": return .text(Fixtures.extJS(marker: req.query["m"] ?? "x"), type: "text/javascript")
            case "/cors/data": return .text("{\"other\":true}", type: "application/json", headers: cors)
            case "/nocors/data": return .text("{\"other\":true}", type: "application/json")
            case "/lib.js": return .text("window.__lib = '\(req.query["id"] ?? "")';", type: "text/javascript", headers: cors)
            default: return SpikeServer.Response(status: 404)
            }
        }
        try await main.start()
        try await other.start()
    }

    // MARK: Web view plumbing

    func hostWindow() async throws -> UIWindow {
        for _ in 0 ..< 50 {
            if let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first {
                return w
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "no host window"])
    }

    func load(_ v: Variant) async throws -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let ucc = cfg.userContentController
        ucc.addUserScript(WKUserScript(source: Fixtures.violationCollector, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true, in: Self.probeWorld))
        for (name, world) in worlds {
            ucc.addUserScript(WKUserScript(source: Fixtures.captureHook, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
            ucc.addUserScript(WKUserScript(source: Fixtures.userScript(when: "start", world: name), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
            ucc.addUserScript(WKUserScript(source: Fixtures.userScript(when: "end", world: name), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        }
        ucc.addScriptMessageHandler(EchoHandler(), contentWorld: Self.iso, name: "agent")
        ucc.addScriptMessageHandler(EchoHandler(), contentWorld: .page, name: "pageCtl")
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: cfg)
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        waiter = NavigationWaiter()
        wv.navigationDelegate = waiter
        try await hostWindow().addSubview(wv)
        let url = URL(string: "\(main.origin)/page?csp=\(v.policy.rawValue)&via=\(v.via)")!
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiter.continuation = c
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func teardown(_ wv: WKWebView) {
        wv.configuration.userContentController.removeAllScriptMessageHandlers()
        wv.removeFromSuperview()
    }

    func eval(_ wv: WKWebView, _ js: String, in world: WKContentWorld) async -> String {
        do {
            let v: Any? = try await wv.evaluateJavaScript(js, in: nil, contentWorld: world)
            return v.map { "\($0)" } ?? "nil"
        } catch {
            return "ERROR: \(Self.describe(error))"
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        let msg = ns.userInfo["WKJavaScriptExceptionMessage"] as? String
        return "\(ns.domain) \(ns.code) \(msg ?? ns.localizedDescription)"
    }

    func violations(_ wv: WKWebView) async -> [[String: Any]] {
        let s = await eval(wv, "JSON.stringify(window.__viol || [])", in: Self.probeWorld)
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [[String: Any]] ?? []
    }

    static func summarize(_ v: [String: Any]) -> String {
        let uri = (v["uri"] as? String).map { $0.isEmpty ? "" : " \($0)" } ?? ""
        let sample = (v["sample"] as? String).map { $0.isEmpty ? "" : " \"\($0)\"" } ?? ""
        return "\(v["dir"] ?? "?")\(uri)\(sample)"
    }

    func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func record(_ v: Variant, _ testCase: String, _ world: String, _ outcome: String, _ detail: String, _ viol: [String] = []) {
        rows.append(Row(variant: v.label, testCase: testCase, world: world, outcome: outcome, detail: detail, violations: viol))
    }

    // MARK: Probes

    static let probes: [Probe] = [
        Probe(name: "evaluateJavaScript", kind: .evaluate, body: "JSON.stringify({o: 'works', d: 'title ' + document.title})"),
        Probe(name: "callAsyncJavaScript await + JSON string", kind: .callAsync, body: """
            await new Promise(r => setTimeout(r, 20));
            return {o: 'works', d: JSON.stringify({n: 1, arr: [1, 'a'], nested: {t: true}})};
            """),
        Probe(name: "callAsyncJavaScript await + object return", kind: .callAsyncObject, body: """
            await new Promise(r => setTimeout(r, 20));
            return {n: 1, arr: [1, 'a'], nested: {t: true}};
            """),
        Probe(name: "eval in injected code", kind: .callAsync, body: """
            try { return {o: 'works', d: 'eval -> ' + eval('1+1')}; } catch (e) { return {o: 'blocked', d: e.name + ': ' + e.message}; }
            """),
        Probe(name: "new Function in injected code", kind: .callAsync, body: """
            try { return {o: 'works', d: 'fn -> ' + new Function('return 7')()}; } catch (e) { return {o: 'blocked', d: e.name + ': ' + e.message}; }
            """),
        Probe(name: "DOM read + write", kind: .callAsync, body: """
            const t = document.getElementById('target'); t.dataset.writtenBy = w;
            return {o: 'works', d: 'read ' + JSON.stringify(t.textContent)};
            """, domCheck: true),
        Probe(name: "page JS global visible", kind: .callAsync, body: """
            const before = typeof window.pageGlobal; window.pageGlobal = 99;
            return {o: before === 'number' ? 'visible' : 'not visible', d: 'typeof pageGlobal = ' + before};
            """, globalCheck: true),
        Probe(name: "CSS via <style> element", kind: .callAsync, body: """
            const t = document.getElementById('target');
            const s = document.createElement('style'); s.textContent = '#target { color: rgb(10, 20, 30); }';
            document.head.appendChild(s); await new Promise(r => setTimeout(r, 50));
            const c = getComputedStyle(t).color;
            return {o: c === 'rgb(10, 20, 30)' ? 'works' : 'blocked', d: 'computed color ' + c};
            """),
        Probe(name: "CSS via adoptedStyleSheets", kind: .callAsync, body: """
            const t = document.getElementById('target');
            const s = new CSSStyleSheet(); s.replaceSync('#target { background-color: rgb(40, 50, 60); }');
            document.adoptedStyleSheets = [...document.adoptedStyleSheets, s]; await new Promise(r => setTimeout(r, 50));
            const c = getComputedStyle(t).backgroundColor;
            return {o: c === 'rgb(40, 50, 60)' ? 'works' : 'blocked', d: 'computed background ' + c};
            """),
        Probe(name: "CSS via setAttribute('style')", kind: .callAsync, body: """
            const t = document.getElementById('target'); t.setAttribute('style', 'opacity: 0.5');
            await new Promise(r => setTimeout(r, 50)); const c = getComputedStyle(t).opacity;
            return {o: c === '0.5' ? 'works' : 'blocked', d: 'computed opacity ' + c};
            """),
        Probe(name: "CSS via element.style (CSSOM)", kind: .callAsync, body: """
            const t = document.getElementById('target'); t.style.letterSpacing = '3px';
            await new Promise(r => setTimeout(r, 50)); const c = getComputedStyle(t).letterSpacing;
            return {o: c === '3px' ? 'works' : 'blocked', d: 'computed letter-spacing ' + c};
            """),
        Probe(name: "dynamic <script> inline", kind: .callAsync, body: dynInline(nonce: false), dynCheck: true),
        Probe(name: "dynamic <script> inline + copied nonce", kind: .callAsync, body: dynInline(nonce: true), dynCheck: true),
        Probe(name: "dynamic <script src> same origin", kind: .callAsync, body: dynSrc(origin: "location.origin", nonce: false), dynCheck: true, server: .mainOrigin),
        Probe(name: "dynamic <script src> same origin + copied nonce", kind: .callAsync, body: dynSrc(origin: "location.origin", nonce: true), dynCheck: true, server: .mainOrigin),
        Probe(name: "dynamic <script src> other origin", kind: .callAsync, body: dynSrc(origin: "other", nonce: false), dynCheck: true, server: .otherOrigin),
        Probe(name: "dynamic <script src> other origin + copied nonce", kind: .callAsync, body: dynSrc(origin: "other", nonce: true), dynCheck: true, server: .otherOrigin),
        Probe(name: "fetch same origin", kind: .callAsync, body: fetchBody(url: "location.origin + '/api/own?id=' + id"), server: .mainOrigin),
        Probe(name: "fetch other origin (CORS allowed)", kind: .callAsync, body: fetchBody(url: "other + '/cors/data?id=' + id"), server: .otherOrigin),
        Probe(name: "fetch other origin (no CORS header)", kind: .callAsync, body: fetchBody(url: "other + '/nocors/data?id=' + id"), server: .otherOrigin),
        Probe(name: "workaround: fetch other-origin script text + indirect eval", kind: .callAsync, body: """
            try {
              const r = await fetch(other + '/lib.js?id=' + id); const src = await r.text();
              (0, eval)(src);
              return {o: window.__lib === id ? 'works' : 'blocked', d: 'status ' + r.status + ', library global set in this world: ' + (window.__lib === id)};
            } catch (e) { return {o: 'blocked', d: e.name + ': ' + e.message}; }
            """, server: .otherOrigin),
        Probe(name: "XHR other origin (CORS allowed)", kind: .callAsync, body: """
            return await new Promise(res => {
              try {
                const x = new XMLHttpRequest(); x.open('GET', other + '/cors/data?id=' + id);
                x.onload = () => res({o: 'works', d: 'status ' + x.status});
                x.onerror = () => res({o: 'blocked', d: 'xhr error event'});
                x.send();
              } catch (e) { res({o: 'blocked', d: e.name + ': ' + e.message}); }
            });
            """, server: .otherOrigin),
        Probe(name: "message handlers seen", kind: .callAsync, body: """
            const wk = window.webkit, mh = wk && wk.messageHandlers;
            const info = {webkit: typeof wk, messageHandlers: typeof mh,
                          agent: mh ? typeof mh.agent : 'n/a', pageCtl: mh ? typeof mh.pageCtl : 'n/a'};
            let replies = {};
            for (const n of ['agent', 'pageCtl']) {
              if (mh && mh[n]) {
                try { replies[n] = await mh[n].postMessage({from: w}); } catch (e) { replies[n] = 'threw ' + e.message; }
              }
            }
            return {o: info.agent === 'object' ? 'agent visible' : 'agent not visible',
                    d: JSON.stringify(info) + ' replies=' + JSON.stringify(replies)};
            """),
    ]

    static func dynInline(nonce: Bool) -> String {
        """
        const s = document.createElement('script');
        \(nonce ? "const n = (document.querySelector('script[nonce]') || {}).nonce || ''; s.nonce = n;" : "const n = null;")
        s.textContent = "document.documentElement.dataset['" + id + "'] = 'ran'; (window.__dyn = window.__dyn || {})['" + id + "'] = 'set';";
        document.head.appendChild(s); await new Promise(r => setTimeout(r, 100));
        const ran = document.documentElement.dataset[id] === 'ran';
        return {o: ran ? 'works' : 'blocked', d: n === null ? '' : ('nonce read: ' + (n ? 'yes' : 'empty'))};
        """
    }

    static func dynSrc(origin: String, nonce: Bool) -> String {
        """
        const s = document.createElement('script');
        \(nonce ? "const n = (document.querySelector('script[nonce]') || {}).nonce || ''; s.nonce = n;" : "const n = null;")
        s.src = \(origin) + '/ext.js?m=' + id + '&id=' + id;
        const done = new Promise(r => { s.onload = () => r('load'); s.onerror = () => r('error'); });
        document.head.appendChild(s);
        const ev = await Promise.race([done, new Promise(r => setTimeout(() => r('no event'), 1500))]);
        await new Promise(r => setTimeout(r, 50));
        const ran = document.documentElement.dataset[id] === 'ran';
        return {o: ran ? 'works' : 'blocked', d: 'event ' + ev + (n === null ? '' : ('; nonce read: ' + (n ? 'yes' : 'empty')))};
        """
    }

    static func fetchBody(url: String) -> String {
        """
        try { const r = await fetch(\(url)); const t = await r.text(); return {o: 'works', d: 'status ' + r.status + ' ' + t}; }
        catch (e) { return {o: 'blocked', d: e.name + ': ' + e.message}; }
        """
    }

    func run(_ probe: Probe, in world: WKContentWorld, worldName: String, id: String, wv: WKWebView) async -> (String, String) {
        switch probe.kind {
        case .evaluate:
            let s = await eval(wv, probe.body, in: world)
            return Self.parseResult(s)
        case .callAsync, .callAsyncObject:
            let wrapped: String
            if probe.kind == .callAsync {
                wrapped = """
                const __timeout = new Promise(r => setTimeout(() => r({o: 'error', d: 'timeout 3s'}), 3000));
                const __res = await Promise.race([__timeout, (async () => {
                  try { \(probe.body) } catch (e) { return {o: 'error', d: 'threw ' + e.name + ': ' + e.message}; }
                })()]);
                return JSON.stringify(__res);
                """
            } else {
                wrapped = probe.body
            }
            do {
                let v: Any? = try await wv.callAsyncJavaScript(wrapped, arguments: ["id": id, "other": other.origin, "w": worldName],
                                                               in: nil, contentWorld: world)
                if probe.kind == .callAsyncObject {
                    guard let dict = v as? [String: Any] else { return ("error", "returned \(type(of: v)): \(String(describing: v))") }
                    let n = dict["n"] as? Int, arr = dict["arr"] as? [Any], nested = dict["nested"] as? [String: Any]
                    let ok = n == 1 && arr?.count == 2 && (nested?["t"] as? Bool) == true
                    return (ok ? "works" : "error", "Swift got [String: Any] n=\(n.map(String.init) ?? "nil") arr=\(arr?.count ?? -1) items nested.t=\(nested?["t"] ?? "nil")")
                }
                return Self.parseResult(v as? String ?? "non-string \(String(describing: v))")
            } catch {
                return ("error", "callAsyncJavaScript threw: \(Self.describe(error))")
            }
        }
    }

    static func parseResult(_ s: String) -> (String, String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { return ("error", s) }
        return (obj["o"] as? String ?? "error", obj["d"] as? String ?? "")
    }

    // MARK: Test

    func testCSPAndExecutionWorlds() async throws {
        try await startServers()
        defer { main.stop(); other.stop() }

        for v in Variant.all {
            try await baseline(v)
            for probe in Self.probes {
                for (worldName, world) in worlds {
                    markerCounter += 1
                    let id = "m\(markerCounter)"
                    let wv = try await load(v)
                    let before = await violations(wv).count
                    var (outcome, detail) = await run(probe, in: world, worldName: worldName, id: id, wv: wv)
                    await sleep(150)
                    if probe.dynCheck {
                        let inPage = await eval(wv, "String(!!(window.__dyn && window.__dyn['\(id)']))", in: .page)
                        let inIso = await eval(wv, "String(!!(window.__dyn && window.__dyn['\(id)']))", in: Self.iso)
                        detail += (detail.isEmpty ? "" : "; ") + "script global set in page world: \(inPage), isolated world: \(inIso)"
                    }
                    if let server = probe.server {
                        let s = server == .mainOrigin ? main! : other!
                        detail += "; server saw request: \(s.received(id: id) ? "yes" : "no")"
                        if !probe.dynCheck {
                            let cap = await eval(wv, "String((window.__cap || []).some(r => r.u.indexOf('id=\(id)') >= 0))", in: .page)
                            detail += "; page-world capture hook saw it: \(cap)"
                        }
                    }
                    if probe.domCheck {
                        let otherWorld = worldName == "page" ? Self.iso : WKContentWorld.page
                        let seen = await eval(wv, "String(document.getElementById('target').dataset.writtenBy)", in: otherWorld)
                        detail += "; write seen from the other world: \(seen)"
                    }
                    if probe.globalCheck {
                        let pageValue = await eval(wv, "String(window.pageGlobal)", in: .page)
                        detail += "; page world now reads pageGlobal = \(pageValue)"
                    }
                    let viol = await violations(wv).dropFirst(before).map(Self.summarize)
                    record(v, probe.name, worldName, outcome, detail, Array(viol))
                    teardown(wv)
                }
            }
        }

        await sleep(500) // let report-uri POSTs arrive
        for v in Variant.all where v.via == "header" {
            let tag = "csp=\(v.policy.rawValue)&via=header"
            let reports = main.log.filter { $0.path == "/report" && String(decoding: $0.body, as: UTF8.self).contains(tag) }
            var directives: [String: Int] = [:]
            for r in reports {
                let obj = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
                let rep = obj?["csp-report"] as? [String: Any]
                let key = "\(rep?["effective-directive"] ?? rep?["violated-directive"] ?? "?") \(rep?["blocked-uri"] ?? "")"
                directives[key, default: 0] += 1
            }
            let detail = directives.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: "; ")
            record(v, "report-uri reports received (whole run)", "-", "\(reports.count)", detail)
        }

        try writeResults()
    }

    /// One load per variant without probes: page controls, the user scripts, the capture hooks, load-time violations.
    func baseline(_ v: Variant) async throws {
        let wv = try await load(v)
        defer { teardown(wv) }
        for _ in 0 ..< 30 { // wait for the page's own late fetch
            if await eval(wv, "String(document.documentElement.dataset.ownDone)", in: .page) == "1" { break }
            await sleep(100)
        }
        await sleep(200)
        let ds = { (k: String) async -> String in await self.eval(wv, "String(document.documentElement.dataset.\(k))", in: .page) }
        let ctlPlain = await ds("ctlInlinePlain"), ctlNonce = await ds("ctlInlineNonce")
        let ctlJs = await ds("ctlPageJs"), ctlEval = await ds("ctlPageEval")
        let ctlStyle = await eval(wv, "getComputedStyle(document.getElementById('ctl')).color", in: .page)
        let ctlSheet = await eval(wv, "getComputedStyle(document.getElementById('ctl2')).color", in: .page)
        let ran = { (s: String) in s == "ran" ? "runs" : "blocked" }
        record(v, "Control: page inline <script> without nonce", "-", ran(ctlPlain), "")
        record(v, "Control: page inline <script> with nonce", "-", ran(ctlNonce), "")
        record(v, "Control: page same-origin <script src> with nonce", "-", ran(ctlJs), "")
        record(v, "Control: page eval", "-", ctlEval == "2" ? "runs" : "blocked", ctlEval)
        record(v, "Control: page inline <style>", "-", ctlStyle == "rgb(1, 2, 3)" ? "applies" : "blocked", ctlStyle)
        record(v, "Control: page same-origin stylesheet", "-", ctlSheet == "rgb(4, 5, 6)" ? "applies" : "blocked", ctlSheet)

        // Controls prove the fixture really enforces the policy; if these fail, the matrix means nothing.
        XCTAssertEqual(ctlJs, "ran", "\(v.label): page.js must run")
        XCTAssertEqual(ctlSheet, "rgb(4, 5, 6)", "\(v.label): same-origin stylesheet must apply")
        if v.policy == .none {
            XCTAssertEqual(ctlPlain, "ran"); XCTAssertEqual(ctlEval, "2"); XCTAssertEqual(ctlStyle, "rgb(1, 2, 3)")
        } else {
            XCTAssertNotEqual(ctlPlain, "ran", "\(v.label): plain inline script must be blocked")
            XCTAssertTrue(ctlEval.hasPrefix("blocked"), "\(v.label): page eval must be blocked, got \(ctlEval)")
            XCTAssertNotEqual(ctlStyle, "rgb(1, 2, 3)", "\(v.label): inline style must be blocked")
        }

        for (name, world) in worlds {
            for when in ["start", "end"] {
                let s = await eval(wv, "JSON.stringify(window.__us_\(when) || null)", in: world)
                let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
                let label = "WKUserScript at document \(when)"
                guard let obj else { record(v, "\(label): runs", name, "did not run", s); continue }
                record(v, "\(label): runs", name, "runs", "readyState \(obj["readyState"] ?? "?"); typeof pageGlobal \(obj["pageGlobal"] ?? "?")")
                let e = "\(obj["eval"] ?? "?")", f = "\(obj["newFunction"] ?? "?")"
                record(v, "\(label): eval", name, e == "5" ? "works" : "blocked", e)
                record(v, "\(label): new Function", name, f == "7" ? "works" : "blocked", f)
            }
            let cap = await eval(wv, "JSON.stringify(window.__cap || null)", in: world)
            let wanted = ["fetch-parse", "xhr-parse", "fetch-load"]
            let seen = wanted.filter { cap.contains("via=\($0)") }
            let outcome = seen.count == wanted.count ? "sees all" : (seen.isEmpty ? "sees none" : "partial")
            record(v, "Capture hook at start sees page's own fetch/XHR", name, outcome, "seen: \(seen.joined(separator: ", ")); raw \(cap)")
        }
        let viol = await violations(wv).map(Self.summarize)
        record(v, "CSP violations during page load (securitypolicyviolation)", "-", "\(viol.count)", "", viol)
    }

    // MARK: Output

    func writeResults() throws {
        let env = ProcessInfo.processInfo.environment
        let outDir = URL(fileURLWithPath: env["SPIKE_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rows).write(to: outDir.appendingPathComponent("results.json"))

        let labels = Variant.all.map(\.label)
        var keys: [String] = []
        var byKey: [String: [Row]] = [:]
        for r in rows {
            let k = "\(r.testCase)\u{1}\(r.world)"
            if byKey[k] == nil { keys.append(k) }
            byKey[k, default: []].append(r)
        }
        var md = "# M0 spike raw results\n\n"
        md += "Generated by `docs/wukongmind/m0-spike/run.sh` on \(ISO8601DateFormatter().string(from: Date())).\n"
        md += "Runtime: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion), "
        md += "simulator \(env["SIMULATOR_DEVICE_NAME"] ?? "?") (\(env["SIMULATOR_MODEL_IDENTIFIER"] ?? "?")).\n\n"
        md += "## Outcomes\n\n| Case | World | " + labels.joined(separator: " | ") + " |\n"
        md += "|---|---|" + labels.map { _ in "---" }.joined(separator: "|") + "|\n"
        for k in keys {
            let rs = byKey[k]!
            let cells = labels.map { l in rs.first { $0.variant == l }.map { $0.outcome + ($0.violations.isEmpty ? "" : " ⚑") } ?? "" }
            md += "| \(rs[0].testCase) | \(rs[0].world) | " + cells.joined(separator: " | ") + " |\n"
        }
        md += "\n⚑ = at least one `securitypolicyviolation` event fired during that case.\n\n## Details\n\n"
        md += "Identical details across variants are grouped.\n\n"
        for k in keys {
            let rs = byKey[k]!
            var groups: [(String, [String])] = []
            for r in rs {
                let text = r.detail + (r.violations.isEmpty ? "" : " — violations: " + r.violations.joined(separator: " | "))
                if text.isEmpty { continue }
                if let i = groups.firstIndex(where: { $0.0 == text }) { groups[i].1.append(r.variant) } else { groups.append((text, [r.variant])) }
            }
            if groups.isEmpty { continue }
            md += "- **\(rs[0].testCase)** (\(rs[0].world))\n"
            for (text, vs) in groups {
                let safe = text.replacingOccurrences(of: "\n", with: " ")
                md += "  - \(vs.joined(separator: ", ")): \(safe)\n"
            }
        }
        try md.write(to: outDir.appendingPathComponent("results.md"), atomically: true, encoding: .utf8)
        print("M0 spike results written to \(outDir.path)")
    }
}
