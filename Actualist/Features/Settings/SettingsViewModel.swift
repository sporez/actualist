import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class SettingsViewModel {
    private var hasHydratedConnection = false
    var serverURLString = ""
    var fallbackServerURLString = ""
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
        fallbackServerURLString = appState.settings.fallbackServerURLString
        selectedAppIcon = AppIcon.current()
    }

    func hydrateConnectionIfNeeded(from appState: AppState) {
        guard !hasHydratedConnection else { return }
        hydrate(from: appState)
        hasHydratedConnection = true
    }

    func customHeadersSummary(using store: LocalFirstActualStore) -> String {
        _ = store.customHeadersRevision
        guard let configuration = try? store.keychain.readCustomHTTPHeaders() else { return "Unavailable" }
        let urls = [serverURLString, fallbackServerURLString]
        let count = zip(ActualServerEndpointRole.allCases, urls).reduce(0) { count, pair in
            guard let url = URL(string: ActualServerURLNormalizer.normalize(pair.1)),
                  let endpoint = configuration[pair.0], endpoint.applies(to: url) else { return count }
            return count + endpoint.headers.count
        }
        return "\(count) Configured"
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

    func commitFallbackServerURL(using appState: AppState) {
        appState.updateFallbackServerURL(fallbackServerURLString)
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
