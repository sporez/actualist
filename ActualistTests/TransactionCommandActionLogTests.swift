import Foundation
import GRDB
import Testing
@testable import Actualist

@Suite @MainActor struct TransactionCommandActionLogTests {
    private typealias StoreFixtures = LocalFirstActualStoreTests

    private struct TransactionRowState: Equatable, CustomStringConvertible {
        var id: String
        var accountID: String?
        var dateValue: Int?
        var amount: Int?
        var payeeID: String?
        var categoryID: String?
        var notes: String?
        var cleared: Int?
        var reconciled: Int?
        var tombstone: Int?
        var parentID: String?
        var isParent: Int?
        var isChild: Int?
        var transferID: String?
        var sortOrder: Double?
        var splitError: String?

        var description: String {
            func value<T>(_ optional: T?) -> String { optional.map { "\($0)" } ?? "nil" }
            return "TransactionRowState(id: \(id), accountID: \(accountID ?? "nil"), date: \(value(dateValue)), "
                + "amount: \(value(amount)), payeeID: \(payeeID ?? "nil"), categoryID: \(categoryID ?? "nil"), "
                + "notes: \(notes ?? "nil"), cleared: \(value(cleared)), reconciled: \(value(reconciled)), "
                + "tombstone: \(value(tombstone)), parentID: \(parentID ?? "nil"), "
                + "isParent: \(value(isParent)), isChild: \(value(isChild)), "
                + "transferID: \(transferID ?? "nil"), sortOrder: \(value(sortOrder)), "
                + "error: \(splitError ?? "nil"))"
        }
    }

    private func makeBundle(
        additionalFixtureSQL: String = ""
    ) async throws -> StoreFixtures.OpenedWritableStoreBundle {
        try await StoreFixtures().makeOpenedWritableStoreBundle(
            keychainBackend: FakeKeychainBackend(),
            additionalFixtureSQL: additionalFixtureSQL
        )
    }

    private func makeAction(
        database: BudgetDatabase,
        drafts: [ActualSyncDecodedMessage],
        descriptor: BudgetActionDescriptor,
        actionID: String = UUID().uuidString
    ) async throws -> BudgetActionRecord {
        try await database.commitUserAction(
            drafts,
            descriptor: descriptor,
            source: .ui,
            actionID: actionID
        )
        return try #require(try await database.actionLogRecord(id: actionID))
    }

    private func makeSimpleDraft(
        date: Date,
        amount: Int,
        categoryID: String?,
        notes: String? = nil
    ) -> TransactionDraft {
        TransactionDraft(
            accountID: "checking",
            date: date,
            amountMinorUnits: amount,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: categoryID,
            notes: notes,
            cleared: false,
            isTransfer: false
        )
    }

    private func makeMessage(
        _ builder: inout LocalFirstSyncMessageBuilder,
        row: String,
        column: String,
        value: LocalFirstSyncValue
    ) throws -> ActualSyncDecodedMessage {
        try builder.makeMessage(dataset: "transactions", row: row, column: column, value: value)
    }

