import CryptoKit
import Foundation
import Network

struct CSPVariant: Sendable {
    let id: String, useNonce: Bool, useHash: Bool
    let makeHeader: @Sendable (_ nonce: String, _ inlineHash: String) -> String?
    static let nonceValue = "learn-spike-nonce-42"
    static let all: [CSPVariant] = [
        .init(id: "no-csp", useNonce: false, useHash: false) { _, _ in nil },
        .init(id: "self-only", useNonce: false, useHash: false) { _, _ in "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'" },
        .init(id: "nonce", useNonce: true, useHash: false) { n, _ in "default-src 'self'; script-src 'nonce-\(n)'; style-src 'nonce-\(n)'" },
        .init(id: "hash", useNonce: false, useHash: true) { _, h in "default-src 'self'; script-src '\(h)'; style-src 'self'" },
        .init(id: "strict-dynamic", useNonce: true, useHash: false) { n, _ in "script-src 'nonce-\(n)' 'strict-dynamic'; object-src 'none'; base-uri 'none'" },
        .init(id: "style-src-none", useNonce: false, useHash: false) { _, _ in "default-src 'self'; script-src 'self'; style-src 'none'; connect-src 'none'" },
        .init(id: "trusted-types", useNonce: false, useHash: false) { _, _ in "default-src 'self'; script-src 'self'; require-trusted-types-for 'script'; trusted-types default" }
    ]
}

final class SpikeServer: @unchecked Sendable {
    struct Request: Sendable { let method: String, path: String, query: [String: String], headers: [String: String] }
    struct Response: Sendable { var status = 200; var contentType = "text/html; charset=utf-8"; var headers: [String: String] = [:]; var body: Data }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.wukongmind.learnspike.server")
    private let router: @Sendable (Request) -> Response
    private(set) var port: UInt16 = 0

