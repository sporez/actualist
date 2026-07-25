import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class SettingsViewModel {
    var serverURLString = ""
    var actualPassword = ""
    var isTesting = false
    var isLoadingBudgets = false
    var selectedAppIcon: AppIcon = .default
    var appIconError: String?

    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    func hydrate(from appState: AppState) {
        serverURLString = appState.settings.localFirstServerURLString
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
        let succeeded = await appState.saveLocalFirstConnection(serverURLString: serverURLString, password: actualPassword)
        if succeeded {
            actualPassword = ""
        }
        isTesting = false
    }

    func loadBudgetsForSelection(using appState: AppState) async {
        guard !isLoadingBudgets else {
            return
        }

        isLoadingBudgets = true
        appState.lastErrorMessage = nil
        do {
            try await appState.loadBudgets()
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
        isLoadingBudgets = false
    }

    func copyDiagnosticReport(using appState: AppState) {
        UIPasteboard.general.string = ActualistDiagnosticReportBuilder.make(appState: appState).text
    }

    var connectionSecurityWarning: String? {
        ActualServerConnectionSecurity.warningMessage(for: serverURLString)
    }
}
