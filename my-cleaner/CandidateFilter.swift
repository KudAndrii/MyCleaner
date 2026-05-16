//
//  CandidateFilter.swift
//  my-cleaner
//

import Foundation

/// One bundle-identifier candidate the orphan scanner is considering for
/// inclusion in its results.
///
/// Holds every piece of information a filter might need without forcing
/// each filter implementation to re-derive it:
/// - the original (case-preserved) bundle ID as extracted from disk,
/// - a lowercased form for case-insensitive comparisons,
/// - the Library category the entry was discovered in,
/// - a reference to the installed-apps index, so filters can answer "is
///   this still installed?" without rebuilding state.
nonisolated struct OrphanCandidate: Sendable {

    /// The bundle ID exactly as parsed from the directory entry. Used
    /// when case matters (team-prefix detection, Launch Services
    /// lookups).
    let bundleID: String

    /// Lowercased form of `bundleID`. Used for set membership tests
    /// against `InstalledAppsIndex.bundleIDs`, which is also lowercased.
    let normalizedID: String

    /// Library category the entry was discovered under. A handful of
    /// filters apply only to specific categories (the team-prefix rule
    /// is restricted to Group Containers and Application Scripts).
    let category: RelatedItem.Category

    /// Snapshot of every `.app` MyCleaner detected as installed, plus
    /// the vendor-namespace and team-ID indices derived from it.
    let installed: InstalledAppsIndex

    /// Build a candidate from a freshly extracted bundle ID.
    ///
    /// - Parameters:
    ///   - bundleID: The bundle ID parsed by `BundleIdentifier.candidate(for:category:)`.
    ///   - category: The category whose folder it was found under.
    ///   - installed: The pre-built installed-apps snapshot.
    init(bundleID: String, category: RelatedItem.Category, installed: InstalledAppsIndex) {
        self.bundleID = bundleID
        self.normalizedID = bundleID.lowercased()
        self.category = category
        self.installed = installed
    }
}

/// A single rule that vetoes a candidate from the orphan results.
///
/// Filters compose into a chain inside `OrphanScanner`. Each candidate
/// is run through every filter in order; the first filter to return
/// `true` from `excludes(_:)` rejects the candidate, and the rest of the
/// chain is skipped for that candidate.
///
/// This is the Swift translation of the "abstract filter with multiple
/// implementations" pattern — each rule lives in its own struct and can
/// be reasoned about, unit-tested, or reordered in isolation.
///
/// ### Adding a new rule
/// 1. Create a `struct YourFilter: CandidateFilter, Sendable`.
/// 2. Implement `excludes(_:)` returning `true` when the candidate
///    should be silently dropped.
/// 3. Add an instance to the chain in
///    `OrphanScanner.exclusionChain(installed:)`, in priority order
///    (cheapest filter first so the expensive ones — Launch Services in
///    particular — only run on candidates the cheap rules can't decide).
nonisolated protocol CandidateFilter: Sendable {

    /// Short human-readable label. Useful for diagnostics and tests; not
    /// surfaced to end users.
    var name: String { get }

    /// Decide whether `candidate` should be **excluded** from the orphan
    /// results.
    ///
    /// - Parameter candidate: The candidate under consideration. Filters
    ///   may use any field on it.
    /// - Returns: `true` to drop the candidate (don't surface it as an
    ///   orphan); `false` to let it through to subsequent filters.
    func excludes(_ candidate: OrphanCandidate) -> Bool
}
