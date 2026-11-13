# WUKO-23 recap

**Goal:** replace the four assistant panels with one Agent conversation view (iPhone drawer, iPad sidebar) with composer, mic hook and status line; engines untouched; about 500 changed lines.

**Rounds**
- Before me: a previous agent left an uncommitted ~5000-line rewrite (panels, composer, status line, tests).
- Me: committed it, fixed 3 failing UI tests (empty-panel mascot id, Create summary entry, Instructions moved to the ⋯ menu), screenshots, proof artifact, ready.
- Review 1: UI tests still used removed controls (askScopeButton, modelPill); a Shortcuts question was dropped; mode code only partly removed. I fixed the tests and the dropped question, and rejected removing the leftover mode code (engine tests use it).
- Review 2 and 3: passed. PR #29 then conflicted with main (WUKO-24, settings by object).
- After that: I merged origin/main, resolved the catalog (three-way by key), `AppModel+Assistant.swift` and one UI test. Build, catalog check and drift check OK; the 3 key UI tests pass on the iPhone simulator. The merge is committed locally; **not pushed and ready not re-run** because of the stop.

**Recurring finding and premise:** every finding came from the panel rewrite deleting controls that tests or other entry points still referenced. The premise is that the old `assistantMode` and ask-scope code stays until the engine tasks, so tests and entry points keep touching it.

**Open items:** `PhysicalDeviceSmokeTests` still uses askScopeButton, assistantModePicker and selectMode (device-only, stale, not run). Unused ask-scope code remains. Change size is far over the 500-line aim. Full UI suite not re-run after the merge.

**Options**
1. Push the merge and run ready (one more review round). Likely passes.
2. Split: land the panel now, and a follow-up task cleans the dead mode code and the device smoke tests.
3. New approach: not needed.
4. Drop: not advised, the work is reviewed twice.
