import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = SettingsViewModel()
    @State private var isBudgetPickerPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Server") {
                        TextField("Required", text: $viewModel.serverURLString, prompt: Text("http://host:5007"))
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("API Key") {
                        SecureField("Required", text: $viewModel.apiKey)
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                    }

                    SettingsStatusRow(status: appState.connectionStatus)

                    if let message = appState.lastErrorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.danger)
                    }

                    Button {
                        Task { await viewModel.saveAndTest(using: appState) }
                    } label: {
                        SettingsActionLabel(
                            title: viewModel.isTesting ? "Checking" : "Save Connection",
                            systemImage: "network"
                        )
                    }
                    .disabled(!canSaveConnection)
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

                Section("Background Refresh") {
                    Toggle("New Transaction Alerts", isOn: backgroundRefreshSelection)

                    BackgroundRefreshDebugRows(debug: appState.settings.backgroundRefreshDebug)
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

    private var canSaveConnection: Bool {
        !viewModel.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isTesting
    }

    private var backgroundRefreshSelection: Binding<Bool> {
        Binding {
            appState.settings.backgroundTransactionRefreshEnabled
        } set: { isEnabled in
            Task {
                await appState.updateBackgroundTransactionRefreshEnabled(isEnabled)
            }
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

private struct SettingsStatusRow: View {
    let status: ServerConnectionStatus

    var body: some View {
        LabeledContent("Status") {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.45), radius: 4)

                Text(title)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
    }

    private var title: String {
        switch status {
        case .online:
            "Connected"
        case .connecting:
            "Checking"
        case .offline:
            "Offline"
        }
    }

    private var color: Color {
        switch status {
        case .online:
            ActualistTheme.positive
        case .connecting:
            ActualistTheme.warning
        case .offline:
            ActualistTheme.danger
        }
    }
}

private struct BackgroundRefreshDebugRows: View {
    let debug: BackgroundRefreshDebugInfo

    var body: some View {
        LabeledContent("Schedule Count") {
            Text(debug.scheduleAttemptCount.formatted())
                .foregroundStyle(ActualistTheme.secondaryText)
        }

        if debug.recentScheduleAttempts.isEmpty {
            Text("No schedule attempts yet")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            ForEach(debug.recentScheduleAttempts.prefix(5)) { attempt in
                BackgroundRefreshScheduleAttemptRow(attempt: attempt)
            }
        }

        LabeledContent("Wake Count") {
            Text(debug.wakeCount.formatted())
                .foregroundStyle(ActualistTheme.secondaryText)
        }

        if debug.recentRuns.isEmpty {
            Text("No background wakes yet")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            ForEach(debug.recentRuns.prefix(20)) { run in
                BackgroundRefreshDebugRunRow(run: run)
            }
        }
    }
}

private struct BackgroundRefreshScheduleAttemptRow: View {
    let attempt: BackgroundRefreshScheduleAttempt

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(formattedDate(attempt.date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer(minLength: 8)

                Text(attempt.succeeded ? "Accepted" : "Rejected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(attempt.succeeded ? ActualistTheme.positive : ActualistTheme.danger)
            }

            if let earliestBeginDate = attempt.earliestBeginDate {
                Text("Earliest \(formattedDate(earliestBeginDate))")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }

            Text(attempt.message)
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else {
            return "Not yet"
        }

        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }
}

private struct BackgroundRefreshDebugRunRow: View {
    let run: BackgroundRefreshDebugRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(formattedDate(run.wakeDate))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer(minLength: 8)

                Text(resultText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(resultColor)
            }

            if let completionDate = run.completionDate {
                Text("Finished \(formattedDate(completionDate))")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }

            Text(run.message)
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .lineLimit(4)
        }
        .padding(.vertical, 2)
    }

    private var resultText: String {
        guard let succeeded = run.succeeded else {
            return "Started"
        }

        return succeeded ? "Succeeded" : "Failed"
    }

    private var resultColor: Color {
        switch run.succeeded {
        case true:
            ActualistTheme.positive
        case false:
            ActualistTheme.danger
        case nil:
            ActualistTheme.secondaryText
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else {
            return "Not yet"
        }

        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
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
                    .font(.body.weight(.semibold))
                    .controlSize(.small)
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
