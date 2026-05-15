//
//  AppScanner.swift
//  my-cleaner
//

import Foundation
import Security

enum AppScanner {

    nonisolated static func scan(app: DroppedApp) -> ScanResult {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let userLib = home.appendingPathComponent("Library", isDirectory: true)
        let sysLib = URL(fileURLWithPath: "/Library", isDirectory: true)
        let teamID = readTeamID(forAppAt: app.url)
        let nameHints = computeNameHints(app: app)

        // (directory, category, extra descent depth — 0 means top-level only)
        let locations: [(URL, RelatedItem.Category, Int)] = [
            (userLib.appendingPathComponent("Application Support", isDirectory: true), .applicationSupport, 1),
            (userLib.appendingPathComponent("Caches", isDirectory: true), .caches, 1),
            (userLib.appendingPathComponent("Preferences", isDirectory: true), .preferences, 0),
            (userLib.appendingPathComponent("Preferences/ByHost", isDirectory: true), .preferences, 0),
            (userLib.appendingPathComponent("Containers", isDirectory: true), .containers, 0),
            (userLib.appendingPathComponent("Group Containers", isDirectory: true), .groupContainers, 0),
            (userLib.appendingPathComponent("Logs", isDirectory: true), .logs, 1),
            (userLib.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true), .crashReports, 0),
            (userLib.appendingPathComponent("Saved Application State", isDirectory: true), .savedState, 0),
            (userLib.appendingPathComponent("HTTPStorages", isDirectory: true), .cookies, 0),
            (userLib.appendingPathComponent("WebKit", isDirectory: true), .cookies, 0),
            (userLib.appendingPathComponent("Cookies", isDirectory: true), .cookies, 0),
            (userLib.appendingPathComponent("LaunchAgents", isDirectory: true), .launchItems, 0),
            (userLib.appendingPathComponent("Application Scripts", isDirectory: true), .scripts, 0),
            (userLib.appendingPathComponent("Mobile Documents", isDirectory: true), .iCloud, 0),
            (sysLib.appendingPathComponent("Application Support", isDirectory: true), .applicationSupport, 1),
            (sysLib.appendingPathComponent("Caches", isDirectory: true), .caches, 1),
            (sysLib.appendingPathComponent("Preferences", isDirectory: true), .preferences, 0),
            (sysLib.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true), .crashReports, 0),
            (sysLib.appendingPathComponent("LaunchAgents", isDirectory: true), .launchItems, 0),
            (sysLib.appendingPathComponent("LaunchDaemons", isDirectory: true), .launchItems, 0),
            (sysLib.appendingPathComponent("PrivilegedHelperTools", isDirectory: true), .launchItems, 0),
        ]

        var found: [URL: RelatedItem] = [:]
        let appPath = app.url.standardizedFileURL.path

        for (dir, category, descend) in locations {
            scan(
                directory: dir,
                category: category,
                app: app,
                teamID: teamID,
                nameHints: nameHints,
                extraDepth: descend,
                appPath: appPath,
                into: &found
            )
        }

        // Spotlight pass — catches Info.plists, preference files, and
        // helper bundles whose metadata carries this bundle ID even though
        // their parent folder name doesn't match anything the walk knows
        // to enter (e.g. files under /Library/Frameworks or vendor dirs).
        supplementWithSpotlight(
            app: app,
            appPath: appPath,
            into: &found
        )

        let appSize = sizeOfItem(at: app.url, isDirectory: true)
        return ScanResult(appSize: appSize, items: Array(found.values))
    }

    private nonisolated static func supplementWithSpotlight(
        app: DroppedApp,
        appPath: String,
        into found: inout [URL: RelatedItem]
    ) {
        guard let bid = app.bundleID, !bid.isEmpty else { return }
        let hits = SpotlightSearch.filesForBundleID(bid)
        guard !hits.isEmpty else { return }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let userLib = home + "/Library/"
        let sysLib = "/Library/"

        for url in hits {
            let std = url.standardizedFileURL
            let path = std.path
            if path == appPath { continue }
            if path.hasPrefix(appPath + "/") { continue }
            // Only surface library-scope hits; the goal is to add things our
            // hand-rolled walk missed, not to surface every Spotlight match.
            guard path.hasPrefix(userLib) || path.hasPrefix(sysLib) else { continue }
            if found[std] != nil { continue }

            let isDir = (try? std.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = sizeOfItem(at: std, isDirectory: isDir)
            let category = categorize(path: path)
            found[std] = RelatedItem(
                url: std,
                category: category,
                sizeBytes: size,
                isDirectory: isDir,
                isShared: false
            )
        }
    }

    private nonisolated static func categorize(path: String) -> RelatedItem.Category {
        // Cheap path-segment classifier so Spotlight results land under the
        // right header in the results list.
        if path.contains("/Application Support/") { return .applicationSupport }
        if path.contains("/Caches/") { return .caches }
        if path.contains("/Containers/") { return .containers }
        if path.contains("/Group Containers/") { return .groupContainers }
        if path.contains("/Preferences/") { return .preferences }
        if path.contains("/Saved Application State/") { return .savedState }
        if path.contains("/Logs/DiagnosticReports/") { return .crashReports }
        if path.contains("/Logs/") { return .logs }
        if path.contains("/HTTPStorages/") || path.contains("/WebKit/") || path.contains("/Cookies/") {
            return .cookies
        }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") || path.contains("/PrivilegedHelperTools/") {
            return .launchItems
        }
        if path.contains("/Application Scripts/") { return .scripts }
        if path.contains("/Mobile Documents/") { return .iCloud }
        return .other
    }

    private nonisolated static func scan(
        directory: URL,
        category: RelatedItem.Category,
        app: DroppedApp,
        teamID: String?,
        nameHints: [String],
        extraDepth: Int,
        appPath: String,
        into found: inout [URL: RelatedItem]
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        for entry in entries {
            let std = entry.standardizedFileURL
            if std.path == appPath { continue }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            let outcome = classify(
                entry: entry,
                app: app,
                teamID: teamID,
                nameHints: nameHints,
                category: category
            )
            if outcome.matched {
                if found[std] == nil {
                    let size = sizeOfItem(at: entry, isDirectory: isDir)
                    found[std] = RelatedItem(
                        url: entry,
                        category: category,
                        sizeBytes: size,
                        isDirectory: isDir,
                        isShared: outcome.shared
                    )
                }
                continue
            }

            if isDir, extraDepth > 0, !shouldSkipDescent(entry) {
                scan(
                    directory: entry,
                    category: category,
                    app: app,
                    teamID: teamID,
                    nameHints: nameHints,
                    extraDepth: extraDepth - 1,
                    appPath: appPath,
                    into: &found
                )
            }
        }
    }

    private nonisolated static func shouldSkipDescent(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix("com.apple.") { return true }
        if name == "Apple" || name == "CrashReporter" { return true }
        return false
    }

    /// Collect every short token we plausibly know the app by: display name, bundle ID's
    /// last reverse-DNS component, and the .app filename. JetBrains stores Rider data in
    /// `~/Library/Caches/JetBrains/Rider2025.3/`, where the folder name only matches the
    /// `rider` token from the bundle ID — not "JetBrains Rider".
    private nonisolated static func computeNameHints(app: DroppedApp) -> [String] {
        var hints: Set<String> = []
        let display = app.name.lowercased()
        if display.count >= 3 { hints.insert(display) }

        if let bid = app.bundleID,
           let last = bid.split(separator: ".").last {
            let token = String(last).lowercased()
            if token.count >= 3 { hints.insert(token) }
        }

        let filename = app.url.deletingPathExtension().lastPathComponent.lowercased()
        if filename.count >= 3 { hints.insert(filename) }

        return Array(hints)
    }

    /// Decide whether `entry` belongs to `app`, and whether the match is a "shared with developer"
    /// container (team-ID-prefixed group container) that should be off by default.
    nonisolated static func classify(
        entry: URL,
        app: DroppedApp,
        teamID: String?,
        nameHints: [String],
        category: RelatedItem.Category
    ) -> (matched: Bool, shared: Bool) {
        let full = entry.lastPathComponent.lowercased()
        let base = entry.deletingPathExtension().lastPathComponent.lowercased()

        if let raw = app.bundleID, !raw.isEmpty {
            let bid = raw.lowercased()
            if full == bid || base == bid { return (true, false) }
            if full.hasPrefix(bid + ".") || base.hasPrefix(bid + ".") { return (true, false) }
            if full == "group.\(bid)" || full.hasPrefix("group.\(bid).") { return (true, false) }
            // iCloud containers under ~/Library/Mobile Documents/ are named
            // with tildes instead of dots: `iCloud~com~apple~Pages`. The
            // entry name was already lowercased into `full`, so match against
            // a lowercased `icloud~` prefix.
            if category == .iCloud {
                let tildeBID = bid.replacingOccurrences(of: ".", with: "~")
                if full == "icloud~\(tildeBID)" { return (true, false) }
                if full.hasPrefix("icloud~\(tildeBID)~") { return (true, false) }
            }
        }

        for hint in nameHints {
            if base == hint || full == hint { return (true, false) }
            if wordBoundaryPrefix(base, prefix: hint) { return (true, false) }
            if wordBoundaryPrefix(full, prefix: hint) { return (true, false) }
        }

        // Team-ID-prefixed group containers are usually shared between every app the
        // developer ships (e.g. Microsoft Office's UBF8T346G9.Office). Surface them but
        // default the toggle off so the user opts in.
        if category == .groupContainers, let raw = teamID, !raw.isEmpty {
            let tid = raw.lowercased()
            if full.hasPrefix(tid + ".") {
                return (true, true)
            }
        }

        return (false, false)
    }

    /// Returns true if `s` starts with `prefix` and the next character is a non-letter
    /// (digit, dot, space, dash, underscore). Avoids matching "Microsoft" in "MicrosoftAutoUpdate"
    /// while still matching "Rider" in "Rider2024.3" or "Microsoft Word" in "Microsoft Word Data".
    private nonisolated static func wordBoundaryPrefix(_ s: String, prefix: String) -> Bool {
        guard prefix.count >= 3, s.count > prefix.count, s.hasPrefix(prefix) else { return false }
        let next = s[s.index(s.startIndex, offsetBy: prefix.count)]
        return !next.isLetter
    }

    nonisolated static func readTeamID(forAppAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else { return nil }

        var infoRef: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, [], &infoRef)
        guard infoStatus == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }

        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated static func sizeOfItem(at url: URL, isDirectory: Bool) -> Int64 {
        if !isDirectory {
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            if let values = try? url.resourceValues(forKeys: keys) {
                return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
            return 0
        }

        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: keys),
               values.isDirectory == false {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
