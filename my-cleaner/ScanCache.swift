//
//  ScanCache.swift
//  my-cleaner
//
//  Cross-session snapshot of the most recent scan per tool, so the
//  home screen can surface "9.2 GB · 14 places"-style stats without
//  re-scanning. Each per-tool snapshot stores enough information to
//  re-validate the cache against the live filesystem (drop entries
//  the user has since trashed) and recompute the displayed totals.
//

import Foundation

/// Top-level cache snapshot persisted by ``ScanCacheStore``.
///
/// One field per home-screen tool. Each field is `nil` until the user
/// has run that tool at least once.
nonisolated struct ScanCache: Codable, Sendable, Equatable {
    var orphans: OrphansSnapshot?
    var largeFiles: LargeFilesSnapshot?
    var oversizedCaches: OversizedCachesSnapshot?
    var duplicates: DuplicatesSnapshot?

    static let empty = ScanCache()
}

/// Snapshot of the last orphan scan.
nonisolated struct OrphansSnapshot: Codable, Sendable, Equatable {
    var scannedAt: Date
    var groups: [Group]

    struct Group: Codable, Sendable, Equatable {
        var bundleID: String
        var items: [Item]
    }

    struct Item: Codable, Sendable, Equatable {
        var path: String
        var sizeBytes: Int64
    }
}

/// Snapshot of the last large-file scan.
nonisolated struct LargeFilesSnapshot: Codable, Sendable, Equatable {
    var scannedAt: Date
    var items: [Item]

    struct Item: Codable, Sendable, Equatable {
        var path: String
        var sizeBytes: Int64
    }
}

/// Snapshot of the last oversized-caches scan.
nonisolated struct OversizedCachesSnapshot: Codable, Sendable, Equatable {
    var scannedAt: Date
    var groups: [Group]

    struct Group: Codable, Sendable, Equatable {
        var id: String
        var entries: [Entry]
    }

    struct Entry: Codable, Sendable, Equatable {
        var path: String
        var sizeBytes: Int64
    }
}

/// Snapshot of the last duplicate scan.
///
/// `paths` is the raw list of every copy in the group. The
/// "recoverable" count and bytes are derived as `(paths.count - 1) ×
/// sizePerCopy` on the assumption the user keeps one copy.
nonisolated struct DuplicatesSnapshot: Codable, Sendable, Equatable {
    var scannedAt: Date
    var groups: [Group]

    struct Group: Codable, Sendable, Equatable {
        var sizePerCopy: Int64
        var paths: [String]
    }
}

/// One home-screen tile's headline stat.
nonisolated struct HomeStat: Equatable, Sendable {
    let totalBytes: Int64
    let count: Int
}

extension ScanCache {
    /// `nil` when the orphan scan has never been run (or every group
    /// has been pruned).
    var orphanStat: HomeStat? {
        guard let snapshot = orphans, !snapshot.groups.isEmpty else { return nil }
        let bytes = snapshot.groups
            .flatMap(\.items)
            .map(\.sizeBytes)
            .reduce(0, +)
        return HomeStat(totalBytes: bytes, count: snapshot.groups.count)
    }

    var largeFileStat: HomeStat? {
        guard let snapshot = largeFiles, !snapshot.items.isEmpty else { return nil }
        let bytes = snapshot.items.map(\.sizeBytes).reduce(0, +)
        return HomeStat(totalBytes: bytes, count: snapshot.items.count)
    }

    var oversizedCacheStat: HomeStat? {
        guard let snapshot = oversizedCaches, !snapshot.groups.isEmpty else { return nil }
        let bytes = snapshot.groups
            .flatMap(\.entries)
            .map(\.sizeBytes)
            .reduce(0, +)
        return HomeStat(totalBytes: bytes, count: snapshot.groups.count)
    }

    /// Duplicates collapse on a "keep one copy per group" assumption —
    /// reportable count and bytes are everything beyond the first
    /// copy of each group.
    var duplicateStat: HomeStat? {
        guard let snapshot = duplicates, !snapshot.groups.isEmpty else { return nil }
        var bytes: Int64 = 0
        var dupes = 0
        for group in snapshot.groups where group.paths.count > 1 {
            let extras = group.paths.count - 1
            bytes += group.sizePerCopy * Int64(extras)
            dupes += extras
        }
        guard dupes > 0 else { return nil }
        return HomeStat(totalBytes: bytes, count: dupes)
    }
}
