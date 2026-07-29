import Foundation
import Observation

@MainActor
@Observable
final class PayeesViewModel {
    var snapshot: PayeeManagementSnapshot = .empty
    var searchText = ""
    var selectedPayeeIDs: Set<String> = []
    var isSelecting = false
    var isLoading = false
    var isSubmitting = false
    var errorMessage: String?

    var regularPayees: [ManagedPayee] {
        filtered(snapshot.payees.filter { !$0.isTransfer })
    }

    var transferPayees: [ManagedPayee] {
        filtered(snapshot.payees.filter(\.isTransfer))
    }

    var selectedPayees: [ManagedPayee] {
        snapshot.payees.filter { selectedPayeeIDs.contains($0.id) && !$0.isTransfer }
    }

    var canBeginMerge: Bool {
        snapshot.supportsMerge && selectedPayeeIDs.count >= 2 && !isSubmitting
    }

    func load(using appState: AppState) async {
        guard let context = context(using: appState) else {
            snapshot = .empty
            isLoading = false
            return
        }
        if let cached = context.repository.cachedPayeeManagementSnapshot(budgetID: context.budgetID) {
            snapshot = cached
        }
        isLoading = snapshot.payees.isEmpty
        errorMessage = nil
        do {
            try await context.repository.refreshPayeeManagementSnapshot(budgetID: context.budgetID)
            snapshot = context.repository.cachedPayeeManagementSnapshot(budgetID: context.budgetID) ?? snapshot
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func refresh(using appState: AppState) async {
        guard let context = context(using: appState) else {
            return
        }
        errorMessage = nil
        _ = await appState.refreshLocalFirstData(budgetID: context.budgetID)
        do {
            try await context.repository.refreshPayeeManagementSnapshot(budgetID: context.budgetID)
            snapshot = context.repository.cachedPayeeManagementSnapshot(budgetID: context.budgetID) ?? snapshot
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func create(name: String, using appState: AppState) async -> Bool {
        await mutate(using: appState) { repository, budgetID in
            try await repository.createPayeeAndRefresh(budgetID: budgetID, name: name)
        }
    }

    func rename(payeeID: String, name: String, using appState: AppState) async -> Bool {
        await mutate(using: appState) { repository, budgetID in
            try await repository.renamePayeeAndRefresh(
                budgetID: budgetID,
                payeeID: payeeID,
                name: name
            )
        }
    }

    func merge(into targetPayeeID: String, using appState: AppState) async -> Bool {
        let sources = selectedPayeeIDs.subtracting([targetPayeeID])
        guard !sources.isEmpty else {
            errorMessage = "Choose a different payee to merge."
            return false
        }
        let succeeded = await mutate(using: appState) { repository, budgetID in
            try await repository.mergePayeesAndRefresh(
                budgetID: budgetID,
                sourcePayeeIDs: sources,
                targetPayeeID: targetPayeeID
            )
        }
        if succeeded {
            endSelection()
        }
        return succeeded
    }

    func delete(payeeID: String, using appState: AppState) async -> Bool {
        await mutate(using: appState) { repository, budgetID in
            try await repository.deletePayeeAndRefresh(budgetID: budgetID, payeeID: payeeID)
        }
    }

    func toggleSelection(_ payeeID: String) {
        if selectedPayeeIDs.contains(payeeID) {
            selectedPayeeIDs.remove(payeeID)
        } else {
            selectedPayeeIDs.insert(payeeID)
        }
    }

    func beginSelection() {
        selectedPayeeIDs = []
        isSelecting = true
    }

    func endSelection() {
        selectedPayeeIDs = []
        isSelecting = false
    }

    private func mutate(
        using appState: AppState,
        operation: (any PayeeRepositoryProtocol, String) async throws -> Void
    ) async -> Bool {
        guard !appState.settings.randomizedDisplayValuesEnabled else {
            errorMessage = "Turn off randomized display data before changing payees."
            return false
        }
        guard appState.capabilities.canManagePayees, let context = context(using: appState) else {
            errorMessage = "Payee management is unavailable."
            return false
        }
        isSubmitting = true
        errorMessage = nil
        do {
            try await operation(context.repository, context.budgetID)
            snapshot = context.repository.cachedPayeeManagementSnapshot(budgetID: context.budgetID) ?? snapshot
            appState.recordLocalDataMutation()
            isSubmitting = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            isSubmitting = false
            return false
        }
    }

    private func context(
        using appState: AppState
    ) -> (repository: any PayeeRepositoryProtocol, budgetID: String)? {
        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makePayeeRepository() else {
            return nil
        }
        return (repository, budgetID)
    }

    private func filtered(_ payees: [ManagedPayee]) -> [ManagedPayee] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return payees
        }
        return payees.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }
}
