import Foundation

struct Money: Hashable, Sendable {
    var cents: Int

    var decimalValue: Decimal {
        Decimal(cents) / Decimal(100)
    }

    func formatted() -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = Locale.current.currency?.identifier ?? "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: decimalValue as NSDecimalNumber) ?? "$0.00"
    }
}

extension Int {
    var actualMoney: Money {
        Money(cents: self)
    }
}
