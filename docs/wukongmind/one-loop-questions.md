# One loop comparison: fixture forums and question set

Owner gate 1 for [design-one-loop.md](design-one-loop.md#comparison-test): 15 questions (5 per forum kind) and one public forum per kind. Task 8 records both loops only after the owner confirms this set.

## Proposed fixture forums

| Kind | Forum | Site URL | Starting home URL | Why this forum |
|---|---|---|---|---|
| `discourse` | 小众软件论坛 (Appinn Meta) | `https://meta.appinn.net` | `https://meta.appinn.net/` | Chinese-language Discourse instance. Its JSON (`/latest.json`, `/t/<id>.json`, `/search.json`) and `/raw/<id>` are readable logged out with no Cloudflare challenge (checked with plain curl, see the proof). It has `#category`, `status:solved` and `after:` search, a 338-post thread, and a daily stream of new threads. Chosen after uscardforum.com (美卡论坛) and linux.do returned a Cloudflare challenge (403) to logged-out clients. |
| `hackernews` | Hacker News | `https://news.ycombinator.com` | `https://news.ycombinator.com/` | Public stories and nested comment trees served via `news.ycombinator.com` and `hn.algolia.com`. |
| `wordpress` | Doctor Of Credit | `https://www.doctorofcredit.com` | `https://www.doctorofcredit.com/` | Public WordPress blog with open `/wp-json/wp/v2/{posts,comments,categories}`, `X-WP-Total` headers, and active reader comment threads. |

**Thread URLs.** Old Research receives only `goal` and `siteURL` (no current page), so every thread question names the thread title and canonical URL in its prompt text and both loops receive the exact same string. WordPress thread questions use canonical `?p=<id>` URLs (`WordPressLinks.topicURL` / `WordPressRecognizer.topicID(fromURL:)`) because WordPress slug permalinks omit the numeric post ID.

**Revision (WUKO-58, owner changes).** Discourse Meta became 小众软件论坛 with five Chinese questions (the owner's first choice, uscardforum.com, sits behind a Cloudflare challenge); only D3 keeps the "point 2" form, H3 and W3 name their follow-up topic; W4 is now an unanswerable question; H1 and W1 are Chinese with thread titles and links left in the original language. The Doctor Of Credit REST title of `?p=229112` is the one quoted in W2 (the HTML page title is the shorter "$100 back on your $600 Chase Travel purchase").

---

## Discourse — 小众软件论坛 (`https://meta.appinn.net`)

All five questions are asked in Chinese. Every thread below is public and loads logged out (HTTP 200).

- **D1 · Site-wide opinion**
  - **Starting page:** `https://meta.appinn.net/`
  - **Exercises:** `search_forum`, reading several threads across categories, citations
  - **Prompt:** `这里的网友怎么看家用 NAS（比如群晖）值不值得买？`

- **D2 · Fact inside one long thread**
  - **Starting page:** `https://meta.appinn.net/t/87128`
  - **Exercises:** `read_topic` over a long thread (338 posts, raw text ~35 KB for the first 100), `query` / `page`, workspace file fallback, post citations
  - **Prompt:** `在帖子「SumatraPDF Plus 增强版：完美中文排版、全渲染暗黑模式、双击查词、大文件加速」（https://meta.appinn.net/t/87128）里，有网友建议作者参考哪个暗黑主题，另一位网友更喜欢哪种黑色，作者又是怎么回应的？`

- **D3 · Multi-step (the one kept in the "point 2" form)**
  - **Starting page:** `https://meta.appinn.net/t/18527`
  - **Exercises:** `summarize_topic`, then `search_forum` across other threads
  - **Prompt:** `请总结帖子「全平台剪贴板推送与同步方案合集」（https://meta.appinn.net/t/18527），然后找找这里其他人怎么看第 2 点。`
  - **Note:** the thread's second top-level section is "2. 剪贴板同步工具", so "第 2 点" is well defined.

- **D4 · Latest**
  - **Starting page:** `https://meta.appinn.net/`
  - **Exercises:** `list_latest`, selecting and citing notable active threads
  - **Prompt:** `今天论坛里有什么值得一读的？`

- **D5 · Kind-specific (category, solved, and date filter)**
  - **Starting page:** `https://meta.appinn.net/`
  - **Exercises:** `search_forum` syntax (`#wen-ti-qiu-zhu` = 问题求助, `status:solved`, `after:YYYY-MM-DD`)
  - **Prompt:** `在「问题求助」分类里，2026-01-01 以来已解决的帖子中，群晖 NAS 用户遇到过哪些问题，是怎么解决的？`

---

## Hacker News (`https://news.ycombinator.com`)

- **H1 · Site-wide opinion (Chinese question)**
  - **Starting page:** `https://news.ycombinator.com/`
  - **Exercises:** `search_forum`, reading multiple story discussions, citations
  - **Prompt:** `这里的人怎么看用 Intel N100 迷你主机做家用服务器？`

- **H2 · Fact inside one long thread**
  - **Starting page:** `https://news.ycombinator.com/item?id=47637353`
  - **Exercises:** `read_topic` over a ~38 KB nested thread (129 comments), `query` / `page`, workspace file fallback
  - **Prompt:** `In the thread "SQLite in Production: Lessons from Running a Store on a Single File" (https://news.ycombinator.com/item?id=47637353), why did concurrent database exec queries during a deploy trigger the OOM killer on their t3.small machine, and what GitHub Actions feature does a commenter recommend instead of CLAUDE.md deploy rules?`

- **H3 · Multi-step (explicit follow-up topic)**
  - **Starting page:** `https://news.ycombinator.com/item?id=44809166`
  - **Exercises:** `summarize_topic`, then `search_forum` / `search_comments`
  - **Prompt:** `Summarize the thread "How I use Tailscale" (https://news.ycombinator.com/item?id=44809166), then find what others here say about exposing a service with `tailscale funnel`.`

- **H4 · Latest**
  - **Starting page:** `https://news.ycombinator.com/`
  - **Exercises:** `list_latest`, reading and citing current stories
  - **Prompt:** `What's worth reading today on Hacker News?`

- **H5 · Kind-specific (comment search)**
  - **Starting page:** `https://news.ycombinator.com/`
  - **Exercises:** `search_comments`, reading parent stories for citable context
  - **Prompt:** `What do commenters here say about running Litestream for SQLite backups in production?`

---

## WordPress — Doctor Of Credit (`https://www.doctorofcredit.com`)

- **W1 · Site-wide opinion (Chinese question)**
  - **Starting page:** `https://www.doctorofcredit.com/`
  - **Exercises:** `search_forum`, reading several posts and reader discussions, citations
  - **Prompt:** `这里的文章和读者怎么看 US Bank Smartly Visa 卡改版后的变化？`

- **W2 · Fact inside one long thread**
  - **Starting page:** `https://www.doctorofcredit.com/?p=229112`
  - **Exercises:** `read_topic` over a ~58 KB post (316 comments across 4 comment pages), `query` / `page`, workspace file fallback
  - **Prompt:** `In the post "[Targeted] Chase Travel: Spend $600+ & Receive $100 Back" (https://www.doctorofcredit.com/?p=229112), does checking out multiple separate hotel bookings together in one Chase Travel cart count as a single transaction to trigger the $100 credit?`

- **W3 · Multi-step (explicit follow-up topic)**
  - **Starting page:** `https://www.doctorofcredit.com/?p=268506`
  - **Exercises:** `summarize_topic`, then `search_forum` / `search_comments`
  - **Prompt:** `Summarize the post "Year-End Credit Card Checklist for 2026: Travel Credits, Spend Reset, Application Strategy & More" (https://www.doctorofcredit.com/?p=268506), then find what others here say about the year-end double-dip strategy for the Amex Platinum, Citi Strata Elite and Bank of America Premium Rewards Elite cards.`

- **W4 · Unanswerable (replaces "What's worth reading today")**
  - **Starting page:** `https://www.doctorofcredit.com/`
  - **Exercises:** `search_forum`, reading related posts, then saying honestly that the forum has no answer (no invented citation)
  - **Prompt:** `Which credit card will offer the biggest sign-up bonus in 2027?`
  - **Expected outcome:** the forum has no settled answer, because it is about future offers nobody has announced. Both loops should say so and may point to related current offers, but must not name a winner.

- **W5 · Kind-specific (comment search with date filter)**
  - **Starting page:** `https://www.doctorofcredit.com/`
  - **Exercises:** `search_comments` with `after`, then `read_topic` on matching posts
  - **Prompt:** `What do commenters here say since 2026-01-01 about getting Chase Ink business cards approved as a sole proprietor?`

---

## Owner gate 1

Confirmed by the owner on YYYY-MM-DD: pending (owner gate 1; confirmed on WUKO-52's Accept card before task 8 records)
