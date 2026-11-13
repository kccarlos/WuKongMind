# ScriptCard

The card the Agent leaves in the conversation after it saves a script or a tool for the current site.

- `surface` card with a `hairline` edge and `radius-lg` corners.
- The leading tile is `gold-wash` with a `gold-ink` braces glyph and `radius-sm` corners: gold because the Agent made it.
- Name in `headline` style; the first match rule in `code` style, `ink-muted`.
- The switch turns the script on and off at once. It is the same Switch used everywhere.
- Actions are a secondary Button ("View code") and a quiet Button ("Manage scripts").
- A script with a runtime error replaces the match rule line with a `danger` line and adds a "Let the Agent fix" button.

The consumer provides the script's name, first match rule, state and error.
