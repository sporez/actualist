import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
@Suite("Tracking budget write safety")
struct TrackingBudgetWriteSafetyTests {
    private let fixture = TrackingBudgetDatabaseContractTests()

    @Test("mode identity changes across conversion round trip and reopen")
    func conversionRoundTripChangesIdentity() async throws {
        let url = try fixture.makeTrackingContractFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "write-safety")
        let tracking = try await database.fetchBudgetModeIdentity()

        _ = try await database.applyRemoteSyncMessages([
            conversionMessage(timestamp: "2026-09-01T00:00:00.000Z-0000-0000000000000001", value: "S:envelope")
        ])

        let envelope = try BudgetDatabase(databaseURL: url, localNodeID: "write-safety")
        #expect(try await envelope.fetchBudgetModeIdentity().table == .envelope)
        _ = try await envelope.applyRemoteSyncMessages([
            conversionMessage(timestamp: "2026-09-02T00:00:00.000Z-0000-0000000000000001", value: "S:tracking")
        ])

        let reopened = try BudgetDatabase(databaseURL: url, localNodeID: "write-safety")
        let roundTripped = try await reopened.fetchBudgetModeIdentity()
        #expect(roundTripped.table == .tracking)
        #expect(roundTripped.storageID == tracking.storageID)
        #expect(roundTripped != tracking)
    }

    @Test("stale assignment fails atomically after conversion")
    func staleAssignmentDoesNotWriteOrLog() async throws {
        let url = try fixture.makeTrackingContractFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "write-safety")
        let before = try await database.fetchBudgetModeIdentity()
        let assignment = assignmentMessage(amount: -900)

        _ = try await database.applyRemoteSyncMessages([
            conversionMessage(timestamp: "2026-09-03T00:00:00.000Z-0000-0000000000000001", value: "S:envelope")
        ])

        await #expect(throws: BudgetModeWriteError.budgetChanged) {
            try await database.commitUserAction(
                [assignment],
                descriptor: .assign(month: "2026-07", categoryID: "groceries", budgeted: -900),
                source: .ui,
                expectedMode: before
            )
        }

        let state = try await sqliteState(at: url)
        #expect(state.envelopeAmount == 500)
        #expect(state.trackingAmount == 500)
        #expect(state.outboxCount == 0)
        #expect(state.actionLogCount == 0)
    }

    @Test("stale no-op template commit still rejects the old review")
    func staleEmptyCommitIsRejected() async throws {
        let url = try fixture.makeTrackingContractFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "write-safety")
        let before = try await database.fetchBudgetModeIdentity()
        _ = try await database.applyRemoteSyncMessages([
            conversionMessage(timestamp: "2026-09-03T00:00:00.000Z-0000-0000000000000001", value: "S:envelope")
        ])
        await #expect(throws: BudgetModeWriteError.budgetChanged) {
            try await database.commitLocalSyncMessagesAndEnqueue([], expectedMode: before)
        }
        #expect(try await sqliteState(at: url).outboxCount == 0)
    }

    @Test("pending local write survives a later conversion")
    func pendingWriteRetainsOriginalDataset() async throws {
        let url = try fixture.makeTrackingContractFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "write-safety")
        let identity = try await database.fetchBudgetModeIdentity()
        let assignment = assignmentMessage(amount: 800)

        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            [assignment],
            expectedMode: identity
        )
        let pendingBeforeConversion = try await database.pendingLocalSyncMessages()
        #expect(pendingBeforeConversion.count == 1)
        _ = try await database.applyRemoteSyncMessages([
            conversionMessage(timestamp: "2026-09-04T00:00:00.000Z-0000-0000000000000001", value: "S:envelope")
        ])

        let reopened = try BudgetDatabase(databaseURL: url, localNodeID: "write-safety")
        let pending = try await reopened.pendingLocalSyncMessages()
        #expect(pending.map(\.message) == pendingBeforeConversion.map(\.message))
        #expect(try await sqliteState(at: url).trackingAmount == 800)
        #expect(try await sqliteState(at: url).envelopeAmount == 500)
    }

    @Test("tracking move and income carryover are refused without side effects")
    func unsupportedTrackingActions() async throws {
        let url = try fixture.makeTrackingContractFixture()
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "write-safety")
        let identity = try await database.fetchBudgetModeIdentity()
        let move = ActualSyncDecodedMessage(
            timestamp: "2026-09-05T00:00:00.000Z-0000-0000000000000001",
            dataset: "reflect_budgets", row: "202607-groceries", column: "amount", serializedValue: "N:900"
        )
        let carryover = ActualSyncDecodedMessage(
            timestamp: "2026-09-05T00:00:00.000Z-0000-0000000000000002",
            dataset: "reflect_budgets", row: "202607-groceries", column: "carryover", serializedValue: "N:1"
        )
        let leg = BudgetMoveLeg(fromCategoryID: "groceries", toCategoryID: "dining", amount: 100)

        await #expect(throws: BudgetModeWriteError.unsupportedAction) {
            try await database.commitUserAction(
                [move], descriptor: .move(month: "2026-07", legs: [leg]), source: .ui, expectedMode: identity
            )
        }

        try await setIncomeCategory(at: url)
        await #expect(throws: BudgetModeWriteError.unsupportedAction) {
            try await database.commitLocalSyncMessagesAndEnqueue(
                [carryover], expectedMode: identity
            )
        }

        let state = try await sqliteState(at: url)
        #expect(state.trackingAmount == 500)
        #expect(state.outboxCount == 0)
        #expect(state.actionLogCount == 0)
    }

    @Test("tracking write generators refuse move and income carryover in both directions")
    func generatorsRefuseUnsupportedTrackingActions() async throws {
        let url = try fixture.makeTrackingContractFixture()
        try await setIncomeCategory(at: url)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "write-safety")
        var builder = LocalFirstSyncMessageBuilder()
        let leg = BudgetMoveLeg(fromCategoryID: "groceries", toCategoryID: "dining", amount: 100)

        await #expect(throws: BudgetModeWriteError.unsupportedAction) {
            try await database.moveMoneyMessages(commands: [BudgetMoveMoneyCommand(
                fromCategoryID: leg.fromCategoryID, toCategoryID: leg.toCategoryID, amount: leg.amount
            )], month: "2026-07", builder: &builder)
        }
        for carryover in [true, false] {
            await #expect(throws: BudgetModeWriteError.unsupportedAction) {
                try await database.categoryCarryoverMessages(
                    categoryID: "groceries", carryover: carryover,
                    startMonth: "2026-07", throughMonth: "2026-08", builder: &builder
                )
            }
        }
    }

    @Test("tracking allows a past income assignment with a negative amount")
    func incomeAssignmentIsAllowed() async throws {
        let url = try fixture.makeTrackingContractFixture()
        try await setIncomeCategory(at: url)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "write-safety")
        let identity = try await database.fetchBudgetModeIdentity()
        let assignment = assignmentMessage(amount: -900)

        #expect(try await database.commitUserAction(
            [assignment],
            descriptor: .assign(month: "2026-07", categoryID: "groceries", budgeted: -900),
            source: .ui,
            expectedMode: identity
        ) == 1)
        #expect(try await sqliteState(at: url).trackingAmount == -900)
    }

    private func conversionMessage(timestamp: String, value: String) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: timestamp,
            dataset: "preferences", row: "budgetType", column: "value", serializedValue: value
        )
    }

    private func assignmentMessage(amount: Int) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: "2026-09-06T00:00:00.000Z-0000-0000000000000001",
            dataset: "reflect_budgets", row: "202607-groceries", column: "amount",
            serializedValue: "N:\(amount)"
        )
    }

    private func setIncomeCategory(at url: URL) async throws {
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE categories SET is_income = 1 WHERE id = 'groceries'")
        }
    }

    private struct SQLiteState {
        let trackingAmount: Int?
        let envelopeAmount: Int?
        let outboxCount: Int
        let actionLogCount: Int
    }

    private func sqliteState(at url: URL) async throws -> SQLiteState {
        let queue = try DatabaseQueue(path: url.path)
        return try await queue.read { db in
            let outboxCount = try countRows(in: "actualist_outbox", db: db)
            let actionLogCount = try countRows(in: "actualist_action_log", db: db)
            return SQLiteState(
                trackingAmount: try Int.fetchOne(db, sql: "SELECT amount FROM reflect_budgets WHERE id = '202607-groceries'"),
                envelopeAmount: try Int.fetchOne(db, sql: "SELECT amount FROM zero_budgets WHERE month = 202607 AND category = 'groceries'"),
                outboxCount: outboxCount,
                actionLogCount: actionLogCount
            )
        }
    }

    nonisolated private func countRows(in table: String, db: Database) throws -> Int {
        let exists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [table]
        ) ?? false
        guard exists else { return 0 }
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }
}
