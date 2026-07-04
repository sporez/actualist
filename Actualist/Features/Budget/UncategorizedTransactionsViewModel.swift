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
    var categoryGroups: [TransactionEditorCategoryGroup] = []
    var isLoading = false
    var errorMessage: String?
    var categorizingTransactionID: String?

    var isCategorizing: Bool {
        categorizingTransactionID != nil
    }

    var transactionGroups: [TransactionDateGroup] {
        TransactionGrouping.grouped(transactions)
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
        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeTransactionRepository() else {
            return
        }

        await load(budgetID: budgetID, month: month, repository: repository)
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
        guard appState.capabilities.canEditTransactions,
              let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeTransactionRepository() else {
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
        guard appState.capabilities.canEditTransactions,
              let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeTransactionRepository() else {
            return false
        }

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
        guard categorizingTransactionID == nil else {
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

            if let month, transactions.isEmpty {
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
        if let payeeName = transaction.payeeName, !payeeName.isEmpty {
            return payeeName
        }
        if let payee = transaction.payee, let name = payeeNames[payee] {
            return name
        }
        if let importedPayee = transaction.importedPayee, !importedPayee.isEmpty {
            return importedPayee
        }
        return "Unknown Payee"
    }

    func categoryNames(for transaction: ActualTransaction) -> [String] {
        if !transaction.subtransactions.isEmpty {
            let names = transaction.subtransactions.map { child in
                categoryName(for: child)
            }
            return names.isEmpty ? ["Split (\(transaction.subtransactions.count))"] : names
        }

        return [categoryName(for: transaction)]
    }

    private func categoryName(for transaction: ActualTransaction) -> String {
        guard let category = transaction.category else {
            if let payee = transaction.payee, transferPayeeIDs.contains(payee) {
                return "Account Transfer"
            }
            return "Uncategorized"
        }

        return categoryNames[category] ?? "Uncategorized"
    }

    private func apply(_ loaded: LoadedUncategorizedTransactions) {
        transactions = loaded.transactions
        accountNames = loaded.accountNames
        categoryNames = loaded.categoryNames
        payeeNames = loaded.payeeNames
        transferPayeeIDs = loaded.transferPayeeIDs
        categoryGroups = loaded.categoryGroups
    }
}
