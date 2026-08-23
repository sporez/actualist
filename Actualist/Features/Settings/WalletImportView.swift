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
    var initialFields: [WalletTransactionFields] = []
    @State private var viewModel = WalletImportViewModel()

    var body: some View {
        NavigationStack {
            Form {
                if !WalletImportAvailability.isFinancialDataAvailable {
                    Section {
                        Text("Wallet transactions aren't available on this device. Apple Card, Apple Cash and Savings are required, and are currently US-only.")
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
            .navigationTitle("Import from Wallet")
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
                    viewModel.updateFields(initialFields)
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
            Text("These Wallet transactions will be added to this account and sync to your Actual server like any other transaction.")
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
    }

    private var candidatesSection: some View {
        Section("Selected") {
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
                Text("Imported")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ActualistTheme.elevatedSurface, in: Capsule())
            }
            Text(row.candidate.amountMinorUnits.actualMoney.formatted())
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
