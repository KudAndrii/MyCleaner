//
//  CleanerModel.swift
//  my-cleaner
//

import Foundation
import Observation
import AppKit

/// Observable state for the cleanup UI.
///
/// Owns the `Stage` machine, both result lists (per-app and orphan),
/// and the two cleanup flows. The flows have the same shape:
///
///   1. Move a list of URLs to the Trash, capturing per-URL failures.
///   2. Re-try every failure via an admin-elevated helper.
///   3. Drop side-effects that survive a Trash move (cfprefsd cache,
///      TCC grants) so the UI doesn't appear to have left state behind.
///
/// Both flows funnel into ``trashURLs(_:)``; their differences are
/// confined to which URLs they collect and which side-effects they
/// trigger.
@Observable
final class CleanerModel {

    /// High-level UI phase.
    ///
    /// Used by the view layer to pick which screen to show. The
    /// `done(_:)` case carries the final ``CleanupReport`` so the
    /// summary screen can render counts and per-URL failures without
    /// re-reading model state.
    enum Stage: Equatable {
        case idle
        case analyzing
        case results
        case cleaning
        case done(CleanupReport)
        case orphanScanning
        case orphanResults
    }

    // MARK: - Shared state

    var stage: Stage = .idle
    var droppedApp: DroppedApp?
    var appSize: Int64 = 0
    var items: [RelatedItem] = []
    var systemExtensions: [SystemExtensionInfo] = []
    var orphanGroups: [OrphanGroup] = []
    var errorMessage: String?
    var isHovering: Bool = false

    // MARK: - Login items (opt-in)

    /// Whether the user has opted into reading SMAppService /
    /// background-task-manager entries. Defaults to `false` because
    /// `sfltool dumpbtm` requires an admin password prompt. The
    /// preference is **session-only** — every relaunch starts off so
    /// the user is never surprised by a credential prompt on startup.
    var loginItemsEnabled: Bool = false

    /// Snapshot of every btm entry returned by `sfltool dumpbtm` the
    /// last time the user enabled the toggle. Cached for the lifetime
    /// of the process so dropping a second app — or toggling off and
    /// back on — doesn't re-prompt. `nil` until the first successful
    /// fetch.
    var cachedAllLoginItems: [LoginItemInfo]?

    /// Team identifier of the most recently dropped app. Stored so
    /// the login-items filter can use the team-ID fallback without
    /// re-reading the bundle's signature.
    var currentTeamID: String?

    /// Login items attributable to the currently dropped app.
    ///
    /// Returns an empty array when the toggle is off, no app is
    /// dropped, or the cache hasn't been populated yet. Filters the
    /// cached snapshot through ``LoginItems/matches(_:bundleID:teamID:)``
    /// so the predicate stays in one place.
    var loginItems: [LoginItemInfo] {
        guard loginItemsEnabled,
              let cache = cachedAllLoginItems,
              let app = droppedApp else { return [] }
        return cache.filter {
            LoginItems.matches($0, bundleID: app.bundleID, teamID: currentTeamID)
        }
    }

    // MARK: - Per-app selection (derived)

    /// Number of items the user has selected for deletion in the per-app flow.
    var selectedCount: Int { items.lazy.filter(\.isSelected).count }

    /// Bytes the user has selected for deletion in the per-app flow.
    var selectedSize: Int64 { items.lazy.filter(\.isSelected).map(\.sizeBytes).reduce(0, +) }

    /// Bytes across every related item, regardless of selection.
    var totalSize: Int64 { items.map(\.sizeBytes).reduce(0, +) }

    /// Bytes that will go to the Trash if the user confirms — selected items + the app itself.
    var trashTotal: Int64 { selectedSize + appSize }

    /// `true` when every related item is selected (and the list isn't empty).
    var allSelected: Bool { !items.isEmpty && items.allSatisfy(\.isSelected) }

    // MARK: - Per-app flow

