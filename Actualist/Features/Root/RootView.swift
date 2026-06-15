import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
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
        .actualistScreenBackground()
        .environment(\.actualistDensity, appState.settings.displayDensity)
    }
}
