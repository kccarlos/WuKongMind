# Website review from a first-time visitor's side (WUKO-202)

Reviewed 2026-11-20: the live site <https://kccarlos.github.io/WuKongMind/> as WUKO-201 left it
(source `site/`, built by `scripts/site/build.py`), at 390 × 844 and 1280 × 800, light and dark, in English,
简体中文 and 繁體中文, as someone who has never heard of WukongMind. Claims were checked against
`appstore/metadata/en-US/description.txt`, `store-positioning.md`, `PRIVACY.md` and the app's own
Settings › Agent › Safety footer. Section 6 says what this task changed.

## 1. Five seconds: what problem does this solve for me?

It does not say. Above the fold a visitor reads:

- the headline "WukongMind Browser" (a name),
- "AI agent for any web page" (a category),
- "A browser … with one box on every page. Ask the Agent to read, change or automate the page you are on" (a
  mechanism and three verbs),
- a large gold ring with a caption that explains the ring.

No line names a problem a person has (a page buried in banners, text that is hard to read, an article too long
to read now, the same fix on every visit) or what they get. "One box on every page" is how the app is built, not
why anyone would want it. The hero picture is an abstract ring: it shows that something turns and finishes, not
that a page got better. The first before-and-after is one screen further down.

On a phone the fold is worse. The header wraps into three rows in English and 繁體中文 (brand, four links, three languages)
and uses 150 px before the headline starts. The quoted request is cut mid-typing when the page opens.

There is nothing a visitor can do. `testflight_url` is still a placeholder, so the only buttons are "See how
it works" and "View the source". That needs the owner (a TestFlight or App Store link in `site/config.json`);
this task does not invent availability wording.

## 2. Does the story run problem → ask → result → trust?

| Step | Today | Verdict |
|---|---|---|
| Problem | Never stated. The demo page is a clean article; "make this page dark" is the only pain shown | Missing |
| What you do | "Ask, and the page changes", step 1 "Say what you want" | Good, but second on the page |
| What you get | The article turns dark; "Like it? Ask the Agent to keep it" is a half sentence in step 3 | Present, weak: the kept script is the lasting result and comes two sections later |
| Why trust it | "Built to be careful" (four bullets) and "Your data" (one paragraph), after a seven-card feature grid | Last and in engineer's words: "cookie values", "WebKit", "filter lists … compiled on your device" |

The order today is: name → ring → demo → address field → scripts → screenshots → feature grid → safety → data.
"One box, on every page" (how the address field routes text) sits between the result and the script that
keeps it, and interrupts the story.

## 3. Design system and the gold ring

Checked by extracting every colour, radius, font size and shadow from `styles.css` and `home.css` and comparing
them with `design/design-system/tokens.json` and the README.

What holds: every page colour is a token (ground, surface, raised, ink, gold, gold-ink, gold-wash, jade); gold
is the only brand colour; text on gold is `on-gold`; buttons are `radius-md`, cards `radius-lg`; no gradients;
system fonts; focus is the 2 px `gold-ink` ring; cinnabar appears only on the Stop button. The phone mock-ups
copy the real components (glass bar, ToolRow, composer, Add script sheet) at about 0.7 scale, so their radii
and sizes are scaled values, and the article inside is a website's own colours. Both are fine.

What does not:

| Finding | Where | Why it matters |
|---|---|---|
| The hero ring is no real surface | `.bigring`, 168 to 200 px | Every ring in the app is the bar button, the pill, a tool row or the composer. A giant free-floating ring is decoration, which the system forbids ("motion shows a live signal or a cause") |
| Three of the four states a person meets | legend: "Ask", "Working", "Answer ready" | "Needs your answer" (the ring with a question mark, when a confirmation card waits) is missing, and it is the trust state. "Ask" is not a ring word (idle has none) and reads like "needs you" |
| Caution note in `gold-wash` | `.note` | Gold means the Agent and the primary action. A caution is `warning` plus a word; colour alone never carries a state |
| Shadows are not the tokens | `.bbar`, `.drawer` use 24 px blurs | Tokens: `shadow-pop` 0 12px 40px .22, `shadow-panel` 0 -8px 30px .16 |
| Type sizes outside the scale | 14 px (legend, captions, Pause, footer), 19 px (lead), 20 px | The scale is 34 / 22 / 17 / 15 / 13 / 12. 44 px (desktop headline) and 28 px (phone section title) are web-only display sizes and are kept |
| Section spacing | fine (multiples of 4) | n/a |
| A leaked-looking placeholder | "By [AUTHOR]" in the mock article | Reads as an unfinished template to a visitor |

## 4. Cut, missing, confusing, and claims the app cannot back

Cut:

- The big hero ring, its rotating quotes and its caption (decoration; replaced by a real surface).
- "One box, on every page" as its own section. Its one useful idea (type a request where you type an address)
  belongs in the hero demo, shown once.
