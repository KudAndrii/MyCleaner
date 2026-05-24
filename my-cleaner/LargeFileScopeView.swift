//
//  LargeFileScopeView.swift
//  my-cleaner
//
//  Pre-scan options sheet shown before the large-file scan starts.
//
//  Lets the user pick:
//    - The minimum file size the scan should surface.
//    - Which targeted nests the directory walk should visit, so the
//      user can opt out of expensive ones (CoreSimulator, Docker)
//      without code changes.
//
//  Spotlight always runs over the home directory — its predicate
//  uses the same minimum-size floor.
//

import SwiftUI

struct LargeFileScopeView: View {
    @Bindable var model: CleanerModel
    @Binding var isPresented: Bool

    @State private var minimumBytes: Int64 = LargeFileScanner.defaultMinimumBytes
    @State private var selectedNestPaths: Set<String> = Set(
        LargeFileScanner.availableNests().map(\.url.path)
    )

    private let availableNests = LargeFileScanner.availableNests()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            sizeSection
            Divider()
            scopeSection
            Divider()
            actions
        }
        .padding(24)
        .frame(width: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scalemass")
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Find large files")
                    .font(.title2.weight(.semibold))
                Text("Pick the size floor and where to look. Spotlight always covers your home folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Size

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Surface files at least this big")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sizeChoices, id: \.0) { (bytes, label) in
                        sizeChip(bytes: bytes, label: label)
                    }
                }
            }
        }
    }

    private var sizeChoices: [(Int64, String)] {
        [
            (50 * 1_024 * 1_024, "50 MB"),
            (100 * 1_024 * 1_024, "100 MB"),
            (500 * 1_024 * 1_024, "500 MB"),
            (1_024 * 1_024 * 1_024, "1 GB"),
            (5 * 1_024 * 1_024 * 1_024, "5 GB"),
        ]
    }

    private func sizeChip(bytes: Int64, label: String) -> some View {
        let selected = minimumBytes == bytes
        return Button {
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

    // MARK: Scope

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Walk these folders after Spotlight")
                .font(.headline)
            Text("Spotlight is usually enough, but these folders often hide bundle-style files Spotlight skips. Deselect the expensive ones if you don't care about them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(availableNests) { nest in
                    nestRow(nest)
                }
            }
            .padding(.top, 4)
        }
    }

    private func nestRow(_ nest: LargeFileNest) -> some View {
        let key = nest.url.path
        let binding = Binding<Bool>(
            get: { selectedNestPaths.contains(key) },
            set: { isOn in
                if isOn { selectedNestPaths.insert(key) }
                else { selectedNestPaths.remove(key) }
            }
        )
        return Toggle(isOn: binding) {
            Text(nest.displayName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button(role: .cancel) {
                isPresented = false
            } label: {
                Text("Cancel")
                    .frame(minWidth: 80)
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.glass)
            .controlSize(.large)

            Spacer()

            Button {
                isPresented = false
                let nests = availableNests.filter { selectedNestPaths.contains($0.url.path) }
                model.startLargeFileScan(minimumBytes: minimumBytes, nests: nests)
            } label: {
                Label("Find large files", systemImage: "scalemass")
                    .padding(.horizontal, 6)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }
}
