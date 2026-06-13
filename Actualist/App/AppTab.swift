import SwiftUI

enum AppTab: String, CaseIterable, Hashable {
    case budget
    case accounts
    case settings

    var title: String {
        switch self {
        case .budget: "Budget"
        case .accounts: "Accounts"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .budget: "list.bullet.rectangle.portrait.fill"
        case .accounts: "building.columns.fill"
        case .settings: "gearshape.fill"
        }
    }
}

