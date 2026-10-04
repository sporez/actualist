import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class SettingsViewModel {
    private var hasHydratedConnection = false
    var serverURLString = ""
    var fallbackServerURLString = ""
    var fallbackServerURLError: String?
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
        fallbackServerURLError = nil
        selectedAppIcon = AppIcon.current()
    }

    func hydrateConnectionIfNeeded(from appState: AppState) {
        guard !hasHydratedConnection else { return }
        hydrate(from: appState)
        hasHydratedConnection = true
    }

    private struct HeadersSummaryKey: Equatable {
        let revision: Int
        let serverURLString: String
        let fallbackServerURLString: String
    }

    /// Keychain is read only when the revision or either URL changes, not on
    /// every view-body evaluation. An unreadable Keychain is never cached, so a
    /// locked device does not stick on "Unavailable".
    @ObservationIgnored private var headersSummaryCache: (key: HeadersSummaryKey, value: String)?

    func customHeadersSummary(using store: LocalFirstActualStore) -> String {
        let key = HeadersSummaryKey(
            revision: store.customHeadersRevision,
            serverURLString: serverURLString,
            fallbackServerURLString: fallbackServerURLString
        )
        if let cached = headersSummaryCache, cached.key == key { return cached.value }
        guard let configuration = try? store.keychain.readCustomHTTPHeaders() else { return "Unavailable" }
        let urls = [serverURLString, fallbackServerURLString]
        let count = zip(ActualServerEndpointRole.allCases, urls).reduce(0) { count, pair in
            guard let url = URL(string: ActualServerURLNormalizer.normalize(pair.1)),
                  let endpoint = configuration[pair.0], endpoint.applies(to: url) else { return count }
            return count + endpoint.headers.count
        }
        let summary = "\(count) Configured"
        headersSummaryCache = (key, summary)
        return summary
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
            appIconError = error.userFacingMessage
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
        fallbackServerURLError = appState.updateFallbackServerURL(fallbackServerURLString)
    }

    /// Reloads the budget list and reports whether discovery completed
    /// successfully. A thrown error — including cancellation — is `false`:
    /// callers must never treat it as a discovered empty server.
    @discardableResult
    func loadBudgetsForSelection(using appState: AppState) async -> Bool {
        guard !isLoadingBudgets else {
            return false
        }

        isLoadingBudgets = true
        appState.lastErrorMessage = nil
        let succeeded: Bool
        do {
            try await appState.loadBudgets()
            succeeded = true
        } catch {
            appState.lastErrorMessage = error.userFacingMessage
            succeeded = false
        }
        isLoadingBudgets = false
        return succeeded
    }

    func copyDiagnosticReport(using appState: AppState) {
        UIPasteboard.general.string = ActualistDiagnosticReportBuilder.make(appState: appState).text
    }

    var canSaveConnection: Bool {
        ConnectionInputValidation.canConnect(
            serverURL: serverURLString, password: actualPassword, isBusy: isTesting
        )
    }

    var connectionSecurityWarning: String? {
        ActualServerConnectionSecurity.warningMessage(for: serverURLString)
    }
}
