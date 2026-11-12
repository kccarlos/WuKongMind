import Foundation

let fixtureNonce = "m0nonce123"

/// One CSP setup for the fixture page: which policy, and whether it arrives as an HTTP header or a `<meta>` tag.
struct Variant {
    enum Policy: String { case none, selfOnly = "self", nonce, strictDynamic = "strict-dynamic" }
    let policy: Policy
    let via: String // "header", "meta" or "-"

    var label: String { policy == .none ? "no CSP" : "\(policy.rawValue) (\(via))" }
    var id: String { "\(policy.rawValue)-\(via)" }

    /// The policy text. `report-uri` is only honoured in the header form (the spec ignores it in `<meta>`).
    var cspText: String? {
        switch policy {
        case .none:
            return nil
        case .selfOnly:
            return "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'"
        case .nonce:
            return "default-src 'self'; script-src 'nonce-\(fixtureNonce)'; style-src 'self'; connect-src 'self'"
        case .strictDynamic:
            return "default-src 'self'; script-src 'nonce-\(fixtureNonce)' 'strict-dynamic'; style-src 'self'; connect-src 'self'"
        }
    }

    static let all: [Variant] = [
        Variant(policy: .none, via: "-"),
        Variant(policy: .selfOnly, via: "header"), Variant(policy: .selfOnly, via: "meta"),
        Variant(policy: .nonce, via: "header"), Variant(policy: .nonce, via: "meta"),
        Variant(policy: .strictDynamic, via: "header"), Variant(policy: .strictDynamic, via: "meta"),
    ]
}

enum Fixtures {
    /// The fixture page. Its own controls prove the CSP is in force: a plain inline script, a nonced inline
    /// script, an inline `<style>`, a same-origin stylesheet and a nonced same-origin external script.
    static func page(_ v: Variant) -> String {
        let meta = (v.via == "meta" ? v.cspText.map { "<meta http-equiv=\"Content-Security-Policy\" content=\"\($0)\">" } : nil) ?? ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>M0 fixture \(v.id)</title>
        \(meta)
        <script nonce="\(fixtureNonce)">document.documentElement.dataset.ctlInlineNonce = 'ran';</script>
        <script>document.documentElement.dataset.ctlInlinePlain = 'ran';</script>
        <style>#ctl { color: rgb(1, 2, 3); }</style>
        <link rel="stylesheet" href="/page.css">
        <script nonce="\(fixtureNonce)" src="/page.js"></script>
        </head><body>
        <div id="ctl">inline style control</div>
        <div id="ctl2">external style control</div>
        <div id="target">target</div>
        </body></html>
        """
    }

    /// The page's own same-origin script (allowed by every policy here). It defines a page global, tries
    /// `eval` as a control and makes the page's own requests that the network-capture hook should see.
    static let pageJS = """
    window.pageGlobal = 42;
    var d = document.documentElement.dataset;
    d.ctlPageJs = 'ran';
    try { d.ctlPageEval = String(eval('1+1')); } catch (e) { d.ctlPageEval = 'blocked: ' + e.name; }
    fetch('/api/own?via=fetch-parse').catch(function () {});
    var x = new XMLHttpRequest(); x.open('GET', '/api/own?via=xhr-parse'); x.send();
    window.addEventListener('load', function () {
      fetch('/api/own?via=fetch-load').then(function (r) { return r.text(); }).then(function () { d.ownDone = '1'; });
    });
    """

    static let pageCSS = "#ctl2 { color: rgb(4, 5, 6); }"

    /// Script served for dynamically created `<script src>` tags. Marks the DOM and a global, so the test can
    /// tell whether it ran and in which world.
    static func extJS(marker: String) -> String {
        """
        document.documentElement.dataset['\(marker)'] = 'ran';
        (window.__dyn = window.__dyn || {})['\(marker)'] = 'set';
        """
    }

    // MARK: Injected user scripts

    /// The WKUserScript under test. Records that it ran, whether eval/new Function work there, and whether it
    /// sees the page global. Stores the record in a world-local global and marks the DOM.
    static func userScript(when: String, world: String) -> String {
        """
        (function () {
          var r = { ran: true, readyState: document.readyState };
          try { r.eval = String(eval('2+3')); } catch (e) { r.eval = 'blocked: ' + e.name + ': ' + e.message; }
          try { r.newFunction = String(new Function('return 7')()); } catch (e) { r.newFunction = 'blocked: ' + e.name + ': ' + e.message; }
          r.pageGlobal = typeof window.pageGlobal;
          window.__us_\(when) = r;
          var el = document.documentElement; if (el) el.setAttribute('data-us-\(when)-\(world)', 'ran');
        })();
        """
    }

    /// Network-capture hook: wraps fetch and XMLHttpRequest in whichever world it is injected into.
    static let captureHook = """
    (function () {
      var cap = window.__cap = [];
      var of = window.fetch;
      window.fetch = function (input, init) {
        var u = (typeof input === 'string') ? input : (input && input.url);
        var rec = { k: 'fetch', u: String(u) }; cap.push(rec);
        return of.apply(this, arguments).then(function (r) { rec.status = r.status; return r; });
      };
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__rec = { k: 'xhr', m: m, u: String(u) }; return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        var x = this, rec = x.__rec;
        if (rec) { cap.push(rec); x.addEventListener('loadend', function () { rec.status = x.status; }); }
        return os.apply(this, arguments);
      };
    })();
    """

    /// Collector in a third "probe" world: records securitypolicyviolation events (they fire on the shared DOM).
    static let violationCollector = """
    window.__viol = [];
    document.addEventListener('securitypolicyviolation', function (e) {
      window.__viol.push({ dir: e.effectiveDirective || e.violatedDirective, uri: e.blockedURI,
                           sample: (e.sample || '').slice(0, 50), disposition: e.disposition });
    }, true);
    """
}
