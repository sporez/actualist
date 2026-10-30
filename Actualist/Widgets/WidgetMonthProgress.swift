import Foundation

/// Where this month's spending stands against its budget and the calendar.
struct WidgetMonthProgress: Equatable, Sendable {
    enum Base: Equatable, Sendable {
        case budgeted
        case income
    }

    let base: Base
    /// Spending as a share of the base. Above 1 when overspent; never below 0, so refunds read as nothing spent.
    let spentShare: Double
    /// Bar length: an overspent month reads as full.
    var spentFraction: Double { min(spentShare, 1) }
    var isOverBase: Bool { spentShare > 1 }
    /// Counts today as elapsed, because a timeline entry shows for the whole day.
    let monthFraction: Double
    let daysLeft: Int

    var spentShareText: String {
        spentShare.formatted(.percent.precision(.fractionLength(0)))
    }

    var daysLeftText: String {
        switch daysLeft {
        case 0: "Last day"
        case 1: "1 day left"
        default: "\(daysLeft) days left"
        }
    }

    /// Nil when neither a budget nor income gives the spending a scale.
    init?(spent: Int, budgeted: Int, income: Int, now: Date, calendar: Calendar) {
        guard let days = calendar.range(of: .day, in: .month, for: now)?.count else { return nil }
        let day = calendar.component(.day, from: now)
        guard budgeted > 0 || income > 0 else { return nil }
        base = budgeted > 0 ? .budgeted : .income
        spentShare = max(Double(spent) / Double(budgeted > 0 ? budgeted : income), 0)
        monthFraction = Double(day) / Double(days)
        daysLeft = max(days - day, 0)
    }
}
