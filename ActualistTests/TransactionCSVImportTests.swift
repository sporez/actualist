import Foundation
import Testing
@testable import Actualist

/// CSV import parse, reconcile matching, and apply coverage.
///
/// The parse cases materialize the declarative index in
/// `ActualistTests/Fixtures/Portability/CSVImport/import-cases.json` in-test
/// (synthetic strings only; the fixture asserts no parse results). Apply-level
/// tests run against the shared synthetic store fixture. No demo or user
/// budget bytes, no server, no wallet or bank-sync routing.
@MainActor
struct TransactionCSVImportTests {

    // MARK: - Parse stage (fixture index materialized in-test)

    private struct FixtureCase {
        let id: String
        let options: TransactionCSVParser.Options
        let csv: String
    }

    /// The eight cases of `import-cases.json`, verbatim.
    private static let fixtureCases: [FixtureCase] = [
        FixtureCase(
            id: "utf8-bom-header-comma",
            options: TransactionCSVParser.Options(delimiter: ",", hasHeaderRow: true),
            csv: "\u{FEFF}Date,Payee,Notes,Amount\r\n2026-09-27,Sample Market,Groceries,12.34\r\n"
        ),
        FixtureCase(
            id: "quoted-delimiter-and-escaped-quote",
            options: TransactionCSVParser.Options(delimiter: ",", hasHeaderRow: true),
            csv: "Date,Payee,Notes,Amount\n2026-09-27,\"Market, North\",\"Said \"\"hello\"\"\",12.34\n"
        ),
        FixtureCase(
            id: "quoted-embedded-newline",
            options: TransactionCSVParser.Options(delimiter: ",", hasHeaderRow: true),
            csv: "Date,Payee,Notes,Amount\n2026-09-27,Sample Store,\"First line\nSecond line\",12.34\n"
        ),
        FixtureCase(
            id: "tab-delimiter",
            options: TransactionCSVParser.Options(delimiter: "\t", hasHeaderRow: true),
            csv: "Date\tPayee\tAmount\n2026-09-27\tSample Store\t12.34\n"
        ),
        FixtureCase(
            id: "relaxed-short-row",
            options: TransactionCSVParser.Options(delimiter: ",", hasHeaderRow: true),
            csv: "Date,Payee,Notes,Amount\n2026-09-27,Sample Store,,12.34\n2026-09-28,Second Store\n"
        ),
        FixtureCase(
            id: "relaxed-extra-column",
            options: TransactionCSVParser.Options(delimiter: ",", hasHeaderRow: true),
            csv: "Date,Payee,Amount\n2026-09-27,Sample Store,12.34,unmapped synthetic value\n"
        ),
        FixtureCase(
            id: "blank-lines",
            options: TransactionCSVParser.Options(delimiter: ",", hasHeaderRow: true),
            csv: "Date,Payee,Amount\n\n2026-09-27,Sample Store,12.34\n\n"
        ),
        FixtureCase(
            id: "headerless-configured-columns",
            options: TransactionCSVParser.Options(delimiter: ",", hasHeaderRow: false),
            csv: "2026-09-27,Sample Store,synthetic note,12.34\n"
        ),
    ]

    @Test func parsesBOMHeaderCommaWithCRLF() throws {
        let table = try TransactionCSVParser(options: fixtureCase("utf8-bom-header-comma").options)
            .parse(Data(fixtureCase("utf8-bom-header-comma").csv.utf8))
        #expect(table.headers == ["Date", "Payee", "Notes", "Amount"])
        #expect(table.rows.count == 1)
        #expect(table.rows[0] == ["2026-09-27", "Sample Market", "Groceries", "12.34"])
        #expect(table.value(header: "Payee", in: table.rows[0]) == "Sample Market")
    }

    @Test func parsesQuotedDelimiterAndEscapedQuote() throws {
        let table = try parseFixtureCase("quoted-delimiter-and-escaped-quote")
        #expect(table.rows.count == 1)
        #expect(table.rows[0] == ["2026-09-27", "Market, North", "Said \"hello\"", "12.34"])
    }

    @Test func parsesQuotedEmbeddedNewlineAsOneRow() throws {
        let table = try parseFixtureCase("quoted-embedded-newline")
        #expect(table.rows.count == 1)
        #expect(table.rows[0][2] == "First line\nSecond line")
    }

    @Test func parsesTabDelimiter() throws {
        let table = try parseFixtureCase("tab-delimiter")
        #expect(table.headers == ["Date", "Payee", "Amount"])
        #expect(table.rows.count == 1)
        #expect(table.rows[0] == ["2026-09-27", "Sample Store", "12.34"])
        #expect(table.value(header: "Notes", in: table.rows[0]) == nil)
    }

