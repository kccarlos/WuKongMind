# WukongMind (悟空)

WukongMind is a fork of Forumind into a self-use, open-source iOS/iPadOS browser whose AI agent reads and changes any web page by running JavaScript, and saves the changes as per-site userscripts.

- The full requirements are in [requirements.md](requirements.md).
- English first: code, docs, commits and pull requests are in English.
- This repo started as a copy of Forumind `main` (e046b43). The `forumind` remote is fetch-only; never push to it.
- Milestones run in order (M0 to M4); each needs the owner's acceptance before the next. M0 comes first: read the Forumind code and write the module map and change list for the owner to confirm before any code changes.
- Open questions in section 11 of the requirements use their stated defaults until the owner decides: a separate repo (this one), separate bundle ID and iCloud container, no preset agent model, Discourse features kept.
- Forumind's own docs, AGENTS/CLAUDE rules and tests still apply, and its existing features and tests must keep passing.
