import Foundation

#if DEBUG
/// The words of the DEBUG sample data (`-dc-sample`, `-dc-seed-forums`) in
/// the app's language, so screenshots in Simplified or Traditional Chinese
/// show Chinese topics, summaries, chats, answers and pages too.
///
/// The forums are real public ones (Discourse Meta and the OpenAI Developer
/// Community, as in the Chrome extension's screenshots); every topic, post,
/// summary and username is invented, and the topic page behind the sample
/// is drawn from `tipsPage` / `streamingPage` (`topicPageHTML`), never
/// loaded, so no real person's name, photo or words appear. The topics match
/// the extension's (`tools/ui/fixtures/copy/*.mjs` in its repository), so the
/// two read as one product. Debug-only: not in the String Catalog.
struct SampleContent {
    struct ForumText {
        var siteURL: String
        var name: String
    }

    /// One post on a sample topic page.
    struct PagePost {
        /// Its post number; nil: the next one.
        var number: Int? = nil
        var user: String
        var badge: String? = nil
        var time: String
        /// Paragraphs; may hold `<b>` and `<code>`.
        var body: [String]
        var likes: Int
    }

    /// A sample topic page (`topicPageHTML`): posts 1…`length`, the ones
    /// not in `posts` short generic replies (`fillerReplies`), so the posts
    /// the summary cites are on the page and citation jumps land.
    struct Page {
        var category: String
        var tags: [String]
        var length: Int
        var posts: [PagePost]
    }

    // Forums (`-dc-sample`, `-dc-seed-forums`): the same in every language.
    var meta = ForumText(siteURL: "https://meta.discourse.org", name: "Discourse Meta")
    var openAI = ForumText(siteURL: "https://community.openai.com", name: "OpenAI Developer Community")

    // Topic titles. Discourse Meta: the open topic, and two more.
    var tipsTitle: String
    var notificationsTitle: String
    var workingOnTitle: String
    // OpenAI Developer Community: the open topic, the answer's sources, one more.
    var streamingTitle: String
    var rateLimitErrorsTitle: String
    var backoffGuideTitle: String
    var batchingTitle: String
    var higherLimitTitle: String
    var longThreadsTitle: String

    // Summaries and chats.
    var tipsSummary: String
    var tipsChat: [(ChatRole, String)]
    var notificationsSummary: String
    var workingOnSummary: String
    var streamingSummary: String
    var streamingChat: [(ChatRole, String)]
    var rateLimitErrorsSummary: String
    var longThreadsSummary: String

    // Ask the forum (on the OpenAI Developer Community).
    var agentGoal: String
    var agentSearchQuery: String
    var agentSecondSearchQuery: String
    /// One per step: search, read S1, read S2, search, read S3, read S4, answer.
    var agentThoughts: [String]
    var agentRunningStatus: String
    /// The URLs of the four sources, in order.
    var agentAnswer: (_ s1: String, _ s2: String, _ s3: String, _ s4: String) -> String
    var agentFollowUpQuestion: String
    var agentFollowUpAnswer: String
    // The older run (on Discourse Meta).
    var olderGoal: String
    var olderSearchQuery: String
    var olderAnswer: String

    // Work in progress.
    var summaryRunningStatus: String
    var summaryStream: String

    // Daily digest (`-dc-digest-sample`): the tips, rate-limit and long-threads cards.
    var digestBlurbs: [String]

    // The pages drawn behind the sample (`topicPageHTML`).
    var tipsPage: Page
    var streamingPage: Page
    var fillerReplies: [String]
    var replyLabel: String
    var language: String

    /// The set for the app's language.
    static var current: SampleContent {
        switch AppLanguage.current {
        case "zh-Hans": simplifiedChinese
        case "zh-Hant": traditionalChinese
        default: english
        }
    }
}

// MARK: - Topic page

