import Foundation
import GRDB
import Testing
@testable import Actualist

/// Phase 5.9: "Enable rollover for all" reads the budget rows once. The
/// per-category, per-month `budgetRowID` lookup is the oracle for which row id
/// each message targets. The written message set (month, category and
/// carryover for every month) is unchanged; see the commit body for upstream.
@MainActor
struct CategoryCarryoverRowReadTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func database(tracking: Bool) throws -> BudgetDatabase {
        // 202301 exists only as a custom-id row, so a synthetic id would be wrong.
        let customRow = tracking
            ? "INSERT INTO reflect_budgets VALUES ('custom-row-id', 202301, 'dining', 1, 0);"
            : ""
        return try BudgetDatabase(databaseURL: fixtures.makeSQLiteFixture(
            extraSQL: BudgetHistoryFixture.sql(seed: 7, tracking: tracking) + "\n" + customRow
        ))
    }

    @Test(arguments: [false, true])
    func messagesMatchPerPairRowLookups(tracking: Bool) async throws {
        let database = try database(tracking: tracking)
        let startMonth = tracking ? "2023-01" : "2024-09"
        // Data runs through 2026-08; the earlier horizon extends to it.
        for (carryover, through) in [(true, "2026-12"), (false, "2026-02")] {
            var actualBuilder = LocalFirstSyncMessageBuilder()
            let actual = try await database.allExpenseCategoryCarryoverMessages(
                carryover: carryover,
                startMonth: startMonth,
                throughMonth: through,
                builder: &actualBuilder
            )
            var expectedBuilder = LocalFirstSyncMessageBuilder()
            let expected = try await database.perPairCarryoverMessagesForTesting(
                carryover: carryover,
                startMonth: startMonth,
                throughMonth: through,
                builder: &expectedBuilder
            )
            func key(_ message: ActualSyncDecodedMessage) -> String {
                "\(message.dataset)|\(message.row)|\(message.column)|\(message.serializedValue)"
            }
            #expect(actual.map(key) == expected.map(key), "tracking \(tracking) through \(through)")
            #expect(actual.count > 200)
        }
        if tracking {
            var builder = LocalFirstSyncMessageBuilder()
            let messages = try await database.allExpenseCategoryCarryoverMessages(
                carryover: true, startMonth: startMonth, throughMonth: "2026-12", builder: &builder
            )
            #expect(messages.contains { $0.row == "custom-row-id" && $0.column == "carryover" })
            #expect(!messages.contains { $0.row == "202301-dining" })
        }
    }

    @Test func rowLookupsDoNotScaleWithCategoriesTimesMonths() async throws {
        let database = try database(tracking: false)
        let log = StatementLog()
        try await database.startStatementTraceForTesting(log)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.allExpenseCategoryCarryoverMessages(
            carryover: true, startMonth: "2024-09", throughMonth: "2026-12", builder: &builder
        )
        try await database.stopStatementTraceForTesting()
        let rowReads = log.count(containing: "FROM \"zero_budgets\"")
        #expect(messages.count == 5 * 28 * 3)
        #expect(rowReads <= 3, "zero_budgets reads \(rowReads)")
    }
}

extension BudgetDatabase {
    /// The pre-Phase-5 loop: one `budgetRowID` lookup per category and month.
    func perPairCarryoverMessagesForTesting(
        carryover: Bool,
        startMonth: String,
        throughMonth: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let startValue = try Self.actualMonthValue(startMonth)
        let throughValue = try Self.actualMonthValue(throughMonth)
        return try queue.read { db in
            let table = try budgetTable(db: db)
            let columns = try requiredColumns(
                table: table.rawValue,
                required: ["month", "category", "carryover"],
                db: db
            )
            let categoryIDs = try templateCategoryIDsInBudgetOrder(
                db: db, includeIncome: false, includeHidden: true
            )
            let latestStored = try categoryBudgetsByMonth(db: db).keys
                .compactMap { canonicalMonthID($0).map(monthInt) }.max() ?? 0
            let effectiveThrough = max(throughValue, latestStored)
            var messages: [ActualSyncDecodedMessage] = []
            for categoryID in categoryIDs {
                var monthValue = startValue
                while monthValue <= effectiveThrough {
                    let rowID = try budgetRowID(
                        table: table, monthValue: monthValue, categoryID: categoryID,
                        columns: columns, db: db
                    ) ?? Self.budgetRowID(monthValue: monthValue, categoryID: categoryID)
                    messages.append(try builder.makeMessage(
                        dataset: table.rawValue, row: rowID, column: "month", value: .int(Int64(monthValue))
                    ))
                    messages.append(try builder.makeMessage(
                        dataset: table.rawValue, row: rowID, column: "category", value: .string(categoryID)
                    ))
                    messages.append(try builder.makeMessage(
                        dataset: table.rawValue, row: rowID, column: "carryover", value: .bool(carryover)
                    ))
                    monthValue = nextMonth(after: monthValue)
                }
            }
            return messages
        }
    }
}