    @Test func parsesRelaxedShortRowWithMissingFields() throws {
        let table = try parseFixtureCase("relaxed-short-row")
        #expect(table.rows.count == 2)
        #expect(table.rows[0] == ["2026-09-27", "Sample Store", "", "12.34"])
        // Short rows are accepted with the missing fields absent.
        #expect(table.rows[1] == ["2026-09-28", "Second Store"])
        #expect(table.value(header: "Amount", in: table.rows[1]) == nil)
    }

    @Test func parsesRelaxedExtraColumnByDroppingExtras() throws {
        let table = try parseFixtureCase("relaxed-extra-column")
        #expect(table.rows.count == 1)
        #expect(table.rows[0] == ["2026-09-27", "Sample Store", "12.34"])
    }

    @Test func dropsBlankLinesInsteadOfRejectingThem() throws {
        let table = try parseFixtureCase("blank-lines")
        #expect(table.rows.count == 1)
        #expect(table.rows[0] == ["2026-09-27", "Sample Store", "12.34"])
    }

    @Test func parsesHeaderlessRowsPositionally() throws {
        let table = try parseFixtureCase("headerless-configured-columns")
        #expect(table.headers == nil)
        #expect(table.rows == [["2026-09-27", "Sample Store", "synthetic note", "12.34"]])
    }

    // MARK: - Mapping stage

    @Test func mapsHeaderedRowsWithInflowSignAndMissingFields() throws {
        let table = try TransactionCSVParser().parse(Data(
            "Date,Payee,Notes,Amount\n2026-09-27,Sample Market,Groceries,12.34\n".utf8
        ))
        let rows = try TransactionCSVImportMapper.map(table)
        #expect(rows.count == 1)
        // Positive amounts are inflow; the sign carries direction.
        #expect(rows[0].amountMinorUnits == 1_234)
        #expect(rows[0].payeeName == "Sample Market")
        #expect(rows[0].notes == "Groceries")
        #expect(rows[0].dateText == "2026-09-27")
        #expect(rows[0].cleared == nil)
    }

    @Test func mapsNegativeAmountsAsOutflowAndResolvesClearedColumn() throws {
        let table = try TransactionCSVParser().parse(Data(
            "Date,Payee,Amount,Cleared\n2026-09-27,Sample Market,-12.34,Not cleared\n2026-09-28,Other,3,Cleared\n"
            .utf8
        ))
        let rows = try TransactionCSVImportMapper.map(table)
        #expect(rows[0].amountMinorUnits == -1_234)
        #expect(rows[0].cleared == false)
        #expect(rows[1].amountMinorUnits == 300)
        #expect(rows[1].cleared == true)
    }

