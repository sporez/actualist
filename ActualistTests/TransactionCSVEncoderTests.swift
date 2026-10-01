import Foundation
import Testing
@testable import Actualist

struct TransactionCSVEncoderTests {
    @Test func writesPinnedActualHeaderRowsLFAndFinalNewline() throws {
        let export = TransactionCSVEncoder().encode(
            [row(id: "one", amount: -12345, isCleared: true)],
            generatedAt: date(2026, 9, 28)
        )
        let csv = try #require(String(data: export.data, encoding: .utf8))
        #expect(csv == "Account,Date,Payee,Notes,Category_Group,Category,Amount,Split_Amount,Cleared\nChecking,2026-09-01,Shop,,Food,Groceries,-123.45,0,Cleared\n")
        #expect(export.suggestedFilename == "Transactions-20260928-000000.csv")
        #expect(export.exportedFamilyCount == 1)
        #expect(export.exportedRowCount == 1)
    }

    @Test func quotesCSVControlsAndPrefixesFormulaLikeTextButNotNegativeNumbers() throws {
        let export = TransactionCSVEncoder().encode([
            row(id: "one", payee: "=shop,\"x\"", notes: "line 1\r\nline 2", amount: -2500)
        ])
        let csv = try #require(String(data: export.data, encoding: .utf8))
        #expect(csv.contains("\"'=shop,\"\"x\"\"\",\"line 1\r\nline 2\""))
        #expect(csv.contains(",-25,0,Not cleared\n"))

        for trigger in ["=", "+", "-", "@", "\t", "\r", "\r\n"] {
            for field in 0..<6 {
                var values = Array(repeating: "ordinary", count: 6)
                values[field] = "\(trigger)input"
                let value = TransactionCSVEncoder().encode([row(
                    id: "trigger-\(field)", account: values[0], payee: values[2],
                    notes: values[3], categoryGroup: values[4], category: values[5], date: values[1]
                )])
                let text = String(decoding: value.data, as: UTF8.self)
                #expect(text.contains("'\(trigger)input"))
            }
        }
    }

    @Test func quotesStandaloneCarriageReturnAndLineFeed() {
        let export = TransactionCSVEncoder().encode([
            row(id: "carriage-return", notes: "before\rafter"),
            row(id: "line-feed", notes: "before\nafter"),
        ])
        let csv = String(decoding: export.data, as: UTF8.self)
        #expect(csv.contains("\"before\rafter\""))
        #expect(csv.contains("\"before\nafter\""))
    }

    @Test func writesActualSplitMarkersAndReconciledStatus() throws {
        let export = TransactionCSVEncoder().encode([
            row(id: "parent", family: "parent", notes: "envelope", amount: -5000, isParent: true),
            row(id: "child-a", family: "parent", amount: -3000, isChild: true),
            row(id: "child-b", family: "parent", amount: -2000, isReconciled: true, isChild: true),
        ])
        let csv = String(decoding: export.data, as: UTF8.self)
        #expect(csv.contains("(SPLIT INTO 2) envelope"))
        #expect(csv.contains("(SPLIT 1 OF 2) "))
        #expect(csv.contains("(SPLIT 2 OF 2) ,Food,Groceries,-20,0,Reconciled"))
        #expect(export.exportedFamilyCount == 1)
        #expect(export.exportedRowCount == 3)
    }

    @Test func triggerLeadingDateIsSanitizedLikeEveryOtherStringCell() {
        let export = TransactionCSVEncoder().encode([row(id: "date", date: "=2026-09-01")])
        #expect(String(decoding: export.data, as: UTF8.self).contains(",'=2026-09-01,"))
    }

    @Test func preservesExactExtremeAmountAndEmptyNamesInLocaleNeutralCSV() throws {
        let export = TransactionCSVEncoder().encode([
            row(id: "empty", account: "", payee: "", categoryGroup: "", category: "", amount: Int.min),
        ])
        let csv = try #require(String(data: export.data, encoding: .utf8))
        #expect(csv.contains(",2026-09-01,,,,,-92233720368547758.08,0,Not cleared\n"))
        #expect(!csv.contains("-92,233,720"))
    }

