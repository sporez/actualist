import SwiftUI

/// Shared compact/wide host; feature loading remains in SchedulesViewModel.
struct SchedulesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let budgetID = appState.settings.selectedBudgetID {
                    SchedulesView(
                        repository: appState.localFirstStore,
                        mutationRepository: appState.localFirstStore,
                        postingRepository: appState.localFirstStore,
                        transactionRepository: appState.transactionRepository,
                        budgetID: budgetID,
                        budgetSessionGeneration: appState.localFirstStore.budgetSessionGeneration,
                        currency: appState.localFirstStore.budgetCurrency(budgetID: budgetID),
                        isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                        refreshRevision: appState.localDataRevision,
                        asOfDayID: SchedulesViewContext.currentDay()
                    )
                } else {
                    ContentUnavailableView("No Budget Selected", systemImage: "calendar")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("schedules-close")
                }
            }
        }
        .id(appState.localFirstStore.budgetSessionGeneration)
        .frame(idealWidth: 580)
        .presentationDetents([.large])
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationBackground(ActualistTheme.background)
        .accessibilityIdentifier("schedules-sheet")
        .onChange(of: appState.settings.selectedBudgetID) { dismiss() }
    }
}
