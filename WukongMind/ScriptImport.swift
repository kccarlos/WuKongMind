import Combine
import CryptoKit
import Foundation

// MARK: - Import Models

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

struct ScriptImportFailure: Error, Equatable, Sendable {
    var linkURL: String
    var reason: String
}

struct ScriptImportReview: Equatable, Sendable {
    var duplicateNameHost: String?
    var candidate: UserScript
    var rawSource: String
    var installURL: String
    var finalHost: String
    var upstreamHash: String
    var author: String?
    var libraries: [ScriptLoadedLibrary]
    var unsupportedItems: [ScriptUnsupportedItem]

    var lineCount: Int {
        max(1, rawSource.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").count)
    }
}

enum ScriptImportSheetPhase: Equatable {
    case loading(linkURL: String)
    case ready(ScriptImportReview)
    case failed(ScriptImportFailure)
}

// MARK: - Importer

@MainActor
final class ScriptImporter: ObservableObject {
    static let maxScriptBytes = 2 * 1024 * 1024
    static let maxRequireBytes = 2 * 1024 * 1024
    static let maxTotalRequireBytes = 5 * 1024 * 1024
    static let navigateInterceptMessage = "The import review is open; the person decides"

    @Published var activeSessionID: UUID?
    @Published private(set) var presentsInSettings = false
    @Published private(set) var phase: ScriptImportSheetPhase?

    private let scriptStore: ScriptStore
    var httpClientProvider: () -> AgentHTTPClient
    private var activeLoadTask: Task<Void, Never>?
    private var retryTarget: (url: URL, inSettings: Bool)?

    init(scriptStore: ScriptStore, httpClientProvider: @escaping () -> AgentHTTPClient) {
        self.scriptStore = scriptStore
        self.httpClientProvider = httpClientProvider
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

    func openImport(from url: URL, inSettings: Bool = false) {
        activeLoadTask?.cancel()
        presentsInSettings = inSettings
        retryTarget = (url, inSettings)
        phase = .loading(linkURL: url.absoluteString)
        let session = UUID()
        activeSessionID = session
        activeLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.fetchReview(from: url)
            guard !Task.isCancelled, self.activeSessionID == session else { return }
            switch outcome {
            case .success(let review): self.phase = .ready(review)
            case .failure(let failure): self.phase = .failed(failure)
            }
        }
    }

    func openImport(rawLink: String, inSettings: Bool = false) {
        let trimmed = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            activeLoadTask?.cancel()
            presentsInSettings = inSettings
            retryTarget = nil
            phase = .failed(ScriptImportFailure(
                linkURL: trimmed,
                reason: String(localized: "Enter a full HTTPS link to a .user.js file.", comment: "Validation error when the user submits a blank or malformed link in Import from link")
            ))
            activeSessionID = UUID()
            return
        }
        openImport(from: url, inSettings: inSettings)
    }

