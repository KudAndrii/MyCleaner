//
//  StageViews.swift
//  my-cleaner
//

import SwiftUI
import AppKit

struct CleaningView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Moving items to the Trash…")
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct DoneView: View {
    let report: CleanupReport
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            heading
            if !report.failures.isEmpty {
                failureList
                fdaHint
            }
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    @ViewBuilder
    private var heading: some View {
        if report.failures.isEmpty {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
            VStack(spacing: 4) {
                Text("All clean").font(.title.weight(.semibold))
                Text("\(report.trashed) \(report.trashed == 1 ? "item" : "items") moved to the Trash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if report.trashed > 0 {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
            VStack(spacing: 4) {
                Text("Partially cleaned").font(.title.weight(.semibold))
                Text("\(report.trashed) moved · \(report.failures.count) couldn't be trashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
            VStack(spacing: 4) {
                Text("Nothing was moved").font(.title.weight(.semibold))
                Text("\(report.failures.count) \(report.failures.count == 1 ? "item" : "items") were blocked by macOS.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var failureList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(report.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.url.lastPathComponent)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.background.secondary, in: .rect(cornerRadius: 10))
                    .help(failure.url.path)
                }
            }
        }
        .frame(maxWidth: 520, maxHeight: 180)
    }

    private var fdaHint: some View {
        Text("Most failures here are macOS privacy controls (Full Disk Access). Grant My Cleaner that permission and run the scan again.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if !report.failures.isEmpty {
                Button {
                    openFullDiskAccessSettings()
                } label: {
                    Label("Open Full Disk Access", systemImage: "lock.shield")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }

            Button {
                onReset()
            } label: {
                Label("Clean another app", systemImage: "arrow.counterclockwise")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(.top, 4)
    }

    private func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
