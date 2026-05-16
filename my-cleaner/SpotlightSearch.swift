//
//  SpotlightSearch.swift
//  my-cleaner
//

import Foundation

/// Thin wrapper around the `mdfind` command-line tool.
///
/// We shell out instead of using the `NSMetadataQuery` API because
/// `mdfind` is synchronous, doesn't need a run loop, and is safe to
/// call from a background queue — which is how the scanners use it.
enum SpotlightSearch {

    /// Runs `mdfind` synchronously and returns matching paths as URLs.
    ///
    /// Output is NUL-separated so paths containing spaces or newlines
    /// can't break parsing. Returns an empty array on any failure
    /// (binary missing, predicate rejected, non-UTF8 output, etc.).
    ///
    /// - Parameters:
    ///   - predicate: A raw `mdfind` predicate string, e.g. `kMDItemContentType == 'com.apple.application-bundle'`.
    ///   - scopes: Optional `-onlyin` roots to restrict the search to.
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

    /// Files that Spotlight has indexed as carrying this bundle ID.
    ///
    /// Typical hits are `Info.plist`s inside `.app`s and `.framework`s,
    /// preference plists, and some container plists. Spotlight reaches
    /// places a directory walk doesn't, e.g. `/usr/local`, Adobe install
    /// directories, and `/Applications` subfolders.
    nonisolated static func filesForBundleID(_ bundleID: String) -> [URL] {
        return find(predicate: bundleIDPredicate(bundleID))
    }

    /// Builds the `mdfind` predicate that matches files whose
    /// `kMDItemCFBundleIdentifier` equals (case-insensitive) or starts
    /// with (case-insensitive wildcard) the given bundle ID.
    ///
    /// Embedded double quotes are stripped because `mdfind` has no
    /// escape syntax for them inside a quoted value.
    nonisolated static func bundleIDPredicate(_ bundleID: String) -> String {
        let escaped = bundleID.replacingOccurrences(of: "\"", with: "")
        return "kMDItemCFBundleIdentifier == \"\(escaped)\"c" +
            " || kMDItemCFBundleIdentifier == \"\(escaped).*\"wc"
    }
}
