import Foundation
import GRDB
import Testing
@testable import Actualist

/// Pins how each row-value coercer reads every storage type SQLite and GRDB
/// can hand back, including the values it refuses (Decision Register D13).
struct SQLiteValueCoercionTests {
    /// What a coercer receives: the types `Row` subscripts return (nil, Int64,
    /// Double, String, Data) plus the Swift types a caller may pass directly.
    private static func values() -> [(label: String, value: (any DatabaseValueConvertible)?)] {
        [
            ("nil", nil),
            ("int64 0", Int64(0)), ("int64 1", Int64(1)), ("int64 2", Int64(2)), ("int64 -1", Int64(-1)),
            ("int 1", Int(1)),
            ("int64 max", Int64.max),
            ("bool true", true), ("bool false", false),
            ("double 0.0", 0.0), ("double 1.0", 1.0), ("double 1.5", 1.5),
            ("'0'", "0"), ("'1'", "1"), ("'true'", "true"), ("'false'", "false"),
            ("'yes'", "yes"), ("'no'", "no"), ("'TRUE'", "TRUE"), ("' 1 '", " 1 "), ("''", ""),
            ("blob", Data([0x31])),
        ]
    }

    private static let boolTrue: Set<String> = [
        "int64 1", "int64 2", "int64 -1", "int 1", "int64 max", "bool true",
        "'1'", "'true'", "'yes'", "'TRUE'",
    ]

    private static let string: [String: String] = [
        "int64 0": "0", "int64 1": "1", "int64 2": "2", "int64 -1": "-1", "int 1": "1",
        "int64 max": "9223372036854775807",
        "'0'": "0", "'1'": "1", "'true'": "true", "'false'": "false", "'yes'": "yes",
        "'no'": "no", "'TRUE'": "TRUE", "' 1 '": " 1 ", "''": "",
    ]

    private static let double: [String: Double] = [
        "int64 1": 1, "int64 2": 2, "int64 -1": -1, "int 1": 1, "int64 max": Double(Int64.max),
        "double 1.0": 1, "double 1.5": 1.5, "'1'": 1,
    ]

    /// Whole numbers: an integer, an exactly whole Double, or text that is an
    /// integer once trimmed. Anything else is not a number.
    private static let exactInt: [String: Int] = [
        "int64 0": 0, "int64 1": 1, "int64 2": 2, "int64 -1": -1, "int 1": 1, "int64 max": Int.max,
        "double 0.0": 0, "double 1.0": 1,
        "'0'": 0, "'1'": 1, "' 1 '": 1,
    ]

    // MARK: lenientBool

    @Test func lenientBoolReadsEveryStorageType() {
        for (label, value) in Self.values() {
            #expect(SQLiteValueCoercion.lenientBool(value) == Self.boolTrue.contains(label), "\(label)")
        }
    }

