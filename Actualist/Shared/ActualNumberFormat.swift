import Foundation

/// Actual's synced `numberFormat` preference: which characters a typed amount
/// uses for thousands and decimals. It follows the budget, not the device locale.
enum ActualNumberFormat: String, CaseIterable, Hashable, Sendable {
    case commaDot = "comma-dot"
    case dotComma = "dot-comma"
    case spaceComma = "space-comma"
    case apostropheDot = "apostrophe-dot"
    case commaDotIn = "comma-dot-in"

    /// An absent or unknown value reads as `comma-dot`, as in Actual's `parseNumberFormat`.
    init(preference: String?) {
        self = preference.flatMap(Self.init(rawValue:)) ?? .commaDot
    }

    var thousandsSeparator: Character {
        switch self {
        case .commaDot, .commaDotIn: ","
        case .dotComma: "."
        case .spaceComma: "\u{202F}"
        case .apostropheDot: "\u{2019}"
        }
    }

    var decimalSeparator: Character {
        switch self {
        case .commaDot, .apostropheDot, .commaDotIn: "."
        case .dotComma, .spaceComma: ","
        }
    }
}
