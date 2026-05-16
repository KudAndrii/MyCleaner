//
//  ScanResult.swift
//  my-cleaner
//

import Foundation

/// The output of an app scan: how big the `.app` bundle itself is, and
/// every Library entry MyCleaner has attributed to it.
///
/// `Sendable` so it can be returned across a `Task.detached` boundary
/// from the background scanner into the `@MainActor`-isolated model.
nonisolated struct ScanResult: Sendable {

    /// Total allocation of the `.app` bundle on disk, in bytes.
    let appSize: Int64

    /// Leftover files and folders MyCleaner matched to the dropped app.
    /// Already deduplicated by URL; order is not significant — the model
    /// sorts before handing the list to the UI.
    let items: [RelatedItem]
}
