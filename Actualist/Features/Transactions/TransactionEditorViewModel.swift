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

struct TransactionSplitEditorRow: Identifiable, Hashable {
    let id: String
    var transactionID: String?
    var categoryID: String
    var categoryName: String
    var amountDigits: String

    var amountCents: Int {
        Int(amountDigits) ?? 0
    }
}

struct TransactionSplitMismatch: Equatable {
    let transactionTotal: Int
    let splitTotal: Int

    var difference: Int {
        transactionTotal - splitTotal
    }
}

struct TransactionEditorPayeeOption: Identifiable, Hashable {
    let payee: ActualPayee
    let transferAccountName: String?

    var id: String {
        payee.id ?? payee.name
    }

    var title: String {
        transferAccountName ?? payee.name
    }

    var isTransfer: Bool {
        payee.transferAccount != nil
    }
}

struct TransactionEditorPayeeSection: Identifiable, Hashable {
    static let transferTitle = "Transfer To/From"

    enum Kind: String {
        case payees
        case transfers
    }

    let kind: Kind
    let options: [TransactionEditorPayeeOption]

    var id: Kind {
        kind
    }

    var title: String? {
        switch kind {
        case .payees:
            nil
        case .transfers:
            Self.transferTitle
        }
    }
}

@MainActor
@Observable
final class TransactionEditorViewModel {
    private static let maximumAmountDigitCount = 16
    private let editingTransactionID: String?
    private let originalAccountID: String?
    private let originalMonth: String?
    private var selectedCategoryFallbackName: String?

    var kind: TransactionFlowKind = .spend
    var amountDigits = ""
    var payeeName = ""
    var selectedPayeeID: String?
    var selectedCategoryID: String?
    var selectedAccountID: String?
    var splitRows: [TransactionSplitEditorRow] = []
    var pendingSplitMismatch: TransactionSplitMismatch?
    var date = Date()
    var notes = ""
    var isCleared = false
    var accounts: [ActualAccount] = []
    var categories: [ActualCategory] = []
    var categoryGroups: [TransactionEditorCategoryGroup] = []
    var payees: [ActualPayee] = []
    var isLoading = false
    var isLoadingCategoryBalances = false
    var isPreviewingRules = false
    var errorMessage: String?
    var submissionState: TransactionSubmissionState = .draft
    private var rulePreviewSequence = 0
    private var loadedCategoryBalanceMonth: String?

    init(
        editing transaction: ActualTransaction? = nil,
        payeeName fallbackPayeeName: String? = nil,
        categoryName fallbackCategoryName: String? = nil
    ) {
        editingTransactionID = transaction?.id
        originalAccountID = transaction?.account
        originalMonth = transaction?.date.actualYearMonth
        selectedCategoryFallbackName = fallbackCategoryName

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
        splitRows.count >= 2
    }

    var canRemoveSplitRow: Bool {
        splitRows.count >= 2
    }

    var isCategoryReadOnly: Bool {
        if selectedPayeeIsTransfer {
            return !transferAllowsCategory
        }
        return selectedAccountIsOffBudget || selectedCategoryFallbackName == "Off budget"
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
        checkedSplitTotalCents ?? Int.max
    }

