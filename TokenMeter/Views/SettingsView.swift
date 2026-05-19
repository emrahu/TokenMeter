import SwiftUI

struct SettingsView: View {
    var viewModel: DashboardViewModel?
    var onSave: (() -> Void)?

    var body: some View {
        TabView {
            Tab("Providers", systemImage: "key") {
                providersTab
            }

            Tab("General", systemImage: "gear") {
                generalTab
            }
        }
        .frame(width: 440, height: 420)
    }

    // MARK: - Providers Tab

    private var providersTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(ProviderType.allCases) { provider in
                    ProviderKeySection(provider: provider, onSave: onSave)
                }
            }
            .padding()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let viewModel {
                    autoRefreshSection(viewModel)
                    budgetSection(viewModel)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func autoRefreshSection(_ vm: DashboardViewModel) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Auto-refresh", isOn: Bindable(vm).autoRefreshEnabled)

                if vm.autoRefreshEnabled {
                    HStack {
                        Text("Interval")
                            .font(.caption)
                        Spacer()
                        Picker("", selection: Bindable(vm).autoRefreshInterval) {
                            Text("1 min").tag(60.0)
                            Text("5 min").tag(300.0)
                            Text("15 min").tag(900.0)
                            Text("30 min").tag(1800.0)
                            Text("1 hour").tag(3600.0)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }
                }
            }
        } label: {
            Label("Auto-Refresh", systemImage: "arrow.clockwise")
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }

    @ViewBuilder
    private func budgetSection(_ vm: DashboardViewModel) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Budget notifications", isOn: Bindable(vm).budgetNotificationsEnabled)

                if vm.budgetNotificationsEnabled {
                    Text("Get notified at 80% and 100% of your budget.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Daily budget")
                            .font(.caption)
                        Spacer()
                        HStack(spacing: 2) {
                            Text("$")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("0.00", value: Bindable(vm).dailyBudget, format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }

                    HStack {
                        Text("Monthly budget")
                            .font(.caption)
                        Spacer()
                        HStack(spacing: 2) {
                            Text("$")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("0.00", value: Bindable(vm).monthlyBudget, format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }
        } label: {
            Label("Budget Alerts", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Provider Key Section

struct ProviderKeySection: View {
    let provider: ProviderType
    var onSave: (() -> Void)?

    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(provider.logoName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                Text(provider.rawValue)
            }
                .font(.subheadline)
                .fontWeight(.medium)

            HStack {
                Group {
                    if showKey {
                        TextField(provider.keyPlaceholder, text: $apiKey)
                    } else {
                        SecureField(provider.keyPlaceholder, text: $apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            Text(provider.keyHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save") {
                    do {
                        try KeychainService.save(key: provider.keychainKey, value: apiKey)
                        saved = true
                        onSave?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            saved = false
                        }
                    } catch {
                        // Save failed
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty)

                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                Spacer()

                Button("Clear") {
                    KeychainService.delete(key: provider.keychainKey)
                    apiKey = ""
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            apiKey = KeychainService.load(key: provider.keychainKey) ?? ""
        }
    }
}
