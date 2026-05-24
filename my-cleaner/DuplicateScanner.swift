//
//  DuplicateScanner.swift
//  my-cleaner
//
//  Duplicate-file detection pipeline.
//
//  Mirrors the find-then-filter shape of ``AppScanner`` and
//  ``OrphanScanner`` but the "filter" half is a content-identity
//  reduction rather than an attribution chain:
//
//    1. **Enumerate** — walk the user-chosen scope folders, skipping
//       `.app` bundles, symlinks, zero-byte files, and iCloud stubs.
//       Group every survivor by `fileAllocatedSize`.
//
//    2. **Hash** — for each size bucket with two or more distinct
//       inodes, stream SHA-256 of every file in 4 MB chunks. Group by
//       `(size, hash)` and surface groups with two or more entries.
//
//  Hardlinks are collapsed at the size-bucket stage via
//  `fileResourceIdentifierKey`: files sharing an inode are the same
//  on-disk file and never get surfaced as duplicates of each other.
//

import Foundation
import CryptoKit

/// Finds files with identical content across a user-chosen scope.
///
/// See the file header for the two-pass enumerate-then-hash pipeline.
enum DuplicateScanner {

    // MARK: - Configuration

    /// Hash-pass read size. Picked to keep memory pressure low on
    /// multi-gigabyte files while still being large enough that the
    /// per-chunk overhead doesn't dominate small files.
    nonisolated private static let chunkSize = 4 * 1024 * 1024

    /// Directory names the walk never descends into.
    ///
    /// `~/Library` is excluded explicitly because it's owned by the
    /// per-app and orphan flows; duplicate detection there would
    /// surface every framework, cache fragment, and preference plist.
    nonisolated private static let excludedDirectoryNames: Set<String> = ["Library"]

