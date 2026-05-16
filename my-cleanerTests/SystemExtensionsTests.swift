//
//  SystemExtensionsTests.swift
//  my-cleanerTests
//
//  Pure-logic tests for the system-extensions detector — output
//  parsing, bundle/team attribution, and team-ID validation. The
//  shell-out paths (`listOutput`, `uninstall`) hit `systemextensionsctl`
//  on the running machine and aren't reproducible in CI, so they're
//  not exercised here.
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("SystemExtensions.parseListOutput")
struct SystemExtensionsParseListTests {

    @Test("Empty output → no extensions")
    func empty() {
        #expect(SystemExtensions.parseListOutput("") == [])
    }

    @Test("Output containing only headers and category markers → no extensions")
    func headersOnly() {
        let sample = """
        0 extension(s)
        --- com.apple.system_extension.driver_extension
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        """
        #expect(SystemExtensions.parseListOutput(sample) == [])
    }

    @Test("Parses a single driver-extension row")
    func parsesDriverRow() {
        let sample = """
        1 extension(s)
        --- com.apple.system_extension.driver_extension
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tNA3SMNCJU9\tcom.dropbox.dropbox.fs (190.4.6604)\tFileProvider\t[activated enabled]
        """
        let parsed = SystemExtensions.parseListOutput(sample)
        #expect(parsed.count == 1)
        #expect(parsed.first?.teamID == "NA3SMNCJU9")
        #expect(parsed.first?.bundleID == "com.dropbox.dropbox.fs")
        #expect(parsed.first?.version == "190.4.6604")
        #expect(parsed.first?.displayName == "FileProvider")
    }

    @Test("Parses multi-category output")
    func parsesMultiCategory() {
        let sample = """
        2 extension(s)
        --- com.apple.system_extension.driver_extension
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tNA3SMNCJU9\tcom.dropbox.dropbox.fs (190.4.6604)\tFileProvider\t[activated enabled]
        --- com.apple.system_extension.network_extension
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tWV28HM8KMA\tcom.docker.docker.network-extension (4.39.0)\tNetworkExtension\t[activated enabled]
        """
        let parsed = SystemExtensions.parseListOutput(sample)
        #expect(parsed.count == 2)
        #expect(parsed.map(\.teamID).sorted() == ["NA3SMNCJU9", "WV28HM8KMA"])
        #expect(parsed.map(\.bundleID).contains("com.docker.docker.network-extension"))
    }

    @Test("Drops rows whose third column isn't a valid team ID")
    func rejectsInvalidTeamID() {
        let sample = """
        1 extension(s)
        --- com.apple.system_extension.driver_extension
        *\t*\tnotateam\tcom.foo.bar (1.0)\tFoo\t[activated enabled]
        """
        #expect(SystemExtensions.parseListOutput(sample) == [])
    }

    @Test("Empty bundle ID column → row dropped")
    func emptyBundleID() {
        let sample = "*\t*\tABCDEFGHIJ\t\tFoo\t[activated enabled]"
        #expect(SystemExtensions.parseListOutput(sample) == [])
    }

    @Test("Missing parenthesised version → empty version string, full column is bundle ID")
    func missingVersion() {
        let sample = "*\t*\tABCDEFGHIJ\tcom.foo.bar\tFoo\t[activated enabled]"
        let parsed = SystemExtensions.parseListOutput(sample)
        #expect(parsed.first?.bundleID == "com.foo.bar")
        #expect(parsed.first?.version == "")
    }

    @Test("Display name falls back to bundle ID when column is blank")
    func displayNameFallback() {
        let sample = "*\t*\tABCDEFGHIJ\tcom.foo.bar (1.0)\t\t[activated enabled]"
        #expect(SystemExtensions.parseListOutput(sample).first?.displayName == "com.foo.bar")
    }
}

@Suite("SystemExtensions.matches")
struct SystemExtensionsMatchesTests {

    private let ext = SystemExtensionInfo(
        bundleID: "com.foo.bar.network-extension",
        teamID: "ABCDEFGHIJ",
        displayName: "Foo Network",
        version: "1.0"
    )

    @Test("Exact bundle ID match")
    func exactBundleID() {
        let exact = SystemExtensionInfo(bundleID: "com.foo.bar", teamID: "ABCDEFGHIJ", displayName: "Foo", version: "1.0")
        #expect(SystemExtensions.matches(exact, bundleID: "com.foo.bar", teamID: nil))
    }

    @Test("Child bundle ID match (app bundle is a prefix of the extension bundle)")
    func childBundleID() {
        #expect(SystemExtensions.matches(ext, bundleID: "com.foo.bar", teamID: nil))
    }

    @Test("Bundle ID match is case-insensitive")
    func caseInsensitive() {
        #expect(SystemExtensions.matches(ext, bundleID: "COM.FOO.BAR", teamID: nil))
    }

