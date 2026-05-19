//
//  TokenMeterApp.swift
//  TokenMeter
//
//  Created by Emrah Usar on 3/26/26.
//

import SwiftUI

@main
struct TokenMeterApp: App {
    @State private var viewModel = DashboardViewModel()

    var body: some Scene {
        MenuBarExtra("TokenMeter", image: "MenuBarIcon") {
            ContentView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView(viewModel: viewModel) {
                Task { await viewModel.refresh() }
            }
        }
        .windowResizability(.contentSize)
    }
}
