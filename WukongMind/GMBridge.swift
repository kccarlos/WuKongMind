import Foundation
import WebKit

enum GMBridgeError: LocalizedError, Equatable, Sendable {
    case ungranted(String)
    case unsupported(String)
    case nonSerializableValue
    case valueTooLarge
    case totalValuesTooLarge
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .ungranted(let name): return "`\(name)` needs `@grant \(name)`"
        case .unsupported(let name): return "`\(name)` is not supported in WukongMind"
        case .nonSerializableValue: return "GM_setValue value must be JSON-serializable"
        case .valueTooLarge: return "GM_setValue value exceeds the 100 KB limit"
        case .totalValuesTooLarge: return "Script values exceed the 256 KB limit"
        case .persistenceFailed(let reason): return "Failed to save script values: \(reason)"
        }
    }
}

/// Persists `GM_setValue` / `GM_deleteValue` entries per script at
/// `ScriptValues/<script-id>.json` with 100 KB per-value and 256 KB per-script limits.
@MainActor
final class ScriptValuesStore {
    let directoryURL: URL
    private var cache: [String: [String: JSONValue]] = [:]
    private var deletedSnapshots: [String: Data] = [:]

    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func fileURL(for scriptID: String) -> URL {
        directoryURL.appendingPathComponent("\(scriptID).json", isDirectory: false)
    }

    func values(for scriptID: String) -> [String: JSONValue] {
        if let cached = cache[scriptID] { return cached }
        guard ScriptStore.isValidScriptID(scriptID),
              let data = try? Data(contentsOf: fileURL(for: scriptID)),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            cache[scriptID] = [:]
            return [:]
        }
        cache[scriptID] = decoded
        return decoded
    }

    func serializedJSON(for scriptID: String) -> String {
        let current = values(for: scriptID)
        guard !current.isEmpty,
              let data = try? Self.canonicalEncoder.encode(current),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    func setValue(rawJSON: String, forKey key: String, scriptID: String) throws {
        guard ScriptStore.isValidScriptID(scriptID) else {
            throw GMBridgeError.persistenceFailed("Invalid script ID.")
        }
        guard let rawData = rawJSON.data(using: .utf8),
              let parsedValue = try? JSONDecoder().decode(JSONValue.self, from: rawData),
              let canonicalValueData = try? Self.canonicalEncoder.encode(parsedValue) else {
            throw GMBridgeError.nonSerializableValue
        }
        guard canonicalValueData.count <= GMBridge.maxSingleValueBytes else {
            throw GMBridgeError.valueTooLarge
        }
        var updated = values(for: scriptID)
        updated[key] = parsedValue
        guard let storeData = try? Self.canonicalEncoder.encode(updated) else {
            throw GMBridgeError.nonSerializableValue
        }
        guard storeData.count <= GMBridge.maxTotalValuesBytes else {
            throw GMBridgeError.totalValuesTooLarge
        }
        try persist(data: storeData, for: scriptID)
        cache[scriptID] = updated
        deletedSnapshots.removeValue(forKey: scriptID)
    }

    func deleteValue(forKey key: String, scriptID: String) throws {
        guard ScriptStore.isValidScriptID(scriptID) else { return }
        var updated = values(for: scriptID)
        guard updated.removeValue(forKey: key) != nil else { return }
        if updated.isEmpty {
            let url = fileURL(for: scriptID)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } else {
            try persist(data: try Self.canonicalEncoder.encode(updated), for: scriptID)
        }
        cache[scriptID] = updated
    }

    func removeValuesForDeletedScript(id: String) {
        guard ScriptStore.isValidScriptID(id) else { return }
        let url = fileURL(for: id)
        if let diskData = try? Data(contentsOf: url) {
            deletedSnapshots[id] = diskData
        } else if let cached = cache[id], !cached.isEmpty,
                  let encoded = try? Self.canonicalEncoder.encode(cached) {
            deletedSnapshots[id] = encoded
        } else {
            deletedSnapshots.removeValue(forKey: id)
        }
        cache.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: url)
    }

    func restoreValuesForUndoneDelete(id: String) {
        guard ScriptStore.isValidScriptID(id),
              let snapshot = deletedSnapshots.removeValue(forKey: id),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: snapshot) else { return }
        cache[id] = decoded
        try? persist(data: snapshot, for: id)
    }

    func discardDeletedSnapshot(id: String) {
        deletedSnapshots.removeValue(forKey: id)
    }

    private func persist(data: Data, for scriptID: String) throws {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: scriptID), options: .atomic)
        } catch {
            throw GMBridgeError.persistenceFailed(error.localizedDescription)
        }
    }
}

