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

    @Test func localFirstCategorizationGateSubmitsWithoutFullEditPermission() async throws {
        let transaction = Self.transaction(id: "txn1")
        let option = TransactionEditorCategoryOption(
            id: "groceries",
            title: "Groceries",
            amount: nil,
            valueText: nil
        )
        let repository = UncategorizedRecordingTransactionRepository(
            loadedResponses: [
                LoadedUncategorizedTransactions(
                    transactions: [transaction],
                    accountNames: ["checking": "Checking"],
                    categoryNames: [:],
                    payeeNames: ["store": "Corner Store"],
                    transferPayeeIDs: [],
                    categoryGroups: []
                ),
                LoadedUncategorizedTransactions(
                    transactions: [],
                    accountNames: ["checking": "Checking"],
                    categoryNames: [:],
                    payeeNames: ["store": "Corner Store"],
                    transferPayeeIDs: [],
                    categoryGroups: []
                )
            ]
        )
        let model = UncategorizedTransactionsViewModel()
        let capabilities = BackendCapabilities.localFirst

        await model.load(budgetID: "budget", month: "2026-06", repository: repository)
        let result = await model.categorize(
            transaction,
            as: option,
            month: "2026-06",
            capabilities: capabilities,
            budgetID: "budget",
            repository: repository
        )

        #expect(capabilities.canCategorizeTransactions)
        #expect(result == .categorized(hasRemainingTransactions: false))
        #expect(model.transactions.isEmpty)
        #expect(await repository.recordedCategoryID() == "groceries")
    }

    @Test func categorizationRefreshesRemainingTransactionsBeforeReportingResolvedAll() async throws {
        let firstTransaction = Self.transaction(id: "txn1")
        let remainingTransaction = Self.transaction(id: "txn2")
        let repository = UncategorizedRecordingTransactionRepository(
            loadedResponses: [
                LoadedUncategorizedTransactions(
                    transactions: [firstTransaction],
                    accountNames: ["checking": "Checking"],
                    categoryNames: [:],
                    payeeNames: ["store": "Corner Store"],
                    transferPayeeIDs: [],
                    categoryGroups: []
                ),
                LoadedUncategorizedTransactions(
                    transactions: [remainingTransaction],
                    accountNames: ["checking": "Checking"],
                    categoryNames: [:],
                    payeeNames: ["store": "Corner Store"],
                    transferPayeeIDs: [],
                    categoryGroups: []
                )
            ]
        )
        let model = UncategorizedTransactionsViewModel()

        await model.load(budgetID: "budget", month: "2026-06", repository: repository)
        let result = await model.categorize(
            firstTransaction,
            categoryID: "groceries",
            budgetID: "budget",
            monthForRemainingRefresh: "2026-06",
            repository: repository
        )

        #expect(result == .categorized(hasRemainingTransactions: true))
        #expect(model.transactions.map(\.rowID) == ["txn2"])
        #expect(model.errorMessage == nil)
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
    nonisolated func cachedAccountTransactions(budgetID: String, accountID: String) -> LoadedAccountTransactions? { nil }
    nonisolated func cachedSpendingTransactions(budgetID: String) -> LoadedAccountTransactions? { nil }
    func refreshAccountTransactions(budgetID: String, accountID: String) async throws {}
    func refreshSpendingTransactions(budgetID: String) async throws {}
    func loadOlderTransactions(budgetID: String, accountID: String) async throws {}
    func loadOlderSpendingTransactions(budgetID: String) async throws {}
    func searchAccountTransactions(budgetID: String, accountID: String, query: String, limit: Int, offset: Int) async throws -> LoadedAccountTransactions {
        LoadedAccountTransactions(transactions: [], balance: nil, categoryNames: [:], payeeNames: [:], transferPayeeIDs: [], reachedEnd: true)
    }
    func searchSpendingTransactions(budgetID: String, query: String, limit: Int, offset: Int) async throws -> LoadedAccountTransactions {
        LoadedAccountTransactions(transactions: [], balance: nil, categoryNames: [:], payeeNames: [:], transferPayeeIDs: [], reachedEnd: true)
    }

    private var loadedResponses: [LoadedUncategorizedTransactions]
    private let categorizeError: Error?
    private var categoryID: String?

    init(
        loaded: LoadedUncategorizedTransactions,
        categorizeError: Error? = nil
    ) {
        self.loadedResponses = [loaded]
        self.categorizeError = categorizeError
    }

    init(
        loadedResponses: [LoadedUncategorizedTransactions],
        categorizeError: Error? = nil
    ) {
        self.loadedResponses = loadedResponses
        self.categorizeError = categorizeError
    }

    func recordedCategoryID() -> String? {
        categoryID
    }

    func uncategorizedTransactions(
        budgetID: String,
        month: String
    ) async throws -> LoadedUncategorizedTransactions {
        if loadedResponses.count > 1 {
            return loadedResponses.removeFirst()
        }

        guard let loaded = loadedResponses.first else {
            throw TestError("missing uncategorized fixture")
        }
        return loaded
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
