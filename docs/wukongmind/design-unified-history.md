# Unified interface design: review history

The review rounds behind [design-unified.md](design-unified.md), oldest first. They record what changed and why; [design-unified.md](design-unified.md) holds only the current rules and wins where this page disagrees. Rows here may describe things that were later removed.

## Owner review of 2026-11-12: what changed, and where

Rows 1, 2 and 4 and parts of 3 are superseded by roadmap v2 (next section): the shared results, the send-to Menu and the run-now row are gone. The rest still holds.

| # | Comment | Change | Boards | Spec |
|---|---|---|---|---|
| 1 | Shared context or clearly separate (*superseded*) | Option a: earlier results go along as shared results, up to 8,000 characters, shown as removable pills before sending and above the bubble after | PhoneResearch (pills in the composer and above the bubble; summary points numbered) | Section 1 › Shared results |
| 2 | Token is transitional; title vs pill (*superseded*) | The send-to Menu replaces the token. The title, symbol and pill follow the target. End state noted: adapters' read-thread and search-site become Agent tools, and the Menu goes | PhoneResearch (title "Research" with a blue pill), PhonePanelForum, IPadForum, QuickRowCheck, Glossary, IA (end-state stub), Motion row 1 | Section 1 › The send-to Menu is transitional; glossary |
| 3 | Room for voice (*voice turns now One loop*) | Mic in every input box, voice turns in the conversation, IA stub "Voice drives the Agent", group renamed **Voice & digest** | PhonePanelForum, PhonePanelPage, IPadForum (voice turns drawn), IPadPage, PhoneOnb3, IA, PhoneSettings, IPadSettings | Section 1 › Voice; IA; placeholders; Settings |
| 4 | Row overflow; two behaviours look alike (*overflow check kept on SuggestionRow*) | Ask actions move into the send-to Menu, so the row holds only run-now chips, now solid blue. The row scrolls sideways. Checked with "Summary · 12 new", Accessibility XXL and Chinese | QuickRowCheck (new), PhonePanelForum, PhoneResearch, IPadForum, Motion row 3 | Section 1 › Run-now chip look, Overflow |
| 5 | Purple and the sparkle mean one thing | Forum badge is now a grey speech bubble. The This page chip and its kind pill are neutral. Scripts & tools icon is grey | PhoneHome, IPadHome, PhoneOnb2, IPadOnb, PhoneThisPage, PhonePanelForum, PhonePanelPage, PhoneResearch, IPadForum, IPadPage, PhoneSettings, IPadSettings, Motion row 4 | Opening rules; sections 2 and 3 |
| 6 | Two address entries on Home | The top field is the only one. The bar hides its capsule on Home (iPad shows a plain title) | PhoneHome, IPadHome | Section 3 |
| 7 | No search engine setting | Browser › Search engine (Google default) | PhoneSettings, IPadSettings (row value), IA | Section 4 › Browser |
| 8 | IA and popover disagree; plain-text row | Popover's first group is "This topic" with only the Follow switch. The text row is gone. IA matches | PhoneThisPage, IA | Section 2 |
| 9 | Recent tasks vs History | One concept: History holds all saved items, and Home shows "Recent" (its newest items) with a History link | PhoneHome, IPadHome, Glossary, IA | Section 3; glossary |
| 10 | Remove code renames | Glossary shows today's code names only. Renames go to the cleanup's rename task. `SettingsPage.provider` keeps its case and is retitled Models | Glossary, Main, Migration | Glossary; Settings tables |
| — | Self-check (iPad, dark, onboarding, settings subpages, migration, motion) | iPad boards: the same composer, chips and neutral chip as iPhone. Dark boards inherit every change. Onboarding: mic in step 3, grey badge in step 2 on both devices. Settings subpages (Models, Agent, Sites) have no purple-only-for-scripts and no explaining copy left. Migration and motion boards are updated | IPadForum, IPadPage, IPadHome, IPadSettings, IPadOnb, all *Dark wrappers, PhoneOnb2/3, Migration, Motion | Migration list; Motion |

## Roadmap v2 "Just ask" (2026-11-12): what changed, and where

