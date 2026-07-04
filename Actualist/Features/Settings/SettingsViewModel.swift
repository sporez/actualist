import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class SettingsViewModel {
    var backendMode: BackendMode = .restAPI
    var serverURLString = ""
    var apiKey = ""
    var actualPassword = ""
    var isTesting = false
    var isLoadingBudgets = false
    var selectedAppIcon: AppIcon = .default
    var appIconError: String?

    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    func hydrate(from appState: AppState) {
        backendMode = appState.settings.backendMode
        serverURLString = backendMode == .localFirstSync
            ? appState.settings.localFirstServerURLString
            : appState.settings.serverURLString
        apiKey = appState.apiKey
        selectedAppIcon = AppIcon.current()
    }

    func setAppIcon(_ icon: AppIcon) async {
        guard icon != selectedAppIcon else {
            return
        }

        let previous = selectedAppIcon
        selectedAppIcon = icon
        appIconError = nil
        do {
            try await UIApplication.shared.setAlternateIconName(icon.alternateIconName)
        } catch {
            selectedAppIcon = previous
            appIconError = error.localizedDescription
        }
    }

    func saveAndTest(using appState: AppState) async {
        isTesting = true
        appState.lastErrorMessage = nil
        switch backendMode {
        case .restAPI:
            appState.saveConnection(serverURLString: serverURLString, apiKey: apiKey)
            await appState.loadBudgets()
        case .localFirstSync:
            await appState.saveLocalFirstConnection(serverURLString: serverURLString, password: actualPassword)
        }
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
