import Foundation
import Observation
import OSLog
import WebKit

// MARK: - Userscript Domain Types

enum ScriptInjectionTime: String, Codable, CaseIterable, Equatable, Sendable {
    case documentStart = "document-start"
    case documentEnd = "document-end"

    nonisolated static let defaultTime: ScriptInjectionTime = .documentEnd

    var wkInjectionTime: WKUserScriptInjectionTime {
        switch self {
        case .documentStart:
            return .atDocumentStart
        case .documentEnd:
            return .atDocumentEnd
        }
    }
}

enum ScriptSource: Codable, Equatable, Sendable {
    case agent(userPrompt: String)
    case imported

    var kindIdentifier: String {
        switch self {
        case .agent:
            return "agent"
        case .imported:
            return "imported"
        }
    }

    var userPrompt: String? {
        switch self {
        case .agent(let prompt):
            return prompt.isEmpty ? nil : prompt
        case .imported:
            return nil
        }
    }
}

struct ScriptRuntimeError: Codable, Equatable, Sendable {
    var scriptID: String
    var scriptName: String
    var message: String
    var line: Int?
    var url: String?
    var occurredAt: Date
    var count: Int

    init(
        scriptID: String,
        scriptName: String,
        message: String,
        line: Int? = nil,
        url: String? = nil,
        occurredAt: Date = Date(),
        count: Int = 1
    ) {
        self.scriptID = scriptID
        self.scriptName = scriptName
        self.message = message
        self.line = line
        self.url = url
        self.occurredAt = occurredAt
        self.count = max(1, count)
    }
}

enum ScriptVersionOrigin: Codable, Equatable, Sendable {
    case savedByAgent(userPrompt: String)
    case changedByAgent(userPrompt: String)
    case editedByUser
    case restored(fromVersion: Int)
    case imported

    var headerKind: String {
        switch self {
        case .savedByAgent: "saved-by-agent"
        case .changedByAgent: "changed-by-agent"
        case .editedByUser: "edited-by-user"
        case .restored(let v): "restored:\(v)"
        case .imported: "imported"
        }
    }

    var promptText: String? {
        switch self {
        case .savedByAgent(let p), .changedByAgent(let p):
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .editedByUser, .restored, .imported:
            return nil
        }
    }

    static func parse(headerKind: String, prompt: String) -> ScriptVersionOrigin? {
        let normalized = headerKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "saved-by-agent":
            return .savedByAgent(userPrompt: prompt)
        case "changed-by-agent":
            return .changedByAgent(userPrompt: prompt)
        case "edited-by-user":
            return .editedByUser
        case "imported":
            return .imported
        default:
            if normalized.hasPrefix("restored:"),
               let v = Int(normalized.dropFirst("restored:".count)),
               v >= 1 {
                return .restored(fromVersion: v)
            }
            return nil
        }
    }
}

enum ScriptVersionChangedField: String, CaseIterable, Equatable, Sendable {
    case name
    case matchRules
    case js
    case css
    case settings
}

struct UserScriptVersion: Identifiable, Codable, Equatable, Sendable {
    var id: Int { version }
    var version: Int
    var name: String
    var matchRules: [String]
    var js: String
    var css: String
    var injectionTime: ScriptInjectionTime
    var environment: AgentExecutionEnvironment
    var savedAt: Date
    var origin: ScriptVersionOrigin?

    init(
        version: Int,
        name: String,
        matchRules: [String],
        js: String,
        css: String,
        injectionTime: ScriptInjectionTime,
        environment: AgentExecutionEnvironment,
        savedAt: Date,
        origin: ScriptVersionOrigin? = nil
    ) {
        self.version = version
        self.name = name
        self.matchRules = matchRules
        self.js = js
        self.css = css
        self.injectionTime = injectionTime
        self.environment = environment
        self.savedAt = savedAt
        self.origin = origin
    }

    func toUserScript(from parent: UserScript) -> UserScript {
        UserScript(
            id: parent.id,
            name: name,
            matchRules: matchRules,
            js: js,
            css: css,
            injectionTime: injectionTime,
            environment: environment,
            isEnabled: parent.isEnabled,
            source: parent.source,
            version: version,
            createdAt: parent.createdAt,
            updatedAt: savedAt,
            versions: [],
            versionOrigin: origin
        )
    }
}

struct ScriptUpdatePatch: Equatable, Sendable {
    var name: String?
    var matchRules: [String]?
    var js: String?
    var css: String?
    var injectionTime: ScriptInjectionTime?
    var environment: AgentExecutionEnvironment?
    var isEnabled: Bool?

    init(
        name: String? = nil,
        matchRules: [String]? = nil,
        js: String? = nil,
        css: String? = nil,
        injectionTime: ScriptInjectionTime? = nil,
        environment: AgentExecutionEnvironment? = nil,
        isEnabled: Bool? = nil
    ) {
        self.name = name
        self.matchRules = matchRules
        self.js = js
        self.css = css
        self.injectionTime = injectionTime
        self.environment = environment
        self.isEnabled = isEnabled
    }

    var hasChanges: Bool {
        name != nil
            || matchRules != nil
            || js != nil
            || css != nil
            || injectionTime != nil
            || environment != nil
            || isEnabled != nil
    }

    var touchesVersionedFields: Bool {
        name != nil
            || matchRules != nil
            || js != nil
            || css != nil
            || injectionTime != nil
            || environment != nil
    }
}

enum ScriptStoreError: LocalizedError, Equatable, Sendable {
    case emptyName
    case emptyMatchRules
    case invalidMatchRule(rule: String, reason: String)
    case emptyBody
    case invalidScriptID(String)
    case duplicateScriptID(String)
    case scriptNotFound(String)
    case versionNotFound(scriptID: String, version: Int)
    case noPreviousVersion(scriptID: String)
    case malformedUserScript(String)
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Script name must not be empty."
        case .emptyMatchRules:
            return "At least one @match rule is required."
        case .invalidMatchRule(let rule, let reason):
            return "Invalid @match pattern '\(rule)': \(reason)"
        case .emptyBody:
            return "Provide non-empty JavaScript ('js'), CSS ('css'), or both."
        case .invalidScriptID(let id):
            return "Invalid script ID '\(id)'."
        case .duplicateScriptID(let id):
            return "A script with ID '\(id)' already exists."
        case .scriptNotFound(let id):
            return "Script '\(id)' was not found."
        case .versionNotFound(let scriptID, let version):
            return "Version \(version) was not found for script '\(scriptID)'."
        case .noPreviousVersion(let scriptID):
            return "Script '\(scriptID)' has no previous version to roll back to."
        case .malformedUserScript(let detail):
            return "Malformed userscript file: \(detail)"
        case .persistenceFailed(let detail):
            return "Failed to persist userscript: \(detail)"
        }
    }
}

// MARK: - Tampermonkey @match Parser & Matcher

enum MatchPatternError: LocalizedError, Equatable, Sendable {
    case emptyPattern
    case missingSchemeSeparator
    case invalidScheme(String)
    case missingPathSlash
    case emptyHost
    case invalidHost(String)
    case invalidPort(String)
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .emptyPattern:
            return "pattern must not be empty."
        case .missingSchemeSeparator:
            return "expected '<scheme>://<host><path>' or '<all_urls>'."
        case .invalidScheme(let scheme):
            return "unsupported scheme '\(scheme)' (expected *, http, https, http*, file, ws, or wss)."
        case .missingPathSlash:
            return "path must start with '/' (for example '/*')."
        case .emptyHost:
            return "host must not be empty for non-file schemes."
        case .invalidHost(let host):
            return "invalid host pattern '\(host)' (use '*', '*.domain.tld', or an exact host)."
        case .invalidPort(let port):
            return "invalid port '\(port)' (use digits 1-65535 or '*')."
        case .invalidPath(let path):
            return "path '\(path)' must start with '/'."
        }
    }
}

/// Parsed Tampermonkey / WebExtensions `@match` rule.
///
/// Semantics:
/// - `<all_urls>` matches any `http`, `https`, `file`, `ws`, or `wss` URL.
/// - Schemes: `*` and `http*` match `http` and `https`; `http`, `https`, `file`,
///   `ws`, and `wss` match themselves literally.
/// - Hosts: `*` matches any host; `*.example.com` matches both `example.com` and
///   any subdomain (`sub.example.com`, `a.b.example.com`), matching Tampermonkey
///   and WebExtensions `@match` behavior; exact hosts match case-insensitively.
///   Optional `:port` or `:*` restricts or wildcards the URL port; omitting `:port`
///   matches regardless of port.
/// - Paths: must begin with `/`; `*` matches zero or more characters across path
///   and query string (`pathname + search`), while `?` and other regex symbols are
///   matched literally. `#fragment` is ignored.
struct MatchPattern: Equatable, Sendable {
    enum HostRule: Equatable, Sendable {
        case any
        case fileAny
        case exact(String)
        case subdomainOrExact(String)
    }

    enum PortRule: Equatable, Sendable {
        case ignore
        case any
        case exact(Int)
    }

    let raw: String
    let isAllURLs: Bool
    let allowedSchemes: Set<String>
    let hostRule: HostRule
    let portRule: PortRule
    let pathPattern: String
    let pathRegexPattern: String
    private let compiledPathRegex: NSRegularExpression

    nonisolated static let allURLSchemes: Set<String> = ["http", "https", "file", "ws", "wss"]

    static func isValid(_ raw: String) -> Bool {
        (try? parse(raw)) != nil
    }

    static func parse(_ raw: String) throws -> MatchPattern {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MatchPatternError.emptyPattern
        }

        if trimmed == "<all_urls>" {
            let regex = try NSRegularExpression(pattern: "^[\\s\\S]*$", options: [])
            return MatchPattern(
                raw: trimmed,
                isAllURLs: true,
                allowedSchemes: allURLSchemes,
                hostRule: .any,
                portRule: .ignore,
                pathPattern: "/*",
                pathRegexPattern: "^[\\s\\S]*$",
                compiledPathRegex: regex
            )
        }

        guard let schemeRange = trimmed.range(of: "://") else {
            throw MatchPatternError.missingSchemeSeparator
        }

        let rawScheme = String(trimmed[..<schemeRange.lowerBound]).lowercased()
        let allowedSchemes: Set<String>
        switch rawScheme {
        case "*", "http*":
            allowedSchemes = ["http", "https"]
        case "http":
            allowedSchemes = ["http"]
        case "https":
            allowedSchemes = ["https"]
        case "file":
            allowedSchemes = ["file"]
        case "ws":
            allowedSchemes = ["ws"]
        case "wss":
            allowedSchemes = ["wss"]
        default:
            throw MatchPatternError.invalidScheme(rawScheme)
        }

        let afterScheme = String(trimmed[schemeRange.upperBound...])
        guard let slashIndex = afterScheme.firstIndex(of: "/") else {
            throw MatchPatternError.missingPathSlash
        }

        let rawAuthority = String(afterScheme[..<slashIndex])
        let rawPath = String(afterScheme[slashIndex...])
        guard rawPath.hasPrefix("/") else {
            throw MatchPatternError.invalidPath(rawPath)
        }

        let (hostRule, portRule) = try parseAuthority(rawAuthority, isFileScheme: rawScheme == "file")
        let regexSource = compileGlobToRegexPattern(rawPath)
        let regex = try NSRegularExpression(pattern: regexSource, options: [])

