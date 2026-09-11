import SwiftUI

struct BudgetAmountPill: View {
    @Environment(\.actualistDensity) private var density
    let value: BudgetSecondValuePresentation
    var hidesCarryoverArrow = false
    var horizontalPadding: CGFloat = 7
    var rolloverOffset: CGFloat = 3

    var body: some View {
        Text(value.text)
            .font(ActualistTypography.rowValue(for: density))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
            .overlay(alignment: .topTrailing) {
                if value.carryover && !hidesCarryoverArrow {
                    BudgetCarryoverBadge(fill: background, foreground: foreground)
                        .offset(x: rolloverOffset, y: -rolloverOffset)
                }
            }
            .accessibilityLabel(value.accessibilityText)
    }

    private var background: Color {
        switch value.tone {
        case .negative: ActualistTheme.danger
        case .zero: ActualistTheme.neutral
        case .positive: ActualistTheme.positive
        }
    }

    private var foreground: Color {
        switch value.tone {
        case .negative: ActualistTheme.dangerForeground
        case .zero: ActualistTheme.neutralForeground
        case .positive: ActualistTheme.positiveForeground
        }
    }
}
