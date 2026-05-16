//
//  AppScanner.swift
//  my-cleaner
//
//  Finds Library entries belonging to a dropped `.app` so the cleanup
//  step can move them to the Trash alongside the app bundle itself.
//
//  Two passes:
//  1. A hand-rolled directory walk over every Library subfolder where
//     macOS conventionally stores per-app state, classified by
//     `AppMatcher` (bundle ID, group prefix, iCloud tilde-encoded form,
//     name hints, team-prefix Group Containers).
//  2. A Spotlight supplement that picks up files whose
//     `kMDItemCFBundleIdentifier` metadata names this bundle even when
//     the parent folder doesn't.
//

import Foundation

/// Discovers every Library entry that belongs to a dropped app.
///
/// Stateless and Sendable — every operation is a `nonisolated static`
/// function the model invokes from a background `Task.detached`.
enum AppScanner {

    /// Run a complete scan for the dropped app.
    ///
    /// - Parameter app: The app whose leftovers MyCleaner should find.
    /// - Returns: A `ScanResult` carrying the app bundle's own on-disk
    ///   size plus every deduplicated leftover entry found in either
    ///   pass.
    nonisolated static func scan(app: DroppedApp) -> ScanResult {
        let matcher = AppMatcher(app: app)
        let locations = libraryLocations()
        let appPath = app.url.standardizedFileURL.path

        var found: [URL: RelatedItem] = [:]
        for location in locations {
            walk(
                location: location,
                matcher: matcher,
                appPath: appPath,
                into: &found
            )
        }

        supplementWithSpotlight(app: app, appPath: appPath, into: &found)

        let appSize = FileSize.of(at: app.url, isDirectory: true)
        return ScanResult(appSize: appSize, items: Array(found.values))
    }

    /// A single Library location the scanner walks.
    ///
    /// `extraDepth` is the number of levels past `directory` the walker
    /// is allowed to descend into when an immediate child doesn't match.
    /// Used for `Application Support`, `Caches`, and `Logs`, where
    /// vendors like JetBrains nest their per-product folders one level
    /// deep under a brand folder.
    private struct Location {
        let directory: URL
        let category: RelatedItem.Category
        let extraDepth: Int
    }

