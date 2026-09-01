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

struct TransactionDeletePresentation: Identifiable, Hashable, Sendable {
    let transaction: ActualTransaction
    let payeeName: String

    var id: String {
        transaction.rowID
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

struct TransactionRow: View {
    @Environment(\.actualistDensity) private var density
    @Environment(\.budgetCurrency) private var currency

    let transaction: ActualTransaction
    let semantics: TransactionRowSemantics
    let accountName: String?
    let isPrivacyModeEnabled: Bool
    let highlightsIncomeAmounts: Bool
    let isNew: Bool
    let showsBottomSeparator: Bool

    init(
        transaction: ActualTransaction,
        semantics: TransactionRowSemantics,
        accountName: String? = nil,
        isPrivacyModeEnabled: Bool = false,
        highlightsIncomeAmounts: Bool = false,
        isNew: Bool = false,
        showsBottomSeparator: Bool = true
    ) {
        self.transaction = transaction
        self.semantics = semantics
        self.accountName = accountName
        self.isPrivacyModeEnabled = isPrivacyModeEnabled
        self.highlightsIncomeAmounts = highlightsIncomeAmounts
        self.isNew = isNew
        self.showsBottomSeparator = showsBottomSeparator
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let transferDirection = semantics.transferDirection {
                        Image(systemName: transferDirection == .inflow ? "arrow.left" : "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(ActualistTheme.secondaryText)
                            .accessibilityLabel(transferDirection == .inflow ? "Transfer in" : "Transfer out")
                    }

                    Text(semantics.payeeText)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(
                            semantics.isPlaceholderPayee
                                ? ActualistTheme.secondaryText
                                : ActualistTheme.primaryText
                        )
                        .italic(semantics.isPlaceholderPayee)
                        .lineLimit(2)
                        .minimumScaleFactor(0.9)
                }

                categoryBadges

                if let notes = semantics.notes {
                    Text(notes)
                        .font(ActualistTypography.rowBadge(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                }

                if let displayedCents = semantics.errorDisplayedCents {
                    Text(SplitRemainingPresentation.statusText(displayedCents: displayedCents, currency: currency))
                        .font(ActualistTypography.rowBadge(for: density))
                        .foregroundStyle(ActualistTheme.warning)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 7) {
                Text(amountText)
                    .font(ActualistTypography.transactionAmount(for: density))
                    .foregroundStyle(amountColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                statusIcon
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
            if semantics.isSplitFamily {
                Image(systemName: "square.split.1x2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .accessibilityLabel("Split")
            }

            categoryBadge(semantics.categoryText)

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
                .italic(semantics.isParent || name == "Uncategorized" || name == "Account Transfer" || name == "Off budget")
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
        .background(
            isNew ? ActualistTheme.control : ActualistTheme.elevatedSurface,
            in: Capsule()
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch semantics.status {
        case .reconciled:
            Image(systemName: "lock.fill")
                .font(.system(size: density.transactionClearedIconSize, weight: .bold))
                .foregroundStyle(ActualistTheme.positive)
                .accessibilityLabel("Reconciled")
        case .cleared:
            Image(systemName: "c.circle.fill")
                .font(.system(size: density.transactionClearedIconSize, weight: .bold))
                .foregroundStyle(ActualistTheme.positive)
                .accessibilityLabel("Cleared")
        case .uncleared:
            Image(systemName: "c.circle.fill")
                .font(.system(size: density.transactionClearedIconSize, weight: .bold))
                .foregroundStyle(ActualistTheme.positive)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var amountText: String {
        guard isPrivacyModeEnabled else {
            return currency.formatted(transaction.amount ?? 0)
        }

        return PrivacyDisplay.money(
            transaction.amount,
            seed: "transaction-amount-\(transaction.rowID)",
            currency: currency,
            maximumDollars: 275
        )
    }

    private var amountColor: Color {
        TransactionAmountPresentation.shouldHighlightAsIncome(
            amount: transaction.amount,
            preferenceEnabled: highlightsIncomeAmounts
        ) ? ActualistTheme.incomeTransactionAmount : ActualistTheme.primaryText
    }

}
