import SwiftUI

/// Appearance settings: theme, layout/display size, app icon, amount colors,
/// and Budget screen banner options.
struct AppearanceSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var viewModel = SettingsViewModel()
    @State private var isAppIconPickerPresented = false

    var body: some View {
        List {
            Section("Theme") {
                Picker("Theme", selection: themeSelection) {
                    ForEach(ActualistThemeOption.allCases) { option in
                        Text(option.title)
                            .tag(option)
                    }
                }
                .pickerStyle(.menu)

                ThemePreviewStrip(theme: appState.settings.theme)
            }
            .settingsSectionChrome()

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Display Size") {
                        Text(appState.settings.displayDensity.title)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }

                    Slider(value: displayDensityValue, in: 0...3, step: 1)

                    HStack {
                        ForEach(ActualistDisplayDensity.allCases) { density in
                            Text(density.title)
                                .font(.caption2.weight(density == appState.settings.displayDensity ? .bold : .medium))
                                .foregroundStyle(
                                    density == appState.settings.displayDensity
                                        ? ActualistTheme.primaryText
                                        : ActualistTheme.secondaryText
                                )

                            if density != ActualistDisplayDensity.allCases.last {
                                Spacer(minLength: 8)
                            }
                        }
                    }
                }
            } header: {
                Text("Layout")
            } footer: {
                Text("Controls row density and amount sizes across the app.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()

            Section("App Icon") {
                Button {
                    isAppIconPickerPresented = true
                } label: {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(viewModel.selectedAppIcon.title)
                                .foregroundStyle(ActualistTheme.secondaryText)
                            AppIconThumbnail(icon: viewModel.selectedAppIcon, size: 28)
                        }
                    } label: {
                        Text("App Icon")
                            .foregroundStyle(ActualistTheme.primaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.supportsAlternateIcons)
            }
            .settingsSectionChrome()

            Section {
                Toggle("Green Income Amounts", isOn: greenIncomeTransactionAmountsSelection)
            } header: {
                Text("Amounts")
            } footer: {
                Text("Show positive transaction amounts in green.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()

            Section {
                Toggle(
                    "Include Rollover in Alerts",
                    isOn: includeCarryoverCategoriesInOverspentAlertsSelection
                )
                Toggle("Show Total Assigned", isOn: showTotalAssignedSelection)
            } header: {
                Text("Budget Options")
            } footer: {
                Text("Controls additional information shown on the Budget screen.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.hydrate(from: appState)
        }
        .sheet(isPresented: $isAppIconPickerPresented) {
            AppIconPickerSheet(viewModel: viewModel)
                .environment(appState)
                .presentationDetents([.height(320)])
                .appSwitcherPrivacyAwareDragIndicator()
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

    private var greenIncomeTransactionAmountsSelection: Binding<Bool> {
        Binding {
            appState.settings.greenIncomeTransactionAmountsEnabled
        } set: { isEnabled in
            appState.updateGreenIncomeTransactionAmountsEnabled(isEnabled)
        }
    }

    private var includeCarryoverCategoriesInOverspentAlertsSelection: Binding<Bool> {
        Binding {
            appState.settings.includeCarryoverCategoriesInOverspentAlerts
        } set: { isEnabled in
            appState.updateIncludeCarryoverCategoriesInOverspentAlerts(isEnabled)
        }
    }

    private var showTotalAssignedSelection: Binding<Bool> {
        Binding {
            appState.settings.showTotalAssigned
        } set: { isEnabled in
            appState.updateShowTotalAssigned(isEnabled)
        }
    }
}
