//
//  ContentView.swift
//  my-cleaner
//

import SwiftUI

struct ContentView: View {
    @State private var model = CleanerModel()
    @State private var permissions = PermissionsChecker()
    @State private var scannerHealth = ScannerHealthChecker()
    @State private var showPermissions = false

    var body: some View {
        ZStack {
            backgroundLayer
            content
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
        }
        .animation(.smooth(duration: 0.35), value: stageID)
        .frame(minWidth: 760, minHeight: 560)
        .task {
            permissions.refresh()
            scannerHealth.refresh()
            if permissions.needsAttention || scannerHealth.needsAttention {
                showPermissions = true
            }
        }
        .sheet(isPresented: $showPermissions) {
            PermissionsView(
                permissions: permissions,
                scannerHealth: scannerHealth,
                isPresented: $showPermissions
            )
        }
    }

    private var stageID: Int {
        switch model.stage {
        case .idle: 0
        case .analyzing: 1
        case .results: 2
        case .cleaning: 3
        case .done: 4
        case .orphanScanning: 5
        case .orphanResults: 6
        case .largeFileScanning: 7
        case .largeFileResults: 8
        case .cacheScanning: 9
        case .cacheResults: 10
        case .duplicateScanning: 11
        case .duplicateResults: 12
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .idle:
            HomeView(model: model, permissions: permissions) {
                permissions.refresh()
                scannerHealth.refresh()
                showPermissions = true
            }
        case .analyzing:
            AnalyzingView(app: model.droppedApp)
        case .results:
            ResultsView(model: model)
        case .cleaning:
            CleaningView()
        case .done(let report):
            DoneView(report: report) { model.reset() }
        case .orphanScanning:
            OrphanScanningView()
        case .orphanResults:
            OrphanResultsView(model: model)
        case .largeFileScanning:
            LargeFileScanningView(model: model)
        case .largeFileResults:
            LargeFileResultsView(model: model)
        case .cacheScanning:
            CacheScanningView(model: model)
        case .cacheResults:
            CacheResultsView(model: model)
        case .duplicateScanning:
            DuplicateScanningView(model: model)
        case .duplicateResults:
            DuplicateResultsView(model: model)
        }
    }

    private var backgroundLayer: some View {
        Rectangle()
            .fill(.regularMaterial)
            .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