    /// Every Library subfolder MyCleaner walks, with its category and
    /// per-location descent depth.
    ///
    /// User and system Library trees both contribute, but only the
    /// places where macOS conventionally stores per-app state are
    /// listed — there's no point walking `~/Library/Fonts` for app
    /// leftovers.
    private nonisolated static func libraryLocations() -> [Location] {
        let fm = FileManager.default
        let userLib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let sysLib = URL(fileURLWithPath: "/Library", isDirectory: true)

        return [
            Location(directory: userLib.appendingPathComponent("Application Support", isDirectory: true), category: .applicationSupport, extraDepth: 1),
            Location(directory: userLib.appendingPathComponent("Caches", isDirectory: true), category: .caches, extraDepth: 1),
            Location(directory: userLib.appendingPathComponent("Preferences", isDirectory: true), category: .preferences, extraDepth: 0),
            Location(directory: userLib.appendingPathComponent("Preferences/ByHost", isDirectory: true), category: .preferences, extraDepth: 0),
            Location(directory: userLib.appendingPathComponent("Containers", isDirectory: true), category: .containers, extraDepth: 0),
            Location(directory: userLib.appendingPathComponent("Group Containers", isDirectory: true), category: .groupContainers, extraDepth: 0),
            Location(directory: userLib.appendingPathComponent("Logs", isDirectory: true), category: .logs, extraDepth: 1),
            Location(directory: userLib.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true), category: .crashReports, extraDepth: 0),
            Location(directory: userLib.appendingPathComponent("Saved Application State", isDirectory: true), category: .savedState, extraDepth: 0),
            Location(directory: userLib.appendingPathComponent("HTTPStorages", isDirectory: true), category: .cookies, extraDepth: 0),
            Location(directory: userLib.appendingPathComponent("WebKit", isDirectory: true), category: .cookies, extraDepth: 0),
            Location(directory: userLib.appendingPathComponent("Cookies", isDirectory: true), category: .cookies, extraDepth: 0),
            Location(directory: userLib.appendingPathComponent("LaunchAgents", isDirectory: true), category: .launchItems, extraDepth: 0),
            Location(directory: userLib.appendingPathComponent("Application Scripts", isDirectory: true), category: .scripts, extraDepth: 0),
            Location(directory: userLib.appendingPathComponent("Mobile Documents", isDirectory: true), category: .iCloud, extraDepth: 0),
            Location(directory: sysLib.appendingPathComponent("Application Support", isDirectory: true), category: .applicationSupport, extraDepth: 1),
            Location(directory: sysLib.appendingPathComponent("Caches", isDirectory: true), category: .caches, extraDepth: 1),
            Location(directory: sysLib.appendingPathComponent("Preferences", isDirectory: true), category: .preferences, extraDepth: 0),
            Location(directory: sysLib.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true), category: .crashReports, extraDepth: 0),
            Location(directory: sysLib.appendingPathComponent("LaunchAgents", isDirectory: true), category: .launchItems, extraDepth: 0),
            Location(directory: sysLib.appendingPathComponent("LaunchDaemons", isDirectory: true), category: .launchItems, extraDepth: 0),
            Location(directory: sysLib.appendingPathComponent("PrivilegedHelperTools", isDirectory: true), category: .launchItems, extraDepth: 0),
        ]
    }

    /// Walk `location.directory`, classify each entry with `matcher`,
    /// and write any matches into `found`.
    ///
    /// Recurses into unmatched subdirectories when `location.extraDepth`
    /// allows, skipping descent into Apple-namespace folders so the
    /// walker doesn't spelunk into system directories looking for
    /// third-party leftovers.
    private nonisolated static func walk(
        location: Location,
        matcher: AppMatcher,
        appPath: String,
        into found: inout [URL: RelatedItem]
    ) {
        walk(
            directory: location.directory,
            category: location.category,
            matcher: matcher,
            extraDepth: location.extraDepth,
            appPath: appPath,
            into: &found
        )
    }

    private nonisolated static func walk(
        directory: URL,
        category: RelatedItem.Category,
        matcher: AppMatcher,
        extraDepth: Int,
        appPath: String,
        into found: inout [URL: RelatedItem]
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        for entry in entries {
            let std = entry.standardizedFileURL
            if std.path == appPath { continue }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            let result = matcher.match(entry: entry, category: category)
            if result.matched {
                if found[std] == nil {
                    let size = FileSize.of(at: entry, isDirectory: isDir)
                    let shared = result.shared || category == .iCloud
                    found[std] = RelatedItem(
                        url: entry,
                        category: category,
                        sizeBytes: size,
                        isDirectory: isDir,
                        isShared: shared
                    )
                }
                continue
            }

            if isDir, extraDepth > 0, !shouldSkipDescent(entry) {
                walk(
                    directory: entry,
                    category: category,
                    matcher: matcher,
                    extraDepth: extraDepth - 1,
                    appPath: appPath,
                    into: &found
                )
            }
        }
    }

    /// Decide whether to skip recursing into a subfolder during the
    /// extra-depth pass.
    ///
    /// Apple-namespace folders (`com.apple.*`, `Apple/`, `CrashReporter/`)
    /// host system content and never contain third-party leftovers; the
    /// walker would burn time descending into them for nothing.
    private nonisolated static func shouldSkipDescent(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix("com.apple.") { return true }
        if name == "Apple" || name == "CrashReporter" { return true }
        return false
    }

    /// Add Spotlight hits — files whose `kMDItemCFBundleIdentifier`
    /// matches this app — to the result set if they weren't already
    /// matched by the directory walk.
    ///
    /// Restricted to library-scope hits so the supplement adds things
    /// the hand-rolled walk missed (`/Library/Frameworks`, vendor install
    /// directories, deeply nested helper bundles) rather than every
    /// Spotlight match anywhere on disk.
    private nonisolated static func supplementWithSpotlight(
        app: DroppedApp,
        appPath: String,
        into found: inout [URL: RelatedItem]
    ) {
        guard let bid = app.bundleID, !bid.isEmpty else { return }
        let hits = SpotlightSearch.filesForBundleID(bid)
        guard !hits.isEmpty else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userLib = home + "/Library/"
        let sysLib = "/Library/"

        for url in hits {
            let std = url.standardizedFileURL
            let path = std.path
            if path == appPath { continue }
            if path.hasPrefix(appPath + "/") { continue }
            guard path.hasPrefix(userLib) || path.hasPrefix(sysLib) else { continue }
            if found[std] != nil { continue }

            let isDir = (try? std.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = FileSize.of(at: std, isDirectory: isDir)
            let category = CategoryClassifier.category(forPath: path)
            // iCloud entries hold user documents that sync to other
            // devices; force opt-in regardless of how they were matched.
            let shared = category == .iCloud
            found[std] = RelatedItem(
                url: std,
                category: category,
                sizeBytes: size,
                isDirectory: isDir,
                isShared: shared
            )
        }
    }
}
