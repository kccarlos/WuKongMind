# Composer

The one input box of the app: a text field and a single round ring button that changes with state.

- There is exactly one composer on every page. It has no mode switch, no target menu and no attachments row.
- The field is `surface` with a `border-strong` edge and `radius-md` corners: a rounded rectangle, not a capsule.
- The round button is the ring, the app's signature shape (`radius-full`):
  - **Empty field**: an open `gold` ring (`ring-width`) with a `gold-ink` mic. Tap to talk.
  - **Text present**: the ring fills `gold` with an `on-gold` arrow. Tap to send.
  - **Agent running**: the ring is `cinnabar` with an `on-cinnabar` square. Tap to stop at once.
- Placeholder is `ink-faint`. Text is the `subheadline` style.
- When the keyboard is up, the suggestion row above the composer hides once the user types the first character.

The consumer provides the placeholder for the current page and handles send, talk and stop.
