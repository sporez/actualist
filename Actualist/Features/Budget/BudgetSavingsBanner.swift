import SwiftUI

struct BudgetSavingsBanner: View {
    @Environment(\.actualistDensity) private var density
    let presentation: BudgetSavingsPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.title)
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(presentation.amountText)
                .font(ActualistTypography.workScreenAmount(for: density))
                .foregroundStyle(presentation.amount < 0 ? ActualistTheme.danger : presentation.amount == 0 ? ActualistTheme.secondaryText : ActualistTheme.positive)
                .monospacedDigit()
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(presentation.incomeText)
                    Spacer(minLength: 16)
                    Text(presentation.expensesText)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.incomeText)
                    Text(presentation.expensesText)
                }
            }
            .font(ActualistTypography.rowLabel(for: density))
            .foregroundStyle(ActualistTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("budget-savings-summary")
    }
}
