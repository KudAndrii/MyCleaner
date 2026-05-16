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
import AppKit

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
        // Pre-compute the set of "vendor namespaces" — the first two
        // reverse-DNS segments of every installed bundle ID. Used downstream
        // to filter sibling-namespace candidates (`com.viber.ViberPC` when
        // `com.viber.osx` is installed, `net.whatsapp.family` when
        // `net.whatsapp.WhatsApp` is installed, etc.). Cheaper than
        // re-deriving it for every entry.
        let installedVendors: Set<String> = Set(
            installed.bundleIDs.compactMap(vendorNamespace(of:))
        )

        for (dir, category) in locations {
            scanDir(
                dir,
                category: category,
                installedBundleIDs: installed.bundleIDs,
                installedTeamIDs: installed.teamIDs,
                installedVendors: installedVendors,
                into: &byBundleID
            )
        }

        // Skip empty-husk groups: bundles whose entries are all 0-byte
        // placeholders (Apple system stubs like group.com.apple.CloudDocs
        // tend to land here once the OS has cleaned out their contents).
        // No disk recovered, so they're pure UI noise.
        let groups: [OrphanGroup] = byBundleID
            .map { OrphanGroup(bundleID: $0.key, items: $0.value, isSelected: false) }
            .filter { $0.totalSize > 0 }
            .sorted { $0.totalSize > $1.totalSize }

        return OrphanScanResult(groups: groups)
    }

    nonisolated static func scanDir(
        _ dir: URL,
        category: RelatedItem.Category,
        installedBundleIDs: Set<String>,
        installedTeamIDs: Set<String>,
        installedVendors: Set<String>,
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
            let lower = candidate.lowercased()
            if installedBundleIDs.contains(lower) { continue }
            // App-group identifiers (`net.whatsapp.WhatsApp.shared`) and
            // helper sub-bundles (`com.microsoft.teams2.agent`) are children
            // of an installed bundle ID, separated by an extra `.<suffix>`.
            // Treat any candidate whose prefix matches an installed bundle
            // ID as still-installed.
            if installedBundleIDs.contains(where: { lower.hasPrefix($0 + ".") }) {
                continue
            }
            // Mirror image: some apps register a shorter ancestor bundle ID
            // for shared resources. Docker installs `com.docker.docker` and
            // owns a `com.docker` container in ~/Library. Treat any candidate
            // that is a strict ancestor of an installed bundle ID as still
            // owned by that family.
            if installedBundleIDs.contains(where: { $0.hasPrefix(lower + ".") }) {
                continue
            }
            // Sibling-namespace rule: when the candidate's first two
            // reverse-DNS segments match an installed app's vendor namespace
            // (`com.viber.*`, `net.whatsapp.*`), treat the candidate as part
            // of that vendor's app family. Filters siblings like
            // `com.viber.ViberPC` when `com.viber.osx` is installed, or
            // `net.whatsapp.family` when `net.whatsapp.WhatsApp` is. Cost:
            // a genuinely uninstalled sibling from a vendor whose other apps
            // remain installed (e.g. an old Microsoft product container)
            // won't surface here — that's an accepted recall trade-off for
            // a destructive operation.
            if let vendor = vendorNamespace(of: lower),
               installedVendors.contains(vendor) {
                continue
            }
            // Team-prefixed group containers (`UBF8T346G9.Office`) and the
            // matching Application Scripts entries belong to a developer, not
            // a single app. If *any* app from that team is still installed,
            // don't surface them.
            if (category == .groupContainers || category == .scripts),
               let teamID = teamIDPrefix(of: candidate),
               installedTeamIDs.contains(teamID) {
                continue
            }
            // Backstop: the directory walk only knows about /Applications and
            // ~/Applications. If Launch Services can resolve the bundle ID to
            // a real .app anywhere on disk (Setapp, /opt, nested vendor dirs,
            // a mounted DMG), bail out — the app probably is still installed
            // and these aren't orphans.
            if launchServicesKnows(bundleID: candidate) { continue }

            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = AppScanner.sizeOfItem(at: entry, isDirectory: isDir)
            // iCloud Documents under Mobile Documents/ are real user files
            // that sync; require explicit opt-in via the group toggle and
            // surface them with a distinct visual cue downstream.
            let shared = category == .iCloud
            let item = RelatedItem(
                url: entry,
                category: category,
                sizeBytes: size,
                isDirectory: isDir,
                isShared: shared
            )
            byBundleID[candidate, default: []].append(item)
        }
    }

    // Extract the bundle ID a directory entry was named after, undoing the
    // category-specific naming convention (group prefix, iCloud tilde-encoded
    // form, .plist / .savedState / .binarycookies suffix). Returns nil for
    // entries that don't look like a bundle ID at all.
    nonisolated static func candidateBundleID(
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
            // Case-insensitive strip of the conventional group prefixes.
            // Apple's standard form is `group.<bid>`; we've also seen
            // vendor variants like `vgroup.<bid>` in the wild (Viber).
            let lowered = name.lowercased()
            for prefix in ["group.", "vgroup."] where lowered.hasPrefix(prefix) {
                let bid = String(name.dropFirst(prefix.count))
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

    nonisolated static func stripKnownSuffix(_ name: String) -> String {
        let suffixes = [".savedState", ".binarycookies"]
        for suffix in suffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    nonisolated static func looksLikeBundleID(_ s: String) -> Bool {
        // Must have at least one dot, no path separators, no spaces, and
        // each component non-empty. The first segment must look like a
        // reverse-DNS root (≥ 2 chars, starts with a letter) so we don't
        // mistake things like "0.5" or ".cache" for a bundle ID.
        guard s.contains("."),
              !s.contains("/"),
              !s.contains(" "),
              !s.hasPrefix("."),
              !s.hasSuffix(".") else { return false }
        let parts = s.split(separator: ".")
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let head = parts[0]
        guard head.count >= 2, let first = head.first, first.isLetter else { return false }
        return true
    }

    // Ask Launch Services whether the bundle ID still resolves to an
    // installed .app. This catches apps in non-standard install locations
    // (Setapp, /opt, deeply nested vendor folders) that the directory walk
    // can't reach. It's deliberately the secondary check: LS is lenient and
    // can remember bundles from old DMGs, but for a bundle whose folder
    // looks orphaned, an LS hit is strong evidence the app is actually
    // installed somewhere we just didn't look.
    private nonisolated static func launchServicesKnows(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    nonisolated static func stripByHostUUID(_ base: String) -> String {
        // `<bundleID>.XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX` → `<bundleID>`.
        let parts = base.split(separator: ".")
        guard let last = parts.last,
              last.count == 36,
              last.filter({ $0 == "-" }).count == 4 else { return base }
        return parts.dropLast().joined(separator: ".")
    }

    nonisolated static func teamIDPrefix(of s: String) -> String? {
        // Apple team IDs are 10 uppercase alphanumerics.
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let head = String(s[..<dot])
        guard head.count == 10,
              head.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return head
    }

    // The first two reverse-DNS segments of a bundle ID — e.g.
    // `com.docker.docker` → `com.docker`, `net.whatsapp.WhatsApp` →
    // `net.whatsapp`. Returns nil for IDs with fewer than two segments,
    // which are too generic to use as a "vendor" key.
    nonisolated static func vendorNamespace(of bid: String) -> String? {
        let parts = bid.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }

    nonisolated static func isAppleReserved(_ bid: String) -> Bool {
        let lower = bid.lowercased()
        if lower.hasPrefix("com.apple.") { return true }
        if lower == "apple" || lower.hasPrefix("apple.") { return true }
        return false
    }

    // Build the "still installed" set from two sources:
    //
    //   1. A directory walk of /Applications and ~/Applications (depth ≤ 1).
    //      Fast, cheap, and reliably picks up the common case.
    //
    //   2. A Spotlight query for every `.app` bundle on disk. This catches
    //      installs the walk can't see — Setapp under /Applications/Setapp,
    //      Autodesk Fusion buried deep in
    //      ~/Library/Application Support/Autodesk/webdeploy/<hash>/, things
    //      under /opt, /usr/local, or external volumes the user has open.
    //
    // Both sources contribute bundle IDs; team IDs come from a code-sign
    // read on every collected .app so the team-prefix Group Container check
    // works for apps reached only via Spotlight too.
    private nonisolated static func collectInstalledApps() -> (bundleIDs: Set<String>, teamIDs: Set<String>) {
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

        // Spotlight pass: every .app the user has installed anywhere.
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
            if let tid = AppScanner.readTeamID(forAppAt: std) {
                teamIDs.insert(tid)
            }
            harvestNestedBundleIDs(in: std, into: &bundleIDs)
        }

        return (bundleIDs, teamIDs)
    }

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
                if let tid = AppScanner.readTeamID(forAppAt: std) {
                    teamIDs.insert(tid)
                }
                // Pull in any nested helper bundles (PlugIns/*.appex,
                // Library/LoginItems/*.app, Helpers/*) — apps like Teams 2
                // ship `com.microsoft.teams2.agent` as a separate bundle
                // that has its own container in ~/Library, and we'd flag
                // that container as orphaned without indexing the helper.
                harvestNestedBundleIDs(in: std, into: &bundleIDs)
                continue
            }
            // Recurse one level so apps grouped in vendor subfolders
            // (`/Applications/Utilities`, `/Applications/Adobe Creative Cloud/`)
            // still get found.
            if depth < 1,
               let isDir = try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
               isDir {
                collectApps(in: entry, depth: depth + 1, bundleIDs: &bundleIDs, teamIDs: &teamIDs, visited: &visited)
            }
        }
    }

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
