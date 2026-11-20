# Store positioning: WukongMind next to Forumind

How WukongMind is positioned, named and kept apart from Forumind so both can be on the App Store from one developer account (WUKO-169, 2026-11-19). This is a plan and a set of recommendations: no app code changed. The owner's decisions are recorded in [requirements.md](requirements.md), section 12; the review checklist and the task list are in [app-store-review.md](app-store-review.md).

- **Decided by the owner (2026-11-19):** WukongMind goes to the App Store; both apps go up; WukongMind is an AI-assisted browser, Forumind is forum browsing only; the assistant may fill in App Store Connect with the `asc` CLI; one codebase, no hidden logic, so everything must comply.
- **Open, the owner's to decide:** the store name (section 4 recommends one), and removing the daily digest from WukongMind (section 2, row 5, recommended).
- **Owner principles applied (2026-11-19):** speed first; the smallest complete change, and delete what can be deleted; design gaps go back to the design documents; code the way Apple would agree with, nothing hidden; checks re-run with their raw output kept. Section 2 says where each one bites.
- **Guidelines used:** [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), fetched 2026-11-19, "Last Updated: October 16, 2026".
- **Code state:** `main` at `6d122e1` (version 1.5.4). App Store Connect and store searches were read on 2026-11-19 (read-only).

## 1. Where the two apps stand today

Read from App Store Connect with the read-only `asc` wrapper, and from the public iTunes lookup.

| | Forumind | WukongMind |
|---|---|---|
| App record | id 6816718686, bundle `io.github.kccarlos.forumind` | **Exists already:** id 6833832262, bundle `io.github.kccarlos.wukongmind`, SKU `wukongmind`; its 1.0 version was created 2026-11-12 (the WUKO-169 brief assumed there was no record) |
| Store state | Version 1.0.0 is `DEVELOPER_REJECTED`; the one review submission on record (submitted 2026-11-09) is `COMPLETE`. **Not on the store:** the public lookup for its id returns nothing | Version 1.0 in `PREPARE_FOR_SUBMISSION`; nothing filled in except the name; not on the store |
| Name and subtitle | "Forumind" / "AI reader for forums" (zh-Hans 论坛 AI 阅读助手, zh-Hant 論壇 AI 閱讀助理) | "WukongMind" / no subtitle, en-US only |
| Categories | Productivity, then Reference | none set |
| Age rating | 17+ | not answered |
| Listing text | Three languages. First line: "It's a forum browser with an AI assistant beside it". Headings: Skip the scroll, Ask questions, Ask the forum, Discourse/WordPress/Hacker News, Today: digest and podcast, Talk to the page, Translate, Share/Siri/Spotlight, Watch topics, Safe browsing, Your choice of AI, Kind to forums, On all your devices | empty |
| Keywords (en-US) | `summarize,summary,chat,community,thread,topic,reader,digest,TLDR,assistant,LLM,wordpress,hacker news` | empty |

So neither app is live, and Forumind has an unresolved history (1.2, then 5.6; [app-store-review.md](app-store-review.md), section 3). The owner's Forumind journal of 2026-11-19 says a new build is ready to resubmit once the owner agrees.

## 2. What a reviewer comparing the two would see

Guideline 4.3(a): "Don't create multiple Bundle IDs of the same app (for example, submitting a separate map app for every city in the world instead of a single worldwide map that allows users to search any city). This practice results in unnecessary apps, which makes it hard for users to find the apps they want."

The honest position: WukongMind began as a copy of Forumind and still contains most of what Forumind's listing describes. What it adds is what makes it a different app: it opens any site with tabs and an address bar, its Agent changes pages by running JavaScript, and it saves and runs user scripts. Forumind does none of that and only works on forum sites. The risk is not the shared code (Apple does not see it); it is that Forumind's listing, read heading by heading, also describes WukongMind, and that WukongMind's own screens still say "forum" in `about 165 of 1,556` interface strings (a pattern count over `WukongMind/Localizable.xcstrings` for forum, topic, thread and the platform names; an estimate, some may be unused).

Three rules decided each row below:

