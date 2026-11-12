# WukongMind roadmap v2: Just ask

*2026-11-12, owner. English translation of the owner's doc "WukongMind 路线 v2：Just ask".*

**Precedence.** This document replaces the previous `docs/wukongmind/next-phase.md` wholesale and requires revising the unified interface design. Where it conflicts with any other document ([requirements.md](requirements.md), [README.md](README.md), [design-m1.md](design-m1.md), [design-m2.md](design-m2.md), [m0-module-map.md](m0-module-map.md) or `design-unified.md`), this document wins. Read sections 1 and 2 first.

The end state of 悟空 is: on any web page there is only one input box, the user asks whenever they need something, and behind it there is only one Agent loop; Forumind's summary, search, podcast and voice all become tools of this Agent, and when it meets a site it doesn't recognize, it learns on the spot.

## 1. What changed from the previous documents

Running the previous plan (`next-phase.md` and draft 2 of the unified interface design) to completion would have produced an AI Tampermonkey browser plus a Forumind that is complete only on three kinds of forum — sharing an interface without becoming one thing. Every change in this version exists to close that seam.

**What changed**

| Topic | Before | Now |
|---|---|---|
| Entry point | A target menu (`send-to Menu`) in the input box switching between Agent, Research and Topic chat | Only one input box, no modes, no targets |
| The row above the input box | Quick actions: buttons that execute a feature directly | Suggestions: pre-written questions; tapping one sends that sentence on the user's behalf |
| Shared-result pills | Built, carrying earlier results to the next engine | Not built. The same Agent naturally remembers earlier turns |
| Title and model pill follow the target | Built | Not built. The title is always Agent |
| Merging the two agent loops | Listed under "Not doing for now" | Promoted to a formal milestone, "One loop", right after M3 |
| Old Research loop | Kept and renamed | Deleted. Forum search and thread reading become Agent tools |
| Topic chat engine | Kept | Deleted. Replaced by the Agent plus thread-reading tools |
| Role of the forum features | Kept untouched alongside the Agent | Capabilities kept, now delivered through the Agent's tools |
| Voice | Unplanned; driving the Agent deferred | Microphone in the input box; in "One loop", voice sessions share the same tool definitions with the Agent and can hand multi-step requests to the Agent |
| M5 page tools, M6 capability outlet | Two milestones | Merged into one milestone, "Learn on ask" |
| How unfamiliar sites are learned | The user says "learn to read this forum" | Happens automatically whenever the user asks anything that needs it |
| Model roles | Three: Agent, Summaries & chat, Research | Two: Agent, Summary |
| Debug information | Audit log | Developer mode, including raw request inspection and task export; see section 8 |
| Code renames (Research-related) | Listed in the design glossary | No longer needed; those types will be deleted |
| Version numbers | M4 was 1.3.0 | M4 is 1.4.0; see section 7 |

**What did not change**

- Decisions on the four kinds of old code and the four cleanup steps (kept verbatim in section 9).
- Everything in M2.
- M3's tool list and workspace revision; M4's scope and `GM_ai`.
- Tools using the WebMCP shape.
- The two-week trial, and the rule that every addition must point to a real failed task as evidence.
- From the unified interface design: the start page, settings grouping, three-step onboarding, the `This page` popover, vocabulary, and purple representing only the Agent.

## 2. Documents and tasks to replace or change

Repository docs remain English-first; translate this document and apply it. Change only docs and the design spec in this step — touch no code.

**Documents**

