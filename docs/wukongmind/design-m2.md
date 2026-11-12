# M2 design: script manager

> **Note.** Per [next-phase.md](next-phase.md), where the script manager is entered from follows the unified interface design once the "One panel" milestone lands ([next-phase.md §2](next-phase.md#2-documents-and-tasks-to-replace-or-change) and [§7](next-phase.md#7-milestones)); the rest of this design still holds.

The M2 UI task implements against this page and the design canvas:
**https://claude.ai/artifact/R4m1cQPSSHB96r7f6gbyBe** (12 artboards: on iPhone, the manager in its normal + error, global-off and empty states, the script detail in normal and error + unsaved-edit states, version history, the JavaScript editor, and "scripts on this page" normal and with an error and a pending reload; on iPad, the manager and detail in the Settings sheet and the side-panel popover with scripts off; light and dark).

It builds on [design-m1.md](design-m1.md) and its canvas (https://claude.ai/artifact/Wi2peNxD7d87bfJcfedbcg). The script card, the toolbar badge and the look of the "N scripts on this page" chip are specified there and are not repeated. Style is Forumind's own, as in M1: SF text styles, `DCTheme` tokens, `Form(.grouped)`, `SettingsIcon`, `DCPill`, `dcCard`, `DCActionButtonStyle` and `DCMotion` (`Forumind/DesignSystem.swift`, `Forumind/SettingsPanel.swift`). The colours: `agentTint` marks script things, `brandBlue` is for actions and switches (the Settings tint), and `danger` is for errors.

## Decisions

- **Where it lives.** A new Settings page, `SettingsPage.scripts` (new case, title "Scripts", symbol `curlybraces`, tint `agentTint`). Its row goes in the root's "Reading" section, right after the "Ask the forum" row (`row(.agent)`, which holds the browser agent settings). The value is "N" when scripts are on and "Off" when the global switch is off. Settings is the existing sheet (`RootPresentation.settings(page)` with its own `NavigationStack`, `PresentationRouter.swift`), so on iPad the manager is that same sheet over the browser, pushing the list and then the detail. There is no split view.
- **Other ways in.** The chip popover's **Manage scripts** sets `app.requestedSettingsPage = .scripts`, the route the M1 panel already uses for `.agent` and `.provider`. Tapping a script's name in the popover also sets a new `app.requestedScriptID` (the script's ID type); `ScriptManagerView` reads and clears it on appear and pushes that script's detail. `SettingsPage` is a `String` enum and cannot carry the ID. The popover is dismissed first and the route is set after it closes, because a sheet won't present over an open popover. The M1 script card's **View code** keeps its own sheet.
- **iPad.** Every state not drawn for iPad (the empty state, the error detail, history and the editor) is the same `Form` in the same Settings sheet as on iPhone. Only the sheet is wider.
- **Proposed names.** `ScriptStore.update`, `lastError`, the script's ID type and `app.settings.scriptsEnabled` are names this page proposes. None exists on this branch yet: the ScriptStore task settles them, and this UI follows.
- **The global script switch** is the first row of the Scripts page ("Run scripts"). It is the only global switch: the popover's **Turn on** button flips the same setting (`app.settings.scriptsEnabled`, a new setting, default on). Turning it off takes effect at once: no script is injected on later loads or route changes, and the CSS of scripts already on the page is removed. JS that already ran stays until the page is reloaded. Pushed Settings pages have no Done button (only the root has one), so the Scripts page's trailing toolbar slot stays free.
- **Grouping.** Each script appears once, under the host of its **first** match rule, with the host shown as written in the rule (`talk.example.org`, `*.example.org`). Rules whose host is `*` (`*://*/*`, `<all_urls>`) put the script in **All sites**. Groups are sorted by host, with All sites last; within a group, scripts sort by name. When a script has more rules, its row's subtitle says "+N more".
- **Saving edits.** Detail edits work on a draft. **Save** (trailing toolbar) is enabled when the draft differs and is valid. While the draft is dirty, the back button becomes **Cancel**, and Cancel asks "Discard changes?" (the one confirmation, because typing is lost). Each save is a new version through `ScriptStore.update`, the same path as `script_update`. The **Enabled** switch is the exception: it applies at once and does not make a version, like the list switch.
- **Validation** blocks Save and shows inline, in `danger` with the triangle symbol, under the field: an empty name ("Add a name"), no rules ("Add at least one rule"), a rule that is not a valid `@match` pattern (for example "Add a scheme, like https:// or *://"), and JS and CSS both empty ("Add JavaScript or CSS"). The parser is `ScriptStore`'s own `@match` parser, so the UI and injection agree.
- **Rollback** never discards anything. **Restore** on an old version copies it as a new version on top ("Version 1 restored as version 4", with **Undo** in a toast). Every version is kept: the requirement is that each change keeps the old one.
- **Delete** acts at once, with Undo and no confirmation prompt, as in M1. A swipe on a list row, the context menu, or **Delete script** in the detail (which pops back to the list) shows a toast, "'Name' deleted", with **Undo** for 5 seconds. Undo restores the script with its history.
- **Error state.** A script is red when `ScriptStore` holds a `lastError` for it (message, line, page URL, time, count). M2 should record it: the injection wrapper catches synchronous errors and the isolated-world handler reports them. If M2's implementation leaves error capture to M4 (the M0 change list puts it there), these states are still built against the model and stay empty. **Let the agent fix** is drawn **disabled** with the note "The agent fix comes in a later update" (M4 enables it). **Copy error** works now.
- **Import from a URL** is M4. The space left for it: a trailing toolbar `Menu` on the Scripts page ("Import from link…") and the **Source** row's "Imported" variant (drawn on the error board). Neither is built in M2: M2 shows no import entry, and every M2 script's source is "Made by the agent".
- **The popover host.** On both iPhone and iPad the chip opens a `.popover` with `.presentationCompactAdaptation(.popover)`. On iPhone it then floats over the drawer instead of stacking a second sheet on it, and the page stays put. It is 320 to 340 pt wide.

## 1. Script manager (`ScriptManagerView`, Settings › Scripts)

**Layout:** a `Form` with `.formStyle(.grouped)`, as on the other Settings pages.
1. A section with the `Toggle` "Run scripts", led by `SettingsIcon(symbol: "curlybraces", tint: agentTint)` (grey while it is off). Its footer reads "Turns every script off at once. N scripts, M on."
2. One `Section` per group. The header is the host (the Form's own uppercase style) with the count trailing. Each row is a `NavigationLink` to the detail:
   - the name (`.body`);
   - a subtitle, the first rule (`.caption.monospaced()`, secondary), plus " · +N more";
   - a trailing `Toggle` (`labelsHidden`, accessibility label = the name).
3. A footer on the last section: "Tap a script to edit it, see its versions or export it. Swipe left to delete." Rows have `.swipeActions` Delete (destructive) and a `.contextMenu` with Delete and Export.

**States**

| State | Shows |
|---|---|
| Normal | As above |
| Error row | The subtitle becomes a `danger` line: `exclamationmark.triangle.fill`, the word **Error**, the message and its line, wrapping to 2 lines. The switch stays usable |
| Script off | The switch is off. No other change (the M1 card's Off pill is only in the detail and the card) |
| Global switch off | The footer becomes a status line with `nosign`: "Scripts are off. No script runs on any page until you turn this back on. Each script keeps its own switch." The group sections are `.disabled(true)` for their switches only (rows dimmed to 45 %, values kept), and the rows still open the detail. The M1 badge turns grey |
| Empty | Only the global switch section, then a `dcCard`: a 52 pt `agentTint` rounded square with `curlybraces`, "No scripts yet", one line of what a script is, and three numbered how-to rows (the same pattern as the M1 agent empty state) |
| Just deleted | A bottom toast (`.overlay(alignment: .bottom)`, 52 pt, corner 16, `role: status`): the trash symbol, "'Name' deleted", **Undo**. It also posts an announcement |

## 2. Script detail (`ScriptDetailView`)

**Layout:** a `Form`. The title is "Script", inline. The toolbar has **Save** at the trailing edge, and **Cancel** replaces the back button while the draft is dirty.
1. **Header** (a plain row, no section background): a 44 pt rounded square with `curlybraces` in `agentTint` (`danger` with an error, grey when off). Beside it, the name (`.title3.weight(.semibold)`) and "Version N · edited <relative date>" (or "unsaved changes"). A state `DCPill` sits at the trailing edge: On `success`, Off secondary, Error `danger` with the triangle.
2. **Error card** (only with `lastError`): `dcCard(tint: danger)` with `role: status`. It holds:
   - the title "It failed on the last page it ran on";
   - a code block with the message and its line (`.caption.monospaced()`, `raisedSurface`, corner 12, `textSelection(.enabled)`);
   - "page URL · time · N times" (`.caption`, secondary);
   - **Copy error** (`DCActionButtonStyle(prominent: false)`) and a disabled **Let the agent fix** (`sparkles`), with its note underneath.
3. **Name:** a `TextField`.
4. **Runs on** (with "N rules" trailing in the header): one `TextField` per rule (`.body.monospaced()`, `.autocorrectionDisabled()`, `.textInputAutocapitalization(.never)`, `.keyboardType(.URL)`). The rules are swipe-to-delete, followed by an **Add rule** button (`plus`, blue). The footer reads "Tampermonkey @match rules, like https://*.example.org/*." An invalid rule shows its message under the field and gets `accessibilityValue("Invalid")`.
5. **How it runs:**
   - `Toggle` **Enabled**.
   - `Picker` **Runs at**, `.menu` style: **Document start** / **Document end** (the M1 card's words).
   - `Picker` **Environment**, `.menu` style: **Isolated** / **Page**. Isolated is the default for new scripts, per [m0-csp-and-worlds.md](m0-csp-and-worlds.md).
   - The footer reads: "Isolated works on every site and is hidden from the page, but can't see the page's own JavaScript. Page can, but strict sites may block `eval` and requests to other sites."
6. **Code:** a **JavaScript** row and a **CSS** row, each a `NavigationLink` to the code editor. The trailing value is "N lines", "Empty" or "N lines · edited". A non-empty row shows its first two lines (`.caption.monospaced()`, secondary, `lineLimit(2)`).
7. **Source:** "Made by the agent · <date>" with `sparkles` in `agentTint`, and the user's words below it as a quote (`.subheadline`, secondary). The imported variant (M4) shows "Imported · <date>" and the URL.
8. A section with **Version history** ("N versions", a `NavigationLink`) and **Export .user.js file** (`square.and.arrow.up`, blue).
9. A section with **Delete script** (`role: .destructive`, centred).

**Export** is a `ShareLink` of a temporary `<name>.user.js` file holding the exact on-disk userscript text (with the `// ==UserScript==` header), so Save to Files, AirDrop and others work. Its UTType is `.javaScript`, and the file name is the name sanitised for a file system.

**Code editor** (`ScriptCodeEditor`, pushed): the title is "JavaScript" or "CSS", with a Copy button at the trailing edge. Under the title, a status line reads "Edited · not saved yet. Go back and tap Save." It has a full-height `TextEditor` with:
- `.font(.callout.monospaced())`;
- `.autocorrectionDisabled()`, `.textInputAutocapitalization(.never)`, and smart quotes and dashes off. SwiftUI has no modifier for those, so wrap `UITextView` in a small `UIViewRepresentable` with `smartQuotesType`, `smartDashesType` and `smartInsertDeleteType` set to `.no`;
- a keyboard toolbar (`ToolbarItemGroup(placement: .keyboard)`) with Tab, `{ }`, `( )`, `' '`, `;` and `=>`, then Done.

Line numbers and syntax colours are drawn but optional: M2 may ship a plain monospaced editor. Edits go to the detail's draft, so Save stays on the detail page.

**Version history** (`ScriptHistoryView`, pushed): an inset grouped list, newest first. Each row has:
- a 32 pt circle with the number (`agentTint` for the current version);
- a title: "Saved by the agent", "Changed by the agent", "Edited by you" or "Restored version N";
- "date · what changed" (`.footnote`, secondary), and the user's words when the agent made it;
- a trailing **Restore** (`DCActionButtonStyle(prominent: false)`), except on the current version, which has a `success` "Current" pill.

Tapping a row opens a `.sheet` (`[.medium, .large]`) with that version's userscript text (the M1 "View code" sheet) and a **Restore this version** button. Restoring shows the toast with Undo. The footer reads "Restoring copies it as a new version, so nothing is lost."

## 3. "Scripts on this page" popover (`PageScriptsPopover`)

It opens from the M1 chip in the agent panel's context row (`agentScriptsCount`), which becomes a `Button`.

**The chip.** M1 drew it as a 28 pt `agentTint` pill. Now that it is a button, it keeps that pill and adds a small chevron. Its hit area grows to 44 pt (`.frame(minHeight: 44)` plus `.contentShape`); the boards draw that hit area as the capsule. It reads:
- "N scripts on this page" with a chevron, in `agentTint`;
- "N scripts · M errors" (or "1 error") in `danger` with the triangle, when any have an error;
- "Scripts off · N here" in secondary with `nosign`, while the global switch is off.

At 0 it reads "No scripts on this page" in secondary, is not a button, and has no chevron.

**The popover:**
1. A title, "Scripts on this page" (`.subheadline.weight(.semibold)`), over the page URL (`.caption.monospaced()`, secondary, one line, truncated in the middle).
2. While the global switch is off: a grey status box, "All scripts are off. Nothing below runs.", with **Turn on** (`DCActionButtonStyle(prominent: true)`). The rows below are dimmed and disabled.
3. One row per matching script, sorted like the manager. The name sits over a subtitle and is a button that opens the detail (see "Other ways in"). The subtitle reads "Ran 2 s ago · isolated", "Off", "All sites · CSS only", or the `danger` error line. A trailing `Toggle` sits on each row.
4. After any switch changes: **Reload page** (`DCActionButtonStyle(prominent: true)`, `arrow.clockwise`). Turning a script on runs it now. Turning one off removes its CSS at once, but JS that already ran stays until a reload, so that row's subtitle reads "Turned off · reload to remove it fully".
5. **Manage scripts** (a blue row with a chevron) opens Settings › Scripts.

## Accessibility

- Every control is at least 44 pt, popover rows included (56 pt rows, 51×31 switches inside a 44 pt hit area).
- Each script row reads as the name plus a value: "On", "Off" or "Error: <message>". The switch keeps the name as its label. On the detail header the state pill is part of one combined element: "Original poster only, on, version 3".
- Errors never rely on colour alone: they also carry the triangle and the word "Error". Validation messages are tied to their field with `accessibilityHint`, and invalid fields read "Invalid".
- Toasts, restores, the error card and the global switch's status are announced (`AccessibilityNotification.Announcement`). The toast stays 5 s, and longer when VoiceOver is on (until it is dismissed).
- Dynamic Type: rows wrap, and nothing truncates except the URL in the popover (middle truncation, with the full URL in its label). At accessibility sizes the manager subtitle stacks under the name and the switch moves below it (the `SettingsIconRow` pattern).
- Reduce Motion: toasts fade instead of sliding (`DCMotion.respecting`).
- Code fields are selectable text and announce "JavaScript code" or "CSS code".
- The disabled **Let the agent fix** has the hint "Coming in a later update".

**Identifiers** (new):
- Settings and manager: `settingsRow-scripts` (from the existing `row(_:)` helper), `scriptManager`, `scriptsGlobalToggle`, `scriptsEmptyState`, `scriptGroup-<host>`, `scriptRow-<id>`, `scriptToggle-<id>`, `scriptUndoToast`.
- Detail: `scriptDetail`, `scriptSaveButton`, `scriptNameField`, `scriptMatchRule-<n>`, `scriptAddRule`, `scriptEnabledToggle`, `scriptInjectionTime`, `scriptEnvironment`, `scriptJSRow`, `scriptCSSRow`, `scriptCodeEditor`, `scriptSource`, `scriptErrorCard`, `scriptCopyError`, `scriptFixWithAgent` (disabled), `scriptHistoryRow`, `scriptExport`, `scriptDelete`.
- History: `scriptVersionRow-<n>`, `scriptRestoreVersion-<n>`.
- Popover: `pageScriptsPopover`, `pageScriptRow-<id>`, `pageScriptToggle-<id>`, `pageScriptsTurnOn`, `pageScriptsReload`, `pageScriptsManage`.

The existing `agentScriptsCount` stays on the chip.

## Files (suggested, following the M0 change list)

- `Forumind/ScriptViews.swift`: `ScriptManagerView`, `ScriptDetailView`, `ScriptCodeEditor`, `ScriptHistoryView` and `PageScriptsPopover`.
- `Forumind/AppModel+Onboarding.swift`: `SettingsPage.scripts` (title, `systemImage`, `tint`).
- `Forumind/SettingsPanel.swift`: the root row and the `SettingsDestination` case.
- `Forumind/AgentPanel.swift`: the chip becomes the popover's button.
- New strings go in `Localizable.xcstrings` with comments, as Forumind does.
