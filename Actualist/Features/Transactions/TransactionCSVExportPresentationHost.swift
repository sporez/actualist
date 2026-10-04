import SwiftUI

struct TransactionCSVExportPresentationHost: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool
    let accountID: String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                if let budgetID = appState.settings.selectedBudgetID, let accountID {
                    TransactionCSVExportReviewView(
                        budgetID: budgetID,
                        accountID: accountID,
                        repository: appState.localFirstStore
                    )
                    .appSwitcherPrivacyProtected(using: appState)
                } else {
                    ChooseBudgetUnavailableView()
                }
            }
            .onBudgetSessionChange { isPresented = false }
    }
}
