//
//  CategoryClassifier.swift
//  my-cleaner
//

import Foundation

/// Classify a file path into a `RelatedItem.Category` from the directory
/// segments it contains.
///
/// Used by the Spotlight supplement pass in `AppScanner`: hand-rolled
/// directory walks already know the category they're scanning, but
/// Spotlight results arrive flat and need to be sorted back under the
/// correct results-UI header.
enum CategoryClassifier {

    /// Match `path` against the known Library category folder names and
    /// return the first hit.
    ///
    /// The classifier walks the categories in priority order so the more
    /// specific paths win — e.g. `Logs/DiagnosticReports/…` resolves to
    /// `.crashReports` before reaching the generic `.logs` rule.
    ///
    /// - Parameter path: An absolute file path to classify.
    /// - Returns: The matching category, or `.other` if no segment lines
    ///   up with a known Library folder.
    nonisolated static func category(forPath path: String) -> RelatedItem.Category {
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
}
