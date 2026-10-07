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
    /// Only the newest `load` may publish, so an older one finishing last cannot win.
    private var loadGeneration = 0
    private(set) var reconciledCategorization: UncategorizedReconciledCategorization?

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
              !transaction.isParent else {
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
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil

        do {
            let loaded = try await repository.uncategorizedTransactions(budgetID: budgetID, month: month)
            guard generation == loadGeneration else { return }
            apply(loaded)
            hasLoadedSnapshot = true
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.userFacingMessage
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
        return await submitSelection(
            categoryID: option.id,
            month: month,
            budgetID: budgetID,
            repository: repository,
            authorizations: [:]
        )
    }

    private func submitSelection(
        categoryID: String,
        month: String,
        budgetID: String,
        repository: any TransactionRepositoryProtocol,
        authorizations: [String: ReconciledTransactionMutationAuthorization]
    ) async -> CategorizationResult {
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
                categoryID: categoryID,
                budgetID: budgetID,
                reconciliationAuthorizations: authorizations
            ) {}
            let resolvedIDs = selectedTransactionIDs
            transactions.removeAll { resolvedIDs.contains($0.rowID) }

            do {
                isLoading = true
                apply(try await repository.uncategorizedTransactions(budgetID: budgetID, month: month))
                isLoading = false
            } catch {
                isLoading = false
                errorMessage = error.userFacingMessage
                endSelection()
                return .categorized(hasRemainingTransactions: true)
            }

            endSelection()
            return .categorized(hasRemainingTransactions: !transactions.isEmpty)
        } catch {
            if error is ReconciledTransactionMutationError {
                await presentSelectionReview(
                    categoryID: categoryID,
                    month: month,
                    selected: selected,
                    budgetID: budgetID,
                    repository: repository,
                    refusal: error
                )
            } else {
                errorMessage = error.userFacingMessage
            }
            return .failed
        }
    }

    /// Reviews every selected row so one confirmation covers the whole batch
    /// instead of prompting row by row as the store refuses each in turn.
    private func presentSelectionReview(
        categoryID: String,
        month: String,
        selected: [ActualTransaction],
        budgetID: String,
        repository: any TransactionRepositoryProtocol,
        refusal: Error
    ) async {
        var reviews: [ReconciledTransactionMutationReview] = []
        do {
            for transaction in selected {
                if let review = try await repository.reconciledMutationReview(
                    budgetID: budgetID,
                    transactionID: transaction.rowID
                ) {
                    reviews.append(review)
                }
            }
        } catch {
            errorMessage = error.userFacingMessage
            return
        }
        if reviews.isEmpty,
           case .confirmationRequired(let review) = refusal as? ReconciledTransactionMutationError {
            reviews = [review]
        }
        guard !reviews.isEmpty else {
            errorMessage = refusal.userFacingMessage
            return
        }
        reconciledCategorization = UncategorizedReconciledCategorization(
            scope: .selection,
            categoryID: categoryID,
            month: month,
            reviews: reviews
        )
        errorMessage = nil
    }

    func confirmReconciledCategorization(
        _ pending: UncategorizedReconciledCategorization,
        using appState: AppState
    ) async -> CategorizationResult {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return .failed
        }
        return await confirmReconciledCategorization(
            pending,
            budgetID: budgetID,
            repository: appState.transactionRepository
        )
    }

    func confirmReconciledCategorization(
        _ pending: UncategorizedReconciledCategorization,
        budgetID: String,
        repository: any TransactionRepositoryProtocol
    ) async -> CategorizationResult {
        guard reconciledCategorization == nil || reconciledCategorization == pending else {
            return .failed
        }
        reconciledCategorization = nil
        switch pending.scope {
        case .single(let transaction):
            return await categorizeAndMaybeRefreshRemaining(
                transaction,
                categoryID: pending.categoryID,
                budgetID: budgetID,
                monthForRemainingRefresh: pending.month,
                repository: repository,
                authorizations: pending.authorizations
            )
        case .selection:
            guard let month = pending.month else {
                return .failed
            }
            return await submitSelection(
                categoryID: pending.categoryID,
                month: month,
                budgetID: budgetID,
                repository: repository,
                authorizations: pending.authorizations
            )
        }
    }

    func dismissReconciledCategorization() {
        reconciledCategorization = nil
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
        repository: any TransactionRepositoryProtocol,
        authorizations: [String: ReconciledTransactionMutationAuthorization] = [:]
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
                budgetID: budgetID,
                reconciliationAuthorizations: authorizations
            ) {}
            transactions.removeAll { $0.rowID == transactionID }

            if let month {
                do {
                    isLoading = true
                    apply(try await repository.uncategorizedTransactions(budgetID: budgetID, month: month))
                    isLoading = false
                } catch {
                    isLoading = false
                    errorMessage = error.userFacingMessage
                    return .categorized(hasRemainingTransactions: true)
                }
            }

            return .categorized(hasRemainingTransactions: !transactions.isEmpty)
        } catch {
            if case .confirmationRequired(let review) = error as? ReconciledTransactionMutationError {
                reconciledCategorization = UncategorizedReconciledCategorization(
                    scope: .single(transaction),
                    categoryID: categoryID,
                    month: month,
                    reviews: [review]
                )
            } else {
                errorMessage = error.userFacingMessage
            }
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
