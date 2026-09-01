import SwiftUI
import Observation

enum AccountReconciliationSubmissionState: Equatable {
    case draft
    case submitting
    case reconciled(AccountReconciliationResult)
    case mismatch(AccountReconciliationResult)
    case failed(String)
}

@MainActor
@Observable
final class AccountReconciliationViewModel {
    var statementBalanceText: String
    var submissionState: AccountReconciliationSubmissionState = .draft
    var currency: BudgetCurrency = .usd

    init(currentBalance: Int?, currency: BudgetCurrency = .usd) {
        self.currency = currency
        statementBalanceText = Self.formattedInput(
            minorUnits: currentBalance ?? 0,
            currency: currency
        )
    }

    var canSubmit: Bool {
        statementBalanceMinorUnits != nil && !isSubmitting
    }

    var isSubmitting: Bool {
        if case .submitting = submissionState {
            return true
        }
        return false
    }

    var submitTitle: String {
        isSubmitting ? "Reconciling" : "Reconcile"
    }

    var statementBalanceMinorUnits: Int? {
        Self.minorUnits(from: statementBalanceText, currency: currency)
    }

    var resultTitle: String? {
        switch submissionState {
        case .draft, .submitting:
            nil
        case .reconciled:
            "Reconciled"
        case .mismatch:
            "Balances Do Not Match"
        case .failed:
            "Reconcile Failed"
        }
    }

    var resultMessage: String? {
        switch submissionState {
        case .draft, .submitting:
            return nil
        case .reconciled(let result):
            let count = result.updated.count
            return count == 1 ? "Marked 1 transaction reconciled." : "Marked \(count) transactions reconciled."
        case .mismatch(let result):
            return "Actual cleared balance is \(currency.formatted(result.clearedBalance)). Statement balance is \(currency.formatted(result.statementBalance)). Difference is \(currency.formatted(result.difference)). No data changed."
        case .failed(let message):
            return message
        }
    }

    var resultColor: Color {
        switch submissionState {
        case .reconciled:
            ActualistTheme.positive
        case .mismatch:
            ActualistTheme.warning
        case .failed:
            ActualistTheme.danger
        case .draft, .submitting:
            ActualistTheme.secondaryText
        }
    }

    func submit(
        budgetID: String,
        accountID: String,
        repository: (any AccountRepositoryProtocol)?
    ) async {
        guard let statementBalance = statementBalanceMinorUnits else {
            submissionState = .failed("Enter a valid statement balance.")
            return
        }

        guard let repository else {
            submissionState = .failed("Reconciliation is unavailable right now.")
            return
        }

        submissionState = .submitting
        do {
            let result = try await repository.reconcileAccountAndRefresh(
                budgetID: budgetID,
                accountID: accountID,
                statementBalance: statementBalance
            )
            submissionState = result.reconciled ? .reconciled(result) : .mismatch(result)
        } catch {
            submissionState = .failed(error.localizedDescription)
        }
    }

    static func formattedInput(minorUnits: Int, currency: BudgetCurrency) -> String {
        currency.editableAmountText(fromMinorUnits: minorUnits)
    }

    private static func minorUnits(from text: String, currency: BudgetCurrency) -> Int? {
        let sanitized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")

        guard !sanitized.isEmpty else {
            return nil
        }
        guard sanitized.count <= 20 else {
            return nil
        }

        let isNegative = sanitized.hasPrefix("-")
        let unsigned = isNegative ? String(sanitized.dropFirst()) : sanitized
        let pieces = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        if currency.decimalPlaces == 0 {
            guard pieces.count == 1, unsigned.allSatisfy(\.isNumber) else {
                return nil
            }
        } else {
            guard (1...2).contains(pieces.count),
                  pieces[0].allSatisfy(\.isNumber) else {
                return nil
            }
            if pieces.count == 2 {
                guard pieces[1].count <= currency.decimalPlaces,
                      pieces[1].allSatisfy(\.isNumber) else {
                    return nil
                }
            }
        }
        guard let decimal = Decimal(string: isNegative ? "-\(unsigned)" : unsigned) else {
            return nil
        }
        return currency.minorUnits(fromDisplay: decimal)
    }
}

struct AccountReconciliationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @Environment(\.budgetCurrency) private var currency
    @State private var viewModel: AccountReconciliationViewModel
    @FocusState private var isStatementBalanceFocused: Bool

    let account: ActualAccount
    let currentBalance: Int?

    init(
        account: ActualAccount,
        currentBalance: Int?
    ) {
        self.account = account
        self.currentBalance = currentBalance
        _viewModel = State(initialValue: AccountReconciliationViewModel(currentBalance: currentBalance))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        fields
                        resultBanner
                        submitButton
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .font(.body.weight(.semibold))
                    .controlSize(.small)
                }
            }
            .navigationTitle("Reconcile")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .appSwitcherPrivacyAwareDragIndicator()
        .onAppear {
            viewModel.currency = currency
            viewModel.statementBalanceText = AccountReconciliationViewModel.formattedInput(
                minorUnits: currentBalance ?? 0,
                currency: currency
            )
        }
        .task {
            await Task.yield()
            isStatementBalanceFocused = true
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(accountDisplayName)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)

            Text(currentBalanceText)
                .font(ActualistTypography.workScreenAmount(for: density))
                .foregroundStyle(ActualistTheme.primaryText)

            Text("Working Balance")
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var accountDisplayName: String {
        guard !appState.settings.randomizedDisplayValuesEnabled else {
            return PrivacyDisplay.name(for: .account, seed: account.id)
        }

        return account.name
    }

    private var currentBalanceText: String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return currency.formatted(currentBalance ?? 0)
        }

        return PrivacyDisplay.money(
            currentBalance,
            seed: "reconcile-balance-\(account.id)",
            currency: currency,
            maximumDollars: 15_000
        )
    }

    private var fields: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "banknote.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(width: density.iconSize)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Statement Balance")
                        .font(ActualistTypography.body(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)

                    TextField("0.00", text: $viewModel.statementBalanceText)
                        .focused($isStatementBalanceFocused)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .tint(ActualistTheme.accent)
                }
            }
            .padding(.horizontal, density.rowHorizontalPadding)
            .padding(.vertical, density.editorRowVerticalPadding)
        }
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    @ViewBuilder
    private var resultBanner: some View {
        if let title = viewModel.resultTitle, let message = viewModel.resultMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(viewModel.resultColor)
                Text(message)
                    .font(ActualistTypography.body(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var submitButton: some View {
        Button {
            guard let budgetID = appState.settings.selectedBudgetID else {
                return
            }
            Task {
                await viewModel.submit(
                    budgetID: budgetID,
                    accountID: account.id,
                    repository: appState.accountRepository
                )
            }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isSubmitting {
                    ProgressView()
                }
                Text(viewModel.submitTitle)
                    .font(ActualistTypography.control(for: density))
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 52)
        }
        .buttonStyle(.glassProminent)
        .tint(ActualistTheme.accent)
        .disabled(!viewModel.canSubmit || appState.settings.selectedBudgetID == nil)
    }
}
