# Design: Safari-like bar, tabs and the provider model list (WUKO-77)

Status: **proposed**. Visual only, with no app code. The owner asked for three things after 1.3.0, and this page designs all three before any of them is built.

- **Boards:** unified design canvas (https://claude.ai/artifact/Daefr4AsZcSm2EWbTLU9uK), version 63, section "WUKO-77" (with Fable second-review caption and `PhoneProviderModels` updates in `design/unified-canvas/`, synced back to the canvas artifact in follow-up task D1b).
- **Export:** `design/unified-canvas/` holds the boards' `*.dc.html` files and 2x PNGs in `png/` (light and dark).

| Board | What it shows |
|---|---|
| `PhoneBar` / `PhoneBarDark` | iPhone bar: expanded, 25 %, 50 %, 75 %, collapsed. Agent running (expanded and collapsed), bar at the top, Home, and the motion card |
| `IPadBar` / `IPadBarDark` | iPad bar: expanded, 25 %, 50 %, 75 %, collapsed, and collapsed with the Agent panel open |
| `PhoneTabs` / `PhoneTabsDark` | Tab overview, one conversation per tab (the Agent opens a tab), closing a tab |
| `IPadTabs` / `IPadTabsDark` | iPad tab overview |
| `PhoneProviderModels` / `PhoneProviderModelsDark` | Settings › Models › Anthropic with the Models list, the ⋯ menu, its states, and a provider without tool calling |

Looks come from the design system (https://claude.ai/artifact/5fGhnS4fmcmWYZbPoKTTZ2). The exceptions are listed under "Decisions taken for the owner", and task D1 carries them into design-unified.md and the design system.

## 1. Safari-like address bar

### Today

- `PhoneBrowser` puts one glass toolbar item at the bottom: the forum menu, the title capsule and the Agent ring.
- `ForumBrowserModel.isChromeMinimized` flips when the scroll passes `chromeToggleTravel`. The toolbar is then swapped for a full-width 30 pt strip in `.bar` material.
- The iPad split bar never collapses (`showsStrip` requires `split == nil`).

### Decisions

- **One element.** The bar and the pill are the same glass shape. Scrolling down morphs its width, height, bottom inset, corner radius and text size. The side buttons fade and shrink inside it. Nothing swaps.
- **Expanded (iPhone):** `back | address field | tabs | Agent ring`.
  - The address field holds three things: the page menu at its leading edge (the forum avatar on forums, ⋯ elsewhere; today's `ForumMenuButton` moves here), the domain, and reload at its trailing edge.
  - The page menu sits inside the field because five 44 pt buttons beside a field leave the domain about 70 pt on a 390 pt phone, which truncates even `news.example.com`. With the menu inside, the domain gets about 140 pt. Safari's compact bar seems to make the same trade, but that is from memory; I haven't seen the owner's screenshots.
  - Forward goes in the page menu and in back's long-press history (today the history list is the title capsule's long press).
- **Collapsed (iPhone):** a small centred glass pill holding the lock and the domain.
  - It is as wide as the domain needs, between 120 and 240 pt, and 34 pt high.
  - Its bottom edge sits at the bottom safe-area inset − 14 pt, never less than 8 pt from the screen edge. On a 34 pt home-indicator inset that is 20 pt from the edge, 7 pt clear of the indicator's top.
  - Page content runs under it to the bottom edge (see "Web view inset").
- **Expanded position:** the bar's bottom edge sits at the bottom safe-area inset − 4 pt (30 pt from the edge on a 34 pt inset), never less than 8 pt.
- **Expands on:**
  - scrolling up, with the finger: from collapsed, 32 pt of upward travel brings p to 0.5 and more than 32 pt below it. Either way, letting go opens the bar, because the tie at exactly 0.5 expands (see "Motion spec");
  - activating the pill (tap, or VoiceOver double-tap);
  - reaching the end of the page (see "Page end");
  - a new page load;
  - starting address editing (⌘L);
  - the Agent finishing a run, or asking you something (an M3 confirmation card), while the panel is closed.
- **Where the Agent and mic live:**

  | State | Agent | Mic / voice |
  |---|---|---|
  | Expanded, on a page | The gold ring at the trailing end. Tap opens the panel | Hold the ring (today's long press) |
  | Collapsed | No Agent button. A tap on the pill expands the bar first, then the ring opens the panel. While the Agent works, the pill's lock becomes a 16 pt turning ring and the ink scripts seal sits after the domain, so work stays visible | Expand first |
  | Collapsed, panel closed, and the Agent finishes or needs an answer | The bar springs open, once no finger is on the page. The ring then shows today's state: done, or the confirmation waiting. A tap opens the panel at the card. There is no separate pill state | — |
  | Home | The ring shows only when a page is loaded under Home (as today) | The mic button replaces the ring. Home never collapses (it has its own address field) |
  | Panel open | The bar is under the panel, and the panel's input box has its own mic | Panel mic |
  | Voice session | The voice Dock replaces the bar (today's rule) and the bar doesn't collapse | Dock |
  | Editing the address | The field rides on the keyboard (today's rule) | — |
  | Keyboard up in a page's form field | The bar hides under the keyboard as the system toolbar does today, p freezes, and the bar returns in the state it had when the keyboard goes | — |

- **Bar at the top (Settings › Browser › Browser bar):**
  - The same element anchored under the status bar: its top edge at the top safe-area inset + 4 pt expanded and + 0 pt collapsed.
  - The motion is the same, and it collapses on scroll down too.
  - With the keyboard up in a page field, the top bar stays where it is, frozen.
- **iPhone landscape:** the same element at the bottom, its width capped at 520 pt and centred, the expanded height 48 pt. The same safe-area rules apply, using the landscape bottom inset.
- **iPad:**
  - The split layout's top bar gets the same treatment: `back, forward | address field (page menu, domain, reload) | tabs, mic, Agent ring`.
  - The ring shows and hides the side panel (today's `SplitPanelToggle`). It is filled gold-wash while the panel shows.
  - Collapsed, the pill is centred over the **page column**, under the status bar: top safe-area inset + 2 pt, 200 × 34.
  - The Agent panel never collapses: it keeps its own header and input box.
  - The bar's mic and the panel's mic start the same voice session.
  - Collapsed with the panel hidden, the Agent and the mic are **two taps** away: tap the pill to expand it, then the ring or the mic.
- **`isChromeMinimized`** (read by result cards today) becomes a value derived from p with hysteresis: it turns true when p rises past 0.6, and false when p falls below 0.4. The Reduce Motion cross-fade uses the same two thresholds.

### Geometry (iPhone 390 pt portrait, 34 pt bottom inset; every value is linear in the progress p)

| | p 0 (expanded) | p 0.25 | p 0.5 | p 0.75 | p 1 (collapsed) |
|---|---|---|---|---|---|
| Width | screen − 24 (366) | 324 | 281 | 239 | fits domain, 120–240 (196 drawn) |
| Height | 56 | 50 | 45 | 40 | 34 |
| Corner radius | height ÷ 2 | | | | height ÷ 2 |
| Bottom edge from screen edge | 30 (safe area − 4) | 27.5 | 25 | 22.5 | 20 (safe area − 14) |
| Back, tabs, ring, page menu, reload: opacity, scale | 1, 1 | 0.5, 0.85 | 0, 0.7 (removed from layout) | — | — |
| Address text | 15 pt semibold | | | | 13 pt semibold |
| Address field fill | glass fill 6 % ink | | none (from p 0.5) | | none |
| Leading glyph | page menu | page menu (fading) | lock (or turning ring) | lock | lock |

On iPad the widths run from page-column width − 24 to 200, the height from 52 to 34, and the top edge from safe area + 6 to safe area + 2.

### Web view inset

- **Expanded:** the web view's scroll view gets `contentInset.bottom` (and the scroll indicator inset) equal to the bar's height plus its bottom edge's distance from the screen edge: 56 + 30 = **86 pt**. The last line of a page then scrolls above the bar.
- **Collapsed:** the inset is **0**, so the page runs to the bottom edge under the pill.
- **When it switches:** the bottom inset switches only when the bar comes to rest at an end (scrolling stops with p = 0 or 1, a settle ends, or a trigger's spring ends), never per frame. At rest at p = 1 it becomes 0; at rest at p = 0 it becomes 86.
- **Δy excludes the inset switch:** any content-offset change that UIKit makes because of the inset change in that run-loop turn is ignored by the p integrator.

### Motion spec

- **Only the person's own scrolling drives p:** offset changes while the scroll view `isTracking` (finger down) or `isDecelerating` after a drag.
  - Script scrolls don't move p: the Agent's `run_js`, `scrollTo`, `scrollIntoView` and restoring a scroll position.
  - Neither do anchor (`#fragment`) jumps, find-in-page, pinch-zoom (`isZooming` or `zoomScale` changes) or the inset switch above.
- **Progress p** (0 expanded, 1 collapsed) is integrated on every such content-offset change:
  `p = clamp(p_prev + δy ÷ 64 pt, 0, 1)`.
  - δy is this change's offset delta: positive while the page scrolls down, negative while it scrolls up. p_prev is p after the previous change. Nothing is anchored at touch-down.
  - Clamping each step means travel past either end never builds up. Reversing mid-drag moves p straight away: after any long drag down, 10 pt back up gives p = 1 − 10/64 at once.
  - So scrolling down collapses the bar and scrolling up expands it, both following the finger.
  - Only offsets inside the content count: no rubber-band bounce, and no changes while the page loads or while the keyboard shows.
  - p follows the finger and the coasting frame by frame: no animation runs while either drives it.
- **When scrolling stops** (finger up with no coasting, or coasting ends) with 0 < p < 1, the bar settles:
  - **To the nearer end** by default: p > 0.5 collapses; p ≤ 0.5 expands (the tie at exactly 0.5 expands).
  - **Flick rule:** the velocity is sampled once, at finger-up (`scrollViewWillEndDragging`). If it is above 300 pt/s, the settle that happens when the coasting ends goes in the flick's direction (down collapses, up expands) instead of to the nearer end. The coasting itself still drives p frame by frame until then.
  - Spring: `.spring(response: 0.24, dampingFraction: 1.0)`. It is critically damped (no bounce) and visually done within 250 ms.
- **Page end:**
  - While the finger is down at the bottom of the page, the rubber-band region doesn't count, so p doesn't change.
  - At finger-up at the end of the page, or when coasting reaches the end, the page-end trigger replaces the settle and springs to p = 0.
  - A page shorter than the screen never collapses.
- **Other discrete triggers** spring to p = 0 with the same spring, and only when no finger is on the page: activating the pill, a page load, address editing, and the Agent finishing or needing an answer. Scrolling up is never a discrete trigger, because it is finger-driven.
- **Buttons** fade over the first half of the gesture (opacity = max(0, 1 − 2p)) and scale from 1 to 0.7. Size, radius, position and text size change over the whole gesture. That way the buttons are gone before the shape is small enough to clip them.
- **The design-system motion rule:** the morph is a functional transition that explains cause and effect. It stays under 250 ms, has no bounce, and isn't decorative. It is the third transition beside the two in design-unified §6. The owner asked for the morph itself, so it is settled; task D1 updates the written rules.
- **The turning ring** keeps turning in both states. Inside the pill it is the same animation at 16 pt.
- **Beyond these rules:** frame-level motion details are settled in task B1 with tests and a device check, and written back into this doc.

**SwiftUI notes (for the implementer, not binding):**

- Use one view with an `@Animatable` progress (or `animatableData`).
- p comes from a `UIScrollViewDelegate` on the WKWebView's scroll view, because the system `toolbarMinimizationBehavior` doesn't follow WKWebView. That is why today's code doesn't use it either.
- The glass is `.glassEffect(.regular, in: .capsule)` on iOS 26+, and `.bar` material below.

### Accessibility

- **VoiceOver, one rule:** the bar behaves as it does for everyone. Scrolling, including VoiceOver's three-finger scroll, collapses and expands it, and **activating** the collapsed pill expands it. Focus alone never changes it.
  - Expanded, the bar is the "Browser bar" container with Back, "Page menu", "Address field: news.example.com" (activating it edits), Reload, Tabs, and "Agent" (hint: "Hold to talk").
  - Collapsed, it is one button: "Show browser bar, news.example.com", plus "Agent working" when the turning ring shows.
- **Reduce Motion:** no morph. The bar keeps its two end states and cross-fades between them in **0.2 s**, when p rises past 0.6 or falls below 0.4 (the same hysteresis as `isChromeMinimized`) or a trigger fires. The turning ring shows still (design-system rule).
- **Reduce Transparency / Increase Contrast:** the glass becomes solid `surface` with a hairline (`border-strong`) edge. The domain text keeps 4.5:1 or better.
- **Dynamic Type:**
  - The address text scales with `.subheadline` (expanded) and `.footnote` (collapsed), capped at the XXXL size so the expanded bar keeps one row and its buttons stay 44 pt.
  - At accessibility sizes, long-pressing a bar button shows the Large Content Viewer (its symbol and name). The domain truncates in the middle, and the full address shows when editing.
  - The collapsed pill grows in height with its text up to XXXL. Above that the bar stays expanded, because a pill that wide is not "small".
- **Hit targets:** every button keeps 44 pt. The collapsed pill's hit area is 44 pt high, extended above the 34 pt glass.

## 2. Multiple tabs

Tabs are a milestone of their own: design-m3 moved them out of M3 ("Not in M3"). That page's earlier version (commit `a3cbd56`) held a tab design with `BrowserTabs` and a page driver that followed the active tab. This page differs in one way: a run stays bound to the tab it started in (below).

### Decisions

- **The tabs button** (two overlapping squares) sits in the bar, before the Agent ring.
  - Long press gives a native Menu: New tab, Close this tab, and the list of open tabs.
  - On iPad, ⌘T, ⌘W and ⌃Tab / ⌃⇧Tab work too.
- **Tab overview (iPhone):**
  - Two columns of cards. Each card is a snapshot at radius-lg with a hairline edge, then the site icon and title, then a close button (24 pt disc, 44 pt target) at the top-trailing corner. The disc is dark ink in light mode and light ink in dark mode, so it shows on both.
  - The current tab has a 3 pt **ink** edge. It isn't gold, because gold means only the Agent.
  - A tab whose Agent is working shows a glass "Agent working" chip with the turning ring on its card.
  - Swipe a card sideways to close it. Long-press and drag to reorder.
  - The bottom glass bar holds `+ (new tab) | N tabs | Done`.
  - A new tab opens Home, the start page.
  - Opening the overview zooms the current page down into its card, and choosing a card zooms it up (0.25 s, the system's standard curve). With Reduce Motion, both are a 0.2 s cross-fade.
- **Tab overview (iPad):** the same cards in four columns, with the same bar at the top. The Agent panel hides while the overview shows and returns on the chosen tab. The first version has no Safari-style tab strip: the overview and the keyboard shortcuts are enough, and a strip would compete with the collapsing bar. A tab strip is a later option.
- **Links that open a new window:**
  - A tapped link with `target="_blank"`, or `window.open` from a user tap, opens a **new tab in front**, after the current one, as Safari does.
  - `window.open` without a user gesture is blocked, as WKWebView does by default.
  - When the Agent's `run_js` opens a window, it follows the `tabs` tool's rule: a background tab, reported in the tool row.
- **Restore on launch:** the app saves, per tab, its order, URL, title, snapshot, scroll position and conversation id, plus which tab is current.
  - On launch only the current tab loads its page. The others show their snapshot in the overview and load when first shown (lazy).
  - Conversations come back from the store with their tab. A run that was going when the app quit comes back stopped.
- **Limits and memory:**
  - At most **30** tabs. At 30 the person's New tab (the button, ⌘T, a `_blank` link) is disabled and opens nothing. The bar's long-press menu and the overview say "30 tabs open. Close one to open another".
  - At 30, the `tabs` tool's `open` returns an error ("Tab limit reached: 30 open"), and the Agent says so in the conversation.
  - Under memory pressure, background tabs drop their web view, keeping their URL, title, snapshot, scroll position and conversation, and reload when shown. **A tab whose Agent is running is never unloaded.**
- **Background runs stay alive:**
  - WebKit throttles timers and JavaScript in a WKWebView that isn't in a window.
  - So a tab with a running Agent keeps its web view attached to the window, hidden behind the current tab (`isHidden` false, alpha 0, user interaction off), until the run ends.
  - At most **3** runs go at once. Starting a fourth (by sending in a fourth tab) shows "3 runs are going. Wait for one or stop it" under the input box and doesn't send.
- **Undo after closing a tab** brings back the tab, its page and its conversation. A run that closing stopped stays stopped: its last turn reads "Stopped", and Undo doesn't resume it.

### Accessibility (tabs)

- **Each card** is one VoiceOver element, for example "Night ferries ease the summer rush, news.example.com, current tab, Agent working". Activating it switches to that tab.
- **Custom actions on each card:** Close, Move earlier, Move later. They do the same as the close button, swipe and drag.
- **Dynamic Type:** card titles wrap to two lines, then truncate at the end. At accessibility sizes the grid becomes one column on iPhone and two on iPad.
- **Reduce Motion:** the overview's zoom becomes a cross-fade (above).

### The Agent conversation and tabs: one per tab (recommended)

**Recommendation: one conversation per tab.** design-unified.md, "What one conversation covers", already planned one conversation per tab, with the panel working on the active tab. The reasons:

1. **The Agent acts on the page it sees.** Its page tools (`read_page`, `run_js`, screenshots) target the tab it runs in. With one shared conversation, earlier turns about tab A would read as if they were about tab B after a switch, and a follow-up like "now make it dark" would be ambiguous.
2. **Runs in parallel.** Each tab can have its own run going: a long research run in one tab, quick page fixes in another. One shared conversation would serialize them or mix their tool rows.
3. **It matches the mental model.** Safari, and people, treat a tab as a task, so the conversation sits with its task. History keeps every finished conversation, so nothing is lost.

How it behaves:

- **The panel** shows the current tab's conversation. Switching tabs switches conversations. The This page seal, the suggestions and the status line follow the tab.
- **A run is bound to its tab:** its page tools drive that tab's web view, even after you switch away. That's the difference from `a3cbd56`'s active-tab driver.
- **When the Agent opens a tab** (the `tabs` tool, part of the tabs milestone), the tool row reads "Opened a new tab · <url> · in the background" with **Show**.
  - The run stays in the tab that asked. It can read the new tab through the `tabs` tool, but the new tab starts with an **empty** conversation of its own.
  - The Agent switches tabs on screen only when you asked it to show something; otherwise new tabs open in the background.
- **Closing a tab:**
  - If its Agent is working, the run stops first, as Stop does.
  - The conversation is saved to History, as New conversation (the panel header's button, WUKO-74) does.
  - A toast reads "Tab closed. Its conversation is in History." with **Undo** for 5 s.
- **New conversation** (the panel header's button) affects only the current tab.
- **Voice** joins the current tab's conversation, as typed turns do.
- **Cross-tab questions** ("compare these two tabs") go through the `tabs` tool from one tab's conversation. No shared conversation is needed for that.

## 3. Provider page model list

### Today

- Settings › Models › Providers & keys › <provider> (`ProviderSettingsPage`) shows the badge, the API key and the server address.
- Models are typed by hand per role in `ModelField` (SettingsProviderForm.swift, about line 205), with a "Choose from list" sheet (`ModelListSheet`) that calls `AppModel.discoverModels`.
- `AIService.discoverModels` returns a **sorted `[String]` of IDs**. It has no display names, no dates and not the provider's own order. Vertex AI returns the fixed `AIProvider.vertexAIModels`, Apple Intelligence its one backend label, Ollama reads `/api/tags`, and the rest read `/models`.
- Favorites have their own section on the Models page.

### Decisions

- **The Models section** goes under the API key on each provider's page, headed "Models", with **Refresh** at the trailing edge where the list is fetched.
  - It loads when the page opens. The result is cached per provider until the key or the address changes, as `discoveredModels` does today.
  - The drawn list is the real one: `GET https://api.anthropic.com/v1/models` with the saved key on 2026-11-14 returned 15 models, newest first (`claude-fable-5-2`, `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`, …), each with a display name.
- **Service change (part of P1):** `discoverModels` returns `[DiscoveredModel]` (`id`, optional `displayName`, optional `createdAt`) in the provider's own order. Anthropic gives `display_name` and `created_at`; OpenAI-style `/models` gives `created`. Rows show the display name when there is one, otherwise the ID. The list keeps the provider's order, with newest first when dates exist and by ID otherwise.
- **Per provider:**

  | Provider | Refresh | Footer | Needs a key |
  |---|---|---|---|
  | Hosted, key-based (Anthropic, OpenAI, OpenRouter, Groq, Gemini, xAI, DeepSeek, NVIDIA) | Yes | "Fetched with your key just now." | Yes |
  | Ollama, LM Studio (on your computer) | Yes | "Read from your server just now." | No: they list without a key |
  | Vertex AI | No | "Built-in list. Add others by name." | — (fixed list) |
  | Apple Intelligence | No | "Apple Intelligence has one model and no tool calling…" | No; no add row |

- **Each row:**
  - a **star** (favorite: 44 pt target, gold and filled when on; `aria-pressed`);
  - the display name, with the model ID in mono under it;
  - a **role seal** for each role using that model (gold-wash "Agent", outline "Summaries");
  - a **⋯** native Menu.
- **The list:**
  - Starred models aren't moved, so the list stays stable.
  - Models added by name, and models a role uses but the list lacks, are pinned at the top, marked "added by name".
  - The first six rows show, then "Show all N".
  - Above 20 models, a search field appears at the top of the section.
- **⋯ menu** (native Menu, per the canvas rule "every ⋯ is a Menu"):
  - The header is the model ID.
  - "Use for Agent" and "Use for Summaries", each with a checkmark when that role already uses this model.
  - "Add to favorites" / "Remove from favorites", and "Copy model name".
  - On "added by name" rows only, **Remove** (destructive). It is disabled while a role uses the model, with the subtitle "Used for Agent" (or Summaries).
  - Choosing a role replaces that role's provider and model, and the seal moves.
  - **Scripts** joins the role items in M4 and isn't shown before then.
- **Without tool calling** (today only Apple Intelligence, per `AIProvider.supportsToolCalling`), "Use for Agent" is **shown but disabled**, with the subtitle "Needs a tool-calling model". It isn't hidden, so the reason is discoverable.
  - Apple Intelligence's page shows its single model ("Foundation Model · Private Cloud Compute when available"), with no Refresh and no add row.
  - If a provider later reports tools per model, the same disabled item applies per row.
- **Typing a model name:**
  - "Add a model by name…" is always the last row, except on Apple Intelligence. A tap turns it into an inline mono text field with **Add**.
  - An added model appears at the top of the list marked "added by name". Use it with ⋯ like any row.
  - This replaces the per-role text field for most cases.
- **The states, one row each:**
  - **Loading:** a spinner and "Loading models…".
  - **No key yet** (key-based providers only): "Add your API key above to see this provider's models", plus the add row.
  - **Fetch failed:** the warning colour and icon, "Couldn't load models", and the reason (for example "The key was refused (401). Check it above.") with **Try again**, plus the add row.
  - **Nothing listed** (neutral, no warning colour): the server has no models endpoint (404) or returned an empty list, as some gateways do. It reads "This server doesn't list its models. Add one by name.", plus the add row.
  - **Loaded.**
- **What happens to the role pages:** `ModelRolePage` keeps its provider picker and current model, but its model text field becomes a row that opens the chosen provider's page, scrolled to Models. The Models page's own Favorites section stays. Starring here and starring there are the same list, which the model menus offer (`AppModel.visibleFavorites`).

### Accessibility

- **Each row** is one VoiceOver element, for example "Claude Sonnet 5.5, claude-sonnet-5-5, used for Agent, favorite". It has two custom actions (Toggle favorite, Actions), so the star and ⋯ don't need separate focus stops.
- **The disabled menu items** read their subtitle as the reason.
- **Role seals** carry text, not just colour, and the gold-wash and outline seals also differ in lightness.
- **Model IDs** wrap rather than truncate at accessibility sizes.

## Decisions taken for the owner

On 2026-11-14 the Assistant chose items 1, 3 and 4 on the owner's behalf, each as recommended. Item 2 is settled because the morph is what the owner asked for. The owner can still overrule any of them on acceptance.

1. **Glass capsule, not radius-lg** (chosen: capsule). The bar and the pill are capsules (radius = height ÷ 2), as the iOS 26 system toolbar already ships in the app (`PhoneBarStyle.usesGlass`). The design system reserves radius-full for the ring, and the BrowserBar component says radius-lg. The alternative is radius-lg (14) expanded and radius-md (10) collapsed; flipping to it changes only the radius values.
2. **The bar morph is a third functional transition** (settled): 0.24 s, no bounce, Reduce Motion cross-fade.
3. **The page menu moves inside the address field** (chosen) to give the domain room on iPhone. Forward moves to the page menu and back's long press.
4. **The iPad bar now collapses too** (chosen); today it never does.

## Proposed implementation tasks

| # | Task | Size | Depends on | Done when |
|---|---|---|---|---|
| D1 | Docs and repo design system (split while Claude quota resets): update design-unified.md §6 and its intro ("two transitions" become three, adding the bar morph), the "Checks before implementing" rule "no … capsule anywhere" (gains the glass bar and pill as the one exception), and the repo's `design/design-system/` (`BrowserBar` component spec and HTML preview, `design-system/README.md`, `tokens.json`) with a link to this page | S (½ day) | — | design-unified.md and `design/design-system/` (`BrowserBar/README.md`, `BrowserBar/preview.html`, `README.md`, `tokens.json`) match this page; `design/README.md` records the pending artifact sync so the next re-export applies D1 first |
| D1b | `claude.ai` artifact sync (Claude follow-up): sync the post-v63 `PhoneBar`, `PhoneTabs` and `PhoneProviderModels` board updates from `design/unified-canvas/` into the unified canvas artifact (`Daefr4AsZcSm2EWbTLU9uK`), apply D1's `BrowserBar`, capsule and motion updates to the design system artifact (`5fGhnS4fmcmWYZbPoKTTZ2`), and re-export `design/design-system/`. Visual work, so it runs on Claude | XS | D1 | The unified canvas artifact matches `design/unified-canvas/` (new canvas version recorded in `design/README.md`), and re-exporting `5fGhnS4fmcmWYZbPoKTTZ2` to `design/design-system/` produces no diff against D1 |
| B1 | Bar morph on iPhone: replace the strip with one glass element driven by p. Covers the user-scroll-only integrator, the settle, flick and page-end rules, the safe-area positions, the inset switch at rest, `isChromeMinimized` hysteresis, Reduce Motion and Reduce Transparency, the collapsed Agent-working ring, expanding when the Agent finishes or asks, the keyboard freeze, the top position and landscape. **The tabs slot stays empty until T3:** the address field takes the room | L (4–5 days) | — | Unit tests: p integration (signed, clamped per step, no build-up), the 0.5 tie, the flick sampled at finger-up, programmatic scroll and zoom ignored, hysteresis, the Reduce Motion cross-fade, the keyboard freeze, expanding when the Agent finishes or asks, and a short page never collapsing. UI tests on the iPhone simulator: scrolling a long page collapses to the pill, a tap expands it, coasting to the end expands it, the inset is 0 once the bar rests collapsed and 86 once it rests expanded (including after a drag straight to an end and after a pill tap), and at the page bottom — after the page-end expand sets the inset to 86, a further drag down collapses, and finger-up at the end re-expands, with no flapping. Real-device check through `scripts/device-check.sh`: the bar follows the finger with no visible jump at the inset switch. Frame-level decisions are written back into this doc |
| B2 | Page menu inside the address field, reload in the field, forward in the menu and in back's long press; VoiceOver labels and the Large Content Viewer | S (1 day) | B1 | UI test: the page menu opens from inside the field, forward is in it, and reload works. A VoiceOver audit finds the labels listed above, and an XXXL screenshot shows one row with 44 pt buttons |
| B3 | iPad split bar collapse (pill centred on the page column), same component | S (1 day) | B1 | UI test on the iPad Air simulator: scrolling collapses the top bar to a pill centred over the page column with the panel open and closed, and a tap expands it |
| T1 | Multiple browser instances: `BrowserTabs` owns one `ForumBrowserModel` per tab (today one instance, created in `AppModel.swift:520`); `AppModel.browser` becomes the current tab's model, and its observers re-subscribe; one `BrowserAgentSession` per tab, with page tools bound to their own tab; `target=_blank` opens a front tab | M–L (3–4 days) | — | Unit tests: code opens, switches and closes tabs, each with its own session, and logins carry over; a run started in tab A keeps driving tab A after a switch to B; a `_blank` tap opens a front tab |
| T2 | Persistence and memory: restore on launch (order, current tab, URL, title, snapshot, scroll, conversation id; lazy load), the 30-tab limit for the person and the tool, memory-pressure unload except running tabs, running tabs kept in the window, at most 3 runs | M (2–3 days) | T1 | Unit tests: a saved set of 5 tabs restores in order with the right current tab, and only that tab loads; the 31st open is refused for both the person and the tool; a simulated memory warning unloads idle background tabs but not one with a run; a 4th run is refused with the message. Real-device check through `scripts/device-check.sh`: an alpha-0 background tab's web view keeps running timers and JavaScript while another tab is in front |
| T3 | Tab overview (iPhone and iPad), the tabs button and its long-press menu, close by swipe or button, reorder, ⌘T / ⌘W / ⌃Tab, close-saves-to-History with Undo (which doesn't resume a run), card accessibility, the overview transition and its Reduce Motion fade | M (2–3 days) | T1, T2, B1 | UI tests: open the overview, add, close (button and swipe) and reorder tabs; Undo restores the tab and its conversation, with a stopped run still stopped; VoiceOver Close and Move actions work |
| T4 | The `tabs` Agent tool (list, open, close, switch; part of the tabs milestone, not M3) with the "Opened a new tab · Show" row; background open by default | S–M (1–2 days) | T1, T2 | Recorded-response tests: `open` returns a background tab and the row with Show; `switch` changes the front tab only when asked; `open` at 30 returns the limit error |
| P1 | Provider page Models section: `discoverModels` returns `[DiscoveredModel]` in provider order with display names and dates; Refresh, the per-provider rows and footers, the five states, star, ⋯ Menu with role checkmarks and the disabled Agent item, role seals | M (2–3 days) | — | Unit tests: parsing Anthropic `/v1/models` (recorded) keeps its order and display names, OpenAI-style uses `created`, Ollama `/api/tags` needs no key, and Vertex returns its fixed list without a fetch. UI test: Anthropic's page lists models, ⋯ › Use for Agent moves the Agent seal, and Apple Intelligence shows Use for Agent disabled |
| P2 | Add a model by name (inline field, "added by name" rows, Remove), `ModelRolePage` linking to the provider's list, strings in Localizable.xcstrings | S (1 day) | P1 | UI test: adding `my-gateway/claude-x` puts it at the top marked "added by name"; Remove is disabled while a role uses it and removes it otherwise; the role page's row opens the provider page at Models |

D1 can go first and on its own, with D1b syncing the `claude.ai` artifacts once Claude quota resets. B, T and P are independent tracks; T3 needs B1 for the tabs button's place in the new bar.
