#!/usr/bin/env python3
"""Generate README design-system palette SVGs from design-system/tokens.json.

    python3 scripts/brand/generate_readme_palettes.py

Reads docs/wukongmind/design/design-system/tokens.json and writes:
  - docs/brand/readme/palette-light.svg
  - docs/brand/readme/palette-dark.svg

Standard library only; deterministic output.
"""
import json
import os
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOKENS_PATH = os.path.join(ROOT, "docs", "wukongmind", "design", "design-system", "tokens.json")
OUT_DIR = os.path.join(ROOT, "docs", "brand", "readme")

SWATCH_TOKENS = [
    ("ground", "Ground"),
    ("surface", "Surface"),
    ("ink", "Ink"),
    ("gold", "Gold"),
    ("gold-ink", "Gold ink"),
    ("jade", "Jade"),
    ("cinnabar", "Cinnabar"),
]

SANS = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'PingFang SC', system-ui, sans-serif"
MONO = "ui-monospace, 'SF Mono', Menlo, monospace"


def load_tokens():
    with open(TOKENS_PATH, encoding="utf-8") as f:
        data = json.load(f)
    raw = {t["name"]: t["value"] for t in data["color"]["tokens"]}

    def resolve(theme_id, name):
        val = raw[name][theme_id]
        while val.startswith("{") and val.endswith("}"):
            val = raw[val[1:-1]][theme_id]
        return val

    themes = {}
    for theme in data["color"]["themes"]:
        tid = theme["id"]
        themes[tid] = {
            "name": theme["name"],
            "colors": {name: resolve(tid, name) for name in raw},
        }
    return themes


def ring_icon(kind, cx, cy, c):
    r = 10
    sw = 2.0
    if kind == "idle":
        # Open gold ring (gap at top-right, matching design-system README)
        return (
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{c["gold"]}" '
            f'stroke-width="{sw}" stroke-dasharray="53 10" stroke-linecap="round" '
            f'transform="rotate(-35 {cx} {cy})"/>'
        )
    if kind == "working":
        return (
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{c["hairline"]}" stroke-width="{sw}"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{c["gold"]}" '
            f'stroke-width="{sw}" stroke-dasharray="22 41" stroke-linecap="round" '
            f'transform="rotate(-90 {cx} {cy})"/>'
        )
    if kind == "needs-you":
        return (
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{c["gold"]}" stroke-width="{sw}"/>'
            f'<text x="{cx}" y="{cy + 4}" text-anchor="middle" font-family="{SANS}" '
            f'font-size="12" font-weight="700" fill="{c["gold-ink"]}">?</text>'
        )
    if kind == "done":
        return (
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{c["gold"]}" stroke-width="{sw}"/>'
            f'<path d="M {cx - 4.2} {cy + 0.3} L {cx - 1.2} {cy + 3.4} L {cx + 4.5} {cy - 3.2}" '
            f'fill="none" stroke="{c["gold-ink"]}" stroke-width="1.9" '
            f'stroke-linecap="round" stroke-linejoin="round"/>'
        )
    if kind == "failed":
        return (
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{c["warning"]}" stroke-width="{sw}"/>'
            f'<text x="{cx}" y="{cy + 4}" text-anchor="middle" font-family="{SANS}" '
            f'font-size="12" font-weight="700" fill="{c["warning"]}">!</text>'
        )
    # unavailable
    return (
        f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{c["ink-faint"]}" stroke-width="{sw}"/>'
    )


def render_svg(theme_id, theme_name, c):
    w, h = 840, 224
    pad = 20
    gap = 10
    card_w = (w - 2 * pad - (len(SWATCH_TOKENS) - 1) * gap) / len(SWATCH_TOKENS)
    card_y = 44
    card_h = 102

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-label="WukongMind {escape(theme_name)} palette and Agent ring states">',
        f'  <rect x="0.5" y="0.5" width="{w - 1}" height="{h - 1}" rx="14" fill="{c["ground"]}" stroke="{c["hairline"]}"/>',
        f'  <text x="{pad}" y="29" font-family="{SANS}" font-size="13" font-weight="600" fill="{c["ink"]}">WukongMind · {escape(theme_name)}</text>',
        f'  <text x="{w - pad}" y="29" text-anchor="end" font-family="{MONO}" font-size="11" fill="{c["ink-muted"]}">tokens.json</text>',
    ]

    for idx, (tok, label) in enumerate(SWATCH_TOKENS):
        x = pad + idx * (card_w + gap)
        val = c[tok]
        lines.extend([
            f'  <rect x="{x:.1f}" y="{card_y}" width="{card_w:.1f}" height="{card_h}" rx="10" fill="{c["surface"]}" stroke="{c["hairline"]}"/>',
            f'  <rect x="{x + 8:.1f}" y="{card_y + 8}" width="{card_w - 16:.1f}" height="48" rx="6" fill="{val}" stroke="{c["hairline"]}"/>',
            f'  <text x="{x + 10:.1f}" y="{card_y + 74}" font-family="{SANS}" font-size="11.5" font-weight="600" fill="{c["ink"]}">{escape(label)}</text>',
            f'  <text x="{x + 10:.1f}" y="{card_y + 90}" font-family="{MONO}" font-size="10.5" fill="{c["ink-muted"]}">{escape(val)}</text>',
        ])

    div_y = 162
    lines.append(f'  <line x1="{pad}" y1="{div_y}" x2="{w - pad}" y2="{div_y}" stroke="{c["hairline"]}"/>')

    ring_y = 192
    lines.append(
        f'  <text x="{pad}" y="{ring_y + 4}" font-family="{SANS}" font-size="11.5" font-weight="600" fill="{c["ink-muted"]}">The ring</text>'
    )

    states = [
        ("idle", "Idle"),
        ("working", "Working"),
        ("needs-you", "Needs you"),
        ("done", "Done"),
        ("failed", "Failed"),
        ("unavailable", "Unavailable"),
    ]
    start_x = 112
    slot_w = (w - pad - start_x) / len(states)
    for idx, (kind, label) in enumerate(states):
        cx = start_x + idx * slot_w + 14
        lines.append("  " + ring_icon(kind, round(cx, 1), ring_y, c))
        lines.append(
            f'  <text x="{cx + 18:.1f}" y="{ring_y + 4}" font-family="{SANS}" font-size="11.5" fill="{c["ink"]}">{escape(label)}</text>'
        )

    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def main():
    themes = load_tokens()
    os.makedirs(OUT_DIR, exist_ok=True)
    for tid in ("light", "dark"):
        theme = themes[tid]
        out_path = os.path.join(OUT_DIR, f"palette-{tid}.svg")
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(render_svg(tid, theme["name"], theme["colors"]))
        print(f"Wrote {os.path.relpath(out_path, ROOT)}")


if __name__ == "__main__":
    main()
