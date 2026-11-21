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
        // Must have content after the prefix, and must not match known noun/site compounds
        // (e.g. "什么值得买", "翻译软件").
        if !chineseNonQuestionNames.contains(text) {
            for prefix in chineseQuestionPrefixes where text.hasPrefix(prefix) && text.count > prefix.count {
                return true
            }
        }

        // English question / instruction starters:
        // - wh-words require at least 2 words (excluding "how to ..." without "?").
        // - auxiliaries and instruction verbs require at least 3 words (or 2 words
        //   when an unambiguous instruction verb is followed by CJK text, which has no spaces)
        //   so ordinary two-word searches like "will smith", "list price", "show hn",
        //   "can opener", or "change management" stay searches.
        let lowered = text.lowercased()
        let words = lowered.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return false }

        let first = String(words[0])
        let second = String(words[1])
        if first == "how" && second == "to" {
            return false
        }
        if englishWhStarters.contains(first) {
            return true
        }
        if englishAuxAndVerbStarters.contains(first) {
            if words.count >= 3 {
                return true
            }
            if englishUnambiguousVerbs.contains(first),
               second.unicodeScalars.contains(where: { $0.value >= 0x4E00 }) {
                return true
            }
        }
        return false
    }

    private static let chineseQuestionSuffixes: [String] = [
        "吗", "嗎", "呢", "什么", "什麼",
    ]

    private static let chineseNonQuestionNames: Set<String> = [
        "什么值得买", "什麼值得買",
        "翻译软件", "翻譯軟件",
        "翻译工具", "翻譯工具",
        "翻译器", "翻譯器",
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

    private static let englishWhStarters: Set<String> = [
        "what", "what's", "what’s",
        "why", "why's", "why’s",
        "how", "how's", "how’s",
        "which",
        "who", "who's", "who’s",
        "where", "where's", "where’s",
        "when", "when's", "when’s",
    ]

    private static let englishUnambiguousVerbs: Set<String> = [
        "summarize", "summarise",
        "explain",
        "translate",
    ]

    private static let englishAuxAndVerbStarters: Set<String> = [
        // Auxiliaries
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
