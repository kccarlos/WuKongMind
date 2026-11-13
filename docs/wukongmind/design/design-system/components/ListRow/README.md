# ListRow

A row in a grouped list, as in Settings: icon tile, title, value and chevron.

- A section is a `surface` block with `radius-lg` corners on `ground`; rows are separated by `hairline`.
- Icon tiles are 29pt squares with `radius-sm` corners in `ink` with a `ground` glyph. All tiles are the same ink; the only exception is the Agent's row, which is `gold` with an `on-gold` ring. This replaces the multicoloured tiles of iOS Settings and of Forumind.
- Title in `body` style, `ink`. Value in `body` style, `ink-muted`. Chevron in `ink-faint`.
- Section headers are `caption` style, uppercase, `ink-muted`.
- Minimum row height 44pt; rows grow with Dynamic Type.

The consumer provides icon, title and value. Build on `Form(.grouped)` with list row backgrounds set to `surface`.
