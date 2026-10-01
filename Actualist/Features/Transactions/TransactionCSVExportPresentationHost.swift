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
                    ContentUnavailableView("Choose a Budget", systemImage: "tray")
                        .presentationBackground(ActualistTheme.background)
                }
            }
            .onChange(of: appState.settings.selectedBudgetID) { isPresented = false }
            .onChange(of: appState.localFirstStore.budgetSessionGeneration) { isPresented = false }
    }
}
