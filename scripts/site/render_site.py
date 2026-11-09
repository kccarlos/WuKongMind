#!/usr/bin/env python3
"""Render the generated parts of mobile-site/ (https://mobile.forumind.top).

The English pages are the source. An element with Chinese carries it in
data-zh (its inner HTML) or data-zh-<attr> (one attribute, e.g.
data-zh-aria-label, data-zh-content). This script, standard library only:

- writes PRIVACY.md into privacy/index.html between <!-- privacy:begin/end -->
  (## and ### headings, paragraphs, "- " lists, links, <url> autolinks,
  **bold**, *italic*, `code`; anything else is an error);
- writes the site directory into sites/index.html between <!-- sites:begin/end -->
  (and a short list on the home page, <!-- teaser:begin/end -->)
  from scripts/site/sites.json: a snapshot of the Chrome extension site's
  sites.json (https://forumind.top/sites/) with only its Discourse and
  WordPress sites, plus Hacker News;
- writes each page's canonical, hreflang and Open Graph URL lines between
  <!-- seo:begin/end --> and its language link between <!-- lang:begin/end -->;
- writes the Chinese copy of each page under zh/, and sitemap.xml.

Usage: scripts/site/render_site.py [--check]
  --check  change nothing; exit 1 if any generated file is not up to date.
"""
import html
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "mobile-site"
BASE = "https://mobile.forumind.top/"
PAGES = ["", "sites/", "privacy/", "support/"]  # English page paths; the Chinese one is zh/<path>
ZH = "zh/"
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


def between(page, name, body, where):
    begin, end = "<!-- %s:begin -->" % name, "<!-- %s:end -->" % name
    head, sep1, rest = page.partition(begin)
    _, sep2, tail = rest.partition(end)
    if not (sep1 and sep2):
        sys.exit("%s: missing %s / %s markers" % (where, begin, end))
    return head + begin + body + end + tail


def attr(name, value):
    return ' %s="%s"' % (name, html.escape(value, quote=True))


# PRIVACY.md

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


def render_privacy(md):
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
    return "\n" + "\n".join(out) + "\n"


# Site directory

CATEGORIES = [  # The extension site's filter labels.
    ("finance", "Credit Cards & Miles", "美卡、里程与羊毛"),
    ("ai", "AI & Developers", "AI 与开发者"),
    ("tech", "Tech, Linux & Self-Host", "技术、Linux 与自托管"),
    ("wordpress", "WordPress Blogs", "WordPress 博客"),
]


def render_sites(sites):
    e = html.escape
    chips = ['<button type="button" class="chip" data-filter="all" aria-pressed="true"%s>All (%d)</button>'
             % (attr("data-zh", "全部 (%d)" % len(sites)), len(sites))]
    for key, en, zh in CATEGORIES:
        count = sum(key in s["categories"] for s in sites)
        chips.append('<button type="button" class="chip" data-filter="%s" aria-pressed="false"%s>%s (%d)</button>'
                     % (key, attr("data-zh", e("%s (%d)" % (zh, count))), e(en), count))
    cards = []
    for s in sites:
        name, desc = s["name"], s["desc"]

        def words(lang):
            return " ".join([s["keywords"][lang], name[lang], s["host"]]).lower()

        login = ('<span class="badge"%s>Login</span>' % attr("data-zh", "需登录")) if s["requiresLogin"] else ""
        if s["platform"] != "Discourse":  # not in the version in App Store review yet
            login += '<span class="badge beta"%s>Beta</span>' % attr("data-zh", "测试版")
        cards.append(
            '<li class="site" data-categories="%s"%s%s>\n'
            '<a href="%s" rel="noopener"><span class="av" style="--hue: %d" aria-hidden="true">%s</span>'
            '<span class="site-name"%s>%s</span><span class="site-host">%s</span></a>\n'
            '<p class="site-desc"%s>%s</p>\n<p class="badges"><span class="badge">%s</span>%s</p>\n</li>'
            % (" ".join(s["categories"]), attr("data-keywords", words("en")), attr("data-zh-data-keywords", words("zh-CN")),
               e(s["url"]), s["hue"], e(s["avatar"]), attr("data-zh", e(name["zh-CN"])), e(name["en"]), e(s["host"]),
               attr("data-zh", e(desc["zh-CN"])), e(desc["en"]), e(s["platform"]), login))
    return ('\n<div class="filters" hidden>\n<div class="chips" role="group" aria-label="Filter by category"%s>\n%s\n</div>\n'
            '<input type="search" id="site-search" placeholder="Search a site or domain" aria-label="Search supported sites"%s%s>\n</div>\n'
            '<ul class="sites" id="sites">\n%s\n</ul>\n'
            '<p class="empty" id="sites-empty" role="status" hidden%s>No site in this list matches. Open any Discourse forum or WordPress site in Forumind, and it tells you whether the site works.</p>\n'
            % (attr("data-zh-aria-label", "按分类筛选"), "\n".join(chips),
               attr("data-zh-placeholder", "搜索网站名或域名"), attr("data-zh-aria-label", "搜索支持的网站"),
               "\n".join(cards),
               attr("data-zh", "列表中没有匹配的网站。在 Forumind 中打开任何 Discourse 论坛或 WordPress 网站，App 会告诉你能不能用。")))


