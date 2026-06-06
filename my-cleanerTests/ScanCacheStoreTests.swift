//
//  ScanCacheStoreTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("ScanCacheStore — JSON round-trip")
struct ScanCacheStoreRoundTripTests {

    @Test
    func emptyCacheRoundTrips() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        ScanCacheStore.save(.empty, to: url)
        let loaded = ScanCacheStore.load(from: url)
        #expect(loaded == .empty)
    }

    @Test
    func populatedCacheRoundTrips() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = ScanCache(
            orphans: OrphansSnapshot(
                scannedAt: Date(timeIntervalSince1970: 1_000),
                groups: [
                    .init(bundleID: "com.example.Foo", items: [
                        .init(path: "/tmp/foo", sizeBytes: 1_024),
                        .init(path: "/tmp/foo2", sizeBytes: 2_048),
                    ])
                ]
            ),
            largeFiles: LargeFilesSnapshot(
                scannedAt: Date(timeIntervalSince1970: 2_000),
                items: [.init(path: "/tmp/big.bin", sizeBytes: 5_000_000)]
            ),
            oversizedCaches: OversizedCachesSnapshot(
                scannedAt: Date(timeIntervalSince1970: 3_000),
                groups: [
                    .init(id: "xcode", entries: [
                        .init(path: "/tmp/derived", sizeBytes: 12_345)
                    ])
                ]
            ),
            duplicates: DuplicatesSnapshot(
                scannedAt: Date(timeIntervalSince1970: 4_000),
                groups: [
                    .init(sizePerCopy: 1_000, paths: ["/tmp/a", "/tmp/b", "/tmp/c"])
                ]
            )
        )

        ScanCacheStore.save(cache, to: url)
        let loaded = ScanCacheStore.load(from: url)
        #expect(loaded == cache)
    }

    @Test
    func loadingMissingFileReturnsEmpty() {
        let url = makeTempURL()
        #expect(ScanCacheStore.load(from: url) == .empty)
    }

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }
}

@Suite("ScanCacheStore — validate prunes missing files")
struct ScanCacheStoreValidateTests {

    @Test
    func keepsEntriesThatExist() {
        let cache = ScanCache(
            largeFiles: LargeFilesSnapshot(
                scannedAt: Date(),
                items: [
                    .init(path: "/exists/a", sizeBytes: 1),
                    .init(path: "/exists/b", sizeBytes: 2),
                ]
            )
        )
        let pruned = ScanCacheStore.validate(cache) { _ in true }
        #expect(pruned == cache)
    }

    @Test
    func dropsMissingLargeFiles() {
        let cache = ScanCache(
            largeFiles: LargeFilesSnapshot(
                scannedAt: Date(),
                items: [
                    .init(path: "/exists", sizeBytes: 1),
                    .init(path: "/gone", sizeBytes: 2),
                ]
            )
        )
        let pruned = ScanCacheStore.validate(cache) { $0 == "/exists" }
        #expect(pruned.largeFiles?.items.map(\.path) == ["/exists"])
    }

    @Test
    func clearsLargeFilesSnapshotWhenEverythingPruned() {
        let cache = ScanCache(
            largeFiles: LargeFilesSnapshot(
                scannedAt: Date(),
                items: [.init(path: "/gone", sizeBytes: 1)]
            )
        )
        let pruned = ScanCacheStore.validate(cache) { _ in false }
        #expect(pruned.largeFiles == nil)
    }

    @Test
    func collapsesEmptyOrphanGroups() {
        let cache = ScanCache(
            orphans: OrphansSnapshot(
                scannedAt: Date(),
                groups: [
                    .init(bundleID: "com.alive", items: [
                        .init(path: "/keep", sizeBytes: 1)
                    ]),
                    .init(bundleID: "com.gone", items: [
                        .init(path: "/missing", sizeBytes: 1)
                    ]),
                ]
            )
        )
        let pruned = ScanCacheStore.validate(cache) { $0 == "/keep" }
        #expect(pruned.orphans?.groups.map(\.bundleID) == ["com.alive"])
    }

