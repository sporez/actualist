import Foundation
import Testing
@testable import Actualist

private enum TransactionCSVImporterInteropConfiguration {
    static let outputEnvironment = "ACTUALIST_CSV_INTEROP_OUTPUT"
    static let encoderHashEnvironment = "ACTUALIST_CSV_INTEROP_ENCODER_SHA256"
    static let testHashEnvironment = "ACTUALIST_CSV_INTEROP_TEST_SHA256"

    static var isConfigured: Bool {
        ProcessInfo.processInfo.environment[outputEnvironment] != nil
    }
}

struct TransactionCSVImporterInteropTests {
    @Test(
        .enabled(
            if: TransactionCSVImporterInteropConfiguration.isConfigured,
            "Requires the reviewed CSV interoperability runner; a normal suite records this test as skipped."
        )
    )
    func writesActualImporterInteropFixture() async throws {
        let configuration = try configuration()
        let cases = fixtureCases()
        let export = await TransactionCSVEncoder().encode(cases.map(\.row), generatedAt: fixedGenerationDate())

        #expect(export.exportedFamilyCount == 7)
        #expect(export.exportedRowCount == cases.count)

        let manifest = Manifest(
            schema: 1,
            scope: "Synthetic production-encoder fixture for pinned Actual parser/mapping observation; not a lossless import or split round-trip claim.",
            generatedFilename: export.suggestedFilename,
            header: [
                "Account", "Date", "Payee", "Notes", "Category_Group", "Category", "Amount", "Split_Amount", "Cleared",
            ],
            source: SourceFreeze(
                actualCommit: "59fe126f637d858c061e1eeedbef5436c8f2225a",
                actualVersion: "26.9.0",
                encoderSHA256: configuration.encoderSHA256,
                fixtureTestSHA256: configuration.testSHA256
            ),
            cases: cases.map(\.manifest)
        )

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: configuration.outputDirectory, withIntermediateDirectories: true)
        let existingFiles = try fileManager.contentsOfDirectory(
            at: configuration.outputDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(existingFiles.isEmpty, "The fixture destination must be a fresh, runner-owned directory.")
        guard existingFiles.isEmpty else {
            throw FixtureError.nonemptyOutputDirectory
        }

        try export.data.write(to: configuration.outputDirectory.appending(path: "transaction-export.csv"), options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var manifestData = try encoder.encode(manifest)
        manifestData.append(0x0A)
        try manifestData.write(to: configuration.outputDirectory.appending(path: "manifest.json"), options: .atomic)

        let writtenFiles = try fileManager.contentsOfDirectory(
            at: configuration.outputDirectory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        #expect(writtenFiles == ["manifest.json", "transaction-export.csv"])
    }

    private func configuration() throws -> Configuration {
        let environment = ProcessInfo.processInfo.environment
        let rawOutput = try requiredEnvironment(
            TransactionCSVImporterInteropConfiguration.outputEnvironment,
            environment: environment
        )
        let output = URL(filePath: rawOutput, directoryHint: .isDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        // <repo>/ActualistTests/<this file> -> <repo>/.artifacts/csv-export-interop
        let requiredRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: ".artifacts/csv-export-interop", directoryHint: .isDirectory)
            .standardizedFileURL
            .path
        guard output.path.hasPrefix(requiredRoot + "/"), output.path.count > requiredRoot.count + 1 else {
            throw FixtureError.outputOutsideOwnedArtifactDirectory(output.path)
        }

        return Configuration(
            outputDirectory: output,
            encoderSHA256: try requiredSHA256(
                TransactionCSVImporterInteropConfiguration.encoderHashEnvironment,
                environment: environment
            ),
            testSHA256: try requiredSHA256(
                TransactionCSVImporterInteropConfiguration.testHashEnvironment,
                environment: environment
            )
        )
    }

    private func requiredEnvironment(_ name: String, environment: [String: String]) throws -> String {
        guard let value = environment[name], !value.isEmpty else {
            throw FixtureError.missingEnvironment(name)
        }
        return value
    }

    private func requiredSHA256(_ name: String, environment: [String: String]) throws -> String {
        let value = try requiredEnvironment(name, environment: environment)
        let isLowercaseSHA256 = value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains(Int($0.value)) || (97...102).contains(Int($0.value))
        }
        guard isLowercaseSHA256 else { throw FixtureError.invalidSHA256(name) }
        return value
    }

    private func fixtureCases() -> [FixtureCase] {
        [
            fixture(
                id: "ordinary-debit-not-cleared",
                row: row(id: "ordinary-debit", amount: -12_345),
                expected: fields(amount: "-123.45", cleared: "Not cleared"),
                intent: "Ordinary negative debit and not-cleared status."
            ),
            fixture(
                id: "ordinary-credit-cleared",
                row: row(id: "ordinary-credit", date: "2026-09-02", amount: 67_890, isCleared: true),
                expected: fields(date: "2026-09-02", amount: "678.9", cleared: "Cleared"),
                intent: "Ordinary positive credit and cleared status."
            ),
            fixture(
                id: "split-parent-reconciled",
                row: row(
                    id: "split-parent", familyID: "split-parent", date: "2026-09-03", notes: "family note",
                    categoryGroup: "", category: "", amount: -5_000, isReconciled: true, isParent: true
                ),
                expected: fields(
                    date: "2026-09-03", notes: "(SPLIT INTO 2) family note", categoryGroup: "", category: "",
                    amount: "0", splitAmount: "-50", cleared: "Reconciled"
                ),
                intent: "Split parent marker, parent total in Split_Amount, and reconciled status."
            ),
            fixture(
                id: "split-child-one",
                row: row(
                    id: "split-child-one", familyID: "split-parent", date: "2026-09-03", notes: "first child",
                    amount: -3_000, isCleared: true, isChild: true
                ),
                expected: fields(
                    date: "2026-09-03", notes: "(SPLIT 1 OF 2) first child", amount: "-30", cleared: "Cleared"
                ),
                intent: "First physical split-child row."
            ),
            fixture(
                id: "split-child-two",
                row: row(
                    id: "split-child-two", familyID: "split-parent", date: "2026-09-03", notes: "second child",
                    amount: -2_000, isReconciled: true, isChild: true
                ),
                expected: fields(
                    date: "2026-09-03", notes: "(SPLIT 2 OF 2) second child", amount: "-20", cleared: "Reconciled"
                ),
                intent: "Second physical split-child row; no reconstruction is asserted."
            ),
            fixture(
                id: "quoted-crlf-unicode",
                row: row(
                    id: "quoted", account: "Wallet, East", date: "2026-09-04", payee: "Café \"North\" — 東京",
                    notes: "line one\r\nline two, quoted \"text\"", categoryGroup: "Daily, Needs",
                    category: "Crème brûlée", amount: -42
                ),
                expected: fields(
                    account: "Wallet, East", date: "2026-09-04", payee: "Café \"North\" — 東京",
                    notes: "line one\r\nline two, quoted \"text\"", categoryGroup: "Daily, Needs",
                    category: "Crème brûlée", amount: "-0.42"
                ),
                intent: "RFC quoting, embedded CRLF, comma, quote, and Unicode preservation."
            ),
            fixture(
                id: "formula-trigger-strings-including-date",
                row: row(
                    id: "formula", account: "=Account", date: "=2026-09-05", payee: "+Payee", notes: "@note",
                    categoryGroup: "\tGroup", category: "\rCategory", amount: -100
                ),
                expected: fields(
                    account: "'=Account", date: "'=2026-09-05", payee: "'+Payee", notes: "'@note",
                    categoryGroup: "'\tGroup", category: "'\rCategory", amount: "-1"
                ),
                intent: "Spreadsheet-formula apostrophe prefixes in every exported string column, including Date."
            ),
            fixture(
                id: "empty-names",
                row: row(
                    id: "empty", account: "", date: "2026-09-06", payee: "", notes: nil,
                    categoryGroup: "", category: "", amount: 0
                ),
                expected: fields(
                    account: "", date: "2026-09-06", payee: "", notes: "", categoryGroup: "", category: "", amount: "0"
                ),
                intent: "Empty account, payee, note, category group, and category names."
            ),
            fixture(
                id: "extreme-negative-amount",
                row: row(id: "extreme", date: "2026-09-07", amount: .min),
                expected: fields(date: "2026-09-07", amount: "-92233720368547758.08"),
                intent: "Exact Swift Int minimum formatting; JavaScript mapping precision is observational."
            ),
        ]
    }

    private func fixture(id: String, row: TransactionCSVExportRow, expected: [String: String], intent: String) -> FixtureCase {
        FixtureCase(row: row, manifest: ManifestCase(id: id, intent: intent, expectedRawFields: expected))
    }

    private func fields(
        account: String = "Checking",
        date: String = "2026-09-01",
        payee: String = "Sample Shop",
        notes: String = "",
        categoryGroup: String = "Food",
        category: String = "Groceries",
        amount: String,
        splitAmount: String = "0",
        cleared: String = "Not cleared"
    ) -> [String: String] {
        [
            "Account": account, "Date": date, "Payee": payee, "Notes": notes,
            "Category_Group": categoryGroup, "Category": category,
            "Amount": amount, "Split_Amount": splitAmount, "Cleared": cleared,
        ]
    }

    private func row(
        id: String,
        familyID: String? = nil,
        account: String = "Checking",
        date: String = "2026-09-01",
        payee: String = "Sample Shop",
        notes: String? = nil,
        categoryGroup: String = "Food",
        category: String = "Groceries",
        amount: Int,
        isCleared: Bool = false,
        isReconciled: Bool = false,
        isParent: Bool = false,
        isChild: Bool = false
    ) -> TransactionCSVExportRow {
        TransactionCSVExportRow(
            id: id,
            familyID: familyID ?? id,
            accountName: account,
            date: date,
            payeeName: payee,
            notes: notes,
            categoryGroupName: categoryGroup,
            categoryName: category,
            amountMinorUnits: amount,
            isCleared: isCleared,
            isReconciled: isReconciled,
            isParent: isParent,
            isChild: isChild
        )
    }

    private func fixedGenerationDate() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 29))!
    }
}

private struct Configuration {
    let outputDirectory: URL
    let encoderSHA256: String
    let testSHA256: String
}

private struct FixtureCase {
    let row: TransactionCSVExportRow
    let manifest: ManifestCase
}

private struct Manifest: Encodable {
    let schema: Int
    let scope: String
    let generatedFilename: String
    let header: [String]
    let source: SourceFreeze
    let cases: [ManifestCase]
}

private struct SourceFreeze: Encodable {
    let actualCommit: String
    let actualVersion: String
    let encoderSHA256: String
    let fixtureTestSHA256: String
}

private struct ManifestCase: Encodable {
    let id: String
    let intent: String
    let expectedRawFields: [String: String]
}

private enum FixtureError: Error {
    case missingEnvironment(String)
    case invalidSHA256(String)
    case outputOutsideOwnedArtifactDirectory(String)
    case nonemptyOutputDirectory
}
