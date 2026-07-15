import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let theme = ActualistTheme.palette(for: appState.settings.theme)

        Group {
            switch appState.setupPhase {
            case .needsConnection:
                OnboardingView()
            case .selectingBudget:
                BudgetPickerView()
            case .ready:
                MainTabView()
            }
        }
        .id("\(appState.settings.theme.rawValue)-\(appState.themeRevision)")
        .background(theme.background.ignoresSafeArea())
        .tint(theme.chromeForeground)
        .environment(\.actualistDensity, appState.settings.displayDensity)
    }
}
