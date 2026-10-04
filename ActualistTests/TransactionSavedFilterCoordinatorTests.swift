import Foundation
import GRDB
import Testing
@testable import Actualist

@Suite("Saved transaction filters")
@MainActor
struct TransactionSavedFilterCoordinatorTests {
    @Test func cancelledLoadCannotPublishLateFilters() async {
        let gate = SavedFilterTestGate()
        let filter = SavedTransactionFilter.project(
            id: "late", name: "Late", rawConditionsJSON: #"[{"field":"account","op":"is","value":"a"}]"#,
            conditionsOperation: "and", tombstone: false
        )
        let repository = SavedFilterRepositoryFake(
            result: .available([filter]), gate: gate
        )
        let coordinator = SavedTransactionFiltersCoordinator(
            mutationContext: SavedTransactionFilterMutationContext(budgetID: "budget", generation: 0),
            repository: repository,
            conditions: [],
            join: .and,
            onApply: { _, _ in }
        )

        let load = Task { await coordinator.load() }
        guard await gate.waitForEntry() else {
            load.cancel()
            gate.release()
            await load.value
            Issue.record("The saved-filter load did not reach its bounded gate")
            return
        }
        coordinator.cancel()
        gate.release()
        await load.value

        #expect(coordinator.filters.isEmpty)
        #expect(!coordinator.isLoading)
    }

