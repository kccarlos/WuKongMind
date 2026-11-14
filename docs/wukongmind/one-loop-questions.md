# One loop comparison: fixture forums and question set

Owner gate 1 for [design-one-loop.md](design-one-loop.md#comparison-test): 15 questions (5 per forum kind) and one public forum per kind. Task 8 records both loops only after the owner confirms this set.

## Proposed fixture forums

| Kind | Forum | Site URL | Starting home URL | Why this forum |
|---|---|---|---|---|
| `discourse` | Discourse Meta | `https://meta.discourse.org` | `https://meta.discourse.org/` | Public Discourse instance with open JSON/raw endpoints, `#category` / `status:solved` / `after:` search syntax, long support threads, and feature announcements. |
| `hackernews` | Hacker News | `https://news.ycombinator.com` | `https://news.ycombinator.com/` | Public stories and nested comment trees served via `news.ycombinator.com` and `hn.algolia.com`. |
| `wordpress` | Doctor Of Credit | `https://www.doctorofcredit.com` | `https://www.doctorofcredit.com/` | Public WordPress blog with open `/wp-json/wp/v2/{posts,comments,categories}`, `X-WP-Total` headers, and active reader comment threads. |

**Thread URLs.** Old Research receives only `goal` and `siteURL` (no current page), so every thread question names the thread title and canonical URL in its prompt text and both loops receive the exact same string. WordPress thread questions use canonical `?p=<id>` URLs (`WordPressLinks.topicURL` / `WordPressRecognizer.topicID(fromURL:)`) because WordPress slug permalinks omit the numeric post ID.

---

## Discourse — Discourse Meta (`https://meta.discourse.org`)

- **D1 · Site-wide opinion**
  - **Starting page:** `https://meta.discourse.org/`
  - **Exercises:** `search_forum`, reading several threads across categories, citations
  - **Prompt:** `What do forum admins here think of Discourse's sidebar navigation compared with the older hamburger menu?`

- **D2 · Fact inside one long thread**
  - **Starting page:** `https://meta.discourse.org/t/discourse-update-keeps-failing/231862`
  - **Exercises:** `read_topic` over a >46 KB thread (72 posts), `query` / `page`, workspace file fallback, post citations
  - **Prompt:** `In the thread "Discourse update keeps failing" (https://meta.discourse.org/t/discourse-update-keeps-failing/231862), which Ruby gem and CPU instruction issue caused the rebuild failures, and how was it fixed?`

- **D3 · Multi-step**
  - **Starting page:** `https://meta.discourse.org/t/introducing-nested-replies/402812`
  - **Exercises:** `summarize_topic`, then `search_forum` across other threads
  - **Prompt:** `Summarize the thread "Introducing nested replies" (https://meta.discourse.org/t/introducing-nested-replies/402812), then find what others here say about point 2.`

- **D4 · Latest**
  - **Starting page:** `https://meta.discourse.org/`
  - **Exercises:** `list_latest`, selecting and citing notable active threads
  - **Prompt:** `What's worth reading today on Discourse Meta?`

- **D5 · Kind-specific (category, solved, and date filter)**
  - **Starting page:** `https://meta.discourse.org/`
  - **Exercises:** `search_forum` syntax (`#support`, `status:solved`, `after:YYYY-MM-DD`)
  - **Prompt:** `In the Support category since 2025-01-01, what solved PostgreSQL upgrade problems have self-hosters hit?`

---

## Hacker News (`https://news.ycombinator.com`)

- **H1 · Site-wide opinion**
  - **Starting page:** `https://news.ycombinator.com/`
  - **Exercises:** `search_forum`, reading multiple story discussions, citations
  - **Prompt:** `What do people here think of using an Intel N100 mini PC for a home server?`

- **H2 · Fact inside one long thread**
  - **Starting page:** `https://news.ycombinator.com/item?id=47637353`
  - **Exercises:** `read_topic` over a ~38 KB nested thread (129 comments), `query` / `page`, workspace file fallback
  - **Prompt:** `In the thread "SQLite in Production: Lessons from Running a Store on a Single File" (https://news.ycombinator.com/item?id=47637353), why did concurrent database exec queries during a deploy trigger the OOM killer on their t3.small machine, and what GitHub Actions feature does a commenter recommend instead of CLAUDE.md deploy rules?`

- **H3 · Multi-step**
  - **Starting page:** `https://news.ycombinator.com/item?id=44809166`
  - **Exercises:** `summarize_topic`, then `search_forum` / `search_comments`
  - **Prompt:** `Summarize the thread "How I use Tailscale" (https://news.ycombinator.com/item?id=44809166), then find what others here say about point 2.`

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

- **W1 · Site-wide opinion**
  - **Starting page:** `https://www.doctorofcredit.com/`
  - **Exercises:** `search_forum`, reading several posts and reader discussions, citations
  - **Prompt:** `What do posts and readers here think of the US Bank Smartly Visa card after its changes?`

- **W2 · Fact inside one long thread**
  - **Starting page:** `https://www.doctorofcredit.com/?p=229112`
  - **Exercises:** `read_topic` over a ~58 KB post (316 comments across 4 comment pages), `query` / `page`, workspace file fallback
  - **Prompt:** `In the post "[Targeted] Chase Travel: Spend $600+ & Receive $100 Back" (https://www.doctorofcredit.com/?p=229112), does checking out multiple separate hotel bookings together in one Chase Travel cart count as a single transaction to trigger the $100 credit?`

- **W3 · Multi-step**
  - **Starting page:** `https://www.doctorofcredit.com/?p=268506`
  - **Exercises:** `summarize_topic`, then `search_forum` / `search_comments`
  - **Prompt:** `Summarize the post "Year-End Credit Card Checklist for 2026: Travel Credits, Spend Reset, Application Strategy & More" (https://www.doctorofcredit.com/?p=268506), then find what others here say about point 2.`

- **W4 · Latest**
  - **Starting page:** `https://www.doctorofcredit.com/`
  - **Exercises:** `list_latest`, selecting and citing recent deals and news
  - **Prompt:** `What's worth reading today on Doctor Of Credit?`

- **W5 · Kind-specific (comment search with date filter)**
  - **Starting page:** `https://www.doctorofcredit.com/`
  - **Exercises:** `search_comments` with `after`, then `read_topic` on matching posts
  - **Prompt:** `What do commenters here say since 2026-01-01 about getting Chase Ink business cards approved as a sole proprietor?`

---

## Owner gate 1

Confirmed by the owner on YYYY-MM-DD: pending (owner gate 1; confirmed on WUKO-52's Accept card before task 8 records)