def render_teaser(sites):
    """The home page's short list: the first sites that need no login, Hacker News, and a link to all."""
    e = html.escape
    picks = [s for s in sites if not s["requiresLogin"] and s["platform"] != "Hacker News"][:11]
    picks += [s for s in sites if s["platform"] == "Hacker News"]
    chips = "\n".join('<li><span class="av" style="--hue: %d" aria-hidden="true">%s</span><span%s>%s</span></li>'
                      % (s["hue"], e(s["avatar"]), attr("data-zh", e(s["name"]["zh-CN"])), e(s["name"]["en"])) for s in picks)
    return ('\n<ul class="tsites">\n%s\n</ul>\n<p class="more center"><a href="sites/"%s>See all %d sites</a></p>\n'
            '<p class="under"%s>Examples only; Forumind is not affiliated with these sites.</p>\n'
            % (chips, attr("data-zh", "查看全部 %d 个网站" % len(sites)), len(sites),
               attr("data-zh", "以上网站仅作举例，Forumind 与它们无任何关联。")))


# Per-page URLs

def rel(src, dst):
    """Relative link from page path src to page path dst (both like 'zh/sites/')."""
    return "../" * src.count("/") + dst or "./"


def render_seo(path):
    en, zh = BASE + path, BASE + ZH + path
    lines = [
        '<link rel="canonical" href="%s" data-zh-href="%s">' % (en, zh),
        '<link rel="alternate" hreflang="en" href="%s">' % en,
        '<link rel="alternate" hreflang="zh-Hans" href="%s">' % zh,
        '<link rel="alternate" hreflang="x-default" href="%s">' % en,
        '<meta property="og:url" content="%s" data-zh-content="%s">' % (en, zh),
        '<meta property="og:locale" content="en_US" data-zh-content="zh_CN">',
        '<meta property="og:locale:alternate" content="zh_CN" data-zh-content="en_US">',
    ]
    return "\n" + "\n".join(lines) + "\n"


def render_lang(path):
    return ('<a class="lang" href="%s" hreflang="zh-Hans" lang="zh-Hans" data-zh="English" data-zh-href="%s" '
            'data-zh-hreflang="en" data-zh-lang="en">中文</a>' % (rel(path, ZH + path), rel(ZH + path, path)))


def render_sitemap():
    urls = []
    for path in PAGES:
        alts = "".join('\n    <xhtml:link rel="alternate" hreflang="%s" href="%s"/>' % (lang, url)
                       for lang, url in (("en", BASE + path), ("zh-Hans", BASE + ZH + path), ("x-default", BASE + path)))
        for loc in (BASE + path, BASE + ZH + path):
            urls.append("  <url>\n    <loc>%s</loc>%s\n  </url>" % (loc, alts))
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
            + "\n".join(urls) + "\n</urlset>\n")


