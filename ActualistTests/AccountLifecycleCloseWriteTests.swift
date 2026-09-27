import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountLifecycleCloseWriteTests {
    private let support = LocalFirstActualStoreTests()

    @Test func emptyAccountDeleteAndZeroBalanceCloseEmitOnlyPinnedAccountCells() async throws {
        let empty = try makeDatabase(extraSQL: "DELETE FROM transactions WHERE id = 'txn';")
        let emptyReview = try await empty.accountLifecycleReview(
            request: closeRequest(destination: nil, category: nil),
            localDay: testDay
        )
        let emptyResult = try await empty.commitAccountLifecycleReview(
            emptyReview,
            localDay: { self.testDay }
        )
        guard case .applied(let emptyOutcome) = emptyResult else {
            Issue.record("Expected empty account deletion")
            return
        }
        #expect(emptyOutcome.operation == .delete)
        #expect(try await empty.pendingLocalSyncMessages().map(\.message).map(\.cell) == [
            "accounts|checking|tombstone|N:1"
        ])
        let emptyAction = try #require(try await empty.recentBudgetActions().first)
        guard case .account(let emptySummary) = emptyAction.summary else {
            Issue.record("Expected account History metadata")
            return
        }
        #expect(emptySummary.operation == .delete)

        let zero = try makeDatabase(extraSQL: "UPDATE transactions SET amount = 0 WHERE id = 'txn';")
        let zeroReview = try await zero.accountLifecycleReview(
            request: closeRequest(destination: nil, category: nil),
            localDay: testDay
        )
        let zeroResult = try await zero.commitAccountLifecycleReview(
            zeroReview,
            localDay: { self.testDay }
        )
        guard case .applied(let zeroOutcome) = zeroResult else {
            Issue.record("Expected zero-balance close")
            return
        }
        #expect(zeroOutcome.operation == .close)
        #expect(zeroOutcome.account.isClosed)
        #expect(try await zero.pendingLocalSyncMessages().map(\.message).map(\.cell) == [
            "accounts|checking|closed|N:1"
        ])
    }

    @Test func nonzeroCloseBuildsSignedPairedTransferWithPinnedDefaultsAndCategoryDirection() async throws {
        let database = try makeDatabase(extraSQL: """
            UPDATE accounts SET offbudget = 0 WHERE id = 'checking';
            UPDATE accounts SET offbudget = 1 WHERE id = 'destination';
            UPDATE transactions SET amount = 4250, category = NULL WHERE id = 'txn';
            """)
        let review = try await database.accountLifecycleReview(
            request: closeRequest(destination: "destination", category: "groceries"),
            localDay: testDay
        )

        let result = try await database.commitAccountLifecycleReview(
            review,
            now: fixedNow,
            localDay: { self.testDay },
            transferIDs: AccountClosingTransferIDs(source: "closing-source", destination: "closing-destination")
        )

        guard case .applied(let outcome) = result else {
            Issue.record("Expected nonzero close")
            return
        }
        #expect(outcome.operation == .close)
        let messages = try await database.pendingLocalSyncMessages().map(\.message)
        #expect(messages.contains(cell: "accounts|checking|closed|N:1"))
        #expect(messages.contains(cell: "transactions|closing-source|acct|S:checking"))
        #expect(messages.contains(cell: "transactions|closing-source|amount|N:-4250"))
        #expect(messages.contains(cell: "transactions|closing-source|description|S:transfer-destination"))
        #expect(messages.contains(cell: "transactions|closing-source|category|S:groceries"))
        #expect(messages.contains(cell: "transactions|closing-source|date|N:20260927"))
        #expect(messages.contains(cell: "transactions|closing-source|notes|S:Closing account"))
        #expect(messages.contains(cell: "transactions|closing-source|cleared|N:1"))
        #expect(messages.contains(cell: "transactions|closing-source|reconciled|N:0"))
        #expect(messages.contains(cell: "transactions|closing-source|sort_order|N:1790510400000.0"))
        #expect(messages.contains(cell: "transactions|closing-source|transferred_id|S:closing-destination"))
        #expect(messages.contains(cell: "transactions|closing-destination|acct|S:destination"))
        #expect(messages.contains(cell: "transactions|closing-destination|amount|N:4250"))
        #expect(messages.contains(cell: "transactions|closing-destination|description|S:transfer-checking"))
        #expect(messages.contains(cell: "transactions|closing-destination|category|0:"))
        #expect(messages.contains(cell: "transactions|closing-destination|date|N:20260927"))
        #expect(messages.contains(cell: "transactions|closing-destination|notes|S:Closing account"))
        #expect(messages.contains(cell: "transactions|closing-destination|cleared|N:0"))
        #expect(messages.contains(cell: "transactions|closing-destination|reconciled|N:0"))
        #expect(messages.contains(cell: "transactions|closing-destination|sort_order|N:1790510400000.0"))
        #expect(messages.contains(cell: "transactions|closing-destination|transferred_id|S:closing-source"))
    }

    @Test func simpleFINCloseClearsSevenCellsPreservesLastSyncAndUsesOneCommit() async throws {
        let database = try makeDatabase(extraSQL: """
            UPDATE transactions SET amount = 0 WHERE id = 'txn';
            ALTER TABLE accounts ADD COLUMN account_id TEXT;
            ALTER TABLE accounts ADD COLUMN account_sync_source TEXT;
            ALTER TABLE accounts ADD COLUMN bank TEXT;
            ALTER TABLE accounts ADD COLUMN balance_current INTEGER;
            ALTER TABLE accounts ADD COLUMN balance_available INTEGER;
            ALTER TABLE accounts ADD COLUMN balance_limit INTEGER;
            ALTER TABLE accounts ADD COLUMN bank_sync_status TEXT;
            ALTER TABLE accounts ADD COLUMN last_sync TEXT;
            UPDATE accounts
            SET account_id = 'remote', account_sync_source = 'simpleFin', bank = 'bank',
                balance_current = 1, balance_available = 2, balance_limit = 3,
                bank_sync_status = 'ok', last_sync = 'synthetic-last-sync'
            WHERE id = 'checking';
            """)
        let review = try await database.accountLifecycleReview(
            request: closeRequest(destination: nil, category: nil),
            localDay: testDay
        )

        _ = try await database.commitAccountLifecycleReview(
            review,
            localDay: { self.testDay }
        )

        let messages = try await database.pendingLocalSyncMessages().map(\.message)
        let accountColumns = messages
            .filter { $0.dataset == "accounts" && $0.row == "checking" }
            .map(\.column)
        #expect(accountColumns == [
            "account_id", "bank", "balance_current", "balance_available", "balance_limit",
            "account_sync_source", "bank_sync_status", "closed",
        ])
        #expect(!messages.contains { $0.column == "last_sync" })
        #expect(try await database.recentBudgetActions().count == 1)
    }

    @Test func localMidnightRolloverReturnsFreshReviewWithoutClockOutboxOrHistoryMutation() async throws {
        let database = try makeDatabase()
        let reviewed = try await database.accountLifecycleReview(
            request: closeRequest(destination: "destination", category: nil),
            localDay: testDay
        )
        let clockBefore = await database.localClock
        let nextDay = AccountLifecycleDay(isoDate: "2026-09-28", transactionDate: 20260928)

        let result = try await database.commitAccountLifecycleReview(
            reviewed,
            localDay: { nextDay }
        )

        guard case .reviewChanged(let fresh) = result else {
            Issue.record("Expected local-day freshness replacement")
            return
        }
        #expect(fresh.identity.localDay == nextDay)
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try await database.recentBudgetActions().isEmpty)
        #expect(await database.localClock == clockBefore)
    }

    @Test func missingOrDuplicateTransferPayeeRollsBackTheEntireClose() async throws {
        let database = try makeDatabase(extraSQL: """
            INSERT INTO payees VALUES ('duplicate-destination', '', 'destination', 0);
            """)
        let review = try await database.accountLifecycleReview(
            request: closeRequest(destination: "destination", category: nil),
            localDay: testDay
        )
        let clockBefore = await database.localClock

        await #expect(throws: LocalFirstError.self) {
            try await database.commitAccountLifecycleReview(
                review,
                localDay: { self.testDay }
            )
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try await database.recentBudgetActions().isEmpty)
        #expect(await database.localClock == clockBefore)
    }

    @Test func historyFailureRollsBackCloseAccountCellOutboxAndClock() async throws {
        let database = try makeDatabase(extraSQL: "UPDATE transactions SET amount = 0 WHERE id = 'txn';")
        _ = try await database.commitAccountLifecycleMutation(
            .rename(AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: "Daily Spending"
            )),
            actionID: "duplicate-action"
        )
        let review = try await database.accountLifecycleReview(
            request: closeRequest(destination: nil, category: nil),
            localDay: testDay
        )
        let messagesBefore = try await database.pendingLocalSyncMessageCount()
        let clockBefore = await database.localClock

        await #expect(throws: LocalFirstError.invalidLocalWrite(
            "the database transaction was rolled back"
        )) {
            try await database.commitAccountLifecycleReview(
                review,
                actionID: "duplicate-action",
                localDay: { self.testDay }
            )
        }

        #expect(try await database.pendingLocalSyncMessageCount() == messagesBefore)
        #expect(try await database.recentBudgetActions().count == 1)
        #expect(try await database.fetchAccounts().first { $0.id == "checking" }?.closed == false)
        #expect(await database.localClock == clockBefore)
    }

    private func makeDatabase(extraSQL: String = "") throws -> BudgetDatabase {
        try BudgetDatabase(
            databaseURL: support.makeSQLiteFixture(extraSQL: """
                ALTER TABLE transactions ADD COLUMN description TEXT;
                ALTER TABLE transactions ADD COLUMN notes TEXT;
                ALTER TABLE transactions ADD COLUMN isChild INTEGER;
                ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
                ALTER TABLE transactions ADD COLUMN cleared INTEGER;
                INSERT INTO accounts VALUES ('destination', 'Destination', 0, 0, 0, 2);
                CREATE TABLE payees (
                    id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER
                );
                INSERT INTO payees VALUES ('transfer-checking', '', 'checking', 0);
                INSERT INTO payees VALUES ('transfer-destination', '', 'destination', 0);
                \(extraSQL)
                """),
            localNodeID: "account-close-tests"
        )
    }

    private func closeRequest(
        destination: String?,
        category: String?
    ) -> AccountLifecycleReviewRequest {
        AccountLifecycleReviewRequest(
            budgetID: "budget",
            accountID: "checking",
            requestedAction: .close(
                destinationAccountID: destination,
                categoryID: category
            )
        )
    }

    private var testDay: AccountLifecycleDay {
        AccountLifecycleDay(isoDate: "2026-09-27", transactionDate: 20260927)
    }

    private var fixedNow: Date {
        Date(timeIntervalSince1970: 1_790_510_400)
    }
}

private extension ActualSyncDecodedMessage {
    var cell: String {
        [dataset, row, column, serializedValue].joined(separator: "|")
    }
}

private extension Array where Element == ActualSyncDecodedMessage {
    func contains(cell: String) -> Bool {
        contains { $0.cell == cell }
    }
}
