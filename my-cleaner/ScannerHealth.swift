//
//  ScannerHealth.swift
//  my-cleaner
//
//  Diagnostic surface for the CLI-backed scanners (`pkgutil`,
//  `systemextensionsctl`, `sfltool`). Each scanner runs as a
//  defensive shell-out that returns empty on any failure, so a UI
//  section that's empty because "the binary refused to run" looks
//  identical to the much-more-common "no findings" case. This
//  module probes those binaries at app launch so users with an
//  unusual setup — SIP-stripped, MDM-restricted, non-standard
//  `/usr/bin` — can see why a section is missing.
//

import Foundation
import Observation

/// Outcome of a single scanner-binary probe.
nonisolated enum ScannerHealth: Equatable, Sendable {
    /// Not probed yet.
    case unknown
    /// Probe succeeded — the scanner can be expected to run.
    case ok
    /// The binary isn't at the expected path or couldn't be launched
    /// (`ENOENT`, MDM-blocked, deleted from the system image).
    case unavailable
    /// The binary launched but exited non-zero, indicating something
    /// upstream is wrong even though the executable is present.
    case failed
}

/// Identifies one of the CLI-backed scanners. The metadata on this
/// enum drives the diagnostics UI, mirroring how ``PermissionKind``
/// drives ``PermissionsView``.
nonisolated enum ScannerKind: String, Identifiable, CaseIterable, Sendable {
    case pkgutil
    case systemExtensions
    case loginItems

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pkgutil: "Installer receipts"
        case .systemExtensions: "System extensions"
        case .loginItems: "Background login items"
        }
    }

    var symbol: String {
        switch self {
        case .pkgutil: "archivebox.fill"
        case .systemExtensions: "puzzlepiece.extension.fill"
        case .loginItems: "person.crop.circle.badge.clock.fill"
        }
    }

    /// One-line explanation of what the user *loses* if this scanner
    /// can't run. Surfaced as the secondary text in the diagnostics
    /// row.
    var explanation: String {
        switch self {
        case .pkgutil:
            return "Lets My Cleaner find files installed by .pkg packages outside the .app bundle (helper binaries, LaunchDaemons, /usr/local tools)."
        case .systemExtensions:
            return "Lets My Cleaner detect network / driver / endpoint-security extensions the app registered, so you know what's still loaded after trashing the bundle."
        case .loginItems:
            return "Lets My Cleaner list background helpers registered via SMAppService — items that don't drop a LaunchAgents plist."
        }
    }
}

/// Probing primitives, split out so the outcome → health mapping
/// stays a pure function (testable without shelling out).
nonisolated enum ScannerProbe {

    /// Raw outcome of an attempt to invoke a scanner's CLI tool.
    /// Decoupled from ``ScannerHealth`` so we can unit-test the
    /// mapping without touching `Process`.
    enum Outcome: Equatable, Sendable {
        /// Executable file isn't present at the expected path.
        case binaryMissing
        /// `Process.run()` threw (e.g. `ENOENT` after the
        /// `fileExists` check, MDM execution denial).
        case launchFailed
        /// Process launched and exited with status 0.
        case exitedZero
        /// Process launched and exited with a non-zero status.
        case exitedNonZero
    }

    /// Pure mapping — every probe result threads through here so the
    /// rule is in one place.
    static func health(for outcome: Outcome) -> ScannerHealth {
        switch outcome {
        case .binaryMissing, .launchFailed: .unavailable
        case .exitedZero: .ok
        case .exitedNonZero: .failed
        }
    }

    /// Runs the cheapest probe for `kind` and returns the resulting
    /// health. Synchronous; expected to run on the main thread at
    /// launch alongside ``PermissionsChecker/refresh()``.
    static func probe(_ kind: ScannerKind) -> ScannerHealth {
        switch kind {
        case .pkgutil:
            return health(for: probeProcess(
                executable: "/usr/sbin/pkgutil",
                arguments: ["--pkgs"]
            ))
        case .systemExtensions:
            return health(for: probeProcess(
                executable: "/usr/bin/systemextensionsctl",
                arguments: ["list"]
            ))
        case .loginItems:
            // Deviation from docs/SCANNER_HEALTH.md: the doc
            // suggested probing with `sfltool dumpbtm`, but that
            // command requires admin and would re-introduce the
            // launch-time password prompt we deliberately gated
            // behind the opt-in toggle. File-existence is enough to
            // catch the "binary missing" case the diagnostic was
            // designed for; the "binary present but refuses to
            // launch" case surfaces at the toggle's runtime path
            // (the prompt itself).
            let exists = FileManager.default.fileExists(atPath: "/usr/bin/sfltool")
            return exists ? .ok : .unavailable
        }
    }

    private static func probeProcess(executable: String, arguments: [String]) -> Outcome {
        guard FileManager.default.fileExists(atPath: executable) else {
            return .binaryMissing
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return .launchFailed }
        task.waitUntilExit()
        return task.terminationStatus == 0 ? .exitedZero : .exitedNonZero
    }
}

/// Observable wrapper that owns the per-scanner status and refresh
/// plumbing. Mirrors ``PermissionsChecker`` so the two diagnostics
/// can share UI scaffolding inside `PermissionsView`.
@Observable
@MainActor
final class ScannerHealthChecker {
    var pkgutil: ScannerHealth = .unknown
    var systemExtensions: ScannerHealth = .unknown
    var loginItems: ScannerHealth = .unknown

    /// `true` when at least one scanner is in a state that warrants
    /// surfacing the diagnostic sheet (binary missing or failing).
    /// `.unknown` and `.ok` don't trigger attention — `.unknown` is
    /// the pre-probe default and `.ok` is the happy path.
    var needsAttention: Bool {
        ScannerKind.allCases.contains { kind in
            let s = status(for: kind)
            return s == .unavailable || s == .failed
        }
    }

    func status(for kind: ScannerKind) -> ScannerHealth {
        switch kind {
        case .pkgutil: pkgutil
        case .systemExtensions: systemExtensions
        case .loginItems: loginItems
        }
    }

    /// Re-probe every scanner. Called from `ContentView.task` at
    /// launch and from the diagnostics sheet's "Re-check all" button.
    func refresh() {
        for kind in ScannerKind.allCases {
            refresh(kind)
        }
    }

    /// Re-probe a single scanner. Used by the per-row re-check button.
    func refresh(_ kind: ScannerKind) {
        let result = ScannerProbe.probe(kind)
        switch kind {
        case .pkgutil: pkgutil = result
        case .systemExtensions: systemExtensions = result
        case .loginItems: loginItems = result
        }
    }
}
