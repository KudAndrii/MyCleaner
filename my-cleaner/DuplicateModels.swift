//
//  DuplicateModels.swift
//  my-cleaner
//
//  Data model for the duplicate-file detection flow.
//
//  Mirrors the shape of the per-app and orphan result types: one group
//  type that owns multiple item rows, with selection toggled per item.
//  The duplicate flow differs in two ways:
//
//    1. Identity is `(size, SHA-256)`, not a bundle ID, so groups are
//       keyed by an opaque UUID and carry the content hash explicitly.
//    2. Selection is **per-copy**, not per-group — the whole point is
//       to pick which copies to keep and which to trash. At least one
//       copy is always kept per group (enforced by ``CleanerModel``).
//

import Foundation

/// A set of files with identical content, surfaced together for review.
///
/// `wastedBytes` is what the user recovers if every selected copy is
/// trashed — equal to `sizePerCopy × (copies - 1)` when only one copy
/// is kept, scaling down as more copies are deselected.
nonisolated struct DuplicateGroup: Identifiable, Sendable, Hashable {
    /// Stable per-scan identity. Regenerated on each scan because the
    /// underlying file set may have changed.
    let id: UUID

    /// SHA-256 of the file content, hex-encoded. Same for every copy
    /// in the group by construction.
    let contentHash: String

    /// Allocated size of any single copy, in bytes. Files in the same
    /// group must have identical size by hash precondition.
    let sizePerCopy: Int64

    /// Every copy attributed to this content. At least two by
    /// construction — the scanner drops singleton groups.
    var copies: [DuplicateCopy]

    /// Bytes the user would recover by trashing every currently
    /// selected copy. Returns `0` when nothing is selected.
    var wastedBytes: Int64 {
        let selected = copies.lazy.filter(\.isSelectedForDeletion).count
        return sizePerCopy * Int64(selected)
    }

    /// Bytes the user could recover at most — every copy but one
    /// trashed. Independent of the current selection.
    var maximumRecoverableBytes: Int64 {
        sizePerCopy * Int64(max(0, copies.count - 1))
    }
}

/// A single on-disk copy inside a ``DuplicateGroup``.
nonisolated struct DuplicateCopy: Identifiable, Sendable, Hashable {
    /// Stable per-scan identity.
    let id: UUID

    /// On-disk URL of the copy.
    let url: URL

    /// Modification date as reported by the filesystem, when readable.
    /// Used by the auto-selection heuristic (keep newest) and surfaced
    /// in the UI to help the user reason about which copy to keep.
    let modificationDate: Date?

    /// Whether the user has currently selected this copy for trashing.
    ///
    /// The scanner pre-selects every copy except the auto-chosen
    /// keeper; the UI flips individual entries via
    /// ``CleanerModel/toggleDuplicateCopy(groupID:copyID:)``, which
    /// refuses to deselect the last kept copy.
    var isSelectedForDeletion: Bool
}

/// User-configurable scan scope.
///
/// Each case maps to one of the default folders listed in the feature
/// spec. Stored as `CaseIterable` so the options sheet can render
/// every choice with a single `ForEach`.
nonisolated enum DuplicateScopeFolder: String, CaseIterable, Identifiable, Sendable {
    case downloads
    case documents
    case desktop
    case pictures
    case movies
    case music

    var id: String { rawValue }

    /// Human-readable label shown in the options sheet.
    var title: String {
        switch self {
        case .downloads: "Downloads"
        case .documents: "Documents"
        case .desktop: "Desktop"
        case .pictures: "Pictures"
        case .movies: "Movies"
        case .music: "Music"
        }
    }

    /// SF Symbol used in the options sheet next to the title.
    var symbol: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .documents: "doc.fill"
        case .desktop: "menubar.dock.rectangle"
        case .pictures: "photo.fill"
        case .movies: "film.fill"
        case .music: "music.note"
        }
    }

    /// Absolute URL of the folder under the current user's home directory.
    var url: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(rawValue.capitalized, isDirectory: true)
    }
}

/// One step in the duplicate scan, surfaced on the scanning screen
/// as a structural progress list (one entry per selected scope
/// folder + a "Comparing content" entry for the hash pass).
///
/// Same shape as `LargeFileScanPhase` / `CacheScanPhase` so the
/// scanning view code can lean on the same render pattern.
nonisolated struct DuplicateScanPhase: Identifiable, Hashable, Sendable {
    /// Stable identifier used by the scanner / model handshake.
    /// Folder phases use the URL path; the hash phase uses
    /// ``DuplicateScanner/hashPhaseID``.
    let id: String

    /// Human-readable label shown in the scanning view.
    let displayName: String

    /// Current execution status.
    var status: Status

    /// Per-phase counter — files visited for folder phases, files
    /// hashed for the hash phase. `0` while pending.
    var counter: Int = 0

    /// For the hash phase only: total candidates to hash. `0` for
    /// folder phases.
    var counterTotal: Int = 0

    enum Status: Sendable, Hashable {
        case pending
        case inProgress
        case completed
    }
}