    func retryCurrentImport() {
        guard let retryTarget else { return }
        openImport(from: retryTarget.url, inSettings: retryTarget.inSettings)
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
        let saved = try scriptStore.saveImportedScript(
            review.candidate,
            installURL: review.installURL,
            sourceHost: review.finalHost,
            upstreamHash: review.upstreamHash,
            libraries: review.libraries,
            turnOn: turnOn
        )
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
        httpClient: AgentHTTPClient? = nil
    ) async -> Result<ScriptImportReview, ScriptImportFailure> {
        let linkText = url.absoluteString
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return .failure(ScriptImportFailure(
                linkURL: linkText,
                reason: String(localized: "Only HTTPS links can be imported.", comment: "Import error when a .user.js link uses http:// or another non-HTTPS scheme")
            ))
        }
        if existingScript(forInstallURL: url) != nil {
            return .failure(ScriptImportFailure(
                linkURL: linkText,
                reason: String(localized: "This script is already installed.", comment: "Import error when a script from the exact same install URL is already installed")
            ))
        }
        let client = httpClient ?? httpClientProvider()
        let response: AgentHTTPResponse
        do {
            response = try await client.send(AgentHTTPRequest(
                url: url, sendCookies: false, httpsOnly: true, maxBytes: Self.maxScriptBytes, timeout: 30
            ))
        } catch {
            return .failure(ScriptImportFailure(
                linkURL: linkText,
                reason: String(localized: "Couldn’t fetch the file: \(error.localizedDescription)", comment: "Import error when downloading the .user.js file fails with a network or redirect error")
            ))
        }
        if !(200..<300).contains(response.status) {
            return .failure(ScriptImportFailure(
                linkURL: linkText,
                reason: String(localized: "Couldn’t fetch the file: the server answered \(Self.httpStatusText(response.status)).", comment: "Import error when the server returns a non-2xx HTTP status for a .user.js file")
            ))
        }
        if response.truncated {
            return .failure(ScriptImportFailure(
                linkURL: linkText,
                reason: String(localized: "The script file is larger than 2 MB.", comment: "Import error when a .user.js file exceeds the 2 MB size cap")
            ))
        }
        guard let rawSource = response.text, !rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(ScriptImportFailure(
                linkURL: linkText,
                reason: String(localized: "The file isn’t readable UTF-8 text.", comment: "Import error when the downloaded .user.js body is empty or not valid UTF-8")
            ))
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
        let duplicateHost = scriptStore.scripts.first {
            $0.name.caseInsensitiveCompare(parsed.script.name) == .orderedSame
        }.map {
            $0.metadata.sourceHost
                ?? $0.metadata.installURL.flatMap { URL(string: $0)?.host }
                ?? String(localized: "this device", comment: "Fallback host label when a duplicate-named script was created locally on this device")
        }
        return .success(ScriptImportReview(
            duplicateNameHost: duplicateHost,
            candidate: parsed.script,
            rawSource: rawSource,
            installURL: Self.canonicalURLString(url),
            finalHost: finalHost,
            upstreamHash: upstreamHash,
            author: parsed.author,
            libraries: libraries,
            unsupportedItems: parsed.unsupported
        ))
    }

    static func fetchLibraries(
        urls: [String],
        httpClient: AgentHTTPClient
    ) async throws -> [ScriptLoadedLibrary] {
        var totalBytes = 0
        var loaded: [ScriptLoadedLibrary] = []
        for rawURL in urls {
            let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
                throw ScriptImportFailure(
                    linkURL: trimmed,
                    reason: String(localized: "Required library isn’t an HTTPS link (\(trimmed)).", comment: "Import error when a @require URL does not use HTTPS")
                )
            }
            var fetchParts = URLComponents(url: url, resolvingAgainstBaseURL: true)
            let fragment = fetchParts?.fragment
            fetchParts?.fragment = nil
            let response: AgentHTTPResponse
            do {
                response = try await httpClient.send(AgentHTTPRequest(
                    url: fetchParts?.url ?? url, sendCookies: false, httpsOnly: true, maxBytes: maxRequireBytes, timeout: 30
                ))
            } catch {
                throw ScriptImportFailure(
                    linkURL: trimmed,
                    reason: String(localized: "Couldn’t fetch required library from \(host): \(error.localizedDescription)", comment: "Import error when fetching a @require JavaScript library fails")
                )
            }
            if !(200..<300).contains(response.status) {
                throw ScriptImportFailure(
                    linkURL: trimmed,
                    reason: String(localized: "Couldn’t fetch required library from \(host): the server answered \(httpStatusText(response.status)).", comment: "Import error when a @require library server returns a non-2xx HTTP status")
                )
            }
            if response.truncated {
                throw ScriptImportFailure(
                    linkURL: trimmed,
                    reason: String(localized: "Required library from \(host) is larger than 2 MB.", comment: "Import error when a single @require library exceeds the 2 MB size cap")
                )
            }
            totalBytes += response.data.count
            if totalBytes > maxTotalRequireBytes {
                throw ScriptImportFailure(
                    linkURL: trimmed,
                    reason: String(localized: "The script’s @require libraries exceed 5 MB in total.", comment: "Import error when all @require libraries combined exceed 5 MB")
                )
            }
            guard let code = response.text else {
                throw ScriptImportFailure(
                    linkURL: trimmed,
                    reason: String(localized: "Required library from \(host) isn’t UTF-8 text.", comment: "Import error when a @require library is not valid UTF-8 text")
                )
            }
            let actualHex = ScriptStore.sha256Hex(response.data).lowercased()
            let actualB64 = Data(SHA256.hash(data: response.data)).base64EncodedString()
            if let sri = extractSRIHash(fragment: fragment), sri.lowercased() != actualHex && sri != actualB64 {
                throw ScriptImportFailure(
                    linkURL: trimmed,
                    reason: String(localized: "Required library hash didn’t match for \(host).", comment: "Import error when a @require library fails its #sha256 integrity hash check")
                )
            }
            loaded.append(ScriptLoadedLibrary(
                meta: ScriptRequiredLibrary(url: rawURL, sha256: actualHex, sizeBytes: response.data.count),
                code: code
            ))
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
            throw ScriptImportFailure(
                linkURL: "",
                reason: String(localized: "The file has no // ==UserScript== header.", comment: "Import error when a .user.js file lacks the Userscript metadata block")
            )
        }
        let sanitized = stripUntrustedWukongLines(from: normalized)
        let rawVersion = extractFirstHeaderValue("@version", in: sanitized)
        let author = extractFirstHeaderValue("@author", in: sanitized)
        var parsed: UserScript
        do {
            parsed = try UserScript.parseUserScriptFile(sanitized)
        } catch ScriptStoreError.emptyMatchRules {
            throw ScriptImportFailure(
                linkURL: "",
                reason: String(localized: "The script has no usable @match or @include rules.", comment: "Import error when a userscript declares no valid match patterns")
            )
        } catch ScriptStoreError.invalidMatchRule(let rule, _) {
            throw ScriptImportFailure(
                linkURL: "",
                reason: String(localized: "The script has an invalid @match rule (\(rule)).", comment: "Import error when one of the script's @match patterns is malformed")
            )
        } catch ScriptStoreError.emptyBody {
            throw ScriptImportFailure(
                linkURL: "",
                reason: String(localized: "The script has no JavaScript code.", comment: "Import error when a userscript has an empty body")
            )
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
                ? String(localized: "A call to either fails; the rest of the script runs.", comment: "Explanation in Not supported here when two unsupported GM_* grants are declared")
                : String(localized: "A call to any of these fails; the rest of the script runs.", comment: "Explanation in Not supported here when unsupported GM_* grants are declared")
            items.append(.init(title: unsupportedGrants.joined(separator: ", "), isMonospaced: false, detail: detail, style: .blocked))
        }
        for inc in script.metadata.values(for: "@include") where !inc.isEmpty && !MatchPattern.isValid(inc) {
            let isRegex = inc.hasPrefix("/") && inc.hasSuffix("/") && inc.count >= 2
            let detail = isRegex
                ? String(localized: "A regular-expression @include can’t be used.", comment: "Explanation in Not supported here when a script uses a regex @include rule")
                : String(localized: "This @include pattern can’t be used.", comment: "Explanation in Not supported here when a script uses a glob @include rule")
            items.append(.init(title: "@include \(inc)", isMonospaced: true, detail: detail, style: .blocked))
        }
        for exc in script.metadata.unusableExcludePatterns {
            items.append(.init(
                title: "@exclude \(exc)",
                isMonospaced: true,
                detail: String(localized: "This exclude rule can’t be used, so the script isn’t excluded there.", comment: "Explanation in Not supported here when an @exclude rule cannot be applied"),
                style: .blocked
            ))
        }
        if let runAt = script.metadata.runAtText, !runAt.isEmpty {
            items.append(.init(
                title: "@run-at \(runAt)",
                isMonospaced: true,
                detail: String(localized: "Runs at document end.", comment: "Explanation in Not supported here when an unknown @run-at value falls back to document-end"),
                style: .note
            ))
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
            rows.append(.init(
                id: "storage",
                icon: .storage,
                title: String(localized: "Keeps its own settings", comment: "Capability row for GM_getValue / GM_setValue storage grants"),
                subtitle: valueSummary,
                isDanger: false
            ))
        }
        if grants.contains("GM_xmlhttpRequest") || grants.contains("GM.xmlHttpRequest") {
            let hosts = script.metadata.connectHosts
            let isWild = hosts.contains("*")
            let title = isWild
                ? String(localized: "Sends requests to any site", comment: "Capability row when @connect * allows requests to any domain")
                : (hosts.isEmpty
                    ? String(localized: "Sends requests to the page’s own site", comment: "Capability row when GM_xmlhttpRequest has no @connect hosts and is restricted to same-site")
                    : String(localized: "Sends requests to \(hosts.joined(separator: ", "))", comment: "Capability row showing which hosts GM_xmlhttpRequest can reach"))
            rows.append(.init(id: "requests", icon: .requests, title: title, subtitle: nil, isDanger: forImportSheet && isWild))
        }
        if grants.contains("GM_ai") {
            let title = forImportSheet
                ? String(localized: "Sends text from the page to your Scripts model (\(scriptsModelName))", comment: "Danger-highlighted capability row in import review when a script requests GM_ai")
                : String(localized: "Uses AI: sends page text to \(scriptsModelName)", comment: "Capability row in Script detail when a script has the GM_ai grant")
            rows.append(.init(id: "ai", icon: .ai, title: title, subtitle: nil, isDanger: forImportSheet))
        }
        if grants.contains("GM_addStyle") || grants.contains("GM.addStyle") {
            rows.append(.init(
                id: "style",
                icon: .style,
                title: String(localized: "Adds custom styles to the page", comment: "Capability row for GM_addStyle grant"),
                subtitle: nil,
                isDanger: false
            ))
        }
        if grants.contains("GM_registerMenuCommand") {
            rows.append(.init(
                id: "menu",
                icon: .menu,
                title: String(localized: "Adds commands to This page", comment: "Capability row for GM_registerMenuCommand grant"),
                subtitle: nil,
                isDanger: false
            ))
        }
        return rows
    }

    static func isBroadEverySiteRule(_ rule: String) -> Bool {
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t == "*://*/*" || t == "<all_urls>" || t == "https://*/*" || t == "http://*/*"
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
}
