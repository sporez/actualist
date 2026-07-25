import SwiftUI

struct TransactionEditorPresentation: Identifiable, Hashable {
    let id: String
    let transaction: ActualTransaction?
    let payeeName: String?
    let categoryName: String?

    static var create: TransactionEditorPresentation {
        TransactionEditorPresentation(
            id: "create",
            transaction: nil,
            payeeName: nil,
            categoryName: nil
        )
    }

    static func edit(
        _ transaction: ActualTransaction,
        payeeName: String,
        categoryName: String
    ) -> TransactionEditorPresentation {
        TransactionEditorPresentation(
            id: "edit-\(transaction.rowID)",
            transaction: transaction,
            payeeName: payeeName,
            categoryName: categoryName
        )
    }
}

struct TransactionDeletePresentation: Identifiable, Hashable {
    let transaction: ActualTransaction
    let payeeName: String

    var id: String {
        transaction.rowID
    }
}

enum AccountReconciliationSubmissionState: Equatable {
    case draft
    case submitting
    case reconciled(APIAccountReconciliationResult)
    case mismatch(APIAccountReconciliationResult)
    case failed(String)
}

@MainActor
@Observable
final class AccountReconciliationViewModel {
    var statementBalanceText: String
    var submissionState: AccountReconciliationSubmissionState = .draft

    init(currentBalance: Int?) {
        statementBalanceText = Self.formattedInput(cents: currentBalance ?? 0)
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
        Self.minorUnits(from: statementBalanceText)
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
            return "Actual cleared balance is \(result.clearedBalance.actualMoney.formatted()). Statement balance is \(result.statementBalance.actualMoney.formatted()). Difference is \(result.difference.actualMoney.formatted()). No data changed."
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

    private static func formattedInput(cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let absolute = cents.magnitude
        let centsValue = absolute % 100
        let centsText = centsValue < 10 ? "0\(centsValue)" : "\(centsValue)"
        return "\(sign)\(absolute / 100).\(centsText)"
    }

    private static func minorUnits(from text: String) -> Int? {
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
        guard (1...2).contains(pieces.count),
              let dollars = Int(pieces[0]),
              pieces[0].allSatisfy(\.isNumber) else {
            return nil
        }

        let cents: Int
        if pieces.count == 2 {
            guard pieces[1].count <= 2, pieces[1].allSatisfy(\.isNumber) else {
                return nil
            }
            cents = Int(pieces[1].padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        } else {
            cents = 0
        }

        let (dollarMinorUnits, multiplicationOverflow) = dollars.multipliedReportingOverflow(by: 100)
        guard !multiplicationOverflow else {
            return nil
        }
        let (amount, additionOverflow) = dollarMinorUnits.addingReportingOverflow(cents)
        guard !additionOverflow else {
            return nil
        }
        if isNegative {
            let (negativeAmount, negationOverflow) = 0.subtractingReportingOverflow(amount)
            return negationOverflow ? nil : negativeAmount
        }
        return amount
    }
}

struct AccountReconciliationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
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
        .presentationDragIndicator(.visible)
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
            return (currentBalance ?? 0).actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            currentBalance,
            seed: "reconcile-balance-\(account.id)",
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
                    repository: appState.makeAccountRepository()
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

struct TransactionDateGroup: Hashable {
    let date: String
    let title: String
    let transactions: [ActualTransaction]
}

extension ActualTransaction {
    var rowID: String {
        id ?? "\(date)-\(account)-\(amount ?? 0)-\(importedPayee ?? "")"
    }
}

enum TransactionAmountPresentation {
    static func shouldHighlightAsIncome(amount: Int?, preferenceEnabled: Bool) -> Bool {
        preferenceEnabled && (amount ?? 0) > 0
    }
}

enum TransactionCategoryPresentation {
    static func names(
        for transaction: ActualTransaction,
        categoryNames: [String: String],
        transferPayeeIDs: Set<String>,
        transferAccountIDsByPayeeID: [String: String] = [:],
        offBudgetAccountIDs: Set<String>
    ) -> [String] {
        if offBudgetAccountIDs.contains(transaction.account) {
            return ["Off budget"]
        }

        if !transaction.subtransactions.isEmpty {
            return transaction.subtransactions.map {
                name(
                    for: $0,
                    categoryNames: categoryNames,
                    transferPayeeIDs: transferPayeeIDs,
                    transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
                    offBudgetAccountIDs: offBudgetAccountIDs
                )
            }
        }

        return [
            name(
                for: transaction,
                categoryNames: categoryNames,
                transferPayeeIDs: transferPayeeIDs,
                transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
                offBudgetAccountIDs: offBudgetAccountIDs
            )
        ]
    }

    private static func name(
        for transaction: ActualTransaction,
        categoryNames: [String: String],
        transferPayeeIDs: Set<String>,
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>
    ) -> String {
        if offBudgetAccountIDs.contains(transaction.account) {
            return "Off budget"
        }
        guard let category = transaction.category else {
            if let payee = transaction.payee, transferPayeeIDs.contains(payee) {
                if let destinationAccountID = transferAccountIDsByPayeeID[payee],
                   offBudgetAccountIDs.contains(destinationAccountID) {
                    return "Uncategorized"
                }
                return "Account Transfer"
            }
            return "Uncategorized"
        }
        return categoryNames[category] ?? "Uncategorized"
    }
}

struct TransactionRow: View {
    @Environment(\.actualistDensity) private var density

    let transaction: ActualTransaction
    let payeeName: String
    let categoryNames: [String]
    let accountName: String?
    let isPrivacyModeEnabled: Bool
    let highlightsIncomeAmounts: Bool
    let isNew: Bool
    let showsBottomSeparator: Bool

    init(
        transaction: ActualTransaction,
        payeeName: String,
        categoryNames: [String],
        accountName: String? = nil,
        isPrivacyModeEnabled: Bool = false,
        highlightsIncomeAmounts: Bool = false,
        isNew: Bool = false,
        showsBottomSeparator: Bool = true
    ) {
        self.transaction = transaction
        self.payeeName = payeeName
        self.categoryNames = categoryNames
        self.accountName = accountName
        self.isPrivacyModeEnabled = isPrivacyModeEnabled
        self.highlightsIncomeAmounts = highlightsIncomeAmounts
        self.isNew = isNew
        self.showsBottomSeparator = showsBottomSeparator
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(cleanedPayeeName)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)

                categoryBadges
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 7) {
                Text(amountText)
                    .font(ActualistTypography.transactionAmount(for: density))
                    .foregroundStyle(amountColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if transaction.cleared?.boolValue == true {
                    Image(systemName: "c.circle.fill")
                        .font(.system(size: density.transactionClearedIconSize, weight: .bold))
                        .foregroundStyle(ActualistTheme.positive)
                }
            }
            .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, density.rowHorizontalPadding)
        .padding(.vertical, density.transactionRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isNew ? ActualistTheme.elevatedSurface : Color.clear)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if isNew {
                Rectangle()
                    .fill(ActualistTheme.accent.opacity(0.7))
                    .frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if showsBottomSeparator {
                Rectangle()
                    .fill(ActualistTheme.separator)
                    .frame(height: 1)
            }
        }
    }

