import Foundation

/// The three forum-tool slots that can be backed by a learned reader script.
enum SiteToolSlot: String, CaseIterable, Codable, CodingKeyRepresentable, Hashable, Sendable {
    case readTopic = "read_topic", listLatest = "list_latest", searchForum = "search_forum"
}

enum SiteSlotStatus: String, Codable, Equatable, Sendable {
    case untried, learned, broken, failed, notApplicable
}

enum SiteFailureCode: String, Codable, Equatable, Sendable {
    case noPosts = "no_posts", shape, threw, timeout
    case refused3 = "refused_3", repair3 = "repair_3", loadErrors3 = "load_errors_3", gaveUp = "gave_up"

    var appSentence: String {
        switch self {
        case .noPosts: "the tool returned no posts"
        case .shape: "the tool returned an invalid shape"
        case .threw: "the tool threw an error"
        case .timeout: "the tool timed out"
        case .refused3: "three attempts were refused"
        case .repair3: "three repairs failed"
        case .loadErrors3: "the script failed on three page loads"
        case .gaveUp: "the site could not be read"
        }
    }
}

struct SiteSlotFailure: Codable, Equatable, Sendable {
    var code: SiteFailureCode
    var sentence: String
    var date: Date
    var agentReason: String?
    private enum CodingKeys: String, CodingKey { case code, sentence, date, agentReason }

    init(code: SiteFailureCode, date: Date = Date(), agentReason: String? = nil) {
        self.code = code; self.sentence = code.appSentence; self.date = date; self.agentReason = agentReason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            code: try c.decode(SiteFailureCode.self, forKey: .code),
            date: try c.decode(Date.self, forKey: .date),
            agentReason: try c.decodeIfPresent(String.self, forKey: .agentReason)
        )
    }
}

struct SiteSlotCheck: Codable, Equatable, Sendable {
    var date: Date, url: String, result: String
    var counts: [Int] = [], durationMs: Double? = nil
}

struct SiteSlotState: Codable, Equatable, Sendable {
    var status: SiteSlotStatus = .untried
    var scriptID: String? = nil, scriptHash: String? = nil
    var testURLs: [String] = []
    var verifiedAt: Date? = nil
    var postStarts: [String: [String]] = [:]
    var repairFailures: Int = 0
    var failure: SiteSlotFailure? = nil, lastCheck: SiteSlotCheck? = nil
}

enum SiteLogEventKind: String, Codable, Equatable, Sendable {
    case learned, failed, broken, repaired, turnedOff = "turned_off", forgotten
}

struct SiteLogEntry: Codable, Equatable, Sendable {
    var kind: SiteLogEventKind, slot: SiteToolSlot? = nil, date: Date, taskID: String? = nil
}

/// Envelope returned by a learned reader (`design-learn-on-ask.md` "What a learned script looks like").
struct LearnedToolResult<Shape: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var shape: Shape
    var page: Int? = nil, totalPages: Int? = nil, nextPage: Int? = nil, currentPageOnly: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case shape, page, totalPages = "total_pages", nextPage = "next_page", currentPageOnly = "current_page_only"
    }
}

