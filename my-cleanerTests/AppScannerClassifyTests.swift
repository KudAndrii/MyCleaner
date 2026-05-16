//
//  AppScannerClassifyTests.swift
//  my-cleanerTests
//
//  Covers AppScanner.classify — the per-entry matcher that decides
//  whether a Library entry belongs to the dropped app and whether it
//  should be flagged as "shared" (default-off).
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("AppScanner.classify")
struct AppScannerClassifyTests {

    private func makeApp(
        name: String = "Sample",
        bundleID: String? = "com.example.sample"
    ) throws -> DroppedApp {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mycleaner-classify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = try AppBundleBuilder.makeApp(in: dir, name: name, bundleID: bundleID)
        // Hold onto the URL only; we don't need to clean up because the
        // OS reclaims /tmp eventually and tests don't depend on filesystem
        // state, only on classify's pure-string logic.
        return DroppedApp(url: app)!
    }

    // MARK: - Bundle ID

    @Test("Exact bundle ID match")
    func exactBundleIDMatch() throws {
        let app = try makeApp(bundleID: "com.example.sample")
        let entry = URL(fileURLWithPath: "/Library/Preferences/com.example.sample.plist")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: [],
            category: .preferences
        )
        #expect(result.matched == true)
        #expect(result.shared == false)
    }

    @Test("Bundle ID prefix match")
    func bundleIDPrefixMatch() throws {
        let app = try makeApp(bundleID: "com.example.sample")
        let entry = URL(fileURLWithPath: "/Library/Containers/com.example.sample.Helper")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: [],
            category: .containers
        )
        #expect(result.matched == true)
    }

    @Test("Group prefix match")
    func groupPrefixMatch() throws {
        let app = try makeApp(bundleID: "com.example.sample")
        let entry = URL(fileURLWithPath: "/Library/Group Containers/group.com.example.sample")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: [],
            category: .groupContainers
        )
        #expect(result.matched == true)
        #expect(result.shared == false)
    }

    @Test("Group prefix match with dotted suffix")
    func groupPrefixWithSuffix() throws {
        let app = try makeApp(bundleID: "com.example.sample")
        let entry = URL(fileURLWithPath: "/Library/Group Containers/group.com.example.sample.Sub")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: [],
            category: .groupContainers
        )
        #expect(result.matched == true)
    }

    @Test("iCloud tilde-encoded bundle ID")
    func iCloudTildeForm() throws {
        let app = try makeApp(bundleID: "com.apple.Pages")
        let entry = URL(fileURLWithPath: "/Library/Mobile Documents/iCloud~com~apple~Pages")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: [],
            category: .iCloud
        )
        #expect(result.matched == true)
    }

    @Test("iCloud tilde-encoded bundle ID with trailing suffix")
    func iCloudTildeWithSuffix() throws {
        let app = try makeApp(bundleID: "com.example.sample")
        let entry = URL(fileURLWithPath: "/Library/Mobile Documents/iCloud~com~example~sample~Documents")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: [],
            category: .iCloud
        )
        #expect(result.matched == true)
    }

    @Test("iCloud match only counts in the iCloud category")
    func iCloudOnlyInICloudCategory() throws {
        let app = try makeApp(bundleID: "com.apple.Pages")
        let entry = URL(fileURLWithPath: "/Library/Preferences/iCloud~com~apple~Pages")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: [],
            category: .preferences
        )
        #expect(result.matched == false)
    }

    @Test("Empty bundle ID is treated as missing")
    func emptyBundleIDIgnored() throws {
        let app = try makeApp(bundleID: "")
        let entry = URL(fileURLWithPath: "/Library/Preferences/random.plist")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: [],
            category: .preferences
        )
        #expect(result.matched == false)
    }

    @Test("Bundle ID matching is case-insensitive")
    func bundleIDCaseInsensitive() throws {
        let app = try makeApp(bundleID: "Com.Example.Sample")
        let entry = URL(fileURLWithPath: "/Library/Preferences/com.example.sample.plist")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: [],
            category: .preferences
        )
        #expect(result.matched == true)
    }

    // MARK: - Name hints

    @Test("Name hint exact match")
    func nameHintExact() throws {
        let app = try makeApp(name: "Rider", bundleID: nil)
        let entry = URL(fileURLWithPath: "/Library/Application Support/Rider")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: ["rider"],
            category: .applicationSupport
        )
        #expect(result.matched == true)
    }

    @Test("Name hint word-boundary match")
    func nameHintWordBoundary() throws {
        let app = try makeApp(name: "Rider", bundleID: nil)
        let entry = URL(fileURLWithPath: "/Library/Application Support/Rider2024.3")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: ["rider"],
            category: .applicationSupport
        )
        #expect(result.matched == true)
    }

    @Test("Name hint rejects letter-following")
    func nameHintRejectsLetterFollowing() throws {
        let app = try makeApp(name: "Rider", bundleID: nil)
        let entry = URL(fileURLWithPath: "/Library/Application Support/RiderProjects")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: ["rider"],
            category: .applicationSupport
        )
        #expect(result.matched == false)
    }

    // MARK: - Team ID (shared group containers)

    @Test("Team-ID-prefixed group container is matched and flagged shared")
    func teamPrefixGroupContainer() throws {
        let app = try makeApp(bundleID: "com.microsoft.Word")
        let entry = URL(fileURLWithPath: "/Library/Group Containers/UBF8T346G9.Office")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: "UBF8T346G9",
            nameHints: [],
            category: .groupContainers
        )
        #expect(result.matched == true)
        #expect(result.shared == true)
    }

    @Test("Team-ID match only applies to Group Containers")
    func teamPrefixOnlyInGroupContainers() throws {
        let app = try makeApp(bundleID: "com.microsoft.Word")
        let entry = URL(fileURLWithPath: "/Library/Preferences/UBF8T346G9.something.plist")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: "UBF8T346G9",
            nameHints: [],
            category: .preferences
        )
        #expect(result.matched == false)
    }

    @Test("No bundle ID and no name hints means no match")
    func nothingMatches() throws {
        let app = try makeApp(name: "X", bundleID: nil)
        let entry = URL(fileURLWithPath: "/Library/Preferences/com.unrelated.foo.plist")
        let result = AppScanner.classify(
            entry: entry,
            app: app,
            teamID: nil,
            nameHints: [],
            category: .preferences
        )
        #expect(result.matched == false)
    }
}

