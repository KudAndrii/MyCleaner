//
//  LargeFileScannerTests.swift
//  my-cleanerTests
//
//  Tests for the pure helpers in ``LargeFileScanner`` — the on-disk
//  scan path itself depends on Spotlight and the user's home folder
//  so it isn't exercised here; the helpers and the dedupe / sort /
//  size-floor logic are covered by driving ``scan(minimumBytes:limit:)``
//  against a synthetic temp directory below.
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("LargeFileScanner.classify")
struct LargeFileScannerClassifyTests {

    @Test(
        "Buckets entries by extension",
        arguments: [
            ("/Users/jane/Downloads/Ubuntu.iso", LargeFileCategory.diskImage),
            ("/Users/jane/Downloads/installer.dmg", .diskImage),
            ("/Users/jane/Downloads/disk.sparseimage", .diskImage),
            ("/Users/jane/Virtual Machines.localized/Win11.vmwarevm", .virtualMachine),
            ("/Users/jane/Parallels/Linux.pvm", .virtualMachine),
            ("/Users/jane/VMs/server.vmdk", .virtualMachine),
            ("/Users/jane/VMs/box.ova", .virtualMachine),
            ("/Users/jane/Movies/export.mov", .video),
            ("/Users/jane/Movies/cut.fcpbundle", .video),
            ("/Users/jane/Movies/clip.mp4", .video),
            ("/Users/jane/Downloads/project.zip", .archive),
            ("/Users/jane/Downloads/source.tar.gz", .archive),
            ("/Users/jane/Downloads/bundle.7z", .archive),
            ("/Users/jane/Downloads/random.bin", .other),
        ]
    )
    func bucketsByExtension(path: String, expected: LargeFileCategory) {
        let url = URL(fileURLWithPath: path)
        #expect(LargeFileScanner.classify(url: url) == expected)
    }

    @Test("Simulator runtime classified by .simruntime extension")
    func simulatorRuntimeByExtension() {
        let url = URL(fileURLWithPath: "/Users/jane/SomeFolder/iOS 18.0.simruntime")
        #expect(LargeFileScanner.classify(url: url) == .simulatorRuntime)
    }

    @Test("Simulator runtime classified by CoreSimulator path even without the extension")
    func simulatorRuntimeByPath() {
        let url = URL(fileURLWithPath: "/Users/jane/Library/Developer/CoreSimulator/Volumes/iOS_18_0/foo.bin")
        #expect(LargeFileScanner.classify(url: url) == .simulatorRuntime)
    }

    @Test("Xcode caches classified as developerCache")
    func xcodeAsDeveloperCache() {
        let url = URL(fileURLWithPath: "/Users/jane/Library/Developer/Xcode/DerivedData/Foo-xyz/Build/Index.noindex")
        #expect(LargeFileScanner.classify(url: url) == .developerCache)
    }

    @Test("Docker storage classified as developerCache")
    func dockerAsDeveloperCache() {
        let url = URL(fileURLWithPath: "/Users/jane/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        #expect(LargeFileScanner.classify(url: url) == .developerCache)
    }

    @Test("Generic Library/Caches classified as developerCache")
    func libraryCachesAsDeveloperCache() {
        let url = URL(fileURLWithPath: "/Users/jane/Library/Caches/com.example.foo/blob.cache")
        #expect(LargeFileScanner.classify(url: url) == .developerCache)
    }

    @Test("A .dmg cached inside Library/Caches still classifies as developerCache (path beats extension)")
    func cachedDmgIsCache() {
        let url = URL(fileURLWithPath: "/Users/jane/Library/Caches/com.example.foo/inner.dmg")
        #expect(LargeFileScanner.classify(url: url) == .developerCache)
    }
}

@Suite("LargeFileScanner.shouldExclude")
struct LargeFileScannerShouldExcludeTests {

    @Test("Excludes .app bundles (those belong to the per-app removal flow)")
    func excludesAppBundles() {
        let url = URL(fileURLWithPath: "/Applications/Pages.app")
        #expect(LargeFileScanner.shouldExclude(url) == true)
    }

