import Foundation

/// One `fetch` or `XMLHttpRequest` entry captured in the page world (`network_log`).
struct AgentNetworkEntry: Codable, Equatable, Sendable {
    var time: String
    var kind: String
    var method: String
    var url: String
    var status: Int
    var durationMs: Int
    var contentType: String
    var responseBytes: Int
    var responsePreview: String?

    enum CodingKeys: String, CodingKey {
        case time, kind, method, url, status
        case durationMs = "duration_ms"
        case contentType = "content_type"
        case responseBytes = "response_bytes"
        case responsePreview = "response_preview"
    }

    private static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()

    func jsonLine(includeBody: Bool) -> String {
        var copy = self
        if !includeBody {
            copy.responsePreview = nil
        } else if let preview = copy.responsePreview, preview.count > AgentPageCapture.maxPreviewCharacters {
            copy.responsePreview = String(preview.prefix(AgentPageCapture.maxPreviewCharacters))
        }
        guard let data = try? Self.lineEncoder.encode(copy),
              let line = String(data: data, encoding: .utf8) else { return "{}" }
        return line
    }
}

/// One `console.*` line captured from the page world for developer mode.
struct AgentConsoleEntry: Codable, Equatable, Sendable {
    var time: String
    var level: String
    var text: String
}

/// Page-world document-start capture hook for `network_log` and the developer console.
/// Records no request headers (`Cookie`, `Authorization`) and never reads `Set-Cookie`.
enum AgentPageCapture {
    static let maxBufferEntries = 200
    static let maxPreviewCharacters = 2_000
    static let maxConsoleLineCharacters = 500
    static let defaultNetworkLimit = 50

    static let readNetworkScript = """
    (window.__wukongPageCapture && typeof window.__wukongPageCapture.networkJSON === 'function')
      ? String(window.__wukongPageCapture.networkJSON()) : '[]'
    """

    static let readNetworkWithBodiesAsyncScript = """
    if (window.__wukongPageCapture && typeof window.__wukongPageCapture.networkJSONWithBodies === 'function') {
      return String(await window.__wukongPageCapture.networkJSONWithBodies());
    }
    return (window.__wukongPageCapture && typeof window.__wukongPageCapture.networkJSON === 'function')
      ? String(window.__wukongPageCapture.networkJSON()) : '[]';
    """

    static let readConsoleScript = """
    (window.__wukongPageCapture && typeof window.__wukongPageCapture.consoleJSON === 'function')
      ? String(window.__wukongPageCapture.consoleJSON()) : '[]'
    """

