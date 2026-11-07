import Foundation

/// Algolia returns the whole item tree in one JSON response. It has a separate
/// origin: keep the shared service/pacer but pass neither forum cookies nor a
/// page loader to it. All reads still go through scoped SiteNetwork requests.
struct HackerNewsAPI: Sendable {
    let net: SiteNetwork
    struct Item: Decodable, Sendable {
        var id: Int
        var type: String
        var author: String?
        var title: String?
        var text: String?
        var url: String?
        var points: Int?
        var created_at_i: Double?
        var children: [Item]?
    }
    private func data(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard let site = URL(string: net.siteURL), HackerNewsRecognizer.accepts(site) else {
            throw AssistantError.invalidResponse
        }
        var parts = URLComponents(string: "https://hn.algolia.com/api/v1" + path)!
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url.flatMap({ URL(string: $0.absoluteString.replacingOccurrences(of: "+", with: "%2B")) }) else {
            throw AssistantError.invalidResponse
        }
        let publicAPI = SiteNetwork(service: net.service, siteURL: "https://hn.algolia.com",
                                    context: SiteRequestContext(pace: net.context.pace))
        return try await publicAPI.data(url, accept: "application/json")
    }
    func story(_ id: String) async throws -> Item {
        guard let valid = HackerNewsRecognizer.validID(id) else { throw AssistantError.invalidResponse }
        let bytes = try await data("/items/" + valid)
        guard let item = try? JSONDecoder().decode(Item.self, from: bytes),
              String(item.id) == valid, ["story", "job", "poll"].contains(item.type) else { throw AssistantError.invalidResponse }
        return item
    }
    /// Preorder preserves the nested thread. Parent numbers and original item ids
    /// live in the body, so moderation, page slicing and query reads retain them.
    static func posts(_ story: Item) -> [(block: PostBlock, body: String)] {
        var result: [(block: PostBlock, body: String)] = []
        func visit(_ item: Item, parentNumber: Int?, parentID: Int?) {
            let number = result.count + 1
            let block = PostBlock(number: number, author: RawTopicFormat.authorToken(item.author ?? ""),
                                  date: item.created_at_i.map(Date.init(timeIntervalSince1970:)),
                                  anchor: String(item.id), score: item.points)
            var body = HTMLText.plainText(item.text ?? "")
            if number == 1 {
                body = "Story: \(story.title ?? "")\nURL: \(HackerNewsRecognizer.siteURL)/item?id=\(story.id)"
                    + (story.url.flatMap { $0.isEmpty ? nil : "\nLink: \($0)" } ?? "") + "\n\n" + body
            } else if let parentNumber, let parentID {
                body = "[Reply to #\(parentNumber); item \(parentID)]\n" + (body.isEmpty ? "[deleted]" : body)
            }
            result.append((block, body))
            for child in item.children ?? [] { visit(child, parentNumber: number, parentID: item.id) }
        }
        visit(story, parentNumber: nil, parentID: nil)
        return result
    }
    static func facts(_ posts: [(block: PostBlock, body: String)]) -> TopicFacts {
        TopicFacts(postsCount: posts.count, highestPostNumber: posts.count,
                   openingPoster: posts.first?.block.author,
                   posts: posts.map {
                       TopicFacts.Post(id: Int($0.block.anchor) ?? $0.block.number,
                                       number: $0.block.number, username: $0.block.author)
                   })
    }
    func run(_ query: SiteQuery) async throws -> SiteQueryResult {
        switch query {
        case .latest:
            return try await search(text: "", comments: false, options: SearchOptions(), newest: true)
        case .search(let text, let scope, let options):
            switch scope {
            case .forum: return try await search(text: text, comments: false, options: options)
            case .comments: return try await search(text: text, comments: true, options: options)
            case .topic: throw SiteQueryError.unsupported
            }
        }
    }
    func search(text: String, comments: Bool, options: SearchOptions, newest: Bool = false, active: Bool = false) async throws -> SiteQueryResult {
        var query: [URLQueryItem] = [
            .init(name: "tags", value: comments ? "comment" : "story"),
            .init(name: "query", value: text),
            .init(name: "page", value: String(options.page - 1)),
            .init(name: "hitsPerPage", value: comments ? "10" : newest ? "30" : "20")
        ]
        var filters: [String] = []
        if let date = options.after { filters.append("created_at_i>\(Int(date.timeIntervalSince1970))") }
        if let date = options.before { filters.append("created_at_i<\(Int(date.timeIntervalSince1970))") }
        if active { filters.append("created_at_i>\(Int(Date().timeIntervalSince1970) - 86400)") }
        if !filters.isEmpty { query.append(.init(name: "numericFilters", value: filters.joined(separator: ","))) }
        let bytes = try await data(newest ? "/search_by_date" : "/search", query: query)
        guard let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]] else { throw AssistantError.invalidResponse }
        let found = hits.compactMap { hit -> ForumSearchHit? in
            guard let objectID = HackerNewsRecognizer.validID(hit["objectID"] as? String),
                  let id = comments ? hit["story_id"] as? Int : Int(objectID), id > 0 else { return nil }
            let title = HTMLText.plainText(hit[comments ? "story_title" : "title"] as? String ?? "")
            let excerpt = HTMLText.plainText(hit[comments ? "comment_text" : "story_text"] as? String ?? "")
            let page = HackerNewsLinks().topicURL(siteURL: net.siteURL, topicID: String(id), slug: nil)!
            let count = (hit["num_comments"] as? Int).map { $0 + 1 }
            let date = hit["created_at"] as? String
            let topic = ForumTopicListing(siteURL: net.siteURL, id: id, title: title, slug: "", url: page,
                                          postsCount: count, lastPostedAt: date, excerpt: String(excerpt.prefix(500)),
                                          likeCount: comments ? nil : hit["points"] as? Int,
                                          author: comments ? nil : hit["author"] as? String)
            var blurb = excerpt
            if comments, let parent = hit["parent_id"] as? Int { blurb = "[Reply to item \(parent)] " + blurb }
            return ForumSearchHit(topic: topic, postNumber: comments ? nil : 1,
                                  username: hit["author"] as? String ?? "anonymous", blurb: String(blurb.prefix(500)),
                                  postedAt: date, url: comments ? HackerNewsLinks().postURL(topicURL: page, number: 0, anchor: objectID) : page)
        }
        var seen = Set<Int>()
        return SiteQueryResult(topics: found.map(\.topic).filter { seen.insert($0.id).inserted }, hits: found)
    }
}
