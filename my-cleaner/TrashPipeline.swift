//
//  TrashPipeline.swift
//  my-cleaner
//
//  Shared "move every URL to the Trash, fall back to elevation on
//  refusals" pipeline. Both the per-app and orphan cleanup flows use it,
//  so the two-pass logic and the failure-message bookkeeping live here
//  in one place instead of being duplicated in `CleanerModel`.
//

import Foundation

/// Moves a batch of URLs to the user's Trash.
///
/// Two passes:
/// 1. Try `FileManager.trashItem` for each URL on the calling task.
/// 2. For any URL the first pass refused, escalate through
///    `AdminTrash.move(urls:)` — a single AppleScript invocation that
///    prompts for the admin password once and `mv`s the refused items
///    into `~/.Trash`.
///
/// Anything still on disk after both passes lands in `failures`, paired
/// with the most informative error string we can produce — the elevation
/// script's error if it provided one, otherwise the original
/// `FileManager` error for that URL.
enum TrashPipeline {

    /// Run both trash passes and return a populated `CleanupReport`.
    ///
    /// - Parameter urls: Every URL to move to the Trash. Order is
    ///   preserved across the first-pass loop, but the report's counts
    ///   are aggregate so order isn't user-visible.
    /// - Returns: A `CleanupReport` summarising the outcome.
    nonisolated static func run(urls: [URL]) async -> CleanupReport {
        let firstPass = await Task.detached(priority: .userInitiated) {
            firstPass(urls: urls)
        }.value

        var elevatedSucceeded = 0
        var failures: [CleanupReport.Failure] = []

        if !firstPass.failed.isEmpty {
            let elevation = await AdminTrash.move(urls: firstPass.failed)
            elevatedSucceeded = elevation.succeeded.count
            for url in elevation.refused {
                let message = elevation.errorMessage
                    ?? firstPass.messages[url]
                    ?? "Item could not be moved to the Trash."
                failures.append(CleanupReport.Failure(url: url, message: message))
            }
        }

        return CleanupReport(
            trashedNormally: firstPass.trashed,
            trashedWithElevation: elevatedSucceeded,
            failures: failures
        )
    }

    /// Result of the unprivileged first pass, ready to feed into the
    /// elevation step.
    private struct FirstPassOutcome: Sendable {
        let trashed: Int
        let failed: [URL]
        let messages: [URL: String]
    }

    /// First pass: try `FileManager.trashItem` for every URL, recording
    /// successes, failures, and per-URL error messages.
    ///
    /// Failures are most commonly "the item is owned by root:wheel" for
    /// LaunchDaemon plists installed by a `.pkg`. The elevation pass
    /// handles those.
    private nonisolated static func firstPass(urls: [URL]) -> FirstPassOutcome {
        let fm = FileManager.default
        var trashed = 0
        var failed: [URL] = []
        var messages: [URL: String] = [:]
        for url in urls {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                trashed += 1
            } catch {
                failed.append(url)
                messages[url] = error.localizedDescription
            }
        }
        return FirstPassOutcome(trashed: trashed, failed: failed, messages: messages)
    }
}