1. **Nothing is kept but left out of the listing.** That is the 5.6 pattern Forumind was rejected for, and it breaks the one-build rule. A feature the build has is named in the description; a feature we don't want named is generalised or removed.
2. **Ask "what can be deleted?" first, and say who decides.** The owner's principle is to delete what can be deleted rather than pile wording on top of it. So where a feature is not useful on any web page, the recommendation is to remove it, not to rename it. A removal still needs the owner's yes where it contradicts a document the owner wrote: [next-phase.md](next-phase.md), section 6, keeps Today on the start page. Small leftovers of deleted engines are simply deleted.
3. **Sizes come from the code.** `summarize_topic` and `read_aloud` already take any page's text (`WukongMind/ToolRegistry+Capabilities.swift:151`, `:199`), so most "generalise" rows are wording, not engines. S: under half a day of agent work, one small pull request. M: one pull request of about a day, with tests. L: more than one pull request.

The rows follow Forumind's own listing headings, since that is the side-by-side view, then the things only the code shows.

| # | Forumind listing says | Still in WukongMind (evidence) | Recommendation | Why, seen from the reviewer | Size |
|---|---|---|---|---|---|
| 1 | Skip the scroll: summarize a long topic | Yes. Suggestion "Summarize this thread and replies" on forum threads, "Summarize this page" elsewhere (`SuggestionRow.swift:51`, `:56`); one tool for both (`ToolRegistry+Capabilities.swift:155`) | **Keep as a generic web feature.** One wording everywhere: "Summarize this page"; on a recognised discussion the summary simply covers the replies too | Summarising the page in front of you is what an AI browser does. Two differently worded buttons, one for forums, is what makes it look like Forumind | S (in task 10) |
| 2 | Ask questions: chat about the topic | The topic chat engine was deleted in One loop; the Agent answers. Leftover wording: share sheet "Chat about it" (`WukongMindShare/ShareSheetView.swift:237`) | **Keep (it is the Agent).** Reword the leftovers to "Ask about this page" | Asking the assistant about a page is generic. Nothing forum-specific is left but words | S (task 10) |
| 3 | Ask the forum: search a whole forum, answer with numbered sources | Yes. Tools `search_forum`, `list_latest`, `read_topic`, `search_comments` (`ToolRegistry+Forum.swift:5-8`); suggestion "Search this forum…" (`SuggestionRow.swift:53`); Siri action "Ask a Forum" (`System/AppIntents.swift:43`); share action "Ask the forum" (`ShareSheetView.swift:244`) | **Generalise.** "Search this site…" / "Ask this site", offered wherever a reader exists (the three built-in ones or one the Agent learned). The Siri action becomes "Ask a Site". Tool names are internal and can stay | "Ask the forum" is Forumind's headline feature under the same name. "Search this site" on any site that can be searched is a browser feature, and Learn on ask already makes it work beyond the three platforms | S for the words (task 10); the capability is already general |
| 4 | Discourse, WordPress and Hacker News | Yes. Three adapters, 3,698 lines in `WukongMind/Sites/`. Visible as: "Add a forum" that refuses other sites ("doesn't look like a supported site. WukongMind works with …", `ForumDirectory.swift:85`, `SettingsForumsPage.swift:201`), a "Suggested" list of well-known forums (`SettingsForumsPage.swift:69`, `ForumDirectory.swift:210`), pinned "forums" on Home | **Keep the code, generalise the surface, delete the forum picker.** The adapters become invisible "fast readers" for sites they recognise. The list becomes "Sites": any address can be pinned; the refusal is deleted; the "Suggested" forums list is deleted | A screen called Forums that accepts only three forum platforms is Forumind's home screen. A list of pinned sites is a browser's favourites. Deleting the adapters would make reading those sites slower and costlier for no visible gain: a reviewer sees words and screens, not parsers | M (task 11) |
| 5 | Today: digest and podcast | Yes. Today module on Home, shown once a recognised site is in the list (`HomeView.swift:89`); digest of watched topics and pinned forums' top topics (`DailyDigest.swift:5-8`); two-host podcast (`Podcast/`); Siri actions "Open Today's Digest", "Play Today's Podcast" (`AppIntents.swift:77`, `:89`) | **Remove from WukongMind (recommended; needs the owner's yes).** The Today module, the digest, its two-host podcast, its background prefetch and its two Siri actions go; Forumind keeps them. Read aloud (row 6) stays. If the owner says no, the alternative is to keep it reworded ("pinned sites", "followed pages"), named in the description and out of the first screenshots | A daily digest of forums is not useful on any web page, and it is a headline of Forumind's listing: it is the one screen that is Forumind and nothing else. Generalising it properly (a digest of any pinned site) needs a way to list "what's new" on unknown sites in the background without a model: new work, not wording. Rewording it would keep a forum feature under a browser's name, which is the piled-up kind of fix the owner's principles rule out. Removing it also takes work off Home and out of background tasks. Against: the roadmap keeps Today on the start page, so the owner must agree, and the design documents change with it | Removal: M (task 12, gated on the owner). Real generalisation: L, not recommended. Rewording only: S |
| 6 | Any summary can be read aloud | Yes. `read_aloud` reads the page's text or a summary (`ToolRegistry+Capabilities.swift:199-203`); suggestion "Read it to me" | **Keep as a generic web feature.** Offer "Read it to me" on ordinary pages too, not only forum threads | Reading a page aloud is a browser feature (Safari has one) | S (task 10) |
| 7 | Talk to the page: live voice | Yes (`WukongMind/Voice/`), on any page; voice shares the Agent's tools | **Keep as a generic web feature** | Already about "the page", not forums. It needs its own consent (task 2) | none |
| 8 | Translate posts or a summary on the device | Yes (`Translation/TranslationViews.swift:84`) | **Keep as a generic web feature**; reword "posts" to "text" where it appears | Translation of on-screen text is generic | S (task 10) |
| 9 | Share, Siri and Spotlight | Yes. Share extension (off by default) with forum-worded actions and "… site detected" (`ShareSheetView.swift:191`, `:244`); "Summarize Link" takes "a forum topic's web address" (`AppIntents.swift:21`); Spotlight "topics you read" (`SettingsDataHelpPages.swift:33`) | **Generalise.** Share any page; "Summarize Link" takes any address; "pages you read". Delete the platform badge from the share sheet | Every browser has share and Siri entry points. The words are what tie them to forums | S (task 10) |
| 10 | Watch topics: notified of new replies | Yes. `watch_topic` follows a forum thread (`ToolRegistry+Capabilities.swift:256`); suggestion "Notify me of new replies" (`SuggestionRow.swift:54`); background refresh (`WatchSupport.swift`) | **Keep, reworded: "Follow this discussion".** Offered only where a reader exists, which is honest. Watching any page for changes is a possible later feature, not part of this plan | Following a discussion is one feature among many in a browser. It is not a headline, so it should not be one in WukongMind's listing either | S (task 10). Any-page watching: L, not now |
| 11 | Safe browsing: report, block, word filter | No. Deleted in `d915ea0` | **Stay removed.** WukongMind argues the general-browser case with Terms and "Report this answer" (task 5) | Per-forum moderation is a forum app's duty. Its absence is a real difference between the two apps, and the fallback if Apple disagrees is already written down | none |
| 12 | Your choice of AI; keys in the Keychain | Yes, shared provider layer | **Keep** | Bring-your-own-key is common to many apps and says nothing about what the app is | none |
| 13 | Kind to forums: one page per second; ad blocking off "out of respect for forum owners" | Yes. `ForumRequestPacing.swift`; Settings footers (`SettingsAssistantPages.swift:135`, `:143`, `:912`) | **Keep the behaviour, generalise the words:** "Site requests", "site owners" | Polite fetching is right for any site. The wording is copied from Forumind's listing | S (task 10) |
| 14 | On all your devices: iCloud sync, iPad side by side | Yes. Sync page lists "Forums and pins · … Ask the forum answers · watched topics" (`SettingsSyncPage.swift:207`) | **Keep; reword** | Sync is generic | S (task 10) |
| 15 | (code only) History and Manage grouped "by forum" | `HistoryView.swift:336`, `:374` | **Generalise** to "by site" | A browser's history is by site | S (task 10) |
| 16 | (code only) Camera, microphone and photo prompts say "forum page" | `WukongMind/Info.plist:57`, `:61`, `:65` | **Generalise** to "web page" | The system prompts are the first text a reviewer reads | already task 7 |
| 17 | (code only) First run | Step 1 "An agent for any web page", step 2 "Open a site · Any address works" with a "Suggested" list (`OnboardingSteps.swift:130`, `:265-277`); step 3 suggests "Make this page easier to read" | **Keep the steps; change the list.** Step 2's "Suggested" entries are the suggested forums of row 4 (`[SuggestedForum]`, `OnboardingSteps.swift:260`). Replace them with a short mixed list of ordinary pages, or with the address field alone; which one is settled in design-unified.md (task 11) | First run already says browser and Agent, but the only things to tap on its second screen are forums, and it is the second screen a reviewer sees | S (in task 11) |
| 18 | (code only) Type and file names (`ForumBrowser`, `ForumService`, …) | throughout | **Leave** | Not visible to users or reviewers; renaming is churn with no review value | none |

