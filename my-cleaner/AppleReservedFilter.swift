//
//  AppleReservedFilter.swift
//  my-cleaner
//

import Foundation

/// Rejects every candidate in Apple's reserved bundle-ID namespace.
///
/// `com.apple.*` and bare `apple.*` identifiers belong to OS-supplied
/// containers and stubs (Cloud Documents, MobileSafari placeholders,
/// system preference panes). Even when their on-disk entries have zero
/// bytes and look orphaned, surfacing them is pure UI noise — the user
/// can't and shouldn't remove them.
///
/// This rule is the cheapest in the chain and runs first.
nonisolated struct AppleReservedFilter: CandidateFilter, Sendable {

    let name = "AppleReserved"

    /// - Returns: `true` when `candidate.bundleID` is in Apple's
    ///   reserved namespace.
    nonisolated func excludes(_ candidate: OrphanCandidate) -> Bool {
        BundleIdentifier.isAppleReserved(candidate.bundleID)
    }
}
