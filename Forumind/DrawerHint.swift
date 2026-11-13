import Foundation

// MARK: - AI drawer hint row and post citations
//
// The pure parts of the iPhone AI drawer (AIDrawer.swift, Dock.swift,
// SummaryPanel.swift): the hint row over the bar while the drawer is closed,
// and the `#N` post citations in a summary (found, linked and tapped to jump
// to the post, §4.5).

/// The row over the bar that says what the drawer can do for this topic,
/// only when it is worth a look: the first topic ever opened (the one-time
/// "Summarize this topic" tip), new replies since the summary, or AI not set
/// up. Otherwise there is no row.
enum DrawerHint {
    struct Input: Equatable {
        var pageState: PageContext.State
        var mode: AssistantMode = .summary
        /// The AI provider for the mode is set up.
        var providerReady = true
        var hasSummary = false
        /// A summary (or a pull of the posts) runs for the topic.
        var summaryRunning = false
        /// The topic's post count and how many the summary covered.
        var totalPosts: Int?
        var summaryPostCount: Int?
    }

    /// The row's trailing button.
    enum Action: Equatable {
        case summarize
        /// The summary is behind by this many replies (always known: the
        /// row only comes with both counts).
        case checkNew(Int)
        case setUpAI

        /// Spoken label of the icon-only button.
        var title: String {
            switch self {
            case .summarize: String(localized: "Summarize this topic", comment: "Hint row over the bar on a topic without a summary, and its button")
            case .checkNew(let count): String(localized: "Check \(count) new replies", comment: "Button on the hint row over the bar; the placeholder is the number of replies since the summary")
            case .setUpAI: String(localized: "Set up AI", comment: "Hint row over the bar when no AI provider is set up, and its button")
            }
        }

        var symbol: String {
            switch self {
            case .summarize: "sparkles"
            case .checkNew: "arrow.clockwise"
            case .setUpAI: "key.fill"
            }
        }

        /// The count on the badge ("99+" from 100), if any.
        var badge: String? {
            guard case .checkNew(let count) = self, count > 0 else { return nil }
            return count > 99 ? "99+" : "\(count)"
        }

        var needsAttention: Bool { self == .setUpAI }
    }

    /// The row: its text, and the button that does the action.
    struct Row: Equatable {
        let action: Action
        /// The one-time first-run tip (a bulb, highlighted).
        let isTip: Bool

        var text: String {
            switch action {
            case .checkNew(let count): String(localized: "\(count) new replies")
            case .summarize, .setUpAI: action.title
            }
        }
    }

    /// What the drawer's main action is for a page state; nil when there is
    /// nothing to do (no topic, a summary running or up to date, Ask the forum).
    static func action(_ input: Input) -> Action? {
        guard input.pageState == .topic else { return nil }
        if !input.providerReady { return .setUpAI }
        guard input.mode != .agent, !input.summaryRunning else { return nil }
        if !input.hasSummary { return .summarize }
        if let total = input.totalPosts, let covered = input.summaryPostCount, total > covered {
            return .checkNew(total - covered)
        }
        return nil
    }

    /// The split layout's panel toggle shows a dot for new replies while the
    /// panel is hidden (there is no hint row there).
    static func showsSplitNewRepliesDot(_ input: Input, panelShown: Bool) -> Bool {
        guard !panelShown, case .checkNew? = action(input) else { return false }
        return true
    }

    /// The hint row, or nil for no row. "Summarize this topic" shows only as
    /// the first-run tip (`tipPending`); new replies and AI setup always.
    static func row(_ input: Input, tipPending: Bool) -> Row? {
        switch action(input) {
        case nil: nil
        case .summarize: tipPending ? Row(action: .summarize, isTip: true) : nil
        case let action?: Row(action: action, isTip: false)
        }
    }
}

/// `#N` post citations in AI text. The summary prompt asks for them; the
/// drawer turns each into a link (`forumind-post:N`) that renders as a chip
/// and jumps to the post.
enum PostCitations {
    static let scheme = "forumind-post"

