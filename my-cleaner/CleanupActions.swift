//
//  CleanupActions.swift
//  my-cleaner
//
//  Post-trash bookkeeping that macOS won't do for us automatically when a
//  plist or container is moved to the Trash: unloading running launchd jobs,
//  flushing the cfprefsd cache, and clearing TCC grants tied to the bundle ID.
//

import Foundation

enum CleanupActions {

    // launchctl keeps user agents and daemons in memory after the plist
    // disappears. `bootout` removes the job from its domain so it stops
    // immediately and doesn't try to respawn from a deleted plist.
    //
    // Caveats:
    //   * The target label is derived from the filename. Per launchd
    //     convention `<Label>` matches the filename, but if it doesn't
    //     bootout silently no-ops.
    //   * `bootout system/<label>` requires root, so for system
    //     LaunchDaemons this call fails when invoked unprivileged. The
    //     daemon will still stop on next reboot via the trashed plist; we
    //     just can't unload it live. The elevated trash path (admin)
    //     handles the actual file removal.
    nonisolated static func bootoutLaunchItems(at urls: [URL]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let uid = getuid()

        for url in urls where url.pathExtension.lowercased() == "plist" {
            let target = bootoutTarget(for: url, homePrefix: home, uid: uid)
            runSilently("/bin/launchctl", ["bootout", target])
        }
    }

    // The launchctl domain target for a LaunchAgent/LaunchDaemon plist.
    // System daemons run in the `system/` domain; everything else (user
    // LaunchAgents and `/Library/LaunchAgents` plists that load per-user)
    // is addressed in the current user's `gui/<uid>/` domain.
    nonisolated static func bootoutTarget(for url: URL, homePrefix: String, uid: UInt32) -> String {
        let label = url.deletingPathExtension().lastPathComponent
        let path = url.path
        if path.contains("/LaunchDaemons/") {
            return "system/\(label)"
        }
        if path.hasPrefix(homePrefix) {
            return "gui/\(uid)/\(label)"
        }
        return "gui/\(uid)/\(label)"
    }

    // After deleting a <bundleID>.plist from Preferences, cfprefsd keeps the
    // old values cached and re-writes them on the next read/sync. Killing the
    // daemon (it relaunches on demand) makes the deletion actually stick.
    //
    // Trade-off: cfprefsd serves every app in the user session. Killing it
    // mid-write from a concurrent app can lose that pending write. The
    // daemon respawns on demand, so impact is bounded to whichever app was
    // mid-flush at the same instant — accepted for the cleanup-finishes-
    // cleanly guarantee. Only the user-session cfprefsd is targeted here;
    // the root-session cfprefsd (serving /Library/Preferences writes) is
    // not killed, so deletions there don't fully flush until next login.
    nonisolated static func killCfprefsd() {
        runSilently("/usr/bin/killall", ["cfprefsd"])
    }

    // Clear every TCC grant (camera, microphone, full disk access, …)
    // attached to the bundle ID. Otherwise the rows linger in
    // System Settings → Privacy & Security forever.
    nonisolated static func resetTCC(forBundleID bundleID: String) {
        runSilently("/usr/bin/tccutil", ["reset", "All", bundleID])
    }

    @discardableResult
    private nonisolated static func runSilently(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return -1
        }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