extension SampleContent {
    /// A small Discourse-style topic page, shown behind the sample at the
    /// topic's real address (`loadHTMLString` with that base URL). Letter
    /// avatars and invented usernames, as in the extension's mock pages.
    func topicPageHTML(forum: ForumText, title: String, page: Page) -> String {
        let colors = ["#7b4fb8", "#2a8f8a", "#c9722a", "#3a78c9", "#4d8f3a", "#b8456a"]
        let isMeta = forum.siteURL == meta.siteURL
        let logo = isMeta ? "#4f2a8a" : "#8a8423"
        let category = isMeta ? "#25aae2" : "#0e76bd"
        var written: [Int: PagePost] = [:]
        for (index, post) in page.posts.enumerated() { written[post.number ?? index + 1] = post }
        let fillerUsers = ["tidepool", "sparrow_9", "cobalt_owl", "fernwood"]
        var time = ""
        let posts = (1...max(page.length, written.keys.max() ?? 1)).map { number in
            let post = written[number] ?? PagePost(
                user: fillerUsers[number % fillerUsers.count], time: time,
                body: [fillerReplies[number % fillerReplies.count]], likes: number % 5
            )
            time = post.time
            let badge = post.badge.map { "<span class=\"badge\">\($0)</span>" } ?? ""
            let body = post.body.map { "<p>\($0)</p>" }.joined()
            let color = colors[(number - 1 + (isMeta ? 0 : 3)) % colors.count]
            // Discourse's markup, as the page scripts read it (DiscourseDOM.swift).
            return """
            <div class="topic-post" data-post-number="\(number)"><article id="post_\(number)">
            <div class="av" style="background:\(color)">\(post.user.prefix(1).uppercased())</div>
            <div class="post"><div class="who"><a data-user-card="\(post.user)"><b>\(post.user)</b></a>\(badge)<span class="time">\(post.time)</span></div>
            <div class="cooked">\(body)</div><div class="acts"><span>♡ \(post.likes)</span><span>\(replyLabel)</span></div></div></article></div>
            """
        }.joined()
        let tags = page.tags.map { "<span class=\"tag\">\($0)</span>" }.joined()
        return """
        <!doctype html><html lang="\(language)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>\(title) - \(forum.name)</title>
        <style>
        body{margin:0;font:17px/1.5 -apple-system,system-ui,sans-serif;color:#222;background:#fff}
        header{display:flex;align-items:center;gap:10px;padding:12px 16px;border-bottom:1px solid #e9e9e9}
        .logo{width:34px;height:34px;border-radius:8px;background:\(logo);color:#fff;font-weight:700;display:grid;place-items:center}
        header b{font-size:19px;flex:1}
        header i{width:20px;height:20px;border:2px solid #999;border-radius:50%;opacity:.7}
        main{padding:16px}
        h1{font-size:24px;line-height:1.25;margin:4px 0 8px}
        .meta{display:flex;flex-wrap:wrap;gap:8px;align-items:center;font-size:14px;color:#555;margin-bottom:12px}
        .cat:before{content:"";display:inline-block;width:10px;height:10px;background:\(category);margin-right:6px}
        .tag{background:#f0f0f0;border-radius:4px;padding:1px 7px}
        article{display:flex;gap:12px;padding:14px 0;border-top:1px solid #eee}
        a{color:inherit;text-decoration:none}
        .av{flex:none;width:44px;height:44px;border-radius:50%;color:#fff;font-weight:600;display:grid;place-items:center}
        .post{flex:1;min-width:0}
        .who{display:flex;align-items:center;gap:6px;font-size:15px}
        .badge{background:#5f6f80;color:#fff;font-size:11px;border-radius:3px;padding:1px 5px}
        .time{margin-left:auto;color:#888;font-size:14px}
        p{margin:6px 0}
        code{background:#f2f2f2;border-radius:3px;padding:0 4px;font-size:15px}
        .acts{display:flex;justify-content:flex-end;gap:18px;color:#888;font-size:14px}
        </style></head><body>
        <header class="d-header"><span class="logo">\(forum.name.prefix(1))</span><b>\(forum.name)</b><i></i></header>
        <main><h1>\(title)</h1><div class="meta"><span class="cat">\(page.category)</span>\(tags)</div>\(posts)</main>
        </body></html>
        """
    }
}

// MARK: - English

