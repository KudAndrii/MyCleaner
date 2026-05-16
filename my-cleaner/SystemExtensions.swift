//
//  SystemExtensions.swift
//  my-cleaner
//
//  Detects system extensions (DriverKit, NetworkExtension,
//  EndpointSecurity, FileProvider) registered by the dropped app that
//  live outside the `.app` bundle and stay loaded after the bundle is
//  trashed. macOS keeps them in its own staging area under
//  `/Library/SystemExtensions` and reloads them at boot until the
//  user explicitly uninstalls them via `systemextensionsctl` (which
//  triggers a confirmation prompt).
//
//  This scanner is **detect-only** — system extensions can't be moved
//  to the Trash. The UI surfaces them in an informational section
//  with an uninstall action that shells out to `systemextensionsctl`.
//

import Foundation

// MARK: - Model

/// A single registered system extension found in
/// `systemextensionsctl list` output.
///
/// Carries the data the UI needs to render the row and the team ID +
/// bundle ID that `systemextensionsctl uninstall` requires.
nonisolated struct SystemExtensionInfo: Sendable, Identifiable, Hashable {
    /// Composite identity — team and bundle together are unique
    /// across the registered set.
    var id: String { "\(teamID).\(bundleID)" }

    /// Bundle identifier of the extension. Often differs from the
    /// owning app's bundle ID (e.g. `com.docker.docker` registers
    /// `com.docker.docker.network-extension`).
    let bundleID: String

    /// 10-character team identifier of the developer who signed the
    /// extension.
    let teamID: String

    /// Human-readable display name from the extension's `Info.plist`,
    /// or the bundle ID as a fallback.
    let displayName: String

    /// Version string from the extension's `Info.plist`. Empty when
    /// `systemextensionsctl` didn't surface one.
    let version: String
}

// MARK: - Scanner

/// Thin wrapper around `/usr/bin/systemextensionsctl`.
///
/// Listing is unprivileged and works without SIP changes. Uninstall
/// always triggers a system confirmation prompt; on machines with
/// SIP fully enforced it may fail entirely, in which case the user
/// has to remove the extension from System Settings.
enum SystemExtensions {

    // MARK: Entry point

    /// Every registered extension attributable to `app`.
    ///
    /// Match strategy (see ``matches(_:bundleID:teamID:)``):
    ///   - Exact or child-of bundle ID.
    ///   - Team ID fallback for extensions whose bundle ID doesn't
    ///     share a prefix with the app (rare but real — Microsoft
    ///     Defender's extension is `com.microsoft.wdav.epsext` against
    ///     a parent app `com.microsoft.edamame.adam`).
    ///
    /// Apple-namespace extensions are unconditionally excluded.
    nonisolated static func extensionsForApp(
        _ app: DroppedApp,
        teamID: String?
    ) -> [SystemExtensionInfo] {
        let all = parseListOutput(listOutput())
        return all.filter { matches($0, bundleID: app.bundleID, teamID: teamID) }
    }

    // MARK: Attribution

    /// `true` when the given extension belongs to the dropped app.
    ///
    /// Rejects anything in Apple's reserved namespace
    /// (`com.apple.*`) so the user can't accidentally try to uninstall
    /// system components. Among the rest, accepts a bundle-ID prefix
    /// match or — when bundle IDs don't line up — a team-ID match.
    nonisolated static func matches(
        _ ext: SystemExtensionInfo,
        bundleID: String?,
        teamID: String?
    ) -> Bool {
        if isAppleNamespace(ext.bundleID) { return false }
        if let bid = bundleID, !bid.isEmpty {
            let extLower = ext.bundleID.lowercased()
            let bidLower = bid.lowercased()
            if extLower == bidLower { return true }
            if extLower.hasPrefix(bidLower + ".") { return true }
        }
        if let tid = teamID, !tid.isEmpty, ext.teamID == tid { return true }
        return false
    }

    /// `true` for `com.apple.*` bundle IDs — used to exclude
    /// OS-shipped extensions from the surfaced set.
    nonisolated static func isAppleNamespace(_ bundleID: String) -> Bool {
        bundleID.lowercased().hasPrefix("com.apple.")
    }

