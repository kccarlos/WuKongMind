import Combine
import CryptoKit
import Foundation

// MARK: - Import & Update Models

struct ScriptUnsupportedItem: Equatable, Identifiable, Sendable {
    enum Style: Equatable, Sendable { case blocked, note }
    var id: String { "\(title)|\(detail)" }
    var title: String
    var isMonospaced: Bool
    var detail: String
    var style: Style
}

struct ScriptCapabilitySummary: Equatable, Identifiable, Sendable {
    enum Icon: String, Sendable {
        case storage = "internaldrive"
        case requests = "arrow.up.right"
        case ai = "sparkles"
        case style = "paintbrush"
        case menu = "list.bullet"
    }
    var id: String
    var icon: Icon
    var title: String
    var subtitle: String?
    var isDanger: Bool
}

struct ScriptUpdateDiff: Equatable, Sendable {
    var oldVersion: String?
    var newVersion: String?
    var changedHost: (oldHost: String, newHost: String)?
    var locallyChanged: Bool
    var addedConnects: [String]
    var removedConnects: [String]
    var addedMatches: [String]
    var removedMatches: [String]
    var addedGrants: [String]
    var removedGrants: [String]
    var addedLibraries: [String]
    var removedLibraries: [String]
    var changedLineCount: Int
    var addedCodeLines: Set<String>

    static func == (lhs: ScriptUpdateDiff, rhs: ScriptUpdateDiff) -> Bool {
        lhs.oldVersion == rhs.oldVersion && lhs.newVersion == rhs.newVersion
            && lhs.changedHost?.oldHost == rhs.changedHost?.oldHost
            && lhs.changedHost?.newHost == rhs.changedHost?.newHost
            && lhs.locallyChanged == rhs.locallyChanged
            && lhs.addedConnects == rhs.addedConnects && lhs.removedConnects == rhs.removedConnects
            && lhs.addedMatches == rhs.addedMatches && lhs.removedMatches == rhs.removedMatches
            && lhs.addedGrants == rhs.addedGrants && lhs.removedGrants == rhs.removedGrants
            && lhs.addedLibraries == rhs.addedLibraries && lhs.removedLibraries == rhs.removedLibraries
            && lhs.changedLineCount == rhs.changedLineCount && lhs.addedCodeLines == rhs.addedCodeLines
    }

    var grantsUnchanged: Bool {
        addedGrants.isEmpty && removedGrants.isEmpty && addedConnects.isEmpty && removedConnects.isEmpty
    }
}

struct ScriptImportFailure: Error, Equatable, Sendable {
    var linkURL: String
    var reason: String
}

