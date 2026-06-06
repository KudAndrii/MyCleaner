//
//  CacheScannerTests.swift
//  my-cleanerTests
//
//  Tests for CacheScanner.scanCachesDirectory against a synthetic
//  directory tree. Each test seeds a temp Caches/ folder with
//  bundle-ID-named subdirectories of controlled sizes, then asserts
//  which groups get surfaced, with which kind, and whether the size
//  threshold and Apple-namespace exclusions kick in correctly.
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("CacheScanner.scanCachesDirectory")
struct CacheScannerScanDirTests {

    /// Seeds a cache directory entry whose tree-sum is approximately `size`
    /// bytes. Uses non-zero bytes so the FS doesn't store it sparse.
    private func seedCache(in dir: TempDir, name: String, size: Int) throws -> URL {
        _ = try dir.makeDir(at: "Caches/\(name)")
        let payload = Data(repeating: 0x41, count: size)
        return try dir.makeFile(at: "Caches/\(name)/blob.bin", contents: payload)
    }

    @Test("Entries below the size threshold are excluded")
    func belowThresholdExcluded() throws {
        let dir = try TempDir(label: "cache-below-threshold")
        let caches = try dir.makeDir(at: "Caches")
        _ = try seedCache(in: dir, name: "com.example.tiny", size: 1_000)

        var groups: [String: CacheGroup] = [:]
        CacheScanner.scanCachesDirectory(
            caches,
            minimumBytes: 50_000,
            installedBundleIDs: [],
            into: &groups
        )
        #expect(groups["com.example.tiny"] == nil)
    }

    @Test("Entries at or above the threshold are surfaced")
    func atThresholdSurfaced() throws {
        let dir = try TempDir(label: "cache-at-threshold")
        let caches = try dir.makeDir(at: "Caches")
        _ = try seedCache(in: dir, name: "com.example.large", size: 60_000)

        var groups: [String: CacheGroup] = [:]
        CacheScanner.scanCachesDirectory(
            caches,
            minimumBytes: 50_000,
            installedBundleIDs: [],
            into: &groups
        )
        let group = try #require(groups["com.example.large"])
        #expect(group.totalBytes >= 50_000)
    }

    @Test("Apple-namespace caches are excluded by default")
    func appleNamespaceExcluded() throws {
        let dir = try TempDir(label: "cache-apple-excluded")
        let caches = try dir.makeDir(at: "Caches")
        _ = try seedCache(in: dir, name: "com.apple.somecache", size: 100_000)

        var groups: [String: CacheGroup] = [:]
        CacheScanner.scanCachesDirectory(
            caches,
            minimumBytes: 50_000,
            installedBundleIDs: [],
            into: &groups
        )
        #expect(groups["com.apple.somecache"] == nil)
    }

    @Test("Allowlisted Apple caches (e.g. Safari) are surfaced")
    func appleSafariAllowed() throws {
        let dir = try TempDir(label: "cache-apple-safari")
        let caches = try dir.makeDir(at: "Caches")
        _ = try seedCache(in: dir, name: "com.apple.Safari", size: 100_000)

        var groups: [String: CacheGroup] = [:]
        CacheScanner.scanCachesDirectory(
            caches,
            minimumBytes: 50_000,
            installedBundleIDs: [],
            into: &groups
        )
        #expect(groups["com.apple.Safari"] != nil)
    }

    @Test("Cache for an installed bundle ID is labeled installedApp")
    func installedAttribution() throws {
        let dir = try TempDir(label: "cache-installed")
        let caches = try dir.makeDir(at: "Caches")
        _ = try seedCache(in: dir, name: "com.totally.unique.installed", size: 100_000)

        var groups: [String: CacheGroup] = [:]
        CacheScanner.scanCachesDirectory(
            caches,
            minimumBytes: 50_000,
            // Launch Services won't know this fabricated ID, so attribution
            // falls back to the installedBundleIDs set.
            installedBundleIDs: ["com.totally.unique.installed"],
            into: &groups
        )
        let group = try #require(groups["com.totally.unique.installed"])
        #expect(group.kind == .installedApp)
        #expect(group.isSafeToDelete == true)
        #expect(group.isSelected == true)
    }

    @Test("Cache whose owning app isn't installed is labeled orphanApp")
    func orphanAttribution() throws {
        let dir = try TempDir(label: "cache-orphan")
        let caches = try dir.makeDir(at: "Caches")
        _ = try seedCache(in: dir, name: "com.totally.unique.notinstalled", size: 100_000)

        var groups: [String: CacheGroup] = [:]
        CacheScanner.scanCachesDirectory(
            caches,
            minimumBytes: 50_000,
            installedBundleIDs: [],
            into: &groups
        )
        let group = try #require(groups["com.totally.unique.notinstalled"])
        #expect(group.kind == .orphanApp)
        // Orphans are still safe to delete — they're just labelled
        // differently in the UI.
        #expect(group.isSafeToDelete == true)
    }

