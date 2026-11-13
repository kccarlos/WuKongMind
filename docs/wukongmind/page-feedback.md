# Page feedback (roadmap v2, section 12, added 2026-11-13)

Source: section 12 of the owner's roadmap doc "WukongMind 路线 v2：Just ask", https://claude.ai/artifact/NXv1yn3RH5eNrQY9Pj6jUa. This is an English translation, exported for agents that can't open claude.ai. The owner has decided (2026-11-13) to fold this into M3, in its first wave, rather than make it a separate 1.1.x milestone.

## Problem

In trial use, the Agent sometimes broke a page without noticing and still answered "done". The cause is what the tools return (checked against the 1.1.2 code on main):

- `run_js` returns only the script's return value, console output and errors the script itself threw. `inject_css` doesn't report what the page turned into either.
- `ScriptStore` already records scripts' runtime errors and counts, and has versions and rollback. But a script that errors is never disabled, and nothing is verified before saving.
- The tools today are `read_page`, `run_js`, `inject_css`, `wait_for` and script create/read/update/delete. There is no tool to reload the page, so an Agent that notices it broke something has no clean way to undo it.

## Principle

Add no model calls, and don't use a model to judge whether a page is fine. Instead, tools that change the page carry a little page state in their result, and the app raises warnings by fixed rules.

## How

1. **Page-state snapshot.** The app runs one fixed small function in the isolated world. It returns these numbers: visible body text characters, document height, whether the page can scroll, link count, form control count, visible image count, and page error count. The page error count comes from a listener injected when the page starts loading (uncaught errors and unhandled Promise rejections).
2. **Page-changing tools report the change.** `run_js`, `inject_css` and any later tool that changes the page take a snapshot before and after running. They append a "Page changes" section to the result that lists only the values that changed, or a single line when nothing changed. Read-only tools take no snapshot. If the URL changed while the tool ran, say so and skip the comparison.
3. **Warning rules.** If any rule below matches, the tool result's first line says "The page may be broken" and why:
   - visible body text dropped by more than half;
   - document height dropped by more than half;
   - the page went from scrollable to not scrollable;
   - link count or form control count dropped by more than half;
   - a new page error appeared.
4. **System prompt addition.** On a warning, the Agent must first check with `read_page`, then fix or undo. It must not report done straight away. If the change is exactly what the user asked for (for example "keep only the article"), it may explain this to the user and carry on.
5. **Undo.** Move `reload_page` forward from M3 to here (only this one tool). Reloading drops this conversation's unsaved changes, and saved scripts are injected again.
6. **Verify before saving.** When `script_save` and `script_update` run, the app reloads the page with the candidate script. Once loading finishes, it takes a snapshot and compares it with the snapshot taken before this turn's first page change, using the same warning rules plus one more: "the script ran without errors". If verification fails, the script isn't saved, and the reason goes back to the Agent. If the change really is what the user asked for, the Agent can save again with `confirm_change: true`.
7. **Auto-disable on errors.** A saved script that reports runtime errors on 3 page loads in a row is disabled automatically, and This page says why. One successful run resets the count. This reuses the existing error records.
8. **Developer mode.** An expanded tool row shows the raw values of both snapshots and the rules that matched. The thresholds are one set of constants in one place.

The thresholds above are a starting point, to be tuned after trial use.

## Parts that belong to other milestones

| What | Where |
| --- | --- |
| An "Undo" on a just-saved script's card (disables the script and reloads); This page shows why a script was disabled, with a "Let the Agent fix it" entry | One panel (owner decision pending; fold into M3 with the rest if One panel has already shipped) |
| When the current page has active scripts, the suggestion row shows "This page looks broken"; tapping it sends that sentence, and the app attaches the current snapshot, the active scripts and their errors | One panel (same note as above) |
| On a warning, or during verify-before-save, give the before and after screenshots to a model that supports images | M3 (the screenshot tool is in M3 anyway) |

## Acceptance

- On a test page, have the Agent run a script that empties the body: the tool result carries a warning, and the Agent doesn't report done straight away.
- Have the Agent save a script that throws at runtime: the save is refused, and the reason goes back to the Agent.
- Break a saved script by hand: after the third load it is disabled automatically.
- A big change the user asked for ("keep only the article") still completes and saves.
- Replay tests with `RecordedModelClient` cover both the warning path and the refused-save path.
- An action that doesn't change the page adds at most one line to the tool result.

## Not doing

- No element-by-element DOM diff.
- No automatic rollback: the Agent or the user decides whether to undo.
- No extra model call for this.
