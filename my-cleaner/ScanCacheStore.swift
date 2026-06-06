//
//  ScanCacheStore.swift
//  my-cleaner
//
//  Load / save / prune the persisted ``ScanCache``.
//
//  Stored as JSON in `~/Library/Application Support/MyCleaner/scan-cache.json`
//  so it survives relaunches and is trivially inspectable. Prune is
//  deliberately filesystem-aware: it drops cached entries whose path
//  no longer exists on disk, then collapses empty groups, so the
//  home-screen tiles never report stale totals after the user has
//  emptied items via the Trash.
//

import Foundation

nonisolated enum ScanCacheStore {

    /// Where the JSON cache lives on disk. Pure path lookup — does not
    /// create the directory; ``save(_:)`` does that on demand.
    nonisolated static var fileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MyCleaner", isDirectory: true)
            .appendingPathComponent("scan-cache.json", isDirectory: false)
    }

    nonisolated static func load() -> ScanCache {
        load(from: fileURL)
    }

    nonisolated static func save(_ cache: ScanCache) {
        save(cache, to: fileURL)
    }

    // MARK: - Test-friendly variants

    nonisolated static func load(from url: URL) -> ScanCache {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return (try? JSONDecoder().decode(ScanCache.self, from: data)) ?? .empty
    }

    nonisolated static func save(_ cache: ScanCache, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Pruning

    /// Filesystem existence predicate. Pulled out so tests can stub.
    typealias Exists = (String) -> Bool

    nonisolated static let defaultExists: Exists = {
        FileManager.default.fileExists(atPath: $0)
    }

    /// Drops cached entries whose path no longer exists on disk and
    /// collapses any group that empties out. Returns the pruned cache;
    /// the result equals the input when nothing changed (so callers
    /// can skip a write).
    ///
    /// Snapshots whose groups all end up empty are **kept** (just with
    /// empty contents) so the home insight card can still distinguish
    /// "scanned, nothing left" from "never scanned" — both states are
    /// surfaced to the user with different copy.
    nonisolated static func validate(
        _ cache: ScanCache,
        exists: Exists = defaultExists
    ) -> ScanCache {
        var pruned = cache

        if var snapshot = pruned.orphans {
            snapshot.groups = snapshot.groups.compactMap { group in
                var g = group
                g.items.removeAll { !exists($0.path) }
                return g.items.isEmpty ? nil : g
            }
            pruned.orphans = snapshot
        }

        if var snapshot = pruned.largeFiles {
            snapshot.items.removeAll { !exists($0.path) }
            pruned.largeFiles = snapshot
        }

        if var snapshot = pruned.oversizedCaches {
            snapshot.groups = snapshot.groups.compactMap { group in
                var g = group
                g.entries.removeAll { !exists($0.path) }
                return g.entries.isEmpty ? nil : g
            }
            pruned.oversizedCaches = snapshot
        }

        if var snapshot = pruned.duplicates {
            snapshot.groups = snapshot.groups.compactMap { group in
                var g = group
                g.paths.removeAll { !exists($0) }
                // A duplicate group below 2 surviving copies isn't a
                // duplicate anymore — drop it.
                return g.paths.count >= 2 ? g : nil
            }
            pruned.duplicates = snapshot
        }

        return pruned
    }
}