    @Test func retainsTheDatabaseProvidedRowOrder() throws {
        let export = TransactionCSVEncoder().encode([
            row(id: "first", payee: "First"),
            row(id: "second", payee: "Second"),
        ])
        let csv = String(decoding: export.data, as: UTF8.self)
        let first = try #require(csv.range(of: ",First,"))
        let second = try #require(csv.range(of: ",Second,"))
        #expect(first.lowerBound < second.lowerBound)
    }

    private func row(
        id: String,
        family: String? = nil,
        account: String = "Checking",
        payee: String = "Shop",
        notes: String? = nil,
        categoryGroup: String = "Food",
        category: String = "Groceries",
        date: String = "2026-09-01",
        amount: Int = -1000,
        isCleared: Bool = false,
        isReconciled: Bool = false,
        isParent: Bool = false,
        isChild: Bool = false
    ) -> TransactionCSVExportRow {
        TransactionCSVExportRow(
            id: id,
            familyID: family ?? id,
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

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

@MainActor
struct TransactionCSVExportDatabaseTests {
    @Test func databaseCSVExportReadsWholeLocalSplitFamilyWithNames() async throws {
        let support = LocalFirstActualStoreTests()
        let databaseURL = try support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            ALTER TABLE transactions ADD COLUMN cleared INTEGER;
            ALTER TABLE transactions ADD COLUMN isChild INTEGER;
            ALTER TABLE transactions ADD COLUMN sort_order REAL;
            INSERT INTO category_groups VALUES ('other', 'Food', 0, 0, 0, 2);
            UPDATE categories SET cat_group = 'other' WHERE id = 'groceries';
            UPDATE transactions SET is_parent = 1, amount = -5000, description = 'Market', notes = 'parent note' WHERE id = 'txn';
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, description, notes, cleared, isChild, sort_order)
                VALUES ('child', 'checking', 20260703, -5000, 'groceries', 0, 'txn', 0, 'Market', NULL, 1, 1, 2);
            """)
        let database = try BudgetDatabase(databaseURL: databaseURL)

        let rows = try await database.fetchTransactionCSVExportRows(accountID: "checking", query: .all)

        #expect(rows.map(\.id) == ["txn", "child"])
        #expect(rows.map(\.accountName) == ["Checking", "Checking"])
        // Split parents carry the total; categories belong to their children.
        #expect(rows.map(\.categoryGroupName) == ["", "Food"])
        #expect(rows.map(\.categoryName) == ["", "Groceries"])
        #expect(rows.map(\.isParent) == [true, false])
        #expect(rows.map(\.isChild) == [false, true])
        #expect(rows.last?.isCleared == true)
    }

    @Test func storeCSVExportUsesOpenedLocalBudgetWithoutSyncing() async throws {
        let transport = RecordingSyncTransport()
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle(syncTransportFactory: { _ in transport })
        bundle.store.openedServerURLString = nil
        let database = try #require(bundle.store.database)
        let pendingBeforeWrite = try await database.pendingLocalSyncMessages()
        #expect(pendingBeforeWrite.isEmpty)

        _ = try await bundle.store.createTransactionAndRefresh(
            TransactionDraft(
                accountID: "checking",
                date: try support.makeDate(year: 2026, month: 7, day: 16),
                amountMinorUnits: -450,
                payeeID: "coffee",
                payeeName: "Coffee Shop",
                categoryID: "groceries",
                notes: "Local CRDT write",
                cleared: false,
                isTransfer: false
            ),
            budgetID: "group-1"
        ) {}
        let pendingAfterWrite = try await database.pendingLocalSyncMessages()
        #expect(!pendingAfterWrite.isEmpty)

        let export = try await bundle.store.exportTransactionsCSV(
            TransactionCSVExportRequest(budgetID: "group-1", accountID: "checking", query: .all)
        )
        let pendingAfterExport = try await database.pendingLocalSyncMessages()
        let csv = String(decoding: export.data, as: UTF8.self)

        #expect(export.exportedFamilyCount == 2)
        #expect(export.exportedRowCount == 2)
        #expect(csv.components(separatedBy: "Coffee Shop").count - 1 == 1)
        #expect(csv.contains("Local CRDT write"))
        #expect(pendingAfterExport == pendingAfterWrite)
        #expect(bundle.store.pendingLocalMessageFlushTask == nil)
        #expect(await transport.messageCounts().isEmpty)
    }
}
