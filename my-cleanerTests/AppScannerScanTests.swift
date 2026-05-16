//
//  AppScannerScanTests.swift
//  my-cleanerTests
//
//  Integration-style tests for AppScanner.scan(directory:...) against
//  a synthetic Library tree built in a temporary directory. Verifies
//  the descent, bundle-ID + name-hint matching, and shared-flag logic
//  end-to-end without touching the real ~/Library.
//

import Foundation
import Testing
@testable import my_cleaner

@Suite("AppScanner.scan(directory:) — synthetic tree")
struct AppScannerScanDirectoryTests {

    private func makeDroppedApp(
        in root: URL,
        bundleID: String,
        name: String = "Sample"
    ) throws -> DroppedApp {
        let appURL = try AppBundleBuilder.makeApp(
            in: root,
            name: name,
            bundleID: bundleID
        )
        return DroppedApp(url: appURL)!
    }

    @Test("Finds a top-level Preferences plist named after the bundle ID")
    func findsPlist() throws {
        let dir = try TempDir(label: "scan-prefs")
        let prefs = try dir.makeDir(at: "Preferences")
        _ = try dir.makeFile(at: "Preferences/com.example.sample.plist")
        _ = try dir.makeFile(at: "Preferences/com.unrelated.foo.plist")
        let appHost = try dir.makeDir(at: "AppHost")
        let app = try makeDroppedApp(in: appHost, bundleID: "com.example.sample")

        var found: [URL: RelatedItem] = [:]
        AppScanner.scan(
            directory: prefs,
            category: .preferences,
            app: app,
            teamID: nil,
            nameHints: AppScanner.computeNameHints(app: app),
            extraDepth: 0,
            appPath: app.url.standardizedFileURL.path,
            into: &found
        )

        let names = Set(found.keys.map(\.lastPathComponent))
        #expect(names.contains("com.example.sample.plist"))
        #expect(!names.contains("com.unrelated.foo.plist"))
    }

    @Test("Descends one level for Application Support when extraDepth=1")
    func descendsOneLevel() throws {
        let dir = try TempDir(label: "scan-appsupport")
        let support = try dir.makeDir(at: "Application Support")
        _ = try dir.makeDir(at: "Application Support/JetBrains/Rider2025.3")
        let appHost = try dir.makeDir(at: "AppHost")
        let app = try makeDroppedApp(in: appHost, bundleID: "com.jetbrains.rider", name: "Rider")

        var found: [URL: RelatedItem] = [:]
        AppScanner.scan(
            directory: support,
            category: .applicationSupport,
            app: app,
            teamID: nil,
            nameHints: AppScanner.computeNameHints(app: app),
            extraDepth: 1,
            appPath: app.url.standardizedFileURL.path,
            into: &found
        )

        let names = Set(found.keys.map(\.lastPathComponent))
        #expect(names.contains("Rider2025.3"))
    }

    @Test("Does not descend into com.apple.* folders")
    func skipsApple() throws {
        let dir = try TempDir(label: "scan-skip-apple")
        let support = try dir.makeDir(at: "Application Support")
        _ = try dir.makeDir(at: "Application Support/com.apple.foo/com.example.sample")
        let appHost = try dir.makeDir(at: "AppHost")
        let app = try makeDroppedApp(in: appHost, bundleID: "com.example.sample")

        var found: [URL: RelatedItem] = [:]
        AppScanner.scan(
            directory: support,
            category: .applicationSupport,
            app: app,
            teamID: nil,
            nameHints: AppScanner.computeNameHints(app: app),
            extraDepth: 1,
            appPath: app.url.standardizedFileURL.path,
            into: &found
        )

        // Nothing should be found because the only match lives under
        // com.apple.foo/, which is skipped.
        #expect(found.isEmpty)
    }

    @Test("Skips the dropped app itself")
    func skipsAppPath() throws {
        let dir = try TempDir(label: "scan-skip-self")
        let applications = try dir.makeDir(at: "Applications")
        let appHost = try dir.makeDir(at: "AppHost")
        // Build an app inside Applications too — it shouldn't be classified as a match.
        _ = try AppBundleBuilder.makeApp(in: applications, name: "Sample", bundleID: "com.example.sample")
        let app = try makeDroppedApp(in: appHost, bundleID: "com.example.sample")

        var found: [URL: RelatedItem] = [:]
        AppScanner.scan(
            directory: applications,
            category: .other,
            app: app,
            teamID: nil,
            nameHints: AppScanner.computeNameHints(app: app),
            extraDepth: 0,
            appPath: app.url.standardizedFileURL.path,
            into: &found
        )

        // The app under Applications has a different filesystem path
        // from the dropped app — and its filename "Sample.app" matches
        // a name hint, so it WILL be picked up. The skipsAppPath logic
        // only protects the exact dropped-app path. Verify that the
        // dropped app's own URL is not in the result.
        #expect(found[app.url.standardizedFileURL] == nil)
    }

