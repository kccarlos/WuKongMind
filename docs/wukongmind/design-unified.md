# Unified interface design (whole app)

The unified-interface implementation milestone builds against this page and the design canvas:
**https://claude.ai/artifact/Daefr4AsZcSm2EWbTLU9uK**. The canvas has the information architecture, the answers to the six directions, artboards for iPhone and iPad in light and dark (the assistant panel on a forum page and on an ordinary page, "This page", Home, Settings, the three onboarding steps), motion storyboards, the migration list and the glossary.

It answers section 3 of [next-phase.md](next-phase.md), which wins where [requirements.md](requirements.md) or [README.md](README.md) disagree. It builds on [design-m1.md](design-m1.md) and [design-m2.md](design-m2.md) and their canvases. **This changes structure, not looks.** Every piece keeps Forumind's style: SF text styles, `DCTheme` tokens, `dcCard`, `DCPill`, `DCActionButtonStyle`, `Form(.grouped)`, `SettingsIcon`, `DCMotion` (`Forumind/DesignSystem.swift`, `Forumind/SettingsPanel.swift`). `brandBlue` is still the action colour. Summary keeps `summaryTint` and topic chat keeps `chatTint`.

**Purple and the sparkle mean only the Agent.** `agentTint` and the `sparkles` symbol appear only on Agent things: the toolbar Agent button and its badge, the Agent model pill, the Agent item of the send-to Menu, Agent tasks in Recent and History, and the Agent's own tool rows and status. Three things change to follow this rule:
- **Research** moves from `agentTint` to `brandBlue`.
- **The This page chip** and its kind pill are neutral: `fill` background and label colour.
- **Forums** are marked with a grey speech-bubble badge (`text.bubble.fill` on `systemGray`) instead of the purple sparkle.

