import Foundation
import Testing
@testable import Actualist

/// Replays the FileImport oracle fixture (`scripts/parity/file-import-oracle/`):
/// every case is what the pinned Actual returned, and each Swift port must
/// return exactly the same. One test per function walks all of its cases and
/// reports the first mismatches. The fixture is read with `JSONDecoder`, not
/// `JSONSerialization` (see `FixtureJSON`). The tests build no database, so
/// they do not take `OracleReplayGate`; a replay that builds one must.
struct FileImportOracleReplayTests {
    private static let domain = "FileImport"
    private static let fileName = "file-import-contract.json"
    private static let mismatchReportLimit = 20
    /// Known divergences, by fixture case (`config/parity/known-divergences.json`).
    private static let op91Cases: Set<String> = ["pipeline/posting-date-plus-date"]
    private static let op92Cases: Set<String> = [
        "parseAmountFields/values/amount-true", "parseAmountFields/values/outflow-true",
        "parseAmountFields/values/inflow-true", "parseAmountFields/values/amount-true-inout",
        "pipeline/saved/mapping-saved-selected-amount",
    ]

    // MARK: - Fixture structure

    // Invariant: the lazy static initializer runs once, and the Foundation
    // graph it builds is never mutated afterwards, so sharing it between test
    // tasks is safe.
    nonisolated(unsafe) private static let contract: Result<[String: Any], Error> = Result {
        let url = try ParityOraclePin.fixtureURL(domain).appending(path: fileName)
        let decoded = try JSONDecoder().decode(FixtureJSON.self, from: Data(contentsOf: url))
        return try OracleJSON.object(decoded.foundationValue, fileName)
    }

    private func header() throws -> [String: Any] {
        try Self.contract.get()
    }

    private func cases(_ function: String) throws -> [(id: String, input: [String: Any], output: Any?)] {
        let root = try Self.contract.get()
        guard let list = root["cases"] as? [[String: Any]] else {
            throw OracleReplayError.malformedFixture("no cases array")
        }
        let selected = try list.filter { ($0["function"] as? String) == function }.map { entry in
            (
                id: try OracleJSON.string(entry, "id"),
                input: try OracleJSON.object(entry["input"], "input"),
                output: entry["output"]
            )
        }
        guard !selected.isEmpty else { throw OracleReplayError.malformedFixture("no \(function) cases") }
        return selected
    }

    @Test
    func fixtureMatchesThePinnedOracle() throws {
        let pin = try ParityOraclePin.load()
        let oracle = try OracleJSON.object(try header()["oracle"], "oracle")
        #expect(oracle["tag"] as? String == pin.tag)
        #expect(oracle["commit"] as? String == pin.commit)
        #expect(oracle["packageVersion"] as? String == pin.packageVersion)
    }

    @Test
    func fixtureIsSyntheticAndSeeded() throws {
        let header = try header()
        let synthetic = try OracleJSON.object(header["syntheticData"], "syntheticData")
        #expect(synthetic["only"] as? Bool == true)
        #expect(OracleJSON.int(header["seed"]) != nil)
    }

    @Test
    func everyRecordedFunctionHasCases() throws {
        let cases = try OracleFixtureCases(domain: Self.domain, fileName: Self.fileName, outputKey: "output")
        let sections = try OracleJSON.object(try header()["functions"], "functions")
        var total = 0
        for (name, value) in sections {
            let section = try OracleJSON.object(value, name)
            let recorded = OracleJSON.int(section["caseCount"]) ?? 0
            let ids = cases.ids.filter { $0.hasPrefix("\(name)/") }
            #expect(recorded > 0, "\(name) has no cases")
            #expect(ids.count == recorded, "\(name) records \(recorded) cases but the fixture holds \(ids.count)")
            total += ids.count
        }
        #expect(total == cases.ids.count, "a fixture case belongs to no recorded function")
    }

    // MARK: - Amounts

    @Test
    func looselyParseAmountMatchesActual() throws {
        var mismatches: [String] = []
        for testCase in try cases("looselyParseAmount") {
            let text = try OracleJSON.string(testCase.input, "text")
            let ours = ImportAmountParsing.looselyParseAmount(text)
            let theirs = JSValue(testCase.output)
            if !theirs.equalsNumber(ours) {
                mismatches.append("\(testCase.id): \(text.debugDescription) → ours \(String(describing: ours)), Actual \(theirs)")
            }
        }
        report(mismatches)
    }