- The seven-card "What it does" grid. It repeats the demos ("Just ask", "Keep what works") and lists the rest
  in engineer's words. Problems the visitor has replace it; the rest becomes one short list.
- One of the three "Pause animations" buttons: one fewer looping demo.

Missing:

- A headline and one line that name the problem and the outcome, in all three languages.
- A page that looks like a problem. The demo article has nothing wrong with it.
- The "needs you" ring and what the Agent asks before.
- Trust near the top: three short facts under the buttons.
- Anything to tap to get the app (owner; see section 1).

Confusing:

- zh-Hans calls the Agent "智能体" in the text and "代理" inside the mock-ups. The mock-ups are right: the
  app's interface says "代理" in both Chinese variants, and the store listing says "智能体" (zh-Hans) and
  "代理" (zh-Hant). Not fixed here: the site follows the store listing in prose and the app in the mock-ups.
  Follow-up for the owner: pick one word for zh-Hans in the app and the listing.
- "Agent", "script", "user script", "JavaScript and CSS", "WebKit", "cookie values" arrive before the visitor
  knows what they get.

Claims that are wrong or too strong:

| On the site | The app | Fix |
|---|---|---|
| "The Agent asks before it changes things … by default" | Changes to the open page run without a question (Settings footer: "it does not prompt for JavaScript on the open page"). It asks before a network request, a notification or a script tool that can make changes (default on), and always before reading cookies or sending your login to another site | Say exactly that. The same goes for "you approve every change": the true line is "you see every step, and nothing is kept unless you approve it" |
| "… so a page cannot give the Agent orders" | Page text is wrapped as untrusted; tests showed injected text was not obeyed, which is not a guarantee | "Text on a web page is treated as content, not as instructions" |
| "Translate a page" | The listing says "translate on-screen text or summaries on your device (iOS 18 or later)" | Use the listing's words |
| "Apple Intelligence on devices that have it" under "Your choice of AI" | Apple Intelligence runs page summaries only, not the Agent | Say "for page summaries" |
| "Fewer ads and trackers" | True, and off by default | Say "off until you turn it on" |
| "Scripts you approve" | True by default; Settings has "Save scripts without asking" | Keep, it is the default |

Outside this task's files: the privacy page is rendered from `PRIVACY.md`, which still names daily digests,
podcast scripts and built-in forum readers. That text needs its own task.

## 5. Ranked suggestions

1. **Lead with the problem and the outcome.** Headline: "Make any web page work your way." One line under it
   that names the pains and the promise. The product name moves to a small line above. *Because a visitor
   decides in seconds whether this is for them, and a name answers nothing.*
2. **Make the hero a real before and after.** A phone with a page covered by a subscribe banner and a cookie
   box; the request typed where you type an address; the Agent's panel opens, its two steps turn and finish,
   and the banners go. *Because the picture should be the result, and this is the app's real flow
   (design-motion.md section 3, step 6: "Ask the Agent" closes Home and opens the panel).* The bar ring stays
   still here, as in the app: with the panel open, the panel's tool rows are the ring that turns, and "Answer
   ready" shows on the bar only when a run ends with the panel closed.
3. **Three trust facts under the buttons.** Every step shown with Stop; your own AI; no accounts, no tracking,
   open source. *Because "an AI that changes web pages" raises the worry before the interest.*
4. **Replace the feature grid with "What gets in your way?"** Four problems, each with the sentence you would
   say. *Because people recognise their problem faster than a feature name.*
5. **Tell the story in order:** hero → problems → ask and watch → keep it as a script you approve → the app's
   real screenshots → why trust it → the rest of the browser. *Because each section should answer the question
   the previous one raised.*
6. **Show the ring's four real states once, with their words,** next to what the Agent asks before. *Because the
   ring is how a person knows where things stand, and "Needs your answer" is the reason to trust it.* The words
   are the app's own strings ("Working", "Needs your answer", "Answer ready" and their Chinese). Idle has no
   word in the app; the site captions that picture "Ready" (待命), which is the site's label, not an app string.
7. **Rewrite trust in plain words and make every line true** (the table in section 4). *Because one overclaim
   on a safety line costs more than it gains.*
8. **Make the demo page look like the problem** and drop "By [AUTHOR]". *Because a clean article needs no fixing.*
9. **Shorten the phone header to two rows** (short language labels). *Because 150 px of navigation sits above
   the pitch.*
10. **Bring the remaining details in line with the design system** (shadows, caption sizes, the caution note).
11. **Chinese written as Chinese:** short sentences, said directly, no exclamation marks, each variant in its
    own vocabulary.

Not suggested: more motion, a mascot, testimonials or numbers we do not have, comparison with other browsers
(the store rules forbid naming them), any availability promise.

## 6. What this task changed

Suggestions 1 to 11 are implemented in the same pull request. Not done, with the reason: the "get the app"
button (needs the owner's link), the zh-Hans word for the Agent in the app and the listing, and `PRIVACY.md`
(both outside `site/`, `scripts/site/` and docs).
