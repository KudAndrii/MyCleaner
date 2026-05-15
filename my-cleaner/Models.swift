//
//  Models.swift
//  my-cleaner
//

import Foundation

nonisolated struct DroppedApp: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let bundleID: String?

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

nonisolated struct ScanResult: Sendable {
    let appSize: Int64
    let items: [RelatedItem]
}

enum SandboxStatus {
    static var isSandboxed: Bool {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home.contains("/Library/Containers/")
    }
}

nonisolated struct RelatedItem: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let category: Category
    let sizeBytes: Int64
    let isDirectory: Bool
    let isShared: Bool
    var isSelected: Bool

    init(url: URL, category: Category, sizeBytes: Int64, isDirectory: Bool, isShared: Bool = false) {
        self.url = url
        self.category = category
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.isShared = isShared
        self.isSelected = !isShared
    }

    enum Category: String, CaseIterable, Hashable, Sendable {
        case applicationSupport = "Application Support"
        case caches = "Caches"
        case preferences = "Preferences"
        case containers = "Containers"
        case groupContainers = "Group Containers"
        case logs = "Logs"
        case savedState = "Saved Application State"
        case cookies = "Cookies & Web Data"
        case launchItems = "Launch Items"
        case scripts = "Application Scripts"
        case other = "Other"

        var symbol: String {
            switch self {
            case .applicationSupport: "shippingbox.fill"
            case .caches: "externaldrive.fill"
            case .preferences: "gearshape.fill"
            case .containers: "cube.fill"
            case .groupContainers: "square.stack.3d.up.fill"
            case .logs: "doc.text.fill"
            case .savedState: "clock.arrow.circlepath"
            case .cookies: "globe"
            case .launchItems: "play.circle.fill"
            case .scripts: "scroll.fill"
            case .other: "folder.fill"
            }
        }
    }
}
