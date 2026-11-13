# SuggestionRow

A horizontally scrolling row of suggested questions above the Composer; tapping one sends that sentence as if the user had typed it.

- A suggestion is a sentence, not a feature. Its label is exactly what gets sent. A label ending in "…" fills the composer and waits for the user to finish it.
- Chips are `surface` with a `border-strong` edge, `radius-md` corners, `ink` text in the `subheadline` style, and an optional `gold-ink` icon.
- There is no disabled or grey state. A suggestion that does not apply to the page is not shown.
- At most four are visible; more scroll sideways. Labels never truncate.
- Suggestions are deliberately quieter than the composer's ring: outlined, never filled.

The consumer provides the list for the current page: built-in ones for the page kind, ones for tools saved for this site, the user's own earlier questions here, and ones for tools the site itself offers.