    static func decodeNetwork(
        from rawJSON: Any?,
        urlFilter: String?,
        limit: Int = defaultNetworkLimit,
        includeBodies: Bool = false
    ) -> [AgentNetworkEntry] {
        guard let json = rawJSON as? String,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AgentNetworkEntry].self, from: data) else {
            return []
        }
        let clampedLimit = min(max(1, limit), maxBufferEntries)
        let newestFirst = decoded.suffix(maxBufferEntries).reversed()
        let filtered = (urlFilter?.isEmpty == false)
            ? newestFirst.filter { $0.url.localizedCaseInsensitiveContains(urlFilter!) }
            : Array(newestFirst)
        return filtered.prefix(clampedLimit).map { entry in
            var copy = entry
            if !includeBodies {
                copy.responsePreview = nil
            } else if let preview = copy.responsePreview, preview.count > maxPreviewCharacters {
                copy.responsePreview = String(preview.prefix(maxPreviewCharacters))
            }
            return copy
        }
    }

    static func decodeConsole(from rawJSON: Any?) -> [AgentConsoleEntry] {
        guard let json = rawJSON as? String,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AgentConsoleEntry].self, from: data) else {
            return []
        }
        return decoded.suffix(maxBufferEntries).reversed().map { entry in
            var copy = entry
            if copy.text.count > maxConsoleLineCharacters {
                copy.text = String(copy.text.prefix(maxConsoleLineCharacters))
            }
            return copy
        }
    }

    static let hookSource = #"""
    (function () {
      if (Object.prototype.hasOwnProperty.call(window, '__wukongPageCapture')) return;
      const MAX_ENTRIES = 200, MAX_PREVIEW = 2000, MAX_CONSOLE = 500;
      const network = [], consoleLines = [], pendingPreviews = new Set();
      const nowMs = () => (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
      const isoNow = () => { try { return new Date().toISOString(); } catch (_) { return ''; } };
      const resolveUrl = (raw) => {
        const s = raw == null ? '' : String(raw);
        if (!s) return '';
        try { return new URL(s, window.location.href).href; } catch (_) { return s; }
      };
      const byteLen = (s) => {
        if (!s) return 0;
        try { if (typeof TextEncoder === 'function') return new TextEncoder().encode(s).byteLength; } catch (_) {}
        return s.length;
      };
      const isTextOrJson = (ct) => {
        if (!ct) return false;
        const m = String(ct).split(';')[0].trim().toLowerCase();
        if (m === 'text/event-stream') return false;
        return m.startsWith('text/') || m === 'application/json' || m.endsWith('+json') ||
          m === 'application/xml' || m.endsWith('+xml') || m === 'application/javascript' || m === 'application/x-javascript';
      };
      const pushBounded = (arr, item) => {
        arr.push(item);
        if (arr.length > MAX_ENTRIES) arr.splice(0, arr.length - MAX_ENTRIES);
      };

      const fmtArg = (a) => {
        if (typeof a === 'string') return a;
        if (a instanceof Error) return a.stack || (a.name + ': ' + a.message);
        if (a === undefined || a === null) return String(a);
        if (typeof a === 'object') { try { return JSON.stringify(a); } catch (_) { return String(a); } }
        return String(a);
      };
      if (window.console && typeof window.console === 'object') {
        ['log', 'info', 'warn', 'error', 'debug'].forEach((level) => {
          const orig = window.console[level];
          if (typeof orig !== 'function') return;
          window.console[level] = function () {
            try {
              const parts = [];
              for (let i = 0; i < arguments.length; i++) parts.push(fmtArg(arguments[i]));
              pushBounded(consoleLines, { time: isoNow(), level: level, text: parts.join(' ').slice(0, MAX_CONSOLE) });
            } catch (_) {}
            return orig.apply(this, arguments);
          };
        });
      }

      const readClonePreview = (response, entry, hasCl) => {
        try {
          const clone = response.clone();
          const timeout = new Promise((r) => setTimeout(r, 150));
          if (clone.body && typeof clone.body.getReader === 'function' && typeof TextDecoder === 'function') {
            const reader = clone.body.getReader(), dec = new TextDecoder('utf-8', { fatal: false });
            let text = '', bytes = 0;
            const pump = () => reader.read().then((c) => {
              if (!c || c.done) {
                text += dec.decode();
                if (!hasCl) entry.response_bytes = bytes;
                entry.response_preview = text.slice(0, MAX_PREVIEW);
                return;
              }
              if (c.value && c.value.byteLength) bytes += c.value.byteLength;
              if (text.length < MAX_PREVIEW) text += dec.decode(c.value, { stream: true });
              if (text.length >= MAX_PREVIEW && (hasCl || bytes >= 65536)) {
                if (!hasCl) entry.response_bytes = bytes;
                entry.response_preview = text.slice(0, MAX_PREVIEW);
                try { reader.cancel(); } catch (_) {}
                return;
              }
              return pump();
            });
            return Promise.race([pump().catch(() => {}), timeout]);
          }
          return Promise.race([clone.text().then((t) => {
            const s = String(t || '');
            if (!hasCl) entry.response_bytes = byteLen(s);
            entry.response_preview = s.slice(0, MAX_PREVIEW);
          }, () => {}), timeout]);
        } catch (_) { return Promise.resolve(); }
      };

      if (typeof window.fetch === 'function') {
        const origFetch = window.fetch;
        window.fetch = function (input, init) {
          let rawUrl = '', method = 'GET';
          try {
            if (typeof input === 'string') rawUrl = input;
            else if (typeof URL === 'function' && input instanceof URL) rawUrl = input.href;
            else if (input && typeof input === 'object' && typeof input.url === 'string') {
              rawUrl = input.url;
              if (input.method) method = input.method;
            } else if (input != null) rawUrl = String(input);
            if (init && typeof init === 'object' && init.method) method = init.method;
          } catch (_) {}
          method = String(method || 'GET').toUpperCase();
          const url = resolveUrl(rawUrl), startedMs = nowMs(), startedIso = isoNow();
          return origFetch.apply(this, arguments).then((res) => {
            let ct = '', parsedCl = NaN;
            try {
              if (res && res.headers && typeof res.headers.get === 'function') {
                ct = res.headers.get('content-type') || '';
                const cl = res.headers.get('content-length');
                if (cl != null && cl !== '') parsedCl = parseInt(cl, 10);
              }
            } catch (_) {}
            const hasCl = Number.isFinite(parsedCl) && parsedCl >= 0;
            const entry = {
              time: startedIso, kind: 'fetch', method: method, url: url,
              status: (res && typeof res.status === 'number') ? res.status : 0,
              duration_ms: Math.max(0, Math.round(nowMs() - startedMs)),
              content_type: ct, response_bytes: hasCl ? parsedCl : 0, response_preview: null
            };
            pushBounded(network, entry);
            if (res && typeof res.clone === 'function' && isTextOrJson(ct)) {
              const p = readClonePreview(res, entry, hasCl);
              pendingPreviews.add(p);
              p.then(() => { pendingPreviews.delete(p); }, () => { pendingPreviews.delete(p); });
            }
            return res;
          }, (err) => {
            pushBounded(network, {
              time: startedIso, kind: 'fetch', method: method, url: url, status: 0,
              duration_ms: Math.max(0, Math.round(nowMs() - startedMs)),
              content_type: '', response_bytes: 0, response_preview: null
            });
            throw err;
          });
        };
      }

      if (typeof window.XMLHttpRequest === 'function' && window.XMLHttpRequest.prototype) {
        const proto = window.XMLHttpRequest.prototype, origOpen = proto.open, origSend = proto.send;
        const xhrMeta = new WeakMap();
        const finalizeXhr = (xhr, state) => {
          if (!state || state.recorded) return;
          state.recorded = true;
          let ct = '', parsedCl = NaN;
          try {
            if (typeof xhr.getResponseHeader === 'function') {
              ct = xhr.getResponseHeader('content-type') || '';
              const cl = xhr.getResponseHeader('content-length');
              if (cl != null && cl !== '') parsedCl = parseInt(cl, 10);
            }
          } catch (_) {}
          const hasCl = Number.isFinite(parsedCl) && parsedCl >= 0;
          let bytes = hasCl ? parsedCl : 0, preview = null;
          try {
            const rt = xhr.responseType || '';
            if ((rt === '' || rt === 'text') && isTextOrJson(ct)) {
              const t = typeof xhr.responseText === 'string' ? xhr.responseText : '';
              if (!hasCl) bytes = byteLen(t);
              preview = t.slice(0, MAX_PREVIEW);
            } else if (rt === 'json' && xhr.response !== undefined) {
              const t = JSON.stringify(xhr.response) || '';
              if (!hasCl) bytes = byteLen(t);
              preview = t.slice(0, MAX_PREVIEW);
            } else if (!hasCl && rt === 'arraybuffer' && xhr.response && xhr.response.byteLength) {
              bytes = xhr.response.byteLength;
            } else if (!hasCl && rt === 'blob' && xhr.response && xhr.response.size) {
              bytes = xhr.response.size;
            }
          } catch (_) {}
          pushBounded(network, {
            time: state.startedIso, kind: 'xhr', method: state.method, url: state.url,
            status: (typeof xhr.status === 'number') ? xhr.status : 0,
            duration_ms: Math.max(0, Math.round(nowMs() - state.startedMs)),
            content_type: ct, response_bytes: bytes, response_preview: preview
          });
        };
        proto.open = function (method, url) {
          try {
            const prev = xhrMeta.get(this);
            const meta = { method: String(method || 'GET').toUpperCase(), url: resolveUrl(url), attached: !!(prev && prev.attached), currentRun: null };
            if (!meta.attached && typeof this.addEventListener === 'function') {
              const self = this;
              this.addEventListener('readystatechange', () => { const m = xhrMeta.get(self); if (m && m.currentRun && self.readyState === 4) finalizeXhr(self, m.currentRun); });
              this.addEventListener('loadend', () => { const m = xhrMeta.get(self); if (m && m.currentRun) finalizeXhr(self, m.currentRun); });
              meta.attached = true;
            }
            xhrMeta.set(this, meta);
          } catch (_) {}
          return origOpen.apply(this, arguments);
        };
        proto.send = function () {
          try {
            const meta = xhrMeta.get(this);
            if (meta) meta.currentRun = { method: meta.method, url: meta.url, startedMs: nowMs(), startedIso: isoNow(), recorded: false };
          } catch (_) {}
          return origSend.apply(this, arguments);
        };
      }

      Object.defineProperty(window, '__wukongPageCapture', {
        value: Object.freeze({
          networkJSON: () => JSON.stringify(network),
          networkJSONWithBodies: () => pendingPreviews.size > 0
            ? Promise.all(Array.from(pendingPreviews)).then(() => JSON.stringify(network), () => JSON.stringify(network))
            : Promise.resolve(JSON.stringify(network)),
          consoleJSON: () => JSON.stringify(consoleLines)
        }),
        configurable: false, enumerable: false, writable: false
      });
    })();
    """#
}
