//
//  AdminTrash.swift
//  my-cleaner
//

import Foundation
import AppKit

/// Elevated-privilege fallback for moving files to the Trash.
///
/// `FileManager.trashItem` refuses root-owned items, which means
/// LaunchDaemon plists and helper binaries installed by a `.pkg` can't
/// be trashed from the user session. `AdminTrash` performs a single
/// AppleScript invocation with `do shell script … with administrator
/// privileges` — the user is prompted for their password once, and every
/// item in the batch is `mv`'d to `~/.Trash` from that elevated context.
enum AdminTrash {

    /// The outcome of a single elevation pass.
    ///
    /// `succeeded` and `refused` partition the input URLs by whether the
    /// item is still present on disk after the script ran. If the
    /// AppleScript itself errored (user cancelled, scripting bridge
    /// failed), every URL is in `refused` and `errorMessage` carries a
    /// human-readable explanation.
    struct Outcome: Sendable {

        /// URLs that are no longer present on disk after the elevation
        /// pass — i.e. the move succeeded.
        let succeeded: [URL]

        /// URLs still present on disk after the elevation pass.
        let refused: [URL]

        /// Localised error string from the AppleScript bridge, or `nil`
        /// if the script ran cleanly (even if individual items refused).
        let errorMessage: String?
    }

    /// Move every URL in `urls` to the user's Trash through a single
    /// password-prompted AppleScript invocation.
    ///
    /// Empty input short-circuits to a no-op outcome — no prompt, no
    /// AppleScript work.
    ///
    /// - Parameter urls: Items to move under elevation. Order is
    ///   preserved when building the shell pipeline.
    /// - Returns: An `Outcome` partitioning the URLs by post-script disk
    ///   presence, plus any bridge-level error string.
    static func move(urls: [URL]) async -> Outcome {
        guard !urls.isEmpty else {
            return Outcome(succeeded: [], refused: [], errorMessage: nil)
        }

        let trashDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true).path

        let shellCommands = urls.map { url -> String in
            let dest = uniqueTrashDestination(for: url, trashDir: trashDir)
            return "/bin/mv -f \(shellQuote(url.path)) \(shellQuote(dest))"
        }
        let shell = shellCommands.joined(separator: " ; ")
        let appleScriptLiteral = appleScriptString(shell)
        let source = "do shell script \(appleScriptLiteral) with administrator privileges"

        let scriptError: String? = await MainActor.run { () -> String? in
            guard let script = NSAppleScript(source: source) else {
                return "Could not build the elevation script."
            }
            var errorInfo: NSDictionary?
            _ = script.executeAndReturnError(&errorInfo)
            if let info = errorInfo {
                if let n = info[NSAppleScript.errorNumber] as? Int, n == -128 {
                    return "Authorization was cancelled."
                }
                return (info[NSAppleScript.errorMessage] as? String) ?? "Authorization failed."
            }
            return nil
        }

        let fm = FileManager.default
        var succeeded: [URL] = []
        var refused: [URL] = []
        for url in urls {
            if !fm.fileExists(atPath: url.path) {
                succeeded.append(url)
            } else {
                refused.append(url)
            }
        }

        return Outcome(succeeded: succeeded, refused: refused, errorMessage: scriptError)
    }

    /// Pick a Trash destination path that doesn't collide with an
    /// existing file.
    ///
    /// Matches Finder's "name 2.ext", "name 3.ext", … convention up to
    /// 99 attempts, then falls back to a UUID suffix to guarantee a
    /// unique target.
    private static func uniqueTrashDestination(for url: URL, trashDir: String) -> String {
        let fm = FileManager.default
        let name = url.lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let firstChoice = (trashDir as NSString).appendingPathComponent(name)
        if !fm.fileExists(atPath: firstChoice) { return firstChoice }
        for i in 2...99 {
            let candidateName = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = (trashDir as NSString).appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate) { return candidate }
        }
        return (trashDir as NSString).appendingPathComponent("\(base)-\(UUID().uuidString)\(ext.isEmpty ? "" : "." + ext)")
    }

    /// Wrap a string in single quotes for safe interpolation into a
    /// shell command, escaping any embedded single quotes.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Wrap a shell command in an AppleScript double-quoted literal,
    /// escaping the characters AppleScript treats specially inside `"…"`
    /// strings.
    private static func appleScriptString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
