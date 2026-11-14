import Foundation

// MARK: - Home's Sites grid and Recent list (design-unified.md §3): the decisions, no views
//
// - `SiteVisit`        a site the user visited, kept on this device only
// - `SiteVisitStore`   the visits, pinned web sites and counts (UserDefaults)
// - `HomeSite`         one tile: a forum from the directory, or any other site
// - `HomeSites`        which tiles show and in what order (pinned first, then most visited)
// - `HomeRecent`       the newest History items Home lists

/// A site the user visited. Forums keep their name, icon and pin in the forum
/// directory (the engines' data model, unchanged); this record adds the visit
/// count for them, and everything for other sites. Stored on this device, not
/// synced.
struct SiteVisit: Codable, Equatable, Identifiable {
    /// `scheme://host[:port]` of a web site; the directory's site URL for a forum.
    var siteURL: String
    var name: String
    var isForum: Bool
    var visitCount: Int
    var lastVisitedAt: Date
    /// Pinned web sites only; forums are pinned in the directory.
    var isPinned = false
    var pinOrder = 0

    var id: String { siteURL }
}

/// One tile on Home's Sites grid.
struct HomeSite: Identifiable, Equatable {
    let siteURL: String
    var name: String
    var iconURL: URL?
    /// The directory forum behind a forum tile; nil for any other site.
    var forum: Forum?
    var isPinned: Bool
    var visitCount: Int
    var lastVisitedAt: Date?

    var id: String { siteURL }
    var isForum: Bool { forum != nil }
    var host: String { ForumSite.host(of: siteURL) }
    var url: URL? { URL(string: siteURL) }
}

enum HomeSites {
    /// Tiles shown before the Add tile.
    static let limit = 11
    /// The most recent visit within this many seconds does not count again.
    static let visitDebounce: TimeInterval = 60

    /// Pinned first (forums in their order, then web sites in theirs), then by
    /// visit count, newest visit breaking ties.
    static func tiles(forums: [Forum], visits: [SiteVisit], limit: Int = limit) -> [HomeSite] {
        let visitsByURL = Dictionary(visits.map { ($0.siteURL, $0) }, uniquingKeysWith: { first, _ in first })
        let forumTiles: [HomeSite] = forums.map { forum in
            let visit = visitsByURL[forum.siteURL]
            let visited = forum.lastVisitedAt ?? visit?.lastVisitedAt
            return HomeSite(
                siteURL: forum.siteURL,
                name: forum.displayName,
                iconURL: forum.iconURL,
                forum: forum,
                isPinned: forum.isPinned,
                // A forum visited before counts were kept has been visited once at least.
                visitCount: max(visit?.visitCount ?? 0, visited == nil ? 0 : 1),
                lastVisitedAt: visited
            )
        }
        let forumURLs = Set(forums.map(\.siteURL))
        let webTiles: [HomeSite] = visits.filter { !$0.isForum && !forumURLs.contains($0.siteURL) }.map { visit in
            HomeSite(
                siteURL: visit.siteURL,
                name: visit.name,
                iconURL: nil,
                forum: nil,
                isPinned: visit.isPinned,
                visitCount: visit.visitCount,
                lastVisitedAt: visit.lastVisitedAt
            )
        }
        let pinnedForums = forumTiles.filter(\.isPinned).sorted {
            ($0.forum?.pinOrder ?? 0) < ($1.forum?.pinOrder ?? 0)
        }
        let pinnedWeb = webTiles.filter(\.isPinned).sorted {
            (visitsByURL[$0.siteURL]?.pinOrder ?? 0) < (visitsByURL[$1.siteURL]?.pinOrder ?? 0)
        }
        let others = (forumTiles + webTiles).filter { !$0.isPinned }.sorted(by: frequentFirst)
        return Array((pinnedForums + pinnedWeb + others).prefix(limit))
    }

    private static func frequentFirst(_ lhs: HomeSite, _ rhs: HomeSite) -> Bool {
        if lhs.visitCount != rhs.visitCount { return lhs.visitCount > rhs.visitCount }
        return (lhs.lastVisitedAt ?? .distantPast) > (rhs.lastVisitedAt ?? .distantPast)
    }