    @Test
    func amountToIntegerMatchesActual() throws {
        var mismatches: [String] = []
        for testCase in try cases("amountToInteger") {
            guard let amount = JSValue(testCase.input["amount"]).number else {
                throw OracleReplayError.malformedFixture("\(testCase.id): amount is not a number")
            }
            let places = OracleJSON.int(testCase.input["decimalPlaces"]) ?? 2
            let ours = ImportAmountParsing.amountToInteger(amount, decimalPlaces: places)
            let theirs = JSValue(testCase.output)
            if !theirs.equalsNumber(ours) {
                mismatches.append("\(testCase.id): \(amount) → ours \(ours), Actual \(theirs)")
            }
        }
        report(mismatches)
    }

    @Test
    func parseAmountFieldsMatchesActual() throws {
        var mismatches: [String] = []
        for testCase in try cases("parseAmountFields") {
            let trans = try OracleJSON.object(testCase.input["trans"], "trans")
            let modes = ImportAmountParsing.AmountModes(
                splitMode: testCase.input["splitMode"] as? Bool ?? false,
                inOutMode: testCase.input["inOutMode"] as? Bool ?? false,
                outValue: testCase.input["outValue"] as? String ?? "",
                flipAmount: testCase.input["flipAmount"] as? Bool ?? false,
                multiplier: testCase.input["multiplierAmount"] as? String ?? ""
            )
            let row = MappedImportRow(
                amount: trans["amount"] as? String,
                inOut: trans["inOut"] as? String,
                outflow: trans["outflow"] as? String,
                inflow: trans["inflow"] as? String
            )
            let ours = ImportAmountParsing.parseAmountFields(row, modes: modes)
            let output = try OracleJSON.object(testCase.output, "output")
            let same = JSValue(output["amount"]).equalsNumber(ours.amount)
                && JSValue(output["outflow"]).equalsNumber(ours.outflow)
                && JSValue(output["inflow"]).equalsNumber(ours.inflow)
            if Self.op92Cases.contains(testCase.id) {
                withKnownIssue("OP-92: a saved column mapping that names the modal's internal `selected` flag reads nothing, where Actual reads the boolean true") {
                    #expect(same, "\(testCase.id): ours \(ours), Actual \(output)")
                }
            } else if !same {
                mismatches.append("\(testCase.id): ours \(ours), Actual \(output)")
            }
        }
        report(mismatches)
    }

    @Test
    func decodeCsvBytesMatchesActual() throws {
        var mismatches: [String] = []
        for testCase in try cases("decodeCsvBytes") {
            let base64 = try OracleJSON.string(testCase.input, "bytesBase64")
            guard let bytes = Data(base64Encoded: base64) else {
                throw OracleReplayError.malformedFixture("\(testCase.id): bad bytesBase64")
            }
            let encoding = testCase.input["encoding"] as? String ?? "auto"
            let output = try OracleJSON.object(testCase.output, "output")
            let ours = try? ImportFileDecoding.decode([UInt8](bytes), encoding: encoding)
            switch (ours, output["text"] as? String) {
            case (nil, nil):
                continue
            case (let ours?, let theirs?) where ours.elementsEqual(theirs.unicodeScalars):
                continue
            default:
                let oursText = ours.map { JavaScriptText.string($0).unicodeScalars.map { String($0.value, radix: 16) } }
                mismatches.append("\(testCase.id) [\(encoding)]: ours \(String(describing: oursText)), Actual \(String(describing: output["text"] ?? output["error"]))")
            }
        }
        report(mismatches)
    }

    // MARK: - Dates

    @Test
    func parseDateMatchesActual() throws {
        var mismatches: [String] = []
        for testCase in try cases("parseDate") {
            let text = testCase.input["text"] as? String
            let format = try dateFormat(testCase.input["format"])
            let ours = ImportDateParsing.parseDate(text, format: format)
            let theirs = testCase.output as? String
            if ours != theirs {
                mismatches.append("\(testCase.id): \(String(describing: text)) as \(format.rawValue) → ours \(String(describing: ours)), Actual \(String(describing: theirs))")
            }
        }
        report(mismatches)
    }

    @Test
    func getInitialDateFormatMatchesActual() throws {
        var mismatches: [String] = []
        for testCase in try cases("getInitialDateFormat") {
            let sources = try sourceRows(testCase.input)
            let mapping = try testCase.input["mappings"].map(fieldMapping)
                ?? ImportFieldMappingRules.initialMappings(sources) ?? ImportFieldMapping()
            let ours = ImportFieldMappingRules.initialDateFormat(sources, mapping: mapping)
            let theirs = testCase.output as? String
            if ours.rawValue != theirs {
                mismatches.append("\(testCase.id): ours \(ours.rawValue), Actual \(String(describing: theirs))")
            }
        }
        report(mismatches)
    }

