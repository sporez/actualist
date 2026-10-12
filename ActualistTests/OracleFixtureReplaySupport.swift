import Foundation
import GRDB
import Synchronization
@testable import Actualist

enum OracleReplayError: Error, CustomStringConvertible {
    case missingFixture(String)
    case malformedFixture(String)
    case unknownCase(String)

    var description: String {
        switch self {
        case .missingFixture(let path):
            "missing oracle fixture at \(path)"
        case .malformedFixture(let detail):
            "malformed oracle fixture: \(detail)"
        case .unknownCase(let id):
            "no replay or fixture case named \(id)"
        }
    }
}

/// JSON-shaped value compared between the pinned oracle and the production replay.
enum OracleValue: Equatable, Sendable {
    case null
    case number(Double)
    case string(String)
    case array([OracleValue])
    case object([String: OracleValue])

    init(json: Any) throws {
        switch json {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            self = .number(number.doubleValue)
        case let array as [Any]:
            self = .array(try array.map { try OracleValue(json: $0) })
        case let object as [String: Any]:
            self = .object(try object.mapValues { try OracleValue(json: $0) })
        default:
            throw OracleReplayError.malformedFixture("unsupported JSON value \(type(of: json))")
        }
    }

    static func databaseValue(_ value: DatabaseValue) -> OracleValue {
        switch value.storage {
        case .null:
            .null
        case .int64(let integer):
            .number(Double(integer))
        case .double(let double):
            .number(double)
        case .string(let string):
            .string(string)
        case .blob:
            .string("<blob>")
        }
    }

    var canonical: String {
        switch self {
        case .null:
            "null"
        case .number(let number):
            number.rounded() == number && abs(number) < 1e15
                ? String(Int64(number))
                : String(number)
        case .string(let string):
            "\"\(string)\""
        case .array(let values):
            "[" + values.map(\.canonical).joined(separator: ",") + "]"
        case .object(let object):
            "{" + object.keys.sorted().map { "\"\($0)\":\(object[$0, default: .null].canonical)" }
                .joined(separator: ",") + "}"
        }
    }

    /// Row identity when the value is a row object.
    var rowID: String? {
        guard case .object(let object) = self, case .string(let id)? = object["id"] else {
            return nil
        }
        return id
    }
}

struct ReplayMismatch: Equatable, Sendable {
    let path: String
    let expected: String
    let actual: String

    var summary: String {
        "\(path): expected \(expected), actual \(actual)"
    }
}

enum ReplayComparison {
    /// Object fields are compared by every expected key. Arrays are paired after sorting by row
    /// id, or by canonical form for message values, so order never decides a result.
    /// Numbers are compared exactly.
    static func mismatches(expected: OracleValue, actual: OracleValue, path: String) -> [ReplayMismatch] {
        switch (expected, actual) {
        case (.object(let expectedFields), .object(let actualFields)):
            var result: [ReplayMismatch] = []
            for key in expectedFields.keys.sorted() {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                let expectedField = expectedFields[key, default: .null]
                guard let actualField = actualFields[key] else {
                    result.append(ReplayMismatch(path: childPath, expected: expectedField.canonical, actual: "missing"))
                    continue
                }
                result += mismatches(expected: expectedField, actual: actualField, path: childPath)
            }
            return result
        case (.array(let expectedItems), .array(let actualItems)):
            return arrayMismatches(expected: expectedItems, actual: actualItems, path: path)
        default:
            guard expected != actual else { return [] }
            return [ReplayMismatch(path: path, expected: expected.canonical, actual: actual.canonical)]
        }
    }

    private static func arrayMismatches(
        expected: [OracleValue],
        actual: [OracleValue],
        path: String
    ) -> [ReplayMismatch] {
        guard expected.count == actual.count else {
            var pending = actual.map(\.canonical)
            var missing: [String] = []
            for item in expected.map(\.canonical) {
                if let index = pending.firstIndex(of: item) {
                    pending.remove(at: index)
                } else {
                    missing.append(item)
                }
            }
            return [ReplayMismatch(
                path: path,
                expected: "\(expected.count) items",
                actual: "\(actual.count) items; missing [\(missing.joined(separator: " "))]; unexpected [\(pending.joined(separator: " "))]"
            )]
        }
        let expectedSorted = expected.sorted { sortKey($0) < sortKey($1) }
        let actualSorted = actual.sorted { sortKey($0) < sortKey($1) }
        var result: [ReplayMismatch] = []
        for (index, pair) in zip(expectedSorted, actualSorted).enumerated() {
            let label = pair.0.rowID ?? String(index)
            result += mismatches(expected: pair.0, actual: pair.1, path: "\(path)[\(label)]")
        }
        return result
    }

    private static func sortKey(_ value: OracleValue) -> String {
        value.rowID ?? value.canonical
    }
}

