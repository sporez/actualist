import Foundation
import Testing
@testable import Actualist

@MainActor
struct UncategorizedTransactionsViewModelTests {
    @Test func successfulCategorizationRemovesResolvedTransaction() async throws {
        let transaction = Self.transaction(id: "txn1")
        let repository = UncategorizedRecordingTransactionRepository(
            loaded: LoadedUncategorizedTransactions(
                transactions: [transaction],
                accountNames: ["checking": "Checking"],
                categoryNames: [:],
                payeeNames: ["store": "Corner Store"],
                transferPayeeIDs: [],
                categoryGroups: []
            )
        )
        let model = UncategorizedTransactionsViewModel()

        await model.load(budgetID: "budget", month: "2026-06", repository: repository)
        let categorized = await model.categorize(
            transaction,
            categoryID: "groceries",
            budgetID: "budget",
            repository: repository
        )

        #expect(categorized)
        #expect(model.transactions.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(await repository.recordedCategoryID() == "groceries")
    }

    @Test func failedCategorizationKeepsTransactionAndShowsError() async throws {
        let transaction = Self.transaction(id: "txn1")
        let repository = UncategorizedRecordingTransactionRepository(
            loaded: LoadedUncategorizedTransactions(
                transactions: [transaction],
                accountNames: [:],
                categoryNames: [:],
                payeeNames: [:],
                transferPayeeIDs: [],
                categoryGroups: []
            ),
            categorizeError: TestError("could not update")
        )
        let model = UncategorizedTransactionsViewModel()

        await model.load(budgetID: "budget", month: "2026-06", repository: repository)
        let categorized = await model.categorize(
            transaction,
            categoryID: "groceries",
            budgetID: "budget",
            repository: repository
        )

        #expect(categorized == false)
        #expect(model.transactions.map(\.rowID) == ["txn1"])
        #expect(model.errorMessage == "could not update")
    }

    @Test func categoryNamesShowAccountTransferForTransferPayees() async throws {
        let transfer = Self.transaction(id: "transfer", payee: "transfer-checking")
        let regular = Self.transaction(id: "regular", payee: "store")
        let repository = UncategorizedRecordingTransactionRepository(
            loaded: LoadedUncategorizedTransactions(
                transactions: [transfer, regular],
                accountNames: [:],
                categoryNames: [:],
                payeeNames: [:],
                transferPayeeIDs: ["transfer-checking"],
                categoryGroups: []
            )
        )
        let model = UncategorizedTransactionsViewModel()

        await model.load(budgetID: "budget", month: "2026-06", repository: repository)

        #expect(model.categoryNames(for: transfer) == ["Account Transfer"])
        #expect(model.categoryNames(for: regular) == ["Uncategorized"])
    }

    private static func transaction(id: String, payee: String = "store") -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: "checking",
            date: "2026-06-14",
            amount: -1_200,
            payee: payee,
            payeeName: nil,
            importedPayee: nil,
            category: nil,
            notes: nil,
            cleared: .bool(false)
        )
    }
}

actor UncategorizedRecordingTransactionRepository: TransactionRepositoryProtocol {
    private let loaded: LoadedUncategorizedTransactions
    private let categorizeError: Error?
    private var categoryID: String?

    init(
        loaded: LoadedUncategorizedTransactions,
        categorizeError: Error? = nil
    ) {
        self.loaded = loaded
        self.categorizeError = categorizeError
    }

    func recordedCategoryID() -> String? {
        categoryID
    }

    func uncategorizedTransactions(
        budgetID: String,
        month: String
    ) async throws -> LoadedUncategorizedTransactions {
        loaded
    }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        if let categorizeError {
            throw categorizeError
        }

        self.categoryID = categoryID
        await didUpdate()
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [transaction.account],
                months: transaction.date.actualYearMonth.map { [$0] } ?? [],
                transactions: transaction.id.map { [$0] } ?? []
            )
        )
    }

    func editorOptions(budgetID: String, month: String) async throws -> TransactionEditorOptions {
        TransactionEditorOptions(accounts: [], categories: [], categoryGroups: [], payees: [])
    }

    func previewRules(for draft: TransactionDraft, budgetID: String) async throws -> TransactionRulePreview {
        TransactionRulePreview(categoryID: nil, notes: nil)
    }

    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        didCreate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        TransactionMutationResult(ok: true, changed: ChangedResources(accounts: [], months: [], transactions: []))
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        TransactionMutationResult(ok: true, changed: ChangedResources(accounts: [], months: [], transactions: []))
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        TransactionMutationResult(ok: true, changed: ChangedResources(accounts: [], months: [], transactions: []))
    }
}
