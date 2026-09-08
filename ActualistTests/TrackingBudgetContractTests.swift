import Foundation
import GRDB
import Testing
@testable import Actualist

struct TrackingBudgetOracle: Decodable {
    struct Case: Decodable {
        let isIncome: Bool
        let budgeted: Int
        let activity: Int
        let previousBalance: Int
        let previousCarryover: Bool
        let balance: Int
    }
    let commit: String
    let cases: [Case]
    let groupDependencies: [String]
    let expenseDependencies: [String]
    let projectedSavings: Int
    let actualSavings: Int

    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf:
            root.appending(path: "Fixtures/ActualCore26_9_0/Tracking/contract.json")))
    }
}

struct TrackingBudgetContractTests {
    @Test func pinnedOracleCoversSignsAndHiddenDependencies() throws {
        let oracle = try TrackingBudgetOracle.load()
        #expect(oracle.commit == "59fe126f637d858c061e1eeedbef5436c8f2225a")
        #expect(oracle.cases.count == 36)
        #expect(oracle.groupDependencies == ["budget-visible"])
        #expect(oracle.expenseDependencies == ["group-budget-expense"])
        #expect(oracle.projectedSavings == 1000)
        #expect(oracle.actualSavings == 900)
    }

    @Test func legacyAssignmentDecodesWithoutInventingIdentity() throws {
        let json = #"{"type":"assign","payload":{"payload":{"month":"2026-07","categoryID":"groceries","before":500,"after":700}}}"#
        let inverse = try JSONDecoder().decode(BudgetActionInverse.self, from: Data(json.utf8))
        #expect(inverse == .assign(AssignBudgetAction(
            month: "2026-07", categoryID: "groceries", before: 500, after: 700)))
    }
}

@MainActor
struct TrackingBudgetDatabaseContractTests {
    func makeTrackingContractFixture() throws -> URL {
        try LocalFirstActualStoreTests().makeSQLiteFixture(extraSQL: """
            DELETE FROM transactions;
            DELETE FROM zero_budgets;
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('budgetType', 'tracking');
            CREATE TABLE reflect_budgets (
                id TEXT PRIMARY KEY, month INTEGER, category TEXT, amount INTEGER, carryover INTEGER
            );
            INSERT INTO reflect_budgets VALUES ('202607-groceries', 202607, 'groceries', 500, 0);
            INSERT INTO reflect_budgets VALUES ('202912-groceries', 202912, 'groceries', 700, 0);
            INSERT INTO zero_budgets VALUES (202607, 'groceries', 500, 0);
            """)
    }

    @Test func trackingSQLiteRecurrenceMatchesPinnedOracle() async throws {
        for testCase in try TrackingBudgetOracle.load().cases {
            let url = try makeTrackingContractFixture()
            let queue = try DatabaseQueue(path: url.path)
            try await queue.write { db in
                try db.execute(sql: "UPDATE categories SET is_income = ? WHERE id = 'groceries'",
                    arguments: [testCase.isIncome])
                try db.execute(sql: "UPDATE reflect_budgets SET amount = ?, carryover = ? WHERE month = 202607",
                    arguments: [testCase.previousBalance, testCase.previousCarryover])
                try db.execute(sql: "INSERT INTO reflect_budgets VALUES ('202608-groceries', 202608, 'groceries', ?, 0)",
                    arguments: [testCase.budgeted])
                try db.execute(sql: "INSERT INTO transactions (id, acct, date, amount, category, tombstone) VALUES ('activity', 'checking', 20260802, ?, 'groceries', 0)",
                    arguments: [testCase.activity])
            }
            let database = try BudgetDatabase(databaseURL: url)
            let month = try await database.fetchBudgetMonth(month: "2026-08")
            let category = try #require(month.categoryGroups.first?.categories.first)
            #expect(category.balance == testCase.balance)
        }
    }

    @Test func trackingReadContractExposesEnvelopeCarryAndMissingFutureMonth() async throws {
        let url = try makeTrackingContractFixture()
        let database = try BudgetDatabase(databaseURL: url)
        let august = try await database.fetchBudgetMonth(month: "2026-08")
        let category = try #require(august.categoryGroups.first?.categories.first)
        #expect(category.balance == 0)
        let months = try await database.fetchAvailableMonths()
        #expect(months.contains("2029-12"))
    }

