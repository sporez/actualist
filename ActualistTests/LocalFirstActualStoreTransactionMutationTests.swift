import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func updateSimpleTransactionLocallyRefreshesMovedAccountMonthAndPayeeOptions() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 11),
            amountMinorUnits: -725,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: "old note",
            cleared: false,
            isTransfer: false
        )
        let createResult = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let transactionID = try #require(createResult.changed.transactions.first)
        let updateDraft = TransactionDraft(
            accountID: "credit",
            date: try makeDate(year: 2026, month: 8, day: 2),
            amountMinorUnits: 425,
            payeeID: nil,
            payeeName: "Edited Payee",
            categoryID: nil,
            notes: "updated note",
            cleared: true,
            isTransfer: false
        )
        var didUpdate = false

        let updateResult = try await store.updateTransactionAndRefresh(
            transactionID,
            with: updateDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {
            didUpdate = true
        }

        let oldAccount = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let newAccount = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let updated = try #require(newAccount.transactions.first { $0.id == transactionID })
        let options = try await store.editorOptions(budgetID: "group-1", month: "2026-08")

        #expect(didUpdate)
        #expect(updateResult.ok)
        #expect(Set(updateResult.changed.accounts) == Set(["checking", "credit"]))
        #expect(Set(updateResult.changed.months) == Set(["2026-07", "2026-08"]))
        #expect(updateResult.changed.transactions == [transactionID])
        #expect(!oldAccount.transactions.contains { $0.id == transactionID })
        #expect(updated.account == "credit")
        #expect(updated.date == "2026-08-02")
        #expect(updated.amount == 425)
        #expect(updated.payeeName == "Edited Payee")
        #expect(updated.category == nil)
        #expect(updated.notes == "updated note")
        #expect(updated.cleared?.boolValue == true)
        #expect(options.payees.contains { $0.name == "Edited Payee" })
    }

    @Test func deleteSimpleTransactionLocallyTombstonesAndRefreshesCaches() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 11),
            amountMinorUnits: -725,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let createResult = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let transactionID = try #require(createResult.changed.transactions.first)
        let created = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        let monthBeforeDelete = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceriesBeforeDelete = try #require(
            monthBeforeDelete.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceriesBeforeDelete.spent == -13_070)
        var didDelete = false

        let deleteResult = try await store.deleteTransactionAndRefresh(
            created,
            budgetID: "group-1"
        ) {
            didDelete = true
        }

        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let month = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(month.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(didDelete)
        #expect(deleteResult.ok)
        #expect(deleteResult.changed.accounts == ["checking"])
        #expect(deleteResult.changed.months == ["2026-07"])
        #expect(deleteResult.changed.transactions == [transactionID])
        #expect(!loaded.transactions.contains { $0.id == transactionID })
        #expect(groceries.spent == -12_345)
    }

    @Test func createTransferLocallyWritesPairedRowsAcrossAccounts() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-credit",
            payeeName: "",
            categoryID: nil,
            notes: "move to card",
            cleared: false,
            isTransfer: true
        )
        var didCreate = false

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {
            didCreate = true
        }

        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let credit = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let source = try #require(checking.transactions.first { $0.id == result.changed.transactions.first })
        let paired = try #require(credit.transactions.first { $0.amount == 1000 })

        #expect(didCreate)
        #expect(result.ok)
        #expect(Set(result.changed.accounts) == Set(["checking", "credit"]))
        #expect(source.amount == -1000)
        #expect(source.category == nil)
        #expect(source.payeeName == "Credit Card")
        #expect(paired.amount == 1000)
        #expect(paired.category == nil)
        #expect(paired.payeeName == "Checking")
        #expect(paired.account == "credit")
    }

    @Test func createCrossBudgetTransferKeepsCategoryOnOnBudgetSide() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-tracking",
            payeeName: "",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: true
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == result.changed.transactions.first }
        )
        let tracking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "tracking"))
        let paired = try #require(tracking.transactions.first { $0.amount == 1000 })

        #expect(source.category == "groceries")
        #expect(paired.category == nil)
    }

    @Test func createReverseCrossBudgetTransferPutsCategoryOnOnBudgetPair() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "tracking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-checking",
            payeeName: "",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: true
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "tracking")?
                .transactions.first { $0.id == result.changed.transactions.first }
        )
        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let paired = try #require(
            checking.transactions.first {
                $0.amount == 1000 && $0.payeeName == "Tracking"
            }
        )

        #expect(source.category == nil)
        #expect(paired.category == "groceries")
    }

    @Test func createSameBudgetTransferClearsCategoryEvenIfProvided() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-credit",
            payeeName: "",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: true
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == result.changed.transactions.first }
        )
        #expect(source.category == nil)
    }

    @Test func editSimpleToCrossBudgetTransferKeepsCategory() async throws {
        let store = try await makeOpenedWritableStore()
        let simpleDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let created = try await store.createTransactionAndRefresh(simpleDraft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)

        let transferDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-tracking",
            payeeName: "",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: transferDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        #expect(source.category == "groceries")
    }

    @Test func editOffBudgetSimpleToCrossBudgetTransferCategorizesOnBudgetPair() async throws {
        let store = try await makeOpenedWritableStore()
        let simpleDraft = TransactionDraft(
            accountID: "tracking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let created = try await store.createTransactionAndRefresh(simpleDraft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)

        let transferDraft = TransactionDraft(
            accountID: "tracking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-checking",
            payeeName: "",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: transferDraft,
            budgetID: "group-1",
            originalAccountID: "tracking",
            originalMonth: "2026-07"
        ) {}

        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "tracking")?
                .transactions.first { $0.id == transactionID }
        )
        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let paired = try #require(
            checking.transactions.first {
                $0.amount == 1000 && $0.payeeName == "Tracking"
            }
        )

        #expect(source.category == nil)
        #expect(paired.category == "groceries")
    }

    @Test func createSplitLocallyWritesParentAndChildren() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 13),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -2000),
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1000)
            ]
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let parent = try #require(checking.transactions.first { $0.id == result.changed.transactions.first })
        let month = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(month.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(result.ok)
        #expect(parent.isParent)
        #expect(parent.category == nil)
        #expect(parent.amount == -3000)
        #expect(parent.subtransactions.count == 2)
        #expect(parent.subtransactions.allSatisfy { $0.category == "groceries" })
        #expect(parent.subtransactions.reduce(0) { $0 + ($1.amount ?? 0) } == -3000)
        #expect(groceries.spent == -15_345)
    }

    @Test func createSplitLocallyPersistsAmountMismatchError() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 13),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -2000),
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -500)
            ]
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let parent = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == result.changed.transactions.first }
        )
        #expect(parent.error?.type == "SplitTransactionError")
        #expect(parent.error?.version == 1)
        #expect(parent.error?.difference == -500)
        #expect(parent.subtransactions.count == 2)
    }

    @Test func editSplitLocallyUpdatesAddsAndRemovesChildren() async throws {
        let store = try await makeOpenedWritableStore()
        let createDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 13),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -2000),
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1000)
            ]
        )
        let created = try await store.createTransactionAndRefresh(createDraft, budgetID: "group-1") {}
        let parentID = try #require(created.changed.transactions.first)
        let parent = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == parentID }
        )
        let keptChildID = try #require(parent.subtransactions.first?.id)
        let removedChildID = try #require(parent.subtransactions.last?.id)

        let updateDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 13),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: keptChildID, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1500),
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1500)
            ]
        )

        _ = try await store.updateTransactionAndRefresh(
            parentID,
            with: updateDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let updatedParent = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == parentID }
        )
        let month = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(month.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(updatedParent.subtransactions.count == 2)
        #expect(!updatedParent.subtransactions.contains { $0.id == removedChildID })
        #expect(updatedParent.subtransactions.contains { $0.id == keptChildID })
        #expect(updatedParent.subtransactions.reduce(0) { $0 + ($1.amount ?? 0) } == -3000)
        #expect(groceries.spent == -15_345)
    }

    @Test func editSimpleToTransferAndBackTogglesPairedRow() async throws {
        let store = try await makeOpenedWritableStore()
        let simpleDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let created = try await store.createTransactionAndRefresh(simpleDraft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)

        let transferDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-credit",
            payeeName: "",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: transferDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let creditAfterTransfer = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let paired = try #require(creditAfterTransfer.transactions.first { $0.amount == 1000 })
        let sourceAfterTransfer = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        #expect(sourceAfterTransfer.category == nil)
        #expect(paired.payeeName == "Checking")

        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: simpleDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let creditAfterRevert = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let sourceAfterRevert = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        #expect(!creditAfterRevert.transactions.contains { $0.id == paired.id })
        #expect(sourceAfterRevert.category == "groceries")
    }

    @Test func editTransferLocallyRepointsPairedAmountAndDestination() async throws {
        let store = try await makeOpenedWritableStore()
        let createDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-credit",
            payeeName: "",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        let created = try await store.createTransactionAndRefresh(createDraft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)

        let editDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -2500,
            payeeID: "xfer-savings",
            payeeName: "",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: editDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let credit = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let savings = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "savings"))
        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        let paired = try #require(savings.transactions.first { $0.amount == 2500 })

        #expect(source.amount == -2500)
        #expect(credit.transactions.isEmpty)
        #expect(paired.account == "savings")
        #expect(paired.payeeName == "Checking")
    }

    @Test func editSimpleToSplitAndBackTogglesChildren() async throws {
        let store = try await makeOpenedWritableStore()
        let simpleDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 14),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let created = try await store.createTransactionAndRefresh(simpleDraft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)

        let splitDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 14),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -2000),
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1000)
            ]
        )
        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: splitDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let asSplit = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        #expect(asSplit.isParent)
        #expect(asSplit.category == nil)
        #expect(asSplit.subtransactions.count == 2)

        let database = try #require(store.database)
        let splitMessages = try await database.pendingLocalSyncMessages().map(\.message)
        func latestValue(
            in messages: [ActualSyncDecodedMessage],
            rowID: String,
            column: String
        ) -> String? {
            messages.last {
                $0.dataset == "transactions" && $0.row == rowID && $0.column == column
            }?.serializedValue
        }
        #expect(
            latestValue(in: splitMessages, rowID: transactionID, column: "is_parent")
                == LocalFirstSyncValue.bool(true).serialized
        )
        for child in asSplit.subtransactions {
            let childID = try #require(child.id)
            #expect(
                latestValue(in: splitMessages, rowID: childID, column: "isChild")
                    == LocalFirstSyncValue.bool(true).serialized
            )
            #expect(
                latestValue(in: splitMessages, rowID: childID, column: "parent_id")
                    == LocalFirstSyncValue.string(transactionID).serialized
            )
            #expect(
                latestValue(in: splitMessages, rowID: childID, column: "acct")
                    == LocalFirstSyncValue.string("checking").serialized
            )
            #expect(
                latestValue(in: splitMessages, rowID: childID, column: "date")
                    == LocalFirstSyncValue.int(20_260_714).serialized
            )
        }

        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: simpleDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let asSimple = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        #expect(!asSimple.isParent)
        #expect(asSimple.subtransactions.isEmpty)
        #expect(asSimple.category == "groceries")

        let simpleMessages = try await database.pendingLocalSyncMessages().map(\.message)
        #expect(
            latestValue(in: simpleMessages, rowID: transactionID, column: "is_parent")
                == LocalFirstSyncValue.bool(false).serialized
        )
    }

    @Test func deleteSplitParentLocallyTombstonesParentAndChildren() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 13),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -2000),
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1000)
            ]
        )
        let created = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let parentID = try #require(created.changed.transactions.first)
        let parent = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == parentID }
        )

        let result = try await store.deleteTransactionAndRefresh(parent, budgetID: "group-1") {}

        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let month = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(month.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(result.ok)
        #expect(!checking.transactions.contains { $0.id == parentID })
        #expect(result.changed.transactions.count == 3)
        #expect(groceries.spent == -12_345)
    }

    @Test func deleteTransferLocallyTombstonesBothSides() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-credit",
            payeeName: "",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        let created = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)
        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit")?.transactions.isEmpty == false)

        let result = try await store.deleteTransactionAndRefresh(source, budgetID: "group-1") {}

        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let credit = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))

        #expect(result.ok)
        #expect(Set(result.changed.accounts) == Set(["checking", "credit"]))
        #expect(!checking.transactions.contains { $0.id == transactionID })
        #expect(credit.transactions.isEmpty)
    }

}