/// Typed reads of JSON parsed by `JSONSerialization`. Each throwing read names the field it could not read.
enum OracleJSON {
    static func int(_ value: Any?) -> Int? {
        if let integer = value as? Int {
            return integer
        }
        return (value as? NSNumber)?.intValue
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? Double {
            return number
        }
        return (value as? NSNumber)?.doubleValue
    }

    static func object(_ value: Any?, _ name: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw OracleReplayError.malformedFixture("\(name) is not an object")
        }
        return object
    }

    static func objects(_ value: Any?, _ name: String) throws -> [[String: Any]] {
        guard let list = value as? [[String: Any]] else {
            throw OracleReplayError.malformedFixture("\(name) is not an array of objects")
        }
        return list
    }

    static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw OracleReplayError.malformedFixture("\(key) is not a string")
        }
        return value
    }
}

/// The cases of one generator-owned fixture file, keyed by id. A missing file throws; it never
/// yields an empty set, so a replay test cannot pass by skipping.
struct OracleFixtureCases {
    private let cases: [String: [String: Any]]
    private let outputKey: String
    /// The fixture's shared `syntheticData` object, which every case replays against.
    let syntheticData: [String: Any]

    init(domain: String, fileName: String, outputKey: String) throws {
        let url = try ParityOraclePin.fixtureURL(domain).appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OracleReplayError.missingFixture(url.path)
        }
        let root = try OracleJSONFileCache.jsonObject(at: url)
        guard let object = root as? [String: Any], let list = object["cases"] as? [[String: Any]] else {
            throw OracleReplayError.malformedFixture("\(fileName) has no cases array")
        }
        var byID: [String: [String: Any]] = [:]
        for entry in list {
            guard let id = entry["id"] as? String, byID[id] == nil else {
                throw OracleReplayError.malformedFixture("\(fileName) has a missing or duplicate case id")
            }
            byID[id] = entry
        }
        self.cases = byID
        self.outputKey = outputKey
        self.syntheticData = object["syntheticData"] as? [String: Any] ?? [:]
    }

    var ids: Set<String> {
        Set(cases.keys)
    }

    func input(_ id: String) throws -> [String: Any] {
        guard let entry = cases[id] else {
            throw OracleReplayError.unknownCase(id)
        }
        return try OracleJSON.object(entry["input"], "input of \(id)")
    }

    /// The whole case object, for fixtures whose replay inputs are not an `input` object.
    func entry(_ id: String) throws -> [String: Any] {
        guard let entry = cases[id] else {
            throw OracleReplayError.unknownCase(id)
        }
        return entry
    }

    func expected(_ id: String) throws -> OracleValue {
        guard let entry = cases[id], let output = entry[outputKey] else {
            throw OracleReplayError.unknownCase(id)
        }
        return try OracleValue(json: output)
    }
}

/// Two-way comparison: every key must be present on both sides, and arrays compare by position.
/// A `<placeholder>` in the expected value binds one-to-one to the first actual value it meets,
/// so generated ids need not match the oracle's numbering.
struct OracleComparison {
    private(set) var mismatches: [ReplayMismatch] = []
    private var bindings: [String: String] = [:]
    private var claims: [String: String] = [:]

    mutating func compare(expected: OracleValue, actual: OracleValue, path: String = "") {
        if case .string(let token) = expected, Self.isPlaceholder(token) {
            bind(token, to: actual, path: path)
            return
        }
        switch (expected, actual) {
        case (.object(let expectedFields), .object(let actualFields)):
            for key in Set(expectedFields.keys).union(actualFields.keys).sorted() {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                switch (expectedFields[key], actualFields[key]) {
                case let (expectedField?, actualField?):
                    compare(expected: expectedField, actual: actualField, path: childPath)
                case let (expectedField?, nil):
                    record(childPath, expected: expectedField.canonical, actual: "missing")
                case let (nil, actualField?):
                    record(childPath, expected: "missing", actual: actualField.canonical)
                case (nil, nil):
                    break
                }
            }
        case (.array(let expectedItems), .array(let actualItems)):
            guard expectedItems.count == actualItems.count else {
                record(path, expected: "\(expectedItems.count) items", actual: "\(actualItems.count) items")
                return
            }
            for (index, pair) in zip(expectedItems, actualItems).enumerated() {
                compare(expected: pair.0, actual: pair.1, path: "\(path)[\(index)]")
            }
        default:
            if expected != actual {
                record(path, expected: expected.canonical, actual: actual.canonical)
            }
        }
    }

    /// One line per mismatch, naming the case, the field path, and both values.
    static func report(_ caseID: String, _ mismatches: [ReplayMismatch]) -> String {
        mismatches
            .map { "\(caseID) \($0.path): expected \($0.expected), actual \($0.actual)" }
            .joined(separator: "\n")
    }

