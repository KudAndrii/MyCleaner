//
//  CacheScanner.swift
//  my-cleaner
//
//  Standalone cache-cleanup pipeline.
//
//  Mirrors the find-then-filter shape of ``OrphanScanner`` but the
//  goal is different: surface oversized caches the user can wipe
//  *without* removing the owning app. The pipeline:
//
//    1. **Find** — walk `~/Library/Caches`, `/Library/Caches`, plus a
//       hardcoded list of well-known out-of-Library cache roots (npm,
//       Gradle, Xcode DerivedData, …). Each on-disk name is mapped to
//       a candidate bundle ID where possible.
//
//    2. **Filter** — drop entries whose tree size is under a
//       configurable floor (50 MB default), and exclude
//       Apple-reserved bundle IDs that aren't on a small allowlist of
//       caches known to regenerate cleanly.
//
//    3. **Attribute** — resolve each candidate to an installed `.app`
//       via Launch Services and label entries whose owning app isn't
//       installed as "orphaned cache".
//

import Foundation
import AppKit

// MARK: - Model

/// One individual cache entry surfaced by the scanner.
///
/// Either a top-level directory inside `~/Library/Caches/<bundleID>` or
/// a per-project subdirectory under a well-known toolchain root
/// (Xcode DerivedData is the canonical example).
nonisolated struct CacheEntry: Identifiable, Hashable, Sendable {
    /// Identity is the entry's URL.
    var id: URL { url }

    /// On-disk URL of the entry.
    let url: URL

    /// Allocated size of the entry's tree, in bytes.
    let sizeBytes: Int64

    /// `true` for directories; informational only.
    let isDirectory: Bool
}

/// A group of cache entries attributed to one owning app or a single
/// well-known toolchain root (npm, Gradle, Xcode DerivedData).
///
/// Selection is at the group level — the UI doesn't expose per-entry
/// toggles, mirroring the orphan flow.
nonisolated struct CacheGroup: Identifiable, Hashable, Sendable {
    /// Stable identifier — the bundle ID when one was resolved,
    /// otherwise the standardized path of the root entry.
    let id: String

    /// Bundle ID we attributed every entry to, when one could be
    /// derived from the directory name.
    let bundleID: String?

    /// Human-readable display name (`"Spotify"`, `"npm cache"`, …).
    let displayName: String

    /// On-disk URL of the owning `.app`, when we resolved one via
    /// Launch Services. Stored so the view can render an icon without
    /// having to redo the lookup itself.
    let appURL: URL?

    /// What the scanner attributed this group to — drives the badge
    /// shown next to the row.
    let kind: Kind

    /// Individual cache entries; one for most app caches, one per
    /// project for Xcode DerivedData.
    let entries: [CacheEntry]

    /// Conservative safety flag. `true` for routine app caches and
    /// well-understood toolchain caches; `false` for anonymous
    /// (vendor-named) entries we couldn't attribute. Unsafe groups are
    /// surfaced **unselected** and with a warning badge.
    let isSafeToDelete: Bool

    /// User-controlled toggle — true when the whole group is staged
    /// for trashing.
    var isSelected: Bool

    /// Sum of every entry's allocated size, in bytes.
    var totalBytes: Int64 { entries.map(\.sizeBytes).reduce(0, +) }

    /// What the scanner attributed this group to.
    enum Kind: String, Hashable, Sendable {
        /// `~/Library/Caches/<bundleID>` and the owning app is still installed.
        case installedApp
        /// `~/Library/Caches/<bundleID>` and the owning app is no longer installed.
        case orphanApp
        /// A toolchain / SDK cache outside `~/Library/Caches` (npm, Gradle, etc.).
        case toolchain
        /// A directory whose name doesn't look like a bundle ID at all
        /// (e.g. vendor folders like `Homebrew/`). Unsafe by default
        /// because we can't reason about what created it.
        case anonymous
    }
}

/// The full cache-scan output.
nonisolated struct CacheScanResult: Sendable {
    let groups: [CacheGroup]
    var totalSize: Int64 { groups.flatMap(\.entries).map(\.sizeBytes).reduce(0, +) }
}

