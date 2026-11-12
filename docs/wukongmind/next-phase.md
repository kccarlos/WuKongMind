# WukongMind next phase: old code and milestone plan

*2026-11-12, owner. English translation of the owner's doc "WukongMind 下一阶段：老代码处理与里程碑规划".*

**Precedence.** This document supplements [requirements.md](requirements.md). Where it conflicts with the requirements or with [README.md](README.md), this document wins. That includes the rule "Forumind's existing features and tests must keep passing": when the cleanup deletes a feature, its tests are deleted with it.

The forum features stay, but they are no longer "legacy code": they are built-in implementations and the outlet for native capabilities. Cleanup comes after M2 and before M3. After M4, the direction is for the agent to turn what it learns about websites into page tools shaped like WebMCP.

Also: the UI was added piece by piece, milestone by milestone, and does not hang together. Before adding more UI, the whole app gets one unified design pass (section 3).

## 1. Answers to the agent's questions

**Question 1: do the forum features stay long term? Yes.**
- The `SiteAdapter` protocol under `Forumind/Sites/` already separates "reading a site" from "doing things with its data". The Discourse, WordPress and Hacker News adapters are the highest-quality built-in implementations; keep them as they are.
- Summary, chat, site-wide Q&A, daily digest, podcast, voice and followed topics are what set Wukong apart from other browser agents: the data the agent gets can do more than answer in a chat. It can be read aloud, summarized daily, and trigger a notification when it changes.
- So they are not legacy code. Under the plan in section 5, M6 opens these capabilities to any website.

**Question 2: is cleanup after M2 and before M3 OK? Yes.**
The one exception is the flaky tests: they slow CI down now, so fix them right away as separate work, without waiting for the cleanup milestone.

**Decisions on the four kinds of old code**

| Kind | Decision | Notes |
|---|---|---|
| 1. Restrictions and compliance added for App Store review | Delete | Delete AI data consent, terms acceptance and content blocking. Keep per-forum rate limiting as a switch in Settings that can be turned off. The safety baselines in requirements section 8 stay unchanged |
| 2. Things that exist only for the App Store listing | Delete | `appstore/`, `mobile-site/`, `moderation/` and the listing steps in fastlane. Keep the TestFlight release flow: the owner installs through it |
| 3. Names still saying Forumind | Rename | Project, targets, schemes, folders and tests all renamed. Last step of the cleanup, since the first two steps shrink what has to change. Keep the "derived from Forumind" statement in `NOTICE`; the `forumind` git remote stays read-only |
| 4. Forum features | Keep | See question 1 |

**Where cleanup most easily breaks things**
Content moderation code is embedded inside the adapters, e.g. `DiscourseDOM.moderationInstaller` and `SiteCapabilities.postIdentity`. When deleting it, make sure the `SiteAdapter` protocol, the three adapters' read paths and the page bridge are unaffected: they are the foundation of later milestones.

**Cleanup is done when**
- CI no longer uses `-retry-tests-on-failure`, and no test is skipped based on the `CI` environment variable.
- Tests of deleted features are deleted with them; the remaining flaky tests are fixed rather than quarantined further.
- `Forumind` cannot be found anywhere in the repo as an identifier, except where docs describe the project's origin.

## 2. Design direction

Wukong is essentially an agent harness: one loop, a set of tools and a file directory, running on web pages and JavaScript. The principle: keep the loop thin and the tools few and general; leave the rest to the model and to files.

**Three layers of capability**

| Layer | What it is | Character | Status |
|---|---|---|---|
| 0 | Bare `run_js` | Works on any site, but explores from scratch every time: slow and token-hungry | Done in M1 |
| 1 | Saved JS | The agent saves what it figured out and reuses it next time | Half in M2, the other half in M5 |
| 2 | Native capabilities | Summary, read-aloud, notifications, daily digest; they consume layer 1's output | Exist, but serve only three kinds of site; opened up in M6 |

Generality comes from layer 0 always being the fallback; power comes from layer 1 accumulating. The quality Forumind bought by researching site APIs by hand becomes the agent doing that same research once per new site, then saving it.

**Layer 1 is one kind of thing with two uses**
Everything saved is a script in ScriptStore; no new storage or file format.
- **Scripts that change the page**: run on page load and change how it looks or behaves. This is what M2 is building.
- **Scripts that register tools**: run on page load but don't change the page; they only register a few functions for the agent to call. M5 adds these (section 4).

**Rule against over-design**
Every addition must point to a real task that failed without it. So after M4 there is a two-week trial, and the scope of M5 and M6 is confirmed after the trial from the problems actually met; what this document says about them is direction only.

## 3. Unified interface design

