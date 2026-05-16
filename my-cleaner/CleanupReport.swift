//
//  CleanupReport.swift
//  my-cleaner
//

import Foundation

/// The outcome of a cleanup run, reported back to the UI for the "done"
/// screen.
///
/// `trashedNormally` counts items the user's session could move on its
/// own; `trashedWithElevation` counts items that required the admin
/// password fallback. `failures` is the residue — items macOS refused
/// even after elevation (usually a missing TCC grant).
nonisolated struct CleanupReport: Sendable, Equatable, Hashable {

    /// Number of items successfully moved using `FileManager.trashItem`.
    let trashedNormally: Int

    /// Number of items moved by the elevated AppleScript fallback after
    /// the unprivileged pass refused them.
    let trashedWithElevation: Int

    /// Items macOS refused to trash even after the elevated pass.
    let failures: [Failure]

    /// Total items removed to the Trash (both passes combined).
    var trashed: Int { trashedNormally + trashedWithElevation }

    /// A single item that could not be moved to the Trash, together with
    /// the platform-localised reason string.
    nonisolated struct Failure: Sendable, Equatable, Hashable, Identifiable {

        /// `Identifiable` conformance — the URL of the refused item.
        var id: URL { url }

        /// File URL of the item that couldn't be removed.
        let url: URL

        /// Human-readable error string, suitable for surfacing in the
        /// failure list. Sourced from `FileManager` or the AppleScript
        /// error info dictionary.
        let message: String
    }
}
