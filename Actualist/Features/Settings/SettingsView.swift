import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = SettingsViewModel()
    @State private var isBudgetPickerPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    TextField("Server URL", text: $viewModel.serverURLString, prompt: Text("http://host:5007"))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    Text("Actualist adds /v1 when no path is provided.")
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.secondaryText)

                    SecureField("API Key", text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)

                    Button {
                        Task { await viewModel.saveAndTest(using: appState) }
                    } label: {
                        SettingsActionLabel(
                            title: viewModel.isTesting ? "Testing" : "Save and Test",
                            systemImage: "network"
                        )
                    }
                }
                .settingsSectionChrome()

                Section("Budget") {
                    LabeledContent("Selected") {
                        Text(appState.settings.selectedBudgetName ?? "None")
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }

                    Button {
                        isBudgetPickerPresented = true
                    } label: {
                        SettingsActionLabel(title: "Change Budget", systemImage: "folder")
                    }
                }
                .settingsSectionChrome()

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
                }
                .settingsSectionChrome()
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("Settings")
            .onAppear {
                viewModel.hydrate(from: appState)
            }
            .sheet(isPresented: $isBudgetPickerPresented) {
                SettingsBudgetPickerSheet(
                    viewModel: viewModel,
                    isPresented: $isBudgetPickerPresented
                )
                .environment(appState)
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

private struct SettingsActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(ActualistTheme.primaryText)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(ActualistTheme.accent)
        }
    }
}

private struct SettingsBudgetPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: SettingsViewModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isLoadingBudgets {
                    ProgressView("Loading budgets")
                        .settingsRowChrome()
                }

                if let message = appState.lastErrorMessage {
                    Text(message)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.danger)
                        .settingsRowChrome()
                }

                Section("Choose Budget") {
                    ForEach(appState.budgets) { budget in
                        Button {
                            appState.selectBudget(budget)
                            isPresented = false
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(budget.name)
                                        .font(ActualistTypography.rowTitle(for: density))
                                        .foregroundStyle(ActualistTheme.primaryText)
                                    Text(budget.syncID)
                                        .font(ActualistTypography.rowLabel(for: density))
                                        .foregroundStyle(ActualistTheme.secondaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                if appState.settings.selectedBudgetID == budget.syncID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(ActualistTheme.accent)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(ActualistTheme.secondaryText)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .settingsSectionChrome()
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("Budgets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.loadBudgetsForSelection(using: appState) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .actualistToolbarGlassButton()
                    .disabled(viewModel.isLoadingBudgets)
                }
            }
            .task {
                await viewModel.loadBudgetsForSelection(using: appState)
            }
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
            ThemeSwatch(color: palette.neutral)
        }
        .padding(.vertical, 4)
    }
}

private extension View {
    func settingsSectionChrome() -> some View {
        self
            .listRowBackground(ActualistTheme.surface)
            .listRowSeparatorTint(ActualistTheme.separator)
    }

    func settingsRowChrome() -> some View {
        self
            .listRowBackground(ActualistTheme.surface)
            .listRowSeparatorTint(ActualistTheme.separator)
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
