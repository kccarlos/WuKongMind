import Foundation

enum BrowserBarPosition: String, Codable, CaseIterable, Identifiable {
    /// Bottom on iPhone and in narrow windows, top in the iPad split layout.
    /// The default for new users; existing users keep their stored choice.
    case automatic
    case top
    case bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: String(localized: "Automatic", comment: "Browser address bar position: bottom on iPhone and in narrow windows, top in the iPad split layout")
        case .top: String(localized: "Top", comment: "Browser address bar position: at the top of the screen")
        case .bottom: String(localized: "Bottom", comment: "Browser address bar position: at the bottom of the screen")
        }
    }

    /// Where the bar goes in this layout: never `.automatic`.
    func resolved(isSplit: Bool) -> BrowserBarPosition {
        switch self {
        case .automatic: isSplit ? .top : .bottom
        case .top, .bottom: self
        }
    }
}

/// Character budget for one hierarchical-summary batch. Longer discussions are
/// split into batches of this size, each batch is summarized on its own, and the
/// batch summaries are combined into the final summary.
enum SummaryBatchLimit {
    static let `default` = 55_000
    static let minimum = 20_000
    static let maximum = 1_000_000
    static let step = 5_000
    static let presets = [20_000, 55_000, 100_000, 200_000, 500_000, 1_000_000]

    static func normalized(_ value: Int) -> Int {
        min(maximum, max(minimum, value))
    }

    static func label(_ value: Int) -> String {
        value >= 1_000_000
            ? String(localized: "1M characters", comment: "Summary batch size: one million characters of text")
            : String(localized: "\(value / 1_000)k characters", comment: "Summary batch size in thousands of characters, e.g. 55k characters")
    }
}

enum SearchEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case google
    case duckDuckGo = "duckduckgo"
    case bing
    case ecosia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .ecosia: "Ecosia"
        }
    }

    func searchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components: URLComponents?
        switch self {
        case .google:
            components = URLComponents(string: "https://www.google.com/search")
        case .duckDuckGo:
            components = URLComponents(string: "https://duckduckgo.com/")
        case .bing:
            components = URLComponents(string: "https://www.bing.com/search")
        case .ecosia:
            components = URLComponents(string: "https://www.ecosia.org/search")
        }
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }
}

struct AppSettings: Codable, Equatable {
    /// Summaries, chat and watched-topic refreshes.
    var assistantModel = ModelSelection(provider: .openRouter, model: AIProvider.openRouter.defaultModel)
    /// Ask the forum: planning, answers and follow-ups.
    var agentModel = ModelSelection(provider: .openRouter, model: AIProvider.openRouter.defaultModel)
    /// Browser agent model (`nil`: no preset model; user chooses a tool-calling model).
    var browserAgentModel: ModelSelection? = nil
    var browserAgentMaxSteps = BrowserAgentLimits.defaultMaxSteps
    var browserAgentTruncationLimit = BrowserAgentLimits.defaultTruncationLimit
    /// Global switch for browser userscripts (`ScriptStore.isGlobalEnabled`).
    var browserScriptsEnabled = true
    var configurations: [String: ProviderConfiguration] = Dictionary(
        uniqueKeysWithValues: AIProvider.allCases.map {
            ($0.rawValue, ProviderConfiguration(provider: $0))
        }
    )
    var favoriteModels: [FavoriteModel] = []
    var systemPrompt = ""
    var forumContextLimit = 30_000
    var summaryBatchLimit = SummaryBatchLimit.default
    var browserBarPosition: BrowserBarPosition = .automatic
    /// Web search engine in Settings › Browser. Synced.
    var searchEngine: SearchEngine = .google
    /// Where the app opens (HomeState.swift). Synced.
    var launchDestination: LaunchDestination = .automatic
    /// Optional confirmation before write actions (`Settings › Agent`). Off by default.
    var agentConfirmBeforeWrites = false
    /// Developer mode, the one switch (`Settings › Agent › Developer`): raw requests, tokens per step,
    /// tool code names and durations, and task export. Off by default; per device.
    var agentDeveloperMode = false
    var agentMaxSteps = AgentLimits.defaultMaxSteps
    var agentMaxTopicReads = AgentLimits.defaultMaxTopicReads
    var agentReadLimit = AgentLimits.defaultReadLimit
    var watchAutoRefreshSummaries = true
    /// False on a fresh install until the walkthrough finishes.
    var hasCompletedOnboarding = false
    /// Built-in browser: block ads (EasyList). Off by default, out of respect
    /// for forum owners who rely on ads.
    var contentBlockingEnabled = false
    /// Built-in browser: block trackers (EasyPrivacy). Off by default.
    var blockTrackers = false
    /// Hosts (lowercased, no "www.") where blocking is off; subdomains match.
    var adBlockAllowedSites: [String] = []
    /// API keys are stored as iCloud Keychain (synchronizable) items. On by
    /// default. Turning it off keeps a local copy and leaves the synced item
    /// in place for the user's other devices.
    var syncAPIKeys = true
    /// Whether per-forum request spacing and concurrency limits are active.
    /// On by default; turning it off sends forum requests immediately.
    var forumRateLimitingEnabled = true
    /// How quickly requests go to one forum (see ForumRequestPacing.swift).
    var forumRequestPace: ForumRequestPace = .default
    /// Daily digest (see DailyDigest.swift). Off by default: making it
    /// spends the user's AI credits. On/off and the notification are per
    /// device (each device spends and schedules on its own); what goes in
    /// and how many cards sync.
    var dailyDigestEnabled = false
    var dailyDigestNotifies = false
    var dailyDigestIncludesWatched = true
    var dailyDigestIncludesTrending = true
    var dailyDigestMaxCards = DigestLimits.defaultCards
    /// Live voice (WukongMind/Voice). Off until turned on on this device.
    var voiceEnabled = false
    var voice = VoiceSettings()
    /// The daily podcast (WukongMind/Podcast): made right after the digest
    /// finishes on open. Off by default (it spends AI and TTS credits); the
    /// switch is per device.
    var podcastDailyEnabled = false
    var podcast = PodcastSettings()
    /// The language summaries, digest cards and posts are translated into
    /// (Translation/ReadingLanguage.swift), and the podcast's script
    /// language. Empty: the app's language.
    var readingLanguage = ""
    /// Read topics and saved summaries in Spotlight (System/Spotlight.swift).
    /// On by default; each device keeps its own index.
    var spotlightEnabled = true
    /// Topics the user reads are offered to Siri suggestions
    /// (`NSUserActivity`). On by default; per device.
    var donatesTopicActivity = true
    init() {}

