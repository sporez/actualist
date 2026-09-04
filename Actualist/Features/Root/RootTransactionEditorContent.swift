import SwiftUI

struct RootTransactionEditorContent: View {
    @Environment(AppState.self) private var appState
    let presentation: RootTransactionEditorPresentation

    var body: some View {
        TransactionEditorView(
            prefilledAccount: presentation.prefilledAccount(from: accountDisplays),
            prefilledPayeeName: presentation.prefill?.payeeName,
            prefilledCategoryName: presentation.prefill?.categoryName,
            shortcutPrefill: presentation.prefill
        )
        .environment(\.budgetCurrency, currency)
    }

    private var accountDisplays: [AccountDisplay] {
        guard let budgetID = appState.settings.selectedBudgetID else { return [] }
        return appState.accountRepository.accountDisplays(budgetID: budgetID)
    }

    private var currency: BudgetCurrency {
        guard let budgetID = appState.settings.selectedBudgetID else { return .usd }
        return appState.localFirstStore.budgetCurrency(budgetID: budgetID)
    }
}
