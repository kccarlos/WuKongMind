import Foundation

/// What a site supports. Each operation is a value: present and working, or
/// nil, so no capability says yes and then throws. There are no flags for
/// data the pages themselves show (accepted answers, scores, author blocking):
/// consumers gate on the data (`facts?.acceptedAnswer`, `likeCount > 0`).
struct SiteCapabilities: Sendable {
    var postIdentity: PostModerationIdentity = .number

    /// Candidates for the digest and podcast.
    var activeTopics: (any ActiveTopicsSource)?
    /// Post text by number from the API when the page doesn't have it.
    var postLookup: (any PostLookup)?
    /// Narrowed views of a topic (top posts, one author); nil = none.
    var topicFilters: (any TopicFilterSource)?
    /// The in-page bridge and DOM moderation.
    var pageBridge: PageBridgeProfile?
    /// The site's sign-in page.
    var loginURL: (@Sendable (_ siteURL: String) -> URL?)?
    /// The signed-in user's account page.
    var accountURL: (@Sendable (_ siteURL: String, _ username: String?) -> URL?)? = nil
    /// The site's own search page for typed words.
    var searchPageURL: (@Sendable (_ siteURL: String, _ query: String) -> URL?)?
    /// The browser reads signed-in state and username from page facts.
    var session: (any SessionReader)?
    /// First-party paths the content blocker must never block.
    var firstPartyPathPatterns: [String]
}

protocol ActiveTopicsSource: Sendable {
    /// At most `budget` requests. Reports how many it used, so the digest's cap holds.
    func activeTopics(siteURL: String, budget: Int, net: SiteNetwork) async -> ActiveTopicsResult
}

struct ActiveTopicsResult: Sendable {
    var topics: [ForumTopicListing]?
    var requests: Int
    var failures: Int
}

protocol PostLookup: Sendable {
    func posts(_ numbers: [Int], in topic: TopicRef, facts: TopicFacts, net: SiteNetwork) async throws -> [ForumPost]
}

enum TopicFilter: Equatable, Sendable {
    case top
    case author(String)
}

protocol TopicFilterSource: Sendable {
    /// The topic URL narrowed by `filter`; `slug` is the page's own, when known.
    func url(topic: TopicRef, slug: String?, filter: TopicFilter) -> URL?
    /// True when `url` already is a filtered view.
    func isFiltered(_ url: URL) -> Bool
    /// The filtered topic's overview (the posts the filter shows).
    func overview(_ topic: TopicRef, filter: TopicFilter, net: SiteNetwork) async throws -> ForumTopicOverview
}

protocol SessionReader: Sendable {
    /// Signed-in state and the user's name from the page's facts.
    func session(from facts: PageFacts) -> (authenticated: Bool, username: String?)
}

/// What the page DOM scripts need.
struct PageBridgeProfile: Sendable {
    /// Nil when numbered-post reading/translation is unsupported.
    var bridgeInstaller: String?
    var moderationInstaller: String
    var moderationObject: String = "__forumindModeration"
    /// Native comment navigation, independent of numbered-post reading.
    var anchorScrollScript: String?
}

