import Foundation

// MARK: - Home and the launch rule (spec §7.1, §7.2): the decisions, no views
//
// - `HomeSections`         Continue reading, Following
// - `LaunchDestination`    Settings › Browser › When WukongMind opens
// - `LaunchRule`           where a launch lands (Home or the last forum)

// MARK: - Sections

enum HomeSections {
    /// Continue reading: the last topics the user opened, newest first.
    static let continueReadingLimit = 3

    static func continueReading(_ sessions: [TopicSession], limit: Int = continueReadingLimit) -> [TopicSession] {
        Array(
            sessions
                .filter { $0.openedByUserAt != nil }
                .sorted { $0.lastSeenAt > $1.lastSeenAt }
                .prefix(limit)
        )
    }

    /// "12 newer replies": posts since the summary was made (or since the
    /// topic was first read).
    static func newerReplies(_ session: TopicSession) -> Int {
        guard let total = session.totalPosts, let summarized = session.summaryPostCount else { return 0 }
        return max(0, total - summarized)
    }

    /// Followed topics with new replies, most first.
    static func watching(_ watched: [WatchedTopic]) -> [WatchedTopic] {
        watched.filter { $0.newReplies > 0 }.sorted { $0.newReplies > $1.newReplies }
    }
}

// MARK: - Launch rule

/// Settings › Browser › When WukongMind opens. Synced like the other settings.
enum LaunchDestination: String, Codable, CaseIterable, Identifiable {
    /// Home on the day's first launch; otherwise the last forum.
    case automatic
    case home
    case lastForum

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: String(localized: "Automatic", comment: "When WukongMind opens: Home on the first launch of the day, else the last site")
        case .home: String(localized: "Home", comment: "When WukongMind opens: always on Home")
        case .lastForum: String(localized: "Last site", comment: "When WukongMind opens: always on the site read last")
        }
    }
}

/// The launch rule's progress in this process: it runs once, on the first
/// activation, unless an outside request came first.
enum LaunchPhase: Equatable {
    case waiting
    /// A link, notification, Siri, Spotlight or the share extension opened
    /// something before the rule ran.
    case openedExternally
    /// The rule ran (or was skipped); later requests just navigate.
    case settled
}

/// Where a launch lands.
enum LaunchDecision: Equatable {
    /// A link, notification, Siri, Spotlight or the share extension opened
    /// the app: that request decides.
    case external
    /// Home; `marksDay` records today as the day Home was shown by itself.
    case home(marksDay: Bool)
    /// The last forum (`AppModel.startForum(in:)`), as before Home existed.
    case lastForum
}

enum LaunchRule {
    /// The local day (`dayKey`) `.automatic` last showed Home; local
    /// to the device (UserDefaults), never synced.
    static let lastHomeAutoShownDayKey = "dc.lastHomeAutoShownDay"

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func decide(
        setting: LaunchDestination,
        openedExternally: Bool,
        lastHomeAutoShownDay: String?,
        now: Date,
        calendar: Calendar = .current
    ) -> LaunchDecision {
        if openedExternally { return .external }
        switch setting {
        case .home:
            return .home(marksDay: false)
        case .lastForum:
            return .lastForum
        case .automatic:
            let today = dayKey(for: now, calendar: calendar)
            guard lastHomeAutoShownDay != today else { return .lastForum }
            return .home(marksDay: true)
        }
    }
}
