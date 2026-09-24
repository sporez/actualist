import Foundation
import Testing
@testable import Actualist

@MainActor
extension TransactionEditorViewModelTests {
    func configuredModel() -> TransactionEditorViewModel {
        let model = TransactionEditorViewModel()
        model.kind = .spend
        model.amountDigits = "1234"
        model.payeeName = "  Corner Store  "
        model.selectedAccountID = "checking"
        model.date = Self.date("2026-06-14")
        model.notes = "  weekly groceries  "
        model.isCleared = true
        return model
    }

    nonisolated static func splitRow(
        id: String,
        categoryID: String? = nil,
        categoryName: String? = nil,
        amount: Int,
        payeeID: String? = nil,
        notes: String? = nil
    ) -> TransactionSplitEditorRow {
        TransactionSplitEditorRow(
            id: id,
            transactionID: nil,
            amountMinorUnits: amount,
            categoryID: categoryID,
            categoryName: categoryName ?? categoryID,
            payeeID: payeeID,
            payeeName: nil,
            notes: notes,
            isTransfer: false
        )
    }

    nonisolated static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: "\(value) 12:00:00")!
    }
}
@MainActor
final class RecordingTransactionRepository: TransactionRepositoryProtocol {
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

    private var drafts: [TransactionDraft] = []
    private var updates: [RecordedTransactionUpdate] = []
    private var deletes: [ActualTransaction] = []
    private var rulePreviewDrafts: [TransactionDraft] = []
    private let rulePreview: TransactionRulePreview
    private let previewError: Error?
    private let createError: Error?
    private let refreshError: Error?
    private let pauseBeforeDidCreate: Bool
    private let pauseAfterDidCreate: Bool
    private let editorOptionsResult: TransactionEditorOptions?
    private let pausedEditorOptionsMonths: Set<String>
    private var didCreateCallbackFinished = false
    private var pausedBeforeDidCreate = false
    private var beforeDidCreateContinuation: CheckedContinuation<Void, Never>?
    private var afterDidCreateContinuation: CheckedContinuation<Void, Never>?
    private let editorAccounts: [ActualAccount]
    private let rulePreviewsByPayeeName: [String: TransactionRulePreview]
    private let pausedRulePreviewPayeeNames: Set<String>
    private var reconciliationReview: ReconciledTransactionMutationReview?
    private var updateAuthorizations: [ReconciledTransactionMutationAuthorization?] = []
    private var deleteAuthorizations: [ReconciledTransactionMutationAuthorization?] = []
    private var unlockTransactionIDs: [String] = []
    private var pausedRulePreviewContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var pausedEditorOptionsContinuations: [String: CheckedContinuation<Void, Never>] = [:]

    init(
        rulePreview: TransactionRulePreview = TransactionRulePreview(categoryID: nil, notes: nil),
        previewError: Error? = nil,
        createError: Error? = nil,
        refreshError: Error? = nil,
        pauseBeforeDidCreate: Bool = false,
        pauseAfterDidCreate: Bool = false,
        editorAccounts: [ActualAccount] = [],
        rulePreviewsByPayeeName: [String: TransactionRulePreview] = [:],
        pausedRulePreviewPayeeNames: Set<String> = [],
        reconciliationReview: ReconciledTransactionMutationReview? = nil,
        editorOptionsResult: TransactionEditorOptions? = nil,
        pausedEditorOptionsMonths: Set<String> = []
    ) {
        self.rulePreview = rulePreview
        self.previewError = previewError
        self.createError = createError
        self.refreshError = refreshError
        self.pauseBeforeDidCreate = pauseBeforeDidCreate
        self.pauseAfterDidCreate = pauseAfterDidCreate
        self.editorAccounts = editorAccounts
        self.rulePreviewsByPayeeName = rulePreviewsByPayeeName
        self.pausedRulePreviewPayeeNames = pausedRulePreviewPayeeNames
        self.reconciliationReview = reconciliationReview
        self.editorOptionsResult = editorOptionsResult
        self.pausedEditorOptionsMonths = pausedEditorOptionsMonths
    }

    func editorOptions(budgetID: String, month: String) async throws -> TransactionEditorOptions {
        if pausedEditorOptionsMonths.contains(month) {
            await withCheckedContinuation { continuation in
                pausedEditorOptionsContinuations[month] = continuation
            }
        }
        return editorOptionsResult ?? TransactionEditorOptions(accounts: editorAccounts, categories: [], categoryGroups: [], payees: [])
    }

    func uncategorizedTransactions(
        budgetID: String,
        month: String
    ) async throws -> LoadedUncategorizedTransactions {
        LoadedUncategorizedTransactions(
            transactions: [],
            accountNames: [:],
            categoryNames: [:],
            payeeNames: [:],
            transferPayeeIDs: [],
            categoryGroups: []
        )
    }

    func previewRules(
        for draft: TransactionDraft,
        budgetID: String
    ) async throws -> TransactionRulePreview {
        rulePreviewDrafts.append(draft)
        if pausedRulePreviewPayeeNames.contains(draft.payeeName) {
            await withCheckedContinuation { continuation in
                pausedRulePreviewContinuations[draft.payeeName] = continuation
            }
        }
        if let previewError {
            throw previewError
        }
        return rulePreviewsByPayeeName[draft.payeeName] ?? rulePreview
    }

    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        didCreate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        drafts.append(draft)

        if pauseBeforeDidCreate {
            await withCheckedContinuation { continuation in
                pausedBeforeDidCreate = true
                beforeDidCreateContinuation = continuation
            }
            pausedBeforeDidCreate = false
        }

