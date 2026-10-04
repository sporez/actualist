import SwiftUI
import UniformTypeIdentifiers

/// File-picker and review presentation for CSV import. Mirrors the export
/// host: the view only flips `isPresented`; the coordinator owns the workflow
/// state and the store does all parsing, matching, and writing.
struct TransactionCSVImportPresentationHost: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool
    let accountID: String?
    @State private var coordinator = TransactionCSVImportCoordinator()

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result,
                      let url = urls.first,
                      let budgetID = appState.settings.selectedBudgetID,
                      let accountID else {
                    return
                }
                Task {
                    await coordinator.load(
                        contentsOf: url,
                        accountID: accountID,
                        budgetID: budgetID,
                        repository: appState.localFirstStore
                    )
                }
            }
            .sheet(isPresented: reviewBinding) {
                reviewSheet
            }
            .onBudgetSessionChange { coordinator.reset() }
    }

    private var reviewBinding: Binding<Bool> {
        Binding(
            get: { coordinator.isPresenting },
            set: { presented in
                if !presented {
                    coordinator.reset()
                }
            }
        )
    }

    @ViewBuilder
    private var reviewSheet: some View {
        if let budgetID = appState.settings.selectedBudgetID {
            TransactionCSVImportReviewView(
                coordinator: coordinator,
                repository: appState.localFirstStore,
                currency: appState.localFirstStore.budgetCurrency(budgetID: budgetID),
                isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                onCancel: { coordinator.reset() },
                onImported: { appState.recordLocalDataMutation() }
            )
            .appSwitcherPrivacyProtected(using: appState)
        } else {
            ChooseBudgetUnavailableView()
        }
    }
}
