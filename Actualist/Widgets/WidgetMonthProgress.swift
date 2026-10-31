import Foundation

/// Spending as a share of the money it drew on. Above 1 when overspent; never
/// below 0, so refunds read as nothing spent.
struct WidgetSpendingShare: Equatable, Sendable {
    let share: Double

    /// Bar length: an overspent budget reads as full.
    var barFraction: Double { min(share, 1) }
    var isOver: Bool { share > 1 }
    var text: String { share.formatted(.percent.precision(.fractionLength(0))) }

    /// Nil without a positive base, which leaves spending no scale.
    init?(spent: Int, base: Int) {
        guard base > 0 else { return nil }
        share = max(Double(spent) / Double(base), 0)
    }
}

/// Where this month's spending stands against its budget and the calendar.
struct WidgetMonthProgress: Equatable, Sendable {
    enum Base: Equatable, Sendable {
        case budgeted
        case income
    }

    let base: Base
    let spending: WidgetSpendingShare
    /// Counts today as elapsed, because a timeline entry shows for the whole day.
    let monthFraction: Double
    let daysLeft: Int

    var daysLeftText: String {
        switch daysLeft {
        case 0: "Last day"
        case 1: "1 day left"
        default: "\(daysLeft) days left"
        }
    }

    /// Nil when neither a budget nor income gives the spending a scale.
    init?(spent: Int, budgeted: Int, income: Int, now: Date, calendar: Calendar) {
        guard let days = calendar.range(of: .day, in: .month, for: now)?.count,
              let spending = WidgetSpendingShare(spent: spent, base: budgeted > 0 ? budgeted : income) else {
            return nil
        }
        let day = calendar.component(.day, from: now)
        base = budgeted > 0 ? .budgeted : .income
        self.spending = spending
        monthFraction = Double(day) / Double(days)
        daysLeft = max(days - day, 0)
    }
}
