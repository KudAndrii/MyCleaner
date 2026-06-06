//
//  DuplicateScopeView.swift
//  my-cleaner
//
//  Pre-scan options sheet for the duplicate-detection flow.
//
//  Renders a checkbox per ``DuplicateScopeFolder`` so the user can
//  narrow the scan before it kicks off. Existing per-app and orphan
//  flows are zero-config; duplicate detection is the first feature
//  where the right scope depends on the user's setup (e.g. someone
//  who keeps everything in ~/Documents vs. someone who lives in
//  ~/Downloads), so the choice can't be hard-coded.
//

import SwiftUI

struct DuplicateScopeView: View {
    @Binding var selection: Set<DuplicateScopeFolder>
    @Binding var isPresented: Bool
    var onStart: ([URL], Int64) -> Void

    @State private var minimumBytes: Int64 = DuplicateScanner.defaultMinimumBytes

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sizeFilter
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.purple.opacity(0.22))
                Image(systemName: "doc.on.doc.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text("Find duplicate files")
                    .font(.title2.weight(.semibold))
                Text("Choose which folders to compare. Files are matched by exact content, not by name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(20)
    }

    /// Discrete minimum-size choices. Files below the chosen floor
    /// are skipped during enumeration — both because small duplicates
    /// don't move the needle on disk usage and because the long tail
    /// of tiny files is what makes a million-file scope blow up memory.
    private var sizeChoices: [(Int64, String)] {
        [
            (100 * 1024,             "100 KB"),
            (1 * 1024 * 1024,        "1 MB"),
            (10 * 1024 * 1024,       "10 MB"),
            (100 * 1024 * 1024,      "100 MB"),
        ]
    }

    private var sizeFilter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "ruler")
                    .foregroundStyle(.secondary)
                Text("Ignore files smaller than")
                    .font(.callout.weight(.medium))
            }
            HStack(spacing: 6) {
                ForEach(sizeChoices, id: \.0) { (bytes, label) in
                    let selected = minimumBytes == bytes
                    Button {
                        minimumBytes = bytes
                    } label: {
                        Text(label)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                selected ? AnyShapeStyle(Color.accentColor.opacity(0.20)) : AnyShapeStyle(.background.secondary),
                                in: .capsule
                            )
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Smaller duplicates rarely free meaningful space, and ignoring them keeps memory usage in check on large folders.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(DuplicateScopeFolder.allCases) { folder in
                    row(for: folder)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func row(for folder: DuplicateScopeFolder) -> some View {
        let binding = Binding<Bool>(
            get: { selection.contains(folder) },
            set: { isOn in
                if isOn { selection.insert(folder) } else { selection.remove(folder) }
            }
        )
        let exists = FileManager.default.fileExists(atPath: folder.url.path)
        return HStack(spacing: 12) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!exists)

            Image(systemName: folder.symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(folder.title)
                    .font(.body.weight(.medium))
                Text("~/" + folder.title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !exists {
                Text("Not found")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            guard exists else { return }
            if selection.contains(folder) {
                selection.remove(folder)
            } else {
                selection.insert(folder)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .opacity(exists ? 1 : 0.55)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(role: .cancel) {
                isPresented = false
            } label: {
                Text("Cancel")
                    .frame(minWidth: 70)
            }
            .buttonStyle(.glass)

            Spacer()

            Button {
                let urls = selection
                    .sorted { $0.rawValue < $1.rawValue }
                    .map(\.url)
                onStart(urls, minimumBytes)
            } label: {
                Label("Start Scan", systemImage: "magnifyingglass")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(selection.isEmpty)
        }
        .padding(16)
    }
}
