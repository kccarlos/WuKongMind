# Instructions for AI agents

WukongMind is a fork of Forumind into an agent browser for iOS/iPadOS. Start with [docs/wukongmind/README.md](docs/wukongmind/README.md) and [the requirements](docs/wukongmind/requirements.md).

- The owner's wiki at `~/Documents/vault/wiki` holds how they want agents to work and lessons from Forumind and their other Apple projects. Read `wiki/index.md` first, then only the pages the task needs (`profile/developer-style.md`, `projects/apple/index.md`).
- English first: code, docs, commits and pull requests.
- Live browser-agent checks (DEBUG, no saved state touched): launch with `-dc-browser-agent-live-prompt` on a simulator, or run `WukongMindUITests/PhysicalDeviceSmokeTests/testLiveBrowserAgentDarkAndHideSidebar` with `TEST_RUNNER_ANTHROPIC_API_KEY` set; unit tests use recorded responses.
- Real-device checks only via `scripts/device-check.sh` (it takes the shared-phone lock): never touch the physical iPhone outside it, not even for a quick `devicectl` check. See docs/DEVELOPMENT.md.
- Run simulator builds and tests with `scripts/remote-test.sh` (they run on the Mac mini); local `xcodebuild` only when the mini is unreachable (the script says so, exit 69). Device tests stay on `scripts/device-check.sh`. See docs/DEVELOPMENT.md.
