//
//  CleanerModel.swift
//  my-cleaner
//

import Foundation
import Observation
import AppKit

@Observable
final class CleanerModel {

    enum Stage: Equatable {
        case idle
        case analyzing
        case results
        case cleaning
        case done(CleanupReport)
        case orphanScanning
        case orphanResults
    }

    var stage: Stage = .idle
    var droppedApp: DroppedApp?
    var appSize: Int64 = 0
    var items: [RelatedItem] = []
    var orphanGroups: [OrphanGroup] = []
    var errorMessage: String?
    var isHovering: Bool = false

    var selectedCount: Int { items.lazy.filter(\.isSelected).count }
    var selectedSize: Int64 { items.lazy.filter(\.isSelected).map(\.sizeBytes).reduce(0, +) }
    var totalSize: Int64 { items.map(\.sizeBytes).reduce(0, +) }
    var trashTotal: Int64 { selectedSize + appSize }
    var allSelected: Bool { !items.isEmpty && items.allSatisfy(\.isSelected) }

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
        stage = .results
    }

    func toggleAll() {
        let target = !allSelected
        for i in items.indices { items[i].isSelected = target }
    }

    func confirmCleanup() async {
        guard let app = droppedApp else { return }
        stage = .cleaning
        let selected = items.filter(\.isSelected)
        let selectedURLs = selected.map(\.url)
        let appURL = app.url
        let allURLs = selectedURLs + [appURL]
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

        let firstPass = await Task.detached(priority: .userInitiated) { () -> FirstPassResult in
            var trashed = 0
            var failed: [URL] = []
            var messages: [URL: String] = [:]
            let fm = FileManager.default
            for url in allURLs {
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
                let msg = elevation.errorMessage ?? firstPass.messages[url] ?? "Item could not be moved to the Trash."
                failures.append(.init(url: url, message: msg))
            }
        }

        // Drop the cfprefsd in-memory cache so deleted plists don't get
        // re-synced from RAM, and clear the bundle ID's TCC grants so the
        // entries don't linger in System Settings → Privacy & Security.
        await Task.detached(priority: .userInitiated) {
            if touchedPreferences {
                CleanupActions.killCfprefsd()
            }
            if let bid = bundleID, !bid.isEmpty {
                CleanupActions.resetTCC(forBundleID: bid)
            }
        }.value

        stage = .done(CleanupReport(
            trashedNormally: firstPass.trashed,
            trashedWithElevation: elevatedSucceeded,
            failures: failures
        ))
    }

    func reset() {
        droppedApp = nil
        appSize = 0
        items = []
        orphanGroups = []
        errorMessage = nil
        isHovering = false
        stage = .idle
    }

    // MARK: - Orphan scan

    var orphanSelectedCount: Int {
        orphanGroups.reduce(0) { $0 + ($1.isSelected ? $1.items.count : 0) }
    }
    var orphanSelectedSize: Int64 {
        orphanGroups.reduce(0) { $0 + ($1.isSelected ? $1.totalSize : 0) }
    }
    var orphanTotalSize: Int64 {
        orphanGroups.map(\.totalSize).reduce(0, +)
    }
    var allOrphansSelected: Bool {
        !orphanGroups.isEmpty && orphanGroups.allSatisfy(\.isSelected)
    }

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

    func toggleOrphanGroup(id: String) {
        guard let i = orphanGroups.firstIndex(where: { $0.id == id }) else { return }
        orphanGroups[i].isSelected.toggle()
    }

    func toggleAllOrphans() {
        let target = !allOrphansSelected
        for i in orphanGroups.indices { orphanGroups[i].isSelected = target }
    }

    func confirmOrphanCleanup() async {
        let selected = orphanGroups.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        stage = .cleaning

        let urls = selected.flatMap { $0.items.map(\.url) }
        let bundleIDs = selected.map(\.bundleID)
        let touchedPreferences = selected
            .flatMap(\.items)
            .contains { $0.category == .preferences }

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
                let msg = elevation.errorMessage ?? firstPass.messages[url] ?? "Item could not be moved to the Trash."
                failures.append(.init(url: url, message: msg))
            }
        }

        await Task.detached(priority: .userInitiated) {
            if touchedPreferences {
                CleanupActions.killCfprefsd()
            }
            for bid in bundleIDs {
                CleanupActions.resetTCC(forBundleID: bid)
            }
        }.value

        stage = .done(CleanupReport(
            trashedNormally: firstPass.trashed,
            trashedWithElevation: elevatedSucceeded,
            failures: failures
        ))
    }
}

private struct FirstPassResult: Sendable {
    let trashed: Int
    let failed: [URL]
    let messages: [URL: String]
}

private nonisolated func categoryOrder(_ c: RelatedItem.Category) -> Int {
    RelatedItem.Category.allCases.firstIndex(of: c) ?? Int.max
}
