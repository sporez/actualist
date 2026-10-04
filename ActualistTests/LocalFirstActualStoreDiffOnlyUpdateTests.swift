import Foundation
import GRDB
import Testing
@testable import Actualist

/// Audit 2.10: a simple-row edit writes only the cells that differ from the
/// caller's loaded baseline, so a stale edit cannot overwrite a remote change or
/// resurrect a row deleted elsewhere (loot-core `diffItems` / `updateTransfer`).
extension LocalFirstActualStoreTests {
    private func landRemoteNow(
        _ cells: [(row: String, column: String, value: String)],
        stamp: Int,
        on store: LocalFirstActualStore
    ) async throws {
        let messages = cells.enumerated().map { index, cell in
            ActualSyncDecodedMessage(
                timestamp: String(format: "2026-01-01T00:00:00.000Z-0000-%016d", stamp * 100 + index),
                dataset: "transactions", row: cell.row, column: cell.column, serializedValue: cell.value
            )
        }
        _ = try await store.requireDatabase(for: "group-1").applyRemoteSyncMessages(messages)
    }

    private func draftEditing(
        _ baseline: ActualTransaction,
        accountID: String? = nil,
        amount: Int? = nil,
        payeeID: String? = nil,
        categoryID: String?? = nil,
        notes: String?? = nil,
        isTransfer: Bool = false
    ) throws -> TransactionDraft {
        TransactionDraft(
            accountID: accountID ?? baseline.account,
            date: try makeDate(year: 2026, month: 7, day: 3),
            amountMinorUnits: amount ?? baseline.amount ?? 0,
            payeeID: payeeID ?? baseline.payee,
            payeeName: "",
            categoryID: categoryID ?? baseline.category,
            notes: notes ?? baseline.notes,
            cleared: baseline.cleared?.boolValue ?? false,
            isTransfer: isTransfer
        )
    }

    private func newLocalCells(
        since before: [ActualSyncDecodedMessage], at url: URL
    ) throws -> Set<String> {
        let known = Set(before.map(\.timestamp))
        return Set(try storedCRDTMessages(at: url).filter { !known.contains($0.timestamp) }.map { "\($0.row).\($0.column)" })
    }

    private func column(_ name: String, row: String, at url: URL) async throws -> String? {
        try await DatabaseQueue(path: url.path).read { db in
            try String.fetchOne(db, sql: "SELECT \(name) FROM transactions WHERE id = ?", arguments: [row])
        }
    }

