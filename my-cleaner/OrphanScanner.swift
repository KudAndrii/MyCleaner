//
//  OrphanScanner.swift
//  my-cleaner
//
//  Finds Library entries whose name looks like a bundle ID (or a
//  recognised variant — group prefix, iCloud tilde-encoded form, ByHost
//  plist) and whose bundle ID no longer resolves to an installed app.
//
//  The scan has two clearly separated halves:
//
//  1. **Find what to delete.** Walk a fixed list of Library locations,
//     extract the bundle ID each entry was named after via
//     `BundleIdentifier.candidate(for:category:)`, and turn it into an
//     `OrphanCandidate`.
//
//  2. **Filter what NOT to delete.** Run every candidate through a chain
//     of `CandidateFilter` rules. The first filter to veto wins; only
//     candidates that survive every filter are surfaced as orphans.
//

import Foundation

/// Discovers Library entries left behind by uninstalled apps.
///
/// Stateless — every operation is a `nonisolated static` function, so the
/// model invokes it from a background `Task.detached`.
enum OrphanScanner {

    /// Run a full orphan scan and return the results grouped by bundle
    /// ID.
    ///
    /// Groups whose total size is zero are dropped from the output:
    /// they're usually system-stub directories Apple has already cleaned
    /// out, and surfacing them is pure UI noise with no disk to recover.
    ///
    /// - Returns: An `OrphanScanResult` whose groups are sorted by
    ///   `totalSize` descending.
    nonisolated static func scan() -> OrphanScanResult {
        let installed = InstalledAppsIndex.build()
        let filters = exclusionChain()
        let locations = libraryLocations()

        var byBundleID: [String: [RelatedItem]] = [:]
        for location in locations {
            scan(
                location: location,
                installed: installed,
                filters: filters,
                into: &byBundleID
            )
        }

        let groups: [OrphanGroup] = byBundleID
            .map { OrphanGroup(bundleID: $0.key, items: $0.value, isSelected: false) }
            .filter { $0.totalSize > 0 }
            .sorted { $0.totalSize > $1.totalSize }

        return OrphanScanResult(groups: groups)
    }

    /// Build the chain of `CandidateFilter` rules used to reject
    /// candidates that aren't real orphans.
    ///
    /// Order matters — cheaper rules run first so the expensive Launch
    /// Services lookup is only consulted for candidates the cheap rules
    /// can't decide. To add a new rule, drop it into this array at the
    /// right priority position.
    ///
    /// - Returns: The configured filter chain.
    nonisolated static func exclusionChain() -> [CandidateFilter] {
        [
            AppleReservedFilter(),
            InstalledBundleFilter(),
            VendorNamespaceFilter(),
            InstalledTeamFilter(),
            LaunchServicesFilter(),
        ]
    }

    /// A single Library location the orphan scanner walks.
    private struct Location {
        let directory: URL
        let category: RelatedItem.Category
    }

    /// Every Library subfolder where macOS conventionally names entries
    /// after a bundle ID (or a recognised variant).
    ///
    /// Deliberately omits name-based folders like `Application Support`
    /// where vendor names (`Adobe`, `JetBrains`) live alongside
    /// bundle-ID-named children — those folders can't be attributed
    /// reliably to a single bundle ID without a maintained vendor map.
    /// Users should reach those leftovers through the per-app scan
    /// instead.
    private nonisolated static func libraryLocations() -> [Location] {
        let fm = FileManager.default
        let userLib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let sysLib = URL(fileURLWithPath: "/Library", isDirectory: true)

        return [
            Location(directory: userLib.appendingPathComponent("Containers", isDirectory: true), category: .containers),
            Location(directory: userLib.appendingPathComponent("Group Containers", isDirectory: true), category: .groupContainers),
            Location(directory: userLib.appendingPathComponent("Application Scripts", isDirectory: true), category: .scripts),
            Location(directory: userLib.appendingPathComponent("Saved Application State", isDirectory: true), category: .savedState),
            Location(directory: userLib.appendingPathComponent("HTTPStorages", isDirectory: true), category: .cookies),
            Location(directory: userLib.appendingPathComponent("WebKit", isDirectory: true), category: .cookies),
            Location(directory: userLib.appendingPathComponent("Preferences", isDirectory: true), category: .preferences),
            Location(directory: userLib.appendingPathComponent("Preferences/ByHost", isDirectory: true), category: .preferences),
            Location(directory: userLib.appendingPathComponent("Mobile Documents", isDirectory: true), category: .iCloud),
            Location(directory: sysLib.appendingPathComponent("Preferences", isDirectory: true), category: .preferences),
        ]
    }

    /// Walk `location.directory`, extract a candidate bundle ID for each
    /// entry, run the filter chain, and group survivors by bundle ID
    /// into `byBundleID`.
    private nonisolated static func scan(
        location: Location,
        installed: InstalledAppsIndex,
        filters: [CandidateFilter],
        into byBundleID: inout [String: [RelatedItem]]
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: location.directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        for entry in entries {
            guard let bundleID = BundleIdentifier.candidate(for: entry, category: location.category) else {
                continue
            }
            let candidate = OrphanCandidate(
                bundleID: bundleID,
                category: location.category,
                installed: installed
            )
            if filters.contains(where: { $0.excludes(candidate) }) { continue }

            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = FileSize.of(at: entry, isDirectory: isDir)
            // iCloud Documents under Mobile Documents/ are real user
            // files that sync to other devices; require explicit opt-in
            // via the group toggle and surface them with a distinct
            // visual cue downstream.
            let shared = location.category == .iCloud
            let item = RelatedItem(
                url: entry,
                category: location.category,
                sizeBytes: size,
                isDirectory: isDir,
                isShared: shared
            )
            byBundleID[bundleID, default: []].append(item)
        }
    }
}
