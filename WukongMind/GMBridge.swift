import Foundation
import Observation
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
    let requestLimiter = ScriptRequestLimiter()
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

struct ScriptMenuCommand: Identifiable, Equatable, Sendable {
    let id: String
    let scriptID: String
    let title: String
}

/// Manages per-script `WKContentWorld`s (`WukongScript.<id>`), per-script
/// `WKScriptMessageHandlerWithReply` registration, Swift-side `@grant` checks,
/// and the `GM_*` / `GM.*` runtime surface.
@MainActor
@Observable
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
    private static let pageWorldPowerFunctions = [
        "GM_getValue", "GM_setValue", "GM_deleteValue", "GM_listValues",
        "GM_xmlhttpRequest", "GM_registerMenuCommand", "GM_unregisterMenuCommand", "GM_ai",
    ]

    static func hasAnyValueReadGrant(_ grants: [String]) -> Bool {
        grants.contains("GM_getValue") || grants.contains("GM_listValues")
            || grants.contains("GM.getValue") || grants.contains("GM.listValues")
    }

    @ObservationIgnored let valuesStore: ScriptValuesStore
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var httpClient: AgentHTTPClient = AgentHTTPClient()
    @ObservationIgnored var aiService: GMAiService?
    @ObservationIgnored var auditLog: AuditLog?
    @ObservationIgnored var resolveScript: ((String) -> UserScript?)?
    @ObservationIgnored var onValuesMutated: ((String) -> Void)?
    @ObservationIgnored var onScriptError: ((String, [String: Any]) -> Void)?
    @ObservationIgnored var onScriptLoadClean: ((String, [String: Any]) -> Void)?
    @ObservationIgnored var onPageScriptReport: (([String: Any]) -> Void)?
    @ObservationIgnored private var registeredHandlers: [String: GMScriptReplyHandler] = [:]
    @ObservationIgnored private var pageReportHandler: GMPageReplyHandler?
    @ObservationIgnored private var inFlightRequests: [String: Task<Void, Never>] = [:]
    private var menuCommandsByScriptID: [String: [ScriptMenuCommand]] = [:]
    @ObservationIgnored private var activeDocTokenByScriptID: [String: String] = [:]
    @ObservationIgnored private var retiredDocTokens: Set<String> = []

    init(valuesStore: ScriptValuesStore) {
        self.valuesStore = valuesStore
    }

    func menuCommands(for scriptID: String) -> [ScriptMenuCommand] { menuCommandsByScriptID[scriptID] ?? [] }

    func invokeMenuCommand(scriptID: String, commandID: String) {
        Task { @MainActor [weak self] in _ = await self?.invokeMenuCommandAsync(scriptID: scriptID, commandID: commandID) }
    }

    @discardableResult
    func invokeMenuCommandAsync(scriptID: String, commandID: String) async -> Bool {
        guard let webView, let script = resolveScript?(scriptID), !script.runsInPageWorld,
              let world = registeredHandlers[scriptID]?.expectedWorld else { return false }
        let js = "return typeof window.__wukongInvokeMenuCommand === 'function' ? window.__wukongInvokeMenuCommand(commandId) : { ok: false };"
        guard let res = (try? await webView.callAsyncJavaScript(js, arguments: ["commandId": commandID], in: nil, contentWorld: world)) as? [String: Any] else {
            return false
        }
        if let err = res["error"] as? String, !err.isEmpty {
            if (res["reported"] as? Bool) != true {
                onScriptError?(scriptID, ["message": err, "afterLoad": true, "url": webView.url?.absoluteString ?? ""])
            }
            return false
        }
        return (res["ok"] as? Bool) == true
    }

    func clearMenuCommands(for scriptID: String) {
        cancelRequests(for: scriptID)
        if let token = activeDocTokenByScriptID.removeValue(forKey: scriptID) { rememberRetiredToken(token) }
        menuCommandsByScriptID.removeValue(forKey: scriptID)
    }

    func clearAllMenuCommands() {
        cancelAllRequests()
        activeDocTokenByScriptID.values.forEach { rememberRetiredToken($0) }
        activeDocTokenByScriptID.removeAll()
        if !menuCommandsByScriptID.isEmpty { menuCommandsByScriptID.removeAll() }
    }

    private func rememberRetiredToken(_ token: String) {
        if retiredDocTokens.count > 256 { retiredDocTokens.removeAll() }
        retiredDocTokens.insert(token)
    }

    func cancelRequests(for scriptID: String) {
        let prefix = "\(scriptID):"
        for key in inFlightRequests.keys where key.hasPrefix(prefix) {
            inFlightRequests.removeValue(forKey: key)?.cancel()
        }
    }

    func cancelAllRequests() {
        let tasks = Array(inFlightRequests.values)
        inFlightRequests.removeAll()
        tasks.forEach { $0.cancel() }
    }

    func syncHandlers(
        for scriptIDs: Set<String>,
        worlds: [String: WKContentWorld] = [:],
        on controller: WKUserContentController
    ) {
        for id in Set(registeredHandlers.keys).subtracting(scriptIDs) {
            if let handler = registeredHandlers.removeValue(forKey: id) {
                controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: handler.expectedWorld)
            }
            clearMenuCommands(for: id)
        }
        for id in scriptIDs where registeredHandlers[id] == nil {
            ensureHandlerRegistered(for: id, world: worlds[id], on: controller)
        }
        ensurePageHandlerRegistered(on: controller)
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
        webView = nil
        clearAllMenuCommands()
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

    fileprivate static func trustedPageURL(origin: WKSecurityOrigin, webViewURL: URL?, frameURL: URL?) -> URL? {
        let proto = origin.protocol.lowercased()
        let host = ConnectHostPolicy.normalizeHost(origin.host)
        guard (proto == "http" || proto == "https"), !host.isEmpty else { return nil }
        for candidate in [webViewURL, frameURL].compactMap({ $0 }) {
            if candidate.scheme?.lowercased() == proto, ConnectHostPolicy.extractHost(from: candidate) == host {
                return candidate
            }
        }
        let hostPart = host.contains(":") ? "[\(host)]" : host
        let portPart = origin.port > 0 ? ":\(origin.port)" : ""
        return URL(string: "\(proto)://\(hostPart)\(portPart)/")
    }

    private func requireActiveGrantedScript(
        _ scriptID: String,
        grants accepted: [String],
        reportName: String,
        replyHandler: (Any?, String?) -> Void
    ) -> UserScript? {
        guard let script = resolveScript?(scriptID), !script.runsInPageWorld else {
            replyHandler(nil, "Script is not active.")
            return nil
        }
        guard accepted.contains(where: { script.metadata.grants.contains($0) }) else {
            let msg = GMBridgeError.ungranted(reportName).errorDescription ?? "Missing grant"
            onScriptError?(scriptID, ["message": msg, "kind": "api"])
            replyHandler(nil, msg)
            return nil
        }
        return script
    }

    fileprivate func handleMessage(
        scriptID: String,
        body: Any,
        isMainFrame: Bool,
        world: WKContentWorld,
        expectedWorld: WKContentWorld,
        pageURL: URL?,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard isMainFrame, world === expectedWorld else {
            replyHandler(nil, "Blocked GM bridge call from untrusted frame or world.")
            return
        }
        guard let payload = body as? [String: Any], let action = payload["action"] as? String else {
            replyHandler(nil, "Invalid GM bridge message.")
            return
        }
        switch action {
        case "scriptError":
            onScriptError?(scriptID, payload)
            replyHandler(["ok": true], nil)
        case "scriptLoadClean":
            onScriptLoadClean?(scriptID, payload)
            replyHandler(["ok": true], nil)
        case "setValue":
            guard requireActiveGrantedScript(scriptID, grants: ["GM_setValue", "GM.setValue"], reportName: "GM_setValue", replyHandler: replyHandler) != nil else { return }
            guard let key = payload["key"] as? String, let rawJSON = payload["rawJSON"] as? String else {
                replyHandler(nil, GMBridgeError.nonSerializableValue.errorDescription)
                return
            }
            do {
                try valuesStore.setValue(rawJSON: rawJSON, forKey: key, scriptID: scriptID)
                onValuesMutated?(scriptID)
                replyHandler(["ok": true], nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        case "deleteValue":
            guard requireActiveGrantedScript(scriptID, grants: ["GM_deleteValue", "GM.deleteValue"], reportName: "GM_deleteValue", replyHandler: replyHandler) != nil else { return }
            guard let key = payload["key"] as? String else { replyHandler(["ok": true], nil); return }
            do {
                try valuesStore.deleteValue(forKey: key, scriptID: scriptID)
                onValuesMutated?(scriptID)
                replyHandler(["ok": true], nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        case "registerMenuCommand":
            guard requireActiveGrantedScript(scriptID, grants: ["GM_registerMenuCommand"], reportName: "GM_registerMenuCommand", replyHandler: replyHandler) != nil else { return }
            let docToken = (payload["docToken"] as? String) ?? ""
            if !docToken.isEmpty, retiredDocTokens.contains(docToken) { replyHandler(["ok": false], nil); return }
            if !docToken.isEmpty, let existingToken = activeDocTokenByScriptID[scriptID], existingToken != docToken {
                rememberRetiredToken(existingToken)
                menuCommandsByScriptID.removeValue(forKey: scriptID)
            }
            if !docToken.isEmpty { activeDocTokenByScriptID[scriptID] = docToken }
            guard let cmdID = payload["id"] as? String, !cmdID.isEmpty,
                  let title = (payload["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                replyHandler(["ok": false], nil)
                return
            }
            var list = menuCommandsByScriptID[scriptID] ?? []
            list.removeAll { $0.id == cmdID }
            list.append(ScriptMenuCommand(id: cmdID, scriptID: scriptID, title: title))
            menuCommandsByScriptID[scriptID] = list
            replyHandler(["ok": true], nil)
        case "unregisterMenuCommand":
            guard requireActiveGrantedScript(scriptID, grants: ["GM_registerMenuCommand", "GM_unregisterMenuCommand"], reportName: "GM_registerMenuCommand", replyHandler: replyHandler) != nil else { return }
            if let cmdID = payload["id"] as? String, var list = menuCommandsByScriptID[scriptID] {
                list.removeAll { $0.id == cmdID }
                menuCommandsByScriptID[scriptID] = list.isEmpty ? nil : list
            }
            replyHandler(["ok": true], nil)
        case "clearMenuCommands":
            let nextToken = (payload["docToken"] as? String) ?? ""
            if let existing = activeDocTokenByScriptID[scriptID], existing != nextToken {
                rememberRetiredToken(existing)
                menuCommandsByScriptID.removeValue(forKey: scriptID)
            } else if nextToken.isEmpty {
                menuCommandsByScriptID.removeValue(forKey: scriptID)
            }
            if !nextToken.isEmpty, !retiredDocTokens.contains(nextToken) {
                activeDocTokenByScriptID[scriptID] = nextToken
            }
            replyHandler(["ok": true], nil)
        case "abortXmlhttpRequest":
            if let requestID = payload["requestId"] as? String, !requestID.isEmpty {
                inFlightRequests.removeValue(forKey: "\(scriptID):\(requestID)")?.cancel()
            }
            replyHandler(["ok": true], nil)
        case "xmlhttpRequest":
            handleXMLHTTPRequest(scriptID: scriptID, payload: payload, pageURL: pageURL, replyHandler: replyHandler)
        case "gmAi", "gmAiMap":
            handleGMAi(scriptID: scriptID, isMap: action == "gmAiMap", payload: payload, pageURL: pageURL, replyHandler: replyHandler)
        default:
            replyHandler(nil, GMBridgeError.unsupported(action).errorDescription)
        }
    }

    private func handleGMAi(
        scriptID: String, isMap: Bool, payload: [String: Any], pageURL: URL?,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let script = requireActiveGrantedScript(scriptID, grants: ["GM_ai"], reportName: "GM_ai", replyHandler: replyHandler) else { return }
        guard let service = aiService else {
            replyHandler(["ok": false, "code": GMAiError.Code.noModel.rawValue, "message": "Script AI service is unavailable."], nil)
            return
        }
        let requestID = (payload["requestId"] as? String) ?? UUID().uuidString
        let docToken = (payload["docToken"] as? String) ?? ""
        let pageKey = "\(UInt(bitPattern: ObjectIdentifier(self)))|\(docToken)"
        let pageURLString = pageURL?.absoluteString, taskKey = "\(scriptID):\(requestID)"
        let formatMode = payload["formatMode"] as? String, schemaJSON = payload["schemaJSON"] as? String
        let prompt = (payload["prompt"] as? String) ?? "", instruction = (payload["instruction"] as? String) ?? ""
        let rawItems = payload["items"] as? [[String: Any]]

        inFlightRequests[taskKey] = Task { @MainActor [weak self] in
            defer { self?.inFlightRequests.removeValue(forKey: taskKey) }
            do {
                let format = try GMAiFormat.parse(mode: formatMode, schemaJSON: schemaJSON)
                let value: JSONValue
                if isMap {
                    guard let rawItems else { throw GMAiError(.invalidOutput, "GM_ai.map items must be an array of {id, text} objects.") }
                    let items = try rawItems.map { raw -> GMAiMapItem in
                        guard let id = raw["id"] as? String, !id.isEmpty else {
                            throw GMAiError(.invalidOutput, "Each GM_ai.map item must have a non-empty id.")
                        }
                        return GMAiMapItem(id: id, text: (raw["text"] as? String) ?? "")
                    }
                    value = .object(try await service.map(script: script, pageKey: pageKey, pageURL: pageURLString, items: items, instruction: instruction, format: format))
                } else {
                    value = try await service.call(script: script, pageKey: pageKey, pageURL: pageURLString, prompt: prompt, format: format)
                }
                replyHandler(["ok": true, "rawJSON": GMAiFormat.encodeJSON(value)], nil)
            } catch let aiErr as GMAiError {
                replyHandler(["ok": false, "code": aiErr.code.rawValue, "message": aiErr.message], nil)
            } catch is CancellationError {
                replyHandler(["ok": false, "code": GMAiError.Code.provider.rawValue, "message": "Cancelled."], nil)
            } catch {
                replyHandler(["ok": false, "code": GMAiError.Code.provider.rawValue, "message": error.localizedDescription], nil)
            }
        }
    }

    private func handleXMLHTTPRequest(
        scriptID: String,
        payload: [String: Any],
        pageURL: URL?,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let script = requireActiveGrantedScript(
            scriptID, grants: ["GM_xmlhttpRequest", "GM.xmlHttpRequest"],
            reportName: "GM_xmlhttpRequest", replyHandler: replyHandler
        ) else { return }
        let requestID = (payload["requestId"] as? String) ?? UUID().uuidString
        let rawURL = (payload["url"] as? String) ?? ""
        let rawMethod = ((payload["method"] as? String) ?? "GET").trimmingCharacters(in: .whitespacesAndNewlines)
        let method = rawMethod.isEmpty ? "GET" : rawMethod.uppercased()
        let timeoutMs = (payload["timeoutMs"] as? NSNumber)?.doubleValue ?? 0
        let timeoutSec = timeoutMs > 0 ? min(timeoutMs / 1000.0, AgentHTTPClient.maxScriptTimeout) : AgentHTTPClient.defaultScriptTimeout
        var headers: [String: String] = [:]
        if let rawHeaders = payload["headers"] as? [String: Any] {
            for (k, v) in rawHeaders { headers[k] = String(describing: v) }
        }

        let startTime = Date(), client = httpClient, log = auditLog
        let scriptName = script.name, connectRules = script.metadata.connectHosts, pageURLString = pageURL?.absoluteString
        let recordAudit: (String, Int?, Bool, String) -> Void = { loggedURL, status, isError, summary in
            let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
            log?.append(.scriptRequest(
                scriptID: scriptID, scriptName: scriptName, time: startTime,
                method: method, url: loggedURL, status: status, pageURL: pageURLString,
                durationMs: elapsedMs, isError: isError, summary: summary
            ))
        }

        guard let parsedURL = URL(string: rawURL), !rawURL.isEmpty else {
            let errMsg = "GM_xmlhttpRequest requires a valid http or https URL."
            do {
                try client.scriptLimiter.acquire(scriptID: scriptID)
                client.scriptLimiter.release(scriptID: scriptID)
                recordAudit(rawURL, nil, true, errMsg)
                replyHandler(["ok": false, "kind": "error", "error": errMsg, "finalUrl": rawURL], nil)
            } catch let limitErr as ScriptHTTPError {
                replyHandler(["ok": false, "kind": "error", "error": limitErr.message, "finalUrl": rawURL], nil)
            } catch {
                replyHandler(["ok": false, "kind": "error", "error": errMsg, "finalUrl": rawURL], nil)
            }
            return
        }

        let taskKey = "\(scriptID):\(requestID)"
        let req = ScriptHTTPRequest(
            scriptID: scriptID, url: parsedURL, method: method, headers: headers,
            body: payload["data"] as? String, timeout: timeoutSec,
            anonymous: (payload["anonymous"] as? Bool) ?? false,
            connect: connectRules, pageURL: pageURL, useEnvironmentPageURL: false
        )
        inFlightRequests[taskKey] = Task { @MainActor [weak self] in
            defer { self?.inFlightRequests.removeValue(forKey: taskKey) }
            let target = parsedURL.absoluteString
            do {
                let response = try await client.sendScriptRequest(req)
                recordAudit(target, response.status, false, "HTTP \(response.status)")
                replyHandler([
                    "ok": true, "status": response.status, "statusText": Self.httpStatusText(for: response.status),
                    "responseText": String(decoding: response.data, as: UTF8.self),
                    "responseHeaders": Self.formatResponseHeaders(response.headers),
                    "finalUrl": response.finalURL.absoluteString,
                ], nil)
            } catch is CancellationError {
                recordAudit(target, nil, true, "Aborted")
                replyHandler(["ok": false, "kind": "abort", "error": "Request aborted", "finalUrl": target], nil)
            } catch let scriptErr as ScriptHTTPError {
                if scriptErr.kind != .limit {
                    recordAudit(target, nil, true, scriptErr.message)
                }
                replyHandler([
                    "ok": false,
                    "kind": scriptErr.kind == .timeout ? "timeout" : "error",
                    "errorKind": scriptErr.kind == .blocked ? "api" : "script",
                    "error": scriptErr.message,
                    "finalUrl": target,
                ], nil)
            } catch {
                recordAudit(target, nil, true, error.localizedDescription)
                replyHandler(["ok": false, "kind": "error", "error": error.localizedDescription, "finalUrl": target], nil)
            }
        }
    }

    private nonisolated static func formatResponseHeaders(_ headers: [String: String]) -> String {
        headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { "\($0.key): \($0.value)\r\n" }.joined()
    }

    private nonisolated static let statusReasons: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
        301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
        307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request",
        401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
        409: "Conflict", 422: "Unprocessable Content", 429: "Too Many Requests",
        500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
    ]

    private nonisolated static func httpStatusText(for status: Int) -> String {
        statusReasons[status] ?? HTTPURLResponse.localizedString(forStatusCode: status)
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
        let idJSON = UserScript.encodeSingleLineJSONString(script.id)
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
          const OWNED_SCRIPT_ID = \(idJSON);
          const makeDocToken = () => Math.random().toString(36).slice(2) + "-" + Date.now();
          let docToken = makeDocToken();
          const resolvePostFn = () => {
            const mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
            return mh && typeof mh.postMessage === "function" ? mh.postMessage.bind(mh) : null;
          };
          let cachedPostFn = resolvePostFn();
          const postMsg = (payload) => {
            const fn = resolvePostFn() || cachedPostFn;
            return fn ? fn(payload) : Promise.reject(new Error("GM bridge unavailable"));
          };
          const origSetTimeout = window.setTimeout.bind(window), origSetInterval = window.setInterval.bind(window);
          const origRAF = typeof window.requestAnimationFrame === "function" ? window.requestAnimationFrame.bind(window) : null;
          const origAddEL = EventTarget.prototype.addEventListener, origRemEL = EventTarget.prototype.removeEventListener;
          const values = new Map(), sheets = new Set(), menuCallbacks = new Map();
          const origLog = console.log.bind(console), enc = new TextEncoder();
          const reportedErrors = new WeakSet(), listenerMap = new WeakMap();
          let seeded = false, grants = new Set(), currentInfo = Object.freeze({}), logPrefix = "";
          let nextMenuCmdId = 0, nextReqId = 0, currentLoadId = "", mainLoadDepth = 0;

          const freezeInfo = (raw) => {
            if (raw && raw.script) {
              if (Array.isArray(raw.script.matches)) Object.freeze(raw.script.matches);
              if (Array.isArray(raw.script.grant)) Object.freeze(raw.script.grant);
              Object.freeze(raw.script);
            }
            return Object.freeze(raw || {});
          };
          const reconfigure = (nextGrants, nextInfo, nextName, allowSeed, rawSeed) => {
            cachedPostFn = resolvePostFn() || cachedPostFn;
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
          window.__wukongClearGMMenuCommands = (notifyHost) => {
            menuCallbacks.clear();
            docToken = makeDocToken();
            if (notifyHost) postMsg({ action: "clearMenuCommands", docToken }).catch(() => {});
          };
          window.__wukongInvokeMenuCommand = (id) => {
            if (!window.__wukongScriptsGlobalEnabled) return { ok: false };
            if (window.__wukongDisabledScriptIDs && window.__wukongDisabledScriptIDs[OWNED_SCRIPT_ID]) return { ok: false };
            const fn = menuCallbacks.get(String(id));
            if (typeof fn !== "function") return { ok: false };
            try {
              const out = fn();
              if (out && typeof out.then === "function") out.then(null, reportAsyncErr);
              return { ok: true };
            } catch (err) {
              const msg = reportCaught(err, undefined, true);
              return { ok: false, reported: true, error: msg };
            }
          };
          window.__wukongPostGM = (msg) => postMsg(msg);
          window.__wukongEnterMainLoad = (lid) => { if (lid) currentLoadId = String(lid); mainLoadDepth++; };
          window.__wukongLeaveMainLoad = () => { if (mainLoadDepth > 0) mainLoadDepth--; };
          const serviceCodes = new Set(["provider_error", "no_model", "rate_limited", "disabled", "cancelled"]);
          const formatErr = (err) => {
            let kind = "script", message = "Unknown userscript error", line = 0, stack = "";
            if (err && typeof err === "object") {
              if (err.__wukongErrorKind === "service" || err.name === "GMAiError" || (typeof err.code === "string" && serviceCodes.has(err.code))) kind = "service";
              else if (err.__wukongErrorKind === "api") kind = "api";
              const rawMsg = err.message != null ? String(err.message) : "";
              const errName = typeof err.name === "string" ? err.name : "";
              if (errName && errName !== "Error" && errName !== "GMAiError" && rawMsg && !rawMsg.startsWith(errName + ":")) message = errName + ": " + rawMsg;
              else message = rawMsg || String(err);
              if (typeof err.line === "number" && err.line > 0) line = err.line;
              if (typeof err.stack === "string") stack = err.stack.trim().slice(0, 2000);
            } else if (err !== undefined && err !== null) {
              message = String(err);
            }
            if (kind === "script" && (message.startsWith("`GM_") || message.startsWith("`window.") || message.includes("is not in @connect"))) kind = "api";
            return { kind, message, line, stack };
          };
          const reportCaught = (err, loadIdOverride, forceAfterLoad) => {
            const info = formatErr(err);
            if (err && typeof err === "object") {
              if (reportedErrors.has(err)) return info.message;
              reportedErrors.add(err);
            }
            const afterLoad = forceAfterLoad !== undefined ? Boolean(forceAfterLoad) : (mainLoadDepth === 0);
            const lid = loadIdOverride !== undefined ? String(loadIdOverride || "") : currentLoadId;
            postMsg({
              action: "scriptError", message: info.message, line: info.line, stack: info.stack,
              kind: info.kind, afterLoad, url: String(window.location.href || ""), loadId: lid
            }).catch(() => {});
            return info.message;
          };
          window.__wukongReportScriptError = reportCaught;
          const wrapFn = (fn) => {
            if (typeof fn !== "function") return fn;
            if (fn.__wukongWrapped) return fn.__wukongWrapped;
            const wrapped = function(...args) {
              try { return fn.apply(this, args); }
              catch (err) { reportCaught(err, undefined, true); throw err; }
            };
            Object.defineProperty(fn, "__wukongWrapped", { value: wrapped, configurable: true });
            return wrapped;
          };
          window.__wukongWrapGMCallback = wrapFn;
          const gmCbKeys = ["onload", "onerror", "ontimeout", "onabort", "onreadystatechange", "onprogress"];
          const wrapGMArg = (v) => {
            if (typeof v === "function") return wrapFn(v);
            if (v && typeof v === "object" && Object.getPrototypeOf(v) === Object.prototype) {
              let copy = null;
              for (const k of gmCbKeys) {
                if (typeof v[k] === "function") { if (!copy) copy = Object.assign({}, v); copy[k] = wrapFn(v[k]); }
              }
              return copy || v;
            }
            return v;
          };
          const defineGM = (name, impl) => {
            window[name] = function(...args) { return impl.apply(this, args.map(wrapGMArg)); };
          };
          window.__wukongDefineGM = defineGM;
          window.setTimeout = (cb, ms, ...args) => origSetTimeout(typeof cb === "function" ? wrapFn(cb) : cb, ms, ...args);
          window.setInterval = (cb, ms, ...args) => origSetInterval(typeof cb === "function" ? wrapFn(cb) : cb, ms, ...args);
          if (origRAF) window.requestAnimationFrame = (cb) => origRAF(typeof cb === "function" ? wrapFn(cb) : cb);
          const wrapListener = (l) => {
            if (!l || (typeof l !== "function" && typeof l !== "object")) return l;
            let w = listenerMap.get(l);
            if (w) return w;
            w = typeof l === "function"
              ? function(...args) { try { return l.apply(this, args); } catch (err) { reportCaught(err, undefined, true); throw err; } }
              : function(ev) { if (typeof l.handleEvent === "function") { try { return l.handleEvent.call(l, ev); } catch (err) { reportCaught(err, undefined, true); throw err; } } };
            listenerMap.set(l, w);
            return w;
          };
          EventTarget.prototype.addEventListener = function(type, l, opts) { return origAddEL.call(this, type, wrapListener(l), opts); };
          EventTarget.prototype.removeEventListener = function(type, l, opts) { return origRemEL.call(this, type, (l && listenerMap.get(l)) || l, opts); };
          for (const obsName of ["MutationObserver", "IntersectionObserver", "ResizeObserver"]) {
            const OrigObs = window[obsName];
            if (typeof OrigObs !== "function") continue;
            const WrappedObs = function(cb, ...rest) {
              if (!new.target) throw new TypeError("Constructor " + obsName + " requires 'new'");
              return new OrigObs(typeof cb === "function" ? wrapFn(cb) : cb, ...rest);
            };
            WrappedObs.prototype = OrigObs.prototype;
            Object.setPrototypeOf(WrappedObs, OrigObs);
            window[obsName] = WrappedObs;
          }
          origAddEL.call(window, "unhandledrejection", (e) => {
            if (e && e.promise instanceof Promise) reportCaught(e.reason, undefined, true);
          });
          const reportAsyncErr = (err) => { reportCaught(err, undefined, true); };
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
            if (document.readyState === "loading") origAddEL.call(document, "DOMContentLoaded", apply, { once: true });
            return sheet;
          };
          const apiErr = (msg) => { const e = new Error(msg); e.__wukongErrorKind = "api"; throw e; };
          const needGrant = (fn) => apiErr("`" + fn + "` needs `@grant " + fn + "`");
          const notSupported = (fn) => apiErr("`" + fn + "` is not supported in WukongMind");
          const req = (fn) => { if (!grants.has(fn)) needGrant(fn); };
          const reqEither = (g1, g2, called) => { if (!grants.has(g1) && (!g2 || !grants.has(g2))) needGrant(called); };
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
          const fireCb = (cb, arg) => {
            if (typeof cb !== "function") return;
            try { cb(arg); } catch (err) { reportAsyncErr(err); }
          };
          const makeErrResp = (finalUrl, error) => Object.freeze({
            status: 0, statusText: "", responseText: "", response: null,
            responseHeaders: "", finalUrl: String(finalUrl || ""), readyState: 4, error: String(error || "Request failed")
          });
          const checkXhrUnsupported = (d) => {
            const rt = d.responseType == null ? "" : String(d.responseType).toLowerCase();
            if (rt !== "" && rt !== "text" && rt !== "json") return 'GM_xmlhttpRequest does not support responseType "' + rt + '".';
            if (d.data !== undefined && d.data !== null && typeof d.data !== "string") return "GM_xmlhttpRequest supports text request bodies only; binary uploads are not supported.";
            if (typeof d.onprogress === "function" || d.upload != null) return "GM_xmlhttpRequest progress events are not supported.";
            return null;
          };
          const startXhr = (details, calledName, promiseHooks) => {
            reqEither("GM_xmlhttpRequest", "GM.xmlHttpRequest", calledName);
            if (!details || typeof details !== "object") throw new TypeError(calledName + " details must be an object");
            const rawUrl = details.url == null ? "" : String(details.url).trim();
            const unsupported = checkXhrUnsupported(details);
            if (unsupported) {
              if (!promiseHooks && typeof details.onerror !== "function") apiErr(unsupported);
              let cancelled = false;
              queueMicrotask(() => {
                if (cancelled) return;
                fireCb(details.onerror, makeErrResp(rawUrl, unsupported));
                if (promiseHooks) { const e = new Error(unsupported); e.__wukongErrorKind = "api"; promiseHooks.reject(e); }
              });
              return { abort() { cancelled = true; } };
            }
            let resolvedUrl = rawUrl;
            if (rawUrl) { try { resolvedUrl = new URL(rawUrl, String(window.location.href || "about:blank")).href; } catch (_) {} }
            const rt = details.responseType == null ? "" : String(details.responseType).toLowerCase();
            const headersObj = {};
            if (details.headers && typeof details.headers === "object") {
              for (const [hk, hv] of Object.entries(details.headers)) { if (hv != null) headersObj[String(hk)] = String(hv); }
            }
            const reqId = "xhr-" + (++nextReqId) + "-" + docToken;
            let settled = false;
            const p = postMsg({
              action: "xmlhttpRequest", requestId: reqId, url: resolvedUrl,
              method: details.method == null ? "GET" : String(details.method),
              headers: headersObj, data: details.data == null ? null : String(details.data),
              timeoutMs: typeof details.timeout === "number" && Number.isFinite(details.timeout) ? details.timeout : 0,
              responseType: rt, anonymous: Boolean(details.anonymous)
            });
            p.then((res) => {
              if (settled) return;
              settled = true;
              if (res && res.ok) {
                const text = String(res.responseText == null ? "" : res.responseText);
                let parsed = text;
                if (rt === "json") { try { parsed = JSON.parse(text); } catch (_) { parsed = null; } }
                const respObj = Object.freeze({
                  status: Number(res.status || 0), statusText: String(res.statusText || ""),
                  responseText: text, response: parsed,
                  responseHeaders: String(res.responseHeaders || ""),
                  finalUrl: String(res.finalUrl || resolvedUrl), readyState: 4
                });
                fireCb(details.onload, respObj);
                if (promiseHooks) promiseHooks.resolve(respObj);
                return;
              }
              const errMsg = String((res && res.error) || "Request failed");
              const errObj = makeErrResp(String((res && res.finalUrl) || resolvedUrl), errMsg);
              const kind = res && res.kind;
              fireCb(kind === "timeout" ? details.ontimeout : (kind === "abort" ? details.onabort : details.onerror), errObj);
              if (promiseHooks) {
                const rejErr = new Error(errMsg);
                if (res && res.errorKind === "api") rejErr.__wukongErrorKind = "api";
                promiseHooks.reject(rejErr);
              }
            }, (err) => {
              if (settled) return;
              settled = true;
              const msg = err && err.message ? String(err.message) : String(err);
              fireCb(details.onerror, makeErrResp(resolvedUrl, msg));
              if (promiseHooks) promiseHooks.reject(new Error(msg));
            });
            return {
              abort() {
                if (settled) return;
                settled = true;
                postMsg({ action: "abortXmlhttpRequest", requestId: reqId }).catch(() => {});
                fireCb(details.onabort, makeErrResp(resolvedUrl, "Request aborted"));
                if (promiseHooks) promiseHooks.reject(new Error("Request aborted"));
              }
            };
          };

          defineGM("GM_log", (...args) => { origLog(logPrefix, ...args); });
          defineGM("GM_addStyle", (css) => addStyleImpl(css));
          defineGM("GM_getValue", (key, def) => {
            reqEither("GM_getValue", "GM.getValue", "GM_getValue");
            const k = String(key);
            return values.has(k) ? JSON.parse(values.get(k)) : def;
          });
          defineGM("GM_setValue", (key, value) => {
            reqEither("GM_setValue", "GM.setValue", "GM_setValue");
            const [k, ser] = prepareSet(key, value), had = values.has(k), prev = values.get(k);
            values.set(k, ser);
            postMsg({ action: "setValue", key: k, rawJSON: ser }).catch((e) => {
              if (had) values.set(k, prev); else values.delete(k);
              reportAsyncErr(e);
            });
          });
          defineGM("GM_deleteValue", (key) => {
            reqEither("GM_deleteValue", "GM.deleteValue", "GM_deleteValue");
            const k = String(key); values.delete(k);
            postMsg({ action: "deleteValue", key: k }).catch(reportAsyncErr);
          });
          defineGM("GM_listValues", () => { reqEither("GM_listValues", "GM.listValues", "GM_listValues"); return Array.from(values.keys()); });
          defineGM("GM_xmlhttpRequest", (details) => startXhr(details, "GM_xmlhttpRequest", null));
          defineGM("GM_registerMenuCommand", (title, fn) => {
            req("GM_registerMenuCommand");
            if (typeof fn !== "function") throw new TypeError("GM_registerMenuCommand requires a callback function");
            const cleanTitle = String(title == null ? "" : title).trim();
            if (!cleanTitle) throw new TypeError("GM_registerMenuCommand requires a non-empty title");
            const id = "cmd-" + (++nextMenuCmdId) + "-" + docToken;
            menuCallbacks.set(id, fn);
            postMsg({ action: "registerMenuCommand", id, title: cleanTitle, docToken }).catch(reportAsyncErr);
            return id;
          });
          defineGM("GM_unregisterMenuCommand", (id) => {
            reqEither("GM_registerMenuCommand", "GM_unregisterMenuCommand", "GM_unregisterMenuCommand");
            const key = String(id == null ? "" : id);
            menuCallbacks.delete(key);
            if (key) postMsg({ action: "unregisterMenuCommand", id: key, docToken }).catch(reportAsyncErr);
          });
          const gmDot = Object.freeze({
            get info() { return currentInfo; },
            addStyle: async (css) => addStyleImpl(css),
            getValue: async (key, def) => {
              reqEither("GM_getValue", "GM.getValue", "GM.getValue");
              const k = String(key);
              return values.has(k) ? JSON.parse(values.get(k)) : def;
            },
            setValue: async (key, value) => {
              reqEither("GM_setValue", "GM.setValue", "GM.setValue");
              const [k, ser] = prepareSet(key, value), had = values.has(k), prev = values.get(k);
              values.set(k, ser);
              try {
                await postMsg({ action: "setValue", key: k, rawJSON: ser });
              } catch (e) {
                if (had) values.set(k, prev); else values.delete(k);
                throw e;
              }
            },
            deleteValue: async (key) => {
              reqEither("GM_deleteValue", "GM.deleteValue", "GM.deleteValue");
              const k = String(key);
              values.delete(k);
              await postMsg({ action: "deleteValue", key: k });
            },
            listValues: async () => {
              reqEither("GM_listValues", "GM.listValues", "GM.listValues");
              return Array.from(values.keys());
            },
            xmlHttpRequest: (details) => {
              const wrappedDetails = wrapGMArg(details);
              if (!grants.has("GM_xmlhttpRequest") && !grants.has("GM.xmlHttpRequest")) {
                const ungrantedErr = new Error("`GM.xmlHttpRequest` needs `@grant GM.xmlHttpRequest`");
                ungrantedErr.__wukongErrorKind = "api";
                const rejected = Promise.reject(ungrantedErr);
                rejected.abort = () => {};
                return rejected;
              }
              let abortFn = () => {};
              const promise = new Promise((resolve, reject) => {
                try {
                  const handle = startXhr(wrappedDetails, "GM.xmlHttpRequest", { resolve, reject });
                  abortFn = () => handle.abort();
                } catch (err) {
                  reject(err);
                }
              });
              promise.abort = () => abortFn();
              return promise;
            }
          });
          Object.defineProperty(window, "GM", { value: gmDot, configurable: false, writable: false });
          const makeAiError = (code, message) => {
            const err = new Error(String(message || "GM_ai failed"));
            Object.defineProperty(err, "name", { value: "GMAiError", enumerable: true, configurable: true, writable: true });
            err.code = String(code || "provider");
            err.__wukongErrorKind = "service";
            Object.defineProperty(err, "message", { value: err.message, enumerable: true, configurable: true, writable: true });
            return err;
          };
          const parseAiFormat = (format) => {
            if (format === undefined || format === null || format === "text") return { formatMode: "text", schemaJSON: null };
            if (format === "json") return { formatMode: "json", schemaJSON: null };
            if (typeof format === "object" && !Array.isArray(format)) return { formatMode: "schema", schemaJSON: JSON.stringify(format) };
            throw makeAiError("invalid_output", 'GM_ai format must be undefined, "text", "json", or a JSON Schema object.');
          };
          const sendAi = async (payload) => {
            const res = await postMsg(payload);
            if (res && res.ok && typeof res.rawJSON === "string") return JSON.parse(res.rawJSON);
            throw makeAiError((res && res.code) || "provider", (res && res.message) || "GM_ai failed");
          };
          const gmAiFn = (prompt, format) => {
            req("GM_ai");
            let fmt;
            try { fmt = parseAiFormat(format); } catch (e) { return Promise.reject(e); }
            const reqId = "ai-" + (++nextReqId) + "-" + docToken;
            return sendAi({ action: "gmAi", requestId: reqId, docToken, prompt: String(prompt == null ? "" : prompt), ...fmt });
          };
          Object.defineProperty(gmAiFn, "map", {
            value: (items, instruction, format) => {
              req("GM_ai");
              let fmt;
              try { fmt = parseAiFormat(format); } catch (e) { return Promise.reject(e); }
              if (!Array.isArray(items)) return Promise.reject(makeAiError("invalid_output", "GM_ai.map items must be an array."));
              const cleanItems = [];
              for (const raw of items) {
                if (!raw || typeof raw !== "object" || raw.id === undefined || raw.id === null || String(raw.id) === "") {
                  return Promise.reject(makeAiError("invalid_output", "Each GM_ai.map item must have a non-empty id."));
                }
                cleanItems.push({ id: String(raw.id), text: String(raw.text == null ? "" : raw.text) });
              }
              const reqId = "ai-" + (++nextReqId) + "-" + docToken;
              return sendAi({ action: "gmAiMap", requestId: reqId, docToken, items: cleanItems, instruction: String(instruction == null ? "" : instruction), ...fmt });
            },
            writable: false,
            configurable: false
          });
          window.GM_ai = gmAiFn;
          for (const fn of \(jsonArray(unsupportedGMFunctions))) defineGM(fn, () => notSupported(fn));
          window.close = () => notSupported("window.close");
          window.focus = () => notSupported("window.focus");
        })();
        """
    }

    static func pageWorldLexicalGMBindingsJS(for script: UserScript, scriptIDJSON: String) -> String {
        let nameJSON = UserScript.encodeSingleLineJSONString(script.name)
        let infoJSON = gmInfoJSONLiteral(for: script)
        let ungranted = pageWorldPowerFunctions.map { "const \($0) = () => { throw new Error(\(UserScript.encodeSingleLineJSONString("`\($0)` needs `@grant \($0)`"))); };" }.joined(separator: "\n")
        let unsupported = unsupportedGMFunctions.map { "const \($0) = () => { throw new Error(\(UserScript.encodeSingleLineJSONString("`\($0)` is not supported in WukongMind"))); };" }.joined(separator: "\n")
        return """
        const GM_info = __wukongFreezeInfo(\(infoJSON));
        const GM_log = (...args) => __wukongLog("[" + \(nameJSON) + "]", ...args);
        const GM_addStyle = (css) => __wukongAddStyle(\(scriptIDJSON), css);
        \(ungranted)
        GM_ai.map = GM_ai;
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
        let pageURL = GMBridge.trustedPageURL(
            origin: message.frameInfo.securityOrigin,
            webViewURL: message.webView?.url,
            frameURL: message.frameInfo.request.url
        )
        bridge.handleMessage(
            scriptID: scriptID,
            body: message.body,
            isMainFrame: message.frameInfo.isMainFrame,
            world: message.world,
            expectedWorld: expectedWorld,
            pageURL: pageURL,
            replyHandler: replyHandler
        )
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
        if var payload = message.body as? [String: Any] {
            if (payload["url"] as? String)?.isEmpty != false {
                payload["url"] = message.webView?.url?.absoluteString
                    ?? message.frameInfo.request.url?.absoluteString
                    ?? ""
            }
            bridge.onPageScriptReport?(payload)
        }
        replyHandler(["ok": true], nil)
    }
}