    @Test("Returns empty when no entries match")
    func noMatches() throws {
        let dir = try TempDir(label: "scan-no-matches")
        let prefs = try dir.makeDir(at: "Preferences")
        _ = try dir.makeFile(at: "Preferences/com.unrelated.foo.plist")
        _ = try dir.makeFile(at: "Preferences/com.unrelated.bar.plist")
        let appHost = try dir.makeDir(at: "AppHost")
        let app = try makeDroppedApp(in: appHost, bundleID: "com.example.sample")

        var found: [URL: RelatedItem] = [:]
        AppScanner.scan(
            directory: prefs,
            category: .preferences,
            app: app,
            teamID: nil,
            nameHints: AppScanner.computeNameHints(app: app),
            extraDepth: 0,
            appPath: app.url.standardizedFileURL.path,
            into: &found
        )
        #expect(found.isEmpty)
    }

    @Test("Team-prefix group container is flagged shared")
    func teamPrefixSharedFlag() throws {
        let dir = try TempDir(label: "scan-team-shared")
        let groupCont = try dir.makeDir(at: "Group Containers")
        _ = try dir.makeDir(at: "Group Containers/UBF8T346G9.Office")
        let appHost = try dir.makeDir(at: "AppHost")
        let app = try makeDroppedApp(in: appHost, bundleID: "com.microsoft.Word")

        var found: [URL: RelatedItem] = [:]
        AppScanner.scan(
            directory: groupCont,
            category: .groupContainers,
            app: app,
            teamID: "UBF8T346G9",
            nameHints: AppScanner.computeNameHints(app: app),
            extraDepth: 0,
            appPath: app.url.standardizedFileURL.path,
            into: &found
        )

        let officeURL = found.keys.first(where: { $0.lastPathComponent == "UBF8T346G9.Office" })
        let office = try #require(officeURL.flatMap { found[$0] })
        #expect(office.isShared == true)
        #expect(office.isSelected == false)
    }

    @Test("iCloud entries are flagged shared even when matched directly")
    func iCloudMatchedIsShared() throws {
        let dir = try TempDir(label: "scan-icloud-shared")
        let mobile = try dir.makeDir(at: "Mobile Documents")
        _ = try dir.makeDir(at: "Mobile Documents/iCloud~com~example~sample")
        let appHost = try dir.makeDir(at: "AppHost")
        let app = try makeDroppedApp(in: appHost, bundleID: "com.example.sample")

        var found: [URL: RelatedItem] = [:]
        AppScanner.scan(
            directory: mobile,
            category: .iCloud,
            app: app,
            teamID: nil,
            nameHints: AppScanner.computeNameHints(app: app),
            extraDepth: 0,
            appPath: app.url.standardizedFileURL.path,
            into: &found
        )

        let entry = try #require(found.values.first)
        #expect(entry.isShared == true)
        #expect(entry.isSelected == false)
    }

    @Test("scan against a missing directory is a no-op")
    func missingDirectory() throws {
        let dir = try TempDir(label: "scan-missing")
        let appHost = try dir.makeDir(at: "AppHost")
        let app = try makeDroppedApp(in: appHost, bundleID: "com.example.sample")

        var found: [URL: RelatedItem] = [:]
        AppScanner.scan(
            directory: dir.url.appendingPathComponent("Nonexistent"),
            category: .preferences,
            app: app,
            teamID: nil,
            nameHints: [],
            extraDepth: 0,
            appPath: app.url.standardizedFileURL.path,
            into: &found
        )
        #expect(found.isEmpty)
    }

    @Test("Won't overwrite an existing entry for the same URL")
    func doesntOverwrite() throws {
        let dir = try TempDir(label: "scan-no-overwrite")
        let prefs = try dir.makeDir(at: "Preferences")
        let file = try dir.makeFile(at: "Preferences/com.example.sample.plist")
        let appHost = try dir.makeDir(at: "AppHost")
        let app = try makeDroppedApp(in: appHost, bundleID: "com.example.sample")

        var found: [URL: RelatedItem] = [
            file.standardizedFileURL: RelatedItem(
                url: file.standardizedFileURL,
                category: .other,        // marker we'll check is preserved
                sizeBytes: 42,
                isDirectory: false,
                isShared: true
            )
        ]
        AppScanner.scan(
            directory: prefs,
            category: .preferences,
            app: app,
            teamID: nil,
            nameHints: [],
            extraDepth: 0,
            appPath: app.url.standardizedFileURL.path,
            into: &found
        )
        let entry = try #require(found[file.standardizedFileURL])
        // Marker category is preserved — the second pass didn't overwrite.
        #expect(entry.category == .other)
        #expect(entry.sizeBytes == 42)
    }
}