| # | Revision | Change | Boards | Spec |
|---|---|---|---|---|
| 1 | Send-to target menu: delete | Gone from the composer, the menus list, the motion table and the glossary | PhonePanelForum(+Dark), IPadForum(+Dark), PhoneResearch, SuggestionRow (replaces QuickRowCheck), Glossary, Motion | Opening rules; section 1; glossary |
| 2 | Shared results chip: delete | Gone. One Agent remembers the conversation | PhoneResearch, Glossary, Motion | Section 1; glossary |
| 3 | Title and pill follow the target: delete | Title is always "Agent"; the pill shows only the Agent's model | PhoneResearch, all panel boards, IA | Section 1, header |
| 4 | Run-now row → suggestion row | Neutral capsules, each a full question that sends on tap; "…" fills the box. Per page: forum thread (4), forum list (2), ordinary page (3), frequent site, unfamiliar forum. No grey states, up to 4 on screen, more scroll. Overflow rechecked (longest, Accessibility XXL, Chinese) | PhonePanelForum, PhonePanelPage, PhoneResearch, IPadForum, IPadPage, SuggestionRow, Motion rows 1–3 | Section 1: suggestions per page, look, tap, overflow; direction 1 |
| 5 | Result styles: keep | Summary card, sourced answer and podcast row are how Agent tool results display. One row per tool call, expandable | PhoneResearch, PhonePanelForum, PhonePanelPage, IPadForum, KeyboardUp | Section 1: transcript, tool rows |
| 6 | Mic: keep, two phases | One panel: dictation into the box, forum voice entry stays. One loop: voice session sharing the Agent's tools | All panel boards (mic labelled Dictate), IPadForum (voice turns removed), IA | Section 1: Voice, Phases; migration (Browser shell) |
| 7 | Settings › Models: two roles | Agent and Summaries, plus the M4 Scripts row (same as Summaries). Summary batching and instructions join Models › Summaries | PhoneModels, PhoneSettings, IPadSettings (2 roles), IA | Section 4 |
| 8 | Settings › Sites: no Research or Summaries & chat pages | Forum search limits move to Agent › Forum search; chat context goes | PhoneSites(+Dark), PhoneAgentSettings, IA | Section 4; migration (Settings) |
| 9 | This page: keep, developer placeholder | A dashed "Developer" group for the site inspector (Learn on ask, developer mode only) | PhoneThisPage(+Dark), IPadPage(+Dark), IA | Section 2 |
| 10 | IA reserved slots by milestone | "End state" and "Later · voice" stubs removed; slots now One panel, M3, One loop, M4, Learn on ask | IA | Information architecture |
| 11 | Keyboard-up state | New board: status folds into the header; the row stays while empty, hides while typing | KeyboardUp(+Dark), Motion row 3 | Section 1: Keyboard up |
| 12 | Migration "assistant panel" rewritten | Four modes → one conversation view + suggestion row; containers stay; Research loop and Topic chat deleted in One loop; roles 3 → 2 | Migration | Migration list |
| 13 | Unchanged parts | Onboarding, other settings pages, This page, the vocabulary rule and purple-only-Agent are kept. Motion keeps its tokens; only the rows about deleted things were redrawn. The start page keeps its layout; two consequences are proposals: History's segments (All, Conversations, Following) and Recent rows showing conversations | PhoneHome, IPadHome (Recent rows) | Proposals; section 3 |
| — | Developer mode switch | Settings › Agent › Developer (M3, default off) | PhoneAgentSettings, IA | Section 4; IA table |

## Owner feedback on the third draft (2026-11-12): what changed, and where

The owner agreed to all six proposals, which are now under "Decided".

| # | Feedback | Change | Boards | Spec |
|---|---|---|---|---|
| 1 | Switch to the new design system | Motion follows the owner's compromise (section 6): the ring is the only continuous animation, plus two 250 ms transitions. Every board uses its tokens: ink, gold, jade and cinnabar on warm paper or lacquer black, with no gradient, no purple and no capsule. Its components are used throughout: Composer, SuggestionRow, ToolRow, ResultCard, Message, Seal, Switch, ListRow and BrowserBar. The Agent's mark is the thin gold ring (bar, composer, running tool). The Logo is on onboarding step 1. The Mascot is in the panel states: wave when empty, think, run and search while working, cheer when done, at most one per screen | All boards; PanelStates (+Dark) is new; PhoneOnb1 (Logo); PhoneOnb3 (cheer) | Opening section; section 1 tree; Settings tree |
| 2 | Token count only in developer mode | The status row shows "Done · 3 steps · 9 s"; tokens join it in developer mode | All panel boards | Section 1, status row; IA table (M3) |
| 3 | Fixed part too tall | Host and This page merge into one seal at the end of the status row; the separate row is gone. The fixed part is about 230 of 500 pt (46%), down from about 265 (53%). Still nearly half: the next saving would be the status row itself | All panel boards, PhoneThisPage, KeyboardUp | Direction 2; section 1, status row |
| 4 | No "Forum ·" in the pill | The seal shows host and script count only; site type is internal. The grey badge stays only on Home's tiles (removed from onboarding) | Panel boards, PhoneThisPage, IPadPage, PhoneOnb2, IPadOnb | Opening rules; section 2 |
| 5 | How an unfamiliar forum is recognised | Until Learn on ask it isn't, so the ordinary-page row shows. From Learn on ask, a proposal: a no-model page check (generator meta today; JSON-LD types and repeated post blocks need two new probe fact keys), overridden by the site's shape state | SuggestionRow (two rows, by milestone) | Section 1, Unfamiliar forums |
| 6 | One panel follow-ups fail | Requirement: a tapped suggestion's engine result text is attached as context to the Agent's next message (untrusted delimiters, capped). PhoneResearch is titled and noted as One loop | PhoneResearch (title, note) | Section 1, Phases |
| 7 | Vocabulary: Follow / Following | The suggestion stays "Notify me of new replies"; the confirmation and the This page switch say "Following" | PhoneThisPage | Decided list; section 2; glossary |
