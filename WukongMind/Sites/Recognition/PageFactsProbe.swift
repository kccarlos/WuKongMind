import Foundation

/// The probe script: collects the declared `PageFactKeys` of a document into
/// the dictionary `PageFacts(probe:fallbackURL:)` reads. Built from the
/// registry's union of keys, so an allowlist of keys decides what leaves the
/// page, not "the first N metas".
enum PageFactsProbe {
    /// "Looks like a thread" (Learn on ask 8): a fixed check on the document
    /// that is already loaded. It reads the DOM only: no model, no request.
    /// True for forum markup (JSON-LD or microdata `DiscussionForumPosting` /
    /// `Comment`), a generator tag of known forum software, or three or more
    /// sibling blocks that each hold a profile link, a time and some text.
    static let looksLikeThreadFunction = """
    const looksLikeThread = () => {
      try {
        const forumType = /DiscussionForumPosting|"@type"\\s*:\\s*"Comment"/;
        for (const node of document.querySelectorAll('script[type="application/ld+json"]')) {
          if (forumType.test((node.textContent || "").slice(0, 200000))) return true;
        }
        if (document.querySelector(
          '[itemtype*="DiscussionForumPosting"], [itemtype$="schema.org/Comment"]'
        )) return true;
        const generator = document.querySelector('meta[name="generator"]');
        if (generator && /phpbb|vbulletin|xenforo|discourse|flarum|mybb|invision|simple machines|fluxbb|nodebb|vanilla|discuz|punbb/i
          .test(generator.getAttribute("content") || "")) return true;
        const profile = 'a[href*="/user"], a[href*="/member"], a[href*="/profile"], a[href*="/u/"], a[href*="/users/"], a[href*="memberlist"]';
        const parents = new Map();
        const blocks = document.body ? document.body.querySelectorAll("article, li, div, tr, section") : [];
        const limit = Math.min(blocks.length, 3000);
        for (let index = 0; index < limit; index++) {
          const block = blocks[index];
          if (!block.parentElement) continue;
          if (!block.querySelector(profile) || !block.querySelector("time, [datetime]")) continue;
          if ((block.textContent || "").trim().length < 30) continue;
          const key = block.parentElement;
          const kin = parents.get(key) || new Set();
          kin.add(block.tagName);
          parents.set(key, kin);
          if (kin.size === 1) {
            let count = 0;
            for (const sibling of key.children) {
              if (sibling.tagName === block.tagName && sibling.querySelector(profile)
                && sibling.querySelector("time, [datetime]")) count++;
            }
            if (count >= 3) return true;
          }
        }
      } catch (error) {}
      return false;
    };
    """

    /// A JavaScript expression that evaluates to the probe function. It keeps
    /// a small cache (JSON paths in big datasets are read once per document),
    /// so evaluate it once per document and call the function many times.
    static func expression(keys: PageFactKeys) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(keys)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (() => {
          const keys = \(json);
          const cache = new Map();
          const clip = (value, limit = \(PageFacts.valueLimit)) =>
            typeof value === "string" ? value.trim().slice(0, limit) : "";
          const walk = (value, props) => {
            let current = value;
            for (const prop of props) {
              if (typeof current === "string") {
                try { current = JSON.parse(current); } catch (error) { return ""; }
              }
              if (current === null || typeof current !== "object") return "";
              current = current[prop];
            }
            if (typeof current === "number") return String(current);
            return clip(current);
          };
          const read = (id, element, entry) => {
            const [name, path] = entry.split(":");
            const raw = element.dataset ? element.dataset[name] : undefined;
            if (path === undefined) return clip(raw);
            const cacheKey = id + "/" + entry;
            if (!cache.has(cacheKey)) cache.set(cacheKey, walk(raw, path.split(".")));
            return cache.get(cacheKey);
          };
          \(looksLikeThreadFunction)
          return () => {
            const meta = {};
            for (const name of keys.meta) {
              const element = document.querySelector(
                "meta[name=" + JSON.stringify(name) + "], meta[property=" + JSON.stringify(name) + "]"
              );
              if (element) meta[name] = clip(element.getAttribute("content"));
            }
            const links = {};
            for (const rel of keys.links) {
              const element = document.querySelector("link[rel~=" + JSON.stringify(rel) + "]");
              if (element) links[rel] = clip(element.href);
            }
            const elements = {};
            for (const id of Object.keys(keys.elements)) {
              const element = document.getElementById(id);
              if (!element) continue;
              const entry = {};
              for (const key of keys.elements[id]) entry[key] = read(id, element, key);
              elements[id] = entry;
            }
            const matches = keys.selectors.filter(selector => {
              try { return Boolean(document.querySelector(selector)); } catch (error) { return false; }
            });
            const icon = document.querySelector(
              'link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]'
            ) || document.querySelector('link[rel~="icon"]');
            return {
              url: window.location.href,
              title: clip(document.title),
              meta: meta,
              links: links,
              elements: elements,
              matches: matches,
              htmlClass: clip(document.documentElement?.className, 2000),
              bodyClass: clip(document.body?.className, 2000),
              iconURL: icon?.href || "",
              looksLikeThread: looksLikeThread()
            };
          };
        })()
        """
    }
}
