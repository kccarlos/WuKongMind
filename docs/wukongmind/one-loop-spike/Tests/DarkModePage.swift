import UIKit
import WebKit

/// A WKWebView in the host window that loads a fixture page, injects CSS the way the app's
/// `inject_css` does (a constructed sheet in `adoptedStyleSheets`) and measures the result.
@MainActor
final class DarkModePage: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    private var loaded: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        webView.navigationDelegate = self
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
        window?.addSubview(webView)
    }

    func load(_ html: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.example/"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded?.resume(throwing: error); loaded = nil }

    func inject(_ css: String) async throws {
        _ = try await webView.callAsyncJavaScript(
            "const s = new CSSStyleSheet(); s.replaceSync(css); document.adoptedStyleSheets = [...document.adoptedStyleSheets, s]; return true;",
            arguments: ["css": css], contentWorld: .page)
    }

    /// A short read_page-like structure: tag, id and classes, and the start of the text.
    func structure() async throws -> String {
        let script = """
        return [...document.body.querySelectorAll('*')].slice(0, 80).map(e => {
          const sel = e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + [...e.classList].map(c => '.' + c).join('');
          const text = [...e.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent.trim()).join(' ').slice(0, 50);
          return sel + (text ? ' "' + text + '"' : '');
        }).join('\\n');
        """
        return try await webView.callAsyncJavaScript(script, contentWorld: .page) as? String ?? ""
    }

    /// Page background luminance, share of text elements at 4.5:1 or better, bright large blocks.
    func measure() async throws -> JSONValue {
        let script = """
        const rgb = c => (c.match(/[\\d.]+/g) || []).map(Number);
        const lum = ([r, g, b]) => { const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
          return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
        const own = e => { const c = rgb(getComputedStyle(e).backgroundColor); return (c.length < 4 || c[3] > 0.5) ? c : null; };
        const bg = e => { for (let x = e; x; x = x.parentElement) { const c = own(x); if (c) return c; } return [255, 255, 255]; };
        const all = [...document.body.querySelectorAll('*')].filter(e => e.getClientRects().length);
        const texts = all.filter(e => [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()));
        const fails = [];
        for (const e of texts) { const a = lum(rgb(getComputedStyle(e).color)), b = lum(bg(e));
          const ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
          if (ratio < 4.5) fails.push(e.tagName.toLowerCase() + (e.className ? '.' + e.className : '') + ' ' + ratio.toFixed(2)); }
        const bright = all.filter(e => { const r = e.getBoundingClientRect(), c = own(e); return r.width * r.height >= 20000 && c && lum(c) > 0.4; })
          .map(e => e.tagName.toLowerCase() + (e.className ? '.' + e.className : ''));
        const pageBg = lum(bg(document.querySelector('main') || document.body));
        const htmlBg = lum(own(document.documentElement) || own(document.body) || [255, 255, 255]);
        return JSON.stringify({ pageBg: Math.max(pageBg, htmlBg), textPass: texts.length ? 1 - fails.length / texts.length : 0,
          textElements: texts.length, fails: fails.slice(0, 10), brightBlocks: bright.length, bright: bright.slice(0, 10) });
        """
        let text = try await webView.callAsyncJavaScript(script, contentWorld: .page) as? String ?? "{}"
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}

/// Three light pages, from easy to hard: plain CSS, inline styles, and CSS variables with !important.
enum DarkModeFixtures {
    static let pages: [(String, String)] = [
        ("Plain article", """
        <!doctype html><html><head><meta name="viewport" content="width=device-width"><style>
        body { background: #fff; color: #222; font: 16px Georgia, serif; margin: 0 }
        header { background: #f4f4f4; padding: 12px; border-bottom: 1px solid #ddd } header a { color: #0645ad; margin-right: 12px }
        main { padding: 16px } blockquote { background: #f9f9f9; border-left: 4px solid #ccc; padding: 8px; color: #444 }
        pre { background: #eee; padding: 8px } aside { background: #fffbe6; padding: 12px; margin-top: 16px } footer { color: #777; padding: 16px }
        </style></head><body><header><a href="#">Home</a><a href="#">Archive</a><a href="#">About</a></header>
        <main><h1>Why my home server got quieter</h1><p class="byline">By Sam, 12 March</p>
        <p>After the firmware update the fan ran at full speed. Here is what fixed it, step by step, with the settings I used.</p>
        <blockquote>Set the fan curve to Silent in the BIOS and the noise stops.</blockquote><pre>fan_curve = silent</pre>
        <p>The rest of this article covers the <a href="#">changelog</a> and the vendor's reply.</p>
        <aside>Tip: check the curve again after every update.</aside></main><footer>© 2026 Sam's notes</footer></body></html>
        """),
        ("Inline styles shop", """
        <!doctype html><html><head><meta name="viewport" content="width=device-width"></head>
        <body style="margin:0;font-family:-apple-system,sans-serif">
        <div style="background:#ffffff;color:#111;padding:12px;border-bottom:1px solid #e5e5e5"><b>MiniPC Store</b> <span style="color:#666">Free shipping</span></div>
        <div class="grid" style="background:#fafafa;padding:12px">
        <div class="card" style="background:#ffffff;color:#222;padding:12px;margin-bottom:12px;border:1px solid #eee"><h2 style="color:#111;margin:0">N100 mini PC</h2><p style="color:#555">16 GB RAM, 512 GB SSD, 6 W idle.</p><button style="background:#ffd814;color:#111;border:0;padding:8px">Add to cart</button></div>
        <div class="card" style="background:#ffffff;color:#222;padding:12px;margin-bottom:12px;border:1px solid #eee"><h2 style="color:#111;margin:0">N305 mini PC</h2><p style="color:#555">32 GB RAM, 1 TB SSD, 9 W idle.</p><button style="background:#ffd814;color:#111;border:0;padding:8px">Add to cart</button></div>
        <table style="background:#fff;color:#333;width:100%"><tr style="background:#f2f2f2"><td>Model</td><td>Idle</td></tr><tr><td>N100</td><td>6 W</td></tr><tr style="background:#f2f2f2"><td>N305</td><td>9 W</td></tr></table>
        </div><p style="background:#e8f4ff;color:#034;padding:12px;margin:0">Questions? Chat with us.</p></body></html>
        """),
        ("Variables and important", """
        <!doctype html><html><head><meta name="viewport" content="width=device-width"><style>
        :root { --bg: #ffffff; --fg: #1a1a1a; --card: #f7f7f9; --muted: #6b6b6b; --accent: #2a6df4 }
        html body { background: var(--bg) !important; color: var(--fg); margin: 0; font: 15px system-ui }
        html body div#app.main { background: #ffffff; padding: 12px }
        .post { background: var(--card); padding: 12px; margin: 10px 0; border-radius: 8px }
        .post .meta { color: var(--muted) !important; font-size: 13px } .post a { color: var(--accent) }
        .badge { background: #e6f0ff; color: #1a3d8f; padding: 2px 6px; border-radius: 4px }
        </style></head><body><div id="app" class="main"><h1>Fan noise after firmware 5.2</h1>
        <div class="post"><div class="meta">alice · 3 days ago <span class="badge">OP</span></div><p>Since 5.2 the fan ramps up every few minutes.</p></div>
        <div class="post"><div class="meta">dave · 2 days ago <span class="badge">Solution</span></div><p>Roll back to 5.1.4, or set the curve to Silent. <a href="#">Guide</a></p></div>
        <div class="post"><div class="meta">erin · 1 day ago</div><p>Same fix worked for me on the N305.</p></div></div></body></html>
        """)
    ]
}