    /// Validates a dropped URL, starts the scan, and parks the result
    /// on `items`. Updates `errorMessage` when the URL isn't a `.app`.
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
        items = result.items.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return categoryOrder(lhs.category) < categoryOrder(rhs.category)
            }
            return lhs.sizeBytes > rhs.sizeBytes
        }
        systemExtensions = result.systemExtensions
        currentTeamID = result.teamID
        stage = .results
    }

    /// Flips the opt-in login-items toggle.
    ///
    /// Enabling for the first time runs `sfltool dumpbtm` (which
    /// triggers the admin prompt) and caches the parsed result.
    /// Subsequent enables — including after toggling off and back on,
    /// or after dropping a different app — reuse the cached snapshot
    /// without re-prompting.
    ///
    /// If the shell-out fails (user cancels the prompt, `sfltool`
    /// exits non-zero), the toggle is left in the off position so the
    /// UI accurately reflects "no data".
    func setLoginItemsEnabled(_ enabled: Bool) async {
        if enabled, cachedAllLoginItems == nil {
            let fetched = await Task.detached(priority: .userInitiated) {
                LoginItems.allItems()
            }.value
            guard let fetched else {
                // Cancellation or failure — keep the toggle off.
                loginItemsEnabled = false
                return
            }
            cachedAllLoginItems = fetched
        }
        loginItemsEnabled = enabled
    }

    /// Asks macOS to uninstall a system extension via
    /// `systemextensionsctl uninstall`. The OS shows its own
    /// confirmation prompt; this method returns once the command
    /// exits, regardless of whether the user approved removal.
    ///
    /// Removes the entry from ``systemExtensions`` on success so the
    /// UI updates without re-scanning. Failures leave the row in
    /// place; callers can prompt the user to remove it via System
    /// Settings instead.
    @discardableResult
    func uninstallSystemExtension(_ ext: SystemExtensionInfo) async -> Bool {
        let ok = await Task.detached(priority: .userInitiated) {
            SystemExtensions.uninstall(ext)
        }.value
        if ok {
            systemExtensions.removeAll { $0.id == ext.id }
        }
        return ok
    }

    /// Flips every item to/from selected based on whether anything is currently unselected.
    func toggleAll() {
        let target = !allSelected
        for i in items.indices { items[i].isSelected = target }
    }

    /// Moves selected items plus the app itself to the Trash, then
    /// drops bundle-scoped side-effects (LaunchAgents, cfprefsd cache,
    /// TCC grants) and transitions to `.done`.
    func confirmCleanup() async {
        guard let app = droppedApp else { return }
        stage = .cleaning

        let selected = items.filter(\.isSelected)
        let urlsToTrash = selected.map(\.url) + [app.url]
        let launchItemURLs = selected.filter { $0.category == .launchItems }.map(\.url)
        let touchedPreferences = selected.contains { $0.category == .preferences }
        let bundleID = app.bundleID

        // Best-effort: bootout any LaunchAgents/Daemons before their plist is
        // moved to the Trash. Otherwise the in-memory job survives and the
        // helper keeps running until reboot.
        if !launchItemURLs.isEmpty {
            await Task.detached(priority: .userInitiated) {
                CleanupActions.bootoutLaunchItems(at: launchItemURLs)
            }.value
        }

        let report = await trashURLs(urlsToTrash)

        await Task.detached(priority: .userInitiated) {
            // Drop the cfprefsd in-memory cache so deleted plists don't get
            // re-synced from RAM, and clear the bundle ID's TCC grants so the
            // entries don't linger in System Settings → Privacy & Security.
            if touchedPreferences {
                CleanupActions.killCfprefsd()
            }
            if let bid = bundleID, !bid.isEmpty {
                CleanupActions.resetTCC(forBundleID: bid)
            }
        }.value

        stage = .done(report)
    }

    /// Returns the model to its initial state. Used when the user
    /// clicks "Done" or drops a second app on the dropzone.
    func reset() {
        droppedApp = nil
        appSize = 0
        items = []
        systemExtensions = []
        currentTeamID = nil
        orphanGroups = []
        errorMessage = nil
        isHovering = false
        stage = .idle
        // `loginItemsEnabled` and `cachedAllLoginItems` deliberately
        // survive reset — once the user has paid the admin-prompt
        // cost, we don't want to re-prompt because they dropped a
        // second app.
    }

    // MARK: - Orphan selection (derived)

    /// Items across every **selected** orphan group.
    var orphanSelectedCount: Int {
        orphanGroups.reduce(0) { $0 + ($1.isSelected ? $1.items.count : 0) }
    }

    /// Bytes across every **selected** orphan group.
    var orphanSelectedSize: Int64 {
        orphanGroups.reduce(0) { $0 + ($1.isSelected ? $1.totalSize : 0) }
    }

    /// Bytes across every orphan group, regardless of selection.
    var orphanTotalSize: Int64 {
        orphanGroups.map(\.totalSize).reduce(0, +)
    }

    /// `true` when every orphan group is selected (and the list isn't empty).
    var allOrphansSelected: Bool {
        !orphanGroups.isEmpty && orphanGroups.allSatisfy(\.isSelected)
    }

    // MARK: - Orphan flow

    /// Kicks off the orphan scan and parks the result on `orphanGroups`.
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

    /// Flips a single orphan group's selection. No-op for unknown ids.
    func toggleOrphanGroup(id: String) {
        guard let i = orphanGroups.firstIndex(where: { $0.id == id }) else { return }
        orphanGroups[i].isSelected.toggle()
    }

    /// Flips every orphan group to/from selected based on whether
    /// anything is currently unselected.
    func toggleAllOrphans() {
        let target = !allOrphansSelected
        for i in orphanGroups.indices { orphanGroups[i].isSelected = target }
    }

    /// Moves every item in every selected orphan group to the Trash,
    /// then drops the same side-effects as the per-app flow but for
    /// every bundle ID across the selected groups.
    func confirmOrphanCleanup() async {
        let selected = orphanGroups.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        stage = .cleaning

        let urls = selected.flatMap { $0.items.map(\.url) }
        let bundleIDs = selected.map(\.bundleID)
        let touchedPreferences = selected
            .flatMap(\.items)
            .contains { $0.category == .preferences }

        let report = await trashURLs(urls)

        await Task.detached(priority: .userInitiated) {
            if touchedPreferences {
                CleanupActions.killCfprefsd()
            }
            for bid in bundleIDs {
                CleanupActions.resetTCC(forBundleID: bid)
            }
        }.value

        stage = .done(report)
    }

    // MARK: - Shared trash plumbing

    /// Moves every URL to the Trash, retries refusals via the
    /// admin-elevated helper, and aggregates everything into a
    /// ``CleanupReport``.
    ///
    /// Shared by ``confirmCleanup()`` and ``confirmOrphanCleanup()``;
    /// both flows have identical retry / error-mapping requirements
    /// so the duplication isn't worth keeping.
    private func trashURLs(_ urls: [URL]) async -> CleanupReport {
        let firstPass = await Task.detached(priority: .userInitiated) { () -> FirstPassResult in
            var trashed = 0
            var failed: [URL] = []
            var messages: [URL: String] = [:]
            let fm = FileManager.default
            for url in urls {
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                    trashed += 1
                } catch {
                    failed.append(url)
                    messages[url] = error.localizedDescription
                }
            }
            return FirstPassResult(trashed: trashed, failed: failed, messages: messages)
        }.value

        var elevatedSucceeded = 0
        var failures: [CleanupReport.Failure] = []

        if !firstPass.failed.isEmpty {
            let elevation = await AdminTrash.move(urls: firstPass.failed)
            elevatedSucceeded = elevation.succeeded.count
            for url in elevation.refused {
                let msg = elevation.errorMessage
                    ?? firstPass.messages[url]
                    ?? "Item could not be moved to the Trash."
                failures.append(.init(url: url, message: msg))
            }
        }

        return CleanupReport(
            trashedNormally: firstPass.trashed,
            trashedWithElevation: elevatedSucceeded,
            failures: failures
        )
    }
}

// MARK: - File-private helpers

/// First-pass trash outcome — split out so the detached closure stays
/// `Sendable`. Not exposed beyond ``CleanerModel/trashURLs(_:)``.
private nonisolated struct FirstPassResult: Sendable {
    let trashed: Int
    let failed: [URL]
    let messages: [URL: String]
}

/// Display order for `RelatedItem.Category` — uses `allCases` order so
/// adding a new case to the enum implicitly sorts it correctly.
private nonisolated func categoryOrder(_ c: RelatedItem.Category) -> Int {
    RelatedItem.Category.allCases.firstIndex(of: c) ?? Int.max
}
