import Foundation

struct HackerNewsAdapter: SiteAdapter {
    var kind: SiteKind { .hackerNews }
    var recognizer: any SiteRecognizer { HackerNewsRecognizer() }
    var links: any SiteLinks { HackerNewsLinks() }
    var agent: AgentSiteProfile { HackerNewsAgent.profile }
    var voice: VoiceSiteProfile { HackerNewsAgent.voice }
    var discussion: DiscussionProfile { HackerNewsAgent.discussion }
    var suggestedForums: SuggestedForums { SuggestedForums(general: [], chinese: []) }
    var capabilities: SiteCapabilities {
        SiteCapabilities(activeTopics: HackerNewsActiveTopics(), postLookup: HackerNewsPostLookup(), topicFilters: nil,
                         pageBridge: nil, loginURL: nil, searchPageURL: { _, query in
            var parts = URLComponents(string: "https://hn.algolia.com/")!
            parts.queryItems = [.init(name: "q", value: query)]
            return parts.url
        }, session: nil, firstPartyPathPatterns: [])
    }
    func siteURLCandidates(fromAddress address: String) -> [String] {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.contains("://") ? text : "https://" + text),
              HackerNewsRecognizer.accepts(url) else { return [] }
        return [HackerNewsRecognizer.siteURL]
    }
    func siteInfo(siteURL: String, net: SiteNetwork) async throws -> ForumSiteInfo {
        guard let url = URL(string: siteURL), HackerNewsRecognizer.accepts(url) else { throw AssistantError.invalidResponse }
        let direct = SiteNetwork(service: net.service, siteURL: HackerNewsRecognizer.siteURL,
                                 context: SiteRequestContext(pace: net.context.pace))
        let data = try await direct.data(URL(string: HackerNewsRecognizer.siteURL)!, accept: "text/html")
        let html = String(decoding: data, as: UTF8.self)
        // A valid 200 HTML page may discuss Cloudflare or challenge phrases.
        // Validate its structure; never classify by words in user content (ae3b61b).
        guard html.range(of: #"\bid=["']?hnmain\b"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            throw AssistantError.invalidResponse
        }
        return ForumSiteInfo(name: "Hacker News", iconURL: URL(string: HackerNewsRecognizer.siteURL + "/y18.svg"))
    }
    func overview(_ topic: TopicRef, net: SiteNetwork) async throws -> ForumTopicOverview {
        let tree = try await HackerNewsAPI(net: net).story(topic.topicID)
        let posts = HackerNewsAPI.posts(tree)
        return ForumTopicOverview(siteURL: topic.siteURL, topicID: topic.topicID, title: tree.title ?? "",
                                  slug: "", url: links.topicURL(siteURL: topic.siteURL, topicID: topic.topicID, slug: nil)!,
                                  postCount: posts.count, facts: HackerNewsAPI.facts(posts))
    }
    func readTopic(_ request: TopicReadRequest, net: SiteNetwork,
                   progress: @escaping @Sendable (ForumFetchProgress) async -> Void,
                   onPage: (@Sendable (RawForumPage) async -> Void)?) async throws -> ForumFetchResult {
        let tree = try await HackerNewsAPI(net: net).story(request.topic.topicID)
        let posts = HackerNewsAPI.posts(tree)
        let pages = stride(from: 0, to: posts.count, by: RawForumPage.size).map { start in
            let slice = Array(posts[start..<min(start + RawForumPage.size, posts.count)])
            return RawForumPage(page: start / RawForumPage.size + 1, content: RawTopicFormat.render(slice),
                                topicPostCount: posts.count, blocks: slice.map(\.block))
        }
        // Compare complete content, not just counts: comments can be edited/deleted.
        let unchanged = request.cachedPages.sorted { $0.page < $1.page } == pages
        return try await PagedTopicFetch.run(
            plan: unchanged ? .unchanged : .fetch(reusablePages: [], pageNumbers: pages.map(\.page)),
            cachedPages: request.cachedPages, knownTotalPosts: request.knownTotalPosts,
            totalPosts: posts.count, totalPages: pages.count, facts: HackerNewsAPI.facts(posts),
            pace: net.context.pace, progress: progress, onPage: onPage, fetchPage: { pages[$0 - 1] })
    }
    func run(_ query: SiteQuery, net: SiteNetwork) async throws -> SiteQueryResult {
        try await HackerNewsAPI(net: net).run(query)
    }
}

/// Numbers refer to preorder positions in the same tree used by readTopic.
struct HackerNewsPostLookup: PostLookup {
    func posts(_ numbers: [Int], in topic: TopicRef, facts: TopicFacts, net: SiteNetwork) async throws -> [ForumPost] {
        let tree = try await HackerNewsAPI(net: net).story(topic.topicID)
        let posts = HackerNewsAPI.posts(tree)
        return numbers.compactMap { number in
            guard number > 0, number <= posts.count else { return nil }
            let post = posts[number - 1]
            return ForumPost(id: Int(post.block.anchor)!, number: number, username: post.block.author,
                             text: post.body, likeCount: post.block.score)
        }
    }
}

struct HackerNewsActiveTopics: ActiveTopicsSource {
    func activeTopics(siteURL: String, budget: Int, net: SiteNetwork) async -> ActiveTopicsResult {
        guard budget > 0 else { return .init(topics: nil, requests: 0, failures: 0) }
        do {
            // Relevance search with no words ranks popular stories in the last day.
            let result = try await HackerNewsAPI(net: net).search(text: "", comments: false, options: SearchOptions(), active: true)
            return .init(topics: result.topics, requests: 1, failures: 0)
        } catch {
            return .init(topics: nil, requests: 1, failures: 1)
        }
    }
}
