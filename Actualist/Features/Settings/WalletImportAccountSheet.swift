import FinanceKit
import SwiftUI

enum WalletImportAvailability {
    static var isFinancialDataAvailable: Bool {
        FinanceStore.isDataAvailable(.financialData)
    }
}

/// The one question Wallet import asks: which account a Wallet account's
/// activity goes to. Shown only for a Wallet account with no remembered link.
struct WalletImportAccountSheet: View {
    @Environment(AppState.self) private var appState
    let coordinator: WalletImportCoordinator

    var body: some View {
        Form {
            ReviewSheetListHeader(title: "Choose an Account")
            Section {
                let accounts = WalletImportCoordinator.openAccounts(from: appState)
                Picker("Account", selection: accountSelection) {
                    if accounts.isEmpty {
                        Text("No Open Accounts")
                            .tag("")
                    }
                    ForEach(accounts) { account in
                        Text(account.name)
                            .tag(account.id)
                    }
                }
            } footer: {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()
        }
        .reviewSheetList()
        .reviewSheetBottomBar {
            ReviewSheetSecondaryButton(title: "Cancel", role: nil) { coordinator.cancel() }
            ReviewSheetPrimaryButton {
                Task {
                    await coordinator.confirmAccount(appState: appState)
                }
            } label: {
                Text("Add")
            }
            .disabled(request?.selectedAccountID == nil)
        }
        .reviewSheetPresentation(appState: appState)
    }

    private var request: WalletImportCoordinator.AccountRequest? {
        if case .needsAccount(let request) = coordinator.state { return request }
        return nil
    }

    private var footerText: String {
        let count = request?.transactionCount ?? 0
        let activity = count == 1 ? "1 transaction" : "\(count) transactions"
        return "\(activity) from this Wallet account will go here, matched against what is already in the account. Actualist remembers this account on this device."
    }

    private var accountSelection: Binding<String> {
        Binding(
            get: { request?.selectedAccountID ?? "" },
            set: { coordinator.selectAccount($0.isEmpty ? nil : $0) }
        )
    }
}

extension WalletTransactionFields {
    init(transaction: FinanceKit.Transaction) {
        self.init(
            id: transaction.id,
            amount: transaction.transactionAmount.amount,
            creditDebitIndicator: WalletCreditDebitIndicator(transaction.creditDebitIndicator),
            merchantName: transaction.merchantName,
            transactionDescription: transaction.transactionDescription,
            transactionDate: transaction.transactionDate,
            status: WalletTransactionStatus(transaction.status),
            walletAccountID: transaction.accountID.uuidString.lowercased()
        )
    }
}

private extension WalletCreditDebitIndicator {
    init(_ indicator: FinanceKit.CreditDebitIndicator) {
        switch indicator {
        case .credit:
            self = .credit
        case .debit:
            self = .debit
        @unknown default:
            self = .debit
        }
    }
}

private extension WalletTransactionStatus {
    init(_ status: FinanceKit.TransactionStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .memo:
            self = .memo
        case .pending:
            self = .pending
        case .booked:
            self = .booked
        case .rejected:
            self = .rejected
        @unknown default:
            self = .pending
        }
    }
}