    /// Verbatim copy of the deleted `BudgetDatabase.flexibleLifecycleBool`,
    /// which `lenientBool` replaced.
    private static func legacyLifecycleBool(_ value: DatabaseValueConvertible?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? Int64 { return value != 0 }
        if let value = value as? String {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return false
    }

    @Test func lenientBoolMatchesTheDeletedLifecycleCopy() {
        for (label, value) in Self.values() {
            #expect(SQLiteValueCoercion.lenientBool(value) == Self.legacyLifecycleBool(value), "\(label)")
        }
    }

    // MARK: lenientString and lenientDouble

    @Test func lenientStringAcceptsTextAndIntegersOnly() {
        for (label, value) in Self.values() {
            #expect(SQLiteValueCoercion.lenientString(value) == Self.string[label], "\(label)")
        }
    }

    @Test func lenientDoubleParsesNumbersAndUntrimmedText() {
        for (label, value) in Self.values() {
            #expect(SQLiteValueCoercion.lenientDouble(value) == Self.double[label] ?? 0, "\(label)")
        }
    }

    // MARK: Whole numbers

    @Test func exactIntegersAcceptWholeNumbersOnly() {
        for (label, value) in Self.values() {
            #expect(SQLiteValueCoercion.exactInt(value) == Self.exactInt[label], "\(label)")
            #expect(SQLiteValueCoercion.exactInt64(value) == Self.exactInt[label].map(Int64.init), "\(label)")
        }
        #expect(SQLiteValueCoercion.exactInt(Double.nan) == nil)
        #expect(SQLiteValueCoercion.exactInt(Double.infinity) == nil)
    }

    /// Verbatim copies of the deleted `accountLifecycleInteger` (a failure is
    /// nil here instead of a thrown error), `reconciliationInt64` and
    /// `reconciliationInteger`, which `exactInt64` and `exactInt` replaced.
    private static func legacyLifecycleInteger(_ value: DatabaseValueConvertible?) -> Int? {
        guard let value else { return 0 }
        if let value = value as? Int { return value }
        if let value = value as? Int64, let exact = Int(exactly: value) { return exact }
        if let value = value as? Double, let exact = Int(exactly: value) { return exact }
        if let value = value as? String,
           let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return nil
    }

    private static func legacyReconciliationInt64(_ value: DatabaseValueConvertible?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double, value.isFinite { return Int64(exactly: value) }
        if let value = value as? String { return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    @Test func exactIntegersMatchTheDeletedCopies() {
        let extra: [(label: String, value: (any DatabaseValueConvertible)?)] = [
            ("nan", Double.nan), ("inf", Double.infinity), ("-inf", -Double.infinity), ("1e300", 1e300),
            ("-0.0", -0.0), ("'+5'", "+5"), ("'-5'", "-5"), ("'9223372036854775808'", "9223372036854775808"),
        ]
        for (label, value) in Self.values() + extra {
            #expect(SQLiteValueCoercion.exactInt64(value) == Self.legacyReconciliationInt64(value), "\(label)")
            #expect(
                SQLiteValueCoercion.exactInt(value) == Self.legacyReconciliationInt64(value).flatMap(Int.init(exactly:)),
                "\(label)"
            )
            // The lifecycle copy read "no value" as zero and failed on the rest.
            let lifecycle = value == nil ? 0 : SQLiteValueCoercion.exactInt(value)
            #expect(lifecycle == Self.legacyLifecycleInteger(value), "\(label)")
        }
    }

    // MARK: Decoded cells

    private func cell(_ literal: String) throws -> Row {
        try DatabaseQueue().read { db in
            try #require(try Row.fetchOne(db, sql: "SELECT \(literal) AS v"))
        }
    }

    /// A text or blob cell traps in `row[column] as Int?`, so these read the
    /// numeric storage classes. Text reads through the String variants only.
    @Test func decodedNumbersFollowTheStorageClass() throws {
        let cases: [(literal: String, int: Int?, flag: Bool?, number: Double?)] = [
            ("NULL", nil, nil, nil),
            ("0", 0, false, 0), ("1", 1, true, 1), ("-1", -1, true, -1),
            ("0.0", 0, false, 0), ("1.0", 1, true, 1), ("1.5", 1, true, 1.5), ("-1.5", -1, true, -1.5),
            ("9223372036854775807", Int.max, true, Double(Int64.max)),
        ]
        for item in cases {
            let row = try cell(item.literal)
            #expect(SQLiteValueCoercion.int(row, "v") == item.int, "\(item.literal)")
            #expect(SQLiteValueCoercion.flag(row, "v") == item.flag, "\(item.literal)")
            #expect(SQLiteValueCoercion.number(row, "v") == item.number, "\(item.literal)")
            #expect(SQLiteValueCoercion.numberOrText(row, "v") == item.number, "\(item.literal)")
        }
        // A missing column reads as no value.
        let row = try cell("1")
        #expect(SQLiteValueCoercion.int(row, "missing") == nil)
        #expect(SQLiteValueCoercion.flag(row, "missing") == nil)
        #expect(SQLiteValueCoercion.number(row, "missing") == nil)
    }

    @Test func nonEmptyStringReadsEmptyAndNullAsNil() throws {
        #expect(try SQLiteValueCoercion.nonEmptyString(cell("'abc'"), "v") == "abc")
        #expect(try SQLiteValueCoercion.nonEmptyString(cell("' '"), "v") == " ")
        #expect(try SQLiteValueCoercion.nonEmptyString(cell("''"), "v") == nil)
        #expect(try SQLiteValueCoercion.nonEmptyString(cell("NULL"), "v") == nil)
        #expect(try SQLiteValueCoercion.nonEmptyString(cell("'abc'"), "missing") == nil)
    }
}
