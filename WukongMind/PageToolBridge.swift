import Foundation
import WebKit

enum PageToolSource: String, Codable, Equatable, Sendable {
    case site, script
}

struct PageToolAnnotations: Codable, Equatable, Sendable {
    var readOnlyHint: Bool = false
    var untrustedContentHint: Bool = false
    var consequentialHint: Bool = false
}

struct PageTool: Codable, Equatable, Sendable {
    var source: PageToolSource
    var ownerID: String?
    var name: String
    var prefixedName: String
    var title: String?
    var description: String
    var inputSchema: JSONValue?
    var inputSchemaJSON: String?
    var annotations: PageToolAnnotations
}

struct PageToolSnapshot: Codable, Equatable, Sendable {
    var tools: [PageTool]
    var droppedCount: Int
    var nativeModelContextDetected: Bool

    var siteTools: [PageTool] { tools.filter { $0.source == .site } }
    var scriptTools: [PageTool] { tools.filter { $0.source == .script } }
    nonisolated static let empty = PageToolSnapshot(tools: [], droppedCount: 0, nativeModelContextDetected: false)
}

struct PageToolCallResult: Codable, Equatable, Sendable {
    var json: String
    var value: JSONValue
    var byteCount: Int
    var durationMs: Double
}

enum PageToolCallFailureCode: String, Codable, Equatable, Sendable {
    case disabled, detached, invalidName, invalidArguments, notFound, timedOut, responseTooLarge, executionThrew
}

struct PageToolCallFailure: Error, LocalizedError, Codable, Equatable, Sendable {
    var code: PageToolCallFailureCode
    var message: String
    var thrownCode: String?
    var durationMs: Double
    var errorDescription: String? { message }
}

struct PageToolBindDescriptor: Equatable, Sendable {
    let bridgeSlot: String
    let bindToken: String
}

/// Injects the WebMCP `document.modelContext` / `navigator.modelContext` shim into `.page`
/// and script `WKContentWorld`s, pulls registered tool metadata, and invokes `execute` with
/// bounded timeout and response size.
@MainActor
final class PageToolBridge {
    nonisolated static let maxNameLength = 64
    nonisolated static let maxTitleCharacters = 200
    nonisolated static let maxDescriptionCharacters = 500
    nonisolated static let maxSchemaCharacters = 4_000
    nonisolated static let maxToolsPerPage = 30
    nonisolated static let defaultTimeout: TimeInterval = 20
    nonisolated static let defaultMaxResponseBytes = 2 * 1_024 * 1_024