    var splitRemainingCents: Int {
        amountCents.subtractingReportingOverflow(splitTotalCents).partialValue
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
        if (selectedAccountIsOffBudget || selectedCategoryFallbackName == "Off budget")
            && !transferAllowsCategory {
            return "Off budget"
        }

        if splitRows.count >= 2 {
            let names = splitRows.map(\.categoryName)
            if names.count <= 2 {
                return names.joined(separator: ", ")
            }
            return "Split (\(splitRows.count))"
        }

        guard let selectedCategoryID else {
            if selectedPayeeIsTransfer {
                // Cross-budget transfers need a category on the budget side.
                return isCategoryReadOnly ? "Account Transfer" : "Select Category"
            }
            if let selectedCategoryFallbackName,
               selectedCategoryFallbackName == "Account Transfer" {
                return selectedCategoryFallbackName
            }
            return isEditing ? "Uncategorized" : "Select Category"
        }

        guard let category = categories.first(where: { $0.id == selectedCategoryID }) else {
            return selectedCategoryFallbackName?.actualistCategoryNameParts.name ?? "Select Category"
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

    func setAmountInput(_ value: String) {
        amountDigits = String(
            value.filter(\.isNumber)
                .trimmingLeadingZeros()
                .prefix(Self.maximumAmountDigitCount)
        )
        pendingSplitMismatch = nil
    }

    func filteredPayees(matching searchText: String) -> [ActualPayee] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            return payees
        }

        return payees.filter { payee in
            payee.name.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    func payeeSections(matching searchText: String) -> [TransactionEditorPayeeSection] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = payees.compactMap(payeeOption(for:))
        let filteredOptions: [TransactionEditorPayeeOption]

        if trimmedSearch.isEmpty {
            filteredOptions = options
        } else {
            filteredOptions = options.filter { option in
                option.title.localizedCaseInsensitiveContains(trimmedSearch)
                    || option.transferAccountName?.localizedCaseInsensitiveContains(trimmedSearch) == true
                    || (option.isTransfer
                        && TransactionEditorPayeeSection.transferTitle.localizedCaseInsensitiveContains(trimmedSearch))
            }
        }

        let transferOptions = filteredOptions.filter(\.isTransfer)
        let regularOptions = filteredOptions.filter { !$0.isTransfer }

        if trimmedSearch.isEmpty {
            return payeeSections(regularOptions: regularOptions, transferOptions: transferOptions)
        }

        return payeeSections(regularOptions: regularOptions, transferOptions: transferOptions, transfersFirst: true)
    }

    func shouldOfferCustomPayee(matching searchText: String) -> Bool {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            return false
        }

        return !payees.contains { payee in
            payee.name.caseInsensitiveCompare(trimmedSearch) == .orderedSame
                || transferAccountName(for: payee)?.caseInsensitiveCompare(trimmedSearch) == .orderedSame
        }
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
        // Transfer payees use the linked account name for display.
        payeeName = transferAccountName(for: payee) ?? payee.name
        if payee.transferAccount != nil {
            splitRows = []
            pendingSplitMismatch = nil
            if isCategoryReadOnly {
                selectedCategoryID = nil
                selectedCategoryFallbackName = nil
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
        selectedCategoryID = nil
        selectedCategoryFallbackName = nil
        splitRows = []
        pendingSplitMismatch = nil
    }

    func selectCategory(_ category: ActualCategory) {
        guard !isCategoryReadOnly else {
            return
        }

        guard let categoryID = category.id else {
            return
        }

        selectedCategoryID = categoryID
        selectedCategoryFallbackName = category.name
        splitRows = []
        pendingSplitMismatch = nil
    }

    func selectCategory(_ option: TransactionEditorCategoryOption) {
        guard !isCategoryReadOnly else {
            return
        }

        selectedCategoryID = option.id
        selectedCategoryFallbackName = option.title
        splitRows = []
        pendingSplitMismatch = nil
    }

    func isSplitCategorySelected(_ option: TransactionEditorCategoryOption) -> Bool {
        splitRows.contains { $0.categoryID == option.id }
    }

    func beginSplitSelection() {
        guard !isCategoryReadOnly else {
            return
        }

        pendingSplitMismatch = nil

        guard splitRows.isEmpty, let selectedCategoryID else {
            return
        }

        splitRows.append(
            TransactionSplitEditorRow(
                id: selectedCategoryID,
                transactionID: nil,
                categoryID: selectedCategoryID,
                categoryName: selectedCategoryName,
                amountDigits: ""
            )
        )
    }

    func toggleSplitCategory(_ option: TransactionEditorCategoryOption) {
        guard !isCategoryReadOnly else {
            return
        }

        pendingSplitMismatch = nil
        if let index = splitRows.firstIndex(where: { $0.categoryID == option.id }) {
            splitRows.remove(at: index)
        } else {
            splitRows.append(
                TransactionSplitEditorRow(
                    id: option.id,
                    transactionID: nil,
                    categoryID: option.id,
                    categoryName: option.title,
                    amountDigits: ""
                )
            )
        }

        if splitRows.count >= 2 {
            selectedCategoryID = nil
            selectedCategoryFallbackName = nil
        }
    }

    func finalizeSplitSelection() {
        guard !isCategoryReadOnly else {
            return
        }

        if splitRows.count == 1, let row = splitRows.first {
            selectedCategoryID = row.categoryID
            selectedCategoryFallbackName = row.categoryName
            splitRows = []
        } else if splitRows.count >= 2 {
            selectedCategoryID = nil
            selectedCategoryFallbackName = nil
        }
    }

    func setSplitAmount(rowID: String, value: String) {
        guard !isCategoryReadOnly else {
            return
        }

        guard let index = splitRows.firstIndex(where: { $0.id == rowID }) else {
            return
        }

        splitRows[index].amountDigits = String(
            value.filter(\.isNumber)
                .trimmingLeadingZeros()
                .prefix(Self.maximumAmountDigitCount)
        )
        pendingSplitMismatch = nil
    }

    func formattedSplitAmount(rowID: String) -> String {
        guard let row = splitRows.first(where: { $0.id == rowID }),
              row.amountCents > 0 else {
            return ""
        }

        return Self.formattedAmountInput(cents: row.amountCents)
    }

    func removeSplit(rowID: String) {
        guard !isCategoryReadOnly else {
            return
        }

        guard canRemoveSplitRow else {
            return
        }

        guard let index = splitRows.firstIndex(where: { $0.id == rowID }) else {
            return
        }

        splitRows.remove(at: index)
        pendingSplitMismatch = nil
        if splitRows.count == 1, let row = splitRows.first {
            selectedCategoryID = row.categoryID
            selectedCategoryFallbackName = row.categoryName
            splitRows = []
        }
    }

    func autoDistributeSplitMismatch() {
        guard !isCategoryReadOnly else {
            return
        }

        guard isSplit else {
            return
        }

        let currentTotal = splitTotalCents
        let difference = amountCents - currentTotal
        guard difference != 0 else {
            pendingSplitMismatch = nil
            return
        }

        let index = splitRows.lastIndex { $0.amountCents > 0 } ?? splitRows.indices.last
        guard let index else {
            return
        }

        let (adjustedAmount, overflow) = splitRows[index].amountCents.addingReportingOverflow(difference)
        guard !overflow else {
            errorMessage = "The split amounts are too large."
            return
        }
        let adjusted = max(0, adjustedAmount)
        splitRows[index].amountDigits = String(adjusted)
        pendingSplitMismatch = nil
    }

    func updateTotalFromSplits() {
        amountDigits = splitTotalCents == 0 ? "" : String(splitTotalCents)
        pendingSplitMismatch = nil
    }

    func adjustSplitsManually() {
        guard !isCategoryReadOnly else {
            return
        }

        pendingSplitMismatch = nil
    }

    func load(using appState: AppState, prefilledAccount: ActualAccount?) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }
        let repository = appState.transactionRepository

        if !isEditing, let prefilledAccount {
            selectedAccountID = prefilledAccount.id
        }

        isLoading = true
        errorMessage = nil

        do {
            let month = YearMonth(date: date).rawValue
            apply(try await repository.editorOptions(budgetID: budgetID, month: month), loadedMonth: month)

            if selectedAccountID == nil {
                selectedAccountID = accounts.first?.id
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

        await refreshCategoryBalancesIfNeeded(budgetID: budgetID, repository: repository)
    }

    func refreshCategoryBalancesIfNeeded(
        budgetID: String,
        repository: any TransactionRepositoryProtocol
    ) async {
        let month = YearMonth(date: date).rawValue
        guard loadedCategoryBalanceMonth != month else {
            return
        }

        isLoadingCategoryBalances = true
        defer { isLoadingCategoryBalances = false }

        do {
            apply(try await repository.editorOptions(budgetID: budgetID, month: month), loadedMonth: month)
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
        repository: any TransactionRepositoryProtocol
    ) async {
        guard !isSplit, !isCategoryReadOnly else {
            return
        }

        guard !selectedPayeeIsTransfer else {
            return
        }

        guard let draft = makeRulePreviewDraft() else {
            return
        }

        rulePreviewSequence += 1
        let requestSequence = rulePreviewSequence
        isPreviewingRules = true

        do {
            let preview = try await repository.previewRules(for: draft, budgetID: budgetID)
            if requestSequence == rulePreviewSequence,
               matchesCurrentRulePreviewDraft(draft) {
                applyRulePreview(preview)
                errorMessage = nil
            }
        } catch {
            if requestSequence == rulePreviewSequence {
                if let localFirstError = error as? LocalFirstError,
                   localFirstError == .unsupportedWrite {
                    errorMessage = nil
                    isPreviewingRules = false
                    return
                }
                errorMessage = "Could not apply payee rules: \(error.localizedDescription)"
            }
        }

        if requestSequence == rulePreviewSequence {
            isPreviewingRules = false
        }
    }

    func submit(
        budgetID: String,
        repository: any TransactionRepositoryProtocol
    ) async -> Bool {
        let submitsAsTransfer = selectedPayeeIsTransfer

        guard let checkedSplitTotalCents else {
            let message = "The split amounts are too large."
            submissionState = .failed(message)
            errorMessage = message
            return false
        }

        if !submitsAsTransfer, isSplit, checkedSplitTotalCents != amountCents {
            pendingSplitMismatch = TransactionSplitMismatch(
                transactionTotal: amountCents,
                splitTotal: checkedSplitTotalCents
            )
            return false
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
            splits: selectedPayeeIsTransfer || isCategoryReadOnly
                ? []
                : splitDrafts(sign: kind == .spend ? -1 : 1)
        )
    }

    private func makeRulePreviewDraft() -> TransactionDraft? {
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

        return TransactionDraft(
            accountID: selectedAccountID,
            date: date,
            amountMinorUnits: signedAmount,
            payeeID: selectedPayeeID,
            payeeName: trimmedPayee,
            categoryID: isCategoryReadOnly ? nil : selectedCategoryID,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            cleared: isCleared,
            isTransfer: selectedPayeeIsTransfer
        )
    }

    private func applyRulePreview(_ preview: TransactionRulePreview) {
        guard !isSplit, !isCategoryReadOnly else {
            return
        }

        selectedCategoryID = preview.categoryID
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

    private var checkedSplitTotalCents: Int? {
        var total = 0
        for row in splitRows {
            let result = total.addingReportingOverflow(row.amountCents)
            guard !result.overflow else {
                return nil
            }
            total = result.partialValue
        }
        return total
    }

    private func matchesCurrentRulePreviewDraft(_ draft: TransactionDraft) -> Bool {
        draft.accountID == selectedAccountID
            && draft.payeeID == selectedPayeeID
            && draft.payeeName == payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func apply(_ transaction: ActualTransaction, payeeName fallbackPayeeName: String?) {
        let amount = transaction.amount ?? 0
        kind = amount >= 0 ? .inflow : .spend
        amountDigits = String(amount.magnitude)
        selectedAccountID = transaction.account
        selectedPayeeID = transaction.payee
        selectedCategoryID = transaction.category
        date = transaction.date.actualDate ?? date
        notes = transaction.notes ?? ""
        isCleared = transaction.cleared?.boolValue ?? false
        splitRows = transaction.subtransactions.compactMap { child in
            guard let categoryID = child.category else {
                return nil
            }

            return TransactionSplitEditorRow(
                id: child.id ?? categoryID,
                transactionID: child.id,
                categoryID: categoryID,
                categoryName: categoryID,
                amountDigits: String((child.amount ?? 0).magnitude)
            )
        }

        if splitRows.count >= 2 {
            selectedCategoryID = nil
            selectedCategoryFallbackName = nil
        }

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

    private func payeeOption(for payee: ActualPayee) -> TransactionEditorPayeeOption? {
        let transferAccountName = transferAccountName(for: payee)
        let title = transferAccountName ?? payee.name
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return TransactionEditorPayeeOption(
            payee: payee,
            transferAccountName: transferAccountName
        )
    }

    private func transferAccountName(for payee: ActualPayee) -> String? {
        guard let transferAccountID = payee.transferAccount else {
            return nil
        }

        if let accountName = accounts.first(where: { $0.id == transferAccountID })?.name,
           !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return accountName
        }

        let fallbackName = payee.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackName.isEmpty ? nil : fallbackName
    }

    private func payeeSections(
        regularOptions: [TransactionEditorPayeeOption],
        transferOptions: [TransactionEditorPayeeOption],
        transfersFirst: Bool = false
    ) -> [TransactionEditorPayeeSection] {
        let regularSection = TransactionEditorPayeeSection(kind: .payees, options: regularOptions)
        let transferSection = TransactionEditorPayeeSection(kind: .transfers, options: transferOptions)
        let orderedSections = transfersFirst ? [transferSection, regularSection] : [regularSection, transferSection]

        return orderedSections.filter { !$0.options.isEmpty }
    }

    private func applyLoadedOptionNamesIfNeeded() {
        if let selectedPayeeID,
           let matchedPayee = payees.first(where: { $0.id == selectedPayeeID }) {
            // Transfer payees have an empty raw name.
            payeeName = transferAccountName(for: matchedPayee) ?? matchedPayee.name
        }

        if let selectedCategoryID,
           let matchedCategory = categories.first(where: { $0.id == selectedCategoryID }) {
            selectedCategoryFallbackName = matchedCategory.name
        }

        if !splitRows.isEmpty {
            splitRows = splitRows.map { row in
                var updated = row
                if let matchedCategory = categories.first(where: { $0.id == row.categoryID }) {
                    updated.categoryName = matchedCategory.name.actualistCategoryNameParts.name
                }
                return updated
            }
        }
    }

    func apply(_ options: TransactionEditorOptions, loadedMonth: String) {
        accounts = options.accounts
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
        let options = categories.compactMap { category -> TransactionEditorCategoryOption? in
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

        guard !options.isEmpty else {
            return []
        }

        return [
            TransactionEditorCategoryGroup(
                id: "categories",
                name: "Categories",
                options: options
            )
        ]
    }

    private func splitDrafts(sign: Int) -> [TransactionSplitDraft] {
        guard isSplit else {
            return []
        }

        return splitRows.map { row in
            TransactionSplitDraft(
                id: row.transactionID,
                categoryID: row.categoryID,
                categoryName: row.categoryName,
                amountMinorUnits: row.amountCents * sign
            )
        }
    }

    private static func formattedAmountInput(cents: Int) -> String {
        "\(cents / 100).\(String(format: "%02d", cents % 100))"
    }
}

extension String {
    func trimmingLeadingZeros() -> String {
        let trimmed = drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "" : String(trimmed)
    }

    var actualDate: Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: self)
    }

    var actualYearMonth: String? {
        guard count >= 7 else {
            return nil
        }

        return String(prefix(7))
    }
}
