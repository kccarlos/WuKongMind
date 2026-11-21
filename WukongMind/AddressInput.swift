import Foundation

/// Classifies text entered in the address bar, Home, or onboarding into ordered
/// actions; the first action is what Return runs.
///
/// Motion task 3 unified the three separate resolvers; Motion task 5 adds the
/// conservative question/instruction rule ("Ask the Agent") when a page is
/// underneath (`Context.canAskAgent`).
enum AddressInput {
    enum ActionKind: Equatable {
        case open
        case askAgent
        case forumSearch
        case webSearch
    }

    enum Action: Equatable {
        case open(URL)
        case askAgent(String)
        case forumSearch(URL)
        case webSearch(URL)

        var kind: ActionKind {
            switch self {
            case .open: .open
            case .askAgent: .askAgent
            case .forumSearch: .forumSearch
            case .webSearch: .webSearch
            }
        }

        var url: URL? {
            switch self {
            case .open(let url), .forumSearch(let url), .webSearch(let url):
                return url
            case .askAgent:
                return nil
            }
        }
    }

    struct Context {
        var currentSiteURL: String?
        /// True when a web page is underneath the address overlay (never on an empty tab or onboarding).
        var canAskAgent: Bool = false
        var forumSearchURL: ((String) -> URL?)?
        var webSearchURL: (String) -> URL?
    }

    static func actions(for rawText: String, context: Context) -> [Action] {
        PerfProbe.time("AddressInput.actions") {
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }

            var result: [Action] = []
            if let url = ForumBrowserModel.resolveAddress(text, currentSiteURL: context.currentSiteURL) {
                result.append(.open(url))
                if let forumURL = context.forumSearchURL?(text) {
                    result.append(.forumSearch(forumURL))
                }
                if let webURL = context.webSearchURL(text) {
                    result.append(.webSearch(webURL))
                }
                return result
            }

            if context.canAskAgent, looksLikeQuestion(text) {
                result.append(.askAgent(text))
                if let webURL = context.webSearchURL(text) {
                    result.append(.webSearch(webURL))
                }
                return result
            }

            if let forumURL = context.forumSearchURL?(text) {
                result.append(.forumSearch(forumURL))
            }
            if let webURL = context.webSearchURL(text) {
                result.append(.webSearch(webURL))
            }
            return result
        }
    }

    /// Conservative word-table check for whether `rawText` is a question or
    /// instruction for the Agent (English, Simplified/Traditional Chinese, and
    /// mixed inputs). Near misses such as bare single words, "how to geek", or
    /// scheme URLs stay searches or addresses.
    static func looksLikeQuestion(_ rawText: String) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        // Never treat a URL-like token without spaces as a question.
        if !text.contains(where: \.isWhitespace), text.contains("://") {
            return false
        }

        // Explicit question mark (English or CJK), with content before it.
        if text.count > 1, let last = text.last, last == "?" || last == "？" {
            return true
        }

        // Chinese question-final particles / interrogative endings.
        if text.count > 1 {
            for suffix in chineseQuestionSuffixes where text.hasSuffix(suffix) {
                return true
            }
        }

        // Chinese question or instruction prefixes (no spaces required).
        for prefix in chineseQuestionPrefixes where text.hasPrefix(prefix) {
            if prefix == "请" || prefix == "請" || prefix == "可以" {
                if text.count > prefix.count { return true }
            } else {
                return true
            }
        }

        // English question / instruction starters (require at least two words
        // so single words like "make", "find", "who", or "what.cd" stay searches).
        let lowered = text.lowercased()
        let words = lowered.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return false }

        let first = String(words[0])
        let second = String(words[1])
        if first == "how" && second == "to" {
            // "how to geek", "how to tie a tie", etc. without "?" stay searches.
            return false
        }
        return englishStarters.contains(first)
    }

    private static let chineseQuestionSuffixes: [String] = [
        "吗", "嗎", "呢", "什么", "什麼",
    ]

    private static let chineseQuestionPrefixes: [String] = [
        "什么", "什麼",
        "怎么", "怎麼",
        "为什么", "為什麼",
        "为何", "為何",
        "如何",
        "是否",
        "能不能",
        "有没有", "有沒有",
        "可以",
        "帮我", "幫我",
        "请", "請",
        "总结", "總結",
        "概括",
        "翻译", "翻譯",
        "解释", "解釋",
        "隐藏", "隱藏",
        "去掉",
        "查找", "找出",
        "提取",
        "对比", "對比",
        "比较", "比較",
    ]

    private static let englishStarters: Set<String> = [
        // Question words
        "what", "what's", "what’s",
        "why", "why's", "why’s",
        "how", "how's", "how’s",
        "which",
        "who", "who's", "who’s",
        "where", "where's", "where’s",
        "when", "when's", "when’s",
        "is", "are", "was", "were",
        "can", "could", "will", "would", "should",
        "do", "does", "did",
        // Instruction verbs
        "summarize", "summarise",
        "explain",
        "translate",
        "make",
        "hide",
        "find",
        "show",
        "list",
        "compare",
        "remove",
        "change",
        "highlight",
        "extract",
        "rewrite",
        "tell",
    ]
}
