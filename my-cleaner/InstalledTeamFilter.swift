//
//  InstalledTeamFilter.swift
//  my-cleaner
//

import Foundation

/// Rejects team-prefixed Group Container / Application Scripts entries
/// when any app from that team is still installed.
///
/// Team-prefixed group containers (`UBF8T346G9.Office`) and matching
/// `Application Scripts` directories belong to a developer, not a
/// single app. Microsoft Office's `UBF8T346G9.Office` is shared by
/// Word, Excel, PowerPoint, OneNote and Outlook — uninstalling Excel
/// alone must not flag this container as orphaned.
///
/// The rule applies only to those two categories. For every other
/// category the team ID isn't part of the on-disk naming convention, so
/// the candidate would have no team-ID prefix to extract.
nonisolated struct InstalledTeamFilter: CandidateFilter, Sendable {

    let name = "InstalledTeam"

    /// - Returns: `true` when the candidate is a team-prefixed entry in
    ///   Group Containers or Application Scripts and the team identifier
    ///   is still represented by an installed app.
    nonisolated func excludes(_ candidate: OrphanCandidate) -> Bool {
        guard candidate.category == .groupContainers || candidate.category == .scripts else {
            return false
        }
        guard let teamID = BundleIdentifier.teamIDPrefix(of: candidate.bundleID) else {
            return false
        }
        return candidate.installed.teamIDs.contains(teamID)
    }
}