    private static func isPlaceholder(_ token: String) -> Bool {
        token.hasPrefix("<") && token.hasSuffix(">")
    }

    private mutating func bind(_ token: String, to actual: OracleValue, path: String) {
        let value = actual.canonical
        if let bound = bindings[token] {
            if bound != value {
                record(path, expected: "\(token) = \(bound)", actual: value)
            }
            return
        }
        if let owner = claims[value], owner != token {
            record(path, expected: token, actual: "\(value), already bound to \(owner)")
            return
        }
        bindings[token] = value
        claims[value] = token
    }

    private mutating func record(_ path: String, expected: String, actual: String) {
        mismatches.append(ReplayMismatch(path: path, expected: expected, actual: actual))
    }
}

extension OracleValue {
    /// Orders an array of records by their `id`. Used where Actual leaves the order unspecified.
    var sortedByID: OracleValue {
        guard case .array(let items) = self else {
            return self
        }
        return .array(items.sorted { Self.idText($0) < Self.idText($1) })
    }

    private static func idText(_ value: OracleValue) -> String {
        if case .object(let fields) = value, case .string(let id)? = fields["id"] {
            return id
        }
        return ""
    }
}

/// Case ids and oracle-only reasons from a generator manifest. A replay test must account for every
/// manifest case as either replayed or oracle-only; see `partitionProblems`.
struct OracleManifest {
    let caseIDs: Set<String>
    let oracleOnly: [String: String]

    /// `fixtures` lists one entry per file (Splits); `fixture` describes a single file (Reconciliation).
    init(domain: String, manifestName: String, fileName: String) throws {
        let url = try ParityOraclePin.fixtureURL(domain).appending(path: manifestName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OracleReplayError.missingFixture(url.path)
        }
        let root = try OracleJSON.object(
            OracleJSONFileCache.jsonObject(at: url),
            manifestName
        )
        let entries = (root["fixtures"] as? [[String: Any]]) ?? [root["fixture"] as? [String: Any]].compactMap { $0 }
        guard let entry = entries.first(where: { ($0["path"] as? String)?.hasSuffix("/\(fileName)") == true }) else {
            throw OracleReplayError.malformedFixture("\(manifestName) has no entry for \(fileName)")
        }
        guard let ids = entry["caseIDs"] as? [String] else {
            throw OracleReplayError.malformedFixture("\(manifestName) entry for \(fileName) has no caseIDs")
        }
        let oracleOnlyEntries = (entry["oracleOnly"] ?? root["oracleOnly"]) as? [[String: Any]] ?? []
        self.caseIDs = Set(ids)
        self.oracleOnly = try Dictionary(uniqueKeysWithValues: oracleOnlyEntries.map {
            (try OracleJSON.string($0, "id"), try OracleJSON.string($0, "reason"))
        })
    }

    /// Empty when the replayed and oracle-only ids exactly partition the manifest's caseIDs and every
    /// oracle-only entry has a reason.
    func partitionProblems(fixtureIDs: Set<String>, replayed: [String]) -> [String] {
        var problems: [String] = []
        if fixtureIDs != caseIDs {
            problems.append("fixture case ids differ from manifest caseIDs")
        }
        let replayedSet = Set(replayed)
        if replayedSet.count != replayed.count {
            problems.append("a replayed case id is listed twice")
        }
        let oracleOnlyIDs = Set(oracleOnly.keys)
        if !replayedSet.isDisjoint(with: oracleOnlyIDs) {
            problems.append("replayed and oracle-only ids overlap")
        }
        if replayedSet.union(oracleOnlyIDs) != caseIDs {
            problems.append("replayed and oracle-only ids do not cover manifest caseIDs")
        }
        for (id, reason) in oracleOnly where reason.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("oracle-only case \(id) has no reason")
        }
        return problems
    }
}

/// Parses each oracle fixture file once per test process. Replay suites look up
/// one case per test argument, and parsing the whole file for every argument
/// kept the main actor busy for tens of seconds in a full run, stalling every
/// main-actor test in the host behind it.
enum OracleJSONFileCache {
    // Invariant: `value` is the immutable Foundation object graph that
    // JSONSerialization returns without `.mutableContainers`; it is never mutated
    // after it is stored, so sharing it between test tasks is safe.
    private final class Entry: @unchecked Sendable {
        let value: Any
        init(_ value: Any) { self.value = value }
    }

    private static let entries = Mutex<[String: Entry]>([:])

    static func jsonObject(at url: URL) throws -> Any {
        let key = url.standardizedFileURL.path
        if let cached = entries.withLock({ $0[key] }) {
            return cached.value
        }
        let entry = Entry(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        // Two first readers may both parse; either result is identical.
        return entries.withLock { entries in
            if let existing = entries[key] { return existing.value }
            entries[key] = entry
            return entry.value
        }
    }
}
