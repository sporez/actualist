import Foundation

struct Money: Hashable, Sendable {
    var minorUnits: Int

    init(minorUnits: Int) {
        self.minorUnits = minorUnits
    }

    init(cents: Int) {
        self.minorUnits = cents
    }

    var decimalValue: Decimal {
        Decimal(minorUnits) / Decimal(100)
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
        Money(minorUnits: self)
    }
}

enum PrivacyDisplayKind {
    case account
    case budget
    case category
    case categoryGroup
    case payee
}

enum PrivacyDisplay {
    /// Resolves the displayed name of the currently selected budget, applying
    /// the sample-values privacy toggle when enabled.
    static func selectedBudgetName(
        name: String?,
        id: String?,
        randomized: Bool
    ) -> String {
        guard let name else {
            return "None"
        }
        guard randomized else {
            return name
        }
        return PrivacyDisplay.name(for: .budget, seed: id ?? name)
    }

    static func name(for kind: PrivacyDisplayKind, seed: String) -> String {
        let value = stableHash(seed)
        let index = Int(value % UInt64(names(for: kind).count))
        let suffix = Int((value / 17) % 90) + 10

        switch kind {
        case .budget:
            return "Sample Budget \(suffix)"
        case .account:
            return "\(names(for: kind)[index]) \(suffix)"
        case .category, .categoryGroup, .payee:
            return names(for: kind)[index]
        }
    }

    static func amount(
        _ original: Int?,
        seed: String,
        currency: BudgetCurrency = .usd,
        minimumDollars: Int = 4,
        maximumDollars: Int = 900
    ) -> Int {
        let value = stableHash(seed)
        let unitSpan = max(maximumDollars - minimumDollars, 1)
        let units = minimumDollars + Int(value % UInt64(unitSpan + 1))
        let scale = NSDecimalNumber(decimal: currency.scale).intValue
        let fraction = currency.decimalPlaces == 0
            ? 0
            : Int((value / 97) % UInt64(scale))
        let sign = (original ?? 0) < 0 ? -1 : 1
        return sign * ((units * scale) + fraction)
    }

    static func money(
        _ original: Int?,
        seed: String,
        currency: BudgetCurrency = .usd,
        minimumDollars: Int = 4,
        maximumDollars: Int = 900
    ) -> String {
        amount(
            original,
            seed: seed,
            currency: currency,
            minimumDollars: minimumDollars,
            maximumDollars: maximumDollars
        ).actualMoney.formatted(using: currency)
    }

    static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    private static func names(for kind: PrivacyDisplayKind) -> [String] {
        switch kind {
        case .account:
            ["Checking", "Savings", "Reserve", "Credit Card", "Cash", "Travel Card", "Brokerage", "Rewards Card"]
        case .budget:
            ["Sample Budget"]
        case .category:
            ["Groceries", "Dining", "Transport", "Utilities", "Subscriptions", "Home", "Health", "Travel", "Gifts", "Shopping", "Fuel", "Savings"]
        case .categoryGroup:
            ["Essentials", "Everyday", "Lifestyle", "Goals", "Bills", "Flex", "Long Term"]
        case .payee:
            ["Market", "Cafe", "Pharmacy", "Hardware", "Transit", "Bookstore", "Store", "Service", "Clinic", "Vendor", "Online Shop"]
        }
    }
}
