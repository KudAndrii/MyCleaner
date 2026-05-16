//
//  LoginItemsTests.swift
//  my-cleanerTests
//
//  Pure-logic tests for the SMAppService login-item detector — the
//  block-structured `sfltool dumpbtm` parser and the bundle/team
//  attribution predicate. The shell-out path (`dumpOutput`) hits
//  `sfltool` on the running machine and isn't reproducible in CI, so
//  it's not exercised here.
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("LoginItems.parseDumpOutput")
struct LoginItemsParseTests {

    @Test("Empty output → no items")
    func empty() {
        #expect(LoginItems.parseDumpOutput("") == [])
    }

    @Test("Output with only a header → no items")
    func headerOnly() {
        let sample = """
        Sept 16 2025 22:14:23
        Total Items: 0
        Pruning disabled: false
        """
        #expect(LoginItems.parseDumpOutput(sample) == [])
    }

    @Test("Parses a single block with lowercase keys")
    func parsesLowercaseBlock() {
        let sample = """
        UUID: ABCDEF12-1234-1234-1234-123456789012
        type: legacy (0x4)
        disposition: [enabled, allowed, visible, not notified]
        identifier: com.example.helper
        url: file:///Applications/Example.app/Contents/Library/LoginItems/Helper.app/
        generation: 0
        parent identifier: com.example.app
        parent url: file:///Applications/Example.app/
        """
        let parsed = LoginItems.parseDumpOutput(sample)
        #expect(parsed.count == 1)
        #expect(parsed.first?.bundleID == "com.example.helper")
        #expect(parsed.first?.parentBundleID == "com.example.app")
        #expect(parsed.first?.isEnabled == true)
        #expect(parsed.first?.url == "file:///Applications/Example.app/Contents/Library/LoginItems/Helper.app/")
    }

    @Test("Parses keys in mixed/upper case (older macOS dump shape)")
    func parsesUppercaseKeys() {
        let sample = """
        UUID: ABCDEF12-1234-1234-1234-123456789012
        Type: agent (0x10)
        Disposition: [disabled, allowed, visible, not notified]
        Identifier: com.example.daemon
        Parent Identifier: com.example.app
        Name: "Example Daemon"
        """
        let parsed = LoginItems.parseDumpOutput(sample)
        #expect(parsed.first?.bundleID == "com.example.daemon")
        #expect(parsed.first?.displayName == "Example Daemon")
        #expect(parsed.first?.isEnabled == false)
    }

    @Test("Parses multiple blocks separated by blank lines")
    func parsesMultipleBlocks() {
        let sample = """
        identifier: com.example.helper
        disposition: [enabled, allowed, visible, not notified]
        parent identifier: com.example.app

        identifier: com.other.helper
        disposition: [disabled, allowed, visible, not notified]
        parent identifier: com.other.app
        """
        let parsed = LoginItems.parseDumpOutput(sample)
        #expect(parsed.count == 2)
        #expect(parsed.map(\.bundleID).sorted() == ["com.example.helper", "com.other.helper"])
    }

    @Test("Blocks without an identifier line are dropped")
    func dropsBlocksWithoutIdentifier() {
        let sample = """
        UUID: ABC
        type: legacy

        identifier: com.example.helper
        disposition: [enabled, allowed, visible, not notified]
        """
        let parsed = LoginItems.parseDumpOutput(sample)
        #expect(parsed.count == 1)
    }

    @Test("(null) team identifier becomes nil")
    func nullTeamID() {
        let sample = """
        identifier: com.example.helper
        team identifier: (null)
        disposition: [enabled, allowed, visible, not notified]
        """
        #expect(LoginItems.parseDumpOutput(sample).first?.teamID == nil)
    }

    @Test("Display name defaults to bundle ID when no name line")
    func displayNameFallback() {
        let sample = """
        identifier: com.example.helper
        disposition: [enabled, allowed, visible, not notified]
        """
        #expect(LoginItems.parseDumpOutput(sample).first?.displayName == "com.example.helper")
    }

    @Test("Disposition without `disabled` keyword → isEnabled true")
    func enabledDisposition() {
        let sample = """
        identifier: com.example.helper
        disposition: [enabled, allowed, visible, not notified]
        """
        #expect(LoginItems.parseDumpOutput(sample).first?.isEnabled == true)
    }

