import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class SettingsViewModel {
    var serverURLString = ""
    var apiKey = ""
    var isTesting = false
    var isLoadingBudgets = false
    var selectedAppIcon: AppIcon = .default
    var appIconError: String?

    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    func hydrate(from appState: AppState) {
        serverURLString = appState.settings.serverURLString
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
