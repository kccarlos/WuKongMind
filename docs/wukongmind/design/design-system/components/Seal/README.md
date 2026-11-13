# Seal

A small squared label, like a stamp: the page chip, the host, the model, counts and states.

- Seals are rounded rectangles with `radius-sm` corners, `caption` style, at least 24pt tall. They are never capsules; this is the clearest difference from Forumind's pills.
- **Ink seal** (`ink` fill, `ground` text): the This page chip, and the script count on the ring. The strongest label; one per row.
- **Outline seal** (`border-strong` edge, `ink` text): neutral facts such as the host.
- **Gold seal** (`gold-wash`, `gold-ink`): Agent things, such as the model, and counts such as "12 new". New and unread are gold, never red.
- **Jade seal** (`jade-wash`, `jade`): facts about the website, such as its platform.
- **States** are an icon plus a word in `success`, `warning`, `danger` or `ink-muted`, without a background. Colour never carries a state alone.

The consumer provides the label. A seal that opens something (This page) is a button with a trailing chevron.
