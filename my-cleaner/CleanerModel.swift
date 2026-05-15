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
    }

    var stage: Stage = .idle
    var droppedApp: DroppedApp?
    var appSize: Int64 = 0
    var items: [RelatedItem] = []
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
        let selected = items.filter(\.isSelected).map(\.url)
        let appURL = app.url
        let allURLs = selected + [appURL]

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
        errorMessage = nil
        isHovering = false
        stage = .idle
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
