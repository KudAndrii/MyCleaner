//
//  DuplicateScanner.swift
//  my-cleaner
//
//  Duplicate-file detection pipeline.
//
//  Mirrors the find-then-filter shape of ``AppScanner`` and
//  ``OrphanScanner`` but the "filter" half is a content-identity
//  reduction rather than an attribution chain. The shape follows
//  the standard fast-dedup pipeline (fdupes, jdupes, rmlint):
//
//    1. **Enumerate** — walk the user-chosen scope folders, skipping
//       `.app` bundles, symlinks, zero-byte files, and iCloud stubs.
//       Bucket every survivor by `fileAllocatedSize`. Stored as plain
//       path strings so peak memory stays proportional to total
//       file-count × path-length, **not** to per-URL metadata caches.
//
//    2. **Inode dedup + singleton drop** — for each size bucket with
//       ≥ 2 entries, collapse hardlinked siblings via
//       `fileResourceIdentifierKey`. Discard any bucket with fewer
//       than 2 unique inodes after the collapse.
//
//    3. **Partial-hash prefilter** — for surviving candidates whose
//       file size exceeds ``partialHashSize``, hash only the first
//       4 KB and sub-group by that. Files with distinct prefixes
//       can't be duplicates, so we skip the full-content read for
//       the (typically dominant) majority of size collisions. 4 KB
//       matches what fdupes, jdupes, and czkawka use — it's the
//       APFS page size, so smaller reads still pay for a full page.
//
//    4. **Full hash** — for each partial-hash sub-group with ≥ 2
//       entries, stream SHA-256 of the entire file in 4 MB chunks
//       and regroup by full digest. Surface groups with ≥ 2 entries.
//
//  Progress is emitted through a throttled `@Sendable` callback so
//  the UI can show "scanned N files" during the walk and a
//  determinate "hashed N of M" bar during the hash pass.
//

import Foundation
import CryptoKit

/// Finds files with identical content across a user-chosen scope.
///
/// See the file header for the full enumerate → dedup → partial →
/// full pipeline.
enum DuplicateScanner {

    // MARK: - Configuration

    /// Hash-pass read size. Picked to keep memory pressure low on
    /// multi-gigabyte files while still being large enough that the
    /// per-chunk overhead doesn't dominate small files.
    nonisolated private static let chunkSize = 4 * 1024 * 1024

    /// Prefilter hash window. 4 KiB matches the APFS page / sector
    /// size — any smaller read still costs a full page off disk, and
    /// any larger read just amplifies the I/O without meaningfully
    /// improving discrimination for the typical home-folder workload
    /// (most same-size coincidences differ within the first KB). This
    /// is the same constant used by fdupes (`PARTIAL_MD5_SIZE`),
    /// jdupes (`PARTIAL_HASH_SIZE`), and czkawka's "prehash" stage.
    nonisolated private static let partialHashSize = 4 * 1024

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

    /// Emit a progress update at most this often within a tight
    /// loop. Tuned to ~8 Hz so SwiftUI sees smooth updates without
    /// the scanner thread spinning on the callback.
    nonisolated private static let progressEmitInterval: TimeInterval = 0.12

    // MARK: - Progress

    /// Coarse progress signal emitted by the scanner so the UI can
    /// show what phase it's in and roughly how far along it is.
    /// Throttled internally by the scanner to ~8 emissions / second.
    nonisolated enum Progress: Sendable, Equatable {
        /// Walking the scope; `filesSeen` grows monotonically.
        case enumerating(filesSeen: Int)

        /// Hashing same-size candidates; the UI can render a
        /// determinate bar from `filesHashed` / `totalToHash`. The
        /// total is locked in at the start of the hash pass and
        /// stays fixed for the rest of the run.
        case hashing(filesHashed: Int, totalToHash: Int)
    }

    // MARK: - Entry point

