# ResultCard

How a tool result that the user reads is shown in the conversation: a summary, an answer with numbered sources, or a listen row.

- A card is `surface` with a `hairline` edge and `radius-lg` corners.
- The header strip is `jade-wash` with `jade` text and icon, `caption` style. Jade means "this came from the website", as opposed to gold, which means "the Agent did this".
- **Summary**: numbered points so later messages can refer to "point 2". The header chevron opens the full summary.
- **Answer with sources**: citation chips are `jade-wash` squares with `radius-sm` corners and a `jade` number, at least 20pt, each a button that jumps to the post.
- **Listen row**: a round `ink` play button with a `ground` glyph, the title in `subheadline` semibold, a `gold` progress bar on `surface-raised`, and elapsed and total time.
- Cards are how results look; they are not separate features. Every card is the output of an Agent tool.

The consumer provides the header label, the content and the sources.
