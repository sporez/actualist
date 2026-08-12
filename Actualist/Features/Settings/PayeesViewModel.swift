import Foundation
import Observation

@MainActor
@Observable
final class PayeesViewModel {
    enum ListFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case unused = "Unused"

        var id: String { rawValue }
    }

    var snapshot: PayeeManagementSnapshot = .empty
    var searchText = ""
    var listFilter: ListFilter = .all
    var selectedPayeeIDs: Set<String> = []
    var isSelecting = false
    var isLoading = false
    var isSubmitting = false
    var errorMessage: String?

    var regularPayees: [ManagedPayee] {
        filtered(snapshot.payees.filter { payee in
            !payee.isTransfer && (listFilter == .all || payee.isUnused)
        })
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

    var unusedPayeeCount: Int {
        snapshot.payees.count { !$0.isTransfer && $0.isUnused }
    }

    var visibleRegularPayeeIDs: Set<String> {
        Set(regularPayees.map(\.id))
    }

    var areAllVisiblePayeesSelected: Bool {
        !visibleRegularPayeeIDs.isEmpty && visibleRegularPayeeIDs.isSubset(of: selectedPayeeIDs)
    }

    var canDeleteSelection: Bool {
        !selectedPayees.isEmpty && selectedPayees.allSatisfy(\.canDelete) && !isSubmitting
    }

    var selectedAreAllFavorites: Bool {
        !selectedPayees.isEmpty && selectedPayees.allSatisfy(\.favorite)
    }

    var selectedAllLearnCategories: Bool {
        !selectedPayees.isEmpty && selectedPayees.allSatisfy(\.learnCategories)
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

    func deleteSelection(using appState: AppState) async -> Bool {
        let ids = Set(selectedPayees.filter(\.canDelete).map(\.id))
        guard ids.count == selectedPayees.count, !ids.isEmpty else {
            errorMessage = "Only unused payees without rule references can be deleted."
            return false
        }
        let succeeded = await mutate(using: appState) { repository, budgetID in
            try await repository.deletePayeesAndRefresh(budgetID: budgetID, payeeIDs: ids)
        }
        if succeeded { endSelection() }
        return succeeded
    }

    func setFavoriteForSelection(_ favorite: Bool, using appState: AppState) async -> Bool {
        let updates = selectedPayees.map {
            PayeeManagementUpdate(payeeID: $0.id, favorite: favorite)
        }
        guard !updates.isEmpty else { return false }
        let succeeded = await mutate(using: appState) { repository, budgetID in
            try await repository.updatePayeesAndRefresh(budgetID: budgetID, updates: updates)
        }
        if succeeded { endSelection() }
        return succeeded
    }

    func setLearningForSelection(_ enabled: Bool, using appState: AppState) async -> Bool {
        let updates = selectedPayees.map {
            PayeeManagementUpdate(payeeID: $0.id, learnCategories: enabled)
        }
        guard !updates.isEmpty else { return false }
        let succeeded = await mutate(using: appState) { repository, budgetID in
            try await repository.updatePayeesAndRefresh(budgetID: budgetID, updates: updates)
        }
        if succeeded { endSelection() }
        return succeeded
    }

    func setFavorite(payeeID: String, favorite: Bool, using appState: AppState) async -> Bool {
        await mutate(using: appState) { repository, budgetID in
            try await repository.updatePayeesAndRefresh(
                budgetID: budgetID,
                updates: [PayeeManagementUpdate(payeeID: payeeID, favorite: favorite)]
            )
        }
    }

    func setLearning(payeeID: String, enabled: Bool, using appState: AppState) async -> Bool {
        await mutate(using: appState) { repository, budgetID in
            try await repository.updatePayeesAndRefresh(
                budgetID: budgetID,
                updates: [PayeeManagementUpdate(payeeID: payeeID, learnCategories: enabled)]
            )
        }
    }

    func setGlobalCategoryLearning(_ enabled: Bool, using appState: AppState) async -> Bool {
        await mutate(using: appState) { repository, budgetID in
            try await repository.setGlobalCategoryLearningAndRefresh(budgetID: budgetID, enabled: enabled)
        }
    }

    func undo(using appState: AppState) async -> Bool {
        await mutate(using: appState) { repository, budgetID in
            try await repository.undoLastPayeeMutationAndRefresh(budgetID: budgetID)
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

    func toggleAllVisibleSelection() {
        if areAllVisiblePayeesSelected {
            selectedPayeeIDs.subtract(visibleRegularPayeeIDs)
        } else {
            selectedPayeeIDs.formUnion(visibleRegularPayeeIDs)
        }
    }

    private func mutate(
        using appState: AppState,
        operation: (any PayeeRepositoryProtocol, String) async throws -> Void
    ) async -> Bool {
        guard !appState.settings.randomizedDisplayValuesEnabled else {
            errorMessage = "Turn off randomized display data before changing payees."
            return false
        }
        guard let context = context(using: appState) else {
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
        guard let budgetID = appState.settings.selectedBudgetID else {
            return nil
        }
        return (appState.payeeRepository, budgetID)
    }

    private func filtered(_ payees: [ManagedPayee]) -> [ManagedPayee] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return payees
        }
        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return payees.filter { payee in
            let searchable = (payee.isTransfer ? "Transfer: " : "") + payee.displayName
            return searchable.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(normalizedQuery)
        }
    }
}
