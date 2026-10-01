import Observation
import SwiftUI

@MainActor
@Observable
final class SavedTransactionFiltersPresentation {
    private(set) var coordinator: SavedTransactionFiltersCoordinator?
    private(set) var isPresented = false

    func present(viewModel: AccountTransactionsViewModel, appState: AppState) {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        let store = appState.localFirstStore
        let sessionGeneration = store.budgetSessionGeneration
        let mutationContext = SavedTransactionFilterMutationContext(
            budgetID: budgetID,
            generation: sessionGeneration
        )
        let transactionRepository = appState.transactionRepository
        let isCurrentSession = {
            appState.settings.selectedBudgetID == budgetID
                && store.budgetSessionGeneration == sessionGeneration
        }
        let coordinator = SavedTransactionFiltersCoordinator(
            mutationContext: mutationContext,
            repository: store,
            conditions: viewModel.activeFeedQuery.conditions,
            join: viewModel.activeFeedQuery.conditionsJoin
        ) { [weak self] conditions, join in
            guard isCurrentSession() else { return }
            self?.dismiss()
            Task {
                guard isCurrentSession() else { return }
                await viewModel.applyStructuredConditions(
                    conditions,
                    join: join,
                    budgetID: budgetID,
                    repository: transactionRepository
                )
            }
        }
        self.coordinator = coordinator
        isPresented = true
    }

    func dismiss() {
        coordinator?.cancel()
        coordinator = nil
        isPresented = false
    }
}

struct SavedTransactionFiltersPresentationHost: ViewModifier {
    @Environment(AppState.self) private var appState
    @Bindable var presentation: SavedTransactionFiltersPresentation

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetBinding) {
                if let coordinator = presentation.coordinator {
                    SavedTransactionFiltersView(coordinator: coordinator)
                        .appSwitcherPrivacyProtected(using: appState)
                } else {
                    ContentUnavailableView("Saved Filters Unavailable", systemImage: "bookmark")
                        .presentationBackground(ActualistTheme.background)
                }
            }
            .onChange(of: appState.settings.selectedBudgetID) { presentation.dismiss() }
            .onChange(of: appState.localFirstStore.budgetSessionGeneration) { presentation.dismiss() }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { presentation.isPresented },
            set: { if !$0 { presentation.dismiss() } }
        )
    }
}