    private func rowState(
        id: String,
        databaseURL: URL
    ) throws -> TransactionRowState? {
        let queue = try DatabaseQueue(path: databaseURL.path)
        return try queue.readSync { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, acct, date, amount, description, category, notes, cleared,
                           reconciled, tombstone, parent_id, is_parent, isChild,
                           transferred_id, sort_order, error
                    FROM transactions WHERE id = ?
                    """,
                arguments: [id]
            ) else { return nil }
            return TransactionRowState(
                id: row["id"],
                accountID: row["acct"],
                dateValue: row["date"],
                amount: row["amount"],
                payeeID: row["description"],
                categoryID: row["category"],
                notes: row["notes"],
                cleared: row["cleared"],
                reconciled: row["reconciled"],
                tombstone: row["tombstone"],
                parentID: row["parent_id"],
                isParent: row["is_parent"],
                isChild: row["isChild"],
                transferID: row["transferred_id"],
                sortOrder: row["sort_order"],
                splitError: row["error"]
            )
        }
    }

    private func splitFixtureSQL(parentID: String = "source-parent") -> String {
        """
        INSERT INTO transactions
            (id, acct, date, amount, category, tombstone, parent_id, is_parent,
             description, notes, cleared, transferred_id, isChild)
        VALUES
            ('\(parentID)', 'checking', 20260703, -1000, NULL, 0, NULL, 1,
             'coffee', 'parent note', 0, NULL, 0),
            ('\(parentID)-child-a', 'checking', 20260703, -400, 'groceries', 0, '\(parentID)', 0,
             'coffee', NULL, 0, NULL, 1),
            ('\(parentID)-child-b', 'checking', 20260703, -600, 'utilities', 0, '\(parentID)', 0,
             'coffee', NULL, 0, NULL, 1);
        """
    }

    @Test func duplicateSimpleUndoRemovesOnlyTheCloneAndRecordsOneAction() async throws {
        let bundle = try await makeBundle()
        let database = try bundle.store.requireDatabase(for: "group-1")
        let originalBefore = try #require(try rowState(
            id: "txn",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        ))
        var builder = LocalFirstSyncMessageBuilder()
        let drafts = try await database.createSimpleTransactionMessages(
            makeSimpleDraft(
                date: try StoreFixtures().makeDate(year: 2026, month: 7, day: 3),
                amount: -12_345,
                categoryID: "groceries"
            ),
            transactionID: "duplicate-simple",
            payeeID: "coffee",
            builder: &builder
        )
        let record = try await makeAction(
            database: database,
            drafts: drafts,
            descriptor: .transactionDuplicate(TransactionDuplicateActionDescriptor(
                selectedSourceTransactionIDs: ["txn"],
                preallocatedCloneTransactionIDs: ["duplicate-simple"]
            )),
            actionID: "duplicate-simple-action"
        )
        #expect(record.kind == .transactionDuplicate)
        #expect(!record.inverse.requiresBudgetModeIdentity)
        guard case .transactionDuplicate(let summary) = record.summary,
              case .transactionDuplicate(let inverse) = record.inverse else {
            Issue.record("expected the explicit duplicate summary and inverse")
            return
        }
        #expect(summary.selectedSourceTransactionIDs == ["txn"])
        #expect(summary.duplicateTransactionIDs == ["duplicate-simple"])
        #expect(inverse.afterSnapshots.map(\.id) == ["duplicate-simple"])

        let preview = try await database.actionUndoPreview(record: record)
        #expect(preview.block == nil)
        #expect(preview.transactionLines.map(\.effect) == [.duplicateRemoval])

        try await database.commitActionUndo(record: record)

        #expect(try rowState(
            id: "txn",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        ) == originalBefore)
        #expect(try rowState(
            id: "duplicate-simple",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        )?.tombstone == 1)
        #expect(try await database.actionLogRecord(id: record.id)?.status == .undone)
    }

    @Test func duplicateSplitUndoTombstonesEveryCloneAndLeavesSourceFamilyUntouched() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: splitFixtureSQL())
        let database = try bundle.store.requireDatabase(for: "group-1")
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let sourceIDs = ["source-parent", "source-parent-child-a", "source-parent-child-b"]
        let sourceBefore = try sourceIDs.map { try #require(try rowState(id: $0, databaseURL: databaseURL)) }
        let cloneIDs = ["duplicate-parent", "duplicate-parent-child-a", "duplicate-parent-child-b"].sorted()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try StoreFixtures().makeDate(year: 2026, month: 7, day: 3),
            amountMinorUnits: -1_000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: "parent note",
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: cloneIDs[1], categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -400),
                TransactionSplitDraft(id: cloneIDs[2], categoryID: "utilities", categoryName: "Utilities", amountMinorUnits: -600)
            ]
        )
        var builder = LocalFirstSyncMessageBuilder()
        let drafts = try await database.createSplitTransactionMessages(
            draft: draft,
            parentTransactionID: cloneIDs[0],
            payeeID: "coffee",
            builder: &builder
        )
        let record = try await makeAction(
            database: database,
            drafts: drafts,
            descriptor: .transactionDuplicate(TransactionDuplicateActionDescriptor(
                selectedSourceTransactionIDs: ["source-parent"],
                preallocatedCloneTransactionIDs: cloneIDs
            )),
            actionID: "duplicate-split-action"
        )
        let preview = try await database.actionUndoPreview(record: record)
        #expect(preview.block == nil)
        #expect(Set(preview.transactionLines.map(\.id)) == Set(cloneIDs))

        try await database.commitActionUndo(record: record)

        #expect(try sourceIDs.map { try #require(try rowState(id: $0, databaseURL: databaseURL)) } == sourceBefore)
        #expect(try cloneIDs.allSatisfy { try rowState(id: $0, databaseURL: databaseURL)?.tombstone == 1 })
    }

    @Test func duplicateTransferUndoTombstonesBothClonesAndLeavesOriginalPairUntouched() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: """
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, parent_id, is_parent,
                 description, notes, cleared, transferred_id, isChild)
            VALUES
                ('source-transfer', 'checking', 20260703, -1000, NULL, 0, NULL, 0,
                 'xfer-credit', 'transfer note', 0, 'source-transfer-peer', 0),
                ('source-transfer-peer', 'credit', 20260703, 1000, NULL, 0, NULL, 0,
                 'xfer-checking', 'transfer note', 0, 'source-transfer', 0);
            """)
        let database = try bundle.store.requireDatabase(for: "group-1")
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let sourceIDs = ["source-transfer", "source-transfer-peer"]
        let sourceBefore = try sourceIDs.map { try #require(try rowState(id: $0, databaseURL: databaseURL)) }
        var builder = LocalFirstSyncMessageBuilder()
        let result = try await database.createTransferTransactionMessages(
            draft: TransactionDraft(
                accountID: "checking",
                date: try StoreFixtures().makeDate(year: 2026, month: 7, day: 3),
                amountMinorUnits: -1_000,
                payeeID: "xfer-credit",
                payeeName: "",
                categoryID: nil,
                notes: "transfer note",
                cleared: false,
                isTransfer: true
            ),
            sourceTransactionID: "duplicate-transfer",
            payeeID: "xfer-credit",
            builder: &builder
        )
        let cloneIDs = ["duplicate-transfer", result.pairedTransactionID].sorted()
        let record = try await makeAction(
            database: database,
            drafts: result.messages,
            descriptor: .transactionDuplicate(TransactionDuplicateActionDescriptor(
                selectedSourceTransactionIDs: ["source-transfer"],
                preallocatedCloneTransactionIDs: cloneIDs
            )),
            actionID: "duplicate-transfer-action"
        )

        try await database.commitActionUndo(record: record)

        #expect(try sourceIDs.map { try #require(try rowState(id: $0, databaseURL: databaseURL)) } == sourceBefore)
        #expect(try cloneIDs.allSatisfy { try rowState(id: $0, databaseURL: databaseURL)?.tombstone == 1 })
    }

    @Test func mergeUndoRestoresTheWholeGraphAndPreviewNamesLinkedRows() async throws {
        // The base fixture's `txn` row predates the isChild column, so it stores
        // SQL NULL there; real Actual rows always carry an explicit is_child
        // value, and the shared snapshot reader derives the effective flag from
        // parent_id. Give the row the explicit value so the raw-state comparison
        // after undo reflects the real-data contract rather than the NULL
        // representation.
        let bundle = try await makeBundle(
            additionalFixtureSQL: splitFixtureSQL(parentID: "merge-parent")
                + "\nUPDATE transactions SET isChild = 0 WHERE id = 'txn';"
        )
        let database = try bundle.store.requireDatabase(for: "group-1")
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let affectedIDs = ["merge-parent", "merge-parent-child-a", "merge-parent-child-b", "txn"].sorted()
        let before = try affectedIDs.map { try #require(try rowState(id: $0, databaseURL: databaseURL)) }
        var builder = LocalFirstSyncMessageBuilder()
        let drafts = [
            try makeMessage(&builder, row: "txn", column: "amount", value: .int(-20_000)),
            try makeMessage(&builder, row: "txn", column: "category", value: .string("dining")),
            try makeMessage(&builder, row: "merge-parent", column: "tombstone", value: .bool(true)),
            try makeMessage(&builder, row: "merge-parent-child-a", column: "tombstone", value: .bool(true)),
            try makeMessage(&builder, row: "merge-parent-child-b", column: "tombstone", value: .bool(true))
        ]
        let record = try await makeAction(
            database: database,
            drafts: drafts,
            descriptor: .transactionMerge(TransactionMergeActionDescriptor(
                orderedInputTransactionIDs: ["txn", "merge-parent"],
                keptTransactionID: "txn",
                droppedTransactionID: "merge-parent",
                affectedGraphTransactionIDs: affectedIDs
            )),
            actionID: "merge-graph-action"
        )
        guard case .transactionMerge(let inverse) = record.inverse else {
            Issue.record("expected the explicit full-graph merge inverse")
            return
        }
        #expect(inverse.beforeSnapshots.map(\.id) == affectedIDs)
        #expect(inverse.afterSnapshots.map(\.id) == affectedIDs)
        #expect(inverse.afterSnapshots.first(where: { $0.id == "merge-parent" })?.tombstone == true)

        let preview = try await database.actionUndoPreview(record: record)
        #expect(preview.block == nil)
        #expect(Set(preview.transactionLines.map(\.id)) == Set(affectedIDs))
        #expect(preview.transactionLines.first(where: { $0.id == "merge-parent-child-a" })?.effect == .mergeRestoration)
        #expect(preview.transactionLines.first(where: { $0.id == "merge-parent-child-a" })?.isLinkedEntry == true)

        try await database.commitActionUndo(record: record)

        let restored = try affectedIDs.map { try #require(try rowState(id: $0, databaseURL: databaseURL)) }
        for (index, id) in affectedIDs.enumerated() {
            #expect(restored[index] == before[index], "\(id) after undo: \(restored[index])\nbefore: \(before[index])")
        }
    }

    @Test func duplicateUndoBlocksLaterRowEditsWithoutChangingTheEditedClone() async throws {
        let bundle = try await makeBundle()
        let database = try bundle.store.requireDatabase(for: "group-1")
        var builder = LocalFirstSyncMessageBuilder()
        let drafts = try await database.createSimpleTransactionMessages(
            makeSimpleDraft(
                date: try StoreFixtures().makeDate(year: 2026, month: 7, day: 3),
                amount: -12_345,
                categoryID: "groceries"
            ),
            transactionID: "edited-duplicate",
            payeeID: "coffee",
            builder: &builder
        )
        let record = try await makeAction(
            database: database,
            drafts: drafts,
            descriptor: .transactionDuplicate(TransactionDuplicateActionDescriptor(
                selectedSourceTransactionIDs: ["txn"],
                preallocatedCloneTransactionIDs: ["edited-duplicate"]
            )),
            actionID: "edited-duplicate-action"
        )
        let preview = try await database.actionUndoPreview(record: record)
        #expect(preview.block == nil)
        let pendingBeforeEdit = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")
        var editBuilder = LocalFirstSyncMessageBuilder()
        let noteEdit = try makeMessage(
            &editBuilder,
            row: "edited-duplicate",
            column: "notes",
            value: .string("later edit")
        )
        let backlinkEdit = try makeMessage(
            &editBuilder,
            row: "edited-duplicate",
            column: "transferred_id",
            value: .string("txn")
        )
        try await database.commitLocalSyncMessagesAndEnqueue([noteEdit, backlinkEdit])
        let pendingAfterEdit = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")

        await #expect(throws: LocalFirstError.actionUndoBlocked(
            BudgetActionUndoBlock.transactionCommandChanged.userFacingReason
        )) {
            try await database.commitActionUndo(record: record)
        }

        #expect(try rowState(
            id: "edited-duplicate",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        )?.notes == "later edit")
        #expect(try rowState(
            id: "edited-duplicate",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        )?.transferID == "txn")
        #expect(try rowState(
            id: "edited-duplicate",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        )?.tombstone == 0)
        #expect(try await database.actionLogRecord(id: record.id)?.status == .applied)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == pendingAfterEdit)
        #expect(pendingAfterEdit > pendingBeforeEdit)
    }

    @Test func duplicateSplitUndoBlocksAChildAddedAfterReview() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: splitFixtureSQL())
        let database = try bundle.store.requireDatabase(for: "group-1")
        let cloneIDs = ["duplicate-parent", "duplicate-parent-child-a", "duplicate-parent-child-b"].sorted()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try StoreFixtures().makeDate(year: 2026, month: 7, day: 3),
            amountMinorUnits: -1_000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: "parent note",
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: cloneIDs[1], categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -400),
                TransactionSplitDraft(id: cloneIDs[2], categoryID: "utilities", categoryName: "Utilities", amountMinorUnits: -600)
            ]
        )
        var builder = LocalFirstSyncMessageBuilder()
        let drafts = try await database.createSplitTransactionMessages(
            draft: draft,
            parentTransactionID: cloneIDs[0],
            payeeID: "coffee",
            builder: &builder
        )
        let record = try await makeAction(
            database: database,
            drafts: drafts,
            descriptor: .transactionDuplicate(TransactionDuplicateActionDescriptor(
                selectedSourceTransactionIDs: ["source-parent"],
                preallocatedCloneTransactionIDs: cloneIDs
            )),
            actionID: "child-added-action"
        )
        var childBuilder = LocalFirstSyncMessageBuilder()
        var extraChild = try await database.createSimpleTransactionMessages(
            makeSimpleDraft(
                date: try StoreFixtures().makeDate(year: 2026, month: 7, day: 3),
                amount: -100,
                categoryID: "groceries"
            ),
            transactionID: "later-child",
            payeeID: "coffee",
            builder: &childBuilder
        )
        extraChild.removeAll { $0.column == "parent_id" || $0.column == "isChild" }
        extraChild.append(try makeMessage(&childBuilder, row: "later-child", column: "parent_id", value: .string("duplicate-parent")))
        extraChild.append(try makeMessage(&childBuilder, row: "later-child", column: "isChild", value: .bool(true)))
        try await database.commitLocalSyncMessagesAndEnqueue(extraChild)

        let preview = try await database.actionUndoPreview(record: record)
        #expect(preview.block == .transactionCommandChanged)
        await #expect(throws: LocalFirstError.actionUndoBlocked(
            BudgetActionUndoBlock.transactionCommandChanged.userFacingReason
        )) {
            try await database.commitActionUndo(record: record)
        }
        #expect(try rowState(
            id: "duplicate-parent",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        )?.tombstone == 0)
        #expect(try rowState(
            id: "duplicate-parent-child-a",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        )?.tombstone == 0)
        #expect(try rowState(
            id: "duplicate-parent-child-b",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        )?.tombstone == 0)
    }

    @Test func mergeUndoBlocksAnExtraIncomingLinkToItsTombstonedTarget() async throws {
        let bundle = try await makeBundle(additionalFixtureSQL: splitFixtureSQL(parentID: "merge-parent"))
        let database = try bundle.store.requireDatabase(for: "group-1")
        let affectedIDs = ["merge-parent", "merge-parent-child-a", "merge-parent-child-b", "txn"].sorted()
        var builder = LocalFirstSyncMessageBuilder()
        let drafts = [
            try makeMessage(&builder, row: "txn", column: "amount", value: .int(-20_000)),
            try makeMessage(&builder, row: "merge-parent", column: "tombstone", value: .bool(true)),
            try makeMessage(&builder, row: "merge-parent-child-a", column: "tombstone", value: .bool(true)),
            try makeMessage(&builder, row: "merge-parent-child-b", column: "tombstone", value: .bool(true))
        ]
        let record = try await makeAction(
            database: database,
            drafts: drafts,
            descriptor: .transactionMerge(TransactionMergeActionDescriptor(
                orderedInputTransactionIDs: ["txn", "merge-parent"],
                keptTransactionID: "txn",
                droppedTransactionID: "merge-parent",
                affectedGraphTransactionIDs: affectedIDs
            )),
            actionID: "incoming-link-action"
        )
        var linkBuilder = LocalFirstSyncMessageBuilder()
        var extraIncoming = try await database.createSimpleTransactionMessages(
            makeSimpleDraft(
                date: try StoreFixtures().makeDate(year: 2026, month: 7, day: 3),
                amount: -50,
                categoryID: nil
            ),
            transactionID: "external-incoming",
            payeeID: "coffee",
            builder: &linkBuilder
        )
        extraIncoming.append(try makeMessage(
            &linkBuilder,
            row: "external-incoming",
            column: "transferred_id",
            value: .string("merge-parent")
        ))
        try await database.commitLocalSyncMessagesAndEnqueue(extraIncoming)

        #expect(try rowState(
            id: "merge-parent",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        )?.tombstone == 1)
        let preview = try await database.actionUndoPreview(record: record)
        #expect(preview.block == .transactionCommandChanged)
        await #expect(throws: LocalFirstError.actionUndoBlocked(
            BudgetActionUndoBlock.transactionCommandChanged.userFacingReason
        )) {
            try await database.commitActionUndo(record: record)
        }
        #expect(try rowState(
            id: "txn",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        )?.amount == -20_000)
        #expect(try rowState(
            id: "merge-parent-child-a",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        )?.tombstone == 1)
        #expect(try await database.actionLogRecord(id: record.id)?.status == .applied)
    }

    @Test func mismatchedCloneIDsRollBackRowsOutboxAndHistoryTogether() async throws {
        let bundle = try await makeBundle()
        let database = try bundle.store.requireDatabase(for: "group-1")
        let pendingBefore = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")
        var builder = LocalFirstSyncMessageBuilder()
        let drafts = try await database.createSimpleTransactionMessages(
            makeSimpleDraft(
                date: try StoreFixtures().makeDate(year: 2026, month: 7, day: 3),
                amount: -12_345,
                categoryID: "groceries"
            ),
            transactionID: "actual-clone",
            payeeID: "coffee",
            builder: &builder
        )

        await #expect(throws: (any Error).self) {
            try await database.commitUserAction(
                drafts,
                descriptor: .transactionDuplicate(TransactionDuplicateActionDescriptor(
                    selectedSourceTransactionIDs: ["txn"],
                    preallocatedCloneTransactionIDs: ["different-preallocated-id"]
                )),
                source: .ui,
                actionID: "rolled-back-duplicate"
            )
        }

        #expect(try rowState(
            id: "actual-clone",
            databaseURL: bundle.fileManager.databaseURL(fileID: "file-1")
        ) == nil)
        #expect(try await database.actionLogRecord(id: "rolled-back-duplicate") == nil)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == pendingBefore)
    }

    private func completeSnapshot(
        id: String,
        amount: Int,
        tombstone: Bool,
        columns: [String]? = nil
    ) -> TransactionBatchTransactionSnapshot {
        TransactionBatchTransactionSnapshot(
            id: id,
            columns: columns ?? [
                "acct", "amount", "category", "cleared", "date", "description", "error",
                "isChild", "is_parent", "notes", "parent_id", "reconciled", "tombstone", "transferred_id"
            ].sorted(),
            accountID: "checking",
            dateValue: 20260703,
            amount: amount,
            payeeID: "coffee",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            reconciled: false,
            tombstone: tombstone,
            isParent: false,
            isChild: false,
            parentID: nil,
            transferID: nil,
            sortOrder: nil,
            splitError: nil,
            startingBalance: nil,
            scheduleID: nil,
            importedID: nil,
            importedPayee: nil,
            importedDescription: nil
        )
    }

    @Test func commandCodableTagsAndUndoIdentityStaySeparateFromTransactionBatch() throws {
        let clone = completeSnapshot(id: "clone", amount: -100, tombstone: false)
        let duplicateSummary = BudgetActionSummary.transactionDuplicate(TransactionDuplicateBudgetAction(
            selectedSourceTransactionIDs: ["source"],
            duplicateTransactionIDs: ["clone"]
        ))
        let duplicateInverse = BudgetActionInverse.transactionDuplicate(
            TransactionDuplicateTransactionInverse(afterSnapshots: [clone])
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let summaryData = try encoder.encode(duplicateSummary)
        let inverseData = try encoder.encode(duplicateInverse)
        #expect(String(decoding: summaryData, as: UTF8.self).contains("transactionDuplicate"))
        #expect(String(decoding: inverseData, as: UTF8.self).contains("transactionDuplicate"))
        #expect(try decoder.decode(BudgetActionSummary.self, from: summaryData) == duplicateSummary)
        #expect(try decoder.decode(BudgetActionInverse.self, from: inverseData) == duplicateInverse)
        #expect(!duplicateInverse.requiresBudgetModeIdentity)

        let beforeDrop = completeSnapshot(id: "drop", amount: -50, tombstone: false)
        let afterDrop = completeSnapshot(id: "drop", amount: -50, tombstone: true)
        let keep = completeSnapshot(id: "keep", amount: -150, tombstone: false)
        let mergeSummary = BudgetActionSummary.transactionMerge(TransactionMergeBudgetAction(
            orderedInputTransactionIDs: ["keep", "drop"],
            keptTransactionID: "keep",
            droppedTransactionID: "drop",
            affectedGraphTransactionIDs: ["drop", "keep"]
        ))
        let mergeInverse = BudgetActionInverse.transactionMerge(TransactionMergeTransactionInverse(
            beforeSnapshots: [beforeDrop, completeSnapshot(id: "keep", amount: -100, tombstone: false)],
            afterSnapshots: [afterDrop, keep]
        ))
        #expect(!mergeInverse.requiresBudgetModeIdentity)
        let mergeSummaryData = try encoder.encode(mergeSummary)
        let mergeInverseData = try encoder.encode(mergeInverse)
        #expect(String(decoding: mergeSummaryData, as: UTF8.self).contains("transactionMerge"))
        #expect(String(decoding: mergeInverseData, as: UTF8.self).contains("transactionMerge"))
        #expect(try decoder.decode(BudgetActionSummary.self, from: mergeSummaryData) == mergeSummary)
        #expect(try decoder.decode(BudgetActionInverse.self, from: mergeInverseData) == mergeInverse)

        let oldBatchSummary = BudgetActionSummary.transactionBatch(TransactionBatchBudgetAction(
            operation: .clear,
            selectedCount: 1,
            changedCount: 1,
            clearTarget: true,
            categoryID: nil
        ))
        let legacyBatchSummaryJSON = Data(
            #"{"type":"transactionBatch","payload":{"payload":{"operation":"clear","selectedCount":1,"changedCount":1,"clearTarget":true,"categoryID":null}}}"#.utf8
        )
        #expect(try decoder.decode(BudgetActionSummary.self, from: legacyBatchSummaryJSON) == oldBatchSummary)

        let oldBatchInverse = BudgetActionInverse.transactionBatch(TransactionBatchTransactionInverse(
            operation: .clear,
            selectedTransactionIDs: ["legacy-selected"],
            beforeSnapshots: [],
            afterSnapshots: [],
            learning: .empty
        ))
        let legacyBatchInverseJSON = Data(
            #"{"type":"transactionBatch","payload":{"payload":{"operation":"clear","selectedTransactionIDs":["legacy-selected"],"beforeSnapshots":[],"afterSnapshots":[],"learning":{"createdRuleIDs":[],"updatedRules":[]}}}}"#.utf8
        )
        #expect(try decoder.decode(BudgetActionInverse.self, from: legacyBatchInverseJSON) == oldBatchInverse)
        #expect(BudgetActionKind.transactionBatch.rawValue == "transactionBatch")
    }

    @Test func malformedOrReorderedCommandSnapshotsFailClosed() {
        let first = completeSnapshot(id: "a", amount: -100, tombstone: false)
        let second = completeSnapshot(id: "b", amount: -200, tombstone: false)
        let summary = TransactionDuplicateBudgetAction(
            selectedSourceTransactionIDs: ["source"],
            duplicateTransactionIDs: ["a", "b"]
        )
        let reordered = TransactionDuplicateTransactionInverse(afterSnapshots: [second, first])
        #expect(!TransactionCommandActionValidation.duplicate(summary: summary, inverse: reordered))
        #expect(!TransactionCommandActionValidation.duplicate(
            summary: summary,
            inverse: TransactionDuplicateTransactionInverse(afterSnapshots: [first])
        ))
        #expect(!TransactionCommandActionValidation.duplicate(
            summary: summary,
            inverse: TransactionDuplicateTransactionInverse(afterSnapshots: [first, second, completeSnapshot(
                id: "c",
                amount: -300,
                tombstone: false
            )])
        ))
        let partial = completeSnapshot(
            id: "a",
            amount: -100,
            tombstone: false,
            columns: first.columns.filter { $0 != "amount" }
        )
        #expect(!TransactionCommandActionValidation.duplicate(
            summary: summary,
            inverse: TransactionDuplicateTransactionInverse(afterSnapshots: [partial, second])
        ))

        let merge = TransactionMergeBudgetAction(
            orderedInputTransactionIDs: ["a", "b"],
            keptTransactionID: "a",
            droppedTransactionID: "b",
            affectedGraphTransactionIDs: ["a", "b"]
        )
        let invalidAfter = TransactionMergeTransactionInverse(
            beforeSnapshots: [first, second],
            afterSnapshots: [first, second]
        )
        #expect(!TransactionCommandActionValidation.merge(summary: merge, inverse: invalidAfter))
        #expect(!TransactionCommandActionValidation.merge(
            summary: merge,
            inverse: TransactionMergeTransactionInverse(
                beforeSnapshots: [first, second],
                afterSnapshots: [first]
            )
        ))
    }
}
