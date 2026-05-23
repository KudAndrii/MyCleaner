//
//  LargeFileScanner.swift
//  my-cleaner
//
//  Large-file ranking pipeline.
//
//  Unlike ``AppScanner`` and ``OrphanScanner``, this scanner doesn't
//  attempt to attribute files to any app — it's a pure size-ranked
//  enumeration of the user's home directory. Two complementary
//  sources feed the result list:
//
//    1. **Spotlight** — `kMDItemFSSize > N` scoped to `$HOME`. Fast,
//       breadth-first, sub-second even on heavily populated machines.
//
//    2. **Targeted enumeration** — `FileManager` walks a curated list
//       of well-known large-file nests (simulator runtimes, Docker,
//       VM folders, `~/Downloads`). Catches paths Spotlight may not
//       index or may report at the wrong granularity (e.g. a bundle
//       whose container size beats its individual files).
//
//  Each surviving URL is sized via ``AppScanner/sizeOfItem(at:isDirectory:)``,
//  classified into a ``LargeFileCategory`` by extension + path
//  heuristic, and ranked by size descending.
//

import Foundation

/// Enumerates the user's home directory for files that are individually
/// large enough to be worth reviewing for one-click cleanup.
///
/// See the file header for the two-source find / classify pipeline.
enum LargeFileScanner {

    // MARK: - Tuning

    /// Default minimum entry size — 100 MB. Surfaces typical culprits
    /// (VM disks, video exports, large installers) while keeping the
    /// total result count small enough to render comfortably.
    nonisolated static let defaultMinimumBytes: Int64 = 100 * 1_024 * 1_024

    /// Hard cap on the number of returned entries. Even a power user's
    /// home directory rarely produces this many candidates above the
    /// default minimum.
    nonisolated static let defaultLimit: Int = 200

    // MARK: - Entry point

    /// Runs a full large-file scan.
    ///
    /// - Parameters:
    ///   - minimumBytes: Smallest size to include. Used as the
    ///     `kMDItemFSSize` floor for Spotlight and as a post-filter on
    ///     targeted-enumeration hits.
    ///   - limit: Maximum number of entries to return; the rest are
    ///     dropped after the result list is sorted by size.
    nonisolated static func scan(
        minimumBytes: Int64 = defaultMinimumBytes,
        limit: Int = defaultLimit
    ) -> [LargeFileEntry] {
        var found: [URL: LargeFileEntry] = [:]

        let spotlightURLs = spotlightHits(minimumBytes: minimumBytes)
        for url in spotlightURLs {
            insert(url, minimumBytes: minimumBytes, into: &found)
        }

        for nest in targetedNests() {
            for url in enumerateNest(nest, minimumBytes: minimumBytes) {
                insert(url, minimumBytes: minimumBytes, into: &found)
            }
        }

        let sorted = found.values.sorted { $0.sizeBytes > $1.sizeBytes }
        if sorted.count <= limit { return sorted }
        return Array(sorted.prefix(limit))
    }

    // MARK: - Spotlight

