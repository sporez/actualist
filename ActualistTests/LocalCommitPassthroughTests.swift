import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct LocalCommitPassthroughTests {
    private let fixtures = LocalFirstActualStoreTests()

    private struct NewPlanError: LocalCommitPassthroughError, Equatable {
        let detail: String
    }

    private func makeDatabase() throws -> BudgetDatabase {
        try BudgetDatabase(databaseURL: try fixtures.makeSQLiteFixture(), localNodeID: "node1")
    }

    private func commit(
        _ database: BudgetDatabase,
        throwing error: any Error
    ) async throws {
        _ = try await database.commitLocalPlan { @Sendable _ -> BudgetDatabase.LocalCommitPlan<Void> in
            throw error
        }
    }

    @Test func aNewTypedErrorReachesTheCallerUnchanged() async throws {
        let database = try makeDatabase()

        await #expect(throws: NewPlanError(detail: "typed")) {
            try await commit(database, throwing: NewPlanError(detail: "typed"))
        }
    }

    @Test func existingTypedErrorsStillPassThrough() async throws {
        let database = try makeDatabase()

        await #expect(throws: SchedulePostingRefusal.draftMismatch) {
            try await commit(database, throwing: SchedulePostingRefusal.draftMismatch)
        }
        await #expect(throws: LocalFirstError.importedTransactionConflict) {
            try await commit(database, throwing: LocalFirstError.importedTransactionConflict)
        }
        await #expect(throws: BudgetModeWriteError.budgetChanged) {
            try await commit(database, throwing: BudgetModeWriteError.budgetChanged)
        }
    }

    @Test func untypedFailuresAreStillWrappedAsARollback() async throws {
        let database = try makeDatabase()

        await #expect(
            throws: LocalFirstError.invalidLocalWrite("the database transaction was rolled back")
        ) {
            try await commit(database, throwing: DatabaseError(message: "boom"))
        }
    }

    @Test func cancellationFromAPlanReachesTheCallerAsCancellation() async throws {
        let database = try makeDatabase()

        await #expect(throws: CancellationError.self) {
            try await commit(database, throwing: CancellationError())
        }
    }

    // MARK: Session write fence (main-to-dev 2.1)

    private func invalidatedDatabase() throws -> BudgetDatabase {
        let database = try makeDatabase()
        database.invalidateSessionWrites()
        return database
    }

    @Test func invalidatedSessionRejectsLocalSyncMessageCommit() async throws {
        let database = try invalidatedDatabase()
        let draft = ActualSyncDecodedMessage(
            timestamp: "1970-01-01T00:00:00.000Z-0000-0000000000000000",
            dataset: "accounts",
            row: "checking",
            column: "name",
            serializedValue: "S:Renamed"
        )

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            _ = try await database.commitLocalSyncMessagesAndEnqueue([draft])
        }
    }

    @Test func invalidatedSessionRejectsUserActionPlanCommit() async throws {
        let database = try invalidatedDatabase()

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            _ = try await database.commitUserActionPlan(source: .ui) { _, _ in
                UserActionPlan(drafts: [], descriptor: nil, outcome: ())
            }
        }
    }

    @Test func invalidatedSessionRejectsDirectLocalPlanCommit() async throws {
        let database = try invalidatedDatabase()

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            try await commit(database, throwing: CancellationError())
        }
    }

    @Test func invalidatedSessionRejectsAssignUndo() async throws {
        let database = try invalidatedDatabase()
        let assign = AssignBudgetAction(month: "2026-07", categoryID: "groceries", before: 0, after: 100)
        let record = BudgetActionRecord(
            id: "action-1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .assign,
            status: .applied,
            month: "2026-07",
            summary: .assign(assign),
            inverse: .assign(assign),
            affectedCategoryIDs: ["groceries"],
            forwardTimestampStart: nil,
            forwardTimestampEnd: nil,
            source: .ui
        )

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            _ = try await database.commitActionUndo(record: record)
        }
    }
}