    @Test func closingBudgetClearsSavedFilterCacheForThatSession() async throws {
        let storeTests = LocalFirstActualStoreTests()
        let bundle = try await storeTests.makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            CREATE TABLE transaction_filters (
                id TEXT PRIMARY KEY, name TEXT, conditions TEXT, conditions_op TEXT, tombstone INTEGER
            );
            """)
        guard case .available(let filters) = try await bundle.store.refreshSavedTransactionFilters(budgetID: "group-1") else {
            Issue.record("Expected saved-filter capability in the opened fixture")
            return
        }
        #expect(filters.isEmpty)
        #expect(bundle.store.savedTransactionFiltersByBudget["group-1"] != nil)

        bundle.store.closeOpenBudget()
        #expect(bundle.store.savedTransactionFiltersByBudget["group-1"] == nil)
    }

    @Test func closingBeforeQueuedSavedFilterWritePreventsOldDatabaseCommit() async throws {
        let storeTests = LocalFirstActualStoreTests()
        let bundle = try await storeTests.makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.filterSchema)
        let database = try #require(bundle.store.database)
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let context = SavedTransactionFilterMutationContext(
            budgetID: "group-1", generation: bundle.store.budgetSessionGeneration
        )
        let outboxBefore = try await database.pendingLocalSyncMessageCount()
        let messagesBefore = try storeTests.storedCRDTMessages(at: databaseURL).count
        let gate = SavedFilterTestGate()
        bundle.store.savedFilterBeforeCommitHook = { await gate.pause() }
        let pending = Task {
            try await bundle.store.createSavedTransactionFilter(
                context: context,
                draft: Self.draft
            )
        }
        guard await gate.waitForEntry() else {
            pending.cancel()
            gate.release()
            _ = try? await pending.value
            Issue.record("The queued saved-filter write did not reach its bounded gate")
            return
        }
        bundle.store.closeOpenBudget()
        gate.release()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }

        #expect(try storeTests.storedCRDTMessages(at: databaseURL).count == messagesBefore)
        #expect(try tableCount("transaction_filters", at: databaseURL) == 0)
        #expect(try await database.pendingLocalSyncMessageCount() == outboxBefore)
    }

    @Test func committedWriteSurvivesCallerCancellationAndRefreshesActiveSession() async throws {
        let storeTests = LocalFirstActualStoreTests()
        let bundle = try await storeTests.makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.filterSchema)
        let context = SavedTransactionFilterMutationContext(
            budgetID: "group-1", generation: bundle.store.budgetSessionGeneration
        )
        let gate = SavedFilterTestGate()
        bundle.store.savedFilterAfterCommitHook = { await gate.pause() }
        let pending = Task {
            try await bundle.store.createSavedTransactionFilter(
                context: context,
                draft: Self.draft
            )
        }
        guard await gate.waitForEntry() else {
            pending.cancel()
            gate.release()
            _ = try? await pending.value
            Issue.record("The committed saved-filter write did not reach its bounded gate")
            return
        }
        pending.cancel()
        gate.release()
        let result = try await pending.value

        #expect(result.changed)
        #expect(result.appliedMessageCount == 4)
        #expect(!result.refreshPending)
        #expect(result.sessionCurrent)
        #expect(result.filters?.contains(where: { $0.name == "Accounts" }) == true)
    }

    @Test func committedWriteAfterSessionCloseReturnsReceiptWithoutPublishingOldCache() async throws {
        let storeTests = LocalFirstActualStoreTests()
        let bundle = try await storeTests.makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.filterSchema)
        let database = try #require(bundle.store.database)
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let context = SavedTransactionFilterMutationContext(
            budgetID: "group-1", generation: bundle.store.budgetSessionGeneration
        )
        let outboxBefore = try await database.pendingLocalSyncMessageCount()
        let messagesBefore = try storeTests.storedCRDTMessages(at: databaseURL).count
        let gate = SavedFilterTestGate()
        bundle.store.savedFilterAfterCommitHook = { await gate.pause() }
        let pending = Task {
            try await bundle.store.createSavedTransactionFilter(
                context: context,
                draft: Self.draft
            )
        }
        guard await gate.waitForEntry() else {
            pending.cancel()
            gate.release()
            _ = try? await pending.value
            Issue.record("The committed saved-filter write did not reach its bounded gate")
            return
        }
        bundle.store.closeOpenBudget()
        gate.release()
        let result = try await pending.value

        #expect(result.changed)
        #expect(result.appliedMessageCount == 4)
        #expect(result.refreshPending)
        #expect(!result.sessionCurrent)
        #expect(result.filters == nil)
        #expect(bundle.store.savedTransactionFiltersByBudget["group-1"] == nil)
        #expect(try storeTests.storedCRDTMessages(at: databaseURL).count == messagesBefore + 4)
        #expect(try await database.pendingLocalSyncMessageCount() == outboxBefore + 4)
    }

    @Test func retainedCoordinatorCannotMutateReopenedSameBudgetSession() async throws {
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            CREATE TABLE transaction_filters (
                id TEXT PRIMARY KEY, name TEXT, conditions TEXT, conditions_op TEXT, tombstone INTEGER
            );
            INSERT INTO transaction_filters VALUES (
                'existing', 'Existing', '[{"field":"account","op":"is","value":"checking","type":"id"}]', 'and', 0
            );
            """)
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let originalSession = SavedTransactionFilterMutationContext(
            budgetID: "group-1", generation: bundle.store.budgetSessionGeneration
        )
        let coordinator = SavedTransactionFiltersCoordinator(
            mutationContext: originalSession,
            repository: bundle.store,
            conditions: [TransactionQueryCondition.account(.equals("checking"))],
            join: .and,
            onApply: { _, _ in }
        )
        await coordinator.load()
        #expect(coordinator.filters.map(\.id) == ["existing"])

        bundle.store.closeOpenBudget()
        _ = try await bundle.store.openCachedBudget(bundle.budget)
        #expect(bundle.store.budgetSessionGeneration != originalSession.generation)
        let reopenedBytes = try Data(contentsOf: databaseURL)
        let database = try #require(bundle.store.database)
        let rowsBefore = try support.storedCRDTMessages(at: databaseURL).count
        let outboxBefore = try await database.pendingLocalSyncMessageCount()

