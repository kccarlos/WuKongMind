# Switch

The on/off control, drawn in gold with a dark knob.

- **On**: `gold` track with an `on-gold` knob. The dark knob on gold is deliberate; a white knob would fail 3:1 against gold.
- **Off**: `surface` track with a `border-strong` edge and an `ink-muted` knob.
- Size follows the system switch (51 × 31pt). In SwiftUI, set the tint to `gold` and supply the custom knob through a `ToggleStyle`.
- A switch applies at once and needs no Save.

The consumer provides the label, which sits in the row, not on the switch.
