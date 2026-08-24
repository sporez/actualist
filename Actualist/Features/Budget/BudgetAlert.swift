struct BudgetAlert: Identifiable, Equatable {
    enum Kind: String {
        case toBudget
        case overspending
        case uncategorizedTransactions
    }

    enum Severity: Equatable {
        case positive
        case warning
        case danger
    }

    let kind: Kind
    let title: String
    let valueText: String?
    let count: Int?
    let actionTitle: String?
    let severity: Severity

    var id: String {
        kind.rawValue
    }

    init(
        kind: Kind,
        title: String,
        valueText: String? = nil,
        count: Int? = nil,
        actionTitle: String?,
        severity: Severity
    ) {
        self.kind = kind
        self.title = title
        self.valueText = valueText
        self.count = count
        self.actionTitle = actionTitle
        self.severity = severity
    }

    init?(alert: BudgetMonthAlert) {
        guard let kind = Kind(rawValue: alert.kind) else {
            return nil
        }

        self.kind = kind
        title = alert.title
        valueText = alert.amount?.actualMoney.formatted()
        count = alert.count
        actionTitle = alert.actionTitle
        severity = Severity(apiValue: alert.severity)
    }

    func replacingCount(with count: Int) -> BudgetAlert {
        BudgetAlert(
            kind: kind,
            title: title,
            valueText: valueText,
            count: count,
            actionTitle: actionTitle,
            severity: severity
        )
    }
}

private extension BudgetAlert.Severity {
    init(apiValue: String) {
        switch apiValue {
        case "positive":
            self = .positive
        case "danger":
            self = .danger
        default:
            self = .warning
        }
    }
}

extension BudgetMonthCategoryGroup {
    var visibleCategories: [BudgetMonthCategory] {
        categories.filter { !($0.hidden ?? false) }
    }
}

/// Optional Total Assigned presentation for the Budget summary bar.
/// Assigned uses `BudgetMonth.totalBudgeted`, the sum of non-income group
/// `budgeted` amounts already shown as group Assigned totals.
enum BudgetMonthSummaryPresentation {
    static func alerts(
        from loaded: [BudgetAlert],
        month: BudgetMonth?,
        showTotalAssigned: Bool
    ) -> [BudgetAlert] {
        guard showTotalAssigned, month != nil else {
            return loaded
        }
        if loaded.contains(where: { $0.kind == .toBudget }) {
            return loaded
        }
        guard let alert = BudgetAlert(alert: zeroToBudgetMonthAlert) else {
            return loaded
        }
        return [alert] + loaded
    }

    static func assignedValueText(
        for alert: BudgetAlert,
        month: BudgetMonth?,
        showTotalAssigned: Bool,
        isPrivacyModeEnabled: Bool
    ) -> String? {
        guard showTotalAssigned, alert.kind == .toBudget, let month else {
            return nil
        }
        if isPrivacyModeEnabled {
            return PrivacyDisplay.money(
                month.totalBudgeted,
                seed: "budget-alert-assigned-\(month.month)",
                maximumDollars: 900
            )
        }
        return month.totalBudgeted.actualMoney.formatted()
    }

    private static let zeroToBudgetMonthAlert = BudgetMonthAlert(
        kind: "toBudget",
        severity: "positive",
        title: "To Budget",
        amount: 0,
        count: nil,
        actionTitle: nil
    )
}
