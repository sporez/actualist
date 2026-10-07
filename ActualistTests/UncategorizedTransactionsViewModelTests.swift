import Foundation
import Testing
@testable import Actualist

@MainActor
struct UncategorizedTransactionsViewModelTests {
    @Test func cachedSnapshotIsAvailableBeforeAnyRepositoryLoad() {
        let transaction = Self.transaction(id: "cached")
        let model = UncategorizedTransactionsViewModel(
            cachedSnapshot: LoadedUncategorizedTransactions(
                transactions: [transaction],
                accountNames: ["checking": "Checking"],
                categoryNames: [:],
                payeeNames: ["store": "Corner Store"],
                transferPayeeIDs: [],
                categoryGroups: []
            )
        )

        #expect(model.hasLoadedSnapshot)
        #expect(!model.isLoading)
        #expect(model.transactions.map(\.rowID) == ["cached"])
        #expect(model.payeeName(for: transaction) == "Corner Store")
    }

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

    @Test func localFirstCategorizationSubmitsThroughRepository() async throws {
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

        await model.load(budgetID: "budget", month: "2026-06", repository: repository)
        let result = await model.categorize(
            transaction,
            as: option,
            month: "2026-06",
            budgetID: "budget",
            repository: repository
        )

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

    @Test func categorizationRefreshesCategoryBalancesWhileTransactionsRemain() async throws {
        let firstTransaction = Self.transaction(id: "txn1")
        let remainingTransaction = Self.transaction(id: "txn2")
        let initialCategoryGroup = TransactionEditorCategoryGroup(
            id: "usual",
            name: "Usual",
            options: [
                TransactionEditorCategoryOption(
                    id: "general",
                    title: "General",
                    amount: 0,
                    valueText: "$0.00"
                )
            ]
        )
        let refreshedCategoryGroup = TransactionEditorCategoryGroup(
            id: "usual",
            name: "Usual",
            options: [
                TransactionEditorCategoryOption(
                    id: "general",
                    title: "General",
                    amount: -1_200,
                    valueText: "-$12.00"
                )
            ]
        )
        let repository = UncategorizedRecordingTransactionRepository(
            loadedResponses: [
                LoadedUncategorizedTransactions(
                    transactions: [firstTransaction, remainingTransaction],
                    accountNames: ["checking": "Checking"],
                    categoryNames: [:],
                    payeeNames: ["store": "Corner Store"],
                    transferPayeeIDs: [],
                    categoryGroups: [initialCategoryGroup]
                ),
                LoadedUncategorizedTransactions(
                    transactions: [remainingTransaction],
                    accountNames: ["checking": "Checking"],
                    categoryNames: [:],
                    payeeNames: ["store": "Corner Store"],
                    transferPayeeIDs: [],
                    categoryGroups: [refreshedCategoryGroup]
                )
            ]
        )
        let model = UncategorizedTransactionsViewModel()

        await model.load(budgetID: "budget", month: "2026-06", repository: repository)
        let result = await model.categorize(
            firstTransaction,
            categoryID: "general",
            budgetID: "budget",
            monthForRemainingRefresh: "2026-06",
            repository: repository
        )

        #expect(result == .categorized(hasRemainingTransactions: true))
        #expect(model.transactions.map(\.rowID) == ["txn2"])
        #expect(model.categoryGroups.first?.options.first?.amount == -1_200)
        #expect(model.categoryGroups.first?.options.first?.valueText == "-$12.00")
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

    @Test func selectionOnlyAcceptsCategorizationEligibleTransactions() async throws {
        let regular = Self.transaction(id: "regular")
        let crossBudgetTransfer = Self.transaction(id: "cross-budget", payee: "transfer-tracking")
        let sameBudgetTransfer = Self.transaction(id: "same-budget", payee: "transfer-savings")
        let repository = UncategorizedRecordingTransactionRepository(
            loaded: LoadedUncategorizedTransactions(
                transactions: [regular, crossBudgetTransfer, sameBudgetTransfer],
                accountNames: [:],
                categoryNames: [:],
                payeeNames: [:],
                transferPayeeIDs: ["transfer-tracking", "transfer-savings"],
                transferAccountIDsByPayeeID: [
                    "transfer-tracking": "tracking",
                    "transfer-savings": "savings"
                ],
                offBudgetAccountIDs: ["tracking"],
                categoryGroups: []
            )
        )
        let model = UncategorizedTransactionsViewModel()

        await model.load(budgetID: "budget", month: "2026-06", repository: repository)
        #expect(model.canCategorize(regular))
        #expect(model.canCategorize(crossBudgetTransfer))
        #expect(!model.canCategorize(sameBudgetTransfer))
        #expect(model.canCategorize(Self.transaction(id: "child", isChild: true, parentID: "parent")))
        #expect(!model.canCategorize(Self.transaction(id: "parent", isParent: true)))

        model.beginSelection()
        model.toggleSelection(regular)
        model.toggleSelection(crossBudgetTransfer)
        model.toggleSelection(sameBudgetTransfer)

        #expect(model.selectedTransactionIDs == ["regular", "cross-budget"])
    }

    @Test func bulkCategorizationUsesOneRepositoryMutationAndRefreshesRemainingRows() async throws {
        let first = Self.transaction(id: "txn1")
        let second = Self.transaction(id: "txn2", account: "credit")
        let remaining = Self.transaction(id: "txn3")
        let option = TransactionEditorCategoryOption(
            id: "groceries",
            title: "Groceries",
            amount: nil,
            valueText: nil
        )
        let repository = UncategorizedRecordingTransactionRepository(
            loadedResponses: [
                LoadedUncategorizedTransactions(
                    transactions: [first, second, remaining],
                    accountNames: [:],
                    categoryNames: [:],
                    payeeNames: [:],
                    transferPayeeIDs: [],
                    categoryGroups: []
                ),
                LoadedUncategorizedTransactions(
                    transactions: [remaining],
                    accountNames: [:],
                    categoryNames: [:],
                    payeeNames: [:],
                    transferPayeeIDs: [],
                    categoryGroups: []
                )
            ]
        )
        let model = UncategorizedTransactionsViewModel()

        await model.load(budgetID: "budget", month: "2026-06", repository: repository)
        model.beginSelection()
        model.toggleSelection(first)
        model.toggleSelection(second)
        let result = await model.categorizeSelection(
            as: option,
            month: "2026-06",
            budgetID: "budget",
            repository: repository
        )

        #expect(result == .categorized(hasRemainingTransactions: true))
        #expect(model.transactions.map(\.rowID) == ["txn3"])
        #expect(!model.isSelecting)
        #expect(model.selectedTransactionIDs.isEmpty)
        #expect(await repository.recordedTransactionIDs() == ["txn1", "txn2"])
        #expect(await repository.recordedCategoryID() == "groceries")
    }

    @Test func failedBulkCategorizationPreservesSelection() async throws {
        let first = Self.transaction(id: "txn1")
        let second = Self.transaction(id: "txn2")
        let repository = UncategorizedRecordingTransactionRepository(
            loaded: LoadedUncategorizedTransactions(
                transactions: [first, second],
                accountNames: [:],
                categoryNames: [:],
                payeeNames: [:],
                transferPayeeIDs: [],
                categoryGroups: []
            ),
            categorizeError: TestError("could not update selection")
        )
        let model = UncategorizedTransactionsViewModel()

        await model.load(budgetID: "budget", month: "2026-06", repository: repository)
        model.beginSelection()
        model.toggleSelection(first)
        model.toggleSelection(second)
        let result = await model.categorizeSelection(
            as: TransactionEditorCategoryOption(
                id: "groceries",
                title: "Groceries",
                amount: nil,
                valueText: nil
            ),
            month: "2026-06",
            budgetID: "budget",
            repository: repository
        )

        #expect(result == .failed)
        #expect(model.isSelecting)
        #expect(model.selectedTransactionIDs == ["txn1", "txn2"])
        #expect(model.errorMessage == "could not update selection")
    }

    @Test func categoryNamesDistinguishSameBudgetAndCrossBudgetTransfers() async throws {
        let transfer = Self.transaction(id: "transfer", payee: "transfer-checking")
        let crossBudgetTransfer = Self.transaction(id: "cross-budget-transfer", payee: "transfer-tracking")
        let regular = Self.transaction(id: "regular", payee: "store")
        let repository = UncategorizedRecordingTransactionRepository(
            loaded: LoadedUncategorizedTransactions(
                transactions: [transfer, crossBudgetTransfer, regular],
                accountNames: [:],
                categoryNames: [:],
                payeeNames: [:],
                transferPayeeIDs: ["transfer-checking", "transfer-tracking"],
                transferAccountIDsByPayeeID: [
                    "transfer-checking": "checking",
                    "transfer-tracking": "tracking"
                ],
                offBudgetAccountIDs: ["tracking"],
                categoryGroups: []
            )
        )
        let model = UncategorizedTransactionsViewModel()

        await model.load(budgetID: "budget", month: "2026-06", repository: repository)

        #expect(model.categoryNames(for: transfer) == ["Account Transfer"])
        #expect(model.categoryNames(for: crossBudgetTransfer) == ["Uncategorized"])
        #expect(model.categoryNames(for: regular) == ["Uncategorized"])
    }

    @Test func olderLoadFinishingLastDoesNotOverwriteNewerSnapshot() async throws {
        func snapshot(_ id: String) -> LoadedUncategorizedTransactions {
            LoadedUncategorizedTransactions(
                transactions: [Self.transaction(id: id)],
                accountNames: [:],
                categoryNames: [:],
                payeeNames: [:],
                transferPayeeIDs: [],
                categoryGroups: []
            )
        }
        let repository = UncategorizedRecordingTransactionRepository(
            loadedResponses: [snapshot("old"), snapshot("new")]
        )
        let oldEntered = TestLatch()
        let newEntered = TestLatch()
        let releaseOld = TestLatch()
        repository.afterLoadSelected = { call in
            if call == 1 {
                oldEntered.trip()
                await releaseOld.wait()
            } else {
                newEntered.trip()
            }
        }
        let model = UncategorizedTransactionsViewModel()

        let oldLoad = Task { await model.load(budgetID: "budget", month: "2026-06", repository: repository) }
        let oldStarted = await oldEntered.wait(timeout: .seconds(5), onTimeout: { releaseOld.trip() })
        #expect(oldStarted)
        let newLoad = Task { await model.load(budgetID: "budget", month: "2026-06", repository: repository) }
        let newStarted = await newEntered.wait(timeout: .seconds(5), onTimeout: { releaseOld.trip() })
        #expect(newStarted)
        await newLoad.value
        #expect(model.transactions.map(\.rowID) == ["new"])
        #expect(!model.isLoading)

        releaseOld.trip()
        await oldLoad.value

        #expect(model.transactions.map(\.rowID) == ["new"])
        #expect(!model.isLoading)
    }

    static func transaction(
        id: String,
        account: String = "checking",
        payee: String = "store",
        isParent: Bool = false,
        isChild: Bool = false,
        parentID: String? = nil
    ) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: account,
            date: "2026-06-14",
            amount: -1_200,
            payee: payee,
            payeeName: nil,
            importedPayee: nil,
            category: nil,
            notes: nil,
            cleared: .bool(false),
            isParent: isParent,
            isChild: isChild,
            parentID: parentID
        )
    }
}

