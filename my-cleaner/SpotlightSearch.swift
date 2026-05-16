//
//  SpotlightSearch.swift
//  my-cleaner
//

import Foundation

enum SpotlightSearch {

    // Run mdfind synchronously. Output is NUL-separated so paths with spaces
    // or newlines can't break parsing. Empty array on any failure.
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

    // Files that Spotlight has indexed as carrying this bundle ID — typically
    // Info.plists inside .apps and .frameworks, plus preference plists and
    // some container plists. Spotlight reaches places a directory walk
    // doesn't, e.g. /usr/local, Adobe install dirs, /Applications subfolders.
    nonisolated static func filesForBundleID(_ bundleID: String) -> [URL] {
        return find(predicate: bundleIDPredicate(bundleID))
    }

    // Builds the mdfind predicate that matches files whose
    // `kMDItemCFBundleIdentifier` equals the given bundle ID (case-
    // insensitive) or starts with `<bundleID>.` (case-insensitive,
    // wildcard suffix). Double quotes inside the bundle ID are stripped
    // because mdfind has no escape syntax for them inside a quoted value.
    nonisolated static func bundleIDPredicate(_ bundleID: String) -> String {
        let escaped = bundleID.replacingOccurrences(of: "\"", with: "")
        return "kMDItemCFBundleIdentifier == \"\(escaped)\"c" +
            " || kMDItemCFBundleIdentifier == \"\(escaped).*\"wc"
    }
}
