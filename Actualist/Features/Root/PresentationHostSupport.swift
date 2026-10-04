import SwiftUI

/// Shared pieces of the sheet presentation hosts: each host dismisses or resets
/// its workflow when the selected budget or its session generation changes.
private struct BudgetSessionChangeModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.settings.selectedBudgetID) { action() }
            .onChange(of: appState.localFirstStore.budgetSessionGeneration) { action() }
    }
}

extension View {
    func onBudgetSessionChange(perform action: @escaping () -> Void) -> some View {
        modifier(BudgetSessionChangeModifier(action: action))
    }
}

/// Sheet content shown when a host is presented with no selected budget.
struct ChooseBudgetUnavailableView: View {
    var body: some View {
        ContentUnavailableView("Choose a Budget", systemImage: "tray")
            .presentationBackground(ActualistTheme.background)
    }
}
