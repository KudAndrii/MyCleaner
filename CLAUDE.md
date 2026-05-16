# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

MyCleaner is a non-sandboxed macOS SwiftUI app that finds and trashes every file a dropped `.app` has scattered across `~/Library` and `/Library`, plus a second mode that finds support files left over by apps that are no longer installed. Requires macOS 26 / Xcode 26 (uses Liquid Glass APIs).

The app is **deliberately not sandboxed** — re-enabling App Sandbox makes the scanner read its own container instead of the real Library and the app stops functioning. Don't add the entitlement back.

## Commands

This project is opened in Xcode and the user expects you to drive builds and tests through the `xcode-tools` MCP server, not the command line:

- **Build** — `BuildProject`. Always run after non-trivial edits.
- **Run all tests** — `RunAllTests`. The full suite is ~195 tests and finishes in seconds.
- **Run a subset** — `GetTestList` to enumerate, then `RunSomeTests` with the identifiers you want.
- **Fast per-file diagnostics** — `XcodeRefreshCodeIssuesInFile` for live compiler errors on a single Swift file without a full build.
- **List warnings/errors visible in Xcode** — `XcodeListNavigatorIssues` (set `severity: "warning"` to surface non-error issues).

If you need shell tools, `gh` lives at `/opt/homebrew/bin/gh`. The user's shell aliases `cat` to `bat`; heredocs piped through `cat` will fail in non-interactive Bash because `bat` isn't on PATH. Avoid `$(cat <<EOF…EOF)` entirely — for commit messages and PR bodies just pass the text directly to `git commit -m "…"` (multi-line strings work fine) or `gh pr create --body "…"`. Don't write the text to a temp file as an intermediate step; that's wasted round-trips and leftover files in `/tmp`.

Scheme name is `my-cleaner`. App target `my-cleaner` → `MyCleaner.app`. Test target `my-cleanerTests` → `MyCleanerTests.xctest`.

## Architecture

### Stage state machine

`CleanerModel` is `@Observable` and owns a single `Stage` enum that the view layer routes off. `ContentView` switches on it: `idle` → `DropZoneView`, `analyzing` → `AnalyzingView`, `results` → `ResultsView`, `cleaning` / `done(CleanupReport)` → screens in `StageViews.swift`, `orphanScanning` → orphan scanner screen, `orphanResults` → `OrphanResultsView`. Adding a new screen means adding a `Stage` case and a route in `ContentView`.

### Two scanner pipelines, both find-then-filter

Both scanners follow the same shape and were refactored into explicit strategy chains:

- **Per-app flow** (`AppScanner.swift` + `AppEntryMatcher.swift`). `AppScanner.scan(app:)` walks a fixed `libraryLocations()` list and supplements with a Spotlight pass (`mdfind kMDItemCFBundleIdentifier`). Each candidate entry runs through `AppScanner.matchers()` — an ordered chain of `any AppEntryMatcher` existentials (`BundleIDMatcher`, `ICloudBundleMatcher`, `NameHintMatcher`, `TeamPrefixGroupContainerMatcher`). First non-`nil` match wins; the match's `shared` flag controls whether the UI defaults the item to unselected.

- **Orphan flow** (`OrphanScanner.swift` + `OrphanFilter.swift`). `OrphanScanner.scan()` walks bundle-ID-named Library directories, extracts a candidate bundle ID per entry, then runs the candidate through `OrphanScanner.filters()` — an **exclusion-only** chain (`AppleReservedFilter`, `InstalledBundleIDFilter`, `InstalledChildFilter`, `InstalledAncestorFilter`, `VendorNamespaceFilter`, `TeamPrefixFilter`, `LaunchServicesFilter`). Any filter hit excludes the candidate; survivors are surfaced grouped by bundle ID. Order matters: cheap exclusions first, `LaunchServicesFilter` (touches disk) last.

When extending either chain, add a new `nonisolated struct` conformer and slot it into the chain factory in the scanner. Don't add inline branches back into `classify` / `scanDir`.

### Shared trash funnel

Both `confirmCleanup()` and `confirmOrphanCleanup()` route through one private helper, `CleanerModel.trashURLs(_:)`. It does:

1. First pass — `FileManager.trashItem` per URL inside a `Task.detached`, captures per-URL failures.
2. Retry — `AdminTrash.move(urls:)` runs an admin-elevated AppleScript / `mv` for refusals (System paths, root-owned plists).
3. Aggregates everything into `CleanupReport(trashedNormally, trashedWithElevation, failures)`.

Post-trash side-effects fire in the calling method, not the helper: `CleanupActions.killCfprefsd()` if any preference plist was touched, `CleanupActions.resetTCC(forBundleID:)` per affected bundle ID, plus `launchctl bootout` for selected LaunchAgent / LaunchDaemon plists. The split is intentional — `trashURLs` doesn't know which categories were selected.

### Concurrency convention

Almost every type in the project is `nonisolated struct` and almost every helper is `nonisolated static func`. Scanners run from `Task.detached(priority: .userInitiated) { … }.value`; only `CleanerModel` itself is main-actor (via `@Observable`). When introducing new types that get passed into the scan task, mark them `nonisolated` + `Sendable`.

Protocol requirements on `Sendable`-only protocols must also be marked `nonisolated` explicitly — otherwise calling them through `any …` existentials from a `nonisolated static` context produces a "main actor-isolated method in synchronous nonisolated context" warning. See `AppEntryMatcher.match` and `OrphanFilter.shouldExclude` for the precedent.

## Tests

Uses **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), not XCTest. One `*Tests.swift` file per source type under `my-cleanerTests/`, shared fixtures in `TestHelpers.swift`. When adding a scanner rule, add a focused test file (or extend the matching one) rather than expanding `CleanerModelTests` — the model tests deliberately don't exercise full filesystem scans.

## Docs

`docs/FUTURE_WORK.md` is a backlog (`pkgutil` receipts, System Extensions, SMAppService btm parsing, Keychain cleanup) — none are implemented yet; if you pick one up, the file names and category-enum additions sketched there are the intended landing spots.

## Working preferences

- README.md asks contributors to keep new matcher rules accompanied by a comment explaining the pattern it catches **and** the false positive it avoids. `AppScanner.wordBoundaryPrefix` is the precedent.
- Don't re-enable App Sandbox under any circumstances.
- The user typically wants you to verify changes with a build + test pass before reporting done.
