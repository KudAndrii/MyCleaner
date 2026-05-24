//
//  LargeFileResultsView.swift
//  my-cleaner
//

import SwiftUI
import AppKit

struct LargeFileScanningView: View {
    @Bindable var model: CleanerModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "scalemass")
                .font(.system(size: 72, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 6) {
                Text("Ranking the biggest files…")
                    .font(.title3.weight(.semibold))
                Text("Asking Spotlight for files above 100 MB and topping up well-known nests (simulator runtimes, Docker, virtual machines).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                if model.largeFileScanProgress > 0 {
                    Text("\(model.largeFileScanProgress) \(model.largeFileScanProgress == 1 ? "candidate" : "candidates") found so far")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .padding(.top, 4)
                }
            }
            Button(role: .cancel) {
                model.cancelLargeFileScan()
            } label: {
                Text("Cancel")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LargeFileResultsView: View {
    @Bindable var model: CleanerModel
    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            if model.largeFiles.isEmpty {
                emptyState
            } else if model.visibleLargeFiles.isEmpty {
                filteredEmptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .alert("Move \(model.largeFileSelectedCount) \(model.largeFileSelectedCount == 1 ? "item" : "items") to the Trash?",
               isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                Task { await model.confirmLargeFileCleanup() }
            }
        } message: {
            Text("\(byteCountString(model.largeFileSelectedSize)) will be moved to your Trash. Running virtual machines or mounted disk images may refuse to move until you quit or unmount them first.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "scalemass.fill")
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Large files").font(.title2.weight(.semibold))
                if !model.largeFiles.isEmpty {
                    Text("\(model.largeFiles.count) above \(byteCountString(model.largeFileMinimumBytes)) · top consumers in your home folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Text("Biggest first")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(label: "All", count: model.largeFiles.count, selected: model.largeFileCategoryFilter == nil) {
                        model.largeFileCategoryFilter = nil
                    }
                    ForEach(LargeFileCategory.allCases, id: \.self) { cat in
                        let count = model.largeFiles.lazy.filter { $0.category == cat }.count
                        if count > 0 {
                            chip(
                                label: cat.rawValue,
                                symbol: cat.symbol,
                                count: count,
                                selected: model.largeFileCategoryFilter == cat
                            ) {
                                model.largeFileCategoryFilter = (model.largeFileCategoryFilter == cat) ? nil : cat
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
            }

            HStack(spacing: 12) {
                Image(systemName: "ruler")
                    .foregroundStyle(.secondary)
                Text("Minimum size")
                    .font(.caption.weight(.medium))
                ForEach(minimumSizeChoices, id: \.0) { (bytes, label) in
                    let isSelected = model.largeFileMinimumBytes == bytes
                    Button {
                        model.largeFileMinimumBytes = bytes
                    } label: {
                        Text(label)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.background.secondary),
                                in: .capsule
                            )
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .padding(.top, 12)
    }

    /// Discrete minimum-size choices shown beside the slider label.
    /// Spans the practical range — 50 MB picks up large installers and
    /// crash bundles, 1 GB narrows to the truly outsized.
    private var minimumSizeChoices: [(Int64, String)] {
        [
            (50 * 1_024 * 1_024, "50 MB"),
            (100 * 1_024 * 1_024, "100 MB"),
            (500 * 1_024 * 1_024, "500 MB"),
            (1_024 * 1_024 * 1_024, "1 GB"),
        ]
    }

    private func chip(
        label: String,
        symbol: String? = nil,
        count: Int,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.caption2)
                }
                Text(label).font(.caption.weight(.medium))
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.background.tertiary, in: .capsule)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                selected ? AnyShapeStyle(Color.accentColor.opacity(0.20)) : AnyShapeStyle(.background.secondary),
                in: .capsule
            )
            .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Empty states

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("No large files found")
                .font(.title3.weight(.semibold))
            Text("Nothing in your home folder is above the size threshold. Try lowering the minimum size to widen the search.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No matches for the current filters")
                .font(.callout.weight(.semibold))
            Text("Pick a different category chip or lower the minimum size.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.visibleLargeFiles.enumerated()), id: \.element.id) { idx, entry in
                    row(for: entry)
                    if idx < model.visibleLargeFiles.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 14))
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }

    private func row(for entry: LargeFileEntry) -> some View {
        let binding = Binding<Bool>(
            get: { model.largeFiles.first(where: { $0.id == entry.id })?.isSelected ?? false },
            set: { _ in model.toggleLargeFile(id: entry.id) }
        )
        return HStack(spacing: 12) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.checkbox)

            Image(systemName: entry.category.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(shortenedPath(entry.url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                HStack(spacing: 8) {
                    Text(entry.category.rawValue)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.background.tertiary, in: .capsule)
                        .foregroundStyle(.secondary)
                    if let date = entry.modificationDate {
                        Text("Modified \(date.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 8)

            Text(byteCountString(entry.sizeBytes))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
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

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                model.toggleAllLargeFiles()
            } label: {
                Text(model.allLargeFilesSelected ? "Deselect all" : "Select all")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.glass)
            .disabled(model.visibleLargeFiles.isEmpty)

            Button(role: .cancel) {
                model.reset()
            } label: {
                Text("Cancel")
                    .frame(minWidth: 70)
            }
            .buttonStyle(.glass)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(model.largeFileSelectedCount) of \(model.visibleLargeFiles.count) selected")
                    .font(.callout.weight(.medium))
                Text("\(byteCountString(model.largeFileSelectedSize)) to Trash")
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
            .disabled(model.largeFileSelectedCount == 0)
        }
        .padding(20)
    }

    // MARK: Formatting helpers

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
