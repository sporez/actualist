import FinanceKit
import FinanceKitUI
import SwiftUI

/// Wallet import row hosted on Bank Sync. The system picker and review
/// sheet must attach to the screen root via `walletImportPresentation` —
/// hanging them off this `Section` dismisses Settings' fullScreenCover.
struct WalletImportSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Binding var isWalletPickerPresented: Bool

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
            .disabled(appState.settings.selectedBudgetID == nil)
        } header: {
            Text("Apple Wallet")
        } footer: {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
    }

    private var footerText: String {
        if appState.settings.selectedBudgetID == nil {
            return "Choose a budget first, then you can add Apple Wallet activity."
        }
        return "Actualist only receives the transactions you select. It does not keep access to Wallet."
    }
}

private struct WalletImportPresentationModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var isWalletPickerPresented: Bool
    @State private var isWalletImportPresented = false
    @State private var walletSelection: [FinanceKit.Transaction] = []

    func body(content: Content) -> some View {
        content
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
}

extension View {
    func walletImportPresentation(isPickerPresented: Binding<Bool>) -> some View {
        modifier(WalletImportPresentationModifier(isWalletPickerPresented: isPickerPresented))
    }
}
