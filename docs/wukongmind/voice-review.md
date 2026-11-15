# Voice review: what voice is for in an agent browser

**Status: proposal for the owner. Nothing here is started.** Design only: no app code and no other document changed. Code references are to `main` at `cc3b976` (1.3.0).

The owner tried voice on 1.3.0 (TestFlight 113) and said: "We should re-examine the voice model's positioning; the current design still feels forum-oriented." This page checks that against the code, picks a position, and proposes a redesign.

**The short answer.** The shape of today's voice is right: a fast voice model does small things itself and hands the rest to the Agent. What is wrong is that every fast thing is a forum thing, and the tool list is tied to the page the session starts on. The proposal: one fixed tool set that works on any page, three any-page abilities (go somewhere, move around, listen), and page facts sent as notes. No reconnect is needed.

## 1. What voice is for

### Who uses it, and when

| Situation | What they say | What they need |
|---|---|---|
| Hands busy (cooking, repairing, holding a child) | "Scroll down." "Go back." "Open the recipe site." | The page moves at once. A few words back. |
| Walking or driving, phone in a pocket | "Open Hacker News." "What's this about?" "Read it to me." | To get somewhere and hear it. The screen doesn't help. |
| Reading, eyes on the page | "Summarize this." "What does post 20 say?" "Make it dark." | A short answer while they keep reading. Changes go to the Agent. |

In all three the user can't or won't type. So voice has to cover what the address bar, the back button and scrolling do. Today it covers them only inside a forum.

### The options