    // MARK: - Columns

    @Test
    func getInitialMappingsMatchesActual() throws {
        var mismatches: [String] = []
        for testCase in try cases("getInitialMappings") {
            let ours = ImportFieldMappingRules.initialMappings(try sourceRows(testCase.input))
            let output = try OracleJSON.object(testCase.output, "output")
            let theirs: ImportFieldMapping? = output.isEmpty ? nil : try fieldMapping(output)
            if !sameMapping(ours, theirs) {
                mismatches.append("\(testCase.id): ours \(String(describing: ours)), Actual \(String(describing: theirs))")
            }
        }
        report(mismatches)
    }

    @Test
    func applyFieldMappingsMatchesActual() throws {
        var mismatches: [String] = []
        for testCase in try cases("applyFieldMappings") {
            let mapping = try fieldMapping(testCase.input["mappings"] as Any)
            let ours = try sourceRows(testCase.input).map { ImportFieldMappingRules.apply(mapping, to: $0) }
            guard let rows = testCase.output as? [Any] else {
                throw OracleReplayError.malformedFixture("\(testCase.id): output is not an array")
            }
            let theirs = try rows.map { value -> MappedImportRow in
                let row = try OracleJSON.object(value, "row")
                return MappedImportRow(
                    date: JSValue(row["date"]).string,
                    amount: JSValue(row["amount"]).string,
                    payeeName: JSValue(row["payee_name"]).string,
                    notes: JSValue(row["notes"]).string,
                    inOut: JSValue(row["inOut"]).string,
                    category: JSValue(row["category"]).string,
                    outflow: JSValue(row["outflow"]).string,
                    inflow: JSValue(row["inflow"]).string
                )
            }
            if !sameMappedRows(ours, theirs) {
                mismatches.append("\(testCase.id): ours \(ours), Actual \(theirs)")
            }
        }
        report(mismatches)
    }

    @Test
    func parseCategoryFieldsMatchesActual() throws {
        var mismatches: [String] = []
        for testCase in try cases("parseCategoryFields") {
            let matcher = ImportCategoryMatcher(categories: try categories(testCase.input["categories"]))
            let text = testCase.input["category"] as? String
            let ours = matcher.categoryID(forText: text)
            let theirs = testCase.output as? String
            if !sameText(ours, theirs) {
                mismatches.append("\(testCase.id): \(String(describing: text)) → ours \(String(describing: ours)), Actual \(String(describing: theirs))")
            }
        }
        report(mismatches)
    }

    // MARK: - CSV parsing

    /// Actual's `parseFile` on a CSV: the records (arrays for a headerless
    /// file, `Object.entries` for a header row) or a refusal.
    @Test
    func parseCsvRecordsMatchesActual() throws {
        var mismatches: [String] = []
        for testCase in try cases("parseCsvRecords") {
            let output = try OracleJSON.object(testCase.output, "output")
            let table: TransactionCSVParser.Table
            do {
                table = try self.table(testCase.input)
            } catch is TransactionCSVParser.ParseError {
                if output["error"] == nil {
                    mismatches.append("\(testCase.id): ours refused the file, Actual read it")
                }
                continue
            }
            guard let records = output["records"] as? [Any] else {
                mismatches.append("\(testCase.id): ours read the file, Actual refused \(String(describing: output["error"]))")
                continue
            }
            let hasHeaderRow = testCase.input["hasHeaderRow"] as? Bool ?? true
            let ours: [[[String]]]
            let theirs: [[[String]]]
            if hasHeaderRow {
                ours = ImportFieldMappingRules.records(from: table).map { $0.entries.map { [$0.key, $0.value] } }
                theirs = try records.map { record in
                    let object = try OracleJSON.object(record, "record")
                    guard let entries = object["entries"] as? [[String]] else {
                        throw OracleReplayError.malformedFixture("\(testCase.id): record without entries")
                    }
                    return entries
                }
            } else {
                ours = table.rows.map { $0.map { [$0] } }
                guard let arrays = records as? [[String]] else {
                    throw OracleReplayError.malformedFixture("\(testCase.id): records are not string arrays")
                }
                theirs = arrays.map { $0.map { [$0] } }
            }
            if !sameNested(ours, theirs) {
                mismatches.append("\(testCase.id):\n  ours   \(ours)\n  Actual \(theirs)")
            }
        }
        report(mismatches)
    }

