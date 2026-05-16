//
//  CleanupActionsTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import my_cleaner

@Suite("CleanupActions.bootoutTarget")
struct BootoutTargetTests {

    @Test("System LaunchDaemons use the system domain")
    func systemDomain() {
        let url = URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.helper.plist")
        let target = CleanupActions.bootoutTarget(
            for: url,
            homePrefix: "/Users/jane",
            uid: 501
        )
        #expect(target == "system/com.example.helper")
    }

    @Test("User LaunchAgents under home use the gui/<uid> domain")
    func homeGUIDomain() {
        let url = URL(fileURLWithPath: "/Users/jane/Library/LaunchAgents/com.example.agent.plist")
        let target = CleanupActions.bootoutTarget(
            for: url,
            homePrefix: "/Users/jane",
            uid: 501
        )
        #expect(target == "gui/501/com.example.agent")
    }

    @Test("/Library LaunchAgents also use gui/<uid>")
    func librarygGUIDomain() {
        let url = URL(fileURLWithPath: "/Library/LaunchAgents/com.example.agent.plist")
        let target = CleanupActions.bootoutTarget(
            for: url,
            homePrefix: "/Users/jane",
            uid: 501
        )
        #expect(target == "gui/501/com.example.agent")
    }

    @Test("Label is derived from the filename minus the .plist extension")
    func labelFromFilename() {
        let url = URL(fileURLWithPath: "/Users/jane/Library/LaunchAgents/com.foo.bar.plist")
        let target = CleanupActions.bootoutTarget(
            for: url,
            homePrefix: "/Users/jane",
            uid: 1000
        )
        #expect(target.hasSuffix("/com.foo.bar"))
    }
}
