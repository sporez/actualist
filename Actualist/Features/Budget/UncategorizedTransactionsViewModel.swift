import Foundation
import Observation

@MainActor
@Observable
final class UncategorizedTransactionsViewModel {
    var transactions: [ActualTransaction] = []
    var accountNames: [String: String] = [:]
    var categoryNames: [String: String] = [:]
    var payeeNames: [String: String] = [:]
    var transferPayeeIDs: Set<String> = []
    var transferAccountIDsByPayeeID: [String: String] = [:]
    var offBudgetAccountIDs: Set<String> = []
    var categoryGroups: [TransactionEditorCategoryGroup] = []
    var isLoading = true
    var errorMessage: String?
    var categorizingTransactionID: String?
    var selectedTransactionIDs: Set<String> = []
    var isSelecting = false
    var isBulkCategorizing = false
    private(set) var hasLoadedSnapshot = false

    init(cachedSnapshot: LoadedUncategorizedTransactions? = nil) {
        guard let cachedSnapshot else {
            return
        }
        apply(cachedSnapshot)
        hasLoadedSnapshot = true
        isLoading = false
    }

    var isCategorizing: Bool {
        categorizingTransactionID != nil || isBulkCategorizing
    }

    var selectedTransactions: [ActualTransaction] {
        transactions.filter { selectedTransactionIDs.contains($0.rowID) }
    }

    var canBeginSelection: Bool {
        transactions.filter(canCategorize).count >= 2 && !isCategorizing
    }

    var canSubmitSelection: Bool {
        !selectedTransactionIDs.isEmpty && !isCategorizing
    }

    var transactionGroups: [TransactionDateGroup] {
        TransactionGrouping.grouped(transactions)
    }

    func canCategorize(_ transaction: ActualTransaction) -> Bool {
        guard let transactionID = transaction.id,
              !transactionID.isEmpty,
              transaction.date.actualYearMonth != nil,
              transaction.subtransactions.isEmpty,
              !transaction.isParent,
              !transaction.isChild else {
            return false
        }

        guard let payeeID = transaction.payee,
              transferPayeeIDs.contains(payeeID) else {
            return true
        }
        guard let destinationAccountID = transferAccountIDsByPayeeID[payeeID] else {
            return false
        }
        return !offBudgetAccountIDs.contains(transaction.account)
            && offBudgetAccountIDs.contains(destinationAccountID)
    }

    func beginSelection() {
        guard canBeginSelection else {
            return
        }
        selectedTransactionIDs = []
        isSelecting = true
    }

    func endSelection() {
        selectedTransactionIDs = []
        isSelecting = false
    }

    func toggleSelection(_ transaction: ActualTransaction) {
        guard isSelecting, canCategorize(transaction), !isCategorizing else {
            return
        }
        if selectedTransactionIDs.contains(transaction.rowID) {
            selectedTransactionIDs.remove(transaction.rowID)
        } else {
            selectedTransactionIDs.insert(transaction.rowID)
        }
    }

    enum CategorizationResult: Equatable {
        case failed
        case categorized(hasRemainingTransactions: Bool)

        var didChange: Bool {
            if case .categorized = self {
                return true
            }
            return false
        }

        var resolvedAll: Bool {
            self == .categorized(hasRemainingTransactions: false)
        }
    }

    func load(month: String, using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }
        let repository = appState.transactionRepository

