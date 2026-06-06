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
                model.cancelDuplicateScan()
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
                    .fill(.purple.opacity(0.22))
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.purple)
            }
            .frame(width: 76, height: 76)

            VStack(spacing: 4) {
                Text("Looking for duplicate files…")
                    .font(.title3.weight(.semibold))
                Text("\(completedCount) of \(model.duplicateScanPhases.count) steps complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var phaseList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.duplicateScanPhases.enumerated()), id: \.element.id) { idx, phase in
                phaseRow(phase)
                if idx < model.duplicateScanPhases.count - 1 {
                    Divider().padding(.leading, 38)
                }
            }
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private func phaseRow(_ phase: DuplicateScanPhase) -> some View {
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
    private func statusIcon(for status: DuplicateScanPhase.Status) -> some View {
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

    private func statusDetail(for phase: DuplicateScanPhase) -> String {
        let isHashPhase = phase.id == DuplicateScanner.hashPhaseID
        switch phase.status {
        case .pending:
            return "Waiting"
        case .inProgress:
            if isHashPhase, phase.counterTotal > 0 {
                let pct = Int((Double(phase.counter) / Double(phase.counterTotal)) * 100)
                return "Hashed \(phase.counter.formatted()) of \(phase.counterTotal.formatted()) (\(pct)%)"
            }
            if isHashPhase {
                return "Comparing content…"
            }
            return "Visited \(phase.counter.formatted()) \(phase.counter == 1 ? "file" : "files")"
        case .completed:
            if isHashPhase {
                return "Hashed \(phase.counter.formatted()) of \(phase.counterTotal.formatted())"
            }
            return "\(phase.counter.formatted()) \(phase.counter == 1 ? "file" : "files")"
        }
    }

    private var completedCount: Int {
        model.duplicateScanPhases.filter { $0.status == .completed }.count
    }
}

struct DuplicateResultsView: View {
    @Bindable var model: CleanerModel
    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.duplicateGroups.isEmpty {
                emptyState
            } else {
                list
            }
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
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.purple.opacity(0.22))
                Image(systemName: "doc.on.doc.fill")
                    .font(.title)
                    .foregroundStyle(.purple)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text("Duplicate files").font(.title.weight(.semibold))
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
        .padding(.vertical, 20)
        .background(.bar)
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
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
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
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
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
