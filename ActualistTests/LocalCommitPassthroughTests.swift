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
}
