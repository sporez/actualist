import SwiftUI

struct AccountTransactionsSummaryView: View {
    @Environment(\.actualistDensity) private var density

    let scope: TransactionFeedScope
    let displayState: AccountTransactionsDisplayState
    let categoryCarryoverIsEnabled: Bool?
    let categoryCarryoverIsUpdating: Bool
    let canEditCategoryCarryover: Bool
    let categoryCarryoverErrorMessage: String?
    let onCategoryCarryoverChanged: (Bool) -> Void

    var body: some View {
        Group {
            if let details = scope.categoryDetails,
               let summary = displayState.categorySummary {
                categorySummary(details, presentation: summary)
            } else {
                VStack(spacing: 6) {
                    Text(displayState.balanceText)
                        .font(ActualistTypography.workScreenAmount(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                    Text("Working Balance")
                        .font(ActualistTypography.body(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.horizontal, 16)
    }

    private func categorySummary(
        _ details: CategoryMonthDetails,
        presentation: AccountTransactionCategorySummaryPresentation
    ) -> some View {
        VStack(spacing: 0) {
            Text(details.monthTitle)
                .font(ActualistTypography.sectionTitle(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)

            summaryRow(label: "Budgeted", value: presentation.budgetedText)
            Divider().overlay(ActualistTheme.separator)
            summaryRow(label: "Spent", value: presentation.spentText)
            Divider().overlay(ActualistTheme.separator)
            summaryRow(
                label: "Remaining",
                value: presentation.remainingText,
                foreground: remainingForeground(presentation.remainingTone)
            )

            if let categoryCarryoverIsEnabled {
                Divider().overlay(ActualistTheme.separator)
                categoryCarryoverRow(isEnabled: categoryCarryoverIsEnabled)
            }

            if let categoryCarryoverErrorMessage {
                Text(categoryCarryoverErrorMessage)
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func categoryCarryoverRow(isEnabled: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Rollover Overspending")
                    .font(ActualistTypography.body(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)

                Text("Carry this category’s negative balance into following months.")
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if categoryCarryoverIsUpdating {
                ProgressView()
                    .controlSize(.small)
                    .tint(ActualistTheme.accent)
            }

            Toggle(
                "Rollover Overspending",
                isOn: Binding(
                    get: { isEnabled },
                    set: onCategoryCarryoverChanged
                )
            )
            .labelsHidden()
            .tint(ActualistTheme.accent)
            .disabled(!canEditCategoryCarryover || categoryCarryoverIsUpdating)
            .accessibilityValue(isEnabled ? "On" : "Off")
        }
        .padding(.vertical, 10)
    }

    private func summaryRow(
        label: String,
        value: String,
        foreground: Color = ActualistTheme.primaryText
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
            Spacer()
            Text(value)
                .font(ActualistTypography.rowValue(for: density))
                .foregroundStyle(foreground)
        }
        .padding(.vertical, 10)
    }

    private func remainingForeground(_ tone: AccountTransactionBalanceTone) -> Color {
        switch tone {
        case .negative: ActualistTheme.danger
        case .zero: ActualistTheme.secondaryText
        case .positive: ActualistTheme.positive
        }
    }
}
