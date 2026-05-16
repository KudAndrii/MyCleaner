//
//  OrphanFilter.swift
//  my-cleaner
//
//  The "filter out non-orphans" half of the orphan-cleanup flow.
//
//  ``OrphanScanner`` walks Library directories whose entries are
//  conventionally named after a bundle ID, then asks an ordered chain
//  of filters to exclude any candidate that isn't actually orphaned.
//  Splitting the rules into typed filters keeps every exclusion rule
//  small, named, and independently testable — adding a new heuristic
//  is a matter of adding one struct to the chain.
//
//  The chain is exclusion-only: a candidate that survives every
//  filter is surfaced as an orphan. There is no "approve" verdict.
//

import Foundation
import AppKit

// MARK: - Filter context

/// Read-only payload threaded through the filter chain for a single candidate.
nonisolated struct OrphanFilterContext: Sendable {
    /// The candidate bundle ID, kept in its original case for team-ID detection.
    let candidateBundleID: String

    /// `candidateBundleID.lowercased()`, precomputed once for the chain.
    let candidateBundleIDLower: String

    /// Which Library bucket the candidate was enumerated under. Some filters
    /// only apply to specific categories (e.g. team-prefix to Group Containers).
    let category: RelatedItem.Category

    /// Lowercased bundle IDs of every currently installed app and helper.
    let installedBundleIDs: Set<String>

    /// 10-character code-signing team identifiers of every currently installed app.
    let installedTeamIDs: Set<String>

    /// First two reverse-DNS segments of every installed bundle ID — `com.docker`,
    /// `net.whatsapp`, etc. Used for the sibling-vendor heuristic.
    let installedVendors: Set<String>
}

// MARK: - Filter protocol

/// One exclusion rule — "this candidate isn't actually orphaned."
///
/// Implementations should be cheap; the scanner runs every filter on
/// every candidate. Order matters: filters that hit on common cases
/// (Apple namespace, exact installed match) come first so the
/// expensive ones (Launch Services) only see the survivors.
protocol OrphanFilter: Sendable {
    /// - Returns: `true` if the candidate should be **excluded** from orphan results.
    nonisolated func shouldExclude(_ context: OrphanFilterContext) -> Bool
}

// MARK: - Concrete filters

/// Excludes anything in Apple's reserved namespace — `com.apple.*`,
/// `apple`, `apple.*`. macOS owns these and the user shouldn't be
/// touching them.
nonisolated struct AppleReservedFilter: OrphanFilter {
    func shouldExclude(_ context: OrphanFilterContext) -> Bool {
        OrphanScanner.isAppleReserved(context.candidateBundleID)
    }
}

/// Excludes candidates whose bundle ID matches an installed app exactly.
nonisolated struct InstalledBundleIDFilter: OrphanFilter {
    func shouldExclude(_ context: OrphanFilterContext) -> Bool {
        context.installedBundleIDs.contains(context.candidateBundleIDLower)
    }
}

/// Excludes app-group identifiers and helper sub-bundles whose prefix
/// matches an installed bundle ID — e.g. `com.microsoft.teams2.agent`
/// when `com.microsoft.teams2` is installed.
nonisolated struct InstalledChildFilter: OrphanFilter {
    func shouldExclude(_ context: OrphanFilterContext) -> Bool {
        let lower = context.candidateBundleIDLower
        return context.installedBundleIDs.contains { lower.hasPrefix($0 + ".") }
    }
}

/// Excludes shorter "umbrella" bundle IDs whose extension matches an
/// installed app — e.g. `com.docker` when `com.docker.docker` is
/// installed and owns a shared container at the parent level.
nonisolated struct InstalledAncestorFilter: OrphanFilter {
    func shouldExclude(_ context: OrphanFilterContext) -> Bool {
        let lower = context.candidateBundleIDLower
        return context.installedBundleIDs.contains { $0.hasPrefix(lower + ".") }
    }
}

/// Excludes sibling apps from the same vendor — `com.viber.ViberPC`
/// when `com.viber.osx` is installed, `net.whatsapp.family` when
/// `net.whatsapp.WhatsApp` is installed.
///
/// Trade-off: a genuinely orphaned sibling whose vendor still ships
/// another installed app won't surface. Accepted because false
/// positives on a destructive operation are worse than missed
/// recoveries.
nonisolated struct VendorNamespaceFilter: OrphanFilter {
    func shouldExclude(_ context: OrphanFilterContext) -> Bool {
        guard let vendor = OrphanScanner.vendorNamespace(of: context.candidateBundleIDLower) else {
            return false
        }
        return context.installedVendors.contains(vendor)
    }
}

/// Excludes team-ID-prefixed Group Containers and Application Scripts
/// (`UBF8T346G9.Office`) whose owning developer still ships an
/// installed app.
nonisolated struct TeamPrefixFilter: OrphanFilter {
    func shouldExclude(_ context: OrphanFilterContext) -> Bool {
        guard context.category == .groupContainers || context.category == .scripts else { return false }
        guard let teamID = OrphanScanner.teamIDPrefix(of: context.candidateBundleID) else { return false }
        return context.installedTeamIDs.contains(teamID)
    }
}

/// Asks Launch Services whether the bundle ID still resolves to an
/// installed `.app` anywhere on disk — Setapp, `/opt`, `/usr/local`,
/// mounted DMGs.
///
/// Deliberately the last filter in the chain because it's the only
/// one that can hit the disk. Launch Services is lenient and may
/// remember bundles from old DMGs, but for a candidate that survived
/// every other check an LS hit is strong evidence the app is still
/// installed somewhere the walk didn't reach.
nonisolated struct LaunchServicesFilter: OrphanFilter {
    func shouldExclude(_ context: OrphanFilterContext) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: context.candidateBundleID
        ) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