extension PageBridgeProfile {
    /// Comment moderation and native-anchor scrolling, without numbered-post reading.
    /// Each installer has its own object because all adapters' scripts coexist.
    static func comments(object: String, rows: String, author: String, body: String,
                         number: String, contents: String = "[row]", authorText: String = "element.textContent", hiddenPosts: String) -> Self {
        Self(bridgeInstaller: nil, moderationInstaller: """
        (() => {
          if (window.\(object)) return;
          const attr = 'data-forumind-hidden';
          let config = { users: [], words: [], posts: {} };
          const rows = () => Array.from(document.querySelectorAll('\(rows)'));
          const contents = row => \(contents);
          const number = row => \(number);
          // Prefer specific content containers before a whole-comment fallback.
          const own = (row, selector) => selector.split(',').flatMap(part => Array.from(row.querySelectorAll(part))).find(element => element.closest('\(rows)') === row);
          const author = row => {
            const element = own(row, '\(author)');
            return (element ? \(authorText) : '').replace(/\\s+/g, ' ').trim();
          };
          const body = row => own(row, '\(body)');
          let wasActive = false;
          function apply() {
            const userKey = name => name.toLowerCase().replace(/\\s+/g, '_');
            const users = new Set(config.users.map(userKey));
            const words = config.words.map(word => word.toLowerCase());
            const hidden = \(hiddenPosts);
            const active = users.size > 0 || words.length > 0 || hidden.length > 0;
            if (!active && !wasActive) return;
            wasActive = active;
            rows().forEach(row => {
              const text = (body(row)?.textContent || '').toLowerCase();
              const hide = (author(row) !== '' && users.has(userKey(author(row)))) || hidden.includes(number(row))
                || words.some(word => text.includes(word));
              contents(row).forEach(element => {
                if (hide) element.setAttribute(attr, '');
                else element.removeAttribute(attr);
              });
            });
          }
          let scheduled = false;
          function schedule() {
            if (scheduled) return;
            scheduled = true;
            requestAnimationFrame(() => { scheduled = false; apply(); });
          }
          window.\(object) = {
            update(value) { config = value; apply(); },
            scrollToAnchor(anchor, smooth) {
              const id = Number((anchor.match(/[0-9]+$/) || [])[0]);
              const row = rows().find(row => row.id === anchor || number(row) === id);
              if (!row) return 'missing';
              const elements = contents(row);
              if (row.hasAttribute(attr) || elements.some(element => element.hasAttribute(attr))) return 'hidden';
              if (row.getClientRects().length === 0) return 'missing';
              row.scrollIntoView({behavior: smooth ? 'smooth' : 'instant', block: 'start'});
              const target = body(row) || row;
              target.animate([{backgroundColor: 'rgba(255, 190, 60, 0.45)'}, {backgroundColor: 'transparent'}], {duration: 1800});
              return 'shown';
            },
            posts() {
              return rows().filter(row => {
                return contents(row).some(element => {
                  const rect = element.getBoundingClientRect();
                  return !element.hasAttribute(attr) && rect.height > 0
                    && rect.bottom > 0 && rect.top < window.innerHeight;
                });
              }).map(row => ({
                number: number(row), username: author(row),
                excerpt: (body(row)?.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 160)
              })).filter(post => post.number > 0 && post.username);
            }
          };
          function start() {
            const style = document.createElement('style');
            style.textContent = '[' + attr + '] { display: none !important; }';
            (document.head || document.documentElement).appendChild(style);
            new MutationObserver(schedule).observe(document.documentElement, {
              childList: true, subtree: true
            });
            apply();
          }
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
          else start();
        })();
        """, moderationObject: object, anchorScrollScript: "if (number === 1) { window.scrollTo({top: 0, behavior: smooth ? 'smooth' : 'instant'}); return 'shown'; } return window.\(object)?.scrollToAnchor(anchor, smooth) ?? 'unavailable';")
    }
}

/// Persisted/page moderation IDs versus the positional numbers used in AI text.
enum PostModerationIdentity: Sendable {
    case number
    case native(anchorPrefix: String)

    func id(anchor: String) -> Int? {
        guard case .native(let prefix) = self, anchor.hasPrefix(prefix),
              let id = Int(anchor.dropFirst(prefix.count)), id > 0 else { return nil }
        return id
    }

    func anchor(number: Int, nativeID: Int) -> String? {
        guard case .native(let prefix) = self else { return nil }
        let nativeID = id(number: number, nativeID: nativeID)
        return nativeID > 0 ? prefix + String(nativeID) : nil
    }

    func id(number: Int, nativeID: Int) -> Int {
        switch self {
        case .number: return number
        case .native(let prefix): return number == 1 && !prefix.isEmpty ? 0 : nativeID
        }
    }

    func aiRules(_ rules: ModerationRules, siteURL: String, topicID: String,
                 blocks: [PostBlock], facts: TopicFacts?) -> ModerationRules {
        guard case .native(let prefix) = self else { return rules }
        let key = "\(siteURL)|\(topicID)"
        // Unprefixed HN item IDs are unique across all story/context pages.
        let ids = prefix.isEmpty
            ? Set(rules.hiddenPosts.filter { $0.key.hasPrefix(siteURL + "|") }.flatMap { $0.value })
            : rules.hiddenPosts[key] ?? []
        guard !ids.isEmpty else { return rules }
        var result = rules
        var identities = Dictionary((facts?.posts ?? []).map { ($0.number, id(number: $0.number, nativeID: $0.id)) },
                                    uniquingKeysWith: { _, last in last })
        for block in blocks where identities[block.number] == nil {
            if let nativeID = id(anchor: block.anchor) { identities[block.number] = nativeID }
        }
        identities[1] = prefix.isEmpty ? Int(topicID) : 0
        result.hiddenPosts[key] = Set(identities.compactMap { ids.contains($0.value) ? $0.key : nil })
        return result
    }
}