    /// Spotlight pass — every file Spotlight has indexed under the
    /// user's home directory whose `kMDItemFSSize` exceeds the
    /// threshold.
    nonisolated static func spotlightHits(minimumBytes: Int64) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let predicate = sizePredicate(minimumBytes: minimumBytes)
        return SpotlightSearch.find(predicate: predicate, scopes: [home])
    }

    /// Builds the `mdfind` predicate string used by ``spotlightHits(minimumBytes:)``.
    ///
    /// Surfaced as a static so the test suite can verify the byte
    /// threshold reaches Spotlight unchanged.
    nonisolated static func sizePredicate(minimumBytes: Int64) -> String {
        "kMDItemFSSize > \(minimumBytes)"
    }

    // MARK: - Targeted enumeration

    /// Well-known nests where the directory walk should top up
    /// Spotlight's findings.
    ///
    /// Some of these are bundle-style directories whose total size
    /// matters more than any individual file inside (`.fcpbundle`,
    /// `.simruntime`); Spotlight reports them as folders without an
    /// `FSSize`, so the directory walk is what surfaces them.
    private nonisolated static func targetedNests() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Developer/CoreSimulator", isDirectory: true),
            home.appendingPathComponent("Library/Containers/com.docker.docker", isDirectory: true),
            home.appendingPathComponent("Movies", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Virtual Machines.localized", isDirectory: true),
            home.appendingPathComponent("Parallels", isDirectory: true),
        ]
    }

    /// Enumerates a nest and emits every URL that looks like a
    /// large-file candidate.
    ///
    /// Bundle-style directories (`.simruntime`, `.fcpbundle`,
    /// `.vmwarevm`, `.sparseimage`, `.sparsebundle`, `.parallels`) are
    /// emitted as a single URL without descending into them — their
    /// content lives behind a package extension and should be sized
    /// and trashed as a unit.
    private nonisolated static func enumerateNest(
        _ nest: URL,
        minimumBytes: Int64
    ) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: nest.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        var results: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = fm.enumerator(
            at: nest,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        for case let url as URL in enumerator {
            let std = url.standardizedFileURL
            if isPackageBundleExtension(std.pathExtension) {
                enumerator.skipDescendants()
                results.append(std)
                continue
            }
            let entryIsDir = (try? std.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if entryIsDir { continue }
            results.append(std)
        }
        return results
    }

    /// `true` for package-style extensions whose total directory size
    /// is more meaningful than any single file inside.
    nonisolated static func isPackageBundleExtension(_ ext: String) -> Bool {
        switch ext.lowercased() {
        case "simruntime", "fcpbundle", "vmwarevm", "parallels", "pvm",
             "sparseimage", "sparsebundle", "utm", "ova", "lrlibrary",
             "photoslibrary", "tvlibrary":
            return true
        default:
            return false
        }
    }

    // MARK: - Per-URL insertion

    /// Validates a URL, sizes it, classifies it, and inserts it into
    /// the dedupe map keyed by standardized URL.
    ///
    /// Standardizing the URL first ensures the Spotlight and walk
    /// passes agree on a single key even when the system serves up
    /// `~/` versus `/Users/<me>/` for the same path.
    private nonisolated static func insert(
        _ rawURL: URL,
        minimumBytes: Int64,
        into found: inout [URL: LargeFileEntry]
    ) {
        let url = rawURL.standardizedFileURL
        if found[url] != nil { return }
        if shouldExclude(url) { return }

        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let size = AppScanner.sizeOfItem(at: url, isDirectory: isDir)
        if size < minimumBytes { return }

        let category = classify(url: url)
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let display = displayName(for: url, category: category)

        found[url] = LargeFileEntry(
            url: url,
            displayName: display,
            sizeBytes: size,
            isDirectory: isDir,
            category: category,
            modificationDate: modDate
        )
    }

    // MARK: - Exclusions

    /// `true` if `url` shouldn't appear in the result list regardless
    /// of size.
    ///
    /// Excludes:
    ///   - `.app` bundles (the per-app removal flow owns those)
    ///   - Time Machine snapshots & `.MobileBackups`
    ///   - External volumes mounted under `/Volumes`
    ///   - macOS index / revision metadata directories
    ///   - The user's own Trash
    nonisolated static func shouldExclude(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if url.pathExtension.lowercased() == "app" { return true }
        if path.hasPrefix("/Volumes/") { return true }
        if path.contains("/.MobileBackups") { return true }
        if path.contains("/Backups.backupdb/") { return true }
        if path.contains("/.Spotlight-") { return true }
        if path.contains("/.DocumentRevisions-") { return true }
        if path.contains("/.fseventsd") { return true }
        if path.contains("/.Trash/") || path.hasSuffix("/.Trash") { return true }
        return false
    }

    // MARK: - Classification

    /// Buckets a URL into a ``LargeFileCategory`` from extension and
    /// path heuristics.
    ///
    /// Order matters: simulator runtimes are checked before the
    /// generic developer-cache rule, and developer-cache paths are
    /// checked before the extension-based buckets so that, e.g., a
    /// `.dmg` cached inside `~/Library/Caches/` is surfaced as a
    /// developer cache rather than a top-level disk image to delete.
    nonisolated static func classify(url: URL) -> LargeFileCategory {
        let ext = url.pathExtension.lowercased()
        let path = url.standardizedFileURL.path

        if ext == "simruntime" || path.contains("/Library/Developer/CoreSimulator/") {
            return .simulatorRuntime
        }

        if path.contains("/Library/Developer/Xcode/") ||
            path.contains("/Library/Containers/com.docker.docker/") ||
            path.contains("/Library/Caches/") {
            return .developerCache
        }

        switch ext {
        case "vmwarevm", "parallels", "vmdk", "vbox", "qcow2", "qcow",
             "utm", "vdi", "ova", "ovf", "pvm", "hdd":
            return .virtualMachine
        case "dmg", "iso", "sparseimage", "sparsebundle", "img", "cdr":
            return .diskImage
        case "mov", "mp4", "mkv", "avi", "m4v", "mpg", "mpeg",
             "wmv", "flv", "webm", "fcpbundle":
            return .video
        case "zip", "tar", "gz", "bz2", "7z", "rar", "tgz", "xz", "lzma":
            return .archive
        default:
            return .other
        }
    }

    // MARK: - Display name

    /// Human-readable label shown in the results list.
    ///
    /// For simulator runtimes, prefers the `.simruntime` bundle's
    /// `CFBundleDisplayName` / `CFBundleName` so the user sees
    /// "iOS 18.0 Simulator Runtime" instead of a raw UUID path.
    /// Falls back to the filename for everything else.
    nonisolated static func displayName(for url: URL, category: LargeFileCategory) -> String {
        if category == .simulatorRuntime, url.pathExtension.lowercased() == "simruntime" {
            if let bundle = Bundle(url: url) {
                let info = bundle.infoDictionary
                let display = info?["CFBundleDisplayName"] as? String
                let name = info?["CFBundleName"] as? String
                if let display, !display.isEmpty { return display }
                if let name, !name.isEmpty { return name }
            }
            return url.deletingPathExtension().lastPathComponent
        }
        return url.lastPathComponent
    }
}
