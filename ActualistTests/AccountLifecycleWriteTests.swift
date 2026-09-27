import Testing
@testable import Actualist

@MainActor
struct AccountLifecycleWriteTests {
    private let support = LocalFirstActualStoreTests()

    @Test func renamePreparesExactlyOneNameCellAndPreservesClosedAccountFacts() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            UPDATE accounts SET closed = 1 WHERE id = 'checking';
            """))
        var builder = LocalFirstSyncMessageBuilder()
        let prepared = try await database.prepareAccountRename(
            command: AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: " Daily Spending "
            ),
            builder: &builder
        )

        guard case .apply(let precondition, let messages, let outcome) = prepared else {
            Issue.record("Expected a prepared rename")
            return
        }
        #expect(precondition == .rename(AccountRenameCommand(
            accountID: "checking",
            expectedCurrentName: "Checking",
            newName: "Daily Spending"
        )))
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
        var builder = LocalFirstSyncMessageBuilder()
        let unchanged = try await database.prepareAccountRename(
            command: AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: " Checking "
            ),
            builder: &builder
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

        let decision = try await database.validateAccountLifecycleMutation(precondition)
        guard case .noChange(let outcome) = decision else {
            Issue.record("Expected peer-completed rename to be a no-op")
            return
        }
        #expect(outcome.account.name == "Daily Spending")
    }

    @Test func renameRejectsChangedReviewAndExactDuplicateButAllowsCaseVariant() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);
            """))
        var builder = LocalFirstSyncMessageBuilder()

        await #expect(throws: AccountLifecycleCommandError.duplicateName("Savings")) {
            try await database.prepareAccountRename(
                command: AccountRenameCommand(
                    accountID: "checking",
                    expectedCurrentName: "Checking",
                    newName: "Savings"
                ),
                builder: &builder
            )
        }

        let caseVariant = try await database.prepareAccountRename(
            command: AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: "savings"
            ),
            builder: &builder
        )
        guard case .apply = caseVariant else {
            Issue.record("Expected exact-case duplicate semantics")
            return
        }

        _ = try await database.applyRemoteSyncMessages([
            peerMessage(column: "name", value: "S:Peer Name")
        ])
        await #expect(throws: AccountLifecycleCommandError.reviewChanged) {
            try await database.validateAccountLifecycleMutation(.rename(AccountRenameCommand(
                accountID: "checking",
                expectedCurrentName: "Checking",
                newName: "Local Name"
            )))
        }
    }

    @Test func reopenPreparesOnlyClosedCellAndPeerCompletedReopenIsNoChange() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            UPDATE accounts SET closed = 1 WHERE id = 'checking';
            """))
        let command = AccountReopenCommand(accountID: "checking", expectedClosed: true)
        var builder = LocalFirstSyncMessageBuilder()
        let prepared = try await database.prepareAccountReopen(command: command, builder: &builder)

        guard case .apply(let precondition, let messages, let outcome) = prepared else {
            Issue.record("Expected a prepared reopen")
            return
        }
        #expect(precondition == .reopen(command))
        #expect(messages.count == 1)
        #expect(messages.first?.dataset == "accounts")
        #expect(messages.first?.row == "checking")
        #expect(messages.first?.column == "closed")
        #expect(messages.first?.serializedValue == "N:0")
        #expect(!outcome.account.isClosed)

        _ = try await database.applyRemoteSyncMessages([
            peerMessage(column: "closed", value: "N:0")
        ])
        let decision = try await database.validateAccountLifecycleMutation(precondition)
        guard case .noChange(let peerOutcome) = decision else {
            Issue.record("Expected peer-completed reopen to be a no-op")
            return
        }
        #expect(!peerOutcome.account.isClosed)
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
            try await database.validateAccountLifecycleMutation(precondition)
        }
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
}
