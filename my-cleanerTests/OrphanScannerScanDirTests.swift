//
//  OrphanScannerScanDirTests.swift
//  my-cleanerTests
//
//  Tests for OrphanScanner.scanDir against a synthetic directory tree.
//  Each test seeds a temp directory with a category of orphan-shaped
//  entries, then provides controlled sets of "installed" bundle/team/
//  vendor identifiers and asserts the resulting bundle-ID grouping.
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("OrphanScanner.scanDir")
struct OrphanScannerScanDirTests {

    @Test("Bundle ID that matches an installed app is not surfaced")
    func installedBundleIDExcluded() throws {
        let dir = try TempDir(label: "orphan-installed")
        let containers = try dir.makeDir(at: "Containers")
        _ = try dir.makeDir(at: "Containers/com.example.installed")
        _ = try dir.makeFile(at: "Containers/com.example.installed/Data/blob.bin")

        var byBundleID: [String: [RelatedItem]] = [:]
        OrphanScanner.scanDir(
            containers,
            category: .containers,
            installedBundleIDs: ["com.example.installed"],
            installedTeamIDs: [],
            installedVendors: [],
            into: &byBundleID
        )
        #expect(byBundleID["com.example.installed"] == nil)
    }

    @Test("Child of an installed bundle ID is not surfaced")
    func installedChildExcluded() throws {
        let dir = try TempDir(label: "orphan-child")
        let containers = try dir.makeDir(at: "Containers")
        _ = try dir.makeDir(at: "Containers/com.example.installed.helper")
        _ = try dir.makeFile(at: "Containers/com.example.installed.helper/x.bin")

        var byBundleID: [String: [RelatedItem]] = [:]
        OrphanScanner.scanDir(
            containers,
            category: .containers,
            installedBundleIDs: ["com.example.installed"],
            installedTeamIDs: [],
            installedVendors: [],
            into: &byBundleID
        )
        #expect(byBundleID["com.example.installed.helper"] == nil)
    }

    @Test("Strict ancestor of an installed bundle ID is not surfaced")
    func installedAncestorExcluded() throws {
        let dir = try TempDir(label: "orphan-ancestor")
        let containers = try dir.makeDir(at: "Containers")
        _ = try dir.makeDir(at: "Containers/com.docker")
        _ = try dir.makeFile(at: "Containers/com.docker/x.bin")

        var byBundleID: [String: [RelatedItem]] = [:]
        OrphanScanner.scanDir(
            containers,
            category: .containers,
            installedBundleIDs: ["com.docker.docker"],
            installedTeamIDs: [],
            installedVendors: [],
            into: &byBundleID
        )
        #expect(byBundleID["com.docker"] == nil)
    }

    @Test("Sibling vendor namespace match is excluded")
    func vendorNamespaceExcluded() throws {
        let dir = try TempDir(label: "orphan-vendor")
        let containers = try dir.makeDir(at: "Containers")
        _ = try dir.makeDir(at: "Containers/com.viber.ViberPC")
        _ = try dir.makeFile(at: "Containers/com.viber.ViberPC/x.bin")

        var byBundleID: [String: [RelatedItem]] = [:]
        OrphanScanner.scanDir(
            containers,
            category: .containers,
            installedBundleIDs: [],
            installedTeamIDs: [],
            installedVendors: ["com.viber"],
            into: &byBundleID
        )
        #expect(byBundleID["com.viber.ViberPC"] == nil)
    }

    @Test("Apple namespace is always excluded")
    func appleReservedExcluded() throws {
        let dir = try TempDir(label: "orphan-apple")
        let containers = try dir.makeDir(at: "Containers")
        _ = try dir.makeDir(at: "Containers/com.apple.something")
        _ = try dir.makeFile(at: "Containers/com.apple.something/x.bin")

        var byBundleID: [String: [RelatedItem]] = [:]
        OrphanScanner.scanDir(
            containers,
            category: .containers,
            installedBundleIDs: [],
            installedTeamIDs: [],
            installedVendors: [],
            into: &byBundleID
        )
        #expect(byBundleID["com.apple.something"] == nil)
    }