**What this adds up to.** Two tasks do the generalising (10: words and entry points; 11: the Sites list and first run, which also deletes the forum picker), one task removes the digest once the owner agrees (12), and one small task covers Forumind's side (13). They are specified in [app-store-review.md](app-store-review.md), section 5.

**How the owner's principles apply to these tasks.**

- **Speed first.** None of the tasks adds work to a hot path. Tasks 11 and 12 change Home, which is on the launch path: each reports Home's first-frame time before and after, measured the way [design-performance-2.md](design-performance-2.md) measures, and must not be slower.
- **Smallest complete change; delete.** Task 10 changes words and deletes leftovers; it adds no abstraction. Task 11 removes a refusal and a list rather than adding a second kind of pin. Task 12 is a deletion.
- **Design gaps go to the design documents.** Tasks 11 and 12 change the start page that [design-unified.md](design-unified.md) and [next-phase.md](next-phase.md) describe; they update those documents in the same pull request instead of working around them.
- **Nothing hidden, nothing gamed.** No feature is kept in the build and left out of the listing; the review note states the shared code; no wording is chosen to steer a reviewer away from something the build does.
- **Verification.** Each task re-runs the tests itself with `scripts/remote-test.sh` and keeps the command, the result and the log path in its proof.

## 3. Listings, screenshots, categories and the review note