    private var categoryBadges: some View {
        HStack(spacing: 6) {
            ForEach(Array(displayCategoryNames.enumerated()), id: \.offset) { _, name in
                categoryBadge(name)
            }

            if let accountName {
                accountBadge(accountName)
            }
        }
    }

    private func categoryBadge(_ name: String) -> some View {
        let parts = name.actualistCategoryNameParts
        return HStack(spacing: 6) {
            if let emoji = parts.emoji {
                Text(verbatim: emoji)
                    .font(.actualistEmoji(size: 14))
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }

            Text(parts.name)
                .font(ActualistTypography.rowBadge(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
            .padding(.horizontal, parts.emoji == nil ? 10 : 9)
            .padding(.vertical, 5)
            .background(ActualistTheme.control, in: Capsule())
    }

    private func accountBadge(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "building.columns.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
                .accessibilityHidden(true)

            Text(name)
                .font(ActualistTypography.rowBadge(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(ActualistTheme.elevatedSurface, in: Capsule())
    }

    private var cleanedPayeeName: String {
        payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var amountText: String {
        guard isPrivacyModeEnabled else {
            return (transaction.amount ?? 0).actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            transaction.amount,
            seed: "transaction-amount-\(transaction.rowID)",
            maximumDollars: 275
        )
    }

    private var amountColor: Color {
        TransactionAmountPresentation.shouldHighlightAsIncome(
            amount: transaction.amount,
            preferenceEnabled: highlightsIncomeAmounts
        ) ? ActualistTheme.incomeTransactionAmount : ActualistTheme.primaryText
    }

    private var displayCategoryNames: [String] {
        guard categoryNames.count > 2 else {
            return categoryNames
        }
        return ["Split (\(categoryNames.count))"]
    }
}
