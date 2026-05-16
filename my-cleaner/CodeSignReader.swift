//
//  CodeSignReader.swift
//  my-cleaner
//

import Foundation
import Security

/// Read code-signing metadata off an `.app` bundle.
///
/// MyCleaner needs the team identifier from an app's signature to
/// recognise team-prefixed Group Containers (`UBF8T346G9.Office`) as
/// shared between every app from the same developer.
enum CodeSignReader {

    /// Read the 10-character team identifier from the app at `url`.
    ///
    /// Uses `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation`
    /// with the `kSecCSSigningInformation` flag — the team ID lives in
    /// the cryptographic-signing section of the info dictionary and is
    /// only populated when that flag is set. Default flags would return
    /// the basic identifier set and silently omit the team ID.
    ///
    /// - Parameter url: A file URL pointing at an `.app` bundle.
    /// - Returns: The team identifier, or `nil` if the bundle is
    ///   unsigned, ad-hoc-signed, or unreadable.
    nonisolated static func readTeamID(forAppAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else { return nil }

        var infoRef: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoRef
        )
        guard infoStatus == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }

        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