    @Test("Team ID fallback when bundle IDs don't line up")
    func teamIDFallback() {
        // Real example shape: app is `com.microsoft.edamame.adam`, the
        // ext is `com.microsoft.wdav.epsext` — different parent, but
        // same team ID, so we still attribute it.
        let stranger = SystemExtensionInfo(bundleID: "com.microsoft.wdav.epsext", teamID: "ABCDEFGHIJ", displayName: "Defender", version: "1.0")
        #expect(SystemExtensions.matches(stranger, bundleID: "com.microsoft.edamame.adam", teamID: "ABCDEFGHIJ"))
    }

    @Test("Apple-namespace extensions are unconditionally excluded")
    func appleNamespaceRejected() {
        let apple = SystemExtensionInfo(bundleID: "com.apple.driver.foo", teamID: "ABCDEFGHIJ", displayName: "Apple", version: "1.0")
        #expect(!SystemExtensions.matches(apple, bundleID: "com.apple.driver.foo", teamID: "ABCDEFGHIJ"))
    }

    @Test("Unrelated bundle and unrelated team → rejected")
    func unrelatedRejected() {
        #expect(!SystemExtensions.matches(ext, bundleID: "com.unrelated.app", teamID: "XYZ1234567"))
    }

    @Test("Nil bundle ID with matching team still attributes")
    func nilBundleWithTeam() {
        #expect(SystemExtensions.matches(ext, bundleID: nil, teamID: "ABCDEFGHIJ"))
    }

    @Test("Nil bundle and nil team → rejected")
    func bothNilRejected() {
        #expect(!SystemExtensions.matches(ext, bundleID: nil, teamID: nil))
    }
}

@Suite("SystemExtensions.splitBundleAndVersion")
struct SystemExtensionsSplitTests {

    @Test("Splits `bundle (version)` into two parts")
    func splitsBoth() {
        let (bid, ver) = SystemExtensions.splitBundleAndVersion("com.foo.bar (1.2.3)")
        #expect(bid == "com.foo.bar")
        #expect(ver == "1.2.3")
    }

    @Test("No parens → input is bundle, version empty")
    func noParens() {
        let (bid, ver) = SystemExtensions.splitBundleAndVersion("com.foo.bar")
        #expect(bid == "com.foo.bar")
        #expect(ver == "")
    }

    @Test("Multi-segment version preserved")
    func multiSegment() {
        let (bid, ver) = SystemExtensions.splitBundleAndVersion("com.foo.bar (190.4.6604)")
        #expect(bid == "com.foo.bar")
        #expect(ver == "190.4.6604")
    }
}

@Suite("SystemExtensions.isTeamID")
struct SystemExtensionsIsTeamIDTests {

    @Test("Ten uppercase alphanumerics accepted")
    func validTeamID() {
        #expect(SystemExtensions.isTeamID("UBF8T346G9"))
        #expect(SystemExtensions.isTeamID("ABCDEFGHIJ"))
        #expect(SystemExtensions.isTeamID("0123456789"))
    }

    @Test("Wrong length rejected")
    func wrongLength() {
        #expect(!SystemExtensions.isTeamID("UBF8T346G"))   // 9 chars
        #expect(!SystemExtensions.isTeamID("UBF8T346G99")) // 11 chars
        #expect(!SystemExtensions.isTeamID(""))
    }

    @Test("Lowercase rejected")
    func lowercaseRejected() {
        #expect(!SystemExtensions.isTeamID("ubf8t346g9"))
    }

    @Test("Non-alphanumeric rejected")
    func nonAlnumRejected() {
        #expect(!SystemExtensions.isTeamID("UBF8T-46G9"))
        #expect(!SystemExtensions.isTeamID("UBF8T346G."))
    }
}

@Suite("SystemExtensions.isAppleNamespace")
struct SystemExtensionsIsAppleNamespaceTests {

    @Test("com.apple.* matched")
    func appleMatched() {
        #expect(SystemExtensions.isAppleNamespace("com.apple.driver.foo"))
        #expect(SystemExtensions.isAppleNamespace("COM.APPLE.driver.foo"))
    }

    @Test("Third-party not matched")
    func thirdParty() {
        #expect(!SystemExtensions.isAppleNamespace("com.docker.docker"))
        #expect(!SystemExtensions.isAppleNamespace("com.microsoft.wdav.epsext"))
    }

    @Test("`apple` outside reverse-DNS shape not matched")
    func bareAppleNotMatched() {
        // We deliberately match only `com.apple.` — not `apple.` or
        // `com.applesoftware.*` — so the false-positive surface is small.
        #expect(!SystemExtensions.isAppleNamespace("com.applesoftware.foo"))
        #expect(!SystemExtensions.isAppleNamespace("apple.foo"))
    }
}