    private enum CodingKeys: String, CodingKey {
        case assistantModel
        case agentModel
        case browserAgentModel
        case browserAgentMaxSteps
        case browserAgentTruncationLimit
        case browserScriptsEnabled
        case configurations
        case favoriteModels
        case systemPrompt
        case forumContextLimit
        case summaryBatchLimit
        case browserBarPosition
        case searchEngine
        case launchDestination
        case agentConfirmBeforeWrites
        case agentDeveloperMode
        case agentMaxSteps
        case agentMaxTopicReads
        case agentReadLimit
        case watchAutoRefreshSummaries
        case hasCompletedOnboarding
        case contentBlockingEnabled
        case blockTrackers
        case adBlockAllowedSites
        case syncAPIKeys
        case forumRateLimitingEnabled
        case forumRequestPace
        case dailyDigestEnabled
        case dailyDigestNotifies
        case dailyDigestIncludesWatched
        case dailyDigestIncludesTrending
        case dailyDigestMaxCards
        case voiceEnabled
        case voice
        case podcastDailyEnabled
        case podcast
        case readingLanguage
        case spotlightEnabled
        case donatesTopicActivity
    }

    /// The older `developerMode` key, folded into `agentDeveloperMode`: read once, never written.
    private enum LegacyKeys: String, CodingKey {
        case developerMode
    }

