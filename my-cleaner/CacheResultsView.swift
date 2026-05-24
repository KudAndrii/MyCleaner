//
//  CacheResultsView.swift
//  my-cleaner
//

import SwiftUI
import AppKit

struct CacheScanningView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 72, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 4) {
                Text("Measuring cache directories…")
                    .font(.title3.weight(.semibold))
                Text("Looking for apps and toolchains hoarding more than 50 MB of cache.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CacheResultsView: View {
    @Bindable var model: CleanerModel
    @State private var showConfirm = false
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.cacheGroups.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
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
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Oversized caches").font(.title2.weight(.semibold))
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
        .padding(.vertical, 18)
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
                .frame(maxWidth: 400)
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
                        if !group.isSafeToDelete {
                            Label("Unattributed — review before trashing", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                        if isRunning(group) {
                            Label("App is running", systemImage: "play.circle.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
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
        .background(.background.secondary, in: .rect(cornerRadius: 14))
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
            Label("Installed app", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.green)
        case .orphanApp:
            Label("Orphaned — app no longer installed", systemImage: "tray.2.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.blue)
        case .toolchain:
            Label("Toolchain cache", systemImage: "hammer.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.purple)
        case .anonymous:
            Label("Unattributed", systemImage: "questionmark.folder.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
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
        .padding(20)
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
