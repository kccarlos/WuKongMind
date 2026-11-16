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

    static func fromDisabledReason(_ raw: String?) -> SiteFailureCode {
        guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return .gaveUp }
        if let code = SiteFailureCode(rawValue: key) { return code }
        if key.hasPrefix("Turned off after errors on ") { return .loadErrors3 }
        return key.lowercased().contains("repair") ? .repair3 : .gaveUp
    }

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

/// One app-text-only `<page_context>` line for learned reading state on a site without an adapter.
enum SiteReadingPromptLine: Equatable, Sendable {
    case noTool, turnedOff
    case failed(date: Date, code: SiteFailureCode)
    case learned(slots: Set<SiteToolSlot>, listUntried: Bool = true, threadUntried: Bool = true)

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!; return cal
    }()

    var text: String {
        switch self {
        case .noTool:
            return "- No reading tool for this site yet."
        case .turnedOff:
            return "- The reading tool for this site is turned off in This page. Don't learn it again or turn it on; use `read_page`."
        case .failed(let date, let code):
            let p = Self.utcCalendar.dateComponents([.year, .month, .day], from: date)
            let day = String(format: "%04d-%02d-%02d", p.year ?? 1970, p.month ?? 1, p.day ?? 1)
            return "- Learning to read this site failed on \(day) (\(code.appSentence)). Don't try again unless the user asks; use `read_page`."
        case .learned(let slots, let listUntried, let threadUntried):
            let hasThread = slots.contains(.readTopic), hasList = slots.contains(.listLatest), hasSearch = slots.contains(.searchForum)
            guard hasThread || hasList || hasSearch else { return "- No reading tool for this site yet." }
            if hasThread {
                let base = "- Reading learned here: `read_topic`, `summarize_topic` and `read_aloud` take a thread URL of this site"
                if hasList && hasSearch { return base + "; `list_latest` and `search_forum` are available." }
                if hasList { return base + "; `list_latest` is available." }
                let tail = listUntried ? " `list_latest`: not learned yet." : ""
                return hasSearch ? base + "; `search_forum` is available." + tail : base + "." + tail
            }
            let avail = (hasList && hasSearch) ? "`list_latest` and `search_forum` are" : (hasList ? "`list_latest` is" : "`search_forum` is")
            return "- Reading learned here: \(avail) available." + (threadUntried ? " `read_topic`: not learned yet." : "")
        }
    }
}

/// Ordered `<page_context>` lines (at most three: `turned off > failed > learned`, else `no tool`).
struct SiteReadingPromptState: Equatable, Sendable {
    static let none = SiteReadingPromptState(entries: [.noTool])
    static let turnedOff = SiteReadingPromptState(entries: [.turnedOff])
    static func failed(date: Date, code: SiteFailureCode) -> Self { .init(entries: [.failed(date: date, code: code)]) }
    static func learned(slots: Set<SiteToolSlot>, listUntried: Bool = true, threadUntried: Bool = true) -> Self {
        .init(entries: [.learned(slots: slots, listUntried: listUntried, threadUntried: threadUntried)])
    }

    var entries: [SiteReadingPromptLine]
    init(entries: [SiteReadingPromptLine] = [.noTool]) { self.entries = entries.isEmpty ? [.noTool] : entries }
    var lines: [String] { entries.map(\.text) }
    var pageContextLine: String { lines.joined(separator: "\n") }
}

/// Device-local learned reading state for one normalized host (`Application Support/WukongMind/SiteTools/<host>.json`).
struct SiteToolState: Codable, Equatable, Sendable {
    static let maxLogEntries = 20
    var host: String
    var slots: [SiteToolSlot: SiteSlotState] = [:]
    var threadMatch: [String] = [], listMatch: [String] = []
    var log: [SiteLogEntry] = []

    init(host: String, slots: [SiteToolSlot: SiteSlotState] = [:], threadMatch: [String] = [], listMatch: [String] = [], log: [SiteLogEntry] = []) {
        self.host = Self.normalizedHost(host) ?? host.lowercased()
        self.slots = slots; self.threadMatch = threadMatch; self.listMatch = listMatch
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
              !host.contains("/"), !host.contains("\\"), !host.contains("\0"), !host.contains(where: \.isWhitespace) else { return nil }
        return host
    }