    // MARK: - Whole files

    /// A CSV file through Actual's default-settings import: parse, guess the
    /// columns and date format, the preview's sort, then each row as
    /// `onImport` sends it. Payee and notes are compared after the server's
    /// own normalization (trim; empty is none), which the bank-sync oracle
    /// covers.
    @Test
    func pipelineMatchesActual() throws {
        var mismatches: [String] = []
        for testCase in try cases("pipeline") {
            let output = try OracleJSON.object(testCase.output, "output")
            let matcher = ImportCategoryMatcher(categories: try categories(testCase.input["categories"]))
            let settings = try pipelineSettings(testCase.input)
            let theirError = (output["error"] as? [String: Any])?["kind"] as? String
            let result: TransactionCSVImportMapper.Result
            do {
                let parsed = try TransactionCSVParser(options: TransactionCSVParser.Options(
                    delimiter: settings.delimiter,
                    hasHeaderRow: settings.hasHeaderRow,
                    encoding: settings.encoding,
                    skipStartLines: settings.skipStartLines,
                    skipEndLines: settings.skipEndLines
                )).parse(try inputData(testCase.input))
                result = try TransactionCSVImportMapper.map(parsed, settings: settings)
            } catch {
                let ourError: String
                switch error {
                case TransactionCSVImportError.invalidRow: ourError = "date"
                case TransactionCSVImportError.unreadableSavedMapping: ourError = "mappings-json"
                case is TransactionCSVParser.ParseError: ourError = "parse"
                default: throw error
                }
                if ourError != theirError {
                    mismatches.append("\(testCase.id): ours refused (\(ourError): \(error)), Actual \(theirError ?? "imported")")
                }
                continue
            }
            guard let transactions = output["transactions"] as? [Any] else {
                mismatches.append("\(testCase.id): ours imported, Actual refused \(String(describing: output["error"]))")
                continue
            }
            let theirs = try transactions.map { try PipelineRow(actual: OracleJSON.object($0, "transaction")) }
            let ours = result.rows.map { PipelineRow(ours: $0, matcher: matcher) }
            let engineDefinedOrder = output["engineDefinedOrder"] as? Bool == true
            if result.orderIsEngineDefined != engineDefinedOrder {
                mismatches.append("\(testCase.id): engine-defined order ours \(result.orderIsEngineDefined), Actual \(engineDefinedOrder)")
            }
            if Self.op91Cases.contains(testCase.id) {
                // The rows themselves must agree; only their order is the engine's.
                if ours.sorted(by: { $0.sourceIndex < $1.sourceIndex }) != theirs.sorted(by: { $0.sourceIndex < $1.sourceIndex }) {
                    mismatches.append("\(testCase.id): rows differ\n  ours   \(ours)\n  Actual \(theirs)")
                }
                withKnownIssue("OP-91: rows whose lowercase date column mixes readable and unreadable dates keep file order, where Actual's order is engine-defined") {
                    #expect(ours == theirs, "\(testCase.id): order differs")
                }
            } else if Self.op92Cases.contains(testCase.id) {
                withKnownIssue("OP-92: a saved column mapping that names the modal's internal `selected` flag reads nothing, where Actual reads the boolean true") {
                    #expect(ours == theirs, "\(testCase.id): differs")
                }
            } else if ours != theirs {
                mismatches.append("\(testCase.id):\n  ours   \(ours)\n  Actual \(theirs)")
            }
        }
        report(mismatches)
    }

    /// The pipeline's starting settings, from the account's synced prefs.
    private func pipelineSettings(_ input: [String: Any]) throws -> ImportSettings {
        guard let pairs = input["prefs"] as? [[Any]] else {
            throw OracleReplayError.malformedFixture("pipeline case without prefs")
        }
        var preferences: [String: String] = [:]
        for pair in pairs {
            guard pair.count == 2, let key = pair[0] as? String, let value = pair[1] as? String else {
                throw OracleReplayError.malformedFixture("bad pref pair")
            }
            preferences[key] = value
        }
        return .saved(
            preferences: preferences,
            accountID: try OracleJSON.string(input, "accountId"),
            fileName: try OracleJSON.string(input, "fileName")
        )
    }

    // MARK: - Helpers

    private struct PipelineRow: Equatable, CustomStringConvertible {
        let sourceIndex: Int
        let date: String
        let amount: Int
        let payee: String?
        let notes: String?
        let category: String?
        let cleared: Bool

