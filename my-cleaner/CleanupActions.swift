//
//  CleanupActions.swift
//  my-cleaner
//

import Foundation

/// Post-trash bookkeeping that macOS won't do for us automatically when
/// a plist or container is moved to the Trash:
///
/// - **`bootoutLaunchItems(at:)`** — unloads running launchd jobs whose
///   plist we're about to delete, so the helper actually stops instead
///   of lingering until reboot.
/// - **`killCfprefsd()`** — terminates the in-memory preferences cache
///   so deleted `<bundleID>.plist` files don't get rewritten from RAM.
/// - **`resetTCC(forBundleID:)`** — clears Transparency, Consent, and
///   Control grants so the bundle ID's row disappears from
///   System Settings → Privacy & Security.
enum CleanupActions {

    /// Run `launchctl bootout` on every plist URL whose extension is
    /// `.plist`, choosing the right launchd domain based on the file's
    /// install location.
    ///
    /// - **System LaunchDaemons** (`/Library/LaunchDaemons/`) use the
    ///   `system/<label>` domain. Booting them out requires root, so for
    ///   unprivileged callers this is a no-op — the daemon stops on next
    ///   reboot via the trashed plist instead.
    /// - **User LaunchAgents** (everything else) use the
    ///   `gui/<uid>/<label>` domain.
    ///
    /// The launchd label is derived from the plist filename. Per
    /// convention the filename matches `<Label>`; if it doesn't, the
    /// `bootout` call silently no-ops.
    ///
    /// - Parameter urls: Plist URLs about to be trashed. Non-`.plist`
    ///   entries are ignored.
    nonisolated static func bootoutLaunchItems(at urls: [URL]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let uid = getuid()

        for url in urls where url.pathExtension.lowercased() == "plist" {
            let label = url.deletingPathExtension().lastPathComponent
            let path = url.path
            let target: String
            if path.contains("/LaunchDaemons/") {
                target = "system/\(label)"
            } else if path.hasPrefix(home) {
                target = "gui/\(uid)/\(label)"
            } else {
                // /Library/LaunchAgents — loaded per-user; label lives
                // in the gui domain for the current user.
                target = "gui/\(uid)/\(label)"
            }
            runSilently("/bin/launchctl", ["bootout", target])
        }
    }

    /// Terminate `cfprefsd`. The daemon caches every app's `Preferences`
    /// in memory and will re-write a deleted plist on its next sync if
    /// left running.
    ///
    /// `cfprefsd` is on-demand-launched by `launchd`, so it'll respawn
    /// the next time anything reads a preference. The trade-off is a
    /// small window where a concurrent app's pending write to a *different*
    /// plist could be lost — accepted for the guarantee that this app's
    /// deletion actually sticks.
    ///
    /// Only the user-session daemon is killed here. The root-session
    /// daemon (serving `/Library/Preferences` writes) is left running;
    /// system-level deletions don't fully flush until next login.
    nonisolated static func killCfprefsd() {
        runSilently("/usr/bin/killall", ["cfprefsd"])
    }

    /// Clear every TCC grant attached to `bundleID` — camera,
    /// microphone, Full Disk Access, all of them.
    ///
    /// Without this, the bundle ID's row lingers in System Settings →
    /// Privacy & Security forever, even after every related file has
    /// been removed.
    ///
    /// - Parameter bundleID: The bundle identifier whose grants should
    ///   be cleared.
    nonisolated static func resetTCC(forBundleID bundleID: String) {
        runSilently("/usr/bin/tccutil", ["reset", "All", bundleID])
    }

    /// Run an external program with stdout/stderr suppressed and return
    /// its exit status.
    ///
    /// Used for the launchctl/killall/tccutil invocations above where
    /// we don't care about the program's output — only whether it ran.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the executable.
    ///   - args: Argument vector.
    /// - Returns: The process exit status, or `-1` if launching failed.
    @discardableResult
    private nonisolated static func runSilently(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
