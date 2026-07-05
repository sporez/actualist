import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    var serverURLString = ""
    var actualPassword = ""
    var isConnecting = false

    func hydrate(from appState: AppState) {
        serverURLString = appState.settings.localFirstServerURLString
    }

    func connect(using appState: AppState) async {
        isConnecting = true
        appState.lastErrorMessage = nil
        await appState.saveLocalFirstConnection(serverURLString: serverURLString, password: actualPassword)
        isConnecting = false
    }

    var canConnect: Bool {
        !serverURLString.isEmpty && !actualPassword.isEmpty && !isConnecting
    }
}

@MainActor
@Observable
final class BudgetPickerViewModel {
    var isLoading = false

    func reload(using appState: AppState) async {
        isLoading = true
        await appState.loadBudgets()
        isLoading = false
    }
}
