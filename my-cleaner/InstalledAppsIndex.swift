//
//  InstalledAppsIndex.swift
//  my-cleaner
//

import Foundation

/// Snapshot of every `.app` currently installed on the user's Mac.
///
/// The orphan scanner uses this to answer the central question "does the
/// bundle ID parsed from this Library entry still belong to an app the
/// user has installed?". An entry is only flagged orphaned when the
/// answer is *no* from every reachable angle.
///
/// Two sources contribute:
/// 1. A bounded directory walk of `/Applications` and
///    `~/Applications` (depth ≤ 1), plus the helper bundles each `.app`
///    embeds under `Contents/PlugIns`, `LoginItems`, `Helpers` and
///    `XPCServices`. Fast, cheap, reliable for the common case.
/// 2. A Spotlight pass for every `com.apple.application-bundle`.
///    Catches apps installed in places the walk can't see (Setapp under
///    `/Applications/Setapp`, deeply-nested vendor directories, `/opt`,
///    external volumes).
///
/// The result is `Sendable` so the orphan scanner can build it on a
/// background task and pass it through filter implementations without
/// copying state out of an actor.
nonisolated struct InstalledAppsIndex: Sendable {

    /// Every bundle identifier we found, lowercased for case-insensitive
    /// matching. Includes nested helper bundles (`*.appex`, `*.xpc`,
    /// LoginItems) so a helper's container isn't mistaken for an orphan
    /// of its parent app.
    let bundleIDs: Set<String>

    /// Team identifiers harvested via `CodeSignReader` for each `.app`.
    /// Used to keep team-prefixed Group Containers and Application
    /// Scripts entries alive while *any* app from that team is still
    /// installed.
    let teamIDs: Set<String>

    /// Pre-computed two-segment "vendor namespaces" (`com.docker`,
    /// `net.whatsapp`) derived from `bundleIDs`. Cached here so
    /// `VendorNamespaceFilter` doesn't have to recompute it per
    /// candidate.
    let vendorNamespaces: Set<String>

    /// Walk `/Applications` + `~/Applications` and run a Spotlight pass
    /// to build a fresh snapshot.
    ///
    /// - Returns: A populated `InstalledAppsIndex`.
    nonisolated static func build() -> InstalledAppsIndex {
        let fm = FileManager.default
        let roots: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        var bundleIDs: Set<String> = []
        var teamIDs: Set<String> = []
        var visitedApps: Set<URL> = []

        for root in roots {
            collectApps(in: root, depth: 0, bundleIDs: &bundleIDs, teamIDs: &teamIDs, visited: &visitedApps)
        }

        let spotlightHits = SpotlightSearch.find(
            predicate: "kMDItemContentType == 'com.apple.application-bundle'"
        )
        for url in spotlightHits {
            let std = url.standardizedFileURL
            if visitedApps.contains(std) { continue }
            visitedApps.insert(std)
            if let bundle = Bundle(url: std), let bid = bundle.bundleIdentifier {
                bundleIDs.insert(bid.lowercased())
            }
            if let tid = CodeSignReader.readTeamID(forAppAt: std) {
                teamIDs.insert(tid)
            }
            harvestNestedBundleIDs(in: std, into: &bundleIDs)
        }

        let vendors: Set<String> = Set(bundleIDs.compactMap(BundleIdentifier.vendorNamespace(of:)))

        return InstalledAppsIndex(
            bundleIDs: bundleIDs,
            teamIDs: teamIDs,
            vendorNamespaces: vendors
        )
    }

    /// Recursively scan `dir` for `.app` bundles, harvesting bundle and
    /// team identifiers (plus nested helper bundle IDs).
    ///
    /// `depth` is bounded at 1 so vendor grouping folders
    /// (`/Applications/Utilities`, `/Applications/Adobe Creative Cloud/`)
    /// still surface their contents, but we don't descend arbitrarily.
    private nonisolated static func collectApps(
        in dir: URL,
        depth: Int,
        bundleIDs: inout Set<String>,
        teamIDs: inout Set<String>,
        visited: inout Set<URL>
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        for entry in entries {
            if entry.pathExtension.lowercased() == "app" {
                let std = entry.standardizedFileURL
                visited.insert(std)
                if let bundle = Bundle(url: std), let bid = bundle.bundleIdentifier {
                    bundleIDs.insert(bid.lowercased())
                }
                if let tid = CodeSignReader.readTeamID(forAppAt: std) {
                    teamIDs.insert(tid)
                }
                harvestNestedBundleIDs(in: std, into: &bundleIDs)
                continue
            }
            if depth < 1,
               let isDir = try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
               isDir {
                collectApps(in: entry, depth: depth + 1, bundleIDs: &bundleIDs, teamIDs: &teamIDs, visited: &visited)
            }
        }
    }

    /// Pull bundle identifiers out of every helper bundle an `.app`
    /// ships internally.
    ///
    /// Apps frequently register additional bundle IDs for App Extensions
    /// (`.appex`), Login Items (`.app` inside `LoginItems`), XPC services
    /// (`.xpc`), and miscellaneous helpers — and macOS gives each of
    /// those helpers their own `~/Library` container. Without indexing
    /// them, a helper's container looks like an orphan even when the
    /// parent app is installed (e.g. Microsoft Teams shipping
    /// `com.microsoft.teams2.agent` alongside `com.microsoft.teams2`).
    private nonisolated static func harvestNestedBundleIDs(
        in appURL: URL,
        into bundleIDs: inout Set<String>
    ) {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let nestedRoots: [URL] = [
            contents.appendingPathComponent("PlugIns", isDirectory: true),
            contents.appendingPathComponent("Library/LoginItems", isDirectory: true),
            contents.appendingPathComponent("Helpers", isDirectory: true),
            contents.appendingPathComponent("XPCServices", isDirectory: true),
        ]
        let fm = FileManager.default
        for root in nestedRoots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }
            for entry in entries {
                let ext = entry.pathExtension.lowercased()
                guard ext == "app" || ext == "appex" || ext == "xpc" else { continue }
                if let bundle = Bundle(url: entry), let bid = bundle.bundleIdentifier {
                    bundleIDs.insert(bid.lowercased())
                }
            }
        }
    }
}