    @Test func amountOnlyEditKeepsARemoteNotesChange() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let store = bundle.store
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        try await landRemoteNow([("txn", "description", "S:coffee")], stamp: 1, on: store)
        let baseline = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))
        try await landRemoteNow([("txn", "notes", "S:remote note")], stamp: 2, on: store)
        let before = try storedCRDTMessages(at: url)

        _ = try await store.updateTransactionAndRefresh(
            "txn", with: try draftEditing(baseline, amount: -20_000), budgetID: "group-1",
            originalAccountID: "checking", originalMonth: "2026-07", baseline: baseline,
            actionSource: .ui, didUpdate: {}
        )

        #expect(try newLocalCells(since: before, at: url) == ["txn.amount"])
        #expect(try await column("notes", row: "txn", at: url) == "remote note")
    }

    @Test func aLocalEditCarriesNoTombstoneSoAnOlderRemoteDeleteStillWins() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let store = bundle.store
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        try await landRemoteNow([("txn", "description", "S:coffee")], stamp: 1, on: store)
        let baseline = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))
        let before = try storedCRDTMessages(at: url)

        _ = try await store.updateTransactionAndRefresh(
            "txn", with: try draftEditing(baseline, notes: .some("edited")), budgetID: "group-1",
            originalAccountID: "checking", originalMonth: "2026-07", baseline: baseline,
            actionSource: .ui, didUpdate: {}
        )
        let cells = try newLocalCells(since: before, at: url)
        #expect(!cells.contains { $0.hasSuffix(".tombstone") })

        try await landRemoteNow([("txn", "tombstone", "N:1")], stamp: 3, on: store)
        #expect(try await column("tombstone", row: "txn", at: url) == "1")
    }

    @Test func transferAmountOnlyEditWritesBothAmountsAndNothingElse() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let store = bundle.store
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        let created = try await store.createTransactionAndRefresh(
            TransactionDraft(
                accountID: "checking", date: try makeDate(year: 2026, month: 7, day: 3),
                amountMinorUnits: -1_000, payeeID: "xfer-credit", payeeName: "",
                categoryID: nil, notes: "move", cleared: false, isTransfer: true
            ),
            budgetID: "group-1"
        ) {}
        let mainID = try #require(created.changed.transactions.first)
        let baseline = try #require(try await store.fetchTransaction(budgetID: "group-1", id: mainID))
        let pairedID = try #require(try await column("transferred_id", row: mainID, at: url))
        let before = try storedCRDTMessages(at: url)

        _ = try await store.updateTransactionAndRefresh(
            mainID, with: try draftEditing(baseline, amount: -1_500, isTransfer: true), budgetID: "group-1",
            originalAccountID: "checking", originalMonth: "2026-07", baseline: baseline,
            actionSource: .ui, didUpdate: {}
        )

        #expect(try newLocalCells(since: before, at: url) == ["\(mainID).amount", "\(pairedID).amount"])
    }

    @Test func transferDestinationOnlyEditWritesPairedAccountAndNeverDateOrCleared() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let store = bundle.store
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        let created = try await store.createTransactionAndRefresh(
            TransactionDraft(
                accountID: "checking", date: try makeDate(year: 2026, month: 7, day: 3),
                amountMinorUnits: -1_000, payeeID: "xfer-credit", payeeName: "",
                categoryID: nil, notes: nil, cleared: false, isTransfer: true
            ),
            budgetID: "group-1"
        ) {}
        let mainID = try #require(created.changed.transactions.first)
        let baseline = try #require(try await store.fetchTransaction(budgetID: "group-1", id: mainID))
        let pairedID = try #require(try await column("transferred_id", row: mainID, at: url))
        let before = try storedCRDTMessages(at: url)

        _ = try await store.updateTransactionAndRefresh(
            mainID, with: try draftEditing(baseline, payeeID: "xfer-savings", isTransfer: true), budgetID: "group-1",
            originalAccountID: "checking", originalMonth: "2026-07", baseline: baseline,
            actionSource: .ui, didUpdate: {}
        )

        #expect(try newLocalCells(since: before, at: url) == [
            "\(mainID).description", "\(pairedID).acct", "\(pairedID).category"
        ])
        #expect(try await column("acct", row: pairedID, at: url) == "savings")
    }

    @Test func nilBaselineDiffsAgainstTheRowReadInsideTheTransaction() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let store = bundle.store
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        try await landRemoteNow([("txn", "description", "S:coffee")], stamp: 1, on: store)
        let loaded = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))
        let before = try storedCRDTMessages(at: url)

        _ = try await store.updateTransactionAndRefresh(
            "txn", with: try draftEditing(loaded, notes: .some("only notes")), budgetID: "group-1",
            originalAccountID: "checking", originalMonth: "2026-07"
        ) {}

        #expect(try newLocalCells(since: before, at: url) == ["txn.notes"])
    }

    @Test func movingARowToAnOffBudgetAccountClearsItsCategory() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let store = bundle.store
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        try await landRemoteNow([("txn", "description", "S:coffee")], stamp: 1, on: store)
        let baseline = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))
        let before = try storedCRDTMessages(at: url)

        _ = try await store.updateTransactionAndRefresh(
            "txn", with: try draftEditing(baseline, accountID: "tracking"), budgetID: "group-1",
            originalAccountID: "checking", originalMonth: "2026-07", baseline: baseline,
            actionSource: .ui, didUpdate: {}
        )

        #expect(try newLocalCells(since: before, at: url) == ["txn.acct", "txn.category"])
        #expect(try await column("category", row: "txn", at: url) == nil)
    }

    @Test func undoRestoresTheFieldAfterADiffOnlyEdit() async throws {
        let store = try await makeOpenedWritableStore()
        try await landRemoteNow([("txn", "description", "S:coffee")], stamp: 1, on: store)
        let baseline = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))

        _ = try await store.updateTransactionAndRefresh(
            "txn", with: try draftEditing(baseline, amount: -20_000), budgetID: "group-1",
            originalAccountID: "checking", originalMonth: "2026-07", baseline: baseline,
            actionSource: .ui, didUpdate: {}
        )
        let row = try #require(try await store.recentBudgetActions(budgetID: "group-1").first)
        #expect(row.kind == .editTransaction)
        try await store.undoBudgetActionAndRefresh(actionID: row.id, budgetID: "group-1")

        let restored = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))
        #expect(restored.amount == -12_345)
    }
}