extension SampleContent {
    static let english = SampleContent(
        tipsTitle: "New user tips: read this before your first post",
        notificationsTitle: "Category-specific notification defaults",
        workingOnTitle: "What are you working on? (2026 edition)",
        streamingTitle: "Streaming function calls with the Responses API",
        rateLimitErrorsTitle: "Rate limit errors only during streamed tool calls",
        backoffGuideTitle: "Guide: exponential backoff with Retry-After",
        batchingTitle: "Batching several tool calls in one turn",
        higherLimitTitle: "How to request a higher rate limit",
        longThreadsTitle: "Best practices for long-running assistant threads",
        tipsSummary: """
        ## Original post
        A staff post collecting the questions new members ask most often: how **trust levels** work, \
        why links are limited at first, and where to find the community guidelines #1.

        ## What people are saying
        - **Trust levels** cause the most confusion: several people thought their account was broken \
        when a second link was blocked #2 #7.
        - **Flags** are reviewed by the community, not only by staff, a moderator explains #3 #12.
        - **Admins** share plugins that build on the default trust-level rules #9.

        ## Key takeaways
        1. New accounts are limited on purpose: it stops spam, not genuine new members #1.
        2. Trust level 1 unlocks after a little reading, no application needed #14.
        """,
        tipsChat: [
            (.user, "Why can’t I post more than two links yet?"),
            (.assistant, "New accounts (trust level 0) are limited to two links per post. It’s a **spam guard**, not a bug, and it lifts automatically at trust level 1 #1."),
            (.user, "How long does that usually take?"),
            (.assistant, "For most people, a day or two of normal reading and a few genuine replies #14. There’s no application or waiting queue.")
        ],
        notificationsSummary: "## Summary\nAdmins can set default notification levels per category; the defaults apply to new users and can be applied to existing ones too.",
        workingOnSummary: "## Summary\nSite owners share what they’re building this year: theme components, automations, and migrations from older forums.",
        streamingSummary: """
        ## Original post
        When a tool call arrives mid-stream, the client gets a **429** right after it retries, \
        even with a fixed one-second delay #1.

        ## What people suggest
        - Back off from the **`Retry-After`** header instead of a fixed delay #2.
        - **Batch tool calls**: each call counts toward the same per-minute limit #3.
        - For steady traffic, ask for a higher limit rather than retrying harder #9.

        ## Status
        The original poster confirmed that backing off from `Retry-After` fixed it #11.
        """,
        streamingChat: [
            (.user, "What delay does Retry-After usually give?"),
            (.assistant, "A few seconds in the examples posted #2 #5. Replies suggest waiting **at least** that long, then doubling the wait on each retry.")
        ],
        rateLimitErrorsSummary: "## Summary\n429s appear when a tool call arrives mid-stream and the client retries at once; backing off from Retry-After fixes it.",
        longThreadsSummary: "## Summary\nKeep a short running summary and send only the last few turns in full; archive old threads on your side.",
        agentGoal: "How are people handling rate limits during streaming?",
        agentSearchQuery: "streaming rate limit 429",
        agentSecondSearchQuery: "Retry-After backoff streaming",
        agentThoughts: [
            "Start with the most direct wording of the question.",
            "The best match for the error itself.",
            "A guide that explains the usual fix.",
            "People may describe the fix instead of the error.",
            "Batching came up in two results.",
            "For steady, high-volume apps the question is whether to ask for more.",
            "Enough to answer."
        ],
        agentRunningStatus: "Searching “Retry-After backoff streaming”…",
        agentAnswer: { s1, s2, s3, s4 in
            """
            Most 429s during streaming come from **retrying too fast**: a failed stream triggers an \
            immediate new request, as reported in [Rate limit errors only during streamed tool calls](\(s1)). The fix people report most is \
            **exponential backoff** from the `Retry-After` header instead of a fixed delay, \
            as in [Guide: exponential backoff with Retry-After](\(s2)).

            Several threads also suggest **batching tool calls**, because every call in a streamed turn \
            counts toward the same per-minute limit: see [Batching several tool calls in one turn](\(s3)). For steady, high-volume apps, \
            people recommend asking for more: [How to request a higher rate limit](\(s4)).
            """
        },
        agentFollowUpQuestion: "Does batching help if I only make one call per turn?",
        agentFollowUpAnswer: "Not much. Batching helps when a turn makes several calls; with one call, backing off from `Retry-After` is what matters.",
        olderGoal: "How do trust levels work for new members?",
        olderSearchQuery: "trust level new user limits",
        olderAnswer: "New accounts start at **trust level 0** and move up by reading, replying and receiving likes. Nothing to apply for.",
        summaryRunningStatus: "Summarizing posts 41–60 of 88…",
        summaryStream: """
        ## Original post
        A staff post collecting the questions new members ask most often: how **trust levels** work.

        ## What people are saying
        - **Trust levels** cause the most confusion
        """,
        digestBlurbs: [
            "Since you last looked, five new replies ask how long trust level 1 takes. A staff reply says a day or two of normal reading is usually enough.",
            "Retrying right after a 429 makes it worse. The accepted answer backs off from the Retry-After header, and two people confirm it stops the errors.",
            "Most replies keep a short running summary and send only the last few turns in full. Two people share how often they refresh it."
        ],
        tipsPage: Page(category: "Community", tags: ["faq", "trust-levels"], length: 30, posts: [
            PagePost(user: "forum_team", badge: "Staff", time: "Sep 2023", body: [
                "Welcome! Here are answers to the questions new members ask most often.",
                "<b>Why can’t I post links or images yet?</b> New accounts start at trust level 0, which limits links per post. It’s a spam guard, and it lifts automatically after you read a few topics.",
                "<b>How do trust levels work?</b> You move up by reading, replying, and receiving likes. There is nothing to apply for."
            ], likes: 214),
            PagePost(user: "pixelpenguin", time: "Oct 2023", body: [
                "This cleared up a lot for me. I thought my account was broken when my second link was blocked!"
            ], likes: 36),
            PagePost(user: "trailrunner42", time: "Nov 2023", body: [
                "Is flagging only for moderators, or can regular members review flags too?"
            ], likes: 18),
            PagePost(number: 7, user: "quietfern", time: "Nov 2023", body: [
                "Same here! I thought I’d been banned when my second link disappeared."
            ], likes: 12),
            PagePost(number: 9, user: "mossy_admin", time: "Dec 2023", body: [
                "On our forum a small plugin sends new members a welcome message that explains trust levels. Far fewer confused posts since."
            ], likes: 21),
            PagePost(number: 12, user: "lantern_mod", badge: "Moderator", time: "Jan 2024", body: [
                "Flags go to the review queue, and members at higher trust levels help handle them, not only staff."
            ], likes: 30),
            PagePost(number: 14, user: "dune_walker", time: "Feb 2024", body: [
                "For me it took a day or two of reading and a couple of replies. No form, it just happened."
            ], likes: 15)
        ]),
        streamingPage: Page(category: "API", tags: ["streaming", "rate-limits"], length: 13, posts: [
            PagePost(user: "async_otter", time: "Aug 28", body: [
                "When a tool call arrives mid-stream, my client sometimes gets a 429 right after it retries. Is there a recommended way to handle rate limits while streaming?",
                "I’m retrying after a fixed one-second delay, which doesn’t seem to help much."
            ], likes: 24),
            PagePost(user: "byte_gardener", time: "Aug 28", body: [
                "Read the <code>Retry-After</code> header and back off from that value instead of a fixed delay. That fixed it for us."
            ], likes: 17),
            PagePost(user: "null_island", time: "Aug 29", body: [
                "Same issue here. Batching tool calls also helped, since each call counts toward the same limit."
            ], likes: 9),
            PagePost(number: 9, user: "glacier_dev", time: "Sep 2", body: [
                "If your traffic is steady, request a higher limit. Backoff only spreads the same load out."
            ], likes: 11),
            PagePost(number: 11, user: "async_otter", time: "Sep 3", body: [
                "Switched to backing off from <code>Retry-After</code> and the 429s are gone. Thanks, everyone!"
            ], likes: 14)
        ]),
        fillerReplies: ["Thanks, this answered my question.", "Bookmarking this for later.", "Helpful, thank you!", "Same question here."],
        replyLabel: "Reply",
        language: "en"
    )
}

