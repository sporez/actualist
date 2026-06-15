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
    var kind: TransactionFlowKind = .spend
    var amountDigits = ""
    var payeeName = ""
    var selectedPayeeID: String?
    var selectedCategoryID: String?
    var selectedAccountID: String?
    var date = Date()
    var notes = ""
    var isCleared = false
    var accounts: [ActualAccount] = []
    var categories: [ActualCategory] = []
    var payees: [ActualPayee] = []
    var isLoading = false
    var isPreviewingRules = false
    var errorMessage: String?
    var submissionState: TransactionSubmissionState = .draft
    private var rulePreviewSequence = 0

    var canSave: Bool {
        amountCents > 0
            && !payeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedAccountID != nil
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
            "Save"
        case .submitting:
            "Saving"
        case .refetching:
            "Refreshing"
        case .clean:
            "Saved"
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

    var selectedCategoryName: String {
        guard let selectedCategoryID,
              let category = categories.first(where: { $0.id == selectedCategoryID }) else {
            return "Select Category"
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
        return trimmed.isEmpty ? "Select Payee" : trimmed
    }

    func setAmountInput(_ value: String) {
        amountDigits = value.filter(\.isNumber).trimmingLeadingZeros()
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

    func selectPayee(_ payee: ActualPayee) {
        selectedPayeeID = payee.id
        payeeName = payee.name
    }

    func selectPayee(_ payee: ActualPayee, using appState: AppState) {
        selectPayee(payee)

        Task {
            await previewRules(using: appState)
        }
    }

    func useCustomPayee(_ name: String) {
        selectedPayeeID = nil
        payeeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func useCustomPayee(_ name: String, using appState: AppState) {
        useCustomPayee(name)

        Task {
            await previewRules(using: appState)
        }
    }

    func load(using appState: AppState, prefilledAccount: ActualAccount?) async {
        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeTransactionRepository() else {
            return
        }

        if let prefilledAccount {
            selectedAccountID = prefilledAccount.id
        }

        isLoading = true
        errorMessage = nil

        do {
            let options = try await repository.editorOptions(budgetID: budgetID)
            accounts = options.accounts
            categories = options.categories
            payees = options.payees

            if selectedAccountID == nil {
                selectedAccountID = accounts.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func submit(using appState: AppState) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeTransactionRepository() else {
            return false
        }

        return await submit(budgetID: budgetID, repository: repository)
    }

    func previewRules(using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeTransactionRepository() else {
            return
        }

        await previewRules(budgetID: budgetID, repository: repository)
    }

    func previewRules(
        budgetID: String,
        repository: any TransactionRepositoryProtocol
    ) async {
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
        guard !isSubmitting, let draft = makeDraft() else {
            return false
        }

        submissionState = .submitting
        errorMessage = nil

        do {
            _ = try await repository.createTransactionAndRefresh(
                draft,
                budgetID: budgetID
            ) { [weak self] in
                await MainActor.run {
                    self?.submissionState = .refetching
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
            categoryID: selectedCategoryID,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            cleared: isCleared
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
            categoryID: selectedCategoryID,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            cleared: isCleared
        )
    }

    private func applyRulePreview(_ preview: TransactionRulePreview) {
        selectedCategoryID = preview.categoryID
        notes = preview.notes ?? ""
    }

    private func matchesCurrentRulePreviewDraft(_ draft: TransactionDraft) -> Bool {
        draft.accountID == selectedAccountID
            && draft.payeeID == selectedPayeeID
            && draft.payeeName == payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func trimmingLeadingZeros() -> String {
        let trimmed = drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "" : String(trimmed)
    }
}
