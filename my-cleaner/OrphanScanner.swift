//
//  OrphanScanner.swift
//  my-cleaner
//
//  Orphan-detection pipeline.
//
//  The flow mirrors ``AppScanner`` but inverts the "find vs filter"
//  responsibilities:
//
//    1. **Find** — walk a fixed set of Library locations whose entries
//       are conventionally named after a bundle ID (Containers, Group
//       Containers, Preferences, etc.). Each on-disk name is mapped to
//       a *candidate* bundle ID, undoing any category-specific naming
//       quirks (`group.` prefix, iCloud tilde encoding, `.plist`
//       suffix, ByHost UUID, …).
//
//    2. **Filter** — pass every candidate through the
//       ``OrphanScanner/filters`` chain. Each ``OrphanFilter``
//       implements one exclusion rule (Apple-reserved, installed exact
//       / child / ancestor, vendor namespace, team prefix, Launch
//       Services). A candidate that survives every filter is surfaced
//       as an orphan.
//

import Foundation
import AppKit

// MARK: - Model

/// A group of leftover files all attributed to the same (uninstalled) bundle ID.
nonisolated struct OrphanGroup: Identifiable, Hashable, Sendable {
    /// Identity is the bundle ID the group is keyed under.
    var id: String { bundleID }

    /// The bundle ID we attributed every item in this group to.
    let bundleID: String

    /// All the orphan items grouped under this bundle ID.
    let items: [RelatedItem]

    /// Sum of every item's allocated size, in bytes.
    var totalSize: Int64 { items.map(\.sizeBytes).reduce(0, +) }

    /// User-controlled toggle — true when the whole group is staged for trashing.
    var isSelected: Bool
}

/// The full orphan-scan output: every surfaced group plus an
/// across-groups size total for the UI summary.
nonisolated struct OrphanScanResult: Sendable {
    let groups: [OrphanGroup]
    var totalSize: Int64 { groups.flatMap(\.items).map(\.sizeBytes).reduce(0, +) }
}

// MARK: - Scanner

/// Finds Library entries whose names look like a bundle ID but whose
/// owning app no longer resolves to anything installed on disk.
///
/// See the file header for the two-phase find / filter pipeline.
enum OrphanScanner {

    // MARK: Locations

    /// Library directories whose entries are conventionally named
    /// after a bundle ID (or a recognisable variant).
    ///
    /// We deliberately **skip** name-based folders like
    /// `Application Support/JetBrains/` — they can't be attributed to a
    /// specific bundle ID without false positives.
    private nonisolated static func libraryLocations() -> [(URL, RelatedItem.Category)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let userLib = home.appendingPathComponent("Library", isDirectory: true)
        let sysLib = URL(fileURLWithPath: "/Library", isDirectory: true)

        return [
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
    }

    /// The ordered filter chain that decides whether a candidate is
    /// **excluded** from the orphan results.
    ///
    /// Order matters: cheap exclusions first, the disk-touching
    /// `LaunchServicesFilter` last so it only runs on candidates that
    /// already look genuinely orphaned. Returned as a function rather
    /// than a `static let` so the call sites stay independent of any
    /// global Sendable storage rules.
    private nonisolated static func filters() -> [any OrphanFilter] {
        [
            AppleReservedFilter(),
            InstalledBundleIDFilter(),
            InstalledChildFilter(),
            InstalledAncestorFilter(),
            VendorNamespaceFilter(),
            TeamPrefixFilter(),
            LaunchServicesFilter(),
        ]
    }

    // MARK: Entry point

    /// Runs a full orphan scan over every ``libraryLocations()`` entry.
    ///
    /// Empty groups (every item is a 0-byte placeholder) are dropped
    /// to keep the results list free of pure-UI noise. Surviving
    /// groups are returned sorted by total size, largest first.
    nonisolated static func scan() -> OrphanScanResult {
        var byBundleID: [String: [RelatedItem]] = [:]
        let installed = collectInstalledApps()
        // Pre-compute the set of "vendor namespaces" — the first two
        // reverse-DNS segments of every installed bundle ID. Used
        // downstream by VendorNamespaceFilter. Cheaper than re-deriving
        // it for every entry.
        let installedVendors: Set<String> = Set(
            installed.bundleIDs.compactMap(vendorNamespace(of:))
        )

        for (dir, category) in libraryLocations() {
            scanDir(
                dir,
                category: category,
                installedBundleIDs: installed.bundleIDs,
                installedTeamIDs: installed.teamIDs,
                installedVendors: installedVendors,
                into: &byBundleID
            )
        }

        let groups: [OrphanGroup] = byBundleID
            .map { OrphanGroup(bundleID: $0.key, items: $0.value, isSelected: false) }
            .filter { $0.totalSize > 0 }
            .sorted { $0.totalSize > $1.totalSize }

        return OrphanScanResult(groups: groups)
    }

    // MARK: Directory walk

    /// Walks a single Library directory and groups surviving candidates
    /// by bundle ID into `byBundleID`.
    ///
    /// Each entry is converted to a candidate bundle ID via
    /// ``candidateBundleID(for:category:)``; entries that don't look
    /// like a bundle ID are silently skipped. Surviving candidates are
    /// passed through the ``filters`` chain — any filter that hits
    /// excludes the entry.
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

        let filterChain = filters()

        for entry in entries {
            guard let candidate = candidateBundleID(for: entry, category: category) else { continue }

            let context = OrphanFilterContext(
                candidateBundleID: candidate,
                candidateBundleIDLower: candidate.lowercased(),
                category: category,
                installedBundleIDs: installedBundleIDs,
                installedTeamIDs: installedTeamIDs,
                installedVendors: installedVendors
            )
            if filterChain.contains(where: { $0.shouldExclude(context) }) { continue }

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

    // MARK: Candidate extraction

    /// Extracts the bundle ID a directory entry was named after, undoing
    /// the category-specific naming convention.
    ///
    /// Handles `group.` / `vgroup.` prefixes, iCloud tilde-encoding,
    /// `.plist` / `.savedState` / `.binarycookies` suffixes, and
    /// ByHost UUID tails.
    ///
    /// - Returns: `nil` for entries that don't look like a bundle ID at all.
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
            // `UBF8T346G9.Office` — team-prefix group container. We keep
            // the full string as the "bundle ID" key so attribution
            // still works.
            return looksLikeBundleID(name) ? name : nil
        }

        // Strip suffixes the various categories tack onto bundle IDs.
        let stripped = stripKnownSuffix(name)
        return looksLikeBundleID(stripped) ? stripped : nil
    }

