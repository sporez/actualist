import Foundation
import GRDB

/// How stored cells become Swift values. Actual budget files store the same
/// field as an integer, a REAL or text depending on the schema version, so each
/// reader picks the variant that matches what it always accepted. A variant
/// that is stricter than another is a different contract, not a mistake.
enum SQLiteValueCoercion {
    // MARK: Untyped values (what `row[column]` without a type returns)

    /// True for a non-zero integer, a `Bool`, or the text `1`, `true` or `yes`
    /// (any case, not trimmed). Everything else, including a REAL, is false.
    static func lenientBool(_ value: DatabaseValueConvertible?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? Int {
            return value != 0
        }
        if let value = value as? Int64 {
            return value != 0
        }
        if let value = value as? String {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return false
    }

    /// Text as stored, or an integer as text. A REAL, `Bool` or blob is nil.
    static func lenientString(_ value: DatabaseValueConvertible?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? Int {
            return String(value)
        }
        if let value = value as? Int64 {
            return String(value)
        }
        return nil
    }

    /// A number, or text that parses whole as a `Double` (not trimmed). Zero
    /// for anything else.
    static func lenientDouble(_ value: DatabaseValueConvertible?) -> Double {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Float {
            return Double(value)
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? Int64 {
            return Double(value)
        }
        if let value = value as? String, let parsed = Double(value) {
            return parsed
        }
        return 0
    }

    /// A whole number: an integer, a REAL with no fraction, or text that is an
    /// integer once trimmed. Nil for anything else, and for a non-finite REAL.
    static func exactInt64(_ value: DatabaseValueConvertible?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double, value.isFinite { return Int64(exactly: value) }
        if let value = value as? String { return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    static func exactInt(_ value: DatabaseValueConvertible?) -> Int? {
        exactInt64(value).flatMap(Int.init(exactly:))
    }

    // MARK: Decoded cells (the stored `DatabaseValue`)
    //
    // These read nil for NULL or a missing column. They switch on the storage
    // class instead of decoding with `row[column] as T?`, which traps inside
    // GRDB when the stored class cannot become `T`. Actual budget files can
    // hold text where a number belongs, so a cell that is not usable is nil.

    /// The stored cell. NULL and a missing column are both `.null`; the
    /// non-optional `DatabaseValue` subscript traps on a missing column.
    private static func cell(_ row: Row, _ column: String) -> DatabaseValue {
        (row[column] as DatabaseValue?) ?? .null
    }

    private static func storage(_ row: Row, _ column: String) -> DatabaseValue.Storage {
        cell(row, column).storage
    }

    /// An integer, a REAL truncated toward zero (nil outside the `Int` range),
    /// or text that parses whole as an integer (not trimmed). Nil for a blob.
    static func int(_ row: Row, _ column: String) -> Int? {
        switch storage(row, column) {
        case .int64(let value): return Int(value)
        case .double(let value): return Int.fromDatabaseValue(value.databaseValue)
        case .string(let value): return Int(value)
        case .null, .blob: return nil
        }
    }

    /// A non-zero `int`, else the text `true`/`yes` (true) or `false`/`no`
    /// (false). Nil for any other value: unknown is not false.
    static func flag(_ row: Row, _ column: String) -> Bool? {
        if let value = int(row, column) { return value != 0 }
        if case .string(let value) = storage(row, column) {
            switch value.lowercased() {
            case "true", "yes": return true
            case "false", "no": return false
            default: return nil
            }
        }
        return nil
    }

    /// A stored integer or REAL. Text and blobs are nil.
    static func number(_ row: Row, _ column: String) -> Double? {
        switch storage(row, column) {
        case .int64(let value): return Double(value)
        case .double(let value): return value
        case .null, .string, .blob: return nil
        }
    }

    /// A stored number, else text that parses whole as a `Double`.
    static func numberOrText(_ row: Row, _ column: String) -> Double? {
        if case .string(let value) = storage(row, column) { return Double(value) }
        return number(row, column)
    }

    /// Text, with the empty string as nil. A blob is read as UTF-8 text; a
    /// number is nil.
    static func nonEmptyString(_ row: Row, _ column: String) -> String? {
        guard let value = String.fromDatabaseValue(cell(row, column)), !value.isEmpty else { return nil }
        return value
    }
}
