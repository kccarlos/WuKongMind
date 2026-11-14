# WukongMind (悟空)

WukongMind is a fork of Forumind into a self-use, open-source iOS/iPadOS browser whose AI agent reads and changes any web page by running JavaScript, and saves the changes as per-site userscripts.

- The full requirements are in [requirements.md](requirements.md). [next-phase.md](next-phase.md) supplements them and wins where they conflict (including the rule that Forumind's features and tests must keep passing: features the cleanup deletes take their tests with them).
- The unified interface design is in [design-unified.md](design-unified.md); exported boards and the design system are in [design/README.md](design/README.md).
- The M3 "Full abilities" (1.2.0) design and its task split are in [design-m3.md](design-m3.md). M3 also includes page feedback, specified in [page-feedback.md](page-feedback.md).
- The One loop (1.3.0) design, comparison test and task split are in [design-one-loop.md](design-one-loop.md) (owner-approved and final, 2026-11-13). Deleting the old Research loop and Topic chat waits for the owner's approval of that comparison.
- English first: code, docs, commits and pull requests are in English.
- This repo started as a copy of Forumind `main` (e046b43). The `forumind` remote is fetch-only; never push to it.
- Milestones run in order per [section 7 of next-phase.md](next-phase.md#7-milestones); each needs the owner's acceptance before the next.
- Open questions in section 11 of the requirements use their stated defaults until the owner decides: a separate repo (this one), separate bundle ID and iCloud container, no preset agent model.
- The share extension and iCloud sync are disabled in the initial `io.github.kccarlos.wukongmind` build (`DC_ENABLE_SHARE_EXTENSION` and `DC_ENABLE_CLOUDKIT` default to `NO` in `scripts/generate_project.rb`): re-enabling them later requires the owner to register the new App Group (`group.io.github.kccarlos.wukongmind`) and iCloud container (`iCloud.io.github.kccarlos.wukongmind`) on the Apple Developer portal.
- Forumind's own docs, AGENTS/CLAUDE rules and tests still apply; how its existing features and tests are kept, rewired or deleted is governed by [sections 6](next-phase.md#6-where-every-existing-piece-goes) and [9](next-phase.md#9-handling-old-code) of [next-phase.md](next-phase.md).

## Where design output lives

The owner's three rules:

1. **Technical design** (architecture, tools, task split, acceptance) is written as documents under `docs/wukongmind/`.
2. **Visual design is changed only in the artifacts**: the unified design canvas (https://claude.ai/artifact/Daefr4AsZcSm2EWbTLU9uK) and the design system (https://claude.ai/artifact/5fGhnS4fmcmWYZbPoKTTZ2). Any new screen the design system doesn't have gets an artboard drawn on the design canvas by a design agent first, before the implementation task starts.
3. **`docs/wukongmind/design/` is a read-only export of the artifacts**, never edited by hand. Re-export after every artifact change. Each export includes a PNG of every new or changed artboard, so workers and reviewers who aren't on Claude can check the UI against the picture without opening the artifact.

## Who reviews what

- **Visual design tasks** (adding or changing artboards in the design artifacts): the worker and the reviewers run on Claude, because only Claude can open the artifacts. One Claude reviewer is enough.
- **Technical design and implementation**: any model.

## Versions and releases

Marketing versions follow milestones on the `1.x` line (see [section 7 of next-phase.md](next-phase.md#7-milestones)):

| Milestone | Marketing version | Status / notes |
|---|---|---|
| M1 | `1.0.0` | Shipped (TestFlight builds 104, 105) |
| M2 | `1.1.0` | Done (no separate release; shipped in 1.2.0). Was: in progress — persistence (userscripts); flaky-test fixes and unified UI design have no release |
| Cleanup | `1.1.x` | Four cleanup tasks (remove App Store review/listing code, rename to WukongMind, drop CI test retries) |
| One panel | `1.1.x` | Unified conversation view, suggestion row, start page, settings and onboarding (engines unchanged) |
| M3 | `1.2.0` | Accepted on recorded tests, version bumped ([m3-acceptance.md](m3-acceptance.md)); live checks left to the trial. Full abilities, workspace, developer mode part 1 (raw request inspection and task export) |
| One loop | `1.3.0` | Merge into one Agent loop; adapters and capabilities become Agent tools; voice shares tools |
| M4 | `1.4.0` | Self-extension, Tampermonkey compatibility and `GM_ai` |
| Trial | No release | Two-week daily-use trial (`docs/wukongmind/trial-notes.md` and task exports) |
| Learn on ask | `1.5.0` | Learn page tools (WebMCP shape) automatically when asked, plus site inspector |

- **Where `MARKETING_VERSION` lives (one place):** `marketing_version` in [`scripts/generate_project.rb`](../../scripts/generate_project.rb) (there are no `.xcconfig` files). Running `scripts/generate_project.rb` writes `MARKETING_VERSION` to the `WukongMind` and `WukongMindShare` targets in `WukongMind.xcodeproj`, and `Info.plist` reads `$(MARKETING_VERSION)`. `scripts/ci/check-project-drift.sh` enforces in CI that the committed `WukongMind.xcodeproj` matches `scripts/generate_project.rb`.
- **How to bump the version:** edit `marketing_version` in `scripts/generate_project.rb`, regenerate the project with `env -u DEVELOPMENT_TEAM -u BUNDLE_ID_PREFIX -u BUILD_NUMBER -u DC_ENABLE_PCC -u DC_ENABLE_CLOUDKIT -u DC_ENABLE_SHARE_EXTENSION -u DC_ENABLE_APP_GROUP ruby scripts/generate_project.rb` (or plain `ruby scripts/generate_project.rb` with no local overrides), and commit both `scripts/generate_project.rb` and `WukongMind.xcodeproj`. Leave `CURRENT_PROJECT_VERSION` at `1` in git; CI sets the build number automatically (`BUILD_NUMBER_BASE + github.run_number`, default base `100`, continuing past `105`).
- **CI vs. release triggers:** `.github/workflows/ci.yml` runs on every pull request and every push to `main`. `.github/workflows/release.yml` runs **only** on a `v*` tag push or a manual `workflow_dispatch` (never on pushes to `main`), and `scripts/ci/check-release-version.sh` fails preflight if a pushed `v*` tag does not match `MARKETING_VERSION`.
- **Release steps per milestone:**
  1. The milestone's acceptance task bumps `marketing_version` in `scripts/generate_project.rb`, regenerates `WukongMind.xcodeproj`, and lands on `main`.
  2. After milestone acceptance, the acceptance task asks the owner on an approval card before pushing the tag (for example `v1.1.0`).
  3. Once approved, push the tag (`git tag vX.Y.Z && git push origin vX.Y.Z`).
  4. `release.yml` checks that `vX.Y.Z` matches `MARKETING_VERSION`, archives with the next automatic build number, uploads to TestFlight and distributes to group `Myself` (`vars.TESTFLIGHT_GROUPS`), and creates the GitHub Release.