        init(ours row: TransactionCSVImportRow, matcher: ImportCategoryMatcher) {
            sourceIndex = row.sourceLine - 1
            date = row.dateText
            amount = row.amountMinorUnits
            payee = row.payeeName.isEmpty ? nil : row.payeeName
            notes = row.notes
            category = matcher.categoryID(forText: row.categoryName)
            cleared = row.cleared == true
        }

        init(actual: [String: Any]) throws {
            guard let index = OracleJSON.int(actual["sourceIndex"]),
                  let amount = JSValue(actual["amount"]).number else {
                throw OracleReplayError.malformedFixture("pipeline transaction without sourceIndex or amount")
            }
            sourceIndex = index
            date = try OracleJSON.string(actual, "date")
            self.amount = Int(amount)
            let payeeText = JSValue(actual["payee_name"]).string.map(JavaScriptText.trim)
            payee = payeeText?.isEmpty == false ? payeeText : nil
            let notesText = JSValue(actual["notes"]).string
            notes = notesText?.isEmpty == false ? notesText : nil
            category = actual["category"] as? String
            cleared = actual["cleared"] as? Bool == true
        }

        static func == (lhs: PipelineRow, rhs: PipelineRow) -> Bool {
            lhs.sourceIndex == rhs.sourceIndex && lhs.date == rhs.date && lhs.amount == rhs.amount
                && sameText(lhs.payee, rhs.payee) && sameText(lhs.notes, rhs.notes)
                && sameText(lhs.category, rhs.category) && lhs.cleared == rhs.cleared
        }

        var description: String {
            "#\(sourceIndex) \(date) \(amount) \(payee ?? "∅") | \(notes ?? "∅") | \(category ?? "∅") \(cleared ? "C" : "-")"
        }
    }

    /// A fixture value with the harness's `{"$js": tag}` encoding for values
    /// JSON cannot carry.
    private struct JSValue: CustomStringConvertible {
        let raw: Any?

        init(_ raw: Any?) { self.raw = raw }

        private var tag: String? { (raw as? [String: Any])?["$js"] as? String }
        var isUndefined: Bool { tag == "undefined" }

        var number: Double? {
            if let tag {
                switch tag {
                case "-0": return -0.0
                case "NaN": return .nan
                case "Infinity": return .infinity
                case "-Infinity": return -.infinity
                default: return nil
                }
            }
            // `JSONSerialization` gives 0 and 1 as `NSNumber`s that Swift's
            // `is Bool` also accepts; only the CF boolean type is a JSON bool.
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }

        var string: String? { raw as? String }

        /// Same value and, for zero, the same sign; `nil` is JS `null`.
        func equalsNumber(_ value: Double?) -> Bool {
            guard let value else { return raw == nil || raw is NSNull }
            guard let number else { return false }
            if number.isNaN { return value.isNaN }
            return number == value && number.sign == value.sign
        }

        var description: String {
            tag.map { "<\($0)>" } ?? String(describing: raw ?? "null")
        }
    }

    private func report(_ mismatches: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(
            mismatches.isEmpty,
            "\(mismatches.count) case(s) differ from Actual:\n\(mismatches.prefix(Self.mismatchReportLimit).joined(separator: "\n"))",
            sourceLocation: sourceLocation
        )
    }

    private func dateFormat(_ value: Any?) throws -> ImportDateFormat {
        // A `null` format takes `parseDate`'s `default:` branch, which reads
        // `mm dd yyyy`. The modal passes null for an invalid saved format;
        // Phase 2's saved-settings reading maps that case the same way.
        if value == nil || value is NSNull { return .mmDDyyyy }
        guard let raw = value as? String, let format = ImportDateFormat(rawValue: raw) else {
            throw OracleReplayError.malformedFixture("unknown date format \(String(describing: value))")
        }
        return format
    }

    private func inputData(_ input: [String: Any]) throws -> Data {
        if let base64 = input["bytesBase64"] as? String {
            guard let decoded = Data(base64Encoded: base64) else {
                throw OracleReplayError.malformedFixture("bad bytesBase64")
            }
            return decoded
        }
        return Data(try OracleJSON.string(input, "csv").utf8)
    }