    /// `true` when `s` is a 10-character uppercase alphanumeric Apple
    /// team identifier (`UBF8T346G9`, `WV28HM8KMA`, …).
    ///
    /// Used by the parser as a sanity check that we're looking at a
    /// real extension row, not a stray header / banner.
    nonisolated static func isTeamID(_ s: String) -> Bool {
        guard s.count == 10 else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isNumber || ($0.isLetter && $0.isUppercase)) }
    }

    // MARK: Parser

    /// Parses `systemextensionsctl list` output into structured info.
    ///
    /// Real output (one section per extension type — driver, network,
    /// endpoint security, file provider):
    ///
    ///     2 extension(s)
    ///     --- com.apple.system_extension.driver_extension
    ///     enabled  active  teamID  bundleID (version)  name  [state]
    ///     *  *  NA3SMNCJU9  com.dropbox.dropbox.fs (190.4.6604)  FileProvider  [activated enabled]
    ///     --- com.apple.system_extension.network_extension
    ///     enabled  active  teamID  bundleID (version)  name  [state]
    ///     *  *  WV28HM8KMA  com.docker.docker.network-extension (4.39.0)  NetworkExtension  [activated enabled]
    ///
    /// Fields are tab-separated in real output. Header lines, category
    /// markers, and the trailing summary count are filtered out by
    /// shape. Rows whose third column isn't a valid team ID are
    /// dropped — defensively skips banners and any future schema
    /// changes that introduce stray text.
    nonisolated static func parseListOutput(_ output: String) -> [SystemExtensionInfo] {
        var results: [SystemExtensionInfo] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("---") { continue }
            if line.hasPrefix("enabled") { continue }
            if line.contains("extension(s)") { continue }

            let parts = line
                .split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 4 else { continue }
            let teamID = parts[2]
            guard isTeamID(teamID) else { continue }

            let (bundleID, version) = splitBundleAndVersion(parts[3])
            guard !bundleID.isEmpty else { continue }

            let displayName: String
            if parts.count >= 5, !parts[4].isEmpty {
                displayName = parts[4]
            } else {
                displayName = bundleID
            }

            results.append(SystemExtensionInfo(
                bundleID: bundleID,
                teamID: teamID,
                displayName: displayName,
                version: version
            ))
        }
        return results
    }

    /// Splits `"com.foo.bar (1.2.3)"` into `("com.foo.bar", "1.2.3")`.
    ///
    /// Returns the input as the bundle ID with an empty version when
    /// there's no parenthesised tail.
    nonisolated static func splitBundleAndVersion(_ s: String) -> (bundleID: String, version: String) {
        guard let openParen = s.lastIndex(of: "("),
              s.hasSuffix(")"),
              openParen > s.startIndex else {
            return (s, "")
        }
        let bundle = s[..<openParen].trimmingCharacters(in: .whitespaces)
        let versionStart = s.index(after: openParen)
        let versionEnd = s.index(before: s.endIndex)
        let version = String(s[versionStart..<versionEnd])
        return (bundle, version)
    }

    // MARK: Shell-out

    /// Raw output of `systemextensionsctl list`. Empty string on any
    /// failure (binary missing, non-UTF8 output, non-zero exit).
    nonisolated static func listOutput() -> String {
        run(arguments: ["list"])
    }

    /// Asks the system to uninstall `ext`. Triggers a user-confirmation
    /// prompt; the return value only indicates whether the command
    /// itself exited successfully, not whether the user approved
    /// removal.
    ///
    /// On strict-SIP setups this command may fail outright — callers
    /// should treat `false` as "user needs to remove it from System
    /// Settings" rather than a hard error.
    nonisolated static func uninstall(_ ext: SystemExtensionInfo) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        task.arguments = ["uninstall", ext.teamID, ext.bundleID]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private nonisolated static func run(arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        task.arguments = arguments

        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()

        do { try task.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        return String(data: data, encoding: .utf8) ?? ""
    }
}
