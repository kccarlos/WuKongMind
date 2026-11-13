import Foundation

extension DiscourseAdapter {
    var suggestedForums: SuggestedForums {
        SuggestedForums(general: Self.generalSuggestions, chinese: Self.chineseSuggestions)
    }

    /// Offered first in the walkthrough when the app language is Chinese.
    static let chineseSuggestions: [SuggestedForum] = [
        SuggestedForum(
            kind: .discourse,
            name: "美卡论坛",
            siteURL: "https://www.uscardforum.com",
            description: String(localized: "Credit cards, travel rewards and personal finance in the US, in Chinese.", comment: "Description of a suggested forum")
        ),
        SuggestedForum(
            kind: .discourse,
            name: "LINUX DO",
            siteURL: "https://linux.do",
            description: String(localized: "A Chinese-language community for technology, AI and open source.", comment: "Description of a suggested forum")
        )
    ]

    static let generalSuggestions: [SuggestedForum] = [
        SuggestedForum(
            kind: .discourse,
            name: "Discourse Meta",
            siteURL: "https://meta.discourse.org",
            description: String(localized: "Discourse’s own community for features, support, and plugins.", comment: "Description of a suggested forum")
        ),
        SuggestedForum(
            kind: .discourse,
            name: "OpenAI Developer Community",
            siteURL: "https://community.openai.com",
            description: String(localized: "Developers discussing the OpenAI API, models, and tools.", comment: "Description of a suggested forum")
        ),
        SuggestedForum(
            kind: .discourse,
            name: "Cursor Community Forum",
            siteURL: "https://forum.cursor.com",
            description: String(localized: "Help, bug reports, and tips for the Cursor code editor.", comment: "Description of a suggested forum")
        ),
        SuggestedForum(
            kind: .discourse,
            name: "Discussions on Python.org",
            siteURL: "https://discuss.python.org",
            description: String(localized: "Python language ideas, packaging, and help.", comment: "Description of a suggested forum")
        ),
        SuggestedForum(
            kind: .discourse,
            name: "Home Assistant Community",
            siteURL: "https://community.home-assistant.io",
            description: String(localized: "Home automation setups, integrations, and troubleshooting.", comment: "Description of a suggested forum")
        )
    ]
}