        if let createError {
            throw createError
        }

        await didCreate()
        didCreateCallbackFinished = true

        if pauseAfterDidCreate {
            await withCheckedContinuation { continuation in
                afterDidCreateContinuation = continuation
            }
        }

        if let refreshError {
            throw refreshError
        }

        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [draft.accountID],
                months: [draft.month.rawValue],
                transactions: []
            )
        )
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        updates.append(
            RecordedTransactionUpdate(
                transactionID: transactionID,
                draft: draft,
                originalAccountID: originalAccountID,
                originalMonth: originalMonth
            )
        )

        if let createError {
            throw createError
        }

        await didUpdate()
        didCreateCallbackFinished = true

        if let refreshError {
            throw refreshError
        }

        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [originalAccountID, draft.accountID],
                months: [originalMonth, draft.month.rawValue],
                transactions: [transactionID]
            )
        )
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization?,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        updateAuthorizations.append(reconciliationAuthorization)
        if let reconciliationReview,
           reconciliationAuthorization != reconciliationReview.authorization {
            throw ReconciledTransactionMutationError.confirmationRequired(reconciliationReview)
        }
        return try await updateTransactionAndRefresh(
            transactionID,
            with: draft,
            budgetID: budgetID,
            originalAccountID: originalAccountID,
            originalMonth: originalMonth,
            didUpdate: didUpdate
        )
    }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        if let createError {
            throw createError
        }

        await didUpdate()

        if let refreshError {
            throw refreshError
        }

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
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        await didUpdate()
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: Array(Set(transactions.map(\.account))).sorted(),
                months: Array(Set(transactions.compactMap { $0.date.actualYearMonth })).sorted(),
                transactions: transactions.map(\.rowID).sorted()
            )
        )
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        deletes.append(transaction)

        if let createError {
            throw createError
        }

        await didDelete()
        didCreateCallbackFinished = true

        if let refreshError {
            throw refreshError
        }

        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [transaction.account],
                months: transaction.date.actualYearMonth.map { [$0] } ?? [],
                transactions: transaction.id.map { [$0] } ?? []
            )
        )
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization?,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        deleteAuthorizations.append(reconciliationAuthorization)
        if let reconciliationReview,
           reconciliationAuthorization != reconciliationReview.authorization {
            throw ReconciledTransactionMutationError.confirmationRequired(reconciliationReview)
        }
        return try await deleteTransactionAndRefresh(
            transaction,
            budgetID: budgetID,
            didDelete: didDelete
        )
    }

    func reconciledMutationReview(
        budgetID: String,
        transactionID: String
    ) async throws -> ReconciledTransactionMutationReview? {
        reconciliationReview
    }

    func unlockReconciledTransactionAndRefresh(
        budgetID: String,
        accountID: String,
        transactionID: String
    ) async throws -> AccountReconciliationMutationResult {
        unlockTransactionIDs.append(transactionID)
        reconciliationReview = nil
        return AccountReconciliationMutationResult(
            snapshot: AccountReconciliationSnapshot(
                accountID: accountID,
                accountName: "Checking",
                workingBalance: 0,
                clearedBalance: 0,
                lastSyncedBalance: nil,
                lastReconciledMilliseconds: nil,
                capability: .available
            ),
            changed: ChangedResources(
                accounts: [accountID],
                months: ["2026-06"],
                transactions: [transactionID]
            )
        )
    }

    func onlyDraft() async throws -> TransactionDraft {
        try #require(drafts.first)
    }

    func onlyUpdate() async throws -> RecordedTransactionUpdate {
        try #require(updates.first)
    }

    func onlyDelete() async throws -> ActualTransaction {
        try #require(deletes.first)
    }

    func onlyRulePreviewDraft() async throws -> TransactionDraft {
        try #require(rulePreviewDrafts.first)
    }

    func recordedUpdateAuthorizations() async -> [ReconciledTransactionMutationAuthorization?] {
        updateAuthorizations
    }

    func recordedDeleteAuthorizations() async -> [ReconciledTransactionMutationAuthorization?] {
        deleteAuthorizations
    }

    func recordedUnlockTransactionIDs() async -> [String] {
        unlockTransactionIDs
    }

    func rulePreviewDraftCount() async -> Int {
        rulePreviewDrafts.count
    }

    func isRulePreviewPaused(payeeName: String) async -> Bool {
        pausedRulePreviewContinuations[payeeName] != nil
    }

    func resumeRulePreview(payeeName: String) async {
        pausedRulePreviewContinuations.removeValue(forKey: payeeName)?.resume()
    }

    func isEditorOptionsPaused(month: String) async -> Bool {
        pausedEditorOptionsContinuations[month] != nil
    }

    func resumeEditorOptions(month: String) async {
        pausedEditorOptionsContinuations.removeValue(forKey: month)?.resume()
    }

    func draftCount() async -> Int {
        drafts.count
    }

    func didCreateFinished() async -> Bool {
        didCreateCallbackFinished
    }

    func isPausedBeforeDidCreate() async -> Bool {
        pausedBeforeDidCreate
    }

    func resumeBeforeDidCreate() async {
        beforeDidCreateContinuation?.resume()
        beforeDidCreateContinuation = nil
    }

    func resumeAfterDidCreate() async {
        afterDidCreateContinuation?.resume()
        afterDidCreateContinuation = nil
    }
}

struct RecordedTransactionUpdate: Sendable {
    let transactionID: String
    let draft: TransactionDraft
    let originalAccountID: String
    let originalMonth: String
}

struct TestError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
