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
                heroRow
                toolsSection
                footerCard
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
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

    // MARK: - Hero row (drop zone + insight)

    /// Top section of the home screen. The two cards always sit
    /// side-by-side, even at the minimum window width — the insight
    /// card is capped so the drop zone keeps the bulk of the row.
    /// `Grid` keeps both cells the same height (matched to the taller
    /// of the two) so the cards line up visually.
    private var heroRow: some View {
        Grid(alignment: .top, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                dropZoneCard
                insightCard
                    .frame(minWidth: 220, idealWidth: 320, maxWidth: 340)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Reclaimable Space insight

    /// Companion to the drop zone. Aggregates whatever survives in the
    /// scan cache into a single "reclaimable" headline + stacked bar +
    /// legend. Stays empty-stated until the user has actually run a
    /// scan — we never claim a number we didn't measure.
    private var insightCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("RECLAIMABLE SPACE")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }

            let segments = model.scanCache.reclaimableSegments
            if segments.isEmpty {
                insightEmptyState
            } else {
                insightPopulated(segments: segments)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
    }

    private var insightEmptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing measured yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Run any tool below and we'll start tracking how much space you can win back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func insightPopulated(segments: [ScanCache.ReclaimableSegment]) -> some View {
        let total = segments.map(\.bytes).reduce(0, +)
        let totalString = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(totalString)
                    .font(.system(size: 36, weight: .bold))
                Text("reclaimable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("across \(segments.count) \(segments.count == 1 ? "category" : "categories") on this Mac")
                .font(.caption)
                .foregroundStyle(.secondary)

            stackedBar(segments: segments, total: total)
            legend(segments: segments)
        }
    }

    private func stackedBar(segments: [ScanCache.ReclaimableSegment], total: Int64) -> some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments, id: \.label) { segment in
                    let fraction = total > 0 ? CGFloat(segment.bytes) / CGFloat(total) : 0
                    Rectangle()
                        .fill(insightColor(for: segment.label))
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
        }
        .frame(height: 8)
        .clipShape(.capsule)
    }

    private func legend(segments: [ScanCache.ReclaimableSegment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(segments, id: \.label) { segment in
                HStack(spacing: 8) {
                    Circle()
                        .fill(insightColor(for: segment.label))
                        .frame(width: 7, height: 7)
                    Text(segment.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(ByteCountFormatter.string(fromByteCount: segment.bytes, countStyle: .file))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func insightColor(for label: String) -> Color {
        switch label {
        case "App leftovers": .indigo
        case "Large files": .orange
        case "Oversized caches": .teal
        case "Duplicate files": .purple
        default: .gray
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

    /// Slim row that closes out the scroll content. Two independent
    /// glass tiles so each half reads as its own affordance — the
    /// left holds the login-items toggle, the right is one large
    /// pressable surface that opens the System Checks sheet.
    private var footerCard: some View {
        HStack(spacing: 12) {
            loginItemsCell
            systemChecksCell
        }
    }

    private var loginItemsCell: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.blue.opacity(0.22))
                Image(systemName: "person.crop.circle.badge.clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Background login items")
                    .font(.caption.weight(.medium))
                Text(loginItemsStateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var systemChecksCell: some View {
        Button {
            onReviewPermissions()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.green.opacity(0.22))
                    Image(systemName: "stethoscope")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("System checks")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Permissions & scanner availability")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .help("Inspect permissions and scanner availability.")
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
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.orange.opacity(0.22))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
            }
            .frame(width: 40, height: 40)

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
        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .rect(cornerRadius: 14))
    }

    private var permissionsBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.orange.opacity(0.22))
                Image(systemName: "lock.shield")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 36, height: 36)

            Text(bannerText)
                .font(.callout)
            Spacer(minLength: 8)
            Button("Review…") { onReviewPermissions() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .rect(cornerRadius: 12))
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
