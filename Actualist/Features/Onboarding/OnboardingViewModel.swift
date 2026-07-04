import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    var backendMode: BackendMode = .restAPI
    var serverURLString = ""
    var apiKey = ""
    var actualPassword = ""
    var isConnecting = false

    func hydrate(from appState: AppState) {
        backendMode = appState.settings.backendMode
        serverURLString = backendMode == .localFirstSync
            ? appState.settings.localFirstServerURLString
            : appState.settings.serverURLString
        apiKey = appState.apiKey
    }

    func connect(using appState: AppState) async {
        isConnecting = true
        appState.lastErrorMessage = nil
        switch backendMode {
        case .restAPI:
            appState.saveConnection(serverURLString: serverURLString, apiKey: apiKey)
            await appState.loadBudgets()
        case .localFirstSync:
            await appState.saveLocalFirstConnection(serverURLString: serverURLString, password: actualPassword)
        }
        isConnecting = false
    }

    var canConnect: Bool {
        switch backendMode {
        case .restAPI:
            !serverURLString.isEmpty && !apiKey.isEmpty && !isConnecting
        case .localFirstSync:
            !serverURLString.isEmpty && !actualPassword.isEmpty && !isConnecting
        }
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
