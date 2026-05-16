//
//  ResultsView.swift
//  my-cleaner
//

import SwiftUI
import AppKit

struct ResultsView: View {
    @Bindable var model: CleanerModel

    private var grouped: [(RelatedItem.Category, [RelatedItem])] {
        let dict = Dictionary(grouping: model.items, by: \.category)
        return RelatedItem.Category.allCases.compactMap { cat in
            guard let items = dict[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.items.isEmpty && model.systemExtensions.isEmpty {
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
            if let app = model.droppedApp {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.title2.weight(.semibold))
                    if let bid = app.bundleID {
                        Text(bid)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(byteCountString(model.appSize))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text("App size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.items.isEmpty {
                    Text("\(model.items.count) leftover · \(byteCountString(model.totalSize))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("No leftover files found")
                .font(.title3.weight(.semibold))
            if let name = model.droppedApp?.name {
                Text("Only \(name) itself (\(byteCountString(model.appSize))) will be moved to the Trash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if SandboxStatus.isSandboxed {
                Label("App Sandbox is on — disable it to scan ~/Library.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 18, pinnedViews: []) {
                if !model.systemExtensions.isEmpty {
                    systemExtensionsSection
                }
                ForEach(grouped, id: \.0) { (cat, items) in
                    section(category: cat, items: items)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }

    private var systemExtensionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(.orange)
                Text("System Extensions")
                    .font(.subheadline.weight(.semibold))
                Text("· \(model.systemExtensions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)

            Text("These stay loaded after the app is trashed. Removing them requires macOS's confirmation prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            VStack(spacing: 0) {
                ForEach(Array(model.systemExtensions.enumerated()), id: \.element.id) { idx, ext in
                    systemExtensionRow(ext)
                    if idx < model.systemExtensions.count - 1 {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 14))
        }
    }

    private func systemExtensionRow(_ ext: SystemExtensionInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(ext.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(ext.bundleID + (ext.version.isEmpty ? "" : " · \(ext.version)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Team \(ext.teamID)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Button {
                Task { await model.uninstallSystemExtension(ext) }
            } label: {
                Text("Uninstall…")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Asks macOS to remove this extension. You'll be prompted to confirm.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func section(category: RelatedItem.Category, items: [RelatedItem]) -> some View {
        let totalSize = items.map(\.sizeBytes).reduce(0, +)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: category.symbol)
                    .foregroundStyle(.tint)
                Text(category.rawValue)
                    .font(.subheadline.weight(.semibold))
                Text("· \(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(byteCountString(totalSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    row(for: item)
                    if idx < items.count - 1 {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 14))
        }
    }

    private func row(for item: RelatedItem) -> some View {
        let binding = Binding<Bool>(
            get: { model.items.first(where: { $0.id == item.id })?.isSelected ?? false },
            set: { newValue in
                if let i = model.items.firstIndex(where: { $0.id == item.id }) {
                    model.items[i].isSelected = newValue
                }
            }
        )
        return HStack(spacing: 12) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.checkbox)

            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(shortenedPath(item.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if item.isShared {
                    Label(sharedReason(for: item), systemImage: sharedSymbol(for: item))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 8)

            Text(item.sizeBytes > 0 ? byteCountString(item.sizeBytes) : "—")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture { binding.wrappedValue.toggle() }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                model.toggleAll()
            } label: {
                Text(model.allSelected ? "Deselect all" : "Select all")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.glass)
            .disabled(model.items.isEmpty)

            Button(role: .cancel) {
                model.reset()
            } label: {
                Text("Cancel")
                    .frame(minWidth: 70)
            }
            .buttonStyle(.glass)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(model.selectedCount) of \(model.items.count) selected")
                    .font(.callout.weight(.medium))
                Text("\(byteCountString(model.trashTotal)) to Trash · incl. the app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button(role: .destructive) {
                Task { await model.confirmCleanup() }
            } label: {
                Label("Move to Trash", systemImage: "trash.fill")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.large)
        }
        .padding(20)
    }

    private func byteCountString(_ b: Int64) -> String {
        b.formatted(.byteCount(style: .file))
    }

    private func sharedReason(for item: RelatedItem) -> String {
        switch item.category {
        case .iCloud:
            return "Contains documents synced via iCloud — deletion may remove them on other devices"
        default:
            return "Shared with other apps from this developer"
        }
    }

    private func sharedSymbol(for item: RelatedItem) -> String {
        item.category == .iCloud ? "icloud.fill" : "person.2.fill"
    }

    private func shortenedPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let parent = url.deletingLastPathComponent().path
        if parent.hasPrefix(home) { return "~" + parent.dropFirst(home.count) }
        return parent
    }
}
