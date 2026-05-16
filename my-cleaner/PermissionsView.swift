//
//  PermissionsView.swift
//  my-cleaner
//

import SwiftUI

struct PermissionsView: View {
    @Bindable var permissions: PermissionsChecker
    @Bindable var scannerHealth: ScannerHealthChecker
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(PermissionKind.allCases) { kind in
                        row(for: kind)
                    }
                }
                .padding(20)

                Divider()

                scannerSection
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 580)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "lock.open.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                Text("Grant permissions").font(.title2.weight(.semibold))
            }
            Text("My Cleaner needs two permissions to find and remove every file an app leaves behind. Click Grant to trigger macOS's prompt, or open System Settings if you've already denied a request.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    @ViewBuilder
    private func row(for kind: PermissionKind) -> some View {
        let status = permissions.status(for: kind)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: kind.symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(kind.title).font(.headline)
                    statusBadge(status)
                }
                Text(kind.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                if status != .granted {
                    Button {
                        permissions.refresh(kind)
                    } label: {
                        Text("Grant").frame(minWidth: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button {
                        Permissions.openSystemSettings(for: kind)
                    } label: {
                        Text("Open Settings").font(.caption)
                    }
                    .buttonStyle(.link)
                } else {
                    Label("Granted", systemImage: "checkmark.seal.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .font(.title2)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func statusBadge(_ status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .denied:
            Label("Required", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .unknown:
            Label("Not checked", systemImage: "questionmark.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Scanner availability section

    private var scannerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(.tint)
                Text("Scanner availability")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            Text("Three of My Cleaner's scanners shell out to macOS system tools. If a binary isn't where we expect it, those sections won't appear in scan results — this is where you'd see why.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(ScannerKind.allCases) { kind in
                    scannerRow(for: kind)
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func scannerRow(for kind: ScannerKind) -> some View {
        let status = scannerHealth.status(for: kind)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: kind.symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(kind.title).font(.headline)
                    scannerStatusBadge(status)
                }
                Text(kind.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                if status == .ok {
                    Label("Available", systemImage: "checkmark.seal.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .font(.title2)
                } else {
                    Button {
                        scannerHealth.refresh(kind)
                    } label: {
                        Text("Re-check").frame(minWidth: 72)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func scannerStatusBadge(_ status: ScannerHealth) -> some View {
        switch status {
        case .ok:
            Label("Available", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .unavailable:
            Label("Not available", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .failed:
            Label("Failed", systemImage: "xmark.octagon.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        case .unknown:
            Label("Not checked", systemImage: "questionmark.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Re-check all") {
                permissions.refresh()
                scannerHealth.refresh()
            }
            .buttonStyle(.bordered)
            Spacer()
            Button {
                isPresented = false
            } label: {
                Text(permissions.needsAttention ? "Continue anyway" : "Done")
                    .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
