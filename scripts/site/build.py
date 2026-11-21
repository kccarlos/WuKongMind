#!/usr/bin/env python3
"""Build the WukongMind website (site/) into _site/ and check it.

    python3 scripts/site/build.py [--out DIR]

Standard library only. Pages: home (one template, site/home.html, with its text per
language in site/lang/<code>/home.json and shared pieces in site/partials/; home.css and
home.js load on this page only), support (hand-written per language under
site/lang/<code>/), privacy (rendered from PRIVACY.md) and terms (rendered from
TERMS.md, only when that file exists). Languages: en at the root, zh-Hans/ and
zh-Hant/. Values that are not known yet live in site/config.json; while one is a
"*_TBD" placeholder, the part of the page that needs it is not rendered.
After building, every page is checked: internal links, scripts and anchors resolve,
images have alt text, <html lang> and <title> are set, no placeholder or
{{template}} text leaked, no big files. Any failure exits 1.
"""
import html
import json
import os
import re
import shutil
import sys
from html.parser import HTMLParser

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SITE = os.path.join(ROOT, "site")
LANGS = ["en", "zh-Hans", "zh-Hant"]  # en is served at the root
MAX_FILE_BYTES = 100_000


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def is_tbd(value):
    return value.endswith("_TBD")


# --- Markdown (the small subset PRIVACY.md and TERMS.md use; anything else fails the build) ---

UNSUPPORTED = re.compile(r"(\||```|\d+\.|\* |<(?!https?://))")


def inline(text, blob):
    codes = []

    def stash(m):
        codes.append(html.escape(m.group(1), quote=False))
        return "\x00%d\x00" % (len(codes) - 1)

    text = re.sub(r"`([^`]+)`", stash, text)
    text = html.escape(text, quote=False)

    def link(m):
        href = m.group(2)
        if not re.match(r"([a-z][a-z0-9+.-]*:|#)", href, re.I):  # a repo-relative file
            href = blob + href
        return '<a href="%s">%s</a>' % (html.escape(href, quote=True), m.group(1))

    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, text)
    text = re.sub(r"&lt;(https?://[^\s&]+)&gt;", r'<a href="\1">\1</a>', text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![*\w])\*([^*\n]+)\*(?![*\w])", r"<em>\1</em>", text)
    return re.sub("\x00(\\d+)\x00", lambda m: "<code>%s</code>" % codes[int(m.group(1))], text)


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", re.sub(r"<[^>]+>", "", text).lower()).strip("-")


def markdown(src, blob):
    lines = src.split("\n")
    out, i = [], 0

    def fail(msg):
        raise SystemExit("markdown: %s: %r" % (msg, lines[i]))

    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
        elif line.startswith("#"):
            m = re.match(r"(#{1,3}) +(.+)$", line)
            if not m:
                fail("heading")
            n, body = len(m.group(1)), inline(m.group(2), blob)
            out.append('<h%d id="%s">%s</h%d>' % (n, slug(body), body, n))
            i += 1
        elif re.match(r"\s*- ", line):
            items = []  # (indent, text)
            while i < len(lines) and (re.match(r"\s*- ", lines[i]) or (lines[i].startswith("  ") and lines[i].strip() and items)):
                m = re.match(r"(\s*)- (.*)$", lines[i])
                if m:
                    items.append([len(m.group(1)), m.group(2)])
                else:
                    items[-1][1] += " " + lines[i].strip()
                i += 1
            out.append(render_list(items, blob))
        elif line.startswith(">"):
            quote = []
            while i < len(lines) and lines[i].startswith(">"):
                quote.append(lines[i].lstrip("> ").rstrip())
                i += 1
            if any("[!" in q for q in quote):
                fail("alert blockquote")
            out.append("<blockquote><p>%s</p></blockquote>" % inline(" ".join(quote), blob))
        elif UNSUPPORTED.match(line):
            fail("unsupported construct")
        else:
            para = []
            while i < len(lines) and lines[i].strip() and not re.match(r"(#|\s*- |>)", lines[i]):
                if UNSUPPORTED.match(lines[i]):
                    raise SystemExit("markdown: unsupported construct: %r" % lines[i])
                para.append(lines[i].strip())
                i += 1
            out.append("<p>%s</p>" % inline(" ".join(para), blob))
    return "\n".join(out)


def render_list(items, blob):
    def build(pos, indent):
        parts = ["<ul>"]
        while pos < len(items) and items[pos][0] >= indent:
            if items[pos][0] > indent:
                raise SystemExit("markdown: list nested more than one level at once")
            text = inline(items[pos][1], blob)
            pos += 1
            sub = ""
            if pos < len(items) and items[pos][0] > indent:
                sub, pos = build(pos, items[pos][0])
            parts.append("<li>%s%s</li>" % (text, sub))
        parts.append("</ul>")
        return "".join(parts), pos

    return build(0, items[0][0])[0]


# --- Pages ---

