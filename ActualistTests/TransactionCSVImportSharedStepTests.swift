import Foundation
import GRDB
import Testing
@testable import Actualist

/// CSV import runs the same rules and reconcile as Bank Sync (main-to-dev D4,
/// audit F-2 and F-9): rules before matching, upstream CSV defaults, and an
/// exact `imported_id` commit precondition.
@MainActor
struct TransactionCSVImportSharedStepTests {
    private typealias Bundle = LocalFirstActualStoreTests.OpenedWritableStoreBundle

    private static let scheduleDay = "2026-09-30"

    /// `rent` is a posting schedule whose rule links it to a matching row.
    /// `rule-*` rows are user rules keyed on the imported payee text.
    private static let fixtureSQL = TransactionCSVImportRevalidationTests.fixtureSQL + """
        ALTER TABLE transactions ADD COLUMN schedule TEXT;
        CREATE TABLE rules (
            id TEXT PRIMARY KEY, stage TEXT, conditions TEXT, actions TEXT,
            conditions_op TEXT DEFAULT 'and', tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE schedules (
            id TEXT PRIMARY KEY, rule TEXT, name TEXT, completed INTEGER DEFAULT 0,
            posts_transaction INTEGER DEFAULT 0, custom_upcoming_length TEXT,
            sort_order REAL, tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE schedules_next_date (
            id TEXT PRIMARY KEY, schedule_id TEXT, local_next_date INTEGER,
            local_next_date_ts INTEGER, base_next_date INTEGER, base_next_date_ts INTEGER,
            tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
        INSERT INTO preferences VALUES ('upcomingScheduledTransactionLength', '7');
        INSERT INTO rules VALUES (
            'rent-rule', 'normal',
            '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-10000},{"op":"is","field":"date","value":"2026-09-30"}]',
            '[{"op":"link-schedule","value":"rent"}]', 'and', 0
        );
        INSERT INTO schedules VALUES ('rent', 'rent-rule', 'Rent', 0, 1, NULL, 1, 0);
        INSERT INTO schedules_next_date VALUES ('rent-next', 'rent', 20260930, 100, 20260930, 100, 0);
        INSERT INTO rules VALUES (
            'rule-rename', NULL,
            '[{"field":"imported_payee","op":"is","value":"Rule Cafe","type":"string"}]',
            '[{"field":"description","op":"set","value":"coffee","type":"id"},{"field":"category","op":"set","value":"groceries","type":"id"}]',
            'and', 0
        );
        INSERT INTO rules VALUES (
            'rule-delete', NULL,
            '[{"field":"imported_payee","op":"is","value":"Delete Me","type":"string"}]',
            '[{"op":"delete-transaction","value":""}]',
            'and', 0
        );
        INSERT INTO rules VALUES (
            'rule-move', NULL,
            '[{"field":"imported_payee","op":"is","value":"Move Me","type":"string"}]',
            '[{"field":"account","op":"set","value":"savings","type":"id"}]',
            'and', 0
        );
        """

