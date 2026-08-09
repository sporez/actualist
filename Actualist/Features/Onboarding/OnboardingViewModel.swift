import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    var serverURLString = ""
    var actualPassword = ""
    var loginMethods: [ActualLoginMethod] = []
    var hasLoadedLoginMethods = false
    var isLoadingLoginMethods = false
    var isConnecting = false
    var isUsingPassword = false

    func hydrate(from appState: AppState) {
        serverURLString = appState.settings.localFirstServerURLString
    }

    func serverURLDidChange() {
        loginMethods = []
        hasLoadedLoginMethods = false
        isUsingPassword = false
        actualPassword = ""
    }

    func loadLoginMethods(using appState: AppState) async {
        isLoadingLoginMethods = true
        appState.lastErrorMessage = nil
        if let response = await appState.loadLocalFirstLoginMethods(
            serverURLString: serverURLString
        ) {
            loginMethods = response.activeLoginMethods
            hasLoadedLoginMethods = true
            isUsingPassword = supportsPassword && !supportsOpenID
        }
        isLoadingLoginMethods = false
    }

    func connectWithPassword(using appState: AppState) async {
        isConnecting = true
        appState.lastErrorMessage = nil
        let succeeded = await appState.saveLocalFirstConnection(serverURLString: serverURLString, password: actualPassword)
        if succeeded {
            actualPassword = ""
        }
        isConnecting = false
    }

    func connectWithOpenID(
        using appState: AppState,
        browserSession: @escaping ActualOpenIDBrowserSession
    ) async {
        isConnecting = true
        appState.lastErrorMessage = nil
        _ = await appState.saveLocalFirstOpenIDConnection(
            serverURLString: serverURLString,
            browserSession: browserSession
        )
        isConnecting = false
    }

    var canLoadLoginMethods: Bool {
        !serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoadingLoginMethods
            && !isConnecting
    }

    var canConnectWithPassword: Bool {
        !serverURLString.isEmpty && !actualPassword.isEmpty && !isConnecting
    }

    var supportsPassword: Bool {
        loginMethods.contains { $0.authenticationMethod == .password }
    }

    var supportsOpenID: Bool {
        loginMethods.contains { $0.authenticationMethod == .openID }
    }

    var showsPasswordForm: Bool {
        hasLoadedLoginMethods && supportsPassword && isUsingPassword
    }

    var unsupportedAuthenticationMessage: String? {
        guard hasLoadedLoginMethods, !supportsPassword, !supportsOpenID else {
            return nil
        }
        let identifiers = loginMethods.map(\.identifier)
        if identifiers.contains("header") {
            return "This server uses header authentication, which Actualist does not support yet."
        }
        if identifiers.isEmpty {
            return "This server did not advertise a supported authentication method."
        }
        return "This server uses an unsupported authentication method: \(identifiers.joined(separator: ", "))."
    }

    var connectionSecurityWarning: String? {
        ActualServerConnectionSecurity.warningMessage(for: serverURLString)
    }
}

@MainActor
@Observable
final class BudgetPickerViewModel {
    var isLoading = false

    func reload(using appState: AppState) async {
        isLoading = true
        do {
            try await appState.loadBudgets()
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
