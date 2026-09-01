import Foundation
import SwiftUI
import Observation

enum TransactionFlowKind: String, CaseIterable, Identifiable {
    case spend = "Spend"
    case inflow = "Inflow"

    var id: String { rawValue }
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
    var splitState = TransactionSplitEditorState()
    private let rulePreviewCoordinator = TransactionRulePreviewCoordinator()
    private let submissionCoordinator = TransactionEditorSubmissionCoordinator()
    let deleteReview = TransactionRuleDeleteReview()

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
    var currency: BudgetCurrency = .usd
    var errorMessage: String?
    var submissionState: TransactionSubmissionState {
        submissionCoordinator.submissionState
    }
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
            categoryID: transaction?.isParent == true ? nil : transaction?.category,
            fallbackName: transaction?.isParent == true ? nil : fallbackCategoryName
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
            && hasRequiredPayee
            && selectedAccountID != nil
            && (!isEditing || (editingTransactionID != nil && originalMonth != nil))
            && !isSubmitting
            && !isPreviewingRules
            && !deleteReview.blocksSave
    }

    private var hasRequiredPayee: Bool {
        if isSplit || isEditing {
            return true
        }
        return !payeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var signedAmountCents: Int {
        kind == .spend ? -amountCents : amountCents
    }

    var isSubmitting: Bool {
        submissionCoordinator.isSubmitting
    }

    var isPreviewingRules: Bool {
        rulePreviewCoordinator.isRunning
    }

    var selectedCategoryID: String? {
        categoryState.selectedCategoryID
    }

    var splitRows: [TransactionSplitEditorRow] {
        splitState.splitRows
    }

    var pendingSplitMismatch: TransactionSplitMismatch? {
        splitState.pendingMismatch
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
        currency.formatted(amountCents)
    }

    var amountColor: Color {
        kind == .spend ? ActualistTheme.danger : ActualistTheme.positive
    }

    var isSplit: Bool {
        splitState.isSplit
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

    var splitRemainingCents: Int {
        splitState.remainingCents(parentSignedAmount: signedAmountCents)
    }

    var splitRemainingStatusText: String {
        splitState.remainingStatusText(parentSignedAmount: signedAmountCents, currency: currency)
    }

    var selectedCategoryName: String {
        if (selectedAccountIsOffBudget || categoryState.selectedCategoryFallbackName == "Off budget")
            && !transferAllowsCategory {
            return "Off budget"
        }

        if isSplit {
            return "Split"
        }

        guard let selectedCategoryID else {
            if selectedPayeeIsTransfer {
                // Cross-budget transfers need a category on the budget side.
                return isCategoryReadOnly ? "Account Transfer" : "Select Category"
            }
            if categoryState.selectedCategoryFallbackName == "Account Transfer" {
                return "Account Transfer"
            }
            if let fallback = categoryState.selectedCategoryFallbackName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !fallback.isEmpty {
                return fallback.actualistCategoryNameParts.name
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
        splitState.clearMismatch()
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
            splitState.discard()
            if isCategoryReadOnly {
                categoryState.clear()
            }
        }
    }

    func applyShortcutPrefill(_ prefill: ShortcutEditorPrefill) {
        kind = prefill.direction
        if let amount = prefill.amountMinorUnits {
            amountDigits = String(abs(amount))
        }
        if let notes = prefill.notes {
            self.notes = notes
        }
        if let accountID = prefill.accountID {
            selectedAccountID = accountID
        }
        if let payeeID = prefill.payeeID {
            selectedPayeeID = payeeID
        }
        if let payeeName = prefill.payeeName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !payeeName.isEmpty {
            self.payeeName = payeeName
        }
        if let categoryID = prefill.categoryID {
            categoryState.selectCategory(id: categoryID, name: prefill.categoryName)
        } else if let categoryName = prefill.categoryName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !categoryName.isEmpty {
            categoryState = TransactionEditorCategoryState(categoryID: nil, fallbackName: categoryName)
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

    func beginSplit() {
        guard !isCategoryReadOnly, !isSplit else {
            return
        }

        splitState.convertToSplit(
            parentPayeeID: selectedPayeeID,
            parentPayeeName: payeeName.trimmingCharacters(in: .whitespacesAndNewlines),
            parentCategoryID: selectedCategoryID,
            parentCategoryName: selectedCategoryName == "Select Category" ? nil : selectedCategoryName
        )
        selectedPayeeID = nil
        payeeName = ""
        categoryState.clear()
    }

    func setSplitAmount(rowID: String, value: String) {
        guard !isCategoryReadOnly else {
            return
        }

        splitState.setAmountDigits(id: rowID, value: value, defaultNegative: kind == .spend)
    }

    func formattedSplitAmount(rowID: String) -> String {
        splitState.formattedAmount(rowID: rowID, currency: currency)
    }

    func removeSplit(rowID: String) {
        guard !isCategoryReadOnly else {
            return
        }

        applyCollapse(splitState.removeChild(id: rowID))
    }

    func autoDistributeSplitMismatch() {
        guard !isCategoryReadOnly else {
            return
        }

        do {
            try splitState.autoDistribute(parentSignedAmount: signedAmountCents)
        } catch {
            errorMessage = "The split amounts are too large."
        }
    }

    func updateTotalFromSplits() {
        guard let total = splitState.checkedSplitTotalCents else {
            errorMessage = "The split amounts are too large."
            return
        }
        kind = total < 0 ? .spend : .inflow
        amountDigits = total == 0 ? "" : String(abs(total))
        splitState.clearMismatch()
    }

    private func applyCollapse(_ collapse: TransactionSplitEditorCollapse?) {
        guard let collapse else { return }
        if let categoryID = collapse.categoryID {
            categoryState.selectCategory(id: categoryID, name: collapse.categoryName)
        } else {
            categoryState.clear()
        }
        if selectedPayeeID == nil, let payeeName = collapse.payeeName, !payeeName.isEmpty {
            selectedPayeeID = collapse.payeeID
            self.payeeName = payeeName
        }
    }

    func load(using appState: AppState, prefilledAccount: ActualAccount?) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }
        let repository = appState.transactionRepository
        let preferredAccountIDs = appState.settings.accountOrderByBudgetID[budgetID] ?? []
        currency = appState.localFirstStore.budgetCurrency(budgetID: budgetID)

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

    func confirmRuleDelete(using appState: AppState) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else { return false }
        if let message = await deleteReview.confirmDeletion(
            transactionID: editingTransactionID,
            accountID: originalAccountID,
            date: date,
            budgetID: budgetID,
            repository: appState.transactionRepository,
            didDelete: { appState.recordLocalDataMutation() }
        ) {
            errorMessage = message
            return false
        }
        return true
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
            deleteReview.consider(preview)
            if !preview.deletesTransaction {
                applyRulePreview(preview)
            }
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
        let validation = splitState.validate(
            parentSignedAmount: signedAmountCents
        )
        switch submissionCoordinator.preflight(
            validation: validation,
            draft: makeDraft(),
            editingIdentity: makeEditingIdentity()
        ) {
        case .proceed(let identity, let draft):
            errorMessage = nil
            switch await submissionCoordinator.execute(
                editingIdentity: identity,
                draft: draft,
                budgetID: budgetID,
                repository: repository
            ) {
            case .succeeded:
                return true
            case .failed(let message):
                errorMessage = message
                return false
            }
        case .rejectedSplitOverflow(let message):
            errorMessage = message
            return false
        case .rejectedSplitMismatch,
             .rejectedInvalidDraft,
             .rejectedAlreadySubmitting,
             .rejectedInvalidEditingIdentity:
            return false
        }
    }

    private func makeDraft() -> TransactionDraft? {
        TransactionDraftBuilder.makeSubmissionDraft(from: makeSubmissionInput())
    }

    private func makeRulePreviewRequest(budgetID: String) -> TransactionRulePreviewRequest? {
        TransactionDraftBuilder.makeRulePreviewRequest(from: makeRulePreviewInput(budgetID: budgetID))
    }

    private func makeEditingIdentity() -> TransactionEditorSubmissionCoordinator.EditingIdentity? {
        if isEditing {
            guard let editingTransactionID,
                  let originalAccountID,
                  let originalMonth else {
                return nil
            }
            return .updating(
                transactionID: editingTransactionID,
                originalAccountID: originalAccountID,
                originalMonth: originalMonth
            )
        }
        return .creating
    }

    private func makeSubmissionInput() -> TransactionDraftBuilder.SubmissionInput {
        TransactionDraftBuilder.SubmissionInput(
            accountID: selectedAccountID,
            amountCents: amountCents,
            kind: kind,
            payeeID: selectedPayeeID,
            payeeName: payeeName,
            notes: notes,
            cleared: isCleared,
            categoryID: selectedCategoryID,
            isCategoryReadOnly: isCategoryReadOnly,
            isSplit: isSplit,
            isTransfer: selectedPayeeIsTransfer,
            realImportedPayee: originalImportedPayee,
            reconciled: originalReconciled,
            originalIsParent: originalIsParent,
            date: date,
            splitDrafts: splitState.splitDrafts()
        )
    }

    private func makeRulePreviewInput(budgetID: String) -> TransactionDraftBuilder.RulePreviewInput {
        TransactionDraftBuilder.RulePreviewInput(
            accountID: selectedAccountID,
            amountCents: amountCents,
            kind: kind,
            payeeID: selectedPayeeID,
            payeeName: payeeName,
            notes: notes,
            cleared: isCleared,
            categoryID: selectedCategoryID,
            isCategoryReadOnly: isCategoryReadOnly,
            isTransfer: selectedPayeeIsTransfer,
            realImportedPayee: originalImportedPayee,
            reconciled: originalReconciled,
            originalIsParent: originalIsParent,
            date: date,
            budgetID: budgetID,
            categorySelection: categoryState.selection
        )
    }

    private func applyRulePreview(_ preview: TransactionRulePreview) {
        guard !isSplit, !isCategoryReadOnly else {
            return
        }

        if !preview.splits.isEmpty {
            splitState.applyRuleSplits(preview.splits)
            categoryState.clear()
        } else if let categoryID = preview.categoryID {
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
        splitState.load(from: transaction)
        if transaction.isParent {
            categoryState.clear()
        }

        if transaction.isParent {
            payeeName = transaction.payeeName ?? ""
            return
        }

        if let fallbackPayeeName,
           !fallbackPayeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           fallbackPayeeName != "Unknown Payee",
           fallbackPayeeName != "(No payee)",
           fallbackPayeeName != "Split (no payee)" {
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
        let payeeNames = payees.reduce(into: [String: String]()) { result, payee in
            guard let id = payee.id else { return }
            result[id] = payeeOptions.displayName(for: payee)
        }
        let transferPayeeIDs = Set(payees.compactMap { payee -> String? in
            guard payee.transferAccount != nil else { return nil }
            return payee.id
        })
        splitState.resolveNames(
            categoryNames: categoryNames,
            payeeNames: payeeNames,
            transferPayeeIDs: transferPayeeIDs
        )
        resolvePrefillCategoryIfNeeded()
    }

    private func resolvePrefillCategoryIfNeeded() {
        guard selectedCategoryID == nil,
              let fallback = categoryState.selectedCategoryFallbackName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fallback.isEmpty else {
            return
        }
        let match = categories.first { category in
            category.name.localizedCaseInsensitiveCompare(fallback) == .orderedSame
                || category.name.actualistCategoryNameParts.name.localizedCaseInsensitiveCompare(fallback) == .orderedSame
        }
        guard let match, let id = match.id else {
            return
        }
        categoryState.selectCategory(id: id, name: match.name)
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
            splitState.discard()
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
