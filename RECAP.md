# WUKO-29 recap

**Goal:** restyle the one conversation's results and tool rows with the design system (ToolRow, ResultCard, Message, ScriptCard, listen row); engines untouched; about 450 changed lines.

**Rounds:** no review yet. Build and `WukongMindTests` pass on the iPhone simulator. Screenshots (folded steps, summary card, script card + saved note; light/dark, iPhone/iPad) are in the proof artifact `wuko-29-one-panel-2c-res-b2ca`.

**Why it is over size:** diff is 487 added and 520 removed (1,023 gross; 3,018 more lines are the regenerated project file). About half is deletion: the old step timeline, tool style table and `BrowserAgentToolRowView` in `AgentPanel.swift`, replaced by one new file `ConversationViews.swift` (292 lines: DCToolRow, DCStepsFold, DCResultCard, DCCitationChip, DCListenRow, DCSavedNote, rise-in motion). Splitting the removal from the new components would leave dead or duplicate code.

**Done:** tense labels (Running script / Ran script), code names and durations only in developer mode, one step shows directly, two or more fold into "Steps N" after the run, summary and forum answer as jade ResultCards with citation chips, podcast listen row, gold-wash script card, "Saved. Faster next time." note, user bubble shape, failure on cinnabar-wash.

**Open items / not proven:** running ring, expanded rows, single-step row, answer card and listen row were not screenshotted (demo run too fast, no launch flag reaches them); Reduce Motion, device and CI not checked. `ResultCardsOverlay` stays (the migration list says keep). `RECAP.md` here overwrites the older tracked WUKO-23 recap and is not committed.

**Options**
1. Accept the size and run ready (recommended): the gross count is mostly replaced code.
2. Split into two tasks: new components plus tool rows, then result cards.
3. Drop: not advised.
