# Message

The text turns of the one conversation: the user's bubble, the Agent's plain text, the "saved" note and an error explanation.

- **User** is a trailing bubble on `surface-raised` with `ink` text; three corners are `radius-lg`, the bottom-trailing corner is `radius-sm`.
- **Agent** text has no bubble: plain `ink` on the panel, `subheadline` style, rendered from Markdown.
- **Saved note** is a `gold-wash` chip with `gold-ink` text and the ring glyph. It appears once after the Agent learns a site or saves a script: "Saved. Faster next time."
- **Failure** is explained in a sentence or two on `cinnabar-wash` with a `danger` icon and `ink` text. Failures are said in the conversation; they are never a disabled control somewhere else.

The consumer provides the text. Keep the Agent's voice short and plain: say what it is doing, then what happened.