    @Test("Quoted display name has the quotes stripped")
    func quotedName() {
        let sample = """
        identifier: com.example.helper
        name: "Example Helper"
        """
        #expect(LoginItems.parseDumpOutput(sample).first?.displayName == "Example Helper")
    }

    @Test("Team identifier captured when present")
    func teamIDCaptured() {
        let sample = """
        identifier: com.example.helper
        team identifier: ABCDEFGHIJ
        """
        #expect(LoginItems.parseDumpOutput(sample).first?.teamID == "ABCDEFGHIJ")
    }
}

@Suite("LoginItems.matches")
struct LoginItemsMatchesTests {

    private let appBundle = "com.example.app"

    private func makeItem(
        bundleID: String,
        parent: String? = nil,
        teamID: String? = nil
    ) -> LoginItemInfo {
        LoginItemInfo(
            bundleID: bundleID,
            parentBundleID: parent,
            teamID: teamID,
            displayName: bundleID,
            url: "",
            isEnabled: true
        )
    }

    @Test("Helper bundle ID equals app bundle ID")
    func exactHelper() {
        let item = makeItem(bundleID: "com.example.app")
        #expect(LoginItems.matches(item, bundleID: appBundle, teamID: nil))
    }

    @Test("Helper bundle ID is a child of the app bundle ID")
    func childHelper() {
        let item = makeItem(bundleID: "com.example.app.helper")
        #expect(LoginItems.matches(item, bundleID: appBundle, teamID: nil))
    }

    @Test("Parent identifier matches the app's bundle ID")
    func parentMatches() {
        let item = makeItem(bundleID: "com.example.helper", parent: "com.example.app")
        #expect(LoginItems.matches(item, bundleID: appBundle, teamID: nil))
    }

    @Test("Parent identifier is an ancestor of the app's bundle ID")
    func parentAncestor() {
        // Some apps register a helper under a shorter parent ID
        // (`com.example`) and the dropped app's ID is the longer
        // `com.example.app`.
        let item = makeItem(bundleID: "com.example.helper", parent: "com.example")
        #expect(LoginItems.matches(item, bundleID: appBundle, teamID: nil))
    }

    @Test("Comparison is case-insensitive")
    func caseInsensitive() {
        let item = makeItem(bundleID: "COM.Example.Helper", parent: "COM.Example.App")
        #expect(LoginItems.matches(item, bundleID: appBundle, teamID: nil))
    }

    @Test("Team ID fallback when neither bundle ID lines up")
    func teamIDFallback() {
        let item = makeItem(bundleID: "com.totally-unrelated.helper", teamID: "ABCDEFGHIJ")
        #expect(LoginItems.matches(item, bundleID: appBundle, teamID: "ABCDEFGHIJ"))
    }

    @Test("Apple-namespace helper unconditionally rejected")
    func appleHelperRejected() {
        let item = makeItem(bundleID: "com.apple.AccountPolicyHelper", teamID: "ABCDEFGHIJ")
        #expect(!LoginItems.matches(item, bundleID: "com.apple.AccountPolicyHelper", teamID: "ABCDEFGHIJ"))
    }

    @Test("Apple-namespace parent unconditionally rejected")
    func appleParentRejected() {
        let item = makeItem(bundleID: "com.example.helper", parent: "com.apple.dock", teamID: "ABCDEFGHIJ")
        #expect(!LoginItems.matches(item, bundleID: appBundle, teamID: "ABCDEFGHIJ"))
    }

    @Test("No bundle and no team → no match")
    func bothMissing() {
        let item = makeItem(bundleID: "com.example.helper")
        #expect(!LoginItems.matches(item, bundleID: nil, teamID: nil))
    }

    @Test("Sibling helper rejected when only the vendor prefix overlaps")
    func siblingRejected() {
        // `com.example.helper` should NOT match `com.example.app` —
        // we require equality or `<app>.X`, not a vendor-namespace
        // sibling.
        let item = makeItem(bundleID: "com.example.helper")
        #expect(!LoginItems.matches(item, bundleID: appBundle, teamID: nil))
    }
}