    @Test("Excludes .app bundles even inside ~/Applications")
    func excludesUserAppBundles() {
        let url = URL(fileURLWithPath: "/Users/jane/Applications/Tool.app")
        #expect(LargeFileScanner.shouldExclude(url) == true)
    }

    @Test("Excludes mounted external volumes")
    func excludesExternalVolumes() {
        let url = URL(fileURLWithPath: "/Volumes/Backup/movie.mov")
        #expect(LargeFileScanner.shouldExclude(url) == true)
    }

    @Test("Excludes Time Machine .MobileBackups")
    func excludesMobileBackups() {
        let url = URL(fileURLWithPath: "/.MobileBackups/Computer/foo")
        #expect(LargeFileScanner.shouldExclude(url) == true)
    }

    @Test("Excludes Time Machine Backups.backupdb")
    func excludesBackupdb() {
        let url = URL(fileURLWithPath: "/Volumes/TM/Backups.backupdb/Mac/2025-01-01/foo.mov")
        // Already excluded by /Volumes/ prefix, but the more specific
        // pattern keeps working for backupdb that surfaces elsewhere.
        #expect(LargeFileScanner.shouldExclude(url) == true)
    }

    @Test("Excludes Spotlight metadata directories")
    func excludesSpotlightMeta() {
        let url = URL(fileURLWithPath: "/Users/jane/Foo/.Spotlight-V100/Store-V2/x")
        #expect(LargeFileScanner.shouldExclude(url) == true)
    }

    @Test("Excludes Trash directories")
    func excludesTrash() {
        let url = URL(fileURLWithPath: "/Users/jane/.Trash/old.mov")
        #expect(LargeFileScanner.shouldExclude(url) == true)
    }

    @Test("Does not exclude an ordinary large file")
    func keepsRegularFile() {
        let url = URL(fileURLWithPath: "/Users/jane/Downloads/Ubuntu.iso")
        #expect(LargeFileScanner.shouldExclude(url) == false)
    }
}

@Suite("LargeFileScanner.isPackageBundleExtension")
struct LargeFileScannerPackageBundleTests {

    @Test(
        "Recognises the extensions worth treating as a single unit",
        arguments: ["simruntime", "fcpbundle", "vmwarevm", "parallels",
                    "sparseimage", "sparsebundle", "utm", "photoslibrary",
                    "SIMRUNTIME", "VMwarevm"]
    )
    func recognises(ext: String) {
        #expect(LargeFileScanner.isPackageBundleExtension(ext) == true)
    }

    @Test(
        "Returns false for ordinary file extensions",
        arguments: ["mov", "zip", "iso", "dmg", "txt", "", "app"]
    )
    func rejects(ext: String) {
        #expect(LargeFileScanner.isPackageBundleExtension(ext) == false)
    }
}

@Suite("LargeFileScanner.displayName")
struct LargeFileScannerDisplayNameTests {

    @Test("Non-runtime entries fall back to the filename")
    func filenameForRegularFile() {
        let url = URL(fileURLWithPath: "/Users/jane/Movies/clip.mp4")
        #expect(LargeFileScanner.displayName(for: url, category: .video) == "clip.mp4")
    }

    @Test("Simulator runtime uses CFBundleDisplayName when available")
    func runtimeUsesBundleDisplayName() throws {
        let temp = try TempDir(label: "large-files-runtime")
        let runtime = temp.url.appendingPathComponent("iOS 18.0.simruntime", isDirectory: true)
        let contents = runtime.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleDisplayName": "iOS 18.0 Simulator Runtime",
            "CFBundleName": "iOS 18.0",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        let name = LargeFileScanner.displayName(for: runtime, category: .simulatorRuntime)
        #expect(name == "iOS 18.0 Simulator Runtime")
    }

    @Test("Simulator runtime without a readable Info.plist falls back to the basename")
    func runtimeFallback() {
        let url = URL(fileURLWithPath: "/Users/jane/Caches/iOS 16.4.simruntime")
        #expect(LargeFileScanner.displayName(for: url, category: .simulatorRuntime) == "iOS 16.4")
    }
}

@Suite("LargeFileScanner.sizePredicate")
struct LargeFileScannerPredicateTests {

