//
//  CacheResultsView.swift
//  my-cleaner
//

import SwiftUI
import AppKit

struct CacheScanningView: View {
    @Bindable var model: CleanerModel

    var body: some View {
        VStack(spacing: 0) {
            heading
                .padding(.top, 28)
                .padding(.bottom, 18)
            ScrollView {
                phaseList
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
            Divider()
            Button(role: .cancel) {
                model.cancelCacheScan()
            } label: {
                Text("Cancel")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var heading: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.teal.opacity(0.22))
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.teal)
            }
            .frame(width: 76, height: 76)

            VStack(spacing: 4) {
                Text("Measuring cache directories…")
                    .font(.title3.weight(.semibold))
                Text("\(completedCount) of \(model.cacheScanPhases.count) steps complete · \(totalGroups) \(totalGroups == 1 ? "candidate" : "candidates") so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var phaseList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.cacheScanPhases.enumerated()), id: \.element.id) { idx, phase in
                phaseRow(phase)
                if idx < model.cacheScanPhases.count - 1 {
                    Divider().padding(.leading, 38)
                }
            }
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private func phaseRow(_ phase: CacheScanPhase) -> some View {
        HStack(spacing: 12) {
            statusIcon(for: phase.status)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(phase.displayName)
                    .font(.callout.weight(phase.status == .inProgress ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusDetail(for: phase))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusIcon(for status: CacheScanPhase.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.body)
                .foregroundStyle(.tertiary)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
        }
    }

    private func statusDetail(for phase: CacheScanPhase) -> String {
        switch phase.status {
        case .pending: "Waiting"
        case .inProgress: "Scanning…"
        case .completed: "\(phase.groupsAfter) \(phase.groupsAfter == 1 ? "candidate" : "candidates")"
        }
    }

    private var completedCount: Int {
        model.cacheScanPhases.filter { $0.status == .completed }.count
    }

    /// Running total of surviving cache groups so far. Each phase's
    /// `groupsAfter` is the cumulative count *after* it finished, so
    /// taking the max gives the latest snapshot.
    private var totalGroups: Int {
        model.cacheScanPhases.map(\.groupsAfter).max() ?? 0
    }
}

struct CacheResultsView: View {
    @Bindable var model: CleanerModel
    @State private var showConfirm = false
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.cacheGroups.isEmpty {
                emptyState
            } else {
                list
            }
            footer
        }
        .alert("Move \(model.cacheSelectedCount) cache \(model.cacheSelectedCount == 1 ? "entry" : "entries") to the Trash?",
               isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                Task { await model.confirmCacheCleanup() }
            }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        let size = byteCountString(model.cacheSelectedSize)
        var lines = ["\(size) across \(selectedGroupCount) \(selectedGroupCount == 1 ? "cache" : "caches") will be moved to your Trash."]
        if hasRunningSelection {
            lines.append("⚠︎ One or more owning apps are currently running. Quit them first so they don't re-create the cache mid-trash.")
        }
        lines.append("Apps recreate caches on next launch as needed — this is normal.")
        return lines.joined(separator: "\n\n")
    }

    private var hasRunningSelection: Bool {
        let running = runningBundleIDs()
        return model.cacheGroups.contains { group in
            guard group.isSelected, let bid = group.bundleID else { return false }
            return running.contains(bid.lowercased())
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.teal.opacity(0.22))
                Image(systemName: "externaldrive.fill")
                    .font(.title)
                    .foregroundStyle(.teal)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text("Oversized caches").font(.title.weight(.semibold))
                if !model.cacheGroups.isEmpty {
                    Text("\(model.cacheGroups.count) \(model.cacheGroups.count == 1 ? "group" : "groups") · \(byteCountString(model.cacheTotalSize)) recoverable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Text("Wipe caches, keep the apps")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Nothing oversized")
                .font(.title3.weight(.semibold))
            Text("No app or toolchain cache passed the 50 MB threshold. Try again after a few weeks of normal use.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                model.reset()
            } label: {
                Text("OK").frame(minWidth: 100)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.cacheGroups) { group in
                    groupCard(for: group)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }

    private func groupCard(for group: CacheGroup) -> some View {
        let binding = Binding<Bool>(
            get: { model.cacheGroups.first { $0.id == group.id }?.isSelected ?? false },
            set: { _ in model.toggleCacheGroup(id: group.id) }
        )
        let isExpanded = expandedGroups.contains(group.id)
        let canExpand = group.entries.count > 1

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                groupIcon(for: group)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let bid = group.bundleID {
                        Text(bid)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 6) {
                        kindBadge(for: group)
                        if isRunning(group) {
                            badgeWithInfoHint(
                                color: .orange,
                                tooltip: "This app is open right now. Quit it before clearing its cache, otherwise the app may re-create the files mid-trash and waste your effort."
                            ) {
                                Label("App is running", systemImage: "play.circle.fill")
                                    .font(.caption2.weight(.medium))
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(byteCountString(group.totalBytes))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if canExpand {
                        Button {
                            if isExpanded {
                                expandedGroups.remove(group.id)
                            } else {
                                expandedGroups.insert(group.id)
                            }
                        } label: {
                            Label(
                                "\(group.entries.count) entries",
                                systemImage: isExpanded ? "chevron.up" : "chevron.down"
                            )
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            // Header taps the group toggle; the expand button has its
            // own hit target so it doesn't double-fire.
            .contentShape(.rect)
            .onTapGesture { model.toggleCacheGroup(id: group.id) }

            if canExpand && isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { idx, entry in
                        entryRow(entry)
                        if idx < group.entries.count - 1 {
                            Divider().padding(.leading, 30)
                        }
                    }
                }
                .padding(.leading, 44)
                .padding(.top, 4)
            } else if !canExpand, let first = group.entries.first {
                entryRow(first)
                    .padding(.leading, 44)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func groupIcon(for group: CacheGroup) -> some View {
        if let appURL = group.appURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: iconName(for: group.kind))
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
        }
    }

    private func iconName(for kind: CacheGroup.Kind) -> String {
        switch kind {
        case .installedApp: "app.fill"
        case .orphanApp: "questionmark.app.dashed"
        case .toolchain: "hammer.fill"
        case .anonymous: "folder.fill"
        }
    }

    @ViewBuilder
    private func kindBadge(for group: CacheGroup) -> some View {
        switch group.kind {
        case .installedApp:
            badgeWithInfoHint(
                color: .green,
                tooltip: "A temporary-files folder belonging to an app you have installed. Safe to remove — the app rebuilds what it needs the next time you open it."
            ) {
                Label("App cache", systemImage: "checkmark.seal.fill")
                    .font(.caption2.weight(.medium))
            }
        case .orphanApp:
            badgeWithInfoHint(
                color: .blue,
                tooltip: "This cache was created by an app that's no longer on your Mac. Nothing will ever read it again — safe to delete."
            ) {
                Label("App removed", systemImage: "tray.2.fill")
                    .font(.caption2.weight(.medium))
            }
        case .toolchain:
            badgeWithInfoHint(
                color: .purple,
                tooltip: "A cache created by a developer tool (for example npm, Gradle, or Xcode). Safe to remove — the tool will re-download or rebuild what it needs the next time you use it."
            ) {
                Label("Developer tool cache", systemImage: "hammer.fill")
                    .font(.caption2.weight(.medium))
            }
        case .anonymous:
            badgeWithInfoHint(
                color: .orange,
                tooltip: "We couldn't tell which app created this folder. If you don't recognise the name shown above, leave it unchecked — deleting unfamiliar caches can occasionally break an app."
            ) {
                Label("Unknown source — check before deleting", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
            }
        }
    }

    /// Wraps a coloured badge with a trailing `info.circle` icon and a
    /// `.help()` tooltip, so the user has a visual cue that hovering
    /// will reveal an explanation. The icon is dimmer than the badge
    /// text so it reads as a secondary hint rather than another label.
    @ViewBuilder
    private func badgeWithInfoHint<C: ShapeStyle, Content: View>(
        color: C,
        tooltip: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 3) {
            content()
            Image(systemName: "info.circle")
                .font(.caption2)
                .imageScale(.small)
                .opacity(0.7)
        }
        .foregroundStyle(color)
        .help(tooltip)
    }

    private func entryRow(_ entry: CacheEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(shortenedPath(entry.url))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            Text(byteCountString(entry.sizeBytes))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                model.toggleAllCaches()
            } label: {
                Text(model.allCachesSelected ? "Deselect all" : "Select all")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.glass)
            .disabled(model.cacheGroups.isEmpty)

            Button(role: .cancel) {
                model.reset()
            } label: {
                Text("Cancel")
                    .frame(minWidth: 70)
            }
            .buttonStyle(.glass)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(model.cacheSelectedCount) \(model.cacheSelectedCount == 1 ? "entry" : "entries") in \(selectedGroupCount) \(selectedGroupCount == 1 ? "group" : "groups")")
                    .font(.callout.weight(.medium))
                Text("\(byteCountString(model.cacheSelectedSize)) to Trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button(role: .destructive) {
                showConfirm = true
            } label: {
                Label("Move to Trash", systemImage: "trash.fill")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(model.cacheSelectedCount == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .opacity(model.cacheGroups.isEmpty ? 0 : 1)
        .background(.bar)
    }

    private var selectedGroupCount: Int {
        model.cacheGroups.filter(\.isSelected).count
    }

    private func isRunning(_ group: CacheGroup) -> Bool {
        guard let bid = group.bundleID else { return false }
        return runningBundleIDs().contains(bid.lowercased())
    }

    private func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
    }

    private func byteCountString(_ b: Int64) -> String {
        b.formatted(.byteCount(style: .file))
    }

    private func shortenedPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let parent = url.deletingLastPathComponent().path
        if parent.hasPrefix(home) { return "~" + parent.dropFirst(home.count) }
        return parent
    }
}
