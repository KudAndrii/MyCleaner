//
//  DuplicateResultsView.swift
//  my-cleaner
//

import SwiftUI
import AppKit

/// In-flight state for the duplicate scan. Renders the scanner's
/// throttled ``DuplicateScanner/Progress`` signal as a file-count
/// during enumeration and a determinate bar during the hash pass,
/// with a Cancel button so the user can bail out without waiting
/// for the whole scope to finish.
struct DuplicateScanningView: View {
    @Bindable var model: CleanerModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 72, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)

            progressIndicator
                .frame(maxWidth: 360)

            VStack(spacing: 4) {
                Text(headlineText)
                    .font(.title3.weight(.semibold))
                Text(subtitleText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .monospacedDigit()
            }

            Button(role: .cancel) {
                model.cancelDuplicateScan()
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

    @ViewBuilder
    private var progressIndicator: some View {
        switch model.duplicateScanProgress {
        case .hashing(let done, let total) where total > 0:
            ProgressView(value: Double(done), total: Double(total))
                .progressViewStyle(.linear)
        default:
            ProgressView()
                .controlSize(.large)
        }
    }

    private var headlineText: String {
        switch model.duplicateScanProgress {
        case .enumerating: "Scanning files…"
        case .hashing: "Comparing content…"
        case .none: "Looking for duplicate files…"
        }
    }

    private var subtitleText: String {
        switch model.duplicateScanProgress {
        case .enumerating(let n):
            return "Visited \(n.formatted()) \(n == 1 ? "file" : "files") so far."
        case .hashing(let done, let total) where total > 0:
            let pct = Int((Double(done) / Double(total)) * 100)
            return "Hashed \(done.formatted()) of \(total.formatted()) candidates (\(pct)%)."
        case .hashing:
            return "Hashing same-size candidates…"
        case .none:
            return "Comparing every file by size first, then by content. Large folders can take a minute."
        }
    }
}

struct DuplicateResultsView: View {
    @Bindable var model: CleanerModel
    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.duplicateGroups.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .alert("Move \(model.duplicateSelectedCount) duplicate \(model.duplicateSelectedCount == 1 ? "copy" : "copies") to the Trash?",
               isPresented: $showConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                Task { await model.confirmDuplicateCleanup() }
            }
        } message: {
            Text("\(byteCountString(model.duplicateSelectedSize)) will be moved to your Trash. Each duplicate group keeps at least one copy intact.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate files").font(.title2.weight(.semibold))
                if !model.duplicateGroups.isEmpty {
                    Text("\(model.duplicateTotalCopies) copies across \(model.duplicateGroups.count) \(model.duplicateGroups.count == 1 ? "group" : "groups") · up to \(byteCountString(model.duplicateMaximumRecoverableBytes)) recoverable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Text("Identical content, scattered around")
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
            Text("No duplicates found")
                .font(.title3.weight(.semibold))
            Text("Every file in the folders you picked has unique content.")
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
                ForEach(model.duplicateGroups) { group in
                    groupCard(for: group)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }

    private func groupCard(for group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.copies.count) identical copies · \(byteCountString(group.sizePerCopy)) each")
                        .font(.body.weight(.medium))
                    Text("SHA-256 " + group.contentHash.prefix(16) + "…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(byteCountString(group.wastedBytes))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("will be trashed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(group.copies.enumerated()), id: \.element.id) { idx, copy in
                    copyRow(group: group, copy: copy)
                    if idx < group.copies.count - 1 {
                        Divider().padding(.leading, 30)
                    }
                }
            }
            .padding(.leading, 4)
            .padding(.top, 4)
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private func copyRow(group: DuplicateGroup, copy: DuplicateCopy) -> some View {
        let canDeselect = model.canDeselectDuplicateCopy(groupID: group.id, copyID: copy.id)
        let binding = Binding<Bool>(
            get: { copy.isSelectedForDeletion },
            set: { _ in model.toggleDuplicateCopy(groupID: group.id, copyID: copy.id) }
        )

        return HStack(spacing: 10) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!canDeselect)
                .help(canDeselect
                      ? "Move this copy to the Trash."
                      : "At least one copy in each group must be kept.")

            VStack(alignment: .leading, spacing: 1) {
                Text(copy.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(shortenedPath(copy.url))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 6)

            if let date = copy.modificationDate {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([copy.url])
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
            Button(role: .cancel) {
                model.reset()
            } label: {
                Text("Cancel")
                    .frame(minWidth: 70)
            }
            .buttonStyle(.glass)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(model.duplicateSelectedCount) \(model.duplicateSelectedCount == 1 ? "copy" : "copies") selected")
                    .font(.callout.weight(.medium))
                Text("\(byteCountString(model.duplicateSelectedSize)) to Trash")
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
            .disabled(model.duplicateSelectedCount == 0)
        }
        .padding(20)
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