### What each listing leads with

| | Forumind | WukongMind |
|---|---|---|
| One line | An AI reader for forums: catch up on long threads | A web browser with an AI agent that reads, changes and automates any page |
| Leads with | Thread summaries, Ask the forum, the daily digest and podcast, watch topics, forum moderation | Open any site (tabs, address bar); ask the Agent to change the page ("make it dark", "hide the clutter"); keep a change as a script you approved; user scripts; Learn on ask |
| Names further down | Voice, translate, share, choice of AI, sync | Summarize and read aloud any page, voice, translate, follow discussions, choice of AI, sync (and the daily digest, only if the owner keeps it) |
| Never says | "browser for any site", "agent", "scripts", "automate" | "forum browser", "Ask the forum", any forum platform's name |
| Category | Productivity, Reference (as it is) | **Utilities**, then Productivity. Most browsers the store search returned, including all the large ones, sit in Utilities (a few small ones are in Productivity), so the category helps say "browser". (This changes app-store-review.md 4.4, which had Productivity first) |
| Works on | Discourse forums, WordPress sites and Hacker News only | Any web page |

Rules for WukongMind's text (also guideline 2.3.7, section 4): no provider names, no "Safari", "Chrome" or "Tampermonkey" in the name, subtitle or keywords; no forum platform names anywhere in the metadata; no "forum" in the keywords, so the two apps do not compete for the same searches. Every feature the build has is named somewhere in the description (rule 1 above).

### Screenshots

WukongMind's set shows what Forumind cannot do, on pages that are not forums, with invented content:

