# M1 design: agent panel, script card, toolbar button

> **Note.** Per [next-phase.md](next-phase.md), the decision below that the agent is a fourth mode of the assistant panel (beside Summary, Chat and Ask the forum, with a separate third `ModelRole`) is superseded: the assistant panel becomes one conversation view with a single input box and a suggestion row ([next-phase.md §3](next-phase.md#3-six-product-rules), [§4](next-phase.md#4-end-state) and [§7](next-phase.md#7-milestones)). The tool rows, status line, Stop button and script card designs still hold.

The UI task implements against this page and the design canvas:
**https://claude.ai/artifact/Wi2peNxD7d87bfJcfedbcg** (7 artboards: iPhone running, done with script card, empty and no-model; iPad running and step limit; a sheet of every component in light and dark).

Everything uses Forumind's own style: iOS system type (SF, Dynamic Type text styles), `DCTheme` colours and spacing, `dcCard`, `DCPill`, `DCActionButtonStyle`, `DCPrimaryButtonStyle`, `DCIconButtonStyle` and `DCMotion` (`WukongMind/DesignSystem.swift`). Forumind's style covers nearly everything, so the sheepdog design system was not used. The few new pieces (the chat bubble, code blocks, the count badge) are built from these same tokens.

## Decisions

- **Where it lives.** The agent is a new assistant mode beside Summary, Chat and Ask the forum (the M0 open question). The toolbar button opens the panel straight in this mode on every site. On non-forum pages it is the only mode. On forum pages it is a fourth entry in the panel's mode menu. Suggested names: `AssistantMode.browserAgent`, title "Agent", and a new `ModelRole` for its model (no model preset).
- **Hosts are reused, not rebuilt.** On iPhone it is the existing drawer (`AIDrawer.swift`). On iPad it is the existing split panel (`WorkspaceView` in `SplitWorkspace.swift`). Neither is a `NavigationSplitView` nor an `.inspector`: Forumind's own resizable panel is kept.
- **Tint.** `DCTheme.agentTint` (brand purple) marks agent things: the model pill, the badge, `run_js`, `script_save` and the script card. `DCTheme.brandBlue` stays the action colour (buttons, switches, the user's bubble).

## 1. Agent chat panel

**Layout.** From top to bottom:
1. A header: the title "Agent", the model pill and a ⋯ menu (New conversation, Settings).
2. A context row: the host as a `DCPill` in a grey tint, then "N scripts on this page" in `agentTint` (M2: a popover that lists them, each with a switch).
3. The conversation (`ScrollView`, which follows the newest row with the existing `scrollToBottomEdge`).
4. A sticky footer (`dcStickyFooter`): a run status line above the composer.

- **iPhone.** The existing drawer: `presentationDetents([.medium, .large])` and `presentationBackgroundInteraction(.enabled(upThrough: .medium))`, so the page stays scrollable and tappable above it. Its drag indicator is visible. It opens at `.medium` and goes to `.large` for Accessibility type sizes, as the drawer does today. Background `systemBackground`.
- **iPad.** The existing split panel at 470 pt (360 to 560 pt, `DCTheme.panel*Width`) with its resize handle, on `DCTheme.pageBackground`. Consecutive tool calls are grouped in one `dcCard`. In the iPhone drawer they are a plain list with dividers.

**Components → SwiftUI**

| Piece | Build from |
|---|---|
| Model pill | The drawer's `drawerModelPill` (`SummaryPanel.swift`): a `Menu` showing readiness. With no model it shows "No model" with a `DCTheme.warning` tint |
| User message | A trailing bubble, `brandBlue.opacity(0.12)` (0.22 in dark), corner 18, `.subheadline` |
| Agent text | Leading `MarkdownView`, `.subheadline` |
| Tool-call row | `stepRow` from `AgentPanel.swift`, rebuilt as a `DisclosureGroup`-style button. Left: a 28 pt tinted circle with the tool's symbol. Then the tool name (`.subheadline.weight(.semibold)`, monospaced) and the argument summary (`.caption`, secondary, one line). Below them, the result summary (`.caption.weight(.medium)` in the tool's tint). Right: the duration (`.caption.monospacedDigit()`) and a chevron. While it runs, a `ProgressView().controlSize(.mini)` replaces the symbol and the result reads "Running…" |
| Expanded row | "ARGUMENTS" and "RESULT" captions over monospaced code blocks (`.caption.monospaced()`, `raisedSurface`, corner 12, `textSelection(.enabled)`), with a Copy button. A cut-off result says "Truncated · N characters in total" |
| Collapsed run | Once a run ends, its rows fold into the "Steps N" card, which shows a strip of tool icons (`toolStrip` in `AgentPanel.swift`) and an error count. A tap expands it. Anything a run produced, such as the script card or the agent's last text, stays outside the fold, below the card |
| Status line | `.caption`, secondary. Working: "Working · step 3 of 30" with a purple dot. Done: "Done · 5 steps · 38 s" with a green check. Stopped: "Stopped by you · step 4". The total tokens ("18.2k tokens", monospaced digits) stay at the trailing edge in every state |
| Composer | The Ask box field shape (`AskBox.swift`): a 44 pt capsule field and a 44 pt round send button with `brandGradient` |
| Stop | While a run is working, the send button becomes a red capsule "Stop" (`stop.fill` on `DCTheme.danger`, at least 44 pt). Its text is white in light mode and black in dark mode, because white on the dark-mode red is only about 2.9:1. It shows for the whole run and ends the loop at once. The field stays editable as a draft ("Write your next message…") and sends once the run ends or is stopped |

Tool symbols and tints: `read_page` `doc.text` with `brandBlue`; `run_js` `curlybraces` with `agentTint`; `inject_css` `drop` with `chatTint`; `wait_for` `clock` with secondary; `script_save` `square.and.arrow.down` with `agentTint`; any error `exclamationmark.triangle.fill` with `danger`.

**States**

| State | Shows |
|---|---|
| Empty | A `dcCard`, "Change this page by asking", with three how-it-works rows (like Ask the forum's `emptyState`). Below it, three example chips that fill the field, then "Up to 30 steps. Change it in Settings." |
| Running | The rows above, the Stop button, and a working ring on the toolbar button. Closing the drawer or hiding the iPad panel does not stop the run. The ring shows that it is still working, a tap brings back the panel with its Stop button, and the button has a "Stop agent" accessibility action |
| Tool error | A red row with the error as its result summary. The loop goes on, so the next row is usually the fix |
| Step limit reached | A `dcCard(tint: warning)` card with `role: status`: "Stopped at the step limit (30)". It says the page may be half changed and offers **Continue** (a new run with a fresh limit) and **Step limit…** (Settings) |
| No model or key | `ProviderSetupCard` with the agent role: "Choose a model for the agent", or "<Provider> needs an API key" with Add key. The field is disabled ("Choose a model first") |
| Model or network error | A `dcCard(tint: danger)` card saying what the provider said (for example "OpenRouter: 401, the API key was refused"), with Try again and Check key. The changes made so far stay on the page |
| Dark | Same layout. Every colour comes from a `DCTheme` token or a system colour that has a dark value |

## 2. Script card (after `script_save`; built in M2)

It is a `dcCard(tint: agentTint)` placed right after the `script_save` row.
- **Top line:** a 32 pt rounded square with `curlybraces`, then the name (`.headline`), the first match rule (`.caption.monospaced()`, secondary) and "Document end · page world · JS" (`.caption`). A state `DCPill` sits at the trailing edge: On (`success`), Off (secondary), Error (`danger`).
- **Buttons:** `DCActionButtonStyle(prominent: false)` for **View code** and **Disable** (Enable when it is off), and a trailing 44 pt trash button in `danger` labelled "Delete script".
- **View code:** opens a `.sheet` with `[.medium, .large]` detents. It shows the userscript file (header block in secondary) in monospaced text you can select, with Copy and Close.
- **Delete:** acts at once; Undo replaces a confirmation prompt. The card collapses into a dashed row, "'Name' deleted", with **Undo**.
- **Off:** the tint goes neutral.
- **Error:** a danger tint, and the error and its line replace the match rule. "Let the agent fix" joins in M4.

## 3. Browser toolbar button

- **iPhone.** `PhoneAIButton` (`PhoneBrowserBar.swift`) stays in place and keeps its `sparkles` symbol and brand gradient. A tap opens the drawer in agent mode.
- **iPad.** The same button takes the `SplitPanelToggle` slot and toggles the panel. While the panel is shown, it has a selected background (`agentTint.opacity(0.12)`).
- **Script count (M2).** A capsule badge at the top trailing corner: `.caption2.weight(.bold)`, white (black in dark) on `agentTint`, with a 2 pt ring of the bar colour. It is hidden at 0. It turns red when a script on the page has an error, and grey while the global script switch is off. The list of scripts with their switches opens from the panel's "N scripts on this page" chip, because the badge is too small to tap on its own.
- **Running.** `ResearchRing` (its short arc) draws around the button while a run works. It keeps the existing bounce when a run finishes and the panel is closed.
- The `.notForum` warning in the title capsule goes away (M0 change list).

## Accessibility

- Every control is at least 44 pt. Icon-only buttons have labels: "Delete script", "Send", "More", "Close".
- The toolbar button reads as one element: "Agent", with a value such as "3 scripts on this page", "Working" or "1 script has an error". The existing `aiButton` identifier stays.
- Each tool row is one combined element, for example "run_js, page, returned 19, 0.3 seconds". It has the button trait and an expanded/collapsed value (the pattern of `agentStepsToggle`). The expanded code is selectable text.
- Stop is always the trailing control of the footer. While a run works, `.keyboardShortcut(".", modifiers: .command)` triggers it.
- The step-limit and error cards are announced: post `AccessibilityNotification.Announcement` when they appear.
- Dynamic Type: rows wrap and no text truncates at accessibility sizes. The drawer opens at `.large` at those sizes.
- Reduce Motion: no row slide-in (`DCMotion.respecting`) and no ring animation.
- Colour is never the only signal: errors also have the triangle symbol and the word "Error". The brand tokens already have high-contrast values.
- New identifiers: `agentPanel`, `agentToolRow`, `agentStopButton`, `agentScriptCard`, `agentStatusLine`.
