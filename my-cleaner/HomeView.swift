//
//  HomeView.swift
//  my-cleaner
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HomeView: View {
    @Bindable var model: CleanerModel
    @Bindable var permissions: PermissionsChecker
    var onReviewPermissions: () -> Void

    @State private var showLargeFileScope = false
    @State private var showDuplicateOptions = false
    @State private var duplicateScope: Set<DuplicateScopeFolder> = Set(DuplicateScopeFolder.allCases)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if SandboxStatus.isSandboxed {
                    sandboxWarning
                }
                if permissions.needsAttention {
                    permissionsBanner
                }
                dropZoneCard
                toolsSection
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) { footerBar }
        .onAppear {
            permissions.refresh()
            model.refreshHomeStats()
        }
        .sheet(isPresented: $showLargeFileScope) {
            LargeFileScopeView(model: model, isPresented: $showLargeFileScope)
        }
        .sheet(isPresented: $showDuplicateOptions) {
            DuplicateScopeView(
                selection: $duplicateScope,
                isPresented: $showDuplicateOptions
            ) { urls, minimumBytes in
                showDuplicateOptions = false
                Task { await model.startDuplicateScan(scope: urls, minimumBytes: minimumBytes) }
            }
        }
    }

    // MARK: - Drop zone

    private var dropZoneCard: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 56, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .scaleEffect(model.isHovering ? 1.12 : 1)
                .animation(.smooth(duration: 0.25), value: model.isHovering)

            VStack(spacing: 6) {
                Text("Drop an app to clean")
                    .font(.title2.weight(.semibold))
                Text("Drag any app onto this window. We'll find every file that belongs to it before sending everything to the Trash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            Button {
                pickApp()
            } label: {
                Label("Choose an app…", systemImage: "app.badge")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .foregroundStyle(model.isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.35)))
        }
        .glassEffect(
            model.isHovering ? .regular.tint(.accentColor.opacity(0.25)).interactive() : .regular.interactive(),
            in: .rect(cornerRadius: 24)
        )
        .scaleEffect(model.isHovering ? 1.01 : 1)
        .animation(.smooth(duration: 0.25), value: model.isHovering)
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { hovering in
            model.isHovering = hovering
        }
    }

    // MARK: - Tools grid

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CLEANUP TOOLS")
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            // Prefer a single 4-up row; fall back to a balanced 2x2 grid
            // once each tile would compress below ~200pt — keeps every
            // tile the same width instead of stranding one orphan on a
            // second row.
            ViewThatFits(in: .horizontal) {
                toolsGrid(columns: 4)
                toolsGrid(columns: 2)
            }
        }
    }

    private func toolsGrid(columns: Int) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(minimum: 200), spacing: 12),
                count: columns
            ),
            spacing: 12
        ) {
            toolTiles
        }
    }

    @ViewBuilder
    private var toolTiles: some View {
        ToolTile(
            title: "App leftovers",
            description: "Support files whose owning app is already gone.",
            systemImage: "tray.2",
            tint: .indigo,
            footer: footer(
                stat: model.scanCache.orphanStat,
                singular: "bundle",
                plural: "bundles",
                callToAction: "Hunt for leftovers"
            )
        ) {
            Task { await model.startOrphanScan() }
        }
        ToolTile(
            title: "Large files",
            description: "Surface the biggest files across your home folder.",
            systemImage: "scalemass",
            tint: .orange,
            footer: footer(
                stat: model.scanCache.largeFileStat,
                singular: "file",
                plural: "files",
                callToAction: "Spot the giants"
            )
        ) {
            showLargeFileScope = true
        }
        ToolTile(
            title: "Oversized caches",
            description: "Dev tool caches, simulators and build artifacts.",
            systemImage: "externaldrive.badge.minus",
            tint: .teal,
            footer: footer(
                stat: model.scanCache.oversizedCacheStat,
                singular: "place",
                plural: "places",
                callToAction: "Reclaim cache space"
            )
        ) {
            model.startCacheScan()
        }
        ToolTile(
            title: "Duplicate files",
            description: "Byte-identical copies hiding across your disk.",
            systemImage: "doc.on.doc",
            tint: .purple,
            footer: footer(
                stat: model.scanCache.duplicateStat,
                singular: "dupe",
                plural: "dupes",
                callToAction: "Find duplicates"
            )
        ) {
            showDuplicateOptions = true
        }
    }

    /// Builds the inline footer for a tool tile.
    ///
    /// Pre-scan: a tile-specific invitation, drawn in the accent
    /// colour so it reads as the active call-to-action. Post-scan:
    /// the headline stat in muted text — the user already knows the
    /// tool works.
    private func footer(
        stat: HomeStat?,
        singular: String,
        plural: String,
        callToAction: String
    ) -> ToolTileFooter {
        guard let stat else { return .callToAction(callToAction) }
        let unit = stat.count == 1 ? singular : plural
        let bytes = ByteCountFormatter.string(
            fromByteCount: stat.totalBytes,
            countStyle: .file
        )
        return .stat("\(bytes) · \(stat.count) \(unit)")
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.clock")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Background login items")
                    .font(.caption.weight(.medium))
                Text(loginItemsStateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Toggle("", isOn: loginItemsBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(model.loginItemsEnabled
                      ? "Stop including registered login items in scan results."
                      : "Include registered login items in scan results. macOS will prompt for an admin password (once per app launch).")
            Spacer(minLength: 8)
            Button {
                onReviewPermissions()
            } label: {
                Label("System checks…", systemImage: "stethoscope")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Inspect permissions and scanner availability.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
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
    /// home and the results screen share a single source of truth
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

    // MARK: - Banners

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

    // MARK: - Drop / picker

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

// MARK: - Tool tile

/// Footer text for ``ToolTile``. Splits the pre-scan call-to-action
/// from the post-scan numeric stat so the tile can render the former
/// in the accent colour (active invitation) and the latter in muted
/// secondary text (informational).
private enum ToolTileFooter {
    case callToAction(String)
    case stat(String)
}

/// Single tile in the home screen's `Cleanup tools` grid. Stays purely
/// presentational — the tap action and footer text are passed in from
/// `HomeView` so this view doesn't reach into the cleaner model.
private struct ToolTile: View {
    let title: String
    let description: String
    let systemImage: String
    let tint: Color
    let footer: ToolTileFooter
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.22))
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(tint)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    footerText
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(footerArrowStyle)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private var footerText: some View {
        switch footer {
        case .callToAction(let text):
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        case .stat(let text):
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var footerArrowStyle: AnyShapeStyle {
        switch footer {
        case .callToAction:
            AnyShapeStyle(tint)
        case .stat:
            AnyShapeStyle(.secondary)
        }
    }
}