    /// Absolute path prefixes the walk never descends into.
    ///
    /// System volumes hold root-owned binaries the user can't safely
    /// touch even when the default scope doesn't include them.
    ///
    /// Note: `URL.standardizedFileURL` collapses `/private/var`,
    /// `/private/etc`, `/private/tmp` to their bare `/var`, `/etc`,
    /// `/tmp` forms on macOS — so callers asking about those specific
    /// paths land outside this prefix list. `/var/folders/...` (the
    /// system temp dir) is deliberately not excluded here so that
    /// scoping a scan to a temp directory still works.
    nonisolated private static let excludedPathPrefixes: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/private", "/dev", "/Volumes"
    ]

    // MARK: - Entry point

    /// Runs a full duplicate scan across the supplied scope.
    ///
    /// - Parameter scope: One or more root URLs to walk. Typically the
    ///   ``DuplicateScopeFolder`` URLs the user opted into.
    /// - Returns: Every duplicate group with ≥ 2 distinct inodes,
    ///   sorted by `wastedBytes` descending so the biggest savings
    ///   surface first.
    /// - Throws: `CancellationError` when the surrounding task is
    ///   cancelled. The check runs between every file and every hash,
    ///   so cancellation is observable within a fraction of a second
    ///   even on multi-gigabyte inputs.
    nonisolated static func scan(scope: [URL]) async throws -> [DuplicateGroup] {
        var sizeBuckets: [Int64: [URL]] = [:]
        for root in scope {
            try Task.checkCancellation()
            enumerate(at: root, into: &sizeBuckets)
        }

        var groups: [DuplicateGroup] = []

        for (size, urls) in sizeBuckets where urls.count >= 2 {
            try Task.checkCancellation()

            let uniqueByInode = dedupeByInode(urls)
            guard uniqueByInode.count >= 2 else { continue }

            var byHash: [String: [URL]] = [:]
            for url in uniqueByInode {
                try Task.checkCancellation()
                guard let hash = hashFile(at: url) else { continue }
                byHash[hash, default: []].append(url)
            }

            for (hash, dupURLs) in byHash where dupURLs.count >= 2 {
                let copies = makeCopies(from: dupURLs)
                let selected = applyAutoSelection(copies)
                groups.append(DuplicateGroup(
                    id: UUID(),
                    contentHash: hash,
                    sizePerCopy: size,
                    copies: selected
                ))
            }
        }

        return groups.sorted { $0.maximumRecoverableBytes > $1.maximumRecoverableBytes }
    }

    // MARK: - Enumeration

    /// Recursively walks `root`, dropping every survivor into the
    /// correct size bucket.
    ///
    /// Uses `FileManager.enumerator` with manual descent control so
    /// we can skip `.app` bundles, hidden folders, and the excluded
    /// path list without recursing into them.
    nonisolated static func enumerate(at root: URL, into sizeBuckets: inout [Int64: [URL]]) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .isPackageKey
        ]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return }

        for case let url as URL in enumerator {
            // Skip excluded directories without descending into them.
            // `.skipsPackageDescendants` already covers `.app` etc., but
            // not Library, which isn't a package.
            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
               values.isDirectory == true {
                if shouldSkipDirectory(url) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard isEligibleFile(at: url) else { continue }
            guard let size = allocatedSize(for: url), size > 0 else { continue }

            sizeBuckets[size, default: []].append(url)
        }
    }

    /// `true` for directories we should never descend into.
    nonisolated static func shouldSkipDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if excludedDirectoryNames.contains(name) { return true }
        let path = url.standardizedFileURL.path
        for prefix in excludedPathPrefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return true
        }
        return false
    }

    /// `true` for files that should participate in duplicate detection.
    ///
    /// Symlinks point at originals — surfacing them would offer to
    /// delete the link without recovering any space. iCloud stubs
    /// aren't readable until downloaded, so hashing them would either
    /// fail or trigger an unwanted download.
    nonisolated static func isEligibleFile(at url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        if values.isSymbolicLink == true { return false }
        if values.isAliasFile == true { return false }
        if values.isRegularFile != true { return false }
        // iCloud stubs (.icloud placeholders) carry the notDownloaded
        // status — reading them would either fail or trigger an
        // unwanted download. Files in `.downloaded` or `.current`
        // state have real bytes on disk and are fine to hash.
        if let status = values.ubiquitousItemDownloadingStatus,
           status == .notDownloaded {
            return false
        }
        return true
    }

    /// Returns the file's allocated size in bytes, preferring the
    /// `totalFileAllocatedSize` key (covers sparse files) and falling
    /// back to `fileAllocatedSize`. Returns `nil` when neither key
    /// is readable so the caller can skip the entry.
    nonisolated static func allocatedSize(for url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let total = values.totalFileAllocatedSize { return Int64(total) }
        if let alloc = values.fileAllocatedSize { return Int64(alloc) }
        return nil
    }

    // MARK: - Inode dedup

    /// Returns a representative URL per unique on-disk file.
    ///
    /// Hardlinked siblings share a `fileResourceIdentifier`; surfacing
    /// every URL would lie to the user — trashing one path leaves the
    /// underlying file in place via the other links. Falls back to
    /// keeping every URL whose identifier we couldn't read.
    nonisolated static func dedupeByInode(_ urls: [URL]) -> [URL] {
        var byInode: [NSObject: URL] = [:]
        var unknownInode: [URL] = []
        for url in urls {
            if let any = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
               let key = any as? NSObject {
                if byInode[key] == nil { byInode[key] = url }
            } else {
                unknownInode.append(url)
            }
        }
        return Array(byInode.values) + unknownInode
    }

    // MARK: - Hashing

    /// Streams a file through SHA-256, returning the hex digest.
    ///
    /// Returns `nil` for files we couldn't open, which keeps a single
    /// unreadable file from aborting the rest of the scan.
    nonisolated static func hashFile(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                return nil
            }
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Copy construction

    /// Builds ``DuplicateCopy`` rows from a set of duplicate URLs.
    /// Every copy is created selected; ``applyAutoSelection(_:)``
    /// then flips the chosen keeper off.
    nonisolated static func makeCopies(from urls: [URL]) -> [DuplicateCopy] {
        urls.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)
            return DuplicateCopy(
                id: UUID(),
                url: url,
                modificationDate: date,
                isSelectedForDeletion: true
            )
        }
    }

    /// Applies the keep-newest / deepest-path heuristic from the
    /// feature spec. The chosen copy gets `isSelectedForDeletion =
    /// false`; every other copy is left selected.
    ///
    /// Tie-breakers:
    ///   1. Most recent `modificationDate` (treating `nil` as oldest).
    ///   2. Deepest path (`pathComponents.count`) — backups tend to
    ///      live at the root of `~/Downloads`, while the "real" copy
    ///      is often filed away under a project folder.
    ///   3. Lexicographic `url.path` for total determinism.
    nonisolated static func applyAutoSelection(_ copies: [DuplicateCopy]) -> [DuplicateCopy] {
        guard !copies.isEmpty else { return [] }
        let keeperIndex = copies.indices.max { a, b in
            let lhs = copies[a]
            let rhs = copies[b]
            let lhsDate = lhs.modificationDate ?? .distantPast
            let rhsDate = rhs.modificationDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            let lhsDepth = lhs.url.pathComponents.count
            let rhsDepth = rhs.url.pathComponents.count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.url.path > rhs.url.path
        } ?? copies.startIndex

        return copies.enumerated().map { idx, copy in
            var mutable = copy
            mutable.isSelectedForDeletion = idx != keeperIndex
            return mutable
        }
    }
}