    /// Runs a full duplicate scan across the supplied scope.
    ///
    /// - Parameters:
    ///   - scope: One or more root URLs to walk. Typically the
    ///     ``DuplicateScopeFolder`` URLs the user opted into.
    ///   - progress: Optional callback for UI progress updates.
    ///     Invoked at most ~8 times per second from the scan task;
    ///     callers that need to touch the main actor should hop
    ///     themselves rather than block the scanner. Pass `nil`
    ///     (the default) when no UI is observing.
    /// - Returns: Every duplicate group with ≥ 2 distinct inodes,
    ///   sorted by `maximumRecoverableBytes` descending so the
    ///   biggest savings surface first.
    /// - Throws: `CancellationError` when the surrounding task is
    ///   cancelled. The check runs between every file and every
    ///   hash chunk, so cancellation is observable within a
    ///   fraction of a second even on multi-gigabyte inputs.
    nonisolated static func scan(
        scope: [URL],
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> [DuplicateGroup] {

        // ─── Pass 1: enumerate, bucket by allocated size ──────────
        //
        // Stored as `[Int64: [String]]` rather than `[Int64: [URL]]`
        // because URLs from `FileManager.enumerator(at:includingPropertiesForKeys:...)`
        // carry per-instance metadata caches that persist for the
        // lifetime of the URL value. Holding millions of cached URLs
        // through to the hash pass would explode peak memory. Path
        // strings have copy-on-write storage and stay slim.
        var sizeBuckets: [Int64: [String]] = [:]
        var filesSeen = 0
        var lastEmit = Date(timeIntervalSince1970: 0)

        for root in scope {
            try Task.checkCancellation()
            try enumerate(at: root) { path, size in
                try Task.checkCancellation()
                sizeBuckets[size, default: []].append(path)
                filesSeen += 1
                let now = Date()
                if now.timeIntervalSince(lastEmit) >= progressEmitInterval {
                    progress?(.enumerating(filesSeen: filesSeen))
                    lastEmit = now
                }
            }
        }
        progress?(.enumerating(filesSeen: filesSeen))

        // ─── Pass 2: inode dedup + singleton compaction ──────────
        //
        // Only buckets with 2+ entries can contain duplicates. Inode
        // collapse rolls hardlinked siblings into a single
        // representative; the bucket is dropped if fewer than 2
        // distinct inodes remain. This is where the working set
        // shrinks from "every file in scope" to "every candidate
        // worth hashing."
        struct Candidate {
            let size: Int64
            let paths: [String]
        }
        var candidates: [Candidate] = []
        var totalToHash = 0

        for (size, paths) in sizeBuckets where paths.count >= 2 {
            try Task.checkCancellation()
            let unique = dedupeByInode(paths: paths)
            guard unique.count >= 2 else { continue }
            candidates.append(Candidate(size: size, paths: unique))
            totalToHash += unique.count
        }
        // Drop the size buckets — we're done with them and they're
        // by far the heaviest in-memory structure.
        sizeBuckets.removeAll(keepingCapacity: false)

        // ─── Passes 3+4: partial-hash prefilter, then full hash ──
        var hashedCount = 0
        var groups: [DuplicateGroup] = []
        progress?(.hashing(filesHashed: 0, totalToHash: totalToHash))
        lastEmit = Date()

        for candidate in candidates {
            try Task.checkCancellation()

            // Sub-grouping after content comparison. Each entry is
            // `(fullHash, paths)` and gets emitted as a duplicate
            // group at the end.
            var verified: [(hash: String, paths: [String])] = []

            if candidate.size <= Int64(partialHashSize) {
                // Files small enough that the partial hash IS the
                // full hash. Skip the prefilter — one read pass is
                // enough.
                var byHash: [String: [String]] = [:]
                for path in candidate.paths {
                    try Task.checkCancellation()
                    guard let hash = hashFile(at: URL(fileURLWithPath: path)) else { continue }
                    byHash[hash, default: []].append(path)
                    hashedCount += 1
                    let now = Date()
                    if now.timeIntervalSince(lastEmit) >= progressEmitInterval {
                        progress?(.hashing(filesHashed: hashedCount, totalToHash: totalToHash))
                        lastEmit = now
                    }
                }
                for (hash, paths) in byHash where paths.count >= 2 {
                    verified.append((hash: hash, paths: paths))
                }
            } else {
                // Partial-hash prefilter. Files whose first 4 KB
                // differ can't be duplicates; the prefilter rules
                // them out without ever touching the rest of the
                // bytes — typically the majority of same-size
                // collisions in a user's home folder.
                var byPartial: [Data: [String]] = [:]
                for path in candidate.paths {
                    try Task.checkCancellation()
                    guard let prefix = partialHash(of: URL(fileURLWithPath: path)) else { continue }
                    byPartial[prefix, default: []].append(path)
                }

                // Account for files that the prefilter ruled out so
                // the UI's "hashed / total" bar can still reach 100%.
                let prefilterDrops = byPartial.values.reduce(0) { acc, ps in
                    acc + (ps.count < 2 ? ps.count : 0)
                }
                hashedCount += prefilterDrops

                for (_, partialPaths) in byPartial where partialPaths.count >= 2 {
                    try Task.checkCancellation()
                    var byHash: [String: [String]] = [:]
                    for path in partialPaths {
                        try Task.checkCancellation()
                        guard let hash = hashFile(at: URL(fileURLWithPath: path)) else { continue }
                        byHash[hash, default: []].append(path)
                        hashedCount += 1
                        let now = Date()
                        if now.timeIntervalSince(lastEmit) >= progressEmitInterval {
                            progress?(.hashing(filesHashed: hashedCount, totalToHash: totalToHash))
                            lastEmit = now
                        }
                    }
                    for (hash, paths) in byHash where paths.count >= 2 {
                        verified.append((hash: hash, paths: paths))
                    }
                }
            }

            for (hash, paths) in verified {
                let urls = paths.map { URL(fileURLWithPath: $0) }
                let copies = makeCopies(from: urls)
                let selected = applyAutoSelection(copies)
                groups.append(DuplicateGroup(
                    id: UUID(),
                    contentHash: hash,
                    sizePerCopy: candidate.size,
                    copies: selected
                ))
            }
        }
        progress?(.hashing(filesHashed: totalToHash, totalToHash: totalToHash))

        return groups.sorted { $0.maximumRecoverableBytes > $1.maximumRecoverableBytes }
    }

    // MARK: - Enumeration

    /// Walks one root, calling `yield(path, size)` for every
    /// eligible regular file.
    ///
    /// The enumerator is given a `includingPropertiesForKeys` hint
    /// so each yielded URL is pre-populated with the values we
    /// query; the yielded URL is then **discarded** after we read
    /// its path and size, so the cached metadata doesn't survive
    /// into ``scan``'s `sizeBuckets`. This is the key memory win
    /// over storing URLs throughout the pipeline.
    nonisolated static func enumerate(
        at root: URL,
        yield: (_ path: String, _ size: Int64) throws -> Void
    ) rethrows {
        let fm = FileManager.default
        // Pre-fetch hint — keeps each URL fast to query inside the
        // loop. The URLs aren't retained past this loop, so the
        // per-URL cache is freed as soon as iteration moves on.
        let prefetch: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .ubiquitousItemDownloadingStatusKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey
        ]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: prefetch,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return }

