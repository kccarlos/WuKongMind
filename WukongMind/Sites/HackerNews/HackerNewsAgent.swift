import Foundation

enum HackerNewsAgent {
    static let voice = VoiceSiteProfile(
        persona: "a reading companion for Hacker News stories and nested comments",
        findHint: "Search Hacker News with concise English technical terms, then read the story and its comments.",
        languageHint: "Search in English even when the user asks in another language; answer in the user's language.")
    static let discussion = DiscussionProfile(
        openingHeading: "Story", material: "a Hacker News story and its nested comments",
        blocks: "#1 is the story, including its submitted link and any story text, not the linked article's full text. "
            + "Later numbers are comments in tree order. [Reply to #N; item ID] names the parent, even when it is hidden or on another page.",
        signals: "Story points are votes, not verification. Comment scores and accepted answers are unavailable.")
    private static let parameters: [AgentToolSpec.Parameter] = [
        .init(name: "query", description: "Search words", required: true),
        .init(name: "page", description: "Result page, 1 to 3", required: false)
    ]
    static let profile = AgentSiteProfile(
        siteDescription: "Hacker News stories and nested comment threads", siteNoun: "site", topicNoun: "story",
        postNumbering: "#1 is the submitted story; later #N are comments in tree order, not item ids. "
            + "[Reply to #N; item ID] names the parent. Cite the story URL, or use a known comment item id as its fragment.",
        postCitation: "Cite a story as [title](url), retaining its ?id= parameter.",
        siteTools: [
            .init(name: ForumToolName.searchForum,
                  description: "Search Hacker News stories by keyword. Returns up to 20 stories per page.", parameters: parameters),
            .init(name: ForumToolName.searchComments,
                  description: "Search comments across stories, returning up to 10 authored excerpts and story ids. Read the story for context.", parameters: parameters),
            .init(name: ForumToolName.listLatest,
                  description: "List the newest 30 stories.", parameters: [])
        ], query: { tool, arguments in
            switch tool {
            case ForumToolName.listLatest: return .latest
            case ForumToolName.searchForum, ForumToolName.searchComments:
                guard let text = arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    throw AgentError.missingArgument("query")
                }
                return .search(text: text, scope: tool == ForumToolName.searchComments ? .comments : .forum,
                               options: try SearchOptions(arguments: arguments, allowsCategory: false))
            default: throw SiteQueryError.unsupported
            }
        }, postLinkHint: { "(story and comments: \($0.absoluteString); comment item ID: \($0.absoluteString)#ID)" })
}
