import Foundation
import Testing
@testable import Actualist

/// CSV import parse, reconcile matching, and apply coverage.
///
/// The parse cases use synthetic strings only. Apply-level
/// tests run against the shared synthetic store fixture. No demo or user
/// budget bytes, no server, no wallet or bank-sync routing.
@MainActor
struct TransactionCSVImportTests {

    // MARK: - Parse stage

    private struct FixtureCase {
        let id: String
        let options: TransactionCSVParser.Options
        let csv: String
    }

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
    }

    @Test func parsesRelaxedShortRowWithMissingFields() throws {
        let table = try parseFixtureCase("relaxed-short-row")
        #expect(table.rows.count == 2)
        #expect(table.rows[0] == ["2026-09-27", "Sample Store", "", "12.34"])
        // Short rows are accepted with the missing fields absent.
        #expect(table.rows[1] == ["2026-09-28", "Second Store"])
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

    /// csv-parse discovers the record delimiter from the first line ending,
    /// so a CR-only file reads like any other.
    @Test func parsesCROnlyLineEndings() throws {
        let table = try TransactionCSVParser().parse(Data("Date,Payee\r2026-09-27,Sample Store\r".utf8))
        #expect(table.headers == ["Date", "Payee"])
        #expect(table.rows == [["2026-09-27", "Sample Store"]])
    }

    /// Like Actual's import, a quote mark after other text refuses the file.
    @Test func aStrayQuoteRefusesTheFileLikeActual() async throws {
        await #expect(throws: TransactionCSVImportError.unreadableFile(.invalidOpeningQuote(line: 2))) {
            _ = try await TransactionCSVImportPipeline.rows(
                from: Data("Date,Payee,Amount\n2026-09-27,Joe\"s Diner,1\n".utf8),
                options: TransactionCSVImportOptions()
            )
        }
    }

    @Test func parsesHeaderlessRowsPositionally() throws {
        let table = try parseFixtureCase("headerless-configured-columns")
        #expect(table.headers == nil)
        #expect(table.rows == [["2026-09-27", "Sample Store", "synthetic note", "12.34"]])
    }

    // MARK: - Mapping stage

    private func mapped(_ csv: String) throws -> TransactionCSVImportMapper.Result {
        try TransactionCSVImportMapper.map(TransactionCSVParser().parse(Data(csv.utf8)))
    }

    @Test func mapsHeaderedRowsWithInflowSignAndMissingFields() throws {
        let rows = try mapped("Date,Payee,Notes,Amount\n2026-09-27,Sample Market,Groceries,12.34\n").rows
        #expect(rows.count == 1)
        // Positive amounts are inflow; the sign carries direction.
        #expect(rows[0].amountMinorUnits == 1_234)
        #expect(rows[0].payeeName == "Sample Market")
        #expect(rows[0].notes == "Groceries")
        #expect(rows[0].dateText == "2026-09-27")
        // Actual's "Clear transactions on import" is on by default.
        #expect(rows[0].cleared == true)
        #expect(rows[0].importedID == nil)
    }

    /// Actual's modal reads neither a Cleared nor an imported_id column. With
    /// no Notes header, the first spare column becomes the notes.
    @Test func ignoresClearedAndImportedIDColumnsLikeActual() throws {
        let cleared = try mapped(
            "Date,Payee,Amount,Cleared\n2026-09-27,Sample Market,-12.34,Not cleared\n2026-09-28,Other,3,Cleared\n"
        ).rows
        #expect(cleared.map(\.amountMinorUnits) == [-1_234, 300])
        #expect(cleared.map(\.cleared) == [true, true])
        #expect(cleared.map(\.notes) == ["Not cleared", "Cleared"])

        let withID = try mapped(
            "Date,Payee,Notes,Amount,imported_id\n2026-09-27,Sample Market,Groceries,12.34,bank-1\n"
        ).rows
        #expect(withID[0].importedID == nil)
        #expect(withID[0].notes == "Groceries")
    }

    @Test func readsCurrencyFormattedAmounts() throws {
        let rows = try mapped(
            "Date,Payee,Amount\n2026-09-27,A,$25.00\n2026-09-26,B,\"$1,234.56\"\n2026-09-25,C,(12.50)\n2026-09-24,D,\"1.234,56\"\n"
        ).rows
        #expect(rows.map(\.amountMinorUnits) == [2_500, 123_456, -1_250, 123_456])
        #expect(rows.allSatisfy { !$0.amountUnreadable })
    }

    @Test func guessesADayFirstDateFormatFromTheFirstRow() throws {
        let result = try mapped("Date,Payee,Amount\n27/09/2026,Sample Market,12.34\n03/10/2026,Other,1\n")
        #expect(result.dateFormat == .ddMMyyyy)
        #expect(result.rows.map(\.dateText) == ["2026-09-27", "2026-10-03"])
    }

    @Test func aDateThatDoesNotReadRejectsTheWholeBatch() throws {
        #expect(throws: TransactionCSVImportError.invalidRow(
            line: 2, reason: .unparseableDate(text: "31/02/2026", format: .ddMMyyyy)
        )) {
            _ = try mapped("Date,Payee,Amount\n27/09/2026,Sample Market,12.34\n31/02/2026,Other,1\n")
        }
    }

    /// Actual imports an amount it cannot read as 0; the review points it out.
    @Test func anUnreadableAmountImportsAsZeroAndIsMarked() throws {
        let rows = try mapped("Date,Payee,Amount\n2026-09-27,Sample Market,abc\n").rows
        #expect(rows[0].amountMinorUnits == 0)
        #expect(rows[0].amountUnreadable)
    }

    /// Actual's import modal turns an empty or zero amount into a zero-amount
    /// row (`parseAmountFields`, then only a null amount is refused).
    @Test func mapsAnEmptyOrZeroAmountToAZeroAmountRow() throws {
        let rows = try mapped("Date,Payee,Notes,Amount\n2026-09-28,Second Store\n2026-09-29,Third Store,,0\n").rows
        #expect(rows.map(\.amountMinorUnits) == [0, 0])
        #expect(rows.allSatisfy { !$0.amountUnreadable })
    }

    /// The preview sorts newest first, but only by a column named exactly
    /// `date`; a `Date` column keeps file order.
    @Test func sortsNewestFirstOnlyByALowercaseDateColumn() throws {
        let lower = try mapped("date,Payee,Amount\n2026-09-01,A,1\n2026-09-03,B,1\n2026-09-02,C,1\n")
        #expect(lower.rows.map(\.payeeName) == ["B", "C", "A"])
        #expect(lower.rows.map(\.sourceLine) == [2, 3, 1])
        let upper = try mapped("Date,Payee,Amount\n2026-09-01,A,1\n2026-09-03,B,1\n2026-09-02,C,1\n")
        #expect(upper.rows.map(\.payeeName) == ["A", "B", "C"])
    }

    /// Actual's own export lists Category_Group before Category, so its
    /// import takes the group column as the category.
    @Test func actualsExportHeaderMapsTheCategoryGroupColumn() throws {
        let rows = try mapped(
            "Account,Date,Payee,Notes,Category_Group,Category,Amount,Split_Amount,Cleared\n"
                + "Checking,2026-09-01,Sample Shop,,Food,Groceries,-123.45,0,Not cleared\n"
        ).rows
        #expect(rows[0].categoryName == "Food")
        #expect(rows[0].amountMinorUnits == -12_345)
    }

    @Test func matchesCategoriesExactlyInActualsListOrder() {
        let matcher = ImportCategoryMatcher(categories: [
            .init(id: "c1", name: "Groceries"), .init(id: "c2", name: "Groceries"), .init(id: "Dining", name: "Dining"),
        ])
        #expect(matcher.categoryID(forText: "Groceries") == "c1")
        #expect(matcher.categoryID(forText: "groceries") == nil)
        // A category whose id equals the text is skipped.
        #expect(matcher.categoryID(forText: "Dining") == nil)
        // No canonical equivalence: a decomposed accent is different text.
        #expect(ImportCategoryMatcher(categories: [.init(id: "c", name: "Caf\u{E9}")]).categoryID(forText: "Cafe\u{301}") == nil)
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

    /// Actual's account export writes each split as a zero-amount parent row
    /// followed by its children (`exportQueryToCSV`), and Actual's import adds
    /// every row as its own transaction. A second import changes nothing.
    @Test func importsActualsSplitExportRowByRowLikeActual() async throws {
        let bundle = try await makeBundle()
        let database = try #require(bundle.store.database)
        let data = csv(
            """
            Checking,2026-09-27,Sample Market,(SPLIT INTO 2) ,,,0,-30.00,Not cleared
            Checking,2026-09-27,Sample Market,(SPLIT 1 OF 2) ,group,Utilities,-10.00,0,Not cleared
            Checking,2026-09-27,Sample Market,(SPLIT 2 OF 2) ,group,Utilities,-20.00,0,Not cleared
            """,
            header: "Account,Date,Payee,Notes,Category_Group,Category,Amount,Split_Amount,Cleared"
        )
        let before = try await checkingRows(database).count

        let first = try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: "checking",
                sessionGeneration: bundle.store.budgetSessionGeneration,
                rows: try preparedRows(bundle.store, data: data, accountID: "checking")
            )
        )
        #expect(first.insertedCount == 3)
        let imported = try await checkingRows(database).filter { $0.importedPayee == "Sample Market" }
        #expect(imported.compactMap(\.amount).sorted() == [-2_000, -1_000, 0])
        #expect(try await checkingRows(database).count == before + 3)

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
        #expect(try await checkingRows(database).count == before + 3)
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
        let data = csv("2026-09-27,Sample Market,Groceries,12.34\n2026-02-30,Bad Row,,1.00")

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
        #expect(review.rows[0].row.cleared == true)
        #expect(review.rows[1].row.amountMinorUnits == 67_890)
        #expect(review.rows[1].row.payeeName == "Café \"North\"")
        #expect(review.rows[1].row.notes == "line one\nline two, quoted \"text\"")
        #expect(review.rows[1].row.cleared == true)
        // Actual's import takes Category_Group, the first header naming a
        // category, and no category is named "Food".
        #expect(review.rows[1].row.categoryName == "Food")

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
        #expect(imported.contains { $0.amount == 67_890 && $0.cleared == .bool(true) && $0.category == nil })
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
