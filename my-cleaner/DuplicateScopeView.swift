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
    var onStart: ([URL]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 460, height: 480)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
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
        .background(.background.secondary, in: .rect(cornerRadius: 10))
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
                onStart(urls)
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
