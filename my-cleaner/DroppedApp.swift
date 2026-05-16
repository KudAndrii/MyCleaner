//
//  DroppedApp.swift
//  my-cleaner
//

import Foundation

/// An `.app` bundle the user has dropped onto the window (or chosen via
/// the file picker), parsed into the metadata MyCleaner needs to attribute
/// support files to it.
///
/// Construction is failable: passing a URL that isn't an `.app` bundle
/// returns `nil` so the caller can surface an "unsupported drop" message
/// without having to inspect the URL itself.
nonisolated struct DroppedApp: Identifiable, Hashable, Sendable {

    /// `Identifiable` conformance — the bundle URL is the natural identity.
    var id: URL { url }

    /// On-disk location of the `.app` bundle.
    let url: URL

    /// Human-readable name. Falls back through `CFBundleDisplayName`,
    /// `CFBundleName`, then the filename without the `.app` extension.
    let name: String

    /// The reverse-DNS bundle identifier read from `Info.plist`, or `nil`
    /// if the bundle is unreadable or doesn't declare one.
    let bundleID: String?

    /// Parse an `.app` bundle into a `DroppedApp`.
    ///
    /// - Parameter url: A file URL pointing to a folder with a `.app`
    ///   extension. Any other URL returns `nil`.
    /// - Returns: A populated `DroppedApp`, or `nil` if `url` isn't an
    ///   `.app` bundle.
    init?(url: URL) {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        self.url = url
        let bundle = Bundle(url: url)
        self.bundleID = bundle?.bundleIdentifier
        let info = bundle?.infoDictionary
        let display = info?["CFBundleDisplayName"] as? String
        let name = info?["CFBundleName"] as? String
        self.name = display ?? name ?? url.deletingPathExtension().lastPathComponent
    }
}
