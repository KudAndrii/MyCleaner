//
//  DuplicateScannerTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("DuplicateScanner — pure helpers")
struct DuplicateScannerHelpersTests {

    @Test("hashFile returns a stable hex digest")
    func hashFileStable() throws {
        let dir = try TempDir(label: "dup-hash")
        let payload = Data("hello world".utf8)
        let url = try dir.makeFile(at: "a.bin", contents: payload)
        let first = DuplicateScanner.hashFile(at: url)
        let second = DuplicateScanner.hashFile(at: url)
        #expect(first != nil)
        #expect(first == second)
        // Known SHA-256("hello world") starts with these bytes.
        #expect(first?.hasPrefix("b94d27b9934d3e08") == true)
    }

    @Test("hashFile returns the same digest for files with identical content")
    func hashFileMatchesAcrossFiles() throws {
        let dir = try TempDir(label: "dup-hash-eq")
        let payload = Data(repeating: 0x7E, count: 16 * 1024)
        let a = try dir.makeFile(at: "one.bin", contents: payload)
        let b = try dir.makeFile(at: "two.bin", contents: payload)
        #expect(DuplicateScanner.hashFile(at: a) == DuplicateScanner.hashFile(at: b))
    }

    @Test("hashFile differs for different content")
    func hashFileDiffersAcrossFiles() throws {
        let dir = try TempDir(label: "dup-hash-diff")
        let a = try dir.makeFile(at: "x.bin", contents: Data("one".utf8))
        let b = try dir.makeFile(at: "y.bin", contents: Data("two".utf8))
        #expect(DuplicateScanner.hashFile(at: a) != DuplicateScanner.hashFile(at: b))
    }

    @Test("hashFile returns nil for missing files")
    func hashFileMissing() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        #expect(DuplicateScanner.hashFile(at: url) == nil)
    }

    @Test("shouldSkipDirectory excludes Library and system paths")
    func shouldSkipDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        #expect(DuplicateScanner.shouldSkipDirectory(library) == true)
        #expect(DuplicateScanner.shouldSkipDirectory(URL(fileURLWithPath: "/System/Library")) == true)
        #expect(DuplicateScanner.shouldSkipDirectory(URL(fileURLWithPath: "/private/var")) == true)
        // A normal user folder should not be skipped.
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        #expect(DuplicateScanner.shouldSkipDirectory(downloads) == false)
    }
}

@Suite("DuplicateScanner.applyAutoSelection")
struct DuplicateScannerAutoSelectionTests {

    private func copy(_ name: String, date: Date?) -> DuplicateCopy {
        DuplicateCopy(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            modificationDate: date,
            isSelectedForDeletion: true
        )
    }

    @Test("Keeps the most recently modified copy")
    func keepsNewest() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        let copies = DuplicateScanner.applyAutoSelection([
            copy("old.bin", date: older),
            copy("new.bin", date: newer)
        ])
        let kept = copies.filter { !$0.isSelectedForDeletion }
        #expect(kept.count == 1)
        #expect(kept.first?.url.lastPathComponent == "new.bin")
    }

    @Test("Tiebreak: identical dates favor the deepest path")
    func tieBreaksByDepth() {
        let same = Date(timeIntervalSince1970: 1_700_000_000)
        let shallow = DuplicateCopy(
            id: UUID(),
            url: URL(fileURLWithPath: "/Users/me/Downloads/file.bin"),
            modificationDate: same,
            isSelectedForDeletion: true
        )
        let deep = DuplicateCopy(
            id: UUID(),
            url: URL(fileURLWithPath: "/Users/me/Documents/Projects/Active/file.bin"),
            modificationDate: same,
            isSelectedForDeletion: true
        )
        let result = DuplicateScanner.applyAutoSelection([shallow, deep])
        let kept = result.filter { !$0.isSelectedForDeletion }
        #expect(kept.count == 1)
        #expect(kept.first?.url == deep.url)
    }

    @Test("Treats a nil date as older than any concrete date")
    func nilDateLosesToConcrete() {
        let real = Date(timeIntervalSince1970: 1_700_000_000)
        let copies = DuplicateScanner.applyAutoSelection([
            copy("ghost.bin", date: nil),
            copy("real.bin", date: real)
        ])
        let kept = copies.filter { !$0.isSelectedForDeletion }
        #expect(kept.count == 1)
        #expect(kept.first?.url.lastPathComponent == "real.bin")
    }

    @Test("Exactly one copy stays kept across a multi-copy group")
    func singleKeeper() {
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let copies = DuplicateScanner.applyAutoSelection([
            copy("a", date: baseline),
            copy("b", date: baseline.addingTimeInterval(10)),
            copy("c", date: baseline.addingTimeInterval(5)),
            copy("d", date: baseline.addingTimeInterval(7))
        ])
        let kept = copies.filter { !$0.isSelectedForDeletion }
        #expect(kept.count == 1)
    }
}

@Suite("DuplicateScanner.scan")
struct DuplicateScannerScanTests {

    @Test("Surfaces files with identical content and skips unique ones")
    func surfacesDuplicates() async throws {
        let dir = try TempDir(label: "dup-scan")
        let payload = Data(repeating: 0x11, count: 4096)
        _ = try dir.makeFile(at: "a.bin", contents: payload)
        _ = try dir.makeFile(at: "nested/b.bin", contents: payload)
        // A unique file with the same size must NOT be grouped with the duplicates.
        let other = Data(repeating: 0x22, count: 4096)
        _ = try dir.makeFile(at: "unique.bin", contents: other)
        // A completely different size — also dropped by the size pass.
        _ = try dir.makeFile(at: "different.bin", contents: Data("nope".utf8))

        let groups = try await DuplicateScanner.scan(scope: [dir.url])
        #expect(groups.count == 1)
        #expect(groups.first?.copies.count == 2)
        #expect(groups.first?.sizePerCopy ?? 0 >= Int64(payload.count))
    }