        return MatchPattern(
            raw: trimmed,
            isAllURLs: false,
            allowedSchemes: allowedSchemes,
            hostRule: hostRule,
            portRule: portRule,
            pathPattern: rawPath,
            pathRegexPattern: regexSource,
            compiledPathRegex: regex
        )
    }

    func matches(urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed) else {
            return false
        }
        return matches(components: components)
    }

    func matches(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return false
        }
        return matches(components: components)
    }

    private func matches(components: URLComponents) -> Bool {
        guard let scheme = components.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else {
            return false
        }

        let host = (components.host ?? "").lowercased()
        switch hostRule {
        case .fileAny:
            break
        case .any:
            if scheme != "file", host.isEmpty {
                return false
            }
        case .exact(let expected):
            if host != expected {
                return false
            }
        case .subdomainOrExact(let base):
            if host != base, !host.hasSuffix("." + base) {
                return false
            }
        }

        switch portRule {
        case .ignore, .any:
            break
        case .exact(let expectedPort):
            let effectivePort = components.port ?? Self.defaultPort(forScheme: scheme)
            guard effectivePort == expectedPort else {
                return false
            }
        }

        let rawPath = components.percentEncodedPath
        let normalizedPath = rawPath.isEmpty ? "/" : rawPath
        var pathAndQuery = normalizedPath
        if let query = components.percentEncodedQuery, !query.isEmpty {
            pathAndQuery += "?" + query
        }

        let nsRange = NSRange(pathAndQuery.startIndex..<pathAndQuery.endIndex, in: pathAndQuery)
        return compiledPathRegex.firstMatch(in: pathAndQuery, options: [], range: nsRange) != nil
    }

    /// Returns whether this pattern applies to the given domain or URL string.
    func matchesDomain(_ rawDomain: String) -> Bool {
        let normalized = Self.extractNormalizedHost(from: rawDomain)
        guard !normalized.isEmpty else { return false }

        if isAllURLs { return true }
        switch hostRule {
        case .any:
            return true
        case .fileAny:
            return normalized == "file" || normalized == "localhost"
        case .exact(let expected):
            return normalized == expected
        case .subdomainOrExact(let base):
            return normalized == base || normalized.hasSuffix("." + base)
        }
    }

    static func validationError(_ raw: String) -> MatchPatternError? {
        do {
            _ = try parse(raw)
            return nil
        } catch let error as MatchPatternError {
            return error
        } catch {
            return .invalidPath(raw)
        }
    }

    var primarySiteLabel: String {
        if isAllURLs { return "All sites" }
        switch hostRule {
        case .any:
            return "All sites"
        case .fileAny:
            return "Local files"
        case .exact(let host):
            return host.isEmpty ? "Local files" : host
        case .subdomainOrExact(let base):
            return base
        }
    }

    /// Host shown in the M2 Script Manager group header: preserves the rule's
    /// written host (`talk.example.org`, `*.example.org`), or returns `nil`
    /// when the rule applies to all sites (`*://*/*`, `<all_urls>`).
    var managerHostLabel: String? {
        if isAllURLs { return nil }
        switch hostRule {
        case .any, .fileAny:
            return nil
        case .exact(let host):
            return host.isEmpty ? nil : host
        case .subdomainOrExact(let base):
            return "*.\(base)"
        }
    }

    func toJSDescriptor() -> [String: Any] {
        let hostMode: String
        let hostValue: String
        switch hostRule {
        case .any:
            hostMode = "any"
            hostValue = ""
        case .fileAny:
            hostMode = "fileAny"
            hostValue = ""
        case .exact(let exact):
            hostMode = "exact"
            hostValue = exact
        case .subdomainOrExact(let base):
            hostMode = "subdomain"
            hostValue = base
        }

        let portMode: String
        let portValue: Int
        switch portRule {
        case .ignore:
            portMode = "ignore"
            portValue = 0
        case .any:
            portMode = "any"
            portValue = 0
        case .exact(let p):
            portMode = "exact"
            portValue = p
        }

        return [
            "allUrls": isAllURLs,
            "schemes": Array(allowedSchemes).sorted(),
            "hostMode": hostMode,
            "hostValue": hostValue,
            "portMode": portMode,
            "portValue": portValue,
            "pathRegex": pathRegexPattern
        ]
    }

    static func extractNormalizedHost(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("://"), let comp = URLComponents(string: trimmed), let host = comp.host {
            return host.lowercased()
        }
        let withoutPath = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        if withoutPath.hasPrefix("[") {
            if let closeBracket = withoutPath.firstIndex(of: "]") {
                return String(withoutPath[...closeBracket])
            }
            return withoutPath
        }
        if let colon = withoutPath.lastIndex(of: ":") {
            return String(withoutPath[..<colon])
        }
        return withoutPath
    }

    private static func defaultPort(forScheme scheme: String) -> Int? {
        switch scheme {
        case "http", "ws":
            return 80
        case "https", "wss":
            return 443
        default:
            return nil
        }
    }

    private static func parseAuthority(
        _ rawAuthority: String,
        isFileScheme: Bool
    ) throws -> (HostRule, PortRule) {
        if isFileScheme && (rawAuthority.isEmpty || rawAuthority == "*") {
            return (.fileAny, .ignore)
        }
        guard !rawAuthority.isEmpty else {
            throw MatchPatternError.emptyHost
        }

        if rawAuthority.contains(where: \.isWhitespace) || rawAuthority.contains("@") {
            throw MatchPatternError.invalidHost(rawAuthority)
        }

        let hostPart: String
        let portRule: PortRule

        if rawAuthority.hasPrefix("[") {
            // IPv6 literal authority, e.g. [::1] or [::1]:8080
            guard let closingBracket = rawAuthority.firstIndex(of: "]") else {
                throw MatchPatternError.invalidHost(rawAuthority)
            }
            let afterBracket = rawAuthority[rawAuthority.index(after: closingBracket)...]
            if afterBracket.isEmpty {
                hostPart = String(rawAuthority[rawAuthority.index(after: rawAuthority.startIndex)..<closingBracket]).lowercased()
                portRule = .ignore
            } else if afterBracket.hasPrefix(":") {
                let rawPort = String(afterBracket.dropFirst())
                portRule = try parsePort(rawPort)
                hostPart = String(rawAuthority[rawAuthority.index(after: rawAuthority.startIndex)..<closingBracket]).lowercased()
            } else {
                throw MatchPatternError.invalidHost(rawAuthority)
            }
            guard !hostPart.isEmpty, !hostPart.contains("*") else {
                throw MatchPatternError.invalidHost(rawAuthority)
            }
            return (.exact(hostPart), portRule)
        }

        if let colonIdx = rawAuthority.firstIndex(of: ":") {
            let afterColon = String(rawAuthority[rawAuthority.index(after: colonIdx)...])
            if afterColon.contains(":") {
                throw MatchPatternError.invalidHost(rawAuthority)
            }
            hostPart = String(rawAuthority[..<colonIdx]).lowercased()
            portRule = try parsePort(afterColon)
        } else {
            hostPart = rawAuthority.lowercased()
            portRule = .ignore
        }

        guard !hostPart.isEmpty else {
            throw MatchPatternError.emptyHost
        }

        if hostPart == "*" {
            return (.any, portRule)
        }

        if hostPart.hasPrefix("*.") {
            let suffix = String(hostPart.dropFirst(2))
            guard isValidHostLabelSequence(suffix) else {
                throw MatchPatternError.invalidHost(rawAuthority)
            }
            return (.subdomainOrExact(suffix), portRule)
        }

        if hostPart.contains("*") {
            throw MatchPatternError.invalidHost(rawAuthority)
        }

        guard isValidHostLabelSequence(hostPart) else {
            throw MatchPatternError.invalidHost(rawAuthority)
        }

        return (.exact(hostPart), portRule)
    }

    private static func parsePort(_ rawPort: String) throws -> PortRule {
        if rawPort == "*" {
            return .any
        }
        guard !rawPort.isEmpty,
              rawPort.allSatisfy(\.isASCIIWholeNumber),
              let port = Int(rawPort),
              (1...65_535).contains(port) else {
            throw MatchPatternError.invalidPort(rawPort)
        }
        return .exact(port)
    }

    private static func isValidHostLabelSequence(_ host: String) -> Bool {
        guard !host.isEmpty,
              !host.hasPrefix("."),
              !host.hasSuffix("."),
              !host.contains(".."),
              !host.contains("*") else {
            return false
        }
        for scalar in host.unicodeScalars {
            let v = scalar.value
            let isLowerAlpha = (0x61...0x7A).contains(v)
            let isDigit = (0x30...0x39).contains(v)
            let isAllowedPunct = scalar == "." || scalar == "-" || scalar == "_"
            let isNonASCIIHost = v >= 0x80
            if !(isLowerAlpha || isDigit || isAllowedPunct || isNonASCIIHost) {
                return false
            }
        }
        return true
    }

    private static func compileGlobToRegexPattern(_ glob: String) -> String {
        var out = "^"
        out.reserveCapacity(glob.count * 2 + 4)
        for ch in glob {
            if ch == "*" {
                out.append("[\\s\\S]*")
            } else if "\\^$.|+?()[]{}".contains(ch) {
                out.append("\\")
                out.append(ch)
            } else {
                out.append(ch)
            }
        }
        out.append("$")
        return out
    }
}

private extension Character {
    var isASCIIWholeNumber: Bool {
        guard let ascii = asciiValue else { return false }
        return ascii >= 48 && ascii <= 57
    }
}

// MARK: - UserScript Model & .user.js Serialization