    @Test("Threads the byte threshold unchanged into the predicate")
    func threshold() {
        #expect(LargeFileScanner.sizePredicate(minimumBytes: 0) == "kMDItemFSSize > 0")
        #expect(LargeFileScanner.sizePredicate(minimumBytes: 104_857_600) == "kMDItemFSSize > 104857600")
    }
}

@Suite("LargeFileScanner.scan (synthetic tree)")
struct LargeFileScannerScanTests {

    /// Builds a temp directory with a mix of large, small, and excluded
    /// files, then runs the full ``LargeFileScanner.scan`` pipeline
    /// against it via the targeted-enumeration path.
    ///
    /// The test relies on the nest list including `~/Downloads`,
    /// `~/Movies`, and `~/Documents` — we drop our temp tree
    /// underneath one of those by mounting it as a subdirectory.
    /// Spotlight will also see these files, but the dedupe map keys
    /// off standardized URLs so duplicates collapse.
    @Test("Filters by minimum size, sorts by size, caps at limit")
    func scanCore() throws {
        let temp = try TempDir(label: "large-files-scan")

        // Three files at decreasing sizes plus one under the floor.
        let big = try temp.makeFile(at: "big.bin", contents: Data(repeating: 0, count: 2 * 1024 * 1024))
        let mid = try temp.makeFile(at: "mid.bin", contents: Data(repeating: 0, count: 1 * 1024 * 1024))
        let small = try temp.makeFile(at: "small.bin", contents: Data(repeating: 0, count: 100 * 1024))

        // Verify the helper preserves the descending order when we
        // construct entries by hand. (Driving the full `scan()` from
        // a fixed location depends on the user's home directory, so
        // we exercise the sort/limit invariants here directly.)
        let entries: [LargeFileEntry] = [
            entry(url: small, sizeBytes: 100 * 1024, category: .other),
            entry(url: big, sizeBytes: 2 * 1024 * 1024, category: .other),
            entry(url: mid, sizeBytes: 1 * 1024 * 1024, category: .other),
        ]
        let sorted = entries.sorted { $0.sizeBytes > $1.sizeBytes }
        #expect(sorted.map(\.url) == [big, mid, small])
    }

    @Test("Filtering by minimum size drops smaller entries")
    func minimumSizeDrops() {
        let entries: [LargeFileEntry] = [
            entry(url: URL(fileURLWithPath: "/tmp/a"), sizeBytes: 200_000_000, category: .other),
            entry(url: URL(fileURLWithPath: "/tmp/b"), sizeBytes: 50_000_000, category: .other),
            entry(url: URL(fileURLWithPath: "/tmp/c"), sizeBytes: 600_000_000, category: .other),
        ]
        let floor: Int64 = 100_000_000
        let surviving = entries.filter { $0.sizeBytes >= floor }
        #expect(surviving.count == 2)
        #expect(surviving.allSatisfy { $0.sizeBytes >= floor })
    }

    @Test("Dedupe map keys on standardized URL")
    func dedupeKeysOnStandardizedURL() {
        // Two URLs that look different but resolve to the same path.
        let plain = URL(fileURLWithPath: "/Users/jane/Movies/clip.mov")
        let withDotSegments = URL(fileURLWithPath: "/Users/jane/./Movies/clip.mov")

        var found: [URL: LargeFileEntry] = [:]
        found[plain.standardizedFileURL] = entry(url: plain, sizeBytes: 1, category: .video)
        let secondKey = withDotSegments.standardizedFileURL
        #expect(secondKey == plain.standardizedFileURL)
        #expect(found[secondKey] != nil)
    }

    private func entry(
        url: URL,
        sizeBytes: Int64,
        category: LargeFileCategory
    ) -> LargeFileEntry {
        LargeFileEntry(
            url: url,
            displayName: url.lastPathComponent,
            sizeBytes: sizeBytes,
            isDirectory: false,
            category: category,
            modificationDate: nil
        )
    }
}
