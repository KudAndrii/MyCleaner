//
//  SpotlightSearch.swift
//  my-cleaner
//

import Foundation

/// Thin synchronous wrapper around the `mdfind` command-line tool.
///
/// MyCleaner uses Spotlight for two purposes:
///
/// - Supplementing the app scan with files whose
///   `kMDItemCFBundleIdentifier` metadata names the dropped app, even
///   when the parent folder doesn't (`Info.plist` files inside
///   `/Library/Frameworks`, helper bundles in vendor install dirs).
/// - Finding every `.app` on disk during installed-apps discovery, so
///   apps in non-standard locations (Setapp, `/opt`, external volumes)
///   aren't mistaken for uninstalled.
enum SpotlightSearch {

    /// Run an `mdfind` query and return the matching URLs.
    ///
    /// Output is parsed as NUL-separated so paths containing spaces or
    /// newlines round-trip correctly. Any launch or read failure
    /// collapses to an empty result rather than throwing.
    ///
    /// - Parameters:
    ///   - predicate: A raw Spotlight predicate string, passed verbatim
    ///     to `mdfind`.
    ///   - scopes: Optional list of URLs to restrict the search to.
    ///     Maps to `-onlyin` flags. An empty array searches everything.
    /// - Returns: The file URLs `mdfind` printed, or an empty array on
    ///   failure.
    nonisolated static func find(predicate: String, scopes: [URL] = []) -> [URL] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        var args: [String] = ["-0"]
        for scope in scopes {
            args.append("-onlyin")
            args.append(scope.path)
        }
        args.append(predicate)
        task.arguments = args

        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()

        do { try task.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard !data.isEmpty,
              let s = String(data: data, encoding: .utf8) else { return [] }

        return s.split(separator: "\0", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)) }
    }

    /// Look up every file Spotlight has indexed as belonging to
    /// `bundleID`.
    ///
    /// Combines an exact match on `kMDItemCFBundleIdentifier` with a
    /// wildcard match on `<bundleID>.*`, so child bundle IDs (helper
    /// extensions, plugin sub-bundles) are surfaced too. Typically this
    /// pulls in `Info.plist` files inside `.app` and `.framework`
    /// bundles, plus preference and container plists.
    ///
    /// - Parameter bundleID: The bundle identifier to search for. Any
    ///   embedded quotes are stripped before being interpolated into
    ///   the predicate.
    /// - Returns: Matching file URLs, or an empty array.
    nonisolated static func filesForBundleID(_ bundleID: String) -> [URL] {
        let escaped = bundleID.replacingOccurrences(of: "\"", with: "")
        let predicate =
            "kMDItemCFBundleIdentifier == \"\(escaped)\"c" +
            " || kMDItemCFBundleIdentifier == \"\(escaped).*\"wc"
        return find(predicate: predicate)
    }
}
