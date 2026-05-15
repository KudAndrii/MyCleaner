//
//  OrphanScanner.swift
//  my-cleaner
//
//  Finds Library entries whose name looks like a bundle ID (or an iCloud /
//  group-container variant of one) and whose bundle ID no longer resolves
//  to an installed app. These are leftover support files from apps the user
//  removed long ago without using an uninstaller.
//

import Foundation

nonisolated struct OrphanGroup: Identifiable, Hashable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let items: [RelatedItem]
    var totalSize: Int64 { items.map(\.sizeBytes).reduce(0, +) }
    var isSelected: Bool
}

nonisolated struct OrphanScanResult: Sendable {
    let groups: [OrphanGroup]
    var totalSize: Int64 { groups.flatMap(\.items).map(\.sizeBytes).reduce(0, +) }
}

enum OrphanScanner {

    nonisolated static func scan() -> OrphanScanResult {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let userLib = home.appendingPathComponent("Library", isDirectory: true)
        let sysLib = URL(fileURLWithPath: "/Library", isDirectory: true)

        // (directory, category) — only places where folders are conventionally
        // named after a bundle ID (or a recognisable variant). We deliberately
        // skip name-based folders like `Application Support/JetBrains` because
        // they can't be attributed to a specific bundle ID without false
        // positives.
        let locations: [(URL, RelatedItem.Category)] = [
            (userLib.appendingPathComponent("Containers", isDirectory: true), .containers),
            (userLib.appendingPathComponent("Group Containers", isDirectory: true), .groupContainers),
            (userLib.appendingPathComponent("Application Scripts", isDirectory: true), .scripts),
            (userLib.appendingPathComponent("Saved Application State", isDirectory: true), .savedState),
            (userLib.appendingPathComponent("HTTPStorages", isDirectory: true), .cookies),
            (userLib.appendingPathComponent("WebKit", isDirectory: true), .cookies),
            (userLib.appendingPathComponent("Preferences", isDirectory: true), .preferences),
            (userLib.appendingPathComponent("Preferences/ByHost", isDirectory: true), .preferences),
            (userLib.appendingPathComponent("Mobile Documents", isDirectory: true), .iCloud),
            (sysLib.appendingPathComponent("Preferences", isDirectory: true), .preferences),
        ]

        var byBundleID: [String: [RelatedItem]] = [:]
        let installed = collectInstalledApps()

        for (dir, category) in locations {
            scanDir(
                dir,
                category: category,
                installedBundleIDs: installed.bundleIDs,
                installedTeamIDs: installed.teamIDs,
                into: &byBundleID
            )
        }

        let groups: [OrphanGroup] = byBundleID
            .map { OrphanGroup(bundleID: $0.key, items: $0.value, isSelected: false) }
            .sorted { $0.totalSize > $1.totalSize }

        return OrphanScanResult(groups: groups)
    }

    private nonisolated static func scanDir(
        _ dir: URL,
        category: RelatedItem.Category,
        installedBundleIDs: Set<String>,
        installedTeamIDs: Set<String>,
        into byBundleID: inout [String: [RelatedItem]]
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        for entry in entries {
            guard let candidate = candidateBundleID(for: entry, category: category) else { continue }
            if isAppleReserved(candidate) { continue }
            if installedBundleIDs.contains(candidate.lowercased()) { continue }
            // Team-prefixed group containers (`UBF8T346G9.Office`) belong to
            // a developer, not a single app. If *any* app from that team is
            // still installed, don't surface them.
            if category == .groupContainers,
               let teamID = teamIDPrefix(of: candidate),
               installedTeamIDs.contains(teamID) {
                continue
            }

            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = AppScanner.sizeOfItem(at: entry, isDirectory: isDir)
            let item = RelatedItem(
                url: entry,
                category: category,
                sizeBytes: size,
                isDirectory: isDir,
                isShared: false
            )
            byBundleID[candidate, default: []].append(item)
        }
    }

