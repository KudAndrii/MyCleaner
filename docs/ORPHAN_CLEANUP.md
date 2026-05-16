# Orphaned files cleanup

MyCleaner can also find support files left behind by apps you've already
removed — the leftover caches, preferences, containers, and saved state
that an app drops around `~/Library` and never cleans up when you drag the
`.app` to the Trash.

This document describes what the orphan scanner looks for, how attribution
works, and where the limits are.

## How to use it

1. Launch MyCleaner.
2. On the drop-zone screen, click **Find leftovers from removed apps**.
3. The scanner walks a handful of Library subdirectories, groups the
   findings by bundle ID, and shows each cluster with its total size.
4. Tick the bundle IDs you want to clean up and press **Move to Trash**.
   Everything goes to the user's Trash — nothing is destroyed.

After cleanup, MyCleaner also clears the matching bundle IDs from your TCC
grants (`tccutil reset All <bundleID>`) so the rows don't linger in
**System Settings → Privacy & Security**, and flushes the preferences
daemon cache (`killall cfprefsd`) so deleted plists don't get re-synced
from RAM.

## What "orphaned" means here

An entry is flagged as orphaned when **all** of the following are true:

1. Its directory or file name is shaped like a bundle ID — a dotted
   reverse-DNS identifier such as `com.example.Foo`, or a recognised
   variant (`group.com.example.Foo`, `iCloud~com~example~Foo`, a ByHost
   plist `com.example.Foo.<UUID>.plist`, a team-prefix group container
   `UBF8T346G9.Office`).
2. The bundle ID does **not** match any `.app` found by walking
   `/Applications` and `~/Applications` (one level of vendor-subfolder
   recursion) and reading each bundle's `Info.plist`.
3. As a backstop, Launch Services
   (`NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`) also
   does not resolve the bundle ID to an `.app` that still exists on disk.
   This catches apps installed in non-standard locations the walk misses
   (Setapp, `/opt`, deeply nested vendor folders).
4. The bundle ID is not in Apple's reserved namespace (`com.apple.*`,
   `apple.*`).
5. For team-prefix group containers, no app from that team identifier is
   still installed in `/Applications` or `~/Applications`.

## Scope of the scan

The scanner looks in directories where macOS conventionally names entries
after a bundle ID:

| Location | Why it's included |
|---|---|
| `~/Library/Containers` | Sandboxed app data containers |
| `~/Library/Group Containers` | App-group + team-prefix containers |
| `~/Library/Application Scripts` | App-group automation scripts |
| `~/Library/Saved Application State` | Per-app window/document state |
| `~/Library/HTTPStorages` | Cookies and HTTP storage per bundle ID |
| `~/Library/WebKit` | WebKit data per bundle ID |
| `~/Library/Preferences` | `<bundleID>.plist` files |
| `~/Library/Preferences/ByHost` | `<bundleID>.<UUID>.plist` files |
| `~/Library/Mobile Documents` | `iCloud~<tilde-encoded-bundle-id>` |
| `/Library/Preferences` | System-wide preference plists |

The scan deliberately does **not** include:

- `~/Library/Application Support` (except where its children happen to be
  bundle-ID-named) — many entries here use vendor names (`Adobe`,
  `JetBrains`, `Microsoft`) that can't be attributed to a single bundle ID
  without false positives. Use the per-app scan for those.
- `~/Library/Caches` — same problem. Caches are also auto-regenerated and
  cleaning them indiscriminately doesn't recover meaningful disk space.
- `~/Library/Logs` — most contents are merged log streams, not per-app
  files. Crash reports under `Logs/DiagnosticReports` are picked up by
  the per-app scan.
- CLI tool caches like `~/.npm`, `~/.gradle`, `~/Library/pnpm` — these
  belong to tools that were never installed as a `.app`, so they'd
  always look "orphaned" from the scanner's perspective.

## Attribution logic

For each entry the scanner extracts a candidate bundle ID by undoing the
category-specific naming convention:

- **Containers / Application Scripts / Saved State / HTTPStorages / WebKit**:
  the directory name *is* the bundle ID.
- **Group Containers**: strip the `group.` prefix; otherwise treat
  `<10-char-team-id>.<rest>` as a team-prefix container and check whether
  the team still owns any installed app.
- **Preferences**: strip `.plist`; if the trailing component looks like a
  UUID (`XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`), strip that too.
