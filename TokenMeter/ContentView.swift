import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.hasAnyProvider {
                DashboardView(viewModel: viewModel)
            } else {
                unconfiguredView
            }

            Divider()

            bottomBar
        }
    }

    private var unconfiguredView: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.medium")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("TokenMeter")
                .font(.headline)

            Text("Add an API key to start\ntracking your AI token usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Open Settings") {
                openWindow(id: "settings")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(24)
        .frame(width: 380, height: 220)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                openWindow(id: "settings")
            } label: {
                Image(systemName: "gear")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