    weak var webView: WKWebView?
    private(set) var scriptWorlds: [WKContentWorld]
    private(set) var ownedScriptWorlds: [String: WKContentWorld] = [:]
    var onEnabledChanged: (@MainActor (Bool) -> Void)?

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            syncUserScripts()
            onEnabledChanged?(isEnabled)
            let enabled = isEnabled
            Task { @MainActor [weak self] in await self?.syncLiveEnabledState(enabled) }
        }
    }

    private let bridgeSlot = "__wukong_ptb_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let bridgeSecret = UUID().uuidString
    private let bindToken = UUID().uuidString
    private var managedScripts: [ObjectIdentifier: WKUserScript] = [:]

    var bindDescriptor: PageToolBindDescriptor {
        PageToolBindDescriptor(bridgeSlot: bridgeSlot, bindToken: bindToken)
    }

    var enabledBindDescriptor: PageToolBindDescriptor? {
        isEnabled ? bindDescriptor : nil
    }

    private var allScriptWorlds: [WKContentWorld] {
        var result: [WKContentWorld] = []
        for id in ownedScriptWorlds.keys.sorted() {
            if let world = ownedScriptWorlds[id], !result.contains(where: { $0 === world }) {
                result.append(world)
            }
        }
        for world in scriptWorlds where !result.contains(where: { $0 === world }) {
            result.append(world)
        }
        return result
    }

    init(webView: WKWebView?, isEnabled: Bool = true, scriptWorlds: [WKContentWorld] = [AgentBridge.isolatedWorld]) {
        self.webView = webView
        self.isEnabled = isEnabled
        self.scriptWorlds = scriptWorlds
        if webView != nil {
            syncUserScripts()
        }
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
        managedScripts.removeAll()
        syncUserScripts()
    }

    func detachWebView() {
        syncManagedScripts(installing: false)
        managedScripts.removeAll()
        ownedScriptWorlds.removeAll()
        scriptWorlds = [AgentBridge.isolatedWorld]
        webView = nil
    }

    func detach() {
        detachWebView()
        onEnabledChanged = nil
    }

    func registerScriptWorld(_ world: WKContentWorld) {
        guard !scriptWorlds.contains(where: { $0 === world }) else { return }
        scriptWorlds.append(world)
        syncUserScripts()
    }

    func setOwnedScriptWorlds(_ worlds: [String: WKContentWorld]) {
        ownedScriptWorlds = worlds
    }

    func scriptWorldShimJS(forScriptID scriptID: String) -> String {
        guard isEnabled, ScriptStore.isValidScriptID(scriptID) else { return "" }
        return Self.shimSource(
            isIsolated: true,
            bridgeSlot: bridgeSlot,
            bridgeSecret: bridgeSecret,
            bindToken: bindToken,
            defaultOwner: scriptID
        )
    }

    func syncUserScripts() {
        syncManagedScripts(installing: isEnabled)
    }

    nonisolated static func isValidToolName(_ name: String) -> Bool {
        let utf8 = name.utf8
        guard (1...maxNameLength).contains(utf8.count) else { return false }
        return utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x5F || $0 == 0x2D
        }
    }

    nonisolated static func parsePrefixedName(_ prefixedName: String) -> (source: PageToolSource, ownerID: String?, name: String)? {
        if prefixedName.hasPrefix("site.") {
            let name = String(prefixedName.dropFirst(5))
            return isValidToolName(name) ? (.site, nil, name) : nil
        }
        if prefixedName.hasPrefix("script.") {
            let rest = prefixedName.dropFirst(7)
            guard let dot = rest.lastIndex(of: ".") else { return nil }
            let ownerID = String(rest[..<dot]), name = String(rest[rest.index(after: dot)...])
            return (ScriptStore.isValidScriptID(ownerID) && isValidToolName(name)) ? (.script, ownerID, name) : nil
        }
        return nil
    }

    func collectTools(pullTimeout: TimeInterval = 2.0) async -> PageToolSnapshot {
        guard isEnabled, webView != nil else { return .empty }
        var tools: [PageTool] = [], dropped = 0, nativeDetected = false
        for (world, source) in allScriptWorlds.map({ ($0, PageToolSource.script) }) + [(.page, .site)] {
            let pulled = await pullWorld(world, source: source, timeout: pullTimeout)
            nativeDetected = nativeDetected || pulled.nativeDetected
            dropped += pulled.droppedCount
            for tool in pulled.tools {
                if tools.count < Self.maxToolsPerPage { tools.append(tool) } else { dropped += 1 }
            }
        }
        return PageToolSnapshot(tools: tools, droppedCount: dropped, nativeModelContextDetected: nativeDetected)
    }

    func callTool(
        prefixedName: String, arguments: [String: JSONValue],
        timeout: TimeInterval = PageToolBridge.defaultTimeout, maxResponseBytes: Int = PageToolBridge.defaultMaxResponseBytes
    ) async -> Result<PageToolCallResult, PageToolCallFailure> {
        guard let data = try? SyncCoding.data(arguments), let json = String(data: data, encoding: .utf8) else {
            return .failure(PageToolCallFailure(code: .invalidArguments, message: "Arguments must be valid JSON.", durationMs: 0))
        }
        return await callTool(prefixedName: prefixedName, argumentsJSON: json, timeout: timeout, maxResponseBytes: maxResponseBytes)
    }

    func callTool(
        prefixedName: String, argumentsJSON: String = "{}",
        timeout: TimeInterval = PageToolBridge.defaultTimeout, maxResponseBytes: Int = PageToolBridge.defaultMaxResponseBytes
    ) async -> Result<PageToolCallResult, PageToolCallFailure> {
        guard let parsed = Self.parsePrefixedName(prefixedName) else {
            return .failure(PageToolCallFailure(code: .invalidName, message: "Invalid page tool name '\(prefixedName)'.", durationMs: 0))
        }
        return parsed.source == .site
            ? await callSiteTool(name: parsed.name, argumentsJSON: argumentsJSON, timeout: timeout, maxResponseBytes: maxResponseBytes)
            : await callScriptTool(scriptID: parsed.ownerID ?? "", name: parsed.name, argumentsJSON: argumentsJSON, timeout: timeout, maxResponseBytes: maxResponseBytes)
    }

    func callSiteTool(
        name: String, argumentsJSON: String = "{}",
        timeout: TimeInterval = PageToolBridge.defaultTimeout, maxResponseBytes: Int = PageToolBridge.defaultMaxResponseBytes
    ) async -> Result<PageToolCallResult, PageToolCallFailure> {
        guard Self.isValidToolName(name) else {
            return .failure(PageToolCallFailure(code: .invalidName, message: "Invalid tool name '\(name)'.", durationMs: 0))
        }
        return await executeInWorld(.page, ownerID: nil, name: name, argumentsJSON: argumentsJSON, timeout: timeout, maxResponseBytes: maxResponseBytes)
    }

    func callScriptTool(
        scriptID: String, name: String, argumentsJSON: String = "{}",
        timeout: TimeInterval = PageToolBridge.defaultTimeout, maxResponseBytes: Int = PageToolBridge.defaultMaxResponseBytes
    ) async -> Result<PageToolCallResult, PageToolCallFailure> {
        guard ScriptStore.isValidScriptID(scriptID), Self.isValidToolName(name) else {
            return .failure(PageToolCallFailure(code: .invalidName, message: "Invalid script tool '\(scriptID).\(name)'.", durationMs: 0))
        }
        guard isEnabled else { return .failure(PageToolCallFailure(code: .disabled, message: "Page tools are turned off.", durationMs: 0)) }
        guard webView != nil else { return .failure(PageToolCallFailure(code: .detached, message: "No web view attached.", durationMs: 0)) }
        let candidateWorlds: [WKContentWorld]
        if let owned = ownedScriptWorlds[scriptID] {
            candidateWorlds = [owned] + scriptWorlds.filter { $0 !== owned }
        } else {
            candidateWorlds = allScriptWorlds
        }
        var lastNotFound: PageToolCallFailure?
        for world in candidateWorlds {
            let outcome = await executeInWorld(world, ownerID: scriptID, name: name, argumentsJSON: argumentsJSON, timeout: timeout, maxResponseBytes: maxResponseBytes)
            if case .failure(let failure) = outcome, failure.code == .notFound { lastNotFound = failure; continue }
            return outcome
        }
        return .failure(lastNotFound ?? PageToolCallFailure(code: .notFound, message: "No tool named \(name) was registered.", durationMs: 0))
    }

    func clearScriptTools(scriptID: String) async {
        guard !scriptID.isEmpty, webView != nil else { return }
        var targetWorlds: [WKContentWorld] = []
        if let owned = ownedScriptWorlds[scriptID] { targetWorlds.append(owned) }
        for world in scriptWorlds where !targetWorlds.contains(where: { $0 === world }) { targetWorlds.append(world) }
        for world in targetWorlds { _ = await evalBridge(world: world, op: "clearOwner", extraArgs: ["owner": scriptID], timeout: 1.0) }
    }

    func clearAllScriptTools() async {
        guard webView != nil else { return }
        for world in allScriptWorlds { _ = await evalBridge(world: world, op: "clearAll", extraArgs: [:], timeout: 1.0) }
    }

    private func syncManagedScripts(installing: Bool) {
        guard let webView else { managedScripts.removeAll(); return }
        if !installing, managedScripts.isEmpty { return }
        let controller = webView.configuration.userContentController
        let existingOthers = controller.userScripts.filter { managedScripts[ObjectIdentifier($0)] == nil }
        controller.removeAllUserScripts()
        managedScripts.removeAll()
        if installing {
            let specs: [(Bool, String, WKContentWorld)] = [(false, "", .page)] + scriptWorlds.map { (true, bindToken, $0) }
            for (isolated, token, world) in specs {
                let script = WKUserScript(
                    source: Self.shimSource(isIsolated: isolated, bridgeSlot: bridgeSlot, bridgeSecret: bridgeSecret, bindToken: token),
                    injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world
                )
                managedScripts[ObjectIdentifier(script)] = script
                controller.addUserScript(script)
            }
        }
        for script in existingOthers { controller.addUserScript(script) }
    }

    private func syncLiveEnabledState(_ enabled: Bool) async {
        guard webView != nil else { return }
        let op = enabled ? "enable" : "disable"
        for world in [WKContentWorld.page] + allScriptWorlds { _ = await evalBridge(world: world, op: op, extraArgs: [:], timeout: 1.0) }
    }

    private func pullWorld(_ world: WKContentWorld, source: PageToolSource, timeout: TimeInterval) async -> (tools: [PageTool], droppedCount: Int, nativeDetected: Bool) {
        guard let dict = await evalBridge(world: world, op: "pull", extraArgs: [:], timeout: timeout) else { return ([], 0, false) }
        let nativePresent = (dict["nativePresent"] as? Bool) ?? false
        var parsed: [PageTool] = [], dropped = 0
        for item in (dict["tools"] as? [[String: Any]]) ?? [] {
            guard let name = item["name"] as? String, Self.isValidToolName(name) else { dropped += 1; continue }
            let ownerID: String?, prefixedName: String
            if source == .site {
                ownerID = nil; prefixedName = "site.\(name)"
            } else {
                guard let rawOwner = item["owner"] as? String, ScriptStore.isValidScriptID(rawOwner) else { dropped += 1; continue }
                ownerID = rawOwner; prefixedName = "script.\(rawOwner).\(name)"
            }
            let rawTitle = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.maxTitleCharacters)) }
            let description = String(((item["description"] as? String) ?? "").prefix(Self.maxDescriptionCharacters))
            var schemaValue: JSONValue?, schemaJSON: String?
            if let rawSchema = item["schemaJSON"] as? String, rawSchema != "__unserializable__",
               rawSchema.count <= Self.maxSchemaCharacters,
               let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(rawSchema.utf8)), !decoded.isNull {
                schemaValue = decoded; schemaJSON = rawSchema
            }
            let rawAnn = item["annotations"] as? [String: Any]
            parsed.append(PageTool(
                source: source, ownerID: ownerID, name: name, prefixedName: prefixedName, title: title, description: description,
                inputSchema: schemaValue, inputSchemaJSON: schemaJSON,
                annotations: PageToolAnnotations(
                    readOnlyHint: (rawAnn?["readOnlyHint"] as? Bool) ?? false,
                    untrustedContentHint: (rawAnn?["untrustedContentHint"] as? Bool) ?? false,
                    consequentialHint: (rawAnn?["consequentialHint"] as? Bool) ?? false
                )
            ))
        }
        return (parsed, dropped, nativePresent)
    }

    private func executeInWorld(
        _ world: WKContentWorld, ownerID: String?, name: String, argumentsJSON: String, timeout: TimeInterval, maxResponseBytes: Int
    ) async -> Result<PageToolCallResult, PageToolCallFailure> {
        guard isEnabled else { return .failure(PageToolCallFailure(code: .disabled, message: "Page tools are turned off.", durationMs: 0)) }
        guard webView != nil else { return .failure(PageToolCallFailure(code: .detached, message: "No web view attached.", durationMs: 0)) }
        guard (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8), options: [.fragmentsAllowed])) != nil else {
            return .failure(PageToolCallFailure(code: .invalidArguments, message: "Arguments must be valid JSON.", durationMs: 0))
        }
        let clampedTimeoutMs = max(1, Int((timeout * 1_000).rounded()))
        let start = CFAbsoluteTimeGetCurrent()
        let dict = await evalBridge(
            world: world, op: "call",
            extraArgs: ["owner": ownerID ?? "", "name": name, "argsJSON": argumentsJSON, "timeoutMs": clampedTimeoutMs, "maxBytes": maxResponseBytes],
            timeout: max(0.05, timeout) + 1.5
        )
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1_000
        guard let dict else {
            return .failure(PageToolCallFailure(code: .timedOut, message: "Tool '\(name)' timed out.", durationMs: elapsedMs))
        }
        if (dict["ok"] as? Bool) == true, let json = dict["json"] as? String {
            let bytes = Data(json.utf8).count
            guard bytes <= maxResponseBytes else {
                return .failure(PageToolCallFailure(code: .responseTooLarge, message: "Tool '\(name)' returned \(bytes) bytes (limit \(maxResponseBytes)).", durationMs: elapsedMs))
            }
            guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
                return .failure(PageToolCallFailure(code: .executionThrew, message: "Tool '\(name)' returned invalid JSON.", durationMs: elapsedMs))
            }
            return .success(PageToolCallResult(json: json, value: decoded, byteCount: bytes, durationMs: elapsedMs))
        }
        let mappedCode: PageToolCallFailureCode = switch (dict["code"] as? String) ?? "threw" {
        case "not_found": .notFound
        case "timeout": .timedOut
        case "response_too_large": .responseTooLarge
        case "disabled": .disabled
        default: .executionThrew
        }
        return .failure(PageToolCallFailure(
            code: mappedCode, message: (dict["error"] as? String) ?? "Tool '\(name)' failed.",
            thrownCode: dict["thrownCode"] as? String, durationMs: elapsedMs
        ))
    }

    private func evalBridge(world: WKContentWorld, op: String, extraArgs: [String: Any], timeout: TimeInterval) async -> [String: Any]? {
        guard let webView else { return nil }
        let args: [String: Any] = ["slot": bridgeSlot, "secret": bridgeSecret, "op": op, "args": extraArgs]
        let js = "const fn = window[slot]; return typeof fn === 'function' ? await fn(secret, op, args) : { ok: false, code: 'not_found', tools: [] };"
        return await withTaskGroup(of: [String: Any]??.self) { group in
            group.addTask { @MainActor in (try? await webView.callAsyncJavaScript(js, arguments: args, in: nil, contentWorld: world)) as? [String: Any] }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000)); return .some(nil) }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    static func shimSource(
        isIsolated: Bool,
        bridgeSlot: String,
        bridgeSecret: String,
        bindToken: String,
        defaultOwner: String? = nil
    ) -> String {
        let slotJSON = UserScript.encodeSingleLineJSONString(bridgeSlot)
        let secretJSON = UserScript.encodeSingleLineJSONString(bridgeSecret)
        let bindJSON = UserScript.encodeSingleLineJSONString(bindToken)
        let defaultOwnerJSON = defaultOwner.map(UserScript.encodeSingleLineJSONString) ?? "null"
        let isolatedSetup = isIsolated ? "try { _def(window, \"modelContext\", { get: () => rootCtx, enumerable: false, configurable: false }); } catch (_) {}" : ""
        let bindBranch = isIsolated ? "if (secret === BIND && op === \"bind\") return enabled && typeof p === \"string\" && p.length > 0 ? makeContext(p) : null;" : ""
        return """
        (() => {
          const SLOT = \(slotJSON), SECRET = \(secretJSON), BIND = \(bindJSON), _def = Object.defineProperty;
          if (Object.prototype.hasOwnProperty.call(window, SLOT)) return;
          if ("modelContext" in document && document.modelContext) {
            const nat = (s, op) => s === SECRET && op === "pull" ? { nativePresent: true, tools: [] } : { ok: false, code: "not_found" };
            try { _def(window, SLOT, { value: nat, configurable: false, enumerable: false, writable: false }); } catch (_) {}
            return;
          }
          const _Promise = Promise, _then = Promise.prototype.then, _setTimeout = window.setTimeout.bind(window), _clearTimeout = window.clearTimeout.bind(window);
          const _AC = AbortController, _abort = AbortController.prototype.abort, _str = JSON.stringify, _parse = JSON.parse;
          const _enc = new TextEncoder(), _encode = TextEncoder.prototype.encode.bind(_enc), _TypeErr = TypeError, _Err = Error;
          const entries = new Map(), _get = Map.prototype.get.bind(entries), _set = Map.prototype.set.bind(entries);
          const _del = Map.prototype.delete.bind(entries), _forEach = Map.prototype.forEach.bind(entries), _clear = Map.prototype.clear.bind(entries);
          const _res = (v) => new _Promise((r) => r(v)), _rej = (e) => new _Promise((_, r) => r(e));
          let enabled = true;
          const makeContext = (owner) => ({
            registerTool(t, opts) {
              if (!t || typeof t !== "object" || typeof t.name !== "string" || !t.name || typeof t.execute !== "function") return _rej(new _TypeErr("Invalid WebMCP tool"));
              if (!enabled) return _res(undefined);
              const sig = opts && typeof opts === "object" ? opts.signal : null;
              if (sig && sig.aborted) return _res(undefined);
              let schemaJSON = null;
              if (t.inputSchema !== undefined && t.inputSchema !== null) {
                try { const s = _str(t.inputSchema); schemaJSON = typeof s === "string" ? s : "__unserializable__"; } catch (_) { schemaJSON = "__unserializable__"; }
              }
              const ann = t.annotations && typeof t.annotations === "object"
                ? { readOnlyHint: Boolean(t.annotations.readOnlyHint), untrustedContentHint: Boolean(t.annotations.untrustedContentHint), consequentialHint: Boolean(t.annotations.consequentialHint) } : null;
              const key = (owner || "") + "\\0" + t.name;
              const rec = { owner: owner || null, name: String(t.name), title: t.title != null ? String(t.title) : null, description: t.description != null ? String(t.description) : "", inputSchema: t.inputSchema !== undefined ? t.inputSchema : null, outputSchema: t.outputSchema !== undefined ? t.outputSchema : null, schemaJSON, annotations: ann, execute: t.execute };
              _set(key, rec);
              if (sig && typeof sig.addEventListener === "function") { try { sig.addEventListener("abort", () => { if (_get(key) === rec) _del(key); }, { once: true }); } catch (_) {} }
              return _res(undefined);
            },
            getTools() {
              const out = [];
              _forEach((r) => { if ((r.owner || null) === (owner || null)) out[out.length] = { name: r.name, title: r.title, description: r.description, inputSchema: r.inputSchema, outputSchema: r.outputSchema, annotations: r.annotations }; });
              return _res(out);
            }
          });
          const rootCtx = makeContext(\(defaultOwnerJSON)), desc = { get: () => rootCtx, enumerable: true, configurable: false };
          for (const tgt of [Document.prototype, Navigator.prototype, document, navigator]) { try { _def(tgt, "modelContext", desc); } catch (_) {} }
          \(isolatedSetup)
          const dispatch = (secret, op, p) => {
            \(bindBranch)
            if (secret !== SECRET) return null;
            if (op === "disable") { enabled = false; _clear(); return { ok: true }; }
            if (op === "enable") { enabled = true; return { ok: true }; }
            if (op === "clearAll") { _clear(); return { ok: true }; }
            if (op === "clearOwner") {
              const tgt = p && typeof p.owner === "string" ? p.owner : "", keys = [];
              if (tgt) { _forEach((r, k) => { if (r.owner === tgt) keys[keys.length] = k; }); for (let i = 0; i < keys.length; i++) _del(keys[i]); }
              return { ok: true };
            }
            if (op === "pull") {
              if (!enabled) return { nativePresent: false, tools: [] };
              const list = [];
              _forEach((r) => { list[list.length] = { owner: r.owner, name: r.name, title: r.title, description: r.description, schemaJSON: r.schemaJSON, annotations: r.annotations }; });
              return { nativePresent: false, tools: list };
            }
            if (op === "call") return (async () => {
              if (!enabled) return { ok: false, code: "disabled", error: "Page tools are turned off." };
              const owner = p && typeof p.owner === "string" ? p.owner : "", name = p && typeof p.name === "string" ? p.name : "";
              const argsJSON = p && typeof p.argsJSON === "string" ? p.argsJSON : "{}", timeoutMs = p && typeof p.timeoutMs === "number" ? p.timeoutMs : 20000, maxBytes = p && typeof p.maxBytes === "number" ? p.maxBytes : 2097152;
              const rec = _get(owner + "\\0" + name);
              if (!rec) return { ok: false, code: "not_found", error: "No tool named " + name + " was registered." };
              const ac = new _AC(); let timer = null, timedOut = false;
              try {
                const parsedArgs = argsJSON ? _parse(argsJSON) : {};
                const val = await new _Promise((resolve, reject) => {
                  timer = _setTimeout(() => { timedOut = true; try { _abort.call(ac); } catch (_) {} reject(new _Err("__WUKONG_TIMEOUT__")); }, timeoutMs);
                  try {
                    const out = rec.execute(parsedArgs, { signal: ac.signal });
                    if (out instanceof _Promise) _then.call(out, resolve, reject);
                    else if (out && (typeof out === "object" || typeof out === "function") && typeof out.then === "function") out.then(resolve, reject);
                    else resolve(out);
                  } catch (err) { reject(err); }
                });
                const rawJSON = val === undefined ? "null" : _str(val), json = typeof rawJSON === "string" ? rawJSON : "null";
                if (json.length > maxBytes) return { ok: false, code: "response_too_large", error: "Response exceeded " + maxBytes + " bytes." };
                const bytes = _encode(json).byteLength;
                return bytes > maxBytes ? { ok: false, code: "response_too_large", error: "Response exceeded " + maxBytes + " bytes." } : { ok: true, json, bytes };
              } catch (err) {
                if (timedOut) return { ok: false, code: "timeout", error: "Tool '" + name + "' timed out." };
                return { ok: false, code: "threw", error: err && (err.message || err.stack) ? String(err.message || err.stack) : String(err), thrownCode: err && typeof err === "object" && typeof err.code === "string" ? String(err.code) : null };
              } finally { if (timer !== null) _clearTimeout(timer); }
            })();
            return null;
          };
          try { _def(window, SLOT, { value: dispatch, configurable: false, enumerable: false, writable: false }); } catch (_) {}
        })();
        """
    }
}
