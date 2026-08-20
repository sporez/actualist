import Foundation
import SwiftUI
import Observation

enum TransactionFlowKind: String, CaseIterable, Identifiable {
    case spend = "Spend"
    case inflow = "Inflow"

    var id: String { rawValue }
}

enum TransactionSubmissionState: Equatable {
    case draft
    case submitting
    case refetching
    case clean
    case failed(String)
}

@MainActor
@Observable
final class TransactionEditorViewModel {
    private static let maximumAmountDigitCount = 16
    private let editingTransactionID: String?
    private let originalAccountID: String?
    private let originalMonth: String?
    private let originalImportedPayee: String?
    private let originalReconciled: Bool
    private let originalIsParent: Bool
    private var categoryState = TransactionEditorCategoryState()
    private let rulePreviewCoordinator = TransactionRulePreviewCoordinator()

    var kind: TransactionFlowKind = .spend
    var amountDigits = ""
    var payeeName = ""
    var selectedPayeeID: String?
    var selectedAccountID: String?
    var date = Date()
    var notes = ""
    var isCleared = false
    var accounts: [ActualAccount] = []
    var categories: [ActualCategory] = []
    var categoryGroups: [TransactionEditorCategoryGroup] = []
    var payees: [ActualPayee] = []
    var isLoading = false
    var isLoadingCategoryBalances = false
    var errorMessage: String?
    var submissionState: TransactionSubmissionState = .draft
    private var loadedCategoryBalanceMonth: String?

    init(
        editing transaction: ActualTransaction? = nil,
        payeeName fallbackPayeeName: String? = nil,
        categoryName fallbackCategoryName: String? = nil
    ) {
        editingTransactionID = transaction?.id
        originalAccountID = transaction?.account
        originalMonth = transaction?.date.actualYearMonth
        originalImportedPayee = transaction?.importedPayee
        originalReconciled = transaction?.reconciled ?? false
        originalIsParent = transaction?.isParent ?? false
        categoryState = TransactionEditorCategoryState(
            categoryID: transaction?.category,
            fallbackName: fallbackCategoryName
        )

        if let transaction {
            apply(transaction, payeeName: fallbackPayeeName)
        }
    }

    var isEditing: Bool {
        originalAccountID != nil
    }

    var title: String {
        isEditing ? "Edit Transaction" : "Add Transaction"
    }

    var canSave: Bool {
        amountCents > 0
            && !payeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedAccountID != nil
            && (!isEditing || (editingTransactionID != nil && originalMonth != nil))
            && !isSubmitting
            && !isPreviewingRules
    }

    var isSubmitting: Bool {
        switch submissionState {
        case .submitting, .refetching:
            true
        case .draft, .clean, .failed:
            false
        }
    }

    var isPreviewingRules: Bool {
        rulePreviewCoordinator.isRunning
    }

    var selectedCategoryID: String? {
        categoryState.selectedCategoryID
    }

    var splitRows: [TransactionSplitEditorRow] {
        categoryState.splitRows
    }

    var pendingSplitMismatch: TransactionSplitMismatch? {
        categoryState.pendingMismatch
    }

    var saveButtonTitle: String {
        switch submissionState {
        case .draft, .failed:
            isEditing ? "Update" : "Save"
        case .submitting:
            isEditing ? "Updating" : "Saving"
        case .refetching:
            "Refreshing"
        case .clean:
            isEditing ? "Updated" : "Saved"
        }
    }

    var amountCents: Int {
        Int(amountDigits) ?? 0
    }

    var formattedAmount: String {
        Money(minorUnits: amountCents).formatted()
    }

    var amountColor: Color {
        kind == .spend ? ActualistTheme.danger : ActualistTheme.positive
    }

    var isSplit: Bool {
        categoryState.isSplit
    }

    var isSelectingSplit: Bool {
        categoryState.isSelectingSplit
    }

    var canRemoveSplitRow: Bool {
        categoryState.canRemoveSplitRow
    }

    var isCategoryReadOnly: Bool {
        if selectedPayeeIsTransfer {
            return !transferAllowsCategory
        }
        return selectedAccountIsOffBudget || categoryState.selectedCategoryFallbackName == "Off budget"
    }

    private var selectedAccountIsOffBudget: Bool {
        accounts.first(where: { $0.id == selectedAccountID })?.offbudget ?? false
    }