/// One step in the cache scan, surfaced on the scanning screen as a
/// structural progress list (user/system Library Caches first, then
/// each well-known toolchain root).
///
/// The model owns `[CacheScanPhase]`, pre-populates it with every
/// known phase in `.pending`, and flips entries to `.inProgress`
/// and `.completed` as the scanner fires events.
nonisolated struct CacheScanPhase: Identifiable, Hashable, Sendable {
    /// Stable identifier used by the scanner / model handshake.
    let id: String

    /// Human-readable label shown in the scanning view.
    let displayName: String

    /// Current execution status.
    var status: Status

    /// Total surviving groups after this phase finished.
    var groupsAfter: Int = 0

    enum Status: Sendable, Hashable {
        case pending
        case inProgress
        case completed
    }
}

// MARK: - Scanner

/// Finds oversized caches the user can wipe without removing the
/// owning app. See the file header for the three-phase pipeline.
enum CacheScanner {

    /// Default size floor. Entries (or non-expanded well-known paths)
    /// whose tree-sum is below this are dropped so the results list
    /// stays focused on hoarders and not OS noise.
    nonisolated static let defaultMinimumBytes: Int64 = 50 * 1024 * 1024

    /// Phase-level event the scanner publishes so the scanning view
    /// can render structural progress.
    enum ScanEvent: Sendable {
        case phaseStarted(id: String)
        case phaseCompleted(id: String, groupsAfter: Int)
    }

    /// Stable identifiers for the two Library Caches phases. Matched
    /// against the ids the model uses when pre-populating its phase
    /// list. Well-known toolchain phases use the `WellKnownPath`'s
    /// `relativePath` as the id so the model can pre-populate the
    /// full list without duplicating the labels.
    nonisolated static let userLibraryCachesPhaseID = "user-library-caches"
    nonisolated static let systemLibraryCachesPhaseID = "system-library-caches"

    // MARK: Library roots

