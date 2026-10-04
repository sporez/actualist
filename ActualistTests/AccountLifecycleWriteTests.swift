import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountLifecycleWriteTests {
    private let support = LocalFirstActualStoreTests()

    @Test func renameCommitsExactlyOneNameCellAndPreservesClosedAccountFacts() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            UPDATE accounts SET closed = 1 WHERE id = 'checking';
            """), localNodeID: "lifecycle-test")
        let result = try await database.commitAccountLifecycleMutation(
            .rename(AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: " Daily Spending "
            ))
        )

        guard case .applied(let outcome) = result else {
            Issue.record("Expected a committed rename")
            return
        }
        let messages = try await database.pendingLocalSyncMessages().map(\.message)
        #expect(messages.count == 1)
        #expect(messages.first?.dataset == "accounts")
        #expect(messages.first?.row == "checking")
        #expect(messages.first?.column == "name")
        #expect(messages.first?.serializedValue == "S:Daily Spending")
        #expect(outcome.account.isClosed)
        #expect(outcome.account.name == "Daily Spending")
    }

    @Test func unchangedRenameAndPeerCompletedRenameAreNoChangeWithoutDrafts() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture())
        let unchanged = try await database.commitAccountLifecycleMutation(
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

        let command = AccountRenameCommand(
            accountID: "checking",
            expectedCurrentName: "Checking",
            newName: "Daily Spending"
        )
        let precondition = AccountLifecycleMutationPrecondition.rename(command)
        _ = try await database.applyRemoteSyncMessages([
            peerMessage(column: "name", value: "S:Daily Spending")
        ])

        let decision = try await database.commitAccountLifecycleMutation(precondition)
        guard case .noChange(let outcome) = decision else {
            Issue.record("Expected peer-completed rename to be a no-op")
            return
        }
        #expect(outcome.account.name == "Daily Spending")
    }

    @Test func renameRejectsChangedReviewAndExactDuplicateButAllowsCaseVariant() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);
            """), localNodeID: "lifecycle-test")

        await #expect(throws: AccountLifecycleCommandError.duplicateName("Savings")) {
            try await database.commitAccountLifecycleMutation(
                .rename(AccountRenameCommand(
                    accountID: "checking",
                    expectedCurrentName: "Checking",
                    newName: "Savings"
                ))
            )
        }

        let caseVariant = try await database.commitAccountLifecycleMutation(
            .rename(AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: "savings"
            ))
        )
        guard case .applied = caseVariant else {
            Issue.record("Expected exact-case duplicate semantics")
            return
        }

        _ = try await database.applyRemoteSyncMessages([
            peerMessage(column: "name", value: "S:Peer Name")
        ])
        await #expect(throws: AccountLifecycleCommandError.reviewChanged) {
            try await database.commitAccountLifecycleMutation(.rename(AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: "Local Name"
            )))
        }
    }

    @Test func reopenCommitsOnlyClosedCellAndPeerCompletedReopenIsNoChange() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            UPDATE accounts SET closed = 1 WHERE id = 'checking';
            """), localNodeID: "lifecycle-test")
        let command = AccountReopenCommand(accountID: "checking", expectedClosed: true)
        let result = try await database.commitAccountLifecycleMutation(.reopen(command))

        guard case .applied(let outcome) = result else {
            Issue.record("Expected a committed reopen")
            return
        }
        let messages = try await database.pendingLocalSyncMessages().map(\.message)
        #expect(messages.count == 1)
        #expect(messages.first?.dataset == "accounts")
        #expect(messages.first?.row == "checking")
        #expect(messages.first?.column == "closed")
        #expect(messages.first?.serializedValue == "N:0")
        #expect(!outcome.account.isClosed)

        let peerDatabase = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            UPDATE accounts SET closed = 1 WHERE id = 'checking';
            """))
        _ = try await peerDatabase.applyRemoteSyncMessages([
            peerMessage(column: "closed", value: "N:0")
        ])
        let decision = try await peerDatabase.commitAccountLifecycleMutation(.reopen(command))
        guard case .noChange(let peerOutcome) = decision else {
            Issue.record("Expected peer-completed reopen to be a no-op")
            return
        }
        #expect(!peerOutcome.account.isClosed)
        #expect(try await peerDatabase.pendingLocalSyncMessageCount() == 0)
    }

    @Test func tombstonedAccountCannotPassSameTransactionValidation() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture())
        let precondition = AccountLifecycleMutationPrecondition.rename(AccountRenameCommand(
            accountID: "checking",
            expectedCurrentName: "Checking",
            newName: "Daily Spending"
        ))
        _ = try await database.applyRemoteSyncMessages([
            peerMessage(column: "tombstone", value: "N:1")
        ])

        await #expect(throws: AccountLifecycleCommandError.accountNotFound) {
            try await database.commitAccountLifecycleMutation(precondition)
        }
    }

    private func peerMessage(column: String, value: String) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: "\(SyncTimestamp.wallTimeString(for: Date().addingTimeInterval(60)))-0000-peer000000000000",
            dataset: "accounts",
            row: "checking",
            column: column,
            serializedValue: value
        )
    }
}
