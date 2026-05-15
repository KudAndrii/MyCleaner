//
//  AppScanner.swift
//  my-cleaner
//

import Foundation

enum AppScanner {

    nonisolated static func scan(app: DroppedApp) -> ScanResult {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let userLib = home.appendingPathComponent("Library", isDirectory: true)
        let sysLib = URL(fileURLWithPath: "/Library", isDirectory: true)

        // (directory, category, extra descent depth — 0 means top-level only)
        let locations: [(URL, RelatedItem.Category, Int)] = [
            (userLib.appendingPathComponent("Application Support", isDirectory: true), .applicationSupport, 1),
            (userLib.appendingPathComponent("Caches", isDirectory: true), .caches, 1),
            (userLib.appendingPathComponent("Preferences", isDirectory: true), .preferences, 0),
            (userLib.appendingPathComponent("Preferences/ByHost", isDirectory: true), .preferences, 0),
            (userLib.appendingPathComponent("Containers", isDirectory: true), .containers, 0),
            (userLib.appendingPathComponent("Group Containers", isDirectory: true), .groupContainers, 0),
            (userLib.appendingPathComponent("Logs", isDirectory: true), .logs, 1),
            (userLib.appendingPathComponent("Saved Application State", isDirectory: true), .savedState, 0),
            (userLib.appendingPathComponent("HTTPStorages", isDirectory: true), .cookies, 0),
            (userLib.appendingPathComponent("WebKit", isDirectory: true), .cookies, 0),
            (userLib.appendingPathComponent("Cookies", isDirectory: true), .cookies, 0),
            (userLib.appendingPathComponent("LaunchAgents", isDirectory: true), .launchItems, 0),
            (userLib.appendingPathComponent("Application Scripts", isDirectory: true), .scripts, 0),
            (sysLib.appendingPathComponent("Application Support", isDirectory: true), .applicationSupport, 1),
            (sysLib.appendingPathComponent("Caches", isDirectory: true), .caches, 1),
            (sysLib.appendingPathComponent("Preferences", isDirectory: true), .preferences, 0),
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
                extraDepth: descend,
                appPath: appPath,
                into: &found
            )
        }

        let appSize = sizeOfItem(at: app.url, isDirectory: true)
        return ScanResult(appSize: appSize, items: Array(found.values))
    }

    private nonisolated static func scan(
        directory: URL,
        category: RelatedItem.Category,
        app: DroppedApp,
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

            if matches(entry: entry, app: app) {
                if found[std] == nil {
                    let size = sizeOfItem(at: entry, isDirectory: isDir)
                    found[std] = RelatedItem(
                        url: entry,
                        category: category,
                        sizeBytes: size,
                        isDirectory: isDir
                    )
                }
                continue
            }

            if isDir, extraDepth > 0, !shouldSkipDescent(entry) {
                scan(
                    directory: entry,
                    category: category,
                    app: app,
                    extraDepth: extraDepth - 1,
                    appPath: appPath,
                    into: &found
                )
            }
        }
    }

    private nonisolated static func shouldSkipDescent(_ url: URL) -> Bool {
        // Avoid descending into Apple system folders or anything that already looks like a bundle ID.
        let name = url.lastPathComponent
        if name.hasPrefix("com.apple.") { return true }
        if name == "Apple" || name == "CrashReporter" { return true }
        return false
    }

    nonisolated static func matches(entry: URL, app: DroppedApp) -> Bool {
        let full = entry.lastPathComponent.lowercased()
        let base = entry.deletingPathExtension().lastPathComponent.lowercased()

        if let raw = app.bundleID, !raw.isEmpty {
            let bid = raw.lowercased()
            if full == bid || base == bid { return true }
            if full.hasPrefix(bid + ".") || base.hasPrefix(bid + ".") { return true }
            if full == "group.\(bid)" || full.hasPrefix("group.\(bid).") { return true }
        }

        let appName = app.name.lowercased()
        if !appName.isEmpty {
            if base == appName || full == appName { return true }
            if wordBoundaryPrefix(base, prefix: appName) { return true }
            if wordBoundaryPrefix(full, prefix: appName) { return true }
        }
        return false
    }

    /// Returns true if `s` starts with `prefix` and the next character is a non-letter
    /// (digit, dot, space, dash, underscore). Avoids matching "Microsoft" in "MicrosoftAutoUpdate"
    /// while still matching "Rider" in "Rider2024.3" or "Microsoft Word" in "Microsoft Word Data".
    private nonisolated static func wordBoundaryPrefix(_ s: String, prefix: String) -> Bool {
        guard prefix.count >= 3, s.count > prefix.count, s.hasPrefix(prefix) else { return false }
        let next = s[s.index(s.startIndex, offsetBy: prefix.count)]
        return !next.isLetter
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
