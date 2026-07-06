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
        switch status {
        case .online:
            Color(red: 0.22, green: 0.82, blue: 0.38)
        case .connecting:
            Color(red: 0.96, green: 0.76, blue: 0.20)
        case .offline:
            Color(red: 0.95, green: 0.26, blue: 0.32)
        }
    }

    private var accessibilityLabel: String {
        switch status {
        case .online:
            "Server connected"
        case .connecting:
            "Server connecting"
        case .offline:
            "Server offline, read only"
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
            .black.opacity(0.78)
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
            .black.opacity(0.78)
        case .warning:
            .black.opacity(0.78)
        case .danger:
            .white
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
