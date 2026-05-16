//
//  PkgutilReceipts.swift
//  my-cleaner
//
//  Cross-references the system installer-package receipt database
//  against the dropped app's bundle identifier to surface files the
//  directory walk and Spotlight pass can't reach.
//
//  Apps that ship via a `.pkg` installer (anything with a kernel /
//  network extension, paid software with a licensing helper, vendor
//  suites) drop files at root-relative paths that don't follow any
//  bundle-ID convention — `/Library/PrivilegedHelperTools/<binary>`,
//  `/Library/LaunchDaemons/<helper>.plist`, `/usr/local/bin/<tool>`,
//  vendor folders under `/Library/Application Support`. The receipt
//  database records every such path; this scanner is additive on
//  top of the existing pipeline.
//

import Foundation

/// Thin wrapper around `/usr/sbin/pkgutil`.
///
/// Shells out instead of binding the receipt store APIs because the
/// CLI is synchronous, stable across macOS releases, and safe to call
/// from a background queue — which is how the scanners use it.
enum PkgutilReceipts {

    /// Absolute paths that are shared between every installer on the
    /// system. `pkgutil --files` lists each parent directory the
    /// package wrote into; trashing one of these would break unrelated
    /// software, so we drop them unconditionally before surfacing the
    /// receipt's contents.
    nonisolated static let sharedDirectories: Set<String> = [
        "/",
        "/Applications",
        "/Library",
        "/Library/Application Support",
        "/Library/Audio",
        "/Library/Audio/Plug-Ins",
        "/Library/Extensions",
        "/Library/Frameworks",
        "/Library/Internet Plug-Ins",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/Library/PreferencePanes",
        "/Library/Preferences",
        "/Library/PrivilegedHelperTools",
        "/Library/QuickLook",
        "/Library/Receipts",
        "/Library/Spotlight",
        "/Library/StartupItems",
        "/private",
        "/private/etc",
        "/private/etc/paths.d",
        "/private/var",
        "/usr",
        "/usr/bin",
        "/usr/lib",
        "/usr/local",
        "/usr/local/bin",
        "/usr/local/etc",
        "/usr/local/lib",
        "/usr/local/share",
        "/usr/sbin",
        "/usr/share",
        "/var",
    ]

    // MARK: - Entry point

    /// Paths a `.pkg` installer wrote that are attributable to the given app.
    ///
    /// Walks the receipt database, picks receipts whose ID matches the
    /// app's bundle ID via ``packageMatches(_:bundleID:)``, and returns
    /// the union of their `--files` outputs filtered to absolute paths
    /// that:
    ///
    ///   - Still exist on disk.
    ///   - Aren't inside the `.app` bundle itself.
    ///   - Aren't a well-known shared parent directory.
    ///
    /// Returns an empty array when the app has no bundle ID, no receipt
    /// matches, or `pkgutil` is unreachable.
    nonisolated static func filesForApp(_ app: DroppedApp) -> [URL] {
        guard let bid = app.bundleID, !bid.isEmpty else { return [] }
        let packages = listPackageIDs()
        guard !packages.isEmpty else { return [] }

        let appPath = app.url.standardizedFileURL.path
        var collected: Set<String> = []
        for pkgID in packages where packageMatches(pkgID, bundleID: bid) {
            for path in filePaths(forPackage: pkgID) {
                if sharedDirectories.contains(path) { continue }
                if path == appPath { continue }
                if path.hasPrefix(appPath + "/") { continue }
                collected.insert(path)
            }
        }

        let fm = FileManager.default
        return collected
            .filter { fm.fileExists(atPath: $0) }
            .sorted()
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Attribution

    /// `true` when `pkgID` looks like it could have been written by the
    /// installer for an app with the given bundle identifier.
    ///
    /// Recognised shapes:
    ///
    /// - exact: `pkgID == bundleID`
    /// - `.pkg` suffix: `pkgID == "<bundleID>.pkg"`
    /// - child receipt: `pkgID` has prefix `"<bundleID>."`
    ///
    /// All comparisons are case-insensitive — receipt IDs are usually
    /// lowercase reverse-DNS but a few vendors capitalise components.
    /// Deliberately does **not** match by vendor namespace; a sibling
    /// package from the same developer is too aggressive a default.
    nonisolated static func packageMatches(_ pkgID: String, bundleID: String) -> Bool {
        let pkg = pkgID.lowercased()
        let bid = bundleID.lowercased()
        guard !bid.isEmpty else { return false }
        if pkg == bid { return true }
        if pkg == bid + ".pkg" { return true }
        if pkg.hasPrefix(bid + ".") { return true }
        return false
    }

    // MARK: - pkgutil shell-out

    /// Every receipt ID the system knows about.
    ///
    /// `pkgutil --pkgs` writes one ID per line. Returns an empty array
    /// on non-zero exit, non-UTF8 output, or a missing `pkgutil` binary.
    nonisolated static func listPackageIDs() -> [String] {
        parseLines(run(arguments: ["--pkgs"]))
    }

    /// Absolute paths the given package wrote, prefixed with `/`.
    ///
    /// `pkgutil --files` outputs root-relative paths (`Library/...`);
    /// this method prefixes each with `/` so callers can pass them
    /// straight to `FileManager` / `URL(fileURLWithPath:)`. The output
    /// is left otherwise unfiltered; use ``filesForApp(_:)`` for the
    /// shared-directory-stripped, on-disk-only subset.
    nonisolated static func filePaths(forPackage pkgID: String) -> [String] {
        parseLines(run(arguments: ["--files", pkgID])).map { line in
            line.hasPrefix("/") ? line : "/" + line
        }
    }

    private nonisolated static func run(arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        task.arguments = arguments

        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()

        do { try task.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Splits shell output into trimmed, non-empty lines.
    ///
    /// Drops the `.` root marker that `pkgutil --files` emits, and any
    /// pure-whitespace lines, so callers don't have to.
    nonisolated static func parseLines(_ output: String) -> [String] {
        output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." }
    }
}