1. A news-style article with the ask box: "Make it dark" and the changed page.
2. The Agent's steps in the conversation while it changes a page.
3. The script approval sheet, or Settings › Scripts with the switches (after task 4).
4. The tab overview and the address bar.
5. "Summarize this page" with Read aloud on an ordinary article.
6. iPad: a page and the Agent side by side.

No forum thread in the set. If the owner keeps the digest it appears once, late in the set, because a feature the build has is shown or named, never left out. Forumind's set stays on forum threads, Ask the forum and Today.

### Forumind's side (another repository; recommendations only)

- Its description opens "It's a forum browser with an AI assistant". Prefer "an AI reader for forums", matching its subtitle, so "browser" belongs to WukongMind.
- Its zh-Hans and zh-Hant keywords contain 浏览器 / 瀏覽器 ("browser"). Remove them.
- Its en-US keywords contain `wordpress` and `hacker news`. Those are other parties' names in keywords; 2.3.7 says not to pack metadata with "trademarked terms, popular app names". Remove them (the description may still name the platforms it supports, with the non-affiliation line it already has).
- Its review note should carry the same relationship paragraph, mirrored.

### Order of submission

1. **Forumind first.** It is further along, and its open 5.6 history should be settled, or at least answered, before a second app from the same account arrives. A 5.6 problem is about the developer, not one app.
2. **WukongMind when its tasks are done** (tasks 1 to 11). It need not wait for Forumind's approval, but should not be submitted while a Forumind rejection sits unanswered.
3. Whichever is in review, the note names the other app. If Apple answers with 4.3, the prepared reply is this section.

### The review note paragraph on the relationship

For App Review Information › Notes, after the opening paragraph ([app-store-review.md](app-store-review.md), section 4.2). About 590 characters:

```
OUR OTHER APP
We also develop Forumind (Apple ID 6816718686). The two apps share some code but are different products. Forumind is a reader for discussions: it works only on Discourse forums, WordPress sites and Hacker News, and has no agent that changes pages and no scripts. WukongMind is a general web browser: it opens any website in tabs, its Agent can change the page you are on by running JavaScript in WebKit, and it can keep a change as a user script that you review and approve. WukongMind can also summarize or read aloud any page, including discussion pages; that is one feature of the browser, not its purpose.
```

Every sentence must be true of both builds on the day of submission. "a user script that you review and approve" is true only after task 4. "has no agent that changes pages and no scripts" and "works only on Discourse forums, WordPress sites and Hacker News" describe Forumind (the second is what its own listing says) and are to be checked against its submitted build (see Not proven).

## 4. Name

### What was checked

- **Public App Store:** the iTunes Search API (`https://itunes.apple.com/search?term=…&entity=software&country=…&limit=25`), 15 terms in the us, cn, tw, hk, gb and jp stores, 2026-11-19. Results are fuzzy matches, top 25 only; some calls were rate-limited and repeated once.
- **USPTO:** the public trademark search (`tmsearch.uspto.gov`), wordmark search, read in a browser on 2026-11-19. Only single-word queries test a name: "wukong" (62 results, the first 50 read), "wukongmind" (none), "forumind" (none), "ruyi" (30), "somersault" (29). Multi-word queries there match any word, so "wukong browser" (386) and "wukong mind" (937) prove nothing about the phrase.
- **App Store Connect:** the app record already holds the name "WukongMind".

### What "Wukong" runs into

- **The store is crowded with it.** Dozens of apps: many games; "WuKong: Chinese, Math & ELA" (Lan Global Limited, Education); "AI WUKONG ROBOT" (UBTECH); "Wukong - Food Delivery"; "悟空AI CRM". No app named "Wukong Browser" or "WukongMind" was returned in any of the six stores.
- **悟空浏览器 is taken, by a large app.** In the China mainland store: "悟空浏览器-看短剧小说影视", seller Beijing Infinite Dimensions Technology Co.,Ltd, Utilities, 999,986 ratings. In the us, tw, gb and jp stores: "悟空智搜浏览器-…", seller Beijing Alpha Technology Co., Ltd, Utilities. "Wukong Browser" is exactly how a Chinese reader says 悟空浏览器, and WukongMind's listing has two Chinese localisations.
- **USPTO, software classes (9 and 42), live marks containing WUKONG:**

