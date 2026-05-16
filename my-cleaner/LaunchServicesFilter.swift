//
//  LaunchServicesFilter.swift
//  my-cleaner
//

import Foundation
import AppKit

/// Rejects candidates whose bundle ID Launch Services can still resolve
/// to a real `.app` on disk.
///
/// This is the **backstop** check — it runs last because it's the most
/// expensive (a synchronous Launch Services round-trip per candidate)
/// and the least precise (LS remembers bundles it has merely seen,
/// including mounted DMGs and quarantined downloads).
///
/// It catches apps the directory walk in `InstalledAppsIndex` can't see:
/// custom install locations under `/opt`, deeply nested vendor folders,
/// installs on external volumes the user still has mounted. For a
/// candidate that has already survived every cheaper rule, an LS hit is
/// strong evidence the app is actually installed somewhere we just
/// didn't look — better to under-report orphans than to flag a real app.
///
/// The match additionally requires the file at the resolved URL to
/// exist, so stale LS entries pointing at deleted bundles don't reject
/// real orphans.
nonisolated struct LaunchServicesFilter: CandidateFilter, Sendable {

    let name = "LaunchServices"

    /// - Returns: `true` when Launch Services resolves the candidate's
    ///   bundle ID to a `.app` URL whose contents still exist on disk.
    nonisolated func excludes(_ candidate: OrphanCandidate) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate.bundleID) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
