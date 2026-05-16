//
//  AppScanner.swift
//  my-cleaner
//
//  App-specific cleanup pipeline.
//
//  The flow has two halves the rest of the codebase also follows:
//
//    1. **Find** — walk a fixed set of `Library` locations and collect
//       every entry that ``classify(entry:app:teamID:nameHints:category:)``
//       attributes to the dropped app. Supplemented by a Spotlight pass
//       that picks up files outside the walk (e.g. helper bundles
//       indexed under `/Library/Frameworks`).
//
//    2. **Attribute / filter** — ``classify`` runs an ordered chain of
//       ``AppEntryMatcher`` strategies. The first matcher that
//       recognises the entry wins; the matcher's ``AppEntryMatch``
//       result tells the scanner whether to surface the entry as
//       *shared* (default-off) or owned outright by the app.
//

import Foundation
import Security

/// Scans the user's Library for entries that belong to a single dropped app.
///
/// See the file header for a description of the two-phase find /
/// attribute pipeline.
enum AppScanner {

    // MARK: - Find phase

    /// Locations the directory walk visits, paired with the bucket they
    /// map to and an "extra descent" depth.
    ///
    /// `extraDepth` is `0` for buckets whose entries are conventionally
    /// named directly after a bundle ID (e.g. `Preferences/`) and `1`
    /// for buckets where vendors stick an intermediate folder
    /// (`Application Support/JetBrains/Rider2025.3/`).
    private nonisolated struct LibraryLocation: Sendable {
        let url: URL
        let category: RelatedItem.Category
        let extraDepth: Int
    }

    private nonisolated static func libraryLocations() -> [LibraryLocation] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let userLib = home.appendingPathComponent("Library", isDirectory: true)
        let sysLib = URL(fileURLWithPath: "/Library", isDirectory: true)