    private func table(_ input: [String: Any]) throws -> TransactionCSVParser.Table {
        let options = TransactionCSVParser.Options(
            delimiter: input["delimiter"] as? String ?? ",",
            hasHeaderRow: input["hasHeaderRow"] as? Bool ?? true,
            encoding: input["encoding"] as? String ?? "auto",
            skipStartLines: OracleJSON.int(input["skipStartLines"]) ?? 0,
            skipEndLines: OracleJSON.int(input["skipEndLines"]) ?? 0
        )
        return try TransactionCSVParser(options: options).parse(inputData(input))
    }

    private func sourceRows(_ input: [String: Any]) throws -> [ImportSourceRow] {
        ImportFieldMappingRules.sourceRows(from: try table(input))
    }

    private func categories(_ value: Any?) throws -> [ImportCategoryMatcher.Category] {
        guard let list = value as? [[String: Any]] else { return [] }
        return try list.map {
            ImportCategoryMatcher.Category(id: try OracleJSON.string($0, "id"), name: try OracleJSON.string($0, "name"))
        }
    }

    /// A mapping object from the fixture, given as an object or as
    /// `[[key, value], ...]` pairs, read the way the import reads a saved one.
    private func fieldMapping(_ value: Any) throws -> ImportFieldMapping {
        var members: [(String, JavaScriptJSONValue)] = []
        if let pairs = value as? [[Any]] {
            for pair in pairs {
                guard pair.count == 2, let key = pair[0] as? String else {
                    throw OracleReplayError.malformedFixture("bad mapping pair")
                }
                members.append((key, javaScriptJSON(pair[1])))
            }
        } else if let object = value as? [String: Any] {
            members = object.map { ($0.key, javaScriptJSON($0.value)) }
        } else {
            throw OracleReplayError.malformedFixture("mapping is neither pairs nor an object")
        }
        var targets: [ImportField: ImportMappingTarget] = [:]
        for (key, member) in members {
            if let field = ImportField(rawValue: key) { targets[field] = member.mappingTarget }
        }
        return ImportFieldMapping(targets)
    }

    private func javaScriptJSON(_ value: Any?) -> JavaScriptJSONValue {
        switch value {
        case nil, is NSNull:
            return .null
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return .bool(number.boolValue)
        case let number as NSNumber:
            return .number(number.doubleValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(javaScriptJSON))
        case let object as [String: Any]:
            return .object(object.mapValues(javaScriptJSON))
        default:
            return .null
        }
    }

    private func sameMapping(_ lhs: ImportFieldMapping?, _ rhs: ImportFieldMapping?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard Set(lhs.targets.keys) == Set(rhs.targets.keys) else { return false }
        return lhs.targets.allSatisfy { field, target in
            switch (target, rhs.targets[field]) {
            case (.null, .null?): return true
            case (.key(let left, let leftTruthy), .key(let right, let rightTruthy)?):
                return leftTruthy == rightTruthy && JavaScriptText.identical(left, right)
            default: return false
            }
        }
    }

    private func sameMappedRows(_ lhs: [MappedImportRow], _ rhs: [MappedImportRow]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { left, right in
            sameText(left.date, right.date) && sameText(left.amount, right.amount)
                && sameText(left.payeeName, right.payeeName) && sameText(left.notes, right.notes)
                && sameText(left.inOut, right.inOut) && sameText(left.category, right.category)
                && sameText(left.outflow, right.outflow) && sameText(left.inflow, right.inflow)
        }
    }
}

/// A fixture value decoded with `JSONDecoder`. `JSONSerialization` drops a
/// leading U+FEFF from every string it decodes, which would change the very
/// inputs and outputs this oracle pins. Converted to the Foundation shapes
/// `OracleJSON` reads (`NSNumber` for numbers and booleans, `NSNull`).
private enum FixtureJSON: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FixtureJSON])
    case object([String: FixtureJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([FixtureJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: FixtureJSON].self))
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return NSNumber(value: value)
        case .number(let value): return NSNumber(value: value)
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationValue)
        case .object(let values): return values.mapValues(\.foundationValue)
        }
    }
}

/// Records compared field by field with JS `===`.
private func sameNested(_ lhs: [[[String]]], _ rhs: [[[String]]]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for (left, right) in zip(lhs, rhs) {
        guard left.count == right.count else { return false }
        for (leftField, rightField) in zip(left, right) {
            guard leftField.count == rightField.count else { return false }
            for (a, b) in zip(leftField, rightField) where !JavaScriptText.identical(a, b) {
                return false
            }
        }
    }
    return true
}

/// JS `===` for optional strings: same code units, no canonical equivalence.
private func sameText(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return JavaScriptText.identical(lhs, rhs)
}
