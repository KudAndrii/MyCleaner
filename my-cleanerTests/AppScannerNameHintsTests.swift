//
//  AppScannerNameHintsTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("AppScanner.computeNameHints")
struct AppScannerNameHintsTests {

    private func make(name: String, bundleID: String?, urlName: String? = nil) throws -> DroppedApp {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mycleaner-hints-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = try AppBundleBuilder.makeApp(
            in: dir,
            name: urlName ?? name,
            bundleID: bundleID,
            displayName: name
        )
        return DroppedApp(url: app)!
    }

    @Test("Collects display name, last bundle component, and filename")
    func collectsAllThree() throws {
        let app = try make(
            name: "JetBrains Rider",
            bundleID: "com.jetbrains.rider",
            urlName: "Rider"
        )
        let hints = AppScanner.computeNameHints(app: app)
        let set = Set(hints)
        #expect(set.contains("jetbrains rider"))
        #expect(set.contains("rider"))
    }

    @Test("Lowercases all hints")
    func lowercased() throws {
        let app = try make(name: "TextEdit", bundleID: "com.apple.TextEdit")
        let hints = AppScanner.computeNameHints(app: app)
        for h in hints {
            #expect(h == h.lowercased())
        }
    }

    @Test("Drops hints shorter than 3 characters")
    func dropsShort() throws {
        let app = try make(name: "AB", bundleID: "com.example.ab")
        let hints = AppScanner.computeNameHints(app: app)
        #expect(!hints.contains("ab"))
    }

    @Test("De-duplicates identical hints")
    func dedupes() throws {
        // Bundle ID's last component equals display name equals filename.
        let app = try make(name: "Sample", bundleID: "com.example.sample")
        let hints = AppScanner.computeNameHints(app: app)
        // Only "sample" should appear once.
        let sampleCount = hints.filter { $0 == "sample" }.count
        #expect(sampleCount == 1)
    }

    @Test("Handles missing bundle ID without crashing")
    func missingBundleID() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mycleaner-hints-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("NakedApp.app", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let app = try #require(DroppedApp(url: url))
        let hints = AppScanner.computeNameHints(app: app)
        #expect(hints.contains("nakedapp"))
    }
}
