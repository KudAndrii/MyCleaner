//
//  ModelsTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("DroppedApp")
struct DroppedAppTests {

    @Test("Rejects URLs that aren't .app bundles")
    func rejectsNonAppURL() {
        let url = URL(fileURLWithPath: "/tmp/whatever.txt")
        #expect(DroppedApp(url: url) == nil)
    }

    @Test("Accepts .app extension case-insensitively")
    func acceptsCaseInsensitiveExtension() throws {
        let dir = try TempDir(label: "dropped-app-ext")
        let app = try AppBundleBuilder.makeApp(
            in: dir.url,
            name: "Sample",
            bundleID: "com.example.sample"
        )
        // Force uppercase extension by renaming.
        let renamed = app.deletingLastPathComponent().appendingPathComponent("Sample.APP")
        try FileManager.default.moveItem(at: app, to: renamed)
        let dropped = DroppedApp(url: renamed)
        #expect(dropped != nil)
    }

    @Test("Reads bundleID and display name from Info.plist")
    func readsInfoPlist() throws {
        let dir = try TempDir(label: "dropped-app-info")
        let app = try AppBundleBuilder.makeApp(
            in: dir.url,
            name: "Internal",
            bundleID: "com.example.internalApp",
            displayName: "Fancy Display Name"
        )
        let dropped = try #require(DroppedApp(url: app))
        #expect(dropped.bundleID == "com.example.internalApp")
        #expect(dropped.name == "Fancy Display Name")
    }

    @Test("Falls back to CFBundleName when no display name is present")
    func fallsBackToBundleName() throws {
        let dir = try TempDir(label: "dropped-app-name")
        let app = try AppBundleBuilder.makeApp(
            in: dir.url,
            name: "InternalName",
            bundleID: "com.example.fallback",
            displayName: nil
        )
        let dropped = try #require(DroppedApp(url: app))
        #expect(dropped.name == "InternalName")
    }

    @Test("Falls back to filename when Info.plist is missing")
    func fallsBackToFilename() throws {
        let dir = try TempDir(label: "dropped-app-filename")
        let appURL = dir.url.appendingPathComponent("Naked.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let dropped = try #require(DroppedApp(url: appURL))
        #expect(dropped.bundleID == nil)
        #expect(dropped.name == "Naked")
    }

    @Test("id is the bundle URL")
    func idEqualsURL() throws {
        let dir = try TempDir(label: "dropped-app-id")
        let app = try AppBundleBuilder.makeApp(
            in: dir.url,
            name: "Sample",
            bundleID: "com.example.sample"
        )
        let dropped = try #require(DroppedApp(url: app))
        #expect(dropped.id == dropped.url)
    }
}

@Suite("RelatedItem")
struct RelatedItemTests {

    @Test("Shared items default to unselected")
    func sharedDefaultsOff() {
        let item = RelatedItem(
            url: URL(fileURLWithPath: "/tmp/foo"),
            category: .groupContainers,
            sizeBytes: 100,
            isDirectory: true,
            isShared: true
        )
        #expect(item.isSelected == false)
    }

    @Test("Non-shared items default to selected")
    func nonSharedDefaultsOn() {
        let item = RelatedItem(
            url: URL(fileURLWithPath: "/tmp/foo"),
            category: .caches,
            sizeBytes: 100,
            isDirectory: true,
            isShared: false
        )
        #expect(item.isSelected == true)
    }

    @Test("id is the URL")
    func idEqualsURL() {
        let url = URL(fileURLWithPath: "/tmp/foo")
        let item = RelatedItem(url: url, category: .caches, sizeBytes: 0, isDirectory: false)
        #expect(item.id == url)
    }

    @Test("Every category has a non-empty SF Symbol name")
    func everyCategoryHasSymbol() {
        for category in RelatedItem.Category.allCases {
            #expect(!category.symbol.isEmpty)
        }
    }

    @Test("Categories have human-readable raw values")
    func categoryRawValues() {
        #expect(RelatedItem.Category.applicationSupport.rawValue == "Application Support")
        #expect(RelatedItem.Category.groupContainers.rawValue == "Group Containers")
        #expect(RelatedItem.Category.iCloud.rawValue == "iCloud Documents")
        #expect(RelatedItem.Category.cookies.rawValue == "Cookies & Web Data")
    }
}

@Suite("CleanupReport")
struct CleanupReportTests {

    @Test("trashed sums normal + elevated")
    func trashedTotal() {
        let report = CleanupReport(trashedNormally: 3, trashedWithElevation: 2, failures: [])
        #expect(report.trashed == 5)
    }

    @Test("Reports with same fields are equal")
    func equality() {
        let url = URL(fileURLWithPath: "/tmp/foo")
        let a = CleanupReport(
            trashedNormally: 1,
            trashedWithElevation: 0,
            failures: [.init(url: url, message: "boom")]
        )
        let b = CleanupReport(
            trashedNormally: 1,
            trashedWithElevation: 0,
            failures: [.init(url: url, message: "boom")]
        )
        #expect(a == b)
    }

    @Test("Failure id is its url")
    func failureIDIsURL() {
        let url = URL(fileURLWithPath: "/tmp/foo")
        let f = CleanupReport.Failure(url: url, message: "x")
        #expect(f.id == url)
    }
}

@Suite("ScanResult")
struct ScanResultTests {

    @Test("Stores appSize and items")
    func storesValues() {
        let item = RelatedItem(
            url: URL(fileURLWithPath: "/tmp/foo"),
            category: .caches,
            sizeBytes: 1024,
            isDirectory: false
        )
        let result = ScanResult(appSize: 4096, items: [item])
        #expect(result.appSize == 4096)
        #expect(result.items.count == 1)
        #expect(result.items[0].sizeBytes == 1024)
    }
}