# Home only. The inline script runs before first paint, so a demo is never drawn finished and then
# reset; without JavaScript or with reduced motion the class is never set and the finished frames show.
HOME_HEAD = """<script>if(!matchMedia("(prefers-reduced-motion: reduce)").matches&&"IntersectionObserver"in window)document.documentElement.classList.add("anim")</script>
<link rel="stylesheet" href="%shome.css">
"""
HOME_SCRIPT = '<script src="%shome.js" defer data-play="%s"></script>\n'

def sub(template, values, where):
    def one(m):
        if m.group(1) not in values:
            raise SystemExit("%s: unknown placeholder {{%s}}" % (where, m.group(1)))
        return values[m.group(1)]

    return re.sub(r"\{\{(\w+)\}\}", one, template)


def directory(lang, page):
    return "/".join(x for x in ("" if lang == "en" else lang, "" if page == "home" else page) if x)


def href(from_dir, to_dir, fragment=""):
    rel = os.path.relpath(to_dir or ".", from_dir or ".")
    return ("./" if rel == "." else rel + "/") + fragment


def build(out):
    config = json.loads(read(os.path.join(SITE, "config.json")))
    repo = config["repo_url"]
    blob = repo + "/blob/main/"
    layout = read(os.path.join(SITE, "layout.html"))
    sources = {"privacy": "PRIVACY.md"}
    if os.path.exists(os.path.join(ROOT, "TERMS.md")):
        sources["terms"] = "TERMS.md"
    pages = ["home", "privacy", "support"] + (["terms"] if "terms" in sources else [])
    docs = {p: markdown(read(os.path.join(ROOT, f)).rstrip("\n"), blob) for p, f in sources.items()}

    for key in ("support_email", "testflight_url"):
        if is_tbd(config[key]):
            print("note: %s is %s; the part of the site that needs it is not rendered" % (key, config[key]))

    shutil.rmtree(out, ignore_errors=True)
    shutil.copytree(os.path.join(SITE, "assets"), os.path.join(out, "assets"))
    for name in ("styles.css", "home.css", "home.js"):
        shutil.copy(os.path.join(SITE, name), out)
    home_template = read(os.path.join(SITE, "home.html"))
    partial = lambda name: read(os.path.join(SITE, "partials", name + ".html")).strip()
    partials = {"ring": partial("ring"), "article": partial("article")}
    partials["bar"] = sub(partial("bar"), partials, "partials/bar")
    write(os.path.join(out, ".nojekyll"), "")

    for lang in LANGS:
        src = os.path.join(SITE, "lang", lang)
        meta = json.loads(read(os.path.join(src, "meta.json")))
        for page in pages:
            here = directory(lang, page)
            root = os.path.relpath(".", here) + "/" if here else ""
            link = lambda p, frag="": href(here, directory(lang, p), frag)
            values = {
                "root": root, "repo_url": repo, "privacy": link("privacy"),
                "support_email": config["support_email"], "testflight_url": config["testflight_url"],
                "testflight_button": "", "testflight_section": "", "email_line": "", "shots_lang": lang,
            }
            if not is_tbd(config["testflight_url"]):
                values["testflight_button"] = "      " + sub(read(os.path.join(src, "testflight_button.html")), values, lang).strip() + "\n"
                values["testflight_section"] = sub(read(os.path.join(src, "testflight.html")), values, lang)
            if not is_tbd(config["support_email"]):
                values["email_line"] = sub(read(os.path.join(src, "email.html")), values, lang)
            head_extra = body_end = ""
            if page in docs:
                note = sub(read(os.path.join(src, "privacy_note.html")), values, lang).strip()
                inner = '<div class="doc"%s>\n%s\n</div>' % (' lang="en"' if lang != "en" else "", docs[page])
                body = (note + "\n" if note else "") + inner
            elif page == "home":
                strings = json.loads(read(os.path.join(src, "home.json")))
                texts = {"t_" + k: sub(v, values, lang + "/home.json") for k, v in strings.items()}
                body = sub(home_template, dict(values, **partials, **texts), lang + "/home")
                head_extra = HOME_HEAD % root
                body_end = HOME_SCRIPT % (root, html.escape(strings["play"]))
            else:
                body = sub(read(os.path.join(src, page + ".html")), values, lang + "/" + page)

            def nav_link(p, frag="", label=None):
                cur = ' aria-current="page"' if p == page and not frag else ""
                return '    <a href="%s"%s>%s</a>' % (link(p, frag), cur, label)

            nav = [nav_link("home", "#features", meta["nav"]["features"])] + [
                nav_link(p, "", meta["nav"][p]) for p in pages if p != "home"]
            footer_nav = [nav_link("home", "", meta["home"])] + nav[1:]
            langs, alternates = [], []
            for other in LANGS:
                target = directory(other, page)
                cur = ' aria-current="page"' if other == lang else ""
                om = json.loads(read(os.path.join(SITE, "lang", other, "meta.json")))
                # The short label shows on phones, so the header stays two rows; the full name is the link's name.
                langs.append('    <a href="%s" hreflang="%s" lang="%s"%s aria-label="%s"><span class="lf">%s</span><span class="ls">%s</span></a>' % (href(here, target), om["html_lang"], om["html_lang"], cur, om["label"], om["label"], om["short"]))
                alternates.append('<link rel="alternate" hreflang="%s" href="%s">' % (om["html_lang"], config["base_url"] + (target + "/" if target else "")))
            alternates.append('<link rel="alternate" hreflang="x-default" href="%s">' % (config["base_url"] + (directory("en", page) + "/" if directory("en", page) else "")))
            page_meta = meta["pages"][page]
            layout_values = {
                "lang": meta["html_lang"], "title": html.escape(page_meta["title"]), "description": html.escape(page_meta["description"]),
                "canonical": config["base_url"] + (here + "/" if here else ""), "alternates": "\n".join(alternates),
                "root": root, "head_extra": head_extra, "body_end": body_end, "skip": meta["skip"], "home": link("home"), "nav_label": meta["nav_label"], "nav": "\n".join(nav),
                "lang_label": meta["lang_label"], "langs": "\n".join(langs), "body": body, "footer_label": meta["footer_label"],
                "footer_nav": "\n".join(footer_nav), "footer_note": sub(meta["footer_note"], {"repo_url": repo}, "footer"),
            }
            write(os.path.join(out, here, "index.html"), sub(layout, layout_values, "layout"))
    return pages