        let prefetchSet = Set(prefetch)
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: prefetchSet) else { continue }

            if values.isDirectory == true {
                if shouldSkipDirectory(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values.isSymbolicLink == true { continue }
            if values.isAliasFile == true { continue }
            if values.isRegularFile != true { continue }
            // iCloud stubs (.icloud placeholders) carry the
            // notDownloaded status — reading them would either fail
            // or trigger an unwanted download. Files in
            // `.downloaded` or `.current` state have real bytes on
            // disk and are fine to hash.
            if let status = values.ubiquitousItemDownloadingStatus,
               status == .notDownloaded {
                continue
            }

            let size: Int64
            if let total = values.totalFileAllocatedSize {
                size = Int64(total)
            } else if let alloc = values.fileAllocatedSize {
                size = Int64(alloc)
            } else {
                continue
            }
            guard size > 0 else { continue }

            try yield(url.path, size)
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

    // MARK: - Inode dedup

    /// Returns a representative path per unique on-disk file.
    ///
    /// Hardlinked siblings share a `fileResourceIdentifier`;
    /// surfacing every path would lie to the user — trashing one
    /// path leaves the underlying file in place via the other
    /// links. Falls back to keeping every path whose identifier
    /// we couldn't read.
    nonisolated static func dedupeByInode(paths: [String]) -> [String] {
        var byInode: [NSObject: String] = [:]
        var unknownInode: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if let any = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
               let key = any as? NSObject {
                if byInode[key] == nil { byInode[key] = path }
            } else {
                unknownInode.append(path)
            }
        }
        return Array(byInode.values) + unknownInode
    }

    // MARK: - Hashing

    /// Streams a file through SHA-256, returning the hex digest.
    ///
    /// Returns `nil` for files we couldn't open, which keeps a
    /// single unreadable file from aborting the rest of the scan.
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

    /// SHA-256 of just the first ``partialHashSize`` bytes of a
    /// file, returned as the raw digest so equal prefixes hash to
    /// the same `Data` value (no hex-string formatting on the hot
    /// path).
    ///
    /// This is the standard fast-dedup prefilter — files with
    /// distinct prefix digests can't be duplicates, so they get
    /// dropped before we ever touch the rest of their bytes. For a
    /// scope where most same-size collisions are coincidental
    /// (which is typical of a user's home folder), the prefilter
    /// turns a many-gigabyte hash pass into a many-megabyte one.
    nonisolated static func partialHash(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let chunk = try handle.read(upToCount: partialHashSize) ?? Data()
            var hasher = SHA256()
            hasher.update(data: chunk)
            return Data(hasher.finalize())
        } catch {
            return nil
        }
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
