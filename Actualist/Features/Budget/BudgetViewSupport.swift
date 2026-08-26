import SwiftUI

enum BudgetTemplateConfirmation: String, Identifiable {
    case monthFillEmpty
    case monthOverwrite
    case category

    var id: String { rawValue }

    var actionTitle: String {
        switch self {
        case .monthFillEmpty:
            "Apply Template"
        case .monthOverwrite:
            "Apply Template Overwrite"
        case .category:
            "Apply Category Template"
        }
    }

    var message: String {
        switch self {
        case .monthFillEmpty:
            "This will apply the budget template to empty categories for this month."
        case .monthOverwrite:
            "This will overwrite this month's category budget amounts with the budget template."
        case .category:
            "This will apply the template to the selected category."
        }
    }

    var buttonRole: ButtonRole? {
        switch self {
        case .monthOverwrite, .category:
            .destructive
        case .monthFillEmpty:
            nil
        }
    }

    var buttonTint: Color {
        switch self {
        case .monthOverwrite, .category:
            ActualistTheme.danger
        case .monthFillEmpty:
            ActualistTheme.positive
        }
    }
}

struct ConnectionStatusDot: View {
    let status: ServerConnectionStatus
    var isDemo = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.65), lineWidth: 0.75)
            }
            .shadow(color: color.opacity(0.55), radius: 4)
            .accessibilityLabel(accessibilityLabel)
    }

    private var color: Color {
        if isDemo {
            return ActualistTheme.secondaryText.opacity(0.85)
        }
        switch status {
        case .online:
            return Color(red: 0.22, green: 0.82, blue: 0.38)
        case .connecting:
            return Color(red: 0.96, green: 0.76, blue: 0.20)
        case .offline:
            return Color(red: 0.95, green: 0.26, blue: 0.32)
        }
    }

    private var accessibilityLabel: String {
        if isDemo {
            return "Demo mode"
        }
        switch status {
        case .online:
            return "Server connected"
        case .connecting:
            return "Server connecting"
        case .offline:
            return "Server offline"
        }
    }
}

extension BudgetAlert {
    var isActionable: Bool {
        switch kind {
        case .uncategorizedTransactions, .overspending:
            true
        case .toBudget:
            false
        }
    }

    var foreground: Color {
        switch severity {
        case .positive:
            ActualistTheme.positiveForeground
        case .warning, .danger:
            ActualistTheme.primaryText
        }
    }

    @ViewBuilder
    var backgroundView: some View {
        switch severity {
        case .positive:
            Capsule().fill(ActualistTheme.positive)
        case .warning, .danger:
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(ActualistTheme.surface)
        }
    }

    var countForeground: Color {
        switch severity {
        case .positive:
            ActualistTheme.positiveForeground
        case .warning:
            ActualistTheme.warningForeground
        case .danger:
            ActualistTheme.dangerForeground
        }
    }

    var countBackground: Color {
        switch severity {
        case .positive:
            ActualistTheme.positive
        case .warning:
            ActualistTheme.warning
        case .danger:
            ActualistTheme.danger.opacity(0.8)
        }
    }
}

struct BudgetAlertBanner: View {
    @Environment(\.actualistDensity) private var density

    let alert: BudgetAlert
    let assignedText: String?

    var body: some View {
        Group {
            if alert.kind == .toBudget {
                toBudgetContent
            } else {
                standardContent
            }
        }
        .foregroundStyle(alert.foreground)
        .padding(.horizontal, BudgetLayout.alertHorizontalPadding)
        .padding(.vertical, verticalPadding)
        .background {
            alert.backgroundView
        }
    }

    private var verticalPadding: CGFloat {
        if alert.kind == .toBudget, assignedText != nil {
            BudgetLayout.summaryStackedVerticalPadding
        } else {
            BudgetLayout.alertVerticalPadding
        }
    }

    @ViewBuilder
    private var toBudgetContent: some View {
        if let assignedText {
            stackedSummary(assignedText: assignedText)
        } else {
            inlineSummary
        }
    }

    private var inlineSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let valueText = alert.valueText {
                Text(valueText)
                    .font(ActualistTypography.workScreenAmount(for: density))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Text(alert.title)
                .font(ActualistTypography.body(for: density))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(inlineAccessibilityLabel)
    }

    private var inlineAccessibilityLabel: String {
        if let valueText = alert.valueText {
            "\(alert.title) \(valueText)"
        } else {
            alert.title
        }
    }

    private func stackedSummary(assignedText: String) -> some View {
        HStack(alignment: .center, spacing: BudgetLayout.summaryColumnSpacing) {
            summaryMetric(
                value: alert.valueText ?? "",
                label: alert.title,
                amountFont: ActualistTypography.workScreenAmount(for: density),
                alignment: .leading
            )
            summaryMetric(
                value: assignedText,
                label: "Assigned",
                amountFont: ActualistTypography.summarySecondaryAmount(for: density),
                alignment: .trailing
            )
        }
    }

    private func summaryMetric(
        value: String,
        label: String,
        amountFont: Font,
        alignment: HorizontalAlignment
    ) -> some View {
        let frameAlignment = Alignment(horizontal: alignment, vertical: .center)
        let textAlignment: TextAlignment = alignment == .trailing ? .trailing : .leading
        return VStack(alignment: alignment, spacing: BudgetLayout.summaryMetricSpacing) {
            Text(value)
                .font(amountFont)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
            Text(label)
                .font(ActualistTypography.body(for: density))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    private var standardContent: some View {
        HStack(spacing: 10) {
            if let valueText = alert.valueText {
                Text(valueText)
                    .font(ActualistTypography.workScreenAmount(for: density))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if let count = alert.count {
                Text("\(count)")
                    .font(ActualistTypography.control(for: density))
                    .foregroundStyle(alert.countForeground)
                    .frame(width: 28, height: 28)
                    .background(alert.countBackground, in: Circle())
            }

            Text(alert.title)
                .font(ActualistTypography.body(for: density))
                .lineLimit(1)
                .minimumScaleFactor(0.86)

            Spacer()

            if let actionTitle = alert.actionTitle {
                Text(actionTitle)
                    .font(ActualistTypography.control(for: density))
                    .lineLimit(1)
            }

            if alert.isActionable {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.bold))
            }
        }
    }
}
