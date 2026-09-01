import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func createTransactionLocallyWithExistingPayeeRefreshesCaches() async throws {
        let store = try await makeOpenedWritableStore()
        var didCreate = false
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 8),
            amountMinorUnits: -450,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: "morning",
            cleared: true,
            isTransfer: false
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {
            didCreate = true
        }

        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let created = try #require(loaded.transactions.first { $0.id == result.changed.transactions.first })
        #expect(didCreate)
        #expect(result.ok)
        #expect(result.changed.accounts == ["checking"])
        #expect(result.changed.months == ["2026-07"])
        #expect(created.amount == -450)
        #expect(created.payee == "coffee")
        #expect(created.payeeName == "Coffee Shop")
        #expect(created.category == "groceries")
        #expect(created.notes == "morning")
        #expect(created.cleared == .bool(true))
        #expect(loaded.balance == -12_795)
    }

    @Test func createTransactionLocallyCreatesTypedNewPayee() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 9),
            amountMinorUnits: -725,
            payeeID: nil,
            payeeName: "New Cafe",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let created = try #require(loaded.transactions.first { $0.id == result.changed.transactions.first })
        let options = try await store.editorOptions(budgetID: "group-1", month: "2026-07")
        let newPayee = try #require(options.payees.first { $0.name == "New Cafe" })
        #expect(created.payee == newPayee.id)
        #expect(created.payeeName == "New Cafe")
        #expect(created.category == nil)
        #expect(created.cleared == .bool(false))
        #expect(loaded.payeeNames[newPayee.id ?? ""] == "New Cafe")
    }

    @Test func createTransactionLocallyReusesTypedPayeeNameCaseInsensitively() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 10),
            amountMinorUnits: -900,
            payeeID: nil,
            payeeName: "coffee shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let created = try #require(loaded.transactions.first { $0.id == result.changed.transactions.first })
        let options = try await store.editorOptions(budgetID: "group-1", month: "2026-07")
        #expect(created.payee == "coffee")
        #expect(created.payeeName == "Coffee Shop")
        #expect(options.payees.filter { $0.name.caseInsensitiveCompare("coffee shop") == .orderedSame }.count == 1)
    }

    @Test func categorizeTransactionLocallyRefreshesCachesAndUncategorizedList() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 11),
            amountMinorUnits: -725,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let createResult = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let uncategorizedBefore = try await store.uncategorizedTransactions(budgetID: "group-1", month: "2026-07")
        let transactionID = try #require(createResult.changed.transactions.first)
        let transaction = try #require(uncategorizedBefore.transactions.first { $0.id == transactionID })
        var didUpdate = false

        let categorizeResult = try await store.categorizeTransactionAndRefresh(
            transaction,
            categoryID: "groceries",
            budgetID: "group-1"
        ) {
            didUpdate = true
        }

        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let categorized = try #require(loaded.transactions.first { $0.id == transactionID })
        let uncategorizedAfter = try await store.uncategorizedTransactions(budgetID: "group-1", month: "2026-07")
        let month = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(month.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(didUpdate)
        #expect(categorizeResult.ok)
        #expect(categorizeResult.changed.accounts == ["checking"])
        #expect(categorizeResult.changed.months == ["2026-07"])
        #expect(categorizeResult.changed.transactions == [transactionID])
        #expect(categorized.category == "groceries")
        #expect(!uncategorizedAfter.transactions.contains { $0.id == transactionID })
        #expect(groceries.spent == -13_070)
    }

    @Test func categorizeTransactionsAtomicallyRefreshesAllAffectedCaches() async throws {
        let store = try await makeOpenedWritableStore()
        let monthBefore = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceriesBefore = try #require(
            monthBefore.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        let drafts = [
            TransactionDraft(
                accountID: "checking",
                date: try makeDate(year: 2026, month: 7, day: 12),
                amountMinorUnits: -725,
                payeeID: "coffee",
                payeeName: "Coffee Shop",
                categoryID: nil,
                notes: nil,
                cleared: false,
                isTransfer: false
            ),
            TransactionDraft(
                accountID: "credit",
                date: try makeDate(year: 2026, month: 7, day: 13),
                amountMinorUnits: -1_275,
                payeeID: "coffee",
                payeeName: "Coffee Shop",
                categoryID: nil,
                notes: nil,
                cleared: false,
                isTransfer: false
            )
        ]
        var createdIDs: [String] = []
        for draft in drafts {
            let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
            createdIDs += result.changed.transactions
        }
        let uncategorized = try await store.uncategorizedTransactions(
            budgetID: "group-1",
            month: "2026-07"
        )
        let selected = uncategorized.transactions.filter { createdIDs.contains($0.rowID) }
        var didUpdateCount = 0

        let result = try await store.categorizeTransactionsAndRefresh(
            selected,
            categoryID: "groceries",
            budgetID: "group-1"
        ) {
            didUpdateCount += 1
        }

        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let credit = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let uncategorizedAfter = try await store.uncategorizedTransactions(
            budgetID: "group-1",
            month: "2026-07"
        )
        let monthAfter = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceriesAfter = try #require(
            monthAfter.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )

        #expect(didUpdateCount == 1)
        #expect(result.ok)
        #expect(result.changed.accounts == ["checking", "credit"])
        #expect(result.changed.months == ["2026-07"])
        #expect(result.changed.transactions == createdIDs.sorted())
        #expect(checking.transactions.first { createdIDs.contains($0.rowID) }?.category == "groceries")
        #expect(credit.transactions.first { createdIDs.contains($0.rowID) }?.category == "groceries")
        #expect(!uncategorizedAfter.transactions.contains { createdIDs.contains($0.rowID) })
        #expect(groceriesAfter.spent == groceriesBefore.spent - 2_000)
    }

    @Test func quickCategorizationSupportsCrossBudgetTransfersInBothDirections() async throws {
        let store = try await makeOpenedWritableStore()
        let outgoing = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 14),
            amountMinorUnits: -2_500,
            payeeID: "xfer-tracking",
            payeeName: "Tracking",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        let incoming = TransactionDraft(
            accountID: "tracking",
            date: try makeDate(year: 2026, month: 7, day: 15),
            amountMinorUnits: -3_500,
            payeeID: "xfer-checking",
            payeeName: "Checking",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        _ = try await store.createTransactionAndRefresh(outgoing, budgetID: "group-1") {}
        _ = try await store.createTransactionAndRefresh(incoming, budgetID: "group-1") {}
        let uncategorized = try await store.uncategorizedTransactions(
            budgetID: "group-1",
            month: "2026-07"
        )
        let transferRows = uncategorized.transactions.filter { $0.payee == "xfer-tracking" }
        let outgoingBudgetRow = try #require(
            transferRows.first { $0.account == "checking" && $0.amount == -2_500 }
        )
        let incomingBudgetRow = try #require(
            transferRows.first { $0.account == "checking" && $0.amount == 3_500 }
        )

        _ = try await store.categorizeTransactionsAndRefresh(
            [outgoingBudgetRow, incomingBudgetRow],
            categoryID: "groceries",
            budgetID: "group-1"
        ) {}

        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        #expect(checking.transactions.first { $0.rowID == outgoingBudgetRow.rowID }?.category == "groceries")
        #expect(checking.transactions.first { $0.rowID == incomingBudgetRow.rowID }?.category == "groceries")
    }

    @Test func bulkCategorizationAppliesNothingWhenAnySelectionIsUnsupported() async throws {
        let store = try await makeOpenedWritableStore()
        let regularDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 16),
            amountMinorUnits: -800,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let transferDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 16),
            amountMinorUnits: -1_800,
            payeeID: "xfer-credit",
            payeeName: "Credit",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        let regularResult = try await store.createTransactionAndRefresh(
            regularDraft,
            budgetID: "group-1"
        ) {}
        _ = try await store.createTransactionAndRefresh(transferDraft, budgetID: "group-1") {}
        let regularID = try #require(regularResult.changed.transactions.first)
        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let regular = try #require(checking.transactions.first { $0.rowID == regularID })
        let sameBudgetTransfer = try #require(
            checking.transactions.first { $0.payee == "xfer-credit" && $0.amount == -1_800 }
        )

        await #expect(throws: LocalFirstError.self) {
            _ = try await store.categorizeTransactionsAndRefresh(
                [regular, sameBudgetTransfer],
                categoryID: "groceries",
                budgetID: "group-1"
            ) {}
        }

        let uncategorizedAfter = try await store.uncategorizedTransactions(
            budgetID: "group-1",
            month: "2026-07"
        )
        #expect(uncategorizedAfter.transactions.contains { $0.rowID == regularID })
    }

    @Test func uncategorizedListIncludesSplitChildrenAndCategorizesOnlyTheChild() async throws {
        let store = try await makeOpenedWritableStore(
            additionalFixtureSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild, notes)
                VALUES ('s03-parent', 'checking', 20260712, -6000, NULL, 0, NULL, 1, 0, 'S03');
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild, notes)
                VALUES ('s03-a', 'checking', 20260712, -3000, 'groceries', 0, 's03-parent', 0, 1, 'Child A');
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, isChild, notes)
                VALUES ('s03-uncat', 'checking', 20260712, -3000, NULL, 0, 's03-parent', 0, 1, 'Q01-CHILD-NOTE');
            """
        )

        let before = try await store.uncategorizedTransactions(budgetID: "group-1", month: "2026-07")
        #expect(before.transactions.contains { $0.id == "s03-uncat" })
        #expect(!before.transactions.contains { $0.id == "s03-parent" })
        #expect(!before.transactions.contains { $0.id == "s03-a" })
        let child = try #require(before.transactions.first { $0.id == "s03-uncat" })
        #expect(child.isChild)
        #expect(child.parentID == "s03-parent")

        _ = try await store.categorizeTransactionAndRefresh(
            child,
            categoryID: "utilities",
            budgetID: "group-1"
        ) {}

        let after = try await store.uncategorizedTransactions(budgetID: "group-1", month: "2026-07")
        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let parent = try #require(loaded.transactions.first { $0.id == "s03-parent" })
        #expect(!after.transactions.contains { $0.id == "s03-uncat" })
        #expect(parent.isParent)
        #expect(parent.subtransactions.first { $0.id == "s03-uncat" }?.category == "utilities")
        #expect(parent.subtransactions.first { $0.id == "s03-a" }?.category == "groceries")
        #expect(parent.subtransactions.first { $0.id == "s03-uncat" }?.notes == "Q01-CHILD-NOTE")
    }
}
