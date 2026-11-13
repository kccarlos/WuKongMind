# Button

A rounded-rectangle button in four roles: primary (gold fill), secondary (outlined), quiet (gold text) and destructive (cinnabar).

- **Primary** is `gold` with `on-gold` text. One per screen at most. Never white text on gold: it fails contrast.
- **Secondary** has a `border-strong` edge and `ink` text. Use it beside a primary, or alone for neutral actions.
- **Quiet** is `gold-ink` text with no edge, for inline actions such as "Manage scripts".
- **Destructive** is a `cinnabar` fill with `on-cinnabar` text for Stop, and outlined with `danger` text for Delete.
- **Disabled** is `surface-raised` with `ink-faint` text.
- Corner is `radius-md`. Minimum height 44pt. Label is the `headline` style. Buttons are never capsules; the only round controls are the ring buttons in Composer.
- Focus shows a `ring-width` outline in `gold-ink`.

The consumer provides the label and, optionally, one leading icon. In SwiftUI these are `ButtonStyle`s; keep Dynamic Type by using text styles, not fixed sizes.