    private func makeBundle() async throws -> Bundle {
        try await LocalFirstActualStoreTests().makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.fixtureSQL)
    }

    private func databaseURL(_ bundle: Bundle) throws -> URL {
        try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
    }

    private func prepare(_ bundle: Bundle, _ csv: String, accountID: String = "checking") async throws -> TransactionCSVImportReview {
        try await bundle.store.prepareTransactionCSVImport(
            TransactionCSVImportPreparationRequest(
                budgetID: "group-1",
                accountID: accountID,
                data: Data(csv.utf8),
                options: TransactionCSVImportOptions()
            )
        )
    }

    /// Prepares and applies every row the review would import.
    @discardableResult
    private func importAll(
        _ bundle: Bundle, _ csv: String, accountID: String = "checking"
    ) async throws -> TransactionCSVImportApplyResult {
        let review = try await prepare(bundle, csv, accountID: accountID)
        return try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: accountID,
                sessionGeneration: review.sessionGeneration,
                rows: review.rows.filter { $0.outcome.writes }
            )
        )
    }

    private func scalar(_ bundle: Bundle, _ sql: String, _ arguments: StatementArguments = []) throws -> String? {
        let queue = try DatabaseQueue(path: databaseURL(bundle).path)
        return try queue.readSync { try String.fetchOne($0, sql: sql, arguments: arguments) }
    }

    private func exec(_ bundle: Bundle, _ sql: String) throws {
        let url = try databaseURL(bundle)
        try DatabaseQueue(path: url.path).write { db in try db.execute(sql: sql) }
    }

    private func count(_ bundle: Bundle, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try scalar(bundle, sql, arguments).flatMap(Int.init) ?? -1
    }

    // MARK: - F-2: rules run before matching

    @Test func anImportedRowThatMatchesAPostingScheduleLinksItAndPaysIt() async throws {
        let bundle = try await makeBundle()
        let database = try #require(bundle.store.database)
        try await importAll(bundle, "Date,Payee,Notes,Amount\n\(Self.scheduleDay),Landlord,,-100.00\n")

        #expect(try scalar(bundle, "SELECT schedule FROM transactions WHERE imported_description = 'Landlord'") == "rent")
        let detail = try await database.fetchSchedules(budgetID: "group-1", today: Self.scheduleDay).detail(id: "rent")
        #expect(detail?.status == .paid)

        let advancement = try await database.advanceSchedules(budgetID: "group-1", today: Self.scheduleDay)
        #expect(advancement.receipts.isEmpty)
        #expect(try count(bundle, "SELECT COUNT(*) FROM transactions WHERE amount = -10000 AND acct = 'checking'") == 1)
    }

    @Test func payeeAndCategoryRulesApplyToImportedRows() async throws {
        let bundle = try await makeBundle()
        try await importAll(bundle, "Date,Payee,Notes,Amount\n2026-09-12,Rule Cafe,,-5.00\n")

        #expect(try scalar(bundle, "SELECT description FROM transactions WHERE amount = -500") == "coffee")
        #expect(try scalar(bundle, "SELECT category FROM transactions WHERE amount = -500") == "groceries")
        // The rule renamed the row, so no payee was created for the file's text.
        #expect(try count(bundle, "SELECT COUNT(*) FROM payees WHERE name = 'Rule Cafe'") == 0)
    }

    @Test func aDeleteRuleSkipsTheRow() async throws {
        let bundle = try await makeBundle()
        try await importAll(
            bundle,
            "Date,Payee,Notes,Amount\n2026-09-12,Delete Me,,-3.00\n2026-09-13,Keep Me,,-4.00\n"
        )

        #expect(try count(bundle, "SELECT COUNT(*) FROM transactions WHERE amount = -300") == 0)
        #expect(try count(bundle, "SELECT COUNT(*) FROM transactions WHERE amount = -400") == 1)
    }

    @Test func aRuleThatMovesTheRowToAnotherAccountRefusesTheWholeImport() async throws {
        let bundle = try await makeBundle()
        let before = try count(bundle, "SELECT COUNT(*) FROM transactions")
        await #expect(throws: TransactionCSVImportError.unsupportedAccountMove(line: 1)) {
            _ = try await self.prepare(
                bundle,
                "Date,Payee,Notes,Amount\n2026-09-12,Move Me,,-6.00\n2026-09-13,Keep Me,,-4.00\n"
            )
        }
        #expect(try count(bundle, "SELECT COUNT(*) FROM transactions") == before)
    }

    @Test func anOffBudgetImportKeepsRuleRenamesButNoCategory() async throws {
        let bundle = try await makeBundle()
        try await importAll(bundle, "Date,Payee,Notes,Amount\n2026-09-12,Rule Cafe,,-5.00\n", accountID: "tracking")

        #expect(try scalar(bundle, "SELECT description FROM transactions WHERE acct = 'tracking'") == "coffee")
        #expect(try scalar(bundle, "SELECT category FROM transactions WHERE acct = 'tracking'") == nil)
    }

    // MARK: - D5: upstream CSV defaults

    @Test func newPayeesAreTitleCased() async throws {
        let bundle = try await makeBundle()
        try await importAll(bundle, "Date,Payee,Notes,Amount\n2026-09-12,STARBUCKS COFFEE,,-4.50\n")

        #expect(try scalar(
            bundle,
            "SELECT p.name FROM transactions t JOIN payees p ON p.id = t.description WHERE t.amount = -450"
        ) == "Starbucks Coffee")
    }

    @Test func clearedComesFromTheFileOrDefaultsToClearedOnInsert() async throws {
        let bundle = try await makeBundle()
        try await importAll(bundle, """
            Date,Payee,Notes,Amount,Cleared
            2026-09-12,No Column Value,,-4.50,
            2026-09-13,Said Not Cleared,,-4.60,Not Cleared

            """)

        #expect(try scalar(bundle, "SELECT cleared FROM transactions WHERE amount = -450") == "1")
        #expect(try scalar(bundle, "SELECT cleared FROM transactions WHERE amount = -460") == "0")
    }

    @Test func aMatchedRowIsNotClearedByAFileThatDoesNotSayCleared() async throws {
        let bundle = try await makeBundle()
        try await importAll(bundle, "Date,Payee,Notes,Amount\n2026-07-03,Coffee Shop,,-123.45\n")

        #expect(try scalar(bundle, "SELECT cleared FROM transactions WHERE id = 'txn'") == nil)
    }

    // MARK: - F-9: one imported_id rule

    @Test func aBankSyncRowLandingAfterReviewBlocksTheImport() async throws {
        let bundle = try await makeBundle()
        let review = try await prepare(
            bundle, "Date,Payee,Amount,imported_id\n2026-09-12,Landlord,-9.99,bank-77\n"
        )
        try exec(bundle, """
            INSERT INTO transactions (id, acct, date, amount, imported_id, tombstone)
            VALUES ('remote-row', 'checking', 20260912, -999, 'bank-77', 0)
            """)
        let before = try await bundle.store.database?.pendingLocalSyncMessageCount()

        await #expect(throws: TransactionCSVImportError.reviewChanged) {
            _ = try await bundle.store.applyTransactionCSVImport(
                TransactionCSVImportApplyRequest(
                    budgetID: "group-1",
                    accountID: "checking",
                    sessionGeneration: review.sessionGeneration,
                    rows: review.rows
                )
            )
        }

        #expect(try count(bundle, "SELECT COUNT(*) FROM transactions WHERE imported_id = 'bank-77'") == 1)
        #expect(try await bundle.store.database?.pendingLocalSyncMessageCount() == before)
    }

    // MARK: - Stored values read the way upstream reads them

    /// A stored NULL `cleared` is `false` (`match.cleared === 1`, sync.ts ~700),
    /// so a file that says Cleared clears the matched row. The deleted CSV-only
    /// matcher treated NULL as "never changes".
    @Test func aStoredNullClearedIsNotCleared() async throws {
        let bundle = try await makeBundle()
        #expect(try scalar(bundle, "SELECT cleared FROM transactions WHERE id = 'txn'") == nil)
        try await importAll(bundle, "Date,Payee,Notes,Amount,Cleared\n2026-07-03,Coffee Shop,,-123.45,Cleared\n")

        #expect(try scalar(bundle, "SELECT cleared FROM transactions WHERE id = 'txn'") == "1")
    }

    /// An empty stored notes value is falsy, like null, in upstream's change
    /// check (`existing.notes || trans.notes || null`), so re-importing the same
    /// row changes nothing.
    @Test func anEmptyStoredNotesValueIsNoChange() async throws {
        let bundle = try await makeBundle()
        try exec(bundle, "UPDATE transactions SET notes = '', description = 'coffee', imported_description = 'Coffee Shop' WHERE id = 'txn'")
        let review = try await prepare(bundle, "Date,Payee,Notes,Amount\n2026-07-03,Coffee Shop,,-123.45\n")

        #expect(review.rows.map(\.outcome.kind) == [.unchanged])
    }

    /// Upstream writes `imported_id: trans.imported_id || null` and
    /// `imported_payee: trans.imported_payee || null` on every matched update
    /// (sync.ts 685/688, no `isBankSyncAccount` gate), so a CSV row without an
    /// id clears the stored one and the stored import text becomes the file's.
    @Test func aMatchedCSVRowWithoutAnImportedIDClearsTheStoredIdentity() async throws {
        let bundle = try await makeBundle()
        try exec(bundle, "UPDATE transactions SET imported_id = 'bank-1', imported_description = 'Old Text' WHERE id = 'txn'")

        try await importAll(bundle, "Date,Payee,Notes,Amount\n2026-07-03,Coffee Shop,,-123.45\n")

        #expect(try scalar(bundle, "SELECT imported_id FROM transactions WHERE id = 'txn'") == nil)
        #expect(try scalar(bundle, "SELECT imported_description FROM transactions WHERE id = 'txn'") == "Coffee Shop")
    }
}
