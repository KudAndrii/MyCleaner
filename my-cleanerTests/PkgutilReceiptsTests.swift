//
//  PkgutilReceiptsTests.swift
//  my-cleanerTests
//
//  Pure-logic tests for the pkgutil receipt scanner — receipt-to-bundle
//  attribution and the shell-output line parser. The shell-out paths
//  (`listPackageIDs`, `filePaths(forPackage:)`) hit the real receipt
//  database and aren't reproducible in CI, so they're exercised only
//  indirectly through the integration via `AppScanner`.
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("PkgutilReceipts.packageMatches")
struct PkgutilReceiptsPackageMatchesTests {

    @Test("Exact pkgID equals bundle ID")
    func exactMatch() {
        #expect(PkgutilReceipts.packageMatches("com.foo.bar", bundleID: "com.foo.bar"))
    }

    @Test("pkgID ends with .pkg suffix")
    func pkgSuffix() {
        #expect(PkgutilReceipts.packageMatches("com.foo.bar.pkg", bundleID: "com.foo.bar"))
    }

    @Test("Child receipt — pkgID extends bundle ID with another segment")
    func childPrefix() {
        #expect(PkgutilReceipts.packageMatches("com.foo.bar.installer", bundleID: "com.foo.bar"))
        #expect(PkgutilReceipts.packageMatches("com.foo.bar.licenseHelper", bundleID: "com.foo.bar"))
    }

    @Test("Comparison is case-insensitive")
    func caseInsensitive() {
        #expect(PkgutilReceipts.packageMatches("COM.Foo.Bar", bundleID: "com.foo.bar"))
        #expect(PkgutilReceipts.packageMatches("com.foo.bar", bundleID: "COM.FOO.BAR"))
    }

    @Test("Unrelated pkgID rejected")
    func differentRejected() {
        #expect(!PkgutilReceipts.packageMatches("com.baz.quux", bundleID: "com.foo.bar"))
    }

    @Test("Sibling under same vendor rejected — no vendor-only match")
    func siblingVendorRejected() {
        // `com.foo.bar` and `com.foo.other` are siblings; we deliberately
        // don't accept a vendor-namespace match because it pulls in
        // unrelated apps from the same developer.
        #expect(!PkgutilReceipts.packageMatches("com.foo.other", bundleID: "com.foo.bar"))
    }

    @Test("Prefix without a trailing dot doesn't match")
    func prefixNeedsDot() {
        // `com.foo.barbaz` must not match `com.foo.bar` — only `com.foo.bar.X` does.
        #expect(!PkgutilReceipts.packageMatches("com.foo.barbaz", bundleID: "com.foo.bar"))
    }

    @Test("Empty bundle ID rejects everything")
    func emptyBundleID() {
        #expect(!PkgutilReceipts.packageMatches("com.foo.bar", bundleID: ""))
    }
}

@Suite("PkgutilReceipts.parseLines")
struct PkgutilReceiptsParseLinesTests {

    @Test("Splits on newline")
    func splitsNewline() {
        #expect(PkgutilReceipts.parseLines("one\ntwo\nthree") == ["one", "two", "three"])
    }

    @Test("Drops empty lines")
    func dropsEmpty() {
        #expect(PkgutilReceipts.parseLines("one\n\ntwo\n") == ["one", "two"])
    }

    @Test("Drops the bare `.` root marker that pkgutil --files emits")
    func dropsRootDot() {
        #expect(PkgutilReceipts.parseLines(".\nLibrary\nLibrary/foo") == ["Library", "Library/foo"])
    }

    @Test("Trims whitespace around each line")
    func trims() {
        #expect(PkgutilReceipts.parseLines("  one  \n\ttwo\t") == ["one", "two"])
    }

    @Test("Empty input → empty array")
    func empty() {
        #expect(PkgutilReceipts.parseLines("") == [])
    }
}

@Suite("PkgutilReceipts.sharedDirectories")
struct PkgutilReceiptsSharedDirectoriesTests {

    @Test("Includes the bare root")
    func includesRoot() {
        #expect(PkgutilReceipts.sharedDirectories.contains("/"))
    }

    @Test("Includes top-level /Library and common subdirs")
    func includesLibraryRoots() {
        #expect(PkgutilReceipts.sharedDirectories.contains("/Library"))
        #expect(PkgutilReceipts.sharedDirectories.contains("/Library/LaunchDaemons"))
        #expect(PkgutilReceipts.sharedDirectories.contains("/Library/PrivilegedHelperTools"))
    }

    @Test("Includes /usr/local roots")
    func includesUsrLocal() {
        #expect(PkgutilReceipts.sharedDirectories.contains("/usr/local"))
        #expect(PkgutilReceipts.sharedDirectories.contains("/usr/local/bin"))
    }

    @Test("Does NOT include a fully-qualified file path")
    func doesNotIncludeFiles() {
        // Concrete payloads like `/Library/LaunchDaemons/com.foo.bar.plist`
        // must survive the shared-directory filter so the user can trash them.
        #expect(!PkgutilReceipts.sharedDirectories.contains("/Library/LaunchDaemons/com.foo.bar.plist"))
        #expect(!PkgutilReceipts.sharedDirectories.contains("/usr/local/bin/foo"))
    }
}
