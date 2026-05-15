//
//  Permissions.swift
//  my-cleaner
//

import Foundation
import Observation
import AppKit

enum PermissionStatus: Equatable {
    case unknown
    case granted
    case denied
}

enum Permissions {

    // Touching a known FDA-protected path. The first access fires the TCC prompt;
    // subsequent calls just observe whether the user granted or denied.
    static func probeFullDiskAccess() -> PermissionStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            home.appendingPathComponent("Library/Mail", isDirectory: true),
            home.appendingPathComponent("Library/Safari", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/com.apple.TCC", isDirectory: true),
            home.appendingPathComponent("Library/Cookies", isDirectory: true),
        ]
        let fm = FileManager.default
        var sawPath = false
        for url in candidates {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            sawPath = true
            do {
                _ = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
                return .granted
            } catch {
                if isPermissionError(error) { return .denied }
            }
        }
        // No protected dir exists at all on this machine — treat as granted to avoid a false warning.
        return sawPath ? .denied : .granted
    }

    // App Management governs writes into /Applications. Creating and deleting a hidden
    // probe file is the lightest-weight way to trigger the TCC prompt without touching
    // any real app bundle.
    static func probeAppManagement() -> PermissionStatus {
        let probe = URL(fileURLWithPath: "/Applications/.mycleaner-probe-\(UUID().uuidString)")
        let fm = FileManager.default
        do {
            try Data().write(to: probe, options: .atomic)
            try? fm.removeItem(at: probe)
            return .granted
        } catch {
            try? fm.removeItem(at: probe)
            if isPermissionError(error) { return .denied }
            return .denied
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) {
            return true
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return true
            default:
                break
            }
        }
        return false
    }

    static func openSystemSettings(for permission: PermissionKind) {
        let pane: String
        switch permission {
        case .fullDiskAccess: pane = "Privacy_AllFiles"
        case .appManagement: pane = "Privacy_AppBundles"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

enum PermissionKind: String, Identifiable, CaseIterable, Sendable {
    case fullDiskAccess
    case appManagement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullDiskAccess: "Full Disk Access"
        case .appManagement: "App Management"
        }
    }

    var symbol: String {
        switch self {
        case .fullDiskAccess: "lock.shield"
        case .appManagement: "app.badge.checkmark"
        }
    }

    var explanation: String {
        switch self {
        case .fullDiskAccess:
            return "Lets My Cleaner enumerate your ~/Library so it can find leftover caches, preferences and containers belonging to the dropped app."
        case .appManagement:
            return "Lets My Cleaner move third-party apps out of /Applications. Without it, apps installed by an installer package can't be removed."
        }
    }
}

@Observable
@MainActor
final class PermissionsChecker {
    var fullDiskAccess: PermissionStatus = .unknown
    var appManagement: PermissionStatus = .unknown

    var needsAttention: Bool {
        fullDiskAccess != .granted || appManagement != .granted
    }

    func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .fullDiskAccess: fullDiskAccess
        case .appManagement: appManagement
        }
    }

    func refresh() {
        fullDiskAccess = Permissions.probeFullDiskAccess()
        appManagement = Permissions.probeAppManagement()
    }

    func refresh(_ kind: PermissionKind) {
        switch kind {
        case .fullDiskAccess: fullDiskAccess = Permissions.probeFullDiskAccess()
        case .appManagement: appManagement = Permissions.probeAppManagement()
        }
    }
}
