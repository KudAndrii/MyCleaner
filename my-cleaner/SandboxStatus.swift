//
//  SandboxStatus.swift
//  my-cleaner
//

import Foundation

/// Best-effort detection of whether MyCleaner is running inside the macOS
/// App Sandbox.
///
/// Sandboxing redirects `~/Library` to a per-app container, so scans
/// produced from a sandboxed build return nothing useful. The UI uses
/// this to surface a "App Sandbox is on" warning in the drop zone.
enum SandboxStatus {

    /// `true` if the current process is sandboxed.
    ///
    /// Detection uses two heuristics:
    /// - `APP_SANDBOX_CONTAINER_ID` environment variable, set by the OS
    ///   for sandboxed processes.
    /// - The home directory path containing `/Library/Containers/`,
    ///   which is the canonical location for sandboxed home directories.
    static var isSandboxed: Bool {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home.contains("/Library/Containers/")
    }
}