// MARK: - Simplified Chinese

extension SampleContent {
    static let simplifiedChinese = SampleContent(
        tipsTitle: "新手须知：发第一帖之前请先读这里",
        notificationsTitle: "按分类设置默认通知级别",
        workingOnTitle: "你最近在做什么？（2026 年版）",
        streamingTitle: "用 Responses API 流式调用函数",
        rateLimitErrorsTitle: "只有在流式工具调用时才出现限流错误",
        backoffGuideTitle: "指南：根据 Retry-After 做指数退避",
        batchingTitle: "在一个回合里合并多个工具调用",
        higherLimitTitle: "如何申请更高的速率限制",
        longThreadsTitle: "长期运行的助手对话有哪些最佳实践？",
        tipsSummary: """
        ## 原帖
        一篇官方帖子，整理了新用户最常问的问题：**信任等级**是怎么回事、为什么一开始能发的链接有限，\
        以及去哪里看社区准则 #1。

        ## 大家怎么说
        - **信任等级**最让人困惑：不少人第二个链接被拦下时，还以为是账号出了问题 #2 #7。
        - 一位版主解释，**举报**由整个社区一起审核，不只是管理人员 #3 #12。
        - 几位**站长**分享了在默认信任等级机制上扩展的插件 #9。

        ## 关键要点
        1. 新账号受限是有意为之：挡住的是垃圾信息，而不是真正的新成员 #1。
        2. 稍微浏览一下就能升到信任等级 1，不用申请 #14。
        """,
        tipsChat: [
            (.user, "为什么我现在一帖里还不能放两个以上的链接？"),
            (.assistant, "新账号（信任等级 0）每帖最多只能放两个链接。这是**防垃圾信息的措施**，不是 bug，升到信任等级 1 后会自动解除 #1。"),
            (.user, "哪一层楼说了升级要多久？"),
            (.assistant, "第 14 楼：正常浏览一两天、认真回复几次就升级了 #14。不用申请，也不用排队。")
        ],
        notificationsSummary: "## 摘要\n管理员可以为每个分类设置默认通知级别；默认值适用于新用户，也可以同步到现有用户。",
        workingOnSummary: "## 摘要\n站长们分享今年在做的东西：主题组件、自动化，以及从旧论坛迁移过来的经验。",
        streamingSummary: """
        ## 原帖
        流式输出中途来了工具调用时，客户端重试后马上就收到 **429**，即使固定等一秒再重试也一样 #1。

        ## 大家的建议
        - 从 **`Retry-After`** 响应头给出的时间开始退避，别用固定延迟 #2。
        - **合并工具调用**：每次调用都计入同一个每分钟额度 #3。
        - 流量稳定的话，申请更高的额度，而不是更用力地重试 #9。

        ## 进展
        楼主确认，按 `Retry-After` 退避之后问题解决了 #11。
        """,
        streamingChat: [
            (.user, "Retry-After 一般会给多长时间？"),
            (.assistant, "帖子里贴出的例子都是几秒钟 #2 #5。回复建议**至少**等这么久，之后每次重试把等待时间翻倍。")
        ],
        rateLimitErrorsSummary: "## 摘要\n流式输出中途发生工具调用、客户端又立刻重试时会出现 429；按 Retry-After 退避就能解决。",
        longThreadsSummary: "## 摘要\n保留一份简短的滚动摘要，只完整发送最近几轮；旧对话在自己这边归档。",
        agentGoal: "大家在流式输出时是怎么处理限流的？",
        agentSearchQuery: "流式 限流 429",
        agentSecondSearchQuery: "Retry-After 退避 流式",
        agentThoughts: [
            "先用最直接的说法搜索这个问题。",
            "和报错本身最吻合的话题。",
            "一篇讲常用解决办法的指南。",
            "大家描述的可能是解决办法，而不是报错本身。",
            "两条搜索结果都提到了合并调用。",
            "对流量稳定且较大的应用来说，问题在于要不要申请更高的额度。",
            "信息已经足够回答了。"
        ],
        agentRunningStatus: "正在搜索“Retry-After 退避 流式”…",
        agentAnswer: { s1, s2, s3, s4 in
            """
            流式输出时的 429 错误，大多是因为**重试太快**：一次流式请求失败后，客户端立刻又发起了新请求，\
            [只有在流式工具调用时才出现限流错误](\(s1))里有详细描述。大家最常用的解决办法是从 `Retry-After` 响应头给出的时间开始做\
            **指数退避**，而不是固定等待，[指南：根据 Retry-After 做指数退避](\(s2))讲得很清楚。

            好几个帖子还建议**合并工具调用**，因为一个流式回合里的每次调用都计入同一个每分钟额度\
            （见[在一个回合里合并多个工具调用](\(s3))）。对于流量稳定且较大的应用，大家建议申请更高的额度，见[如何申请更高的速率限制](\(s4))。
            """
        },
        agentFollowUpQuestion: "如果每个回合只调用一次，合并还有用吗？",
        agentFollowUpAnswer: "用处不大。一个回合有多次调用时合并才有帮助；只调用一次的话，关键是按 `Retry-After` 退避。",
        olderGoal: "新成员的信任等级是怎么回事？",
        olderSearchQuery: "信任等级 新用户 限制",
        olderAnswer: "新账号从**信任等级 0** 开始，浏览、回复和收到点赞都会让你升级，不需要申请。",
        summaryRunningStatus: "正在总结第 41–60 楼（共 88 楼）…",
        summaryStream: """
        ## 原帖
        一篇官方帖子，整理了新用户最常问的问题：**信任等级**是怎么回事。

        ## 大家怎么说
        - **信任等级**最让人困惑
        """,
        digestBlurbs: [
            "自你上次查看以来，有五条新回复在问多久能升到信任等级 1。管理人员回复说，正常浏览一两天通常就够了。",
            "收到 429 后立刻重试只会更糟。采纳的答案按 Retry-After 响应头退避，已有两人确认错误不再出现。",
            "多数回复建议保留一份简短的滚动摘要，只完整发送最近几轮。有两人分享了他们多久更新一次。"
        ],
        tipsPage: Page(category: "社区", tags: ["常见问题", "信任等级"], length: 30, posts: [
            PagePost(user: "forum_team", badge: "管理人员", time: "2023 年 9 月", body: [
                "欢迎！这里整理了新成员最常问的问题。",
                "<b>为什么我还不能发链接或图片？</b>新账号从信任等级 0 开始，每帖能放的链接有限。这是为了防垃圾信息，看过几个话题后就会自动解除。",
                "<b>信任等级是怎么回事？</b>浏览、回复和收到点赞都会让你升级，不需要申请。"
            ], likes: 214),
            PagePost(user: "pixelpenguin", time: "2023 年 10 月", body: [
                "终于搞明白了！第二个链接被拦下的时候，我还以为是账号出问题了。"
            ], likes: 36),
            PagePost(user: "trailrunner42", time: "2023 年 11 月", body: [
                "举报只有版主能处理吗？普通成员也能参与审核吗？"
            ], likes: 18),
            PagePost(number: 7, user: "quietfern", time: "2023 年 11 月", body: [
                "我也是！第二个链接不见的时候，我还以为自己被封号了。"
            ], likes: 12),
            PagePost(number: 9, user: "mossy_admin", time: "2023 年 12 月", body: [
                "我们论坛用了一个小插件，给新成员发一条欢迎消息，解释信任等级。之后一头雾水的帖子少多了。"
            ], likes: 21),
            PagePost(number: 12, user: "lantern_mod", badge: "版主", time: "2024 年 1 月", body: [
                "举报会进入审核队列，信任等级较高的成员也会帮忙处理，不只是管理人员。"
            ], likes: 30),
            PagePost(number: 14, user: "dune_walker", time: "2024 年 2 月", body: [
                "我大概浏览了一两天、回复了几次就升级了。不用填表，自动就升了。"
            ], likes: 15)
        ]),
        streamingPage: Page(category: "API", tags: ["流式", "限流"], length: 13, posts: [
            PagePost(user: "async_otter", time: "8 月 28 日", body: [
                "流式输出中途来了工具调用时，我的客户端重试后有时马上就收到 429。流式输出时有没有推荐的限流处理方式？",
                "我现在是固定等一秒再重试，好像没什么用。"
            ], likes: 24),
            PagePost(user: "byte_gardener", time: "8 月 28 日", body: [
                "读取 <code>Retry-After</code> 响应头，从这个值开始退避，别用固定延迟。我们就是这样解决的。"
            ], likes: 17),
            PagePost(user: "null_island", time: "8 月 29 日", body: [
                "我也遇到过。合并工具调用也有帮助，因为每次调用都计入同一个额度。"
            ], likes: 9),
            PagePost(number: 9, user: "glacier_dev", time: "9 月 2 日", body: [
                "如果流量比较稳定，就申请更高的额度。退避只是把同样的负载摊开而已。"
            ], likes: 11),
            PagePost(number: 11, user: "async_otter", time: "9 月 3 日", body: [
                "改成按 <code>Retry-After</code> 退避之后，429 没有了。谢谢大家！"
            ], likes: 14)
        ]),
        fillerReplies: ["谢谢，正好解答了我的问题。", "先收藏，回头再看。", "很有帮助，谢谢！", "我也有同样的问题。"],
        replyLabel: "回复",
        language: "zh-Hans"
    )
}

