//
//  AdminTrash.swift
//  my-cleaner
//

import Foundation
import AppKit

enum AdminTrash {

    struct Outcome: Sendable {
        let succeeded: [URL]
        let refused: [URL]
        let errorMessage: String?
    }

    // Single AppleScript invocation that prompts for the admin password once and
    // moves everything in `urls` to the user's ~/.Trash. Used as a fallback when
    // FileManager.trashItem refuses because the item is owned by root:wheel.
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

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Wrap a shell command in an AppleScript double-quoted literal, escaping the
    // characters AppleScript treats specially inside "..." strings.
    private static func appleScriptString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