        coordinator.nameDraft = "Created from retired session"
        await coordinator.saveCurrentConditions()
        coordinator.beginRename(try #require(coordinator.filters.first))
        coordinator.nameDraft = "Renamed from retired session"
        await coordinator.confirmRename()
        coordinator.requestDelete(try #require(coordinator.filters.first))
        await coordinator.confirmDelete()

        #expect(coordinator.errorMessage == nil)
        #expect(!coordinator.isSaving)
        #expect(try Data(contentsOf: databaseURL) == reopenedBytes)
        #expect(try support.storedCRDTMessages(at: databaseURL).count == rowsBefore)
        #expect(try await database.pendingLocalSyncMessageCount() == outboxBefore)
        #expect(try savedFilterRow("existing", at: databaseURL).name == "Existing")
        #expect(try savedFilterRow("existing", at: databaseURL).tombstone == 0)
    }

    @Test func capturedCurrentContextCanCreateRenameAndDelete() async throws {
        let bundle = try await LocalFirstActualStoreTests().makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.filterSchema
        )
        let coordinator = SavedTransactionFiltersCoordinator(
            mutationContext: SavedTransactionFilterMutationContext(
                budgetID: "group-1", generation: bundle.store.budgetSessionGeneration
            ),
            repository: bundle.store,
            conditions: [TransactionQueryCondition.account(.equals("checking"))],
            join: .and,
            onApply: { _, _ in }
        )

        coordinator.nameDraft = "Current session"
        await coordinator.saveCurrentConditions()
        let created = try #require(coordinator.filters.first)
        #expect(created.name == "Current session")
        coordinator.beginRename(created)
        coordinator.nameDraft = "Renamed"
        await coordinator.confirmRename()
        #expect(coordinator.filters.first?.name == "Renamed")
        coordinator.requestDelete(try #require(coordinator.filters.first))
        await coordinator.confirmDelete()
        #expect(coordinator.filters.isEmpty)
        #expect(coordinator.errorMessage == nil)
    }

    private static let draft = SavedTransactionFilterDraft(
        name: "Accounts",
        conditions: [RuleCondition(field: "account", operation: "is", value: .string("acct-a"), type: "id")],
        join: .and
    )

    private static let filterSchema = """
        CREATE TABLE transaction_filters (
            id TEXT PRIMARY KEY, name TEXT, conditions TEXT, conditions_op TEXT, tombstone INTEGER
        );
        """

    private func tableCount(_ table: String, at url: URL) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
                arguments: [table]
            ) ?? false
            guard exists else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func savedFilterRow(_ id: String, at url: URL) throws -> (name: String?, tombstone: Int?) {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT name, tombstone FROM transaction_filters WHERE id = ?",
                arguments: [id]
            ) else { return (nil, nil) }
            return (row["name"], row["tombstone"])
        }
    }
}

@MainActor
private final class SavedFilterRepositoryFake: SavedTransactionFilterRepositoryProtocol {
    private let result: SavedTransactionFilterReadResult
    private let gate: SavedFilterTestGate

    init(result: SavedTransactionFilterReadResult, gate: SavedFilterTestGate) {
        self.result = result
        self.gate = gate
    }

    func refreshSavedTransactionFilters(budgetID: String) async throws -> SavedTransactionFilterReadResult {
        await gate.pause()
        return result
    }

    func createSavedTransactionFilter(
        context: SavedTransactionFilterMutationContext,
        draft: SavedTransactionFilterDraft
    ) async throws -> SavedTransactionFilterMutationResult { fatalError("Unused in this test") }

    func updateSavedTransactionFilter(
        context: SavedTransactionFilterMutationContext,
        update: SavedTransactionFilterUpdate
    ) async throws -> SavedTransactionFilterMutationResult { fatalError("Unused in this test") }

    func deleteSavedTransactionFilter(
        context: SavedTransactionFilterMutationContext,
        filterID: String
    ) async throws -> SavedTransactionFilterMutationResult { fatalError("Unused in this test") }
}

@MainActor
private final class SavedFilterTestGate {
    private let entered = TestLatch()
    private let released = TestLatch()
    private var didEnter = false

    func pause() async {
        didEnter = true
        entered.trip()
        await released.wait()
    }

    func waitForEntry(timeout: Duration = .seconds(10)) async -> Bool {
        let reached = await entered.wait(timeout: timeout) { [released] in released.trip() }
        return didEnter && reached
    }

    func release() { released.trip() }
}
