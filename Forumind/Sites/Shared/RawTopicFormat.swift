import Foundation

/// The one shape of a topic's AI-facing text, whatever the platform:
///
/// - a post is `author | YYYY-MM-DD HH:MM:SS UTC | #N`, a newline, its body;
/// - posts are joined with `blockSeparator`, and a page's text ends in a newline;
/// - pages are joined with `blockSeparator` too;
/// - no post contains `blockSeparator`.
///
/// Prompts state this format, `ModerationFilter` hides posts by it and
/// `PromptBuilder.splitForHierarchicalSummary` cuts at the separator.
enum RawTopicFormat {
    static let blockSeparator = "\n\n\n"

    /// A header line: author token, date, post number.
    static let headerPattern = try! NSRegularExpression(
        pattern: #"^(\S+) \| (\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) UTC \| #(\d+)$"#,
        options: [.anchorsMatchLines]
    )

    struct Header: Equatable {
        var number: Int
        var author: String
        var date: Date?
        /// The header line's range in the parsed text (UTF-16 units).
        var range: NSRange
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Every header line of `text`, in order.
    static func parseHeaders(_ text: String) -> [Header] {
        let string = text as NSString
        return headerPattern.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            func part(_ index: Int) -> Int { Int(string.substring(with: match.range(at: index))) ?? 0 }
            let date = utc.date(from: DateComponents(
                year: part(2), month: part(3), day: part(4), hour: part(5), minute: part(6), second: part(7)
            ))
            return Header(
                number: part(8),
                author: string.substring(with: match.range(at: 1)),
                date: date,
                range: match.range
            )
        }
    }

    /// The blocks of a page's text: the headers it holds. Post numbers are
    /// the anchors (Discourse).
    static func blocks(in text: String) -> [PostBlock] {
        parseHeaders(text).map {
            PostBlock(number: $0.number, author: $0.author, date: $0.date, anchor: "\($0.number)", score: nil)
        }
    }

    /// Whitespace runs become `_`; `anonymous` when empty.
    static func authorToken(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? "anonymous" : words.joined(separator: "_")
    }

    static func headerLine(for block: PostBlock) -> String {
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: block.date ?? Date(timeIntervalSince1970: 0))
        let date = String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return "\(authorToken(block.author)) | \(date) UTC | #\(block.number)"
    }

    /// `\r\n` becomes `\n`, runs of three or more newlines collapse to two, and the body is trimmed.
    static func sanitizedBody(_ body: String) -> String {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n")
        while text.contains(blockSeparator) { text = text.replacingOccurrences(of: blockSeparator, with: "\n\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One page's text for `posts` (a post without a date gets the epoch).
    static func render(_ posts: [(block: PostBlock, body: String)]) -> String {
        posts
            .map { headerLine(for: $0.block) + "\n" + sanitizedBody($0.body) }
            .joined(separator: blockSeparator) + "\n"
    }

    /// The topic text for pages' texts, in page order.
    static func join(_ pageContents: [String]) -> String {
        pageContents.joined(separator: blockSeparator)
    }

    private static let rawPostSeparator = try! NSRegularExpression(
        pattern: #"\r?\n\r?\n-{5,}[ \t]*\r?\n\r?\n"#
    )

    /// Splits a raw topic text into its individual post blocks (`header\nbody`),
    /// handling both normalized `RawTopicFormat` (`\n\n\n`) and legacy Discourse
    /// `/raw` (`-----`) separators.
    static func postBlocks(_ text: String) -> [String] {
        let headers = parseHeaders(text)
        let string = text as NSString
        if let first = headers.first,
           string.substring(to: first.range.location).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return headers.enumerated().map { index, header in
                let end = index + 1 < headers.count ? headers[index + 1].range.location : string.length
                let slice = string.substring(with: NSRange(location: header.range.location, length: end - header.range.location))
                return slice.replacingOccurrences(
                    of: #"(?:\r?\n)+-{5,}[ \t]*\s*\z"#,
                    with: "",
                    options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        }
        let normalized = rawPostSeparator.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: string.length),
            withTemplate: blockSeparator
        )
        return normalized
            .components(separatedBy: blockSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Number of `RawForumPage`-sized pages in `text` (at least 1).
    static func pageCount(of text: String, pageSize: Int = RawForumPage.size) -> Int {
        let count = postBlocks(text).count
        guard count > 0, pageSize > 0 else { return 1 }
        return max(1, (count + pageSize - 1) / pageSize)
    }

    /// The text of 1-based `page` from `pages` when present, or sliced from `fallbackText` in chunks of `pageSize` posts.
    static func pageText(
        _ page: Int,
        pages: [RawForumPage],
        fallbackText: String,
        pageSize: Int = RawForumPage.size
    ) -> String {
        let sorted = pages.sorted { $0.page < $1.page }
        if page >= 1, page <= sorted.count {
            return sorted[page - 1].content
        }
        let blocks = postBlocks(fallbackText)
        let start = max(0, (page - 1) * pageSize)
        guard start < blocks.count else { return "" }
        let end = min(blocks.count, start + pageSize)
        return blocks[start..<end].joined(separator: blockSeparator) + "\n"
    }

    /// Filters post blocks in `text` by whitespace-separated terms in `query`.
    /// Returns the opening post (`#1` / first block), matching reply blocks, and whether the opening post itself matched.
    static func matchingBlocks(
        in text: String,
        query: String,
        openingPost: String? = nil
    ) -> (opening: String?, matches: [String], openingMatched: Bool) {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let blocks = postBlocks(text)
        let op = openingPost ?? blocks.first
        guard !terms.isEmpty else { return (op, [], false) }
        func matchesQuery(_ block: String) -> Bool {
            let lower = block.lowercased()
            return terms.contains { lower.contains($0) }
        }
        let replyBlocks: [String]
        if let first = blocks.first, first == op {
            replyBlocks = Array(blocks.dropFirst())
        } else {
            replyBlocks = blocks.filter { $0 != op }
        }
        let matchingReplies = replyBlocks.filter(matchesQuery)
        let opMatched = op.map(matchesQuery) ?? false
        return (op, matchingReplies, opMatched)
    }
}
