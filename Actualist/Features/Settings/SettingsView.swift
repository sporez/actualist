import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    TextField("Server URL", text: $viewModel.serverURLString, prompt: Text("http://host:5007"))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    Text("Actualist adds /v1 when no path is provided.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    SecureField("API Key", text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)

                    Button {
                        Task { await viewModel.saveAndTest(using: appState) }
                    } label: {
                        Label(viewModel.isTesting ? "Testing" : "Save and Test", systemImage: "network")
                    }
                }

                Section("Budget") {
                    LabeledContent("Selected") {
                        Text(appState.settings.selectedBudgetName ?? "None")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await viewModel.changeBudget(using: appState) }
                    } label: {
                        Label("Change Budget", systemImage: "folder")
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: themeSelection) {
                        ForEach(ActualistThemeOption.allCases) { option in
                            Text(option.title)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.menu)

                    ThemePreviewStrip(theme: appState.settings.theme)

                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Display Size") {
                            Text(appState.settings.displayDensity.title)
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: displayDensityValue, in: 0...3, step: 1)

                        HStack {
                            ForEach(ActualistDisplayDensity.allCases) { density in
                                Text(density.title)
                                    .font(.caption2.weight(density == appState.settings.displayDensity ? .bold : .medium))
                                    .foregroundStyle(density == appState.settings.displayDensity ? ActualistTheme.primaryText : .secondary)

                                if density != ActualistDisplayDensity.allCases.last {
                                    Spacer(minLength: 8)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle("Settings")
            .onAppear {
                viewModel.hydrate(from: appState)
            }
        }
    }

    private var displayDensityValue: Binding<Double> {
        Binding {
            appState.settings.displayDensity.sliderValue
        } set: { value in
            appState.updateDisplayDensity(ActualistDisplayDensity(sliderValue: value))
        }
    }

    private var themeSelection: Binding<ActualistThemeOption> {
        Binding {
            appState.settings.theme
        } set: { theme in
            appState.updateTheme(theme)
        }
    }
}

private struct ThemePreviewStrip: View {
    let theme: ActualistThemeOption

    var body: some View {
        let palette = ActualistTheme.palette(for: theme)

        HStack(spacing: 8) {
            ThemeSwatch(color: palette.background)
            ThemeSwatch(color: palette.surface)
            ThemeSwatch(color: palette.elevatedSurface)
            ThemeSwatch(color: palette.accent)
            ThemeSwatch(color: palette.positive)
            ThemeSwatch(color: palette.warning)
            ThemeSwatch(color: palette.danger)
        }
        .padding(.vertical, 4)
    }
}

private struct ThemeSwatch: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
    }
}