    @Test("Anonymous (vendor-named) entries are labeled anonymous and default unselected")
    func anonymousAttribution() throws {
        let dir = try TempDir(label: "cache-anon")
        let caches = try dir.makeDir(at: "Caches")
        // "Homebrew" doesn't look like a bundle ID — no dot.
        _ = try seedCache(in: dir, name: "RandomVendorFolder", size: 100_000)

        var groups: [String: CacheGroup] = [:]
        CacheScanner.scanCachesDirectory(
            caches,
            minimumBytes: 50_000,
            installedBundleIDs: [],
            into: &groups
        )
        let group = try #require(groups.values.first { $0.displayName == "RandomVendorFolder" })
        #expect(group.kind == .anonymous)
        #expect(group.bundleID == nil)
        #expect(group.isSafeToDelete == false)
        #expect(group.isSelected == false)
    }

    @Test("Same bundle ID across two passes appends entries to one group")
    func mergesAcrossPasses() throws {
        let dirA = try TempDir(label: "cache-merge-a")
        let dirB = try TempDir(label: "cache-merge-b")
        let cachesA = try dirA.makeDir(at: "Caches")
        let cachesB = try dirB.makeDir(at: "Caches")
        _ = try seedCache(in: dirA, name: "com.example.shared", size: 100_000)
        _ = try seedCache(in: dirB, name: "com.example.shared", size: 100_000)

        var groups: [String: CacheGroup] = [:]
        CacheScanner.scanCachesDirectory(
            cachesA,
            minimumBytes: 50_000,
            installedBundleIDs: [],
            into: &groups
        )
        CacheScanner.scanCachesDirectory(
            cachesB,
            minimumBytes: 50_000,
            installedBundleIDs: [],
            into: &groups
        )
        let group = try #require(groups["com.example.shared"])
        #expect(group.entries.count == 2)
    }

    @Test("Missing directory is a no-op")
    func missingDirectory() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        var groups: [String: CacheGroup] = [:]
        CacheScanner.scanCachesDirectory(
            url,
            minimumBytes: 50_000,
            installedBundleIDs: [],
            into: &groups
        )
        #expect(groups.isEmpty)
    }
}

@Suite("CacheScanner.isWellKnownSafeAppleCache")
struct WellKnownSafeAppleCacheTests {

    @Test("Safari is allowlisted")
    func safariAllowed() {
        #expect(CacheScanner.isWellKnownSafeAppleCache(bundleID: "com.apple.Safari") == true)
        // Case-insensitive.
        #expect(CacheScanner.isWellKnownSafeAppleCache(bundleID: "COM.APPLE.SAFARI") == true)
    }

    @Test("Most Apple caches are not allowlisted")
    func mostNotAllowed() {
        #expect(CacheScanner.isWellKnownSafeAppleCache(bundleID: "com.apple.dt.Xcode") == false)
        #expect(CacheScanner.isWellKnownSafeAppleCache(bundleID: "com.apple.cfprefsd") == false)
        #expect(CacheScanner.isWellKnownSafeAppleCache(bundleID: "com.example.foo") == false)
    }
}

@Suite("CacheScanner.scanWellKnownPath")
struct CacheScannerWellKnownPathTests {

    @Test("Missing path returns nil")
    func missingPath() {
        let path = CacheScanner.WellKnownPath(
            relativePath: "nonexistent-\(UUID().uuidString)",
            displayName: "Bogus"
        )
        #expect(CacheScanner.scanWellKnownPath(path, minimumBytes: 1) == nil)
    }
}

@Suite("CacheGroup")
struct CacheGroupTests {

    private func entry(_ size: Int64) -> CacheEntry {
        CacheEntry(
            url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"),
            sizeBytes: size,
            isDirectory: true
        )
    }

    @Test("totalBytes sums entries")
    func totalBytes() {
        let group = CacheGroup(
            id: "com.example.foo",
            bundleID: "com.example.foo",
            displayName: "Example",
            appURL: nil,
            kind: .installedApp,
            entries: [entry(100), entry(200), entry(300)],
            isSafeToDelete: true,
            isSelected: true
        )
        #expect(group.totalBytes == 600)
    }

    @Test("Empty entries yields zero total")
    func emptyTotal() {
        let group = CacheGroup(
            id: "x",
            bundleID: nil,
            displayName: "x",
            appURL: nil,
            kind: .anonymous,
            entries: [],
            isSafeToDelete: false,
            isSelected: false
        )
        #expect(group.totalBytes == 0)
    }
}

@Suite("CacheScanResult")
struct CacheScanResultTests {

    private func entry(_ size: Int64) -> CacheEntry {
        CacheEntry(
            url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"),
            sizeBytes: size,
            isDirectory: true
        )
    }

    private func group(_ id: String, sizes: [Int64]) -> CacheGroup {
        CacheGroup(
            id: id,
            bundleID: id,
            displayName: id,
            appURL: nil,
            kind: .installedApp,
            entries: sizes.map(entry),
            isSafeToDelete: true,
            isSelected: true
        )
    }

    @Test("totalSize sums across every group")
    func sumsAcrossGroups() {
        let result = CacheScanResult(groups: [
            group("a", sizes: [10, 20]),
            group("b", sizes: [30]),
        ])
        #expect(result.totalSize == 60)
    }
}