    /// `#37`, not inside a word, a URL or `##`. ASCII only before it, so
    /// `确认#37` still counts. Brackets can group citations; `](...` marks an existing link.
    private static let pattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_&/#])#(\d{1,5})(?!\d)(?![^\[\]\n]*\]\()"#
    )

    static func url(post number: Int) -> URL? {
        URL(string: "\(scheme):\(number)")
    }

    /// The post number of a citation link, or nil.
    static func postNumber(from url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.absoluteString.dropFirst(scheme.count + 1)).flatMap { $0 >= 1 ? $0 : nil }
    }

    /// The cited post numbers in order of first appearance.
    static func numbers(in text: String, maximum: Int? = nil) -> [Int] {
        var seen: [Int] = []
        _ = MarkdownCodeSpans.transform(text) { segment in
            for (_, number) in matches(in: segment, maximum: maximum) where !seen.contains(number) {
                seen.append(number)
            }
            return segment
        }
        return seen
    }

    /// Rewrites `#37` as `[#37](forumind-post:37)` outside code. Numbers above
    /// `maximum` (the topic's highest post) stay plain text.
    static func linked(_ markdown: String, maximum: Int? = nil) -> String {
        MarkdownCodeSpans.transform(markdown) { line in
            let nsLine = line as NSString
            var result = ""
            var cursor = 0
            for (range, number) in matches(in: line, maximum: maximum) {
                result += nsLine.substring(with: NSRange(location: cursor, length: range.location - cursor))
                result += "[#\(number)](\(scheme):\(number))"
                cursor = range.location + range.length
            }
            return result + nsLine.substring(from: cursor)
        }
    }

    /// The text without citations (read aloud, translated).
    static func stripped(_ markdown: String) -> String {
        guard let pattern else { return markdown }
        return MarkdownCodeSpans.transform(markdown) { segment in
            // Only discard groups that held citations, including their enclosing emphasis.
            let group = #"(?:\[[\s,、，;；#0-9]+\]|\([\s,、，;；#0-9]+\)|（[\s,、，;；#0-9]+）|【[\s,、，;；#0-9]+】)"#
            let groups = try? NSRegularExpression(pattern: "([*_]{1,3})" + group + #"\1|"# + group)
            let nsText = segment as NSString
            let citations = pattern.matches(in: segment, range: NSRange(location: 0, length: nsText.length))
            var text = segment
            for match in (groups?.matches(in: segment, range: NSRange(location: 0, length: nsText.length)) ?? []).reversed() {
                let candidate = nsText.substring(with: match.range)
                let remaining = pattern.stringByReplacingMatches(in: candidate,
                    range: NSRange(location: 0, length: (candidate as NSString).length), withTemplate: "")
                guard remaining != candidate,
                      remaining.allSatisfy({ "[]()（）【】*_,、，;；".contains($0) || $0.isWhitespace }),
                      citations.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
                text = (text as NSString).replacingCharacters(in: match.range, with: "")
            }
            let removed = pattern.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: ""
            )
            // "fixes it #37 ; three" → "fixes it; three"
            return removed
                .replacingOccurrences(of: #"[ \t]+([.,;:!?。，；：！？])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        }
    }

    private static func matches(in text: String, maximum: Int?) -> [(NSRange, Int)] {
        guard let pattern else { return [] }
        let nsText = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard let number = Int(nsText.substring(with: match.range(at: 1))), number >= 1 else { return nil }
            if let maximum, maximum > 0, number > maximum { return nil }
            return (match.range, number)
        }
    }
}

/// Walks Markdown lines while skipping fenced (` ``` ` / `~~~`) and inline
/// backtick code spans so citation extractors and rewriters leave code alone.
enum MarkdownCodeSpans {
    static func mapLines(_ markdown: String, _ body: (String, [NSRange]) -> String) -> String {
        var activeFence: (char: Character, length: Int)?
        return markdown.components(separatedBy: "\n").map { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let fence = activeFence {
                if let first = trimmed.first, first == fence.char {
                    let count = trimmed.prefix { $0 == first }.count
                    let rest = trimmed.dropFirst(count)
                    if count >= fence.length, rest.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
                        activeFence = nil
                    }
                }
                return line
            }
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix { $0 == first }.count
                let rest = trimmed.dropFirst(count)
                if count >= 3, !(first == "`" && rest.contains("`")) {
                    activeFence = (first, count)
                    return line
                }
            }
            return body(line, inlineRanges(in: line))
        }
        .joined(separator: "\n")
    }

    static func transform(_ markdown: String, _ body: (String) -> String) -> String {
        mapLines(markdown) { line, codeRanges in
            guard !codeRanges.isEmpty else { return body(line) }
            let nsLine = line as NSString
            var result = ""
            var cursor = 0
            for code in codeRanges {
                if code.location > cursor {
                    result += body(nsLine.substring(with: NSRange(location: cursor, length: code.location - cursor)))
                }
                result += nsLine.substring(with: code)
                cursor = code.location + code.length
            }
            if cursor < nsLine.length {
                result += body(nsLine.substring(from: cursor))
            }
            return result
        }
    }

    static func inlineRanges(in line: String) -> [NSRange] {
        let nsLine = line as NSString
        let length = nsLine.length
        let backtick: unichar = 0x60
        var ranges: [NSRange] = []
        var i = 0
        while i < length {
            guard nsLine.character(at: i) == backtick else {
                i += 1
                continue
            }
            var openEnd = i
            while openEnd < length, nsLine.character(at: openEnd) == backtick { openEnd += 1 }
            let runLength = openEnd - i
            var search = openEnd
            var closedAt: Int?
            while search < length {
                guard nsLine.character(at: search) == backtick else {
                    search += 1
                    continue
                }
                var closeEnd = search
                while closeEnd < length, nsLine.character(at: closeEnd) == backtick { closeEnd += 1 }
                if closeEnd - search == runLength {
                    closedAt = closeEnd
                    break
                }
                search = closeEnd
            }
            if let closeEnd = closedAt {
                ranges.append(NSRange(location: i, length: closeEnd - i))
                i = closeEnd
            } else {
                i = openEnd
            }
        }
        return ranges
    }

    static func overlapsEndpoint(_ range: NSRange, codeRanges: [NSRange]) -> Bool {
        guard range.length > 0 else { return false }
        let last = range.location + range.length - 1
        return codeRanges.contains { NSLocationInRange(range.location, $0) || NSLocationInRange(last, $0) }
    }
}

/// One jump to a cited post; `serial` makes a second tap on the same post a
/// new event (haptic).
struct CitationJump: Equatable {
    var number: Int
    var serial: Int
}
