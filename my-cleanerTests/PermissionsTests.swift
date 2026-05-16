//
//  PermissionsTests.swift
//  my-cleanerTests
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("Permissions.isPermissionError")
struct IsPermissionErrorTests {

    @Test("POSIX EPERM is treated as a permission error")
    func posixEPERM() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        #expect(Permissions.isPermissionError(err) == true)
    }

    @Test("POSIX EACCES is treated as a permission error")
    func posixEACCES() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        #expect(Permissions.isPermissionError(err) == true)
    }

    @Test("POSIX ENOENT is NOT a permission error")
    func posixENOENT() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        #expect(Permissions.isPermissionError(err) == false)
    }

    @Test("NSFileReadNoPermissionError is a permission error")
    func cocoaRead() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        #expect(Permissions.isPermissionError(err) == true)
    }

    @Test("NSFileWriteNoPermissionError is a permission error")
    func cocoaWrite() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        #expect(Permissions.isPermissionError(err) == true)
    }

    @Test("Other Cocoa errors are not permission errors")
    func cocoaOther() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        #expect(Permissions.isPermissionError(err) == false)
    }

    @Test("Unrelated domains are not permission errors")
    func unrelatedDomain() {
        let err = NSError(domain: "FakeDomain", code: 13)
        #expect(Permissions.isPermissionError(err) == false)
    }
}

@Suite("PermissionKind")
struct PermissionKindTests {

    @Test("Every kind has a non-empty title, symbol, explanation, id")
    func nonEmptyStrings() {
        for kind in PermissionKind.allCases {
            #expect(!kind.title.isEmpty)
            #expect(!kind.symbol.isEmpty)
            #expect(!kind.explanation.isEmpty)
            #expect(!kind.id.isEmpty)
        }
    }

    @Test("id equals rawValue")
    func idEqualsRawValue() {
        for kind in PermissionKind.allCases {
            #expect(kind.id == kind.rawValue)
        }
    }
}

@Suite("PermissionsChecker")
@MainActor
struct PermissionsCheckerTests {

    @Test("Defaults to unknown for both kinds")
    func defaultsUnknown() {
        let checker = PermissionsChecker()
        #expect(checker.fullDiskAccess == .unknown)
        #expect(checker.appManagement == .unknown)
        #expect(checker.status(for: .fullDiskAccess) == .unknown)
        #expect(checker.status(for: .appManagement) == .unknown)
    }

    @Test("needsAttention while both unknown")
    func needsAttentionUnknown() {
        let checker = PermissionsChecker()
        #expect(checker.needsAttention == true)
    }

    @Test("needsAttention is false only when both granted")
    func needsAttentionLogic() {
        let checker = PermissionsChecker()
        checker.fullDiskAccess = .granted
        #expect(checker.needsAttention == true)
        checker.appManagement = .granted
        #expect(checker.needsAttention == false)
        checker.fullDiskAccess = .denied
        #expect(checker.needsAttention == true)
    }
}