        return [
            LibraryLocation(url: userLib.appendingPathComponent("Application Support", isDirectory: true), category: .applicationSupport, extraDepth: 1),
            LibraryLocation(url: userLib.appendingPathComponent("Caches", isDirectory: true), category: .caches, extraDepth: 1),
            LibraryLocation(url: userLib.appendingPathComponent("Preferences", isDirectory: true), category: .preferences, extraDepth: 0),
            LibraryLocation(url: userLib.appendingPathComponent("Preferences/ByHost", isDirectory: true), category: .preferences, extraDepth: 0),
            LibraryLocation(url: userLib.appendingPathComponent("Containers", isDirectory: true), category: .containers, extraDepth: 0),
            LibraryLocation(url: userLib.appendingPathComponent("Group Containers", isDirectory: true), category: .groupContainers, extraDepth: 0),
            LibraryLocation(url: userLib.appendingPathComponent("Logs", isDirectory: true), category: .logs, extraDepth: 1),
            LibraryLocation(url: userLib.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true), category: .crashReports, extraDepth: 0),
            LibraryLocation(url: userLib.appendingPathComponent("Saved Application State", isDirectory: true), category: .savedState, extraDepth: 0),
            LibraryLocation(url: userLib.appendingPathComponent("HTTPStorages", isDirectory: true), category: .cookies, extraDepth: 0),
            LibraryLocation(url: userLib.appendingPathComponent("WebKit", isDirectory: true), category: .cookies, extraDepth: 0),
            LibraryLocation(url: userLib.appendingPathComponent("Cookies", isDirectory: true), category: .cookies, extraDepth: 0),
            LibraryLocation(url: userLib.appendingPathComponent("LaunchAgents", isDirectory: true), category: .launchItems, extraDepth: 0),
            LibraryLocation(url: userLib.appendingPathComponent("Application Scripts", isDirectory: true), category: .scripts, extraDepth: 0),
            LibraryLocation(url: userLib.appendingPathComponent("Mobile Documents", isDirectory: true), category: .iCloud, extraDepth: 0),
            LibraryLocation(url: sysLib.appendingPathComponent("Application Support", isDirectory: true), category: .applicationSupport, extraDepth: 1),
            LibraryLocation(url: sysLib.appendingPathComponent("Caches", isDirectory: true), category: .caches, extraDepth: 1),
            LibraryLocation(url: sysLib.appendingPathComponent("Preferences", isDirectory: true), category: .preferences, extraDepth: 0),
            LibraryLocation(url: sysLib.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true), category: .crashReports, extraDepth: 0),
            LibraryLocation(url: sysLib.appendingPathComponent("LaunchAgents", isDirectory: true), category: .launchItems, extraDepth: 0),
            LibraryLocation(url: sysLib.appendingPathComponent("LaunchDaemons", isDirectory: true), category: .launchItems, extraDepth: 0),
            LibraryLocation(url: sysLib.appendingPathComponent("PrivilegedHelperTools", isDirectory: true), category: .launchItems, extraDepth: 0),
        ]
    }

    /// The ordered matcher chain used by ``classify(entry:app:teamID:nameHints:category:)``.
    ///
    /// Order is significant: cheap exact-match strategies first, more
    /// permissive heuristics (name hints, team prefix) after. Returned
    /// as a function rather than a `static let` so the call sites stay
    /// independent of any global Sendable storage rules.
    private nonisolated static func matchers() -> [any AppEntryMatcher] {
        [
            BundleIDMatcher(),
            ICloudBundleMatcher(),
            NameHintMatcher(),
            TeamPrefixGroupContainerMatcher(),
        ]
    }

    // MARK: - Entry point

    /// Runs a full app-specific scan.
    ///
    /// Walks every ``libraryLocations()`` entry, then supplements with
    /// a Spotlight query for files that carry the app's bundle ID.
    ///
    /// - Parameter app: The bundle the user dropped onto the app.
    /// - Returns: The app's own on-disk size plus every related entry found.
    nonisolated static func scan(app: DroppedApp) -> ScanResult {
        let teamID = readTeamID(forAppAt: app.url)
        let nameHints = computeNameHints(app: app)
        let appPath = app.url.standardizedFileURL.path

        var found: [URL: RelatedItem] = [:]

        for location in libraryLocations() {
            scan(
                directory: location.url,
                category: location.category,
                app: app,
                teamID: teamID,
                nameHints: nameHints,
                extraDepth: location.extraDepth,
                appPath: appPath,
                into: &found
            )
        }

        // Spotlight pass — catches Info.plists, preference files, and
        // helper bundles whose metadata carries this bundle ID even
        // though their parent folder name doesn't match anything the
        // walk knows to enter (e.g. files under /Library/Frameworks or
        // vendor dirs).
        supplementWithSpotlight(app: app, appPath: appPath, into: &found)

        let appSize = sizeOfItem(at: app.url, isDirectory: true)
        return ScanResult(appSize: appSize, items: Array(found.values))
    }

    // MARK: - Spotlight supplement

    private nonisolated static func supplementWithSpotlight(
        app: DroppedApp,
        appPath: String,
        into found: inout [URL: RelatedItem]
    ) {
        guard let bid = app.bundleID, !bid.isEmpty else { return }
        let hits = SpotlightSearch.filesForBundleID(bid)
        guard !hits.isEmpty else { return }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let userLib = home + "/Library/"
        let sysLib = "/Library/"

        for url in hits {
            let std = url.standardizedFileURL
            let path = std.path
            if path == appPath { continue }
            if path.hasPrefix(appPath + "/") { continue }
            // Only surface library-scope hits; the goal is to add things our
            // hand-rolled walk missed, not to surface every Spotlight match.
            guard path.hasPrefix(userLib) || path.hasPrefix(sysLib) else { continue }
            if found[std] != nil { continue }

            let isDir = (try? std.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = sizeOfItem(at: std, isDirectory: isDir)
            let category = categorize(path: path)
            // iCloud entries hold user documents synced via iCloud Drive;
            // deleting them locally can also remove them on other devices.
            // Force opt-in regardless of how the entry was matched.
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

    /// Cheap path-segment classifier used to bucket Spotlight hits into
    /// the same section headers as the directory walk.
    nonisolated static func categorize(path: String) -> RelatedItem.Category {
        if path.contains("/Application Support/") { return .applicationSupport }
        if path.contains("/Caches/") { return .caches }
        if path.contains("/Containers/") { return .containers }
        if path.contains("/Group Containers/") { return .groupContainers }
        if path.contains("/Preferences/") { return .preferences }
        if path.contains("/Saved Application State/") { return .savedState }
        if path.contains("/Logs/DiagnosticReports/") { return .crashReports }
        if path.contains("/Logs/") { return .logs }
        if path.contains("/HTTPStorages/") || path.contains("/WebKit/") || path.contains("/Cookies/") {
            return .cookies
        }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") || path.contains("/PrivilegedHelperTools/") {
            return .launchItems
        }
        if path.contains("/Application Scripts/") { return .scripts }
        if path.contains("/Mobile Documents/") { return .iCloud }
        return .other
    }

    // MARK: - Directory walk

    /// Walks a single Library directory and inserts every matching entry into `found`.
    ///
    /// Recurses up to `extraDepth` levels into non-Apple subdirectories
    /// so vendor folders like `Application Support/JetBrains/Rider2025.3`
    /// still get reached.
    nonisolated static func scan(
        directory: URL,
        category: RelatedItem.Category,
        app: DroppedApp,
        teamID: String?,
        nameHints: [String],
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

            let outcome = classify(
                entry: entry,
                app: app,
                teamID: teamID,
                nameHints: nameHints,
                category: category
            )
            if outcome.matched {
                if found[std] == nil {
                    let size = sizeOfItem(at: entry, isDirectory: isDir)
                    // iCloud Documents hold real user files that sync to other
                    // devices — require explicit opt-in instead of defaulting on.
                    let shared = outcome.shared || category == .iCloud
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
                scan(
                    directory: entry,
                    category: category,
                    app: app,
                    teamID: teamID,
                    nameHints: nameHints,
                    extraDepth: extraDepth - 1,
                    appPath: appPath,
                    into: &found
                )
            }
        }
    }

    /// `true` for subdirectories the walk shouldn't descend into.
    ///
    /// We always skip `com.apple.*`, the literal `Apple` folder, and
    /// `CrashReporter` — they hold OS-owned data, not app caches.
    nonisolated static func shouldSkipDescent(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix("com.apple.") { return true }
        if name == "Apple" || name == "CrashReporter" { return true }
        return false
    }

    // MARK: - Attribution

    /// Decides whether `entry` belongs to `app`, and whether the match
    /// should default to opt-in.
    ///
    /// Implementation runs the ``matchers`` chain in order and returns
    /// the first non-`nil` verdict. The tuple shape is preserved as the
    /// public API for the rest of the scanner and the test suite.
    ///
    /// - Returns: `(matched: true, shared: …)` when any matcher recognised
    ///   the entry, otherwise `(matched: false, shared: false)`.
    nonisolated static func classify(
        entry: URL,
        app: DroppedApp,
        teamID: String?,
        nameHints: [String],
        category: RelatedItem.Category
    ) -> (matched: Bool, shared: Bool) {
        let context = AppEntryMatchContext(
            app: app,
            teamID: teamID,
            nameHints: nameHints,
            category: category,
            entry: entry
        )
        for matcher in matchers() {
            if let result = matcher.match(entry: entry, in: context) {
                return (true, result.shared)
            }
        }
        return (false, false)
    }

    /// Collects every short attribution token we plausibly know the app by.
    ///
    /// Sources are the display name, the bundle ID's last reverse-DNS
    /// component, and the `.app` filename. Tokens are lowercased and
    /// de-duplicated; tokens shorter than 3 characters are dropped to
    /// keep false-positive risk low.
    ///
    /// Example — JetBrains stores Rider data under
    /// `~/Library/Caches/JetBrains/Rider2025.3/`, where only the
    /// `rider` token from the bundle ID matches the folder name; the
    /// display name `JetBrains Rider` doesn't.
    nonisolated static func computeNameHints(app: DroppedApp) -> [String] {
        var hints: Set<String> = []
        let display = app.name.lowercased()
        if display.count >= 3 { hints.insert(display) }

        if let bid = app.bundleID,
           let last = bid.split(separator: ".").last {
            let token = String(last).lowercased()
            if token.count >= 3 { hints.insert(token) }
        }

        let filename = app.url.deletingPathExtension().lastPathComponent.lowercased()
        if filename.count >= 3 { hints.insert(filename) }

        return Array(hints)
    }

    /// `true` if `s` starts with `prefix` **and** the next character is
    /// a non-letter (digit, dot, space, dash, underscore).
    ///
    /// Avoids matching "Microsoft" in "MicrosoftAutoUpdate" while still
    /// matching "Rider" in "Rider2024.3" or "Microsoft Word" in
    /// "Microsoft Word Data". Returns `false` for prefixes shorter than
    /// 3 characters and for exact-equality (handled separately by the
    /// caller).
    nonisolated static func wordBoundaryPrefix(_ s: String, prefix: String) -> Bool {
        guard prefix.count >= 3, s.count > prefix.count, s.hasPrefix(prefix) else { return false }
        let next = s[s.index(s.startIndex, offsetBy: prefix.count)]
        return !next.isLetter
    }

    // MARK: - Code signing

    /// Reads the code-signing team identifier from a `.app` bundle.
    ///
    /// `kSecCodeInfoTeamIdentifier` lives in the cryptographic-signing
    /// section of the info dict, so we have to request it explicitly
    /// via ``kSecCSSigningInformation``. Default flags return only the
    /// basic identifier set and leave the team ID out — which made the
    /// installedTeamIDs cross-check a silent no-op before this was
    /// fixed.
    ///
    /// - Returns: The team ID, or `nil` for unsigned / unsignable bundles.
    nonisolated static func readTeamID(forAppAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else { return nil }

        var infoRef: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoRef
        )
        guard infoStatus == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }

        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - Size accounting

    /// Allocated size of a single file or directory tree, in bytes.
    ///
    /// For files, prefers `totalFileAllocatedSize` (sparse files) and
    /// falls back to `fileAllocatedSize`. For directories, recursively
    /// sums the same per-file values. Returns `0` for missing paths or
    /// when none of the size keys can be read.
    nonisolated static func sizeOfItem(at url: URL, isDirectory: Bool) -> Int64 {
        if !isDirectory {
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            if let values = try? url.resourceValues(forKeys: keys) {
                return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
            return 0
        }

        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: keys),
               values.isDirectory == false {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
