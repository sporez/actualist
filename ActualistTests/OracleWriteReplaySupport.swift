import Foundation
import GRDB
@testable import Actualist

/// Helpers shared by the oracle replays that compare the net CRDT writes and the stored rows of a store
/// command (Payees, Categories).
enum OracleWriteReplay {
    /// The net cell writes of a message list: the last value per dataset, row and column, in comparison form.
    static func netWrites(_ messages: [ActualSyncDecodedMessage]) -> OracleValue {
        var last: [String: ActualSyncDecodedMessage] = [:]
        for message in messages {
            last["\(message.dataset)\u{0}\(message.row)\u{0}\(message.column)"] = message
        }
        return .array(last.values.map { message in
            .object([
                "dataset": .string(message.dataset),
                "row": .string(message.row),
                "column": .string(message.column),
                "value": ReplayNormalizer.parse(message.serializedValue),
            ])
        })
    }

    /// Writes ordered by dataset, row and column, as the generator sorts them.
    static func sortedWrites(_ writes: OracleValue) -> OracleValue {
        guard case .array(let items) = writes else { return writes }
        func key(_ item: OracleValue) -> [String] {
            ["dataset", "row", "column"].map { field in
                if case .string(let text)? = item.field(field) { return text }
                return ""
            }
        }
        return .array(items.sorted { key($0).lexicographicallyPrecedes(key($1)) })
    }

    /// Every table of a rows object ordered by row id.
    static func sortedRows(_ rows: OracleValue) -> OracleValue {
        guard case .object(let tables) = rows else { return rows }
        return .object(tables.mapValues(\.sortedByID))
    }

    /// Replaces each string that is a key of `aliases`, at any depth.
    static func aliased(_ value: OracleValue, _ aliases: [String: String]) -> OracleValue {
        switch value {
        case .string(let text):
            return .string(aliases[text] ?? text)
        case .array(let items):
            return .array(items.map { aliased($0, aliases) })
        case .object(let fields):
            return .object(fields.mapValues { aliased($0, aliases) })
        default:
            return value
        }
    }

    /// A fixture JSON value as a SQLite value for seeding; `column` names it in the error.
    static func seedValue(_ value: Any, column: String) throws -> DatabaseValue {
        switch value {
        case is NSNull:
            return .null
        case let string as String:
            return string.databaseValue
        case let number as NSNumber:
            if String(cString: number.objCType) == "d" { return number.doubleValue.databaseValue }
            return number.int64Value.databaseValue
        default:
            throw OracleReplayError.malformedFixture("unsupported value in \(column)")
        }
    }
}

/// A registered divergence (`config/parity/known-divergences.json`) and the mismatch paths it accounts
/// for, so a new difference in a marked case still fails.
struct OracleKnownDivergence {
    let op: String
    /// Regular expressions that carry their own `^`/`$` anchors; empty covers every path of the case.
    let patterns: [String]

    func covers(_ path: String) -> Bool {
        patterns.isEmpty || patterns.contains { path.range(of: $0, options: .regularExpression) != nil }
    }
}
