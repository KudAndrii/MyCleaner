//
//  AppEntryMatcher.swift
//  my-cleaner
//
//  The "find what belongs to this app" half of the app-cleanup flow.
//
//  ``AppScanner`` walks Library directories to enumerate candidate
//  entries; each candidate is then passed through an ordered chain of
//  matchers. The first matcher that recognises the entry wins, and the
//  entry is attributed to the dropped app. Splitting attribution into
//  small typed strategies keeps the matching rules close to their
//  rationale and makes each one independently reviewable.
//

import Foundation

// MARK: - Match result

/// The "yes, this belongs to the app" half of a matcher's response.
///
/// Matchers that don't recognise the entry return `nil`. Matchers that
/// do return an ``AppEntryMatch`` whose `shared` flag marks items the
/// UI should leave unselected by default (e.g. vendor-wide group
/// containers, iCloud Documents that sync between devices).
nonisolated struct AppEntryMatch: Sendable, Equatable {
    /// Whether the match should be surfaced **unselected** by default.
    let shared: Bool
}

// MARK: - Match context

/// Read-only payload threaded through the matcher chain for a single entry.
///
/// The lowercased filename and basename are computed once at the call
/// site so each matcher only does the work that's specific to its
/// own rule.
nonisolated struct AppEntryMatchContext: Sendable {
    /// The dropped app whose related entries we're attributing.
    let app: DroppedApp

    /// Code-signing team identifier, when readable.
    let teamID: String?

    /// Short attribution tokens — display name, last bundle-ID segment, filename.
    let nameHints: [String]

    /// Which Library bucket this entry was enumerated under.
    let category: RelatedItem.Category

    /// `entry.lastPathComponent.lowercased()`.
    let fullNameLower: String

    /// `entry.deletingPathExtension().lastPathComponent.lowercased()`.
    let baseNameLower: String

    init(
        app: DroppedApp,
        teamID: String?,
        nameHints: [String],
        category: RelatedItem.Category,
        entry: URL
    ) {
        self.app = app
        self.teamID = teamID
        self.nameHints = nameHints
        self.category = category
        self.fullNameLower = entry.lastPathComponent.lowercased()
        self.baseNameLower = entry.deletingPathExtension().lastPathComponent.lowercased()
    }
}

// MARK: - Matcher protocol

/// One attribution strategy — "does this entry belong to the dropped app?"
///
/// Implementations should be cheap, pure functions of their inputs.
/// The scanner runs the matchers in declaration order (see
/// ``AppScanner/matchers``) and uses the first non-`nil` response.
protocol AppEntryMatcher: Sendable {
    /// - Parameters:
    ///   - entry: A direct child of one of the Library directories the scanner walks.
    ///   - context: Pre-computed attribution hints for this entry.
    /// - Returns: `nil` when this matcher doesn't recognise the entry, otherwise
    ///   an ``AppEntryMatch`` describing how to surface it.
    func match(entry: URL, in context: AppEntryMatchContext) -> AppEntryMatch?
}

// MARK: - Concrete matchers

/// Matches entries named after the dropped app's bundle ID — exact match,
/// dotted prefix (`com.foo.bar.Helper`), or the conventional `group.<bid>` form.
///
/// All comparisons are case-insensitive.
nonisolated struct BundleIDMatcher: AppEntryMatcher {
    func match(entry: URL, in context: AppEntryMatchContext) -> AppEntryMatch? {
        guard let raw = context.app.bundleID, !raw.isEmpty else { return nil }
        let bid = raw.lowercased()
        let full = context.fullNameLower
        let base = context.baseNameLower

        if full == bid || base == bid { return AppEntryMatch(shared: false) }
        if full.hasPrefix(bid + ".") || base.hasPrefix(bid + ".") { return AppEntryMatch(shared: false) }
        if full == "group.\(bid)" || full.hasPrefix("group.\(bid).") { return AppEntryMatch(shared: false) }
        return nil
    }
}

/// Matches iCloud containers, which encode the bundle ID with tildes
/// instead of dots (`iCloud~com~apple~Pages` ↔ `com.apple.Pages`).
///
/// Only fires inside the `.iCloud` category so we don't accidentally
/// pick the form up elsewhere.
nonisolated struct ICloudBundleMatcher: AppEntryMatcher {
    func match(entry: URL, in context: AppEntryMatchContext) -> AppEntryMatch? {
        guard context.category == .iCloud else { return nil }
        guard let raw = context.app.bundleID, !raw.isEmpty else { return nil }
        let tildeBID = raw.lowercased().replacingOccurrences(of: ".", with: "~")
        let full = context.fullNameLower

        if full == "icloud~\(tildeBID)" { return AppEntryMatch(shared: false) }
        if full.hasPrefix("icloud~\(tildeBID)~") { return AppEntryMatch(shared: false) }
        return nil
    }
}

/// Matches entries whose name starts with one of the app's short
/// "name hints" at a word boundary, accepting digits / punctuation
/// but rejecting another letter immediately after.
///
/// Catches folders like `Rider2024.3`, `Microsoft Word Data`, etc.
nonisolated struct NameHintMatcher: AppEntryMatcher {
    func match(entry: URL, in context: AppEntryMatchContext) -> AppEntryMatch? {
        let full = context.fullNameLower
        let base = context.baseNameLower

        for hint in context.nameHints {
            if base == hint || full == hint { return AppEntryMatch(shared: false) }
            if AppScanner.wordBoundaryPrefix(base, prefix: hint) { return AppEntryMatch(shared: false) }
            if AppScanner.wordBoundaryPrefix(full, prefix: hint) { return AppEntryMatch(shared: false) }
        }
        return nil
    }
}

/// Matches team-ID-prefixed Group Containers (e.g. `UBF8T346G9.Office`).
///
/// The same group container is used by every app the developer ships,
/// so the result is always flagged `shared` — the user has to opt in
/// before it gets trashed.
nonisolated struct TeamPrefixGroupContainerMatcher: AppEntryMatcher {
    func match(entry: URL, in context: AppEntryMatchContext) -> AppEntryMatch? {
        guard context.category == .groupContainers,
              let raw = context.teamID,
              !raw.isEmpty else { return nil }
        let tid = raw.lowercased()
        return context.fullNameLower.hasPrefix(tid + ".") ? AppEntryMatch(shared: true) : nil
    }
}
