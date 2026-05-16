//
//  BundleIdentifier.swift
//  my-cleaner
//
//  Pure-function helpers for parsing and validating bundle identifiers
//  off the strings macOS uses to name per-app folders, preference plists,
//  group containers, and iCloud containers. Centralised here so the
//  app-scan and orphan-scan code paths share one set of rules.
//

import Foundation

/// Namespace for bundle-identifier shape rules and naming-convention
/// decoding.
///
/// macOS stores per-app data under filesystem names derived from the
/// app's reverse-DNS bundle ID, but each Library subfolder applies its
/// own decoration (a `group.` prefix, a tilde-encoded iCloud variant, a
/// `.plist` extension, a ByHost UUID suffix, …). The helpers here strip
/// those decorations back to the raw bundle ID and validate the result
/// so we don't mistake stray fragments like `0.5` or `.cache` for an ID.
enum BundleIdentifier {

    /// Validate that a string is shaped like a reverse-DNS bundle
    /// identifier.
    ///
    /// Requirements:
    /// - At least one `.` separator.
    /// - No path separators or spaces.
    /// - No leading or trailing dot, no empty components.
    /// - First component is at least two characters long and starts with
    ///   a letter.
    ///
    /// - Parameter candidate: The string to validate.
    /// - Returns: `true` if `candidate` could plausibly be a bundle ID.
    nonisolated static func looksLikeBundleID(_ candidate: String) -> Bool {
        guard candidate.contains("."),
              !candidate.contains("/"),
              !candidate.contains(" "),
              !candidate.hasPrefix("."),
              !candidate.hasSuffix(".") else { return false }
        let parts = candidate.split(separator: ".")
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let head = parts[0]
        guard head.count >= 2, let first = head.first, first.isLetter else { return false }
        return true
    }

    /// `true` if the bundle ID is in Apple's reserved namespace and
    /// therefore must never be surfaced for deletion.
    ///
    /// Matches both `com.apple.*` and bare `apple.*` forms.
    nonisolated static func isAppleReserved(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        if lower.hasPrefix("com.apple.") { return true }
        if lower == "apple" || lower.hasPrefix("apple.") { return true }
        return false
    }

    /// The first two reverse-DNS segments of a bundle ID — the "vendor
    /// namespace" used to recognise sibling bundles from the same
    /// developer.
    ///
    /// Examples:
    /// - `com.docker.docker` → `com.docker`
    /// - `net.whatsapp.WhatsApp` → `net.whatsapp`
    ///
    /// - Parameter bundleID: The full bundle identifier.
    /// - Returns: The lowercased two-segment prefix, or `nil` for IDs
    ///   with fewer than two segments (too generic to use as a vendor key).
    nonisolated static func vendorNamespace(of bundleID: String) -> String? {
        let parts = bundleID.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }

    /// Extract the 10-character team identifier prefix from a
    /// team-prefixed group-container name (`UBF8T346G9.Office`).
    ///
    /// Apple team IDs are exactly 10 uppercase alphanumeric characters
    /// followed by `.` and a sub-bundle name. Anything else returns `nil`.
    ///
    /// - Parameter string: A directory name to inspect.
    /// - Returns: The 10-character team ID, or `nil` if `string` doesn't
    ///   begin with one.
    nonisolated static func teamIDPrefix(of string: String) -> String? {
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let head = String(string[..<dot])
        guard head.count == 10,
              head.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return head
    }

    /// Strip a trailing per-host UUID from a ByHost preference plist
    /// basename.
    ///
    /// ByHost plists are named `<bundleID>.<UUID>.plist` (the plist
    /// extension is stripped by the caller). The UUID is exactly 36
    /// characters and contains four `-` separators, so we strip it
    /// conservatively only when those constraints both match.
    ///
    /// - Parameter base: The plist basename (already stripped of
    ///   `.plist`).
    /// - Returns: `base` with the UUID suffix removed if it was present,
    ///   otherwise `base` unchanged.
    nonisolated static func stripByHostUUID(_ base: String) -> String {
        let parts = base.split(separator: ".")
        guard let last = parts.last,
              last.count == 36,
              last.filter({ $0 == "-" }).count == 4 else { return base }
        return parts.dropLast().joined(separator: ".")
    }

    /// Extract the bundle identifier a directory or file entry was named
    /// after, undoing the category-specific naming convention.
    ///
    /// Each Library subfolder decorates the bundle ID differently — this
    /// helper centralises the unwrapping so callers don't have to know
    /// the conventions:
    /// - `.iCloud`: requires an `iCloud~` prefix and tilde-encoded dots.
    /// - `.preferences`: requires `.plist` extension; ByHost UUID is stripped.
    /// - `.groupContainers`: strips `group.` or `vgroup.` (case-insensitive),
    ///   or keeps a team-prefix name (`UBF8T346G9.Office`) verbatim.
    /// - everything else: strips known suffixes (`.savedState`,
    ///   `.binarycookies`).
    ///
    /// - Parameters:
    ///   - url: The directory or file entry under inspection.
    ///   - category: Which Library category the entry was discovered in.
    /// - Returns: The decoded bundle ID, or `nil` if the entry's name
    ///   doesn't decode to anything that looks like a valid bundle ID.
    nonisolated static func candidate(
        for url: URL,
        category: RelatedItem.Category
    ) -> String? {
        let name = url.lastPathComponent

        if category == .iCloud {
            guard name.hasPrefix("iCloud~") else { return nil }
            let tail = String(name.dropFirst("iCloud~".count))
            let decoded = tail.replacingOccurrences(of: "~", with: ".")
            return looksLikeBundleID(decoded) ? decoded : nil
        }

        if category == .preferences {
            guard name.hasSuffix(".plist") else { return nil }
            let base = (name as NSString).deletingPathExtension
            let stripped = stripByHostUUID(base)
            return looksLikeBundleID(stripped) ? stripped : nil
        }

        if category == .groupContainers {
            let lowered = name.lowercased()
            for prefix in ["group.", "vgroup."] where lowered.hasPrefix(prefix) {
                let bid = String(name.dropFirst(prefix.count))
                return looksLikeBundleID(bid) ? bid : nil
            }
            // Team-prefix group container (`UBF8T346G9.Office`) — keep
            // the full string as the bundle-ID key so attribution still
            // works downstream.
            return looksLikeBundleID(name) ? name : nil
        }

        let stripped = stripKnownSuffix(name)
        return looksLikeBundleID(stripped) ? stripped : nil
    }

    /// Strip a known per-category file suffix from a directory entry name.
    ///
    /// Currently handles `Saved Application State` (`.savedState`) and
    /// `Cookies` (`.binarycookies`). Returns `name` unchanged if no
    /// known suffix is present.
    private nonisolated static func stripKnownSuffix(_ name: String) -> String {
        let suffixes = [".savedState", ".binarycookies"]
        for suffix in suffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}
