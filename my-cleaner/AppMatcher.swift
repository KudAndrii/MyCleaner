//
//  AppMatcher.swift
//  my-cleaner
//

import Foundation

/// Decides whether a Library directory entry belongs to a specific
/// dropped app.
///
/// The matcher captures the per-app metadata once (bundle ID, team ID,
/// name hints) and answers `match(entry:category:)` for every directory
/// entry the scanner walks. Pulling this out of `AppScanner` makes the
/// rules unit-testable in isolation and lets the scanner stay focused
/// on the directory traversal.
///
/// ### Match rules, in priority order
///
/// 1. **Bundle ID — exact / prefix / group / iCloud.**
///    - `<bid>` or `<bid>.*` matches anywhere.
///    - `group.<bid>` or `group.<bid>.*` matches in any category.
///    - `iCloud~<tilde-encoded-bid>` matches only under `.iCloud`
///      (Mobile Documents stores `.` as `~` in folder names).
/// 2. **Name hints.** Display name, the last reverse-DNS component of
///    the bundle ID, and the bare `.app` filename — all lowercased and
///    matched on word boundaries, so `Rider` matches `Rider2024.3` but
///    not `RiderProjects`.
/// 3. **Team-ID prefix — Group Containers only.** Marks the entry as
///    `shared` (off by default) rather than including it unconditionally,
///    because team-prefixed group containers are usually shared between
///    every app the developer ships.
nonisolated struct AppMatcher: Sendable {

    /// The dropped app we're attributing files to.
    let app: DroppedApp

    /// Team identifier read from the app's code signature, or `nil` if
    /// the bundle is unsigned. Only consulted for `.groupContainers`.
    let teamID: String?

    /// Lowercased short tokens we plausibly know the app by — display
    /// name, last bundle-ID component, `.app` filename. Each is at least
    /// three characters long.
    let nameHints: [String]

    /// Outcome of a single match check.
    nonisolated struct MatchResult: Sendable, Equatable {

        /// `true` if `entry` belongs to the app.
        let matched: Bool

        /// `true` if the match was via a team-ID prefix in Group
        /// Containers, i.e. the entry is shared with other apps from the
        /// same developer and should default to off in the UI.
        let shared: Bool

        /// Convenience: an explicit "no match" outcome.
        static let none = MatchResult(matched: false, shared: false)
    }

    /// Build a matcher for `app`, reading its team ID once and
    /// pre-computing the name-hint list.
    ///
    /// - Parameter app: The dropped app to attribute files to.
    init(app: DroppedApp) {
        self.app = app
        self.teamID = CodeSignReader.readTeamID(forAppAt: app.url)
        self.nameHints = Self.computeNameHints(app: app)
    }

    /// Decide whether `entry` belongs to the captured app.
    ///
    /// - Parameters:
    ///   - entry: A directory entry from a Library subfolder.
    ///   - category: The Library category `entry` was found under (the
    ///     iCloud and Group Containers paths apply category-specific
    ///     rules).
    /// - Returns: A `MatchResult` describing the outcome.
    nonisolated func match(entry: URL, category: RelatedItem.Category) -> MatchResult {
        let full = entry.lastPathComponent.lowercased()
        let base = entry.deletingPathExtension().lastPathComponent.lowercased()

        if let raw = app.bundleID, !raw.isEmpty {
            let bid = raw.lowercased()
            if full == bid || base == bid { return MatchResult(matched: true, shared: false) }
            if full.hasPrefix(bid + ".") || base.hasPrefix(bid + ".") {
                return MatchResult(matched: true, shared: false)
            }
            if full == "group.\(bid)" || full.hasPrefix("group.\(bid).") {
                return MatchResult(matched: true, shared: false)
            }
            if category == .iCloud {
                let tildeBID = bid.replacingOccurrences(of: ".", with: "~")
                if full == "icloud~\(tildeBID)" { return MatchResult(matched: true, shared: false) }
                if full.hasPrefix("icloud~\(tildeBID)~") { return MatchResult(matched: true, shared: false) }
            }
        }

        for hint in nameHints {
            if base == hint || full == hint { return MatchResult(matched: true, shared: false) }
            if wordBoundaryPrefix(base, prefix: hint) { return MatchResult(matched: true, shared: false) }
            if wordBoundaryPrefix(full, prefix: hint) { return MatchResult(matched: true, shared: false) }
        }

        if category == .groupContainers, let raw = teamID, !raw.isEmpty {
            let tid = raw.lowercased()
            if full.hasPrefix(tid + ".") {
                return MatchResult(matched: true, shared: true)
            }
        }

        return .none
    }

    /// Collect every short token we plausibly know the app by — display
    /// name, the last reverse-DNS component of the bundle ID, and the
    /// `.app` filename — and deduplicate them.
    ///
    /// Each token is required to be at least three characters long so
    /// short fragments don't produce noisy matches. JetBrains stores
    /// Rider data under `~/Library/Caches/JetBrains/Rider2025.3/`, where
    /// the folder name only lines up with the `rider` token from the
    /// bundle ID — not "JetBrains Rider", and not "RD".
    ///
    /// - Parameter app: The dropped app whose hints to compute.
    /// - Returns: An array of unique lowercased hints, order-insensitive.
    private nonisolated static func computeNameHints(app: DroppedApp) -> [String] {
        var hints: Set<String> = []
        let display = app.name.lowercased()
        if display.count >= 3 { hints.insert(display) }

        if let bid = app.bundleID,
           let last = bid.split(separator: ".").last {
            let token = String(last).lowercased()
            if token.count >= 3 { hints.insert(token) }
        }

        let filename = app.url.deletingPathExtension().lastPathComponent.lowercased()
        if filename.count >= 3 { hints.insert(filename) }

        return Array(hints)
    }

    /// Returns `true` when `string` starts with `prefix` and the next
    /// character is a non-letter (digit, dot, space, dash, underscore).
    ///
    /// Lets us match `Rider` in `Rider2024.3` and `Microsoft Word` in
    /// `Microsoft Word Data` without matching `Microsoft` in
    /// `MicrosoftAutoUpdate` — the boundary is the transition out of the
    /// letter run.
    private nonisolated func wordBoundaryPrefix(_ string: String, prefix: String) -> Bool {
        guard prefix.count >= 3, string.count > prefix.count, string.hasPrefix(prefix) else { return false }
        let next = string[string.index(string.startIndex, offsetBy: prefix.count)]
        return !next.isLetter
    }
}