    static func normalizedHost(from url: URL) -> String? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              comps.user == nil, comps.password == nil, let rawHost = comps.host else { return nil }
        return normalizedHost(rawHost)
    }

    static func sameSiteURL(_ rawURL: String, host: String) -> URL? {
        guard let expected = normalizedHost(host), let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
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
        guard let openURL = URL(string: openURLString.trimmingCharacters(in: .whitespacesAndNewlines)), normalizedHost(from: openURL) != nil else { return false }
        return canonicalThreadKey(for: requested) == canonicalThreadKey(for: openURL)
    }

    static func isTurnedOffByPerson(_ slotState: SiteSlotState, scriptsByID: [String: UserScript]) -> Bool {
        guard let id = slotState.scriptID, let script = scriptsByID[id] else { return false }
        return !script.isEnabled && (script.disabledReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the saved reading state says of the page at `url`, for suggestions:
    /// a thread page when `read_topic` is learned and `thread_match` matches,
    /// else a list page when `list_latest` is learned and `list_match` matches.
    /// A slot counts only while it is learned and its script exists and is on.
    /// Pure, no I/O: the patterns come from the script's own header.
    static func learnedSuggestionKind(state: SiteToolState?, url: URL, scripts: [UserScript]) -> SuggestionPageKind? {
        guard let state, normalizedHost(from: url) == state.host else { return nil }
        let scriptsByID = Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0) })
        func usable(_ slot: SiteToolSlot) -> Bool {
            let s = state.slot(slot)
            guard s.status == .learned, let id = s.scriptID, let script = scriptsByID[id] else { return false }
            return script.isEnabled
        }
        func matches(_ patterns: [String]) -> Bool {
            patterns.contains { (try? MatchPattern.parse($0))?.matches(url: url) == true }
        }
        let search = usable(.searchForum)
        if usable(.readTopic), matches(state.threadMatch) { return .learnedThread(search: search) }
        if usable(.listLatest), matches(state.listMatch) { return .learnedList(search: search) }
        return nil
    }

    private enum SlotOutcome: Equatable {
        case untried, notApplicable, learned, failed(Date, SiteFailureCode), turnedOff
    }

    static func readingPromptState(
        state: SiteToolState?, scripts: [UserScript] = [], pageToolsEnabled: Bool = true
    ) -> SiteReadingPromptState {
        guard pageToolsEnabled, let state else { return .none }
        let scriptsByID = Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0) })
        var outcomes: [SiteToolSlot: SlotOutcome] = [:]
        for slot in SiteToolSlot.allCases {
            let s = state.slot(slot)
            if let id = s.scriptID, scriptsByID[id] == nil { outcomes[slot] = .untried; continue }
            let script = s.scriptID.flatMap { scriptsByID[$0] }
            if isTurnedOffByPerson(s, scriptsByID: scriptsByID) {
                outcomes[slot] = .turnedOff
            } else if s.status == .failed || (script.map { !$0.isEnabled } ?? false) {
                let date = s.failure?.date ?? script?.updatedAt ?? Date(timeIntervalSince1970: 0)
                outcomes[slot] = .failed(date, s.failure?.code ?? SiteFailureCode.fromDisabledReason(script?.disabledReason))
            } else if s.status == .learned {
                outcomes[slot] = .learned
            } else {
                outcomes[slot] = s.status == .notApplicable ? .notApplicable : .untried
            }
        }
        var entries: [SiteReadingPromptLine] = []
        if SiteToolSlot.allCases.contains(where: { outcomes[$0] == .turnedOff }) { entries.append(.turnedOff) }
        let failures: [(Date, SiteFailureCode)] = SiteToolSlot.allCases.compactMap {
            if case .failed(let d, let c)? = outcomes[$0] { return (d, c) }; return nil
        }
        if let latest = failures.max(by: { $0.0 < $1.0 }) { entries.append(.failed(date: latest.0, code: latest.1)) }
        let learned = Set(SiteToolSlot.allCases.filter { outcomes[$0] == .learned })
        if !learned.isEmpty {
            entries.append(.learned(slots: learned, listUntried: outcomes[.listLatest] == .untried, threadUntried: outcomes[.readTopic] == .untried))
        }
        return entries.isEmpty ? .none : SiteReadingPromptState(entries: entries)
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

extension UserScript {
    /// A learned reader: an Agent-made script that provides a forum-tool slot.
    /// This page shows "Reads this site" under it.
    var readsSite: Bool {
        if case .agent = source { return !metadata.provides.isEmpty }
        return false
    }
}