    private var transferAllowsCategory: Bool {
        guard selectedPayeeIsTransfer,
              let selectedPayeeID,
              let destinationAccountID = payees.first(where: { $0.id == selectedPayeeID })?.transferAccount else {
            return false
        }
        let sourceOffBudget = accounts.first(where: { $0.id == selectedAccountID })?.offbudget ?? false
        let destinationOffBudget = accounts.first(where: { $0.id == destinationAccountID })?.offbudget ?? false
        return sourceOffBudget != destinationOffBudget
    }

    var splitTotalCents: Int {
        categoryState.splitTotalCents
    }

    var splitRemainingCents: Int {
        categoryState.splitRemainingCents(transactionTotal: amountCents)
    }

    var splitRemainingText: String {
        splitRemainingCents.actualMoney.formatted()
    }

    var splitRemainingStatusText: String {
        if splitRemainingCents < 0 {
            return "\(Int(clamping: splitRemainingCents.magnitude).actualMoney.formatted()) Over"
        }

        return "\(splitRemainingText) Remaining"
    }

    var selectedCategoryName: String {
        if (selectedAccountIsOffBudget || categoryState.selectedCategoryFallbackName == "Off budget")
            && !transferAllowsCategory {
            return "Off budget"
        }

        if let summaryName = categoryState.summaryName, categoryState.isSplit {
            return summaryName
        }

        guard let selectedCategoryID else {
            if selectedPayeeIsTransfer {
                // Cross-budget transfers need a category on the budget side.
                return isCategoryReadOnly ? "Account Transfer" : "Select Category"
            }
            if categoryState.selectedCategoryFallbackName == "Account Transfer" {
                return "Account Transfer"
            }
            return isEditing ? "Uncategorized" : "Select Category"
        }

        guard let category = categories.first(where: { $0.id == selectedCategoryID }) else {
            return categoryState.selectedCategoryFallbackName?.actualistCategoryNameParts.name ?? "Select Category"
        }

        return category.name.actualistCategoryNameParts.name
    }

    var selectedAccountName: String {
        guard let selectedAccountID,
              let account = accounts.first(where: { $0.id == selectedAccountID }) else {
            return "Select Account"
        }

        return account.name
    }

    var selectedPayeeName: String {
        let trimmed = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Select Payee"
        }

        if let selectedPayeeID,
           payees.first(where: { $0.id == selectedPayeeID })?.transferAccount != nil {
            return "Transfer: \(trimmed)"
        }