    @Test func rejectsNonISODateAndUnparseableAmountForTheWholeBatch() throws {
        #expect(throws: TransactionCSVImportError.invalidRow(line: 1, reason: .unparseableDate(text: "27/09/2026"))) {
            let table = try TransactionCSVParser().parse(Data(
                "Date,Payee,Amount\n27/09/2026,Sample Market,12.34\n".utf8
            ))
            _ = try TransactionCSVImportMapper.map(table)
        }
        #expect(throws: TransactionCSVImportError.invalidRow(line: 1, reason: .unparseableAmount(text: "abc"))) {
            let table = try TransactionCSVParser().parse(Data(
                "Date,Payee,Amount\n2026-09-27,Sample Market,abc\n".utf8
            ))
            _ = try TransactionCSVImportMapper.map(table)
        }
    }

    @Test func rejectsZeroAmountRowsBecauseTheWriteEngineRequiresNonZero() throws {
        #expect(throws: TransactionCSVImportError.invalidRow(line: 1, reason: .zeroAmount)) {
            let table = try TransactionCSVParser().parse(Data(
                "Date,Payee,Notes,Amount\n2026-09-28,Second Store\n".utf8
            ))
            _ = try TransactionCSVImportMapper.map(table)
        }
    }

    // MARK: - Apply stage (shared synthetic store fixture)

    private static let fixtureSQL = """
        ALTER TABLE transactions ADD COLUMN imported_id TEXT;
        ALTER TABLE transactions ADD COLUMN imported_description TEXT;
        INSERT INTO payees VALUES ('to-savings', 'To Savings', 'savings', 0);
        INSERT INTO payee_mapping VALUES ('to-savings', 'to-savings');
        """

    private func makeBundle() async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        try await LocalFirstActualStoreTests().makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.fixtureSQL
        )
    }

    private func csv(_ body: String, header: String = "Date,Payee,Notes,Amount") -> Data {
        Data((header + "\n" + body + "\n").utf8)
    }

    private func checkingRows(_ database: BudgetDatabase) async throws -> [ActualTransaction] {
        try await database.fetchTransactions(accountID: "checking")
    }

    @Test func sameFileAppliedTwiceIsNoOpWithImportedID() async throws {
        let bundle = try await makeBundle()
        let database = try #require(bundle.store.database)
        let withImportedID = Data((
            "Date,Payee,Notes,Amount,imported_id\n2026-09-27,Sample Market,Groceries,12.34,bank-1\n"
        ).utf8)

        let first = try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: "checking",
                sessionGeneration: bundle.store.budgetSessionGeneration,
                rows: try preparedRows(bundle.store, data: withImportedID, accountID: "checking")
            )
        )
        #expect(first.insertedCount == 1)
        #expect(first.updatedCount == 0)
        #expect(try await checkingRows(database).count == 2)

        let second = try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: "checking",
                sessionGeneration: bundle.store.budgetSessionGeneration,
                rows: try preparedRows(bundle.store, data: withImportedID, accountID: "checking")
            )
        )
        #expect(second.insertedCount == 0)
        #expect(second.updatedCount == 0)
        #expect(try await checkingRows(database).count == 2)

        let imported = try await checkingRows(database).first { $0.importedPayee == "Sample Market" }
        #expect(imported != nil)
        #expect(imported?.payeeName == "Sample Market")
        #expect(imported?.amount == 1_234)
        #expect(imported?.date == "2026-09-27")
    }

    @Test func sameFileAppliedTwiceIsNoOpWithoutImportedID() async throws {
        let bundle = try await makeBundle()
        let database = try #require(bundle.store.database)
        let data = csv("2026-09-27,Sample Market,Groceries,12.34")

        let first = try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: "checking",
                sessionGeneration: bundle.store.budgetSessionGeneration,
                rows: try preparedRows(bundle.store, data: data, accountID: "checking")
            )
        )
        #expect(first.insertedCount == 1)
        #expect(try await checkingRows(database).count == 2)

        let second = try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: "checking",
                sessionGeneration: bundle.store.budgetSessionGeneration,
                rows: try preparedRows(bundle.store, data: data, accountID: "checking")
            )
        )
        #expect(second.insertedCount == 0)
        #expect(second.updatedCount == 0)
        #expect(try await checkingRows(database).count == 2)
    }

    @Test func changedPayeeTextUpdatesImportedPayeeOnTheMatchedRow() async throws {
        let bundle = try await makeBundle()
        let database = try #require(bundle.store.database)
        let firstFile = csv("2026-09-02,Fuzzy Market,,-19.99")
        let secondFile = csv("2026-09-05,Different Payee,,-19.99")

        _ = try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: "checking",
                sessionGeneration: bundle.store.budgetSessionGeneration,
                rows: try preparedRows(bundle.store, data: firstFile, accountID: "checking")
            )
        )
        let second = try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: "checking",
                sessionGeneration: bundle.store.budgetSessionGeneration,
                rows: try preparedRows(bundle.store, data: secondFile, accountID: "checking")
            )
        )
        #expect(second.updatedCount == 1)
        #expect(second.insertedCount == 0)
        #expect(try await checkingRows(database).count == 2)
        let matched = try await checkingRows(database).first { $0.payeeName == "Fuzzy Market" }
        #expect(matched?.importedPayee == "Different Payee")
        #expect(matched?.amount == -1_999)
    }

    @Test func identicalRowsInOneBatchBothInsert() async throws {
        let bundle = try await makeBundle()
        let database = try #require(bundle.store.database)
        let data = csv("2026-09-27,Sample Market,Groceries,12.34\n2026-09-27,Sample Market,Groceries,12.34")

        let result = try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: "checking",
                sessionGeneration: bundle.store.budgetSessionGeneration,
                rows: try preparedRows(bundle.store, data: data, accountID: "checking")
            )
        )
        #expect(result.insertedCount == 2)
        #expect(try await checkingRows(database).count == 3)
    }

    @Test func transferPayeeRowCreatesTheMirrorTransaction() async throws {
        let bundle = try await makeBundle()
        let database = try #require(bundle.store.database)
        let data = csv("2026-09-10,To Savings,,-50.00")

        let result = try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: "checking",
                sessionGeneration: bundle.store.budgetSessionGeneration,
                rows: try preparedRows(bundle.store, data: data, accountID: "checking")
            )
        )
        #expect(result.insertedCount == 1)

        let savingsRows = try await database.fetchTransactions(accountID: "savings")
        #expect(savingsRows.count == 1)
        let mirror = savingsRows[0]
        // The mirror: negated amount, the source account's transfer payee,
        // uncleared, no category.
        #expect(mirror.amount == 5_000)
        #expect(mirror.payee == "xfer-checking")
        #expect(mirror.cleared == FlexibleBool.bool(false))
        #expect(mirror.category == nil)
        #expect(mirror.date == "2026-09-10")

        let imported = try await checkingRows(database).first { $0.payee == "to-savings" }
        #expect(imported?.amount == -5_000)
    }

    @Test func invalidRowRejectsTheWholeBatchWithZeroRowsWritten() async throws {
        let bundle = try await makeBundle()
        let database = try #require(bundle.store.database)
        let before = try await checkingRows(database).count
        let data = csv("2026-09-27,Sample Market,Groceries,12.34\n2026-09-28,Bad Row,abc")

        await #expect(throws: TransactionCSVImportError.self) {
            try await bundle.store.prepareTransactionCSVImport(
                TransactionCSVImportPreparationRequest(
                    budgetID: "group-1",
                    accountID: "checking",
                    data: data,
                    options: TransactionCSVImportOptions()
                )
            )
        }
        #expect(try await checkingRows(database).count == before)
    }

    @Test func exporterRoundTripImportsAnEncoderExport() async throws {
        let bundle = try await makeBundle()
        let database = try #require(bundle.store.database)

        let exportedRows = [
            TransactionCSVExportRow(
                id: "round-trip-1", familyID: "round-trip-1", accountName: "Checking",
                date: "2026-09-01", payeeName: "Sample Shop", notes: nil,
                categoryGroupName: "Food", categoryName: "Groceries",
                amountMinorUnits: -12_345, isCleared: false, isReconciled: false,
                isParent: false, isChild: false
            ),
            TransactionCSVExportRow(
                id: "round-trip-2", familyID: "round-trip-2", accountName: "Checking",
                date: "2026-09-02", payeeName: "Café \"North\"",
                notes: "line one\nline two, quoted \"text\"",
                categoryGroupName: "Food", categoryName: "Groceries",
                amountMinorUnits: 67_890, isCleared: true, isReconciled: false,
                isParent: false, isChild: false
            ),
        ]
        let export = await TransactionCSVEncoder().encode(exportedRows, generatedAt: Self.fixedGenerationDate())

        let review = try await bundle.store.prepareTransactionCSVImport(
            TransactionCSVImportPreparationRequest(
                budgetID: "group-1",
                accountID: "checking",
                data: export.data,
                options: TransactionCSVImportOptions()
            )
        )
        #expect(review.rows.count == 2)
        #expect(review.rows.allSatisfy { $0.outcome.kind == .insert })
        #expect(review.rows[0].row.amountMinorUnits == -12_345)
        #expect(review.rows[0].row.dateText == "2026-09-01")
        #expect(review.rows[0].row.payeeName == "Sample Shop")
        #expect(review.rows[0].row.cleared == false)
        #expect(review.rows[1].row.amountMinorUnits == 67_890)
        #expect(review.rows[1].row.payeeName == "Café \"North\"")
        #expect(review.rows[1].row.notes == "line one\nline two, quoted \"text\"")
        #expect(review.rows[1].row.cleared == true)
        #expect(review.rows[1].row.categoryName == "Groceries")

        let result = try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: "checking",
                sessionGeneration: bundle.store.budgetSessionGeneration,
                rows: review.rows
            )
        )
        #expect(result.insertedCount == 2)

        let imported = try await checkingRows(database).filter { $0.id != "txn" }
        #expect(imported.count == 2)
        #expect(imported.contains { $0.amount == -12_345 && $0.payeeName == "Sample Shop" })
        #expect(imported.contains { $0.amount == 67_890 && $0.cleared == .bool(true) && $0.category == "groceries" })
    }

    // MARK: - Helpers

    private func parseFixtureCase(_ id: String) throws -> TransactionCSVParser.Table {
        let fixture = fixtureCase(id)
        return try TransactionCSVParser(options: fixture.options).parse(Data(fixture.csv.utf8))
    }

    private func fixtureCase(_ id: String) -> FixtureCase {
        Self.fixtureCases.first { $0.id == id }!
    }

    private func preparedRows(
        _ store: LocalFirstActualStore,
        data: Data,
        accountID: String
    ) async throws -> [TransactionCSVImportReviewRow] {
        let review = try await store.prepareTransactionCSVImport(
            TransactionCSVImportPreparationRequest(
                budgetID: "group-1",
                accountID: accountID,
                data: data,
                options: TransactionCSVImportOptions()
            )
        )
        return review.rows.filter { $0.outcome.writes }
    }

    private static func fixedGenerationDate() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 29))!
    }
}