/// Manages per-script `WKContentWorld`s (`WukongScript.<id>`), per-script
/// `WKScriptMessageHandlerWithReply` registration, Swift-side `@grant` checks,
/// and the `GM_*` runtime surface.
@MainActor
final class GMBridge {
    nonisolated static let worldPrefix = "WukongScript."
    nonisolated static let handlerName = "gm"
    nonisolated static let pageReportHandlerName = "__wukongPageScript"
    nonisolated static let maxSingleValueBytes = 100 * 1024
    nonisolated static let maxTotalValuesBytes = 256 * 1024

    static func worldName(for scriptID: String) -> String { "\(worldPrefix)\(scriptID)" }
    static func world(for scriptID: String) -> WKContentWorld { .world(name: worldName(for: scriptID)) }

    static let unsupportedGMFunctions = [
        "GM_notification", "GM_openInTab", "GM_setClipboard", "GM_getResourceText",
        "GM_getResourceURL", "GM_download", "GM_cookie", "GM_addElement",
        "GM_addValueChangeListener", "GM_removeValueChangeListener", "GM_getTab", "GM_saveTab", "GM_getTabs",
    ]
    static let futureM4GrantFunctions = [
        "GM_xmlhttpRequest", "GM_registerMenuCommand", "GM_unregisterMenuCommand", "GM_ai",
    ]

    static func hasAnyValueReadGrant(_ grants: [String]) -> Bool {
        grants.contains("GM_getValue") || grants.contains("GM_listValues")
    }

    let valuesStore: ScriptValuesStore
    var resolveScript: ((String) -> UserScript?)?
    var onValuesMutated: ((String) -> Void)?
    var onScriptError: ((String, [String: Any]) -> Void)?
    var onScriptLoadClean: ((String, [String: Any]) -> Void)?
    var onPageScriptReport: (([String: Any]) -> Void)?
    private var registeredHandlers: [String: GMScriptReplyHandler] = [:]
    private var pageReportHandler: GMPageReplyHandler?

    init(valuesStore: ScriptValuesStore) {
        self.valuesStore = valuesStore
    }