| Mark | Status | Classes | Owner | Goods (as shown, cut short by the site) |
|---|---|---|---|---|
| WUKONG (79292704) | registered | 9, 16, 35, 41 | Lan Global Limited (New Zealand) | "Downloadable Educational software for use in the teaching and…" |
| WUKONG (99774216) | pending | 42 | DingTalk (Singapore) Private Limited | "Technology consultation in the field of artificial…" |
| BLACK MYTH WUKONG (90564354, 90564367, 90564509) | registered | 9, 42, 41 | Game Science Interactive Technology Co., Ltd. | "Computer keyboards; Computer peripheral devices; Downloadable…", "Computer programming; Computer software consultancy…" |
| EYE OF WUKONG (98851368) | registered | 9, 41 | bet365 Group Limited | casino game software |
| WUKONG (87572323) | registered | 9 | Shenzhen Aiyimei Technology Co.,Ltd. | "Decorative magnets; Magnets." (not software) |

This is a search, not legal advice. The point it supports: when a name is a known word plus a descriptive one ("Wukong" + "Browser"), the descriptive word carries no weight and what remains is bare WUKONG, which is exactly where a registered software mark and a pending AI filing sit. A coined single word ("WukongMind") is further from them, though it still contains the word.

### Candidates

Store names are at most 30 characters; so are subtitles.

| Candidate (length) | App Store | USPTO | Next to Forumind | 2.3.7 | In Chinese | Verdict |
|---|---|---|---|---|---|---|
| **WukongMind** (10) | No app of that name returned. Already held by our record | No results for "wukongmind" | Shares the "-mind" ending: reads as a sibling of Forumind. Says nothing about being a browser; the subtitle must | Unique, no descriptive padding | "悟空" + Mind; nobody else uses it | Safe; weakest at showing the difference |
| **Wukong Browser** (14) | No exact match in English. But 悟空浏览器 (cn) and 悟空智搜浏览器 (us, tw, gb, jp) exist, both browsers | The distinctive part is bare WUKONG: registered in class 9 (Lan Global), pending in class 42 for AI (DingTalk) | Furthest from "Forumind" | A generic word after a crowded one; reads like a variant of an existing browser's name in Chinese, which 5.2.1 calls "copycat … names" | Reads as 悟空浏览器, an existing browser with about a million ratings | **Not recommended** |
| **WukongMind Browser** (18) | No match returned | Distinctive part is WUKONGMIND: no results | Says "browser" in the name; "-mind" still shared, but the second word separates them | "Browser" as part of a browser's name is ordinary (other browsers in the results do the same) | "WukongMind 浏览器": keeps the coined word in Latin letters, so it is not 悟空浏览器 | **Recommended** |
| Wukong AI Browser (17) | No exact match; "AI Browser" is a crowded phrase (several apps use it) | As "Wukong Browser": bare WUKONG, and "AI" moves it closer to the pending AI filing | Far | "AI" in the name is descriptive padding | 悟空 AI 浏览器: still the existing browser's name with a word added | Not recommended |
| Ruyi Browser (12) (如意, the staff: "as you wish") | No match | RUYI is registered in classes 9, 28, 35, 41, 42 (79423235, Beijing TuSimple Technology Co., Ltd.) | Far; loses the WukongMind identity | Fine | 如意浏览器: pleasant, but a common brand word | Not recommended: a live software registration on the exact word |
| Somersault Browser (18) (筋斗云, the cloud somersault) | No match | No live software mark on SOMERSAULT (two dead class 9 filings; SOMERSAULT WELLNESS and SOMERSAULT INNOVATION are live in other fields) | Far; loses the identity, the icon and the repository name | Fine | 筋斗云浏览器: clear to Chinese readers, opaque in English | Clean fallback if "Wukong" ever draws a complaint |
| Monkey King Browser (19) | No exact match; the phrase is crowded with games | 652 results for the two words, many dead game filings; MONKEY KING is registered in class 41 | Far | Fine | 美猴王浏览器 | Not recommended: generic and game-flavoured |

### Recommendation

