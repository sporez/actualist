import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actualist

@MainActor
struct AccountLifecycleAtomicCommitTests {
    private let support = LocalFirstActualStoreTests()

    @Test func normalizedRenameCommitsOnlyNameCellAndRecordsRenameHistory() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE accounts ADD COLUMN account_group_id TEXT;
            UPDATE accounts
            SET offbudget = 1, closed = 1, sort_order = 42, account_group_id = 'cash-group'
            WHERE id = 'checking';
            """)
        let revisions = MutationCounter()
        let database = try makeDatabase(at: url, revisions: revisions)
        let before = try databaseState(at: url)

        let result = try await database.commitAccountLifecycleMutation(
            .rename(AccountRenameCommand(
                accountID: " checking ",
                expectedCurrentName: "Checking",
                newName: " Daily Spending "
            )),
            actionID: "rename-action",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        guard case .applied(let outcome) = result else {
            Issue.record("Expected an applied rename")
            return
        }
        #expect(outcome.operation == .rename)
        #expect(outcome.account == AccountLifecycleAccount(
            id: "checking",
            name: "Daily Spending",
            offBudget: true,
            isClosed: true,
            accountGroupID: "cash-group"
        ))

        let after = try databaseState(at: url)
        #expect(after.account == AccountState(
            id: "checking",
            name: "Daily Spending",
            offBudget: 1,
            closed: 1,
            tombstone: 0,
            sortOrder: 42,
            accountGroupID: "cash-group",
            bankSyncStatus: nil
        ))
        #expect(before.account?.name == "Checking")
        #expect(after.messages.count == before.messages.count + 1)
        let message = try #require(after.messages.last)
        #expect(message.dataset == "accounts")
        #expect(message.row == "checking")
        #expect(message.column == "name")
        #expect(message.value == "S:Daily Spending")
        #expect(after.outbox?.count == 1)
        #expect(after.outbox?.first?.cell == message.cell)
        #expect(revisions.count == 1)

        let record = try #require(try await database.recentBudgetActions().first)
        let payload = AccountBudgetAction(
            name: "Daily Spending",
            offbudget: true,
            operation: .rename
        )
        #expect(record.id == "rename-action")
        #expect(record.kind == .account)
        #expect(record.source == .ui)
        #expect(record.summary == .account(payload))
        #expect(record.inverse == .account(payload))
    }

    @Test func reopenCommitsOnlyClosedCellAndPreservesOtherAccountFacts() async throws {
        let url = try support.makeSQLiteFixture(extraSQL: """
            ALTER TABLE accounts ADD COLUMN account_group_id TEXT;
            UPDATE accounts
            SET name = 'Daily Spending', offbudget = 1, closed = 1,
                sort_order = 17, account_group_id = 'cash-group'
            WHERE id = 'checking';
            """)
        let revisions = MutationCounter()
        let database = try makeDatabase(at: url, revisions: revisions)
        let before = try databaseState(at: url)

        let result = try await database.commitAccountLifecycleMutation(
            .reopen(AccountReopenCommand(accountID: " checking ", expectedClosed: true)),
            actionID: "reopen-action",
            now: Date(timeIntervalSince1970: 1_800_000_100)
        )

        guard case .applied(let outcome) = result else {
            Issue.record("Expected an applied reopen")
            return
        }
        #expect(outcome.operation == .reopen)
        #expect(outcome.account == AccountLifecycleAccount(
            id: "checking",
            name: "Daily Spending",
            offBudget: true,
            isClosed: false,
            accountGroupID: "cash-group"
        ))

        let after = try databaseState(at: url)
        #expect(before.account?.closed == 1)
        #expect(after.account == AccountState(
            id: "checking",
            name: "Daily Spending",
            offBudget: 1,
            closed: 0,
            tombstone: 0,
            sortOrder: 17,
            accountGroupID: "cash-group",
            bankSyncStatus: nil
        ))
        #expect(after.messages.count == before.messages.count + 1)
        let message = try #require(after.messages.last)
        #expect(message.dataset == "accounts")
        #expect(message.row == "checking")
        #expect(message.column == "closed")
        #expect(message.value == "N:0")
        #expect(after.outbox?.count == 1)
        #expect(after.outbox?.first?.cell == message.cell)
        #expect(revisions.count == 1)

        let record = try #require(try await database.recentBudgetActions().first)
        let payload = AccountBudgetAction(
            name: "Daily Spending",
            offbudget: true,
            operation: .reopen
        )
        #expect(record.id == "reopen-action")
        #expect(record.summary == .account(payload))
        #expect(record.inverse == .account(payload))
    }

    @Test func unchangedAndPeerCompletedRenamesAreTrueNoOps() async throws {
        let unchangedURL = try support.makeSQLiteFixture()
        let unchangedRevisions = MutationCounter()
        let unchangedDatabase = try makeDatabase(at: unchangedURL, revisions: unchangedRevisions)
        let unchangedBefore = try databaseState(at: unchangedURL)
        let unchangedClock = await unchangedDatabase.localClock

        let unchanged = try await unchangedDatabase.commitAccountLifecycleMutation(
            .rename(AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: " Checking "
            ))
        )

        guard case .noChange(let unchangedOutcome) = unchanged else {
            Issue.record("Expected unchanged rename to be a no-op")
            return
        }
        #expect(unchangedOutcome.account.name == "Checking")
        #expect(try databaseState(at: unchangedURL) == unchangedBefore)
        #expect(await unchangedDatabase.localClock == unchangedClock)
        #expect(unchangedRevisions.count == 0)

        let peerURL = try support.makeSQLiteFixture()
        let peerRevisions = MutationCounter()
        let peerDatabase = try makeDatabase(at: peerURL, revisions: peerRevisions)
        _ = try await peerDatabase.applyRemoteSyncMessages([
            peerMessage(column: "name", value: "S:Daily Spending")
        ])
        peerRevisions.reset()
        let peerBefore = try databaseState(at: peerURL)
        let peerClock = await peerDatabase.localClock

        let peerCompleted = try await peerDatabase.commitAccountLifecycleMutation(
            .rename(AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: "Daily Spending"
            ))
        )

        guard case .noChange(let peerOutcome) = peerCompleted else {
            Issue.record("Expected peer-completed rename to be a no-op")
            return
        }
        #expect(peerOutcome.account.name == "Daily Spending")
        #expect(try databaseState(at: peerURL) == peerBefore)
        #expect(await peerDatabase.localClock == peerClock)
        #expect(peerRevisions.count == 0)
    }

    @Test func staleTombstonedAndDuplicateRenamesRejectWithoutMutation() async throws {
        try await expectRejectedRename(
            extraSQL: "UPDATE accounts SET name = 'Peer Name' WHERE id = 'checking';",
            command: AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: "Local Name"
            ),
            expectedError: .reviewChanged
        )
        try await expectRejectedRename(
            extraSQL: "UPDATE accounts SET tombstone = 1 WHERE id = 'checking';",
            command: AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: "Local Name"
            ),
            expectedError: .accountNotFound
        )
        try await expectRejectedRename(
            extraSQL: "INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);",
            command: AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: "Savings"
            ),
            expectedError: .duplicateName("Savings")
        )
    }

    @Test func historyInsertFailureRollsBackAccountCRDTOutboxAndClock() async throws {
        let url = try support.makeSQLiteFixture()
        let revisions = MutationCounter()
        let database = try makeDatabase(at: url, revisions: revisions)
        _ = try await database.commitAccountLifecycleMutation(
            .rename(AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: "First Name"
            )),
            actionID: "duplicate-history-id",
            now: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let before = try databaseState(at: url)
        let clockBefore = await database.localClock

        await #expect(throws: LocalFirstError.invalidLocalWrite(
            "the database transaction was rolled back"
        )) {
            try await database.commitAccountLifecycleMutation(
                .rename(AccountRenameCommand(
                    accountID: "checking",
                    expectedCurrentName: "First Name",
                    newName: "Second Name"
                )),
                actionID: "duplicate-history-id",
                now: Date(timeIntervalSince1970: 1_800_000_300)
            )
        }

        #expect(try databaseState(at: url) == before)
        #expect(await database.localClock == clockBefore)
        #expect(revisions.count == 2)
    }

    @Test func retainedInvalidatedDatabaseRejectsLifecycleWrite() async throws {
        let url = try support.makeSQLiteFixture()
        let revisions = MutationCounter()
        let database = try makeDatabase(at: url, revisions: revisions)
        let before = try databaseState(at: url)
        let clockBefore = await database.localClock
        database.invalidateSessionWrites()

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            try await database.commitAccountLifecycleMutation(
                .rename(AccountRenameCommand(
                    accountID: "checking",
                    expectedCurrentName: "Checking",
                    newName: "Daily Spending"
                ))
            )
        }

        #expect(try databaseState(at: url) == before)
        #expect(await database.localClock == clockBefore)
        #expect(revisions.count == 0)
    }

    @Test func accountHistoryCodingPreservesLegacyCreationAndNewOperations() throws {
        let legacy = try JSONDecoder().decode(
            AccountBudgetAction.self,
            from: Data(#"{"name":"Checking","offbudget":false}"#.utf8)
        )
        #expect(legacy == AccountBudgetAction(name: "Checking", offbudget: false))
        #expect(legacy.operation == nil)

        let legacyRecord = BudgetActionRecord(
            id: "legacy-account",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .account,
            status: .applied,
            month: nil,
            summary: .account(legacy),
            inverse: .account(legacy),
            affectedCategoryIDs: [],
            forwardTimestampStart: nil,
            forwardTimestampEnd: nil,
            source: .ui
        )
        let row = try #require(HistoryRowPresentation.rows(
            from: [legacyRecord],
            categoryNames: [:],
            undoableActionID: nil,
            currency: .usd,
            privacyEnabled: false,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ).first)
        #expect(row.title == "Added Checking")

        for operation in [AccountLifecycleOperation.rename, .reopen] {
            let action = AccountBudgetAction(
                name: "Daily Spending",
                offbudget: true,
                operation: operation
            )
            let decoded = try JSONDecoder().decode(
                AccountBudgetAction.self,
                from: JSONEncoder().encode(action)
            )
            #expect(decoded == action)
            var record = legacyRecord
            record.summary = .account(decoded)
            let title = HistoryRowPresentation.gestureSummary(
                for: record, categoryNames: [:], currency: .usd, privacyEnabled: false
            )
            #expect(title == (operation == .rename ? "Renamed Daily Spending" : "Reopened Daily Spending"))
            let privateTitle = HistoryRowPresentation.gestureSummary(
                for: record, categoryNames: [:], currency: .usd, privacyEnabled: true
            )
            #expect(!privateTitle.contains(action.name))
        }
    }

    private func expectRejectedRename(
        extraSQL: String,
        command: AccountRenameCommand,
        expectedError: AccountLifecycleCommandError
    ) async throws {
        let url = try support.makeSQLiteFixture(extraSQL: extraSQL)
        let revisions = MutationCounter()
        let database = try makeDatabase(at: url, revisions: revisions)
        let before = try databaseState(at: url)
        let clockBefore = await database.localClock

        do {
            _ = try await database.commitAccountLifecycleMutation(.rename(command))
            Issue.record("Expected account lifecycle rejection")
        } catch let error as AccountLifecycleCommandError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Expected AccountLifecycleCommandError, received \(error)")
        }

        #expect(try databaseState(at: url) == before)
        #expect(await database.localClock == clockBefore)
        #expect(revisions.count == 0)
    }

    private func makeDatabase(at url: URL, revisions: MutationCounter) throws -> BudgetDatabase {
        try BudgetDatabase(
            databaseURL: url,
            localNodeID: "account-lifecycle-tests",
            beforeBudgetDataMutation: {
                revisions.increment()
            }
        )
    }

    private func peerMessage(column: String, value: String) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: "2026-09-27T12:00:00.000Z-0000-peer000000000000",
            dataset: "accounts",
            row: "checking",
            column: column,
            serializedValue: value
        )
    }

    private func databaseState(at url: URL) throws -> DatabaseState {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in
            let accountColumns = Set(
                try Row.fetchAll(db, sql: "PRAGMA table_info(accounts)")
                    .compactMap { $0["name"] as String? }
            )
            let accountGroup = accountColumns.contains("account_group_id")
                ? "account_group_id" : "NULL"
            let bankSyncStatus = accountColumns.contains("bank_sync_status")
                ? "bank_sync_status" : "NULL"
            let account = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, name, offbudget, closed, tombstone, sort_order,
                           \(accountGroup) AS account_group_id,
                           \(bankSyncStatus) AS bank_sync_status
                    FROM accounts WHERE id = 'checking'
                    """
            ).map { row in
                AccountState(
                    id: row["id"] ?? "",
                    name: row["name"] ?? "",
                    offBudget: row["offbudget"] ?? 0,
                    closed: row["closed"] ?? 0,
                    tombstone: row["tombstone"] ?? 0,
                    sortOrder: row["sort_order"] ?? 0,
                    accountGroupID: row["account_group_id"],
                    bankSyncStatus: row["bank_sync_status"]
                )
            }
            let messages = try Row.fetchAll(
                db,
                sql: """
                    SELECT timestamp, dataset, row, column, value
                    FROM messages_crdt
                    ORDER BY timestamp, dataset, row, column
                    """
            ).map(MessageState.init)
            let outbox = try tableExists("actualist_outbox", db: db)
                ? Row.fetchAll(
                    db,
                    sql: """
                        SELECT timestamp, dataset, row, column, value
                        FROM actualist_outbox
                        ORDER BY timestamp, dataset, row, column
                        """
                ).map(MessageState.init)
                : nil
            let history = try tableExists("actualist_action_log", db: db)
                ? String.fetchAll(
                    db,
                    sql: """
                        SELECT id || '|' || created_at || '|' || kind || '|' || status || '|'
                               || summary_json || '|' || inverse_json || '|' || source
                        FROM actualist_action_log
                        ORDER BY created_at, id
                        """
                )
                : nil
            return DatabaseState(
                account: account,
                messages: messages,
                outbox: outbox,
                history: history
            )
        }
    }

    nonisolated private func tableExists(_ table: String, db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?
                )
                """,
            arguments: [table]
        ) ?? false
    }
}

private struct AccountState: Equatable {
    let id: String
    let name: String
    let offBudget: Int
    let closed: Int
    let tombstone: Int
    let sortOrder: Int
    let accountGroupID: String?
    let bankSyncStatus: String?
}

private struct MessageState: Equatable {
    let timestamp: String
    let dataset: String
    let row: String
    let column: String
    let value: String

    init(row: Row) {
        timestamp = row["timestamp"] ?? ""
        dataset = row["dataset"] ?? ""
        self.row = row["row"] ?? ""
        column = row["column"] ?? ""
        value = row["value"] ?? ""
    }

    var cell: String {
        [timestamp, dataset, row, column, value].joined(separator: "|")
    }
}

private struct DatabaseState: Equatable {
    let account: AccountState?
    let messages: [MessageState]
    let outbox: [MessageState]?
    let history: [String]?
}

private final class MutationCounter: Sendable {
    private let storage = Mutex(0)

    var count: Int {
        storage.withLock { $0 }
    }

    func increment() {
        storage.withLock { $0 += 1 }
    }

    func reset() {
        storage.withLock { $0 = 0 }
    }
}
