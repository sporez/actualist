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
    var errorMessage: String?

    var canSave: Bool {
        amountCents > 0
            && !payeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedAccountID != nil
    }

    var amountCents: Int {
        Int(amountDigits) ?? 0
    }

    var formattedAmount: String {
        Money(cents: amountCents).formatted()
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

    func useCustomPayee(_ name: String) {
        selectedPayeeID = nil
        payeeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func load(using appState: AppState, prefilledAccount: ActualAccount?) async {
        guard let budgetID = appState.settings.selectedBudgetID,
              let client = appState.makeClient() else {
            return
        }

        if let prefilledAccount {
            selectedAccountID = prefilledAccount.id
        }

        isLoading = true
        errorMessage = nil

        do {
            async let loadedAccounts = client.accounts(budgetID: budgetID)
            async let loadedCategories = client.categories(budgetID: budgetID)
            async let loadedPayees = client.payees(budgetID: budgetID)

            let fetchedAccounts = try await loadedAccounts
            accounts = fetchedAccounts.filter { !$0.closed }
            categories = (try await loadedCategories)
                .filter { !($0.hidden ?? false) && !($0.isIncome ?? false) }
            payees = try await loadedPayees

            if selectedAccountID == nil {
                selectedAccountID = accounts.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

private extension String {
    func trimmingLeadingZeros() -> String {
        let trimmed = drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "" : String(trimmed)
    }
}
