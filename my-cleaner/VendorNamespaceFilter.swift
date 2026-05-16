//
//  VendorNamespaceFilter.swift
//  my-cleaner
//

import Foundation

/// Rejects candidates whose first two reverse-DNS segments match an
/// installed app's vendor namespace.
///
/// This is the rule that keeps siblings from the same vendor out of the
/// results. Without it, `com.viber.ViberPC` would surface as orphaned
/// when only `com.viber.osx` is installed; `net.whatsapp.family` would
/// surface when only `net.whatsapp.WhatsApp` is installed. In practice
/// every one of those siblings is a different vehicle for the same app
/// (`Viber` is registered under multiple IDs across versions), and
/// flagging them as orphans is almost always a false positive.
///
/// **Cost.** A genuinely uninstalled sibling whose vendor still ships
/// another app on this Mac (e.g. an old Microsoft product container)
/// won't be surfaced. Accepted recall trade-off — destructive operations
/// should err high on precision.
nonisolated struct VendorNamespaceFilter: CandidateFilter, Sendable {

    let name = "VendorNamespace"

    /// - Returns: `true` when the candidate's vendor namespace matches
    ///   that of any installed app.
    nonisolated func excludes(_ candidate: OrphanCandidate) -> Bool {
        guard let vendor = BundleIdentifier.vendorNamespace(of: candidate.normalizedID) else {
            return false
        }
        return candidate.installed.vendorNamespaces.contains(vendor)
    }
}