- **Store name: "WukongMind Browser".** In the Chinese localisations: "WukongMind 浏览器" (zh-Hans) and "WukongMind 瀏覽器" (zh-Hant). Never "悟空浏览器" or "悟空瀏覽器" as the name, in the subtitle or in the keywords.
- **Subtitle:** "AI agent for any web page" (25). zh-Hans: "任意网页上的 AI 智能体". zh-Hant: "任何網頁上的 AI 代理".
- **Why this one:** it gives the owner's wish (the word "browser" in the name, the widest honest gap from "Forumind: AI reader for forums") without resting the name on bare "Wukong", and it needs no code change.
- **Second choice:** keep "WukongMind" and let the subtitle say browser ("Browser with an AI agent", 24). Lower risk still, smaller gap.

### Risks that remain

- **"Wukong" inside the name.** Lan Global's registration covers educational software and DingTalk's filing is pending; neither is a browser, and "WukongMind" is one coined word, but a complaint through Apple's name-dispute form is possible. If it comes, a rename is cheap (below) and "Somersault Browser" is the checked fallback.
- **The well-known game.** BLACK MYTH WUKONG is registered in classes 9 and 42. The icon, screenshots and text must not borrow the game's look or the words "Black Myth".
- **The Chinese nickname.** The repository calls the app 悟空. In the store, "悟空" alone or next to "浏览器" is someone else's name; the description may say "WukongMind（悟空）" at most once, or leave it out. Recommended: leave it out.
- **"-mind" is shared with Forumind.** It marks the two as siblings. That is honest (same developer, stated in the note) and is not what 4.3(a) is about, but it is why the second word matters.

### What a rename touches

| Thing | Changes? | How |
|---|---|---|
| Bundle id `io.github.kccarlos.wukongmind`, SKU, App Group, iCloud container, URL scheme | **No.** No reason to: the record exists under this bundle id, TestFlight builds are attached to it, and Apple does not show it to users | |
| App Store name (App Information › Name, per language) | Yes | An edit of the existing record while the version is in Prepare for Submission; with `asc` in write mode, as part of task 8. The store name must be free at that moment: only App Store Connect can say so |
| Name under the icon (`CFBundleDisplayName`, `WukongMind/Info.plist:13`, `WukongMindShare/Info.plist:8`) | **No, recommended.** "WukongMind" fits under an icon; "WukongMind Browser" would be cut. A home-screen name that is the short form of the store name is common practice; no rule on it was looked up (see Not proven) | |
| In-app text | No. 44 interface strings and 6 share-extension strings say "WukongMind"; they stay | |
| Repository, README, website | The README's title may say "WukongMind Browser" once; part of task 3 | |

## 5. Not proven

- **Name availability.** Only App Store Connect can confirm a store name is free, at the moment of saving. The iTunes Search API is a fuzzy, top-25 search of six stores; an app with one of these names can exist and not have been returned.
- **Trademarks.** USPTO only (no EUIPO, WIPO, China, Taiwan). Wordmark search only; 12 of the 62 "wukong" results were not read; goods and services are quoted as the site cut them; no search for 悟空 returned anything and "wu kong" (two words) was an any-word search. Not legal advice.
- **Store name and home-screen name differing.** That Apple accepts "WukongMind Browser" in the store with "WukongMind" under the icon is common practice as far as known, not checked against Apple's text.
- **Who is behind 悟空浏览器.** Only the seller name the API returned is recorded.
- **Forumind's build.** That Forumind "works only on forum sites" and has no tabs, agent or scripts is taken from this repository's documents (the "not a supported site" block removed here, [m0-module-map.md](m0-module-map.md) row 9) and Forumind's listing (Discourse, WordPress and Hacker News), not from running its current build.
- **How Apple applies 4.3(a) to two apps like these.** No precedent was found or searched for; the plan is an argument, and a rejection round is possible.
- **The string count.** "About 165" is a pattern count over the string catalogue; nobody walked the screens. Task 10 starts by listing them.
- **Forumind's review state beyond the API.** The Resolution Center messages and the 5.6 appeal's outcome are not readable through the API key used.
- **Nothing was run** on a device or simulator for this plan.