    // A missing key takes its default; an unreadable value fails the decode
    // (the store then starts fresh).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent([String: ProviderConfiguration].self, forKey: .configurations)
        configurations = stored.map { stored in
            Dictionary(uniqueKeysWithValues: stored.map { key, value in
                var configuration = value
                configuration.model = AIProvider(rawValue: key)?.defaultModel ?? ""
                return (key, configuration)
            })
        } ?? Dictionary(
            uniqueKeysWithValues: AIProvider.allCases.map {
                ($0.rawValue, ProviderConfiguration(provider: $0))
            }
        )
        favoriteModels = try container.decodeIfPresent([FavoriteModel].self, forKey: .favoriteModels)
            ?? []
        let stock = AppSettings()
        assistantModel = try container.decodeIfPresent(ModelSelection.self, forKey: .assistantModel) ?? stock.assistantModel
        agentModel = try container.decodeIfPresent(ModelSelection.self, forKey: .agentModel) ?? stock.agentModel
        browserAgentModel = try container.decodeIfPresent(ModelSelection.self, forKey: .browserAgentModel)
        browserAgentMaxSteps = BrowserAgentLimits.clampSteps(
            try container.decodeIfPresent(Int.self, forKey: .browserAgentMaxSteps)
                ?? BrowserAgentLimits.defaultMaxSteps
        )
        browserAgentTruncationLimit = BrowserAgentLimits.clampTruncationLimit(
            try container.decodeIfPresent(Int.self, forKey: .browserAgentTruncationLimit)
                ?? BrowserAgentLimits.defaultTruncationLimit
        )
        browserScriptsEnabled = try container.decodeIfPresent(Bool.self, forKey: .browserScriptsEnabled) ?? true
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        forumContextLimit = try container.decodeIfPresent(Int.self, forKey: .forumContextLimit)
            ?? 30_000
        summaryBatchLimit = SummaryBatchLimit.normalized(
            try container.decodeIfPresent(Int.self, forKey: .summaryBatchLimit)
                ?? SummaryBatchLimit.default
        )
        browserBarPosition = try container.decodeIfPresent(BrowserBarPosition.self, forKey: .browserBarPosition) ?? stock.browserBarPosition
        searchEngine = try container.decodeIfPresent(SearchEngine.self, forKey: .searchEngine) ?? stock.searchEngine
        launchDestination = try container.decodeIfPresent(LaunchDestination.self, forKey: .launchDestination) ?? stock.launchDestination
        agentConfirmBeforeWrites = try container.decodeIfPresent(Bool.self, forKey: .agentConfirmBeforeWrites) ?? stock.agentConfirmBeforeWrites
        agentDeveloperMode = try container.decodeIfPresent(Bool.self, forKey: .agentDeveloperMode) ?? stock.agentDeveloperMode
        agentMaxSteps = AgentLimits.clampSteps(
            try container.decodeIfPresent(Int.self, forKey: .agentMaxSteps)
                ?? AgentLimits.defaultMaxSteps
        )
        agentMaxTopicReads = AgentLimits.clampTopicReads(
            try container.decodeIfPresent(Int.self, forKey: .agentMaxTopicReads)
                ?? AgentLimits.defaultMaxTopicReads
        )
        agentReadLimit = AgentLimits.clampReadLimit(
            try container.decodeIfPresent(Int.self, forKey: .agentReadLimit)
                ?? AgentLimits.defaultReadLimit
        )
        watchAutoRefreshSummaries = try container.decodeIfPresent(
            Bool.self,
            forKey: .watchAutoRefreshSummaries
        ) ?? true
        hasCompletedOnboarding = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasCompletedOnboarding
        ) ?? false
        contentBlockingEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .contentBlockingEnabled
        ) ?? false
        blockTrackers = try container.decodeIfPresent(Bool.self, forKey: .blockTrackers) ?? false
        adBlockAllowedSites = (try container.decodeIfPresent([String].self, forKey: .adBlockAllowedSites) ?? [])
            .compactMap(ContentBlockingRules.normalizedHost)
        syncAPIKeys = try container.decodeIfPresent(Bool.self, forKey: .syncAPIKeys) ?? true
        forumRateLimitingEnabled = try container.decodeIfPresent(Bool.self, forKey: .forumRateLimitingEnabled) ?? true
        forumRequestPace = try container.decodeIfPresent(ForumRequestPace.self, forKey: .forumRequestPace) ?? .default
        dailyDigestEnabled = try container.decodeIfPresent(Bool.self, forKey: .dailyDigestEnabled) ?? false
        dailyDigestNotifies = try container.decodeIfPresent(Bool.self, forKey: .dailyDigestNotifies) ?? false
        dailyDigestIncludesWatched = try container.decodeIfPresent(Bool.self, forKey: .dailyDigestIncludesWatched) ?? true
        dailyDigestIncludesTrending = try container.decodeIfPresent(Bool.self, forKey: .dailyDigestIncludesTrending) ?? true
        dailyDigestMaxCards = DigestLimits.clampCards(
            try container.decodeIfPresent(Int.self, forKey: .dailyDigestMaxCards) ?? DigestLimits.defaultCards
        )
        voiceEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? false
        voice = try container.decodeIfPresent(VoiceSettings.self, forKey: .voice) ?? VoiceSettings()
        podcastDailyEnabled = try container.decodeIfPresent(Bool.self, forKey: .podcastDailyEnabled) ?? false
        podcast = try container.decodeIfPresent(PodcastSettings.self, forKey: .podcast) ?? PodcastSettings()
        readingLanguage = try container.decodeIfPresent(String.self, forKey: .readingLanguage) ?? ""
        spotlightEnabled = try container.decodeIfPresent(Bool.self, forKey: .spotlightEnabled) ?? true
        donatesTopicActivity = try container.decodeIfPresent(Bool.self, forKey: .donatesTopicActivity) ?? true
        if try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Bool.self, forKey: .developerMode) == true {
            agentDeveloperMode = true
        }
    }

    func configuration(for provider: AIProvider) -> ProviderConfiguration {
        var configuration = configurations[provider.rawValue] ?? ProviderConfiguration(provider: provider)
        configuration.model = provider.defaultModel
        return configuration
    }

    mutating func setConfiguration(_ configuration: ProviderConfiguration, for provider: AIProvider) {
        var stored = configuration
        stored.model = provider.defaultModel
        configurations[provider.rawValue] = stored
    }

    var persistable: AppSettings {
        var copy = self
        for provider in AIProvider.allCases {
            var configuration = copy.configuration(for: provider)
            configuration.apiKey = ""
            copy.setConfiguration(configuration, for: provider)
        }
        return copy
    }
}

struct RawForumPage: Codable, Equatable {
    var page: Int
    var content: String
    /// The topic's post count when the page was fetched: a page that was full
    /// then never changes (`DiscoursePagePlan`).
    var topicPostCount: Int?
    /// The posts of `content`, same order. The adapter writes both in one
    /// call and nothing edits either afterwards: one fact, two representations.
    var blocks: [PostBlock] = []
    /// What the platform says about the article's version when this page was
    /// fetched (opaque; only the adapter compares it). nil for Discourse.
    var revision: String?

