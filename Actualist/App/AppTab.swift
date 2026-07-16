import SwiftUI

enum AppTab: String, CaseIterable, Hashable {
    case budget
    case spending
    case accounts
    case reports

    var title: String {
        switch self {
        case .budget: "Budget"
        case .spending: "Spending"
        case .accounts: "Accounts"
        case .reports: "Reports"
        }
    }

    var symbolName: String {
        switch self {
        case .budget: "list.bullet.rectangle.portrait.fill"
        case .spending: "creditcard.fill"
        case .accounts: "building.columns.fill"
        case .reports: "chart.xyaxis.line"
        }
    }
}