struct ScriptImportReview: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case create(duplicateNameHost: String?)
        case update(existing: UserScript, diff: ScriptUpdateDiff)
    }
    var mode: Mode
    var candidate: UserScript
    var rawSource: String
    var installURL: String
    var finalHost: String
    var upstreamHash: String
    var author: String?
    var libraries: [ScriptLoadedLibrary]
    var unsupportedItems: [ScriptUnsupportedItem]

    var isUpdate: Bool { if case .update = mode { true } else { false } }
    var lineCount: Int { max(1, rawSource.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").count) }
}

struct ScriptAvailableUpdate: Codable, Equatable, Sendable {
    var scriptID: String
    var fetchURL: String
    var newVersion: String?
    var checkedAt: Date
    var upstreamHash: String
}

enum ScriptImportSheetPhase: Equatable {
    case loading(linkURL: String, isUpdate: Bool)
    case ready(ScriptImportReview)
    case failed(ScriptImportFailure, isUpdate: Bool)
}

// MARK: - Importer & Update Checker

@MainActor
final class ScriptImporter: ObservableObject {
    static let maxScriptBytes = 2 * 1024 * 1024
    static let maxRequireBytes = 2 * 1024 * 1024
    static let maxTotalRequireBytes = 5 * 1024 * 1024
    static let dailyCheckInterval: TimeInterval = 24 * 60 * 60
    static let navigateInterceptMessage = "The import review is open; the person decides"

    @Published var activeSessionID: UUID?
    @Published private(set) var presentsInSettings = false
    @Published private(set) var phase: ScriptImportSheetPhase?
    @Published private(set) var availableUpdates: [String: ScriptAvailableUpdate] = [:]
    @Published private(set) var checkingScriptIDs: Set<String> = []
    private(set) var lastForegroundCheckAt: Date?

    private let scriptStore: ScriptStore
    private let stateFileURL: URL
    var httpClientProvider: () -> AgentHTTPClient
    private var activeLoadTask: Task<Void, Never>?
    private var retryTarget: (url: URL, targetScriptID: String?, inSettings: Bool)?

    private struct PersistedState: Codable {
        var lastForegroundCheckAt: Date?
        var availableUpdates: [String: ScriptAvailableUpdate] = [:]
    }

    init(scriptStore: ScriptStore, stateDirectoryURL: URL, httpClientProvider: @escaping () -> AgentHTTPClient) {
        self.scriptStore = scriptStore
        self.stateFileURL = stateDirectoryURL.appendingPathComponent("script-updates.json", isDirectory: false)
        self.httpClientProvider = httpClientProvider
        if let data = try? Data(contentsOf: stateFileURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            lastForegroundCheckAt = decoded.lastForegroundCheckAt
            availableUpdates = decoded.availableUpdates
        }
    }

    nonisolated static func isUserScriptURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return false }
        return url.path.lowercased().hasSuffix(".user.js")
    }

    nonisolated static func canonicalURLString(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }

    nonisolated static func compareVersions(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        let a = (lhs ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let b = (rhs ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if a == b { return .orderedSame }
        if a.isEmpty { return .orderedAscending }
        if b.isEmpty { return .orderedDescending }
        let (aCore, aPre) = splitPrerelease(a), (bCore, bPre) = splitPrerelease(b)
        let aParts = aCore.split(whereSeparator: { $0 == "." || $0 == "_" })
        let bParts = bCore.split(whereSeparator: { $0 == "." || $0 == "_" })
        for idx in 0..<max(aParts.count, bParts.count) {
            let cmp = comparePart(idx < aParts.count ? String(aParts[idx]) : "0", idx < bParts.count ? String(bParts[idx]) : "0")
            if cmp != .orderedSame { return cmp }
        }
        switch (aPre, bPre) {
        case (nil, nil): return .orderedSame
        case (nil, .some): return .orderedDescending
        case (.some, nil): return .orderedAscending
        case (.some(let lp), .some(let rp)):
            let lt = lp.split(whereSeparator: { $0 == "." || $0 == "-" })
            let rt = rp.split(whereSeparator: { $0 == "." || $0 == "-" })
            for i in 0..<max(lt.count, rt.count) {
                guard i < lt.count else { return .orderedAscending }
                guard i < rt.count else { return .orderedDescending }
                let cmp = comparePart(String(lt[i]), String(rt[i]))
                if cmp != .orderedSame { return cmp }
            }
            return .orderedSame
        }
    }

    private nonisolated static func splitPrerelease(_ version: String) -> (String, String?) {
        let stripped = (version.hasPrefix("v") || version.hasPrefix("V")) ? String(version.dropFirst()) : version
        let noBuild = String(stripped.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard let dash = noBuild.firstIndex(of: "-") else { return (noBuild, nil) }
        return (String(noBuild[..<dash]), String(noBuild[noBuild.index(after: dash)...]))
    }

    private nonisolated static func comparePart(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let ln = UInt64(lhs), let rn = UInt64(rhs) {
            return ln == rn ? .orderedSame : (ln < rn ? .orderedAscending : .orderedDescending)
        }
        return lhs.localizedStandardCompare(rhs)
    }

    func openImport(from url: URL, targetScriptID: String? = nil, inSettings: Bool = false) {
        activeLoadTask?.cancel()
        presentsInSettings = inSettings
        retryTarget = (url, targetScriptID, inSettings)
        let isUpdate = targetScriptID != nil || existingScript(forInstallURL: url) != nil
        phase = .loading(linkURL: url.absoluteString, isUpdate: isUpdate)
        let session = UUID()
        activeSessionID = session
        activeLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let target = targetScriptID.flatMap { self.scriptStore.script(id: $0) }
            let outcome = await self.fetchReview(from: url, targetScript: target)
            guard !Task.isCancelled, self.activeSessionID == session else { return }
            switch outcome {
            case .success(let review): self.phase = .ready(review)
            case .failure(let failure): self.phase = .failed(failure, isUpdate: isUpdate)
            }
        }
    }

    func openImport(rawLink: String, inSettings: Bool = false) {
        let trimmed = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            activeLoadTask?.cancel()
            presentsInSettings = inSettings
            retryTarget = nil
            phase = .failed(ScriptImportFailure(linkURL: trimmed, reason: String(localized: "Enter a full HTTPS link to a .user.js file.")), isUpdate: false)
            activeSessionID = UUID()
            return
        }
        openImport(from: url, inSettings: inSettings)
    }

    func retryCurrentImport() {
        guard let retryTarget else { return }
        openImport(from: retryTarget.url, targetScriptID: retryTarget.targetScriptID, inSettings: retryTarget.inSettings)
    }

    func dismissImport() {
        activeLoadTask?.cancel()
        activeLoadTask = nil
        phase = nil
        presentsInSettings = false
        activeSessionID = nil
    }

    #if DEBUG
    func presentDebugPhase(_ debugPhase: ScriptImportSheetPhase, inSettings: Bool = false) {
        activeLoadTask?.cancel()
        presentsInSettings = inSettings
        phase = debugPhase
        activeSessionID = UUID()
    }
    func setDebugAvailableUpdate(_ update: ScriptAvailableUpdate) { availableUpdates[update.scriptID] = update }
    #endif

    @discardableResult
    func confirmImport(
        turnOn: Bool,
        expectedSessionID: UUID? = nil,
        expectedReview: ScriptImportReview? = nil
    ) throws -> UserScript? {
        guard case .ready(let review) = phase else { return nil }
        if let expectedSessionID, activeSessionID != expectedSessionID { return nil }
        if let expectedReview, review != expectedReview { return nil }
        let saved: UserScript
        switch review.mode {
        case .create:
            saved = try scriptStore.saveImportedScript(
                review.candidate, installURL: review.installURL, sourceHost: review.finalHost,
                upstreamHash: review.upstreamHash, libraries: review.libraries, turnOn: turnOn
            )
        case .update(let existing, _):
            saved = try scriptStore.applyImportedUpdate(
                id: existing.id, candidate: review.candidate, sourceHost: review.finalHost,
                upstreamHash: review.upstreamHash, libraries: review.libraries
            )
            availableUpdates.removeValue(forKey: existing.id)
            savePersistedState()
        }
        dismissImport()
        return saved
    }

    func existingScript(forInstallURL url: URL) -> UserScript? {
        let target = Self.canonicalURLString(url)
        return scriptStore.scripts.first {
            guard let raw = $0.metadata.installURL, let parsed = URL(string: raw) else { return false }
            return Self.canonicalURLString(parsed) == target
        }
    }

    func fetchReview(
        from url: URL,
        targetScript: UserScript? = nil,
        httpClient: AgentHTTPClient? = nil
    ) async -> Result<ScriptImportReview, ScriptImportFailure> {
        let linkText = url.absoluteString
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return .failure(ScriptImportFailure(linkURL: linkText, reason: String(localized: "Only HTTPS links can be imported.")))
        }
        let client = httpClient ?? httpClientProvider()
        let response: AgentHTTPResponse
        do {
            response = try await client.send(AgentHTTPRequest(url: url, sendCookies: false, httpsOnly: true, maxBytes: Self.maxScriptBytes, timeout: 30))
        } catch {
            return .failure(ScriptImportFailure(linkURL: linkText, reason: String(localized: "Couldn’t fetch the file: \(error.localizedDescription)")))
        }
        if !(200..<300).contains(response.status) {
            return .failure(ScriptImportFailure(linkURL: linkText, reason: String(localized: "Couldn’t fetch the file: the server answered \(Self.httpStatusText(response.status)).")))
        }
        if response.truncated {
            return .failure(ScriptImportFailure(linkURL: linkText, reason: String(localized: "The script file is larger than 2 MB.")))
        }
        guard let rawSource = response.text, !rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(ScriptImportFailure(linkURL: linkText, reason: String(localized: "The file isn’t readable UTF-8 text.")))
        }
        let parsed: (script: UserScript, author: String?, unsupported: [ScriptUnsupportedItem])
        let libraries: [ScriptLoadedLibrary]
        do {
            parsed = try Self.parseExternalUserScript(rawSource)
            libraries = try await Self.fetchLibraries(urls: parsed.script.metadata.requireURLs, httpClient: client)
        } catch let failure as ScriptImportFailure {
            return .failure(ScriptImportFailure(linkURL: linkText, reason: failure.reason))
        } catch {
            return .failure(ScriptImportFailure(linkURL: linkText, reason: error.localizedDescription))
        }

        let upstreamHash = ScriptStore.sha256Hex(Data(rawSource.utf8))
        let finalHost = response.finalURL.host?.lowercased() ?? host.lowercased()
        if let existing = targetScript ?? existingScript(forInstallURL: url) {
            let installString = existing.metadata.installURL ?? Self.canonicalURLString(url)
            let origHost = existing.metadata.sourceHost?.lowercased() ?? URL(string: installString)?.host?.lowercased()
            let changedHost = (origHost != nil && origHost != finalHost) ? (origHost!, finalHost) : nil
            let diff = Self.computeDiff(existing: existing, candidate: parsed.script, newRawSource: rawSource, changedHost: changedHost)
            return .success(ScriptImportReview(
                mode: .update(existing: existing, diff: diff), candidate: parsed.script, rawSource: rawSource,
                installURL: installString, finalHost: finalHost, upstreamHash: upstreamHash,
                author: parsed.author, libraries: libraries, unsupportedItems: parsed.unsupported
            ))
        }
        let duplicateHost = scriptStore.scripts.first {
            $0.name.caseInsensitiveCompare(parsed.script.name) == .orderedSame
        }.map { $0.metadata.sourceHost ?? $0.metadata.installURL.flatMap { URL(string: $0)?.host } ?? String(localized: "this device") }
        return .success(ScriptImportReview(
            mode: .create(duplicateNameHost: duplicateHost), candidate: parsed.script, rawSource: rawSource,
            installURL: Self.canonicalURLString(url), finalHost: finalHost, upstreamHash: upstreamHash,
            author: parsed.author, libraries: libraries, unsupportedItems: parsed.unsupported
        ))
    }

    static func fetchLibraries(
        urls: [String],
        expectedHashes: [String: String] = [:],
        httpClient: AgentHTTPClient
    ) async throws -> [ScriptLoadedLibrary] {
        var totalBytes = 0
        var loaded: [ScriptLoadedLibrary] = []
        for rawURL in urls {
            let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
                throw ScriptImportFailure(linkURL: trimmed, reason: String(localized: "Required library isn’t an HTTPS link (\(trimmed))."))
            }
            var fetchParts = URLComponents(url: url, resolvingAgainstBaseURL: true)
            let fragment = fetchParts?.fragment
            fetchParts?.fragment = nil
            let response: AgentHTTPResponse
            do {
                response = try await httpClient.send(AgentHTTPRequest(url: fetchParts?.url ?? url, sendCookies: false, httpsOnly: true, maxBytes: maxRequireBytes, timeout: 30))
            } catch {
                throw ScriptImportFailure(linkURL: trimmed, reason: String(localized: "Couldn’t fetch required library from \(host): \(error.localizedDescription)"))
            }
            if !(200..<300).contains(response.status) {
                throw ScriptImportFailure(linkURL: trimmed, reason: String(localized: "Couldn’t fetch required library from \(host): the server answered \(httpStatusText(response.status))."))
            }
            if response.truncated {
                throw ScriptImportFailure(linkURL: trimmed, reason: String(localized: "Required library from \(host) is larger than 2 MB."))
            }
            totalBytes += response.data.count
            if totalBytes > maxTotalRequireBytes {
                throw ScriptImportFailure(linkURL: trimmed, reason: String(localized: "The script’s @require libraries exceed 5 MB in total."))
            }
            guard let code = response.text else {
                throw ScriptImportFailure(linkURL: trimmed, reason: String(localized: "Required library from \(host) isn’t UTF-8 text."))
            }
            let actualHex = ScriptStore.sha256Hex(response.data).lowercased()
            let actualB64 = Data(SHA256.hash(data: response.data)).base64EncodedString()
            if let expected = expectedHashes[rawURL]?.lowercased(), expected != actualHex {
                throw ScriptImportFailure(linkURL: trimmed, reason: String(localized: "Required library hash changed for \(host)."))
            }
            if let sri = extractSRIHash(fragment: fragment), sri.lowercased() != actualHex && sri != actualB64 {
                throw ScriptImportFailure(linkURL: trimmed, reason: String(localized: "Required library hash didn’t match for \(host)."))
            }
            loaded.append(ScriptLoadedLibrary(meta: ScriptRequiredLibrary(url: rawURL, sha256: actualHex, sizeBytes: response.data.count), code: code))
        }
        return loaded
    }

    private nonisolated static func extractSRIHash(fragment: String?) -> String? {
        guard let fragment, !fragment.isEmpty else { return nil }
        for part in fragment.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "&" }) {
            let token = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            if token.lowercased().hasPrefix("sha256=") { return String(token.dropFirst(7)) }
            if token.lowercased().hasPrefix("sha256-") { return String(token.dropFirst(7)) }
        }
        return nil
    }

    static func parseExternalUserScript(_ rawSource: String) throws -> (script: UserScript, author: String?, unsupported: [ScriptUnsupportedItem]) {
        let normalized = rawSource.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.contains(UserScript.headerStartMarker), normalized.contains(UserScript.headerEndMarker) else {
            throw ScriptImportFailure(linkURL: "", reason: String(localized: "The file has no // ==UserScript== header."))
        }
        let sanitized = stripUntrustedWukongLines(from: normalized)
        let rawVersion = extractFirstHeaderValue("@version", in: sanitized)
        let author = extractFirstHeaderValue("@author", in: sanitized)
        var parsed: UserScript
        do {
            parsed = try UserScript.parseUserScriptFile(sanitized)
        } catch ScriptStoreError.emptyMatchRules {
            throw ScriptImportFailure(linkURL: "", reason: String(localized: "The script has no usable @match or @include rules."))
        } catch ScriptStoreError.invalidMatchRule(let rule, _) {
            throw ScriptImportFailure(linkURL: "", reason: String(localized: "The script has an invalid @match rule (\(rule))."))
        } catch ScriptStoreError.emptyBody {
            throw ScriptImportFailure(linkURL: "", reason: String(localized: "The script has no JavaScript code."))
        } catch {
            throw ScriptImportFailure(linkURL: "", reason: error.localizedDescription)
        }
        parsed.source = .imported
        parsed.environment = .isolated
        parsed.version = 1
        parsed.versionOrigin = .imported
        parsed.isEnabled = false
        parsed.disabledReason = nil
        parsed.metadata.authorVersion = rawVersion?.isEmpty == false ? rawVersion : nil
        parsed.metadata.locallyChanged = false
        return (parsed, author?.isEmpty == false ? author : nil, collectUnsupportedItems(for: parsed))
    }

    private static func stripUntrustedWukongLines(from content: String) -> String {
        guard let start = content.range(of: UserScript.headerStartMarker),
              let end = content.range(of: UserScript.headerEndMarker, range: start.upperBound..<content.endIndex) else { return content }
        let filtered = content[start.upperBound..<end.lowerBound].components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { return true }
            return !trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("@wukong-")
        }.joined(separator: "\n")
        return String(content[..<start.upperBound]) + filtered + String(content[end.lowerBound...])
    }

    private static func extractFirstHeaderValue(_ targetKey: String, in content: String) -> String? {
        guard let start = content.range(of: UserScript.headerStartMarker),
              let end = content.range(of: UserScript.headerEndMarker, range: start.upperBound..<content.endIndex) else { return nil }
        for line in content[start.upperBound..<end.lowerBound].components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { continue }
            let after = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard let split = after.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            if String(after[..<split]).caseInsensitiveCompare(targetKey) == .orderedSame {
                return String(after[split...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func collectUnsupportedItems(for script: UserScript) -> [ScriptUnsupportedItem] {
        var items: [ScriptUnsupportedItem] = []
        let supported = Set(ScriptMetadata.supportedGrants)
        let unsupportedGrants = script.metadata.grants.filter { !supported.contains($0) }
        if !unsupportedGrants.isEmpty {
            let detail = unsupportedGrants.count == 2
                ? String(localized: "A call to either fails; the rest of the script runs.")
                : String(localized: "A call to any of these fails; the rest of the script runs.")
            items.append(.init(title: unsupportedGrants.joined(separator: ", "), isMonospaced: false, detail: detail, style: .blocked))
        }
        for inc in script.metadata.values(for: "@include") where !inc.isEmpty && !MatchPattern.isValid(inc) {
            let isRegex = inc.hasPrefix("/") && inc.hasSuffix("/") && inc.count >= 2
            let detail = isRegex ? String(localized: "A regular-expression @include can’t be used.") : String(localized: "This @include pattern can’t be used.")
            items.append(.init(title: "@include \(inc)", isMonospaced: true, detail: detail, style: .blocked))
        }
        for exc in script.metadata.unusableExcludePatterns {
            items.append(.init(title: "@exclude \(exc)", isMonospaced: true, detail: String(localized: "This exclude rule can’t be used, so the script isn’t excluded there."), style: .blocked))
        }
        if let runAt = script.metadata.runAtText, !runAt.isEmpty {
            items.append(.init(title: "@run-at \(runAt)", isMonospaced: true, detail: String(localized: "Runs at document end."), style: .note))
        }
        return items
    }

    static func capabilitySummaries(
        for script: UserScript,
        scriptsModelName: String,
        valueSummary: String? = nil,
        forImportSheet: Bool
    ) -> [ScriptCapabilitySummary] {
        let grants = Set(script.metadata.grants)
        var rows: [ScriptCapabilitySummary] = []
        if !grants.isDisjoint(with: ["GM_getValue", "GM_setValue", "GM_deleteValue", "GM_listValues", "GM.getValue", "GM.setValue", "GM.deleteValue", "GM.listValues"]) {
            rows.append(.init(id: "storage", icon: .storage, title: String(localized: "Keeps its own settings"), subtitle: valueSummary, isDanger: false))
        }
        if grants.contains("GM_xmlhttpRequest") || grants.contains("GM.xmlHttpRequest") {
            let hosts = script.metadata.connectHosts
            let isWild = hosts.contains("*")
            let title = isWild ? String(localized: "Sends requests to any site")
                : (hosts.isEmpty ? String(localized: "Sends requests to the page’s own site") : String(localized: "Sends requests to \(hosts.joined(separator: ", "))"))
            rows.append(.init(id: "requests", icon: .requests, title: title, subtitle: nil, isDanger: forImportSheet && isWild))
        }
        if grants.contains("GM_ai") {
            let title = forImportSheet
                ? String(localized: "Sends text from the page to your Scripts model (\(scriptsModelName))")
                : String(localized: "Uses AI: sends page text to \(scriptsModelName)")
            rows.append(.init(id: "ai", icon: .ai, title: title, subtitle: nil, isDanger: forImportSheet))
        }
        if grants.contains("GM_addStyle") || grants.contains("GM.addStyle") {
            rows.append(.init(id: "style", icon: .style, title: String(localized: "Adds custom styles to the page"), subtitle: nil, isDanger: false))
        }
        if grants.contains("GM_registerMenuCommand") {
            rows.append(.init(id: "menu", icon: .menu, title: String(localized: "Adds commands to This page"), subtitle: nil, isDanger: false))
        }
        return rows
    }

    static func isBroadEverySiteRule(_ rule: String) -> Bool {
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t == "*://*/*" || t == "<all_urls>" || t == "https://*/*" || t == "http://*/*"
    }

    static func computeDiff(
        existing: UserScript,
        candidate: UserScript,
        newRawSource: String,
        changedHost: (oldHost: String, newHost: String)?
    ) -> ScriptUpdateDiff {
        let oldBody = Set(existing.js.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        let newBody = Set(candidate.js.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        let existingFull = Set(existing.toUserScriptFileContent().replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let addedLines = Set(newRawSource.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !existingFull.contains($0) })
        let oc = existing.metadata.connectHosts, nc = candidate.metadata.connectHosts
        let om = existing.matchRules, nm = candidate.matchRules
        let og = existing.metadata.grants, ng = candidate.metadata.grants
        let ol = existing.metadata.requireURLs, nl = candidate.metadata.requireURLs
        return ScriptUpdateDiff(
            oldVersion: existing.metadata.authorVersion, newVersion: candidate.metadata.authorVersion,
            changedHost: changedHost, locallyChanged: existing.metadata.locallyChanged,
            addedConnects: nc.filter { !oc.contains($0) }, removedConnects: oc.filter { !nc.contains($0) },
            addedMatches: nm.filter { !om.contains($0) }, removedMatches: om.filter { !nm.contains($0) },
            addedGrants: ng.filter { !og.contains($0) }, removedGrants: og.filter { !ng.contains($0) },
            addedLibraries: nl.filter { !ol.contains($0) }, removedLibraries: ol.filter { !nl.contains($0) },
            changedLineCount: max(oldBody.symmetricDifference(newBody).count, addedLines.count),
            addedCodeLines: addedLines
        )
    }

    func availableUpdate(for scriptID: String) -> ScriptAvailableUpdate? { availableUpdates[scriptID] }

    func pruneDeletedScripts() {
        let validIDs = Set(scriptStore.scripts.map(\.id))
        let filtered = availableUpdates.filter { validIDs.contains($0.key) }
        if filtered.count != availableUpdates.count { availableUpdates = filtered; savePersistedState() }
    }

    func checkForegroundUpdatesIfDue(enabled: Bool, now: Date = Date()) async {
        guard enabled else { return }
        if let last = lastForegroundCheckAt, now.timeIntervalSince(last) < Self.dailyCheckInterval { return }
        lastForegroundCheckAt = now
        savePersistedState()
        for script in scriptStore.scripts where script.isEnabled && script.source == .imported && Self.preferredCheckURL(for: script) != nil {
            _ = await checkForUpdate(script: script, now: now)
        }
    }

    enum UpdateCheckOutcome: Equatable {
        case updateAvailable(ScriptAvailableUpdate)
        case upToDate
        case failed(String)
    }

    @discardableResult
    func checkForUpdate(script: UserScript, httpClient: AgentHTTPClient? = nil, now: Date = Date()) async -> UpdateCheckOutcome {
        guard let checkURL = Self.preferredCheckURL(for: script) else {
            return .failed(String(localized: "This script has no HTTPS update link."))
        }
        checkingScriptIDs.insert(script.id)
        defer { checkingScriptIDs.remove(script.id) }
        let client = httpClient ?? httpClientProvider()
        do {
            let response = try await client.send(AgentHTTPRequest(url: checkURL, sendCookies: false, httpsOnly: true, maxBytes: Self.maxScriptBytes, timeout: 30))
            guard (200..<300).contains(response.status), !response.truncated, let text = response.text else {
                return .failed(String(localized: "Couldn’t check for updates (HTTP \(response.status))."))
            }
            let sanitized = Self.stripUntrustedWukongLines(from: text.replacingOccurrences(of: "\r\n", with: "\n"))
            guard sanitized.contains(UserScript.headerStartMarker), sanitized.contains(UserScript.headerEndMarker) else {
                return .failed(String(localized: "The update link didn’t return a valid userscript header."))
            }
            let remoteVersion = Self.extractFirstHeaderValue("@version", in: sanitized)
            let remoteHash = ScriptStore.sha256Hex(Data(text.utf8))
            let isNewer = (remoteVersion != nil || script.metadata.authorVersion != nil)
                ? Self.compareVersions(remoteVersion, script.metadata.authorVersion) == .orderedDescending
                : remoteHash != (script.metadata.upstreamHash ?? "")
            if isNewer {
                let downloadURL = Self.preferredDownloadURL(for: script) ?? checkURL
                let available = ScriptAvailableUpdate(scriptID: script.id, fetchURL: downloadURL.absoluteString, newVersion: remoteVersion, checkedAt: now, upstreamHash: remoteHash)
                availableUpdates[script.id] = available
                savePersistedState()
                return .updateAvailable(available)
            }
            if availableUpdates.removeValue(forKey: script.id) != nil { savePersistedState() }
            return .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func preferredCheckURL(for script: UserScript) -> URL? {
        httpsURL(from: script.metadata.values(for: "@updateURL").first)
            ?? httpsURL(from: script.metadata.values(for: "@downloadURL").first)
            ?? httpsURL(from: script.metadata.installURL)
    }

    static func preferredDownloadURL(for script: UserScript) -> URL? {
        httpsURL(from: script.metadata.values(for: "@downloadURL").first)
            ?? httpsURL(from: script.metadata.values(for: "@updateURL").first)
            ?? httpsURL(from: script.metadata.installURL)
    }

    private static func httpsURL(from raw: String?) -> URL? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              let url = URL(string: t), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private static func httpStatusText(_ status: Int) -> String {
        switch status {
        case 401: "401 Unauthorized"
        case 403: "403 Forbidden"
        case 404: "404 Not Found"
        case 410: "410 Gone"
        case 429: "429 Too Many Requests"
        case 500: "500 Server Error"
        case 502: "502 Bad Gateway"
        case 503: "503 Service Unavailable"
        default: "\(status)"
        }
    }

    private func savePersistedState() {
        guard let data = try? JSONEncoder().encode(PersistedState(lastForegroundCheckAt: lastForegroundCheckAt, availableUpdates: availableUpdates)) else { return }
        try? FileManager.default.createDirectory(at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateFileURL, options: .atomic)
    }
}

extension ScriptStore {
    func resolveSyncedRequiredLibraries(_ pending: PendingLibrarySync, httpClient: AgentHTTPClient? = nil) {
        schedulePendingLibrarySync(pending.scriptID) { [weak self] in
            guard let self, let resolvedClient = httpClient ?? self.libraryHTTPClientProvider?() else { return }
            do {
                let loaded = try await ScriptImporter.fetchLibraries(
                    urls: pending.pins.map(\.url),
                    httpClient: resolvedClient
                )
                for (item, pin) in zip(loaded, pending.pins) {
                    if item.meta.sha256.lowercased() != pin.sha256.lowercased() {
                        let host = URL(string: pin.url)?.host ?? pin.url
                        let reason = String(
                            localized: "Required library hash changed for \(host).",
                            comment: "Disabled reason when a synced userscript's @require library no longer matches the sender's SHA-256 hash"
                        )
                        self.failSyncedRequiredLibraries(
                            for: pending.scriptID,
                            pins: pending.pins,
                            reason: reason,
                            hashMismatch: true
                        )
                        return
                    }
                }
                self.completeSyncedRequiredLibraries(
                    for: pending.scriptID,
                    pins: pending.pins,
                    bodies: loaded.map(\.code),
                    enableOnSuccess: pending.enableOnSuccess,
                    runLiveJS: pending.runLiveJS
                )
            } catch let failure as ScriptImportFailure {
                self.failSyncedRequiredLibraries(
                    for: pending.scriptID,
                    pins: pending.pins,
                    reason: failure.reason,
                    hashMismatch: false
                )
            } catch {
                self.failSyncedRequiredLibraries(
                    for: pending.scriptID,
                    pins: pending.pins,
                    reason: error.localizedDescription,
                    hashMismatch: false
                )
            }
        }
    }
}
