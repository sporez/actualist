import Foundation

enum BudgetTemplateAdjustmentMode: String, CaseIterable, Hashable, Sendable {
    case none
    case fixed
    case percent

    var title: String {
        switch self {
        case .none: "No adjustment"
        case .fixed: "Fixed amount"
        case .percent: "Percentage"
        }
    }
}

enum BudgetTemplateAdjustmentDirection: String, CaseIterable, Hashable, Sendable {
    case increase
    case decrease

    var title: String {
        switch self {
        case .increase: "Increase"
        case .decrease: "Decrease"
        }
    }
}
