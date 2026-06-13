import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    var serverURLString = ""
    var apiKey = ""
    var isConnecting = false

    func hydrate(from appState: AppState) {
        serverURLString = appState.settings.serverURLString
        apiKey = appState.apiKey
    }

    func connect(using appState: AppState) async {
        isConnecting = true
        appState.lastErrorMessage = nil
        appState.saveConnection(serverURLString: serverURLString, apiKey: apiKey)
        await appState.loadBudgets()
        isConnecting = false
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