    // Extract the bundle ID a directory entry was named after, undoing the
    // category-specific naming convention (group prefix, iCloud tilde-encoded
    // form, .plist / .savedState / .binarycookies suffix). Returns nil for
    // entries that don't look like a bundle ID at all.
    private nonisolated static func candidateBundleID(
        for url: URL,
        category: RelatedItem.Category
    ) -> String? {
        let name = url.lastPathComponent

        if category == .iCloud {
            guard name.hasPrefix("iCloud~") else { return nil }
            let tail = String(name.dropFirst("iCloud~".count))
            let bid = tail.replacingOccurrences(of: "~", with: ".")
            return looksLikeBundleID(bid) ? bid : nil
        }

        if category == .preferences {
            guard name.hasSuffix(".plist") else { return nil }
            let base = (name as NSString).deletingPathExtension
            // ByHost plists have a UUID suffix: `com.foo.bar.<UUID>.plist`.
            let stripped = stripByHostUUID(base)
            return looksLikeBundleID(stripped) ? stripped : nil
        }

        if category == .groupContainers {
            if name.hasPrefix("group.") {
                let bid = String(name.dropFirst("group.".count))
                return looksLikeBundleID(bid) ? bid : nil
            }
            // `UBF8T346G9.Office` — team-prefix group container. We keep the
            // full string as the "bundle ID" key so attribution still works.
            return looksLikeBundleID(name) ? name : nil
        }

        // Strip suffixes the various categories tack onto bundle IDs.
        let stripped = stripKnownSuffix(name)
        return looksLikeBundleID(stripped) ? stripped : nil
    }

    private nonisolated static func stripKnownSuffix(_ name: String) -> String {
        let suffixes = [".savedState", ".binarycookies"]
        for suffix in suffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    private nonisolated static func looksLikeBundleID(_ s: String) -> Bool {
        // Must have at least one dot, no path separators, no spaces, and
        // each component non-empty.
        guard s.contains("."),
              !s.contains("/"),
              !s.contains(" "),
              !s.hasPrefix("."),
              !s.hasSuffix(".") else { return false }
        let parts = s.split(separator: ".")
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { !$0.isEmpty }
    }

    private nonisolated static func stripByHostUUID(_ base: String) -> String {
        // `<bundleID>.XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX` → `<bundleID>`.
        let parts = base.split(separator: ".")
        guard let last = parts.last,
              last.count == 36,
              last.filter({ $0 == "-" }).count == 4 else { return base }
        return parts.dropLast().joined(separator: ".")
    }

    private nonisolated static func teamIDPrefix(of s: String) -> String? {
        // Apple team IDs are 10 uppercase alphanumerics.
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let head = String(s[..<dot])
        guard head.count == 10,
              head.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return head
    }

    private nonisolated static func isAppleReserved(_ bid: String) -> Bool {
        let lower = bid.lowercased()
        if lower.hasPrefix("com.apple.") { return true }
        if lower == "apple" || lower.hasPrefix("apple.") { return true }
        return false
    }

    // Walk /Applications and ~/Applications and read each .app's Info.plist
    // + code signature once. We use bundle IDs to decide "is this bundle
    // still installed", and team IDs to keep team-prefix group containers
    // from being flagged when sibling apps from the same developer remain.
    //
    // This is more conservative than asking Launch Services — LS remembers
    // apps it has ever seen, including bundles mounted from DMGs and
    // quarantined downloads. We only want apps actually present in an
    // Applications folder right now.
    private nonisolated static func collectInstalledApps() -> (bundleIDs: Set<String>, teamIDs: Set<String>) {
        let fm = FileManager.default
        let roots: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        var bundleIDs: Set<String> = []
        var teamIDs: Set<String> = []

        for root in roots {
            collectApps(in: root, depth: 0, bundleIDs: &bundleIDs, teamIDs: &teamIDs)
        }
        return (bundleIDs, teamIDs)
    }

    private nonisolated static func collectApps(
        in dir: URL,
        depth: Int,
        bundleIDs: inout Set<String>,
        teamIDs: inout Set<String>
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        for entry in entries {
            if entry.pathExtension.lowercased() == "app" {
                if let bundle = Bundle(url: entry), let bid = bundle.bundleIdentifier {
                    bundleIDs.insert(bid.lowercased())
                }
                if let tid = AppScanner.readTeamID(forAppAt: entry) {
                    teamIDs.insert(tid)
                }
                continue
            }
            // Recurse one level so apps grouped in vendor subfolders
            // (`/Applications/Utilities`, `/Applications/Adobe Creative Cloud/`)
            // still get found.
            if depth < 1,
               let isDir = try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
               isDir {
                collectApps(in: entry, depth: depth + 1, bundleIDs: &bundleIDs, teamIDs: &teamIDs)
            }
        }
    }
}