    /// Posts per raw page.
    static let size = 100
}

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: ChatRole
    var content: String
    var createdAt = Date()
}

struct TopicSession: Codable, Identifiable, Equatable {
    /// The topic text of the last complete read. With `rawPages` it is written
    /// only by the fetched-text methods in the extension below.
    /// The forum's site URL (origin + base path).
    var siteURL: String
    var topicID: String
    var url: URL
    var title: String
    var source = ""
    var rawPages: [RawForumPage] = []
    var summary = ""
    var history: [ChatMessage] = []
    var kept = false
    /// Per-topic instructions; when non-empty they replace the global custom
    /// instructions for this topic's summary and chat.
    var instructions = ""
    var totalPosts: Int?
    var summaryPostCount: Int?
    var provider: AIProvider?
    var model = ""
    var createdAt = Date()
    var updatedAt = Date()
    var summaryUpdatedAt: Date?
    var chatUpdatedAt: Date?
    var lastCheckedAt: Date?
    /// When the user last opened the topic in the browser; nil when only
    /// the agent (or a digest) read it. Continue reading, Spotlight and the
    /// Siri topic entities list only topics the user opened (or summaries).
    var openedByUserAt: Date?

    init(
        siteURL: String,
        topicID: String,
        url: URL,
        title: String
    ) {
        self.siteURL = siteURL
        self.topicID = topicID
        self.url = url
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case siteURL, topicID, url, title, source, rawPages, summary, history, kept, instructions
        case totalPosts, summaryPostCount, provider, model, createdAt, updatedAt
        case summaryUpdatedAt, chatUpdatedAt, lastCheckedAt, openedByUserAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        siteURL = try container.decode(String.self, forKey: .siteURL)
        topicID = try container.decode(String.self, forKey: .topicID)
        url = try container.decode(URL.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        // A device-local cache: pages saved before they carried `blocks` do
        // not decode and are dropped, and the next read fetches them again
        // while the summary and chat stay. Cache invalidation, not a migration.
        rawPages = (try? container.decode([RawForumPage].self, forKey: .rawPages)) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        history = try container.decodeIfPresent([ChatMessage].self, forKey: .history) ?? []
        kept = try container.decodeIfPresent(Bool.self, forKey: .kept) ?? false
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        totalPosts = try container.decodeIfPresent(Int.self, forKey: .totalPosts)
        summaryPostCount = try container.decodeIfPresent(Int.self, forKey: .summaryPostCount)
        provider = try container.decodeIfPresent(AIProvider.self, forKey: .provider)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        summaryUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .summaryUpdatedAt)
        chatUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .chatUpdatedAt)
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        openedByUserAt = try container.decodeIfPresent(Date.self, forKey: .openedByUserAt)
    }

    /// `host[/basePath]/t/{id}`; the key of `AppModel.sessions`.
    var topicKey: String { TopicIdentity.key(siteURL: siteURL, topicID: topicID) }
    var id: String { topicKey }
    var hasSummary: Bool { !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// When the user last opened it, else when it last changed (lists and
    /// "· 2 hours ago" lines).
    var lastSeenAt: Date { openedByUserAt ?? updatedAt }
    var hasInstructions: Bool {
        !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasStaleSummary: Bool {
        guard hasSummary,
              let summaryPostCount,
              let totalPosts
        else {
            return false
        }
        return totalPosts > summaryPostCount
    }
}

/// The only writers of `source` and `rawPages` (with the blocks inside the
/// pages). P1: derive `source` from the pages with a `completeThrough` marker.
extension TopicSession {
    /// A complete read: its text, its pages and the post count.
    mutating func apply(_ fetch: ForumFetchResult, at date: Date) {
        source = fetch.content
        rawPages = fetch.rawPages
        totalPosts = fetch.totalPosts
        lastCheckedAt = date
        #if DEBUG
        assert(source == RawTopicFormat.join(rawPages.map(\.content)), "source must equal the pages joined")
        #endif
    }

    /// One page of a read in progress. `source` stays the last complete read.
    mutating func apply(page: RawForumPage) {
        rawPages.removeAll { $0.page == page.page }
        rawPages.append(page)
        rawPages.sort { $0.page < $1.page }
    }

    /// Drops the fetched text to save space (the summary and chat stay).
    mutating func dropFetchedText() {
        rawPages = []
        source = ""
    }

    /// A synced copy keeps this device's cache: the fetched text is not synced.
    mutating func keepFetchedText(of local: TopicSession?) {
        source = local?.source ?? ""
        rawPages = local?.rawPages ?? []
    }

    /// Placeholder text with no pages (DEBUG fakes and UI-test seeds).
    mutating func seedSource(_ text: String) {
        source = text
    }
}

struct ExportOptions: Equatable {
    var excludeTitleAndURL = false
    var excludeSummary = false
    var excludePostAndResponses = false
    var excludeChatHistory = false
}

struct TopicExportPayload: Equatable {
    private static let dayFormat = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!)
        .year().month().day()

    let summary: String
    let source: String
    let title: String
    let url: URL?
    let history: [ChatMessage]
    var summaryUpdatedAt: Date? = nil
    var summaryPostCount: Int? = nil
    var totalPosts: Int? = nil

    var summaryMetadataLine: String? {
        let coverage: String?
        if let covered = summaryPostCount, covered > 0, let total = totalPosts, total > 0 {
            let totalLabel = String(localized: "\(total) posts", comment: "Exported summary metadata: post count")
            coverage = String(localized: "\(covered) of \(totalLabel)", comment: "Exported summary metadata: post coverage (summarized count of total posts)")
        } else if let count = summaryPostCount ?? totalPosts, count > 0 {
            coverage = String(localized: "\(count) posts", comment: "Exported summary metadata: post count")
        } else {
            coverage = nil
        }
        return Self.formatSummaryLine(date: summaryUpdatedAt, coverage: coverage)
    }

    private static func formatSummaryLine(date: Date?, coverage: String?) -> String? {
        if let date {
            let day = date.formatted(dayFormat)
            if let coverage {
                return String(localized: "Summarized \(day) · \(coverage)", comment: "Exported summary metadata: date summarized and post coverage")
            }
            return String(localized: "Summarized \(day)", comment: "Exported summary metadata: date summarized")
        }
        return coverage
    }

    var hasTitleAndURL: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(url?.absoluteString.isEmpty ?? true)
    }

    var hasSummary: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasSource: Bool {
        !source.isEmpty
    }

    var hasChatHistory: Bool {
        !history.isEmpty
    }

    func text(options: ExportOptions) -> String {
        var sections: [String] = []
        if !options.excludeTitleAndURL {
            if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(title)
            }
            if let url, !url.absoluteString.isEmpty {
                sections.append(String(localized: "Post URL: \(url.absoluteString)", comment: "Exported text: line with the forum post's address"))
            }
        }
        if !options.excludeSummary,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let body = summaryMetadataLine.map { "\($0)\n\(summary)" } ?? summary
            sections.append(String(localized: "Summary:\n\(body)", comment: "Exported text: heading followed by the AI summary"))
        }
        if !options.excludePostAndResponses, !source.isEmpty {
            sections.append(String(localized: "Full post:\n\(source)", comment: "Exported text: heading followed by the forum post and its replies"))
        }
        if !options.excludeChatHistory, !history.isEmpty {
            let transcript = history.map { message in
                let role = message.role == .user
                    ? String(localized: "User", comment: "Exported chat transcript: label for the user's messages")
                    : String(localized: "Assistant", comment: "Exported chat transcript: label for the AI's messages")
                return "\(role):\n\(message.content)"
            }
            let joined = transcript.joined(separator: "\n\n")
            sections.append(String(localized: "Chat history:\n\(joined)", comment: "Exported text: heading followed by the chat transcript"))
        }
        return sections.joined(separator: "\n\n")
    }

    func hasContent(options: ExportOptions) -> Bool {
        !text(options: options).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ForumPreview {
    static func compact(
        _ source: String,
        headLines: Int = 50,
        tailLines: Int = 50
    ) -> String {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let visibleLines = headLines + tailLines
        guard lines.count > visibleLines else { return source }
        let omitted = lines.count - visibleLines
        return lines.prefix(headLines).joined(separator: "\n")
            + "\n\n" + String(localized: "[… \(omitted) middle lines omitted from the preview …]", comment: "Shown in the middle of a long forum post preview") + "\n\n"
            + lines.suffix(tailLines).joined(separator: "\n")
    }
}

struct ForumTopic: Equatable, Identifiable {
    let siteURL: String
    let topicID: String
    let url: URL
    let title: String

    var topicKey: String { TopicIdentity.key(siteURL: siteURL, topicID: topicID) }
    var id: String { topicKey }

    /// Parses a topic URL under `basePath` on any host, with the platform's
    /// recognizer. URL-only: callers must know the page is on a forum of that
    /// platform (probe or forum directory). The default title uses the forum name.
    static func parse(
        url: URL?,
        title: String?,
        basePath: String = "",
        forumName: String? = nil,
        recognizer: any SiteRecognizer
    ) -> ForumTopic? {
        guard let url, let topicID = recognizer.topicID(fromURL: url, basePath: basePath) else { return nil }
        return parse(url: url, title: title, basePath: basePath, forumName: forumName, topicID: topicID)
    }

    /// The same with a topic id already known (the recognition match's, which
    /// the facts may supply where the URL carries none).
    static func parse(
        url: URL?,
        title: String?,
        basePath: String = "",
        forumName: String? = nil,
        topicID: String,
        links: (any SiteLinks)? = nil
    ) -> ForumTopic? {
        guard let url, let siteURL = ForumSite.siteURL(fromPage: url, basePath: basePath) else { return nil }
        // The platform decides what identifies its page (Discourse: the path
        // with its post number; WordPress: the permalink or its `?p=` query).
        let canonicalURL = links?.canonicalPageURL(url) ?? ForumSite.withoutQueryAndFragment(url)
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ForumSite.displayName(siteURL: siteURL, name: forumName)
        return ForumTopic(
            siteURL: siteURL,
            topicID: topicID,
            url: canonicalURL,
            title: normalizedTitle?.isEmpty == false
                ? normalizedTitle!
                : String(localized: "\(name) topic \(topicID)", comment: "Fallback title of a forum topic: forum name, then the topic's number")
        )
    }
}

/// Topic keys for records. A record whose id is not a forum topic id (agent
/// work records use `agent:{runID}`) keys on its id unchanged.
enum TopicIdentity {
    static func key(siteURL: String, topicID: String) -> String {
        ForumSite.topicKey(siteURL: siteURL, topicID: topicID) ?? topicID
    }
}

enum WorkType: String, Codable {
    case summary
    case pull
    case chat
    case agent
}

/// Budget for one agent run. Steps count every tool call; topic reads count
/// each distinct topic whose posts are pulled or summarized.
enum AgentLimits {
    static let defaultMaxSteps = 15
    static let stepRange = 3...60
    static let defaultMaxTopicReads = 8
    static let topicReadRange = 1...30
    static let defaultReadLimit = 30_000
    static let readLimitRange = 10_000...200_000

    static func clampSteps(_ value: Int) -> Int {
        min(stepRange.upperBound, max(stepRange.lowerBound, value))
    }

    static func clampTopicReads(_ value: Int) -> Int {
        min(topicReadRange.upperBound, max(topicReadRange.lowerBound, value))
    }

    static func clampReadLimit(_ value: Int) -> Int {
        min(readLimitRange.upperBound, max(readLimitRange.lowerBound, value))
    }
}

/// One tool call (or the final answer) inside an agent run.
struct AgentStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var tool: String
    var arguments: [String: String] = [:]
    var thought = ""
    /// Short human-readable outcome shown in the step log.
    var outcome = ""
    var isError = false
    var topicID: String?
    /// Key of the topic the step read (`sessions` key), when it read one.
    var topicKey: String?
    var startedAt = Date()
    var finishedAt: Date?
}

