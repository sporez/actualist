import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func createSplitNullsParentPayeeAndInheritsChildPayee() async throws {
        let store = try await makeOpenedWritableStore()
        let created = try await store.createTransactionAndRefresh(
            splitDraft(
                amount: -10_000,
                splits: [
                    TransactionSplitDraft(id: "child-a", categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -4_000),
                    TransactionSplitDraft(id: "child-b", categoryID: "utilities", categoryName: "Utilities", amountMinorUnits: -6_000),
                ]
            ),
            budgetID: "group-1"
        ) {}
        let parent = try #require(parentTransaction(in: store, id: created.changed.transactions.first))
        #expect(parent.payee == nil)
        #expect(parent.category == nil)
        #expect(parent.error == nil)
        #expect(parent.subtransactions.map(\.payee) == ["coffee", "coffee"])
        #expect(parent.subtransactions.map(\.category) == ["groceries", "utilities"])
        #expect(parent.subtransactions.map(\.amount) == [-4_000, -6_000])
    }

    @Test func createSplitPreservesNullableChildFieldsAndMixedSigns() async throws {
        let store = try await makeOpenedWritableStore()
        let created = try await store.createTransactionAndRefresh(
            splitDraft(
                amount: -10_000,
                splits: [
                    TransactionSplitDraft(
                        id: "spend",
                        categoryID: "groceries",
                        categoryName: "Groceries",
                        amountMinorUnits: -11_000,
                        payeeID: .value("coffee"),
                        notes: .value("child note")
                    ),
                    TransactionSplitDraft(
                        id: "refund",
                        categoryID: "utilities",
                        categoryName: "Utilities",
                        amountMinorUnits: 1_000,
                        payeeID: .value(nil),
                        notes: .value("refund")
                    ),
                    TransactionSplitDraft(
                        id: "zero",
                        categoryID: nil,
                        categoryName: nil,
                        amountMinorUnits: 0,
                        payeeID: .value(nil),
                        notes: .value("zero child")
                    ),
                ]
            ),
            budgetID: "group-1"
        ) {}
        let parent = try #require(parentTransaction(in: store, id: created.changed.transactions.first))
        #expect(parent.error == nil)
        #expect(parent.subtransactions.map(\.amount) == [-11_000, 1_000, 0])
        #expect(parent.subtransactions.map(\.payee) == ["coffee", nil, nil])
        #expect(parent.subtransactions.map(\.notes) == ["child note", "refund", "zero child"])
        #expect(parent.subtransactions.map(\.category) == ["groceries", "utilities", nil])
    }

    @Test func updateOneChildDoesNotRewriteSiblingPayeeOrNotes() async throws {
        let store = try await makeOpenedWritableStore()
        let created = try await store.createTransactionAndRefresh(
            splitDraft(
                amount: -10_000,
                splits: [
                    TransactionSplitDraft(
                        id: "child-a",
                        categoryID: "groceries",
                        categoryName: "Groceries",
                        amountMinorUnits: -4_000,
                        payeeID: .value("coffee"),
                        notes: .value("keep me")
                    ),
                    TransactionSplitDraft(
                        id: "child-b",
                        categoryID: "utilities",
                        categoryName: "Utilities",
                        amountMinorUnits: -6_000,
                        payeeID: .value("market"),
                        notes: .value("override")
                    ),
                ]
            ),
            budgetID: "group-1"
        ) {}
        let parentID = try #require(created.changed.transactions.first)
        _ = try await store.updateTransactionAndRefresh(
            parentID,
            with: splitDraft(
                amount: -10_000,
                splits: [
                    TransactionSplitDraft(id: "child-a", categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -3_000),
                    TransactionSplitDraft(id: "child-b", categoryID: "utilities", categoryName: "Utilities", amountMinorUnits: -6_000),
                ]
            ),
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}
        let parent = try #require(parentTransaction(in: store, id: parentID))
        #expect(parent.error?.difference == -1_000)
        #expect(parent.subtransactions.first { $0.id == "child-a" }?.notes == "keep me")
        #expect(parent.subtransactions.first { $0.id == "child-a" }?.payee == "coffee")
        #expect(parent.subtransactions.first { $0.id == "child-b" }?.notes == "override")
        #expect(parent.subtransactions.first { $0.id == "child-b" }?.payee == "market")
        let database = try #require(store.database)
        let rewrittenDuringUpdate = try await database.pendingLocalSyncMessages().map(\.message).filter {
            $0.row == "child-b"
                && $0.column == "description"
                && $0.serializedValue == LocalFirstSyncValue.string("coffee").serialized
        }
        #expect(rewrittenDuringUpdate.isEmpty)
    }

    @Test func deleteLastChildCollapsesParent() async throws {
        let store = try await makeOpenedWritableStore()
        let created = try await store.createTransactionAndRefresh(
            splitDraft(
                amount: -10_000,
                splits: [
                    TransactionSplitDraft(id: "only-child", categoryID: "utilities", categoryName: "Utilities", amountMinorUnits: -10_000),
                ]
            ),
            budgetID: "group-1"
        ) {}
        let parentID = try #require(created.changed.transactions.first)
        let parent = try #require(parentTransaction(in: store, id: parentID))
        let child = try #require(parent.subtransactions.first)
        _ = try await store.deleteTransactionAndRefresh(child, budgetID: "group-1") {}
        let collapsed = try #require(parentTransaction(in: store, id: parentID))
        #expect(!collapsed.isParent)
        #expect(collapsed.subtransactions.isEmpty)
        #expect(collapsed.error == nil)
        #expect(collapsed.amount == -10_000)
    }

    @Test func childTransferCreatesPairedRowAndParentIsNotTransfer() async throws {
        let store = try await makeOpenedWritableStore()
        let created = try await store.createTransactionAndRefresh(
            splitDraft(
                amount: -10_000,
                splits: [
                    TransactionSplitDraft(
                        id: "ordinary",
                        categoryID: "groceries",
                        categoryName: "Groceries",
                        amountMinorUnits: -4_000
                    ),
                    TransactionSplitDraft(
                        id: "xfer",
                        categoryID: nil,
                        categoryName: nil,
                        amountMinorUnits: -6_000,
                        payeeID: .value("xfer-savings")
                    ),
                ]
            ),
            budgetID: "group-1"
        ) {}
        let parent = try #require(parentTransaction(in: store, id: created.changed.transactions.first))
        #expect(parent.payee == nil)
        let transferChild = try #require(parent.subtransactions.first { $0.id == "xfer" })
        #expect(transferChild.payee == "xfer-savings")
        let savings = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "savings"))
        let paired = try #require(savings.transactions.first { $0.amount == 6_000 })
        #expect(paired.payeeName == "Checking")
        #expect(parent.amount == -10_000)
    }

    @Test func updatingSiblingNotesDoesNotDuplicateTransferPair() async throws {
        let store = try await makeOpenedWritableStore()
        let created = try await store.createTransactionAndRefresh(
            splitDraft(
                amount: -10_000,
                splits: [
                    TransactionSplitDraft(
                        id: "ordinary",
                        categoryID: "groceries",
                        categoryName: "Groceries",
                        amountMinorUnits: -4_000,
                        notes: .value("ordinary child")
                    ),
                    TransactionSplitDraft(
                        id: "xfer",
                        categoryID: nil,
                        categoryName: nil,
                        amountMinorUnits: -6_000,
                        payeeID: .value("xfer-savings"),
                        notes: .value("transfer child")
                    ),
                ]
            ),
            budgetID: "group-1"
        ) {}
        let parentID = try #require(created.changed.transactions.first)
        func pairedCount() -> Int {
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "savings")?
                .transactions.filter { $0.amount == 6_000 }.count ?? 0
        }
        #expect(pairedCount() == 1)

        _ = try await store.updateTransactionAndRefresh(
            parentID,
            with: splitDraft(
                amount: -10_000,
                splits: [
                    TransactionSplitDraft(
                        id: "ordinary",
                        categoryID: "groceries",
                        categoryName: "Groceries",
                        amountMinorUnits: -4_000,
                        notes: .value("ordinary child plop")
                    ),
                    TransactionSplitDraft(
                        id: "xfer",
                        categoryID: nil,
                        categoryName: nil,
                        amountMinorUnits: -6_000,
                        payeeID: .value("xfer-savings"),
                        notes: .value("transfer child")
                    ),
                ]
            ),
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        #expect(pairedCount() == 1)
        let parent = try #require(parentTransaction(in: store, id: parentID))
        #expect(parent.subtransactions.first { $0.id == "ordinary" }?.notes == "ordinary child plop")
        #expect(parent.subtransactions.first { $0.id == "xfer" }?.notes == "transfer child")
        #expect(parent.subtransactions.first { $0.id == "xfer" }?.payee == "xfer-savings")
    }

    @Test func categorizeChildIsAllowedAndParentStaysUncategorized() async throws {
        let store = try await makeOpenedWritableStore()
        let created = try await store.createTransactionAndRefresh(
            splitDraft(
                amount: -3_000,
                splits: [
                    TransactionSplitDraft(id: "child-a", categoryID: nil, categoryName: nil, amountMinorUnits: -2_000),
                    TransactionSplitDraft(id: "child-b", categoryID: "utilities", categoryName: "Utilities", amountMinorUnits: -1_000),
                ]
            ),
            budgetID: "group-1"
        ) {}
        let parent = try #require(parentTransaction(in: store, id: created.changed.transactions.first))
        let child = try #require(parent.subtransactions.first { $0.id == "child-a" })
        _ = try await store.categorizeTransactionAndRefresh(
            child,
            categoryID: "groceries",
            budgetID: "group-1"
        ) {}
        await #expect(throws: LocalFirstError.unsupportedSplitWrite) {
            _ = try await store.categorizeTransactionAndRefresh(
                parent,
                categoryID: "groceries",
                budgetID: "group-1"
            ) {}
        }
        let updated = try #require(parentTransaction(in: store, id: parent.id))
        #expect(updated.category == nil)
        #expect(updated.subtransactions.first { $0.id == "child-a" }?.category == "groceries")
        #expect(updated.subtransactions.first { $0.id == "child-b" }?.category == "utilities")
    }

    @Test func repairFixesBlankChildPayeeParentCategoryAndNonParentError() async throws {
        let store = try await makeOpenedWritableStore(
            additionalFixtureSQL: """
                ALTER TABLE transactions ADD COLUMN error TEXT;
                ALTER TABLE transactions ADD COLUMN reconciled INTEGER;
                ALTER TABLE transactions ADD COLUMN sort_order REAL;
                INSERT INTO transactions (
                    id, acct, date, amount, category, description, notes, cleared, tombstone,
                    parent_id, is_parent, isChild, error, sort_order, reconciled
                ) VALUES
                ('s07', 'checking', 20260807, -10000, 'groceries', 'coffee', 'parent', 1, 0, NULL, 1, 0,
                 '{"type":"SplitTransactionError","version":1,"difference":-1000}', -1, 0),
                ('s07-a', 'checking', 20260807, -4000, 'groceries', NULL, 'child a', 0, 0, 's07', 0, 1, NULL, -1, 0),
                ('s07-b', 'checking', 20260807, -5000, 'utilities', 'coffee', 'child b', 1, 0, 's07', 0, 1,
                 '{"type":"SplitTransactionError","version":1,"difference":9}', -2, 0),
                ('orphan', 'checking', 20260807, -1000, 'groceries', 'coffee', 'orphan', 0, 0, 'missing', 0, 1, NULL, -1, 0);
                """
        )
        let result = try await store.repairSplitTransactionsAndRefresh(budgetID: "group-1")
        #expect(result.blankPayeeCount == 1)
        #expect(result.clearedCount == 1)
        #expect(result.deletedCount == 1)
        #expect(result.nonParentErrorsFixedCount == 1)
        #expect(result.parentCategoriesFixedCount == 1)
        #expect(result.mismatchedParentIDs == ["s07"])
        let parent = try #require(parentTransaction(in: store, id: "s07"))
        #expect(parent.category == nil)
        #expect(parent.subtransactions.first { $0.id == "s07-a" }?.payee == "coffee")
        #expect(parent.subtransactions.first { $0.id == "s07-a" }?.cleared?.boolValue == true)
        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        #expect(!checking.transactions.contains { $0.id == "orphan" })
        #expect(!checking.transactions.contains { transaction in
            transaction.subtransactions.contains { $0.id == "orphan" }
        })
    }

    func splitDraft(
        amount: Int,
        splits: [TransactionSplitDraft]
    ) -> TransactionDraft {
        TransactionDraft(
            accountID: "checking",
            date: {
                var components = DateComponents()
                components.calendar = Calendar(identifier: .gregorian)
                components.timeZone = TimeZone(secondsFromGMT: 0)
                components.year = 2026
                components.month = 7
                components.day = 13
                components.hour = 12
                return components.date ?? Date()
            }(),
            amountMinorUnits: amount,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: "parent note",
            cleared: true,
            isTransfer: false,
            splits: splits
        )
    }

    func parentTransaction(in store: LocalFirstActualStore, id: String?) -> ActualTransaction? {
        store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
            .transactions.first { $0.id == id }
    }
}
