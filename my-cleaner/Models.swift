//
//  Models.swift
//  my-cleaner
//

import Foundation

// MARK: - Dropped app

/// A `.app` bundle the user has dropped into the app for analysis.
///
/// Initialisation reads the bundle's `Info.plist` (when present) to
/// pick up the bundle ID and display name. Anything that can't be
/// parsed falls back to the filename, so the type also covers
/// malformed bundles a user might drop in by accident.
nonisolated struct DroppedApp: Identifiable, Hashable, Sendable {
    /// Identity is the on-disk URL of the bundle.
    var id: URL { url }

    /// The bundle URL on disk.
    let url: URL

    /// Human-readable name, preferring `CFBundleDisplayName` and falling back to
    /// `CFBundleName`, then the bundle's filename.
    let name: String

    /// The bundle identifier from `Info.plist`, or `nil` for malformed bundles.
    let bundleID: String?

    /// Builds a ``DroppedApp`` from a URL.
    ///
    /// - Parameter url: The path the user dropped or selected.
    /// - Returns: `nil` if `url` doesn't end in `.app` (case-insensitive).
    init?(url: URL) {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        self.url = url
        let bundle = Bundle(url: url)
        self.bundleID = bundle?.bundleIdentifier
        let info = bundle?.infoDictionary
        let display = info?["CFBundleDisplayName"] as? String
        let name = info?["CFBundleName"] as? String
        self.name = display ?? name ?? url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Scan results

/// The output of an app-specific scan: the app's own on-disk size plus
/// every related Library entry the scanner found.
nonisolated struct ScanResult: Sendable {
    /// On-disk allocated size of the `.app` bundle itself, in bytes.
    let appSize: Int64

    /// Library entries that look like they belong to the dropped app.
    let items: [RelatedItem]

    /// System extensions registered by the dropped app. These can't
    /// be moved to the Trash — removal goes through `systemextensionsctl`
    /// or System Settings. Empty when the app didn't register any.
    let systemExtensions: [SystemExtensionInfo]

    init(
        appSize: Int64,
        items: [RelatedItem],
        systemExtensions: [SystemExtensionInfo] = []
    ) {
        self.appSize = appSize
        self.items = items
        self.systemExtensions = systemExtensions
    }
}

/// A single Library entry attributed to a dropped app (or an orphan group).
///
/// The same type is used for app-specific and orphan flows so the UI
/// can render them uniformly.
nonisolated struct RelatedItem: Identifiable, Hashable, Sendable {
    /// Identity is the entry's URL.
    var id: URL { url }

    /// On-disk URL of the entry.
    let url: URL

    /// Which Library bucket this entry belongs to (drives the UI section header).
    let category: Category

    /// Allocated size of the entry on disk, in bytes.
    let sizeBytes: Int64

    /// Whether the entry is a directory (governs how size was summed).
    let isDirectory: Bool

    /// Marks entries that are shared between apps or sync to other devices
    /// (team-prefixed Group Containers, iCloud Documents). Shared entries
    /// default to **unselected** so the user has to opt in.
    let isShared: Bool

    /// Whether the user has currently selected this entry for deletion.
    ///
    /// Mirrors `!isShared` at construction time; toggled by the UI.
    var isSelected: Bool

    /// - Parameter isShared: When `true`, the entry is created **unselected**.
    init(url: URL, category: Category, sizeBytes: Int64, isDirectory: Bool, isShared: Bool = false) {
        self.url = url
        self.category = category
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.isShared = isShared
        self.isSelected = !isShared
    }

    /// Buckets the UI groups related items into.
    ///
    /// The raw value is the user-visible section header. The order of
    /// `allCases` is also used by the model to sort items within a
    /// result list (most user-relevant categories first).
    enum Category: String, CaseIterable, Hashable, Sendable {
        case applicationSupport = "Application Support"
        case caches = "Caches"
        case preferences = "Preferences"
        case containers = "Containers"
        case groupContainers = "Group Containers"
        case logs = "Logs"
        case crashReports = "Crash Reports"
        case savedState = "Saved Application State"
        case cookies = "Cookies & Web Data"
        case launchItems = "Launch Items"
        case installerFiles = "Installer Files"
        case scripts = "Application Scripts"
        case iCloud = "iCloud Documents"
        case other = "Other"

        /// SF Symbol name shown next to the section header.
        var symbol: String {
            switch self {
            case .applicationSupport: "shippingbox.fill"
            case .caches: "externaldrive.fill"
            case .preferences: "gearshape.fill"
            case .containers: "cube.fill"
            case .groupContainers: "square.stack.3d.up.fill"
            case .logs: "doc.text.fill"
            case .crashReports: "exclamationmark.triangle.fill"
            case .savedState: "clock.arrow.circlepath"
            case .cookies: "globe"
            case .launchItems: "play.circle.fill"
            case .installerFiles: "archivebox.fill"
            case .scripts: "scroll.fill"
            case .iCloud: "icloud.fill"
            case .other: "folder.fill"
            }
        }
    }
}

// MARK: - Cleanup report

/// The outcome of a cleanup pass — how many items reached the Trash and what,
/// if anything, refused to move (with the OS error message).
nonisolated struct CleanupReport: Sendable, Equatable, Hashable {
    /// Items trashed via the normal user-level `trashItem` call.
    let trashedNormally: Int

    /// Items trashed after a privileged second-pass elevation prompt.
    let trashedWithElevation: Int

    /// Items that couldn't be trashed even after elevation.
    let failures: [Failure]

    /// Total items the OS accepted into the Trash.
    var trashed: Int { trashedNormally + trashedWithElevation }

    /// A single per-URL failure carried in ``CleanupReport/failures``.
    nonisolated struct Failure: Sendable, Equatable, Hashable, Identifiable {
        var id: URL { url }

        /// The URL that couldn't be moved.
        let url: URL

        /// Localised error message returned by the OS or elevation helper.
        let message: String
    }
}

// MARK: - Environment

/// Reports whether the running process is currently inside an App Sandbox container.
///
/// Used by the UI to surface a banner explaining why some destinations
/// (e.g. `/Library`) won't be reachable in a sandboxed build.
enum SandboxStatus {
    /// `true` when either the sandbox environment variable is set or the
    /// process is running from `~/Library/Containers/`.
    static var isSandboxed: Bool {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home.contains("/Library/Containers/")
    }
}
