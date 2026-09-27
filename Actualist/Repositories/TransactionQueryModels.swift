import Foundation

enum TransactionQueryJoin: String, CaseIterable, Hashable, Sendable {
    case and
    case or
}

enum TransactionQueryDateOperation: String, CaseIterable, Hashable, Sendable {
    case isOn = "is"
    case isApproximately = "isapprox"
    case isAfter = "gt"
    case isOnOrAfter = "gte"
    case isBefore = "lt"
    case isOnOrBefore = "lte"
}

struct TransactionQueryDay: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              year > 0,
              (1...12).contains(month),
              (1...Self.daysInMonth(year: year, month: month)).contains(day) else {
            return nil
        }
        self.rawValue = trimmed
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let isLeap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
            return isLeap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }
}

struct TransactionQueryDateCondition: Hashable, Sendable {
    let operation: TransactionQueryDateOperation
    let day: TransactionQueryDay
}

enum TransactionQueryIDOperation: String, CaseIterable, Hashable, Sendable {
    case isEqual = "is"
    case isNotEqual = "isNot"
    case isOneOf = "oneOf"
    case isNotOneOf = "notOneOf"
}

struct TransactionQueryIDCondition: Hashable, Sendable {
    let operation: TransactionQueryIDOperation
    let values: [String?]

    static func equals(_ value: String?) -> Self {
        Self(operation: .isEqual, values: [normalized(value)])
    }

    static func doesNotEqual(_ value: String?) -> Self {
        Self(operation: .isNotEqual, values: [normalized(value)])
    }

    static func oneOf(_ values: [String?]) -> Self {
        Self(operation: .isOneOf, values: normalized(values))
    }

    static func notOneOf(_ values: [String?]) -> Self {
        Self(operation: .isNotOneOf, values: normalized(values))
    }

    private init(operation: TransactionQueryIDOperation, values: [String?]) {
        self.operation = operation
        self.values = values
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ values: [String?]) -> [String?] {
        var seen = Set<String?>()
        return values
            .map(normalized)
            .filter { seen.insert($0).inserted }
            .sorted { lhs, rhs in
                switch (lhs, rhs) {
                case (nil, nil): false
                case (nil, _): true
                case (_, nil): false
                case let (.some(lhs), .some(rhs)): lhs < rhs
                }
            }
    }
}

enum TransactionQueryCondition: Hashable, Sendable {
    case date(TransactionQueryDateCondition)
    case account(TransactionQueryIDCondition)
    case payee(TransactionQueryIDCondition)
    case category(TransactionQueryIDCondition)

    fileprivate var canonicalKey: String {
        switch self {
        case .date(let condition):
            return "date|\(condition.operation.rawValue)|\(condition.day.rawValue)"
        case .account(let condition):
            return idCanonicalKey(field: "account", condition: condition)
        case .payee(let condition):
            return idCanonicalKey(field: "payee", condition: condition)
        case .category(let condition):
            return idCanonicalKey(field: "category", condition: condition)
        }
    }

    private func idCanonicalKey(field: String, condition: TransactionQueryIDCondition) -> String {
        let values = condition.values.map { $0 ?? "<null>" }.joined(separator: "\u{1f}")
        return "\(field)|\(condition.operation.rawValue)|\(values)"
    }
}

struct TransactionQuerySignature: Hashable, Sendable {
    let status: TransactionStatusFilter
    let text: String?
    let conditionsJoin: TransactionQueryJoin
    let conditions: [TransactionQueryCondition]

    var stableSortKey: String {
        [
            status.rawValue,
            text ?? "",
            conditionsJoin.rawValue,
            conditions.map(\.canonicalKey).joined(separator: "\u{1e}"),
        ].joined(separator: "\u{1d}")
    }
}

struct TransactionFeedQuery: Hashable, Sendable {
    let signature: TransactionQuerySignature

    var status: TransactionStatusFilter { signature.status }
    var text: String? { signature.text }
    var conditionsJoin: TransactionQueryJoin { signature.conditionsJoin }
    var conditions: [TransactionQueryCondition] { signature.conditions }
    var hasStructuredConditions: Bool { !conditions.isEmpty }

    init(
        status: TransactionStatusFilter = .all,
        text: String? = nil,
        conditionsJoin: TransactionQueryJoin = .and,
        conditions: [TransactionQueryCondition] = []
    ) {
        let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalConditions = Array(Set(conditions)).sorted { lhs, rhs in
            lhs.canonicalKey < rhs.canonicalKey
        }
        self.signature = TransactionQuerySignature(
            status: status,
            text: normalizedText?.isEmpty == false ? normalizedText : nil,
            conditionsJoin: conditionsJoin,
            conditions: canonicalConditions
        )
    }

    init(signature: TransactionQuerySignature) {
        self.init(
            status: signature.status,
            text: signature.text,
            conditionsJoin: signature.conditionsJoin,
            conditions: signature.conditions
        )
    }

    func replacingStatus(_ status: TransactionStatusFilter) -> Self {
        Self(status: status, text: text, conditionsJoin: conditionsJoin, conditions: conditions)
    }

    func replacingText(_ text: String?) -> Self {
        Self(status: status, text: text, conditionsJoin: conditionsJoin, conditions: conditions)
    }

    func replacingConditions(
        join: TransactionQueryJoin,
        conditions: [TransactionQueryCondition]
    ) -> Self {
        Self(status: status, text: text, conditionsJoin: join, conditions: conditions)
    }

    static let all = Self()
}

enum TransactionQueryScope: Hashable, Sendable {
    case account(String)
    case spending
}

struct TransactionDrilldownRequest: Hashable, Sendable {
    let scope: TransactionQueryScope
    let query: TransactionFeedQuery
}

struct TransactionDrilldownResult: Hashable, Sendable {
    let querySignature: TransactionQuerySignature
    let displayTransactions: [ActualTransaction]
    let matchingTransactionIDs: Set<String>
    let contributingTransactions: [ActualTransaction]
    let attachedContextTransactionIDs: Set<String>
    let totalMatchCount: Int
}
