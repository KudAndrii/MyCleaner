//
//  StageViews.swift
//  my-cleaner
//

import SwiftUI

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
    let count: Int
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 88))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
            VStack(spacing: 4) {
                Text("All clean")
                    .font(.title.weight(.semibold))
                Text("\(count) \(count == 1 ? "item" : "items") moved to the Trash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                onReset()
            } label: {
                Label("Clean another app", systemImage: "arrow.counterclockwise")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