| File | Action | What changes |
|---|---|---|
| [docs/wukongmind/next-phase.md](next-phase.md) | Replace wholesale | Overwrite with the English version of this document, keeping the file name. The old section 2 (three layers of capability), section 5 (milestones) and section 6 (not doing for now) are all superseded |
| `docs/wukongmind/design-unified.md` | Revise | See "Design revisions" below |
| [docs/wukongmind/README.md](README.md) | Modify | Four changes: point "Milestones run in order (M0 to M4)" to section 7 of this document; remove "Discourse features kept" from the open-question defaults; change the last bullet "existing features and tests must keep passing" to be governed by sections 6 and 9 of this document; rewrite the version table per section 7 |
| [docs/wukongmind/requirements.md](requirements.md) | Add note, don't rewrite | Add a note at the top listing the items superseded by this document: the section 2 baseline row "Discourse-specific summaries, chat, site-wide Q&A, followed topics: Kept as they are", section 6 "Agent mode has its own default model, beside Forumind's two existing defaults", section 7's interface, section 9's milestone order and versions, and section 11 "Whether the Discourse-specific features stay long term" |
| [docs/wukongmind/design-m1.md](design-m1.md) | Add note | The decision that "the agent is a fourth mode of the assistant panel" is superseded. The tool rows, status line, Stop button and script card designs still hold |
| [docs/wukongmind/design-m2.md](design-m2.md) | Add note | Where the script manager is entered from follows the unified design; the rest still holds |
| [docs/wukongmind/m0-module-map.md](m0-module-map.md) | Add note | Mark as a historical document. "Keep the forum agent untouched" and "a separate third model role for the browser agent" are superseded; the file-level change lists for M3 and M4 remain useful references |
| [AGENTS.md](../../AGENTS.md), [m0-csp-and-worlds.md](m0-csp-and-worlds.md), [flaky-tests.md](flaky-tests.md) | Unchanged | |

**Design revisions (`design-unified.md` and artboards)**

| Part | Action |
|---|---|
| Target menu (`send-to Menu`) | Delete. Affects the panel artboards, `QuickRowCheck` and the glossary |
| Shared-result pills (`shared results`) | Delete. Affects `PhoneResearch`, spec section 1 and the glossary |
| Title and model pill follow the target | Delete. Title is fixed as Agent; the model pill shows only the Agent's model |
| Quick-action row (`run-now row`) | Replace with the suggestion row, redrawn per section 4's rules, including how it looks on an ordinary web page and on an unfamiliar forum |
| Result styles in the conversation | Keep the summary card, answers with numbered sources, and the podcast row. State that they are now how Agent tool results are displayed |
| Microphone | Keep. Add behavior across the two stages; see "One panel" and "One loop" in section 7 |
| Settings › Models | Change roles to two — Agent and Summary — plus a placeholder for M4's script model |
| Settings › Sites | Remove the separate settings page entries for Research and Summaries & chat; fold any options still needed into Agent or Models |
| `This page` popover | Keep. Add a placeholder for the site inspector under developer mode |
| Placeholders in the information architecture diagram | Remove "End state · send-to button goes" and "Later · Voice drives the Agent"; replace with section 7's milestones |
| Keyboard-up state | Add an artboard specifying how the status line and suggestion row collapse while typing |
| "Assistant panel" section of the migration list | Rewrite per the disposition table in section 6 |
| Start page, onboarding, remaining settings pages, motion | Unchanged |

**Tasks**

- Task 15 (unified interface design): do not accept against draft 2; revise per the table above before showing the owner again.
- Tasks 10, 11 (M2) and task 14 (flaky tests): continue as planned, unaffected.
- Do not split tasks yet for any milestone after "One panel".

**Current status (verified when writing this document)**