    /// Strips `.savedState` / `.binarycookies` suffixes, leaving the bundle ID.
    /// Returns the input unchanged when no known suffix matches.
    nonisolated static func stripKnownSuffix(_ name: String) -> String {
        let suffixes = [".savedState", ".binarycookies"]
        for suffix in suffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// Cheap structural sanity check that a string plausibly is a bundle ID.
    ///
    /// Requires at least one dot, no path separators or spaces, no
    /// leading/trailing dot, and every component non-empty. The first
    /// segment additionally has to be ≥ 2 characters and start with a
    /// letter so things like `"0.5"` or `".cache"` aren't mistaken
    /// for bundle IDs.
    nonisolated static func looksLikeBundleID(_ s: String) -> Bool {
        guard s.contains("."),
              !s.contains("/"),
              !s.contains(" "),
              !s.hasPrefix("."),
              !s.hasSuffix(".") else { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let head = parts[0]
        guard head.count >= 2, let first = head.first, first.isLetter else { return false }
        return true
    }

    /// Removes a trailing `.XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX` UUID
    /// from a ByHost plist basename, leaving the bundle ID.
    ///
    /// Returns the input unchanged when the tail isn't a UUID-shaped
    /// 36-character segment with exactly four dashes.
    nonisolated static func stripByHostUUID(_ base: String) -> String {
        let parts = base.split(separator: ".")
        guard let last = parts.last,
              last.count == 36,
              last.filter({ $0 == "-" }).count == 4 else { return base }
        return parts.dropLast().joined(separator: ".")
    }

    /// Extracts a 10-character uppercase alphanumeric Apple team ID
    /// from the front of a string like `UBF8T346G9.Office`.
    ///
    /// Returns `nil` if there's no dot, or the prefix isn't exactly 10
    /// uppercase ASCII alphanumerics.
    nonisolated static func teamIDPrefix(of s: String) -> String? {
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let head = String(s[..<dot])
        guard head.count == 10,
              head.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return head
    }

    /// First two reverse-DNS segments of a bundle ID — the "vendor".
    ///
    /// `com.docker.docker` → `com.docker`, `net.whatsapp.WhatsApp` →
    /// `net.whatsapp`. Returns `nil` for IDs with fewer than two
    /// segments, which are too generic to use as a vendor key.
    nonisolated static func vendorNamespace(of bid: String) -> String? {
        let parts = bid.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }

    /// `true` for bundle IDs in Apple's reserved namespace.
    nonisolated static func isAppleReserved(_ bid: String) -> Bool {
        let lower = bid.lowercased()
        if lower.hasPrefix("com.apple.") { return true }
        if lower == "apple" || lower.hasPrefix("apple.") { return true }
        return false
    }

    // MARK: Installed-app inventory

    /// Builds the "still installed" set from two complementary sources.
    ///
    /// 1. A bounded directory walk of `/Applications` and
    ///    `~/Applications` (depth ≤ 1). Fast, cheap, and reliably
    ///    picks up the common case.
    ///
    /// 2. A Spotlight query for every `.app` bundle on disk. Catches
    ///    installs the walk can't see — Setapp under
    ///    `/Applications/Setapp`, Autodesk Fusion buried deep in
    ///    `~/Library/Application Support/Autodesk/webdeploy/<hash>/`,
    ///    apps under `/opt`, `/usr/local`, or external volumes.
    ///
    /// Both sources contribute bundle IDs. Team IDs come from a code-sign
    /// read on every collected `.app` so the team-prefix Group Container
    /// check also works for apps reached only via Spotlight.
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
