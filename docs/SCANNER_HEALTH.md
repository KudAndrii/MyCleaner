# Scanner health surfacing

Tracked-but-not-yet-implemented diagnostic surface for the CLI-backed
scanners. Modeled on the existing `Permissions` /
`PermissionsView` flow so the UX is consistent with what users
already see when they grant Full Disk Access or App Management.

## Status

Not implemented. Discussed during the rollout of the
`pkgutil` / `systemextensionsctl` / `sfltool` scanners but
deliberately deferred — those binaries ship with macOS and can't
realistically be missing on macOS 26. The deferral is a UX call,
not a technical one.

## Problem

Three of the scanners shell out to system CLI tools:

| Scanner | Binary |
|---|---|
| Installer-package receipts | `/usr/sbin/pkgutil` |
| System Extensions | `/usr/bin/systemextensionsctl` |
| SMAppService login items | `/usr/bin/sfltool` |

Each follows the same defensive pattern — `try task.run()` is wrapped
in a `do { … } catch { return "" }`, so any launch failure (binary
missing, refused execution, broken stdout) silently degrades to an
empty parsed result. The corresponding UI section is then hidden
because the model array is empty.

This is correct for the 99.99% case (the binary is present, returns
zero findings for a given app, the section just doesn't appear) but
indistinguishable from the unlikely failure case (the binary refused
to run and the section is hidden for the wrong reason). A user with
an unusual setup — a SIP-stripped machine, a non-standard
`/usr/bin` path, MDM-restricted process execution — has no way to
know that part of the scanner stack didn't run.

## Solution sketch

Mirror the `Permissions` pattern.

### Types

```swift
enum ScannerHealth: Equatable {
    case unknown      // not probed yet
    case ok           // probe succeeded
    case unavailable  // binary not at expected path
    case failed       // binary launched but exited non-zero
}

enum ScannerKind: String, CaseIterable, Sendable {
    case pkgutil
    case systemExtensions
    case loginItems

    var title: String { … }    // "Installer receipts", "System extensions", "Background login items"
    var symbol: String { … }   // SF Symbol, e.g. `archivebox`, `puzzlepiece.extension`, `person.crop.circle.badge.clock`
    var explanation: String {  // what the user loses if this can't run
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

@Observable
@MainActor
final class ScannerHealthChecker {
    var pkgutil: ScannerHealth = .unknown
    var systemExtensions: ScannerHealth = .unknown
    var loginItems: ScannerHealth = .unknown

    var needsAttention: Bool {
        [pkgutil, systemExtensions, loginItems].contains {
            $0 == .unavailable || $0 == .failed
        }
    }

    func status(for kind: ScannerKind) -> ScannerHealth { … }
    func refresh() { … }
    func refresh(_ kind: ScannerKind) { … }
}
```

### Probing

One cheap probe per binary. Each runs the lightest argument that
exercises the executable end-to-end:

| Scanner | Probe command | Healthy when |
|---|---|---|
| pkgutil | `pkgutil --pkgs` | exit 0 |
| systemExtensions | `systemextensionsctl list` | exit 0 |
| loginItems | `sfltool dumpbtm` | exit 0 |

`.unavailable` is the case where `try task.run()` itself throws
(`POSIXErrorDomain.ENOENT` for the executable). `.failed` is the
case where it launched but exited non-zero, or wrote nothing to
stdout when it should have.

### UI

Extend `PermissionsView` rather than building a new sheet. The
existing view already opens when `PermissionsChecker.needsAttention`
is true at launch; tightening that to
`permissions.needsAttention || scannerHealth.needsAttention` makes
diagnostic surfacing free for users with all-green permissions.

Layout in the sheet:

```
[ existing permissions rows ]   ← Full Disk Access, App Management
[ divider ]
Scanner availability             ← new section header
[ scanner row × 3 ]              ← reuse PermissionsView.row style
[ Re-check all ]                 ← same footer
```

Each scanner row reuses the same row component:

- SF Symbol on the left.
- Title + status badge (`Available` green / `Not available` orange /
  `Failed` red).
- Explanation in secondary text.
- **Re-check** button on the right (no "Grant" equivalent — the
  user can't fix a missing binary, only re-check).

### Where it lives

- New `my-cleaner/ScannerHealth.swift` — `ScannerHealth`,
  `ScannerKind`, `ScannerHealthChecker`.
- Extend `PermissionsView` with a `scannerHealthSection`. Pass a
  `ScannerHealthChecker` alongside the existing `PermissionsChecker`.
- Wire `ScannerHealthChecker` into `my_cleanerApp` next to the
  existing checker and refresh on app launch.

## Pitfalls

- **Probe cost**. Three `Process.run()` invocations per refresh,
  each in the 30–100 ms range. Don't re-probe on every view render;
  refresh only on app launch and on explicit user action.
- **Re-running scanners after a refresh**. A "fixed" diagnostic
  shouldn't force a re-scan of an already-analysed app. The user
  re-drops the app if they want to retry.
- **Tests**. Status enum, probe-return mapping, and
  `needsAttention` are pure logic. The probe itself shells out and
  can't be reproduced in CI.

## What's intentionally not on this list

- A failed-scanner banner on `ResultsView`. Adds chrome to the
  99.99% happy path; the permissions sheet is the right channel
  because it's already the "things you need to know before you
  start" surface.
- Auto-recovery / fallback paths. If `systemextensionsctl` is gone,
  there's no equivalent we can substitute — surfacing the gap is the
  honest answer.
- Per-scan toast notifications. The pre-scan diagnostic is enough;
  notifying mid-scan would interrupt the user without giving them
  anything actionable.