/// How an Ask the forum run was started; History tags voice runs.
enum AgentRunOrigin: String, Codable, CaseIterable {
    case typed, voice, shortcut
}

/// Which loop wrote a saved `AgentRun`. A record from before the Agent saved
/// answers has no key and reads as `.research`.
enum AgentRunLoop: String, Codable, CaseIterable {
    case research, agent
}

/// One line of a saved answer's sources list (`AgentSources.Source`, as data):
/// the snapshot an Agent record keeps, so the list still shows after the topic
/// pages are pruned.
struct SavedSource: Codable, Equatable {
    var number: Int
    var title: String
    var url: String
    var topicID: String?
    var postNumber: Int?
    var cited = true

    /// More sources than an answer cites; a synced record stays small.
    static let limit = 30

    init(number: Int, title: String, url: String, topicID: String? = nil, postNumber: Int? = nil, cited: Bool = true) {
        self.number = number
        self.title = title
        self.url = url
        self.topicID = topicID
        self.postNumber = postNumber
        self.cited = cited
    }

    init(_ source: AgentSources.Source) {
        self.init(
            number: source.number, title: source.title, url: source.url.absoluteString,
            topicID: source.topicID, postNumber: source.postNumber, cited: source.cited
        )
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, url, topicID, postNumber, cited
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try container.decode(String.self, forKey: .url)
        topicID = try container.decodeIfPresent(String.self, forKey: .topicID)
        postNumber = try container.decodeIfPresent(Int.self, forKey: .postNumber)
        cited = try container.decodeIfPresent(Bool.self, forKey: .cited) ?? true
    }