@MainActor
final class UncategorizedRecordingTransactionRepository: TransactionRepositoryProtocol {
    func cachedAccountTransactions(budgetID: String, accountID: String, statusFilter: TransactionStatusFilter) -> LoadedAccountTransactions? { nil }
    func cachedSpendingTransactions(budgetID: String, statusFilter: TransactionStatusFilter) -> LoadedAccountTransactions? { nil }
    func refreshAccountTransactions(budgetID: String, accountID: String, statusFilter: TransactionStatusFilter) async throws {}
    func refreshSpendingTransactions(budgetID: String, statusFilter: TransactionStatusFilter) async throws {}
    func loadOlderTransactions(budgetID: String, accountID: String, statusFilter: TransactionStatusFilter) async throws {}
    func loadOlderSpendingTransactions(budgetID: String, statusFilter: TransactionStatusFilter) async throws {}
    func searchAccountTransactions(budgetID: String, accountID: String, query: String, limit: Int, offset: Int, statusFilter: TransactionStatusFilter) async throws -> LoadedAccountTransactions {
        LoadedAccountTransactions(transactions: [], balance: nil, categoryNames: [:], payeeNames: [:], transferPayeeIDs: [], reachedEnd: true)
    }
    func searchSpendingTransactions(budgetID: String, query: String, limit: Int, offset: Int, statusFilter: TransactionStatusFilter) async throws -> LoadedAccountTransactions {
        LoadedAccountTransactions(transactions: [], balance: nil, categoryNames: [:], payeeNames: [:], transferPayeeIDs: [], reachedEnd: true)
    }

