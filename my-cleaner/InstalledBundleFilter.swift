//
//  InstalledBundleFilter.swift
//  my-cleaner
//

import Foundation

/// Rejects candidates that match — directly or by family — a bundle ID
/// MyCleaner has already detected as installed.
///
/// Three relationships count as "installed":
///
/// 1. **Exact match.** The candidate's lowercased ID is in
///    `installed.bundleIDs`.
/// 2. **App-group / helper child.** The candidate is a strict descendant
///    of an installed bundle ID (`net.whatsapp.WhatsApp.shared` →
///    `net.whatsapp.WhatsApp`). Helper sub-bundles and app-group
///    identifiers follow this pattern.
/// 3. **Shared-resource ancestor.** The candidate is a strict ancestor
///    of an installed bundle ID (`com.docker` → `com.docker.docker`).
///    Some apps register a shorter ancestor ID for shared resources.
///
/// All three relationships are treated the same way: don't surface the
/// candidate as orphaned.
nonisolated struct InstalledBundleFilter: CandidateFilter, Sendable {

    let name = "InstalledBundle"

    /// - Returns: `true` when the candidate is in any of the three
    ///   "installed family" relationships.
    nonisolated func excludes(_ candidate: OrphanCandidate) -> Bool {
        let installed = candidate.installed.bundleIDs
        let id = candidate.normalizedID

        if installed.contains(id) { return true }
        if installed.contains(where: { id.hasPrefix($0 + ".") }) { return true }
        if installed.contains(where: { $0.hasPrefix(id + ".") }) { return true }
        return false
    }
}