    /// The row `DCSourcesList` shows; nil for a URL that no longer parses.
    var source: AgentSources.Source? {
        URL(string: url).map {
            AgentSources.Source(number: number, title: title, url: $0, topicID: topicID, postNumber: postNumber, cited: cited)
        }
    }
}

/// A goal-driven run of the forum agent, kept so it can be reopened and
/// continued with follow-up questions.
/// The terminal outcome of an agent run.
enum AgentRunResult: String, Codable, Equatable {
    case completed
    case failed
    case cancelled

    var workStatus: WorkStatus {
        switch self {
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

struct AgentRun: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The forum every tool call of this run (and its follow-ups) targets.
    var siteURL: String
    var goal: String
    /// How the run ended; nil while it is live. Whether a live run is queued
    /// or running is its work record's (`AppModel.status(of:)`).
    var result: AgentRunResult?
    var steps: [AgentStep] = []
    /// Model/observation exchange; follow-ups append to it so the agent keeps
    /// the topics it already read as context.
    var transcript: [ChatMessage] = []
    /// The latest answer (updated by follow-ups).
    var answer = ""
    /// The answer to the original goal, kept when follow-ups replace `answer`.
    var initialAnswer = ""
    /// Follow-up questions and their answers, in order.
    var followUps: [ChatMessage] = []
    var topicIDs: [String] = []
    /// The topic ids behind the permalinks the run's tools showed, by
    /// `AgentSources.knownKey`: how a citation of a link with no id in it
    /// (a WordPress slug) finds its topic.
    var knownLinks: [String: String] = [:]
    var error = ""
    var provider: AIProvider
    var model: String
    var origin: AgentRunOrigin = .typed
    /// `.agent` for an answer the browser Agent saved at the end of a turn
    /// (`siteURL` is then the forum's, or the page's origin).
    var loop: AgentRunLoop = .research
    /// An Agent record's sources list as it stood at the end of the turn.
    var sources: [SavedSource] = []
    var createdAt = Date()
    var updatedAt = Date()
    var completedAt: Date?

    var readTopicCount: Int { topicIDs.count }

    /// More than a long run needs; a synced record stays small.
    static let knownLinkLimit = 300

    /// Notes the topic behind each link a tool showed (see `knownLinks`).
    mutating func remember(_ found: [(url: URL, topicID: String)], links: any SiteLinks) {
        for (url, topicID) in found where knownLinks.count < Self.knownLinkLimit {
            knownLinks[AgentSources.knownKey(url, links: links)] = topicID
        }
    }

    var isFinished: Bool { result != nil }

    init(id: UUID = UUID(), siteURL: String, goal: String, provider: AIProvider, model: String, origin: AgentRunOrigin = .typed) {
        self.id = id
        self.origin = origin
        self.siteURL = siteURL
        self.goal = goal
        self.provider = provider
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case id, siteURL, goal, result, steps, transcript, answer, initialAnswer, followUps
        case topicIDs, knownLinks, error, provider, model, origin, loop, sources, createdAt, updatedAt, completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        siteURL = try container.decode(String.self, forKey: .siteURL)
        goal = try container.decode(String.self, forKey: .goal)
        result = try container.decodeIfPresent(AgentRunResult.self, forKey: .result)
        steps = try container.decode([AgentStep].self, forKey: .steps)
        transcript = try container.decode([ChatMessage].self, forKey: .transcript)
        answer = try container.decode(String.self, forKey: .answer)
        initialAnswer = try container.decode(String.self, forKey: .initialAnswer)
        followUps = try container.decode([ChatMessage].self, forKey: .followUps)
        topicIDs = try container.decode([String].self, forKey: .topicIDs)
        knownLinks = try container.decodeIfPresent([String: String].self, forKey: .knownLinks) ?? [:]
        error = try container.decode(String.self, forKey: .error)
        provider = try container.decode(AIProvider.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        origin = try container.decode(AgentRunOrigin.self, forKey: .origin)
        loop = try container.decodeIfPresent(AgentRunLoop.self, forKey: .loop) ?? .research
        sources = try container.decodeIfPresent([SavedSource].self, forKey: .sources) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

/// A topic the app checks for new replies on the user's behalf.
struct WatchedTopic: Codable, Identifiable, Equatable {
    var siteURL: String
    var topicID: String
    var url: URL
    var title: String
    var knownPostCount: Int
    var newReplies = 0
    var addedAt = Date()
    var lastCheckedAt: Date?

    var topicKey: String { TopicIdentity.key(siteURL: siteURL, topicID: topicID) }
    var id: String { topicKey }

    init(siteURL: String, topicID: String, url: URL, title: String, knownPostCount: Int) {
        self.siteURL = siteURL
        self.topicID = topicID
        self.url = url
        self.title = title
        self.knownPostCount = knownPostCount
    }

    private enum CodingKeys: String, CodingKey {
        case siteURL, topicID, url, title, knownPostCount, newReplies, addedAt, lastCheckedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        siteURL = try container.decode(String.self, forKey: .siteURL)
        topicID = try container.decode(String.self, forKey: .topicID)
        url = try container.decode(URL.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        knownPostCount = try container.decode(Int.self, forKey: .knownPostCount)
        newReplies = try container.decodeIfPresent(Int.self, forKey: .newReplies) ?? 0
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }

    /// Applies a fresh post count. Returns the number of replies that arrived
    /// since the last check (0 when nothing changed).
    mutating func record(postCount: Int, at date: Date = Date()) -> Int {
        lastCheckedAt = date
        let delta = max(0, postCount - knownPostCount)
        if delta > 0 {
            newReplies += delta
            knownPostCount = postCount
        }
        return delta
    }

    mutating func markSeen() {
        newReplies = 0
    }
}

/// A topic as listed by the forum's search/latest endpoints.
struct ForumTopicListing: Codable, Equatable, Identifiable {
    var siteURL: String
    var id: Int
    var title: String
    var slug: String
    /// The topic's page, set by the adapter that parsed it.
    var url: URL
    /// nil when the platform's listing does not say.
    var postsCount: Int?
    var lastPostedAt: String?
    var excerpt: String?
    /// From topic lists (`/latest.json`, `/top.json`); nil from search.
    var isPinned: Bool?
    var likeCount: Int?
    var hasAcceptedAnswer: Bool?
    /// Opening author, when supplied by the listing.
    var author: String? = nil

    var topicID: String { String(id) }
}

/// Title and post count of a topic from `/t/{id}.json`.
struct ForumTopicOverview: Equatable {
    var siteURL: String
    var topicID: String
    var title: String
    var slug: String
    /// The topic's page, set by the adapter that parsed it.
    var url: URL
    var postCount: Int
    /// Read from the same JSON.
    var facts: TopicFacts?
}

/// One Discourse search hit: a post in a topic. `/search.json` can return
/// several posts of one topic; hits keep the forum's order.
struct ForumSearchHit: Equatable, Identifiable {
    var topic: ForumTopicListing
    /// nil when the platform does not number posts in a result (a comment hit
    /// knows its number only after the post is read).
    var postNumber: Int?
    var username: String?
    var blurb: String?
    /// When the post was written, as the platform reports it; nil from Discourse.
    var postedAt: String?
    /// The topic opened at this post, set by the adapter that parsed it.
    var url: URL

    var id: String { postNumber.map { "\(topic.id)/\($0)" } ?? url.absoluteString }
}

/// A post fetched by id (`/t/{id}/posts.json`), its cooked HTML as plain text.
struct ForumPost: Equatable, Identifiable {
    var id: Int
    var number: Int
    var username: String
    var text: String
    var likeCount: Int?
}

/// Who asked for a job. Work the app starts by itself (a watched topic's
/// summary refresh) never interrupts with an alert: a failure stays on its
/// record in Activity.
enum WorkOrigin: String, Codable {
    case user
    case automatic
}

enum WorkStatus: String, Codable {
    case queued
    case running
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

struct WorkRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: WorkType
    /// The forum the work runs against.
    var siteURL: String
    /// Forum topic id, or `agent:{runID}` for agent work.
    var topicID: String
    var title: String
    var url: URL
    var question = ""
    var provider: AIProvider
    var model: String
    var status: WorkStatus = .queued
    var origin: WorkOrigin = .user
    var statusText = WorkRecord.waitingStatusText
    var error = ""
    /// Per-run override of the hierarchical-summary batch size; nil uses the
    /// setting current when the task runs (survives task restoration).
    var batchLimit: Int?
    /// Summary Retry: written again even when no reply is new. Not saved (a
    /// restored task summarizes normally).
    var regenerate: Bool?
    var createdAt = Date()
    var updatedAt = Date()
    var startedAt: Date?
    var completedAt: Date?

    static var waitingStatusText: String {
        String(localized: "Waiting for an available worker…", comment: "Status of queued AI work (summary, chat or research) before it starts")
    }

    /// `host[/basePath]/t/{id}`, or `agent:{runID}` for agent work.
    var topicKey: String { TopicIdentity.key(siteURL: siteURL, topicID: topicID) }

    init(
        id: UUID = UUID(),
        type: WorkType,
        siteURL: String,
        topicID: String,
        title: String,
        url: URL,
        question: String = "",
        provider: AIProvider,
        model: String
    ) {
        self.id = id
        self.type = type
        self.siteURL = siteURL
        self.topicID = topicID
        self.title = title
        self.url = url
        self.question = question
        self.provider = provider
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, siteURL, topicID, title, url, question, provider, model, status, origin
        case statusText, error, batchLimit, createdAt, updatedAt, startedAt, completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(WorkType.self, forKey: .type)
        siteURL = try container.decode(String.self, forKey: .siteURL)
        topicID = try container.decode(String.self, forKey: .topicID)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(URL.self, forKey: .url)
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        provider = try container.decode(AIProvider.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        status = try container.decode(WorkStatus.self, forKey: .status)
        origin = try container.decodeIfPresent(WorkOrigin.self, forKey: .origin) ?? .user
        statusText = try container.decodeIfPresent(String.self, forKey: .statusText) ?? ""
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        batchLimit = try container.decodeIfPresent(Int.self, forKey: .batchLimit)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

struct ForumFetchProgress: Equatable {
    var completedPages: Int
    var totalPages: Int
    var totalPosts: Int
    var message: String

    var fraction: Double {
        guard totalPages > 0 else { return 0 }
        return min(1, max(0, Double(completedPages) / Double(totalPages)))
    }
}

struct ForumFetchResult: Equatable {
    var content: String
    var rawPages: [RawForumPage]
    var totalPosts: Int
    var unchanged: Bool
    var newPosts: Int
    /// From the topic JSON fetched for the post count.
    var facts: TopicFacts?
}

struct ForumResourceResponse {
    var statusCode: Int
    var statusText: String
    /// Lowercased names.
    var headers: [String: String]
    var data: Data
}

enum AssistantError: LocalizedError {
    case noTopic
    case noForum
    case missingConfiguration(String)
    case invalidResponse
    case http(Int, String)
    case emptyResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noTopic:
            String(localized: "Open a topic or article first.")
        case .noForum:
            String(localized: "Open a forum first, or add the forum again.")
        case .missingConfiguration(let message):
            message
        case .invalidResponse:
            String(localized: "The server returned an invalid response.")
        case .http(let status, let message):
            String(localized: "HTTP \(status): \(message)", comment: "Error: HTTP status code, then the server's message")
        case .emptyResponse:
            String(localized: "The AI provider returned an empty response.")
        case .cancelled:
            String(localized: "The operation was cancelled.")
        }
    }
}
