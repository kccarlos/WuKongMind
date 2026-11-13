# Logo

The WukongMind mark is a square split down the middle, ink on the left and gold on the right, with three thin concentric rings that change colour as they cross the split: gold on ink, ink on gold. It comes from the cover: thin rings over flat colour blocks. There is no centre line and no third colour.

## Files

| File | Use |
| --- | --- |
| `mark.svg` | The default mark, with rounded corners. Use it in the app, in docs and on the web, on light or dark ground. |
| `app-icon.svg`, `app-icon-1024.png` | The app icon, full-bleed square. iOS rounds the corners; do not round them yourself. |
| `mark-mono-ink.svg` | One-colour version in ink, for light ground where colour is not available. |
| `mark-mono-paper.svg` | One-colour version in paper, for dark ground where colour is not available, or where the default mark's ink half would disappear. |

## Construction

- Canvas 1024 × 1024, split at x = 512.
- Rings centred at (512, 512), radii 130, 235 and 340, stroke 28. Keep this ratio when you scale: the stroke is about 2.7% of the width.
- Rounded version: corner radius 230.
- Colours: ink `#1a1612` (token `ink`, light theme) and gold `#e0b040` (token `gold`, dark theme). The mark uses the same two values in both themes.

## Rules

- Smallest size: 24 px. Below 40 px the rings read as texture, which is fine; do not thicken them.
- Clear space: one quarter of the mark's width on every side.
- Do not add a centre line, a dot, a gap in the rings, a shadow, a gradient or a third colour.
- Do not thicken the rings to make the mark look like a band. The mark is meant to be light.
- Do not recolour the halves with jade or cinnabar.
- Do not put the name inside the mark. Set "WukongMind" beside it in the system font, semibold, in `ink`.

## Relation to the Agent ring

The gold ring on the Agent button (`ring-width`, 2 px) is the same idea at interface size: a thin gold circle on ink or ground. The logo and the button should never appear heavier than each other.