- `next-phase.md` is already on `main` (PR #15 merged); replace it directly on `main`.
- `design-unified.md` is still on task 15's branch and in PR #16, not yet merged. Apply the revisions directly in that PR.
- The briefs for tasks 14 and 15 cite section numbers from the previous `next-phase.md`; map them using the table below.

| Previous section | Where it is here |
|---|---|
| 1 Answers to the agent's questions | Section 9 |
| 2 Design direction | Sections 3 and 5 |
| 3 Unified interface design | Section 2's revision table and sections 3 and 4; item 1 of the six directions becomes "One input box plus suggestions" |
| 4 Page tools and WebMCP | Section 5 |
| 5 Milestones | Section 7 |
| 6 Not doing for now | Section 10 |
| 7 Open questions | Section 11 |

## 3. Six product rules

Test every design and implementation choice against these six rules. When unsure, ask: does the user have to learn this?

- **One input box.** Every page has only one input box and one microphone — no modes, no target switching.
- **Suggestions are just shortcuts for asking.** Every suggestion above the input box is a sentence the user could have asked on their own. There are no greyed-out or disabled states: if it applies, it appears; if it doesn't, it doesn't appear.
- **Learn on the spot when needed.** When visiting a site with no ready-made tools, the Agent explores on its own, writes a tool, verifies it and saves it, then says in the conversation, "Saved — faster next time." The user never has to say "go learn".
- **Everything saved lives in one place.** Scripts and tools saved for each site live in `This page`, where they can be viewed and switched off.
- **Failures are explained in the conversation.** When something cannot be done, the Agent explains why in a sentence or two rather than expressing it through UI states.
- **Everything hidden from the user is visible in developer mode.** See section 8.

The user only ever has to learn two things: ask whenever you need something; and what it saved for this site is visible in `This page`.

## 4. End state

Opening the app shows the browser start page. Entering any web page shows one input box and one microphone at the bottom, with a row of suggestions above it.

**Suggestion row**

| Where the user is | Suggestions shown |
|---|---|
| Forum thread | Summarize this thread and replies · Read it to me · Search this forum… · Notify me on new replies |
| Forum list page | What's worth reading today · Search this forum… |
| Ordinary web page | Summarize this page · Switch to dark mode · Remove distractions |
| Frequently visited site | Also shows things the user has asked here before, plus questions matching tools saved for this site |

Suggestion rules:

- Each suggestion is a complete question; tapping sends it at once. Suggestions with an ellipsis (`…`) fill in half the sentence and wait for the user to finish it.
- Typing or speaking the same thing directly must have the exact same effect.
- Four sources: built-in by page type, matching tools saved for this site, previously asked by the user on this site, and matching the site's own WebMCP tools.
- At most four visible on screen at once; extras scroll horizontally.
- Suggestions still appear on unfamiliar forums. The first time the user taps "Summarize this thread", the Agent learns first and then answers.

**Conversation**

- Every result lives in the same conversation, produced by the same Agent, which remembers earlier context. "Summarize this first, then look up the model mentioned in point 2, then highlight it on the page" is three consecutive sentences without switching anything.
- Result rendering reuses Forumind's mature styles: a summary is an expandable card, a search answer carries numbered sources, and a podcast has a playback bar. These are how tool results are displayed.
- Each tool-call step shows as a single line by default and can be expanded.

**What persists**

- `This page`: scripts and tools saved for this site, with switches.
- Start page: frequent sites, recent items, `Today` daily digest.
- Notifications when followed threads get new replies.
- History: all conversations and results.

**Three scenarios**

- News site: tap "Remove distractions"; the Agent cleans up the page and asks whether to always do this, saving it as a script once agreed.
- Unfamiliar forum: tap "Summarize this thread and replies"; the Agent says "Let me see how to read this site first", delivers the summary in about half a minute and saves the tool. The second time, the result comes straight out.
- Discourse forum: say "What do people here think of the N100, and read it to me"; the Agent searches the whole site, reads the relevant threads, gives an answer with numbered sources, and then generates a podcast.

## 5. Architecture

One loop, one set of tools, one file directory. Keep the loop thin and the tools few and general; leave the rest to the model and the prompts.

**One loop**

The sole agent loop is M1's `BrowserAgent`, using native tool calling. Both text input and suggestions enter this single loop; there is no second text agent loop. Voice sessions are an exception: they are driven by a real-time voice model that calls tools itself. Rather than keeping its own separate set of tools, it shares the same tool definitions with the Agent and can hand multi-step requests off to the Agent.

**Four sources of tools, merged into one list**

| Source | Examples | When present | Trust |
|---|---|---|---|
| Built-in | `run_js`, `read_page`, `http_request`, file read/write | Always | Trusted |
| Built-in adapters | Read thread, search, list latest — implemented by the Discourse, WordPress and Hacker News adapters | When the current site is recognized by an adapter | Trusted |
| Capabilities | Summary, read aloud as podcast, send notification, follow | Always; accept text, files or a thread reference | Trusted |
| Page tools | Registered by scripts (written by the Agent or imported by the user), or registered by the site itself | When registered on the current page | Script tools belong to the user; site tools are untrusted |

**Page tools use the WebMCP shape**

- [WebMCP](https://webmachinelearning.github.io/webmcp/) is a draft from the W3C Web Machine Learning Community Group that lets web pages register tools in JavaScript for AI agents to call. The entry point is `document.modelContext`; each tool has a name, description, input and output JSON Schemas, an execute function and a few annotations.
- A tool the Agent writes for a site is simply a script in `ScriptStore` that calls the registration interface. No new storage or file format is added.
- 悟空 injects an implementation of `document.modelContext` into the page (while also catching the older `navigator.modelContext` entry point), so tools shipped by websites themselves work too. No browser on iOS supports WebMCP today.
- Site tools register in the page world, while Agent-written scripts run in the isolated world by default, so the bridge layer must collect from both sides. How to move the page world's registry safely into the isolated world gets a small verification spike before implementation, modeled on M0's CSP verification ([m0-csp-and-worlds.md](m0-csp-and-worlds.md)).
- Tool names get a source prefix; site tools cannot collide with built-in tool names. Site tools' descriptions and return values are handled as untrusted content.
- A tool's "has consequences" annotation hooks into the existing "Confirm before writes" switch, which stays off by default.
- The spec is a draft and its interface has changed once already. Keep the implementation thin, concentrated in one file, with a switch that can turn it off wholesale.

**Two data shapes, hardcoded**

Solely to give capabilities like summary and podcast stable inputs, two shapes are agreed on:

| Shape | Required fields | Produced by | Consumed by |
|---|---|---|---|
| Thread | Title, link, posts; each post has post number, author, body | Read-thread tools | Summary, podcast, Agent |
| List | Items; each item has title, link | List-latest, search | Agent, daily digest |

- Keep required fields as few as possible; everything else is optional (timestamp, like count, reply-to relation). Field names follow the three adapters' existing models as closely as possible.
- No shape registry and no extensible capability declarations. Discuss a third shape only when a real need appears.
- Once a tool returns data matching a shape, the corresponding suggestions can appear on that site.

**Research becomes prompt instructions**

What was valuable in the old Research loop is its rules: how to search, how much to read, how to cite sources. Those become a passage of instructions appended to the Agent's system prompt whenever forum tools are present. The numbered-source display component stays.

**Background features bypass the Agent**

Daily digest and follow notifications continue calling the three built-in adapters directly on a background schedule without invoking the agent loop. They are available only for the three built-in forum kinds; sites learned by the Agent have no background features for now.

**Site state is recorded internally only**

Each site records the status of each of the two shapes: learned, tried and failed (with reason), not applicable, or untried. These states decide which suggestions to show and avoid retrying things already known not to work. Not shown in the user interface; visible in developer mode.

## 6. Where every existing piece goes

From today's code to the end state, most pieces are kept and wired differently; only two things are truly deleted.

| Existing piece | Code location | Disposition | Milestone |
|---|---|---|---|
| Browser Agent loop, tool registry, page bridge | `BrowserAgent`, `ToolRegistry`, `AgentBridge` | Becomes the sole loop, unchanged | Existing |
| Script storage | `ScriptStore` | Unchanged; later also stores scripts that register tools | M2 |
| Three site adapters | `Sites/Discourse`, `WordPress`, `HackerNews` | Code unchanged. Read thread, search, list latest and search comments are wrapped as Agent tools | One loop |
| Summary engine, including cache and summarizing new replies only | `SummaryPanel`, summary parts of `AppModel` | Processing logic unchanged, wrapped as a tool; the summary card renders the tool result | One loop |
| Podcast and speech synthesis | `Podcast/` | Unchanged, wrapped as a tool | One loop |
| Followed threads | `WatchSupport` | Unchanged, plus a tool entry point | One loop |
| Old Research loop | `AgentEngine` (`AgentPlanner`, `AgentActionParser`, `AgentPrompt`), `AgentPanel`, `AgentToolName` | Deleted. Rules become prompt instructions; the source citation display component stays | One loop |
| Topic chat engine | `sendChat`-related code in `AppModel` | Deleted; replaced by the Agent plus thread-reading tools | One loop |
| Voice session | `Voice/` | Audio and transport unchanged. `VoiceToolBridge` currently calls voice's own set of tools (search, open thread, turn page, filter posts); those tool implementations merge into `ToolRegistry` | One loop |
| Daily digest, follow notifications | `DailyDigest`, `WatchSupport` | Unchanged; continue using the adapters directly in the background | Unchanged |
| Four modes of the assistant panel and their views | `AssistantMode`, `SummaryPanel`, `AskBox`, `AIDrawer` | Merged into one conversation view plus a suggestion row. Both containers — drawer and sidebar — stay | One panel |
| Model roles | `ModelRole` | Reduced from three to two: Agent, and the model used for summaries | One loop |
| Apple Intelligence | `AppleIntelligence*` | Does not support tool calling and cannot be the Agent model. Kept for summaries | One loop |
| Each adapter's voice and discussion descriptions | `VoiceSiteProfile`, `DiscussionProfile`, `AgentSiteProfile` | Their wording folds into the instructions appended to the Agent | One loop |
| App Store review, consent and listing code | See section 9 | Deleted | Cleanup |

Until "One loop", every item marked "One loop" in the table keeps running as it does today.

## 7. Milestones

Run in order. Every finished step leaves a working, usable app, and the next step starts only after acceptance. Task splitting follows the current pattern: design task, implementation tasks, acceptance task — and the acceptance task bumps the version number and asks the owner before tagging.

| Order | Milestone | Version | Compared with v1 |
|---|---|---|---|
| In progress | Fix flaky tests (task 14) | No release | Unchanged |
| In progress | Unified interface design (task 15) | No release | Revise per section 2 |
| In progress | M2 persistence (tasks 10, 11) | 1.1.0 | Unchanged |
| 1 | Cleanup | 1.1.x | Unchanged |
| 2 | One panel | 1.1.x | Was "Unified interface (implementation)", simplified |
| 3 | M3 full abilities | 1.2.0 | Adds task export and raw request inspection |
| 4 | One loop | 1.3.0 | New; was under "Not doing for now" |
| 5 | M4 self-extension and Tampermonkey compatibility | 1.4.0 | Scope unchanged; version moves from 1.3.0 to 1.4.0 |
| 6 | Trial | No release | Unchanged |
| 7 | Learn on ask | 1.5.0 | Merges old M5 and M6 |

**M2 persistence (1.1.0)**

Finish per the original requirements and [design-m2.md](design-m2.md), adding nothing.

**Cleanup (1.1.x)**

Four independent tasks; see section 9.

**One panel (1.1.x)**

The UI takes its final shape without changing a single line of the engines.

- Preconditions: the revised unified interface design is confirmed by the owner, and cleanup is done.
- Deliver: one conversation view plus the suggestion row, replacing the four modes; start page; settings grouped by object; three-step onboarding; `This page` popover; unified vocabulary.
- Transitional routing: on the three built-in forum kinds, tapping "Summarize this thread" calls the existing summary engine directly, tapping "Read it to me" calls the existing podcast, tapping "Search this forum…" and completing the query calls the old Research loop, and tapping "Notify me on new replies" calls the existing follow feature. Everything the user types directly goes to the Agent.
- Microphone: dictation only in this stage, turning speech into text in the input box. Dictation is a new feature not in the codebase today; implement it with system speech recognition and add the corresponding permission description. The existing forum voice-session entry stays in place untouched.
- Topic chat has no entry point in this stage. Questions the user asks about a thread go to the Agent, which answers by reading the current page with `read_page`.
- Known inconsistency: tapping the suggestion "Search this forum" works well, while typing the same question goes to an Agent that does not yet have forum tools and works poorly. This disappears once "One loop" finishes and is accepted during this stage.
- Acceptance: forum pages and ordinary web pages show the exact same panel and input box, differing only in suggestions; there is no mode or target switcher anywhere in the UI; every setting appears in only one place; summary, search, podcast, follow, daily digest and voice all still work.

**M3 full abilities (1.2.0)**

The planned tools are unchanged: screenshot, network log, navigation, multiple tabs, HTTP requests, cookies, audit log. Additions:

- Workspace: one directory and three tools — `file_read` (supports range reads), `file_write`, `file_list`. Tool results exceeding the truncation limit are automatically saved as files, and the model receives the path, a preview and the total size. The directory is visible in the system Files app. Directory layout is agreed on only in the prompt, not written into code.
- Developer mode part 1: switch, raw request and response inspection, per-step token counts, and task export. See section 8.
- Acceptance (added): crawl a thread of 20+ pages, with raw content landing in the workspace and the summary covering every page; kill and reopen the app mid-task and the files are still there; an exported task file can be replayed by unit tests.

**One loop (1.3.0)**

The highest-risk step on the entire roadmap. Never reverse the order: prove quality does not regress before deleting old code.

- Register the three adapters' read-thread, search, list-latest and search-comments operations as Agent tools, reusing the existing tool names in `AgentToolName` and implementations in `executeAgentTool`, returning the two shapes from section 5. Long thread content lands in the workspace.
- Register summary, podcast, follow and notification as capability tools. The summary tool reuses the existing engine and cache, and renders its result with the existing summary card.
- Write the old Research rules as prompt instructions appended to the Agent whenever forum tools are present. Connect the numbered-source display component to the Agent's answers.
- Comparison test: prepare a set of questions on test data across the three forum kinds, answer them with both old Research and the new Agent, and record the runs. Move to the next step only after the owner compares them by hand and approves. Report token consumption on both sides at the same time.
- Change suggestions to simply send the question text, dropping transitional routing. Delete the old Research loop and the Topic chat engine. Reduce model roles to two.
- Connect voice sessions. Merge voice's existing tools (search, open thread, turn page, filter posts) into the same tool registry so voice and text share one set of tool definitions; add a "hand off to Agent" tool to the voice model to handle multi-step requests. Settle the exact design in this milestone's design task, and run a small verification spike before implementing. Once complete, the microphone can enter a voice session, each voice turn enters the same conversation, and spoken requests can drive the Agent on any web page.
- Acceptance: on a Discourse forum, type or say "Summarize this thread first, then check what other people on this forum say about point 2, then read it to me" — completed in one run, with clickable source citations in the answer.
- Acceptance: tapping a suggestion and typing the same question directly produce comparable result quality.
- Acceptance: only one loop remains for the text Agent, sharing the same tool definitions with voice; saying "Switch to dark mode" by voice on an ordinary web page takes effect; daily digest and follow notifications are unaffected.
- Known cost: Apple Intelligence users lose site-wide search Q&A and keep summaries only.

**M4 self-extension and Tampermonkey compatibility (1.4.0)**

Original plan unchanged: GM API subset, importing scripts from a URL, handing script errors to the Agent to fix, and including scripts in iCloud sync. Add `GM_ai(prompt, optional return format)` so scripts can call a model at run time, defaulting to the Summary model role.

- Acceptance (added): have the Agent write a script that, on a thread page, uses `GM_ai` to judge whether each post has substance and folds those that don't; it still takes effect after reloading.

**Trial (two weeks, no release)**

The owner uses 1.4.0 daily and exports any task the Agent cannot do, does slowly, or spends too many tokens on. The deliverable is an issue list in `docs/wukongmind/trial-notes.md` together with the exported files. During the trial, the orchestrator handles only defects the owner reports. Confirm the scope of "Learn on ask" against this list before splitting tasks.

**Learn on ask (1.5.0, direction)**

- Trigger: when the user's question needs to read a thread or a list and the current site has no matching tool, the Agent starts learning on its own. There is no dedicated "Learn" button, and nothing runs automatically on page open.
- Learning process: look for data sources in priority order — the site's own JSON API, preloaded page data, then the DOM — write a tool-registering script, and record findings in site notes in the workspace.
- Verification: the app calls the new tool with real arguments and validates the return value against section 5's shapes; only if it passes is it saved and marked learned. If it fails, record the reason and explain it in the conversation.
- Invalidation: when a saved tool errors at run time or its return value no longer matches the shape, its status rolls back and the Agent automatically re-learns next time it is needed, reusing M4's repair mechanism.
- Page-tool infrastructure: `document.modelContext` injection, bridge into the tool list, source prefixes, untrusted marking. Websites' own WebMCP tools work the same way.
- Suggestions: learned sites show the matching suggestions.
- Developer mode part 2: site inspector and tool dry-run.
- Acceptance: on a forum that is none of the three built-in kinds, tap "Summarize this thread and replies"; the first time, the Agent learns first, answers, and notes that it was saved; the second time, on another thread, it gives the summary in at most two tool calls; "Read it to me" works too.
- Acceptance: on a test page with its own WebMCP tools, the tools appear in the Agent's list and can be called; when a tool's description contains instructions, the Agent does not execute them.
- Acceptance: break a saved tool by hand; on the next question, the Agent detects and repairs it.
- Out of scope: learned sites have no daily digest or follow notifications.

## 8. Developer mode

One set of data at two densities: the default UI shows one line per step, while developer mode lays out everything underneath. The switch lives in Settings › Agent, off by default; while off, none of the developer-mode entries below appear.

| What is shown | Question it answers | Milestone |
|---|---|---|
| Each tool call's arguments, result and duration | What did it do | Existing (M1); does not require developer mode |
| Full request sent to the model and raw response, including system prompt and tool definitions | Why did it decide that | M3 |
| Per-step tokens and model used | Where did the cost go | M3 |
| Task export | Hand the exact run to an implementation agent | M3 |
| Audit log, workspace files | What happened historically, and what are the intermediate results | M3; does not require developer mode |
| Page console output and network requests | Is it a page problem or a tool problem | M3 |
| Site inspector: currently registered tools and their sources, status and failure reasons for both shapes, learning log, last validation result | What can this site do, and why not | Learn on ask |
| Tool dry-run: fill in arguments by hand to call one tool, inspect raw return value, re-run validation | Does this tool work on its own | Learn on ask |

**Task export requirements**

- One task exports as a single JSON file containing every turn's full request, raw response, tool calls and results, page URL, and app version, shared via the system share sheet.
- The format must be directly replayable by the existing recorded-response mechanism in unit tests (`RecordedModelClient` in `AgentLoopTests`), turning a failed task straight into a regression test.
- API keys and cookies are not written to the exported file. Page content is written; prompt once before exporting.

## 9. Handling old code

This section carries over from v1; only category 4's role changed.

| Category | Decision | Notes |
|---|---|---|
| 1. Restrictions and compliance added for App Store review | Delete | Delete AI data consent, terms acceptance and content blocking. Keep per-forum rate limiting as a switch in Settings that can be turned off. The safety baselines in requirements section 8 stay unchanged |
| 2. Things prepared only for the App Store listing | Delete | `appstore/`, `mobile-site/`, `moderation/` and the listing steps in `fastlane`. Keep the TestFlight release flow |
| 3. Names still saying Forumind | Rename | Rename the project, targets, schemes, directories and tests as step 3 of cleanup. Keep the "derived from Forumind" statement in `NOTICE`; keep the `forumind` remote read-only |
| 4. Forum features | Keep capabilities, change wiring | Leave them untouched during cleanup. Per section 6, turn them into Agent tools in "One loop", and delete the old Research loop and Topic chat |

**Four cleanup tasks, in order, each shipping a 1.1.x**

- Delete review restrictions and compliance flows; make rate limiting a switch in Settings.
- Delete listing-only directories and flows; keep TestFlight releases.
- Rename the project, targets, directories and tests to WukongMind.
- Remove CI's automatic retries and `CI`-based skips.

**Where cleanup most easily breaks things**

Content moderation code is embedded inside the adapters, e.g. `DiscourseDOM.moderationInstaller` and `SiteCapabilities.postIdentity`. When deleting it, make sure the `SiteAdapter` protocol, the three adapters' read paths and the page bridge are unaffected — "One loop" uses them directly.

**Cleanup is done when**

- CI removes `-retry-tests-on-failure`, and no test is skipped based on the `CI` environment variable.
- Tests of deleted features are deleted with them; remaining flaky tests are fixed rather than quarantined further.
- `Forumind` cannot be found anywhere in the repo as an identifier, except where docs describe the project's origin.
- Manual smoke tests of summary, site-wide search Q&A and podcast pass on all three adapters.

## 10. Not doing for now

The designs below were all considered, and no real problem drives them today. Do not implement them early, and do not reserve interfaces for them.

| Item | Why deferred | When to reconsider |
|---|---|---|
| Background daily digests and follow notifications for learned sites | Requires running scripts with no page open and making the site registry mutable at run time | When the trial brings a real wish to turn on a daily digest for a new site |
| A third or further data shapes (articles, products, videos), a shape registry, extensible capability declarations | Two shapes cover every existing feature | When more than two sites and at least one feature all need the same new shape |
| Unified abstraction for write actions (reply, like, place order) | The Agent can already do them with `run_js`; no reuse need | When the same kind of write action recurs across multiple sites |
| Dedicated design for cross-site Q&A | With multiple tabs and one loop, the Agent may handle it directly | Try it once after "One loop" finishes; revisit only if it falls short |
| Scheduled watching of arbitrary content changes | Needs scheduled background execution, which iOS restricts heavily | When a concrete need appears during the trial |
| Dedicated fast-judgement model role | `GM_ai` with a return format is enough | When `GM_ai` speed or cost becomes a real problem |
| Using a model to screen web pages for prompt injection | No real problem observed | When exported tasks show a record of the Agent being steered astray by a page |
| Connecting to websites' backend MCP servers | Must handle login authorization and overlaps with page tools | When a frequently used site provides only a backend MCP |
| Automatically exploring a site on page open | Spends tokens and goes unused on most pages | No plan to reconsider |

## 11. Open questions

These items need the owner's decision; until answered, follow the default in parentheses.

- After "One loop", Apple Intelligence users lose site-wide search Q&A. (Default: accept.)
- In the "One panel" stage the microphone does dictation only, entering voice sessions only after "One loop". (Default: yes.)
- In the "One panel" stage Topic chat temporarily has no entry point. (Default: accept.)
- How many questions to use in the "One loop" comparison test. (Default: 5 per forum kind, 15 in total, drafted by the implementation agent and confirmed by the owner.)
- Whether the rename includes source directories and Xcode targets. (Default: rename everything.)
- How to handle `PRIVACY.md`, `TERMS.md` and `SECURITY.md`. (Default: delete `TERMS.md` along with the terms-acceptance flow; rewrite the other two as short versions suited to a self-use open-source project.)
- Whether the trial runs for two weeks. (Default: yes.)
- Which forum to use for "Learn on ask" acceptance. (Default: at the end of the trial, the owner picks a frequently visited forum that is none of the three built-in kinds.)
- How voice connects to the Agent. (Default: the voice model directly calls fast tools in the shared tool registry, plus a "hand off to Agent" tool for multi-step requests; confirmed after verification in the "One loop" design task.)
