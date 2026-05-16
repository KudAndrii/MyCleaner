//
//  CleanerModel.swift
//  my-cleaner
//

import Foundation
import Observation
import AppKit

/// The view model driving every screen.
///
/// `CleanerModel` owns the stage machine (`Stage`), the data the
/// SwiftUI views bind against, and the orchestration of the two cleanup
/// flows:
///
/// - **App-deletion flow.** `handleDrop(url:)` → `AppScanner.scan(app:)`
///   → user toggles → `confirmCleanup()` → `TrashPipeline.run(urls:)`.
/// - **Orphan-files flow.** `startOrphanScan()` → `OrphanScanner.scan()`
///   → user picks groups → `confirmOrphanCleanup()` →
///   `TrashPipeline.run(urls:)`.
///
/// Heavy work (scanning, trashing, AppleScript calls) is always
/// dispatched to a `Task.detached` so the main actor stays responsive.
/// The model itself runs on the main actor — `@Observable` automatically
/// notifies SwiftUI views of property changes.
@Observable
final class CleanerModel {

    /// High-level UI stage. Drives the `switch` in `ContentView` that
    /// chooses which screen to render.
    enum Stage: Equatable {
        case idle
        case analyzing
        case results
        case cleaning
        case done(CleanupReport)
        case orphanScanning
        case orphanResults
    }

    // MARK: - Observable state (consumed by views)

    /// Current screen the UI should render. Setting this triggers the
    /// stage transition animation in `ContentView`.
    var stage: Stage = .idle

    /// The dropped or picked app being cleaned. `nil` until the user
    /// drops something or starts the orphan flow.
    var droppedApp: DroppedApp?

    /// On-disk size of the dropped app bundle itself, in bytes.
    var appSize: Int64 = 0

    /// Leftover items found by the app scan. Sorted by category, then by
    /// size descending.
    var items: [RelatedItem] = []

    /// Groups produced by the orphan scan, sorted by `totalSize`
    /// descending.
    var orphanGroups: [OrphanGroup] = []

    /// Last user-facing error message, surfaced in the drop zone.
    /// `nil` when there's nothing to report.
    var errorMessage: String?

    /// Whether the drop zone currently has a drag operation hovering
    /// over it. Drives the hover animation.
    var isHovering: Bool = false

    // MARK: - App-scan derived state

    /// Number of currently-selected items in the app-scan results.
    var selectedCount: Int { items.lazy.filter(\.isSelected).count }

    /// Total size of currently-selected items, in bytes.
    var selectedSize: Int64 { items.lazy.filter(\.isSelected).map(\.sizeBytes).reduce(0, +) }

    /// Total size of every item found by the app scan, in bytes.
    var totalSize: Int64 { items.map(\.sizeBytes).reduce(0, +) }

    /// Total size that will be trashed, including the app bundle itself.
    var trashTotal: Int64 { selectedSize + appSize }

    /// `true` when every found item is ticked.
    var allSelected: Bool { !items.isEmpty && items.allSatisfy(\.isSelected) }

    // MARK: - Orphan-scan derived state

    /// Number of items in every selected orphan group.
    var orphanSelectedCount: Int {
        orphanGroups.reduce(0) { $0 + ($1.isSelected ? $1.items.count : 0) }
    }

    /// Total size of every selected orphan group, in bytes.
    var orphanSelectedSize: Int64 {
        orphanGroups.reduce(0) { $0 + ($1.isSelected ? $1.totalSize : 0) }
    }

    /// Total size of every orphan group found, in bytes.
    var orphanTotalSize: Int64 {
        orphanGroups.map(\.totalSize).reduce(0, +)
    }

    /// `true` when every orphan group is ticked.
    var allOrphansSelected: Bool {
        !orphanGroups.isEmpty && orphanGroups.allSatisfy(\.isSelected)
    }

    // MARK: - App-deletion flow

    /// Handle a dropped URL: validate it's an `.app`, kick off the scan,
    /// and advance the stage machine accordingly.
    ///
    /// - Parameter url: The URL the user dropped or picked.
    func handleDrop(url: URL) async {
        guard let app = DroppedApp(url: url) else {
            errorMessage = "That doesn't look like an application."
            return
        }
        errorMessage = nil
        droppedApp = app
        items = []
        appSize = 0
        stage = .analyzing

        let result = await Task.detached(priority: .userInitiated) {
            AppScanner.scan(app: app)
        }.value

        appSize = result.appSize
        items = result.items.sorted(by: Self.appScanItemOrder)
        stage = .results
    }

    /// Flip every row's checkbox in unison. If everything is currently
    /// ticked, this deselects all; otherwise it selects all.
    func toggleAll() {
        let target = !allSelected
        for i in items.indices { items[i].isSelected = target }
    }

