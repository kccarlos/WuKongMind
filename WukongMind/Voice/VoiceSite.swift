import Foundation

/// The words of a site in the voice agent's forum screen note (model-facing
/// English, not localized). `SiteAdapter.voice`.
struct VoiceSiteProfile: Sendable, Equatable {
    /// The `search_forum` rule on search words (the whole sentence).
    var findHint: String
    /// The language rule's sentence on searching in the forum's language.
    var languageHint: String

    /// A site-neutral profile, for tool declarations and sessions without a concrete site.
    static let neutral = VoiceSiteProfile(
        findHint: "Search matches words, so search a forum in its own language even when the user speaks another language.",
        languageHint: "Search matches words, so a question in another language is searched with words in the forum's language."
    )
}

/// What a site tells the voice session: its platform name, its search and
/// language hints for the forum screen note, and the focus modes its pages
/// support. Tool declarations use the full neutral set; a site without a mode
/// answers `.unavailable` from its own data.
struct VoiceSite: Sendable, Equatable {
    static let allFocusModes = ["user", "op", "top", "posts", "clear"]
    /// Modes a site without `topicFilters` cannot narrow a topic to.
    static let authorFocusModes: Set<String> = ["user", "op"]

    /// The platform's proper noun ("Discourse", "Hacker News"); empty for the fallback.
    var platformName: String
    var profile: VoiceSiteProfile
    /// `focus.mode` options this site supports, in declaration order.
    var focusModes: [String]

    init(platformName: String = "", profile: VoiceSiteProfile, topicFilters: Bool) {
        self.platformName = platformName
        self.profile = profile
        focusModes = Self.allFocusModes.filter { topicFilters || !Self.authorFocusModes.contains($0) }
    }

    init(adapter: any SiteAdapter) {
        self.init(
            platformName: adapter.recognizer.platformName,
            profile: adapter.voice,
            topicFilters: adapter.capabilities.topicFilters != nil
        )
    }

    var offersAuthorFocus: Bool { focusModes.contains("user") }
}

extension SiteRegistry {
    /// The voice setup of a session that starts on a site of `kind`; the
    /// fallback when the kind is unknown or has no adapter (a session can start
    /// from Home with no forum).
    func voiceSite(for kind: SiteKind?) -> VoiceSite {
        kind.flatMap(adapter(for:)).map(VoiceSite.init(adapter:)) ?? voiceFallback
    }

    /// A session that starts where no site is known speaks as the neutral
    /// persona, with the union of all adapters' options.
    var voiceFallback: VoiceSite {
        VoiceSite(profile: .neutral, topicFilters: adapters.contains { $0.capabilities.topicFilters != nil })
    }
}
