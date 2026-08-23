import FinanceKit
import FinanceKitUI
import SwiftUI

/// Wallet import controls hosted on Budget & Data. Owns the system picker and
/// review sheet so FinanceKit presentation stays off the Settings directory.
struct WalletImportSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var isWalletImportPresented = false
    @State private var isWalletPickerPresented = false
    @State private var walletSelection: [FinanceKit.Transaction] = []

    var body: some View {
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
        } header: {
            Text("Wallet")
        } footer: {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
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
