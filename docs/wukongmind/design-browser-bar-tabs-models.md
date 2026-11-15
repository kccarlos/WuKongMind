# Design: Safari-like bar, tabs and the provider model list (WUKO-77)

Status: **proposed**. Visual only, with no app code. The owner asked for three things after 1.3.0, and this page designs all three before any of them is built.

- **Boards:** unified design canvas (https://claude.ai/artifact/Daefr4AsZcSm2EWbTLU9uK), version 59, section "WUKO-77".
- **Export:** `design/unified-canvas/` holds the boards' `*.dc.html` files and 2x PNGs in `png/` (light and dark).

| Board | What it shows |
|---|---|
| `PhoneBar` / `PhoneBarDark` | iPhone bar: expanded, 25 %, 50 %, 75 %, collapsed. Agent running (expanded and collapsed), bar at the top, Home, and the motion card |
| `IPadBar` / `IPadBarDark` | iPad bar: expanded, 50 %, collapsed, and collapsed with the Agent panel open |
| `PhoneTabs` / `PhoneTabsDark` | Tab overview, one conversation per tab (the Agent opens a tab), closing a tab |
| `IPadTabs` / `IPadTabsDark` | iPad tab overview |
| `PhoneProviderModels` / `PhoneProviderModelsDark` | Settings › Models › Anthropic with the Models list, the ⋯ menu, its four states, and a provider without tool calling |

Looks come from the design system (https://claude.ai/artifact/5fGhnS4fmcmWYZbPoKTTZ2). The two exceptions are named under "For the owner to confirm".

## 1. Safari-like address bar

### Today

- `PhoneBrowser` puts one glass toolbar item at the bottom: the forum menu, the title capsule and the Agent ring.
- `ForumBrowserModel.isChromeMinimized` flips when the scroll passes `chromeToggleTravel`. The toolbar is then swapped for a full-width 30 pt strip in `.bar` material.
- The iPad split bar never collapses (`showsStrip` requires `split == nil`).

### Decisions

- **One element.** The bar and the pill are the same glass shape. Scrolling down morphs its width, height, bottom inset, corner radius and text size. The side buttons fade and shrink inside it. Nothing swaps.
- **Expanded (iPhone):** `back | address field | tabs | Agent ring`.
  - The address field holds three things: the page menu at its leading edge (the forum avatar on forums, ⋯ elsewhere; today's `ForumMenuButton` moves here), the domain, and reload at its trailing edge.
  - The page menu sits inside the field because five 44 pt buttons beside a field leave the domain about 70 pt on a 390 pt phone, which truncates even `news.example.com`. With the menu inside, the domain gets about 140 pt. Safari's compact bar makes the same trade.
  - Forward goes in the page menu and in back's long-press history (today the history list is the title capsule's long press).
- **Collapsed (iPhone):** a small centred glass pill holding the lock and the domain.
  - It is as wide as the domain needs, between 120 and 240 pt, and 34 pt high.
  - It sits 9 pt above the bottom edge, over the home indicator.
  - Page content runs under it to the bottom edge, and the web view's bottom inset becomes 0 while collapsed.
- **Expands on:**
  - scrolling up (16 pt or more of upward travel);
  - a tap on the pill;
  - reaching the end of the page (the scroll view's bottom bounce);
  - a new page load;
  - starting address editing (⌘L);
  - VoiceOver focus on the pill.
- **Where the Agent and mic live:**

  | State | Agent | Mic / voice |
  |---|---|---|
  | Expanded, on a page | The gold ring at the trailing end. Tap opens the panel | Hold the ring (today's long press) |
  | Collapsed | No Agent button. A tap on the pill expands the bar first, then the ring opens the panel. While the Agent works, the pill's lock becomes a 16 pt turning ring and the ink scripts seal sits after the domain, so work stays visible | Expand first |
  | Home | The ring shows only when a page is loaded under Home (as today) | The mic button replaces the ring. Home never collapses (it has its own address field) |
  | Panel open | The bar is under the panel, and the panel's input box has its own mic | Panel mic |
  | Voice session | The voice Dock replaces the bar (today's rule) and the bar doesn't collapse | Dock |
  | Editing the address | The field rides on the keyboard (today's rule) | — |

- **Bar at the top (Settings › Browser › Browser bar):**
  - The same element anchored under the status bar: top inset 54 pt expanded, 50 pt collapsed.
  - The motion is the same, and it collapses on scroll down too.
- **iPad:**
  - The split layout's top bar gets the same treatment: `back, forward | address field (page menu, domain, reload) | tabs, mic, Agent ring`.
  - The ring shows and hides the side panel (today's `SplitPanelToggle`). It is filled gold-wash while the panel shows.
  - Collapsed, the pill is centred over the **page column**, under the status bar (top 26 pt, 200 × 34).
  - The Agent panel never collapses: it keeps its own header and input box.
  - The bar's mic and the panel's mic start the same voice session.
- **Result cards** read `isChromeMinimized` today. Keep the name as a derived value, `progress > 0.5`.

### Geometry (iPhone 390 pt; every value is linear in the progress p)

| | p 0 (expanded) | p 0.25 | p 0.5 | p 0.75 | p 1 (collapsed) |
|---|---|---|---|---|---|
| Width | screen − 24 (366) | 324 | 281 | 239 | fits domain, 120–240 (196 drawn) |
| Height | 56 | 50 | 45 | 40 | 34 |
| Corner radius | height ÷ 2 | | | | height ÷ 2 |
| Bottom inset | 30 | 25 | 20 | 14 | 9 |
| Back, tabs, ring, page menu, reload: opacity, scale | 1, 1 | 0.5, 0.85 | 0, 0.7 (removed from layout) | — | — |
| Address text | 15 pt semibold | | | | 13 pt semibold |
| Address field fill | glass fill 6 % ink | | none (from p 0.5) | | none |
| Leading glyph | page menu | page menu (fading) | lock (or turning ring) | lock | lock |

On iPad the widths run from page-column width − 24 to 200, the height from 52 to 34, and the top inset from 30 to 26.

### Motion spec

- **Progress p** (0 expanded, 1 collapsed) = the scroll distance travelled since the last change of direction, divided by **64 pt**, clamped to 0…1.
  - Only offsets inside the content count: no bounce, and no changes while the page loads or while the keyboard shows.
  - p follows the finger frame by frame: no animation runs while you drag.
- **On release** with 0 < p < 1:
  - It settles to the nearer end.
  - A flick faster than 300 pt/s settles in its own direction.
  - Spring: `.spring(response: 0.24, dampingFraction: 1.0)`. It is critically damped (no bounce) and visually done within 250 ms.
- **Discrete triggers** animate with the same spring: tap, page end, load, address edit, scroll-up threshold.
- **Buttons** fade over the first half of the gesture (opacity = max(0, 1 − 2p)) and scale from 1 to 0.7. Size, radius, position and text size change over the whole gesture. That way the buttons are gone before the shape is small enough to clip them.
- **The design-system motion rule** (design-system README, "Motion"): this is a functional transition that explains cause and effect. It is under 250 ms, has no bounce, and is not decorative. It adds a third transition beside the two on the `Motion` board, so the owner confirms it.
- **The turning ring** keeps turning in both states. Inside the pill it is the same animation at 16 pt.

**SwiftUI notes (for the implementer, not binding):**

- Use one view with an `@Animatable` progress (or `animatableData`).
- p comes from a `UIScrollViewDelegate` on the WKWebView's scroll view, because the system `toolbarMinimizationBehavior` doesn't follow WKWebView. That is why today's code doesn't use it either.
- The glass is `.glassEffect(.regular, in: .capsule)` on iOS 26+, and `.bar` material below.

### Accessibility

- **VoiceOver:**
  - Expanded, the bar is the "Browser bar" container with Back, "Page menu", "Address field: news.example.com" (activating it edits), Reload, Tabs, and "Agent" (hint: "Hold to talk").
  - Collapsed, it is one button: "Show browser bar, news.example.com", plus "Agent working" when the turning ring shows.
  - The bar never collapses while VoiceOver focus is inside it.
  - A VoiceOver three-finger scroll counts as scrolling, so it collapses and expands the bar the same way.
  - When VoiceOver is running, the bar can stay expanded (Settings › Browser › "Keep the bar expanded", default **on** when VoiceOver is running at first launch). That setting is a proposal.
- **Reduce Motion:** no morph. The bar keeps its two end states and cross-fades between them in **0.2 s** when p passes 0.5 or a trigger fires. The turning ring shows still (design-system rule).
- **Reduce Transparency / Increase Contrast:** the glass becomes solid `surface` with a hairline (`border-strong`) edge. The domain text keeps 4.5:1 or better.
- **Dynamic Type:**
  - The address text scales with `.subheadline` (expanded) and `.footnote` (collapsed).
  - At accessibility sizes the collapsed pill grows in height to fit; the 44 pt hit area stays.
  - Above XXXL the bar stays expanded, because a pill that wide is not "small".
- **Hit targets:** every button keeps 44 pt. The collapsed pill's hit area is 44 pt high, extended above the 34 pt glass.

## 2. Multiple tabs

### Decisions

- **The tabs button** (two overlapping squares) sits in the bar, before the Agent ring.
  - Long press gives a native Menu: New tab, Close this tab, and the list of open tabs.
  - On iPad, ⌘T, ⌘W and ⌃Tab / ⌃⇧Tab work too.
- **Tab overview (iPhone):**
  - Two columns of cards. Each card is a snapshot at radius-lg with a hairline edge, then the site icon and title, then a close button (24 pt visual, 44 pt target) at the top-trailing corner.
  - The current tab has a 3 pt **ink** edge. It isn't gold, because gold means only the Agent.
  - A tab whose Agent is working shows a glass "Agent working" chip with the turning ring on its card.
  - Swipe a card sideways to close it. Long-press and drag to reorder.
  - The bottom glass bar holds `+ (new tab) | N tabs | Done`.
  - A new tab opens Home, the start page.
- **Tab overview (iPad):** the same cards in four columns, with the same bar at the top. The Agent panel hides while the overview shows and returns on the chosen tab. The first version has no Safari-style tab strip: the overview and the keyboard shortcuts are enough, and a strip would compete with the collapsing bar. A tab strip is a later option.
- **Limits:** the first version allows up to 30 tabs. When memory is low, background tabs drop their web view (they keep their URL, title, snapshot and conversation) and reload when shown.

### The Agent conversation and tabs: one per tab (recommended)

**Recommendation: one conversation per tab.** It is already the agreed model: design-unified.md, "What one conversation covers", says the conversation belongs to the browser, one now and one per tab from M3, and the panel works on the active tab. The reasons:

1. **The Agent acts on the page it sees.** Its page tools (`read_page`, `run_js`, screenshots) target the tab it runs in. With one shared conversation, earlier turns about tab A would read as if they were about tab B after a switch, and a follow-up like "now make it dark" would be ambiguous.
2. **Runs in parallel.** Each tab can have its own run going: a long research run in one tab, quick page fixes in another. One shared conversation would serialize them or mix their tool rows.
3. **It matches the mental model.** Safari, and people, treat a tab as a task, so the conversation sits with its task. History keeps every finished conversation, so nothing is lost.

How it behaves:

- **The panel** shows the current tab's conversation. Switching tabs switches conversations. The This page seal, the suggestions and the status line follow the tab.
- **When the Agent opens a tab** (the M3 `tabs` tool), the tool row reads "Opened a new tab · <url> · in the background" with **Show**. The run stays in the tab that asked: it can read the new tab through the `tabs` tool, but the new tab starts with an **empty** conversation of its own. The Agent switches tabs on screen only when you asked it to show something; otherwise new tabs open in the background.
- **Closing a tab:**
  - If its Agent is working, the run stops first, as Stop does.
  - The conversation is saved to History, as ⋯ › New conversation does.
  - A toast reads "Tab closed. Its conversation is in History." with **Undo** for 5 s.
- **New conversation** (⋯) affects only the current tab.
- **Voice** joins the current tab's conversation, as typed turns do.
- **Cross-tab questions** ("compare these two tabs") go through the `tabs` tool from one tab's conversation. No shared conversation is needed for that.

## 3. Provider page model list

### Today

- Settings › Models › Providers & keys › <provider> (`ProviderSettingsPage`) shows the badge, the API key and the server address.
- Models are typed by hand per role in `ModelField` (SettingsProviderForm.swift, about line 205), with a "Choose from list" sheet (`ModelListSheet`) that calls `AppModel.discoverModels`.
- Favorites have their own section on the Models page.

### Decisions

- **The Models section** goes under the API key on each provider's page, headed "Models" with **Refresh** at the trailing edge.
  - It loads with the saved key when the page opens. The result is cached per provider until the key or the address changes, as `discoveredModels` does today.
  - The footer reads "Fetched with your key just now."
  - The drawn list is the real one: `GET https://api.anthropic.com/v1/models` with the saved key on 2026-11-14 returned 15 models, newest first (`claude-fable-5-2`, `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`, …).
- **Each row:**
  - a **star** (favourite: 44 pt target, gold and filled when on; `aria-pressed`);
  - the display name, with the model ID in mono under it;
  - a **role seal** for each role using that model (gold-wash "Agent", outline "Summaries");
  - a **⋯** native Menu.
- **The list:**
  - It is sorted the way the provider returns it (newest first for Anthropic). Starred models aren't moved, so the list stays stable.
  - Rows for models a role uses but the list lacks are pinned at the top with "added by name".
  - The first six rows show, then "Show all N".
  - Above 20 models, a search field appears at the top of the section.
- **⋯ menu** (native Menu, per the canvas rule "every ⋯ is a Menu"):
  - The header is the model ID.
  - Then "Use for Agent" and "Use for Summaries", each with a checkmark when that role already uses this model.
  - Then "Add to favorites" / "Remove from favorites" and "Copy model name".
  - Choosing a role replaces that role's provider and model, and the seal moves.
  - **Scripts** joins the role items in M4 and isn't shown before then.
- **Without tool calling** (today only Apple Intelligence, per `AIProvider.supportsToolCalling`), "Use for Agent" is **shown but disabled**, with the subtitle "Needs a tool-calling model". It isn't hidden, so the reason is discoverable.
  - Apple Intelligence's page shows its single model ("Apple Foundation Model · Private Cloud Compute when available"), with no Refresh and no add row.
  - If a provider later reports tools per model, the same disabled item applies per row.
- **Typing a model name:**
  - "Add a model by name…" is always the last row. Tap turns it into an inline mono text field with **Add**.
  - An added model appears at the top of the list marked "added by name". Use it with ⋯ like any row.
  - This replaces the per-role text field for most cases.
- **The four states, one row each:**
  - **Loading:** a spinner and "Loading models…".
  - **No key yet:** "Add your API key above to see this provider's models", plus the add row, since local servers and gateways may still work.
  - **Fetch failed:** the warning colour and icon, "Couldn't load models", and the reason (for example "The key was refused (401). Check it above.") with **Try again**, plus the add row.
  - **Loaded.**
- **What happens to the role pages:** `ModelRolePage` keeps its provider picker and current model, but its model text field becomes a row that opens the chosen provider's page, scrolled to Models. The Models page's own Favorites section stays. Starring here and starring there are the same list.

### Accessibility

- **Each row** is one VoiceOver element, for example "Claude Sonnet 5.5, claude-sonnet-5-5, used for Agent, favourite". It has two custom actions (Toggle favourite, Actions), so the star and ⋯ don't need separate focus stops.
- **The disabled menu item** reads its subtitle as the reason.
- **Role seals** carry text, not just colour, and the gold-wash and outline seals also differ in lightness.
- **Model IDs** wrap rather than truncate at accessibility sizes.

## For the owner to confirm

1. **Glass capsule, not radius-lg.** The bar and the pill are capsules (radius = height ÷ 2), as the iOS 26 system toolbar already ships in the app (`PhoneBarStyle.usesGlass`). The design system reserves radius-full for the ring, and the BrowserBar component says radius-lg. The brief asks for Safari's pill, so the boards draw the capsule. The alternative is radius-lg (14) expanded and radius-md (10) collapsed; flipping to it changes only the radius values.
2. **A third functional transition** beside the two on the Motion board (the bar morph, 0.24 s, no bounce).
3. **The page menu moves inside the address field** to give the domain room on iPhone. Forward moves to the page menu and back's long press.
4. **The iPad bar now collapses too**; today it never does.

## Proposed implementation tasks

| # | Task | Size | Depends on |
|---|---|---|---|
| B1 | Bar morph on iPhone: replace the strip with one glass element driven by the progress p (scroll delegate on the WKWebView), the triggers, the spring, Reduce Motion and Reduce Transparency, the collapsed Agent-working ring, the top position. Unit tests for p and the settle; a UI test that collapses, expands by tap and expands at page end | M (2–3 days) | — |
| B2 | Page menu inside the address field, reload in the field, forward in the menu and in back's long press; VoiceOver labels and the "Keep the bar expanded" setting | S (1 day) | B1 |
| B3 | iPad split bar collapse (pill centred on the page column), same component | S (1 day) | B1 |
| T1 | Tab model: `BrowserTab` (web view, URL, title, snapshot, conversation id), a tab store with restore on launch, at most 30, memory-pressure unload; the panel binds to the current tab's `BrowserAgentSession` | M (3 days) | — |
| T2 | Tab overview (iPhone and iPad), tabs button and long-press menu, close by swipe or button, reorder, ⌘T / ⌘W / ⌃Tab, close-saves-to-History with Undo | M (2–3 days) | T1, B1 |
| T3 | The M3 `tabs` Agent tool (list, open, close, switch) with the "Opened a new tab · Show" row; runs stay in their own tab | S–M (1–2 days) | T1 |
| P1 | Provider page Models section: list from `discoverModels`, Refresh, the four states, star, ⋯ Menu with role checkmarks and the disabled Agent item, role seals | M (2 days) | — |
| P2 | Add a model by name (inline field, "added by name" rows), `ModelRolePage` linking to the provider's list, strings in Localizable.xcstrings | S (1 day) | P1 |

B, T and P are independent tracks. T2 needs B1 only for the tabs button's place in the new bar.
