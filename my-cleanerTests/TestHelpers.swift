//
//  TestHelpers.swift
//  my-cleanerTests
//

import Foundation
@testable import my_cleaner

/// Builds a minimal on-disk `.app` bundle (Contents/Info.plist plus
/// a placeholder executable) so we can exercise `DroppedApp(url:)`
/// without bundling real apps into the test target.
enum AppBundleBuilder {

    @discardableResult
    static func makeApp(
        in directory: URL,
        name: String,
        bundleID: String?,
        displayName: String? = nil,
        executable: String? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let appURL = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        var info: [String: Any] = [:]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        if let displayName { info["CFBundleDisplayName"] = displayName }
        info["CFBundleName"] = name
        info["CFBundleExecutable"] = executable ?? name
        info["CFBundlePackageType"] = "APPL"

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        // Placeholder binary so the bundle isn't empty.
        let exeURL = macOS.appendingPathComponent(executable ?? name)
        try Data().write(to: exeURL)

        return appURL
    }
}

/// Manages a temporary scratch directory for filesystem-touching tests.
/// Each instance gets a unique subdirectory under `NSTemporaryDirectory()`
/// and removes it when the instance is deallocated.
nonisolated final class TempDir {
    let url: URL

    init(label: String = "mycleaner-test") throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base
    }

    func makeFile(at relativePath: String, contents: Data = Data("test".utf8)) throws -> URL {
        let target = url.appendingPathComponent(relativePath)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try contents.write(to: target)
        return target
    }

    func makeDir(at relativePath: String) throws -> URL {
        let target = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
