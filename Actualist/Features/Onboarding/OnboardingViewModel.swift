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
    var isEnteringDemo = false

    func hydrate(from appState: AppState) {
        serverURLString = appState.settings.localFirstServerURLString
    }

    func serverURLDidChange() {
        loginMethods = []
        hasLoadedLoginMethods = false
        isUsingPassword = false
        actualPassword = ""
    }

    func continueFromServer(
        using appState: AppState,
        browserSession: @escaping ActualOpenIDBrowserSession
    ) async {
        await loadLoginMethods(using: appState)
        guard hasLoadedLoginMethods, supportsOpenID, !supportsPassword else {
            return
        }
        await connectWithOpenID(using: appState, browserSession: browserSession)
    }

    /// Enter demo mode with sample data. No server traffic is involved; the
    /// store seeds a local-only budget so the user can explore the app.
    func enterDemo(using appState: AppState) async {
        isEnteringDemo = true
        appState.lastErrorMessage = nil
        await appState.enterDemoMode()
        isEnteringDemo = false
    }

    private func loadLoginMethods(using appState: AppState) async {
        isLoadingLoginMethods = true
        appState.lastErrorMessage = nil
        if let response = await appState.loadLocalFirstLoginMethods(
            serverURLString: serverURLString
        ) {
            loginMethods = response.availableLoginMethods
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
            && !isEnteringDemo
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

    var showsOpenIDAction: Bool {
        hasLoadedLoginMethods && supportsOpenID && !isUsingPassword
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

    func showsLocalNetworkSettingsAction(for errorMessage: String?) -> Bool {
        errorMessage == ActualAPIError.localNetworkDenied.localizedDescription
    }
}

/// State machine for the budget-open workflow surfaced by `BudgetPickerView`.
///
/// Kept as an explicit enum (rather than loose flags) because a budget open is a
/// multi-step flow (download -> decrypt -> import -> sync) whose in-flight,
/// encryption-prompt, and failure outcomes must stay coherent.
enum BudgetPickerOpenState: Equatable {
    case idle
    case opening(budgetID: String)
    case needsEncryptionPassword(ActualBudget)
    case failed(message: String)
}

@MainActor
@Observable
final class BudgetPickerViewModel {
    var isLoading = false
    var openState: BudgetPickerOpenState = .idle

    /// Hard ceiling for a single budget-open attempt. The Actual download path
    /// uses a 30s per-request timeout, but a black-holed cellular connection can
    /// hold an idle socket well past that with no data flow. Without this ceiling
    /// a stalled open leaves the picker at "connecting" indefinitely, which reads
    /// as a dead tap to the user.
    private let openTimeout: Duration = .seconds(60)

    private var openTask: Task<Void, Never>?
    private var openGeneration = 0

    var openingBudgetID: String? {
        if case .opening(let budgetID) = openState { return budgetID }
        return nil
    }

    var hasInFlightOpen: Bool {
        openingBudgetID != nil
    }

    func reload(using appState: AppState) async {
        isLoading = true
        do {
            try await appState.loadBudgets()
            if case .failed = openState {
                openState = .idle
            }
        } catch {
            appState.lastErrorMessage = error.localizedDescription
            openState = .failed(message: error.localizedDescription)
        }
        isLoading = false
    }

    func selectBudget(_ budget: ActualBudget, using appState: AppState) {
        startOpen(budget, password: nil, using: appState)
    }

    func unlockBudget(_ budget: ActualBudget, password: String, using appState: AppState) {
        startOpen(budget, password: password, using: appState)
    }

    /// Called when the encrypted-budget sheet is dismissed without unlocking.
    func dismissEncryptionPrompt() {
        if case .needsEncryptionPassword = openState {
            openState = .idle
        }
    }

    /// Called when the user starts a fresh open after seeing a failure banner.
    func clearFailure() {
        if case .failed = openState {
            openState = .idle
        }
    }

    private func startOpen(_ budget: ActualBudget, password: String?, using appState: AppState) {
        openTask?.cancel()
        openGeneration += 1
        let generation = openGeneration
        openState = .opening(budgetID: budget.syncID)
        appState.lastErrorMessage = nil

        openTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runOpen(budget, password: password, using: appState, generation: generation)
        }
    }

    private func runOpen(
        _ budget: ActualBudget,
        password: String?,
        using appState: AppState,
        generation: Int
    ) async {
        // The open runs on AppState/store; race it against a timeout so a
        // stalled network cannot pin the picker forever. Cancelling `work`
        // propagates to the URLSession bytes iterator, aborting the download.
        let work = Task { @MainActor in
            await appState.selectBudgetForCurrentBackend(budget, encryptionPassword: password)
        }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: openTimeout)
            work.cancel()
        }
        await work.value
        timer.cancel()

        // A newer open (or dismissal) should own the screen state; bail before
        // overwriting it with a stale result.
        guard generation == openGeneration, !Task.isCancelled else { return }

        let encryptedMessage = LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription
        if work.isCancelled {
            let message = "Opening this budget is taking too long. Check your connection to the Actual server and try again."
            appState.lastErrorMessage = message
            openState = .failed(message: message)
        } else if appState.lastErrorMessage == encryptedMessage {
            openState = .needsEncryptionPassword(budget)
        } else if let message = appState.lastErrorMessage {
            openState = .failed(message: message)
        } else {
            // Success: AppState moves to .ready and RootView swaps in MainTabView.
            openState = .idle
        }
    }
}
