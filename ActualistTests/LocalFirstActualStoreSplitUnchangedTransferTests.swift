import Foundation
import GRDB
import Testing
@testable import Actualist

/// A one-field split edit must not reconcile untouched transfer children (audit 2.18).
extension LocalFirstActualStoreTests {
    @Test func oneFieldSplitEditWritesNoTransferMessagesForUnlinkedTransferChild() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            ALTER TABLE transactions ADD COLUMN reconciled INTEGER;
            \(TransactionBatchDeleteTests.row("p", amount: -600, isParent: true, category: nil))
            \(TransactionBatchDeleteTests.row("c1", amount: -300, parent: "p"))
            \(TransactionBatchDeleteTests.row("c2", amount: -300, parent: "p", category: nil))
            UPDATE transactions SET description = 'xfer-savings' WHERE id = 'c2';
            """)
        let splits = [
            TransactionSplitDraft(
                id: "c1", categoryID: "groceries", categoryName: "Groceries",
                amountMinorUnits: -300, payeeID: .value("coffee")
            ),
            TransactionSplitDraft(
                id: "c2", categoryID: nil, categoryName: nil,
                amountMinorUnits: -300, payeeID: .value("xfer-savings")
            ),
        ]
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 5),
            amountMinorUnits: -600,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: "only the parent note changed",
            cleared: false,
            isTransfer: false,
            splits: splits
        )
        _ = try await bundle.store.updateTransactionAndRefresh(
            "p", with: draft, budgetID: "group-1",
            originalAccountID: "checking", originalMonth: "2026-07"
        ) {}

        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        let state = try await DatabaseQueue(path: url.path).read { db in
            (
                savings: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM transactions WHERE acct = 'savings'"
                ) ?? -1,
                link: try String.fetchOne(
                    db, sql: "SELECT transferred_id FROM transactions WHERE id = 'c2'"
                ),
                linkMessages: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE column = 'transferred_id'"
                ) ?? -1
            )
        }
        #expect(state.savings == 0)
        #expect(state.link == nil)
        #expect(state.linkMessages == 0)
    }
}