/// App-text-only site reading state rendered into `<page_context>`.
enum SiteReadingPromptState: Equatable, Sendable {
    case none, turnedOff
    case learned(slots: Set<SiteToolSlot>, listNotApplicable: Bool = false)
    case failed(date: Date, code: SiteFailureCode)

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!; return cal
    }()

    var pageContextLine: String {
        switch self {
        case .none:
            return "- No reading tool for this site yet."
        case .turnedOff:
            return "- The reading tool for this site is turned off in This page. Don't learn it again or turn it on; use `read_page`."
        case .failed(let date, let code):
            let p = Self.utcCalendar.dateComponents([.year, .month, .day], from: date)
            let day = String(format: "%04d-%02d-%02d", p.year ?? 1970, p.month ?? 1, p.day ?? 1)
            return "- Learning to read this site failed on \(day) (\(code.appSentence)). Don't try again unless the user asks; use `read_page`."
        case .learned(let slots, let listNotApplicable):
            let hasThread = slots.contains(.readTopic), hasList = slots.contains(.listLatest), hasSearch = slots.contains(.searchForum)
            guard hasThread || hasList || hasSearch else { return "- No reading tool for this site yet." }
            if hasThread {
                let base = "- Reading learned here: `read_topic`, `summarize_topic` and `read_aloud` take a thread URL of this site"
                if hasList && hasSearch { return base + "; `list_latest` and `search_forum` are available." }
                if hasList { return base + "; `list_latest` is available." }
                let tail = listNotApplicable ? "" : " `list_latest`: not learned yet."
                return hasSearch ? base + "; `search_forum` is available." + tail : base + "." + tail
            }
            let avail = (hasList && hasSearch) ? "`list_latest` and `search_forum` are" : (hasList ? "`list_latest` is" : "`search_forum` is")
            return "- Reading learned here: \(avail) available. `read_topic`: not learned yet."
        }
    }
}

/// Device-local learned reading state for one normalized host (`Application Support/WukongMind/SiteTools/<host>.json`).
struct SiteToolState: Codable, Equatable, Sendable {
    static let maxLogEntries = 20

    var host: String
    var slots: [SiteToolSlot: SiteSlotState] = [:]
    var threadMatch: [String] = []
    var listMatch: [String] = []
    var log: [SiteLogEntry] = []

    init(
        host: String, slots: [SiteToolSlot: SiteSlotState] = [:],
        threadMatch: [String] = [], listMatch: [String] = [], log: [SiteLogEntry] = []
    ) {
        self.host = Self.normalizedHost(host) ?? host.lowercased()
        self.slots = slots
        self.threadMatch = threadMatch
        self.listMatch = listMatch
        self.log = Array(log.prefix(Self.maxLogEntries))
    }

    func slot(_ slot: SiteToolSlot) -> SiteSlotState { slots[slot] ?? SiteSlotState() }
    mutating func setSlot(_ state: SiteSlotState, for slot: SiteToolSlot) { slots[slot] = state }

    mutating func appendLog(_ entry: SiteLogEntry) {
        log.insert(entry, at: 0)
        if log.count > Self.maxLogEntries { log.removeSubrange(Self.maxLogEntries...) }
    }

