//
//  OrphanScannerHelpersTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("OrphanScanner.looksLikeBundleID")
struct LooksLikeBundleIDTests {

    @Test(
        "Accepts well-formed bundle IDs",
        arguments: [
            "com.example.foo",
            "com.example.Foo.Helper",
            "net.whatsapp.WhatsApp",
            "UBF8T346G9.Office",
            "io.app.x",
        ]
    )
    func accepts(bid: String) {
        #expect(OrphanScanner.looksLikeBundleID(bid) == true)
    }

    @Test(
        "Rejects malformed strings",
        arguments: [
            "",                  // empty
            "no-dot",            // no dot
            ".cache",            // leading dot
            "trailing.",         // trailing dot
            "0.5",               // first segment doesn't start with letter
            "a.b",               // first segment is 1 char
            "com..example",      // empty component
            "with space.foo",    // space
            "com/example.foo",   // slash
            ".",                 // dot only
        ]
    )
    func rejects(bid: String) {
        #expect(OrphanScanner.looksLikeBundleID(bid) == false)
    }
}

@Suite("OrphanScanner.candidateBundleID")
struct CandidateBundleIDTests {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/" + name)
    }

    // MARK: - Generic categories (containers, scripts, saved state, cookies, webkit)

    @Test("Container directory name is the bundle ID")
    func containerName() {
        let result = OrphanScanner.candidateBundleID(
            for: url("com.example.foo"),
            category: .containers
        )
        #expect(result == "com.example.foo")
    }

    @Test("Saved Application State strips .savedState suffix")
    func savedStateSuffix() {
        let result = OrphanScanner.candidateBundleID(
            for: url("com.example.foo.savedState"),
            category: .savedState
        )
        #expect(result == "com.example.foo")
    }

    @Test("Cookies strip .binarycookies suffix")
    func binarycookiesSuffix() {
        let result = OrphanScanner.candidateBundleID(
            for: url("com.example.foo.binarycookies"),
            category: .cookies
        )
        #expect(result == "com.example.foo")
    }

    @Test("Non-bundle-ID-shaped names return nil")
    func nonBundleIDName() {
        let result = OrphanScanner.candidateBundleID(
            for: url("NotABundleID"),
            category: .containers
        )
        #expect(result == nil)
    }

    // MARK: - Preferences

    @Test("Preferences with .plist suffix")
    func prefsPlist() {
        let result = OrphanScanner.candidateBundleID(
            for: url("com.example.foo.plist"),
            category: .preferences
        )
        #expect(result == "com.example.foo")
    }

    @Test("ByHost preferences strip UUID")
    func prefsByHost() {
        let uuid = "ABCDEFAB-1234-5678-9012-ABCDEF123456"
        let result = OrphanScanner.candidateBundleID(
            for: url("com.example.foo.\(uuid).plist"),
            category: .preferences
        )
        #expect(result == "com.example.foo")
    }

    @Test("Preferences without .plist return nil")
    func prefsNoPlist() {
        let result = OrphanScanner.candidateBundleID(
            for: url("com.example.foo"),
            category: .preferences
        )
        #expect(result == nil)
    }

    // MARK: - Group containers

    @Test("group. prefix strip")
    func groupPrefix() {
        let result = OrphanScanner.candidateBundleID(
            for: url("group.com.example.foo"),
            category: .groupContainers
        )
        #expect(result == "com.example.foo")
    }

    @Test("vgroup. prefix strip (Viber variant)")
    func vgroupPrefix() {
        let result = OrphanScanner.candidateBundleID(
            for: url("vgroup.com.viber.foo"),
            category: .groupContainers
        )
        #expect(result == "com.viber.foo")
    }

    @Test("systemgroup. prefix strip (system-owned variant)")
    func systemgroupPrefix() {
        let result = OrphanScanner.candidateBundleID(
            for: url("systemgroup.com.apple.icloud.searchpartyd.sharedsettings"),
            category: .groupContainers
        )
        #expect(result == "com.apple.icloud.searchpartyd.sharedsettings")
    }

    @Test("Team-prefix group container is kept whole")
    func teamPrefixKeptWhole() {
        let result = OrphanScanner.candidateBundleID(
            for: url("UBF8T346G9.Office"),
            category: .groupContainers
        )
        #expect(result == "UBF8T346G9.Office")
    }

    @Test("Group prefix strip is case-insensitive")
    func groupPrefixCaseInsensitive() {
        let result = OrphanScanner.candidateBundleID(
            for: url("Group.com.example.foo"),
            category: .groupContainers
        )
        #expect(result == "com.example.foo")
    }

    // MARK: - iCloud

    @Test("iCloud tildes get converted back to dots")
    func iCloudConversion() {
        let result = OrphanScanner.candidateBundleID(
            for: url("iCloud~com~example~foo"),
            category: .iCloud
        )
        #expect(result == "com.example.foo")
    }

    @Test("iCloud without iCloud~ prefix returns nil")
    func iCloudMissingPrefix() {
        let result = OrphanScanner.candidateBundleID(
            for: url("com.example.foo"),
            category: .iCloud
        )
        #expect(result == nil)
    }
}

