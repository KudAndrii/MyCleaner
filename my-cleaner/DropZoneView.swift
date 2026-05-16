//
//  DropZoneView.swift
//  my-cleaner
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Bindable var model: CleanerModel
    @Bindable var permissions: PermissionsChecker
    var onReviewPermissions: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if SandboxStatus.isSandboxed {
                sandboxWarning
            }
            if permissions.needsAttention {
                permissionsBanner
            }
            dropZone
            loginItemsRow
        }
        .padding(24)
        .onAppear {
            permissions.refresh()
        }
    }

    private var sandboxWarning: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("App Sandbox is enabled — scans will return nothing.")
                    .font(.callout.weight(.semibold))
                Text("In Xcode, open the target's Signing & Capabilities tab and remove the App Sandbox capability. The app is reading its own container right now, not your real Library folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }

    private var permissionsBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text(bannerText)
                .font(.callout)
            Spacer(minLength: 8)
            Button("Review…") { onReviewPermissions() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.10), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
        }
    }

    private var bannerText: String {
        let missing = PermissionKind.allCases.filter { permissions.status(for: $0) != .granted }
        let names = missing.map(\.title).joined(separator: " · ")
        return "Permissions needed: \(names)"
    }

    private var dropZone: some View {
        VStack(spacing: 28) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 64, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .scaleEffect(model.isHovering ? 1.12 : 1)
                .animation(.smooth(duration: 0.25), value: model.isHovering)

            VStack(spacing: 8) {
                Text("Drop an app to clean")
                    .font(.title.weight(.semibold))
                Text("Drag any app onto this window. We'll find every file that belongs to it before sending everything to the Trash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 10) {
                Button {
                    pickApp()
                } label: {
                    Label("Choose an app…", systemImage: "app.badge")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
                .controlSize(.large)

                Button {
                    Task { await model.startOrphanScan() }
                } label: {
                    Label("Find leftovers from removed apps", systemImage: "tray.2")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("Scan ~/Library for support files whose owning app is no longer installed.")
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [10, 8])
                )
                .foregroundStyle(model.isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.35)))
        }
        .glassEffect(
            model.isHovering ? .regular.tint(.accentColor.opacity(0.25)).interactive() : .regular.interactive(),
            in: .rect(cornerRadius: 32)
        )
        .scaleEffect(model.isHovering ? 1.015 : 1)
        .animation(.smooth(duration: 0.25), value: model.isHovering)
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { hovering in
            model.isHovering = hovering
        }
    }

    private var loginItemsRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.clock")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Background login items")
                    .font(.callout.weight(.medium))
                Text(loginItemsStateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: loginItemsBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(model.loginItemsEnabled
                      ? "Stop including registered login items in scan results."
                      : "Include registered login items in scan results. macOS will prompt for an admin password (once per app launch).")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    private var loginItemsStateText: String {
        if model.loginItemsEnabled {
            if let count = model.cachedAllLoginItems?.count {
                return "On — \(count) registered \(count == 1 ? "item" : "items") cached"
            }
            return "On"
        }
        return "Off — admin prompt required to enable"
    }

    /// Async toggle binding — mirrors the one in `ResultsView` so the
    /// dropzone and the results screen share a single source of truth
    /// for the opt-in scan. Fire-and-forget Task means the visual flips
    /// once the admin prompt resolves; cancellations leave the toggle
    /// off.
    private var loginItemsBinding: Binding<Bool> {
        Binding(
            get: { model.loginItemsEnabled },
            set: { newValue in
                Task { await model.setLoginItemsEnabled(newValue) }
            }
        )
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let appURL = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            model.errorMessage = "Please drop a .app bundle."
            return false
        }
        Task { await model.handleDrop(url: appURL) }
        return true
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Analyze"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.handleDrop(url: url) }
        }
    }
}