- **iCloud (`Mobile Documents`)**: require `iCloud~` prefix, then convert
  tildes back to dots.

The candidate must contain at least one dot and no spaces or slashes,
and its first segment must be a ≥ 2-character reverse-DNS root that
starts with a letter — that prevents fragments like `0.5` or `.cache`
from being mistaken for bundle IDs. Anything else is silently skipped.

Two checks then decide whether the bundle ID is still installed:

1. **Primary** — read every `.app/Contents/Info.plist` under
   `/Applications` and `~/Applications` (depth ≤ 1) and collect bundle
   IDs + Team IDs. This is intentionally narrower than Launch Services,
   which remembers bundles it has merely seen (mounted DMGs, downloads
   in quarantine).
2. **Backstop** — for the remaining candidates, ask
   `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`. If LS
   resolves it to an `.app` that still exists on disk, the entry is
   treated as installed. Used purely as a "don't surface this" filter to
   avoid false positives for apps in non-standard locations.

Only if both checks come up empty is the entry flagged as orphaned.

## Why bundle ID, not name

Earlier prototypes tried to attribute leftover folders by name
(`Slack`, `Spotify`). That technique falls apart fast:

- **Renamed installs**: an app installed as `Slack 2.app` writes to
  `com.tinyspeck.slackmacgap` — name-based matching needs an explicit
  mapping table.
- **Suites**: `Microsoft` matches every Office app's leftover folder;
  cleaning blindly removes data still in use.
- **Locale variants**: app names get translated, bundle IDs don't.
- **False positives**: a folder named `Foo` could come from any of a
  hundred apps.

Bundle IDs are stable, globally unique, and what every per-app folder is
already named after. Trading some recall (we don't catch vendor-named
folders) for very high precision is the right call for a destructive
operation.

## What still won't be caught

A few things by design:

- **Vendor-name folders** in `Application Support` (`Adobe`,
  `JetBrains`, `Microsoft`, `Logitech`, …). These are common but
  un-attributable without a maintained vendor map. Track them down with
  the per-app scan instead — drop any single app from that suite.
- **Configuration profiles** (`/Library/Managed Preferences`). MDM
  territory, not user-cleanable.
- **Keychain items**, **System Extensions**, **Network Extensions**.
  Each has its own removal API that requires user prompts beyond the
  scope of a trash-only cleaner.
- **Installer receipts** (`pkgutil`). These are tracked separately from
  user-data files; a follow-up release may surface them.
- **Homebrew formula prefs / CLI-tool plists** that happen to live in
  `~/Library/Preferences`. With no `.app` anywhere, they will always
  look orphaned to this scanner; if you keep brew formulae, leave those
  groups unchecked.
- **Apps installed at non-`/Applications` paths the LS backstop can't
  reach** — extremely unusual placements (custom mount points, removable
  volumes) may still produce false orphan reports.

## Implementation reference

The scanner is implemented in:

- `my-cleaner/OrphanScanner.swift` — directory walk, bundle ID
  extraction, Launch Services lookup, team ID cross-check.
- `my-cleaner/OrphanResultsView.swift` — SwiftUI list grouped by bundle
  ID with per-group selection.
- `my-cleaner/CleanerModel.swift` — `startOrphanScan` and
  `confirmOrphanCleanup` drive the UI state machine.
- `my-cleaner/CleanupActions.swift` — `tccutil reset` and
  `killall cfprefsd` invocations that run after the trash step.

## Safety

- Everything goes to `~/.Trash`. The user can put any item back from the
  Trash window with **Put Back** until they empty it.
- Selection defaults to **off**. The user has to opt in to each bundle
  ID. There's no "select all and clean" shortcut path; you click
  **Select all** before **Move to Trash**.
- A final confirmation alert summarises the byte total and group count
  before anything moves. Groups that include iCloud Drive documents are
  called out explicitly in that alert.
- Apple-namespace bundle IDs are excluded unconditionally, even if
  they're somehow not resolvable.
- System-protected paths (`/System`, `/private`) are not scanned and
  can't be reached from this UI.
- iCloud Drive containers under `~/Library/Mobile Documents/iCloud~…`
  hold real user documents that sync to other devices. They are surfaced
  with a distinct visual cue and the surrounding group's confirmation
  alert warns that local deletion may also delete from iCloud.
