import Foundation
import GRDB
import Testing
@testable import Actualist

/// Pins how each row-value coercer reads every storage type SQLite and GRDB
/// can hand back, including the values it refuses (Decision Register D13).
@MainActor
struct SQLiteValueCoercionTests {
    private let support = LocalFirstActualStoreTests()

    /// What a coercer receives: the types `Row` subscripts return (nil, Int64,
    /// Double, String, Data) plus the Swift types a caller may pass directly.
    nonisolated private static func values() -> [(label: String, value: (any DatabaseValueConvertible)?)] {
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

    // MARK: flexibleBool and flexibleLifecycleBool

    @Test func flexibleBoolReadsEveryStorageType() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture())
        let results = await read(database) { (database: isolated BudgetDatabase) in
            Self.values().map { ($0.label, database.flexibleBool($0.value)) }
        }
        for (label, result) in results {
            #expect(result == Self.boolTrue.contains(label), "\(label)")
        }
    }

    /// Verbatim copy of the private `BudgetDatabase.flexibleLifecycleBool`.
    private static func legacyLifecycleBool(_ value: DatabaseValueConvertible?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? Int64 { return value != 0 }
        if let value = value as? String {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return false
    }

    @Test func lifecycleBoolReadsEveryStorageTypeLikeFlexibleBool() {
        for (label, value) in Self.values() {
            #expect(Self.legacyLifecycleBool(value) == Self.boolTrue.contains(label), "\(label)")
        }
    }

    // MARK: flexibleString and flexibleDouble

    @Test func flexibleStringAcceptsTextAndIntegersOnly() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture())
        let results = await read(database) { (database: isolated BudgetDatabase) in
            Self.values().map { ($0.label, database.flexibleString($0.value)) }
        }
        for (label, result) in results {
            #expect(result == Self.string[label], "\(label)")
        }
    }

    @Test func flexibleDoubleParsesNumbersAndUntrimmedText() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture())
        let results = await read(database) { (database: isolated BudgetDatabase) in
            Self.values().map { ($0.label, database.flexibleDouble($0.value)) }
        }
        for (label, result) in results {
            #expect(result == Self.double[label] ?? 0, "\(label)")
        }
    }

    // MARK: Integer coercers

    /// Verbatim copy of the private `BudgetDatabase.accountLifecycleInteger`
    /// (a failure is nil here instead of a thrown error).
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

    @Test func accountLifecycleIntegerFailsWhereNotAWholeNumber() {
        for (label, value) in Self.values() {
            // nil is "no value" and reads as zero; the rest fail unless whole.
            let expected = label == "nil" ? 0 : Self.exactInt[label]
            #expect(Self.legacyLifecycleInteger(value) == expected, "\(label)")
        }
    }

    /// Verbatim copies of the private `BudgetDatabase.reconciliationInt64` and
    /// `reconciliationInteger`.
    private static func legacyReconciliationInt64(_ value: DatabaseValueConvertible?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double, value.isFinite { return Int64(exactly: value) }
        if let value = value as? String { return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func legacyReconciliationInteger(_ value: DatabaseValueConvertible?) -> Int? {
        legacyReconciliationInt64(value).flatMap(Int.init(exactly:))
    }

    @Test func reconciliationIntegersAcceptWholeNumbersOnly() {
        for (label, value) in Self.values() {
            #expect(Self.legacyReconciliationInt64(value) == Self.exactInt[label].map(Int64.init), "\(label)")
            #expect(Self.legacyReconciliationInteger(value) == Self.exactInt[label], "\(label)")
        }
    }

    private func read<T: Sendable>(
        _ database: isolated BudgetDatabase,
        _ body: @Sendable (isolated BudgetDatabase) throws -> T
    ) rethrows -> T {
        try body(database)
    }
}