// MARK: - Traditional Chinese

extension SampleContent {
    static let traditionalChinese = SampleContent(
        tipsTitle: "新手須知：發第一篇文章之前請先讀這裡",
        notificationsTitle: "按分類設定預設通知級別",
        workingOnTitle: "你最近在做什麼？（2026 年版）",
        streamingTitle: "用 Responses API 串流呼叫函式",
        rateLimitErrorsTitle: "只有在串流工具呼叫時才出現速率限制錯誤",
        backoffGuideTitle: "指南：根據 Retry-After 做指數退避",
        batchingTitle: "在一個回合裡合併多個工具呼叫",
        higherLimitTitle: "如何申請更高的速率限制",
        longThreadsTitle: "長時間運作的助理對話有哪些最佳做法？",
        tipsSummary: """
        ## 原始貼文
        一篇官方貼文，整理了新使用者最常問的問題：**信任等級**是怎麼回事、為什麼一開始能發的連結有限，\
        以及去哪裡看社群準則 #1。

        ## 大家怎麼說
        - **信任等級**最讓人困惑：不少人第二個連結被攔下時，還以為是帳號出了問題 #2 #7。
        - 一位版主解釋，**檢舉**由整個社群一起審核，不只是管理人員 #3 #12。
        - 幾位**站長**分享了在預設信任等級機制上擴充的外掛 #9。

        ## 關鍵要點
        1. 新帳號受限是有意為之：擋住的是垃圾訊息，而不是真正的新成員 #1。
        2. 稍微瀏覽一下就能升到信任等級 1，不用申請 #14。
        """,
        tipsChat: [
            (.user, "為什麼我現在一篇貼文裡還不能放兩個以上的連結？"),
            (.assistant, "新帳號（信任等級 0）每篇貼文最多只能放兩個連結。這是**防垃圾訊息的措施**，不是 bug，升到信任等級 1 後會自動解除 #1。"),
            (.user, "哪一樓有說升級要多久？"),
            (.assistant, "14 樓：正常瀏覽一兩天、認真回覆幾次就升級了 #14。不用申請，也不用排隊。")
        ],
        notificationsSummary: "## 摘要\n管理員可以為每個分類設定預設通知級別；預設值適用於新使用者，也可以套用到現有使用者。",
        workingOnSummary: "## 摘要\n站長們分享今年在做的東西：佈景主題元件、自動化，以及從舊論壇遷移過來的經驗。",
        streamingSummary: """
        ## 原始貼文
        串流輸出中途來了工具呼叫時，用戶端重試後馬上就收到 **429**，即使固定等一秒再重試也一樣 #1。

        ## 大家的建議
        - 從 **`Retry-After`** 回應標頭給出的時間開始退避，別用固定延遲 #2。
        - **合併工具呼叫**：每次呼叫都計入同一個每分鐘額度 #3。
        - 流量穩定的話，申請更高的額度，而不是更用力地重試 #9。

        ## 進展
        原 PO 確認，按 `Retry-After` 退避之後問題解決了 #11。
        """,
        streamingChat: [
            (.user, "Retry-After 一般會給多長時間？"),
            (.assistant, "貼文裡貼出的例子都是幾秒鐘 #2 #5。回覆建議**至少**等這麼久，之後每次重試把等待時間加倍。")
        ],
        rateLimitErrorsSummary: "## 摘要\n串流輸出中途發生工具呼叫、用戶端又立刻重試時會出現 429；按 Retry-After 退避就能解決。",
        longThreadsSummary: "## 摘要\n保留一份簡短的滾動摘要，只完整傳送最近幾輪；舊對話在自己這邊歸檔。",
        agentGoal: "大家在串流輸出時是怎麼處理速率限制的？",
        agentSearchQuery: "串流 速率限制 429",
        agentSecondSearchQuery: "Retry-After 退避 串流",
        agentThoughts: [
            "先用最直接的說法搜尋這個問題。",
            "和錯誤本身最吻合的話題。",
            "一篇講常用解決辦法的指南。",
            "大家描述的可能是解決辦法，而不是錯誤本身。",
            "兩筆搜尋結果都提到了合併呼叫。",
            "對流量穩定且較大的應用程式來說，問題在於要不要申請更高的額度。",
            "資訊已經足夠回答了。"
        ],
        agentRunningStatus: "正在搜尋「Retry-After 退避 串流」…",
        agentAnswer: { s1, s2, s3, s4 in
            """
            串流輸出時的 429 錯誤，大多是因為**重試太快**：一次串流請求失敗後，用戶端立刻又發起了新請求，\
            [只有在串流工具呼叫時才出現速率限制錯誤](\(s1))裡有詳細描述。大家最常用的解決辦法是從 `Retry-After` 回應標頭給出的時間開始做\
            **指數退避**，而不是固定等待，[指南：根據 Retry-After 做指數退避](\(s2))講得很清楚。

            好幾篇貼文還建議**合併工具呼叫**，因為一個串流回合裡的每次呼叫都計入同一個每分鐘額度\
            （見[在一個回合裡合併多個工具呼叫](\(s3))）。對於流量穩定且較大的應用程式，大家建議申請更高的額度，見[如何申請更高的速率限制](\(s4))。
            """
        },
        agentFollowUpQuestion: "如果每個回合只呼叫一次，合併還有用嗎？",
        agentFollowUpAnswer: "用處不大。一個回合有多次呼叫時合併才有幫助；只呼叫一次的話，關鍵是按 `Retry-After` 退避。",
        olderGoal: "新成員的信任等級是怎麼回事？",
        olderSearchQuery: "信任等級 新使用者 限制",
        olderAnswer: "新帳號從**信任等級 0** 開始，瀏覽、回覆和收到按讚都會讓你升級，不需要申請。",
        summaryRunningStatus: "正在摘要第 41–60 樓（共 88 樓）…",
        summaryStream: """
        ## 原始貼文
        一篇官方貼文，整理了新使用者最常問的問題：**信任等級**是怎麼回事。

        ## 大家怎麼說
        - **信任等級**最讓人困惑
        """,
        digestBlurbs: [
            "自你上次查看以來，有五則新回覆在問多久能升到信任等級 1。管理人員回覆說，正常瀏覽一兩天通常就夠了。",
            "收到 429 後立刻重試只會更糟。採納的答案按 Retry-After 回應標頭退避，已有兩人確認錯誤不再出現。",
            "多數回覆建議保留一份簡短的滾動摘要，只完整傳送最近幾輪。有兩人分享了他們多久更新一次。"
        ],
        tipsPage: Page(category: "社群", tags: ["常見問題", "信任等級"], length: 30, posts: [
            PagePost(user: "forum_team", badge: "管理人員", time: "2023 年 9 月", body: [
                "歡迎！這裡整理了新成員最常問的問題。",
                "<b>為什麼我還不能發連結或圖片？</b>新帳號從信任等級 0 開始，每篇貼文能放的連結有限。這是為了防垃圾訊息，看過幾個話題後就會自動解除。",
                "<b>信任等級是怎麼回事？</b>瀏覽、回覆和收到按讚都會讓你升級，不需要申請。"
            ], likes: 214),
            PagePost(user: "pixelpenguin", time: "2023 年 10 月", body: [
                "終於弄懂了！第二個連結被攔下的時候，我還以為是帳號出問題了。"
            ], likes: 36),
            PagePost(user: "trailrunner42", time: "2023 年 11 月", body: [
                "檢舉只有版主能處理嗎？一般成員也能參與審核嗎？"
            ], likes: 18),
            PagePost(number: 7, user: "quietfern", time: "2023 年 11 月", body: [
                "我也是！第二個連結不見的時候，我還以為自己被停權了。"
            ], likes: 12),
            PagePost(number: 9, user: "mossy_admin", time: "2023 年 12 月", body: [
                "我們論壇用了一個小外掛，給新成員發一則歡迎訊息，解釋信任等級。之後一頭霧水的貼文少多了。"
            ], likes: 21),
            PagePost(number: 12, user: "lantern_mod", badge: "版主", time: "2024 年 1 月", body: [
                "檢舉會進入審核佇列，信任等級較高的成員也會幫忙處理，不只是管理人員。"
            ], likes: 30),
            PagePost(number: 14, user: "dune_walker", time: "2024 年 2 月", body: [
                "我大概瀏覽了一兩天、回覆了幾次就升級了。不用填表，自動就升了。"
            ], likes: 15)
        ]),
        streamingPage: Page(category: "API", tags: ["串流", "速率限制"], length: 13, posts: [
            PagePost(user: "async_otter", time: "8 月 28 日", body: [
                "串流輸出中途來了工具呼叫時，我的用戶端重試後有時馬上就收到 429。串流輸出時有沒有建議的速率限制處理方式？",
                "我現在是固定等一秒再重試，好像沒什麼用。"
            ], likes: 24),
            PagePost(user: "byte_gardener", time: "8 月 28 日", body: [
                "讀取 <code>Retry-After</code> 回應標頭，從這個值開始退避，別用固定延遲。我們就是這樣解決的。"
            ], likes: 17),
            PagePost(user: "null_island", time: "8 月 29 日", body: [
                "我也遇到過。合併工具呼叫也有幫助，因為每次呼叫都計入同一個額度。"
            ], likes: 9),
            PagePost(number: 9, user: "glacier_dev", time: "9 月 2 日", body: [
                "如果流量比較穩定，就申請更高的額度。退避只是把同樣的負載攤開而已。"
            ], likes: 11),
            PagePost(number: 11, user: "async_otter", time: "9 月 3 日", body: [
                "改成按 <code>Retry-After</code> 退避之後，429 沒有了。謝謝大家！"
            ], likes: 14)
        ]),
        fillerReplies: ["謝謝，剛好解答了我的問題。", "先收藏，之後再看。", "很有幫助，謝謝！", "我也有同樣的問題。"],
        replyLabel: "回覆",
        language: "zh-Hant"
    )
}
#endif
