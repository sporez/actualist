import SwiftUI

struct AccountLifecycleMenu: View {
    @Environment(AppState.self) private var appState
    let accountID: String
    let coordinator: AccountLifecycleCoordinator

    private var context: AccountLifecycleMenuContext? {
        let budgetID = appState.settings.selectedBudgetID
        return AccountLifecycleMenuContext(
            budgetID: budgetID,
            accountID: accountID,
            accounts: budgetID.map { appState.accountRepository.accountDisplays(budgetID: $0).map(\.account) } ?? []
        )
    }

    var body: some View {
        if let context {
            Button {
                coordinator.beginRename(
                    identity: context.identity,
                    account: context.account,
                    existingAccounts: context.accounts
                )
            } label: {
                Label("Rename Account", systemImage: "pencil")
            }
            .disabled(appState.settings.randomizedDisplayValuesEnabled || coordinator.isSubmitting)
            .accessibilityIdentifier("account-lifecycle-rename-action")

            if context.account.isClosed {
                Button {
                    coordinator.beginReopen(identity: context.identity, account: context.account)
                } label: {
                    Label("Reopen Account", systemImage: "arrow.uturn.backward")
                }
                .disabled(appState.settings.randomizedDisplayValuesEnabled || coordinator.isSubmitting)
                .accessibilityIdentifier("account-lifecycle-reopen-action")
            }
        }
    }
}

/// The same coordinator-driven sheet is composed into both account entry points.
/// Its bindings only dismiss presentation; commands and errors stay in the coordinator.
struct AccountLifecyclePresentationHost: ViewModifier {
    @Environment(AppState.self) private var appState
    let coordinator: AccountLifecycleCoordinator

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetBinding) {
                sheetContent
                    .appSwitcherPrivacyProtected(using: appState)
                    .interactiveDismissDisabled(coordinator.isSubmitting)
            }
            .onChange(of: appState.settings.selectedBudgetID) { coordinator.cancel() }
            .onChange(of: appState.localFirstStore.budgetSessionGeneration) { coordinator.cancel() }
            .onChange(of: appState.settings.randomizedDisplayValuesEnabled, initial: true) {
                coordinator.updatePrivacyMode(appState.settings.randomizedDisplayValuesEnabled)
            }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { AccountLifecyclePresentation.mutationSheet(for: coordinator.state) != nil },
            set: { if !$0 { coordinator.cancel() } }
        )
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch AccountLifecyclePresentation.mutationSheet(for: coordinator.state) {
        case .savedRefreshPending:
            NavigationStack {
                ContentUnavailableView(
                    "Account Change Saved",
                    systemImage: "checkmark.circle",
                    description: Text("Your change is saved on this device. Pull to refresh the account list to update its display.")
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { coordinator.cancel() }
                    }
                }
            }
            .presentationDetents([.medium])
        case .rename:
            AccountRenameSheet(coordinator: coordinator) {
                coordinator.submitRename(repository: appState.localFirstStore) { _ in
                    appState.recordLocalDataMutation()
                }
            }
            .safeAreaInset(edge: .bottom) { retryButton }
        case .reopen:
            AccountReopenSheet(coordinator: coordinator) {
                coordinator.confirmReopen(repository: appState.localFirstStore) { _ in
                    appState.recordLocalDataMutation()
                }
            }
            .safeAreaInset(edge: .bottom) { retryButton }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var retryButton: some View {
        if coordinator.errorMessage != nil {
            Button("Review Again") { coordinator.retry(repository: appState.localFirstStore) }
                .buttonStyle(.glass)
                .padding()
        }
    }
}
