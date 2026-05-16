//
//  LoginItems.swift
//  my-cleaner
//
//  Detects login items / background agents registered through the
//  modern SMAppService API. These don't drop a `.plist` into
//  `~/Library/LaunchAgents`; instead they're recorded in the system
//  background-task manager's opaque binary file
//  `~/Library/Application Support/com.apple.backgroundtaskmanagementagent/backgrounditems.btm`,
//  which is invisible to a directory walk.
//
//  Detection only — there's no public API for removing a btm entry
//  programmatically. Once the owning app is trashed, macOS prunes the
//  entry itself on the next launch of `backgroundtaskmanagementagent`.
//  The UI surfaces matches so the user understands where the
//  registration came from.
//

import Foundation

// MARK: - Model

/// One registered login item / background agent from `sfltool dumpbtm`.
nonisolated struct LoginItemInfo: Sendable, Identifiable, Hashable {
    /// Composite identity — uses both helper and parent IDs so two
    /// helpers with the same identifier under different parents
    /// don't collapse in the UI.
    var id: String { "\(parentBundleID ?? "").\(bundleID)" }

    /// Bundle identifier of the helper binary (often a child of the
    /// owning app's bundle ID, e.g. `com.example.app.helper`).
    let bundleID: String

    /// Bundle identifier of the **registering** app — set when
    /// `sfltool` reported a "parent identifier" for this entry.
    /// `nil` when the helper is the registering bundle itself.
    let parentBundleID: String?

    /// 10-character Apple team identifier, when present in output.
    let teamID: String?

    /// Human-readable name as it appears in System Settings → Login Items.
    let displayName: String

    /// Path the registered helper resolves to on disk, when `sfltool`
    /// included a URL. Empty string when the registration didn't
    /// carry a URL.
    let url: String

    /// `true` when the registration is currently enabled — derived
    /// from the `disposition:` flags. Disabled entries still occupy
    /// a row in btm and are worth surfacing.
    let isEnabled: Bool
}

// MARK: - Scanner

/// Thin wrapper around `/usr/bin/sfltool`.
enum LoginItems {

    // MARK: Entry point

    /// Every login item / background agent registered with btm.
    ///
    /// Returns `nil` when `sfltool` couldn't be invoked or exited
    /// non-zero — the most common cause being the user cancelling the
    /// admin prompt that `sfltool dumpbtm` requires. Callers should
    /// treat `nil` as "we don't know, leave the toggle off" rather
    /// than "no entries". Apple-namespace and per-app filtering are
    /// the caller's job; ``matches(_:bundleID:teamID:)`` is the
    /// canonical predicate.
    nonisolated static func allItems() -> [LoginItemInfo]? {
        guard let output = dumpOutput() else { return nil }
        return parseDumpOutput(output)
    }

    // MARK: Attribution

    /// `true` when the given login item belongs to the dropped app.
    ///
    /// Rejects `com.apple.*` outright. Checks the helper's own bundle
    /// ID against the app's bundle ID (exact or child), then the
    /// parent (registering) bundle ID, then falls back to team ID
    /// when both have one.
    nonisolated static func matches(
        _ item: LoginItemInfo,
        bundleID: String?,
        teamID: String?
    ) -> Bool {
        if isAppleNamespace(item.bundleID) { return false }
        if let parent = item.parentBundleID, isAppleNamespace(parent) { return false }

        if let bid = bundleID, !bid.isEmpty {
            let bidLower = bid.lowercased()
            let helperLower = item.bundleID.lowercased()
            if helperLower == bidLower { return true }
            if helperLower.hasPrefix(bidLower + ".") { return true }
            if let parent = item.parentBundleID?.lowercased() {
                if parent == bidLower { return true }
                if parent.hasPrefix(bidLower + ".") { return true }
                if bidLower.hasPrefix(parent + ".") { return true }
            }
        }
        if let tid = teamID, !tid.isEmpty, item.teamID == tid {
            return true
        }
        return false
    }

    /// `true` for `com.apple.*` — used to exclude OS-shipped items.
    nonisolated static func isAppleNamespace(_ bundleID: String) -> Bool {
        bundleID.lowercased().hasPrefix("com.apple.")
    }

    // MARK: Parser

    /// Parses `sfltool dumpbtm` output into structured entries.
    ///
    /// The dump is block-structured: an item is a run of `key: value`
    /// lines separated from the next item by a blank line. Keys vary
    /// in case between macOS releases (`Identifier:` on some, lowercase
    /// `identifier:` on others); the parser is case-insensitive on
    /// keys but preserves values verbatim.
    ///
    /// Anchor key is `identifier:` — a block without one is dropped.
    /// `parent identifier:`, `team identifier:`, `name:`, `url:`, and
    /// `disposition:` are picked up when present.
    nonisolated static func parseDumpOutput(_ output: String) -> [LoginItemInfo] {
        var results: [LoginItemInfo] = []
        // Items are separated by blank lines. The dump prepends a
        // header block (generation, totals, etc.) which we discard
        // by requiring an `identifier:` line per surviving block.
        let blocks = output.components(separatedBy: "\n\n")
        for block in blocks {
            if let info = parseBlock(block) {
                results.append(info)
            }
        }
        return results
    }

    private nonisolated static func parseBlock(_ block: String) -> LoginItemInfo? {
        var bundleID: String?
        var parentBundleID: String?
        var teamID: String?
        var displayName: String?
        var url: String = ""
        var disposition: String = ""

        for raw in block.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let v = matchKey(line, "parent identifier") {
                parentBundleID = stripQuotes(v)
            } else if let v = matchKey(line, "identifier") {
                bundleID = stripQuotes(v)
            } else if let v = matchKey(line, "team identifier") {
                let stripped = stripQuotes(v)
                teamID = (stripped == "(null)" || stripped.isEmpty) ? nil : stripped
            } else if let v = matchKey(line, "name") {
                displayName = stripQuotes(v)
            } else if let v = matchKey(line, "url") {
                url = stripQuotes(v)
            } else if let v = matchKey(line, "disposition") {
                disposition = v
            }
        }

        guard let bid = bundleID, !bid.isEmpty else { return nil }
        let enabled = !disposition.lowercased().contains("disabled")
        return LoginItemInfo(
            bundleID: bid,
            parentBundleID: parentBundleID,
            teamID: teamID,
            displayName: displayName ?? bid,
            url: url,
            isEnabled: enabled
        )
    }

    /// Returns the value after `<key>:`, case-insensitive on the key
    /// itself. `nil` when the line doesn't start with the given key.
    private nonisolated static func matchKey(_ line: String, _ key: String) -> String? {
        let prefix = key + ":"
        let lower = line.lowercased()
        guard lower.hasPrefix(prefix) else { return nil }
        let value = line.dropFirst(prefix.count)
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// Strips surrounding double quotes if present. `sfltool` quotes
    /// string-valued fields inconsistently across macOS releases.
    private nonisolated static func stripQuotes(_ s: String) -> String {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
        return String(s.dropFirst().dropLast())
    }

    // MARK: Shell-out

    /// Raw output of `sfltool dumpbtm`, or `nil` when the process
    /// couldn't be started or exited non-zero (most often: user
    /// cancelled the admin prompt that `sfltool` requires to read the
    /// btm database).
    nonisolated static func dumpOutput() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
        task.arguments = ["dumpbtm"]

        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()

        do { try task.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
