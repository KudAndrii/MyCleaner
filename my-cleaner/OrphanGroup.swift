//
//  OrphanGroup.swift
//  my-cleaner
//

import Foundation

/// A cluster of orphaned items that all share the same bundle identifier
/// — i.e. files left behind by the same now-uninstalled app.
///
/// Items are grouped at this level (rather than surfaced individually) so
/// the user can opt in to "everything from `com.example.Foo`" in one
/// click, instead of ticking a dozen unrelated rows.
nonisolated struct OrphanGroup: Identifiable, Hashable, Sendable {

    /// `Identifiable` conformance — the bundle ID is unique per group.
    var id: String { bundleID }

    /// The reverse-DNS bundle identifier all items in this group are
    /// named after. For team-prefixed group containers, this is the full
    /// `<TeamID>.<Name>` string.
    let bundleID: String

    /// Every leftover entry attributed to this bundle ID. Already
    /// deduplicated by URL.
    let items: [RelatedItem]

    /// Sum of every item's `sizeBytes`. Surfaced in the group header so
    /// the user can see how much disk they'd recover.
    var totalSize: Int64 { items.map(\.sizeBytes).reduce(0, +) }

    /// `true` when the user has ticked the group's checkbox. Toggling
    /// applies to every contained item in one shot.
    var isSelected: Bool
}

/// The output of an orphan scan: every `OrphanGroup` MyCleaner found,
/// ordered largest-first.
nonisolated struct OrphanScanResult: Sendable {

    /// The discovered groups, sorted by `totalSize` descending.
    let groups: [OrphanGroup]

    /// Sum of every group's `totalSize`.
    var totalSize: Int64 { groups.flatMap(\.items).map(\.sizeBytes).reduce(0, +) }
}
