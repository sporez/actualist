import Foundation
import Observation

@MainActor
@Observable
final class SettingsViewModel {
    var serverURLString = ""
    var apiKey = ""
    var isTesting = false
    var isLoadingBudgets = false

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

    func loadBudgetsForSelection(using appState: AppState) async {
        guard !isLoadingBudgets else {
            return
        }

        isLoadingBudgets = true
        appState.lastErrorMessage = nil
        await appState.loadBudgets()
        isLoadingBudgets = false
    }
}