        await load(budgetID: budgetID, month: month, repository: repository)
    }

    func loadIfNeeded(month: String, using appState: AppState) async {
        guard !hasLoadedSnapshot else {
            return
        }
        await load(month: month, using: appState)
    }

    func refresh(month: String, using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }

        _ = await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
        await load(month: month, using: appState)
    }

    func load(
        budgetID: String,
        month: String,
        repository: any TransactionRepositoryProtocol
    ) async {
        isLoading = true
        errorMessage = nil

        do {
            apply(try await repository.uncategorizedTransactions(budgetID: budgetID, month: month))
            hasLoadedSnapshot = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func categorize(
        _ transaction: ActualTransaction,
        as option: TransactionEditorCategoryOption,
        month: String,
        using appState: AppState
    ) async -> CategorizationResult {
        return await categorize(
            transaction,
            as: option,
            month: month,
            budgetID: appState.settings.selectedBudgetID,
            repository: appState.transactionRepository
        )
    }

    func categorize(
        _ transaction: ActualTransaction,
        as option: TransactionEditorCategoryOption,
        month: String,
        budgetID: String?,
        repository: (any TransactionRepositoryProtocol)?
    ) async -> CategorizationResult {
        guard let budgetID,
              let repository else {
            return .failed
        }

        return await categorize(
            transaction,
            categoryID: option.id,
            budgetID: budgetID,
            monthForRemainingRefresh: month,
            repository: repository
        )
    }

    func categorize(
        _ transaction: ActualTransaction,
        as option: TransactionEditorCategoryOption,
        using appState: AppState
    ) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return false
        }
        let repository = appState.transactionRepository

        return await categorize(transaction, categoryID: option.id, budgetID: budgetID, repository: repository)
    }

    func categorize(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        repository: any TransactionRepositoryProtocol
    ) async -> Bool {
        let result = await categorizeAndMaybeRefreshRemaining(
            transaction,
            categoryID: categoryID,
            budgetID: budgetID,
            monthForRemainingRefresh: nil,
            repository: repository
        )
        return result.didChange
    }

    func categorizeSelection(
        as option: TransactionEditorCategoryOption,
        month: String,
        using appState: AppState
    ) async -> CategorizationResult {
        await categorizeSelection(
            as: option,
            month: month,
            budgetID: appState.settings.selectedBudgetID,
            repository: appState.transactionRepository
        )
    }

    func categorizeSelection(
        as option: TransactionEditorCategoryOption,
        month: String,
        budgetID: String?,
        repository: (any TransactionRepositoryProtocol)?
    ) async -> CategorizationResult {
        guard let budgetID,
              let repository,
              canSubmitSelection else {
            return .failed
        }
        let selected = selectedTransactions
        guard selected.count == selectedTransactionIDs.count,
              selected.allSatisfy(canCategorize) else {
            errorMessage = "One or more selected transactions can no longer be categorized."
            return .failed
        }

        isBulkCategorizing = true
        errorMessage = nil
        defer {
            isBulkCategorizing = false
        }

        do {
            _ = try await repository.categorizeTransactionsAndRefresh(
                selected,
                categoryID: option.id,
                budgetID: budgetID
            ) {}
            let resolvedIDs = selectedTransactionIDs
            transactions.removeAll { resolvedIDs.contains($0.rowID) }

            do {
                isLoading = true
                apply(try await repository.uncategorizedTransactions(budgetID: budgetID, month: month))
                isLoading = false
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
                endSelection()
                return .categorized(hasRemainingTransactions: true)
            }

            endSelection()
            return .categorized(hasRemainingTransactions: !transactions.isEmpty)
        } catch {
            errorMessage = error.localizedDescription
            return .failed
        }
    }

    func categorize(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        monthForRemainingRefresh month: String,
        repository: any TransactionRepositoryProtocol
    ) async -> CategorizationResult {
        await categorizeAndMaybeRefreshRemaining(
            transaction,
            categoryID: categoryID,
            budgetID: budgetID,
            monthForRemainingRefresh: month,
            repository: repository
        )
    }

    private func categorizeAndMaybeRefreshRemaining(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        monthForRemainingRefresh month: String?,
        repository: any TransactionRepositoryProtocol
    ) async -> CategorizationResult {
        guard !isCategorizing, canCategorize(transaction) else {
            return .failed
        }

        let transactionID = transaction.rowID
        categorizingTransactionID = transactionID
        errorMessage = nil
        defer {
            categorizingTransactionID = nil
        }

        do {
            _ = try await repository.categorizeTransactionAndRefresh(
                transaction,
                categoryID: categoryID,
                budgetID: budgetID
            ) {}
            transactions.removeAll { $0.rowID == transactionID }

            if let month {
                do {
                    isLoading = true
                    apply(try await repository.uncategorizedTransactions(budgetID: budgetID, month: month))
                    isLoading = false
                } catch {
                    isLoading = false
                    errorMessage = error.localizedDescription
                    return .categorized(hasRemainingTransactions: true)
                }
            }

            return .categorized(hasRemainingTransactions: !transactions.isEmpty)
        } catch {
            errorMessage = error.localizedDescription
            return .failed
        }
    }

    func payeeName(for transaction: ActualTransaction) -> String {
        rowSemantics(for: transaction).payeeText
    }

    func categoryNames(for transaction: ActualTransaction) -> [String] {
        [rowSemantics(for: transaction).categoryText]
    }

    func rowSemantics(
        for transaction: ActualTransaction,
        privacyEnabled: Bool = false
    ) -> TransactionRowSemantics {
        TransactionRowSemantics.project(
            transaction,
            lookup: TransactionRowLookup(
                payeeNames: payeeNames,
                categoryNames: categoryNames,
                transferPayeeIDs: transferPayeeIDs,
                transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
                offBudgetAccountIDs: offBudgetAccountIDs
            ),
            privacyEnabled: privacyEnabled
        )
    }

    private func apply(_ loaded: LoadedUncategorizedTransactions) {
        transactions = loaded.transactions
        accountNames = loaded.accountNames
        categoryNames = loaded.categoryNames
        payeeNames = loaded.payeeNames
        transferPayeeIDs = loaded.transferPayeeIDs
        transferAccountIDsByPayeeID = loaded.transferAccountIDsByPayeeID
        offBudgetAccountIDs = loaded.offBudgetAccountIDs
        categoryGroups = loaded.categoryGroups
        let currentEligibleIDs = Set(transactions.filter(canCategorize).map(\.rowID))
        selectedTransactionIDs.formIntersection(currentEligibleIDs)
    }
}
