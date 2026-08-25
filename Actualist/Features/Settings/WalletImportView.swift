import FinanceKit
import SwiftUI

enum WalletImportAvailability {
    static var isFinancialDataAvailable: Bool {
        FinanceStore.isDataAvailable(.financialData)
    }
}

struct WalletImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.budgetCurrency) private var currency
    var initialFields: [WalletTransactionFields] = []
    @State private var viewModel = WalletImportViewModel()

    var body: some View {
        NavigationStack {
            Form {
                if !WalletImportAvailability.isFinancialDataAvailable {
                    Section {
                        Text("Apple Wallet activity isn't available on this iPhone. It needs Apple Card, Apple Cash, or Savings, which are only offered in the United States.")
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                    .settingsSectionChrome()
                } else {
                    accountSection
                    if !viewModel.displayedCandidates.isEmpty {
                        candidatesSection
                    }
                    importSection
                    if let result = viewModel.result {
                        Section {
                            Text(result.summaryText)
                                .foregroundStyle(ActualistTheme.primaryText)
                        }
                        .settingsSectionChrome()
                    }
                    if let errorMessage = viewModel.errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(ActualistTheme.danger)
                        }
                        .settingsSectionChrome()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("Review Apple Wallet Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .task {
                await viewModel.prepare(using: appState)
                if !initialFields.isEmpty {
                    viewModel.updateFields(initialFields, currency: currency)
                }
            }
            .onChange(of: viewModel.selectedAccountID) {
                viewModel.noteAccountChanged()
                Task {
                    await viewModel.refreshExistingIDs(using: appState)
                }
            }
        }
        .appSwitcherPrivacyAwareDragIndicator()
        .appSwitcherPrivacyProtected()
    }

    private var accountSection: some View {
        Section {
            let accounts = viewModel.openAccounts(from: appState)
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
            Text("They'll be added to this account and sync with the rest of this budget.")
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
    }

    private var candidatesSection: some View {
        Section("To Add") {
            ForEach(viewModel.displayedCandidates) { row in
                WalletImportCandidateRow(row: row)
            }
        }
        .settingsSectionChrome()
    }

    private var importSection: some View {
        Section {
            Button {
                Task {
                    await viewModel.importSelected(using: appState)
                }
            } label: {
                if viewModel.isImporting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(viewModel.importButtonTitle)
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!viewModel.canImport)
        }
        .settingsSectionChrome()
    }

    private var accountSelection: Binding<String> {
        Binding(
            get: { viewModel.selectedAccountID ?? "" },
            set: { viewModel.selectedAccountID = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct WalletImportCandidateRow: View {
    @Environment(\.budgetCurrency) private var currency
    let row: WalletImportDisplayedCandidate

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.candidate.payeeName)
                    .foregroundStyle(ActualistTheme.primaryText)
                Text(row.candidate.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            Spacer(minLength: 8)
            if row.isDuplicate {
                Text("Already added")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ActualistTheme.elevatedSurface, in: Capsule())
            }
            Text(currency.formatted(row.candidate.amountMinorUnits))
                .foregroundStyle(amountColor)
        }
    }

    private var amountColor: Color {
        row.candidate.amountMinorUnits < 0
            ? ActualistTheme.primaryText
            : ActualistTheme.positive
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
            status: WalletTransactionStatus(transaction.status)
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
