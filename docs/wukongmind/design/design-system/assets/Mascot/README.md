# Mascot

The mascot is a small monkey in ink and paper with a thin gold headband. It gives the Agent a face in moments when the interface would otherwise be empty or waiting. It is not the logo and never replaces the mark.

## Poses

| File | Use |
| --- | --- |
| `wave.svg` | First launch, empty panel, "ask anything" state. |
| `think.svg` | The Agent is planning or waiting on the model. |
| `run.svg` | The Agent is running tools or a script. |
| `search.svg` | Reading the page, searching a site, learning a new site. |
| `cheer.svg` | A task finished, or a script was saved. |

## Colours

Each pose uses four fixed values, the same in both themes: ink `#1a1612`, paper `#f7f3ea`, gold `#e0b040` for the headband and cinnabar `#b3321f` for the inside of the mouth. Every figure has a paper outline, like a sticker, so it reads on dark ground as well as light.

## Rules

- Show one pose at a time, and at most one mascot per screen.
- Sizes: 96 to 160 px in empty states, 40 to 56 px next to a status line. Do not go below 40 px; use the mark instead.
- Do not put the mascot in the browser bar, in buttons, in lists or beside every message.
- Do not recolour it, remove the outline, add a forehead mark, or put the logo on the headband.
- Do not use it for errors or destructive confirmations. Those stay plain text with `cinnabar`.
- New poses must keep the same head, the plain gold band and the tail.

The files were traced from a raster drawing, so small differences between the heads remain. Redraw from one master head if the mascot is ever animated.
