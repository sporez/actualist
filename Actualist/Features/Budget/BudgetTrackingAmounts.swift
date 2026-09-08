import SwiftUI

/// Tracking keeps all amounts visible even at accessibility text sizes.
struct BudgetTrackingAmounts: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.actualistDensity) private var density
    let semantics: BudgetModePresentation
    let budgeted: String
    let activity: String
    let balance: String
    var balanceAmount: Int = 0
    var carryover = false
    var editing = false
    var secondaryBudgeted: String?

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            metric(semantics.budgetedLabel, value: budgeted, color: editing ? ActualistTheme.accent : ActualistTheme.primaryText, secondary: secondaryBudgeted)
            metric(semantics.activityLabel, value: activity)
            if semantics.showsBalance {
                metric(semantics.balanceLabel, value: balance,
                    color: balanceAmount < 0 ? ActualistTheme.danger : balanceAmount > 0 ? ActualistTheme.positive : ActualistTheme.secondaryText,
                    secondary: carryover ? "Rollover on" : nil)
            }
        }
    }

    private func metric(_ label: String, value: String, color: Color = ActualistTheme.primaryText, secondary: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(ActualistTypography.rowLabel(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(value)
                .font(ActualistTypography.rowValue(for: density))
                .monospacedDigit()
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            if let secondary {
                Text(secondary)
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