struct UserScript: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var matchRules: [String]
    var js: String
    var css: String
    var injectionTime: ScriptInjectionTime
    var environment: AgentExecutionEnvironment
    var isEnabled: Bool
    var source: ScriptSource
    var version: Int
    var createdAt: Date
    var updatedAt: Date
    var versions: [UserScriptVersion]
    var versionOrigin: ScriptVersionOrigin?

    init(
        id: String,
        name: String,
        matchRules: [String],
        js: String = "",
        css: String = "",
        injectionTime: ScriptInjectionTime = .defaultTime,
        environment: AgentExecutionEnvironment = .defaultEnvironment,
        isEnabled: Bool = true,
        source: ScriptSource = .imported,
        version: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        versions: [UserScriptVersion] = [],
        versionOrigin: ScriptVersionOrigin? = nil
    ) {
        self.id = id
        self.name = name
        self.matchRules = matchRules
        self.js = js
        self.css = css
        self.injectionTime = injectionTime
        self.environment = environment
        self.isEnabled = isEnabled
        self.source = source
        self.version = max(1, version)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.versions = versions.sorted { $0.version < $1.version }
        self.versionOrigin = versionOrigin
    }

    var hasJS: Bool {
        !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCSS: Bool {
        !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var primarySite: String {
        for rule in matchRules {
            if let parsed = try? MatchPattern.parse(rule) {
                return parsed.primarySiteLabel
            }
        }
        return "Unknown site"
    }

    /// Host of the **first** `@match` rule as written (`talk.example.org`,
    /// `*.example.org`), or `nil` when the first rule applies to all sites
    /// (`*://*/*`, `<all_urls>`). Used by `ScriptManagerView` per M2 design.
    var managerGroupHost: String? {
        guard let first = matchRules.first,
              let parsed = try? MatchPattern.parse(first) else {
            return nil
        }
        return parsed.managerHostLabel
    }

    var isAllSitesRule: Bool {
        managerGroupHost == nil
    }

    /// Sanitizes `name` for exporting as `<name>.user.js`.
    nonisolated static func sanitizedExportFilename(from name: String) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix(".user.js") {
            base = String(base.dropLast(".user.js".count))
        }
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        var cleaned = ""
        var lastWasDash = false
        for scalar in base.unicodeScalars {
            if forbidden.contains(scalar) {
                if !lastWasDash && !cleaned.isEmpty {
                    cleaned.append("-")
                    lastWasDash = true
                }
            } else {
                cleaned.unicodeScalars.append(scalar)
                lastWasDash = false
            }
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        if cleaned.isEmpty {
            cleaned = "script"
        }
        if cleaned.count > 80 {
            cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        }
        return "\(cleaned).user.js"
    }

    /// Computes which versioned fields changed relative to `previous`.
    static func changedFields(
        from previous: (
            name: String,
            matchRules: [String],
            js: String,
            css: String,
            injectionTime: ScriptInjectionTime,
            environment: AgentExecutionEnvironment
        ),
        to current: (
            name: String,
            matchRules: [String],
            js: String,
            css: String,
            injectionTime: ScriptInjectionTime,
            environment: AgentExecutionEnvironment
        )
    ) -> [ScriptVersionChangedField] {
        var fields: [ScriptVersionChangedField] = []
        if previous.js != current.js { fields.append(.js) }
        if previous.css != current.css { fields.append(.css) }
        if previous.matchRules != current.matchRules { fields.append(.matchRules) }
        if previous.name != current.name { fields.append(.name) }
        if previous.injectionTime != current.injectionTime || previous.environment != current.environment {
            fields.append(.settings)
        }
        return fields
    }

    func matches(url: URL) -> Bool {
        for rule in matchRules {
            if let pattern = try? MatchPattern.parse(rule), pattern.matches(url: url) {
                return true
            }
        }
        return false
    }

    func matches(urlString: String) -> Bool {
        for rule in matchRules {
            if let pattern = try? MatchPattern.parse(rule), pattern.matches(urlString: urlString) {
                return true
            }
        }
        return false
    }

    func matchesDomain(_ domain: String) -> Bool {
        for rule in matchRules {
            if let pattern = try? MatchPattern.parse(rule), pattern.matchesDomain(domain) {
                return true
            }
        }
        return false
    }

    fileprivate func snapshotVersion(savedAt: Date? = nil) -> UserScriptVersion {
        UserScriptVersion(
            version: version,
            name: name,
            matchRules: matchRules,
            js: js,
            css: css,
            injectionTime: injectionTime,
            environment: environment,
            savedAt: savedAt ?? updatedAt,
            origin: versionOrigin
        )
    }

    // MARK: Standard `.user.js` Format

    private static let headerStartMarker = "// ==UserScript=="
    private static let headerEndMarker = "// ==/UserScript=="
    private static let cssBlockStartMarker = "// ==WukongCSS=="
    private static let cssBlockEndMarker = "// ==/WukongCSS=="
    private static let cssDeclarationPrefix = "  const css = "
    private static let cssDeclarationSuffix = ";"

    /// Serializes the script as a standalone, Tampermonkey-compatible `.user.js` file
    /// with a `// ==UserScript==` metadata block and lossless round-tripping of both
    /// CSS and JavaScript bodies.
    func toUserScriptFileContent() -> String {
        var lines: [String] = []
        lines.append(Self.headerStartMarker)
        lines.append("// @name \(Self.encodeHeaderValue(name))")
        for rule in matchRules {
            lines.append("// @match \(Self.encodeHeaderValue(rule))")
        }
        lines.append("// @run-at \(injectionTime.rawValue)")
        lines.append("// @version \(version)")
        lines.append("// @wukong-id \(Self.encodeHeaderValue(id))")
        lines.append("// @wukong-environment \(environment.rawValue)")
        lines.append("// @wukong-enabled \(isEnabled ? "true" : "false")")
        lines.append("// @wukong-source \(source.kindIdentifier)")
        if case .agent(let prompt) = source, !prompt.isEmpty {
            lines.append("// @wukong-prompt \(Self.encodeHeaderValue(prompt))")
        }
        if let versionOrigin {
            lines.append("// @wukong-version-origin \(Self.encodeHeaderValue(versionOrigin.headerKind))")
            if let prompt = versionOrigin.promptText {
                lines.append("// @wukong-version-prompt \(Self.encodeHeaderValue(prompt))")
            }
        }
        lines.append("// @wukong-created-at \(Self.formatISO8601(createdAt))")
        lines.append("// @wukong-updated-at \(Self.formatISO8601(updatedAt))")
        lines.append(Self.headerEndMarker)

        var output = lines.joined(separator: "\n") + "\n"
        if !css.isEmpty {
            let encodedCSS = Self.encodeSingleLineJSONString(css)
            output += """
            \(Self.cssBlockStartMarker)
            (() => {
            \(Self.cssDeclarationPrefix)\(encodedCSS)\(Self.cssDeclarationSuffix)
              if (typeof CSSStyleSheet !== "undefined" && document.adoptedStyleSheets) {
                const sheet = new CSSStyleSheet();
                sheet.replaceSync(css);
                document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
              } else {
                const style = document.createElement("style");
                style.textContent = css;
                (document.head || document.documentElement).appendChild(style);
              }
            })();
            \(Self.cssBlockEndMarker)
            """ + "\n"
        }
        output += js
        return output
    }

    static func parseUserScriptFile(
        _ content: String,
        fallbackID: String? = nil,
        defaultTimestamp: Date = Date()
    ) throws -> UserScript {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard let startRange = normalized.range(of: headerStartMarker) else {
            throw ScriptStoreError.malformedUserScript("Missing '// ==UserScript==' header.")
        }
        let afterHeaderStart = normalized[startRange.upperBound...]
        guard let endMarkerRange = findHeaderEndRange(in: afterHeaderStart) else {
            throw ScriptStoreError.malformedUserScript("Missing '// ==/UserScript==' closing header.")
        }

        let headerText = String(afterHeaderStart[..<endMarkerRange.lowerBound])
        var remainder = String(afterHeaderStart[endMarkerRange.upperBound...])
        if remainder.hasPrefix("\n") {
            remainder.removeFirst()
        }

        var parsedName: String?
        var matchRules: [String] = []
        var includeFallbacks: [String] = []
        var injectionTime: ScriptInjectionTime = .defaultTime
        var environment: AgentExecutionEnvironment = .defaultEnvironment
        var isEnabled = true
        var sourceKind: String?
        var userPrompt = ""
        var versionOriginKind: String?
        var versionOriginPrompt = ""
        var version = 1
        var explicitID: String?
        var createdAt: Date?
        var updatedAt: Date?

        for rawLine in headerText.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { continue }
            let afterComment = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard afterComment.hasPrefix("@") else { continue }

            let key: String
            let rawValue: String
            if let splitIdx = afterComment.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                key = String(afterComment[..<splitIdx]).lowercased()
                rawValue = String(afterComment[splitIdx...]).trimmingCharacters(in: .whitespaces)
            } else {
                key = afterComment.lowercased()
                rawValue = ""
            }
            let value = decodeHeaderValue(rawValue)

            switch key {
            case "@name":
                if parsedName == nil, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parsedName = value
                }
            case "@match":
                if !value.isEmpty {
                    matchRules.append(value)
                }
            case "@include":
                if !value.isEmpty {
                    includeFallbacks.append(value)
                }
            case "@run-at":
                switch value.lowercased() {
                case "document-start":
                    injectionTime = .documentStart
                case "document-end", "document-idle", "document-body":
                    injectionTime = .documentEnd
                default:
                    throw ScriptStoreError.malformedUserScript("Unsupported @run-at value '\(value)'.")
                }
            case "@version":
                if let exactInt = Int(value), exactInt >= 1 {
                    version = exactInt
                } else if let major = value.split(separator: ".").first.flatMap({ Int($0) }), major >= 1 {
                    version = major
                }
            case "@wukong-id":
                if !value.isEmpty {
                    explicitID = value
                }
            case "@wukong-environment":
                guard let env = AgentExecutionEnvironment(rawValue: value.lowercased()) else {
                    throw ScriptStoreError.malformedUserScript("Unsupported @wukong-environment value '\(value)'.")
                }
                environment = env
            case "@wukong-enabled":
                switch value.lowercased() {
                case "true", "1", "yes":
                    isEnabled = true
                case "false", "0", "no":
                    isEnabled = false
                default:
                    throw ScriptStoreError.malformedUserScript("Unsupported @wukong-enabled value '\(value)'.")
                }
            case "@wukong-source":
                sourceKind = value.lowercased()
            case "@wukong-prompt":
                userPrompt = value
            case "@wukong-version-origin":
                versionOriginKind = value
            case "@wukong-version-prompt":
                versionOriginPrompt = value
            case "@wukong-created-at":
                createdAt = parseISO8601(value)
            case "@wukong-updated-at":
                updatedAt = parseISO8601(value)
            default:
                break
            }
        }

        if matchRules.isEmpty, !includeFallbacks.isEmpty {
            matchRules = includeFallbacks.filter { MatchPattern.isValid($0) }
        }
        guard !matchRules.isEmpty else {
            throw ScriptStoreError.emptyMatchRules
        }
        for rule in matchRules {
            do {
                _ = try MatchPattern.parse(rule)
            } catch {
                throw ScriptStoreError.invalidMatchRule(rule: rule, reason: error.localizedDescription)
            }
        }

        let (extractedCSS, extractedJS) = try extractCSSAndJS(from: remainder)
        if extractedCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           extractedJS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ScriptStoreError.emptyBody
        }

        let finalName = parsedName ?? (fallbackID ?? "Imported Script").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptStoreError.emptyName
        }

        let resolvedID = explicitID ?? fallbackID ?? ScriptStore.makeSlugID(from: finalName)
        guard ScriptStore.isValidScriptID(resolvedID) else {
            throw ScriptStoreError.invalidScriptID(resolvedID)
        }

        let resolvedSource: ScriptSource
        switch sourceKind {
        case "agent":
            resolvedSource = .agent(userPrompt: userPrompt)
        default:
            resolvedSource = .imported
        }

        let created = createdAt ?? defaultTimestamp
        let updated = updatedAt ?? created
        let parsedVersionOrigin = versionOriginKind.flatMap {
            ScriptVersionOrigin.parse(headerKind: $0, prompt: versionOriginPrompt)
        }

        return UserScript(
            id: resolvedID,
            name: finalName,
            matchRules: matchRules,
            js: extractedJS,
            css: extractedCSS,
            injectionTime: injectionTime,
            environment: environment,
            isEnabled: isEnabled,
            source: resolvedSource,
            version: version,
            createdAt: created,
            updatedAt: updated,
            versions: [],
            versionOrigin: parsedVersionOrigin
        )
    }

    private static func findHeaderEndRange(in substring: Substring) -> Range<Substring.Index>? {
        var searchStart = substring.startIndex
        while searchStart < substring.endIndex,
              let candidate = substring.range(of: headerEndMarker, range: searchStart..<substring.endIndex) {
            let isAtLineStart: Bool = {
                if candidate.lowerBound == substring.startIndex { return true }
                var idx = substring.index(before: candidate.lowerBound)
                while true {
                    let ch = substring[idx]
                    if ch == "\n" { return true }
                    if ch != " " && ch != "\t" { return false }
                    if idx == substring.startIndex { return true }
                    idx = substring.index(before: idx)
                }
            }()
            let isAtLineEnd: Bool = {
                var idx = candidate.upperBound
                while idx < substring.endIndex {
                    let ch = substring[idx]
                    if ch == "\n" { return true }
                    if ch != " " && ch != "\t" { return false }
                    idx = substring.index(after: idx)
                }
                return true
            }()
            if isAtLineStart && isAtLineEnd {
                var endBound = candidate.upperBound
                while endBound < substring.endIndex, substring[endBound] == " " || substring[endBound] == "\t" {
                    endBound = substring.index(after: endBound)
                }
                return candidate.lowerBound..<endBound
            }
            searchStart = candidate.upperBound
        }
        return nil
    }

    private static func extractCSSAndJS(from body: String) throws -> (css: String, js: String) {
        let startPrefix = cssBlockStartMarker + "\n"
        guard body.hasPrefix(startPrefix),
              let endRange = body.range(of: "\n" + cssBlockEndMarker) else {
            return ("", body)
        }

        let blockInterior = String(body[body.index(body.startIndex, offsetBy: startPrefix.count)..<endRange.lowerBound])
        var parsedCSS: String?
        for line in blockInterior.components(separatedBy: "\n") {
            if line.hasPrefix(cssDeclarationPrefix), line.hasSuffix(cssDeclarationSuffix) {
                let start = line.index(line.startIndex, offsetBy: cssDeclarationPrefix.count)
                let end = line.index(line.endIndex, offsetBy: -cssDeclarationSuffix.count)
                let jsonLiteral = String(line[start..<end])
                guard let data = jsonLiteral.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(String.self, from: data) else {
                    throw ScriptStoreError.malformedUserScript("Invalid JSON string in WukongCSS block.")
                }
                parsedCSS = decoded
                break
            }
        }

        guard let css = parsedCSS else {
            throw ScriptStoreError.malformedUserScript("Missing CSS declaration inside WukongCSS block.")
        }

        var jsRemainder = String(body[endRange.upperBound...])
        if jsRemainder.hasPrefix("\n") {
            jsRemainder.removeFirst()
        }
        return (css, jsRemainder)
    }

    static func encodeHeaderValue(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        let scalars = Array(value.unicodeScalars)
        var out = ""
        out.reserveCapacity(scalars.count + 8)
        for (idx, scalar) in scalars.enumerated() {
            let isBoundarySpace = (idx == 0 || idx == scalars.count - 1) && scalar == " "
            if isBoundarySpace {
                out.append("\\x20")
                continue
            }
            switch scalar {
            case "\\":
                out.append("\\\\")
            case "\n":
                out.append("\\n")
            case "\r":
                out.append("\\r")
            case "\t":
                out.append("\\t")
            case "\u{2028}":
                out.append("\\u2028")
            case "\u{2029}":
                out.append("\\u2029")
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func decodeHeaderValue(_ encoded: String) -> String {
        guard encoded.contains("\\") else { return encoded }
        var out = ""
        out.reserveCapacity(encoded.count)
        var idx = encoded.startIndex
        while idx < encoded.endIndex {
            let ch = encoded[idx]
            if ch != "\\" {
                out.append(ch)
                idx = encoded.index(after: idx)
                continue
            }
            let nextIdx = encoded.index(after: idx)
            guard nextIdx < encoded.endIndex else {
                out.append("\\")
                break
            }
            let esc = encoded[nextIdx]
            switch esc {
            case "\\":
                out.append("\\")
                idx = encoded.index(after: nextIdx)
            case "n":
                out.append("\n")
                idx = encoded.index(after: nextIdx)
            case "r":
                out.append("\r")
                idx = encoded.index(after: nextIdx)
            case "t":
                out.append("\t")
                idx = encoded.index(after: nextIdx)
            case "x":
                if let twoAfter = encoded.index(nextIdx, offsetBy: 3, limitedBy: encoded.endIndex) {
                    let hex = encoded[encoded.index(after: nextIdx)..<twoAfter]
                    if let byte = UInt8(hex, radix: 16) {
                        out.unicodeScalars.append(UnicodeScalar(byte))
                        idx = twoAfter
                        continue
                    }
                }
                out.append("\\")
                idx = nextIdx
            case "u":
                if let fourAfter = encoded.index(nextIdx, offsetBy: 5, limitedBy: encoded.endIndex) {
                    let hex = encoded[encoded.index(after: nextIdx)..<fourAfter]
                    if let codePoint = UInt32(hex, radix: 16), let scalar = UnicodeScalar(codePoint) {
                        out.unicodeScalars.append(scalar)
                        idx = fourAfter
                        continue
                    }
                }
                out.append("\\")
                idx = nextIdx
            default:
                out.append("\\")
                out.append(esc)
                idx = encoded.index(after: nextIdx)
            }
        }
        return out
    }

    fileprivate static func encodeSingleLineJSONString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // Escape U+2028 / U+2029 so JS string literals remain strictly single-line.
        return encoded
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func formatISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: string) {
            return parsed
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }
}

// MARK: - Observable ScriptStore

/// Manages per-site userscripts stored as `.user.js` files in Application Support,
/// including version history, rollback, per-script error state, and the global
/// script kill switch.
@MainActor
@Observable
final class ScriptStore {
    nonisolated private static let log = Logger(subsystem: AppIdentity.identifierPrefix, category: "script-store")

    struct ManagerScriptGroup: Identifiable, Equatable {
        /// `nil` represents the "All sites" bucket (`*://*/*`, `<all_urls>`).
        var host: String?
        var scripts: [UserScript]

        var id: String { host ?? "all" }
        var identifierHost: String { host ?? "all" }
    }

    let directoryURL: URL
    private(set) var scripts: [UserScript] = [] {
        didSet { onStoreChanged?() }
    }
    private(set) var scriptErrors: [String: ScriptRuntimeError] = [:] {
        didSet { onStoreChanged?() }
    }
    private(set) var lastExecutedAt: [String: Date] = [:] {
        didSet { onStoreChanged?() }
    }

    var isGlobalEnabled: Bool {
        didSet {
            guard isGlobalEnabled != oldValue else { return }
            onGlobalEnabledChanged?(isGlobalEnabled)
            onStoreChanged?()
            syncAttachedWebControllersForGlobalToggle()
        }
    }

    @ObservationIgnored
    var onGlobalEnabledChanged: (@MainActor (Bool) -> Void)?

    @ObservationIgnored
    var onStoreChanged: (@MainActor () -> Void)?

    @ObservationIgnored
    private var attachedControllers: [WeakScriptWebController] = []

    private struct WeakScriptWebController {
        weak var controller: ScriptWebController?
    }

    init(
        directoryURL: URL = ScriptStore.defaultDirectoryURL(),
        isGlobalEnabled: Bool = true
    ) {
        self.directoryURL = directoryURL
        self.isGlobalEnabled = isGlobalEnabled
        reloadFromDisk()
    }

    nonisolated static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("Forumind", isDirectory: true)
            .appendingPathComponent("Scripts", isDirectory: true)
    }

    nonisolated static func isValidScriptID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, id != ".", id != ".." else {
            return false
        }
        for scalar in id.unicodeScalars {
            let v = scalar.value
            let isAlphaNum = (0x30...0x39).contains(v)
                || (0x41...0x5A).contains(v)
                || (0x61...0x7A).contains(v)
            let isSafePunct = scalar == "-" || scalar == "_" || scalar == "."
            if !(isAlphaNum || isSafePunct) {
                return false
            }
        }
        return true
    }

    nonisolated static func makeSlugID(from name: String, existingIDs: Set<String> = []) -> String {
        var slug = ""
        var previousWasHyphen = false
        for scalar in name.lowercased().unicodeScalars {
            let v = scalar.value
            if (0x61...0x7A).contains(v) || (0x30...0x39).contains(v) {
                slug.unicodeScalars.append(scalar)
                previousWasHyphen = false
            } else if !previousWasHyphen && !slug.isEmpty {
                slug.append("-")
                previousWasHyphen = true
            }
            if slug.count >= 40 { break }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        if slug.isEmpty {
            slug = "script"
        }

        for _ in 0..<16 {
            let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6))
            let candidate = "\(slug)-\(suffix)"
            if !existingIDs.contains(candidate) {
                return candidate
            }
        }
        return "\(slug)-\(UUID().uuidString.lowercased())"
    }

    // MARK: Queries (Tools + M2 UI)

    func script(id: String) -> UserScript? {
        scripts.first { $0.id == id }
    }

    /// Scripts whose `@match` rules match `url`. Pass `includeDisabled: true`
    /// for UI surfaces (such as the toolbar badge popover) that list disabled
    /// matching scripts alongside enabled ones.
    func scripts(matching url: URL, includeDisabled: Bool = false) -> [UserScript] {
        scripts.filter { script in
            (includeDisabled || script.isEnabled) && script.matches(url: url)
        }
    }

    func scripts(matchingURLString urlString: String, includeDisabled: Bool = false) -> [UserScript] {
        scripts.filter { script in
            (includeDisabled || script.isEnabled) && script.matches(urlString: urlString)
        }
    }

    /// Scripts that actively execute on `url` right now, honoring both the global
    /// switch and each script's `isEnabled` flag.
    func activeScripts(matching url: URL) -> [UserScript] {
        guard isGlobalEnabled else { return [] }
        return scripts(matching: url, includeDisabled: false)
    }

    func scripts(matchingDomain domain: String) -> [UserScript] {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return scripts }
        return scripts.filter { $0.matchesDomain(trimmed) }
    }

    /// Scripts grouped by primary site label for the M2 Script Manager UI.
    var scriptsBySite: [(site: String, scripts: [UserScript])] {
        var buckets: [String: [UserScript]] = [:]
        for script in scripts {
            buckets[script.primarySite, default: []].append(script)
        }
        return buckets.keys.sorted().map { site in
            (site: site, scripts: buckets[site] ?? [])
        }
    }

    /// Scripts grouped by the written host of their first `@match` rule (with
    /// "All sites" last) and sorted by name within each group, per `design-m2.md`.
    var managerGroups: [ManagerScriptGroup] {
        var hostBuckets: [String: [UserScript]] = [:]
        var allSitesBucket: [UserScript] = []
        for script in scripts {
            if let host = script.managerGroupHost {
                hostBuckets[host, default: []].append(script)
            } else {
                allSitesBucket.append(script)
            }
        }
        let sortedHosts = hostBuckets.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        var result: [ManagerScriptGroup] = sortedHosts.map { host in
            ManagerScriptGroup(
                host: host,
                scripts: Self.sortedByName(hostBuckets[host] ?? [])
            )
        }
        if !allSitesBucket.isEmpty {
            result.append(
                ManagerScriptGroup(
                    host: nil,
                    scripts: Self.sortedByName(allSitesBucket)
                )
            )
        }
        return result
    }

    /// Matching scripts for `url`, sorted by name (same order as `ScriptManagerView`).
    func sortedMatchingScripts(for url: URL, includeDisabled: Bool = true) -> [UserScript] {
        Self.sortedByName(scripts(matching: url, includeDisabled: includeDisabled))
    }

    nonisolated static func sortedByName(_ list: [UserScript]) -> [UserScript] {
        list.sorted { lhs, rhs in
            let cmp = lhs.name.localizedStandardCompare(rhs.name)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    func noteExecuted(scriptID: String, at date: Date = Date()) {
        lastExecutedAt[scriptID] = date
    }

    func error(for scriptID: String) -> ScriptRuntimeError? {
        scriptErrors[scriptID]
    }

    var errorCount: Int {
        scriptErrors.count
    }

    func versions(for scriptID: String) -> [UserScriptVersion] {
        script(id: scriptID)?.versions ?? []
    }

    // MARK: CRUD, Versioning & Rollback

    @discardableResult
    func create(
        id: String? = nil,
        name: String,
        matchRules: [String],
        js: String = "",
        css: String = "",
        injectionTime: ScriptInjectionTime = .defaultTime,
        environment: AgentExecutionEnvironment = .defaultEnvironment,
        isEnabled: Bool = true,
        source: ScriptSource = .imported,
        now: Date = Date()
    ) throws -> UserScript {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ScriptStoreError.emptyName
        }

        let cleanedRules = try Self.validateMatchRules(matchRules)
        try Self.validateBody(js: js, css: css)

        let existingIDs = Set(scripts.map(\.id))
        let resolvedID: String
        if let explicit = id?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            guard Self.isValidScriptID(explicit) else {
                throw ScriptStoreError.invalidScriptID(explicit)
            }
            guard !existingIDs.contains(explicit) else {
                throw ScriptStoreError.duplicateScriptID(explicit)
            }
            resolvedID = explicit
        } else {
            resolvedID = Self.makeSlugID(from: trimmedName, existingIDs: existingIDs)
        }

        let created = UserScript(
            id: resolvedID,
            name: trimmedName,
            matchRules: cleanedRules,
            js: js,
            css: css,
            injectionTime: injectionTime,
            environment: environment,
            isEnabled: isEnabled,
            source: source,
            version: 1,
            createdAt: now,
            updatedAt: now,
            versions: []
        )

        try writeScriptFile(created)
        scripts.append(created)
        sortScriptsInPlace()
        scriptErrors.removeValue(forKey: created.id)
        syncAttachedUserScripts()
        return created
    }

    @discardableResult
    func importUserScript(
        _ fileContent: String,
        preferredID: String? = nil,
        now: Date = Date()
    ) throws -> UserScript {
        var parsed = try UserScript.parseUserScriptFile(
            fileContent,
            fallbackID: preferredID,
            defaultTimestamp: now
        )
        let existingIDs = Set(scripts.map(\.id))
        if existingIDs.contains(parsed.id) {
            parsed.id = Self.makeSlugID(from: parsed.name, existingIDs: existingIDs)
        }
        parsed.updatedAt = now
        try writeScriptFile(parsed)
        scripts.append(parsed)
        sortScriptsInPlace()
        scriptErrors.removeValue(forKey: parsed.id)
        syncAttachedUserScripts()
        return parsed
    }

    @discardableResult
    func update(
        id: String,
        patch: ScriptUpdatePatch,
        origin: ScriptVersionOrigin? = nil,
        now: Date = Date()
    ) throws -> UserScript {
        guard let idx = scripts.firstIndex(where: { $0.id == id }) else {
            throw ScriptStoreError.scriptNotFound(id)
        }
        let existing = scripts[idx]

        if !patch.touchesVersionedFields {
            if let enabled = patch.isEnabled {
                return try setEnabled(id: id, isEnabled: enabled, now: now)
            }
            return existing
        }

        let nextName: String
        if let rawName = patch.name {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ScriptStoreError.emptyName }
            nextName = trimmed
        } else {
            nextName = existing.name
        }

        let nextRules: [String]
        if let rawRules = patch.matchRules {
            nextRules = try Self.validateMatchRules(rawRules)
        } else {
            nextRules = existing.matchRules
        }

        let nextJS = patch.js ?? existing.js
        let nextCSS = patch.css ?? existing.css
        try Self.validateBody(js: nextJS, css: nextCSS)

        let nextInjectionTime = patch.injectionTime ?? existing.injectionTime
        let nextEnvironment = patch.environment ?? existing.environment
        let nextEnabled = patch.isEnabled ?? existing.isEnabled

        let archivedSnapshot = existing.snapshotVersion()
        var updatedVersions = existing.versions.filter { $0.version != archivedSnapshot.version }
        updatedVersions.append(archivedSnapshot)
        updatedVersions.sort { $0.version < $1.version }

        let maxKnownVersion = max(existing.version, updatedVersions.map(\.version).max() ?? 0)
        let nextVersion = maxKnownVersion + 1

        let updated = UserScript(
            id: existing.id,
            name: nextName,
            matchRules: nextRules,
            js: nextJS,
            css: nextCSS,
            injectionTime: nextInjectionTime,
            environment: nextEnvironment,
            isEnabled: nextEnabled,
            source: existing.source,
            version: nextVersion,
            createdAt: existing.createdAt,
            updatedAt: now,
            versions: updatedVersions,
            versionOrigin: origin
        )

        try writeVersionArchive(for: existing)
        try writeScriptFile(updated)

        scripts[idx] = updated
        sortScriptsInPlace()
        scriptErrors.removeValue(forKey: id)
        syncAttachedUserScripts()
        return updated
    }

    @discardableResult
    func setEnabled(
        id: String,
        isEnabled: Bool,
        runLiveJS: Bool = false,
        now: Date = Date()
    ) throws -> UserScript {
        guard let idx = scripts.firstIndex(where: { $0.id == id }) else {
            throw ScriptStoreError.scriptNotFound(id)
        }
        var current = scripts[idx]
        guard current.isEnabled != isEnabled else {
            return current
        }
        current.isEnabled = isEnabled
        current.updatedAt = now
        try writeScriptFile(current)
        scripts[idx] = current
        if !isEnabled {
            scriptErrors.removeValue(forKey: id)
        }
        syncAttachedUserScripts()
        for entry in attachedControllers {
            guard let controller = entry.controller else { continue }
            Task { @MainActor in
                if isEnabled {
                    _ = await controller.applyLiveScript(current, runJS: runLiveJS)
                } else {
                    await controller.removeLiveScript(id: id)
                }
            }
        }
        return current
    }

    /// Rolls `id` back to `targetVersion` (or the most recent archived version when
    /// `targetVersion` is `nil`), keeping the outgoing version in history as well.
    @discardableResult
    func rollback(
        id: String,
        toVersion targetVersion: Int? = nil,
        now: Date = Date()
    ) throws -> UserScript {
        guard let idx = scripts.firstIndex(where: { $0.id == id }) else {
            throw ScriptStoreError.scriptNotFound(id)
        }
        let current = scripts[idx]
        guard !current.versions.isEmpty else {
            throw ScriptStoreError.noPreviousVersion(scriptID: id)
        }

        let target: UserScriptVersion
        if let requested = targetVersion {
            guard let found = current.versions.first(where: { $0.version == requested }) else {
                throw ScriptStoreError.versionNotFound(scriptID: id, version: requested)
            }
            target = found
        } else {
            target = current.versions[current.versions.count - 1]
        }

        let outgoingSnapshot = current.snapshotVersion()
        var updatedVersions = current.versions.filter { $0.version != outgoingSnapshot.version }
        updatedVersions.append(outgoingSnapshot)
        updatedVersions.sort { $0.version < $1.version }

        let maxKnownVersion = max(current.version, updatedVersions.map(\.version).max() ?? 0)
        let nextVersion = maxKnownVersion + 1

        let restored = UserScript(
            id: current.id,
            name: target.name,
            matchRules: target.matchRules,
            js: target.js,
            css: target.css,
            injectionTime: target.injectionTime,
            environment: target.environment,
            isEnabled: current.isEnabled,
            source: current.source,
            version: nextVersion,
            createdAt: current.createdAt,
            updatedAt: now,
            versions: updatedVersions,
            versionOrigin: .restored(fromVersion: target.version)
        )

        try writeVersionArchive(for: current)
        try writeScriptFile(restored)

        scripts[idx] = restored
        sortScriptsInPlace()
        scriptErrors.removeValue(forKey: id)
        syncAttachedUserScripts()
        for entry in attachedControllers {
            guard let controller = entry.controller else { continue }
            Task { @MainActor in
                if restored.isEnabled {
                    _ = await controller.applyLiveScript(restored, runJS: false)
                } else {
                    await controller.removeLiveScript(id: id)
                }
            }
        }
        return restored
    }

    @discardableResult
    func delete(id: String) throws -> UserScript {
        guard let idx = scripts.firstIndex(where: { $0.id == id }) else {
            throw ScriptStoreError.scriptNotFound(id)
        }
        let removed = scripts.remove(at: idx)
        scriptErrors.removeValue(forKey: id)
        try removeScriptFilesFromDisk(id: id)
        syncAttachedUserScripts()
        for entry in attachedControllers {
            guard let controller = entry.controller else { continue }
            Task { @MainActor in
                await controller.removeLiveScript(id: id)
            }
        }
        return removed
    }

    @discardableResult
    func deleteIfPresent(id: String) -> UserScript? {
        try? delete(id: id)
    }

    func restore(_ script: UserScript) throws {
        guard Self.isValidScriptID(script.id) else {
            throw ScriptStoreError.invalidScriptID(script.id)
        }
        _ = try Self.validateMatchRules(script.matchRules)
        try Self.validateBody(js: script.js, css: script.css)

        let versionDir = versionsDirectoryURL(for: script.id)
        if FileManager.default.fileExists(atPath: versionDir.path) {
            try? FileManager.default.removeItem(at: versionDir)
        }
        try writeScriptFile(script)
        for historical in script.versions {
            let historicalScript = UserScript(
                id: script.id,
                name: historical.name,
                matchRules: historical.matchRules,
                js: historical.js,
                css: historical.css,
                injectionTime: historical.injectionTime,
                environment: historical.environment,
                isEnabled: script.isEnabled,
                source: script.source,
                version: historical.version,
                createdAt: script.createdAt,
                updatedAt: historical.savedAt,
                versions: [],
                versionOrigin: historical.origin
            )
            try writeVersionArchive(for: historicalScript)
        }

        if let idx = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[idx] = script
        } else {
            scripts.append(script)
        }
        sortScriptsInPlace()
        syncAttachedUserScripts()
        for entry in attachedControllers {
            guard let controller = entry.controller else { continue }
            Task { @MainActor in
                if script.isEnabled {
                    _ = await controller.applyLiveScript(script, runJS: false)
                } else {
                    await controller.removeLiveScript(id: script.id)
                }
            }
        }
    }

    // MARK: Runtime Error State

    func recordError(
        scriptID: String,
        message: String,
        line: Int? = nil,
        url: String? = nil,
        occurredAt: Date = Date()
    ) {
        let name = script(id: scriptID)?.name ?? scriptID
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unknown userscript error"
            : message
        let nextCount = (scriptErrors[scriptID]?.count ?? 0) + 1
        let runtimeError = ScriptRuntimeError(
            scriptID: scriptID,
            scriptName: name,
            message: cleanMessage,
            line: line,
            url: url,
            occurredAt: occurredAt,
            count: nextCount
        )
        scriptErrors[scriptID] = runtimeError
        Self.log.error(
            "Userscript error [\(scriptID, privacy: .public)] (\(name, privacy: .public)): \(cleanMessage, privacy: .public)"
        )
    }

    func clearError(for scriptID: String) {
        scriptErrors.removeValue(forKey: scriptID)
    }

    func clearAllErrors() {
        scriptErrors.removeAll()
    }

    // MARK: Disk Persistence

    func scriptFileURL(for id: String) -> URL {
        directoryURL.appendingPathComponent("\(id).user.js", isDirectory: false)
    }

    func versionsDirectoryURL(for id: String) -> URL {
        directoryURL
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    func versionFileURL(for id: String, version: Int) -> URL {
        versionsDirectoryURL(for: id)
            .appendingPathComponent("v\(version).user.js", isDirectory: false)
    }

    func reloadFromDisk() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path) else {
            if !scripts.isEmpty {
                scripts = []
            }
            syncAttachedUserScripts()
            return
        }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Self.log.error("Failed listing scripts directory: \(error.localizedDescription, privacy: .public)")
            scripts = []
            return
        }

        var loaded: [UserScript] = []
        for fileURL in entries where fileURL.lastPathComponent.hasSuffix(".user.js") {
            let filename = fileURL.lastPathComponent
            let fallbackID = String(filename.dropLast(".user.js".count))
            guard Self.isValidScriptID(fallbackID) else { continue }
            do {
                let raw = try String(contentsOf: fileURL, encoding: .utf8)
                let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                var script = try UserScript.parseUserScriptFile(
                    raw,
                    fallbackID: fallbackID,
                    defaultTimestamp: mtime
                )
                script.versions = loadArchivedVersions(for: script.id)
                loaded.append(script)
            } catch {
                Self.log.error(
                    "Skipping unreadable userscript \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        scripts = loaded
        sortScriptsInPlace()
        syncAttachedUserScripts()
    }

    private func loadArchivedVersions(for scriptID: String) -> [UserScriptVersion] {
        let fm = FileManager.default
        let versionDir = versionsDirectoryURL(for: scriptID)
        guard fm.fileExists(atPath: versionDir.path),
              let files = try? fm.contentsOfDirectory(
                  at: versionDir,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var archives: [UserScriptVersion] = []
        for fileURL in files where fileURL.lastPathComponent.hasSuffix(".user.js") {
            guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if let parsed = try? UserScript.parseUserScriptFile(
                raw,
                fallbackID: scriptID,
                defaultTimestamp: mtime
            ) {
                archives.append(
                    UserScriptVersion(
                        version: parsed.version,
                        name: parsed.name,
                        matchRules: parsed.matchRules,
                        js: parsed.js,
                        css: parsed.css,
                        injectionTime: parsed.injectionTime,
                        environment: parsed.environment,
                        savedAt: parsed.updatedAt,
                        origin: parsed.versionOrigin
                    )
                )
            }
        }
        archives.sort { $0.version < $1.version }
        return archives
    }

    private func writeScriptFile(_ script: UserScript) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = Data(script.toUserScriptFileContent().utf8)
            try data.write(to: scriptFileURL(for: script.id), options: .atomic)
        } catch {
            throw ScriptStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    private func writeVersionArchive(for script: UserScript) throws {
        let fm = FileManager.default
        let versionDir = versionsDirectoryURL(for: script.id)
        do {
            try fm.createDirectory(at: versionDir, withIntermediateDirectories: true)
            let data = Data(script.toUserScriptFileContent().utf8)
            try data.write(to: versionFileURL(for: script.id, version: script.version), options: .atomic)
        } catch {
            throw ScriptStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    private func removeScriptFilesFromDisk(id: String) throws {
        let fm = FileManager.default
        let fileURL = scriptFileURL(for: id)
        let versionDir = versionsDirectoryURL(for: id)
        do {
            if fm.fileExists(atPath: fileURL.path) {
                try fm.removeItem(at: fileURL)
            }
            if fm.fileExists(atPath: versionDir.path) {
                try fm.removeItem(at: versionDir)
            }
        } catch {
            throw ScriptStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    private func sortScriptsInPlace() {
        scripts.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    // MARK: Validation Helpers

    static func validateMatchRules(_ matchRules: [String]) throws -> [String] {
        let cleaned = matchRules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ !$0.isEmpty }) else {
            throw ScriptStoreError.emptyMatchRules
        }
        for rule in cleaned {
            do {
                _ = try MatchPattern.parse(rule)
            } catch {
                throw ScriptStoreError.invalidMatchRule(rule: rule, reason: error.localizedDescription)
            }
        }
        return cleaned
    }

    static func validateBody(js: String, css: String) throws {
        if js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ScriptStoreError.emptyBody
        }
    }

    // MARK: Web Controller Attachment

    fileprivate func registerWebController(_ controller: ScriptWebController) {
        attachedControllers.removeAll { $0.controller == nil || $0.controller === controller }
        attachedControllers.append(WeakScriptWebController(controller: controller))
    }

    fileprivate func unregisterWebController(_ controller: ScriptWebController) {
        attachedControllers.removeAll { $0.controller == nil || $0.controller === controller }
    }

    private func syncAttachedUserScripts() {
        attachedControllers.removeAll { $0.controller == nil }
        for entry in attachedControllers {
            entry.controller?.syncUserScripts()
        }
    }

    private func syncAttachedWebControllersForGlobalToggle() {
        attachedControllers.removeAll { $0.controller == nil }
        let enabled = isGlobalEnabled
        for entry in attachedControllers {
            guard let controller = entry.controller else { continue }
            controller.syncUserScripts()
            Task { @MainActor in
                await controller.syncLiveGlobalState(isEnabled: enabled)
            }
        }
    }
}

// MARK: - Live Page Application Protocol & WKWebView Injector

struct ScriptLiveApplicationOutcome: Equatable, Sendable {
    var applied: Bool
    var runtimeError: String?

    nonisolated static let notApplied = ScriptLiveApplicationOutcome(applied: false, runtimeError: nil)
}

protocol ScriptLiveApplying: Sendable {
    @MainActor func applyLiveScript(_ script: UserScript, runJS: Bool) async -> ScriptLiveApplicationOutcome
    @MainActor func removeLiveScript(id: String) async
    @MainActor func syncLiveGlobalState(isEnabled: Bool) async
}

/// Bridges a `ScriptStore` to a `WKWebView` + `AgentBridge`:
/// - Registers enabled userscripts as `WKUserScript`s at `.atDocumentStart` or
///   `.atDocumentEnd` in `.page` or `AgentBridge.isolatedWorld` without removing
///   Forumind's own built-in `WKUserScript`s.
/// - Injects userscript CSS via `CSSStyleSheet` + `adoptedStyleSheets` across
///   `document` and open shadow roots so styles work under strict `style-src` CSP
///   and can be removed cleanly when disabled, deleted, or globally switched off.
/// - Re-runs matching userscripts on SPA route changes (`pushState`, `replaceState`,
///   `popstate`, `hashchange`).
/// - Captures userscript errors from both `.isolated` and `.page` worlds through the
///   isolated-only `wukongAgent` message handler, logging them and updating
///   `ScriptStore.scriptErrors`.
@MainActor
final class ScriptWebController: ScriptLiveApplying {
    weak var webView: WKWebView?
    let store: ScriptStore
    weak var agentBridge: AgentBridge?

    private lazy var relayToken = UUID().uuidString
    private var managedUserScripts: [ObjectIdentifier: WKUserScript] = [:]
    private var previousReplyRouter: (([String: Any]) async throws -> Any?)?
    private var isReplyRouterInstalled = false

    init(webView: WKWebView, store: ScriptStore, agentBridge: AgentBridge) {
        self.webView = webView
        self.store = store
        self.agentBridge = agentBridge

        store.registerWebController(self)
        syncUserScripts()
    }

    func detach() {
        store.unregisterWebController(self)
        removeAllManagedUserScripts()
        if isReplyRouterInstalled {
            agentBridge?.replyRouter = previousReplyRouter
            previousReplyRouter = nil
            isReplyRouterInstalled = false
        }
    }

    private func installReplyRouterIfNeeded() {
        guard !isReplyRouterInstalled, let agentBridge else { return }
        let fallbackRouter = agentBridge.replyRouter
        previousReplyRouter = fallbackRouter
        isReplyRouterInstalled = true
        agentBridge.replyRouter = { [weak self] payload in
            if let action = payload["action"] as? String, action == "scriptError" {
                await MainActor.run {
                    self?.handleReportedScriptError(payload)
                }
                return ["ok": true]
            }
            if let fallbackRouter {
                return try await fallbackRouter(payload)
            }
            let unknown = (payload["action"] as? String) ?? ""
            throw AgentBridgeError.javaScriptFailed("Unsupported isolated bridge action '\(unknown)'.")
        }
    }

    private static func contentWorld(for environment: AgentExecutionEnvironment) -> WKContentWorld {
        switch environment {
        case .page:
            return .page
        case .isolated:
            return AgentBridge.isolatedWorld
        }
    }

    /// Rebuilds managed `WKUserScript`s on `webView.configuration.userContentController`
    /// while preserving all non-ScriptStore `WKUserScript`s (such as Forumind's
    /// `routeObserverScript` and Discourse moderation/browse bridges).
    func syncUserScripts() {
        guard let webView else { return }
        let enabledScripts = store.isGlobalEnabled ? store.scripts.filter(\.isEnabled) : []
        if managedUserScripts.isEmpty, enabledScripts.isEmpty {
            return
        }

        let controller = webView.configuration.userContentController
        let preserved = controller.userScripts.filter { managedUserScripts[ObjectIdentifier($0)] == nil }
        controller.removeAllUserScripts()
        managedUserScripts.removeAll()

        for existing in preserved {
            controller.addUserScript(existing)
        }

        guard !enabledScripts.isEmpty else { return }
        installReplyRouterIfNeeded()

        addManagedUserScript(
            WKUserScript(
                source: Self.isolatedBootstrapSource(relayToken: relayToken),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: AgentBridge.isolatedWorld
            ),
            to: controller
        )

        addManagedUserScript(
            WKUserScript(
                source: Self.pageBootstrapSource(relayToken: relayToken),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ),
            to: controller
        )

        for script in enabledScripts {
            if script.hasCSS {
                addManagedUserScript(
                    WKUserScript(
                        source: Self.buildCSSUserScriptSource(for: script),
                        injectionTime: script.injectionTime.wkInjectionTime,
                        forMainFrameOnly: true,
                        in: AgentBridge.isolatedWorld
                    ),
                    to: controller
                )
            }

            if script.hasJS {
                let targetWorld = Self.contentWorld(for: script.environment)
                addManagedUserScript(
                    WKUserScript(
                        source: Self.buildJSUserScriptSource(for: script, relayToken: relayToken),
                        injectionTime: script.injectionTime.wkInjectionTime,
                        forMainFrameOnly: true,
                        in: targetWorld
                    ),
                    to: controller
                )
            }
        }
    }

    // MARK: Live Page Sync (script_save / script_update / script_delete / global switch)

    func applyLiveScript(_ script: UserScript, runJS: Bool) async -> ScriptLiveApplicationOutcome {
        guard store.isGlobalEnabled, script.isEnabled else {
            await removeLiveScript(id: script.id)
            return .notApplied
        }
        guard let currentURL = await currentLoadedURL() else {
            return .notApplied
        }
        guard script.matches(url: currentURL) else {
            await removeLiveScript(id: script.id)
            return .notApplied
        }

        installReplyRouterIfNeeded()
        await ensureBootstrapsInstalledOnCurrentPage()

        if script.hasCSS {
            _ = try? await evalAsync(
                script: """
                if (typeof window.__wukongSetUserScriptCSS === "function") {
                  window.__wukongSetUserScriptCSS(scriptId, cssText);
                }
                if (window.__wukongDisabledScriptIDs) {
                  delete window.__wukongDisabledScriptIDs[scriptId];
                }
                const rules = compiledRules;
                const syncCSSOnRoute = () => {
                  if (!window.__wukongScriptsGlobalEnabled) return;
                  if (window.__wukongDisabledScriptIDs && window.__wukongDisabledScriptIDs[scriptId]) return;
                  if (window.__wukongMatchesRules(rules, String(window.location.href || ""))) {
                    window.__wukongSetUserScriptCSS(scriptId, cssText);
                  } else {
                    window.__wukongRemoveUserScriptCSS(scriptId);
                  }
                };
                if (window.__wukongLiveCSSRouteHandlers) {
                  window.__wukongLiveCSSRouteHandlers.set(scriptId, syncCSSOnRoute);
                }
                return true;
                """,
                arguments: [
                    "scriptId": script.id,
                    "cssText": script.css,
                    "compiledRules": Self.compiledRulesArray(for: script)
                ],
                world: AgentBridge.isolatedWorld
            )
        } else {
            _ = try? await evalAsync(
                script: """
                if (typeof window.__wukongRemoveUserScriptCSS === "function") {
                  window.__wukongRemoveUserScriptCSS(scriptId);
                }
                if (window.__wukongLiveCSSRouteHandlers) {
                  window.__wukongLiveCSSRouteHandlers.delete(scriptId);
                }
                return true;
                """,
                arguments: ["scriptId": script.id],
                world: AgentBridge.isolatedWorld
            )
        }

        var capturedError: String?
        if script.hasJS {
            let otherWorld: WKContentWorld = (script.environment == .page) ? AgentBridge.isolatedWorld : .page
            _ = try? await evalAsync(
                script: """
                if (window.__wukongLiveJSRouteHandlers) {
                  window.__wukongLiveJSRouteHandlers.delete(scriptId);
                }
                return true;
                """,
                arguments: ["scriptId": script.id],
                world: otherWorld
            )
            let world = Self.contentWorld(for: script.environment)
            let liveRunner = Self.buildLiveJSInstallAndRunSource(
                for: script,
                relayToken: relayToken,
                executeImmediately: runJS
            )
            if let dict = (try? await evalAsync(script: liveRunner, arguments: [:], world: world)) as? [String: Any],
               let errMessage = dict["error"] as? String,
               !errMessage.isEmpty {
                capturedError = errMessage
            }
        } else {
            for world in [AgentBridge.isolatedWorld, WKContentWorld.page] {
                _ = try? await evalAsync(
                    script: """
                    if (window.__wukongLiveJSRouteHandlers) {
                      window.__wukongLiveJSRouteHandlers.delete(scriptId);
                    }
                    return true;
                    """,
                    arguments: ["scriptId": script.id],
                    world: world
                )
            }
        }

        store.noteExecuted(scriptID: script.id)
        return ScriptLiveApplicationOutcome(applied: true, runtimeError: capturedError)
    }

    func removeLiveScript(id: String) async {
        guard webView != nil else { return }
        _ = try? await evalAsync(
            script: """
            if (!window.__wukongDisabledScriptIDs) window.__wukongDisabledScriptIDs = {};
            window.__wukongDisabledScriptIDs[scriptId] = true;
            if (typeof window.__wukongRemoveUserScriptCSS === "function") {
              window.__wukongRemoveUserScriptCSS(scriptId);
            }
            if (window.__wukongLiveCSSRouteHandlers) {
              window.__wukongLiveCSSRouteHandlers.delete(scriptId);
            }
            if (window.__wukongLiveJSRouteHandlers) {
              window.__wukongLiveJSRouteHandlers.delete(scriptId);
            }
            return true;
            """,
            arguments: ["scriptId": id],
            world: AgentBridge.isolatedWorld
        )
        _ = try? await evalAsync(
            script: """
            if (!window.__wukongDisabledScriptIDs) window.__wukongDisabledScriptIDs = {};
            window.__wukongDisabledScriptIDs[scriptId] = true;
            if (window.__wukongLiveJSRouteHandlers) {
              window.__wukongLiveJSRouteHandlers.delete(scriptId);
            }
            return true;
            """,
            arguments: ["scriptId": id],
            world: .page
        )
    }

    func syncLiveGlobalState(isEnabled: Bool) async {
        guard webView != nil else { return }
        if !isEnabled {
            _ = try? await evalAsync(
                script: """
                window.__wukongScriptsGlobalEnabled = false;
                if (typeof window.__wukongRemoveAllUserScriptCSS === "function") {
                  window.__wukongRemoveAllUserScriptCSS();
                }
                return true;
                """,
                arguments: [:],
                world: AgentBridge.isolatedWorld
            )
            _ = try? await evalAsync(
                script: "window.__wukongScriptsGlobalEnabled = false; return true;",
                arguments: [:],
                world: .page
            )
        } else {
            installReplyRouterIfNeeded()
        await ensureBootstrapsInstalledOnCurrentPage()
            _ = try? await evalAsync(
                script: "window.__wukongScriptsGlobalEnabled = true; return true;",
                arguments: [:],
                world: AgentBridge.isolatedWorld
            )
            _ = try? await evalAsync(
                script: "window.__wukongScriptsGlobalEnabled = true; return true;",
                arguments: [:],
                world: .page
            )
            if let currentURL = await currentLoadedURL() {
                for script in store.scripts where script.isEnabled && script.matches(url: currentURL) && script.hasCSS {
                    _ = await applyLiveScript(script, runJS: false)
                }
            }
        }
    }

    // MARK: Private Helpers

    private func addManagedUserScript(_ script: WKUserScript, to controller: WKUserContentController) {
        managedUserScripts[ObjectIdentifier(script)] = script
        controller.addUserScript(script)
    }

    private func removeAllManagedUserScripts() {
        guard !managedUserScripts.isEmpty else { return }
        guard let webView else {
            managedUserScripts.removeAll()
            return
        }
        let controller = webView.configuration.userContentController
        let preserved = controller.userScripts.filter { managedUserScripts[ObjectIdentifier($0)] == nil }
        controller.removeAllUserScripts()
        managedUserScripts.removeAll()
        for existing in preserved {
            controller.addUserScript(existing)
        }
    }

    private func handleReportedScriptError(_ payload: [String: Any]) {
        guard let scriptID = payload["scriptId"] as? String, !scriptID.isEmpty else { return }
        let message = (payload["message"] as? String) ?? "Unknown userscript error"
        let line: Int? = {
            if let intLine = payload["line"] as? Int, intLine > 0 { return intLine }
            if let numLine = payload["line"] as? NSNumber, numLine.intValue > 0 { return numLine.intValue }
            return nil
        }()
        let url = (payload["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        store.recordError(scriptID: scriptID, message: message, line: line, url: url)
    }

    private func currentLoadedURL() async -> URL? {
        if let direct = webView?.url, !direct.absoluteString.isEmpty {
            return direct
        }
        guard let agentBridge else { return nil }
        let meta = await agentBridge.currentPageMetadata()
        guard !meta.url.isEmpty else { return nil }
        return URL(string: meta.url)
    }

    private func ensureBootstrapsInstalledOnCurrentPage() async {
        _ = try? await evalAsync(
            script: Self.isolatedBootstrapSource(relayToken: relayToken) + "\nreturn true;",
            arguments: [:],
            world: AgentBridge.isolatedWorld
        )
        _ = try? await evalAsync(
            script: Self.pageBootstrapSource(relayToken: relayToken) + "\nreturn true;",
            arguments: [:],
            world: .page
        )
    }

    private func evalAsync(
        script: String,
        arguments: [String: Any],
        world: WKContentWorld
    ) async throws -> Any? {
        guard let webView else { return nil }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                in: world
            ) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Injected JavaScript Templates

    private static func compiledRulesArray(for script: UserScript) -> [[String: Any]] {
        script.matchRules.compactMap { try? MatchPattern.parse($0).toJSDescriptor() }
    }

    private static func compiledRulesJSONLiteral(for script: UserScript) -> String {
        let descriptors = compiledRulesArray(for: script)
        guard let data = try? JSONSerialization.data(withJSONObject: descriptors, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Shared JS helper code defining `window.__wukongMatchesRules` and the SPA
    /// `history.pushState` / `history.replaceState` / `popstate` / `hashchange` hook.
    private static let sharedMatcherAndSpaHookJS = #"""
    if (typeof window.__wukongScriptsGlobalEnabled === "undefined") {
      window.__wukongScriptsGlobalEnabled = true;
    }
    if (!window.__wukongDisabledScriptIDs) {
      window.__wukongDisabledScriptIDs = {};
    }
    if (!window.__wukongLiveJSRouteHandlers) {
      window.__wukongLiveJSRouteHandlers = new Map();
    }
    if (typeof window.__wukongMatchesRules !== "function") {
      window.__wukongMatchesRules = function(rules, rawHref) {
        if (!Array.isArray(rules) || rules.length === 0 || !rawHref) return false;
        let parsed;
        try {
          parsed = new URL(String(rawHref));
        } catch (_) {
          return false;
        }
        const scheme = String(parsed.protocol || "").replace(/:$/, "").toLowerCase();
        const host = String(parsed.hostname || "").toLowerCase();
        const rawPort = String(parsed.port || "");
        const effectivePort = rawPort
          ? parseInt(rawPort, 10)
          : (scheme === "http" || scheme === "ws" ? 80 : (scheme === "https" || scheme === "wss" ? 443 : 0));
        const pathname = parsed.pathname || "/";
        const pathAndQuery = pathname + (parsed.search || "");

        for (let i = 0; i < rules.length; i++) {
          const rule = rules[i];
          if (!rule) continue;
          if (!Array.isArray(rule.schemes) || rule.schemes.indexOf(scheme) === -1) {
            continue;
          }
          if (!rule.allUrls) {
            if (rule.hostMode === "any") {
              if (scheme !== "file" && !host) continue;
            } else if (rule.hostMode === "fileAny") {
              // Matches any file host
            } else if (rule.hostMode === "exact") {
              if (host !== rule.hostValue) continue;
            } else if (rule.hostMode === "subdomain") {
              if (host !== rule.hostValue && !host.endsWith("." + rule.hostValue)) continue;
            }
            if (rule.portMode === "exact") {
              if (effectivePort !== rule.portValue) continue;
            }
          }
          try {
            const re = rule._compiledRegex || (rule._compiledRegex = new RegExp(rule.pathRegex));
            if (re.test(pathAndQuery)) {
              return true;
            }
          } catch (_) {}
        }
        return false;
      };
    }
    if (!window.__wukongSpaHookInstalled) {
      window.__wukongSpaHookInstalled = true;
      let lastHref = String(window.location.href || "");
      let routeTimer = 0;
      const dispatchIfChanged = () => {
        const nowHref = String(window.location.href || "");
        if (nowHref !== lastHref) {
          lastHref = nowHref;
          document.dispatchEvent(new Event("__wukong_spa_route"));
        }
      };
      const scheduleEmitIfChanged = () => {
        const nowHref = String(window.location.href || "");
        if (nowHref !== lastHref && window.__wukongLiveCSSRouteHandlers) {
          for (const handler of window.__wukongLiveCSSRouteHandlers.values()) {
            try { handler(); } catch (_) {}
          }
        }
        window.clearTimeout(routeTimer);
        routeTimer = window.setTimeout(dispatchIfChanged, 0);
      };
      const wrapHistory = (method) => {
        const orig = history[method];
        if (typeof orig !== "function") return;
        history[method] = function(...args) {
          const res = orig.apply(this, args);
          scheduleEmitIfChanged();
          return res;
        };
      };
      wrapHistory("pushState");
      wrapHistory("replaceState");
      window.addEventListener("popstate", scheduleEmitIfChanged);
      window.addEventListener("hashchange", scheduleEmitIfChanged);
      document.addEventListener("__wukong_spa_route", () => {
        lastHref = String(window.location.href || "");
        if (window.__wukongLiveCSSRouteHandlers) {
          for (const handler of window.__wukongLiveCSSRouteHandlers.values()) {
            try { handler(); } catch (_) {}
          }
        }
        if (window.__wukongLiveJSRouteHandlers) {
          for (const handler of window.__wukongLiveJSRouteHandlers.values()) {
            try { handler(); } catch (_) {}
          }
        }
      });
    }
    """#

    private static func isolatedBootstrapSource(relayToken: String) -> String {
        let tokenJSON = UserScript.encodeSingleLineJSONString(relayToken)
        return """
        (() => {
          \(sharedMatcherAndSpaHookJS)
          if (window.__wukongIsolatedBootstrapInstalled) return;
          window.__wukongIsolatedBootstrapInstalled = true;
          const RELAY_TOKEN = \(tokenJSON);

          if (!window.__wukongUserScriptSheets) {
            window.__wukongUserScriptSheets = new Map();
          }
          if (!window.__wukongLiveCSSRouteHandlers) {
            window.__wukongLiveCSSRouteHandlers = new Map();
          }

          const collectStyleTargets = () => {
            const targets = [document];
            const root = document.documentElement;
            if (!root) return targets;
            const walk = (node) => {
              const children = node.children;
              if (!children) return;
              for (let i = 0; i < children.length; i++) {
                const el = children[i];
                if (el.shadowRoot) {
                  targets.push(el.shadowRoot);
                  walk(el.shadowRoot);
                }
                walk(el);
              }
            };
            walk(root);
            return targets;
          };

          window.__wukongSetUserScriptCSS = function(scriptId, cssText) {
            let entry = window.__wukongUserScriptSheets.get(scriptId);
            if (!entry) {
              entry = { sheet: new CSSStyleSheet(), cssText: "" };
              window.__wukongUserScriptSheets.set(scriptId, entry);
            }
            if (entry.cssText !== cssText) {
              entry.sheet.replaceSync(cssText);
              entry.cssText = cssText;
            }
            const targets = collectStyleTargets();
            for (let i = 0; i < targets.length; i++) {
              const target = targets[i];
              const adopted = Array.from(target.adoptedStyleSheets || []);
              if (adopted.indexOf(entry.sheet) === -1) {
                target.adoptedStyleSheets = [...adopted, entry.sheet];
              }
            }
          };

          window.__wukongRemoveUserScriptCSS = function(scriptId) {
            const entry = window.__wukongUserScriptSheets.get(scriptId);
            if (!entry) return false;
            window.__wukongUserScriptSheets.delete(scriptId);
            try { entry.sheet.replaceSync(""); } catch (_) {}
            const targets = collectStyleTargets();
            for (let i = 0; i < targets.length; i++) {
              const target = targets[i];
              const adopted = Array.from(target.adoptedStyleSheets || []);
              const filtered = adopted.filter((s) => s !== entry.sheet);
              if (filtered.length !== adopted.length) {
                target.adoptedStyleSheets = filtered;
              }
            }
            return true;
          };

          window.__wukongRemoveAllUserScriptCSS = function() {
            const entries = Array.from(window.__wukongUserScriptSheets.values());
            window.__wukongUserScriptSheets.clear();
            for (let i = 0; i < entries.length; i++) {
              try { entries[i].sheet.replaceSync(""); } catch (_) {}
            }
            const sheetSet = new Set(entries.map((e) => e.sheet));
            const targets = collectStyleTargets();
            for (let i = 0; i < targets.length; i++) {
              const target = targets[i];
              const adopted = Array.from(target.adoptedStyleSheets || []);
              const filtered = adopted.filter((s) => !sheetSet.has(s));
              if (filtered.length !== adopted.length) {
                target.adoptedStyleSheets = filtered;
              }
            }
          };

          window.__wukongReportScriptError = function(payload) {
            try {
              const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wukongAgent;
              if (handler && typeof handler.postMessage === "function") {
                const p = handler.postMessage({
                  action: "scriptError",
                  scriptId: String(payload.scriptId || ""),
                  message: String(payload.message || "Unknown userscript error"),
                  line: typeof payload.line === "number" ? payload.line : 0,
                  url: String(payload.url || window.location.href || "")
                });
                if (p && typeof p.catch === "function") {
                  p.catch(() => {});
                }
              }
            } catch (_) {}
          };

          document.addEventListener("__wukong_script_error", () => {
            const root = document.documentElement || document;
            if (!root.querySelectorAll) return;
            const nodes = root.querySelectorAll("template[data-wukong-script-error]");
            for (let i = 0; i < nodes.length; i++) {
              const node = nodes[i];
              const raw = node.getAttribute("data-wukong-script-error");
              node.remove();
              if (!raw) continue;
              try {
                const parsed = JSON.parse(raw);
                if (parsed && parsed.token === RELAY_TOKEN) {
                  window.__wukongReportScriptError(parsed);
                }
              } catch (_) {}
            }
          });
        })();
        """
    }

    private static func pageBootstrapSource(relayToken: String) -> String {
        _ = relayToken
        return """
        (() => {
          \(sharedMatcherAndSpaHookJS)
        })();
        """
    }

    private static func buildCSSUserScriptSource(for script: UserScript) -> String {
        let idJSON = UserScript.encodeSingleLineJSONString(script.id)
        let cssJSON = UserScript.encodeSingleLineJSONString(script.css)
        let rulesJSON = compiledRulesJSONLiteral(for: script)

        return """
        (() => {
          const SCRIPT_ID = \(idJSON);
          const CSS_TEXT = \(cssJSON);
          const RULES = \(rulesJSON);

          const applyOrRemove = () => {
            if (!window.__wukongScriptsGlobalEnabled) return;
            if (window.__wukongDisabledScriptIDs && window.__wukongDisabledScriptIDs[SCRIPT_ID]) return;
            const href = String(window.location.href || "");
            if (window.__wukongMatchesRules(RULES, href)) {
              window.__wukongSetUserScriptCSS(SCRIPT_ID, CSS_TEXT);
            } else {
              window.__wukongRemoveUserScriptCSS(SCRIPT_ID);
            }
          };

          applyOrRemove();
          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", applyOrRemove, { once: true });
          }
          if (window.__wukongLiveCSSRouteHandlers) {
            window.__wukongLiveCSSRouteHandlers.set(SCRIPT_ID, applyOrRemove);
          }
        })();
        """
    }

    private static func errorReporterSnippet(
        for environment: AgentExecutionEnvironment,
        scriptIDJSON: String,
        relayTokenJSON: String
    ) -> String {
        switch environment {
        case .isolated:
            return """
            const reportError = (err) => {
              const msg = err && (err.stack || err.message) ? String(err.message || err.stack) : String(err);
              const line = err && typeof err.line === "number" ? err.line : 0;
              if (typeof window.__wukongReportScriptError === "function") {
                window.__wukongReportScriptError({
                  scriptId: \(scriptIDJSON),
                  message: msg,
                  line: line,
                  url: String(window.location.href || "")
                });
              }
              return msg;
            };
            """
        case .page:
            return """
            const reportError = (err) => {
              const msg = err && (err.stack || err.message) ? String(err.message || err.stack) : String(err);
              const line = err && typeof err.line === "number" ? err.line : 0;
              const sendViaDOM = (host) => {
                const tpl = document.createElement("template");
                tpl.setAttribute("data-wukong-script-error", JSON.stringify({
                  token: \(relayTokenJSON),
                  scriptId: \(scriptIDJSON),
                  message: msg,
                  line: line,
                  url: String(window.location.href || "")
                }));
                try {
                  host.appendChild(tpl);
                  document.dispatchEvent(new Event("__wukong_script_error"));
                } finally {
                  tpl.remove();
                }
              };
              const immediateHost = document.documentElement || document.body;
              if (immediateHost) {
                sendViaDOM(immediateHost);
              } else {
                const onReady = () => {
                  const deferredHost = document.documentElement || document.body;
                  if (deferredHost) {
                    document.removeEventListener("readystatechange", onReady);
                    sendViaDOM(deferredHost);
                  }
                };
                document.addEventListener("readystatechange", onReady);
              }
              return msg;
            };
            """
        }
    }

    private static func userMainDeclarationSnippet(for script: UserScript) -> String {
        switch script.environment {
        case .isolated:
            let codeJSON = UserScript.encodeSingleLineJSONString(script.js)
            return """
            const USER_CODE = \(codeJSON);
            const AsyncFn = Object.getPrototypeOf(async function(){}).constructor;
            const __wukongUserMain = () => {
              const fn = new AsyncFn(USER_CODE);
              return fn();
            };
            """
        case .page:
            return """
            async function __wukongUserMain() {
            \(script.js)
            }
            """
        }
    }

    private static func buildJSUserScriptSource(for script: UserScript, relayToken: String) -> String {
        let idJSON = UserScript.encodeSingleLineJSONString(script.id)
        let tokenJSON = UserScript.encodeSingleLineJSONString(relayToken)
        let rulesJSON = compiledRulesJSONLiteral(for: script)
        let reporter = errorReporterSnippet(
            for: script.environment,
            scriptIDJSON: idJSON,
            relayTokenJSON: tokenJSON
        )
        let mainDecl = userMainDeclarationSnippet(for: script)

        return """
        (() => {
          const SCRIPT_ID = \(idJSON);
          const RULES = \(rulesJSON);
          \(reporter)
          \(mainDecl)

          let lastExecutedHref = null;
          const runIfMatching = () => {
            if (!window.__wukongScriptsGlobalEnabled) return;
            if (window.__wukongDisabledScriptIDs && window.__wukongDisabledScriptIDs[SCRIPT_ID]) return;
            const href = String(window.location.href || "");
            if (!window.__wukongMatchesRules(RULES, href)) {
              lastExecutedHref = null;
              return;
            }
            if (href === lastExecutedHref) return;
            lastExecutedHref = href;
            try {
              const promise = __wukongUserMain();
              if (promise && typeof promise.catch === "function") {
                promise.catch((err) => { reportError(err); });
              }
            } catch (err) {
              reportError(err);
            }
          };

          runIfMatching();
          if (window.__wukongLiveJSRouteHandlers) {
            window.__wukongLiveJSRouteHandlers.set(SCRIPT_ID, runIfMatching);
          }
        })();
        """
    }

    private static func buildLiveJSInstallAndRunSource(
        for script: UserScript,
        relayToken: String,
        executeImmediately: Bool
    ) -> String {
        let idJSON = UserScript.encodeSingleLineJSONString(script.id)
        let tokenJSON = UserScript.encodeSingleLineJSONString(relayToken)
        let rulesJSON = compiledRulesJSONLiteral(for: script)
        let reporter = errorReporterSnippet(
            for: script.environment,
            scriptIDJSON: idJSON,
            relayTokenJSON: tokenJSON
        )
        let mainDecl = userMainDeclarationSnippet(for: script)
        let runFlag = executeImmediately ? "true" : "false"

        return """
        const SCRIPT_ID = \(idJSON);
        const RULES = \(rulesJSON);
        if (window.__wukongDisabledScriptIDs) {
          delete window.__wukongDisabledScriptIDs[SCRIPT_ID];
        }
        \(reporter)
        \(mainDecl)

        let lastExecutedHref = String(window.location.href || "");
        const runOnSpaRoute = () => {
          if (!window.__wukongScriptsGlobalEnabled) return;
          if (window.__wukongDisabledScriptIDs && window.__wukongDisabledScriptIDs[SCRIPT_ID]) return;
          const href = String(window.location.href || "");
          if (!window.__wukongMatchesRules(RULES, href)) {
            lastExecutedHref = null;
            return;
          }
          if (href === lastExecutedHref) return;
          lastExecutedHref = href;
          try {
            const promise = __wukongUserMain();
            if (promise && typeof promise.catch === "function") {
              promise.catch((err) => { reportError(err); });
            }
          } catch (err) {
            reportError(err);
          }
        };

        if (window.__wukongLiveJSRouteHandlers) {
          window.__wukongLiveJSRouteHandlers.set(SCRIPT_ID, runOnSpaRoute);
        }

        if (\(runFlag)) {
          try {
            await __wukongUserMain();
            return { ok: true };
          } catch (err) {
            const msg = reportError(err);
            return { ok: false, error: msg };
          }
        }
        return { ok: true };
        """
    }
}
