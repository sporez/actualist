import Foundation

struct WidgetMoney: Codable, Equatable, Sendable {
    let minorUnits: Int
    let formatted: String

    var tone: WidgetAmountTone {
        minorUnits < 0 ? .negative : (minorUnits == 0 ? .zero : .positive)
    }
}

struct WidgetAccountSnapshot: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let group: String
    let isClosed: Bool
    let balance: WidgetMoney?
}

struct WidgetAttentionSnapshot: Codable, Equatable, Sendable {
    let uncategorizedCount: Int
    let overspentCategoryIDs: [String]

    var issueCount: Int { uncategorizedCount + overspentCategoryIDs.count }
}

struct WidgetMonthOverviewSnapshot: Codable, Equatable, Sendable {
    let income: WidgetMoney
    let spent: WidgetMoney
    let toBudget: WidgetMoney
    let budgeted: WidgetMoney
    let available: WidgetMoney
}

struct WidgetTransactionSnapshot: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let accountID: String
    let accountName: String
    let payee: String
    let date: String
    let amount: WidgetMoney?
}

struct WidgetNetWorthPoint: Codable, Equatable, Sendable, Identifiable {
    let date: Date
    let amount: WidgetMoney
    var id: Date { date }
}

struct WidgetNetWorthSnapshot: Codable, Equatable, Sendable {
    let balance: WidgetMoney
    let change: WidgetMoney
    let period: String
    let points: [WidgetNetWorthPoint]
}
