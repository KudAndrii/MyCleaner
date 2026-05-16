//
//  RelatedItem.swift
//  my-cleaner
//

import Foundation

/// A single file or folder MyCleaner has attributed to an app (either a
/// dropped app's leftovers, or an orphan group's items).
///
/// `RelatedItem` is the unit the results UI binds against — its
/// `isSelected` flag toggles whether the user wants the entry moved to
/// the Trash, while `isShared` marks entries that are flagged "off by
/// default" because deleting them has cross-app consequences (developer
/// group containers, iCloud Drive documents).
nonisolated struct RelatedItem: Identifiable, Hashable, Sendable {

    /// `Identifiable` conformance — the on-disk URL is the natural identity.
    var id: URL { url }

    /// Absolute file URL of the item.
    let url: URL

    /// Which Library category the item belongs to (used both for the
    /// results-UI grouping and for category-conditional logic like the
    /// iCloud opt-in).
    let category: Category

    /// Total file allocation in bytes — for directories, the sum across
    /// every non-directory descendant.
    let sizeBytes: Int64

    /// `true` if the entry is a folder. Used by the UI for the row icon
    /// and by the size walker to choose between a single-file lookup and
    /// a recursive enumeration.
    let isDirectory: Bool

    /// `true` when deleting this entry has consequences beyond the single
    /// app being uninstalled — e.g. a team-prefixed group container
    /// shared between every app from the same developer, or an iCloud
    /// Drive document that syncs to the user's other devices. The UI
    /// surfaces these with a distinct visual cue.
    let isShared: Bool

    /// `true` if the row's checkbox is ticked.
    ///
    /// Defaults to `!isShared`: items that are safe for default-on get
    /// selected automatically, items flagged shared start unticked and
    /// require explicit opt-in.
    var isSelected: Bool

    /// Build a `RelatedItem` for a file or folder discovered during scanning.
    ///
    /// - Parameters:
    ///   - url: Absolute file URL of the item.
    ///   - category: Library category the entry was found under.
    ///   - sizeBytes: Total allocation in bytes (already summed for
    ///     directories).
    ///   - isDirectory: Whether the URL points at a folder.
    ///   - isShared: Pass `true` to force the row off by default. Used
    ///     for team-prefix group containers and iCloud-synced entries.
    init(url: URL, category: Category, sizeBytes: Int64, isDirectory: Bool, isShared: Bool = false) {
        self.url = url
        self.category = category
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.isShared = isShared
        self.isSelected = !isShared
    }

    /// Library categories surfaced as section headers in the results UI.
    ///
    /// `Category.allCases` is also used to define the section order — the
    /// declaration order here is the order rows appear on screen.
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
        case scripts = "Application Scripts"
        case iCloud = "iCloud Documents"
        case other = "Other"

        /// SF Symbol name for the section header icon.
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
            case .scripts: "scroll.fill"
            case .iCloud: "icloud.fill"
            case .other: "folder.fill"
            }
        }
    }
}
