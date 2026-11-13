# BrowserBar

The floating bar of the browser: back, the address field and the ring that opens the Agent.

- The bar is `surface` with `radius-lg` corners and `shadow-pop`. It floats over the page with `space-3` side margins.
- The address field is `surface-raised` with `radius-md` corners, centred `subheadline` text. Empty, it shows a search glyph and "Search or enter address" in `ink-faint`.
- **The ring** is the Agent's entry point and the app's mark: a 44pt circle with a 3pt `gold` stroke and an empty centre. It carries no icon. It replaces Forumind's gradient sparkle button.
- When scripts run on the page, a small `ink` seal with a `ground` number sits on the ring's top-trailing corner.
- Back and other bar buttons are `ink` glyphs on 44pt targets; unavailable ones are `ink-faint`.

The consumer provides the page host, navigation state and the script count.
