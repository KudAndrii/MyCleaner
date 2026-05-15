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
                // /Library/LaunchAgents — agent loaded per-user, but the
                // label lives in the gui domain for the current user.
                target = "gui/\(uid)/\(label)"
            }
            runSilently("/bin/launchctl", ["bootout", target])
        }
    }

    // After deleting a <bundleID>.plist from Preferences, cfprefsd keeps the
    // old values cached and re-writes them on the next read/sync. Killing the
    // daemon (it relaunches on demand) makes the deletion actually stick.
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