The UI was added to Forumind's shell one milestone at a time. Each piece looks consistent, but nobody has designed the app as a whole as "a general browser". Before adding more UI, do one whole-app design.

**Where it falls apart**

| Symptom | Where |
|---|---|
| The assistant panel has four modes: summary, chat, site-wide Q&A, browser agent. Forum pages show four, other pages only one | `AssistantMode` has `summary`, `chat`, `agent`, `browserAgent` |
| Two things are both called agent, each with its own loop, tools and step display | `AgentEngine` vs `BrowserAgent`, `AgentToolName` vs `ToolRegistry` |
| Browser agent settings sit in the "site-wide Q&A" row; the M2 design puts script management under "Reading" | `SettingsPage.agent`, `design-m2.md` |
| Home, onboarding and the bottom Dock all center on "add a forum", though the app is now a general browser | `HomeView`, `Onboarding`, `Dock` |
| Default models have three roles, spread over different settings pages | `ModelRole` |
| Design tasks were split by milestone (M1 design, M2 design); no task looked at the whole | Tasks 7 and 8 |

**Direction**
This is the starting point for the design task, not the final answer. The design task may propose something better, but must answer these six points.
1. **One assistant, one input box.** The same panel and input box on every page, agent by default. Summary, podcast and site-wide Q&A stop being parallel modes and become quick actions above the input box, shown only when the current page supports them.
2. **Capabilities follow the page.** What the current page can do is visible in one place: active scripts, available tools, whether it can be summarized or listened to. The M1 design's "N scripts on this page" row grows into this entry point.
3. **Home is the browser's start page.** Address bar, frequent sites, recent tasks. Forums are just one kind of site, marked as having extra capabilities, no longer how home is organized.
4. **Settings grouped by object.** Models (all roles on one page), Agent (steps, confirm switch, audit log, workspace), Scripts and tools, Sites (forums, rate limiting, ad blocking), Voice and podcast, Sync, Data.
5. **One vocabulary.** Only one thing is called Agent. "Site-wide Q&A" gets a name without "agent". Script, tool and site mean the same in the UI, the docs and the code.
6. **Onboarding rewritten.** Pick a model, open a site, try the agent once: three steps and done.

**Unifying the UI does not require unifying the engines**
What is unified is what the user sees. The panel's "site-wide Q&A" quick action can keep calling the old forum loop; merging the two engines stays deferred (section 6).

**Design task deliverables**
- An information architecture diagram: which screens the app has and how they reach each other.
- A set of artboards covering the whole app, iPhone and iPad, light and dark.
- A migration list: for every existing screen, keep, merge, move or delete.
- A glossary.

**Constraints**
- Keep the existing styles in `DesignSystem.swift`; no new visual style. This changes structure, not looks.
- Implement only after the owner confirms the design.
- Finish M2's remaining UI tasks to their current design without rework; repositioning waits for the unified design's implementation.
- From then on, each milestone's design task takes this whole-app design as its base, draws only the increment, and says where new screens sit in the information architecture.

## 4. Page tools and WebMCP

Layer 1's "functions for the agent to call" use the tool shape of [WebMCP](https://webmachinelearning.github.io/webmcp/) rather than a format of our own.

**What WebMCP is**
A draft from the W3C Web Machine Learning Community Group that lets web pages register tools in JavaScript for AI agents to call. The entry point is `document.modelContext`. Each tool has a name, a natural-language description, JSON Schemas for input and output, an execute function and a few annotations (read-only, has consequences, contains untrusted content).

