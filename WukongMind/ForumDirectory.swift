import Foundation
import SwiftUI

/// A forum the user added or visited. Pinned forums are ordered by
/// `pinOrder`; the rest are "recent", newest visit first.
struct Forum: Codable, Identifiable, Equatable, Hashable {
    /// Normalized site URL (origin + base path), e.g. `https://example.com/forum`.
    var siteURL: String
    /// The platform, which picks the site adapter (`AppModel.adapter(for:)`).
    /// Stored once here and synced with the record.
    var kind: SiteKind
    var name: String
    var iconURL: URL?
    var isPinned = false
    var pinOrder = 0
    var addedAt = Date()
    var lastVisitedAt: Date?

    var id: String { siteURL }
    /// `host[/basePath]` for display.
    var host: String { ForumSite.host(of: siteURL) }
    var displayName: String { ForumSite.displayName(siteURL: siteURL, name: name) }
    /// Whether this site has a built-in reader (not a plain `.web` favourite or `.unknown` placeholder).
    var hasReader: Bool { kind != .web && kind != .unknown }

    init(
        siteURL: String,
        kind: SiteKind,
        name: String,
        iconURL: URL? = nil,
        isPinned: Bool = false,
        pinOrder: Int = 0,
        addedAt: Date = Date(),
        lastVisitedAt: Date? = nil
    ) {
        self.siteURL = siteURL
        self.kind = kind
        self.name = name
        self.iconURL = iconURL
        self.isPinned = isPinned
        self.pinOrder = pinOrder
        self.addedAt = addedAt
        self.lastVisitedAt = lastVisitedAt
    }

    private enum CodingKeys: String, CodingKey {
        case siteURL, kind, name, iconURL, isPinned, pinOrder, addedAt, lastVisitedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        siteURL = try container.decode(String.self, forKey: .siteURL)
        // Synced-data exception (ENGINEERING_RULES): every forum saved or synced before kinds existed is Discourse. Remove once every device has run this build.
        kind = try container.decodeIfPresent(SiteKind.self, forKey: .kind) ?? .discourse
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        iconURL = try container.decodeIfPresent(URL.self, forKey: .iconURL)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinOrder = try container.decodeIfPresent(Int.self, forKey: .pinOrder) ?? 0
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastVisitedAt = try container.decodeIfPresent(Date.self, forKey: .lastVisitedAt)
    }
}

/// An ordinary public website offered as a starting point on first run and
/// on an empty Home screen.
struct SuggestedSite: Identifiable, Equatable {
    var name: String
    var siteURL: String
    /// One line about the site.
    var description: String

    var id: String { siteURL }
    var host: String { ForumSite.host(of: siteURL) }
    var url: URL? { URL(string: siteURL) }
}

enum ForumDirectoryError: LocalizedError, Equatable {
    case invalidAddress
    case offline

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            String(localized: "Enter a web address such as example.com.", comment: "Add site error; keep the example address as is")
        case .offline:
            String(localized: "You’re offline. Check your connection and try again.", comment: "Add site error when the device has no internet connection")
        }
    }
}

/// Add site: checking whether a typed address matches a built-in reader and its outcome.
/// `detecting` is entered once per address (a repeated tap joins it);
/// `failed` is the network's fault and may be retried; an ordinary site with no
/// reader is stored with `SiteKind.web`.
enum AddForumPhase: Equatable {
    case idle
    case detecting(address: String)
    case recognized(kind: SiteKind, siteURL: String)
    case failed(NetworkFailure)
}

/// What one Add forum detection is for; the same request joins a running one.
struct AddForumRequest: Equatable {
    var address: String
    var pin: Bool
}

/// The user's forums (pure; `AppModel` persists it in the snapshot).
struct ForumDirectory: Equatable {
    var forums: [Forum] = []

    var pinned: [Forum] {
        forums.filter(\.isPinned).sorted { $0.pinOrder < $1.pinOrder }
    }

    /// Unpinned forums, most recently visited (or added) first.
    var recent: [Forum] {
        forums.filter { !$0.isPinned }.sorted {
            ($0.lastVisitedAt ?? $0.addedAt) > ($1.lastVisitedAt ?? $1.addedAt)
        }
    }

    func forum(siteURL: String) -> Forum? {
        let normalized = ForumSite.normalizeSiteURL(siteURL) ?? siteURL
        return forums.first { $0.siteURL == normalized }
    }

    /// The directory forum a page URL belongs to (longest base path wins).
    func forum(containing url: URL) -> Forum? {
        forums
            .filter { ForumSite.isSameForum(url: url, siteURL: $0.siteURL) }
            .max { $0.siteURL.count < $1.siteURL.count }
    }

    /// Adds the forum (unpinned) or refreshes its name/icon. Returns it. A stored
    /// forum keeps its kind: a different `kind` is a bug (DEBUG assert) unless
    /// the caller validated the site just now (`overwritingKind`, Add forum).
    @discardableResult
    mutating func upsert(
        siteURL: String,
        kind: SiteKind,
        name: String?,
        iconURL: URL?,
        visitedAt: Date? = nil,
        overwritingKind: Bool = false
    ) -> Forum? {
        // `.unknown` is a display placeholder (`AppModel.forumInfo`); it is never stored or synced.
        guard kind != .unknown, let normalized = ForumSite.normalizeSiteURL(siteURL) else { return nil }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let index = forums.firstIndex(where: { $0.siteURL == normalized }) {
            if overwritingKind || forums[index].kind == .unknown || (forums[index].kind == .web && kind != .web) {
                forums[index].kind = kind
            } else if kind != .web {
                assert(forums[index].kind == kind, "\(normalized) is \(forums[index].kind), not \(kind)")
            }
            if !trimmedName.isEmpty { forums[index].name = trimmedName }
            if let iconURL { forums[index].iconURL = iconURL }
            if let visitedAt { forums[index].lastVisitedAt = visitedAt }
            return forums[index]
        }
        let forum = Forum(
            siteURL: normalized,
            kind: kind,
            name: ForumSite.displayName(siteURL: normalized, name: trimmedName),
            iconURL: iconURL,
            addedAt: visitedAt ?? Date(),
            lastVisitedAt: visitedAt
        )
        forums.append(forum)
        return forum
    }

    mutating func setPinned(_ pinned: Bool, siteURL: String) {
        guard let index = forums.firstIndex(where: { $0.siteURL == siteURL }),
              forums[index].isPinned != pinned
        else {
            return
        }
        forums[index].isPinned = pinned
        forums[index].pinOrder = pinned ? (self.pinned.map(\.pinOrder).max() ?? -1) + 1 : 0
        renumberPinned()
    }

    mutating func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = pinned
        ordered.move(fromOffsets: source, toOffset: destination)
        for (order, forum) in ordered.enumerated() {
            if let index = forums.firstIndex(where: { $0.siteURL == forum.siteURL }) {
                forums[index].pinOrder = order
            }
        }
    }

    mutating func remove(siteURL: String) {
        forums.removeAll { $0.siteURL == siteURL }
        renumberPinned()
    }

    private mutating func renumberPinned() {
        for (order, forum) in pinned.enumerated() {
            if let index = forums.firstIndex(where: { $0.siteURL == forum.siteURL }) {
                forums[index].pinOrder = order
            }
        }
    }
}