    /// Replaces `existingImportedIDs` when set; receives the requested account id.
    var existingImportedIDsHook: (@MainActor (String) async -> Set<String>)?

    func existingImportedIDs(budgetID: String, accountID: String) async throws -> Set<String> {
        guard let existingImportedIDsHook else { return [] }
        return await existingImportedIDsHook(accountID)
    }

    private var loadedResponses: [LoadedUncategorizedTransactions]
    private let categorizeError: Error?
    private var categoryID: String?
    private var categorizedTransactionIDs: [String] = []
    /// Reviews the fake store would demand a matching authorization for.
    var reconciledReviews: [String: ReconciledTransactionMutationReview] = [:]
    private(set) var submittedAuthorizations: [[String: ReconciledTransactionMutationAuthorization]] = []

    private func enforceReconciliation(
        _ transactions: [ActualTransaction],
        _ authorizations: [String: ReconciledTransactionMutationAuthorization]
    ) throws {
        submittedAuthorizations.append(authorizations)
        for transaction in transactions {
            if let review = reconciledReviews[transaction.rowID],
               authorizations[transaction.rowID] != review.authorization {
                throw ReconciledTransactionMutationError.confirmationRequired(review)
            }
        }
    }

    func reconciledMutationReview(
        budgetID: String,
        transactionID: String
    ) async throws -> ReconciledTransactionMutationReview? {
        reconciledReviews[transactionID]
    }

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