# Chinese pages

def is_file_link(url):
    """A relative link to a file (styles.css, ../assets/x.png), not to a page or an anchor."""
    if not url or url[0] in "#/" or re.match(r"[a-z][a-z0-9+.-]*:", url):
        return False
    return "." in url.split("?")[0].split("#")[0].rsplit("/", 1)[-1]


class Chinese(HTMLParser):
    """Copies a page one directory deeper, with its data-zh content swapped in."""

    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.out = []
        self.skip = 0  # depth inside an element whose content was replaced

    def tag(self, tag, attrs, close):
        values = dict(attrs)
        if not any(k.startswith("data-zh") or (k in ("href", "src") and is_file_link(v or "")) for k, v in attrs):
            return self.get_starttag_text()
        parts = []
        for k, v in attrs:
            if k.startswith("data-zh"):
                continue
            if "data-zh-" + k in values:
                v = values["data-zh-" + k]
            elif k in ("href", "src") and is_file_link(v or ""):
                v = "../" + v
            parts.append(" " + k if v is None else attr(k, v))
        return "<%s%s%s>" % (tag, "".join(parts), " /" if close else "")

    def handle_starttag(self, tag, attrs):
        if self.skip:
            if tag not in VOID:
                self.skip += 1
            return
        self.out.append(self.tag(tag, attrs, False))
        zh = dict(attrs).get("data-zh")
        if zh is not None and tag not in VOID:
            self.out.append(zh if tag in ("script", "title") else convert(zh))
            self.skip = 1

    def handle_startendtag(self, tag, attrs):
        if not self.skip:
            self.out.append(self.tag(tag, attrs, True))

    def handle_endtag(self, tag):
        if self.skip:
            self.skip -= 1
            if self.skip:
                return
        self.out.append("</%s>" % tag)

    def emit(self, text):
        if not self.skip:
            self.out.append(text)

    def handle_data(self, data):
        self.emit(data)

    def handle_entityref(self, name):
        self.emit("&%s;" % name)

    def handle_charref(self, name):
        self.emit("&#%s;" % name)

    def handle_comment(self, data):
        self.emit("<!--%s-->" % data)

    def handle_decl(self, decl):
        self.emit("<!%s>" % decl)


def convert(markup):
    parser = Chinese()
    parser.feed(markup)
    parser.close()
    return "".join(parser.out)


# Everything

def outputs():
    """Every generated file: path -> content."""
    files = {}
    sites = json.loads((ROOT / "scripts/site/sites.json").read_text(encoding="utf-8"))
    for path in PAGES:
        where = SITE / path / "index.html"
        page = where.read_text(encoding="utf-8")
        page = between(page, "seo", render_seo(path), where)
        page = between(page, "lang", render_lang(path), where)
        if path == "privacy/":
            page = between(page, "privacy", render_privacy((ROOT / "PRIVACY.md").read_text(encoding="utf-8")), where)
        if path == "":
            page = between(page, "teaser", render_teaser(sites), where)
        if path == "sites/":
            page = between(page, "sites", render_sites(sites), where)
        files[where] = page
        zh = convert(page)
        if "data-zh" in zh:
            sys.exit("%s: data-zh is left in the Chinese page (unbalanced tags?)" % where)
        files[SITE / ZH / path / "index.html"] = zh
    files[SITE / "sitemap.xml"] = render_sitemap()
    return files


def main():
    check = "--check" in sys.argv
    stale = []
    for where, content in outputs().items():
        if not where.exists() or where.read_text(encoding="utf-8") != content:
            stale.append(str(where.relative_to(ROOT)))
            if not check:
                where.parent.mkdir(parents=True, exist_ok=True)
                where.write_text(content, encoding="utf-8")
    if check:
        if stale:
            sys.exit("Out of date: %s. Run scripts/site/render_site.py and commit." % ", ".join(stale))
        print("OK: generated site files are up to date")


main()