    /// `~/Library/Caches` and `/Library/Caches` — the primary find phase.
    nonisolated static func libraryCacheRoots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Caches", isDirectory: true),
            URL(fileURLWithPath: "/Library/Caches", isDirectory: true),
        ]
    }

    // MARK: Well-known out-of-Library paths

    /// A cache hoarder living outside `~/Library/Caches` that we know
    /// about by name.
    ///
    /// We never do a full `~` walk — the cost / false-positive risk is
    /// too high — so adding a new toolchain here is the only way for
    /// it to surface.
    nonisolated struct WellKnownPath: Sendable {
        /// Path relative to the user's home directory.
        let relativePath: String

        /// User-visible label.
        let displayName: String

        /// Optional bundle ID attribution (e.g. Xcode DerivedData → `com.apple.dt.Xcode`).
        let bundleID: String?

        /// When `true`, surface each immediate subdirectory as its own
        /// ``CacheEntry`` so the user can selectively wipe. Used for
        /// Xcode DerivedData where each `<scheme>-<hash>` is per-project.
        let expandChildren: Bool

        init(
            relativePath: String,
            displayName: String,
            bundleID: String? = nil,
            expandChildren: Bool = false
        ) {
            self.relativePath = relativePath
            self.displayName = displayName
            self.bundleID = bundleID
            self.expandChildren = expandChildren
        }
    }

    /// Hardcoded list of well-known toolchain cache locations.
    ///
    /// Xcode DerivedData is special-cased with `expandChildren: true`
    /// because the per-project breakdown is exactly what a user
    /// reaching for "free up Xcode space" wants to see.
    nonisolated static func wellKnownPaths() -> [WellKnownPath] {
        [
            WellKnownPath(
                relativePath: "Library/Developer/Xcode/DerivedData",
                displayName: "Xcode DerivedData",
                bundleID: "com.apple.dt.Xcode",
                expandChildren: true
            ),
            WellKnownPath(
                relativePath: "Library/Developer/CoreSimulator/Caches",
                displayName: "iOS Simulator caches",
                bundleID: "com.apple.CoreSimulator"
            ),
            // Node ecosystem.
            WellKnownPath(relativePath: ".npm/_cacache", displayName: "npm cache"),
            WellKnownPath(relativePath: ".yarn/cache", displayName: "Yarn cache"),
            WellKnownPath(relativePath: "Library/pnpm/store", displayName: "pnpm store"),
            // JVM ecosystem.
            WellKnownPath(relativePath: ".gradle/caches", displayName: "Gradle cache"),
            WellKnownPath(relativePath: ".m2/repository", displayName: "Maven repository"),
            // Rust / Python / Go / Homebrew / CocoaPods.
            WellKnownPath(relativePath: ".cargo/registry", displayName: "Cargo registry cache"),
            WellKnownPath(relativePath: "Library/Caches/pip", displayName: "pip cache"),
            WellKnownPath(relativePath: "Library/Caches/Homebrew", displayName: "Homebrew downloads"),
            WellKnownPath(relativePath: "go/pkg/mod/cache", displayName: "Go module cache"),
            WellKnownPath(relativePath: "Library/Caches/CocoaPods", displayName: "CocoaPods cache"),
        ]
    }

    // MARK: Entry point

    /// Runs a full cache scan over every library root and well-known
    /// toolchain path.
    ///
    /// - Parameters:
    ///   - minimumBytes: Floor; entries (or non-expanded well-known
    ///     roots) whose tree size is below this are dropped.
    ///   - onEvent: Optional callback invoked when the scanner enters
    ///     and exits each phase. The model uses these to flip a
    ///     `CacheScanPhase` from pending → inProgress → completed.
    /// - Throws: `CancellationError` when the surrounding task is
    ///   cancelled — checked before each library root and each
    ///   well-known path so the Cancel button responds promptly.
    nonisolated static func scan(
        minimumBytes: Int64 = defaultMinimumBytes,
        onEvent: (@Sendable (ScanEvent) -> Void)? = nil
    ) async throws -> CacheScanResult {
        let installed = OrphanScanner.collectInstalledApps()
        var groups: [String: CacheGroup] = [:]

        let roots = libraryCacheRoots()
        let phaseIDs = [userLibraryCachesPhaseID, systemLibraryCachesPhaseID]
        for (idx, root) in roots.enumerated() {
            try Task.checkCancellation()
            let phaseID = phaseIDs[idx]
            onEvent?(.phaseStarted(id: phaseID))
            scanCachesDirectory(
                root,
                minimumBytes: minimumBytes,
                installedBundleIDs: installed.bundleIDs,
                into: &groups
            )
            onEvent?(.phaseCompleted(id: phaseID, groupsAfter: groups.count))
        }

        for path in wellKnownPaths() {
            try Task.checkCancellation()
            onEvent?(.phaseStarted(id: path.relativePath))
            if let group = scanWellKnownPath(path, minimumBytes: minimumBytes) {
                // Same logical cache may show up under both buckets
                // (e.g. Launch Services attributes `~/Library/Caches/com.apple.dt.Xcode`
                // to Xcode, then DerivedData hits the same bundle ID).
                // The well-known form is more useful — keep it.
                groups[group.id] = group
            }
            onEvent?(.phaseCompleted(id: path.relativePath, groupsAfter: groups.count))
        }

        let sorted = groups.values.sorted { $0.totalBytes > $1.totalBytes }
        return CacheScanResult(groups: sorted)
    }

    // MARK: Library Caches walk

    /// Walks a Library Caches directory and inserts every entry that
    /// passes the size + Apple-namespace filters into `groups`.
    ///
    /// If a bundle ID appears in both user and system Library Caches,
    /// the second entry is appended to the existing group so the UI
    /// shows them together.
    nonisolated static func scanCachesDirectory(
        _ dir: URL,
        minimumBytes: Int64,
        installedBundleIDs: Set<String>,
        into groups: inout [String: CacheGroup]
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            let candidateBID: String? = OrphanScanner.looksLikeBundleID(name) ? name : nil

            // Apple-namespace exclusion. Allowlist a handful of caches
            // (Safari's HTTP cache, …) that regenerate cleanly.
            if let bid = candidateBID,
               OrphanScanner.isAppleReserved(bid),
               !isWellKnownSafeAppleCache(bundleID: bid) {
                continue
            }

            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = AppScanner.sizeOfItem(at: entry, isDirectory: isDir)
            if size < minimumBytes { continue }

            let groupID = candidateBID ?? entry.standardizedFileURL.path
            let newEntry = CacheEntry(url: entry, sizeBytes: size, isDirectory: isDir)

            if let existing = groups[groupID] {
                groups[groupID] = CacheGroup(
                    id: existing.id,
                    bundleID: existing.bundleID,
                    displayName: existing.displayName,
                    appURL: existing.appURL,
                    kind: existing.kind,
                    entries: existing.entries + [newEntry],
                    isSafeToDelete: existing.isSafeToDelete,
                    isSelected: existing.isSelected
                )
                continue
            }

            let attribution = attribute(
                candidateBundleID: candidateBID,
                fallbackName: name,
                installedBundleIDs: installedBundleIDs
            )
            // Anonymous (vendor-named) entries default to unsafe — we
            // don't know what they belong to so the user has to opt in.
            let safe = attribution.kind != .anonymous

            groups[groupID] = CacheGroup(
                id: groupID,
                bundleID: candidateBID,
                displayName: attribution.displayName,
                appURL: attribution.appURL,
                kind: attribution.kind,
                entries: [newEntry],
                isSafeToDelete: safe,
                isSelected: safe
            )
        }
    }

    /// Resolves a candidate bundle ID against installed apps to decide
    /// whether the cache should be labelled as installed-app, orphan,
    /// or anonymous.
    ///
    /// The Launch Services lookup is the source of truth — it catches
    /// installs outside `/Applications` (Setapp, `/opt`) that the
    /// `installedBundleIDs` directory walk doesn't reach. The set is a
    /// fallback for tests and for cases where LS hasn't yet indexed a
    /// fresh install.
    private nonisolated static func attribute(
        candidateBundleID: String?,
        fallbackName: String,
        installedBundleIDs: Set<String>
    ) -> (kind: CacheGroup.Kind, displayName: String, appURL: URL?) {
        guard let bid = candidateBundleID else {
            return (.anonymous, fallbackName, nil)
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
           FileManager.default.fileExists(atPath: app.path) {
            let info = Bundle(url: app)?.infoDictionary
            let display = (info?["CFBundleDisplayName"] as? String)
                ?? (info?["CFBundleName"] as? String)
                ?? app.deletingPathExtension().lastPathComponent
            return (.installedApp, display, app)
        }
        if installedBundleIDs.contains(bid.lowercased()) {
            return (.installedApp, bid, nil)
        }
        return (.orphanApp, bid, nil)
    }

    // MARK: Well-known path walk

    /// Resolves a `WellKnownPath` against the user's home directory
    /// and returns a `CacheGroup` if the resulting path exists and
    /// meets the size floor.
    ///
    /// When `expandChildren` is set, each immediate subdirectory is
    /// surfaced as its own ``CacheEntry`` so the user can pick which
    /// projects to wipe.
    nonisolated static func scanWellKnownPath(
        _ path: WellKnownPath,
        minimumBytes: Int64
    ) -> CacheGroup? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(path.relativePath, isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return nil }

        let rootSize = AppScanner.sizeOfItem(at: root, isDirectory: true)
        guard rootSize >= minimumBytes else { return nil }

        let entries: [CacheEntry] = {
            guard path.expandChildren,
                  let children = try? fm.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                  ) else {
                return [CacheEntry(url: root, sizeBytes: rootSize, isDirectory: true)]
            }
            let expanded: [CacheEntry] = children.compactMap { child in
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let size = AppScanner.sizeOfItem(at: child, isDirectory: isDir)
                return size > 0 ? CacheEntry(url: child, sizeBytes: size, isDirectory: isDir) : nil
            }
            if expanded.isEmpty {
                return [CacheEntry(url: root, sizeBytes: rootSize, isDirectory: true)]
            }
            return expanded.sorted { $0.sizeBytes > $1.sizeBytes }
        }()

        let id = path.bundleID ?? root.standardizedFileURL.path
        return CacheGroup(
            id: id,
            bundleID: path.bundleID,
            displayName: path.displayName,
            appURL: nil,
            kind: .toolchain,
            entries: entries,
            isSafeToDelete: true,
            isSelected: true
        )
    }

    // MARK: Apple namespace allowlist

    /// Bundle IDs in `com.apple.*` whose caches are routinely safe to
    /// wipe.
    ///
    /// Kept deliberately small — most Apple caches are managed by a
    /// running daemon and wiping them mid-flight can corrupt state.
    /// Safari's HTTP cache and a handful of others regenerate cleanly
    /// and routinely hit several GB; those are worth the carve-out.
    nonisolated static func isWellKnownSafeAppleCache(bundleID: String) -> Bool {
        let allowlist: Set<String> = [
            "com.apple.safari",
        ]
        return allowlist.contains(bundleID.lowercased())
    }
}