    @Test("Team-prefix Group Container is excluded when the team still ships an installed app")
    func teamPrefixInstalled() throws {
        let dir = try TempDir(label: "orphan-team-installed")
        let groups = try dir.makeDir(at: "Group Containers")
        _ = try dir.makeDir(at: "Group Containers/UBF8T346G9.Office")
        _ = try dir.makeFile(at: "Group Containers/UBF8T346G9.Office/x.bin")

        var byBundleID: [String: [RelatedItem]] = [:]
        OrphanScanner.scanDir(
            groups,
            category: .groupContainers,
            installedBundleIDs: [],
            installedTeamIDs: ["UBF8T346G9"],
            installedVendors: [],
            into: &byBundleID
        )
        #expect(byBundleID["UBF8T346G9.Office"] == nil)
    }

    @Test("Team-prefix Group Container surfaces when no app from that team is installed")
    func teamPrefixSurfaced() throws {
        let dir = try TempDir(label: "orphan-team-orphan")
        let groups = try dir.makeDir(at: "Group Containers")
        _ = try dir.makeDir(at: "Group Containers/ABCDE12345.Office")
        _ = try dir.makeFile(at: "Group Containers/ABCDE12345.Office/x.bin")

        var byBundleID: [String: [RelatedItem]] = [:]
        OrphanScanner.scanDir(
            groups,
            category: .groupContainers,
            installedBundleIDs: [],
            installedTeamIDs: [],
            installedVendors: [],
            into: &byBundleID
        )
        // launchServicesKnows likely returns false for a fabricated team ID,
        // so this should be surfaced.
        #expect(byBundleID["ABCDE12345.Office"] != nil)
    }

    @Test("group. prefix is normalised to the inner bundle ID")
    func groupPrefixNormalised() throws {
        let dir = try TempDir(label: "orphan-group-prefix")
        let groups = try dir.makeDir(at: "Group Containers")
        _ = try dir.makeDir(at: "Group Containers/group.com.totally.unique.testing")
        _ = try dir.makeFile(at: "Group Containers/group.com.totally.unique.testing/x.bin")

        var byBundleID: [String: [RelatedItem]] = [:]
        OrphanScanner.scanDir(
            groups,
            category: .groupContainers,
            installedBundleIDs: [],
            installedTeamIDs: [],
            installedVendors: [],
            into: &byBundleID
        )
        // launchServicesKnows is unlikely to recognise this fabricated ID.
        #expect(byBundleID["com.totally.unique.testing"] != nil)
    }

    @Test("iCloud entries are flagged shared")
    func iCloudShared() throws {
        let dir = try TempDir(label: "orphan-icloud-shared")
        let mobile = try dir.makeDir(at: "Mobile Documents")
        _ = try dir.makeDir(at: "Mobile Documents/iCloud~com~totally~unique~test")
        _ = try dir.makeFile(at: "Mobile Documents/iCloud~com~totally~unique~test/x.bin")

        var byBundleID: [String: [RelatedItem]] = [:]
        OrphanScanner.scanDir(
            mobile,
            category: .iCloud,
            installedBundleIDs: [],
            installedTeamIDs: [],
            installedVendors: [],
            into: &byBundleID
        )
        let items = try #require(byBundleID["com.totally.unique.test"])
        #expect(items.allSatisfy { $0.isShared })
    }

    @Test("Non-bundle-ID-shaped entries are silently skipped")
    func nonBundleIDsSkipped() throws {
        let dir = try TempDir(label: "orphan-non-bid")
        let containers = try dir.makeDir(at: "Containers")
        _ = try dir.makeDir(at: "Containers/RandomFolderName")
        _ = try dir.makeFile(at: "Containers/RandomFolderName/x.bin")

        var byBundleID: [String: [RelatedItem]] = [:]
        OrphanScanner.scanDir(
            containers,
            category: .containers,
            installedBundleIDs: [],
            installedTeamIDs: [],
            installedVendors: [],
            into: &byBundleID
        )
        #expect(byBundleID.isEmpty)
    }

    @Test("Missing directory is a no-op")
    func missingDirectory() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        var byBundleID: [String: [RelatedItem]] = [:]
        OrphanScanner.scanDir(
            url,
            category: .containers,
            installedBundleIDs: [],
            installedTeamIDs: [],
            installedVendors: [],
            into: &byBundleID
        )
        #expect(byBundleID.isEmpty)
    }
}