    @Test("Auto-selects all but the chosen keeper")
    func autoSelectsCopies() async throws {
        let dir = try TempDir(label: "dup-auto")
        let payload = Data(repeating: 0x33, count: 2048)
        _ = try dir.makeFile(at: "first.bin", contents: payload)
        _ = try dir.makeFile(at: "deep/second.bin", contents: payload)

        let groups = try await DuplicateScanner.scan(scope: [dir.url])
        #expect(groups.count == 1)
        let kept = groups.first?.copies.filter { !$0.isSelectedForDeletion } ?? []
        #expect(kept.count == 1)
    }

    @Test("Hardlinks are collapsed and not surfaced as duplicates")
    func hardlinkExclusion() async throws {
        let dir = try TempDir(label: "dup-link")
        let payload = Data(repeating: 0x44, count: 1024)
        let original = try dir.makeFile(at: "original.bin", contents: payload)
        let linkURL = dir.url.appendingPathComponent("link.bin")
        try FileManager.default.linkItem(at: original, to: linkURL)

        let groups = try await DuplicateScanner.scan(scope: [dir.url])
        // Only one logical file on disk — no duplicate group should surface.
        #expect(groups.isEmpty)
    }

    @Test("Zero-byte files are ignored even when they share a size bucket")
    func zeroByteIgnored() async throws {
        let dir = try TempDir(label: "dup-empty")
        _ = try dir.makeFile(at: "a.bin", contents: Data())
        _ = try dir.makeFile(at: "b.bin", contents: Data())

        let groups = try await DuplicateScanner.scan(scope: [dir.url])
        #expect(groups.isEmpty)
    }

    @Test("Symlinks are skipped")
    func symlinkSkipped() async throws {
        let dir = try TempDir(label: "dup-sym")
        let payload = Data(repeating: 0x55, count: 1024)
        let real = try dir.makeFile(at: "real.bin", contents: payload)
        let link = dir.url.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let groups = try await DuplicateScanner.scan(scope: [dir.url])
        // The symlink points at the real file but isn't itself a
        // duplicate — only one regular file exists.
        #expect(groups.isEmpty)
    }

    @Test("dedupeByInode collapses hardlinks to a single representative")
    func dedupeByInode() throws {
        let dir = try TempDir(label: "dup-dedupe")
        let payload = Data(repeating: 0x66, count: 512)
        let a = try dir.makeFile(at: "a.bin", contents: payload)
        let b = dir.url.appendingPathComponent("b.bin")
        try FileManager.default.linkItem(at: a, to: b)
        let c = try dir.makeFile(at: "c.bin", contents: payload)

        let unique = DuplicateScanner.dedupeByInode([a, b, c])
        // `a` and `b` are hardlinked — they should collapse to one
        // representative. `c` is a separate file on disk.
        #expect(unique.count == 2)
    }

    @Test("Groups are sorted by maximum recoverable bytes, largest first")
    func sortedBySavings() async throws {
        let dir = try TempDir(label: "dup-sort")
        // Small duplicate pair.
        let small = Data(repeating: 0x77, count: 1024)
        _ = try dir.makeFile(at: "small-a.bin", contents: small)
        _ = try dir.makeFile(at: "small-b.bin", contents: small)
        // Large duplicate pair.
        let large = Data(repeating: 0x88, count: 32 * 1024)
        _ = try dir.makeFile(at: "large-a.bin", contents: large)
        _ = try dir.makeFile(at: "large-b.bin", contents: large)

        let groups = try await DuplicateScanner.scan(scope: [dir.url])
        #expect(groups.count == 2)
        #expect(groups.first!.maximumRecoverableBytes >= groups.last!.maximumRecoverableBytes)
    }

    @Test("Cancellation propagates as CancellationError")
    func cancellable() async throws {
        let dir = try TempDir(label: "dup-cancel")
        // Make a few duplicate pairs so there's work to do.
        for i in 0..<8 {
            let payload = Data(repeating: UInt8(i + 1), count: 4096)
            _ = try dir.makeFile(at: "bucket-\(i)-a.bin", contents: payload)
            _ = try dir.makeFile(at: "bucket-\(i)-b.bin", contents: payload)
        }

        let task = Task {
            try await DuplicateScanner.scan(scope: [dir.url])
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("Skips descending into .app bundles in the scope")
    func skipsAppBundles() async throws {
        let dir = try TempDir(label: "dup-app")
        let payload = Data(repeating: 0x99, count: 2048)
        // Two duplicates outside any app — should surface.
        _ = try dir.makeFile(at: "outside-a.bin", contents: payload)
        _ = try dir.makeFile(at: "outside-b.bin", contents: payload)
        // Two duplicates *inside* an .app bundle — should NOT surface,
        // because the walk skips package descendants.
        _ = try AppBundleBuilder.makeApp(
            in: dir.url,
            name: "Sample",
            bundleID: "com.example.sample"
        )
        let appURL = dir.url.appendingPathComponent("Sample.app", isDirectory: true)
        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try payload.write(to: resources.appendingPathComponent("inside-a.bin"))
        try payload.write(to: resources.appendingPathComponent("inside-b.bin"))

        let groups = try await DuplicateScanner.scan(scope: [dir.url])
        // Exactly one group — the pair outside the .app. The pair inside
        // is invisible to the walk thanks to .skipsPackageDescendants.
        #expect(groups.count == 1)
        let urls = groups.first?.copies.map(\.url.lastPathComponent).sorted() ?? []
        #expect(urls == ["outside-a.bin", "outside-b.bin"])
    }
}