@Suite("OrphanScanner.stripByHostUUID")
struct StripByHostUUIDTests {

    @Test("Strips a trailing UUID")
    func stripsUUID() {
        let s = "com.example.foo.ABCDEFAB-1234-5678-9012-ABCDEF123456"
        #expect(OrphanScanner.stripByHostUUID(s) == "com.example.foo")
    }

    @Test("Leaves strings without a UUID tail untouched")
    func leavesAlone() {
        #expect(OrphanScanner.stripByHostUUID("com.example.foo") == "com.example.foo")
        #expect(OrphanScanner.stripByHostUUID("com.example.foo.notuuid") == "com.example.foo.notuuid")
    }

    @Test("Rejects 36-char tail without the right dash count")
    func wrongDashCount() {
        // 36 chars but no dashes — must not match.
        let fake = String(repeating: "a", count: 36)
        let s = "com.example.foo.\(fake)"
        #expect(OrphanScanner.stripByHostUUID(s) == s)
    }
}

@Suite("OrphanScanner.stripKnownSuffix")
struct StripKnownSuffixTests {

    @Test("Strips .savedState")
    func stripsSavedState() {
        #expect(OrphanScanner.stripKnownSuffix("com.foo.bar.savedState") == "com.foo.bar")
    }

    @Test("Strips .binarycookies")
    func stripsBinarycookies() {
        #expect(OrphanScanner.stripKnownSuffix("com.foo.bar.binarycookies") == "com.foo.bar")
    }

    @Test("Leaves unrecognised suffixes intact")
    func leavesOthers() {
        #expect(OrphanScanner.stripKnownSuffix("com.foo.bar.plist") == "com.foo.bar.plist")
        #expect(OrphanScanner.stripKnownSuffix("com.foo.bar") == "com.foo.bar")
    }
}

@Suite("OrphanScanner.teamIDPrefix")
struct TeamIDPrefixTests {

    @Test("Extracts a 10-char uppercase alphanumeric team ID")
    func extracts() {
        #expect(OrphanScanner.teamIDPrefix(of: "UBF8T346G9.Office") == "UBF8T346G9")
    }

    @Test("Rejects when prefix is not exactly 10 chars")
    func rejectsLength() {
        #expect(OrphanScanner.teamIDPrefix(of: "ABC.Office") == nil)
        #expect(OrphanScanner.teamIDPrefix(of: "ABCDEFGHIJK.Office") == nil)
    }

    @Test("Rejects when prefix contains lowercase letters")
    func rejectsLowercase() {
        #expect(OrphanScanner.teamIDPrefix(of: "ubf8t346g9.Office") == nil)
    }

    @Test("Rejects strings without a dot")
    func rejectsNoDot() {
        #expect(OrphanScanner.teamIDPrefix(of: "UBF8T346G9") == nil)
    }
}

@Suite("OrphanScanner.vendorNamespace")
struct VendorNamespaceTests {

    @Test("Returns the first two reverse-DNS segments")
    func twoSegments() {
        #expect(OrphanScanner.vendorNamespace(of: "com.docker.docker") == "com.docker")
        #expect(OrphanScanner.vendorNamespace(of: "net.whatsapp.WhatsApp") == "net.whatsapp")
    }

    @Test("Lowercases the result")
    func lowercases() {
        #expect(OrphanScanner.vendorNamespace(of: "Com.Example.Foo") == "com.example")
    }

    @Test("Returns nil for too-short identifiers")
    func tooShort() {
        #expect(OrphanScanner.vendorNamespace(of: "noDot") == nil)
        #expect(OrphanScanner.vendorNamespace(of: "x") == nil)
    }
}

@Suite("OrphanScanner.isAppleReserved")
struct IsAppleReservedTests {

    @Test(
        "Matches Apple-namespace bundle IDs",
        arguments: [
            "com.apple.Mail",
            "com.apple.dock",
            "apple",
            "apple.foo",
            "COM.APPLE.SOMETHING",
            // CUPS — Apple-owned since 2007.
            "org.cups.printers",
            "org.cups.PrintingPrefs",
            // Shortcuts — inherited from the Workflow acquisition.
            "is.workflow.shortcuts",
            "is.workflow.my.app",
        ]
    )
    func matches(bid: String) {
        #expect(OrphanScanner.isAppleReserved(bid) == true)
    }

    @Test(
        "Doesn't match non-Apple bundle IDs",
        arguments: [
            "com.example.foo",
            "net.whatsapp.WhatsApp",
            "com.appleseed.foo",   // accidental substring
            "org.cupsoftea.foo",   // accidental substring on cups
            "is.workflower.foo",   // accidental substring on workflow
        ]
    )
    func doesntMatch(bid: String) {
        #expect(OrphanScanner.isAppleReserved(bid) == false)
    }
}