        return trimmed
    }

    private var selectedPayeeIsTransfer: Bool {
        guard let selectedPayeeID else {
            return false
        }
        return payees.first(where: { $0.id == selectedPayeeID })?.transferAccount != nil
    }

    private var payeeOptions: TransactionEditorPayeeOptions {
        TransactionEditorPayeeOptions(accounts: accounts, payees: payees)
    }

    var payeeSections: [TransactionEditorPayeeSection] {
        payeeOptions.sections
    }

    func setAmountInput(_ value: String) {
        amountDigits = Self.sanitizedAmountDigits(value)
        categoryState.clearMismatch()
    }

    func categorySelectionGroups(matching searchText: String) -> [TransactionEditorCategoryGroup] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = categoryGroups.isEmpty ? fallbackCategorySelectionGroups() : categoryGroups

        guard !trimmedSearch.isEmpty else {
            return groups
        }

        return groups.compactMap { group in
            let options = group.options.filter { option in
                option.title.localizedCaseInsensitiveContains(trimmedSearch)
                    || group.name.localizedCaseInsensitiveContains(trimmedSearch)
            }

            guard !options.isEmpty else {
                return nil
            }

            return TransactionEditorCategoryGroup(
                id: group.id,
                name: group.name,
                options: options
            )
        }
    }

    func selectPayee(_ payee: ActualPayee) {
        selectedPayeeID = payee.id
        payeeName = payeeOptions.displayName(for: payee)
        if payee.transferAccount != nil {
            categoryState.discardSplitSelection()
            if isCategoryReadOnly {
                categoryState.clear()
            }
        }
    }

    func selectAccount(_ account: ActualAccount) {
        selectedAccountID = account.id
        normalizeCategoryForSelectedAccount()
    }

    func useCustomPayee(_ name: String) {
        selectedPayeeID = nil
        payeeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearCategory() {
        categoryState.clear()
    }

    func selectCategory(_ category: ActualCategory) {
        guard !isCategoryReadOnly else {
            return
        }

        guard let categoryID = category.id else {
            return
        }

        categoryState.selectCategory(id: categoryID, name: category.name)
    }

    func selectCategory(_ option: TransactionEditorCategoryOption) {
        guard !isCategoryReadOnly else {
            return
        }

        categoryState.selectCategory(id: option.id, name: option.title)
    }

    func isSplitCategorySelected(_ option: TransactionEditorCategoryOption) -> Bool {
        categoryState.containsSplitCategory(id: option.id)
    }

    func beginSplitSelection() {
        guard !isCategoryReadOnly else {
            return
        }

        categoryState.beginSplitSelection()
    }

    func toggleSplitCategory(_ option: TransactionEditorCategoryOption) {
        guard !isCategoryReadOnly else {
            return
        }

        categoryState.toggleSplitCategory(id: option.id, name: option.title)
    }

    func finalizeSplitSelection() {
        guard !isCategoryReadOnly else {
            return
        }

        categoryState.finalizeSplitSelection()
    }

    func setSplitAmount(rowID: String, value: String) {
        guard !isCategoryReadOnly else {
            return
        }

        categoryState.setSplitAmount(rowID: rowID, value: value)
    }

    func formattedSplitAmount(rowID: String) -> String {
        categoryState.formattedSplitAmount(rowID: rowID)
    }

    func removeSplit(rowID: String) {
        guard !isCategoryReadOnly else {
            return
        }

        categoryState.removeSplit(rowID: rowID)
    }

    func autoDistributeSplitMismatch() {
        guard !isCategoryReadOnly else {
            return
        }

        do {
            try categoryState.autoDistributeMismatch(transactionTotal: amountCents)
        } catch {
            errorMessage = "The split amounts are too large."
        }
    }

    func updateTotalFromSplits() {
        guard let total = categoryState.checkedSplitTotalCents else {
            errorMessage = "The split amounts are too large."
            return
        }
        amountDigits = total == 0 ? "" : String(total)
        categoryState.clearMismatch()
    }

    func adjustSplitsManually() {
        guard !isCategoryReadOnly else {
            return
        }

        categoryState.clearMismatch()
    }

    func load(using appState: AppState, prefilledAccount: ActualAccount?) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }
        let repository = appState.transactionRepository
        let preferredAccountIDs = appState.settings.accountOrderByBudgetID[budgetID] ?? []

        if !isEditing, let prefilledAccount {
            selectedAccountID = prefilledAccount.id
        }

        isLoading = true
        errorMessage = nil

        do {
            let month = YearMonth(date: date).rawValue
            apply(
                try await repository.editorOptions(budgetID: budgetID, month: month),
                loadedMonth: month,
                preferredAccountIDs: preferredAccountIDs
            )

            if selectedAccountID == nil {
                let defaultAccountID = appState.defaultAccountID(forBudgetID: budgetID)
                if let defaultAccountID, accounts.contains(where: { $0.id == defaultAccountID }) {
                    selectedAccountID = defaultAccountID
                } else {
                    selectedAccountID = accounts.first?.id
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func refreshCategoryBalancesIfNeeded(using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }
        let repository = appState.transactionRepository
        let preferredAccountIDs = appState.settings.accountOrderByBudgetID[budgetID] ?? []

        await refreshCategoryBalancesIfNeeded(
            budgetID: budgetID,
            repository: repository,
            preferredAccountIDs: preferredAccountIDs
        )
    }

    func refreshCategoryBalancesIfNeeded(
        budgetID: String,
        repository: any TransactionRepositoryProtocol,
        preferredAccountIDs: [String] = []
    ) async {
        let month = YearMonth(date: date).rawValue
        guard loadedCategoryBalanceMonth != month else {
            return
        }

        isLoadingCategoryBalances = true
        defer { isLoadingCategoryBalances = false }

        do {
            apply(
                try await repository.editorOptions(budgetID: budgetID, month: month),
                loadedMonth: month,
                preferredAccountIDs: preferredAccountIDs
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submit(using appState: AppState) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return false
        }
        let repository = appState.transactionRepository

        return await submit(budgetID: budgetID, repository: repository)
    }

    func previewRules(
        budgetID: String,
        repository: any TransactionRepositoryProtocol,
        currentBudgetID: (@MainActor @Sendable () -> String?)? = nil
    ) async {
        guard !isSplit, !isCategoryReadOnly else {
            return
        }

        guard !selectedPayeeIsTransfer else {
            return
        }

        guard let request = makeRulePreviewRequest(budgetID: budgetID) else {
            return
        }

        let outcome = await rulePreviewCoordinator.preview(
            request: request,
            repository: repository,
            currentRequest: { [weak self] in
                let liveBudgetID = currentBudgetID?() ?? budgetID
                guard liveBudgetID == budgetID else {
                    return nil
                }
                return self?.makeRulePreviewRequest(budgetID: budgetID)
            }
        )
        switch outcome {
        case .applied(let preview):
            applyRulePreview(preview)
            errorMessage = nil
        case .unsupported:
            errorMessage = nil
        case .failed(let message):
            errorMessage = message
        case .stale:
            break
        }
    }

    func submit(
        budgetID: String,
        repository: any TransactionRepositoryProtocol
    ) async -> Bool {
        let submitsAsTransfer = selectedPayeeIsTransfer

        switch categoryState.validate(
            transactionTotal: amountCents,
            submitsAsTransfer: submitsAsTransfer
        ) {
        case .overflow:
            let message = "The split amounts are too large."
            submissionState = .failed(message)
            errorMessage = message
            return false
        case .mismatch:
            return false
        case .valid:
            break
        }

        guard !isSubmitting, let draft = makeDraft() else {
            return false
        }

        guard !isEditing || (editingTransactionID != nil && originalAccountID != nil && originalMonth != nil) else {
            return false
        }

        submissionState = .submitting
        errorMessage = nil

        do {
            if isEditing {
                guard let editingTransactionID,
                      let originalAccountID,
                      let originalMonth else {
                    return false
                }

                _ = try await repository.updateTransactionAndRefresh(
                    editingTransactionID,
                    with: draft,
                    budgetID: budgetID,
                    originalAccountID: originalAccountID,
                    originalMonth: originalMonth
                ) { [weak self] in
                    await MainActor.run {
                        self?.submissionState = .refetching
                    }
                }
            } else {
                _ = try await repository.createTransactionAndRefresh(
                    draft,
                    budgetID: budgetID
                ) { [weak self] in
                    await MainActor.run {
                        self?.submissionState = .refetching
                    }
                }
            }
            submissionState = .clean
            return true
        } catch {
            let message = error.localizedDescription
            submissionState = .failed(message)
            errorMessage = message
            return false
        }
    }

    private func makeDraft() -> TransactionDraft? {
        guard let selectedAccountID else {
            return nil
        }

        let trimmedPayee = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard amountCents > 0, !trimmedPayee.isEmpty else {
            return nil
        }

        let signedAmount = kind == .spend ? -amountCents : amountCents
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        return TransactionDraft(
            accountID: selectedAccountID,
            date: date,
            amountMinorUnits: signedAmount,
            payeeID: selectedPayeeID,
            payeeName: trimmedPayee,
            categoryID: isCategoryReadOnly || isSplit ? nil : selectedCategoryID,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            cleared: isCleared,
            isTransfer: selectedPayeeIsTransfer,
            importedPayee: originalImportedPayee,
            reconciled: originalReconciled,
            isParent: isSplit || originalIsParent,
            splits: selectedPayeeIsTransfer || isCategoryReadOnly
                ? []
                : categoryState.splitDrafts(sign: kind == .spend ? -1 : 1)
        )
    }

    private func makeRulePreviewRequest(budgetID: String) -> TransactionRulePreviewRequest? {
        guard let selectedAccountID else {
            return nil
        }

        let trimmedPayee = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPayee.isEmpty else {
            return nil
        }

        let signedAmount: Int
        if amountCents > 0 {
            signedAmount = kind == .spend ? -amountCents : amountCents
        } else {
            signedAmount = 0
        }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        // Manually-added transactions have no imported payee, but the rules Actual
        // records when categorizing an imported transaction match on `imported_payee`.
        // Feed the entered payee name as that text for preview matching only; the
        // saved draft keeps its real (nil) imported payee.
        let rulePreviewImportedPayee = originalImportedPayee ?? trimmedPayee

        return TransactionRulePreviewRequest(
            budgetID: budgetID,
            draft: TransactionDraft(
                accountID: selectedAccountID,
                date: date,
                amountMinorUnits: signedAmount,
                payeeID: selectedPayeeID,
                payeeName: trimmedPayee,
                categoryID: isCategoryReadOnly ? nil : selectedCategoryID,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                cleared: isCleared,
                isTransfer: selectedPayeeIsTransfer,
                importedPayee: rulePreviewImportedPayee,
                reconciled: originalReconciled,
                isParent: originalIsParent
            ),
            categorySelection: categoryState.selection
        )
    }

    private func applyRulePreview(_ preview: TransactionRulePreview) {
        guard !isSplit, !isCategoryReadOnly else {
            return
        }

        if let categoryID = preview.categoryID {
            let categoryName = categories.first(where: { $0.id == categoryID })?.name
            categoryState.selectCategory(id: categoryID, name: categoryName)
        } else {
            categoryState.clear()
        }
        notes = preview.notes ?? ""
        if let accountID = preview.accountID, accounts.contains(where: { $0.id == accountID }) {
            selectedAccountID = accountID
        }
        if let payeeID = preview.payeeID,
           let payee = payees.first(where: { $0.id == payeeID }) {
            selectPayee(payee)
        }
        if let amount = preview.amountMinorUnits {
            kind = amount < 0 ? .spend : .inflow
            amountDigits = String(amount.magnitude)
        }
        if let date = preview.date { self.date = date }
        if let cleared = preview.cleared { isCleared = cleared }
    }

    private func apply(_ transaction: ActualTransaction, payeeName fallbackPayeeName: String?) {
        let amount = transaction.amount ?? 0
        kind = amount >= 0 ? .inflow : .spend
        amountDigits = String(amount.magnitude)
        selectedAccountID = transaction.account
        selectedPayeeID = transaction.payee
        date = transaction.date.actualDate ?? date
        notes = transaction.notes ?? ""
        isCleared = transaction.cleared?.boolValue ?? false
        categoryState.load(
            categoryID: transaction.category,
            fallbackName: categoryState.selectedCategoryFallbackName,
            subtransactions: transaction.subtransactions
        )

        if let fallbackPayeeName,
           !fallbackPayeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           fallbackPayeeName != "Unknown Payee" {
            payeeName = fallbackPayeeName
        } else if let transactionPayeeName = transaction.payeeName,
                  !transactionPayeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payeeName = transactionPayeeName
        } else if let importedPayee = transaction.importedPayee,
                  !importedPayee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payeeName = importedPayee
        }
    }

    private func applyLoadedOptionNamesIfNeeded() {
        if let selectedPayeeID,
           let matchedPayee = payees.first(where: { $0.id == selectedPayeeID }) {
            payeeName = payeeOptions.displayName(for: matchedPayee)
        }

        let categoryNames = categories.reduce(into: [String: String]()) { result, category in
            guard let id = category.id else { return }
            result[id] = category.name.actualistCategoryNameParts.name
        }
        categoryState.resolveNames(categoryNames)
    }

    func apply(_ options: TransactionEditorOptions, loadedMonth: String, preferredAccountIDs: [String] = []) {
        accounts = AccountOrderPreference.ordered(
            options.accounts,
            preferredIDs: preferredAccountIDs
        )
        categories = options.categories
        categoryGroups = options.categoryGroups
        payees = options.payees
        loadedCategoryBalanceMonth = loadedMonth
        applyLoadedOptionNamesIfNeeded()
        normalizeCategoryForSelectedAccount()
    }

    private func normalizeCategoryForSelectedAccount() {
        if selectedAccountIsOffBudget && !transferAllowsCategory {
            clearCategory()
        }
    }

    private func fallbackCategorySelectionGroups() -> [TransactionEditorCategoryGroup] {
        let incomeCategories = categories.filter { ($0.isIncome ?? false) }
        let expenseCategories = categories.filter { !($0.isIncome ?? false) }

        var result: [TransactionEditorCategoryGroup] = []

        if let incomeID = incomeCategories.first(where: { $0.id != nil })?.id {
            result.append(TransactionEditorCategoryGroup(
                id: "to-budget",
                name: "To Budget",
                options: [
                    TransactionEditorCategoryOption(
                        id: incomeID,
                        title: "To Budget",
                        amount: nil,
                        valueText: nil
                    )
                ]
            ))
        }

        let expenseOptions = expenseCategories.compactMap { category -> TransactionEditorCategoryOption? in
            guard let categoryID = category.id else {
                return nil
            }

            return TransactionEditorCategoryOption(
                id: categoryID,
                title: category.name.actualistCategoryNameParts.name,
                amount: nil,
                valueText: nil
            )
        }

        if !expenseOptions.isEmpty {
            result.append(TransactionEditorCategoryGroup(
                id: "categories",
                name: "Categories",
                options: expenseOptions
            ))
        }

        return result
    }

    private static func sanitizedAmountDigits(_ value: String) -> String {
        let trimmed = value.filter(\.isNumber).drop(while: { $0 == "0" })
        return String(trimmed.prefix(maximumAmountDigitCount))
    }
}