M1 and M2 screens that use `agentTint` for scripts (the script card, the script manager's header icon) finish as designed. Aligning them belongs to this design's implementation. Settings' Scripts & tools icon is already drawn grey.

**What the boards draw that is not to be built as copy:**
- **Placeholders.** Dashed, dimmed rows marked M3, M4 or M5 only show where a later milestone's screen goes. The implementation ships no disabled rows: each milestone adds its own row in the place shown.
- **Captions.** Notes that explain a board sit in the canvas's sticky notes, not inside the mock UI.

**Two rules from the owner, for every screen:**
- **Menus are native menus only.** A SwiftUI `Menu` (`UIMenu`) holds only these: buttons (a title, an SF Symbol and an optional subtitle), checkmark or toggle state, submenus, inline sections and dividers, the destructive role, and the small or medium palette sizes. It never holds custom views, switches, sliders, chips, badges or text fields. Here is where each of this design's menus stands:
  - The model pill is a `Menu` of models with a checkmark on the current one, plus "Models…".
  - The send-to button in the input box is a `Menu` of three buttons (Agent, Research, Topic chat). Each has a symbol and a one-line subtitle, and the current one has a checkmark.
  - The panel's ⋯ and the summary card's ⋯ hold buttons only. Export options… opens its sheet.
  - The iPhone browser menu and the iPad More menu hold buttons only.
  - Follow, the script switches and "Block ads here" are real `Toggle`s, so they live in the This page **popover**, never in a menu.
  - The tile actions on Home (Pin, Unpin, Remove) are a `contextMenu` of buttons.
- **The UI explains itself.** Labels stay short. Layout, icons and state carry the meaning. No line of copy explains how the screen works:
  - When a page has no quick actions, the row is simply absent.
  - Settings rows carry no explanatory footers beyond what Forumind's existing pages already have.
  - Onboarding keeps one short subtitle per step.
  Designer notes live in this file and in the canvas's sticky notes, outside the frames.

**Status: a draft for the owner.** Nothing here is built until the owner confirms the information architecture, the artboards and the migration list. M2's UI tasks finish to their current design. Moving them is part of this design's implementation, and no M2 screen is redrawn here. Screens the cleanup deletes (consent, terms, report, moderation) need no migration and are only listed.

## The six directions, answered

1. **One assistant, one input box.** One panel (`AssistantPanel`) with one composer on every page, sending to the Agent by default. Summary, Listen (the podcast), Research (was "Ask the forum") and Topic chat stop being modes. Two kinds of action look different and sit in different places:
   - **Run-now actions: Summary, Listen.** They are solid chips in a row right above the input box, shown only when the page supports them. A tap runs at once and adds a result card (Summary) or starts the podcast and its now-playing row (Listen).
   - **Ask actions: Research, Topic chat.** They live in the **send-to Menu**, a button inside the input box, shown on forum pages only. The panel title and model pill follow the chosen target. This is a **transitional** design (section 1).
   - **Voice.** The trailing button is a **mic** while the field is empty and **Send** once you type. Voice turns land in the same conversation.
   - **Shared results.** Every result lands in **one conversation**, and earlier results are passed to whichever engine gets your next message as **shared results** (section 1), shown as removable pills.
   - **The engines don't change their loops.** Summary uses `ModelRole.assistant` and the summary pipeline, Topic chat uses the chat engine, Research uses `AgentEngine`, and the Agent uses `BrowserAgent`. Their only new input is the shared-results text placed before the user's message.
2. **Capabilities follow the page.** The M1 context row's chip ("N scripts on this page") becomes the neutral **This page** chip. It shows the site's kind and its script count ("Forum · 3 scripts"). It opens the **This page** popover (`PageCapabilitiesView`, which grows from M2's `PageScriptsPopover`). The popover has four groups:
   - **This topic**: the Follow switch (forum topics only). Summary, Listen and Research are not repeated here, because the row and the Menu already show them.
   - **Scripts on this page**: M2's rows and switches.
   - **Tools on this page**: an M5 placeholder.
   - **This site**: block ads here, and a link to the site's settings.
   It is the only place a page's capabilities are listed. The toolbar badge keeps its M1/M2 meaning (the script count) and opens the panel.
3. **Home is the browser's start page.** From top to bottom:
   - an address field ("Search or enter address"). It is the only address field on Home; the bottom bar shows no address capsule there;
   - Today, only when the digest or podcast has something;
   - **Sites**: a grid of pinned and frequent sites, with an Add tile;
   - **Recent**: the newest History items of any kind, with a History link;
   - Continue reading;
   - Following.
   Forums are tiles like any site, with a grey speech-bubble badge. Suggested forums move into the Add site sheet.
4. **Settings grouped by object.** The root has five groups:
   - **Assistant**: Models, Agent, Scripts & tools.
   - **Sites & browsing**: Sites, Browser (which gains a search engine setting).
   - **Voice & digest**: Voice, Daily digest & podcast.
   - **Your data**: iCloud Sync, Data & privacy.
   - **Help & about**.
   All three model roles are on one Models page. Every setting appears exactly once (the per-setting table below).
5. **One vocabulary.** Only the browser agent is called **Agent**, and only it is purple or carries the sparkle. Site-wide Q&A is called **Research**. Script, tool, site, task and History mean one thing each in the UI and the docs (glossary below). Code renames are not part of this design or its implementation. The owner decides them in the cleanup's rename task.
6. **Onboarding in three steps.** 1 Pick a model, 2 Open a site, 3 Try the Agent. After that you're done. Welcome, Forums, Daily, Privacy and Done fold into these steps or move to Settings.

**Proposals beyond section 3, for the owner to confirm:**
- **Topic chat sits in the send-to Menu beside Research.** It is transitional, like Research (section 1).
- **One conversation with shared results** instead of one view per mode.
- **"Browser" stays a settings group of its own.** The bar position and what opens at launch fit none of section 3's seven groups.
- **The iPhone bar's forum menu (`ForumMenuButton`) becomes the browser menu.** It shows the site's icon. "Home" opens the start page, and the forum-only items move (migration list).
- **The ad shield moves from the title capsule into This page.**
- **"Watch" is renamed "Follow"** (next-phase's word).
- **Research takes `brandBlue` instead of `agentTint`** (see above).
- **On iPad, onboarding steps 1 and 2 are a form sheet** instead of today's full-screen cover.

## Information architecture

```mermaid
flowchart TD
  Launch([Launch]) -->|first run| OB1[Onboarding 1 · Pick a model]
  OB1 --> OB2[Onboarding 2 · Open a site] --> OB3[Onboarding 3 · Try the Agent] --> Browser
  Launch -->|later runs| Browser

  subgraph Browser[Browser · ContentView]
    Bar[Browser bar · address, back/forward, Home, ⋯]
    Page[Web page · WKWebView]
    Dock[Bottom layer · Dock: hint, answer ready, podcast, voice]
    Home[Home · start page]
  end

  Bar -->|Home button| Home
  Bar -->|sparkles button / badge| Panel
  Home -->|address field / site tile / continue reading| Page
  Home -->|Recent item| Panel
  Home -->|Today card| Today[Today · digest & podcast]
  Home -->|History| History[History]
  Home -->|Settings| Settings
  Home -->|Add tile| AddSite[Add site sheet · suggestions]

  subgraph Panel[Assistant panel · iPhone drawer / iPad side panel]
    Conv[One conversation: agent turns, result cards, voice turns · shared results]
    QA[Run-now row · Summary · Listen]
    Composer[Input box · send-to Menu Agent/Research/Topic chat · mic / send]
  end
  Composer -->|mic| Voice

  Panel -->|This page chip| ThisPage[This page popover]
  Panel -->|summary card ⤢| Expanded[Expanded summary / post & responses]
  Panel -->|Listen / podcast row| NowPlaying[Now playing]
  Panel -->|⋯ History| History
  Panel -->|⋯ Settings| Settings
  Panel -->|script card · view code| CodeSheet[Script code sheet]
  ThisPage -->|Manage scripts / script name| Scripts
  ThisPage -->|Site settings| Sites
  Voice[Voice session · controls in the Dock] -->|turns| Conv

  subgraph Settings[Settings sheet]
    Models[Models · 3 roles + providers & keys]
    Agent[Agent · steps, result size]
    Scripts[Scripts & tools · M2 manager]
    Sites[Sites · forums, following, summaries & chat, research, pace, ads]
    BrowserSet[Browser · search engine, bar, open at launch]
    VoiceSet[Voice]
    Digest[Daily digest & podcast]
    Sync[iCloud Sync]
    Data[Data & privacy]
    Help[Help & about · share from Safari, licences]
  end
  Scripts --> Detail[Script detail → code editor, history]

  Bar -.->|M3| Tabs[[Tab overview]]
  Agent -.->|M3| Audit[[Audit log]]
  Panel -.->|M3 ⋯ / tool row| Audit
  Agent -.->|M3| Workspace[[Workspace · also in Files]]
  ThisPage -.->|M5| PageTools[[Tools on this page]]
  Scripts -.->|M5| PageTools
  QA -.->|M6| CapQA[[Capability quick actions on any site]]
  Voice -.->|later| VoiceAgent[[Voice drives the Agent]]
```

Dashed links with double borders are **placeholders**: their place is reserved, and their content comes in the milestone named.

| Placeholder | Milestone | Where it sits | What is reserved now |
|---|---|---|---|
| Multiple tabs | M3 | A tab button in the browser bar, beside Home, opening a tab overview | The bar's slot. The panel works on the active tab |
| Audit log | M3 | Settings › Agent › Audit log; the panel's ⋯ › Audit log; "View in audit log" in an expanded tool row | One row on the Agent page, drawn disabled |
| Workspace | M3 | Settings › Agent › Workspace (and the system Files app) | One row on the Agent page, drawn disabled |
| Page tool list | M5 | This page › Tools on this page; Settings › Scripts & tools › Tools; script detail "Registers N tools" | The group's place in This page (drawn dashed on the canvas; nothing shipped until M5) |
| Capability quick actions | M6 | The quick-action row, on any site whose page tools return a thread or a post list | Nothing new: the row already shows actions by capability, not by forum |
| `GM_ai` model | M4 | Settings › Models, a fourth role row "Scripts" ("Same as Agent") | A disabled row on Models |
| Confirm before writes, step-limit switches | M3 | Settings › Agent | The Agent page's "Safety" section |
| Voice drives the Agent | Later (next-phase section 6, deferred) | The mic in the input box: spoken requests would run the Agent's tools | Nothing beyond the mic and voice turns in the conversation |

## Areas and their SwiftUI structure

### 1. Assistant panel

One view for both hosts. On iPhone it lives in the existing drawer (`AIDrawer.swift`, `.medium/.large` detents, background interaction up to medium). On iPad it lives in the existing split panel (`WorkspaceView` in `SplitWorkspace.swift`, 360 to 560 pt). Neither host changes.

```
AssistantPanel                         // replaces the per-mode switch in SummaryPanel/AgentPanel/BrowserAgentPanelView
├─ AssistantHeader                     // target symbol + title (Agent / Research / Topic chat) · model pill of that target · ⋯ menu
│    ⋯: New conversation, History, Audit log (M3), Settings
├─ PageContextRow                      // host DCPill + neutral This page chip → PageCapabilitiesView (.popover, compact adaptation .popover)
├─ AssistantTranscript (ScrollView)    // one list, newest at the bottom (scrollToBottomEdge)
│    ├─ user bubble (+ shared-result pills above it) / agent text / tool rows / "Steps N" fold   (M1)
│    ├─ ScriptCard                                              (M1/M2, unchanged)
│    ├─ SummaryResultCard   dcCard(tint: summaryTint) · numbered points · ⤢ opens ExpandedPanel
│    ├─ ResearchResultCard  dcCard(tint: brandBlue) · answer with numbered sources · "N topics read" fold
│    ├─ TopicChatTurn       bubbles with a chatTint caption
│    ├─ VoiceTurn           bubbles with a waveform glyph (what you said, what was answered)
│    └─ ListenRow           PodcastNowPlayingRow
└─ AssistantFooter (dcStickyFooter)
     ├─ status line                    // M1 status line; for Research: "Researching · 4 of 12 steps"
     ├─ QuickActionBar                 // run-now chips only; ScrollView(.horizontal); absent when empty
     ├─ SharedResultsRow               // removable pills for the results that go with the next message
     └─ Composer (AskBox field shape)  // [send-to Menu (forum pages)] field [mic when empty | send when typed | Stop while running]
```

- **State.** Replace `AssistantMode` (`summary`, `chat`, `agent`, `browserAgent`) with two small types:
  - `AssistantTarget` (`.agent`, `.research`, `.topicChat`) for where the composer sends, picked in the send-to Menu.
  - `QuickAction` (`.summary`, `.listen`), whose availability comes from `SiteCapabilities` for the current page (M6: also from page tools).
  `app.assistantMode` becomes `app.assistantTarget`, and its default is `.agent` on every page. Leaving the forum resets it to `.agent`.
- **The transcript** is a UI list of entries that point into each engine's own state (`BrowserAgentSession`, the summary store, the chat stream, the `AgentEngine` run). A Summary or Research result for a topic is the same record History shows, so reopening the panel on that topic shows it again.
- **What one conversation covers.** The Agent's turns belong to the browser (one conversation now, one per tab from M3) and stay as you move between pages, as `BrowserAgentSession` does today. Quick-action and Research results belong to their topic or forum and show only while you are on it. ⋯ › New conversation clears the Agent's turns, the shared results and the target. Results stay in History.
- **Shared results (owner point 1, option a).** Everything in one conversation can be referred to, because earlier results go along with the next message:
  - **Which results.** Those visible in the conversation for the current topic or page, newest first:
    - each summary card's text, up to 4,000 characters each;
    - each Research answer with its numbered source titles and URLs, up to 3,000;
    - the last three Topic chat question-and-answer pairs, up to 3,000;
    - the last two voice exchanges, up to 1,000;
    - the Agent's last final reply, up to 2,000, when the message goes to Research or Topic chat. The Agent already keeps its own turns.
  - **How much.** At most 8,000 characters in all. Older items are cut first and end with "(truncated, N characters)". Tool rows, raw tool results, script code and earlier topics' results are never sent.
  - **How.** One block, "Earlier results in this panel", placed before the user's message and wrapped in requirements section 8's untrusted-content delimiters, since it comes from web pages. The engines' loops don't change.
  - **What you see.** The SharedResultsRow shows one pill per result that will go along ("Summary ✕", "Research ✕"). Tapping ✕ leaves that result out of this message. After sending, the same pills sit above your bubble, so you can see what the engine was given. "Do point 2 of the summary" then works for any target.
- **The send-to Menu is transitional (owner point 2).** Research and Topic chat use separate engines and models today, so the Menu picks one of three targets, and the header shows the target's symbol, title and model: "Agent" with the Agent model in purple, "Research" with the Research model in blue, "Topic chat" with its model in teal. Title and pill never disagree. **End state:** the built-in adapters' "read the whole thread" and "search the whole site" become tools of the Agent, so a forum question goes to the Agent like any other. Then the Menu, the Research and Topic chat targets, and their header states go away. The end state is not drawn.
- **Page states.** Today's panel has page states besides the modes (`AssistantPanel.BodyKind` in `SummaryPanel.swift`):
  - `forumHome` (`ForumHomeState`) becomes the forum-list chips below.
  - `notForum` (`NotForumState`) goes: an ordinary page shows the Agent with no chips.
  - `maybe` (`MaybeForumState`, with its "add this forum" button) becomes a row in This page › This site: "Add as a forum".
  - `loading` (`AssistantLoadingState`) stays as the transcript's loading row.
- **Quick actions per page** (drawn):

  | Page | Run-now row | Send-to Menu |
  |---|---|---|
  | Forum topic (Discourse, WordPress post, HN item) | Summary · Listen | Agent · Research · Topic chat |
  | Forum home or list | Summary (of the list, as today) | Agent · Research |
  | Any other page | absent (M6 adds chips when page tools allow) | absent: Agent only |
  | No model for a role | The chip or Menu item stays. Choosing it shows `ProviderSetupCard` for that role | |
- **Run-now chip look.** A chip is a solid `brandBlue` capsule with white text: 36 pt tall with a 44 pt hit area, `.subheadline.weight(.semibold)`, and a symbol (Summary `text.alignleft`, Listen `headphones`). Solid fill means "runs when tapped". A chip whose result already exists reads "Summary · updated" or "Summary · 12 new".
- **Overflow (owner point 4).** The row is a `ScrollView(.horizontal)` with `.scrollIndicators(.hidden)` and 16 pt content margins, and a short fade at the trailing edge when it scrolls. Labels never truncate and chips never wrap. Checked on the canvas's QuickRowCheck board at 390 pt:
  - "Summary · 12 new" + "Listen" at the default size fits in about 250 of 358 pt.
  - At Accessibility XXL the row scrolls and the second chip peeks under the fade.
  - In Chinese, "摘要 · 12 条新回复" + "收听" fits.
  M6's extra chips scroll the same way.
- **The send-to button.** It sits inside the field's leading edge. For the Agent it is compact (the sparkle and a chevron). For the other targets it widens to its label in the target's tint ("Research ⌄"). The placeholder follows the target: "Ask the Agent…", "Research talk.example.org…", "Ask about this topic…". It is a `Menu` (native items only).
- **The panel's old tabs:**
  - Post & responses (`ExpandedPanelRoute.post`) is reached from a summary card's citations and ⤢, unchanged.
  - History (`.history`) is ⋯ › History.
  - Settings (`.settings`) is ⋯ › Settings, opening Settings at the root.
- **Today's ⋯ menu, item by item** (`SummaryPanel.swift`):

  | Today | Where it lands |
  |---|---|
  | Summary (mode switch) | The Summary run-now chip |
  | Chat, Ask the forum, Agent (mode switches) | The send-to Menu |
  | History, Settings | The panel's ⋯ |
  | Clear chat | The Topic chat turn's ⋯ › Clear topic chat. ⋯ › New conversation for the Agent |
  | Copy, Share, Export .txt, Export options…, Instructions & context, Pull post + replies only, Post & responses | The summary card's ⋯ menu |
  | Watch topic / Unwatch topic | This page › Follow this topic |
  | Report this answer / summary | Deleted by the cleanup |
- **Voice (owner point 3).**
  - **Starting.** The composer's trailing button is a mic (`mic.fill`) while the field is empty, and it starts a voice session (`VoiceBarButton`'s action). The bar's voice button stays as a second entry.
  - **Controls.** While a session runs, the Dock shows its controls as today.
  - **Turns.** What you say and what is answered appear as `VoiceTurn` bubbles in the same conversation, not in a separate place, and they join the shared results.
  - **Engine.** The voice engine itself doesn't change. "Voice drives the Agent" is a reserved place only.
- **Accessibility.**
  - **Labels.** The run-now chips are a group, "Quick actions", where each chip is a button. The send-to button reads "Send to: Agent", with the Menu's items as its choices. Shared-result pills read "Summary, shared, remove". The mic reads "Talk".
  - **Identifiers.** `agentPanel` and `aiButton` stay. New ones: `quickActionBar`, `quickAction.summary`, `composerSendTo`, `sharedResult.summary`, `composerMic`, `pageCapabilitiesChip`.

### 2. This page (`PageCapabilitiesView`)

This is a `.popover` with `.presentationCompactAdaptation(.popover)`, 320 to 340 pt, as M2's popover. It opens from the panel's chip.

```
PageCapabilitiesView
├─ header: site icon · host · kind DCPill (neutral: speech-bubble + "Forum · Discourse", or "Website") · page URL (mono, middle-truncated)
├─ Section "This topic"              // forum topics only: Follow this topic (Toggle). No list of actions: the row and the Menu show them
├─ Section "Scripts on this page"     // M2 PageScriptsPopover rows, Turn on box, Manage scripts — unchanged
├─ Section "Tools on this page"       // M5: the place only; not shipped before M5
└─ Section "This site"                // Block ads here (Toggle; was AdShieldMenu) · Add as a forum (was MaybeForumState) · Site settings ›
```

The chip reads "Forum · 3 scripts" or "3 scripts" (an ordinary page), or just the host on a page with nothing else; it stays a button, because the site group always has something. Errors keep M2's danger form ("3 scripts · 1 error").

### 3. Home (start page)

```
HomeView (List, .insetGrouped, listSectionSpacing(.compact))
├─ header: "Home" · History · Settings      (unchanged buttons)
├─ AddressField                              // 44 pt capsule, "Search or enter address" (searches with Browser › Search engine); focus shows suggestions
│                                            // the only address entry on Home: the bottom bar hides its address capsule while Home shows
├─ TodayModule / PodcastHomeCard / DigestStrip   // unchanged, only when there is something
├─ Section "Sites": SiteGrid                 // LazyVGrid, 4 columns on iPhone, adaptive 88 pt on iPad
│    SiteTile: ForumIcon-style tile (DCTheme.forumTileIcon), name; forum → grey speech-bubble badge
│    pinned first, then most visited; last tile "Add" → AddSiteSheet; context menu Pin/Unpin, Remove
├─ Section "Recent" + History link: RecentRow   // the newest 3 History items of any kind (kind symbol, first words, host, time) → page + panel
├─ Section "Continue reading": ContinueReadingRow   // unchanged, any site, keeps NewRepliesBadge
└─ Section "Following"                        // watched topics with new replies (was Watching)
```

- **One concept: History (owner point 9).**
  - **What it holds.** History holds everything saved: Agent tasks, Research runs, summaries and topic chats. A *task* is one Agent conversation, and it is one kind of History item.
  - **Recent.** Home's **Recent** is not a separate list: it is the newest History items, with a link to all of History. `HistoryView`'s segments become All, Tasks, Research, Summaries & chats, Following.
  - **Agent tasks.** They live in memory today (`BrowserAgentSession`). They join History once they are saved, which comes with M3's workspace (`tasks/`). Until then, Recent also shows this launch's current Agent task.
- **The empty state** (no sites yet) is the address field plus a `dcCard`: three suggested sites, no explanatory text. The forums among them carry the speech-bubble badge. This replaces the forum-centred empty state and the suggestions section.

### 4. Settings

The settings sheet keeps its host (`RootPresentation.settings(page)`, its own `NavigationStack`, Done only on the root).

```
SettingsRootView (Form .grouped)
├─ Section "Assistant"
│    Models            cpu            value: "3 roles" or "Agent: none"
│    Agent             sparkles       agentTint
│    Scripts & tools   curlybraces    systemGray, value: N / Off    (M2's row moves here)
├─ Section "Sites & browsing"
│    Sites             globe          value: "N forums"
│    Browser           safari.fill    value: the search engine, e.g. "Google"
├─ Section "Voice & digest"
│    Voice             waveform       value: On / Off               (the top-of-root Voice row goes)
│    Daily digest & podcast  sun.max.fill   value: On / Off
├─ Section "Your data"
│    iCloud Sync · Data & privacy
└─ Section
     Help & about      (Share from Safari or Chrome and Licences move inside)
```

| Page | Contents |
|---|---|
| **Models** (`SettingsPage.provider`, retitled; case name unchanged) | Section "Default models", with one row per role: **Agent** (`ModelRole.browserAgent` today, tool-calling models only), **Summaries & chat** (`ModelRole.assistant`), **Research** (`ModelRole.agent` today), then a disabled **Scripts** row (M4 `GM_ai`, "Same as Agent"). Section "Answer language": `ReadingLanguagePicker` (moved from the root). Section "Providers & keys": the existing provider list and forms |
| **Agent** (`.agent`, now the browser agent only) | Section "Runs": Step limit, Result size (from the old Ask-the-forum page's "Browser agent" section). Section "Safety": Confirm before writes. Requirements section 7 lists it, it isn't built yet, and the tools it guards (`http_request`, `cookies_get`) arrive in M3, so it lands then. Section "Records": Audit log ›, Workspace › (M3). Header line: the model name with a Change link to Models |
| **Scripts & tools** (`.scripts`) | M2's `ScriptManagerView`, unchanged. M5 adds a "Tools" section |
| **Sites** (a new page) | Section "Forums": Forums › (the existing page), Following › (the existing Watched topics page). Section "What forums can do": Summaries & chat › (the existing page, minus pacing), Research › (the research half of the old `.agent` page, as a new page). Section "Reading pace": the rate-limit switch (cleanup task 1) and the existing pace picker. Section "Ads & trackers": `ContentBlockingSettingsSections` (moved from Browser) |
| **Browser** (`.browser`) | **Search engine** (new, owner point 7): a `Picker` with Google, DuckDuckGo, Bing and Ecosia, default Google. It is used by the address field on Home, in the bar and in onboarding step 2, wherever text isn't an address. Today's search runs only inside the current forum (`searchPageURL`). Then Browser bar position and Open at launch |
| **Voice**, **Daily digest & podcast**, **iCloud Sync**, **Data & privacy** | Unchanged pages |
| **Help & about** (`.help`) | The existing page, which already links Licences (`.acknowledgements`), plus a row to Share from Safari or Chrome (`.sharing`, today on the root) |

### 5. Onboarding (`OnboardingFlow`, three steps)

Today onboarding is a full-screen cover on both devices (`RootPresentation.isFullScreen`). Steps 1 and 2 keep it on iPhone. On iPad they become a form sheet over the browser (a proposal). Step 3 runs in the real browser after the cover or sheet closes: the page opens with the panel at medium in a first-run state. `OnboardingProgressDots` shows 3.

```
OnboardingFlow
├─ 1 OnboardingModelPage     // BrandMark, "An agent for any web page"; OnboardingProviderPage's list for the Agent role
│                            // (tool-calling models only), key field; footnote "Keys stay in the Keychain"; Continue / Later
├─ 2 OnboardingSitePage      // AddressField + suggested sites (forums with the speech-bubble badge, from ForumDirectory) ; Open
└─ 3 OnboardingTryPage       // the chosen page behind a medium drawer: the real AssistantPanel with two suggested prompts
                             // ("Make this page easier to read", "Hide everything but the article"); after a run or Skip:
                             // a dcCard "You're set" with Done, and rows "iCloud sync: On" and "Daily digest: in Settings"
```

"Later" on step 1 still goes on. Step 3 then shows the panel's no-model card instead of the prompts.

### 6. Motion

Motion explains what happened, so the screens need fewer words. It reuses what the app already has:
- `DCMotion.quick` (0.22 s), `.smooth` (0.32 s) and `.spring` for animation.
- `DCMotion.respecting(reduceMotion, …)` for Reduce Motion.
- `DCHaptics` for haptics.
- `.contentTransition(.numericText())`, already used on Home.
- The zoom navigation transition, already used by Now playing.
- The Dock's `glassEffectID` morph.

There are no new curves and no decorative motion. Every animation is short, starts from what was touched, and ends where the result is. The canvas's **Motion** board draws each one as a storyboard.

| Moment | What moves | How (SwiftUI) | Why |
|---|---|---|---|
| Pick Research or Topic chat in the send-to Menu | The native Menu opens and closes. The send-to button widens to its label, and the header title, symbol and model pill crossfade to the target | system `Menu`, `matchedGeometryEffect` on the button label, `DCMotion.spring`, `DCHaptics.tap()` | Shows where the next message goes, and that the header changed with it |
| Shared results | When a result card arrives, its pill slides into the shared-results row. When you send, the pills move up with your bubble | `matchedGeometryEffect` between the row's pill and the bubble's pill, `DCMotion.smooth` | Shows what went along with the message |
| Mic and send | The trailing button morphs between mic and send as the field empties or fills | `.contentTransition(.symbolEffect(.replace))` | One place for both |
| Tap Summary or Listen | The chip shows a small `ProgressView` in place of its symbol. The result card then inserts at the bottom of the conversation, which scrolls to it | `.transition(.move(edge: .bottom).combined(with: .opacity))`, `DCMotion.smooth`, the existing `scrollToBottomEdge` | It links the tap to its result |
| Page changes (forum topic ↔ ordinary page) | The quick-action row grows or collapses in height while its chips fade. The header and input box stay still | `.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))` on the row, `DCMotion.smooth` | Only the part that differs moves, so the panel reads as the same panel |
| This page chip and toolbar badge | The count rolls to its new value. The chip's tint crossfades to danger on an error | `.contentTransition(.numericText())`, `DCMotion.quick` | Shows that a script just applied or failed |
| Open This page | The system popover animation, nothing custom | `.popover` | Native behaviour |
| Agent running | Unchanged from M1: tool rows slide in, `ResearchRing` turns around the toolbar button, and the run folds into "Steps N" when it ends. Research runs get the same ring | M1's `DCMotion.respecting` rules | One way to show "working" |
| Run finishes | A success haptic, and the status line's dot morphs into the check. With the panel closed, the existing button bounce plays and the Dock shows "Answer ready" (`glassEffectID` morph) | `DCHaptics.success()`, `.symbolEffect(.bounce)` | Felt even when you aren't looking |
| Run fails or hits the step limit | A warning haptic. The card inserts as above and is announced | `DCHaptics.warning()`, the M1 announcement | Same rule for every result |
| Home: open a site tile or a recent task | The tile zooms into the page. A recent task then raises the panel | `.navigationTransition(.zoom(sourceID: site.id, in: ns))`, the Now playing pattern. If the browser host can't take a navigation transition, a 0.22 s crossfade | Keeps your place: back returns to the tile |
| Home: pin or unpin | The tile moves to or from the front of the grid | `withAnimation(DCMotion.spring)` on the grid order | Shows where it went |
| Onboarding | Steps 1 → 2 push. The active progress dot stretches to the next one. When the cover closes for step 3, the panel rises to medium over the opened page and the two prompts appear 60 ms apart | `matchedGeometryEffect` on the active dot, the drawer's own detent animation, a `.delay` on the second prompt | Ends onboarding inside the real app, not on a "done" page |
| Settings | System push and pop only | — | Settings stay plain |

**Reduce Motion.** Every row above goes through `DCMotion.respecting`:
- Moves, scales, zooms and the pill and button morphs become a 0.2 s opacity crossfade.
- The progress ring and the bounce are off.
- Number rolls become plain changes.
- Haptics stay, because they aren't motion.

## Migration list

Kinds: **keep** (same place, maybe new words), **move** (same view, new place), **merge** (folded into another screen), **delete** (gone; own proposals are flagged *owner*), **cleanup** (deleted by the cleanup milestone, no migration).

### Browser shell, bar and Dock

| Existing | Kind | Where it lands |
|---|---|---|
| `ContentView`, `BrowserContent`, `PhoneBrowser` | keep | Unchanged hosts |
| `PhoneTitleCapsule` | keep | Shows the host. The `.notForum` warning is already gone (M1) |
| `PhoneAIButton`, `SplitPanelToggle`, `ResearchRing` | keep | Opens the one panel. The badge is M1/M2's |
| `VoiceBarButton`, `VoiceDock`, `VoiceSessionBar`, `VoiceBarCloseButton`, `VoiceLevelBars`, `VoiceDisclosure` | keep | Voice starts from the composer's mic (and the bar). Controls stay in the Dock; turns join the conversation |
| `AdShieldMenu` | move | This page › This site › Block ads here |
| `ForumMenuButton` (iPhone bar menu) | keep | Renamed browser menu, showing the site icon. Items: **Home** (was "Home", the forums home) opens the start page; the site's own home, Back, Forward, Stop/Reload, Share page, Copy link, History and Settings stay; Report or block goes with the cleanup. *owner* |
| `ForumSwitcherPanel` | delete | Not used by any view today. Home's Sites grid covers pinned and recent sites |
| `SplitNavigationButtons` | keep | Unchanged |
| `SplitMoreMenu` (iPad ⋯) | keep | Items: All forums → **Home**; Add forum… → **Add site…**; History, Settings, Translate posts on screen stay; Report or block goes with the cleanup |
| `DockLayer`, `HomeRouteDockModifier` (`Dock.swift`) | keep | The bottom layer's views, unchanged |
| `BottomLayer` `.bar`, `.dock` (voice), `.barWithPodcast`, `.drawer` | keep | Unchanged |
| `BottomLayer.barWithAnswerReady` | keep | Says "Answer ready" for any panel result (agent done, research answer, summary) |
| `BottomLayer.barWithHint` + `DrawerHint` `.summarize` | keep | New words: "Summary is ready to try · Open assistant" |
| `DrawerHint` `.checkNew`, `.setUpAI` | keep | `.setUpAI` reads "Choose a model" |
| `DrawerHint` `.allowAI` | cleanup | Goes with AI data consent |
| `WebContentCrashBanner`, `LoadingLine`, `LoginReadinessView` (`.loginInfo`) | keep | Unchanged |

### Assistant panel

| Existing | Kind | Where it lands |
|---|---|---|
| `AssistantMode` (`summary`, `chat`, `agent`, `browserAgent`) and the mode menu | merge | `AssistantTarget` + `QuickAction` (section 1) |
| `AssistantPanel` (`SummaryPanel.swift`) | keep | The one panel. Its per-mode branches go |
| Summary mode view | merge | The Summary quick action → `SummaryResultCard` in the transcript; ⤢ → `ExpandedPanel` |
| Chat mode | merge | Send-to Menu › Topic chat (transitional) |
| Ask the forum (`AgentPanel.swift`, `AssistantMode.agent`) | merge | Send-to Menu › Research (transitional). The run shows as `ResearchResultCard` with its steps fold (`toolStrip` and `stepRow` reused) |
| `BrowserAgentPanelView` | merge | The Agent part of the transcript (M1 rows, cards, status line, composer) |
| Panel tabs `ExpandedPanelRoute` `.post` / `.history` / `.settings` | move | `.post`: from summary cards. `.history`: ⋯ › History. `.settings`: ⋯ › Settings |
| `ExpandedPanel` (`RootPresentation.expanded`) | keep | Opened from ⤢ |
| `ResultCardsOverlay` (`.research`, `.sources`, `.focus`, `.search`) | keep | Same overlay over the page. Its research tint follows Research's |
| `ProviderSetupCard`, `ProviderSetupSheet` (`.providerSetup(role)`) | keep | Shown for the target's or chip's role |
| `InstructionsSheet` (`.instructions`), `ExportOptionsSheet` (`.exportOptions`) | keep | Under the summary card's ⋯ |
| `PostsTranslationSheet` (`.translatePosts`), `TranslationSheet` (`.translateText`) | keep | Unchanged triggers |
| `ReadAloudButton` | keep | On summary cards |
| M1 script card, View code sheet | keep | Unchanged |
| M1 context row chip "N scripts on this page" | merge | The This page chip |
| M2 `PageScriptsPopover` | merge | The "Scripts on this page" group inside `PageCapabilitiesView`, unchanged rows |

### Home and its sheets

| Existing | Kind | Where it lands |
|---|---|---|
| `HomeView` header (History, Settings) | keep | Unchanged |
| `TodayModule`, `PodcastHomeCard`, `DigestStrip` | keep | Below the address field, only when there is something |
| Continue reading (`ContinueReadingRow`, `NewRepliesBadge`) | keep | Any site |
| Pinned forums section | merge | The Sites grid (pinned first) |
| Recent forums section | merge | The Sites grid (frequent) |
| Watching section | keep | Renamed "Following" |
| Suggested forums section | move | `AddSiteSheet` (was `AddForumSheet`, `.addForum`), and the empty state |
| Share card | move | Help & about › Share from Safari or Chrome |
| `.pinnedForums` (all forums sheet), `ForumDirectory` | move | Settings › Sites › Forums |
| `.shareHowTo` (`ShareHowToSheet`) | keep | Opened from Help & about |
| `HistoryView` | keep | Holds everything saved. Segments: All, **Tasks** (Agent), **Research** (was Asks), Summaries & chats, **Following** (was Watching). Home's Recent shows its newest items |
| `TodayPage`, `DigestHistoryPage`, `DigestCardView` | keep | Unchanged, from Home's Today card |
| `NowPlayingView` (`.nowPlaying`) | keep | Unchanged |

### Settings, page by page

| Existing `SettingsPage` / section | Kind | Where it lands |
|---|---|---|
| Root: the Voice row at the top | delete | It duplicated Voice & digest › Voice |
| Root: `ReadingLanguagePicker` | move | Models › Answer language |
| `.provider` "AI models" | keep | Retitled **Models**, with all three roles (case name unchanged) |
| `.summaries` batching, chat context, custom instructions | move | Sites › What forums can do › Summaries & chat |
| `.summaries` `ForumRequestPaceSection` | move | Sites › Reading pace (plus the cleanup's on/off switch) |
| `.agent` research steps, topics to read, read size | move | Sites › What forums can do › **Research** (a new page) |
| `.agent` "Browser agent" section (steps, truncation) | move | **Agent** (`.agent`) › Runs |
| `.watched` Watched topics | move | Sites › Forums › **Following** |
| `.forums` | move | Sites › Forums |
| `.digest` (incl. `SettingsPodcastSections`) | keep | Voice & digest |
| `.voice` | keep | Voice & digest |
| `.browser` bar position, start page | keep | Browser, after the new Search engine setting |
| `.browser` `ContentBlockingSettingsSections` (ads, trackers, allowed sites) | move | Sites › Ads & trackers |
| `.sync`, `.data` | keep | Your data |
| `.help` | keep | Help & about |
| `.sharing` (a row on the root today) | move | A row inside Help & about |
| `.acknowledgements` | keep | Already linked from Help & about |
| `.scripts` (M2 `ScriptManagerView`, `ScriptDetailView`, `ScriptCodeEditor`, `ScriptHistoryView`) | move | Assistant › **Scripts & tools**. Only the root row moves; the pages are unchanged |
| `.debugSettings` | keep | Unchanged (DEBUG) |
| `ModelListSheet` (`.openAIModels`) | keep | From Models |

### Onboarding

| Existing | Kind | Where it lands |
|---|---|---|
| `OnboardingFlow` (`RootPresentation.onboarding`), `OnboardingPage`, `OnboardingHeader`, `OnboardingProgressDots`, `OnboardingBackdrop` | keep | Three steps |
| `OnboardingWelcomePage` | merge | Step 1's header |
| `OnboardingProviderPage` | keep | Step 1, for the Agent role |
| `OnboardingForumsPage`, `OnboardingForumIcon` | merge | Step 2 (any site; forums get the badge) |
| `OnboardingDailyPage` | move | Settings › Daily digest & podcast (no step) |
| `OnboardingSyncCard`, `OnboardingDoneSyncRow` | merge | Step 3's "You're set" card |
| `OnboardingDonePage`, `ChecklistMark` | merge | Step 3's "You're set" card |
| `OnboardingPrivacyPage`, `PrivacyPoints` | cleanup | Goes with consent. Step 1 keeps the one line about keys |
| `ShareHowToGuide` | move | Help & about |

### Deleted by the cleanup (no migration)

`.termsGate`, `.aiConsent` (`AIDataConsentViews`), `.voiceConsent` (`VoiceConsentSheet`), `.podcastConsent` (`PodcastConsentSheet`), `.report` (`ReportSheet`), `.reportAIOutput` (`AIOutputReportSheet`), and the rest of `ModerationViews` / moderation UI. "Content blocking" in next-phase's kind 1 means moderation's content filtering. The ad and tracker blocker (`ContentBlocker`) stays and moves to Sites (section 3 lists ad blocking under Sites).

## Glossary

One word per thing, the same in the UI and the docs. The code column shows today's names, which this design doesn't change. **Code renames are not part of this design or of the unified-interface implementation.** The owner decides them separately, in the cleanup's rename task (owner point 10). New types the implementation adds (`AssistantTarget`, `QuickAction`, `PageCapabilitiesView`) are named here. The VoiceOver label "Agent" on today's Ask-the-forum mode (`AssistantStates.swift`) changes to "Research", because that is UI wording.

| Word (UI) | Means | Not called | Code today |
|---|---|---|---|
| **Agent** | The browser agent: one loop with tools that reads and changes web pages. The only thing called Agent, and the only thing in purple or with the sparkle | browser agent (in the UI), assistant | `BrowserAgent`, `ToolRegistry`, `ModelRole.browserAgent` |
| **Research** | Answers a question by searching and reading the whole forum, with numbered sources. Picked in the send-to Menu (transitional) | Ask the forum, site-wide Q&A, research agent, Agent | `AgentEngine`, `AgentPanel`, `AgentToolName`, `AgentLimits`, `ModelRole.agent` |
| **Topic chat** | Questions about the open topic, answered from its full text. Picked in the send-to Menu (transitional) | Chat (alone) | the chat engine; new `AssistantTarget.topicChat` |
| **Send-to Menu** | The button inside the input box on forum pages: Agent, Research or Topic chat. The panel title and model pill follow it. Goes away in the end state | mode, token | new `AssistantTarget` |
| **Assistant** (the panel) | The one panel beside the page: the conversation, the run-now row and the input box. Its title is the current target | AI drawer, mode | `AssistantPanel` |
| **Quick action** | A run-now chip above the input box (Summary, Listen), shown only when the page supports it | mode | new `QuickAction` |
| **Shared results** | Earlier results that go along with the next message, shown as removable pills | context | new |
| **Summary** | A structured summary of the open topic or list | | unchanged |
| **Listen** | The podcast of the open topic or of Today | | podcast views |
| **Voice** | Talking with the assistant. Starts from the mic in the input box; its turns join the same conversation | Listen | `Voice*` views |
| **Follow** | Get told when a topic has new replies | Watch | `watchedTopics` |
| **Site** | Any website | | — |
| **Forum** | A site with a built-in adapter (Discourse, WordPress, Hacker News), so it has extra capabilities. Marked with a grey speech-bubble badge | | `SiteAdapter`, `Forum` |
| **This page** | What the current page offers: Follow, scripts, tools, site switches | page info | new `PageCapabilitiesView` |
| **Script** | Saved JavaScript/CSS in ScriptStore that runs on matching pages. It changes the page (M2) or registers tools (M5) | userscript (only in export/import), extension | `ScriptStore` |
| **Tool** | A function the Agent can call. Comes from the app (built-in), a script (script tool) or the site (site tool, WebMCP). "Page tools" means script and site tools on the current page | action, command | `ToolRegistry`; source prefixes per next-phase section 4 |
| **Task** | One conversation with the Agent, from the first message to the last result. One kind of History item | session, job | `BrowserAgentSession` |
| **History** | Everything saved: Agent tasks, Research runs, summaries, topic chats. Home's **Recent** shows its newest items | recent tasks | `HistoryView` |
| **Home** | The browser's start page | | `HomeView` |
| **Workspace** (M3) | The Agent's file folder, visible in Files | | — |
| **Audit log** (M3) | The record of every tool call | history | — |

## Checks before implementing

- **Every setting appears once.** Every current settings page has one destination. Pages that move whole keep all their sections, and the pages that split (`.agent`, `.summaries`, `.browser`, the root) are listed section by section.
- **The same panel everywhere.** Opening the panel on a forum topic and on an ordinary page shows the same header, chip and input box with its mic. Forum pages add only the run-now row and the send-to button (artboards 1 and 2).
- **Purple means Agent.** No purple and no sparkle on anything that isn't the Agent.

## Owner review of 2026-11-12: what changed, and where

| # | Comment | Change | Boards | Spec |
|---|---|---|---|---|
| 1 | Shared context or clearly separate | Option a: earlier results go along as shared results, up to 8,000 characters, shown as removable pills before sending and above the bubble after | PhoneResearch (pills in the composer and above the bubble; summary points numbered) | Section 1 › Shared results |
| 2 | Token is transitional; title vs pill | The send-to Menu replaces the token. The title, symbol and pill follow the target. End state noted: adapters' read-thread and search-site become Agent tools, and the Menu goes | PhoneResearch (title "Research" with a blue pill), PhonePanelForum, IPadForum, QuickRowCheck, Glossary, IA (end-state stub), Motion row 1 | Section 1 › The send-to Menu is transitional; glossary |
| 3 | Room for voice | Mic in every input box, voice turns in the conversation, IA stub "Voice drives the Agent", group renamed **Voice & digest** | PhonePanelForum, PhonePanelPage, IPadForum (voice turns drawn), IPadPage, PhoneOnb3, IA, PhoneSettings, IPadSettings | Section 1 › Voice; IA; placeholders; Settings |
| 4 | Row overflow; two behaviours look alike | Ask actions move into the send-to Menu, so the row holds only run-now chips, now solid blue. The row scrolls sideways. Checked with "Summary · 12 new", Accessibility XXL and Chinese | QuickRowCheck (new), PhonePanelForum, PhoneResearch, IPadForum, Motion row 3 | Section 1 › Run-now chip look, Overflow |
| 5 | Purple and the sparkle mean one thing | Forum badge is now a grey speech bubble. The This page chip and its kind pill are neutral. Scripts & tools icon is grey | PhoneHome, IPadHome, PhoneOnb2, IPadOnb, PhoneThisPage, PhonePanelForum, PhonePanelPage, PhoneResearch, IPadForum, IPadPage, PhoneSettings, IPadSettings, Motion row 4 | Opening rules; sections 2 and 3 |
| 6 | Two address entries on Home | The top field is the only one. The bar hides its capsule on Home (iPad shows a plain title) | PhoneHome, IPadHome | Section 3 |
| 7 | No search engine setting | Browser › Search engine (Google default) | PhoneSettings, IPadSettings (row value), IA | Section 4 › Browser |
| 8 | IA and popover disagree; plain-text row | Popover's first group is "This topic" with only the Follow switch. The text row is gone. IA matches | PhoneThisPage, IA | Section 2 |
| 9 | Recent tasks vs History | One concept: History holds all saved items, and Home shows "Recent" (its newest items) with a History link | PhoneHome, IPadHome, Glossary, IA | Section 3; glossary |
| 10 | Remove code renames | Glossary shows today's code names only. Renames go to the cleanup's rename task. `SettingsPage.provider` keeps its case and is retitled Models | Glossary, Main, Migration | Glossary; Settings tables |
| — | Self-check (iPad, dark, onboarding, settings subpages, migration, motion) | iPad boards: the same composer, chips and neutral chip as iPhone. Dark boards inherit every change. Onboarding: mic in step 3, grey badge in step 2 on both devices. Settings subpages (Models, Agent, Sites) have no purple-only-for-scripts and no explaining copy left. Migration and motion boards are updated | IPadForum, IPadPage, IPadHome, IPadSettings, IPadOnb, all *Dark wrappers, PhoneOnb2/3, Migration, Motion | Migration list; Motion |
- **Order.** Implementation goes assistant panel, then settings, then home and onboarding (next-phase section 5). Each part ships alone.

## Appendix: every other view in the code

Every public `struct …: View` / `ViewModifier` under `Forumind/` is named on this page. The ones the tables above don't name:

| Views | Kind | Where they land |
|---|---|---|
| `SettingsProviderPage`, `ProviderSettingsPage`, `ModelRolePage`, `ModelRoleRow`, `ProviderSetupForm`, `ProviderMenu`, `ProviderBadge`, `ProviderTestStatusView`, `APIKeyField`, `ModelField`, `AppleIntelligenceStatusView` | move | Settings › Models |
| `SettingsAgentPage` | merge | Split: research half → Sites › Research; browser-agent half → Agent |
| `SettingsSummariesPage` | move | Sites › Summaries & chat (pacing → Sites › Reading pace) |
| `SettingsWatchedPage` | move | Sites › Following |
| `SettingsForumsPage`, `PinnedForumsEditor`, `ForumRow`, `ForumTile`, `ForumTileLabel`, `ForumSwitcherLabel` | move | Sites › Forums (tiles reused by Home's Sites grid) |
| `SettingsBrowserPage` | keep | Browser, minus ads & trackers |
| `SettingsDigestPage`, `PodcastTodaySection`, `PodcastDisclosure`, `DigestIcon` | keep | Voice & digest |
| `SettingsVoicePage` | keep | Voice & digest › Voice |
| `SettingsSyncPage`, `SettingsSyncRow`, `SyncStatusRow`, `SettingsDataPage` | keep | Your data |
| `SettingsHelpPage`, `SettingsAcknowledgementsPage`, `SettingsSharingPage`, `ShareStepRow`, `ShareSheetIllustration`, `ShareActionsIllustration` | keep | Help & about |
| `SettingsDestination`, `SettingsIconRow`, `SettingsRowLabel`, `SettingsStatusPill` | keep | Settings building blocks |
| `AgentView` (`AgentPanel.swift`) | merge | Research run view inside the research card |
| `ForumHomeState`, `NotForumState`, `MaybeForumState`, `AssistantLoadingState` | merge | Page states, section 1 |
| `AssistantForumIcon`, `AssistantForumPill`, `AssistantForumRow`, `AssistantProgressBar`, `WorkProgressBar`, `WorkProgressCard`, `TypingIndicator`, `DrawerStatusRow`, `DrawerSummarySections`, `ChatBubble`, `PostPreviewView` | keep | Travel with the summary card, research card and topic chat turns |
| `AIDrawerModifier`, `AIDrawerCoordinator`, `PanelResizeHandle`, `DebugWindowWidth`, `RouterHost`, `HomeDestinations` | keep | Hosts and routing, unchanged |
| `OnboardingFeatureRow`, `OnboardingIconTile` | keep | Onboarding building blocks |
| `MarkdownView`, `MarkdownBlockView`, `CitationChip`, `TranslateButton`, `NewRepliesDot`, `BrandAppIcon`, `BrandGlyphLayout`, `BrandGlyphShape`, `DCCardModifier`, `DCSectionHeader`, `DCStatusChip` | keep | Shared components and the design system, unchanged |
| `AIDataConsentPage`, `AIDataFlowSection`, `TermsGateView`, `TermsAgreementCard`, `TermsPoints`, `ReportForm`, `ReportEmailFallback`, `ModerationSettingsSections`, `BlockedUsersPage`, `FilteredWordsPage` | cleanup | Deleted with consent, terms and moderation |

Private and file-private helper views travel with the screen that defines them.
