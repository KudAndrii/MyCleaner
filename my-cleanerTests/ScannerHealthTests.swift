//
//  ScannerHealthTests.swift
//  my-cleanerTests
//
//  Pure-logic tests for the scanner-health diagnostic surface — the
//  probe-outcome → health mapping and the observable checker's
//  state machine. The shell-out paths (`probeProcess`, the live
//  `probe(_:)` against `/usr/sbin/pkgutil` etc.) hit the real system
//  and aren't reproducible in CI, so they're exercised only via the
//  pure mapping.
//

import Foundation
import Testing
@testable import MyCleaner

@Suite("ScannerProbe.health(for:)")
struct ScannerProbeMappingTests {

    @Test("binaryMissing maps to .unavailable")
    func binaryMissing() {
        #expect(ScannerProbe.health(for: .binaryMissing) == .unavailable)
    }

    @Test("launchFailed maps to .unavailable")
    func launchFailed() {
        #expect(ScannerProbe.health(for: .launchFailed) == .unavailable)
    }

    @Test("exitedZero maps to .ok")
    func exitedZero() {
        #expect(ScannerProbe.health(for: .exitedZero) == .ok)
    }

    @Test("exitedNonZero maps to .failed")
    func exitedNonZero() {
        #expect(ScannerProbe.health(for: .exitedNonZero) == .failed)
    }
}

@Suite("ScannerKind metadata")
struct ScannerKindMetadataTests {

    @Test("Every kind has a non-empty title, symbol, explanation, id")
    func nonEmptyStrings() {
        for kind in ScannerKind.allCases {
            #expect(!kind.title.isEmpty)
            #expect(!kind.symbol.isEmpty)
            #expect(!kind.explanation.isEmpty)
            #expect(!kind.id.isEmpty)
        }
    }

    @Test("id equals rawValue")
    func idEqualsRawValue() {
        for kind in ScannerKind.allCases {
            #expect(kind.id == kind.rawValue)
        }
    }

    @Test("Exactly three known kinds — guards against accidental enum drift")
    func threeKinds() {
        #expect(ScannerKind.allCases.count == 3)
        #expect(Set(ScannerKind.allCases.map(\.rawValue)) == ["pkgutil", "systemExtensions", "loginItems"])
    }
}

@Suite("ScannerHealthChecker")
@MainActor
struct ScannerHealthCheckerTests {

    @Test("Defaults to unknown for every kind")
    func defaultsUnknown() {
        let checker = ScannerHealthChecker()
        for kind in ScannerKind.allCases {
            #expect(checker.status(for: kind) == .unknown)
        }
    }

    @Test("needsAttention is false when all statuses are unknown")
    func unknownDoesNotTriggerAttention() {
        let checker = ScannerHealthChecker()
        // .unknown is the pre-probe default — it shouldn't open the
        // diagnostic sheet on its own; that's what `.unavailable` /
        // `.failed` are for.
        #expect(checker.needsAttention == false)
    }

    @Test("needsAttention is false when every status is ok")
    func okDoesNotTriggerAttention() {
        let checker = ScannerHealthChecker()
        checker.pkgutil = .ok
        checker.systemExtensions = .ok
        checker.loginItems = .ok
        #expect(checker.needsAttention == false)
    }

    @Test("needsAttention is true when any status is unavailable")
    func unavailableTriggersAttention() {
        let checker = ScannerHealthChecker()
        checker.pkgutil = .ok
        checker.systemExtensions = .unavailable
        checker.loginItems = .ok
        #expect(checker.needsAttention == true)
    }

    @Test("needsAttention is true when any status is failed")
    func failedTriggersAttention() {
        let checker = ScannerHealthChecker()
        checker.pkgutil = .ok
        checker.systemExtensions = .ok
        checker.loginItems = .failed
        #expect(checker.needsAttention == true)
    }

    @Test("status(for:) returns the stored value for each kind")
    func statusForKind() {
        let checker = ScannerHealthChecker()
        checker.pkgutil = .ok
        checker.systemExtensions = .unavailable
        checker.loginItems = .failed

        #expect(checker.status(for: .pkgutil) == .ok)
        #expect(checker.status(for: .systemExtensions) == .unavailable)
        #expect(checker.status(for: .loginItems) == .failed)
    }
}