    @Test func trackingConversionRoundTripRetainsMetadataRevisionAcrossReopen() async throws {
        let url = try makeTrackingContractFixture()
        let database = try BudgetDatabase(databaseURL: url)
        #expect(try await database.isTrackingBudget())
        let changes = [
            ActualSyncDecodedMessage(timestamp: "2026-09-01T00:00:00.000Z-0000-0000000000000001",
                dataset: "preferences", row: "budgetType", column: "value", serializedValue: "S:envelope"),
            ActualSyncDecodedMessage(timestamp: "2026-09-02T00:00:00.000Z-0000-0000000000000001",
                dataset: "preferences", row: "budgetType", column: "value", serializedValue: "S:tracking")
        ]
        #expect(try await database.applyRemoteSyncMessages(changes) == 2)
        let reopened = try BudgetDatabase(databaseURL: url)
        #expect(try await reopened.isTrackingBudget())
        let stored = try LocalFirstActualStoreTests().storedCRDTMessages(at: url)
        #expect(stored.filter { $0.dataset == "preferences" }.count == 2)
        #expect(try await reopened.applyRemoteSyncMessages(changes.reversed()) == 0)
    }

    @Test func trackingPendingWriteKeepsDatasetAcrossConversionAndDuplicateDelivery() async throws {
        let firstURL = try makeTrackingContractFixture()
        let secondURL = try makeTrackingContractFixture()
        let first = try BudgetDatabase(databaseURL: firstURL)
        let second = try BudgetDatabase(databaseURL: secondURL)
        let assignment = ActualSyncDecodedMessage(
            timestamp: "2026-09-01T00:00:00.000Z-0000-0000000000000001",
            dataset: "reflect_budgets", row: "202607-groceries", column: "amount", serializedValue: "N:800")
        let conversion = ActualSyncDecodedMessage(
            timestamp: "2026-09-02T00:00:00.000Z-0000-0000000000000002",
            dataset: "preferences", row: "budgetType", column: "value", serializedValue: "S:envelope")
        _ = try await first.applyLocalSyncMessagesAndEnqueue([assignment],
            baseTimestamp: "1970-01-01T00:00:00.000Z-0000-0000000000000000")
        _ = try await first.applyRemoteSyncMessages([conversion])
        _ = try await second.applyRemoteSyncMessages([conversion, assignment])
        let reopened = try BudgetDatabase(databaseURL: firstURL)
        let pending = try await reopened.pendingLocalSyncMessages()
        #expect(pending.map(\.message) == [assignment])
        #expect(try await second.applyRemoteSyncMessages(pending.map(\.message)) == 0)
        for url in [firstURL, secondURL] {
            let queue = try DatabaseQueue(path: url.path)
            let amounts = try await queue.read { db in
                (try Int.fetchOne(db, sql: "SELECT amount FROM reflect_budgets WHERE id = '202607-groceries'"),
                 try Int.fetchOne(db, sql: "SELECT amount FROM zero_budgets WHERE month = 202607"))
            }
            #expect(amounts.0 == 800)
            #expect(amounts.1 == 500)
        }
    }

    @Test func trackingExplicitRolloverHorizonIncludesFarFutureRows() async throws {
        let url = try makeTrackingContractFixture()
        let database = try BudgetDatabase(databaseURL: url)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.categoryCarryoverMessages(categoryID: "groceries",
            carryover: true, startMonth: "2026-07", throughMonth: "2029-12", builder: &builder)
        #expect(messages.allSatisfy { $0.dataset == "reflect_budgets" })
        #expect(messages.contains { $0.row == "202912-groceries" && $0.column == "carryover" })
        _ = try await database.applyLocalSyncMessages(messages)
        let queue = try DatabaseQueue(path: url.path)
        #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT carryover FROM reflect_budgets WHERE id = '202912-groceries'") } == 1)
    }
}
