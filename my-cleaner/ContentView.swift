//
//  ContentView.swift
//  my-cleaner
//

import SwiftUI

struct ContentView: View {
    @State private var model = CleanerModel()

    var body: some View {
        ZStack {
            backgroundLayer
            content
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
        }
        .animation(.smooth(duration: 0.35), value: stageID)
        .frame(minWidth: 760, minHeight: 560)
    }

    private var stageID: Int {
        switch model.stage {
        case .idle: 0
        case .analyzing: 1
        case .results: 2
        case .cleaning: 3
        case .done: 4
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .idle:
            DropZoneView(model: model)
        case .analyzing:
            AnalyzingView(app: model.droppedApp)
        case .results:
            ResultsView(model: model)
        case .cleaning:
            CleaningView()
        case .done(let report):
            DoneView(report: report) { model.reset() }
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .underPageBackgroundColor),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [.accentColor.opacity(0.18), .clear],
                center: .topLeading,
                startRadius: 40,
                endRadius: 520
            )
            RadialGradient(
                colors: [.purple.opacity(0.12), .clear],
                center: .bottomTrailing,
                startRadius: 60,
                endRadius: 560
            )
        }
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