@Suite("AppScanner.wordBoundaryPrefix")
struct AppScannerWordBoundaryTests {

    @Test("Returns true when prefix is followed by digit")
    func digitBoundary() {
        #expect(AppScanner.wordBoundaryPrefix("rider2024.3", prefix: "rider") == true)
    }

    @Test("Returns true when prefix is followed by space")
    func spaceBoundary() {
        #expect(AppScanner.wordBoundaryPrefix("microsoft word data", prefix: "microsoft") == true)
    }

    @Test("Returns true when prefix is followed by dot")
    func dotBoundary() {
        #expect(AppScanner.wordBoundaryPrefix("rider.config", prefix: "rider") == true)
    }

    @Test("Returns true when prefix is followed by dash")
    func dashBoundary() {
        #expect(AppScanner.wordBoundaryPrefix("rider-config", prefix: "rider") == true)
    }

    @Test("Returns false when prefix is followed by letter")
    func letterFollowingFails() {
        #expect(AppScanner.wordBoundaryPrefix("microsoftautoupdate", prefix: "microsoft") == false)
        #expect(AppScanner.wordBoundaryPrefix("riderprojects", prefix: "rider") == false)
    }

    @Test("Returns false when string equals prefix")
    func exactEqualFails() {
        // The function is `prefix` (strictly longer than) — exact-match is
        // handled by a separate branch in classify().
        #expect(AppScanner.wordBoundaryPrefix("rider", prefix: "rider") == false)
    }

    @Test("Returns false for prefixes shorter than 3 chars")
    func shortPrefixRejected() {
        #expect(AppScanner.wordBoundaryPrefix("ab1", prefix: "ab") == false)
    }

    @Test("Returns false when string doesn't start with prefix")
    func nonPrefixFails() {
        #expect(AppScanner.wordBoundaryPrefix("xrider2", prefix: "rider") == false)
    }
}
