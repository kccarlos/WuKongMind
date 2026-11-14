import Foundation

/// Structured thread output carried beside rendered forum text (`design-one-loop.md` "The two shapes").
struct ThreadShape: Codable, Equatable, Sendable {
    struct Post: Codable, Equatable, Sendable {
        var number: Int
        var author: String
        var body: String
        var date: String? = nil
        var score: Int? = nil
        var replyTo: Int? = nil

        enum CodingKeys: String, CodingKey {
            case number, author, body, date, score
            case replyTo = "reply_to"
        }
    }

    var id: String? = nil
    var title: String
    var url: String
    var posts: [Post]
    var totalPosts: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, url, posts
        case totalPosts = "total_posts"
    }

    init(id: String? = nil, title: String, url: String, posts: [Post], totalPosts: Int? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.posts = posts
        self.totalPosts = totalPosts
    }

    init(session: TopicSession) {
        let posts: [Post]
        if !session.rawPages.isEmpty {
            posts = session.rawPages.sorted { $0.page < $1.page }
                .flatMap { Self.posts(in: $0.content, blocks: $0.blocks, dropEpochDates: false) }
        } else {
            posts = Self.posts(
                in: session.source, blocks: RawTopicFormat.blocks(in: session.source), dropEpochDates: true
            )
        }
        self.init(
            id: session.topicID.isEmpty ? nil : session.topicID,
            title: session.title,
            url: session.url.absoluteString,
            posts: posts,
            totalPosts: session.totalPosts
        )
    }

    private static let utcISO8601 = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!)
    private static let replyToPattern = try! NSRegularExpression(pattern: #"^\[Reply to #(\d+)(?:;[^\]]*)?\]"#)

    private static func posts(in content: String, blocks: [PostBlock], dropEpochDates: Bool) -> [Post] {
        let chunks = RawTopicFormat.postBlocks(content)
        let resolved = blocks.count == chunks.count ? blocks : RawTopicFormat.blocks(in: content)
        guard resolved.count == chunks.count else { return [] }
        return zip(resolved, chunks).map { block, chunk in
            let body = chunk.firstIndex(of: "\n").map { String(chunk[chunk.index(after: $0)...]) } ?? ""
            let formattedDate: String?
            if let date = block.date, !(dropEpochDates && date.timeIntervalSince1970 == 0) {
                formattedDate = date.formatted(utcISO8601)
            } else {
                formattedDate = nil
            }
            return Post(
                number: block.number, author: block.author, body: body,
                date: formattedDate, score: block.score, replyTo: parseReplyTo(in: body)
            )
        }
    }

    private static func parseReplyTo(in body: String) -> Int? {
        let nsBody = body as NSString
        guard let match = replyToPattern.firstMatch(in: body, range: NSRange(location: 0, length: nsBody.length)) else {
            return nil
        }
        return Int(nsBody.substring(with: match.range(at: 1)))
    }
}

/// Structured topic or search list carried beside rendered forum text (`design-one-loop.md` "The two shapes").
struct ListShape: Codable, Equatable, Sendable {
    struct Hit: Codable, Equatable, Sendable {
        var number: Int? = nil
        var author: String? = nil
        var blurb: String? = nil
    }

    struct Item: Codable, Equatable, Sendable {
        var id: String? = nil
        var title: String
        var url: String
        var postsCount: Int? = nil
        var lastActivity: String? = nil
        var excerpt: String? = nil
        var author: String? = nil
        var hits: [Hit]? = nil

        enum CodingKeys: String, CodingKey {
            case id, title, url, excerpt, author, hits
            case postsCount = "posts_count"
            case lastActivity = "last_activity"
        }
    }

    var items: [Item]

    init(items: [Item]) {
        self.items = items
    }

    init(listings: [ForumTopicListing], hits: [ForumSearchHit] = []) {
        let hitsByTopic = Dictionary(grouping: hits, by: \.topic.id)
        self.items = listings.map { listing in
            let mappedHits = hitsByTopic[listing.id].flatMap { topicHits in
                topicHits.isEmpty ? nil : topicHits.map {
                    Hit(number: $0.postNumber, author: Self.nonEmpty($0.username), blurb: Self.nonEmpty($0.blurb))
                }
            }
            return Item(
                id: listing.topicID, title: listing.title, url: listing.url.absoluteString,
                postsCount: listing.postsCount, lastActivity: Self.nonEmpty(listing.lastPostedAt),
                excerpt: Self.nonEmpty(listing.excerpt), author: Self.nonEmpty(listing.author),
                hits: mappedHits
            )
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Either of the two structured forum tool shapes (`design-one-loop.md` "The two shapes").
enum ForumShape: Codable, Equatable, Sendable {
    case thread(ThreadShape)
    case list(ListShape)

    private enum CodingKeys: String, CodingKey { case thread, list }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let thread = try container.decodeIfPresent(ThreadShape.self, forKey: .thread) {
            self = .thread(thread)
        } else {
            self = .list(try container.decode(ListShape.self, forKey: .list))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .thread(let thread): try container.encode(thread, forKey: .thread)
        case .list(let list): try container.encode(list, forKey: .list)
        }
    }
}
