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
        .overlay(alignment: .topLeading) {
            if appState.setupPhase == .ready {
                ConnectionStatusDot(status: appState.connectionStatus)
                    .padding(.top, 8)
                    .padding(.leading, 12)
            }
        }
        .tint(.white)
        .environment(\.actualistDensity, appState.settings.displayDensity)
    }
}

private struct ConnectionStatusDot: View {
    let status: ServerConnectionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.55), lineWidth: 1)
            }
            .shadow(color: color.opacity(0.55), radius: 5)
            .accessibilityLabel(accessibilityLabel)
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

    private var accessibilityLabel: String {
        switch status {
        case .online:
            "Server connected"
        case .connecting:
            "Server connecting"
        case .offline:
            "Server offline, read only"
        }
    }
}