    func recordedCategoryID() async -> String? {
        categoryID
    }

    func recordedTransactionIDs() async -> [String] {
        categorizedTransactionIDs
    }

    /// Awaited after the response for call `n` (1-based) is chosen, so a test
    /// can park individual loads and complete them out of order.
    var afterLoadSelected: (@MainActor (Int) async -> Void)?
    private var loadCallCount = 0

    func uncategorizedTransactions(
        budgetID: String,
        month: String
    ) async throws -> LoadedUncategorizedTransactions {
        loadCallCount += 1
        let call = loadCallCount
        let response: LoadedUncategorizedTransactions
        if loadedResponses.count > 1 {
            response = loadedResponses.removeFirst()
        } else if let loaded = loadedResponses.first {
            response = loaded
        } else {
            throw TestError("missing uncategorized fixture")
        }
        await afterLoadSelected?(call)
        return response
    }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        reconciliationAuthorizations: [String: ReconciledTransactionMutationAuthorization],
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        if let categorizeError {
            throw categorizeError
        }
        try enforceReconciliation([transaction], reconciliationAuthorizations)

        self.categoryID = categoryID
        categorizedTransactionIDs = [transaction.rowID]
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

    func categorizeTransactionsAndRefresh(
        _ transactions: [ActualTransaction],
        categoryID: String,
        budgetID: String,
        reconciliationAuthorizations: [String: ReconciledTransactionMutationAuthorization],
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        if let categorizeError {
            throw categorizeError
        }
        try enforceReconciliation(transactions, reconciliationAuthorizations)

        self.categoryID = categoryID
        categorizedTransactionIDs = transactions.map(\.rowID)
        await didUpdate()
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: Array(Set(transactions.map(\.account))).sorted(),
                months: Array(Set(transactions.compactMap { $0.date.actualYearMonth })).sorted(),
                transactions: categorizedTransactionIDs.sorted()
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
        transactionID: String?,
        didCreate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        TransactionMutationResult(ok: true, changed: ChangedResources(accounts: [], months: [], transactions: []))
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        TransactionMutationResult(ok: true, changed: ChangedResources(accounts: [], months: [], transactions: []))
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        TransactionMutationResult(ok: true, changed: ChangedResources(accounts: [], months: [], transactions: []))
    }
}
