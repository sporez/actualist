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

    init?(alert: BudgetMonthAlert, currency: BudgetCurrency = .usd) {
        guard let kind = Kind(rawValue: alert.kind) else {
            return nil
        }

        self.kind = kind
        title = alert.title
        valueText = alert.amount.map(currency.formatted)
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
        BudgetCategoryVisibility.visibleCategories(in: self)
    }
}

/// Budget summary-bar presentation.
/// Pass the sample-values projected month when that setting is on so To Budget,
/// Assigned, and the overspent count match the rows. Cover still uses real data.
enum BudgetMonthSummaryPresentation {
    static func alerts(
        from loaded: [BudgetAlert],
        month: BudgetMonth?,
        showTotalAssigned: Bool,
        includeCarryoverInOverspent: Bool,
        isTrackingBudget: Bool = false,
        currency: BudgetCurrency = .usd
    ) -> [BudgetAlert] {
        let remainder = loaded.filter { $0.kind != .toBudget && $0.kind != .overspending }
        var result: [BudgetAlert] = []
        if let toBudget = toBudgetAlert(from: month, includeZero: showTotalAssigned, currency: currency) {
            result.append(toBudget)
        }
        if let overspent = overspentAlert(
            from: month,
            includeCarryover: includeCarryoverInOverspent,
            isTrackingBudget: isTrackingBudget,
            template: loaded.first { $0.kind == .overspending }
        ) {
            result.append(overspent)
        }
        result.append(contentsOf: remainder)
        return result
    }

    static func assignedValueText(
        for alert: BudgetAlert,
        month: BudgetMonth?,
        showTotalAssigned: Bool,
        currency: BudgetCurrency = .usd
    ) -> String? {
        guard showTotalAssigned, alert.kind == .toBudget, let month else {
            return nil
        }
        return currency.formatted(month.totalBudgeted)
    }

    static func overspentCount(
        in month: BudgetMonth,
        includeCarryover: Bool,
        isTrackingBudget: Bool = false
    ) -> Int {
        month.categoryGroups
            .filter { !$0.isIncome }
            .flatMap { BudgetCategoryVisibility.overspentCategories(in: $0, isTrackingBudget: isTrackingBudget) }
            .filter { category in
                category.balance < 0 && (includeCarryover || !category.carryover)
            }
            .count
    }

    private static func overspentAlert(
        from month: BudgetMonth?,
        includeCarryover: Bool,
        isTrackingBudget: Bool,
        template: BudgetAlert?
    ) -> BudgetAlert? {
        guard let month else {
            return template
        }
        let count = overspentCount(
            in: month,
            includeCarryover: includeCarryover,
            isTrackingBudget: isTrackingBudget
        )
        guard count > 0 else {
            return nil
        }
        if let template {
            return template.replacingCount(with: count)
        }
        return BudgetAlert(
            kind: .overspending,
            title: "Overspent categories",
            count: count,
            actionTitle: "Cover",
            severity: .danger
        )
    }

    private static func toBudgetAlert(
        from month: BudgetMonth?,
        includeZero: Bool,
        currency: BudgetCurrency
    ) -> BudgetAlert? {
        guard let month else {
            return nil
        }
        if month.toBudget == 0 && !includeZero {
            return nil
        }
        return BudgetAlert(
            kind: .toBudget,
            title: "To Budget",
            valueText: currency.formatted(month.toBudget),
            actionTitle: nil,
            severity: month.toBudget < 0 ? .warning : .positive
        )
    }
}