# --- Checks ---

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids, self.links, self.problems, self.lang, self.title, self._in_title = set(), [], [], None, "", False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a:
            self.ids.add(a["id"])
        if tag == "html":
            self.lang = a.get("lang")
        if tag == "title":
            self._in_title = True
        if tag == "img" and a.get("alt") is None:
            self.problems.append("<img src=%s> has no alt" % a.get("src"))
        for attr in ("href", "src"):
            if tag in ("a", "link", "img", "script") and a.get(attr):
                self.links.append(a[attr])

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data


# State classes toggled by site/home.js; a bare CSS rule targeting one (e.g. `.in`) collides across the page.
STATE_CLASS_RE = re.compile(r"^\.(?:in|on|still|paused|cur|anim|c|s\d+|is-(?:idle|work|ask|done))$")


def check_css_state_classes():
    problems = []
    for name in sorted(os.listdir(SITE)):
        if not name.endswith(".css"):
            continue
        css = re.sub(r"/\*.*?\*/", "", read(os.path.join(SITE, name)), flags=re.S)
        for m in re.finditer(r"([^{}@]+)\{", css):
            for sel in m.group(1).split(","):
                s = sel.strip()
                if STATE_CLASS_RE.match(s):
                    problems.append("%s: bare state-class selector %r (scope it to a component)" % (name, s))
    return problems


def check(out):
    parsed, problems = {}, check_css_state_classes()
    for dirpath, _, files in os.walk(out):
        for name in files:
            path = os.path.join(dirpath, name)
            if os.path.getsize(path) > MAX_FILE_BYTES:
                problems.append("%s is %d bytes (limit %d)" % (os.path.relpath(path, out), os.path.getsize(path), MAX_FILE_BYTES))
            if name.endswith(".html"):
                text = read(path)
                p = Page()
                p.feed(text)
                parsed[path] = p
                rel = os.path.relpath(path, out)
                if not p.lang:
                    problems.append("%s: <html> has no lang" % rel)
                if not p.title.strip():
                    problems.append("%s: empty <title>" % rel)
                if "{{" in text or "_TBD" in text:
                    problems.append("%s: leaked placeholder text" % rel)
                problems += ["%s: %s" % (rel, x) for x in p.problems]
    internal = external = 0
    for path, p in parsed.items():
        for url in p.links:
            if re.match(r"(https?:|mailto:)", url):
                if "//" in re.sub(r"^https?://", "", url):
                    problems.append("%s: malformed URL (double slash) %s" % (os.path.relpath(path, out), url))
                external += 1
                continue
            internal += 1
            target, _, fragment = url.partition("#")
            target = target.split("?")[0]
            dest = os.path.normpath(os.path.join(os.path.dirname(path), target)) if target else path
            if os.path.isdir(dest):
                dest = os.path.join(dest, "index.html")
            rel = os.path.relpath(path, out)
            if not os.path.isfile(dest):
                problems.append("%s: broken link %s" % (rel, url))
            elif fragment and dest in parsed and fragment not in parsed[dest].ids:
                problems.append("%s: missing anchor %s" % (rel, url))
    print("link check: %d pages, %d internal links, %d external links (not fetched), %d problems" % (len(parsed), internal, external, len(problems)))
    for x in problems:
        print("  FAIL", x)
    return not problems


if __name__ == "__main__":
    out = os.path.join(ROOT, "_site")
    if "--out" in sys.argv:
        out = os.path.abspath(sys.argv[sys.argv.index("--out") + 1])
    build(out)
    sys.exit(0 if check(out) else 1)
