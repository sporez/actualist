import FinanceKit
import FinanceKitUI
import SwiftUI

/// Wallet import row hosted on Bank Sync: the action, the last result, and
/// the remembered Wallet account links. The system picker and the account
/// question must attach to the screen root via `walletImportPresentation` —
/// hanging them off this `Section` dismisses Settings' fullScreenCover.
struct WalletImportSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Binding var isWalletPickerPresented: Bool
    let coordinator: WalletImportCoordinator

    var body: some View {
        Section {
            Button {
                isWalletPickerPresented = true
            } label: {
                SettingsActionLabel(
                    title: "Add Activity",
                    systemImage: "wallet.bifold"
                )
            }
            .disabled(appState.settings.selectedBudgetID == nil || coordinator.state == .importing)

            statusRow

            ForEach(WalletImportCoordinator.linkRows(from: appState)) { link in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.accountName)
                            .foregroundStyle(ActualistTheme.primaryText)
                        Text("Imports from a Wallet account")
                            .font(.caption)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Button("Forget", role: .destructive) {
                        coordinator.forgetLink(link.walletAccountID, appState: appState)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Apple Wallet")
        } footer: {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
    }

    @ViewBuilder
    private var statusRow: some View {
        switch coordinator.state {
        case .idle, .needsAccount:
            EmptyView()
        case .importing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Adding Apple Wallet activity…")
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        case .finished(let result):
            Text(result.summaryText)
                .foregroundStyle(ActualistTheme.primaryText)
        case .failed(let message, let partial):
            VStack(alignment: .leading, spacing: 4) {
                if let partial {
                    Text(partial.summaryText)
                        .foregroundStyle(ActualistTheme.primaryText)
                }
                Text(message)
                    .foregroundStyle(ActualistTheme.danger)
            }
        }
    }

    private var footerText: String {
        if appState.settings.selectedBudgetID == nil {
            return "Choose a budget first, then you can add Apple Wallet activity."
        }
        return "Actualist only receives the transactions you select, and matches ones already in the account. It asks once where each Wallet account goes and remembers it on this device."
    }
}

private struct WalletImportPresentationModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var isWalletPickerPresented: Bool
    let coordinator: WalletImportCoordinator
    @State private var walletSelection: [FinanceKit.Transaction] = []

    func body(content: Content) -> some View {
        content
            .transactionPicker(isPresented: $isWalletPickerPresented, selection: $walletSelection)
            .onChange(of: walletSelection) { _, transactions in
                guard !transactions.isEmpty else {
                    return
                }
                let fields = transactions.map(WalletTransactionFields.init(transaction:))
                walletSelection = []
                Task {
                    await coordinator.begin(fields, appState: appState)
                }
            }
            .sheet(isPresented: Binding(
                get: { coordinator.isAskingForAccount },
                set: { isPresented in
                    if !isPresented, coordinator.isAskingForAccount {
                        coordinator.cancel()
                    }
                }
            )) {
                WalletImportAccountSheet(coordinator: coordinator)
                    .environment(appState)
            }
    }
}

extension View {
    func walletImportPresentation(
        isPickerPresented: Binding<Bool>,
        coordinator: WalletImportCoordinator
    ) -> some View {
        modifier(WalletImportPresentationModifier(
            isWalletPickerPresented: isPickerPresented,
            coordinator: coordinator
        ))
    }
}
