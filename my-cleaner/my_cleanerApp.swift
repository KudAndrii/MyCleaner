//
//  my_cleanerApp.swift
//  my-cleaner
//

import SwiftUI

@main
struct my_cleanerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 860, height: 620)
    }
}