    @Test
    func collapsesEmptyOversizedCacheGroups() {
        let cache = ScanCache(
            oversizedCaches: OversizedCachesSnapshot(
                scannedAt: Date(),
                groups: [
                    .init(id: "keep", entries: [.init(path: "/k", sizeBytes: 1)]),
                    .init(id: "gone", entries: [.init(path: "/g", sizeBytes: 1)]),
                ]
            )
        )
        let pruned = ScanCacheStore.validate(cache) { $0 == "/k" }
        #expect(pruned.oversizedCaches?.groups.map(\.id) == ["keep"])
    }

    @Test
    func dropsDuplicateGroupBelowTwoCopies() {
        let cache = ScanCache(
            duplicates: DuplicatesSnapshot(
                scannedAt: Date(),
                groups: [
                    .init(sizePerCopy: 100, paths: ["/a", "/b", "/c"]),
                    .init(sizePerCopy: 200, paths: ["/x", "/y"]),
                ]
            )
        )
        // Group 1: only /a survives → drop the whole group (was 3 copies).
        // Group 2: /y survives → drop (singleton can't be a duplicate).
        let pruned = ScanCacheStore.validate(cache) { $0 == "/a" || $0 == "/y" }
        #expect(pruned.duplicates == nil)
    }

    @Test
    func keepsDuplicateGroupWithTwoOrMoreSurvivors() {
        let cache = ScanCache(
            duplicates: DuplicatesSnapshot(
                scannedAt: Date(),
                groups: [
                    .init(sizePerCopy: 100, paths: ["/a", "/b", "/c"])
                ]
            )
        )
        let pruned = ScanCacheStore.validate(cache) { $0 != "/c" }
        #expect(pruned.duplicates?.groups.first?.paths == ["/a", "/b"])
    }
}

@Suite("ScanCache — home stat derivations")
struct ScanCacheHomeStatTests {

    @Test
    func orphanStatSumsGroups() {
        let cache = ScanCache(
            orphans: OrphansSnapshot(scannedAt: Date(), groups: [
                .init(bundleID: "a", items: [
                    .init(path: "/p1", sizeBytes: 1_000),
                    .init(path: "/p2", sizeBytes: 2_000),
                ]),
                .init(bundleID: "b", items: [
                    .init(path: "/p3", sizeBytes: 4_000)
                ]),
            ])
        )
        let stat = cache.orphanStat
        #expect(stat?.totalBytes == 7_000)
        #expect(stat?.count == 2)
    }

    @Test
    func largeFileStatCountsItems() {
        let cache = ScanCache(
            largeFiles: LargeFilesSnapshot(scannedAt: Date(), items: [
                .init(path: "/a", sizeBytes: 1_000),
                .init(path: "/b", sizeBytes: 2_500),
                .init(path: "/c", sizeBytes: 500),
            ])
        )
        let stat = cache.largeFileStat
        #expect(stat?.totalBytes == 4_000)
        #expect(stat?.count == 3)
    }

    @Test
    func duplicateStatReportsExtraCopiesOnly() {
        let cache = ScanCache(
            duplicates: DuplicatesSnapshot(scannedAt: Date(), groups: [
                // 3 copies × 1000 = 2000 extra
                .init(sizePerCopy: 1_000, paths: ["/a", "/b", "/c"]),
                // 2 copies × 500 = 500 extra
                .init(sizePerCopy: 500, paths: ["/x", "/y"]),
            ])
        )
        let stat = cache.duplicateStat
        // dupes = 2 + 1 = 3; bytes = 2*1000 + 1*500 = 2500
        #expect(stat?.count == 3)
        #expect(stat?.totalBytes == 2_500)
    }

    @Test
    func statsAreNilWhenSnapshotMissingOrEmpty() {
        #expect(ScanCache.empty.orphanStat == nil)
        #expect(ScanCache.empty.largeFileStat == nil)
        #expect(ScanCache.empty.oversizedCacheStat == nil)
        #expect(ScanCache.empty.duplicateStat == nil)

        let onlyEmptyOrphans = ScanCache(
            orphans: OrphansSnapshot(scannedAt: Date(), groups: [])
        )
        #expect(onlyEmptyOrphans.orphanStat == nil)
    }
}
