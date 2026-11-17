# Feedback reports (TestFlight)

The owner sends feedback with TestFlight's screenshot feedback; the matching task export reaches the Mac by itself through the app's iCloud Drive container. The Assistant reads the feedback with `asc testflight feedback list` and opens the report with the same time.

## What saves a report

- **⋯ › Report a problem** in the Agent drawer (every build, not only developer mode): the same alert, redaction and refusals as ⋯ › Export task (API keys and cookies removed; a task whose cookies can't be removed is refused). It saves the last finished task and shows a short toast.
- **A task that ends in an error** saves itself when Settings › Agent › Developer › **Save failed tasks for feedback** is on: an API or network error (the run ends as failed) or the step limit. A completed task, or one stopped with Stop, doesn't. A "Don't allow" on a confirmation card doesn't end a run (the model is told and carries on), so it never saves by itself; nor does a run refused before it starts (no model or no API key), which has no task record. The switch is on by default in TestFlight builds and off elsewhere, and it stays on each device (it doesn't sync). An automatic save shows no toast; a task whose export is refused is skipped.

## Where reports land

| Build and account | On the iPhone or iPad | On the Mac |
| --- | --- | --- |
| Generated with `DC_ENABLE_CLOUDKIT=YES`, signed in to iCloud | the container `iCloud.io.github.kccarlos.wukongmind`, `Documents/Reports/` | `~/Library/Mobile Documents/iCloud~io~github~kccarlos~wukongmind/Documents/Reports/` |
| No CloudKit build, signed out, or the container unavailable | the app's own `Documents/Reports/` (Files › On My iPhone › WukongMind › Reports); the toast says iCloud isn't available | nothing: share it from the Files app |

The container isn't public (`NSUbiquitousContainerIsDocumentScopePublic` is false), so it doesn't show as a folder in iCloud Drive, but the Mac still syncs it to the path above. `ls` there may show a not-yet-downloaded report as `.<name>.icloud`; `brctl download <path>` or opening it fetches it.

The app keeps the newest **50** reports (and at most 200 MB of them) and deletes older ones after each save. Files in the folder that aren't reports are left alone.

## File names

`<time>-<host>-task.json`, for example `20261117T093012Z-news.ycombinator.com-task.json`:

- `<time>`: when the report was saved, in **UTC**, ISO 8601 basic format (`yyyyMMddTHHmmssZ`), so names sort by time and have no colons.
- `<host>`: the host of the page the task started on, lowercased (`no-page` without one).
- A second report in the same second gets `-task-2.json`.

The file is a normal task export (`"format": "wukongmind-task"`, see design-m3.md "Task export"): `exported_at` is the save time, `app.version` and `app.build` the app's version and build.

## Matching a TestFlight feedback item to a report

1. List the feedback: `asc testflight feedback list` gives each item's `createdDate` (UTC) and build.
2. Find the report saved just **before** the feedback's `createdDate`: the owner taps Report a problem (or the task fails) and then takes the screenshot, usually within a few minutes.
   ```sh
   ls ~/Library/Mobile\ Documents/iCloud~io~github~kccarlos~wukongmind/Documents/Reports/
   ```
3. Check `app.build` in the report against the feedback's build.
