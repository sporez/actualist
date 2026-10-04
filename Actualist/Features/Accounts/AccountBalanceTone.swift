import Foundation

/// Money state of an account balance: green positive, gray zero or unknown,
/// red negative.
enum AccountBalanceTone: Equatable, Sendable {
    case positive
    case neutral
    case negative

    init(minorUnits: Int?) {
        switch minorUnits ?? 0 {
        case ..<0: self = .negative
        case 0: self = .neutral
        default: self = .positive
        }
    }
}

extension AccountDisplay {
    var balanceTone: AccountBalanceTone { AccountBalanceTone(minorUnits: balance) }
}