    /// The site a page belongs to: `scheme://host[:port]`, nil for anything
    /// that is not an http(s) page.
    static func originOf(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty
        else {
            return nil
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// "news.example.com" for `https://www.news.example.com`.
    static func displayName(forOrigin origin: String) -> String {
        var host = ForumSite.host(of: origin)
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Tiles whose name or address contains `text` (the address field's suggestions).
    static func matches(_ tiles: [HomeSite], for text: String, limit: Int = 4) -> [HomeSite] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return Array(
            tiles.filter { $0.name.lowercased().contains(needle) || $0.host.lowercased().contains(needle) }
                .prefix(limit)
        )
    }
}

/// The visits behind Home's Sites grid. Local to the device.
@MainActor
final class SiteVisitStore: ObservableObject {
    nonisolated static let defaultsKey = "wk.siteVisits"
    /// Visits kept; the least visited, oldest ones go first.
    nonisolated static let maximumSites = 200

    @Published private(set) var visits: [SiteVisit]
    /// DEBUG `-dc-no-forums`: Home shows no visited sites (nothing is deleted).
    var hidesVisits = false {
        didSet { objectWillChange.send() }
    }
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = SiteVisitStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode([SiteVisit].self, from: data) {
            visits = decoded
        } else {
            visits = []
        }
    }

    /// The visits Home lists.
    var shownVisits: [SiteVisit] { hidesVisits ? [] : visits }

    func visit(for siteURL: String) -> SiteVisit? {
        visits.first { $0.siteURL == siteURL }
    }

    /// Counts a visit to `siteURL`; a second visit within a minute does not count.
    func noteVisit(siteURL: String, name: String, isForum: Bool, at now: Date = Date()) {
        if let index = visits.firstIndex(where: { $0.siteURL == siteURL }) {
            guard now.timeIntervalSince(visits[index].lastVisitedAt) > HomeSites.visitDebounce else { return }
            visits[index].visitCount += 1
            visits[index].lastVisitedAt = now
            if !name.isEmpty, !isForum { visits[index].name = name }
        } else {
            visits.append(SiteVisit(siteURL: siteURL, name: name, isForum: isForum, visitCount: 1, lastVisitedAt: now))
            prune()
        }
        save()
    }

    /// Pins (or unpins) a web site. A pinned site goes last among the pinned ones.
    func setPinned(_ pinned: Bool, siteURL: String) {
        guard let index = visits.firstIndex(where: { $0.siteURL == siteURL }), visits[index].isPinned != pinned else { return }
        visits[index].pinOrder = pinned ? (visits.filter(\.isPinned).map(\.pinOrder).max() ?? -1) + 1 : 0
        visits[index].isPinned = pinned
        save()
    }

    /// Forgets a site (a web site is back on Home after its next visit).
    func remove(siteURL: String) {
        guard visits.contains(where: { $0.siteURL == siteURL }) else { return }
        visits.removeAll { $0.siteURL == siteURL }
        save()
    }

    private func prune() {
        guard visits.count > Self.maximumSites else { return }
        let keep = visits.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            return $0.lastVisitedAt > $1.lastVisitedAt
        }
        visits = Array(keep.prefix(Self.maximumSites))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(visits) { defaults.set(data, forKey: key) }
    }
}

// MARK: - Recent

/// One row of Home's Recent: an item of History (design-unified.md §3). Its
/// text is the first words of what was asked or summarized.
struct HomeRecentItem: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A saved Agent answer, from a forum or an ordinary page.
        case agent
        /// An "Ask the forum" run.
        case ask
        case summary
    }

    enum Target: Equatable {
        case topic(String)
        case askRun(UUID)
    }

    var id: String
    var kind: Kind
    var title: String
    var host: String
    var date: Date
    var target: Target

    /// Gold marks the Agent: its conversations and the forum search it runs.
    var isAgent: Bool { kind == .agent || kind == .ask }
}

enum HomeRecent {
    static let limit = 3
    static let titleLength = 80

    /// The newest `limit` History items: saved summaries and the
    /// saved answers (Research and Agent).
    static func items(
        sessions: [TopicSession],
        runs: [AgentRun],
        limit: Int = limit
    ) -> [HomeRecentItem] {
        var items: [HomeRecentItem] = []
        for session in sessions where session.hasSummary {
            items.append(HomeRecentItem(
                id: "session-\(session.topicKey)",
                kind: .summary,
                title: firstWords(session.title),
                host: ForumSite.host(of: session.siteURL),
                date: session.updatedAt,
                target: .topic(session.topicKey)
            ))
        }
        for run in runs {
            items.append(HomeRecentItem(
                id: "run-\(run.id.uuidString)",
                kind: run.loop == .agent ? .agent : .ask,
                title: firstWords(run.goal),
                host: ForumSite.host(of: run.siteURL),
                date: run.createdAt,
                target: .askRun(run.id)
            ))
        }
        return Array(items.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// The text cut at a word near `titleLength`, on one line.
    static func firstWords(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > titleLength else { return trimmed }
        let cut = trimmed.prefix(titleLength)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > titleLength / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}
