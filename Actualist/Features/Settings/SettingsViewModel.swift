import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    var serverURLString = ""
    var apiKey = ""
    var isTesting = false

    func hydrate(from appState: AppState) {
        serverURLString = appState.settings.serverURLString
        apiKey = appState.apiKey
    }

    func saveAndTest(using appState: AppState) async {
        isTesting = true
        appState.lastErrorMessage = nil
        appState.saveConnection(serverURLString: serverURLString, apiKey: apiKey)
        await appState.loadBudgets()
        isTesting = false
    }

    func changeBudget(using appState: AppState) async {
        appState.clearSelectionForBudgetChange()
        await appState.loadBudgets()
    }
}
