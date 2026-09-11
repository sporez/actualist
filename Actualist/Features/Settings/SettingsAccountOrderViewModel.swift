import SwiftUI
import Observation

@MainActor
@Observable
final class SettingsAccountOrderViewModel {
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var generation = 0

    func accounts(using appState: AppState) -> [ActualAccount] {
        guard let budgetID = appState.settings.selectedBudgetID else { return [] }
        return appState.orderedAccounts(
            appState.accountRepository.accountDisplays(budgetID: budgetID).map(\.account),
            budgetID: budgetID
        )
    }

    func hasCustomOrder(using appState: AppState) -> Bool {
        appState.settings.selectedBudgetID.map { appState.settings.accountOrderByBudgetID[$0] != nil } ?? false
    }

    func load(using appState: AppState) async {
        await load(budgetID: appState.settings.selectedBudgetID, repository: appState.accountRepository)
    }

    func load(budgetID: String?, repository: any AccountRepositoryProtocol) async {
        generation += 1
        let request = generation
        errorMessage = nil
        guard let budgetID else { isLoading = false; return }
        isLoading = repository.accountDisplays(budgetID: budgetID).isEmpty
        defer { if generation == request { isLoading = false } }
        do {
            try await repository.refreshAccountsWithBalances(budgetID: budgetID)
        } catch {
            guard generation == request, let message = error.userFacingMessage else { return }
            errorMessage = repository.accountDisplays(budgetID: budgetID).isEmpty
                ? message : "Could not refresh accounts. Showing cached accounts."
        }
    }

    func refresh(using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        _ = await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
        await load(using: appState)
    }

    func move(from source: IndexSet, to destination: Int, using appState: AppState) {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        var ordered = accounts(using: appState)
        ordered.move(fromOffsets: source, toOffset: destination)
        appState.updateAccountOrder(ordered.map(\.id), budgetID: budgetID)
    }

    func reset(using appState: AppState) {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        appState.resetAccountOrder(budgetID: budgetID)
    }
}
