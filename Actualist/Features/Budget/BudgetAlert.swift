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

    init?(apiAlert: APIBudgetMonthAlert) {
        guard let kind = Kind(rawValue: apiAlert.kind) else {
            return nil
        }

        self.kind = kind
        title = apiAlert.title
        valueText = apiAlert.amount?.actualMoney.formatted()
        count = apiAlert.count
        actionTitle = apiAlert.actionTitle
        severity = Severity(apiValue: apiAlert.severity)
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
