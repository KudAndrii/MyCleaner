//
//  AnalyzingView.swift
//  my-cleaner
//

import SwiftUI
import AppKit

struct AnalyzingView: View {
    let app: DroppedApp?

    var body: some View {
        VStack(spacing: 24) {
            if let app {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            }
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 4) {
                Text("Scanning your Mac…")
                    .font(.title3.weight(.semibold))
                if let app {
                    Text("Looking for files related to \(app.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
