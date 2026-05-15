//
//  OrphanResultsView.swift
//  my-cleaner
//

import SwiftUI
import AppKit

struct OrphanScanningView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 72, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 4) {
                Text("Scanning for leftovers…")
                    .font(.title3.weight(.semibold))
                Text("Looking for files that belong to apps you've already removed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OrphanResultsView: View {
    @Bindable var model: CleanerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.orphanGroups.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "tray.2.fill")
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Orphaned files").font(.title2.weight(.semibold))
                if !model.orphanGroups.isEmpty {
                    Text("\(model.orphanGroups.count) bundle IDs · \(byteCountString(model.orphanTotalSize)) recoverable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Text("Apps gone, files left behind")
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
            Text("Nothing orphaned")
                .font(.title3.weight(.semibold))
            Text("Every bundle ID we found in your Library still maps to an installed app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.orphanGroups) { group in
                    groupCard(for: group)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }

    private func groupCard(for group: OrphanGroup) -> some View {
        let binding = Binding<Bool>(
            get: { model.orphanGroups.first { $0.id == group.id }?.isSelected ?? false },
            set: { _ in model.toggleOrphanGroup(id: group.id) }
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.bundleID)
                        .font(.body.weight(.medium))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(group.items.count) \(group.items.count == 1 ? "item" : "items")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(byteCountString(group.totalSize))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                    itemRow(item)
                    if idx < group.items.count - 1 {
                        Divider().padding(.leading, 30)
                    }
                }
            }
            .padding(.leading, 28)
            .padding(.top, 2)
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .contentShape(.rect)
        .onTapGesture { model.toggleOrphanGroup(id: group.id) }
    }

    private func itemRow(_ item: RelatedItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.category.symbol)
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(shortenedPath(item.url))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            Text(item.sizeBytes > 0 ? byteCountString(item.sizeBytes) : "—")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
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
                model.toggleAllOrphans()
            } label: {
                Text(model.allOrphansSelected ? "Deselect all" : "Select all")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.glass)
            .disabled(model.orphanGroups.isEmpty)

            Button(role: .cancel) {
                model.reset()
            } label: {
                Text("Cancel")
                    .frame(minWidth: 70)
            }
            .buttonStyle(.glass)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(model.orphanSelectedCount) \(model.orphanSelectedCount == 1 ? "item" : "items") in \(selectedGroupCount) \(selectedGroupCount == 1 ? "group" : "groups")")
                    .font(.callout.weight(.medium))
                Text("\(byteCountString(model.orphanSelectedSize)) to Trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button(role: .destructive) {
                Task { await model.confirmOrphanCleanup() }
            } label: {
                Label("Move to Trash", systemImage: "trash.fill")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(model.orphanSelectedCount == 0)
        }
        .padding(20)
    }

    private var selectedGroupCount: Int {
        model.orphanGroups.filter(\.isSelected).count
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
