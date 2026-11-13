# ToolRow

One step of the Agent's work as a single line: what it called, a summary, how long it took; plus the folded run and the status line.

- Default density is one line per step. Tapping a row expands arguments and result in `code` style on `surface-raised`.
- The leading glyph is a 28pt disc:
  - **Done**: `surface-raised` disc, `ink-muted` check.
  - **Running**: an open `gold` ring (`ring-width`) that rotates; the tool name turns `gold-ink`. This is the only continuous animation in the panel.
  - **Error**: `cinnabar-wash` disc with a `danger` triangle, and the word "Error" in the summary. The loop continues; errors are not alarming.
- By default a row shows a plain label in `subheadline` style, semibold ("Read page", "Ran script", "Saved script", "Searched forum"), not the tool's code name, and no duration. In developer mode the row shows the raw tool name in `code` style (`read_page`, `run_js`) and its duration. Tools are not colour-coded by kind; only state has colour.
- When a run ends its rows fold into "Steps N". Results the run produced stay outside the fold.
- The status line is `caption` style in `ink-muted`. It is shown while a run is in progress and just after it ends, and is hidden when idle. The token total, in `code` style at the trailing edge, appears only in developer mode.

The consumer provides tool name, argument summary, result summary, duration and state. In developer mode the expanded row also shows the raw request and response.