**Why use it**
- It has the same shape as "callable functions the agent writes"; only the source differs (one comes from the site, one is added on the user's side). With one shape, both sources go into the same list.
- Only Chrome and Edge are experimenting with it; no iOS browser supports it. If Wukong injects its own implementation, it can call sites' own tools on iOS.
- It is a public spec, so as more sites ship their own tools, Wukong needs no change.

**Three sources of tools, one list**

| Source | Written by | Trust |
|---|---|---|
| Registered by the site | The site's developer | Untrusted: name, description and results may carry injected instructions |
| Registered by a script | Generated by the agent, or imported by the user | The user's own; viewable and editable |
| Built in | The app (`run_js`, `read_page` and the rest) | Trusted |

**Technical points**
- Inject an implementation of `document.modelContext` at document start. The spec moved the entry point from `navigator.modelContext` to `document.modelContext`; support both.
- Site tools register in the page world; agent-written scripts run in the isolated world by default (per M0's findings). So there are two registries and the bridge must collect from both. The page world cannot reach the message channel directly (requirements section 8); how to move the page world's registry safely into the isolated world gets a small spike in M5's design task, modeled on M0's CSP verification.
- Tool names get a source prefix; site tools can never take a built-in tool's name.
- Site tools' descriptions and results are untrusted content, wrapped in requirements section 8's delimiters.
- A tool's "has consequences" annotation hooks into the existing "confirm before writes" switch, which stays off by default.
- Refresh the tool list the agent sees on page load, route change, and when tools are added or removed.

**Tool-writing guide for the agent (an M5 deliverable)**
- Data source priority: the site's own JSON API first, then data embedded in the page, and only then parsing the DOM.
- Return only the fields needed to answer the question; turn HTML into plain text.
- Paginate with a cursor: one page per call, saying how to get the next.
- Name reads and writes separately and annotate them correctly.
- After writing a tool, call it once with real arguments and check the result answers the user's question directly.

**Risks**
- The spec is a community group draft, not on the standards track, and its interface has already changed once. Keep the implementation thin, in one file, with a switch that turns it all off.
- Few sites ship their own tools yet. M5's main value comes from tools the agent writes; site tools are a bonus.

## 5. Milestones

In order; each starts after the previous one is accepted. Tasks are split as now: milestones with UI start with a design task, then implementation tasks, and end with an acceptance task that bumps the version and asks the owner before tagging.

| Order | Milestone | Version | Status |
|---|---|---|---|
| Now | Fix flaky tests | No release | New, start at once |
| Now | Unified interface design (design only) | No release | New, in parallel with M2 |
| 1 | M2 persistence | 1.1.0 | In progress, unchanged |
| 2 | Cleanup | 1.1.x | New |
| 3 | Unified interface (implementation) | 1.1.x | New |
| 4 | M3 full abilities | 1.2.0 | As planned, one revision |
| 5 | M4 self-extension and Tampermonkey compatibility | 1.3.0 | As planned, one revision |
| 6 | Trial | No release | New, two weeks |
| 7 | M5 page tools | 1.4.0 | New, scope confirmed after the trial |
| 8 | M6 capability outlet | 1.5.0 | New, scope confirmed after the trial |

**Now: fix flaky tests**
- Deliver: fix the tests listed in `docs/wukongmind/flaky-tests.md` one by one. Tests of features the cleanup will delete (content moderation, consent flows) need no fix; mark them as deleted with the cleanup.
- Accept: CI passes 5 runs in a row without retries.

**Now: unified interface design (design only, no code changes)**
- One design task, following section 3, in parallel with M2's implementation tasks; neither blocks the other.
- The design reserves places in the information architecture for screens M3 to M6 will bring: multiple tabs, audit log, workspace, page tool list, capability quick actions. Placeholders only, no detail.
- Accept: the owner confirms the information architecture diagram, artboards and migration list.

**M2 persistence (1.1.0)**
Finish per the original requirements and `design-m2.md`, adding nothing. Tool-registering scripts need no new storage fields, so M2 reserves nothing for M5.

**Cleanup (1.1.x)**
Four independent tasks, in this order, each shipping a 1.1.x:
1. Delete review restrictions and compliance flows (kind 1); rate limiting becomes a switch in Settings.
2. Delete listing-only folders and flows (kind 2); keep the TestFlight release.
3. Rename the project, targets, folders and tests to WukongMind (kind 3).
4. Remove CI's automatic retries and CI-only skips.

Acceptance: "Cleanup is done when" in section 1, plus a manual smoke test of summary, site-wide Q&A and podcast on the three adapters.

**Unified interface (implementation, 1.1.x)**
- Precondition: the unified design is confirmed and the cleanup is done. Onboarding steps, consent screens and moderation UI deleted by the cleanup need no migration.
- Deliver: implement the migration list, split into tasks by UI area; suggested order: assistant panel, settings, home and onboarding.
- Engines untouched: change only UI structure and entry points; the two agent loops, three adapters and data models stay as they are.
- Accept: opening the assistant on a forum page and on an ordinary page shows the same panel and input box, differing only in the quick actions available; every setting appears in exactly one place; summary, site-wide Q&A, podcast and voice all still work.

**M3 full abilities (1.2.0), revision: workspace**
The planned tools are unchanged. File reading and writing becomes:
- One workspace directory and three tools: `file_read` (supports reading a range), `file_write`, `file_list`.
- Tool results over the truncation limit are no longer cut and dropped; they are saved to a file in the workspace automatically, and the model gets the path, a preview and the total size.
- The directory is visible in the system Files app, so the owner can browse it.
- The layout is not in code, only two lines in the system prompt: a task's intermediate files go in `tasks/`, notes about a site go in `sites/<domain>/notes.md`.
- Accept (added): read a thread of 20+ pages; the raw content lands in the workspace and the summary covers every page; kill and reopen the app mid-task, and the files are still there.

**M4 self-extension and Tampermonkey compatibility (1.3.0), revision: `GM_ai`**
The plan is unchanged. Add one GM API:
- `GM_ai(prompt, optional output format)`: lets a saved script call the model at run time, returning text, or JSON in the given format.
- The model is chosen in Settings and follows the agent model by default. Calls count in the audit log and usage.
- Accept (added): have the agent write a script that, on a forum thread page, uses `GM_ai` to judge whether each post has substance and collapses those that don't; it still applies after a reload.

**Trial (two weeks, no release)**
- The owner uses 1.3.0 daily and records tasks the agent can't do, does slowly or spends too many tokens on.
- Deliver: an issue list in `docs/wukongmind/trial-notes.md`.
- M5 and M6 scope is confirmed or adjusted against this list before splitting tasks.

**M5 page tools (1.4.0, direction)**
- Deliver: `document.modelContext` injection; the bridge that brings tools registered on the page into the agent's tool list, with source prefixes and untrusted marking; tool annotations hooked into the confirm switch; the tool-writing guide; the script manager showing which tools each script registers.
- Accept: on a page with its own WebMCP tools (a local test page is fine), the tools appear in the agent's list and can be called.
- Accept: on a forum that is none of the three built-in kinds, say "learn to read this forum"; the agent writes and saves a tool script. In a new conversation, "summarize this thread" gets the full text in at most two tool calls.
- Accept: when a site tool's description contains instructions, the agent doesn't follow them. Covered with a local test page.

**M6 capability outlet (1.5.0, direction)**
- Deliver: turn the existing native capabilities into tools that take text or files, at least `summarize` and `speak`. Recognize by data shape: when a page tool returns a "post thread" (each item with post number, author and body), that page's summary and podcast entries become available; for a "post list", the daily digest becomes available.
- Scripts are not required to implement the `SiteAdapter` protocol, and the site registry doesn't change. The three built-in adapters stay as they are.
- Accept: on the forum used for M5's acceptance, open a thread; the summary panel works and it can be listened to as a podcast.

## 6. Not doing for now

These designs were considered but no real problem drives them yet, so they are deferred. Don't implement them early, and don't reserve interfaces for them.

| Item | Why deferred | When to reconsider |
|---|---|---|
| Scripts implementing the `SiteAdapter` protocol; a site registry that can change at run time | The biggest change; it must solve where JS runs in the background with no page. M6's recognition by shape covers most uses | When new sites should also get background daily digests and follow notifications |
| Merging the old site-wide Q&A loop and the browser agent into one engine (merging at the UI level is not deferred, see section 3) | They coexist fine now; merging is a refactor, not a new capability | When maintaining two loops becomes a burden, or voice needs to drive the browser agent |
| Cross-site Q&A | Depends on M3's tabs and M5's page tools; may need no special design by then | Try it once after M5; revisit if the agent does it poorly |
| Following changes to arbitrary content and notifying | Needs scheduled background runs; iOS limits them heavily | When a concrete follow need comes up in the trial |
| A dedicated fast-judgement model role | `GM_ai` with an output format is enough; switching models is a setting | When `GM_ai`'s speed or cost becomes a real problem |
| Using a model to screen pages for injected instructions | No real attack seen; the existing delimiters and audit log hold for now | When the audit log shows the agent led astray by a page |
| A layered workspace directory, a dedicated site memory system | One directory plus prompt conventions is enough | When there are so many files the agent can't find things |
| Connecting to sites' backend MCP servers | Must handle login and authorization, and overlaps with page tools | When a frequently used site offers only a backend MCP and no page tools |

## 7. Open questions

These need the owner's decision; until answered, follow the default in brackets.
- [ ] Does the rename include source folders and Xcode targets, or only display names and identifiers? (Default: everything.)
- [ ] What happens to public-facing docs such as `PRIVACY.md`, `TERMS.md` and `SECURITY.md`? (Default: `TERMS.md` is deleted with the terms-acceptance flow; the other two are rewritten as short versions suited to a self-use open-source project.)
- [ ] Does the trial run for two weeks? (Default: yes; during it the orchestrator handles only defects the owner reports.)
- [ ] Which model does `GM_ai` use by default? (Default: follows the agent model.)
- [ ] Which forum is used for M5's acceptance? (Default: at the end of the trial the owner names a forum they visit often that is none of the three built-in kinds.)
- [ ] Are section 3's six unification directions agreed, especially "summary, podcast and site-wide Q&A turn from modes into quick actions" and "home no longer centers on forums"? (Default: the design task drafts in this direction; the owner decides after seeing the draft.)
- [ ] Does the unified UI implementation come before M3? (Default: yes; M3's tabs and audit log UI are built directly on the unified structure.)