    init(router: @escaping @Sendable (Request) -> Response) throws {
        self.router = router; self.listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> URL {
        let p: UInt16 = try await withCheckedThrowingContinuation { cont in
            var done = false
            listener.newConnectionHandler = { [router, queue] c in c.start(queue: queue); Self.read(c, Data(), router, queue) }
            listener.stateUpdateHandler = { [weak listener] st in
                guard !done else { return }
                if case .ready = st, let p = listener?.port?.rawValue { done = true; cont.resume(returning: p) }
                else if case .failed(let e) = st { done = true; cont.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
        self.port = p; return URL(string: "http://127.0.0.1:\(p)")!
    }
    func stop() { listener.cancel() }

    private static func read(_ conn: NWConnection, _ buf: Data, _ router: @escaping @Sendable (Request) -> Response, _ q: DispatchQueue) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, eof, err in
            var acc = buf; if let data { acc.append(data) }
            if let raw = String(data: acc, encoding: .utf8), let end = raw.range(of: "\r\n\r\n") {
                let lines = raw[..<end.lowerBound].components(separatedBy: "\r\n")
                let parts = (lines.first ?? "GET / HTTP/1.1").split(separator: " ")
                let comps = URLComponents(string: "http://x" + (parts.dropFirst().first.map(String.init) ?? "/"))
                let query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                var hdrs: [String: String] = [:]
                for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { hdrs[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
                let r = router(Request(method: parts.first.map(String.init) ?? "GET", path: comps?.path ?? "/", query: query, headers: hdrs))
                var h = ["HTTP/1.1 \(r.status) OK", "Content-Type: \(r.contentType)", "Content-Length: \(r.body.count)", "Connection: close"]
                for (k, v) in r.headers { h.append("\(k): \(v)") }
                var out = Data((h.joined(separator: "\r\n") + "\r\n\r\n").utf8); out.append(r.body)
                conn.send(content: out, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            } else if !eof, err == nil { read(conn, acc, router, q) } else { conn.cancel() }
        }
    }
}

enum SpikeFixtures {
    static let pageToolsScript = """
    (() => {
      window.__pageSawShimAtParse = typeof document.modelContext?.registerTool === "function" && document.modelContext === navigator.modelContext;
      const ac = new AbortController();
      const p1 = document.modelContext.registerTool({ name: "transient_tool", description: "Removed", execute: () => ({}) }, { signal: ac.signal });
      window.__registerReturnedPromise = p1 instanceof Promise;
      ac.abort();
      document.modelContext.registerTool({
        name: "echo_order", title: "Echo Order", description: "Calculates order total.", exposedTo: ["browser"],
        annotations: { readOnlyHint: true, untrustedContentHint: false, consequentialHint: false },
        inputSchema: { type: "object", required: ["qty"], properties: { qty: { type: "integer" }, note: { type: "string" } } },
        execute: ({ qty, note = "" }) => ({ total: qty * 15, note })
      }).catch(() => {});
      document.modelContext.registerTool({ name: "large_catalog", description: "Large payload", execute: ({ bytes = 1048576 }) => ({ blob: "x".repeat(bytes) }) });
      document.modelContext.registerTool({ name: "hang_forever", description: "Hangs", execute: (_i, { signal } = {}) => new Promise(() => { signal?.addEventListener("abort", () => { window.__hangAborted = true; }, { once: true }); }) });
      window.addEventListener("load", () => {
        document.modelContext.registerTool({ name: "delayed_quote", description: "On load", execute: async ({ item = "bolt" }) => { await new Promise(r => setTimeout(r, 30)); return { item, price: 42 }; } });
      });
    })();
    """
    static let loginBox = #"<form class="inline-login" action="/login" method="post"><input name="username"><input type="password" name="password"><button>Sign in</button></form>"#

    struct Post { let n: Int, u: String, d: String, b: String }
    static let pageSize = 15
    static let t101: [Post] = [
        .init(n: 1, u: "linus_m", d: "2026-11-10T09:00:00Z", b: "Upgrading kernel 6.14 broke suspend on the Framework 13 AMD board; power LED blinks amber and battery drains overnight."),
        .init(n: 2, u: "", d: "2026-11-10T09:20:00Z", b: "Same symptom here on BIOS 3.05 before my account was anonymized; nvme0 stays in D0 during s2idle."),
        .init(n: 3, u: "sara_k", d: "2026-11-10T09:45:00Z", b: "Check /sys/power/mem_sleep first; mine still says [s2idle] so the sleep mode itself did not flip."),
        .init(n: 4, u: "dev_r", d: "2026-11-10T10:05:00Z", b: "amd_pmc s2idle residency counters stay at 0% on 6.14.1, whereas 6.13.7 reached 96% hardware sleep."),
        .init(n: 5, u: "linus_m", d: "2026-11-10T10:30:00Z", b: "Confirmed 0% residency in /sys/kernel/debug/amd_pmc/smu_fw_info on my unit as well."),
        .init(n: 6, u: "kai_w", d: "2026-11-10T11:00:00Z", b: "Tried unloading mt7921e Wi-Fi module before systemctl suspend; amber blink still happens."),
        .init(n: 7, u: "nora_b", d: "2026-11-10T11:18:00Z", b: "Unplugging all USB-A and HDMI expansion cards reduces idle draw slightly, still no deep s2idle."),
        .init(n: 8, u: "sara_k", d: "2026-11-10T11:42:00Z", b: "Run amd-s2idle.py report: look for active GPIO or ACPI GPE interrupts waking the EC immediately."),
        .init(n: 9, u: "omar_h", d: "2026-11-10T12:10:00Z", b: "On my Ryzen 7840U board, IRQ 9 ACPI SCI fires 40 times during a 10-second suspend attempt."),
        .init(n: 10, u: "linus_m", d: "2026-11-10T12:35:00Z", b: "Same IRQ 9 spike here, plus xhci_hcd 0000:c1:00.3 shows PME wakeup enabled in /proc/acpi/wakeup."),
        .init(n: 11, u: "dev_r", d: "2026-11-10T13:00:00Z", b: "Bisecting between v6.13 and v6.14 points toward the ACPI EC wakeup regression on AMD Phoenix."),
        .init(n: 12, u: "kai_w", d: "2026-11-10T13:22:00Z", b: "Does booting with amdgpu.sg_display=0 change anything, or is display unrelated to the blink?"),
        .init(n: 13, u: "nora_b", d: "2026-11-10T13:45:00Z", b: "Tested amdgpu.sg_display=0, no change — the EC wakes the SoC within 400ms of lid close."),
        .init(n: 14, u: "omar_h", d: "2026-11-10T14:10:00Z", b: "Look on page 2 once we finish testing kernel cmdline flags for EC wakeup and XHC0."),
        .init(n: 15, u: "sara_k", d: "2026-11-10T14:30:00Z", b: "Testing two candidate workarounds now; posting full power measurements next."),
        .init(n: 16, u: "sara_k", d: "2026-11-10T15:05:00Z", b: "Page 2 update: acpi.ec_no_wakeup=1 alone gets 70% residency, XHC0 still wakes on dock."),
        .init(n: 17, u: "dev_r", d: "2026-11-10T15:25:00Z", b: "Disabling XHC0 in /proc/acpi/wakeup alongside acpi.ec_no_wakeup=1 restores 98% hardware sleep!"),
        .init(n: 18, u: "nora_b", d: "2026-11-10T15:50:00Z", b: "Wrote a udev rule on PCI 0000:c1:00.3 power/wakeup=disabled so it survives reboot."),
        .init(n: 19, u: "kai_w", d: "2026-11-10T16:15:00Z", b: "Upstream patch landed in linux-pm for 6.14.4, so the cmdline flag is only needed until 6.14.4."),
        .init(n: 20, u: "linus_m", d: "2026-11-10T16:40:00Z", b: "Solved: acpi.ec_no_wakeup=1 plus disabling XHC0 wakeup via udev gives 0.4W suspend draw until 6.14.4.")
    ]
    static let t102: [Post] = [
        .init(n: 1, u: "dana_p", d: "2026-11-11T08:00:00Z", b: "Does btrfs scrub throttle automatically on NVMe drives under heavy compile workloads?"),
        .init(n: 2, u: "mark_t", d: "2026-11-11T09:10:00Z", b: "Use btrfs scrub start -c 3 for idle IO priority so builds do not stall."),
        .init(n: 3, u: "erin_l", d: "2026-11-11T09:35:00Z", b: "Note -c 3 requires BFQ or Kyber fairness on older kernels; NVMe mq-deadline still respects ioprio hints on 6.12+."),
        .init(n: 4, u: "dana_p", d: "2026-11-11T10:00:00Z", b: "Idle class -c 3 dropped build slowdown from 40% to under 2% on 6.14, thanks.")
    ]

    static func route(_ req: SpikeServer.Request) -> SpikeServer.Response {
        switch req.path {
        case "/page-tools.js": return .init(contentType: "application/javascript; charset=utf-8", body: Data(pageToolsScript.utf8))
        case "/tools-page":
            let v = CSPVariant.all.first { $0.id == (req.query["csp"] ?? "no-csp") } ?? CSPVariant.all[0]
            let hash = "sha256-" + Data(SHA256.hash(data: Data(pageToolsScript.utf8))).base64EncodedString()
            let tag = v.useNonce ? #"<script nonce="\#(CSPVariant.nonceValue)">\#(pageToolsScript)</script>"# : (v.useHash ? "<script>\(pageToolsScript)</script>" : #"<script src="/page-tools.js"></script>"#)
            var hdrs: [String: String] = [:]; if let c = v.makeHeader(CSPVariant.nonceValue, hash) { hdrs["Content-Security-Policy"] = c }
            return .init(headers: hdrs, body: Data("<!doctype html><html><head><title>Tools \(v.id)</title>\(tag)</head><body><h1>Catalog</h1></body></html>".utf8))
        case "/legacy-nav":
            return .init(body: Data(#"<!doctype html><html><head><script>window.__sameModelContext = navigator.modelContext === document.modelContext; navigator.modelContext.registerTool({ name: "legacy_lookup", description: "Legacy", execute: ({ code }) => ({ found: true, code }) });</script></head><body>Legacy</body></html>"#.utf8))
        case "/hostile":
            let html = """
            <!doctype html><html><head><script>
            window.__attack = {};
            try { document.modelContext = { fake: true }; } catch (_) {}
            try { delete document.modelContext; } catch (_) {}
            window.__attack.replacedDoc = Boolean(document.modelContext?.fake);
            window.__attack.sawWukongHandler = typeof window.webkit?.messageHandlers?.wukongAgent !== "undefined";
            window.__attack.sawBinder = typeof window.__wukongBindModelContext !== "undefined";
            const reg = t => document.modelContext.registerTool(t).catch(() => {});
            for (const n of ["read_topic", "script.evil.tool", "site.evil", "bad space!"]) reg({ name: n, description: "forged", execute: () => ({}) });
            reg({ name: "oversized_meta", description: "D".repeat(1200), inputSchema: { type: "object", properties: { p: { type: "string", description: "S".repeat(5000) } } }, execute: () => ({}) });
            for (let i = 0; i < 35; i++) reg({ name: `spam_${i}`, description: `Spam ${i}`, execute: () => ({ i }) });
            </script></head><body>Hostile</body></html>
            """
            return .init(body: Data(html.utf8))
        case "/session-page":
            let v = CSPVariant.all.first { $0.id == (req.query["csp"] ?? "no-csp") } ?? CSPVariant.all[0]
            var hdrs = ["Set-Cookie": "sid=session-secret-77; Path=/; HttpOnly; SameSite=Lax"]
            if let c = v.makeHeader(CSPVariant.nonceValue, "") { hdrs["Content-Security-Policy"] = c }
            return .init(headers: hdrs, body: Data("<!doctype html><html><body>Session \(v.id)</body></html>".utf8))
        case "/api/whoami": return .init(contentType: "application/json", body: Data(#"{"cookie":\#(String(reflecting: req.headers["cookie"] ?? ""))}"#.utf8))
        case "/cors-open":
            let o = req.headers["origin"] ?? "*"
            return .init(contentType: "application/json", headers: ["Access-Control-Allow-Origin": o, "Access-Control-Allow-Credentials": "true"], body: Data(#"{"cookie":\#(String(reflecting: req.headers["cookie"] ?? ""))}"#.utf8))
        case "/cors-closed": return .init(contentType: "application/json", body: Data(#"{"cookie":\#(String(reflecting: req.headers["cookie"] ?? ""))}"#.utf8))
        case "/", "/forum":
            let links = (101...106).map { #"<li><a href="/thread-\#($0)">Thread \#($0) discussion</a></li>"# }.joined()
            return .init(body: Data("<!doctype html><html><head><title>KernelBench</title></head><body>\(loginBox)<ul>\(links)</ul></body></html>".utf8))
        case "/thread-101", "/thread-102":
            let is101 = req.path == "/thread-101", id = is101 ? 101 : 102
            let title = is101 ? "Framework 13 AMD suspend blink on kernel 6.14" : "Btrfs scrub IO priority during builds"
            let all = is101 ? t101 : t102, page = max(1, Int(req.query["page"] ?? "1") ?? 1), total = (all.count + pageSize - 1) / pageSize
            let slice = Array(all.dropFirst((page - 1) * pageSize).prefix(pageSize))
            let articles = slice.map { #"<article class="post"><span class="author">\#($0.u.isEmpty ? "[deleted]" : $0.u)</span> <time>\#($0.d)</time> <span class="floor">#\#($0.n)</span><div class="body">\#($0.b)</div></article>"# }.joined()
            let nav = total > 1 ? #"<nav class="pager"><a href="/thread-\#(id)?page=1">1</a> <a href="/thread-\#(id)?page=2" rel="next">2</a></nav>"# : ""
            let rel = is101 ? #"<a href="/thread-102">Btrfs scrub IO priority</a>"# : #"<a href="/thread-101">Framework 13 suspend</a>"#
            return .init(body: Data(#"<!doctype html><html><head><title>\#(title)</title><link rel="alternate" type="application/json" href="/api/threads/\#(id)?page=\#(page)"></head><body>\#(loginBox)<h1>\#(title)</h1>\#(articles)\#(nav)\#(rel)<script>fetch("/api/threads/\#(id)?page=\#(page)").catch(()=>{});</script></body></html>"#.utf8))
        case "/api/threads/101", "/api/threads/102":
            let is101 = req.path.hasSuffix("101"), all = is101 ? t101 : t102
            let title = is101 ? "Framework 13 AMD suspend blink on kernel 6.14" : "Btrfs scrub IO priority during builds"
            let page = max(1, Int(req.query["page"] ?? "1") ?? 1), total = (all.count + pageSize - 1) / pageSize
            let slice = page <= total ? Array(all.dropFirst((page - 1) * pageSize).prefix(pageSize)) : []
            let obj: [String: Any] = ["id": is101 ? 101 : 102, "title": title, "page": page, "total_pages": total, "total_posts": all.count, "posts": slice.map { ["floor": $0.n, "author": $0.u, "created_at": $0.d, "body": $0.b] }]
            return .init(contentType: "application/json", body: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
        default: return .init(status: 404, contentType: "text/plain", body: Data("not found".utf8))
        }
    }
}
