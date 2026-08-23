import FinanceKit
import FinanceKitUI
import SwiftUI

/// Wallet settings: one-shot import of Apple Card, Apple Cash, and Savings
/// transactions. The system picker is presented from this pushed screen, not
/// from the Settings directory.
struct WalletSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isWalletImportPresented = false
    @State private var isWalletPickerPresented = false
    @State private var walletSelection: [FinanceKit.Transaction] = []

    var body: some View {
        List {
            Section {
                Button {
                    isWalletPickerPresented = true
                } label: {
                    SettingsActionLabel(
                        title: "Import Wallet Transactions",
                        systemImage: "wallet.pass"
                    )
                }
                .disabled(appState.settings.selectedBudgetID == nil)
            } footer: {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .transactionPicker(isPresented: $isWalletPickerPresented, selection: $walletSelection)
        .onChange(of: walletSelection) { _, transactions in
            guard !transactions.isEmpty else {
                return
            }
            isWalletImportPresented = true
        }
        .sheet(isPresented: $isWalletImportPresented, onDismiss: {
            walletSelection = []
        }) {
            WalletImportView(
                initialFields: walletSelection.map(WalletTransactionFields.init(transaction:))
            )
            .environment(appState)
        }
    }

    private var footerText: String {
        if appState.settings.selectedBudgetID == nil {
            return "Select a budget before importing Wallet transactions."
        }
        return "Apple shares only the transactions you pick — this app has no ongoing access to your Wallet. You can also log tap-to-pay purchases with a Shortcuts automation."
    }
}
