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
        // Use a /private subpath that has no corresponding top-level
        // symlink — `/private/var`, `/private/etc`, `/private/tmp` all
        // standardize back to `/var`, `/etc`, `/tmp` on macOS and
        // bypass the `/private` prefix check, so we pick a made-up
        // subdir that survives standardization.
        let privateSub = URL(fileURLWithPath: "/private/\(UUID().uuidString)")
        #expect(DuplicateScanner.shouldSkipDirectory(privateSub) == true)
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

        let unique = DuplicateScanner.dedupeByInode(paths: [a.path, b.path, c.path])
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

    @Test("Partial-hash prefilter still groups large identical files together")
    func partialHashCorrectness() async throws {
        // Files large enough to land in the partial-then-full path
        // (size > partialHashSize = 64 KB). Two pairs share content;
        // a third file is unique but the same size as one of the pairs.
        let dir = try TempDir(label: "dup-partial")
        let large = 80 * 1024
        let payloadA = Data(repeating: 0xAA, count: large)
        let payloadB = Data(repeating: 0xBB, count: large)
        _ = try dir.makeFile(at: "a1.bin", contents: payloadA)
        _ = try dir.makeFile(at: "a2.bin", contents: payloadA)
        _ = try dir.makeFile(at: "b1.bin", contents: payloadB)
        _ = try dir.makeFile(at: "b2.bin", contents: payloadB)
        _ = try dir.makeFile(at: "lonely.bin", contents: Data(repeating: 0xCC, count: large))

        let groups = try await DuplicateScanner.scan(scope: [dir.url])
        // Two duplicate groups, lonely.bin ruled out by the partial pass.
        #expect(groups.count == 2)
        let counts = groups.map(\.copies.count).sorted()
        #expect(counts == [2, 2])
    }

    @Test("Partial-hash prefilter discriminates files with identical sizes but different content")
    func partialHashSeparatesByPrefix() async throws {
        // Two files of the same large size whose content differs only
        // in the first 64 KB — the prefilter should still split them
        // into separate groups (i.e. surface nothing).
        let dir = try TempDir(label: "dup-prefix-only")
        var a = Data(repeating: 0x11, count: 64 * 1024)
        a.append(Data(repeating: 0x00, count: 32 * 1024))
        var b = Data(repeating: 0x22, count: 64 * 1024)
        b.append(Data(repeating: 0x00, count: 32 * 1024))
        _ = try dir.makeFile(at: "a.bin", contents: a)
        _ = try dir.makeFile(at: "b.bin", contents: b)

        let groups = try await DuplicateScanner.scan(scope: [dir.url])
        #expect(groups.isEmpty)
    }

    @Test("Scanner emits progress for both enumeration and hashing phases")
    func progressCallback() async throws {
        let dir = try TempDir(label: "dup-progress")
        // Plenty of small files so we get enumeration emissions.
        for i in 0..<24 {
            let payload = Data(repeating: UInt8(i + 1), count: 256)
            _ = try dir.makeFile(at: "a-\(i).bin", contents: payload)
        }
        // A couple of duplicate pairs so the hash phase has work.
        let dupePayload = Data(repeating: 0xDD, count: 256)
        _ = try dir.makeFile(at: "dup-a.bin", contents: dupePayload)
        _ = try dir.makeFile(at: "dup-b.bin", contents: dupePayload)

        let updates = ProgressCollector()
        _ = try await DuplicateScanner.scan(scope: [dir.url]) { update in
            updates.append(update)
        }

        let collected = updates.snapshot()
        // Enumeration phase: at least one update with filesSeen > 0.
        #expect(collected.contains { update in
            if case .enumerating(let n) = update { return n > 0 }
            return false
        })
        // Hash phase: at least one update.
        #expect(collected.contains { update in
            if case .hashing = update { return true }
            return false
        })
        // Final hash update should report all candidates hashed.
        let finalHashing = collected.reversed().first(where: { update in
            if case .hashing = update { return true }
            return false
        })
        if case .hashing(let done, let total) = finalHashing {
            #expect(done == total)
            #expect(total > 0)
        } else {
            Issue.record("expected a final .hashing update with done == total")
        }
    }
}

/// Lock-protected sink for ``DuplicateScanner.Progress`` events
/// observed across the scanner's detached task. Lets the test
/// thread snapshot the full stream after the scan finishes.
private nonisolated final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DuplicateScanner.Progress] = []

    func append(_ event: DuplicateScanner.Progress) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [DuplicateScanner.Progress] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}
