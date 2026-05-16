//
//  AppScannerSizeTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import my_cleaner

@Suite("AppScanner.sizeOfItem")
struct AppScannerSizeTests {

    @Test("Returns 0 for a nonexistent file")
    func sizeForMissing() {
        let url = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
        let size = AppScanner.sizeOfItem(at: url, isDirectory: false)
        #expect(size == 0)
    }

    @Test("Returns nonzero for a file with bytes on disk")
    func sizeForFile() throws {
        let dir = try TempDir(label: "size-file")
        let payload = Data(repeating: 0x41, count: 8192)
        let file = try dir.makeFile(at: "blob.bin", contents: payload)
        let size = AppScanner.sizeOfItem(at: file, isDirectory: false)
        // Allocated size can be larger than the logical size due to FS
        // block rounding, but it should be at least the payload size.
        #expect(size >= Int64(payload.count))
    }

    @Test("Recursively sums file sizes inside a directory")
    func sizeForDirectory() throws {
        let dir = try TempDir(label: "size-dir")
        let root = try dir.makeDir(at: "root")
        let payload = Data(repeating: 0x42, count: 4096)
        _ = try dir.makeFile(at: "root/a.bin", contents: payload)
        _ = try dir.makeFile(at: "root/sub/b.bin", contents: payload)
        let size = AppScanner.sizeOfItem(at: root, isDirectory: true)
        // Two files of 4096 bytes each; on-disk allocation is at least that.
        #expect(size >= Int64(payload.count * 2))
    }

    @Test("Returns 0 for an empty directory")
    func sizeForEmptyDir() throws {
        let dir = try TempDir(label: "size-empty")
        let empty = try dir.makeDir(at: "empty")
        let size = AppScanner.sizeOfItem(at: empty, isDirectory: true)
        #expect(size == 0)
    }
}