    static func normalizedHost(_ rawHost: String) -> String? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        guard !host.isEmpty, host != ".", host != "..", !host.contains(".."),
              !host.contains("/"), !host.contains("\\"), !host.contains("\0"),
              !host.contains(where: \.isWhitespace) else { return nil }
        return host
    }

    static func normalizedHost(from url: URL) -> String? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              comps.user == nil, comps.password == nil, let rawHost = comps.host else { return nil }
        return normalizedHost(rawHost)
    }

    static func sameSiteURL(_ rawURL: String, host: String) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expected = normalizedHost(host), let url = URL(string: trimmed),
              normalizedHost(from: url) == expected else { return nil }
        return url
    }

    static func canonicalThreadKey(for url: URL) -> String {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased(), let host = normalizedHost(from: url) else { return url.absoluteString }
        let portPart = comps.port.flatMap { $0 == (scheme == "https" ? 443 : 80) ? nil : ":\($0)" } ?? ""
        let path = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        return "\(scheme)://\(host)\(portPart)\(path)\(comps.percentEncodedQuery.map { "?\($0)" } ?? "")"
    }

    static func isSameDocument(_ requested: URL, openURLString: String) -> Bool {
        let trimmed = openURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openURL = URL(string: trimmed), normalizedHost(from: openURL) != nil else { return false }
        return canonicalThreadKey(for: requested) == canonicalThreadKey(for: openURL)
    }

    static func isTurnedOffByPerson(_ slotState: SiteSlotState, scriptsByID: [String: UserScript]) -> Bool {
        guard let id = slotState.scriptID, let script = scriptsByID[id] else { return false }
        return !script.isEnabled && (script.disabledReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func readingPromptState(
        state: SiteToolState?, scripts: [UserScript] = [], pageToolsEnabled: Bool = true
    ) -> SiteReadingPromptState {
        guard pageToolsEnabled, let state else { return .none }
        let scriptsByID = Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0) })
        func isDeleted(_ s: SiteSlotState) -> Bool { s.scriptID.map { scriptsByID[$0] == nil } ?? false }
        if SiteToolSlot.allCases.contains(where: { isTurnedOffByPerson(state.slot($0), scriptsByID: scriptsByID) }) {
            return .turnedOff
        }
        let failed = SiteToolSlot.allCases.map { state.slot($0) }.filter { !isDeleted($0) && $0.status == .failed }
        if let chosen = failed.max(by: { ($0.failure?.date ?? .distantPast) < ($1.failure?.date ?? .distantPast) }) {
            return .failed(date: chosen.failure?.date ?? Date(timeIntervalSince1970: 0), code: chosen.failure?.code ?? .gaveUp)
        }
        let learned = SiteToolSlot.allCases.filter { let st = state.slot($0); return !isDeleted(st) && st.status == .learned }
        if !learned.isEmpty {
            return .learned(slots: Set(learned), listNotApplicable: state.slot(.listLatest).status == .notApplicable)
        }
        return .none
    }
}

final class SiteToolStateStore: @unchecked Sendable {
    static var defaultDirectoryURL: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("WukongMind/SiteTools", isDirectory: true)
    }

    let directoryURL: URL
    private let lock = NSLock()
    private var cache: [String: SiteToolState] = [:]

    init(directoryURL: URL = SiteToolStateStore.defaultDirectoryURL) { self.directoryURL = directoryURL }

    func state(forHost rawHost: String) -> SiteToolState? {
        guard let host = SiteToolState.normalizedHost(rawHost), let url = fileURL(forNormalizedHost: host) else { return nil }
        return lock.withLock {
            if let cached = cache[host] { return cached }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? decoder.decode(SiteToolState.self, from: data) else { return nil }
            cache[host] = decoded
            return decoded
        }
    }

    func state(forURL url: URL) -> SiteToolState? { SiteToolState.normalizedHost(from: url).flatMap { state(forHost: $0) } }

    func save(_ state: SiteToolState) throws {
        guard let host = SiteToolState.normalizedHost(state.host), let url = fileURL(forNormalizedHost: host) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var normalized = state; normalized.host = host
        normalized.log = Array(normalized.log.prefix(SiteToolState.maxLogEntries))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(normalized)
        try lock.withLock {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            cache[host] = normalized
        }
    }

    @discardableResult
    func update(host rawHost: String, _ mutate: (inout SiteToolState) -> Void) throws -> SiteToolState {
        guard let host = SiteToolState.normalizedHost(rawHost) else { throw CocoaError(.fileWriteInvalidFileName) }
        var current = state(forHost: host) ?? SiteToolState(host: host)
        mutate(&current)
        try save(current)
        return current
    }

    func forget(host rawHost: String) {
        guard let host = SiteToolState.normalizedHost(rawHost), let url = fileURL(forNormalizedHost: host) else { return }
        lock.withLock { cache.removeValue(forKey: host); try? FileManager.default.removeItem(at: url) }
    }

    private func fileURL(forNormalizedHost host: String) -> URL? {
        let safeName = host.replacingOccurrences(of: ":", with: "_")
        guard !safeName.isEmpty, !safeName.hasPrefix(".") else { return nil }
        let file = directoryURL.appendingPathComponent("\(safeName).json", isDirectory: false)
        return file.deletingLastPathComponent().standardizedFileURL == directoryURL.standardizedFileURL ? file : nil
    }
}