    func syncHandlers(
        for scriptIDs: Set<String>,
        hasPageScripts: Bool = false,
        worlds: [String: WKContentWorld] = [:],
        on controller: WKUserContentController
    ) {
        for id in Set(registeredHandlers.keys).subtracting(scriptIDs) {
            if let handler = registeredHandlers.removeValue(forKey: id) {
                controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: handler.expectedWorld)
            }
        }
        for id in scriptIDs where registeredHandlers[id] == nil {
            ensureHandlerRegistered(for: id, world: worlds[id], on: controller)
        }
        if hasPageScripts {
            ensurePageHandlerRegistered(on: controller)
        } else if pageReportHandler != nil {
            pageReportHandler = nil
            controller.removeScriptMessageHandler(forName: Self.pageReportHandlerName, contentWorld: .page)
        }
    }

    func ensureHandlerRegistered(
        for scriptID: String,
        world: WKContentWorld? = nil,
        on controller: WKUserContentController
    ) {
        guard registeredHandlers[scriptID] == nil else { return }
        let contentWorld = world ?? Self.world(for: scriptID)
        let handler = GMScriptReplyHandler(scriptID: scriptID, expectedWorld: contentWorld, bridge: self)
        registeredHandlers[scriptID] = handler
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: contentWorld)
        controller.addScriptMessageHandler(handler, contentWorld: contentWorld, name: Self.handlerName)
    }

    func ensurePageHandlerRegistered(on controller: WKUserContentController) {
        guard pageReportHandler == nil else { return }
        let handler = GMPageReplyHandler(bridge: self)
        pageReportHandler = handler
        controller.removeScriptMessageHandler(forName: Self.pageReportHandlerName, contentWorld: .page)
        controller.addScriptMessageHandler(handler, contentWorld: .page, name: Self.pageReportHandlerName)
    }

    func removeAllHandlers(from controller: WKUserContentController?) {
        if let controller {
            for handler in registeredHandlers.values {
                controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: handler.expectedWorld)
            }
            if pageReportHandler != nil {
                controller.removeScriptMessageHandler(forName: Self.pageReportHandlerName, contentWorld: .page)
            }
        }
        registeredHandlers.removeAll()
        pageReportHandler = nil
    }

    fileprivate func handleMessage(
        scriptID: String,
        body: Any,
        isMainFrame: Bool,
        world: WKContentWorld,
        expectedWorld: WKContentWorld
    ) -> (Any?, String?) {
        guard isMainFrame, world === expectedWorld else {
            return (nil, "Blocked GM bridge call from untrusted frame or world.")
        }
        guard let payload = body as? [String: Any], let action = payload["action"] as? String else {
            return (nil, "Invalid GM bridge message.")
        }
        switch action {
        case "scriptError":
            onScriptError?(scriptID, payload)
            return (["ok": true], nil)
        case "scriptLoadClean":
            onScriptLoadClean?(scriptID, payload)
            return (["ok": true], nil)
        case "setValue":
            guard let script = resolveScript?(scriptID), !script.runsInPageWorld else {
                return (nil, "Script is not active.")
            }
            guard script.metadata.grants.contains("GM_setValue") else {
                let msg = GMBridgeError.ungranted("GM_setValue").errorDescription ?? "Missing grant"
                onScriptError?(scriptID, ["message": msg])
                return (nil, msg)
            }
            guard let key = payload["key"] as? String, let rawJSON = payload["rawJSON"] as? String else {
                return (nil, GMBridgeError.nonSerializableValue.errorDescription)
            }
            do {
                try valuesStore.setValue(rawJSON: rawJSON, forKey: key, scriptID: scriptID)
                onValuesMutated?(scriptID)
                return (["ok": true], nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        case "deleteValue":
            guard let script = resolveScript?(scriptID), !script.runsInPageWorld else {
                return (nil, "Script is not active.")
            }
            guard script.metadata.grants.contains("GM_deleteValue") else {
                let msg = GMBridgeError.ungranted("GM_deleteValue").errorDescription ?? "Missing grant"
                onScriptError?(scriptID, ["message": msg])
                return (nil, msg)
            }
            guard let key = payload["key"] as? String else { return (["ok": true], nil) }
            do {
                try valuesStore.deleteValue(forKey: key, scriptID: scriptID)
                onValuesMutated?(scriptID)
                return (["ok": true], nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        default:
            return (nil, GMBridgeError.unsupported(action).errorDescription)
        }
    }

    nonisolated static var appMarketingVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.3.0"
    }

    static func gmInfoJSONLiteral(for script: UserScript) -> String {
        let info: [String: Any] = [
            "script": [
                "name": script.name,
                "version": script.metadata.authorVersion ?? String(script.version),
                "namespace": script.metadata.values(for: "@namespace").first ?? "",
                "matches": script.matchRules,
                "grant": script.metadata.grants,
            ],
            "scriptHandler": "WukongMind",
            "version": appMarketingVersion,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func jsonArray(_ items: [String]) -> String {
        (try? String(data: JSONEncoder().encode(items), encoding: .utf8)) ?? "[]"
    }

    static func scriptWorldBootstrapJS(for script: UserScript, initialValuesJSON: String) -> String {
        let canRead = hasAnyValueReadGrant(script.metadata.grants)
        let nameJSON = UserScript.encodeSingleLineJSONString(script.name)
        let infoJSON = gmInfoJSONLiteral(for: script)
        let grantsJSON = jsonArray(script.metadata.grants)
        let seedStr = UserScript.encodeSingleLineJSONString(canRead ? initialValuesJSON : "{}")
        let nonSerErr = UserScript.encodeSingleLineJSONString(GMBridgeError.nonSerializableValue.errorDescription!)
        let singleErr = UserScript.encodeSingleLineJSONString(GMBridgeError.valueTooLarge.errorDescription!)
        let totalErr = UserScript.encodeSingleLineJSONString(GMBridgeError.totalValuesTooLarge.errorDescription!)

        return """
        (() => {
          if (typeof window.__wukongReconfigureGMWorld === "function") {
            window.__wukongReconfigureGMWorld(\(grantsJSON), \(infoJSON), \(nameJSON), \(canRead ? "true" : "false"), \(seedStr));
            return;
          }
          const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
          const postFn = h && typeof h.postMessage === "function" ? h.postMessage.bind(h) : null;
          const values = new Map(), sheets = new Set(), origLog = console.log.bind(console), enc = new TextEncoder();
          let seeded = false, grants = new Set(), currentInfo = Object.freeze({}), logPrefix = "";

          const freezeInfo = (raw) => {
            if (raw && raw.script) {
              if (Array.isArray(raw.script.matches)) Object.freeze(raw.script.matches);
              if (Array.isArray(raw.script.grant)) Object.freeze(raw.script.grant);
              Object.freeze(raw.script);
            }
            return Object.freeze(raw || {});
          };
          const reconfigure = (nextGrants, nextInfo, nextName, allowSeed, rawSeed) => {
            grants = new Set(Array.isArray(nextGrants) ? nextGrants : []);
            currentInfo = freezeInfo(nextInfo);
            window.GM_info = currentInfo;
            logPrefix = "[" + String(nextName || "") + "]";
            if (!seeded && allowSeed) {
              seeded = true;
              try {
                const parsed = JSON.parse(rawSeed);
                for (const [k, v] of Object.entries(parsed || {})) {
                  if (!values.has(k)) values.set(k, JSON.stringify(v));
                }
              } catch (_) {}
            }
          };
          Object.defineProperty(window, "__wukongReconfigureGMWorld", { value: reconfigure });
          reconfigure(\(grantsJSON), \(infoJSON), \(nameJSON), \(canRead ? "true" : "false"), \(seedStr));

          const styleTargets = () => {
            const out = [document], walk = (n) => {
              for (const el of Array.from((n && n.children) || [])) {
                if (el.shadowRoot) { out.push(el.shadowRoot); walk(el.shadowRoot); }
                walk(el);
              }
            };
            if (document.documentElement) walk(document.documentElement);
            return out;
          };
          window.__wukongClearGMStyles = () => {
            if (!sheets.size) return;
            const owned = new Set(sheets); sheets.clear();
            for (const s of owned) { try { s.replaceSync(""); } catch (_) {} }
            for (const t of styleTargets()) {
              try {
                const cur = Array.from(t.adoptedStyleSheets || []);
                const next = cur.filter((s) => !owned.has(s));
                if (next.length !== cur.length) t.adoptedStyleSheets = next;
              } catch (_) {}
            }
          };
          window.__wukongPostGM = (msg) => postFn ? postFn(msg) : Promise.reject(new Error("GM bridge unavailable"));
          const reportAsyncErr = (err) => {
            if (!postFn) return;
            const msg = err && (err.message || err.stack) ? String(err.message || err.stack) : String(err);
            postFn({ action: "scriptError", message: msg, url: String(window.location.href || "") }).catch(() => {});
          };
          const addStyleImpl = (css) => {
            const sheet = new CSSStyleSheet();
            sheet.replaceSync(String(css == null ? "" : css));
            sheets.add(sheet);
            const apply = () => {
              if (!sheets.has(sheet)) return;
              for (const t of styleTargets()) {
                const cur = Array.from(t.adoptedStyleSheets || []);
                if (!cur.includes(sheet)) t.adoptedStyleSheets = [...cur, sheet];
              }
            };
            apply();
            if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", apply, { once: true });
            return sheet;
          };
          const needGrant = (fn) => { throw new Error("`" + fn + "` needs `@grant " + fn + "`"); };
          const notSupported = (fn) => { throw new Error("`" + fn + "` is not supported in WukongMind"); };
          const req = (fn) => { if (!grants.has(fn)) needGrant(fn); };
          const uLen = (s) => enc.encode(s).length;
          const prepareSet = (key, value) => {
            const k = String(key), ser = JSON.stringify(value);
            if (ser === undefined) throw new TypeError(\(nonSerErr));
            if (uLen(ser) > \(maxSingleValueBytes)) throw new Error(\(singleErr));
            let count = 1, bytes = uLen(JSON.stringify(k)) + 1 + uLen(ser);
            for (const [ek, ev] of values.entries()) {
              if (ek === k) continue;
              count++; bytes += uLen(JSON.stringify(ek)) + 1 + uLen(ev);
            }
            if ((2 + (count - 1) + bytes) > \(maxTotalValuesBytes)) throw new Error(\(totalErr));
            return [k, ser];
          };

          window.GM_log = (...args) => { origLog(logPrefix, ...args); };
          window.GM_addStyle = (css) => addStyleImpl(css);
          window.GM_getValue = (key, def) => { req("GM_getValue"); const k = String(key); return values.has(k) ? JSON.parse(values.get(k)) : def; };
          window.GM_setValue = (key, value) => {
            req("GM_setValue");
            const [k, ser] = prepareSet(key, value), had = values.has(k), prev = values.get(k);
            values.set(k, ser);
            if (postFn) postFn({ action: "setValue", key: k, rawJSON: ser }).catch((e) => {
              if (had) values.set(k, prev); else values.delete(k);
              reportAsyncErr(e);
            });
          };
          window.GM_deleteValue = (key) => {
            req("GM_deleteValue");
            const k = String(key); values.delete(k);
            if (postFn) postFn({ action: "deleteValue", key: k }).catch(reportAsyncErr);
          };
          window.GM_listValues = () => { req("GM_listValues"); return Array.from(values.keys()); };
          for (const fn of \(jsonArray(futureM4GrantFunctions))) window[fn] = () => { req(fn); notSupported(fn); };
          for (const fn of \(jsonArray(unsupportedGMFunctions))) window[fn] = () => notSupported(fn);
          window.close = () => notSupported("window.close");
          window.focus = () => notSupported("window.focus");
        })();
        """
    }

    static func pageWorldLexicalGMBindingsJS(for script: UserScript, scriptIDJSON: String) -> String {
        let nameJSON = UserScript.encodeSingleLineJSONString(script.name)
        let infoJSON = gmInfoJSONLiteral(for: script)
        let powerFns = ["GM_getValue", "GM_setValue", "GM_deleteValue", "GM_listValues"] + futureM4GrantFunctions
        let ungranted = powerFns.map { "const \($0) = () => { throw new Error(\(UserScript.encodeSingleLineJSONString("`\($0)` needs `@grant \($0)`"))); };" }.joined(separator: "\n")
        let unsupported = unsupportedGMFunctions.map { "const \($0) = () => { throw new Error(\(UserScript.encodeSingleLineJSONString("`\($0)` is not supported in WukongMind"))); };" }.joined(separator: "\n")
        return """
        const GM_info = (() => {
          const info = \(infoJSON);
          if (info && info.script) {
            if (Array.isArray(info.script.matches)) Object.freeze(info.script.matches);
            if (Array.isArray(info.script.grant)) Object.freeze(info.script.grant);
            Object.freeze(info.script);
          }
          return Object.freeze(info);
        })();
        const __wukongOrigLog = console.log.bind(console);
        const GM_log = (...args) => { __wukongOrigLog("[" + \(nameJSON) + "]", ...args); };
        const GM_addStyle = (css) => window.__wukongAddPageScriptStyle(\(scriptIDJSON), String(css == null ? "" : css));
        \(ungranted)
        \(unsupported)
        """
    }
}

@MainActor
private final class GMScriptReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    let scriptID: String
    let expectedWorld: WKContentWorld
    weak var bridge: GMBridge?

    init(scriptID: String, expectedWorld: WKContentWorld, bridge: GMBridge) {
        self.scriptID = scriptID
        self.expectedWorld = expectedWorld
        self.bridge = bridge
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let bridge else {
            replyHandler(nil, "GM bridge is no longer attached.")
            return
        }
        let (reply, err) = bridge.handleMessage(
            scriptID: scriptID,
            body: message.body,
            isMainFrame: message.frameInfo.isMainFrame,
            world: message.world,
            expectedWorld: expectedWorld
        )
        replyHandler(reply, err)
    }
}

@MainActor
private final class GMPageReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var bridge: GMBridge?

    init(bridge: GMBridge) {
        self.bridge = bridge
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let bridge, message.frameInfo.isMainFrame, message.world === WKContentWorld.page else {
            replyHandler(["ok": false], nil)
            return
        }
        if let payload = message.body as? [String: Any] {
            bridge.onPageScriptReport?(payload)
        }
        replyHandler(["ok": true], nil)
    }
}
