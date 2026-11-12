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

    // MARK: Decoded cells (`row[column] as T?`)
    //
    // These read nil for NULL or a missing column. A stored value that cannot
    // become the requested type traps inside GRDB, so a text-typed integer never
    // reaches the text fallback in `int`. The fallbacks are kept as written.

    /// An integer or a REAL truncated toward zero, else text parsed as an
    /// integer (not trimmed).
    static func int(_ row: Row, _ column: String) -> Int? {
        if let value = row[column] as Int? { return value }
        if let value = row[column] as Int64? { return Int(value) }
        if let value = row[column] as String? { return Int(value) }
        return nil
    }

    /// A non-zero `int`, else the text `true`/`yes` (true) or `false`/`no`
    /// (false). Nil for any other value: unknown is not false.
    static func flag(_ row: Row, _ column: String) -> Bool? {
        if let value = int(row, column) { return value != 0 }
        if let value = row[column] as String? {
            switch value.lowercased() {
            case "true", "yes": return true
            case "false", "no": return false
            default: return nil
            }
        }
        return nil
    }

    /// A stored number.
    static func number(_ row: Row, _ column: String) -> Double? {
        if let value = row[column] as Double? { return value }
        if let value = row[column] as Int? { return Double(value) }
        return nil
    }

    /// A stored number, else text that parses whole as a `Double`.
    static func numberOrText(_ row: Row, _ column: String) -> Double? {
        if let value = row[column] as Double? { return value }
        if let value = row[column] as Int? { return Double(value) }
        if let value = row[column] as String? { return Double(value) }
        return nil
    }

    /// Text, with the empty string as nil.
    static func nonEmptyString(_ row: Row, _ column: String) -> String? {
        guard let value = row[column] as String?, !value.isEmpty else { return nil }
        return value
    }
}