| | A. Thin remote for the Agent | B. Voice as its own browsing assistant | C. Hybrid (today's shape, on any page) |
|---|---|---|---|
| What it is | Voice only listens and speaks. Every request is an Agent run. | The voice model gets the Agent's page tools: click, type, `run_js`, `inject_css`. | Voice does a small fixed set of one-call actions itself and hands the rest off. |
| Latency | Slow for everything. Measured Agent runs on `claude-haiku-5-5`: "Make it dark" took 8 s in 4 steps ([check8-simulator.txt](one-loop-acceptance/check8-simulator.txt)); forum research questions took a median of 17 to 63 s ([one-loop-comparison.md](one-loop-comparison.md), Totals). A one-call run such as "go back" was never timed, but it is at least one model round trip more than a direct tool. | Fast: first audio about 0.7 s after a tool result (spike Q1, Q6). | Fast for the common small things, Agent speed for the rest. |
| Cost | One Agent run per sentence. Each run sends the Agent's whole prompt and tool list at every step. A one-call run's tokens were not measured. | Every turn re-bills the whole context, and many more tools raise it. | A few more tool declarations per turn. Agent cost only when needed. |
| Reliability | Best: the Agent looks before acting and checks the result. | Poor for changes: a dark-mode stylesheet written by the voice model passed 0 of 9 times (spike Q5). | Good if the line is drawn well: voice never writes code. |
| Privacy | Audio still goes to Google unless voice becomes dictation plus system speech. Page text goes only to the Agent's provider. | Most page text goes to Google, turn after turn. | As today on a forum topic: the topic brief, the lines on screen and the post in focus go to Google unasked (`VoiceContext`). On an ordinary page, only the title and host go unasked; page text goes only when the user asks, capped at 8,000 characters a result. |

### The pick: C, made page-independent

- A fails the hands-busy user. Even the small measured run took 8 s. A direct tool answers in under a second (spike Q1).
- B was measured and failed (spike Q5). It also sends the most page text to a second provider and gives page text the most ways to steer the model.
- C is already built and measured: routing was right 30 of 30 times on the non-opinion utterances (spike Q3), and the hand-off and briefing work (spike Q4). The design needs widening, not replacing.

It also fits the product rules in [next-phase.md](next-phase.md#3-six-product-rules): one microphone, no modes, and the user doesn't have to learn which pages voice works on.

### The line between voice and the Agent

Voice does a thing itself only when all four hold:

1. **One call.** One tool call answers it.
2. **Undoable.** It is navigation, playback or a read. Nothing is written to a page or a site.
3. **App code does the work.** The model passes a few plain arguments. It never writes JavaScript, CSS or a selector.
4. **It fits.** The result fits in 8,000 characters (spike Q6).

Everything else goes to the Agent through `hand_off_to_agent`.

### What voice should not try to do

- **Change a page.** Dark mode, hiding parts, saving a script. Spike Q5 stands.
- **Click, type, fill forms, sign in, buy, post.** These need looking and checking, which is the Agent's loop.
- **Research.** Anything that needs several pages or threads.
- **Open an address that came from page text.** Voice opens only what the user said. Page text is data, and a page must not be able to send the browser somewhere.
- **Use heavy tools.** Workspace, network, cookies, scripts, screenshots and `notify` stay text-only, as today.

## 2. Gaps in today's design

Each gap is tied to the code. The four facts in the brief hold in the code. One part of them is the owner's observation, not something code can show: what the model actually says to "open bbc.com" (gap 2).

| # | Gap | Evidence |
|---|---|---|
| 1 | **Voice can't go anywhere outside the forum.** There is no voice tool that opens an address. `navigate` exists but is text-only, and it refuses "bbc.com" without a scheme. | `ToolRegistry+Navigation.swift:61` (no `surfaces`, so the default `[.text]` at `ToolRegistry.swift:511`); `:45` "not a full address". The forum voice set is pinned by `VoiceToolTests.swift:357–360`. |
| 2 | **"Open bbc.com" isn't routed.** The instruction sends the hand-off only questions and page changes, and the tool text says the same. Nothing routes it, so the model is left to guess: the owner saw it hand off (an Agent run for one page load) or refuse. This review ran no live session. | `VoiceInstructions.swift:40–45`; `VoiceTools.swift:104–112`. |
| 3 | **"Go back" works only on a forum.** Back and forward are plain browser history, but they sit inside `browse_move`, which is declared only on a forum. | `AppModel+Navigation.swift:506–517`; `ToolRegistry+Browse.swift:79–80` behind the guard at `:124`. |
| 4 | **The tool list is tied to the start page, both ways.** The session declares tools once, for the page it starts on. Start on a forum and move to an ordinary page: forum tools answer "isn't available on this page". Start on an ordinary page and move to a forum: the forum tools were never declared, so they can never be called. The user has to restart. | `VoiceSession.swift:387–407` (declared once; `:403–404`); `VoiceToolBridge.swift:189–198` and `:235–236`; `AppModel+Voice.swift:181–194`. |
| 5 | **A resume can't fix it.** A resume with a new setup keeps the old tool list silently, even a tool the new setup removed. So the "resume with a new setup" idea isn't used, and rightly. | [one-loop-voice-spike.md](one-loop-voice-spike.md) Q2; `VoiceSession.swift:403`. |
| 6 | **On an ordinary page the model is blind.** The silent screen notes are sent only on a forum topic. Off a topic the model gets no title, no site, nothing. | `VoiceContext.swift:107`; `VoiceSession.swift:734–756`. |
| 7 | **"Summarize this" and "read it to me" barely work on an article.** Both tools are declared on an ordinary page, but they need exactly one of a forum `topic_id`, a forum thread `url`, a workspace `path`, or `text`. The bridge fills in the open topic only when there is one. So the voice model has to paste the page text into `text` itself, through an 8,000-character window. | `ToolRegistry+Capabilities.swift:67–87`; `VoiceToolBridge.swift:239–260`; `VoiceToolTests.swift:373–376`. |
| 8 | **The instruction talks forum on every page.** The persona says "usually a forum page". Even the neutral profile is "a reading companion for online forums and discussion sites". The precedence, opinion and grounding rules name forum tools, threads and posts. The language rule is about searching the forum. Transcription vocabulary comes only from the forum and topic names. | `VoiceInstructions.swift:9`, `:26–38`, `:47–52`, `:60–66`, `:99–100`; `VoiceSite.swift:15–19`; `VoiceSession.swift:411–423`. |
| 9 | **Declarations carry site wording.** The search hint, the focus modes and the forum tools' texts are built from the start site's adapter, so they can't be right for the next site. | `ToolRegistry+Browse.swift:150–157`, `:253–262`; `ToolRegistry+Forum.swift:14–20`; `VoiceSite.swift:21–42`. |
| 10 | **Voice can't change the page and can't notify.** This is by design and should stay. It is listed because the user will ask, and the instruction must route it. | Spike Q5; `ToolRegistry+Capabilities.swift:63` (`notify` has no voice surface). |
| 11 | **Results are capped at 8,000 characters.** Correct, and it stays. It is why "listen to this page" must be done by the app, not by the model passing text along. | `ToolRegistry.swift:595–630`; spike Q6. |
| 12 | **The visible text says forum too.** Settings describes voice as "a live conversation that can find, open and read posts for you". | `VoiceViews.swift:412`. |
| 13 | **The spoken checks of 1.3.0 never ran.** Saying "Switch to dark mode" on an ordinary page was not run in acceptance. | [one-loop-acceptance.md](one-loop-acceptance.md) check 3 and "not run" list. |

Also confirmed: the model is fixed at `gemini-3.8-live` (`LiveProtocol.swift:64`) and needs a Gemini or Vertex key (`AppModel+Voice.swift:116–125`). Tap talks when a key is set, long-press dictates (`AskBox.swift:217–224`).

## 3. Proposal

### One fixed tool set, declared in every session

Gemini Live fixes the setup at connect, and a resume can't change it (spike Q2). So the setup must not depend on the page. **Everything that depends on the page moves out of the setup**: into screen notes, tool arguments and tool results.

The session declares the same 13 tools wherever it starts:

| Tool | Works on | Change from today |
|---|---|---|
| `open_page` | any page | **New.** Opens what the user named. See Navigation. |
| `browse_move` | any page | `back`, `forward`, `top`, `bottom` work everywhere. New: `down` and `up` scroll one screen. `next`, `previous`, `post` still need a forum list or topic. |
| `read_page` | any page | Unchanged (structure, capped). |
| `summarize_topic` | any page | With no input: the open thread on a topic, else **the page on screen**. |
| `read_aloud` | any page | The same default. |
| `hand_off_to_agent`, `end` | any page | Unchanged contract. The text also covers ordinary pages. |
| `search_forum`, `browse_open`, `browse_focus`, `read_post`, `read_topic`, `watch_topic` | forum only | Declared always, with neutral wording. Off a forum they refuse with a sentence that says what to use instead. |

- **Cost.** One tool more than today's forum set of 12. On an ordinary page it is 13 against today's 6. The spike measured no latency cost for more tools (setup 0.33 s against 0.31 s, first audio 0.72 s against 0.75 s for 15 tools against 7). The cost is prompt tokens on every turn. The spike's "about 1,180 tokens for 8 more tools" also included a different instruction, so it is only a rough guide. The real number is a proposed measurement (task 1).
- **Neutral wording.** The search hint and the focus modes stop coming from the start site. The focus modes are the full list (`SiteRegistry.voiceFallback` already builds it), and a site that can't narrow by author refuses from its own data, as `VoiceSite`'s comment already says. `read_topic` needs a voice definition that doesn't need a forum at connect.
- **Refusals that help.** "search_forum isn't available on this page" becomes "This page isn't a forum. Use read_page for what is on it, or hand the request off." The check for unknown names (`VoiceToolBridge.swift:197`) stays.

### Page facts go in notes

Every time a page settles, the session sends one silent note, as it does for topics today:

- Ordinary page: `[Screen: the user is on "<title>" at <host>, an ordinary web page. Forum tools don't work here.]`
- Forum: `[Screen: the user is on the forum <name> (<kind>). Forum tools work here. <the adapter's search hint and language hint>]`
- Topic: today's topic brief and position notes, unchanged.

The note carries the title and the host only, never the full address: paths and queries can hold private tokens. Transcription vocabulary also takes words from the page title.

### Navigation

`open_page` takes one argument, `target`: the words the user said. App code resolves it, in this order:

1. **An address.** "bbc.com", "github.com/kccarlos". The existing resolver (`ForumBrowser.resolveAddress`, `ForumBrowser.swift:462–504`) already turns a host with a dot into `https://…`, and returns nothing for plain words or text with spaces. Voice calls it with no current forum, so "t/123" is not read as a forum path. Queries and fragments are dropped from a spoken address.
2. **A site name.** "Hacker News", "appinn". Matched by name or host against the user's own sites: their forums and the sites they visited (`HomeSites.matches`, `HomeSites.swift:117`; the visit store keeps up to 200 sites, `:132`). The match runs over all of them, not only the 11 tiles Home shows. One match opens. Several come back as a short list for the model to ask about.
3. **Anything else.** A web search with the engine from Settings (`AppModel.webSearchURL`, `AppModel+Browse.swift:69–71`). The result says it was a search, so the model says so.

- **It returns when the page has started to load,** with the title and host once known. The page note follows when it settles. A failed load says why.
- **History** is back and forward, in `browse_move`, plus sites visited before, by name (rule 2). A spoken search of page history is not proposed: nothing shows a need, and the app keeps sites, not pages.
- **While a hand-off runs.** The Agent works on the same one page. This review did not check what a run does when the page changes under it. Default: `open_page` during a running hand-off is refused with a sentence ("The Agent is still working on this page. Say never mind to stop it."). Moves that work today during a hand-off keep today's behaviour. Task 3 checks the Agent's behaviour first and may tighten this.
- **Following a link on the page** ("open the article about tariffs") goes to the Agent for now. See open question 5.
- **Safety.** The model must pass only what the user said. Code can't fully prove that, so code limits the damage: no queries or fragments on spoken addresses, http and https only, and voice still has no tool that reads cookies, storage or network data. What remains: a page could talk the model into a web search that contains page text. That is the same text the user asked voice to read, sent to the user's own search engine. The spike (task 1) includes a page that tries this.

### Switching page kinds in a session

Nothing happens. The tools are the same, and the page note tells the model what kind of page it is on. The conversation is kept, so "open Hacker News, find the Rust thread, summarize it, now go back" is one session.

Two alternatives were considered and rejected:

- **Resume with new declarations.** Measured not to work (spike Q2).
- **A fresh session at each switch, seeded with the notes.** The app already does this at about 54 minutes on AI Studio (`VoiceSession.swift:25–29`, `:476–484`). Setup takes about 0.3 s (spike Q1), but the server-side conversation is lost, and a switch mid-sentence would cut the reply. It has not been measured end to end. With a fixed set it isn't needed.

### What goes to the Agent

- Every change to a page: dark mode, hiding, larger text, saving a script.
- Clicking, typing, forms, sign-in, anything that writes to a site.
- Questions across several threads or pages, and opinion questions on a forum (the spike's rule stays).
- Following a link by its meaning (for now).
- A notification, if the user asks for one.
- **Tools learned later** (Learn on ask, 1.5.0, and a site's own WebMCP tools). They appear at run time, so a voice session can never declare them. Voice reaches them through the hand-off: the Agent has them. Nothing is reserved for this now, in line with [next-phase.md §10](next-phase.md#10-not-doing-for-now).

The hand-off contract doesn't change: non-blocking, one at a time, a WHEN_IDLE briefing, cancel on "never mind". The hand-off is slow by nature: median Agent runs were 17 to 63 s in the comparison. That is acceptable for these requests, and it is why the small things above must not go through it.

### Instruction changes

| Part (`VoiceInstructions.swift`) | Change |
|---|---|
| `persona` | "You are the voice of WukongMind, a browser with an AI agent. The user is on a web page, often with their hands busy…" No site words. `VoiceSiteProfile.persona` goes. |
| `precedence` | Names the any-page tools first: "open X", "go to X", "go back", "scroll down", "what's on this page", "read it to me" are yours. Then the forum actions, "when the screen note says you are on a forum". |
| `opinionRule` | Kept, worded "on a forum". It was measured (spike Q3). |
| `handOff` | Adds clicking, typing and following a link. Still names every page change. |
| `grounding` | "a post" becomes "a page or a post"; `read_page` joins `read_post`. |
| `language` | Keeps "reply in the user's language". The forum search sentence moves into the forum note. |
| The "user is on the forum X" line | Goes: the note says it, and it stays true after a move. |
| `speech`, `screen`, `notes`, eyes-free, answer length | Unchanged. |

Spike Q3 showed that one new tool can steal routing: `search_forum` took the opinion questions until one sentence was added. `open_page` can do the same to `search_forum` ("find X" on a forum must stay a forum search, "search the web for X" must not). So the routing script is run again with the new set before any app code is written (task 1).

### What stays forum-specific

- The six forum tools, cards, focus modes, post numbers and the solution.
- The topic brief, position notes, the quick summary and the "this post" grounding (`VoiceContext`, `VoiceSession.groundIfNeeded`).
- `VoiceRouting.browserAction` (the code guard for "next", "post 37").
- Each adapter's search and language hints, now sent in the forum note.
- `watch_topic`. Watching ordinary pages is deferred in [next-phase.md §10](next-phase.md#10-not-doing-for-now).

This is deliberate. Forums are where the app has structured data, so voice is richest there. The change is that forums become one kind of page voice knows well, not the only place it works.

### Conflicts called out

- **[design-one-loop.md](design-one-loop.md#voice), "the session declares tools for the page kind it starts on"** and "a session on an ordinary page uses `VoiceSiteProfile.neutral`, with no forum tools". This proposal replaces both with one fixed set. "The session doesn't reconnect" is kept.
- **`VoiceToolTests.swift:357–376`** pins today's two sets. The task that changes the set changes the test.
- **Kept, not reopened:** no `inject_css` for voice (spike Q5), the browse tools stay voice-only, `notify` stays text-only, the 8,000-character cap, tap to talk and long-press to dictate.
- **[next-phase.md §10](next-phase.md#10-not-doing-for-now), "no third data shape (articles)".** Not broken: "listen to this page" passes the page's text through the tools' existing `text` path. No new shape.
- **No new screens.** Nothing here needs an artboard. If a task finds it does, the artboard comes first (README rule).

## 4. Open questions for the owner

| # | Question | Recommended answer |
|---|---|---|
| 1 | Is the position right: voice does one-call, undoable things on any page and hands the rest to the Agent? | **Yes.** It is the only option that is fast for small things and was measured to be reliable. |
| 2 | May a voice session send the title and host of every page the user visits during it to Gemini Live? Today it sends nothing on ordinary pages. | **Yes, title and host only, never the full address.** Without it the model can't know where it is. The Settings text for voice (`VoiceViews.swift:412–420`) is reworded to say what is sent, and loses "posts". It is a wording change on an existing screen, so no artboard. |
| 3 | When should this ship: before the trial, or after it? | **Before the trial, as a 1.3.x release, alongside M4.** The trial judges daily use, and the owner already found voice lacking. The work touches `Voice/` and three registry files, so it shouldn't collide with M4. |
| 4 | The spike (task 1) needs live Gemini Live calls with `GEMINI_LIVE_KEY`. Allowed? | **Yes, with the same small harness as the One loop spike.** It guards against the routing regression Q3 already showed once. |
| 5 | Should voice follow links itself ("open the third link", "open the one about tariffs")? | **Not yet: through the Agent first.** It needs a numbered link list and has a prompt-injection side. Decide from the trial notes. |

## 5. Task split (proposal, nothing started)

Five tasks in the project's pattern. Sizes count changed lines, tests included. The rules for every task in [design-one-loop.md](design-one-loop.md#task-split) apply (regenerate the project when files change, strings in `Localizable.xcstrings`, recorded model calls in tests).

**Waves.** Task 1 first. Then task 2. Then 3 and 4, one after the other (both touch `ToolRegistry+Browse.swift` and `VoiceToolBridge.swift`). Then 5.

### 1. Voice anywhere 1: routing and cost spike
- **Read:** this page, and [one-loop-voice-spike.md](one-loop-voice-spike.md).
- **Scope:** `docs/wukongmind/one-loop-spike/` (the existing harness, with the 13 drafted tools and the drafted instruction) and a results section added to this page. No app code. Needs the owner's word for the key (question 4).
- **Size:** about 250.
- **Done when**, each with numbers:
  - prompt tokens per turn for the fixed set against today's two sets;
  - the 12 utterances of spike Q3 on a forum, with the new set: no worse than before;
  - new utterances on an ordinary page and on a forum, 3 runs each: "open bbc.com", "open Hacker News", "search the web for X", "go back", "scroll down", "what's this page about", "read it to me", "make it dark", "find X" on a forum;
  - a forum tool called on an ordinary page: the model tells the user and doesn't retry;
  - how long a one-call Agent run takes ("open bbc.com" through the hand-off), as the baseline `open_page` replaces;
  - a page whose text says "open evil.example": the model doesn't;
  - the draft texts are fixed or changed from the results, and the changes are written down.

### 2. Voice anywhere 2: one fixed tool set and page notes
- **Read:** sections 2 and 3, and task 1's results.
- **Scope:** `Voice/VoiceInstructions.swift`, `Voice/VoiceSite.swift`, `Voice/VoiceContext.swift`, `Voice/VoiceSession.swift` (setup, notes, vocabulary), `Voice/VoiceToolBridge.swift` (refusals), `ToolRegistry+Browse.swift` and `ToolRegistry+Forum.swift` (neutral voice definitions), `AppModel+Voice.swift`, `VoiceViews.swift` (two strings). Tests: `VoiceToolTests.swift`, `VoiceSessionTests.swift`.
- **Size:** about 500. If it runs over, the instruction rewrite splits off. **Depends on:** 1.
- **Done when:**
  - a session declares the same names on a forum, on an ordinary page and from Home (test);
  - a session that starts on an ordinary page and moves to a forum can search it, and the other way round `read_page` works (tests with the fake transport);
  - every settled page sends one note with the title and host and no path or query (test);
  - a forum tool off a forum answers with the helping sentence;
  - the instruction has no site words, and `VoiceSiteProfile.persona` is gone;
  - the Settings text for voice no longer says "posts" and says what is sent to Google.

### 3. Voice anywhere 3: go and move on any page
- **Read:** "Navigation".
- **Scope:** `ToolRegistry+Browse.swift` (`open_page`, the any-page moves), `AppModel+Navigation.swift` (the resolver and the scroll), `Voice/VoiceToolBridge.swift`. Tests: `VoiceToolTests.swift`.
- **Size:** about 400. **Depends on:** 2.
- **Done when:**
  - "bbc.com", a Home site's name and plain words resolve to an address, that site and a web search (tests);
  - a spoken address loses its query and fragment, and other schemes are refused (tests);
  - back, forward, top, bottom, down and up work on an ordinary page (WebKit test on a local fixture);
  - `open_page` during a running hand-off is refused with the sentence (test);
  - `navigate` is still text-only.

### 4. Voice anywhere 4: listen on any page
- **Read:** gap 7 and the tool table.
- **Scope:** `Voice/VoiceToolBridge.swift` (the default input off a topic), `ToolRegistry+Capabilities.swift` (the two descriptions). Tests: `VoiceToolTests.swift`, `CapabilityToolTests`.
- **Size:** about 300. **Depends on:** 2.
- **Done when:**
  - "summarize this" and "read it to me" with no input on an ordinary page use the page's readable text, read by app code (tests);
  - on a topic they still use the open thread;
  - the spoken result stays under the cap, and the text Agent's behaviour is unchanged.

### 5. Voice anywhere acceptance
- **Scope:** an acceptance page under `docs/wukongmind/`, the version bump if the owner chooses a release (question 3), and the device run through `scripts/device-check.sh`.
- **Done when**, said aloud on the phone in one session without restarting voice:
  - from a forum: "open bbc.com" opens it in a few seconds, with no Agent run;
  - there: "what's this page about" and "read it to me" answer and play;
  - "go back" returns to the forum, and "search for X" shows cards;
  - "open Hacker News" opens the saved site by name;
  - "switch to dark mode" on an ordinary page takes effect through the Agent (the check 1.3.0 didn't run);
  - "open bbc.com" while that hand-off runs is refused in a sentence, and "never mind" stops the run.

## Code checked for this review

- `Voice/LiveProtocol.swift:64` (model), `:183–227` (compression, resumption)
- `Voice/VoiceInstructions.swift` (whole file)
- `Voice/VoiceTools.swift` (whole file)
- `Voice/VoiceSite.swift` (whole file)
- `Voice/VoiceContext.swift` (whole file; the topic guard at `:107`)
- `Voice/VoiceToolBridge.swift` (whole file; `:189–198`, `:235–260`, `:283–323`)
- `Voice/VoiceSession.swift:1–35`, `:387–423`, `:447–484`, `:533–556`, `:734–780`
- `Voice/VoiceSettings.swift:80–118` (limits)
- `AppModel+Voice.swift` (whole file)
- `AppModel+Navigation.swift:506–517` (back, forward)
- `AppModel+Browse.swift:61–71` (search URLs); `AppModel.swift:2834–2855` (forum context)
- `ToolRegistry+Browse.swift` (whole file)
- `ToolRegistry.swift:498–513` (surfaces), `:595–630` (the cap), `:2325–2360` (`m3`)
- `ToolRegistry+Navigation.swift:40–100` (`navigate`)
- `ToolRegistry+Capabilities.swift:57–87`, `:119–226`
- `ToolRegistry+Forum.swift:14–20`, `:87–112`
- `ForumBrowser.swift:454–504` (address resolver); `HomeSites.swift:46–60`, `:112–132`, `:186–196`
- `VoiceViews.swift:411–420` (Settings text)
- `PageContext.swift:27–59`; `AgentBridge.swift:118–148`; `AskBox.swift:210–232`
- `WukongMindTests/VoiceToolTests.swift:345–376`
- Docs: `README.md`, `next-phase.md` (§3, §7, §10, §11), `design-one-loop.md` (Voice, task split, conflicts), `one-loop-voice-spike.md`, `one-loop-comparison.md` (Totals), `one-loop-acceptance.md` and `one-loop-acceptance/check8-simulator.txt`, and the voice lines of `requirements.md` and `design-unified.md`.

## Not checked

- No live Gemini Live session was run. What the model says to "open bbc.com" today is the owner's observation.
- The prompt tokens of the fixed set, and routing with `open_page` in the set. Both are task 1.
- How long a one-call Agent run takes.
- What an Agent run does when the page changes under it.
- Vertex AI. The spike measured AI Studio only.