    /// Move every selected leftover, plus the app bundle itself, to the
    /// Trash. Runs the post-trash bookkeeping (launchctl bootout,
    /// cfprefsd flush, TCC reset) around the trash pipeline.
    func confirmCleanup() async {
        guard let app = droppedApp else { return }
        stage = .cleaning

        let selected = items.filter(\.isSelected)
        let urls = selected.map(\.url) + [app.url]
        let launchItemURLs = selected.filter { $0.category == .launchItems }.map(\.url)
        let touchedPreferences = selected.contains { $0.category == .preferences }
        let bundleID = app.bundleID

        // Pre-step: bootout any LaunchAgents/Daemons before their plist
        // is trashed. Otherwise the in-memory job survives until reboot.
        if !launchItemURLs.isEmpty {
            await Task.detached(priority: .userInitiated) {
                CleanupActions.bootoutLaunchItems(at: launchItemURLs)
            }.value
        }

        let report = await TrashPipeline.run(urls: urls)

        let bundleIDsToReset: [String] = {
            guard let bid = bundleID, !bid.isEmpty else { return [] }
            return [bid]
        }()
        await Self.runPostTrashBookkeeping(
            touchedPreferences: touchedPreferences,
            bundleIDsToReset: bundleIDsToReset
        )

        stage = .done(report)
    }

    /// Reset every observable property back to `idle`. Called from the
    /// "Clean another app" button on the done screen and from the
    /// Cancel button on the results screens.
    func reset() {
        droppedApp = nil
        appSize = 0
        items = []
        orphanGroups = []
        errorMessage = nil
        isHovering = false
        stage = .idle
    }

    // MARK: - Orphan-files flow

    /// Kick off the orphan scan and advance the stage machine.
    func startOrphanScan() async {
        errorMessage = nil
        orphanGroups = []
        stage = .orphanScanning

        let result = await Task.detached(priority: .userInitiated) {
            OrphanScanner.scan()
        }.value

        orphanGroups = result.groups
        stage = .orphanResults
    }

    /// Flip the selection state of a single orphan group.
    ///
    /// - Parameter id: The bundle ID of the group to toggle.
    func toggleOrphanGroup(id: String) {
        guard let i = orphanGroups.firstIndex(where: { $0.id == id }) else { return }
        orphanGroups[i].isSelected.toggle()
    }

    /// Flip every orphan group's checkbox in unison.
    func toggleAllOrphans() {
        let target = !allOrphansSelected
        for i in orphanGroups.indices { orphanGroups[i].isSelected = target }
    }

    /// Move every item in every selected orphan group to the Trash, plus
    /// the post-trash bookkeeping (cfprefsd flush, TCC reset per bundle
    /// ID).
    func confirmOrphanCleanup() async {
        let selected = orphanGroups.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        stage = .cleaning

        let urls = selected.flatMap { $0.items.map(\.url) }
        let bundleIDs = selected.map(\.bundleID)
        let touchedPreferences = selected
            .flatMap(\.items)
            .contains { $0.category == .preferences }

        let report = await TrashPipeline.run(urls: urls)

        await Self.runPostTrashBookkeeping(
            touchedPreferences: touchedPreferences,
            bundleIDsToReset: bundleIDs
        )

        stage = .done(report)
    }

    // MARK: - Private helpers

    /// Sort key used to order app-scan results.
    ///
    /// Items are grouped by category (in the declaration order of
    /// `RelatedItem.Category.allCases`) and within each category sorted
    /// by `sizeBytes` descending so the biggest leftovers float to the
    /// top of each section.
    private nonisolated static func appScanItemOrder(_ lhs: RelatedItem, _ rhs: RelatedItem) -> Bool {
        if lhs.category != rhs.category {
            return categoryOrder(lhs.category) < categoryOrder(rhs.category)
        }
        return lhs.sizeBytes > rhs.sizeBytes
    }

    /// Position of `category` in `RelatedItem.Category.allCases`.
    /// Used as a numeric sort key.
    private nonisolated static func categoryOrder(_ category: RelatedItem.Category) -> Int {
        RelatedItem.Category.allCases.firstIndex(of: category) ?? Int.max
    }

    /// Run the post-trash housekeeping macOS won't do for us
    /// automatically: kill cfprefsd if any preference plists were
    /// removed (otherwise the daemon re-syncs them from RAM), and clear
    /// TCC grants for each bundle ID (otherwise the rows linger in
    /// System Settings → Privacy & Security).
    ///
    /// - Parameters:
    ///   - touchedPreferences: `true` if any item under the
    ///     `.preferences` category was trashed.
    ///   - bundleIDsToReset: Bundle IDs whose TCC grants should be
    ///     cleared. Empty strings are skipped.
    private nonisolated static func runPostTrashBookkeeping(
        touchedPreferences: Bool,
        bundleIDsToReset: [String]
    ) async {
        await Task.detached(priority: .userInitiated) {
            if touchedPreferences {
                CleanupActions.killCfprefsd()
            }
            for bundleID in bundleIDsToReset where !bundleID.isEmpty {
                CleanupActions.resetTCC(forBundleID: bundleID)
            }
        }.value
    }
}
