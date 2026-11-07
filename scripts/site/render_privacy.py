#!/usr/bin/env python3
"""Render PRIVACY.md into mobile-site/privacy/index.html.

PRIVACY.md is the single source of the policy text. This writes it between the
<!-- privacy:begin --> and <!-- privacy:end --> markers of the page and leaves
the rest of the page alone. Only the Markdown PRIVACY.md uses is supported
(## and ### headings, paragraphs, "- " lists, links, <url> autolinks, **bold**,
*italic*, `code`); anything else is an error. The leading "# " title is skipped
because the page has its own heading.

Usage: scripts/site/render_privacy.py [--check]
  --check  change nothing; exit 1 if the page is not up to date.
"""
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "PRIVACY.md"
PAGE = ROOT / "mobile-site/privacy/index.html"
BEGIN, END = "<!-- privacy:begin -->", "<!-- privacy:end -->"


def inline(text):
    out = []
    for i, part in enumerate(text.split("`")):
        if i % 2:  # inside a code span
            out.append("<code>%s</code>" % html.escape(part, quote=False))
            continue
        s = html.escape(part, quote=False)
        s = re.sub(r"&lt;(https?://[^\s&]+)&gt;", r'<a href="\1">\1</a>', s)
        s = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', s)
        s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
        s = re.sub(r"(?<!\*)\*([^*\s][^*]*)\*(?!\*)", r"<i>\1</i>", s)
        out.append(s)
    return "".join(out)


def render(md):
    out, para, items = [], [], []

    def flush():
        if para:
            out.append("<p>%s</p>" % inline(" ".join(para)))
            para.clear()
        if items:
            out.append("<ul>%s</ul>" % "".join("<li>%s</li>" % inline(" ".join(i)) for i in items))
            items.clear()

    for n, line in enumerate(md.splitlines(), 1):
        if re.match(r"\s*(\||>|```|\d+\.\s|[*+]\s|#{4,}\s)", line):
            sys.exit("PRIVACY.md:%d: unsupported Markdown: %s" % (n, line))
        if not line.strip():
            flush()
        elif line.startswith("# "):
            continue
        elif m := re.match(r"(##|###) (.+)", line):
            flush()
            out.append("<h%d>%s</h%d>" % (len(m[1]), inline(m[2]), len(m[1])))
        elif line.startswith("- "):
            if para:
                flush()
            items.append([line[2:].strip()])
        elif line[0] == " " and items:
            items[-1].append(line.strip())
        elif items:
            flush()
            para.append(line.strip())
        else:
            para.append(line.strip())
    flush()
    return "\n".join(out)


def main():
    page = PAGE.read_text(encoding="utf-8")
    head, sep1, rest = page.partition(BEGIN)
    _, sep2, tail = rest.partition(END)
    if not (sep1 and sep2):
        sys.exit("%s: missing %s / %s markers" % (PAGE, BEGIN, END))
    new = "%s%s\n%s\n%s%s" % (head, BEGIN, render(SOURCE.read_text(encoding="utf-8")), END, tail)
    if "--check" in sys.argv:
        if new != page:
            sys.exit("mobile-site/privacy/index.html is out of date; run scripts/site/render_privacy.py")
        print("OK: privacy page matches PRIVACY.md")
    elif new != page:
        PAGE.write_text(new, encoding="utf-8")


main()
